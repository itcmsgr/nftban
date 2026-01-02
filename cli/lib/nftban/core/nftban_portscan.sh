#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0 - Port Scan Detection Module (Dual-Mode Controller)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Master controller for portscan detection with dual-mode support
#
# meta:name=nftban_portscan
# meta:type=core
# meta:header=Port Scan Detection
# meta:version=1.0.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Detects IP addresses accessing multiple ports and auto-bans scanners
# meta:input=Configuration from /etc/nftban/conf.d/portscan/
# meta:output=nftables logging rules and ban actions
#
# **Dual-Mode Architecture**
# - Classic Mode: Pure nftables log-based detection (no IDS required)
# - Suricata Mode: Uses Suricata IDS EVE JSON alerts for intelligent detection
# - Auto Mode: Automatically selects mode based on Suricata availability
# - Hybrid Mode: Classic for logging + Suricata for intelligent detection
#
# **Inventory & Requirements**
# meta:depends=bash>=4.0,nftables>=0.9.0,nftban_output.sh
# meta:optional=suricata,jq
#
# meta:created_date=2025-11-05
# meta:updated_date=2025-12-01
# meta:migrated_from=v0.7.3:cli/lib/nftban/core/nftban_portscan.sh
# =============================================================================

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
readonly PORTSCAN_MODULE_VERSION="1.0.0"
readonly PORTSCAN_MODULE_TYPE="core"
readonly PORTSCAN_MODULE_DESCRIPTION="Port Scan Detection Module (Dual-Mode)"

# =============================================================================
# FHS COMPLIANT PATHS
# =============================================================================

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
[[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" ]] && source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf"

readonly NFTBAN_PORTSCAN_CONFIG_DIR="${NFTBAN_CONFIG_DIR}/conf.d/portscan"
readonly NFTBAN_PORTSCAN_DATA_DIR="${PORTSCAN_DATA_DIR:-${NFTBAN_DATA_DIR}/portscan}"
readonly NFTBAN_PORTSCAN_CACHE_DIR="${PORTSCAN_CACHE_DIR:-${NFTBAN_CACHE_DIR}/portscan}"
readonly NFTBAN_PORTSCAN_LOG_FILE="${PORTSCAN_LOG_FILE:-${NFTBAN_LOG_DIR}/portscan.log}"

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
╔══════════════════════════════════════════════════════════╗
║  🔍 Port Scan Detection (v1.0 Dual-Mode)                ║
║  nftban — Simplifying Linux Firewall Management         ║
╚══════════════════════════════════════════════════════════╝
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
        source "$main_config"
    fi

    if [[ -f "$main_local" ]]; then
        # shellcheck source=/dev/null
        source "$main_local"
    fi

    # Set defaults
    : "${PORTSCAN_ENABLED:=true}"
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
    local eve_file="${PORTSCAN_SURICATA_EVE_FILE:-/var/log/suricata/eve.json}"
    local freshness="${PORTSCAN_EVE_FRESHNESS_THRESHOLD:-60}"

    [[ -f "$eve_file" ]] || return 1

    local file_mtime
    file_mtime=$(stat -c %Y "$eve_file" 2>/dev/null) || return 1

    local current_time
    current_time=$(date +%s)

    local age
    age=$((current_time - file_mtime))
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
        source "$classic_module"
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
        source "$suricata_module"
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

    nftban_log "INFO" "portscan" "Initializing portscan detection module"

    # Load configuration
    nftban_portscan_load_config

    # Check if enabled
    if [[ "${PORTSCAN_ENABLED:-true}" != "true" ]]; then
        nftban_log "INFO" "portscan" "Portscan detection is disabled"
        return 0
    fi

    # Initialize directories
    nftban_portscan_init_dirs

    # Load mode modules
    _nftban_portscan_load_modules

    # Detect mode
    _PORTSCAN_ACTIVE_MODE=$(_nftban_portscan_detect_mode)

    nftban_log "INFO" "portscan" "Portscan mode: ${_PORTSCAN_ACTIVE_MODE}"

    _PORTSCAN_INITIALIZED=1
    return 0
}

# =============================================================================
# ENABLE/DISABLE
# =============================================================================

# Enable portscan detection
nftban_portscan_enable() {
    nftban_portscan_init

    if [[ "${PORTSCAN_ENABLED:-true}" != "true" ]]; then
        nftban_log "WARN" "portscan" "Portscan is disabled in configuration"
        return 1
    fi

    local mode="${_PORTSCAN_ACTIVE_MODE}"

    nftban_log "INFO" "portscan" "Enabling portscan detection (mode: ${mode})"

    case "$mode" in
        classic)
            if type -t nftban_portscan_classic_enable &>/dev/null; then
                nftban_portscan_classic_enable
            else
                nftban_log "ERROR" "portscan" "Classic mode module not loaded"
                return 1
            fi
            ;;
        suricata)
            if type -t nftban_portscan_suricata_enable &>/dev/null; then
                nftban_portscan_suricata_enable
            else
                nftban_log "ERROR" "portscan" "Suricata mode module not loaded"
                return 1
            fi
            ;;
        hybrid)
            # Enable both modes
            if type -t nftban_portscan_classic_enable &>/dev/null; then
                nftban_portscan_classic_enable
            fi
            if type -t nftban_portscan_suricata_enable &>/dev/null; then
                nftban_portscan_suricata_enable
            fi
            ;;
        *)
            nftban_log "ERROR" "portscan" "Unknown mode: ${mode}"
            return 1
            ;;
    esac

    nftban_log "INFO" "portscan" "Portscan detection enabled successfully"
    return 0
}

# Disable portscan detection
nftban_portscan_disable() {
    local mode="${_PORTSCAN_ACTIVE_MODE}"

    nftban_log "INFO" "portscan" "Disabling portscan detection"

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
    nftban_log "INFO" "portscan" "Portscan detection disabled"
    return 0
}

# =============================================================================
# STATUS
# =============================================================================

# Get portscan detection status
nftban_portscan_status() {
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
    local is_enabled="${PORTSCAN_ENABLED:-true}"
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
        local eve_file="${SURICATA_EVE_LOG:-/var/log/suricata/eve.json}"
        if [[ -f "$eve_file" ]]; then
            local eve_age
            eve_age=$(( $(date +%s) - $(stat -c %Y "$eve_file" 2>/dev/null || echo 0) ))
            if [[ $eve_age -lt 300 ]]; then
                echo "  EVE Log:     ✅ Active (updated ${eve_age}s ago)"
            else
                echo "  EVE Log:     ⚠️  Stale (last update ${eve_age}s ago)"
            fi
        else
            echo "  EVE Log:     ❌ Not found at $eve_file"
        fi
    else
        echo "  Available:   ❌ NO - Suricata not available"
        if ! command -v suricata &>/dev/null; then
            echo "  Reason:      Binary not installed"
            echo "  Install:     nftban setup suricata"
        elif ! systemctl is-active suricata &>/dev/null; then
            echo "  Reason:      Service not running"
            echo "  Start:       systemctl start suricata"
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
    local ban_log="${NFTBAN_BAN_LOG:-/var/log/nftban/bans.log}"
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
    if [[ "${PORTSCAN_ENABLED:-true}" != "true" ]]; then
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
# AUTO-INITIALIZATION
# =============================================================================

# Initialize on source if not in library mode
if [[ "${NFTBAN_LIBRARY_MODE:-0}" != "1" ]]; then
    nftban_portscan_load_config
fi

# =============================================================================
# END OF PORTSCAN MODULE
# =============================================================================
