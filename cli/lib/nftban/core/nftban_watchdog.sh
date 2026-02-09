#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0 - System Watchdog Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Monitor system resources for auditing and alerting
#
# meta:name="nftban_watchdog"
# meta:type="core"
# meta:header="System Watchdog Module"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
# meta:description="Monitors OS-level resources (load, memory, I/O, disk) for troubleshooting"
# meta:input="System /proc filesystem and df command"
# meta:output="Reports, alerts, and Prometheus metrics"
# meta:depends="bash,df"
# meta:created_date="2025-12-17"
# meta:updated_date="2026-02-07"
# meta:inventory.files="/var/log/nftban/watchdog.log,/var/lib/nftban/reports/watchdog"
# meta:inventory.binaries="df"
# meta:inventory.env_vars="NFTBAN_WATCHDOG_ENABLED,NFTBAN_WATCHDOG_INTERVAL"
# meta:inventory.config_files="/etc/nftban/conf.d/watchdog.conf"
# meta:inventory.systemd_units="nftban-watchdog.timer,nftban-watchdog.service"
# meta:inventory.network=""
# meta:inventory.privileges="nftban"
#
# **What This Module Monitors (NO OVERLAP with other modules)**
# - Load Average (from /proc/loadavg)
# - Memory Usage (from /proc/meminfo)
# - Swap Usage (from /proc/meminfo)
# - I/O Wait % (from /proc/stat)
# - Disk Usage (from df command)
# - File Descriptors (from /proc/sys/fs/file-nr)
# - Top CPU/Memory Processes (from /proc/[pid]/*)
#
# **What OTHER Modules Handle (we don't touch these)**
# - Connection per IP: nftban_ddos_classic.sh
# - Ban rate alerts: nftban_stats.sh
# - Service health: nftban_health.sh
# =============================================================================
set -Eeuo pipefail

# Enhanced strict mode
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_WATCHDOG_LOADED:-}" ]] && return 0
readonly NFTBAN_WATCHDOG_LOADED=1

# =============================================================================
# CONFIGURATION (defaults - override in conf.d/watchdog.conf)
# =============================================================================

# Load main configuration
# shellcheck source=/etc/nftban/nftban.conf
if [[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" ]]; then
    source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf"
fi

# Watchdog defaults (can be overridden in conf.d/watchdog.conf)
: "${NFTBAN_WATCHDOG_ENABLED:=false}"
: "${NFTBAN_WATCHDOG_INTERVAL:=90}"
: "${NFTBAN_WATCHDOG_ALERT_THROTTLE:=3600}"

# Load thresholds
: "${NFTBAN_WATCHDOG_LOAD_ENABLED:=true}"
: "${NFTBAN_WATCHDOG_LOAD_AVG:=5}"
: "${NFTBAN_WATCHDOG_LOAD_WARNING:=10}"
: "${NFTBAN_WATCHDOG_LOAD_CRITICAL:=20}"

# Memory thresholds
: "${NFTBAN_WATCHDOG_MEM_ENABLED:=true}"
: "${NFTBAN_WATCHDOG_MEM_WARNING:=80}"
: "${NFTBAN_WATCHDOG_MEM_CRITICAL:=95}"
: "${NFTBAN_WATCHDOG_SWAP_WARNING:=50}"

# I/O wait thresholds
: "${NFTBAN_WATCHDOG_IOWAIT_ENABLED:=true}"
: "${NFTBAN_WATCHDOG_IOWAIT_WARNING:=20}"
: "${NFTBAN_WATCHDOG_IOWAIT_CRITICAL:=40}"

# Disk thresholds
: "${NFTBAN_WATCHDOG_DISK_ENABLED:=true}"
: "${NFTBAN_WATCHDOG_DISK_PATH:=/var/log}"
: "${NFTBAN_WATCHDOG_DISK_WARNING:=80}"
: "${NFTBAN_WATCHDOG_DISK_CRITICAL:=95}"

# Process tracking
: "${NFTBAN_WATCHDOG_PROC_ENABLED:=true}"
: "${NFTBAN_WATCHDOG_PROC_TOP_COUNT:=10}"
: "${NFTBAN_WATCHDOG_PROC_CPU_ALERT:=80}"
: "${NFTBAN_WATCHDOG_PROC_MEM_ALERT:=2048}"

# Logging and metrics
: "${NFTBAN_WATCHDOG_LOG:=${NFTBAN_LOG_DIR:-/var/log/nftban}/watchdog.log}"
: "${NFTBAN_WATCHDOG_REPORT_DIR:=${NFTBAN_DATA_DIR:-/var/lib/nftban}/reports/watchdog}"
: "${NFTBAN_WATCHDOG_ALERT_EMAIL:=true}"
: "${NFTBAN_WATCHDOG_ALERT_SYSLOG:=true}"

# Prometheus metrics
: "${NFTBAN_WATCHDOG_METRICS_ENABLED:=true}"
: "${NFTBAN_WATCHDOG_METRICS_FILE:=${NFTBAN_DATA_DIR:-/var/lib/nftban}/metrics/watchdog.prom}"
: "${NFTBAN_WATCHDOG_REPORT_RETENTION:=7}"

# Load pipeline validation library for capability metric
# shellcheck source=/dev/null
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_pipeline_validation.sh" ]]; then
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_pipeline_validation.sh"
fi

# Load unified alert throttling library
# shellcheck source=/dev/null
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_alert_throttle.sh" ]]; then
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_alert_throttle.sh"
fi

# Load timestamp utilities library
# shellcheck source=/dev/null
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_timestamp.sh" ]]; then
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_timestamp.sh"
fi

# Throttle state file (kept for backward compatibility, no longer used directly)
# shellcheck disable=SC2034  # Exported for external scripts
readonly WATCHDOG_THROTTLE_FILE="${NFTBAN_RUN_DIR:-/run/nftban}/watchdog_throttle"

# Status codes
readonly WATCHDOG_OK=0
readonly WATCHDOG_WARNING=1
readonly WATCHDOG_CRITICAL=2

# Results storage
declare -A WATCHDOG_RESULTS=()
declare -a WATCHDOG_ALERTS=()

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

watchdog_log() {
    # Write to watchdog log
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Ensure log directory exists
    mkdir -p "$(dirname "$NFTBAN_WATCHDOG_LOG")" 2>/dev/null

    echo "[$timestamp] [$level] $msg" >> "$NFTBAN_WATCHDOG_LOG"
}

watchdog_alert() {
    # Add alert to list and optionally send to syslog
    local severity="$1"
    local msg="$2"

    WATCHDOG_ALERTS+=("[$severity] $msg")

    # Log to syslog if enabled
    if [[ "$NFTBAN_WATCHDOG_ALERT_SYSLOG" == "true" ]]; then
        local priority="user.notice"
        [[ "$severity" == "WARNING" ]] && priority="user.warning"
        [[ "$severity" == "CRITICAL" ]] && priority="user.alert"
        logger -t nftban-watchdog -p "$priority" "$msg"
    fi

    watchdog_log "$severity" "$msg"
}

# watchdog_should_alert - Backward compatible wrapper for alert throttling
#
# Arguments:
#   $1 - alert_type: Type of watchdog alert (e.g., "load", "memory", "disk")
#
# Returns:
#   0 - Should send alert
#   1 - Alert is throttled
#
watchdog_should_alert() {
    local alert_type="$1"
    local throttle_seconds="${NFTBAN_WATCHDOG_ALERT_THROTTLE:-3600}"
    local state_dir="${NFTBAN_DATA_DIR:-/var/lib/nftban}/state"

    # Use unified throttle function with 'watchdog_' prefix for namespace
    nftban_should_alert "watchdog_${alert_type}" "$throttle_seconds" "$state_dir"
}

# =============================================================================
# CORE CHECK FUNCTIONS (Read from /proc - no external dependencies)
# =============================================================================

nftban_watchdog_check_load() {
    # Check system load average from /proc/loadavg
    # Returns: status code, sets WATCHDOG_RESULTS

    if [[ "$NFTBAN_WATCHDOG_LOAD_ENABLED" != "true" ]]; then
        return 0
    fi

    # Structured read from /proc/loadavg - only some fields used
    # shellcheck disable=SC2034  # last_pid not used but required for proper parsing
    local load1 load5 load15 running_procs total_procs last_pid
    # Must use default IFS (space) for reading space-separated values
    # shellcheck disable=SC2034  # last_pid captures trailing field
    if ! IFS=' ' read -r load1 load5 load15 running_procs last_pid < /proc/loadavg 2>/dev/null; then
        WATCHDOG_RESULTS[load_status]="ERROR"
        WATCHDOG_RESULTS[load_error]="Cannot read /proc/loadavg"
        return $WATCHDOG_CRITICAL
    fi

    # Parse running/total processes
    local running total
    running="${running_procs%/*}"
    total="${running_procs#*/}"

    WATCHDOG_RESULTS[load_1m]="$load1"
    WATCHDOG_RESULTS[load_5m]="$load5"
    WATCHDOG_RESULTS[load_15m]="$load15"
    WATCHDOG_RESULTS[procs_running]="$running"
    WATCHDOG_RESULTS[procs_total]="$total"

    # Determine which load to check based on config
    local check_load
    case "$NFTBAN_WATCHDOG_LOAD_AVG" in
        1)  check_load="$load1" ;;
        15) check_load="$load15" ;;
        *)  check_load="$load5" ;;
    esac

    WATCHDOG_RESULTS[load_checked]="$check_load"
    WATCHDOG_RESULTS[load_avg_type]="$NFTBAN_WATCHDOG_LOAD_AVG"

    # Compare using bc for floating point (or awk if bc not available)
    local status=$WATCHDOG_OK
    if command -v bc >/dev/null 2>&1; then
        if (( $(echo "$check_load >= $NFTBAN_WATCHDOG_LOAD_CRITICAL" | bc -l) )); then
            status=$WATCHDOG_CRITICAL
            WATCHDOG_RESULTS[load_status]="CRITICAL"
            if watchdog_should_alert "load"; then
                watchdog_alert "CRITICAL" "Load average CRITICAL: ${check_load} >= ${NFTBAN_WATCHDOG_LOAD_CRITICAL}"
            fi
        elif (( $(echo "$check_load >= $NFTBAN_WATCHDOG_LOAD_WARNING" | bc -l) )); then
            status=$WATCHDOG_WARNING
            WATCHDOG_RESULTS[load_status]="WARNING"
            if watchdog_should_alert "load"; then
                watchdog_alert "WARNING" "Load average exceeded: ${check_load} >= ${NFTBAN_WATCHDOG_LOAD_WARNING}"
            fi
        else
            WATCHDOG_RESULTS[load_status]="OK"
        fi
    else
        # Fallback: use awk for comparison
        if awk "BEGIN {exit !($check_load >= $NFTBAN_WATCHDOG_LOAD_CRITICAL)}"; then
            status=$WATCHDOG_CRITICAL
            WATCHDOG_RESULTS[load_status]="CRITICAL"
            if watchdog_should_alert "load"; then
                watchdog_alert "CRITICAL" "Load average CRITICAL: ${check_load} >= ${NFTBAN_WATCHDOG_LOAD_CRITICAL}"
            fi
        elif awk "BEGIN {exit !($check_load >= $NFTBAN_WATCHDOG_LOAD_WARNING)}"; then
            status=$WATCHDOG_WARNING
            WATCHDOG_RESULTS[load_status]="WARNING"
            if watchdog_should_alert "load"; then
                watchdog_alert "WARNING" "Load average exceeded: ${check_load} >= ${NFTBAN_WATCHDOG_LOAD_WARNING}"
            fi
        else
            WATCHDOG_RESULTS[load_status]="OK"
        fi
    fi

    return $status
}

