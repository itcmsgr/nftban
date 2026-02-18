#!/usr/bin/env bash
# shellcheck disable=SC1090  # Dynamic config paths, cannot follow
# =============================================================================
# NFTBan v1.0 - Health Fix Functions Library
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Auto-fix functions for health issues (permissions, directories, etc.)
#
# meta:name="nftban_health_fixes"
# meta:type="lib"
# meta:header="Health Fix Functions"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# **Description & Purpose**
# meta:description="Auto-fix functions for common health issues"
# meta:input="Health check results"
# meta:output="Fixed system state"
#
# **Inventory & Requirements**
# meta:depends="nftban_health.sh"
# meta:inventory.files=""
# meta:inventory.binaries="systemctl,chown,chmod,mkdir"
# meta:inventory.env_vars="NFTBAN_DATA_DIR,NFTBAN_CONFIG_DIR,NFTBAN_METRICS_ENABLED,NFTBAN_METRICS_BACKEND"
# meta:inventory.config_files="/etc/nftban/nftban.conf"
# meta:inventory.systemd_units="nftban-health.timer,nftban-unified-exporter.timer,prometheus.service"
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2026-01-09"
# meta:updated_date="2026-02-08"
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_NFTBAN_HEALTH_FIXES_LOADED:-}" ]] && return 0
_NFTBAN_HEALTH_FIXES_LOADED=1

# Default paths (for direct sourcing compatibility)
: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"

# AUTO-FIX FUNCTIONS
# =============================================================================

# =============================================================================
# AUDITOR ACL SETUP (defined first - called by other functions)
# =============================================================================
# Sets up ACLs for nftban-auditor group to have read access to logs and reports
# without changing base ownership (nftban:nftban) needed for daemon writes.

nftban_health_fix_auditor_acls() {
    # Check if setfacl is available
    if ! command -v setfacl &>/dev/null; then
        echo "  ⚠ setfacl not available - skipping auditor ACL setup"
        echo "    Install acl package: apt install acl / dnf install acl"
        return 0
    fi

    # Check if nftban-auditor group exists
    if ! getent group nftban-auditor &>/dev/null; then
        echo "  ⚠ nftban-auditor group not found - skipping auditor ACL setup"
        return 0
    fi

    echo "  Setting up auditor ACLs (read-only access)..."

    local acl_errors=0

    # Log directory - auditor needs traverse (x) and read (r) on specific logs
    if [[ -d /var/log/nftban ]]; then
        setfacl -m g:nftban-auditor:x /var/log/nftban 2>/dev/null || ((++acl_errors))
        for logfile in bans.log login_monitor.log feeds.log nftban-actions.log ddos.log portscan.log; do
            [[ -f "/var/log/nftban/$logfile" ]] && setfacl -m g:nftban-auditor:r "/var/log/nftban/$logfile" 2>/dev/null || true
        done
    fi

    # Reports directory - auditor needs traverse to reach auditors/ subdir
    if [[ -d /var/lib/nftban ]]; then
        setfacl -m g:nftban-auditor:x /var/lib/nftban 2>/dev/null || ((++acl_errors))
        [[ -d /var/lib/nftban/reports ]] && setfacl -m g:nftban-auditor:x /var/lib/nftban/reports 2>/dev/null || ((++acl_errors))
        [[ -d /var/lib/nftban/reports/auditors ]] && setfacl -m g:nftban-auditor:rx /var/lib/nftban/reports/auditors 2>/dev/null || ((++acl_errors))
    fi

    # Config directory - auditor needs read access to view (not modify) configuration
    if [[ -d /etc/nftban ]]; then
        setfacl -m g:nftban-auditor:x /etc/nftban 2>/dev/null || ((++acl_errors))
        [[ -f /etc/nftban/nftban.conf ]] && setfacl -m g:nftban-auditor:r /etc/nftban/nftban.conf 2>/dev/null || true
    fi

    if [[ $acl_errors -eq 0 ]]; then
        echo "  ✓ Auditor ACLs configured successfully"
    else
        echo "  ⚠ Some auditor ACLs could not be set ($acl_errors errors)"
    fi

    return 0
}

# =============================================================================

