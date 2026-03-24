#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0 - Port Scan Detection Module (Dual-Mode Controller)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="nftban_portscan"
# meta:type="core"
# meta:header="Port Scan Detection"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Dual-mode portscan detection with journalctl support"
# meta:inventory.files="/var/lib/nftban/portscan/"
# meta:inventory.binaries="nft,journalctl"
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/conf.d/portscan/main.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2025-11-05"
# meta:updated_date="2026-01-11"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# =============================================================================
# MODULE GUARD
# =============================================================================

[[ -n "${NFTBAN_PORTSCAN_LOADED:-}" ]] && return 0
readonly NFTBAN_PORTSCAN_LOADED=1

# =============================================================================
# MODULE METADATA
# =============================================================================

# shellcheck disable=SC2034  # Module metadata used when sourced
readonly PORTSCAN_MODULE_NAME="nftban_portscan"
# shellcheck disable=SC2034  # Module metadata used when sourced
readonly PORTSCAN_MODULE_VERSION="1.0.0"
# shellcheck disable=SC2034  # Module metadata used when sourced
readonly PORTSCAN_MODULE_TYPE="core"
# shellcheck disable=SC2034  # Module metadata used when sourced
readonly PORTSCAN_MODULE_DESCRIPTION="Port Scan Detection Module (Dual-Mode)"

# =============================================================================
# FHS COMPLIANT PATHS
# =============================================================================

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" 2>/dev/null || true
source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf.local" 2>/dev/null || true

readonly NFTBAN_PORTSCAN_CONFIG_DIR="${NFTBAN_CONFIG_DIR}/conf.d/portscan"
readonly NFTBAN_PORTSCAN_DATA_DIR="${PORTSCAN_DATA_DIR:-${NFTBAN_DATA_DIR}/portscan}"
readonly NFTBAN_PORTSCAN_CACHE_DIR="${PORTSCAN_CACHE_DIR:-${NFTBAN_CACHE_DIR}/portscan}"
readonly NFTBAN_PORTSCAN_LOG_FILE="${PORTSCAN_LOG_FILE:-${NFTBAN_LOG_DIR}/portscan.log}"

# =============================================================================
# LOGGING
# =============================================================================

_nftban_portscan_log() {
    local level="$1"
    local message="$2"

    mkdir -p "$(dirname "$NFTBAN_PORTSCAN_LOG_FILE")" 2>/dev/null || return 1

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [PORTSCAN] [$level] $message" >> "$NFTBAN_PORTSCAN_LOG_FILE"
}

# =============================================================================
# NFTABLES CONFIGURATION
# =============================================================================

readonly NFTBAN_NFT_TABLE_IPV4="${NFTBAN_NFT_TABLE_IPV4:-ip nftban}"
readonly NFTBAN_NFT_TABLE_IPV6="${NFTBAN_NFT_TABLE_IPV6:-ip6 nftban}"
# shellcheck disable=SC2034  # Used by classic/suricata mode modules
readonly NFTBAN_NFT_PORTSCAN_CHAIN="${PORTSCAN_NFT_CHAIN:-portscan_detection}"

# =============================================================================
# RUNTIME STATE
# =============================================================================

declare -g _PORTSCAN_ACTIVE_MODE=""      # Currently active mode
declare -g _PORTSCAN_INITIALIZED=0       # Initialization flag

# =============================================================================
# BANNER FUNCTION
# =============================================================================

nftban_portscan_banner() {
    cat <<'BANNER'
╔═══════════════════════════════════════════════════════════════════════════╗
║  🔍 Port Scan Detection (v1.0 Dual-Mode)                                  ║
║  NFTBan — Open-source Linux IPS and nftables firewall manager             ║
╚═══════════════════════════════════════════════════════════════════════════╝
BANNER
}

# =============================================================================
# CONFIGURATION LOADING
# =============================================================================

# Load main portscan configuration
nftban_portscan_load_config() {
    local config_dir="${NFTBAN_PORTSCAN_CONFIG_DIR}"

    # Load main config
    local main_config="${config_dir}/main.conf"
    local main_local="${config_dir}/main.conf.local"

    if [[ -f "$main_config" ]]; then
        # shellcheck source=/dev/null
        source "$main_config" || true
    fi

    if [[ -f "$main_local" ]]; then
        # shellcheck source=/dev/null
        source "$main_local" || true
    fi

    # Set defaults
    : "${PORTSCAN_ENABLED:=false}"
    : "${PORTSCAN_MODE:=auto}"
    : "${PORTSCAN_AUTO_CHECK_SERVICE:=true}"
    : "${PORTSCAN_AUTO_CHECK_BINARY:=true}"
    : "${PORTSCAN_AUTO_CHECK_EVE_FILE:=true}"
    : "${PORTSCAN_SURICATA_SERVICE_NAME:=suricata}"
    : "${PORTSCAN_SURICATA_BINARY:=/usr/bin/suricata}"
    : "${PORTSCAN_EVE_FRESHNESS_THRESHOLD:=60}"

    return 0
}

