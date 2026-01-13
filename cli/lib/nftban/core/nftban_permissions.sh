#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Permission Hardening Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="nftban_permissions"
# meta:type="core"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2025-11-05"
# meta:description="Enforces strict permissions on NFTBan directories and files"
# meta:input="System paths and current permission states"
# meta:output="Enforced secure permissions and ownership"
# meta:depends="bash,chmod,chown,find"
# meta:inventory.files="/etc/nftban/,/var/lib/nftban/,/var/log/nftban/"
# meta:inventory.binaries="chmod,chown,find,mkdir"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================

set -Eeuo pipefail

# Enhanced strict mode
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_PERMISSIONS_LOADED:-}" ]] && return 0
readonly NFTBAN_PERMISSIONS_LOADED=1

# =============================================================================
# CONFIGURATION
# =============================================================================

# Load FHS spec for canonical paths
if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_fhs_spec.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/core/nftban_fhs_spec.sh"
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
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local user="${SUDO_USER:-${USER:-root}}"

    # Create audit log if it doesn't exist (with correct ownership)
    if [[ ! -f "$PERMS_AUDIT_LOG" ]]; then
        mkdir -p "$(dirname "$PERMS_AUDIT_LOG")"
        touch "$PERMS_AUDIT_LOG"
        chown nftban:nftban "$PERMS_AUDIT_LOG" 2>/dev/null || true
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
    # Security: root:nftban, directories 0750, files 0640

    perms_say "Enforcing permissions on: $PERMS_ETC"

    # Check if nftban group exists
    if ! getent group nftban >/dev/null 2>&1; then
        perms_warn "Group nftban does not exist - creating it"
        groupadd nftban 2>/dev/null || perms_err "Failed to create nftban group"
    fi

    # Create base directory if missing
    perms_mkd "$PERMS_ETC" 0750 root nftban
    perms_mkd "$PERMS_ETC/conf.d" 0750 root nftban

    # Secure directories in /etc/nftban (readable by nftban group)
    # IMPORTANT: Do NOT use recursive -R to preserve user-edited file permissions
    if [[ -d "$PERMS_ETC" ]]; then
        perms_say "Securing config directory: $PERMS_ETC"
        perms_run chown root:nftban "$PERMS_ETC"
        perms_run chmod 0750 "$PERMS_ETC"
        # Set permissions on subdirectories only (not recursively into files)
        perms_run find "$PERMS_ETC" -maxdepth 1 -type d -exec chown root:nftban {} \;
        perms_run find "$PERMS_ETC" -maxdepth 1 -type d -exec chmod 0750 {} \;

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
        # Set ownership on directory tree (package-managed, not user-editable)
        perms_run chown root:root "$PERMS_LIB"
        perms_run find "$PERMS_LIB" -type d -exec chown root:root {} \;
        perms_run find "$PERMS_LIB" -type d -exec chmod 0755 {} \;
        # CRITICAL: Shell scripts in lib need to be executable (755)
        # Scripts like cron/maintenance.sh are executed directly by systemd
        perms_run find "$PERMS_LIB" -type f -name "*.sh" -exec chmod 0755 {} \;
    fi
}

perms_enforce_sbin() {
    # Enforce permissions on /usr/sbin/nftban* binaries ONLY
    # Security: root:nftban, 0750 (group-restricted executable)
    # NOTE: We do NOT touch /usr/sbin directory itself - it's a system directory!

    perms_say "Enforcing permissions on: $PERMS_SBIN/nftban* binaries"

    # Check if nftban group exists
    if ! getent group nftban >/dev/null 2>&1; then
        perms_warn "Group nftban does not exist - creating it"
        groupadd nftban 2>/dev/null || perms_err "Failed to create nftban group"
    fi

    if [[ -f "$PERMS_SBIN/nftban" ]]; then
        perms_run chown root:nftban "$PERMS_SBIN/nftban"
        perms_run chmod 0750 "$PERMS_SBIN/nftban"
    fi

    # Other nftban-* binaries (also restricted)
    for bin in "$PERMS_SBIN"/nftban-*; do
        if [[ -f "$bin" ]]; then
            perms_run chown root:nftban "$bin"
            perms_run chmod 0750 "$bin"
        fi
    done
}

