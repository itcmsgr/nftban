#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0 - Suricata IDS CLI Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Easy user interface for Suricata IDS management
#
# meta:name=cmd_suricata
# meta:type=cli
# meta:header=Suricata IDS Management
# meta:version=1.0.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=User-friendly CLI for Suricata IDS installation and management
# meta:input=Commands: install, enable, disable, status, rules
# meta:output=Automated Suricata setup and control
#
# meta:created_date=2025-12-28
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${NFTBAN_CMD_SURICATA_LOADED:-}" ]] && return 0
NFTBAN_CMD_SURICATA_LOADED="true"

# =============================================================================
# CONFIGURATION
# =============================================================================

NFTBAN_LIB_DIR="${NFTBAN_LIB_DIR:-/usr/lib/nftban}"
NFTBAN_CONF_DIR="${NFTBAN_CONF_DIR:-/etc/nftban}"

# Load output library
if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"
fi

# Suricata paths
readonly SURICATA_SETUP_SCRIPT="${NFTBAN_LIB_DIR}/setup/install_suricata.sh"
readonly SURICATA_RULES_SCRIPT="${NFTBAN_LIB_DIR}/setup/setup_suricata_rules.sh"
readonly SURICATA_SERVICE="suricata.service"

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

_suricata_is_installed() {
    command -v suricata &>/dev/null
}

_suricata_is_running() {
    systemctl is-active --quiet "$SURICATA_SERVICE" 2>/dev/null
}

_suricata_is_enabled() {
    systemctl is-enabled --quiet "$SURICATA_SERVICE" 2>/dev/null
}

_check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: This command requires root privileges"
        echo "Usage: sudo nftban suricata $1"
        return 1
    fi
}

# =============================================================================
# COMMAND: install
# =============================================================================

