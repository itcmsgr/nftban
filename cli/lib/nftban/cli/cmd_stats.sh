#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Statistics CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: CLI interface for statistics and metrics
#
# meta:name=cmd_stats
# meta:type=cli
# meta:header=Statistics CLI Handler
# meta:version=1.0.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=CLI interface for statistics and metrics collection and display
# meta:input=Statistics query parameters and display options
# meta:output=Statistics dashboard, metrics, and analytics
#
# **Inventory & Requirements**
# meta:depends=nftban_stats.sh
#
# meta:created_date=2025-11-05
# meta:updated_date=2025-11-24
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
[[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" ]] && source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf"

# Load JSON helper for --json support
[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"

# Load strict mode library
# shellcheck source=/usr/lib/nftban/lib/strict.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/strict.sh"
else
    # Fallback to manual strict mode
    set -Eeuo pipefail
fi

# Load version library
# shellcheck source=/usr/lib/nftban/lib/version.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/version.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/version.sh"
fi
JSON_HELPER="${NFTBAN_LIB_DIR}/helpers/json_output.sh"
if [[ -f "$JSON_HELPER" ]]; then
    # shellcheck source=/dev/null
    source "$JSON_HELPER"
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
# MAIN CLI HANDLER
# =============================================================================

nftban_cmd_stats() {
    # Main stats command handler
    # Usage: nftban stats [subcommand] [options]

    local subcommand="${1:-dashboard}"

    # If no args or help requested, show dashboard
    case "$subcommand" in
        help|--help|-h)
            nftban_stats_cmd_help
            return 0
            ;;
        dashboard|"")
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
        --today)
            # Show stats for today only
            local today_start=$(date +%Y-%m-%d)
            shift
            nftban_stats_cmd_dashboard --since "$today_start" "$@"
            ;;
        --week)
            # Show stats for last 7 days
            local week_start=$(date -d "7 days ago" +%Y-%m-%d)
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
            --json)
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
        if [[ -f "${NFTBAN_BAN_LOG:-/var/log/nftban/ban.log}" ]]; then
            total_bans=$(grep -c "^" "${NFTBAN_BAN_LOG}" 2>/dev/null || echo "0")
        fi

        # Count active bans from nftables - USE CENTRALIZED nftban_stats_count_breakdown()
        # This ensures consistency across all commands (status, stats, GUI API)
        local temp_v4=0 temp_v6=0 black_v4=0 black_v6=0 feed_v4=0 feed_v6=0
        local whitelist_v4=0 whitelist_v6=0 geoban_v4=0 geoban_v6=0

        # Call centralized breakdown function (if available)
        if declare -f nftban_stats_count_breakdown >/dev/null 2>&1; then
            # Use centralized function
            eval "$(nftban_stats_count_breakdown)"
        else
            # Fallback: inline counting for v0.7.3 architecture (ip/ip6 nftban tables)
            # Note: New architecture uses single blacklist with timeout flag
            # Cannot distinguish temp vs permanent without parsing timeout attribute

            # Blacklist (contains permanent + temporary with timeout)
            if nft list set ${NFTBAN_TABLE_IPV4} blacklist_ipv4 &>/dev/null 2>&1; then
                black_v4=$(nft list set ${NFTBAN_TABLE_IPV4} blacklist_ipv4 2>/dev/null | { grep -oP '\d+\.\d+\.\d+\.\d+' || true; } | wc -l 2>/dev/null || echo "0")
                black_v4=${black_v4//[^0-9]/}
                black_v4=${black_v4:-0}
            fi
            if nft list set ${NFTBAN_TABLE_IPV6} blacklist_ipv6 &>/dev/null 2>&1; then
                black_v6=$(nft list set ${NFTBAN_TABLE_IPV6} blacklist_ipv6 2>/dev/null | { grep -oP '[0-9a-fA-F:]+::[0-9a-fA-F:]*|[0-9a-fA-F:]+:[0-9a-fA-F:]+' || true; } | wc -l 2>/dev/null || echo "0")
                black_v6=${black_v6//[^0-9]/}
                black_v6=${black_v6:-0}
            fi

            # Whitelist
            if nft list set ${NFTBAN_TABLE_IPV4} whitelist_ipv4 &>/dev/null 2>&1; then
                whitelist_v4=$(nft list set ${NFTBAN_TABLE_IPV4} whitelist_ipv4 2>/dev/null | { grep -oP '\d+\.\d+\.\d+\.\d+' || true; } | wc -l 2>/dev/null || echo "0")
                whitelist_v4=${whitelist_v4//[^0-9]/}
                whitelist_v4=${whitelist_v4:-0}
            fi
            if nft list set ${NFTBAN_TABLE_IPV6} whitelist_ipv6 &>/dev/null 2>&1; then
                whitelist_v6=$(nft list set ${NFTBAN_TABLE_IPV6} whitelist_ipv6 2>/dev/null | { grep -oP '[0-9a-fA-F:]+::[0-9a-fA-F:]*|[0-9a-fA-F:]+:[0-9a-fA-F:]+' || true; } | wc -l 2>/dev/null || echo "0")
                whitelist_v6=${whitelist_v6//[^0-9]/}
                whitelist_v6=${whitelist_v6:-0}
            fi

            # Note: In v0.7.3, feeds/geoban are consolidated into blacklist by nftban-core
            # Set to 0 as they're no longer separate sets
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
            total_countries=$(echo "$top_countries" | jq '. | length' 2>/dev/null || echo "0")
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
            local yesterday_ts=$(date -d '24 hours ago' +%s)
            portscan_blocked_24h=$(jq -r --arg ts "$yesterday_ts" 'select(.source == "portscan" and .event == "ban") | select((.ts | fromdateiso8601) >= ($ts | tonumber))' "$actions_log" 2>/dev/null | jq -s '. | length' 2>/dev/null || echo "0")

            # Count total portscan bans
            portscan_blocked_total=$(jq -r 'select(.source == "portscan" and .event == "ban")' "$actions_log" 2>/dev/null | jq -s '. | length' 2>/dev/null || echo "0")
        fi

        # Get monitored ports count and enabled status from portscan config
        if [[ -f "/etc/nftban/conf.d/portscan.conf" ]]; then
            # Check if enabled
            local enabled_line
            enabled_line=$(grep "^PORTSCAN_ENABLED=" /etc/nftban/conf.d/portscan.conf 2>/dev/null) || true
            if [[ -n "$enabled_line" ]]; then
                local enabled_value
                enabled_value=$(echo "$enabled_line" | cut -d= -f2 | tr -d '"' | tr -d "'" | tr -d ' ') || true
                if [[ "$enabled_value" == "true" ]]; then
                    portscan_enabled="true"
                fi
            fi

            # Get monitored ports
            local ports_line
            ports_line=$(grep "^PORTSCAN_MONITOR_PORTS=" /etc/nftban/conf.d/portscan.conf 2>/dev/null) || true
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
                    top_ips: $top_ips,
                    top_countries: $top_countries,
                    top_jails: $top_jails
                }')
        else
            # Fallback without jq
            local enabled_json="false"
            [[ "$portscan_enabled" == "true" ]] && enabled_json="true"
            data="{\"period\":{\"since\":\"$since\",\"until\":\"$until\"},\"summary\":{\"total_bans\":$total_bans,\"active_bans\":$active_bans,\"total_countries\":$total_countries},\"breakdown\":{\"temporary\":{\"total\":$total_temp,\"ipv4\":$temp_v4,\"ipv6\":$temp_v6},\"blacklist\":{\"total\":$total_black,\"ipv4\":$black_v4,\"ipv6\":$black_v6},\"feeds\":{\"total\":$total_feed,\"ipv4\":$feed_v4,\"ipv6\":$feed_v6},\"whitelist\":{\"total\":$total_whitelist,\"ipv4\":$whitelist_v4,\"ipv6\":$whitelist_v6}},\"portscan\":{\"monitored_ports\":$portscan_monitored_ports,\"blocked_24h\":$portscan_blocked_24h,\"blocked_total\":$portscan_blocked_total,\"enabled\":$enabled_json},\"top_ips\":$top_ips,\"top_countries\":$top_countries,\"top_jails\":$top_jails}"
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
            --json)
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
            local count=$(echo "$result_data" | { grep -o "}" || true; } | wc -l)
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
            --json)
                json_mode=true
                shift
                ;;
            --detailed)
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
            total=$(echo "$history" | jq '. | length' 2>/dev/null || echo "0")
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
            --json)
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
        tail -f "${NFTBAN_BAN_LOG:-/var/log/nftban/ban.log}" | while IFS='|' read -r timestamp id jail ip reason action timeout; do
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
                local count=$(echo "$activity_data" | { grep -o "}" || true; } | wc -l)
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
# HELP TEXT
# =============================================================================

nftban_stats_cmd_help() {
    cat <<'EOF'
NFTBan Statistics & Metrics

USAGE:
    nftban stats [COMMAND] [OPTIONS]

COMMANDS:
    dashboard              Show comprehensive statistics dashboard (default)
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

EXAMPLES:
    # Show dashboard for last 24 hours
    nftban stats

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
    /var/log/nftban/ban.log            Primary data source

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
