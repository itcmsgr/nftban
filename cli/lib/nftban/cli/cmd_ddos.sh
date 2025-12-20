#!/usr/bin/env bash
# =============================================================================

# Load JSON helper for --json support
[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"

# Load strict mode library
# shellcheck source=/usr/lib/nftban/lib/strict.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/strict.sh"
else
    # Fallback to manual strict mode
    set -Eeuo pipefail
fi

# Load version library
# shellcheck source=/usr/lib/nftban/lib/version.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/version.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/version.sh"
fi
JSON_HELPER="${NFTBAN_LIB_DIR}/helpers/json_output.sh"
if [[ -f "$JSON_HELPER" ]]; then
    # shellcheck source=/dev/null
    source "$JSON_HELPER"
fi
# NFTBan v1.0.0 - DDoS CLI Handler
# =============================================================================

# SPDX-License-Identifier: MPL-2.0
# Purpose: Command-line interface for DDoS protection management
#
# meta:name=cmd_ddos
# meta:type=cli
# meta:header=DDoS CLI
# meta:version=1.0.0
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
# meta:updated_date=2025-11-24
# =============================================================================



# =============================================================================

# CONFIGURATION
# =============================================================================

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

# JSON STATS FUNCTION (for API/GUI)
# =============================================================================

_nftban_ddos_stats_json() {
    local json_mode="${1:-false}"

    # Get DDoS enabled status, mode, and rate limit from config
    local ddos_enabled="false"
    local ddos_mode="classic"
    local rate_limit=0
    local suricata_available="false"
    local config_file="/etc/nftban/conf.d/ddos.conf"
    local config_main="/etc/nftban/conf.d/ddos/main.conf"
    local config_classic="/etc/nftban/conf.d/ddos/classic.conf"

    # Check if Suricata is available
    if systemctl is-active suricata.service >/dev/null 2>&1; then
        suricata_available="true"
    fi

    if [[ -f "$config_main" ]]; then
        local enabled_val=$(grep "^DDOS_ENABLED=" "$config_main" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'" | xargs)
        [[ "$enabled_val" == "true" ]] && ddos_enabled="true"
        # Get mode (auto, classic, suricata, hybrid)
        local mode_val=$(grep "^DDOS_MODE=" "$config_main" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'" | xargs)
        [[ -n "$mode_val" ]] && ddos_mode="$mode_val"
        # If mode is "auto", determine effective mode
        if [[ "$ddos_mode" == "auto" ]]; then
            if [[ "$suricata_available" == "true" ]]; then
                ddos_mode="suricata"
            else
                ddos_mode="classic"
            fi
        fi
    elif [[ -f "$config_file" ]]; then
        local enabled_val=$(grep "^DDOS_ENABLED=" "$config_file" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'" | xargs)
        [[ "$enabled_val" == "true" ]] && ddos_enabled="true"
    fi

    # Get rate limit from classic config (if exists)
    if [[ -f "$config_classic" ]]; then
        local rate_val=$(grep "^DDOS_SYNFLOOD_RATE=" "$config_classic" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'" | grep -oE '^[0-9]+' || echo "0")
        [[ -n "$rate_val" ]] && rate_limit="$rate_val"
    elif [[ -f "$config_main" ]]; then
        local rate_val=$(grep "^DDOS_SYNFLOOD_RATE=" "$config_main" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'" | grep -oE '^[0-9]+' || echo "0")
        [[ -n "$rate_val" ]] && rate_limit="$rate_val"
    fi

    # Count DDoS blocks from nftban-actions.log
    local blocked_24h=0
    local blocked_total=0
    local packets_dropped=0
    local bytes_dropped=0

    if [[ -f "/var/log/nftban/nftban-actions.log" ]]; then
        # Count ddos bans in last 24 hours
        local yesterday_ts=$(date -d '24 hours ago' +%s 2>/dev/null || echo "0")
        blocked_24h=$(jq -r --arg ts "$yesterday_ts" 'select(.source == "ddos" and .event == "ban") | select((.ts | fromdateiso8601) >= ($ts | tonumber))' /var/log/nftban/nftban-actions.log 2>/dev/null | jq -s '. | length' 2>/dev/null || echo "0")

        # Count total ddos bans
        blocked_total=$(jq -r 'select(.source == "ddos" and .event == "ban")' /var/log/nftban/nftban-actions.log 2>/dev/null | jq -s '. | length' 2>/dev/null || echo "0")
    fi

    # Try to get nftables counter stats (packets/bytes dropped)
    # Check DDoS-related chains for drop counters
    if command -v nft &>/dev/null; then
        # Get counter stats from ddos_protection chain if it exists
        local counter_output
        counter_output=$(nft list chain ip nftban ddos_protection 2>/dev/null || true)
        if [[ -n "$counter_output" ]]; then
            # Parse packets and bytes from counter output
            # Format: counter packets X bytes Y
            packets_dropped=$(echo "$counter_output" | grep -oP 'counter packets \K[0-9]+' | head -1 || echo "0")
            bytes_dropped=$(echo "$counter_output" | grep -oP 'bytes \K[0-9]+' | head -1 || echo "0")
        fi
    fi

    # Ensure numeric values
    packets_dropped=${packets_dropped:-0}
    bytes_dropped=${bytes_dropped:-0}
    blocked_24h=${blocked_24h:-0}
    blocked_total=${blocked_total:-0}

    if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
        local data
        if command -v jq &>/dev/null; then
            data=$(jq -n \
                --arg packets "$packets_dropped" \
                --arg bytes "$bytes_dropped" \
                --arg blocked_24h "$blocked_24h" \
                --arg blocked_total "$blocked_total" \
                --arg enabled "$ddos_enabled" \
                --arg rate "$rate_limit" \
                --arg mode "$ddos_mode" \
                --arg suricata "$suricata_available" \
                '{
                    ddos: {
                        packets_dropped: ($packets | tonumber),
                        bytes_dropped: ($bytes | tonumber),
                        blocked_24h: ($blocked_24h | tonumber),
                        blocked_total: ($blocked_total | tonumber),
                        enabled: ($enabled == "true"),
                        rate_limit: ($rate | tonumber),
                        mode: $mode,
                        suricata_available: ($suricata == "true")
                    }
                }')
        else
            local enabled_json="false"
            local suricata_json="false"
            [[ "$ddos_enabled" == "true" ]] && enabled_json="true"
            [[ "$suricata_available" == "true" ]] && suricata_json="true"
            data="{\"ddos\":{\"packets_dropped\":$packets_dropped,\"bytes_dropped\":$bytes_dropped,\"blocked_24h\":$blocked_24h,\"blocked_total\":$blocked_total,\"enabled\":$enabled_json,\"rate_limit\":$rate_limit,\"mode\":\"$ddos_mode\",\"suricata_available\":$suricata_json}}"
        fi

        json_output "true" "$data"
        return 0
    fi

    # Human-readable output
    echo "DDoS Protection Statistics"
    echo "=========================="
    echo ""
    echo "  Enabled:         $ddos_enabled"
    echo "  Mode:            $ddos_mode"
    echo "  Suricata:        $suricata_available"
    echo "  Rate Limit:      $rate_limit conn/s"
    echo "  Packets Dropped: $packets_dropped"
    echo "  Bytes Dropped:   $bytes_dropped"
    echo "  Blocked (24h):   $blocked_24h"
    echo "  Blocked (Total): $blocked_total"
    echo ""
}

# =============================================================================

# MAIN COMMAND HANDLER
# =============================================================================


nftban_cmd_ddos() {
    local action="${1:-status}"
    local json_mode=false

    # Check for --json flag
    for arg in "$@"; do
        [[ "$arg" == "--json" ]] && json_mode=true && break
    done
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

    # NOTE: Root check removed - nftables operations require CAP_NET_ADMIN
    # which can be granted via capabilities, not just EUID==0.
    # Let the actual nft commands fail with proper error if privileges missing.

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
            # Banner is handled by main CLI router
            local subaction="${1:-all}"
            case "$subaction" in
                synflood)
                    nftban_ddos_synflood_status
                    ;;
                connlimit)
                    nftban_ddos_connlimit_status
                    ;;
                portflood)
                    nftban_ddos_portflood_status
                    ;;
                icmp)
                    nftban_ddos_icmp_status
                    ;;
                all|*)
                    nftban_ddos_status
                    ;;
            esac
            ;;

        stats)
            # JSON stats for API/GUI - output DDoS statistics
            _nftban_ddos_stats_json "$json_mode"
            ;;

        test)
            nftban_ddos_banner
            echo ""
            echo "🧪 Testing DDoS Protection Rules"
            echo ""
            echo "Checking nftables chains..."
            echo ""

            # Check for SYN flood chain
            if nft list chain ${NFTBAN_TABLE_IPV4} synflood_protection &>/dev/null; then
                echo "  ✅ SYN flood chain exists (IPv4)"
            else
                echo "  ❌ SYN flood chain not found (IPv4)"
            fi

            # Check for connection limit chain
            if nft list chain ${NFTBAN_TABLE_IPV4} connlimit_protection &>/dev/null; then
                echo "  ✅ Connection limit chain exists (IPv4)"
            else
                echo "  ❌ Connection limit chain not found (IPv4)"
            fi

            # Check for port flood chain
            if nft list chain ${NFTBAN_TABLE_IPV4} portflood_protection &>/dev/null; then
                echo "  ✅ Port flood chain exists (IPv4)"
            else
                echo "  ❌ Port flood chain not found (IPv4)"
            fi

            # Check for ICMP chain
            if nft list chain ${NFTBAN_TABLE_IPV4} icmp_protection &>/dev/null; then
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


    # Exit marker for testing validation
    command -v nftban_cmd_exit >/dev/null 2>&1 && nftban_cmd_exit "ddos"
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
