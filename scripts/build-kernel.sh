#!/bin/bash
set -euo pipefail

# =============================================================================
# scripts/build-kernel.sh — Stage 1: cross-compile the Linux kernel for ARM64.
#
# Sources scripts/env.sh for all path variables (canonical source of truth).
# Derives OUTPUT from BUILD for the kernel build output directory.
# Cross-compiles from a Debian amd64 host targeting Snapdragon X (ARM64).
# =============================================================================

# --- 0.1 Path configuration: env.sh is the single source of truth ---
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/env.sh"

# Derived: kernel build output directory (not in env.sh).
OUTPUT="${BUILD}/output"
CROSS_COMPILE="aarch64-linux-gnu-"

# --- 7.3 Cleanup function ---
CLEANUP_DONE=false
cleanup() {
    if [ "$CLEANUP_DONE" = true ]; then
        return
    fi
    CLEANUP_DONE=true
    if [ -d "$OUTPUT" ]; then
        echo "Cleaning up partial build output..."
        rm -rf "$OUTPUT"
    fi
}
trap cleanup EXIT

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

# --- 2.2 Verify DTB ---
verify_dtb() {
    if [ ! -f "${ASSETS}/boot/dtb" ]; then
        echo "ERROR: DTB file not found at ${ASSETS}/boot/dtb"
        echo "       Ensure the 'assets/' symlink or directory contains the device-tree package."
        exit 1
    fi
    echo "DTB verified: ${ASSETS}/boot/dtb"
}

# --- 2.3 Check/install toolchain ---
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

# --- Error handling wrapper ---
run_with_check() {
    local step_name="$1"
    shift
    echo "[BUILD] ${step_name}"
    if ! "$@"; then
        echo "ERROR: '${step_name}' failed (exit code $?)."
        exit 1
    fi
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

    # 8.6 Normalize config: resolve dependency constraints
    run_with_check "Running olddefconfig to normalize .config" \
        make -C "$KERNEL_SRC" \
             ARCH=arm64 \
             CROSS_COMPILE="${CROSS_COMPILE}" \
             olddefconfig
    echo "Config normalized."
}

# --- 9.x Verify config overrides in build output ---
verify_config() {
    echo ""
    echo "--- Verifying required config overrides ---"
    CONFIG_FILE="${OUTPUT}/config"
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

    echo "All 16 required symbols verified as =y in build output."
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
verify_dtb
install_toolchain
echo ""

# Prepare output directory
echo "--- Preparing output ---"
mkdir -p "$OUTPUT"
echo "Output directory: ${OUTPUT}"
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

# --- 3.3 Copy kernel image ---
run_with_check "Copying kernel image" \
    cp "${KERNEL_SRC}/arch/arm64/boot/Image" "${OUTPUT}/vmlinuz"
echo "Kernel image: ${OUTPUT}/vmlinuz"

# --- 4.1 Copy DTB ---
run_with_check "Copying device tree blob" \
    cp "${ASSETS}/boot/dtb" "${OUTPUT}/dtb"
echo "Device tree blob: ${OUTPUT}/dtb"

# --- 5.1-5.2 Modules ---
echo "[BUILD] Building and installing modules..."
run_with_check "Installing modules" \
    make -C "$KERNEL_SRC" \
         ARCH=arm64 \
         CROSS_COMPILE="${CROSS_COMPILE}" \
         modules_install \
         INSTALL_MOD_PATH="${OUTPUT}/modules"
echo "Modules installed to: ${OUTPUT}/modules/"

# --- 6.1 Copy .config ---
run_with_check "Copying kernel config" \
    cp "${KERNEL_SRC}/.config" "${OUTPUT}/config"
echo "Kernel config: ${OUTPUT}/config"

# --- 6.2 Copy System.map ---
run_with_check "Copying System.map" \
    cp "${KERNEL_SRC}/System.map" "${OUTPUT}/System.map"
echo "System.map: ${OUTPUT}/System.map"

# --- 6.3 Build info ---
KERNEL_VERSION=$(make -C "$KERNEL_SRC" kernelversion 2>/dev/null || echo "unknown")
GIT_HASH=$(cd "$KERNEL_SRC" && git log --format="%h" -1 2>/dev/null || echo "not-a-git-repo")
TOOLCHAIN_VERSION=$(aarch64-linux-gnu-gcc --version | head -1)

cat > "${OUTPUT}/build-info.txt" <<EOF
Kernel Version: ${KERNEL_VERSION}
Git Commit: ${GIT_HASH}
Toolchain: ${TOOLCHAIN_VERSION}
Host: $(uname -m) $(uname -s)
Arch: arm64
CROSS_COMPILE: ${CROSS_COMPILE}
Build Date: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
echo "Build info: ${OUTPUT}/build-info.txt"

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
    "CONFIG_SERIAL_DEV_BUS=y"
    "CONFIG_SERIAL_QCOM_GENI=y"
    "CONFIG_SURFACE_PLATFORMS=y"
    "CONFIG_ACPI=y"
)
verify_config

# --- 7.2 Validate output files ---
EXPECTED_FILES="vmlinuz dtb config System.map build-info.txt"
EXPECTED_DIRS="modules"
ALL_OK=true

for f in $EXPECTED_FILES; do
    if [ ! -f "${OUTPUT}/${f}" ]; then
        echo "VALIDATION ERROR: Missing expected output file: ${f}"
        ALL_OK=false
    fi
done

for d in $EXPECTED_DIRS; do
    if [ ! -d "${OUTPUT}/${d}" ]; then
        echo "VALIDATION ERROR: Missing expected output directory: ${d}"
        ALL_OK=false
    fi
done

if [ "$ALL_OK" = false ]; then
    echo "ERROR: Build validation failed — some expected output files are missing."
    exit 1
fi

# Clean up trap is handled by EXIT trap, but we don't want to clean on success
CLEANUP_DONE=true

echo ""
echo "=============================================="
echo " Build complete!"
echo " Output: ${OUTPUT}"
echo "=============================================="
