#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.32.6 - Port Scan CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Command-line interface for port scan detection management
#
# meta:name=cmd_portscan
# meta:type=cli
# meta:header=Port Scan CLI
# meta:version=0.32.6
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
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

readonly NFTBAN_LIB_DIR="${NFTBAN_LIB_DIR:-/usr/lib/nftban}"

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
# MAIN COMMAND HANDLER
# =============================================================================

nftban_cmd_portscan() {
    local action="${1:-status}"
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

    # Check root privileges for state-changing operations
    case "$action" in
        enable|disable|check)
            if [[ "$EUID" -ne 0 ]]; then
                echo "ERROR: This command requires root privileges"
                echo "Usage: sudo nftban portscan $action"
                exit 1
            fi
            ;;
    esac

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
            if nft list chain ip nftban_v4 portscan_detection &>/dev/null; then
                echo "  ✅ Port scan detection chain exists (IPv4)"

                # Count rules
                local rule_count
                rule_count=$(nft list chain ip nftban_v4 portscan_detection 2>/dev/null | grep -c "log prefix" || echo "0")
                echo "     Rules: $rule_count logging rules"
            else
                echo "  ❌ Port scan detection chain not found (IPv4)"
                echo "     Run 'sudo nftban portscan enable' to create"
            fi

            if nft list chain ip6 nftban_v6 portscan_detection &>/dev/null; then
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

        help|--help|-h)
            _nftban_portscan_help
            ;;

        *)
            echo "ERROR: Unknown command: $action"
            echo ""
            echo "Available commands: enable, disable, status, check, history, test, help"
            echo "Run 'nftban portscan help' for detailed usage information"
            exit 1
            ;;
    esac

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
