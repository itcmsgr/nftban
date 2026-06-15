#!/usr/bin/env bash
# shellcheck disable=SC1083  # Braces in nftables syntax are literal, not bash
# =============================================================================
# NFTBan - DDoS Protection Module - SURICATA MODE
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Suricata IDS-integrated DDoS protection with scoring engine
#
# meta:name="nftban_ddos_suricata"
# meta:type="core"
# meta:header="DDoS Protection (Suricata)"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# **Description**
# Suricata-based DDoS protection using IDS alerts:
# - EVE JSON parsing for real-time alerts
# - Signature-based detection (DDoS categories)
# - Scoring engine with multi-signal correlation
# - Integration with feeds, GeoIP for enrichment
#
# **When to use Suricata Mode:**
# - Suricata IDS is installed and running
# - Deep packet inspection required
# - Protocol-aware detection needed
# - AI-ready scoring pipeline
#
# meta:description="Suricata IDS-integrated DDoS protection with scoring engine"
# meta:depends="bash>=4.0,nftables>=0.9.0,suricata,jq"
# meta:inventory.files=""
# meta:inventory.binaries="suricata,jq,nft"
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/conf.d/ddos/suricata.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
# meta:created_date="2025-12-01"
# meta:updated_date="2026-02-05"
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# MODULE GUARD
# =============================================================================

[[ -n "${NFTBAN_DDOS_SURICATA_LOADED:-}" ]] && return 0
readonly NFTBAN_DDOS_SURICATA_LOADED=1

# =============================================================================
# LOAD IPC/FRAGMENT AND SHARED LIBRARIES
# =============================================================================

: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/nft_ipc.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/nft_fragment.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/nftban_timestamp.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/nftban_file_utils.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/nftban_service_control.sh" 2>/dev/null || true

# =============================================================================
# CONFIGURATION LOADING
# =============================================================================

_nftban_ddos_suricata_load_config() {
    local config_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/ddos/suricata.conf"

    if [[ -f "$config_file" ]]; then
        # shellcheck source=/dev/null
        source "$config_file" || true
    fi

    # Set defaults if not configured
    : "${DDOS_SURICATA_EVE_FILE:=${NFTBAN_LOG_DIR:-/var/log/nftban}/suricata/eve-alerts.json}"
    : "${DDOS_SURICATA_EVE_SOCKET:=}"
    : "${DDOS_SURICATA_SIG_PATTERNS:=DDoS|flood|amplification|reflection|slowloris}"
    : "${DDOS_SURICATA_CATEGORIES:=attempted-dos,successful-dos,denial-of-service}"

    # Scoring defaults (Severity: 1=High, 2=Medium, 3=Low, 4=Info - matches Go)
    : "${DDOS_SURICATA_SCORE_SEVERITY_1:=0.50}"
    : "${DDOS_SURICATA_SCORE_SEVERITY_2:=0.35}"
    : "${DDOS_SURICATA_SCORE_SEVERITY_3:=0.20}"
    : "${DDOS_SURICATA_SCORE_SEVERITY_4:=0.10}"
    : "${DDOS_SURICATA_SCORE_REPEAT_5:=0.10}"
    : "${DDOS_SURICATA_SCORE_REPEAT_10:=0.20}"
    : "${DDOS_SURICATA_SCORE_REPEAT_20:=0.30}"
    : "${DDOS_SURICATA_SCORE_BAD_REPUTATION:=0.15}"
    : "${DDOS_SURICATA_SCORE_HIGH_RISK_GEO:=0.10}"

    # Action thresholds
    : "${DDOS_SURICATA_THRESHOLD_OBSERVE:=0.30}"
    : "${DDOS_SURICATA_THRESHOLD_BLOCK_SHORT:=0.50}"
    : "${DDOS_SURICATA_THRESHOLD_BLOCK_LONG:=0.70}"
    : "${DDOS_SURICATA_THRESHOLD_BLOCK_PERMANENT:=0.90}"

    # Ban durations
    : "${DDOS_SURICATA_BAN_DURATION_SHORT:=600}"
    : "${DDOS_SURICATA_BAN_DURATION_LONG:=3600}"
    : "${DDOS_SURICATA_BAN_DURATION_PERMANENT:=86400}"
    : "${DDOS_SURICATA_SCORE_DECAY:=3600}"
    : "${DDOS_SURICATA_ALERT_WINDOW:=120}"

    # Integration
    : "${DDOS_SURICATA_USE_FEEDS:=true}"
    : "${DDOS_SURICATA_USE_GEOIP:=true}"
    : "${DDOS_SURICATA_USE_CLASSIC_LAYER0:=true}"

    # Performance
    : "${DDOS_SURICATA_BATCH_SIZE:=100}"
    : "${DDOS_SURICATA_POLL_INTERVAL_MS:=500}"

    # Logging
    : "${DDOS_SURICATA_LOG_FILE:=${NFTBAN_LOG_DIR:-/var/log/nftban}/ddos-suricata.log}"
    : "${DDOS_SURICATA_LOG_LEVEL:=INFO}"
    : "${DDOS_SURICATA_LOG_SCORES:=true}"
}

