#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# scripts/inst-initrd.sh — Stage 2: pack the RAM-boot payload.
#
# Consumes the Stage 1 rootfs tree ($ROOTFS = $BUILD/inst/root) and produces,
# under $OUT ($BUILD/inst/out):
#
#   rootfs.squashfs      the full rootfs, mksquashfs -comp gzip -b 1M
#   sp12-install.initrd  an UNCOMPRESSED newc cpio that CARRIES that squashfs
#                        plus a static aarch64 busybox, overlay.ko, and /init —
#                        an "OS-in-a-file" initramfs GRUB loads into RAM in one
#                        shot, after which Linux never reads USB again.
#   vmlinuz-<release>    kernel + DTB copied out for the Stage 3 ESP.
#   surface.dtb
#
# Runs as root (mknod + faithful root:root ownership in the squashfs/cpio).
# gzip is mandatory for the squashfs: the 7.2 kernel this boots under supports
# only the ZLIB squashfs decompressor at the RAM lower layer.
# =============================================================================

# --- 0. Path configuration: env.sh is the single source of truth -------------
# shellcheck source=scripts/env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# Fixed knobs for this stage.
KERNEL_RELEASE_FILE="${KERNEL_SRC}/include/config/kernel.release"
STAGING="${BUILD}/inst/initramfs"               # scratch tree cpio'd into the initrd
SQUASHFS="${OUT}/rootfs.squashfs"
INITRD="${OUT}/sp12-install.initrd"
# A statically-linked aarch64 busybox for the initramfs. Alpine/pmOS ships it via
# the busybox-static package at /bin/busybox.static (musl, static), so prefer that;
# fall back to /usr/bin/busybox (Debian/Ubuntu busybox-static). Alpine's plain
# /bin/busybox is musl-*dynamic* and would fail the static check below. Override
# with BUSYBOX=/path if needed. Verified static+aarch64 below, so a wrong binary
# aborts loudly rather than producing an unbootable initramfs.
if   [ -n "${BUSYBOX:-}" ];                 then :   # caller-provided, honored as-is
elif [ -f "${ROOTFS}/bin/busybox.static" ]; then BUSYBOX="${ROOTFS}/bin/busybox.static"
else                                             BUSYBOX="${ROOTFS}/usr/bin/busybox"
fi
# Applets /init needs, symlinked to /bin/busybox (plus a few for the rescue shell).
APPLETS=(sh mount umount insmod losetup switch_root mkdir ls cat)
# Hard cap: newc cpio AND FAT32 each cap a single file at 4 GiB.
FOUR_GIB=$((4 * 1024 * 1024 * 1024))            # 4294967296
CPIO_OVERHEAD=$((16 * 1024 * 1024))             # busybox+overlay.ko+cpio headers

# --- Helpers -----------------------------------------------------------------
die() { echo "ERROR: $*" >&2; exit 1; }

run_with_check() {
    local step_name="$1"; shift
    echo "[INITRD] ${step_name}"
    if ! "$@"; then
        die "'${step_name}' failed (exit code $?)."
    fi
}

# Remove the scratch staging tree, but only if it is exactly the expected path
# (never rm -rf an unexpected location). Safe to call from the EXIT trap.
cleanup_staging() {
    case "$STAGING" in
        "${PROJECT_DIR}/build/inst/initramfs")
            [ -e "$STAGING" ] && rm -rf "$STAGING" || true ;;
        *) : ;;
    esac
}
cleanup() { local rc=$?; cleanup_staging; exit "$rc"; }

# =============================================================================
# 1. Verify prerequisites
# =============================================================================
echo "=============================================="
echo " Surface Pro 12 RAM-boot payload (Stage 2)"
echo "=============================================="

# Root: mknod for device nodes + faithful ownership in the squashfs/cpio.
[ "$(id -u)" -eq 0 ] || die "This script must be run as root (mknod + squashfs/cpio ownership)."

# 1.7 host tools.
command -v mksquashfs >/dev/null || die "mksquashfs not found (install squashfs-tools)."
command -v cpio       >/dev/null || die "cpio not found (install cpio)."

# 1.1 rootfs tree exists and is non-empty.
[ -d "$ROOTFS" ] || die "Rootfs tree not found at ${ROOTFS} (run inst-rootfs.sh first)."
[ -n "$(ls -A "$ROOTFS" 2>/dev/null)" ] || die "Rootfs tree at ${ROOTFS} is empty."

