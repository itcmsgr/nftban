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

# CRITICAL: Load FHS spec - this is the SINGLE SOURCE OF TRUTH for permissions!
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_fhs_spec.sh" ]]; then
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_fhs_spec.sh"
else
    echo "ERROR: FHS spec not found - cannot enforce permissions" >&2
    return 1
fi

# Path shortcuts (for legacy compatibility, but permissions come from FHS spec)
readonly PERMS_ETC="${NFTBAN_CONFIG_DIR:-/etc/nftban}"
readonly PERMS_LIB="${NFTBAN_LIB_DIR:-/usr/lib/nftban}"
readonly PERMS_SBIN="${NFTBAN_SBIN_DIR:-/usr/sbin}"
readonly PERMS_VAR="${NFTBAN_VAR_DIR:-/var/lib/nftban}"
readonly PERMS_LOG="${NFTBAN_LOG_DIR:-/var/log/nftban}"
# shellcheck disable=SC2034  # May be used by sourcing scripts
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

perms_enforce_etc_files() {
    # Enforce file permissions in /etc/nftban (directories handled by FHS spec)
    # Security: files 0640

    perms_say "Enforcing file permissions in: $PERMS_ETC"

    # Check if nftban group exists
    if ! getent group nftban >/dev/null 2>&1; then
        perms_warn "Group nftban does not exist - creating it"
        groupadd nftban 2>/dev/null || perms_err "Failed to create nftban group"
    fi

    # NOTE: Directory permissions now handled by perms_enforce_from_fhs_spec()

    # Secure files in /etc/nftban (readable by nftban group)
    if [[ -d "$PERMS_ETC" ]]; then
        # Fix conf.d/*.conf files - MUST be readable by nftban group for services
        if [[ -d "$PERMS_ETC/conf.d" ]]; then
            perms_run find "$PERMS_ETC/conf.d" -type f -name "*.conf" -exec chown root:nftban {} \;
            perms_run find "$PERMS_ETC/conf.d" -type f -name "*.conf" -exec chmod 0640 {} \;
        fi

        # Fix whitelist.d, blacklist.d, etc.
        for subdir in whitelist.d blacklist.d ports.d rules.d patterns.d; do
            if [[ -d "$PERMS_ETC/$subdir" ]]; then
                perms_run find "$PERMS_ETC/$subdir" -type f -exec chown root:nftban {} \;
                perms_run find "$PERMS_ETC/$subdir" -type f -exec chmod 0640 {} \;
            fi
        done

        # Handle .local files (user overrides)
        perms_run find "$PERMS_ETC" -type f -name "*.local" -exec chown root:nftban {} \;
        perms_run find "$PERMS_ETC" -type f -name "*.local" -exec chmod 0640 {} \;
    fi
}

