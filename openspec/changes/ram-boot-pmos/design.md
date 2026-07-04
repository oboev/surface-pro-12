## Context

The current pipeline RAM-boots Ubuntu: Stage 1 cross-compiles the Surface kernel; Stage 1.5 (`inst-rootfs.sh`) extracts the Resolute ISO squashfs into `$ROOTFS` and injects our kernel/modules/firmware/DTB, then chroots to configure apt/user/GDM/target; Stage 2 (`inst-initrd.sh`) packs `$ROOTFS` into a gzip squashfs carried inside an uncompressed cpio initrd with a static busybox + overlay.ko + `/init`; Stage 3 (`flash-install.sh`) writes kernel+dtb+initrd to a GRUB ESP with the `clk_ignore_unused pd_ignore_unused` cmdline.

This branch (`pmos`) is dedicated to postmarketOS, so Stage 1.5 is *converted* to build pmOS — there is no Ubuntu path to keep. The Surface hardware works because of *our* kernel + `assets/boot/dtb` + firmware overlay + that cmdline — none of which is Ubuntu-specific. The RAM-boot wrapper (Stage 2/3) is userland-agnostic: its `/init` does `switch_root /mnt/root /sbin/init`, which OpenRC satisfies as readily as systemd. Build host is x86_64 Debian; the target is aarch64, so the chroot runs under `qemu-aarch64-static` + binfmt.

