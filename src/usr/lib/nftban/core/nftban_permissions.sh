#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.10.0 - Permission Hardening Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Enforce secure ownership and permissions on critical paths
# Location: /usr/lib/nftban/core/nftban_permissions.sh
#
# **CRITICAL SECURITY MODULE**
# This module enforces strict permissions on NFTBan directories and files
# to prevent unauthorized access and tampering.
#
# **Security Model:**
# - /etc/nftban/* → root:root, 0750/0640 (configs are code-sensitive!)
# - /usr/lib/nftban/* → root:root, 0755/0644 (immutable system code)
# - /var/lib/nftban/* → nftban:nftban, 0750 (mutable state data)
# - /var/log/nftban/* → nftban:nftban, 0750 (log files)
#
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
# meta:source=ChatGPT Security Review 2025-10-30
# =============================================================================

# Enhanced strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_PERMISSIONS_LOADED:-}" ]] && return 0
readonly NFTBAN_PERMISSIONS_LOADED=1

# =============================================================================
# CONFIGURATION
# =============================================================================

# Load FHS spec for canonical paths
if [[ -f "/usr/lib/nftban/core/nftban_fhs_spec.sh" ]]; then
    source "/usr/lib/nftban/core/nftban_fhs_spec.sh"
fi

# Fallback paths if FHS spec not available
readonly PERMS_ETC="${NFTBAN_CONFIG_DIR:-/etc/nftban}"
readonly PERMS_LIB="${NFTBAN_LIB_DIR:-/usr/lib/nftban}"
readonly PERMS_SBIN="${NFTBAN_SBIN_DIR:-/usr/sbin}"
readonly PERMS_VAR="${NFTBAN_VAR_DIR:-/var/lib/nftban}"
readonly PERMS_LOG="${NFTBAN_LOG_DIR:-/var/log/nftban}"
readonly PERMS_USRSHARE="${NFTBAN_SHARE_DIR:-/usr/share/nftban}"

# Audit logging
readonly PERMS_AUDIT_LOG="${PERMS_VAR}/permissions_audit.log"

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

perms_say() {
    # Print message
    # Args: message
    printf "[PERMS] %s\n" "$*"
}

perms_err() {
    # Print error message
    # Args: message
    printf "[PERMS ERROR] %s\n" "$*" >&2
}

perms_warn() {
    # Print warning message
    # Args: message
    printf "[PERMS WARNING] %s\n" "$*" >&2
}

perms_log_audit() {
    # Log to audit trail
    # Args: message
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local user="${SUDO_USER:-${USER:-root}}"

    # Create audit log if it doesn't exist
    if [[ ! -f "$PERMS_AUDIT_LOG" ]]; then
        mkdir -p "$(dirname "$PERMS_AUDIT_LOG")"
        touch "$PERMS_AUDIT_LOG"
        chmod 640 "$PERMS_AUDIT_LOG"
    fi

    # Write audit entry
    echo "[$timestamp] [$user] $*" >> "$PERMS_AUDIT_LOG"
}

perms_run() {
    # Run command (or simulate in dry-run mode)
    # Args: command and arguments

    if [[ "${PERMS_DRYRUN:-0}" == "1" ]]; then
        perms_say "DRYRUN: $*"
    else
        # Log the action to audit trail
        perms_log_audit "EXEC: $*"

        "$@" || {
            perms_err "Command failed: $*"
            perms_log_audit "FAILED: $*"
            return 1
        }

        perms_log_audit "SUCCESS: $*"
    fi
}

# =============================================================================
# DIRECTORY CREATION WITH SAFE PERMISSIONS
# =============================================================================

perms_mkd() {
    # Create directory with safe permissions
    # Args: path, mode, owner, group

    local path="$1"
    local mode="$2"
    local owner="${3:-root}"
    local group="${4:-root}"

    if [[ ! -d "$path" ]]; then
        perms_say "Creating directory: $path ($owner:$group $mode)"
        perms_run install -d -o "$owner" -g "$group" -m "$mode" "$path"
    else
        # Directory exists, fix ownership and permissions
        perms_run chown "$owner:$group" "$path"
        perms_run chmod "$mode" "$path"
    fi
}

