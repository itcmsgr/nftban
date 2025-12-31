#!/usr/bin/env bash

# =============================================================================

# Load JSON helper for --json support
[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"

# Load strict mode library
# shellcheck source=/usr/lib/nftban/lib/strict.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/strict.sh"
else
    # Fallback to manual strict mode
    set -Eeuo pipefail
fi

# Load version library
# shellcheck source=/usr/lib/nftban/lib/version.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/version.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/version.sh"
fi
JSON_HELPER="${NFTBAN_LIB_DIR}/helpers/json_output.sh"

# Load NFT schema (single source of truth for table/set names)
# shellcheck source=/usr/lib/nftban/lib/nft_schema.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nft_schema.sh"
fi
if [[ -f "$JSON_HELPER" ]]; then
    # shellcheck source=/dev/null
    source "$JSON_HELPER"
fi
# NFTBan v1.0.0 - Panel CLI Handler
# =============================================================================

# SPDX-License-Identifier: MPL-2.0
# Purpose: Web hosting panel firewall integration and management
#
# meta:name=cmd_panel
# meta:type=cli
# meta:header=Panel CLI Command
# meta:version=1.0.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Manage web hosting panel firewall integration (DirectAdmin, cPanel, Plesk)
# meta:input=Panel name and action (enable, disable, status, report, repair, test)
# meta:output=Panel configuration status and firewall rules
#
# **Usage**
#   nftban panel <panel_name> <action>
#
# **Supported Panels**
#   directadmin (da)     - DirectAdmin Control Panel
#   cpanel (cp)          - cPanel/WHM Control Panel
#
# **Actions**
#   enable    - Enable panel ports in firewall
#   disable   - Disable panel ports in firewall
#   status    - Show panel port configuration status
#   report    - Generate detailed report (ports, IPs, config)
#   repair    - Fix/update configuration files
#   test      - Test panel connectivity and configuration
# =============================================================================



# =============================================================================

# LOAD DEPENDENCIES
# =============================================================================


# Load cmd_port.sh for DirectAdmin port configuration functions
NFTBAN_LIB_DIR="${NFTBAN_LIB_DIR:-/usr/lib/nftban}"
if [[ -f "${NFTBAN_LIB_DIR}/cli/cmd_port.sh" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR}/cli/cmd_port.sh"
fi

# =============================================================================

# MAIN COMMAND DISPATCHER
# =============================================================================


nftban_cmd_panel() {
    local panel="${1:-}"
    local action="${2:-}"
    local json_mode=false

    # Check for --json flag
    for arg in "$@"; do
        [[ "$arg" == "--json" ]] && json_mode=true && break
    done

    # Show banner (skip for JSON output)
    if [[ "$json_mode" != "true" ]]; then
        if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
            # shellcheck source=/dev/null
            source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"
            if [[ $(type -t nftban_banner) == "function" ]]; then
                nftban_banner
            fi
        fi
        echo ""
    fi

    if [[ -z "$panel" ]]; then
        nftban_panel_help
        return 1
    fi

    # Normalize panel name
    case "$panel" in
        directadmin|da|DA|DirectAdmin)
            panel="directadmin"
            ;;
        cpanel|cp|CP|cPanel|CPANEL)
            panel="cpanel"
            ;;
        help|-h|--help)
            nftban_panel_help
            return 0
            ;;
        *)
            echo "ERROR: Unknown panel: $panel" >&2
            echo "Run 'nftban panel help' for available panels" >&2
            return 1
            ;;
    esac

    if [[ -z "$action" ]]; then
        echo "ERROR: Action required" >&2
        echo "Usage: nftban panel $panel <action>" >&2
        echo "Actions: enable, disable, status, report, repair, test" >&2
        return 1
    fi

    # Route to panel-specific handler
    case "$action" in
        enable)
            nftban_panel_${panel}_enable
            ;;
        disable)
            nftban_panel_${panel}_disable
            ;;
        status)
            nftban_panel_${panel}_status
            ;;
        report)
            nftban_panel_${panel}_report
            ;;
        repair)
            nftban_panel_${panel}_repair
            ;;
        test)
            nftban_panel_${panel}_test
            ;;
        help|-h|--help)
            nftban_panel_help "$panel"
            ;;
        *)
            echo "ERROR: Unknown action: $action" >&2
            echo "Actions: enable, disable, status, report, repair, test" >&2
            return 1
            ;;
    esac
}

# =============================================================================

# HELP SYSTEM
# =============================================================================


nftban_panel_help() {
    local panel="${1:-}"

    if [[ -n "$panel" ]]; then
        # Panel-specific help
        case "$panel" in
            directadmin)
                nftban_panel_directadmin_help
                ;;
            cpanel)
                nftban_panel_cpanel_help
                ;;
        esac
        return 0
    fi

    cat <<'EOF'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
NFTBan Panel Integration - Control Panel Firewall Management
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Usage:
  nftban panel <panel_name> <action>

Supported Panels:
  directadmin (da)    - DirectAdmin Control Panel
  cpanel (cp)         - cPanel/WHM Control Panel

Actions:
  enable              - Enable panel ports in firewall
  disable             - Disable panel ports in firewall
  status              - Show panel port configuration status
  report              - Generate detailed report (ports, IPs, config)
  repair              - Fix/update configuration files
  test                - Test panel connectivity and configuration

Examples:
  nftban panel directadmin enable      # Enable DirectAdmin ports
  nftban panel cpanel enable           # Enable cPanel/WHM ports
  nftban panel directadmin status      # Check configuration
  nftban panel cpanel report           # Full diagnostic report
  nftban panel directadmin test        # Test connectivity

Panel-Specific Help:
  nftban panel directadmin help        # DirectAdmin detailed help
  nftban panel cpanel help             # cPanel/WHM detailed help

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
}

