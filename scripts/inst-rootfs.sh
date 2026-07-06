#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# scripts/inst-rootfs.sh — Stage 1.5: build the RAM-boot rootfs tree (postmarketOS GNOME).
#
# Decompresses the postmarketOS trailblazer GNOME image ($ISO_PATH — a GPT .img.xz
# whose second partition is the ext4 aarch64 root), loop-mounts that root partition,
# rsyncs it into $ROOTFS, injects the cross-compiled kernel + modules + Surface
# firmware + DTB, then chroots (via the qemu-aarch64 binfmt handler) to install a
# static busybox, set the root password and hostname, and provision a graphical
# session: a non-root user with GDM autologin into GNOME (mutter/Wayland won't run
# as root, and a RAM boot discards pmOS's own first-boot user setup, so we create
# the user here).
#
# The result ($BUILD/inst/root) is a complete pmOS/Alpine aarch64 rootfs that
# Stage 2 packs into a squashfs and embeds in the initrd for RAM-only boot.
#
# Runs as root on the x86_64 build host. Every write/mount MUST target
# "${ROOTFS}/…" or "chroot ${ROOTFS}" — a bare host path would corrupt the host.
# =============================================================================

# --- 0. Path configuration: env.sh is the single source of truth -------------
# shellcheck source=scripts/env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# Fixed knobs for this stage.
CROSS_COMPILE="aarch64-linux-gnu-"
KERNEL_RELEASE_FILE="${KERNEL_SRC}/include/config/kernel.release"
TARGET_HOSTNAME="surface-sp12"
ROOT_PASSWORD="surface"
# GNOME can't run as root, so a non-root user is created and GDM autologs it in.
# postmarketOS convention is user "user".
TARGET_USER="user"
USER_PASSWORD="surface"

# Scratch: the decompressed image, plus the loop device holding it (set once
# attached, used by cleanup to detach). The image's root partition (p2) is mounted
# at $ISO_MOUNT — reused as the generic "source" mount point.
SRC_IMG="${BUILD}/inst/src.img"
LOOP=""

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

# Unmount every chroot bind (reverse order) plus the source mount, then detach the
# loop device. Idempotent and non-fatal: safe to call from the EXIT trap on any
# exit path.
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
    if [ -n "$LOOP" ]; then
        losetup -d "$LOOP" 2>/dev/null || true
        LOOP=""
    fi
}

# EXIT trap: preserve the real exit status, always clean up mounts + loop. Installed
# before the first mount so a failure at ANY later step still unwinds.
cleanup() {
    local rc=$?
    unmount_all
    exit "$rc"
}

# =============================================================================
# 1. Verify prerequisites
# =============================================================================
echo "=============================================="
echo " Surface Pro 12 rootfs build (Stage 1.5, pmOS)"
echo "=============================================="

# Must be root: loop-mount, chroot, and modules_install (owned by root) require it.
[ "$(id -u)" -eq 0 ] || die "This script must be run as root (mount/chroot/modules_install)."

# 1.7 arm64 chroot needs the qemu-aarch64 binfmt handler registered & enabled.
BINFMT="/proc/sys/fs/binfmt_misc/qemu-aarch64"
[ -e "$BINFMT" ] || die "qemu-aarch64 binfmt not registered. Install qemu-user-static and register binfmts."
grep -q '^enabled' "$BINFMT" || die "qemu-aarch64 binfmt is registered but disabled."

# 1.1 pmOS source image (a GPT .img.xz).
[ -f "$ISO_PATH" ] || die "pmOS image not found at ${ISO_PATH}"

# 1.2 kernel source with the compiled ARM64 Image
[ -f "${KERNEL_SRC}/arch/arm64/boot/Image" ] \
    || die "Kernel Image not found at ${KERNEL_SRC}/arch/arm64/boot/Image (run scripts/build-kernel.sh first)."

# 1.2 (cont.) kernel release string — required to name vmlinuz + place modules
[ -f "$KERNEL_RELEASE_FILE" ] \
    || die "Kernel release file not found at ${KERNEL_RELEASE_FILE} (kernel not fully built)."