# 1.8 top-level permission sanity — the real footgun is unsquashfs -f leaving
# /, /usr, /etc as 700 (owner-only), which kills every non-root service. Require
# group AND other to keep read+execute; benign variants like 775 pass.
for d in "" /usr /etc; do
    mode="$(stat -c '%a' "${ROOTFS}${d}")"; mode="${mode: -3}"   # drop any setuid/gid/sticky digit
    g="${mode:1:1}"; o="${mode:2:1}"
    (( (g & 5) == 5 && (o & 5) == 5 )) \
        || die "Bad permissions on ${ROOTFS}${d}: ${mode} is not group+other traversable (unsquashfs -f corruption?)."
done

# 1.2 kernel release string.
[ -f "$KERNEL_RELEASE_FILE" ] || die "Kernel release file not found at ${KERNEL_RELEASE_FILE}."
REL="$(<"$KERNEL_RELEASE_FILE")"
[ -n "$REL" ] || die "Empty kernel release string in ${KERNEL_RELEASE_FILE}."
echo "Kernel release: ${REL}"

# 1.3 kernel image for the ESP — prefer the one Stage 1 injected, fall back to
# the raw build product.
if   [ -f "${ROOTFS}/boot/vmlinuz-${REL}" ]; then
    VMLINUZ_SRC="${ROOTFS}/boot/vmlinuz-${REL}"
elif [ -f "${KERNEL_SRC}/arch/arm64/boot/Image" ]; then
    VMLINUZ_SRC="${KERNEL_SRC}/arch/arm64/boot/Image"
else
    die "Kernel image not found (${ROOTFS}/boot/vmlinuz-${REL} or ${KERNEL_SRC}/arch/arm64/boot/Image)."
fi

# 1.4 overlay module (may be compressed) somewhere under the modules tree.
OVERLAY_SRC="$(find "${ROOTFS}/lib/modules/${REL}" -name 'overlay.ko*' -print -quit 2>/dev/null || true)"
[ -n "$OVERLAY_SRC" ] \
    || die "overlay.ko not found under ${ROOTFS}/lib/modules/${REL} (needed pre-switch_root)."

# 1.5 static busybox (defaults to the rootfs's busybox-static binary).
[ -f "$BUSYBOX" ] || die "busybox not found at ${BUSYBOX} (rootfs missing busybox-static?). Set BUSYBOX=/path to override."

# 1.6 Surface DTB for the ESP.
DTB_SRC="${ROOTFS}/boot/surface.dtb"
[ -f "$DTB_SRC" ] || die "surface.dtb not found at ${DTB_SRC}."

echo "Prerequisites OK."
mkdir -p "$OUT" || die "Cannot create output dir ${OUT}."

# Clean any stale staging tree up front, and unwind it on any exit hereafter.
cleanup_staging
trap cleanup EXIT

# =============================================================================
# 2. Pack the rootfs squashfs (gzip, 1 MiB blocks)
# =============================================================================
# 2.1 exclude the ISO's stale 7.0 qcom kernel + initrd (dead weight — RAM boot
# uses the ESP's initrd, not one inside the squashfs). Excludes keep $ROOTFS
# pristine; everything under boot/ except our injected vmlinuz-<release> is cut.
STALE_EXCLUDES=()
shopt -s nullglob
for f in "${ROOTFS}"/boot/vmlinuz-* "${ROOTFS}"/boot/initrd.img-* \
         "${ROOTFS}"/boot/initramfs-* "${ROOTFS}"/boot/initrd-*; do
    base="$(basename "$f")"
    [ "$base" = "vmlinuz-${REL}" ] && continue
    STALE_EXCLUDES+=("boot/${base}")
done
shopt -u nullglob

MKSQ=(mksquashfs "$ROOTFS" "$SQUASHFS" -comp gzip -b 1M -noappend)
if [ "${#STALE_EXCLUDES[@]}" -gt 0 ]; then
    echo "[INITRD] Excluding stale boot artifacts: ${STALE_EXCLUDES[*]}"
    MKSQ+=(-e "${STALE_EXCLUDES[@]}")
fi
run_with_check "Packing rootfs.squashfs (gzip -b 1M)" "${MKSQ[@]}"

# 2.3 verify compression + block size actually landed as gzip/1 MiB.
SQ_INFO="$(unsquashfs -s "$SQUASHFS")"
grep -qi 'Compression gzip' <<<"$SQ_INFO" \
    || die "rootfs.squashfs is not gzip-compressed — the 7.2 kernel can only mount ZLIB at this layer."
grep -q 'Block size 1048576' <<<"$SQ_INFO" \
    || die "rootfs.squashfs block size is not 1048576 (expected -b 1M)."

# 2.1 (verify) stale qcom kernel gone, injected kernel present.
SQ_LIST="$(unsquashfs -l "$SQUASHFS")"
grep -qi 'boot/vmlinuz-.*qcom' <<<"$SQ_LIST" \
    && die "Stale qcom kernel still present inside the squashfs."