nftban_watchdog_check_memory() {
    # Check memory usage from /proc/meminfo
    # Returns: status code, sets WATCHDOG_RESULTS

    if [[ "$NFTBAN_WATCHDOG_MEM_ENABLED" != "true" ]]; then
        return 0
    fi

    local mem_total=0 mem_free=0 mem_available=0 buffers=0 cached=0
    local swap_total=0 swap_free=0

    while IFS=': ' read -r key value _; do
            # Memory stats - reserved for future metrics
            # shellcheck disable=SC2034
        case "$key" in
            MemTotal)     mem_total=$value ;;
            MemFree)      mem_free=$value ;;
            MemAvailable) mem_available=$value ;;
            Buffers)      buffers=$value ;;
            Cached)       cached=$value ;;
            SwapTotal)    swap_total=$value ;;
            SwapFree)     swap_free=$value ;;
        esac
    done < /proc/meminfo

    # Calculate usage (values are in kB)
    local mem_used
    mem_used=$((mem_total - mem_available))
    local mem_used_percent=0
    if [[ $mem_total -gt 0 ]]; then
        mem_used_percent=$((mem_used * 100 / mem_total))
    fi

    local swap_used
    swap_used=$((swap_total - swap_free))
    local swap_used_percent=0
    if [[ $swap_total -gt 0 ]]; then
        swap_used_percent=$((swap_used * 100 / swap_total))
    fi

    # Store in MB for readability
    WATCHDOG_RESULTS[mem_total_mb]=$((mem_total / 1024))
    WATCHDOG_RESULTS[mem_used_mb]=$((mem_used / 1024))
    WATCHDOG_RESULTS[mem_available_mb]=$((mem_available / 1024))
    WATCHDOG_RESULTS[mem_used_percent]="$mem_used_percent"
    WATCHDOG_RESULTS[swap_total_mb]=$((swap_total / 1024))
    WATCHDOG_RESULTS[swap_used_mb]=$((swap_used / 1024))
    WATCHDOG_RESULTS[swap_used_percent]="$swap_used_percent"

    # Store in bytes for Prometheus metrics
    WATCHDOG_RESULTS[mem_total_bytes]=$((mem_total * 1024))
    WATCHDOG_RESULTS[mem_available_bytes]=$((mem_available * 1024))
    WATCHDOG_RESULTS[swap_used_bytes]=$((swap_used * 1024))

    # Check thresholds
    local status=$WATCHDOG_OK

    if [[ $mem_used_percent -ge $NFTBAN_WATCHDOG_MEM_CRITICAL ]]; then
        status=$WATCHDOG_CRITICAL
        WATCHDOG_RESULTS[mem_status]="CRITICAL"
        if watchdog_should_alert "memory"; then
            watchdog_alert "CRITICAL" "Memory usage CRITICAL: ${mem_used_percent}% >= ${NFTBAN_WATCHDOG_MEM_CRITICAL}%"
        fi
    elif [[ $mem_used_percent -ge $NFTBAN_WATCHDOG_MEM_WARNING ]]; then
        status=$WATCHDOG_WARNING
        WATCHDOG_RESULTS[mem_status]="WARNING"
        if watchdog_should_alert "memory"; then
            watchdog_alert "WARNING" "Memory usage high: ${mem_used_percent}% >= ${NFTBAN_WATCHDOG_MEM_WARNING}%"
        fi
    else
        WATCHDOG_RESULTS[mem_status]="OK"
    fi

    # Check swap separately
    if [[ $swap_total -gt 0 && $swap_used_percent -ge $NFTBAN_WATCHDOG_SWAP_WARNING ]]; then
        if [[ $status -lt $WATCHDOG_WARNING ]]; then
            status=$WATCHDOG_WARNING
        fi
        WATCHDOG_RESULTS[swap_status]="WARNING"
        if watchdog_should_alert "swap"; then
            watchdog_alert "WARNING" "Swap usage: ${swap_used_percent}% >= ${NFTBAN_WATCHDOG_SWAP_WARNING}%"
        fi
    else
        WATCHDOG_RESULTS[swap_status]="OK"
    fi

    return $status
}

nftban_watchdog_check_iowait() {
    # Check I/O wait percentage from /proc/stat
    # Returns: status code, sets WATCHDOG_RESULTS

    if [[ "$NFTBAN_WATCHDOG_IOWAIT_ENABLED" != "true" ]]; then
        return 0
    fi

    # Read CPU line from /proc/stat
    # Format: cpu user nice system idle iowait irq softirq steal guest guest_nice
    local cpu_line
    cpu_line=$(head -1 /proc/stat)

    local -a cpu_vals
    # Must use default IFS (space) for reading space-separated values
    IFS=' ' read -ra cpu_vals <<< "$cpu_line"

    # cpu_vals[0] = "cpu", [1] = user, [2] = nice, [3] = system, [4] = idle, [5] = iowait
    local user="${cpu_vals[1]:-0}"
    local nice="${cpu_vals[2]:-0}"
    local system="${cpu_vals[3]:-0}"
    local idle="${cpu_vals[4]:-0}"
    local iowait="${cpu_vals[5]:-0}"
    local irq="${cpu_vals[6]:-0}"
    local softirq="${cpu_vals[7]:-0}"

    local total
    total=$((user + nice + system + idle + iowait + irq + softirq))

    # Calculate percentages
    local iowait_percent=0
    local user_percent=0
    local system_percent=0
    local idle_percent=0

    if [[ $total -gt 0 ]]; then
        iowait_percent=$((iowait * 100 / total))
        user_percent=$((user * 100 / total))
        system_percent=$((system * 100 / total))
        idle_percent=$((idle * 100 / total))
    fi

    WATCHDOG_RESULTS[cpu_user_percent]="$user_percent"
    WATCHDOG_RESULTS[cpu_system_percent]="$system_percent"
    WATCHDOG_RESULTS[cpu_idle_percent]="$idle_percent"
    WATCHDOG_RESULTS[cpu_iowait_percent]="$iowait_percent"

    # Check thresholds
    local status=$WATCHDOG_OK

    if [[ $iowait_percent -ge $NFTBAN_WATCHDOG_IOWAIT_CRITICAL ]]; then
        status=$WATCHDOG_CRITICAL
        WATCHDOG_RESULTS[iowait_status]="CRITICAL"
        if watchdog_should_alert "iowait"; then
            watchdog_alert "CRITICAL" "I/O Wait CRITICAL: ${iowait_percent}% >= ${NFTBAN_WATCHDOG_IOWAIT_CRITICAL}%"
        fi
    elif [[ $iowait_percent -ge $NFTBAN_WATCHDOG_IOWAIT_WARNING ]]; then
        status=$WATCHDOG_WARNING
        WATCHDOG_RESULTS[iowait_status]="WARNING"
        if watchdog_should_alert "iowait"; then
            watchdog_alert "WARNING" "I/O Wait high: ${iowait_percent}% >= ${NFTBAN_WATCHDOG_IOWAIT_WARNING}%"
        fi
    else
        WATCHDOG_RESULTS[iowait_status]="OK"
    fi

    return $status
}

nftban_watchdog_check_disk() {
    # Check disk usage using df command
    # Returns: status code, sets WATCHDOG_RESULTS

    if [[ "$NFTBAN_WATCHDOG_DISK_ENABLED" != "true" ]]; then
        return 0
    fi

    local path="$NFTBAN_WATCHDOG_DISK_PATH"

    # Use df -P for POSIX output
    local df_output
    if ! df_output=$(df -P "$path" 2>/dev/null | tail -1); then
        WATCHDOG_RESULTS[disk_status]="ERROR"
        WATCHDOG_RESULTS[disk_error]="Cannot check disk for $path"
        return $WATCHDOG_CRITICAL
    fi

    # Parse: Filesystem 1024-blocks Used Available Capacity Mounted
    local -a df_vals
    # Must use default IFS (space) for reading space-separated values
    IFS=' ' read -ra df_vals <<< "$df_output"

    local total="${df_vals[1]:-0}"
    local used="${df_vals[2]:-0}"
    local available="${df_vals[3]:-0}"
    local percent="${df_vals[4]:-0%}"
    local mount="${df_vals[5]:-$path}"

    # Remove % from percent
    percent="${percent%\%}"

    # Store in GB for readability
    WATCHDOG_RESULTS[disk_path]="$path"
    WATCHDOG_RESULTS[disk_mount]="$mount"
    WATCHDOG_RESULTS[disk_total_gb]=$((total / 1024 / 1024))
    WATCHDOG_RESULTS[disk_used_gb]=$((used / 1024 / 1024))
    WATCHDOG_RESULTS[disk_available_gb]=$((available / 1024 / 1024))
    WATCHDOG_RESULTS[disk_used_percent]="$percent"

    # Check thresholds
    local status=$WATCHDOG_OK

    if [[ $percent -ge $NFTBAN_WATCHDOG_DISK_CRITICAL ]]; then
        status=$WATCHDOG_CRITICAL
        WATCHDOG_RESULTS[disk_status]="CRITICAL"
        if watchdog_should_alert "disk"; then
            watchdog_alert "CRITICAL" "Disk usage CRITICAL on $path: ${percent}% >= ${NFTBAN_WATCHDOG_DISK_CRITICAL}%"
        fi
    elif [[ $percent -ge $NFTBAN_WATCHDOG_DISK_WARNING ]]; then
        status=$WATCHDOG_WARNING
        WATCHDOG_RESULTS[disk_status]="WARNING"
        if watchdog_should_alert "disk"; then
            watchdog_alert "WARNING" "Disk usage high on $path: ${percent}% >= ${NFTBAN_WATCHDOG_DISK_WARNING}%"
        fi
    else
        WATCHDOG_RESULTS[disk_status]="OK"
    fi

    return $status
}

