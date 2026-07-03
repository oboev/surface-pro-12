## ADDED Requirements

### Requirement: Cleanup removes build output tree
The cleanup script MUST remove the `build/` directory entirely. It MUST NOT recreate it.

#### Scenario: Rootfs tree exists
- **WHEN** `build/` exists (empty or not)
- **THEN** cleanup removes it entirely and does not recreate it

#### Scenario: build/ does not exist
- **WHEN** `build/` does not exist
- **THEN** cleanup runs without error

### Requirement: Cleanup resets the kernel source tree with git clean
The cleanup script MUST reset the kernel source tree (`$KERNEL_SRC`) to a pristine checkout by running `git clean -dfx` inside it, removing all build-generated artifacts (`.config`, `.tmp_*`, object/command files, `vmlinux`, `arch/arm64/boot/Image`, and any other untracked or git-ignored files). It MUST NOT remove files tracked by the kernel repository.

The kernel tree contains tens of thousands of artifacts, so the deletion MUST run quietly (`git clean -dfxq`) — it MUST NOT print one line per removed file.

Because the script runs as root (see "Cleanup requires root") while the kernel checkout is user-owned, it MUST run git as the checkout's owner (e.g. `sudo -u "$SUDO_USER"`) or otherwise satisfy git's ownership check, so the kernel cleanup is not silently skipped by git's "dubious ownership" guard.

#### Scenario: Kernel tree has build artifacts
- **WHEN** the kernel tree contains build artifacts (`.config`, `.tmp_*`, `*.o`, `vmlinux`, `Image`, …)
- **THEN** `git clean -dfx` removes all of them and the tree returns to a pristine (tracked-files-only) state — verifiable: `git -C "$KERNEL_SRC" status --porcelain --ignored` reports nothing

#### Scenario: Kernel tree is already clean
- **WHEN** the kernel tree has no untracked or ignored files
- **THEN** cleanup runs without error and removes nothing

#### Scenario: Script runs as root over a user-owned kernel repo
- **WHEN** cleanup runs as root and the kernel checkout is owned by another user
- **THEN** git does not refuse with a "dubious ownership" error and the kernel artifacts are actually removed

### Requirement: Cleanup is idempotent and safe
The cleanup script MUST be idempotent — running it multiple times must not produce errors. A missing `build/` directory and an already-clean kernel tree MUST be silently skipped.

#### Scenario: First run removes everything
- **WHEN** cleanup runs with all build artifacts present
- **THEN** `build/` is removed and the kernel tree is pristine; exit code is 0

#### Scenario: Second run on clean tree
- **WHEN** cleanup runs after a successful first run (no `build/`, pristine kernel tree)
- **THEN** no errors, exit code is 0, and the script reports "Nothing to clean" without prompting for confirmation

### Requirement: Cleanup sources env.sh for canonical paths
The cleanup script MUST source `scripts/env.sh` to resolve all paths, consistent with the existing build stage scripts.

#### Scenario: Paths resolve correctly
- **WHEN** cleanup sources env.sh
- **THEN** all paths are resolved via the canonical variables (`BUILD`, `KERNEL_SRC`, `PROJECT_DIR`) rather than recomputed literals

### Requirement: Cleanup prints summary before acting
The cleanup script MUST display a summary of what it will remove and the total reclaimable space before performing any deletions. The summary MUST cover both `build/` and the kernel artifacts. The kernel artifacts MUST be presented in aggregate — a single line with the file count and total size, computed from a dry run (e.g. `git clean -dxn`). The summary MUST NOT list individual kernel artifact paths (there are tens of thousands).

#### Scenario: Summary shows items and sizes
- **WHEN** cleanup runs with artifacts present
- **THEN** it prints one line for the `build/` tree and one aggregate line for the kernel artifacts (file count + total size), each with a human-readable size, plus a total reclaimable amount — without enumerating individual kernel files

#### Scenario: User must confirm
- **WHEN** cleanup prompts for confirmation
- **THEN** it only proceeds if the user types "yes" exactly; any other input aborts with no deletions

### Requirement: Cleanup requires root
The cleanup script MUST require root (uid 0) to run.

#### Scenario: Non-root user runs cleanup
- **WHEN** a non-root user executes cleanup
- **THEN** cleanup prints an error and exits with code 1 before removing anything

#### Scenario: Root user runs cleanup
- **WHEN** root executes cleanup
- **THEN** cleanup proceeds normally
