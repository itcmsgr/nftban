#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="env" meta:type="lib" meta:version="1.39.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Central environment variable defaults for all NFTBan scripts"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_LIB_DIR,NFTBAN_LOG_DIR,NFTBAN_CACHE_DIR,NFTBAN_DATA_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"

set -Eeuo pipefail

# Guard: prevent double-loading
[[ -n "${NFTBAN_ENV_LOADED:-}" ]] && return 0
NFTBAN_ENV_LOADED="true"

# =============================================================================
# CORE PATHS - Single source of truth for all NFTBan scripts
# =============================================================================
# These defaults match install/config/nftban.conf
# Config files can override these after this file is sourced
#
# NOTE: Use parameter expansion with guards to avoid readonly variable conflicts
# when nftban.conf has already been sourced (it declares these as readonly)

# Only set if not already defined (avoids readonly conflict)
[[ -z "${NFTBAN_CONFIG_DIR:-}" ]] && export NFTBAN_CONFIG_DIR="/etc/nftban"
[[ -z "${NFTBAN_LIB_DIR:-}" ]] && export NFTBAN_LIB_DIR="/usr/lib/nftban"
[[ -z "${NFTBAN_LOG_DIR:-}" ]] && export NFTBAN_LOG_DIR="/var/log/nftban"
[[ -z "${NFTBAN_CACHE_DIR:-}" ]] && export NFTBAN_CACHE_DIR="/var/cache/nftban"
[[ -z "${NFTBAN_DATA_DIR:-}" ]] && export NFTBAN_DATA_DIR="/var/lib/nftban"

# =============================================================================
# CONFIG-LOCAL OVERRIDE LOADER (v1.201.x CONFIG_LOCAL_RECOVERY IMPL-1)
# =============================================================================
# _source_local <abs_path_to_.conf.local> — the SINGLE authority for sourcing
# operator *.conf.local override files. Replaces ~41 scattered, inconsistently-
# guarded `source X 2>/dev/null || true` sites. Behavior:
#   - NFTBAN_IGNORE_LOCAL_CONFIG=1 -> skip ALL .local (break-glass bypass)
#   - missing / unreadable file    -> silent success (return 0)
#   - present + `bash -n` clean     -> source it (KEY=value assignments land in
#                                      the global scope, preserving today's
#                                      semantics for good .local files)
#   - present + `bash -n` FAILS     -> do NOT source (no partial-apply), emit ONE
#                                      actionable WARN, continue non-fatal (the
#                                      caller proceeds on base defaults)
# Always returns 0 (non-fatal) so callers need no `|| true` and set -e is safe.
declare -A _NFTBAN_LOCAL_WARNED 2>/dev/null || true
_source_local() {
    local _sl_file="$1"
    [[ -n "${NFTBAN_IGNORE_LOCAL_CONFIG:-}" ]] && return 0
    [[ -f "$_sl_file" && -r "$_sl_file" ]] || return 0
    if bash -n "$_sl_file" 2>/dev/null; then
        # shellcheck source=/dev/null
        source "$_sl_file"
        return 0
    fi
    if [[ -z "${_NFTBAN_LOCAL_WARNED[$_sl_file]:-}" ]]; then
        _NFTBAN_LOCAL_WARNED[$_sl_file]=1
        printf 'nftban: WARNING: skipping malformed config override %s (bash -n failed) — using defaults. Fix it, or run with NFTBAN_IGNORE_LOCAL_CONFIG=1.\n' "$_sl_file" >&2
    fi
    return 0
}

# =============================================================================
# LOAD CONFIG (if not already loaded by main CLI)
# =============================================================================
# Only load config if the main nftban script hasn't already done it
# This allows scripts to run independently while still getting config values

if [[ -z "${NFTBAN_CONFIG_LOADED:-}" ]]; then
    if [[ -f "${NFTBAN_CONFIG_DIR}/nftban.conf" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_CONFIG_DIR}/nftban.conf" || true
    fi
    # v1.19.0: Source .local override (user customizations survive package updates).
    # v1.201.x IMPL-1: routed through _source_local (bash -n gate + bypass-aware).
    _source_local "${NFTBAN_CONFIG_DIR}/nftban.conf.local"
    export NFTBAN_CONFIG_LOADED="true"
fi