# =============================================================================
# PERMISSION ENFORCEMENT FUNCTIONS
# =============================================================================

perms_enforce_etc() {
    # Enforce permissions on /etc/nftban
    # Security: root:root, directories 0750, files 0640

    perms_say "Enforcing permissions on: $PERMS_ETC"

    # Create base directory if missing
    perms_mkd "$PERMS_ETC" 0750 root root
    perms_mkd "$PERMS_ETC/conf.d" 0750 root root

    # Secure all files in /etc/nftban (configs are code-sensitive!)
    if [[ -d "$PERMS_ETC" ]]; then
        perms_say "Securing config directory: $PERMS_ETC"
        perms_run chown -R root:root "$PERMS_ETC"
        perms_run find "$PERMS_ETC" -type d -exec chmod 0750 {} \;
        perms_run find "$PERMS_ETC" -type f -exec chmod 0640 {} \;

        # Special handling for .local files (user overrides - keep 0640)
        if compgen -G "$PERMS_ETC/*.local" > /dev/null 2>&1; then
            perms_run find "$PERMS_ETC" -type f -name "*.local" -exec chmod 0640 {} \;
        fi
    fi
}

perms_enforce_lib() {
    # Enforce permissions on /usr/lib/nftban
    # Security: root:root, directories 0755, files 0644 (immutable)

    perms_say "Enforcing permissions on: $PERMS_LIB"

    if [[ -d "$PERMS_LIB" ]]; then
        perms_say "Securing lib directory: $PERMS_LIB"
        perms_run chown -R root:root "$PERMS_LIB"
        perms_run find "$PERMS_LIB" -type d -exec chmod 0755 {} \;
        perms_run find "$PERMS_LIB" -type f -name "*.sh" -exec chmod 0644 {} \;
    fi
}

perms_enforce_sbin() {
    # Enforce permissions on /usr/sbin/nftban*
    # Security: root:root, 0755 (executable)

    perms_say "Enforcing permissions on: $PERMS_SBIN/nftban*"

    if [[ -f "$PERMS_SBIN/nftban" ]]; then
        perms_run chown root:root "$PERMS_SBIN/nftban"
        perms_run chmod 0755 "$PERMS_SBIN/nftban"
    fi

    # Other nftban-* binaries
    for bin in "$PERMS_SBIN"/nftban-*; do
        if [[ -f "$bin" ]]; then
            perms_run chown root:root "$bin"
            perms_run chmod 0755 "$bin"
        fi
    done
}

perms_enforce_var() {
    # Enforce permissions on /var/lib/nftban
    # Security: nftban:nftban, 0750 (mutable state data)

    perms_say "Enforcing permissions on: $PERMS_VAR"

    # Create base directory
    perms_mkd "$PERMS_VAR" 0750 nftban nftban

    # Create subdirectories if missing
    perms_mkd "$PERMS_VAR/banned" 0750 nftban nftban
    perms_mkd "$PERMS_VAR/whitelist" 0750 nftban nftban
    perms_mkd "$PERMS_VAR/feeds" 0750 nftban nftban
    perms_mkd "$PERMS_VAR/geoip" 0750 nftban nftban
    perms_mkd "$PERMS_VAR/snapshots" 0750 nftban nftban
    perms_mkd "$PERMS_VAR/reports" 0750 nftban nftban
    perms_mkd "$PERMS_VAR/metrics" 0750 nftban nftban

    # Secure all content
    if [[ -d "$PERMS_VAR" ]]; then
        perms_say "Securing var directory: $PERMS_VAR"
        perms_run chown -R nftban:nftban "$PERMS_VAR"
        perms_run find "$PERMS_VAR" -type d -exec chmod 0750 {} \;
        perms_run find "$PERMS_VAR" -type f -exec chmod 0640 {} \;
    fi
}

