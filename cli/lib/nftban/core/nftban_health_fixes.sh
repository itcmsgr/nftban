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
# meta:inventory.systemd_units="nftban-health.timer,nftban-metrics-exporter.timer,prometheus.service,victoriametrics.service"
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2026-01-09"
# meta:updated_date="2026-01-09"
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_NFTBAN_HEALTH_FIXES_LOADED:-}" ]] && return 0
_NFTBAN_HEALTH_FIXES_LOADED=1

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
            # CRITICAL: Shell scripts MUST be executable (755), not 644
            find "${NFTBAN_LIB_DIR}" -type f -name "*.sh" -exec chown root:root {} \; 2>/dev/null
            find "${NFTBAN_LIB_DIR}" -type f -name "*.sh" -exec chmod 755 {} \; 2>/dev/null

            # Fix binary permissions (if they exist)
            find "${NFTBAN_LIB_DIR}/bin" -type f 2>/dev/null | while read -r binary; do
                chown root:root "$binary" 2>/dev/null
                chmod 755 "$binary" 2>/dev/null
            done

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

            # Fix eve-alerts.json: suricata:nftban 640 so nftban can read
            if [[ -f "${NFTBAN_LOG_DIR}/suricata/eve-alerts.json" ]]; then
                chown suricata:nftban "${NFTBAN_LOG_DIR}/suricata/eve-alerts.json" 2>/dev/null
                chmod 640 "${NFTBAN_LOG_DIR}/suricata/eve-alerts.json" 2>/dev/null
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
        "nftban-metrics-exporter.timer"
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
    if systemctl is-enabled nftban-metrics-exporter.timer &>/dev/null; then
        if ! systemctl is-active nftban-metrics-exporter.timer &>/dev/null; then
            systemctl start nftban-metrics-exporter.timer 2>/dev/null || true
            echo "  ✓ Started metrics exporter timer"
            fixed=$((fixed + 1))
        fi
    fi

    # Fix 2: Ensure textfile collector directory exists
    local textfile_dir="/var/lib/node_exporter/textfile_collector"
    if [[ ! -d "$textfile_dir" ]]; then
        # Create with correct ownership (no -R needed for fresh directory)
        install -d -o nftban -g nftban -m 0755 "$textfile_dir" 2>/dev/null || \
            mkdir -p "$textfile_dir" 2>/dev/null
        chown nftban:nftban "$textfile_dir" 2>/dev/null || true
        chmod 755 "$textfile_dir" 2>/dev/null || true
        echo "  ✓ Created textfile collector directory"
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

/var/log/nftban/suricata/eve-alerts.json {
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

        # Ensure directory exists
        mkdir -p "$geoip_dir" 2>/dev/null
        chown nftban:nftban "$geoip_dir" 2>/dev/null || true
        chmod 750 "$geoip_dir" 2>/dev/null || true

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
# REPORTING
# =============================================================================

