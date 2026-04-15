#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - System Watchdog CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cmd_watchdog"
# meta:type="cli"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2025-12-17"
# meta:description="CLI interface for system watchdog monitoring"
# meta:input="Command line options (status)"
# meta:output="Watchdog status and health information"
# meta:depends="bash,systemctl"
# meta:platform="linux"
# meta:inventory.files=""
# meta:inventory.binaries="systemctl"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units="nftban-watchdog.service"
# meta:inventory.network=""
# meta:inventory.privileges="root"
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

# Enhanced strict mode
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_CLI_WATCHDOG_LOADED:-}" ]] && return 0
readonly NFTBAN_CLI_WATCHDOG_LOADED=1

# Load the core watchdog module
# shellcheck source=/dev/null
if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_watchdog.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/core/nftban_watchdog.sh" || return 1
fi

# Load pipeline validation library
# shellcheck source=/dev/null
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_pipeline_validation.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_pipeline_validation.sh" || return 1
fi

# =============================================================================
# HELP TEXT
# =============================================================================

nftban_watchdog_help() {
    # Show watchdog help
    cat << 'EOF'
USAGE: nftban watchdog <command> [options]

COMMANDS:
  status           Tiered status (auto-detects best format)
  check            Run all checks and show alerts only
  run              Execute watchdog cycle (used by systemd timer)
  report           Full detailed report
  trend            Show 7-day trend analysis with averages
  trends           Show JSONL trend log (per-cycle data)
  history          Show saved reports for auditing
  enable           Enable watchdog timer (auto-monitoring)
  disable          Disable watchdog timer
  help             Show this help message

DAEMON STATS COMMANDS:
  stats            Show daemon runtime stats (memory, goroutines, IPC)
  stats-history    Show historical daemon stats (daily summaries)
  snapshot         Capture a pprof profile (heap, goroutine, cpu)
  profiles         List captured pprof profiles

STATUS OPTIONS:
  --json           Output in JSON format
  --verbose, -v    Full detailed report
  --summary        10-line summary format
  --journal        1-line format for systemd/scripts

  Default: Terminal gets summary, non-terminal gets journal format.
  If issues detected (CRITICAL or 3+ alerts), auto-shows full report.

GENERAL OPTIONS:
  --last=N         Show last N reports (for history, default: 10)
  --format=FORMAT  Output format: text, json (for history)
  --days=N         Number of days for stats-history (1-30, default: 7)
  --type=TYPE      Profile type for snapshot: heap, goroutine, cpu
  --duration=N     CPU profile duration in seconds (default: 30)

EXAMPLES:
  nftban watchdog status         # Auto-detect best format
  nftban watchdog status --summary   # 10-line summary
  nftban watchdog status --journal   # 1-line for scripts
  nftban watchdog status --verbose   # Full report
  nftban watchdog check          # Run checks, show alerts
  nftban watchdog report         # Full report with all metrics
  nftban watchdog trends --last=100  # Recent JSONL trend data
  nftban watchdog history        # Last 10 saved reports
  nftban watchdog enable         # Enable auto-monitoring

  # Daemon stats examples:
  nftban watchdog stats          # Current daemon stats
  nftban watchdog stats --json   # JSON format
  nftban watchdog stats-history --days=7
  nftban watchdog snapshot --type=heap
  nftban watchdog snapshot --type=cpu --duration=30
  nftban watchdog profiles       # List captured profiles

CAPABILITY MODES:
  LOCAL (always available):
    - Load, Memory, I/O Wait, Disk monitoring
    - Alerts to syslog
    - No external dependencies

  PERFORMANCE (requires metrics pipeline):
    - All LOCAL features plus:
    - 7-day historical trends
    - Prometheus/VictoriaMetrics integration
    - Remote alerting support

  The watchdog auto-detects capability based on pipeline health.
  LOCAL mode always enables immediately; PERFORMANCE requires:
    nftban metrics enable

WHAT WATCHDOG MONITORS:
  - Load Average     (from /proc/loadavg)
  - Memory Usage     (from /proc/meminfo)
  - Swap Usage       (from /proc/meminfo)
  - I/O Wait %       (from /proc/stat)
  - Disk Usage       (df on /var/log)
  - File Descriptors (from /proc/sys/fs/file-nr)
  - Top Processes    (CPU and memory consumers)

DAEMON STATS (from nftband via IPC):
  - Memory usage     (heap, alloc, system)
  - Goroutine count
  - GC cycles/pauses
  - IPC throughput   (requests, latency, errors)
  - Ban/unban rates
  - Module status

CONFIGURATION:
  Config file: /etc/nftban/conf.d/watchdog.conf
  Stats file:  /var/lib/nftban/stats/current.json
  History dir: /var/lib/nftban/stats/history/
  Profile dir: /var/lib/nftban/stats/profiles/
  Reports dir: /var/lib/nftban/reports/watchdog/
  Metrics:     /var/lib/nftban/metrics/watchdog.prom

EOF
}

