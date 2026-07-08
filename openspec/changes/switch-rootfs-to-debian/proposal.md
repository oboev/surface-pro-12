## Why

The base rootfs should be Debian instead of Ubuntu. The Debian 14 (forky) "generic" arm64 cloud image is available at `iso/debian-14-generic-arm64-daily.tar.xz` and is a leaner, headless starting point. The switch must change as little of the pipeline as possible — only Stage 1.5 (rootfs assembly) and the one input path it consumes.

## What Changes

- **BREAKING** Change the base image input from the Resolute Ubuntu ISO to the Debian generic arm64 cloud image (`env.sh`: `ISO_PATH`, `ISO_MOUNT`).
- Replace Stage 1.5's ISO-mount + `unsquashfs` extraction with: extract `disk.raw` from the `.tar.xz`, loop-mount its ext4 root partition (partition 1) with `losetup -P`, and copy the tree into `$ROOTFS`. Detach the loop device on every exit path.
- Drop the Ubuntu apt *reconfiguration* (disabling live-media sources, pinning `ports.ubuntu.com`/`resolute`): the Debian image already ships correct deb822 sources (`deb.debian.org` forky). Replace it with a chroot apt step — `apt-get update` + install `busybox-static` (the Stage 2 initrd's `/init` requires a static aarch64 busybox that Ubuntu's base shipped but the Debian generic image does not) **plus the desktop stack: `xorg`, `sddm`, `lxqt`, `network-manager`, `nm-tray`**. This makes package installation the one build-time network dependency.
- Desktop target (the generic image ships no desktop): replace the Ubuntu GDM3 autologin with an apt-installed **LXQt desktop on the SDDM login manager plus `xorg` and NetworkManager (`network-manager`, `nm-tray`)**; enable `sddm.service` and `NetworkManager.service`; keep `graphical.target` as the default systemd target.
- Remove `netdev` from the new user's groups (absent in the Debian image; the group-existence guard would otherwise abort).
- Neutralize boot-hang footguns from the cloud image: blank `/etc/fstab` (UUID mounts for `/`, `/boot`, `/boot/efi` that do not exist under RAM/overlay boot) and disable cloud-init (`/etc/cloud/cloud-init.disabled`).
- Kernel/module/firmware/DTB injection and the chroot user/password/hostname setup are unchanged.

## Capabilities

### New Capabilities
<!-- None — this modifies the existing rootfs-builder capability. -->

### Modified Capabilities
- `rootfs-builder`: the base rootfs is sourced from the Debian generic arm64 cloud image (raw-disk loop mount) instead of the Resolute Ubuntu ISO squashfs, and the produced rootfs is a Debian system running an apt-installed LXQt/SDDM graphical desktop with NetworkManager rather than the Ubuntu GNOME/GDM3 desktop.

## Impact

- `scripts/env.sh`: input path variables repointed to the Debian tarball and its mount point.
- `scripts/inst-rootfs.sh`: extraction (section 2), apt config (section 5), and desktop/target config (section 6) rewritten; requires host `losetup -P` (loop partition scanning) and `tar` with xz support in place of `unsquashfs`. `qemu-aarch64` binfmt for the chroot is still required.
- Input: `iso/debian-14-generic-arm64-daily.tar.xz` replaces `iso/resolute-desktop-arm64+x1e.iso`.
