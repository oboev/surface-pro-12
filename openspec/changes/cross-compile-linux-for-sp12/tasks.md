## 1. Create build script skeleton

- [x] 1.1 Create `build/build.sh` with shebang, set -e, and executable permission
- [x] 1.2 Define constants (KERNEL_SRC, ASSETS, OUTPUT, CROSS_COMPILE)

## 2. Pre-flight checks

- [x] 2.1 Add function to verify kernel source exists at KERNEL_SRC with a Makefile
- [x] 2.2 Add function to verify DTB exists at ASSETS/boot/dtb
- [x] 2.3 Add function to check for gcc-aarch64-linux-gnu; install via apt if missing

## 3. Kernel build

- [x] 3.1 Add step to run ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- make defconfig
- [x] 3.2 Add step to run ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- make -j$(nproc)
- [x] 3.3 Add step to copy arch/arm64/boot/Image to OUTPUT/vmlinuz

## 4. Device tree blob

- [x] 4.1 Add step to copy ASSETS/boot/dtb to OUTPUT/dtb

## 5. Modules

- [x] 5.1 Add step to run make modules (or rely on -j$(nproc) parallel build)
- [x] 5.2 Add step to run make modules_install with INSTALL_MOD_PATH=OUTPUT/modules

## 6. Metadata files

- [x] 6.1 Add step to copy .config to OUTPUT/config
- [x] 6.2 Add step to copy System.map to OUTPUT/System.map
- [x] 6.3 Add step to write OUTPUT/build-info.txt with kernel version, git hash, and toolchain version

## 7. Error handling and validation

- [x] 7.1 Add error handling after each make step (check exit code)
- [x] 7.2 Add validation that all expected output files exist before script exits successfully
- [x] 7.3 Add cleanup function for failed builds (optional: remove partial output)

## 8. Force required config options (=y beyond defconfig)

- [x] 8.1 After `defconfig`, run `"$KERNEL_SRC/scripts/config" --file "$KERNEL_SRC/.config" -e <SYM>` for each of the 12 symbols to re-enable them (paths anchored to `$KERNEL_SRC`, **not** CWD)
- [x] 8.2 Squashfs decompressors: `CONFIG_SQUASHFS_LZO`, `CONFIG_SQUASHFS_XZ`, `CONFIG_SQUASHFS_ZSTD`, `CONFIG_SQUASHFS_LZ4`, `CONFIG_SQUASHFS_ZLIB`
- [x] 8.3 SSAM: `CONFIG_SURFACE_AGGREGATOR`, `CONFIG_SURFACE_AGGREGATOR_BUS`, `CONFIG_SURFACE_AGGREGATOR_REGISTRY`, `CONFIG_SURFACE_AGGREGATOR_HUB`, `CONFIG_SURFACE_AGGREGATOR_TABLET_SWITCH`
- [x] 8.4 Surface HID: `CONFIG_SURFACE_HID`, `CONFIG_SURFACE_HID_CORE`
- [x] 8.5 Verify each `scripts/config` call succeeds (check exit code; abort with error if any fails)
- [x] 8.6 Run `make olddefconfig` after all `scripts/config` calls to normalize the config — resolve dependency constraints and write a fully consistent `.config`
- [x] 8.7 Verify `olddefconfig` succeeds (check exit code; abort with error if it fails)

## 9. Verify required config overrides in build output

- [x] 9.1 Squashfs decompressors — confirm `build/output/config` contains `CONFIG_SQUASHFS_LZO=y`, `CONFIG_SQUASHFS_XZ=y`, `CONFIG_SQUASHFS_ZSTD=y`, `CONFIG_SQUASHFS_LZ4=y`, `CONFIG_SQUASHFS_ZLIB=y`
- [x] 9.2 Surface Aggregator — confirm `build/output/config` contains `CONFIG_SURFACE_AGGREGATOR=y`, `CONFIG_SURFACE_AGGREGATOR_BUS=y`, `CONFIG_SURFACE_AGGREGATOR_REGISTRY=y`, `CONFIG_SURFACE_AGGREGATOR_HUB=y`, `CONFIG_SURFACE_AGGREGATOR_TABLET_SWITCH=y`
- [x] 9.3 Surface HID — confirm `build/output/config` contains `CONFIG_SURFACE_HID=y` and `CONFIG_SURFACE_HID_CORE=y`
- [x] 9.4 Deps — confirm `CONFIG_SERIAL_DEV_BUS=y`, `CONFIG_SERIAL_QCOM_GENI=y`, `CONFIG_SURFACE_PLATFORMS=y`, `CONFIG_ACPI=y` are present (defconfig baseline)
- [x] 9.5 If any of the above are missing or not `=y`, flag as a build failure — the script must force them via `scripts/config`
