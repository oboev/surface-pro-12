## MODIFIED Requirements

### Requirement: The rootfs source reuses ISO_PATH pointed at the pmOS image
`scripts/env.sh` MUST point the existing `ISO_PATH` variable at the postmarketOS **GNOME** `trailblazer` `.img.xz`. No new source variable (`PMOS_IMG_XZ`/`PMOS_IMG`/`PMOS_SRC_MNT`) is added; `scripts/inst-rootfs.sh` consumes `$ISO_PATH` as the rootfs source. (Changed from the console image to the GNOME image; the console `.img.xz` is no longer referenced on this branch.)

#### Scenario: ISO_PATH resolves to the GNOME image
- **WHEN** a script sources `scripts/env.sh`
- **THEN** `$ISO_PATH` ends in `.img.xz` and names the pmOS **GNOME** `trailblazer` image under `iso/` (matches `*gnome*trailblazer*`)

#### Scenario: no parallel source variable is introduced
- **WHEN** `scripts/env.sh` is inspected
- **THEN** it defines no `PMOS_IMG_XZ`, `PMOS_IMG`, or `PMOS_SRC_MNT`

### Requirement: The chroot configures the systemd userland for a graphical autologin session
After the shared dev/pts/proc/sys binds, `scripts/inst-rootfs.sh` MUST provision a graphical session rather than a root console login. It MUST keep the carried-over steps: ensure a static busybox at `${ROOTFS}/bin/busybox.static` (installing `busybox-static` via `apk` if absent, dying clearly if `apk` fails); set the root password to `$ROOT_PASSWORD`; write `$TARGET_HOSTNAME` to `/etc/hostname`; and verify `/sbin/init` exists. It MUST additionally create a non-root user and enable a GDM autologin graphical boot (see the requirements below). Because GNOME/Wayland (mutter) refuses to run as root and GDM will not perform a root graphical login, and because pmOS's own first-boot user setup lives in the discarded initramfs (so no user exists in a RAM boot), a non-root user MUST be created here for the desktop to start. Any Ubuntu-only configuration (apt sources, `apt-get`, GDM `/etc/gdm3/`, `ports.ubuntu.com`) MUST NOT be present.

#### Scenario: busybox-static is present for Stage 2 after config
- **WHEN** the chroot configuration completes
- **THEN** `${ROOTFS}/bin/busybox.static` exists (satisfying Stage 2's default `BUSYBOX`)

#### Scenario: no Ubuntu-only configuration remains
- **WHEN** the text of `scripts/inst-rootfs.sh` is inspected
- **THEN** it contains no `apt-get`, no `ports.ubuntu.com`, and no `/etc/gdm3/` path

## ADDED Requirements

### Requirement: The chroot creates a non-root user for the GNOME session
`scripts/inst-rootfs.sh` MUST create a non-root user `$TARGET_USER` (default `user`) in the chroot, idempotently: skip if `id -u "$TARGET_USER"` already succeeds; otherwise create with a home directory via `useradd -m`, falling back to busybox `adduser -D`, and die if both fail. It MUST set the user's password to `$USER_PASSWORD` via `chpasswd`. It MUST add the user only to groups that actually exist, iterating over `wheel video audio input netdev plugdev render` and adding to each group `g` only when `getent group $g` succeeds (via `usermod -aG`, or busybox `addgroup` as a fallback). It MUST NOT pass a fixed `useradd -G <grouplist>` (which fails wholesale if any group is missing).

#### Scenario: the user exists after configuration
- **WHEN** the chroot configuration completes
- **THEN** `id -u "$TARGET_USER"` succeeds in the rootfs and the user has a home directory

#### Scenario: group membership degrades gracefully for missing groups
- **WHEN** one of `wheel video audio input netdev plugdev render` does not exist in the image
- **THEN** user creation and the remaining group additions still succeed (no wholesale failure), because each group is added only after `getent group` confirms it exists

#### Scenario: no fixed multi-group useradd is used
- **WHEN** the text of `scripts/inst-rootfs.sh` is inspected
- **THEN** it contains no `useradd -G <comma-separated-list>`; group additions go through a `getent group`-guarded loop

### Requirement: The chroot enables GDM autologin and a graphical default target
`scripts/inst-rootfs.sh` MUST configure GDM to autologin `$TARGET_USER` by writing `${ROOTFS}/etc/gdm/custom.conf` (the Alpine/pmOS GDM config path, not `/etc/gdm3/`) containing a `[daemon]` section with `AutomaticLoginEnable=True` and `AutomaticLogin=$TARGET_USER`. It MUST defensively set the graphical boot: `systemctl set-default graphical.target` and `systemctl enable gdm` in the chroot (non-fatal — the GNOME image likely already sets both). It MAY write a `gnome-initial-setup-done` marker under the user's `~/.config` to skip the first-run wizard.

#### Scenario: GDM custom.conf enables autologin for the user
- **WHEN** the chroot configuration completes
- **THEN** `${ROOTFS}/etc/gdm/custom.conf` contains `AutomaticLoginEnable=True` and `AutomaticLogin=$TARGET_USER` under `[daemon]`

#### Scenario: the default target is graphical
- **WHEN** the text of `scripts/inst-rootfs.sh` is inspected
- **THEN** it runs `systemctl set-default graphical.target` and `systemctl enable gdm` in the chroot

## RENAMED Requirements

- FROM: `### Requirement: The chroot configures the systemd userland for console login`
- TO: `### Requirement: The chroot configures the systemd userland for a graphical autologin session`