grep -q "boot/vmlinuz-${REL}\$" <<<"$SQ_LIST" \
    || die "Injected boot/vmlinuz-${REL} is missing from the squashfs."

SQ_SIZE="$(stat -c%s "$SQUASHFS")"
echo "[INITRD] rootfs.squashfs = ${SQ_SIZE} bytes"

# =============================================================================
# 3. Size guard (pre-cpio): fail fast before assembling a too-large initrd
# =============================================================================
if [ "$((SQ_SIZE + CPIO_OVERHEAD))" -ge "$FOUR_GIB" ]; then
    die "squashfs (${SQ_SIZE} B) + overhead would meet/exceed the 4 GiB initrd cap (${FOUR_GIB} B).
Shrink the rootfs before continuing (newc cpio and FAT32 both cap a file at 4 GiB)."
fi

# =============================================================================
# 4. Assemble the initramfs staging tree
# =============================================================================
run_with_check "Creating staging tree" \
    mkdir -p "${STAGING}/bin" "${STAGING}/dev" "${STAGING}/proc" "${STAGING}/sys" \
             "${STAGING}/mnt/squash" "${STAGING}/mnt/overlay" "${STAGING}/mnt/root"

# 4.3 busybox MUST be statically linked and aarch64, or the initramfs dies
# before the rootfs is mounted (nothing to satisfy a dynamic loader).
BB_INFO="$(file -L "$BUSYBOX")"
grep -q 'aarch64' <<<"$BB_INFO" \
    || die "busybox at ${BUSYBOX} is not an aarch64 ELF: ${BB_INFO}"
grep -Eq 'statically linked|static-pie linked' <<<"$BB_INFO" \
    || die "busybox at ${BUSYBOX} is not statically linked: ${BB_INFO}"
install -m 0755 "$BUSYBOX" "${STAGING}/bin/busybox"

# 4.4 applet symlinks → /bin/busybox (absolute; resolved in the initramfs root).
for a in "${APPLETS[@]}"; do
    ln -sf /bin/busybox "${STAGING}/bin/${a}"
done

# 4.5 overlay.ko, decompressed — busybox insmod cannot load a compressed module.
# Direct commands (not run_with_check) so the `>` redirect is honored.
echo "[INITRD] Preparing overlay.ko from ${OVERLAY_SRC##*/}"
case "$OVERLAY_SRC" in
    *.ko.zst) zstd -d -q -c "$OVERLAY_SRC" > "${STAGING}/overlay.ko" || die "zstd -d overlay.ko failed." ;;
    *.ko.gz)  gzip -d    -c "$OVERLAY_SRC" > "${STAGING}/overlay.ko" || die "gzip -d overlay.ko failed." ;;
    *.ko.xz)  xz   -d    -c "$OVERLAY_SRC" > "${STAGING}/overlay.ko" || die "xz -d overlay.ko failed." ;;
    *.ko)     cp "$OVERLAY_SRC" "${STAGING}/overlay.ko" || die "copy overlay.ko failed." ;;
    *)        die "Unrecognized overlay module extension: ${OVERLAY_SRC}" ;;
esac
OV_INFO="$(file "${STAGING}/overlay.ko")"
grep -q 'ELF' <<<"$OV_INFO" \
    || die "overlay.ko is not an uncompressed ELF after decompression: ${OV_INFO}"

# 4.6 static device nodes so kernel/init (and the rescue shell) have a console
# before devtmpfs is mounted.
run_with_check "Creating /dev/console" mknod -m 600 "${STAGING}/dev/console" c 5 1
run_with_check "Creating /dev/null"    mknod -m 666 "${STAGING}/dev/null"    c 1 3

# 4.7 the squashfs rides inside the initramfs. Hardlink (same filesystem under
# $BUILD) to avoid a second 3.5 GB copy; fall back to cp across devices.
if ! ln "$SQUASHFS" "${STAGING}/rootfs.squashfs" 2>/dev/null; then
    run_with_check "Copying squashfs into staging" cp "$SQUASHFS" "${STAGING}/rootfs.squashfs"
fi

# 4.8 /init — the ~40-line RAM-pivot. Single-quoted heredoc: NOTHING here is
# expanded by the build host; it runs on the Surface under busybox sh.
cat > "${STAGING}/init" <<'INIT_EOF'
#!/bin/busybox sh
# RAM-boot init: mount the squashfs carried in this initramfs, stack a writable
# tmpfs overlay, hand the pseudo-filesystems over, and switch_root into Ubuntu.
export PATH=/bin

rescue() {
    echo ""
    echo "!!! sp12 RAM-boot init failed: $*"
    echo "!!! dropping to an interactive rescue shell."
    exec /bin/busybox sh
}

# Belt-and-braces: (re)install applet symlinks in case any are missing.
/bin/busybox --install -s /bin 2>/dev/null

