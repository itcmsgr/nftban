#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Statistics CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: CLI interface for statistics and metrics
#
# meta:name="cmd_stats"
# meta:type="cli"
# meta:header="Statistics CLI Handler"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="CLI interface for statistics and metrics collection and display"
# meta:inventory.files=""
# meta:inventory.binaries="nft,curl,jq"
# meta:inventory.env_vars="NFTBAN_API_URL"
# meta:inventory.config_files="/etc/nftban/nftban.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network="localhost:8080"
# meta:inventory.privileges="none"
#
# meta:created_date="2025-11-05"
# meta:updated_date="2025-11-24"
# =============================================================================

# Enhanced strict mode
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_CLI_STATS_LOADED:-}" ]] && return 0
readonly NFTBAN_CLI_STATS_LOADED=1

# =============================================================================
# LOAD DEPENDENCIES
# =============================================================================

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" 2>/dev/null || true

# Load JSON helper for --json support
[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"

# Load strict mode library
# shellcheck source=/usr/lib/nftban/lib/strict.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/strict.sh" || return 1
else
    # Fallback to manual strict mode
    set -Eeuo pipefail
fi

# Load version library
# shellcheck source=/usr/lib/nftban/lib/version.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/version.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/version.sh" || return 1
fi
JSON_HELPER="${NFTBAN_LIB_DIR}/helpers/json_output.sh"
if [[ -f "$JSON_HELPER" ]]; then
    # shellcheck source=/dev/null
    source "$JSON_HELPER" || return 1
fi

# Load stats core module
if ! declare -f nftban_stats_generate_dashboard >/dev/null 2>&1; then
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_stats.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/core/nftban_stats.sh" || {
            echo "ERROR: Failed to load stats core module" >&2
            return 1
        }
    else
        echo "ERROR: Stats module not found: ${NFTBAN_LIB_DIR}/core/nftban_stats.sh" >&2
        return 1
    fi
fi

# Load path security module
if ! declare -f nftban_path_get_safe_output >/dev/null 2>&1; then
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_path_security.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/core/nftban_path_security.sh" || {
            echo "ERROR: Failed to load path security module" >&2
            return 1
        }
    fi
fi

# =============================================================================
# SHARED STATE API HELPER - NO CLI OVERHEAD
# =============================================================================
# Tries to get basic stats from nftban-ui API first (shared state from watchdog).
# Falls back to nft CLI calls only if API unavailable.
# This eliminates CLI overhead when watchdog is running.
# =============================================================================

# nftban_stats_get_basic_from_api attempts to fetch basic stats from the API
# Returns: JSON with banned_ipv4, banned_ipv6, whitelist_ipv4, whitelist_ipv6, etc.
# Exit code: 0 on success, 1 if API unavailable (caller should fall back to CLI)
nftban_stats_get_basic_from_api() {
    local api_url="${NFTBAN_API_URL:-http://127.0.0.1:8080}"
    local api_endpoint="/api/v1/basic-stats"
    local timeout=2  # Fast timeout - if API slow, fall back to CLI

    # Check if curl available
    if ! command -v curl &>/dev/null; then
        return 1
    fi

    # Try to fetch from API (requires valid session or localhost exemption)
    local response
    response=$(curl -s --max-time "$timeout" "${api_url}${api_endpoint}" 2>/dev/null) || return 1

    # Check if response is valid JSON with success=true
    if command -v jq &>/dev/null; then
        local success
        success=$(echo "$response" | jq -r '.success // false' 2>/dev/null)
        if [[ "$success" == "true" ]]; then
            # Extract data and output
            echo "$response" | jq -r '.data'
            return 0
        fi
    fi

    return 1
}

# nftban_stats_get_counts_optimized gets ban/whitelist counts with API-first approach
# Sets variables: black_v4, black_v6, whitelist_v4, whitelist_v6, feeds_active, feeds_ips
# Returns: 0 if API used (fast), 1 if CLI fallback used (slow)
nftban_stats_get_counts_optimized() {
    local api_data

    # Try API first (NO CLI overhead - data from watchdog netlink)
    if api_data=$(nftban_stats_get_basic_from_api 2>/dev/null); then
        # Parse API response
        if command -v jq &>/dev/null; then
            black_v4=$(echo "$api_data" | jq -r '.banned_ipv4 // 0')
            black_v6=$(echo "$api_data" | jq -r '.banned_ipv6 // 0')
            whitelist_v4=$(echo "$api_data" | jq -r '.whitelist_ipv4 // 0')
            whitelist_v6=$(echo "$api_data" | jq -r '.whitelist_ipv6 // 0')
            feeds_active=$(echo "$api_data" | jq -r '.feeds_active // 0')
            feeds_ips=$(echo "$api_data" | jq -r '.feeds_ips // 0')
            rules_total=$(echo "$api_data" | jq -r '.rules_total // 0')
            return 0  # API success
        fi
    fi

    # Fall back to CLI (slower - direct nft calls)
    # This path is only used when nftban-ui is not running
    return 1
}

# =============================================================================
# SUBCOMMAND: BRIEF (v1.37.1)
# =============================================================================

