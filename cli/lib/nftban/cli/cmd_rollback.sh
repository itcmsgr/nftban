#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.18.3 - Rollback CLI Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Restore previous firewall state - enterprise safety net
#
# meta:name="cmd_rollback"
# meta:type="cli"
# meta:header="Rollback Command"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Rollback NFTBan and restore previous firewall authority"
# meta:input="Target firewall to restore (fail2ban, csf, ufw, firewalld, none)"
# meta:output="Restored firewall state"
#
# meta:inventory.files=""
# meta:inventory.binaries="systemctl,nft"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units="fail2ban.service,csf.service,ufw.service,firewalld.service"
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2026-02-20"
# meta:updated_date="2026-02-20"
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# HELP
# =============================================================================

_rollback_help() {
    cat <<'HELP'

USAGE:
    nftban rollback <action> [options]

ACTIONS:
    show                Show current state and available rollback options
    flush               Flush NFTBan tables (emergency - keeps services)
    disable             Disable NFTBan services (keeps tables)
    full                Full rollback: disable services + flush tables

RESTORE PREVIOUS FIREWALL:
    restore fail2ban    Re-enable fail2ban after NFTBan removal
    restore csf         Re-enable CSF/LFD after NFTBan removal
    restore ufw         Re-enable UFW after NFTBan removal
    restore firewalld   Re-enable firewalld after NFTBan removal

OPTIONS:
    --yes               Skip confirmation prompts
    --json              Output in JSON format

EXAMPLES:
    nftban rollback show                    # Show rollback options
    nftban rollback flush --yes             # Emergency flush all tables
    nftban rollback full --yes              # Complete NFTBan disable
    nftban rollback restore fail2ban        # Re-enable fail2ban

ENTERPRISE SAFETY NET:
    This command provides deterministic rollback for enterprise environments.

    If NFTBan is causing issues:
    1. nftban rollback flush           # Immediate - flush all blocking rules
    2. nftban rollback disable         # Stop NFTBan services
    3. nftban rollback restore <tool>  # Re-enable previous firewall

COMPLETE REMOVAL:
    To completely remove NFTBan from the system:

    # DEB systems:
    apt-get remove --purge nftban-core

    # RPM systems:
    dnf remove nftban-core

    # Or use the uninstall script:
    /usr/lib/nftban/uninstall.sh --purge

HELP
}

# =============================================================================
# ROLLBACK FUNCTIONS
# =============================================================================

_rollback_show() {
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  NFTBan Rollback Status"
    echo "═══════════════════════════════════════════════════════════"
    echo ""

    # Current NFTBan state
    echo "CURRENT STATE:"
    echo "──────────────────────────────────────────────────────────"

    # Check services
    local nftband_active="no"
    if systemctl is-active --quiet nftband.service 2>/dev/null; then
        nftband_active="yes"
    fi
    echo "  NFTBand daemon:     $nftband_active"

    # Check tables
    local tables_exist="no"
    if nft list table ip nftban &>/dev/null; then
        tables_exist="yes"
    fi
    echo "  NFTBan tables:      $tables_exist"

    # Count blocked IPs
    local blocked_v4=0 blocked_v6=0
    if [[ "$tables_exist" == "yes" ]]; then
        blocked_v4=$(timeout 10s nft list set ip nftban blacklist_ipv4 2>/dev/null | tr ',' '\n' | grep -cE '^[0-9]' || echo "0")
        blocked_v6=$(timeout 10s nft list set ip6 nftban blacklist_ipv6 2>/dev/null | tr ',' '\n' | grep -cE '^[0-9a-f]' || echo "0")
    fi
    echo "  Blocked IPs:        IPv4=$blocked_v4, IPv6=$blocked_v6"

    echo ""
    echo "DETECTED PREVIOUS FIREWALLS:"
    echo "──────────────────────────────────────────────────────────"

    # Check for installed but disabled firewalls
    local found=0

    if command -v fail2ban-client &>/dev/null; then
        local f2b_state="installed"
        if systemctl is-enabled --quiet fail2ban 2>/dev/null; then
            f2b_state="enabled"
        fi
        if systemctl is-active --quiet fail2ban 2>/dev/null; then
            f2b_state="ACTIVE"
        fi
        echo "  fail2ban:           $f2b_state"
        found=$((found + 1))
    fi

    if [[ -f /etc/csf/csf.conf ]] || command -v csf &>/dev/null; then
        local csf_state="installed"
        if systemctl is-enabled --quiet lfd 2>/dev/null; then
            csf_state="enabled"
        fi
        if systemctl is-active --quiet lfd 2>/dev/null; then
            csf_state="ACTIVE"
        fi
        echo "  CSF/LFD:            $csf_state"
        found=$((found + 1))
    fi

    if command -v ufw &>/dev/null; then
        local ufw_state="installed"
        if ufw status 2>/dev/null | grep -q "Status: active"; then
            ufw_state="ACTIVE"
        fi
        echo "  UFW:                $ufw_state"
        found=$((found + 1))
    fi

    if command -v firewall-cmd &>/dev/null; then
        local fwd_state="installed"
        if systemctl is-enabled --quiet firewalld 2>/dev/null; then
            fwd_state="enabled"
        fi
        if systemctl is-active --quiet firewalld 2>/dev/null; then
            fwd_state="ACTIVE"
        fi
        echo "  firewalld:          $fwd_state"
        found=$((found + 1))
    fi

    if [[ $found -eq 0 ]]; then
        echo "  (none detected)"
    fi

    echo ""
    echo "ROLLBACK OPTIONS:"
    echo "──────────────────────────────────────────────────────────"
    echo "  nftban rollback flush           # Emergency: flush all blocks"
    echo "  nftban rollback disable         # Stop NFTBan services"
    echo "  nftban rollback full            # Complete rollback"
    echo "  nftban rollback restore <tool>  # Re-enable previous firewall"
    echo ""
}

