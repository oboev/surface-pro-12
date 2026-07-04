## Why

`assets/fixwifi.sh` explains and performs the ath12k WCN7850 Wi-Fi fix, but it runs on the booted target and needs network + `curl`/`python3`/`zstd`/`ath12k-bdencoder` — none guaranteed in a RAM-boot install session. Do the extraction once, offline, and bake the resulting `board.bin` into the image so Wi-Fi works on first boot with no network and no manual step.

## What Changes

- Add an in-repo firmware overlay `firmware/`, tracked in this repo (unlike the external `assets/` symlink).
- Ship the pre-extracted `firmware/ath12k/WCN7850/hw2.0/board.bin` (the same board entry `fixwifi.sh` selects), extracted offline instead of at runtime.
- Add a `FIRMWARE` path variable to `scripts/env.sh`.
- Extend Stage 1.5 (`scripts/inst-rootfs.sh`) to merge `$FIRMWARE/.` into the rootfs `/lib/firmware/` after the `assets/` firmware pass, so the overlay wins on collision.

## Non-Goals

- Does not modify or remove `assets/fixwifi.sh` (kept as reference / manual fallback).
- Does not auto-detect the SP12 board ID — ships the entry `fixwifi.sh` uses; hardware RF-correctness is out of scope.

## Capabilities

### New Capabilities
- `wifi-board-fixup`: Ship a pre-extracted ath12k WCN7850 `board.bin` via an in-repo firmware overlay that Stage 1.5 merges into the rootfs.

### Modified Capabilities
<!-- None — additive to rootfs-builder; changes no existing requirement. -->

## Impact

- New tracked file: `firmware/ath12k/WCN7850/hw2.0/board.bin`.
- Modified: `scripts/env.sh` (adds `FIRMWARE`), `scripts/inst-rootfs.sh` (adds the overlay copy step).
- No new build/runtime dependencies. Removes the need to run `fixwifi.sh` post-install for Wi-Fi.