# 1.3 Surface DTB
[ -f "${ASSETS}/boot/dtb" ] || die "DTB not found at ${ASSETS}/boot/dtb"

# 1.4 host tools needed for the image → rootfs path.
for tool in xz losetup partx rsync; do
    command -v "$tool" >/dev/null || die "${tool} not found (needed to decompress + loop-mount the pmOS image)."
done

# 1.5 output dirs can be created. $ROOTFS itself is created below (rsync target);
# ensure its parent, the source mount point, and the scratch image's dir exist.
mkdir -p "$(dirname "$ROOTFS")" "$(dirname "$SRC_IMG")" "$ISO_MOUNT" \
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

# Install the cleanup trap now: every mount/loop from here on is unwound on any exit.
trap cleanup EXIT

# =============================================================================
# 2. Decompress the image, loop-mount its root partition, rsync into $ROOTFS
# =============================================================================
# 2.1 decompress. Reuse an existing expansion ONLY if it is newer than the source
# .img.xz — otherwise a run that repointed $ISO_PATH (e.g. console → GNOME) would
# silently rsync the stale image. On failure, remove the partial output so a later
# run does not "skip" a corrupt image.
if [ -f "$SRC_IMG" ] && [ "$SRC_IMG" -nt "$ISO_PATH" ]; then
    echo "[ROOTFS] Using existing decompressed image ${SRC_IMG}"
else
    echo "[ROOTFS] Decompressing $(basename "$ISO_PATH")"
    if ! xz -dc "$ISO_PATH" > "$SRC_IMG"; then
        rm -f "$SRC_IMG"
        die "Failed to decompress ${ISO_PATH}."
    fi
fi

# 2.2 attach with partition scanning so ${LOOP}p2 appears. losetup -P derives the
# partition table itself — no hardcoded sector offset.
echo "[ROOTFS] Attaching ${SRC_IMG} via loop (with partition scan)"
LOOP="$(losetup -Pf --show "$SRC_IMG")" || die "losetup failed for ${SRC_IMG}."
[ -n "$LOOP" ] || die "losetup returned no device for ${SRC_IMG}."

# 2.3 the ext4 root is the SECOND partition. Confirm the layout dynamically (>=2
# partitions per the table) and that the kernel created the p2 node.
NPART="$(partx -g -o NR "$SRC_IMG" | wc -l)"
[ "$NPART" -ge 2 ] || die "Expected >=2 partitions in ${SRC_IMG}, found ${NPART}."
P2="${LOOP}p2"
[ -b "$P2" ] \
    || die "Root partition ${P2} not found. partx table:
$(partx -o NR,START,SECTORS,TYPE "$SRC_IMG" 2>/dev/null)"

# 2.4 mount the root partition read-only (we only copy out of it).
run_with_check "Mounting pmOS root (p2) read-only" \
    mount -o ro "$P2" "$ISO_MOUNT"

# 2.5 copy the whole root into $ROOTFS with rsync — preserve hardlinks, ACLs,
# xattrs, and numeric ownership (the chroot runs under qemu, so names needn't
# resolve on the host).
run_with_check "Creating rootfs dir" mkdir -p "$ROOTFS"
run_with_check "Copying pmOS root into rootfs (rsync)" \
    rsync -aHAX --numeric-ids "${ISO_MOUNT}/" "${ROOTFS}/"

# 2.6 done with the image — unmount and detach immediately.
run_with_check "Unmounting pmOS root" umount "$ISO_MOUNT"
mountpoint -q "$ISO_MOUNT" && die "p2 still mounted at ${ISO_MOUNT} after umount."
run_with_check "Detaching loop device" losetup -d "$LOOP"
LOOP=""

# 2.7 sanity: the copy must look like a real root filesystem.
for d in "" /usr /etc /sbin; do
    [ -d "${ROOTFS}${d}" ] || die "Copied rootfs missing ${d:-/} — rsync incomplete?"
