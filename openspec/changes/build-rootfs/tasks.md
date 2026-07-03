## 0. Path configuration

- [ ] 0.1 Use scripts/env.sh as source of truth for variables.

## 1. Verify prerequisites

- [ ] 1.1 Confirm Resolute ISO exists at ISO path (3.9 GB)
- [ ] 1.2 Confirm kernel source exists at KERNEL_SRC with `arch/arm64/boot/Image`
- [ ] 1.3 Confirm DTB assets exist at DTB path
- [ ] 1.4 Confirm output directories can be created (`$BUILD/inst/root/`, `$BUILD/inst/iso/`)

## 2. ISO mount and squashfs extraction

- [ ] 2.1 Create mount point `$BUILD/inst/iso/` and mount ISO read-only (`-o loop,ro`)
- [ ] 2.2 Extract `casper/minimal.squashfs` using `unsquashfs -d $BUILD/inst/root/` (no `-f`)
- [ ] 2.3 Verify ISO is unmounted after extraction
- [ ] 2.4 Sanity check: verify `$BUILD/inst/root/`, `$BUILD/inst/root/usr`, `$BUILD/inst/root/etc` are 755 permissions
- [ ] 2.5 Abort with error if permissions are incorrect

## 3. Inject kernel, modules, firmware, DTB

- [ ] 3.1 Read kernel release string from `linux/include/config/kernel.release`
- [ ] 3.2 Copy `arch/arm64/boot/Image` to `$BUILD/inst/root/boot/vmlinuz-<release>`
- [ ] 3.3 Run `make modules_install` with `INSTALL_MOD_PATH=$BUILD/inst/root/`
- [ ] 3.4 Create `$BUILD/inst/root/lib/firmware/` directory
- [ ] 3.5 Copy firmware files from assets (`$REPO/lib/` → `$BUILD/inst/root/lib/`)
- [ ] 3.6 Copy `/usr/` files from assets if present
- [ ] 3.7 Copy DTB to `$BUILD/inst/root/boot/surface.dtb`

## 4. Chroot — prepare mounts

- [ ] 4.1 Copy `/etc/resolv.conf` into rootfs
- [ ] 4.2 Set up EXIT trap to unmount bind mounts on failure
- [ ] 4.3 Bind-mount `/dev`, `/dev/pts`, `proc`, `sys` into rootfs

## 5. Chroot — apt configuration

- [ ] 5.1 Disable all ISO/live-media apt sources (rename `*.list`/`*.sources` → `*.disabled`)
- [ ] 5.2 Write `/etc/apt/sources.list` with arm64 ports mirror for resolute
- [ ] 5.3 Run `apt-get update`

## 6. Chroot — user and system configuration

- [ ] 6.1 Set hostname to `surface-sp12` in `/etc/hostname`
- [ ] 6.2 Create user `myuser` with groups `sudo,adm,plugdev,netdev,video,audio,render`
- [ ] 6.3 Set passwords: `myuser:surface` and `root:surface`
- [ ] 6.4 Create `/etc/gdm3/custom.conf` with GDM autologin for `myuser`
- [ ] 6.5 Set systemd default target to `graphical.target`

## 7. Cleanup and reporting

- [ ] 7.1 Unmount all chroot bind mounts (`/dev`, `/dev/pts`, `/proc`, `/sys`)
- [ ] 7.2 Remove mount point `$BUILD/inst/iso/`
- [ ] 7.3 Print rootfs tree size summary
- [ ] 7.4 Print completion message with next-stage guidance

## 8. Verification (must pass before archiving)
  
### 8.1 Static analysis (no execution needed)
- [ ] 8.1.1 `bash -n inst-rootfs.sh` exits 0 — script parses as valid bash (guards against zsh-only syntax such as `for a b in …`)
- [ ] 8.1.2 `shellcheck inst-rootfs.sh` reports no errors (catches pipe-precedence bugs like `run_with_check … | chroot chpasswd` and unreachable `|| true` after a function that calls `exit`)
- [ ] 8.1.3 Confirm the script sets `set -euo pipefail` and targets bash
  
### 8.2 Spec-scenario conformance (walk every requirement's THEN)
- [ ] 8.2.1 Prereqs: missing ISO / kernel source (incl. `include/config/kernel.release`) / DTB each abort with a descriptive error
- [ ] 8.2.2 ISO is mounted `-o loop,ro`; `casper/minimal.squashfs` missing aborts cleanly
- [ ] 8.2.3 `unsquashfs` runs WITHOUT `-f` and the rootfs dir is NOT pre-created before extraction
- [ ] 8.2.4 After extraction, `/`, `/usr`, `/etc` are 755; a non-755 result aborts
- [ ] 8.2.5 `boot/vmlinuz-<release>`, `lib/modules/<release>/`, `lib/firmware/`, `boot/surface.dtb`, and (if present) `/usr` assets exist
- [ ] 8.2.6 `/etc/apt/sources.list` contains exactly the resolute / -updates / -security ports entries (no unspecified pockets)
- [ ] 8.2.7 User `myuser` exists with the specified groups; both passwords are set
- [ ] 8.2.8 `/etc/hostname` = `surface-sp12`; `/etc/gdm3/custom.conf` has autologin
- [ ] 8.2.9 `/etc/systemd/system/default.target` is a symlink to `graphical.target` AND the link target exists
- [ ] 8.2.10 No bind mounts remain under the rootfs on success
  
### 8.3 Runtime verification (after a real build run)
- [ ] 8.3.1 Script completes end-to-end with exit code 0
- [ ] 8.3.2 Deliberately fail a mid-chroot step (e.g. rename `useradd`); confirm the EXIT trap unmounts `/dev`, `/dev/pts`, `/proc`,`/sys` — no leaked mounts
- [ ] 8.3.3 `readlink -f <rootfs>/etc/systemd/system/default.target` resolves to a real `graphical.target`
- [ ] 8.3.4 `chroot <rootfs> passwd -S myuser` reports a set password (P), not locked/empty
  
  ### 8.4 Regression checks (one per bug that escaped last time)
- [ ] 8.4.1 The bind-mount loop uses valid bash and maps `/sys` (not `/sysfs`)
- [ ] 8.4.2 `chpasswd` receives only `user:password` on stdin (no log lines)
- [ ] 8.4.3 `default.target` does not point at any SysV `init.d`/`run.levelN` path
- [ ] 8.4.4 The unmount trap fires on *any* failure exit, not only when a prior unmount already failed
