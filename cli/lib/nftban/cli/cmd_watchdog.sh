#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - System Watchdog CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: CLI interface for system watchdog monitoring
#
# meta:name=cmd_watchdog
# meta:type=cli
# meta:header=System Watchdog CLI Handler
# meta:version=1.0.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# meta:created_date=2025-12-17
# meta:updated_date=2025-12-17
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

# Enhanced strict mode
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_CLI_WATCHDOG_LOADED:-}" ]] && return 0
readonly NFTBAN_CLI_WATCHDOG_LOADED=1

# Load the core watchdog module
# shellcheck source=/dev/null
if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_watchdog.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/core/nftban_watchdog.sh"
fi

# =============================================================================
# HELP TEXT
# =============================================================================

nftban_watchdog_help() {
    # Show watchdog help
    cat << 'EOF'
USAGE: nftban watchdog <command> [options]

COMMANDS:
  status           Quick one-line status
  check            Run all checks and show alerts only
  report           Full detailed report (like DirectAdmin alert)
  trend            Show 7-day trend analysis with averages
  history          Show saved reports for auditing
  enable           Enable watchdog timer (auto-monitoring)
  disable          Disable watchdog timer
  help             Show this help message

OPTIONS:
  --json           Output in JSON format (for status, check)
  --last=N         Show last N reports (for history, default: 10)
  --format=FORMAT  Output format: text, json (for history)

EXAMPLES:
  nftban watchdog status         # Quick status check
  nftban watchdog check          # Run checks, show alerts
  nftban watchdog report         # Full report with all metrics
  nftban watchdog history        # Last 10 reports
  nftban watchdog history --last=24
  nftban watchdog enable         # Enable auto-monitoring

WHAT WATCHDOG MONITORS:
  - Load Average     (from /proc/loadavg)
  - Memory Usage     (from /proc/meminfo)
  - Swap Usage       (from /proc/meminfo)
  - I/O Wait %       (from /proc/stat)
  - Disk Usage       (df on /var/log)
  - File Descriptors (from /proc/sys/fs/file-nr)
  - Top Processes    (CPU and memory consumers)

CONFIGURATION:
  Config file: /etc/nftban/conf.d/watchdog.conf
  Reports dir: /var/lib/nftban/reports/watchdog/
  Metrics:     /var/lib/nftban/metrics/watchdog.prom

EOF
}

# =============================================================================
# STATUS COMMAND
# =============================================================================

