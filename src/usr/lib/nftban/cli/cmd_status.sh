#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.32.22 - Global Status Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Global system status overview
#
# meta:name=cmd_status
# meta:type=cli
# meta:header=NFTBan Global Status
# meta:version=0.32.22
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
        if nft list chain inet nftban_main portscan_detection 2>/dev/null | grep -q "log prefix"; then
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

    # System Requirements & Warnings
    echo "⚙️  SYSTEM REQUIREMENTS"
    echo "────────────────────────────────────────────────────────────────"

    local warnings=0

    # Check DNS
    if host google.com >/dev/null 2>&1 || nslookup google.com >/dev/null 2>&1; then
        echo "  DNS:            ✅ Working"
    else
        echo "  DNS:            ⚠️  Not working"
        echo "                  → Feeds/Cloudflare updates will FAIL"
        warnings=$((warnings + 1))
    fi

    # Check Email capability
    local email_status="⚪ Not configured"
    local email_working=false
    if [[ -f /etc/nftban/conf.d/mail.conf ]]; then
        # Check if mail is configured
        if grep -q "MAIL_ENABLED=true" /etc/nftban/conf.d/mail.conf 2>/dev/null; then
            # Check if can send email (test common methods)
            if command -v sendmail >/dev/null 2>&1 || \
               command -v msmtp >/dev/null 2>&1 || \
               command -v mailx >/dev/null 2>&1; then
                email_status="✅ Configured"
                email_working=true
            else
                email_status="⚠️  Configured but no mail command"
                warnings=$((warnings + 1))
            fi
        fi
    fi
    echo "  Email:          $email_status"

    # Check SMTP ports (25, 587, 465)
    if [[ "$email_working" == true ]]; then
        local smtp_port_status=""
        local ports_open=0

        # Port 25 (SMTP)
        if timeout 2 bash -c "cat < /dev/null > /dev/tcp/smtp.gmail.com/25" 2>/dev/null; then
            smtp_port_status="${smtp_port_status}25✅ "
            ports_open=$((ports_open + 1))
        else
            smtp_port_status="${smtp_port_status}25❌ "
        fi

        # Port 587 (Submission)
        if timeout 2 bash -c "cat < /dev/null > /dev/tcp/smtp.gmail.com/587" 2>/dev/null; then
            smtp_port_status="${smtp_port_status}587✅ "
            ports_open=$((ports_open + 1))
        else
            smtp_port_status="${smtp_port_status}587❌ "
        fi

        # Port 465 (SMTPS)
        if timeout 2 bash -c "cat < /dev/null > /dev/tcp/smtp.gmail.com/465" 2>/dev/null; then
            smtp_port_status="${smtp_port_status}465✅"
            ports_open=$((ports_open + 1))
        else
            smtp_port_status="${smtp_port_status}465❌"
        fi

        echo "  SMTP Ports:     $smtp_port_status"

        if [[ $ports_open -eq 0 ]]; then
            echo "                  → All ports blocked - Email will FAIL"
            warnings=$((warnings + 1))
        fi
    fi

    # Check Auto-Reports (currently only local save, no remote upload)
    local report_status="⚪ Disabled"

    # Reports are saved locally in /var/lib/nftban/reports/
    if [[ -d /var/lib/nftban/reports ]]; then
        local report_count=$(find /var/lib/nftban/reports -type f -name "*.html" -o -name "*.json" 2>/dev/null | wc -l)
        if [[ $report_count -gt 0 ]]; then
            report_status="✅ Enabled (${report_count} reports saved)"
        else
            report_status="⚪ Enabled (no reports yet)"
        fi
    fi

    echo "  Auto-Reports:   $report_status"
    echo "                  → Saved to: /var/lib/nftban/reports/"

    # Show warning if email enabled but can't send
    if [[ "$email_working" == false ]] && [[ -f /etc/nftban/conf.d/mail.conf ]]; then
        if grep -q "NFTBAN_LOGIN_ALERT=\"YES\"" /etc/nftban/conf.d/mail.conf 2>/dev/null; then
            echo ""
            echo "  ⚠️  Login alerts enabled but email not configured!"
            echo "      Alerts will NOT be sent"
            warnings=$((warnings + 1))
        fi
    fi

    # Check if feeds enabled but DNS broken
    if [[ $feeds_enabled -gt 0 ]]; then
        if ! host google.com >/dev/null 2>&1; then
            echo ""
            echo "  ⚠️  WARNING: Feeds enabled but DNS not working!"
            echo "              Feed updates will FAIL"
            warnings=$((warnings + 1))
        fi
    fi

    # Check if Cloudflare enabled but DNS broken
    if [[ "$cf_status" == "✅ Enabled" ]]; then
        if ! host cloudflare.com >/dev/null 2>&1; then
            echo ""
            echo "  ⚠️  WARNING: Cloudflare enabled but DNS not working!"
            echo "              Cloudflare updates will FAIL"
            warnings=$((warnings + 1))
        fi
    fi

    if [[ $warnings -eq 0 ]]; then
        echo ""
        echo "  ✅ All requirements met"
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
