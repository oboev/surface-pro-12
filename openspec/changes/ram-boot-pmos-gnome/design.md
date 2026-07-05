## Context

`ram-boot-pmos` established a rootfs-swap RAM-boot pipeline for postmarketOS on the Surface Pro 12: Stage 1 cross-compiles our kernel; Stage 1.5 (`inst-rootfs.sh`) decompresses the pmOS `.img.xz`, loop-mounts its ext4 p2 root, rsyncs it into `$ROOTFS`, injects our kernel/modules/firmware/DTB, and chroots (under `qemu-aarch64-static` + binfmt) to configure the userland; Stage 2 (`inst-initrd.sh`) packs `$ROOTFS` into a gzip squashfs inside a cpio initrd with a static busybox + overlay.ko + `/init` doing `switch_root /mnt/root /sbin/init`; Stage 3 (`flash-install.sh`) writes kernel+dtb+initrd to a GRUB ESP with `clk_ignore_unused pd_ignore_unused cma=128M`.

That pipeline boots the pmOS **console** image to a root text login. This change targets the pmOS **GNOME** image to reach a graphical desktop instead. Everything that makes the hardware boot — kernel, `assets/boot/dtb`, firmware overlay, cmdline — is shared with the working console boot and unchanged. The RAM-boot wrapper (Stage 2/3) is userland-agnostic and unchanged: `switch_root /sbin/init` reaches systemd, which then brings up `graphical.target` and GDM exactly as it would on a disk boot.

The GNOME image is the same kind of artifact as the console one: a GPT `.img.xz` with p1 = EFI/`/boot` (ignored) and p2 = ext4 aarch64 Alpine-userland **systemd** root. It is 904 MB compressed (vs. 473 MB console) — larger, but Stage 2's 4 GiB initrd size guard covers it. So the extraction, injection, cleanup, and fstab-neutralization logic all carry over verbatim; only the *chroot config* gains graphical-session provisioning, and `env.sh` repoints `ISO_PATH`.

## Goals / Non-Goals

**Goals:**
- RAM-boot pmOS GNOME to a working desktop by swapping ONLY the rootfs; reuse Stage 1/2/3 and the whole of `inst-rootfs.sh` above §5 with zero change.
- Reach the desktop with zero interaction (autologin), matching the console flow's zero-typing root login.
- Keep the change inside `inst-rootfs.sh` §5 + one `env.sh` line — one script, one flow — reusing `ISO_PATH` and all existing helpers/guards.

**Non-Goals:**
- Any console path, dual-flavor branching, source-selection argument, or new image variable.
- A GDM greeter (autologin only). Adreno/mesa bring-up beyond the shared kernel/DTB/firmware. pmbootstrap; trailblazer's kernel/DTB/initramfs; internal-disk writes.
- Any Stage 1/2/3 change. `cma=128M` and everything else in Stage 3 stay as `ram-boot-pmos` left them.

## Decisions

**D1 — Repoint, don't branch.** This branch builds GNOME only, so `ISO_PATH` is *repointed* at the GNOME image and the chroot config is *extended* in place — no console path is kept, no `case "$FLAVOR"` is introduced. *Alternative:* a `FLAVOR=console|gnome` switch selecting image + config — rejected: this branch never builds the console image, so the plumbing is dead weight, exactly as `ram-boot-pmos` D2 rejected a dual-source script.

**D2 — Create a non-root user; GNOME cannot run as root.** GNOME/Wayland (mutter) refuses to run as root and GDM will not perform a root graphical login, so a graphical session *requires* a non-root user. In a normal pmOS install that user is created by pmOS's first-boot initramfs setup — but we discard that initramfs and boot our own, so **no user exists** and one MUST be created in the chroot here. *Alternative:* run the whole session as root — rejected: mutter/GDM refuse it; there is no root graphical path.

**D3 — Autologin, not the GDM greeter.** Chosen for the simpler *outcome*: boot → desktop, nothing to type — matching the console flow's zero-interaction root login. Cost is a single GDM config file. *Alternative:* the GDM greeter (type a password each boot) — rejected: it adds interaction for no benefit on a single-user bring-up image.

**D4 — GDM autologin lives in `/etc/gdm/custom.conf`.** Alpine/pmOS package GDM to read `/etc/gdm/custom.conf` (not the Debian `/etc/gdm3/` path). The file is written directly to `${ROOTFS}/etc/gdm/custom.conf` (mkdir -p first) with `[daemon]`/`AutomaticLoginEnable=True`/`AutomaticLogin=<TARGET_USER>`. *Alternative:* `/etc/gdm3/custom.conf` (Debian convention) — rejected: wrong path on Alpine, GDM would ignore it and fall back to the greeter.

