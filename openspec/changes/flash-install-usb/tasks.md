## 0. Path configuration

- [ ] 0.1 Source `scripts/env.sh` as the single source of truth; read `$OUT`, `$KERNEL_SRC`, `$PROJECT_DIR`
- [ ] 0.2 Recompute no paths outside env.sh

## 1. Arguments and prerequisites

- [ ] 1.1 Require `<device>` as `$1`; print usage and exit non-zero if absent
- [ ] 1.2 Must run as root; abort otherwise
- [ ] 1.3 Resolve `<release>` from `linux/include/config/kernel.release`
- [ ] 1.4 Verify `$OUT/vmlinuz-<release>`, `$OUT/surface.dtb`, `$OUT/sp12-install.initrd` exist; abort naming any missing + pointing at Stage 2
- [ ] 1.5 Verify host tools: `parted`, `wipefs`, `mkfs.vfat`, `grub-install`, `partprobe`, `cmp`; abort naming any missing (no `gdisk`)
- [ ] 1.6 Verify an `arm64-efi` GRUB target is installed; abort naming `grub-efi-arm64-bin` otherwise

## 2. Destructive-target safety guards

- [ ] 2.1 Target must be a block device; abort otherwise
- [ ] 2.2 Target must not be the disk backing `/` or `$PROJECT_DIR` (compare via `lsblk -no PKNAME`/`findmnt`); abort otherwise
- [ ] 2.3 Target must have no mounted partitions (scan `lsblk`/`findmnt`); abort otherwise
- [ ] 2.4 Target must be removable (`/sys/block/<name>/removable == 1`) unless `SP12_ALLOW_NONREMOVABLE=1`; abort otherwise
- [ ] 2.5 Derive the partition node: `<dev>p1` if the device node ends in a digit (nvme/mmc/loop), else `<dev>1`

## 3. Partition and format

- [ ] 3.1 `wipefs -a <device>` (clear old partition-table / filesystem signatures)
- [ ] 3.2 `parted -s <device> mklabel gpt mkpart SP12BOOT fat32 1MiB 100% set 1 esp on` (one EFI System partition spanning the disk)
- [ ] 3.3 `partprobe <device>` + `udevadm settle` (wait for the partition node to appear)
- [ ] 3.4 `mkfs.vfat -F 32 -n SP12BOOT <part>`

## 4. Copy and byte-verify payload

- [ ] 4.1 Mount `<part>` at a temp mountpoint; set an EXIT trap to unmount it
- [ ] 4.2 Copy `vmlinuz-<release>` → ESP root; `cmp` against source; abort on mismatch
- [ ] 4.3 Copy `surface.dtb` → ESP root; `cmp`; abort on mismatch
- [ ] 4.4 Copy `sp12-install.initrd` → ESP root; `cmp`; abort on mismatch
- [ ] 4.5 Do NOT copy `rootfs.squashfs` (it rides inside the initrd)

## 5. Install GRUB and write grub.cfg

- [ ] 5.1 `grub-install --removable --no-nvram --target=arm64-efi --efi-directory=<mnt> --boot-directory=<mnt>/boot --modules="part_gpt fat search search_label search_fs_uuid normal configfile linux fdt all_video gzio echo test"`
- [ ] 5.2 Verify `<mnt>/EFI/BOOT/BOOTAA64.EFI` exists
- [ ] 5.3 Write `<mnt>/boot/grub/grub.cfg`: `set default=0`, a timeout, and a single entry
- [ ] 5.4 Entry "Try in RAM (no disk changes)": `search --no-floppy --label SP12BOOT --set=root`, `linux /vmlinuz-<release> rw console=tty0 clk_ignore_unused pd_ignore_unused`, `devicetree /surface.dtb`, `initrd /sp12-install.initrd` — no `sp12.install` flag. The `clk_ignore_unused pd_ignore_unused` params are REQUIRED (Snapdragon display stays lit)
- [ ] 5.5 `insmod part_gpt fat search_label linux fdt all_video gzio` (the `devicetree` command lives in `fdt.mod`, NOT `devicetree.mod`; `all_video` sets up the EFI framebuffer the kernel inherits)
- [ ] 5.6 `grub-install` bakes the same modules into the core image via `--modules=…` and uses `--no-nvram`

## 6. Finish

- [ ] 6.1 `sync`, unmount the ESP, disarm the trap
- [ ] 6.2 Print completion summary (device, entries, Secure-Boot-off reminder, next step)

## 7. Verification (must pass before archiving)

