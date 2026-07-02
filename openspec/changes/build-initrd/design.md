## Context

Stage 1 (`build-rootfs`) leaves a complete Ubuntu arm64 rootfs **tree** at `$ROOTFS = $BUILD/inst/root`, with the cross-compiled 7.2 kernel, modules, Surface firmware, and DTB already injected. Stage 2 must turn that tree into a bootable RAM payload.

The Surface can boot Linux reliably only if Linux never has to read USB after the kernel starts: the `dwc3-qcom` USB path drops offline under load. GRUB/UEFI USB, by contrast, is rock-solid. The exploit is to make the initramfs *be* the whole OS — GRUB reads kernel + a ~3.5 GB initrd into RAM in one shot, and `/init` pivots into it. See `next-proposal.md` for the mechanism narrative.

## Goals / Non-Goals

**Goals:**
- Pack `$ROOTFS` into `$OUT/rootfs.squashfs` with `mksquashfs -comp gzip -b 1M`
- Build `$OUT/sp12-install.initrd`: an uncompressed `newc` cpio carrying the squashfs, a static aarch64 busybox, `overlay.ko`, and a `/init` that overlay-mounts and `switch_root`s
- Copy `vmlinuz-<release>` and `surface.dtb` to `$OUT` for the Stage 3 ESP
- Fail fast and loud if the initrd would exceed 4 GiB, or if inputs are missing/wrong

**Non-Goals:**
- Building the rootfs tree (Stage 1), writing the install USB / GRUB (Stage 3)
- Kernel config tuning (cross-compile change)
- Re-packing with zstd/xz to shrink — gzip is mandatory for the RAM lower layer

## Architecture

```
┌────────────────────────────────────────────────────────────────┐
│                      inst-initrd.sh (root)                       │
├────────────────────────────────────────────────────────────────┤
│  Inputs:                                                         │
│    $ROOTFS               ──► the Stage 1 rootfs tree             │
│    kernel.release        ──► <release> string                   │
│    $ROOTFS/lib/modules/<release>/.../overlay.ko[.zst]           │
│    static aarch64 busybox                                        │
│    $ROOTFS/boot/vmlinuz-<release>, $ROOTFS/boot/surface.dtb     │
│                                                                  │
│  Process:                                                        │
│    1. Verify prereqs (tree, tools, busybox is static, overlay)   │
│    2. mksquashfs $ROOTFS → $OUT/rootfs.squashfs  (gzip, -b 1M)   │
│       └─ drop stale 7.0 qcom kernel/initrd; verify gzip; size    │
│    3. Guard: squashfs + overhead must stay < 4 GiB               │
│    4. Assemble initramfs staging tree:                           │
│       /init  /bin/busybox(+applet symlinks)  /overlay.ko         │
│       /rootfs.squashfs(hardlink)  /dev/{console,null}  mnt dirs  │
│    5. cpio -o -H newc (uncompressed) → $OUT/sp12-install.initrd  │
│    6. Guard: initrd < 4 GiB                                       │
│    7. Copy vmlinuz-<release> + surface.dtb → $OUT                │
│    8. Report sizes / headroom / RAM budget                       │
│                                                                  │
│  Output: $OUT = $BUILD/inst/out/                                 │
│    rootfs.squashfs  sp12-install.initrd  vmlinuz-<release>  surface.dtb │
└────────────────────────────────────────────────────────────────┘
```

## Decisions

### gzip squashfs, `-b 1M`
The 7.2 kernel this rootfs boots under had, at pack time, only `CONFIG_SQUASHFS_ZLIB=y`; zstd/xz/lz4 mounted with "compression not supported." So the RAM lower layer **must** be gzip. `-b 1M` (the max block size) claws back some of gzip's worse ratio to help stay under the 4 GiB cap. (A later kernel rebuild added lzo/xz/zstd — but that was so *Ubuntu's snaps* mount inside the running system, not to re-pack this rootfs.)

### Uncompressed `newc` cpio
The squashfs inside is already compressed, so gzip-ing the cpio would burn boot-time CPU for ~no size win. Pack `-H newc` with no compression. `newc` also has a 4 GiB per-entry limit, which — together with FAT32's 4 GiB per-file limit on the ESP — sets the hard cap.

### The 4 GiB cap is a hard guard, checked twice
`newc` cannot represent a ≥4 GiB member and FAT32 cannot store a ≥4 GiB file. Check once *before* building the cpio (squashfs size + a small overhead) to fail fast, and once *after* on the real initrd file. Abort with the byte counts on either.

### Static busybox + applet symlinks
Nothing in the initramfs may depend on the not-yet-mounted rootfs, so busybox must be **statically linked** (verified: `file` reports "statically linked", ELF aarch64) and every applet used by `/init` (`sh mount umount insmod losetup switch_root mkdir` …) is a symlink to `/bin/busybox`.

### `overlay.ko` decompressed into the initramfs
overlayfs is a module in this kernel (squashfs and loop are built-in). Ubuntu installs modules compressed (`overlay.ko.zst`); busybox `insmod` cannot load a compressed module, so the script decompresses to a plain `/overlay.ko` in the initramfs.

### Static `/dev/console` and `/dev/null` nodes
Before `/init` mounts devtmpfs, the kernel still needs `/dev/console` for early output. Bake static `console` and `null` device nodes into the cpio so rescue-shell output is visible even if devtmpfs auto-mount is off.

### `/init` drops to a rescue shell, never panics
Every step in `/init` is guarded; on failure it `exec`s an interactive busybox `sh` on the console so a broken boot is debuggable on the Surface instead of a silent panic.

### The loop-pinned-inode trick
`switch_root` deletes the old initramfs contents — including `/rootfs.squashfs` — to free RAM. That is fine: the loop device holds the inode open, so its RAM pages stay alive and the squashfs/overlay mounts remain pinned. Standard live-boot mechanism.

### `OUT` added to `env.sh`
Per the project rule that `env.sh` is the single source of truth for paths, add `OUT="$(realpath -m "${PROJECT_DIR}/build/inst/out")"` (`realpath -m` so it resolves before the dir exists). Artifact filenames are local knobs in the script.

## Risks / Trade-offs

### Top-level permission check tests intent, not an exact mode
The Stage 1 `unsquashfs -f` footgun is directories going **owner-only** (`700`), which kills non-root services. Stage 2 therefore checks that `/`, `/usr`, `/etc` keep **group+other read+execute** (bitmask `& 5 == 5` on each), rather than demanding an exact `755` — benign group-writable modes like `775` (left by `modules_install`/chroot writes) are fine and must not abort the build.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| gzip ratio pushes the initrd over 4 GiB | `-b 1M`; check size before and after and abort with byte counts |
| Provided busybox is dynamically linked → boot dies pre-rootfs | Prereq verifies `file` reports "statically linked" + ELF aarch64; abort otherwise |
| `overlay.ko` is `.zst` and busybox `insmod` can't load it | Decompress to a plain `/overlay.ko` before packing |
| Doubling the 3.5 GB squashfs into the cpio staging tree fills `$BUILD` | Hardlink the squashfs into staging instead of copying |
| Stale 7.0 qcom kernel/initrd bloats the squashfs | Exclude/remove them from the tree before packing; verify absent in `unsquashfs -l` |
| `mount -o loop` helper missing in this busybox | `/init` falls back to explicit `losetup /dev/loop0` |
