#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_panel_directadmin" meta:type="lib" meta:version="1.0.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="DirectAdmin panel integration with enable/disable/status/report/repair/test"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_DATA_DIR"
# meta:inventory.config_files="/etc/nftban/conf.d/panels/directadmin/main.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"

set -Eeuo pipefail

# Prevent double-sourcing
[[ -n "${_NFTBAN_PANEL_DIRECTADMIN_LOADED:-}" ]] && return 0
readonly _NFTBAN_PANEL_DIRECTADMIN_LOADED=1

# =============================================================================
# HELP
# =============================================================================

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
  /etc/nftban/nftban.conf.local                   - Your customizations
  /etc/nftban/conf.d/login/main.conf                   - Login monitoring (brute-force)

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
# ENABLE
# =============================================================================

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
        source "$config_file" || true
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
    local state_dir="${NFTBAN_DATA_DIR:-/var/lib/nftban}/panels"
    local state_file="$state_dir/enabled.conf"

    # Ensure state directory exists
    if [[ ! -d "$state_dir" ]]; then
        mkdir -p "$state_dir" 2>/dev/null || {
            echo "ERROR: Failed to create state directory: $state_dir" >&2
            echo "This may be a permissions issue." >&2
            return 1
        }
    fi

    # v1.19.0: Preserve other panels' state when updating (R25)
    local temp_file
    temp_file=$(mktemp "${state_file}.XXXXXX")
    {
        echo "# NFTBan Panel State Configuration"
        echo "# Format: panelname=enabled|disabled"
        echo "# This file is automatically managed by 'nftban panel' commands"
        echo ""
        if [[ -f "$state_file" ]]; then
            grep -v "^directadmin=" "$state_file" 2>/dev/null | grep -v "^#" | grep -v "^$" || true
        fi
        echo "directadmin=enabled"
    } > "$temp_file"
    mv "$temp_file" "$state_file" || {
        echo "ERROR: Failed to write state file: $state_file" >&2
        rm -f "$temp_file"
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

# =============================================================================
# DISABLE
# =============================================================================

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
    local state_dir="${NFTBAN_DATA_DIR:-/var/lib/nftban}/panels"
    local state_file="$state_dir/enabled.conf"

    # Ensure state directory exists
    if [[ ! -d "$state_dir" ]]; then
        mkdir -p "$state_dir" 2>/dev/null || {
            echo "ERROR: Failed to create state directory: $state_dir" >&2
            return 1
        }
    fi

    # v1.19.0: Preserve other panels' state when updating (R25)
    local temp_file
    temp_file=$(mktemp "${state_file}.XXXXXX")
    {
        echo "# NFTBan Panel State Configuration"
        echo "# Format: panelname=enabled|disabled"
        echo "# This file is automatically managed by 'nftban panel' commands"
        echo ""
        if [[ -f "$state_file" ]]; then
            grep -v "^directadmin=" "$state_file" 2>/dev/null | grep -v "^#" | grep -v "^$" || true
        fi
        echo "directadmin=disabled"
    } > "$temp_file"
    mv "$temp_file" "$state_file" || {
        echo "ERROR: Failed to write state file: $state_file" >&2
        rm -f "$temp_file"
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

# =============================================================================
# STATUS
# =============================================================================

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
    if [[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/panels/directadmin/main.conf" ]]; then
        echo "  Config: ✓ ${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/panels/directadmin/main.conf"
    else
        echo "  Config: ✗ NOT FOUND"
    fi
    echo ""
}

# =============================================================================
# REPORT
# =============================================================================

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
    if [[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/panels/directadmin/main.conf" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/panels/directadmin/main.conf" || true
    fi
    # v1.19.0: Source .local override (user customizations survive package updates)
    if [[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/panels/directadmin/main.conf.local" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/panels/directadmin/main.conf.local" || true
    fi
    if [[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/panels/directadmin/main.conf" ]]; then
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
    echo "6. CONFIGURATION FILES"
    echo "   ───────────────────────────────────────────────────"
    echo "   ${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/panels/directadmin/main.conf"
    echo "   ${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf.local (customizations)"
    echo "   ${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/login/main.conf (brute-force protection)"
    echo ""
}

# =============================================================================
# REPAIR
# =============================================================================

nftban_panel_directadmin_repair() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "DirectAdmin Repair - Fix Configuration Issues"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    local repairs=0

    # Check configuration file
    if [[ ! -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/panels/directadmin/main.conf" ]]; then
        echo "✗ Configuration file missing!"
        echo "  This file should be restored by: dnf reinstall nftban"
        # v1.19.20 FIX
        ((repairs++)) || true
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
            # v1.19.20 FIX
        ((repairs++)) || true
        fi
    else
        echo "✓ CloudFlare whitelist enabled"
    fi

    # Check panel port
    if ! _nftban_panel_check_port 2222; then
        echo "✗ Panel port (2222) not open in firewall"
        echo "  Run: nftban panel directadmin enable"
        # v1.19.20 FIX
        ((repairs++)) || true
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

# =============================================================================
# TEST
# =============================================================================

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
        # v1.19.20 FIX
        ((tests_passed++)) || true
    else
        echo "  ✗ FAIL: Port 2222 not listening"
        echo "    Ensure DirectAdmin is running: systemctl status directadmin"
        # v1.19.20 FIX
        ((tests_failed++)) || true
    fi
    echo ""

    # Test 2: Firewall rules
    echo "Test 2: Firewall Rules (2222/TCP)"
    if _nftban_panel_check_port 2222; then
        echo "  ✓ PASS: Port 2222 allowed in firewall"
        # v1.19.20 FIX
        ((tests_passed++)) || true
    else
        echo "  ✗ FAIL: Port 2222 blocked by firewall"
        echo "    Run: nftban panel directadmin enable"
        # v1.19.20 FIX
        ((tests_failed++)) || true
    fi
    echo ""

    # Test 3: CloudFlare whitelist
    echo "Test 3: CloudFlare Whitelist"
    if _nftban_panel_check_cloudflare; then
        echo "  ✓ PASS: CloudFlare whitelist enabled"
        # v1.19.20 FIX
        ((tests_passed++)) || true
    else
        echo "  ✗ FAIL: CloudFlare whitelist disabled"
        echo "    ⚠️  DirectAdmin licensing requires CloudFlare!"
        echo "    Run: nftban trust enable CLOUDFLARE"
        # v1.19.20 FIX
        ((tests_failed++)) || true
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
        # v1.19.20 FIX
        ((tests_passed++)) || true
    else
        # v1.19.20 FIX
        ((tests_failed++)) || true
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
        # v1.19.20 FIX
        ((tests_passed++)) || true
    else
        # v1.19.20 FIX
        ((tests_failed++)) || true
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
# EXPORT FUNCTIONS
# =============================================================================

export -f nftban_panel_directadmin_help
export -f nftban_panel_directadmin_enable
export -f nftban_panel_directadmin_disable
export -f nftban_panel_directadmin_status
export -f nftban_panel_directadmin_report
export -f nftban_panel_directadmin_repair
export -f nftban_panel_directadmin_test
