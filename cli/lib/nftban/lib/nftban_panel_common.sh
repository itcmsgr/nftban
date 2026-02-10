#!/usr/bin/env bash

# =============================================================================
# NFTBan v1.0.0 - Panel Common Library
# =============================================================================
#
# SPDX-License-Identifier: MPL-2.0
# Purpose: Common helper functions for web hosting panel integrations
#
# meta:name="nftban_panel_common"
# meta:type="library"
# meta:header="Panel Common Library"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# **Description & Purpose**
# meta:description="Shared utility functions for panel firewall management"
# meta:input="Port numbers, panel names, panel metadata fields"
# meta:output="Port status, panel info, configuration status"
#
# **Inventory & Requirements**
# meta:inventory.files=""
# meta:inventory.binaries="nft ss"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR"
# meta:inventory.config_files="/etc/nftban/conf.d/panels/*/main.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================

set -Eeuo pipefail

# Prevent double-sourcing
[[ -n "${_NFTBAN_PANEL_COMMON_LOADED:-}" ]] && return 0
readonly _NFTBAN_PANEL_COMMON_LOADED=1

# =============================================================================
# ADMIN EMAIL DETECTION
# =============================================================================

# Get admin email from detected panel
# Usage: nftban_panel_get_admin_email
# Returns: Admin email on stdout, or empty if not found
# Exit: 0 if found, 1 if not found
nftban_panel_get_admin_email() {
    local email=""

    # DirectAdmin
    if [[ -f /usr/local/directadmin/data/users/admin/user.conf ]]; then
        email=$(grep '^email=' /usr/local/directadmin/data/users/admin/user.conf 2>/dev/null | cut -d= -f2)
        if [[ -n "$email" ]]; then
            echo "$email"
            return 0
        fi
    fi

    # cPanel/WHM
    if [[ -d /usr/local/cpanel ]]; then
        # Try .contactemail first
        if [[ -f /root/.contactemail ]]; then
            email=$(cat /root/.contactemail 2>/dev/null | tr -d '[:space:]')
        fi
        # Try wwwacct.conf
        if [[ -z "$email" && -f /etc/wwwacct.conf ]]; then
            email=$(grep '^CONTACTEMAIL' /etc/wwwacct.conf 2>/dev/null | awk '{print $2}')
        fi
        # Try whmapi1
        if [[ -z "$email" ]] && command -v whmapi1 &>/dev/null; then
            email=$(whmapi1 get_tweaksetting key=contact_email 2>/dev/null | grep 'value:' | awk '{print $2}')
        fi
        if [[ -n "$email" ]]; then
            echo "$email"
            return 0
        fi
    fi

    # Plesk
    if [[ -d /usr/local/psa ]]; then
        # Try plesk bin admin --info
        if command -v plesk &>/dev/null; then
            email=$(plesk bin admin --info 2>/dev/null | grep -i '^email:' | awk '{print $2}')
        fi
        # Try database query
        if [[ -z "$email" ]] && command -v plesk &>/dev/null; then
            email=$(plesk db -Ne "SELECT val FROM misc WHERE param='admin_email'" 2>/dev/null)
        fi
        if [[ -n "$email" ]]; then
            echo "$email"
            return 0
        fi
    fi

    # CyberPanel
    if [[ -d /usr/local/CyberCP ]]; then
        if [[ -f /usr/local/CyberCP/serverStatus/serverStatusData.json ]]; then
            email=$(grep -o '"adminEmail":"[^"]*"' /usr/local/CyberCP/serverStatus/serverStatusData.json 2>/dev/null | cut -d'"' -f4)
            if [[ -n "$email" ]]; then
                echo "$email"
                return 0
            fi
        fi
    fi

    # VestaCP / HestiaCP
    if [[ -d /usr/local/vesta ]] || [[ -d /usr/local/hestia ]]; then
        local vesta_path="/usr/local/vesta"
        [[ -d /usr/local/hestia ]] && vesta_path="/usr/local/hestia"
        if [[ -f "$vesta_path/data/users/admin/user.conf" ]]; then
            email=$(grep '^CONTACT=' "$vesta_path/data/users/admin/user.conf" 2>/dev/null | cut -d"'" -f2)
            if [[ -n "$email" ]]; then
                echo "$email"
                return 0
            fi
        fi
    fi

    # Fallback: check /etc/aliases for root
    if [[ -f /etc/aliases ]]; then
        email=$(grep '^root:' /etc/aliases 2>/dev/null | awk -F: '{print $2}' | tr -d '[:space:]' | grep '@')
        if [[ -n "$email" ]]; then
            echo "$email"
            return 0
        fi
    fi

    return 1
}

