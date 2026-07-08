## 1. Repoint the input path (env.sh)

- [x] 1.1 Repoint `ISO_PATH` to `${PROJECT_DIR}/iso/debian-14-generic-arm64-daily.tar.xz` and update its comment to describe the Debian raw-disk image (keep the variable name `ISO_PATH`)
- [x] 1.2 Keep `ISO_MOUNT` as the loop-mounted root-partition mount point; update its comment (no rename)

## 2. Rewrite extraction — Debian raw disk (inst-rootfs.sh §2)

- [x] 2.1 Update the file header comment (lines ~5–17) to describe the Debian generic arm64 cloud image instead of the Resolute ISO/squashfs
- [x] 2.2 Replace the Ubuntu constants: remove `SQUASHFS_REL`, `UBUNTU_SUITE`, `PORTS_MIRROR`; keep `TARGET_USER`/`USER_PASSWORD`/`ROOT_PASSWORD`/`TARGET_HOSTNAME`
- [x] 2.3 Prereq check: replace the "Resolute ISO" check with a check for the Debian tarball at `$ISO_PATH`; confirm host has `losetup` with `-P` support and `tar` xz support
- [x] 2.4 Extract `disk.raw` from the tarball into a scratch dir under `build/` (`tar -xf "$ISO_PATH" -C <work> disk.raw`); assert the file exists
- [x] 2.5 Attach with `LOOP="$(losetup -Pf --show "$DISK_RAW")"`; assert `${LOOP}p1` is a block device (bounded wait / `partprobe` fallback) before mounting
- [x] 2.6 `mkdir -p "$ROOTFS"`, mount `${LOOP}p1` read-only at `$ISO_MOUNT`, then `cp -a "${ISO_MOUNT}/." "$ROOTFS/"`
- [x] 2.7 Unmount `$ISO_MOUNT`, `losetup -d "$LOOP"`, and `rm -f "$DISK_RAW"`
- [x] 2.8 Extend `unmount_all`/cleanup trap to also unmount `$ISO_MOUNT` and detach the tracked `$LOOP` on any exit path; keep the `$ROOTFS` boundary guard and leaked-mount checks
- [x] 2.9 Keep the `/`, `/usr`, `/etc` = 755 sanity check after the copy (update its comment: real ext4 rootfs, not unsquashfs)

## 3. Chroot apt: install the initrd package + desktop stack (inst-rootfs.sh §5)

- [x] 3.1 Delete the Ubuntu source-rewrite (live-media disabling, `ports.ubuntu.com` sources.list); leave the image's deb822 sources untouched
- [x] 3.2 Keep a working `/etc/resolv.conf` for the chroot: replace the image's dangling symlink (section 4.1)
- [x] 3.3 In the chroot, `apt-get update` (lists are empty) then `apt-get install -y busybox-static` (the Stage 2 initrd needs a static aarch64 busybox at `/usr/bin/busybox`) plus the desktop stack `xorg sddm lxqt network-manager nm-tray`

## 4. Desktop + boot-hang fixes (inst-rootfs.sh §6)

- [x] 4.1 Set `USER_GROUPS="sudo,adm,plugdev,video,audio,render"` (drop `netdev`)
- [x] 4.2 Replace the GDM3 `custom.conf` step with `systemctl enable sddm.service`; also `systemctl enable NetworkManager.service`
- [x] 4.3 Keep `default.target` → `graphical.target` (now that the LXQt/SDDM/xorg stack is installed the unit exists); verify the symlink resolves to a real unit
- [x] 4.4 Blank `$ROOTFS/etc/fstab` (comment-only file)
- [x] 4.5 Disable cloud-init: `touch "$ROOTFS/etc/cloud/cloud-init.disabled"` guarded by `[ -d "$ROOTFS/etc/cloud" ]`
- [x] 4.6 Update the completion/summary message (drop "Ubuntu" wording; note Debian + SDDM login)

## 5. Documentation

- [x] 5.1 Update README.md base-image references and the Stage 1.5 description (Ubuntu ISO/squashfs/GDM desktop → Debian generic image/raw-disk copy/LXQt+SDDM desktop); update the checkout/env.sh setup snippet

## 6. Verification

- [x] 6.1 `bash -n scripts/inst-rootfs.sh` and `bash -n scripts/env.sh` pass
- [x] 6.2 `shellcheck -x scripts/inst-rootfs.sh` passes (exit 0, clean)
- [x] 6.3 Run Stage 1.5 as root; confirm the loop device is detached and `disk.raw` removed on completion, and no mounts leak under `$ROOTFS` or at `$ISO_MOUNT`
- [x] 6.4 Confirm `$ROOTFS/etc/os-release` is Debian forky; `/`, `/usr`, `/etc` are 755
- [x] 6.5 Confirm the user exists with groups `sudo,adm,plugdev,video,audio,render`; passwords set; hostname set
- [x] 6.6 Confirm `default.target` → `graphical.target`, `sddm.service`/`NetworkManager.service` are enabled, `/etc/fstab` has no active entries, and `/etc/cloud/cloud-init.disabled` exists
- [x] 6.7 Confirm downstream Stage 2 (`inst-initrd.sh`) still consumes `$ROOTFS` unchanged (packs `rootfs.squashfs`)

> Verification note: 6.1/6.2 confirmed by static checks. 6.3–6.7 confirmed end-to-end by building the full pipeline and booting the resulting USB on a Surface Pro 12: the device boots the Debian rootfs from RAM into the LXQt desktop via SDDM, with NetworkManager for Wi-Fi.