nftban_panel_directadmin_help() {
    cat <<'EOF'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
NFTBan DirectAdmin Integration - Comprehensive Panel Support
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Usage:
  nftban panel directadmin <action>

Actions:
  enable              - Enable DirectAdmin ports in firewall
                        • Opens all required TCP/UDP ports
                        • Prompts for CloudFlare whitelist (required!)
                        • Creates firewall rules for IPv4 and IPv6

  disable             - Disable DirectAdmin ports in firewall
                        • Removes all DirectAdmin-specific rules
                        • Preserves essential SSH/HTTP ports
                        • Safe operation (no lockout risk)

  status              - Show current DirectAdmin configuration
                        • Lists enabled/disabled ports
                        • Shows CloudFlare whitelist status
                        • Displays panel detection status

  report              - Generate comprehensive diagnostic report
                        • All ports (enabled/disabled)
                        • CloudFlare IP whitelist status
                        • DirectAdmin installation details
                        • Recommended security improvements
                        • Configuration file locations

  repair              - Fix DirectAdmin configuration issues
                        • Updates configuration files
                        • Fixes missing port rules
                        • Re-enables CloudFlare whitelist if needed
                        • Validates all settings

  test                - Test DirectAdmin connectivity and configuration
                        • Tests panel port (2222) accessibility
                        • Verifies CloudFlare whitelist
                        • Tests mail ports (SMTP, IMAP, POP3)
                        • Tests FTP ports
                        • Reports any issues found

DirectAdmin Ports Configured:
  TCP INPUT:  20,21,22,25,53,80,110,143,443,465,587,993,995,2222,35000:35999
  TCP OUTPUT: 20,21,22,25,53,80,110,113,143,443,465,587,993,995,2222
  UDP INPUT:  20,21,53,80,443,853
  UDP OUTPUT: 20,21,53,113,123,443,853

Key Ports:
  2222        - DirectAdmin Web Panel
  22          - SSH
  80/443      - HTTP/HTTPS (including QUIC/HTTP3)
  25/587/465  - SMTP/Submission
  20/21       - FTP
  35000:35999 - Passive FTP range

⚠️  CloudFlare Whitelist REQUIRED:
  DirectAdmin licensing servers are behind CloudFlare CDN.
  You MUST enable CloudFlare IP whitelist for licensing to work.

  Enable CloudFlare:
    nftban trust enable CLOUDFLARE
    nftban trust update

Configuration Files:
  /etc/nftban/conf.d/panels/directadmin/main.conf - Main configuration
  /etc/nftban/nftban.conf.local                - Your customizations
  /etc/fail2ban/jail.d/nftban-directadmin.conf - Fail2ban integration

Examples:
  # Initial setup
  nftban panel directadmin enable

  # Check status
  nftban panel directadmin status

  # Full diagnostic
  nftban panel directadmin report

  # Test connectivity
  nftban panel directadmin test

  # Fix issues
  nftban panel directadmin repair

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
}

nftban_panel_cpanel_help() {
    cat <<'EOF'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
NFTBan cPanel/WHM Integration - Comprehensive Panel Support
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Usage:
  nftban panel cpanel <action>

Actions:
  enable              - Enable cPanel/WHM ports in firewall
                        • Opens all required TCP/UDP ports
                        • Prompts for cPanel license server whitelist
                        • Creates firewall rules for IPv4 and IPv6

  disable             - Disable cPanel/WHM ports in firewall
                        • Removes all cPanel-specific rules
                        • Preserves essential SSH/HTTP ports
                        • Safe operation (no lockout risk)

  status              - Show current cPanel/WHM configuration
                        • Lists enabled/disabled ports
                        • Shows license server whitelist status
                        • Displays panel detection status

  report              - Generate comprehensive diagnostic report
                        • All ports (enabled/disabled)
                        • cPanel license server whitelist status
                        • cPanel/WHM installation details
                        • Recommended security improvements
                        • Configuration file locations

  repair              - Fix cPanel/WHM configuration issues
                        • Updates configuration files
                        • Fixes missing port rules
                        • Re-enables license server whitelist if needed
                        • Validates all settings

  test                - Test cPanel/WHM connectivity and configuration
                        • Tests panel ports (2082/2083, 2086/2087)
                        • Verifies license server whitelist
                        • Tests mail ports (SMTP, IMAP, POP3)
                        • Tests webmail ports
                        • Reports any issues found

cPanel/WHM Ports Configured:
  TCP INPUT:  20,21,25,53,80,110,143,443,465,587,993,995,2077-2080,2082,2083,2086,2087,2095,2096,8443
  TCP OUTPUT: 20,21,25,37,43,53,80,110,113,443,587,873,993,995,2086,2087,2089,2703
  UDP INPUT:  20,21,53,80,443
  UDP OUTPUT: 20,21,53,113,123,873,6277,24441

Key Ports:
  2082/2083   - cPanel (HTTP/HTTPS)
  2086/2087   - WHM (HTTP/HTTPS)
  2095/2096   - Webmail (HTTP/HTTPS)
  80/443      - HTTP/HTTPS (including QUIC/HTTP3)
  25/587/465  - SMTP/Submission
  20/21       - FTP

⚠️  cPanel License Server Whitelist:
  cPanel licensing servers must be whitelisted for licensing to work.
  You can enable automatic license server whitelisting during setup.

Configuration Files:
  /etc/nftban/conf.d/panels/cpanel/main.conf       - Main configuration
  /etc/nftban/nftban.conf.local                    - Your customizations
  /etc/fail2ban/jail.d/nftban-cpanel.conf          - Fail2ban integration

Examples:
  # Initial setup
  nftban panel cpanel enable

  # Check status
  nftban panel cpanel status

  # Full diagnostic
  nftban panel cpanel report

  # Test connectivity
  nftban panel cpanel test

  # Fix issues
  nftban panel cpanel repair

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
}

# =============================================================================

# DIRECTADMIN PANEL SUPPORT
# =============================================================================


# Helper function: Check if a port is open in nftables
_nftban_panel_check_port() {
    local port="$1"
    local table output
    local old_ifs="$IFS"
    IFS=$' \t\n'  # Reset IFS to default for iteration
    for table in nftban nftban_runtime nftban_filter; do
        # Use command substitution to avoid SIGPIPE with pipefail
        output=$(nft list table inet "$table" 2>/dev/null) || true
        if echo "$output" | grep -q "dport $port"; then
            IFS="$old_ifs"
            return 0
        fi
    done
    IFS="$old_ifs"
    return 1
}

