## 1. Create cleanup script

- [x] 1.1 Scaffold `scripts/cleanup.sh` with shebang, `set -euo pipefail`, and source `env.sh`
- [x] 1.2 Add root-check guard (`id -u` must be 0); print an error and exit 1 if not root
- [x] 1.3 Implement path resolution using canonical variables from `env.sh` (`BUILD`, `KERNEL_SRC`, `PROJECT_DIR`)
- [x] 1.4 Resolve the git-as-owner invocation: build a `git -C "$KERNEL_SRC"` wrapper that runs as the checkout owner (`sudo -u "$SUDO_USER"` when set; fall back to `-c safe.directory=<realpath of KERNEL_SRC>`) so the root-run script does not hit git's "dubious ownership" guard
- [x] 1.5 Implement inventory collection: size of `build/` (if present) and the kernel artifacts enumerated via `git clean -dxn` in `$KERNEL_SRC`; skip missing/clean sources gracefully (guard glob/empty-list expansion under `set -euo pipefail`)
- [x] 1.6 Implement summary display: print each item (the `build/` tree and the kernel artifacts) with human-readable size and a total reclaimable amount
- [x] 1.7 Implement idempotency short-circuit: if `build/` is absent AND the kernel tree is already clean, print "Nothing to clean" and exit 0 before prompting
- [x] 1.8 Implement confirmation prompt: `read -r` with check for exact "yes"; abort with no deletions on anything else
- [x] 1.9 Implement deletion: `rm -rf "$BUILD"` (do not recreate it) and the git-as-owner `git clean -dfx` in `$KERNEL_SRC`
- [x] 1.10 Implement idempotency: no errors on missing `build/` or an already-clean kernel tree

## 2. Documentation

- [x] 2.1 Add `scripts/cleanup.sh` to README.md as an optional first step of the pipeline

## 3. Verification

- [x] 3.1 Run `bash -n scripts/cleanup.sh` — must pass with no errors
- [x] 3.2 Run `shellcheck scripts/cleanup.sh` — must pass with no errors (clean under `shellcheck -x`; only the shared SC1091 info about the sourced `env.sh`)
- [ ] 3.3 Verify full build state as root (`sudo ./scripts/cleanup.sh`, answer "yes"): confirm `build/` is removed and not recreated, and the kernel tree is pristine — `git -C "$KERNEL_SRC" status --porcelain --ignored` reports nothing
- [ ] 3.4 Verify the ownership guard: while running as root over the user-owned kernel checkout, confirm git does NOT abort with "detected dubious ownership" and the kernel artifacts are actually removed
- [x] 3.5 Verify env.sh path resolution: confirm the script references `$BUILD`/`$KERNEL_SRC` from `env.sh` (no recomputed literals) and the summary prints the paths those variables resolve to
- [ ] 3.6 Verify summary + confirmation: with artifacts present, confirm the summary lists both `build/` and the kernel artifacts with sizes and a total, and that typing "no" (or anything other than "yes") aborts with no deletions
- [x] 3.7 Verify non-root rejection: run as a non-root user, confirm exit code 1 and an error message, with nothing removed
- [ ] 3.8 Verify idempotency / empty-tree handling: run cleanup a second time (no `build/`, pristine kernel tree), confirm it prints "Nothing to clean", does not prompt, and exits 0

> Verification note: 3.3/3.4/3.6/3.8 require an interactive `sudo` run and are destructive (they wipe the ~3.1 GB kernel build + `build/` tree), so they were left for a deliberate run by the maintainer. The inventory/size/git-as-owner logic underlying them was validated non-destructively via `git clean -dxn` (44,959 files / 3.1 G, correctly including `.config`, `.tmp_*`, and `*.o`).
