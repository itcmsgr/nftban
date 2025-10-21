#!/usr/bin/env bash
# =============================================================================
# NFTBan Monitoring Module
# Version: 0.9.2
# Location: lib/nftban_monitoring_module.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# System resource monitoring with multi-level alerts and sustained violation tracking
# =============================================================================

# Strict & safe defaults (per NFTBan Remediation Guide 2025-10-20)
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# =============================================================================
# MODULE GUARD
# =============================================================================
[[ -n "${NFTBAN_MONITORING_MODULE_LOADED:-}" ]] && return 0
readonly NFTBAN_MONITORING_MODULE_LOADED=1

# =============================================================================
# DEPENDENCIES
# =============================================================================
# Core module will be loaded by CLI or installer

# =============================================================================
# CONFIGURATION DEFAULTS
# =============================================================================

# Disk space thresholds (percentage)
readonly NFTBAN_MONITOR_DISK_WARN_DEFAULT=80
readonly NFTBAN_MONITOR_DISK_CRIT_DEFAULT=90
readonly NFTBAN_MONITOR_DISK_EMERG_DEFAULT=95

# Memory thresholds (percentage)
readonly NFTBAN_MONITOR_MEM_WARN_DEFAULT=80
readonly NFTBAN_MONITOR_MEM_CRIT_DEFAULT=90
readonly NFTBAN_MONITOR_MEM_EMERG_DEFAULT=95

# CPU thresholds (percentage)
readonly NFTBAN_MONITOR_CPU_WARN_DEFAULT=80
readonly NFTBAN_MONITOR_CPU_CRIT_DEFAULT=90
readonly NFTBAN_MONITOR_CPU_EMERG_DEFAULT=95

# Inode thresholds (percentage)
readonly NFTBAN_MONITOR_INODE_WARN_DEFAULT=80
readonly NFTBAN_MONITOR_INODE_CRIT_DEFAULT=90
readonly NFTBAN_MONITOR_INODE_EMERG_DEFAULT=95

# Duration thresholds (seconds) - sustained violations before alerting
readonly NFTBAN_MONITOR_MEM_DURATION_WARN_DEFAULT=300   # 5 minutes
readonly NFTBAN_MONITOR_MEM_DURATION_CRIT_DEFAULT=300   # 5 minutes
readonly NFTBAN_MONITOR_MEM_DURATION_EMERG_DEFAULT=180  # 3 minutes

readonly NFTBAN_MONITOR_CPU_DURATION_WARN_DEFAULT=600   # 10 minutes
readonly NFTBAN_MONITOR_CPU_DURATION_CRIT_DEFAULT=300   # 5 minutes
readonly NFTBAN_MONITOR_CPU_DURATION_EMERG_DEFAULT=180  # 3 minutes

# Monitoring state directory
readonly NFTBAN_MONITOR_STATE_DIR="${NFTBAN_DATA_DIR:-/etc/nftban/data}/monitoring"
readonly NFTBAN_MONITOR_LOG="${NFTBAN_LOG_DIR:-/var/log/nftban}/monitoring.log"

# Alert cooldown (seconds) - prevent alert spam
readonly NFTBAN_MONITOR_ALERT_COOLDOWN_DEFAULT=3600  # 1 hour

# =============================================================================
# LOGGING HELPERS
# =============================================================================

_nftban_monitor_log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Log to monitoring log file
    echo "[${timestamp}] [${level}] ${message}" >> "${NFTBAN_MONITOR_LOG}" 2>/dev/null || true

    # Also use main logging if available
    if declare -f nftban_log_info >/dev/null 2>&1; then
        case "$level" in
            ERROR)   nftban_log_error "${message}" ;;
            WARNING) nftban_log_warning "${message}" ;;
            SUCCESS) nftban_log_success "${message}" ;;
            *)       nftban_log_info "${message}" ;;
        esac
    fi
}

# =============================================================================
# STATE MANAGEMENT
# =============================================================================

# Initialize state directory
nftban_monitor_init_state() {
    mkdir -p "${NFTBAN_MONITOR_STATE_DIR}" 2>/dev/null || true
    mkdir -p "$(dirname "${NFTBAN_MONITOR_LOG}")" 2>/dev/null || true
}