nftban_health_fix_permissions() {
    # Fix ALL permissions and ownership to match FHS specification
    # Uses the new permissions enforcement module if available, otherwise legacy fix
    # Smart about privileges: fixes what it can, reports what needs root

    local running_as_root=0
    [[ $EUID -eq 0 ]] && running_as_root=1

    echo "Fixing permissions and ownership..."

    # ==========================================================================
    # STEP 1: Use systemd-tmpfiles for runtime directories (FHS-correct method)
    # ==========================================================================
    # This is the canonical way to fix /run/nftban, /var/log/nftban, /var/cache/nftban
    # per the tmpfiles.d specification. Manual chown is discouraged.
    if [[ $running_as_root -eq 1 ]]; then
        local tmpfiles_conf=""
        for path in /usr/lib/tmpfiles.d/nftban.conf /etc/tmpfiles.d/nftban.conf; do
            [[ -f "$path" ]] && tmpfiles_conf="$path" && break
        done

        if [[ -n "$tmpfiles_conf" ]] && command -v systemd-tmpfiles &>/dev/null; then
            echo "  Using systemd-tmpfiles for FHS runtime directories..."
            if systemd-tmpfiles --create "$tmpfiles_conf" 2>/dev/null; then
                echo "  ✓ FHS runtime directories restored via tmpfiles.d"
            else
                echo "  ⚠ systemd-tmpfiles returned non-zero (some dirs may not exist yet)"
            fi
        fi

        # ======================================================================
        # EXPLICIT OWNERSHIP FIX (defense in depth)
        # ======================================================================
        # tmpfiles 'd' directive only creates directories, it won't fix ownership
        # on existing directories. Even with 'z' directive, we enforce explicitly
        # to handle edge cases where tmpfiles fails or isn't available.
        # Critical for services running as User=nftban (unified-exporter, etc.)
        echo "  Enforcing ownership on FHS runtime directories..."

        # /run/nftban - exporter creates lock files here
        if [[ -d /run/nftban ]]; then
            chown nftban:nftban /run/nftban 2>/dev/null || true
            chmod 755 /run/nftban 2>/dev/null || true
            # Fix files inside (except socket which is root:nftban)
            find /run/nftban -maxdepth 1 -type f ! -name "nftband.sock" -exec chown nftban:nftban {} \; 2>/dev/null || true
            # Fix socket ownership explicitly (root:nftban for daemon IPC)
            if [[ -S /run/nftban/nftband.sock ]]; then
                chown root:nftban /run/nftban/nftband.sock 2>/dev/null || true
                chmod 660 /run/nftban/nftband.sock 2>/dev/null || true
            fi
        fi

        # /var/log/nftban - logs written by nftban user
        if [[ -d /var/log/nftban ]]; then
            chown nftban:nftban /var/log/nftban 2>/dev/null || true
            chmod 750 /var/log/nftban 2>/dev/null || true
        fi

        # /var/cache/nftban - cache written by nftban user
        if [[ -d /var/cache/nftban ]]; then
            chown nftban:nftban /var/cache/nftban 2>/dev/null || true
            chmod 755 /var/cache/nftban 2>/dev/null || true
        fi

        echo "  ✓ FHS runtime directory ownership enforced"
    fi

    # ==========================================================================
    # STEP 2: Use permissions enforcement module or legacy fix for remaining items
    # ==========================================================================
    # Try to use new permissions enforcement module (more comprehensive)
    local lib_dir="${NFTBAN_LIB_DIR:-/usr/lib/nftban}"
    if [[ -f "${lib_dir}/core/nftban_permissions.sh" ]]; then
        if source "${lib_dir}/core/nftban_permissions.sh" 2>/dev/null; then
            # Log audit entry before fixing
            if declare -f perms_log_audit >/dev/null 2>&1; then
                perms_log_audit "Health auto-fix: Starting permission enforcement"
            fi

            echo "  Using enhanced permission enforcement module"
            nftban_permissions_enforce_all || true  # Continue even if permissions fail
            # Also fix auditor ACLs (not handled by permissions module)
            nftban_health_fix_auditor_acls
            return 0
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

        local nftban_bin="${NFTBAN_BIN:-/usr/sbin/nftban}"
        if [[ -f "$nftban_bin" ]]; then
            chmod 755 "$nftban_bin" 2>/dev/null && \
            chown root:root "$nftban_bin" 2>/dev/null && \
            echo "  ✓ Fixed $nftban_bin binary" && \
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
            # CRITICAL: Shell scripts MUST be executable (755), not 644
            find "${NFTBAN_LIB_DIR}" -type f -name "*.sh" -exec chown root:root {} \; 2>/dev/null
            find "${NFTBAN_LIB_DIR}" -type f -name "*.sh" -exec chmod 755 {} \; 2>/dev/null

            # Fix binary permissions (if they exist)
            find "${NFTBAN_LIB_DIR}/bin" -type f 2>/dev/null | while read -r binary; do
                chown root:root "$binary" 2>/dev/null
                chmod 755 "$binary" 2>/dev/null
            done

            # Fix sbin binaries (queue processor, etc.) - CRITICAL: must be executable
            # Issue found on all 5 lab servers: queue processor installed with 644 instead of 755
            if [[ -d "${NFTBAN_LIB_DIR}/sbin" ]]; then
                find "${NFTBAN_LIB_DIR}/sbin" -type f 2>/dev/null | while read -r binary; do
                    chown root:root "$binary" 2>/dev/null
                    chmod 755 "$binary" 2>/dev/null
                done
                echo "  ✓ Fixed ${NFTBAN_LIB_DIR}/sbin binary permissions (755)"
            fi

            echo "  ✓ Fixed ${NFTBAN_LIB_DIR} directory and file ownership (root:root)"
            : $((fixed_count++))
        fi

        if [[ -d "/usr/share/nftban" ]]; then
            # Fix ownership on share directory and immediate contents (no deep recursion)
            chown root:root /usr/share/nftban 2>/dev/null
            find /usr/share/nftban -maxdepth 1 -exec chown root:root {} \; 2>/dev/null && \
            echo "  ✓ Fixed /usr/share/nftban ownership (root:root)" && \
            : $((fixed_count++))
        fi

        # Fix Suricata permissions for NFTBan integration
        # Suricata writes to LOG_DIR/suricata/, nftban needs to read eve-alerts.json
        # Bug fix v1.12.8: Create directory and EVE file if missing (prevents daemon startup failure)
        # Bug fix v1.12.9: Detect Suricata user (suricata on RHEL, root on Debian/Ubuntu)
        local suricata_dir="${NFTBAN_LOG_DIR}/suricata"
        local suricata_fixed=0
        local suri_user="root"

        # Detect Suricata user (suricata on RHEL/AlmaLinux, root on Debian/Ubuntu)
        if id suricata >/dev/null 2>&1; then
            suri_user="suricata"
        fi

        # Create Suricata log directory if missing (per FHS spec)
        if [[ ! -d "$suricata_dir" ]]; then
            mkdir -p "$suricata_dir" 2>/dev/null
            chown "${suri_user}:nftban" "$suricata_dir" 2>/dev/null
            chmod 770 "$suricata_dir" 2>/dev/null
            echo "  ✓ Created ${suricata_dir} (${suri_user}:nftban, 770)"
            suricata_fixed=1
        fi

        if [[ -d "$suricata_dir" ]]; then
            # Add suricata user to nftban group (if suricata user exists)
            # This allows suricata to traverse /var/log/nftban/ (owned by nftban:nftban)
            if [[ "$suri_user" == "suricata" ]]; then
                if ! id -nG suricata 2>/dev/null | grep -qw nftban; then
                    usermod -aG nftban suricata 2>/dev/null && suricata_fixed=1
                fi
            fi

            # Fix directory: suri_user:nftban with 770 (suricata writes, nftban reads)
            chown "${suri_user}:nftban" "$suricata_dir" 2>/dev/null
            chmod 770 "$suricata_dir" 2>/dev/null

            # CRITICAL: Create eve-alerts.json if missing
            # Suricata 7.x with threaded:yes only creates file on first event
            # nftban-suricata daemon requires file to exist on startup
            local eve_file="${suricata_dir}/eve-alerts.json"
            if [[ ! -f "$eve_file" ]]; then
                touch "$eve_file" 2>/dev/null
                chown "${suri_user}:nftban" "$eve_file" 2>/dev/null
                chmod 640 "$eve_file" 2>/dev/null
                echo "  ✓ Created ${eve_file} (${suri_user}:nftban, 640)"
                suricata_fixed=1
            else
                # Fix ownership if exists
                chown "${suri_user}:nftban" "$eve_file" 2>/dev/null
                chmod 640 "$eve_file" 2>/dev/null
            fi

            # Fix suricata.log similarly
            if [[ -f "${suricata_dir}/suricata.log" ]]; then
                chown "${suri_user}:nftban" "${suricata_dir}/suricata.log" 2>/dev/null
                chmod 640 "${suricata_dir}/suricata.log" 2>/dev/null
            fi

            if [[ $suricata_fixed -eq 1 ]]; then
                echo "  ✓ Fixed ${suricata_dir} permissions (${suri_user}:nftban, 770)"
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

    # Also fix auditor ACLs if running as root
    if [[ $running_as_root -eq 1 ]]; then
        nftban_health_fix_auditor_acls
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
    # Restart failed services AND timers
    # Auto-heals enabled but stopped services/timers

    echo "Checking services and timers..."

    # Core services that should be running if enabled
    local services=(
        "${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service}"
        "nftband.service"
    )

    # Core timers that should be running if enabled
    local timers=(
        "nftban-health.timer"
        "nftban-maintenance.timer"
        "nftban-unified-exporter.timer"
        "nftban-watchdog.timer"
        "nftban-queue.timer"
        "nftban-core-geoip.timer"
    )

    local fixed_count=0

    # Fix services
    for service in "${services[@]}"; do
        if systemctl list-unit-files "$service" &>/dev/null; then
            if systemctl is-enabled "$service" &>/dev/null; then
                if ! systemctl is-active "$service" &>/dev/null; then
                    systemctl restart "$service" 2>/dev/null || true
                    echo "  ✓ Restarted $service"
                    fixed_count=$((fixed_count + 1))
                fi
            fi
        fi
    done

    # Fix timers (enabled but dead)
    for timer in "${timers[@]}"; do
        if systemctl list-unit-files "$timer" &>/dev/null; then
            if systemctl is-enabled "$timer" &>/dev/null; then
                if ! systemctl is-active "$timer" &>/dev/null; then
                    systemctl start "$timer" 2>/dev/null || true
                    echo "  ✓ Started $timer"
                    fixed_count=$((fixed_count + 1))
                fi
            fi
        fi
    done

    # Fix stale PID file (case study: lab1 missing metrics due to PID mismatch)
    # When nftband restarts but PID file isn't updated, metrics exporter can't read runtime stats
    local pid_file="${NFTBAN_RUN_DIR:-/run/nftban}/nftband.pid"
    if systemctl is-active nftband.service &>/dev/null; then
        local stored_pid actual_pid
        stored_pid=$(cat "$pid_file" 2>/dev/null | awk '{print $1}')
        actual_pid=$(pgrep -f "/usr/lib/nftban/bin/nftband" | head -1)

        if [[ -n "$actual_pid" ]]; then
            if [[ -z "$stored_pid" ]] || [[ "$stored_pid" != "$actual_pid" ]]; then
                if echo "$actual_pid" > "$pid_file" 2>/dev/null; then
                    echo "  ✓ Fixed stale PID file: $actual_pid"
                    fixed_count=$((fixed_count + 1))
                fi
            fi
        fi
    fi

    if [[ $fixed_count -eq 0 ]]; then
        echo "  ✓ All enabled services/timers are running"
    else
        echo "  ✓ Fixed $fixed_count service(s)/timer(s)"
    fi

    return 0
}

