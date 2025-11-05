#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.30.0 - System Enable/Disable CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Enable/disable NFTBan system (nftables + fail2ban)
#
# meta:name=cmd_system
# meta:type=cli
# meta:header=System Enable/Disable CLI
# meta:version=0.30.1
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Enable or disable NFTBan system with comprehensive config validation
# meta:input=enable|disable command with safety checks
# meta:output=System status, validation results, and service management
#
# **Inventory & Requirements**
# meta:depends=bash,systemctl,nft,nftban_health.sh,nftban_firewall.sh
#
# meta:created_date=2025-11-05
# =============================================================================

# Enhanced strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# =============================================================================
# SYSTEM ENABLE - Check config and enable services
# =============================================================================

nftban_system_enable() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🚀 NFTBan System Enable"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Step 1: Check if firewall is initialized
    echo "[1/5] Checking firewall initialization..."
    if ! nft list table inet nftban_main >/dev/null 2>&1; then
        echo ""
        echo "❌ ERROR: Firewall not initialized"
        echo ""
        echo "Please run first:"
        echo "  → nftban firewall init"
        echo ""
        echo "This will:"
        echo "  • Auto-detect and whitelist SSH port"
        echo "  • Whitelist your current IP address"
        echo "  • Create nftables tables and rules"
        echo ""
        return 1
    fi
    echo "  ✓ Firewall initialized"
    echo ""

    # Step 2: Validate configuration
    echo "[2/5] Validating configuration files..."

    local config_errors=0

    # Check main config exists
    if [[ ! -f "/etc/nftban/nftban.conf" ]]; then
        echo "  ✗ Missing: /etc/nftban/nftban.conf"
        config_errors=$((config_errors + 1))
    fi

    # Check SSH port is whitelisted
    if [[ ! -f "/etc/nftban/ports.d/00-ssh.conf" ]]; then
        echo "  ⚠️  WARNING: SSH port not whitelisted"
        echo "     File missing: /etc/nftban/ports.d/00-ssh.conf"
        echo "     This is a LOCKOUT RISK!"
        config_errors=$((config_errors + 1))
    fi

    # Check at least one IP is whitelisted
    if [[ ! -f "/etc/nftban/whitelist.d/00-system.conf" ]]; then
        echo "  ⚠️  WARNING: No system IPs whitelisted"
        echo "     File missing: /etc/nftban/whitelist.d/00-system.conf"
        echo "     This is a LOCKOUT RISK!"
        config_errors=$((config_errors + 1))
    fi

    if [[ $config_errors -gt 0 ]]; then
        echo ""
        echo "❌ Configuration validation FAILED ($config_errors issues)"
        echo ""
        echo "Please fix the issues above before enabling."
        echo ""
        echo "Check configuration:"
        echo "  → nftban firewall check"
        echo "  → nftban health check"
        echo ""
        echo "Re-initialize if needed:"
        echo "  → nftban firewall init"
        echo ""
        return 1
    fi

    echo "  ✓ Configuration valid"
    echo ""

    # Step 3: Run health check
    echo "[3/5] Running system health check..."
    if ! nftban health check --quiet 2>/dev/null; then
        echo ""
        echo "⚠️  WARNING: Health check found issues"
        echo ""
        echo "Review health status:"
        echo "  → nftban health check"
        echo ""
        echo "Continue anyway? (not recommended)"
        read -p "Type 'yes' to continue: " confirm
        if [[ "$confirm" != "yes" ]]; then
            echo "Aborted."
            return 1
        fi
    else
        echo "  ✓ Health check passed"
    fi
    echo ""

    # Step 4: Enable and start services
    echo "[4/5] Enabling services..."

    # Enable nftban timer
    if systemctl enable nftban.timer 2>/dev/null; then
        echo "  ✓ Enabled: nftban.timer"
    else
        echo "  ✗ Failed to enable: nftban.timer"
        config_errors=$((config_errors + 1))
    fi

    # Enable fail2ban if installed
    if systemctl list-unit-files | grep -q "^fail2ban.service"; then
        if systemctl enable fail2ban.service 2>/dev/null; then
            echo "  ✓ Enabled: fail2ban.service"
        else
            echo "  ⚠️  Warning: Failed to enable fail2ban.service"
        fi
    else
        echo "  ⚠️  Fail2ban not installed (optional)"
    fi

    echo ""
    echo "[5/5] Starting services..."

    # Start nftban timer
    if systemctl start nftban.timer 2>/dev/null; then
        echo "  ✓ Started: nftban.timer"
    else
        echo "  ✗ Failed to start: nftban.timer"
        config_errors=$((config_errors + 1))
    fi

    # Start fail2ban if installed
    if systemctl list-unit-files | grep -q "^fail2ban.service"; then
        if systemctl start fail2ban.service 2>/dev/null; then
            echo "  ✓ Started: fail2ban.service"
        else
            echo "  ⚠️  Warning: Failed to start fail2ban.service"
        fi
    fi

    if [[ $config_errors -gt 0 ]]; then
        echo ""
        echo "❌ Enable FAILED with errors"
        echo ""
        echo "Check systemd status:"
        echo "  → systemctl status nftban.timer"
        echo "  → systemctl status fail2ban.service"
        echo ""
        echo "View logs:"
        echo "  → journalctl -u nftban.timer -n 50"
        echo "  → journalctl -u fail2ban.service -n 50"
        echo ""
        return 1
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ NFTBan System ENABLED Successfully"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Services running:"
    echo "  • nftban.timer     - Automatic maintenance (hourly)"
    echo "  • fail2ban.service - Intrusion prevention"
    echo ""
    echo "Check status:"
    echo "  → nftban status"
    echo "  → systemctl status nftban.timer"
    echo ""
    echo "View activity:"
    echo "  → journalctl -u nftban.timer -f"
    echo "  → tail -f /var/log/nftban/*.log"
    echo ""

    return 0
}