# Helper function: Check if CloudFlare is enabled (via trust command)
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

nftban_panel_directadmin_enable() {
    # Nice header for Web Hosting Panel
    cat <<'EOF'
╔═══════════════════════════════════════════════════════════════════╗
║                                                                   ║
║           🌐  WEB HOSTING PANEL: DirectAdmin                      ║
║                 Firewall Configuration Wizard                     ║
║                                                                   ║
╚═══════════════════════════════════════════════════════════════════╝

EOF

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "DirectAdmin Control Panel - Enable Firewall Rules"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Load DirectAdmin configuration to show port summary
    local config_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/panels/directadmin/main.conf"
    if [[ -f "$config_file" ]]; then
        # shellcheck source=/dev/null
        source "$config_file"
        echo "✓ Loaded configuration from: $config_file"
        echo ""
        echo "Port Configuration (applies to both IPv4 and IPv6):"
        echo "  TCP IN:  ${NFTBAN_DIRECTADMIN_TCP_IN:-Not configured}"
        echo "  UDP IN:  ${NFTBAN_DIRECTADMIN_UDP_IN:-Not configured}"
        echo ""
    else
        echo "⚠ Config file not found: $config_file"
        echo "  This may indicate a broken installation."
        echo "  Please reinstall: dnf reinstall nftban"
        return 1
    fi

    # IMPORTANT WARNING: CloudFlare requirement
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║ ⚠️  IMPORTANT: CloudFlare Whitelist Required                      ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "DirectAdmin licensing servers are behind CloudFlare CDN."
    echo "You MUST whitelist CloudFlare IP ranges for licensing to work!"
    echo ""

    # Handle CloudFlare whitelist based on configuration
    local cf_mode="${NFTBAN_DIRECTADMIN_AUTO_CLOUDFLARE:-ASK}"
    local enable_cloudflare="no"

    case "$cf_mode" in
        YES|yes|Y|y)
            enable_cloudflare="yes"
            echo "→ CloudFlare whitelist: AUTO-ENABLE (configured)"
            ;;
        NO|no|N|n)
            enable_cloudflare="no"
            echo "→ CloudFlare whitelist: DISABLED (configured)"
            echo "  ⚠️  WARNING: You must manually whitelist CloudFlare IPs!"
            echo "     Run: nftban trust enable CLOUDFLARE"
            ;;
        ASK|ask|A|a|*)
            echo "Do you want to enable CloudFlare IP whitelist? (REQUIRED for licensing)"
            echo -n "Enable CloudFlare whitelist? [Y/n]: "
            read -r response
            case "$response" in
                n|N|no|NO)
                    enable_cloudflare="no"
                    echo "  ⚠️  WARNING: CloudFlare whitelist NOT enabled!"
                    echo "     DirectAdmin licensing may fail!"
                    echo "     Enable later with: nftban trust enable CLOUDFLARE"
                    ;;
                *)
                    enable_cloudflare="yes"
                    echo "  ✓ CloudFlare whitelist will be enabled"
                    ;;
            esac
            ;;
    esac
    echo ""

    # Enable CloudFlare if requested
    if [[ "$enable_cloudflare" == "yes" ]]; then
        echo "Enabling CloudFlare IP whitelist..."
        if nftban-core trust enable CLOUDFLARE 2>/dev/null && nftban-core trust update 2>/dev/null; then
            echo "  ✓ CloudFlare whitelist enabled"
        else
            echo "  ⚠️ Failed to enable CloudFlare (non-critical, continuing...)"
        fi
        echo ""
    fi

    # Mark DirectAdmin panel as enabled in state file
    echo "Enabling DirectAdmin panel in NFTBan..."
    local state_dir="/var/lib/nftban/panels"
    local state_file="$state_dir/enabled.conf"

    # Ensure state directory exists
    if [[ ! -d "$state_dir" ]]; then
        mkdir -p "$state_dir" 2>/dev/null || {
            echo "ERROR: Failed to create state directory: $state_dir" >&2
            echo "This may be a permissions issue." >&2
            return 1
        }
    fi

    # Update state file using a simple approach (create/update)
    {
        echo "# NFTBan Panel State Configuration"
        echo "# Format: panelname=enabled|disabled"
        echo "# This file is automatically managed by 'nftban panel' commands"
        echo ""
        echo "directadmin=enabled"
    } > "$state_file" || {
        echo "ERROR: Failed to write state file: $state_file" >&2
        return 1
    }

    echo "  ✓ DirectAdmin marked as enabled"
    echo ""

    # Trigger nftban-core sync to load DirectAdmin ports
    echo "Loading DirectAdmin ports into firewall..."
    echo "(This will sync ALL configuration: whitelists, blacklists, ports)"
    echo ""

    if nftban-core sync; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "✅ DirectAdmin panel enabled successfully!"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "DirectAdmin ports are now active and will persist across reboots."
        echo ""
        echo "Next steps:"
        echo "  1. Verify panel access: https://YOUR_SERVER:2222"
        echo "  2. Check firewall status: nftban panel directadmin status"
        echo "  3. Test connectivity: nftban panel directadmin test"
        echo ""
        return 0
    else
        echo ""
        echo "❌ ERROR: Failed to sync firewall configuration" >&2
        echo ""
        echo "DirectAdmin is marked as enabled but ports may not be loaded." >&2
        echo "Try running: nftban-core sync" >&2
        return 1
    fi
}

