## Context

The Surface Pro 12 uses a Qualcomm Snapdragon X Plus (SDX85 / SC8280XP-class) ARM64 SoC. Building a kernel for it requires cross-compilation from an x86_64 host, and the device needs a custom device tree blob plus firmware packages that are maintained separately in the `harrisonvanderbyl/surface-pro-12-inch-linux` repository. All kernel driver patches are included in the kernel source.

The host is Debian 14 (forky) x86_64. The target is Ubuntu (ARM64) on the Surface Pro 12, which boots via GRUB.

## Goals / Non-Goals

**Goals:**
- Single command to produce all kernel build artifacts from source
- Cross-compile from Debian amd64 host to ARM64 target
- Use default kernel configuration (`make defconfig`) — no manual tuning
- Copy DTB from assets (device-tree repository) rather than building from source
- Produce individual output files (Image, DTB, modules, config, System.map)

**Non-Goals:**
- Deploying the built artifacts to the target device
- Building or managing initramfs
- GRUB configuration, EFI stub, or shim setup
- Recovery kernels
- Any kernel configuration tuning or module selection

## Decisions

### Use `make defconfig` for all kernel configuration
The default ARM64 config includes ACPI support, ARM64 architecture, and a broad set of drivers. Manual tuning is explicitly excluded. If a required driver is missing, it is treated as a kernel version issue (the kernel source may need to be updated) rather than a config issue.

### Copy DTB from assets rather than building from kernel source
The pre-compiled DTB (`assets/boot/dtb`) was produced by the device-tree maintainer and is calibrated to match the firmware and sensor registry data shipped with the repo. Building our own DTB from kernel source risks version drift between the DTB and the firmware calibration files.

### Output to `build/output/` as individual files
No package format (`.deb`, tarball) — just individual files arranged in a flat output directory. This matches the deployment expectation where files are manually placed into `/boot` and `/lib/modules` on the target.

### Cross-toolchain via Debian package
Install `gcc-aarch64-linux-gnu` from Debian repos rather than building a custom toolchain. This is the standard Debian cross-compiler package and provides `aarch64-linux-gnu-gcc` with all necessary binutils.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Default config may lack a driver needed for SP12 boot | The kernel source contains all SP12 patches; report missing drivers as upstream issues |
| Kernel version mismatch between DTB and kernel | DTB is from assets repo, not built alongside kernel; accept this risk as the assets repo is actively maintained |
| Cross-compiler ABI mismatch with Ubuntu target | Ubuntu ARM64 uses glibc; Debian cross-compiler should match; if issues arise, use a Debian-based cross-SDK |
| Long build time on slow host | Use `$(nproc)` parallelism; modules can be built after kernel to allow incremental progress |

## Open Questions

<!-- None remaining -- all were resolved during planning -->