# Detect which panel is installed
# Usage: nftban_panel_detect
# Returns: Panel name on stdout (directadmin, cpanel, plesk, cyberpanel, vesta, hestia, cwp, interworx, none)
nftban_panel_detect() {
    if [[ -d /usr/local/directadmin ]]; then
        echo "directadmin"
    elif [[ -d /usr/local/cpanel ]]; then
        echo "cpanel"
    elif [[ -d /usr/local/psa ]]; then
        echo "plesk"
    elif [[ -d /usr/local/CyberCP ]]; then
        echo "cyberpanel"
    elif [[ -d /usr/local/hestia ]]; then
        echo "hestia"
    elif [[ -d /usr/local/vesta ]]; then
        echo "vesta"
    elif [[ -d /usr/local/cwpsrv ]]; then
        echo "cwp"
    elif [[ -d /usr/local/interworx ]]; then
        echo "interworx"
    else
        echo "none"
    fi
}

# =============================================================================
# PORT CHECK HELPER
# =============================================================================

# Check if a port is open in nftables
# Usage: _nftban_panel_check_port <port>
# Returns: 0 if port is open, 1 if closed
#
# Checks tcp_ports and udp_ports sets in nftables.
# Architecture: NFTBan uses separate ip/ip6 tables (not inet).
# Port sets are: "ip nftban tcp_ports" and "ip nftban udp_ports"
_nftban_panel_check_port() {
    local port="$1"
    local output

    # Check tcp_ports set in ip nftban table (primary architecture)
    output=$(nft list set ip nftban tcp_ports 2>/dev/null) || true
    if [[ -n "$output" ]]; then
        # Match port as standalone number or in a list (e.g., "22, 80, 443" or "elements = { 22 }")
        # Port can appear as: standalone, comma-separated, or with spaces
        if echo "$output" | grep -qE "(^|[^0-9])${port}([^0-9]|$)"; then
            return 0
        fi
    fi

    # Check udp_ports set in ip nftban table
    output=$(nft list set ip nftban udp_ports 2>/dev/null) || true
    if [[ -n "$output" ]]; then
        if echo "$output" | grep -qE "(^|[^0-9])${port}([^0-9]|$)"; then
            return 0
        fi
    fi

    # Fallback: Check legacy inet nftban table (for older installations)
    output=$(nft list set inet nftban tcp_ports 2>/dev/null) || true
    if [[ -n "$output" ]]; then
        if echo "$output" | grep -qE "(^|[^0-9])${port}([^0-9]|$)"; then
            return 0
        fi
    fi

    output=$(nft list set inet nftban udp_ports 2>/dev/null) || true
    if [[ -n "$output" ]]; then
        if echo "$output" | grep -qE "(^|[^0-9])${port}([^0-9]|$)"; then
            return 0
        fi
    fi

    return 1
}

# =============================================================================
# CLOUDFLARE CHECK HELPER
# =============================================================================

# Check if CloudFlare is enabled (via trust command)
# Usage: _nftban_panel_check_cloudflare
# Returns: 0 if enabled, 1 if disabled
_nftban_panel_check_cloudflare() {
    # Check if CLOUDFLARE is enabled in trust feeds
    # First try new trust command, fallback to legacy cloudflare command
    local status_output
    status_output=$(nftban-core trust list 2>/dev/null) || true
    if echo "$status_output" | grep -q 'CLOUDFLARE.*enabled'; then
        return 0
    fi
    # Fallback: check legacy cloudflare command
    status_output=$(nftban cloudflare status 2>/dev/null) || true
    echo "$status_output" | grep -q 'Master switch: true'
}

# =============================================================================
# PANEL METADATA HELPER
# =============================================================================

