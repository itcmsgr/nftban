#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.10.0 - Health Check System
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: System health checks and diagnostics
# Location: /usr/lib/nftban/core/nftban_health.sh
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
# nftban — Simplifying Linux Firewall Management
# Comprehensive system health verification and auto-fix
# =============================================================================

# Enhanced strict mode
set -Eeuo pipefail
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
    local lib_dir="/usr/lib/nftban"

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
        NFTBAN_HEALTH_WARNINGS+=("Missing optional binaries: ${missing_optional[*]}")
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
        "/usr/lib/nftban"
        "/usr/lib/nftban/core"
        "/usr/lib/nftban/cli"
        "/etc/nftban"
        "/var/lib/nftban"
        "/var/log/nftban"
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
        "/usr/lib/nftban/core/nftban_output.sh"
    )

    for file in "${critical_files[@]}"; do
        if [[ -f "$file" ]]; then
            if [[ ! -r "$file" ]]; then
                permission_issues+=("$file not readable")
                status=$HEALTH_ERROR
            fi
        fi
    done

    # Check /etc/nftban config files should be nftban:nftban 644
    local config_files=(
        "/etc/nftban/portscan_whitelist.conf"
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

    # Check /var/lib/nftban ownership
    if [[ -d "/var/lib/nftban" ]]; then
        local owner
        owner=$(stat -c '%U' /var/lib/nftban 2>/dev/null || echo "unknown")
        if [[ "$owner" != "nftban" && "$owner" != "root" ]]; then
            permission_issues+=("/var/lib/nftban has incorrect owner: $owner")
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
        "nftban-login-monitor.service"
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
        local module_path="/usr/lib/nftban/core/$module"
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
# GEOIP CHECKS
# =============================================================================

nftban_health_check_geoip() {
    # Check GO GeoIP system
    # Returns: 0=OK, 1=Warning, 2=Error

    local status=$HEALTH_OK
    local geoip_issues=()

    local binary_path="/usr/lib/nftban/bin/nftban-geoip"
    local db_path="/var/lib/nftban/geoip/GeoLite2-City.mmdb"
    local wrapper_path="/usr/lib/nftban/core/nftban_geoip_go.sh"

    # Check binary
    if [[ ! -f "$binary_path" ]]; then
        geoip_issues+=("Binary not found: $binary_path")
        status=$HEALTH_WARNING
    elif [[ ! -x "$binary_path" ]]; then
        geoip_issues+=("Binary not executable: $binary_path")
        status=$HEALTH_WARNING
    else
        # Test binary
        if ! "$binary_path" version >/dev/null 2>&1; then
            geoip_issues+=("Binary test failed")
            status=$HEALTH_WARNING
        fi
    fi

    # Check database
    if [[ ! -f "$db_path" ]]; then
        geoip_issues+=("Database not found: $db_path")
        status=$HEALTH_WARNING
    elif [[ ! -r "$db_path" ]]; then
        geoip_issues+=("Database not readable: $db_path")
        status=$HEALTH_WARNING
    fi

    # Check wrapper
    if [[ ! -f "$wrapper_path" ]]; then
        geoip_issues+=("Wrapper not found: $wrapper_path")
        status=$HEALTH_WARNING
    fi

    # Performance test (only if everything exists)
    if [[ -x "$binary_path" && -f "$db_path" ]]; then
        local start_time end_time elapsed
        start_time=$(date +%s%N)
        if "$binary_path" lookup 8.8.8.8 >/dev/null 2>&1; then
            end_time=$(date +%s%N)
            elapsed=$(( (end_time - start_time) / 1000 ))

            if (( elapsed > 10000 )); then
                geoip_issues+=("Performance degraded: ${elapsed}μs (expected <1000μs)")
                status=$HEALTH_WARNING
            fi
        else
            geoip_issues+=("Lookup test failed")
            status=$HEALTH_WARNING
        fi
    fi

    # Store results
    if [[ ${#geoip_issues[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["geoip"]="${geoip_issues[*]}"
        NFTBAN_HEALTH_WARNINGS+=("GeoIP issues: ${geoip_issues[*]}")
    fi

    NFTBAN_HEALTH_RESULTS["geoip"]=$status
    return $status
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
    local geolite2="/var/lib/nftban/geoip/GeoLite2-City.mmdb"
    if [[ -f "$geolite2" ]]; then
        # Check age (warn if >90 days old)
        local file_age
        file_age=$(( $(date +%s) - $(stat -c %Y "$geolite2" 2>/dev/null || echo 0) ))
        local days_old=$(( file_age / 86400 ))

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
    return $status
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
    if [[ ! -d "/etc/nftban" ]]; then
        config_issues+=("Config directory not found: /etc/nftban")
        status=$HEALTH_ERROR
    fi

    # Check for basic config files
    local config_dir="/etc/nftban/conf.d"
    if [[ -d "$config_dir" ]]; then
        # Try to source config files (in subshell)
        for conf_file in "$config_dir"/*.conf; do
            if [[ -f "$conf_file" ]]; then
                if ! (source "$conf_file") 2>/dev/null; then
                    config_issues+=("Config has syntax errors: $(basename "$conf_file")")
                    status=$HEALTH_ERROR
                fi
            fi
        done
    fi

    # Check system.conf (UID/GID configuration)
    local system_conf="/var/lib/nftban/config/system.conf"
    if [[ ! -f "$system_conf" ]]; then
        config_issues+=("System config missing: $system_conf (will auto-create)")
        [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
    else
        # Verify system.conf is readable and has valid syntax
        if ! (source "$system_conf") 2>/dev/null; then
            config_issues+=("System config has syntax errors: $system_conf")
            status=$HEALTH_ERROR
        else
            # Verify UID/GID values match actual system
            source "$system_conf" 2>/dev/null
            local actual_uid actual_gid actual_cli_gid
            actual_uid=$(id -u nftban 2>/dev/null || echo "MISSING")
            actual_gid=$(id -g nftban 2>/dev/null || echo "MISSING")
            actual_cli_gid=$(getent group nftban-cli 2>/dev/null | cut -d: -f3 || echo "MISSING")

            if [[ "$actual_uid" != "$NFTBAN_UID" ]] || \
               [[ "$actual_gid" != "$NFTBAN_GID" ]] || \
               [[ "$actual_cli_gid" != "$NFTBAN_CLI_GID" ]]; then
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
# COMPREHENSIVE HEALTH CHECK
# =============================================================================

nftban_health_check_all() {
    # Run all health checks (ORCHESTRATES existing report modules!)
    # Returns: 0=Healthy, 1=Warnings, 2=Errors, 3=Critical

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

    # Binaries check (keep for now - no dedicated module)
    check_result=0
    nftban_health_check_binaries || check_result=$?
    [[ $check_result -gt $overall_status ]] && overall_status=$check_result

    # GeoIP check (keep for now - no dedicated module)
    check_result=0
    nftban_health_check_geoip || check_result=$?
    [[ $check_result -gt $overall_status ]] && overall_status=$check_result

    # Databases check (keep for now - no dedicated module)
    check_result=0
    nftban_health_check_databases || check_result=$?
    [[ $check_result -gt $overall_status ]] && overall_status=$check_result

    # Config check (keep for now - no dedicated module)
    check_result=0
    nftban_health_check_config || check_result=$?
    [[ $check_result -gt $overall_status ]] && overall_status=$check_result

    return $overall_status
}

# =============================================================================
# AUTO-FIX FUNCTIONS
# =============================================================================

nftban_health_fix_permissions() {
    # Fix ALL permissions and ownership to match FHS specification
    # Uses canonical FHS spec from nftban_fhs_spec.sh (SINGLE SOURCE OF TRUTH)
    # Smart about privileges: fixes what it can, reports what needs root

    local running_as_root=0
    [[ $EUID -eq 0 ]] && running_as_root=1

    echo "Fixing permissions and ownership..."

    # Load canonical FHS specification
    if ! declare -f nftban_fhs_load_spec >/dev/null 2>&1; then
        source /usr/lib/nftban/core/nftban_fhs_spec.sh || {
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
            local current_perms=$(stat -c "%a" "$dir" 2>/dev/null || echo "")
            local current_owner=$(stat -c "%U" "$dir" 2>/dev/null || echo "")
            local current_group=$(stat -c "%G" "$dir" 2>/dev/null || echo "")

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
                ((fixed_count++))
            fi
        fi
    done

    # Fix system binaries (only if root)
    if [[ $running_as_root -eq 1 ]]; then
        if [[ -f "/usr/sbin/nftban" ]]; then
            chmod 755 /usr/sbin/nftban 2>/dev/null && \
            chown root:root /usr/sbin/nftban 2>/dev/null && \
            echo "  ✓ Fixed /usr/sbin/nftban" && \
            ((fixed_count++))
        fi

        if [[ -f "/usr/lib/nftban/bin/nftban-geoip" ]]; then
            chmod 755 /usr/lib/nftban/bin/nftban-geoip 2>/dev/null && \
            chown root:root /usr/lib/nftban/bin/nftban-geoip 2>/dev/null && \
            echo "  ✓ Fixed /usr/lib/nftban/bin/nftban-geoip" && \
            ((fixed_count++))
        fi

        # Recursively fix ownership for system libraries
        if [[ -d "/usr/lib/nftban" ]]; then
            find /usr/lib/nftban -type f -name "*.sh" -exec chown root:root {} \; 2>/dev/null && \
            find /usr/lib/nftban -type f -name "*.sh" -exec chmod 644 {} \; 2>/dev/null && \
            echo "  ✓ Fixed /usr/lib/nftban module ownership (root:root)" && \
            ((fixed_count++))
        fi

        if [[ -d "/usr/share/nftban" ]]; then
            chown -R root:root /usr/share/nftban 2>/dev/null && \
            echo "  ✓ Fixed /usr/share/nftban ownership (root:root)" && \
            ((fixed_count++))
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
        source /usr/lib/nftban/core/nftban_fhs_spec.sh || {
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
            local parent_dir=$(dirname "$dir")
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
                    ((fixed_count++))
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
        "nftban-login-monitor.service"
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
    # Create or update /var/lib/nftban/config/system.conf with current UID/GID
    # This ensures we always have a reference for the actual system IDs

    local system_conf="/var/lib/nftban/config/system.conf"
    local config_dir="/var/lib/nftban/config"

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
    local nftban_uid nftban_gid nftban_cli_gid
    nftban_uid=$(id -u nftban 2>/dev/null || echo "MISSING")
    nftban_gid=$(id -g nftban 2>/dev/null || echo "MISSING")
    nftban_cli_gid=$(getent group nftban-cli 2>/dev/null | cut -d: -f3 || echo "MISSING")

    # Verify users/groups exist
    if [[ "$nftban_uid" == "MISSING" ]] || [[ "$nftban_gid" == "MISSING" ]] || [[ "$nftban_cli_gid" == "MISSING" ]]; then
        echo "  ✖ ERROR: nftban user or nftban-cli group not found" >&2
        echo "    Run installer to create system users/groups" >&2
        return 1
    fi

    # Check if update needed
    local needs_update=0
    if [[ ! -f "$system_conf" ]]; then
        needs_update=1
        echo "  → System config missing, will create"
    else
        # Source existing config and check for mismatches
        local existing_uid existing_gid existing_cli_gid
        if source "$system_conf" 2>/dev/null; then
            existing_uid="${NFTBAN_UID:-}"
            existing_gid="${NFTBAN_GID:-}"
            existing_cli_gid="${NFTBAN_CLI_GID:-}"

            if [[ "$existing_uid" != "$nftban_uid" ]] || \
               [[ "$existing_gid" != "$nftban_gid" ]] || \
               [[ "$existing_cli_gid" != "$nftban_cli_gid" ]]; then
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

NFTBAN_USER="nftban"
NFTBAN_UID=${nftban_uid}
NFTBAN_GROUP="nftban"
NFTBAN_GID=${nftban_gid}
NFTBAN_CLI_GROUP="nftban-cli"
NFTBAN_CLI_GID=${nftban_cli_gid}
EOF

        chown root:root "$system_conf"
        chmod 0644 "$system_conf"
        echo "  ✓ Updated $system_conf"
        echo "    nftban UID=$nftban_uid GID=$nftban_gid, nftban-cli GID=$nftban_cli_gid"
    else
        echo "  ✓ System config is up to date"
    fi

    return 0
}

# =============================================================================
# REPORTING
# =============================================================================

nftban_health_render_terminal() {
    # Render health check results to terminal

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  NFTBan System Health Check"
    echo "═══════════════════════════════════════════════════════════"
    echo ""

    # Display results
    for check in binaries paths permissions services modules geoip databases config; do
        if [[ -n "${NFTBAN_HEALTH_RESULTS[$check]:-}" ]]; then
            local status=${NFTBAN_HEALTH_RESULTS[$check]}
            local symbol status_name

            # Get status symbol
            case $status in
                0) symbol="✅" ;;
                1) symbol="⚠️ " ;;
                2) symbol="❌" ;;
                *) symbol="❓" ;;
            esac

            # Get status text
            case $status in
                0) status_name="OK" ;;
                1) status_name="WARNING" ;;
                2) status_name="ERROR" ;;
                *) status_name="UNKNOWN" ;;
            esac

            printf "%s %-20s %s\n" \
                "$symbol" \
                "$(echo ${check^} | sed 's/_/ /g'):" \
                "$status_name"

            if [[ -n "${NFTBAN_HEALTH_ISSUES[$check]:-}" ]]; then
                echo "  └─ ${NFTBAN_HEALTH_ISSUES[$check]}"
            fi
        fi
    done

    echo ""

    # Overall status (count errors and warnings safely)
    local error_count=0
    local warning_count=0
    # Count errors (if array has elements)
    if [[ -n "${NFTBAN_HEALTH_ERRORS+x}" ]]; then
        error_count="${#NFTBAN_HEALTH_ERRORS[@]}"
    fi
    # Count warnings (if array has elements)
    if [[ -n "${NFTBAN_HEALTH_WARNINGS+x}" ]]; then
        warning_count="${#NFTBAN_HEALTH_WARNINGS[@]}"
    fi

    echo "═══════════════════════════════════════════════════════════"
    if [[ $error_count -eq 0 && $warning_count -eq 0 ]]; then
        echo "  Overall Status: ✅ OK"
    elif [[ $error_count -eq 0 ]]; then
        echo "  Overall Status: ⚠️  WARNING (${warning_count} warnings)"
    else
        echo "  Overall Status: ❌ ERROR"
        echo "  Errors: $error_count, Warnings: $warning_count"
    fi
    echo "═══════════════════════════════════════════════════════════"
    echo ""

    # Show errors
    if [[ $error_count -gt 0 ]]; then
        echo "Errors:"
        for error in "${NFTBAN_HEALTH_ERRORS[@]}"; do
            echo "  ❌ $error"
        done
        echo ""
    fi

    # Show warnings
    if [[ $warning_count -gt 0 ]]; then
        echo "Warnings:"
        for warning in "${NFTBAN_HEALTH_WARNINGS[@]}"; do
            echo "  ⚠️  $warning"
        done
        echo ""
    fi
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
    for check in binaries paths permissions services modules geoip databases config fhs; do
        if [[ -n "${NFTBAN_HEALTH_RESULTS[$check]:-}" ]]; then
            [[ "$first" == "false" ]] && echo ","
            first=false

            local status="${NFTBAN_HEALTH_RESULTS[$check]}"
            local status_name="ok"
            [[ $status -eq 1 ]] && status_name="warning"
            [[ $status -eq 2 ]] && status_name="error"
            [[ $status -eq 3 ]] && status_name="critical"

            local issues="${NFTBAN_HEALTH_ISSUES[$check]:-}"

            echo -n "    \"$check\": {\"status\": \"$status_name\", \"exit_code\": $status, \"message\": \"$issues\"}"
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
            echo -n "    \"$error\""
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
            echo -n "    \"$warning\""
        done
        echo ""
    fi

    echo "  ]"
    echo "}"

    return $exit_code
}

# =============================================================================
# EXPORTS
# =============================================================================

# Export main functions
export -f nftban_health_init
export -f nftban_health_check_all

# Export check functions
export -f nftban_health_check_binaries
export -f nftban_health_check_paths
export -f nftban_health_check_permissions
export -f nftban_health_check_services
export -f nftban_health_check_modules
export -f nftban_health_check_geoip
export -f nftban_health_check_databases
export -f nftban_health_check_config

# Export fix functions
export -f nftban_health_fix_permissions
export -f nftban_health_fix_directories
export -f nftban_health_fix_services

# Export render functions
export -f nftban_health_render_terminal
export -f nftban_health_render_summary
export -f nftban_health_render_json