done
echo "Rootfs copy verified (/, /usr, /etc, /sbin present)."

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
# 4.1 resolv.conf so apk can resolve names inside the chroot.
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

# =============================================================================
# 5. Chroot — pmOS (systemd) configuration for a GNOME graphical session
# =============================================================================
# 5.1 busybox-static: Stage 2 embeds a STATIC aarch64 busybox in the RAM-boot
# initramfs. Alpine ships it via the busybox-static package at /bin/busybox.static.
# Skip if already present; otherwise apk-add it (needs network in the chroot).
if [ -f "${ROOTFS}/bin/busybox.static" ]; then
    echo "[ROOTFS] busybox-static already present"
else
    echo "[ROOTFS] Installing busybox-static via apk"
    if ! in_chroot apk add busybox-static; then
        die "apk add busybox-static failed — needs network inside the chroot, or pre-stage a static busybox at ${ROOTFS}/bin/busybox.static."
    fi
    [ -f "${ROOTFS}/bin/busybox.static" ] \
        || die "apk add busybox-static reported success but ${ROOTFS}/bin/busybox.static is missing."
fi

# 5.1b Disk-install tooling — baked in so the on-device installer (inst-disk,
# run later from the RAM session) is self-sufficient with NO network at install
# time. rsync: clone the rootfs onto the internal disk. grub + grub-efi: the
# arm64-efi GRUB that injects surface.dtb, installed onto the shared internal
# ESP. efibootmgr: create the NVRAM boot entry ahead of Windows Boot Manager.
# (parted / mkfs.ext4 / partprobe are already in the base pmOS image.) apk here
# needs network in the chroot, same as busybox-static above.
echo "[ROOTFS] Installing disk-install tooling (rsync grub grub-efi efibootmgr) via apk"
in_chroot apk add rsync grub grub-efi efibootmgr \
    || die "apk add of disk-install tooling (rsync grub grub-efi efibootmgr) failed — needs network inside the chroot."

# 5.2 root password — kept for recovery/console (the GNOME login is the user below).
echo "[ROOTFS] Setting root password"
printf 'root:%s\n' "$ROOT_PASSWORD" | in_chroot chpasswd \
    || die "Setting root password failed."

# 5.3 hostname.
run_with_check "Setting hostname" \
    tee "${ROOTFS}/etc/hostname" <<<"$TARGET_HOSTNAME"

# 5.4 RAM boot: neutralize the image's own fstab. The rsync'd pmOS root (which
# runs systemd) still lists its original ext4 root, the ESP (/boot, e.g. FAT
# UUID 98A5-E1A0), and TPM devices — none of which exist in a RAM boot. Left in
# place, systemd-remount-fs fails and systemd waits ~90s on each phantom device
# before dropping to emergency.service (sulogin) instead of a console getty.
# Root comes from the initrd overlay, so nothing here needs mounting.
run_with_check "Neutralizing fstab for RAM boot" \
    tee "${ROOTFS}/etc/fstab" <<<"# RAM boot — root provided by initrd overlay; no disk mounts"
# Mask the disk-bound units that would otherwise fail/hang on the absent devices.
in_chroot systemctl mask systemd-remount-fs.service systemd-fsck-root.service \
    2>/dev/null || true

# 5.5 sanity: init must exist for Stage 2's `switch_root /sbin/init`.
[ -e "${ROOTFS}/sbin/init" ] || die "/sbin/init missing in rootfs — not a bootable pmOS root?"

# 5.6 create the GNOME session user. GNOME/mutter refuses to run as root and GDM
# won't do a root graphical login; a RAM boot discards pmOS's own first-boot user
# setup, so no user exists — create one here. Idempotent (skip if it already
# exists). Prefer shadow's useradd (GNOME/accountsservice pulls in shadow); fall
# back to busybox adduser.
if in_chroot id -u "$TARGET_USER" >/dev/null 2>&1; then
    echo "[ROOTFS] User ${TARGET_USER} already exists"
else
    echo "[ROOTFS] Creating user ${TARGET_USER}"
    in_chroot useradd -m -s /bin/bash "$TARGET_USER" \
        || in_chroot adduser -D "$TARGET_USER" \
        || die "Creating user ${TARGET_USER} failed (neither useradd nor adduser worked)."
