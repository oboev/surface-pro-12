# What this project is

Project creates a set of scripts to produce a bootable Ubuntu USB on a **Microsoft Surface Pro 12** (Snapdragon X, ARM64) entirely from RAM. The machine boots from USB, loads the OS into RAM, then never reads the USB again.

---

# How to create a bootable image

```bash
# 1. Checkout external deps
# git clone --depth=1 https://github.com/torvalds/linux.git
# git clone https://github.com/harrisonvanderbyl/surface-pro-12-inch-linux.git
# wget -c https://people.canonical.com/~platform/images/ubuntu-concept/resolute-desktop-arm64+x1e.iso

# 2. Update env.sh
# KERNEL_SRC=".../linux"
# ASSETS=".../surface-pro-12-inch-linux"
# ISO_PATH=".../resolute-desktop-arm64+x1e.iso"

# 3. Build kernel
./scripts/build.sh

# 4. Assemble rootfs
sudo ./scripts/inst-rootfs.sh

# 5. Build initrd
sudo ./scripts/inst-initrd.sh

# 6. Flash USB
sudo ./scripts/flash-install.sh /dev/sdX
```

# Build pipeline — three stages

Run from the project root. Each stage must complete successfully before the next.

## Stage 1: Cross-compile kernel

```bash
./scripts/build.sh
```

Cross-compiles the ARM64 kernel from the `linux/` tree. Forces Surface-specific config symbols (Surface Aggregator, Surface HID, squashfs decompressors, ACPI, serial drivers, etc.). Outputs to `build/output/`: `vmlinuz`, `dtb`, `modules/`, `config`, `System.map`, `build-info.txt`.

**Prerequisites:** `gcc-aarch64-linux-gnu`, kernel tree with compiled `Image`.

## Stage 1.5: Assemble rootfs

```bash
sudo ./scripts/inst-rootfs.sh
```

Extracts the ISO's `casper/minimal.squashfs` into `build/inst/root/`, injects the custom kernel + modules + firmware + DTB, then chroots (via `qemu-aarch64-static` + binfmt) to configure apt for the arm64 ports mirror, create user `aleksey` (password `surface`), enable GDM3 autologin, and set `graphical.target` as default.

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

Wipes and repartitions the USB (GPT + single FAT32 ESP), copies kernel/DTB/initrd, installs GRUB (removable arm64-efi), writes a two-entry `grub.cfg` ("Try in RAM" default + "INSTALL").