# =============================================================================
# LOGGING
# =============================================================================

_nftban_ddos_suricata_log() {
    local level="$1"
    local message="$2"
    local log_file="${DDOS_SURICATA_LOG_FILE:-${NFTBAN_LOG_DIR:-/var/log/nftban}/ddos-suricata.log}"

    mkdir -p "$(dirname "$log_file")" 2>/dev/null || return 1

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [SURICATA] [$level] $message" >> "$log_file"
}

# =============================================================================
# SURICATA DETECTION (Is Suricata Available?)
# =============================================================================

# Check if Suricata binary exists
nftban_ddos_suricata_binary_exists() {
    local binary="${DDOS_SURICATA_BINARY:-/usr/bin/suricata}"
    [[ -x "$binary" ]] || command -v suricata &>/dev/null
}

# Check if Suricata service is running
nftban_ddos_suricata_service_running() {
    local service="${DDOS_SURICATA_SERVICE_NAME:-suricata}"

    # Try systemctl first
    if command -v systemctl &>/dev/null; then
        systemctl is-active --quiet "$service" 2>/dev/null && return 0
    fi

    # Try service command
    if command -v service &>/dev/null; then
        service "$service" status &>/dev/null && return 0
    fi

    # Check for running process (use configurable service name)
    pgrep -x "${service}" &>/dev/null && return 0
    pgrep -f "${service}.*-c" &>/dev/null && return 0

    return 1
}

# Check if EVE JSON file exists and is fresh
nftban_ddos_suricata_eve_active() {
    local eve_file="${DDOS_SURICATA_EVE_FILE:-/var/log/nftban/suricata/eve-alerts.json}"
    local threshold="${DDOS_EVE_FRESHNESS_THRESHOLD:-60}"

    # Support Suricata 7.x threaded logging (writes to eve-alerts.1.json, eve-alerts.2.json, etc.)
    local eve_dir="${eve_file%/*}"
    local freshest_mtime=0

    shopt -s nullglob
    for f in "$eve_dir"/eve-alerts*.json; do
        [[ -f "$f" ]] || continue
        local m
        m=$(stat -L -c %Y -- "$f" 2>/dev/null) || continue
        (( m > freshest_mtime )) && freshest_mtime=$m
    done
    shopt -u nullglob

    [[ $freshest_mtime -eq 0 ]] && return 1
    local age=$(( $(date +%s) - freshest_mtime ))
    [[ $age -le $threshold ]]
}

# Combined check: Is Suricata fully operational?
nftban_ddos_suricata_is_available() {
    local check_binary="${DDOS_AUTO_CHECK_BINARY:-true}"
    local check_service="${DDOS_AUTO_CHECK_SERVICE:-true}"
    local check_eve="${DDOS_AUTO_CHECK_EVE_FILE:-true}"

    # Check binary
    if [[ "$check_binary" == "true" ]]; then
        if ! nftban_ddos_suricata_binary_exists; then
            return 1
        fi
    fi

    # Check service
    if [[ "$check_service" == "true" ]]; then
        if ! nftban_ddos_suricata_service_running; then
            return 1
        fi
    fi

    # Check EVE file
    if [[ "$check_eve" == "true" ]]; then
        if ! nftban_ddos_suricata_eve_active; then
            return 1
        fi
    fi

    return 0
}

