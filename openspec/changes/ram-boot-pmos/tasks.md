## 1. env.sh — repoint the source at the pmOS image

- [x] 1.1 In `scripts/env.sh`, change `ISO_PATH` to `${PROJECT_DIR}/iso/20260704-0052-postmarketOS-edge-console-0.1-postmarketos-trailblazer-next.img.xz` and update its comment (now the pmOS rootfs source, not the resolute ISO). Do not add any new variable.

## 2. Stage 2 — Alpine-aware busybox default

- [x] 2.1 In `scripts/inst-initrd.sh`, change the default `BUSYBOX` (line ~37) so that, when `BUSYBOX` is unset, it is `${ROOTFS}/bin/busybox.static` if that file exists, else `${ROOTFS}/usr/bin/busybox`; an explicit `BUSYBOX=` from the environment still wins. Update the surrounding comment to mention the Alpine/pmOS static path. Leave the downstream static+aarch64 verification unchanged.

## 3. inst-rootfs.sh — replace Ubuntu extraction with pmOS extraction

- [x] 3.1 Remove the Ubuntu-only knobs (`SQUASHFS_REL`, `UBUNTU_SUITE`, `PORTS_MIRROR`, `TARGET_USER`, `USER_PASSWORD`, `USER_GROUPS`). Keep `CROSS_COMPILE`, `KERNEL_RELEASE_FILE`, `TARGET_HOSTNAME`, `ROOT_PASSWORD`, `CHROOT_BINDS`.
- [x] 3.2 Prereqs: keep root/binfmt/kernel-Image/kernel-release/DTB checks; check `$ISO_PATH` (the `.img.xz`) exists; additionally require `losetup`, `partx`, `rsync`, `xz`.
- [x] 3.3 Replace the ISO-mount + `unsquashfs` block: if `$ISO_PATH` is `.img.xz`, decompress to a scratch `SRC_IMG="${BUILD}/inst/src.img"` via `xz -dc` (skip if present; die on failure). `LOOP="$(losetup -Pf --show "$SRC_IMG")"` (track for cleanup); derive/confirm the root partition dynamically with `partx` (no hardcoded `999424`); mount `${LOOP}p2` read-only at a scratch `SRC_MNT="${BUILD}/inst/src"`.
- [x] 3.4 `mkdir -p "$ROOTFS"`; `rsync -aHAX --numeric-ids "${SRC_MNT}/" "${ROOTFS}/"`; then `umount "$SRC_MNT"` and `losetup -d "$LOOP"` (clear the tracked loop var). Drop the ISO 755-perm check (that was an `unsquashfs` footgun guard; N/A for rsync).
- [x] 3.5 Extend `unmount_all`/`cleanup` to also unmount `$SRC_MNT` and `losetup -d` the tracked loop device, idempotently. Keep the `rm -rf "$ROOTFS"` boundary guard and leaked-mount check unchanged.

## 4. inst-rootfs.sh — replace Ubuntu chroot config with pmOS config

- [x] 4.1 Keep the kernel/modules/firmware/DTB injection block (~lines 160-201) and the chroot bind-mount setup unchanged.
- [x] 4.2 Remove the Ubuntu config: disable-apt-sources, ports `sources.list`, `apt-get update`, `useradd`, GDM `custom.conf`, and the `graphical.target` default link.
- [x] 4.3 Add the pmOS config: if `${ROOTFS}/bin/busybox.static` absent, `in_chroot apk add busybox-static` (die with a clear offline message on failure; re-check the file exists). Set root password via `printf 'root:%s\n' "$ROOT_PASSWORD" | in_chroot chpasswd`. Write `${ROOTFS}/etc/hostname` = `$TARGET_HOSTNAME`. Sanity: `[ -e "${ROOTFS}/sbin/init" ]` or die. (No user creation; console login is root.)
- [x] 4.4 Update the completion/report section for pmOS (report `root`/`$ROOT_PASSWORD` console login and `$TARGET_HOSTNAME`; drop the Ubuntu user/autologin line).
- [x] 4.5 Neutralize the image fstab for RAM boot (the image runs **systemd**): overwrite `${ROOTFS}/etc/fstab` with a no-mount placeholder comment and `in_chroot systemctl mask systemd-remount-fs.service systemd-fsck-root.service` (non-fatal). Without this the stock fstab's disk root + ESP (`98A5-E1A0`) + TPM entries fail remount-fs and hang boot ~90s each, dropping systemd to `emergency.service` instead of a console login.

