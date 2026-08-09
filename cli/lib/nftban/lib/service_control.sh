#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="service_control" meta:type="lib" meta:version="1.48.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Centralized service control for enable/disable NFTBan and subsystems"
# meta:inventory.files=""
# meta:inventory.binaries="systemctl,nftban,nftban-core"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR"
# meta:inventory.config_files="/etc/nftban/nftban.conf"
# meta:inventory.systemd_units="nftables.service"
# meta:inventory.network=""
# meta:inventory.privileges="root"

set -Eeuo pipefail

# Guard against multiple sourcing (C4 fix: unique guard name to avoid collision with nftban_service_control.sh)
[[ -n "${_NFTBAN_SVC_CONTROL_LOADED:-}" ]] && return 0
readonly _NFTBAN_SVC_CONTROL_LOADED=1

# =============================================================================
# CONFIGURATION
# =============================================================================

# Bootstrap config path (nftban.conf will make it readonly)
: "${NFTBAN_CONFIG_DIR:=/etc/nftban}"

# Load main configuration (sets readonly paths, service names)
source "${NFTBAN_CONFIG_DIR}/nftban.conf" 2>/dev/null || true
NFTBAN_SERVICES_CONF="${NFTBAN_CONFIG_DIR}/conf.d/services.conf"
NFTBAN_SERVICES_LOCAL="${NFTBAN_CONFIG_DIR}/conf.d/services.conf.local"

# Load services config
_nftban_load_services_config() {
    # Load base config
    if [[ -f "$NFTBAN_SERVICES_CONF" ]]; then
        # shellcheck source=/dev/null
        source "$NFTBAN_SERVICES_CONF" || true
    fi

    # Load local overrides
    if [[ -f "$NFTBAN_SERVICES_LOCAL" ]]; then
        # shellcheck source=/dev/null
        # IMPL-1: ensure _source_local is defined wherever this file is loaded (env.sh idempotent)
        declare -F _source_local >/dev/null 2>&1 || source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/env.sh" 2>/dev/null || true
        _source_local "$NFTBAN_SERVICES_LOCAL"
    fi
}

# =============================================================================
# MASTER SWITCH FUNCTIONS
# =============================================================================

# Check if NFTBan is globally enabled
# Returns: 0 if enabled, 1 if disabled
nftban_is_enabled() {
    _nftban_load_services_config

    # Check kernel command line for emergency disable
    if grep -q 'nftban=disabled' /proc/cmdline 2>/dev/null; then
        return 1
    fi

    # Check master switch
    [[ "${NFTBAN_ENABLED:-true}" == "true" ]]
}

# Check master switch and exit if disabled
# Usage: nftban_check_enabled || exit 0
nftban_check_enabled() {
    if ! nftban_is_enabled; then
        echo "NFTBan is disabled (NFTBAN_ENABLED=false or kernel parameter nftban=disabled)" >&2
        return 1
    fi
    return 0
}

# =============================================================================
# SERVICE-SPECIFIC CHECKS
# =============================================================================

# Check if a specific service is enabled in config
# Usage: nftban_service_is_enabled "nftables"
# Returns: 0 if enabled, 1 if disabled
nftban_service_is_enabled() {
    local service="$1"
    _nftban_load_services_config

    # Master switch overrides everything
    if ! nftban_is_enabled; then
        return 1
    fi

    case "$service" in
        nftables)
            [[ "${NFTABLES_ENABLED:-true}" == "true" ]]
            ;;
        suricata)
            [[ "${SURICATA_ENABLED:-true}" == "true" ]]
            ;;
        login|login_monitor)
            # Login uses its own config file
            local login_conf="${NFTBAN_CONFIG_DIR}/conf.d/login_alert.conf"
            local login_local="${NFTBAN_CONFIG_DIR}/conf.d/login_alert.conf.local"

            # Default to true, check configs
            local enabled="true"
            if [[ -f "$login_conf" ]]; then
                # shellcheck source=/dev/null
                source "$login_conf" || true
                enabled="${NFTBAN_LOGIN_ALERT_ENABLED:-true}"
            fi
            if [[ -f "$login_local" ]]; then
                # shellcheck source=/dev/null
                _source_local "$login_local"
                enabled="${NFTBAN_LOGIN_ALERT_ENABLED:-$enabled}"
            fi
            [[ "$enabled" == "true" ]]
            ;;
        *)
            # Unknown service - assume enabled
            return 0
            ;;
    esac
}

# Check if auto-start is enabled for a service
# Usage: nftban_service_auto_start "nftables"
nftban_service_auto_start() {
    local service="$1"
    _nftban_load_services_config

    case "$service" in
        nftables)
            [[ "${NFTABLES_AUTO_START:-false}" == "true" ]]
            ;;
        suricata)
            [[ "${SURICATA_AUTO_START:-false}" == "true" ]]
            ;;
        *)
            return 1
            ;;
    esac
}

# =============================================================================
# FIREWALL CONFLICT RESOLUTION
# =============================================================================