# Get Suricata status details
nftban_ddos_suricata_get_status() {
    local status=""

    if nftban_ddos_suricata_binary_exists; then
        local version
        version=$(suricata -V 2>/dev/null | head -1 | grep -oP '\d+\.\d+\.\d+' || echo "unknown")
        status+="binary=OK(v$version) "
    else
        status+="binary=MISSING "
    fi

    if nftban_ddos_suricata_service_running; then
        status+="service=RUNNING "
    else
        status+="service=STOPPED "
    fi

    local eve_file="${DDOS_SURICATA_EVE_FILE:-/var/log/nftban/suricata/eve-alerts.json}"
    if [[ -f "$eve_file" ]]; then
        if nftban_ddos_suricata_eve_active; then
            local size
            size=$(du -h "$eve_file" 2>/dev/null | cut -f1)
            status+="eve=ACTIVE($size) "
        else
            status+="eve=STALE "
        fi
    else
        status+="eve=MISSING "
    fi

    echo "$status"
}

# =============================================================================
# EVE JSON PARSING
# =============================================================================

# Parse EVE JSON and extract DDoS-related alerts
_nftban_ddos_suricata_parse_eve() {
    local eve_file="${DDOS_SURICATA_EVE_FILE:-/var/log/nftban/suricata/eve-alerts.json}"
    local patterns="${DDOS_SURICATA_SIG_PATTERNS}"
    local window="${DDOS_SURICATA_ALERT_WINDOW:-120}"

    # Check if jq is available
    if ! command -v jq &>/dev/null; then
        _nftban_ddos_suricata_log "ERROR" "jq not found - required for EVE parsing"
        return 1
    fi

    # Get alerts from last N seconds
    local since
    since=$(date -d "-${window} seconds" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || \
            date -v-${window}S '+%Y-%m-%dT%H:%M:%S' 2>/dev/null)

    # Parse and filter alerts
    tail -n 10000 "$eve_file" 2>/dev/null | \
    jq -r --arg since "$since" --arg patterns "$patterns" '
        select(.event_type == "alert") |
        select(.timestamp >= $since) |
        select(.alert.signature | test($patterns; "i")) |
        [.src_ip, .alert.severity, .alert.signature, .alert.category] | @tsv
    ' 2>/dev/null
}

# Count alerts per IP in window
_nftban_ddos_suricata_count_alerts() {
    local ip="$1"
    local eve_file="${DDOS_SURICATA_EVE_FILE:-/var/log/nftban/suricata/eve-alerts.json}"
    local window="${DDOS_SURICATA_ALERT_WINDOW:-120}"

    local since
    since=$(date -d "-${window} seconds" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || \
            date -v-${window}S '+%Y-%m-%dT%H:%M:%S' 2>/dev/null)

    tail -n 10000 "$eve_file" 2>/dev/null | \
    jq -r --arg since "$since" --arg ip "$ip" '
        select(.event_type == "alert") |
        select(.timestamp >= $since) |
        select(.src_ip == $ip) |
        .src_ip
    ' 2>/dev/null | wc -l
}

# =============================================================================
# SCORING ENGINE
# =============================================================================

# Calculate score for an IP based on alerts
_nftban_ddos_suricata_calculate_score() {
    local ip="$1"
    local severity="$2"
    local signature="$3"

    local score=0

    # Base score from severity
    case "$severity" in
        1) score=$(echo "$score + $DDOS_SURICATA_SCORE_SEVERITY_1" | bc -l) ;;
        2) score=$(echo "$score + $DDOS_SURICATA_SCORE_SEVERITY_2" | bc -l) ;;
        3) score=$(echo "$score + $DDOS_SURICATA_SCORE_SEVERITY_3" | bc -l) ;;
        4) score=$(echo "$score + $DDOS_SURICATA_SCORE_SEVERITY_4" | bc -l) ;;
    esac

    # Bonus for specific attack types
    if echo "$signature" | grep -qi "syn.*flood"; then
        score=$(echo "$score + ${DDOS_SURICATA_SCORE_SYN_FLOOD:-0.15}" | bc -l)
    fi
    if echo "$signature" | grep -qi "amplification\|reflection"; then
        score=$(echo "$score + ${DDOS_SURICATA_SCORE_AMPLIFICATION:-0.20}" | bc -l)
    fi

    # Repetition bonus
    local alert_count
    alert_count=$(_nftban_ddos_suricata_count_alerts "$ip")

    if [[ $alert_count -ge 20 ]]; then
        score=$(echo "$score + $DDOS_SURICATA_SCORE_REPEAT_20" | bc -l)
    elif [[ $alert_count -ge 10 ]]; then
        score=$(echo "$score + $DDOS_SURICATA_SCORE_REPEAT_10" | bc -l)
    elif [[ $alert_count -ge 5 ]]; then
        score=$(echo "$score + $DDOS_SURICATA_SCORE_REPEAT_5" | bc -l)
    fi

    # Feed reputation (if enabled and function exists)
    if [[ "$DDOS_SURICATA_USE_FEEDS" == "true" ]]; then
        if type -t nftban_feeds_check_ip &>/dev/null; then
            if nftban_feeds_check_ip "$ip" &>/dev/null; then
                score=$(echo "$score + $DDOS_SURICATA_SCORE_BAD_REPUTATION" | bc -l)
            fi
        fi
    fi

    # GeoIP risk (if enabled and function exists)
    if [[ "$DDOS_SURICATA_USE_GEOIP" == "true" ]]; then
        if type -t nftban_geoip_lookup &>/dev/null; then
            local country
            country=$(nftban_geoip_lookup "$ip" 2>/dev/null)
            # High-risk countries (configurable)
            if echo "$country" | grep -qE "^(CN|RU|KP|IR)$"; then
                score=$(echo "$score + $DDOS_SURICATA_SCORE_HIGH_RISK_GEO" | bc -l)
            fi
        fi
    fi

    # Clamp to 0.0 - 1.0
    if (( $(echo "$score > 1.0" | bc -l) )); then
        score="1.0"
    fi
    if (( $(echo "$score < 0.0" | bc -l) )); then
        score="0.0"
    fi

    echo "$score"
}