fi

# 5.6.1 user password.
echo "[ROOTFS] Setting password for ${TARGET_USER}"
printf '%s:%s\n' "$TARGET_USER" "$USER_PASSWORD" | in_chroot chpasswd \
    || die "Setting password for ${TARGET_USER} failed."

# 5.6.2 add the user to each group that ACTUALLY exists. Never `useradd -G` a
# fixed list — it fails wholesale if any group is missing. Add per-group instead,
# guarded by getent, via usermod (shadow) or busybox addgroup. Non-fatal per group.
for g in wheel video audio input netdev plugdev render; do
    in_chroot sh -c "getent group $g >/dev/null 2>&1 || exit 0
        usermod -aG $g $TARGET_USER 2>/dev/null || addgroup $TARGET_USER $g 2>/dev/null || true" \
        || true
done

# 5.7 GDM autologin — boot straight to the GNOME desktop, no greeter, matching the
# console flow's zero-interaction login. Alpine/pmOS GDM reads /etc/gdm/custom.conf
# (the Debian gdm-3 dir does not apply). mkdir -p: the dir may not exist yet.
echo "[ROOTFS] Enabling GDM autologin for ${TARGET_USER}"
mkdir -p "${ROOTFS}/etc/gdm"
cat >"${ROOTFS}/etc/gdm/custom.conf" <<EOF
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=${TARGET_USER}
EOF

# 5.7.1 ensure a graphical boot. Both are almost certainly already set in the GNOME
# image; set them defensively (non-fatal on already-enabled).
in_chroot systemctl set-default graphical.target 2>/dev/null || true
in_chroot systemctl enable gdm 2>/dev/null || true

# 5.8 skip the gnome-initial-setup first-run wizard so it doesn't sit in front of
# the autologin session. Best-effort/non-fatal — autologin works without it.
in_chroot sh -c "install -d -o $TARGET_USER -g $TARGET_USER /home/$TARGET_USER/.config \
    && printf 'yes\n' > /home/$TARGET_USER/.config/gnome-initial-setup-done \
    && chown $TARGET_USER:$TARGET_USER /home/$TARGET_USER/.config/gnome-initial-setup-done" \
    2>/dev/null || true

# =============================================================================
# 6. Cleanup and reporting
# =============================================================================
# 6.1 unmount chroot binds (the trap would also do this; do it now so the size
# report and the leaked-mount check see a clean tree).
echo "[ROOTFS] Unmounting chroot binds"
unmount_all

# Confirm nothing is left mounted under the rootfs.
if findmnt -rno TARGET | grep -q -E "^${ROOTFS}(/|$)"; then
    die "Bind mounts leaked under ${ROOTFS}:
$(findmnt -rno TARGET | grep -E "^${ROOTFS}(/|$)")"
fi

# 6.2 remove the (now-unmounted) source mount point.
rmdir "$ISO_MOUNT" 2>/dev/null || true

# Everything succeeded — disarm the trap so its exit code can't mask success.
trap - EXIT

# 6.3 size summary.
ROOTFS_SIZE="$(du -sh "$ROOTFS" | cut -f1)"

# 6.4 completion message.
echo ""
echo "=============================================="
echo " Rootfs build complete!"
echo "   Tree:    ${ROOTFS}"
echo "   Size:    ${ROOTFS_SIZE}"
echo "   Kernel:  vmlinuz-${REL}  (+ modules, firmware, surface.dtb)"
echo "   Session: GNOME via GDM autologin as ${TARGET_USER} (graphical.target)"
echo "   Login:   ${TARGET_USER} / ${USER_PASSWORD}  (root / ${ROOT_PASSWORD} for console)"
echo "   Host:    ${TARGET_HOSTNAME}"
echo ""
echo " Next: Stage 2 (inst-initrd.sh) packs this tree into rootfs.squashfs"
echo "       and embeds it in the RAM-boot initrd."
echo "=============================================="