# =============================================================================
# MODE DETECTION
# =============================================================================

# Check if Suricata binary exists
_nftban_portscan_suricata_binary_exists() {
    local binary="${PORTSCAN_SURICATA_BINARY:-/usr/bin/suricata}"
    [[ -x "$binary" ]]
}

# Check if Suricata service is running
_nftban_portscan_suricata_service_running() {
    local service_name="${PORTSCAN_SURICATA_SERVICE_NAME:-suricata}"

    # Try systemctl first
    if command -v systemctl &>/dev/null; then
        if systemctl is-active --quiet "$service_name" 2>/dev/null; then
            return 0
        fi
    fi

    # Fall back to pgrep
    if pgrep -x suricata &>/dev/null; then
        return 0
    fi

    return 1
}

# Check if EVE JSON file is being actively written
_nftban_portscan_suricata_eve_active() {
    local eve_file="${PORTSCAN_SURICATA_EVE_FILE:-/var/log/nftban/suricata/eve-alerts.json}"
    local freshness="${PORTSCAN_EVE_FRESHNESS_THRESHOLD:-60}"

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
    [[ $age -le $freshness ]]
}

# Combined Suricata availability check
_nftban_portscan_suricata_is_available() {
    local check_binary="${PORTSCAN_AUTO_CHECK_BINARY:-true}"
    local check_service="${PORTSCAN_AUTO_CHECK_SERVICE:-true}"
    local check_eve="${PORTSCAN_AUTO_CHECK_EVE_FILE:-true}"

    # Check binary
    if [[ "$check_binary" == "true" ]]; then
        if ! _nftban_portscan_suricata_binary_exists; then
            return 1
        fi
    fi

    # Check service
    if [[ "$check_service" == "true" ]]; then
        if ! _nftban_portscan_suricata_service_running; then
            return 1
        fi
    fi

    # Check EVE file
    if [[ "$check_eve" == "true" ]]; then
        if ! _nftban_portscan_suricata_eve_active; then
            return 1
        fi
    fi

    return 0
}

# Detect which mode to use
_nftban_portscan_detect_mode() {
    local configured_mode="${PORTSCAN_MODE:-auto}"

    # If not auto, use configured mode
    if [[ "$configured_mode" != "auto" ]]; then
        echo "$configured_mode"
        return 0
    fi

    # Auto-detect: check if Suricata is available
    if _nftban_portscan_suricata_is_available; then
        echo "suricata"
        return 0
    fi

    # Fall back to classic
    echo "classic"
}

# =============================================================================
# MODULE LOADING
# =============================================================================

# Source the appropriate mode modules
_nftban_portscan_load_modules() {
    local lib_dir="${NFTBAN_LIB_DIR:-/usr/lib/nftban}"
    local core_dir="${lib_dir}/core"

    # Also check for dev paths
    local dev_core_dir
    if [[ -d "${BASH_SOURCE[0]%/*}" ]]; then
        dev_core_dir="${BASH_SOURCE[0]%/*}"
    fi

    # Load classic module
    local classic_module=""
    for path in "${core_dir}/nftban_portscan_classic.sh" "${dev_core_dir}/nftban_portscan_classic.sh"; do
        if [[ -f "$path" ]]; then
            classic_module="$path"
            break
        fi
    done

    if [[ -n "$classic_module" ]]; then
        # shellcheck source=/dev/null
        source "$classic_module" || return 1
        # Initialize classic module config and state
        if type -t nftban_portscan_classic_load_config &>/dev/null; then
            nftban_portscan_classic_load_config
        fi
        if type -t nftban_portscan_classic_init_state &>/dev/null; then
            nftban_portscan_classic_init_state
        fi
    fi

    # Load suricata module
    local suricata_module=""
    for path in "${core_dir}/nftban_portscan_suricata.sh" "${dev_core_dir}/nftban_portscan_suricata.sh"; do
        if [[ -f "$path" ]]; then
            suricata_module="$path"
            break
        fi
    done

    if [[ -n "$suricata_module" ]]; then
        # shellcheck source=/dev/null
        source "$suricata_module" || return 1
        # Initialize suricata module config and state
        if type -t nftban_portscan_suricata_load_config &>/dev/null; then
            nftban_portscan_suricata_load_config
        fi
        if type -t nftban_portscan_suricata_init_state &>/dev/null; then
            nftban_portscan_suricata_init_state
        fi
    fi

    return 0
}

# =============================================================================
# INITIALIZATION
# =============================================================================

