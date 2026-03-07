#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_vm_enterprise" meta:type="lib" meta:version="1.0.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Secure management of VictoriaMetrics Enterprise trial keys"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"

set -Eeuo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

# Enterprise key storage paths
readonly NFTBAN_VM_METRICS_DIR="${NFTBAN_VM_METRICS_DIR:-/etc/nftban/metrics}"
readonly NFTBAN_VM_ENTERPRISE_KEY_FILE="${NFTBAN_VM_ENTERPRISE_KEY_FILE:-${NFTBAN_VM_METRICS_DIR}/enterprise.key}"
readonly NFTBAN_VM_ENTERPRISE_ENV_FILE="${NFTBAN_VM_ENTERPRISE_ENV_FILE:-${NFTBAN_VM_METRICS_DIR}/enterprise.env}"

# Security settings
readonly NFTBAN_VM_KEY_OWNER="root"
readonly NFTBAN_VM_KEY_GROUP="nftban"
readonly NFTBAN_VM_KEY_PERMS="0640"

# Minimum key length (basic sanity check)
readonly NFTBAN_VM_KEY_MIN_LENGTH=20

# =============================================================================
# INTERNAL HELPERS
# =============================================================================

_vm_enterprise_log_info() {
    echo "  [INFO] $*"
}

_vm_enterprise_log_success() {
    echo "  [OK] $*"
}

_vm_enterprise_log_error() {
    echo "  [ERROR] $*" >&2
}

_vm_enterprise_log_warn() {
    echo "  [WARN] $*"
}

# =============================================================================
# KEY MANAGEMENT FUNCTIONS
# =============================================================================