nftban_watchdog_check_fd() {
    # Check file descriptor usage from /proc/sys/fs/file-nr
    # Returns: status code, sets WATCHDOG_RESULTS

    local allocated free max
    # File-nr uses tabs as separator, but also spaces sometimes - use explicit IFS
    if ! IFS=$' \t' read -r allocated free max < /proc/sys/fs/file-nr 2>/dev/null; then
        WATCHDOG_RESULTS[fd_status]="ERROR"
        return $WATCHDOG_WARNING
    fi

    WATCHDOG_RESULTS[fd_allocated]="$allocated"
    WATCHDOG_RESULTS[fd_free]="$free"
    WATCHDOG_RESULTS[fd_max]="$max"

    # Calculate percentage
    local fd_percent=0
    if [[ $max -gt 0 ]]; then
        fd_percent=$((allocated * 100 / max))
    fi
    WATCHDOG_RESULTS[fd_used_percent]="$fd_percent"

    # Alert if over 80% (hardcoded threshold for FD exhaustion)
    if [[ $fd_percent -ge 80 ]]; then
        WATCHDOG_RESULTS[fd_status]="WARNING"
        if watchdog_should_alert "fd"; then
            watchdog_alert "WARNING" "File descriptors at ${fd_percent}% (${allocated}/${max})"
        fi
        return $WATCHDOG_WARNING
    fi

    WATCHDOG_RESULTS[fd_status]="OK"
    return $WATCHDOG_OK
}

nftban_watchdog_get_top_cpu() {
    # Get top CPU-consuming processes from /proc
    # Stores results in WATCHDOG_RESULTS[top_cpu_*]

    if [[ "$NFTBAN_WATCHDOG_PROC_ENABLED" != "true" ]]; then
        return 0
    fi

    # Process stats - only some fields used
    # shellcheck disable=SC2034
    local count="${NFTBAN_WATCHDOG_PROC_TOP_COUNT:-10}"
    # Ensure count is a valid positive integer (fixes head -"" error)
    [[ ! "$count" =~ ^[1-9][0-9]*$ ]] && count=10
    local -a procs=()

    # Read all process stats quickly
    # shellcheck disable=SC2034  # Structured read - only some fields used
    # Declare loop variables outside loop to avoid 'local' exit code issues with set -e
    local pid cmdline comm state utime stime stat_line cpu_time vmrss
    for proc_dir in /proc/[0-9]*/; do
        pid="${proc_dir#/proc/}"
        pid="${pid%/}"
        [[ ! -d "/proc/$pid" ]] && continue

        # Read comm (process name)
        comm=$(cat "/proc/$pid/comm" 2>/dev/null) || continue

        # Read stat for CPU time
        stat_line=$(cat "/proc/$pid/stat" 2>/dev/null) || continue

        # Parse stat: pid (comm) state ... utime(14) stime(15)
        # Use awk for reliable parsing
        cpu_time=$(echo "$stat_line" | awk '{print $14 + $15}')

        # Read status for memory
        vmrss=0
        while IFS=': ' read -r key value _; do
            [[ "$key" == "VmRSS" ]] && { vmrss=$value; break; }
        done < "/proc/$pid/status" 2>/dev/null

        # Store: cpu_time pid vmrss_kb comm
        procs+=("$cpu_time $pid $vmrss $comm")
    done

    # Sort by CPU time (descending) and take top N
    local sorted
    sorted=$(printf '%s\n' "${procs[@]}" | sort -rn | head -"$count")

    local i=0
    while IFS=' ' read -r cpu_time pid vmrss comm; do
        [[ -z "$pid" ]] && continue
        WATCHDOG_RESULTS["top_cpu_${i}_pid"]="$pid"
        WATCHDOG_RESULTS["top_cpu_${i}_comm"]="$comm"
        WATCHDOG_RESULTS["top_cpu_${i}_cpu_ticks"]="$cpu_time"
        WATCHDOG_RESULTS["top_cpu_${i}_mem_kb"]="$vmrss"
        ((++i)) || true  # Avoid exit code 1 when i was 0
    done <<< "$sorted"

    WATCHDOG_RESULTS[top_cpu_count]="$i"
    return 0
}

nftban_watchdog_get_top_mem() {
    # Get top memory-consuming processes from /proc
    # Stores results in WATCHDOG_RESULTS[top_mem_*]

    if [[ "$NFTBAN_WATCHDOG_PROC_ENABLED" != "true" ]]; then
        return 0
    fi

    local count="${NFTBAN_WATCHDOG_PROC_TOP_COUNT:-10}"
    # Ensure count is a valid positive integer (fixes head -"" error)
    [[ ! "$count" =~ ^[1-9][0-9]*$ ]] && count=10
    local -a procs=()

    # Read all process memory quickly
    # Declare loop variables outside loop to avoid 'local' exit code issues with set -e
    local pid comm vmrss
    for proc_dir in /proc/[0-9]*/; do
        pid="${proc_dir#/proc/}"
        pid="${pid%/}"
        [[ ! -d "/proc/$pid" ]] && continue

        # Read comm (process name)
        comm=$(cat "/proc/$pid/comm" 2>/dev/null) || continue

        # Read status for memory
        vmrss=0
        while IFS=': ' read -r key value _; do
            [[ "$key" == "VmRSS" ]] && { vmrss=$value; break; }
        done < "/proc/$pid/status" 2>/dev/null

        [[ $vmrss -gt 0 ]] && procs+=("$vmrss $pid $comm")
    done

    # Sort by memory (descending) and take top N
    local sorted
    sorted=$(printf '%s\n' "${procs[@]}" | sort -rn | head -"$count")

    local i=0
    local alert_threshold_kb
    alert_threshold_kb=$((NFTBAN_WATCHDOG_PROC_MEM_ALERT * 1024))

    while IFS=' ' read -r vmrss pid comm; do
        [[ -z "$pid" ]] && continue
        WATCHDOG_RESULTS["top_mem_${i}_pid"]="$pid"
        WATCHDOG_RESULTS["top_mem_${i}_comm"]="$comm"
        WATCHDOG_RESULTS["top_mem_${i}_mem_kb"]="$vmrss"
        WATCHDOG_RESULTS["top_mem_${i}_mem_mb"]=$((vmrss / 1024))

        # Alert if single process exceeds threshold
        if [[ $vmrss -ge $alert_threshold_kb && $i -eq 0 ]]; then
            if watchdog_should_alert "proc_mem_$pid"; then
                watchdog_alert "INFO" "High memory process: $comm (PID $pid) using $((vmrss / 1024)) MB"
            fi
        fi

        ((++i)) || true  # Avoid exit code 1 when i was 0
    done <<< "$sorted"

    WATCHDOG_RESULTS[top_mem_count]="$i"
    return 0
}

# =============================================================================
# ORCHESTRATION
# =============================================================================

nftban_watchdog_run_all() {
    # Execute all enabled checks
    # Returns: highest severity status

    # Clear previous results
    WATCHDOG_RESULTS=()
    WATCHDOG_ALERTS=()

    local overall_status=$WATCHDOG_OK
    local status

    # Run all checks
    nftban_watchdog_check_load
    status=$?
    [[ $status -gt $overall_status ]] && overall_status=$status

    nftban_watchdog_check_memory
    status=$?
    [[ $status -gt $overall_status ]] && overall_status=$status

    nftban_watchdog_check_iowait
    status=$?
    [[ $status -gt $overall_status ]] && overall_status=$status

    nftban_watchdog_check_disk
    status=$?
    [[ $status -gt $overall_status ]] && overall_status=$status

    nftban_watchdog_check_fd
    status=$?
    [[ $status -gt $overall_status ]] && overall_status=$status

    nftban_watchdog_get_top_cpu
    nftban_watchdog_get_top_mem

    # Collect module-level resource usage
    nftban_watchdog_collect_module_resources

    # Store overall status
    WATCHDOG_RESULTS[overall_status]="$overall_status"
    WATCHDOG_RESULTS[check_timestamp]=$(date +%s)
    WATCHDOG_RESULTS[check_datetime]=$(date '+%Y-%m-%d %H:%M:%S')

    return $overall_status
}

# =============================================================================
# OUTPUT FUNCTIONS
# =============================================================================