nftban_stats_cmd_brief() {
    # v1.37.1: One-line stats output for scripts/monitoring
    # Output: "75 banned | 9 whitelisted | 40 dropped | 1463 bans today"
    local banned=0 whitelisted=0 dropped=0 bans_today=0

    # Use nftban_nft_count_all_sets (same source as full dashboard)
    if declare -f nftban_nft_count_all_sets >/dev/null 2>&1; then
        local json
        json=$(nftban_nft_count_all_sets 2>/dev/null || echo '{}')
        banned=$(echo "$json" | jq -r '.blacklist.total // 0' 2>/dev/null || echo 0)
        whitelisted=$(echo "$json" | jq -r '.whitelist.total // 0' 2>/dev/null || echo 0)
    else
        # Fallback: count from cache or nft directly
        local cache_file="/var/cache/nftban/set_counts.json"
        if [[ -f "$cache_file" ]]; then
            banned=$(jq -r '.total_banned // 0' "$cache_file" 2>/dev/null || echo 0)
            whitelisted=$(jq -r '.total_whitelisted // 0' "$cache_file" 2>/dev/null || echo 0)
        fi
    fi

    # Dropped packets from counters
    dropped=$(nft list counters table ip nftban 2>/dev/null | grep -oP 'packets\s+\K[0-9]+' | paste -sd+ | bc 2>/dev/null || echo 0)

    # Today's bans from log
    local today
    today=$(date +%Y-%m-%d)
    local ban_log="${NFTBAN_BAN_LOG:-${NFTBAN_LOG_DIR:-/var/log/nftban}/ban.log}"
    if [[ -f "$ban_log" ]]; then
        bans_today=$(grep -c "$today" "$ban_log" 2>/dev/null || echo 0)
    fi

    echo "${banned} banned | ${whitelisted} whitelisted | ${dropped} dropped | ${bans_today} bans today"
}

# =============================================================================
# MAIN CLI HANDLER
# =============================================================================

nftban_cmd_stats() {
    # Main stats command handler
    # Usage: nftban stats [subcommand] [options]

    local subcommand="${1:-dashboard}"

    # If no args or help requested, show dashboard
    case "$subcommand" in
        help|-h|--help)
            nftban_stats_cmd_help
            return 0
            ;;
        --brief|-b)
            nftban_stats_cmd_brief
            return $?
            ;;
        dashboard|summary|"")
            shift || true
            nftban_stats_cmd_dashboard "$@"
            ;;
        top)
            shift
            nftban_stats_cmd_top "$@"
            ;;
        ip)
            shift
            nftban_stats_cmd_ip "$@"
            ;;
        recent)
            shift
            nftban_stats_cmd_recent "$@"
            ;;
        monitor)
            shift || true
            nftban_stats_cmd_monitor "$@"
            ;;
        export)
            shift
            nftban_stats_cmd_export "$@"
            ;;
        snapshot)
            shift || true
            nftban_stats_cmd_snapshot "$@"
            ;;
        cleanup)
            shift || true
            nftban_stats_cmd_cleanup "$@"
            ;;
        clear-cache)
            shift || true
            nftban_stats_clear_cache
            ;;
        check-alerts)
            shift || true
            nftban_stats_cmd_check_alerts "$@"
            ;;
        trend)
            shift || true
            nftban_stats_cmd_trend "$@"
            ;;
        --today)
            # Show stats for today only
            local today_start
            today_start=$(date +%Y-%m-%d)
            shift
            nftban_stats_cmd_dashboard --since "$today_start" "$@"
            ;;
        --week)
            # Show stats for last 7 days
            local week_start
            week_start=$(date -d "7 days ago" +%Y-%m-%d)
            shift
            nftban_stats_cmd_dashboard --since "$week_start" "$@"
            ;;
        *)
            # If it looks like an option, pass to dashboard
            if [[ "$subcommand" =~ ^-- ]]; then
                nftban_stats_cmd_dashboard "$@"
            else
                echo "ERROR: Unknown stats command: $subcommand" >&2
                echo "Run 'nftban stats help' for usage information" >&2
                return 1
            fi
            ;;
    esac
}

# =============================================================================
# SUBCOMMAND: DASHBOARD
# =============================================================================