# Initialize directory structure
nftban_portscan_init_dirs() {
    local dirs=(
        "$NFTBAN_PORTSCAN_DATA_DIR"
        "$NFTBAN_PORTSCAN_CACHE_DIR"
        "$(dirname "$NFTBAN_PORTSCAN_LOG_FILE")"
    )

    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir" 2>/dev/null || true
            chmod 750 "$dir" 2>/dev/null || true
        fi
    done

    # Create log file if it doesn't exist
    if [[ ! -f "$NFTBAN_PORTSCAN_LOG_FILE" ]]; then
        touch "$NFTBAN_PORTSCAN_LOG_FILE" 2>/dev/null || true
        chmod 640 "$NFTBAN_PORTSCAN_LOG_FILE" 2>/dev/null || true
        chown nftban:nftban "$NFTBAN_PORTSCAN_LOG_FILE" 2>/dev/null || true
    fi

    return 0
}

# Initialize portscan detection
nftban_portscan_init() {
    [[ $_PORTSCAN_INITIALIZED -eq 1 ]] && return 0

    _nftban_portscan_log "INFO" "Initializing portscan detection module"

    # Load configuration
    nftban_portscan_load_config

    # Check if enabled
    if [[ "${PORTSCAN_ENABLED:-false}" != "true" ]]; then
        _nftban_portscan_log "INFO" "Portscan detection is disabled"
        return 0
    fi

    # Initialize directories
    nftban_portscan_init_dirs

    # Load mode modules
    _nftban_portscan_load_modules

    # Detect mode
    _PORTSCAN_ACTIVE_MODE=$(_nftban_portscan_detect_mode)

    _nftban_portscan_log "INFO" "Portscan mode: ${_PORTSCAN_ACTIVE_MODE}"

    _PORTSCAN_INITIALIZED=1
    return 0
}

# =============================================================================
# ENABLE/DISABLE
# =============================================================================

# Enable portscan detection
nftban_portscan_enable() {
    # Load config and modules even if currently disabled — enable needs to work
    # when portscan is off (that's the whole point of enable)
    nftban_portscan_load_config
    nftban_portscan_init_dirs
    _nftban_portscan_load_modules

    # Detect mode (init may have returned early if disabled, leaving mode unset)
    local mode="${_PORTSCAN_ACTIVE_MODE:-$(_nftban_portscan_detect_mode)}"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Portscan Detection - Mode: ${mode^^}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    _nftban_portscan_log "INFO" "Enabling portscan detection (mode: ${mode})"

    # Step 1: Apply nftables rules FIRST (before persisting config)
    local enable_result=0
    case "$mode" in
        classic)
            echo ""
            echo "  Using CLASSIC mode (native nftables)"
            echo ""
            if type -t nftban_portscan_classic_enable &>/dev/null; then
                nftban_portscan_classic_enable || enable_result=$?
            else
                echo "  ERROR: Classic mode module not loaded!" >&2
                _nftban_portscan_log "ERROR" "Classic mode module not loaded"
                return 1
            fi
            ;;
        suricata)
            echo ""
            echo "  Using SURICATA mode (IDS-integrated)"
            echo ""
            if type -t nftban_portscan_suricata_enable &>/dev/null; then
                nftban_portscan_suricata_enable || enable_result=$?
            else
                echo "  ERROR: Suricata mode module not loaded!" >&2
                _nftban_portscan_log "ERROR" "Suricata mode module not loaded"
                return 1
            fi
            ;;
        hybrid)
            echo ""
            echo "  Using HYBRID mode (Classic + Suricata)"
            echo ""
            if type -t nftban_portscan_classic_enable &>/dev/null; then
                nftban_portscan_classic_enable || enable_result=$?
            fi
            if type -t nftban_portscan_suricata_enable &>/dev/null; then
                nftban_portscan_suricata_enable || enable_result=$?
            fi
            ;;
        *)
            echo "  ERROR: Unknown mode: ${mode}" >&2
            _nftban_portscan_log "ERROR" "Unknown mode: ${mode}"
            return 1
            ;;
    esac

    # Step 2: Verify nft rules were actually applied
    if [[ $enable_result -ne 0 ]]; then
        echo ""
        echo "  ❌ ERROR: Failed to apply nftables rules!" >&2
        echo "  Check: is nftband daemon running? (systemctl status nftband)" >&2
        _nftban_portscan_log "ERROR" "Failed to apply nftables rules (exit=$enable_result)"
        return 1
    fi

    # Step 3: Persist PORTSCAN_ENABLED=true ONLY after nft rules succeed
    local local_conf="${NFTBAN_PORTSCAN_CONFIG_DIR}/main.conf.local"
    mkdir -p "$(dirname "$local_conf")" || return 1
    if grep -q "^PORTSCAN_ENABLED=" "$local_conf" 2>/dev/null; then
        sed -i 's/^PORTSCAN_ENABLED=.*/PORTSCAN_ENABLED="true"/' "$local_conf"
    else
        echo 'PORTSCAN_ENABLED="true"' >> "$local_conf"
    fi
    PORTSCAN_ENABLED="true"

    # Step 4: Auto-restart nftband to activate immediately
    if systemctl is-active nftband &>/dev/null; then
        echo "  Restarting nftband daemon..."
        if systemctl restart nftband 2>/dev/null; then
            echo "  ✅ Daemon restarted — portscan detection is now active"
        else
            echo "  ⚠️  Daemon restart failed — run: systemctl restart nftband" >&2
        fi
    else
        echo "  ⚠️  nftband not running — start with: systemctl start nftband"
    fi

    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  ✅ Portscan Detection ENABLED (${mode^^})"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""

    _nftban_portscan_log "INFO" "Portscan detection enabled successfully"
    return 0
}

