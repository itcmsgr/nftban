#!/bin/bash
# =============================================================================
# NFTBan v1.0.0 - Portscan Protection Classic Mode
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="nftban_portscan_classic"
# meta:type="module"
# meta:header="Portscan Classic Mode"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Pure nftables-based portscan detection with journalctl support"
# meta:inventory.files="/var/lib/nftban/portscan-state.db"
# meta:inventory.binaries="nft,journalctl"
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/conf.d/portscan/classic.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2025-10-26"
# meta:updated_date="2026-01-11"
# =============================================================================
# shellcheck disable=SC1083  # Braces in nftables syntax are literal, not bash
# =============================================================================

set -Eeuo pipefail

# Prevent double sourcing
[[ -n "${_NFTBAN_PORTSCAN_CLASSIC_LOADED:-}" ]] && return 0
declare -g _NFTBAN_PORTSCAN_CLASSIC_LOADED=1

# Load fragment and IPC libraries for single-writer architecture
# See: ARCHITECTURE-NFT-POLICY.md
: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/nft_fragment.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/nft_ipc.sh" 2>/dev/null || true

# =============================================================================
# CONFIGURATION LOADING
# =============================================================================

# Load classic mode configuration
nftban_portscan_classic_load_config() {
    local config_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/portscan/classic.conf"
    local local_config="${config_file%.conf}.conf.local"

    # Load base config
    if [[ -f "$config_file" ]]; then
        # shellcheck source=/dev/null
        source "$config_file"
    else
        _nftban_portscan_classic_log "WARN" "Config not found: $config_file"
    fi

    # Load local overrides
    if [[ -f "$local_config" ]]; then
        # shellcheck source=/dev/null
        source "$local_config"
    fi

    # Set defaults
    : "${PORTSCAN_CLASSIC_LOG_PREFIX:=NFTBAN_PORTSCAN:}"
    : "${PORTSCAN_CLASSIC_LOG_FILE:=/var/log/kern.log}"
    : "${PORTSCAN_CLASSIC_MIN_PORTS:=5}"
    : "${PORTSCAN_CLASSIC_TIME_WINDOW:=60}"
    : "${PORTSCAN_CLASSIC_VERTICAL_PORTS:=10}"
    : "${PORTSCAN_CLASSIC_HORIZONTAL_TARGETS:=5}"
    : "${PORTSCAN_CLASSIC_ACTION:=block}"
    : "${PORTSCAN_CLASSIC_BAN_DEFAULT:=1800}"
    : "${PORTSCAN_CLASSIC_MAX_TRACKED_IPS:=10000}"
    : "${PORTSCAN_CLASSIC_LOG_RATE:=10/second}"
    : "${PORTSCAN_CLASSIC_LOG_BURST:=50}"
    : "${PORTSCAN_CLASSIC_STATE_FILE:=/var/lib/nftban/portscan-state.db}"

    return 0
}

# =============================================================================
# LOGGING
# =============================================================================

# Log file for portscan classic mode
readonly PORTSCAN_CLASSIC_LOG_FILE="${PORTSCAN_CLASSIC_LOG_FILE:-/var/log/nftban/portscan-classic.log}"

_nftban_portscan_classic_log() {
    local level="$1"
    local message="$2"
    local log_file="${PORTSCAN_CLASSIC_LOG_FILE:-/var/log/nftban/portscan-classic.log}"

    # Create log directory if needed
    mkdir -p "$(dirname "$log_file")" 2>/dev/null

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [CLASSIC] [$level] $message" >> "$log_file"
}

# =============================================================================
# STATE TRACKING
# =============================================================================

# In-memory tracking arrays
declare -gA _PORTSCAN_CLASSIC_IP_PORTS       # IP -> ports seen (space-separated)
declare -gA _PORTSCAN_CLASSIC_IP_TIMESTAMPS  # IP -> timestamps (space-separated)
declare -gA _PORTSCAN_CLASSIC_IP_TARGETS     # IP -> target IPs (space-separated)
declare -gA _PORTSCAN_CLASSIC_IP_BLOCKED     # IP -> block timestamp
declare -gA _PORTSCAN_CLASSIC_IP_BAN_COUNT   # IP -> number of times banned