perms_enforce_lib_files() {
    # Enforce file permissions in /usr/lib/nftban (directories handled by FHS spec)
    # Security: files 0644, shell scripts 0755 (executable), binaries 0755 (executable)

    perms_say "Enforcing file permissions in: $PERMS_LIB"

    # NOTE: Directory permissions now handled by perms_enforce_from_fhs_spec()

    if [[ -d "$PERMS_LIB" ]]; then
        # CRITICAL: Shell scripts in lib need to be executable (755)
        # Scripts like cron/maintenance.sh are executed directly by systemd
        perms_run find "$PERMS_LIB" -type f -name "*.sh" -exec chmod 0755 {} \;

        # CRITICAL: Go binaries in bin/ need to be executable (755)
        # BUG FIX: Previously all non-.sh files got 644, breaking nftban-core/nftband
        if [[ -d "$PERMS_LIB/bin" ]]; then
            perms_run find "$PERMS_LIB/bin" -type f -exec chmod 0755 {} \;
            perms_run find "$PERMS_LIB/bin" -type f -exec chown root:root {} \;
            perms_say "  ✓ Binaries in $PERMS_LIB/bin set to 755 (executable)"

            # CRITICAL: Restore CAP_NET_ADMIN for nftables operations
            # Without this capability, nftban-core and nftband cannot modify firewall rules
            if command -v setcap &>/dev/null; then
                for binary in nftban-core nftband; do
                    if [[ -f "$PERMS_LIB/bin/$binary" ]]; then
                        if setcap 'cap_net_admin+ep' "$PERMS_LIB/bin/$binary" 2>/dev/null; then
                            perms_say "  ✓ CAP_NET_ADMIN set on $binary"
                        else
                            perms_warn "  Failed to set CAP_NET_ADMIN on $binary"
                        fi
                    fi
                done
            fi
        fi

        # CRITICAL: Internal sbin binaries need to be executable (755)
        # These are helper scripts called by systemd units (queue-processor, apply, rollback, etc.)
        if [[ -d "$PERMS_LIB/sbin" ]]; then
            perms_run find "$PERMS_LIB/sbin" -type f -exec chmod 0755 {} \;
            perms_run find "$PERMS_LIB/sbin" -type f -exec chown root:root {} \;
            perms_say "  ✓ Binaries in $PERMS_LIB/sbin set to 755 (executable)"
        fi

        # Other files are 644 (EXCLUDING bin/ and sbin/ directories which were handled above)
        perms_run find "$PERMS_LIB" -type f ! -name "*.sh" ! -path "*/bin/*" ! -path "*/sbin/*" -exec chmod 0644 {} \;
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

perms_enforce_var_files() {
    # Enforce file permissions in /var/lib/nftban (directories handled by FHS spec)
    # Security: files nftban:nftban 0640
    # v1.13.12: Added chown to fix files created by Go binaries with root:root

    perms_say "Enforcing file permissions in: $PERMS_VAR"

    # NOTE: Directory permissions now handled by perms_enforce_from_fhs_spec()

    # Secure all files (excluding auditors which has special perms)
    if [[ -d "$PERMS_VAR" ]]; then
        # Fix ownership: nftban:nftban (feeds, banned, whitelist, etc.)
        perms_run find "$PERMS_VAR" -path "$PERMS_VAR/reports/auditors" -prune -o -type f \( -not -user nftban -o -not -group nftban \) -exec chown nftban:nftban {} \;

        # Files 640 (only owner read/write, group read)
        perms_run find "$PERMS_VAR" -path "$PERMS_VAR/reports/auditors" -prune -o -type f -not -perm 0640 -exec chmod 0640 {} \;

        # Files in auditors directory need group write with nftban-auditor group
        if [[ -d "$PERMS_VAR/reports/auditors" ]]; then
            perms_run find "$PERMS_VAR/reports/auditors" -type f -exec chown root:nftban-auditor {} \;
            perms_run find "$PERMS_VAR/reports/auditors" -type f -exec chmod 0660 {} \;
        fi
    fi
}

perms_enforce_cache_files() {
    # FIX v1.17.0: Enforce file permissions in /var/cache/nftban
    # The unified exporter runs as nftban user and needs write access
    # Files created by root during install must be fixed

    local PERMS_CACHE="/var/cache/nftban"

    perms_say "Enforcing file permissions in: $PERMS_CACHE"

    if [[ -d "$PERMS_CACHE" ]]; then
        # Fix ownership: nftban:nftban for all files (exporter runs as nftban)
        perms_run find "$PERMS_CACHE" -type f \( -not -user nftban -o -not -group nftban \) -exec chown nftban:nftban {} \;

        # Fix directory ownership recursively
        perms_run find "$PERMS_CACHE" -type d \( -not -user nftban -o -not -group nftban \) -exec chown nftban:nftban {} \;

        # Files 0640 (owner read/write, group read)
        perms_run find "$PERMS_CACHE" -type f -not -perm 0640 -exec chmod 0640 {} \;
    fi
}

perms_enforce_log_files() {
    # Enforce file permissions in /var/log/nftban (directories handled by FHS spec)
    # Security: files 0640
    # EXCEPTION: suricata/ subdirectory owned by suricata:nftban (Suricata writes, nftban reads)

    perms_say "Enforcing file permissions in: $PERMS_LOG"

    # NOTE: Directory permissions now handled by perms_enforce_from_fhs_spec()

    # Secure all log files (excluding suricata subdirectory)
    if [[ -d "$PERMS_LOG" ]]; then
        # Fix file ownership and permissions (excluding suricata)
        perms_run find "$PERMS_LOG" -type f ! -path "*/suricata*" -exec chown nftban:nftban {} \;
        perms_run find "$PERMS_LOG" -type f ! -path "*/suricata*" -exec chmod 0640 {} \;

        # Handle suricata directory specially: suricata:nftban so Suricata can write, nftban can read
        if [[ -d "$PERMS_LOG/suricata" ]]; then
            perms_say "Securing suricata log directory and files (suricata:nftban)"
            # Add suricata to nftban group if not already (must come first)
            if id suricata >/dev/null 2>&1 && ! id -nG suricata 2>/dev/null | grep -qw nftban; then
                perms_run usermod -aG nftban suricata
            fi
            # Directory: suricata:nftban 770 (suricata writes, nftban reads)
            # Only chown to suricata if user exists, otherwise use root
            if id suricata &>/dev/null; then
                perms_run chown suricata:nftban "$PERMS_LOG/suricata"
                perms_run find "$PERMS_LOG/suricata" -type f -exec chown suricata:nftban {} \;
            else
                perms_run chown root:nftban "$PERMS_LOG/suricata"
                perms_run find "$PERMS_LOG/suricata" -type f -exec chown root:nftban {} \;
            fi
            perms_run chmod 0770 "$PERMS_LOG/suricata"
            # Files: 640
            perms_run find "$PERMS_LOG/suricata" -type f -exec chmod 0640 {} \;
        fi
    fi
}

# NOTE: perms_enforce_usrshare removed - now handled by perms_enforce_from_fhs_spec()

# =============================================================================
# FHS SPEC-BASED ENFORCEMENT (NEW - USES SINGLE SOURCE OF TRUTH)
# =============================================================================

perms_enforce_from_fhs_spec() {
    # Enforce permissions using the canonical FHS spec
    # This is the CORRECT way - using the single source of truth!

    perms_say "Enforcing permissions from FHS specification..."

    # Ensure FHS spec is loaded
    if [[ ${#NFTBAN_FHS_DIRECTORIES[@]} -eq 0 ]]; then
        nftban_fhs_load_spec
    fi

    local errors=0
    local fixed=0

    # Iterate through ALL paths defined in FHS spec
    for path in "${!NFTBAN_FHS_DIRECTORIES[@]}"; do
        local spec="${NFTBAN_FHS_DIRECTORIES[$path]}"

        # Parse spec: mode|owner|group|description
        IFS='|' read -r exp_mode exp_owner exp_group _description <<< "$spec"

        # Check if directory exists
        if [[ ! -d "$path" ]]; then
            perms_say "Creating missing directory: $path"
            if ! perms_run install -d -o "$exp_owner" -g "$exp_group" -m "$exp_mode" "$path"; then
                perms_err "Failed to create: $path"
                # v1.19.20 FIX
                ((errors++)) || true
            else
                # v1.19.20 FIX
                ((fixed++)) || true
            fi
            continue
        fi

        # Get actual values
        local act_mode act_owner act_group
        act_mode=$(stat -c "%a" "$path" 2>/dev/null || echo "000")
        act_owner=$(stat -c "%U" "$path" 2>/dev/null || echo "nobody")
        act_group=$(stat -c "%G" "$path" 2>/dev/null || echo "nogroup")

        # Normalize expected mode (strip leading 0)
        local exp_mode_norm="${exp_mode#0}"

        # Check and fix ownership
        if [[ "$act_owner" != "$exp_owner" || "$act_group" != "$exp_group" ]]; then
            perms_say "Fixing ownership: $path ($act_owner:$act_group → $exp_owner:$exp_group)"
            if ! perms_run chown "$exp_owner:$exp_group" "$path"; then
                perms_err "Failed to fix ownership: $path"
                # v1.19.20 FIX
                ((errors++)) || true
            else
                # v1.19.20 FIX
                ((fixed++)) || true
            fi
        fi

        # Check and fix permissions
        if [[ "$act_mode" != "$exp_mode_norm" ]]; then
            perms_say "Fixing permissions: $path ($act_mode → $exp_mode_norm)"
            if ! perms_run chmod "$exp_mode" "$path"; then
                perms_err "Failed to fix permissions: $path"
                # v1.19.20 FIX
                ((errors++)) || true
            else
                # v1.19.20 FIX
                ((fixed++)) || true
            fi
        fi
    done

    perms_say ""
    perms_say "FHS spec enforcement: $fixed fixes applied, $errors errors"

    [[ $errors -gt 0 ]] && return 1
    return 0
}

# =============================================================================
# MAIN ENFORCEMENT FUNCTION
# =============================================================================

nftban_permissions_enforce_all() {
    # Enforce all permission rules using FHS spec (SINGLE SOURCE OF TRUTH)
    # Args: none
    # Returns: 0 on success, 1 on error

    perms_say "Starting permission enforcement (dry-run: ${PERMS_DRYRUN:-0})"
    perms_say ""

    local errors=0

    # Step 1: Directory permissions from FHS spec
    if ! perms_enforce_from_fhs_spec; then
        errors=$((errors + 1))
    fi

    # Step 2: File permissions from FHS spec (UNIFIED - replaces 5 legacy functions)
    perms_say "Enforcing file permissions from FHS specification..."
    if declare -f nftban_fhs_enforce_file_rules >/dev/null 2>&1; then
        if ! nftban_fhs_enforce_file_rules; then
            errors=$((errors + 1))
        fi
        perms_say "  ✓ File permissions enforced via FHS spec"
    else
        # Fallback to legacy functions if FHS file rules not available
        perms_say "  Using legacy file permission functions"
        perms_enforce_etc_files || errors=$((errors + 1))
        perms_enforce_lib_files || errors=$((errors + 1))
        perms_enforce_sbin || errors=$((errors + 1))
        perms_enforce_var_files || errors=$((errors + 1))
        perms_enforce_log_files || errors=$((errors + 1))
        perms_enforce_cache_files || errors=$((errors + 1))
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
    # Check current permissions against FHS spec (single source of truth)
    # Args: none
    # Returns: 0 if all OK, 1 if issues found

    perms_say "Checking permissions against FHS specification..."
    perms_say ""

    # Ensure FHS spec is loaded
    if [[ ${#NFTBAN_FHS_DIRECTORIES[@]} -eq 0 ]]; then
        nftban_fhs_load_spec
    fi

    local issues=0

    # Check ALL paths defined in FHS spec
    for path in "${!NFTBAN_FHS_DIRECTORIES[@]}"; do
        local spec="${NFTBAN_FHS_DIRECTORIES[$path]}"

        # Parse spec: mode|owner|group|description
        IFS='|' read -r exp_mode exp_owner exp_group _description <<< "$spec"

        # Skip if directory doesn't exist
        [[ ! -d "$path" ]] && continue

        # Get actual values
        local act_mode act_owner act_group
        act_mode=$(stat -c "%a" "$path" 2>/dev/null || echo "000")
        act_owner=$(stat -c "%U" "$path" 2>/dev/null || echo "nobody")
        act_group=$(stat -c "%G" "$path" 2>/dev/null || echo "nogroup")

        # Normalize expected mode (strip leading 0)
        local exp_mode_norm="${exp_mode#0}"

        # Check ownership
        if [[ "$act_owner" != "$exp_owner" || "$act_group" != "$exp_group" ]]; then
            perms_warn "$path has wrong ownership: $act_owner:$act_group (expected: $exp_owner:$exp_group)"
            # v1.19.20 FIX
            ((issues++)) || true
        fi

        # Check permissions
        if [[ "$act_mode" != "$exp_mode_norm" ]]; then
            perms_warn "$path has wrong permissions: $act_mode (expected: $exp_mode_norm)"
            # v1.19.20 FIX
            ((issues++)) || true
        fi
    done

    perms_say ""
    if ((issues > 0)); then
        perms_warn "Found $issues permission issue(s)"
        perms_say "Run 'nftban permissions enforce' to fix"
        return 1
    else
        perms_say "✅ All permissions match FHS specification"
        return 0
    fi
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_permissions_enforce_all
export -f nftban_permissions_check