**D5 — Portable, idempotent user creation: `useradd` with a busybox `adduser` fallback, and add only to existing groups.** GNOME pulls in `accountsservice`, which almost certainly pulls in `shadow`, so `useradd`/`usermod`/`chpasswd` are expected — but the image is Alpine, whose base provides only busybox `adduser`/`addgroup`, so the fallback keeps this robust if `shadow` is somehow absent. Guard the whole thing with `id -u "$TARGET_USER"` so re-runs are idempotent. Crucially, do **not** pass `useradd -G wheel,video,…`: `useradd -G` fails wholesale if *any* listed group is missing. Instead create the user with a home dir, then loop `for g in wheel video audio input netdev plugdev render`, adding to `$g` only when `getent group $g` succeeds. *Alternative:* a single `useradd -m -G <fixed list>` — rejected: any missing group aborts user creation entirely; the per-group `getent` loop degrades gracefully.

**D6 — Set graphical boot defensively.** `systemctl set-default graphical.target` and `systemctl enable gdm` are run non-fatally even though the GNOME image almost certainly ships them already — cheap insurance that a RAM boot lands in the desktop, not multi-user text. *Alternative:* assume the image defaults — rejected cheaply: the defensive calls are idempotent and harmless, and protect against an image built with a non-graphical default.

**D7 — Skip `gnome-initial-setup` (optional, best-effort).** Write `~<TARGET_USER>/.config/gnome-initial-setup-done` = `yes`, chown'd to the user, so the first-run wizard does not sit in front of the autologin session. Best-effort/non-fatal: if the path or ownership can't be set, autologin still works, the user just sees the wizard once.

**D8 — Everything else in `inst-rootfs.sh` and all of Stage 1/2/3 is unchanged.** The extraction (D4 of `ram-boot-pmos`), injection block, chroot binds, cleanup/loop-unwind, `rm -rf` boundary guard, busybox-static install, root password, hostname, fstab neutralization + unit masking, and `/sbin/init` sanity all carry over verbatim. Stage 2's Alpine-aware busybox default already selects the GNOME rootfs's `bin/busybox.static`. Stage 3's `cma=128M` (ath12k) stays; no GNOME-specific cmdline is needed. *This keeps the diff to one `env.sh` line plus §5 additions.*

## Risks / Trade-offs

- **GPU good-enough-for-GNOME is unverifiable from the x86 build host.** Kernel/DTB/firmware are shared with the working console boot, so the DRM/KMS base (DPU + GMU fw, `fb0`) is present — but whether Adreno/mesa renders a real mutter/Wayland session or falls back to software (llvmpipe) can only be seen on-host. If it's software-only or black-screens, mesa/Adreno work is a separate follow-up (flag it; out of scope here).
- **`useradd` vs. busybox `adduser` uncertainty.** The `shadow` tools are *expected* (accountsservice), not guaranteed. Mitigated by the `adduser -D` fallback and the `getent`-guarded per-group loop (which uses `usermod -aG`, falling back to `addgroup` if only busybox is present). Verify on-host which toolset the image actually ships.
- **`gnome-initial-setup` could block autologin.** Mitigated by D7's `gnome-initial-setup-done` marker; if the marker path is wrong for this GNOME version, the wizard appears once — non-fatal, cosmetically off-brand for a zero-interaction image.
- **Larger rootfs (904 MB vs. 473 MB) → larger squashfs.** Must still fit under Stage 2's 4 GiB initrd cap; the existing size guard will catch it if not. Expected to fit comfortably.
- **Cannot fully verify on the build host** (no `sudo`/`losetup`/`qemu-aarch64-static`). Static-checked (`bash -n`, `shellcheck`) and grep-asserted here; user creation, autologin, and the actual desktop must be exercised on-host (tracked in tasks + HANDOVER).

## Open Questions

- Is Adreno/mesa good enough for a real GNOME session, or does it fall back to software rendering? (Resolve on-host — shared kernel/DTB/firmware means the KMS base should be there.)
- Does the image ship `useradd`/`usermod` (`shadow`), or only busybox `adduser`/`addgroup`? Confirm on-host; the fallback covers both but the primary path assumes `shadow`.
- Does the GNOME image already default to `graphical.target` and enable `gdm`? (D6 sets both defensively, so harmless either way.)
- Final `TARGET_USER`/`USER_PASSWORD` values (`user`/`surface` assumed, pmOS convention).
