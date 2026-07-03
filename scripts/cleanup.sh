#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# scripts/cleanup.sh — reset the project to a clean, pre-build state.
#
# Removes every build-generated artifact so the full pipeline can run from
# scratch:
#   - the entire build/ tree (root-owned rootfs + initrd payload)
#   - the in-tree kernel build (config, intermediates, objects, vmlinux, Image)
#     via `git clean -dfx` in the kernel checkout
#
# The kernel checkout ($KERNEL_SRC, a symlink to an out-of-tree git repo) is
# user-owned, but this script runs as root (build/ is root-owned). Running git
# as root there trips the "detected dubious ownership" guard, so the kernel
# cleanup is dropped to the checkout's owner (see kgit()).
#
# Prints a summary with sizes, requires an exact "yes" confirmation, requires
# root, and is idempotent (safe to run repeatedly).
# =============================================================================

# --- 0. Path configuration: env.sh is the single source of truth -------------
# shellcheck source=scripts/env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

die() { echo "ERROR: $*" >&2; exit 1; }
hr()  { numfmt --to=iec --format='%.1f' "${1:-0}"; }   # bytes -> human-readable

# --- 1. Root requirement -----------------------------------------------------
# build/inst/root/ was assembled with root ownership and cannot be removed
# otherwise.
[ "$(id -u)" -eq 0 ] || die "This script must be run as root (build/ is root-owned). Try: sudo $0"

# --- 2. Run git in the kernel checkout as its owner --------------------------
# We are root, the checkout is user-owned: drop to the invoking user so git's
# ownership guard does not silently skip the cleanup. If invoked as root
# directly (no SUDO_USER), mark the resolved checkout path safe instead.
KERNEL_SRC_REAL="$(realpath -m "$KERNEL_SRC")"
kgit() {
    if [ -n "${SUDO_USER:-}" ]; then
        sudo -u "$SUDO_USER" git -C "$KERNEL_SRC" "$@"
    else
        git -C "$KERNEL_SRC" -c safe.directory="$KERNEL_SRC_REAL" "$@"
    fi
}

# --- 3. Inventory ------------------------------------------------------------
# Kernel artifacts = everything `git clean -dfx` would remove (untracked +
# ignored). Enumerate via a dry run; empty when the tree is already clean or is
# not a git repo.
kernel_list() {
    [ -d "$KERNEL_SRC" ] || return 0
    kgit rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
    kgit clean -dxn 2>/dev/null | sed -n 's/^Would remove //p'
}

KERNEL_LIST="$(kernel_list)"

kernel_count() { [ -n "$KERNEL_LIST" ] && printf '%s\n' "$KERNEL_LIST" | wc -l || echo 0; }

kernel_size_bytes() {
    [ -n "$KERNEL_LIST" ] || { echo 0; return; }
    # Prefix each relative path with the checkout root, NUL-delimit, and let du
    # total them (avoids ARG_MAX with ~tens of thousands of object files).
    printf '%s\n' "$KERNEL_LIST" | sed "s#^#${KERNEL_SRC}/#" | tr '\n' '\0' \
        | du --files0-from=- -cb 2>/dev/null | tail -n1 | cut -f1
}

build_present=false
[ -e "$BUILD" ] && build_present=true

# --- 4. Idempotency short-circuit --------------------------------------------
if ! $build_present && [ -z "$KERNEL_LIST" ]; then
    echo "Nothing to clean."
    exit 0
fi

# --- 5. Summary --------------------------------------------------------------
total=0
echo "The following build artifacts will be removed:"
echo

if $build_present; then
    build_bytes="$(du -sb "$BUILD" 2>/dev/null | cut -f1)"
    total=$((total + build_bytes))
    printf '  %-32s %8s   (%s)\n' "build/ tree" "$(hr "$build_bytes")" "$BUILD"
fi

if [ -n "$KERNEL_LIST" ]; then
    kernel_bytes="$(kernel_size_bytes)"
    total=$((total + kernel_bytes))
    printf '  %-32s %8s   (%s)\n' \
        "kernel artifacts ($(kernel_count) files)" "$(hr "$kernel_bytes")" "$KERNEL_SRC"
fi

echo
printf '  %-32s %8s\n' "Total reclaimable" "$(hr "$total")"
echo

# --- 6. Confirmation ---------------------------------------------------------
printf 'Type "yes" to proceed: '
read -r answer || answer=""
if [ "$answer" != "yes" ]; then
    echo "Aborted — nothing removed."
    exit 0
fi

# --- 7. Deletion -------------------------------------------------------------
if $build_present; then
    echo "[CLEAN] Removing build/ tree"
    rm -rf "$BUILD"
fi

if [ -n "$KERNEL_LIST" ]; then
    echo "[CLEAN] Resetting kernel tree (git clean -dfx, $(kernel_count) files)"
    kgit clean -dfxq
fi

echo "Done. Reclaimed $(hr "$total")."