# Disable portscan detection
nftban_portscan_disable() {
    local mode="${_PORTSCAN_ACTIVE_MODE:-classic}"

    echo ""
    echo "  Disabling portscan detection (${mode})..."

    # Persist PORTSCAN_ENABLED=false to local config override
    local local_conf="${NFTBAN_PORTSCAN_CONFIG_DIR}/main.conf.local"
    mkdir -p "$(dirname "$local_conf")" || return 1
    if grep -q "^PORTSCAN_ENABLED=" "$local_conf" 2>/dev/null; then
        sed -i 's/^PORTSCAN_ENABLED=.*/PORTSCAN_ENABLED="false"/' "$local_conf"
    else
        echo 'PORTSCAN_ENABLED="false"' >> "$local_conf"
    fi
    PORTSCAN_ENABLED="false"

    _nftban_portscan_log "INFO" "Disabling portscan detection"

    case "$mode" in
        classic)
            if type -t nftban_portscan_classic_disable &>/dev/null; then
                nftban_portscan_classic_disable
            fi
            ;;
        suricata)
            if type -t nftban_portscan_suricata_disable &>/dev/null; then
                nftban_portscan_suricata_disable
            fi
            ;;
        hybrid)
            if type -t nftban_portscan_classic_disable &>/dev/null; then
                nftban_portscan_classic_disable
            fi
            if type -t nftban_portscan_suricata_disable &>/dev/null; then
                nftban_portscan_suricata_disable
            fi
            ;;
    esac

    _PORTSCAN_INITIALIZED=0

    echo "  ✅ Portscan detection disabled"
    echo ""

    _nftban_portscan_log "INFO" "Portscan detection disabled"
    return 0
}

# =============================================================================
# STATUS
# =============================================================================