## 4b. flash-install.sh (Stage 3) — reserve CMA for ath12k Wi-Fi

- [x] 4b.1 In `scripts/flash-install.sh`, append `cma=128M` to `BASE_CMDLINE` (keep `clk_ignore_unused pd_ignore_unused`), with a comment explaining the RAM-boot CMA-starvation reason. Purely additive; no other Stage 3 change.

## 5. Verification

- [x] 5.1 `bash -n scripts/env.sh scripts/inst-initrd.sh scripts/inst-rootfs.sh` — passes with no errors.
- [x] 5.2 `shellcheck -x scripts/inst-rootfs.sh scripts/inst-initrd.sh` — no new errors (only the shared SC1091 info for the sourced `env.sh`).
- [x] 5.3 Spec "ISO_PATH resolves to the pmOS image" + "no parallel source variable": source `env.sh`, assert `$ISO_PATH` ends in `.img.xz` and names the trailblazer image; `! grep -Eq 'PMOS_IMG_XZ|PMOS_IMG|PMOS_SRC_MNT' scripts/env.sh`.
- [x] 5.4 Spec "no ISO/unsquashfs extraction remains": `! grep -Eq 'unsquashfs|casper/minimal\.squashfs' scripts/inst-rootfs.sh`.
- [x] 5.5 Spec "partition offset not hardcoded": `! grep -q 999424 scripts/inst-rootfs.sh`; confirm it uses `losetup -P`/`partx`.
- [x] 5.6 Spec "no Ubuntu-only configuration remains": `! grep -Eq 'apt-get|useradd|gdm3|graphical\.target|ports\.ubuntu\.com' scripts/inst-rootfs.sh`.
- [x] 5.7 Spec "cleanup unwinds loop mount": inspect that the EXIT trap unmounts `$SRC_MNT` and calls `losetup -d`, and that the `rm -rf` boundary guard + leaked-mount check remain.
- [x] 5.8 Spec "Stage 2 busybox default": statically confirm the selection logic — `busybox.static` when present, `usr/bin/busybox` fallback, explicit `BUSYBOX=` wins.
- [x] 5.9 Spec "fstab neutralized": `bash -n scripts/inst-rootfs.sh` passes; confirm it overwrites `${ROOTFS}/etc/fstab` and masks `systemd-remount-fs.service` + `systemd-fsck-root.service` in the chroot.
- [x] 5.9b Spec "Stage 3 cma": `bash -n scripts/flash-install.sh` passes; `grep -q 'cma=128M' scripts/flash-install.sh` and `BASE_CMDLINE` still contains `clk_ignore_unused` + `pd_ignore_unused`.
- [x] 5.10 On-host boot (done): RAM boot succeeds — overlay-on-squash root, internal disk untouched, our kernel `7.2.0-rc1` + pmOS edge userland. Working: Surface Aggregator (SAM 14.101.139), display/GPU (DPU + GMU fw, `fb0`), Bluetooth. **Findings feeding the edits above:** (a) init is **systemd**, not OpenRC; (b) stock fstab (root/ESP/TPM) dropped systemd to `emergency.service` → fixed by 4.5; (c) ath12k enumerates + loads fw but `qmi dma allocation failed` (CMA starvation, flaky across boots) → fixed by Stage 3 `cma=128M` (4b.1); (d) audio (`tplg.bin`) + HW video decode (`.mbn`) firmware missing.
- [x] 5.11 Post-fix on-host confirm: reaches a normal pmOS console login (`surface-sp12 login:` + `Welcome to postmarketOS! o/`), **not** emergency mode. `systemctl list-jobs` shows only `systemd-time-wait-sync`/`time-sync.target` (NTP; RTC starts at 1970) — **no tpm0/disk jobs**, so the earlier TPM timeouts were transient and **no TPM unit mask is needed** beyond 4.5. ath12k probed clean on this boot (`wcn7850 hw2.0`, MSI 16, fw loaded, no qmi dma failure), confirming the CMA fix stabilizes an otherwise flaky bring-up.
