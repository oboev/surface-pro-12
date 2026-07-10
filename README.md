# What this project is

Project creates a set of scripts to produce a bootable **postmarketOS GNOME** USB on a **Microsoft Surface Pro 12** (Snapdragon X, ARM64) entirely from RAM. The machine boots from USB, loads the OS into RAM, then never reads the USB again — dropping straight into a GNOME desktop (GDM autologin) with the internal disk untouched.

---

# How to create a bootable image

```bash
# 1. Checkout external deps
# git clone --depth=1 https://github.com/torvalds/linux.git
# git clone https://github.com/harrisonvanderbyl/surface-pro-12-inch-linux.git
# download trailblazer image from https://images.postmarketos.org/bpo/edge/postmarketos-trailblazer/

# 2. Update env.sh
# KERNEL_SRC=".../linux"
# ASSETS=".../surface-pro-12-inch-linux"
# ISO_PATH=".../20260704-0051-postmarketOS-edge-gnome-4-postmarketos-trailblazer-next.img.xz"

# 3. Build kernel
./scripts/build-kernel.sh

# 4. Assemble rootfs
sudo ./scripts/inst-rootfs.sh

# 5. Build initrd
sudo ./scripts/inst-initrd.sh

# 6. Flash USB
sudo ./scripts/flash-install.sh /dev/sdX
```

# Build pipeline — staged

Run from the project root. Each stage must complete successfully before the next.

## Stage 0 (optional): Clean state

```bash
sudo ./scripts/cleanup.sh
```

Removes every build-generated artifact so the pipeline runs from scratch: the entire `build/` tree plus the in-tree kernel build (`git clean -dfx` in the kernel checkout — config, intermediates, objects, `vmlinux`, `Image`). Prints a summary with sizes and requires an exact `yes` confirmation; idempotent and requires root.

## Stage 1: Cross-compile kernel

```bash
./scripts/build-kernel.sh
```

Cross-compiles the ARM64 kernel in the `linux/` source tree. Forces Surface-specific config symbols (Surface Aggregator, Surface HID, squashfs decompressors, ACPI, serial drivers, etc.).

**Prerequisites:** `gcc-aarch64-linux-gnu`, kernel tree with compiled `Image`.

## Stage 1.5: Assemble rootfs

```bash
sudo ./scripts/inst-rootfs.sh
```

Decompresses the postmarketOS trailblazer image, loop-mounts its ext4 root partition (p2), and rsyncs it into `build/inst/root/`. Injects the custom kernel + modules + firmware + DTB, then chroots (via `qemu-aarch64-static` + binfmt) to install a static busybox, set the hostname and root password, and create a non-root user `user` (password `surface`) with GDM autologin into GNOME (mutter/Wayland won't run as root, and a RAM boot discards pmOS's own first-boot user setup).

**Prerequisites:** Stage 1 complete, `qemu-user-static` with binfmt handler registered, run as root.

## Stage 2: Build RAM-boot initrd

```bash
sudo ./scripts/inst-initrd.sh
```

Packs the rootfs into `build/inst/out/rootfs.squashfs` (gzip, 1 MiB blocks), then embeds it in an uncompressed newc cpio initrd (`sp12-install.initrd`) along with static busybox, `overlay.ko`, and a ~40-line `/init` script.

**Outputs:** `build/inst/out/` — `rootfs.squashfs`, `sp12-install.initrd`, `vmlinuz-<release>`, `surface.dtb`.

## Stage 3: Flash install USB

```bash
sudo ./scripts/flash-install.sh /dev/sdX
```

Wipes and repartitions the USB, copies kernel/DTB and the ~3.5 GB OS-in-a-file initrd, installs GRUB (removable arm64-efi), and writes a single-entry `grub.cfg` ("Try in RAM (no disk changes)"). The rootfs squashfs is not copied separately — it rides inside the initrd, so the internal disk is never touched.

**Prerequisites:** Stage 2 complete, run as root, Secure Boot OFF on the Surface.
