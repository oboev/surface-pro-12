## ADDED Requirements

### Requirement: Script exists and sources env.sh
The system SHALL provide `scripts/flash-install.sh`, executable, starting with `set -euo pipefail`, that takes a target block device as its first argument and sources `scripts/env.sh` for `$OUT`.

#### Scenario: Script exists and is executable
- **WHEN** the project is set up
- **THEN** `scripts/flash-install.sh` exists and has the executable permission set

#### Scenario: Missing device argument
- **WHEN** the script is invoked with no argument
- **THEN** it exits non-zero with a usage message naming the expected `<device>` argument

### Requirement: Stage 2 artifacts required
The script SHALL verify that `$OUT/vmlinuz-<release>`, `$OUT/surface.dtb`, and `$OUT/sp12-install.initrd` all exist, resolving `<release>` from `linux/include/config/kernel.release`, and abort with a descriptive error if any is missing.

#### Scenario: An artifact is missing
- **WHEN** any of the three `$OUT` artifacts is absent
- **THEN** the script exits non-zero naming the missing file and pointing at Stage 2

### Requirement: Destructive-target safety guards
Before writing anything, the script SHALL confirm the target is a block device, is NOT the disk backing `/` or the project tree, and has NO currently-mounted partitions; it SHALL also require the device be removable, overridable only by `SP12_ALLOW_NONREMOVABLE=1`. Failing any guard aborts with a descriptive error and touches nothing.

#### Scenario: Target is not a block device
- **WHEN** the argument is a regular file or absent device node
- **THEN** the script exits non-zero without partitioning anything

#### Scenario: Target is the system disk
- **WHEN** the target device backs `/` or the directory containing the project
- **THEN** the script refuses and exits non-zero

#### Scenario: Target has a mounted partition
- **WHEN** any partition of the target device is currently mounted
- **THEN** the script refuses and exits non-zero

#### Scenario: Non-removable device without override
- **WHEN** `/sys/block/<name>/removable` is `0` and `SP12_ALLOW_NONREMOVABLE` is unset
- **THEN** the script refuses; **AND WHEN** `SP12_ALLOW_NONREMOVABLE=1` is set, the guard is bypassed and the build proceeds

### Requirement: Required host tooling
The script SHALL verify the presence of `parted`, `wipefs`, `mkfs.vfat`, `grub-install` with an installed `arm64-efi` target, `partprobe`, and `cmp`, and abort naming any missing tool or the package that provides it. It SHALL NOT depend on `gdisk`/`sgdisk`.

#### Scenario: arm64-efi GRUB target absent
- **WHEN** the host has no `arm64-efi` GRUB modules directory
- **THEN** the script exits non-zero naming `grub-efi-arm64-bin` (or equivalent) as the missing dependency

### Requirement: Single FAT32 EFI System partition
The script SHALL partition the device GPT (via `parted`) with exactly one EFI System partition spanning the device, formatted FAT32 with label `SP12BOOT`. It SHALL derive the partition node correctly for both `sdX`-style (`<dev>1`) and `nvme`/`mmcblk`/`loop`-style (`<dev>p1`) devices.

#### Scenario: Partition table and filesystem
- **WHEN** the build completes
- **THEN** the device has exactly one GPT partition whose type is the EFI System GUID (`lsblk -no PARTTYPE <part>` = `c12a7328-f81f-11d2-ba4b-00a0c93ec93b`), and `blkid <part>` reports `TYPE="vfat"` with `LABEL="SP12BOOT"`

#### Scenario: Partition suffix for NVMe/MMC/loop devices
- **WHEN** the target is `/dev/nvme0n1`, `/dev/mmcblk0`, or `/dev/loop0`
- **THEN** the script operates on `<dev>p1`, not `<dev>1`

### Requirement: Artifacts copied and byte-verified
The script SHALL copy `vmlinuz-<release>`, `surface.dtb`, and `sp12-install.initrd` to the ESP root and verify each copy byte-for-byte with `cmp` against its source, aborting on any mismatch. The rootfs squashfs SHALL NOT be copied (it is carried inside the initrd).

#### Scenario: Files present and identical
- **WHEN** the copy step completes
- **THEN** the ESP contains `/vmlinuz-<release>`, `/surface.dtb`, and `/sp12-install.initrd`, each `cmp`-identical to its `$OUT` source, and contains no `rootfs.squashfs`

#### Scenario: Truncated copy detected
- **WHEN** a copy is short or corrupted (e.g. the target filesystem fills)
- **THEN** `cmp` fails and the script aborts non-zero rather than producing a silently-broken stick

### Requirement: GRUB installed in removable mode
The script SHALL run `grub-install --removable --target=arm64-efi` against the ESP so the stick boots via the UEFI fallback path with no NVRAM entry.

#### Scenario: Fallback bootloader present
- **WHEN** GRUB installation completes
- **THEN** `/EFI/BOOT/BOOTAA64.EFI` exists on the ESP

### Requirement: Single-entry grub.cfg that RAM-boots and touches no disk
The script SHALL write a `grub.cfg` with exactly one menu entry, "Try in RAM", that loads `/vmlinuz-<release>` with only the base cmdline, injects the DTB via `devicetree /surface.dtb`, and loads `initrd /sp12-install.initrd`. The cmdline SHALL carry no disk-touching flags — in particular no `sp12.install`.

#### Scenario: Exactly one entry, titled "Try in RAM"
- **WHEN** the generated `grub.cfg` is inspected
- **THEN** it contains exactly one `menuentry` line whose title contains "Try in RAM"

#### Scenario: Entry references the payload and injects the DTB
- **WHEN** the entry is inspected
- **THEN** it contains `linux /vmlinuz-<release> …`, `devicetree /surface.dtb`, and `initrd /sp12-install.initrd`

#### Scenario: No install/disk-touching flags anywhere
- **WHEN** the whole `grub.cfg` is searched
- **THEN** neither `sp12.install` nor `systemd.unit=multi-user.target` appears anywhere in it

### Requirement: Clean unmount and end-to-end success
The script SHALL `sync` and unmount the ESP before exiting, and complete with exit code 0 leaving no mounts it created behind.

#### Scenario: Complete build
- **WHEN** all prerequisites and guards pass
- **THEN** the script exits 0, the ESP is unmounted, and the device holds a bootable GRUB + kernel + DTB + initrd + single-entry `grub.cfg`
