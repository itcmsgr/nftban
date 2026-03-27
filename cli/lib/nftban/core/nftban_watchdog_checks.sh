#!/usr/bin/env bash
# =============================================================================
# NFTBan - System Watchdog Check Functions
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Core resource check functions for watchdog module
#
# meta:name="nftban_watchdog_checks"
# meta:type="core"
# meta:header="System Watchdog Check Functions"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
# meta:description="Resource check functions: load, memory, I/O, disk, FD, Suricata drift, top processes"
# meta:input="System /proc filesystem and df command"
# meta:output="WATCHDOG_RESULTS associative array, WATCHDOG_ALERTS array"
# meta:depends="bash,df"
# meta:created_date="2026-02-26"
# meta:inventory.files=""
# meta:inventory.binaries="df"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="nftban"
#
# Split from nftban_watchdog.sh (BUG-L24: large file refactoring)
# This file contains ALL check functions. The parent nftban_watchdog.sh
# handles orchestration, reporting, trends, and output.
# =============================================================================
# shellcheck disable=SC2034,SC2154
# SC2034: WATCHDOG_RESULTS/WATCHDOG_ALERTS appear unused - they are exported associative arrays used by parent
# SC2154: Associative array keys appear as unassigned variables - they are hash keys, not variables

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${NFTBAN_WATCHDOG_CHECKS_LOADED:-}" ]] && return 0
readonly NFTBAN_WATCHDOG_CHECKS_LOADED=1

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
    mkdir -p "$(dirname "$NFTBAN_WATCHDOG_LOG")" 2>/dev/null || return 1

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
    if [[ "$NFTBAN_WATCHDOG_MEM_ENABLED" != "true" ]]; then return 0; fi

    local mem_total=0 mem_free=0 mem_available=0 buffers=0 cached=0
    local swap_total=0 swap_free=0

    while IFS=': ' read -r key value _; do
            # Memory stats - reserved for future metrics
            # shellcheck disable=SC2034  -- case vars consumed by threshold checks below
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

    local mem_used mem_used_percent=0
    mem_used=$((mem_total - mem_available))
    [[ $mem_total -gt 0 ]] && mem_used_percent=$((mem_used * 100 / mem_total))

    local swap_used swap_used_percent=0
    swap_used=$((swap_total - swap_free))
    [[ $swap_total -gt 0 ]] && swap_used_percent=$((swap_used * 100 / swap_total))

    WATCHDOG_RESULTS[mem_total_mb]=$((mem_total / 1024))
    WATCHDOG_RESULTS[mem_used_mb]=$((mem_used / 1024))
    WATCHDOG_RESULTS[mem_available_mb]=$((mem_available / 1024))
    WATCHDOG_RESULTS[mem_used_percent]="$mem_used_percent"
    WATCHDOG_RESULTS[swap_total_mb]=$((swap_total / 1024))
    WATCHDOG_RESULTS[swap_used_mb]=$((swap_used / 1024))
    WATCHDOG_RESULTS[swap_used_percent]="$swap_used_percent"
    WATCHDOG_RESULTS[mem_total_bytes]=$((mem_total * 1024))
    WATCHDOG_RESULTS[mem_available_bytes]=$((mem_available * 1024))
    WATCHDOG_RESULTS[swap_used_bytes]=$((swap_used * 1024))

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

    if [[ $swap_total -gt 0 && $swap_used_percent -ge $NFTBAN_WATCHDOG_SWAP_WARNING ]]; then
        [[ $status -lt $WATCHDOG_WARNING ]] && status=$WATCHDOG_WARNING
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
    if [[ "$NFTBAN_WATCHDOG_IOWAIT_ENABLED" != "true" ]]; then return 0; fi

    local cpu_line
    cpu_line=$(head -1 /proc/stat)

    local -a cpu_vals
    IFS=' ' read -ra cpu_vals <<< "$cpu_line"

    local user="${cpu_vals[1]:-0}" nice="${cpu_vals[2]:-0}" system="${cpu_vals[3]:-0}"
    local idle="${cpu_vals[4]:-0}" iowait="${cpu_vals[5]:-0}"
    local irq="${cpu_vals[6]:-0}" softirq="${cpu_vals[7]:-0}"

    local total
    total=$((user + nice + system + idle + iowait + irq + softirq))

    local iowait_percent=0 user_percent=0 system_percent=0 idle_percent=0
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
    if [[ "$NFTBAN_WATCHDOG_DISK_ENABLED" != "true" ]]; then return 0; fi

    local path="$NFTBAN_WATCHDOG_DISK_PATH"
    local df_output
    if ! df_output=$(df -P "$path" 2>/dev/null | tail -1); then
        WATCHDOG_RESULTS[disk_status]="ERROR"
        WATCHDOG_RESULTS[disk_error]="Cannot check disk for $path"
        return $WATCHDOG_CRITICAL
    fi

    local -a df_vals
    IFS=' ' read -ra df_vals <<< "$df_output"

    local total="${df_vals[1]:-0}" used="${df_vals[2]:-0}"
    local available="${df_vals[3]:-0}" percent="${df_vals[4]:-0%}"
    local mount="${df_vals[5]:-$path}"
    percent="${percent%\%}"

    WATCHDOG_RESULTS[disk_path]="$path"
    WATCHDOG_RESULTS[disk_mount]="$mount"
    WATCHDOG_RESULTS[disk_total_gb]=$((total / 1024 / 1024))
    WATCHDOG_RESULTS[disk_used_gb]=$((used / 1024 / 1024))
    WATCHDOG_RESULTS[disk_available_gb]=$((available / 1024 / 1024))
    WATCHDOG_RESULTS[disk_used_percent]="$percent"

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
    local allocated free max
    if ! IFS=$' \t' read -r allocated free max < /proc/sys/fs/file-nr 2>/dev/null; then
        WATCHDOG_RESULTS[fd_status]="ERROR"
        return $WATCHDOG_WARNING
    fi

    WATCHDOG_RESULTS[fd_allocated]="$allocated"
    WATCHDOG_RESULTS[fd_free]="$free"
    WATCHDOG_RESULTS[fd_max]="$max"

    local fd_percent=0
    [[ $max -gt 0 ]] && fd_percent=$((allocated * 100 / max))
    WATCHDOG_RESULTS[fd_used_percent]="$fd_percent"

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

