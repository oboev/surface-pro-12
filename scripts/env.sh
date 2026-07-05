#!/usr/bin/env bash
# =============================================================================
# scripts/env.sh — canonical path variables for the Surface Pro 12 build.
#
# Single source of truth for every input/output path. Source it from a build
# script; do NOT recompute these paths per-script.
#
#   Usage (from a script anywhere in the tree):
#       source "$(dirname "${BASH_SOURCE[0]}")/scripts/env.sh"   # if at root
#   or, robustly, source it by its known location under the project.
#
# This file lives in scripts/, so PROJECT_DIR = <this dir>/.. correctly yields
# the project root. That is the whole point of centralizing here: a script that
# sits AT the project root must use its own dir as PROJECT_DIR (no "/.."),
# whereas this file — being one level down — must climb exactly one "/..".
# Getting that wrong points every path at the parent of the project.
#
# No side effects beyond variable assignment (safe to source under `set -e`).
# =============================================================================

# These variables are consumed by scripts that source this file, not here.
# shellcheck disable=SC2034

# Resolve this file's own directory (scripts/), then the project root above it.
_ENV_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${_ENV_SH_DIR}/.." && pwd)"
unset _ENV_SH_DIR

# ── Inputs ───────────────────────────────────────────────────────────────────
# Rootfs source: the prebuilt postmarketOS trailblazer GNOME image (a GPT .img.xz
# whose p2 is the ext4 aarch64 root). Kept under the name ISO_PATH — the single
# "rootfs source image" variable Stage 1.5 consumes — even though it is an .img.xz.
ISO_PATH="${PROJECT_DIR}/iso/20260704-0051-postmarketOS-edge-gnome-4-postmarketos-trailblazer-next.img.xz"
KERNEL_SRC="${PROJECT_DIR}/linux"
BUILD="${PROJECT_DIR}/build"
ASSETS="${PROJECT_DIR}/assets"
FIRMWARE="${PROJECT_DIR}/firmware"

# ── Outputs ──────────────────────────────────────────────────────────────────
# Resolve with `realpath -m`: it produces an absolute path even for a path that
# does not exist yet (the build dir is created later), which is required for the
# mount-table comparisons and the rm -rf boundary guard to work correctly.
ROOTFS="$(realpath -m "${PROJECT_DIR}/build/inst/root")"
ISO_MOUNT="$(realpath -m "${PROJECT_DIR}/build/inst/iso")"

# Stage 2 output dir — holds rootfs.squashfs, the RAM-boot initrd, and the
# kernel+dtb copied out for the Stage 3 ESP. `realpath -m` so it is absolute
# even before the directory exists (created by inst-initrd.sh).
OUT="$(realpath -m "${PROJECT_DIR}/build/inst/out")"
