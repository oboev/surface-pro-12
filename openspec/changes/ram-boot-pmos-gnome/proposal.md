## Why

The `ram-boot-pmos` change RAM-boots the postmarketOS **console** image on the Surface Pro 12 by swapping *only* the rootfs: our Surface-tuned kernel + DTB + firmware + cmdline make the hardware work, and the RAM-boot wrapper (Stage 2 squashfs→cpio initrd, Stage 3 GRUB) is userland-agnostic. This change repoints that same flow at the postmarketOS **GNOME** image so the branch RAM-boots a graphical desktop instead of a text console. Nothing about *why* the hardware boots changes — kernel/DTB/firmware/cmdline are shared with the working console boot — so once again the cheapest correct path is to swap only the rootfs.

The GNOME image is already staged at `iso/20260704-0051-postmarketOS-edge-gnome-4-postmarketos-trailblazer-next.img.xz` (904 MB vs. the console image's 473 MB — still well under Stage 2's 4 GiB initrd cap).

## What Changes

- **Repoint `ISO_PATH` in `scripts/env.sh`** at the GNOME `.img.xz` and update its comment. No new variable — same single "rootfs source image" that `ram-boot-pmos` established.
- **Extend the `inst-rootfs.sh` chroot-config section (§5) for a graphical session.** Everything above §5 (prereq checks, `rm -rf` boundary guard + leaked-mount check, EXIT-trap cleanup, loop-mount/rsync extraction, the kernel/modules/firmware/DTB injection block, the chroot binds) is unchanged. Kept in §5: busybox-static install, root password, hostname, fstab neutralization (`/etc/fstab` placeholder + masking `systemd-remount-fs.service`/`systemd-fsck-root.service`), and the `/sbin/init` sanity check. Added in §5:
  - **Create a non-root user.** GNOME/Wayland (mutter) refuses to run as root and GDM will not do a root graphical login. pmOS's own first-boot user setup lives in the initramfs we discard, so **no user exists in a RAM boot** — one MUST be created here. Create idempotently: prefer `useradd -m`, fall back to busybox `adduser -D`; set the password via `chpasswd`; then add the user to each group that actually exists (`getent group`) out of `wheel video audio input netdev plugdev render`. Never `useradd -G` a possibly-missing group (it fails wholesale).
  - **Enable GDM autologin** by writing `${ROOTFS}/etc/gdm/custom.conf` with `[daemon]`/`AutomaticLoginEnable=True`/`AutomaticLogin=<TARGET_USER>` (Alpine/pmOS GDM reads `/etc/gdm/custom.conf`, not `/etc/gdm3/`). Chosen over the GDM greeter for the same zero-interaction outcome as the console flow's root login: boot → desktop, nothing to type.
  - **Ensure graphical boot** defensively: `systemctl set-default graphical.target` and `systemctl enable gdm` (both likely already true in the GNOME image; set non-fatally).
  - **Optional:** skip the first-run wizard by writing `~<TARGET_USER>/.config/gnome-initial-setup-done` = `yes`, chown'd to the user.
- **New knobs** in `inst-rootfs.sh` near `TARGET_HOSTNAME`/`ROOT_PASSWORD`: `TARGET_USER="user"`, `USER_PASSWORD="surface"` (postmarketOS convention is user `user`).
- **Update the §5 header comment and the §6 completion report** to describe the GNOME graphical session + autologin user + `graphical.target` instead of the root console login.

## Non-Goals

- **No console path, no dual-flavor, no flavor-switch argument.** This branch builds GNOME only; `inst-rootfs.sh` stays one flow — consistent with `ram-boot-pmos`'s single-flavor stance.
- **No new script and no new source-image variable.** The build stays in `inst-rootfs.sh`; the source reuses `ISO_PATH`.
- **No GDM greeter.** Autologin is the chosen zero-interaction outcome; the greeter is explicitly not implemented.
- **No Adreno/mesa bring-up work** beyond what the shared kernel/DTB/firmware already provide. Whether the GPU renders a real GNOME session (vs. software fallback) is verified on-host, not engineered here.
- **No Stage 1, Stage 2, or Stage 3 changes.** Same silicon → same kernel, initrd wrapper, and GRUB cmdline. `cma=128M` (from `ram-boot-pmos`) stays; no cmdline change is needed for GNOME.
- **No internal-disk writes.** RAM boot only; pmOS's own first-boot resize lives in its (unused) initramfs and never runs.
- **No pmbootstrap; no use of trailblazer's own kernel/DTB/initramfs.** We consume the prebuilt image's rootfs and boot our kernel, as in `ram-boot-pmos`.

## Capabilities

### Modified Capabilities
- `pmos-ram-boot`: the source image becomes the postmarketOS **GNOME** `.img.xz`, and the chroot config now provisions a **graphical session with autologin** (create a non-root user, GDM `custom.conf` autologin, `graphical.target`) instead of a root console login. The fstab-neutralization, busybox-static, hostname, injection, and cleanup requirements are unchanged. Stages 1/2/3 (including the `cma=128M` cmdline) are unchanged.

## Impact

- **Modified:** `scripts/env.sh` (`ISO_PATH` repointed to the GNOME image; no new variable), `scripts/inst-rootfs.sh` (new `TARGET_USER`/`USER_PASSWORD` knobs; §5 adds user creation + GDM autologin + `graphical.target`; header/report updated). Everything above §5 unchanged.
- **Unchanged:** `scripts/build-kernel.sh` (Stage 1), `scripts/inst-initrd.sh` (Stage 2 — its Alpine-aware busybox default already picks up the GNOME rootfs's `bin/busybox.static`), `scripts/flash-install.sh` (Stage 3 — `cma=128M` stays; its header comment already says "full GNOME desktop").
- **Inputs:** consumes `iso/20260704-0051-postmarketOS-edge-gnome-4-postmarketos-trailblazer-next.img.xz` (the console `.img.xz` is no longer used on this branch).
- **New build-host tools:** none beyond `ram-boot-pmos` (`losetup`, `xz`, `partx`, `rsync`); the chroot's user-creation uses `useradd`/`usermod` (present via `shadow`, which GNOME/accountsservice pulls in) with a busybox `adduser`/`addgroup` fallback.