# Resolve conflicting firewalls before enabling NFTBan
# Detects firewalld, ufw, iptables services and offers to disable them
# Usage: nftban_resolve_firewall_conflicts
nftban_resolve_firewall_conflicts() {
    local conflicts_found=0
    local backup_dir
    backup_dir="${NFTBAN_DATA_DIR:-/var/lib/nftban}/backups/firewall-migration-$(date +%Y%m%d-%H%M%S)"

    echo ""
    echo "Checking for conflicting firewalls..."

    # Check firewalld (RHEL/CentOS/Fedora)
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        echo ""
        echo "[!] CONFLICT: firewalld is ACTIVE"
        echo "    NFTBan cannot coexist with firewalld."
        echo ""
        read -r -p "    Backup firewalld rules and disable it? [Y/n] " response
        response=${response:-Y}
        if [[ "$response" =~ ^[Yy]$ ]]; then
            mkdir -p "$backup_dir" || return 1
            echo "    Backing up firewalld config to $backup_dir/..."
            firewall-cmd --list-all-zones > "$backup_dir/firewalld-zones.txt" 2>/dev/null || true
            cp -r /etc/firewalld "$backup_dir/" 2>/dev/null || true
            echo "    Stopping and disabling firewalld..."
            if ! systemctl stop firewalld 2>/dev/null; then
                echo "    [!] Warning: Failed to stop firewalld (may already be stopped)"
            fi
            if ! systemctl disable firewalld 2>/dev/null; then
                echo "    [!] Warning: Failed to disable firewalld"
            fi
            echo "    [✓] firewalld disabled"
        else
            echo "    [!] Skipped - firewalld still active (may cause issues)"
            conflicts_found=1
        fi
    fi

    # Check ufw (Ubuntu/Debian)
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        echo ""
        echo "[!] CONFLICT: ufw is ACTIVE"
        echo "    NFTBan cannot coexist with ufw."
        echo ""
        read -r -p "    Backup ufw rules and disable it? [Y/n] " response
        response=${response:-Y}
        if [[ "$response" =~ ^[Yy]$ ]]; then
            mkdir -p "$backup_dir" || return 1
            echo "    Backing up ufw config to $backup_dir/..."
            ufw status verbose > "$backup_dir/ufw-status.txt" 2>/dev/null || true
            cp -r /etc/ufw "$backup_dir/" 2>/dev/null || true
            echo "    Disabling ufw..."
            ufw disable
            echo "    [✓] ufw disabled"
        else
            echo "    [!] Skipped - ufw still active (may cause issues)"
            conflicts_found=1
        fi
    fi

    # Check iptables service (legacy systems)
    if systemctl is-active --quiet iptables 2>/dev/null || \
       systemctl is-active --quiet iptables.service 2>/dev/null; then
        echo ""
        echo "[!] CONFLICT: iptables service is ACTIVE"
        echo "    NFTBan uses nftables and cannot coexist with iptables service."
        echo ""
        read -r -p "    Backup iptables rules and disable service? [Y/n] " response
        response=${response:-Y}
        if [[ "$response" =~ ^[Yy]$ ]]; then
            mkdir -p "$backup_dir" || return 1
            echo "    Backing up iptables rules to $backup_dir/..."
            iptables-save > "$backup_dir/iptables-v4.rules" 2>/dev/null || true
            ip6tables-save > "$backup_dir/iptables-v6.rules" 2>/dev/null || true
            echo "    Stopping and disabling iptables service..."
            systemctl stop iptables 2>/dev/null || true
            systemctl stop ip6tables 2>/dev/null || true
            systemctl disable iptables 2>/dev/null || true
            systemctl disable ip6tables 2>/dev/null || true
            echo "    [✓] iptables service disabled"
        else
            echo "    [!] Skipped - iptables service still active (may cause issues)"
            conflicts_found=1
        fi
    fi

    # Show backup location if backups were created
    if [[ -d "$backup_dir" ]]; then
        echo ""
        echo "[✓] Firewall configs backed up to: $backup_dir"
    fi

    if [[ $conflicts_found -eq 1 ]]; then
        echo ""
        echo "[!] WARNING: Some conflicting firewalls are still active."
        echo "    NFTBan may not work correctly until they are disabled."
        return 1
    fi

    echo "[✓] No firewall conflicts"
    return 0
}

# =============================================================================
# SERVICE CONTROL FUNCTIONS
# =============================================================================