nftban_stats_cmd_dashboard() {
    # Show statistics dashboard
    # Usage: nftban stats [dashboard] [--since DATE] [--until DATE] [--last PERIOD] [--json]

    local since=""
    local until=""
    local detailed=false
    local json_mode=false

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json|-j)
                json_mode=true
                shift
                ;;
            --since)
                since="$2"
                shift 2
                ;;
            --until)
                until="$2"
                shift 2
                ;;
            --last)
                # Parse period: 24h, 7d, 30d
                local period="$2"
                case "$period" in
                    *h)
                        local hours="${period%h}"
                        since="$(date -d "${hours} hours ago" +%Y-%m-%d)"
                        ;;
                    *d)
                        local days="${period%d}"
                        since="$(date -d "${days} days ago" +%Y-%m-%d)"
                        ;;
                    *)
                        if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
                            json_output "false" '{}' "Invalid period format. Use: 24h, 7d, 30d, etc."
                        else
                            echo "ERROR: Invalid period format. Use: 24h, 7d, 30d, etc." >&2
                        fi
                        return 1
                        ;;
                esac
                shift 2
                ;;
            --detailed)
                detailed=true
                shift
                ;;
            *)
                if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
                    json_output "false" '{}' "Unknown option: $1"
                else
                    echo "ERROR: Unknown option: $1" >&2
                fi
                return 1
                ;;
        esac
    done

    # Set defaults if not specified
    [[ -z "$since" ]] && since="$(date -d '24 hours ago' +%Y-%m-%d)"
    [[ -z "$until" ]] && until="$(date +%Y-%m-%d)"

    # JSON output mode
    if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
        # Get raw statistics data
        local total_bans=0
        local active_bans=0
        local total_countries=0

        # Count total bans from log
        if [[ -f "${NFTBAN_BAN_LOG:-${NFTBAN_LOG_DIR:-/var/log/nftban}/ban.log}" ]]; then
            total_bans=$(grep -c "^" "${NFTBAN_BAN_LOG}" 2>/dev/null || true)
        fi

        # Count active bans - TRY API FIRST (NO CLI overhead when watchdog running)
        # Falls back to nft CLI only if API unavailable
        local temp_v4=0 temp_v6=0 black_v4=0 black_v6=0 feed_v4=0 feed_v6=0
        local whitelist_v4=0 whitelist_v6=0 geoban_v4=0 geoban_v6=0
        local feeds_active=0 feeds_ips=0 rules_total=0

        # Try optimized API-first approach (reads from shared state - NO CLI)
        if nftban_stats_get_counts_optimized 2>/dev/null; then
            # API success - variables already set by function
            # Note: API provides aggregated counts, not per-source breakdown
            temp_v4=0
            temp_v6=0
            feed_v4=0
            feed_v6=0
            geoban_v4=0
            geoban_v6=0
        # Use centralized nft_schema.sh functions (SINGLE SOURCE OF TRUTH)
        elif declare -f nftban_nft_count_all_sets >/dev/null 2>&1; then
            # Use centralized JSON-based counting (fast O(1) via nft JSON API)
            local counts_json
            counts_json=$(nftban_nft_count_all_sets 2>/dev/null || echo '{}')

            if command -v jq &>/dev/null && [[ -n "$counts_json" ]]; then
                black_v4=$(echo "$counts_json" | jq -r '.blacklist.ipv4 // 0')
                black_v6=$(echo "$counts_json" | jq -r '.blacklist.ipv6 // 0')
                temp_v4=$(echo "$counts_json" | jq -r '.temporary.ipv4 // 0')
                temp_v6=$(echo "$counts_json" | jq -r '.temporary.ipv6 // 0')

                # Whitelist from centralized function
                local wl_counts
                wl_counts=$(nftban_nft_count_whitelist 2>/dev/null || echo "0 0 0")
                whitelist_v4=$(echo "$wl_counts" | cut -d' ' -f1)
                whitelist_v6=$(echo "$wl_counts" | cut -d' ' -f2)
            else
                # jq not available - use line-based centralized functions
                local bl_counts wl_counts
                bl_counts=$(nftban_nft_count_blacklist 2>/dev/null || echo "0 0 0")
                wl_counts=$(nftban_nft_count_whitelist 2>/dev/null || echo "0 0 0")
                black_v4=$(echo "$bl_counts" | cut -d' ' -f1)
                black_v6=$(echo "$bl_counts" | cut -d' ' -f2)
                whitelist_v4=$(echo "$wl_counts" | cut -d' ' -f1)
                whitelist_v6=$(echo "$wl_counts" | cut -d' ' -f2)
                temp_v4=0
                temp_v6=0
            fi

            # Note: In v1.0, feeds/geoban are consolidated into blacklist by nftban-core
            # Set to 0 as they're no longer separate sets
            feed_v4=0
            feed_v6=0
            geoban_v4=0
            geoban_v6=0
        else
            # Fallback: centralized nftban_stats.sh functions (uses nft_schema.sh internally)
            black_v4=0
            black_v6=0
            whitelist_v4=0
            whitelist_v6=0

            if declare -f nftban_stats_count_active_bans >/dev/null 2>&1; then
                local total_bans
                total_bans=$(nftban_stats_count_active_bans 2>/dev/null || echo "0")
                # Cannot break down without JSON - use total for v4
                black_v4="$total_bans"
            fi

            if declare -f nftban_stats_count_whitelist >/dev/null 2>&1; then
                local total_wl
                total_wl=$(nftban_stats_count_whitelist 2>/dev/null || echo "0")
                whitelist_v4="$total_wl"
            fi

            # Note: In v1.0, feeds/geoban are consolidated into blacklist by nftban-core
            temp_v4=0
            temp_v6=0
            feed_v4=0
            feed_v6=0
            geoban_v4=0
            geoban_v6=0
        fi

        # Calculate totals
        local total_temp=$((${temp_v4} + ${temp_v6}))
        local total_black=$((${black_v4} + ${black_v6}))
        local total_feed=$((${feed_v4} + ${feed_v6}))
        local total_geoban=$((${geoban_v4} + ${geoban_v6}))
        local total_whitelist=$((${whitelist_v4} + ${whitelist_v6}))
        active_bans=$((${total_temp} + ${total_black} + ${total_feed} + ${total_geoban}))

        # Get top data
        local top_ips="[]"
        local top_countries="[]"
        local top_jails="[]"

        if declare -f nftban_stats_top_ips >/dev/null 2>&1; then
            top_ips=$(nftban_stats_top_ips 10 "$since" "$until" 2>/dev/null || echo "[]")
        fi

        if declare -f nftban_stats_top_countries >/dev/null 2>&1; then
            top_countries=$(nftban_stats_top_countries 10 "$since" "$until" 2>/dev/null || echo "[]")
            total_countries=$(echo "$top_countries" | jq '. | length' 2>/dev/null) || total_countries=0
        fi

        if declare -f nftban_stats_top_jails >/dev/null 2>&1; then
            top_jails=$(nftban_stats_top_jails 10 "$since" "$until" 2>/dev/null || echo "[]")
        fi

        # Get portscan statistics from nftban-actions.log
        local portscan_blocked_24h=0
        local portscan_blocked_total=0
        local portscan_monitored_ports=0
        local portscan_enabled="false"

        local actions_log="${NFTBAN_ACTIONS_LOG:-${NFTBAN_LOG_DIR:-/var/log/nftban}/nftban-actions.log}"
        if [[ -f "$actions_log" ]]; then
            # Count portscan bans in last 24 hours
            local yesterday_ts
            yesterday_ts=$(date -d '24 hours ago' +%s)
            portscan_blocked_24h=$(jq -r --arg ts "$yesterday_ts" 'select(.source == "portscan" and .event == "ban") | select((.ts | fromdateiso8601) >= ($ts | tonumber))' "$actions_log" 2>/dev/null | jq -s '. | length' 2>/dev/null) || portscan_blocked_24h=0

            # Count total portscan bans
            portscan_blocked_total=$(jq -r 'select(.source == "portscan" and .event == "ban")' "$actions_log" 2>/dev/null | jq -s '. | length' 2>/dev/null) || portscan_blocked_total=0
        fi

        # Get monitored ports count and enabled status from portscan config
        local portscan_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/portscan/main.conf"
        if [[ -f "$portscan_conf" ]]; then
            # Check if enabled
            local enabled_line
            enabled_line=$(grep "^PORTSCAN_ENABLED=" "$portscan_conf" 2>/dev/null) || true
            if [[ -n "$enabled_line" ]]; then
                local enabled_value
                enabled_value=$(echo "$enabled_line" | cut -d= -f2 | tr -d '"' | tr -d "'" | tr -d ' ') || true
                if [[ "$enabled_value" == "true" ]]; then
                    portscan_enabled="true"
                fi
            fi

            # Get monitored ports
            local ports_line
            ports_line=$(grep "^PORTSCAN_MONITOR_PORTS=" "$portscan_conf" 2>/dev/null) || true
            if [[ -n "$ports_line" ]]; then
                # Extract value: PORTSCAN_MONITOR_PORTS="value"
                local ports_value
                ports_value=$(echo "$ports_line" | cut -d= -f2 | tr -d '"' | tr -d "'") || true

                # Handle special values
                if [[ "$ports_value" == "closed" ]] || [[ "$ports_value" == "all" ]]; then
                    portscan_monitored_ports=1
                elif [[ -n "$ports_value" ]]; then
                    portscan_monitored_ports=$(echo "$ports_value" | grep -oE '[0-9]+' | wc -l) || portscan_monitored_ports=0
                fi
            fi
        fi

        # Get DDoS statistics from config and nftables counters
        local ddos_enabled="false"
        local ddos_packets_dropped=0
        local ddos_bytes_dropped=0
        local ddos_blocked_24h=0
        local ddos_blocked_total=0

        local ddos_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/ddos/main.conf"
        if [[ -f "$ddos_conf" ]]; then
            # Check if enabled
            local ddos_enabled_line
            ddos_enabled_line=$(grep "^DDOS_ENABLED=" "$ddos_conf" 2>/dev/null) || true
            if [[ -n "$ddos_enabled_line" ]]; then
                local ddos_enabled_value
                ddos_enabled_value=$(echo "$ddos_enabled_line" | cut -d= -f2 | tr -d '"' | tr -d "'" | tr -d ' ') || true
                if [[ "$ddos_enabled_value" == "true" ]]; then
                    ddos_enabled="true"
                fi
            fi
        fi

        # Get DDoS counters from nftables if available
        if [[ "$ddos_enabled" == "true" ]]; then
            # Try to get counters from ddos chain
            local ddos_counter_output
            ddos_counter_output=$(nft list chain "${NFTBAN_TABLE_IPV4}" ddos_protection 2>/dev/null || nft list chain "${NFTBAN_TABLE_IPV6}" ddos_protection 2>/dev/null || true)
            if [[ -n "$ddos_counter_output" ]]; then
                # Extract packets and bytes from counter output
                ddos_packets_dropped=$(echo "$ddos_counter_output" | grep -oP 'packets \K[0-9]+' | head -1) || ddos_packets_dropped=0
                ddos_bytes_dropped=$(echo "$ddos_counter_output" | grep -oP 'bytes \K[0-9]+' | head -1) || ddos_bytes_dropped=0
            fi

            # Get DDoS bans from actions log
            if [[ -f "$actions_log" ]]; then
                ddos_blocked_24h=$(jq -r --arg ts "$yesterday_ts" 'select(.source == "ddos" and .event == "ban") | select((.ts | fromdateiso8601) >= ($ts | tonumber))' "$actions_log" 2>/dev/null | jq -s '. | length' 2>/dev/null) || ddos_blocked_24h=0
                ddos_blocked_total=$(jq -r 'select(.source == "ddos" and .event == "ban")' "$actions_log" 2>/dev/null | jq -s '. | length' 2>/dev/null) || ddos_blocked_total=0
            fi
        fi

        # Build JSON response with detailed breakdown
        local data
        if command -v jq &>/dev/null; then
            data=$(jq -n \
                --arg since "$since" \
                --arg until "$until" \
                --arg total_bans "$total_bans" \
                --arg active_bans "$active_bans" \
                --arg total_countries "$total_countries" \
                --arg temp_v4 "$temp_v4" \
                --arg temp_v6 "$temp_v6" \
                --arg black_v4 "$black_v4" \
                --arg black_v6 "$black_v6" \
                --arg feed_v4 "$feed_v4" \
                --arg feed_v6 "$feed_v6" \
                --arg geoban_v4 "$geoban_v4" \
                --arg geoban_v6 "$geoban_v6" \
                --arg whitelist_v4 "$whitelist_v4" \
                --arg whitelist_v6 "$whitelist_v6" \
                --arg total_temp "$total_temp" \
                --arg total_black "$total_black" \
                --arg total_feed "$total_feed" \
                --arg total_geoban "$total_geoban" \
                --arg total_whitelist "$total_whitelist" \
                --arg portscan_blocked_24h "$portscan_blocked_24h" \
                --arg portscan_blocked_total "$portscan_blocked_total" \
                --arg portscan_monitored_ports "$portscan_monitored_ports" \
                --arg portscan_enabled "$portscan_enabled" \
                --arg ddos_enabled "$ddos_enabled" \
                --arg ddos_packets_dropped "$ddos_packets_dropped" \
                --arg ddos_bytes_dropped "$ddos_bytes_dropped" \
                --arg ddos_blocked_24h "$ddos_blocked_24h" \
                --arg ddos_blocked_total "$ddos_blocked_total" \
                --arg feeds_active "$feeds_active" \
                --arg feeds_ips "$feeds_ips" \
                --arg rules_total "$rules_total" \
                --argjson top_ips "$top_ips" \
                --argjson top_countries "$top_countries" \
                --argjson top_jails "$top_jails" \
                '{
                    period: {since: $since, until: $until},
                    summary: {
                        total_bans: ($total_bans | tonumber),
                        active_bans: ($active_bans | tonumber),
                        total_countries: ($total_countries | tonumber)
                    },
                    breakdown: {
                        temporary: {
                            total: ($total_temp | tonumber),
                            ipv4: ($temp_v4 | tonumber),
                            ipv6: ($temp_v6 | tonumber)
                        },
                        blacklist: {
                            total: ($total_black | tonumber),
                            ipv4: ($black_v4 | tonumber),
                            ipv6: ($black_v6 | tonumber)
                        },
                        feeds: {
                            total: ($total_feed | tonumber),
                            ipv4: ($feed_v4 | tonumber),
                            ipv6: ($feed_v6 | tonumber)
                        },
                        geoban: {
                            total: ($total_geoban | tonumber),
                            ipv4: ($geoban_v4 | tonumber),
                            ipv6: ($geoban_v6 | tonumber)
                        },
                        whitelist: {
                            total: ($total_whitelist | tonumber),
                            ipv4: ($whitelist_v4 | tonumber),
                            ipv6: ($whitelist_v6 | tonumber)
                        }
                    },
                    portscan: {
                        monitored_ports: ($portscan_monitored_ports | tonumber),
                        blocked_24h: ($portscan_blocked_24h | tonumber),
                        blocked_total: ($portscan_blocked_total | tonumber),
                        enabled: ($portscan_enabled == "true")
                    },
                    ddos: {
                        packets_dropped: ($ddos_packets_dropped | tonumber),
                        bytes_dropped: ($ddos_bytes_dropped | tonumber),
                        blocked_24h: ($ddos_blocked_24h | tonumber),
                        blocked_total: ($ddos_blocked_total | tonumber),
                        enabled: ($ddos_enabled == "true")
                    },
                    shared_state: {
                        feeds_active: ($feeds_active | tonumber),
                        feeds_ips: ($feeds_ips | tonumber),
                        rules_total: ($rules_total | tonumber)
                    },
                    top_ips: $top_ips,
                    top_countries: $top_countries,
                    top_jails: $top_jails
                }')
        else
            # Fallback without jq
            local portscan_enabled_json="false"
            [[ "$portscan_enabled" == "true" ]] && portscan_enabled_json="true"
            local ddos_enabled_json="false"
            [[ "$ddos_enabled" == "true" ]] && ddos_enabled_json="true"
            data="{\"period\":{\"since\":\"$since\",\"until\":\"$until\"},\"summary\":{\"total_bans\":$total_bans,\"active_bans\":$active_bans,\"total_countries\":$total_countries},\"breakdown\":{\"temporary\":{\"total\":$total_temp,\"ipv4\":$temp_v4,\"ipv6\":$temp_v6},\"blacklist\":{\"total\":$total_black,\"ipv4\":$black_v4,\"ipv6\":$black_v6},\"feeds\":{\"total\":$total_feed,\"ipv4\":$feed_v4,\"ipv6\":$feed_v6},\"whitelist\":{\"total\":$total_whitelist,\"ipv4\":$whitelist_v4,\"ipv6\":$whitelist_v6}},\"portscan\":{\"monitored_ports\":$portscan_monitored_ports,\"blocked_24h\":$portscan_blocked_24h,\"blocked_total\":$portscan_blocked_total,\"enabled\":$portscan_enabled_json},\"ddos\":{\"packets_dropped\":$ddos_packets_dropped,\"bytes_dropped\":$ddos_bytes_dropped,\"blocked_24h\":$ddos_blocked_24h,\"blocked_total\":$ddos_blocked_total,\"enabled\":$ddos_enabled_json},\"shared_state\":{\"feeds_active\":$feeds_active,\"feeds_ips\":$feeds_ips,\"rules_total\":$rules_total},\"top_ips\":$top_ips,\"top_countries\":$top_countries,\"top_jails\":$top_jails}"
        fi

        json_output "true" "$data"
        return 0
    fi

    # Human-readable output mode
    # Show unified banner with health indicator
    set +e
    if [[ ! $(type -t nftban_banner_unified) == "function" ]]; then
        if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
            source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" 2>/dev/null || true
        fi
    fi
    if type -t nftban_banner_unified >/dev/null 2>&1; then
        nftban_banner_unified "stats" 2>/dev/null || true
    elif type -t nftban_banner >/dev/null 2>&1; then
        nftban_banner 2>/dev/null || true
        echo ""
    fi
    set -e

    # Generate dashboard
    nftban_stats_generate_dashboard "$since" "$until"
}