# =============================================================================
# SYSTEM DISABLE - Stop and disable services
# =============================================================================

nftban_system_disable() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🛑 NFTBan System Disable"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    echo "⚠️  WARNING: This will STOP all NFTBan protection!"
    echo ""
    echo "This will:"
    echo "  • Stop nftban.timer (no automatic updates)"
    echo "  • Stop fail2ban.service (no intrusion prevention)"
    echo "  • Disable auto-start on boot"
    echo ""
    echo "⚠️  Your firewall rules (nftables) will remain active."
    echo "⚠️  To remove firewall rules, run: nftban firewall stop"
    echo ""

    read -p "Are you sure you want to disable NFTBan? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "Aborted."
        return 0
    fi

    echo ""
    echo "[1/2] Stopping services..."

    # Stop nftban timer
    if systemctl stop nftban.timer 2>/dev/null; then
        echo "  ✓ Stopped: nftban.timer"
    else
        echo "  ⚠️  Warning: Failed to stop nftban.timer (may not be running)"
    fi

    # Stop fail2ban if installed and running
    if systemctl list-unit-files | grep -q "^fail2ban.service"; then
        if systemctl stop fail2ban.service 2>/dev/null; then
            echo "  ✓ Stopped: fail2ban.service"
        else
            echo "  ⚠️  Warning: Failed to stop fail2ban.service (may not be running)"
        fi
    fi

    echo ""
    echo "[2/2] Disabling auto-start..."

    # Disable nftban timer
    if systemctl disable nftban.timer 2>/dev/null; then
        echo "  ✓ Disabled: nftban.timer"
    else
        echo "  ⚠️  Warning: Failed to disable nftban.timer"
    fi

    # Disable fail2ban if installed
    if systemctl list-unit-files | grep -q "^fail2ban.service"; then
        if systemctl disable fail2ban.service 2>/dev/null; then
            echo "  ✓ Disabled: fail2ban.service"
        else
            echo "  ⚠️  Warning: Failed to disable fail2ban.service"
        fi
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ NFTBan System DISABLED"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Services stopped and disabled:"
    echo "  • nftban.timer (attack protection)"
    echo "  • fail2ban.service (intrusion prevention)"
    echo ""
    echo "ℹ️  NOTE: Maintenance timer still running (safety checks)"
    echo "   → nftban-maintenance.timer monitors SSH port and system health"
    echo "   → Runs even when NFTBan is disabled (lockout prevention)"
    echo ""
    echo "⚠️  NOTE: Firewall rules (nftables) are still active!"
    echo ""
    echo "To re-enable NFTBan:"
    echo "  → nftban enable"
    echo ""
    echo "To stop firewall completely:"
    echo "  → nftban firewall stop"
    echo ""

    return 0
}

# =============================================================================
# COMMAND HANDLER
# =============================================================================

nftban_cmd_system() {
    local action="${1:-}"

    case "$action" in
        enable)
            nftban_system_enable
            ;;
        disable)
            nftban_system_disable
            ;;
        *)
            echo "Usage: nftban system <enable|disable>"
            echo ""
            echo "Commands:"
            echo "  enable   - Enable and start NFTBan (with config validation)"
            echo "  disable  - Disable and stop NFTBan"
            echo ""
            return 1
            ;;
    esac
}

# Export function
export -f nftban_cmd_system
export -f nftban_system_enable
export -f nftban_system_disable
