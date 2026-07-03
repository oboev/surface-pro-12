## Context

The Surface Pro 12 build pipeline produces artifacts in two places:

**Under `build/` (root-owned, created by the install stages):**
- `build/inst/root/` (6.7 GB) — extracted rootfs
- `build/inst/out/` (6.5 GB) — initrd payload (includes redundant 3.3 GB squashfs copy)

**In the kernel source tree (user-owned, created by `build-kernel.sh`):**
- `linux` is a **symlink to an out-of-tree checkout** that is its own git repository (`linux/.git` exists).
- The kernel is built **in-tree**, so the checkout holds ~5.2 GB of artifacts: `.config` (316 KB), `.tmp_*` (~247 MB), plus `vmlinux` (152 MB), `built-in.a`, `arch/arm64/boot/Image`, and ~32k `*.o`/`*.cmd` object/command files scattered throughout the tree.

Removing only `.config` and `.tmp_*` (an earlier plan) reclaims ~247 MB and leaves ~5 GB of compiled objects in place — it does **not** produce the clean state this change exists to provide. Because kernel build artifacts are git-ignored in the kernel repo, `git clean -dfx` removes all of them in one operation and restores a pristine checkout.

## Goals / Non-Goals

**Goals:**
- Restore the project to a genuinely clean state — no build-generated artifacts under `build/` and a pristine kernel checkout.
- Require root.
- Safe to run multiple times (idempotent).

**Non-Goals:**
- Not a selective/partial cleaner (no `--dry-run`, `--full`, `--partial`).
- Does not touch project inputs (`assets/`, the ISO) or anything tracked by git in the kernel repo.
- Does not attempt to preserve incremental-build state — a clean run means the next kernel build recompiles from scratch.

## Decisions

### D1: Remove entire `build/` vs. individual files
**Decision:** Remove the entire `build/` directory with `rm -rf "$BUILD"`.

### D2: Clean the kernel tree with `git clean`, not per-file removal
**Decision:** Reset the kernel source tree with `git -C "$KERNEL_SRC" clean -dfx` instead of removing `linux/.config` and `linux/.tmp_*` individually.

**Rationale:** The kernel is built in-tree and produces ~5.2 GB of artifacts (~32k files), not just `.config` + `.tmp_*`. Per-file removal leaves the tree ~5 GB dirty and fails the "clean state" goal. All kernel build outputs are git-ignored, so `git clean -dfx` (`-d` directories, `-f` force, `-x` include ignored files) removes every build artifact — config, intermediates, objects, `vmlinux`, `Image` — and nothing tracked. This subsumes the old D2 (removing `.config` alone was a behavioral no-op, since `build-kernel.sh` runs `defconfig` regardless).

### D3: Ownership guard when running git as root
**Decision:** Invoke git as the checkout's owner rather than as root: `sudo -u "$SUDO_USER" git -C "$KERNEL_SRC" clean -dfx` (falling back to a `-c safe.directory=<resolved path>` override if `$SUDO_USER` is unset).

**Rationale:** The script requires root (D4) for the root-owned `build/`, but the kernel repo is user-owned. Running `git` as root in a repo owned by another user triggers git's "detected dubious ownership" refusal, which would silently skip the kernel cleanup. Dropping to the owning user avoids the guard and also keeps any files git might touch user-owned. The symlink is resolved to its real path before use.

### D4: Require root
**Decision:** Check `id -u` at the top and exit with code 1 if not root.

**Rationale:** `build/inst/root/` was assembled with root ownership and cannot be removed otherwise.

### D5: No selective modes
**Decision:** One operation — remove everything that should be removed. No `--dry-run`, no `--full`, no `--partial`.

## Risks / Trade-offs

- **[Accidental data loss]** → Mitigation: confirmation prompt (exact `yes`), root requirement, and an explicit summary of every path/size before acting.
- **[`git clean -dfx` is aggressive]** → It removes *all* untracked and ignored files in the kernel checkout, including any hand-added scratch files. This is intended (pristine checkout) but the summary must make clear the kernel tree will be fully reset. Use `git clean -dxn` to build the summary of what would be removed.
- **[Cleanup reaches outside `PROJECT_DIR`]** → Because `linux` is a symlink, the kernel cleanup operates outside the project directory. This is expected here, but it is why the operation is scoped to `git clean` within that specific repo rather than a blind `rm -rf`.

## Migration Plan

No migration needed — this is a new script. Existing pipeline runs are unaffected. Add it to README.md as an optional first step.
