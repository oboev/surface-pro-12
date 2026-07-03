## Why

A cleanup script is needed so the full pipeline can be executed from a genuinely clean state — both the root-owned `build/` tree and the in-tree kernel checkout (~5.2 GB of build artifacts).

## What Changes

- Add `scripts/cleanup.sh` that removes all build-generated artifacts, leaving the project tree clean:
  - removes the entire `build/` directory (does not recreate it)
  - resets the kernel source tree to a pristine checkout via `git clean -dfx`, run as the checkout owner so the root-run script does not trip git's "dubious ownership" guard
  - prints a summary with sizes and a total, requires an exact `yes` confirmation, requires root, and is idempotent

## Non-Goals

- Not a selective/partial cleaner — no `--dry-run`, `--full`, or `--partial` modes.
- Does not touch project inputs (`assets/`, the ISO) or any files tracked by git in the kernel repo.
- Does not preserve incremental-build state — a clean run means the next kernel build recompiles from scratch.

## Capabilities

### New Capabilities
- `scripts/cleanup.sh`: Script that removes all build outputs and resets the kernel tree.

### Modified Capabilities
<!-- None — this is a new capability, not a modification -->

## Impact

- New script: `scripts/cleanup.sh`
- README.md gains an optional cleanup step at the front of the pipeline.
