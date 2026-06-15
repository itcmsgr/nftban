#!/usr/bin/env bash
# shellcheck disable=SC1090  # Dynamic config paths, cannot follow
# =============================================================================
# NFTBan - Login Monitor Module (Dual-Mode Controller)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Master controller for login monitoring with dual-mode support
#
# meta:name="nftban_login"
# meta:type="core"
# meta:header="Login Monitor"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Monitors login attempts and auto-bans attackers (replaces fail2ban)"
# meta:input="Configuration from /etc/nftban/conf.d/login/"
# meta:output="Login alerts and ban actions"
#
# meta:inventory.files=""
# meta:inventory.binaries="journalctl"
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/conf.d/login/main.conf"
# meta:inventory.systemd_units="nftban-login-monitor.service"
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# meta:created_date="2025-12-01"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# =============================================================================
# MODULE GUARD
# =============================================================================

[[ -n "${NFTBAN_LOGIN_LOADED:-}" ]] && return 0
readonly NFTBAN_LOGIN_LOADED=1

# =============================================================================
# MODULE METADATA
# =============================================================================

# shellcheck disable=SC2034  # Module metadata used when sourced
readonly LOGIN_MODULE_NAME="nftban_login"
# shellcheck disable=SC2034  # Module metadata used when sourced
readonly LOGIN_MODULE_VERSION="1.0.0"
# shellcheck disable=SC2034  # Module metadata used when sourced
readonly LOGIN_MODULE_TYPE="core"
# shellcheck disable=SC2034  # Module metadata used when sourced
readonly LOGIN_MODULE_DESCRIPTION="Login Monitor Module (Dual-Mode)"

# =============================================================================
# LOAD MAIN CONFIG FOR NFTBAN_BIN AND OTHER PATHS
# =============================================================================

# Source main nftban.conf for NFTBAN_BIN, NFTBAN_CONFIG_DIR, etc.
# This MUST be sourced before using these variables
if [[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" ]]; then
    # shellcheck source=/etc/nftban/nftban.conf
    source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" || true
fi
source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf.local" 2>/dev/null || true

# =============================================================================
# FHS COMPLIANT PATHS (uses central config from nftban.conf)
# =============================================================================

readonly NFTBAN_LOGIN_CONFIG_DIR="${NFTBAN_CONFIG_DIR}/conf.d/login"
readonly NFTBAN_LOGIN_DATA_DIR="${LOGIN_DATA_DIR:-${NFTBAN_DATA_DIR}/login}"
readonly NFTBAN_LOGIN_CACHE_DIR="${LOGIN_CACHE_DIR:-${NFTBAN_CACHE_DIR}/login}"
readonly NFTBAN_LOGIN_LOG_FILE="${LOGIN_LOG_FILE:-${NFTBAN_LOG_DIR}/login-monitor.log}"

# =============================================================================
# RUNTIME STATE
# =============================================================================

declare -g _LOGIN_ACTIVE_MODE=""          # Currently active mode
declare -g _LOGIN_INITIALIZED=0           # Initialization flag
declare -gA _LOGIN_DETECTED_SERVICES=()   # Services detected on system

# =============================================================================
# BANNER FUNCTION
# =============================================================================

nftban_login_banner() {
    cat <<'BANNER'
╔═══════════════════════════════════════════════════════════════════════════╗
║  🔐 Login Monitor (v1.0 Dual-Mode)                                        ║
║  NFTBan — Open-source Linux IPS and nftables firewall manager             ║
╚═══════════════════════════════════════════════════════════════════════════╝
BANNER
}

# =============================================================================
# CONFIGURATION LOADING
# =============================================================================

# Load main login configuration
nftban_login_load_config() {
    local config_dir="${NFTBAN_LOGIN_CONFIG_DIR}"

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
    : "${LOGIN_ENABLED:=true}"
    : "${LOGIN_MODE:=auto}"
    : "${LOGIN_AUTO_CHECK_SERVICE:=true}"
    : "${LOGIN_AUTO_CHECK_BINARY:=true}"
    : "${LOGIN_AUTO_CHECK_EVE_FILE:=true}"
    : "${LOGIN_SURICATA_SERVICE_NAME:=suricata}"
    : "${LOGIN_SURICATA_BINARY:=/usr/bin/suricata}"
    : "${LOGIN_EVE_FRESHNESS_THRESHOLD:=60}"
    : "${LOGIN_AUTO_DETECT_SERVICES:=true}"
    : "${LOGIN_ACTION_MODE:=both}"
    : "${LOGIN_BAN_COMMAND:=${NFTBAN_BIN:-/usr/sbin/nftban} ban}"
    : "${LOGIN_DEFAULT_BAN_DURATION:=3600}"

    return 0
}

# Load mode-specific configuration
nftban_login_load_mode_config() {
    local mode="$1"
    local config_dir="${NFTBAN_LOGIN_CONFIG_DIR}"

    case "$mode" in
        classic)
            local classic_config="${config_dir}/classic.conf"
            local classic_local="${config_dir}/classic.conf.local"

            source "$classic_config" 2>/dev/null || true
            source "$classic_local" 2>/dev/null || true
            ;;
        suricata)
            local suricata_config="${config_dir}/suricata.conf"
            local suricata_local="${config_dir}/suricata.conf.local"

            source "$suricata_config" 2>/dev/null || true
            source "$suricata_local" 2>/dev/null || true
            ;;
        hybrid)
            # Load both
            nftban_login_load_mode_config "classic"
            nftban_login_load_mode_config "suricata"
            ;;
    esac

    # Load services configuration
    local services_config="${config_dir}/services.conf"
    local services_local="${config_dir}/services.conf.local"

    source "$services_config" 2>/dev/null || true
    source "$services_local" 2>/dev/null || true

    return 0
}

