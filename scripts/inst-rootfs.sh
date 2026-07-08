#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# scripts/inst-rootfs.sh — Stage 1.5: build the RAM-boot rootfs tree.
#
# Extracts the Debian 14 (forky) generic arm64 cloud image by loop-mounting
# its ext4 root partition and copying the  tree into $ROOTFS, injects
# the cross-compiled kernel + modules + Surface firmware + DTB, then chroots 
# to create the user, install the LXQt desktop with the SDDM login manager, and
# neutralize cloud-image boot footguns.
#
# The result ($BUILD/inst/root) is a complete Debian arm64 rootfs with an
# LXQt/SDDM graphical desktop that Stage 2 packs into a squashfs and embeds in
# the initrd for RAM-only boot.
#
# Runs as root on the x86_64 build host. Every write/mount MUST target
# "${ROOTFS}/…" or "chroot ${ROOTFS}" — a bare host path would corrupt the host.
# =============================================================================

# --- 0. Path configuration: env.sh is the single source of truth -------------
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# Fixed knobs for this stage.
CROSS_COMPILE="aarch64-linux-gnu-"
KERNEL_RELEASE_FILE="${KERNEL_SRC}/include/config/kernel.release"
TARGET_USER="myuser"
USER_PASSWORD="surface"
ROOT_PASSWORD="surface"
TARGET_HOSTNAME="surface-sp12"
USER_GROUPS="sudo,adm,plugdev,video,audio,render"

# Bind mounts we set up for the chroot, in mount order. Unmounted in reverse.
CHROOT_BINDS=(dev dev/pts proc sys)

# Loop device attached to disk.raw (set in section 2). Tracked here so the
# cleanup trap can detach it on any exit path.
LOOP=""

# --- Helpers -----------------------------------------------------------------
die() { echo "ERROR: $*" >&2; exit 1; }

run_with_check() {
    local step_name="$1"; shift
    echo "[ROOTFS] ${step_name}"
    if ! "$@"; then
        die "'${step_name}' failed (exit code $?)."
    fi
}

