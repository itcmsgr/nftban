#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.32.25 - DDoS CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Command-line interface for DDoS protection management
#
# meta:name=cmd_ddos
# meta:type=cli
# meta:header=DDoS CLI
# meta:version=0.32.24
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=CLI handler for DDoS protection commands
# meta:input=Command line arguments (enable, disable, status, etc.)
# meta:output=DDoS protection management output
#
# **Inventory & Requirements**
# meta:depends=bash,nftban_ddos.sh
#
# meta:created_date=2025-11-05
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

readonly NFTBAN_LIB_DIR="${NFTBAN_LIB_DIR:-/usr/lib/nftban}"

# =============================================================================
# HELP TEXT
# =============================================================================

_nftban_ddos_help() {
    # Load output module for standard banner
    source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"

    # Show standard banner
    nftban_banner

    cat <<'HELP'

USAGE:
    nftban ddos <command> [options]

COMMANDS:
    enable              Enable DDoS protection (all configured protections)
    disable             Disable all DDoS protections
    status              Show status of all DDoS protections

    enable synflood     Enable SYN flood protection only
    disable synflood    Disable SYN flood protection only
    status synflood     Show SYN flood protection status

    enable connlimit    Enable connection limit protection only
    disable connlimit   Disable connection limit protection only
    status connlimit    Show connection limit protection status

    enable portflood    Enable port flood protection only
    disable portflood   Disable port flood protection only
    status portflood    Show port flood protection status

    enable icmp         Enable ICMP flood protection only
    disable icmp        Disable ICMP flood protection only
    status icmp         Show ICMP flood protection status

    test                Test DDoS protection rules
    help                Show this help message

DESCRIPTION:
    The DDoS protection module provides comprehensive protection against
    distributed denial-of-service attacks using nftables rate limiting
    and connection tracking.

PROTECTION TYPES:

    1. SYN Flood Protection
       Protects against TCP SYN flood attacks by rate limiting new
       connections with SYN flag set.

       ⚠️  WARNING: Only enable during active attack (adds connection latency)

       Configuration:
         DDOS_SYNFLOOD_ENABLED="false"    # Master switch
         DDOS_SYNFLOOD_RATE="100/second"  # Rate limit
         DDOS_SYNFLOOD_BURST="150"        # Burst allowance

    2. Connection Limit Protection
       Limits concurrent connections per IP address to specific ports.
       Prevents connection exhaustion attacks.

       ✅ Recommended: Enable for all servers

       Configuration:
         DDOS_CONNLIMIT_ENABLED="true"    # Master switch
         DDOS_CONNLIMIT_SSH="5"           # Max SSH connections per IP
         DDOS_CONNLIMIT_HTTP="20"         # Max HTTP connections per IP
         DDOS_CONNLIMIT_HTTPS="20"        # Max HTTPS connections per IP
         DDOS_CONNLIMIT_SMTP="5"          # Max SMTP connections per IP
         ... (9 services total)

    3. Port Flood Protection
       Rate limits new connection attempts per time period.
       Effective against slowloris and brute force attacks.

       Configuration:
         DDOS_PORTFLOOD_ENABLED="true"    # Master switch
         DDOS_PORTFLOOD_SSH="5/300"       # 5 connections per 5 minutes
         DDOS_PORTFLOOD_HTTP="20/5"       # 20 connections per 5 seconds
         DDOS_PORTFLOOD_HTTPS="20/5"      # 20 connections per 5 seconds

    4. ICMP Flood Protection
       Rate limits ICMP echo requests (ping) to prevent ping floods.
       Allows legitimate monitoring but blocks abuse.

       ✅ Recommended: Always enable

       Configuration:
         DDOS_ICMPFLOOD_ENABLED="true"    # Master switch
         DDOS_ICMPFLOOD_RATE="1/second"   # 1 ping per second per IP
         DDOS_ICMPFLOOD_BURST="10"        # Burst allowance

CONFIGURATION:
    DDoS protection is configured in:
      /etc/nftban/conf.d/ddos.conf

    User overrides:
      /etc/nftban/nftban.conf.local

    Example override:
      DDOS_CONNLIMIT_HTTP="50"         # Increase HTTP limit to 50
      DDOS_SYNFLOOD_ENABLED="true"     # Enable SYN flood protection

PROFILE SELECTION:
    Instead of manually configuring DDoS protection, you can select
    a pre-configured profile based on your server role:

      nftban profile select

    Available profiles:
      • Web Server      - High HTTP/HTTPS traffic
      • Mail Server     - SMTP, POP3, IMAP protection
      • Database        - MySQL, PostgreSQL protection
      • Mixed           - Multiple services
      • Development     - Minimal protection for testing
      • Maximum         - All protections enabled (paranoid mode)
      • Custom          - User-defined configuration

EXAMPLES:
    # Enable all DDoS protections (based on config)
    sudo nftban ddos enable

    # Disable all DDoS protections
    sudo nftban ddos disable

    # Show status of all protections
    nftban ddos status

    # Enable only connection limit protection
    sudo nftban ddos enable connlimit

    # Show SYN flood protection status
    nftban ddos status synflood

    # Disable ICMP flood protection
    sudo nftban ddos disable icmp

    # Test DDoS protection rules
    nftban ddos test

LOG FILES:
    DDoS protection logs: /var/log/nftban/ddos.log
    Statistics: /var/lib/nftban/ddos/stats.json

REQUIREMENTS:
    • Root privileges (for enable/disable commands)
    • nftables >= 0.9.0
    • Linux kernel >= 3.13 (for connection tracking)

SEE ALSO:
    nftban profile help      - Profile selection help
    nftban portscan help     - Port scan detection help
    nftban cloudflare help   - Cloudflare integration help

HELP
}

