#!/usr/bin/env bash
# =============================================================================
# NFTBan - Portscan Protection Suricata Mode
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_portscan_suricata"
# meta:type="module"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2025-10-26"
# meta:description="Suricata IDS-based portscan detection via EVE JSON alerts"
# meta:input="Suricata EVE JSON alerts"
# meta:output="Ban actions for detected port scanners"
# meta:depends="nft_ipc.sh, suricata"
# meta:inventory.files="/var/lib/nftban/portscan-suricata-state.db"
# meta:inventory.binaries="nft, suricata"
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/conf.d/portscan/suricata.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================
# shellcheck disable=SC1083  # Braces in nftables syntax are literal, not bash
# =============================================================================

set -Eeuo pipefail

# Prevent double sourcing
[[ -n "${_NFTBAN_PORTSCAN_SURICATA_LOADED:-}" ]] && return 0
declare -g _NFTBAN_PORTSCAN_SURICATA_LOADED=1

# =============================================================================
# LOAD IPC AND SHARED LIBRARIES
# =============================================================================

: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/nft_ipc.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/nftban_timestamp.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/nftban_file_utils.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/nftban_service_control.sh" 2>/dev/null || true

# =============================================================================
# CONFIGURATION LOADING
# =============================================================================

# Load suricata mode configuration
nftban_portscan_suricata_load_config() {
    local config_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/portscan/suricata.conf"
    local local_config="${config_file%.conf}.conf.local"

    # Load base config
    if [[ -f "$config_file" ]]; then
        # shellcheck source=/dev/null
        source "$config_file" || true
    else
        _nftban_portscan_suricata_log "WARN" "Config not found: $config_file"
    fi

    # Load local overrides
    if [[ -f "$local_config" ]]; then
        # shellcheck source=/dev/null
        _source_local "$local_config"
    fi

    # Set defaults
    : "${PORTSCAN_SURICATA_EVE_FILE:=${NFTBAN_LOG_DIR:-/var/log/nftban}/suricata/eve-alerts.json}"
    : "${PORTSCAN_SURICATA_SIG_PATTERNS:=[Pp]ort[Ss]can|[Pp]ort [Ss]weep|SCAN|Nmap|masscan}"
    : "${PORTSCAN_SURICATA_THRESHOLD_OBSERVE:=0.25}"
    : "${PORTSCAN_SURICATA_THRESHOLD_BLOCK_SHORT:=0.45}"
    : "${PORTSCAN_SURICATA_THRESHOLD_BLOCK_LONG:=0.65}"
    : "${PORTSCAN_SURICATA_THRESHOLD_BLOCK_PERMANENT:=0.85}"
    : "${PORTSCAN_SURICATA_BAN_DURATION_SHORT:=900}"
    : "${PORTSCAN_SURICATA_BAN_DURATION_LONG:=3600}"
    : "${PORTSCAN_SURICATA_BAN_DURATION_PERMANENT:=86400}"
    : "${PORTSCAN_SURICATA_ALERT_WINDOW:=300}"
    : "${PORTSCAN_SURICATA_SCORE_DECAY:=1800}"
    : "${PORTSCAN_SURICATA_MAX_TRACKED_IPS:=10000}"
    : "${PORTSCAN_SURICATA_BATCH_SIZE:=100}"
    : "${PORTSCAN_SURICATA_STATE_FILE:=/var/lib/nftban/portscan-suricata-state.db}"

    return 0
}

# =============================================================================
# LOGGING
# =============================================================================

# Log file for portscan suricata mode
# Default log file (can be overridden by config)
: "${PORTSCAN_SURICATA_LOG_FILE:=${NFTBAN_LOG_DIR:-/var/log/nftban}/portscan-suricata.log}"

_nftban_portscan_suricata_log() {
    local level="$1"
    local message="$2"
    local log_file="${PORTSCAN_SURICATA_LOG_FILE:-${NFTBAN_LOG_DIR:-/var/log/nftban}/portscan-suricata.log}"

    mkdir -p "$(dirname "$log_file")" 2>/dev/null || return 1

    # Use library timestamp if available, fallback to date
    local timestamp
    if type -t nftban_timestamp_log &>/dev/null; then
        timestamp=$(nftban_timestamp_log)
    else
        timestamp="[$(date '+%Y-%m-%d %H:%M:%S')]"
    fi

    echo "${timestamp} [SURICATA] [$level] $message" >> "$log_file"
}

