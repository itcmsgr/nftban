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
# meta:updated_date="2026-01-25"
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
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/env.sh"

# Source file utilities for age/freshness checking
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_file_utils.sh" 2>/dev/null || true

# Use central config paths (set by nftban.conf)
readonly NFTBAN_STATS_DB="${STATS_DB_DIR:-${NFTBAN_DATA_DIR}/metrics}/metrics.db"
readonly NFTBAN_STATS_CACHE_DIR="${STATS_CACHE_DIR:-${NFTBAN_CACHE_DIR}/stats}"
readonly NFTBAN_STATS_SNAPSHOTS_DIR="${STATS_SNAPSHOTS_DIR:-${NFTBAN_DATA_DIR}/snapshots}"
readonly NFTBAN_BAN_LOG="${STATS_BAN_LOG:-${NFTBAN_LOG_DIR}/bans.log}"
# shellcheck disable=SC2034  # Reserved for stats logging
readonly NFTBAN_STATS_LOG="${STATS_LOG_FILE:-${NFTBAN_LOG_DIR}/stats.log}"

# Configuration defaults (overridden by conf.d/stats.conf)
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
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nft_schema.sh"
else
    # Development fallback: Try to locate from script location
    _STATS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _NFT_SCHEMA_PATH="$(dirname "$_STATS_DIR")/lib/nft_schema.sh"
    if [[ -f "$_NFT_SCHEMA_PATH" ]]; then
        source "$_NFT_SCHEMA_PATH"
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
# CORE METRICS COLLECTION
# =============================================================================

nftban_stats_count_bans() {
    # Count total bans in time window
    # Usage: nftban_stats_count_bans [since] [until]
    # Args: since=YYYY-MM-DD (default: 1970-01-01)
    #       until=YYYY-MM-DD (default: today)
    # Returns: Number of bans
    #
    # SINGLE SOURCE OF TRUTH: Uses unified cache for common time windows

    local since="${1:-1970-01-01}"
    local until="${2:-$(date +%Y-%m-%d)}"
    local today
    today=$(date +%Y-%m-%d)

    # Try unified cache for common time windows
    if nftban_stats_unified_available; then
        local yesterday week_ago month_ago
        yesterday=$(date -d '1 day ago' +%Y-%m-%d 2>/dev/null || date -v-1d +%Y-%m-%d 2>/dev/null || echo "")
        week_ago=$(date -d '7 days ago' +%Y-%m-%d 2>/dev/null || date -v-7d +%Y-%m-%d 2>/dev/null || echo "")
        month_ago=$(date -d '30 days ago' +%Y-%m-%d 2>/dev/null || date -v-30d +%Y-%m-%d 2>/dev/null || echo "")

        # All-time bans
        if [[ "$since" == "1970-01-01" ]] && [[ "$until" == "$today" ]]; then
            nftban_stats_get_unified ".activity.total_bans" "0"
            return 0
        fi
        # 24h window
        if [[ "$since" == "$yesterday" ]] && [[ "$until" == "$today" ]]; then
            nftban_stats_get_unified ".activity.bans_24h" "0"
            return 0
        fi
        # 7d window
        if [[ "$since" == "$week_ago" ]] && [[ "$until" == "$today" ]]; then
            nftban_stats_get_unified ".activity.bans_7d" "0"
            return 0
        fi
        # 30d window
        if [[ "$since" == "$month_ago" ]] && [[ "$until" == "$today" ]]; then
            nftban_stats_get_unified ".activity.bans_30d" "0"
            return 0
        fi
    fi

    # Fallback: Parse log file for custom date ranges
    if [[ ! -f "$NFTBAN_BAN_LOG" ]]; then
        echo "0"
        return 0
    fi

    # Try local cache
    local cache_key="bans_${since}_${until}"
    if nftban_stats_get_cache "$cache_key"; then
        return 0
    fi

    # Count bans from log
    local count
    count=$(awk -F'|' -v since="$since" -v until="$until" \
        '$1 >= since && $1 <= until && $6 == "BANNED" {count++} END {print count+0}' \
        "$NFTBAN_BAN_LOG")

    nftban_stats_set_cache "$cache_key" "$count"
    echo "$count"
}

nftban_stats_count_unique_ips() {
    # Count unique IPs banned in time window
    # Usage: nftban_stats_count_unique_ips [since] [until]
    #
    # SINGLE SOURCE OF TRUTH: Uses unified cache for common time windows

    local since="${1:-1970-01-01}"
    local until="${2:-$(date +%Y-%m-%d)}"
    local today
    today=$(date +%Y-%m-%d)

    # Try unified cache for common time windows
    if nftban_stats_unified_available; then
        local yesterday
        yesterday=$(date -d '1 day ago' +%Y-%m-%d 2>/dev/null || date -v-1d +%Y-%m-%d 2>/dev/null || echo "")

        # All-time unique IPs
        if [[ "$since" == "1970-01-01" ]] && [[ "$until" == "$today" ]]; then
            nftban_stats_get_unified ".activity.unique_ips" "0"
            return 0
        fi
        # 24h unique IPs
        if [[ "$since" == "$yesterday" ]] && [[ "$until" == "$today" ]]; then
            nftban_stats_get_unified ".activity.unique_ips_24h" "0"
            return 0
        fi
    fi

    # Fallback: Parse log file for custom date ranges
    if [[ ! -f "$NFTBAN_BAN_LOG" ]]; then
        echo "0"
        return 0
    fi

    # Try local cache
    local cache_key="unique_ips_${since}_${until}"
    if nftban_stats_get_cache "$cache_key"; then
        return 0
    fi

    # Count unique IPs from log
    local count
    count=$(awk -F'|' -v since="$since" -v until="$until" \
        '$1 >= since && $1 <= until && $6 == "BANNED" {ips[$4]=1} END {print length(ips)}' \
        "$NFTBAN_BAN_LOG")

    nftban_stats_set_cache "$cache_key" "$count"
    echo "$count"
}

nftban_stats_count_active_bans() {
    # Count currently active bans in nftables (v0.7.3 unified architecture)
    # Usage: nftban_stats_count_active_bans
    # Returns: Number of active bans
    #
    # SINGLE SOURCE OF TRUTH: Reads from unified cache when available
    # Fallback: Direct nftables query if cache is stale

    # Try unified cache first (Single Source of Truth)
    local cached_total
    if cached_total=$(nftban_stats_get_unified ".blacklist.total"); then
        echo "$cached_total"
        return 0
    fi

    # Fallback: Use nft_schema.sh centralized counting (SINGLE SOURCE OF TRUTH)
    # nftban_nft_count_blacklist returns: "ipv4_count ipv6_count total_count"
    local counts
    counts=$(nftban_nft_count_blacklist 2>/dev/null || echo "0 0 0")
    echo "${counts##* }"  # Return total (last field)
}

nftban_stats_count_whitelist() {
    # Count whitelist entries from nftables (v0.7.3 dual-table architecture)
    # Usage: nftban_stats_count_whitelist
    # Returns: Total whitelist entries
    #
    # SINGLE SOURCE OF TRUTH: Reads from unified cache when available

    # Try unified cache first
    local cached_total
    if cached_total=$(nftban_stats_get_unified ".whitelist.total"); then
        echo "$cached_total"
        return 0
    fi

    # Fallback: Use nft_schema.sh centralized counting (SINGLE SOURCE OF TRUTH)
    # nftban_nft_count_whitelist returns: "ipv4_count ipv6_count total_count"
    local counts
    counts=$(nftban_nft_count_whitelist 2>/dev/null || echo "0 0 0")
    echo "${counts##* }"  # Return total (last field)
}

# =============================================================================
# DETAILED BREAKDOWN FUNCTIONS (SINGLE SOURCE OF TRUTH)
# These wrap nft_schema.sh functions for consistent metrics everywhere
# =============================================================================

nftban_stats_get_blacklist_breakdown() {
    # Get detailed blacklist breakdown: IPv4, IPv6, temporary, permanent
    # Usage: nftban_stats_get_blacklist_breakdown
    # Returns: JSON {"ipv4":N,"ipv6":N,"temporary":N,"permanent":N,"total":N}
    #
    # SINGLE SOURCE OF TRUTH: Uses nft_schema.sh nftban_nft_count_all_sets()

    local json
    json=$(nftban_nft_count_all_sets 2>/dev/null || echo '{"blacklist":{"ipv4":0,"ipv6":0,"total":0},"temporary":{"total":0},"permanent":{"total":0}}')

    local ipv4 ipv6 temp perm total
    ipv4=$(echo "$json" | jq -r '.blacklist.ipv4 // 0')
    ipv6=$(echo "$json" | jq -r '.blacklist.ipv6 // 0')
    temp=$(echo "$json" | jq -r '.temporary.total // 0')
    perm=$(echo "$json" | jq -r '.permanent.total // 0')
    total=$(echo "$json" | jq -r '.blacklist.total // 0')

    echo "{\"ipv4\":$ipv4,\"ipv6\":$ipv6,\"temporary\":$temp,\"permanent\":$perm,\"total\":$total}"
}

