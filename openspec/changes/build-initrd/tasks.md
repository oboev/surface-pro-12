## 0. Path configuration

- [ ] 0.1 Source `scripts/env.sh` as the single source of truth for paths
- [ ] 0.2 Add `OUT="$(realpath -m "${PROJECT_DIR}/build/inst/out")"` to `scripts/env.sh` (`realpath -m` so it resolves before the dir exists)
- [ ] 0.3 `inst-initrd.sh` reads `$ROOTFS`, `$BUILD`, `$KERNEL_SRC`, `$OUT` from env.sh; recomputes no paths

## 1. Verify prerequisites

- [ ] 1.1 `$ROOTFS` exists and is non-empty; abort naming it otherwise
- [ ] 1.2 Read `<release>` from `linux/include/config/kernel.release`; abort if missing
- [ ] 1.3 Kernel image present (`$ROOTFS/boot/vmlinuz-<release>` or `$KERNEL_SRC/arch/arm64/boot/Image`)
- [ ] 1.4 `overlay.ko` or `overlay.ko.zst` present under `$ROOTFS/lib/modules/<release>/`; abort if neither
- [ ] 1.5 Static busybox input present; abort if missing
- [ ] 1.6 `$ROOTFS/boot/surface.dtb` present
- [ ] 1.7 Host tools `mksquashfs` and `cpio` on `PATH`; abort naming any missing
- [ ] 1.8 Top-level sanity: `$ROOTFS`, `$ROOTFS/usr`, `$ROOTFS/etc` keep group+other read+execute (reject owner-only `700`/`750`; accept benign `775`); abort with the offending mode otherwise
- [ ] 1.9 `mkdir -p "$OUT"`

## 2. Pack the rootfs squashfs

- [ ] 2.1 Remove/exclude the ISO's stale 7.0 qcom kernel + initrd from the tree so they don't enter the squashfs
- [ ] 2.2 `mksquashfs "$ROOTFS" "$OUT/rootfs.squashfs" -comp gzip -b 1M -noappend`
- [ ] 2.3 Verify `unsquashfs -s` reports `Compression gzip` and `Block size 1048576`
- [ ] 2.4 Record squashfs size (`stat -c%s`)

## 3. Size guard (pre-cpio)

- [ ] 3.1 If squashfs size + fixed overhead ≥ 4294967296, abort before building the cpio, printing the size and the 4 GiB cap

## 4. Assemble the initramfs staging tree

- [ ] 4.1 Create a staging dir under `$BUILD` (e.g. `$BUILD/inst/initramfs`); start clean
- [ ] 4.2 Make dirs: `/bin /dev /proc /sys /mnt/squash /mnt/overlay /mnt/root`
- [ ] 4.3 Verify busybox is `statically linked` + aarch64 ELF (`file`); abort otherwise; copy to `/bin/busybox`
- [ ] 4.4 Symlink applets → `/bin/busybox`: `sh mount umount insmod losetup switch_root mkdir` (at minimum)
- [ ] 4.5 Place `/overlay.ko` uncompressed (decompress `overlay.ko.zst` with `zstd -d` if needed); verify it is a relocatable ELF, not a zstd stream
- [ ] 4.6 Create static device nodes `dev/console` (c 5 1) and `dev/null` (c 1 3) via `mknod`
- [ ] 4.7 Hardlink (not copy) `$OUT/rootfs.squashfs` into the staging tree as `/rootfs.squashfs` to avoid a third 3.5 GB copy
- [ ] 4.8 Write `/init` (see §5), `chmod +x`

## 5. Author /init

- [ ] 5.1 Shebang `#!/bin/busybox sh`; guard each step; on failure `exec /bin/busybox sh` on the console
- [ ] 5.2 Mount `proc` `/proc`, `sysfs` `/sys`, `devtmpfs` `/dev`
- [ ] 5.3 `insmod /overlay.ko`
- [ ] 5.4 Mount `/rootfs.squashfs` ro at `/mnt/squash` (`-t squashfs -o ro,loop`; fallback `losetup /dev/loop0` + mount)
- [ ] 5.5 Mount `tmpfs` at `/mnt/overlay`; make `upper/` and `work/`
- [ ] 5.6 `mount -t overlay overlay -o lowerdir=/mnt/squash,upperdir=/mnt/overlay/upper,workdir=/mnt/overlay/work /mnt/root`
- [ ] 5.7 `mount --move` `/proc`, `/sys`, `/dev` into `/mnt/root/*`
- [ ] 5.8 `exec switch_root /mnt/root /sbin/init`

## 6. Pack the initramfs

- [ ] 6.1 From the staging root, `find . | cpio -o -H newc > "$OUT/sp12-install.initrd"` (uncompressed; run as root for root:root ownership)
- [ ] 6.2 Verify with `cpio -itv < "$OUT/sp12-install.initrd"` that `init`, `bin/busybox`, `overlay.ko`, `rootfs.squashfs`, `dev/console` are present

## 7. Size guard (post-cpio) and ESP artifacts