# =============================================================================
# SURICATA AVAILABILITY DETECTION
# =============================================================================

# Check if Suricata binary exists
nftban_portscan_suricata_binary_exists() {
    local binary="${PORTSCAN_SURICATA_BINARY:-/usr/bin/suricata}"
    [[ -x "$binary" ]]
}

# Check if Suricata service is running
nftban_portscan_suricata_service_running() {
    local service_name="${PORTSCAN_SURICATA_SERVICE_NAME:-suricata}"

    # Use library function if available
    if type -t nftban_service_is_active &>/dev/null; then
        if nftban_service_is_active "$service_name"; then
            return 0
        fi
    else
        # Fallback: Try systemctl first
        if command -v systemctl &>/dev/null; then
            if systemctl is-active --quiet "$service_name" 2>/dev/null; then
                return 0
            fi
        fi
    fi

    # Fall back to pgrep
    if pgrep -x suricata &>/dev/null; then
        return 0
    fi

    return 1
}

# Check if EVE JSON file is active (being written to)
nftban_portscan_suricata_eve_active() {
    local eve_file="${PORTSCAN_SURICATA_EVE_FILE}"
    local freshness_threshold="${PORTSCAN_EVE_FRESHNESS_THRESHOLD:-60}"

    [[ -f "$eve_file" ]] || return 1

    # Use library function if available
    if type -t nftban_file_is_fresh &>/dev/null; then
        nftban_file_is_fresh "$eve_file" "$freshness_threshold"
        return $?
    fi

    # Fallback: manual check (use -L to follow symlinks)
    local file_mtime
    file_mtime=$(stat -L -c %Y "$eve_file" 2>/dev/null || stat -L -f %m "$eve_file" 2>/dev/null) || return 1

    local current_time
    current_time=$(date +%s)

    local age
    age=$((current_time - file_mtime))

    [[ $age -le $freshness_threshold ]]
}

# Combined availability check
nftban_portscan_suricata_is_available() {
    local check_binary="${PORTSCAN_AUTO_CHECK_BINARY:-true}"
    local check_service="${PORTSCAN_AUTO_CHECK_SERVICE:-true}"
    local check_eve="${PORTSCAN_AUTO_CHECK_EVE_FILE:-true}"

    # Check binary
    if [[ "$check_binary" == "true" ]]; then
        if ! nftban_portscan_suricata_binary_exists; then
            return 1
        fi
    fi

    # Check service
    if [[ "$check_service" == "true" ]]; then
        if ! nftban_portscan_suricata_service_running; then
            return 1
        fi
    fi

    # Check EVE file
    if [[ "$check_eve" == "true" ]]; then
        if ! nftban_portscan_suricata_eve_active; then
            return 1
        fi
    fi

    return 0
}

# =============================================================================
# STATE TRACKING
# =============================================================================

# In-memory tracking
declare -gA _PORTSCAN_SURICATA_IP_SCORES       # IP -> current score
declare -gA _PORTSCAN_SURICATA_IP_ALERTS       # IP -> alert count
declare -gA _PORTSCAN_SURICATA_IP_FIRST_SEEN   # IP -> first seen timestamp
declare -gA _PORTSCAN_SURICATA_IP_LAST_SEEN    # IP -> last seen timestamp
declare -gA _PORTSCAN_SURICATA_IP_SCAN_TYPES   # IP -> scan types seen
declare -gA _PORTSCAN_SURICATA_IP_BLOCKED      # IP -> blocked timestamp
declare -g  _PORTSCAN_SURICATA_EVE_OFFSET=0    # EVE file read offset