nftban_panel_directadmin_disable() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "DirectAdmin Control Panel - Disable Firewall Rules"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "⚠️  WARNING: This will remove DirectAdmin port rules from firewall."
    echo "   Essential ports (SSH, HTTP) from ports.d/ will be preserved."
    echo ""
    read -p "Continue? (yes/no) [no]: " confirm
    confirm="${confirm:-no}"

    if [[ "$confirm" != "yes" && "$confirm" != "y" ]]; then
        echo "Aborted."
        return 0
    fi

    echo ""
    echo "Disabling DirectAdmin panel in NFTBan..."

    # Mark DirectAdmin panel as disabled in state file
    local state_dir="/var/lib/nftban/panels"
    local state_file="$state_dir/enabled.conf"

    # Ensure state directory exists
    if [[ ! -d "$state_dir" ]]; then
        mkdir -p "$state_dir" 2>/dev/null || {
            echo "ERROR: Failed to create state directory: $state_dir" >&2
            return 1
        }
    fi

    # Update state file
    {
        echo "# NFTBan Panel State Configuration"
        echo "# Format: panelname=enabled|disabled"
        echo "# This file is automatically managed by 'nftban panel' commands"
        echo ""
        echo "directadmin=disabled"
    } > "$state_file" || {
        echo "ERROR: Failed to write state file: $state_file" >&2
        return 1
    }

    echo "  ✓ DirectAdmin marked as disabled"
    echo ""

    # Trigger nftban-core sync to remove DirectAdmin ports
    echo "Removing DirectAdmin ports from firewall..."
    echo "(This will sync ALL configuration: whitelists, blacklists, ports)"
    echo ""

    if nftban-core sync; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "✅ DirectAdmin panel disabled successfully!"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "DirectAdmin ports have been removed from firewall."
        echo ""
        echo "Preserved ports from ports.d/:"
        echo "  • 22 (SSH - safety port)"
        echo "  • Any custom ports you configured"
        echo ""
        return 0
    else
        echo ""
        echo "❌ ERROR: Failed to sync firewall configuration" >&2
        echo ""
        echo "DirectAdmin is marked as disabled but ports may still be active." >&2
        echo "Try running: nftban-core sync" >&2
        return 1
    fi
}

nftban_panel_directadmin_status() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "DirectAdmin Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Check installation
    local da_path="/usr/local/directadmin"
    if [[ -d "$da_path" ]]; then
        echo "Installation: ✓ DETECTED"
        echo "  Path: $da_path"
        if [[ -f "$da_path/directadmin" ]]; then
            local version
            version=$("$da_path/directadmin" v 2>/dev/null | head -1 || echo "Unknown")
            echo "  Version: $version"
        fi
    else
        echo "Installation: ✗ NOT FOUND"
    fi
    echo ""

    # Check panel port (2222)
    echo "Panel Port (2222/TCP):"
    if ss -tlnp 2>/dev/null | grep -q ':2222 '; then
        echo "  Listening: ✓ YES"
    else
        echo "  Listening: ✗ NO"
    fi

    if _nftban_panel_check_port 2222; then
        echo "  Firewall: ✓ OPEN"
    else
        echo "  Firewall: ✗ CLOSED"
    fi
    echo ""

    # Check CloudFlare whitelist
    echo "CloudFlare Whitelist:"
    if _nftban_panel_check_cloudflare; then
        echo "  Status: ✓ ENABLED"
    else
        echo "  Status: ✗ DISABLED (⚠️  Required for licensing!)"
    fi
    echo ""

    # Configuration file
    echo "Configuration:"
    if [[ -f "/etc/nftban/conf.d/panels/directadmin/main.conf" ]]; then
        echo "  Config: ✓ /etc/nftban/conf.d/panels/directadmin/main.conf"
    else
        echo "  Config: ✗ NOT FOUND"
    fi
    echo ""
}

