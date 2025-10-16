#!/usr/bin/env bash
# =============================================================================
# NFTBan Validator - Run Module
# Version: 7.0.0
# Provides: Manifest-driven validation (sha256, md5 optional, size, syntax, perms)
# Location: /etc/nftban/lib/nftban-validator-run.sh
# Requires: jq, sha256sum; optional: md5sum
# =============================================================================

set -euo pipefail

# --- Module banner (optical confirmation) ------------------------------------
echo "[NFTBan] Loading: Validator Run Module v7.0.0"

# --- Logging helpers (fallback if installer logger not sourced) --------------
if ! type installer_log_debug >/dev/null 2>&1; then
  installer_log_debug() { printf "%s [DEBUG] %s\n" "$(date -Is)" "$*"; }
fi
if ! type installer_log_info >/dev/null 2>&1; then
  installer_log_info() { printf "%s [INFO]  %s\n" "$(date -Is)" "$*"; }
fi
if ! type installer_log_warn >/dev/null 2>&1; then
  installer_log_warn() { printf "%s [WARN]  %s\n" "$(date -Is)" "$*"; }
fi
if ! type installer_log_error >/dev/null 2>&1; then
  installer_log_error() { printf "%s [ERROR] %s\n" "$(date -Is)" "$*"; }
fi

INSTALL_DIR="${INSTALL_DIR:-/etc/nftban}"
LIB_DIR="${LIB_DIR:-$INSTALL_DIR/lib}"
MANIFEST="${MANIFEST:-$LIB_DIR/nftban-validator-manifest.json}"
LOG="${LOG:-/var/log/nftban/validator.log}"
USE_MD5="${USE_MD5:-0}"

mkdir -p "$(dirname "$LOG")"

require() { command -v "$1" >/dev/null 2>&1 || { echo "Missing tool: $1"; exit 1; }; }

require jq
require sha256sum
[ "$USE_MD5" -eq 0 ] || require md5sum

ok=0; fail=0

installer_log_info "Validator Run starting (manifest: $MANIFEST)"

while read -r fname; do
  fpath="$LIB_DIR/$fname"
  if [ ! -f "$fpath" ]; then
    installer_log_warn "$fname: MISSING"
    fail=$((fail+1))
    continue
  fi

  m_sha="$(jq -r ".modules[] | select(.filename==\"$fname\").sha256" "$MANIFEST")"
  m_md5="$(jq -r ".modules[] | select(.filename==\"$fname\").md5" "$MANIFEST")"
  sha="$(sha256sum "$fpath" | awk '{print $1}')"

  if [ -n "$m_sha" ] && [ "$m_sha" != "null" ]; then
    if [ "$sha" != "$m_sha" ]; then
      installer_log_error "$fname: sha256 FAIL"
      fail=$((fail+1))
      continue
    fi
  else
    installer_log_warn "$fname: manifest sha256 missing"
  fi

  if [ "$USE_MD5" -eq 1 ] && [ -n "$m_md5" ] && [ "$m_md5" != "null" ]; then
    md5="$(md5sum "$fpath" | awk '{print $1}')"
    if [ "$md5" != "$m_md5" ]; then
      installer_log_error "$fname: md5 FAIL"
      fail=$((fail+1))
      continue
    fi
  fi

  # size check (optional)
  m_size="$(jq -r ".modules[] | select(.filename==\"$fname\").size_bytes" "$MANIFEST" 2>/dev/null || echo "null")"
  if [ "$m_size" != "null" ] && [ -n "$m_size" ]; then
    f_size="$(stat -c%s "$fpath" 2>/dev/null || stat -f%z "$fpath" 2>/dev/null)"
    if [ "$f_size" != "$m_size" ]; then
      installer_log_error "$fname: size mismatch ($f_size != $m_size)"
      fail=$((fail+1))
      continue
    fi
  fi

  # syntax
  if ! bash -n "$fpath" 2>/dev/null; then
    installer_log_error "$fname: bash syntax FAIL"
    fail=$((fail+1))
    continue
  fi

  # perms
  if [ ! -r "$fpath" ]; then
    installer_log_error "$fname: not readable"
    fail=$((fail+1))
    continue
  fi

  installer_log_info "$fname: OK"
  ok=$((ok+1))
done < <(jq -r '.modules[].filename' "$MANIFEST")

installer_log_info "Summary: OK=$ok FAIL=$fail"

# Exit non-zero on failure
if [ "$fail" -ne 0 ]; then
  installer_log_error "Validator Run completed with failures"
  installer_log_debug "Validator Run module loaded"
  exit 1
fi

installer_log_info "Validator Run completed successfully"
# --- Module footer (optical confirmation) ------------------------------------
installer_log_debug "Validator Run module loaded"