# =============================================================================
# SUBCOMMAND: TOP
# =============================================================================

nftban_stats_cmd_top() {
    # Show top lists (IPs, countries, jails)
    # Usage: nftban stats top [ips|countries|jails] [LIMIT] [--json]

    local type="${1:-ips}"
    local limit="${2:-${STATS_TOP_N:-10}}"
    local since
    since="$(date -d '30 days ago' +%Y-%m-%d)"
    local until
    until="$(date +%Y-%m-%d)"
    local json_mode=false

    # Parse additional options
    shift 2 2>/dev/null || shift $# 2>/dev/null || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json|-j)
                json_mode=true
                shift
                ;;
            --since)
                since="$2"
                shift 2
                ;;
            --until)
                until="$2"
                shift 2
                ;;
            --last)
                local period="$2"
                case "$period" in
                    *h)
                        since="$(date -d "${period%h} hours ago" +%Y-%m-%d)"
                        ;;
                    *d)
                        since="$(date -d "${period%d} days ago" +%Y-%m-%d)"
                        ;;
                esac
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    # JSON output mode
    if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
        local result_data="[]"

        case "$type" in
            ips|ip)
                if declare -f nftban_stats_top_ips >/dev/null 2>&1; then
                    result_data=$(nftban_stats_top_ips "$limit" "$since" "$until" 2>/dev/null || echo "[]")
                fi
                ;;
            countries|country)
                if declare -f nftban_stats_top_countries >/dev/null 2>&1; then
                    result_data=$(nftban_stats_top_countries "$limit" "$since" "$until" 2>/dev/null || echo "[]")
                fi
                ;;
            jails|jail)
                if declare -f nftban_stats_top_jails >/dev/null 2>&1; then
                    result_data=$(nftban_stats_top_jails "$limit" "$since" "$until" 2>/dev/null || echo "[]")
                fi
                ;;
            *)
                json_output "false" '{}' "Unknown top type: $type. Valid types: ips, countries, jails"
                return 1
                ;;
        esac

        local data
        if command -v jq &>/dev/null; then
            data=$(jq -n \
                --arg type "$type" \
                --arg limit "$limit" \
                --arg since "$since" \
                --arg until "$until" \
                --argjson items "$result_data" \
                '{
                    type: $type,
                    limit: ($limit | tonumber),
                    period: {since: $since, until: $until},
                    items: $items,
                    count: ($items | length)
                }')
        else
            # Fallback without jq
            local count
            count=$(echo "$result_data" | { grep -o "}" || true; } | wc -l)
            data="{\"type\":\"$type\",\"limit\":$limit,\"period\":{\"since\":\"$since\",\"until\":\"$until\"},\"items\":$result_data,\"count\":$count}"
        fi

        json_output "true" "$data"
        return 0
    fi

    # Human-readable output mode
    echo ""
    if type -t nftban_render_separator >/dev/null 2>&1; then
        nftban_render_separator "─"
    else
        echo "───────────────────────────────────────────────────────────────"
    fi

    case "$type" in
        ips|ip)
            echo "Top ${limit} Banned IPs (${since} to ${until})"
            if type -t nftban_render_separator >/dev/null 2>&1; then
                nftban_render_separator "─"
            else
                echo "───────────────────────────────────────────────────────────────"
            fi
            echo ""
            if command -v jq &>/dev/null; then
                nftban_stats_top_ips "$limit" "$since" "$until" | \
                    jq -r '.[] | "\(.ip) (\(.country)): \(.count) bans"'
            else
                echo "ERROR: jq is required for formatted output" >&2
                return 1
            fi
            ;;
        countries|country)
            echo "Top ${limit} Countries (${since} to ${until})"
            if type -t nftban_render_separator >/dev/null 2>&1; then
                nftban_render_separator "─"
            else
                echo "───────────────────────────────────────────────────────────────"
            fi
            echo ""
            if command -v jq &>/dev/null; then
                nftban_stats_top_countries "$limit" "$since" "$until" | \
                    jq -r '.[] | "\(.country): \(.count) bans"'
            else
                echo "ERROR: jq is required for formatted output" >&2
                return 1
            fi
            ;;
        jails|jail)
            echo "Top ${limit} Jails (${since} to ${until})"
            if type -t nftban_render_separator >/dev/null 2>&1; then
                nftban_render_separator "─"
            else
                echo "───────────────────────────────────────────────────────────────"
            fi
            echo ""
            if command -v jq &>/dev/null; then
                nftban_stats_top_jails "$limit" "$since" "$until" | \
                    jq -r '.[] | "\(.name): \(.count) bans"'
            else
                echo "ERROR: jq is required for formatted output" >&2
                return 1
            fi
            ;;
        *)
            echo "ERROR: Unknown top type: $type" >&2
            echo "Valid types: ips, countries, jails" >&2
            return 1
            ;;
    esac

    echo ""
}