# Get portscan detection status
nftban_portscan_status() {
    # v1.19.20 FIX (B6): Ensure config is loaded before using variables
    nftban_portscan_load_config

    # Show unified banner
    if type -t nftban_banner >/dev/null 2>&1; then
        nftban_banner "portscan"
        echo ""
    fi
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  NFTBan Portscan Detection Status                       ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""

    # ==========================================================================
    # MAIN STATUS - Is it enabled and protecting?
    # ==========================================================================
    # v1.19.20 FIX (B5): Correct default to false (matches config loader)
    local is_enabled="${PORTSCAN_ENABLED:-false}"
    local auto_ban="${PORTSCAN_AUTO_BAN:-true}"

    if [[ "$is_enabled" == "true" ]]; then
        echo "  Status:      ✅ ENABLED - Port scan detection is active"
    else
        echo "  Status:      ❌ DISABLED - Port scan detection is OFF"
        echo ""
        echo "  To enable:   nftban portscan enable"
        echo ""
        return 0
    fi

    if [[ "$auto_ban" == "true" ]]; then
        echo "  Auto-Ban:    ✅ ON - Detected scanners will be automatically banned"
    else
        echo "  Auto-Ban:    ⚠️  OFF - Monitoring only, no automatic bans"
    fi
    echo ""

    # ==========================================================================
    # DETECTION METHOD
    # ==========================================================================
    echo "DETECTION METHOD"
    echo "───────────────────────────────────────────────────────────"

    local configured_mode="${PORTSCAN_MODE:-auto}"
    local detected_mode
    detected_mode=$(_nftban_portscan_detect_mode)
    local active_mode="${_PORTSCAN_ACTIVE_MODE:-$detected_mode}"

    case "$active_mode" in
        suricata)
            echo "  Using:       Suricata IDS (recommended, high accuracy)"
            echo "  Mode:        Suricata is analyzing network traffic in real-time"
            ;;
        classic)
            echo "  Using:       Classic nftables log parsing"
            echo "  Mode:        Monitoring closed port connection attempts"
            ;;
        hybrid)
            echo "  Using:       Hybrid (Suricata + nftables logs)"
            echo "  Mode:        Dual detection for maximum coverage"
            ;;
        *)
            echo "  Using:       Unknown (needs initialization)"
            ;;
    esac
    echo ""

    # ==========================================================================
    # SURICATA STATUS (if relevant)
    # ==========================================================================
    local suricata_available=false
    if _nftban_portscan_suricata_is_available; then
        suricata_available=true
    fi

    echo "SURICATA IDS"
    echo "───────────────────────────────────────────────────────────"
    if [[ "$suricata_available" == "true" ]]; then
        echo "  Available:   ✅ YES - Suricata is installed and running"
        echo "  Service:     $(systemctl is-active suricata 2>/dev/null || echo 'unknown')"

        # Support Suricata 7.x threaded logging: check all eve-alerts*.json files
        local eve_dir="${NFTBAN_LOG_DIR:-/var/log/nftban}/suricata"
        local eve_file="${PORTSCAN_SURICATA_EVE_FILE:-${eve_dir}/eve-alerts.json}"
        local freshest_mtime=0 freshest_file="" now_ts eve_age

        shopt -s nullglob
        for f in "$eve_dir"/eve-alerts*.json; do
            [[ -f "$f" ]] || continue
            local m
            m=$(stat -L -c %Y -- "$f" 2>/dev/null) || continue
            [[ "$m" =~ ^[0-9]+$ ]] || continue
            if (( m > freshest_mtime )); then
                freshest_mtime=$m
                freshest_file="$f"
            fi
        done
        shopt -u nullglob

        if [[ $freshest_mtime -gt 0 ]]; then
            now_ts=$(date +%s)
            eve_age=$(( now_ts - freshest_mtime ))
            local source_note=""
            [[ "$freshest_file" != "$eve_file" ]] && source_note=" (threaded)"
            if [[ $eve_age -lt 300 ]]; then
                echo "  EVE Log:     ✅ Active (updated ${eve_age}s ago${source_note})"
            else
                echo "  EVE Log:     ⚠️  Stale (last update ${eve_age}s ago${source_note})"
            fi
        else
            echo "  EVE Log:     ❌ Not found in $eve_dir"
        fi
    else
        echo "  Available:   ❌ NO - Suricata not available for detection"
        if ! command -v suricata &>/dev/null; then
            echo "  Reason:      Binary not installed"
            echo "  Fix:         nftban setup suricata"
        elif ! systemctl is-active suricata &>/dev/null; then
            echo "  Reason:      Service not running"
            echo "  Fix:         systemctl start suricata"
        else
            # Binary exists and service running — EVE log must be the issue
            # Support Suricata 7.x threaded logging
            local eve_dir="${NFTBAN_LOG_DIR:-/var/log/nftban}/suricata"
            local eve_file="${PORTSCAN_SURICATA_EVE_FILE:-${eve_dir}/eve-alerts.json}"
            local freshest_mtime=0

            shopt -s nullglob
            for f in "$eve_dir"/eve-alerts*.json; do
                [[ -f "$f" ]] || continue
                local m
                m=$(stat -L -c %Y -- "$f" 2>/dev/null) || continue
                [[ "$m" =~ ^[0-9]+$ ]] || continue
                (( m > freshest_mtime )) && freshest_mtime=$m
            done
            shopt -u nullglob

            if [[ $freshest_mtime -eq 0 ]]; then
                echo "  Reason:      EVE log not found in $eve_dir"
                echo "  Fix:         Check Suricata output config (suricata.yaml)"
            else
                local eve_age=$(( $(date +%s) - freshest_mtime ))
                echo "  Reason:      EVE log stale (last update ${eve_age}s ago, threshold: ${PORTSCAN_EVE_FRESHNESS_THRESHOLD:-60}s)"
                echo "  Fix:         Check Suricata is processing traffic: suricata --build-info"
                echo "               Verify EVE output: grep eve-log /etc/suricata/suricata.yaml"
            fi
        fi
    fi
    echo ""

    # ==========================================================================
    # DETECTION SETTINGS
    # ==========================================================================
    echo "DETECTION SETTINGS"
    echo "───────────────────────────────────────────────────────────"
    echo "  Threshold:   ${PORTSCAN_THRESHOLD:-10} unique ports triggers detection"
    echo "  Time Window: ${PORTSCAN_TIME_WINDOW:-300} seconds ($(( ${PORTSCAN_TIME_WINDOW:-300} / 60 )) minutes)"
    echo "  Ban Type:    ${PORTSCAN_BAN_TYPE:-temporary}"
    if [[ "${PORTSCAN_BAN_TYPE:-temporary}" == "temporary" ]]; then
        echo "  Ban Duration: ${PORTSCAN_BAN_TIME:-3600} seconds ($(( ${PORTSCAN_BAN_TIME:-3600} / 60 )) minutes)"
    fi
    echo ""

    # ==========================================================================
    # RECENT ACTIVITY
    # ==========================================================================
    echo "RECENT ACTIVITY (last 24h)"
    echo "───────────────────────────────────────────────────────────"
    local ban_log="${NFTBAN_BAN_LOG:-${NFTBAN_LOG_DIR:-/var/log/nftban}/bans.log}"
    if [[ -f "$ban_log" ]]; then
        local yesterday today scan_bans
        yesterday=$(date -d '24 hours ago' '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')
        today=$(date '+%Y-%m-%d')
        # Count portscan bans from last 24 hours
        scan_bans=$(grep "|portscan|" "$ban_log" 2>/dev/null | grep -cE "^($yesterday|$today)" || true)
        [[ -z "$scan_bans" ]] && scan_bans=0
        echo "  Port scans detected: $scan_bans"
    else
        echo "  No activity log found"
    fi
    echo ""

    # ==========================================================================
    # DETECTION MODES EXPLAINED
    # ==========================================================================
    echo "DETECTION MODES"
    echo "───────────────────────────────────────────────────────────"
    echo ""
    echo "  classic   - Uses nftables logging of closed port attempts"
    echo "              Parses kernel/journalctl logs for scan patterns"
    echo ""
    echo "  suricata  - Uses Suricata IDS with portscan rules"
    echo "              Better accuracy, lower false positives"
    echo ""
    echo "  hybrid    - Combines both classic and Suricata detection"
    echo "              Maximum coverage with redundant detection"
    echo ""
    echo "  auto      - Auto-selects based on Suricata availability"
    echo "              Uses suricata if available, otherwise classic"
    echo ""

    # ==========================================================================
    # CONFIGURATION
    # ==========================================================================
    echo "CONFIGURATION"
    echo "───────────────────────────────────────────────────────────"
    echo ""
    echo "  Config File:  /etc/nftban/conf.d/portscan/main.conf"
    local local_file="/etc/nftban/conf.d/portscan/main.conf.local"
    if [[ -f "$local_file" ]]; then
        echo "  Override File:  $local_file  [Active]"
    else
        echo "  Override File:  $local_file  [Not created]"
    fi
    echo "  Log File:     ${NFTBAN_PORTSCAN_LOG_FILE}"
    echo ""
    echo "  Key Settings:"
    echo "    PORTSCAN_ENABLED=true|false"
    echo "    PORTSCAN_MODE=auto|classic|suricata|hybrid"
    echo "    PORTSCAN_AUTO_BAN=true|false   - Auto-ban detected scanners"
    echo "    PORTSCAN_THRESHOLD=10          - Ports to trigger detection"
    echo "    PORTSCAN_TIME_WINDOW=300       - Detection window (seconds)"
    echo "    PORTSCAN_BAN_TIME=3600         - Ban duration (seconds)"
    echo ""
    echo "  Note: Put custom settings in main.conf.local (survives upgrades)"
    echo ""

    # ==========================================================================
    # v1.19.20 (B8): OPEN PORTS VISIBILITY
    # ==========================================================================
    echo "OPEN PORTS (Allowed Inbound - Bypass Detection)"
    echo "───────────────────────────────────────────────────────────"

    local tcp_ports_ipv4="" udp_ports_ipv4="" tcp_ports_ipv6="" udp_ports_ipv6=""

    # IPv4 ports
    if nft list set ip nftban tcp_ports_in &>/dev/null; then
        tcp_ports_ipv4=$(nft list set ip nftban tcp_ports_in 2>/dev/null | \
            grep "elements" | sed 's/.*elements = { //;s/ }$//' | tr -d '\n\t') || true
    fi
    if nft list set ip nftban udp_ports_in &>/dev/null; then
        udp_ports_ipv4=$(nft list set ip nftban udp_ports_in 2>/dev/null | \
            grep "elements" | sed 's/.*elements = { //;s/ }$//' | tr -d '\n\t') || true
    fi

    # IPv6 ports
    if nft list set ip6 nftban tcp_ports_in &>/dev/null; then
        tcp_ports_ipv6=$(nft list set ip6 nftban tcp_ports_in 2>/dev/null | \
            grep "elements" | sed 's/.*elements = { //;s/ }$//' | tr -d '\n\t') || true
    fi
    if nft list set ip6 nftban udp_ports_in &>/dev/null; then
        udp_ports_ipv6=$(nft list set ip6 nftban udp_ports_in 2>/dev/null | \
            grep "elements" | sed 's/.*elements = { //;s/ }$//' | tr -d '\n\t') || true
    fi

    echo "  IPv4:"
    echo "    TCP:  ${tcp_ports_ipv4:-none}"
    echo "    UDP:  ${udp_ports_ipv4:-none}"
    echo ""
    echo "  IPv6:"
    echo "    TCP:  ${tcp_ports_ipv6:-none}"
    echo "    UDP:  ${udp_ports_ipv6:-none}"
    echo ""

    # ==========================================================================
    # v1.19.20 (B9): JUMP RULE VERIFICATION
    # ==========================================================================
    echo "NFTABLES RULE VERIFICATION"
    echo "───────────────────────────────────────────────────────────"

    local expected_position="${PORTSCAN_NFT_JUMP_POSITION:-established}"
    local ipv4_jump_exists=false ipv6_jump_exists=false
    local ipv4_jump_index=0 ipv6_jump_index=0
    local ipv4_accept_index=0 ipv6_accept_index=0
    local chain_rules=""

    # Check IPv4 jump rule
    if nft list chain ip nftban input &>/dev/null; then
        chain_rules=$(nft -a list chain ip nftban input 2>/dev/null) || true
        if echo "$chain_rules" | grep -q "jump portscan_detection"; then
            ipv4_jump_exists=true
            ipv4_jump_index=$(echo "$chain_rules" | grep -n "jump portscan_detection" | cut -d: -f1 | head -1) || true
        fi
        # Find first service accept rule (tcp dport ... accept)
        ipv4_accept_index=$(echo "$chain_rules" | grep -n "tcp dport.*accept" | head -1 | cut -d: -f1) || true
    fi

    # Check IPv6 jump rule
    if nft list chain ip6 nftban input &>/dev/null; then
        chain_rules=$(nft -a list chain ip6 nftban input 2>/dev/null) || true
        if echo "$chain_rules" | grep -q "jump portscan_detection"; then
            ipv6_jump_exists=true
            ipv6_jump_index=$(echo "$chain_rules" | grep -n "jump portscan_detection" | cut -d: -f1 | head -1) || true
        fi
        ipv6_accept_index=$(echo "$chain_rules" | grep -n "tcp dport.*accept" | head -1 | cut -d: -f1) || true
    fi

    # Display IPv4 results
    echo "  IPv4 Jump Rule:"
    if [[ "$ipv4_jump_exists" == "true" ]]; then
        echo "    Exists:    ✅ YES (rule #${ipv4_jump_index})"
        if [[ -n "$ipv4_accept_index" ]] && [[ "$ipv4_accept_index" =~ ^[0-9]+$ ]] && \
           [[ "$ipv4_jump_index" =~ ^[0-9]+$ ]] && [[ "$ipv4_jump_index" -gt "$ipv4_accept_index" ]]; then
            echo "    Position:  ❌ WRONG - After service accepts (rule #${ipv4_accept_index})"
            echo "    ⚠️  WARNING: Scans to open ports will NOT be detected!"
        else
            echo "    Position:  ✅ CORRECT - Before service accepts"
        fi
    else
        echo "    Exists:    ❌ NO - Jump rule not found!"
        echo "    ⚠️  WARNING: Portscan detection is NOT active in nftables!"
    fi
    echo ""

    # Display IPv6 results
    echo "  IPv6 Jump Rule:"
    if [[ "$ipv6_jump_exists" == "true" ]]; then
        echo "    Exists:    ✅ YES (rule #${ipv6_jump_index})"
        if [[ -n "$ipv6_accept_index" ]] && [[ "$ipv6_accept_index" =~ ^[0-9]+$ ]] && \
           [[ "$ipv6_jump_index" =~ ^[0-9]+$ ]] && [[ "$ipv6_jump_index" -gt "$ipv6_accept_index" ]]; then
            echo "    Position:  ❌ WRONG - After service accepts"
            echo "    ⚠️  WARNING: IPv6 scans to open ports will NOT be detected!"
        else
            echo "    Position:  ✅ CORRECT - Before service accepts"
        fi
    else
        echo "    Exists:    ❌ NO - IPv6 jump rule not found!"
    fi
    echo ""
    echo "  Expected Position: after '${expected_position}' rule"
    echo ""

    # ==========================================================================
    # COMMANDS
    # ==========================================================================
    echo "COMMANDS"
    echo "───────────────────────────────────────────────────────────"
    echo ""
    echo "  nftban portscan enable         - Enable port scan detection"
    echo "  nftban portscan disable        - Disable port scan detection"
    echo "  nftban portscan history        - View detected port scans"
    echo "  nftban portscan check          - Run manual detection now"
    echo "  nftban portscan sync           - Sync logs from journalctl"
    echo "  nftban portscan help           - Show all available commands"
    echo ""

    return 0
}

