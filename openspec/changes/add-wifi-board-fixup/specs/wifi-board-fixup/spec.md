## ADDED Requirements

### Requirement: env.sh exposes the firmware overlay path
`scripts/env.sh` MUST define a canonical `FIRMWARE` variable resolving to `${PROJECT_DIR}/firmware`, consistent with the other input path variables. Scripts MUST consume `$FIRMWARE` rather than recomputing the path.

#### Scenario: FIRMWARE resolves under the project root
- **WHEN** a script sources `scripts/env.sh`
- **THEN** `$FIRMWARE` equals `${PROJECT_DIR}/firmware` and points at the in-repo overlay directory

### Requirement: Stage 1.5 merges the firmware overlay into the rootfs
`scripts/inst-rootfs.sh` MUST copy the contents of `$FIRMWARE` into the rootfs firmware tree (`${ROOTFS}/lib/firmware/`) using `cp -a "${FIRMWARE}/." "${ROOTFS}/lib/firmware/"`. This copy MUST run AFTER the `assets/` firmware pass (`cp -a "${ASSETS}/lib/." "${ROOTFS}/lib/"`) so overlay files win on any path collision. The step MUST be guarded so a missing `$FIRMWARE` directory is a no-op rather than an error (consistent with `set -euo pipefail`).

#### Scenario: Overlay wins over assets/base on collision
- **WHEN** a file with the same path exists in both the `assets/` firmware pass and the `$FIRMWARE` overlay
- **THEN** the resulting rootfs file matches the `$FIRMWARE` overlay copy (overlay applied last)
