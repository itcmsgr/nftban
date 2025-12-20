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
# NFTBan v1.0.0 - Port Scan CLI Handler
# =============================================================================

# SPDX-License-Identifier: MPL-2.0
# Purpose: Command-line interface for port scan detection management
#
# meta:name=cmd_portscan
# meta:type=cli
# meta:header=Port Scan CLI
# meta:version=1.0.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=CLI handler for port scan detection commands
# meta:input=Command line arguments (enable, disable, status, etc.)
# meta:output=Port scan detection management output
#
# **Inventory & Requirements**
# meta:depends=bash,nftban_portscan.sh
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


_nftban_portscan_help() {
    # Load output module for standard banner
    source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"

    # Show standard banner
    nftban_banner

    cat <<'HELP'

USAGE:
    nftban portscan <command> [options]

COMMANDS:
    enable              Enable port scan detection
    disable             Disable port scan detection
    status              Show detection status and configuration
    check               Run manual port scan check (parse logs)
    history             Show detected scans (last 24 hours)
    test                Test port scan detection rules
    help                Show this help message

DESCRIPTION:
    The port scan detection module identifies IP addresses that access
    multiple ports within a time window and automatically bans them
    to prevent reconnaissance attacks.

HOW IT WORKS:

    1. Detection: Monitors nftables logs for connection attempts
    2. Tracking: Records which ports each IP accesses
    3. Threshold: Flags IPs accessing N ports in M seconds
    4. Auto-Ban: Automatically bans detected scanners (if enabled)

DETECTION PARAMETERS:

    PORTSCAN_TIME_WINDOW="300"       # Time window (5 minutes)
    PORTSCAN_THRESHOLD="10"          # Ports to trigger detection
    PORTSCAN_DIVERSITY="true"        # Require port diversity
    PORTSCAN_AUTO_BAN="true"         # Auto-ban detected scanners

MONITORING MODES:

    "closed"  - Monitor only closed ports (RECOMMENDED)
                ✅ Detects reconnaissance scans
                ✅ No false positives from legitimate traffic
                ✅ Best for most servers

    "all"     - Monitor all ports (AGGRESSIVE)
                ⚠️  May cause false positives
                ✅ Detects all scan types
                ⚠️  Only use if under active attack

    "custom"  - Monitor specific ports
                ✅ Targeted protection
                ✅ Flexible configuration
                Set PORTSCAN_CUSTOM_PORTS="1-1024,3306,5432"

BAN SETTINGS:

    PORTSCAN_AUTO_BAN="true"         # Enable auto-banning
    PORTSCAN_BAN_TYPE="temporary"    # Ban type (temporary/permanent)
    PORTSCAN_BAN_TIME="3600"         # Ban duration (1 hour)

    Examples:
      • Temporary ban: 1 hour cooling-off period
      • Permanent ban: Requires manual unban

CONFIGURATION:
    Port scan detection is configured in:
      /etc/nftban/conf.d/portscan.conf

    User overrides:
      /etc/nftban/nftban.conf.local

    Example override:
      PORTSCAN_THRESHOLD="5"           # Lower threshold (aggressive)
      PORTSCAN_BAN_TYPE="permanent"    # Permanent bans
      PORTSCAN_AUTO_BAN="false"        # Monitoring mode (no bans)

PROFILE SELECTION:
    Select a pre-configured profile based on server role:

      nftban profile select

    Profile examples:
      • Web Server:    10 ports in 5 min, 1-hour temp ban
      • Mail Server:   8 ports in 3 min, 2-hour temp ban
      • Database:      5 ports in 2 min, permanent ban
      • Development:   No auto-ban (monitoring only)
      • Maximum:       3 ports in 1 min, permanent ban

EXAMPLES:
    # Enable port scan detection
    sudo nftban portscan enable

    # Disable port scan detection
    sudo nftban portscan disable

    # Show detection status
    nftban portscan status

    # Run manual check (parse logs)
    sudo nftban portscan check

    # Show detected scans
    nftban portscan history

    # Test detection rules
    nftban portscan test

WHITELIST:
    Create whitelist for monitoring/security tools:
      /etc/nftban/portscan_whitelist.conf

    Format (one IP/CIDR per line):
      # Monitoring tools
      192.168.1.100
      10.0.0.0/8        # Internal network
      203.0.113.0/24    # Security scanner

LOG FILES:
    Detection logs: /var/log/nftban/portscan.log
    Statistics: /var/lib/nftban/portscan/stats.json
    Tracking database: /var/lib/nftban/portscan/tracker.db

REQUIREMENTS:
    • Root privileges (for enable/disable commands)
    • nftables >= 0.9.0
    • Kernel logging enabled

SEE ALSO:
    nftban ddos help         - DDoS protection help
    nftban profile help      - Profile selection help
    nftban ban help          - Ban management help

HELP
}

# =============================================================================

# JSON STATS FUNCTION (for API/GUI)
# =============================================================================

