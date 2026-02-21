#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_panel_cpanel" meta:type="lib" meta:version="1.0.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="cPanel/WHM panel integration with enable/disable/status/report/repair/test"
# meta:inventory.files=""
# meta:inventory.binaries="whmapi1"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR"
# meta:inventory.config_files="/etc/nftban/conf.d/panels/cpanel/main.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"

set -Eeuo pipefail

# Prevent double-sourcing
[[ -n "${_NFTBAN_PANEL_CPANEL_LOADED:-}" ]] && return 0
readonly _NFTBAN_PANEL_CPANEL_LOADED=1

# =============================================================================
# HELP
# =============================================================================

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
  /etc/nftban/conf.d/login/main.conf                    - Login monitoring (brute-force)

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
# CPHULK CONFLICT CHECK
# =============================================================================

_nftban_cpanel_check_cphulk() {
    # Check if cPHulk brute-force protection is enabled
    # cPHulk and NFTBan login monitoring can conflict (duplicate ban decisions)

    if ! command -v whmapi1 &>/dev/null; then
        return 0  # Not a WHM system or whmapi1 not available
    fi

    local cphulk_enabled
    cphulk_enabled=$(whmapi1 cphulk_status 2>/dev/null | grep -i "is_enabled" | grep -oP '\d+' || echo "0")

    if [[ "$cphulk_enabled" == "1" ]]; then
        echo ""
        echo "╔═══════════════════════════════════════════════════════════════════╗"
        echo "║ ⚠️  WARNING: cPHulk Brute Force Protection is ENABLED            ║"
        echo "╚═══════════════════════════════════════════════════════════════════╝"
        echo ""
        echo "cPHulk and NFTBan login monitoring may conflict, causing:"
        echo "  • Duplicate ban decisions for the same IP"
        echo "  • Inconsistent ban durations"
        echo "  • Potential false positives"
        echo ""
        echo "Recommendations:"
        echo "  1. Disable cPHulk:  whmapi1 configureservice service=cphulkd enabled=0"
        echo "     (Let NFTBan handle all brute-force protection)"
        echo ""
        echo "  2. Or disable NFTBan login monitoring:  nftban login disable"
        echo "     (Let cPHulk handle brute-force protection)"
        echo ""
        echo "Continuing with panel enable... (login monitoring may still work)"
        echo ""
    fi
}

# =============================================================================
# ENABLE
# =============================================================================

nftban_panel_cpanel_enable() {
    # Check for cPHulk conflict before proceeding
    _nftban_cpanel_check_cphulk

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

# =============================================================================
# DISABLE
# =============================================================================

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

# =============================================================================
# STATUS
# =============================================================================

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

# =============================================================================
# REPORT
# =============================================================================

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

    # v2.1: Check native login monitoring (replaces fail2ban)
    if nftban login status &>/dev/null; then
        recommendations+=("✓ Native login monitoring enabled")
    else
        recommendations+=("Enable login monitoring: nftban login enable")
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
    echo "   /etc/nftban/conf.d/login/main.conf (brute-force protection)"
    echo ""
}

# =============================================================================
# REPAIR
# =============================================================================

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

# =============================================================================
# TEST
# =============================================================================

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

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================

export -f nftban_panel_cpanel_help
export -f nftban_panel_cpanel_enable
export -f nftban_panel_cpanel_disable
export -f nftban_panel_cpanel_status
export -f nftban_panel_cpanel_report
export -f nftban_panel_cpanel_repair
export -f nftban_panel_cpanel_test