# =============================================================================
# MAIN COMMAND HANDLER
# =============================================================================

nftban_cmd_ddos() {
    local action="${1:-status}"
    shift || true

    # Load core DDoS module (lazy loading for performance)
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_ddos.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_ddos.sh"
    else
        echo "ERROR: DDoS protection module not found"
        echo "Expected: ${NFTBAN_LIB_DIR}/core/nftban_ddos.sh"
        exit 1
    fi

    # Check root privileges for state-changing operations
    case "$action" in
        enable|disable)
            if [[ "$EUID" -ne 0 ]]; then
                echo "ERROR: This command requires root privileges"
                echo "Usage: sudo nftban ddos $action"
                exit 1
            fi
            ;;
    esac

    # Handle commands
    case "$action" in
        enable)
            local subaction="${1:-all}"
            case "$subaction" in
                synflood)
                    nftban_ddos_synflood_enable
                    ;;
                connlimit)
                    nftban_ddos_connlimit_enable
                    ;;
                portflood)
                    nftban_ddos_portflood_enable
                    ;;
                icmp)
                    nftban_ddos_icmp_enable
                    ;;
                all|*)
                    nftban_ddos_enable
                    ;;
            esac
            ;;

        disable)
            local subaction="${1:-all}"
            case "$subaction" in
                synflood)
                    nftban_ddos_synflood_disable
                    ;;
                connlimit)
                    nftban_ddos_connlimit_disable
                    ;;
                portflood)
                    nftban_ddos_portflood_disable
                    ;;
                icmp)
                    nftban_ddos_icmp_disable
                    ;;
                all|*)
                    nftban_ddos_disable
                    ;;
            esac
            ;;

        status)
            local subaction="${1:-all}"
            case "$subaction" in
                synflood)
                    nftban_ddos_banner
                    nftban_ddos_synflood_status
                    ;;
                connlimit)
                    nftban_ddos_banner
                    nftban_ddos_connlimit_status
                    ;;
                portflood)
                    nftban_ddos_banner
                    nftban_ddos_portflood_status
                    ;;
                icmp)
                    nftban_ddos_banner
                    nftban_ddos_icmp_status
                    ;;
                all|*)
                    nftban_ddos_status
                    ;;
            esac
            ;;

        test)
            nftban_ddos_banner
            echo ""
            echo "🧪 Testing DDoS Protection Rules"
            echo ""
            echo "Checking nftables chains..."
            echo ""

            # Check for SYN flood chain
            if nft list chain ip nftban_v4 synflood_protection &>/dev/null; then
                echo "  ✅ SYN flood chain exists (IPv4)"
            else
                echo "  ❌ SYN flood chain not found (IPv4)"
            fi

            # Check for connection limit chain
            if nft list chain ip nftban_v4 connlimit_protection &>/dev/null; then
                echo "  ✅ Connection limit chain exists (IPv4)"
            else
                echo "  ❌ Connection limit chain not found (IPv4)"
            fi

            # Check for port flood chain
            if nft list chain ip nftban_v4 portflood_protection &>/dev/null; then
                echo "  ✅ Port flood chain exists (IPv4)"
            else
                echo "  ❌ Port flood chain not found (IPv4)"
            fi

            # Check for ICMP chain
            if nft list chain ip nftban_v4 icmp_protection &>/dev/null; then
                echo "  ✅ ICMP protection chain exists (IPv4)"
            else
                echo "  ❌ ICMP protection chain not found (IPv4)"
            fi

            echo ""
            echo "Test complete. Run 'nftban ddos status' for detailed information."
            ;;

        help|--help|-h)
            _nftban_ddos_help
            ;;

        *)
            echo "ERROR: Unknown command: $action"
            echo ""
            echo "Available commands: enable, disable, status, test, help"
            echo "Run 'nftban ddos help' for detailed usage information"
            exit 1
            ;;
    esac

    return 0
}

# =============================================================================
# EXPORT FOR MAIN CLI
# =============================================================================
export -f nftban_cmd_ddos

# Execute if called directly (shouldn't happen, but handle gracefully)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_ddos "$@"
fi