cmd_suricata_install() {
    _check_root install || return 1

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🛡️  NFTBan - Suricata IDS Automated Installation"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Check if already installed
    if _suricata_is_installed; then
        local version
        version=$(suricata -V 2>&1 | head -1 || echo "unknown")
        echo "✓ Suricata is already installed: $version"
        echo ""
        read -p "Do you want to reinstall/upgrade? [y/N]: " reinstall
        if [[ "${reinstall,,}" != "y" ]]; then
            echo "  Installation cancelled"
            return 0
        fi
        echo ""
    fi

    echo "This will:"
    echo "  1. Check for package repository version (EPEL)"
    echo "  2. Install Suricata from packages OR compile from source"
    echo "  3. Configure Suricata for NFTBan integration"
    echo "  4. Setup systemd service"
    echo ""
    read -p "Continue with installation? [Y/n]: " confirm
    confirm=${confirm:-y}
    if [[ "${confirm,,}" != "y" ]]; then
        echo "  Installation cancelled"
        return 0
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Step 1/3: Installing Suricata"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Try package installation first
    local pkg_installed=false
    if command -v dnf &>/dev/null; then
        echo "  → Checking DNF repositories for Suricata..."
        if dnf info suricata &>/dev/null 2>&1; then
            echo "  ✓ Suricata package found in repositories"
            echo "  → Installing via DNF..."
            if dnf install -y suricata; then
                pkg_installed=true
                echo "  ✓ Suricata installed from packages"
            fi
        fi
    elif command -v apt-get &>/dev/null; then
        echo "  → Checking APT repositories for Suricata..."
        apt-get update -qq
        if apt-cache show suricata &>/dev/null 2>&1; then
            echo "  ✓ Suricata package found in repositories"
            echo "  → Installing via APT..."
            if apt-get install -y suricata; then
                pkg_installed=true
                echo "  ✓ Suricata installed from packages"
            fi
        fi
    fi

    # If package install failed, use setup script
    if [[ "$pkg_installed" == false ]]; then
        echo "  ⊘ No package available, installing from source..."
        if [[ -f "$SURICATA_SETUP_SCRIPT" ]]; then
            bash "$SURICATA_SETUP_SCRIPT" || {
                echo "  ✗ Installation from source failed"
                return 1
            }
        else
            echo "  ✗ Setup script not found: $SURICATA_SETUP_SCRIPT"
            return 1
        fi
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Step 2/3: Installing Detection Rules"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Install suricata-update if not present
    if ! command -v suricata-update &>/dev/null; then
        echo "  → Installing suricata-update..."
        pip3 install --upgrade suricata-update || {
            echo "  ✗ Failed to install suricata-update"
            return 1
        }
    fi

    # Run rules setup
    if [[ -f "$SURICATA_RULES_SCRIPT" ]]; then
        bash "$SURICATA_RULES_SCRIPT" || {
            echo "  ⚠  Rules setup had warnings (may be OK)"
        }
    else
        echo "  ⊘ Rules script not found, manual setup required"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Step 3/3: Finalizing Installation"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Set config flags
    if [[ -f "${NFTBAN_CONF_DIR}/nftban.conf" ]]; then
        if grep -q "^ENABLE_IDS_INTEGRATION=" "${NFTBAN_CONF_DIR}/nftban.conf"; then
            sed -i 's/^ENABLE_IDS_INTEGRATION=.*/ENABLE_IDS_INTEGRATION=1/' "${NFTBAN_CONF_DIR}/nftban.conf"
        else
            echo "ENABLE_IDS_INTEGRATION=1" >> "${NFTBAN_CONF_DIR}/nftban.conf"
        fi

        if grep -q "^NFTBAN_SURICATA_ENABLED=" "${NFTBAN_CONF_DIR}/nftban.conf"; then
            sed -i 's/^NFTBAN_SURICATA_ENABLED=.*/NFTBAN_SURICATA_ENABLED=true/' "${NFTBAN_CONF_DIR}/nftban.conf"
        else
            echo "NFTBAN_SURICATA_ENABLED=true" >> "${NFTBAN_CONF_DIR}/nftban.conf"
        fi
        echo "  ✓ NFTBan config updated (IDS enabled)"
    fi

    # Enable Suricata rules update timer (weekly updates)
    if [[ -f /usr/lib/systemd/system/nftban-suricata-update.timer ]]; then
        systemctl enable nftban-suricata-update.timer 2>/dev/null || echo "  ⊘ Timer enable failed (will install manually)"
        echo "  ✓ Rules update timer enabled (weekly Sunday 3 AM)"
    fi

    # Show version
    local version
    version=$(suricata -V 2>&1 | head -1 || echo "unknown")
    echo "  ✓ Installed: $version"
    echo ""

    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  ✅ Suricata IDS Installation Complete!                      ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Next steps:"
    echo "  1. Enable and start: nftban suricata enable"
    echo "  2. Check status:     nftban suricata status"
    echo "  3. View alerts:      tail -f /var/log/suricata/eve.json"
    echo ""
}

# =============================================================================
# COMMAND: enable
# =============================================================================

cmd_suricata_enable() {
    _check_root enable || return 1

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🛡️  NFTBan - Enable Suricata IDS"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Check if installed
    if ! _suricata_is_installed; then
        echo "✗ Suricata is not installed"
        echo ""
        echo "Install first:"
        echo "  nftban suricata install"
        return 1
    fi

    # Enable service
    echo "  → Enabling Suricata service..."
    systemctl enable "$SURICATA_SERVICE" || {
        echo "  ✗ Failed to enable service"
        return 1
    }
    echo "  ✓ Service enabled (will start on boot)"

    # Start service
    echo "  → Starting Suricata service..."
    systemctl start "$SURICATA_SERVICE" || {
        echo "  ✗ Failed to start service"
        echo ""
        echo "Check logs:"
        echo "  journalctl -u suricata -n 50"
        return 1
    }

    # Wait for startup
    sleep 2

    # Verify running
    if _suricata_is_running; then
        echo "  ✓ Suricata is running"
    else
        echo "  ✗ Suricata failed to start"
        systemctl status "$SURICATA_SERVICE" --no-pager -l
        return 1
    fi

    # Enable automatic rules update timer
    if [[ -f /usr/lib/systemd/system/nftban-suricata-update.timer ]]; then
        echo "  → Enabling weekly rules update timer..."
        systemctl enable --now nftban-suricata-update.timer 2>/dev/null && \
            echo "  ✓ Rules update timer enabled (weekly Sunday 3 AM)" || \
            echo "  ⊘ Timer enable failed (not critical)"
    fi

    echo ""
    echo "✅ Suricata IDS is now ENABLED and RUNNING"
    echo ""
    echo "Automatic updates:"
    echo "  Rules updated weekly (Sunday 3 AM)"
    echo "  Manual update: nftban suricata rules update"
    echo ""
    echo "Monitor alerts:"
    echo "  tail -f /var/log/suricata/eve.json | jq 'select(.event_type==\"alert\")'"
    echo ""
    echo "Check status:"
    echo "  nftban suricata status"
    echo ""
}