# =============================================================================
# RUN (PERIODIC PROCESSING)
# =============================================================================

# Run portscan detection cycle
nftban_portscan_run() {
    if [[ "${PORTSCAN_ENABLED:-false}" != "true" ]]; then
        return 0
    fi

    # Initialize if needed
    if [[ $_PORTSCAN_INITIALIZED -eq 0 ]]; then
        nftban_portscan_init
    fi

    local mode="${_PORTSCAN_ACTIVE_MODE}"

    case "$mode" in
        classic)
            if type -t nftban_portscan_classic_run &>/dev/null; then
                nftban_portscan_classic_run
            fi
            ;;
        suricata)
            if type -t nftban_portscan_suricata_run &>/dev/null; then
                nftban_portscan_suricata_run
            fi
            ;;
        hybrid)
            if type -t nftban_portscan_classic_run &>/dev/null; then
                nftban_portscan_classic_run
            fi
            if type -t nftban_portscan_suricata_run &>/dev/null; then
                nftban_portscan_suricata_run
            fi
            ;;
    esac

    return 0
}

# =============================================================================
# CLI INTERFACE
# =============================================================================

# Main CLI handler
nftban_portscan_cli() {
    local cmd="${1:-status}"
    shift || true

    case "$cmd" in
        enable)
            nftban_portscan_enable
            ;;
        disable)
            nftban_portscan_disable
            ;;
        status)
            nftban_portscan_status
            ;;
        run|process)
            nftban_portscan_run
            ;;
        mode)
            echo "Configured: ${PORTSCAN_MODE:-auto}"
            echo "Active: ${_PORTSCAN_ACTIVE_MODE:-$(_nftban_portscan_detect_mode)}"
            ;;
        help|--help|-h)
            echo "Usage: nftban portscan <command>"
            echo ""
            echo "Commands:"
            echo "  enable    Enable portscan detection"
            echo "  disable   Disable portscan detection"
            echo "  status    Show portscan detection status"
            echo "  run       Run detection cycle"
            echo "  mode      Show current mode"
            echo ""
            echo "Configuration: ${NFTBAN_PORTSCAN_CONFIG_DIR}/"
            ;;
        *)
            echo "Unknown command: $cmd"
            echo "Run 'nftban portscan help' for usage"
            return 1
            ;;
    esac

    return 0
}

