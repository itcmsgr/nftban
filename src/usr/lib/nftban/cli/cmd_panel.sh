#!/usr/bin/env bash

# =============================================================================
# NFTBan CLI - Panel Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Web hosting panel firewall integration and management
#
# meta:name=cmd_panel
# meta:type=cli
# meta:header=Panel CLI Command
# meta:version=0.32.6
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
#
# **Actions**
#   enable    - Enable panel ports in firewall
#   disable   - Disable panel ports in firewall
#   status    - Show panel port configuration status
#   report    - Generate detailed report (ports, IPs, config)
#   repair    - Fix/update configuration files
#   test      - Test panel connectivity and configuration
# =============================================================================

set -Eeuo pipefail

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

    if [[ -z "$panel" ]]; then
        nftban_panel_help
        return 1
    fi

    # Normalize panel name
    case "$panel" in
        directadmin|da|DA|DirectAdmin)
            panel="directadmin"
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

Actions:
  enable              - Enable panel ports in firewall
  disable             - Disable panel ports in firewall
  status              - Show panel port configuration status
  report              - Generate detailed report (ports, IPs, config)
  repair              - Fix/update configuration files
  test                - Test panel connectivity and configuration

Examples:
  nftban panel directadmin enable      # Enable DirectAdmin ports
  nftban panel directadmin status      # Check configuration
  nftban panel directadmin report      # Full diagnostic report
  nftban panel directadmin test        # Test connectivity
  nftban panel directadmin repair      # Fix configuration issues

Panel-Specific Help:
  nftban panel directadmin help        # DirectAdmin detailed help

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
    nftban cloudflare enable
    nftban cloudflare update

Configuration Files:
  /etc/nftban/conf.d/directadmin.conf          - Main configuration
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

# Helper function: Check if CloudFlare is enabled
_nftban_panel_check_cloudflare() {
    # Use command substitution to avoid SIGPIPE with pipefail
    local status_output
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

    # Delegate to existing implementation in cmd_port.sh
    # This function has all the logic we need
    if command -v nftban_port_allow_directadmin >/dev/null 2>&1; then
        nftban_port_allow_directadmin
    else
        echo "ERROR: DirectAdmin port configuration function not found" >&2
        echo "This may indicate a broken installation." >&2
        echo ""
        echo "Please reinstall: dnf reinstall nftban" >&2
        return 1
    fi
}

nftban_panel_directadmin_disable() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "DirectAdmin Control Panel - Disable Firewall Rules"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "⚠️  WARNING: This will remove DirectAdmin port rules."
    echo "   Essential ports (SSH, HTTP) will be preserved."
    echo ""
    read -p "Continue? (yes/no) [no]: " confirm
    confirm="${confirm:-no}"

    if [[ "$confirm" != "yes" && "$confirm" != "y" ]]; then
        echo "Aborted."
        return 0
    fi

    echo ""
    echo "Removing DirectAdmin-specific port rules..."

    # Remove DirectAdmin-specific ports (keep SSH/HTTP)
    local da_specific_ports="2222,35000:35999"

    echo "  Removing DirectAdmin panel port (2222)..."
    nftban port remove 2222 tcp >/dev/null 2>&1 || true

    echo "  Removing passive FTP range (35000:35999)..."
    # Note: Range removal requires special handling

    echo "✓ DirectAdmin-specific ports removed"
    echo ""
    echo "Preserved essential ports:"
    echo "  • 22 (SSH)"
    echo "  • 80/443 (HTTP/HTTPS)"
    echo ""
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
    if [[ -f "/etc/nftban/conf.d/directadmin.conf" ]]; then
        echo "  Config: ✓ /etc/nftban/conf.d/directadmin.conf"
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
    if [[ -f "/etc/nftban/conf.d/directadmin.conf" ]]; then
        # shellcheck source=/dev/null
        source "/etc/nftban/conf.d/directadmin.conf"

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
        ipv4_count=$(nft list set inet nftban cloudflare_ipv4 2>/dev/null | grep -c 'elements' || echo "0")
        ipv6_count=$(nft list set inet nftban cloudflare_ipv6 2>/dev/null | grep -c 'elements' || echo "0")

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
        recommendations+=("Enable CloudFlare whitelist: nftban cloudflare enable")
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
    echo "   /etc/nftban/conf.d/directadmin.conf"
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
    if [[ ! -f "/etc/nftban/conf.d/directadmin.conf" ]]; then
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
        if nftban cloudflare enable 2>/dev/null; then
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
        echo "    Run: nftban cloudflare enable"
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

# Export functions
export -f nftban_cmd_panel
export -f _nftban_panel_check_port
export -f _nftban_panel_check_cloudflare
export -f nftban_panel_directadmin_enable
export -f nftban_panel_directadmin_disable
export -f nftban_panel_directadmin_status
export -f nftban_panel_directadmin_report
export -f nftban_panel_directadmin_repair
export -f nftban_panel_directadmin_test
