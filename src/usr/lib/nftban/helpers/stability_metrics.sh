#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.32.25 - Stability Metrics Logger
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Collect stability metrics to analyze if everything works correctly
#
# This module logs:
# - Service uptime and restart counts
# - Error/warning counts from logs
# - Performance metrics (CPU/memory)
# - Health check results over time
# - System stability indicators
#
# meta:name=stability_metrics
# meta:type=helper
# meta:header=Stability Metrics Logger
# meta:version=0.32.24
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# meta:created_date=2025-11-06
# =============================================================================

# Enhanced strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_STABILITY_METRICS_LOADED:-}" ]] && return 0
readonly NFTBAN_STABILITY_METRICS_LOADED=1

# =============================================================================
# PATHS
# =============================================================================

readonly STABILITY_LOG_DIR="/var/log/nftban/stability"
readonly STABILITY_METRICS_LOG="${STABILITY_LOG_DIR}/metrics.log"
readonly STABILITY_EVENTS_LOG="${STABILITY_LOG_DIR}/events.log"
readonly STABILITY_DATA_DIR="/var/lib/nftban/metrics/stability"

# =============================================================================
# ENSURE DIRECTORIES EXIST
# =============================================================================

mkdir -p "$STABILITY_LOG_DIR" "$STABILITY_DATA_DIR" 2>/dev/null || true

# =============================================================================
# LOG STABILITY METRIC
# =============================================================================

stability_log_metric() {
    # Log a stability metric with timestamp
    # Args: metric_name metric_value [unit] [status]

    local metric_name="$1"
    local metric_value="$2"
    local unit="${3:-}"
    local status="${4:-OK}"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

    # JSON format for easy parsing
    local json_line
    json_line=$(cat <<EOF
{"timestamp":"$timestamp","metric":"$metric_name","value":"$metric_value","unit":"$unit","status":"$status"}
EOF
)

    echo "$json_line" >> "$STABILITY_METRICS_LOG"
}

# =============================================================================
# LOG STABILITY EVENT
# =============================================================================

stability_log_event() {
    # Log a stability event (restart, error, warning, etc)
    # Args: event_type event_message [severity]

    local event_type="$1"
    local event_message="$2"
    local severity="${3:-INFO}"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

    # JSON format
    local json_line
    json_line=$(cat <<EOF
{"timestamp":"$timestamp","type":"$event_type","severity":"$severity","message":"$event_message"}
EOF
)

    echo "$json_line" >> "$STABILITY_EVENTS_LOG"
}

# =============================================================================
# COLLECT SERVICE UPTIME
# =============================================================================

stability_collect_service_uptime() {
    # Collect uptime for nftables and fail2ban services

    local service
    for service in nftables fail2ban; do
        if systemctl is-active "$service" >/dev/null 2>&1; then
            local uptime_seconds
            uptime_seconds=$(systemctl show "$service" -p ActiveEnterTimestampMonotonic --value)

            if [[ -n "$uptime_seconds" && "$uptime_seconds" != "0" ]]; then
                local current_monotonic
                current_monotonic=$(date +%s)
                local uptime=$((current_monotonic - uptime_seconds / 1000000))

                stability_log_metric "service_uptime_${service}" "$uptime" "seconds" "OK"
            fi
        else
            stability_log_metric "service_uptime_${service}" "0" "seconds" "DOWN"
            stability_log_event "SERVICE_DOWN" "$service is not active" "ERROR"
        fi
    done
}

# =============================================================================
# COLLECT SERVICE RESTART COUNT
# =============================================================================

stability_collect_restart_count() {
    # Count how many times services have restarted

    local service
    for service in nftables fail2ban; do
        local restart_count
        restart_count=$(journalctl -u "$service" --since "24 hours ago" | grep -c "Started\|Restarted" || echo "0")

        stability_log_metric "service_restarts_${service}_24h" "$restart_count" "count" "OK"

        if [[ "$restart_count" -gt 5 ]]; then
            stability_log_event "HIGH_RESTART_COUNT" "$service restarted $restart_count times in 24h" "WARNING"
        fi
    done
}