# =============================================================================
# MODE DETECTION
# =============================================================================

# Check if Suricata binary exists
_nftban_login_suricata_binary_exists() {
    local binary="${LOGIN_SURICATA_BINARY:-/usr/bin/suricata}"
    [[ -x "$binary" ]]
}

# Check if Suricata service is running
_nftban_login_suricata_service_running() {
    local service_name="${LOGIN_SURICATA_SERVICE_NAME:-suricata}"

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

# Check if EVE JSON file exists and is fresh
_nftban_login_eve_file_fresh() {
    local eve_file="${LOGIN_SURICATA_EVE_FILE:-/var/log/nftban/suricata/eve-alerts.json}"
    local threshold="${LOGIN_EVE_FRESHNESS_THRESHOLD:-60}"

    if [[ ! -f "$eve_file" ]]; then
        return 1
    fi

    local file_mtime
    # Use -L to follow symlinks (eve-alerts.json -> eve.json)
    file_mtime=$(stat -L -c %Y "$eve_file" 2>/dev/null) || return 1
    local now
    now=$(date +%s)
    local age
    age=$((now - file_mtime))

    [[ $age -lt $threshold ]]
}

# Detect if Suricata is available for login monitoring
nftban_login_suricata_available() {
    local score=0

    # v1.19.20 FIX: Added || true to prevent set -e failures
    if [[ "${LOGIN_AUTO_CHECK_BINARY:-true}" == "true" ]]; then
        _nftban_login_suricata_binary_exists && { ((score++)) || true; }
    fi

    if [[ "${LOGIN_AUTO_CHECK_SERVICE:-true}" == "true" ]]; then
        _nftban_login_suricata_service_running && { ((score++)) || true; }
    fi

    if [[ "${LOGIN_AUTO_CHECK_EVE_FILE:-true}" == "true" ]]; then
        _nftban_login_eve_file_fresh && { ((score++)) || true; }
    fi

    # Need at least 2 checks to pass
    [[ $score -ge 2 ]]
}

# Determine which mode to use
nftban_login_detect_mode() {
    local configured_mode="${LOGIN_MODE:-auto}"

    case "$configured_mode" in
        classic)
            echo "classic"
            ;;
        suricata)
            # Force Suricata mode - fail if not available
            if nftban_login_suricata_available; then
                echo "suricata"
            else
                nftban_login_log "ERROR" "Suricata mode forced but Suricata not available"
                return 1
            fi
            ;;
        hybrid)
            echo "hybrid"
            ;;
        auto|*)
            # Auto-detect: prefer Suricata if available
            if nftban_login_suricata_available; then
                echo "suricata"
            else
                echo "classic"
            fi
            ;;
    esac
}

# =============================================================================
# SERVICE DETECTION
# =============================================================================

