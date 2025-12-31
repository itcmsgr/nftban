#!/usr/bin/env bash
# shellcheck disable=SC1090  # Dynamic config paths, cannot follow
# =============================================================================
# NFTBan v1.0 - Health Check System
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: System health checks and diagnostics
#
# meta:name=nftban_health
# meta:type=core
# meta:header=Health Check System
# meta:version=1.0.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Comprehensive system health verification and auto-fix capabilities
# meta:input=System state and configuration files
# meta:output=Health status reports and automated fixes
#
# **Inventory & Requirements**
# meta:depends=nftban_fhs_spec.sh,nft,systemctl
#
# meta:created_date=2025-11-05
# meta:updated_date=2025-11-24
# =============================================================================

# Enhanced strict mode
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_HEALTH_LOADED:-}" ]] && return 0
readonly NFTBAN_HEALTH_LOADED=1

# =============================================================================
# CONFIGURATION
# =============================================================================

# Health check results storage
declare -A NFTBAN_HEALTH_RESULTS
declare -A NFTBAN_HEALTH_ISSUES
declare -a NFTBAN_HEALTH_WARNINGS
declare -a NFTBAN_HEALTH_ERRORS

# Health status codes
readonly HEALTH_OK=0
readonly HEALTH_WARNING=1
readonly HEALTH_ERROR=2
readonly HEALTH_CRITICAL=3
readonly HEALTH_NOT_INSTALLED=4