_rollback_flush() {
    local skip_confirm="${1:-false}"

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  EMERGENCY FLUSH - NFTBan Tables"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    echo "This will:"
    echo "  • Flush ALL blocked IPs from nftban tables"
    echo "  • Restore system whitelist (anti-lockout)"
    echo "  • Keep NFTBan services running"
    echo ""

    if [[ "$skip_confirm" != "true" ]]; then
        read -r -p "Proceed? [y/N] " response
        if [[ ! "$response" =~ ^[yY] ]]; then
            echo "Cancelled."
            return 1
        fi
    fi

    echo ""
    echo "Flushing NFTBan tables..."

    # Flush blacklists
    nft flush set ip nftban blacklist_ipv4 2>/dev/null && echo "  [OK] Flushed blacklist_ipv4"
    nft flush set ip6 nftban blacklist_ipv6 2>/dev/null && echo "  [OK] Flushed blacklist_ipv6"

    # Flush DDoS/portscan sets if exist
    nft flush set ip nftban ddos_blocked 2>/dev/null && echo "  [OK] Flushed ddos_blocked"
    nft flush set ip nftban portscan_blocked 2>/dev/null && echo "  [OK] Flushed portscan_blocked"

    # Restore system whitelist
    echo ""
    echo "Restoring system whitelist..."
    if command -v nftban &>/dev/null; then
        nftban whitelist-system sync 2>/dev/null || true
    fi

    echo ""
    echo "[OK] Emergency flush complete"
    echo ""
    echo "NFTBan services still running - to fully disable:"
    echo "  nftban rollback disable"
    echo ""
}

_rollback_disable() {
    local skip_confirm="${1:-false}"

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  DISABLE NFTBan Services"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    echo "This will:"
    echo "  • Stop nftband daemon"
    echo "  • Disable all NFTBan timers"
    echo "  • Keep nftables tables (for inspection)"
    echo ""

    if [[ "$skip_confirm" != "true" ]]; then
        read -r -p "Proceed? [y/N] " response
        if [[ ! "$response" =~ ^[yY] ]]; then
            echo "Cancelled."
            return 1
        fi
    fi

    echo ""
    echo "Stopping NFTBan services..."

    # Stop daemon
    systemctl stop nftband.socket 2>/dev/null && echo "  [OK] Stopped nftband.socket"
    systemctl stop nftband.service 2>/dev/null && echo "  [OK] Stopped nftband.service"

    # Disable daemon
    systemctl disable nftband.socket 2>/dev/null && echo "  [OK] Disabled nftband.socket"
    systemctl disable nftband.service 2>/dev/null && echo "  [OK] Disabled nftband.service"

    # Stop timers
    for timer in nftban-maintenance nftban-health nftban-unified-exporter nftban-rbl nftban-geoip; do
        systemctl stop "${timer}.timer" 2>/dev/null && echo "  [OK] Stopped ${timer}.timer"
        systemctl disable "${timer}.timer" 2>/dev/null || true
    done

    # Stop login monitor
    systemctl stop nftban-login-monitor.service 2>/dev/null && echo "  [OK] Stopped login monitor"
    systemctl disable nftban-login-monitor.service 2>/dev/null || true

    echo ""
    echo "[OK] NFTBan services disabled"
    echo ""
    echo "Tables still exist - to also flush tables:"
    echo "  nftban rollback flush"
    echo ""
    echo "To completely remove:"
    echo "  apt-get remove --purge nftban-core   # DEB"
    echo "  dnf remove nftban-core               # RPM"
    echo ""
}