perms_enforce_log() {
    # Enforce permissions on /var/log/nftban
    # Security: nftban:nftban, 0750, files 0640

    perms_say "Enforcing permissions on: $PERMS_LOG"

    # Create base directory
    perms_mkd "$PERMS_LOG" 0750 nftban nftban

    # Secure all log files
    if [[ -d "$PERMS_LOG" ]]; then
        perms_say "Securing log directory: $PERMS_LOG"
        perms_run chown -R nftban:nftban "$PERMS_LOG"
        perms_run find "$PERMS_LOG" -type d -exec chmod 0750 {} \;
        perms_run find "$PERMS_LOG" -type f -exec chmod 0640 {} \;
    fi
}

perms_enforce_usrshare() {
    # Enforce permissions on /usr/share/nftban
    # Security: root:root, directories 0755, files 0644

    perms_say "Enforcing permissions on: $PERMS_USRSHARE"

    if [[ -d "$PERMS_USRSHARE" ]]; then
        perms_say "Securing share directory: $PERMS_USRSHARE"
        perms_run chown -R root:root "$PERMS_USRSHARE"
        perms_run find "$PERMS_USRSHARE" -type d -exec chmod 0755 {} \;
        perms_run find "$PERMS_USRSHARE" -type f -exec chmod 0644 {} \;
    fi
}

# =============================================================================
# MAIN ENFORCEMENT FUNCTION
# =============================================================================

nftban_permissions_enforce_all() {
    # Enforce all permission rules
    # Args: none
    # Returns: 0 on success, 1 on error

    perms_say "Starting permission enforcement (dry-run: ${PERMS_DRYRUN:-0})"
    perms_say ""

    local errors=0

    # Enforce permissions on each path
    perms_enforce_etc || ((errors++))
    perms_enforce_lib || ((errors++))
    perms_enforce_sbin || ((errors++))
    perms_enforce_var || ((errors++))
    perms_enforce_log || ((errors++))
    perms_enforce_usrshare || ((errors++))

    perms_say ""
    if ((errors > 0)); then
        perms_err "Permission enforcement completed with $errors error(s)"
        return 1
    else
        perms_say "✅ Permission enforcement completed successfully"
        return 0
    fi
}

# =============================================================================
# VALIDATION FUNCTIONS
# =============================================================================

nftban_permissions_check() {
    # Check current permissions and report issues
    # Args: none
    # Returns: 0 if all OK, 1 if issues found

    perms_say "Checking current permissions..."
    perms_say ""

    local issues=0

    # Check /etc/nftban
    if [[ -d "$PERMS_ETC" ]]; then
        local owner
        owner="$(stat -c '%U:%G' "$PERMS_ETC" 2>/dev/null || stat -f '%Su:%Sg' "$PERMS_ETC")"
        local mode
        mode="$(stat -c '%a' "$PERMS_ETC" 2>/dev/null || stat -f '%Lp' "$PERMS_ETC")"

        if [[ "$owner" != "root:root" ]]; then
            perms_warn "$PERMS_ETC has wrong ownership: $owner (expected: root:root)"
            ((issues++))
        fi

        if [[ "$mode" != "750" ]]; then
            perms_warn "$PERMS_ETC has wrong permissions: $mode (expected: 750)"
            ((issues++))
        fi
    fi

    # Check /var/lib/nftban
    if [[ -d "$PERMS_VAR" ]]; then
        local owner
        owner="$(stat -c '%U:%G' "$PERMS_VAR" 2>/dev/null || stat -f '%Su:%Sg' "$PERMS_VAR")"
        local mode
        mode="$(stat -c '%a' "$PERMS_VAR" 2>/dev/null || stat -f '%Lp' "$PERMS_VAR")"

        if [[ "$owner" != "nftban:nftban" ]]; then
            perms_warn "$PERMS_VAR has wrong ownership: $owner (expected: nftban:nftban)"
            ((issues++))
        fi

        if [[ "$mode" != "750" ]]; then
            perms_warn "$PERMS_VAR has wrong permissions: $mode (expected: 750)"
            ((issues++))
        fi
    fi

    perms_say ""
    if ((issues > 0)); then
        perms_warn "Found $issues permission issue(s)"
        perms_say "Run 'nftban permissions enforce' to fix"
        return 1
    else
        perms_say "✅ All permissions are correct"
        return 0
    fi
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_permissions_enforce_all
export -f nftban_permissions_check