# Initialize state tracking
nftban_portscan_classic_init_state() {
    _PORTSCAN_CLASSIC_IP_PORTS=()
    _PORTSCAN_CLASSIC_IP_TIMESTAMPS=()
    _PORTSCAN_CLASSIC_IP_TARGETS=()
    _PORTSCAN_CLASSIC_IP_BLOCKED=()
    _PORTSCAN_CLASSIC_IP_BAN_COUNT=()

    # Load persistent state if exists
    if [[ -f "${PORTSCAN_CLASSIC_STATE_FILE}" ]]; then
        nftban_portscan_classic_load_state
    fi

    return 0
}

# Save state to disk
nftban_portscan_classic_save_state() {
    local state_file="${PORTSCAN_CLASSIC_STATE_FILE}"
    local state_dir
    state_dir=$(dirname "$state_file")

    [[ -d "$state_dir" ]] || mkdir -p "$state_dir"

    {
        echo "# NFTBan Portscan Classic State - $(date -Iseconds)"
        echo "# Format: TYPE|IP|DATA"

        for ip in "${!_PORTSCAN_CLASSIC_IP_BLOCKED[@]}"; do
            echo "BLOCKED|${ip}|${_PORTSCAN_CLASSIC_IP_BLOCKED[$ip]}"
        done

        for ip in "${!_PORTSCAN_CLASSIC_IP_BAN_COUNT[@]}"; do
            echo "BAN_COUNT|${ip}|${_PORTSCAN_CLASSIC_IP_BAN_COUNT[$ip]}"
        done
    } > "${state_file}.tmp" && mv "${state_file}.tmp" "${state_file}"

    return 0
}

# Load state from disk
nftban_portscan_classic_load_state() {
    local state_file="${PORTSCAN_CLASSIC_STATE_FILE}"

    [[ -f "$state_file" ]] || return 0

    while IFS='|' read -r type ip data; do
        [[ "$type" =~ ^# ]] && continue
        [[ -z "$type" ]] && continue

        case "$type" in
            BLOCKED)
                _PORTSCAN_CLASSIC_IP_BLOCKED["$ip"]="$data"
                ;;
            BAN_COUNT)
                _PORTSCAN_CLASSIC_IP_BAN_COUNT["$ip"]="$data"
                ;;
        esac
    done < "$state_file"

    return 0
}

# =============================================================================
# NFTABLES RULES (via IPC - single-writer architecture)
# =============================================================================

# Create nftables chain for portscan detection
# Uses fragment renderer + IPC instead of direct nft calls
nftban_portscan_classic_create_chain() {
    _nftban_portscan_classic_log "INFO" "Creating portscan detection chain via IPC"

    # Chain creation is handled by the fragment in add_rules
    # This function is kept for compatibility but is now a no-op
    # The fragment includes "add chain" which is idempotent
    return 0
}

# Add logging rules for portscan detection
# Uses fragment renderer + IPC instead of direct nft calls
nftban_portscan_classic_add_rules() {
    _nftban_portscan_classic_log "INFO" "Adding portscan logging rules via IPC"

    # Check if IPC is available
    if ! type -t nft_fragment_render_portscan_classic &>/dev/null; then
        _nftban_portscan_classic_log "ERROR" "Fragment library not loaded"
        return 1
    fi

    # Render the fragment with current configuration
    local fragment_path
    fragment_path=$(nft_fragment_render_portscan_classic) || {
        _nftban_portscan_classic_log "ERROR" "Failed to render fragment"
        return 1
    }

    _nftban_portscan_classic_log "DEBUG" "Fragment rendered: $fragment_path"

    # Apply via IPC
    if ! nft_fragment_apply "$fragment_path"; then
        _nftban_portscan_classic_log "ERROR" "Failed to apply fragment via IPC"
        return 1
    fi

    _nftban_portscan_classic_log "INFO" "Portscan rules applied via IPC"
    return 0
}

# Add jump to portscan chain from input chain
# Uses fragment renderer + IPC instead of direct nft calls
nftban_portscan_classic_add_jump() {
    local table_ipv4="${PORTSCAN_NFT_TABLE_IPV4:-ip nftban}"
    local chain="${PORTSCAN_NFT_CHAIN:-portscan_detection}"

    _nftban_portscan_classic_log "INFO" "Adding jump to portscan chain via IPC"

    # Check if jump already exists (to avoid duplicates)
    if nft_fragment_has_jump "$table_ipv4" "$chain" 2>/dev/null; then
        _nftban_portscan_classic_log "DEBUG" "Jump rule already exists, skipping"
        return 0
    fi

    # Render and apply jump fragment
    local fragment_path
    fragment_path=$(nft_fragment_render_portscan_classic_jump) || {
        _nftban_portscan_classic_log "ERROR" "Failed to render jump fragment"
        return 1
    }

    if ! nft_fragment_apply "$fragment_path"; then
        _nftban_portscan_classic_log "ERROR" "Failed to apply jump fragment via IPC"
        return 1
    fi

    _nftban_portscan_classic_log "INFO" "Jump rules applied via IPC"
    return 0
}