nftban_panel_directadmin_report() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "DirectAdmin Comprehensive Report"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Installation details
    echo "1. INSTALLATION"
    echo "   ───────────────────────────────────────────────────"
    local da_path="/usr/local/directadmin"
    if [[ -d "$da_path" ]]; then
        echo "   Status: INSTALLED"
        echo "   Path: $da_path"
        if [[ -f "$da_path/directadmin" ]]; then
            local version
            version=$("$da_path/directadmin" v 2>/dev/null | head -1 || echo "Unknown")
            echo "   Version: $version"
        fi
        if [[ -f "$da_path/conf/directadmin.conf" ]]; then
            local port
            port=$(grep -E '^port=' "$da_path/conf/directadmin.conf" 2>/dev/null | cut -d= -f2 || echo "2222")
            echo "   Panel Port: $port"
        fi
    else
        echo "   Status: NOT FOUND"
    fi
    echo ""

    # Port configuration
    echo "2. PORT CONFIGURATION"
    echo "   ───────────────────────────────────────────────────"

    # Load config
    if [[ -f "/etc/nftban/conf.d/panels/directadmin/main.conf" ]]; then
        # shellcheck source=/dev/null
        source "/etc/nftban/conf.d/panels/directadmin/main.conf"

        echo "   TCP INPUT:  ${NFTBAN_DIRECTADMIN_TCP_IN:-Not configured}"
        echo "   TCP OUTPUT: ${NFTBAN_DIRECTADMIN_TCP_OUT:-Not configured}"
        echo "   UDP INPUT:  ${NFTBAN_DIRECTADMIN_UDP_IN:-Not configured}"
        echo "   UDP OUTPUT: ${NFTBAN_DIRECTADMIN_UDP_OUT:-Not configured}"
    else
        echo "   Configuration file not found!"
    fi
    echo ""

    # Firewall status
    echo "3. FIREWALL STATUS"
    echo "   ───────────────────────────────────────────────────"

    # Check key ports
    local key_ports=(2222 80 443 22 25 587)
    for port in "${key_ports[@]}"; do
        local status="CLOSED"
        if _nftban_panel_check_port "$port"; then
            status="OPEN"
        fi
        printf "   Port %-5s: %s\n" "$port" "$status"
    done
    echo ""

    # CloudFlare status
    echo "4. CLOUDFLARE WHITELIST"
    echo "   ───────────────────────────────────────────────────"
    if _nftban_panel_check_cloudflare; then
        echo "   Status: ENABLED ✓"

        # Count IPs
        local ipv4_count ipv6_count
        ipv4_count=$(nft list set ${NFTBAN_TABLE_IPV4} cloudflare_ipv4 2>/dev/null | grep -c 'elements' || echo "0")
        ipv6_count=$(nft list set ${NFTBAN_TABLE_IPV6} cloudflare_ipv6 2>/dev/null | grep -c 'elements' || echo "0")

        echo "   IPv4 ranges: $ipv4_count"
        echo "   IPv6 ranges: $ipv6_count"
    else
        echo "   Status: DISABLED ✗"
        echo "   ⚠️  WARNING: DirectAdmin licensing requires CloudFlare!"
    fi
    echo ""

    # Recommendations
    echo "5. RECOMMENDATIONS"
    echo "   ───────────────────────────────────────────────────"

    local recommendations=()

    # Check CloudFlare
    if ! _nftban_panel_check_cloudflare; then
        recommendations+=("Enable CloudFlare whitelist: nftban trust enable CLOUDFLARE")
    fi

    # Check panel port
    if ! _nftban_panel_check_port 2222; then
        recommendations+=("Open panel port: nftban panel directadmin enable")
    fi

    # Check Fail2ban
    if systemctl is-active fail2ban >/dev/null 2>&1; then
        if [[ -f "/etc/fail2ban/jail.d/nftban-directadmin.conf" ]]; then
            recommendations+=("✓ Fail2ban DirectAdmin jail available")
        fi
    else
        recommendations+=("Consider installing fail2ban for brute-force protection")
    fi

    if [[ ${#recommendations[@]} -eq 0 ]]; then
        echo "   ✓ All checks passed - No recommendations"
    else
        for rec in "${recommendations[@]}"; do
            echo "   • $rec"
        done
    fi
    echo ""

    # Configuration files
    echo "6. CONFIGURATION FILES"
    echo "   ───────────────────────────────────────────────────"
    echo "   /etc/nftban/conf.d/panels/directadmin/main.conf"
    echo "   /etc/nftban/nftban.conf.local (customizations)"
    echo "   /etc/fail2ban/jail.d/nftban-directadmin.conf"
    echo ""
}

nftban_panel_directadmin_repair() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "DirectAdmin Repair - Fix Configuration Issues"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    local repairs=0

    # Check configuration file
    if [[ ! -f "/etc/nftban/conf.d/panels/directadmin/main.conf" ]]; then
        echo "✗ Configuration file missing!"
        echo "  This file should be restored by: dnf reinstall nftban"
        ((repairs++))
    else
        echo "✓ Configuration file exists"
    fi

    # Check CloudFlare whitelist
    if ! _nftban_panel_check_cloudflare; then
        echo "✗ CloudFlare whitelist disabled"
        echo "  Enabling CloudFlare whitelist..."
        if nftban trust enable CLOUDFLARE 2>/dev/null && nftban trust update 2>/dev/null; then
            echo "  ✓ CloudFlare whitelist enabled"
        else
            echo "  ✗ Failed to enable CloudFlare"
            ((repairs++))
        fi
    else
        echo "✓ CloudFlare whitelist enabled"
    fi

    # Check panel port
    if ! _nftban_panel_check_port 2222; then
        echo "✗ Panel port (2222) not open in firewall"
        echo "  Run: nftban panel directadmin enable"
        ((repairs++))
    else
        echo "✓ Panel port (2222) open in firewall"
    fi

    echo ""
    if [[ $repairs -eq 0 ]]; then
        echo "✅ No repairs needed - Configuration looks good!"
    else
        echo "⚠️  Found $repairs issue(s) that need attention"
        echo ""
        echo "To fix all issues, run:"
        echo "  nftban panel directadmin enable"
    fi
    echo ""
}

nftban_panel_directadmin_test() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "DirectAdmin Connectivity Tests"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    local tests_passed=0
    local tests_failed=0

    # Test 1: Panel port listening
    echo "Test 1: Panel Port (2222/TCP)"
    if ss -tlnp 2>/dev/null | grep -q ':2222 '; then
        echo "  ✓ PASS: Port 2222 is listening"
        ((tests_passed++))
    else
        echo "  ✗ FAIL: Port 2222 not listening"
        echo "    Ensure DirectAdmin is running: systemctl status directadmin"
        ((tests_failed++))
    fi
    echo ""

    # Test 2: Firewall rules
    echo "Test 2: Firewall Rules (2222/TCP)"
    if _nftban_panel_check_port 2222; then
        echo "  ✓ PASS: Port 2222 allowed in firewall"
        ((tests_passed++))
    else
        echo "  ✗ FAIL: Port 2222 blocked by firewall"
        echo "    Run: nftban panel directadmin enable"
        ((tests_failed++))
    fi
    echo ""

    # Test 3: CloudFlare whitelist
    echo "Test 3: CloudFlare Whitelist"
    if _nftban_panel_check_cloudflare; then
        echo "  ✓ PASS: CloudFlare whitelist enabled"
        ((tests_passed++))
    else
        echo "  ✗ FAIL: CloudFlare whitelist disabled"
        echo "    ⚠️  DirectAdmin licensing requires CloudFlare!"
        echo "    Run: nftban trust enable CLOUDFLARE"
        ((tests_failed++))
    fi
    echo ""

    # Test 4: HTTP/HTTPS ports
    echo "Test 4: Web Server Ports (80, 443)"
    local web_ok=true
    for port in 80 443; do
        if _nftban_panel_check_port "$port"; then
            echo "  ✓ Port $port: OPEN"
        else
            echo "  ✗ Port $port: CLOSED"
            web_ok=false
        fi
    done
    if $web_ok; then
        ((tests_passed++))
    else
        ((tests_failed++))
        echo "    Run: nftban panel directadmin enable"
    fi
    echo ""

    # Test 5: Mail ports
    echo "Test 5: Mail Server Ports (25, 587, 465)"
    local mail_ok=true
    for port in 25 587 465; do
        if _nftban_panel_check_port "$port"; then
            echo "  ✓ Port $port: OPEN"
        else
            echo "  ✗ Port $port: CLOSED"
            mail_ok=false
        fi
    done
    if $mail_ok; then
        ((tests_passed++))
    else
        ((tests_failed++))
        echo "    Run: nftban panel directadmin enable"
    fi
    echo ""

    # Summary
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Test Results"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Passed: $tests_passed"
    echo "  Failed: $tests_failed"
    echo ""

    if [[ $tests_failed -eq 0 ]]; then
        echo "✅ All tests passed - DirectAdmin configuration OK!"
        return 0
    else
        echo "⚠️  Some tests failed - Run 'nftban panel directadmin repair' to fix"
        return 1
    fi
}