# =============================================================================
# STATUS COMMAND
# =============================================================================

nftban_watchdog_cmd_status() {
    # Tiered status output
    #
    # Options:
    #   --json      JSON format output
    #   --verbose   Full detailed report
    #   --summary   10-line summary (default for terminal)
    #   --journal   1-line format for systemd/scripts
    #
    # Default behavior (no flags):
    #   - Terminal: 10-line summary (or full if issues detected)
    #   - Non-terminal: 1-line journal format

    local json_mode=false
    local output_tier="auto"

    for arg in "$@"; do
        case "$arg" in
            --json) json_mode=true ;;
            --verbose|-v) output_tier="full" ;;
            --summary) output_tier="summary" ;;
            --journal) output_tier="journal" ;;
        esac
    done

    # Check if enabled
    local enabled="${NFTBAN_WATCHDOG_ENABLED:-false}"

    # Run quick checks (|| true prevents set -e from exiting on WARNING/CRITICAL status)
    nftban_watchdog_run_all >/dev/null 2>&1 || true

    local load="${WATCHDOG_RESULTS[load_5m]:-N/A}"
    local mem="${WATCHDOG_RESULTS[mem_used_percent]:-N/A}"
    local iowait="${WATCHDOG_RESULTS[cpu_iowait_percent]:-N/A}"
    local disk="${WATCHDOG_RESULTS[disk_used_percent]:-N/A}"
    local status="${WATCHDOG_RESULTS[overall_status]:-0}"

    local status_text="PROTECTED"
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
        # Use tiered output based on flags or auto-detect
        case "$output_tier" in
            full)
                nftban_watchdog_report
                ;;
            summary)
                _watchdog_output_summary
                ;;
            journal)
                _watchdog_output_journal
                ;;
            auto)
                # Auto-detect: terminal gets summary, scripts get journal
                if [[ -t 1 ]]; then
                    # Terminal - show summary or full if issues
                    if _watchdog_should_show_full; then
                        nftban_watchdog_report
                    else
                        _watchdog_output_summary
                    fi
                else
                    # Not a terminal (systemd, script) - journal format
                    _watchdog_output_journal
                fi
                ;;
        esac
    fi
}

# =============================================================================
# RUN COMMAND (Called by systemd timer)
# =============================================================================

nftban_watchdog_cmd_run() {
    # Main entry point for systemd timer execution
    # Runs all checks with proper conditional save logic:
    # - Reports saved ONLY if issues detected (status > 0)
    # - JSONL trends appended EVERY cycle
    # - Prometheus metrics exported EVERY cycle
    #
    # Options:
    #   --verbose    Show full report output
    #   --summary    Show summary output
    #   --journal    Show journal-style output (default for timer)
    #   --silent     No output (metrics/trends still recorded)

    local output_tier="silent"

    for arg in "$@"; do
        case "$arg" in
            --verbose|-v) output_tier="full" ;;
            --summary) output_tier="summary" ;;
            --journal) output_tier="journal" ;;
            --silent) output_tier="silent" ;;
        esac
    done

    # Ensure trends directory exists before running
    local trends_dir="${NFTBAN_LOG_DIR:-/var/log/nftban}/watchdog"
    mkdir -p "$trends_dir" 2>/dev/null || true
    chown nftban:nftban "$trends_dir" 2>/dev/null || true
    chmod 750 "$trends_dir" 2>/dev/null || true

    # Call the core run function which handles:
    # - Running all checks
    # - Saving report ONLY if status > 0
    # - Exporting Prometheus metrics
    # - Appending JSONL trends
    # - Cleanup of old reports
    nftban_watchdog_run "$output_tier"
}

