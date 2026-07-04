## 1. In-repo firmware overlay

- [x] 1.1 Create the overlay tree `firmware/ath12k/WCN7850/hw2.0/` and place the precomputed `board.bin` at `firmware/ath12k/WCN7850/hw2.0/board.bin`

## 2. Wire the overlay into the pipeline

- [x] 2.1 Add `FIRMWARE="${PROJECT_DIR}/firmware"` to `scripts/env.sh` under the Inputs section
- [x] 2.2 In `scripts/inst-rootfs.sh`, after the `assets/` firmware pass (`cp -a "${ASSETS}/lib/." "${ROOTFS}/lib/"`, ~line 183), add a guarded step: `if [ -d "$FIRMWARE" ]; then run_with_check "Installing project-local firmware overlay" cp -a "${FIRMWARE}/." "${ROOTFS}/lib/firmware/"; fi`

## 3. Verification

- [x] 3.1 Run `bash -n scripts/env.sh scripts/inst-rootfs.sh` — must pass with no errors
- [x] 3.2 Run `shellcheck -x scripts/inst-rootfs.sh` — must pass with no new errors (only the shared SC1091 info about the sourced `env.sh`)
- [x] 3.3 Verify `FIRMWARE` resolves (spec: "FIRMWARE resolves under the project root"): source `env.sh` and confirm `$FIRMWARE` == `${PROJECT_DIR}/firmware` and the directory exists
- [x] 3.5 Verify overlay precedence (spec: "Overlay wins over assets/base on collision"): confirm the overlay copy runs textually AFTER the `assets/` firmware copy in `inst-rootfs.sh`
