#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Statistics Data Collection
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Core metrics collection functions extracted from nftban_stats.sh
#
# meta:name="nftban_stats_collect"
# meta:type="core"
# meta:header="Statistics Data Collection"
# meta:version="1.49.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# **Description & Purpose**
# meta:description="Core metrics collection functions extracted from nftban_stats.sh"
# meta:input="Ban logs, nftables sets, unified cache"
# meta:output="JSON metrics data"
#
# **Inventory & Requirements**
# meta:depends="nftban_stats.sh"
# meta:inventory.files="/usr/lib/nftban/core/nftban_stats_collect.sh"
# meta:inventory.binaries="nft"
# meta:inventory.env_vars="NFTBAN_BAN_LOG,NFTBAN_STATS_CACHE_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units="none"
# meta:inventory.network="none"
# meta:inventory.privileges="root:read-nftables,read-logs"
#
# meta:created_date="2026-02-27"
# meta:updated_date="2026-02-27"
# =============================================================================

# Enhanced strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_STATS_COLLECT_LOADED:-}" ]] && return 0
readonly NFTBAN_STATS_COLLECT_LOADED=1

# Load shared feed-counter helpers (v1.167 PR-1: single source of truth for
# the feed IP-total surface — BUG-CtCount-feeds). Best-effort; helpers degrade
# to 0 if the feeds-discovery lib is unreachable.
if ! declare -f nftban_feed_ips_total >/dev/null 2>&1; then
    _nfc_lib="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_feed_counters.sh"
    [[ -f "$_nfc_lib" ]] || _nfc_lib="$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")/lib/nftban_feed_counters.sh"
    if [[ -f "$_nfc_lib" ]]; then
        # shellcheck source=/usr/lib/nftban/lib/nftban_feed_counters.sh
        source "$_nfc_lib" 2>/dev/null || true
    fi
    unset _nfc_lib
fi

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
    count_v4=$(nft list table ip nftban 2>/dev/null | grep -c "^\s*\(accept\|drop\|reject\|counter\|log\)" || true)
    count_v4=${count_v4:-0}
    count_v6=$(nft list table ip6 nftban 2>/dev/null | grep -c "^\s*\(accept\|drop\|reject\|counter\|log\)" || true)
    count_v6=${count_v6:-0}
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
            # Feeds: use actual loaded IPs (feeds are bulk-loaded, not logged in bans.log)
            local feeds_loaded
            feeds_loaded=$(nftban_stats_get_unified ".feeds.ips_total" "0")
            [[ "$feeds_loaded" -gt 0 ]] 2>/dev/null && feeds="$feeds_loaded"
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
            # Feeds: use actual loaded IPs (feeds are bulk-loaded, not logged in bans.log)
            local feeds_loaded
            feeds_loaded=$(nftban_stats_get_unified ".feeds.ips_total" "0")
            [[ "$feeds_loaded" -gt 0 ]] 2>/dev/null && feeds="$feeds_loaded"
            echo "{\"login\":$login,\"portscan\":$portscan,\"ddos\":$ddos,\"manual\":$manual,\"feeds\":$feeds,\"suricata\":$suricata}"
            return 0
        fi
    fi

    # Fallback: Parse log file for custom date ranges
    if [[ ! -f "$NFTBAN_BAN_LOG" ]]; then
        # No ban log — still check for loaded feed IPs.
        # v1.167 PR-1: feed IP-total unified via nftban_feed_ips_total()
        # (BUG-CtCount-feeds). Replaces the prior cat-all `wc -l`, which summed
        # EVERY .txt (incl. disabled/orphan feeds); the helper sums only ENABLED
        # feed files (canonical v1.141 PR-C resolution), matching the other
        # feed IP surfaces.
        local feed_total=0
        if declare -f nftban_feed_ips_total >/dev/null 2>&1; then
            feed_total=$(nftban_feed_ips_total)
        else
            local feeds_dir="${NFTBAN_DATA_DIR:-/var/lib/nftban}/feeds"
            if [[ -d "$feeds_dir" ]]; then
                # shellcheck disable=SC2312  # cat in subshell is fine here
                feed_total=$(cat "$feeds_dir"/*.txt 2>/dev/null | wc -l || true)
            fi
        fi
        feed_total=${feed_total:-0}
        echo "{\"login\":0,\"portscan\":0,\"ddos\":0,\"manual\":0,\"feeds\":$feed_total,\"suricata\":0}"
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

    # Feeds: override with actual loaded IPs (feeds are bulk-loaded, not logged in bans.log)
    if command -v jq &>/dev/null && [[ -n "$result" ]]; then
        local log_feeds
        log_feeds=$(echo "$result" | jq -r '.feeds // 0')
        if [[ "$log_feeds" == "0" ]]; then
            # v1.167 PR-1: feed IP-total unified via nftban_feed_ips_total()
            # (BUG-CtCount-feeds) — same enabled-only resolution as above.
            local feed_count=0
            if declare -f nftban_feed_ips_total >/dev/null 2>&1; then
                feed_count=$(nftban_feed_ips_total)
            else
                local feeds_dir="${NFTBAN_DATA_DIR:-/var/lib/nftban}/feeds"
                if [[ -d "$feeds_dir" ]]; then
                    # shellcheck disable=SC2312  # cat in subshell is fine here
                    feed_count=$(cat "$feeds_dir"/*.txt 2>/dev/null | wc -l || true)
                fi
            fi
            feed_count=${feed_count:-0}
            if [[ "$feed_count" -gt 0 ]]; then
                result=$(echo "$result" | jq -c ".feeds = $feed_count")
            fi
        fi
    fi

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
            awk 'BEGIN{printf "["; n=0}
                 $1 > 0 { if (n++) printf ","; printf "{\"name\":\"%s\",\"count\":%d}", $2, $1 }
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
