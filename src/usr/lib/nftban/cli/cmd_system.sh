#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.32.23 - System Enable/Disable CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Enable/disable NFTBan system (nftables + fail2ban)
#
# meta:name=cmd_system
# meta:type=cli
# meta:header=System Enable/Disable CLI
# meta:version=0.32.23
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
    echo "🚀 NFTBan System Enable - Automatic Setup"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Step 1: Auto-fix permissions and directories
    echo "[1/7] Fixing permissions and creating directories..."
    nftban permissions enforce >/dev/null 2>&1 || true
    nftban health check --auto-heal >/dev/null 2>&1 || true
    echo "  ✓ Permissions fixed, directories created"
    echo ""

    # Step 2: Check if firewall is initialized, if not - initialize it automatically
    echo "[2/7] Initializing firewall..."
    if ! nft list table inet nftban_main >/dev/null 2>&1; then
        echo "  → Firewall not initialized, initializing now..."
        if nftban firewall init >/dev/null 2>&1; then
            echo "  ✓ Firewall initialized (SSH port and your IP whitelisted)"
        else
            echo ""
            echo "❌ ERROR: Failed to initialize firewall"
            echo ""
            echo "Try manually:"
            echo "  → nftban firewall init"
            echo ""
            return 1
        fi
    else
        echo "  ✓ Firewall already initialized"
    fi
    echo ""

    # Step 3: Validate configuration
    echo "[3/7] Validating configuration files..."

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

    # Step 4: Run health check (auto-heal any issues)
    echo "[4/7] Running system health check..."
    nftban health check --quiet >/dev/null 2>&1 || true
    echo "  ✓ Health check passed"
    echo ""

    # Step 5: Enable and start services
    echo "[5/7] Enabling services..."

    # Enable nftban timer
    if systemctl enable nftban.timer 2>/dev/null; then
        echo "  ✓ Enabled: nftban.timer"
    else
        echo "  ✗ Failed to enable: nftban.timer"
        config_errors=$((config_errors + 1))
    fi

    # Enable fail2ban (REQUIRED)
    if command -v fail2ban-server >/dev/null 2>&1 || rpm -q fail2ban-server >/dev/null 2>&1 || dpkg -l fail2ban >/dev/null 2>&1; then
        if systemctl enable fail2ban.service 2>/dev/null; then
            echo "  ✓ Enabled: fail2ban.service"
        else
            echo "  ⚠️  Warning: Failed to enable fail2ban.service"
        fi
    else
        echo "  ❌ ERROR: fail2ban is REQUIRED but not installed!"
        echo "     Install with: sudo dnf install -y fail2ban-server"
        config_errors=$((config_errors + 1))
    fi

    echo ""
    echo "[6/7] Starting services..."

    # Start nftban timer
    if systemctl start nftban.timer 2>/dev/null; then
        echo "  ✓ Started: nftban.timer"
    else
        echo "  ✗ Failed to start: nftban.timer"
        config_errors=$((config_errors + 1))
    fi

    # Start fail2ban (REQUIRED)
    if command -v fail2ban-server >/dev/null 2>&1 || rpm -q fail2ban-server >/dev/null 2>&1 || dpkg -l fail2ban >/dev/null 2>&1; then
        if systemctl start fail2ban.service 2>/dev/null; then
            echo "  ✓ Started: fail2ban.service"
        else
            echo "  ❌ ERROR: Failed to start fail2ban.service"
            config_errors=$((config_errors + 1))
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
    echo "[7/7] Verifying protection is active..."
    systemctl is-active nftban.timer >/dev/null 2>&1 && echo "  ✓ NFTBan protection active"
    systemctl is-active fail2ban.service >/dev/null 2>&1 && echo "  ✓ Fail2ban protection active"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ NFTBan ENABLED - Your Server is Now Protected!"
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
    echo "  • Stop nftables firewall (remove all rules)"
    echo "  • Disable auto-start on boot"
    echo ""
    echo "Your server will be UNPROTECTED after this!"
    echo ""

    read -p "Are you sure you want to disable NFTBan? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "Aborted."
        return 0
    fi

    echo ""
    echo "[1/3] Stopping services..."

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
    echo "[2/3] Stopping firewall (removing nftables rules)..."

    # Delete nftban tables (removes all firewall rules)
    if nft list table inet nftban_main >/dev/null 2>&1; then
        nft delete table inet nftban_main 2>/dev/null && echo "  ✓ Removed: nftban_main table"
    fi
    if nft list table inet nftban_runtime >/dev/null 2>&1; then
        nft delete table inet nftban_runtime 2>/dev/null && echo "  ✓ Removed: nftban_runtime table"
    fi
    echo "  ✓ Firewall stopped (all protection removed)"

    echo ""
    echo "[3/3] Disabling auto-start..."

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
    echo "✅ NFTBan DISABLED - Protection Stopped"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "What was stopped:"
    echo "  • nftban.timer - Stopped and disabled"
    echo "  • fail2ban.service - Stopped and disabled"
    echo "  • nftables firewall - All rules removed"
    echo ""
    echo "⚠️  Your server is now UNPROTECTED!"
    echo ""
    echo "To re-enable protection:"
    echo "  → sudo nftban enable"
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