# Get panel information
# Usage: _get_panel_info <panel> <field>
# Fields: name, path, ports, var
_get_panel_info() {
    local panel="$1"
    local field="$2"

    case "${panel}_${field}" in
        # DirectAdmin (dedicated module)
        directadmin_name)  echo "DirectAdmin" ;;
        directadmin_path)  echo "/usr/local/directadmin" ;;
        directadmin_ports) echo "2222" ;;
        directadmin_var)   echo "DIRECTADMIN" ;;
        # cPanel/WHM (dedicated module)
        cpanel_name)       echo "cPanel/WHM" ;;
        cpanel_path)       echo "/usr/local/cpanel" ;;
        cpanel_ports)      echo "2082,2083,2086,2087" ;;
        cpanel_var)        echo "CPANEL" ;;
        # Plesk (dedicated module)
        plesk_name)        echo "Plesk" ;;
        plesk_path)        echo "/usr/local/psa" ;;
        plesk_ports)       echo "8443,8447,8880" ;;
        plesk_var)         echo "PLESK" ;;
        # CWP (generic functions)
        cwp_name)          echo "CentOS Web Panel (CWP)" ;;
        cwp_path)          echo "/usr/local/cwpsrv" ;;
        cwp_ports)         echo "2030,2031" ;;
        cwp_var)           echo "CWP" ;;
        # CyberPanel (generic functions)
        cyberpanel_name)   echo "CyberPanel" ;;
        cyberpanel_path)   echo "/usr/local/CyberCP" ;;
        cyberpanel_ports)  echo "7080,8090" ;;
        cyberpanel_var)    echo "CYBERPANEL" ;;
        # InterWorx (generic functions)
        interworx_name)    echo "InterWorx" ;;
        interworx_path)    echo "/usr/local/interworx" ;;
        interworx_ports)   echo "2080,2443" ;;
        interworx_var)     echo "INTERWORX" ;;
        # VestaCP/HestiaCP (generic functions)
        vesta_name)        echo "VestaCP / HestiaCP" ;;
        vesta_path)        echo "/usr/local/vesta" ;;
        vesta_ports)       echo "8083" ;;
        vesta_var)         echo "VESTA" ;;
        # Generic server (reference config)
        generic_name)      echo "Generic Server" ;;
        generic_path)      echo "" ;;
        generic_ports)     echo "" ;;
        generic_var)       echo "GENERIC" ;;
        *)                 echo "" ;;
    esac
}

# =============================================================================
# SIMPLE PANEL HELP
# =============================================================================

# Simple help for basic panels
nftban_panel_simple_help() {
    local panel="$1"
    local name
    local ports
    name=$(_get_panel_info "$panel" "name")
    ports=$(_get_panel_info "$panel" "ports")

    cat <<EOF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
NFTBan ${name} Integration
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Usage:
  nftban panel ${panel} <action>

Actions:
  enable    - Enable ${name} ports in firewall
  disable   - Disable ${name} ports in firewall
  status    - Show ${name} port configuration status

Panel Ports: ${ports}

Examples:
  nftban panel ${panel} enable       # Enable ports
  nftban panel ${panel} disable      # Disable ports
  nftban panel ${panel} status       # Check status

Note: SSH port is handled separately and not included in panel configuration.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
}

# =============================================================================
# SIMPLE PANEL ENABLE
# =============================================================================

# Generic enable function for simple panels
_nftban_panel_simple_enable() {
    local panel="$1"
    local name var config_file
    name=$(_get_panel_info "$panel" "name")
    var=$(_get_panel_info "$panel" "var")
    config_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/panels/${panel}/main.conf"

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "${name} - Enable Firewall Rules"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Load configuration
    if [[ -f "$config_file" ]]; then
        # shellcheck source=/dev/null
        source "$config_file"
        echo "Loaded configuration from: $config_file"
        echo ""

        # Get port variables dynamically
        local tcp_in_var="NFTBAN_${var}_TCP_IN"
        local udp_in_var="NFTBAN_${var}_UDP_IN"

        echo "Port Configuration (applies to both IPv4 and IPv6):"
        echo "  TCP IN:  ${!tcp_in_var:-Not configured}"
        echo "  UDP IN:  ${!udp_in_var:-Not configured}"
        echo ""
    else
        echo "ERROR: Config file not found: $config_file" >&2
        echo "  Please reinstall nftban package." >&2
        return 1
    fi

    # Mark panel as enabled in state file
    echo "Enabling ${name} in NFTBan..."
    local state_dir="/var/lib/nftban/panels"
    local state_file="$state_dir/enabled.conf"

    # Ensure state directory exists
    if [[ ! -d "$state_dir" ]]; then
        mkdir -p "$state_dir" 2>/dev/null || {
            echo "ERROR: Failed to create state directory: $state_dir" >&2
            return 1
        }
    fi

    # Read existing state and update
    local temp_file
    temp_file=$(mktemp)
    {
        echo "# NFTBan Panel State Configuration"
        echo "# Format: panelname=enabled|disabled"
        echo "# This file is automatically managed by 'nftban panel' commands"
        echo ""
        # Preserve other panels, update this one
        if [[ -f "$state_file" ]]; then
            grep -v "^${panel}=" "$state_file" 2>/dev/null | grep -v "^#" | grep -v "^$" || true
        fi
        echo "${panel}=enabled"
    } > "$temp_file"
    mv "$temp_file" "$state_file"

    echo "  ${name} marked as enabled"
    echo ""

    # Trigger sync
    echo "Loading ${name} ports into firewall..."
    echo ""

    if nftban-core sync; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "${name} enabled successfully!"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "Panel ports are now active and will persist across reboots."
        echo ""
        echo "Check status: nftban panel ${panel} status"
        echo ""
        return 0
    else
        echo ""
        echo "ERROR: Failed to sync firewall configuration" >&2
        echo "Try running: nftban-core sync" >&2
        return 1
    fi
}

