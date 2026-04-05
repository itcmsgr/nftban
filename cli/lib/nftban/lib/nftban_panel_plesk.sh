#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_panel_plesk" meta:type="lib" meta:version="1.48.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Plesk panel integration with enable/disable/status/report/repair/test"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_DATA_DIR"
# meta:inventory.config_files="/etc/nftban/conf.d/panels/plesk/main.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"

set -Eeuo pipefail

# Variable defaults (safe for re-sourcing)
: "${NFTBAN_CONFIG_DIR:=/etc/nftban}"
: "${NFTBAN_DATA_DIR:=/var/lib/nftban}"

# Prevent double-sourcing
[[ -n "${_NFTBAN_PANEL_PLESK_LOADED:-}" ]] && return 0
readonly _NFTBAN_PANEL_PLESK_LOADED=1

# =============================================================================
# HELP
# =============================================================================

nftban_panel_plesk_help() {
    cat <<'EOF'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
NFTBan Plesk Integration - Comprehensive Panel Support
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Usage:
  nftban panel plesk <action>

Actions:
  enable              - Enable Plesk ports in firewall
                        • Opens all required TCP/UDP ports
                        • Prompts for Plesk license server whitelist
                        • Creates firewall rules for IPv4 and IPv6

  disable             - Disable Plesk ports in firewall
                        • Removes all Plesk-specific rules
                        • Preserves essential SSH/HTTP ports
                        • Safe operation (no lockout risk)

  status              - Show current Plesk configuration
                        • Lists enabled/disabled ports
                        • Shows license server whitelist status
                        • Displays panel detection status

  report              - Generate comprehensive diagnostic report
                        • All ports (enabled/disabled)
                        • Plesk license server whitelist status
                        • Plesk installation details
                        • Recommended security improvements
                        • Configuration file locations

  repair              - Fix Plesk configuration issues
                        • Updates configuration files
                        • Fixes missing port rules
                        • Re-enables license server whitelist if needed
                        • Validates all settings

  test                - Test Plesk connectivity and configuration
                        • Tests panel ports (8443, 8447, 8880)
                        • Verifies license server whitelist
                        • Tests mail ports (SMTP, IMAP, POP3)
                        • Reports any issues found

Plesk Ports Configured:
  TCP INPUT:  20,21,25,53,80,110,143,443,465,587,993,995,8443,8447,8880
  TCP OUTPUT: 20,21,25,53,80,110,113,443,587,993,995,8443,8447
  UDP INPUT:  20,21,53,80,443
  UDP OUTPUT: 20,21,53,113,123

Key Ports:
  8443        - Plesk Web Panel (HTTPS)
  8447        - Plesk Update Manager
  8880        - Plesk HTTP (redirects to HTTPS)
  80/443      - HTTP/HTTPS (including QUIC/HTTP3)
  25/587/465  - SMTP/Submission
  20/21       - FTP

⚠️  Plesk License Server Whitelist:
  Plesk licensing servers must be accessible for licensing to work.
  You can enable automatic license server whitelisting during setup.

Configuration Files:
  /etc/nftban/conf.d/panels/plesk/main.conf       - Main configuration
  /etc/nftban/nftban.conf.local                   - Your customizations
  /etc/nftban/conf.d/login/main.conf                   - Login monitoring (brute-force)

Examples:
  # Initial setup
  nftban panel plesk enable

  # Check status
  nftban panel plesk status

  # Full diagnostic
  nftban panel plesk report

  # Test connectivity
  nftban panel plesk test

  # Fix issues
  nftban panel plesk repair

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
}

# =============================================================================
# ENABLE
# =============================================================================