# =============================================================================
# LOGGING HELPER
# =============================================================================

# Log function (use nftban_log if available, otherwise echo)
if ! type -t nftban_log &>/dev/null; then
    nftban_log() {
        local level="$1"
        local module="$2"
        local message="$3"
        echo "[$(date -Iseconds)] [${level}] [${module}] ${message}" >&2
    }
fi

# =============================================================================
# LOG CHECKING FUNCTIONS (for CLI)
# =============================================================================

# Check/process logs for portscan detection
# Supports both traditional log files and journalctl
nftban_portscan_check() {
    local log_source="${1:-}"

    # Load classic module if needed
    if ! type -t nftban_portscan_classic_process_logs &>/dev/null; then
        local classic_module="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_portscan_classic.sh"
        if [[ -f "$classic_module" ]]; then
            # shellcheck source=/dev/null
            source "$classic_module" || return 1
            nftban_portscan_classic_load_config
            nftban_portscan_classic_init_state
        fi
    fi

    # If journalctl source, run the classic processor which handles it
    if [[ "$log_source" == "journalctl" ]]; then
        echo "Processing kernel logs from journalctl..."
        if type -t nftban_portscan_classic_process_logs &>/dev/null; then
            nftban_portscan_classic_process_logs
        else
            echo "ERROR: Classic portscan module not loaded" >&2
            return 1
        fi
    else
        # Traditional file-based processing
        echo "Processing log file: $log_source"
        if type -t nftban_portscan_classic_process_logs &>/dev/null; then
            # Override the log file temporarily (used by sourced module)
            # shellcheck disable=SC2034
            PORTSCAN_CLASSIC_LOG_FILE="$log_source"
            nftban_portscan_classic_process_logs
        else
            echo "ERROR: Classic portscan module not loaded" >&2
            return 1
        fi
    fi

    # Show results
    local tracked=0
    local blocked=0
    # Check if arrays are declared (empty arrays still have count 0)
    if declare -p _PORTSCAN_CLASSIC_IP_PORTS &>/dev/null; then
        tracked="${#_PORTSCAN_CLASSIC_IP_PORTS[@]}"
    fi
    if declare -p _PORTSCAN_CLASSIC_IP_BLOCKED &>/dev/null; then
        blocked="${#_PORTSCAN_CLASSIC_IP_BLOCKED[@]}"
    fi
    echo ""
    echo "Detection Summary:"
    echo "  IPs tracked: $tracked"
    echo "  IPs blocked: $blocked"

    return 0
}

