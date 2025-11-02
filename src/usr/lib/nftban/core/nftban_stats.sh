#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.10.0 - Statistics & Metrics Core Engine
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Comprehensive statistics collection, analysis, and reporting
#
# meta:name=nftban_stats
# meta:type=core
# meta:header=Statistics & Metrics Engine
# meta:version=0.10.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Production-grade stats engine with real-time metrics and analytics
# meta:input=System metrics, ban data, and firewall statistics
# meta:output=Dashboards, analytics reports, and statistical summaries
#
# **Inventory & Requirements**
# meta:depends=nft,sqlite3,nftban_geoip_go.sh
#
# meta:created_date=2025-10-28
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

# Load configuration (conf.d/stats.conf will be sourced by main CLI)
readonly NFTBAN_STATS_DB="${STATS_DB_DIR:-/var/lib/nftban/metrics}/metrics.db"
readonly NFTBAN_STATS_CACHE_DIR="${STATS_CACHE_DIR:-/var/cache/nftban/stats}"
readonly NFTBAN_STATS_SNAPSHOTS_DIR="${STATS_SNAPSHOTS_DIR:-/var/lib/nftban/snapshots}"
readonly NFTBAN_BAN_LOG="${STATS_BAN_LOG:-/var/log/nftban/ban.log}"
readonly NFTBAN_STATS_LOG="${STATS_LOG_FILE:-/var/log/nftban/stats.log}"

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

    # Check if cache is fresh
    local cache_age=$(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0) ))
    if [[ $cache_age -lt ${STATS_CACHE_TTL} ]]; then
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
# CORE METRICS COLLECTION
# =============================================================================

nftban_stats_count_bans() {
    # Count total bans in time window
    # Usage: nftban_stats_count_bans [since] [until]
    # Args: since=YYYY-MM-DD (default: 1970-01-01)
    #       until=YYYY-MM-DD (default: today)
    # Returns: Number of bans

    local since="${1:-1970-01-01}"
    local until="${2:-$(date +%Y-%m-%d)}"

    if [[ ! -f "$NFTBAN_BAN_LOG" ]]; then
        echo "0"
        return 0
    fi

    # Try cache first
    local cache_key="bans_${since}_${until}"
    if nftban_stats_get_cache "$cache_key"; then
        return 0
    fi

    # Count bans
    local count
    count=$(awk -F'|' -v since="$since" -v until="$until" \
        '$1 >= since && $1 <= until && $6 == "BANNED" {count++} END {print count+0}' \
        "$NFTBAN_BAN_LOG")

    # Cache result
    nftban_stats_set_cache "$cache_key" "$count"

    echo "$count"
}

nftban_stats_count_unique_ips() {
    # Count unique IPs banned in time window
    # Usage: nftban_stats_count_unique_ips [since] [until]

    local since="${1:-1970-01-01}"
    local until="${2:-$(date +%Y-%m-%d)}"

    if [[ ! -f "$NFTBAN_BAN_LOG" ]]; then
        echo "0"
        return 0
    fi

    # Try cache
    local cache_key="unique_ips_${since}_${until}"
    if nftban_stats_get_cache "$cache_key"; then
        return 0
    fi

    # Count unique IPs
    local count
    count=$(awk -F'|' -v since="$since" -v until="$until" \
        '$1 >= since && $1 <= until && $6 == "BANNED" {ips[$4]=1} END {print length(ips)}' \
        "$NFTBAN_BAN_LOG")

    nftban_stats_set_cache "$cache_key" "$count"
    echo "$count"
}