nftban_watchdog_report() {
    # Generate human-readable report
    # Output: printed to stdout

    local sep="================================================================================"

    echo "$sep"
    echo "NFTBan System Watchdog Report"
    echo "Generated: ${WATCHDOG_RESULTS[check_datetime]:-$(date '+%Y-%m-%d %H:%M:%S')}"
    echo "$sep"
    echo ""

    # Load Average
    if [[ -n "${WATCHDOG_RESULTS[load_1m]:-}" ]]; then
        local load_status="${WATCHDOG_RESULTS[load_status]:-OK}"
        local status_indicator="[OK]"
        [[ "$load_status" == "WARNING" ]] && status_indicator="[WARNING]"
        [[ "$load_status" == "CRITICAL" ]] && status_indicator="[CRITICAL]"

        echo "LOAD AVERAGE: ${status_indicator} ${WATCHDOG_RESULTS[load_avg_type]:-5}-min avg is ${WATCHDOG_RESULTS[load_checked]:-N/A}"
        echo "  1 minute:  ${WATCHDOG_RESULTS[load_1m]}"
        echo "  5 minute:  ${WATCHDOG_RESULTS[load_5m]}"
        echo "  15 minute: ${WATCHDOG_RESULTS[load_15m]}"
        echo "  Running:   ${WATCHDOG_RESULTS[procs_running]:-0} of ${WATCHDOG_RESULTS[procs_total]:-0} processes"
        echo ""
    fi

    # I/O Wait
    if [[ -n "${WATCHDOG_RESULTS[cpu_iowait_percent]:-}" ]]; then
        local iowait_status="${WATCHDOG_RESULTS[iowait_status]:-OK}"
        local status_indicator="[OK]"
        [[ "$iowait_status" == "WARNING" ]] && status_indicator="[WARNING]"
        [[ "$iowait_status" == "CRITICAL" ]] && status_indicator="[CRITICAL]"

        echo "CPU: ${WATCHDOG_RESULTS[cpu_iowait_percent]}% I/O Wait ${status_indicator}"
        echo "  User:     ${WATCHDOG_RESULTS[cpu_user_percent]}%"
        echo "  System:   ${WATCHDOG_RESULTS[cpu_system_percent]}%"
        echo "  Idle:     ${WATCHDOG_RESULTS[cpu_idle_percent]}%"
        echo "  I/O Wait: ${WATCHDOG_RESULTS[cpu_iowait_percent]}%"
        echo ""
    fi

    # Memory
    if [[ -n "${WATCHDOG_RESULTS[mem_used_percent]:-}" ]]; then
        local mem_status="${WATCHDOG_RESULTS[mem_status]:-OK}"
        local status_indicator="[OK]"
        [[ "$mem_status" == "WARNING" ]] && status_indicator="[WARNING]"
        [[ "$mem_status" == "CRITICAL" ]] && status_indicator="[CRITICAL]"

        echo "MEMORY: ${WATCHDOG_RESULTS[mem_used_percent]}% used ${status_indicator}"
        echo "  Total:     ${WATCHDOG_RESULTS[mem_total_mb]} MB"
        echo "  Used:      ${WATCHDOG_RESULTS[mem_used_mb]} MB"
        echo "  Available: ${WATCHDOG_RESULTS[mem_available_mb]} MB"
        echo "  Swap Used: ${WATCHDOG_RESULTS[swap_used_mb]} MB (${WATCHDOG_RESULTS[swap_used_percent]}%)"
        echo ""
    fi

    # Disk
    if [[ -n "${WATCHDOG_RESULTS[disk_used_percent]:-}" ]]; then
        local disk_status="${WATCHDOG_RESULTS[disk_status]:-OK}"
        local status_indicator="[OK]"
        [[ "$disk_status" == "WARNING" ]] && status_indicator="[WARNING]"
        [[ "$disk_status" == "CRITICAL" ]] && status_indicator="[CRITICAL]"

        echo "DISK USAGE: ${status_indicator}"
        echo "  ${WATCHDOG_RESULTS[disk_path]}: ${WATCHDOG_RESULTS[disk_used_percent]}% used (${WATCHDOG_RESULTS[disk_used_gb]}GB of ${WATCHDOG_RESULTS[disk_total_gb]}GB)"
        echo ""
    fi

    # File Descriptors
    if [[ -n "${WATCHDOG_RESULTS[fd_allocated]:-}" ]]; then
        local fd_status="${WATCHDOG_RESULTS[fd_status]:-OK}"
        local status_indicator="[OK]"
        [[ "$fd_status" == "WARNING" ]] && status_indicator="[WARNING]"

        echo "FILE DESCRIPTORS: ${status_indicator}"
        echo "  Allocated: ${WATCHDOG_RESULTS[fd_allocated]} / ${WATCHDOG_RESULTS[fd_max]} (${WATCHDOG_RESULTS[fd_used_percent]}%)"
        echo ""
    fi

    # Module Resources (per-module CPU/Memory)
    # Always show if any nftban services are running
    echo "MODULE RESOURCES:"
    printf "  %-20s %8s %10s %10s\n" "MODULE" "CPU%" "MEM(MB)" "STATUS"

    # nftband daemon (use pidof - more reliable)
    local daemon_pid daemon_mem_kb=0 daemon_mem_mb=0 daemon_cpu=0
    daemon_pid=$(pidof nftband 2>/dev/null | awk '{print $1}' || true)
    if [[ -n "$daemon_pid" ]]; then
        daemon_mem_kb=$(ps -p "$daemon_pid" -o rss= 2>/dev/null | tr -d ' ')
        daemon_mem_mb=$((daemon_mem_kb / 1024))
        daemon_cpu=$(ps -p "$daemon_pid" -o %cpu= 2>/dev/null | tr -d ' ')
        printf "  %-20s %7s%% %10s %10s\n" "nftband" "${daemon_cpu:-0}" "${daemon_mem_mb}MB" "running"
    else
        printf "  %-20s %8s %10s %10s\n" "nftband" "-" "-" "stopped"
    fi

    # Login monitor
    local login_mem_kb=0 login_mem_mb=0
    if systemctl is-active nftban-login-monitor &>/dev/null; then
        login_mem_kb=$(systemctl show nftban-login-monitor --property=MemoryCurrent 2>/dev/null | cut -d= -f2)
        login_mem_mb=$((login_mem_kb / 1024 / 1024))
        printf "  %-20s %8s %10s %10s\n" "login-monitor" "-" "${login_mem_mb}MB" "running"
    else
        printf "  %-20s %8s %10s %10s\n" "login-monitor" "-" "-" "stopped"
    fi

    # Suricata (use pidof - more reliable than pgrep for this binary)
    local suricata_pid suricata_mem_kb=0 suricata_mem_mb=0 suricata_cpu=0
    suricata_pid=$(pidof suricata 2>/dev/null | awk '{print $1}' || true)
    if [[ -n "$suricata_pid" ]]; then
        suricata_mem_kb=$(ps -p "$suricata_pid" -o rss= 2>/dev/null | tr -d ' ')
        suricata_mem_mb=$((suricata_mem_kb / 1024))
        suricata_cpu=$(ps -p "$suricata_pid" -o %cpu= 2>/dev/null | tr -d ' ')
        printf "  %-20s %7s%% %10s %10s\n" "suricata" "${suricata_cpu:-0}" "${suricata_mem_mb}MB" "running"
    else
        printf "  %-20s %8s %10s %10s\n" "suricata" "-" "-" "stopped"
    fi

    # Queue processor
    if systemctl is-active nftban-queue &>/dev/null; then
        local queue_mem_kb queue_mem_mb
        queue_mem_kb=$(systemctl show nftban-queue --property=MemoryCurrent 2>/dev/null | cut -d= -f2)
        queue_mem_mb=$((queue_mem_kb / 1024 / 1024))
        printf "  %-20s %8s %10s %10s\n" "queue" "-" "${queue_mem_mb}MB" "running"
    fi

    echo ""

    # Top Processes by Memory
    local top_mem_count="${WATCHDOG_RESULTS[top_mem_count]:-0}"
    if [[ $top_mem_count -gt 0 ]]; then
        echo "TOP PROCESSES BY MEMORY:"
        printf "  %-8s %-15s %8s  %s\n" "PID" "COMMAND" "MEM(MB)" "MEM(KB)"
        for ((i=0; i<top_mem_count && i<5; i++)); do
            printf "  %-8s %-15s %8s  %s\n" \
                "${WATCHDOG_RESULTS[top_mem_${i}_pid]}" \
                "${WATCHDOG_RESULTS[top_mem_${i}_comm]}" \
                "${WATCHDOG_RESULTS[top_mem_${i}_mem_mb]}" \
                "${WATCHDOG_RESULTS[top_mem_${i}_mem_kb]}"
        done
        echo ""
    fi

    # Alerts
    if [[ ${#WATCHDOG_ALERTS[@]} -gt 0 ]]; then
        echo "ALERTS TRIGGERED:"
        for alert in "${WATCHDOG_ALERTS[@]}"; do
            echo "  $alert"
        done
        echo ""
    fi

    echo "$sep"
}

nftban_watchdog_report_save() {
    # Save report to file for auditing
    # Returns: path to saved report

    mkdir -p "$NFTBAN_WATCHDOG_REPORT_DIR" 2>/dev/null

    local timestamp
    timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    local report_file="${NFTBAN_WATCHDOG_REPORT_DIR}/${timestamp}.report"

    nftban_watchdog_report > "$report_file"

    # Set permissions
    chown nftban:nftban "$report_file" 2>/dev/null || true
    chmod 640 "$report_file"

    echo "$report_file"
}

nftban_watchdog_metrics_export() {
    # Write Prometheus-format metrics file
    # Output: writes to NFTBAN_WATCHDOG_METRICS_FILE

    if [[ "$NFTBAN_WATCHDOG_METRICS_ENABLED" != "true" ]]; then
        return 0
    fi

    mkdir -p "$(dirname "$NFTBAN_WATCHDOG_METRICS_FILE")" 2>/dev/null

    local tmp_file="${NFTBAN_WATCHDOG_METRICS_FILE}.tmp"

    {
        echo "# HELP nftban_watchdog_load_avg System load average"
        echo "# TYPE nftban_watchdog_load_avg gauge"
        echo "nftban_watchdog_load_avg{period=\"1m\"} ${WATCHDOG_RESULTS[load_1m]:-0}"
        echo "nftban_watchdog_load_avg{period=\"5m\"} ${WATCHDOG_RESULTS[load_5m]:-0}"
        echo "nftban_watchdog_load_avg{period=\"15m\"} ${WATCHDOG_RESULTS[load_15m]:-0}"
        echo ""

        echo "# HELP nftban_watchdog_memory_used_percent Memory usage percentage"
        echo "# TYPE nftban_watchdog_memory_used_percent gauge"
        echo "nftban_watchdog_memory_used_percent ${WATCHDOG_RESULTS[mem_used_percent]:-0}"
        echo ""

        echo "# HELP nftban_watchdog_memory_bytes Memory usage in bytes"
        echo "# TYPE nftban_watchdog_memory_bytes gauge"
        echo "nftban_watchdog_memory_bytes{type=\"total\"} ${WATCHDOG_RESULTS[mem_total_bytes]:-0}"
        echo "nftban_watchdog_memory_bytes{type=\"available\"} ${WATCHDOG_RESULTS[mem_available_bytes]:-0}"
        echo "nftban_watchdog_memory_bytes{type=\"swap_used\"} ${WATCHDOG_RESULTS[swap_used_bytes]:-0}"
        echo ""

        echo "# HELP nftban_watchdog_iowait_percent CPU I/O wait percentage"
        echo "# TYPE nftban_watchdog_iowait_percent gauge"
        echo "nftban_watchdog_iowait_percent ${WATCHDOG_RESULTS[cpu_iowait_percent]:-0}"
        echo ""

        echo "# HELP nftban_watchdog_disk_used_percent Disk usage percentage"
        echo "# TYPE nftban_watchdog_disk_used_percent gauge"
        echo "nftban_watchdog_disk_used_percent{path=\"${WATCHDOG_RESULTS[disk_path]:-/var/log}\"} ${WATCHDOG_RESULTS[disk_used_percent]:-0}"
        echo ""

        echo "# HELP nftban_watchdog_fd_allocated File descriptors allocated"
        echo "# TYPE nftban_watchdog_fd_allocated gauge"
        echo "nftban_watchdog_fd_allocated ${WATCHDOG_RESULTS[fd_allocated]:-0}"
        echo ""

        echo "# HELP nftban_watchdog_fd_max Maximum file descriptors"
        echo "# TYPE nftban_watchdog_fd_max gauge"
        echo "nftban_watchdog_fd_max ${WATCHDOG_RESULTS[fd_max]:-0}"
        echo ""

        # Count alerts by severity
        local warning_count=0 critical_count=0
        for alert in "${WATCHDOG_ALERTS[@]}"; do
            [[ "$alert" == *"[WARNING]"* ]] && ((warning_count++))
            [[ "$alert" == *"[CRITICAL]"* ]] && ((critical_count++))
        done

        echo "# HELP nftban_watchdog_alert_total Count of alerts by severity"
        echo "# TYPE nftban_watchdog_alert_total counter"
        echo "nftban_watchdog_alert_total{severity=\"warning\"} $warning_count"
        echo "nftban_watchdog_alert_total{severity=\"critical\"} $critical_count"
        echo ""

        echo "# HELP nftban_watchdog_last_check_timestamp Last check unix timestamp"
        echo "# TYPE nftban_watchdog_last_check_timestamp gauge"
        echo "nftban_watchdog_last_check_timestamp ${WATCHDOG_RESULTS[check_timestamp]:-$(date +%s)}"
        echo ""

        # Capability metric (0=local, 1=perf_degraded, 2=perf_full)
        local capability_value=0
        if declare -f nftban_get_capability_metric_value &>/dev/null; then
            capability_value=$(nftban_get_capability_metric_value)
        fi
        echo "# HELP nftban_watchdog_capability Watchdog capability level (0=local, 1=perf_degraded, 2=perf_full)"
        echo "# TYPE nftban_watchdog_capability gauge"
        echo "nftban_watchdog_capability $capability_value"
    } > "$tmp_file"

    # Atomic move
    mv "$tmp_file" "$NFTBAN_WATCHDOG_METRICS_FILE"

    # Set permissions
    chown nftban:nftban "$NFTBAN_WATCHDOG_METRICS_FILE" 2>/dev/null || true
    chmod 644 "$NFTBAN_WATCHDOG_METRICS_FILE"

    return 0
}

nftban_watchdog_cleanup_old() {
    # Remove reports older than retention period
    # Returns: number of files removed

    local retention_days="${NFTBAN_WATCHDOG_REPORT_RETENTION:-7}"
    local removed=0

    if [[ -d "$NFTBAN_WATCHDOG_REPORT_DIR" ]]; then
        while IFS= read -r -d '' file; do
            rm -f "$file"
            ((removed++))
        done < <(find "$NFTBAN_WATCHDOG_REPORT_DIR" -name "*.report" -type f -mtime +"$retention_days" -print0 2>/dev/null)
    fi

    watchdog_log "INFO" "Cleanup: removed $removed old reports (retention: ${retention_days} days)"
    echo "$removed"
}

nftban_watchdog_cleanup_all() {
    # Comprehensive cleanup of all watchdog-related data directories
    # Called by maintenance.sh for periodic housekeeping
    local total_removed=0
    local removed

    # 1. Watchdog reports (already handled by cleanup_old)
    removed=$(nftban_watchdog_cleanup_old 2>/dev/null) || removed=0
    total_removed=$((total_removed + removed))

    # 2. Stats history directory - keep 30 days
    local stats_history_dir="${NFTBAN_DATA_DIR:-/var/lib/nftban}/stats/history"
    if [[ -d "$stats_history_dir" ]]; then
        removed=0
        while IFS= read -r -d '' file; do
            rm -f "$file" && ((removed++))
        done < <(find "$stats_history_dir" -name "*.json" -type f -mtime +30 -print0 2>/dev/null)
        [[ $removed -gt 0 ]] && watchdog_log "INFO" "Cleanup: removed $removed old stats history files (>30 days)"
        total_removed=$((total_removed + removed))
    fi

    # 3. Profiles directory - keep 7 days (pprof captures)
    local profiles_dir="${NFTBAN_WATCHDOG_PROFILE_DIR:-${NFTBAN_DATA_DIR:-/var/lib/nftban}/stats/profiles}"
    local profile_retention="${NFTBAN_WATCHDOG_PROFILE_RETENTION_DAYS:-7}"
    if [[ -d "$profiles_dir" ]]; then
        removed=0
        while IFS= read -r -d '' file; do
            rm -f "$file" && ((removed++))
        done < <(find "$profiles_dir" -type f -mtime +"$profile_retention" -print0 2>/dev/null)
        [[ $removed -gt 0 ]] && watchdog_log "INFO" "Cleanup: removed $removed old profile captures (>${profile_retention} days)"
        total_removed=$((total_removed + removed))
    fi

    # 4. Flight recorder directory - keep 7 days
    local recorder_dir="${NFTBAN_RECORDER_DIR:-${NFTBAN_DATA_DIR:-/var/lib/nftban}/recorder}"
    local recorder_retention="${NFTBAN_RECORDER_RETENTION_DAYS:-7}"
    if [[ -d "$recorder_dir" ]]; then
        removed=0
        while IFS= read -r -d '' file; do
            rm -f "$file" && ((removed++))
        done < <(find "$recorder_dir" -type f -mtime +"$recorder_retention" -print0 2>/dev/null)
        [[ $removed -gt 0 ]] && watchdog_log "INFO" "Cleanup: removed $removed old recorder files (>${recorder_retention} days)"
        total_removed=$((total_removed + removed))
    fi

    echo "$total_removed"
}

# =============================================================================
# MAIN ENTRY POINT (for timer/service)
# =============================================================================

nftban_watchdog_run() {
    # Main entry point called by systemd timer
    # Runs all checks, saves report, exports metrics, logs trends
    #
    # Arguments:
    #   $1 - (optional) output tier: "journal", "summary", "full", "auto", "silent"
    #        Default: "silent" when called from timer, "auto" otherwise
    #
    # Returns: Overall status code (0=OK, 1=WARNING, 2=CRITICAL)

    local output_tier="${1:-silent}"

    if [[ "$NFTBAN_WATCHDOG_ENABLED" != "true" ]]; then
        echo "Watchdog is disabled. Enable with: nftban watchdog enable"
        return 0
    fi

    watchdog_log "INFO" "Watchdog check starting"

    # Run all checks
    nftban_watchdog_run_all
    local status=$?

    # Save report (only if issues or explicitly requested)
    local report_file=""
    if [[ $status -gt 0 || "$output_tier" == "full" ]]; then
        report_file=$(nftban_watchdog_report_save)
        watchdog_log "INFO" "Report saved: $report_file"
    fi

    # Export Prometheus metrics
    nftban_watchdog_metrics_export

    # Append to JSONL trend log (every cycle for trend analysis)
    _watchdog_append_trend

    # Cleanup old reports periodically
    nftban_watchdog_cleanup_old >/dev/null

    # Log completion status
    local status_text="OK"
    [[ $status -eq $WATCHDOG_WARNING ]] && status_text="WARNING"
    [[ $status -eq $WATCHDOG_CRITICAL ]] && status_text="CRITICAL"
    watchdog_log "INFO" "Watchdog check completed: $status_text"

    # Generate output based on requested tier
    case "$output_tier" in
        silent)
            # No output (called from timer - logs to journal via logger in alerts)
            ;;
        journal)
            _watchdog_output_journal
            ;;
        summary)
            _watchdog_output_summary
            ;;
        full)
            nftban_watchdog_report
            ;;
        auto)
            nftban_watchdog_output auto
            ;;
    esac

    return $status
}

