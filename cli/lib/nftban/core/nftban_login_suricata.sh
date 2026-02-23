#!/usr/bin/env bash
# shellcheck disable=SC1090  # Dynamic config paths, cannot follow
# =============================================================================
# NFTBan v1.0 - Login Monitor Suricata Mode Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Suricata EVE JSON based login/auth failure monitoring
#
# meta:name="nftban_login_suricata"
# meta:type="core"
# meta:header="Login Monitor Suricata Mode"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Suricata mode login monitoring using EVE JSON auth alerts"
# meta:input="Suricata EVE JSON log file"
# meta:output="Auth failure detection and ban actions"
# meta:depends="bash,jq,nftban_login.sh,suricata"
# meta:created_date="2025-12-01"
# meta:updated_date="2026-02-04"
#
# meta:inventory.files=""
# meta:inventory.binaries="jq,suricata"
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/conf.d/login/main.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# =============================================================================
# MODULE GUARD
# =============================================================================

[[ -n "${NFTBAN_LOGIN_SURICATA_LOADED:-}" ]] && return 0
readonly NFTBAN_LOGIN_SURICATA_LOADED=1

# =============================================================================
# LOAD SHARED LIBRARIES
# =============================================================================

: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/nftban_timestamp.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/nftban_file_utils.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/nftban_service_control.sh" 2>/dev/null || true

# =============================================================================
# MODULE METADATA
# =============================================================================

# shellcheck disable=SC2034  # Module metadata used when sourced
readonly LOGIN_SURICATA_MODULE_NAME="nftban_login_suricata"
# shellcheck disable=SC2034  # Module metadata used when sourced
readonly LOGIN_SURICATA_MODULE_VERSION="1.0.0"

# =============================================================================
# STATE TRACKING
# =============================================================================

# Alert counts per IP (IP -> count)
declare -gA _LOGIN_SURICATA_ALERT_COUNT=()
# First alert timestamp per IP (IP -> timestamp)
declare -gA _LOGIN_SURICATA_ALERT_FIRST=()
# Accumulated score per IP (IP -> score)
declare -gA _LOGIN_SURICATA_SCORES=()
# Running flag
declare -g _LOGIN_SURICATA_RUNNING=0
# Monitor PID
declare -g _LOGIN_SURICATA_MONITOR_PID=""
# Last processed position
declare -g _LOGIN_SURICATA_LAST_POS=0

# =============================================================================
# INITIALIZATION
# =============================================================================

