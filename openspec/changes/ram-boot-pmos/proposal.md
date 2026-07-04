## Why

The existing pipeline RAM-boots **Ubuntu** on the Surface Pro 12 by pairing our Surface-tuned kernel + DTB + firmware with a userland-agnostic RAM-boot wrapper (Stage 2 squashfs→cpio initrd, Stage 3 GRUB). This branch (`pmos`) is dedicated to RAM-booting **postmarketOS** (device `trailblazer`) on the same hardware. Because what makes the hardware work is *our* kernel/DTB/firmware — none of it Ubuntu-specific — the cheapest correct path is to swap **only the rootfs**: convert Stage 1.5 to build the pmOS rootfs and keep everything else.

## What Changes

- **Convert `scripts/inst-rootfs.sh` to build the pmOS rootfs** (this branch drops the Ubuntu path). Replace the Ubuntu-specific *extraction* (mount ISO → `unsquashfs`) with the pmOS one (decompress the `.img.xz`, loop-mount its ext4 root partition p2, `rsync` into `$ROOTFS`), and replace the Ubuntu *chroot config* (apt sources, `useradd`, GDM, `graphical.target`) with the pmOS one (`apk add busybox-static`, root password, hostname, **fstab neutralization for RAM boot**, `/sbin/init` sanity). The image's init is **systemd** (not OpenRC as earlier assumed); its stock fstab references the original disk root, ESP, and TPM, so it MUST be blanked and the disk-bound units masked, or systemd drops to emergency mode instead of a console login. The kernel/modules/firmware/DTB injection block, the chroot bind scaffolding, and the safety scaffolding (root/binfmt checks, `rm -rf` boundary guard, EXIT-trap cleanup, leaked-mount check) are kept.
- **Reuse the existing source-path variable** rather than adding one: point `ISO_PATH` in `scripts/env.sh` at the pmOS `.img.xz`. No `PMOS_IMG_XZ`.
- Change the default `BUSYBOX` in Stage 2 (`scripts/inst-initrd.sh`) to prefer the Alpine/pmOS static busybox (`${ROOTFS}/bin/busybox.static`) and fall back to `${ROOTFS}/usr/bin/busybox`. Alpine's `/bin/busybox` is musl-*dynamic* and would (correctly) fail the existing static+aarch64 check.
- Remove the now-dead Ubuntu-only knobs from `inst-rootfs.sh` (`SQUASHFS_REL`, `UBUNTU_SUITE`, `PORTS_MIRROR`, `TARGET_USER`, `USER_PASSWORD`, `USER_GROUPS`).
- Leave `scripts/build-kernel.sh` (Stage 1) unchanged. In `scripts/flash-install.sh` (Stage 3), append a single additive token `cma=128M` to `BASE_CMDLINE` so ath12k (WCN7850 Wi-Fi) gets a contiguous DMA pool under RAM boot — otherwise its ~7 MB QMI DMA alloc fails on the memory-fragmented RAM-boot host. No other Stage 3 change.

## Non-Goals

- **No Ubuntu path, no dual-flavor, no source-selection argument.** This branch builds pmOS only; `inst-rootfs.sh` has a single flow.
- **No new script and no new env variable.** The build stays in `inst-rootfs.sh`; the source reuses `ISO_PATH`.
- **No graphical UI.** The `-console-` image boots to a text login; mesa/Adreno bring-up is out of scope (kernel/DTB/firmware are shared, so it should carry over later).
- **No pmbootstrap.** We consume the already-downloaded prebuilt image, not a freshly-built one.
- **No use of trailblazer's own kernel/DTB/initramfs.** They target the Qualcomm X1E reference board; we deliberately discard them and boot ours.
- **No internal-disk writes.** RAM boot only; pmOS's own first-boot resize lives in its (unused) initramfs and never runs.
- **No change to Stage 1.** Same silicon → same kernel and GRUB. Stage 3's only change is the additive `cma=128M` cmdline token for ath12k; `clk_ignore_unused pd_ignore_unused` and everything else stay.

## Capabilities

### New Capabilities
- `pmos-ram-boot`: Build the RAM-boot rootfs from the postmarketOS `trailblazer` image (rootfs swap only) in the existing Stage 1.5 script, and make Stage 2's busybox default Alpine-aware, so the existing initrd/flash stages boot pmOS to a console login unchanged.

### Modified Capabilities
<!-- None — openspec/specs/ has no established specs; this is the first spec for the (now pmOS) rootfs builder. -->

## Impact

- **Modified:** `scripts/inst-rootfs.sh` (Ubuntu extraction + config replaced by the pmOS ones; shared scaffolding/injection kept), `scripts/inst-initrd.sh` (busybox default now Alpine-aware), `scripts/env.sh` (`ISO_PATH` repurposed to the pmOS image; no new variable).
- **Modified (Stage 3):** `scripts/flash-install.sh` — `BASE_CMDLINE` gains `cma=128M` for ath12k; no other change.
- **Unchanged:** `scripts/build-kernel.sh`.
- **Inputs:** consumes `iso/20260704-0052-postmarketOS-edge-console-0.1-postmarketos-trailblazer-next.img.xz` (the resolute ISO is no longer used on this branch).
- **New build-host tools:** `losetup`, `xz` (decompress), plus existing `partx`/`rsync`; the pmOS chroot's `apk add busybox-static` needs network (or a pre-staged static busybox).
- **No change** to Stage 1; Stage 3 only gains the `cma=128M` cmdline token.
