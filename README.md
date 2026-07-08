# What this project is

Project creates a set of scripts to produce a bootable Debian USB on a **Microsoft Surface Pro 12** (Snapdragon X, ARM64) entirely from RAM. The machine boots from USB, loads the OS into RAM, then never reads the USB again.

---

# How to create a bootable image

```bash
# 1. Checkout external deps
# git clone --depth=1 https://github.com/torvalds/linux.git
# git clone https://github.com/harrisonvanderbyl/surface-pro-12-inch-linux.git
# Place the Debian 14 (forky) generic arm64 daily cloud image at
#   iso/debian-14-generic-arm64-daily.tar.xz

# 2. Update env.sh
# KERNEL_SRC=".../linux"
# ASSETS=".../surface-pro-12-inch-linux"
# ISO_PATH=".../iso/debian-14-generic-arm64-daily.tar.xz"

# 3. Build kernel
./scripts/build-kernel.sh

# 4. Assemble rootfs
sudo ./scripts/inst-rootfs.sh

# 5. Build initrd
sudo ./scripts/inst-initrd.sh

# 6. Flash USB
sudo ./scripts/flash-install.sh /dev/sdX
```

# Build pipeline — three stages

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

Extracts `disk.raw` from the Debian generic arm64 cloud image, loop-mounts its ext4 root partition (`losetup -P`), and copies the tree into `build/inst/root/`. Injects the custom kernel + modules + firmware + DTB, then chroots (via `qemu-aarch64-static` + binfmt) to install a static busybox and the **LXQt desktop on the SDDM login manager** (plus `xorg` and NetworkManager), create user `myuser` (password `surface`), enable `sddm.service`/`NetworkManager.service`, set `graphical.target` as default, and neutralize cloud-image boot footguns (blank `/etc/fstab`, disable cloud-init). The Debian image already ships correct deb822 sources, so apt is not reconfigured.

**Prerequisites:** Stage 1 complete, `qemu-user-static` with binfmt handler registered, host `losetup -P` + xz-capable `tar`, network access (for the apt install), run as root.

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

Wipes and repartitions the USB (GPT + single FAT32 ESP), copies kernel/DTB/initrd, installs GRUB (removable arm64-efi), writes a two-entry `grub.cfg` ("Try in RAM" default + "INSTALL").