# =============================================================================
# SUBCOMMAND: IP HISTORY
# =============================================================================

nftban_stats_cmd_ip() {
    # Show ban history for specific IP
    # Usage: nftban stats ip <IP> [--detailed] [--json]

    local ip="${1:-}"
    local json_mode=false

    if [[ -z "$ip" ]]; then
        if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
            json_output "false" '{}' "IP address required"
        else
            echo "ERROR: IP address required" >&2
            echo "Usage: nftban stats ip <IP>" >&2
        fi
        return 1
    fi

    shift
    local detailed=false

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json|-j)
                json_mode=true
                shift
                ;;
            --detailed)
                # shellcheck disable=SC2034  # Reserved for detailed mode
                detailed=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    # Get history
    local history
    if declare -f nftban_stats_ip_history >/dev/null 2>&1; then
        history=$(nftban_stats_ip_history "$ip" 2>/dev/null || echo "[]")
    else
        history="[]"
    fi

    # JSON output mode
    if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
        local data
        if command -v jq &>/dev/null; then
            local total
            total=$(echo "$history" | jq '. | length' 2>/dev/null) || total=0
            data=$(jq -n \
                --arg ip "$ip" \
                --arg total "$total" \
                --argjson history "$history" \
                '{
                    ip: $ip,
                    total_events: ($total | tonumber),
                    history: $history
                }')
        else
            data="{\"ip\":\"$ip\",\"total_events\":0,\"history\":$history}"
        fi

        json_output "true" "$data"
        return 0
    fi

    # Human-readable output mode
    echo ""
    if type -t nftban_render_separator >/dev/null 2>&1; then
        nftban_render_separator "═"
    else
        echo "═══════════════════════════════════════════════════════════════"
    fi
    echo "Ban History for ${ip}"
    if type -t nftban_render_separator >/dev/null 2>&1; then
        nftban_render_separator "═"
    else
        echo "═══════════════════════════════════════════════════════════════"
    fi
    echo ""

    if command -v jq &>/dev/null; then
        local total
        total=$(echo "$history" | jq '. | length')

        if [[ $total -eq 0 ]]; then
            echo "No ban records found for ${ip}"
            echo ""
            return 0
        fi

        echo "Total events: ${total}"
        echo ""

        # Display events
        echo "$history" | jq -r '.[] | "[\(.action)] \(.timestamp)\n  Jail: \(.jail)\n  Reason: \(.reason)\n"'
    else
        echo "ERROR: jq is required for formatted output" >&2
        return 1
    fi

    echo ""
}