# Unmount every chroot bind (reverse order) plus the image root partition, and
# detach the disk.raw loop device, if still present. Idempotent and non-fatal:
# safe to call from the EXIT trap on any exit path.
unmount_all() {
    local i target
    for (( i=${#CHROOT_BINDS[@]}-1; i>=0; i-- )); do
        target="${ROOTFS}/${CHROOT_BINDS[$i]}"
        if mountpoint -q "$target"; then
            umount "$target" 2>/dev/null || umount -l "$target" 2>/dev/null || true
        fi
    done
    if mountpoint -q "$ISO_MOUNT"; then
        umount "$ISO_MOUNT" 2>/dev/null || umount -l "$ISO_MOUNT" 2>/dev/null || true
    fi
    # Detach the loop device (with its partition scan) once nothing is mounted
    # off it. losetup -d is a no-op-safe best effort here.
    if [ -n "$LOOP" ] && [ -b "$LOOP" ]; then
        losetup -d "$LOOP" 2>/dev/null || true
    fi
}

# EXIT trap: preserve the real exit status, always clean up mounts. Installed
# before the first mount so a failure at ANY later step still unmounts.
cleanup() {
    local rc=$?
    unmount_all
    exit "$rc"
}

# =============================================================================
# 1. Verify prerequisites
# =============================================================================
echo "=============================================="
echo " Surface Pro 12 rootfs build (Stage 1.5)"
echo "=============================================="

# Must be root: loop-mount, chroot, and modules_install (owned by root) require it.
[ "$(id -u)" -eq 0 ] || die "This script must be run as root (mount/chroot/modules_install)."

# 1.7 arm64 chroot needs the qemu-aarch64 binfmt handler registered & enabled.
BINFMT="/proc/sys/fs/binfmt_misc/qemu-aarch64"
[ -e "$BINFMT" ] || die "qemu-aarch64 binfmt not registered. Install qemu-user-static and register binfmts."
grep -q '^enabled' "$BINFMT" || die "qemu-aarch64 binfmt is registered but disabled."

# 1.1 Debian generic arm64 cloud image.
[ -f "$ISO_PATH" ] || die "Debian image not found at ${ISO_PATH}"

# 1.1b host tooling: losetup with partition scanning (-P) and xz-capable tar are
# required to unpack and loop-mount the raw disk.
command -v losetup >/dev/null || die "losetup not found (util-linux) — required to loop-mount disk.raw."
losetup --help 2>&1 | grep -q -- '-P' \
    || die "This losetup lacks -P (partition scan) support — cannot mount disk.raw partitions."
command -v xz >/dev/null || die "xz not found — required to extract the .tar.xz image."

# 1.2 kernel source with the compiled ARM64 Image
[ -f "${KERNEL_SRC}/arch/arm64/boot/Image" ] \
    || die "Kernel Image not found at ${KERNEL_SRC}/arch/arm64/boot/Image (run scripts/build-kernel.sh first)."

# 1.2 (cont.) kernel release string — required to name vmlinuz + place modules
[ -f "$KERNEL_RELEASE_FILE" ] \
    || die "Kernel release file not found at ${KERNEL_RELEASE_FILE} (kernel not fully built)."

# 1.3 Surface DTB
[ -f "${ASSETS}/boot/dtb" ] || die "DTB not found at ${ASSETS}/boot/dtb"

# 1.4 output dirs can be created (parent must be writable; $ROOTFS itself is
# created by unsquashfs, so we only ensure its parent and the ISO mount point).
mkdir -p "$(dirname "$ROOTFS")" "$ISO_MOUNT" \
    || die "Cannot create build output directories under $(dirname "$ROOTFS")"

echo "Prerequisites OK."

# =============================================================================
# 0. Guard + remove any stale rootfs (findmnt safety before rm -rf)
# =============================================================================
# Boundary guard: refuse to rm anything that isn't the expected build path.
case "$ROOTFS" in
    "${PROJECT_DIR}/build/inst/root") : ;;
    *) die "Refusing to rm ROOTFS='${ROOTFS}': not the expected build/inst/root path." ;;
esac

# Safety: if a previous run left bind mounts under $ROOTFS, `rm -rf` would delete
# THROUGH them into the host (e.g. host /dev). Abort rather than recurse.
if findmnt -rno TARGET | grep -q -E "^${ROOTFS}(/|$)"; then
    die "Mounts still present under ${ROOTFS}. Unmount them before rebuilding:
$(findmnt -rno TARGET | grep -E "^${ROOTFS}(/|$)")"
fi

if [ -e "$ROOTFS" ]; then
    echo "Removing stale rootfs at ${ROOTFS}"
    rm -rf "$ROOTFS"
fi

# Install the cleanup trap now: every mount from here on is unwound on any exit.
trap cleanup EXIT

# =============================================================================
# 2. Unpack the Debian disk image and copy its root partition into $ROOTFS
# =============================================================================
# 2.1 extract disk.raw from the .tar.xz into build/inst (sibling of $ROOTFS).
DISK_WORK="$(dirname "$ROOTFS")"
DISK_RAW="${DISK_WORK}/disk.raw"
mkdir -p "$DISK_WORK"
rm -f "$DISK_RAW"
run_with_check "Extracting disk.raw from image" \
    tar -xf "$ISO_PATH" -C "$DISK_WORK" disk.raw
[ -f "$DISK_RAW" ] || die "disk.raw not found after extracting ${ISO_PATH}."

# 2.2 attach as a loop device with partition scanning. $LOOP is tracked so the
# cleanup trap detaches it on any later failure.
LOOP="$(losetup -Pf --show "$DISK_RAW")" || die "losetup failed for ${DISK_RAW}."
[ -b "$LOOP" ] || die "losetup did not return a block device (got '${LOOP}')."
echo "[ROOTFS] Attached ${DISK_RAW} as ${LOOP}"

# 2.3 the ext4 root is partition 1. The pN node can appear slightly after
# losetup returns; wait briefly (partprobe as a fallback) before giving up.
ROOT_PART="${LOOP}p1"
for _ in $(seq 1 10); do
    [ -b "$ROOT_PART" ] && break
    partprobe "$LOOP" 2>/dev/null || true
    sleep 0.3
done
[ -b "$ROOT_PART" ] || die "Root partition ${ROOT_PART} did not appear (partition scan failed)."

# 2.4 mount the root partition read-only and copy its whole tree into $ROOTFS.
# Unlike the old unsquashfs flow, $ROOTFS is created here (cp -a into it); -a
# preserves ownership, perms, and symlinks and copies top-level dotfiles.
run_with_check "Mounting root partition read-only" \
    mount -o ro "$ROOT_PART" "$ISO_MOUNT"
mkdir -p "$ROOTFS"
run_with_check "Copying root filesystem into ${ROOTFS}" \
    cp -a "${ISO_MOUNT}/." "$ROOTFS/"

# 2.5 tear down the image: unmount, detach the loop, and delete disk.raw so it
# does not linger as a multi-gigabyte artifact.
run_with_check "Unmounting root partition" umount "$ISO_MOUNT"
mountpoint -q "$ISO_MOUNT" && die "Image partition still mounted at ${ISO_MOUNT} after umount."
losetup -d "$LOOP" 2>/dev/null || true
LOOP=""
rm -f "$DISK_RAW"

# 2.6 sanity check: a well-formed rootfs has 755 on /, /usr, /etc.
for d in "" /usr /etc; do
    perm="$(stat -c '%a' "${ROOTFS}${d}")"
    [ "$perm" = "755" ] \
        || die "Bad permissions on ${ROOTFS}${d}: expected 755, got ${perm} (bad copy?)."
done
echo "Copy verified (/, /usr, /etc are 755)."

# =============================================================================
# 3. Inject kernel, modules, firmware, DTB
# =============================================================================
# 3.1 kernel release string.
REL="$(<"$KERNEL_RELEASE_FILE")"
[ -n "$REL" ] || die "Empty kernel release string in ${KERNEL_RELEASE_FILE}."
echo "Kernel release: ${REL}"

# 3.2 kernel image.
mkdir -p "${ROOTFS}/boot"
run_with_check "Installing kernel image" \
    cp "${KERNEL_SRC}/arch/arm64/boot/Image" "${ROOTFS}/boot/vmlinuz-${REL}"

run_with_check "Installing kernel modules" \
    make -C "$KERNEL_SRC" \
         ARCH=arm64 \
         CROSS_COMPILE="$CROSS_COMPILE" \
         INSTALL_MOD_PATH="$ROOTFS" \
         modules_install

# 3.4 / 3.5 firmware from assets/lib → rootfs/lib (merges assets/lib/firmware/*).
mkdir -p "${ROOTFS}/lib/firmware"
run_with_check "Installing Surface firmware" \
    cp -a "${ASSETS}/lib/." "${ROOTFS}/lib/"

# 3.5b project-local firmware overlay. Holds the ath12k WCN7850 board.bin Wi-Fi fixup.
if [ -d "$FIRMWARE" ]; then
    run_with_check "Installing project-local firmware overlay" \
        cp -a "${FIRMWARE}/." "${ROOTFS}/lib/firmware/"
fi

# 3.6 optional /usr assets (e.g. qcom acdbdata) if present.
if [ -d "${ASSETS}/usr" ]; then
    run_with_check "Installing /usr assets" \
        cp -a "${ASSETS}/usr/." "${ROOTFS}/usr/"
fi

# 3.7 device tree blob.
run_with_check "Installing device tree blob" \
    cp "${ASSETS}/boot/dtb" "${ROOTFS}/boot/surface.dtb"

# =============================================================================
# 4. Chroot — prepare mounts
# =============================================================================
# 4.1 resolv.conf so apt can resolve names inside the chroot.
run_with_check "Removing image's dangling resolv.conf symlink" \
    rm -f "${ROOTFS}/etc/resolv.conf"
run_with_check "Writing static resolv.conf into rootfs" \
    tee "${ROOTFS}/etc/resolv.conf" <<'EOF'
# Static resolvers for the chroot build; NetworkManager overwrites this at boot.
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

# 4.2 the EXIT trap (installed above) already guarantees unmount on any failure.
# 4.3 bind/virtual mounts, in CHROOT_BINDS order. Explicit commands (not a
# multi-var `for` loop) so this stays valid bash and maps /sys, not /sysfs.
run_with_check "Bind-mounting /dev"     mount --bind /dev      "${ROOTFS}/dev"
run_with_check "Bind-mounting /dev/pts" mount --bind /dev/pts  "${ROOTFS}/dev/pts"
run_with_check "Mounting proc"          mount -t proc  proc    "${ROOTFS}/proc"
run_with_check "Mounting sysfs"         mount -t sysfs sys     "${ROOTFS}/sys"

# Convenience wrapper for commands that must run inside the target.
in_chroot() { chroot "$ROOTFS" "$@"; }
export DEBIAN_FRONTEND=noninteractive

# =============================================================================
# 5. Chroot — install packages
# =============================================================================
run_with_check "apt-get update" in_chroot apt-get update
run_with_check "Installing busybox-static + LXQt/SDDM desktop + NetworkManager" \
    in_chroot apt-get install -y \
        busybox-static \
        xorg \
        sddm lxqt \
        network-manager nm-tray \
        rsync efibootmgr

# =============================================================================
# 6. Chroot — user and system configuration
# =============================================================================
# 6.1 hostname.
run_with_check "Setting hostname" \
    tee "${ROOTFS}/etc/hostname" <<<"$TARGET_HOSTNAME"

# 6.2 user account. Verify each required group exists first so useradd -G can't
# fail halfway and leave a half-created account.
echo "[ROOTFS] Creating user ${TARGET_USER}"
IFS=',' read -r -a _groups <<<"$USER_GROUPS"
for g in "${_groups[@]}"; do
    in_chroot getent group "$g" >/dev/null \
        || die "Required group '${g}' missing in rootfs — cannot add ${TARGET_USER} to it."
done
run_with_check "useradd ${TARGET_USER}" \
    in_chroot useradd --create-home --shell /bin/bash --groups "$USER_GROUPS" "$TARGET_USER"

# 6.3 passwords. chpasswd gets ONLY user:password lines on stdin (no log output),
# and pipefail makes a chroot/chpasswd failure abort the script.
echo "[ROOTFS] Setting passwords"
printf '%s:%s\n%s:%s\n' \
    "$TARGET_USER" "$USER_PASSWORD" \
    "root" "$ROOT_PASSWORD" \
    | in_chroot chpasswd

# 6.4 graphical login
run_with_check "Enabling SDDM display manager" \
    in_chroot systemctl enable sddm.service

# 6.4b NetworkManager: enable explicitly.
run_with_check "Enabling NetworkManager" \
    in_chroot systemctl enable NetworkManager.service

# 6.5 default target = graphical.target.
if   [ -f "${ROOTFS}/usr/lib/systemd/system/graphical.target" ]; then
    GRAPHICAL_UNIT="/usr/lib/systemd/system/graphical.target"
elif [ -f "${ROOTFS}/lib/systemd/system/graphical.target" ]; then
    GRAPHICAL_UNIT="/lib/systemd/system/graphical.target"
else
    die "graphical.target unit not found in rootfs — is this a systemd userspace?"
fi
mkdir -p "${ROOTFS}/etc/systemd/system"
run_with_check "Setting default target to graphical.target" \
    ln -sf "$GRAPHICAL_UNIT" "${ROOTFS}/etc/systemd/system/default.target"
# Verify the symlink resolves to a real file (guards against a dangling link).
[ -f "$(readlink -f "${ROOTFS}/etc/systemd/system/default.target")" ] \
    || die "default.target symlink does not resolve to a real unit."

# 6.6 neutralize cloud-image boot footguns.
# 6.6a /etc/fstab: the image mounts /, /boot, /boot/efi by UUIDs that belong to
# disk.raw and do not exist under RAM/overlay boot — systemd would block on the
# .mount units. Replace with a comment-only fstab (root comes from the overlay).
run_with_check "Blanking /etc/fstab" \
    tee "${ROOTFS}/etc/fstab" <<EOF
# Intentionally empty for RAM/overlay boot — see scripts/inst-rootfs.sh.
# Root is provided by the initrd overlay; the cloud image's UUID mounts are
# removed because those devices do not exist in this boot.
EOF

# 6.6b cloud-init: with no datasource it stalls boot probing for config and can
# override our user/hostname. Disable it if the image ships it.
if [ -d "${ROOTFS}/etc/cloud" ]; then
    run_with_check "Disabling cloud-init" \
        touch "${ROOTFS}/etc/cloud/cloud-init.disabled"
fi

# 6.7 SSH host keys. The Debian cloud image ships openssh-server WITHOUT host
# keys — each instance is expected to generate its own on first boot (cloud-init
# / a first-boot service). With cloud-init disabled (6.6b) and root being a
# discarded overlay, that never happens, so sshd exits with "no hostkeys
# available" and crash-loops. Generate the keys here so they are baked into the
# squashfs and stable across the RAM/overlay boots. ssh-keygen -A only creates
# the key types that are missing, so this is safe on re-runs.
if [ -x "${ROOTFS}/usr/bin/ssh-keygen" ] || [ -x "${ROOTFS}/bin/ssh-keygen" ]; then
    run_with_check "Generating SSH host keys" \
        in_chroot ssh-keygen -A
else
    echo "[ROOTFS] ssh-keygen not present in rootfs — skipping host key generation."
fi

# =============================================================================
# 7. Cleanup and reporting
# =============================================================================
# 7.1 unmount chroot binds (the trap would also do this; do it now so the size
# report and the leaked-mount check see a clean tree).
echo "[ROOTFS] Unmounting chroot binds"
unmount_all

# Confirm nothing is left mounted under the rootfs.
if findmnt -rno TARGET | grep -q -E "^${ROOTFS}(/|$)"; then
    die "Bind mounts leaked under ${ROOTFS}:
$(findmnt -rno TARGET | grep -E "^${ROOTFS}(/|$)")"
fi

# 7.2 remove the (now-unmounted) ISO mount point.
rmdir "$ISO_MOUNT" 2>/dev/null || true

# Everything succeeded — disarm the trap so its exit code can't mask success.
trap - EXIT

# 7.3 size summary.
ROOTFS_SIZE="$(du -sh "$ROOTFS" | cut -f1)"

# 7.4 completion message.
echo ""
echo "=============================================="
echo " Rootfs build complete!"
echo "   Tree:    ${ROOTFS}"
echo "   Size:    ${ROOTFS_SIZE}"
echo "   Kernel:  vmlinuz-${REL}  (+ modules, firmware, surface.dtb)"
echo "   User:    ${TARGET_USER} (SDDM login), hostname ${TARGET_HOSTNAME}"
echo ""
echo " Next: Stage 2 (inst-initrd.sh) packs this tree into rootfs.squashfs"
echo "       and embeds it in the RAM-boot initrd."
echo "=============================================="