# =============================================================================
# SIMPLE PANEL DISABLE
# =============================================================================

# Generic disable function for simple panels
_nftban_panel_simple_disable() {
    local panel="$1"
    local name
    name=$(_get_panel_info "$panel" "name")

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "${name} - Disable Firewall Rules"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "WARNING: This will remove ${name} port rules from firewall."
    echo ""
    read -p "Continue? (yes/no) [no]: " confirm
    confirm="${confirm:-no}"

    if [[ "$confirm" != "yes" && "$confirm" != "y" ]]; then
        echo "Aborted."
        return 0
    fi

    echo ""
    echo "Disabling ${name} in NFTBan..."

    # Update state file
    local state_dir="/var/lib/nftban/panels"
    local state_file="$state_dir/enabled.conf"

    if [[ ! -d "$state_dir" ]]; then
        mkdir -p "$state_dir" 2>/dev/null || {
            echo "ERROR: Failed to create state directory: $state_dir" >&2
            return 1
        }
    fi

    # Read existing state and update
    local temp_file
    temp_file=$(mktemp)
    {
        echo "# NFTBan Panel State Configuration"
        echo "# Format: panelname=enabled|disabled"
        echo "# This file is automatically managed by 'nftban panel' commands"
        echo ""
        if [[ -f "$state_file" ]]; then
            grep -v "^${panel}=" "$state_file" 2>/dev/null | grep -v "^#" | grep -v "^$" || true
        fi
        echo "${panel}=disabled"
    } > "$temp_file"
    mv "$temp_file" "$state_file"

    echo "  ${name} marked as disabled"
    echo ""

    # Trigger sync
    echo "Removing ${name} ports from firewall..."
    echo ""

    if nftban-core sync; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "${name} disabled successfully!"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        return 0
    else
        echo ""
        echo "ERROR: Failed to sync firewall configuration" >&2
        return 1
    fi
}

# =============================================================================
# SIMPLE PANEL STATUS
# =============================================================================

# Generic status function for simple panels
_nftban_panel_simple_status() {
    local panel="$1"
    local name path ports var config_file
    name=$(_get_panel_info "$panel" "name")
    path=$(_get_panel_info "$panel" "path")
    ports=$(_get_panel_info "$panel" "ports")
    var=$(_get_panel_info "$panel" "var")
    config_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/panels/${panel}/main.conf"

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "${name} Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Check installation
    if [[ -d "$path" ]]; then
        echo "Installation: DETECTED"
        echo "  Path: $path"
    else
        echo "Installation: NOT FOUND"
        echo "  Expected: $path"
    fi
    echo ""

    # Check panel enabled state
    local state_file="/var/lib/nftban/panels/enabled.conf"
    local enabled_state="unknown"
    if [[ -f "$state_file" ]]; then
        enabled_state=$(grep "^${panel}=" "$state_file" 2>/dev/null | cut -d= -f2 || echo "not set")
    fi
    echo "NFTBan State: ${enabled_state}"
    echo ""

    # Check panel ports
    echo "Panel Ports:"
    IFS=',' read -ra PORT_ARRAY <<< "$ports"
    for port in "${PORT_ARRAY[@]}"; do
        local listening="NO"
        local firewall="CLOSED"

        if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            listening="YES"
        fi

        if _nftban_panel_check_port "$port"; then
            firewall="OPEN"
        fi

        printf "  Port %-5s: Listening: %-3s | Firewall: %s\n" "$port" "$listening" "$firewall"
    done
    echo ""

    # Configuration file
    echo "Configuration:"
    if [[ -f "$config_file" ]]; then
        echo "  Config: $config_file"

        # Show configured ports
        # shellcheck source=/dev/null
        source "$config_file"
        local tcp_in_var="NFTBAN_${var}_TCP_IN"
        local udp_in_var="NFTBAN_${var}_UDP_IN"
        echo "  TCP IN: ${!tcp_in_var:-Not configured}"
        echo "  UDP IN: ${!udp_in_var:-Not configured}"
    else
        echo "  Config: NOT FOUND"
    fi
    echo ""
}