nftban_stats_get_whitelist_breakdown() {
    # Get detailed whitelist breakdown: IPv4, IPv6
    # Usage: nftban_stats_get_whitelist_breakdown
    # Returns: JSON {"ipv4":N,"ipv6":N,"total":N}
    #
    # SINGLE SOURCE OF TRUTH: Uses nft_schema.sh nftban_nft_count_whitelist()

    local counts ipv4 ipv6 total
    counts=$(nftban_nft_count_whitelist 2>/dev/null || echo "0 0 0")

    # Parse "ipv4 ipv6 total" format
    ipv4=$(echo "$counts" | cut -d' ' -f1)
    ipv6=$(echo "$counts" | cut -d' ' -f2)
    total=$(echo "$counts" | cut -d' ' -f3)

    echo "{\"ipv4\":${ipv4:-0},\"ipv6\":${ipv6:-0},\"total\":${total:-0}}"
}

nftban_stats_count_rules() {
    # Count total nftables rules in nftban table
    # Usage: nftban_stats_count_rules
    # Returns: Integer count of rules
    #
    # SINGLE SOURCE OF TRUTH: Direct nft query (no caching needed - fast operation)
    # v1.18.0: Use ip nftban table (not inet nftban)

    local count_v4 count_v6
    count_v4=$(nft list table ip nftban 2>/dev/null | grep -c "^\s*\(accept\|drop\|reject\|counter\|log\)" || echo "0")
    count_v6=$(nft list table ip6 nftban 2>/dev/null | grep -c "^\s*\(accept\|drop\|reject\|counter\|log\)" || echo "0")
    echo "$((count_v4 + count_v6))"
}

# =============================================================================
# BAN SOURCE ANALYSIS
# =============================================================================

