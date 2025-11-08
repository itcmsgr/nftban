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
# meta:version=0.32.6
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
# meta:created_date=2025-11-05
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
            local basename
            basename=$(basename "$file" .conf)
            jail_names+=("$basename")
        done < <(find /etc/fail2ban/jail.d -name "nftban-*.conf" -print0 2>/dev/null)
    fi

    # Sort and print unique jail names
    printf '%s\n' "${jail_names[@]}" | sort -u
}

# Get OS-specific recommended jails
nftban_fail2ban_get_recommended_jails() {
    local os_info
    os_info=$(nftban_fail2ban_detect_os)
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

    # Use command substitution to avoid SIGPIPE with pipefail
    local status_output jail_line
    status_output=$(fail2ban-client status 2>/dev/null) || true
    jail_line=$(echo "$status_output" | grep "Jail list:" || true)
    echo "$jail_line" | sed 's/.*Jail list:\s*//' | tr ',' '\n' | tr -d ' \t'
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

    # Use command substitution to avoid SIGPIPE with pipefail
    local jail_status banned_line
    jail_status=$(fail2ban-client status "$jail" 2>/dev/null) || return 0
    banned_line=$(echo "$jail_status" | grep "Banned IP list:" || true)
    echo "$banned_line" | sed 's/.*Banned IP list:\s*//' | tr ' ' '\n' | grep -v '^$' || true
}

# Check if jail is enabled
nftban_fail2ban_jail_is_enabled() {
    local jail="$1"

    if ! nftban_fail2ban_is_running; then
        return 1
    fi

    nftban_fail2ban_list_jails | grep -q "^${jail}$"
}