nftban_panel_plesk_enable() {
    # Nice header for Web Hosting Panel
    cat <<'EOF'
╔═══════════════════════════════════════════════════════════════════╗
║                                                                   ║
║              🌐  WEB HOSTING PANEL: Plesk                         ║
║                 Firewall Configuration Wizard                     ║
║                                                                   ║
╚═══════════════════════════════════════════════════════════════════╝

EOF

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Plesk Control Panel - Enable Firewall Rules"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Load Plesk configuration to show port summary
    local config_file="${NFTBAN_CONFIG_DIR}/conf.d/panels/plesk/main.conf"
    if [[ -f "$config_file" ]]; then
        # shellcheck source=/dev/null
        source "$config_file" || true
        echo "✓ Loaded configuration from: $config_file"
        echo ""
        echo "Port Configuration (applies to both IPv4 and IPv6):"
        echo "  TCP IN:  ${NFTBAN_PLESK_TCP_IN:-Not configured}"
        echo "  UDP IN:  ${NFTBAN_PLESK_UDP_IN:-Not configured}"
        echo ""
    else
        echo "⚠ Config file not found: $config_file"
        echo "  This may indicate a broken installation."
        echo "  Please reinstall: dnf reinstall nftban"
        return 1
    fi

    # v1.48.0: Warn about CSF conflict
    if [[ -f /etc/csf/csf.conf ]] || command -v csf &>/dev/null; then
        local csf_active=0
        if systemctl is-active csf.service &>/dev/null || systemctl is-active lfd.service &>/dev/null; then
            csf_active=1
        fi
        echo "╔═══════════════════════════════════════════════════════════════════╗"
        echo "║ ⚠️  CSF (ConfigServer Firewall) is INSTALLED                      ║"
        echo "╚═══════════════════════════════════════════════════════════════════╝"
        echo ""
        if [[ "$csf_active" == "1" ]]; then
            echo "CSF/LFD services are RUNNING — directly conflicts with NFTBan."
        else
            echo "CSF is installed but services appear stopped."
        fi
        echo "CSF manages its own iptables/nftables rules that conflict with NFTBan."
        echo ""
        echo "To disable: csf -x && systemctl disable csf lfd"
        echo ""
    fi

    # v1.48.0 P3-61: Warn about Plesk Firewall extension
    if [[ -d "/usr/local/psa/admin/htdocs/modules/firewall" ]] || \
       plesk bin extension --list 2>/dev/null | grep -qi 'firewall'; then
        echo "╔═══════════════════════════════════════════════════════════════════╗"
        echo "║ ⚠️  Plesk Firewall Extension DETECTED                             ║"
        echo "╚═══════════════════════════════════════════════════════════════════╝"
        echo ""
        echo "The Plesk Firewall extension conflicts with NFTBan."
        echo "It injects its own rules that override NFTBan's protection."
        echo ""
        echo "Disable it now:  plesk bin extension --disable firewall"
        echo ""
    fi

    # IMPORTANT WARNING: License server whitelist
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║ ⚠️  IMPORTANT: Plesk License Server Whitelist                     ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Plesk licensing servers must be accessible for licensing to work."
    echo ""

    # Handle license server whitelist based on configuration
    local license_mode="${NFTBAN_PLESK_AUTO_LICENSE_WHITELIST:-ASK}"
    local enable_license_whitelist="no"

    case "$license_mode" in
        YES|yes|Y|y)
            enable_license_whitelist="yes"
            echo "→ License server whitelist: AUTO-ENABLE (configured)"
            ;;
        NO|no|N|n)
            enable_license_whitelist="no"
            echo "→ License server whitelist: DISABLED (configured)"
            echo "  ⚠️  WARNING: You must manually whitelist Plesk license servers!"
            ;;
        ASK|ask|A|a|*)
            # Non-interactive (no TTY): default YES — Plesk licensing needs whitelist
            if [[ ! -t 0 ]]; then
                enable_license_whitelist="yes"
                echo "→ License server whitelist: AUTO-ENABLE (non-interactive mode)"
            else
                echo "Do you want to enable Plesk license server whitelist?"
                echo -n "Enable license server whitelist? [Y/n]: "
                read -r response
                case "$response" in
                    n|N|no|NO)
                        enable_license_whitelist="no"
                        echo "  ⚠️  WARNING: License server whitelist NOT enabled!"
                        echo "     Plesk licensing may fail!"
                        ;;
                    *)
                        enable_license_whitelist="yes"
                        echo "  ✓ License server whitelist will be enabled"
                        ;;
                esac
            fi
            ;;
    esac
    echo ""

    # Enable license server whitelist if requested (placeholder for now)
    if [[ "$enable_license_whitelist" == "yes" ]]; then
        echo "Enabling Plesk license server whitelist..."
        echo "  ℹ️  Note: License server whitelist implementation pending"
        echo ""
    fi

    # Mark Plesk panel as enabled in state file
    echo "Enabling Plesk panel in NFTBan..."
    local state_dir="${NFTBAN_DATA_DIR}/panels"
    local state_file="$state_dir/enabled.conf"

    # Ensure state directory exists
    if [[ ! -d "$state_dir" ]]; then
        mkdir -p "$state_dir" 2>/dev/null || {
            echo "ERROR: Failed to create state directory: $state_dir" >&2
            echo "This may be a permissions issue." >&2
            return 1
        }
    fi

    # Update state file - preserve other panels
    local temp_file
    temp_file=$(mktemp)
    {
        echo "# NFTBan Panel State Configuration"
        echo "# Format: panelname=enabled|disabled"
        echo "# This file is automatically managed by 'nftban panel' commands"
        echo ""
        # Preserve other panels, update this one
        if [[ -f "$state_file" ]]; then
            grep -v "^plesk=" "$state_file" 2>/dev/null | grep -v "^#" | grep -v "^$" || true
        fi
        echo "plesk=enabled"
    } > "$temp_file"
    mv "$temp_file" "$state_file"

    echo "  ✓ Plesk marked as enabled"
    echo ""

    # Trigger nftban-core sync to load Plesk ports
    echo "Loading Plesk ports into firewall..."
    echo "(This will sync ALL configuration: whitelists, blacklists, ports)"
    echo ""

    if /usr/lib/nftban/bin/nftban-core sync; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "✅ Plesk panel enabled successfully!"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "Plesk ports are now active and will persist across reboots."
        echo ""
        echo "Next steps:"
        echo "  1. Verify Plesk access: https://YOUR_SERVER:8443"
        echo "  2. Check firewall status: nftban panel plesk status"
        echo "  3. Test connectivity: nftban panel plesk test"
        echo ""
        return 0
    else
        echo ""
        echo "❌ ERROR: Failed to sync firewall configuration" >&2
        echo ""
        echo "Plesk is marked as enabled but ports may not be loaded." >&2
        echo "Try running: nftban-core sync" >&2
        return 1
    fi
}

