## Why

Stage 2 turns the Stage 1 rootfs **tree** (`$ROOTFS = $BUILD/inst/root`) into the two artifacts that make the machine boot Ubuntu **entirely from RAM**: a compressed **`rootfs.squashfs`** and the **`sp12-install.initrd`** that carries that squashfs inside it — an "OS-in-a-file" initramfs.

We do this because the Surface's Linux USB path (`dwc3-qcom`) drops offline under load, but GRUB/UEFI USB reads are reliable. So we let firmware read the whole OS into RAM in one shot (kernel + ~3.5 GB initrd), then a tiny `/init` stacks a writable tmpfs overlay and `switch_root`s into it — after which USB is never touched again.

## What Changes

- Create `scripts/inst-initrd.sh` (run as root) that consumes `$ROOTFS` and produces, under a new `$OUT = $BUILD/inst/out`:
  - `rootfs.squashfs` — the full rootfs packed with `mksquashfs -comp gzip -b 1M -noappend`
  - `sp12-install.initrd` — an **uncompressed** `cpio -H newc` initramfs carrying the squashfs, a static aarch64 busybox + applet symlinks, `overlay.ko`, and a custom `/init`
  - `vmlinuz-<release>` and `surface.dtb` — copied out for the Stage 3 ESP
- Add an `OUT` output path to `scripts/env.sh` (the single source of truth); `inst-initrd.sh` sources `env.sh` rather than recomputing paths
- Pack the squashfs with **gzip specifically** (the 7.2 kernel had only `CONFIG_SQUASHFS_ZLIB=y` at the time this rootfs mounts as the RAM lower layer)
- Drop the ISO's stale 7.0 qcom kernel/initrd from the image (dead weight — RAM boot uses the ESP's initrd, not one inside the squashfs)
- Enforce the **4 GiB** hard cap on the initrd (`newc` per-file limit *and* FAT32's 4 GiB file limit) — abort before and after packing if it would be exceeded
- Embed a `/init` that mounts the squashfs read-only (loop), stacks a tmpfs overlay, moves the pseudo-filesystems, and `switch_root`s into `/sbin/init`; on any failure it drops to an interactive rescue shell on the console instead of panicking

## Non-Goals

- Building the rootfs tree — that is Stage 1 (`build-rootfs`); this stage only consumes `$ROOTFS`
- Kernel configuration — the squashfs decompressors and SSAM options are baked by the cross-compile change; tuning them here is out of scope
- Writing the install USB, GRUB, or `grub.cfg` — that is Stage 3 (`flash-install.sh`)
- Any disk partitioning, GRUB EFI install, or `switch_root` target beyond `/sbin/init` — the machine boots purely from RAM
- Re-packing the squashfs with zstd/xz to shrink it — gzip is required for the RAM lower layer; a later re-pack is a separate optimization

## Capabilities

### New Capabilities

- `initrd-builder`: Pack the Stage 1 rootfs tree into a gzip squashfs and an OS-in-a-file RAM-boot initramfs, plus copy out the kernel and DTB for the ESP.

## Impact

- Consumes the Stage 1 output tree `$ROOTFS` (`$BUILD/inst/root`); requires it to exist, be non-empty, and have top-level `755` perms (guards against the `unsquashfs -f` footgun propagating into Stage 2)
- Requires a **static aarch64 busybox** (verified statically linked + ELF aarch64). Defaults to the rootfs's own `usr/bin/busybox` (shipped by the `busybox-static` package, so no external fetch); overridable via `BUSYBOX=/path`. The script aborts if it is missing, dynamically linked, or not aarch64
- Requires the kernel release string from `linux/include/config/kernel.release`, the kernel `Image`/`vmlinuz-<release>`, `overlay.ko` (or `overlay.ko.zst`, which the script decompresses) from `$ROOTFS/lib/modules/<release>/`, and `surface.dtb`
- Requires host tools `mksquashfs` (squashfs-tools) and `cpio`
- Writes ~3.5 GB (`rootfs.squashfs`) + ~3.5 GB (`sp12-install.initrd`) to `$OUT`; needs roughly **8 GB free** in `$BUILD` (hardlink the squashfs into the initramfs staging tree to avoid a third copy)
- The initrd must stay **under 4 GiB**; the script aborts rather than emit an initrd GRUB/FAT32 cannot carry
- Runs as root (for faithful ownership in the squashfs/cpio); no host paths outside `$OUT` and a staging dir under `$BUILD` are written

## Depends on

- **`build-rootfs` (Stage 1)** must have produced `$ROOTFS` with the 7.2 kernel/modules/firmware/DTB injected and top-level `755` perms.
- **Cross-compile change** must have built `CONFIG_SQUASHFS_ZLIB=y` (so the gzip squashfs mounts as the RAM lower layer) and `overlay` as a loadable module (`overlay.ko`, ridden along in the initramfs).