# Read state file (timestamp of first violation)
_nftban_monitor_read_state() {
    local resource="$1"
    local level="$2"
    local state_file="${NFTBAN_MONITOR_STATE_DIR}/${resource}_${level}.state"

    if [[ -f "$state_file" ]]; then
        cat "$state_file" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# Write state file
_nftban_monitor_write_state() {
    local resource="$1"
    local level="$2"
    local timestamp="$3"
    local state_file="${NFTBAN_MONITOR_STATE_DIR}/${resource}_${level}.state"

    echo "$timestamp" > "$state_file" 2>/dev/null || true
}

# Clear state file
_nftban_monitor_clear_state() {
    local resource="$1"
    local level="$2"
    local state_file="${NFTBAN_MONITOR_STATE_DIR}/${resource}_${level}.state"

    rm -f "$state_file" 2>/dev/null || true
}

# Read last alert timestamp
_nftban_monitor_read_last_alert() {
    local resource="$1"
    local level="$2"
    local alert_file="${NFTBAN_MONITOR_STATE_DIR}/${resource}_${level}.alert"

    if [[ -f "$alert_file" ]]; then
        cat "$alert_file" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# Write last alert timestamp
_nftban_monitor_write_last_alert() {
    local resource="$1"
    local level="$2"
    local timestamp="$3"
    local alert_file="${NFTBAN_MONITOR_STATE_DIR}/${resource}_${level}.alert"

    echo "$timestamp" > "$alert_file" 2>/dev/null || true
}

# =============================================================================
# ALERT DELIVERY
# =============================================================================

_nftban_monitor_send_alert() {
    local resource="$1"
    local level="$2"
    local subject="$3"
    local body="$4"

    local current_time=$(date +%s)
    local last_alert=$(_nftban_monitor_read_last_alert "$resource" "$level")
    local cooldown="${NFTBAN_MONITOR_ALERT_COOLDOWN:-${NFTBAN_MONITOR_ALERT_COOLDOWN_DEFAULT}}"

    # Check cooldown period
    if [[ $((current_time - last_alert)) -lt $cooldown ]]; then
        _nftban_monitor_log INFO "Alert suppressed (cooldown): $subject"
        return 0
    fi

    # Send email if function available
    if declare -f nftban_send_email >/dev/null 2>&1; then
        if nftban_send_email "$subject" "$body"; then
            _nftban_monitor_log SUCCESS "Alert sent: $subject"
            _nftban_monitor_write_last_alert "$resource" "$level" "$current_time"
        else
            _nftban_monitor_log ERROR "Failed to send alert: $subject"
        fi
    else
        _nftban_monitor_log WARNING "Email function not available, logging alert only"
        _nftban_monitor_log WARNING "Subject: $subject"
        _nftban_monitor_log WARNING "Body: $body"
    fi
}

# =============================================================================
# DISK SPACE MONITORING
# =============================================================================

nftban_monitor_check_disk() {
    local warn_threshold="${NFTBAN_MONITOR_DISK_WARN:-${NFTBAN_MONITOR_DISK_WARN_DEFAULT}}"
    local crit_threshold="${NFTBAN_MONITOR_DISK_CRIT:-${NFTBAN_MONITOR_DISK_CRIT_DEFAULT}}"
    local emerg_threshold="${NFTBAN_MONITOR_DISK_EMERG:-${NFTBAN_MONITOR_DISK_EMERG_DEFAULT}}"

    # Check critical filesystems
    local filesystems=("/" "/var" "/tmp" "/home")
    local alerts=()

    for fs in "${filesystems[@]}"; do
        # Skip if filesystem doesn't exist
        [[ ! -d "$fs" ]] && continue

        # Get usage percentage (without % sign)
        local usage=$(df -h "$fs" 2>/dev/null | awk 'NR==2 {gsub(/%/,""); print $5}')
        [[ -z "$usage" ]] && continue

        local level=""
        local level_name=""

        # Determine alert level
        if [[ $usage -ge $emerg_threshold ]]; then
            level="EMERGENCY"
            level_name="emerg"
        elif [[ $usage -ge $crit_threshold ]]; then
            level="CRITICAL"
            level_name="crit"
        elif [[ $usage -ge $warn_threshold ]]; then
            level="WARNING"
            level_name="warn"
        else
            # Below threshold, clear any existing state
            _nftban_monitor_clear_state "disk_${fs//\//_}" "warn"
            _nftban_monitor_clear_state "disk_${fs//\//_}" "crit"
            _nftban_monitor_clear_state "disk_${fs//\//_}" "emerg"
            continue
        fi

        # Get disk details
        local df_output=$(df -h "$fs" 2>/dev/null | awk 'NR==2 {print $2,$3,$4,$5}')
        read -r total used avail percent <<< "$df_output"

        # Build alert message
        local hostname=$(hostname -f 2>/dev/null || hostname)
        local subject="[nftban] ${level}: Disk space ${usage}% on ${hostname}"
        local body="Filesystem: ${fs}
Used: ${usage}% (${used} / ${total})
Available: ${avail}
Threshold: ${level_name} (${!level_name}_threshold%)
Server: ${hostname}
Time: $(date -Iseconds)

Action: Consider cleanup of old logs, backups, or temporary files."

        # Send alert (cooldown handled internally)
        _nftban_monitor_send_alert "disk_${fs//\//_}" "$level_name" "$subject" "$body"

        # Log to array for status output
        alerts+=("${level}: ${fs} at ${usage}%")
    done

    # Return status
    if [[ ${#alerts[@]} -gt 0 ]]; then
        _nftban_monitor_log WARNING "Disk space alerts: ${alerts[*]}"
        return 1
    fi

    return 0
}

# =============================================================================
# MEMORY MONITORING
# =============================================================================

nftban_monitor_check_memory() {
    local warn_threshold="${NFTBAN_MONITOR_MEM_WARN:-${NFTBAN_MONITOR_MEM_WARN_DEFAULT}}"
    local crit_threshold="${NFTBAN_MONITOR_MEM_CRIT:-${NFTBAN_MONITOR_MEM_CRIT_DEFAULT}}"
    local emerg_threshold="${NFTBAN_MONITOR_MEM_EMERG:-${NFTBAN_MONITOR_MEM_EMERG_DEFAULT}}"

    local warn_duration="${NFTBAN_MONITOR_MEM_DURATION_WARN:-${NFTBAN_MONITOR_MEM_DURATION_WARN_DEFAULT}}"
    local crit_duration="${NFTBAN_MONITOR_MEM_DURATION_CRIT:-${NFTBAN_MONITOR_MEM_DURATION_CRIT_DEFAULT}}"
    local emerg_duration="${NFTBAN_MONITOR_MEM_DURATION_EMERG:-${NFTBAN_MONITOR_MEM_DURATION_EMERG_DEFAULT}}"

    # Get memory usage percentage
    local mem_info=$(free -m | awk 'NR==2 {printf "%d %d %d %.0f", $2, $3, $7, ($3/$2)*100}')
    read -r total used available percent_used <<< "$mem_info"

    local current_time=$(date +%s)
    local level=""
    local level_name=""
    local required_duration=0

    # Determine alert level and required duration
    if [[ $percent_used -ge $emerg_threshold ]]; then
        level="EMERGENCY"
        level_name="emerg"
        required_duration=$emerg_duration
    elif [[ $percent_used -ge $crit_threshold ]]; then
        level="CRITICAL"
        level_name="crit"
        required_duration=$crit_duration
    elif [[ $percent_used -ge $warn_threshold ]]; then
        level="WARNING"
        level_name="warn"
        required_duration=$warn_duration
    else
        # Below threshold, clear all states
        _nftban_monitor_clear_state "memory" "warn"
        _nftban_monitor_clear_state "memory" "crit"
        _nftban_monitor_clear_state "memory" "emerg"
        return 0
    fi

    # Check sustained duration
    local first_violation=$(_nftban_monitor_read_state "memory" "$level_name")

    if [[ $first_violation -eq 0 ]]; then
        # First time seeing this violation level
        _nftban_monitor_write_state "memory" "$level_name" "$current_time"
        _nftban_monitor_log INFO "Memory ${level_name} threshold reached: ${percent_used}% (tracking duration)"
        return 0
    fi

    local duration=$((current_time - first_violation))

    if [[ $duration -lt $required_duration ]]; then
        # Not sustained long enough yet
        _nftban_monitor_log INFO "Memory ${level_name} ongoing: ${percent_used}% for ${duration}s (need ${required_duration}s)"
        return 0
    fi

    # Sustained violation - send alert
    local duration_min=$((duration / 60))
    local hostname=$(hostname -f 2>/dev/null || hostname)

    # Get top memory consumers
    local top_consumers=$(ps aux --sort=-%mem | awk 'NR<=6 {printf "  %-20s %6s %6s\n", $11, $4"%", $6/1024"MB"}')

    local subject="[nftban] ${level}: Memory usage ${percent_used}% for ${duration_min}+ minutes"
    local body="Memory Usage: ${percent_used}%
Total: ${total} MB
Used: ${used} MB
Available: ${available} MB
Duration: Sustained for ${duration_min} minutes
Threshold: ${level_name} (${!level_name}_threshold%)
Required Duration: ${required_duration}s
Server: ${hostname}
Time: $(date -Iseconds)

Top Memory Consumers:
${top_consumers}

Action: Investigate high memory usage processes."

    _nftban_monitor_send_alert "memory" "$level_name" "$subject" "$body"

    return 1
}

# =============================================================================
# CPU MONITORING
# =============================================================================

nftban_monitor_check_cpu() {
    local warn_threshold="${NFTBAN_MONITOR_CPU_WARN:-${NFTBAN_MONITOR_CPU_WARN_DEFAULT}}"
    local crit_threshold="${NFTBAN_MONITOR_CPU_CRIT:-${NFTBAN_MONITOR_CPU_CRIT_DEFAULT}}"
    local emerg_threshold="${NFTBAN_MONITOR_CPU_EMERG:-${NFTBAN_MONITOR_CPU_EMERG_DEFAULT}}"

    local warn_duration="${NFTBAN_MONITOR_CPU_DURATION_WARN:-${NFTBAN_MONITOR_CPU_DURATION_WARN_DEFAULT}}"
    local crit_duration="${NFTBAN_MONITOR_CPU_DURATION_CRIT:-${NFTBAN_MONITOR_CPU_DURATION_CRIT_DEFAULT}}"
    local emerg_duration="${NFTBAN_MONITOR_CPU_DURATION_EMERG:-${NFTBAN_MONITOR_CPU_DURATION_EMERG_DEFAULT}}"

    # Get CPU usage (100 - idle)
    local cpu_idle=$(top -bn2 -d 0.5 | grep "Cpu(s)" | tail -1 | awk '{print $8}' | cut -d'%' -f1)
    local cpu_used=$(awk -v idle="$cpu_idle" 'BEGIN {printf "%.0f", 100 - idle}')

    # Get load average
    local load_avg=$(uptime | awk -F'load average:' '{print $2}' | xargs)

    local current_time=$(date +%s)
    local level=""
    local level_name=""
    local required_duration=0

    # Determine alert level and required duration
    if [[ $cpu_used -ge $emerg_threshold ]]; then
        level="EMERGENCY"
        level_name="emerg"
        required_duration=$emerg_duration
    elif [[ $cpu_used -ge $crit_threshold ]]; then
        level="CRITICAL"
        level_name="crit"
        required_duration=$crit_duration
    elif [[ $cpu_used -ge $warn_threshold ]]; then
        level="WARNING"
        level_name="warn"
        required_duration=$warn_duration
    else
        # Below threshold, clear all states
        _nftban_monitor_clear_state "cpu" "warn"
        _nftban_monitor_clear_state "cpu" "crit"
        _nftban_monitor_clear_state "cpu" "emerg"
        return 0
    fi

    # Check sustained duration
    local first_violation=$(_nftban_monitor_read_state "cpu" "$level_name")

    if [[ $first_violation -eq 0 ]]; then
        # First time seeing this violation level
        _nftban_monitor_write_state "cpu" "$level_name" "$current_time"
        _nftban_monitor_log INFO "CPU ${level_name} threshold reached: ${cpu_used}% (tracking duration)"
        return 0
    fi

    local duration=$((current_time - first_violation))

    if [[ $duration -lt $required_duration ]]; then
        # Not sustained long enough yet
        _nftban_monitor_log INFO "CPU ${level_name} ongoing: ${cpu_used}% for ${duration}s (need ${required_duration}s)"
        return 0
    fi

    # Sustained violation - send alert
    local duration_min=$((duration / 60))
    local hostname=$(hostname -f 2>/dev/null || hostname)

    # Get top CPU consumers
    local top_consumers=$(ps aux --sort=-%cpu | awk 'NR<=6 {printf "  %-20s %6s %6s\n", $11, $3"%", $4"%"}')

    local subject="[nftban] ${level}: CPU usage ${cpu_used}% for ${duration_min}+ minutes"
    local body="CPU Usage: ${cpu_used}%
Load Average: ${load_avg}
Duration: Sustained for ${duration_min} minutes
Threshold: ${level_name} (${!level_name}_threshold%)
Required Duration: ${required_duration}s
Server: ${hostname}
Time: $(date -Iseconds)

Top CPU Consumers:
${top_consumers}

Action: Investigate high CPU usage processes."

    _nftban_monitor_send_alert "cpu" "$level_name" "$subject" "$body"

    return 1
}

# =============================================================================
# INODE MONITORING
# =============================================================================

nftban_monitor_check_inodes() {
    local warn_threshold="${NFTBAN_MONITOR_INODE_WARN:-${NFTBAN_MONITOR_INODE_WARN_DEFAULT}}"
    local crit_threshold="${NFTBAN_MONITOR_INODE_CRIT:-${NFTBAN_MONITOR_INODE_CRIT_DEFAULT}}"
    local emerg_threshold="${NFTBAN_MONITOR_INODE_EMERG:-${NFTBAN_MONITOR_INODE_EMERG_DEFAULT}}"

    # Check critical filesystems
    local filesystems=("/" "/var" "/tmp" "/home")
    local alerts=()

    for fs in "${filesystems[@]}"; do
        # Skip if filesystem doesn't exist
        [[ ! -d "$fs" ]] && continue

        # Get inode usage percentage (without % sign)
        local usage=$(df -i "$fs" 2>/dev/null | awk 'NR==2 {gsub(/%/,""); print $5}')
        [[ -z "$usage" ]] && continue

        local level=""
        local level_name=""

        # Determine alert level
        if [[ $usage -ge $emerg_threshold ]]; then
            level="EMERGENCY"
            level_name="emerg"
        elif [[ $usage -ge $crit_threshold ]]; then
            level="CRITICAL"
            level_name="crit"
        elif [[ $usage -ge $warn_threshold ]]; then
            level="WARNING"
            level_name="warn"
        else
            # Below threshold, clear any existing state
            _nftban_monitor_clear_state "inode_${fs//\//_}" "warn"
            _nftban_monitor_clear_state "inode_${fs//\//_}" "crit"
            _nftban_monitor_clear_state "inode_${fs//\//_}" "emerg"
            continue
        fi

        # Get inode details
        local inode_output=$(df -i "$fs" 2>/dev/null | awk 'NR==2 {print $2,$3,$4,$5}')
        read -r total used avail percent <<< "$inode_output"

        # Build alert message
        local hostname=$(hostname -f 2>/dev/null || hostname)
        local subject="[nftban] ${level}: Inode usage ${usage}% on ${hostname}"
        local body="Filesystem: ${fs}
Inode Usage: ${usage}%
Total Inodes: ${total}
Used Inodes: ${used}
Available Inodes: ${avail}
Threshold: ${level_name} (${!level_name}_threshold%)
Server: ${hostname}
Time: $(date -Iseconds)

Action: Clean up directories with many small files.
Common culprits: /tmp, /var/spool, session directories."

        # Send alert (cooldown handled internally)
        _nftban_monitor_send_alert "inode_${fs//\//_}" "$level_name" "$subject" "$body"

        # Log to array for status output
        alerts+=("${level}: ${fs} at ${usage}%")
    done

    # Return status
    if [[ ${#alerts[@]} -gt 0 ]]; then
        _nftban_monitor_log WARNING "Inode usage alerts: ${alerts[*]}"
        return 1
    fi

    return 0
}

# =============================================================================
# MAIN MONITORING LOOP
# =============================================================================

nftban_monitor_run() {
    _nftban_monitor_log INFO "Starting monitoring check..."

    # Initialize state directory
    nftban_monitor_init_state

    local issues=0

    # Run all checks
    nftban_monitor_check_disk || ((issues++))
    nftban_monitor_check_memory || ((issues++))
    nftban_monitor_check_cpu || ((issues++))
    nftban_monitor_check_inodes || ((issues++))

    if [[ $issues -eq 0 ]]; then
        _nftban_monitor_log INFO "Monitoring check complete: All systems normal"
    else
        _nftban_monitor_log WARNING "Monitoring check complete: ${issues} issue(s) detected"
    fi

    return $issues
}

# =============================================================================
# STATUS DISPLAY
# =============================================================================

nftban_monitor_status() {
    echo "=== NFTBan System Monitoring Status ==="
    echo ""

    # Disk space
    echo "Disk Space:"
    df -h / /var /tmp /home 2>/dev/null | awk 'NR==1 || NR>1 {printf "  %-20s %10s %10s %10s %6s\n", $6, $2, $3, $4, $5}'
    echo ""

    # Memory
    echo "Memory Usage:"
    free -h | awk 'NR==1 || NR==2 {print "  " $0}'
    echo ""

    # CPU & Load
    echo "CPU & Load Average:"
    echo "  $(uptime | sed 's/^.*load average: /Load: /')"
    top -bn1 | grep "Cpu(s)" | awk '{print "  CPU: " $2 " user, " $4 " system, " $8 " idle"}'
    echo ""

    # Inodes
    echo "Inode Usage:"
    df -i / /var /tmp /home 2>/dev/null | awk 'NR==1 || NR>1 {printf "  %-20s %12s %12s %12s %6s\n", $6, $2, $3, $4, $5}'
    echo ""

    # Configured thresholds
    echo "Alert Thresholds:"
    echo "  Disk:   ${NFTBAN_MONITOR_DISK_WARN:-${NFTBAN_MONITOR_DISK_WARN_DEFAULT}}% / ${NFTBAN_MONITOR_DISK_CRIT:-${NFTBAN_MONITOR_DISK_CRIT_DEFAULT}}% / ${NFTBAN_MONITOR_DISK_EMERG:-${NFTBAN_MONITOR_DISK_EMERG_DEFAULT}}% (warn/crit/emerg)"
    echo "  Memory: ${NFTBAN_MONITOR_MEM_WARN:-${NFTBAN_MONITOR_MEM_WARN_DEFAULT}}% / ${NFTBAN_MONITOR_MEM_CRIT:-${NFTBAN_MONITOR_MEM_CRIT_DEFAULT}}% / ${NFTBAN_MONITOR_MEM_EMERG:-${NFTBAN_MONITOR_MEM_EMERG_DEFAULT}}% (warn/crit/emerg)"
    echo "  CPU:    ${NFTBAN_MONITOR_CPU_WARN:-${NFTBAN_MONITOR_CPU_WARN_DEFAULT}}% / ${NFTBAN_MONITOR_CPU_CRIT:-${NFTBAN_MONITOR_CPU_CRIT_DEFAULT}}% / ${NFTBAN_MONITOR_CPU_EMERG:-${NFTBAN_MONITOR_CPU_EMERG_DEFAULT}}% (warn/crit/emerg)"
    echo "  Inodes: ${NFTBAN_MONITOR_INODE_WARN:-${NFTBAN_MONITOR_INODE_WARN_DEFAULT}}% / ${NFTBAN_MONITOR_INODE_CRIT:-${NFTBAN_MONITOR_INODE_CRIT_DEFAULT}}% / ${NFTBAN_MONITOR_INODE_EMERG:-${NFTBAN_MONITOR_INODE_EMERG_DEFAULT}}% (warn/crit/emerg)"
    echo ""

    echo "Duration Requirements (sustained before alert):"
    echo "  Memory: $((${NFTBAN_MONITOR_MEM_DURATION_WARN:-${NFTBAN_MONITOR_MEM_DURATION_WARN_DEFAULT}}/60))m / $((${NFTBAN_MONITOR_MEM_DURATION_CRIT:-${NFTBAN_MONITOR_MEM_DURATION_CRIT_DEFAULT}}/60))m / $((${NFTBAN_MONITOR_MEM_DURATION_EMERG:-${NFTBAN_MONITOR_MEM_DURATION_EMERG_DEFAULT}}/60))m"
    echo "  CPU:    $((${NFTBAN_MONITOR_CPU_DURATION_WARN:-${NFTBAN_MONITOR_CPU_DURATION_WARN_DEFAULT}}/60))m / $((${NFTBAN_MONITOR_CPU_DURATION_CRIT:-${NFTBAN_MONITOR_CPU_DURATION_CRIT_DEFAULT}}/60))m / $((${NFTBAN_MONITOR_CPU_DURATION_EMERG:-${NFTBAN_MONITOR_CPU_DURATION_EMERG_DEFAULT}}/60))m"
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f nftban_monitor_run
export -f nftban_monitor_status

# =============================================================================
# MODULE INFO
# =============================================================================

_nftban_monitor_log INFO "Monitoring module loaded (v0.8.0)"