# Initialize state
nftban_portscan_suricata_init_state() {
    _PORTSCAN_SURICATA_IP_SCORES=()
    _PORTSCAN_SURICATA_IP_ALERTS=()
    _PORTSCAN_SURICATA_IP_FIRST_SEEN=()
    _PORTSCAN_SURICATA_IP_LAST_SEEN=()
    _PORTSCAN_SURICATA_IP_SCAN_TYPES=()
    _PORTSCAN_SURICATA_IP_BLOCKED=()
    _PORTSCAN_SURICATA_EVE_OFFSET=0

    # Load persistent state
    if [[ -f "${PORTSCAN_SURICATA_STATE_FILE}" ]]; then
        nftban_portscan_suricata_load_state
    fi

    return 0
}

# Save state to disk
nftban_portscan_suricata_save_state() {
    local state_file="${PORTSCAN_SURICATA_STATE_FILE}"
    local state_dir
    state_dir=$(dirname "$state_file")

    mkdir -p "$state_dir" 2>/dev/null || true

    # Use library timestamp if available
    local state_timestamp
    if type -t nftban_timestamp &>/dev/null; then
        state_timestamp=$(nftban_timestamp)
    else
        state_timestamp=$(date -Iseconds)
    fi

    {
        echo "# NFTBan Portscan Suricata State - ${state_timestamp}"
        echo "# Format: TYPE|IP|DATA"
        echo "EVE_OFFSET|0|${_PORTSCAN_SURICATA_EVE_OFFSET}"

        for ip in "${!_PORTSCAN_SURICATA_IP_SCORES[@]}"; do
            echo "SCORE|${ip}|${_PORTSCAN_SURICATA_IP_SCORES[$ip]}"
        done

        for ip in "${!_PORTSCAN_SURICATA_IP_BLOCKED[@]}"; do
            echo "BLOCKED|${ip}|${_PORTSCAN_SURICATA_IP_BLOCKED[$ip]}"
        done
    } > "${state_file}.tmp" && mv "${state_file}.tmp" "${state_file}"

    return 0
}

# Load state from disk
nftban_portscan_suricata_load_state() {
    local state_file="${PORTSCAN_SURICATA_STATE_FILE}"

    [[ -f "$state_file" ]] || return 0

    while IFS='|' read -r type key data; do
        [[ "$type" =~ ^# ]] && continue
        [[ -z "$type" ]] && continue

        case "$type" in
            EVE_OFFSET)
                _PORTSCAN_SURICATA_EVE_OFFSET="$data"
                ;;
            SCORE)
                _PORTSCAN_SURICATA_IP_SCORES["$key"]="$data"
                ;;
            BLOCKED)
                _PORTSCAN_SURICATA_IP_BLOCKED["$key"]="$data"
                ;;
        esac
    done < "$state_file"

    return 0
}

# =============================================================================
# EVE JSON PARSING
# =============================================================================

# Read new alerts from EVE file
nftban_portscan_suricata_read_eve() {
    local eve_file="${PORTSCAN_SURICATA_EVE_FILE}"
    local batch_size="${PORTSCAN_SURICATA_BATCH_SIZE}"
    local sig_patterns="${PORTSCAN_SURICATA_SIG_PATTERNS}"

    [[ -f "$eve_file" ]] || return 1

    # Check if file was rotated (smaller than offset)
    local file_size
    file_size=$(stat -c %s "$eve_file" 2>/dev/null) || return 1

    if [[ $file_size -lt $_PORTSCAN_SURICATA_EVE_OFFSET ]]; then
        _PORTSCAN_SURICATA_EVE_OFFSET=0
    fi

    # Read new entries
    local count=0
    while IFS= read -r line; do
        nftban_portscan_suricata_process_alert "$line"
        # v1.19.20 FIX
        ((count++)) || true
        [[ $count -ge $batch_size ]] && break
    done < <(tail -c +$((_PORTSCAN_SURICATA_EVE_OFFSET + 1)) "$eve_file" 2>/dev/null | \
             grep -E '"event_type"\s*:\s*"alert"' | \
             grep -iE "$sig_patterns" | \
             head -n "$batch_size")

    # Update offset
    _PORTSCAN_SURICATA_EVE_OFFSET=$file_size

    return 0
}