_rollback_full() {
    local skip_confirm="${1:-false}"

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  FULL ROLLBACK - Complete NFTBan Disable"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    echo "This will:"
    echo "  • Flush ALL nftban tables (removes all blocks)"
    echo "  • Delete nftban nftables tables"
    echo "  • Stop and disable all NFTBan services"
    echo "  • System will have NO FIREWALL after this"
    echo ""
    echo "⚠️  WARNING: System will be UNPROTECTED until you:"
    echo "    1. Re-enable another firewall, OR"
    echo "    2. Reinstall NFTBan"
    echo ""

    if [[ "$skip_confirm" != "true" ]]; then
        read -r -p "Type 'ROLLBACK' to confirm: " response
        if [[ "$response" != "ROLLBACK" ]]; then
            echo "Cancelled."
            return 1
        fi
    fi

    echo ""

    # Disable services first
    echo "Step 1: Disabling NFTBan services..."
    _rollback_disable true

    # Delete tables
    echo "Step 2: Removing nftables tables..."
    nft delete table ip nftban 2>/dev/null && echo "  [OK] Deleted table ip nftban"
    nft delete table ip6 nftban 2>/dev/null && echo "  [OK] Deleted table ip6 nftban"

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  FULL ROLLBACK COMPLETE"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    echo "⚠️  System has NO ACTIVE FIREWALL"
    echo ""
    echo "To restore protection, choose ONE:"
    echo ""
    echo "  Option 1: Re-enable previous firewall"
    echo "    nftban rollback restore fail2ban"
    echo "    nftban rollback restore csf"
    echo "    nftban rollback restore ufw"
    echo "    nftban rollback restore firewalld"
    echo ""
    echo "  Option 2: Reinstall NFTBan"
    echo "    apt-get install --reinstall nftban-core   # DEB"
    echo "    dnf reinstall nftban-core                 # RPM"
    echo ""
}

_rollback_restore() {
    local target="${1:-}"
    local skip_confirm="${2:-false}"

    if [[ -z "$target" ]]; then
        echo "Error: Specify firewall to restore: fail2ban, csf, ufw, firewalld"
        return 1
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  RESTORE: $target"
    echo "═══════════════════════════════════════════════════════════"
    echo ""

    case "$target" in
        fail2ban)
            if ! command -v fail2ban-client &>/dev/null; then
                echo "Error: fail2ban is not installed"
                echo "Install: apt-get install fail2ban  # DEB"
                echo "         dnf install fail2ban      # RPM"
                return 1
            fi

            echo "Restoring fail2ban..."
            systemctl unmask fail2ban 2>/dev/null || true
            systemctl enable fail2ban 2>/dev/null && echo "  [OK] Enabled fail2ban"
            systemctl start fail2ban 2>/dev/null && echo "  [OK] Started fail2ban"

            echo ""
            echo "fail2ban status:"
            fail2ban-client status 2>/dev/null || echo "  (check with: fail2ban-client status)"
            ;;

        csf)
            if ! command -v csf &>/dev/null; then
                echo "Error: CSF is not installed"
                return 1
            fi

            echo "Restoring CSF/LFD..."
            csf -e 2>/dev/null && echo "  [OK] Enabled CSF"
            systemctl enable lfd 2>/dev/null || true
            systemctl start lfd 2>/dev/null && echo "  [OK] Started LFD"

            echo ""
            echo "CSF status:"
            csf -s 2>/dev/null || echo "  (check with: csf -s)"
            ;;

        ufw)
            if ! command -v ufw &>/dev/null; then
                echo "Error: UFW is not installed"
                echo "Install: apt-get install ufw"
                return 1
            fi

            echo "Restoring UFW..."
            ufw --force enable 2>/dev/null && echo "  [OK] Enabled UFW"

            echo ""
            echo "UFW status:"
            ufw status 2>/dev/null
            ;;

        firewalld)
            if ! command -v firewall-cmd &>/dev/null; then
                echo "Error: firewalld is not installed"
                echo "Install: dnf install firewalld"
                return 1
            fi

            echo "Restoring firewalld..."
            systemctl unmask firewalld 2>/dev/null || true
            systemctl enable firewalld 2>/dev/null && echo "  [OK] Enabled firewalld"
            systemctl start firewalld 2>/dev/null && echo "  [OK] Started firewalld"

            echo ""
            echo "firewalld status:"
            firewall-cmd --state 2>/dev/null
            ;;

        *)
            echo "Unknown target: $target"
            echo "Valid options: fail2ban, csf, ufw, firewalld"
            return 1
            ;;
    esac

    echo ""
    echo "[OK] $target restored"
    echo ""
    echo "⚠️  IMPORTANT: NFTBan and $target cannot run together"
    echo "   To switch back to NFTBan, first disable $target"
    echo ""
}

# =============================================================================
# MAIN COMMAND HANDLER
# =============================================================================

nftban_cmd_rollback() {
    local action="${1:-}"
    shift || true

    # Parse options
    local skip_confirm=false
    local target=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes|-y)
                skip_confirm=true
                ;;
            --json)
                # Reserved for JSON output
                ;;
            --help|-h)
                _rollback_help
                return 0
                ;;
            *)
                if [[ -z "$target" ]]; then
                    target="$1"
                fi
                ;;
        esac
        shift
    done

    case "$action" in
        show|status)
            _rollback_show
            ;;
        flush)
            _rollback_flush "$skip_confirm"
            ;;
        disable)
            _rollback_disable "$skip_confirm"
            ;;
        full)
            _rollback_full "$skip_confirm"
            ;;
        restore)
            _rollback_restore "$target" "$skip_confirm"
            ;;
        help|--help|-h|"")
            _rollback_help
            ;;
        *)
            echo "Unknown action: $action"
            _rollback_help
            return 1
            ;;
    esac
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_cmd_rollback