# Sync logs from journalctl to portscan log file
nftban_portscan_sync_logs() {
    local portscan_log="${NFTBAN_PORTSCAN_LOG:-${NFTBAN_LOG_DIR:-/var/log/nftban}/portscan.log}"
    local log_prefix="${PORTSCAN_CLASSIC_LOG_PREFIX:-NFTBAN_PORTSCAN:}"
    local time_range="${1:-24h}"

    # Ensure log directory exists
    local log_dir
    log_dir=$(dirname "$portscan_log")
    mkdir -p "$log_dir" 2>/dev/null || true

    echo "Syncing portscan logs from journalctl (last $time_range)..."

    # Extract portscan entries from journalctl and append to log
    if command -v journalctl &>/dev/null; then
        journalctl -k --since "$time_range ago" --no-pager 2>/dev/null | \
            grep "$log_prefix" >> "$portscan_log" 2>/dev/null || true
        echo "Logs synced to: $portscan_log"
    else
        echo "ERROR: journalctl not available" >&2
        return 1
    fi

    return 0
}

# =============================================================================
# AUTO-INITIALIZATION
# =============================================================================

# Initialize on source if not in library mode
if [[ "${NFTBAN_LIBRARY_MODE:-0}" != "1" ]]; then
    nftban_portscan_load_config
fi

# =============================================================================
# END OF PORTSCAN MODULE
# =============================================================================