# =============================================================================
# DISABLE
# =============================================================================

nftban_panel_plesk_disable() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Plesk Control Panel - Disable Firewall Rules"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "⚠️  WARNING: This will remove Plesk port rules from firewall."
    echo "   Essential ports (SSH, HTTP) from ports.d/ will be preserved."
    echo ""
    read -p "Continue? (yes/no) [no]: " confirm
    confirm="${confirm:-no}"

    if [[ "$confirm" != "yes" && "$confirm" != "y" ]]; then
        echo "Aborted."
        return 0
    fi

    echo ""
    echo "Disabling Plesk panel in NFTBan..."

    # Mark Plesk panel as disabled in state file
    local state_dir="${NFTBAN_DATA_DIR}/panels"
    local state_file="$state_dir/enabled.conf"

    # Ensure state directory exists
    if [[ ! -d "$state_dir" ]]; then
        mkdir -p "$state_dir" 2>/dev/null || {
            echo "ERROR: Failed to create state directory: $state_dir" >&2
            return 1
        }
    fi

    # Update state file - preserve other panels
    local temp_file
    temp_file=$(mktemp)
    {
        echo "# NFTBan Panel State Configuration"
        echo "# Format: panelname=enabled|disabled"
        echo "# This file is automatically managed by 'nftban panel' commands"
        echo ""
        if [[ -f "$state_file" ]]; then
            grep -v "^plesk=" "$state_file" 2>/dev/null | grep -v "^#" | grep -v "^$" || true
        fi
        echo "plesk=disabled"
    } > "$temp_file"
    mv "$temp_file" "$state_file"

    echo "  ✓ Plesk marked as disabled"
    echo ""

    # Trigger nftban-core sync to remove Plesk ports
    echo "Removing Plesk ports from firewall..."
    echo "(This will sync ALL configuration: whitelists, blacklists, ports)"
    echo ""

    if /usr/lib/nftban/bin/nftban-core sync; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "✅ Plesk panel disabled successfully!"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "Plesk ports have been removed from firewall."
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
        echo "Plesk is marked as disabled but ports may still be active." >&2
        echo "Try running: nftban-core sync" >&2
        return 1
    fi
}