# Detect installed services that we can monitor
nftban_login_detect_services() {
    _LOGIN_DETECTED_SERVICES=()

    # SSH - always check
    if _nftban_login_service_exists "sshd" || _nftban_login_service_exists "ssh"; then
        _LOGIN_DETECTED_SERVICES[ssh]=1
    fi

    # Dovecot
    if _nftban_login_service_exists "dovecot"; then
        _LOGIN_DETECTED_SERVICES[dovecot]=1
    fi

    # Exim
    if _nftban_login_service_exists "exim" || _nftban_login_service_exists "exim4"; then
        _LOGIN_DETECTED_SERVICES[exim]=1
    fi

    # Postfix
    if _nftban_login_service_exists "postfix"; then
        _LOGIN_DETECTED_SERVICES[postfix]=1
    fi

    # Pure-FTPd
    if _nftban_login_service_exists "pure-ftpd"; then
        _LOGIN_DETECTED_SERVICES[pureftpd]=1
    fi

    # vsftpd
    if _nftban_login_service_exists "vsftpd"; then
        _LOGIN_DETECTED_SERVICES[vsftpd]=1
    fi

    # ProFTPD
    if _nftban_login_service_exists "proftpd"; then
        _LOGIN_DETECTED_SERVICES[proftpd]=1
    fi

    # Apache
    if _nftban_login_service_exists "apache2" || _nftban_login_service_exists "httpd"; then
        _LOGIN_DETECTED_SERVICES[apache]=1
    fi

    # Nginx
    if _nftban_login_service_exists "nginx"; then
        _LOGIN_DETECTED_SERVICES[nginx]=1
    fi

    # DirectAdmin
    if [[ -d "/usr/local/directadmin" ]]; then
        _LOGIN_DETECTED_SERVICES[directadmin]=1
    fi

    # cPanel/WHM
    if [[ -d "/usr/local/cpanel" ]]; then
        _LOGIN_DETECTED_SERVICES[cpanel]=1
    fi

    # Plesk
    if [[ -d "/usr/local/psa" ]] || [[ -d "/opt/psa" ]]; then
        _LOGIN_DETECTED_SERVICES[plesk]=1
    fi

    # WordPress - check if Apache/Nginx is running and wp-config.php exists somewhere
    if [[ -n "${_LOGIN_DETECTED_SERVICES[apache]:-}" ]] || [[ -n "${_LOGIN_DETECTED_SERVICES[nginx]:-}" ]]; then
        if find /var/www -name "wp-config.php" -type f 2>/dev/null | head -1 | grep -q .; then
            _LOGIN_DETECTED_SERVICES[wordpress]=1
            _LOGIN_DETECTED_SERVICES[xmlrpc]=1
        fi
    fi

    # Roundcube
    if [[ -d "/usr/share/roundcubemail" ]] || [[ -d "/var/lib/roundcube" ]]; then
        _LOGIN_DETECTED_SERVICES[roundcube]=1
    fi
}

# Check if a service exists (distro-agnostic: Debian + RPM)
_nftban_login_service_exists() {
    local service="$1"

    # Method 1: systemctl show (most robust - asks systemd if it knows the unit)
    if command -v systemctl &>/dev/null; then
        local load_state
        load_state=$(systemctl show "${service}.service" --property=LoadState 2>/dev/null | cut -d= -f2)
        if [[ "$load_state" == "loaded" ]]; then
            return 0
        fi
        # Fallback: check list-units for active/registered services
        if systemctl list-units --full --all 2>/dev/null | grep -Fq "${service}.service"; then
            return 0
        fi
    fi

    # Check SysV init
    [[ -f "/etc/init.d/$service" ]] && return 0

    # Check binary exists (fallback for non-systemd or manual installs)
    command -v "$service" &>/dev/null && return 0
    [[ -x "/usr/sbin/$service" ]] && return 0
    [[ -x "/usr/bin/$service" ]] && return 0

    return 1
}

# Get list of detected services
nftban_login_get_detected_services() {
    echo "${!_LOGIN_DETECTED_SERVICES[@]}"
}

# Check if a specific service is detected
nftban_login_service_detected() {
    local service="$1"
    [[ -n "${_LOGIN_DETECTED_SERVICES[$service]:-}" ]]
}

