#!/usr/bin/env bash
# =============================================================================
# NFTBAN FAIL2BAN INTEGRATION MODULE (CORE)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Fail2ban integration for NFTBan - manage jails and sync bans
#
# meta:name=nftban_fail2ban
# meta:type=core
# meta:header=Fail2ban Integration Module
# meta:version=0.30.1
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Integrate fail2ban with NFTBan for jail management and ban synchronization
# meta:input=Configuration from conf.d/fail2ban.conf, fail2ban commands
# meta:output=Fail2ban status, jail management, ban synchronization
#
# **Inventory & Requirements**
# meta:depends=fail2ban-client,systemctl
# meta:requires_env=FAIL2BAN_ENABLED
#
# meta:created_date=2025-10-28
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# PREVENT DOUBLE-LOADING
# =============================================================================
[[ -n "${NFTBAN_FAIL2BAN_LOADED:-}" ]] && return 0
NFTBAN_FAIL2BAN_LOADED="true"

# =============================================================================
# CONFIGURATION
# =============================================================================

# Default paths (only set if not already set)
if [[ -z "${NFTBAN_LIB_DIR:-}" ]]; then
    readonly NFTBAN_LIB_DIR="/usr/lib/nftban"
fi

if [[ -z "${NFTBAN_CONF_DIR:-}" ]]; then
    readonly NFTBAN_CONF_DIR="/etc/nftban"
fi

# Load fail2ban configuration
if [[ -f "${NFTBAN_CONF_DIR}/conf.d/fail2ban.conf" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_CONF_DIR}/conf.d/fail2ban.conf"
fi

# Apply defaults if not set
FAIL2BAN_ENABLED="${FAIL2BAN_ENABLED:-true}"
FAIL2BAN_CLIENT="${FAIL2BAN_CLIENT:-/usr/bin/fail2ban-client}"
FAIL2BAN_SERVICE="${FAIL2BAN_SERVICE:-fail2ban}"
FAIL2BAN_LOG_FILE="${FAIL2BAN_LOG_FILE:-/var/log/nftban/fail2ban.log}"

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Check if fail2ban is installed
nftban_fail2ban_is_installed() {
    command -v fail2ban-client &>/dev/null
}

# Check if fail2ban service is running
nftban_fail2ban_is_running() {
    systemctl is-active --quiet "${FAIL2BAN_SERVICE}" 2>/dev/null
}

# Check if fail2ban is enabled
nftban_fail2ban_is_enabled() {
    [[ "${FAIL2BAN_ENABLED}" == "true" ]]
}

# Log to fail2ban log file
nftban_fail2ban_log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    echo "[${timestamp}] [${level}] ${message}" >> "${FAIL2BAN_LOG_FILE}"
}

# =============================================================================
# STATUS FUNCTIONS
# =============================================================================

# Get fail2ban status
nftban_fail2ban_status() {
    local status="UNKNOWN"
    local version=""

    if ! nftban_fail2ban_is_installed; then
        echo "NOT_INSTALLED"
        return 1
    fi

    if nftban_fail2ban_is_running; then
        status="RUNNING"
        version=$(fail2ban-client version 2>/dev/null || echo "unknown")
    else
        status="STOPPED"
    fi

    echo "${status}"
    return 0
}

# Get fail2ban version
nftban_fail2ban_version() {
    if nftban_fail2ban_is_installed; then
        fail2ban-client version 2>/dev/null || echo "unknown"
    else
        echo "not installed"
    fi
}

# Check fail2ban health
nftban_fail2ban_health() {
    if ! nftban_fail2ban_is_installed; then
        echo "ERROR: fail2ban not installed"
        return 1
    fi

    if ! nftban_fail2ban_is_running; then
        echo "WARNING: fail2ban not running"
        return 2
    fi

    # Try to ping fail2ban
    if fail2ban-client ping &>/dev/null; then
        echo "OK: fail2ban responding"
        return 0
    else
        echo "ERROR: fail2ban not responding"
        return 1
    fi
}

# =============================================================================
# JAIL MANAGEMENT
# =============================================================================

# Detect OS type and version for jail recommendations
nftban_fail2ban_detect_os() {
    local os_type=""
    local os_version=""

    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        os_type="$ID"
        os_version="$VERSION_ID"
    elif [[ -f /etc/redhat-release ]]; then
        os_type="rhel"
        os_version=$(cat /etc/redhat-release | grep -oP '\d+\.\d+' | head -1)
    elif [[ -f /etc/debian_version ]]; then
        os_type="debian"
        os_version=$(cat /etc/debian_version)
    else
        os_type="unknown"
        os_version="unknown"
    fi

    echo "${os_type}:${os_version}"
}

