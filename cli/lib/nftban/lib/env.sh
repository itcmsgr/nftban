#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
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
# FINAL OPERATOR OVERLAY (v1.230.0 PR-5c-B1)
# =============================================================================
# THE PRECEDENCE CONTRACT THIS EXISTS TO MAKE EXPLICIT:
#
#     shipped/module base  <  module-local override  <  central operator override
#
# The Go plane already implements exactly that, last-wins, with nftban.conf.local as the
# highest-priority layer (internal/nftbanconf/loader.go:484 — "the SINGLE user override
# file"). The shell plane did NOT: env.sh loads nftban.conf.local once at startup, and any
# consumer that later sources its own base `conf.d/X.conf` overwrites it, because every
# shipped base file uses PLAIN assignments. Bash is last-assignment-wins, so the operator's
# supported override lost to a shipped default. MEASURED: operator sets STATS_ENABLED=false
# via `nftban config set`; after the central load the value is false; after
# cmd_report.sh:1076 sources conf.d/stats.conf it is true again.
#
# ⛔ NOT fixed by rewriting base files to `: "${KEY:=...}"`. Empty-value semantics are
#    key-specific in this tree, and := treats empty as unset — that would silently change a
#    second contract while repairing this one.
# ⛔ NOT fixed by scattering `source nftban.conf.local` through consumers: that recreates
#    the scattered authority the central file exists to remove.
#
# Instead the override is applied ONCE MORE, deliberately, at the point where a consumer has
# finished loading its subject base and subject-local configuration. The startup load in
# env.sh is deliberately left in place — removing it would turn this into a change to global
# initialisation semantics rather than a precedence repair.
#
# Re-application is safe: _source_local is idempotent for assignment files, keeps the
# `bash -n` candidate gate, and honours NFTBAN_IGNORE_LOCAL_CONFIG.
nftban_config_apply_final_operator_overlay() {
    _source_local "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf.local"
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