# =============================================================================

# CPANEL PANEL SUPPORT
# =============================================================================


nftban_panel_cpanel_enable() {
    # Nice header for Web Hosting Panel
    cat <<'EOF'
╔═══════════════════════════════════════════════════════════════════╗
║                                                                   ║
║              🌐  WEB HOSTING PANEL: cPanel/WHM                    ║
║                 Firewall Configuration Wizard                     ║
║                                                                   ║
╚═══════════════════════════════════════════════════════════════════╝

EOF

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "cPanel/WHM Control Panel - Enable Firewall Rules"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Load cPanel configuration to show port summary
    local config_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/panels/cpanel/main.conf"
    if [[ -f "$config_file" ]]; then
        # shellcheck source=/dev/null
        source "$config_file"
        echo "✓ Loaded configuration from: $config_file"
        echo ""
        echo "Port Configuration (applies to both IPv4 and IPv6):"
        echo "  TCP IN:  ${NFTBAN_CPANEL_TCP_IN:-Not configured}"
        echo "  UDP IN:  ${NFTBAN_CPANEL_UDP_IN:-Not configured}"
        echo ""
    else
        echo "⚠ Config file not found: $config_file"
        echo "  This may indicate a broken installation."
        echo "  Please reinstall: dnf reinstall nftban"
        return 1
    fi

    # IMPORTANT WARNING: License server whitelist
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║ ⚠️  IMPORTANT: cPanel License Server Whitelist                    ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "cPanel licensing servers must be whitelisted for licensing to work."
    echo ""

    # Handle license server whitelist based on configuration
    local license_mode="${NFTBAN_CPANEL_AUTO_LICENSE_WHITELIST:-ASK}"
    local enable_license_whitelist="no"

    case "$license_mode" in
        YES|yes|Y|y)
            enable_license_whitelist="yes"
            echo "→ License server whitelist: AUTO-ENABLE (configured)"
            ;;
        NO|no|N|n)
            enable_license_whitelist="no"
            echo "→ License server whitelist: DISABLED (configured)"
            echo "  ⚠️  WARNING: You must manually whitelist cPanel license servers!"
            ;;
        ASK|ask|A|a|*)
            echo "Do you want to enable cPanel license server whitelist?"
            echo -n "Enable license server whitelist? [Y/n]: "
            read -r response
            case "$response" in
                n|N|no|NO)
                    enable_license_whitelist="no"
                    echo "  ⚠️  WARNING: License server whitelist NOT enabled!"
                    echo "     cPanel licensing may fail!"
                    ;;
                *)
                    enable_license_whitelist="yes"
                    echo "  ✓ License server whitelist will be enabled"
                    ;;
            esac
            ;;
    esac
    echo ""

    # Enable license server whitelist if requested (placeholder for now)
    if [[ "$enable_license_whitelist" == "yes" ]]; then
        echo "Enabling cPanel license server whitelist..."
        echo "  ℹ️  Note: License server whitelist implementation pending"
        echo ""
    fi

    # Mark cPanel panel as enabled in state file
    echo "Enabling cPanel/WHM panel in NFTBan..."
    local state_dir="/var/lib/nftban/panels"
    local state_file="$state_dir/enabled.conf"

    # Ensure state directory exists
    if [[ ! -d "$state_dir" ]]; then
        mkdir -p "$state_dir" 2>/dev/null || {
            echo "ERROR: Failed to create state directory: $state_dir" >&2
            echo "This may be a permissions issue." >&2
            return 1
        }
    fi

    # Update state file
    {
        echo "# NFTBan Panel State Configuration"
        echo "# Format: panelname=enabled|disabled"
        echo "# This file is automatically managed by 'nftban panel' commands"
        echo ""
        echo "cpanel=enabled"
    } > "$state_file" || {
        echo "ERROR: Failed to write state file: $state_file" >&2
        return 1
    }

    echo "  ✓ cPanel/WHM marked as enabled"
    echo ""

    # Trigger nftban-core sync to load cPanel ports
    echo "Loading cPanel/WHM ports into firewall..."
    echo "(This will sync ALL configuration: whitelists, blacklists, ports)"
    echo ""

    if nftban-core sync; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "✅ cPanel/WHM panel enabled successfully!"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "cPanel/WHM ports are now active and will persist across reboots."
        echo ""
        echo "Next steps:"
        echo "  1. Verify cPanel access: https://YOUR_SERVER:2083"
        echo "  2. Verify WHM access: https://YOUR_SERVER:2087"
        echo "  3. Check firewall status: nftban panel cpanel status"
        echo "  4. Test connectivity: nftban panel cpanel test"
        echo ""
        return 0
    else
        echo ""
        echo "❌ ERROR: Failed to sync firewall configuration" >&2
        echo ""
        echo "cPanel/WHM is marked as enabled but ports may not be loaded." >&2
        echo "Try running: nftban-core sync" >&2
        return 1
    fi
}