# Discover available NFTBan-compatible jail configurations
# ONLY returns jails configured to use NFTBan's nftables action
nftban_fail2ban_discover_available_jails() {
    local jail_names=()

    # ONLY check NFTBan-specific jails: /etc/fail2ban/jail.d/nftban-*.conf
    # These are the ONLY jails configured with action = nftban[...]
    # System jails (sshd, apache-auth, etc.) use iptables/firewalld and won't work
    if [[ -d /etc/fail2ban/jail.d ]]; then
        while IFS= read -r -d '' file; do
            # Extract jail name from filename: nftban-sshd.conf -> nftban-sshd
            local basename=$(basename "$file" .conf)
            jail_names+=("$basename")
        done < <(find /etc/fail2ban/jail.d -name "nftban-*.conf" -print0 2>/dev/null)
    fi

    # Sort and print unique jail names
    printf '%s\n' "${jail_names[@]}" | sort -u
}

# Get OS-specific recommended jails
nftban_fail2ban_get_recommended_jails() {
    local os_info=$(nftban_fail2ban_detect_os)
    local os_type="${os_info%%:*}"
    local recommended=()

    # Common jails for all systems
    recommended+=("sshd")

    # Detect installed services and recommend appropriate jails
    if systemctl list-unit-files | grep -q "nginx.service"; then
        recommended+=("nginx-http-auth" "nginx-limit-req" "nginx-botsearch")
    fi

    if systemctl list-unit-files | grep -q "apache2.service\|httpd.service"; then
        recommended+=("apache-auth" "apache-badbots" "apache-shellshock")
    fi

    if systemctl list-unit-files | grep -q "postfix.service"; then
        recommended+=("postfix" "postfix-sasl")
    fi

    if systemctl list-unit-files | grep -q "dovecot.service"; then
        recommended+=("dovecot")
    fi

    if systemctl list-unit-files | grep -q "mysql.service\|mariadb.service"; then
        recommended+=("mysqld-auth")
    fi

    if systemctl list-unit-files | grep -q "proftpd.service\|vsftpd.service"; then
        recommended+=("proftpd" "vsftpd")
    fi

    # OS-specific additions
    case "$os_type" in
        debian|ubuntu)
            if dpkg -l | grep -q "roundcube"; then
                recommended+=("roundcube-auth")
            fi
            ;;
        rhel|centos|rocky|almalinux|fedora)
            if rpm -qa | grep -q "roundcubemail"; then
                recommended+=("roundcube-auth")
            fi
            ;;
    esac

    # Print unique recommendations
    printf '%s\n' "${recommended[@]}" | sort -u
}

# List all currently active/enabled jails (dynamic from fail2ban)
nftban_fail2ban_list_jails() {
    if ! nftban_fail2ban_is_running; then
        echo "ERROR: fail2ban not running" >&2
        return 1
    fi

    fail2ban-client status 2>/dev/null | grep "Jail list:" | sed 's/.*Jail list:\s*//' | tr ',' '\n' | tr -d ' \t'
}

# List all available jails (enabled + available but not enabled)
nftban_fail2ban_list_all_available_jails() {
    local available_jails=()
    local enabled_jails=()

    # Get currently enabled jails if fail2ban is running
    if nftban_fail2ban_is_running; then
        mapfile -t enabled_jails < <(nftban_fail2ban_list_jails 2>/dev/null)
    fi

    # Get all available jail configurations
    mapfile -t available_jails < <(nftban_fail2ban_discover_available_jails)

    # Merge and mark status
    local all_jails=()

    # Add enabled jails first (marked as enabled)
    for jail in "${enabled_jails[@]}"; do
        echo "${jail}:enabled"
    done

    # Add available but not enabled jails
    for jail in "${available_jails[@]}"; do
        if [[ ! " ${enabled_jails[*]} " =~ " ${jail} " ]]; then
            echo "${jail}:available"
        fi
    done
}

# Get jail status
nftban_fail2ban_jail_status() {
    local jail="$1"

    if ! nftban_fail2ban_is_running; then
        echo "ERROR: fail2ban not running" >&2
        return 1
    fi

    fail2ban-client status "$jail" 2>/dev/null
}

