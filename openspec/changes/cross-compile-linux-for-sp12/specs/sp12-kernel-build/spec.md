## ADDED Requirements

### Requirement: Build script exists and is executable
The system SHALL provide a build script at `build/build.sh` that is executable and builds all kernel artifacts in one invocation.

#### Scenario: Script exists and is executable
- **WHEN** the project is set up
- **THEN** `build/build.sh` exists and has the executable permission set

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

### Requirement: Assets verification
The build script SHALL verify that the assets directory exists at `assets/` and contains the DTB file at `boot/dtb`.

#### Scenario: Assets present
- **WHEN** `assets/boot/dtb` exists
- **THEN** the script proceeds to build

#### Scenario: Assets missing
- **WHEN** `assets/boot/dtb` does not exist
- **THEN** the script exits with a descriptive error message

### Requirement: Kernel image build
The build script SHALL compile the kernel using `ARCH=arm64` and `CROSS_COMPILE=aarch64-linux-gnu-` with `make defconfig` followed by `make -j$(nproc)`, and place the resulting image at `build/output/vmlinuz`.

#### Scenario: Kernel compiles successfully
- **WHEN** the kernel source is valid and the cross-toolchain is installed
- **THEN** `build/output/vmlinuz` contains the ARM64 kernel image (arch/arm64/boot/Image)

#### Scenario: Kernel compilation fails
- **WHEN** `make` returns a non-zero exit code
- **THEN** the script exits with the build failure message and non-zero exit code

### Requirement: Device tree blob
The build script SHALL copy the device tree blob from `assets/boot/dtb` to `build/output/dtb`.

#### Scenario: DTB copied
- **WHEN** `assets/boot/dtb` exists
- **THEN** `build/output/dtb` is an exact copy of the source DTB

### Requirement: Kernel modules build and install
The build script SHALL compile kernel modules and install them to `build/output/modules/` using `make modules_install`.

#### Scenario: Modules built and installed
- **WHEN** the kernel image build succeeds
- **THEN** `build/output/modules/` contains the full modules tree with a versioned subdirectory containing `kernel/`, `modules.dep`, and all compiled modules

### Requirement: Kernel config and System.map
The build script SHALL copy the kernel `.config` and `System.map` to `build/output/`.

#### Scenario: Config files present
- **WHEN** the kernel build completes
- **THEN** `build/output/config` contains the kernel `.config` and `build/output/System.map` contains the kernel System.map

### Requirement: Build metadata
The build script SHALL write a `build/output/build-info.txt` file containing the kernel version, git commit hash (if available), and cross-toolchain version.

#### Scenario: Build info written
- **WHEN** the build completes
- **THEN** `build/output/build-info.txt` exists and contains version information

### Requirement: Build succeeds end-to-end
The entire build process SHALL complete from start to finish with exit code 0, producing all output files.

#### Scenario: Complete build
- **WHEN** all prerequisites are met (kernel source, assets, toolchain)
- **THEN** `build/output/` contains: `vmlinuz`, `dtb`, `config`, `System.map`, `modules/`, and `build-info.txt`