nftban_vm_enterprise_write_key() {
    # Write enterprise key securely
    # CRITICAL: Key value is NEVER logged
    #
    # Args:
    #   $1 - Enterprise trial key
    #
    # Returns:
    #   0 - Success
    #   1 - Invalid key or write error

    local key="$1"

    # Validate key format (basic sanity)
    if [[ ${#key} -lt ${NFTBAN_VM_KEY_MIN_LENGTH} ]]; then
        _vm_enterprise_log_error "Enterprise key appears invalid (too short)"
        return 1
    fi

    # Create directory with secure permissions
    if ! mkdir -p "${NFTBAN_VM_METRICS_DIR}" 2>/dev/null; then
        _vm_enterprise_log_error "Failed to create directory: ${NFTBAN_VM_METRICS_DIR}"
        return 1
    fi

    # Set directory permissions
    chmod 750 "${NFTBAN_VM_METRICS_DIR}" 2>/dev/null || true
    chown "${NFTBAN_VM_KEY_OWNER}:${NFTBAN_VM_KEY_GROUP}" "${NFTBAN_VM_METRICS_DIR}" 2>/dev/null || true

    # Write key with secure permissions using temp file + atomic move
    local temp_file="${NFTBAN_VM_ENTERPRISE_KEY_FILE}.tmp.$$"

    # Use umask to ensure restrictive permissions during write
    (
        umask 077
        echo -n "$key" > "$temp_file"
    )

    if [[ ! -f "$temp_file" ]]; then
        _vm_enterprise_log_error "Failed to write temporary key file"
        return 1
    fi

    # Set ownership and permissions
    chown "${NFTBAN_VM_KEY_OWNER}:${NFTBAN_VM_KEY_GROUP}" "$temp_file" 2>/dev/null || true
    chmod "${NFTBAN_VM_KEY_PERMS}" "$temp_file" 2>/dev/null || true

    # Atomic move to final location
    if ! mv "$temp_file" "${NFTBAN_VM_ENTERPRISE_KEY_FILE}"; then
        rm -f "$temp_file" 2>/dev/null || true
        _vm_enterprise_log_error "Failed to save enterprise key"
        return 1
    fi

    # Create environment file for systemd
    _vm_enterprise_create_env_file

    # CRITICAL: Do not log the key value - only log file location
    _vm_enterprise_log_success "Enterprise key saved to ${NFTBAN_VM_ENTERPRISE_KEY_FILE}"
    _vm_enterprise_log_info "Key file permissions: ${NFTBAN_VM_KEY_PERMS}"

    return 0
}

nftban_vm_enterprise_write_key_from_file() {
    # Write enterprise key from a file
    #
    # Args:
    #   $1 - Path to file containing key
    #
    # Returns:
    #   0 - Success
    #   1 - Error

    local key_source_file="$1"

    if [[ ! -f "$key_source_file" ]]; then
        _vm_enterprise_log_error "Key file not found: $key_source_file"
        return 1
    fi

    if [[ ! -r "$key_source_file" ]]; then
        _vm_enterprise_log_error "Cannot read key file: $key_source_file"
        return 1
    fi

    # Read key (trim whitespace)
    local key
    key=$(tr -d '[:space:]' < "$key_source_file")

    if [[ -z "$key" ]]; then
        _vm_enterprise_log_error "Key file is empty"
        return 1
    fi

    nftban_vm_enterprise_write_key "$key"
}

nftban_vm_enterprise_remove_key() {
    # Remove enterprise key and environment file
    #
    # Returns:
    #   0 - Success (or already removed)

    local removed=false

    if [[ -f "${NFTBAN_VM_ENTERPRISE_KEY_FILE}" ]]; then
        rm -f "${NFTBAN_VM_ENTERPRISE_KEY_FILE}"
        _vm_enterprise_log_success "Removed enterprise key file"
        removed=true
    fi

    if [[ -f "${NFTBAN_VM_ENTERPRISE_ENV_FILE}" ]]; then
        rm -f "${NFTBAN_VM_ENTERPRISE_ENV_FILE}"
        _vm_enterprise_log_success "Removed enterprise environment file"
        removed=true
    fi

    if [[ "$removed" == "false" ]]; then
        _vm_enterprise_log_info "No enterprise key configured"
    fi

    return 0
}

nftban_vm_enterprise_is_enabled() {
    # Check if enterprise key exists and is valid
    #
    # Returns:
    #   0 - Enterprise key is configured
    #   1 - No enterprise key

    if [[ -f "${NFTBAN_VM_ENTERPRISE_KEY_FILE}" ]] && \
       [[ -s "${NFTBAN_VM_ENTERPRISE_KEY_FILE}" ]]; then
        return 0
    fi

    return 1
}

nftban_vm_enterprise_status() {
    # Display enterprise key status (without revealing key)
    #
    # Args:
    #   $1 - Output format: "text" (default) or "json"

    local format="${1:-text}"

    if nftban_vm_enterprise_is_enabled; then
        local key_file="${NFTBAN_VM_ENTERPRISE_KEY_FILE}"
        local key_perms key_owner key_size key_age

        key_perms=$(stat -c '%a' "$key_file" 2>/dev/null || echo "unknown")
        key_owner=$(stat -c '%U:%G' "$key_file" 2>/dev/null || echo "unknown")
        key_size=$(stat -c '%s' "$key_file" 2>/dev/null || echo "0")
        key_age=$(stat -c '%Y' "$key_file" 2>/dev/null || echo "0")

        if [[ "$format" == "json" ]]; then
            cat << EOF
{
  "enabled": true,
  "key_file": "${key_file}",
  "permissions": "${key_perms}",
  "owner": "${key_owner}",
  "size_bytes": ${key_size},
  "modified_epoch": ${key_age}
}
EOF
        else
            echo ""
            echo "VictoriaMetrics Enterprise Key Status"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            echo "  Status:       CONFIGURED"
            echo "  Key File:     ${key_file}"
            echo "  Permissions:  ${key_perms}"
            echo "  Owner:        ${key_owner}"
            echo ""
            echo "  NOTE: Key value is never displayed for security"
            echo ""
            echo "  To use enterprise features, ensure VictoriaMetrics"
            echo "  is installed with enterprise binary from:"
            echo "  https://victoriametrics.com/products/enterprise/"
            echo ""
        fi
    else
        if [[ "$format" == "json" ]]; then
            cat << EOF
{
  "enabled": false,
  "key_file": null
}
EOF
        else
            echo ""
            echo "VictoriaMetrics Enterprise Key Status"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            echo "  Status:       NOT CONFIGURED"
            echo ""
            echo "  To configure an enterprise trial key:"
            echo ""
            echo "    nftban metrics enterprise-key set <YOUR_KEY>"
            echo ""
            echo "  Get a trial key from VictoriaMetrics:"
            echo "  https://victoriametrics.com/products/enterprise/"
            echo ""
        fi
    fi
}

# =============================================================================
# SYSTEMD ENVIRONMENT FILE
# =============================================================================

_vm_enterprise_create_env_file() {
    # Create environment file that references the key file
    # This allows systemd to load the key without exposing it in logs

    cat > "${NFTBAN_VM_ENTERPRISE_ENV_FILE}" << EOF
# VictoriaMetrics Enterprise Configuration
# Generated by NFTBan on $(date -Iseconds)
#
# This file is loaded by systemd to configure VictoriaMetrics
# with enterprise features.
#
# DO NOT EDIT - managed by nftban
# To update: nftban metrics enterprise-key set <key>
# To remove: nftban metrics enterprise-key remove

VM_LICENSE_FILE=${NFTBAN_VM_ENTERPRISE_KEY_FILE}
EOF

    # Set permissions
    chmod "${NFTBAN_VM_KEY_PERMS}" "${NFTBAN_VM_ENTERPRISE_ENV_FILE}" 2>/dev/null || true
    chown "${NFTBAN_VM_KEY_OWNER}:${NFTBAN_VM_KEY_GROUP}" "${NFTBAN_VM_ENTERPRISE_ENV_FILE}" 2>/dev/null || true

    _vm_enterprise_log_success "Created systemd environment file: ${NFTBAN_VM_ENTERPRISE_ENV_FILE}"
}

# =============================================================================
# SECURITY VALIDATION
# =============================================================================

nftban_vm_enterprise_validate_permissions() {
    # Validate that key file has correct permissions
    #
    # Returns:
    #   0 - Permissions are correct
    #   1 - Permissions issue detected

    if ! nftban_vm_enterprise_is_enabled; then
        _vm_enterprise_log_info "No enterprise key to validate"
        return 0
    fi

    local key_file="${NFTBAN_VM_ENTERPRISE_KEY_FILE}"
    local issues=0

    # Check file permissions
    local actual_perms
    actual_perms=$(stat -c '%a' "$key_file" 2>/dev/null || echo "")

    if [[ "$actual_perms" != "640" ]] && [[ "$actual_perms" != "600" ]]; then
        _vm_enterprise_log_warn "Key file has insecure permissions: $actual_perms (expected 640)"
        # v1.19.20 FIX
        ((issues++)) || true
    fi

    # Check file ownership
    local actual_owner
    actual_owner=$(stat -c '%U' "$key_file" 2>/dev/null || echo "")

    if [[ "$actual_owner" != "root" ]]; then
        _vm_enterprise_log_warn "Key file has unexpected owner: $actual_owner (expected root)"
        # v1.19.20 FIX
        ((issues++)) || true
    fi

    # Check group
    local actual_group
    actual_group=$(stat -c '%G' "$key_file" 2>/dev/null || echo "")

    if [[ "$actual_group" != "nftban" ]] && [[ "$actual_group" != "root" ]]; then
        _vm_enterprise_log_warn "Key file has unexpected group: $actual_group (expected nftban)"
        # v1.19.20 FIX
        ((issues++)) || true
    fi

    if [[ $issues -gt 0 ]]; then
        _vm_enterprise_log_warn "Found $issues permission issue(s)"
        _vm_enterprise_log_info "To fix: chmod 640 $key_file && chown root:nftban $key_file"
        return 1
    fi

    _vm_enterprise_log_success "Enterprise key permissions are correct"
    return 0
}

nftban_vm_enterprise_fix_permissions() {
    # Fix key file permissions
    #
    # Returns:
    #   0 - Success
    #   1 - Error

    if ! nftban_vm_enterprise_is_enabled; then
        _vm_enterprise_log_info "No enterprise key to fix"
        return 0
    fi

    local key_file="${NFTBAN_VM_ENTERPRISE_KEY_FILE}"

    chmod "${NFTBAN_VM_KEY_PERMS}" "$key_file" 2>/dev/null || {
        _vm_enterprise_log_error "Failed to set permissions on $key_file"
        return 1
    }

    chown "${NFTBAN_VM_KEY_OWNER}:${NFTBAN_VM_KEY_GROUP}" "$key_file" 2>/dev/null || {
        _vm_enterprise_log_error "Failed to set ownership on $key_file"
        return 1
    }

    _vm_enterprise_log_success "Fixed enterprise key permissions"
    return 0
}

# =============================================================================
# SYSTEMD RELOAD HELPER
# =============================================================================

nftban_vm_enterprise_reload_services() {
    # Reload VictoriaMetrics service to pick up new enterprise key
    #
    # Returns:
    #   0 - Success
    #   1 - Error or service not running

    if systemctl is-active victoriametrics &>/dev/null; then
        _vm_enterprise_log_info "Reloading VictoriaMetrics to apply enterprise key..."

        systemctl daemon-reload

        if systemctl restart victoriametrics; then
            _vm_enterprise_log_success "VictoriaMetrics restarted with enterprise key"
            return 0
        else
            _vm_enterprise_log_error "Failed to restart VictoriaMetrics"
            return 1
        fi
    else
        _vm_enterprise_log_info "VictoriaMetrics is not running"
        _vm_enterprise_log_info "Enterprise key will be used when VictoriaMetrics starts"
        return 0
    fi
}
