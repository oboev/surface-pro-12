## ADDED Requirements

### Requirement: The rootfs source reuses ISO_PATH pointed at the pmOS image
`scripts/env.sh` MUST point the existing `ISO_PATH` variable at the postmarketOS `trailblazer` `.img.xz`. No new source variable (`PMOS_IMG_XZ`/`PMOS_IMG`/`PMOS_SRC_MNT`) is added; `scripts/inst-rootfs.sh` consumes `$ISO_PATH` as the rootfs source.

#### Scenario: ISO_PATH resolves to the pmOS image
- **WHEN** a script sources `scripts/env.sh`
- **THEN** `$ISO_PATH` ends in `.img.xz` and names the pmOS `trailblazer` image under `iso/`

#### Scenario: no parallel source variable is introduced
- **WHEN** `scripts/env.sh` is inspected
- **THEN** it defines no `PMOS_IMG_XZ`, `PMOS_IMG`, or `PMOS_SRC_MNT`

### Requirement: inst-rootfs.sh builds the pmOS rootfs from the image root partition
`scripts/inst-rootfs.sh` MUST build a single (pmOS) rootfs: decompress the `$ISO_PATH` `.img.xz` to a scratch `.img` under `$BUILD` (skipping if already present), loop-mount the image's **second** partition (the ext4 aarch64 root) read-only, and populate `$ROOTFS` with `rsync -aHAX --numeric-ids`. The root-partition offset MUST be computed dynamically (via `losetup -P` partition nodes or `partx`), never hardcoded. `$ROOTFS` MUST remain the same `build/inst/root` path Stage 2 consumes. The p2 mount MUST be unmounted and the loop device detached once the rsync completes. The Ubuntu-only extraction (`unsquashfs` of `casper/minimal.squashfs`) MUST be gone.

#### Scenario: rootfs is built from p2 into the Stage 2 path
- **WHEN** `inst-rootfs.sh` runs
- **THEN** it loop-mounts the image's second partition and rsyncs it into `$ROOTFS` (= `${PROJECT_DIR}/build/inst/root`), the identical path `inst-initrd.sh` reads

#### Scenario: partition offset is not hardcoded
- **WHEN** the text of `scripts/inst-rootfs.sh` is inspected
- **THEN** it contains no hardcoded sector offset `999424` and derives the root partition from `losetup -P` and/or `partx`

#### Scenario: no ISO/unsquashfs extraction remains
- **WHEN** the text of `scripts/inst-rootfs.sh` is inspected
- **THEN** it contains no `unsquashfs` and no `casper/minimal.squashfs` reference

### Requirement: Kernel, modules, firmware, and DTB injection is retained
`scripts/inst-rootfs.sh` MUST keep the existing injection block: copy the compiled `Image` to `${ROOTFS}/boot/vmlinuz-<REL>` (`<REL>` from `${KERNEL_SRC}/include/config/kernel.release`), `make … INSTALL_MOD_PATH=$ROOTFS modules_install`, merge `${ASSETS}/lib/.` and (if present) `${FIRMWARE}/.` into the rootfs firmware tree, and copy `${ASSETS}/boot/dtb` to `${ROOTFS}/boot/surface.dtb`.

#### Scenario: injected artifacts are present after injection
- **WHEN** the injection block completes at kernel release `<REL>`
- **THEN** `${ROOTFS}/boot/vmlinuz-<REL>`, `${ROOTFS}/lib/modules/<REL>/`, and `${ROOTFS}/boot/surface.dtb` all exist

### Requirement: The chroot configures the systemd userland for console login
After the shared dev/pts/proc/sys binds, `scripts/inst-rootfs.sh` MUST: ensure a static busybox exists at `${ROOTFS}/bin/busybox.static` (installing `busybox-static` via `apk` if absent, dying with a clear message if `apk` fails, e.g. offline); set the root password to `$ROOT_PASSWORD`; write `$TARGET_HOSTNAME` to `/etc/hostname`; and verify `/sbin/init` exists. The Ubuntu-only configuration (apt sources, `apt-get`, `useradd`, GDM, `graphical.target`) and its knobs MUST be removed.

Note: the `trailblazer` console image's `/sbin/init` is **systemd** (confirmed on-host — `systemd-journald`/`emergency.service` present), not OpenRC as earlier assumed. Stage 2's `switch_root /sbin/init` is init-agnostic, so this does not change the flow; it only governs how the image's boot units (fstab, remount-fs) must be handled — see the fstab-neutralization requirement below.