# Remove portscan rules
# Uses fragment renderer + IPC instead of direct nft calls
nftban_portscan_classic_remove_rules() {
    _nftban_portscan_classic_log "INFO" "Removing portscan rules via IPC"

    # Render cleanup fragment
    local fragment_path
    fragment_path=$(nft_fragment_render_portscan_classic_cleanup) || {
        _nftban_portscan_classic_log "ERROR" "Failed to render cleanup fragment"
        return 1
    }

    # Apply via IPC
    if ! nft_fragment_apply "$fragment_path"; then
        _nftban_portscan_classic_log "ERROR" "Failed to apply cleanup fragment via IPC"
        return 1
    fi

    _nftban_portscan_classic_log "INFO" "Portscan rules removed via IPC"
    return 0
}

# =============================================================================
# LOG PARSING
# =============================================================================

# Find the correct log source
# Returns: file path OR "journalctl" for systemd journal
nftban_portscan_classic_find_log() {
    local log_file="${PORTSCAN_CLASSIC_LOG_FILE}"
    local alt_logs="${PORTSCAN_CLASSIC_LOG_FILE_ALT:-/var/log/messages,/var/log/syslog}"
    local use_journalctl="${PORTSCAN_CLASSIC_USE_JOURNALCTL:-auto}"

    # Check if journalctl is explicitly enabled or auto-detect
    if [[ "$use_journalctl" == "true" ]]; then
        if command -v journalctl &>/dev/null; then
            echo "journalctl"
            return 0
        fi
    fi

    # Check primary log file
    if [[ -f "$log_file" ]]; then
        echo "$log_file"
        return 0
    fi

    # Check alternatives
    IFS=',' read -ra alt_array <<< "$alt_logs"
    for alt in "${alt_array[@]}"; do
        alt=$(echo "$alt" | xargs)  # trim whitespace
        if [[ -f "$alt" ]]; then
            echo "$alt"
            return 0
        fi
    done

    # Default to syslog
    if [[ -f "/var/log/syslog" ]]; then
        echo "/var/log/syslog"
        return 0
    fi

    # Auto-detect: if no traditional log files exist and journalctl is available, use it
    # This handles systemd-only systems (Fedora, RHEL 8+, AlmaLinux 9, etc.)
    if [[ "$use_journalctl" == "auto" ]] && command -v journalctl &>/dev/null; then
        echo "journalctl"
        return 0
    fi

    return 1
}

# Parse a log line for portscan info
# Returns: SRC_IP|DST_IP|DST_PORT|PROTO
nftban_portscan_classic_parse_line() {
    local line="$1"
    local log_prefix="${PORTSCAN_CLASSIC_LOG_PREFIX}"

    # Check if this is our log entry
    [[ "$line" =~ ${log_prefix} ]] || return 1

    local src_ip="" dst_ip="" dst_port="" proto=""

    # Extract source IP
    if [[ "$line" =~ SRC=([0-9a-fA-F.:]+) ]]; then
        src_ip="${BASH_REMATCH[1]}"
    fi

    # Extract destination IP
    if [[ "$line" =~ DST=([0-9a-fA-F.:]+) ]]; then
        dst_ip="${BASH_REMATCH[1]}"
    fi

    # Extract destination port
    if [[ "$line" =~ DPT=([0-9]+) ]]; then
        dst_port="${BASH_REMATCH[1]}"
    fi

    # Extract protocol
    if [[ "$line" =~ PROTO=([A-Z]+) ]]; then
        proto="${BASH_REMATCH[1]}"
    fi

    # Validate we got required fields
    [[ -n "$src_ip" && -n "$dst_port" ]] || return 1

    echo "${src_ip}|${dst_ip}|${dst_port}|${proto}"
    return 0
}