nftban_stats_ban_sources() {
    # Get ban breakdown by source (login, portscan, ddos, manual, feeds, suricata)
    # Usage: nftban_stats_ban_sources [since] [until]
    # Returns: JSON {"login":N,"portscan":N,"ddos":N,"manual":N,"feeds":N,"suricata":N}
    #
    # SINGLE SOURCE OF TRUTH: Uses unified cache when available

    local since="${1:-1970-01-01}"
    local until="${2:-$(date +%Y-%m-%d)}"
    local today
    today=$(date +%Y-%m-%d)

    # Try unified cache first (Single Source of Truth)
    # Use bans_by_source for all-time, bans_by_source_24h for 24h window
    if nftban_stats_unified_available; then
        local login portscan ddos manual feeds suricata

        # Determine which cache to use based on time window
        if [[ "$since" == "1970-01-01" ]] && [[ "$until" == "$today" ]]; then
            # All-time stats -> use bans_by_source
            login=$(nftban_stats_get_unified ".bans_by_source.login" "0")
            portscan=$(nftban_stats_get_unified ".bans_by_source.portscan" "0")
            ddos=$(nftban_stats_get_unified ".bans_by_source.ddos" "0")
            manual=$(nftban_stats_get_unified ".bans_by_source.manual" "0")
            feeds=$(nftban_stats_get_unified ".bans_by_source.feeds" "0")
            suricata=$(nftban_stats_get_unified ".bans_by_source.suricata" "0")
            echo "{\"login\":$login,\"portscan\":$portscan,\"ddos\":$ddos,\"manual\":$manual,\"feeds\":$feeds,\"suricata\":$suricata}"
            return 0
        fi

        # Check if this is a 24h window (yesterday to today)
        local yesterday
        yesterday=$(date -d '1 day ago' +%Y-%m-%d 2>/dev/null || date -v-1d +%Y-%m-%d 2>/dev/null || echo "")
        if [[ "$since" == "$yesterday" ]] && [[ "$until" == "$today" ]]; then
            # 24h stats -> use bans_by_source_24h
            login=$(nftban_stats_get_unified ".bans_by_source_24h.login" "0")
            portscan=$(nftban_stats_get_unified ".bans_by_source_24h.portscan" "0")
            ddos=$(nftban_stats_get_unified ".bans_by_source_24h.ddos" "0")
            manual=$(nftban_stats_get_unified ".bans_by_source_24h.manual" "0")
            feeds=$(nftban_stats_get_unified ".bans_by_source_24h.feeds" "0")
            suricata=$(nftban_stats_get_unified ".bans_by_source_24h.suricata" "0")
            echo "{\"login\":$login,\"portscan\":$portscan,\"ddos\":$ddos,\"manual\":$manual,\"feeds\":$feeds,\"suricata\":$suricata}"
            return 0
        fi
    fi

    # Fallback: Parse log file for custom date ranges
    if [[ ! -f "$NFTBAN_BAN_LOG" ]]; then
        echo "{\"login\":0,\"portscan\":0,\"ddos\":0,\"manual\":0,\"feeds\":0,\"suricata\":0}"
        return 0
    fi

    # Try local cache
    local cache_key="sources_${since}_${until}"
    if nftban_stats_get_cache "$cache_key"; then
        return 0
    fi

    # Analyze sources from log
    local result
    result=$(awk -F'|' -v since="$since" -v until="$until" '
    BEGIN {login=0; portscan=0; ddos=0; manual=0; feeds=0; suricata=0}
    $1 >= since && $1 <= until && $6 == "BANNED" {
        if ($3 ~ /login|ssh|auth|fail2ban/) login++
        else if ($3 ~ /portscan|scan/) portscan++
        else if ($3 ~ /ddos|flood|synflood/) ddos++
        else if ($3 == "manual" || $3 == "user") manual++
        else if ($3 ~ /feed/) feeds++
        else if ($3 ~ /suricata|ids/) suricata++
    }
    END {
        printf "{\"login\":%d,\"portscan\":%d,\"ddos\":%d,\"manual\":%d,\"feeds\":%d,\"suricata\":%d}", login, portscan, ddos, manual, feeds, suricata
    }' "$NFTBAN_BAN_LOG")

    nftban_stats_set_cache "$cache_key" "$result"
    echo "$result"
}

nftban_stats_top_sources() {
    # Get top ban sources (login, portscan, ddos, manual, feeds, suricata)
    # Usage: nftban_stats_top_sources [limit] [since] [until]
    # Returns: JSON array [{"name":"source","count":N},...]
    #
    # SINGLE SOURCE OF TRUTH: Uses unified cache when available for common time windows

    local limit="${1:-${STATS_TOP_N}}"
    local since="${2:-1970-01-01}"
    local until="${3:-$(date +%Y-%m-%d)}"
    local today
    today=$(date +%Y-%m-%d)

    # Try unified cache first (Single Source of Truth)
    if nftban_stats_unified_available; then
        local yesterday
        yesterday=$(date -d '1 day ago' +%Y-%m-%d 2>/dev/null || date -v-1d +%Y-%m-%d 2>/dev/null || echo "")

        # Determine which cache source to use based on time window
        local cache_prefix=""
        if [[ "$since" == "1970-01-01" ]] && [[ "$until" == "$today" ]]; then
            cache_prefix=".bans_by_source"  # All-time stats
        elif [[ "$since" == "$yesterday" ]] && [[ "$until" == "$today" ]]; then
            cache_prefix=".bans_by_source_24h"  # 24h stats
        fi

        if [[ -n "$cache_prefix" ]]; then
            # Read from unified cache and format as sorted array
            local login portscan ddos manual feeds suricata
            login=$(nftban_stats_get_unified "${cache_prefix}.login" "0")
            portscan=$(nftban_stats_get_unified "${cache_prefix}.portscan" "0")
            ddos=$(nftban_stats_get_unified "${cache_prefix}.ddos" "0")
            manual=$(nftban_stats_get_unified "${cache_prefix}.manual" "0")
            feeds=$(nftban_stats_get_unified "${cache_prefix}.feeds" "0")
            suricata=$(nftban_stats_get_unified "${cache_prefix}.suricata" "0")

            # Build array and sort by count descending, limit to requested number
            printf '%d login\n%d portscan\n%d ddos\n%d manual\n%d feeds\n%d suricata\n' \
                "$login" "$portscan" "$ddos" "$manual" "$feeds" "$suricata" | \
            sort -rn | head -n "$limit" | \
            awk 'BEGIN{printf "["}
                 NR>1{printf ","}
                 $1 > 0 {printf "{\"name\":\"%s\",\"count\":%d}", $2, $1}
                 END{printf "]"}'
            return 0
        fi
    fi

    # Fallback: Parse log file for custom date ranges
    if [[ ! -f "$NFTBAN_BAN_LOG" ]]; then
        echo "[]"
        return 0
    fi

    awk -F'|' -v since="$since" -v until="$until" -v limit="$limit" \
        '$1 >= since && $1 <= until && $6 == "BANNED" {sources[$3]++}
         END {
             for (s in sources) print sources[s], s
         }' \
        "$NFTBAN_BAN_LOG" | \
    sort -rn | \
    awk -v limit="$limit" 'BEGIN{printf "["}
         NR>1 && NR<=limit+1{printf ","}
         NR<=limit {printf "{\"name\":\"%s\",\"count\":%d}", $2, $1}
         NR==limit {exit}
         END{printf "]"}'
}

# =============================================================================
# IP INTELLIGENCE
# =============================================================================

nftban_stats_top_ips() {
    # Get top banned IPs with GeoIP
    # Usage: nftban_stats_top_ips [limit] [since] [until]
    # Returns: JSON array with IP, count, country, first/last seen

    local limit="${1:-${STATS_TOP_N}}"
    local since="${2:-1970-01-01}"
    local until="${3:-$(date +%Y-%m-%d)}"

    if [[ ! -f "$NFTBAN_BAN_LOG" ]]; then
        echo "[]"
        return 0
    fi

    # Get top IPs into temp file to avoid subshell variable issues
    local temp_file
    temp_file=$(mktemp)
    trap 'rm -f "$temp_file"' RETURN

    awk -F'|' -v since="$since" -v until="$until" \
        '$1 >= since && $1 <= until && $6 == "BANNED" {ips[$4]++}
         END {for (ip in ips) print ips[ip], ip}' \
        "$NFTBAN_BAN_LOG" 2>/dev/null | \
    sort -rn | head -n "$limit" > "$temp_file" || true

    # Check if we have any results
    if [[ ! -s "$temp_file" ]]; then
        echo "[]"
        return 0
    fi

    local result="["
    local first=true

    while read -r count ip; do
        [[ -z "$ip" ]] && continue

        local country="--"
        local first_seen
        local last_seen

        # Get first and last seen (use subshell to avoid errexit issues)
        first_seen=$(grep "|${ip}|" "$NFTBAN_BAN_LOG" 2>/dev/null | awk -F'|' 'NR==1 {print $1; exit}' || true)
        [[ -z "$first_seen" ]] && first_seen="--"
        last_seen=$(grep "|${ip}|" "$NFTBAN_BAN_LOG" 2>/dev/null | awk -F'|' 'END {print $1}' || true)
        [[ -z "$last_seen" ]] && last_seen="--"

        # GeoIP lookup if enabled
        if [[ "${STATS_GEOIP_ENABLED}" == "true" ]] && command -v nftban-geoip &>/dev/null; then
            country=$(nftban-geoip lookup "$ip" 2>/dev/null | cut -d'/' -f1 || echo "--")
        fi

        # Build JSON
        if [[ "$first" == "false" ]]; then
            result+=","
        fi
        result+="{\"ip\":\"${ip}\",\"count\":${count},\"country\":\"${country}\",\"first_seen\":\"${first_seen}\",\"last_seen\":\"${last_seen}\"}"
        first=false
    done < "$temp_file"

    result+="]"
    echo "$result"
}

nftban_stats_ip_history() {
    # Get full ban history for specific IP
    # Usage: nftban_stats_ip_history "IP"
    # Returns: JSON array of events

    local ip="$1"

    if [[ ! -f "$NFTBAN_BAN_LOG" ]]; then
        echo "[]"
        return 0
    fi

    grep "|${ip}|" "$NFTBAN_BAN_LOG" 2>/dev/null | \
    awk -F'|' 'BEGIN{printf "["}
               NR>1{printf ","}
               {printf "{\"timestamp\":\"%s\",\"ip\":\"%s\",\"jail\":\"%s\",\"action\":\"%s\",\"reason\":\"%s\"}",
                       $1, $4, $3, $6, $5}
               END{printf "]"}' || echo "[]"
}

# =============================================================================
# GEOGRAPHIC ANALYSIS
# =============================================================================

nftban_stats_top_countries() {
    # Get top countries (requires GeoIP)
    # Usage: nftban_stats_top_countries [limit] [since] [until]
    # Returns: JSON array [{"country":"XX","count":N},...]
    #
    # OPTIMIZED: 2026-01-15 - Aggregate IPs first, then lookup unique IPs only
    # Previous: O(n) process spawns (one per IP)
    # Now: O(unique_ips) process spawns + O(n) in-memory aggregation

    local limit="${1:-${STATS_TOP_N}}"
    local since="${2:-1970-01-01}"
    local until="${3:-$(date +%Y-%m-%d)}"

    if [[ "${STATS_GEOIP_ENABLED}" != "true" ]] || ! command -v nftban-core &>/dev/null; then
        echo "[]"
        return 0
    fi

    if [[ ! -f "$NFTBAN_BAN_LOG" ]]; then
        echo "[]"
        return 0
    fi

    local temp_ips temp_countries
    temp_ips=$(mktemp)
    temp_countries=$(mktemp)

    # Step 1: Extract and count unique IPs (O(n) in awk, very fast)
    awk -F'|' -v since="$since" -v until="$until" \
        '$1 >= since && $1 <= until && $6 == "BANNED" {ips[$4]++}
         END {for (ip in ips) print ip, ips[ip]}' \
        "$NFTBAN_BAN_LOG" > "$temp_ips"

    # Step 2: Lookup country for each unique IP (O(unique_ips) lookups)
    # This is much faster than looking up every ban event
    declare -A country_counts
    while read -r ip count; do
        local country
        country=$(nftban-core geoip lookup "$ip" 2>/dev/null | cut -d'/' -f1) || country="Unknown"
        [[ -z "$country" ]] && country="Unknown"
        country_counts["$country"]=$(( ${country_counts["$country"]:-0} + count ))
    done < "$temp_ips"

    # Step 3: Sort by count and limit
    for country in "${!country_counts[@]}"; do
        echo "${country_counts[$country]} $country"
    done | sort -rn | head -n "$limit" > "$temp_countries"

    # Step 4: Convert to JSON
    awk 'BEGIN{printf "["}
         NR>1{printf ","}
         {printf "{\"country\":\"%s\",\"count\":%d}", $2, $1}
         END{printf "]"}' "$temp_countries"

    rm -f "$temp_ips" "$temp_countries"
}

# =============================================================================
# TEMPORAL ANALYSIS
# =============================================================================

nftban_stats_timeline() {
    # Get ban timeline with hourly/daily aggregation
    # Usage: nftban_stats_timeline [since] [until] [interval]
    # Args: interval = "hour" or "day"
    # Returns: JSON array [{"timestamp":"...",  "count":N},...]

    local since="${1:-$(date -d '24 hours ago' +%Y-%m-%d\ %H:%M:%S)}"
    local until="${2:-$(date +%Y-%m-%d\ %H:%M:%S)}"
    local interval="${3:-hour}"

    if [[ ! -f "$NFTBAN_BAN_LOG" ]]; then
        echo "[]"
        return 0
    fi

    local temp_file
    temp_file=$(mktemp)

    case "$interval" in
        hour)
            awk -F'|' -v since="$since" -v until="$until" '
            $1 >= since && $1 <= until && $6 == "BANNED" {
                hour=substr($1,1,13)":00:00"
                hours[hour]++
            }
            END {
                for (h in hours) printf "%s|%d\n", h, hours[h]
            }' "$NFTBAN_BAN_LOG" | sort > "$temp_file"
            ;;
        day)
            awk -F'|' -v since="$since" -v until="$until" '
            $1 >= since && $1 <= until && $6 == "BANNED" {
                day=substr($1,1,10)
                days[day]++
            }
            END {
                for (d in days) printf "%s|%d\n", d, days[d]
            }' "$NFTBAN_BAN_LOG" | sort > "$temp_file"
            ;;
    esac

    # Convert to JSON
    awk -F'|' 'BEGIN{printf "["}
               NR>1{printf ","}
               {printf "{\"timestamp\":\"%s\",\"count\":%d}", $1, $2}
               END{printf "]"}' "$temp_file"

    rm -f "$temp_file"
}

# =============================================================================
# DASHBOARD GENERATION
# =============================================================================