# R25: Conntrack overflow detection (v1.19.12)
nftban_watchdog_check_conntrack() {
    # Check nf_conntrack table utilization
    if [[ "${NFTBAN_WATCHDOG_CONNTRACK_ENABLED:-true}" != "true" ]]; then
        return $WATCHDOG_OK
    fi

    local entries=0 max=0 percent=0
    local status=$WATCHDOG_OK

    # Read current conntrack entries
    if [[ -f /proc/sys/net/netfilter/nf_conntrack_count ]]; then
        entries=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "0")
    else
        WATCHDOG_RESULTS[conntrack_status]="NOT_AVAILABLE"
        return $WATCHDOG_OK
    fi

    # Read max conntrack limit
    if [[ -f /proc/sys/net/netfilter/nf_conntrack_max ]]; then
        max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo "0")
    fi

    WATCHDOG_RESULTS[conntrack_entries]="$entries"
    WATCHDOG_RESULTS[conntrack_max]="$max"

    # Calculate utilization percentage
    if [[ $max -gt 0 ]]; then
        percent=$((entries * 100 / max))
    fi
    WATCHDOG_RESULTS[conntrack_percent]="$percent"

    # Thresholds (configurable)
    local warning_threshold="${NFTBAN_WATCHDOG_CONNTRACK_WARNING:-80}"
    local critical_threshold="${NFTBAN_WATCHDOG_CONNTRACK_CRITICAL:-95}"

    if [[ $percent -ge $critical_threshold ]]; then
        WATCHDOG_RESULTS[conntrack_status]="CRITICAL"
        if watchdog_should_alert "conntrack"; then
            watchdog_alert "CRITICAL" "Conntrack table at ${percent}% (${entries}/${max}) - near overflow!"
        fi
        status=$WATCHDOG_CRITICAL
    elif [[ $percent -ge $warning_threshold ]]; then
        WATCHDOG_RESULTS[conntrack_status]="WARNING"
        if watchdog_should_alert "conntrack"; then
            watchdog_alert "WARNING" "Conntrack table at ${percent}% (${entries}/${max})"
        fi
        status=$WATCHDOG_WARNING
    else
        WATCHDOG_RESULTS[conntrack_status]="OK"
    fi

    return $status
}

