#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="service_control" meta:type="lib" meta:version="1.0.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Centralized service control for enable/disable NFTBan and subsystems"
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
        source "$NFTBAN_SERVICES_CONF"
    fi

    # Load local overrides
    if [[ -f "$NFTBAN_SERVICES_LOCAL" ]]; then
        # shellcheck source=/dev/null
        source "$NFTBAN_SERVICES_LOCAL"
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
                source "$login_conf"
                enabled="${NFTBAN_LOGIN_ALERT_ENABLED:-true}"
            fi
            if [[ -f "$login_local" ]]; then
                # shellcheck source=/dev/null
                source "$login_local"
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
            mkdir -p "$backup_dir"
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
            mkdir -p "$backup_dir"
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
            mkdir -p "$backup_dir"
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

# Enable all NFTBan services
# Usage: nftban_enable_all
nftban_enable_all() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: Must be root to enable services" >&2
        return 1
    fi

    # Check and resolve firewall conflicts first
    nftban_resolve_firewall_conflicts

    echo ""
    echo "Enabling all NFTBan services..."

    # Set master switch
    _nftban_set_config "NFTBAN_ENABLED" "true"

    # Enable systemd services
    local services=("nftables")

    # Add suricata if installed
    if command -v suricata &>/dev/null; then
        services+=("suricata")
    fi

    for svc in "${services[@]}"; do
        if systemctl list-unit-files "${svc}.service" &>/dev/null; then
            echo "  Enabling ${svc}..."
            systemctl enable "${svc}.service" 2>/dev/null || true
            systemctl start "${svc}.service" 2>/dev/null || true
        fi
    done

    # Initialize nftban firewall tables if not present
    if ! nft list table ip nftban &>/dev/null 2>&1; then
        echo "  Initializing nftban firewall..."
        if command -v nftban &>/dev/null; then
            nftban firewall init 2>/dev/null || echo "  Warning: firewall init failed"
        fi
    fi

    # EMERGENCY: Auto-whitelist system IPs to prevent lockout
    # This adds server's own IPs directly to nftables as safety measure
    # Even if Go daemon fails, server won't lock itself out
    echo "  Auto-detecting system IPs (lockout prevention)..."
    if command -v nftban &>/dev/null; then
        nftban whitelist-system sync 2>/dev/null || echo "  Warning: whitelist-system sync failed"
    fi

    # Primary sync via Go daemon (handles full whitelist/blacklist sync)
    if command -v nftban-core &>/dev/null; then
        echo "  Syncing via daemon..."
        nftban-core sync 2>/dev/null || true
    fi

    echo "All services enabled"
    return 0
}

# Disable all NFTBan services (emergency mode)
# Usage: nftban_disable_all
nftban_disable_all() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: Must be root to disable services" >&2
        return 1
    fi

    echo "EMERGENCY: Disabling all NFTBan services..."

    # Stop and disable systemd services
    local login_svc="${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service}"
    local metrics_svc="${NFTBAN_SERVICE_METRICS_EXPORTER:-nftban-unified-exporter.service}"
    local services=("${login_svc%.service}" "${metrics_svc%.service}" "nftban" "suricata")

    for svc in "${services[@]}"; do
        if systemctl list-unit-files "${svc}.service" &>/dev/null 2>&1; then
            echo "  Stopping ${svc}..."
            systemctl stop "${svc}.service" 2>/dev/null || true
            systemctl disable "${svc}.service" 2>/dev/null || true
        fi
    done

    # Set master switch to disabled
    _nftban_set_config "NFTBAN_ENABLED" "false"

    echo ""
    echo "All NFTBan services stopped and disabled."
    echo ""
    echo "To re-enable:"
    echo "  nftban enable"
    echo ""
    echo "Note: nftables service left running for manual firewall management"

    return 0
}

# Start a specific service if enabled
# Usage: nftban_service_start "suricata"
nftban_service_start() {
    local service="$1"

    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: Must be root to start services" >&2
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
            systemctl start "${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service}"
            ;;
        nftban|nftband)
            systemctl start nftband.service
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
        echo "ERROR: Must be root to stop services" >&2
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
            systemctl stop "${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service}"
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
        mkdir -p "$(dirname "$file")"
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
export -f nftban_service_start
export -f nftban_service_stop
export -f nftban_services_status

# =============================================================================
# LICENSE
# =============================================================================
# Mozilla Public License 2.0 (MPL-2.0)
# Copyright (c) 2024-2026 NFTBAN Project / Antonios Voulvoulis
# Contact: contact@nftban.com | Website: https://nftban.com
# =============================================================================
