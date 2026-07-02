## Why

Stage 3 turns the Stage 2 artifacts into a **bootable install USB** for the Surface Pro 12. It exists because the Surface's Linux USB path (`dwc3-qcom`) is unreliable but its **UEFI/GRUB** USB reads are rock-solid: so the USB only ever has to be read by firmware, which loads the kernel + the OS-in-a-file initrd into RAM and never touches it again.

The USB is a single FAT32 EFI System partition carrying just the kernel, the Surface DTB, and `sp12-install.initrd` (the squashfs rides *inside* that initrd — it is **not** a separate file on the stick). GRUB offers a single entry that boots the desktop entirely in RAM and touches no disk.

## What Changes

- Create `scripts/flash-install.sh <device>` (run as root) that writes a bootable install USB to the given block device
- Source `scripts/env.sh` for `$OUT`; consume `$OUT/vmlinuz-<release>`, `$OUT/surface.dtb`, `$OUT/sp12-install.initrd`
- **Refuse to touch an unsafe target**: require a block device argument that is not the disk backing the project/root and has no mounted partitions; require the device to be removable unless `SP12_ALLOW_NONREMOVABLE=1` is set (which is how the loopback self-test drives it)
- Partition the device GPT (via `parted`, after `wipefs`) with **one** EFI System partition spanning it, formatted **FAT32**; handle both `sdX1` and `nvme…p1`/`mmcblk…p1`/`loopNp1` partition-suffix conventions
- Copy kernel + DTB + initrd to the ESP and **byte-verify** each copy (`cmp`) — a silently truncated 3.5 GB initrd would be unbootable
- Run `grub-install --removable --target=arm64-efi` so firmware finds `/EFI/BOOT/BOOTAA64.EFI` with no NVRAM entry
- Write a **single-entry** `grub.cfg` — "Try in RAM" — that loads the kernel, injects the Surface DTB via `devicetree`, and loads the RAM-boot initrd; it carries no disk-touching flags

## Non-Goals

- The disk installer — partitioning the internal UFS, rsync-to-disk, `os-prober`, `efibootmgr`, and the `sp12-install.service`, **and its own GRUB "INSTALL" entry / `sp12.install=1` flag** — is a **separate future change** (the `build-rootfs` change likewise deferred it). This USB boots RAM only; the installer change will add its menu entry when it lands
- Building the squashfs or initrd — that is Stage 2 (`build-initrd`)
- Copying `rootfs.squashfs` onto the USB — it rides inside the initrd
- Disabling Secure Boot or any UEFI firmware configuration — that is a documented manual prerequisite on the Surface, not something this script can do
- Signing GRUB/kernel for Secure Boot — the design assumes Secure Boot is off

## Capabilities

### New Capabilities

- `install-usb-builder`: Write a bootable FAT32 install USB (GRUB removable + kernel + DTB + RAM-boot initrd + single-entry grub.cfg) from the Stage 2 artifacts.

## Impact

- **Destructive**: repartitions and reformats the target device. Guarded by block-device, not-system-disk, not-mounted, and removable checks; the removable check is the only one overridable (`SP12_ALLOW_NONREMOVABLE=1`), for loopback testing
- Requires the Stage 2 outputs in `$OUT`: `vmlinuz-<release>`, `surface.dtb`, `sp12-install.initrd` (~3.5 GB)
- Requires host tools: `parted` + `wipefs` (partitioning; no `gdisk` dependency), `mkfs.vfat` (dosfstools), `grub-install` with the **arm64-efi** target installed (`grub-efi-arm64-bin`), `partprobe`/`udevadm`, `cmp`
- Target device must be **≥ ~4 GB** (FAT32 ESP holding the ~3.5 GB initrd + kernel + GRUB)
- Runs as root (partition/format/mount/grub-install)
- On the Surface, booting this USB additionally requires **Secure Boot OFF** (so GRUB may `devicetree`-inject the DTB) — a manual firmware step, out of scope here

## Depends on

- **`build-initrd` (Stage 2)** must have produced `$OUT/{vmlinuz-<release>,surface.dtb,sp12-install.initrd}`, with the initrd under the 4 GiB FAT32 file limit.