# Decide action based on score
_nftban_ddos_suricata_decide_action() {
    local ip="$1"
    local score="$2"

    if (( $(echo "$score >= $DDOS_SURICATA_THRESHOLD_BLOCK_PERMANENT" | bc -l) )); then
        echo "block_permanent"
    elif (( $(echo "$score >= $DDOS_SURICATA_THRESHOLD_BLOCK_LONG" | bc -l) )); then
        echo "block_long"
    elif (( $(echo "$score >= $DDOS_SURICATA_THRESHOLD_BLOCK_SHORT" | bc -l) )); then
        echo "block_short"
    elif (( $(echo "$score >= $DDOS_SURICATA_THRESHOLD_OBSERVE" | bc -l) )); then
        echo "observe"
    else
        echo "ignore"
    fi
}

# =============================================================================
# BLOCKING ACTIONS
# =============================================================================

_nftban_ddos_suricata_block_ip() {
    local ip="$1"
    local duration="$2"
    local reason="$3"

    local table="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
    local set="${DDOS_CLASSIC_BLOCK_SET:-ddos_blocked}"

    # v1.19.0: Propagate errors instead of silencing (R18)
    local ban_rc=0
    if type -t nft_ipc_ban &>/dev/null; then
        if ! nft_ipc_ban "$ip" "$duration" "ddos_suricata:$reason" "ddos-suricata"; then
            ban_rc=1
        fi
    else
        if ! nft_ipc_add_element "$table" "$set" "$ip" "$duration"; then
            ban_rc=1
        fi
    fi

    if [[ "$ban_rc" -eq 0 ]]; then
        _nftban_ddos_suricata_log "INFO" "BLOCKED ip=$ip duration=${duration}s reason=$reason"
    else
        _nftban_ddos_suricata_log "ERROR" "BAN_FAILED ip=$ip duration=${duration}s reason=$reason"
    fi

    return "$ban_rc"
}

# =============================================================================
# MAIN PROCESSING LOOP
# =============================================================================

_nftban_ddos_suricata_process_alerts() {
    _nftban_ddos_suricata_load_config

    local processed=0
    local blocked=0

    # shellcheck disable=SC2034  # Structured Suricata parsing - only some fields used
    while IFS=$'\t' read -r ip severity signature category; do
        [[ -z "$ip" ]] && continue

        # Skip private/local IPs
        if echo "$ip" | grep -qE "^(127\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)"; then
            continue
        fi

        # Skip whitelisted IPs (CDNs, partners, etc.)
        if type -t nftban_is_whitelisted &>/dev/null; then
            if nftban_is_whitelisted "$ip"; then
                _nftban_ddos_suricata_log "INFO" "Skipping whitelisted IP: $ip"
                continue
            fi
        fi

        # Calculate score
        local score
        score=$(_nftban_ddos_suricata_calculate_score "$ip" "$severity" "$signature")

        # Decide action
        local action
        action=$(_nftban_ddos_suricata_decide_action "$ip" "$score")

        if [[ "$DDOS_SURICATA_LOG_SCORES" == "true" ]]; then
            _nftban_ddos_suricata_log "DEBUG" "ip=$ip severity=$severity score=$score action=$action sig=$signature"
        fi

        # v1.19.0: Check return codes — only count successful bans (R18)
        case "$action" in
            block_permanent)
                if _nftban_ddos_suricata_block_ip "$ip" "$DDOS_SURICATA_BAN_DURATION_PERMANENT" "permanent_threat"; then
                    # v1.19.20 FIX
                    ((blocked++)) || true
                fi
                ;;
            block_long)
                if _nftban_ddos_suricata_block_ip "$ip" "$DDOS_SURICATA_BAN_DURATION_LONG" "high_threat"; then
                    # v1.19.20 FIX
                    ((blocked++)) || true
                fi
                ;;
            block_short)
                if _nftban_ddos_suricata_block_ip "$ip" "$DDOS_SURICATA_BAN_DURATION_SHORT" "medium_threat"; then
                    # v1.19.20 FIX
                    ((blocked++)) || true
                fi
                ;;
            observe)
                _nftban_ddos_suricata_log "INFO" "OBSERVE ip=$ip score=$score"
                ;;
        esac

        # v1.19.20 FIX
        ((processed++)) || true

    done < <(_nftban_ddos_suricata_parse_eve)

    echo "processed=$processed blocked=$blocked"
}

