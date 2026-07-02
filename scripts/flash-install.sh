#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# scripts/flash-install.sh — Stage 3: write the bootable RAM-boot install USB.
#
#   Usage:  sudo ./scripts/flash-install.sh <device>       e.g. /dev/sdb
#
# Consumes the Stage 2 artifacts in $OUT (vmlinuz-<release>, surface.dtb,
# sp12-install.initrd) and writes them onto a USB stick that the Surface Pro 12
# boots from firmware into a full GNOME desktop entirely in RAM. The stick is a
# single FAT32 EFI System partition: GRUB (removable) + kernel + DTB + the
# ~3.5 GB OS-in-a-file initrd. The rootfs squashfs is NOT copied — it rides
# inside the initrd.
#
# DESTRUCTIVE: repartitions and reformats <device>. Guarded by block-device,
# not-system-disk, not-mounted, and removable checks (only the removable check
# is overridable, via SP12_ALLOW_NONREMOVABLE=1, for loopback testing).
#
# Partitioning uses parted + wipefs (no gdisk dependency). Runs as root.
# =============================================================================

# --- 0. Path configuration: env.sh is the single source of truth -------------
# shellcheck source=scripts/env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# Fixed knobs for this stage.
KERNEL_RELEASE_FILE="${KERNEL_SRC}/include/config/kernel.release"
ESP_LABEL="SP12BOOT"
GRUB_TARGET="arm64-efi"
GRUB_MODULES_DIR="/usr/lib/grub/${GRUB_TARGET}"
# Base kernel cmdline for the (single) menu entry. No disk-touching flags.
BASE_CMDLINE="console=tty0"

MNT=""   # ESP mountpoint, set once we mount; used by the cleanup trap.

# --- Helpers -----------------------------------------------------------------
die() { echo "ERROR: $*" >&2; exit 1; }

run_with_check() {
    local step_name="$1"; shift
    echo "[FLASH] ${step_name}"
    if ! "$@"; then
        die "'${step_name}' failed (exit code $?)."
    fi
}

# Unmount + remove the ESP mountpoint if we made one. Idempotent; safe from the
# EXIT trap on any exit path.
cleanup() {
    local rc=$?
    if [ -n "${MNT:-}" ] && mountpoint -q "$MNT"; then
        umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true
    fi
    [ -n "${MNT:-}" ] && [ -d "$MNT" ] && rmdir "$MNT" 2>/dev/null || true
    exit "$rc"
}

# Copy src → dst then byte-verify. A truncated 3.5 GB initrd would boot to
# nothing, so a bad/full stick must fail here, not on the Surface.
copy_verify() {
    local src="$1" dst="$2"
    run_with_check "Copying $(basename "$src")" cp "$src" "$dst"
    cmp -s "$src" "$dst" || die "Verify failed: ${dst} differs from ${src} (bad or full media?)."
}

# =============================================================================
# 1. Arguments and prerequisites
# =============================================================================
echo "=============================================="
echo " Surface Pro 12 install USB (Stage 3)"
echo "=============================================="

DEV="${1:-}"
[ -n "$DEV" ] || die "Usage: $0 <device>   (e.g. /dev/sdb — the whole disk, not a partition)"

# Must be root: partition/format/mount/grub-install all require it.
[ "$(id -u)" -eq 0 ] || die "This script must be run as root (partition/format/mount/grub-install)."

# 1.3 kernel release string → names the kernel file we look for and boot.
[ -f "$KERNEL_RELEASE_FILE" ] || die "Kernel release file not found at ${KERNEL_RELEASE_FILE}."
REL="$(<"$KERNEL_RELEASE_FILE")"
[ -n "$REL" ] || die "Empty kernel release string in ${KERNEL_RELEASE_FILE}."

# 1.4 Stage 2 artifacts.
VMLINUZ_SRC="${OUT}/vmlinuz-${REL}"
DTB_SRC="${OUT}/surface.dtb"
INITRD_SRC="${OUT}/sp12-install.initrd"
for f in "$VMLINUZ_SRC" "$DTB_SRC" "$INITRD_SRC"; do
    [ -f "$f" ] || die "Stage 2 artifact missing: ${f} (run inst-initrd.sh first)."
done

# 1.5 host tools (parted + wipefs for partitioning; no gdisk).
for t in parted wipefs mkfs.vfat grub-install partprobe cmp; do
    command -v "$t" >/dev/null || die "Required tool '${t}' not found on PATH."
done
# 1.6 arm64-efi GRUB modules (grub-efi-arm64-bin), needed by grub-install --target.
[ -d "$GRUB_MODULES_DIR" ] \
    || die "GRUB ${GRUB_TARGET} modules not found at ${GRUB_MODULES_DIR} — install grub-efi-arm64-bin."

# =============================================================================
# 2. Destructive-target safety guards
# =============================================================================
# 2.1 must be a block device.
[ -b "$DEV" ] || die "${DEV} is not a block device."

# Kernel name of the target (e.g. sdb, nvme0n1, loop0) and its type.
DEV_KNAME="$(lsblk -ndo KNAME "$DEV")"
DEV_TYPE="$(lsblk -ndo TYPE "$DEV")"
[ "$DEV_TYPE" = "disk" ] || [ "$DEV_TYPE" = "loop" ] \
    || die "${DEV} is a ${DEV_TYPE}, not a whole disk. Pass the disk (e.g. /dev/sdb), not a partition."

