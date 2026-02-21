#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.9.3 - DDoS CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Command-line interface for DDoS protection management
#
# meta:name="cmd_ddos"
# meta:type="cli"
# meta:header="DDoS CLI"
# meta:version="1.9.3"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="CLI handler for DDoS protection commands"
# meta:input="Command line arguments (enable, disable, status, etc.)"
# meta:output="DDoS protection management output"
# meta:depends="bash,nftban_ddos.sh"
#
# meta:inventory.files=""
# meta:inventory.binaries="nft"
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/conf.d/ddos/main.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2025-11-05"
# meta:updated_date="2026-02-02"
# =============================================================================

set -Eeuo pipefail

# Load common CLI helpers (provides cmd_init, cmd_error, cmd_is_json_mode, etc.)
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/cmd_common.sh"

# Load prerequisite checker
# shellcheck source=/dev/null
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_prereq.sh" ]]; then
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_prereq.sh"
fi

# Initialize CLI environment (loads config, sets paths, enables strict mode)
cmd_init

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
    stats               Show DDoS statistics (use --json for GUI)
    test                Test DDoS protection rules
    mode                Show or set protection mode (auto|classic|suricata|hybrid)
    help                Show this help message

NOTE:
    DDoS protections are managed as a unified set. Individual protection
    types (synflood, connlimit, etc.) are controlled via configuration
    files, not separate commands.

DESCRIPTION:
    The DDoS protection module provides comprehensive protection against
    distributed denial-of-service attacks using nftables rate limiting
    and connection tracking.

PROTECTION TYPES:

    The DDoS module includes multiple protection layers:

    • SYN Flood Protection - Rate limits TCP SYN packets
    • Connection Limits - Limits concurrent connections per IP/port
    • ICMP Rate Limiting - Prevents ping floods
    • UDP Flood Protection - Rate limits UDP traffic

    All protections are configured via environment variables in:
      /etc/nftban/conf.d/ddos/main.conf
      /etc/nftban/conf.d/ddos/classic.conf

    Key configuration variables:
      DDOS_ENABLED="true"                        # Master enable/disable
      DDOS_MODE="auto"                           # auto|classic|suricata|hybrid
      DDOS_CLASSIC_SYN_RATE="25/second"         # SYN flood rate limit
      DDOS_CLASSIC_SYN_BURST="50"               # Burst allowance
      DDOS_CLASSIC_SSH_CONN_LIMIT="10"          # Max SSH connections/IP
      DDOS_CLASSIC_HTTP_CONN_LIMIT="100"        # Max HTTP connections/IP
      DDOS_CLASSIC_ICMP_RATE="10/second"        # ICMP rate limit
      DDOS_CLASSIC_UDP_RATE="100/second"        # UDP rate limit