# =============================================================================
# SUBCOMMAND: RECENT ACTIVITY
# =============================================================================

nftban_stats_cmd_recent() {
    # Show recent ban activity
    # Usage: nftban stats recent [LIMIT] [--follow] [--json]

    local limit="${1:-20}"
    local follow=false
    local json_mode=false

    shift || true

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json|-j)
                json_mode=true
                shift
                ;;
            --follow)
                follow=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    # JSON mode doesn't support --follow
    if [[ "$follow" == "true" ]] && [[ "$json_mode" == "true" ]]; then
        if declare -f json_output >/dev/null 2>&1; then
            json_output "false" '{}' "JSON mode does not support --follow. Use --json without --follow."
        else
            echo "ERROR: JSON mode does not support --follow" >&2
        fi
        return 1
    fi

    if [[ "$follow" == "true" ]]; then
        # Tail mode
        echo "Following ban log (Ctrl+C to exit)..."
        echo ""
        # shellcheck disable=SC2034  # Structured log parsing - only some fields used
        tail -f "${NFTBAN_BAN_LOG:-${NFTBAN_LOG_DIR:-/var/log/nftban}/ban.log}" | while IFS='|' read -r timestamp id jail ip reason action timeout; do
            printf "[%s] %s | %-16s | %-12s | %s\n" \
                "$(date +%H:%M:%S)" "$timestamp" "$ip" "$action" "$jail"
        done
    else
        # JSON output mode
        if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
            local activity_data="[]"

            if declare -f nftban_stats_recent_activity >/dev/null 2>&1; then
                activity_data=$(nftban_stats_recent_activity "$limit" 2>/dev/null || echo "[]")
            fi

            local data
            if command -v jq &>/dev/null; then
                data=$(jq -n \
                    --arg limit "$limit" \
                    --argjson items "$activity_data" \
                    '{
                        limit: ($limit | tonumber),
                        items: $items,
                        count: ($items | length)
                    }')
            else
                local count
                count=$(echo "$activity_data" | { grep -o "}" || true; } | wc -l)
                data="{\"limit\":$limit,\"items\":$activity_data,\"count\":$count}"
            fi

            json_output "true" "$data"
            return 0
        fi

        # Human-readable output
        nftban_stats_recent_activity "$limit"
    fi
}

