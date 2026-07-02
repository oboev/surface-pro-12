## Why

Stage 1 produces the **RAM-boot rootfs tree** — the full Ubuntu desktop rootfs that Stage 2 will pack into a squashfs and embed in the initrd. The machine boots it entirely from RAM; no disk installation is involved.

The kernel and modules are already compiled (completed cross-compile change). We now need the full userspace — desktop, firmware, user account — in a single directory tree, ready to be compressed into a squashfs.

## What Changes

- Create `inst-rootfs.sh` that builds the rootfs tree at `build/inst/root/`
- Extract the base rootfs from the Resolute ISO's `casper/minimal.squashfs`
- Inject the cross-compiled kernel image, modules, firmware, and device tree blob
- Chroot to reconfigure apt for arm64 ports mirror; create user account; enable GDM autologin
- Hardened against live-boot footguns: mount verification, permission sanity checks, unmount traps

## Capabilities

### New Capabilities

- `rootfs-builder`: Build RAM-boot rootfs tree from Resolute ISO squashfs + kernel artifacts

## Impact

- Requires the Resolute ISO (`resolute-desktop-arm64+x1e.iso`) — 3.9 GB ISO image
- Requires the cross-compiled kernel source (`linux/`) and its `include/config/kernel.release` for kernel version
- Requires the surface device-tree assets (`assets/boot/dtb`)
- The rootfs tree (~3 GB expected) is written to `build/inst/root/` which may need ~4 GB free (squashfs + overhead)
- The script modifies nothing on the host except creating the output tree
- No disk installer, no GRUB EFI installation, no gdisk/rsync/os-prober — those belong to a separate change