# Enable all NFTBan services — SINGLE SOURCE OF TRUTH (v1.22.0)
# Implements Minimum Safe State: either PROTECTED or explicit FAIL.
# No partial success. No false "ACTIVE" state.
# Usage: nftban_enable_all
nftban_enable_all() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: PolicyKit/polkit authorization failed or insufficient privileges (enable services)" >&2
        return 1
    fi

    # Track which firewall was disabled for rollback
    local _prev_firewall=""

    # Check and resolve firewall conflicts first
    # Detect BEFORE disabling (using runtime state, not binary presence)
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        _prev_firewall="firewalld"
    elif command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        _prev_firewall="ufw"
    elif systemctl is-active --quiet iptables 2>/dev/null; then
        _prev_firewall="iptables"
    fi

    if ! nftban_resolve_firewall_conflicts; then
        echo "ERROR: Failed to resolve firewall conflicts" >&2
        return 1
    fi

    echo ""
    echo "Enabling all NFTBan services..."
    echo ""

    # =========================================================================
    # [1/10] Fix permissions and create directories
    # =========================================================================
    echo "[1/10] Fixing permissions and creating directories..."
    if command -v nftban &>/dev/null; then
        nftban permissions enforce >/dev/null 2>&1 || true
        nftban health check --auto-heal >/dev/null 2>&1 || true
    fi
    echo "  ✅ Permissions fixed"
    echo ""

    # =========================================================================
    # [2/10] Auto-whitelist system IP (write config file for lockout prevention)
    # =========================================================================
    echo "[2/10] Auto-whitelisting system IP..."
    if declare -f _nftban_auto_whitelist_system_ip &>/dev/null; then
        _nftban_auto_whitelist_system_ip
    fi

    # Whitelist the admin's SSH session IP (lockout prevention)
    # Uses --protect-session to detect SSH_CLIENT/SSH_CONNECTION
    if [[ -n "${SSH_CLIENT:-}" || -n "${SSH_CONNECTION:-}" ]]; then
        local admin_ip=""
        admin_ip=$(echo "${SSH_CLIENT:-${SSH_CONNECTION:-}}" | awk '{print $1}')
        if [[ -n "$admin_ip" && "$admin_ip" != "127.0.0.1" && "$admin_ip" != "::1" ]]; then
            # Append to system whitelist if not already present
            local sys_wl="${NFTBAN_CONFIG_DIR}/whitelist.d/00-system.conf"
            if [[ -f "$sys_wl" ]] && ! grep -q "^${admin_ip}" "$sys_wl" 2>/dev/null; then
                echo "${admin_ip}  # Admin session (enable lockout prevention) (added: $(date -u '+%Y-%m-%d %H:%M:%S UTC'))" >> "$sys_wl"
                echo "  ✅ Admin session IP whitelisted: $admin_ip"
            elif ! grep -rq "^${admin_ip}" "${NFTBAN_CONFIG_DIR}/whitelist.d/" 2>/dev/null; then
                echo "${admin_ip}  # Admin session (enable lockout prevention) (added: $(date -u '+%Y-%m-%d %H:%M:%S UTC'))" >> "$sys_wl"
                echo "  ✅ Admin session IP whitelisted: $admin_ip"
            else
                echo "  ✅ Admin session IP already whitelisted: $admin_ip"
            fi
        fi
    fi
    echo ""

    # =========================================================================
    # [3/10] Auto-detect and whitelist SSH port + panel ports + essential ports
    # =========================================================================
    echo "[3/10] Auto-detecting ports (SSH, panel, essential services)..."

    # SSH port (primary lockout prevention)
    # Source cmd_system.sh if SSH port function not already available
    if ! declare -f _nftban_auto_whitelist_ssh_port &>/dev/null; then
        local _sys_lib="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/cli/cmd_system.sh"
        # shellcheck source=/dev/null
        [[ -f "$_sys_lib" ]] && source "$_sys_lib" 2>/dev/null || true
    fi
    if declare -f _nftban_auto_whitelist_ssh_port &>/dev/null; then
        _nftban_auto_whitelist_ssh_port
    fi

    # Panel port detection (Plesk, cPanel, DirectAdmin, etc.)
    # Source panel library if not already loaded
    local _panel_lib="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_panel_common.sh"
    if ! declare -f nftban_panel_detect &>/dev/null && [[ -f "$_panel_lib" ]]; then
        # shellcheck source=/dev/null
        source "$_panel_lib" 2>/dev/null || true
    fi
    local detected_panel="none"
    if declare -f nftban_panel_detect &>/dev/null; then
        detected_panel=$(nftban_panel_detect 2>/dev/null) || detected_panel="none"
    fi
    if [[ "$detected_panel" != "none" ]]; then
        local panel_ports=""
        local panel_name=""
        if declare -f _get_panel_info &>/dev/null; then
            panel_ports=$(_get_panel_info "$detected_panel" "ports" 2>/dev/null) || panel_ports=""
            panel_name=$(_get_panel_info "$detected_panel" "name" 2>/dev/null) || panel_name="$detected_panel"
        fi
        if [[ -n "$panel_ports" ]]; then
            local panel_port_file="${NFTBAN_CONFIG_DIR}/ports.d/01-panel.conf"
            if [[ ! -f "$panel_port_file" ]]; then
                mkdir -p "${NFTBAN_CONFIG_DIR}/ports.d" 2>/dev/null || true
                {
                    echo "# Auto-detected panel ports"
                    echo "# Panel: $panel_name"
                    echo "# Date: $(date -Iseconds)"
                    echo "# Format: PORT/PROTOCOL/DIRECTION (T=TCP, I=Input)"
                    echo "$panel_ports" | tr ',' '\n' | while read -r port; do
                        echo "${port}/T/I"
                    done
                } > "$panel_port_file"
                chmod 644 "$panel_port_file"
                echo "  ✅ Panel ports whitelisted ($panel_name): $panel_ports"
            else
                echo "  ✅ Panel ports already configured ($panel_name)"
            fi
        fi
    fi

    # Essential service port detection (HTTP, HTTPS, mail, DNS)
    local essential_port_file="${NFTBAN_CONFIG_DIR}/ports.d/02-essential.conf"
    if [[ ! -f "$essential_port_file" ]]; then
        mkdir -p "${NFTBAN_CONFIG_DIR}/ports.d" 2>/dev/null || true
        # Detect listening TCP ports for well-known services
        local listening_ports
        listening_ports=$(ss -tlnH 2>/dev/null | awk '{print $4}' | grep -oP ':\K\d+$' | sort -un || true)
        local -a detected_essential=()
        for p in $listening_ports; do
            case "$p" in
                80|443)    detected_essential+=("$p") ;;  # HTTP/HTTPS
                25|465|587) detected_essential+=("$p") ;; # SMTP
                110|995)   detected_essential+=("$p") ;;  # POP3
                143|993)   detected_essential+=("$p") ;;  # IMAP
                53)        detected_essential+=("$p") ;;  # DNS
            esac
        done
        if [[ ${#detected_essential[@]} -gt 0 ]]; then
            {
                echo "# Auto-detected essential service ports"
                echo "# Created by: nftban enable"
                echo "# Date: $(date -Iseconds)"
                echo "# Format: PORT/PROTOCOL/DIRECTION (T=TCP, I=Input)"
                for p in "${detected_essential[@]}"; do
                    echo "${p}/T/I"
                done
                # DNS also needs UDP
                if printf '%s\n' "${detected_essential[@]}" | grep -q '^53$'; then
                    echo "53/U/I"
                fi
            } > "$essential_port_file"
            chmod 644 "$essential_port_file"
            local ports_list
            ports_list=$(printf '%s,' "${detected_essential[@]}")
            echo "  ✅ Essential ports whitelisted: ${ports_list%,}"
        else
            echo "  ℹ️  No additional essential service ports detected"
        fi
    else
        echo "  ✅ Essential ports already configured"
    fi
    echo ""

    # =========================================================================
    # [4/10] Initialize firewall (with rollback on failure)
    # =========================================================================
    echo "[4/10] Initializing firewall..."
    if ! nft list table ip nftban >/dev/null 2>&1; then
        echo "  Firewall not initialized, initializing now..."
        if command -v nftban &>/dev/null; then
            # v1.228.5: rebuild returns non-zero with the CAUSE on stderr. Discarding
            # it left this branch — which rolls the previous firewall back and returns
            # 1 — with no evidence at all. Capture it; report a BOUNDED excerpt.
            # Pass/fail semantics and the rollback below are unchanged.
            local _fw_rc=0 _fw_out="" _fw_line
            _fw_out="$(nftban firewall rebuild 2>&1)" || _fw_rc=$?
            if [[ $_fw_rc -eq 0 ]]; then
                echo "  ✅ Firewall initialized"
            else
                echo "  ❌ ERROR: Failed to initialize firewall (exit $_fw_rc)" >&2
                if [[ -n "$_fw_out" ]]; then
                    while IFS= read -r _fw_line; do
                        if [[ -n "$_fw_line" ]]; then
                            echo "     rebuild: $_fw_line" >&2
                        fi
                    done <<< "$(printf '%s\n' "$_fw_out" | tail -n 5)"
                fi
                # ROLLBACK: Restore previous firewall if we disabled one
                if [[ -n "$_prev_firewall" ]]; then
                    echo "  Restoring previous firewall ($_prev_firewall)..."
                    case "$_prev_firewall" in
                        firewalld)
                            systemctl enable firewalld 2>/dev/null || true
                            systemctl start firewalld 2>/dev/null || true
                            ;;
                        ufw)
                            ufw --force enable 2>/dev/null || true
                            ;;
                        iptables)
                            systemctl enable iptables 2>/dev/null || true
                            systemctl start iptables 2>/dev/null || true
                            ;;
                    esac
                    echo "  ✅ Previous firewall restored: $_prev_firewall"
                fi
                echo "  ❌ Protection failed — rollback applied" >&2
                return 1
            fi
        fi
    else
        echo "  ✅ Firewall already initialized"
    fi
    echo ""

    # =========================================================================
    # [5/10] Validate configuration
    # =========================================================================
    echo "[5/10] Validating configuration..."
    local config_errors=0
    [[ ! -f "${NFTBAN_CONFIG_DIR}/nftban.conf" ]] && config_errors=$((config_errors + 1))
    [[ ! -f "${NFTBAN_CONFIG_DIR}/ports.d/00-ssh.conf" ]] && echo "  ⚠️  WARNING: SSH port config missing" && config_errors=$((config_errors + 1))
    if [[ $config_errors -gt 0 ]]; then
        echo "  ⚠️  WARNING: $config_errors config issues detected"
    else
        echo "  ✅ Configuration valid"
    fi
    echo ""

    # =========================================================================
    # [6/10] Enable core services (names from central config, not hardcoded)
    # =========================================================================
    echo "[6/10] Enabling core services..."
    _nftban_set_config "NFTBAN_ENABLED" "true"

    # Service names from nftban.conf (per-distro safe)
    local svc_daemon="${NFTBAN_SERVICE_DAEMON:-nftband.service}"
    local svc_login="${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service}"

    # nftables is an external service — always "nftables.service" but resolved via config
    local services=("nftables.service" "$svc_daemon")
    if command -v suricata &>/dev/null; then
        services+=("suricata.service")
    fi

    for svc in "${services[@]}"; do
        if systemctl list-unit-files "$svc" &>/dev/null 2>&1; then
            systemctl enable "$svc" 2>/dev/null && \
            systemctl start "$svc" 2>/dev/null && \
            echo "  ✅ Enabled & started: ${svc%.service}"
        fi
    done

    # Sync whitelist into running daemon (must happen AFTER nftband starts)
    if command -v nftban &>/dev/null; then
        nftban whitelist-system sync 2>/dev/null || echo "  ⚠️  Whitelist sync deferred (daemon initializing)"
    fi
    echo ""

    # =========================================================================
    # [7/10] Enable timers (names from central config, not hardcoded)
    # =========================================================================
    echo "[7/10] Enabling timers..."

    # Timer names from nftban.conf (per-distro safe)
    local tmr_health="${NFTBAN_TIMER_HEALTH:-nftban-health.timer}"
    local tmr_maintenance="${NFTBAN_TIMER_MAINTENANCE:-nftban-maintenance.timer}"
    local tmr_watchdog="${NFTBAN_TIMER_WATCHDOG:-nftban-watchdog.timer}"
    local tmr_geoip="${NFTBAN_TIMER_GEOIP:-nftban-core-geoip.timer}"
    local tmr_metrics="${NFTBAN_TIMER_METRICS_EXPORTER:-nftban-unified-exporter.timer}"
    local tmr_feeds="${NFTBAN_TIMER_FEEDS:-nftban-core-feeds.timer}"
    # NFTBAN_TIMER_SURICATA_UPDATE is no longer read here: the timer it named
    # was retired in v1.228.2 (owner ruling D2). The key survives in
    # nftban.conf conffile space and is reported as a known stale key.
    # TMR-01: Snapshot/rollback timers are apply/confirm-managed, NOT
    # auto-enabled. nftban-rollback.timer is started by nftban-apply and stopped
    # by nftban-confirm (its unit's [Install] explicitly says "Do NOT
    # auto-enable" — auto-enabling fails on fresh install before any
    # backup.rules exists). The snapshot timer is paired with it under the same
    # apply/confirm lifecycle. They are intentionally omitted from core_timers
    # below so they stay confirm-managed rather than force-enabled here.

    # Core timers — ALWAYS enabled (non-negotiable)
    local core_timers=(
        "$tmr_health"
        "$tmr_maintenance"
        "$tmr_watchdog"
    )
    for timer in "${core_timers[@]}"; do
        if systemctl list-unit-files "$timer" &>/dev/null 2>&1; then
            systemctl enable "$timer" 2>/dev/null && \
            systemctl start "$timer" 2>/dev/null && \
            echo "  ✅ Enabled: $timer"
        fi
    done

    # GeoIP timer — always enabled (GeoIP is default-on)
    if systemctl list-unit-files "$tmr_geoip" &>/dev/null 2>&1; then
        systemctl enable "$tmr_geoip" 2>/dev/null && \
        systemctl start "$tmr_geoip" 2>/dev/null && \
        echo "  ✅ Enabled: $tmr_geoip"
    fi

    # Optional timers (config-gated)
    if [[ "${NFTBAN_METRICS_ENABLED:-false}" == "true" ]]; then
        if systemctl list-unit-files "$tmr_metrics" &>/dev/null 2>&1; then
            systemctl enable "$tmr_metrics" 2>/dev/null && \
            systemctl start "$tmr_metrics" 2>/dev/null && \
            echo "  ✅ Enabled: $tmr_metrics"
        fi
    fi
    if [[ "${NFTBAN_FEEDS_ENABLED:-false}" == "true" ]]; then
        if systemctl list-unit-files "$tmr_feeds" &>/dev/null 2>&1; then
            systemctl enable "$tmr_feeds" 2>/dev/null && \
            systemctl start "$tmr_feeds" 2>/dev/null && \
            echo "  ✅ Enabled: $tmr_feeds"
        fi
    fi
    # v1.228.2: the NFTBAN_SURICATA_ENABLED-gated enable of
    # nftban-suricata-update.timer is REMOVED. Suricata is retired from the
    # active product surface (owner ruling D2); the timer is no longer shipped
    # and package convergence removes it from hosts that have it. Enabling a
    # unit that does not exist can only ever fail, and leaving the branch in
    # place would keep a stale conffile key (NFTBAN_SURICATA_ENABLED) wired to
    # an operational effect that no longer exists.
    echo ""

    # =========================================================================
    # [8/10] Enable login monitor
    # =========================================================================
    echo "[8/10] Enabling login monitor..."
    if declare -f nftban_login_cmd_enable &>/dev/null; then
        nftban_login_cmd_enable >/dev/null 2>&1 && echo "  ✅ Login monitor enabled"
    elif command -v nftban >/dev/null 2>&1; then
        # cmd_login.sh may not be loaded in this context — call via CLI
        nftban login enable >/dev/null 2>&1 && echo "  ✅ Login monitor enabled"
    else
        echo "  ⚠️  Login monitor: nftban CLI not available"
    fi
    echo ""

    # =========================================================================
    # [9/10] GeoIP provisioning (default-on, immediate download if missing)
    # =========================================================================
    echo "[9/10] Provisioning GeoIP database..."
    _nftban_set_config "NFTBAN_GEOIP_ENABLED" "true"
    local geoip_dir="${NFTBAN_DATA_DIR:-/var/lib/nftban}/geoip"
    local geoip_found=0
    # Check for any supported GeoIP database
    for db_name in "dbip-country-lite.mmdb" "GeoLite2-Country.mmdb" "GeoLite2-City.mmdb"; do
        if [[ -f "${geoip_dir}/${db_name}" ]]; then
            geoip_found=1
            echo "  ✅ GeoIP database present: ${db_name}"
            break
        fi
    done
    if [[ $geoip_found -eq 0 ]]; then
        echo "  GeoIP database missing, downloading now..."
        if declare -f nftban_geoip_download &>/dev/null; then
            if nftban_geoip_download 2>/dev/null; then
                echo "  ✅ GeoIP database installed"
            else
                echo "  ⚠️  GeoIP download failed (will retry via timer)"
            fi
        elif command -v nftban &>/dev/null; then
            if nftban geoip download 2>/dev/null; then
                echo "  ✅ GeoIP database installed"
            else
                echo "  ⚠️  GeoIP download failed (will retry via timer)"
            fi
        else
            echo "  ⚠️  GeoIP provisioning unavailable"
        fi
    fi
    echo ""

    # =========================================================================
    # [10/10] POST-ENABLE VALIDATION GATE
    # =========================================================================
    # No false ACTIVE state. Either PROTECTED or NOT PROTECTED.
    echo "[10/10] Verifying protection state..."
    echo ""

    # Sync via Go daemon first
    if command -v nftban-core &>/dev/null; then
        nftban-core sync 2>/dev/null || true
    fi

    local validation_failures=()

    # Check 1: nft rules loaded > 0
    local rules_count _ruleset_raw
    if _ruleset_raw=$(nft list ruleset 2>/dev/null) && [[ -n "${_ruleset_raw//[[:space:]]/}" ]]; then
        rules_count=$(printf '%s' "$_ruleset_raw" | grep -cE '^\s+(type|chain|rule|set)' || true)
        rules_count=${rules_count:-0}
        if [[ "$rules_count" -eq 0 ]]; then
            validation_failures+=("nft rules: 0 (no firewall rules loaded)")
        fi
    else
        # A ruleset that could not be read is not a ruleset with no rules. Both
        # are failures here, but only one of them is a statement about the
        # firewall — the other is a statement about our own visibility.
        validation_failures+=("nft rules: UNKNOWN (ruleset could not be read; rule count NOT established)")
    fi

    # Check 2: nftband active (using config var)
    local nftband_state
    nftband_state=$(systemctl is-active "${svc_daemon}" 2>/dev/null || echo "inactive")
    if [[ "$nftband_state" != "active" ]]; then
        validation_failures+=("${svc_daemon%.service}: $nftband_state")
    fi

    # Check 3: login monitoring active
    # v1.23.0: login-monitor.service removed; loginmon now runs via nftband daemon
    # Check PID file instead of systemd service
    if [[ ! -f "${NFTBAN_RUN_DIR:-/run/nftban}/loginmon.pid" ]]; then
        # Not critical if daemon is active (loginmon starts with daemon)
        if [[ "$nftband_state" != "active" ]]; then
            validation_failures+=("loginmon: not running (no PID file)")
        fi
    fi

    # Check 4: core timers active (at least 1)
    local timers_active=0
    # wrap systemctl (rc!=0 path) so wc emits one count, never "0\n0" into the `[[ -eq 0 ]]`.
    timers_active=$({ systemctl list-timers 'nftban-*' --no-legend 2>/dev/null || true; } | wc -l)
    timers_active=${timers_active//[^0-9]/}; timers_active=${timers_active:-0}
    if [[ "$timers_active" -eq 0 ]]; then
        validation_failures+=("timers: 0 active")
    fi

    # Check 5: SSH port preserved
    local ssh_conf="${NFTBAN_CONFIG_DIR}/ports.d/00-ssh.conf"
    if [[ ! -f "$ssh_conf" ]]; then
        validation_failures+=("SSH port config: missing")
    fi

    # Check 6: GeoIP database present
    local geoip_present=0
    for db_name in "dbip-country-lite.mmdb" "GeoLite2-Country.mmdb" "GeoLite2-City.mmdb"; do
        if [[ -f "${geoip_dir}/${db_name}" ]]; then
            geoip_present=1
            break
        fi
    done
    if [[ $geoip_present -eq 0 ]]; then
        validation_failures+=("GeoIP database: missing (DEGRADED)")
    fi

    # Final verdict
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ ${#validation_failures[@]} -eq 0 ]]; then
        echo "✅ PROTECTED"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "  Rules: $rules_count | nftband: $nftband_state | Timers: $timers_active"
        echo "  Run 'nftban status' for full details"
        return 0
    else
        # Check if it's just GeoIP (DEGRADED) or something critical (NOT PROTECTED)
        local critical_failures=0
        for failure in "${validation_failures[@]}"; do
            [[ "$failure" != *"DEGRADED"* ]] && critical_failures=$((critical_failures + 1))
        done

        if [[ $critical_failures -eq 0 ]]; then
            echo "⚠️  DEGRADED (non-critical components missing)"
        else
            echo "❌ NOT PROTECTED"
        fi
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        for failure in "${validation_failures[@]}"; do
            echo "  ❌ $failure"
        done
        echo ""
        echo "  Run 'nftban health check --auto-heal' to attempt repair"

        # Return failure only for critical issues
        if [[ $critical_failures -gt 0 ]]; then
            return 1
        fi
        return 0
    fi
}

# Disable all NFTBan services (emergency mode)
# Usage: nftban_disable_all [--flush-rules]
# Options:
#   --flush-rules   Also flush nft tables (remove all firewall rules)
#                   Without this flag, nft rules remain active in kernel
nftban_disable_all() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: PolicyKit/polkit authorization failed or insufficient privileges (disable services)" >&2
        return 1
    fi

    # v1.38.0: Parse --flush-rules flag
    local flush_rules=false
    for arg in "$@"; do
        case "$arg" in
            --flush-rules) flush_rules=true ;;
        esac
    done

    echo "EMERGENCY: Disabling all NFTBan services..."

    # Stop all timers first (before stopping services that depend on them)
    echo "  Stopping timers..."
    local all_timers
    all_timers=$(systemctl list-unit-files 'nftban-*.timer' --no-legend 2>/dev/null | awk '{print $1}' || true)
    for timer in $all_timers; do
        systemctl stop "$timer" 2>/dev/null || true
        systemctl disable "$timer" 2>/dev/null || true
    done

    # Stop and disable systemd services (names from central config)
    local svc_daemon="${NFTBAN_SERVICE_DAEMON:-nftband.service}"
    local svc_login="${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service}"
    local svc_metrics="${NFTBAN_SERVICE_METRICS_EXPORTER:-nftban-unified-exporter.service}"
    local services=("${svc_login}" "${svc_metrics}" "${svc_daemon}" "suricata.service" "nftables.service")

    for svc in "${services[@]}"; do
        if systemctl list-unit-files "${svc}" &>/dev/null 2>&1; then
            echo "  Stopping ${svc%.service}..."
            systemctl stop "${svc}" 2>/dev/null || true
            systemctl disable "${svc}" 2>/dev/null || true
        fi
    done

    # v1.38.0: Flush nft tables if --flush-rules is set
    if [[ "$flush_rules" == "true" ]]; then
        echo "  Flushing nftables rules..."
        if command -v nft >/dev/null 2>&1; then
            nft flush table ip nftban 2>/dev/null || true
            nft flush table ip6 nftban 2>/dev/null || true
            echo "  NFTBan firewall rules removed from kernel."
        fi
    fi

    # Set master switch to disabled
    _nftban_set_config "NFTBAN_ENABLED" "false"

    echo ""
    echo "All NFTBan services stopped and disabled."
    if [[ "$flush_rules" == "false" ]]; then
        echo ""
        echo "NOTE: Firewall rules remain active in kernel."
        echo "  To also remove rules: nftban disable --flush-rules"
        echo "  To delete tables:     nft delete table ip nftban; nft delete table ip6 nftban"
    fi
    echo ""
    echo "To re-enable:"
    echo "  nftban enable"

    return 0
}

