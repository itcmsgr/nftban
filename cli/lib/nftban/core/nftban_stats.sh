#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Statistics & Metrics Core Engine
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Comprehensive statistics collection, analysis, and reporting
#
# meta:name="nftban_stats"
# meta:type="core"
# meta:header="Statistics & Metrics Engine"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# **Description & Purpose**
# meta:description="Production-grade stats engine with real-time metrics and analytics"
# meta:input="System metrics, ban data, and firewall statistics"
# meta:output="Dashboards, analytics reports, and statistical summaries"
#
# **Inventory & Requirements**
# meta:depends="nft,nftban_geoip_go.sh"
# meta:inventory.files="/usr/lib/nftban/core/nftban_stats.sh"
# meta:inventory.binaries="nft"
# meta:inventory.env_vars="NFTBAN_LOG_DIR,NFTBAN_DATA_DIR,NFTBAN_CACHE_DIR"
# meta:inventory.config_files="/etc/nftban/nftban.conf"
# meta:inventory.systemd_units="none"
# meta:inventory.network="none"
# meta:inventory.privileges="root:read-nftables,read-logs"
#
# meta:created_date="2025-11-05"
# meta:updated_date="2026-02-27"
# =============================================================================

# Enhanced strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_STATS_LOADED:-}" ]] && return 0
readonly NFTBAN_STATS_LOADED=1

# =============================================================================
# CONFIGURATION & PATHS
# =============================================================================

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# Source central environment loader (single source of truth for paths)
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/env.sh" || return 1

# Source file utilities for age/freshness checking
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_file_utils.sh" 2>/dev/null || true

# Use central config paths (set by nftban.conf)
readonly NFTBAN_STATS_DB="${STATS_DB_DIR:-${NFTBAN_DATA_DIR}/metrics}/metrics.db"
readonly NFTBAN_STATS_CACHE_DIR="${STATS_CACHE_DIR:-${NFTBAN_CACHE_DIR}/stats}"
readonly NFTBAN_STATS_SNAPSHOTS_DIR="${STATS_SNAPSHOTS_DIR:-${NFTBAN_DATA_DIR}/snapshots}"
# shellcheck disable=SC2034  # Used by sub-modules: nftban_stats_collect.sh, nftban_stats_format.sh
readonly NFTBAN_BAN_LOG="${STATS_BAN_LOG:-${NFTBAN_LOG_DIR}/bans.log}"
# shellcheck disable=SC2034  # Reserved for stats logging
readonly NFTBAN_STATS_LOG="${STATS_LOG_FILE:-${NFTBAN_LOG_DIR}/stats.log}"

# Configuration defaults (overridden by conf.d/stats.conf)
# shellcheck disable=SC2034  # Used by sub-modules: nftban_stats_collect.sh, nftban_stats_format.sh
STATS_ENABLED="${STATS_ENABLED:-true}"
STATS_CACHE_ENABLED="${STATS_CACHE_ENABLED:-true}"
STATS_CACHE_TTL="${STATS_CACHE_TTL:-300}"
STATS_RETENTION_DAYS="${STATS_RETENTION_DAYS:-90}"
STATS_GEOIP_ENABLED="${STATS_GEOIP_ENABLED:-true}"
STATS_TOP_N="${STATS_TOP_N:-10}"

# Create required directories
mkdir -p "$(dirname "$NFTBAN_STATS_DB")" 2>/dev/null || true
mkdir -p "$NFTBAN_STATS_CACHE_DIR" 2>/dev/null || true
mkdir -p "$NFTBAN_STATS_SNAPSHOTS_DIR" 2>/dev/null || true

# Source canonical NFT schema (single source of truth for table/set names)
# NFTBAN_LIB_DIR is set by the calling script - just use it with fallback
# shellcheck source=/usr/lib/nftban/lib/nft_schema.sh
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nft_schema.sh" ]]; then
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nft_schema.sh" || return 1
else
    # Development fallback: Try to locate from script location
    _STATS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _NFT_SCHEMA_PATH="$(dirname "$_STATS_DIR")/lib/nft_schema.sh"
    if [[ -f "$_NFT_SCHEMA_PATH" ]]; then
        source "$_NFT_SCHEMA_PATH" || true
    else
        echo "ERROR: Cannot load nft_schema.sh - NFTables schema undefined" >&2
        echo "  Tried: ${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nft_schema.sh" >&2
        echo "  Tried: $_NFT_SCHEMA_PATH" >&2
        exit 1
    fi
    unset _STATS_DIR _NFT_SCHEMA_PATH
fi

# =============================================================================
# CACHE MANAGEMENT
# =============================================================================

nftban_stats_get_cache() {
    # Get cached data if fresh
    # Usage: nftban_stats_get_cache "cache_key"
    # Returns: 0=cache hit (prints data), 1=cache miss

    local cache_key="$1"
    local cache_file="${NFTBAN_STATS_CACHE_DIR}/${cache_key}.cache"

    [[ "$STATS_CACHE_ENABLED" != "true" ]] && return 1
    [[ ! -f "$cache_file" ]] && return 1

    # Check if cache is fresh using file_utils library
    if nftban_file_is_fresh "$cache_file" "${STATS_CACHE_TTL}"; then
        cat "$cache_file"
        return 0
    fi

    return 1
}