nftban_login_suricata_init() {
    nftban_login_log "INFO" "Initializing Suricata mode..."

    # Check jq availability
    if ! command -v jq &>/dev/null; then
        nftban_login_log "ERROR" "jq is required for Suricata mode but not installed"
        return 1
    fi

    # Load state from disk if exists (safe line-by-line parsing, no source)
    local state_file="${LOGIN_SURICATA_STATE_FILE:-/var/lib/nftban/login-suricata-state.db}"
    if [[ -f "$state_file" ]]; then
        while IFS='=' read -r key value; do
            # Skip comments and blank lines
            [[ -z "$key" || "$key" =~ ^# ]] && continue
            # Only allow known variable patterns with safe values
            [[ "$key" =~ ^_LOGIN_SURICATA_(ALERT_COUNT|ALERT_FIRST|SCORES)(\[[^]]+\])?$ ]] || continue
            [[ "$value" =~ ^[0-9a-zA-Z.,_:\ -]+$ ]] || continue
            declare "$key=$value" 2>/dev/null || true
        done < "$state_file"
    fi

    # Set defaults
    : "${LOGIN_SURICATA_EVE_FILE:=${NFTBAN_LOG_DIR:-/var/log/nftban}/suricata/eve-alerts.json}"
    : "${LOGIN_SURICATA_SIG_PATTERNS:=[Aa]uth|[Ll]ogin|[Pp]assword|[Cc]redential|[Bb]rute|SSH|FTP|SMTP|POP3|IMAP}"
    : "${LOGIN_SURICATA_ALERT_WINDOW:=300}"
    # Severity scoring (1=High, 2=Medium, 3=Low, 4=Info - matches Go)
    : "${LOGIN_SURICATA_SCORE_SEVERITY_1:=0.50}"
    : "${LOGIN_SURICATA_SCORE_SEVERITY_2:=0.35}"
    : "${LOGIN_SURICATA_SCORE_SEVERITY_3:=0.20}"
    : "${LOGIN_SURICATA_SCORE_SEVERITY_4:=0.10}"
    : "${LOGIN_SURICATA_SCORE_BRUTE_FORCE:=0.25}"
    : "${LOGIN_SURICATA_THRESHOLD_BLOCK_SHORT:=0.45}"
    : "${LOGIN_SURICATA_THRESHOLD_BLOCK_LONG:=0.65}"
    : "${LOGIN_SURICATA_BAN_DURATION_SHORT:=900}"
    : "${LOGIN_SURICATA_BAN_DURATION_LONG:=3600}"
    : "${LOGIN_SURICATA_POLL_INTERVAL_MS:=500}"

    return 0
}

# =============================================================================
# EVE JSON PARSING
# =============================================================================

# Monitor EVE JSON file for auth-related alerts
_nftban_login_suricata_monitor_eve() {
    local eve_file="${LOGIN_SURICATA_EVE_FILE:-/var/log/nftban/suricata/eve-alerts.json}"
    local poll_ms="${LOGIN_SURICATA_POLL_INTERVAL_MS:-500}"
    local poll_sec
    poll_sec=$(echo "scale=3; $poll_ms / 1000" | bc)

    nftban_login_log "INFO" "Starting EVE JSON monitor: $eve_file"

    if [[ ! -f "$eve_file" ]]; then
        nftban_login_log "ERROR" "EVE file not found: $eve_file"
        return 1
    fi

    # Start tailing from current position
    tail -F -n 0 "$eve_file" 2>/dev/null | while read -r line; do
        [[ -z "$line" ]] && continue

        # Parse JSON and check if relevant
        _nftban_login_suricata_process_eve_line "$line"

        # Small sleep to prevent CPU spinning
        sleep "$poll_sec"
    done
}

# Process a single EVE JSON line
_nftban_login_suricata_process_eve_line() {
    local line="$1"

    # Parse JSON
    local event_type src_ip signature signature_id severity

    event_type=$(echo "$line" | jq -r '.event_type // empty' 2>/dev/null) || return 0
    [[ -z "$event_type" ]] && return 0

    # Get source IP
    src_ip=$(echo "$line" | jq -r '.src_ip // empty' 2>/dev/null)
    [[ -z "$src_ip" ]] && return 0

    # Skip whitelisted
    if _nftban_login_suricata_is_whitelisted "$src_ip"; then
        return 0
    fi

    # shellcheck disable=SC2034  # Reserved for event tracking
    local processed=0

    # Handle alert events
    if [[ "$event_type" == "alert" ]]; then
        signature=$(echo "$line" | jq -r '.alert.signature // empty' 2>/dev/null)
        signature_id=$(echo "$line" | jq -r '.alert.signature_id // empty' 2>/dev/null)
        severity=$(echo "$line" | jq -r '.alert.severity // 2' 2>/dev/null)

        # Check if auth-related
        local patterns="${LOGIN_SURICATA_SIG_PATTERNS}"
        if [[ "$signature" =~ $patterns ]]; then
            _nftban_login_suricata_process_alert "$src_ip" "$signature" "$signature_id" "$severity"
            processed=1
        fi
    fi

    # Handle SSH events (Suricata SSH protocol logging)
    if [[ "$event_type" == "ssh" ]]; then
        # shellcheck disable=SC2034  # Reserved for protocol analysis
        local client_proto client_software
        # shellcheck disable=SC2034  # Reserved for protocol analysis
        client_proto=$(echo "$line" | jq -r '.ssh.client.proto_version // empty' 2>/dev/null)
        client_software=$(echo "$line" | jq -r '.ssh.client.software_version // empty' 2>/dev/null)

        # Check for scanner patterns
        local scanner_patterns="${LOGIN_SURICATA_SSH_SCANNER_PATTERNS:-[Nn]map|[Ss]can|[Aa]udit|[Bb]rute}"
        if [[ "$client_software" =~ $scanner_patterns ]]; then
            _nftban_login_suricata_process_ssh_scanner "$src_ip" "$client_software"
            processed=1
        fi
    fi

    # Handle anomaly events
    if [[ "$event_type" == "anomaly" ]]; then
        local anomaly_type
        anomaly_type=$(echo "$line" | jq -r '.anomaly.type // empty' 2>/dev/null)

        # Auth-related anomalies
        if [[ "$anomaly_type" == "auth" ]] || [[ "$anomaly_type" == "applayer" ]]; then
            _nftban_login_suricata_process_anomaly "$src_ip" "$anomaly_type"
            # shellcheck disable=SC2034  # Marker variable for event processing
            processed=1
        fi
    fi

    return 0
}

# Process an auth-related alert
_nftban_login_suricata_process_alert() {
    local ip="$1"
    local signature="$2"
    # shellcheck disable=SC2034  # Reserved for SID filtering
    local sig_id="$3"
    local severity="${4:-2}"
    local now
    # Use library function if available, fallback to date
    if type -t nftban_timestamp_unix &>/dev/null; then
        now=$(nftban_timestamp_unix)
    else
        now=$(date +%s)
    fi

    local window="${LOGIN_SURICATA_ALERT_WINDOW:-300}"

    # Track alert count
    if [[ -z "${_LOGIN_SURICATA_ALERT_FIRST[$ip]:-}" ]]; then
        _LOGIN_SURICATA_ALERT_COUNT[$ip]=1
        _LOGIN_SURICATA_ALERT_FIRST[$ip]=$now
        _LOGIN_SURICATA_SCORES[$ip]="0"
    else
        local first="${_LOGIN_SURICATA_ALERT_FIRST[$ip]}"
        local elapsed
        elapsed=$((now - first))

        if [[ $elapsed -lt $window ]]; then
            ((_LOGIN_SURICATA_ALERT_COUNT[$ip]++))
        else
            _LOGIN_SURICATA_ALERT_COUNT[$ip]=1
            _LOGIN_SURICATA_ALERT_FIRST[$ip]=$now
            _LOGIN_SURICATA_SCORES[$ip]="0"
        fi
    fi

    local count="${_LOGIN_SURICATA_ALERT_COUNT[$ip]}"

    # Calculate score
    local score
    score=$(_nftban_login_suricata_calculate_score "$ip" "$signature" "$severity" "$count")
    _LOGIN_SURICATA_SCORES[$ip]="$score"

    nftban_login_log "DEBUG" "Alert: $ip - sig: $signature (severity: $severity, count: $count, score: $score)"

    # Check thresholds
    _nftban_login_suricata_check_threshold "$ip" "$score" "alert"
}

# Process SSH scanner detection
_nftban_login_suricata_process_ssh_scanner() {
    local ip="$1"
    local client_software="$2"
    local now
    # Use library function if available, fallback to date
    if type -t nftban_timestamp_unix &>/dev/null; then
        now=$(nftban_timestamp_unix)
    else
        now=$(date +%s)
    fi

    nftban_login_log "INFO" "SSH scanner detected from $ip: $client_software"

    # Initialize tracking
    if [[ -z "${_LOGIN_SURICATA_SCORES[$ip]:-}" ]]; then
        _LOGIN_SURICATA_ALERT_COUNT[$ip]=1
        _LOGIN_SURICATA_ALERT_FIRST[$ip]=$now
        _LOGIN_SURICATA_SCORES[$ip]="0"
    fi

    # Add scanner penalty
    local current_score="${_LOGIN_SURICATA_SCORES[$ip]:-0}"
    local tool_score="${LOGIN_SURICATA_SCORE_KNOWN_TOOL:-0.20}"
    local new_score
    new_score=$(echo "$current_score + $tool_score" | bc -l)
    _LOGIN_SURICATA_SCORES[$ip]="$new_score"

    _nftban_login_suricata_check_threshold "$ip" "$new_score" "ssh_scanner"
}

# Process anomaly event
_nftban_login_suricata_process_anomaly() {
    local ip="$1"
    local anomaly_type="$2"
    local now
    # Use library function if available, fallback to date
    if type -t nftban_timestamp_unix &>/dev/null; then
        now=$(nftban_timestamp_unix)
    else
        now=$(date +%s)
    fi

    # Initialize tracking
    if [[ -z "${_LOGIN_SURICATA_SCORES[$ip]:-}" ]]; then
        _LOGIN_SURICATA_ALERT_COUNT[$ip]=1
        _LOGIN_SURICATA_ALERT_FIRST[$ip]=$now
        _LOGIN_SURICATA_SCORES[$ip]="0"
    fi

    # Add anomaly penalty (lower than alerts)
    local current_score="${_LOGIN_SURICATA_SCORES[$ip]:-0}"
    local anomaly_score="0.10"
    local new_score
    new_score=$(echo "$current_score + $anomaly_score" | bc -l)
    _LOGIN_SURICATA_SCORES[$ip]="$new_score"

    ((_LOGIN_SURICATA_ALERT_COUNT[$ip]++))

    nftban_login_log "DEBUG" "Anomaly: $ip - type: $anomaly_type (score: $new_score)"

    _nftban_login_suricata_check_threshold "$ip" "$new_score" "anomaly"
}

# Calculate score for an alert
_nftban_login_suricata_calculate_score() {
    local ip="$1"
    local signature="$2"
    local severity="$3"
    local count="$4"

    local current_score="${_LOGIN_SURICATA_SCORES[$ip]:-0}"
    local additional=0

    # Severity-based score (1=High, 2=Medium, 3=Low, 4=Info - matches Go)
    case "$severity" in
        1) additional=$(echo "$additional + ${LOGIN_SURICATA_SCORE_SEVERITY_1:-0.50}" | bc -l) ;;
        2) additional=$(echo "$additional + ${LOGIN_SURICATA_SCORE_SEVERITY_2:-0.35}" | bc -l) ;;
        3) additional=$(echo "$additional + ${LOGIN_SURICATA_SCORE_SEVERITY_3:-0.20}" | bc -l) ;;
        4) additional=$(echo "$additional + ${LOGIN_SURICATA_SCORE_SEVERITY_4:-0.10}" | bc -l) ;;
    esac

    # Brute force signature bonus
    if [[ "$signature" =~ [Bb]rute ]]; then
        additional=$(echo "$additional + ${LOGIN_SURICATA_SCORE_BRUTE_FORCE:-0.25}" | bc -l)
    fi

    # Credential stuffing/dictionary bonus
    if [[ "$signature" =~ [Cc]redential|[Dd]ictionary ]]; then
        additional=$(echo "$additional + ${LOGIN_SURICATA_SCORE_CREDENTIAL_STUFFING:-0.30}" | bc -l)
    fi

    # Repetition bonuses
    if [[ $count -ge 10 ]]; then
        additional=$(echo "$additional + ${LOGIN_SURICATA_SCORE_REPEAT_10:-0.25}" | bc -l)
    elif [[ $count -ge 5 ]]; then
        additional=$(echo "$additional + ${LOGIN_SURICATA_SCORE_REPEAT_5:-0.15}" | bc -l)
    elif [[ $count -ge 3 ]]; then
        additional=$(echo "$additional + ${LOGIN_SURICATA_SCORE_REPEAT_3:-0.10}" | bc -l)
    fi

    local new_score
    new_score=$(echo "$current_score + $additional" | bc -l)

    # Cap at 1.0
    if (( $(echo "$new_score > 1.0" | bc -l) )); then
        new_score="1.0"
    fi

    echo "$new_score"
}