# Clear systemd start-limit-hit state before starting a service.
# When a service crashes repeatedly, systemd stops retrying and marks
# it as failed with 'start-limit-hit'. A subsequent 'systemctl start'
# will fail silently. This function clears that state first.
# Usage: nftban_service_clear_failed "nftband.service"
nftban_service_clear_failed() {
    local unit="$1"
    local state
    state=$(systemctl show -p ActiveState --value "$unit" 2>/dev/null) || return 0
    if [[ "$state" == "failed" ]]; then
        systemctl reset-failed "$unit" 2>/dev/null || true
    fi
}

# Safe daemon restart: clear start-limit-hit then restart.
# This is the ONLY correct way to restart nftband after a crash loop.
# Usage: nftban_daemon_restart
nftban_daemon_restart() {
    nftban_service_clear_failed "nftband.service"
    nftban_service_clear_failed "nftband.socket"
    systemctl restart nftband.service
}

# Safe daemon start: clear start-limit-hit then start.
# Usage: nftban_daemon_start
nftban_daemon_start() {
    nftban_service_clear_failed "nftband.service"
    nftban_service_clear_failed "nftband.socket"
    systemctl start nftband.service
}

# Start a specific service if enabled
# Usage: nftban_service_start "suricata"
nftban_service_start() {
    local service="$1"

    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: PolicyKit/polkit authorization failed or insufficient privileges (start services)" >&2
        return 1
    fi

    # Check if enabled first
    if ! nftban_service_is_enabled "$service"; then
        echo "Service '$service' is disabled in configuration" >&2
        return 1
    fi

    case "$service" in
        nftables)
            systemctl start nftables.service
            ;;
        suricata)
            systemctl start suricata.service
            ;;
        login|login_monitor)
            # v1.48.0: Login monitoring handled by nftband daemon loginmon module
            echo "Login monitoring is part of the nftband daemon (loginmon module)"
            echo "Starting nftband daemon..."
            nftban_daemon_start
            ;;
        nftban|nftband)
            nftban_daemon_start
            ;;
        *)
            echo "Unknown service: $service" >&2
            return 1
            ;;
    esac
}