nftban_stats_set_cache() {
    # Store data in cache
    # Usage: nftban_stats_set_cache "cache_key" "data"

    local cache_key="$1"
    local data="$2"
    local cache_file="${NFTBAN_STATS_CACHE_DIR}/${cache_key}.cache"

    [[ "$STATS_CACHE_ENABLED" != "true" ]] && return 0

    echo "$data" > "$cache_file" 2>/dev/null || true
}

nftban_stats_clear_cache() {
    # Clear all cached statistics
    # Usage: nftban_stats_clear_cache

    rm -f "${NFTBAN_STATS_CACHE_DIR}"/*.cache 2>/dev/null || true

    if type -t nftban_print_status >/dev/null 2>&1; then
        nftban_print_status "info" "Stats cache cleared"
    else
        echo "[INFO] Stats cache cleared"
    fi
}

# =============================================================================
# UNIFIED METRICS CACHE (Single Source of Truth)
# =============================================================================
# The unified exporter collects ALL metrics and writes to:
#   /var/cache/nftban/metrics/stats.json
#
# This is the SINGLE SOURCE OF TRUTH. All stats functions should read
# from this cache when available, falling back to direct collection
# only if cache is stale (>5 minutes old).
# =============================================================================

# Unified cache location (written by nftban_unified_exporter.sh)
readonly NFTBAN_UNIFIED_CACHE="${NFTBAN_JSON_CACHE_DIR:-/var/cache/nftban/metrics}/stats.json"
readonly NFTBAN_UNIFIED_CACHE_TTL="${NFTBAN_UNIFIED_CACHE_TTL:-300}"  # 5 minutes

# Cached JSON data (loaded once per session)
_UNIFIED_CACHE_DATA=""
_UNIFIED_CACHE_LOADED=0

nftban_stats_load_unified_cache() {
    # Load unified metrics cache (Single Source of Truth)
    # Usage: nftban_stats_load_unified_cache
    # Returns: 0=success (cache loaded), 1=cache miss/stale
    # Sets: _UNIFIED_CACHE_DATA with JSON content

    # Already loaded this session?
    if [[ $_UNIFIED_CACHE_LOADED -eq 1 ]] && [[ -n "$_UNIFIED_CACHE_DATA" ]]; then
        return 0
    fi

    # Check if cache file exists
    if [[ ! -f "$NFTBAN_UNIFIED_CACHE" ]]; then
        return 1
    fi

    # Check if cache is fresh using file_utils library
    if nftban_file_is_stale "$NFTBAN_UNIFIED_CACHE" "$NFTBAN_UNIFIED_CACHE_TTL"; then
        return 1  # Cache too old
    fi

    # Load cache data
    _UNIFIED_CACHE_DATA=$(cat "$NFTBAN_UNIFIED_CACHE" 2>/dev/null)
    if [[ -z "$_UNIFIED_CACHE_DATA" ]]; then
        return 1
    fi

    # Validate JSON (quick check)
    if ! echo "$_UNIFIED_CACHE_DATA" | jq -e '.schema_version' &>/dev/null; then
        _UNIFIED_CACHE_DATA=""
        return 1
    fi

    _UNIFIED_CACHE_LOADED=1
    return 0
}

nftban_stats_get_unified() {
    # Get value from unified cache using jq path
    # Usage: nftban_stats_get_unified ".blacklist.ipv4.total"
    # Returns: Value or empty string if not found

    local jq_path="$1"
    local default="${2:-}"

    if ! nftban_stats_load_unified_cache; then
        echo "$default"
        return 1
    fi

    local value
    value=$(echo "$_UNIFIED_CACHE_DATA" | jq -r "$jq_path // empty" 2>/dev/null)
    if [[ -z "$value" ]] || [[ "$value" == "null" ]]; then
        echo "$default"
        return 1
    fi

    echo "$value"
    return 0
}

nftban_stats_unified_available() {
    # Check if unified cache is available and fresh
    # Usage: if nftban_stats_unified_available; then ...
    # Returns: 0=available, 1=not available

    nftban_stats_load_unified_cache
}

# =============================================================================
# SUB-MODULES (refactored from monolithic 1819-line file)
# =============================================================================
# nftban_stats_collect.sh  — Core metrics collection (13 functions)
# nftban_stats_format.sh   — Dashboard, export, trends (15 functions)
# =============================================================================

# shellcheck source=/usr/lib/nftban/core/nftban_stats_collect.sh
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_stats_collect.sh" || return 1

# shellcheck source=/usr/lib/nftban/core/nftban_stats_format.sh
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_stats_format.sh" || return 1

# =============================================================================
# MODULE INITIALIZATION
# =============================================================================

# Module loaded
if type -t nftban_print_status >/dev/null 2>&1; then
    nftban_print_status "debug" "Stats module loaded"
fi