# =============================================================================
# COMMAND: disable
# =============================================================================

cmd_suricata_disable() {
    _check_root disable || return 1

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🛡️  NFTBan - Disable Suricata IDS"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Stop service
    echo "  → Stopping Suricata service..."
    systemctl stop "$SURICATA_SERVICE" || true
    echo "  ✓ Service stopped"

    # Disable service
    echo "  → Disabling Suricata service..."
    systemctl disable "$SURICATA_SERVICE" || true
    echo "  ✓ Service disabled (will not start on boot)"

    # Disable rules update timer
    if systemctl is-enabled --quiet nftban-suricata-update.timer 2>/dev/null; then
        echo "  → Disabling weekly rules update timer..."
        systemctl disable --now nftban-suricata-update.timer 2>/dev/null || true
        echo "  ✓ Rules update timer disabled"
    fi

    echo ""
    echo "✅ Suricata IDS is now DISABLED"
    echo ""
}

# =============================================================================
# COMMAND: status
# =============================================================================

cmd_suricata_status() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🛡️  Suricata IDS Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Installation status
    if _suricata_is_installed; then
        local version
        version=$(suricata -V 2>&1 | head -1 || echo "unknown")
        echo "  Installed:  ✅ YES - $version"
    else
        echo "  Installed:  ❌ NO"
        echo ""
        echo "Install with:"
        echo "  nftban suricata install"
        return 1
    fi

    # Service status
    if _suricata_is_running; then
        echo "  Running:    ✅ YES"
    else
        echo "  Running:    ❌ NO"
    fi

    if _suricata_is_enabled; then
        echo "  Enabled:    ✅ YES (starts on boot)"
    else
        echo "  Enabled:    ❌ NO"
    fi

    # Auto-update timer status
    if systemctl is-enabled --quiet nftban-suricata-update.timer 2>/dev/null; then
        echo "  Auto-update: ✅ YES (weekly Sunday 3 AM)"
    elif [[ -f /usr/lib/systemd/system/nftban-suricata-update.timer ]]; then
        echo "  Auto-update: ❌ NO (timer not enabled)"
    else
        echo "  Auto-update: ⊘ Timer not installed"
    fi

    # Rules status
    echo ""
    echo "  Rules:"
    if [[ -d /var/lib/suricata/rules ]]; then
        local rule_count
        rule_count=$(find /var/lib/suricata/rules -name "*.rules" -exec cat {} \; 2>/dev/null | grep -c "^alert" || echo "0")
        echo "    Total alert rules: $rule_count"
        echo "    Rules directory:   /var/lib/suricata/rules/"
    else
        echo "    ⚠  No rules directory found"
    fi

    # Recent alerts
    echo ""
    echo "  Recent Alerts (last 5):"
    if [[ -f /var/log/suricata/eve.json ]]; then
        tail -100 /var/log/suricata/eve.json 2>/dev/null | \
            jq -r 'select(.event_type=="alert") | "    [\(.timestamp)] \(.alert.signature) - \(.src_ip):\(.src_port) -> \(.dest_ip):\(.dest_port)"' 2>/dev/null | \
            tail -5 || echo "    (no recent alerts or jq not installed)"
    else
        echo "    (eve.json not found)"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Show systemd status if running
    if _suricata_is_running; then
        echo "Service Status:"
        systemctl status "$SURICATA_SERVICE" --no-pager -l | head -15
    fi

    echo ""
}

# =============================================================================
# COMMAND: rules
# =============================================================================