# =============================================================================
# LOGGING
# =============================================================================

nftban_login_log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Ensure log directory exists
    mkdir -p "$(dirname "$NFTBAN_LOGIN_LOG_FILE")" || return 1

    # Log to file
    echo "[$timestamp] [$level] $message" >> "$NFTBAN_LOGIN_LOG_FILE"

    # Log to syslog (suppress errors if /dev/log unavailable in sandboxed service)
    logger -t "nftban-login" -p "auth.$level" "$message" 2>/dev/null || true
}

# =============================================================================
# INITIALIZATION
# =============================================================================

# Initialize the login monitor
nftban_login_init() {
    [[ $_LOGIN_INITIALIZED -eq 1 ]] && return 0

    nftban_login_log "INFO" "Initializing login monitor..."

    # Load configuration
    nftban_login_load_config

    # Check if enabled
    if [[ "${LOGIN_ENABLED:-true}" != "true" ]]; then
        nftban_login_log "INFO" "Login monitor is disabled in configuration"
        return 0
    fi

    # Detect mode
    _LOGIN_ACTIVE_MODE=$(nftban_login_detect_mode) || return 1
    nftban_login_log "INFO" "Selected mode: $_LOGIN_ACTIVE_MODE"

    # Load mode-specific configuration
    nftban_login_load_mode_config "$_LOGIN_ACTIVE_MODE"

    # Detect services
    if [[ "${LOGIN_AUTO_DETECT_SERVICES:-true}" == "true" ]]; then
        nftban_login_detect_services
        local services
        services=$(nftban_login_get_detected_services)
        nftban_login_log "INFO" "Detected services: $services"
    fi

    # Ensure directories exist
    mkdir -p "$NFTBAN_LOGIN_DATA_DIR" "$NFTBAN_LOGIN_CACHE_DIR" || return 1

    # Load the appropriate module
    local lib_dir="${NFTBAN_LIB_DIR:-/usr/lib/nftban}"

    case "$_LOGIN_ACTIVE_MODE" in
        classic)
            if [[ -f "${lib_dir}/core/nftban_login_classic.sh" ]]; then
                source "${lib_dir}/core/nftban_login_classic.sh" || return 1
                nftban_login_classic_init
            else
                nftban_login_log "ERROR" "Classic module not found"
                return 1
            fi
            ;;
        suricata)
            if [[ -f "${lib_dir}/core/nftban_login_suricata.sh" ]]; then
                source "${lib_dir}/core/nftban_login_suricata.sh" || return 1
                nftban_login_suricata_init
            else
                nftban_login_log "ERROR" "Suricata module not found"
                return 1
            fi
            ;;
        hybrid)
            # Load both modules
            if [[ -f "${lib_dir}/core/nftban_login_classic.sh" ]]; then
                source "${lib_dir}/core/nftban_login_classic.sh" || return 1
                nftban_login_classic_init
            fi
            if [[ -f "${lib_dir}/core/nftban_login_suricata.sh" ]]; then
                source "${lib_dir}/core/nftban_login_suricata.sh" || return 1
                nftban_login_suricata_init
            fi
            ;;
    esac

    _LOGIN_INITIALIZED=1
    nftban_login_log "INFO" "Login monitor initialized successfully"
    return 0
}

# =============================================================================
# MAIN OPERATIONS
# =============================================================================

# Start monitoring
nftban_login_start() {
    nftban_login_init || return 1

    if [[ "${LOGIN_ENABLED:-true}" != "true" ]]; then
        echo "Login monitor is disabled"
        return 0
    fi

    nftban_login_banner
    echo "Mode: $_LOGIN_ACTIVE_MODE"
    echo "Services: $(nftban_login_get_detected_services)"
    echo ""

    nftban_login_log "INFO" "Starting login monitor in $_LOGIN_ACTIVE_MODE mode"

    case "$_LOGIN_ACTIVE_MODE" in
        classic)
            nftban_login_classic_start
            ;;
        suricata)
            nftban_login_suricata_start
            ;;
        hybrid)
            # Start both in background
            nftban_login_classic_start &
            local classic_pid=$!
            nftban_login_suricata_start &
            local suricata_pid=$!

            # Wait for both
            wait $classic_pid $suricata_pid
            ;;
    esac
}