nftban_watchdog_check_suricata_drift() {
    # Check Suricata resource usage against profile budgets
    if [[ "${NFTBAN_WATCHDOG_SURICATA_ENABLED:-true}" != "true" ]]; then
        return $WATCHDOG_OK
    fi

    if ! command -v suricata &>/dev/null; then
        WATCHDOG_RESULTS[suricata_status]="NOT_INSTALLED"
        return $WATCHDOG_OK
    fi

    if ! systemctl is-active suricata.service &>/dev/null; then
        WATCHDOG_RESULTS[suricata_status]="NOT_RUNNING"
        return $WATCHDOG_OK
    fi

    # Get distro family for memory budget selection
    local distro_family="debian"
    if declare -f _suricata_get_distro_family &>/dev/null; then
        distro_family=$(_suricata_get_distro_family)
    else
        if [[ -f /etc/os-release ]]; then
            # shellcheck source=/dev/null
            source /etc/os-release || true
            case "${ID:-}" in
                rhel|centos|almalinux|rocky|fedora|ol) distro_family="rhel" ;;
            esac
        fi
    fi
    WATCHDOG_RESULTS[suricata_distro]="$distro_family"

    # Get current profile
    local profile="standard"
    local profile_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/suricata/config/profile.conf"
    if [[ -f "$profile_conf" ]]; then
        # shellcheck source=/dev/null
        source "$profile_conf" || true
        profile="${NFTBAN_SURICATA_PROFILE:-standard}"
    else
        if declare -f _suricata_detect_optimal_profile &>/dev/null; then
            profile=$(_suricata_detect_optimal_profile)
            WATCHDOG_RESULTS[suricata_profile_autodetected]="true"
            watchdog_log "INFO" "Suricata profile auto-detected: $profile"
        fi
    fi
    WATCHDOG_RESULTS[suricata_profile]="$profile"

    # Get profile budgets based on profile and distro
    local max_rules max_mem_mb
    case "$profile" in
        minimal)
            max_rules="${NFTBAN_WATCHDOG_SURICATA_MINIMAL_MAX_RULES:-10000}"
            if [[ "$distro_family" == "rhel" ]]; then
                max_mem_mb="${NFTBAN_WATCHDOG_SURICATA_MINIMAL_MAX_MEM_RHEL:-600}"
            else
                max_mem_mb="${NFTBAN_WATCHDOG_SURICATA_MINIMAL_MAX_MEM_DEBIAN:-150}"
            fi
            ;;
        standard)
            max_rules="${NFTBAN_WATCHDOG_SURICATA_STANDARD_MAX_RULES:-25000}"
            if [[ "$distro_family" == "rhel" ]]; then
                max_mem_mb="${NFTBAN_WATCHDOG_SURICATA_STANDARD_MAX_MEM_RHEL:-1500}"
            else
                max_mem_mb="${NFTBAN_WATCHDOG_SURICATA_STANDARD_MAX_MEM_DEBIAN:-400}"
            fi
            ;;
        maximum|*)
            max_rules="${NFTBAN_WATCHDOG_SURICATA_MAXIMUM_MAX_RULES:-60000}"
            if [[ "$distro_family" == "rhel" ]]; then
                max_mem_mb="${NFTBAN_WATCHDOG_SURICATA_MAXIMUM_MAX_MEM_RHEL:-2500}"
            else
                max_mem_mb="${NFTBAN_WATCHDOG_SURICATA_MAXIMUM_MAX_MEM_DEBIAN:-800}"
            fi
            ;;
    esac
    WATCHDOG_RESULTS[suricata_max_rules]="$max_rules"
    WATCHDOG_RESULTS[suricata_max_mem_mb]="$max_mem_mb"

    local status=$WATCHDOG_OK
    local drift_detected=false

    # CHECK 1: Rule count
    local rule_count=0
    local rules_file="/var/lib/suricata/rules/suricata.rules"
    if [[ -f "$rules_file" ]]; then
        rule_count=$(grep -cE '^(alert|drop|reject|pass|rejectsrc|rejectdst|rejectboth)' "$rules_file" 2>/dev/null || echo 0)
    fi
    WATCHDOG_RESULTS[suricata_rule_count]="$rule_count"

    if [[ $rule_count -gt $max_rules ]]; then
        drift_detected=true
        WATCHDOG_RESULTS[suricata_rule_drift]="OVER_BUDGET"
        local overage=$((rule_count - max_rules))
        if watchdog_should_alert "suricata_rules"; then
            watchdog_alert "WARNING" "Suricata rules ($rule_count) exceed $profile budget ($max_rules) by $overage"
        fi
        status=$WATCHDOG_WARNING
    else
        WATCHDOG_RESULTS[suricata_rule_drift]="OK"
    fi

    # CHECK 2: Memory usage (RSS)
    local rss_kb=0 rss_mb=0
    local suricata_pid
    suricata_pid=$(pgrep -x suricata 2>/dev/null | head -1)
    if [[ -n "$suricata_pid" && -f "/proc/$suricata_pid/status" ]]; then
        rss_kb=$(awk '/VmRSS/ {print $2}' "/proc/$suricata_pid/status" 2>/dev/null || echo 0)
        rss_mb=$((rss_kb / 1024))
    fi
    WATCHDOG_RESULTS[suricata_rss_mb]="$rss_mb"

    if [[ $rss_mb -gt $max_mem_mb ]]; then
        drift_detected=true
        WATCHDOG_RESULTS[suricata_mem_drift]="OVER_BUDGET"
        local overage_mb=$((rss_mb - max_mem_mb))
        if watchdog_should_alert "suricata_mem"; then
            watchdog_alert "WARNING" "Suricata RSS (${rss_mb}MB) exceeds $profile budget (${max_mem_mb}MB) by ${overage_mb}MB [$distro_family]"
        fi
        [[ $status -lt $WATCHDOG_WARNING ]] && status=$WATCHDOG_WARNING
    else
        WATCHDOG_RESULTS[suricata_mem_drift]="OK"
    fi

    # CHECK 3: EVE log freshness
    local eve_file="/var/log/suricata/eve.json"
    local eve_freshness="${NFTBAN_WATCHDOG_SURICATA_EVE_FRESHNESS:-60}"
    WATCHDOG_RESULTS[suricata_eve_freshness_threshold]="$eve_freshness"

    if [[ -f "$eve_file" ]]; then
        local eve_mtime eve_age
        eve_mtime=$(stat -c %Y "$eve_file" 2>/dev/null || echo 0)
        eve_age=$(($(date +%s) - eve_mtime))
        WATCHDOG_RESULTS[suricata_eve_age_sec]="$eve_age"

        if [[ $eve_age -gt $eve_freshness ]]; then
            WATCHDOG_RESULTS[suricata_eve_status]="STALE"
            if watchdog_should_alert "suricata_eve"; then
                watchdog_alert "WARNING" "Suricata EVE log stale: ${eve_age}s old (threshold: ${eve_freshness}s)"
            fi
            [[ $status -lt $WATCHDOG_WARNING ]] && status=$WATCHDOG_WARNING
        else
            WATCHDOG_RESULTS[suricata_eve_status]="FRESH"
        fi
    else
        WATCHDOG_RESULTS[suricata_eve_status]="NOT_FOUND"
        WATCHDOG_RESULTS[suricata_eve_age_sec]="N/A"
    fi

    # AUTO-FALLBACK: If drift detected and auto-fallback enabled
    if [[ "$drift_detected" == "true" && "${NFTBAN_WATCHDOG_SURICATA_AUTO_FALLBACK:-true}" == "true" ]]; then
        if [[ "$profile" != "minimal" ]]; then
            WATCHDOG_RESULTS[suricata_fallback_triggered]="true"
            watchdog_log "WARN" "Suricata drift detected - triggering fallback to minimal profile"

            local fallback_trigger_file="${NFTBAN_RUN_DIR:-/run/nftban}/suricata_fallback_requested"
            echo "$(date -Iseconds) profile=$profile rule_count=$rule_count rss_mb=$rss_mb" > "$fallback_trigger_file"

            if declare -f suricata_generate_effective_config &>/dev/null; then
                local profile_conf_dir
                profile_conf_dir="$(dirname "$profile_conf")"
                mkdir -p "$profile_conf_dir" || return 1
                cat > "$profile_conf" << EOF
