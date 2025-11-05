#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.30.0 - Global Status Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Global system status overview
#
# meta:name=cmd_status
# meta:type=cli
# meta:header=NFTBan Global Status
# meta:version=0.30.1
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Provides consolidated system status overview (firewall, services, protections, alerts)
# meta:input=Command line options (--json, --quiet)
# meta:output=Formatted status dashboard with health indicators
#
# **Inventory & Requirements**
# meta:depends=bash,nftban_output.sh,nftban_health.sh
#
# meta:created_date=2025-11-05

set -Eeuo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

NFTBAN_LIB_DIR="${NFTBAN_LIB_DIR:-/usr/lib/nftban}"

# =============================================================================
# STATUS AGGREGATION
# =============================================================================

nftban_cmd_status() {
    # Display global system status overview
    # Args: [--json] [--quiet]

    local json_mode=0
    local quiet_mode=0

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                json_mode=1
                shift
                ;;
            --quiet)
                quiet_mode=1
                shift
                ;;
            help|--help|-h)
                show_usage
                return 0
                ;;
            *)
                echo "ERROR: Unknown option: $1" >&2
                echo "" >&2
                show_usage
                return 1
                ;;
        esac
    done

    # JSON mode
    if [[ $json_mode -eq 1 ]]; then
        output_json
        return $?
    fi

    # Terminal mode (default)
    output_terminal "$quiet_mode"
    return $?
}

output_terminal() {
    # Output formatted terminal status
    local quiet_mode="$1"

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "NFTBAN — Global System Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # System Info
    echo "📋 SYSTEM"
    echo "────────────────────────────────────────────────────────────────"
    echo "  Hostname:       $(hostname)"
    echo "  Kernel:         $(uname -r)"
    echo "  Uptime:         $(uptime -p 2>/dev/null || uptime | awk '{print $3, $4}')"
    echo "  NFTBan:         v${NFTBAN_VERSION:-unknown}"
    echo ""

    # Firewall Status
    echo "🔥 FIREWALL"
    echo "────────────────────────────────────────────────────────────────"

    local nft_status="❌ Not active"
    if systemctl is-active nftables.service >/dev/null 2>&1; then
        nft_status="✅ Active"
    fi
    echo "  nftables:       $nft_status"

    # Count rules
    local rule_count=0
    if command -v nft >/dev/null 2>&1; then
        rule_count=$(nft list ruleset 2>/dev/null | grep -c "^[[:space:]]*[^#]" || echo 0)
    fi
    echo "  Rules:          $rule_count"

    # Count banned IPs
    local ban_count=0
    if nft list set inet nftban_main ban_v4 >/dev/null 2>&1; then
        ban_count=$(nft list set inet nftban_main ban_v4 2>/dev/null | grep -c "elements = {" || echo 0)
    fi
    echo "  Banned IPs:     $ban_count"
    echo ""

    # Services Status
    echo "⚙️  SERVICES"
    echo "────────────────────────────────────────────────────────────────"

    check_service "nftables" "nftables.service"
    check_service "fail2ban" "fail2ban.service"
    check_service "nftban-login-alert" "nftban-login-alert.service"
    echo ""

    # Protection Modules
    echo "🛡️  PROTECTION MODULES"
    echo "────────────────────────────────────────────────────────────────"

    # DDoS
    local ddos_status="❓ Unknown"
    if [[ -f "${NFTBAN_LIB_DIR}/cli/cmd_ddos.sh" ]]; then
        if nft list chain inet nftban_main input 2>/dev/null | grep -q "ct state new limit"; then
            ddos_status="✅ Enabled"
        else
            ddos_status="⚪ Disabled"
        fi
    fi
    echo "  DDoS:           $ddos_status"

    # Port-scan
    local portscan_status="❓ Unknown"
    if [[ -f "${NFTBAN_LIB_DIR}/cli/cmd_portscan.sh" ]]; then
        if nft list chain inet nftban_main input 2>/dev/null | grep -q "tcp flags & (fin|syn|rst|psh|ack|urg)"; then
            portscan_status="✅ Enabled"
        else
            portscan_status="⚪ Disabled"
        fi
    fi
    echo "  Port-scan:      $portscan_status"

    # Cloudflare
    local cf_status="❓ Unknown"
    if [[ -f /var/lib/nftban/cloudflare/enabled ]]; then
        cf_status="✅ Enabled"
    elif [[ -f /var/lib/nftban/cloudflare/disabled ]]; then
        cf_status="⚪ Disabled"
    fi
    echo "  Cloudflare:     $cf_status"

    # Feeds
    local feeds_enabled=0
    if [[ -d /var/lib/nftban/feeds ]]; then
        feeds_enabled=$(find /var/lib/nftban/feeds -name "*.txt" -type f 2>/dev/null | wc -l)
    fi
    echo "  Threat Feeds:   $feeds_enabled active"
    echo ""

    # Health Check (quick)
    echo "🏥 HEALTH"
    echo "────────────────────────────────────────────────────────────────"

    # Load health module
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_health.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/core/nftban_health.sh"

        # Run quick check (silent mode)
        local health_exit=0
        nftban_health_check_all 0 >/dev/null 2>&1 || health_exit=$?

        case $health_exit in
            0) echo "  Status:         ✅ Healthy" ;;
            1) echo "  Status:         ⚠️  Warnings detected" ;;
            2) echo "  Status:         ❌ Errors detected" ;;
            *) echo "  Status:         ❓ Unknown" ;;
        esac

        # Show summary if issues found
        if [[ $health_exit -gt 0 ]] && [[ $quiet_mode -eq 0 ]]; then
            echo ""
            echo "  Run 'nftban health check' for details"
            echo "  Run 'nftban health check --auto-heal' to fix issues"
        fi
    else
        echo "  Status:         ❓ Health module not found"
    fi
    echo ""

    # Quick Stats (if available)
    echo "📊 RECENT ACTIVITY"
    echo "────────────────────────────────────────────────────────────────"

    # Check for fail2ban banned count
    if command -v fail2ban-client >/dev/null 2>&1 && systemctl is-active fail2ban.service >/dev/null 2>&1; then
        local f2b_bans=0
        f2b_bans=$(fail2ban-client status 2>/dev/null | grep "Currently banned" | awk '{print $4}' || echo 0)
        echo "  Fail2ban bans:  $f2b_bans"
    else
        echo "  Fail2ban bans:  N/A"
    fi

    # Check for recent nftables log entries
    if [[ -r /var/log/nftban/nftables.log ]]; then
        local recent_blocks=0
        recent_blocks=$(grep -c "$(date +%Y-%m-%d)" /var/log/nftban/nftables.log 2>/dev/null || echo 0)
        echo "  Blocks today:   $recent_blocks"
    else
        echo "  Blocks today:   N/A"
    fi
    echo ""

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "💡 QUICK ACTIONS"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  nftban menu                 Interactive TUI menu"
    echo "  nftban health check         Full diagnostics"
    echo "  nftban stats dashboard      Detailed statistics"
    echo "  nftban firewall status      Firewall details"
    echo "  nftban help                 Show all commands"
    echo ""

    return 0
}