nftban_stats_generate_dashboard() {
    # Generate comprehensive terminal dashboard - Clean v1.0 layout
    # Usage: nftban_stats_generate_dashboard [since] [until]
    #
    # SINGLE SOURCE OF TRUTH: Uses unified cache when available

    local since="${1:-$(date -d '24 hours ago' +%Y-%m-%d)}"
    local until="${2:-$(date +%Y-%m-%d)}"

    # Load unified cache once for this dashboard run
    local use_unified_cache=false
    if nftban_stats_unified_available; then
        use_unified_cache=true
    fi

    # Collect metrics (uses unified cache internally)
    local total_bans unique_ips whitelist_count
    total_bans=$(nftban_stats_count_bans "$since" "$until")
    unique_ips=$(nftban_stats_count_unique_ips "$since" "$until")
    whitelist_count=$(nftban_stats_count_whitelist)

    # Header
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NFTBan Statistics Dashboard"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # ─────────────────────────────────────────────────────────────────────
    # SYSTEM
    # ─────────────────────────────────────────────────────────────────────
    echo "SYSTEM"
    echo "───────────────────────────────────────────────────────────"
    printf "  %-20s %s\n" "Hostname............" "$(hostname)"
    printf "  %-20s %s → %s\n" "Period.............." "$since" "$until"
    printf "  %-20s %s\n" "Generated..........." "$(date '+%Y-%m-%d %H:%M:%S')"
    if [[ "$use_unified_cache" == "true" ]]; then
        printf "  %-20s %s\n" "Data source........." "unified cache"
    fi
    echo ""

    # ─────────────────────────────────────────────────────────────────────
    # UNIFIED BLACKLIST (SINGLE SOURCE OF TRUTH from unified cache)
    # ─────────────────────────────────────────────────────────────────────
    local black_v4=0 black_v6=0
    local black_v4_temp=0 black_v4_perm=0
    local black_v6_temp=0 black_v6_perm=0

    if [[ "$use_unified_cache" == "true" ]]; then
        # Read from unified cache (Single Source of Truth)
        black_v4=$(nftban_stats_get_unified ".blacklist.ipv4.total" "0")
        black_v4_perm=$(nftban_stats_get_unified ".blacklist.ipv4.permanent" "0")
        black_v4_temp=$(nftban_stats_get_unified ".blacklist.ipv4.temporary" "0")
        black_v6=$(nftban_stats_get_unified ".blacklist.ipv6.total" "0")
        black_v6_perm=$(nftban_stats_get_unified ".blacklist.ipv6.permanent" "0")
        black_v6_temp=$(nftban_stats_get_unified ".blacklist.ipv6.temporary" "0")
    else
        # Fallback: Direct nftables query
        if timeout 10s nft list set "${NFTBAN_TABLE_IPV4}" blacklist_ipv4 &>/dev/null 2>&1; then
            local v4_output
            v4_output=$(timeout 10s nft list set "${NFTBAN_TABLE_IPV4}" blacklist_ipv4 2>/dev/null || true)
            black_v4_temp=$(echo "$v4_output" | { grep -oP 'timeout \d+[smhd]' 2>/dev/null || true; } | wc -l)
            black_v4=$(echo "$v4_output" | { grep -oP '\d+\.\d+\.\d+\.\d+(/\d+)?' || true; } | wc -l 2>/dev/null || echo "0")
            black_v4=${black_v4:-0}
            black_v4_temp=${black_v4_temp:-0}
            black_v4_perm=$((black_v4 - black_v4_temp))
            [[ $black_v4_perm -lt 0 ]] && black_v4_perm=0
        fi
        if timeout 10s nft list set "${NFTBAN_TABLE_IPV6}" blacklist_ipv6 &>/dev/null 2>&1; then
            local v6_output
            v6_output=$(timeout 10s nft list set "${NFTBAN_TABLE_IPV6}" blacklist_ipv6 2>/dev/null || true)
            black_v6_temp=$(echo "$v6_output" | { grep -oP 'timeout \d+[smhd]' 2>/dev/null || true; } | wc -l)
            black_v6=$(echo "$v6_output" | { grep -oP '[0-9a-fA-F:]+::[0-9a-fA-F:]*(/\d+)?|[0-9a-fA-F:]+:[0-9a-fA-F:]+(/\d+)?' || true; } | wc -l 2>/dev/null || echo "0")
            black_v6=${black_v6:-0}
            black_v6_temp=${black_v6_temp:-0}
            black_v6_perm=$((black_v6 - black_v6_temp))
            [[ $black_v6_perm -lt 0 ]] && black_v6_perm=0
        fi
    fi

    black_v4=${black_v4//[^0-9]/}
    black_v6=${black_v6//[^0-9]/}
    local total_black
    total_black=$((${black_v4:-0} + ${black_v6:-0}))

    # ─────────────────────────────────────────────────────────────────────
    # FIREWALL (CURRENT)
    # ─────────────────────────────────────────────────────────────────────
    echo "FIREWALL (CURRENT)"
    echo "───────────────────────────────────────────────────────────"
    printf "  %-20s %s\n" "Blocked IPs........." "$total_black"
    printf "  %-20s %s\n" "Whitelisted........." "$whitelist_count"
    echo ""

    # ─────────────────────────────────────────────────────────────────────
    # PROTECTION BREAKDOWN (all sources)
    # ─────────────────────────────────────────────────────────────────────
    echo "PROTECTION BREAKDOWN"
    echo "───────────────────────────────────────────────────────────"

    # Direct bans (blacklist sets) - show IPv4/IPv6 and temp/permanent
    echo "  Direct Bans (nftables):"
    printf "      %-16s %'d (perm: %'d, temp: %'d)\n" "IPv4............" "$black_v4" "$black_v4_perm" "$black_v4_temp"
    printf "      %-16s %'d (perm: %'d, temp: %'d)\n" "IPv6............" "$black_v6" "$black_v6_perm" "$black_v6_temp"

    # Count feeds (SINGLE SOURCE OF TRUTH from unified cache)
    local feeds_ipv4_total=0 feeds_ipv6_total=0
    if [[ "$use_unified_cache" == "true" ]]; then
        # Read from unified cache
        feeds_ipv4_total=$(nftban_stats_get_unified ".feeds.ipv4_total" "0")
        feeds_ipv6_total=$(nftban_stats_get_unified ".feeds.ipv6_total" "0")
    else
        # Ensure feeds library is loaded for discovery functions
        if ! type -t nftban_feeds_discover_all >/dev/null 2>&1; then
            if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_feeds.sh" ]]; then
                source "${NFTBAN_LIB_DIR}/core/nftban_feeds.sh" 2>/dev/null || true
            fi
        fi

        # Fallback: Scan feed files
        local feeds_dir="${NFTBAN_DATA_DIR:-/var/lib/nftban}/feeds"
        if [[ -d "$feeds_dir" ]]; then
            if type -t nftban_feeds_discover_all >/dev/null 2>&1 && type -t nftban_feeds_get_property >/dev/null 2>&1; then
                local all_feeds
                all_feeds=$(nftban_feeds_discover_all 2>/dev/null || true)
                for feed in $all_feeds; do
                    local enabled
                    enabled=$(nftban_feeds_get_property "$feed" "ENABLED" 2>/dev/null || echo "false")
                    if [[ "$enabled" == "true" ]]; then
                        local feed_lower="${feed,,}"
                        local feed_file="${feeds_dir}/${feed_lower}.txt"
                        if [[ -f "$feed_file" ]]; then
                            local v4_count v6_count
                            v4_count=$(grep -cE '^[0-9]+\.' "$feed_file" 2>/dev/null) || v4_count=0
                            v6_count=$(grep -cE '^[0-9a-fA-F]*:' "$feed_file" 2>/dev/null) || v6_count=0
                            feeds_ipv4_total=$((feeds_ipv4_total + v4_count))
                            feeds_ipv6_total=$((feeds_ipv6_total + v6_count))
                        fi
                    fi
                done
            fi
        fi
    fi
    echo "  Threat Feeds:"
    printf "      %-16s %'d\n" "IPv4............" "$feeds_ipv4_total"
    printf "      %-16s %'d\n" "IPv6............" "$feeds_ipv6_total"

    # Count geoban entries (SINGLE SOURCE OF TRUTH from unified cache)
    local geoban_total=0
    if [[ "$use_unified_cache" == "true" ]]; then
        # Read from unified cache
        geoban_total=$(nftban_stats_get_unified ".geoban.countries_blocked" "0")
    else
        # Fallback: Scan geoban config files
        local geoban_dir="${NFTBAN_DATA_DIR:-/var/lib/nftban}/geoban"
        if [[ -d "$geoban_dir" ]]; then
            local blocked_countries=0
            shopt -s nullglob 2>/dev/null || true
            for file in "$geoban_dir"/*.conf; do
                [[ -f "$file" ]] && grep -q "^MODE=.*block" "$file" 2>/dev/null && ((blocked_countries++))
            done
            shopt -u nullglob 2>/dev/null || true
            geoban_total=$blocked_countries
        fi
    fi
    if [[ $geoban_total -gt 0 ]]; then
        printf "  %-20s %d countries\n" "GeoBan.............." "$geoban_total"
    fi

    local total_ipv4=$((black_v4 + feeds_ipv4_total))
    local total_ipv6=$((black_v6 + feeds_ipv6_total))
    local grand_total=$((total_ipv4 + total_ipv6))
    echo "  ─────────────────────────────────────"
    echo "  TOTAL:"
    printf "      %-16s %'d\n" "IPv4............" "$total_ipv4"
    printf "      %-16s %'d\n" "IPv6............" "$total_ipv6"
    printf "      %-16s %'d\n" "TOTAL..........." "$grand_total"
    echo ""

    # ─────────────────────────────────────────────────────────────────────
    # ACTIVITY HISTORY
    # ─────────────────────────────────────────────────────────────────────
    echo "ACTIVITY HISTORY"
    echo "───────────────────────────────────────────────────────────"
    printf "  %-20s %s\n" "New bans (period)..." "$total_bans"
    printf "  %-20s %s\n" "Unique IPs banned..." "$unique_ips"

    # Source breakdown (SINGLE SOURCE OF TRUTH via nftban_stats_ban_sources)
    local sources
    sources=$(nftban_stats_ban_sources "$since" "$until")
    if command -v jq &>/dev/null && [[ -n "$sources" ]]; then
        local login_bans portscan_bans ddos_bans manual feeds suricata_bans
        login_bans=$(echo "$sources" | jq -r '.login // 0')
        portscan_bans=$(echo "$sources" | jq -r '.portscan // 0')
        ddos_bans=$(echo "$sources" | jq -r '.ddos // 0')
        manual=$(echo "$sources" | jq -r '.manual // 0')
        feeds=$(echo "$sources" | jq -r '.feeds // 0')
        suricata_bans=$(echo "$sources" | jq -r '.suricata // 0')

        echo "  Modules:"
        printf "      %-14s %s\n" "Login..........." "$login_bans"
        printf "      %-14s %s\n" "Port Scan......." "$portscan_bans"
        printf "      %-14s %s\n" "DDoS............" "$ddos_bans"
        printf "      %-14s %s\n" "Manual.........." "$manual"
        printf "      %-14s %s\n" "Feeds..........." "$feeds"
        [[ "$suricata_bans" != "0" ]] && printf "      %-14s %s\n" "Suricata........" "$suricata_bans"

        if [[ "$login_bans" == "0" ]] && [[ "$portscan_bans" == "0" ]] && [[ "$ddos_bans" == "0" ]] && [[ "$manual" == "0" ]] && [[ "$feeds" == "0" ]] && [[ "$suricata_bans" == "0" ]]; then
            echo ""
            echo "  Summary: No new attacks detected this period."
            if [[ $total_black -gt 0 ]]; then
                echo "           Protection active: $total_black IPs blocked in firewall."
            fi
        fi
    fi
    echo ""

    # ─────────────────────────────────────────────────────────────────────
    # THREAT FEEDS
    # ─────────────────────────────────────────────────────────────────────
    if ! type -t nftban_feeds_discover_all >/dev/null 2>&1; then
        if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_feeds.sh" ]]; then
            source "${NFTBAN_LIB_DIR}/core/nftban_feeds.sh" 2>/dev/null || true
        fi
    fi

    if type -t nftban_feeds_discover_all >/dev/null 2>&1 && type -t nftban_feeds_get_property >/dev/null 2>&1; then
        echo "THREAT FEEDS"
        echo "───────────────────────────────────────────────────────────"

        local all_feeds
        all_feeds=$(nftban_feeds_discover_all 2>/dev/null || true)

        if [[ -n "$all_feeds" ]]; then
            local found_enabled=false
            for feed in $all_feeds; do
                local enabled
                enabled=$(nftban_feeds_get_property "$feed" "ENABLED" 2>/dev/null || echo "false")

                if [[ "$enabled" == "true" ]]; then
                    found_enabled=true
                    local feed_lower="${feed,,}"
                    local feed_file="${NFTBAN_FEEDS_STORAGE_DIR:-/var/lib/nftban/feeds}/${feed_lower}.txt"
                    if [[ -f "$feed_file" ]]; then
                        local count mtime
                        count=$(wc -l < "$feed_file" 2>/dev/null || true)
                        count=${count:-0}
                        mtime=$(date -r "$feed_file" '+%m-%d %H:%M' 2>/dev/null || echo "?")
                        local feed_padded
                        feed_padded=$(printf "%-20s" "$feed")
                        feed_padded="${feed_padded// /.}"
                        printf "  %s %s IPs (Updated: %s)\n" "$feed_padded" "$count" "$mtime"
                    else
                        local feed_padded
                        feed_padded=$(printf "%-20s" "$feed")
                        feed_padded="${feed_padded// /.}"
                        printf "  %s pending download\n" "$feed_padded"
                    fi
                fi
            done

            if [[ "$found_enabled" == "false" ]]; then
                echo "  (no feeds enabled)"
            fi
        else
            echo "  (no feeds configured)"
        fi
        echo ""
    fi

    # ─────────────────────────────────────────────────────────────────────
    # FIREWALL COUNTERS (nftables packet/byte counters since last reboot)
    # ─────────────────────────────────────────────────────────────────────
    local ipv4_pkt_count ipv6_pkt_count
    ipv4_pkt_count=$(nft list table "${NFTBAN_TABLE_IPV4}" 2>/dev/null | grep 'blacklist_ipv4.*counter' | grep -oP 'packets \K[0-9]+' || true)
    ipv4_pkt_count=${ipv4_pkt_count:-0}
    ipv6_pkt_count=$(nft list table "${NFTBAN_TABLE_IPV6}" 2>/dev/null | grep 'blacklist_ipv6.*counter' | grep -oP 'packets \K[0-9]+' || true)
    ipv6_pkt_count=${ipv6_pkt_count:-0}
    local total_pkt_blocked=$((ipv4_pkt_count + ipv6_pkt_count))

    if [[ $total_pkt_blocked -gt 0 ]]; then
        local formatted_ipv4 formatted_ipv6 formatted_total
        formatted_ipv4=$(printf "%'d" "$ipv4_pkt_count" 2>/dev/null || echo "$ipv4_pkt_count")
        formatted_ipv6=$(printf "%'d" "$ipv6_pkt_count" 2>/dev/null || echo "$ipv6_pkt_count")
        formatted_total=$(printf "%'d" "$total_pkt_blocked" 2>/dev/null || echo "$total_pkt_blocked")

        echo "FIREWALL COUNTERS (since last reboot)"
        echo "───────────────────────────────────────────────────────────"
        printf "  %-20s %s packets\n" "IPv4 dropped........" "$formatted_ipv4"
        printf "  %-20s %s packets\n" "IPv6 dropped........" "$formatted_ipv6"
        printf "  %-20s %s packets\n" "Total dropped......." "$formatted_total"
        echo "  (all sources: bans, feeds, geoban — resets on reboot)"
        echo ""
    fi

    # ─────────────────────────────────────────────────────────────────────
    # BANS BY MODULE (SINGLE SOURCE OF TRUTH from unified cache)
    # ─────────────────────────────────────────────────────────────────────
    echo "BANS BY MODULE"
    echo "───────────────────────────────────────────────────────────"

    local feeds_total=0 login_count=0 portscan_count=0 ddos_count=0 manual_count=0 suricata_count=0

    if [[ "$use_unified_cache" == "true" ]]; then
        # Read from unified cache (Single Source of Truth)
        login_count=$(nftban_stats_get_unified ".bans_by_source.login" "0")
        portscan_count=$(nftban_stats_get_unified ".bans_by_source.portscan" "0")
        ddos_count=$(nftban_stats_get_unified ".bans_by_source.ddos" "0")
        manual_count=$(nftban_stats_get_unified ".bans_by_source.manual" "0")
        suricata_count=$(nftban_stats_get_unified ".bans_by_source.suricata" "0")
        # Feeds total from feeds.ips_total (actual IPs loaded from feeds)
        feeds_total=$(nftban_stats_get_unified ".feeds.ips_total" "0")
    else
        # Fallback: Direct calculation
        local feeds_dir="${NFTBAN_DATA_DIR:-/var/lib/nftban}/feeds"
        local bans_log="${NFTBAN_LOG_DIR:-/var/log/nftban}/bans.log"

        # PERFORMANCE FIX: Use awk for O(n+m) instead of O(n*m) loop
        local counts_result
        counts_result=$(awk -F'|' '
            # First pass: Build IP->source map from bans.log (most recent entry wins)
            # Format: DATE|TIME|SOURCE|IP|COUNTRY|STATUS|REASON ($1|$2|$3|$4|$5|$6|$7)
            NR==FNR && NF>=4 {
                ip=$4; src=$3
                # Normalize source names
                if (src ~ /login|loginmon/) sources[ip]="login"
                else if (src ~ /portscan/) sources[ip]="portscan"
                else if (src ~ /ddos/) sources[ip]="ddos"
                else if (src ~ /manual|cli/) sources[ip]="manual"
                else if (src ~ /feed/) sources[ip]="feeds"
                else if (src ~ /suricata|ids/) sources[ip]="suricata"
                next
            }
            # Second pass: Count IPs from nftables by their source
            {
                while (match($0, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) {
                    ip = substr($0, RSTART, RLENGTH)
                    $0 = substr($0, RSTART + RLENGTH)
                    src = sources[ip]
                    if (src == "login") login++
                    else if (src == "portscan") portscan++
                    else if (src == "ddos") ddos++
                    else if (src == "manual") manual++
                    else if (src == "feeds") feeds++
                    else if (src == "suricata") suricata++
                }
            }
            END {
                printf "%d %d %d %d %d %d\n", login+0, portscan+0, ddos+0, manual+0, feeds+0, suricata+0
            }
        ' "$bans_log" <(timeout 10s nft list set "${NFTBAN_TABLE_IPV4}" blacklist_ipv4 2>/dev/null) 2>/dev/null)

        if [[ -n "$counts_result" ]]; then
            local counts_array
            IFS=' ' read -ra counts_array <<< "$counts_result"
            login_count="${counts_array[0]:-0}"
            portscan_count="${counts_array[1]:-0}"
            ddos_count="${counts_array[2]:-0}"
            manual_count="${counts_array[3]:-0}"
            local bans_log_feeds="${counts_array[4]:-0}"
            suricata_count="${counts_array[5]:-0}"
            feeds_total=$((feeds_total + bans_log_feeds))
        fi

        # FEEDS: Also count from enabled feed files
        if type -t nftban_feeds_discover_all >/dev/null 2>&1 && type -t nftban_feeds_get_property >/dev/null 2>&1; then
            local all_feeds
            all_feeds=$(nftban_feeds_discover_all 2>/dev/null || true)
            for feed in $all_feeds; do
                local enabled
                enabled=$(nftban_feeds_get_property "$feed" "ENABLED" 2>/dev/null || echo "false")
                if [[ "$enabled" == "true" ]]; then
                    local feed_lower="${feed,,}"
                    local feed_file="${feeds_dir}/${feed_lower}.txt"
                    if [[ -f "$feed_file" ]]; then
                        local count
                        count=$(grep -cE '^[0-9]' "$feed_file" 2>/dev/null) || count=0
                        feeds_total=$((feeds_total + count))
                    fi
                fi
            done
        fi
    fi

    # Display counts
    printf "  %-18s %'d IPs\n" "FEEDS" "$feeds_total"
    printf "  %-18s %'d IPs\n" "LOGIN" "$login_count"
    printf "  %-18s %'d IPs\n" "PORTSCAN" "$portscan_count"
    printf "  %-18s %'d IPs\n" "DDOS" "$ddos_count"
    printf "  %-18s %'d IPs\n" "MANUAL" "$manual_count"
    [[ "$suricata_count" -gt 0 ]] && printf "  %-18s %'d IPs\n" "SURICATA" "$suricata_count"
    echo ""

    # ─────────────────────────────────────────────────────────────────────
    # CURRENT ACTIVE BANS (sample)
    # ─────────────────────────────────────────────────────────────────────
    if [[ $total_black -gt 0 ]]; then
        echo "CURRENT ACTIVE BANS (sample)"
        echo "───────────────────────────────────────────────────────────"
        if timeout 10s nft list set "${NFTBAN_TABLE_IPV4}" blacklist_ipv4 &>/dev/null 2>&1; then
            timeout 10s nft list set "${NFTBAN_TABLE_IPV4}" blacklist_ipv4 2>/dev/null | \
                grep -oP '\d+\.\d+\.\d+\.\d+(/\d+)?' | \
                awk 'NR<=5 {print "  " $1}' 2>/dev/null || true
        fi
        echo ""
    fi

    # Top countries (if GeoIP enabled)
    if [[ "${STATS_GEOIP_ENABLED}" == "true" ]] && command -v nftban-geoip &>/dev/null && command -v jq &>/dev/null; then
        echo "TOP COUNTRIES"
        echo "───────────────────────────────────────────────────────────"
        nftban_stats_top_countries 5 "$since" "$until" | \
            jq -r '.[] | "  \(.country): \(.count)"' 2>/dev/null || true
        echo ""
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# =============================================================================
# RECENT ACTIVITY
# =============================================================================

nftban_stats_recent_activity() {
    # Show recent ban events
    # Usage: nftban_stats_recent_activity [limit]

    local limit="${1:-20}"

    if [[ ! -f "$NFTBAN_BAN_LOG" ]]; then
        echo "[WARN] No ban log available"
        return 0
    fi

    echo ""
    echo "Recent Activity (last ${limit})"
    echo "───────────────────────────────────────────────────────────────"
    echo ""

    # shellcheck disable=SC2034  # Structured log parsing - only some fields used
    tail -n "$limit" "$NFTBAN_BAN_LOG" | \
    while IFS='|' read -r timestamp id jail ip reason action timeout; do
        printf "%s | %-16s | %-12s | %s\n" \
            "$timestamp" "$ip" "$action" "$jail"
    done

    echo ""
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================

nftban_stats_export_json() {
    # Export statistics to JSON
    # Usage: nftban_stats_export_json [output_file] [since] [until]

    local output_file="${1:-/tmp/nftban-stats-$(date +%Y%m%d-%H%M%S).json}"
    local since="${2:-$(date -d '30 days ago' +%Y-%m-%d)}"
    local until="${3:-$(date +%Y-%m-%d)}"

    if type -t nftban_print_status >/dev/null 2>&1; then
        nftban_print_status "info" "Exporting statistics to JSON: $output_file"
    else
        echo "[INFO] Exporting to: $output_file"
    fi

    # Build JSON structure
    cat > "$output_file" <<EOF
{
  "schema_version": "1.0.0",
  "report": {
    "type": "export",
    "period": {
      "since": "${since}",
      "until": "${until}"
    },
    "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "hostname": "$(hostname)"
  },
  "summary": {
    "total_bans": $(nftban_stats_count_bans "$since" "$until"),
    "unique_ips": $(nftban_stats_count_unique_ips "$since" "$until"),
    "active_bans": $(nftban_stats_count_active_bans),
    "whitelist_total": $(nftban_stats_count_whitelist)
  },
  "ban_sources": $(nftban_stats_ban_sources "$since" "$until"),
  "top_sources": $(nftban_stats_top_sources 10 "$since" "$until"),
  "top_ips": $(nftban_stats_top_ips 20 "$since" "$until"),
  "top_countries": $(nftban_stats_top_countries 10 "$since" "$until"),
  "timeline": $(nftban_stats_timeline "$since 00:00:00" "$until 23:59:59" "day")
}
EOF

    if type -t nftban_print_status >/dev/null 2>&1; then
        nftban_print_status "success" "Statistics exported to: $output_file"
    else
        echo "[SUCCESS] Exported to: $output_file"
    fi

    echo "$output_file"
}

nftban_stats_export_csv() {
    # Export ban log to CSV
    # Usage: nftban_stats_export_csv [output_file] [since] [until]

    local output_file="${1:-/tmp/nftban-stats-$(date +%Y%m%d-%H%M%S).csv}"
    local since="${2:-$(date -d '30 days ago' +%Y-%m-%d)}"
    local until="${3:-$(date +%Y-%m-%d)}"

    if type -t nftban_print_status >/dev/null 2>&1; then
        nftban_print_status "info" "Exporting ban log to CSV: $output_file"
    else
        echo "[INFO] Exporting to: $output_file"
    fi

    if [[ ! -f "$NFTBAN_BAN_LOG" ]]; then
        echo "[ERROR] No ban log available"
        return 1
    fi

    # Create CSV header
    echo "Timestamp,ID,Source,IP,Reason,Action,Timeout" > "$output_file"

    # Export filtered data
    awk -F'|' -v since="$since" -v until="$until" \
        '$1 >= since && $1 <= until {print $0}' \
        "$NFTBAN_BAN_LOG" | \
    sed 's/|/,/g' >> "$output_file"

    local count
    count=$(($(wc -l < "$output_file") - 1))

    if type -t nftban_print_status >/dev/null 2>&1; then
        nftban_print_status "success" "Exported ${count} records to: $output_file"
    else
        echo "[SUCCESS] Exported ${count} records to: $output_file"
    fi

    echo "$output_file"
}

# =============================================================================
# MONITORING & ALERTS
# =============================================================================

nftban_stats_check_high_ban_rate() {
    # Check for high ban rate (alerts)
    # Usage: nftban_stats_check_high_ban_rate [threshold]
    # Returns: 0=alert triggered, 1=no alert

    local threshold="${1:-${STATS_ALERT_HIGH_BAN_RATE:-100}}"
    local since
    local until
    since="$(date -d '1 hour ago' +%Y-%m-%d\ %H:%M:%S)"
    until="$(date +%Y-%m-%d\ %H:%M:%S)"

    local recent_bans
    recent_bans=$(nftban_stats_count_bans "$since" "$until")

    if [[ $recent_bans -gt $threshold ]]; then
        if type -t nftban_print_status >/dev/null 2>&1; then
            nftban_print_status "warn" "High ban rate detected: ${recent_bans} bans in last hour (threshold: ${threshold})"
        else
            echo "[WARN] High ban rate: ${recent_bans} bans/hour (threshold: ${threshold})"
        fi
        return 0  # Alert triggered
    fi

    return 1  # No alert
}

nftban_stats_find_repeat_offenders() {
    # Identify repeat offenders
    # Usage: nftban_stats_find_repeat_offenders [threshold]
    # Returns: JSON array of IPs with multiple bans

    local threshold="${1:-${STATS_REPEAT_OFFENDER_THRESHOLD:-5}}"

    if [[ ! -f "$NFTBAN_BAN_LOG" ]]; then
        echo "[]"
        return 0
    fi

    awk -F'|' -v thresh="$threshold" '
    $6 == "BANNED" {ips[$4]++}
    END {
        printf "["
        first=1
        for (ip in ips) {
            if (ips[ip] >= thresh) {
                if (!first) printf ","
                printf "{\"ip\":\"%s\",\"count\":%d}", ip, ips[ip]
                first=0
            }
        }
        printf "]"
    }' "$NFTBAN_BAN_LOG"
}

# =============================================================================
# LOG CLEANUP & MAINTENANCE
# =============================================================================

nftban_stats_cleanup_logs() {
    # Rotate and cleanup old logs
    # Usage: nftban_stats_cleanup_logs [days]

    local days="${1:-${STATS_RETENTION_DAYS:-90}}"

    if type -t nftban_print_status >/dev/null 2>&1; then
        nftban_print_status "info" "Cleaning up logs older than ${days} days..."
    else
        echo "[INFO] Cleaning up logs older than ${days} days..."
    fi

    local cleaned=0

    # Rotate ban log if too large (>10MB)
    if [[ -f "$NFTBAN_BAN_LOG" ]]; then
        local size
        size=$(stat -c %s "$NFTBAN_BAN_LOG")
        if [[ $size -gt 10485760 ]]; then  # 10MB
            local backup
            backup="${NFTBAN_BAN_LOG}.$(date +%Y%m%d-%H%M%S)"
            mv "$NFTBAN_BAN_LOG" "$backup"
            gzip "$backup" 2>/dev/null || true
            touch "$NFTBAN_BAN_LOG"
            chown nftban:nftban "$NFTBAN_BAN_LOG" 2>/dev/null || true
            chmod 640 "$NFTBAN_BAN_LOG" 2>/dev/null || true

            if type -t nftban_print_status >/dev/null 2>&1; then
                nftban_print_status "success" "Rotated ban log: ${backup}.gz"
            else
                echo "[SUCCESS] Rotated: ${backup}.gz"
            fi
            cleaned=$((cleaned + 1)) || true
        fi
    fi

    # Delete old compressed logs
    find "$(dirname "$NFTBAN_BAN_LOG")" -name "*.log.gz" -mtime +"${days}" -type f -delete 2>/dev/null || true

    # Delete old snapshots
    find "$NFTBAN_STATS_SNAPSHOTS_DIR" -type f -mtime +"${days}" -delete 2>/dev/null || true

    if type -t nftban_print_status >/dev/null 2>&1; then
        nftban_print_status "success" "Log cleanup complete"
    else
        echo "[SUCCESS] Log cleanup complete"
    fi
}

# =============================================================================
# SNAPSHOTS (for trending)
# =============================================================================

nftban_stats_create_snapshot() {
    # Create hourly snapshot for trending
    # Usage: nftban_stats_create_snapshot

    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local snapshot_file="${NFTBAN_STATS_SNAPSHOTS_DIR}/snapshot-${timestamp}.json"

    local since
    local until
    since="$(date -d '1 hour ago' +%Y-%m-%d\ %H:%M:%S)"
    until="$(date +%Y-%m-%d\ %H:%M:%S)"

    nftban_stats_export_json "$snapshot_file" "$since" "$until" &>/dev/null

    echo "$snapshot_file"
}

# =============================================================================
# TREND ANALYSIS (7-day rolling history)
# =============================================================================

# Storage paths for trend data
readonly NFTBAN_TREND_DIR="${NFTBAN_DATA_DIR:-/var/lib/nftban}/stats"
readonly NFTBAN_TREND_FILE="${NFTBAN_TREND_DIR}/trend_hourly.json"
readonly NFTBAN_TREND_RETENTION=168  # 7 days in hours

nftban_stats_trend_collect() {
    # Collect current hour statistics and append to trend history
    # Called hourly by maintenance timer
    # Usage: nftban_stats_trend_collect

    mkdir -p "$NFTBAN_TREND_DIR" 2>/dev/null || true

    # shellcheck disable=SC2034  # Reserved for time range queries
    local hour_start hour_end
    # shellcheck disable=SC2034  # Reserved for time range queries
    hour_end=$(date +%Y-%m-%dT%H:%M:%SZ)

    # Count bans/unbans in current hour
    local today bans unbans
    today=$(date +%Y-%m-%d)
    local hour_pattern
    hour_pattern="^${today}|$(date +%H):"

    if [[ -f "$NFTBAN_BAN_LOG" ]]; then
        bans=$(grep -c "BANNED$" "$NFTBAN_BAN_LOG" 2>/dev/null | grep -cE "$hour_pattern" 2>/dev/null) || bans=0
        unbans=$(grep -c "UNBANNED$" "$NFTBAN_BAN_LOG" 2>/dev/null | grep -cE "$hour_pattern" 2>/dev/null) || unbans=0

        # Simpler: count today's bans in current hour
        bans=$(awk -F'|' -v h="$(date +%H)" '$1 ~ /^[0-9]/ && $2 ~ "^"h":" && $6=="BANNED" {c++} END {print c+0}' "$NFTBAN_BAN_LOG" 2>/dev/null) || bans=0
        unbans=$(awk -F'|' -v h="$(date +%H)" '$1 ~ /^[0-9]/ && $2 ~ "^"h":" && $6=="UNBANNED" {c++} END {print c+0}' "$NFTBAN_BAN_LOG" 2>/dev/null) || unbans=0
    else
        bans=0
        unbans=0
    fi

    # Count by source
    local login_c=0 portscan_c=0 feeds_c=0 ddos_c=0 manual_c=0
    if [[ -f "$NFTBAN_BAN_LOG" ]]; then
        login_c=$(awk -F'|' -v h="$(date +%H)" '$2 ~ "^"h":" && $3=="login" && $6=="BANNED" {c++} END {print c+0}' "$NFTBAN_BAN_LOG" 2>/dev/null) || login_c=0
        portscan_c=$(awk -F'|' -v h="$(date +%H)" '$2 ~ "^"h":" && $3=="portscan" && $6=="BANNED" {c++} END {print c+0}' "$NFTBAN_BAN_LOG" 2>/dev/null) || portscan_c=0
        feeds_c=$(awk -F'|' -v h="$(date +%H)" '$2 ~ "^"h":" && $3=="feeds" && $6=="BANNED" {c++} END {print c+0}' "$NFTBAN_BAN_LOG" 2>/dev/null) || feeds_c=0
        ddos_c=$(awk -F'|' -v h="$(date +%H)" '$2 ~ "^"h":" && $3=="ddos" && $6=="BANNED" {c++} END {print c+0}' "$NFTBAN_BAN_LOG" 2>/dev/null) || ddos_c=0
        manual_c=$(awk -F'|' -v h="$(date +%H)" '$2 ~ "^"h":" && $3=="manual" && $6=="BANNED" {c++} END {print c+0}' "$NFTBAN_BAN_LOG" 2>/dev/null) || manual_c=0
    fi

    # Create new sample JSON
    local sample
    sample=$(cat <<EOF
{"hour":"${hour_start}","bans":${bans},"unbans":${unbans},"sources":{"login":${login_c},"portscan":${portscan_c},"feeds":${feeds_c},"ddos":${ddos_c},"manual":${manual_c}}}
EOF
)

    # Load existing data, append, and enforce retention
    local temp_file="${NFTBAN_TREND_FILE}.tmp"

    if [[ -f "$NFTBAN_TREND_FILE" ]] && command -v jq &>/dev/null; then
        # Append and trim to retention limit
        jq --argjson new "$sample" --argjson max "$NFTBAN_TREND_RETENTION" \
            '.samples += [$new] | .samples = .samples[-$max:]' \
            "$NFTBAN_TREND_FILE" > "$temp_file" 2>/dev/null && \
            mv "$temp_file" "$NFTBAN_TREND_FILE"
    else
        # Initialize new file
        echo "{\"samples\":[$sample],\"retention_hours\":$NFTBAN_TREND_RETENTION}" > "$NFTBAN_TREND_FILE"
    fi

    chown nftban:nftban "$NFTBAN_TREND_FILE" 2>/dev/null || true
    chmod 640 "$NFTBAN_TREND_FILE" 2>/dev/null || true
}

nftban_stats_trend_load() {
    # Load trend history
    # Usage: nftban_stats_trend_load
    # Returns: JSON array of samples

    if [[ -f "$NFTBAN_TREND_FILE" ]] && command -v jq &>/dev/null; then
        jq -r '.samples' "$NFTBAN_TREND_FILE" 2>/dev/null
    else
        echo "[]"
    fi
}

nftban_stats_trend_averages() {
    # Calculate averages from trend data
    # Usage: nftban_stats_trend_averages
    # Returns: JSON with avg, min, max, stddev

    if [[ ! -f "$NFTBAN_TREND_FILE" ]] || ! command -v jq &>/dev/null; then
        echo '{"avg_hourly":0,"avg_daily":0,"min":0,"max":0,"stddev":0,"samples":0}'
        return
    fi

    jq '
        .samples as $s |
        ($s | length) as $n |
        if $n == 0 then
            {"avg_hourly":0,"avg_daily":0,"min":0,"max":0,"stddev":0,"samples":0}
        else
            ($s | map(.bans) | add / $n) as $avg |
            ($s | map(.bans) | min) as $min |
            ($s | map(.bans) | max) as $max |
            ($s | map((.bans - $avg) * (.bans - $avg)) | add / $n | sqrt) as $stddev |
            {
                "avg_hourly": ($avg | . * 10 | floor / 10),
                "avg_daily": ($avg * 24 | floor),
                "min": $min,
                "max": $max,
                "stddev": ($stddev | . * 10 | floor / 10),
                "samples": $n
            }
        end
    ' "$NFTBAN_TREND_FILE" 2>/dev/null || echo '{"avg_hourly":0,"avg_daily":0,"min":0,"max":0,"stddev":0,"samples":0}'
}

nftban_stats_trend_thresholds() {
    # Calculate suggested thresholds based on stddev
    # Usage: nftban_stats_trend_thresholds
    # Returns: JSON with warning and critical thresholds

    local stats
    stats=$(nftban_stats_trend_averages)

    if ! command -v jq &>/dev/null; then
        echo '{"warning":10,"critical":25}'
        return
    fi

    echo "$stats" | jq '
        (.avg_hourly + (1.5 * .stddev)) as $warn |
        (.avg_hourly + (3 * .stddev)) as $crit |
        {
            "warning": ([($warn | floor), 10] | max),
            "critical": ([($crit | floor), 25] | max),
            "based_on_samples": .samples
        }
    ' 2>/dev/null || echo '{"warning":10,"critical":25,"based_on_samples":0}'
}

nftban_stats_trend_compare() {
    # Compare current period vs previous periods
    # Usage: nftban_stats_trend_compare
    # Returns: JSON with vs_yesterday and vs_last_week percentages

    if [[ ! -f "$NFTBAN_TREND_FILE" ]] || ! command -v jq &>/dev/null; then
        echo '{"vs_yesterday":0,"vs_last_week":0}'
        return
    fi

    jq '
        .samples as $s |
        ($s | length) as $n |
        if $n < 48 then
            {"vs_yesterday":0,"vs_last_week":0,"insufficient_data":true}
        else
            # Last 24 hours
            ($s[-24:] | map(.bans) | add) as $today |
            # Previous 24 hours (24-48 hours ago)
            ($s[-48:-24] | map(.bans) | add) as $yesterday |
            # Calculate week comparison if enough data
            (if $n >= 168 then ($s[-168:-144] | map(.bans) | add) else 0 end) as $last_week |
            {
                "today_total": $today,
                "yesterday_total": $yesterday,
                "vs_yesterday": (if $yesterday > 0 then ((($today - $yesterday) / $yesterday * 100) | . * 10 | floor / 10) else 0 end),
                "vs_last_week": (if $last_week > 0 and $n >= 168 then ((($today - $last_week) / $last_week * 100) | . * 10 | floor / 10) else null end)
            }
        end
    ' "$NFTBAN_TREND_FILE" 2>/dev/null || echo '{"vs_yesterday":0,"vs_last_week":0}'
}

nftban_stats_trend_top_sources() {
    # Get source breakdown for trend period
    # Usage: nftban_stats_trend_top_sources
    # Returns: JSON with source totals and percentages

    if [[ ! -f "$NFTBAN_TREND_FILE" ]] || ! command -v jq &>/dev/null; then
        echo '[]'
        return
    fi

    jq '
        .samples | map(.sources) |
        reduce .[] as $s ({"login":0,"portscan":0,"feeds":0,"ddos":0,"manual":0};
            . + {
                "login": (.login + $s.login),
                "portscan": (.portscan + $s.portscan),
                "feeds": (.feeds + $s.feeds),
                "ddos": (.ddos + $s.ddos),
                "manual": (.manual + $s.manual)
            }
        ) |
        . as $totals |
        ($totals | add) as $grand_total |
        to_entries | map({
            "source": .key,
            "count": .value,
            "percent": (if $grand_total > 0 then (.value / $grand_total * 100 | . * 10 | floor / 10) else 0 end)
        }) | sort_by(-.count)
    ' "$NFTBAN_TREND_FILE" 2>/dev/null || echo '[]'
}

nftban_stats_trend_display() {
    # Display formatted trend analysis
    # Usage: nftban_stats_trend_display [--json]

    local json_mode=0
    [[ "${1:-}" == "--json" ]] && json_mode=1

    if [[ $json_mode -eq 1 ]]; then
        # JSON output
        local averages compare sources thresholds hourly_data
        averages=$(nftban_stats_trend_averages)
        compare=$(nftban_stats_trend_compare)
        sources=$(nftban_stats_trend_top_sources)
        thresholds=$(nftban_stats_trend_thresholds)

        # Get hourly data points for charting (last 168 hours / 7 days)
        if [[ -f "$NFTBAN_TREND_FILE" ]] && command -v jq &>/dev/null; then
            hourly_data=$(jq '[.samples[] | {hour: .hour, bans: .bans, sources: .sources}]' "$NFTBAN_TREND_FILE" 2>/dev/null || echo '[]')
        else
            hourly_data='[]'
        fi

        jq -n --argjson avg "$averages" --argjson cmp "$compare" \
              --argjson src "$sources" --argjson thr "$thresholds" \
              --argjson hourly "$hourly_data" \
            '{averages: $avg, comparison: $cmp, sources: $src, thresholds: $thr, hourly: $hourly}'
        return
    fi

    # Text output
    echo ""
    echo "BAN STATISTICS TREND (Last 7 Days)"
    echo "══════════════════════════════════════════════════════════════"
    echo ""

    # Get data
    local avg_data compare_data sources_data threshold_data
    avg_data=$(nftban_stats_trend_averages)
    compare_data=$(nftban_stats_trend_compare)
    sources_data=$(nftban_stats_trend_top_sources)
    threshold_data=$(nftban_stats_trend_thresholds)

    if ! command -v jq &>/dev/null; then
        echo "[WARN] jq not installed - trend analysis requires jq"
        return 1
    fi

    local samples avg_h avg_d min_v max_v
    samples=$(echo "$avg_data" | jq -r '.samples')
    avg_h=$(echo "$avg_data" | jq -r '.avg_hourly')
    avg_d=$(echo "$avg_data" | jq -r '.avg_daily')
    min_v=$(echo "$avg_data" | jq -r '.min')
    max_v=$(echo "$avg_data" | jq -r '.max')

    if [[ "$samples" == "0" ]]; then
        echo "  No trend data available yet."
        echo "  Trend data is collected every 15 minutes by the maintenance timer."
        echo ""
        echo "  Enable timer: nftban timers enable nftban-maintenance.timer"
        return 0
    fi

    echo "AVERAGES (${samples} samples)"
    echo "───────────────────────────────────────────────────────────────"
    printf "  %-20s %s (min: %s, max: %s)\n" "Bans per hour......." "$avg_h" "$min_v" "$max_v"
    printf "  %-20s %s\n" "Bans per day........" "$avg_d"
    echo ""

    # Suggested thresholds
    local warn_t crit_t
    warn_t=$(echo "$threshold_data" | jq -r '.warning')
    crit_t=$(echo "$threshold_data" | jq -r '.critical')

    echo "SUGGESTED THRESHOLDS (based on stddev)"
    echo "───────────────────────────────────────────────────────────────"
    printf "  %-20s %s/hour\n" "Warning threshold..." "$warn_t"
    printf "  %-20s %s/hour\n" "Critical threshold.." "$crit_t"
    echo ""

    # Trend direction
    local vs_yest vs_week today_t yest_t
    vs_yest=$(echo "$compare_data" | jq -r '.vs_yesterday')
    vs_week=$(echo "$compare_data" | jq -r '.vs_last_week // "N/A"')
    today_t=$(echo "$compare_data" | jq -r '.today_total // 0')
    yest_t=$(echo "$compare_data" | jq -r '.yesterday_total // 0')

    echo "TREND DIRECTION"
    echo "───────────────────────────────────────────────────────────────"

    local arrow_yest="→"
    if [[ "$vs_yest" != "0" ]] && [[ "$vs_yest" != "null" ]]; then
        if (( $(echo "$vs_yest > 0" | bc -l 2>/dev/null || echo 0) )); then
            arrow_yest="↑"
        elif (( $(echo "$vs_yest < 0" | bc -l 2>/dev/null || echo 0) )); then
            arrow_yest="↓"
        fi
    fi
    printf "  %-20s %s %s%% (%s → %s)\n" "vs Yesterday........" "$arrow_yest" "$vs_yest" "$yest_t" "$today_t"

    if [[ "$vs_week" != "null" ]] && [[ "$vs_week" != "N/A" ]]; then
        local arrow_week="→"
        if (( $(echo "$vs_week > 0" | bc -l 2>/dev/null || echo 0) )); then
            arrow_week="↑"
        elif (( $(echo "$vs_week < 0" | bc -l 2>/dev/null || echo 0) )); then
            arrow_week="↓"
        fi
        printf "  %-20s %s %s%%\n" "vs Last Week........" "$arrow_week" "$vs_week"
    else
        printf "  %-20s %s\n" "vs Last Week........" "(need 7 days of data)"
    fi
    echo ""

    # Top sources
    echo "TOP SOURCES (7-day)"
    echo "───────────────────────────────────────────────────────────────"
    echo "$sources_data" | jq -r '.[] | select(.count > 0) | "  \(.source)............ \(.percent)% (\(.count) bans)"' 2>/dev/null || true
    echo ""
    echo "══════════════════════════════════════════════════════════════"
}

# =============================================================================
# MODULE INITIALIZATION
# =============================================================================

# Module loaded
if type -t nftban_print_status >/dev/null 2>&1; then
    nftban_print_status "debug" "Stats module loaded"
fi