# =============================================================================
# TREND ANALYSIS (7-day rolling history)
# =============================================================================

readonly NFTBAN_WATCHDOG_TREND_DIR="${NFTBAN_DATA_DIR:-/var/lib/nftban}/watchdog"
readonly NFTBAN_WATCHDOG_TREND_FILE="${NFTBAN_WATCHDOG_TREND_DIR}/trend_hourly.json"
readonly NFTBAN_WATCHDOG_TREND_RETENTION=168  # 7 days in hours

nftban_watchdog_trend_collect() {
    # Collect current system metrics and append to trend history
    # Called hourly by maintenance timer
    # Usage: nftban_watchdog_trend_collect

    mkdir -p "$NFTBAN_WATCHDOG_TREND_DIR" 2>/dev/null || true

    # Run checks to populate WATCHDOG_RESULTS
    nftban_watchdog_run_all >/dev/null 2>&1

    local hour_start
    hour_start=$(date -d "$(date +%Y-%m-%d\ %H):00:00" +%Y-%m-%dT%H:%M:%SZ)

    # Extract metrics from WATCHDOG_RESULTS
    local load5="${WATCHDOG_RESULTS[load_5m]:-0}"
    local mem_pct="${WATCHDOG_RESULTS[mem_used_percent]:-0}"
    local iowait="${WATCHDOG_RESULTS[cpu_iowait_percent]:-0}"
    local disk_pct="${WATCHDOG_RESULTS[disk_used_percent]:-0}"

    # Create new sample JSON
    local sample
    sample=$(cat <<EOF
{"hour":"${hour_start}","load_5m":${load5},"mem_percent":${mem_pct},"iowait_percent":${iowait},"disk_percent":${disk_pct}}
EOF
)

    # Load existing data, append, and enforce retention
    local temp_file="${NFTBAN_WATCHDOG_TREND_FILE}.tmp"

    if [[ -f "$NFTBAN_WATCHDOG_TREND_FILE" ]] && command -v jq &>/dev/null; then
        jq --argjson new "$sample" --argjson max "$NFTBAN_WATCHDOG_TREND_RETENTION" \
            '.samples += [$new] | .samples = .samples[-$max:]' \
            "$NFTBAN_WATCHDOG_TREND_FILE" > "$temp_file" 2>/dev/null && \
            mv "$temp_file" "$NFTBAN_WATCHDOG_TREND_FILE"
    else
        echo "{\"samples\":[$sample],\"retention_hours\":$NFTBAN_WATCHDOG_TREND_RETENTION}" > "$NFTBAN_WATCHDOG_TREND_FILE"
    fi

    chown nftban:nftban "$NFTBAN_WATCHDOG_TREND_FILE" 2>/dev/null || true
    chmod 640 "$NFTBAN_WATCHDOG_TREND_FILE" 2>/dev/null || true
}