# Process a single EVE alert
nftban_portscan_suricata_process_alert() {
    local alert_json="$1"

    # Check if jq is available
    if ! command -v jq &>/dev/null; then
        nftban_portscan_suricata_process_alert_regex "$alert_json"
        return $?
    fi

    # Parse with jq
    local src_ip severity signature category

    src_ip=$(echo "$alert_json" | jq -r '.src_ip // empty' 2>/dev/null)
    [[ -z "$src_ip" ]] && return 1

    severity=$(echo "$alert_json" | jq -r '.alert.severity // 3' 2>/dev/null)
    signature=$(echo "$alert_json" | jq -r '.alert.signature // ""' 2>/dev/null)
    category=$(echo "$alert_json" | jq -r '.alert.category // ""' 2>/dev/null)

    # Process the alert
    nftban_portscan_suricata_record_alert "$src_ip" "$severity" "$signature" "$category"

    return 0
}

# Fallback regex parser for EVE alerts
nftban_portscan_suricata_process_alert_regex() {
    local alert_json="$1"

    local src_ip="" severity="3" signature="" category=""

    # Extract src_ip
    if [[ "$alert_json" =~ \"src_ip\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
        src_ip="${BASH_REMATCH[1]}"
    fi

    [[ -z "$src_ip" ]] && return 1

    # Extract severity
    if [[ "$alert_json" =~ \"severity\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
        severity="${BASH_REMATCH[1]}"
    fi

    # Extract signature
    if [[ "$alert_json" =~ \"signature\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
        signature="${BASH_REMATCH[1]}"
    fi

    # Extract category
    if [[ "$alert_json" =~ \"category\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
        category="${BASH_REMATCH[1]}"
    fi

    nftban_portscan_suricata_record_alert "$src_ip" "$severity" "$signature" "$category"

    return 0
}

# Record an alert and update scores
nftban_portscan_suricata_record_alert() {
    local src_ip="$1"
    local severity="$2"
    local signature="$3"
    local category="$4"

    local current_time
    # Use library function if available, fallback to date
    if type -t nftban_timestamp_unix &>/dev/null; then
        current_time=$(nftban_timestamp_unix)
    else
        current_time=$(date +%s)
    fi

    # Skip whitelisted IPs
    if nftban_portscan_suricata_is_whitelisted "$src_ip"; then
        return 0
    fi

    # Skip already blocked IPs
    [[ -n "${_PORTSCAN_SURICATA_IP_BLOCKED[$src_ip]:-}" ]] && return 0

    # Update tracking
    [[ -z "${_PORTSCAN_SURICATA_IP_FIRST_SEEN[$src_ip]:-}" ]] && \
        _PORTSCAN_SURICATA_IP_FIRST_SEEN["$src_ip"]=$current_time

    _PORTSCAN_SURICATA_IP_LAST_SEEN["$src_ip"]=$current_time

    # Increment alert count
    local alert_count="${_PORTSCAN_SURICATA_IP_ALERTS[$src_ip]:-0}"
    _PORTSCAN_SURICATA_IP_ALERTS["$src_ip"]=$((alert_count + 1))

    # Detect scan type from signature
    local scan_type
    scan_type=$(nftban_portscan_suricata_detect_scan_type "$signature")

    if [[ -n "$scan_type" ]]; then
        local current_types="${_PORTSCAN_SURICATA_IP_SCAN_TYPES[$src_ip]:-}"
        local type_pattern=" ${scan_type} "
        if [[ ! " $current_types " =~ $type_pattern ]]; then
            _PORTSCAN_SURICATA_IP_SCAN_TYPES["$src_ip"]="${current_types} ${scan_type}"
        fi
    fi

    # Calculate score
    local score
    score=$(nftban_portscan_suricata_calculate_score "$src_ip" "$severity" "$scan_type")

    _PORTSCAN_SURICATA_IP_SCORES["$src_ip"]="$score"

    # Log if verbose
    if [[ "${PORTSCAN_SURICATA_LOG_ALL_ALERTS:-false}" == "true" ]]; then
        _nftban_portscan_suricata_log "DEBUG" "Alert: IP=${src_ip} severity=${severity} sig=${signature} score=${score}"
    fi

    # Check thresholds and take action
    nftban_portscan_suricata_check_thresholds "$src_ip" "$score"

    return 0
}

# =============================================================================
# SCAN TYPE DETECTION
# =============================================================================

# Detect scan type from signature string
nftban_portscan_suricata_detect_scan_type() {
    local signature="$1"

    local sig_lower
    sig_lower=$(echo "$signature" | tr '[:upper:]' '[:lower:]')

    # Check for specific scan types
    if [[ "$sig_lower" =~ portsweep|port[[:space:]]sweep ]]; then
        echo "portsweep"
    elif [[ "$sig_lower" =~ decoy|spoofed ]]; then
        echo "decoy"
    elif [[ "$sig_lower" =~ distributed ]]; then
        echo "distributed"
    elif [[ "$sig_lower" =~ nmap ]]; then
        echo "nmap"
    elif [[ "$sig_lower" =~ masscan ]]; then
        echo "masscan"
    elif [[ "$sig_lower" =~ portscan|port[[:space:]]scan ]]; then
        echo "portscan"
    elif [[ "$sig_lower" =~ scan ]]; then
        echo "generic"
    fi

    return 0
}

# =============================================================================
# SCORING ENGINE
# =============================================================================

# Calculate score for an IP
nftban_portscan_suricata_calculate_score() {
    local ip="$1"
    local severity="$2"
    local scan_type="$3"

    local score=0.0
    local current_score="${_PORTSCAN_SURICATA_IP_SCORES[$ip]:-0}"

    # Apply score decay
    local last_seen="${_PORTSCAN_SURICATA_IP_LAST_SEEN[$ip]:-0}"
    local current_time
    # Use library function if available, fallback to date
    if type -t nftban_timestamp_unix &>/dev/null; then
        current_time=$(nftban_timestamp_unix)
    else
        current_time=$(date +%s)
    fi
    local score_decay="${PORTSCAN_SURICATA_SCORE_DECAY}"

    if [[ $last_seen -gt 0 && -n "$current_score" ]]; then
        local time_diff
        time_diff=$((current_time - last_seen))
        if [[ $time_diff -gt $score_decay ]]; then
            current_score=0
        else
            # Linear decay
            local decay_factor
            decay_factor=$(echo "scale=4; 1 - ($time_diff / $score_decay)" | bc 2>/dev/null || echo "0.5")
            current_score=$(echo "scale=4; $current_score * $decay_factor" | bc 2>/dev/null || echo "0")
        fi
    fi

    score="$current_score"

    # Add severity score (1=High, 2=Medium, 3=Low, 4=Info - matches Go)
    local severity_score=0
    case "$severity" in
        1) severity_score="${PORTSCAN_SURICATA_SCORE_SEVERITY_1:-0.50}" ;;
        2) severity_score="${PORTSCAN_SURICATA_SCORE_SEVERITY_2:-0.35}" ;;
        3) severity_score="${PORTSCAN_SURICATA_SCORE_SEVERITY_3:-0.20}" ;;
        4) severity_score="${PORTSCAN_SURICATA_SCORE_SEVERITY_4:-0.10}" ;;
    esac

    score=$(echo "scale=4; $score + $severity_score" | bc 2>/dev/null || echo "$score")

    # Add scan type bonus
    local type_score=0
    case "$scan_type" in
        portscan)    type_score="${PORTSCAN_SURICATA_SCORE_PORTSCAN:-0.15}" ;;
        portsweep)   type_score="${PORTSCAN_SURICATA_SCORE_PORTSWEEP:-0.20}" ;;
        decoy)       type_score="${PORTSCAN_SURICATA_SCORE_DECOY:-0.25}" ;;
        distributed) type_score="${PORTSCAN_SURICATA_SCORE_DISTRIBUTED:-0.30}" ;;
        nmap|masscan) type_score="${PORTSCAN_SURICATA_SCORE_KNOWN_TOOL:-0.20}" ;;
    esac

    score=$(echo "scale=4; $score + $type_score" | bc 2>/dev/null || echo "$score")

    # Add repetition bonus
    local alert_count="${_PORTSCAN_SURICATA_IP_ALERTS[$ip]:-0}"
    local repeat_score=0

    if [[ $alert_count -ge 20 ]]; then
        repeat_score="${PORTSCAN_SURICATA_SCORE_REPEAT_20:-0.30}"
    elif [[ $alert_count -ge 10 ]]; then
        repeat_score="${PORTSCAN_SURICATA_SCORE_REPEAT_10:-0.20}"
    elif [[ $alert_count -ge 5 ]]; then
        repeat_score="${PORTSCAN_SURICATA_SCORE_REPEAT_5:-0.10}"
    fi

    score=$(echo "scale=4; $score + $repeat_score" | bc 2>/dev/null || echo "$score")

    # Add reputation bonus if feeds integration enabled
    if [[ "${PORTSCAN_SURICATA_USE_FEEDS:-true}" == "true" ]]; then
        if type -t nftban_feeds_is_known_bad &>/dev/null; then
            if nftban_feeds_is_known_bad "$ip" 2>/dev/null; then
                local rep_score="${PORTSCAN_SURICATA_SCORE_BAD_REPUTATION:-0.15}"
                score=$(echo "scale=4; $score + $rep_score" | bc 2>/dev/null || echo "$score")
            fi
        fi
    fi

    # Add GeoIP risk if enabled
    if [[ "${PORTSCAN_SURICATA_USE_GEOIP:-true}" == "true" ]]; then
        if type -t nftban_geoip_is_high_risk &>/dev/null; then
            if nftban_geoip_is_high_risk "$ip" 2>/dev/null; then
                local geo_score="${PORTSCAN_SURICATA_SCORE_HIGH_RISK_GEO:-0.10}"
                score=$(echo "scale=4; $score + $geo_score" | bc 2>/dev/null || echo "$score")
            fi
        fi
    fi

    # Cap score at 1.0
    if (( $(echo "$score > 1.0" | bc -l 2>/dev/null || echo 0) )); then
        score="1.0"
    fi

    echo "$score"
}

