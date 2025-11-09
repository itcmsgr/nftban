#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.32.22 - Statistics CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: CLI interface for statistics and metrics
#
# meta:name=cmd_stats
# meta:type=cli
# meta:header=Statistics CLI Handler
# meta:version=0.32.22
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
# =============================================================================

# Enhanced strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_CLI_STATS_LOADED:-}" ]] && return 0
readonly NFTBAN_CLI_STATS_LOADED=1

# =============================================================================
# LOAD DEPENDENCIES
# =============================================================================

# Load stats core module
if ! declare -f nftban_stats_generate_dashboard >/dev/null 2>&1; then
    if [[ -f "/usr/lib/nftban/core/nftban_stats.sh" ]]; then
        source "/usr/lib/nftban/core/nftban_stats.sh" || {
            echo "ERROR: Failed to load stats core module" >&2
            return 1
        }
    else
        echo "ERROR: Stats module not found: /usr/lib/nftban/core/nftban_stats.sh" >&2
        return 1
    fi
fi

# Load path security module
if ! declare -f nftban_path_get_safe_output >/dev/null 2>&1; then
    if [[ -f "/usr/lib/nftban/core/nftban_path_security.sh" ]]; then
        source "/usr/lib/nftban/core/nftban_path_security.sh" || {
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
    # Usage: nftban stats [dashboard] [--since DATE] [--until DATE] [--last PERIOD]

    local since=""
    local until=""
    local detailed=false

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
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
                        echo "ERROR: Invalid period format. Use: 24h, 7d, 30d, etc." >&2
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
                echo "ERROR: Unknown option: $1" >&2
                return 1
                ;;
        esac
    done

    # Set defaults if not specified
    [[ -z "$since" ]] && since="$(date -d '24 hours ago' +%Y-%m-%d)"
    [[ -z "$until" ]] && until="$(date +%Y-%m-%d)"

    # Generate dashboard
    nftban_stats_generate_dashboard "$since" "$until"
}

# =============================================================================
# SUBCOMMAND: TOP
# =============================================================================

nftban_stats_cmd_top() {
    # Show top lists (IPs, countries, jails)
    # Usage: nftban stats top [ips|countries|jails] [LIMIT]

    local type="${1:-ips}"
    local limit="${2:-${STATS_TOP_N:-10}}"
    local since
    since="$(date -d '30 days ago' +%Y-%m-%d)"
    local until
    until="$(date +%Y-%m-%d)"

    # Parse additional options
    shift 2 2>/dev/null || shift $# 2>/dev/null || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
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
    # Usage: nftban stats ip <IP> [--detailed]

    local ip="${1:-}"

    if [[ -z "$ip" ]]; then
        echo "ERROR: IP address required" >&2
        echo "Usage: nftban stats ip <IP>" >&2
        return 1
    fi

    shift
    local detailed=false
    [[ "${1:-}" == "--detailed" ]] && detailed=true

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

    # Get history
    local history
    history=$(nftban_stats_ip_history "$ip")

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
    # Usage: nftban stats recent [LIMIT] [--follow]

    local limit="${1:-20}"
    local follow=false

    shift || true
    [[ "${1:-}" == "--follow" ]] && follow=true

    if [[ "$follow" == "true" ]]; then
        # Tail mode
        echo "Following ban log (Ctrl+C to exit)..."
        echo ""
        tail -f "$NFTBAN_BAN_LOG" | while IFS='|' read -r timestamp id jail ip reason action timeout; do
            printf "[%s] %s | %-16s | %-12s | %s\n" \
                "$(date +%H:%M:%S)" "$timestamp" "$ip" "$action" "$jail"
        done
    else
        # Show recent
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
    if [[ -n "$output" ]]; then
        echo "[SECURITY] Output path validation enabled - only approved directories allowed" >&2
        echo "[INFO] Approved locations: /var/lib/nftban/* (reports, metrics, exports)" >&2
    fi

    case "$format" in
        json)
            local safe_output
            safe_output=$(nftban_path_get_safe_output "$output" "/var/lib/nftban/exports" "$allow_unsafe" ".json") || return 1
            nftban_stats_export_json "$safe_output" "$since" "$until"
            ;;
        csv)
            local safe_output
            safe_output=$(nftban_path_get_safe_output "$output" "/var/lib/nftban/exports" "$allow_unsafe" ".csv") || return 1
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

export -f nftban_cmd_stats

# =============================================================================
# MODULE INITIALIZATION
# =============================================================================

# CLI module loaded
if type -t nftban_print_status >/dev/null 2>&1; then
    nftban_print_status "debug" "Stats CLI loaded"
fi