# Check if jail requirements are met (service installed, log file exists)
nftban_fail2ban_jail_check_requirements() {
    local jail_name="$1"
    local warnings=()
    local errors=()

    # Read jail config to get logpath
    local jail_config="/etc/fail2ban/jail.d/${jail_name}.conf"
    if [[ ! -f "$jail_config" ]]; then
        echo "ERROR:Config file not found"
        return 1
    fi

    # Check based on jail type
    case "$jail_name" in
        nftban-sshd)
            # SSH always available
            ;;
        nftban-directadmin)
            if ! command -v directadmin &>/dev/null && [[ ! -d /usr/local/directadmin ]]; then
                errors+=("DirectAdmin is not installed")
            fi
            if [[ ! -f /var/log/directadmin/login.log ]]; then
                errors+=("DirectAdmin log not found: /var/log/directadmin/login.log")
            fi
            ;;
        nftban-exim|nftban-exim-spam)
            if ! command -v exim &>/dev/null; then
                errors+=("Exim is not installed")
            fi
            if [[ ! -f /var/log/exim/mainlog ]]; then
                errors+=("Exim log not found: /var/log/exim/mainlog")
            fi
            ;;
        nftban-dovecot)
            # Use command substitution to avoid SIGPIPE with pipefail
            local unit_files
            unit_files=$(systemctl list-unit-files 2>/dev/null) || true
            if ! echo "$unit_files" | grep -q "dovecot.service"; then
                errors+=("Dovecot is not installed")
            fi
            if [[ ! -f /var/log/maillog ]] && [[ ! -f /var/log/mail.log ]]; then
                errors+=("Mail log not found (checked: /var/log/maillog, /var/log/mail.log)")
            fi
            ;;
        nftban-apache-*|nftban-modsecurity)
            # Use command substitution to avoid SIGPIPE with pipefail
            local unit_files
            unit_files=$(systemctl list-unit-files 2>/dev/null) || true
            if ! echo "$unit_files" | grep -qE "httpd.service|apache2.service"; then
                errors+=("Apache/httpd is not installed")
            fi
            # Check for any httpd log directory
            if [[ ! -d /var/log/httpd ]] && [[ ! -d /var/log/apache2 ]]; then
                errors+=("Apache log directory not found (checked: /var/log/httpd, /var/log/apache2)")
            fi
            ;;
        nftban-pure-ftpd)
            # Use command substitution to avoid SIGPIPE with pipefail
            local unit_files
            unit_files=$(systemctl list-unit-files 2>/dev/null) || true
            if ! echo "$unit_files" | grep -q "pure-ftpd.service"; then
                errors+=("Pure-FTPd is not installed")
            fi
            ;;
        nftban-roundcube)
            if [[ ! -d /var/www/html/roundcube ]] && [[ ! -d /usr/share/roundcube ]]; then
                errors+=("Roundcube is not installed")
            fi
            ;;
    esac

    # CRITICAL: Validate logpath patterns actually match files
    # This prevents fail2ban from crashing with "Have not found any log file" error
    local found_files=0
    local logpath_patterns=()

    # Parse multiline logpath - extract all lines starting with logpath or continuation (whitespace)
    local in_logpath=false
    while IFS= read -r line; do
        # Start of logpath section
        if [[ "$line" =~ ^[[:space:]]*logpath[[:space:]]*= ]]; then
            in_logpath=true
            # Extract value after =
            pattern=$(echo "$line" | sed 's/.*=\s*//' | sed 's/^\s*//' | sed 's/\s*$//')
            [[ -n "$pattern" ]] && logpath_patterns+=("$pattern")
        # Continuation line (starts with whitespace, not a new directive)
        elif [[ $in_logpath == true ]] && [[ "$line" =~ ^[[:space:]]+[^#] ]] && [[ ! "$line" =~ ^[[:space:]]*[a-z]+[[:space:]]*= ]]; then
            pattern=$(echo "$line" | sed 's/^\s*//' | sed 's/\s*$//')
            [[ -n "$pattern" ]] && logpath_patterns+=("$pattern")
        # New directive or comment - stop continuation
        elif [[ "$line" =~ ^[[:space:]]*[a-z]+[[:space:]]*= ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
            in_logpath=false
        fi
    done < "$jail_config"

    # Test each logpath pattern for matching files
    if [[ ${#logpath_patterns[@]} -gt 0 ]]; then
        for pattern in "${logpath_patterns[@]}"; do
            # Use compgen to test if glob pattern matches any files
            if compgen -G "$pattern" >/dev/null 2>&1; then
                ((found_files++))
            fi
        done

        # Error if ZERO files matched ANY pattern
        if [[ $found_files -eq 0 ]]; then
            errors+=("No log files match jail logpath patterns (checked ${#logpath_patterns[@]} patterns)")
            errors+=("Jail would cause fail2ban to crash with 'Have not found any log file' error")
        fi
    fi

    # Print results
    if [[ ${#errors[@]} -gt 0 ]]; then
        for err in "${errors[@]}"; do
            echo "ERROR:$err"
        done
        return 1
    fi

    if [[ ${#warnings[@]} -gt 0 ]]; then
        for warn in "${warnings[@]}"; do
            echo "WARNING:$warn"
        done
    fi

    return 0
}

# Start a jail (PERMANENTLY - modifies config file)
nftban_fail2ban_jail_start() {
    local jail_input="$1"
    local jail_name
    local force="${2:-false}"

    # Auto-prefix with nftban- if not already prefixed
    if [[ "$jail_input" == nftban-* ]]; then
        jail_name="$jail_input"
    else
        jail_name="nftban-${jail_input}"
    fi

    if ! nftban_fail2ban_is_running; then
        echo "ERROR: fail2ban not running" >&2
        return 1
    fi

    # Check if jail config exists
    local jail_config="/etc/fail2ban/jail.d/${jail_name}.conf"
    if [[ ! -f "$jail_config" ]]; then
        echo "ERROR: Jail config not found: ${jail_config}" >&2
        echo "Available jails:" >&2
        ls -1 /etc/fail2ban/jail.d/nftban-*.conf 2>/dev/null | xargs -n1 basename | sed 's/\.conf$//' >&2
        return 1
    fi

    # Check requirements (unless force is enabled)
    if [[ "$force" != "true" ]]; then
        echo "Checking requirements for ${jail_name}..."
        local check_output
        local check_result

        # Capture output and result separately (avoid set -e killing the script)
        check_output=$(nftban_fail2ban_jail_check_requirements "$jail_name" 2>&1) || check_result=$?
        check_result=${check_result:-0}

        if [[ $check_result -ne 0 ]]; then
            echo ""
            echo "⚠️  WARNING: This jail cannot be safely enabled"
            echo "────────────────────────────────────────────────────────────"
            echo "$check_output" | grep "ERROR:" | sed 's/ERROR:/  ✗ /'
            echo ""
            echo "Enabling this jail will cause fail2ban to crash with:"
            echo "  'Have not found any log file for ${jail_name} jail'"
            echo ""
            echo "To enable anyway (not recommended):"
            echo "  nftban fail2ban enable ${jail_input} --force"
            echo ""
            return 1
        fi

        # Show any warnings but continue
        if echo "$check_output" | grep -q "WARNING:"; then
            echo "$check_output" | grep "WARNING:" | sed 's/WARNING:/  ⚠  /'
            echo ""
        fi
    fi

    # Modify config file to enable jail
    if grep -q "^enabled.*=.*false" "$jail_config"; then
        sed -i 's/^enabled\s*=\s*false/enabled   = true/' "$jail_config"
        echo "✓ Enabled ${jail_name} in configuration"
        nftban_fail2ban_log "INFO" "Enabled jail in config: ${jail_name}"
    elif grep -q "^enabled.*=.*true" "$jail_config"; then
        echo "  ${jail_name} already enabled in configuration"
    else
        echo "ERROR: No 'enabled' directive found in ${jail_config}" >&2
        return 1
    fi

    # Restart fail2ban to apply changes (reload doesn't always work)
    echo "  Restarting fail2ban..."
    if systemctl restart fail2ban 2>/dev/null; then
        echo "✓ Fail2ban restarted successfully"

        # Wait a moment for jail to start
        sleep 3

        # Verify jail is running
        if nftban_fail2ban_list_jails | grep -q "^${jail_name}$"; then
            echo "✓ Jail ${jail_name} is now active"
            return 0
        else
            echo "⚠  Jail enabled in config but not yet active. Check: fail2ban-client status" >&2
            return 1
        fi
    else
        echo "ERROR: Failed to restart fail2ban" >&2
        return 1
    fi
}

# Stop a jail (PERMANENTLY - modifies config file)
nftban_fail2ban_jail_stop() {
    local jail_input="$1"
    local jail_name

    # Auto-prefix with nftban- if not already prefixed
    if [[ "$jail_input" == nftban-* ]]; then
        jail_name="$jail_input"
    else
        jail_name="nftban-${jail_input}"
    fi

    if ! nftban_fail2ban_is_running; then
        echo "ERROR: fail2ban not running" >&2
        return 1
    fi

    # Check if jail config exists
    local jail_config="/etc/fail2ban/jail.d/${jail_name}.conf"
    if [[ ! -f "$jail_config" ]]; then
        echo "ERROR: Jail config not found: ${jail_config}" >&2
        return 1
    fi

    # Modify config file to disable jail
    if grep -q "^enabled.*=.*true" "$jail_config"; then
        sed -i 's/^enabled\s*=\s*true/enabled   = false/' "$jail_config"
        echo "✓ Disabled ${jail_name} in configuration"
        nftban_fail2ban_log "INFO" "Disabled jail in config: ${jail_name}"
    elif grep -q "^enabled.*=.*false" "$jail_config"; then
        echo "  ${jail_name} already disabled in configuration"
    else
        echo "ERROR: No 'enabled' directive found in ${jail_config}" >&2
        return 1
    fi

    # Restart fail2ban to apply changes (reload doesn't always work)
    echo "  Restarting fail2ban..."
    if systemctl restart fail2ban 2>/dev/null; then
        echo "✓ Fail2ban restarted successfully"

        # Wait a moment
        sleep 2

        # Verify jail is stopped
        if ! nftban_fail2ban_list_jails | grep -q "^${jail_name}$"; then
            echo "✓ Jail ${jail_name} is now stopped"
            return 0
        else
            echo "⚠  Jail disabled in config but still active. Check: fail2ban-client status" >&2
            return 1
        fi
    else
        echo "ERROR: Failed to restart fail2ban" >&2
        return 1
    fi
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
# HEALTH CHECK AND AUTO-FIX
# =============================================================================

# Health check all jails and fix problems
nftban_fail2ban_health_fix() {
    # Health check and auto-fix for fail2ban jails with report and mail support
    # Usage: nftban_fail2ban_health_fix [--save-report FILE] [--mail EMAIL]
    # Arguments:
    #   --save-report FILE  - Save report to file (default: /var/log/nftban/reports/fail2ban-health-TIMESTAMP.txt)
    #   --mail EMAIL        - Send report via email
    # Returns: 0=OK, 1=problems found and fixed

    # Temporarily disable exit-on-error for this function
    local old_opts
    old_opts=$(set +o)
    set +e

    # Parse arguments
    local save_report=false
    local report_file=""
    local mail_to=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --save-report)
                save_report=true
                if [[ -n "${2:-}" ]] && [[ ! "$2" =~ ^-- ]]; then
                    report_file="$2"
                    shift
                fi
                shift
                ;;
            --mail)
                if [[ -n "${2:-}" ]] && [[ ! "$2" =~ ^-- ]]; then
                    mail_to="$2"
                    shift
                else
                    echo "ERROR: --mail requires an email address" >&2
                    eval "$old_opts"
                    return 1
                fi
                shift
                ;;
            *)
                echo "ERROR: Unknown option: $1" >&2
                echo "Usage: nftban fail2ban health-fix [--save-report [FILE]] [--mail EMAIL]" >&2
                eval "$old_opts"
                return 1
                ;;
        esac
    done

    # Generate default report filename if save requested but no file specified
    if [[ "$save_report" == "true" ]] && [[ -z "$report_file" ]]; then
        report_file="/var/log/nftban/reports/fail2ban-health-$(date +%Y%m%d-%H%M%S).txt"
    fi

    # Start capturing output for report if needed
    local report_output=""
    if [[ "$save_report" == "true" ]] || [[ -n "$mail_to" ]]; then
        # Capture to variable AND show on terminal (use temp file to avoid /dev/tty issues)
        local temp_output="/tmp/nftban-health-fix-$$.tmp"
        _nftban_fail2ban_health_fix_core 2>&1 | tee "$temp_output"
        report_output=$(cat "$temp_output" 2>/dev/null)
        rm -f "$temp_output"
    else
        # Normal output to terminal only
        _nftban_fail2ban_health_fix_core
    fi

    # Save report if requested
    if [[ "$save_report" == "true" ]]; then
        # Ensure report directory exists
        mkdir -p "$(dirname "$report_file")" 2>/dev/null || true

        # Save report
        if echo "$report_output" > "$report_file" 2>/dev/null; then
            echo ""
            echo "📄 Report saved to: $report_file"
        else
            echo ""
            echo "⚠️  Failed to save report to: $report_file" >&2
        fi
    fi

    # Send email if requested
    if [[ -n "$mail_to" ]]; then
        # Load mail module
        if [[ -f "/usr/lib/nftban/core/nftban_mail.sh" ]]; then
            source /usr/lib/nftban/core/nftban_mail.sh 2>/dev/null || true
        fi

        # Check if mail is available
        if declare -f nftban_mail_send >/dev/null 2>&1; then
            echo ""
            echo "📧 Sending report via email to: $mail_to"

            # Create email body with HTML formatting
            local email_body
            email_body="<html><head><style>
body { font-family: monospace; background: #f5f5f5; padding: 20px; }
pre { background: white; padding: 15px; border-radius: 5px; border: 1px solid #ddd; }
.header { background: #2c3e50; color: white; padding: 15px; border-radius: 5px; margin-bottom: 20px; }
.ok { color: green; }
.warn { color: orange; }
.error { color: red; }
</style></head><body>
<div class='header'>
<h2>NFTBan Fail2ban Health Report</h2>
<p>Generated: $(date "+%Y-%m-%d %H:%M:%S")</p>
<p>Hostname: $(hostname)</p>
</div>
<pre>$report_output</pre>
</body></html>"

            # Send email
            if echo "$email_body" | nftban_mail_send "$mail_to" "NFTBan Fail2ban Health Report - $(hostname)" "html" 2>/dev/null; then
                echo "✓ Email sent successfully"
            else
                echo "⚠️  Failed to send email (mail system may not be configured)" >&2
            fi
        else
            echo "⚠️  Mail module not available - skipping email" >&2
        fi
    fi

    # Restore original shell options
    eval "$old_opts"
    return 0
}

# Core health-fix logic (separated for report capture)
_nftban_fail2ban_health_fix_core() {
    echo "════════════════════════════════════════════════════════════"
    echo "  NFTBan Fail2ban Health Check & Auto-Fix"
    echo "════════════════════════════════════════════════════════════"
    echo ""

    local problems_found=false
    local jails_disabled=0
    local jails_ok=0
    local total_jails=0

    # Track detailed jail status for report
    declare -a enabled_jails=()
    declare -a disabled_jails=()
    declare -a problematic_jails=()

    # Get all jail configs
    local all_jail_configs=()
    mapfile -t all_jail_configs < <(find /etc/fail2ban/jail.d -name "nftban-*.conf" 2>/dev/null | sort)

    if [[ ${#all_jail_configs[@]} -eq 0 ]]; then
        echo "No NFTBan jail configurations found."
        return 0
    fi

    echo "Scanning ${#all_jail_configs[@]} jail configurations..."
    echo ""

    for jail_config in "${all_jail_configs[@]}"; do
        local jail_name
        jail_name=$(basename "$jail_config" .conf)
        ((total_jails++))

        # Check if jail is enabled
        local is_enabled=false
        if grep -q "^enabled.*=.*true" "$jail_config"; then
            is_enabled=true
        fi

        # Check requirements
        local check_output
        local check_result=0
        check_output=$(nftban_fail2ban_jail_check_requirements "$jail_name" 2>&1) || check_result=$?

        if [[ "$is_enabled" == "true" ]] && [[ $check_result -ne 0 ]]; then
            # Jail is enabled but has problems
            problems_found=true
            problematic_jails+=("$jail_name")
            echo "✗ ${jail_name} - PROBLEMS FOUND"
            echo "$check_output" | grep "ERROR:" | sed 's/ERROR:/    /'
            echo "    → Disabling this jail to prevent fail2ban crash"

            # Disable the jail
            sed -i 's/^enabled\s*=\s*true/enabled   = false  # Disabled by health-fix/' "$jail_config"
            ((jails_disabled++))
            echo ""

        elif [[ "$is_enabled" == "true" ]] && [[ $check_result -eq 0 ]]; then
            # Jail is enabled and OK
            enabled_jails+=("$jail_name")
            echo "✓ ${jail_name} - OK (enabled)"
            ((jails_ok++))

        else
            # Jail is disabled
            disabled_jails+=("$jail_name")
            if [[ $check_result -ne 0 ]]; then
                echo "○ ${jail_name} - disabled (would fail if enabled)"
            else
                echo "○ ${jail_name} - disabled (ready to enable)"
            fi
        fi
    done

    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "  Summary"
    echo "════════════════════════════════════════════════════════════"
    echo ""
    echo "Total jails scanned:     ${total_jails}"
    echo "Jails OK (enabled):      ${jails_ok}"
    echo "Jails disabled by fix:   ${jails_disabled}"
    echo ""

    # Show enabled jails list
    if [[ ${#enabled_jails[@]} -gt 0 ]]; then
        echo "Currently Enabled Jails:"
        for jail in "${enabled_jails[@]}"; do
            echo "  ✓ $jail"
        done
        echo ""
    fi

    # Show problematic jails if any
    if [[ ${#problematic_jails[@]} -gt 0 ]]; then
        echo "Disabled Problematic Jails:"
        for jail in "${problematic_jails[@]}"; do
            echo "  ✗ $jail"
        done
        echo ""
    fi

    if [[ $jails_disabled -gt 0 ]]; then
        echo "⚠️  Action Required: Restarting fail2ban..."
        if systemctl restart fail2ban 2>/dev/null; then
            sleep 3
            echo "✓ Fail2ban restarted successfully"
            echo ""
            echo "Currently active jails:"
            nftban_fail2ban_list_jails | sed 's/^/  - /'
        else
            echo "✗ Failed to restart fail2ban"
            echo "  Please check: systemctl status fail2ban"
        fi
    else
        echo "✓ No problems found - all enabled jails are healthy"
    fi

    echo ""
    echo "Report generated: $(date "+%Y-%m-%d %H:%M:%S")"
    echo ""

    return 0
}

# =============================================================================
# FOOTER
# =============================================================================

if [[ "${NFTBAN_DEBUG_MODE:-false}" == "true" ]]; then
    nftban_module_loaded "nftban_fail2ban" "1.0.0" "Fail2ban Integration Module" "core" "fail2ban-client,systemctl"
fi

return 0 2>/dev/null || :