# Process log entries and detect portscans
nftban_portscan_classic_process_logs() {
    local log_source
    log_source=$(nftban_portscan_classic_find_log) || {
        _nftban_portscan_classic_log "ERROR" "No log source found (checked /var/log/kern.log, /var/log/messages, /var/log/syslog, journalctl)"
        return 1
    }

    local log_prefix="${PORTSCAN_CLASSIC_LOG_PREFIX}"
    local time_window="${PORTSCAN_CLASSIC_TIME_WINDOW}"
    local current_time
    current_time=$(date +%s)
    local cutoff_time
    cutoff_time=$((current_time - time_window))

    # Read recent log entries - handle both file and journalctl
    local log_cmd
    if [[ "$log_source" == "journalctl" ]]; then
        # Use journalctl for kernel logs on systemd systems
        # --since filters to recent entries, --no-pager for non-interactive
        # Use || true in case --grep returns no matches (exit code 1)
        log_cmd="{ journalctl -k --since '${time_window} seconds ago' --no-pager --grep='${log_prefix}' 2>/dev/null || true; } | tail -1000"
        _nftban_portscan_classic_log "DEBUG" "Reading from journalctl (kernel logs)"
    else
        # grep returns 1 when no matches found - use || true to handle this
        log_cmd="{ grep '${log_prefix}' '$log_source' 2>/dev/null || true; } | tail -1000"
        _nftban_portscan_classic_log "DEBUG" "Reading from file: $log_source"
    fi

    while IFS= read -r line; do
        local parsed
        parsed=$(nftban_portscan_classic_parse_line "$line") || continue

        IFS='|' read -r src_ip dst_ip dst_port proto <<< "$parsed"

        # Skip whitelisted IPs
        if nftban_portscan_classic_is_whitelisted "$src_ip"; then
            continue
        fi

        # Record this connection
        nftban_portscan_classic_record_connection "$src_ip" "$dst_ip" "$dst_port" "$current_time"

    done < <(eval "$log_cmd")

    # Analyze and block if needed
    nftban_portscan_classic_analyze_all

    # Save state for progressive banning persistence
    nftban_portscan_classic_save_state

    return 0
}

# =============================================================================
# CONNECTION TRACKING
# =============================================================================

