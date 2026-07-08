## Context

Stage 1.5 (`scripts/inst-rootfs.sh`) builds the RAM-boot rootfs tree at `$ROOTFS` (`build/inst/root`). Today it consumes the Resolute Ubuntu ISO: loop-mount the ISO read-only, `unsquashfs` its `casper/minimal.squashfs` into `$ROOTFS`, then chroot (via the `qemu-aarch64` binfmt handler) to reconfigure apt and set up a GNOME desktop autologin.

The new base image is the Debian 14 (forky) generic arm64 cloud image at `iso/debian-14-generic-arm64-daily.tar.xz`. Inspection of its `disk.raw` establishes the ground truth this design relies on:

- The tarball's sole member is `disk.raw` — a 3 GiB GPT-partitioned raw disk.
- Partition **1** is the ext4 root (`Linux root (ARM-64)`, sectors 262144–6289407); partition **15** is a 127 MiB EFI system partition. There is no squashfs.
- The image already ships correct deb822 apt sources: `deb.debian.org/debian` `forky`/`-updates`/`-backports` and `deb.debian.org/debian-security` `forky-security`, components `main contrib non-free-firmware non-free`.
- It is **headless** — no GNOME, no GDM3, no `graphical.target` desktop stack.
- `/etc/group` has `sudo adm plugdev video audio render` but **not** `netdev`.
- `/etc/fstab` mounts `/`, `/boot`, and `/boot/efi` by UUID; those UUIDs belong to the raw disk, not the RAM/overlay root.
- cloud-init is installed.

Everything downstream of `$ROOTFS` (kernel/module/firmware/DTB injection, and Stages 2–3) treats `$ROOTFS` as an opaque directory tree and is unaffected.

## Goals / Non-Goals

**Goals:**
- Replace the ISO/squashfs input with the Debian raw-disk image, changing only `env.sh` and `inst-rootfs.sh`.
- Produce a Debian rootfs that boots into a graphical LXQt desktop on the SDDM login manager with NetworkManager for networking.
- Preserve the script's safety posture: mount/loop cleanup on every exit path, the `$ROOTFS` boundary guard, and the leaked-mount checks.
- Keep the existing `ISO_PATH` / `ISO_MOUNT` variable names (repoint, do not rename) to minimize churn.

**Non-Goals:**
- No GNOME desktop (chosen: LXQt, a lighter stack than the Ubuntu GNOME the Ubuntu path shipped).
- No change to Stage 1 (kernel), Stage 2 (initrd), or Stage 3 (flash).
- No support for both Ubuntu and Debian behind a flag — this is a straight replacement.

## Decisions

### D1. Acquire the rootfs via loop-mounting `disk.raw`, not by extracting a squashfs
`unsquashfs -d "$ROOTFS"` is replaced by: `tar -xf "$ISO_PATH" -C <work> disk.raw` → `losetup -Pf --show` → mount `${LOOP}p1` read-only → copy the tree into `$ROOTFS` → unmount → `losetup -d`.

- **Copy mechanism:** `cp -a "${IMG_MOUNT}/." "$ROOTFS/"` preserves ownership, permissions, symlinks, and xattrs and copies dotfiles at the top level. `$ROOTFS` is created (mkdir) first, unlike the old flow where `unsquashfs -d` owned its creation.
- **Root partition selection:** partition 1 is the ext4 root per the GPT. The script asserts `${LOOP}p1` is a block device before mounting rather than silently guessing.
- **Alternatives considered:** (a) `mount -o loop,offset=<bytes>` — avoids `losetup -P` but hardcodes the byte offset and is fragile if the layout shifts; loop with `-P` is cleaner. (b) `guestfish`/`libguestfs` — heavier dependency for no benefit on a root-run host script.

### D2. Trust the image's apt sources; install the initrd and desktop packages
The Ubuntu path had to disable `file:/cdrom` live-media sources and pin `ports.ubuntu.com`. The Debian image already has valid internet deb822 sources, so the source-rewrite block is removed. The chroot apt step now serves two purposes: the image ships **empty** apt lists, **no busybox**, and **no desktop**. Stage 2's initrd `/init` requires a *static aarch64* busybox at `/usr/bin/busybox` (Ubuntu's base squashfs shipped `busybox-static`; the Debian generic image does not), and the target machine needs a usable desktop. So Stage 1.5 runs `apt-get update` (lists are empty) then installs `busybox-static` plus the desktop stack — `xorg`, `sddm`, `lxqt`, `network-manager`, `nm-tray`. This requires network + a working `/etc/resolv.conf` in the chroot — the image's `/etc/resolv.conf` is a dangling symlink into `/run/systemd/resolve`, so it is replaced before the chroot apt runs.