# =============================================================================
# SUBCOMMAND: MONITOR
# =============================================================================

nftban_stats_cmd_monitor() {
    # Real-time monitoring mode with auto-refresh
    # Usage: nftban stats monitor [--interval SECONDS]

    local interval="${STATS_MONITOR_REFRESH:-5}"

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --interval)
                interval="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    echo "Starting real-time monitor (refresh every ${interval}s, Ctrl+C to exit)..."
    sleep 2

    while true; do
        clear
        nftban_stats_generate_dashboard "$(date -d '24 hours ago' +%Y-%m-%d)" "$(date +%Y-%m-%d)"
        echo ""
        echo "Auto-refreshing every ${interval} seconds... (Ctrl+C to exit)"
        sleep "$interval"
    done
}

# =============================================================================
# SUBCOMMAND: EXPORT
# =============================================================================

nftban_stats_cmd_export() {
    # Export statistics
    # Usage: nftban stats export [--format json|csv] [--output FILE]

    local format="json"
    local output=""
    local since
    since="$(date -d '30 days ago' +%Y-%m-%d)"
    local until
    until="$(date +%Y-%m-%d)"
    local allow_unsafe=""

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format)
                format="$2"
                shift 2
                ;;
            --output)
                output="$2"
                shift 2
                ;;
            --unsafe-allow-tmp)
                allow_unsafe="allow-unsafe"
                shift
                ;;
            --since)
                since="$2"
                shift 2
                ;;
            --until)
                until="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    # Security notice
    local exports_dir="${NFTBAN_DATA_DIR:-/var/lib/nftban}/exports"
    if [[ -n "$output" ]]; then
        echo "[SECURITY] Output path validation enabled - only approved directories allowed" >&2
        echo "[INFO] Approved locations: ${NFTBAN_DATA_DIR:-/var/lib/nftban}/* (reports, metrics, exports)" >&2
    fi

    case "$format" in
        json)
            local safe_output
            safe_output=$(nftban_path_get_safe_output "$output" "$exports_dir" "$allow_unsafe" ".json") || return 1
            nftban_stats_export_json "$safe_output" "$since" "$until"
            ;;
        csv)
            local safe_output
            safe_output=$(nftban_path_get_safe_output "$output" "$exports_dir" "$allow_unsafe" ".csv") || return 1
            nftban_stats_export_csv "$safe_output" "$since" "$until"
            ;;
        *)
            echo "ERROR: Unknown export format: $format" >&2
            echo "Valid formats: json, csv" >&2
            return 1
            ;;
    esac
}

# =============================================================================
# SUBCOMMAND: SNAPSHOT
# =============================================================================

nftban_stats_cmd_snapshot() {
    # Create hourly snapshot
    # Usage: nftban stats snapshot

    if type -t nftban_print_status >/dev/null 2>&1; then
        nftban_print_status "info" "Creating statistics snapshot..."
    else
        echo "[INFO] Creating snapshot..."
    fi

    local snapshot_file
    snapshot_file=$(nftban_stats_create_snapshot)

    if type -t nftban_print_status >/dev/null 2>&1; then
        nftban_print_status "success" "Snapshot created: ${snapshot_file}"
    else
        echo "[SUCCESS] Snapshot: ${snapshot_file}"
    fi
}

# =============================================================================
# SUBCOMMAND: CLEANUP
# =============================================================================

nftban_stats_cmd_cleanup() {
    # Cleanup old logs and snapshots
    # Usage: nftban stats cleanup [--days N]

    local days="${STATS_RETENTION_DAYS:-90}"

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --days)
                days="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    nftban_stats_cleanup_logs "$days"
}

# =============================================================================
# SUBCOMMAND: CHECK ALERTS
# =============================================================================