CONFIGURATION:
    DDoS protection is configured in:
      /etc/nftban/conf.d/ddos/main.conf

    User overrides:
      /etc/nftban/nftban.conf.local

    Example overrides:
      DDOS_CLASSIC_HTTP_CONN_LIMIT="200"   # Increase HTTP limit
      DDOS_CLASSIC_SYN_RATE="50/second"    # Increase SYN rate limit
      DDOS_MODE="classic"                   # Force classic mode

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

    # Show statistics
    nftban ddos stats

    # Test DDoS protection rules
    nftban ddos test

    # Show current mode
    nftban ddos mode show

    # Set mode to classic
    sudo nftban ddos mode set classic

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
    local config_main="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/ddos/main.conf"
    local config_classic="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/ddos/classic.conf"

    # Check if Suricata is available
    if systemctl is-active suricata.service >/dev/null 2>&1; then
        suricata_available="true"
    fi

    if [[ -f "$config_main" ]]; then
        local enabled_val
        enabled_val=$(grep "^DDOS_ENABLED=" "$config_main" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'" | xargs)
        [[ "$enabled_val" == "true" ]] && ddos_enabled="true"
        # Get mode (auto, classic, suricata, hybrid)
        local mode_val
        mode_val=$(grep "^DDOS_MODE=" "$config_main" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'" | xargs)
        [[ -n "$mode_val" ]] && ddos_mode="$mode_val"
        # If mode is "auto", determine effective mode
        if [[ "$ddos_mode" == "auto" ]]; then
            if [[ "$suricata_available" == "true" ]]; then
                ddos_mode="suricata"
            else
                ddos_mode="classic"
            fi
        fi
    fi

    # Get rate limit from classic config (if exists)
    if [[ -f "$config_classic" ]]; then
        local rate_val
        rate_val=$(grep "^DDOS_SYNFLOOD_RATE=" "$config_classic" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'" | grep -oE '^[0-9]+' || echo "0")
        [[ -n "$rate_val" ]] && rate_limit="$rate_val"
    elif [[ -f "$config_main" ]]; then
        local rate_val2
        rate_val2=$(grep "^DDOS_SYNFLOOD_RATE=" "$config_main" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'" | grep -oE '^[0-9]+' || echo "0")
        [[ -n "$rate_val2" ]] && rate_limit="$rate_val2"
    fi

    # Count DDoS blocks from nftban-actions.log
    local blocked_24h=0
    local blocked_total=0
    local packets_dropped=0
    local bytes_dropped=0

    if [[ -f "${NFTBAN_LOG_DIR:-/var/log/nftban}/nftban-actions.log" ]]; then
        # Count ddos bans in last 24 hours
        local yesterday_ts
        yesterday_ts=$(date -d '24 hours ago' +%s 2>/dev/null || echo "0")
        blocked_24h=$(jq -r --arg ts "$yesterday_ts" 'select(.source == "ddos" and .event == "ban") | select((.ts | fromdateiso8601) >= ($ts | tonumber))' "${NFTBAN_LOG_DIR:-/var/log/nftban}/nftban-actions.log" 2>/dev/null | jq -s '. | length' 2>/dev/null || echo "0")

        # Count total ddos bans
        blocked_total=$(jq -r 'select(.source == "ddos" and .event == "ban")' "${NFTBAN_LOG_DIR:-/var/log/nftban}/nftban-actions.log" 2>/dev/null | jq -s '. | length' 2>/dev/null || echo "0")
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
# MODE COMMAND: Wrapper using shared helper
# =============================================================================

_nftban_ddos_mode() {
    local subcommand="${1:-show}"
    local json_mode="${2:-false}"
    local mode_arg="${3:-}"

    # Load shared mode helper
    local mode_helper="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/helpers/nftban_mode.sh"
    if [[ -f "$mode_helper" ]]; then
        # shellcheck source=/dev/null
        source "$mode_helper"
    else
        echo "ERROR: Mode helper not found: $mode_helper" >&2
        return 1
    fi

    # Delegate to shared handler with DDoS-specific parameters
    _nftban_mode_handler "ddos" "DDOS_MODE" \
        "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/ddos/main.conf" \
        "DDoS Protection" \
        "$subcommand" "$json_mode" "$mode_arg"
}

# =============================================================================
# MAIN COMMAND HANDLER
# =============================================================================

nftban_cmd_ddos() {
    local action="${1:-status}"
    local json_mode

    # Check for help first
    cmd_wants_help "$@" && { _nftban_ddos_help; return 0; }

    # Detect JSON mode and load helper
    json_mode=$(cmd_is_json_mode "$@")
    cmd_load_helpers json

    # Shift past the action argument
    shift || true

    # Load core DDoS module (lazy loading for performance)
    local ddos_module="${NFTBAN_LIB_DIR}/core/nftban_ddos.sh"
    if [[ -f "$ddos_module" ]]; then
        # shellcheck source=/dev/null
        source "$ddos_module"
    else
        cmd_error "DDoS protection module not found at $ddos_module" "$json_mode"
        return 1
    fi

    # Handle commands
    case "$action" in
        enable)
            # Enable all DDoS protections (granular controls not implemented)
            nftban_ddos_enable
            ;;

        disable)
            # Disable all DDoS protections
            nftban_ddos_disable
            ;;

        status)
            # Show status of all DDoS protections
            nftban_ddos_status
            ;;

        stats)
            # JSON stats for API/GUI - output DDoS statistics
            _nftban_ddos_stats_json "$json_mode"
            ;;

        test)
            # Delegate to main controller's test function
            if type -t nftban_ddos_test &>/dev/null; then
                nftban_ddos_test
            else
                cmd_error "DDoS test function not available" "$json_mode"
                return 1
            fi
            ;;

        mode)
            # Handle mode subcommand (show/set) via shared helper
            local mode_subcmd="${1:-show}"
            shift || true
            local mode_arg="${1:-}"
            _nftban_ddos_mode "$mode_subcmd" "$json_mode" "$mode_arg"
            ;;

        help|--help|-h)
            _nftban_ddos_help
            ;;

        *)
            cmd_error "Unknown command: $action. Use: enable, disable, status, stats, test, mode, help" "$json_mode"
            return 1
            ;;
    esac

    return 0
}

# =============================================================================
# EXPORT FOR MAIN CLI
# =============================================================================

export -f nftban_cmd_ddos
export -f _nftban_ddos_help
export -f _nftban_ddos_stats_json
export -f _nftban_ddos_mode