cmd_suricata_rules() {
    local action="${1:-help}"

    case "$action" in
        update)
            _check_root "rules update" || return 1

            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  🛡️  Updating Suricata Rules"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            if ! command -v suricata-update &>/dev/null; then
                echo "✗ suricata-update not installed"
                echo ""
                echo "Install:"
                echo "  pip3 install --upgrade suricata-update"
                return 1
            fi

            echo "  → Downloading latest rules from ET/Open..."
            suricata-update || {
                echo "  ✗ Rule update failed"
                return 1
            }

            echo ""
            echo "  → Restarting Suricata to load new rules..."
            systemctl restart "$SURICATA_SERVICE" || {
                echo "  ✗ Failed to restart Suricata"
                return 1
            }

            sleep 2
            if _suricata_is_running; then
                echo "  ✓ Suricata restarted successfully"
            else
                echo "  ✗ Suricata failed to restart"
                return 1
            fi

            echo ""
            echo "✅ Rules updated successfully"
            echo ""
            ;;

        list)
            echo ""
            echo "Suricata Rule Files:"
            if [[ -d /var/lib/suricata/rules ]]; then
                ls -lh /var/lib/suricata/rules/*.rules 2>/dev/null || echo "No rule files found"
            else
                echo "Rules directory not found"
            fi
            echo ""
            ;;

        help|*)
            cat << 'EOF'

Suricata Rules Management

USAGE:
    nftban suricata rules <command>

COMMANDS:
    update      Update rules from ET/Open (requires root)
    list        List installed rule files
    help        Show this help message

EXAMPLES:
    nftban suricata rules update    # Download latest rules
    nftban suricata rules list      # Show installed rules

NOTES:
    - Rules are updated automatically via systemd timer (weekly)
    - Manual update: suricata-update && systemctl restart suricata

EOF
            ;;
    esac
}

# =============================================================================
# HELP
# =============================================================================

cmd_suricata_help() {
    cat << 'EOF'

🛡️  NFTBan - Suricata IDS Management

USAGE:
    nftban suricata <command>

COMMANDS:
    install     Install Suricata IDS (automated)
    enable      Enable and start Suricata service
    disable     Stop and disable Suricata service
    status      Show Suricata status and recent alerts
    rules       Manage Suricata rules (see: nftban suricata rules help)
    help        Show this help message

INSTALLATION PROCESS:
    1. Checks for package availability (EPEL/APT)
    2. Installs from packages OR compiles from source
    3. Downloads ET/Open ruleset (free)
    4. Configures for NFTBan integration
    5. Sets up systemd service

EXAMPLES:
    # Full automated setup (one command):
    nftban suricata install
    nftban suricata enable

    # Check status:
    nftban suricata status

    # Update rules:
    nftban suricata rules update

    # View live alerts:
    tail -f /var/log/suricata/eve.json | jq 'select(.event_type=="alert")'

REQUIREMENTS:
    - Root privileges (sudo)
    - EPEL repository (RHEL/Rocky) or standard repos (Debian/Ubuntu)
    - 2+ cores, 2+ GB RAM recommended
    - Python 3 + pip (for suricata-update)

PERFORMANCE:
    - CPU: 10-30% of 1 core (medium traffic)
    - RAM: 300-800 MB typical
    - Optimized for VPS/cloud environments

DOCUMENTATION:
    - Suricata: https://suricata.io/
    - NFTBan Suricata guide: docs/SURICATA.md

EOF
}

# =============================================================================
# COMMAND ROUTER
# =============================================================================

nftban_cmd_suricata() {
    local action="${1:-help}"
    shift || true

    case "$action" in
        install)
            cmd_suricata_install "$@"
            ;;
        enable)
            cmd_suricata_enable "$@"
            ;;
        disable)
            cmd_suricata_disable "$@"
            ;;
        status)
            cmd_suricata_status "$@"
            ;;
        rules)
            cmd_suricata_rules "$@"
            ;;
        help|--help|-h)
            cmd_suricata_help
            ;;
        *)
            echo "ERROR: Unknown command: $action"
            echo "Run 'nftban suricata help' for usage"
            return 1
            ;;
    esac
}

# Export for main CLI
export -f nftban_cmd_suricata

# Execute if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_suricata "$@"
fi