# Stop a specific service
# Usage: nftban_service_stop "suricata"
nftban_service_stop() {
    local service="$1"

    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: PolicyKit/polkit authorization failed or insufficient privileges (stop services)" >&2
        return 1
    fi

    case "$service" in
        nftables)
            systemctl stop nftables.service
            ;;
        suricata)
            systemctl stop suricata.service
            ;;
        login|login_monitor)
            # v1.48.0: Login monitoring handled by nftband daemon; stopping daemon stops all modules
            echo "Login monitoring is part of the nftband daemon"
            echo "To stop login monitoring, disable it: nftban login disable"
            ;;
        nftban|nftband)
            systemctl stop nftband.service
            ;;
        *)
            echo "Unknown service: $service" >&2
            return 1
            ;;
    esac
}

# =============================================================================
# STATUS FUNCTIONS
# =============================================================================

# Get status of all services
# Usage: nftban_services_status [--json]
nftban_services_status() {
    local json_mode="${1:-}"
    _nftban_load_services_config

    if [[ "$json_mode" == "--json" ]]; then
        _nftban_services_status_json
        return
    fi

    echo "NFTBan Service Status"
    echo "====================="
    echo ""

    # Master switch
    if nftban_is_enabled; then
        echo "Master Switch: ENABLED"
    else
        echo "Master Switch: DISABLED"
        if grep -q 'nftban=disabled' /proc/cmdline 2>/dev/null; then
            echo "  (Disabled via kernel parameter)"
        fi
    fi
    echo ""

    # Individual services
    echo "Services:"

    # NFTables
    local nft_enabled="disabled"
    nftban_service_is_enabled "nftables" && nft_enabled="enabled"
    local nft_status
    nft_status=$(systemctl is-active nftables.service 2>/dev/null || echo "inactive")
    echo "  nftables:  config=$nft_enabled, systemd=$nft_status"

    # Suricata
    if command -v suricata &>/dev/null; then
        local suri_enabled="disabled"
        nftban_service_is_enabled "suricata" && suri_enabled="enabled"
        local suri_status
        suri_status=$(systemctl is-active suricata.service 2>/dev/null || echo "inactive")
        echo "  suricata:  config=$suri_enabled, systemd=$suri_status"
    else
        echo "  suricata:  not installed"
    fi

    # Login Monitor
    local login_enabled="disabled"
    nftban_service_is_enabled "login" && login_enabled="enabled"
    local login_status
    local login_svc="${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service}"
    login_status=$(systemctl is-active "$login_svc" 2>/dev/null || echo "inactive")
    echo "  login:     config=$login_enabled, systemd=$login_status"

    echo ""
}

