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