nftban_watchdog_trend_load() {
    # Load watchdog trend history
    # Returns: JSON array of samples

    if [[ -f "$NFTBAN_WATCHDOG_TREND_FILE" ]] && command -v jq &>/dev/null; then
        jq -r '.samples' "$NFTBAN_WATCHDOG_TREND_FILE" 2>/dev/null
    else
        echo "[]"
    fi
}

nftban_watchdog_trend_averages() {
    # Calculate averages from watchdog trend data
    # Returns: JSON with averages for each metric

    if [[ ! -f "$NFTBAN_WATCHDOG_TREND_FILE" ]] || ! command -v jq &>/dev/null; then
        echo '{"load_5m":{"avg":0,"min":0,"max":0},"mem_percent":{"avg":0,"min":0,"max":0},"iowait_percent":{"avg":0,"min":0,"max":0},"disk_percent":{"avg":0,"min":0,"max":0},"samples":0}'
        return
    fi

    jq '
        .samples as $s |
        ($s | length) as $n |
        if $n == 0 then
            {"load_5m":{"avg":0,"min":0,"max":0},"mem_percent":{"avg":0,"min":0,"max":0},"iowait_percent":{"avg":0,"min":0,"max":0},"disk_percent":{"avg":0,"min":0,"max":0},"samples":0}
        else
            {
                "load_5m": {
                    "avg": (($s | map(.load_5m) | add / $n) | . * 10 | floor / 10),
                    "min": ($s | map(.load_5m) | min),
                    "max": ($s | map(.load_5m) | max)
                },
                "mem_percent": {
                    "avg": (($s | map(.mem_percent) | add / $n) | floor),
                    "min": ($s | map(.mem_percent) | min),
                    "max": ($s | map(.mem_percent) | max)
                },
                "iowait_percent": {
                    "avg": (($s | map(.iowait_percent) | add / $n) | . * 10 | floor / 10),
                    "min": ($s | map(.iowait_percent) | min),
                    "max": ($s | map(.iowait_percent) | max)
                },
                "disk_percent": {
                    "avg": (($s | map(.disk_percent) | add / $n) | floor),
                    "min": ($s | map(.disk_percent) | min),
                    "max": ($s | map(.disk_percent) | max)
                },
                "samples": $n
            }
        end
    ' "$NFTBAN_WATCHDOG_TREND_FILE" 2>/dev/null || echo '{"samples":0}'
}

nftban_watchdog_trend_thresholds() {
    # Calculate suggested thresholds based on historical data
    # Returns: JSON with suggested warning/critical thresholds

    if [[ ! -f "$NFTBAN_WATCHDOG_TREND_FILE" ]] || ! command -v jq &>/dev/null; then
        echo '{"load":{"warning":10,"critical":20},"mem":{"warning":80,"critical":95},"iowait":{"warning":20,"critical":40}}'
        return
    fi

    jq '
        .samples as $s |
        ($s | length) as $n |
        if $n < 24 then
            {"load":{"warning":10,"critical":20},"mem":{"warning":80,"critical":95},"iowait":{"warning":20,"critical":40},"insufficient_data":true}
        else
            # Load thresholds
            (($s | map(.load_5m) | add / $n) as $avg |
             ($s | map((.load_5m - $avg) * (.load_5m - $avg)) | add / $n | sqrt) as $sd |
             {"warning": ([($avg + 1.5 * $sd) | floor, 5] | max), "critical": ([($avg + 3 * $sd) | floor, 10] | max)}) as $load |
            # Memory thresholds (cap at 95%)
            (($s | map(.mem_percent) | add / $n) as $avg |
             ($s | map((.mem_percent - $avg) * (.mem_percent - $avg)) | add / $n | sqrt) as $sd |
             {"warning": ([($avg + 1.5 * $sd) | floor, 80] | min), "critical": 95}) as $mem |
            # I/O wait thresholds
            (($s | map(.iowait_percent) | add / $n) as $avg |
             ($s | map((.iowait_percent - $avg) * (.iowait_percent - $avg)) | add / $n | sqrt) as $sd |
             {"warning": ([($avg + 2 * $sd) | floor, 15] | max), "critical": ([($avg + 4 * $sd) | floor, 30] | max)}) as $iowait |
            {
                "load": $load,
                "mem": $mem,
                "iowait": $iowait,
                "based_on_samples": $n
            }
        end
    ' "$NFTBAN_WATCHDOG_TREND_FILE" 2>/dev/null || echo '{"load":{"warning":10,"critical":20},"mem":{"warning":80,"critical":95},"iowait":{"warning":20,"critical":40}}'
}

nftban_watchdog_trend_display() {
    # Display formatted watchdog trend analysis
    # Usage: nftban_watchdog_trend_display [--json]

    local json_mode=0
    [[ "${1:-}" == "--json" ]] && json_mode=1

    if [[ $json_mode -eq 1 ]]; then
        local averages thresholds
        averages=$(nftban_watchdog_trend_averages)
        thresholds=$(nftban_watchdog_trend_thresholds)
        jq -n --argjson avg "$averages" --argjson thr "$thresholds" \
            '{averages: $avg, thresholds: $thr}'
        return
    fi

    # Text output
    echo ""
    echo "SYSTEM RESOURCE TRENDS (Last 7 Days)"
    echo "══════════════════════════════════════════════════════════════"
    echo ""

    local avg_data threshold_data
    avg_data=$(nftban_watchdog_trend_averages)
    threshold_data=$(nftban_watchdog_trend_thresholds)

    if ! command -v jq &>/dev/null; then
        echo "[WARN] jq not installed - trend analysis requires jq"
        return 1
    fi

    local samples
    samples=$(echo "$avg_data" | jq -r '.samples')

    if [[ "$samples" == "0" ]]; then
        echo "  No trend data available yet."
        echo "  Trend data is collected every 15 minutes by the maintenance timer."
        echo ""
        echo "  Enable timer: nftban timers enable nftban-maintenance.timer"
        return 0
    fi

    # Load Average
    local load_avg load_min load_max load_warn
    load_avg=$(echo "$avg_data" | jq -r '.load_5m.avg')
    load_min=$(echo "$avg_data" | jq -r '.load_5m.min')
    load_max=$(echo "$avg_data" | jq -r '.load_5m.max')
    load_warn=$(echo "$threshold_data" | jq -r '.load.warning')

    echo "LOAD AVERAGE (5-min)"
    echo "───────────────────────────────────────────────────────────────"
    printf "  %-20s %s\n" "Average............." "$load_avg"
    printf "  %-20s %s (min) / %s (max)\n" "Range..............." "$load_min" "$load_max"
    printf "  %-20s %s (current: ${NFTBAN_WATCHDOG_LOAD_WARNING:-10})\n" "Suggested Warning..." "$load_warn"
    echo ""

    # Memory
    local mem_avg mem_min mem_max
    mem_avg=$(echo "$avg_data" | jq -r '.mem_percent.avg')
    mem_min=$(echo "$avg_data" | jq -r '.mem_percent.min')
    mem_max=$(echo "$avg_data" | jq -r '.mem_percent.max')

    echo "MEMORY USAGE"
    echo "───────────────────────────────────────────────────────────────"
    printf "  %-20s %s%%\n" "Average............." "$mem_avg"
    printf "  %-20s %s%% (min) / %s%% (max)\n" "Range..............." "$mem_min" "$mem_max"
    echo ""

    # I/O Wait
    local io_avg io_min io_max io_warn
    io_avg=$(echo "$avg_data" | jq -r '.iowait_percent.avg')
    io_min=$(echo "$avg_data" | jq -r '.iowait_percent.min')
    io_max=$(echo "$avg_data" | jq -r '.iowait_percent.max')
    io_warn=$(echo "$threshold_data" | jq -r '.iowait.warning')

    echo "I/O WAIT"
    echo "───────────────────────────────────────────────────────────────"
    printf "  %-20s %s%%\n" "Average............." "$io_avg"
    printf "  %-20s %s%% (min) / %s%% (max)\n" "Range..............." "$io_min" "$io_max"
    printf "  %-20s %s%% (current: ${NFTBAN_WATCHDOG_IOWAIT_WARNING:-20}%%)\n" "Suggested Warning..." "$io_warn"
    echo ""

    # Disk
    local disk_avg disk_min disk_max
    disk_avg=$(echo "$avg_data" | jq -r '.disk_percent.avg')
    disk_min=$(echo "$avg_data" | jq -r '.disk_percent.min')
    disk_max=$(echo "$avg_data" | jq -r '.disk_percent.max')

    echo "DISK USAGE"
    echo "───────────────────────────────────────────────────────────────"
    printf "  %-20s %s%%\n" "Average............." "$disk_avg"
    printf "  %-20s %s%% (min) / %s%% (max)\n" "Range..............." "$disk_min" "$disk_max"
    echo ""

    printf "Based on %s hourly samples\n" "$samples"
    echo "══════════════════════════════════════════════════════════════"
}

# =============================================================================
# MODULE RESOURCE COLLECTION
# =============================================================================