mount -t proc     proc /proc || rescue "mount /proc"
mount -t sysfs    sys  /sys  || rescue "mount /sys"
mount -t devtmpfs dev  /dev  || rescue "mount /dev"

insmod /overlay.ko || rescue "insmod /overlay.ko"

# Lower (read-only): the squashfs living in the RAM-resident initramfs.
if ! mount -t squashfs -o ro,loop /rootfs.squashfs /mnt/squash 2>/dev/null; then
    losetup /dev/loop0 /rootfs.squashfs        || rescue "losetup /rootfs.squashfs"
    mount -t squashfs -o ro /dev/loop0 /mnt/squash || rescue "mount squashfs (losetup)"
fi

# Upper (writable): tmpfs (defaults to 50% RAM).
mount -t tmpfs tmpfs /mnt/overlay || rescue "mount tmpfs upper"
mkdir -p /mnt/overlay/upper /mnt/overlay/work || rescue "mkdir upper/work"

# Stack them: read-only OS image, all writes captured in RAM.
mount -t overlay overlay \
    -o lowerdir=/mnt/squash,upperdir=/mnt/overlay/upper,workdir=/mnt/overlay/work \
    /mnt/root || rescue "mount overlay -> /mnt/root"

# Move the pseudo-filesystems so systemd finds them already there.
mount --move /proc /mnt/root/proc || rescue "move /proc"
mount --move /sys  /mnt/root/sys  || rescue "move /sys"
mount --move /dev  /mnt/root/dev  || rescue "move /dev"

exec switch_root /mnt/root /sbin/init
rescue "switch_root returned"
INIT_EOF
chmod 0755 "${STAGING}/init"

# =============================================================================
# 5. Pack the initramfs — UNCOMPRESSED newc cpio (the squashfs is already
#    compressed, so gzip-ing the cpio burns boot CPU for ~no size win)
# =============================================================================
echo "[INITRD] Packing ${INITRD} (newc, uncompressed)"
( cd "$STAGING" && find . -print0 | cpio --null --create --format=newc --quiet ) > "$INITRD" \
    || die "cpio packing failed."

# 5.2 sanity: the members that matter are actually in there. cpio may list
# names with or without a leading "./" (version-dependent), so strip it and
# match plain paths.
CPIO_LIST="$(cpio -it < "$INITRD" 2>/dev/null | sed 's#^\./##' || true)"
for member in init bin/busybox overlay.ko rootfs.squashfs dev/console; do
    grep -qxF "$member" <<<"$CPIO_LIST" \
        || die "initrd is missing member: ${member}"
done

# =============================================================================
# 6. Size guard (post-cpio) + copy out the ESP artifacts
# =============================================================================
INITRD_SIZE="$(stat -c%s "$INITRD")"
if [ "$INITRD_SIZE" -ge "$FOUR_GIB" ]; then
    die "initrd is ${INITRD_SIZE} B, at/over the 4 GiB cap (${FOUR_GIB} B) — GRUB/FAT32 cannot carry it."
fi

run_with_check "Copying kernel to OUT" cp "$VMLINUZ_SRC" "${OUT}/vmlinuz-${REL}"
run_with_check "Copying DTB to OUT"    cp "$DTB_SRC"     "${OUT}/surface.dtb"
cmp -s "$VMLINUZ_SRC" "${OUT}/vmlinuz-${REL}" || die "vmlinuz copy differs from source."
cmp -s "$DTB_SRC"     "${OUT}/surface.dtb"    || die "surface.dtb copy differs from source."

# =============================================================================
# 7. Cleanup and reporting
# =============================================================================
cleanup_staging
trap - EXIT   # success — disarm so the trap's exit code can't mask it

HEADROOM=$((FOUR_GIB - INITRD_SIZE))
echo ""
echo "=============================================="
echo " RAM-boot payload complete!"
echo "   Output dir:    ${OUT}"
printf "   squashfs:      %s bytes (%s)\n" "$SQ_SIZE"     "$(numfmt --to=iec "$SQ_SIZE")"
printf "   initrd:        %s bytes (%s)\n" "$INITRD_SIZE" "$(numfmt --to=iec "$INITRD_SIZE")"
printf "   4 GiB headroom:%s bytes (%s)\n" "$HEADROOM"    "$(numfmt --to=iec "$HEADROOM")"
echo "   kernel + dtb:  vmlinuz-${REL}, surface.dtb"
echo ""
echo " RAM budget: ~7 GB boot-time peak (kernel holds the initramfs while"
echo "   unpacking) settling to ~3.5 GB resident — comfortable on 16 GB."
echo ""
echo " Next: Stage 3 (flash-install.sh /dev/sdX) writes these to the install USB."
echo "=============================================="