# Stop monitoring
nftban_login_stop() {
    nftban_login_log "INFO" "Stopping login monitor"

    case "$_LOGIN_ACTIVE_MODE" in
        classic)
            nftban_login_classic_stop 2>/dev/null
            ;;
        suricata)
            nftban_login_suricata_stop 2>/dev/null
            ;;
        hybrid)
            nftban_login_classic_stop 2>/dev/null
            nftban_login_suricata_stop 2>/dev/null
            ;;
    esac

    return 0
}

# Get status
nftban_login_status() {
    nftban_login_init || return 1

    nftban_login_banner

    echo "=== Login Monitor Status ==="
    echo ""
    echo "Enabled:  ${LOGIN_ENABLED:-true}"
    echo "Mode:     $_LOGIN_ACTIVE_MODE"
    echo "Action:   ${LOGIN_ACTION_MODE:-both}"
    echo ""

    echo "=== Suricata Availability ==="
    echo -n "Binary:   "
    _nftban_login_suricata_binary_exists && echo "✓ Found" || echo "✗ Not found"
    echo -n "Service:  "
    _nftban_login_suricata_service_running && echo "✓ Running" || echo "✗ Not running"
    echo -n "EVE File: "
    _nftban_login_eve_file_fresh && echo "✓ Fresh" || echo "✗ Stale/Missing"
    echo ""

    echo "=== Detected Services ==="
    for service in $(nftban_login_get_detected_services); do
        local enabled_var="LOGIN_SERVICE_${service^^}_ENABLED"
        local enabled="${!enabled_var:-true}"
        local status="enabled"
        [[ "$enabled" != "true" ]] && status="disabled"
        echo "  $service: $status"
    done
    echo ""

    # Mode-specific status
    case "$_LOGIN_ACTIVE_MODE" in
        classic)
            if declare -f nftban_login_classic_status &>/dev/null; then
                nftban_login_classic_status
            fi
            ;;
        suricata)
            if declare -f nftban_login_suricata_status &>/dev/null; then
                nftban_login_suricata_status
            fi
            ;;
        hybrid)
            echo "=== Classic Mode Status ==="
            declare -f nftban_login_classic_status &>/dev/null && nftban_login_classic_status
            echo ""
            echo "=== Suricata Mode Status ==="
            declare -f nftban_login_suricata_status &>/dev/null && nftban_login_suricata_status
            ;;
    esac

    return 0
}

# Enable login monitoring
nftban_login_enable() {
    nftban_login_init || return 1

    nftban_login_log "INFO" "Enabling login monitor"

    case "$_LOGIN_ACTIVE_MODE" in
        classic)
            nftban_login_classic_enable
            ;;
        suricata)
            nftban_login_suricata_enable
            ;;
        hybrid)
            nftban_login_classic_enable
            nftban_login_suricata_enable
            ;;
    esac

    echo "Login monitor enabled in $_LOGIN_ACTIVE_MODE mode"
    return 0
}

# Disable login monitoring
nftban_login_disable() {
    nftban_login_log "INFO" "Disabling login monitor"

    case "$_LOGIN_ACTIVE_MODE" in
        classic)
            nftban_login_classic_disable 2>/dev/null
            ;;
        suricata)
            nftban_login_suricata_disable 2>/dev/null
            ;;
        hybrid)
            nftban_login_classic_disable 2>/dev/null
            nftban_login_suricata_disable 2>/dev/null
            ;;
    esac

    echo "Login monitor disabled"
    return 0
}

# =============================================================================
# BAN OPERATIONS
# =============================================================================

