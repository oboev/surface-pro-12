## ADDED Requirements

### Requirement: Script exists and sources env.sh
The system SHALL provide `scripts/build-kernel.sh`, executable, starting with `set -euo pipefail`, that sources `scripts/env.sh` for all path variables and resolves every input/output relative to those variables (never the caller's working directory).

#### Scenario: Script exists and is executable
- **WHEN** the project is set up
- **THEN** `scripts/build-kernel.sh` exists and has the executable permission set

### Requirement: Toolchain installation
The build script SHALL verify and install the `gcc-aarch64-linux-gnu` cross-compilation toolchain via `apt` if not already present.

#### Scenario: Toolchain already installed
- **WHEN** `aarch64-linux-gnu-gcc` is available on the system
- **THEN** the script proceeds without attempting to install anything

#### Scenario: Toolchain not installed
- **WHEN** `aarch64-linux-gnu-gcc` is not found
- **THEN** the script installs `gcc-aarch64-linux-gnu` via `apt`

### Requirement: Kernel source verification
The build script SHALL verify that the kernel source directory exists at `linux/` and contains a valid kernel tree (at minimum a `Makefile`).

#### Scenario: Kernel source present
- **WHEN** `linux/Makefile` exists
- **THEN** the script proceeds to build

#### Scenario: Kernel source missing
- **WHEN** `linux/` does not contain a `Makefile`
- **THEN** the script exits with a descriptive error message

### Requirement: Kernel image build
The build script SHALL compile the kernel using `ARCH=arm64` and `CROSS_COMPILE=aarch64-linux-gnu-` with the sequence `make -C linux defconfig` → `linux/scripts/config --file linux/.config -e …` (12 forced symbols) → `make -C linux olddefconfig` → `make -C linux -j$(nproc)`. All config operations SHALL target the kernel source tree's own `scripts/config` and `linux/.config` via paths anchored to the kernel source directory, never paths relative to the caller's working directory.

#### Scenario: Kernel compiles successfully
- **WHEN** the kernel source is valid and the cross-toolchain is installed
- **THEN** `linux/arch/arm64/boot/Image` contains the ARM64 kernel image

#### Scenario: Kernel compilation fails
- **WHEN** `make` returns a non-zero exit code
- **THEN** the script exits with the build failure message and non-zero exit code

### Requirement: Working-directory independence
The build script SHALL resolve every input and output path — kernel source and its `scripts/config`/`.config`, and assets — relative to the project location, not the caller's current working directory, and SHALL produce identical results regardless of where it is invoked from.

#### Scenario: Config overrides land in the kernel tree
- **WHEN** the force + `olddefconfig` steps complete
- **THEN** `linux/.config` contains all 12 override symbols set to `=y`, before compilation begins

#### Scenario: Invoked from an unrelated directory
- **WHEN** `build-kernel.sh` is run with a current working directory outside the project tree
- **THEN** the config overrides are still applied to `linux/.config` and the build completes successfully

#### Scenario: Config files present
- **WHEN** the kernel build completes
- **THEN** `linux/.config` and `linux/System.map` contain the build artifacts

### Requirement: Build succeeds end-to-end
The entire build process SHALL complete from start to finish with exit code 0.

#### Scenario: Complete build
- **WHEN** all prerequisites are met (kernel source, assets, toolchain)
- **THEN** `linux/arch/arm64/boot/Image`, `linux/.config`, and `linux/System.map` are all present and the script exits 0

### Requirement: Squashfs decompressor support
The build script SHALL force all five squashfs decompressor drivers to `=y` in `.config` (after defconfig, before `make`): `CONFIG_SQUASHFS_LZO`, `CONFIG_SQUASHFS_XZ`, `CONFIG_SQUASHFS_ZSTD`, `CONFIG_SQUASHFS_LZ4`, `CONFIG_SQUASHFS_ZLIB`.

#### Scenario: All squashfs decompressors enabled in .config
- **WHEN** the kernel build completes
- **THEN** `linux/.config` contains `CONFIG_SQUASHFS_ZLIB=y`, `CONFIG_SQUASHFS_LZO=y`, `CONFIG_SQUASHFS_XZ=y`, `CONFIG_SQUASHFS_ZSTD=y`, and `CONFIG_SQUASHFS_LZ4=y`

#### Scenario: Missing decompressor detected
- **WHEN** any of the five squashfs decompressor options is missing or not set to `=y` in the built `.config`
- **THEN** this is a build failure — the kernel cannot support Ubuntu snaps and `graphical.target` will not start

### Requirement: Surface Aggregator (SSAM) support
The build script SHALL force the Surface Aggregator framework to `=y` in `.config` (after defconfig, before `make`): `CONFIG_SURFACE_AGGREGATOR`, `CONFIG_SURFACE_AGGREGATOR_BUS`, `CONFIG_SURFACE_AGGREGATOR_REGISTRY`, `CONFIG_SURFACE_AGGREGATOR_HUB`, and `CONFIG_SURFACE_AGGREGATOR_TABLET_SWITCH`. It SHALL also force `CONFIG_SURFACE_HID` and `CONFIG_SURFACE_HID_CORE` to `=y`.

#### Scenario: All SSAM symbols enabled in .config
- **WHEN** the kernel build completes
- **THEN** `linux/.config` contains `CONFIG_SURFACE_AGGREGATOR=y`, `CONFIG_SURFACE_AGGREGATOR_BUS=y`, `CONFIG_SURFACE_AGGREGATOR_REGISTRY=y`, `CONFIG_SURFACE_AGGREGATOR_HUB=y`, `CONFIG_SURFACE_AGGREGATOR_TABLET_SWITCH=y`, `CONFIG_SURFACE_HID=y`, and `CONFIG_SURFACE_HID_CORE=y`

#### Scenario: Deps satisfied
- **WHEN** the SSAM symbols are enabled
- **THEN** `linux/.config` also contains `CONFIG_SERIAL_DEV_BUS=y`, `CONFIG_SERIAL_QCOM_GENI=y`, `CONFIG_SURFACE_PLATFORMS=y`, and `CONFIG_ACPI=y` (already guaranteed by defconfig)

#### Scenario: Missing SSAM symbol detected
- **WHEN** any of the seven SSAM symbols is missing or not set to `=y` in the built `.config`
- **THEN** this is a build failure — the Type Cover will remain dead after boot

### Requirement: Config verification gate
After `make olddefconfig` (and before declaring success), the build script SHALL verify that `linux/.config` contains all 12 required override symbols set to `=y`, and SHALL exit non-zero with a descriptive error naming the missing symbol(s) if any is absent or not `=y`. This gate backs the "build failure" outcome of the squashfs and SSAM scenarios above.

#### Scenario: All required symbols present
- **WHEN** the final `.config` contains all 12 override symbols (5 squashfs + 7 SSAM) set to `=y`
- **THEN** the verification passes and the build proceeds to completion

#### Scenario: A required symbol is missing or not built-in
- **WHEN** any of the 12 override symbols is absent, `=m`, or `=n` in the final `.config`
- **THEN** the build script exits non-zero and prints an error naming each offending symbol