# =============================================================================
# PUBLIC API
# =============================================================================

nftban_ddos_suricata_enable() {
    _nftban_ddos_suricata_load_config

    echo ""
    echo "Enabling Suricata DDoS Protection..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Check Suricata availability
    if ! nftban_ddos_suricata_is_available; then
        echo ""
        echo "  ERROR: Suricata is not available!"
        echo ""
        echo "  Status: $(nftban_ddos_suricata_get_status)"
        echo ""
        echo "  To use Suricata mode:"
        echo "    1. Install Suricata: apt install suricata"
        echo "    2. Start service:    systemctl start suricata"
        echo "    3. Verify EVE log:   ls -la $DDOS_SURICATA_EVE_FILE"
        echo ""
        return 1
    fi

    echo "  Suricata: $(nftban_ddos_suricata_get_status)"
    echo ""

    # Enable Classic Layer 0 if configured
    if [[ "$DDOS_SURICATA_USE_CLASSIC_LAYER0" == "true" ]]; then
        echo "  Enabling Classic Layer 0 (hard limits)..."
        if type -t nftban_ddos_classic_enable &>/dev/null; then
            nftban_ddos_classic_enable
        fi
    fi

    # Create block set if not exists (via IPC fragment)
    local table="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
    local set="${DDOS_CLASSIC_BLOCK_SET:-ddos_blocked}"

    if ! timeout 10s nft list set $table "$set" &>/dev/null; then
        local set_fragment="${NFTBAN_CONFIG_DIR:-/etc/nftban}/rules.d/ddos-suricata-set-$$.nft"
        echo "add set $table $set { type ipv4_addr; flags timeout; }" > "${set_fragment}.tmp" && mv -f "${set_fragment}.tmp" "$set_fragment"
        nft_ipc_apply_ruleset "$set_fragment" 2>/dev/null || true
        rm -f "$set_fragment" 2>/dev/null
    fi

    # Add drop rule for blocked set (via IPC fragment)
    if ! nft list chain $table input 2>/dev/null | grep -q "@$set drop"; then
        local rule_fragment="${NFTBAN_CONFIG_DIR:-/etc/nftban}/rules.d/ddos-suricata-rule-$$.nft"
        echo "add rule $table input ip saddr @$set counter drop comment \"DDoS Suricata blocked\"" > "${rule_fragment}.tmp" && mv -f "${rule_fragment}.tmp" "$rule_fragment"
        nft_ipc_apply_ruleset "$rule_fragment" 2>/dev/null || true
        rm -f "$rule_fragment" 2>/dev/null
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Suricata DDoS Protection ENABLED"
    echo ""
    echo "  EVE File:        $DDOS_SURICATA_EVE_FILE"
    echo "  Block Threshold: $DDOS_SURICATA_THRESHOLD_BLOCK_SHORT"
    echo "  Alert Window:    ${DDOS_SURICATA_ALERT_WINDOW}s"
    echo "  Use Feeds:       $DDOS_SURICATA_USE_FEEDS"
    echo "  Use GeoIP:       $DDOS_SURICATA_USE_GEOIP"
    echo "  Classic Layer0:  $DDOS_SURICATA_USE_CLASSIC_LAYER0"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    _nftban_ddos_suricata_log "INFO" "Suricata DDoS protection enabled"

    return 0
}