nftban_stats_count_active_bans() {
    # Count currently active bans in nftables (FIXED for unified table structure)
    # Usage: nftban_stats_count_active_bans
    # Returns: Number of active bans

    local total=0

    # Count temp_ban_v4 (NEW unified structure)
    if nft list set inet nftban_runtime temp_ban_v4 &>/dev/null 2>&1; then
        local temp_v4
        temp_v4=$(nft list set inet nftban_runtime temp_ban_v4 2>/dev/null | grep -c 'timeout' 2>/dev/null)
        temp_v4=${temp_v4:-0}
        total=$((total + temp_v4))
    fi

    # Count temp_ban_v6 (NEW unified structure)
    if nft list set inet nftban_runtime temp_ban_v6 &>/dev/null 2>&1; then
        local temp_v6
        temp_v6=$(nft list set inet nftban_runtime temp_ban_v6 2>/dev/null | grep -c 'timeout' 2>/dev/null)
        temp_v6=${temp_v6:-0}
        total=$((total + temp_v6))
    fi

    # Count permanent blacklist_v4 (NEW unified structure)
    if nft list set inet nftban_main blacklist_v4 &>/dev/null 2>&1; then
        local black_v4
        black_v4=$(nft list set inet nftban_main blacklist_v4 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+' | wc -l 2>/dev/null)
        black_v4=${black_v4:-0}
        total=$((total + black_v4))
    fi

    # Count permanent blacklist_v6 (NEW unified structure)
    if nft list set inet nftban_main blacklist_v6 &>/dev/null 2>&1; then
        local black_v6
        black_v6=$(nft list set inet nftban_main blacklist_v6 2>/dev/null | grep -c '::' 2>/dev/null)
        black_v6=${black_v6:-0}
        total=$((total + black_v6))
    fi

    echo "$total"
}

nftban_stats_count_whitelist() {
    # Count whitelist entries from nftables (FIXED to read from nftables, not files)
    # Usage: nftban_stats_count_whitelist
    # Returns: Total whitelist entries

    local total=0

    # Read from nftables whitelist_v4 set (NEW unified structure)
    if nft list set inet nftban_main whitelist_v4 &>/dev/null 2>&1; then
        local wl_v4
        wl_v4=$(nft list set inet nftban_main whitelist_v4 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+' | wc -l 2>/dev/null)
        wl_v4=${wl_v4:-0}
        total=$((total + wl_v4))
    fi

    # Read from nftables whitelist_v6 set (NEW unified structure)
    if nft list set inet nftban_main whitelist_v6 &>/dev/null 2>&1; then
        local wl_v6
        wl_v6=$(nft list set inet nftban_main whitelist_v6 2>/dev/null | grep -c '::' 2>/dev/null)
        wl_v6=${wl_v6:-0}
        total=$((total + wl_v6))
    fi

    echo "$total"
}

# =============================================================================
# BAN SOURCE ANALYSIS
# =============================================================================

nftban_stats_ban_sources() {
    # Get ban breakdown by source (fail2ban, manual, feeds)
    # Usage: nftban_stats_ban_sources [since] [until]
    # Returns: JSON {"fail2ban":N,"manual":N,"feeds":N}

    local since="${1:-1970-01-01}"
    local until="${2:-$(date +%Y-%m-%d)}"

    if [[ ! -f "$NFTBAN_BAN_LOG" ]]; then
        echo "{\"fail2ban\":0,\"manual\":0,\"feeds\":0}"
        return 0
    fi

    # Try cache
    local cache_key="sources_${since}_${until}"
    if nftban_stats_get_cache "$cache_key"; then
        return 0
    fi

    # Analyze sources
    local result
    result=$(awk -F'|' -v since="$since" -v until="$until" '
    BEGIN {fail2ban=0; manual=0; feeds=0}
    $1 >= since && $1 <= until && $6 == "BANNED" {
        if ($3 ~ /^fail2ban/) fail2ban++
        else if ($3 == "manual" || $3 == "user") manual++
        else if ($3 ~ /feed/) feeds++
    }
    END {
        printf "{\"fail2ban\":%d,\"manual\":%d,\"feeds\":%d}", fail2ban, manual, feeds
    }' "$NFTBAN_BAN_LOG")

    nftban_stats_set_cache "$cache_key" "$result"
    echo "$result"
}

nftban_stats_top_jails() {
    # Get top Fail2Ban jails
    # Usage: nftban_stats_top_jails [limit] [since] [until]
    # Returns: JSON array [{"name":"jail","count":N},...]

    local limit="${1:-${STATS_TOP_N}}"
    local since="${2:-1970-01-01}"
    local until="${3:-$(date +%Y-%m-%d)}"

    if [[ ! -f "$NFTBAN_BAN_LOG" ]]; then
        echo "[]"
        return 0
    fi

    awk -F'|' -v since="$since" -v until="$until" -v limit="$limit" \
        '$1 >= since && $1 <= until && $6 == "BANNED" {jails[$3]++}
         END {
             for (j in jails) print jails[j], j
         }' \
        "$NFTBAN_BAN_LOG" | \
    sort -rn | head -n "$limit" | \
    awk 'BEGIN{printf "["}
         NR>1{printf ","}
         {printf "{\"name\":\"%s\",\"count\":%d}", $2, $1}
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

    local result="["
    local first=true

    awk -F'|' -v since="$since" -v until="$until" \
        '$1 >= since && $1 <= until && $6 == "BANNED" {ips[$4]++}
         END {for (ip in ips) print ips[ip], ip}' \
        "$NFTBAN_BAN_LOG" | \
    sort -rn | head -n "$limit" | \
    while read -r count ip; do
        local country="--"
        local first_seen
        local last_seen

        # Get first and last seen
        first_seen=$(grep "|${ip}|" "$NFTBAN_BAN_LOG" | head -1 | cut -d'|' -f1)
        last_seen=$(grep "|${ip}|" "$NFTBAN_BAN_LOG" | tail -1 | cut -d'|' -f1)

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
    done

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

    local limit="${1:-${STATS_TOP_N}}"
    local since="${2:-1970-01-01}"
    local until="${3:-$(date +%Y-%m-%d)}"

    if [[ "${STATS_GEOIP_ENABLED}" != "true" ]] || ! command -v nftban-geoip &>/dev/null; then
        echo "[]"
        return 0
    fi

    if [[ ! -f "$NFTBAN_BAN_LOG" ]]; then
        echo "[]"
        return 0
    fi

    # Extract banned IPs and lookup countries
    local temp_file
    temp_file=$(mktemp)

    awk -F'|' -v since="$since" -v until="$until" \
        '$1 >= since && $1 <= until && $6 == "BANNED" {print $4}' \
        "$NFTBAN_BAN_LOG" | \
    while read -r ip; do
        nftban-geoip lookup "$ip" 2>/dev/null | cut -d'/' -f1 || echo "Unknown"
    done | \
    sort | uniq -c | sort -rn | head -n "$limit" > "$temp_file"

    # Convert to JSON
    awk 'BEGIN{printf "["}
         NR>1{printf ","}
         {printf "{\"country\":\"%s\",\"count\":%d}", $2, $1}
         END{printf "]"}' "$temp_file"

    rm -f "$temp_file"
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
    # Generate comprehensive terminal dashboard
    # Usage: nftban_stats_generate_dashboard [since] [until]

    local since="${1:-$(date -d '24 hours ago' +%Y-%m-%d)}"
    local until="${2:-$(date +%Y-%m-%d)}"

    # Collect metrics
    local total_bans
    local unique_ips
    local active_bans
    local whitelist_count

    total_bans=$(nftban_stats_count_bans "$since" "$until")
    unique_ips=$(nftban_stats_count_unique_ips "$since" "$until")
    active_bans=$(nftban_stats_count_active_bans)
    whitelist_count=$(nftban_stats_count_whitelist)

    # Display header (use output module if available)
    echo ""
    if type -t nftban_render_separator >/dev/null 2>&1; then
        nftban_render_separator "═"
        echo -e "${NFTBAN_COLOR_BOLD:-}${NFTBAN_COLOR_CYAN:-}  NFTBan Statistics Dashboard${NFTBAN_COLOR_RESET:-}"
        nftban_render_separator "═"
    else
        echo "═══════════════════════════════════════════════════════════════"
        echo "  NFTBan Statistics Dashboard"
        echo "═══════════════════════════════════════════════════════════════"
    fi
    echo ""

    # System info
    echo "[SYSTEM]"
    echo "  Hostname: $(hostname)"
    echo "  Period: ${since} to ${until}"
    echo "  Generated: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""

    # Summary metrics
    echo "[SUMMARY]"
    echo "  Total Bans: ${total_bans}"
    echo "  Unique IPs: ${unique_ips}"
    echo "  Active Bans: ${active_bans}"
    echo "  Whitelist Entries: ${whitelist_count}"
    echo ""

    # Ban sources
    echo "[BAN SOURCES]"
    local sources
    sources=$(nftban_stats_ban_sources "$since" "$until")
    if command -v jq &>/dev/null; then
        local fail2ban manual feeds
        fail2ban=$(echo "$sources" | jq -r '.fail2ban')
        manual=$(echo "$sources" | jq -r '.manual')
        feeds=$(echo "$sources" | jq -r '.feeds')
        echo "  Fail2Ban: ${fail2ban}"
        echo "  Manual: ${manual}"
        echo "  Feeds: ${feeds}"
    fi
    echo ""

    # Feed details
    # Load feeds module if not already loaded
    if ! type -t nftban_feeds_discover_all >/dev/null 2>&1; then
        if [[ -f "/usr/lib/nftban/core/nftban_feeds.sh" ]]; then
            source "/usr/lib/nftban/core/nftban_feeds.sh" 2>/dev/null || true
        fi
    fi

    if type -t nftban_feeds_discover_all >/dev/null 2>&1 && type -t nftban_feeds_get_property >/dev/null 2>&1; then
        echo "[FEEDS]"
        local all_feeds
        all_feeds=$(nftban_feeds_discover_all 2>/dev/null || true)

        if [[ -n "$all_feeds" ]]; then
            local found_enabled=false
            for feed in $all_feeds; do
                local enabled
                enabled=$(nftban_feeds_get_property "$feed" "ENABLED" 2>/dev/null || echo "false")

                if [[ "$enabled" == "true" ]]; then
                    found_enabled=true
                    local feed_file="${NFTBAN_FEEDS_STORAGE_DIR:-/var/lib/nftban/feeds}/${feed}.txt"
                    if [[ -f "$feed_file" ]]; then
                        local count mtime
                        count=$(wc -l < "$feed_file" 2>/dev/null || echo "0")
                        mtime=$(date -r "$feed_file" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "unknown")
                        printf "  • %-25s %6s IPs (Updated: %s)\n" "$feed" "$count" "$mtime"
                    else
                        printf "  • %-25s %s\n" "$feed" "pending download"
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

    # Top jails
    echo "[TOP JAILS]"
    if command -v jq &>/dev/null; then
        nftban_stats_top_jails 5 "$since" "$until" | \
            jq -r '.[] | "  \(.name): \(.count)"' 2>/dev/null || echo "  (jq not available)"
    fi
    echo ""

    # Top IPs
    echo "[TOP BANNED IPs]"
    if command -v jq &>/dev/null; then
        nftban_stats_top_ips 5 "$since" "$until" | \
            jq -r '.[] | "  \(.ip) (\(.country)): \(.count) bans"' 2>/dev/null || echo "  (jq not available)"
    fi
    echo ""

    # Top countries (if GeoIP enabled)
    if [[ "${STATS_GEOIP_ENABLED}" == "true" ]] && command -v nftban-geoip &>/dev/null && command -v jq &>/dev/null; then
        echo "[TOP COUNTRIES]"
        nftban_stats_top_countries 5 "$since" "$until" | \
            jq -r '.[] | "  \(.country): \(.count)"' 2>/dev/null || true
        echo ""
    fi

    if type -t nftban_render_separator >/dev/null 2>&1; then
        nftban_render_separator "═"
    else
        echo "═══════════════════════════════════════════════════════════════"
    fi
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
  "top_jails": $(nftban_stats_top_jails 10 "$since" "$until"),
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
    echo "Timestamp,ID,Jail,IP,Reason,Action,Timeout" > "$output_file"

    # Export filtered data
    awk -F'|' -v since="$since" -v until="$until" \
        '$1 >= since && $1 <= until {print $0}' \
        "$NFTBAN_BAN_LOG" | \
    sed 's/|/,/g' >> "$output_file"

    local count=$(($(wc -l < "$output_file") - 1))

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
            local backup="${NFTBAN_BAN_LOG}.$(date +%Y%m%d-%H%M%S)"
            mv "$NFTBAN_BAN_LOG" "$backup"
            gzip "$backup" 2>/dev/null || true
            touch "$NFTBAN_BAN_LOG"
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
# MODULE INITIALIZATION
# =============================================================================

# Module loaded
if type -t nftban_print_status >/dev/null 2>&1; then
    nftban_print_status "debug" "Stats module loaded (v0.10.0)"
fi