A prebuilt pmOS `trailblazer` image is already downloaded at `iso/20260704-…-trailblazer-next.img.xz`. Decompressed it is a GPT disk with p1 = EFI/`/boot` (pmOS's own kernel+initramfs+reference DTBs — we ignore it) and p2 = ext4 aarch64 root (Alpine userland running **systemd** — confirmed on-host; earlier notes assumed OpenRC). No LUKS.

Within `inst-rootfs.sh`, most of the flow is already OS-agnostic and is kept: prereq checks, the `rm -rf` boundary guard + leaked-mount check, the EXIT-trap cleanup, the kernel/modules/firmware/DTB injection block, the chroot bind mounts, and the size report. Only two segments are Ubuntu-specific and get replaced: **extraction** (mount ISO → `unsquashfs`) and **chroot config** (apt sources, `useradd`, GDM, default target).

## Goals / Non-Goals

**Goals:**
- RAM-boot pmOS to a console login by swapping ONLY the rootfs; reuse Stage 1/2/3 with the minimum possible change.
- Keep the change inside the existing `inst-rootfs.sh` — one script, one flow — reusing its helpers, guards, injection block, and source-path variable.
- Keep `$ROOTFS` = `build/inst/root` so Stage 2 is byte-for-byte the same consumer.

**Non-Goals:**
- Any Ubuntu path, dual-flavor branching, or source-selection argument — this branch is pmOS-only.
- A separate script or a new image path variable.
- Graphical UI / mesa / Adreno bring-up; pmbootstrap; using trailblazer's kernel/DTB/initramfs; touching the internal disk.
- Changing Stage 1. Stage 3 changes only by the additive `cma=128M` cmdline token (D9); no other Stage 3 change.

## Decisions

**D1 — Swap only the rootfs; keep our kernel/DTB/firmware.** trailblazer's kernel/DTB target the Qualcomm X1E reference board; ours is tuned for this exact device and already boots it under Ubuntu. *Alternative:* boot pmOS's own kernel — rejected: loses the Surface DTB/firmware/cmdline that make the hardware work.

**D2 — Convert `inst-rootfs.sh` in place; no new script, no flavor switch.** The branch is pmOS-only, so the two Ubuntu-specific segments (extraction, chroot config) are *replaced* by their pmOS equivalents rather than branched. The ~80% that is OS-agnostic (helpers, guards, EXIT-trap cleanup, injection block, chroot binds, report) is kept verbatim. *Alternative:* a second `inst-rootfs-pmos.sh`, or a `case "$FLAVOR"` dual-source script (both earlier plans) — rejected: this branch never builds Ubuntu, so keeping that code is dead weight and the flavor plumbing is unneeded complexity.

**D3 — Reuse `ISO_PATH` as the source; no new variable.** `ISO_PATH` already names the rootfs source image in `env.sh`; repoint it at the pmOS `.img.xz`. The decompressed image and its p2 mount are per-run scratch (derived locally under `$BUILD`), not first-class paths worth an env entry. *Alternative:* add `PMOS_IMG_XZ` (an earlier plan) — rejected: a parallel variable when `ISO_PATH` already exists. *Note:* the `ISO_PATH` name now points at a `.img.xz`; kept as-is to minimize churn (only `env.sh` + `inst-rootfs.sh` reference it) — a rename to an OS-neutral name is a trivial follow-up if wanted.

**D4 — pmOS extraction: decompress, then loop-mount p2 via `losetup -P`, deriving the partition dynamically.** Decompress `.img.xz` to a scratch `.img` under `$BUILD` (skip if present). `losetup -Pf --show "$IMG"` returns a loop device and creates `…p1`/`…p2` nodes; mount `…p2` read-only. The root partition is derived from the table (`partx` cross-check), never a hardcoded sector. `rsync -aHAX --numeric-ids` copies p2 into `$ROOTFS`; the mount is unmounted and the loop device detached immediately after. *Alternative:* `mount -o loop,offset=$((999424*512))` — rejected: hardcodes a layout a re-download could change.

**D5 — Reuse the existing injection block and chroot binds unchanged.** Kernel `Image` → `vmlinuz-<REL>`, `modules_install`, `assets/lib` + `firmware/` overlay, `assets/boot/dtb` → `surface.dtb`, and the dev/pts/proc/sys binds are already OS-agnostic; they run unchanged. Only the extraction (D4) and the post-bind config (D6) are new.

**D6 — pmOS chroot config: `busybox-static`, root password, hostname, `/sbin/init` sanity.** Stage 2's default `BUSYBOX` needs a *static* busybox; Alpine ships it as `busybox-static` at `/bin/busybox.static` (skip `apk add` if already present; die with a clear offline message if `apk` fails). A known root password guarantees console login. The Ubuntu-only steps (apt sources, `apt-get`, `useradd`, GDM, `graphical.target`) and their knobs are removed. `TARGET_HOSTNAME` (`surface-sp12`) and `ROOT_PASSWORD` (`surface`) stay.

**D8 — Neutralize the image's fstab for RAM boot.** The rsync'd root ships a `/etc/fstab` listing the original ext4 root, the ESP (`/boot`, FAT UUID `98A5-E1A0`), and TPM devices. Under systemd (D-note below), none exist in a RAM boot: `systemd-remount-fs` fails and boot blocks ~90s per phantom device, then drops to `emergency.service` (sulogin) — observed on-host. So the chroot config overwrites `/etc/fstab` with a no-mount placeholder and masks `systemd-remount-fs.service` + `systemd-fsck-root.service`; root is provided by the initrd overlay. *Alternative:* leave fstab and rely on `nofail`/`x-systemd.device-timeout` — rejected: still fails remount-fs and still degrades the boot. *Note:* the image's init is **systemd**, not OpenRC as D6/the earlier plan assumed; this doesn't affect Stage 2's init-agnostic `switch_root` (D2), only which boot units must be neutralized here.

**D9 — Add `cma=128M` to the Stage 3 kernel cmdline for ath12k Wi-Fi.** On-host, the WCN7850 (`0004:01:00.0`) enumerates and loads firmware, but `qmi dma allocation failed (~7 MB type 1)` — under RAM boot the squashfs+overlay fragment memory so ath12k's large contiguous QMI DMA alloc fails (it worked on the disk-backed Ubuntu boot). Reserving a dedicated CMA pool via `cma=128M` gives ath12k its contiguous buffer regardless of overlay pressure. This is the *only* Stage 3 change and it's additive (a single cmdline token appended to `BASE_CMDLINE` after `clk_ignore_unused pd_ignore_unused`). *Alternatives:* raise CMA in the kernel defconfig (Stage 1) — rejected: cmdline is the lighter, per-boot-tunable lever and keeps Stage 1 untouched; or leave it and accept flaky Wi-Fi — rejected: bring-up is unreliable across boots. *Size:* 128M comfortably covers the ~7 MB alloc with headroom for other CMA users; bump if a larger alloc ever fails.

**D7 — Stage 2 busybox default becomes Alpine-aware (prefer `bin/busybox.static`, fall back `usr/bin/busybox`).** This is the single Stage 2 change and the single reason it needs one: Alpine's `/bin/busybox` is musl-*dynamic* and the existing static+aarch64 check would (correctly) reject it. An explicit `BUSYBOX=` env still wins; the verification stays. Everything else in Stage 2 (`switch_root /sbin/init`, overlay.ko from our modules, gzip squashfs, stale-kernel exclude) works unchanged. The fallback keeps the line harmless even though this branch no longer produces a `usr/bin/busybox` rootfs.

## Risks / Trade-offs

- **`apk add busybox-static` needs network inside the chroot** → die with a clear, actionable message on failure; allow pre-staging (skip when `/bin/busybox.static` already present). Documented as a prerequisite.
- **p2's `/boot` is an empty mountpoint** (pmOS's kernel lives on p1, which we ignore) → Stage 2's stale-kernel exclude simply finds our injected `vmlinuz-<REL>` and nothing to exclude; no conflict.
- **pmOS kernel modules under p2 `/lib/modules/<pmos-kernel>` are dead weight** in the squashfs (we boot our kernel + our modules) → tolerated (image bloat only); optional future exclude in Stage 2.
- **Leaked loop device / mount on a mid-run failure** → the EXIT-trap cleanup gains an unmount of the p2 mount and a `losetup -d`; the existing boundary guard + leaked-mount check protect the `rm -rf`.
- **Cannot fully verify on this build host** (no `sudo`/`losetup`/`qemu-aarch64-static`) → scripts are static-checked (`bash -n`, `shellcheck`) and behavior-asserted by text inspection here; the loop-mount/chroot/boot steps must be exercised on a host with root + those tools (tracked in verification + HANDOVER's on-host TODO).

## Open Questions

- Does the image's `apk` repository config resolve on first `apk add` (network), or should a static busybox be pre-staged offline? Resolve during on-host verification.
- ~~Confirm `/sbin/init` in the image is OpenRC and that a getty is spawned on the console.~~ **Resolved on-host:** init is **systemd**; the console login was initially blocked by the stock fstab (root/ESP/TPM devices absent in RAM boot) dropping systemd to `emergency.service` — fixed by D8 (fstab neutralization + unit masking).
- ~~ath12k Wi-Fi under RAM boot (follow-up, out of scope).~~ **Folded in as D9.**
