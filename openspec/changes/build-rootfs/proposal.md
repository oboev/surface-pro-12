## Why

Stage 1 produces the **RAM-boot rootfs tree** — the full Ubuntu desktop rootfs that Stage 2 will pack into a squashfs and embed in the initrd. The machine boots it entirely from RAM; no disk installation is involved.

The kernel and modules are already compiled (completed cross-compile change). We now need the full userspace — desktop, firmware, user account — in a single directory tree, ready to be compressed into a squashfs.

## What Changes

- Create `inst-rootfs.sh` that builds the rootfs tree at `$BUILD/inst/root`
- Use `$PROJECT_DIR/scripts/env.sh` as the single source of truth for path variables (`PROJECT_DIR`, `ISO_PATH`, `KERNEL_SRC`, `BUILD`, `ASSETS`, `ROOTFS`, `ISO_MOUNT`); `inst-rootfs.sh` sources it instead of recomputing paths
- Extract the base rootfs from the Resolute ISO's `casper/minimal.squashfs`
- Inject the cross-compiled kernel image, modules, firmware, and device tree blob
- Chroot to reconfigure apt for arm64 ports mirror; create user account; enable GDM autologin
- Hardened against live-boot footguns: mount verification, permission sanity checks, unmount traps

## Capabilities

### New Capabilities

- `rootfs-builder`: Build RAM-boot rootfs tree from Resolute ISO squashfs + kernel artifacts

## Impact

- Requires the Resolute ISO (`resolute-desktop-arm64+x1e.iso`) — 3.9 GB ISO image
- Requires the cross-compiled kernel source (`$KERNEL_SRC`) and its `include/config/kernel.release` for kernel version
- Requires the compiled kernel modules in `$KERNEL_SRC` — installed into the rootfs via `make -C $KERNEL_SRC modules_install INSTALL_MOD_PATH=$ROOTFS` (not copied from `$BUILD/output`) — and the Surface device tree blob (`$ASSETS/boot/dtb`) from the project's `assets/` staging dir (populated from the Surface community repo), not a kernel build product
- Requires the Surface firmware assets (`$ASSETS/lib/firmware/`)
- Requires **arm64 chroot execution on the x86_64 build host** — `qemu-user-static` installed and the `qemu-aarch64` binfmt handler registered (the chroot steps run arm64 `apt-get`/`useradd`/`chpasswd`); verified by prereq 1.7
- The rootfs tree (~3 GB expected) is written to `build/inst/root/` which may need ~4 GB free (squashfs + overhead)
- The script modifies nothing on the host except creating the output tree — it runs as root, so every write/mount must target `${ROOTFS}/…` or `chroot ${ROOTFS}`; a bare host path (e.g. `> /etc/hostname`) would corrupt the build host (see design invariant)
- No disk installer, no GRUB EFI installation, no gdisk/rsync/os-prober — those belong to a separate change (install is implemented later)

## Depends on

- **Cross-compile change** must bake the kernel config this stage relies on but does not set: the Surface Aggregator (SSAM) options for the Type Cover keyboard, and squashfs LZO/XZ/ZSTD decompressors so Ubuntu's snaps mount. Without them the rootfs reaches `graphical.target` but stalls before GNOME. Kernel-config tuning is a Non-Goal here (see design).