# =============================================================================
# THRESHOLD ACTIONS
# =============================================================================

# Check thresholds and take action
nftban_portscan_suricata_check_thresholds() {
    local ip="$1"
    local score="$2"

    local threshold_observe="${PORTSCAN_SURICATA_THRESHOLD_OBSERVE}"
    local threshold_short="${PORTSCAN_SURICATA_THRESHOLD_BLOCK_SHORT}"
    local threshold_long="${PORTSCAN_SURICATA_THRESHOLD_BLOCK_LONG}"
    local threshold_permanent="${PORTSCAN_SURICATA_THRESHOLD_BLOCK_PERMANENT}"

    # Use bc for float comparison
    local compare_result

    # Check permanent threshold
    compare_result=$(echo "$score >= $threshold_permanent" | bc -l 2>/dev/null || echo 0)
    if [[ "$compare_result" == "1" ]]; then
        nftban_portscan_suricata_block_ip "$ip" "permanent" "$score"
        return 0
    fi

    # Check long block threshold
    compare_result=$(echo "$score >= $threshold_long" | bc -l 2>/dev/null || echo 0)
    if [[ "$compare_result" == "1" ]]; then
        nftban_portscan_suricata_block_ip "$ip" "long" "$score"
        return 0
    fi

    # Check short block threshold
    compare_result=$(echo "$score >= $threshold_short" | bc -l 2>/dev/null || echo 0)
    if [[ "$compare_result" == "1" ]]; then
        nftban_portscan_suricata_block_ip "$ip" "short" "$score"
        return 0
    fi

    # Check observe threshold
    compare_result=$(echo "$score >= $threshold_observe" | bc -l 2>/dev/null || echo 0)
    if [[ "$compare_result" == "1" ]]; then
        if [[ "${PORTSCAN_SURICATA_LOG_SCORES:-true}" == "true" ]]; then
            _nftban_portscan_suricata_log "INFO" "Observing ${ip} score=${score}"
        fi
    fi

    return 0
}

