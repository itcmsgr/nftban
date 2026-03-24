#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Atomic File Operations Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_file_ops"
# meta:type="core"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Atomic file write operations to prevent race conditions and corruption"
# meta:inventory.files=""
# meta:inventory.binaries="mktemp,mv"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Replace entire file atomically with content from stdin
# Usage: echo "full new content" | nftban_atomic_write /path/to/file
nftban_atomic_write() {
  local target="$1"
  local dir base tmp mode owner group
  dir="$(dirname -- "$target")"
  base="$(basename -- "$target")"

  # Ensure dir exists & is writable
  [[ -d "$dir" ]] || { echo "No such directory: $dir" >&2; return 1; }
  [[ -w "$dir" ]] || { echo "Directory not writable: $dir" >&2; return 1; }

  # Determine attributes (if file exists)
  if [[ -e "$target" ]]; then
    mode="$(stat -c '%a' -- "$target")"
    owner="$(stat -c '%u' -- "$target")"
    group="$(stat -c '%g' -- "$target")"
  else
    # Sensible defaults for config files
    mode="0644"; owner="0"; group="0"
  fi

  # Temp in same fs for atomic rename
  tmp="$(mktemp --tmpdir="$dir" ".${base}.tmp.XXXXXX")" || { echo "mktemp failed" >&2; return 1; }
  # Ensure cleanup on any failure
  cleanup() { rm -f -- "$tmp" || true; }
  trap cleanup EXIT

  # Write stdin to temp
  # Use dd with oflag=dsync for durability without huge penalty
  dd of="$tmp" oflag=dsync status=none

  # Set attributes on temp (before move)
  chown "${owner}:${group}" "$tmp"
  chmod "${mode}" "$tmp"
  # Preserve SELinux context (if source exists) or restore default
  if command -v chcon >/dev/null 2>&1 && [[ -e "$target" ]]; then
    chcon --reference="$target" "$tmp" 2>/dev/null || true
  elif command -v restorecon >/dev/null 2>&1; then
    restorecon "$tmp" 2>/dev/null || true
  fi

  # Atomic replace
  mv -f -- "$tmp" "$target"

  # fsync dir entry to be extra safe (Linux-only)
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<PY || true
import os, sys
fd=os.open("$dir", os.O_DIRECTORY)
try:
  os.fsync(fd)
finally:
  os.close(fd)
PY
  fi

  trap - EXIT
  cleanup
}

# Append to file atomically (reads existing file + appends stdin)
# Usage:
#   nftban_atomic_append /path/to/file <<<"one new line"
#   echo "a=b" | nftban_atomic_append /path/file
nftban_atomic_append() {
  local target="$1"
  shift || true

  local dir base tmp mode owner group
  dir="$(dirname -- "$target")"
  base="$(basename -- "$target")"

  [[ -d "$dir" ]] || { echo "No such directory: $dir" >&2; return 1; }
  [[ -w "$dir" ]] || { echo "Directory not writable: $dir" >&2; return 1; }

  if [[ -e "$target" ]]; then
    mode="$(stat -c '%a' -- "$target")"
    owner="$(stat -c '%u' -- "$target")"
    group="$(stat -c '%g' -- "$target")"
  else
    mode="0644"; owner="0"; group="0"
    # Ensure file exists to preserve ordering comments if needed
    : > "$target"
    chown "${owner}:${group}" "$target"
    chmod "${mode}" "$target"
  fi

  tmp="$(mktemp --tmpdir="$dir" ".${base}.tmp.XXXXXX")" || { echo "mktemp failed" >&2; return 1; }
  cleanup() { rm -f -- "$tmp" || true; }
  trap cleanup EXIT

  # Build new file: existing + stdin
  cat -- "$target" >"$tmp"
  # Append stdin (if a single line param was passed via args, print that; else read stdin)
  if [[ $# -gt 0 ]]; then
    printf '%s\n' "$*" >>"$tmp"
  else
    cat >>"$tmp"
  fi

  chown "${owner}:${group}" "$tmp"
  chmod "${mode}" "$tmp"
  if command -v chcon >/dev/null 2>&1 && [[ -e "$target" ]]; then
    chcon --reference="$target" "$tmp" 2>/dev/null || true
  elif command -v restorecon >/dev/null 2>&1; then
    restorecon "$tmp" 2>/dev/null || true
  fi

  mv -f -- "$tmp" "$target"

  if command -v python3 >/dev/null 2>&1; then
    python3 - <<PY || true
import os, sys
fd=os.open("$dir", os.O_DIRECTORY)
try:
  os.fsync(fd)
finally:
  os.close(fd)
PY
  fi

  trap - EXIT
  cleanup
}