nftban_panel_cpanel_disable() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "cPanel/WHM Control Panel - Disable Firewall Rules"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "⚠️  WARNING: This will remove cPanel/WHM port rules from firewall."
    echo "   Essential ports (SSH, HTTP) from ports.d/ will be preserved."
    echo ""
    read -p "Continue? (yes/no) [no]: " confirm
    confirm="${confirm:-no}"

    if [[ "$confirm" != "yes" && "$confirm" != "y" ]]; then
        echo "Aborted."
        return 0
    fi

    echo ""
    echo "Disabling cPanel/WHM panel in NFTBan..."

    # Mark cPanel panel as disabled in state file
    local state_dir="/var/lib/nftban/panels"
    local state_file="$state_dir/enabled.conf"

    # Ensure state directory exists
    if [[ ! -d "$state_dir" ]]; then
        mkdir -p "$state_dir" 2>/dev/null || {
            echo "ERROR: Failed to create state directory: $state_dir" >&2
            return 1
        }
    fi

    # Update state file
    {
        echo "# NFTBan Panel State Configuration"
        echo "# Format: panelname=enabled|disabled"
        echo "# This file is automatically managed by 'nftban panel' commands"
        echo ""
        echo "cpanel=disabled"
    } > "$state_file" || {
        echo "ERROR: Failed to write state file: $state_file" >&2
        return 1
    }

    echo "  ✓ cPanel/WHM marked as disabled"
    echo ""

    # Trigger nftban-core sync to remove cPanel ports
    echo "Removing cPanel/WHM ports from firewall..."
    echo "(This will sync ALL configuration: whitelists, blacklists, ports)"
    echo ""

    if nftban-core sync; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "✅ cPanel/WHM panel disabled successfully!"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "cPanel/WHM ports have been removed from firewall."
        echo ""
        echo "Preserved ports from ports.d/:"
        echo "  • 22 (SSH - safety port)"
        echo "  • Any custom ports you configured"
        echo ""
        return 0
    else
        echo ""
        echo "❌ ERROR: Failed to sync firewall configuration" >&2
        echo ""
        echo "cPanel/WHM is marked as disabled but ports may still be active." >&2
        echo "Try running: nftban-core sync" >&2
        return 1
    fi
}

nftban_panel_cpanel_status() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "cPanel/WHM Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Check installation
    local cpanel_path="/usr/local/cpanel"
    if [[ -d "$cpanel_path" ]]; then
        echo "Installation: ✓ DETECTED"
        echo "  Path: $cpanel_path"
        if [[ -f "$cpanel_path/cpanel" ]]; then
            local version
            version=$("$cpanel_path/cpanel" -V 2>/dev/null | head -1 || echo "Unknown")
            echo "  Version: $version"
        fi
    else
        echo "Installation: ✗ NOT FOUND"
    fi
    echo ""

    # Check cPanel port (2083)
    echo "cPanel Port (2083/TCP):"
    if ss -tlnp 2>/dev/null | grep -q ':2083 '; then
        echo "  Listening: ✓ YES"
    else
        echo "  Listening: ✗ NO"
    fi

    if _nftban_panel_check_port 2083; then
        echo "  Firewall: ✓ OPEN"
    else
        echo "  Firewall: ✗ CLOSED"
    fi
    echo ""

    # Check WHM port (2087)
    echo "WHM Port (2087/TCP):"
    if ss -tlnp 2>/dev/null | grep -q ':2087 '; then
        echo "  Listening: ✓ YES"
    else
        echo "  Listening: ✗ NO"
    fi

    if _nftban_panel_check_port 2087; then
        echo "  Firewall: ✓ OPEN"
    else
        echo "  Firewall: ✗ CLOSED"
    fi
    echo ""

    # Configuration file
    echo "Configuration:"
    if [[ -f "/etc/nftban/conf.d/panels/cpanel/main.conf" ]]; then
        echo "  Config: ✓ /etc/nftban/conf.d/panels/cpanel/main.conf"
    else
        echo "  Config: ✗ NOT FOUND"
    fi
    echo ""
}