# Record a connection attempt
nftban_portscan_classic_record_connection() {
    local src_ip="$1"
    local dst_ip="$2"
    local dst_port="$3"
    local timestamp="$4"

    local max_tracked="${PORTSCAN_CLASSIC_MAX_TRACKED_IPS}"

    # Check if we're tracking too many IPs
    if [[ ${#_PORTSCAN_CLASSIC_IP_PORTS[@]} -ge $max_tracked ]]; then
        nftban_portscan_classic_cleanup_old_entries
    fi

    # Add port to tracked list for this IP
    local current_ports="${_PORTSCAN_CLASSIC_IP_PORTS[$src_ip]:-}"
    local port_pattern=" ${dst_port} "
    if [[ ! " $current_ports " =~ $port_pattern ]]; then
        _PORTSCAN_CLASSIC_IP_PORTS["$src_ip"]="${current_ports} ${dst_port}"
    fi

    # Add timestamp
    local current_timestamps="${_PORTSCAN_CLASSIC_IP_TIMESTAMPS[$src_ip]:-}"
    _PORTSCAN_CLASSIC_IP_TIMESTAMPS["$src_ip"]="${current_timestamps} ${timestamp}"

    # Add target if different from self
    if [[ -n "$dst_ip" ]]; then
        local current_targets="${_PORTSCAN_CLASSIC_IP_TARGETS[$src_ip]:-}"
        local target_pattern=" ${dst_ip} "
        if [[ ! " $current_targets " =~ $target_pattern ]]; then
            _PORTSCAN_CLASSIC_IP_TARGETS["$src_ip"]="${current_targets} ${dst_ip}"
        fi
    fi

    return 0
}

# Cleanup old tracking entries
nftban_portscan_classic_cleanup_old_entries() {
    local time_window="${PORTSCAN_CLASSIC_TIME_WINDOW}"
    local current_time
    current_time=$(date +%s)
    local cutoff_time
    cutoff_time=$((current_time - time_window))

    for ip in "${!_PORTSCAN_CLASSIC_IP_TIMESTAMPS[@]}"; do
        local timestamps="${_PORTSCAN_CLASSIC_IP_TIMESTAMPS[$ip]}"
        local new_timestamps=""
        local has_recent=false

        # Use read -ra to properly split into array
        local -a ts_array
        read -ra ts_array <<< "$timestamps"

        for ts in "${ts_array[@]}"; do
            # Skip empty or non-numeric entries
            [[ -z "$ts" || ! "$ts" =~ ^[0-9]+$ ]] && continue

            if [[ $ts -ge $cutoff_time ]]; then
                new_timestamps="${new_timestamps} ${ts}"
                has_recent=true
            fi
        done

        if [[ "$has_recent" == "true" ]]; then
            _PORTSCAN_CLASSIC_IP_TIMESTAMPS["$ip"]="$new_timestamps"
        else
            # No recent activity, remove tracking
            unset "_PORTSCAN_CLASSIC_IP_PORTS[$ip]"
            unset "_PORTSCAN_CLASSIC_IP_TIMESTAMPS[$ip]"
            unset "_PORTSCAN_CLASSIC_IP_TARGETS[$ip]"
        fi
    done

    return 0
}

# =============================================================================
# SCAN DETECTION
# =============================================================================

# Analyze all tracked IPs for portscan behavior
nftban_portscan_classic_analyze_all() {
    local min_ports="${PORTSCAN_CLASSIC_MIN_PORTS}"

    for ip in "${!_PORTSCAN_CLASSIC_IP_PORTS[@]}"; do
        # Skip already blocked IPs
        [[ -n "${_PORTSCAN_CLASSIC_IP_BLOCKED[$ip]:-}" ]] && continue

        local scan_type
        # detect_scan_type returns 1 if no scan detected - that's normal behavior
        scan_type=$(nftban_portscan_classic_detect_scan_type "$ip") || true

        if [[ -n "$scan_type" ]]; then
            nftban_portscan_classic_handle_detection "$ip" "$scan_type"
        fi
    done

    return 0
}

# Detect what type of scan an IP is performing
nftban_portscan_classic_detect_scan_type() {
    local ip="$1"

    local ports="${_PORTSCAN_CLASSIC_IP_PORTS[$ip]:-}"
    local targets="${_PORTSCAN_CLASSIC_IP_TARGETS[$ip]:-}"

    # Count unique ports
    local port_count
    port_count=$(echo "$ports" | tr ' ' '\n' | grep -v '^$' | sort -u | wc -l)

    # Count unique targets
    local target_count
    target_count=$(echo "$targets" | tr ' ' '\n' | grep -v '^$' | sort -u | wc -l)

    local vertical_threshold="${PORTSCAN_CLASSIC_VERTICAL_PORTS}"
    local horizontal_threshold="${PORTSCAN_CLASSIC_HORIZONTAL_TARGETS}"
    local block_threshold="${PORTSCAN_CLASSIC_BLOCK_RANGE}"
    local strobe_ports="${PORTSCAN_CLASSIC_STROBE_PORTS}"

    # Check for block scan (scanning port ranges)
    if [[ $port_count -ge $block_threshold ]]; then
        echo "block"
        return 0
    fi

    # Check for vertical scan (many ports on one target)
    if [[ $port_count -ge $vertical_threshold && $target_count -le 1 ]]; then
        echo "vertical"
        return 0
    fi

    # Check for horizontal scan (same ports across many targets)
    if [[ $target_count -ge $horizontal_threshold && $port_count -le 3 ]]; then
        echo "horizontal"
        return 0
    fi

    # Check for strobe scan (rapid scanning of common ports)
    if [[ $port_count -ge $strobe_ports ]]; then
        local timestamps="${_PORTSCAN_CLASSIC_IP_TIMESTAMPS[$ip]}"
        # Convert to array, filtering empty elements
        local -a ts_array
        read -ra ts_array <<< "$timestamps"
        local ts_count=${#ts_array[@]}

        if [[ $ts_count -gt 1 ]]; then
            # Get first and last timestamps (ensure single values)
            local first_ts="${ts_array[0]}"
            local last_ts="${ts_array[$((ts_count-1))]}"

            # Validate timestamps are numeric before arithmetic
            if [[ "$first_ts" =~ ^[0-9]+$ ]] && [[ "$last_ts" =~ ^[0-9]+$ ]]; then
                local duration=$((last_ts - first_ts))

                # If many connections in short time
                if [[ $duration -lt 10 && $port_count -ge $strobe_ports ]]; then
                    echo "strobe"
                    return 0
                fi
            fi
        fi
    fi

    # Check minimum port threshold
    local min_ports="${PORTSCAN_CLASSIC_MIN_PORTS}"
    if [[ $port_count -ge $min_ports ]]; then
        echo "generic"
        return 0
    fi

    return 1
}

# =============================================================================
# BLOCKING
# =============================================================================

# Handle detected portscan
nftban_portscan_classic_handle_detection() {
    local ip="$1"
    local scan_type="$2"

    local action="${PORTSCAN_CLASSIC_ACTION}"

    _nftban_portscan_classic_log "WARN" "Detected ${scan_type} scan from ${ip}"

    case "$action" in
        block)
            nftban_portscan_classic_block_ip "$ip" "$scan_type"
            ;;
        log)
            _nftban_portscan_classic_log "INFO" "Logged ${scan_type} scan from ${ip} (no block)"
            ;;
        alert)
            nftban_portscan_classic_send_alert "$ip" "$scan_type"
            ;;
        block_and_alert)
            nftban_portscan_classic_block_ip "$ip" "$scan_type"
            nftban_portscan_classic_send_alert "$ip" "$scan_type"
            ;;
    esac

    return 0
}