# NFTBan Suricata Profile Configuration
# Watchdog fallback: $(date -Iseconds)
# Previous profile: $profile (drift: rules=$rule_count/${max_rules}, mem=${rss_mb}/${max_mem_mb}MB)
NFTBAN_SURICATA_PROFILE_MODE="pinned"
NFTBAN_SURICATA_PROFILE="minimal"
EOF
                watchdog_alert "WARNING" "Suricata profile downgraded to 'minimal' due to budget drift. Run 'nftban suricata rules update' to apply."
            fi
        else
            WATCHDOG_RESULTS[suricata_fallback_triggered]="already_minimal"
            watchdog_log "WARN" "Suricata drift on minimal profile - manual intervention needed"
        fi
    else
        WATCHDOG_RESULTS[suricata_fallback_triggered]="false"
    fi

    if [[ "$drift_detected" == "true" ]]; then
        WATCHDOG_RESULTS[suricata_status]="DRIFT"
    else
        WATCHDOG_RESULTS[suricata_status]="OK"
    fi

    return $status
}

nftban_watchdog_get_top_cpu() {
    # Get top CPU-consuming processes from /proc
    if [[ "$NFTBAN_WATCHDOG_PROC_ENABLED" != "true" ]]; then return 0; fi

    # Process stats - only some fields used
    # shellcheck disable=SC2034  -- count used in head -n below
    local count="${NFTBAN_WATCHDOG_PROC_TOP_COUNT:-10}"
    [[ ! "$count" =~ ^[1-9][0-9]*$ ]] && count=10
    local -a procs=()

    # shellcheck disable=SC2034  # Structured read - only some fields used
    local pid cmdline comm state utime stime stat_line cpu_time vmrss
    for proc_dir in /proc/[0-9]*/; do
        pid="${proc_dir#/proc/}"
        pid="${pid%/}"
        [[ ! -d "/proc/$pid" ]] && continue

        comm=$(cat "/proc/$pid/comm" 2>/dev/null) || continue
        stat_line=$(cat "/proc/$pid/stat" 2>/dev/null) || continue
        cpu_time=$(echo "$stat_line" | awk '{print $14 + $15}')

        vmrss=0
        if [[ -r "/proc/$pid/status" ]]; then
            while IFS=': ' read -r key value _; do
                [[ "$key" == "VmRSS" ]] && { vmrss=$value; break; }
            done < "/proc/$pid/status" 2>/dev/null || true
        fi

        procs+=("$cpu_time $pid $vmrss $comm")
    done

    local sorted
    sorted=$(printf '%s\n' "${procs[@]}" | sort -rn | head -"$count")

    local i=0
    while IFS=' ' read -r cpu_time pid vmrss comm; do
        [[ -z "$pid" ]] && continue
        WATCHDOG_RESULTS["top_cpu_${i}_pid"]="$pid"
        WATCHDOG_RESULTS["top_cpu_${i}_comm"]="$comm"
        WATCHDOG_RESULTS["top_cpu_${i}_cpu_ticks"]="$cpu_time"
        WATCHDOG_RESULTS["top_cpu_${i}_mem_kb"]="$vmrss"
        ((++i)) || true
    done <<< "$sorted"

    WATCHDOG_RESULTS[top_cpu_count]="$i"
    return 0
}