# 2.2 refuse the disk backing / or the project tree.
protect=""
for p in / "$PROJECT_DIR"; do
    src="$(findmnt -no SOURCE --target "$p" 2>/dev/null || true)"
    [ -n "$src" ] || continue
    pk="$(lsblk -ndo PKNAME "$src" 2>/dev/null || true)"   # parent disk of a partition
    sk="$(lsblk -ndo KNAME  "$src" 2>/dev/null || true)"   # or the source itself
    protect="${protect} ${pk} ${sk}"
done
for d in $protect; do
    [ "$d" = "$DEV_KNAME" ] \
        && die "Refusing: ${DEV} (${DEV_KNAME}) backs the running system or the project tree."
done

# 2.3 no partition of the target may be mounted.
if lsblk -nro MOUNTPOINT "$DEV" 2>/dev/null | grep -q '[^[:space:]]'; then
    die "${DEV} has mounted partition(s):
$(lsblk -nro NAME,MOUNTPOINT "$DEV" | awk 'NF>1')
Unmount them first."
fi

# 2.4 removable, unless explicitly overridden (loopback testing).
removable="$(cat "/sys/block/${DEV_KNAME}/removable" 2>/dev/null || echo 0)"
if [ "$removable" != "1" ] && [ "${SP12_ALLOW_NONREMOVABLE:-}" != "1" ]; then
    die "${DEV} (${DEV_KNAME}) is not removable. Refusing.
Set SP12_ALLOW_NONREMOVABLE=1 to override (e.g. for a loopback test device)."
fi

# 2.5 partition node: nvme/mmc/loop end in a digit → need a 'p' separator.
case "$DEV" in
    *[0-9]) PART="${DEV}p1" ;;
    *)      PART="${DEV}1" ;;
esac

echo "Target: ${DEV} (${DEV_KNAME}), partition ${PART}. Prerequisites OK."
echo ">>> This ERASES ${DEV}. <<<"

# =============================================================================
# 3. Partition and format
# =============================================================================
# 3.1 clear any stale partition-table / filesystem signatures.
run_with_check "Wiping old signatures on ${DEV}" wipefs -a "$DEV"

# 3.2 GPT + one EFI System partition spanning the disk (esp flag sets the type).
run_with_check "Creating GPT + EFI System partition" \
    parted -s "$DEV" mklabel gpt mkpart "$ESP_LABEL" fat32 1MiB 100% set 1 esp on

# 3.3 make the kernel re-read the table and wait for the partition node.
run_with_check "Re-reading partition table" partprobe "$DEV"
udevadm settle 2>/dev/null || true
for _ in $(seq 1 20); do [ -b "$PART" ] && break; sleep 0.5; done
[ -b "$PART" ] || die "Partition ${PART} did not appear after partprobe."

# 3.4 FAT32 — the only filesystem UEFI is guaranteed to read.
run_with_check "Formatting ${PART} as FAT32" mkfs.vfat -F 32 -n "$ESP_LABEL" "$PART"

# =============================================================================
# 4. Copy and byte-verify payload
# =============================================================================
MNT="$(mktemp -d)"
trap cleanup EXIT
run_with_check "Mounting ESP" mount "$PART" "$MNT"

copy_verify "$VMLINUZ_SRC" "${MNT}/vmlinuz-${REL}"
copy_verify "$DTB_SRC"     "${MNT}/surface.dtb"
copy_verify "$INITRD_SRC"  "${MNT}/sp12-install.initrd"
# NB: rootfs.squashfs is deliberately NOT copied — it rides inside the initrd.

# =============================================================================
# 5. Install GRUB (removable) and write the single-entry grub.cfg
# =============================================================================
run_with_check "Installing GRUB (${GRUB_TARGET}, removable)" \
    grub-install --removable --target="$GRUB_TARGET" \
        --efi-directory="$MNT" --boot-directory="${MNT}/boot"
[ -f "${MNT}/EFI/BOOT/BOOTAA64.EFI" ] \
    || die "grub-install did not produce ${MNT}/EFI/BOOT/BOOTAA64.EFI."

# One entry only: RAM boot, no disk-touching flags. Paths are relative to the
# ESP (GRUB's $root). Only ${REL}/${BASE_CMDLINE} expand — there are no GRUB
# $-tokens in this cfg, so the unquoted heredoc is safe.
echo "[FLASH] Writing grub.cfg (single 'Try in RAM' entry)"
mkdir -p "${MNT}/boot/grub"
cat > "${MNT}/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=5

menuentry "Try in RAM (no disk changes)" {
    insmod part_gpt
    insmod fat
    insmod linux
    insmod fdt
    linux /vmlinuz-${REL} ${BASE_CMDLINE}
    devicetree /surface.dtb
    initrd /sp12-install.initrd
}
EOF

# =============================================================================
# 6. Finish
# =============================================================================
run_with_check "Syncing" sync
run_with_check "Unmounting ESP" umount "$MNT"
rmdir "$MNT" 2>/dev/null || true
MNT=""
trap - EXIT   # success — disarm so the trap's exit code can't mask it

echo ""
echo "=============================================="
echo " Install USB ready on ${DEV}!"
echo "   Partition:  ${PART}  (FAT32, ${ESP_LABEL})"
echo "   Boot:       GRUB removable (EFI/BOOT/BOOTAA64.EFI)"
echo "   Entry:      Try in RAM  →  vmlinuz-${REL} + surface.dtb + sp12-install.initrd"
echo ""
echo " On the Surface: ensure Secure Boot is OFF, then boot this USB."
echo " It loads the whole OS into RAM; the internal disk is never touched."
echo "=============================================="