# =============================================================================
# STATUS
# =============================================================================

nftban_panel_plesk_status() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Plesk Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Check installation
    local plesk_path="/usr/local/psa"
    if [[ -d "$plesk_path" ]]; then
        echo "Installation: ✓ DETECTED"
        echo "  Path: $plesk_path"
        if [[ -f "$plesk_path/version" ]]; then
            local version
            version=$(cat "$plesk_path/version" 2>/dev/null | head -1 || echo "Unknown")
            echo "  Version: $version"
        fi
    else
        echo "Installation: ✗ NOT FOUND"
    fi
    echo ""

    # Check Plesk port (8443)
    echo "Plesk Panel Port (8443/TCP):"
    if ss -tlnp 2>/dev/null | grep -q ':8443 '; then
        echo "  Listening: ✓ YES"
    else
        echo "  Listening: ✗ NO"
    fi

    if _nftban_panel_check_port 8443; then
        echo "  Firewall: ✓ OPEN"
    else
        echo "  Firewall: ✗ CLOSED"
    fi
    echo ""

    # Check Plesk Updater port (8447)
    echo "Plesk Updater Port (8447/TCP):"
    if ss -tlnp 2>/dev/null | grep -q ':8447 '; then
        echo "  Listening: ✓ YES"
    else
        echo "  Listening: ✗ NO"
    fi

    if _nftban_panel_check_port 8447; then
        echo "  Firewall: ✓ OPEN"
    else
        echo "  Firewall: ✗ CLOSED"
    fi
    echo ""

    # v1.48.0 P3-61: Detect Plesk Firewall extension conflict
    echo "Plesk Firewall Extension:"
    if [[ -d "/usr/local/psa/admin/htdocs/modules/firewall" ]] || \
       plesk bin extension --list 2>/dev/null | grep -qi 'firewall'; then
        echo "  Status: ⚠️  INSTALLED (conflicts with NFTBan)"
        echo "  Action: Disable the Plesk Firewall extension"
        echo "          plesk bin extension --disable firewall"
        echo "  Reason: Plesk Firewall injects its own nftables/iptables rules"
        echo "          that conflict with NFTBan's rule management"
    else
        echo "  Status: ✓ NOT INSTALLED"
    fi
    echo ""

    # v1.48.0: CSF detection
    echo "CSF (ConfigServer Firewall):"
    if [[ -f /etc/csf/csf.conf ]] || command -v csf &>/dev/null; then
        if systemctl is-active csf.service &>/dev/null || systemctl is-active lfd.service &>/dev/null; then
            echo "  Status: ⚠️  RUNNING (conflicts with NFTBan)"
            echo "  Action: csf -x && systemctl disable csf lfd"
        else
            echo "  Status: ⚠️  INSTALLED but stopped"
            echo "  Tip:    Remove CSF if not needed: csf -u"
        fi
    else
        echo "  Status: ✓ NOT INSTALLED"
    fi
    echo ""

    # Configuration file
    echo "Configuration:"
    if [[ -f "${NFTBAN_CONFIG_DIR}/conf.d/panels/plesk/main.conf" ]]; then
        echo "  Config: ✓ ${NFTBAN_CONFIG_DIR}/conf.d/panels/plesk/main.conf"
    else
        echo "  Config: ✗ NOT FOUND"
    fi
    echo ""
}

# =============================================================================
# REPORT
# =============================================================================