- [ ] 7.1 `stat -c%s "$OUT/sp12-install.initrd"` strictly < 4294967296; abort with byte counts otherwise
- [ ] 7.2 Copy `vmlinuz-<release>` → `$OUT/vmlinuz-<release>` (byte-identical)
- [ ] 7.3 Copy `surface.dtb` → `$OUT/surface.dtb` (byte-identical)

## 8. Cleanup and reporting

- [ ] 8.1 Remove the initramfs staging dir (the squashfs survives in `$OUT`)
- [ ] 8.2 Print squashfs size, initrd size, and headroom under 4 GiB
- [ ] 8.3 Print RAM-budget note (~7 GB boot peak → ~3.5 GB resident on 16 GB) and next-stage (`flash-install.sh`) guidance

## 9. Verification (must pass before archiving)

### 9.1 Static analysis (no execution needed)
- [ ] 9.1.1 `bash -n scripts/inst-initrd.sh` exits 0 (guards against zsh-only syntax such as `for a b in …`)
- [ ] 9.1.2 `shellcheck scripts/inst-initrd.sh` reports no errors (catch pipe-precedence bugs and unreachable `|| true` after a function that `exit`s)
- [ ] 9.1.3 Confirm the script sets `set -euo pipefail` and targets bash
- [ ] 9.1.4 The `/init` heredoc is single-quoted (or `$` escaped) so build-host variables do not expand into it

### 9.2 Spec-scenario conformance (walk every requirement's THEN)
- [ ] 9.2.1 env.sh: `$OUT` = absolute `build/inst/out`, set even before the dir exists
- [ ] 9.2.2 Prereqs: missing rootfs / kernel.release / kernel image / overlay module / busybox / dtb / `mksquashfs` / `cpio` each abort with a descriptive, input-naming error
- [ ] 9.2.3 Owner-only (`700`/`750`) `$ROOTFS`/`usr`/`etc` aborts with the offending mode; `775` is accepted
- [ ] 9.2.4 `unsquashfs -l` shows no `boot/vmlinuz-*qcom*` / stale initrd; `boot/vmlinuz-<release>` present
- [ ] 9.2.5 `unsquashfs -s` reports `Compression gzip` and `Block size 1048576`
- [ ] 9.2.6 Second run replaces (not appends) the squashfs (`-noappend`)
- [ ] 9.2.7 Oversize squashfs aborts pre-cpio with size + cap printed
- [ ] 9.2.8 `stat -c%s` of the initrd is strictly < 4294967296
- [ ] 9.2.9 Busybox: `file` reports `aarch64` + `statically linked`; a dynamic/non-aarch64 binary aborts
- [ ] 9.2.10 Applets `sh mount umount insmod losetup switch_root mkdir` are symlinks to `/bin/busybox`
- [ ] 9.2.11 `/overlay.ko` is an uncompressed relocatable ELF (not a zstd stream)
- [ ] 9.2.12 `dev/console` and `dev/null` are character device nodes in the cpio
- [ ] 9.2.13 `/init` contains, in order, insmod overlay → squashfs mount → tmpfs upper → overlay mount at `/mnt/root` → `mount --move` → `exec switch_root /mnt/root /sbin/init`, and an `exec …sh` rescue on failure
- [ ] 9.2.14 `file` on the initrd reports raw `newc` cpio (no gzip/zstd/xz); `cpio -itv` lists members
- [ ] 9.2.15 `$OUT/vmlinuz-<release>` and `$OUT/surface.dtb` exist and are byte-identical to sources
- [ ] 9.2.16 End-to-end exit 0 with all four artifacts present and both sizes + headroom printed

### 9.3 Runtime verification (after a real build run)
- [ ] 9.3.1 Script completes end-to-end with exit code 0 against the real `$ROOTFS`
- [ ] 9.3.2 `cmp` `$OUT/vmlinuz-<release>` and `$OUT/surface.dtb` against their sources → identical
- [ ] 9.3.3 `unsquashfs -s $OUT/rootfs.squashfs | grep -E 'Compression gzip|Block size 1048576'` → both lines present
- [ ] 9.3.4 Deliberately point at a dynamically-linked busybox → build aborts before packing
- [ ] 9.3.5 `stat -c%s $OUT/sp12-install.initrd` < 4294967296 and > squashfs size (carries it)

### 9.4 Regression checks (one per bug that could silently return)
- [ ] 9.4.1 The initrd is **not** gzip/zstd-compressed (a compressed cpio would waste boot CPU and can confuse GRUB) — `file` shows raw newc
- [ ] 9.4.2 `overlay.ko` is decompressed (busybox `insmod` cannot load `.ko.zst`)
- [ ] 9.4.3 The squashfs is hardlinked, not copied, into staging (no silent 3.5 GB extra + no stale copy left behind)
- [ ] 9.4.4 The 4 GiB guard uses the exact byte constant 4294967296 with a strict `<` (off-by-one at the FAT32/newc boundary)
- [ ] 9.4.5 `-noappend` is present so re-runs never grow an existing squashfs
- [ ] 9.4.6 `/init` uses `mount --move` (not a fresh mount) for proc/sys/dev so systemd finds them already populated
