## Context

The Surface Pro 12 uses a Qualcomm Snapdragon X Plus (SDX85 / SC8280XP-class) ARM64 SoC. Building a kernel for it requires cross-compilation from an x86_64 host, and the device needs a custom device tree blob plus firmware packages that are maintained separately in the `harrisonvanderbyl/surface-pro-12-inch-linux` repository. All kernel driver patches are included in the kernel source.

The host is Debian 14 (forky) x86_64. The target is Ubuntu (ARM64) on the Surface Pro 12, which boots via GRUB.

## Goals / Non-Goals

**Goals:**
- Single command to produce all kernel build artifacts from source
- Cross-compile from Debian amd64 host to ARM64 target
- Apply required `=y` config overrides on top of `defconfig`

**Non-Goals:**
- Deploying the built artifacts to the target device
- Building or managing initramfs
- GRUB configuration, EFI stub, or shim setup
- Recovery kernels

### Required config overrides

| # | Symbol | Why |
|---|--------|-----|
| 1 | `CONFIG_SQUASHFS_LZO=y` | Ubuntu snaps use lzo; without it, snap `.mount` units fail and `graphical.target` never starts |
| 2 | `CONFIG_SQUASHFS_XZ=y` | Some snaps use xz compression |
| 3 | `CONFIG_SQUASHFS_ZSTD=y` | Some snaps use zstd compression |
| 4 | `CONFIG_SQUASHFS_LZ4=y` | Some snaps use lz4 compression |
| 5 | `CONFIG_SQUASHFS_ZLIB=y` | Some snaps use zlib compression |
| 6 | `CONFIG_SURFACE_AGGREGATOR=y` | EC communication for Surface devices |
| 7 | `CONFIG_SURFACE_AGGREGATOR_BUS=y` | SSAM bus driver |
| 8 | `CONFIG_SURFACE_AGGREGATOR_REGISTRY=y` | SSAM registry for device properties |
| 9 | `CONFIG_SURFACE_AGGREGATOR_HUB=y` | SSAM hub driver |
| 10 | `CONFIG_SURFACE_AGGREGATOR_TABLET_SWITCH=y` | Tablet-mode switch (lid) support |
| 11 | `CONFIG_SURFACE_HID=y` | Surface HID device driver |
| 12 | `CONFIG_SURFACE_HID_CORE=y` | Surface HID core |

## Decisions

### Copy DTB from assets rather than building from kernel source
The pre-compiled DTB (`assets/boot/dtb`) was produced by the device-tree maintainer and is calibrated to match the firmware and sensor registry data shipped with the repo. Building our own DTB from kernel source risks version drift between the DTB and the firmware calibration files.

### Kernel source tree as single source of truth
The compiled `Image`, `.config`, `System.map` all stay in the kernel source tree.

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