# Get currently banned IPs for a jail
nftban_fail2ban_jail_banned() {
    local jail="$1"

    if ! nftban_fail2ban_is_running; then
        return 1
    fi

    fail2ban-client status "$jail" 2>/dev/null | grep "Banned IP list:" | sed 's/.*Banned IP list:\s*//' | tr ' ' '\n' | grep -v '^$'
}

# Check if jail is enabled
nftban_fail2ban_jail_is_enabled() {
    local jail="$1"

    if ! nftban_fail2ban_is_running; then
        return 1
    fi

    nftban_fail2ban_list_jails | grep -q "^${jail}$"
}

# Start a jail
nftban_fail2ban_jail_start() {
    local jail="$1"

    if ! nftban_fail2ban_is_running; then
        echo "ERROR: fail2ban not running" >&2
        return 1
    fi

    fail2ban-client start "$jail" 2>/dev/null
    local result=$?

    if [[ $result -eq 0 ]]; then
        nftban_fail2ban_log "INFO" "Started jail: ${jail}"
    else
        nftban_fail2ban_log "ERROR" "Failed to start jail: ${jail}"
    fi

    return $result
}

# Stop a jail
nftban_fail2ban_jail_stop() {
    local jail="$1"

    if ! nftban_fail2ban_is_running; then
        echo "ERROR: fail2ban not running" >&2
        return 1
    fi

    fail2ban-client stop "$jail" 2>/dev/null
    local result=$?

    if [[ $result -eq 0 ]]; then
        nftban_fail2ban_log "INFO" "Stopped jail: ${jail}"
    else
        nftban_fail2ban_log "ERROR" "Failed to stop jail: ${jail}"
    fi

    return $result
}

# Reload a jail
nftban_fail2ban_jail_reload() {
    local jail="$1"

    if ! nftban_fail2ban_is_running; then
        echo "ERROR: fail2ban not running" >&2
        return 1
    fi

    fail2ban-client reload "$jail" 2>/dev/null
    local result=$?

    if [[ $result -eq 0 ]]; then
        nftban_fail2ban_log "INFO" "Reloaded jail: ${jail}"
    else
        nftban_fail2ban_log "ERROR" "Failed to reload jail: ${jail}"
    fi

    return $result
}

# =============================================================================
# BAN MANAGEMENT
# =============================================================================

# Ban an IP in a jail
nftban_fail2ban_ban_ip() {
    local jail="$1"
    local ip="$2"

    if ! nftban_fail2ban_is_running; then
        echo "ERROR: fail2ban not running" >&2
        return 1
    fi

    fail2ban-client set "$jail" banip "$ip" 2>/dev/null
    local result=$?

    if [[ $result -eq 0 ]]; then
        nftban_fail2ban_log "INFO" "Banned IP ${ip} in jail ${jail}"
    else
        nftban_fail2ban_log "ERROR" "Failed to ban IP ${ip} in jail ${jail}"
    fi

    return $result
}

# Unban an IP from a jail
nftban_fail2ban_unban_ip() {
    local jail="$1"
    local ip="$2"

    if ! nftban_fail2ban_is_running; then
        echo "ERROR: fail2ban not running" >&2
        return 1
    fi

    fail2ban-client set "$jail" unbanip "$ip" 2>/dev/null
    local result=$?

    if [[ $result -eq 0 ]]; then
        nftban_fail2ban_log "INFO" "Unbanned IP ${ip} from jail ${jail}"
    else
        nftban_fail2ban_log "ERROR" "Failed to unban IP ${ip} from jail ${jail}"
    fi

    return $result
}

# Get total banned IPs across all jails
nftban_fail2ban_total_banned() {
    local total=0
    local jails

    if ! nftban_fail2ban_is_running; then
        echo "0"
        return 0
    fi

    mapfile -t jails < <(nftban_fail2ban_list_jails)

    for jail in "${jails[@]}"; do
        local count
        count=$(nftban_fail2ban_jail_banned "$jail" | wc -l)
        total=$((total + count))
    done

    echo "$total"
}

# =============================================================================
# CLOUDFLARE INTEGRATION
# =============================================================================