nftban_stats_cmd_check_alerts() {
    # Check for alerts and report
    # Usage: nftban stats check-alerts

    local alerts_triggered=false

    # Check high ban rate
    if nftban_stats_check_high_ban_rate; then
        alerts_triggered=true
    fi

    # Check repeat offenders
    local offenders
    offenders=$(nftban_stats_find_repeat_offenders)

    if command -v jq &>/dev/null; then
        local count
        count=$(echo "$offenders" | jq '. | length')

        if [[ $count -gt 0 ]]; then
            echo ""
            echo "Repeat Offenders Detected (${count}):"
            echo "$offenders" | jq -r '.[] | "  \(.ip): \(.count) bans"'
            alerts_triggered=true
        fi
    fi

    if [[ "$alerts_triggered" == "false" ]]; then
        if type -t nftban_print_status >/dev/null 2>&1; then
            nftban_print_status "success" "No alerts triggered"
        else
            echo "[OK] No alerts"
        fi
    fi
}

# =============================================================================
# SUBCOMMAND: TREND
# =============================================================================

nftban_stats_cmd_trend() {
    # Display ban statistics trends (7-day rolling history)
    # Usage: nftban stats trend [--json] [thresholds]

    local json_mode=0
    local show_thresholds_only=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json|-j)
                json_mode=1
                shift
                ;;
            thresholds)
                show_thresholds_only=1
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    # Ensure trend functions are available
    if ! declare -f nftban_stats_trend_display >/dev/null 2>&1; then
        echo "ERROR: Trend functions not loaded" >&2
        return 1
    fi

    if [[ $show_thresholds_only -eq 1 ]]; then
        local thresholds
        thresholds=$(nftban_stats_trend_thresholds)

        if [[ $json_mode -eq 1 ]]; then
            echo "$thresholds"
        else
            echo ""
            echo "SUGGESTED THRESHOLDS (based on historical data)"
            echo "══════════════════════════════════════════════════════════════"
            echo ""
            local warn crit samples
            warn=$(echo "$thresholds" | jq -r '.warning')
            crit=$(echo "$thresholds" | jq -r '.critical')
            samples=$(echo "$thresholds" | jq -r '.based_on_samples')
            printf "  %-20s %s bans/hour\n" "Warning threshold..." "$warn"
            printf "  %-20s %s bans/hour\n" "Critical threshold.." "$crit"
            printf "  %-20s %s hours\n" "Based on samples...." "$samples"
            echo ""
        fi
        return 0
    fi

    # Full trend display
    if [[ $json_mode -eq 1 ]]; then
        nftban_stats_trend_display --json
    else
        nftban_stats_trend_display
    fi
}

# =============================================================================
# HELP TEXT
# =============================================================================

nftban_stats_cmd_help() {
    cat <<'EOF'
NFTBan Statistics & Metrics

USAGE:
    nftban stats [COMMAND] [OPTIONS]

COMMANDS:
    dashboard | summary    Show comprehensive statistics dashboard (default)
    trend                  Show 7-day trend analysis with averages
    top <type> [N]         Show top lists (ips, countries, jails)
    ip <IP>                Show ban history for specific IP
    recent [N]             Show recent ban activity
    monitor                Real-time monitoring with auto-refresh
    export                 Export statistics to file
    snapshot               Create hourly snapshot
    cleanup                Cleanup old logs and snapshots
    clear-cache            Clear statistics cache
    check-alerts           Check for threshold alerts
    help                   Show this help message

DASHBOARD OPTIONS:
    --since DATE           Start date (YYYY-MM-DD)
    --until DATE           End date (YYYY-MM-DD)
    --last PERIOD          Time window (24h, 7d, 30d)
    --detailed             Show detailed metrics

TOP COMMAND:
    nftban stats top ips 20            Top 20 banned IPs
    nftban stats top countries 10      Top 10 countries
    nftban stats top jails 5           Top 5 jails

EXPORT OPTIONS:
    --format FORMAT        Export format (json, csv)
    --output FILE          Output file path
    --since DATE           Start date
    --until DATE           End date

MONITOR OPTIONS:
    --interval SECONDS     Refresh interval (default: 5)

CLEANUP OPTIONS:
    --days N               Retention period (default: 90)

TREND COMMAND:
    nftban stats trend               Show 7-day trend analysis
    nftban stats trend --json        JSON output for scripts
    nftban stats trend thresholds    Show suggested thresholds only

EXAMPLES:
    # Show dashboard for last 24 hours
    nftban stats
    nftban stats summary  # Alias for dashboard

    # Show dashboard for last 7 days
    nftban stats --last 7d

    # Top 20 banned IPs
    nftban stats top ips 20

    # IP ban history
    nftban stats ip 192.0.2.100

    # Recent activity (last 50)
    nftban stats recent 50

    # Follow ban log in real-time
    nftban stats recent --follow

    # Real-time monitoring
    nftban stats monitor

    # Export to JSON
    nftban stats export --format json --output /tmp/stats.json

    # Export to CSV (last 30 days)
    nftban stats export --format csv --last 30d

    # Create snapshot
    nftban stats snapshot

    # Cleanup logs older than 90 days
    nftban stats cleanup --days 90

    # Check for alerts
    nftban stats check-alerts

CONFIGURATION:
    /etc/nftban/conf.d/stats.conf      Statistics configuration
    /var/lib/nftban/metrics/           Metrics database
    /var/lib/nftban/snapshots/         Hourly snapshots
    ${NFTBAN_LOG_DIR}/ban.log            Primary data source

For automated reports, see: nftban report help
EOF
}

# =============================================================================
# EXPORTS
# =============================================================================

# Exit marker for testing validation
command -v nftban_cmd_exit >/dev/null 2>&1 && nftban_cmd_exit "stats"

export -f nftban_cmd_stats

# =============================================================================
# MODULE INITIALIZATION
# =============================================================================

# CLI module loaded
if type -t nftban_print_status >/dev/null 2>&1; then
    nftban_print_status "debug" "Stats CLI loaded"
fi
