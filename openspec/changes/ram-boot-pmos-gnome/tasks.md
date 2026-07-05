## 1. env.sh — repoint the source at the GNOME image

- [x] 1.1 In `scripts/env.sh`, change `ISO_PATH` to `${PROJECT_DIR}/iso/20260704-0051-postmarketOS-edge-gnome-4-postmarketos-trailblazer-next.img.xz` and update its comment (now the pmOS **GNOME** rootfs source). Do not add any new variable.

## 2. inst-rootfs.sh — new user knobs

- [x] 2.1 Near the existing `TARGET_HOSTNAME`/`ROOT_PASSWORD` knobs (line ~28), add `TARGET_USER="user"` and `USER_PASSWORD="surface"` (postmarketOS convention is user `user`). Keep `ROOT_PASSWORD` (root still gets a password).

## 3. inst-rootfs.sh §5 — create the graphical-session user

Everything above §5 (prereqs, boundary guard, cleanup trap, extraction, injection, chroot binds) is unchanged. Keep the existing §5 steps: busybox-static, root password, hostname, fstab neutralization + unit masking, `/sbin/init` sanity.

- [x] 3.1 Create the user idempotently in the chroot: if `id -u "$TARGET_USER"` fails, `useradd -m -s /bin/bash "$TARGET_USER"`, falling back to `adduser -D "$TARGET_USER"`, dying if both fail.
- [x] 3.2 Set the user password: `printf '%s:%s\n' "$TARGET_USER" "$USER_PASSWORD" | in_chroot chpasswd` (die on failure).
- [x] 3.3 Add the user to each **existing** group only, looping over `wheel video audio input netdev plugdev render`: for each `g`, `getent group $g` and, if present, `usermod -aG $g $TARGET_USER` (fall back to busybox `addgroup $TARGET_USER $g` if `usermod` is absent). Never `useradd -G` a possibly-missing group. Non-fatal per group.

## 4. inst-rootfs.sh §5 — GDM autologin + graphical boot

- [x] 4.1 `mkdir -p "${ROOTFS}/etc/gdm"` and write `${ROOTFS}/etc/gdm/custom.conf` with `[daemon]` / `AutomaticLoginEnable=True` / `AutomaticLogin=${TARGET_USER}`. (Alpine/pmOS GDM reads `/etc/gdm/custom.conf`, not `/etc/gdm3/`.)
- [x] 4.2 Defensively ensure graphical boot: `in_chroot systemctl set-default graphical.target` and `in_chroot systemctl enable gdm`, both non-fatal (likely already set in the GNOME image).
- [x] 4.3 (Optional) Skip the first-run wizard: write `~<TARGET_USER>/.config/gnome-initial-setup-done` containing `yes`, `mkdir -p` the `.config` dir, and chown the path to the user; best-effort/non-fatal.

## 5. inst-rootfs.sh — comments & completion report

- [x] 5.1 Update the §5 header comment to describe the GNOME graphical session (drop the "console login" / any "OpenRC" wording — the image is systemd).
- [x] 5.2 Update the §6 completion report to print the GNOME autologin user (`$TARGET_USER` / `$USER_PASSWORD`), `graphical.target`, and the hostname — instead of the root console line. (Root password still set; may still be reported.)

## 6. Verification

- [x] 6.1 `bash -n scripts/env.sh scripts/inst-rootfs.sh` — passes with no errors.
- [x] 6.2 `shellcheck -x scripts/inst-rootfs.sh` — no new errors (only the shared SC1091 info for the sourced `env.sh`).
- [x] 6.3 Spec "source is the GNOME image": source `env.sh`; assert `$ISO_PATH` ends in `.img.xz` and matches `*gnome*trailblazer*`; `! grep -Eq 'PMOS_IMG_XZ|PMOS_IMG|PMOS_SRC_MNT' scripts/env.sh` (still no parallel variable).
- [x] 6.4 Spec "user is created": `grep -Eq 'useradd|adduser' scripts/inst-rootfs.sh` and `grep -q 'TARGET_USER' scripts/inst-rootfs.sh`; confirm the group-add loop uses `getent group` (no bare `useradd -G <list>`).
- [x] 6.5 Spec "GDM autologin configured": confirm the script writes `etc/gdm/custom.conf` with `AutomaticLoginEnable=True` and `AutomaticLogin=${TARGET_USER}`; `! grep -q 'gdm3' scripts/inst-rootfs.sh`.
- [x] 6.6 Spec "graphical default": `grep -q 'set-default graphical.target' scripts/inst-rootfs.sh` and `grep -Eq 'systemctl enable gdm' scripts/inst-rootfs.sh`.
- [x] 6.7 Spec "carried-over config retained": still masks `systemd-remount-fs.service` + `systemd-fsck-root.service`, still writes the fstab placeholder, still installs busybox-static, still sets hostname + root password, still checks `/sbin/init`. (`! grep -Eq 'apt-get|ports\.ubuntu\.com' scripts/inst-rootfs.sh`.)
- [x] 6.8 Spec "no Stage 1/2/3 change": `git diff --name-only` touches only `scripts/env.sh` + `scripts/inst-rootfs.sh` (not `build-kernel.sh`, `inst-initrd.sh`, or `flash-install.sh`); `grep -q 'cma=128M' scripts/flash-install.sh` still holds.
- [x] 6.8b Regression (first on-host boot showed a console, not GNOME): the decompressed-image cache MUST be source-aware — repointing `$ISO_PATH` (console → GNOME) without deleting `build/inst/src.img` previously reused the stale console image and rsynced the wrong rootfs. `inst-rootfs.sh` now reuses `$SRC_IMG` only when `[ "$SRC_IMG" -nt "$ISO_PATH" ]`. Assert: `grep -q '"$SRC_IMG" -nt "$ISO_PATH"' scripts/inst-rootfs.sh`; and with a stale (older) `src.img` present, the decompress branch is taken.
- [ ] 6.9 On-host (the real functional test — cannot be done from the x86 build host: no root/losetup/qemu): run Stage 1.5 → 2 → 3, boot the USB, and confirm it reaches the **GNOME desktop via autologin** (not emergency mode, not a black screen). Watch for: (a) mutter/Wayland actually renders on the Adreno/DPU proven at `fb0` by the console boot — if it software-falls-back or black-screens, flag mesa/Adreno as follow-up (out of scope); (b) `useradd`/`usermod` really present (else the busybox `adduser`/`addgroup` fallback engaged correctly); (c) `gnome-initial-setup` does not block autologin; (d) the larger GNOME squashfs still fits under Stage 2's 4 GiB cap (its size guard catches it if not).