nftban_ddos_suricata_disable() {
    _nftban_ddos_suricata_load_config

    echo ""
    echo "Disabling Suricata DDoS Protection..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Disable Classic Layer 0 if it was enabled
    if [[ "$DDOS_SURICATA_USE_CLASSIC_LAYER0" == "true" ]]; then
        if type -t nftban_ddos_classic_disable &>/dev/null; then
            nftban_ddos_classic_disable
        fi
    fi

    # Flush block set via IPC
    local table="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
    local set="${DDOS_CLASSIC_BLOCK_SET:-ddos_blocked}"

    nft_ipc_flush_set "$table" "$set" 2>/dev/null || true

    echo ""
    echo "Suricata DDoS protection disabled"
    echo ""

    _nftban_ddos_suricata_log "INFO" "Suricata DDoS protection disabled"

    return 0
}

nftban_ddos_suricata_status() {
    _nftban_ddos_suricata_load_config

    echo ""
    echo "Suricata DDoS Protection Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Suricata availability
    echo ""
    echo "Suricata IDS:"
    if nftban_ddos_suricata_binary_exists; then
        local version
        version=$(suricata -V 2>/dev/null | head -1 | grep -oP '\d+\.\d+\.\d+' || echo "?")
        echo "  Binary:  OK (v$version)"
    else
        echo "  Binary:  NOT FOUND"
    fi

    if nftban_ddos_suricata_service_running; then
        echo "  Service: RUNNING"
    else
        echo "  Service: STOPPED"
    fi

    local eve_file="${DDOS_SURICATA_EVE_FILE:-/var/log/nftban/suricata/eve-alerts.json}"
    if [[ -f "$eve_file" ]]; then
        local size age
        size=$(du -h "$eve_file" 2>/dev/null | cut -f1)
        # Use -L to follow symlinks (backwards compatibility)
        local mtime
        mtime=$(stat -L -c %Y "$eve_file" 2>/dev/null || stat -L -f %m "$eve_file" 2>/dev/null)
        age=$(($(date +%s) - mtime))
        if [[ $age -le 60 ]]; then
            echo "  EVE Log: ACTIVE (${size}, ${age}s ago)"
        else
            echo "  EVE Log: STALE (${size}, ${age}s ago)"
        fi
    else
        echo "  EVE Log: NOT FOUND ($eve_file)"
    fi

    # Overall status
    echo ""
    if nftban_ddos_suricata_is_available; then
        echo "  Overall: READY"
    else
        echo "  Overall: NOT READY"
    fi

    # Configuration
    echo ""
    echo "Configuration:"
    echo "  Block Threshold:   $DDOS_SURICATA_THRESHOLD_BLOCK_SHORT"
    echo "  Ban Short:         ${DDOS_SURICATA_BAN_DURATION_SHORT}s"
    echo "  Ban Long:          ${DDOS_SURICATA_BAN_DURATION_LONG}s"
    echo "  Alert Window:      ${DDOS_SURICATA_ALERT_WINDOW}s"
    echo "  Use Feeds:         $DDOS_SURICATA_USE_FEEDS"
    echo "  Use GeoIP:         $DDOS_SURICATA_USE_GEOIP"
    echo "  Classic Layer0:    $DDOS_SURICATA_USE_CLASSIC_LAYER0"

    # Block set stats
    echo ""
    local table="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
    local set="${DDOS_CLASSIC_BLOCK_SET:-ddos_blocked}"
    local blocked_count
    blocked_count=$(timeout 10s nft list set $table "$set" 2>/dev/null | grep -c "timeout" || true)
    blocked_count=${blocked_count:-0}
    echo "Currently Blocked: $blocked_count IPs"

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    return 0
}

# Process alerts (called by timer/daemon)
nftban_ddos_suricata_process() {
    _nftban_ddos_suricata_load_config

    if ! nftban_ddos_suricata_is_available; then
        _nftban_ddos_suricata_log "WARN" "Suricata not available, skipping"
        return 1
    fi

    _nftban_ddos_suricata_process_alerts
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_ddos_suricata_enable
export -f nftban_ddos_suricata_disable
export -f nftban_ddos_suricata_status
export -f nftban_ddos_suricata_process
export -f nftban_ddos_suricata_is_available
export -f nftban_ddos_suricata_get_status
export -f nftban_ddos_suricata_binary_exists
export -f nftban_ddos_suricata_service_running
export -f nftban_ddos_suricata_eve_active