nftban_watchdog_cmd_status() {
    # Quick one-line status
    local json_mode=false
    [[ "${1:-}" == "--json" ]] && json_mode=true

    # Check if enabled
    local enabled="${NFTBAN_WATCHDOG_ENABLED:-false}"

    # Run quick checks
    nftban_watchdog_run_all >/dev/null 2>&1

    local load="${WATCHDOG_RESULTS[load_5m]:-N/A}"
    local mem="${WATCHDOG_RESULTS[mem_used_percent]:-N/A}"
    local iowait="${WATCHDOG_RESULTS[cpu_iowait_percent]:-N/A}"
    local disk="${WATCHDOG_RESULTS[disk_used_percent]:-N/A}"
    local status="${WATCHDOG_RESULTS[overall_status]:-0}"

    local status_text="OK"
    [[ "$status" == "1" ]] && status_text="WARNING"
    [[ "$status" == "2" ]] && status_text="CRITICAL"

    if [[ "$json_mode" == "true" ]]; then
        cat << EOF
{
  "enabled": $([[ "$enabled" == "true" ]] && echo "true" || echo "false"),
  "status": "$status_text",
  "load_5m": "$load",
  "memory_percent": "$mem",
  "iowait_percent": "$iowait",
  "disk_percent": "$disk",
  "alerts_count": ${#WATCHDOG_ALERTS[@]}
}
EOF
    else
        # Color coding
        local color_reset="\033[0m"
        local color_green="\033[32m"
        local color_yellow="\033[33m"
        local color_red="\033[31m"

        local status_color="$color_green"
        [[ "$status_text" == "WARNING" ]] && status_color="$color_yellow"
        [[ "$status_text" == "CRITICAL" ]] && status_color="$color_red"

        local enabled_text="disabled"
        [[ "$enabled" == "true" ]] && enabled_text="enabled"

        printf "Watchdog: %b%s%b | Load: %s | Mem: %s%% | I/O Wait: %s%% | Disk: %s%% | Timer: %s\n" \
            "$status_color" "$status_text" "$color_reset" \
            "$load" "$mem" "$iowait" "$disk" "$enabled_text"
    fi
}

# =============================================================================
# CHECK COMMAND
# =============================================================================

nftban_watchdog_cmd_check() {
    # Run all checks and show alerts only
    local json_mode=false
    [[ "${1:-}" == "--json" ]] && json_mode=true

    # Run all checks
    nftban_watchdog_run_all

    if [[ "$json_mode" == "true" ]]; then
        # JSON output
        cat << EOF
{
  "status": "${WATCHDOG_RESULTS[overall_status]:-0}",
  "timestamp": "${WATCHDOG_RESULTS[check_datetime]:-$(date '+%Y-%m-%d %H:%M:%S')}",
  "load": {
    "1m": "${WATCHDOG_RESULTS[load_1m]:-0}",
    "5m": "${WATCHDOG_RESULTS[load_5m]:-0}",
    "15m": "${WATCHDOG_RESULTS[load_15m]:-0}",
    "status": "${WATCHDOG_RESULTS[load_status]:-OK}"
  },
  "memory": {
    "used_percent": "${WATCHDOG_RESULTS[mem_used_percent]:-0}",
    "total_mb": "${WATCHDOG_RESULTS[mem_total_mb]:-0}",
    "available_mb": "${WATCHDOG_RESULTS[mem_available_mb]:-0}",
    "status": "${WATCHDOG_RESULTS[mem_status]:-OK}"
  },
  "iowait": {
    "percent": "${WATCHDOG_RESULTS[cpu_iowait_percent]:-0}",
    "status": "${WATCHDOG_RESULTS[iowait_status]:-OK}"
  },
  "disk": {
    "path": "${WATCHDOG_RESULTS[disk_path]:-/var/log}",
    "used_percent": "${WATCHDOG_RESULTS[disk_used_percent]:-0}",
    "status": "${WATCHDOG_RESULTS[disk_status]:-OK}"
  },
  "alerts_count": ${#WATCHDOG_ALERTS[@]}
}
EOF
    else
        # Text output - show alerts only if any
        if [[ ${#WATCHDOG_ALERTS[@]} -eq 0 ]]; then
            echo "Watchdog check completed: OK (no alerts)"
        else
            echo "Watchdog check completed with ${#WATCHDOG_ALERTS[@]} alert(s):"
            echo ""
            for alert in "${WATCHDOG_ALERTS[@]}"; do
                echo "  $alert"
            done
        fi
    fi

    return "${WATCHDOG_RESULTS[overall_status]:-0}"
}

# =============================================================================
# REPORT COMMAND
# =============================================================================

nftban_watchdog_cmd_report() {
    # Full detailed report
    local save_report=false

    # Parse args
    for arg in "$@"; do
        [[ "$arg" == "--save" ]] && save_report=true
    done

    # Run all checks
    nftban_watchdog_run_all

    # Print report
    nftban_watchdog_report

    # Save if requested or if there are alerts
    if [[ "$save_report" == "true" || ${#WATCHDOG_ALERTS[@]} -gt 0 ]]; then
        local report_file
        report_file=$(nftban_watchdog_report_save)
        echo "Report saved to: $report_file"
    fi

    # Export metrics
    nftban_watchdog_metrics_export

    return "${WATCHDOG_RESULTS[overall_status]:-0}"
}

# =============================================================================
# HISTORY COMMAND
# =============================================================================

nftban_watchdog_cmd_history() {
    # Show saved reports for auditing
    local last_count=10
    local format="text"

    # Parse args
    for arg in "$@"; do
        case "$arg" in
            --last=*) last_count="${arg#--last=}" ;;
            --format=*) format="${arg#--format=}" ;;
        esac
    done

    local report_dir="${NFTBAN_WATCHDOG_REPORT_DIR:-/var/lib/nftban/reports/watchdog}"

    if [[ ! -d "$report_dir" ]]; then
        echo "No reports found (directory does not exist: $report_dir)"
        return 0
    fi

    # Get list of reports
    local -a reports
    mapfile -t reports < <(find "$report_dir" -name "*.report" -type f 2>/dev/null | sort -r | head -"$last_count")

    if [[ ${#reports[@]} -eq 0 ]]; then
        echo "No reports found in $report_dir"
        return 0
    fi

    if [[ "$format" == "json" ]]; then
        echo "["
        local first=true
        for report in "${reports[@]}"; do
            local filename
            filename=$(basename "$report")
            local timestamp="${filename%.report}"
            local size
            size=$(stat -c %s "$report" 2>/dev/null || echo 0)

            [[ "$first" == "true" ]] || echo ","
            first=false

            printf '  {"file": "%s", "timestamp": "%s", "size": %d}' "$report" "$timestamp" "$size"
        done
        echo ""
        echo "]"
    else
        echo "Watchdog Reports (last $last_count):"
        echo "=============================================="
        printf "%-25s  %8s  %s\n" "TIMESTAMP" "SIZE" "PATH"
        echo "----------------------------------------------"

        for report in "${reports[@]}"; do
            local filename
            filename=$(basename "$report")
            local timestamp="${filename%.report}"
            local size
            size=$(stat -c %s "$report" 2>/dev/null || echo 0)

            # Convert size to human-readable
            local size_hr
            if [[ $size -gt 1048576 ]]; then
                size_hr="$((size / 1048576)) MB"
            elif [[ $size -gt 1024 ]]; then
                size_hr="$((size / 1024)) KB"
            else
                size_hr="$size B"
            fi

            printf "%-25s  %8s  %s\n" "$timestamp" "$size_hr" "$report"
        done

        echo ""
        echo "To view a report: cat /var/lib/nftban/reports/watchdog/<timestamp>.report"
    fi
}

# =============================================================================
# ENABLE/DISABLE COMMANDS
# =============================================================================

nftban_watchdog_cmd_enable() {
    # Enable watchdog timer

    echo "Enabling NFTBan Watchdog..."

    # Check if timer exists
    if ! systemctl list-unit-files nftban-watchdog.timer >/dev/null 2>&1; then
        echo "Error: nftban-watchdog.timer not found"
        echo "The watchdog timer needs to be installed first."
        return 1
    fi

    # Enable and start the timer
    if systemctl enable nftban-watchdog.timer 2>/dev/null; then
        echo "  Timer enabled"
    else
        echo "  Warning: Could not enable timer"
    fi

    if systemctl start nftban-watchdog.timer 2>/dev/null; then
        echo "  Timer started"
    else
        echo "  Warning: Could not start timer"
    fi

    # Update config file to set ENABLED=true
    local conf_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/watchdog.conf"
    if [[ -f "$conf_file" ]]; then
        if grep -q "^NFTBAN_WATCHDOG_ENABLED=" "$conf_file"; then
            sed -i 's/^NFTBAN_WATCHDOG_ENABLED=.*/NFTBAN_WATCHDOG_ENABLED="true"/' "$conf_file"
        else
            echo 'NFTBAN_WATCHDOG_ENABLED="true"' >> "$conf_file"
        fi
        echo "  Config updated: $conf_file"
    fi

    echo ""
    echo "Watchdog enabled. Checks will run every 90 seconds."
    echo "View status: nftban watchdog status"

    # Show timer status
    systemctl status nftban-watchdog.timer --no-pager 2>/dev/null || true
}

nftban_watchdog_cmd_disable() {
    # Disable watchdog timer

    echo "Disabling NFTBan Watchdog..."

    # Stop and disable the timer
    if systemctl stop nftban-watchdog.timer 2>/dev/null; then
        echo "  Timer stopped"
    fi

    if systemctl disable nftban-watchdog.timer 2>/dev/null; then
        echo "  Timer disabled"
    fi

    # Update config file to set ENABLED=false
    local conf_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/watchdog.conf"
    if [[ -f "$conf_file" ]]; then
        if grep -q "^NFTBAN_WATCHDOG_ENABLED=" "$conf_file"; then
            sed -i 's/^NFTBAN_WATCHDOG_ENABLED=.*/NFTBAN_WATCHDOG_ENABLED="false"/' "$conf_file"
        fi
        echo "  Config updated: $conf_file"
    fi

    echo ""
    echo "Watchdog disabled."
}

# =============================================================================
# TREND COMMAND
# =============================================================================

nftban_watchdog_cmd_trend() {
    # Display system resource trends (7-day rolling history)
    # Usage: nftban watchdog trend [--json]

    local json_mode=0

    for arg in "$@"; do
        [[ "$arg" == "--json" ]] && json_mode=1
    done

    # Ensure trend functions are available
    if ! declare -f nftban_watchdog_trend_display >/dev/null 2>&1; then
        echo "ERROR: Trend functions not loaded" >&2
        return 1
    fi

    if [[ $json_mode -eq 1 ]]; then
        nftban_watchdog_trend_display --json
    else
        nftban_watchdog_trend_display
    fi
}

# =============================================================================
# MAIN CLI HANDLER
# =============================================================================

nftban_cmd_watchdog() {
    # Main watchdog command handler
    # Args: subcommand [options]

    local subcommand="${1:-status}"
    shift || true

    # Load output module (for help banner)
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"
    fi

    case "$subcommand" in
        status)
            nftban_watchdog_cmd_status "$@"
            ;;
        check)
            nftban_watchdog_cmd_check "$@"
            ;;
        report)
            nftban_watchdog_cmd_report "$@"
            ;;
        history)
            nftban_watchdog_cmd_history "$@"
            ;;
        enable)
            nftban_watchdog_cmd_enable "$@"
            ;;
        disable)
            nftban_watchdog_cmd_disable "$@"
            ;;
        trend)
            nftban_watchdog_cmd_trend "$@"
            ;;
        help|--help|-h)
            nftban_watchdog_help
            ;;
        *)
            echo "Unknown command: $subcommand"
            echo ""
            nftban_watchdog_help
            return 1
            ;;
    esac
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_cmd_watchdog