# =============================================================================
# CHECK COMMAND
# =============================================================================

nftban_watchdog_cmd_check() {
    # Run all checks and show alerts only
    local json_mode=false
    [[ "${1:-}" == "--json" ]] && json_mode=true

    # Run all checks (|| true prevents set -e from exiting on WARNING/CRITICAL status)
    nftban_watchdog_run_all || true

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
        [[ "$arg" == "--save" ]] && save_report=true || true
    done

    # Run all checks (|| true prevents set -e from exiting on WARNING/CRITICAL status)
    nftban_watchdog_run_all || true

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

    # Append to JSONL trend log (every cycle for trend analysis)
    _watchdog_append_trend

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
    # Enable watchdog timer with smart capability detection
    # LOCAL capability always enables immediately
    # PERF capability requires metrics pipeline

    echo "Enabling NFTBan Watchdog..."
    echo ""

    # Check if timer exists
    if ! systemctl list-unit-files nftban-watchdog.timer >/dev/null 2>&1; then
        echo "ERROR: nftban-watchdog.timer not found" >&2
        echo "The watchdog timer needs to be installed first."
        return 1
    fi

    # ==========================================================================
    # CAPABILITY DETECTION
    # ==========================================================================
    local capability="local"
    local pipeline_status=0

    # Check if validation library is loaded
    if declare -f nftban_detect_watchdog_capability &>/dev/null; then
        capability=$(nftban_detect_watchdog_capability false)
        nftban_pipeline_status false
        pipeline_status=$?
    fi

    echo "Detected capability: ${capability^^}"

    # ==========================================================================
    # SMART BEHAVIOR: LOCAL always enables, PERF offers metrics prompt
    # ==========================================================================
    if [[ "$capability" == "local" ]]; then
        # Check if perf deps are available but just not running
        if declare -f nftban_check_perf_deps_available &>/dev/null; then
            if nftban_check_perf_deps_available; then
                # Deps available - suggest enabling metrics
                echo ""
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "  Performance monitoring available"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                echo "  Metrics infrastructure is installed but not running."
                echo "  Enable it for historical trends and remote alerting:"
                echo ""
                echo "    nftban metrics enable"
                echo ""
                echo "  Continuing with LOCAL watchdog (always works)..."
                echo ""
            else
                # Deps not installed - single prompt offer
                echo ""
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "  Optional: Enable performance monitoring"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                echo "  LOCAL watchdog provides:"
                echo "    - Load, Memory, I/O Wait, Disk monitoring"
                echo "    - Alerts to syslog"
                echo ""
                echo "  PERFORMANCE monitoring adds:"
                echo "    - 7-day historical trends"
                echo "    - Prometheus/VictoriaMetrics integration"
                echo "    - Remote alerting support"
                echo ""
                echo "  Missing: ${NFTBAN_PERF_DEPS_MISSING[*]:-metrics backend}"
                echo ""
                echo "  To enable performance monitoring later:"
                echo "    nftban metrics enable"
                echo ""
                echo "  Continuing with LOCAL watchdog (always works)..."
                echo ""
            fi
        fi
    else
        # PERF capability available
        echo "  Metrics pipeline: $([ $pipeline_status -eq 2 ] && echo "PROTECTED" || echo "DEGRADED")"
        echo ""
    fi

    # ==========================================================================
    # ENABLE WATCHDOG (never blocked for LOCAL)
    # ==========================================================================
    echo "Enabling watchdog timer..."

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
    mkdir -p "$(dirname "$conf_file")" 2>/dev/null || true
    if [[ -f "$conf_file" ]]; then
        if grep -q "^NFTBAN_WATCHDOG_ENABLED=" "$conf_file"; then
            sed -i 's/^NFTBAN_WATCHDOG_ENABLED=.*/NFTBAN_WATCHDOG_ENABLED="true"/' "$conf_file"
        else
            echo 'NFTBAN_WATCHDOG_ENABLED="true"' >> "$conf_file"
        fi
    else
        echo 'NFTBAN_WATCHDOG_ENABLED="true"' > "$conf_file"
    fi
    echo "  Config updated: $conf_file"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Watchdog enabled (${capability^^} mode)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Checks run every 90 seconds"
    echo "  View status: nftban watchdog status"
    echo "  Full report: nftban watchdog report"
    echo ""

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
# DAEMON STATS COMMANDS (via IPC)
# =============================================================================

# Helper: Call daemon via Unix socket
_watchdog_ipc_call() {
    local method="$1"
    local params="${2:-{}}"
    local socket_path="${NFTBAN_RUN_DIR:-/run/nftban}/nftband.sock"

    if [[ ! -S "$socket_path" ]]; then
        printf '{"success":false,"error":"daemon not running (socket not found)"}'
        return 1
    fi

    # Send JSON request, receive JSON response
    echo "{\"method\":\"$method\",\"params\":$params}" | \
        timeout 30 socat - "UNIX-CONNECT:$socket_path" 2>/dev/null
}

nftban_watchdog_cmd_stats() {
    # Show daemon runtime stats
    local json_mode=false

    for arg in "$@"; do
        [[ "$arg" == "--json" ]] && json_mode=true || true
    done

    local response
    response=$(_watchdog_ipc_call "stats" "{}")

    if [[ -z "$response" ]]; then
        echo "ERROR: No response from daemon" >&2
        return 1
    fi

    # Check for error
    local success
    success=$(echo "$response" | jq -r '.success // false')
    if [[ "$success" != "true" ]]; then
        local error
        error=$(echo "$response" | jq -r '.error // "unknown error"')
        echo "ERROR: $error" >&2
        return 1
    fi

    if [[ "$json_mode" == "true" ]]; then
        echo "$response" | jq '.data'
    else
        # Human-readable format - extract all values in single jq call (18 jq -> 1)
        local stats_output
        stats_output=$(echo "$response" | jq -r '.data | [
            .daemon.version // "N/A",
            (.daemon.uptime_seconds // 0 | tostring),
            .daemon.pid // "N/A",
            .health // "N/A",
            (.runtime.memory_heap_mb // 0 | tostring),
            (.runtime.memory_sys_mb // 0 | tostring),
            (.runtime.goroutines // 0 | tostring),
            (.runtime.gc_cycles // 0 | tostring),
            (.runtime.gc_pause_ms // 0 | tostring),
            (.throughput.bans_total // 0 | tostring),
            (.throughput.unbans_total // 0 | tostring),
            (.throughput.events_total // 0 | tostring),
            (.throughput.bans_per_min // 0 | tostring),
            (.ipc.requests_total // 0 | tostring),
            (.ipc.avg_latency_ms // 0 | tostring),
            (.ipc.errors_total // 0 | tostring),
            (.alerts | length // 0 | tostring)
        ] | @tsv')

        # Parse tab-separated values
        local version uptime pid health heap_mem sys_mem goroutines gc_cycles gc_pause
        local bans_total unbans_total events_total bans_per_min
        local ipc_requests ipc_latency ipc_errors alert_count
        IFS=$'\t' read -r version uptime pid health heap_mem sys_mem goroutines gc_cycles gc_pause \
            bans_total unbans_total events_total bans_per_min \
            ipc_requests ipc_latency ipc_errors alert_count <<< "$stats_output"

        echo "NFTBan Daemon Stats"
        echo "==================="
        echo ""
        echo "Daemon:"
        echo "  Version:     $version"
        echo "  Uptime:      $uptime seconds"
        echo "  PID:         $pid"
        echo "  Health:      $health"
        echo ""
        echo "Runtime:"
        printf "  Heap Memory: %.2f MB\n" "$heap_mem"
        printf "  Sys Memory:  %.2f MB\n" "$sys_mem"
        echo "  Goroutines:  $goroutines"
        echo "  GC Cycles:   $gc_cycles"
        printf "  GC Pause:    %.2f ms\n" "$gc_pause"
        echo ""
        echo "Throughput:"
        echo "  Bans Total:   $bans_total"
        echo "  Unbans Total: $unbans_total"
        echo "  Events Total: $events_total"
        printf "  Bans/min:    %.2f\n" "$bans_per_min"
        echo ""
        echo "IPC:"
        echo "  Requests:    $ipc_requests"
        printf "  Avg Latency: %.2f ms\n" "$ipc_latency"
        echo "  Errors:      $ipc_errors"

        # Show alerts if any (requires second jq call only when alerts exist)
        if [[ "${alert_count:-0}" -gt 0 ]]; then
            echo ""
            echo "Alerts ($alert_count):"
            echo "$response" | jq -r '.data.alerts[] | "  [\(.level)] \(.type): \(.message)"'
        fi
    fi
}

nftban_watchdog_cmd_stats_history() {
    # Show historical daemon stats
    local days=7
    local json_mode=false

    for arg in "$@"; do
        case "$arg" in
            --days=*) days="${arg#--days=}" ;;
            --json) json_mode=true ;;
        esac
    done

    local response
    response=$(_watchdog_ipc_call "stats_history" "{\"days\":$days}")

    if [[ -z "$response" ]]; then
        echo "ERROR: No response from daemon" >&2
        return 1
    fi

    local success
    success=$(echo "$response" | jq -r '.success // false')
    if [[ "$success" != "true" ]]; then
        local error
        error=$(echo "$response" | jq -r '.error // "unknown error"')
        echo "ERROR: $error" >&2
        return 1
    fi

    if [[ "$json_mode" == "true" ]]; then
        echo "$response" | jq '.data'
    else
        local history
        history=$(echo "$response" | jq '.data.history')
        local count
        count=$(echo "$history" | jq 'length')

        if [[ "$count" -eq 0 ]]; then
            echo "No historical data available (daemon may have just started)"
            return 0
        fi

        echo "Daemon Stats History (last $days days)"
        echo "======================================="
        echo ""
        printf "%-12s  %8s  %8s  %10s  %10s  %8s\n" \
            "DATE" "BANS" "UNBANS" "PEAK_MEM" "PEAK_GOR" "ALERTS"
        echo "------------------------------------------------------------------------"

        echo "$history" | jq -r '.[] | "\(.date)  \(.total_bans)  \(.total_unbans)  \(.peak_memory_mb)  \(.peak_goroutines)  \(.warning_count + .critical_count)"' | \
        while read -r line; do
            # $line intentionally unquoted for printf field splitting
            # shellcheck disable=SC2086
            printf "%-12s  %8s  %8s  %8.1f MB  %10s  %8s\n" $line
        done
    fi
}

nftban_watchdog_cmd_snapshot() {
    # Trigger a pprof profile capture
    local profile_type="heap"
    local duration=30

    for arg in "$@"; do
        case "$arg" in
            --type=*) profile_type="${arg#--type=}" ;;
            --duration=*) duration="${arg#--duration=}" ;;
        esac
    done

    # Validate type
    case "$profile_type" in
        heap|goroutine|cpu) ;;
        *)
            echo "ERROR: Invalid profile type '$profile_type'" >&2
            echo "Valid types: heap, goroutine, cpu"
            return 1
            ;;
    esac

    echo "Capturing $profile_type profile..."
    [[ "$profile_type" == "cpu" ]] && echo "  Duration: ${duration}s (CPU profiling is async)"

    local response
    response=$(_watchdog_ipc_call "snapshot_profile" "{\"type\":\"$profile_type\",\"duration\":$duration}")

    if [[ -z "$response" ]]; then
        echo "ERROR: No response from daemon" >&2
        return 1
    fi

    local success
    success=$(echo "$response" | jq -r '.success // false')
    if [[ "$success" != "true" ]]; then
        local error
        error=$(echo "$response" | jq -r '.error // "unknown error"')
        echo "ERROR: $error" >&2
        return 1
    fi

    local path
    path=$(echo "$response" | jq -r '.data.path // "unknown"')
    local filename
    filename=$(echo "$response" | jq -r '.data.filename // "unknown"')

    echo ""
    echo "Profile captured successfully!"
    echo "  Type:     $profile_type"
    echo "  File:     $filename"
    echo "  Path:     $path"
    echo ""
    echo "Analyze with:"
    echo "  go tool pprof $path"
}

nftban_watchdog_cmd_profiles() {
    # List captured pprof profiles
    local profile_dir="${NFTBAN_WATCHDOG_PROFILE_DIR:-${NFTBAN_DATA_DIR:-/var/lib/nftban}/stats/profiles}"
    local json_mode=false

    for arg in "$@"; do
        [[ "$arg" == "--json" ]] && json_mode=true || true
    done

    if [[ ! -d "$profile_dir" ]]; then
        echo "No profiles directory: $profile_dir"
        return 0
    fi

    local -a profiles
    mapfile -t profiles < <(find "$profile_dir" -name "*.pprof" -type f 2>/dev/null | sort -r)

    if [[ ${#profiles[@]} -eq 0 ]]; then
        echo "No profiles found in $profile_dir"
        echo ""
        echo "Capture a profile with: nftban watchdog snapshot --type=heap"
        return 0
    fi

    if [[ "$json_mode" == "true" ]]; then
        echo "["
        local first=true
        for profile in "${profiles[@]}"; do
            local filename size mtime
            filename=$(basename "$profile")
            size=$(stat -c %s "$profile" 2>/dev/null || echo 0)
            mtime=$(stat -c %Y "$profile" 2>/dev/null || echo 0)

            [[ "$first" == "true" ]] || echo ","
            first=false

            printf '  {"file": "%s", "path": "%s", "size": %d, "mtime": %d}' \
                "$filename" "$profile" "$size" "$mtime"
        done
        echo ""
        echo "]"
    else
        echo "Captured Profiles"
        echo "================="
        echo "Directory: $profile_dir"
        echo ""
        printf "%-35s  %10s  %s\n" "FILENAME" "SIZE" "CREATED"
        echo "--------------------------------------------------------------------"

        for profile in "${profiles[@]}"; do
            local filename size mtime_fmt
            filename=$(basename "$profile")
            size=$(stat -c %s "$profile" 2>/dev/null || echo 0)
            mtime_fmt=$(stat -c %y "$profile" 2>/dev/null | cut -d. -f1)

            # Human-readable size
            local size_hr
            if [[ $size -gt 1048576 ]]; then
                size_hr="$(awk "BEGIN {printf \"%.1f\", $size/1048576}") MB"
            elif [[ $size -gt 1024 ]]; then
                size_hr="$(awk "BEGIN {printf \"%.1f\", $size/1024}") KB"
            else
                size_hr="$size B"
            fi

            printf "%-35s  %10s  %s\n" "$filename" "$size_hr" "$mtime_fmt"
        done

        echo ""
        echo "Analyze with: go tool pprof <path>"
    fi
}

# =============================================================================
# TREND COMMAND
# =============================================================================

nftban_watchdog_cmd_trend() {
    # Display system resource trends (7-day rolling history)
    # Usage: nftban watchdog trend [--json]

    local json_mode=0

    for arg in "$@"; do
        [[ "$arg" == "--json" ]] && json_mode=1 || true
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
# TRENDS COMMAND (JSONL per-cycle data)
# =============================================================================

nftban_watchdog_cmd_trends() {
    # View JSONL trend log (per-cycle data)
    #
    # Options:
    #   --last=N     Show last N entries (default: 50)
    #   --json       Output raw JSON lines
    #   --stats      Show statistics summary
    #   --follow     Follow log in real-time (like tail -f)

    local last_count=50
    local raw_json=false
    local show_stats=false
    local follow_mode=false

    for arg in "$@"; do
        case "$arg" in
            --last=*) last_count="${arg#--last=}" ;;
            --json) raw_json=true ;;
            --stats) show_stats=true ;;
            --follow|-f) follow_mode=true ;;
        esac
    done

    local trends_file="${NFTBAN_WATCHDOG_TRENDS_JSONL:-/var/log/nftban/watchdog/trends.jsonl}"

    if [[ ! -f "$trends_file" ]]; then
        echo "No JSONL trend data found: $trends_file"
        echo ""
        echo "Trend data is recorded after each watchdog cycle."
        echo "Enable watchdog: nftban watchdog enable"
        return 0
    fi

    if [[ "$follow_mode" == "true" ]]; then
        echo "Following $trends_file (Ctrl+C to stop)..."
        tail -f "$trends_file"
        return
    fi

    if [[ "$show_stats" == "true" ]]; then
        # Show statistics from the JSONL data
        if ! command -v jq &>/dev/null; then
            echo "ERROR: jq is required for --stats" >&2
            return 1
        fi

        local line_count
        line_count=$(wc -l < "$trends_file")

        echo "JSONL Trend Statistics"
        echo "═══════════════════════════════════════════════════════════════"
        echo "File: $trends_file"
        echo "Total entries: $line_count"
        echo ""

        # Calculate stats using jq
        # Read last N lines and aggregate
        tail -n "$last_count" "$trends_file" | jq -s '
            if length == 0 then
                {"error": "No data"}
            else
                {
                    "entries": length,
                    "first_ts": (.[0].ts // "N/A"),
                    "last_ts": (.[-1].ts // "N/A"),
                    "mode_counts": (group_by(.mode) | map({key: .[0].mode, value: length}) | from_entries),
                    "cpu": {
                        "avg": ([.[].cpu] | add / length | floor),
                        "min": ([.[].cpu] | min),
                        "max": ([.[].cpu] | max)
                    },
                    "mem": {
                        "avg": ([.[].mem] | add / length | floor),
                        "min": ([.[].mem] | min),
                        "max": ([.[].mem] | max)
                    },
                    "io": {
                        "avg": ([.[].io] | add / length | . * 10 | floor / 10),
                        "min": ([.[].io] | min),
                        "max": ([.[].io] | max)
                    },
                    "total_actions": ([.[].actions] | add)
                }
            end
        '
        return
    fi

    if [[ "$raw_json" == "true" ]]; then
        # Output raw JSON lines
        tail -n "$last_count" "$trends_file"
    else
        # Formatted output
        echo "Recent Watchdog Trends (last $last_count entries)"
        echo "═══════════════════════════════════════════════════════════════"
        echo "STATUS: OK=protected  WARN=degraded  CRIT=down"
        echo ""
        printf "%-25s  %-8s  %5s  %5s  %5s  %7s\n" "TIMESTAMP" "STATUS" "CPU%" "MEM%" "IO%" "ACTIONS"
        echo "───────────────────────────────────────────────────────────────"

        if command -v jq &>/dev/null; then
            tail -n "$last_count" "$trends_file" | jq -r '
                [(.ts | split("T") | .[0] + " " + (.[1] | split("+")[0] | split(".")[0])),
                 ({"normal":"OK","degraded":"WARN","critical":"CRIT"}[.mode] // .mode),
                 .cpu, .mem, .io, .actions] | @csv
            ' 2>/dev/null | awk -F',' '{gsub(/"/, ""); printf "%-25s  %-8s  %5s  %5s  %5s  %7s\n", $1, $2, $3, $4, $5, $6}' || {
                echo "(jq parse error - showing raw data)"
                tail -n "$last_count" "$trends_file"
            }
        else
            # Fallback without jq
            tail -n "$last_count" "$trends_file"
        fi

        echo "───────────────────────────────────────────────────────────────"
        echo ""
        echo "Use --stats for aggregated statistics, --json for raw data"
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

    # Load output module (for banner)
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
    fi

    # Show banner for detailed commands (not for quick status)
    # This keeps "nftban watchdog status" as a one-liner for scripts
    # while showing banner for interactive commands
    case "$subcommand" in
        status)
            # Quick one-liner - no banner for scripting compatibility
            ;;
        *)
            # Show banner for all other commands (report, check, history, etc.)
            if [[ $(type -t nftban_banner) == "function" ]]; then
                nftban_banner
            fi
            echo ""
            ;;
    esac

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
        run)
            # Called by systemd timer - runs checks with proper save/trend logic
            nftban_watchdog_cmd_run "$@"
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
        trends)
            nftban_watchdog_cmd_trends "$@"
            ;;
        stats)
            nftban_watchdog_cmd_stats "$@"
            ;;
        stats-history)
            nftban_watchdog_cmd_stats_history "$@"
            ;;
        snapshot)
            nftban_watchdog_cmd_snapshot "$@"
            ;;
        profiles)
            nftban_watchdog_cmd_profiles "$@"
            ;;
        help|-h|--help)
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
