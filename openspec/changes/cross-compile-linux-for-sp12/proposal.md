## Why

The Surface Pro 12 uses a Qualcomm Snapdragon X Plus (ARM64) SoC. There is no pre-built kernel toolchain for this device, and building from source is the only way to get a working kernel with all necessary device tree and firmware support. This change provides an automated build system to cross-compile the kernel for the SP12 from an x86_64 Debian host.

## What Changes

- Create a build script (`scripts/build.sh`) that cross-compiles the kernel for ARM64 from a Debian amd64 host
- Install the `gcc-aarch64-linux-gnu` cross-compilation toolchain
- Produce individual build artifacts (kernel image, device tree blob, modules, config, System.map) in a structured output directory
- Copy the device tree blob from the Surface Pro 12 device-tree repository (assets) rather than building from kernel source
- Kernel configuration: `make defconfig` baseline, plus additional options forced to `=y` to support GNOME desktop boot and Type Cover power-on

## Capabilities

### New Capabilities

- `sp12-kernel-build`: Cross-compilation of kernel for Surface Pro 12 (ARM64 target, x86_64 Debian host)

### Modified Capabilities

<!-- None yet -->

## Impact

- Adds cross-compilation toolchain dependency (`gcc-aarch64-linux-gnu`)
- Creates new build system under `build/`
- Host is Debian 14 (forky) x86_64
- Kernel source is expected at `linux/` (provided externally)
- Device tree and firmware are expected at `assets/` (provided externally)
- Output directory: `build/output/` containing individual files for deployment
