#!/bin/bash
set -euo pipefail

# =============================================================================
# scripts/build-kernel.sh — Stage 1: cross-compile the Linux kernel for ARM64.
#
# Configures and compiles a kernel from the KERNEL_SRC tree with Surface Pro 12
# specific drivers (Surface Aggregator, Surface HID, squashfs decompressors,
# ACPI, Snapdragon serial). Outputs live exclusively in the kernel source tree
#
# Cross-compiles from a Debian amd64 host targeting Snapdragon X (ARM64).
# =============================================================================

# --- 0.1 Path configuration: env.sh is the single source of truth ---
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/env.sh"

CROSS_COMPILE="aarch64-linux-gnu-"

# --- Helpers -----------------------------------------------------------------
run_with_check() {
    local step_name="$1"
    shift
    echo "[BUILD] ${step_name}"
    if ! "$@"; then
        echo "ERROR: '${step_name}' failed (exit code $?)."
        exit 1
    fi
}

# --- 2.1 Verify kernel source ---
verify_kernel_source() {
    if [ ! -f "${KERNEL_SRC}/Makefile" ]; then
        echo "ERROR: Kernel source not found at ${KERNEL_SRC}"
        echo "       Expected a valid kernel tree with a Makefile."
        echo "       Ensure the 'linux/' symlink or directory points to a kernel source tree."
        exit 1
    fi
    echo "Kernel source verified: ${KERNEL_SRC}"
}

# --- 2.2 Check/install toolchain ---
install_toolchain() {
    if command -v aarch64-linux-gnu-gcc &>/dev/null; then
        echo "Cross-toolchain already available: $(aarch64-linux-gnu-gcc --version | head -1)"
        return
    fi
    echo "Cross-toolchain not found. Installing gcc-aarch64-linux-gnu..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get update && sudo apt-get install -y gcc-aarch64-linux-gnu
    else
        echo "ERROR: apt-get not found. Please install 'gcc-aarch64-linux-gnu' manually."
        exit 1
    fi
    echo "Toolchain installed successfully."
}

# --- 8.x Force config options using paths anchored to KERNEL_SRC ---
force_config_symbols() {
    echo "--- Forcing required config options ---"

    # 8.2 Squashfs decompressors (needed for Ubuntu snaps)
    for sym in CONFIG_SQUASHFS_LZO CONFIG_SQUASHFS_XZ CONFIG_SQUASHFS_ZSTD CONFIG_SQUASHFS_LZ4 CONFIG_SQUASHFS_ZLIB; do
        run_with_check "Enabling $sym" \
            "$KERNEL_SRC/scripts/config" --file "$KERNEL_SRC/.config" -e "$sym"
    done

    # 8.3 Surface Aggregator (SSAM) — EC, bus, registry, hub, tablet switch
    for sym in CONFIG_SURFACE_AGGREGATOR CONFIG_SURFACE_AGGREGATOR_BUS CONFIG_SURFACE_AGGREGATOR_REGISTRY CONFIG_SURFACE_AGGREGATOR_HUB CONFIG_SURFACE_AGGREGATOR_TABLET_SWITCH; do
        run_with_check "Enabling $sym" \
            "$KERNEL_SRC/scripts/config" --file "$KERNEL_SRC/.config" -e "$sym"
    done

    # 8.4 Surface HID — core and driver
    for sym in CONFIG_SURFACE_HID CONFIG_SURFACE_HID_CORE; do
        run_with_check "Enabling $sym" \
            "$KERNEL_SRC/scripts/config" --file "$KERNEL_SRC/.config" -e "$sym"
    done

    # 8.5 Compressed firmware loading
    for sym in CONFIG_FW_LOADER_COMPRESS CONFIG_FW_LOADER_COMPRESS_ZSTD; do
        run_with_check "Enabling $sym" \
            "$KERNEL_SRC/scripts/config" --file "$KERNEL_SRC/.config" -e "$sym"
    done

    # 8.6 Internal UFS storage built-in — root-on-disk with no initramfs.
    for sym in CONFIG_SCSI CONFIG_BLK_DEV_SD CONFIG_SCSI_UFSHCD \
               CONFIG_SCSI_UFSHCD_PLATFORM CONFIG_SCSI_UFS_QCOM \
               CONFIG_PHY_QCOM_QMP CONFIG_PHY_QCOM_QMP_UFS CONFIG_EXT4_FS; do
        run_with_check "Enabling $sym" \
            "$KERNEL_SRC/scripts/config" --file "$KERNEL_SRC/.config" -e "$sym"
    done

    # 8.7 Normalize config: resolve dependency constraints
    run_with_check "Running olddefconfig to normalize .config" \
        make -C "$KERNEL_SRC" \
             ARCH=arm64 \
             CROSS_COMPILE="${CROSS_COMPILE}" \
             olddefconfig
    echo "Config normalized."
}

