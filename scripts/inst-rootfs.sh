#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# scripts/inst-rootfs.sh — Stage 1.5: build the RAM-boot rootfs tree.
#
# Extracts the Resolute ISO's casper/minimal.squashfs into $ROOTFS, injects the
# cross-compiled 7.2 kernel + modules + Surface firmware + DTB, then chroots
# (via the qemu-aarch64 binfmt handler) to reconfigure apt for the arm64 ports
# mirror, create the user, enable GDM autologin, and set the default target.
#
# The result ($BUILD/inst/root) is a complete Ubuntu arm64 rootfs that Stage 2
# packs into a squashfs and embeds in the initrd for RAM-only boot.
#
# Runs as root on the x86_64 build host. Every write/mount MUST target
# "${ROOTFS}/…" or "chroot ${ROOTFS}" — a bare host path would corrupt the host.
# =============================================================================

# --- 0. Path configuration: env.sh is the single source of truth -------------
# shellcheck source=scripts/env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# Fixed knobs for this stage.
CROSS_COMPILE="aarch64-linux-gnu-"
SQUASHFS_REL="casper/minimal.squashfs"   # ISO-relative path to the base rootfs
KERNEL_RELEASE_FILE="${KERNEL_SRC}/include/config/kernel.release"
UBUNTU_SUITE="resolute"                   # Ubuntu 26.04 codename (the ISO's release)
PORTS_MIRROR="http://ports.ubuntu.com/ubuntu-ports"
TARGET_USER="aleksey"
USER_PASSWORD="surface"
ROOT_PASSWORD="surface"
TARGET_HOSTNAME="surface-sp12"
USER_GROUPS="sudo,adm,plugdev,netdev,video,audio,render"

# Bind mounts we set up for the chroot, in mount order. Unmounted in reverse.
CHROOT_BINDS=(dev dev/pts proc sys)

# --- Helpers -----------------------------------------------------------------
die() { echo "ERROR: $*" >&2; exit 1; }

run_with_check() {
    local step_name="$1"; shift
    echo "[ROOTFS] ${step_name}"
    if ! "$@"; then
        die "'${step_name}' failed (exit code $?)."
    fi
}

# Unmount every chroot bind (reverse order) plus the ISO, if still mounted.
# Idempotent and non-fatal: safe to call from the EXIT trap on any exit path.
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

# 1.1 Resolute ISO
[ -f "$ISO_PATH" ] || die "Resolute ISO not found at ${ISO_PATH}"

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
# 2. ISO mount and squashfs extraction
# =============================================================================
# 2.1 mount the ISO read-only via loop.
run_with_check "Mounting ISO read-only" \
    mount -o loop,ro "$ISO_PATH" "$ISO_MOUNT"

# 2.2 the base squashfs must exist inside the ISO.
[ -f "${ISO_MOUNT}/${SQUASHFS_REL}" ] \
    || die "${SQUASHFS_REL} not found inside the ISO — wrong ISO or layout changed."

# 2.2 extract. NOTE: no -f, and $ROOTFS must NOT pre-exist — unsquashfs -d owns
# and creates it. -f corrupts top-level perms to 700 (known project footgun).
run_with_check "Extracting ${SQUASHFS_REL}" \
    unsquashfs -d "$ROOTFS" "${ISO_MOUNT}/${SQUASHFS_REL}"

# 2.3 the ISO is no longer needed — unmount immediately and verify.
run_with_check "Unmounting ISO" umount "$ISO_MOUNT"
mountpoint -q "$ISO_MOUNT" && die "ISO still mounted at ${ISO_MOUNT} after umount."

# 2.4 / 2.5 sanity check: extraction must leave 755 on /, /usr, /etc.
for d in "" /usr /etc; do
    perm="$(stat -c '%a' "${ROOTFS}${d}")"
    [ "$perm" = "755" ] \
        || die "Bad permissions on ${ROOTFS}${d}: expected 755, got ${perm} (unsquashfs corruption?)."
done
echo "Extraction verified (/, /usr, /etc are 755)."

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
run_with_check "Copying resolv.conf into rootfs" \
    cp --dereference /etc/resolv.conf "${ROOTFS}/etc/resolv.conf"

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
# 5. Chroot — apt configuration
# =============================================================================
# 5.1 disable every live-media apt source (both classic .list and deb822 .sources)
# so nothing points at file:/cdrom, which does not exist off the ISO.
echo "[ROOTFS] Disabling live-media apt sources"
if [ -f "${ROOTFS}/etc/apt/sources.list" ]; then
    mv "${ROOTFS}/etc/apt/sources.list" "${ROOTFS}/etc/apt/sources.list.disabled"
fi
if [ -d "${ROOTFS}/etc/apt/sources.list.d" ]; then
    for f in "${ROOTFS}/etc/apt/sources.list.d/"*.list "${ROOTFS}/etc/apt/sources.list.d/"*.sources; do
        [ -e "$f" ] || continue   # nullglob-free guard: skip the literal pattern
        mv "$f" "${f}.disabled"
    done
fi

# 5.2 pin apt to the arm64 ports mirror — exactly resolute / -updates / -security.
run_with_check "Writing arm64 ports sources.list" \
    tee "${ROOTFS}/etc/apt/sources.list" <<EOF
deb ${PORTS_MIRROR} ${UBUNTU_SUITE} main restricted universe multiverse
deb ${PORTS_MIRROR} ${UBUNTU_SUITE}-updates main restricted universe multiverse
deb ${PORTS_MIRROR} ${UBUNTU_SUITE}-security main restricted universe multiverse
EOF

# 5.3 refresh package lists against the new mirror.
run_with_check "apt-get update" in_chroot apt-get update

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

# 6.4 GDM autologin.
run_with_check "Creating gdm3 autologin config" mkdir -p "${ROOTFS}/etc/gdm3"
run_with_check "Writing gdm3 custom.conf" \
    tee "${ROOTFS}/etc/gdm3/custom.conf" <<EOF
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=${TARGET_USER}
EOF

# 6.5 default target = graphical.target. Link straight at the unit file (never a
# SysV init.d / runlevel path). Resolve where systemd units actually live in
# this rootfs (usrmerge → /lib is a symlink to /usr/lib, but be explicit).
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
echo "   User:    ${TARGET_USER} (autologin), hostname ${TARGET_HOSTNAME}"
echo ""
echo " Next: Stage 2 (inst-initrd.sh) packs this tree into rootfs.squashfs"
echo "       and embeds it in the RAM-boot initrd."
echo "=============================================="
