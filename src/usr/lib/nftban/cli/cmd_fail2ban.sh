#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.31.0 - Fail2ban CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Command-line interface for Fail2ban integration management
#
# meta:name=cmd_fail2ban
# meta:type=cli
# meta:header=Fail2ban CLI
# meta:version=0.31.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=CLI handler for Fail2ban integration commands
# meta:input=Command line arguments (status, jails, enable, disable, etc.)
# meta:output=Fail2ban management output
#
# **Inventory & Requirements**
# meta:depends=bash,nftban_fail2ban.sh
#
# meta:created_date=2025-11-05
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

readonly NFTBAN_LIB_DIR="${NFTBAN_LIB_DIR:-/usr/lib/nftban}"

# Load fail2ban core module
if [[ ! $(type -t nftban_fail2ban_status) == "function" ]]; then
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_fail2ban.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_fail2ban.sh"
    else
        echo "ERROR: nftban_fail2ban.sh not found" >&2
        exit 1
    fi
fi

# =============================================================================
# HELP TEXT
# =============================================================================

_nftban_fail2ban_help() {
    # Load output module for standard banner
    source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"

    # Show standard banner
    nftban_banner

    cat <<'HELP'

USAGE:
    nftban fail2ban <command> [options]

COMMANDS:
    status              Show fail2ban status and statistics
    jails               List all currently enabled jails
    available           Show all available jails on this system
    recommended         Show recommended jails for your OS/services
    jail <name>         Show detailed status for specific jail

    enable <jail>       Enable/start a fail2ban jail
    disable <jail>      Disable/stop a fail2ban jail
    reload [jail]       Reload fail2ban or specific jail

    banned [jail]       List banned IPs (all jails or specific)
    ban <jail> <ip>     Manually ban an IP in a jail
    unban <jail> <ip>   Unban an IP from a jail

    cloudflare          Update Cloudflare IP whitelist

    start               Start fail2ban service
    stop                Stop fail2ban service
    restart             Restart fail2ban service

    help                Show this help message

DESCRIPTION:
    Integrate fail2ban with NFTBan for comprehensive protection.
    Manage fail2ban jails, monitor banned IPs, and synchronize with
    NFTBan's nftables rules.

COMMON JAILS:
    sshd                SSH brute force protection
    nginx-limit-req     Nginx rate limiting
    nginx-botsearch     Nginx bot/scanner protection
    apache-auth         Apache authentication failures
    postfix             Mail server protection
    dovecot             IMAP/POP3 protection

EXAMPLES:
    # Check fail2ban status
    nftban fail2ban status

    # List all jails
    nftban fail2ban jails

    # Enable SSH protection
    nftban fail2ban enable sshd

    # Check specific jail
    nftban fail2ban jail sshd

    # List all banned IPs
    nftban fail2ban banned

    # Unban specific IP
    nftban fail2ban unban sshd 192.0.2.100

    # Update Cloudflare whitelist
    nftban fail2ban cloudflare

CLOUDFLARE INTEGRATION:
    When Cloudflare integration is enabled, Cloudflare IPs are
    automatically whitelisted in fail2ban to prevent blocking
    legitimate traffic coming through Cloudflare proxy.

CONFIGURATION:
    /etc/nftban/conf.d/fail2ban.conf

NOTES:
    - Most commands require root privileges
    - Fail2ban must be installed and running
    - Changes are logged to /var/log/nftban/fail2ban.log

HELP
}

# =============================================================================
# COMMAND FUNCTIONS
# =============================================================================