# Load main configuration (service names, paths)
# shellcheck source=/etc/nftban/nftban.conf
if [[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" ]]; then
    source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf"
fi

# Metrics endpoint defaults (use config or fallback)
: "${NFTBAN_METRICS_PROMETHEUS_ADDR:=localhost:9090}"
: "${NFTBAN_METRICS_NODE_EXPORTER_ADDR:=localhost:9100}"
: "${NFTBAN_METRICS_VICTORIA_ADDR:=localhost:8428}"
: "${NFTBAN_TIMEOUT_FAST:=5}"

# Load NFT schema (single source of truth for table/set names)
# NFTBAN_LIB_DIR is set by the calling script (cmd_health.sh, etc.)
# shellcheck source=/usr/lib/nftban/lib/nft_schema.sh
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nft_schema.sh" ]]; then
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nft_schema.sh"
fi

# =============================================================================
# INITIALIZATION & DEPENDENCIES
# =============================================================================

nftban_health_init() {
    # Initialize health check system and load report modules

    # Clear previous results (MUST be associative arrays)
    declare -gA NFTBAN_HEALTH_RESULTS=()
    declare -gA NFTBAN_HEALTH_ISSUES=()
    declare -ga NFTBAN_HEALTH_WARNINGS=()
    declare -ga NFTBAN_HEALTH_ERRORS=()

    # Load report modules (orchestrate, don't duplicate!)
    local lib_dir="${NFTBAN_LIB_DIR}"

    # Load module report
    if ! declare -f nftban_module_report_summary >/dev/null 2>&1; then
        if [[ -f "${lib_dir}/core/nftban_report_module.sh" ]]; then
            source "${lib_dir}/core/nftban_report_module.sh" 2>/dev/null || true
        fi
    fi

    # Load FHS report
    if ! declare -f nftban_fhs_report_summary >/dev/null 2>&1; then
        if [[ -f "${lib_dir}/core/nftban_report_fhs.sh" ]]; then
            source "${lib_dir}/core/nftban_report_fhs.sh" 2>/dev/null || true
        fi
    fi

    # Load distro config module for cross-distro compatibility
    if ! declare -f nftban_distro_get_service >/dev/null 2>&1; then
        if [[ -f "${lib_dir}/lib/nftban_distro_config.sh" ]]; then
            source "${lib_dir}/lib/nftban_distro_config.sh" 2>/dev/null || true
        fi
    fi

    # Load services report
    if ! declare -f nftban_services_report_summary >/dev/null 2>&1; then
        if [[ -f "${lib_dir}/core/nftban_report_services.sh" ]]; then
            source "${lib_dir}/core/nftban_report_services.sh" 2>/dev/null || true
        fi
    fi

    return 0
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

    local optional_binaries=(
        "go"
        "git"
        "mail"
        "sendmail"
    )

    local missing_required=()
    local missing_optional=()

    # Check required binaries
    for binary in "${required_binaries[@]}"; do
        if ! command -v "$binary" >/dev/null 2>&1; then
            missing_required+=("$binary")
            status=$HEALTH_ERROR
        fi
    done

    # Check optional binaries
    for binary in "${optional_binaries[@]}"; do
        if ! command -v "$binary" >/dev/null 2>&1; then
            missing_optional+=("$binary")
            [[ $status -eq $HEALTH_OK ]] && status=$HEALTH_WARNING
        fi
    done

    # Store results
    if [[ ${#missing_required[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["binaries"]="Missing required: ${missing_required[*]}"
        NFTBAN_HEALTH_ERRORS+=("Missing required binaries: ${missing_required[*]}")
    fi

    if [[ ${#missing_optional[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_WARNINGS+=("Optional features not installed (OK to ignore): ${missing_optional[*]}")
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
        "/usr/sbin/nftban"
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
    # Check for conflicting firewall services (firewalld, iptables, ufw)
    # These cannot coexist with nftban and cause unpredictable behavior
    # Returns: 0=OK, 1=Warning, 2=Critical Error

    local status=$HEALTH_OK
    local firewall_conflicts=()

    # Check firewalld
    if command -v firewall-cmd &>/dev/null; then
        if systemctl is-active --quiet firewalld 2>/dev/null; then
            firewall_conflicts+=("ERROR: firewalld is ACTIVE - conflicts with nftban")
            firewall_conflicts+=("  └─ FIX: systemctl stop firewalld && systemctl disable firewalld")
            status=$HEALTH_CRITICAL
        elif systemctl is-enabled --quiet firewalld 2>/dev/null; then
            firewall_conflicts+=("WARNING: firewalld is ENABLED (not running)")
            firewall_conflicts+=("  └─ FIX: systemctl disable firewalld")
            [[ $status -eq $HEALTH_OK ]] && status=$HEALTH_WARNING
        fi
    fi

    # Check iptables service
    if systemctl is-active --quiet iptables 2>/dev/null || \
       systemctl is-active --quiet iptables.service 2>/dev/null || \
       systemctl is-active --quiet ip6tables.service 2>/dev/null; then
        firewall_conflicts+=("ERROR: iptables service is ACTIVE - conflicts with nftban")
        firewall_conflicts+=("  └─ FIX: systemctl stop iptables && systemctl disable iptables")
        status=$HEALTH_CRITICAL
    elif systemctl is-enabled --quiet iptables 2>/dev/null || \
         systemctl is-enabled --quiet iptables.service 2>/dev/null; then
        firewall_conflicts+=("WARNING: iptables service is ENABLED (not running)")
        firewall_conflicts+=("  └─ FIX: systemctl disable iptables")
        [[ $status -eq $HEALTH_OK ]] && status=$HEALTH_WARNING
    fi

    # Check ufw
    if command -v ufw &>/dev/null; then
        if ufw status 2>/dev/null | grep -q "Status: active"; then
            firewall_conflicts+=("ERROR: ufw is ACTIVE - conflicts with nftban")
            firewall_conflicts+=("  └─ FIX: ufw disable")
            status=$HEALTH_CRITICAL
        fi
    fi

    # Store results
    if [[ ${#firewall_conflicts[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["conflicting_firewalls"]="${firewall_conflicts[*]}"
        if [[ $status -eq $HEALTH_CRITICAL ]]; then
            NFTBAN_HEALTH_ERRORS+=("Conflicting firewall(s) detected: ${firewall_conflicts[*]}")
        else
            NFTBAN_HEALTH_WARNINGS+=("Conflicting firewall(s) enabled: ${firewall_conflicts[*]}")
        fi
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

    # 3. Check eve.json log file exists and has recent activity
    # Use central config path, with fallback to common locations
    local eve_log="${NFTBAN_SURICATA_EVE_LOG:-/var/log/suricata/eve.json}"
    if [[ -f "$eve_log" ]]; then
        # Check if file has been modified in last 10 minutes
        local last_modified
        last_modified=$(stat -c %Y "$eve_log" 2>/dev/null || echo 0)
        local current_time
        current_time=$(date +%s)
        local age
        age=$((current_time - last_modified))

        if [[ $age -gt 600 ]]; then
            suricata_issues+=("Eve.json not updated in 10+ minutes (may be stalled)")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi

        # Check file size (warn if > 1GB)
        local file_size
        file_size=$(stat -c %s "$eve_log" 2>/dev/null || echo 0)
        if [[ $file_size -gt 1073741824 ]]; then
            suricata_issues+=("Eve.json large ($(numfmt --to=iec "$file_size")), consider log rotation")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi
    elif systemctl is-active --quiet suricata.service 2>/dev/null; then
        # Service running but no log file
        suricata_issues+=("Suricata running but eve.json not found at $eve_log")
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
    local db_path="${NFTBAN_DATA_DIR}/geoip/GeoLite2-City.mmdb"

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
    if [[ ! -f "$db_path" ]]; then
        geoip_issues+=("GeoIP database not downloaded")
        geoip_issues+=("FIX: Run 'nftban geoip update' to download GeoLite2 database")
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
# DATABASE CHECKS
# =============================================================================

nftban_health_check_databases() {
    # Check database files
    # Returns: 0=OK, 1=Warning, 2=Error

    local status=$HEALTH_OK
    local db_issues=()

    # GeoLite2 database
    local geolite2="${NFTBAN_DATA_DIR}/geoip/GeoLite2-City.mmdb"
    if [[ -f "$geolite2" ]]; then
        # Check age (warn if >90 days old)
        local file_age
        file_age=$(( $(date +%s) - $(stat -c %Y "$geolite2" 2>/dev/null || echo 0) ))
        local days_old
        days_old=$(( file_age / 86400 ))

        if (( days_old > 90 )); then
            db_issues+=("GeoLite2 database is ${days_old} days old (consider updating)")
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
        for subdir in "$config_dir"/*; do
            if [[ -d "$subdir" ]]; then
                for conf_file in "$subdir"/*.conf; do
                    if [[ -f "$conf_file" ]]; then
                        # shellcheck disable=SC1090  # Dynamic source for config validation
                        if ! (source "$conf_file") 2>/dev/null; then
                            local relative_path="$(basename "$subdir")/$(basename "$conf_file")"
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
            # NFTBan v1.0 simplified 2-group model: nftban + nftban-auditors
            local actual_uid actual_gid actual_auditors_gid
            actual_uid=$(id -u nftban 2>/dev/null || echo "MISSING")
            actual_gid=$(id -g nftban 2>/dev/null || echo "MISSING")
            actual_auditors_gid=$(getent group nftban-auditors 2>/dev/null | cut -d: -f3 || echo "MISSING")

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
        polkit_issues+=("nftban-auditors group will also require sudo for inventory helpers")
        status=$HEALTH_WARNING
    else
        # Check if NFTBAN services authorization rules are installed (v1.0 simplified model)
        local polkit_services_rules="${NFTBAN_POLKIT_RULES_DIR:-/etc/polkit-1/rules.d}/60-nftban-services.rules"
        if [[ ! -f "$polkit_services_rules" ]]; then
            polkit_issues+=("CRITICAL: Polkit services rules missing at $polkit_services_rules")
            polkit_issues+=("This violates NFTBAN security model - privilege separation not functional!")
            polkit_issues+=("Users in nftban group CANNOT manage services without sudo")
            polkit_issues+=("FIX: Re-run install.sh or manually copy packaging/polkit-1/rules.d/60-nftban-services.rules")
            status=$HEALTH_ERROR
        else
            # Verify file permissions
            local perms
            perms=$(stat -c '%a' "$polkit_services_rules" 2>/dev/null || echo "000")
            if [[ "$perms" != "644" ]]; then
                polkit_issues+=("Polkit services rules have wrong permissions: $perms (should be 644)")
                status=$HEALTH_WARNING
            fi
        fi

        # Check if NFTBAN Auditors authorization rules are installed (v0.31+)
        local polkit_auditors_rules="${NFTBAN_POLKIT_RULES_DIR:-/etc/polkit-1/rules.d}/50-nftban-v030.rules"
        if [[ ! -f "$polkit_auditors_rules" ]]; then
            polkit_issues+=("WARNING: Polkit auditors rules missing at $polkit_auditors_rules")
            polkit_issues+=("Users in nftban-auditors group cannot run inventory helpers without sudo")
            polkit_issues+=("FIX: Re-run install.sh or manually copy packaging/polkit-1/rules.d/50-nftban-v030.rules")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        else
            # Verify file permissions
            local perms
            perms=$(stat -c '%a' "$polkit_auditors_rules" 2>/dev/null || echo "000")
            if [[ "$perms" != "644" ]]; then
                polkit_issues+=("Polkit auditors rules have wrong permissions: $perms (should be 644)")
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

    # Check central config - if metrics disabled, skip detailed checks
    if [[ "${NFTBAN_METRICS_ENABLED:-false}" != "true" ]]; then
        NFTBAN_HEALTH_ISSUES["metrics"]="Disabled in config (set NFTBAN_METRICS_ENABLED=true to enable)"
        NFTBAN_HEALTH_RESULTS["metrics"]=$HEALTH_NOT_INSTALLED
        return $HEALTH_NOT_INSTALLED
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
            node_exporter_running=true
        else
            metrics_issues+=("ℹ️ Node Exporter installed but not running (optional - for Prometheus)")
        fi
    else
        # Not installed - this is OK, it's optional
        metrics_issues+=("ℹ️ Node Exporter not installed (optional - only needed for Prometheus scraping)")
    fi

    # Check Prometheus or VictoriaMetrics (optional alternatives - only one needed)
    local metrics_backend_found=false
    local prometheus_running=false

    # Check Prometheus first
    if command -v prometheus >/dev/null 2>&1 || systemctl list-unit-files 2>/dev/null | grep -q "^prometheus.service"; then
        metrics_backend_found=true
        if systemctl is-active --quiet prometheus 2>/dev/null; then
            prometheus_running=true
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
            metrics_issues+=("Prometheus installed but not running")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi
    fi

    # Check VictoriaMetrics (alternative to Prometheus) - only if Prometheus not running
    # Skip VictoriaMetrics check if Prometheus is already running (they're alternatives)
    if [[ "$prometheus_running" != "true" ]]; then
        if command -v victoria-metrics >/dev/null 2>&1 || systemctl list-unit-files 2>/dev/null | grep -q "^victoria-metrics.service"; then
            metrics_backend_found=true
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

nftban_health_check_timers() {
    # Check all NFTBan systemd timers (v0.7.3)
    # Returns: 0=OK, 1=WARNING, 2=ERROR, 3=CRITICAL
    # Args: $1 = auto_heal (0=check only, 1=auto-fix)

    local auto_heal="${1:-0}"
    local status=$HEALTH_OK
    local timer_issues=()

    # All NFTBan timers in priority order (REQUIRED for complete installation)
    local -a timers=(
        "nftban-maintenance.timer"      # CRITICAL: SSH/IP protection, auto-heal
        "nftban-health.timer"           # Health checks
        "nftban-core-feeds.timer"       # Threat feeds sync
        "nftban-core-geoip.timer"       # GeoIP updates
        "nftban-queue.timer"            # Ban queue processing
        "nftban-watchdog.timer"         # System resource monitoring
        "nftban-metrics-exporter.timer" # Prometheus metrics
    )

    # Optional timers (only needed for specific features)
    local -a optional_timers=(
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

    # Store results
    NFTBAN_HEALTH_RESULTS["timers"]=$status
    NFTBAN_HEALTH_ISSUES["timers"]="${timer_issues[*]}"

    return $status
}

# =============================================================================
# COMPREHENSIVE HEALTH CHECK
# =============================================================================

nftban_health_check_all() {
    # Run all health checks (ORCHESTRATES existing report modules!)
    # Args: $1 = auto_heal (0=check only, 1=auto-fix issues)
    # Returns: 0=Healthy, 1=Warnings, 2=Errors, 3=Critical

    local auto_heal="${1:-0}"
    nftban_health_init

    local overall_status=$HEALTH_OK
    local check_result=0

    # =========================================================================
    # ORCHESTRATE EXISTING REPORT MODULES (Don't Duplicate!)
    # =========================================================================

    # MODULE CHECK - Use existing nftban_report_module.sh
    if declare -f nftban_module_report_summary >/dev/null 2>&1; then
        check_result=0
        local module_output
        module_output=$(nftban_module_report_summary 2>&1) || check_result=$?
        [[ $check_result -gt $overall_status ]] && overall_status=$check_result

        NFTBAN_HEALTH_RESULTS["modules"]=$check_result
        if [[ $check_result -eq 0 ]]; then
            NFTBAN_HEALTH_ISSUES["modules"]="$module_output"
        elif [[ $check_result -eq 1 ]]; then
            NFTBAN_HEALTH_ISSUES["modules"]="$module_output"
            NFTBAN_HEALTH_WARNINGS+=("Modules: $module_output")
        else
            NFTBAN_HEALTH_ISSUES["modules"]="$module_output"
            NFTBAN_HEALTH_ERRORS+=("Modules: $module_output")
        fi
    else
        # Fallback if module report not available
        check_result=0
        nftban_health_check_modules || check_result=$?
        [[ $check_result -gt $overall_status ]] && overall_status=$check_result
    fi

    # FHS CHECK - Use existing nftban_report_fhs.sh
    if declare -f nftban_fhs_report_summary >/dev/null 2>&1; then
        check_result=0
        local fhs_output
        fhs_output=$(nftban_fhs_report_summary 2>&1) || check_result=$?
        [[ $check_result -gt $overall_status ]] && overall_status=$check_result

        NFTBAN_HEALTH_RESULTS["fhs"]=$check_result
        if [[ $check_result -eq 0 ]]; then
            NFTBAN_HEALTH_ISSUES["fhs"]="$fhs_output"
        elif [[ $check_result -eq 1 ]]; then
            NFTBAN_HEALTH_ISSUES["fhs"]="$fhs_output"
            NFTBAN_HEALTH_WARNINGS+=("FHS: $fhs_output")
        else
            NFTBAN_HEALTH_ISSUES["fhs"]="$fhs_output"
            NFTBAN_HEALTH_ERRORS+=("FHS: $fhs_output")
        fi
    else
        # Fallback - use paths and permissions checks
        check_result=0
        nftban_health_check_paths || check_result=$?
        [[ $check_result -gt $overall_status ]] && overall_status=$check_result

        check_result=0
        nftban_health_check_permissions || check_result=$?
        [[ $check_result -gt $overall_status ]] && overall_status=$check_result
    fi

    # SERVICES CHECK - Use existing nftban_report_services.sh
    if declare -f nftban_services_report_summary >/dev/null 2>&1; then
        check_result=0
        local services_output
        services_output=$(nftban_services_report_summary 2>&1) || check_result=$?
        [[ $check_result -gt $overall_status ]] && overall_status=$check_result

        NFTBAN_HEALTH_RESULTS["services"]=$check_result
        if [[ $check_result -eq 0 ]]; then
            NFTBAN_HEALTH_ISSUES["services"]="$services_output"
        elif [[ $check_result -eq 1 ]]; then
            NFTBAN_HEALTH_ISSUES["services"]="$services_output"
            NFTBAN_HEALTH_WARNINGS+=("Services: $services_output")
        else
            NFTBAN_HEALTH_ISSUES["services"]="$services_output"
            NFTBAN_HEALTH_ERRORS+=("Services: $services_output")
        fi
    else
        # Fallback if services report not available
        check_result=0
        nftban_health_check_services || check_result=$?
        [[ $check_result -gt $overall_status ]] && overall_status=$check_result
    fi

    # =========================================================================
    # HEALTH-SPECIFIC CHECKS (No dedicated modules yet)
    # =========================================================================

    # Suricata IDS check (comprehensive monitoring)
    check_result=0
    nftban_health_check_suricata || check_result=$?
    [[ $check_result -gt $overall_status ]] && overall_status=$check_result

    # nftables security check (CVE-2025-NFTBAN-001 - inet filter bypass)
    check_result=0
    nftban_health_check_nftables_security || check_result=$?
    [[ $check_result -gt $overall_status ]] && overall_status=$check_result

    # Conflicting firewalls check (firewalld, iptables, ufw)
    check_result=0
    nftban_health_check_conflicting_firewalls || check_result=$?
    [[ $check_result -gt $overall_status ]] && overall_status=$check_result

    # Binaries check (keep for now - no dedicated module)
    check_result=0
    nftban_health_check_binaries || check_result=$?
    [[ $check_result -gt $overall_status ]] && overall_status=$check_result

    # System resources check (CPU, RAM, disk)
    check_result=0
    nftban_health_check_resources || check_result=$?
    [[ $check_result -gt $overall_status ]] && overall_status=$check_result

    # GeoIP check (keep for now - no dedicated module)
    check_result=0
    nftban_health_check_geoip || check_result=$?
    [[ $check_result -gt $overall_status ]] && overall_status=$check_result

    # v0.31 inventory helpers check
    check_result=0
    nftban_health_check_v030_helpers || check_result=$?
    [[ $check_result -gt $overall_status ]] && overall_status=$check_result

    # Databases check (keep for now - no dedicated module)
    check_result=0
    nftban_health_check_databases || check_result=$?
    [[ $check_result -gt $overall_status ]] && overall_status=$check_result

    # Polkit check (CRITICAL security check)
    check_result=0
    nftban_health_check_polkit || check_result=$?
    [[ $check_result -gt $overall_status ]] && overall_status=$check_result

    # SSH port check (CRITICAL lockout prevention)
    check_result=0
    nftban_health_check_ssh_port || check_result=$?
    [[ $check_result -gt $overall_status ]] && overall_status=$check_result

    # Bash completion check (CLI usability check)
    check_result=0
    nftban_health_check_bash_completion || check_result=$?
    [[ $check_result -gt $overall_status ]] && overall_status=$check_result

    # Removed: fail2ban jails check (v1.0 migration to Suricata)

    # Metrics integration check (v0.6.0 - Prometheus/Grafana)
    check_result=0
    nftban_health_check_metrics || check_result=$?
    [[ $check_result -gt $overall_status ]] && overall_status=$check_result

    # Systemd timers check (v0.7.3 - all automated tasks)
    check_result=0
    nftban_health_check_timers "$auto_heal" || check_result=$?
    [[ $check_result -gt $overall_status ]] && overall_status=$check_result

    # GUI (Web UI) check (v0.6.0 - nftban-ui)
    check_result=0
    nftban_health_check_gui "$auto_heal" || check_result=$?
    [[ $check_result -gt $overall_status ]] && overall_status=$check_result

    # CLI errors check (v0.6.5 - strict.sh error logging)
    check_result=0
    nftban_health_check_cli_errors || check_result=$?
    [[ $check_result -gt $overall_status ]] && overall_status=$check_result

    # Config check (keep for now - no dedicated module)
    check_result=0
    nftban_health_check_config || check_result=$?
    [[ $check_result -gt $overall_status ]] && overall_status=$check_result

    # Registry check (v1.0.16 - commands.registry.yml and generators)
    check_result=0
    nftban_health_check_registry || check_result=$?
    [[ $check_result -gt $overall_status ]] && overall_status=$check_result

    # Permissions check (using nftban_permissions module if available)
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_permissions.sh" ]]; then
        if source "${NFTBAN_LIB_DIR}/core/nftban_permissions.sh" 2>/dev/null; then
            if declare -f nftban_permissions_check >/dev/null 2>&1; then
                check_result=0
                local perms_output
                perms_output=$(nftban_permissions_check 2>&1) || check_result=$?

                # Treat check result as health status
                [[ $check_result -gt $overall_status ]] && overall_status=$check_result

                NFTBAN_HEALTH_RESULTS["permissions"]=$check_result
                if [[ $check_result -eq 0 ]]; then
                    NFTBAN_HEALTH_ISSUES["permissions"]="All permissions are correct"
                elif [[ $check_result -eq 1 ]]; then
                    NFTBAN_HEALTH_ISSUES["permissions"]="$perms_output"
                    NFTBAN_HEALTH_WARNINGS+=("Permissions: $perms_output")
                else
                    NFTBAN_HEALTH_ISSUES["permissions"]="$perms_output"
                    NFTBAN_HEALTH_ERRORS+=("Permissions: $perms_output")
                fi
            fi
        fi
    fi

    # =========================================================================
    # AUTO-HEAL EXECUTION (if enabled and issues found)
    # =========================================================================

    if [[ $auto_heal -eq 1 ]] && [[ $overall_status -gt $HEALTH_OK ]]; then
        echo ""
        echo "═══════════════════════════════════════════════════════════"
        echo "  Auto-Heal Activated"
        echo "═══════════════════════════════════════════════════════════"
        echo ""

        # Check user has permissions (root required for chown/chmod)
        if [[ $EUID -ne 0 ]]; then
            echo "⚠️  Auto-heal requires root privileges" >&2
            echo "   Run: sudo nftban health check --auto-heal" >&2
            return 2
        fi

        # Log auto-heal start
        if declare -f perms_log_audit >/dev/null 2>&1; then
            perms_log_audit "Auto-heal started by ${SUDO_USER:-root}"
        fi

        # Execute fix functions
        local fixes_applied=0

        # Always run fixes when overall_status indicates issues
        # (we already checked overall_status > HEALTH_OK above)
        if [[ $overall_status -gt $HEALTH_OK ]]; then
            echo "→ Fixing directories..."
            if nftban_health_fix_directories; then
                fixes_applied=$((fixes_applied + 1))
            fi
            echo ""

            echo "→ Fixing permissions..."
            if nftban_health_fix_permissions; then
                fixes_applied=$((fixes_applied + 1))
            fi
            echo ""

            echo "→ Fixing system config..."
            if nftban_health_fix_system_config; then
                fixes_applied=$((fixes_applied + 1))
            fi
            echo ""

            echo "→ Fixing services..."
            if nftban_health_fix_services; then
                fixes_applied=$((fixes_applied + 1))
            fi
            echo ""

            echo "→ Fixing registry..."
            if nftban_health_fix_registry; then
                fixes_applied=$((fixes_applied + 1))
            fi
            echo ""

            echo "✅ Auto-heal complete ($fixes_applied fixes applied)"
            echo ""

            # Log auto-heal completion
            if declare -f perms_log_audit >/dev/null 2>&1; then
                perms_log_audit "Auto-heal completed: $fixes_applied fixes applied"
            fi

            # Re-run checks to verify fixes worked
            echo "→ Re-checking system health..."
            echo ""

            # Clear previous results
            overall_status=$HEALTH_OK
            NFTBAN_HEALTH_ERRORS=()
            NFTBAN_HEALTH_WARNINGS=()
            declare -gA NFTBAN_HEALTH_RESULTS=()
            declare -gA NFTBAN_HEALTH_ISSUES=()

            # Re-check (without auto-heal to avoid infinite loop)
            nftban_health_check_all 0 || overall_status=$?
        fi
    fi

    return $overall_status
}

# =============================================================================
# AUTO-FIX FUNCTIONS
# =============================================================================

nftban_health_fix_permissions() {
    # Fix ALL permissions and ownership to match FHS specification
    # Uses the new permissions enforcement module if available, otherwise legacy fix
    # Smart about privileges: fixes what it can, reports what needs root

    local running_as_root=0
    [[ $EUID -eq 0 ]] && running_as_root=1

    echo "Fixing permissions and ownership..."

    # Try to use new permissions enforcement module (more comprehensive)
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_permissions.sh" ]]; then
        if source "${NFTBAN_LIB_DIR}/core/nftban_permissions.sh" 2>/dev/null; then
            # Log audit entry before fixing
            if declare -f perms_log_audit >/dev/null 2>&1; then
                perms_log_audit "Health auto-fix: Starting permission enforcement"
            fi

            echo "  Using enhanced permission enforcement module"
            nftban_permissions_enforce_all
            return $?
        fi
    fi

    # Fall back to legacy implementation
    echo "  Using legacy permission fix"

    # Load canonical FHS specification
    if ! declare -f nftban_fhs_load_spec >/dev/null 2>&1; then
        source "${NFTBAN_LIB_DIR}/core/nftban_fhs_spec.sh" || {
            echo "  ✖ ERROR: Failed to load FHS specification" >&2
            return 1
        }
    fi

    # Ensure spec is loaded
    if [[ ${#NFTBAN_FHS_DIRECTORIES[@]} -eq 0 ]]; then
        nftban_fhs_load_spec
    fi

    local fixed_count=0
    local need_root_count=0
    declare -a need_root_fixes=()

    for dir in "${!NFTBAN_FHS_DIRECTORIES[@]}"; do
        if [[ -d "$dir" ]]; then
            IFS='|' read -r expected_perms expected_owner expected_group _purpose <<< "${NFTBAN_FHS_DIRECTORIES[$dir]}"

            # Get current perms/owner/group
            local current_perms
            current_perms=$(stat -c "%a" "$dir" 2>/dev/null || echo "")
            local current_owner
            current_owner=$(stat -c "%U" "$dir" 2>/dev/null || echo "")
            local current_group
            current_group=$(stat -c "%G" "$dir" 2>/dev/null || echo "")

            local can_fix=0
            local issues=()

            # Check if we own this directory (can fix permissions)
            if [[ "$current_owner" == "nftban" ]] || [[ $running_as_root -eq 1 ]]; then
                can_fix=1
            fi

            # Check permissions
            if [[ "$current_perms" != "$expected_perms" ]]; then
                if [[ $can_fix -eq 1 ]]; then
                    if chmod "$expected_perms" "$dir" 2>/dev/null; then
                        issues+=("perms: $current_perms → $expected_perms")
                    fi
                else
                    need_root_fixes+=("$dir: chmod $expected_perms (currently $current_perms, owned by $current_owner)")
                    ((need_root_count++))
                fi
            fi

            # Check ownership
            if [[ "$current_owner" != "$expected_owner" ]] || [[ "$current_group" != "$expected_group" ]]; then
                if [[ $running_as_root -eq 1 ]]; then
                    # Verify user/group exists before changing
                    if [[ "$expected_owner" == "nftban" ]] && ! id -u nftban >/dev/null 2>&1; then
                        continue  # Skip if nftban user doesn't exist
                    fi
                    local target_group="$expected_group"
                    if [[ "$expected_group" == "nftban" ]] && ! getent group nftban >/dev/null 2>&1; then
                        target_group="$expected_owner"  # Fallback to owner
                    fi

                    if chown "${expected_owner}:${target_group}" "$dir" 2>/dev/null; then
                        issues+=("owner: $current_owner:$current_group → ${expected_owner}:${target_group}")
                    fi
                else
                    # Not root, can't change ownership
                    need_root_fixes+=("$dir: chown ${expected_owner}:${expected_group} (currently $current_owner:$current_group)")
                    ((need_root_count++))
                fi
            fi

            # Report what we fixed
            if [[ ${#issues[@]} -gt 0 ]]; then
                echo "  ✓ Fixed $dir → ${issues[*]}"
                : $((fixed_count++))
            fi
        fi
    done

    # Fix system binaries (only if root)
    if [[ $running_as_root -eq 1 ]]; then
        # Fix /usr/sbin directory ownership (FHS compliance)
        if [[ -d "/usr/sbin" ]]; then
            local sbin_owner sbin_group
            sbin_owner=$(stat -c '%U' /usr/sbin 2>/dev/null || echo "unknown")
            sbin_group=$(stat -c '%G' /usr/sbin 2>/dev/null || echo "unknown")

            if [[ "$sbin_owner" != "root" ]] || [[ "$sbin_group" != "root" ]]; then
                chown root:root /usr/sbin 2>/dev/null && \
                chmod 755 /usr/sbin 2>/dev/null && \
                echo "  ✓ Fixed /usr/sbin directory ownership (was $sbin_owner:$sbin_group)" && \
                : $((fixed_count++))
            fi
        fi

        if [[ -f "/usr/sbin/nftban" ]]; then
            chmod 755 /usr/sbin/nftban 2>/dev/null && \
            chown root:root /usr/sbin/nftban 2>/dev/null && \
            echo "  ✓ Fixed /usr/sbin/nftban binary" && \
            : $((fixed_count++))
        fi

        if [[ -f "${NFTBAN_LIB_DIR}/bin/nftban-geoip" ]]; then
            chmod 755 "${NFTBAN_LIB_DIR}/bin/nftban-geoip" 2>/dev/null && \
            chown root:root "${NFTBAN_LIB_DIR}/bin/nftban-geoip" 2>/dev/null && \
            echo "  ✓ Fixed ${NFTBAN_LIB_DIR}/bin/nftban-geoip" && \
            : $((fixed_count++))
        fi

        # Recursively fix ownership for system libraries (both directories AND files)
        if [[ -d "${NFTBAN_LIB_DIR}" ]]; then
            # Fix directory ownership and permissions first
            find "${NFTBAN_LIB_DIR}" -type d -exec chown root:root {} \; 2>/dev/null
            find "${NFTBAN_LIB_DIR}" -type d -exec chmod 755 {} \; 2>/dev/null

            # Fix file ownership and permissions
            find "${NFTBAN_LIB_DIR}" -type f -name "*.sh" -exec chown root:root {} \; 2>/dev/null
            find "${NFTBAN_LIB_DIR}" -type f -name "*.sh" -exec chmod 644 {} \; 2>/dev/null

            # Fix binary permissions (if they exist)
            find "${NFTBAN_LIB_DIR}/bin" -type f 2>/dev/null | while read -r binary; do
                chown root:root "$binary" 2>/dev/null
                chmod 755 "$binary" 2>/dev/null
            done

            echo "  ✓ Fixed ${NFTBAN_LIB_DIR} directory and file ownership (root:root)"
            : $((fixed_count++))
        fi

        if [[ -d "/usr/share/nftban" ]]; then
            chown -R root:root /usr/share/nftban 2>/dev/null && \
            echo "  ✓ Fixed /usr/share/nftban ownership (root:root)" && \
            : $((fixed_count++))
        fi

        # Fix Suricata permissions for NFTBan integration
        # Suricata writes to LOG_DIR/suricata/, nftban needs to read eve.json
        if [[ -d "${NFTBAN_LOG_DIR}/suricata" ]]; then
            local suricata_fixed=0

            # Add suricata user to nftban group (if not already)
            if id suricata >/dev/null 2>&1; then
                if ! groups suricata 2>/dev/null | grep -q '\bnftban\b'; then
                    usermod -aG nftban suricata 2>/dev/null && suricata_fixed=1
                fi
            fi

            # Fix directory: suricata:nftban with group read
            chgrp -R nftban "${NFTBAN_LOG_DIR}/suricata" 2>/dev/null
            chmod 750 "${NFTBAN_LOG_DIR}/suricata" 2>/dev/null

            # Fix eve.json: suricata:nftban 640 so nftban can read
            if [[ -f "${NFTBAN_LOG_DIR}/suricata/eve.json" ]]; then
                chown suricata:nftban "${NFTBAN_LOG_DIR}/suricata/eve.json" 2>/dev/null
                chmod 640 "${NFTBAN_LOG_DIR}/suricata/eve.json" 2>/dev/null
                suricata_fixed=1
            fi

            # Fix suricata.log similarly
            if [[ -f "${NFTBAN_LOG_DIR}/suricata/suricata.log" ]]; then
                chown suricata:nftban "${NFTBAN_LOG_DIR}/suricata/suricata.log" 2>/dev/null
                chmod 640 "${NFTBAN_LOG_DIR}/suricata/suricata.log" 2>/dev/null
            fi

            if [[ $suricata_fixed -eq 1 ]]; then
                echo "  ✓ Fixed ${NFTBAN_LOG_DIR}/suricata permissions (suricata:nftban)"
                : $((fixed_count++))
            fi
        fi
    fi

    if [[ $fixed_count -eq 0 ]] && [[ $need_root_count -eq 0 ]]; then
        echo "  ✓ All permissions already correct"
    fi

    # Report what needs root
    if [[ $need_root_count -gt 0 ]]; then
        echo ""
        echo "  ⚠️  Cannot fix $need_root_count permission/ownership issues (need root privileges):"
        for item in "${need_root_fixes[@]}"; do
            echo "     - $item"
        done
        echo ""
        echo "  💡 Run with root privileges to fix:"
        echo "     sudo nftban health fix permissions"
    fi
    return 0
}

nftban_health_fix_directories() {
    # Create missing directories with correct ownership and permissions
    # Uses canonical FHS spec from nftban_fhs_spec.sh (SINGLE SOURCE OF TRUTH)
    # Smart about privileges: fixes what it can, reports what needs root

    local running_as_root=0
    [[ $EUID -eq 0 ]] && running_as_root=1

    echo "Creating missing directories..."

    # Load canonical FHS specification
    if ! declare -f nftban_fhs_load_spec >/dev/null 2>&1; then
        source "${NFTBAN_LIB_DIR}/core/nftban_fhs_spec.sh" || {
            echo "  ✖ ERROR: Failed to load FHS specification" >&2
            return 1
        }
    fi

    # Ensure spec is loaded
    if [[ ${#NFTBAN_FHS_DIRECTORIES[@]} -eq 0 ]]; then
        nftban_fhs_load_spec
    fi

    local fixed_count=0
    local need_root_count=0
    declare -a need_root_dirs=()

    for dir in "${!NFTBAN_FHS_DIRECTORIES[@]}"; do
        if [[ ! -d "$dir" ]]; then
            IFS='|' read -r perms owner group _purpose <<< "${NFTBAN_FHS_DIRECTORIES[$dir]}"

            # Check if we can create this directory
            local parent_dir
            parent_dir=$(dirname "$dir")
            local can_create=0

            # Check if nftban user can write to parent
            if [[ "$owner" == "nftban" ]] && [[ -d "$parent_dir" ]] && [[ -w "$parent_dir" ]]; then
                can_create=1
            elif [[ $running_as_root -eq 1 ]]; then
                can_create=1
            fi

            if [[ $can_create -eq 1 ]]; then
                # We can create this directory
                if mkdir -p "$dir" 2>/dev/null; then
                    # Set ownership (only if root or already correct owner)
                    if [[ $running_as_root -eq 1 ]]; then
                        chown "${owner}:${group}" "$dir" 2>/dev/null || true
                        chmod "$perms" "$dir" 2>/dev/null || true
                        echo "  ✓ Created $dir (${perms} ${owner}:${group})"
                    else
                        # nftban user created it, ownership is already correct
                        chmod "$perms" "$dir" 2>/dev/null || true
                        echo "  ✓ Created $dir (${perms} ${owner}:${group})"
                    fi
                    : $((fixed_count++))

                    # Log to audit trail
                    if declare -f perms_log_audit >/dev/null 2>&1; then
                        perms_log_audit "Health auto-fix: Created directory $dir ($perms $owner:$group)"
                    fi
                else
                    # mkdir failed
                    need_root_dirs+=("$dir: mkdir failed (check parent directory permissions)")
                    ((need_root_count++))
                fi
            else
                # Need root to create this
                need_root_dirs+=("$dir → ${perms} ${owner}:${group} (parent: $parent_dir not writable)")
                ((need_root_count++))
            fi
        fi
    done

    if [[ $fixed_count -eq 0 ]] && [[ $need_root_count -eq 0 ]]; then
        echo "  ✓ All directories already exist"
    fi

    # Report what needs root
    if [[ $need_root_count -gt 0 ]]; then
        echo ""
        echo "  ⚠️  Cannot create $need_root_count directories (need root privileges):"
        for item in "${need_root_dirs[@]}"; do
            echo "     - $item"
        done
        echo ""
        echo "  💡 Run with root privileges to fix:"
        echo "     sudo nftban health fix directories"
    fi
    return 0
}

nftban_health_fix_services() {
    # Restart failed services

    echo "Restarting failed services..."

    local services=(
        "${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service}"
    )

    for service in "${services[@]}"; do
        if systemctl list-unit-files "$service" >/dev/null 2>&1; then
            if systemctl is-enabled "$service" >/dev/null 2>&1; then
                if ! systemctl is-active "$service" >/dev/null 2>&1; then
                    systemctl restart "$service" 2>/dev/null || true
                    echo "  ✓ Restarted $service"
                fi
            fi
        fi
    done
    return 0
}

nftban_health_fix_system_config() {
    # Create or update DATA_DIR/config/system.conf with current UID/GID
    # This ensures we always have a reference for the actual system IDs

    local system_conf="${NFTBAN_DATA_DIR}/config/system.conf"
    local config_dir="${NFTBAN_DATA_DIR}/config"

    echo "Checking system configuration..."

    # Ensure config directory exists
    if [[ ! -d "$config_dir" ]]; then
        mkdir -p "$config_dir" 2>/dev/null || {
            echo "  ⚠️  Cannot create $config_dir (need root)" >&2
            return 1
        }
        chown root:root "$config_dir"
        chmod 0755 "$config_dir"
        echo "  ✓ Created $config_dir"
    fi

    # Get current UID/GID values
    # NFTBan v1.0 simplified 2-group model: nftban + nftban-auditors
    local nftban_uid nftban_gid nftban_auditors_gid
    nftban_uid=$(id -u nftban 2>/dev/null || echo "MISSING")
    nftban_gid=$(id -g nftban 2>/dev/null || echo "MISSING")
    nftban_auditors_gid=$(getent group nftban-auditors 2>/dev/null | cut -d: -f3 || echo "MISSING")

    # Verify users/groups exist
    if [[ "$nftban_uid" == "MISSING" ]] || [[ "$nftban_gid" == "MISSING" ]]; then
        echo "  ✖ ERROR: nftban user or group not found" >&2
        echo "    Run installer to create system users/groups" >&2
        return 1
    fi

    # nftban-auditors is optional, warn if missing but don't fail
    if [[ "$nftban_auditors_gid" == "MISSING" ]]; then
        echo "  ⚠ WARNING: nftban-auditors group not found (optional, for inventory helpers)" >&2
    fi

    # Check if update needed
    local needs_update=0
    if [[ ! -f "$system_conf" ]]; then
        needs_update=1
        echo "  → System config missing, will create"
    else
        # Source existing config and check for mismatches
        local existing_uid existing_gid existing_auditors_gid
        if source "$system_conf" 2>/dev/null; then
            existing_uid="${NFTBAN_UID:-}"
            existing_gid="${NFTBAN_GID:-}"
            existing_auditors_gid="${NFTBAN_AUDITORS_GID:-}"

            if [[ "$existing_uid" != "$nftban_uid" ]] || \
               [[ "$existing_gid" != "$nftban_gid" ]] || \
               [[ "$existing_auditors_gid" != "$nftban_auditors_gid" ]]; then
                needs_update=1
                echo "  → System config outdated (UID/GID changed), will update"
            fi
        else
            needs_update=1
            echo "  → System config corrupted, will recreate"
        fi
    fi

    # Create/update if needed
    if [[ $needs_update -eq 1 ]]; then
        cat > "$system_conf" <<EOF
# =============================================================================
# NFTBan System Configuration (AUTO-GENERATED - DO NOT EDIT)
# =============================================================================
# Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
# Hostname: $(hostname)
#
# ⚠️  WARNING: DO NOT EDIT THIS FILE MANUALLY
#
# This file MUST stay aligned with actual system UID/GID values.
# Editing manually will cause health check failures.
#
# If UID/GID changes (user deleted/recreated), run:
#   sudo nftban health fix all
#
# This file is auto-maintained by:
#   - install.sh (during installation)
#   - nftban health fix (during auto-heal)
# =============================================================================

# NFTBan v1.0 simplified 2-group model
NFTBAN_USER="nftban"
NFTBAN_UID=${nftban_uid}
NFTBAN_GROUP="nftban"
NFTBAN_GID=${nftban_gid}
NFTBAN_AUDITORS_GROUP="nftban-auditors"
NFTBAN_AUDITORS_GID=${nftban_auditors_gid}
EOF

        chown root:root "$system_conf"
        chmod 0644 "$system_conf"
        echo "  ✓ Updated $system_conf"
        echo "    nftban UID=$nftban_uid GID=$nftban_gid"
        if [[ "$nftban_auditors_gid" != "MISSING" ]]; then
            echo "    nftban-auditors GID=$nftban_auditors_gid"
        fi
    else
        echo "  ✓ System config is up to date"
    fi

    # Fix logrotate configuration
    echo ""
    echo "Checking log rotation..."
    local logrotate_src="${NFTBAN_LIB_DIR}/config/nftban.logrotate"
    local logrotate_dst="/etc/logrotate.d/nftban"

    if [[ ! -f "$logrotate_dst" ]]; then
        if [[ -f "$logrotate_src" ]]; then
            cp "$logrotate_src" "$logrotate_dst" 2>/dev/null && {
                chown root:root "$logrotate_dst"
                chmod 0644 "$logrotate_dst"
                echo "  ✓ Installed logrotate config from $logrotate_src"
            } || {
                echo "  ⚠️  Cannot copy logrotate config (need root)" >&2
            }
        else
            # Create minimal logrotate config if source not found
            cat > "$logrotate_dst" 2>/dev/null <<'LOGROTATE'
# NFTBan Log Rotation (auto-generated by health fix)
/var/log/nftban/*.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 0640 nftban nftban
}

/var/log/nftban/suricata/eve.json {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0640 suricata nftban
    copytruncate
    size 100M
}
LOGROTATE
            if [[ -f "$logrotate_dst" ]]; then
                chown root:root "$logrotate_dst"
                chmod 0644 "$logrotate_dst"
                echo "  ✓ Created logrotate config"
            else
                echo "  ⚠️  Cannot create logrotate config (need root)" >&2
            fi
        fi
    else
        echo "  ✓ Logrotate already configured"
    fi

    return 0
}

nftban_health_fix_registry() {
    # Fix registry and generator issues
    # Returns: 0=fixed, 1=partial fix, 2=failed

    local status=0
    local registry="${NFTBAN_CONFIG_DIR:-/etc/nftban}/commands.registry.yml"

    echo "Checking registry configuration..."

    # Check if registry file exists
    if [[ ! -f "$registry" ]]; then
        echo "  ✖ ERROR: Registry file missing: $registry"
        echo "    This file should be installed by the package manager."
        echo "    Please reinstall nftban package to restore registry."
        return 2
    fi

    # Fix registry permissions (should be 644)
    local perms
    perms=$(stat -c "%a" "$registry" 2>/dev/null || stat -f "%Lp" "$registry" 2>/dev/null || echo "000")
    if [[ "$perms" != "644" ]]; then
        if chmod 644 "$registry" 2>/dev/null; then
            echo "  ✓ Fixed registry permissions: $perms → 644"
        else
            echo "  ⚠️  Cannot fix registry permissions (need root)"
            status=1
        fi
    fi

    # Fix registry ownership (should be root:root)
    local owner group
    owner=$(stat -c "%U" "$registry" 2>/dev/null || echo "unknown")
    group=$(stat -c "%G" "$registry" 2>/dev/null || echo "unknown")
    if [[ "$owner" != "root" ]] || [[ "$group" != "root" ]]; then
        if [[ $EUID -eq 0 ]]; then
            if chown root:root "$registry" 2>/dev/null; then
                echo "  ✓ Fixed registry ownership: $owner:$group → root:root"
            else
                echo "  ⚠️  Cannot fix registry ownership"
                status=1
            fi
        else
            echo "  ⚠️  Cannot fix registry ownership (need root)"
            status=1
        fi
    fi

    # Check YAML validity if yq available
    if command -v yq &>/dev/null; then
        if ! yq -r '._metadata.version' "$registry" >/dev/null 2>&1; then
            echo "  ✖ ERROR: Registry has invalid YAML syntax"
            echo "    Please reinstall nftban package to restore registry."
            return 2
        else
            echo "  ✓ Registry YAML is valid"
        fi
    else
        echo "  ⚠️  Cannot validate YAML (yq not installed)"
        echo "    Install: pip install yq  OR  brew install yq"
        status=1
    fi

    # Fix generator permissions (should be 755)
    echo ""
    echo "Checking documentation generators..."
    local generators=(
        "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/scripts/generate-help.sh"
        "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/scripts/generate-wiki-operator.sh"
        "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/scripts/generate-wiki-auditor.sh"
    )

    local generators_ok=true
    for gen in "${generators[@]}"; do
        if [[ ! -f "$gen" ]]; then
            echo "  ✖ ERROR: Generator missing: $(basename "$gen")"
            echo "    Please reinstall nftban package to restore generators."
            generators_ok=false
            status=2
        else
            # Check if executable
            if [[ ! -x "$gen" ]]; then
                if chmod +x "$gen" 2>/dev/null; then
                    echo "  ✓ Fixed generator permissions: $(basename "$gen")"
                else
                    echo "  ⚠️  Cannot fix generator permissions: $(basename "$gen") (need root)"
                    status=1
                fi
            else
                echo "  ✓ Generator OK: $(basename "$gen")"
            fi
        fi
    done

    if [[ "$generators_ok" == true ]]; then
        echo "  ✓ All generators present and executable"
    fi

    return $status
}

# =============================================================================
# REPORTING
# =============================================================================

nftban_health_render_terminal() {
    # Render health check results to terminal - Clean v1.0 layout

    # Helper function to create dot-padded labels (16 char width)
    # Usage: pad_with_dots "Label" -> "Label..........."
    pad_with_dots() {
        local label="$1"
        local width=16
        local len=${#label}
        local dots_needed
        dots_needed=$((width - len))
        if [[ $dots_needed -gt 0 ]]; then
            local dots=""
            for ((i=0; i<dots_needed; i++)); do dots+="."; done
            echo "${label}${dots}"
        else
            echo "$label"
        fi
    }

    # Labels for each check type
    local -A check_labels=(
        [binaries]="Binaries"
        [paths]="Paths"
        [permissions]="Permissions"
        [services]="Services"
        [modules]="Modules"
        [geoip]="GeoIP"
        [databases]="Databases"
        [polkit]="Polkit"
        [bash_completion]="Bash Complet"
        [config]="Configuration"
        [metrics]="Metrics"
        [gui]="Web GUI"
    )

    # Count errors and warnings
    local error_count=0
    local warning_count=0
    if [[ -n "${NFTBAN_HEALTH_ERRORS+x}" ]]; then
        error_count="${#NFTBAN_HEALTH_ERRORS[@]}"
    fi
    if [[ -n "${NFTBAN_HEALTH_WARNINGS+x}" ]]; then
        warning_count="${#NFTBAN_HEALTH_WARNINGS[@]}"
    fi

    # Header
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NFTBan System Health Check"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # SYSTEM CHECKS section
    echo "SYSTEM CHECKS"
    echo "───────────────────────────────────────────────────────────"

    for check in binaries paths permissions services modules config geoip databases; do
        if [[ -n "${NFTBAN_HEALTH_RESULTS[$check]:-}" ]]; then
            local status=${NFTBAN_HEALTH_RESULTS[$check]}
            local status_text

            case $status in
                0) status_text="OK" ;;
                1) status_text="WARNING" ;;
                2) status_text="ERROR" ;;
                *) status_text="UNKNOWN" ;;
            esac

            local label="${check_labels[$check]:-$check}"
            local padded_label
            padded_label=$(pad_with_dots "$label")

            printf "  %s %s\n" "$padded_label" "$status_text"

            if [[ -n "${NFTBAN_HEALTH_ISSUES[$check]:-}" && $status -gt 0 ]]; then
                echo "    Issue: ${NFTBAN_HEALTH_ISSUES[$check]}"
            fi
        fi
    done
    echo ""

    # OPTIONAL FEATURES section
    echo "OPTIONAL FEATURES"
    echo "───────────────────────────────────────────────────────────"

    for check in metrics gui polkit bash_completion; do
        if [[ -n "${NFTBAN_HEALTH_RESULTS[$check]:-}" ]]; then
            local status=${NFTBAN_HEALTH_RESULTS[$check]}
            local status_text

            case $status in
                0) status_text="OK" ;;
                1) status_text="WARNING" ;;
                2) status_text="ERROR" ;;
                3) status_text="CRITICAL" ;;
                4) status_text="NOT INSTALLED" ;;
                *) status_text="UNKNOWN" ;;
            esac

            local label="${check_labels[$check]:-$check}"
            local padded_label
            padded_label=$(pad_with_dots "$label")

            printf "  %s %s\n" "$padded_label" "$status_text"
        fi
    done
    echo ""

    # SUMMARY section
    echo "SUMMARY"
    echo "───────────────────────────────────────────────────────────"

    printf "  %s %d\n" "$(pad_with_dots "Errors")" "$error_count"
    printf "  %s %d\n" "$(pad_with_dots "Warnings")" "$warning_count"

    if [[ $error_count -eq 0 && $warning_count -eq 0 ]]; then
        printf "  %s OK\n" "$(pad_with_dots "Overall")"
    elif [[ $error_count -eq 0 ]]; then
        printf "  %s WARNING\n" "$(pad_with_dots "Overall")"
    else
        printf "  %s ERROR\n" "$(pad_with_dots "Overall")"
    fi
    echo ""

    # ERRORS section (only if errors exist)
    if [[ $error_count -gt 0 ]]; then
        echo "ERRORS"
        echo "───────────────────────────────────────────────────────────"
        for error in "${NFTBAN_HEALTH_ERRORS[@]}"; do
            echo "  - $error"
        done
        echo ""
    fi

    # WARNINGS section (only if warnings exist)
    if [[ $warning_count -gt 0 ]]; then
        echo "WARNINGS"
        echo "───────────────────────────────────────────────────────────"
        for warning in "${NFTBAN_HEALTH_WARNINGS[@]}"; do
            echo "  - $warning"
        done
        echo ""

        # Helpful context for optional features
        if [[ $error_count -eq 0 ]]; then
            echo "NOTE"
            echo "───────────────────────────────────────────────────────────"
            echo "  Warnings are about OPTIONAL features."
            echo "  Your firewall is working! You can safely ignore these."
            echo "  To enable optional features: nftban help"
            echo ""
        fi
    fi

    # QUICK COMMANDS section
    echo "QUICK COMMANDS"
    echo "───────────────────────────────────────────────────────────"
    echo "  nftban health fix        Auto-fix common issues"
    echo "  nftban health summary    One-line status"
    echo "  nftban health --json     JSON output for scripts"
    echo ""
}

nftban_health_render_summary() {
    # Render one-line summary of health status
    # Output: "Health: WARNING (2 warnings, 0 errors)"
    # Returns: Overall health status code

    # Count errors and warnings safely
    local error_count=0
    local warning_count=0

    if [[ -n "${NFTBAN_HEALTH_ERRORS+x}" ]]; then
        error_count="${#NFTBAN_HEALTH_ERRORS[@]}"
    fi
    if [[ -n "${NFTBAN_HEALTH_WARNINGS+x}" ]]; then
        warning_count="${#NFTBAN_HEALTH_WARNINGS[@]}"
    fi

    # Output summary based on status
    if [[ $error_count -eq 0 && $warning_count -eq 0 ]]; then
        echo "Health: OK"
        return 0
    elif [[ $error_count -eq 0 ]]; then
        echo "Health: WARNING ($warning_count warnings)"
        return 1
    else
        echo "Health: ERROR ($error_count errors, $warning_count warnings)"
        return 2
    fi
}

nftban_health_render_json() {
    # Render health check results as JSON
    # Output: Complete JSON object with all health data

    # JSON escape function - escapes special chars for valid JSON strings
    _json_escape() {
        local str="$1"
        # Escape backslashes first, then other special chars
        str="${str//\\/\\\\}"      # backslash
        str="${str//\"/\\\"}"      # double quote
        str="${str//$'\n'/\\n}"    # newline
        str="${str//$'\r'/\\r}"    # carriage return
        str="${str//$'\t'/\\t}"    # tab
        echo -n "$str"
    }

    # Count errors and warnings safely
    local error_count=0
    local warning_count=0

    if [[ -n "${NFTBAN_HEALTH_ERRORS+x}" ]]; then
        error_count="${#NFTBAN_HEALTH_ERRORS[@]}"
    fi
    if [[ -n "${NFTBAN_HEALTH_WARNINGS+x}" ]]; then
        warning_count="${#NFTBAN_HEALTH_WARNINGS[@]}"
    fi

    # Determine overall status
    local overall_status="ok"
    local exit_code=0
    if [[ $error_count -gt 0 ]]; then
        overall_status="error"
        exit_code=2
    elif [[ $warning_count -gt 0 ]]; then
        overall_status="warning"
        exit_code=1
    fi

    echo "{"
    echo "  \"timestamp\": \"$(date --iso-8601=seconds)\","
    echo "  \"overall_status\": \"$overall_status\","
    echo "  \"exit_code\": $exit_code,"
    echo "  \"summary\": {"
    echo "    \"errors\": $error_count,"
    echo "    \"warnings\": $warning_count"
    echo "  },"
    echo "  \"checks\": {"

    # Output each check result
    local first=true
    for check in binaries paths permissions services modules geoip databases config fhs metrics gui; do
        if [[ -n "${NFTBAN_HEALTH_RESULTS[$check]:-}" ]]; then
            [[ "$first" == "false" ]] && echo ","
            first=false

            local status="${NFTBAN_HEALTH_RESULTS[$check]}"
            local status_name="ok"
            [[ $status -eq 1 ]] && status_name="warning"
            [[ $status -eq 2 ]] && status_name="error"
            [[ $status -eq 3 ]] && status_name="critical"

            local issues="${NFTBAN_HEALTH_ISSUES[$check]:-}"
            local escaped_issues
            escaped_issues="$(_json_escape "$issues")"

            echo -n "    \"$check\": {\"status\": \"$status_name\", \"exit_code\": $status, \"message\": \"$escaped_issues\"}"
        fi
    done

    echo ""
    echo "  },"
    echo "  \"errors\": ["

    # Output errors array
    if [[ $error_count -gt 0 ]]; then
        local first_error=true
        for error in "${NFTBAN_HEALTH_ERRORS[@]}"; do
            [[ "$first_error" == "false" ]] && echo ","
            first_error=false
            local escaped_error
            escaped_error="$(_json_escape "$error")"
            echo -n "    \"$escaped_error\""
        done
        echo ""
    fi

    echo "  ],"
    echo "  \"warnings\": ["

    # Output warnings array
    if [[ $warning_count -gt 0 ]]; then
        local first_warn=true
        for warning in "${NFTBAN_HEALTH_WARNINGS[@]}"; do
            [[ "$first_warn" == "false" ]] && echo ","
            first_warn=false
            local escaped_warning
            escaped_warning="$(_json_escape "$warning")"
            echo -n "    \"$escaped_warning\""
        done
        echo ""
    fi

    echo "  ]"
    echo "}"

    return $exit_code
}

# =============================================================================
# INSTALLATION VERIFICATION
# =============================================================================

nftban_health_verify_installation() {
    # Comprehensive installation verification
    # Returns: 0=COMPLETE, 1=INCOMPLETE (warnings), 2=BROKEN (errors)
    # Args: $1 = verbose (0=summary, 1=detailed)

    local verbose="${1:-0}"
    local status=0
    local missing_required=()
    local missing_optional=()
    local issues=()

    echo ""
    echo "NFTBan Installation Verification"
    echo "════════════════════════════════════════════════════════════════"
    echo ""

    # ─────────────────────────────────────────────────────────────────────
    # 1. REQUIRED TIMERS
    # ─────────────────────────────────────────────────────────────────────
    echo "REQUIRED TIMERS"
    echo "───────────────────────────────────────────────────────────────"

    local -a required_timers=(
        "nftban-maintenance.timer"      # CRITICAL: SSH/IP lockout prevention
        "nftban-health.timer"           # Health checks
        "nftban-core-feeds.timer"       # Threat feeds
        "nftban-core-geoip.timer"       # GeoIP updates
        "nftban-queue.timer"            # Ban queue
        "nftban-watchdog.timer"         # System monitoring
        "nftban-metrics-exporter.timer" # Prometheus metrics
    )

    local -A timer_desc=(
        ["nftban-maintenance.timer"]="SSH/IP lockout prevention (CRITICAL)"
        ["nftban-health.timer"]="Health checks and auto-heal"
        ["nftban-core-feeds.timer"]="Threat feeds sync"
        ["nftban-core-geoip.timer"]="GeoIP database updates"
        ["nftban-queue.timer"]="Ban queue processing"
        ["nftban-watchdog.timer"]="System resource monitoring"
        ["nftban-metrics-exporter.timer"]="Prometheus metrics"
    )

    local timer_ok=0
    local timer_missing=0

    for timer in "${required_timers[@]}"; do
        if systemctl list-unit-files "$timer" --no-legend 2>/dev/null | grep -q "^$timer"; then
            if systemctl is-active --quiet "$timer" 2>/dev/null; then
                printf "  ✔ %-30s ACTIVE\n" "$timer"
                timer_ok=$((timer_ok + 1))
            elif systemctl is-enabled --quiet "$timer" 2>/dev/null; then
                printf "  ⚠ %-30s ENABLED (stopped)\n" "$timer"
                timer_ok=$((timer_ok + 1))
            else
                printf "  ✖ %-30s DISABLED\n" "$timer"
                missing_required+=("Timer: $timer (${timer_desc[$timer]})")
                timer_missing=$((timer_missing + 1))
            fi
        else
            printf "  ✖ %-30s NOT INSTALLED\n" "$timer"
            missing_required+=("Timer: $timer (${timer_desc[$timer]})")
            timer_missing=$((timer_missing + 1))
        fi
    done

    echo ""
    printf "  Summary: %d/%d timers OK\n" "$timer_ok" "${#required_timers[@]}"
    echo ""

    # ─────────────────────────────────────────────────────────────────────
    # 2. REQUIRED SERVICES
    # ─────────────────────────────────────────────────────────────────────
    echo "REQUIRED SERVICES"
    echo "───────────────────────────────────────────────────────────────"

    local -a required_services=(
        "nftables.service"
        "nftban-core.service"
    )

    local -a optional_services=(
        "nftban-login-monitor.service"
        "nftban-suricata.service"
        "nftban-ui.service"
    )

    local svc_ok=0
    local svc_missing=0

    for svc in "${required_services[@]}"; do
        if systemctl list-unit-files "$svc" --no-legend 2>/dev/null | grep -q "^$svc"; then
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                printf "  ✔ %-30s ACTIVE\n" "$svc"
                svc_ok=$((svc_ok + 1))
            elif systemctl is-enabled --quiet "$svc" 2>/dev/null; then
                printf "  ⚠ %-30s ENABLED (stopped)\n" "$svc"
                svc_ok=$((svc_ok + 1))
            else
                printf "  ✖ %-30s DISABLED\n" "$svc"
                missing_required+=("Service: $svc")
                svc_missing=$((svc_missing + 1))
            fi
        else
            printf "  ✖ %-30s NOT INSTALLED\n" "$svc"
            missing_required+=("Service: $svc")
            svc_missing=$((svc_missing + 1))
        fi
    done

    echo ""
    printf "  Summary: %d/%d services OK\n" "$svc_ok" "${#required_services[@]}"
    echo ""

    # ─────────────────────────────────────────────────────────────────────
    # 3. REQUIRED BINARIES (using distro config paths)
    # ─────────────────────────────────────────────────────────────────────
    echo "REQUIRED BINARIES"
    echo "───────────────────────────────────────────────────────────────"

    # Load distro config for correct paths
    if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_distro_config.sh" ]]; then
        source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_distro_config.sh" 2>/dev/null || true
        nftban_distro_load 2>/dev/null || true
    fi

    # Required binaries - check using command -v for distro independence
    local -a required_bins=(
        "nftban"
        "nft"
        "jq"
        "curl"
        "systemctl"
    )

    local -a optional_bins=(
        "nftban-core"
        "nftban-ui"
        "suricata"
    )

    local bin_ok=0
    local bin_missing=0
    local total_required=${#required_bins[@]}

    for name in "${required_bins[@]}"; do
        local bin_path=""

        # Try distro config path first
        if [[ -n "${DISTRO_PATHS[$name]:-}" ]] && [[ -x "${DISTRO_PATHS[$name]}" ]]; then
            bin_path="${DISTRO_PATHS[$name]}"
            printf "  ✔ %-15s OK (%s)\n" "$name" "$bin_path"
            bin_ok=$((bin_ok + 1))
        elif command -v "$name" &>/dev/null; then
            bin_path=$(command -v "$name")
            printf "  ✔ %-15s OK (%s)\n" "$name" "$bin_path"
            bin_ok=$((bin_ok + 1))
        else
            printf "  ✖ %-15s MISSING\n" "$name"
            missing_required+=("Binary: $name")
            bin_missing=$((bin_missing + 1))
        fi
    done

    echo ""
    printf "  Summary: %d/%d binaries OK\n" "$bin_ok" "$total_required"
    echo ""

    # ─────────────────────────────────────────────────────────────────────
    # 4. REQUIRED DIRECTORIES
    # ─────────────────────────────────────────────────────────────────────
    echo "REQUIRED DIRECTORIES"
    echo "───────────────────────────────────────────────────────────────"

    local -a required_dirs=(
        "${NFTBAN_CONFIG_DIR:-/etc/nftban}"
        "${NFTBAN_LIB_DIR:-/usr/lib/nftban}"
        "${NFTBAN_DATA_DIR:-/var/lib/nftban}"
        "${NFTBAN_LOG_DIR:-/var/log/nftban}"
        "${NFTBAN_RUN_DIR:-/run/nftban}"
    )

    local dir_ok=0
    local dir_missing=0

    for dir in "${required_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            printf "  ✔ %-30s OK\n" "$dir"
            dir_ok=$((dir_ok + 1))
        else
            printf "  ✖ %-30s MISSING\n" "$dir"
            missing_required+=("Directory: $dir")
            dir_missing=$((dir_missing + 1))
        fi
    done

    echo ""
    printf "  Summary: %d/%d directories OK\n" "$dir_ok" "${#required_dirs[@]}"
    echo ""

    # ─────────────────────────────────────────────────────────────────────
    # 5. REQUIRED CONFIG FILES
    # ─────────────────────────────────────────────────────────────────────
    echo "REQUIRED CONFIG FILES"
    echo "───────────────────────────────────────────────────────────────"

    local -a required_configs=(
        "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf"
        "${NFTBAN_CONFIG_DIR:-/etc/nftban}/whitelist.d/00-system.conf"
        "${NFTBAN_CONFIG_DIR:-/etc/nftban}/ports.d/00-ssh.conf"
    )

    local cfg_ok=0
    local cfg_missing=0

    for cfg in "${required_configs[@]}"; do
        if [[ -f "$cfg" ]]; then
            printf "  ✔ %-40s OK\n" "$cfg"
            cfg_ok=$((cfg_ok + 1))
        else
            printf "  ✖ %-40s MISSING\n" "$cfg"
            missing_required+=("Config: $cfg")
            cfg_missing=$((cfg_missing + 1))
        fi
    done

    echo ""
    printf "  Summary: %d/%d config files OK\n" "$cfg_ok" "${#required_configs[@]}"
    echo ""

    # ─────────────────────────────────────────────────────────────────────
    # 6. OPTIONAL COMPONENTS
    # ─────────────────────────────────────────────────────────────────────
    if [[ $verbose -eq 1 ]]; then
        echo "OPTIONAL COMPONENTS"
        echo "───────────────────────────────────────────────────────────────"

        for svc in "${optional_services[@]}"; do
            if systemctl list-unit-files "$svc" --no-legend 2>/dev/null | grep -q "^$svc"; then
                if systemctl is-active --quiet "$svc" 2>/dev/null; then
                    printf "  ✔ %-30s ACTIVE\n" "$svc"
                else
                    printf "  ○ %-30s INSTALLED (inactive)\n" "$svc"
                fi
            else
                printf "  ○ %-30s NOT INSTALLED\n" "$svc"
                missing_optional+=("$svc")
            fi
        done

        for bin in "${optional_binaries[@]}"; do
            if [[ -x "$bin" ]]; then
                printf "  ✔ %-30s OK\n" "$bin"
            else
                printf "  ○ %-30s NOT INSTALLED\n" "$bin"
                missing_optional+=("$bin")
            fi
        done
        echo ""
    fi

    # ─────────────────────────────────────────────────────────────────────
    # SUMMARY
    # ─────────────────────────────────────────────────────────────────────
    echo "════════════════════════════════════════════════════════════════"

    if [[ ${#missing_required[@]} -eq 0 ]]; then
        echo "✔ INSTALLATION COMPLETE"
        echo ""
        echo "All required components are installed and configured."
        status=0
    else
        echo "✖ INSTALLATION INCOMPLETE"
        echo ""
        echo "Missing required components (${#missing_required[@]}):"
        for item in "${missing_required[@]}"; do
            echo "  - $item"
        done
        echo ""
        echo "To fix, run:"
        echo "  nftban health fix"
        echo ""
        echo "Or reinstall the package."
        status=2
    fi

    if [[ ${#missing_optional[@]} -gt 0 && $verbose -eq 1 ]]; then
        echo ""
        echo "Optional components not installed (${#missing_optional[@]}):"
        for item in "${missing_optional[@]}"; do
            echo "  - $item"
        done
    fi

    echo "════════════════════════════════════════════════════════════════"
    echo ""

    return $status
}

# =============================================================================
# EXPORTS
# =============================================================================

# Export main functions
export -f nftban_health_init
export -f nftban_health_check_all

# Export check functions
export -f nftban_health_check_nftables_security
export -f nftban_health_check_conflicting_firewalls
export -f nftban_health_check_binaries
export -f nftban_health_check_paths
export -f nftban_health_check_permissions
export -f nftban_health_check_services
export -f nftban_health_check_modules
export -f nftban_health_check_geoip
export -f nftban_health_check_databases
export -f nftban_health_check_config
export -f nftban_health_check_registry
export -f nftban_health_check_metrics
# Removed: export fail2ban health check (v1.0 migration)
export -f nftban_health_check_timers
export -f nftban_health_check_gui

# Export fix functions
export -f nftban_health_fix_permissions
export -f nftban_health_fix_directories
export -f nftban_health_fix_services
export -f nftban_health_fix_registry

# Export render functions
export -f nftban_health_render_terminal
export -f nftban_health_render_summary
export -f nftban_health_render_json

# Export installation verification
export -f nftban_health_verify_installation
