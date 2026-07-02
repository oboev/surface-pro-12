## Context

The Surface Pro 12 uses a Qualcomm Snapdragon X Plus (ARM64) SoC. The cross-compiled 7.2 kernel, device tree blob, and modules already exist in this project. The Resolute ISO (`resolute-desktop-arm64+x1e.iso`) provides a ready-made Ubuntu 26.04 arm64 userspace. We need to combine these into a single rootfs tree that Stage 2 will compress into a squashfs and embed in the initrd for RAM-only boot.

## Goals / Non-Goals

**Goals:**
- Produce a complete rootfs tree (`build/inst/root/`) that boots to GNOME on the SP12
- Inject the cross-compiled kernel, modules, firmware, and DTB into the tree
- Configure apt to use the arm64 ports mirror (not the ISO's `file:/cdrom` source)
- Create user `aleksey` with password, enable GDM autologin, set hostname, default target = graphical.target
- Extract from ISO's `minimal.squashfs` (not the full desktop squashfs) to minimize size

**Non-Goals:**
- Packing the squashfs or building the initrd — that's Stage 2
- Kernel configuration tuning — we use the default config from the cross-compile change
- Any disk installation — the machine boots entirely from RAM
- GRUB installation, EFI stub, or shim setup
- Disk partitioning, gdisk, rsync, os-prober, or other install tooling

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                    inst-rootfs.sh                         │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  Inputs:                                                 │
│    Resolute ISO ──► casper/minimal.squashfs              │
│    Kernel src ──► arch/arm64/boot/Image                  │
│    Kernel src ──► modules (via modules_install)          │
│    DTB assets ──► boot/dtb                               │
│                                                          │
│  Process:                                                │
│    1. Mount ISO → extract minimal.squashfs               │
│    2. Inject kernel + modules + firmware + DTB           │
│    3. Chroot: apt config + user setup                     │
│    4. Unmount chroot bind mounts                            │
│                                                          │
│  Output:                                                 │
│    build/inst/root/  — complete rootfs tree              │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

## Decisions

### Extract from ISO's minimal.squashfs rather than debootstrap
The Resolute ISO contains `casper/minimal.squashfs` — a lean Ubuntu arm64 rootfs with only the essentials. This is:
- Already compiled and tested for arm64
- ~3 GB vs ~1.5 GB base (but includes desktop packages)
- Saves hours of debootstrap + package installation time
- Guarantees the desktop environment is present

### Use minimal.squashfs, not the full desktop squashfs
Both ISO squashfs variants include snapd and snaps. `minimal.squashfs` is leaner because it excludes some desktop meta-packages and extra apps, reducing the squashfs size for Stage 2. This matters: every megabyte saved in the squashfs means more RAM headroom for the desktop and the overlay upper layer.

### Rootfs tree at `build/inst/root/` (project-local)
The rootfs tree lives inside the `build/` directory alongside the kernel output:
- Keeps all build artifacts in one place (`build/output/` for kernel, `build/inst/root/` for rootfs)
- Uses the same gitignore pattern as `build/output/` (already excluded)
- Can be regenerated from scratch without affecting the project repo

### Chroot reconfigure apt to use ports mirror
The ISO's rootfs points apt at `file:/cdrom` (the live media source). In our chroot, the CDROM doesn't exist. We must disable all live-media sources and pin to `ports.ubuntu.com/ubuntu-ports` for arm64.

### Permission sanity checks after unsquashfs
`unsquashfs` can overwrite existing directories with 700 permissions (owner-only). A sanity check verifies that `/`, `/usr`, and `/etc` are 755. This prevents subtle permission disasters later.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| ISO's `minimal.squashfs` may not exist or path differs | Script checks and aborts with clear error |
| Rootfs exceeds 4 GB squashfs limit | Size is printed at end; Stage 2 will check and abort if needed |
| Chroot apt mirror is down or partial | Use standard `ports.ubuntu.com`; accept transient failure |
| `build/` dir on shared or CI storage fills up | Staged cleanup between rootfs and squashfs; `build/` already gitignored |