# =============================================================================
# BLOCKING
# =============================================================================

# Block an IP based on threshold level
nftban_portscan_suricata_block_ip() {
    local ip="$1"
    local level="$2"
    local score="$3"

    # Determine duration
    local duration
    case "$level" in
        short)     duration="${PORTSCAN_SURICATA_BAN_DURATION_SHORT}" ;;
        long)      duration="${PORTSCAN_SURICATA_BAN_DURATION_LONG}" ;;
        permanent) duration="${PORTSCAN_SURICATA_BAN_DURATION_PERMANENT}" ;;
        *)         duration="${PORTSCAN_SURICATA_BAN_DURATION_SHORT}" ;;
    esac

    local scan_types="${_PORTSCAN_SURICATA_IP_SCAN_TYPES[$ip]:-unknown}"

    # Use nftban ban command if available
    if type -t nftban_ban &>/dev/null; then
        nftban_ban "$ip" \
            --timeout "$duration" \
            --reason "portscan:suricata:${level}:${scan_types}" \
            --source "portscan-suricata" \
            --score "$score"
    elif type -t nft_ipc_ban &>/dev/null; then
        # Use IPC to ban (single-writer architecture)
        local ipc_result
        if ! ipc_result=$(nft_ipc_ban "$ip" "$duration" "portscan:suricata:${level}:${scan_types}" "portscan-suricata" 2>&1); then
            _nftban_portscan_suricata_log "ERROR" "IPC ban failed for $ip: $ipc_result"
        fi
    else
        # Fallback: Direct IPC add element
        local table_ipv4="${PORTSCAN_NFT_TABLE_IPV4:-ip nftban}"
        local table_ipv6="${PORTSCAN_NFT_TABLE_IPV6:-ip6 nftban}"

        if [[ "$ip" =~ : ]]; then
            if ! nft_ipc_add_element "$table_ipv6" "blacklist" "$ip" "$duration"; then
                _nftban_portscan_suricata_log "WARN" "IPC ban failed for $ip"
            fi
        else
            if ! nft_ipc_add_element "$table_ipv4" "blacklist" "$ip" "$duration"; then
                _nftban_portscan_suricata_log "WARN" "IPC ban failed for $ip"
            fi
        fi
    fi

    # Record block - Use library function if available, fallback to date
    if type -t nftban_timestamp_unix &>/dev/null; then
        _PORTSCAN_SURICATA_IP_BLOCKED["$ip"]=$(nftban_timestamp_unix)
    else
        _PORTSCAN_SURICATA_IP_BLOCKED["$ip"]=$(date +%s)
    fi

    _nftban_portscan_suricata_log "WARN" "Blocked ${ip} for ${duration}s (${level}, score=${score}, types=${scan_types})"

    # Send notification
    nftban_portscan_suricata_send_alert "$ip" "$level" "$score"

    return 0
}