_nftban_services_status_json() {
    local master_enabled="false"
    nftban_is_enabled && master_enabled="true"

    local nft_config="false"
    nftban_service_is_enabled "nftables" && nft_config="true"
    local nft_status
    nft_status=$(systemctl is-active nftables.service 2>/dev/null || echo "inactive")

    local suri_config="false"
    nftban_service_is_enabled "suricata" && suri_config="true"
    local suri_status
    suri_status=$(systemctl is-active suricata.service 2>/dev/null || echo "inactive")

    local login_config="false"
    nftban_service_is_enabled "login" && login_config="true"
    local login_status
    local login_svc="${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service}"
    login_status=$(systemctl is-active "$login_svc" 2>/dev/null || echo "inactive")

    cat <<EOF
{
  "master_enabled": $master_enabled,
  "services": {
    "nftables": {"config_enabled": $nft_config, "status": "$nft_status"},
    "suricata": {"config_enabled": $suri_config, "status": "$suri_status"},
    "login_monitor": {"config_enabled": $login_config, "status": "$login_status"}
  }
}
EOF
}

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Set a config value in the local override file
_nftban_set_config() {
    local key="$1"
    local value="$2"
    local file="${NFTBAN_SERVICES_LOCAL}"

    # Create local file if doesn't exist
    if [[ ! -f "$file" ]]; then
        mkdir -p "$(dirname "$file")" || return 1
        cat > "$file" <<'EOF'
# NFTBan Services - Local Overrides
# This file overrides settings from services.conf
EOF
        chmod 640 "$file"
        chown root:nftban "$file" 2>/dev/null || true
    fi

    # Update or add the key
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$file"
    else
        echo "${key}=\"${value}\"" >> "$file"
    fi
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_is_enabled
export -f nftban_check_enabled
export -f nftban_service_is_enabled
export -f nftban_service_auto_start
export -f nftban_enable_all
export -f nftban_disable_all
export -f nftban_service_clear_failed
export -f nftban_daemon_restart
export -f nftban_daemon_start
export -f nftban_service_start
export -f nftban_service_stop
export -f nftban_services_status

# =============================================================================
# LICENSE
# =============================================================================
# Mozilla Public License 2.0 (MPL-2.0)
# Copyright (c) 2024-2026 Antonios Voulvoulis
# Contact: contact@nftban.com | Website: https://nftban.com
# =============================================================================