nftban_watchdog_get_top_mem() {
    # Get top memory-consuming processes from /proc
    if [[ "$NFTBAN_WATCHDOG_PROC_ENABLED" != "true" ]]; then return 0; fi

    local count="${NFTBAN_WATCHDOG_PROC_TOP_COUNT:-10}"
    [[ ! "$count" =~ ^[1-9][0-9]*$ ]] && count=10
    local -a procs=()

    local pid comm vmrss
    for proc_dir in /proc/[0-9]*/; do
        pid="${proc_dir#/proc/}"
        pid="${pid%/}"
        [[ ! -d "/proc/$pid" ]] && continue

        comm=$(cat "/proc/$pid/comm" 2>/dev/null) || continue

        vmrss=0
        if [[ -r "/proc/$pid/status" ]]; then
            while IFS=': ' read -r key value _; do
                [[ "$key" == "VmRSS" ]] && { vmrss=$value; break; }
            done < "/proc/$pid/status" 2>/dev/null || true
        fi

        [[ $vmrss -gt 0 ]] && procs+=("$vmrss $pid $comm")
    done

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

        if [[ $vmrss -ge $alert_threshold_kb && $i -eq 0 ]]; then
            if watchdog_should_alert "proc_mem_$pid"; then
                watchdog_alert "INFO" "High memory process: $comm (PID $pid) using $((vmrss / 1024)) MB"
            fi
        fi

        ((++i)) || true
    done <<< "$sorted"

    WATCHDOG_RESULTS[top_mem_count]="$i"
    return 0
}

# =============================================================================
# EXPORTS
# =============================================================================
export -f watchdog_log
export -f watchdog_alert
export -f watchdog_should_alert
export -f nftban_watchdog_check_load
export -f nftban_watchdog_check_memory
export -f nftban_watchdog_check_iowait
export -f nftban_watchdog_check_disk
export -f nftban_watchdog_check_fd
export -f nftban_watchdog_check_suricata_drift
export -f nftban_watchdog_get_top_cpu
export -f nftban_watchdog_get_top_mem