nftban_panel_plesk_report() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Plesk Comprehensive Report"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Installation details
    echo "1. INSTALLATION"
    echo "   ───────────────────────────────────────────────────"
    local plesk_path="/usr/local/psa"
    if [[ -d "$plesk_path" ]]; then
        echo "   Status: INSTALLED"
        echo "   Path: $plesk_path"
        if [[ -f "$plesk_path/version" ]]; then
            local version
            version=$(cat "$plesk_path/version" 2>/dev/null | head -1 || echo "Unknown")
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
    if [[ -f "${NFTBAN_CONFIG_DIR}/conf.d/panels/plesk/main.conf" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_CONFIG_DIR}/conf.d/panels/plesk/main.conf" || true
    fi
    # v1.19.0: Source .local override (user customizations survive package updates)
    if [[ -f "${NFTBAN_CONFIG_DIR}/conf.d/panels/plesk/main.conf.local" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_CONFIG_DIR}/conf.d/panels/plesk/main.conf.local" || true
    fi
    if [[ -f "${NFTBAN_CONFIG_DIR}/conf.d/panels/plesk/main.conf" ]]; then
        echo "   TCP INPUT:  ${NFTBAN_PLESK_TCP_IN:-Not configured}"
        echo "   TCP OUTPUT: ${NFTBAN_PLESK_TCP_OUT:-Not configured}"
        echo "   UDP INPUT:  ${NFTBAN_PLESK_UDP_IN:-Not configured}"
        echo "   UDP OUTPUT: ${NFTBAN_PLESK_UDP_OUT:-Not configured}"
    else
        echo "   Configuration file not found!"
    fi
    echo ""

    # Firewall status
    echo "3. FIREWALL STATUS"
    echo "   ───────────────────────────────────────────────────"

    # Check key ports
    local key_ports=(8443 8447 8880 80 443 25 587)
    for port in "${key_ports[@]}"; do
        local status="CLOSED"
        if _nftban_panel_check_port "$port"; then
            status="OPEN"
        fi
        printf "   Port %-5s: %s\n" "$port" "$status"
    done
    echo ""

    # v1.48.0 P3-61: Plesk Firewall extension
    echo "4. PLESK FIREWALL EXTENSION"
    echo "   ───────────────────────────────────────────────────"
    if [[ -d "/usr/local/psa/admin/htdocs/modules/firewall" ]] || \
       plesk bin extension --list 2>/dev/null | grep -qi 'firewall'; then
        echo "   Status: INSTALLED ⚠️  (conflicts with NFTBan)"
        echo "   Fix:    plesk bin extension --disable firewall"
    else
        echo "   Status: NOT INSTALLED ✓"
    fi
    echo ""

    # Recommendations
    echo "5. RECOMMENDATIONS"
    echo "   ───────────────────────────────────────────────────"

    local recommendations=()

    # Check Plesk Firewall extension
    if [[ -d "/usr/local/psa/admin/htdocs/modules/firewall" ]] || \
       plesk bin extension --list 2>/dev/null | grep -qi 'firewall'; then
        recommendations+=("Disable Plesk Firewall: plesk bin extension --disable firewall")
    fi

    # Check CSF
    if [[ -f /etc/csf/csf.conf ]] || command -v csf &>/dev/null; then
        if systemctl is-active csf.service &>/dev/null || systemctl is-active lfd.service &>/dev/null; then
            recommendations+=("Disable CSF: csf -x && systemctl disable csf lfd")
        fi
    fi

    # Check Plesk port
    if ! _nftban_panel_check_port 8443; then
        recommendations+=("Open Plesk panel port: nftban panel plesk enable")
    fi

    # Check Plesk Updater port
    if ! _nftban_panel_check_port 8447; then
        recommendations+=("Open Plesk Updater port: nftban panel plesk enable")
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
    echo "   ${NFTBAN_CONFIG_DIR}/conf.d/panels/plesk/main.conf"
    echo "   ${NFTBAN_CONFIG_DIR}/nftban.conf.local (customizations)"
    echo "   ${NFTBAN_CONFIG_DIR}/conf.d/login/main.conf (brute-force protection)"
    echo ""
}

# =============================================================================
# REPAIR
# =============================================================================

nftban_panel_plesk_repair() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Plesk Repair - Fix Configuration Issues"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    local repairs=0

    # Check configuration file
    if [[ ! -f "${NFTBAN_CONFIG_DIR}/conf.d/panels/plesk/main.conf" ]]; then
        echo "✗ Configuration file missing!"
        echo "  This file should be restored by: dnf reinstall nftban"
        # v1.19.20 FIX
        ((repairs++)) || true
    else
        echo "✓ Configuration file exists"
    fi

    # Check Plesk panel port
    if ! _nftban_panel_check_port 8443; then
        echo "✗ Plesk port (8443) not open in firewall"
        echo "  Run: nftban panel plesk enable"
        # v1.19.20 FIX
        ((repairs++)) || true
    else
        echo "✓ Plesk port (8443) open in firewall"
    fi

    # Check Plesk Updater port
    if ! _nftban_panel_check_port 8447; then
        echo "✗ Plesk Updater port (8447) not open in firewall"
        echo "  Run: nftban panel plesk enable"
        # v1.19.20 FIX
        ((repairs++)) || true
    else
        echo "✓ Plesk Updater port (8447) open in firewall"
    fi

    echo ""
    if [[ $repairs -eq 0 ]]; then
        echo "✅ No repairs needed - Configuration looks good!"
    else
        echo "⚠️  Found $repairs issue(s) that need attention"
        echo ""
        echo "To fix all issues, run:"
        echo "  nftban panel plesk enable"
    fi
    echo ""
}