output_json() {
    # Output JSON format
    echo "{"
    echo "  \"version\": \"${NFTBAN_VERSION:-unknown}\","
    echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"hostname\": \"$(hostname)\","

    # Firewall
    local nft_active=false
    systemctl is-active nftables.service >/dev/null 2>&1 && nft_active=true

    echo "  \"firewall\": {"
    echo "    \"nftables_active\": $nft_active,"

    local rule_count=0
    if command -v nft >/dev/null 2>&1; then
        rule_count=$(nft list ruleset 2>/dev/null | grep -c "^[[:space:]]*[^#]" || echo 0)
    fi
    echo "    \"rule_count\": $rule_count,"

    local ban_count=0
    if nft list set inet nftban_main ban_v4 >/dev/null 2>&1; then
        ban_count=$(nft list set inet nftban_main ban_v4 2>/dev/null | grep -c "elements = {" || echo 0)
    fi
    echo "    \"banned_ips\": $ban_count"
    echo "  },"

    # Services
    echo "  \"services\": {"
    echo "    \"nftables\": \"$(systemctl is-active nftables.service 2>/dev/null || echo inactive)\","
    echo "    \"fail2ban\": \"$(systemctl is-active fail2ban.service 2>/dev/null || echo inactive)\","
    echo "    \"login_alert\": \"$(systemctl is-active nftban-login-alert.service 2>/dev/null || echo inactive)\""
    echo "  },"

    # Health
    local health_exit=0
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_health.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/core/nftban_health.sh"
        nftban_health_check_all 0 >/dev/null 2>&1 || health_exit=$?
    fi

    local health_status="unknown"
    case $health_exit in
        0) health_status="healthy" ;;
        1) health_status="warnings" ;;
        2) health_status="errors" ;;
    esac

    echo "  \"health\": {"
    echo "    \"status\": \"$health_status\","
    echo "    \"exit_code\": $health_exit"
    echo "  }"
    echo "}"

    return 0
}

check_service() {
    # Check and display service status
    # Args: service_name systemd_unit
    local name="$1"
    local unit="$2"

    local status="❌ Inactive"
    if systemctl is-active "$unit" >/dev/null 2>&1; then
        status="✅ Active"
    fi

    printf "  %-20s %s\n" "$name:" "$status"
}

show_usage() {
    cat <<'EOF'
nftban status — Global system status overview

USAGE:
  nftban status [OPTIONS]

OPTIONS:
  --json          Output in JSON format
  --quiet         Suppress suggestions and tips
  --help          Show this help

DESCRIPTION:
  Displays a consolidated overview of:
    • System information (hostname, kernel, uptime)
    • Firewall status (nftables, rules, bans)
    • Service status (nftables, fail2ban, login-alert)
    • Protection modules (DDoS, port-scan, Cloudflare, feeds)
    • Health check summary
    • Recent activity statistics

EXAMPLES:
  nftban status                Show full status dashboard
  nftban status --json         Output as JSON
  nftban status --quiet        Show status without tips

SEE ALSO:
  nftban health check         Full diagnostics
  nftban firewall status      Detailed firewall info
  nftban stats dashboard      Detailed statistics
EOF
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_cmd_status

# =============================================================================
# DIRECT EXECUTION SUPPORT
# =============================================================================

# If executed directly (not sourced), run the command handler
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_status "$@"
fi
