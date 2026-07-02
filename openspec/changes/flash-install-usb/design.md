## Context

Stage 2 (`build-initrd`) leaves three files in `$OUT`: `vmlinuz-<release>`, `surface.dtb`, and `sp12-install.initrd` (the OS-in-a-file initramfs that carries the whole rootfs squashfs). Stage 3 writes them onto a USB stick that the Surface can boot.

The Surface's own USB driver (`dwc3-qcom`) drops the device offline under load, but UEFI/GRUB USB reads are reliable. So the USB is designed to be read **only by firmware**: GRUB pulls the kernel + ~3.5 GB initrd into RAM, `/init` pivots into the RAM overlay, and the stick is never read again. That is why there is no ext4 root partition and no separate squashfs on the stick — everything rides in the initrd.

## Goals / Non-Goals

**Goals:**
- Produce a bootable FAT32 install USB from `$OUT` on a caller-named device
- Guard hard against writing to the wrong (system) disk
- A single GRUB entry that RAM-boots the desktop and touches no disk
- Byte-verify the initrd copy (a truncated 3.5 GB file boots to nothing)

**Non-Goals:**
- The internal-disk installer, its GRUB "INSTALL" entry, and the `sp12.install=1` flag (separate future change)
- Building the squashfs/initrd (Stage 2); Secure Boot / firmware config (manual)
- Placing `rootfs.squashfs` on the stick (it is inside the initrd)

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                 flash-install.sh <device>   (root)                 │
├──────────────────────────────────────────────────────────────────┤
│  Inputs ($OUT):  vmlinuz-<release>   surface.dtb   sp12-install.initrd │
│  Arg:            <device>  e.g. /dev/sdb                            │
│                                                                    │
│  1. Safety: block dev? not system disk? not mounted? removable?    │
│  2. Partition: wipefs -a; parted gpt + one EFI System, full disk    │
│  3. Format:   mkfs.vfat -F32 -n SP12BOOT  <part>                    │
│  4. Mount <part> → copy kernel/dtb/initrd → cmp each               │
│  5. grub-install --removable --target=arm64-efi                     │
│  6. Write /boot/grub/grub.cfg  (single "Try in RAM" entry)          │
│  7. sync + unmount                                                  │
│                                                                    │
│  Output: bootable USB — /EFI/BOOT/BOOTAA64.EFI + kernel+dtb+initrd  │
└──────────────────────────────────────────────────────────────────┘
```

## Decisions

### One FAT32 ESP, nothing else
FAT32 is the only filesystem UEFI is guaranteed to read, and the ESP doubles as GRUB's home and the store for kernel/DTB/initrd. No ext4 root: the rootfs lives inside the initrd, in RAM. FAT32's 4 GiB per-file limit is exactly why Stage 2 caps the initrd at 4 GiB.

### `grub-install --removable`
`--removable` installs to the fallback path `/EFI/BOOT/BOOTAA64.EFI`, so the stick boots on any UEFI machine with no NVRAM boot entry — essential for a portable installer and for a machine we don't want to add boot entries to. Target is `arm64-efi` (the Surface is aarch64), which requires `grub-efi-arm64-bin` on the build host, not the host's native x86 GRUB.

### Single "Try in RAM" entry; DTB via `devicetree`
Stock GRUB has no Surface DTB, so the entry injects it with `devicetree /surface.dtb` (needs Secure Boot off). The USB boots RAM only and carries no disk-touching flags, so any boot — menu pick or timeout — lands in the same safe RAM desktop and never writes to disk. The internal-disk installer is a separate future change; when it lands it will add its own "INSTALL" entry with the `sp12.install=1` gate, keeping the destructive path out of this stick entirely.

### Byte-verify every copy, especially the initrd
A partial write of the 3.5 GB initrd (full FS, bad stick) yields a stick that loads but hangs. After each copy the script runs `cmp` against the source and aborts on mismatch, so a bad stick fails loudly at build time rather than silently on the Surface.

### Destructive-target guards, one override
The script refuses to run unless the target is a block device, is **not** the disk backing `/` or the project tree, and has **no mounted partitions**. It also requires the device be removable (`/sys/block/<name>/removable == 1`) — overridable only via `SP12_ALLOW_NONREMOVABLE=1`, which is how the loopback self-test (a `losetup -P` file) exercises the full path without a physical stick.

### Partition-suffix handling
Partition 1 is `${DEV}1` for `sd*`/`vd*` but `${DEV}p1` for `nvme*`/`mmcblk*`/`loop*`. The script derives the suffix from whether the device node ends in a digit, so it works for real sticks and loop-backed test images alike.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Wrong device wipes the user's system disk | Block-dev + not-system-disk + not-mounted + removable guards; only removable is overridable |
| `arm64-efi` GRUB target not installed on the host | Prereq check for the target dir / `grub-install` support; abort with the package name |
| Truncated initrd copy → unbootable stick | `cmp` every copy; abort on mismatch |
| Partition device not settled before mkfs | `partprobe` + `udevadm settle` (or wait) before formatting |
| `nvme`/`mmc`/`loop` partition naming differs from `sdX` | Derive `p1` vs `1` suffix from a trailing-digit test |
| A stray INSTALL entry could write to disk before the installer exists | Ship a single RAM-only entry; the installer change adds its own entry later |