# Send alert notification
nftban_portscan_suricata_send_alert() {
    local ip="$1"
    local level="$2"
    local score="$3"

    local threshold="${PORTSCAN_NOTIFY_THRESHOLD:-10}"
    local alert_count="${_PORTSCAN_SURICATA_IP_ALERTS[$ip]:-0}"

    # Only alert if above threshold
    [[ $alert_count -lt $threshold ]] && return 0

    local scan_types="${_PORTSCAN_SURICATA_IP_SCAN_TYPES[$ip]:-unknown}"
    local message="Portscan detected by Suricata: ${ip} (${level} block, score=${score}, alerts=${alert_count}, types=${scan_types})"

    # Email notification via NFTBan unified mail mechanism
    # Per-module override: PORTSCAN_NOTIFY_EMAIL_TO, fallback: NFTBAN_MAIL_RECIPIENT
    if [[ "${PORTSCAN_NOTIFY_EMAIL:-false}" == "true" ]]; then
        local recipient="${PORTSCAN_NOTIFY_EMAIL_TO:-${NFTBAN_MAIL_RECIPIENT:-}}"
        if [[ -n "$recipient" ]]; then
            nftban_mail_send "$message" "$recipient" 2>/dev/null || true
        fi
    fi

    # Webhook notification
    if [[ "${PORTSCAN_NOTIFY_WEBHOOK:-false}" == "true" && -n "${PORTSCAN_NOTIFY_WEBHOOK_URL:-}" ]]; then
        curl -s -X POST "${PORTSCAN_NOTIFY_WEBHOOK_URL}" \
            -H "Content-Type: application/json" \
            -d "{\"type\":\"portscan\",\"mode\":\"suricata\",\"ip\":\"${ip}\",\"level\":\"${level}\",\"score\":${score},\"alerts\":${alert_count}}" \
            2>/dev/null || true
    fi

    return 0
}

