#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034  # SC1090: Dynamic paths; SC2034: Global arrays used by render module
# =============================================================================
# NFTBan v1.0 - Health Check Core Functions
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Core health check functions (helpers, binaries, paths, permissions, resources, fhs)
#
# meta:name="nftban_health_checks_core"
# meta:type="lib"
# meta:header="Health Check Core Functions"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Core health check functions for system verification"
# meta:depends="nftban_health.sh"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="nftban"
# meta:created_date="2026-02-04"
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_NFTBAN_HEALTH_CHECKS_CORE_LOADED:-}" ]] && return 0
_NFTBAN_HEALTH_CHECKS_CORE_LOADED=1

# Source shared libraries
NFTBAN_LIB_DIR="${NFTBAN_LIB_DIR:-/usr/lib/nftban}"
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/nftban_alert_throttle.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/nftban_file_utils.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/nftban_service_control.sh" 2>/dev/null || true

# =============================================================================
# COMMON HELPER FUNCTIONS
# =============================================================================

# Wrapper functions that delegate to shared libraries
_health_service_active() {
    nftban_service_is_active "$1" 2>/dev/null
}

_health_service_enabled() {
    nftban_service_is_enabled "$1" 2>/dev/null
}

_health_service_exists() {
    nftban_service_exists "$1" 2>/dev/null
}

# Wrapper functions that delegate to shared file utils library
_health_file_age() {
    nftban_file_age "$1"
}

_health_file_fresh() {
    nftban_file_is_fresh "$1" "${2:-120}"
}

_health_http_check() {
    local url="$1" timeout="${2:-${NFTBAN_TIMEOUT_FAST:-3}}"
    command -v curl >/dev/null 2>&1 || return 1
    curl -k -s --connect-timeout "$timeout" "$url" >/dev/null 2>&1
}

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