- **Alternatives considered:** (a) ship a prebuilt static busybox blob in the repo — rejected: an unversioned binary to maintain; the project's design intent (per `inst-initrd.sh` comments) is to take busybox from the `busybox-static` package. (b) use the `busybox` (non-static) package — rejected: `inst-initrd.sh` asserts the binary is statically linked. (c) keep the build fully offline — not possible once a package must be installed.

### D3. Graphical desktop: LXQt on SDDM + `graphical.target`
Remove the Ubuntu GDM3 `custom.conf` autologin. The desktop stack (`xorg`, `sddm`, `lxqt`) is apt-installed in D2, so `graphical.target` now exists and is kept as the default. The script:
- enables `sddm.service` (display manager) and `NetworkManager.service` (networking, via `nm-tray` in the tray),
- sets `default.target` → `graphical.target` explicitly (matching the script's existing explicit-default-target style) and verifies the symlink resolves to a real unit.

LXQt was chosen over GNOME as a lighter desktop; SDDM is its conventional login manager. (Autologin is not configured — SDDM prompts for the `myuser`/`surface` credentials.)

### D4. Neutralize cloud-image boot-hang footguns
- **`/etc/fstab`:** overwrite with a comment-only file. Its UUID entries for `/`, `/boot`, `/boot/efi` reference the raw disk; under RAM/overlay boot systemd would block on `local-fs`/`.mount` units for devices that never appear. The overlay `/init` provides root; no fstab entries are needed.
- **cloud-init:** `touch /etc/cloud/cloud-init.disabled` (guarded by `[ -d .../etc/cloud ]`). Prevents first-boot datasource probing (delays/hangs with no cloud datasource) and stops cloud-init from overriding our user/hostname/network setup.

### D5. Drop `netdev` from the user's groups
The group is absent in the Debian image and the script's pre-flight group-existence guard would `die`. New `USER_GROUPS="sudo,adm,plugdev,video,audio,render"`.

## Risks / Trade-offs

- **`losetup -P` partition node timing** → the `${LOOP}pN` node can appear slightly after `losetup` returns. Mitigation: assert `-b "${LOOP}p1"` and, if needed, a short bounded wait / `partprobe` before mounting; fail with a clear error rather than a race.
- **Loop device leak on failure** → a detached-late loop holds the image file. Mitigation: track `LOOP` in a variable and detach it (and unmount `$IMG_MOUNT`) from the same EXIT-trap cleanup that already unwinds the chroot binds.
- **Copying a live-ish rootfs** → the cloud root has empty `/dev`, `/proc`, `/sys`, `/run` mountpoints (plain dirs); `cp -a` copies them as empty dirs, which is correct. No device nodes to preserve.
- **Disk space** → `disk.raw` is 3 GiB extracted; combined with `$ROOTFS` the build needs materially more scratch space than the squashfs flow. Mitigation: extract to the `build/` tree and delete `disk.raw` after the copy.
- **Build-time desktop download** → installing `xorg`/`sddm`/`lxqt`/NetworkManager pulls a large dependency set over the network in the chroot, lengthening Stage 1.5 and making it network-dependent. Accepted: the generic image ships no desktop, so this is unavoidable to reach a usable graphical system.

## Migration Plan

1. Repoint `ISO_PATH`/`ISO_MOUNT` in `env.sh` to the Debian tarball and its mount point.
2. Rewrite `inst-rootfs.sh` sections 2, 5, 6 per the decisions above; leave sections 3 (inject) and 4 (chroot mounts) intact.
3. `bash -n` + `shellcheck -x` the script.
4. Run Stage 1.5 as root; verify `$ROOTFS/etc/os-release` is Debian forky, the user exists with the reduced group set, the LXQt/SDDM desktop is installed, `default.target` → `graphical.target`, `/etc/fstab` is blank, and cloud-init is disabled.
5. Update README base-image references.

Rollback: revert the two files and restore the Resolute ISO path — no persisted state outside `build/`.