nftban_health_fix_metrics() {
    # Auto-heal metrics collection issues
    # Called by health timer for automatic recovery

    local fixed=0

    # Check if metrics is enabled in config
    if [[ "${NFTBAN_METRICS_ENABLED:-false}" != "true" ]]; then
        return 0  # Metrics disabled, nothing to fix
    fi

    # Fix 1: Ensure metrics exporter timer is running
    if systemctl is-enabled nftban-unified-exporter.timer &>/dev/null; then
        if ! systemctl is-active nftban-unified-exporter.timer &>/dev/null; then
            systemctl start nftban-unified-exporter.timer 2>/dev/null || true
            echo "  ✓ Started unified exporter timer"
            fixed=$((fixed + 1))
        fi
    fi

    # Fix 2: Ensure textfile collector directory exists
    # Use config variable with sensible default (node_exporter standard path)
    local textfile_dir="${NFTBAN_METRICS_TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
    if [[ ! -d "$textfile_dir" ]]; then
        # Create with correct ownership (no -R needed for fresh directory)
        install -d -o nftban -g nftban -m 0755 "$textfile_dir" 2>/dev/null || \
            mkdir -p "$textfile_dir" 2>/dev/null
        chown nftban:nftban "$textfile_dir" 2>/dev/null || true
        chmod 755 "$textfile_dir" 2>/dev/null || true
        echo "  ✓ Created textfile collector directory: $textfile_dir"
        fixed=$((fixed + 1))
    fi

    # Fix 3: Check configured backend and restart if needed
    local backend="${NFTBAN_METRICS_BACKEND:-prometheus}"
    case "$backend" in
        prometheus)
            if systemctl is-enabled prometheus &>/dev/null; then
                if ! systemctl is-active prometheus &>/dev/null; then
                    systemctl restart prometheus 2>/dev/null || true
                    echo "  ✓ Restarted Prometheus"
                    fixed=$((fixed + 1))
                fi
            fi
            ;;
        victoriametrics)
            if systemctl is-enabled victoriametrics &>/dev/null; then
                if ! systemctl is-active victoriametrics &>/dev/null; then
                    systemctl restart victoriametrics 2>/dev/null || true
                    echo "  ✓ Restarted VictoriaMetrics"
                    fixed=$((fixed + 1))
                fi
            fi
            ;;
    esac

    # Fix 4: Ensure node_exporter is running (try all possible service names)
    local node_running=false
    for svc in prometheus-node-exporter node_exporter node-exporter; do
        if systemctl is-active "$svc" &>/dev/null; then
            node_running=true
            break
        fi
    done

    if [[ "$node_running" == "false" ]]; then
        for svc in prometheus-node-exporter node_exporter node-exporter; do
            if systemctl is-enabled "$svc" &>/dev/null; then
                systemctl start "$svc" 2>/dev/null || true
                if systemctl is-active "$svc" &>/dev/null; then
                    echo "  ✓ Started Node Exporter ($svc)"
                    fixed=$((fixed + 1))
                    break
                fi
            fi
        done
    fi

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
    # NFTBan v1.0 simplified 2-group model: nftban + nftban-auditor
    local nftban_uid nftban_gid nftban_auditors_gid
    nftban_uid=$(id -u nftban 2>/dev/null || echo "MISSING")
    nftban_gid=$(id -g nftban 2>/dev/null || echo "MISSING")
    nftban_auditors_gid=$(getent group nftban-auditor 2>/dev/null | cut -d: -f3 || echo "MISSING")

    # Verify users/groups exist
    if [[ "$nftban_uid" == "MISSING" ]] || [[ "$nftban_gid" == "MISSING" ]]; then
        echo "  ✖ ERROR: nftban user or group not found" >&2
        echo "    Run installer to create system users/groups" >&2
        return 1
    fi

    # nftban-auditor is optional, warn if missing but don't fail
    if [[ "$nftban_auditors_gid" == "MISSING" ]]; then
        echo "  ⚠ WARNING: nftban-auditor group not found (optional, for inventory helpers)" >&2
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
NFTBAN_AUDITORS_GROUP="nftban-auditor"
NFTBAN_AUDITORS_GID=${nftban_auditors_gid}
EOF

        chown root:root "$system_conf"
        chmod 0644 "$system_conf"
        echo "  ✓ Updated $system_conf"
        echo "    nftban UID=$nftban_uid GID=$nftban_gid"
        if [[ "$nftban_auditors_gid" != "MISSING" ]]; then
            echo "    nftban-auditor GID=$nftban_auditors_gid"
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
            # Auto-calculate rotation based on disk space
            local avail_gb=0
            local log_frequency="weekly"
            local log_rotate=4
            local suricata_rotate=7
            local report_rotate=3

            if [[ -d /var/log ]]; then
                avail_gb=$(df -BG /var/log 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$4); print int($4)}' || echo "0")
            fi

            if [[ "$avail_gb" -lt 10 ]]; then
                log_frequency="daily"; log_rotate=7; suricata_rotate=3; report_rotate=1
                echo "  Disk: ${avail_gb}GB (small) → rotation: 7d"
            elif [[ "$avail_gb" -lt 30 ]]; then
                log_frequency="weekly"; log_rotate=4; suricata_rotate=7; report_rotate=3
                echo "  Disk: ${avail_gb}GB (medium) → rotation: 1 month"
            else
                log_frequency="weekly"; log_rotate=8; suricata_rotate=14; report_rotate=6
                echo "  Disk: ${avail_gb}GB (large) → rotation: 2 months"
            fi

            # Create logrotate config with calculated values
            cat > "$logrotate_dst" 2>/dev/null << LOGROTATE
