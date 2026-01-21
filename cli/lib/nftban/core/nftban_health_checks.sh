#!/usr/bin/env bash
# shellcheck disable=SC1090  # Dynamic config paths, cannot follow
# =============================================================================
# NFTBan v1.0 - Health Check Functions Library
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: All health check functions (binaries, paths, services, etc.)
#
# meta:name="nftban_health_checks"
# meta:type="lib"
# meta:header="Health Check Functions"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# **Description & Purpose**
# meta:description="Health check functions for system verification"
# meta:input="System state and configuration"
# meta:output="Health status codes and issue reports"
#
# **Inventory & Requirements**
# meta:depends="nftban_health.sh"
# meta:inventory.files=""
# meta:inventory.binaries="nft,systemctl"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_LIB_DIR"
# meta:inventory.config_files="/etc/nftban/nftban.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="nftban"
#
# meta:created_date="2026-01-09"
# meta:updated_date="2026-01-09"
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_NFTBAN_HEALTH_CHECKS_LOADED:-}" ]] && return 0
_NFTBAN_HEALTH_CHECKS_LOADED=1

# =============================================================================
# COMMON HELPER FUNCTIONS
# =============================================================================
# These helpers reduce code duplication across health check functions

# Check if a systemd service is active
# Usage: _health_service_active <service_name>
# Returns: 0 if active, 1 otherwise
_health_service_active() {
    systemctl is-active --quiet "$1" 2>/dev/null
}

# Check if a systemd service is enabled
# Usage: _health_service_enabled <service_name>
# Returns: 0 if enabled, 1 otherwise
_health_service_enabled() {
    systemctl is-enabled --quiet "$1" 2>/dev/null
}

# Check if a systemd unit exists
# Usage: _health_service_exists <service_name>
# Returns: 0 if exists, 1 otherwise
_health_service_exists() {
    local service="$1"
    systemctl list-unit-files 2>/dev/null | grep -q "^${service}" || \
    [[ -f "/etc/systemd/system/${service}" ]] || \
    [[ -f "/usr/lib/systemd/system/${service}" ]]
}

# Get file age in seconds
# Usage: _health_file_age <filepath>
# Returns: age in seconds (0 if file doesn't exist)
_health_file_age() {
    local filepath="$1"
    [[ ! -f "$filepath" ]] && echo "0" && return 1
    local mtime
    mtime=$(stat -c %Y "$filepath" 2>/dev/null || stat -f %m "$filepath" 2>/dev/null || echo 0)
    echo $(( $(date +%s) - mtime ))
}

# Check if a file exists and is recent
# Usage: _health_file_fresh <filepath> <max_age_seconds>
# Returns: 0 if fresh, 1 if stale, 2 if missing
_health_file_fresh() {
    local filepath="$1" max_age="${2:-120}"
    [[ ! -f "$filepath" ]] && return 2
    local age
    age=$(_health_file_age "$filepath")
    [[ $age -lt $max_age ]] && return 0 || return 1
}

# Check if an endpoint is healthy via HTTP
# Usage: _health_http_check <url> [timeout]
# Returns: 0 if healthy, 1 otherwise
_health_http_check() {
    local url="$1" timeout="${2:-${NFTBAN_TIMEOUT_FAST:-3}}"
    command -v curl >/dev/null 2>&1 || return 1
    curl -k -s --connect-timeout "$timeout" "$url" >/dev/null 2>&1
}

# Check and report service status
# Usage: _health_check_service <service> <issues_var> <status_var> [is_optional]
# Modifies the issues array and status variable by reference
_health_check_service() {
    local service="$1"
    local -n issues_ref="$2"
    local -n status_ref="$3"
    local optional="${4:-0}"
    local service_name="${service%.service}"

    if ! _health_service_exists "$service"; then
        if [[ "$optional" == "1" ]]; then
            issues_ref+=("ℹ️ ${service_name}: Not installed (optional)")
        else
            issues_ref+=("${service_name} not installed")
            [[ $status_ref -lt $HEALTH_ERROR ]] && status_ref=$HEALTH_ERROR
        fi
        return 1
    fi

    if _health_service_active "$service"; then
        issues_ref+=("✓ ${service_name}: Running")
        return 0
    else
        if [[ "$optional" == "1" ]]; then
            issues_ref+=("ℹ️ ${service_name}: Not running (optional)")
        else
            issues_ref+=("${service_name} not running")
            [[ $status_ref -lt $HEALTH_WARNING ]] && status_ref=$HEALTH_WARNING
        fi
        return 1
    fi
}

# Check metrics file freshness with standard messaging
# Usage: _health_check_metrics_file <filepath> <name> <issues_var> <status_var> [max_fresh] [max_warning]
_health_check_metrics_file() {
    local filepath="$1" name="$2"
    local -n issues_ref="$3"
    local -n status_ref="$4"
    local max_fresh="${5:-120}" max_warning="${6:-300}"

    if [[ ! -f "$filepath" ]]; then
        issues_ref+=("${name} file not found")
        return 1
    fi

    local age
    age=$(_health_file_age "$filepath")

    if [[ $age -lt $max_fresh ]]; then
        issues_ref+=("✓ ${name}: Fresh (${age}s old)")
        return 0
    elif [[ $age -lt $max_warning ]]; then
        issues_ref+=("⚠ ${name}: ${age}s old (may be stale)")
        [[ $status_ref -eq $HEALTH_OK ]] && status_ref=$HEALTH_WARNING
        return 1
    else
        issues_ref+=("${name} stale (${age}s old)")
        [[ $status_ref -lt $HEALTH_ERROR ]] && status_ref=$HEALTH_ERROR
        return 1
    fi
}

# =============================================================================
# BINARY CHECKS
# =============================================================================