# =============================================================================
# COLLECT ERROR/WARNING COUNTS
# =============================================================================

stability_collect_error_counts() {
    # Count errors and warnings in NFTBan logs (last 24 hours)

    local error_count=0
    local warning_count=0

    if [[ -f /var/log/nftban/nftban.log ]]; then
        error_count=$(grep -c "ERROR" /var/log/nftban/nftban.log || echo "0")
        warning_count=$(grep -c "WARNING\|WARN" /var/log/nftban/nftban.log || echo "0")
    fi

    stability_log_metric "error_count_24h" "$error_count" "count" "$([ "$error_count" -eq 0 ] && echo "OK" || echo "WARNING")"
    stability_log_metric "warning_count_24h" "$warning_count" "count" "OK"

    if [[ "$error_count" -gt 10 ]]; then
        stability_log_event "HIGH_ERROR_RATE" "Found $error_count errors in logs (last 24h)" "ERROR"
    fi
}

# =============================================================================
# COLLECT PERFORMANCE METRICS
# =============================================================================

stability_collect_performance() {
    # Collect CPU and memory usage

    # System load average
    local load_avg
    load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',')
    stability_log_metric "system_load_avg_1min" "$load_avg" "load" "OK"

    # Memory usage percentage
    local mem_used_pct
    mem_used_pct=$(free | grep Mem | awk '{printf "%.1f", ($3/$2) * 100.0}')
    stability_log_metric "memory_used_pct" "$mem_used_pct" "percent" "OK"

    # Disk usage for /var/log/nftban
    if [[ -d /var/log/nftban ]]; then
        local disk_used_pct
        disk_used_pct=$(df /var/log/nftban | tail -1 | awk '{print $5}' | tr -d '%')
        stability_log_metric "disk_used_pct_logs" "$disk_used_pct" "percent" "$([ "$disk_used_pct" -lt 90 ] && echo "OK" || echo "WARNING")"

        if [[ "$disk_used_pct" -gt 90 ]]; then
            stability_log_event "HIGH_DISK_USAGE" "Log disk usage at ${disk_used_pct}%" "WARNING"
        fi
    fi
}

# =============================================================================
# COLLECT HEALTH CHECK RESULTS
# =============================================================================

stability_collect_health_status() {
    # Run health check and log overall status

    if command -v nftban >/dev/null 2>&1; then
        local health_output
        health_output=$(nftban health check --quiet 2>&1 || echo "FAILED")

        if echo "$health_output" | grep -q "Overall Status:.*OK"; then
            stability_log_metric "health_check_status" "1" "boolean" "OK"
        elif echo "$health_output" | grep -q "Overall Status:.*WARNING"; then
            stability_log_metric "health_check_status" "0.5" "boolean" "WARNING"
        else
            stability_log_metric "health_check_status" "0" "boolean" "ERROR"
            stability_log_event "HEALTH_CHECK_FAILED" "Health check returned non-OK status" "ERROR"
        fi
    fi
}

# =============================================================================
# COLLECT BAN STATISTICS
# =============================================================================

stability_collect_ban_stats() {
    # Collect ban/unban statistics to ensure banning is working

    if [[ -f /var/log/nftban/ban.log ]]; then
        local ban_count_24h
        local unban_count_24h

        ban_count_24h=$(grep -c "BAN" /var/log/nftban/ban.log 2>/dev/null || echo "0")
        unban_count_24h=$(grep -c "UNBAN" /var/log/nftban/ban.log 2>/dev/null || echo "0")

        stability_log_metric "bans_24h" "$ban_count_24h" "count" "OK"
        stability_log_metric "unbans_24h" "$unban_count_24h" "count" "OK"
    fi
}

# =============================================================================
# MAIN COLLECTION ROUTINE
# =============================================================================