nftban_watchdog_collect_module_resources() {
    # Collect resource usage for active NFTBan modules
    # - Timer modules (feeds, rbl): Get stats via systemctl show
    # - Embedded modules (portscan, ddos, geoban): Estimate from daemon stats
    #
    # Stores results in WATCHDOG_RESULTS array:
    #   module_<name>_duration    - Last run duration in seconds
    #   module_<name>_memory      - Peak memory in bytes
    #   module_<name>_status      - Exit status (0=ok, 1=fail)
    #   module_<name>_cpu_pct     - Estimated CPU percentage (embedded only)
    #   module_<name>_mem_pct     - Estimated memory percentage (embedded only)
    #   module_<name>_last_run    - Last run timestamp (epoch)
    #
    # Usage: nftban_watchdog_collect_module_resources

    local stats_cache="${NFTBAN_JSON_CACHE_DIR:-/var/cache/nftban/metrics}/stats.json"

    # =========================================================================
    # TIMER MODULES (feeds, rbl)
    # These run as oneshot services triggered by timers
    # =========================================================================

    local -a timer_modules=("feeds:nftban-core-feeds" "rbl:nftban-rbl-check")
    local module_name service_name

    for module_spec in "${timer_modules[@]}"; do
        module_name="${module_spec%%:*}"
        service_name="${module_spec#*:}.service"

        # Check if service is enabled or has run recently
        if ! systemctl is-enabled "$service_name" &>/dev/null && \
           ! systemctl show "$service_name" -p ActiveEnterTimestamp --value 2>/dev/null | grep -qv '^$'; then
            continue
        fi

        # Get service properties in one call for efficiency
        local props
        props=$(systemctl show "$service_name" \
            -p ExecMainStartTimestampMonotonic \
            -p ExecMainExitTimestampMonotonic \
            -p ExecMainStatus \
            -p MemoryPeak \
            -p ActiveEnterTimestamp \
            2>/dev/null) || continue

        # Parse properties
        local start_mono=0 exit_mono=0 exit_status=0 memory_peak=0 last_run_ts=""

        while IFS='=' read -r key value; do
            case "$key" in
                ExecMainStartTimestampMonotonic)
                    start_mono="${value:-0}"
                    ;;
                ExecMainExitTimestampMonotonic)
                    exit_mono="${value:-0}"
                    ;;
                ExecMainStatus)
                    exit_status="${value:-0}"
                    ;;
                MemoryPeak)
                    # MemoryPeak is in bytes, may be empty or "[not set]"
                    if [[ "$value" =~ ^[0-9]+$ ]]; then
                        memory_peak="$value"
                    fi
                    ;;
                ActiveEnterTimestamp)
                    # Convert to epoch if present
                    if [[ -n "$value" && "$value" != "n/a" ]]; then
                        last_run_ts=$(date -d "$value" +%s 2>/dev/null || echo "0")
                    fi
                    ;;
            esac
        done <<< "$props"

        # Calculate duration from monotonic timestamps (microseconds to seconds)
        local duration=0
        if [[ $start_mono -gt 0 && $exit_mono -gt 0 && $exit_mono -ge $start_mono ]]; then
            duration=$(( (exit_mono - start_mono) / 1000000 ))
        fi

        # Store results
        WATCHDOG_RESULTS["module_${module_name}_duration"]="$duration"
        WATCHDOG_RESULTS["module_${module_name}_memory"]="$memory_peak"
        WATCHDOG_RESULTS["module_${module_name}_status"]="$exit_status"
        WATCHDOG_RESULTS["module_${module_name}_last_run"]="${last_run_ts:-0}"
    done

    # =========================================================================
    # EMBEDDED MODULES (portscan, ddos, geoban)
    # These are handled by the nftband daemon - estimate resource usage
    # based on ban ratios from the unified cache
    # =========================================================================

    # Check if nftband is running
    local daemon_pid daemon_cpu=0 daemon_mem_bytes=0
    daemon_pid=$(cat "${NFTBAN_RUN_DIR:-/run/nftban}/nftband.pid" 2>/dev/null || echo "")

    if [[ -n "$daemon_pid" && -d "/proc/$daemon_pid" ]]; then
        # Get daemon CPU% from /proc/stat (cumulative ticks)
        # For a point-in-time %, we use ps as a simpler approach
        local ps_output
        ps_output=$(ps -p "$daemon_pid" -o %cpu=,%mem= 2>/dev/null) || ps_output=""
        if [[ -n "$ps_output" ]]; then
            # Must use default IFS for space-separated values
            local cpu_pct mem_pct
            IFS=' ' read -r cpu_pct mem_pct <<< "$ps_output"
            daemon_cpu="${cpu_pct%.*}"  # Truncate decimal
            daemon_cpu="${daemon_cpu:-0}"
        fi

        # Get daemon memory from /proc/pid/status
        local vmrss=0
        while IFS=': ' read -r key value _; do
            [[ "$key" == "VmRSS" ]] && { vmrss=$value; break; }
        done < "/proc/$daemon_pid/status" 2>/dev/null
        daemon_mem_bytes=$((vmrss * 1024))  # kB to bytes
    fi

    # Read ban counts by source from unified cache
    local src_portscan=0 src_ddos=0 src_geoban=0 src_total=0

    if [[ -f "$stats_cache" ]] && command -v jq &>/dev/null; then
        # Extract ban counts from cache
        local bans_json
        bans_json=$(jq -r '.bans_by_source // {}' "$stats_cache" 2>/dev/null) || bans_json="{}"

        src_portscan=$(echo "$bans_json" | jq -r '.portscan // 0')
        src_ddos=$(echo "$bans_json" | jq -r '.ddos // 0')
        # geoban is not a direct source, estimate from feeds or manual for now
        # For geoban, we check if the module is active
        if systemctl is-active nftban-geoban.service &>/dev/null 2>&1 || \
           [[ -f "${NFTBAN_DATA_DIR:-/var/lib/nftban}/geoban/enabled" ]]; then
            # Geoban doesn't generate bans the same way, check its status
            local geoban_countries
            geoban_countries=$(jq -r '.geoban.countries_blocked // 0' "$stats_cache" 2>/dev/null || echo "0")
            src_geoban=$((geoban_countries > 0 ? 1 : 0))  # Active indicator
        fi

        # shellcheck disable=SC2034  # Used for debugging/future features
        src_total=$((src_portscan + src_ddos))
    fi

    # Calculate resource attribution based on ban ratio
    # If no bans, distribute equally among active modules
    local -a embedded_modules=()
    local active_count=0

    # Check which embedded modules are active
    if systemctl is-active nftban-portscan.service &>/dev/null 2>&1 || \
       [[ "$(jq -r '.module_status.portscan // 0' "$stats_cache" 2>/dev/null)" == "1" ]]; then
        embedded_modules+=("portscan:$src_portscan")
        ((active_count++)) || true
    fi

    if systemctl is-active nftban-ddos.service &>/dev/null 2>&1 || \
       [[ "$(jq -r '.module_status.ddos // 0' "$stats_cache" 2>/dev/null)" == "1" ]]; then
        embedded_modules+=("ddos:$src_ddos")
        ((active_count++)) || true
    fi

    if [[ $src_geoban -gt 0 ]] || \
       [[ "$(jq -r '.module_status.geoban // 0' "$stats_cache" 2>/dev/null)" == "1" ]]; then
        embedded_modules+=("geoban:1")  # Geoban gets a base weight of 1
        ((active_count++)) || true
    fi

    # Distribute daemon resources among active embedded modules
    if [[ $active_count -gt 0 && ($daemon_cpu -gt 0 || $daemon_mem_bytes -gt 0) ]]; then
        local total_weight=0
        local mod_spec mod_weight

        # Calculate total weight
        for mod_spec in "${embedded_modules[@]}"; do
            mod_weight="${mod_spec#*:}"
            total_weight=$((total_weight + mod_weight + 1))  # +1 base weight
        done

        # Ensure minimum total weight
        [[ $total_weight -eq 0 ]] && total_weight=$active_count

        # Attribute resources proportionally
        for mod_spec in "${embedded_modules[@]}"; do
            module_name="${mod_spec%%:*}"
            mod_weight="${mod_spec#*:}"
            mod_weight=$((mod_weight + 1))  # +1 base weight

            local cpu_share mem_share
            cpu_share=$((daemon_cpu * mod_weight / total_weight))
            mem_share=$((daemon_mem_bytes * mod_weight / total_weight))

            # Store as percentage of daemon resources
            local cpu_pct_of_daemon=0 mem_pct_of_daemon=0
            if [[ $daemon_cpu -gt 0 ]]; then
                cpu_pct_of_daemon=$((cpu_share * 100 / (daemon_cpu > 0 ? daemon_cpu : 1)))
            fi
            if [[ $daemon_mem_bytes -gt 0 ]]; then
                mem_pct_of_daemon=$((mem_share * 100 / daemon_mem_bytes))
            fi

            WATCHDOG_RESULTS["module_${module_name}_cpu_pct"]="$cpu_pct_of_daemon"
            WATCHDOG_RESULTS["module_${module_name}_mem_pct"]="$mem_pct_of_daemon"
            WATCHDOG_RESULTS["module_${module_name}_mem_bytes"]="$mem_share"
        done
    else
        # No daemon running or no resources - set zeros for active modules
        for mod_spec in "${embedded_modules[@]}"; do
            module_name="${mod_spec%%:*}"
            WATCHDOG_RESULTS["module_${module_name}_cpu_pct"]=0
            WATCHDOG_RESULTS["module_${module_name}_mem_pct"]=0
            WATCHDOG_RESULTS["module_${module_name}_mem_bytes"]=0
        done
    fi

    # Store daemon totals for reference
    WATCHDOG_RESULTS["daemon_cpu_pct"]="$daemon_cpu"
    WATCHDOG_RESULTS["daemon_mem_bytes"]="$daemon_mem_bytes"
    WATCHDOG_RESULTS["daemon_pid"]="${daemon_pid:-0}"

    return 0
}

# =============================================================================
# JSONL TREND LOGGING (Fast Append-Only Logging)
# =============================================================================
#
# This provides a simple, fast append-only log format (JSONL = one JSON object
# per line) for trend analysis. Unlike the hourly trend_hourly.json which is
# designed for jq aggregation, this JSONL file:
# - Writes after EVERY watchdog cycle (not just hourly)
# - Uses simple append (no JSON parsing needed for writes)
# - Auto-rotates at 10000 lines (keeps last 5000)
# - Provides ~7 days of data at 90s intervals
#
# Format per line:
#   {"ts":"ISO8601","mode":"normal|degraded|survival","cpu":N,"mem":N,"io":N,"net":N,"actions":N}
#
# =============================================================================

# JSONL trend file location (in watchdog log directory for easy access)
: "${NFTBAN_WATCHDOG_TRENDS_JSONL:=${NFTBAN_WATCHDOG_LOG_DIR:-${NFTBAN_LOG_DIR:-/var/log/nftban}/watchdog}/trends.jsonl}"

# Maximum lines before rotation (approx 7 days at 90s intervals = ~6700 entries)
: "${NFTBAN_WATCHDOG_TRENDS_MAX_LINES:=10000}"

# Lines to keep after rotation
: "${NFTBAN_WATCHDOG_TRENDS_KEEP_LINES:=5000}"