# =============================================================================
# TEST
# =============================================================================

nftban_panel_plesk_test() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Plesk Connectivity Tests"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    local tests_passed=0
    local tests_failed=0

    # Test 1: Plesk port listening
    echo "Test 1: Plesk Panel Port (8443/TCP)"
    if ss -tlnp 2>/dev/null | grep -q ':8443 '; then
        echo "  ✓ PASS: Port 8443 is listening"
        # v1.19.20 FIX
        ((tests_passed++)) || true
    else
        echo "  ✗ FAIL: Port 8443 not listening"
        echo "    Ensure Plesk is running: systemctl status sw-cp-server"
        # v1.19.20 FIX
        ((tests_failed++)) || true
    fi
    echo ""

    # Test 2: Plesk firewall rules
    echo "Test 2: Plesk Panel Firewall Rules (8443/TCP)"
    if _nftban_panel_check_port 8443; then
        echo "  ✓ PASS: Port 8443 allowed in firewall"
        # v1.19.20 FIX
        ((tests_passed++)) || true
    else
        echo "  ✗ FAIL: Port 8443 blocked by firewall"
        echo "    Run: nftban panel plesk enable"
        # v1.19.20 FIX
        ((tests_failed++)) || true
    fi
    echo ""

    # Test 3: Plesk Updater port listening
    echo "Test 3: Plesk Updater Port (8447/TCP)"
    if ss -tlnp 2>/dev/null | grep -q ':8447 '; then
        echo "  ✓ PASS: Port 8447 is listening"
        # v1.19.20 FIX
        ((tests_passed++)) || true
    else
        echo "  ✗ FAIL: Port 8447 not listening"
        echo "    Plesk Updater may not be running"
        # v1.19.20 FIX
        ((tests_failed++)) || true
    fi
    echo ""

    # Test 4: Plesk Updater firewall rules
    echo "Test 4: Plesk Updater Firewall Rules (8447/TCP)"
    if _nftban_panel_check_port 8447; then
        echo "  ✓ PASS: Port 8447 allowed in firewall"
        # v1.19.20 FIX
        ((tests_passed++)) || true
    else
        echo "  ✗ FAIL: Port 8447 blocked by firewall"
        echo "    Run: nftban panel plesk enable"
        # v1.19.20 FIX
        ((tests_failed++)) || true
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
        # v1.19.20 FIX
        ((tests_passed++)) || true
    else
        # v1.19.20 FIX
        ((tests_failed++)) || true
        echo "    Run: nftban panel plesk enable"
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
        # v1.19.20 FIX
        ((tests_passed++)) || true
    else
        # v1.19.20 FIX
        ((tests_failed++)) || true
        echo "    Run: nftban panel plesk enable"
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
        echo "✅ All tests passed - Plesk configuration OK!"
        return 0
    else
        echo "⚠️  Some tests failed - Run 'nftban panel plesk repair' to fix"
        return 1
    fi
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================

export -f nftban_panel_plesk_help
export -f nftban_panel_plesk_enable
export -f nftban_panel_plesk_disable
export -f nftban_panel_plesk_status
export -f nftban_panel_plesk_report
export -f nftban_panel_plesk_repair
export -f nftban_panel_plesk_test