# Update Cloudflare whitelist in fail2ban
nftban_fail2ban_update_cloudflare_whitelist() {
    if [[ "${FAIL2BAN_CLOUDFLARE_WHITELIST}" != "true" ]]; then
        return 0
    fi

    # Check if Cloudflare module is available
    if [[ ! $(type -t nftban_cloudflare_get_ips) == "function" ]]; then
        if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_cloudflare.sh" ]]; then
            # shellcheck source=/dev/null
            source "${NFTBAN_LIB_DIR}/core/nftban_cloudflare.sh"
        else
            echo "WARNING: Cloudflare module not available" >&2
            return 1
        fi
    fi

    local whitelist_file="${FAIL2BAN_CLOUDFLARE_WHITELIST_FILE}"
    local cf_ips

    # Get Cloudflare IPs
    cf_ips=$(nftban_cloudflare_get_ips 2>/dev/null)

    if [[ -z "$cf_ips" ]]; then
        echo "WARNING: Could not retrieve Cloudflare IPs" >&2
        return 1
    fi

    # Create whitelist configuration
    {
        echo "# Cloudflare IP Whitelist - Auto-generated by NFTBan"
        echo "# Generated: $(date)"
        echo "#"
        echo "# These IPs are whitelisted to prevent blocking Cloudflare proxy"
        echo ""
        echo "[Init]"
        echo ""
        echo "ignoreip = $(echo "$cf_ips" | tr '\n' ' ')"
    } > "$whitelist_file"

    nftban_fail2ban_log "INFO" "Updated Cloudflare whitelist in fail2ban"

    # Reload fail2ban if configured
    if [[ "${FAIL2BAN_AUTO_RELOAD}" == "true" ]]; then
        fail2ban-client reload >/dev/null 2>&1
        nftban_fail2ban_log "INFO" "Reloaded fail2ban configuration"
    fi

    return 0
}

# =============================================================================
# SERVICE MANAGEMENT
# =============================================================================

# Start fail2ban service
nftban_fail2ban_start() {
    if nftban_fail2ban_is_running; then
        echo "fail2ban is already running"
        return 0
    fi

    systemctl start "${FAIL2BAN_SERVICE}" 2>&1
    local result=$?

    if [[ $result -eq 0 ]]; then
        nftban_fail2ban_log "INFO" "Started fail2ban service"
        echo "✓ fail2ban started successfully"
    else
        nftban_fail2ban_log "ERROR" "Failed to start fail2ban service"
        echo "ERROR: Failed to start fail2ban" >&2
    fi

    return $result
}

# Stop fail2ban service
nftban_fail2ban_stop() {
    if ! nftban_fail2ban_is_running; then
        echo "fail2ban is not running"
        return 0
    fi

    systemctl stop "${FAIL2BAN_SERVICE}" 2>&1
    local result=$?

    if [[ $result -eq 0 ]]; then
        nftban_fail2ban_log "INFO" "Stopped fail2ban service"
        echo "✓ fail2ban stopped successfully"
    else
        nftban_fail2ban_log "ERROR" "Failed to stop fail2ban service"
        echo "ERROR: Failed to stop fail2ban" >&2
    fi

    return $result
}

# Restart fail2ban service
nftban_fail2ban_restart() {
    systemctl restart "${FAIL2BAN_SERVICE}" 2>&1
    local result=$?

    if [[ $result -eq 0 ]]; then
        nftban_fail2ban_log "INFO" "Restarted fail2ban service"
        echo "✓ fail2ban restarted successfully"
    else
        nftban_fail2ban_log "ERROR" "Failed to restart fail2ban service"
        echo "ERROR: Failed to restart fail2ban" >&2
    fi

    return $result
}

# Reload fail2ban configuration
nftban_fail2ban_reload() {
    if ! nftban_fail2ban_is_running; then
        echo "ERROR: fail2ban not running" >&2
        return 1
    fi

    fail2ban-client reload 2>/dev/null
    local result=$?

    if [[ $result -eq 0 ]]; then
        nftban_fail2ban_log "INFO" "Reloaded fail2ban configuration"
        echo "✓ fail2ban configuration reloaded"
    else
        nftban_fail2ban_log "ERROR" "Failed to reload fail2ban configuration"
        echo "ERROR: Failed to reload fail2ban" >&2
    fi

    return $result
}

# =============================================================================
# FOOTER
# =============================================================================

if [[ "${NFTBAN_DEBUG_MODE:-false}" == "true" ]]; then
    nftban_module_loaded "nftban_fail2ban" "1.0.0" "Fail2ban Integration Module" "core" "fail2ban-client,systemctl"
fi

return 0 2>/dev/null || :