# =============================================================================
# WHITELIST
# =============================================================================

# Check if IP is whitelisted
nftban_portscan_suricata_is_whitelisted() {
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
            fc*|fd*) return 0 ;;
        esac
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
# CLEANUP
# =============================================================================

# Cleanup stale tracking entries
nftban_portscan_suricata_cleanup() {
    local current_time
    # Use library function if available, fallback to date
    if type -t nftban_timestamp_unix &>/dev/null; then
        current_time=$(nftban_timestamp_unix)
    else
        current_time=$(date +%s)
    fi
    local alert_window="${PORTSCAN_SURICATA_ALERT_WINDOW}"
    local max_tracked="${PORTSCAN_SURICATA_MAX_TRACKED_IPS}"

    # Remove entries older than alert window
    for ip in "${!_PORTSCAN_SURICATA_IP_LAST_SEEN[@]}"; do
        local last_seen="${_PORTSCAN_SURICATA_IP_LAST_SEEN[$ip]}"
        local age
        age=$((current_time - last_seen))

        if [[ $age -gt $alert_window ]]; then
            # Check if blocked, keep those for longer
            if [[ -z "${_PORTSCAN_SURICATA_IP_BLOCKED[$ip]:-}" ]]; then
                unset "_PORTSCAN_SURICATA_IP_SCORES[$ip]"
                unset "_PORTSCAN_SURICATA_IP_ALERTS[$ip]"
                unset "_PORTSCAN_SURICATA_IP_FIRST_SEEN[$ip]"
                unset "_PORTSCAN_SURICATA_IP_LAST_SEEN[$ip]"
                unset "_PORTSCAN_SURICATA_IP_SCAN_TYPES[$ip]"
            fi
        fi
    done

    # If still over limit, remove oldest entries
    if [[ ${#_PORTSCAN_SURICATA_IP_SCORES[@]} -gt $max_tracked ]]; then
        local count_to_remove
        count_to_remove=$((${#_PORTSCAN_SURICATA_IP_SCORES[@]} - max_tracked))
        local removed=0

        for ip in "${!_PORTSCAN_SURICATA_IP_LAST_SEEN[@]}"; do
            [[ $removed -ge $count_to_remove ]] && break
            [[ -n "${_PORTSCAN_SURICATA_IP_BLOCKED[$ip]:-}" ]] && continue

            unset "_PORTSCAN_SURICATA_IP_SCORES[$ip]"
            unset "_PORTSCAN_SURICATA_IP_ALERTS[$ip]"
            unset "_PORTSCAN_SURICATA_IP_FIRST_SEEN[$ip]"
            unset "_PORTSCAN_SURICATA_IP_LAST_SEEN[$ip]"
            unset "_PORTSCAN_SURICATA_IP_SCAN_TYPES[$ip]"

            # v1.19.20 FIX
            ((removed++)) || true
        done
    fi

    return 0
}

# =============================================================================
# MODULE LIFECYCLE
# =============================================================================

# Enable suricata portscan detection
nftban_portscan_suricata_enable() {
    _nftban_portscan_suricata_log "INFO" "Enabling Suricata portscan detection"

    # Check if Suricata is available
    if ! nftban_portscan_suricata_is_available; then
        _nftban_portscan_suricata_log "ERROR" "Suricata is not available"
        return 1
    fi

    # Load configuration
    nftban_portscan_suricata_load_config

    # Initialize state
    nftban_portscan_suricata_init_state

    _nftban_portscan_suricata_log "INFO" "Suricata portscan detection enabled"
    return 0
}

# Disable suricata portscan detection
nftban_portscan_suricata_disable() {
    _nftban_portscan_suricata_log "INFO" "Disabling Suricata portscan detection"

    # Save state
    nftban_portscan_suricata_save_state

    _nftban_portscan_suricata_log "INFO" "Suricata portscan detection disabled"
    return 0
}

# Process pending alerts (called periodically)
nftban_portscan_suricata_run() {
    # Read and process EVE alerts
    nftban_portscan_suricata_read_eve

    # Cleanup old entries
    nftban_portscan_suricata_cleanup

    return 0
}

# =============================================================================
# END OF SURICATA MODE IMPLEMENTATION
# =============================================================================