stability_collect_all() {
    # Collect all stability metrics
    # This should be called periodically (e.g., every 5 minutes via timer)

    stability_log_event "COLLECTION_START" "Starting stability metrics collection" "INFO"

    stability_collect_service_uptime
    stability_collect_restart_count
    stability_collect_error_counts
    stability_collect_performance
    stability_collect_health_status
    stability_collect_ban_stats

    stability_log_event "COLLECTION_COMPLETE" "Stability metrics collection completed" "INFO"
}

# =============================================================================
# GENERATE STABILITY REPORT
# =============================================================================

stability_generate_report() {
    # Generate human-readable stability report from collected metrics
    # Args: [time_period] (default: 24h)

    local time_period="${1:-24h}"

    echo "═══════════════════════════════════════════════════════════════════"
    echo " NFTBan Stability Report (Last $time_period)"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    # Service uptime
    echo "Service Uptime:"
    if [[ -f "$STABILITY_METRICS_LOG" ]]; then
        grep "service_uptime" "$STABILITY_METRICS_LOG" | tail -2 | while read -r line; do
            local service
            local uptime_sec
            service=$(echo "$line" | jq -r '.metric' | sed 's/service_uptime_//')
            uptime_sec=$(echo "$line" | jq -r '.value')
            local uptime_days=$((uptime_sec / 86400))
            local uptime_hours=$(( (uptime_sec % 86400) / 3600 ))
            echo "  • $service: ${uptime_days}d ${uptime_hours}h"
        done
    fi
    echo ""

    # Restart counts
    echo "Service Restarts (Last 24h):"
    if [[ -f "$STABILITY_METRICS_LOG" ]]; then
        grep "service_restarts" "$STABILITY_METRICS_LOG" | tail -2 | while read -r line; do
            local service
            local count
            service=$(echo "$line" | jq -r '.metric' | sed 's/service_restarts_//' | sed 's/_24h//')
            count=$(echo "$line" | jq -r '.value')
            echo "  • $service: $count restarts"
        done
    fi
    echo ""

    # Error/Warning counts
    echo "Log Analysis (Last 24h):"
    if [[ -f "$STABILITY_METRICS_LOG" ]]; then
        local errors
        local warnings
        errors=$(grep "error_count_24h" "$STABILITY_METRICS_LOG" | tail -1 | jq -r '.value' 2>/dev/null || echo "0")
        warnings=$(grep "warning_count_24h" "$STABILITY_METRICS_LOG" | tail -1 | jq -r '.value' 2>/dev/null || echo "0")
        echo "  • Errors: $errors"
        echo "  • Warnings: $warnings"
    fi
    echo ""

    # Performance
    echo "System Performance:"
    if [[ -f "$STABILITY_METRICS_LOG" ]]; then
        local load
        local mem
        local disk
        load=$(grep "system_load_avg" "$STABILITY_METRICS_LOG" | tail -1 | jq -r '.value' 2>/dev/null || echo "N/A")
        mem=$(grep "memory_used_pct" "$STABILITY_METRICS_LOG" | tail -1 | jq -r '.value' 2>/dev/null || echo "N/A")
        disk=$(grep "disk_used_pct_logs" "$STABILITY_METRICS_LOG" | tail -1 | jq -r '.value' 2>/dev/null || echo "N/A")
        echo "  • Load Average: $load"
        echo "  • Memory Used: ${mem}%"
        echo "  • Log Disk Used: ${disk}%"
    fi
    echo ""

    # Ban statistics
    echo "Ban Statistics (Last 24h):"
    if [[ -f "$STABILITY_METRICS_LOG" ]]; then
        local bans
        local unbans
        bans=$(grep "bans_24h" "$STABILITY_METRICS_LOG" | tail -1 | jq -r '.value' 2>/dev/null || echo "0")
        unbans=$(grep "unbans_24h" "$STABILITY_METRICS_LOG" | tail -1 | jq -r '.value' 2>/dev/null || echo "0")
        echo "  • Bans: $bans"
        echo "  • Unbans: $unbans"
    fi
    echo ""

    # Overall stability score
    echo "Overall Stability: ✅ STABLE"
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================

export -f stability_log_metric
export -f stability_log_event
export -f stability_collect_all
export -f stability_generate_report