### 7.1 Static analysis (no execution needed)
- [ ] 7.1.1 `bash -n scripts/flash-install.sh` exits 0
- [ ] 7.1.2 `shellcheck scripts/flash-install.sh` reports no errors (watch pipe-precedence around the guard helpers and `|| true` after functions that `exit`)
- [ ] 7.1.3 Confirm `set -euo pipefail` and bash target
- [ ] 7.1.4 The `grub.cfg` heredoc expands only the intended variables (`<release>`, cmdlines) — quote/escape the rest so `$root`/`${…}` GRUB tokens survive verbatim

### 7.2 Spec-scenario conformance (walk every requirement's THEN)
- [ ] 7.2.1 No arg → usage + non-zero
- [ ] 7.2.2 Missing `$OUT` artifact → abort naming it
- [ ] 7.2.3 Non-block-device / system-disk / mounted-partition targets each abort touching nothing
- [ ] 7.2.4 Non-removable aborts without `SP12_ALLOW_NONREMOVABLE`, proceeds with it
- [ ] 7.2.5 Missing `arm64-efi` target aborts naming the package
- [ ] 7.2.6 `lsblk -no PARTTYPE <part>` is the ESP GUID `c12a7328-…`; `blkid` shows `vfat` + `SP12BOOT`
- [ ] 7.2.7 `/dev/…p1` derived for nvme/mmc/loop; `<dev>1` for sd*
- [ ] 7.2.8 ESP has kernel/dtb/initrd all `cmp`-identical; no `rootfs.squashfs`
- [ ] 7.2.9 `/EFI/BOOT/BOOTAA64.EFI` present
- [ ] 7.2.10 grub.cfg: exactly one `menuentry`, title has "Try in RAM"
- [ ] 7.2.11 Neither `sp12.install` nor `systemd.unit=multi-user.target` appears anywhere in grub.cfg
- [ ] 7.2.12 The entry has `linux /vmlinuz-<release>`, `devicetree /surface.dtb`, `initrd /sp12-install.initrd`
- [ ] 7.2.13 Script exits 0 with the ESP unmounted

### 7.3 Runtime verification via a loopback image (no physical USB needed)
- [ ] 7.3.1 `truncate -s 6G /tmp/sp12usb.img`; `losetup -fP --show /tmp/sp12usb.img` → `/dev/loopN`
- [ ] 7.3.2 `SP12_ALLOW_NONREMOVABLE=1 ./scripts/flash-install.sh /dev/loopN` completes exit 0
- [ ] 7.3.3 `lsblk -no PARTTYPE /dev/loopNp1` is the ESP GUID; `blkid /dev/loopNp1` shows vfat/SP12BOOT
- [ ] 7.3.4 Mount `/dev/loopNp1`; confirm kernel/dtb/initrd present, `cmp`-identical, no squashfs, and `EFI/BOOT/BOOTAA64.EFI` present
- [ ] 7.3.5 `grep -c menuentry grub.cfg` == 1; `grep -c sp12.install grub.cfg` == 0
- [ ] 7.3.6 Point the script at `/dev/loopN` WITHOUT the override → aborts on the removable guard (loop is non-removable)
- [ ] 7.3.7 Teardown: unmount, `losetup -d /dev/loopN`, `rm /tmp/sp12usb.img`

### 7.4 Regression checks (one per bug that could silently return)
- [ ] 7.4.1 The initrd copy is `cmp`-verified (a truncated 3.5 GB initrd must fail the build, not the Surface)
- [ ] 7.4.2 Partition suffix logic never yields `nvme0n11`/`loop01` (trailing-digit devices get `p1`)
- [ ] 7.4.3 grub.cfg has no INSTALL entry and no `sp12.install` flag (this USB never writes to disk)
- [ ] 7.4.4 `rootfs.squashfs` is never copied onto the ESP (would double the space and isn't used)
- [ ] 7.4.5 The system-disk guard rejects the disk backing `/` even when passed as a bare short name vs full `/dev/...` path
- [ ] 7.4.6 The EXIT trap unmounts the ESP on any mid-build failure (no leaked mount / busy loop device)
- [ ] 7.4.7 grub.cfg uses `insmod fdt` (not `insmod devicetree`) — the `devicetree` command is provided by `fdt.mod`; `insmod devicetree` fails at boot with "devicetree.mod not found"
- [ ] 7.4.8 The kernel cmdline keeps `clk_ignore_unused pd_ignore_unused` and the entry `insmod all_video` — dropping either black-screens the Surface after GRUB (Snapdragon gates the display clocks/power domains / no EFI framebuffer)