nftban_health_check_binaries() {
    # Check all required binaries are present and executable
    # Returns: 0=OK, 1=Warning, 2=Error

    local status=$HEALTH_OK
    local required_binaries=(
        "nft"
        "systemctl"
        "journalctl"
        "awk"
        "sed"
        "grep"
        "jq"
        "curl"
        "wget"
    )

    # NFTBan's own Go binaries - CRITICAL for core functionality
    local nftban_binaries=(
        "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/bin/nftban-core"
        "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/bin/nftband"
    )

    # NOTE: 'go' is NOT required - NFTBan ships prebuilt Go binaries
    # NOTE: 'git' is only needed for development
    local optional_binaries=(
        "git"
    )

    # Mail binaries - only check if NOT on a panel server
    # Panels manage their own mail services (Exim, Postfix via cPanel/DirectAdmin/Plesk)
    local mail_binaries=(
        "mail"
        "sendmail"
    )

    local missing_required=()
    local missing_optional=()
    local missing_mail=()
    local broken_nftban=()

    # Check required binaries
    for binary in "${required_binaries[@]}"; do
        if ! command -v "$binary" >/dev/null 2>&1; then
            missing_required+=("$binary")
            status=$HEALTH_ERROR
        fi
    done

    # CRITICAL: Check NFTBan's own binaries exist AND are executable
    # BUG FIX: This was missing, so non-executable binaries went undetected
    for binary in "${nftban_binaries[@]}"; do
        if [[ ! -f "$binary" ]]; then
            broken_nftban+=("$binary (missing)")
            status=$HEALTH_ERROR
        elif [[ ! -x "$binary" ]]; then
            broken_nftban+=("$binary (not executable - mode=$(stat -c '%a' "$binary" 2>/dev/null || echo 'unknown'))")
            status=$HEALTH_ERROR
        fi
    done

    if [[ ${#broken_nftban[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ERRORS+=("NFTBan binaries broken: ${broken_nftban[*]}")
        NFTBAN_HEALTH_ISSUES["nftban_binaries"]="Broken: ${broken_nftban[*]}"
    fi

    # Check optional binaries
    for binary in "${optional_binaries[@]}"; do
        if ! command -v "$binary" >/dev/null 2>&1; then
            missing_optional+=("$binary")
            # git is truly optional - don't even warn
        fi
    done

    # Check mail binaries (panel-aware)
    local is_panel=0
    if [[ -d "/usr/local/cpanel" ]] || [[ -d "/usr/local/directadmin" ]] || [[ -d "/usr/local/psa" ]]; then
        is_panel=1
    fi

    for binary in "${mail_binaries[@]}"; do
        if ! command -v "$binary" >/dev/null 2>&1; then
            missing_mail+=("$binary")
        fi
    done

    # Store results
    if [[ ${#missing_required[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["binaries"]="Missing required: ${missing_required[*]}"
        NFTBAN_HEALTH_ERRORS+=("Missing required binaries: ${missing_required[*]}")
    fi

    # Only warn about mail if NOT on a panel (panels manage their own mail)
    if [[ ${#missing_mail[@]} -gt 0 ]] && [[ $is_panel -eq 0 ]]; then
        NFTBAN_HEALTH_WARNINGS+=("Mail notifications disabled (install mailx or sendmail to enable)")
        [[ $status -eq $HEALTH_OK ]] && status=$HEALTH_WARNING
    fi

    NFTBAN_HEALTH_RESULTS["binaries"]=$status
    return $status
}

# =============================================================================
# PATH CHECKS
# =============================================================================

nftban_health_check_paths() {
    # Check all FHS paths exist
    # Returns: 0=OK, 1=Warning, 2=Error

    local status=$HEALTH_OK
    local missing_paths=()

    # Critical paths
    local critical_paths=(
        "${NFTBAN_LIB_DIR}"
        "${NFTBAN_LIB_DIR}/core"
        "${NFTBAN_LIB_DIR}/cli"
        "${NFTBAN_CONFIG_DIR}"
        "${NFTBAN_DATA_DIR}"
        "${NFTBAN_LOG_DIR}"
    )

    # Check critical paths
    for path in "${critical_paths[@]}"; do
        if [[ ! -d "$path" ]]; then
            missing_paths+=("$path")
            status=$HEALTH_ERROR
        fi
    done

    # Store results
    if [[ ${#missing_paths[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["paths"]="Missing: ${missing_paths[*]}"
        NFTBAN_HEALTH_ERRORS+=("Missing critical paths: ${missing_paths[*]}")
    fi

    NFTBAN_HEALTH_RESULTS["paths"]=$status
    return $status
}

# =============================================================================
# PERMISSION CHECKS
# =============================================================================

nftban_health_check_permissions() {
    # Check file and directory permissions
    # Returns: 0=OK, 1=Warning, 2=Error

    local status=$HEALTH_OK
    local permission_issues=()

    # Check nftban user exists
    if ! id -u nftban >/dev/null 2>&1; then
        permission_issues+=("User 'nftban' does not exist")
        status=$HEALTH_ERROR
    fi

    # Check critical file permissions
    local critical_files=(
        "${NFTBAN_BIN:-/usr/bin/nftban}"
        "${NFTBAN_LIB_DIR}/core/nftban_output.sh"
    )

    for file in "${critical_files[@]}"; do
        if [[ -f "$file" ]]; then
            if [[ ! -r "$file" ]]; then
                permission_issues+=("$file not readable")
                status=$HEALTH_ERROR
            fi
        fi
    done

    # Check config files should be nftban:nftban 644
    local config_files=(
        "${NFTBAN_CONFIG_DIR}/portscan_whitelist.conf"
    )

    for file in "${config_files[@]}"; do
        if [[ -f "$file" ]]; then
            local file_owner file_group file_perms
            file_owner=$(stat -c '%U' "$file" 2>/dev/null || echo "unknown")
            file_group=$(stat -c '%G' "$file" 2>/dev/null || echo "unknown")
            file_perms=$(stat -c '%a' "$file" 2>/dev/null || echo "unknown")

            if [[ "$file_owner" == "root" || "$file_group" == "root" ]]; then
                permission_issues+=("$file has root ownership (should be nftban:nftban)")
                status=$HEALTH_WARNING
            fi

            if [[ "$file_perms" == "600" ]]; then
                permission_issues+=("$file has restrictive permissions 600 (should be 644)")
                status=$HEALTH_WARNING
            fi
        fi
    done

    # Check data directory ownership
    if [[ -d "${NFTBAN_DATA_DIR}" ]]; then
        local owner
        owner=$(stat -c '%U' "${NFTBAN_DATA_DIR}" 2>/dev/null || echo "unknown")
        if [[ "$owner" != "nftban" && "$owner" != "root" ]]; then
            permission_issues+=("${NFTBAN_DATA_DIR} has incorrect owner: $owner")
            status=$HEALTH_WARNING
        fi
    fi

    # Check critical scripts are executable (cron, helpers)
    local executable_scripts=(
        "${NFTBAN_LIB_DIR}/cron/maintenance.sh"
        "${NFTBAN_LIB_DIR}/cron/run.sh"
    )

    for script in "${executable_scripts[@]}"; do
        if [[ -f "$script" ]]; then
            if [[ ! -x "$script" ]]; then
                permission_issues+=("$script not executable (run: chmod +x $script)")
                status=$HEALTH_ERROR
            fi
        fi
    done

    # Store results
    if [[ ${#permission_issues[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["permissions"]="${permission_issues[*]}"
        if [[ $status -eq $HEALTH_ERROR ]]; then
            NFTBAN_HEALTH_ERRORS+=("Permission issues: ${permission_issues[*]}")
        else
            NFTBAN_HEALTH_WARNINGS+=("Permission warnings: ${permission_issues[*]}")
        fi
    fi

    NFTBAN_HEALTH_RESULTS["permissions"]=$status
    return $status
}

# =============================================================================
# NFTABLES SECURITY CHECKS
# =============================================================================

nftban_health_check_nftables_security() {
    # Check for security vulnerabilities in nftables configuration
    # Specifically: CVE-2025-NFTBAN-001 (inet filter bypass)
    # Returns: 0=OK, 2=Critical Error

    local status=$HEALTH_OK
    local security_issues=()

    # Check for legacy inet filter table (CVE-2025-NFTBAN-001)
    if nft list table inet filter &>/dev/null 2>&1; then
        # Table exists - check if it has ACCEPT policy at priority 0
        local filter_policy
        filter_policy=$(nft list table inet filter 2>/dev/null | grep -E 'chain input.*priority 0.*policy accept' || true)

        if [[ -n "$filter_policy" ]]; then
            security_issues+=("CRITICAL: inet filter table with 'policy accept' at priority 0 bypasses nftban blocking (CVE-2025-NFTBAN-001)")
            security_issues+=("  └─ All banned IPs can still connect!")
            security_issues+=("  └─ FIX: nft delete table inet filter")
            status=$HEALTH_CRITICAL
        else
            # Table exists but not at priority 0 or doesn't have accept policy
            security_issues+=("WARNING: inet filter table exists but may not conflict")
            security_issues+=("  └─ Verify with: nft list table inet filter")
            status=$HEALTH_WARNING
        fi
    fi

    # Check nftban tables exist (v0.7.3: dual-table architecture)
    if ! nft list table ${NFTBAN_TABLE_IPV4} &>/dev/null 2>&1; then
        security_issues+=("ERROR: IPv4 table (${NFTBAN_TABLE_IPV4}) missing - firewall not active")
        status=$HEALTH_CRITICAL
    fi

    if ! nft list table ${NFTBAN_TABLE_IPV6} &>/dev/null 2>&1; then
        security_issues+=("WARNING: IPv6 table (${NFTBAN_TABLE_IPV6}) missing - IPv6 firewall not active")
        [[ $status -eq $HEALTH_OK ]] && status=$HEALTH_WARNING
    fi

    # Store results
    if [[ ${#security_issues[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["nftables_security"]="${security_issues[*]}"
        if [[ $status -eq $HEALTH_CRITICAL ]]; then
            NFTBAN_HEALTH_ERRORS+=("CRITICAL nftables security issue: ${security_issues[*]}")
        elif [[ $status -eq $HEALTH_WARNING ]]; then
            NFTBAN_HEALTH_WARNINGS+=("nftables security warning: ${security_issues[*]}")
        fi
    fi

    NFTBAN_HEALTH_RESULTS["nftables_security"]=$status
    return $status
}

nftban_health_check_conflicting_firewalls() {
    # Check for conflicting firewall services using comprehensive detection
    # Detects: firewalld, iptables, ufw, fail2ban, CSF, iptables-nft, cPHulk
    # Returns: 0=OK, 1=Warning, 2=Critical Error
    #
    # NOTE: cPHulk (cPanel) is treated as INFO only - it's designed to coexist

    local status=$HEALTH_OK

    # Source the comprehensive conflict detection library
    local conflict_lib="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_firewall_conflicts.sh"
    if [[ -f "$conflict_lib" ]]; then
        # shellcheck source=/dev/null
        source "$conflict_lib" 2>/dev/null || true
    fi

    # Check if detection functions are available
    if ! declare -f nftban_detect_all_conflicts &>/dev/null; then
        # Fallback to basic checks if library not available
        local firewall_conflicts=()

        # Basic firewalld check
        if command -v firewall-cmd &>/dev/null; then
            if systemctl is-active --quiet firewalld 2>/dev/null; then
                firewall_conflicts+=("ERROR: firewalld is ACTIVE")
                status=$HEALTH_CRITICAL
            fi
        fi

        # Basic iptables check
        if systemctl is-active --quiet iptables 2>/dev/null; then
            firewall_conflicts+=("ERROR: iptables service is ACTIVE")
            status=$HEALTH_CRITICAL
        fi

        # Basic ufw check
        if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
            firewall_conflicts+=("ERROR: ufw is ACTIVE")
            status=$HEALTH_CRITICAL
        fi

        if [[ ${#firewall_conflicts[@]} -gt 0 ]]; then
            NFTBAN_HEALTH_ISSUES["conflicting_firewalls"]="${firewall_conflicts[*]}"
            NFTBAN_HEALTH_ERRORS+=("Conflicting firewall(s): ${firewall_conflicts[*]}")
        fi

        NFTBAN_HEALTH_RESULTS["conflicting_firewalls"]=$status
        return $status
    fi

    # Use comprehensive detection
    nftban_detect_all_conflicts

    # Map severity to health status
    case $NFTBAN_FIREWALL_SEVERITY in
        0) status=$HEALTH_OK ;;      # CONFLICT_NONE
        1) status=$HEALTH_OK ;;      # CONFLICT_INFO (e.g., cPHulk - OK to coexist)
        2) status=$HEALTH_WARNING ;; # CONFLICT_WARNING
        3) status=$HEALTH_CRITICAL ;; # CONFLICT_CRITICAL
        *) status=$HEALTH_OK ;;
    esac

    # Store results
    if [[ ${#NFTBAN_FIREWALL_CONFLICTS[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["conflicting_firewalls"]="${NFTBAN_FIREWALL_CONFLICTS[*]}"

        if [[ $status -eq $HEALTH_CRITICAL ]]; then
            NFTBAN_HEALTH_ERRORS+=("Conflicting firewall(s) detected - see: nftban health conflicts")
        elif [[ $status -eq $HEALTH_WARNING ]]; then
            NFTBAN_HEALTH_WARNINGS+=("Firewall conflicts detected - see: nftban health conflicts")
        fi
        # INFO level (cPHulk) doesn't add to warnings/errors
    fi

    NFTBAN_HEALTH_RESULTS["conflicting_firewalls"]=$status
    return $status
}

# =============================================================================
# SERVICE CHECKS
# =============================================================================

nftban_health_check_services() {
    # Check systemd services status
    # Returns: 0=OK, 1=Warning, 2=Error (warnings only, no errors for disabled services)

    local status=$HEALTH_OK
    local service_issues=()

    # Optional services (only check if they exist)
    local optional_services=(
        "nftban-login-monitor.timer"
        "${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service}"
        "${NFTBAN_SERVICE_SURICATA:-nftban-suricata.service}"
        "suricata.service"
    )

    for service in "${optional_services[@]}"; do
        if systemctl list-unit-files "$service" >/dev/null 2>&1; then
            if systemctl is-enabled "$service" >/dev/null 2>&1; then
                if ! systemctl is-active "$service" >/dev/null 2>&1; then
                    service_issues+=("$service is enabled but not running")
                    status=$HEALTH_WARNING
                fi
            fi
        fi
    done

    # Store results
    if [[ ${#service_issues[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["services"]="${service_issues[*]}"
        NFTBAN_HEALTH_WARNINGS+=("Service issues: ${service_issues[*]}")
    fi

    NFTBAN_HEALTH_RESULTS["services"]=$status
    return $status
}

nftban_health_check_suricata() {
    # Comprehensive Suricata IDS health check
    # Returns: 0=OK, 1=Warning, 2=Error

    local status=$HEALTH_OK
    local suricata_issues=()

    # 1. Check if Suricata is installed
    if ! command -v suricata >/dev/null 2>&1; then
        # Suricata is optional, not an error if missing
        NFTBAN_HEALTH_RESULTS["suricata"]=$HEALTH_OK
        return $HEALTH_OK
    fi

    # 2. Check if Suricata service is active (if enabled)
    if systemctl list-unit-files 2>/dev/null | grep -q "^suricata.service"; then
        if systemctl is-enabled --quiet suricata.service 2>/dev/null; then
            if ! systemctl is-active --quiet suricata.service; then
                suricata_issues+=("Suricata service enabled but not running")
                status=$HEALTH_ERROR
            fi
        fi
    fi

    # 3. Check eve-alerts.json log file exists and has recent activity
    # Use central config path, with fallback to NFTBan's path (NOT Suricata default)
    local eve_log="${NFTBAN_SURICATA_EVE_LOG:-/var/log/nftban/suricata/eve-alerts.json}"
    if [[ -f "$eve_log" ]]; then
        # Check if file has been modified in last 10 minutes
        local last_modified
        last_modified=$(stat -c %Y "$eve_log" 2>/dev/null || echo 0)
        local current_time
        current_time=$(date +%s)
        local age
        age=$((current_time - last_modified))

        if [[ $age -gt 600 ]]; then
            suricata_issues+=("eve-alerts.json not updated in 10+ minutes (may be stalled)")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi

        # Check file size (warn if > 1GB)
        local file_size
        file_size=$(stat -c %s "$eve_log" 2>/dev/null || echo 0)
        if [[ $file_size -gt 1073741824 ]]; then
            suricata_issues+=("eve-alerts.json large ($(numfmt --to=iec "$file_size")), consider log rotation")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi
    elif systemctl is-active --quiet suricata.service 2>/dev/null; then
        # Service running but no log file
        suricata_issues+=("Suricata running but eve-alerts.json not found at $eve_log")
        status=$HEALTH_ERROR
    fi

    # 4. Check Suricata memory usage (if running)
    if systemctl is-active --quiet suricata.service 2>/dev/null; then
        local suricata_pid
        suricata_pid=$(systemctl show -p MainPID --value suricata.service 2>/dev/null)
        if [[ -n "$suricata_pid" && "$suricata_pid" != "0" ]]; then
            local mem_mb
            mem_mb=$(ps -p "$suricata_pid" -o rss= 2>/dev/null | awk '{print int($1/1024)}')
            if [[ -n "$mem_mb" && $mem_mb -gt 1024 ]]; then
                suricata_issues+=("Suricata memory usage high (${mem_mb}MB, expected 300-600MB)")
                [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
            fi
        fi
    fi

    # 5. Check sysctl network buffer tuning
    if [[ -f /etc/sysctl.d/90-suricata.conf ]]; then
        local rmem_max
        rmem_max=$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)
        if [[ $rmem_max -lt 67108864 ]]; then
            suricata_issues+=("Network buffer not optimized (rmem_max: $rmem_max, expected: 67108864)")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi
    elif systemctl is-active --quiet suricata.service 2>/dev/null; then
        suricata_issues+=("Sysctl tuning not applied (/etc/sysctl.d/90-suricata.conf missing)")
        [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
    fi

    # Store results
    if [[ ${#suricata_issues[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["suricata"]="${suricata_issues[*]}"
        if [[ $status -eq $HEALTH_WARNING ]]; then
            NFTBAN_HEALTH_WARNINGS+=("Suricata: ${suricata_issues[*]}")
        elif [[ $status -eq $HEALTH_ERROR ]]; then
            NFTBAN_HEALTH_ERRORS+=("Suricata: ${suricata_issues[*]}")
        fi
    fi

    NFTBAN_HEALTH_RESULTS["suricata"]=$status
    return $status
}

# =============================================================================
# MODULE CHECKS
# =============================================================================

nftban_health_check_modules() {
    # Check loaded modules and their functions
    # Returns: 0=OK, 1=Warning, 2=Error

    local status=$HEALTH_OK
    local module_issues=()

    # Core modules that should be loadable
    local core_modules=(
        "nftban_output.sh"
        "nftban_report_port.sh"
        "nftban_report_module.sh"
        "nftban_report_fhs.sh"
        "nftban_geoip_go.sh"
        "nftban_health.sh"
        "nftban_login_alert.sh"
        "nftban_mail.sh"
    )

    for module in "${core_modules[@]}"; do
        local module_path="${NFTBAN_LIB_DIR}/core/$module"
        if [[ ! -f "$module_path" ]]; then
            module_issues+=("Module not found: $module")
            status=$HEALTH_ERROR
        elif [[ ! -r "$module_path" ]]; then
            module_issues+=("Module not readable: $module")
            status=$HEALTH_ERROR
        else
            # Try to source it (in subshell to avoid side effects)
            if ! (source "$module_path") 2>/dev/null; then
                module_issues+=("Module has syntax errors: $module")
                status=$HEALTH_ERROR
            fi
        fi
    done

    # Store results
    if [[ ${#module_issues[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["modules"]="${module_issues[*]}"
        NFTBAN_HEALTH_ERRORS+=("Module issues: ${module_issues[*]}")
    fi

    NFTBAN_HEALTH_RESULTS["modules"]=$status
    return $status
}

# =============================================================================
# ALERT THROTTLING HELPER
# =============================================================================

nftban_health_should_alert() {
    # Check if we should send an alert for a specific issue
    # Args: $1 = alert_key (unique identifier for this alert type)
    # Returns: 0 = should alert, 1 = throttled (too soon)

    local alert_key="$1"
    local throttle_seconds="${NFTBAN_ALERT_THROTTLE_SECONDS:-3600}"
    local state_file="${NFTBAN_ALERT_STATE_FILE:-${NFTBAN_DATA_DIR}/state/health_alerts.state}"
    local state_dir
    state_dir=$(dirname "$state_file")

    # Create state directory if it doesn't exist
    if [[ ! -d "$state_dir" ]]; then
        mkdir -p "$state_dir" 2>/dev/null || return 0
    fi

    # Create state file if it doesn't exist
    if [[ ! -f "$state_file" ]]; then
        touch "$state_file" 2>/dev/null || return 0
    fi

    local current_time
    current_time=$(date +%s)

    # Check last alert time for this key
    local last_alert_time
    last_alert_time=$(grep "^${alert_key}:" "$state_file" 2>/dev/null | cut -d: -f2)

    if [[ -n "$last_alert_time" ]]; then
        local time_since_last_alert
        time_since_last_alert=$((current_time - last_alert_time))

        if [[ $time_since_last_alert -lt $throttle_seconds ]]; then
            # Too soon, throttle this alert
            return 1
        fi
    fi

    # Update state file with current time
    # Remove old entry and add new one
    grep -v "^${alert_key}:" "$state_file" > "${state_file}.tmp" 2>/dev/null || true
    echo "${alert_key}:${current_time}" >> "${state_file}.tmp"
    mv "${state_file}.tmp" "$state_file" 2>/dev/null || true

    # Clean up old entries (older than 24 hours)
    local cutoff_time
    cutoff_time=$((current_time - 86400))
    awk -F: -v cutoff="$cutoff_time" '$2 >= cutoff' "$state_file" > "${state_file}.tmp" 2>/dev/null || true
    mv "${state_file}.tmp" "$state_file" 2>/dev/null || true

    # Should send alert
    return 0
}

# =============================================================================
# SYSTEM RESOURCE CHECKS (CPU, RAM, DISK)
# =============================================================================

nftban_health_check_resources() {
    # Check system resources (CPU, RAM, disk usage)
    # Returns: 0=OK, 1=Warning, 2=Error

    local status=$HEALTH_OK
    local resource_issues=()

    # Configurable thresholds (can be overridden in /etc/nftban/conf.d/health.conf)
    local DISK_WARN_THRESHOLD=${NFTBAN_DISK_WARN_THRESHOLD:-85}
    local DISK_CRIT_THRESHOLD=${NFTBAN_DISK_CRIT_THRESHOLD:-95}
    local RAM_WARN_THRESHOLD=${NFTBAN_RAM_WARN_THRESHOLD:-90}
    local RAM_CRIT_THRESHOLD=${NFTBAN_RAM_CRIT_THRESHOLD:-95}
    local CPU_WARN_THRESHOLD=${NFTBAN_CPU_WARN_THRESHOLD:-80}
    local CPU_CRIT_THRESHOLD=${NFTBAN_CPU_CRIT_THRESHOLD:-95}

    # ==========================================================================
    # DISK USAGE CHECK
    # ==========================================================================

    # Check critical filesystems
    local critical_mounts=("/" "/var" "/var/log" "/tmp")

    for mount_point in "${critical_mounts[@]}"; do
        if [[ -d "$mount_point" ]]; then
            # Get disk usage percentage (without % symbol)
            local disk_usage
            disk_usage=$(df -h "$mount_point" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')

            if [[ -n "$disk_usage" && "$disk_usage" =~ ^[0-9]+$ ]]; then
                if [[ $disk_usage -ge $DISK_CRIT_THRESHOLD ]]; then
                    resource_issues+=("CRITICAL: $mount_point disk usage at ${disk_usage}%")
                    status=$HEALTH_ERROR
                elif [[ $disk_usage -ge $DISK_WARN_THRESHOLD ]]; then
                    resource_issues+=("WARNING: $mount_point disk usage at ${disk_usage}%")
                    [[ $status -eq $HEALTH_OK ]] && status=$HEALTH_WARNING
                fi
            fi
        fi
    done

    # ==========================================================================
    # MEMORY (RAM) USAGE CHECK
    # ==========================================================================

    if command -v free >/dev/null 2>&1; then
        # Get memory usage percentage
        # Using available memory for more accurate calculation
        local mem_total mem_available mem_used_percent

        mem_total=$(free -m | awk '/^Mem:/ {print $2}')
        mem_available=$(free -m | awk '/^Mem:/ {print $7}')

        if [[ -n "$mem_total" && -n "$mem_available" && "$mem_total" -gt 0 ]]; then
            mem_used_percent=$(( 100 - (mem_available * 100 / mem_total) ))

            if [[ $mem_used_percent -ge $RAM_CRIT_THRESHOLD ]]; then
                resource_issues+=("CRITICAL: RAM usage at ${mem_used_percent}%")
                status=$HEALTH_ERROR
            elif [[ $mem_used_percent -ge $RAM_WARN_THRESHOLD ]]; then
                resource_issues+=("WARNING: RAM usage at ${mem_used_percent}%")
                [[ $status -eq $HEALTH_OK ]] && status=$HEALTH_WARNING
            fi
        fi
    fi

    # ==========================================================================
    # CPU LOAD CHECK
    # ==========================================================================

    if [[ -f /proc/loadavg ]]; then
        # Get 1-minute load average
        local load_avg cpu_count load_percent

        load_avg=$(awk '{print $1}' /proc/loadavg)
        cpu_count=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)

        if [[ -n "$load_avg" && -n "$cpu_count" && "$cpu_count" -gt 0 ]]; then
            # Calculate load as percentage of CPU capacity
            load_percent=$(awk -v loadval="$load_avg" -v cpus="$cpu_count" 'BEGIN {printf "%.0f", (loadval/cpus)*100}')

            if [[ $load_percent -ge $CPU_CRIT_THRESHOLD ]]; then
                resource_issues+=("CRITICAL: CPU load at ${load_percent}% (${load_avg}/${cpu_count} cores)")
                status=$HEALTH_ERROR
            elif [[ $load_percent -ge $CPU_WARN_THRESHOLD ]]; then
                resource_issues+=("WARNING: CPU load at ${load_percent}% (${load_avg}/${cpu_count} cores)")
                [[ $status -eq $HEALTH_OK ]] && status=$HEALTH_WARNING
            fi
        fi
    fi

    # ==========================================================================
    # SWAP USAGE CHECK (Optional - high swap can indicate memory pressure)
    # ==========================================================================

    if command -v free >/dev/null 2>&1; then
        local swap_total swap_used swap_percent

        swap_total=$(free -m | awk '/^Swap:/ {print $2}')
        swap_used=$(free -m | awk '/^Swap:/ {print $3}')

        if [[ -n "$swap_total" && -n "$swap_used" && "$swap_total" -gt 0 ]]; then
            swap_percent=$(( swap_used * 100 / swap_total ))

            # Warn if swap usage is high (indicates memory pressure)
            if [[ $swap_percent -ge 75 ]]; then
                resource_issues+=("WARNING: High swap usage at ${swap_percent}% (memory pressure)")
                [[ $status -eq $HEALTH_OK ]] && status=$HEALTH_WARNING
            fi
        fi
    fi

    # ==========================================================================
    # INODE USAGE CHECK (Can cause issues even with free disk space)
    # ==========================================================================

    for mount_point in "${critical_mounts[@]}"; do
        if [[ -d "$mount_point" ]]; then
            local inode_usage
            inode_usage=$(df -i "$mount_point" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')

            if [[ -n "$inode_usage" && "$inode_usage" =~ ^[0-9]+$ ]]; then
                if [[ $inode_usage -ge 95 ]]; then
                    resource_issues+=("CRITICAL: $mount_point inode usage at ${inode_usage}%")
                    status=$HEALTH_ERROR
                elif [[ $inode_usage -ge 85 ]]; then
                    resource_issues+=("WARNING: $mount_point inode usage at ${inode_usage}%")
                    [[ $status -eq $HEALTH_OK ]] && status=$HEALTH_WARNING
                fi
            fi
        fi
    done

    # Store results
    if [[ ${#resource_issues[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["resources"]="${resource_issues[*]}"
        if [[ $status -eq $HEALTH_ERROR ]]; then
            NFTBAN_HEALTH_ERRORS+=("Resource issues: ${resource_issues[*]}")
        else
            NFTBAN_HEALTH_WARNINGS+=("Resource warnings: ${resource_issues[*]}")
        fi
    else
        NFTBAN_HEALTH_ISSUES["resources"]="All resources within normal limits"
    fi

    NFTBAN_HEALTH_RESULTS["resources"]=$status
    return "$status"
}

# =============================================================================
# v0.31 INVENTORY HELPERS CHECKS
# =============================================================================

nftban_health_check_v030_helpers() {
    # Check v0.31 inventory helpers
    # Returns: 0=OK, 1=Warning, 2=Error (warnings only - v0.31 is optional)

    local status=$HEALTH_OK
    local helper_issues=()

    # v0.31 inventory helpers
    local helpers=(
        "nftban-procnet"
        "nftban-pkgs"
        "nftban-verify"
        "nftban-firewall"
    )

    local helpers_found=0
    local helpers_executable=0

    for helper in "${helpers[@]}"; do
        local helper_path="/usr/libexec/nftban/$helper"

        if [[ -f "$helper_path" ]]; then
            helpers_found=$((helpers_found + 1))

            if [[ -x "$helper_path" ]]; then
                helpers_executable=$((helpers_executable + 1))
            else
                helper_issues+=("$helper not executable")
                status=$HEALTH_WARNING
            fi
        fi
    done

    # Check if v0.31 mail adapter is present
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_mail_v030.sh" ]]; then
        if [[ ! -r "${NFTBAN_LIB_DIR}/core/nftban_mail_v030.sh" ]]; then
            helper_issues+=("v0.31 mail adapter not readable")
            status=$HEALTH_WARNING
        fi
    fi

    # Check if v0.31 health commands are present
    local health_commands=(
        "nftban-health"
        "nftban-baseline-save"
        "nftban-verify-signature"
    )

    for cmd in "${health_commands[@]}"; do
        if [[ -f "/usr/local/lib/nftban/$cmd" ]]; then
            if [[ ! -x "/usr/local/lib/nftban/$cmd" ]]; then
                helper_issues+=("$cmd not executable")
                status=$HEALTH_WARNING
            fi

            # Check symlink in /usr/local/bin
            if [[ ! -L "/usr/local/bin/$cmd" ]]; then
                helper_issues+=("$cmd symlink missing in /usr/local/bin")
                status=$HEALTH_WARNING
            fi
        fi
    done

    # Store results
    if [[ $helpers_found -eq 0 ]]; then
        # v0.31 not installed - not an error, just informational
        NFTBAN_HEALTH_ISSUES["v030_helpers"]="v0.31 extensions not installed"
    elif [[ ${#helper_issues[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["v030_helpers"]="${helper_issues[*]}"
        NFTBAN_HEALTH_WARNINGS+=("v0.31 issues: ${helper_issues[*]}")
    else
        NFTBAN_HEALTH_ISSUES["v030_helpers"]="All v0.31 helpers OK ($helpers_executable/$helpers_found)"
    fi

    NFTBAN_HEALTH_RESULTS["v030_helpers"]=$status
    return "$status"
}

# =============================================================================
# GEOIP CHECKS
# =============================================================================

nftban_health_check_geoip() {
    # Check GeoIP system (v0.7.3 unified architecture)
    # - All GeoIP functionality in nftban-core (update, status, lookup)
    # Returns: 0=OK, 1=Warning, 2=Error

    local status=$HEALTH_OK
    local geoip_issues=()

    local nftban_core="${NFTBAN_LIB_DIR}/bin/nftban-core"

    # Check for ANY supported GeoIP database (DB-IP free or MaxMind)
    local db_path=""
    local geoip_dir="${NFTBAN_DATA_DIR}/geoip"
    for db_file in "dbip-country-lite.mmdb" "GeoLite2-City.mmdb" "GeoLite2-Country.mmdb"; do
        if [[ -f "${geoip_dir}/${db_file}" ]]; then
            db_path="${geoip_dir}/${db_file}"
            break
        fi
    done

    # Check nftban-core (REQUIRED CORE MODULE - handles country/feeds/geoip)
    if [[ ! -x "$nftban_core" ]]; then
        # Try fallback paths
        nftban_core=$(command -v nftban-core 2>/dev/null || echo "")
        if [[ -z "$nftban_core" ]]; then
            geoip_issues+=("nftban-core binary NOT FOUND - REQUIRED core module")
            geoip_issues+=("FIX: nftban-core must be installed and compiled (handles country/feeds/geoip)")
            status=$HEALTH_ERROR
            # Store and return immediately - no point checking database if core is missing
            NFTBAN_HEALTH_ISSUES["geoip"]="${geoip_issues[*]}"
            NFTBAN_HEALTH_ERRORS+=("nftban-core: ${geoip_issues[*]}")
            NFTBAN_HEALTH_RESULTS["geoip"]=$status
            return "$status"
        fi
    fi

    # Check database (nftban-core is installed, now check if GeoIP DB is downloaded)
    if [[ -z "$db_path" ]]; then
        geoip_issues+=("GeoIP database not downloaded")
        geoip_issues+=("FIX: Run 'nftban geoip update' to download database")
        status=$HEALTH_ERROR
    elif [[ ! -r "$db_path" ]]; then
        geoip_issues+=("Database not readable: $db_path")
        status=$HEALTH_WARNING
    else
        # Database exists - verify with nftban-core
        if [[ -n "$nftban_core" && -x "$nftban_core" ]]; then
            if ! "$nftban_core" geoip status >/dev/null 2>&1; then
                geoip_issues+=("Database verification failed")
                status=$HEALTH_WARNING
            else
                # Performance test
                local start_time end_time elapsed
                start_time=$(date +%s%N)
                if "$nftban_core" geoip lookup 8.8.8.8 >/dev/null 2>&1; then
                    end_time=$(date +%s%N)
                    elapsed=$(( (end_time - start_time) / 1000 ))

                    if (( elapsed > 10000 )); then
                        geoip_issues+=("Lookup performance degraded: ${elapsed}μs (expected <1000μs)")
                    fi
                else
                    geoip_issues+=("Lookup test failed")
                fi
            fi
        fi
    fi

    # Store results
    if [[ ${#geoip_issues[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["geoip"]="${geoip_issues[*]}"
        if [[ $status -eq $HEALTH_WARNING ]]; then
            NFTBAN_HEALTH_WARNINGS+=("nftban-core: ${geoip_issues[*]}")
        elif [[ $status -eq $HEALTH_ERROR ]]; then
            NFTBAN_HEALTH_ERRORS+=("nftban-core: ${geoip_issues[*]}")
        fi
    fi

    NFTBAN_HEALTH_RESULTS["geoip"]=$status
    return "$status"
}

# =============================================================================
# GEOBAN (COUNTRY BLOCKING) CHECK
# =============================================================================

nftban_health_check_geoban() {
    # Check GeoBan country blocking module
    # This is SEPARATE from GeoIP (database) - GeoBan is the country blocking feature
    # Returns: 0=OK (configured or not needed), 1=Warning, 2=Error

    local status=$HEALTH_OK
    local geoban_issues=()

    # Check for country blocking configurations
    local geoban_dir="${NFTBAN_DATA_DIR}/geoban"
    local blocked_count=0

    if [[ -d "$geoban_dir" ]]; then
        # Count blocked countries
        shopt -s nullglob 2>/dev/null || true
        for file in "$geoban_dir"/*.conf; do
            if [[ -f "$file" ]] && grep -q "^MODE=.*block" "$file" 2>/dev/null; then
                ((blocked_count++))
            fi
        done
        shopt -u nullglob 2>/dev/null || true
    fi

    # GeoBan is optional - not having it configured is fine
    if [[ $blocked_count -gt 0 ]]; then
        # If GeoBan is configured, verify GeoIP database is available
        local nftban_core="${NFTBAN_LIB_DIR}/bin/nftban-core"
        [[ ! -x "$nftban_core" ]] && nftban_core=$(command -v nftban-core 2>/dev/null || echo "")

        if [[ -n "$nftban_core" ]] && [[ -x "$nftban_core" ]]; then
            if ! "$nftban_core" geoip status >/dev/null 2>&1; then
                geoban_issues+=("GeoBan has $blocked_count countries configured but GeoIP database is missing")
                geoban_issues+=("FIX: Run 'nftban geoip update' to download the database")
                status=$HEALTH_WARNING
            fi
        else
            geoban_issues+=("GeoBan has $blocked_count countries configured but nftban-core is missing")
            status=$HEALTH_WARNING
        fi
    fi

    # Store results
    if [[ ${#geoban_issues[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["geoban"]="${geoban_issues[*]}"
        if [[ $status -eq $HEALTH_WARNING ]]; then
            NFTBAN_HEALTH_WARNINGS+=("geoban: ${geoban_issues[*]}")
        elif [[ $status -eq $HEALTH_ERROR ]]; then
            NFTBAN_HEALTH_ERRORS+=("geoban: ${geoban_issues[*]}")
        fi
    fi

    NFTBAN_HEALTH_RESULTS["geoban"]=$status
    return "$status"
}

# =============================================================================
# DATABASE CHECKS
# =============================================================================

nftban_health_check_databases() {
    # Check database files
    # Returns: 0=OK, 1=Warning, 2=Error

    local status=$HEALTH_OK
    local db_issues=()

    # Auto-detect GeoIP database from config
    local geoip_db=""
    local geoip_dir="${NFTBAN_DATA_DIR}/geoip"
    if [[ -n "${NFTBAN_GEOIP_DATABASE:-}" ]] && [[ -f "${NFTBAN_GEOIP_DATABASE}" ]]; then
        geoip_db="${NFTBAN_GEOIP_DATABASE}"
    else
        for db_file in ${NFTBAN_GEOIP_DATABASES:-dbip-country-lite.mmdb GeoLite2-City.mmdb GeoLite2-Country.mmdb}; do
            [[ -f "${geoip_dir}/${db_file}" ]] && geoip_db="${geoip_dir}/${db_file}" && break
        done
    fi

    if [[ -n "$geoip_db" ]] && [[ -f "$geoip_db" ]]; then
        # Check age (warn if >90 days old)
        local file_age
        file_age=$(( $(date +%s) - $(stat -c %Y "$geoip_db" 2>/dev/null || echo 0) ))
        local days_old
        days_old=$(( file_age / 86400 ))
        local db_name
        db_name=$(basename "$geoip_db")

        if (( days_old > 90 )); then
            db_issues+=("${db_name} is ${days_old} days old (consider updating)")
            status=$HEALTH_WARNING
        fi
    fi

    # Store results
    if [[ ${#db_issues[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["databases"]="${db_issues[*]}"
        NFTBAN_HEALTH_WARNINGS+=("Database issues: ${db_issues[*]}")
    fi

    NFTBAN_HEALTH_RESULTS["databases"]=$status
    return "$status"
}

# =============================================================================
# CONFIGURATION CHECKS
# =============================================================================

nftban_health_check_config() {
    # Check configuration files
    # Returns: 0=OK, 1=Warning, 2=Error

    local status=$HEALTH_OK
    local config_issues=()

    # Main config directory
    if [[ ! -d "${NFTBAN_CONFIG_DIR}" ]]; then
        config_issues+=("Config directory not found: ${NFTBAN_CONFIG_DIR}")
        status=$HEALTH_ERROR
    fi

    # Check for basic config files
    local config_dir="${NFTBAN_CONFIG_DIR}/conf.d"
    if [[ -d "$config_dir" ]]; then
        # Try to source config files (in subshell)
        # Check top-level conf files
        for conf_file in "$config_dir"/*.conf; do
            if [[ -f "$conf_file" ]]; then
                # shellcheck disable=SC1090  # Dynamic source for config validation
                if ! (source "$conf_file") 2>/dev/null; then
                    config_issues+=("Config has syntax errors: $(basename "$conf_file")")
                    status=$HEALTH_ERROR
                fi
            fi
        done

        # Check subdirectory config files (ddos/, portscan/, login/, panels/)
        # Skip data files that aren't meant to be sourced as bash
        local skip_files=("rbls.conf" "feeds.conf")  # Data files, not bash configs
        for subdir in "$config_dir"/*; do
            if [[ -d "$subdir" ]]; then
                for conf_file in "$subdir"/*.conf; do
                    if [[ -f "$conf_file" ]]; then
                        local filename; filename=$(basename "$conf_file")
                        # Skip known data files that aren't bash configs
                        local skip=false
                        for skip_file in "${skip_files[@]}"; do
                            [[ "$filename" == "$skip_file" ]] && { skip=true; break; }
                        done
                        [[ "$skip" == "true" ]] && continue

                        # shellcheck disable=SC1090  # Dynamic source for config validation
                        if ! (source "$conf_file") 2>/dev/null; then
                            local relative_path; relative_path="$(basename "$subdir")/$(basename "$conf_file")"
                            config_issues+=("Config has syntax errors: $relative_path")
                            status=$HEALTH_ERROR
                        fi
                    fi
                done
            fi
        done
    fi

    # Check system.conf (UID/GID configuration)
    local system_conf="${NFTBAN_DATA_DIR}/config/system.conf"
    if [[ ! -f "$system_conf" ]]; then
        config_issues+=("System config missing: $system_conf (will auto-create)")
        [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
    else
        # Verify system.conf is readable and has valid syntax
        # shellcheck disable=SC1090  # Dynamic source for config validation
        if ! (source "$system_conf") 2>/dev/null; then
            config_issues+=("System config has syntax errors: $system_conf")
            status=$HEALTH_ERROR
        else
            # Verify UID/GID values match actual system
            # shellcheck disable=SC1090  # Dynamic source for config validation
            source "$system_conf" 2>/dev/null
            # NFTBan v1.0 simplified 2-group model: nftban + nftban-auditor
            local actual_uid actual_gid actual_auditors_gid
            actual_uid=$(id -u nftban 2>/dev/null || echo "MISSING")
            actual_gid=$(id -g nftban 2>/dev/null || echo "MISSING")
            actual_auditors_gid=$(getent group nftban-auditor 2>/dev/null | cut -d: -f3 || echo "MISSING")

            if [[ "$actual_uid" != "$NFTBAN_UID" ]] || \
               [[ "$actual_gid" != "$NFTBAN_GID" ]] || \
               [[ "$actual_auditors_gid" != "${NFTBAN_AUDITORS_GID:-MISSING}" ]]; then
                config_issues+=("System config outdated (UID/GID mismatch, will auto-fix)")
                [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
            fi
        fi
    fi

    # Store results
    if [[ ${#config_issues[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["config"]="${config_issues[*]}"
        if [[ $status -eq $HEALTH_ERROR ]]; then
            NFTBAN_HEALTH_ERRORS+=("Config issues: ${config_issues[*]}")
        else
            NFTBAN_HEALTH_WARNINGS+=("Config issues: ${config_issues[*]}")
        fi
    fi

    NFTBAN_HEALTH_RESULTS["config"]=$status
    return $status
}

# =============================================================================
# REGISTRY HEALTH CHECK (v1.0.16 - Commands Registry)
# =============================================================================

nftban_health_check_registry() {
    # Check commands.registry.yml and documentation generators
    # Returns: 0=OK, 1=Warning, 2=Error

    local status=$HEALTH_OK
    local registry_issues=()

    # Check registry file exists
    local registry="${NFTBAN_CONFIG_DIR:-/etc/nftban}/commands.registry.yml"
    if [[ ! -f "$registry" ]]; then
        registry_issues+=("Registry missing: $registry")
        status=$HEALTH_ERROR
    else
        # Check registry is readable
        if [[ ! -r "$registry" ]]; then
            registry_issues+=("Registry not readable: $registry")
            status=$HEALTH_ERROR
        else
            # Check registry file size (should be ~100KB+)
            local size
            size=$(stat -c%s "$registry" 2>/dev/null || stat -f%z "$registry" 2>/dev/null || echo "0")
            if [[ $size -lt 10000 ]]; then
                registry_issues+=("Registry suspiciously small: $size bytes (corrupted?)")
                status=$HEALTH_ERROR
            fi

            # Check YAML validity if yq available
            if command -v yq &>/dev/null; then
                if ! yq -r '._metadata.version' "$registry" >/dev/null 2>&1; then
                    registry_issues+=("Registry has invalid YAML syntax")
                    status=$HEALTH_ERROR
                else
                    # Verify metadata
                    local total_commands
                    total_commands=$(yq -r '._metadata.total_commands // 0' "$registry" 2>/dev/null)
                    if [[ $total_commands -lt 40 ]]; then
                        registry_issues+=("Registry appears incomplete: only $total_commands commands (expected 45+)")
                        [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
                    fi
                fi
            else
                registry_issues+=("yq not installed - cannot validate YAML (install: pip install yq)")
                [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
            fi
        fi

        # Check registry permissions (should be 644)
        local perms
        perms=$(stat -c "%a" "$registry" 2>/dev/null || stat -f "%Lp" "$registry" 2>/dev/null || echo "000")
        if [[ "$perms" != "644" ]]; then
            registry_issues+=("Registry permissions incorrect: $perms (should be 644)")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi
    fi

    # Check documentation generators exist and are executable
    local generators=(
        "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/scripts/generate-help.sh"
        "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/scripts/generate-wiki-operator.sh"
        "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/scripts/generate-wiki-auditor.sh"
    )

    for gen in "${generators[@]}"; do
        if [[ ! -f "$gen" ]]; then
            registry_issues+=("Generator missing: $(basename "$gen")")
            status=$HEALTH_ERROR
        elif [[ ! -x "$gen" ]]; then
            registry_issues+=("Generator not executable: $(basename "$gen")")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi
    done

    # Store results
    if [[ ${#registry_issues[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["registry"]="${registry_issues[*]}"
        if [[ $status -eq $HEALTH_ERROR ]]; then
            NFTBAN_HEALTH_ERRORS+=("Registry issues: ${registry_issues[*]}")
        else
            NFTBAN_HEALTH_WARNINGS+=("Registry issues: ${registry_issues[*]}")
        fi
    fi

    NFTBAN_HEALTH_RESULTS["registry"]=$status
    return $status
}

nftban_health_check_polkit() {
    # Check Polkit authorization rules installation
    # Returns: 0=OK, 1=Warning, 2=Error (CRITICAL security violation)

    local status=$HEALTH_OK
    local polkit_issues=()

    # Check if Polkit is available on the system
    if ! command -v pkaction >/dev/null 2>&1; then
        polkit_issues+=("Polkit not installed - nftban group requires sudo for service management")
        polkit_issues+=("nftban-auditor group will also require sudo for inventory helpers")
        status=$HEALTH_WARNING
    else
        # Check if NFTBAN systemd authorization rules are installed (v1.0.19+ naming)
        # Old names: 60-nftban-services.rules, 50-nftban-v030.rules (removed in v1.0.19)
        # New names: 10-nftban-systemd.rules, 20-nftban-auditor.rules, 30-nftban-panel.rules
        local polkit_rules_dir="${NFTBAN_POLKIT_RULES_DIR:-/etc/polkit-1/rules.d}"

        local polkit_systemd_rules="${polkit_rules_dir}/10-nftban-systemd.rules"
        if [[ ! -f "$polkit_systemd_rules" ]]; then
            polkit_issues+=("CRITICAL: Polkit systemd rules missing at $polkit_systemd_rules")
            polkit_issues+=("This violates NFTBAN security model - privilege separation not functional!")
            polkit_issues+=("Users in nftban group CANNOT manage services without sudo")
            polkit_issues+=("FIX: Re-run install.sh or reinstall nftban package")
            status=$HEALTH_ERROR
        else
            # Verify file permissions
            local perms
            perms=$(stat -c '%a' "$polkit_systemd_rules" 2>/dev/null || echo "000")
            if [[ "$perms" != "644" ]]; then
                polkit_issues+=("Polkit systemd rules have wrong permissions: $perms (should be 644)")
                status=$HEALTH_WARNING
            fi
        fi

        # Check if NFTBAN Auditor authorization rules are installed (v1.0.19+)
        local polkit_auditor_rules="${polkit_rules_dir}/20-nftban-auditor.rules"
        if [[ ! -f "$polkit_auditor_rules" ]]; then
            polkit_issues+=("WARNING: Polkit auditor rules missing at $polkit_auditor_rules")
            polkit_issues+=("Users in nftban-auditor group cannot run inventory helpers without sudo")
            polkit_issues+=("FIX: Re-run install.sh or reinstall nftban package")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        else
            # Verify file permissions
            local perms
            perms=$(stat -c '%a' "$polkit_auditor_rules" 2>/dev/null || echo "000")
            if [[ "$perms" != "644" ]]; then
                polkit_issues+=("Polkit auditor rules have wrong permissions: $perms (should be 644)")
                [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
            fi
        fi

        # Check if NFTBAN Panel authorization rules are installed (v1.0.19+)
        local polkit_panel_rules="${polkit_rules_dir}/30-nftban-panel.rules"
        if [[ ! -f "$polkit_panel_rules" ]]; then
            polkit_issues+=("WARNING: Polkit panel rules missing at $polkit_panel_rules")
            polkit_issues+=("Control panel integrations may not work without sudo")
            polkit_issues+=("FIX: Re-run install.sh or reinstall nftban package")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        else
            # Verify file permissions
            local perms
            perms=$(stat -c '%a' "$polkit_panel_rules" 2>/dev/null || echo "000")
            if [[ "$perms" != "644" ]]; then
                polkit_issues+=("Polkit panel rules have wrong permissions: $perms (should be 644)")
                [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
            fi
        fi

        # Check if polkit service is running
        # Service name varies: polkit (RHEL) vs polkitd (Debian)
        if command -v systemctl >/dev/null 2>&1; then
            local polkit_service="polkit"
            # Use distro config if available (polkit on RHEL, polkitd on Debian)
            if declare -F nftban_distro_get_service >/dev/null 2>&1; then
                polkit_service=$(nftban_distro_get_service polkit)
                # Fallback to "polkit" if distro config doesn't have it
                [[ -z "$polkit_service" ]] && polkit_service="polkit"
            fi

            if ! systemctl is-active --quiet "$polkit_service" 2>/dev/null; then
                # Polkit not running - this is OPTIONAL for minimal installations
                # Only matters if users in nftban group need to manage services without sudo
                # Root users (which is typical for minimal installs) don't need polkit
                if [[ "${NFTBAN_HEALTH_AUTO_HEAL:-false}" == "true" ]]; then
                    if systemctl start "$polkit_service" 2>/dev/null; then
                        polkit_issues+=("Polkit service was stopped - AUTO-HEALED: started successfully")
                        [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
                    else
                        polkit_issues+=("Polkit service not running (optional for minimal installs)")
                        polkit_issues+=("Only needed if non-root users manage services")
                        [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
                    fi
                else
                    polkit_issues+=("Polkit service not running (optional for minimal installs)")
                    polkit_issues+=("Only needed if non-root users manage services")
                    polkit_issues+=("FIX: sudo systemctl start $polkit_service")
                    [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
                fi
            fi
        fi
    fi

    # Store results
    if [[ ${#polkit_issues[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["polkit"]="${polkit_issues[*]}"
        if [[ $status -eq $HEALTH_ERROR ]]; then
            NFTBAN_HEALTH_ERRORS+=("Polkit issues: ${polkit_issues[*]}")
        else
            NFTBAN_HEALTH_WARNINGS+=("Polkit issues: ${polkit_issues[*]}")
        fi
    fi

    NFTBAN_HEALTH_RESULTS["polkit"]=$status
    return $status
}

nftban_health_check_systemd_hardening() {
    # Check systemd service hardening (NoNewPrivileges, security scores)
    # Returns: 0=OK, 1=Warning, 2=Error, 3=Critical
    #
    # Checks:
    # 1. NoNewPrivileges=false instances (privilege escalation risk)
    # 2. systemd-analyze security scores for key services

    local status=$HEALTH_OK
    local hardening_issues=()

    # =========================================================================
    # CHECK 1: Scan all NFTBan systemd units for NoNewPrivileges=false
    # =========================================================================

    local units_with_nnp_false=()
    local systemd_unit_paths=(
        "/etc/systemd/system"
        "/usr/lib/systemd/system"
        "/lib/systemd/system"
    )

    # Find all nftban*.service files
    local nftban_units=()
    for unit_path in "${systemd_unit_paths[@]}"; do
        if [[ -d "$unit_path" ]]; then
            while IFS= read -r -d '' unit_file; do
                nftban_units+=("$unit_file")
            done < <(find "$unit_path" -maxdepth 1 -name 'nftban*.service' -type f -print0 2>/dev/null)
        fi
    done

    # Scan each unit for NoNewPrivileges=false
    for unit_file in "${nftban_units[@]}"; do
        if grep -qE '^\s*NoNewPrivileges\s*=\s*false\s*$' "$unit_file" 2>/dev/null; then
            local unit_name
            unit_name=$(basename "$unit_file")
            units_with_nnp_false+=("$unit_name")
        fi
    done

    # Report NoNewPrivileges=false findings
    if [[ ${#units_with_nnp_false[@]} -gt 0 ]]; then
        hardening_issues+=("CRITICAL: ${#units_with_nnp_false[@]} systemd service(s) have NoNewPrivileges=false")
        hardening_issues+=("  └─ This allows privilege escalation via setuid/setcap executables")
        for unit in "${units_with_nnp_false[@]}"; do
            hardening_issues+=("  └─ $unit")
        done
        hardening_issues+=("  └─ FIX: Set NoNewPrivileges=yes in all units")
        hardening_issues+=("  └─ See: /home/commonfolder/nftban2026/SECURITY_NONEWPRIVILEGES_FIX.md")
        status=$HEALTH_CRITICAL
    fi

    # =========================================================================
    # CHECK 2: Run systemd-analyze security on key services
    # =========================================================================

    if command -v systemd-analyze >/dev/null 2>&1; then
        # Key security-sensitive services to check
        local key_services=(
            "nftban-maintenance.service"
            "nftban-ui.service"
            "nftband.service"
        )

        local poor_scores=()
        for service in "${key_services[@]}"; do
            # Check if service exists
            if systemctl list-unit-files "$service" &>/dev/null; then
                # Run systemd-analyze security (extract exposure score)
                local score_output
                score_output=$(systemd-analyze security "$service" 2>/dev/null | grep -E '^→ Overall exposure level:' | head -1)

                if [[ -n "$score_output" ]]; then
                    # Extract exposure level (SAFE, OK, MEDIUM, EXPOSED, UNSAFE)
                    local exposure_level
                    exposure_level=$(echo "$score_output" | awk '{print $NF}')

                    # Warn on EXPOSED or UNSAFE
                    if [[ "$exposure_level" == "EXPOSED" || "$exposure_level" == "UNSAFE" ]]; then
                        poor_scores+=("$service: $exposure_level")
                    fi
                fi
            fi
        done

        if [[ ${#poor_scores[@]} -gt 0 ]]; then
            hardening_issues+=("WARNING: ${#poor_scores[@]} service(s) have poor systemd security scores")
            for score in "${poor_scores[@]}"; do
                hardening_issues+=("  └─ $score")
            done
            hardening_issues+=("  └─ Run: systemd-analyze security <service> for details")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi
    fi

    # =========================================================================
    # Store results
    # =========================================================================

    if [[ ${#hardening_issues[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["systemd_hardening"]="${hardening_issues[*]}"
        if [[ $status -eq $HEALTH_CRITICAL ]]; then
            NFTBAN_HEALTH_ERRORS+=("CRITICAL systemd hardening issues: ${hardening_issues[*]}")
        elif [[ $status -eq $HEALTH_ERROR ]]; then
            NFTBAN_HEALTH_ERRORS+=("systemd hardening issues: ${hardening_issues[*]}")
        elif [[ $status -eq $HEALTH_WARNING ]]; then
            NFTBAN_HEALTH_WARNINGS+=("systemd hardening warnings: ${hardening_issues[*]}")
        fi
    fi

    NFTBAN_HEALTH_RESULTS["systemd_hardening"]=$status
    return $status
}

nftban_health_check_ssh_port() {
    # Check and auto-update SSH port whitelist
    # Returns: 0=OK, 1=Warning (auto-fixed), 2=Error (couldn't fix)

    local status=$HEALTH_OK
    local ssh_issues=()

    # Detect current SSH port from sshd_config
    local current_ssh_port=22
    if [[ -f "/etc/ssh/sshd_config" ]]; then
        local detected_port
        detected_port=$(grep -E '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
        if [[ -n "$detected_port" ]] && [[ "$detected_port" =~ ^[0-9]+$ ]]; then
            current_ssh_port=$detected_port
        fi
    fi

    # Check current whitelisted SSH port in config
    local config_ssh_port=""
    if [[ -f "${NFTBAN_CONFIG_DIR}/ports.d/00-ssh.conf" ]]; then
        config_ssh_port=$(grep -oP '^\d+' "${NFTBAN_CONFIG_DIR}/ports.d/00-ssh.conf" 2>/dev/null | head -1)
    fi

    # Compare and auto-update if needed
    if [[ "$current_ssh_port" != "$config_ssh_port" ]]; then
        ssh_issues+=("SSH port mismatch: sshd_config=$current_ssh_port, nftban=$config_ssh_port")

        # Auto-fix: Update the SSH port config
        if mkdir -p "${NFTBAN_CONFIG_DIR}/ports.d" 2>/dev/null; then
            cat > "${NFTBAN_CONFIG_DIR}/ports.d/00-ssh.conf" << EOF
# SSH port auto-updated by health check ($(date '+%Y-%m-%d %H:%M:%S'))
# Port format: PORT|PROTO where PROTO = T(tcp), U(udp), B(both)
$current_ssh_port|T
EOF
            chown nftban:nftban "${NFTBAN_CONFIG_DIR}/ports.d/00-ssh.conf" 2>/dev/null || true
            chmod 644 "${NFTBAN_CONFIG_DIR}/ports.d/00-ssh.conf" 2>/dev/null || true

            ssh_issues+=("AUTO-FIXED: Updated SSH port to $current_ssh_port in ${NFTBAN_CONFIG_DIR}/ports.d/00-ssh.conf")
            ssh_issues+=("Action required: Run 'nftban firewall reload' to apply changes")

            status=$HEALTH_WARNING  # Warning because reload needed
        else
            ssh_issues+=("FAILED to auto-fix: Cannot write to ${NFTBAN_CONFIG_DIR}/ports.d/")
            status=$HEALTH_ERROR
        fi
    fi

    # Verify SSH port is actually in nftables (v0.7.3: check IPv4 table)
    if nft list table ${NFTBAN_TABLE_IPV4} >/dev/null 2>&1; then
        if ! nft list set ${NFTBAN_TABLE_IPV4} tcp_ports 2>/dev/null | grep -qw "$current_ssh_port"; then
            ssh_issues+=("WARNING: SSH port $current_ssh_port NOT in nftables tcp_ports set")
            ssh_issues+=("LOCKOUT RISK! Run: nftban firewall reload")
            status=$HEALTH_ERROR
        fi
    fi

    # Store results
    if [[ ${#ssh_issues[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["ssh_port"]="${ssh_issues[*]}"
        if [[ $status -eq $HEALTH_ERROR ]]; then
            NFTBAN_HEALTH_ERRORS+=("SSH port issues: ${ssh_issues[*]}")
        else
            NFTBAN_HEALTH_WARNINGS+=("SSH port issues: ${ssh_issues[*]}")
        fi
    fi

    NFTBAN_HEALTH_RESULTS["ssh_port"]=$status
    return $status
}

nftban_health_check_bash_completion() {
    # Check bash-completion package installation
    # Returns: 0=OK, 1=Warning, 2=Error

    local status=$HEALTH_OK
    local completion_issues=()

    # Check if bash-completion is installed
    # Method 1: Check if main bash_completion script exists
    if [[ ! -f /usr/share/bash-completion/bash_completion ]] && \
       [[ ! -f /etc/bash_completion ]]; then
        completion_issues+=("bash-completion package not installed")
        completion_issues+=("Tab completion for nftban command will not work")
        completion_issues+=("FIX: Install bash-completion package (dnf/apt/yum install bash-completion)")
        status=$HEALTH_WARNING
    else
        # Check if NFTBAN completion file is installed
        local nftban_completion="/usr/share/bash-completion/completions/nftban"
        if [[ ! -f "$nftban_completion" ]]; then
            # Try to auto-install if auto-heal enabled
            if [[ "${NFTBAN_HEALTH_AUTO_HEAL:-false}" == "true" ]]; then
                # Try to find source file
                local completion_src=""
                for dir in "/home/gituser/github/nftban-dev" "/usr/src/nftban" "/opt/nftban"; do
                    if [[ -f "$dir/install/bash-completion/nftban" ]]; then
                        completion_src="$dir/install/bash-completion/nftban"
                        break
                    fi
                done

                if [[ -n "$completion_src" && -f "$completion_src" ]]; then
                    mkdir -p "$(dirname "$nftban_completion")"
                    if cp "$completion_src" "$nftban_completion"; then
                        chmod 644 "$nftban_completion"
                        completion_issues+=("Bash completion was missing - AUTO-HEALED: installed")
                        status=$HEALTH_WARNING
                    else
                        completion_issues+=("NFTBAN bash completion file missing at $nftban_completion")
                        completion_issues+=("AUTO-HEAL FAILED: Could not copy file")
                        status=$HEALTH_WARNING
                    fi
                else
                    completion_issues+=("NFTBAN bash completion file missing at $nftban_completion")
                    completion_issues+=("AUTO-HEAL FAILED: Source file not found")
                    completion_issues+=("FIX: sudo cp install/bash-completion/nftban /usr/share/bash-completion/completions/nftban")
                    status=$HEALTH_WARNING
                fi
            else
                completion_issues+=("NFTBAN bash completion file missing at $nftban_completion")
                completion_issues+=("FIX: sudo cp install/bash-completion/nftban /usr/share/bash-completion/completions/nftban")
                status=$HEALTH_WARNING
            fi
        else
            # Verify file is readable
            if [[ ! -r "$nftban_completion" ]]; then
                completion_issues+=("NFTBAN completion file exists but is not readable")
                status=$HEALTH_WARNING
            fi
        fi
    fi

    # Store results
    if [[ ${#completion_issues[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["bash_completion"]="${completion_issues[*]}"
        if [[ $status -eq $HEALTH_ERROR ]]; then
            NFTBAN_HEALTH_ERRORS+=("Bash completion issues: ${completion_issues[*]}")
        else
            NFTBAN_HEALTH_WARNINGS+=("Bash completion issues: ${completion_issues[*]}")
        fi
    fi

    NFTBAN_HEALTH_RESULTS["bash_completion"]=$status
    return $status
}

# Removed: fail2ban health check (v1.0 migration to Suricata)

# =============================================================================
# METRICS INTEGRATION CHECK (v0.6.0)
# =============================================================================

nftban_health_check_metrics() {
    # Check Prometheus/Grafana metrics integration (NFTBan v0.6.0)
    # Returns: 0=OK, 1=WARNING, 2=ERROR, 3=CRITICAL
    # Uses central config: NFTBAN_METRICS_ENABLED, NFTBAN_METRICS_BACKEND

    local status=$HEALTH_OK
    local metrics_issues=()

    # Check if metrics exporter script exists (determine if metrics are installable)
    local exporter_installed=false
    if [[ -f "${NFTBAN_LIB_DIR}/exporters/nftban_prometheus_exporter.sh" ]]; then
        exporter_installed=true
    fi

    # Check central config - if metrics disabled, report appropriately
    if [[ "${NFTBAN_METRICS_ENABLED:-false}" != "true" ]]; then
        if [[ "$exporter_installed" == "true" ]]; then
            # Installed but disabled by user choice
            NFTBAN_HEALTH_ISSUES["metrics"]="Disabled (set NFTBAN_METRICS_ENABLED=true to enable)"
            NFTBAN_HEALTH_RESULTS["metrics"]=$HEALTH_DISABLED
            return $HEALTH_DISABLED
        else
            # Not installed (optional feature)
            NFTBAN_HEALTH_ISSUES["metrics"]="Not installed (optional feature)"
            NFTBAN_HEALTH_RESULTS["metrics"]=$HEALTH_NOT_INSTALLED
            return $HEALTH_NOT_INSTALLED
        fi
    fi

    # Check if metrics exporter script exists
    if [[ ! -f "${NFTBAN_LIB_DIR}/exporters/nftban_prometheus_exporter.sh" ]]; then
        metrics_issues+=("Metrics exporter not installed (optional)")
        NFTBAN_HEALTH_ISSUES["metrics"]="Not installed (optional feature)"
        return $HEALTH_NOT_INSTALLED
    fi

    # Check if exporter script is executable
    if [[ ! -x "${NFTBAN_LIB_DIR}/exporters/nftban_prometheus_exporter.sh" ]]; then
        metrics_issues+=("Metrics exporter not executable")
        metrics_issues+=("FIX: sudo chmod +x ${NFTBAN_LIB_DIR}/exporters/nftban_prometheus_exporter.sh")
        status=$HEALTH_ERROR
    fi

    # Check pipeline validation library (watchdog capability detection)
    if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_pipeline_validation.sh" ]]; then
        metrics_issues+=("✓ Pipeline validation library: Installed")
        # Test if it can be sourced
        if bash -n "${NFTBAN_LIB_DIR}/lib/nftban_pipeline_validation.sh" 2>/dev/null; then
            metrics_issues+=("✓ Pipeline validation library: Syntax OK")
        else
            metrics_issues+=("Pipeline validation library has syntax errors")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi
    else
        metrics_issues+=("ℹ️ Pipeline validation library not installed (optional for watchdog)")
    fi

    # Check if metrics file exists and is recent (PRIMARY CHECK)
    local metrics_file="/var/lib/node_exporter/textfile_collector/nftban.prom"
    if [[ -f "$metrics_file" ]]; then
        local file_age
        file_age=$(( $(date +%s) - $(stat -c %Y "$metrics_file" 2>/dev/null || stat -f %m "$metrics_file" 2>/dev/null || echo 0) ))

        if [[ $file_age -lt 120 ]]; then
            metrics_issues+=("✓ Metrics exporter: Working (file ${file_age}s old)")
            # Exporter is working - check timer status
            if systemctl is-active --quiet nftban-metrics-exporter.timer 2>/dev/null; then
                metrics_issues+=("✓ Metrics timer: Active")
            else
                metrics_issues+=("⚠ Metrics timer not active (but exporter is working)")
                [[ $status -eq $HEALTH_OK ]] && status=$HEALTH_WARNING
            fi
        elif [[ $file_age -lt 300 ]]; then
            metrics_issues+=("⚠ Metrics file is ${file_age}s old (may be stale)")
            [[ $status -eq $HEALTH_OK ]] && status=$HEALTH_WARNING
        else
            metrics_issues+=("Metrics file is stale (${file_age}s old)")
            metrics_issues+=("Exporter may not be running or timer is disabled")
            [[ $status -lt $HEALTH_ERROR ]] && status=$HEALTH_ERROR
        fi
    else
        # No metrics file - check if timer exists
        if systemctl list-unit-files 2>/dev/null | grep -q "nftban-metrics-exporter.timer"; then
            if systemctl is-active --quiet nftban-metrics-exporter.timer 2>/dev/null; then
                metrics_issues+=("Metrics timer active but no metrics file yet (may be first run)")
                status=$HEALTH_WARNING
            else
                metrics_issues+=("Metrics timer exists but not running")
                metrics_issues+=("FIX: sudo systemctl enable --now nftban-metrics-exporter.timer")
                status=$HEALTH_ERROR
            fi
        else
            metrics_issues+=("Metrics timer not installed")
            metrics_issues+=("FIX: sudo ./install.sh systemd")
            status=$HEALTH_ERROR
        fi
    fi

    # Check Node Exporter (OPTIONAL - only needed for Prometheus scraping)
    # Binary name varies: node_exporter (CentOS/Debian) or prometheus-node-exporter (some RHEL)
    # Service name varies: node_exporter, prometheus-node-exporter, or node-exporter
    local node_exporter_running=false
    if command -v node_exporter >/dev/null 2>&1 || command -v prometheus-node-exporter >/dev/null 2>&1; then
        # Check all possible service names
        if systemctl is-active --quiet node_exporter 2>/dev/null || \
           systemctl is-active --quiet prometheus-node-exporter 2>/dev/null || \
           systemctl is-active --quiet node-exporter 2>/dev/null; then
            metrics_issues+=("✓ Node Exporter: Running")
            # shellcheck disable=SC2034  # Reserved for metrics validation
            node_exporter_running=true
        else
            metrics_issues+=("ℹ️ Node Exporter installed but not running (optional - for Prometheus)")
        fi
    else
        # Not installed - this is OK, it's optional
        metrics_issues+=("ℹ️ Node Exporter not installed (optional - only needed for Prometheus scraping)")
    fi

    # Check Prometheus or VictoriaMetrics (optional alternatives - only one needed)
    # Only warn about unconfigured backend if it's the one selected in config
    local configured_backend="${NFTBAN_METRICS_BACKEND:-prometheus}"

    # Check Prometheus (only warn if it's the configured backend)
    if command -v prometheus >/dev/null 2>&1 || systemctl list-unit-files 2>/dev/null | grep -q "^prometheus.service"; then
        if systemctl is-active --quiet prometheus 2>/dev/null; then
            metrics_issues+=("✓ Prometheus: Running")

            # Check if Prometheus is accessible
            if command -v curl >/dev/null 2>&1; then
                if curl -s --connect-timeout "${NFTBAN_TIMEOUT_FAST}" "http://${NFTBAN_METRICS_PROMETHEUS_ADDR}/-/healthy" >/dev/null 2>&1; then
                    metrics_issues+=("✓ Prometheus: Healthy")
                else
                    metrics_issues+=("Prometheus not responding on ${NFTBAN_METRICS_PROMETHEUS_ADDR}")
                    [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
                fi
            fi
        else
            # Only warn if prometheus is the configured backend
            if [[ "$configured_backend" == "prometheus" ]]; then
                metrics_issues+=("Prometheus installed but not running")
                [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
            fi
        fi
    fi

    # Check VictoriaMetrics (alternative to Prometheus)
    if command -v victoria-metrics >/dev/null 2>&1 || systemctl list-unit-files 2>/dev/null | grep -q "^victoria-metrics.service"; then
        if systemctl is-active --quiet victoria-metrics 2>/dev/null; then
            metrics_issues+=("✓ VictoriaMetrics: Running")

            # Check if VictoriaMetrics is accessible
            if command -v curl >/dev/null 2>&1; then
                if curl -s --connect-timeout "${NFTBAN_TIMEOUT_FAST}" "http://${NFTBAN_METRICS_VICTORIA_ADDR}/metrics" >/dev/null 2>&1; then
                    metrics_issues+=("✓ VictoriaMetrics: Healthy")
                else
                    metrics_issues+=("VictoriaMetrics not responding on ${NFTBAN_METRICS_VICTORIA_ADDR}")
                    [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
                fi
            fi
        else
            # Only warn if victoriametrics is the configured backend
            if [[ "$configured_backend" == "victoriametrics" ]]; then
                metrics_issues+=("VictoriaMetrics installed but not running")
                [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
            fi
        fi
    fi

    # Check Grafana (optional)
    if command -v grafana-server >/dev/null 2>&1 || systemctl list-unit-files | grep -q "grafana-server"; then
        if systemctl is-active --quiet grafana-server 2>/dev/null; then
            metrics_issues+=("✓ Grafana: Running")
        else
            metrics_issues+=("Grafana installed but not running")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi
    fi

    # Check Bandwidth Exporter (v0.6 GUI redesign)
    if [[ -f "${NFTBAN_LIB_DIR}/exporters/nftban_bandwidth_exporter.sh" ]]; then
        # Check if bandwidth exporter timer is enabled
        if systemctl list-unit-files | grep -q "nftban-bandwidth-exporter.timer"; then
            if systemctl is-enabled --quiet nftban-bandwidth-exporter.timer 2>/dev/null; then
                if systemctl is-active --quiet nftban-bandwidth-exporter.timer; then
                    metrics_issues+=("✓ Bandwidth exporter timer: Active")
                else
                    metrics_issues+=("Bandwidth exporter timer not running")
                    [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
                fi
            else
                metrics_issues+=("Bandwidth exporter timer not enabled")
                [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
            fi
        else
            metrics_issues+=("Bandwidth exporter timer not installed")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi

        # Check if bandwidth metrics file exists and is recent
        local bandwidth_metrics_file="/var/lib/node_exporter/textfile_collector/nftban_bandwidth.prom"
        if [[ -f "$bandwidth_metrics_file" ]]; then
            local file_age
            file_age=$(( $(date +%s) - $(stat -c %Y "$bandwidth_metrics_file" 2>/dev/null || stat -f %m "$bandwidth_metrics_file" 2>/dev/null || echo 0) ))

            if [[ $file_age -lt 30 ]]; then
                metrics_issues+=("✓ Bandwidth metrics: Fresh (${file_age}s old)")
            elif [[ $file_age -lt 60 ]]; then
                metrics_issues+=("Bandwidth metrics ${file_age}s old (may be stale)")
                [[ $status -eq $HEALTH_OK ]] && status=$HEALTH_WARNING
            else
                # Bandwidth exporter is optional - only WARNING, not ERROR
                metrics_issues+=("⚠ Bandwidth metrics stale (${file_age}s old)")
                [[ $status -eq $HEALTH_OK ]] && status=$HEALTH_WARNING
            fi
        else
            metrics_issues+=("ℹ️ Bandwidth metrics file not found (optional - exporter may not have run yet)")
            # Don't upgrade status for missing optional component
        fi
    fi

    # Store results (format metrics issues as separate lines)
    NFTBAN_HEALTH_RESULTS["metrics"]=$status
    if [[ ${#metrics_issues[@]} -gt 0 ]]; then
        # Join array elements with newlines and proper indentation
        local formatted_issues=""
        for issue in "${metrics_issues[@]}"; do
            if [[ -z "$formatted_issues" ]]; then
                formatted_issues="$issue"
            else
                formatted_issues="${formatted_issues}
     ${issue}"
            fi
        done
        NFTBAN_HEALTH_ISSUES["metrics"]="$formatted_issues"
    fi

    return $status
}

# =============================================================================
# PRO SUBSCRIPTION CHECK (v1.0.0)
# =============================================================================

nftban_health_check_pro() {
    # Check NFTBan Pro subscription health
    # Returns: 0=OK, 1=WARNING, 2=ERROR, 3=CRITICAL, 4=NOT_INSTALLED
    #
    # Validates:
    #   - Pro enabled in config
    #   - Token file exists with secure permissions
    #   - vmagent running (if Pro mode enabled)
    #   - Server ID exists

    local status=$HEALTH_OK
    local pro_issues=()

    # Check if Pro is enabled in config
    if [[ "${NFTBAN_PRO_ENABLED:-false}" != "true" ]]; then
        NFTBAN_HEALTH_ISSUES["pro"]="Disabled in config (run 'nftban pro enroll' to enable)"
        NFTBAN_HEALTH_RESULTS["pro"]=$HEALTH_NOT_INSTALLED
        return $HEALTH_NOT_INSTALLED
    fi

    pro_issues+=("✓ Pro subscription: Enabled")

    # Check token file exists
    local token_file="${NFTBAN_PRO_TOKEN_FILE:-/etc/nftban/pro.token}"
    if [[ ! -f "$token_file" ]]; then
        pro_issues+=("Token file missing: $token_file")
        pro_issues+=("FIX: Run 'nftban pro enroll' to set up token")
        status=$HEALTH_ERROR
    else
        pro_issues+=("✓ Token file: Present")

        # Check token file permissions (must be 0600 or 0640)
        local token_perms
        token_perms=$(stat -c %a "$token_file" 2>/dev/null || stat -f %Lp "$token_file" 2>/dev/null || echo "???")

        if [[ "$token_perms" == "600" || "$token_perms" == "640" ]]; then
            pro_issues+=("✓ Token permissions: $token_perms (secure)")
        else
            pro_issues+=("Token file has insecure permissions: $token_perms")
            pro_issues+=("FIX: sudo chmod 600 $token_file")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi

        # Check token file ownership (must be root:root or root:nftban)
        local token_owner token_group
        token_owner=$(stat -c %U "$token_file" 2>/dev/null || stat -f %Su "$token_file" 2>/dev/null || echo "???")
        token_group=$(stat -c %G "$token_file" 2>/dev/null || stat -f %Sg "$token_file" 2>/dev/null || echo "???")

        if [[ "$token_owner" == "root" ]]; then
            if [[ "$token_group" == "root" || "$token_group" == "nftban" ]]; then
                pro_issues+=("✓ Token ownership: ${token_owner}:${token_group}")
            else
                pro_issues+=("Token file has incorrect group: $token_group (expected root or nftban)")
                pro_issues+=("FIX: sudo chown root:nftban $token_file")
                [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
            fi
        else
            pro_issues+=("Token file has incorrect owner: $token_owner (expected root)")
            pro_issues+=("FIX: sudo chown root:root $token_file")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi

        # Check token is not empty
        if [[ ! -s "$token_file" ]]; then
            pro_issues+=("Token file is empty")
            pro_issues+=("FIX: Run 'nftban pro enroll' to configure token")
            [[ $status -lt $HEALTH_ERROR ]] && status=$HEALTH_ERROR
        fi
    fi

    # Check server ID file
    local server_id_file="${NFTBAN_PRO_SERVER_ID_FILE:-/etc/nftban/server_id}"
    if [[ -f "$server_id_file" ]]; then
        if [[ -s "$server_id_file" ]]; then
            local server_id
            server_id=$(head -1 "$server_id_file" 2>/dev/null || echo "")
            if [[ -n "$server_id" ]]; then
                pro_issues+=("✓ Server ID: ${server_id:0:8}...")
            else
                pro_issues+=("Server ID file exists but is empty")
                [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
            fi
        else
            pro_issues+=("Server ID file is empty")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi
    else
        pro_issues+=("Server ID not generated")
        pro_issues+=("FIX: Server ID will be generated on next 'nftban pro enroll'")
        [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
    fi

    # Check vmagent is running (Pro mode requires remote_write agent)
    if systemctl is-active --quiet vmagent 2>/dev/null; then
        pro_issues+=("✓ vmagent: Running")

        # Check vmagent config points to Pro endpoint
        local vmagent_config="/etc/victoriametrics/vmagent.yml"
        if [[ -f "$vmagent_config" ]]; then
            if grep -q "pro.nftban.com" "$vmagent_config" 2>/dev/null; then
                pro_issues+=("✓ vmagent config: Pro endpoint configured")
            else
                pro_issues+=("vmagent config does not point to Pro endpoint")
                pro_issues+=("FIX: Run 'nftban metrics enable --pro' to reconfigure")
                [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
            fi
        fi
    elif systemctl list-unit-files 2>/dev/null | grep -q "^vmagent.service"; then
        pro_issues+=("vmagent installed but not running")
        pro_issues+=("FIX: sudo systemctl enable --now vmagent")
        [[ $status -lt $HEALTH_ERROR ]] && status=$HEALTH_ERROR
    else
        pro_issues+=("vmagent not installed (required for Pro metrics)")
        pro_issues+=("FIX: Run 'nftban metrics enable --pro' to install vmagent")
        [[ $status -lt $HEALTH_ERROR ]] && status=$HEALTH_ERROR
    fi

    # Check Pro timers are enabled
    local pro_timers=("nftban-pro-license.timer" "nftban-pro-inventory.timer")
    for timer in "${pro_timers[@]}"; do
        if systemctl is-active --quiet "$timer" 2>/dev/null; then
            pro_issues+=("✓ ${timer}: Active")
        elif systemctl list-unit-files 2>/dev/null | grep -q "^${timer}"; then
            pro_issues+=("${timer} exists but not active")
            pro_issues+=("FIX: sudo systemctl enable --now $timer")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        else
            pro_issues+=("${timer} not installed")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi
    done

    # Store results
    NFTBAN_HEALTH_RESULTS["pro"]=$status
    if [[ ${#pro_issues[@]} -gt 0 ]]; then
        local formatted_issues=""
        for issue in "${pro_issues[@]}"; do
            if [[ -z "$formatted_issues" ]]; then
                formatted_issues="$issue"
            else
                formatted_issues="${formatted_issues}
     ${issue}"
            fi
        done
        NFTBAN_HEALTH_ISSUES["pro"]="$formatted_issues"
    fi

    return $status
}

# =============================================================================
# GUI (WEB UI) CHECK (v0.6.0)
# =============================================================================

nftban_health_check_gui() {
    # Check NFTBan Web UI (nftban-ui) health and binary deployment
    # Returns: 0=OK, 1=WARNING, 2=ERROR, 3=CRITICAL
    # Auto-heal: Rebuild binary if outdated, restart service if crashed

    local status=$HEALTH_OK
    local gui_issues=()
    local auto_heal="${1:-0}"

    # Check if GUI is installed
    local gui_binary="/usr/sbin/nftban-ui"
    local gui_source_dir="${NFTBAN_DEV_SOURCE_DIR:-}/cmd/nftban-ui"
    local build_binary="$gui_source_dir/nftban-ui"

    if [[ ! -f "$gui_binary" ]]; then
        gui_issues+=("GUI binary not found at $gui_binary")
        status=$HEALTH_CRITICAL

        if [[ $auto_heal -eq 1 ]]; then
            echo "  🔧 Auto-heal: Building and installing GUI binary..."
            if [[ -d "$gui_source_dir" ]]; then
                (
                    cd "$gui_source_dir" || exit 1
                    CGO_ENABLED=1 GOOS=linux GOARCH=amd64 go build -o "$build_binary" . 2>&1
                    cp -f "$build_binary" "$gui_binary" 2>&1
                    chmod +x "$gui_binary" 2>&1
                ) && gui_issues+=("✓ GUI binary built and installed") || gui_issues+=("Failed to build GUI binary")
            else
                gui_issues+=("GUI source directory not found: $gui_source_dir")
            fi
        fi
    else
        # Check if binary is executable
        if [[ ! -x "$gui_binary" ]]; then
            gui_issues+=("GUI binary not executable")
            status=$HEALTH_ERROR

            if [[ $auto_heal -eq 1 ]]; then
                echo "  🔧 Auto-heal: Making GUI binary executable..."
                chmod +x "$gui_binary" && gui_issues+=("✓ Fixed GUI binary permissions")
            fi
        else
            gui_issues+=("✓ GUI binary: Installed and executable")
        fi

        # Check if binary is up-to-date (compare with build directory)
        if [[ -f "$build_binary" ]]; then
            local installed_md5 built_md5
            installed_md5=$(md5sum "$gui_binary" 2>/dev/null | awk '{print $1}')
            built_md5=$(md5sum "$build_binary" 2>/dev/null | awk '{print $1}')

            if [[ "$installed_md5" != "$built_md5" ]]; then
                gui_issues+=("Web UI binary outdated (needs reinstall)")
                gui_issues+=("ℹ️  To update: Rebuild with './build.sh' then restart service")
                [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING

                if [[ $auto_heal -eq 1 ]]; then
                    echo "  🔧 Auto-heal: Updating GUI binary from build directory..."
                    cp -f "$build_binary" "$gui_binary" 2>&1 && \
                    chmod +x "$gui_binary" 2>&1 && \
                    gui_issues+=("✓ GUI binary updated from build directory")
                fi
            else
                gui_issues+=("✓ GUI binary: Up-to-date")
            fi
        elif [[ -d "$gui_source_dir" ]]; then
            # Build binary doesn't exist but installed binary is working - this is OK
            # The build directory may exist on servers with dev repo but binary was deployed via rsync/install
            gui_issues+=("✓ GUI binary: Installed (build directory present but binary not built locally)")
        fi
    fi

    # Check if GUI service exists (check both systemctl and service files)
    local service_exists=false
    if systemctl list-unit-files | grep -q "${NFTBAN_SERVICE_UI:-nftban-ui.service}" 2>/dev/null; then
        service_exists=true
    elif [[ -f "/etc/systemd/system/${NFTBAN_SERVICE_UI:-nftban-ui.service}" ]] || [[ -f "/usr/lib/systemd/system/${NFTBAN_SERVICE_UI:-nftban-ui.service}" ]]; then
        service_exists=true
    fi

    if [[ "$service_exists" == "false" ]]; then
        gui_issues+=("Web UI not enabled (OPTIONAL)")
        gui_issues+=("ℹ️  To enable: Run 'nftban ui init' then 'nftban ui start'")
        # GUI is OPTIONAL - only set WARNING if binary exists (partially installed)
        # If binary doesn't exist either, keep status OK (not installed = OK for optional feature)
        if [[ -f "$gui_binary" ]]; then
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi
    else
        # Check if service is enabled
        if systemctl is-enabled --quiet ${NFTBAN_SERVICE_UI:-nftban-ui.service} 2>/dev/null; then
            gui_issues+=("✓ GUI service: Enabled")
        else
            gui_issues+=("Web UI service not enabled (OPTIONAL)")
            gui_issues+=("ℹ️  To enable: Run 'systemctl enable nftban-ui'")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING

            if [[ $auto_heal -eq 1 ]]; then
                echo "  🔧 Auto-heal: Enabling GUI service..."
                systemctl enable ${NFTBAN_SERVICE_UI:-nftban-ui.service} 2>&1 && gui_issues+=("✓ GUI service enabled")
            fi
        fi

        # Check if service is running
        if systemctl is-active --quiet ${NFTBAN_SERVICE_UI:-nftban-ui.service} 2>/dev/null; then
            gui_issues+=("✓ GUI service: Running")

            # Check if GUI is accessible
            local gui_addr="${NFTBAN_GUI_ADDR:-127.0.0.1:3940}"
            if command -v curl >/dev/null 2>&1; then
                if timeout "${NFTBAN_TIMEOUT_FAST}" curl -k -s "https://${gui_addr}/" >/dev/null 2>&1; then
                    gui_issues+=("✓ GUI: Accessible on https://${gui_addr}")
                else
                    gui_issues+=("GUI not responding on https://${gui_addr}")
                    [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
                fi
            fi
        else
            gui_issues+=("Web UI service not running (OPTIONAL)")
            gui_issues+=("ℹ️  To start: Run 'nftban ui start'")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING

            if [[ $auto_heal -eq 1 ]]; then
                echo "  🔧 Auto-heal: Starting GUI service..."
                systemctl start ${NFTBAN_SERVICE_UI:-nftban-ui.service} 2>&1 && \
                sleep 2 && \
                systemctl is-active --quiet ${NFTBAN_SERVICE_UI:-nftban-ui.service} 2>/dev/null && \
                gui_issues+=("✓ GUI service started") || gui_issues+=("Failed to start GUI service")
            fi
        fi

        # Check service status for errors
        if systemctl is-failed --quiet ${NFTBAN_SERVICE_UI:-nftban-ui.service} 2>/dev/null; then
            gui_issues+=("GUI service in failed state")
            [[ $status -lt $HEALTH_CRITICAL ]] && status=$HEALTH_CRITICAL

            if [[ $auto_heal -eq 1 ]]; then
                echo "  🔧 Auto-heal: Resetting failed GUI service..."
                systemctl reset-failed ${NFTBAN_SERVICE_UI:-nftban-ui.service} 2>&1
                systemctl restart ${NFTBAN_SERVICE_UI:-nftban-ui.service} 2>&1 && \
                sleep 2 && \
                systemctl is-active --quiet ${NFTBAN_SERVICE_UI:-nftban-ui.service} 2>/dev/null && \
                gui_issues+=("✓ GUI service restarted") || gui_issues+=("Failed to restart GUI service")
            fi
        fi
    fi

    # ==========================================================================
    # GUI-AUTH: Check auth socket and directory permissions
    # ==========================================================================
    # The nftban-ui service (runs as 'nftban' user) must be able to connect
    # to /run/nftban-ui/auth.sock (created by nftban-ui-auth as root)
    # Directory must be root:nftban 750, socket must be root:nftban 770
    local auth_socket_dir="/run/nftban-ui"
    local auth_socket="${auth_socket_dir}/auth.sock"

    if [[ -d "$auth_socket_dir" ]]; then
        # Check directory ownership (must be root:nftban for nftban user access)
        local dir_owner dir_group
        dir_owner=$(stat -c '%U' "$auth_socket_dir" 2>/dev/null)
        dir_group=$(stat -c '%G' "$auth_socket_dir" 2>/dev/null)

        if [[ "$dir_group" != "nftban" ]]; then
            gui_issues+=("GUI-AUTH: Auth socket directory has wrong group: ${dir_owner}:${dir_group} (should be root:nftban)")
            [[ $status -lt $HEALTH_ERROR ]] && status=$HEALTH_ERROR

            if [[ $auto_heal -eq 1 ]]; then
                echo "  🔧 Auto-heal: Fixing auth socket directory permissions..."
                chown root:nftban "$auth_socket_dir" 2>&1 && \
                chmod 750 "$auth_socket_dir" 2>&1 && \
                gui_issues+=("✓ GUI-AUTH: Fixed directory permissions")
            fi
        else
            gui_issues+=("✓ GUI-AUTH: Socket directory permissions OK (${dir_owner}:${dir_group})")
        fi

        # Check socket exists and has correct ownership
        if [[ -S "$auth_socket" ]]; then
            local sock_owner sock_group
            sock_owner=$(stat -c '%U' "$auth_socket" 2>/dev/null)
            sock_group=$(stat -c '%G' "$auth_socket" 2>/dev/null)

            if [[ "$sock_group" != "nftban" ]]; then
                gui_issues+=("GUI-AUTH: Auth socket has wrong group: ${sock_owner}:${sock_group} (should be root:nftban)")
                [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
            else
                gui_issues+=("✓ GUI-AUTH: Socket permissions OK (${sock_owner}:${sock_group})")
            fi
        else
            # Socket doesn't exist - check if auth service is running
            if systemctl is-active --quiet nftban-ui-auth.service 2>/dev/null; then
                gui_issues+=("GUI-AUTH: Auth service running but socket missing")
                [[ $status -lt $HEALTH_ERROR ]] && status=$HEALTH_ERROR
            fi
        fi
    elif systemctl is-active --quiet ${NFTBAN_SERVICE_UI:-nftban-ui.service} 2>/dev/null; then
        # GUI running but auth directory doesn't exist
        gui_issues+=("GUI-AUTH: Auth socket directory missing (/run/nftban-ui)")
        gui_issues+=("ℹ️  Restart auth service: systemctl restart nftban-ui-auth")
        [[ $status -lt $HEALTH_ERROR ]] && status=$HEALTH_ERROR
    fi

    # Check GUI log file for recent errors (last 50 lines)
    if [[ -f "/var/log/nftban-ui.log" ]]; then
        local error_count
        error_count=$(tail -n 50 /var/log/nftban-ui.log 2>/dev/null | grep -c "ERROR\|FATAL\|panic" || echo 0)

        if [[ $error_count -gt 0 ]]; then
            gui_issues+=("Found $error_count errors in recent GUI logs")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi
    fi

    # Store results
    NFTBAN_HEALTH_RESULTS["gui"]=$status
    NFTBAN_HEALTH_ISSUES["gui"]="${gui_issues[*]}"

    return $status
}

# =============================================================================
# CLI ERROR LOG CHECK
# =============================================================================

nftban_health_check_cli_errors() {
    # Check CLI error log for recent errors
    # Returns: 0=OK, 1=Warnings, 2=Errors

    local status=$HEALTH_OK
    local -a cli_issues=()

    local cli_error_log="${NFTBAN_LOG_DIR}/cli-errors.log"

    # Check if log file exists
    if [[ ! -f "$cli_error_log" ]]; then
        cli_issues+=("✓ No CLI errors logged (log file doesn't exist)")
        NFTBAN_HEALTH_RESULTS["cli_errors"]=$status
        NFTBAN_HEALTH_ISSUES["cli_errors"]="${cli_issues[*]}"
        return $status
    fi

    # Check file size
    local log_size
    log_size=$(stat -f%z "$cli_error_log" 2>/dev/null || stat -c%s "$cli_error_log" 2>/dev/null || echo 0)

    if [[ $log_size -eq 0 ]]; then
        cli_issues+=("✓ No CLI errors logged (empty log)")
        NFTBAN_HEALTH_RESULTS["cli_errors"]=$status
        NFTBAN_HEALTH_ISSUES["cli_errors"]="${cli_issues[*]}"
        return $status
    fi

    # Check for recent errors (last 24 hours)
    local recent_errors=0
    local cutoff_time
    cutoff_time=$(date -d "24 hours ago" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -v-24H '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")

    if [[ -n "$cutoff_time" ]]; then
        # Count errors in last 24 hours
        while IFS= read -r line; do
            if [[ "$line" =~ ERROR:\ ([0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
                local error_time="${BASH_REMATCH[1]}"
                if [[ "$error_time" > "$cutoff_time" ]]; then
                    ((recent_errors++)) || true
                fi
            fi
        done < "$cli_error_log"
    else
        # Fallback: count all ERROR lines
        recent_errors=$(grep -c "^ERROR:" "$cli_error_log" 2>/dev/null || echo 0)
    fi

    # Evaluate error count
    if [[ $recent_errors -eq 0 ]]; then
        cli_issues+=("✓ No recent CLI errors")
    elif [[ $recent_errors -lt 5 ]]; then
        cli_issues+=("Found $recent_errors CLI error(s) in last 24 hours")
        status=$HEALTH_WARNING
    elif [[ $recent_errors -lt 20 ]]; then
        cli_issues+=("Found $recent_errors CLI errors in last 24 hours - investigate")
        status=$HEALTH_ERROR
    else
        cli_issues+=("CRITICAL: $recent_errors CLI errors in last 24 hours")
        status=$HEALTH_CRITICAL
    fi

    # Check log size (warn if > 10MB)
    local log_size_mb
    log_size_mb=$((log_size / 1024 / 1024))
    if [[ $log_size_mb -gt 10 ]]; then
        cli_issues+=("CLI error log is ${log_size_mb}MB - consider rotation")
        [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
    fi

    # Store results
    NFTBAN_HEALTH_RESULTS["cli_errors"]=$status
    NFTBAN_HEALTH_ISSUES["cli_errors"]="${cli_issues[*]}"

    return $status
}

nftban_health_check_rbl() {
    # Check RBL monitoring status (v1.0.24)
    # Returns: 0=OK, 1=WARNING, 2=ERROR
    # Checks: enabled status, last check time, blacklist status

    local status=$HEALTH_OK
    local rbl_issues=()

    # Load RBL configuration
    local rbl_config="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/rbl/main.conf"
    local rbl_cache_dir="${NFTBAN_LOG_DIR:-/var/log/nftban}/rbl"

    # Check if RBL is enabled
    local rbl_enabled="NO"
    if [[ -f "$rbl_config" ]]; then
        rbl_enabled=$(grep -E "^NFTBAN_RBL_ENABLED=" "$rbl_config" 2>/dev/null | cut -d'"' -f2 || echo "NO")
    fi

    if [[ "$rbl_enabled" != "YES" ]]; then
        rbl_issues+=("RBL monitoring disabled (optional)")
        # Not an error - just informational
        NFTBAN_HEALTH_RESULTS["rbl"]=$HEALTH_OK
        NFTBAN_HEALTH_ISSUES["rbl"]="RBL monitoring disabled (enable in $rbl_config)"
        return $HEALTH_OK
    fi

    # Check last check time
    local last_check_file="${rbl_cache_dir}/last_check"
    if [[ -f "$last_check_file" ]]; then
        local last_check
        last_check=$(cat "$last_check_file" 2>/dev/null)
        local last_check_epoch
        last_check_epoch=$(date -d "$last_check" +%s 2>/dev/null || echo 0)
        local now_epoch
        now_epoch=$(date +%s)
        local hours_ago=$(( (now_epoch - last_check_epoch) / 3600 ))

        if [[ $hours_ago -gt 48 ]]; then
            rbl_issues+=("Last RBL check was ${hours_ago}h ago (stale)")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi
    else
        rbl_issues+=("RBL check never run")
        [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
    fi

    # Check for blacklisted IPs in state file
    local state_file="${rbl_cache_dir}/state.json"
    if [[ -f "$state_file" ]]; then
        if grep -q '"listed"' "$state_file" 2>/dev/null; then
            rbl_issues+=("Server IP(s) currently BLACKLISTED on RBLs!")
            status=$HEALTH_ERROR
            NFTBAN_HEALTH_ERRORS+=("RBL: Server IP blacklisted - run 'nftban rbl check' for details")
        fi
    fi

    # Check RBL timer status
    if systemctl is-enabled nftban-rbl-check.timer &>/dev/null; then
        if ! systemctl is-active nftban-rbl-check.timer &>/dev/null; then
            rbl_issues+=("RBL timer enabled but not active")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi
    else
        rbl_issues+=("RBL timer not enabled (run: nftban rbl enable)")
        [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
    fi

    # Store results
    NFTBAN_HEALTH_RESULTS["rbl"]=$status
    if [[ ${#rbl_issues[@]} -eq 0 ]]; then
        NFTBAN_HEALTH_ISSUES["rbl"]="RBL monitoring active, no blacklistings"
    else
        NFTBAN_HEALTH_ISSUES["rbl"]="${rbl_issues[*]}"
    fi

    return $status
}

nftban_health_check_timers() {
    # Check all NFTBan systemd timers (v0.7.3)
    # Returns: 0=OK, 1=WARNING, 2=ERROR, 3=CRITICAL
    # Args: $1 = auto_heal (0=check only, 1=auto-fix)

    local auto_heal="${1:-0}"
    local status=$HEALTH_OK
    local timer_issues=()

    # Core NFTBan timers (REQUIRED - always enabled)
    local -a timers=(
        "nftban-maintenance.timer"      # CRITICAL: SSH/IP protection, auto-heal
        "nftban-health.timer"           # Health checks
        "nftban-core-geoip.timer"       # GeoIP updates
        "nftban-queue.timer"            # Ban queue processing
    )

    # Optional timers (only enabled when feature is configured)
    # These are not checked by default - only if the feature is enabled
    # shellcheck disable=SC2034
    local -a optional_timers=(
        "nftban-watchdog.timer"         # System resource monitoring (nftban watchdog enable)
        "nftban-core-feeds.timer"       # Threat feeds sync (nftban feeds enable)
        "nftban-metrics-exporter.timer" # Prometheus metrics (nftban metrics enable)
        "nftban-suricata-update.timer"  # Suricata rules (needs suricata)
        "nftban-snapshot.timer"         # Firewall snapshots
        "nftban-rollback.timer"         # Auto-rollback checks
    )

    local -A timer_desc=(
        ["nftban-maintenance.timer"]="CRITICAL: SSH/IP lockout prevention, auto-heal"
        ["nftban-health.timer"]="Health checks and auto-heal"
        ["nftban-core-feeds.timer"]="Threat feeds sync"
        ["nftban-core-geoip.timer"]="GeoIP database updates"
        ["nftban-queue.timer"]="Ban queue processing"
        ["nftban-watchdog.timer"]="System resource monitoring"
        ["nftban-metrics-exporter.timer"]="Prometheus metrics collection"
        ["nftban-suricata-update.timer"]="Suricata rules update (optional)"
        ["nftban-snapshot.timer"]="Firewall snapshot creation (optional)"
        ["nftban-rollback.timer"]="Auto-rollback checks (optional)"
    )

    local total=0
    local enabled=0
    local active=0
    local missing=0
    local disabled=0

    # Check each timer
    for timer in "${timers[@]}"; do
        total=$((total + 1))

        # Check if timer unit file exists
        if ! systemctl list-unit-files "$timer" --no-legend 2>/dev/null | grep -q "^$timer"; then
            timer_issues+=("⚠ $timer not installed - ${timer_desc[$timer]}")
            missing=$((missing + 1))
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING

            # Auto-heal: Try to install if from systemd directory
            if [[ $auto_heal -eq 1 ]]; then
                local timer_file="/home/gituser/github/nftban-dev/install/systemd/$timer"
                if [[ -f "$timer_file" ]]; then
                    echo "  🔧 Auto-heal: Installing $timer..."
                    if cp "$timer_file" /etc/systemd/system/ 2>/dev/null && systemctl daemon-reload 2>/dev/null; then
                        timer_issues+=("✓ Installed $timer")
                    else
                        timer_issues+=("❌ Failed to install $timer")
                    fi
                fi
            fi
            continue
        fi

        # Check if enabled
        if systemctl is-enabled --quiet "$timer" 2>/dev/null; then
            enabled=$((enabled + 1))

            # Check if active
            if systemctl is-active --quiet "$timer" 2>/dev/null; then
                active=$((active + 1))
                timer_issues+=("✓ $timer - Active")
            else
                timer_issues+=("⚠ $timer - Enabled but not active")
                [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING

                # Auto-heal: Start timer
                if [[ $auto_heal -eq 1 ]]; then
                    echo "  🔧 Auto-heal: Starting $timer..."
                    if systemctl start "$timer" 2>/dev/null; then
                        timer_issues+=("✓ Started $timer")
                    else
                        timer_issues+=("❌ Failed to start $timer")
                    fi
                fi
            fi
        else
            disabled=$((disabled + 1))
            timer_issues+=("⚠ $timer - Disabled (${timer_desc[$timer]})")
            timer_issues+=("FIX: sudo systemctl enable --now $timer")
            [[ $status -lt $HEALTH_ERROR ]] && status=$HEALTH_ERROR

            # Auto-heal: Enable and start timer
            if [[ $auto_heal -eq 1 ]]; then
                echo "  🔧 Auto-heal: Enabling $timer..."
                if systemctl enable --now "$timer" 2>/dev/null; then
                    timer_issues+=("✓ Enabled and started $timer")
                    enabled=$((enabled + 1))
                    active=$((active + 1))
                    disabled=$((disabled - 1))
                else
                    timer_issues+=("❌ Failed to enable $timer")
                fi
            fi
        fi
    done

    # Summary
    if [[ $active -eq $total ]]; then
        timer_issues=("✓ All timers active ($active/$total)" "${timer_issues[@]}")
    elif [[ $enabled -eq $total ]]; then
        timer_issues=("⚠ All timers enabled but some not active ($active/$total active)" "${timer_issues[@]}")
    elif [[ $disabled -gt 0 ]]; then
        timer_issues=("⚠ $disabled/$total timers disabled" "${timer_issues[@]}")
    fi

    if [[ $missing -gt 0 ]]; then
        timer_issues+=("⚠ $missing/$total timers not installed")
        timer_issues+=("FIX: Run install script - sudo ./install.sh systemd")
    fi

    # Store results (used by render functions)
    # shellcheck disable=SC2034
    NFTBAN_HEALTH_RESULTS["timers"]=$status
    # shellcheck disable=SC2034
    NFTBAN_HEALTH_ISSUES["timers"]="${timer_issues[*]}"

    return $status
}

# =============================================================================
# COMPREHENSIVE HEALTH CHECK
# =============================================================================

