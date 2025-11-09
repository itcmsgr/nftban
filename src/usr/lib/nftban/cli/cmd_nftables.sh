#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.32.24 - NFTables Service Management CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Command-line interface for nftables service management
#
# meta:name=cmd_nftables
# meta:type=cli
# meta:header=NFTables Service CLI
# meta:version=0.32.24
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=CLI handler for nftables service management
# meta:input=Command line arguments (start, stop, restart, enable, disable, status)
# meta:output=Service management output
#
# **Inventory & Requirements**
# meta:depends=bash,systemctl,nft
#
# meta:created_date=2025-11-05
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

readonly NFTBAN_LIB_DIR="${NFTBAN_LIB_DIR:-/usr/lib/nftban}"
readonly NFTABLES_SERVICE="nftables.service"

# =============================================================================
# HELP TEXT
# =============================================================================

_nftban_nftables_help() {
    # Load output module for standard banner
    source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"

    # Show standard banner
    nftban_banner

    cat <<'HELP'

USAGE:
    nftban nftables <command>

COMMANDS:
    start               Start nftables service
    stop                Stop nftables service
    restart             Restart nftables service
    reload              Reload nftables ruleset

    enable              Enable nftables service at boot
    disable             Disable nftables service at boot

    status              Show nftables service status
    check               Check nftables configuration
    list                List current nftables ruleset

    help                Show this help message

DESCRIPTION:
    Manage the nftables firewall service. NFTBan uses nftables as its
    underlying firewall system. These commands allow you to control the
    nftables systemd service and view the current ruleset.

EXAMPLES:
    # Check nftables status
    nftban nftables status

    # Restart nftables service
    sudo nftban nftables restart

    # Enable nftables at boot
    sudo nftban nftables enable

    # View current ruleset
    nftban nftables list

    # Check configuration
    sudo nftban nftables check

NOTES:
    - Most commands require root privileges
    - NFTBan manages nftables rules automatically
    - Manual changes to nftables rules may be overwritten by NFTBan

SERVICE INFORMATION:
    Service:  nftables.service
    Binary:   /usr/sbin/nft
    Config:   /etc/nftables/nftban.nft

HELP
}

# =============================================================================
# COMMAND FUNCTIONS
# =============================================================================

_nftban_nftables_cmd_start() {
    echo "Starting nftables service..."
    systemctl start "${NFTABLES_SERVICE}"
    local result=$?

    if [[ $result -eq 0 ]]; then
        echo "✓ nftables service started successfully"
    else
        echo "ERROR: Failed to start nftables service" >&2
        return $result
    fi
}

_nftban_nftables_cmd_stop() {
    echo "Stopping nftables service..."
    systemctl stop "${NFTABLES_SERVICE}"
    local result=$?

    if [[ $result -eq 0 ]]; then
        echo "✓ nftables service stopped successfully"
    else
        echo "ERROR: Failed to stop nftables service" >&2
        return $result
    fi
}

_nftban_nftables_cmd_restart() {
    echo "Restarting nftables service..."
    systemctl restart "${NFTABLES_SERVICE}"
    local result=$?

    if [[ $result -eq 0 ]]; then
        echo "✓ nftables service restarted successfully"
    else
        echo "ERROR: Failed to restart nftables service" >&2
        return $result
    fi
}

_nftban_nftables_cmd_reload() {
    echo "Reloading nftables ruleset..."
    systemctl reload "${NFTABLES_SERVICE}" 2>/dev/null || nft -f /etc/nftables/nftban.nft
    local result=$?

    if [[ $result -eq 0 ]]; then
        echo "✓ nftables ruleset reloaded successfully"
    else
        echo "ERROR: Failed to reload nftables ruleset" >&2
        return $result
    fi
}

_nftban_nftables_cmd_enable() {
    echo "Enabling nftables service at boot..."
    systemctl enable "${NFTABLES_SERVICE}"
    local result=$?

    if [[ $result -eq 0 ]]; then
        echo "✓ nftables service enabled at boot"
    else
        echo "ERROR: Failed to enable nftables service" >&2
        return $result
    fi
}

_nftban_nftables_cmd_disable() {
    echo "Disabling nftables service at boot..."
    systemctl disable "${NFTABLES_SERVICE}"
    local result=$?

    if [[ $result -eq 0 ]]; then
        echo "✓ nftables service disabled at boot"
    else
        echo "ERROR: Failed to disable nftables service" >&2
        return $result
    fi
}

