## ADDED Requirements

### Requirement: Base rootfs is sourced from the Debian generic arm64 cloud image
Stage 1.5 MUST build the rootfs tree from the Debian 14 (forky) generic arm64 cloud image (`$ISO_PATH`, the `.tar.xz` at `iso/debian-14-generic-arm64-daily.tar.xz`) instead of a Resolute Ubuntu ISO squashfs. The image's sole tar member is a GPT-partitioned `disk.raw` whose partition 1 is the ext4 root.

To obtain the tree, the script MUST: extract `disk.raw` from the tarball, attach it as a loop device with partition scanning (`losetup -P`), mount the ext4 root partition read-only, and copy its contents into `$ROOTFS` preserving ownership, permissions, and symlinks. The script MUST assert the root partition node is a block device before mounting rather than assuming it appeared.

#### Scenario: Debian image is expanded into the rootfs tree
- **WHEN** Stage 1.5 runs with `$ISO_PATH` pointing at the Debian generic arm64 tarball
- **THEN** `disk.raw` is extracted, its root partition is loop-mounted, and its tree is copied into `$ROOTFS`
- **AND** `$ROOTFS/etc/os-release` identifies the system as Debian forky

#### Scenario: Root partition node is missing
- **WHEN** the loop device is attached but its partition-1 node does not appear
- **THEN** the script aborts with a clear error and does not attempt to mount

### Requirement: Loop device and mounts are released on every exit path
The script MUST detach the loop device and unmount the image root partition on every exit path (success or failure), using the same cleanup that unwinds the chroot bind mounts. `disk.raw` MUST be removed after the copy so it does not persist as a stale multi-gigabyte artifact.

#### Scenario: Failure after loop attach
- **WHEN** any step fails after `disk.raw` is loop-mounted
- **THEN** the mount is unmounted and the loop device is detached before the script exits

#### Scenario: Successful build
- **WHEN** the rootfs build completes
- **THEN** no loop device remains attached to `disk.raw`, the image mount point is unmounted, and `disk.raw` has been removed

### Requirement: Apt is not reconfigured, but the initrd and desktop packages are installed
The Debian image already ships valid deb822 sources (`deb.debian.org` forky), so the script MUST NOT rewrite apt sources. However, the image ships empty apt lists, no busybox, and no desktop. The script MUST run `apt-get update` (lists are empty) then install, in the chroot:
- `busybox-static` — the Stage 2 initrd requires a static aarch64 busybox at `/usr/bin/busybox`; and
- the graphical desktop stack: `xorg`, `sddm`, `lxqt`, `network-manager`, `nm-tray`.

Because this needs name resolution in the chroot, the script MUST provide a working `/etc/resolv.conf`, replacing the image's dangling `/etc/resolv.conf` symlink rather than failing on it.

#### Scenario: busybox-static and the desktop are present after the build
- **WHEN** Stage 1.5 completes
- **THEN** `$ROOTFS/usr/bin/busybox` exists and is a statically linked aarch64 binary
- **AND** the LXQt/SDDM desktop and NetworkManager packages are installed
- **AND** the image's original deb822 apt sources are unchanged

#### Scenario: chroot apt can resolve names
- **WHEN** the chroot apt step runs and the image's `/etc/resolv.conf` is a dangling symlink
- **THEN** `/etc/resolv.conf` is replaced with a working resolver and the install is not blocked by the dangling link

### Requirement: Rootfs boots to an LXQt graphical desktop
The generic image has no desktop, so Stage 1.5 MUST install and enable one. The script MUST enable `sddm.service` as the display manager and `NetworkManager.service` for networking, and MUST set `graphical.target` as the default systemd target, verifying the `default.target` symlink resolves to a real unit.

#### Scenario: Boot target and display manager
- **WHEN** the rootfs build completes
- **THEN** `default.target` resolves to `graphical.target`
- **AND** `sddm.service` and `NetworkManager.service` are enabled

### Requirement: Cloud-image boot-hang footguns are neutralized
The generic cloud image carries state that breaks RAM/overlay boot. The script MUST blank `/etc/fstab` (its UUID mounts for `/`, `/boot`, and `/boot/efi` reference the raw disk, not the overlay root) and MUST disable cloud-init (`/etc/cloud/cloud-init.disabled`) when cloud-init is present.

#### Scenario: fstab is neutralized
- **WHEN** the rootfs build completes
- **THEN** `$ROOTFS/etc/fstab` contains no active mount entries

#### Scenario: cloud-init is disabled
- **WHEN** the image contains a cloud-init configuration directory
- **THEN** `$ROOTFS/etc/cloud/cloud-init.disabled` exists

### Requirement: Target user is created with groups present in the Debian image
The script MUST add the target user only to groups that exist in the Debian image. `netdev` is absent in the generic image, so the user's group set MUST be `sudo,adm,plugdev,video,audio,render`. The existing group-existence pre-flight guard MUST still pass for every group in the set.

#### Scenario: User creation with the Debian group set
- **WHEN** the target user is created
- **THEN** the user belongs to `sudo,adm,plugdev,video,audio,render` and the build does not abort on a missing group