# Block an IP
# Uses IPC instead of direct nft calls (single-writer architecture)
nftban_portscan_classic_block_ip() {
    local ip="$1"
    local scan_type="$2"

    # Determine ban duration
    local duration
    case "$scan_type" in
        vertical)   duration="${PORTSCAN_CLASSIC_BAN_VERTICAL:-1800}" ;;
        horizontal) duration="${PORTSCAN_CLASSIC_BAN_HORIZONTAL:-3600}" ;;
        block)      duration="${PORTSCAN_CLASSIC_BAN_BLOCK:-7200}" ;;
        strobe)     duration="${PORTSCAN_CLASSIC_BAN_STROBE:-600}" ;;
        *)          duration="${PORTSCAN_CLASSIC_BAN_DEFAULT:-1800}" ;;
    esac

    # Progressive banning
    if [[ "${PORTSCAN_CLASSIC_PROGRESSIVE_BAN:-true}" == "true" ]]; then
        local ban_count="${_PORTSCAN_CLASSIC_IP_BAN_COUNT[$ip]:-0}"
        local multiplier="${PORTSCAN_CLASSIC_PROGRESSIVE_MULTIPLIER:-2}"
        local max_duration="${PORTSCAN_CLASSIC_PROGRESSIVE_MAX:-86400}"

        if [[ $ban_count -gt 0 ]]; then
            duration=$((duration * multiplier * ban_count))
            [[ $duration -gt $max_duration ]] && duration=$max_duration
        fi

        _PORTSCAN_CLASSIC_IP_BAN_COUNT["$ip"]=$((ban_count + 1))
    fi

    # Use nftban ban command if available (preferred - handles all logic)
    if type -t nftban_ban &>/dev/null; then
        nftban_ban "$ip" \
            --timeout "$duration" \
            --reason "portscan:${scan_type}" \
            --source "portscan-classic"
    # Fall back to IPC directly (single-writer architecture)
    elif type -t nft_ipc_ban &>/dev/null; then
        nft_ipc_ban "$ip" "$duration" "portscan:${scan_type}" "portscan-classic"
    else
        _nftban_portscan_classic_log "ERROR" "No ban method available (IPC library not loaded)"
        return 1
    fi

    # Record block
    _PORTSCAN_CLASSIC_IP_BLOCKED["$ip"]=$(date +%s)

    _nftban_portscan_classic_log "INFO" "Blocked ${ip} for ${duration}s (${scan_type} scan)"

    return 0
}

# Send alert notification
nftban_portscan_classic_send_alert() {
    local ip="$1"
    local scan_type="$2"

    local ports="${_PORTSCAN_CLASSIC_IP_PORTS[$ip]:-unknown}"
    local port_count
    port_count=$(echo "$ports" | tr ' ' '\n' | grep -v '^$' | wc -l)

    local message="Portscan detected: ${scan_type} scan from ${ip} (${port_count} ports)"

    # Email notification
    if [[ "${PORTSCAN_NOTIFY_EMAIL:-false}" == "true" && -n "${PORTSCAN_NOTIFY_EMAIL_TO:-}" ]]; then
        echo "$message" | mail -s "[NFTBan] Portscan Alert: ${ip}" "${PORTSCAN_NOTIFY_EMAIL_TO}" 2>/dev/null || true
    fi

    # Webhook notification
    if [[ "${PORTSCAN_NOTIFY_WEBHOOK:-false}" == "true" && -n "${PORTSCAN_NOTIFY_WEBHOOK_URL:-}" ]]; then
        curl -s -X POST "${PORTSCAN_NOTIFY_WEBHOOK_URL}" \
            -H "Content-Type: application/json" \
            -d "{\"type\":\"portscan\",\"ip\":\"${ip}\",\"scan_type\":\"${scan_type}\",\"ports\":${port_count}}" \
            2>/dev/null || true
    fi

    return 0
}

