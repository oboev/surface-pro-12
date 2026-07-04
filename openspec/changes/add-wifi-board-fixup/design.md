## Context

`assets/fixwifi.sh` documents and performs the ath12k WCN7850 board-file fix at runtime. See that script for the full rationale (why a bare `board.bin` is needed and which board entry is chosen). This change moves the same fix to build time by shipping the `board.bin` pre-extracted.

## Goals / Non-Goals

**Goals:**
- Wi-Fi works on first boot with no network and no manual step.
- Reuse the existing Stage 1.5 firmware-injection mechanism; minimal new code.

**Non-Goals:**
- Re-explaining ath12k board loading (already in `fixwifi.sh`).
- Auto-detecting the SP12 board ID or verifying RF correctness on hardware.

## Decisions

**D1 — Pre-extract the blob, don't extract at build time.** The extraction is a one-time, deterministic operation; baking `board.bin` in keeps the build offline and dependency-free. *Alternative:* run the extraction inside `inst-rootfs.sh` — rejected: reintroduces the network/`curl`/`python3` dependency for no benefit.

**D2 — In-repo overlay (`firmware/`) over editing `assets/`.** `assets/` is a symlink to a separate, `.gitignore`d repo, so a file dropped there is not tracked by this project. A tracked `firmware/` tree owns the fix explicitly.

**D3 — Copy the overlay after the `assets/` pass, guarded by `[ -d "$FIRMWARE" ]`.** Placing the copy last makes the overlay authoritative on collision; the guard mirrors the existing optional-`/usr`-assets block so a missing overlay is a clean no-op under `set -euo pipefail`.

## Risks / Trade-offs

- **[Board entry is the SP11-derived one from `fixwifi.sh`]** → It loads as a bare `board.bin` (no ID matching), so Wi-Fi associates; if SP12 dmesg wants a different entry, re-extract it (blob-only change). Same trade-off `fixwifi.sh` already makes.