# =============================================================================
# CWP (CentOS Web Panel) Functions
# =============================================================================

nftban_panel_cwp_enable() {
    _nftban_panel_simple_enable "cwp"
}

nftban_panel_cwp_disable() {
    _nftban_panel_simple_disable "cwp"
}

nftban_panel_cwp_status() {
    _nftban_panel_simple_status "cwp"
}

# Stub functions for report/repair/test (not implemented for simple panels)
nftban_panel_cwp_report() {
    nftban_panel_cwp_status
}

nftban_panel_cwp_repair() {
    echo "Repair: Run 'nftban panel cwp enable' to fix configuration."
}

nftban_panel_cwp_test() {
    nftban_panel_cwp_status
}

# =============================================================================
# CyberPanel Functions
# =============================================================================

nftban_panel_cyberpanel_enable() {
    _nftban_panel_simple_enable "cyberpanel"
}

nftban_panel_cyberpanel_disable() {
    _nftban_panel_simple_disable "cyberpanel"
}

nftban_panel_cyberpanel_status() {
    _nftban_panel_simple_status "cyberpanel"
}

nftban_panel_cyberpanel_report() {
    nftban_panel_cyberpanel_status
}

nftban_panel_cyberpanel_repair() {
    echo "Repair: Run 'nftban panel cyberpanel enable' to fix configuration."
}

nftban_panel_cyberpanel_test() {
    nftban_panel_cyberpanel_status
}

# =============================================================================
# InterWorx Functions
# =============================================================================

nftban_panel_interworx_enable() {
    _nftban_panel_simple_enable "interworx"
}

nftban_panel_interworx_disable() {
    _nftban_panel_simple_disable "interworx"
}

nftban_panel_interworx_status() {
    _nftban_panel_simple_status "interworx"
}

nftban_panel_interworx_report() {
    nftban_panel_interworx_status
}

nftban_panel_interworx_repair() {
    echo "Repair: Run 'nftban panel interworx enable' to fix configuration."
}

nftban_panel_interworx_test() {
    nftban_panel_interworx_status
}

# =============================================================================
# VestaCP / HestiaCP Functions
# =============================================================================

nftban_panel_vesta_enable() {
    _nftban_panel_simple_enable "vesta"
}

nftban_panel_vesta_disable() {
    _nftban_panel_simple_disable "vesta"
}

nftban_panel_vesta_status() {
    _nftban_panel_simple_status "vesta"
}

nftban_panel_vesta_report() {
    nftban_panel_vesta_status
}

nftban_panel_vesta_repair() {
    echo "Repair: Run 'nftban panel vesta enable' to fix configuration."
}

nftban_panel_vesta_test() {
    nftban_panel_vesta_status
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================

export -f nftban_panel_get_admin_email
export -f nftban_panel_detect
export -f _nftban_panel_check_port
export -f _nftban_panel_check_cloudflare
export -f _get_panel_info
export -f nftban_panel_simple_help
export -f _nftban_panel_simple_enable
export -f _nftban_panel_simple_disable
export -f _nftban_panel_simple_status
export -f nftban_panel_cwp_enable
export -f nftban_panel_cwp_disable
export -f nftban_panel_cwp_status
export -f nftban_panel_cwp_report
export -f nftban_panel_cwp_repair
export -f nftban_panel_cwp_test
export -f nftban_panel_cyberpanel_enable
export -f nftban_panel_cyberpanel_disable
export -f nftban_panel_cyberpanel_status
export -f nftban_panel_cyberpanel_report
export -f nftban_panel_cyberpanel_repair
export -f nftban_panel_cyberpanel_test
export -f nftban_panel_interworx_enable
export -f nftban_panel_interworx_disable
export -f nftban_panel_interworx_status
export -f nftban_panel_interworx_report
export -f nftban_panel_interworx_repair
export -f nftban_panel_interworx_test
export -f nftban_panel_vesta_enable
export -f nftban_panel_vesta_disable
export -f nftban_panel_vesta_status
export -f nftban_panel_vesta_report
export -f nftban_panel_vesta_repair
export -f nftban_panel_vesta_test