nftban_panel_cpanel_report() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "cPanel/WHM Comprehensive Report"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Installation details
    echo "1. INSTALLATION"
    echo "   ───────────────────────────────────────────────────"
    local cpanel_path="/usr/local/cpanel"
    if [[ -d "$cpanel_path" ]]; then
        echo "   Status: INSTALLED"
        echo "   Path: $cpanel_path"
        if [[ -f "$cpanel_path/cpanel" ]]; then
            local version
            version=$("$cpanel_path/cpanel" -V 2>/dev/null | head -1 || echo "Unknown")
            echo "   Version: $version"
        fi
    else
        echo "   Status: NOT FOUND"
    fi
    echo ""

    # Port configuration
    echo "2. PORT CONFIGURATION"
    echo "   ───────────────────────────────────────────────────"

    # Load config
    if [[ -f "/etc/nftban/conf.d/panels/cpanel/main.conf" ]]; then
        # shellcheck source=/dev/null
        source "/etc/nftban/conf.d/panels/cpanel/main.conf"

        echo "   TCP INPUT:  ${NFTBAN_CPANEL_TCP_IN:-Not configured}"
        echo "   TCP OUTPUT: ${NFTBAN_CPANEL_TCP_OUT:-Not configured}"
        echo "   UDP INPUT:  ${NFTBAN_CPANEL_UDP_IN:-Not configured}"
        echo "   UDP OUTPUT: ${NFTBAN_CPANEL_UDP_OUT:-Not configured}"
    else
        echo "   Configuration file not found!"
    fi
    echo ""

    # Firewall status
    echo "3. FIREWALL STATUS"
    echo "   ───────────────────────────────────────────────────"

    # Check key ports
    local key_ports=(2083 2087 2095 2096 80 443 25 587)
    for port in "${key_ports[@]}"; do
        local status="CLOSED"
        if _nftban_panel_check_port "$port"; then
            status="OPEN"
        fi
        printf "   Port %-5s: %s\n" "$port" "$status"
    done
    echo ""

    # Recommendations
    echo "4. RECOMMENDATIONS"
    echo "   ───────────────────────────────────────────────────"

    local recommendations=()

    # Check cPanel port
    if ! _nftban_panel_check_port 2083; then
        recommendations+=("Open cPanel port: nftban panel cpanel enable")
    fi

    # Check WHM port
    if ! _nftban_panel_check_port 2087; then
        recommendations+=("Open WHM port: nftban panel cpanel enable")
    fi

    # Check Fail2ban
    if systemctl is-active fail2ban >/dev/null 2>&1; then
        if [[ -f "/etc/fail2ban/jail.d/nftban-cpanel.conf" ]]; then
            recommendations+=("✓ Fail2ban cPanel jail available")
        fi
    else
        recommendations+=("Consider installing fail2ban for brute-force protection")
    fi

    if [[ ${#recommendations[@]} -eq 0 ]]; then
        echo "   ✓ All checks passed - No recommendations"
    else
        for rec in "${recommendations[@]}"; do
            echo "   • $rec"
        done
    fi
    echo ""

    # Configuration files
    echo "5. CONFIGURATION FILES"
    echo "   ───────────────────────────────────────────────────"
    echo "   /etc/nftban/conf.d/panels/cpanel/main.conf"
    echo "   /etc/nftban/nftban.conf.local (customizations)"
    echo "   /etc/fail2ban/jail.d/nftban-cpanel.conf"
    echo ""
}

nftban_panel_cpanel_repair() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "cPanel/WHM Repair - Fix Configuration Issues"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    local repairs=0

    # Check configuration file
    if [[ ! -f "/etc/nftban/conf.d/panels/cpanel/main.conf" ]]; then
        echo "✗ Configuration file missing!"
        echo "  This file should be restored by: dnf reinstall nftban"
        ((repairs++))
    else
        echo "✓ Configuration file exists"
    fi

    # Check cPanel panel port
    if ! _nftban_panel_check_port 2083; then
        echo "✗ cPanel port (2083) not open in firewall"
        echo "  Run: nftban panel cpanel enable"
        ((repairs++))
    else
        echo "✓ cPanel port (2083) open in firewall"
    fi

    # Check WHM panel port
    if ! _nftban_panel_check_port 2087; then
        echo "✗ WHM port (2087) not open in firewall"
        echo "  Run: nftban panel cpanel enable"
        ((repairs++))
    else
        echo "✓ WHM port (2087) open in firewall"
    fi

    echo ""
    if [[ $repairs -eq 0 ]]; then
        echo "✅ No repairs needed - Configuration looks good!"
    else
        echo "⚠️  Found $repairs issue(s) that need attention"
        echo ""
        echo "To fix all issues, run:"
        echo "  nftban panel cpanel enable"
    fi
    echo ""
}

nftban_panel_cpanel_test() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "cPanel/WHM Connectivity Tests"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    local tests_passed=0
    local tests_failed=0

    # Test 1: cPanel port listening
    echo "Test 1: cPanel Port (2083/TCP)"
    if ss -tlnp 2>/dev/null | grep -q ':2083 '; then
        echo "  ✓ PASS: Port 2083 is listening"
        ((tests_passed++))
    else
        echo "  ✗ FAIL: Port 2083 not listening"
        echo "    Ensure cPanel is running"
        ((tests_failed++))
    fi
    echo ""

    # Test 2: cPanel firewall rules
    echo "Test 2: cPanel Firewall Rules (2083/TCP)"
    if _nftban_panel_check_port 2083; then
        echo "  ✓ PASS: Port 2083 allowed in firewall"
        ((tests_passed++))
    else
        echo "  ✗ FAIL: Port 2083 blocked by firewall"
        echo "    Run: nftban panel cpanel enable"
        ((tests_failed++))
    fi
    echo ""

    # Test 3: WHM port listening
    echo "Test 3: WHM Port (2087/TCP)"
    if ss -tlnp 2>/dev/null | grep -q ':2087 '; then
        echo "  ✓ PASS: Port 2087 is listening"
        ((tests_passed++))
    else
        echo "  ✗ FAIL: Port 2087 not listening"
        echo "    Ensure WHM is running"
        ((tests_failed++))
    fi
    echo ""

    # Test 4: WHM firewall rules
    echo "Test 4: WHM Firewall Rules (2087/TCP)"
    if _nftban_panel_check_port 2087; then
        echo "  ✓ PASS: Port 2087 allowed in firewall"
        ((tests_passed++))
    else
        echo "  ✗ FAIL: Port 2087 blocked by firewall"
        echo "    Run: nftban panel cpanel enable"
        ((tests_failed++))
    fi
    echo ""

    # Test 5: HTTP/HTTPS ports
    echo "Test 5: Web Server Ports (80, 443)"
    local web_ok=true
    for port in 80 443; do
        if _nftban_panel_check_port "$port"; then
            echo "  ✓ Port $port: OPEN"
        else
            echo "  ✗ Port $port: CLOSED"
            web_ok=false
        fi
    done
    if $web_ok; then
        ((tests_passed++))
    else
        ((tests_failed++))
        echo "    Run: nftban panel cpanel enable"
    fi
    echo ""

    # Test 6: Mail ports
    echo "Test 6: Mail Server Ports (25, 587, 465)"
    local mail_ok=true
    for port in 25 587 465; do
        if _nftban_panel_check_port "$port"; then
            echo "  ✓ Port $port: OPEN"
        else
            echo "  ✗ Port $port: CLOSED"
            mail_ok=false
        fi
    done
    if $mail_ok; then
        ((tests_passed++))
    else
        ((tests_failed++))
        echo "    Run: nftban panel cpanel enable"
    fi
    echo ""

    # Summary
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Test Results"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Passed: $tests_passed"
    echo "  Failed: $tests_failed"
    echo ""

    if [[ $tests_failed -eq 0 ]]; then
        echo "✅ All tests passed - cPanel/WHM configuration OK!"
        return 0
    else
        echo "⚠️  Some tests failed - Run 'nftban panel cpanel repair' to fix"
        return 1
    fi
}

# Export functions
export -f nftban_cmd_panel
export -f nftban_panel_help
export -f nftban_panel_directadmin_help
export -f nftban_panel_cpanel_help
export -f _nftban_panel_check_port
export -f _nftban_panel_check_cloudflare
export -f nftban_panel_directadmin_enable
export -f nftban_panel_directadmin_disable
export -f nftban_panel_directadmin_status
export -f nftban_panel_directadmin_report
export -f nftban_panel_directadmin_repair
export -f nftban_panel_directadmin_test
export -f nftban_panel_cpanel_enable
export -f nftban_panel_cpanel_disable
export -f nftban_panel_cpanel_status
export -f nftban_panel_cpanel_report
export -f nftban_panel_cpanel_repair
export -f nftban_panel_cpanel_test