_nftban_portscan_stats_json() {
    local json_mode="${1:-false}"

    # Get portscan enabled status, mode from config
    local portscan_enabled="false"
    local portscan_mode="classic"
    local suricata_available="false"
    local config_file="/etc/nftban/conf.d/portscan.conf"
    local config_main="/etc/nftban/conf.d/portscan/main.conf"
    local monitored_ports=0

    # Check if Suricata is available
    if systemctl is-active suricata.service >/dev/null 2>&1; then
        suricata_available="true"
    fi

    # Read from main.conf (new structure)
    if [[ -f "$config_main" ]]; then
        local enabled_val
        enabled_val=$(grep "^PORTSCAN_ENABLED=" "$config_main" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"' | tr -d "'" | tr -d ' ') || true
        [[ "$enabled_val" == "true" ]] && portscan_enabled="true"

        # Get mode (auto, classic, suricata, hybrid)
        local mode_val=$(grep "^PORTSCAN_MODE=" "$config_main" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'" | xargs)
        [[ -n "$mode_val" ]] && portscan_mode="$mode_val"

        # If mode is "auto", determine effective mode
        if [[ "$portscan_mode" == "auto" ]]; then
            if [[ "$suricata_available" == "true" ]]; then
                portscan_mode="suricata"
            else
                portscan_mode="classic"
            fi
        fi
    elif [[ -f "$config_file" ]]; then
        # Fallback to old config file
        local enabled_val
        enabled_val=$(grep "^PORTSCAN_ENABLED=" "$config_file" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"' | tr -d "'" | tr -d ' ') || true
        [[ "$enabled_val" == "true" ]] && portscan_enabled="true"

        # Get monitored ports count from old config
        local ports_val
        ports_val=$(grep "^PORTSCAN_MONITOR_PORTS=" "$config_file" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"' | tr -d "'") || true
        if [[ "$ports_val" == "closed" ]] || [[ "$ports_val" == "all" ]]; then
            monitored_ports=1
        elif [[ -n "$ports_val" ]]; then
            monitored_ports=$(echo "$ports_val" | grep -oE '[0-9]+' | wc -l) || monitored_ports=0
        fi
    fi

    # Count portscan blocks from nftban-actions.log
    local blocked_24h=0
    local blocked_total=0

    if [[ -f "/var/log/nftban/nftban-actions.log" ]]; then
        # Count portscan bans in last 24 hours
        local yesterday_ts
        yesterday_ts=$(date -d '24 hours ago' +%s 2>/dev/null) || yesterday_ts=0
        blocked_24h=$(grep -c '"source":"portscan"' /var/log/nftban/nftban-actions.log 2>/dev/null) || blocked_24h=0

        # Count total portscan bans (same as 24h for now, proper implementation needs timestamp filtering)
        blocked_total=$blocked_24h
    fi

    # Ensure numeric values - strip any non-numeric characters
    monitored_ports=$(echo "$monitored_ports" | tr -dc '0-9')
    [[ -z "$monitored_ports" ]] && monitored_ports=0
    blocked_24h=$(echo "$blocked_24h" | tr -dc '0-9')
    [[ -z "$blocked_24h" ]] && blocked_24h=0
    blocked_total=$(echo "$blocked_total" | tr -dc '0-9')
    [[ -z "$blocked_total" ]] && blocked_total=0

    if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
        local data
        if command -v jq &>/dev/null; then
            data=$(jq -n \
                --arg ports "$monitored_ports" \
                --arg blocked_24h "$blocked_24h" \
                --arg blocked_total "$blocked_total" \
                --arg enabled "$portscan_enabled" \
                --arg mode "$portscan_mode" \
                --arg suricata "$suricata_available" \
                '{
                    portscan: {
                        monitored_ports: ($ports | tonumber),
                        blocked_24h: ($blocked_24h | tonumber),
                        blocked_total: ($blocked_total | tonumber),
                        enabled: ($enabled == "true"),
                        mode: $mode,
                        suricata_available: ($suricata == "true")
                    }
                }')
        else
            local enabled_json="false"
            local suricata_json="false"
            [[ "$portscan_enabled" == "true" ]] && enabled_json="true"
            [[ "$suricata_available" == "true" ]] && suricata_json="true"
            data="{\"portscan\":{\"monitored_ports\":$monitored_ports,\"blocked_24h\":$blocked_24h,\"blocked_total\":$blocked_total,\"enabled\":$enabled_json,\"mode\":\"$portscan_mode\",\"suricata_available\":$suricata_json}}"
        fi

        json_output "true" "$data"
        return 0
    fi

    # Human-readable output
    echo "Port Scan Detection Statistics"
    echo "=============================="
    echo ""
    echo "  Enabled:          $portscan_enabled"
    echo "  Mode:             $portscan_mode"
    echo "  Suricata:         $suricata_available"
    echo "  Monitored Ports:  $monitored_ports"
    echo "  Blocked (24h):    $blocked_24h"
    echo "  Blocked (Total):  $blocked_total"
    echo ""
}

# =============================================================================

# MAIN COMMAND HANDLER
# =============================================================================


nftban_cmd_portscan() {
    local action="${1:-status}"
    local json_mode=false

    # Check for --json flag
    for arg in "$@"; do
        [[ "$arg" == "--json" ]] && json_mode=true && break
    done
    shift || true

    # Load core port scan module (lazy loading for performance)
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_portscan.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_portscan.sh"
    else
        echo "ERROR: Port scan detection module not found"
        echo "Expected: ${NFTBAN_LIB_DIR}/core/nftban_portscan.sh"
        exit 1
    fi

    # NOTE: Root check removed - nftables operations require CAP_NET_ADMIN
    # which can be granted via capabilities, not just EUID==0.
    # Let the actual nft commands fail with proper error if privileges missing.

    # Handle commands
    case "$action" in
        enable)
            nftban_portscan_enable
            ;;

        disable)
            nftban_portscan_disable
            ;;

        status)
            nftban_portscan_status
            ;;

        stats)
            # JSON stats for API/GUI - output portscan statistics
            _nftban_portscan_stats_json "$json_mode"
            ;;

        check)
            nftban_portscan_banner
            echo ""
            echo "🔍 Running port scan check..."
            echo ""

            # Parse kernel log
            local log_file="/var/log/kern.log"
            if [[ ! -f "$log_file" ]]; then
                log_file="/var/log/messages"
            fi

            if [[ ! -f "$log_file" ]]; then
                echo "❌ No suitable log file found"
                echo "   Tried: /var/log/kern.log, /var/log/messages"
                exit 1
            fi

            echo "Parsing log file: $log_file"
            echo ""

            nftban_portscan_check "$log_file"

            echo ""
            echo "✅ Port scan check complete"
            echo "   Check log: /var/log/nftban/portscan.log"
            ;;

        history)
            nftban_portscan_banner
            echo ""
            echo "📜 Recent Port Scan Detections (last 24 hours)"
            echo ""

            local log_file="/var/log/nftban/portscan.log"
            if [[ ! -f "$log_file" ]]; then
                echo "  (no detections yet)"
            else
                # Show last 24 hours of detections
                local cutoff_time
                cutoff_time=$(date -d "24 hours ago" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -v-24H "+%Y-%m-%d %H:%M:%S")

                grep "Port scanner detected" "$log_file" 2>/dev/null | \
                    awk -v cutoff="$cutoff_time" '$0 >= cutoff' | \
                    tail -n 50 | \
                    sed 's/^/  /' || echo "  (no recent detections)"
            fi
            echo ""
            ;;

        test)
            nftban_portscan_banner
            echo ""
            echo "🧪 Testing Port Scan Detection Rules"
            echo ""
            echo "Checking nftables chains..."
            echo ""

            # Check for portscan chain
            if nft list chain ${NFTBAN_TABLE_IPV4} portscan_detection &>/dev/null; then
                echo "  ✅ Port scan detection chain exists (IPv4)"

                # Count rules
                local rule_count
                rule_count=$(nft list chain ${NFTBAN_TABLE_IPV4} portscan_detection 2>/dev/null | grep -c "log prefix" || echo "0")
                echo "     Rules: $rule_count logging rules"
            else
                echo "  ❌ Port scan detection chain not found (IPv4)"
                echo "     Run 'sudo nftban portscan enable' to create"
            fi

            if nft list chain ${NFTBAN_TABLE_IPV6} portscan_detection &>/dev/null; then
                echo "  ✅ Port scan detection chain exists (IPv6)"
            else
                echo "  ❌ Port scan detection chain not found (IPv6)"
            fi

            echo ""
            echo "Checking log file..."
            if [[ -f "/var/log/nftban/portscan.log" ]]; then
                local log_size
                log_size=$(stat -f%z "/var/log/nftban/portscan.log" 2>/dev/null || stat -c%s "/var/log/nftban/portscan.log")
                echo "  ✅ Log file exists: /var/log/nftban/portscan.log"
                echo "     Size: $log_size bytes"
            else
                echo "  ⚠️  Log file not found (will be created on first detection)"
            fi

            echo ""
            echo "Test complete. Run 'nftban portscan status' for detailed configuration."
            ;;

        sync)
            nftban_portscan_banner
            echo ""
            echo "🔄 Syncing port scan logs from journalctl..."
            echo ""

            nftban_portscan_sync_logs

            local portscan_log="${NFTBAN_PORTSCAN_LOG:-/var/log/nftban/portscan.log}"
            local line_count=$(wc -l < "$portscan_log" 2>/dev/null || echo "0")

            echo "✅ Log sync complete"
            echo "   File: $portscan_log"
            echo "   Entries: $line_count"
            ;;

        help|--help|-h)
            _nftban_portscan_help
            ;;

        *)
            echo "ERROR: Unknown command: $action"
            echo ""
            echo "Available commands: enable, disable, status, check, history, test, sync, help"
            echo "Run 'nftban portscan help' for detailed usage information"
            exit 1
            ;;
    esac


    # Exit marker for testing validation
    command -v nftban_cmd_exit >/dev/null 2>&1 && nftban_cmd_exit "portscan"
    return 0
}

# =============================================================================

# EXPORT FOR MAIN CLI
# =============================================================================

export -f nftban_cmd_portscan

# Execute if called directly (shouldn't happen, but handle gracefully)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_portscan "$@"
fi