_watchdog_append_trend() {
    # Append JSONL trend data after each watchdog run
    # Called at the end of nftban_watchdog_run()
    #
    # Uses data from WATCHDOG_RESULTS array populated by nftban_watchdog_run_all()
    #
    # Returns: 0 on success, 1 on failure (non-fatal)

    local trend_file="$NFTBAN_WATCHDOG_TRENDS_JSONL"
    local trend_dir
    trend_dir=$(dirname "$trend_file")

    # Ensure directory exists
    if ! mkdir -p "$trend_dir" 2>/dev/null; then
        watchdog_log "WARN" "Cannot create trend directory: $trend_dir"
        return 1
    fi

    # Get timestamp in ISO8601 format
    local timestamp
    timestamp=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')

    # Determine watchdog mode based on overall status
    local mode="normal"
    local overall_status="${WATCHDOG_RESULTS[overall_status]:-0}"
    case "$overall_status" in
        1) mode="degraded" ;;
        2) mode="survival" ;;
    esac

    # Extract key metrics from WATCHDOG_RESULTS
    # CPU score: use combined system+user CPU percentage (100 - idle)
    local cpu_score="${WATCHDOG_RESULTS[cpu_idle_percent]:-100}"
    cpu_score=$((100 - cpu_score))

    # Memory score: use memory used percentage
    local mem_score="${WATCHDOG_RESULTS[mem_used_percent]:-0}"

    # I/O score: use iowait percentage
    local io_score="${WATCHDOG_RESULTS[cpu_iowait_percent]:-0}"

    # Network score: derived from load and active processes (approximation)
    # Since we don't have direct network metrics, use load as proxy
    local net_score=0
    local load5="${WATCHDOG_RESULTS[load_5m]:-0}"
    # Convert load to percentage-like score (load of 4 = 100% for 4-core system)
    if command -v nproc &>/dev/null; then
        local ncpu
        ncpu=$(nproc 2>/dev/null || echo 4)
        # Avoid division by zero and floating point
        if [[ $ncpu -gt 0 ]]; then
            # Multiply load by 100, then divide by ncpu for percentage
            # Use awk for floating point math
            net_score=$(awk -v load="$load5" -v cpu="$ncpu" 'BEGIN {
                score = (load * 100) / cpu;
                if (score > 100) score = 100;
                printf "%.0f", score
            }')
        fi
    fi

    # Count actions taken (alerts triggered)
    local actions_count="${#WATCHDOG_ALERTS[@]}"

    # Create compact JSON line (no spaces for efficiency)
    local json_line
    printf -v json_line '{"ts":"%s","mode":"%s","cpu":%d,"mem":%d,"io":%d,"net":%d,"actions":%d}' \
        "$timestamp" \
        "$mode" \
        "$cpu_score" \
        "$mem_score" \
        "$io_score" \
        "$net_score" \
        "$actions_count"

    # Append to file (atomic via printf >> which flushes on newline)
    if ! printf '%s\n' "$json_line" >> "$trend_file" 2>/dev/null; then
        watchdog_log "WARN" "Cannot append to trend file: $trend_file"
        return 1
    fi

    # Check if rotation is needed
    local line_count
    line_count=$(wc -l < "$trend_file" 2>/dev/null || echo 0)

    if [[ $line_count -gt $NFTBAN_WATCHDOG_TRENDS_MAX_LINES ]]; then
        # Rotate: keep only the last N lines
        local temp_file="${trend_file}.tmp.$$"

        if tail -n "$NFTBAN_WATCHDOG_TRENDS_KEEP_LINES" "$trend_file" > "$temp_file" 2>/dev/null; then
            if mv "$temp_file" "$trend_file" 2>/dev/null; then
                watchdog_log "INFO" "Rotated trend file: kept last $NFTBAN_WATCHDOG_TRENDS_KEEP_LINES lines"
            else
                rm -f "$temp_file" 2>/dev/null
                watchdog_log "WARN" "Failed to rotate trend file (mv failed)"
            fi
        else
            rm -f "$temp_file" 2>/dev/null
            watchdog_log "WARN" "Failed to rotate trend file (tail failed)"
        fi
    fi

    # Set permissions (non-fatal if fails)
    chown nftban:nftban "$trend_file" 2>/dev/null || true
    chmod 640 "$trend_file" 2>/dev/null || true

    return 0
}

# =============================================================================
# TIERED OUTPUT (Systemd Journal / Summary / Full Report)
# =============================================================================
#
# Three output tiers for different contexts:
# 1. JOURNAL (1-line):  For systemd journal, scripts, monitoring
# 2. SUMMARY (10-line): For `nftban watchdog status` interactive use
# 3. FULL:              For --verbose or when issues detected
#
# =============================================================================

_watchdog_output_journal() {
    # Generate 1-line output for systemd journal
    # Format: "Watchdog: MODE cpu=X% mem=Y% io=Z% [actions: N]"
    #
    # Reads from WATCHDOG_RESULTS array (must be populated first)
    # Output: prints to stdout

    local mode="OK"
    local overall_status="${WATCHDOG_RESULTS[overall_status]:-0}"
    case "$overall_status" in
        1) mode="WARN" ;;
        2) mode="CRIT" ;;
    esac

    local cpu_pct="${WATCHDOG_RESULTS[cpu_idle_percent]:-100}"
    cpu_pct=$((100 - cpu_pct))

    local mem_pct="${WATCHDOG_RESULTS[mem_used_percent]:-0}"
    local io_pct="${WATCHDOG_RESULTS[cpu_iowait_percent]:-0}"
    local actions="${#WATCHDOG_ALERTS[@]}"

    local output
    printf -v output "Watchdog: %s cpu=%d%% mem=%d%% io=%d%%" \
        "$mode" "$cpu_pct" "$mem_pct" "$io_pct"

    # Add actions count if any
    if [[ $actions -gt 0 ]]; then
        output+=" [actions: $actions]"
    fi

    echo "$output"
}

_watchdog_output_summary() {
    # Generate 10-line summary for interactive status
    # More detail than journal, less than full report
    #
    # Reads from WATCHDOG_RESULTS array (must be populated first)
    # Output: prints to stdout

    local mode="OK"
    local overall_status="${WATCHDOG_RESULTS[overall_status]:-0}"
    case "$overall_status" in
        1) mode="DEGRADED" ;;
        2) mode="SURVIVAL" ;;
    esac

    local timestamp="${WATCHDOG_RESULTS[check_datetime]:-$(date '+%Y-%m-%d %H:%M:%S')}"

    echo "NFTBan Watchdog Summary"
    echo "─────────────────────────────────────────"
    printf "%-15s %s\n" "Status:" "$mode"
    printf "%-15s %s\n" "Checked:" "$timestamp"
    echo ""

    # Resource line
    local cpu_pct="${WATCHDOG_RESULTS[cpu_idle_percent]:-100}"
    cpu_pct=$((100 - cpu_pct))
    local mem_pct="${WATCHDOG_RESULTS[mem_used_percent]:-0}"
    local io_pct="${WATCHDOG_RESULTS[cpu_iowait_percent]:-0}"
    local disk_pct="${WATCHDOG_RESULTS[disk_used_percent]:-0}"

    printf "CPU: %3d%%  MEM: %3d%%  I/O: %3d%%  DISK: %3d%%\n" \
        "$cpu_pct" "$mem_pct" "$io_pct" "$disk_pct"
    echo ""

    # Load average
    local load1="${WATCHDOG_RESULTS[load_1m]:-0}"
    local load5="${WATCHDOG_RESULTS[load_5m]:-0}"
    local load15="${WATCHDOG_RESULTS[load_15m]:-0}"
    printf "Load: %s / %s / %s (1/5/15 min)\n" "$load1" "$load5" "$load15"

    # Alerts summary
    local alert_count="${#WATCHDOG_ALERTS[@]}"
    if [[ $alert_count -gt 0 ]]; then
        echo ""
        echo "Alerts ($alert_count):"
        # Show first 2 alerts
        local shown=0
        for alert in "${WATCHDOG_ALERTS[@]}"; do
            echo "  $alert"
            ((shown++))
            [[ $shown -ge 2 ]] && break
        done
        if [[ $alert_count -gt 2 ]]; then
            echo "  ... and $((alert_count - 2)) more (use --verbose)"
        fi
    fi

    echo "─────────────────────────────────────────"
}

_watchdog_should_show_full() {
    # Determine if full report should be shown
    # Returns: 0 if full report should be shown, 1 otherwise
    #
    # Conditions for full report:
    # - Overall status is CRITICAL (survival mode)
    # - More than 2 alerts triggered
    # - --verbose flag (checked by caller)

    local overall_status="${WATCHDOG_RESULTS[overall_status]:-0}"
    local alert_count="${#WATCHDOG_ALERTS[@]}"

    # Critical status always shows full report
    [[ $overall_status -ge 2 ]] && return 0

    # Many alerts suggest something significant
    [[ $alert_count -ge 3 ]] && return 0

    return 1
}

nftban_watchdog_output() {
    # Smart output selector based on context
    #
    # Arguments:
    #   $1 - output tier: "journal", "summary", "full", "auto"
    #   $2 - (optional) --verbose flag
    #
    # "auto" tier selection:
    #   - If stdout is a terminal: summary (or full if issues)
    #   - If stdout is not a terminal: journal

    local tier="${1:-auto}"
    local verbose=false
    [[ "${2:-}" == "--verbose" || "${2:-}" == "-v" ]] && verbose=true

    case "$tier" in
        journal)
            _watchdog_output_journal
            ;;
        summary)
            _watchdog_output_summary
            ;;
        full)
            nftban_watchdog_report
            ;;
        auto)
            if [[ "$verbose" == "true" ]]; then
                nftban_watchdog_report
            elif [[ -t 1 ]]; then
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
        *)
            echo "Unknown output tier: $tier" >&2
            return 1
            ;;
    esac
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_watchdog_run_all
export -f nftban_watchdog_report
export -f nftban_watchdog_report_save
export -f nftban_watchdog_metrics_export
export -f nftban_watchdog_run
export -f nftban_watchdog_check_load
export -f nftban_watchdog_check_memory
export -f nftban_watchdog_check_iowait
export -f nftban_watchdog_check_disk
export -f nftban_watchdog_check_fd
export -f nftban_watchdog_get_top_cpu
export -f nftban_watchdog_get_top_mem
export -f nftban_watchdog_cleanup_old
export -f nftban_watchdog_cleanup_all
export -f nftban_watchdog_trend_collect
export -f nftban_watchdog_trend_display
export -f nftban_watchdog_trend_averages
export -f nftban_watchdog_trend_thresholds
export -f nftban_watchdog_collect_module_resources
export -f nftban_watchdog_output
# Internal functions (exported for subshell access)
export -f _watchdog_append_trend
export -f _watchdog_output_journal
export -f _watchdog_output_summary
export -f _watchdog_should_show_full
