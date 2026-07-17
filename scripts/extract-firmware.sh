#!/bin/sh
set -eu

# =============================================================================
# extract-firmware.sh — pull Qualcomm firmware blobs out of a device's own Windows
# install into an out directory, laid out like /lib/firmware.
#
#   Usage (run ON the device — e.g. from the pmOS session):
#       Mount the Windows partition read-only first, then point --windows at it:
#
#       sudo apk add ntfs-3g       
#       sudo mkdir -p /mnt/win    
#       sudo mount -t ntfs-3g -r /dev/sda3 /mnt/win
#
#       ./extract-firmware.sh --windows /mnt/win             # -> ./out/
#       ./extract-firmware.sh --windows /mnt/win --dry-run   # report only
#
# =============================================================================

# The firmware-name properties from the Surface Pro 12 device tree.
# Regenerate if the DT's firmware-name list ever changes:
#   dtc -I dtb -O dts surface.dtb | awk '/firmware-name/{p=1} p{b=b$0} p&&/;/{print b;b="";p=0}' \
#     | grep -oE '"[^"]*"' | tr -d '"' | sort -u
DT_FIRMWARE="qcom/x1p42100/Microsoft/Surface12/adsp_dtbs.elf
qcom/x1p42100/Microsoft/Surface12/cdsp_dtbs.elf
qcom/x1p42100/Microsoft/Surface12/qcadsp8380.mbn
qcom/x1p42100/Microsoft/Surface12/qccdsp8380.mbn
qcom/x1p42100/Microsoft/Surface12/qcdxkmsucpurwa.mbn
qcom/x1p42100/Microsoft/Surface12/qcvss8380_pa.mbn"

# Blobs the device needs but the DT doesn't name: pd-mapper configs, in the same
# dir as the ADSP/CDSP firmware.
EXTRA_FIRMWARE="qcom/x1p42100/Microsoft/Surface12/adspr.jsn
qcom/x1p42100/Microsoft/Surface12/adsps.jsn
qcom/x1p42100/Microsoft/Surface12/adspua.jsn
qcom/x1p42100/Microsoft/Surface12/cdspr.jsn
qcom/x1p42100/Microsoft/Surface12/battmgr.jsn"

FIRMWARE="${DT_FIRMWARE}
${EXTRA_FIRMWARE}"

DEST="${PWD}/out"       # output folder, created where the script is run
WINDOWS=""              # mounted Windows root
DRY_RUN=0

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[EXTRACT] $*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --windows) WINDOWS="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        *) die "Unknown argument: $1" ;;
    esac
done

echo "=============================================="
echo " Pull firmware from the Windows install"
echo "=============================================="

for t in find cp basename dirname; do
    command -v "$t" >/dev/null || die "Required tool '${t}' not found."
done

# --- Resolve the Windows root ------------------------------------------------
# The caller mounts Windows read-only and points --windows at it. Read-only:
# this is someone's real Windows install; never write to it.
[ -n "$WINDOWS" ] || die "Pass --windows DIR pointing at the mounted Windows root, e.g.:
       mount -t ntfs3 -r /dev/disk/by-label/Windows /mnt/win     (or -t ntfs-3g if
       ntfs3 is not in your kernel: apk add ntfs-3g)
       ./extract-firmware.sh --windows /mnt/win"
[ -d "$WINDOWS" ] || die "--windows path is not a directory: $WINDOWS"

REPO="${WINDOWS}/Windows/System32/DriverStore/FileRepository"
[ -d "$REPO" ] || die "DriverStore not found at: $REPO
       That path is not a Windows system root."

FW_DIR="${DEST}/firmware"
log "Using mounted Windows root: $WINDOWS"
[ "$DRY_RUN" -eq 1 ] && log "--dry-run: nothing will be written"

# --- Copy each firmware file out of the DriverStore --------------------------
# The DriverStore may keep several driver-package versions; -exec ls -t picks the
# newest match. Files Windows lacks are warned about, not fatal.
found=0
missing=
for rel in $FIRMWARE; do
    src="$(find "$REPO" -name "$(basename "$rel")" -exec ls -t {} + 2>/dev/null | head -n1)"
    if [ -z "$src" ]; then
        missing="${missing}${rel}
"
        continue
    fi
    found=1
    if [ "$DRY_RUN" -eq 1 ]; then
        log "would pull ${rel}"
        continue
    fi
    dst="${FW_DIR}/${rel}"
    mkdir -p "$(dirname "$dst")"
    cp -f "$src" "$dst"
    chmod 0644 "$dst"
    log "pulled ${rel}"
done

if [ -n "$missing" ]; then
    echo
    log "WARNING: not found in the Windows DriverStore:"
    printf '           %s\n' $missing
    log "Those drivers may not be installed in Windows, or use a different name."
fi

[ "$found" -eq 1 ] || die "Nothing found to pull."
[ "$DRY_RUN" -eq 1 ] && exit 0

echo
echo "=============================================="
echo " Firmware written to ${DEST}"
echo ""
echo " Firmware tree (laid out like /lib/firmware):"
echo "     ${FW_DIR}"
echo " Merge it into the from-device bucket:"
echo "     cp -a ${FW_DIR}/. /path/to/surface-pro-12/firmware/from-device/firmware/"
echo "=============================================="