_nftban_nftables_cmd_status() {
    echo "NFTables Service Status:"
    echo "════════════════════════════════════════════════════════════"
    echo ""

    systemctl status "${NFTABLES_SERVICE}" --no-pager

    echo ""
    echo "NFTables Binary:"
    echo "────────────────────────────────────────────────────────────"
    if command -v nft &>/dev/null; then
        echo "  Location: $(command -v nft)"
        echo "  Version:  $(nft --version 2>&1 | head -1)"
    else
        echo "  ERROR: nft binary not found" >&2
    fi

    echo ""
    echo "Boot Status:"
    echo "────────────────────────────────────────────────────────────"
    if systemctl is-enabled "${NFTABLES_SERVICE}" &>/dev/null; then
        echo "  Enabled at boot: ✓ YES"
    else
        echo "  Enabled at boot: ✗ NO"
    fi
}

_nftban_nftables_cmd_check() {
    echo "Checking nftables configuration..."
    echo ""

    # Check if nft binary exists
    if ! command -v nft &>/dev/null; then
        echo "ERROR: nft binary not found" >&2
        echo "Install nftables: sudo dnf install nftables" >&2
        return 1
    fi

    # Check if service is installed
    if ! systemctl list-unit-files | grep -q "${NFTABLES_SERVICE}"; then
        echo "WARNING: nftables service not found"
        return 1
    fi

    # Check configuration syntax
    if [[ -f /etc/nftables/nftban.nft ]]; then
        echo "Checking NFTBan configuration..."
        nft -c -f /etc/nftables/nftban.nft
        if [[ $? -eq 0 ]]; then
            echo "✓ Configuration syntax is valid"
        else
            echo "ERROR: Configuration syntax error" >&2
            return 1
        fi
    fi

    # Check if service is active
    if systemctl is-active "${NFTABLES_SERVICE}" &>/dev/null; then
        echo "✓ Service is running"
    else
        echo "WARNING: Service is not running"
    fi

    echo ""
    echo "✓ All checks passed"
}

_nftban_nftables_cmd_list() {
    echo "Current NFTables Ruleset:"
    echo "════════════════════════════════════════════════════════════"
    echo ""

    if ! command -v nft &>/dev/null; then
        echo "ERROR: nft binary not found" >&2
        return 1
    fi

    nft list ruleset
}

# =============================================================================
# MAIN COMMAND HANDLER
# =============================================================================

nftban_cmd_nftables() {
    local action="${1:-help}"
    shift || true

    case "$action" in
        start)
            if [[ $EUID -ne 0 ]]; then
                echo "ERROR: This command requires root privileges" >&2
                exit 1
            fi
            _nftban_nftables_cmd_start
            ;;

        stop)
            if [[ $EUID -ne 0 ]]; then
                echo "ERROR: This command requires root privileges" >&2
                exit 1
            fi
            _nftban_nftables_cmd_stop
            ;;

        restart)
            if [[ $EUID -ne 0 ]]; then
                echo "ERROR: This command requires root privileges" >&2
                exit 1
            fi
            _nftban_nftables_cmd_restart
            ;;

        reload)
            if [[ $EUID -ne 0 ]]; then
                echo "ERROR: This command requires root privileges" >&2
                exit 1
            fi
            _nftban_nftables_cmd_reload
            ;;

        enable)
            if [[ $EUID -ne 0 ]]; then
                echo "ERROR: This command requires root privileges" >&2
                exit 1
            fi
            _nftban_nftables_cmd_enable
            ;;

        disable)
            if [[ $EUID -ne 0 ]]; then
                echo "ERROR: This command requires root privileges" >&2
                exit 1
            fi
            _nftban_nftables_cmd_disable
            ;;

        status)
            _nftban_nftables_cmd_status
            ;;

        check)
            if [[ $EUID -ne 0 ]]; then
                echo "ERROR: This command requires root privileges" >&2
                exit 1
            fi
            _nftban_nftables_cmd_check
            ;;

        list)
            _nftban_nftables_cmd_list
            ;;

        help|--help|-h)
            _nftban_nftables_help
            ;;

        *)
            echo "ERROR: Unknown command: $action" >&2
            echo "" >&2
            echo "Run 'nftban nftables help' for available commands" >&2
            exit 1
            ;;
    esac

    return 0
}

# =============================================================================
# EXPORT FOR MAIN CLI
# =============================================================================
export -f nftban_cmd_nftables