#### Scenario: busybox-static is present for Stage 2 after config
- **WHEN** the chroot configuration completes
- **THEN** `${ROOTFS}/bin/busybox.static` exists (satisfying Stage 2's default `BUSYBOX`)

#### Scenario: no Ubuntu-only configuration remains
- **WHEN** the text of `scripts/inst-rootfs.sh` is inspected
- **THEN** it contains no `apt-get`, no `useradd`, no `gdm3`, no `graphical.target`, and no `ports.ubuntu.com`

### Requirement: The chroot neutralizes the image fstab for RAM boot
The rsync'd pmOS root ships its own `/etc/fstab` referencing the original ext4 root, the ESP (`/boot`, a FAT `98A5-E1A0`-style UUID), and TPM devices — none of which exist in a RAM boot. Under systemd this makes `systemd-remount-fs` fail and blocks boot ~90s per phantom device before dropping to `emergency.service` (sulogin) instead of a console login. `scripts/inst-rootfs.sh` MUST, in the chroot config, overwrite `${ROOTFS}/etc/fstab` with a no-mount RAM-boot placeholder and mask the disk-bound units (`systemd-remount-fs.service`, `systemd-fsck-root.service`). Root is provided by the initrd overlay, so no fstab entry is needed.

#### Scenario: fstab carries no disk mounts after config
- **WHEN** the chroot configuration completes
- **THEN** `${ROOTFS}/etc/fstab` contains no device/UUID mount entries (only a RAM-boot placeholder comment), so systemd reaches a console login rather than emergency mode

#### Scenario: disk-bound units are masked
- **WHEN** the text of `scripts/inst-rootfs.sh` is inspected
- **THEN** it masks `systemd-remount-fs.service` and `systemd-fsck-root.service` in the chroot

### Requirement: Cleanup unwinds the loop mount and device
The EXIT-trap cleanup in `scripts/inst-rootfs.sh` MUST, in addition to the chroot-bind unmounts, unmount the p2 mount and detach the loop device on every exit path. The existing `rm -rf "$ROOTFS"` boundary guard (refusing any path other than `${PROJECT_DIR}/build/inst/root`) and the leaked-mount check MUST continue to protect the rebuild.

#### Scenario: loop device and mount are released on failure
- **WHEN** the script exits (success or failure) after loop-mounting p2
- **THEN** the EXIT trap has unmounted the p2 mount and detached the loop device (no leaked `losetup` entry for the scratch image)

### Requirement: Stage 3 cmdline reserves CMA for ath12k Wi-Fi
`scripts/flash-install.sh` MUST append `cma=128M` to `BASE_CMDLINE`, in addition to the required `clk_ignore_unused pd_ignore_unused`. Under RAM boot the squashfs+overlay fragment memory, so ath12k's (WCN7850) large contiguous QMI DMA allocation fails without a reserved CMA pool. This is the only Stage 3 change and is purely additive.

#### Scenario: cma is present on the kernel cmdline
- **WHEN** `scripts/flash-install.sh` is inspected
- **THEN** `BASE_CMDLINE` contains `cma=128M` alongside `clk_ignore_unused` and `pd_ignore_unused`

### Requirement: Stage 2 busybox default is Alpine-aware
`scripts/inst-initrd.sh` MUST default `BUSYBOX` to `${ROOTFS}/bin/busybox.static` when that file exists, and otherwise fall back to `${ROOTFS}/usr/bin/busybox`. An explicit `BUSYBOX=/path` from the environment MUST still take precedence over both. The existing static+aarch64 verification MUST remain, so a dynamic/musl or wrong-arch binary still aborts loudly.

#### Scenario: pmOS rootfs selects the static busybox
- **WHEN** `inst-initrd.sh` runs with `BUSYBOX` unset and `${ROOTFS}/bin/busybox.static` present
- **THEN** the selected `$BUSYBOX` is `${ROOTFS}/bin/busybox.static`

#### Scenario: fallback path is used when no static busybox is present
- **WHEN** `inst-initrd.sh` runs with `BUSYBOX` unset, no `${ROOTFS}/bin/busybox.static`, and `${ROOTFS}/usr/bin/busybox` present
- **THEN** the selected `$BUSYBOX` is `${ROOTFS}/usr/bin/busybox`

#### Scenario: explicit override wins
- **WHEN** `inst-initrd.sh` runs with `BUSYBOX=/custom/busybox` set in the environment
- **THEN** the selected `$BUSYBOX` is `/custom/busybox` regardless of which rootfs files exist