perms_enforce_var() {
    # Enforce permissions on /var/lib/nftban
    # Security: nftban:nftban, 0755 for dirs (allows nftband daemon traversal), 0640 for files

    perms_say "Enforcing permissions on: $PERMS_VAR"

    # Create base directory (755 for daemon access via systemd sandboxing)
    perms_mkd "$PERMS_VAR" 0755 nftban nftban

    # Create subdirectories per FHS spec (see nftban_fhs_spec.sh)
    perms_mkd "$PERMS_VAR/reports" 0755 nftban nftban
    perms_mkd "$PERMS_VAR/reports/baseline" 0755 nftban nftban
    perms_mkd "$PERMS_VAR/reports/watchdog" 0755 nftban nftban
    perms_mkd "$PERMS_VAR/metrics" 0755 nftban nftban
    perms_mkd "$PERMS_VAR/snapshots" 0755 nftban nftban
    perms_mkd "$PERMS_VAR/exports" 0755 nftban nftban
    perms_mkd "$PERMS_VAR/geoip" 0755 nftban nftban
    perms_mkd "$PERMS_VAR/panels" 0755 nftban nftban
    perms_mkd "$PERMS_VAR/stats" 0755 nftban nftban

    # CRITICAL: Create auditors directory with special permissions
    # This directory uses root:nftban-auditor (NOT nftban:nftban)
    # If nftban-auditor group doesn't exist, fallback to nftban:nftban
    if getent group nftban-auditor >/dev/null 2>&1; then
        perms_mkd "$PERMS_VAR/reports/auditors" 0770 root nftban-auditor
    else
        perms_mkd "$PERMS_VAR/reports/auditors" 0770 nftban nftban
    fi

    # Secure all content (excluding auditors which has special perms)
    if [[ -d "$PERMS_VAR" ]]; then
        perms_say "Securing var directory: $PERMS_VAR"
        # Use find to chown, but exclude auditors directory
        perms_run find "$PERMS_VAR" -path "$PERMS_VAR/reports/auditors" -prune -o -exec chown nftban:nftban {} \;
        # Dirs 755 (allows nftband daemon traversal), files 640 (only owner read/write)
        perms_run find "$PERMS_VAR" -path "$PERMS_VAR/reports/auditors" -prune -o -type d -exec chmod 0755 {} \;
        perms_run find "$PERMS_VAR" -path "$PERMS_VAR/reports/auditors" -prune -o -type f -exec chmod 0640 {} \;
    fi
}

perms_enforce_log() {
    # Enforce permissions on /var/log/nftban
    # Security: nftban:nftban, 0750, files 0640
    # EXCEPTION: suricata/ subdirectory owned by suricata:nftban (Suricata writes, nftban reads)

    perms_say "Enforcing permissions on: $PERMS_LOG"

    # Create base directory
    perms_mkd "$PERMS_LOG" 0750 nftban nftban

    # Secure all log files (excluding suricata subdirectory)
    if [[ -d "$PERMS_LOG" ]]; then
        perms_say "Securing log directory: $PERMS_LOG"
        # Exclude suricata directory from recursive chown
        perms_run find "$PERMS_LOG" -mindepth 1 -maxdepth 1 -type d ! -name "suricata" -exec chown -R nftban:nftban {} \;
        perms_run find "$PERMS_LOG" -maxdepth 1 -type f -exec chown nftban:nftban {} \;
        perms_run find "$PERMS_LOG" -type d ! -path "*/suricata*" -exec chmod 0750 {} \;
        perms_run find "$PERMS_LOG" -type f ! -path "*/suricata*" -exec chmod 0640 {} \;

        # Handle suricata directory specially: suricata:nftban so Suricata can write, nftban can read
        if [[ -d "$PERMS_LOG/suricata" ]]; then
            perms_say "Securing suricata log directory (suricata:nftban)"
            perms_run chown -R suricata:nftban "$PERMS_LOG/suricata"
            perms_run chmod 0750 "$PERMS_LOG/suricata"
            perms_run find "$PERMS_LOG/suricata" -type f -exec chmod 0640 {} \;
            # Add suricata to nftban group if not already
            if id suricata >/dev/null 2>&1 && ! groups suricata 2>/dev/null | grep -q '\bnftban\b'; then
                perms_run usermod -aG nftban suricata
            fi
        fi
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

    # Enforce permissions on each path (count failures for error tracking)
    if ! perms_enforce_etc; then
        errors=$((errors + 1))
    fi
    if ! perms_enforce_lib; then
        errors=$((errors + 1))
    fi
    if ! perms_enforce_sbin; then
        errors=$((errors + 1))
    fi
    if ! perms_enforce_var; then
        errors=$((errors + 1))
    fi
    if ! perms_enforce_log; then
        errors=$((errors + 1))
    fi
    if ! perms_enforce_usrshare; then
        errors=$((errors + 1))
    fi

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

        if [[ "$owner" != "root:nftban" ]]; then
            perms_warn "$PERMS_ETC has wrong ownership: $owner (expected: root:nftban)"
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