_nftban_fail2ban_cmd_status() {
    # Show fail2ban status

    local status version total_banned os_info

    # Check if fail2ban is installed
    if ! nftban_fail2ban_is_installed; then
        echo "════════════════════════════════════════════════════════════"
        echo "  Fail2ban Status: NOT INSTALLED"
        echo "════════════════════════════════════════════════════════════"
        echo ""
        echo "Fail2ban is not installed on this system."
        echo ""
        echo "To install:"
        echo "  # Debian/Ubuntu"
        echo "  sudo apt-get install fail2ban"
        echo ""
        echo "  # RHEL/Rocky/AlmaLinux"
        echo "  sudo dnf install fail2ban"
        echo ""
        return 1
    fi

    status=$(nftban_fail2ban_status)
    version=$(nftban_fail2ban_version)
    os_info=$(nftban_fail2ban_detect_os)

    echo "════════════════════════════════════════════════════════════"
    echo "  Fail2ban Integration Status"
    echo "════════════════════════════════════════════════════════════"
    echo ""
    echo "Service Status: ${status}"
    echo "Version:        ${version}"
    echo "Detected OS:    ${os_info}"
    echo ""

    if [[ "$status" == "RUNNING" ]]; then
        # Get statistics
        total_banned=$(nftban_fail2ban_total_banned)
        local jail_count
        jail_count=$(nftban_fail2ban_list_jails | wc -l)

        echo "Active Jails:   ${jail_count}"
        echo "Total Banned:   ${total_banned} IPs"
        echo ""

        # List jails with status
        echo "Configured Jails:"
        echo "─────────────────────────────────────────────────────────"

        local jails
        mapfile -t jails < <(nftban_fail2ban_list_jails)

        if [[ ${#jails[@]} -eq 0 ]]; then
            echo "  (no jails configured)"
        else
            for jail in "${jails[@]}"; do
                local banned_count
                banned_count=$(nftban_fail2ban_jail_banned "$jail" | wc -l)
                printf "  %-20s  %3d banned\n" "$jail" "$banned_count"
            done
        fi

        echo ""
        echo "NFTBan Integration:"
        echo "─────────────────────────────────────────────────────────"
        echo "  Enabled:              ${FAIL2BAN_ENABLED}"
        echo "  Cloudflare Whitelist: ${FAIL2BAN_CLOUDFLARE_WHITELIST}"
        echo "  Sync to NFTBan:       ${FAIL2BAN_SYNC_TO_NFTABLES}"
        echo ""
    else
        echo "Fail2ban service is not running."
        echo ""
        echo "To start fail2ban:"
        echo "  sudo nftban fail2ban start"
        echo ""
    fi

    return 0
}

_nftban_fail2ban_cmd_jails() {
    # List all currently enabled jails

    if ! nftban_fail2ban_is_running; then
        echo "ERROR: fail2ban is not running" >&2
        echo "Start it with: sudo nftban fail2ban start" >&2
        return 1
    fi

    echo "Currently Enabled Fail2ban Jails:"
    echo "════════════════════════════════════════════════════════════"
    echo ""

    local jails
    mapfile -t jails < <(nftban_fail2ban_list_jails)

    if [[ ${#jails[@]} -eq 0 ]]; then
        echo "  No jails currently enabled"
        echo ""
        echo "  Use 'nftban fail2ban available' to see available jails"
        echo "  Use 'nftban fail2ban recommended' for recommendations"
        return 0
    fi

    printf "%-25s %-10s %s\n" "JAIL" "STATUS" "BANNED IPs"
    echo "────────────────────────────────────────────────────────────"

    for jail in "${jails[@]}"; do
        local status="active"
        local banned_count
        banned_count=$(nftban_fail2ban_jail_banned "$jail" | wc -l)

        printf "%-25s %-10s %d\n" "$jail" "$status" "$banned_count"
    done

    echo ""
}

_nftban_fail2ban_cmd_available() {
    # Show NFTBan-compatible jails (configured with nftables action)

    echo "NFTBan-Compatible Fail2ban Jails:"
    echo "════════════════════════════════════════════════════════════"
    echo ""
    echo "NOTE: This list shows ONLY jails configured to use NFTBan's"
    echo "      nftables action. System jails (sshd, apache-auth, etc.)"
    echo "      use iptables/firewalld by default and won't work with"
    echo "      NFTBan unless reconfigured with action = nftban[...]"
    echo ""

    local all_jails
    mapfile -t all_jails < <(nftban_fail2ban_list_all_available_jails)

    if [[ ${#all_jails[@]} -eq 0 ]]; then
        echo "  No NFTBan-compatible jail configurations found"
        echo ""
        echo "  NFTBan-compatible jails must be placed in:"
        echo "    /etc/fail2ban/jail.d/nftban-*.conf"
        echo ""
        echo "  Example: /etc/fail2ban/jail.d/nftban-sshd.conf"
        echo ""
        return 0
    fi

    printf "%-30s %s\n" "JAIL NAME" "STATUS"
    echo "────────────────────────────────────────────────────────────"

    for jail_entry in "${all_jails[@]}"; do
        local jail_name="${jail_entry%%:*}"
        local jail_status="${jail_entry##*:}"

        if [[ "$jail_status" == "enabled" ]]; then
            printf "%-30s ✓ %s\n" "$jail_name" "ENABLED"
        else
            printf "%-30s   %s\n" "$jail_name" "available"
        fi
    done

    echo ""
    echo "To enable a jail:"
    echo "  sudo nftban fail2ban enable <jail-name>"
    echo ""
}

_nftban_fail2ban_cmd_recommended() {
    # Show recommended jails based on OS and installed services

    local os_info=$(nftban_fail2ban_detect_os)
    local os_type="${os_info%%:*}"
    local os_version="${os_info##*:}"

    echo "Recommended Fail2ban Jails:"
    echo "════════════════════════════════════════════════════════════"
    echo ""
    echo "Detected System: ${os_type} ${os_version}"
    echo ""

    local recommended_jails
    mapfile -t recommended_jails < <(nftban_fail2ban_get_recommended_jails)

    if [[ ${#recommended_jails[@]} -eq 0 ]]; then
        echo "  No specific recommendations for this system"
        echo ""
        echo "  Use 'nftban fail2ban available' to see all available jails"
        return 0
    fi

    echo "Based on your installed services, we recommend enabling:"
    echo ""

    for jail in "${recommended_jails[@]}"; do
        # Check if already enabled
        local is_enabled=""
        if nftban_fail2ban_is_running && nftban_fail2ban_jail_is_enabled "$jail" 2>/dev/null; then
            is_enabled="✓ ENABLED"
        else
            is_enabled="  (not enabled)"
        fi

        printf "  %-30s %s\n" "$jail" "$is_enabled"
    done

    echo ""
    echo "To enable recommended jails:"
    echo "  sudo nftban fail2ban enable <jail-name>"
    echo ""
    echo "To enable all recommended jails at once:"
    echo "  for jail in ${recommended_jails[*]}; do"
    echo "    sudo nftban fail2ban enable \$jail"
    echo "  done"
    echo ""
}

_nftban_fail2ban_cmd_jail() {
    # Show detailed jail status
    local jail="$1"

    if ! nftban_fail2ban_is_running; then
        echo "ERROR: fail2ban is not running" >&2
        return 1
    fi

    nftban_fail2ban_jail_status "$jail"
}

_nftban_fail2ban_cmd_enable() {
    # Enable a jail
    local jail="$1"

    if ! nftban_fail2ban_is_running; then
        echo "ERROR: fail2ban is not running" >&2
        echo "Start it with: sudo systemctl start fail2ban" >&2
        return 1
    fi

    echo "Enabling jail: ${jail}..."
    nftban_fail2ban_jail_start "$jail"
}

_nftban_fail2ban_cmd_disable() {
    # Disable a jail
    local jail="$1"

    if ! nftban_fail2ban_is_running; then
        echo "ERROR: fail2ban is not running" >&2
        return 1
    fi

    echo "Disabling jail: ${jail}..."
    nftban_fail2ban_jail_stop "$jail"
}

_nftban_fail2ban_cmd_reload() {
    # Reload fail2ban or specific jail
    local jail="${1:-}"

    if ! nftban_fail2ban_is_running; then
        echo "ERROR: fail2ban is not running" >&2
        return 1
    fi

    if [[ -n "$jail" ]]; then
        echo "Reloading jail: ${jail}..."
        nftban_fail2ban_jail_reload "$jail"
    else
        echo "Reloading fail2ban configuration..."
        nftban_fail2ban_reload
    fi
}

_nftban_fail2ban_cmd_banned() {
    # List banned IPs
    local jail="${1:-}"

    if ! nftban_fail2ban_is_running; then
        echo "ERROR: fail2ban is not running" >&2
        return 1
    fi

    if [[ -n "$jail" ]]; then
        # Specific jail
        echo "Banned IPs in jail: ${jail}"
        echo "════════════════════════════════════════════════════════════"
        nftban_fail2ban_jail_banned "$jail"
    else
        # All jails
        echo "All Banned IPs:"
        echo "════════════════════════════════════════════════════════════"
        echo ""

        local jails
        mapfile -t jails < <(nftban_fail2ban_list_jails)

        for jail in "${jails[@]}"; do
            local banned_ips
            mapfile -t banned_ips < <(nftban_fail2ban_jail_banned "$jail")

            if [[ ${#banned_ips[@]} -gt 0 ]]; then
                echo "Jail: ${jail}"
                for ip in "${banned_ips[@]}"; do
                    echo "  ${ip}"
                done
                echo ""
            fi
        done
    fi
}

_nftban_fail2ban_cmd_ban() {
    # Manually ban an IP
    local jail="$1"
    local ip="$2"

    if ! nftban_fail2ban_is_running; then
        echo "ERROR: fail2ban is not running" >&2
        return 1
    fi

    echo "Banning ${ip} in jail ${jail}..."
    nftban_fail2ban_ban_ip "$jail" "$ip"
}

_nftban_fail2ban_cmd_unban() {
    # Unban an IP
    local jail="$1"
    local ip="$2"

    if ! nftban_fail2ban_is_running; then
        echo "ERROR: fail2ban is not running" >&2
        return 1
    fi

    echo "Unbanning ${ip} from jail ${jail}..."
    nftban_fail2ban_unban_ip "$jail" "$ip"
}

_nftban_fail2ban_cmd_cloudflare() {
    # Update Cloudflare whitelist

    echo "Updating Cloudflare IP whitelist in fail2ban..."
    nftban_fail2ban_update_cloudflare_whitelist
}

# =============================================================================
# MAIN COMMAND HANDLER
# =============================================================================

nftban_cmd_fail2ban() {
    local action="${1:-help}"
    shift || true

    case "$action" in
        status)
            _nftban_fail2ban_cmd_status
            ;;

        jails)
            _nftban_fail2ban_cmd_jails
            ;;

        available)
            _nftban_fail2ban_cmd_available
            ;;

        recommended)
            _nftban_fail2ban_cmd_recommended
            ;;

        jail)
            if [[ -z "${1:-}" ]]; then
                echo "ERROR: Jail name required" >&2
                echo "Usage: nftban fail2ban jail <name>" >&2
                exit 1
            fi
            _nftban_fail2ban_cmd_jail "$1"
            ;;

        enable)
            if [[ -z "${1:-}" ]]; then
                echo "ERROR: Jail name required" >&2
                echo "Usage: nftban fail2ban enable <jail>" >&2
                exit 1
            fi
            if [[ $EUID -ne 0 ]]; then
                echo "ERROR: This command requires root privileges" >&2
                exit 1
            fi
            _nftban_fail2ban_cmd_enable "$1"
            ;;

        disable)
            if [[ -z "${1:-}" ]]; then
                echo "ERROR: Jail name required" >&2
                echo "Usage: nftban fail2ban disable <jail>" >&2
                exit 1
            fi
            if [[ $EUID -ne 0 ]]; then
                echo "ERROR: This command requires root privileges" >&2
                exit 1
            fi
            _nftban_fail2ban_cmd_disable "$1"
            ;;

        reload)
            if [[ $EUID -ne 0 ]]; then
                echo "ERROR: This command requires root privileges" >&2
                exit 1
            fi
            _nftban_fail2ban_cmd_reload "${1:-}"
            ;;

        banned)
            _nftban_fail2ban_cmd_banned "${1:-}"
            ;;

        ban)
            if [[ -z "${1:-}" ]] || [[ -z "${2:-}" ]]; then
                echo "ERROR: Jail and IP required" >&2
                echo "Usage: nftban fail2ban ban <jail> <ip>" >&2
                exit 1
            fi
            if [[ $EUID -ne 0 ]]; then
                echo "ERROR: This command requires root privileges" >&2
                exit 1
            fi
            _nftban_fail2ban_cmd_ban "$1" "$2"
            ;;

        unban)
            if [[ -z "${1:-}" ]] || [[ -z "${2:-}" ]]; then
                echo "ERROR: Jail and IP required" >&2
                echo "Usage: nftban fail2ban unban <jail> <ip>" >&2
                exit 1
            fi
            if [[ $EUID -ne 0 ]]; then
                echo "ERROR: This command requires root privileges" >&2
                exit 1
            fi
            _nftban_fail2ban_cmd_unban "$1" "$2"
            ;;

        cloudflare)
            if [[ $EUID -ne 0 ]]; then
                echo "ERROR: This command requires root privileges" >&2
                exit 1
            fi
            _nftban_fail2ban_cmd_cloudflare
            ;;

        start)
            if [[ $EUID -ne 0 ]]; then
                echo "ERROR: This command requires root privileges" >&2
                exit 1
            fi
            nftban_fail2ban_start
            ;;

        stop)
            if [[ $EUID -ne 0 ]]; then
                echo "ERROR: This command requires root privileges" >&2
                exit 1
            fi
            nftban_fail2ban_stop
            ;;

        restart)
            if [[ $EUID -ne 0 ]]; then
                echo "ERROR: This command requires root privileges" >&2
                exit 1
            fi
            nftban_fail2ban_restart
            ;;

        help|--help|-h)
            _nftban_fail2ban_help
            ;;

        *)
            echo "ERROR: Unknown command: $action" >&2
            echo "" >&2
            echo "Run 'nftban fail2ban help' for available commands" >&2
            exit 1
            ;;
    esac

    return 0
}

# =============================================================================
# EXPORT FOR MAIN CLI
# =============================================================================
export -f nftban_cmd_fail2ban