# Ban an IP for login failures
nftban_login_ban() {
    local ip="$1"
    local reason="${2:-login_brute_force}"
    local duration="${3:-${LOGIN_DEFAULT_BAN_DURATION:-3600}}"
    local service="${4:-unknown}"

    # v1.18.7: Check whitelist BEFORE banning - never ban whitelisted IPs
    local whitelist_set
    if [[ "$ip" =~ : ]]; then
        whitelist_set="ip6 nftban whitelist_ipv6"
    else
        whitelist_set="ip nftban whitelist_ipv4"
    fi
    if nft get element ${whitelist_set} "{ $ip }" &>/dev/null; then
        nftban_login_log "INFO" "Skipping ban for whitelisted IP: $ip"
        return 0
    fi

    if [[ "${LOGIN_ACTION_MODE:-both}" == "alert" ]]; then
        nftban_login_log "INFO" "Would ban $ip (alert-only mode)"
        return 0
    fi

    nftban_login_log "INFO" "Banning $ip for $duration seconds (service: $service, reason: $reason)"

    # Use nftban ban command
    local ban_cmd="${LOGIN_BAN_COMMAND:-${NFTBAN_BIN:-/usr/sbin/nftban} ban}"

    if $ban_cmd "$ip" --timeout "$duration" --reason "${LOGIN_BAN_REASON_PREFIX:-login-monitor}:${reason}" --source "$service" 2>/dev/null; then
        nftban_login_log "INFO" "Successfully banned $ip"
        return 0
    else
        nftban_login_log "ERROR" "Failed to ban $ip"
        return 1
    fi
}

# =============================================================================
# CLI INTERFACE
# =============================================================================

# Main entry point for CLI
nftban_login_main() {
    local cmd="${1:-status}"
    shift || true

    case "$cmd" in
        start)
            nftban_login_start "$@"
            ;;
        stop)
            nftban_login_stop "$@"
            ;;
        status)
            nftban_login_status "$@"
            ;;
        enable)
            nftban_login_enable "$@"
            ;;
        disable)
            nftban_login_disable "$@"
            ;;
        services)
            nftban_login_init
            echo "Detected services:"
            for service in $(nftban_login_get_detected_services); do
                echo "  - $service"
            done
            ;;
        test)
            nftban_login_test "$@"
            ;;
        help|--help|-h)
            nftban_login_help
            ;;
        *)
            echo "Unknown command: $cmd"
            nftban_login_help
            return 1
            ;;
    esac
}

# Help message
nftban_login_help() {
    cat <<'HELP'
NFTBan Login Monitor - Dual-Mode (Classic/Suricata)

USAGE:
    nftban login <command> [options]

COMMANDS:
    status      Show login monitor status (default)
    start       Start login monitoring
    stop        Stop login monitoring
    enable      Enable login protection
    disable     Disable login protection
    services    List detected services
    test        Test login alert system
    help        Show this help message

MODES:
    auto        Auto-detect Suricata, fallback to Classic
    classic     Force journalctl/log parsing mode
    suricata    Force Suricata EVE JSON mode
    hybrid      Use both for maximum detection

CONFIGURATION:
    /etc/nftban/conf.d/login/main.conf      Main configuration
    /etc/nftban/conf.d/login/classic.conf   Classic mode settings
    /etc/nftban/conf.d/login/suricata.conf  Suricata mode settings
    /etc/nftban/conf.d/login/services.conf  Per-service settings

EXAMPLES:
    nftban login status
    nftban login start
    nftban login services

HELP
}

# Test function
nftban_login_test() {
    nftban_login_init || return 1

    echo "Testing NFTBan Login Monitor"
    echo "============================"
    echo ""

    echo "Configuration:"
    echo "  Enabled: ${LOGIN_ENABLED:-true}"
    echo "  Mode: $_LOGIN_ACTIVE_MODE"
    echo "  Action: ${LOGIN_ACTION_MODE:-both}"
    echo ""

    echo "Detected Services:"
    for service in $(nftban_login_get_detected_services); do
        echo "  ✓ $service"
    done
    echo ""

    # Test mode-specific
    case "$_LOGIN_ACTIVE_MODE" in
        classic)
            declare -f nftban_login_classic_test &>/dev/null && nftban_login_classic_test
            ;;
        suricata)
            declare -f nftban_login_suricata_test &>/dev/null && nftban_login_suricata_test
            ;;
    esac

    echo "✓ Test complete"
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_login_banner
export -f nftban_login_load_config
export -f nftban_login_load_mode_config
export -f nftban_login_suricata_available
export -f nftban_login_detect_mode
export -f nftban_login_detect_services
export -f nftban_login_get_detected_services
export -f nftban_login_service_detected
export -f nftban_login_log
export -f nftban_login_init
export -f nftban_login_start
export -f nftban_login_stop
export -f nftban_login_status
export -f nftban_login_enable
export -f nftban_login_disable
export -f nftban_login_ban
export -f nftban_login_main
export -f nftban_login_help
export -f nftban_login_test