# Check threshold and take action
_nftban_login_suricata_check_threshold() {
    local ip="$1"
    local score="$2"
    local source="$3"

    if (( $(echo "$score >= ${LOGIN_SURICATA_THRESHOLD_BLOCK_LONG:-0.65}" | bc -l) )); then
        # Long ban
        local duration="${LOGIN_SURICATA_BAN_DURATION_LONG:-3600}"
        nftban_login_log "INFO" "Banning $ip (long) - score: $score, source: $source"
        nftban_login_ban "$ip" "suricata_${source}" "$duration" "suricata"
        _nftban_login_suricata_clear_ip "$ip"
    elif (( $(echo "$score >= ${LOGIN_SURICATA_THRESHOLD_BLOCK_SHORT:-0.45}" | bc -l) )); then
        # Short ban
        local duration="${LOGIN_SURICATA_BAN_DURATION_SHORT:-900}"
        nftban_login_log "INFO" "Banning $ip (short) - score: $score, source: $source"
        nftban_login_ban "$ip" "suricata_${source}" "$duration" "suricata"
        _nftban_login_suricata_clear_ip "$ip"
    fi
}

# Check if IP is whitelisted
_nftban_login_suricata_is_whitelisted() {
    local ip="$1"

    # Localhost
    if [[ "${LOGIN_WHITELIST_LOCALHOST:-true}" == "true" ]]; then
        [[ "$ip" == "127.0.0.1" ]] && return 0
        [[ "$ip" == "::1" ]] && return 0
    fi

    # Private networks
    if [[ "${LOGIN_WHITELIST_PRIVATE:-true}" == "true" ]]; then
        [[ "$ip" =~ ^10\. ]] && return 0
        [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
        [[ "$ip" =~ ^192\.168\. ]] && return 0
    fi

    # Central whitelist check (SINGLE SOURCE OF TRUTH)
    # Uses nft_schema.sh nftban_is_whitelisted() which checks:
    # 1. nftables whitelist sets (whitelist_ipv4/whitelist_ipv6)
    # 2. /etc/nftban/whitelist.d/*.conf files
    if declare -f nftban_is_whitelisted &>/dev/null; then
        nftban_is_whitelisted "$ip" && return 0
    fi

    return 1
}

# Clear tracking for an IP
_nftban_login_suricata_clear_ip() {
    local ip="$1"
    unset "_LOGIN_SURICATA_ALERT_COUNT[$ip]"
    unset "_LOGIN_SURICATA_ALERT_FIRST[$ip]"
    unset "_LOGIN_SURICATA_SCORES[$ip]"
}

# =============================================================================
# MAIN OPERATIONS
# =============================================================================

# Start Suricata mode monitoring
nftban_login_suricata_start() {
    if [[ $_LOGIN_SURICATA_RUNNING -eq 1 ]]; then
        nftban_login_log "WARN" "Suricata mode already running"
        return 0
    fi

    _LOGIN_SURICATA_RUNNING=1
    nftban_login_log "INFO" "Starting Suricata mode monitoring"

    _nftban_login_suricata_monitor_eve &
    _LOGIN_SURICATA_MONITOR_PID=$!

    wait $_LOGIN_SURICATA_MONITOR_PID
}

# Stop Suricata mode monitoring
nftban_login_suricata_stop() {
    _LOGIN_SURICATA_RUNNING=0

    if [[ -n "$_LOGIN_SURICATA_MONITOR_PID" ]] && kill -0 "$_LOGIN_SURICATA_MONITOR_PID" 2>/dev/null; then
        kill "$_LOGIN_SURICATA_MONITOR_PID" 2>/dev/null
        nftban_login_log "INFO" "Stopped EVE monitor (PID: $_LOGIN_SURICATA_MONITOR_PID)"
    fi
    _LOGIN_SURICATA_MONITOR_PID=""

    # Save state
    _nftban_login_suricata_save_state
}

# Save state to disk
_nftban_login_suricata_save_state() {
    local state_file="${LOGIN_SURICATA_STATE_FILE:-/var/lib/nftban/login-suricata-state.db}"
    mkdir -p "$(dirname "$state_file")"

    # Use library timestamp if available
    local state_timestamp
    if type -t nftban_timestamp &>/dev/null; then
        state_timestamp=$(nftban_timestamp)
    else
        state_timestamp=$(date)
    fi

    {
        echo "# Login Suricata State - ${state_timestamp}"
        for key in "${!_LOGIN_SURICATA_ALERT_COUNT[@]}"; do
            echo "_LOGIN_SURICATA_ALERT_COUNT[$key]=${_LOGIN_SURICATA_ALERT_COUNT[$key]}"
        done
        for key in "${!_LOGIN_SURICATA_ALERT_FIRST[@]}"; do
            echo "_LOGIN_SURICATA_ALERT_FIRST[$key]=${_LOGIN_SURICATA_ALERT_FIRST[$key]}"
        done
        for key in "${!_LOGIN_SURICATA_SCORES[@]}"; do
            echo "_LOGIN_SURICATA_SCORES[$key]=${_LOGIN_SURICATA_SCORES[$key]}"
        done
    } > "$state_file"
}

# Get status
nftban_login_suricata_status() {
    echo "Suricata Mode Status:"
    echo "  Running: $_LOGIN_SURICATA_RUNNING"
    echo "  EVE File: ${LOGIN_SURICATA_EVE_FILE:-/var/log/nftban/suricata/eve-alerts.json}"

    local eve_exists="no"
    [[ -f "${LOGIN_SURICATA_EVE_FILE:-/var/log/nftban/suricata/eve-alerts.json}" ]] && eve_exists="yes"
    echo "  EVE Exists: $eve_exists"

    if [[ -n "$_LOGIN_SURICATA_MONITOR_PID" ]]; then
        local status="stopped"
        kill -0 "$_LOGIN_SURICATA_MONITOR_PID" 2>/dev/null && status="running (PID: $_LOGIN_SURICATA_MONITOR_PID)"
        echo "  Monitor: $status"
    fi

    echo "  Tracked IPs: ${#_LOGIN_SURICATA_ALERT_COUNT[@]}"

    if [[ ${#_LOGIN_SURICATA_SCORES[@]} -gt 0 ]]; then
        echo "  Current Scores:"
        for ip in "${!_LOGIN_SURICATA_SCORES[@]}"; do
            echo "    $ip: ${_LOGIN_SURICATA_SCORES[$ip]}"
        done
    fi
}

# Enable Suricata mode
nftban_login_suricata_enable() {
    nftban_login_log "INFO" "Enabling Suricata mode"
    return 0
}

# Disable Suricata mode
nftban_login_suricata_disable() {
    nftban_login_suricata_stop
    return 0
}

# Test Suricata mode
nftban_login_suricata_test() {
    echo "Suricata Mode Test:"
    echo "  jq available: $(command -v jq &>/dev/null && echo "yes" || echo "no")"

    local eve_file="${LOGIN_SURICATA_EVE_FILE:-/var/log/nftban/suricata/eve-alerts.json}"
    echo "  EVE file: $eve_file"
    echo "  EVE exists: $([[ -f "$eve_file" ]] && echo "yes" || echo "no")"

    if [[ -f "$eve_file" ]]; then
        local last_line
        last_line=$(tail -1 "$eve_file" 2>/dev/null)
        if [[ -n "$last_line" ]]; then
            echo "  Last event type: $(echo "$last_line" | jq -r '.event_type // "unknown"' 2>/dev/null)"
            echo "  EVE is being updated: yes"
        fi
    fi

    # Test JSON parsing
    local test_json='{"event_type":"alert","src_ip":"192.168.1.100","alert":{"signature":"ET SCAN SSH Brute Force","severity":2}}'
    echo "  Testing JSON parsing..."
    local parsed_type
    parsed_type=$(echo "$test_json" | jq -r '.event_type' 2>/dev/null)
    if [[ "$parsed_type" == "alert" ]]; then
        echo "    JSON parsing: OK"
    else
        echo "    JSON parsing: FAILED"
    fi
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_login_suricata_init
export -f nftban_login_suricata_start
export -f nftban_login_suricata_stop
export -f nftban_login_suricata_status
export -f nftban_login_suricata_enable
export -f nftban_login_suricata_disable
export -f nftban_login_suricata_test