# --- 9.x Verify config overrides ---
verify_config() {
    echo ""
    echo "--- Verifying required config overrides ---"
    CONFIG_FILE="${KERNEL_SRC}/.config"
    MISSING_SYMBOLS=()

    for symbol in "${REQUIRED_SYMBOLS[@]}"; do
        if ! grep -q "^${symbol}$" "$CONFIG_FILE"; then
            MISSING_SYMBOLS+=("$symbol")
        fi
    done

    if [ ${#MISSING_SYMBOLS[@]} -gt 0 ]; then
        echo "ERROR: The following required symbols are missing or not set to =y in the final .config:"
        for sym in "${MISSING_SYMBOLS[@]}"; do
            echo "  - ${sym}"
        done
        echo ""
        echo "This is a build failure — the kernel is missing required drivers."
        echo "Squashfs decompressors are needed for Ubuntu snaps."
        echo "Surface Aggregator/HID are needed for Type Cover and lid detection."
        exit 1
    fi

    echo "All ${#REQUIRED_SYMBOLS[@]} required symbols verified as =y in .config."
}

# =============================================================================
# Main Build
# =============================================================================

echo "=============================================="
echo " Surface Pro 12 Kernel Build"
echo "=============================================="
echo ""

# Pre-flight checks
echo "--- Pre-flight checks ---"
verify_kernel_source
install_toolchain
echo ""

# --- 3.1 Defconfig ---
run_with_check "Running defconfig" \
    make -C "$KERNEL_SRC" \
         ARCH=arm64 \
         CROSS_COMPILE="${CROSS_COMPILE}" \
         defconfig

# --- 8.1-8.7 Force required config options ---
force_config_symbols

# --- 3.2 Kernel compilation ---
run_with_check "Compiling kernel" \
    make -C "$KERNEL_SRC" \
         ARCH=arm64 \
         CROSS_COMPILE="${CROSS_COMPILE}" \
         -j"$(nproc)"

# --- 9.x Verify required config overrides ---
REQUIRED_SYMBOLS=(
    "CONFIG_SQUASHFS_LZO=y"
    "CONFIG_SQUASHFS_XZ=y"
    "CONFIG_SQUASHFS_ZSTD=y"
    "CONFIG_SQUASHFS_LZ4=y"
    "CONFIG_SQUASHFS_ZLIB=y"
    "CONFIG_SURFACE_AGGREGATOR=y"
    "CONFIG_SURFACE_AGGREGATOR_BUS=y"
    "CONFIG_SURFACE_AGGREGATOR_REGISTRY=y"
    "CONFIG_SURFACE_AGGREGATOR_HUB=y"
    "CONFIG_SURFACE_AGGREGATOR_TABLET_SWITCH=y"
    "CONFIG_SURFACE_HID=y"
    "CONFIG_SURFACE_HID_CORE=y"
    "CONFIG_FW_LOADER_COMPRESS=y"
    "CONFIG_FW_LOADER_COMPRESS_ZSTD=y"
    "CONFIG_SERIAL_DEV_BUS=y"
    "CONFIG_SERIAL_QCOM_GENI=y"
    "CONFIG_SURFACE_PLATFORMS=y"
    "CONFIG_ACPI=y"
    "CONFIG_SCSI=y"
    "CONFIG_BLK_DEV_SD=y"
    "CONFIG_SCSI_UFSHCD=y"
    "CONFIG_SCSI_UFSHCD_PLATFORM=y"
    "CONFIG_SCSI_UFS_QCOM=y"
    "CONFIG_PHY_QCOM_QMP=y"
    "CONFIG_PHY_QCOM_QMP_UFS=y"
    "CONFIG_EXT4_FS=y"
)
verify_config

echo ""
echo "=============================================="
echo " Build complete!"
echo " Kernel image: ${KERNEL_SRC}/arch/arm64/boot/Image"
echo " Kernel .config: ${KERNEL_SRC}/.config"
echo " System.map: ${KERNEL_SRC}/System.map"
echo ""
echo " Next: Stage 1.5 (inst-rootfs.sh) assembles the rootfs using the kernel source."
echo "=============================================="
