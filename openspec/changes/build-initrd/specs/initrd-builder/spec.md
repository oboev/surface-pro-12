## ADDED Requirements

### Requirement: Script exists and sources env.sh
The system SHALL provide `scripts/inst-initrd.sh`, executable, starting with `set -euo pipefail`, that sources `scripts/env.sh` for all path variables and resolves every input/output relative to those variables (never the caller's working directory).

#### Scenario: Script exists and is executable
- **WHEN** the project is set up
- **THEN** `scripts/inst-initrd.sh` exists and has the executable permission set

#### Scenario: Paths come from env.sh
- **WHEN** `inst-initrd.sh` is invoked from any working directory
- **THEN** it sources `scripts/env.sh` and reads `$ROOTFS`, `$BUILD`, `$KERNEL_SRC`, and `$OUT` from it, producing identical output paths regardless of the caller's cwd

### Requirement: env.sh defines the OUT path
`scripts/env.sh` SHALL define `OUT` as the Stage 2 output directory, resolved with `realpath -m` so it is absolute even before the directory exists.

#### Scenario: OUT is defined and absolute
- **WHEN** `scripts/env.sh` is sourced
- **THEN** `$OUT` equals the absolute path of `${PROJECT_DIR}/build/inst/out` and is set even when that directory does not yet exist

### Requirement: Prerequisite verification
The script SHALL verify all inputs before doing any work and abort with a descriptive error naming the missing/invalid input: the rootfs tree `$ROOTFS` (exists, non-empty), the kernel release file `linux/include/config/kernel.release`, the kernel image (`$ROOTFS/boot/vmlinuz-<release>` or `$KERNEL_SRC/arch/arm64/boot/Image`), the overlay module under `$ROOTFS/lib/modules/<release>/`, the static busybox input, `$ROOTFS/boot/surface.dtb`, and host tools `mksquashfs` and `cpio`.

#### Scenario: Rootfs tree missing or empty
- **WHEN** `$ROOTFS` does not exist or contains no files
- **THEN** the script exits non-zero with an error naming `$ROOTFS`

#### Scenario: A required host tool is absent
- **WHEN** `mksquashfs` or `cpio` is not on `PATH`
- **THEN** the script exits non-zero naming the missing tool

#### Scenario: Overlay module absent
- **WHEN** no `overlay.ko` or `overlay.ko.zst` exists under `$ROOTFS/lib/modules/<release>/`
- **THEN** the script exits non-zero naming the missing overlay module

### Requirement: Rootfs tree top-level permission sanity
Before packing, the script SHALL verify that `$ROOTFS`, `$ROOTFS/usr`, and `$ROOTFS/etc` remain traversable by non-owners — group AND other each retaining read+execute — and abort otherwise. This guards against a Stage 1 `unsquashfs -f` corruption (owner-only `700`, which kills every non-root service) propagating into the squashfs. Benign group-writable variants such as `775` pass.

#### Scenario: Owner-only top-level directory
- **WHEN** any of `$ROOTFS`, `$ROOTFS/usr`, `$ROOTFS/etc` lacks read+execute for group or other (e.g. mode `700` or `750`)
- **THEN** the script exits non-zero identifying the offending directory and its mode

#### Scenario: Group-writable directory is accepted
- **WHEN** a top-level directory is mode `775` (group+other still have read+execute)
- **THEN** the check passes and the build proceeds

### Requirement: Stale qcom kernel/initrd dropped from the image
The rootfs squashfs SHALL NOT contain the ISO's original 7.0 qcom kernel or its initrd; only the injected `vmlinuz-<release>` (and `surface.dtb`) may remain under `/boot`.

#### Scenario: Old boot artifacts absent from the squashfs
- **WHEN** `unsquashfs -l $OUT/rootfs.squashfs` is inspected
- **THEN** it lists no `boot/vmlinuz-*qcom*` and no matching stale `boot/initrd*`/`boot/initramfs*` entry, while `boot/vmlinuz-<release>` is present

### Requirement: Root filesystem squashfs is gzip with 1 MiB blocks
The script SHALL pack `$ROOTFS` into `$OUT/rootfs.squashfs` using `mksquashfs` with `-comp gzip -b 1M -noappend`. gzip is mandatory because the booting 7.2 kernel supports only the ZLIB squashfs decompressor at this layer.

#### Scenario: Squashfs is produced with gzip and 1 MiB blocks
- **WHEN** packing completes
- **THEN** `unsquashfs -s $OUT/rootfs.squashfs` reports `Compression gzip` and `Block size 1048576`

#### Scenario: Re-run overwrites, does not append
- **WHEN** `inst-initrd.sh` is run twice
- **THEN** the second run replaces `$OUT/rootfs.squashfs` (via `-noappend`) rather than appending to it

### Requirement: 4 GiB hard cap on the initrd
Because the `newc` cpio format and FAT32 each cap a single file at 4 GiB (4294967296 bytes), the script SHALL check the size budget **before** building the cpio (squashfs size plus a small fixed overhead) and **after** (the real initrd file), and abort non-zero with the byte counts if either would meet or exceed 4 GiB.

#### Scenario: Squashfs too large to fit an initrd under 4 GiB
- **WHEN** `rootfs.squashfs` plus overhead is ≥ 4294967296 bytes
- **THEN** the script aborts before building the cpio and prints the squashfs size and the cap

#### Scenario: Built initrd stays under the cap
- **WHEN** the build completes successfully
- **THEN** `stat -c%s $OUT/sp12-install.initrd` is strictly less than 4294967296

### Requirement: Static aarch64 busybox in the initramfs
The initramfs SHALL contain a **statically linked** aarch64 busybox at `/bin/busybox`, with applet symlinks for at least `sh`, `mount`, `umount`, `insmod`, `losetup`, `switch_root`, and `mkdir` pointing to it. The script SHALL abort if the busybox input is not statically linked or not an aarch64 ELF.

#### Scenario: Busybox is static and aarch64
- **WHEN** the busybox input is checked
- **THEN** `file` on it reports `ELF 64-bit ... ARM aarch64` and `statically linked`; a dynamically-linked or non-aarch64 binary aborts the build

#### Scenario: Required applets are symlinked
- **WHEN** the initramfs staging tree is assembled
- **THEN** each of `sh mount umount insmod losetup switch_root mkdir` exists as a symlink to `/bin/busybox`

### Requirement: Overlay module present and loadable
The initramfs SHALL contain `/overlay.ko` as a plain, uncompressed kernel object (decompressed from `overlay.ko.zst` if the tree ships it compressed), so busybox `insmod` can load it before `switch_root`.

#### Scenario: overlay.ko is uncompressed in the initramfs
- **WHEN** the staging tree is assembled
- **THEN** `/overlay.ko` exists and `file` reports it as an uncompressed `ELF ... relocatable` object (not a zstd stream)

### Requirement: Static device nodes for early console output
The initramfs SHALL contain static `/dev/console` and `/dev/null` device nodes so kernel/`/init` output (including the rescue shell) is visible before devtmpfs is mounted.

#### Scenario: Console and null nodes exist
- **WHEN** the initramfs is built
- **THEN** the cpio contains `dev/console` and `dev/null` as character device nodes

### Requirement: /init overlay-and-pivot logic
The initramfs `/init` SHALL: mount `proc`, `sysfs`, and `devtmpfs`; `insmod /overlay.ko`; mount `/rootfs.squashfs` read-only at `/mnt/squash` via loop (with a `losetup /dev/loop0` fallback); mount a `tmpfs` upper at `/mnt/overlay` and create `upper/` and `work/`; `mount -t overlay` (`lowerdir=/mnt/squash,upperdir=/mnt/overlay/upper,workdir=/mnt/overlay/work`) at `/mnt/root`; `mount --move` `proc`/`sys`/`dev` into `/mnt/root`; then `exec switch_root /mnt/root /sbin/init`. On any failure it SHALL `exec` an interactive shell on the console instead of panicking.

#### Scenario: /init contains the pivot sequence
- **WHEN** the generated `/init` is read
- **THEN** it contains, in order, the `insmod /overlay.ko`, the squashfs mount at `/mnt/squash`, the `tmpfs` upper, the `mount -t overlay ... /mnt/root`, the `mount --move` of the pseudo-filesystems, and a final `exec switch_root /mnt/root /sbin/init`

#### Scenario: Failure drops to a rescue shell
- **WHEN** any step in `/init` fails
- **THEN** control reaches an `exec` of a busybox `sh` on the console rather than a kernel panic

### Requirement: Uncompressed newc cpio initramfs
The script SHALL pack the initramfs as a `cpio -H newc` archive with **no** compression applied.

#### Scenario: Archive is newc and uncompressed
- **WHEN** the initrd is built
- **THEN** `cpio -itv < $OUT/sp12-install.initrd` lists the members successfully and `file $OUT/sp12-install.initrd` does not report a gzip/zstd/xz compressed stream (it is a raw `ASCII cpio archive (SVR4/newc)`)

### Requirement: ESP artifacts copied out
The script SHALL copy `vmlinuz-<release>` and `surface.dtb` into `$OUT` for Stage 3 to place on the install USB's ESP.

#### Scenario: Kernel and DTB present in OUT
- **WHEN** the build completes
- **THEN** `$OUT/vmlinuz-<release>` and `$OUT/surface.dtb` both exist and are byte-identical to their sources

### Requirement: End-to-end success and reporting
The build SHALL complete with exit code 0, producing `rootfs.squashfs`, `sp12-install.initrd`, `vmlinuz-<release>`, and `surface.dtb` in `$OUT`, and SHALL print the squashfs size, the initrd size, and the headroom under the 4 GiB cap.

#### Scenario: Complete build
- **WHEN** all prerequisites are met
- **THEN** `$OUT` contains `rootfs.squashfs`, `sp12-install.initrd`, `vmlinuz-<release>`, and `surface.dtb`, the script exits 0, and it has printed the two sizes and the remaining headroom