# NFTBan Log Rotation (auto-generated by health fix)
# Disk space: ${avail_gb}GB - Policy adjusted automatically

/var/log/nftban/*.log {
    ${log_frequency}
    rotate ${log_rotate}
    compress
    delaycompress
    missingok
    notifempty
    create 0640 nftban nftban
    copytruncate
}

/var/log/nftban/suricata/*.json /var/log/nftban/suricata/*.log {
    daily
    rotate ${suricata_rotate}
    compress
    delaycompress
    missingok
    notifempty
    create 0640 suricata nftban
    copytruncate
    size 50M
}

/var/lib/nftban/reports/*.html /var/lib/nftban/reports/*.json {
    monthly
    rotate ${report_rotate}
    compress
    delaycompress
    missingok
    notifempty
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
# GEOIP FIX
# =============================================================================

nftban_health_fix_geoip() {
    # Auto-heal GeoIP database issues
    # Downloads database if missing, using nftban-core or fallback to curl
    # Returns: 0=fixed, 1=warning, 2=failed

    echo "Checking GeoIP database..."

    local geoip_dir="${NFTBAN_DATA_DIR:-/var/lib/nftban}/geoip"
    local nftban_core="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/bin/nftban-core"
    local db_found=false
    local status=0

    # Check for any supported database
    for db_file in "dbip-country-lite.mmdb" "GeoLite2-City.mmdb" "GeoLite2-Country.mmdb"; do
        if [[ -f "${geoip_dir}/${db_file}" ]]; then
            db_found=true
            local file_age
            local now_ts file_ts
            now_ts=$(date +%s)
            file_ts=$(stat -c %Y "${geoip_dir}/${db_file}" 2>/dev/null || echo 0)
            file_age=$(( (now_ts - file_ts) / 86400 ))

            if [[ $file_age -gt 45 ]]; then
                echo "  ⚠️  Database is ${file_age} days old (recommend update)"
                status=1
            else
                echo "  ✓ GeoIP database present (${file_age} days old)"
            fi
            break
        fi
    done

    # If no database found, try to download
    if [[ "$db_found" == "false" ]]; then
        echo "  ⚠️  GeoIP database not found - downloading..."

        # Ensure directory exists using FHS spec (single source of truth)
        if [[ ! -d "$geoip_dir" ]]; then
            local geoip_spec
            geoip_spec=$(nftban_fhs_get_spec "$geoip_dir" 2>/dev/null || echo "0750|nftban|nftban|GeoIP database")
            IFS='|' read -r fhs_perms fhs_owner fhs_group _ <<< "$geoip_spec"
            install -d -o "${fhs_owner:-nftban}" -g "${fhs_group:-nftban}" -m "${fhs_perms:-0750}" "$geoip_dir" 2>/dev/null || {
                mkdir -p "$geoip_dir" 2>/dev/null
                chown "${fhs_owner:-nftban}:${fhs_group:-nftban}" "$geoip_dir" 2>/dev/null || true
                chmod "${fhs_perms:-750}" "$geoip_dir" 2>/dev/null || true
            }
        fi

        # Method 1: Try nftban-core (handles DB-IP and MaxMind based on config)
        if [[ -x "$nftban_core" ]]; then
            echo "  → Using nftban-core to download GeoIP database..."
            if "$nftban_core" geoip update 2>/dev/null; then
                echo "  ✓ GeoIP database downloaded successfully"
                return 0
            fi
            echo "  ⚠️  nftban-core download failed, trying direct download..."
        fi

        # Method 2: Fallback to direct curl download (DB-IP free)
        if command -v curl &>/dev/null; then
            local current_month
            current_month=$(date +%Y-%m)
            local db_url="https://download.db-ip.com/free/dbip-country-lite-${current_month}.mmdb.gz"
            local db_file="${geoip_dir}/dbip-country-lite.mmdb"
            local tmp_file="/tmp/dbip-geoip-$$.mmdb.gz"

            echo "  → Downloading DB-IP Lite database..."
            if curl -fsSL -o "$tmp_file" "$db_url" --max-time 120 2>/dev/null; then
                if gunzip -c "$tmp_file" > "$db_file" 2>/dev/null; then
                    rm -f "$tmp_file"
                    chmod 644 "$db_file"
                    chown nftban:nftban "$db_file" 2>/dev/null || true
                    echo "  ✓ GeoIP database downloaded (DB-IP Lite)"
                    return 0
                else
                    rm -f "$tmp_file"
                    echo "  ✖ Failed to decompress database"
                    status=2
                fi
            else
                rm -f "$tmp_file" 2>/dev/null
                echo "  ✖ Failed to download database"
                echo "    Manual fix: nftban geoip update"
                status=2
            fi
        else
            echo "  ✖ curl not available for download"
            echo "    Manual fix: nftban geoip update"
            status=2
        fi
    fi

    return $status
}

# =============================================================================
# WHITELIST FIX (Server IP auto-protection)
# =============================================================================

nftban_health_fix_whitelist() {
    # Auto-heal server IP whitelist issues
    # Ensures server IPs are whitelisted to prevent self-lockout
    # Uses nftban_whitelist_system_sync from nftban_system_ip.sh
    # Returns: 0=fixed, 1=partial, 2=failed

    echo "Checking server IP whitelist..."

    # Check if nftables is running
    if ! command -v nft &>/dev/null; then
        echo "  ⚠️  nft command not found"
        return 1
    fi

    # Check if nftban table exists
    if ! nft list table ip nftban &>/dev/null; then
        echo "  ⚠️  nftban nftables table not found"
        echo "    Run: systemctl restart nftables"
        return 1
    fi

    # Source system IP module if not already loaded
    if ! declare -f nftban_whitelist_system_sync &>/dev/null; then
        local system_ip_module="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_system_ip.sh"
        if [[ -f "$system_ip_module" ]]; then
            # shellcheck source=/dev/null
            source "$system_ip_module" 2>/dev/null || {
                echo "  ✖ Failed to load system IP module"
                return 2
            }
        else
            echo "  ✖ System IP module not found: $system_ip_module"
            return 2
        fi
    fi

    # Run whitelist sync (adds all server IPs to nftables whitelist)
    if nftban_whitelist_system_sync; then
        echo "  ✓ Server IP whitelist synced successfully"
        return 0
    else
        echo "  ⚠️  Whitelist sync returned warnings"
        return 1
    fi
}

# =============================================================================
# NFTABLES STRUCTURE AUTO-HEAL
# =============================================================================

nftban_health_fix_nftables() {
    # Auto-heal missing nftables tables, sets, and chains
    # Uses canonical schema from nft_schema.sh as single source of truth
    # Returns: 0=fixed, 1=partial, 2=failed
    #
    # ==========================================================================
    # LOCKOUT PREVENTION (v1.16.1)
    # ==========================================================================
    # ROOT CAUSE: This function creates chains with "policy drop" which blocks
    # ALL traffic by default, including SSH. If the whitelist (server IPs, SSH
    # IPs) is not synced to nftables BEFORE creating DROP chains, the admin
    # gets locked out of the server.
    #
    # SOLUTION: Always sync whitelist FIRST, before creating any chains.
    # This is a defense-in-depth measure - the caller should also sync whitelist,
    # but we do it here too to protect against direct function calls.
    # ==========================================================================

    echo "Checking nftables structure..."

    if ! command -v nft &>/dev/null; then
        echo "  ✖ nft command not found"
        return 2
    fi

    # ==========================================================================
    # STEP 0: LOCKOUT PREVENTION - Sync whitelist BEFORE creating DROP chains
    # ==========================================================================
    # If nftban tables already exist with DROP policy, we need whitelist synced.
    # If tables don't exist, we create them, then add chains - still need whitelist.
    # Either way: ALWAYS sync whitelist first.
    if declare -f nftban_health_fix_whitelist >/dev/null 2>&1; then
        echo "  → Pre-sync: Ensuring server IPs are whitelisted (lockout prevention)..."
        if ! nftban_health_fix_whitelist 2>/dev/null; then
            # Try loading the module and retry
            if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_system_ip.sh" ]]; then
                source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_system_ip.sh" 2>/dev/null || true
            fi
            nftban_health_fix_whitelist 2>/dev/null || {
                echo "  ⚠ WARNING: Could not sync whitelist - proceeding with caution"
                echo "    If locked out, recover via console and run: nftban whitelist sync"
            }
        fi
    else
        # Try to load and call the whitelist sync function
        if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_system_ip.sh" ]]; then
            echo "  → Pre-sync: Loading system IP module for lockout prevention..."
            source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_system_ip.sh" 2>/dev/null || true
            if declare -f nftban_whitelist_system_sync >/dev/null 2>&1; then
                nftban_whitelist_system_sync 2>/dev/null || {
                    echo "  ⚠ WARNING: Could not sync whitelist"
                }
            fi
        fi
    fi

    # Ensure schema is loaded
    if ! declare -f nftban_nft_validate_tables >/dev/null 2>&1; then
        if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nft_schema.sh" ]]; then
            source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nft_schema.sh" 2>/dev/null || {
                echo "  ✖ Cannot load nft_schema.sh"
                return 2
            }
        else
            echo "  ✖ nft_schema.sh not found"
            return 2
        fi
    fi

    local fixed=0
    local existing_tables
    existing_tables=$(nft list tables 2>/dev/null)

    # Fix 1: Create missing tables
    if ! echo "$existing_tables" | grep -q "^table ${NFTBAN_TABLE_IPV4}$"; then
        echo "  → Creating missing table: ${NFTBAN_TABLE_IPV4}"
        if nft add table ${NFTBAN_TABLE_IPV4} 2>/dev/null; then
            echo "  ✓ Created ${NFTBAN_TABLE_IPV4}"
            fixed=$((fixed + 1))
        else
            echo "  ✖ Failed to create ${NFTBAN_TABLE_IPV4}"
            return 2
        fi
    fi

    if ! echo "$existing_tables" | grep -q "^table ${NFTBAN_TABLE_IPV6}$"; then
        echo "  → Creating missing table: ${NFTBAN_TABLE_IPV6}"
        if nft add table ${NFTBAN_TABLE_IPV6} 2>/dev/null; then
            echo "  ✓ Created ${NFTBAN_TABLE_IPV6}"
            fixed=$((fixed + 1))
        else
            echo "  ⚠ Failed to create ${NFTBAN_TABLE_IPV6} (IPv6 optional)"
        fi
    fi

    # Fix 2: Create missing sets (IPv4)
    local set_name set_spec set_type set_flags
    for set_name in "${!NFTBAN_IPV4_SETS[@]}"; do
        if ! nft list set ${NFTBAN_TABLE_IPV4} "$set_name" &>/dev/null; then
            set_spec="${NFTBAN_IPV4_SETS[$set_name]}"
            IFS='|' read -r set_type set_flags _ <<< "$set_spec"

            local flags_clause=""
            [[ -n "$set_flags" ]] && flags_clause="flags $set_flags ;"

            echo "  → Creating missing set: ${NFTBAN_TABLE_IPV4} $set_name"
            if nft add set ${NFTBAN_TABLE_IPV4} "$set_name" "{ type $set_type ; $flags_clause }" 2>/dev/null; then
                echo "  ✓ Created set $set_name"
                fixed=$((fixed + 1))
            else
                echo "  ✖ Failed to create set $set_name"
            fi
        fi
    done

    # Fix 3: Create missing sets (IPv6)
    for set_name in "${!NFTBAN_IPV6_SETS[@]}"; do
        if ! nft list set ${NFTBAN_TABLE_IPV6} "$set_name" &>/dev/null; then
            set_spec="${NFTBAN_IPV6_SETS[$set_name]}"
            IFS='|' read -r set_type set_flags _ <<< "$set_spec"

            local flags_clause=""
            [[ -n "$set_flags" ]] && flags_clause="flags $set_flags ;"

            echo "  → Creating missing set: ${NFTBAN_TABLE_IPV6} $set_name"
            if nft add set ${NFTBAN_TABLE_IPV6} "$set_name" "{ type $set_type ; $flags_clause }" 2>/dev/null; then
                echo "  ✓ Created set $set_name"
                fixed=$((fixed + 1))
            else
                echo "  ⚠ Failed to create IPv6 set $set_name"
            fi
        fi
    done

    # Fix 4: Create missing chains (IPv4)
    local chain_name chain_spec chain_type chain_hook chain_priority chain_policy
    for chain_name in "${!NFTBAN_IPV4_CHAINS[@]}"; do
        if ! nft list chain ${NFTBAN_TABLE_IPV4} "$chain_name" &>/dev/null; then
            chain_spec="${NFTBAN_IPV4_CHAINS[$chain_name]}"
            IFS='|' read -r chain_type chain_hook chain_priority chain_policy _ <<< "$chain_spec"

            echo "  → Creating missing chain: ${NFTBAN_TABLE_IPV4} $chain_name"
            if nft add chain ${NFTBAN_TABLE_IPV4} "$chain_name" "{ type $chain_type hook $chain_hook priority $chain_priority ; policy $chain_policy ; }" 2>/dev/null; then
                echo "  ✓ Created chain $chain_name (type=$chain_type hook=$chain_hook priority=$chain_priority policy=$chain_policy)"
                fixed=$((fixed + 1))
            else
                echo "  ✖ Failed to create chain $chain_name"
            fi
        fi
    done

    # Fix 5: Create missing chains (IPv6)
    for chain_name in "${!NFTBAN_IPV6_CHAINS[@]}"; do
        if ! nft list chain ${NFTBAN_TABLE_IPV6} "$chain_name" &>/dev/null; then
            chain_spec="${NFTBAN_IPV6_CHAINS[$chain_name]}"
            IFS='|' read -r chain_type chain_hook chain_priority chain_policy _ <<< "$chain_spec"

            echo "  → Creating missing chain: ${NFTBAN_TABLE_IPV6} $chain_name"
            if nft add chain ${NFTBAN_TABLE_IPV6} "$chain_name" "{ type $chain_type hook $chain_hook priority $chain_priority ; policy $chain_policy ; }" 2>/dev/null; then
                echo "  ✓ Created chain $chain_name"
                fixed=$((fixed + 1))
            else
                echo "  ⚠ Failed to create IPv6 chain $chain_name"
            fi
        fi
    done

    # Fix 6: Remove deprecated tables (if confirmed safe)
    for deprecated_table in "${!NFTBAN_DEPRECATED_TABLES[@]}"; do
        if echo "$existing_tables" | grep -q "^table ${deprecated_table}$"; then
            echo "  ⚠ Legacy table found: ${deprecated_table}"
            echo "    Reason: ${NFTBAN_DEPRECATED_TABLES[$deprecated_table]}"
            echo "    Manual removal: nft delete table ${deprecated_table}"
        fi
    done

    if [[ $fixed -eq 0 ]]; then
        echo "  ✓ All nftables structure correct"
    else
        echo "  ✓ Fixed $fixed nftables structure issues"
    fi

    return 0
}

# =============================================================================
# POLKIT RULES AUTO-HEAL
# =============================================================================

nftban_health_fix_polkit() {
    # Auto-heal missing or broken polkit rules
    # Copies canonical rules from packaging/ to /etc/polkit-1/rules.d/
    # Returns: 0=fixed, 1=partial, 2=failed

    echo "Checking polkit rules..."

    if ! command -v pkaction >/dev/null 2>&1; then
        echo "  ⚠ Polkit not installed - skipping (optional for root-only installs)"
        return 0
    fi

    local polkit_rules_dir="${NFTBAN_POLKIT_RULES_DIR:-$(nftban_distro_get_polkit_dir)}"
    local source_dir="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/packaging/polkit-1/rules.d"
    local fixed=0
    local failed=0

    # Three canonical rule files (v1.0.19+ naming)
    local -a rule_files=(
        "10-nftban-systemd.rules"
        "20-nftban-auditor.rules"
        "30-nftban-panel.rules"
    )

    for rule_file in "${rule_files[@]}"; do
        local target="${polkit_rules_dir}/${rule_file}"
        local source="${source_dir}/${rule_file}"

        if [[ ! -f "$target" ]]; then
            echo "  → Missing: ${rule_file}"
            if [[ -f "$source" ]]; then
                if cp "$source" "$target" 2>/dev/null; then
                    chmod 644 "$target" 2>/dev/null
                    echo "  ✓ Installed ${rule_file}"
                    fixed=$((fixed + 1))
                else
                    echo "  ✖ Failed to install ${rule_file} (permission denied)"
                    failed=$((failed + 1))
                fi
            else
                echo "  ✖ Source not found: ${source}"
                failed=$((failed + 1))
            fi
        else
            # Verify permissions
            local perms
            perms=$(stat -c '%a' "$target" 2>/dev/null || echo "000")
            if [[ "$perms" != "644" ]]; then
                echo "  → Wrong permissions on ${rule_file}: $perms (fixing to 644)"
                if chmod 644 "$target" 2>/dev/null; then
                    echo "  ✓ Fixed permissions on ${rule_file}"
                    fixed=$((fixed + 1))
                else
                    echo "  ✖ Failed to fix permissions on ${rule_file}"
                    failed=$((failed + 1))
                fi
            fi
        fi
    done

    # Remove obsolete rule files (pre-v1.0.19)
    local -a obsolete_files=(
        "50-nftban-auth.rules"
        "60-nftban-services.rules"
        "10-nftban-core.rules"
        "50-nftban-v030.rules"
        "20-nftban-suricata.rules"
    )

    for obsolete in "${obsolete_files[@]}"; do
        if [[ -f "${polkit_rules_dir}/${obsolete}" ]]; then
            echo "  → Removing obsolete: ${obsolete}"
            if rm -f "${polkit_rules_dir}/${obsolete}" 2>/dev/null; then
                echo "  ✓ Removed ${obsolete}"
                fixed=$((fixed + 1))
            else
                echo "  ⚠ Cannot remove ${obsolete} (permission denied)"
            fi
        fi
    done

    # Restart polkit if rules were changed
    if [[ $fixed -gt 0 ]]; then
        local polkit_service="polkit"
        if declare -F nftban_distro_get_service >/dev/null 2>&1; then
            polkit_service=$(nftban_distro_get_service polkit)
            [[ -z "$polkit_service" ]] && polkit_service="polkit"
        fi
        systemctl restart "$polkit_service" 2>/dev/null || true
        echo "  ✓ Restarted polkit service"
    fi

    if [[ $failed -gt 0 ]]; then
        echo "  ⚠ $failed polkit issues could not be fixed (run as root)"
        return 1
    elif [[ $fixed -eq 0 ]]; then
        echo "  ✓ All polkit rules correct"
    else
        echo "  ✓ Fixed $fixed polkit issues"
    fi

    return 0
}

# =============================================================================
# DAEMON MEMORY HEALTH
# =============================================================================

nftban_health_fix_daemon_memory() {
    # Detect and fix memory leaks in nftband daemon
    # Thresholds based on empirical data from production:
    # - Normal: 15-30MB RSS after hours of operation
    # - Warning: >100MB RSS
    # - Critical: >300MB RSS or >50MB/hour growth rate
    #
    # This function:
    # 1. Checks current memory usage
    # 2. Calculates growth rate (MB/hour)
    # 3. Checks cgroup memory pressure
    # 4. Restarts daemon if critical threshold exceeded

    echo "Checking daemon memory health..."

    local pid rss_kb uptime_sec mb_per_hour memory_pressure
    local warning_rss_kb=102400      # 100MB in KB
    local critical_rss_kb=307200     # 300MB in KB
    local critical_growth_rate=50    # MB per hour

    # Get daemon PID
    pid=$(cat "${NFTBAN_RUN_DIR:-/run/nftban}/nftband.pid" 2>/dev/null || echo "")
    if [[ -z "$pid" ]] || [[ ! -d "/proc/$pid" ]]; then
        echo "  ⚠ nftband not running, skipping memory check"
        return 0
    fi

    # Get current RSS (in KB)
    rss_kb=$(awk '/VmRSS/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo "0")
    if [[ "$rss_kb" == "0" ]]; then
        echo "  ⚠ Cannot read daemon memory stats"
        return 0
    fi

    # Get uptime in seconds
    uptime_sec=$(ps -p "$pid" -o etimes= 2>/dev/null | tr -d ' ' || echo "0")
    [[ "$uptime_sec" == "0" ]] && uptime_sec=1

    # Calculate MB per hour growth rate
    # Formula: (current_MB / uptime_hours)
    # This assumes daemon starts at ~15MB baseline
    local baseline_mb=15
    local current_mb=$((rss_kb / 1024))
    local uptime_hours=$((uptime_sec / 3600))
    [[ $uptime_hours -lt 1 ]] && uptime_hours=1

    local growth_mb=$((current_mb - baseline_mb))
    [[ $growth_mb -lt 0 ]] && growth_mb=0
    mb_per_hour=$((growth_mb / uptime_hours))

    # Check cgroup memory pressure (cgroup v2)
    memory_pressure=0
    local pressure_file="/sys/fs/cgroup/system.slice/nftband.service/memory.pressure"
    if [[ -f "$pressure_file" ]]; then
        # Extract avg10 value (0-100 scale)
        memory_pressure=$(awk '/^some/ {gsub(/avg10=/, ""); print int($2)}' "$pressure_file" 2>/dev/null || echo "0")
    fi

    # Report current state
    local uptime_human
    if [[ $uptime_sec -ge 3600 ]]; then
        uptime_human="$((uptime_sec / 3600))h $((uptime_sec % 3600 / 60))m"
    else
        uptime_human="$((uptime_sec / 60))m"
    fi

    echo "  PID: $pid | RSS: ${current_mb}MB | Uptime: $uptime_human | Growth: ${mb_per_hour}MB/h | Pressure: ${memory_pressure}%"

    # Check thresholds
    local needs_restart=0
    local status="OK"

    if [[ $rss_kb -gt $critical_rss_kb ]]; then
        echo "  ✖ CRITICAL: RSS ${current_mb}MB exceeds 300MB limit"
        needs_restart=1
        status="CRITICAL"
    elif [[ $mb_per_hour -gt $critical_growth_rate ]] && [[ $uptime_hours -ge 1 ]]; then
        echo "  ✖ CRITICAL: Memory growth ${mb_per_hour}MB/h exceeds 50MB/h limit"
        needs_restart=1
        status="CRITICAL"
    elif [[ $memory_pressure -gt 80 ]]; then
        echo "  ✖ CRITICAL: Memory pressure ${memory_pressure}% exceeds 80%"
        needs_restart=1
        status="CRITICAL"
    elif [[ $rss_kb -gt $warning_rss_kb ]]; then
        echo "  ⚠ WARNING: RSS ${current_mb}MB exceeds 100MB threshold"
        status="WARNING"
    elif [[ $memory_pressure -gt 50 ]]; then
        echo "  ⚠ WARNING: Memory pressure ${memory_pressure}% exceeds 50%"
        status="WARNING"
    else
        echo "  ✓ Daemon memory usage healthy"
    fi

    # Auto-restart if critical
    if [[ $needs_restart -eq 1 ]]; then
        echo "  → Restarting nftband to fix memory leak..."

        # Log the event
        logger -t nftban-health "Memory leak detected: RSS=${current_mb}MB, Growth=${mb_per_hour}MB/h, Pressure=${memory_pressure}%. Restarting nftband."

        if systemctl restart nftband 2>/dev/null; then
            sleep 2
            local new_pid new_rss
            new_pid=$(cat "${NFTBAN_RUN_DIR:-/run/nftban}/nftband.pid" 2>/dev/null || echo "")
            if [[ -n "$new_pid" ]] && [[ -d "/proc/$new_pid" ]]; then
                new_rss=$(awk '/VmRSS/ {print int($2/1024)}' "/proc/$new_pid/status" 2>/dev/null || echo "?")
                echo "  ✓ Daemon restarted. New PID: $new_pid, RSS: ${new_rss}MB"
            else
                echo "  ✖ Daemon restart failed - not running"
                return 1
            fi
        else
            echo "  ✖ Failed to restart nftband"
            return 1
        fi
    fi

    # Save metrics for trending
    local metrics_file="${NFTBAN_RUN_DIR:-/run/nftban}/daemon_memory.dat"
    echo "$(date +%s) $rss_kb $uptime_sec $mb_per_hour $memory_pressure" >> "$metrics_file" 2>/dev/null || true
    # Keep only last 100 entries
    tail -100 "$metrics_file" > "$metrics_file.tmp" 2>/dev/null && mv "$metrics_file.tmp" "$metrics_file" 2>/dev/null || true

    return 0
}

# =============================================================================
# REPORTING
# =============================================================================

