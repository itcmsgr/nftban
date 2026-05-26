#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Port Scan CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="cmd_portscan"
# meta:type="cli"
# meta:header="Port Scan CLI"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="CLI handler for port scan detection commands"
# meta:inventory.files=""
# meta:inventory.binaries="nft"
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/conf.d/portscan/main.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2025-11-05"
# meta:updated_date="2026-02-02"
# =============================================================================

set -Eeuo pipefail

[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"

# Load strict mode library
# shellcheck source=/usr/lib/nftban/lib/strict.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/strict.sh" || return 1
fi

# Load prerequisite checker
# shellcheck source=/dev/null
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_prereq.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_prereq.sh" || return 1
fi

# Load version library
# shellcheck source=/usr/lib/nftban/lib/version.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/version.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/version.sh" || return 1
fi

# Load JSON helper for --json support
JSON_HELPER="${NFTBAN_LIB_DIR}/helpers/json_output.sh"
if [[ -f "$JSON_HELPER" ]]; then
    # shellcheck source=/dev/null
    source "$JSON_HELPER" || return 1
fi
# =============================================================================



# =============================================================================

# CONFIGURATION
# =============================================================================

# =============================================================================

# HELP TEXT
# =============================================================================


_nftban_portscan_help() {
    # Load output module for standard banner
    source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1

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
    mode                Show or set detection mode (auto|classic|suricata|hybrid)
    config              Show current configuration settings
    reload              Reload detection (disable + re-enable with fresh config)
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
      /etc/nftban/conf.d/portscan/main.conf

    User overrides:
      /etc/nftban/nftban.conf.local

    Example override:
      PORTSCAN_THRESHOLD="5"           # Lower threshold (aggressive)
      PORTSCAN_BAN_TYPE="permanent"    # Permanent bans
      PORTSCAN_AUTO_BAN="false"        # Monitoring mode (no bans)

PROFILE SELECTION:
    Select a pre-configured profile based on server role:

      nftban wizard

    Profile examples:
      • Web Server:    10 ports in 5 min, 1-hour temp ban
      • Mail Server:   8 ports in 3 min, 2-hour temp ban
      • Database:      5 ports in 2 min, permanent ban
      • Development:   No auto-ban (monitoring only)
      • Maximum:       3 ports in 1 min, permanent ban

EXAMPLES:
    # Enable port scan detection
    nftban portscan enable

    # Disable port scan detection
    nftban portscan disable

    # Show detection status
    nftban portscan status

    # Run manual check (parse logs)
    nftban portscan check

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
    Detection logs: ${NFTBAN_LOG_DIR}/portscan.log
    Statistics: /var/lib/nftban/portscan/stats.json
    Tracking database: /var/lib/nftban/portscan/tracker.db

REQUIREMENTS:
    • Elevated privileges (members of the nftban group are authorized via PolicyKit/polkit for enable/disable commands)
    • nftables >= 0.9.0
    • Kernel logging enabled

HELP
}

# =============================================================================

# PORT SCAN STATISTICS (JSON)
# =============================================================================

_nftban_portscan_stats_json() {
    local json_mode="${1:-false}"
    local stats_file="${NFTBAN_DATA_DIR:-/var/lib/nftban}/portscan/stats.json"
    local log_file="${NFTBAN_LOG_DIR:-/var/log/nftban}/portscan.log"

    # Initialize counters
    local detected_24h=0
    local blocked_24h=0
    local detected_total=0
    local blocked_total=0
    local last_detection=""
    local last_block=""

    # Read stats from JSON file if exists
    if [[ -f "$stats_file" ]] && command -v jq &>/dev/null; then
        detected_total=$(jq -r '.detected_total // 0' "$stats_file" 2>/dev/null || echo "0")
        blocked_total=$(jq -r '.blocked_total // 0' "$stats_file" 2>/dev/null || echo "0")
        last_detection=$(jq -r '.last_detection // ""' "$stats_file" 2>/dev/null || echo "")
        last_block=$(jq -r '.last_block // ""' "$stats_file" 2>/dev/null || echo "")
    fi

    # Count last 24 hours from log
    if [[ -f "$log_file" ]]; then
        local cutoff_epoch
        cutoff_epoch=$(date -d "24 hours ago" +%s 2>/dev/null || date -v-24H +%s 2>/dev/null || echo "0")
        
        # Parse log for detections and blocks in last 24h
        while IFS= read -r line; do
            # Extract timestamp (assumes ISO format at start)
            local ts
            ts=$(echo "$line" | grep -oP '^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}' | head -1)
            if [[ -n "$ts" ]]; then
                local line_epoch
                line_epoch=$(date -d "$ts" +%s 2>/dev/null || echo "0")
                if [[ "$line_epoch" -ge "$cutoff_epoch" ]]; then
                    if echo "$line" | grep -q "detected"; then
                        ((detected_24h++)) || true
                    fi
                    if echo "$line" | grep -q "blocked\|banned"; then
                        ((blocked_24h++)) || true
                    fi
                fi
            fi
        done < "$log_file"
    fi

    # JSON output
    if [[ "$json_mode" == "true" ]] && declare -f json_output &>/dev/null; then
        local data
        if command -v jq &>/dev/null; then
            data=$(jq -n \
                --argjson detected_24h "$detected_24h" \
                --argjson blocked_24h "$blocked_24h" \
                --argjson detected_total "$detected_total" \
                --argjson blocked_total "$blocked_total" \
                --arg last_detection "$last_detection" \
                --arg last_block "$last_block" \
                '{
                    stats: {
                        detected_24h: $detected_24h,
                        blocked_24h: $blocked_24h,
                        detected_total: $detected_total,
                        blocked_total: $blocked_total,
                        last_detection: (if $last_detection == "" then null else $last_detection end),
                        last_block: (if $last_block == "" then null else $last_block end)
                    }
                }')
        else
            local ld_json="null"
            local lb_json="null"
            [[ -n "$last_detection" ]] && ld_json="\"$last_detection\""
            [[ -n "$last_block" ]] && lb_json="\"$last_block\""
            data="{\"stats\":{\"detected_24h\":$detected_24h,\"blocked_24h\":$blocked_24h,\"detected_total\":$detected_total,\"blocked_total\":$blocked_total,\"last_detection\":$ld_json,\"last_block\":$lb_json}}"
        fi
        json_output "true" "$data"
        return 0
    fi

    # Human-readable output
    echo "Port Scan Statistics"
    echo "===================="
    echo ""
    echo "  Last 24 Hours:"
    echo "  Detected:         $detected_24h"
    echo "  Blocked:          $blocked_24h"
    echo ""
    echo "  All Time:"
    echo "  Detected (Total): $detected_total"
    echo "  Blocked (Total):  $blocked_total"
    echo ""
}

# =============================================================================
# CONFIG COMMAND: Show portscan configuration
# =============================================================================

_nftban_portscan_config() {
    local json_mode="${1:-false}"
    local config_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/portscan/main.conf"
    local config_local="${config_file}.local"

    if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
        local data
        if command -v jq &>/dev/null; then
            data=$(jq -n \
                --arg config_file "$config_file" \
                --arg config_local "$config_local" \
                --arg local_exists "$([[ -f "$config_local" ]] && echo "true" || echo "false")" \
                --arg enabled "${PORTSCAN_ENABLED:-false}" \
                --arg mode "${PORTSCAN_MODE:-auto}" \
                --arg threshold "${PORTSCAN_THRESHOLD:-10}" \
                --arg time_window "${PORTSCAN_TIME_WINDOW:-300}" \
                --arg auto_ban "${PORTSCAN_AUTO_BAN:-true}" \
                --arg ban_type "${PORTSCAN_BAN_TYPE:-temporary}" \
                --arg ban_time "${PORTSCAN_BAN_TIME:-3600}" \
                '{
                    config_file: $config_file,
                    config_local: $config_local,
                    local_exists: ($local_exists == "true"),
                    settings: {
                        enabled: ($enabled == "true"),
                        mode: $mode,
                        threshold: ($threshold | tonumber),
                        time_window: ($time_window | tonumber),
                        auto_ban: ($auto_ban == "true"),
                        ban_type: $ban_type,
                        ban_time: ($ban_time | tonumber)
                    }
                }')
        else
            data="{\"config_file\":\"$config_file\",\"enabled\":${PORTSCAN_ENABLED:-false}}"
        fi
        json_output "true" "$data"
        return 0
    fi

    # Human-readable output
    echo "Port Scan Detection Configuration"
    echo "=================================="
    echo ""
    echo "  Config File:    $config_file"
    echo "  Override File:  $config_local"
    if [[ -f "$config_local" ]]; then
        echo "  Status:         [Override Active]"
    else
        echo "  Status:         [Using defaults]"
    fi
    echo ""
    echo "Detection Settings:"
    echo "  Enabled:        ${PORTSCAN_ENABLED:-false}"
    echo "  Mode:           ${PORTSCAN_MODE:-auto}"
    echo "  Threshold:      ${PORTSCAN_THRESHOLD:-10} ports"
    echo "  Time Window:    ${PORTSCAN_TIME_WINDOW:-300} seconds"
    echo "  Diversity:      ${PORTSCAN_DIVERSITY:-true}"
    echo ""
    echo "Ban Settings:"
    echo "  Auto-Ban:       ${PORTSCAN_AUTO_BAN:-true}"
    echo "  Ban Type:       ${PORTSCAN_BAN_TYPE:-temporary}"
    echo "  Ban Duration:   ${PORTSCAN_BAN_TIME:-3600} seconds"
    echo ""
    echo "To override settings, create/edit: $config_local"
}

# =============================================================================
# MODE COMMAND: Thin wrapper using shared helper
# =============================================================================

# Mode subcommand handler - delegates to shared helper
_nftban_portscan_mode() {
    local subcommand="${1:-show}"
    local json_mode="${2:-false}"
    local mode_arg="${3:-}"

    # Load shared mode helper
    local mode_helper="${NFTBAN_LIB_DIR}/helpers/nftban_mode.sh"
    if [[ -f "$mode_helper" ]]; then
        # shellcheck source=/dev/null
        source "$mode_helper" || return 1
    else
        echo "ERROR: Mode helper not found: $mode_helper" >&2
        return 1
    fi

    # Delegate to shared handler
    _nftban_mode_handler "portscan" "PORTSCAN_MODE" \
        "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/portscan/main.conf" \
        "Port Scan Detection" \
        "$subcommand" "$json_mode" "$mode_arg"
}

# =============================================================================

# MAIN COMMAND HANDLER
# =============================================================================


nftban_cmd_portscan() {
    local action="${1:-status}"
    local json_mode=false

    # Check for --json flag
    for arg in "$@"; do
        [[ "$arg" == "--json" ]] && json_mode=true && break || true
    done
    shift || true

    # Load core port scan module (lazy loading for performance)
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_portscan.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_portscan.sh" || return 1
    else
        echo "ERROR: Port scan detection module not found" >&2
        echo "Expected: ${NFTBAN_LIB_DIR}/core/nftban_portscan.sh"
        return 1
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

        config)
            # Show portscan configuration
            _nftban_portscan_config "$json_mode"
            ;;

        check)
            nftban_portscan_banner
            echo ""
            echo "🔍 Running port scan check..."
            echo ""

            # Detect log source - support both traditional files and journalctl
            local log_source=""
            local use_journalctl=false

            # Check traditional log files first
            if [[ -f "/var/log/kern.log" ]]; then
                log_source="/var/log/kern.log"
            elif [[ -f "/var/log/messages" ]]; then
                log_source="/var/log/messages"
            elif [[ -f "/var/log/syslog" ]]; then
                log_source="/var/log/syslog"
            elif command -v journalctl &>/dev/null; then
                # Use journalctl on systemd systems without traditional log files
                log_source="journalctl"
                use_journalctl=true
            fi

            if [[ -z "$log_source" ]]; then
                echo "❌ No suitable log source found"
                echo "   Tried: /var/log/kern.log, /var/log/messages, /var/log/syslog, journalctl"
                return 1
            fi

            if [[ "$use_journalctl" == "true" ]]; then
                echo "Using log source: journalctl -k (systemd kernel journal)"
            else
                echo "Parsing log file: $log_source"
            fi
            echo ""

            nftban_portscan_check "$log_source"

            echo ""
            echo "✅ Port scan check complete"
            echo "   Check log: ${NFTBAN_LOG_DIR:-/var/log/nftban}/portscan.log"
            ;;

        history)
            nftban_portscan_banner
            echo ""
            echo "📜 Recent Port Scan Detections (last 24 hours)"
            echo ""

            local log_file="${NFTBAN_LOG_DIR:-/var/log/nftban}/portscan.log"
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
            if nft list chain "${NFTBAN_TABLE_IPV4}" portscan_detection &>/dev/null; then
                echo "  ✅ Port scan detection chain exists (IPv4)"

                # Count rules
                local rule_count
                rule_count=$(nft list chain "${NFTBAN_TABLE_IPV4}" portscan_detection 2>/dev/null | grep -c "log prefix" || true)
                rule_count=${rule_count:-0}
                echo "     Rules: $rule_count logging rules"
            else
                echo "  ❌ Port scan detection chain not found (IPv4)"
                echo "     Run 'nftban portscan enable' to create"
            fi

            if nft list chain "${NFTBAN_TABLE_IPV6}" portscan_detection &>/dev/null; then
                echo "  ✅ Port scan detection chain exists (IPv6)"
            else
                echo "  ❌ Port scan detection chain not found (IPv6)"
            fi

            echo ""
            echo "Checking log file..."
            if [[ -f "${NFTBAN_LOG_DIR:-/var/log/nftban}/portscan.log" ]]; then
                local log_size
                log_size=$(stat -f%z "${NFTBAN_LOG_DIR:-/var/log/nftban}/portscan.log" 2>/dev/null || stat -c%s "${NFTBAN_LOG_DIR:-/var/log/nftban}/portscan.log")
                echo "  ✅ Log file exists: ${NFTBAN_LOG_DIR:-/var/log/nftban}/portscan.log"
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

            local portscan_log="${NFTBAN_PORTSCAN_LOG:-${NFTBAN_LOG_DIR:-/var/log/nftban}/portscan.log}"
            local line_count
            line_count=$(wc -l < "$portscan_log" 2>/dev/null || echo "0")

            echo "✅ Log sync complete"
            echo "   File: $portscan_log"
            echo "   Entries: $line_count"
            ;;

        mode)
            # Handle mode subcommand (show/set)
            local mode_subcmd="${1:-show}"
            shift || true
            local mode_arg="${1:-}"
            _nftban_portscan_mode "$mode_subcmd" "$json_mode" "$mode_arg"
            ;;

        reload|restart)
            echo "Reloading port scan detection..."
            echo ""
            # Disable + re-enable to re-read config and rebuild nft chains
            # v1.40.0: Also fixes wrong jump rule position
            if nftban_portscan_disable 2>/dev/null; then
                echo ""
            fi
            nftban_portscan_enable
            echo ""
            echo "Port scan detection reloaded successfully"
            ;;

        help|--help|-h)
            _nftban_portscan_help
            ;;

        *)
            echo "ERROR: Unknown command: $action" >&2
            echo ""
            echo "Available commands: enable, disable, status, check, history, test, mode, sync, config, reload, restart, help"
            echo "Run 'nftban portscan help' for detailed usage information"
            return 1
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
export -f _nftban_portscan_help
export -f _nftban_portscan_stats_json
export -f _nftban_portscan_mode
export -f _nftban_portscan_config

# Execute if called directly (shouldn't happen, but handle gracefully)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_portscan "$@"
fi