# =============================================================================
# WHITELIST
# =============================================================================

# Check if IP is whitelisted
nftban_portscan_classic_is_whitelisted() {
    local ip="$1"

    # Localhost
    if [[ "${PORTSCAN_WHITELIST_LOCALHOST:-true}" == "true" ]]; then
        case "$ip" in
            127.*|::1|0.0.0.0) return 0 ;;
        esac
    fi

    # Private networks
    if [[ "${PORTSCAN_WHITELIST_PRIVATE:-true}" == "true" ]]; then
        case "$ip" in
            10.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|192.168.*) return 0 ;;
            fc*|fd*) return 0 ;;  # IPv6 private
        esac
    fi

    # Check whitelist file
    local whitelist_file="${PORTSCAN_WHITELIST_FILE:-}"
    if [[ -f "$whitelist_file" ]]; then
        if grep -q "^${ip}$" "$whitelist_file" 2>/dev/null; then
            return 0
        fi
    fi

    # Use nftban whitelist check if available
    if type -t nftban_is_whitelisted &>/dev/null; then
        if nftban_is_whitelisted "$ip"; then
            return 0
        fi
    fi

    return 1
}

# =============================================================================
# MODULE LIFECYCLE
# =============================================================================

# Enable classic portscan detection
nftban_portscan_classic_enable() {
    _nftban_portscan_classic_log "INFO" "Enabling classic portscan detection"

    # Load configuration
    nftban_portscan_classic_load_config

    # Initialize state
    nftban_portscan_classic_init_state

    # Create nftables chain and rules
    nftban_portscan_classic_create_chain
    nftban_portscan_classic_add_rules
    nftban_portscan_classic_add_jump

    _nftban_portscan_classic_log "INFO" "Classic portscan detection enabled"
    return 0
}

# Disable classic portscan detection
nftban_portscan_classic_disable() {
    _nftban_portscan_classic_log "INFO" "Disabling classic portscan detection"

    # Save state before disabling
    nftban_portscan_classic_save_state

    # Remove rules
    nftban_portscan_classic_remove_rules

    _nftban_portscan_classic_log "INFO" "Classic portscan detection disabled"
    return 0
}

# Get status
nftban_portscan_classic_status() {
    local table_ipv4="${PORTSCAN_NFT_TABLE_IPV4:-ip nftban}"
    local chain="${PORTSCAN_NFT_CHAIN:-portscan_detection}"

    echo "=== NFTBan Portscan Classic Mode Status ==="
    echo ""

    # Check if chain exists
    if nft list chain ${table_ipv4} ${chain} &>/dev/null; then
        echo "Status: ACTIVE"
    else
        echo "Status: INACTIVE"
    fi

    echo ""
    echo "Tracking:"
    echo "  IPs tracked: ${#_PORTSCAN_CLASSIC_IP_PORTS[@]}"
    echo "  IPs blocked: ${#_PORTSCAN_CLASSIC_IP_BLOCKED[@]}"

    echo ""
    echo "Configuration:"
    echo "  Min ports for detection: ${PORTSCAN_CLASSIC_MIN_PORTS:-5}"
    echo "  Time window: ${PORTSCAN_CLASSIC_TIME_WINDOW:-60}s"
    local log_source
    log_source=$(nftban_portscan_classic_find_log 2>/dev/null) || log_source="not found"
    if [[ "$log_source" == "journalctl" ]]; then
        echo "  Log source: journalctl -k (systemd kernel journal)"
    else
        echo "  Log source: $log_source"
    fi

    return 0
}

# Process pending detections (called periodically)
nftban_portscan_classic_run() {
    # Process logs
    nftban_portscan_classic_process_logs

    # Cleanup old entries
    nftban_portscan_classic_cleanup_old_entries

    return 0
}

# =============================================================================
# END OF CLASSIC MODE IMPLEMENTATION
# =============================================================================