_health_check_metrics_file() {
    local filepath="$1" name="$2"
    # shellcheck disable=SC2178
    local -n issues_ref="$3"
    # shellcheck disable=SC2178
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
# ALERT THROTTLING HELPER (uses unified library)
# =============================================================================

# nftban_health_should_alert - Wrapper for backward compatibility
# Delegates to the unified nftban_should_alert() function
#
# Arguments:
#   $1 - alert_key: Unique identifier for the alert type
#
# Returns:
#   0 - Should send alert
#   1 - Alert is throttled
#
nftban_health_should_alert() {
    local alert_key="$1"
    local throttle_seconds="${NFTBAN_ALERT_THROTTLE_SECONDS:-3600}"
    local state_dir="${NFTBAN_DATA_DIR:-/var/lib/nftban}/state"

    # Prefix with 'health_' to namespace health check alerts
    nftban_should_alert "health_${alert_key}" "$throttle_seconds" "$state_dir"
}

# =============================================================================
# BINARY CHECKS
# =============================================================================

nftban_health_check_binaries() {
    local status=$HEALTH_OK
    local required_binaries=("nft" "systemctl" "journalctl" "awk" "sed" "grep" "jq" "curl" "wget" "socat")
    local nftban_binaries=("${NFTBAN_LIB_DIR:-/usr/lib/nftban}/bin/nftban-core" "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/bin/nftband")
    local mail_binaries=("mail" "sendmail")

    local missing_required=() missing_mail=() broken_nftban=()

    for binary in "${required_binaries[@]}"; do
        if ! command -v "$binary" >/dev/null 2>&1; then
            missing_required+=("$binary")
            status=$HEALTH_ERROR
        fi
    done

    for binary in "${nftban_binaries[@]}"; do
        if [[ ! -f "$binary" ]]; then
            broken_nftban+=("$binary (missing)")
            status=$HEALTH_ERROR
        elif [[ ! -x "$binary" ]]; then
            broken_nftban+=("$binary (not executable)")
            status=$HEALTH_ERROR
        fi
    done

    [[ ${#broken_nftban[@]} -gt 0 ]] && NFTBAN_HEALTH_ERRORS+=("NFTBan binaries broken: ${broken_nftban[*]}")

    local is_panel=0
    [[ -d "/usr/local/cpanel" || -d "/usr/local/directadmin" || -d "/usr/local/psa" ]] && is_panel=1

    for binary in "${mail_binaries[@]}"; do
        command -v "$binary" >/dev/null 2>&1 || missing_mail+=("$binary")
    done

    [[ ${#missing_required[@]} -gt 0 ]] && NFTBAN_HEALTH_ERRORS+=("Missing required binaries: ${missing_required[*]}")
    [[ ${#missing_mail[@]} -gt 0 && $is_panel -eq 0 ]] && { NFTBAN_HEALTH_WARNINGS+=("Mail notifications disabled"); [[ $status -eq $HEALTH_OK ]] && status=$HEALTH_WARNING; }

    NFTBAN_HEALTH_RESULTS["binaries"]=$status
    return $status
}

# =============================================================================
# PATH CHECKS
# =============================================================================

nftban_health_check_paths() {
    local status=$HEALTH_OK
    local missing_paths=()
    local critical_paths=("${NFTBAN_LIB_DIR}" "${NFTBAN_LIB_DIR}/core" "${NFTBAN_LIB_DIR}/cli" "${NFTBAN_CONFIG_DIR}" "${NFTBAN_DATA_DIR}" "${NFTBAN_LOG_DIR}")

    for path in "${critical_paths[@]}"; do
        [[ ! -d "$path" ]] && { missing_paths+=("$path"); status=$HEALTH_ERROR; }
    done

    [[ ${#missing_paths[@]} -gt 0 ]] && { NFTBAN_HEALTH_ISSUES["paths"]="Missing: ${missing_paths[*]}"; NFTBAN_HEALTH_ERRORS+=("Missing critical paths: ${missing_paths[*]}"); }
    NFTBAN_HEALTH_RESULTS["paths"]=$status
    return $status
}

# =============================================================================
# PERMISSION CHECKS
# =============================================================================

nftban_health_check_permissions() {
    local status=$HEALTH_OK
    local permission_issues=()

    if ! id -u nftban >/dev/null 2>&1; then
        permission_issues+=("User 'nftban' does not exist")
        status=$HEALTH_ERROR
    fi

    local critical_files=("${NFTBAN_BIN:-/usr/sbin/nftban}" "${NFTBAN_LIB_DIR}/core/nftban_output.sh")
    for file in "${critical_files[@]}"; do
        [[ -f "$file" && ! -r "$file" ]] && { permission_issues+=("$file not readable"); status=$HEALTH_ERROR; }
    done

    if [[ -d "${NFTBAN_DATA_DIR}" ]]; then
        local owner; owner=$(stat -c '%U' "${NFTBAN_DATA_DIR}" 2>/dev/null || echo "unknown")
        [[ "$owner" != "nftban" && "$owner" != "root" ]] && { permission_issues+=("${NFTBAN_DATA_DIR} has incorrect owner: $owner"); status=$HEALTH_WARNING; }
    fi

    local fhs_dirs=("/run/nftban:nftban:nftban:755" "/var/log/nftban:nftban:nftban:750" "/var/cache/nftban:nftban:nftban:755")
    for entry in "${fhs_dirs[@]}"; do
        IFS=':' read -r dir expected_owner expected_group expected_perms <<< "$entry"
        [[ -d "$dir" ]] || continue
        local actual_owner actual_group actual_perms
        actual_owner=$(stat -c '%U' "$dir" 2>/dev/null)
        actual_group=$(stat -c '%G' "$dir" 2>/dev/null)
        actual_perms=$(stat -c '%a' "$dir" 2>/dev/null)
        [[ "$actual_owner" != "$expected_owner" ]] && { permission_issues+=("$dir owner is $actual_owner (expected $expected_owner)"); status=$HEALTH_ERROR; }
        [[ "$actual_group" != "$expected_group" ]] && { permission_issues+=("$dir group is $actual_group (expected $expected_group)"); status=$HEALTH_ERROR; }
        [[ "$actual_perms" != "$expected_perms" ]] && { permission_issues+=("$dir perms is $actual_perms (expected $expected_perms)"); status=$HEALTH_ERROR; }
    done

    [[ ${#permission_issues[@]} -gt 0 ]] && { NFTBAN_HEALTH_ISSUES["permissions"]="${permission_issues[*]}"; [[ $status -eq $HEALTH_ERROR ]] && NFTBAN_HEALTH_ERRORS+=("Permission issues: ${permission_issues[*]}") || NFTBAN_HEALTH_WARNINGS+=("Permission warnings: ${permission_issues[*]}"); }
    NFTBAN_HEALTH_RESULTS["permissions"]=$status
    return $status
}

# =============================================================================
# AUDITOR ACL CHECKS
# =============================================================================
# Verifies nftban-auditor group has correct ACL access for read-only audit.
# ACLs should be set on: /etc/nftban, /var/log/nftban, /var/lib/nftban
# This enables auto-heal to trigger ACL setup if missing.
# =============================================================================

nftban_health_check_auditor_acls() {
    local auto_heal="${1:-0}"
    local status=$HEALTH_OK
    local acl_issues=()

    # Skip if setfacl not available (ACLs not supported)
    if ! command -v getfacl &>/dev/null; then
        NFTBAN_HEALTH_RESULTS["auditor_acls"]=$HEALTH_OK
        return $HEALTH_OK
    fi

    # Skip if nftban-auditor group doesn't exist
    if ! getent group nftban-auditor &>/dev/null; then
        NFTBAN_HEALTH_RESULTS["auditor_acls"]=$HEALTH_OK
        return $HEALTH_OK
    fi

    # Critical directories that should have auditor ACLs
    local acl_dirs=("/etc/nftban" "/var/log/nftban" "/var/lib/nftban")

    for dir in "${acl_dirs[@]}"; do
        [[ -d "$dir" ]] || continue

        # Check if nftban-auditor group has ACL entry (x permission for traversal)
        if ! getfacl -p "$dir" 2>/dev/null | grep -q "^group:nftban-auditor:"; then
            acl_issues+=("$dir missing auditor ACL")
            status=$HEALTH_WARNING
        fi
    done

    # Auto-heal: Set ACLs if missing
    if [[ ${#acl_issues[@]} -gt 0 ]]; then
        if [[ $auto_heal -eq 1 ]] || [[ "${NFTBAN_HEALTH_AUTO_HEAL:-false}" == "true" ]]; then
            if [[ $EUID -eq 0 ]]; then
                # Try to source and call the install ACL function
                local lib_dir="${NFTBAN_LIB_DIR:-/usr/lib/nftban}"
                if [[ -f "${lib_dir}/setup/fhs-permissions.sh" ]]; then
                    # shellcheck source=/dev/null
                    source "${lib_dir}/setup/fhs-permissions.sh" 2>/dev/null
                    if declare -f nftban_install_set_auditor_acls &>/dev/null; then
                        nftban_install_set_auditor_acls 2>/dev/null && {
                            acl_issues+=("AUTO-FIXED: Auditor ACLs configured")
                            status=$HEALTH_OK
                        }
                    fi
                fi
                # Fallback: Use health fix function if available
                if [[ $status -ne $HEALTH_OK ]] && declare -f nftban_health_fix_auditor_acls &>/dev/null; then
                    nftban_health_fix_auditor_acls 2>/dev/null && {
                        acl_issues+=("AUTO-FIXED: Auditor ACLs configured (via health fix)")
                        status=$HEALTH_OK
                    }
                fi
            else
                acl_issues+=("NEEDS ROOT: Run 'sudo nftban health fix permissions' to set ACLs")
            fi
        else
            acl_issues+=("FIX: Run 'sudo nftban health fix permissions' or 'sudo nftban permissions enforce'")
        fi
    fi

    [[ ${#acl_issues[@]} -gt 0 ]] && {
        NFTBAN_HEALTH_ISSUES["auditor_acls"]="${acl_issues[*]}"
        if [[ $status -eq $HEALTH_WARNING ]]; then
            NFTBAN_HEALTH_WARNINGS+=("Auditor ACL issues: ${acl_issues[*]}")
        fi
    }
    NFTBAN_HEALTH_RESULTS["auditor_acls"]=$status
    return $status
}

# =============================================================================
# SYSTEM RESOURCE CHECKS
# =============================================================================

nftban_health_check_resources() {
    local status=$HEALTH_OK
    local resource_issues=()
    local DISK_WARN_THRESHOLD=${NFTBAN_DISK_WARN_THRESHOLD:-85}
    local DISK_CRIT_THRESHOLD=${NFTBAN_DISK_CRIT_THRESHOLD:-95}
    local RAM_WARN_THRESHOLD=${NFTBAN_RAM_WARN_THRESHOLD:-90}
    local RAM_CRIT_THRESHOLD=${NFTBAN_RAM_CRIT_THRESHOLD:-95}

    local critical_mounts=("/" "/var" "/var/log" "/tmp")
    for mount_point in "${critical_mounts[@]}"; do
        if [[ -d "$mount_point" ]]; then
            local disk_usage; disk_usage=$(df -h "$mount_point" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
            if [[ -n "$disk_usage" && "$disk_usage" =~ ^[0-9]+$ ]]; then
                [[ $disk_usage -ge $DISK_CRIT_THRESHOLD ]] && { resource_issues+=("CRITICAL: $mount_point disk at ${disk_usage}%"); status=$HEALTH_ERROR; }
                [[ $disk_usage -ge $DISK_WARN_THRESHOLD && $disk_usage -lt $DISK_CRIT_THRESHOLD ]] && { resource_issues+=("WARNING: $mount_point disk at ${disk_usage}%"); [[ $status -eq $HEALTH_OK ]] && status=$HEALTH_WARNING; }
            fi
        fi
    done

    if command -v free >/dev/null 2>&1; then
        local mem_total mem_available mem_used_percent
        mem_total=$(free -m | awk '/^Mem:/ {print $2}')
        mem_available=$(free -m | awk '/^Mem:/ {print $7}')
        if [[ -n "$mem_total" && -n "$mem_available" && "$mem_total" -gt 0 ]]; then
            mem_used_percent=$(( 100 - (mem_available * 100 / mem_total) ))
            [[ $mem_used_percent -ge $RAM_CRIT_THRESHOLD ]] && { resource_issues+=("CRITICAL: RAM at ${mem_used_percent}%"); status=$HEALTH_ERROR; }
            [[ $mem_used_percent -ge $RAM_WARN_THRESHOLD && $mem_used_percent -lt $RAM_CRIT_THRESHOLD ]] && { resource_issues+=("WARNING: RAM at ${mem_used_percent}%"); [[ $status -eq $HEALTH_OK ]] && status=$HEALTH_WARNING; }
        fi
    fi

    [[ ${#resource_issues[@]} -gt 0 ]] && { NFTBAN_HEALTH_ISSUES["resources"]="${resource_issues[*]}"; [[ $status -eq $HEALTH_ERROR ]] && NFTBAN_HEALTH_ERRORS+=("Resource issues: ${resource_issues[*]}") || NFTBAN_HEALTH_WARNINGS+=("Resource warnings: ${resource_issues[*]}"); }
    NFTBAN_HEALTH_RESULTS["resources"]=$status
    return "$status"
}

# =============================================================================
# FHS COMPLIANCE CHECK
# =============================================================================

nftban_health_check_fhs() {
    local status=$HEALTH_OK
    local fhs_issues=()

    if ! declare -f nftban_fhs_check_all >/dev/null 2>&1; then
        if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_report_fhs.sh" ]]; then
            source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_report_fhs.sh" 2>/dev/null || {
                fhs_issues+=("Cannot load FHS report module")
                NFTBAN_HEALTH_RESULTS["fhs"]=$HEALTH_ERROR
                return 2
            }
        else
            fhs_issues+=("FHS report module not found")
            NFTBAN_HEALTH_RESULTS["fhs"]=$HEALTH_ERROR
            return 2
        fi
    fi

    nftban_fhs_check_all
    local ok_count=0 error_count=0 missing_count=0
    for path in "${!NFTBAN_FHS_STATUS[@]}"; do
        local fhs_status="${NFTBAN_FHS_STATUS[$path]}"
        [[ "$fhs_status" == "OK" ]] && ok_count=$((ok_count + 1))
        [[ "$fhs_status" == "MISSING" ]] && missing_count=$((missing_count + 1))
        [[ "$fhs_status" != "OK" && "$fhs_status" != "MISSING" ]] && error_count=$((error_count + 1))
    done

    local total=${#NFTBAN_FHS_DIRECTORIES[@]}
    [[ $error_count -gt 0 ]] && { fhs_issues+=("FHS: $ok_count/$total OK, $error_count errors, $missing_count missing"); status=$HEALTH_ERROR; }
    [[ $missing_count -gt 0 && $error_count -eq 0 ]] && { fhs_issues+=("FHS: $ok_count/$total OK, $missing_count missing"); status=$HEALTH_WARNING; }

    [[ ${#fhs_issues[@]} -gt 0 ]] && NFTBAN_HEALTH_ISSUES["fhs"]="${fhs_issues[*]}"
    NFTBAN_HEALTH_RESULTS["fhs"]=$status
    return $status
}

# =============================================================================
# QUEUE PROCESSOR CHECK (Bug #21: Permission issues cause service failure)
# =============================================================================

# =============================================================================
# NFTBAN_BIN CONFIG CHECK (Prevent path misconfig across distros)
# =============================================================================

nftban_health_check_nftban_bin() {
    # Verify NFTBAN_BIN config matches actual binary location
    # Prevents: "nftban command not found" errors from path mismatch
    # Returns: 0=OK, 2=Error

    local status=$HEALTH_OK
    local bin_issues=()
    local config_bin="${NFTBAN_BIN:-/usr/sbin/nftban}"

    if [[ ! -f "$config_bin" ]]; then
        bin_issues+=("NFTBAN_BIN=$config_bin does not exist")
        bin_issues+=("Check /etc/nftban/nftban.conf or reinstall")
        status=$HEALTH_ERROR
        NFTBAN_HEALTH_ERRORS+=("NFTBAN_BIN path invalid: $config_bin")
    elif [[ ! -x "$config_bin" ]]; then
        bin_issues+=("NFTBAN_BIN=$config_bin exists but not executable")
        bin_issues+=("FIX: chmod 755 $config_bin")
        status=$HEALTH_ERROR
        NFTBAN_HEALTH_ERRORS+=("NFTBAN_BIN not executable")
    else
        bin_issues+=("✓ NFTBAN_BIN=$config_bin OK")
    fi

    NFTBAN_HEALTH_RESULTS["nftban_bin"]=$status
    [[ ${#bin_issues[@]} -gt 0 ]] && NFTBAN_HEALTH_ISSUES["nftban_bin"]="${bin_issues[*]}"
    return $status
}

nftban_health_check_queue_processor() {
    # Check if queue processor script is executable
    # Bug found: Deployed with mode 644 instead of 755, causing nftban-queue.service to fail
    # Returns: 0=OK, 1=Warning (auto-fixed), 2=Error
    # Args: $1 = auto_heal (0=check only, 1=auto-fix)

    local auto_heal="${1:-0}"
    local status=$HEALTH_OK
    local qp_issues=()
    local qp="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/sbin/nftban-queue-processor"

    if [[ -f "$qp" ]]; then
        if [[ ! -x "$qp" ]]; then
            local current_mode
            current_mode=$(stat -c %a "$qp" 2>/dev/null || echo "unknown")
            qp_issues+=("Queue processor not executable: $qp (mode $current_mode, expected 755)")
            status=$HEALTH_ERROR

            # Auto-heal: Fix permissions
            if [[ $auto_heal -eq 1 ]] || [[ "${NFTBAN_HEALTH_AUTO_HEAL:-false}" == "true" ]]; then
                if chmod 755 "$qp" 2>/dev/null; then
                    qp_issues+=("AUTO-FIXED: Set $qp to mode 755")
                    status=$HEALTH_WARNING  # Downgrade from error since we fixed it

                    # Also restart the service if it was failing
                    if systemctl is-enabled --quiet nftban-queue.service 2>/dev/null; then
                        systemctl restart nftban-queue.service 2>/dev/null && \
                            qp_issues+=("AUTO-FIXED: Restarted nftban-queue.service")
                    fi
                else
                    qp_issues+=("FAILED to fix permissions (need root)")
                    qp_issues+=("FIX: sudo chmod 755 $qp")
                    NFTBAN_HEALTH_ERRORS+=("Queue processor not executable (mode $current_mode)")
                fi
            else
                qp_issues+=("FIX: sudo chmod 755 $qp")
                NFTBAN_HEALTH_ERRORS+=("Queue processor not executable (mode $current_mode)")
            fi
        else
            qp_issues+=("✓ Queue processor executable")
        fi
    fi

    NFTBAN_HEALTH_RESULTS["queue_processor"]=$status
    [[ ${#qp_issues[@]} -gt 0 ]] && NFTBAN_HEALTH_ISSUES["queue_processor"]="${qp_issues[*]}"
    return $status
}

# Export helper functions
export -f _health_service_active _health_service_enabled _health_service_exists
export -f _health_file_age _health_file_fresh _health_http_check
export -f _health_check_service _health_check_metrics_file
export -f nftban_health_should_alert
export -f nftban_health_check_binaries nftban_health_check_paths
export -f nftban_health_check_permissions nftban_health_check_auditor_acls
export -f nftban_health_check_resources
export -f nftban_health_check_fhs nftban_health_check_queue_processor
export -f nftban_health_check_nftban_bin
