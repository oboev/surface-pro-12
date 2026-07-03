## 1. Create build script skeleton

- [x] 1.1 Create `scripts/build-kernel.sh` with shebang, set -euo pipefail, and executable permission
- [x] 1.2 Define constants (KERNEL_SRC, ASSETS, CROSS_COMPILE)

## 2. Pre-flight checks

- [x] 2.1 Add function to verify kernel source exists at KERNEL_SRC with a Makefile
- [x] 2.2 Add function to check for gcc-aarch64-linux-gnu; install via apt if missing

## 3. Kernel build

- [x] 3.1 Add step to run ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- make defconfig
- [x] 3.2 Add step to run ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- make -j$(nproc)

## 7. Error handling and validation

- [x] 7.1 Add error handling after each make step (check exit code; abort with error)

## 8. Force required config options (=y beyond defconfig)

- [x] 8.1 After `defconfig`, run `"$KERNEL_SRC/scripts/config" --file "$KERNEL_SRC/.config" -e <SYM>` for each of the 12 symbols to re-enable them (paths anchored to `$KERNEL_SRC`, **not** CWD)
- [x] 8.2 Squashfs decompressors: `CONFIG_SQUASHFS_LZO`, `CONFIG_SQUASHFS_XZ`, `CONFIG_SQUASHFS_ZSTD`, `CONFIG_SQUASHFS_LZ4`, `CONFIG_SQUASHFS_ZLIB`
- [x] 8.3 SSAM: `CONFIG_SURFACE_AGGREGATOR`, `CONFIG_SURFACE_AGGREGATOR_BUS`, `CONFIG_SURFACE_AGGREGATOR_REGISTRY`, `CONFIG_SURFACE_AGGREGATOR_HUB`, `CONFIG_SURFACE_AGGREGATOR_TABLET_SWITCH`
- [x] 8.4 Surface HID: `CONFIG_SURFACE_HID`, `CONFIG_SURFACE_HID_CORE`
- [x] 8.5 Verify each `scripts/config` call succeeds (check exit code; abort with error if any fails)
- [x] 8.6 Run `make olddefconfig` after all `scripts/config` calls to normalize the config — resolve dependency constraints and write a fully consistent `.config`
- [x] 8.7 Verify `olddefconfig` succeeds (check exit code; abort with error if it fails)

## 9. Verify required config overrides in kernel source .config

- [x] 9.1 Squashfs decompressors — confirm `linux/.config` contains `CONFIG_SQUASHFS_LZO=y`, `CONFIG_SQUASHFS_XZ=y`, `CONFIG_SQUASHFS_ZSTD=y`, `CONFIG_SQUASHFS_LZ4=y`, `CONFIG_SQUASHFS_ZLIB=y`
- [x] 9.2 Surface Aggregator — confirm `linux/.config` contains `CONFIG_SURFACE_AGGREGATOR=y`, `CONFIG_SURFACE_AGGREGATOR_BUS=y`, `CONFIG_SURFACE_AGGREGATOR_REGISTRY=y`, `CONFIG_SURFACE_AGGREGATOR_HUB=y`, `CONFIG_SURFACE_AGGREGATOR_TABLET_SWITCH=y`
- [x] 9.3 Surface HID — confirm `linux/.config` contains `CONFIG_SURFACE_HID=y` and `CONFIG_SURFACE_HID_CORE=y`
- [x] 9.4 Deps — confirm `CONFIG_SERIAL_DEV_BUS=y`, `CONFIG_SERIAL_QCOM_GENI=y`, `CONFIG_SURFACE_PLATFORMS=y`, `CONFIG_ACPI=y` are present (defconfig baseline)
- [x] 9.5 If any of the above are missing or not `=y`, flag as a build failure — the script must force them via `scripts/config`
