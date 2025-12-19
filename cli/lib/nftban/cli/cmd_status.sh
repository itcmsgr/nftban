#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Global Status Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Global system status overview
#
# meta:name=cmd_status
# meta:type=cli
# meta:header=NFTBan Global Status
# meta:version=1.0.0
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
# meta:updated_date=2025-11-24


# =============================================================================
# CONFIGURATION
# =============================================================================

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
[[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" ]] && source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf"

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


# Load NFT schema (single source of truth for table/set names)
# shellcheck source=/usr/lib/nftban/lib/nft_schema.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nft_schema.sh"
elif [[ -f "$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")/lib/nft_schema.sh" ]]; then
    # Development fallback: Load from relative path
    source "$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")/lib/nft_schema.sh"
else
    # Last resort: Set defaults
    NFTBAN_TABLE_IPV4="${NFTBAN_TABLE_IPV4:-ip nftban}"
    NFTBAN_TABLE_IPV6="${NFTBAN_TABLE_IPV6:-ip6 nftban}"
fi
# Load statistics library (for centralized counting)
# shellcheck source=/usr/lib/nftban/core/nftban_stats.sh
if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_stats.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/core/nftban_stats.sh"
elif [[ -f "$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")/core/nftban_stats.sh" ]]; then
    # Development fallback: Load from relative path
    source "$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")/core/nftban_stats.sh"
fi

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

    # Show unified banner with health indicator (skip for JSON/quiet output)
    if [[ $json_mode -eq 0 ]] && [[ $quiet_mode -eq 0 ]]; then
        if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
            # shellcheck source=/dev/null
            source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"
            # Use unified banner with health indicator
            if [[ $(type -t nftban_banner_unified) == "function" ]]; then
                nftban_banner_unified "status"
            elif [[ $(type -t nftban_banner) == "function" ]]; then
                nftban_banner
            fi
        fi
    fi

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
    # Output formatted terminal status - Clean professional layout v1.0
    local quiet_mode="$1"

    # Header with version
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NFTBan v${NFTBAN_VERSION:-1.0.0} — System Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # ─────────────────────────────────────────────────────────────────────
    # SYSTEM
    # ─────────────────────────────────────────────────────────────────────
    echo "SYSTEM"
    echo "───────────────────────────────────────────────────────────────"
    printf "  %-20s %s\n" "Hostname............" "$(hostname)"
    printf "  %-20s %s\n" "Kernel.............." "$(uname -r)"
    printf "  %-20s %s\n" "Uptime.............." "$(uptime -p 2>/dev/null | sed 's/^up //' || uptime | awk '{print $3, $4}' | sed 's/,$//')"
    printf "  %-20s %s\n" "NFTBan.............." "v${NFTBAN_VERSION:-unknown}"
    echo ""

    # ─────────────────────────────────────────────────────────────────────
    # FIREWALL
    # ─────────────────────────────────────────────────────────────────────
    echo "FIREWALL"
    echo "───────────────────────────────────────────────────────────────"

    local nft_status="INACTIVE"
    if systemctl is-active nftables.service >/dev/null 2>&1; then
        nft_status="ACTIVE"
    fi
    printf "  %-20s %s\n" "nftables............" "$nft_status"

    # Count rules (using -a to show handles, then count them)
    local rule_count=0
    if command -v nft >/dev/null 2>&1; then
        # nft -a shows "# handle N" for each rule - count those
        rule_count=$(nft -a list table ${NFTBAN_TABLE_IPV4} 2>/dev/null | grep -c "# handle" 2>/dev/null || true)
        rule_count="${rule_count:-0}"
    fi
    printf "  %-20s %s\n" "Rules..............." "$rule_count"

    # Count banned IPs (use centralized function)
    local ban_count=0
    if declare -f nftban_stats_count_active_bans >/dev/null 2>&1; then
        ban_count=$(nftban_stats_count_active_bans)
    fi
    printf "  %-20s %s\n" "Banned IPs.........." "$ban_count"

    # Check master switch
    local master_enabled="true"
    if [[ -f "${NFTBAN_CONFIG_DIR}/conf.d/services.conf.local" ]]; then
        source "${NFTBAN_CONFIG_DIR}/conf.d/services.conf.local" 2>/dev/null || true
        master_enabled="${NFTBAN_ENABLED:-true}"
    fi

    local master_status="ENABLED"
    if grep -q 'nftban=disabled' /proc/cmdline 2>/dev/null; then
        master_status="DISABLED (kernel)"
    elif [[ "$master_enabled" == "false" ]]; then
        master_status="DISABLED (config)"
    fi
    printf "  %-20s %s\n" "Master Control......" "$master_status"
    echo ""

    # ─────────────────────────────────────────────────────────────────────
    # SERVICES
    # ─────────────────────────────────────────────────────────────────────
    echo "SERVICES"
    echo "───────────────────────────────────────────────────────────────"

    check_service_clean "nftables" "nftables.service"
    check_service_clean "suricata" "suricata.service"
    check_service_clean "nftban-core" "${NFTBAN_SERVICE_CORE:-nftban-core.service}"
    check_service_clean "nftban-api" "${NFTBAN_SERVICE_UI:-nftban-ui.service}"
    check_service_clean "nftban-suricata" "${NFTBAN_SERVICE_SURICATA:-nftban-suricata.service}"
    check_service_clean "login-monitor" "${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service}"
    check_service_clean "metrics-exporter" "${NFTBAN_SERVICE_METRICS_EXPORTER:-nftban-metrics-exporter.service}"
    echo ""

    # ─────────────────────────────────────────────────────────────────────
    # PROTECTION MODULES
    # ─────────────────────────────────────────────────────────────────────
    echo "PROTECTION MODULES"
    echo "───────────────────────────────────────────────────────────────"

    # Suricata IDS
    local suricata_status="NOT INSTALLED"
    if systemctl is-active suricata.service >/dev/null 2>&1; then
        if systemctl is-active nftban-suricata.service >/dev/null 2>&1; then
            suricata_status="ACTIVE (IDS + Banning)"
        else
            suricata_status="ACTIVE (IDS only)"
        fi
    elif command -v suricata &>/dev/null; then
        suricata_status="INSTALLED (stopped)"
    fi
    printf "  %-20s %s\n" "Suricata IDS........" "$suricata_status"

    # DDoS Protection
    local ddos_status="UNKNOWN"
    if command -v nftban &>/dev/null; then
        local ddos_output
        ddos_output=$(nftban ddos status 2>/dev/null | grep -E "Module Enabled:|Master Switch:" | head -1) || true
        if [[ "$ddos_output" =~ "true" ]] || [[ "$ddos_output" =~ "ENABLED" ]]; then
            ddos_status="ENABLED (rate-limit active)"
        elif [[ "$ddos_output" =~ "false" ]] || [[ "$ddos_output" =~ "DISABLED" ]]; then
            ddos_status="DISABLED"
        fi
    fi
    printf "  %-20s %s\n" "DDoS................" "$ddos_status"

    # Port-scan Detection
    local portscan_status="UNKNOWN"
    if command -v nftban &>/dev/null; then
        local portscan_output
        portscan_output=$(nftban portscan status 2>/dev/null | grep -E "Module Status:|Master Switch:" | head -1) || true
        if [[ "$portscan_output" =~ "ENABLED" ]] && [[ ! "$portscan_output" =~ "NOT" ]]; then
            portscan_status="ENABLED"
        elif [[ "$portscan_output" =~ "NOT INITIALIZED" ]]; then
            if systemctl is-active suricata.service >/dev/null 2>&1; then
                portscan_status="NOT CONFIGURED"
            else
                portscan_status="DISABLED (Suricata required)"
            fi
        elif [[ "$portscan_output" =~ "DISABLED" ]]; then
            portscan_status="DISABLED"
        fi
    fi
    printf "  %-20s %s\n" "Port Scan..........." "$portscan_status"

    # Trust Feeds (CDN whitelist - including Cloudflare)
    local trust_status="UNKNOWN"
    local trust_count=0
    if command -v nftban-core &>/dev/null; then
        local trust_output
        trust_output=$(nftban-core trust list 2>/dev/null) || true
        trust_count=$(echo "$trust_output" | grep -c "enabled" 2>/dev/null) || trust_count=0
        if [[ $trust_count -gt 0 ]]; then
            trust_status="ENABLED ($trust_count feeds)"
        else
            trust_status="DISABLED"
        fi
    fi
    printf "  %-20s %s\n" "Trust Feeds........." "$trust_status"

    # Feeds
    local feeds_enabled=0
    if [[ -d "${NFTBAN_DATA_DIR}/feeds" ]]; then
        feeds_enabled=$(find "${NFTBAN_DATA_DIR}/feeds" -name "*.txt" -type f 2>/dev/null | wc -l)
    fi
    printf "  %-20s %s Active\n" "Threat Feeds........" "$feeds_enabled"

    # Login Monitor
    local login_status="UNKNOWN"
    local login_details=""
    if systemctl is-active nftban-login-monitor.service >/dev/null 2>&1; then
        login_status="ACTIVE"
        # Get monitoring targets from config
        local login_conf="${NFTBAN_CONFIG_DIR}/conf.d/login_alert.conf"
        local login_local="${NFTBAN_CONFIG_DIR}/conf.d/login_alert.conf.local"
        [[ -f "$login_conf" ]] && source "$login_conf" 2>/dev/null || true
        [[ -f "$login_local" ]] && source "$login_local" 2>/dev/null || true

        local monitors=""
        [[ "${NFTBAN_LOGIN_ALERT_SSH:-true}" == "true" ]] && monitors="${monitors}SSH, "
        [[ "${NFTBAN_LOGIN_ALERT_SU:-true}" == "true" ]] && monitors="${monitors}SU, "
        [[ "${NFTBAN_LOGIN_ALERT_SUDO:-true}" == "true" ]] && monitors="${monitors}SUDO, "
        monitors="${monitors%, }"
        [[ -n "$monitors" ]] && login_details="$monitors"
    elif command -v nftban &>/dev/null; then
        local login_output
        login_output=$(nftban login status 2>/dev/null | grep "Enabled:" | head -1) || true
        if [[ "$login_output" =~ "true" ]]; then
            login_status="ENABLED (stopped)"
        elif [[ "$login_output" =~ "false" ]]; then
            login_status="DISABLED"
        fi
    fi
    printf "  %-20s %s\n" "Login Monitor......." "$login_status"
    [[ -n "$login_details" ]] && printf "      %-16s %s\n" "Watching........" "$login_details"

    # GeoIP/GeoBan
    local geoip_db="${NFTBAN_DATA_DIR}/geoip/GeoLite2-City.mmdb"
    local geoban_status="NOT INSTALLED"
    if [[ -f "$geoip_db" ]]; then
        local db_size db_date
        db_size=$(du -h "$geoip_db" 2>/dev/null | awk '{print $1}' || echo "?")
        db_date=$(stat -c %y "$geoip_db" 2>/dev/null | cut -d' ' -f1 || echo "?")

        local banned_countries
        banned_countries=$(nftban geoban list 2>/dev/null | grep -c "BLOCKED" 2>/dev/null || echo "0")
        banned_countries=$(echo "$banned_countries" | tr -d '\n' | tr -d ' ')

        if [[ "$banned_countries" =~ ^[0-9]+$ ]] && [[ "$banned_countries" -gt 0 ]]; then
            geoban_status="ACTIVE ($banned_countries countries blocked)"
        else
            geoban_status="READY (DB: $db_size, $db_date)"
        fi
    fi
    printf "  %-20s %s\n" "GeoIP / GeoBan......" "$geoban_status"

    # Metrics Database
    local metrics_db_status="NOT INSTALLED"
    local prom_running=false vm_running=false
    systemctl is-active prometheus >/dev/null 2>&1 && prom_running=true
    systemctl is-active victoriametrics >/dev/null 2>&1 && vm_running=true
    if [[ "$prom_running" == "true" ]]; then
        metrics_db_status="Prometheus (running)"
    elif [[ "$vm_running" == "true" ]]; then
        metrics_db_status="VictoriaMetrics (running)"
    elif systemctl list-unit-files 2>/dev/null | grep -qE "^(prometheus|victoriametrics).service"; then
        metrics_db_status="INSTALLED (stopped)"
    fi
    printf "  %-20s %s\n" "Metrics DB.........." "$metrics_db_status"

    # Metrics Exporter
    local metrics_exp_status="NOT INSTALLED"
    if systemctl is-active nftban-metrics-exporter.timer >/dev/null 2>&1 || \
       systemctl is-active nftban-metrics-exporter.service >/dev/null 2>&1; then
        metrics_exp_status="ACTIVE"
    elif systemctl list-unit-files 2>/dev/null | grep -q "nftban-metrics-exporter"; then
        metrics_exp_status="INACTIVE"
    fi
    printf "  %-20s %s\n" "Metrics Exporter...." "$metrics_exp_status"

    # GUI
    local gui_status="NOT INSTALLED"
    if systemctl is-active nftban-ui >/dev/null 2>&1; then
        gui_status="ACTIVE"
    elif systemctl list-unit-files 2>/dev/null | grep -q nftban-ui; then
        gui_status="INACTIVE"
    fi
    printf "  %-20s %s\n" "GUI................." "$gui_status"
    echo ""

    # ─────────────────────────────────────────────────────────────────────
    # HEALTH
    # ─────────────────────────────────────────────────────────────────────
    echo "HEALTH"
    echo "───────────────────────────────────────────────────────────────"

    # Load health module
    # Read from health cache (written by nftban-health.timer)
    local health_cache="${NFTBAN_CACHE_DIR:-/var/cache/nftban}/health/health_status.cache"
    local health_status="UNKNOWN"

    if [[ -r "$health_cache" ]]; then
        health_status=$(cat "$health_cache" 2>/dev/null) || health_status="UNKNOWN"
    fi

    printf "  %-20s %s\n" "Overall Status......" "$health_status"

    # Show hints if not OK
    if [[ "$health_status" != "OK" ]] && [[ $quiet_mode -eq 0 ]]; then
        echo "      → Run: nftban health check"
        echo "      → Auto-fix: nftban health check --auto-heal"
    fi
    echo ""

    # ─────────────────────────────────────────────────────────────────────
    # RECENT ACTIVITY
    # ─────────────────────────────────────────────────────────────────────
    echo "RECENT ACTIVITY"
    echo "───────────────────────────────────────────────────────────────"

    # Count bans today from bans.log
    local bans_today="0"
    local unbans_today="0"
    local ban_log="${NFTBAN_LOG_DIR}/bans.log"
    local today
    today=$(date +%Y-%m-%d)

    if [[ -r "$ban_log" ]]; then
        bans_today=$(grep -c "^${today}.*BANNED$" "$ban_log" 2>/dev/null) || bans_today=0
        unbans_today=$(grep -c "^${today}.*UNBANNED$" "$ban_log" 2>/dev/null) || unbans_today=0
    fi

    printf "  %-20s %s\n" "Bans today.........." "$bans_today"
    printf "  %-20s %s\n" "Unbans today........" "$unbans_today"
    echo ""

    # ─────────────────────────────────────────────────────────────────────
    # TIMERS
    # ─────────────────────────────────────────────────────────────────────
    echo "TIMERS"
    echo "───────────────────────────────────────────────────────────────"

    # Define all NFTBan timers with their descriptions
    local -A timer_desc=(
        ["nftban-health.timer"]="Health check"
        ["nftban-metrics-exporter.timer"]="Prometheus metrics"
        ["nftban-core-feeds.timer"]="Threat feeds update"
        ["nftban-core-geoip.timer"]="GeoIP database update"
        ["nftban-queue.timer"]="Queue processing"
        ["nftban-suricata-update.timer"]="Suricata rules update"
        ["nftban-snapshot.timer"]="Snapshot creation"
        ["nftban-rollback.timer"]="Rollback check"
    )

    local timer_count=0
    local timer_active=0
    local timer_output=""

    for timer in "${!timer_desc[@]}"; do
        if systemctl list-unit-files "$timer" --no-legend 2>/dev/null | grep -q "$timer"; then
            timer_count=$((timer_count + 1))
            local status_text="INACTIVE"
            local next_run=""

            if systemctl is-active "$timer" >/dev/null 2>&1; then
                timer_active=$((timer_active + 1))

                # Get next run time
                next_run=$(systemctl list-timers "$timer" --no-legend 2>/dev/null | awk '{
                    if (NF >= 6) { print $5, $6 }
                    else if (NF >= 2) { print $1, $2 }
                }' || true)

                if [[ -n "$next_run" ]] && [[ "$next_run" != "n/a" ]]; then
                    status_text="OK — next in $next_run"
                else
                    status_text="ACTIVE"
                fi
            elif systemctl is-enabled "$timer" >/dev/null 2>&1; then
                status_text="ENABLED (stopped)"
            fi

            # Format timer name (remove .timer suffix and prefix)
            local timer_name="${timer%.timer}"
            timer_name="${timer_name#nftban-}"
            [[ "$timer_name" == "nftban" ]] && timer_name="main"
            timer_name=$(printf "%-16s" "$timer_name")
            timer_name="${timer_name// /.}"

            timer_output+=$(printf "  %s %s\n" "$timer_name" "$status_text")
            timer_output+=$'\n'
        fi
    done

    if [[ $timer_count -gt 0 ]]; then
        printf "  %-20s %s\n" "Active timers......." "$timer_active / $timer_count"
        echo ""
        echo -n "$timer_output"
    else
        printf "  %-20s %s\n" "Active timers......." "None installed"
    fi
    echo ""

    # ─────────────────────────────────────────────────────────────────────
    # LOGS
    # ─────────────────────────────────────────────────────────────────────
    echo "LOGS"
    echo "───────────────────────────────────────────────────────────────"

    local log_rotation_status="NOT CONFIGURED"
    local log_size="N/A"
    local last_rotate="N/A"

    if [[ -f /etc/logrotate.d/nftban ]]; then
        log_rotation_status="CONFIGURED"
    fi

    if [[ -d "${NFTBAN_LOG_DIR}" ]]; then
        log_size=$(du -sh "${NFTBAN_LOG_DIR}" 2>/dev/null | awk '{print $1}' || echo "N/A")
    fi

    if [[ -f /var/lib/logrotate/status ]] && grep -q "nftban" /var/lib/logrotate/status 2>/dev/null; then
        last_rotate=$(grep "nftban" /var/lib/logrotate/status 2>/dev/null | head -1 | awk '{print $NF}' || echo "N/A")
    elif [[ -f /var/lib/logrotate.status ]] && grep -q "nftban" /var/lib/logrotate.status 2>/dev/null; then
        last_rotate=$(grep "nftban" /var/lib/logrotate.status 2>/dev/null | head -1 | awk '{print $NF}' || echo "N/A")
    fi

    printf "  %-20s %s\n" "Log rotation........" "$log_rotation_status"
    printf "  %-20s %s\n" "Size................" "$log_size"
    printf "  %-20s %s\n" "Last rotation......." "$last_rotate"
    echo ""

    # ─────────────────────────────────────────────────────────────────────
    # SYSTEM REQUIREMENTS
    # ─────────────────────────────────────────────────────────────────────
    echo "SYSTEM REQUIREMENTS"
    echo "───────────────────────────────────────────────────────────────"

    # Check DNS
    local dns_status="NOT WORKING"
    if host google.com >/dev/null 2>&1 || nslookup google.com >/dev/null 2>&1; then
        dns_status="OK"
    fi
    printf "  %-20s %s\n" "DNS................." "$dns_status"

    # Check Email capability
    local email_status="NOT CONFIGURED"
    local email_working=false
    if [[ -f "${NFTBAN_CONFIG_DIR}/conf.d/mail.conf" ]]; then
        if grep -q "MAIL_ENABLED=true" "${NFTBAN_CONFIG_DIR}/conf.d/mail.conf" 2>/dev/null; then
            if command -v sendmail >/dev/null 2>&1 || \
               command -v msmtp >/dev/null 2>&1 || \
               command -v mailx >/dev/null 2>&1; then
                email_status="CONFIGURED"
                email_working=true
            else
                email_status="CONFIGURED (no mail cmd)"
            fi
        fi
    fi
    printf "  %-20s %s\n" "Email..............." "$email_status"

    # Check Auto-Reports
    local report_status="DISABLED"
    if [[ -d "${NFTBAN_DATA_DIR}/reports" ]]; then
        local report_count=$(find "${NFTBAN_DATA_DIR}/reports" -type f \( -name "*.html" -o -name "*.json" \) 2>/dev/null | wc -l)
        if [[ $report_count -gt 0 ]]; then
            report_status="ENABLED ($report_count reports)"
        else
            report_status="ENABLED (no reports yet)"
        fi
    fi
    printf "  %-20s %s\n" "Auto-Reports........" "$report_status"
    echo "      → ${NFTBAN_DATA_DIR}/reports/"
    echo ""

    # ─────────────────────────────────────────────────────────────────────
    # QUICK COMMANDS
    # ─────────────────────────────────────────────────────────────────────
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "QUICK COMMANDS"
    echo "  nftban menu              Interactive TUI menu"
    echo "  nftban health check      Full diagnostics"
    echo "  nftban stats dashboard   Detailed statistics"
    echo "  nftban firewall status   Firewall details"
    echo "  nftban help              Show all commands"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

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

    # PERFORMANCE FIX: Use 'nft list table' instead of 'nft list ruleset'
    # Reason: With large feed sets (5000+ IPs), 'list ruleset' can take 30+ seconds
    #         and consume 100% CPU + 850MB RAM just to serialize all IP addresses.
    #         We only need rule count, not the full IP list.
    # Impact: Reduces execution time from 30s to <1s, CPU from 100% to <5%
    local rule_count=0
    if command -v nft >/dev/null 2>&1; then
        rule_count=$(nft list table ${NFTBAN_TABLE_IPV4} 2>/dev/null | grep -c "^[[:space:]]*rule" 2>/dev/null || true)
        rule_count=${rule_count:-0}
    fi
    echo "    \"rule_count\": $rule_count,"

    # v0.7.3: Use unified blacklist_ipv4/ipv6 sets (all bans consolidated)
    local ban_count=0
    if command -v nftban_stats_count_active_bans >/dev/null 2>&1; then
        # Use stats module function (correct for v0.7.3)
        ban_count=$(nftban_stats_count_active_bans 2>/dev/null || echo 0)
    elif nft list set ${NFTBAN_TABLE_IPV4} blacklist_ipv4 >/dev/null 2>&1; then
        # Fallback: Count blacklist_ipv4 + blacklist_ipv6 manually
        local black_v4 black_v6
        black_v4=$(nft list set ${NFTBAN_TABLE_IPV4} blacklist_ipv4 2>/dev/null | { grep -oP '\d+\.\d+\.\d+\.\d+' || true; } | wc -l || echo 0)
        black_v6=$(nft list set ${NFTBAN_TABLE_IPV6} blacklist_ipv6 2>/dev/null | { grep -oP '[0-9a-fA-F:]+::[0-9a-fA-F:]*|[0-9a-fA-F:]+:[0-9a-fA-F:]+' || true; } | wc -l || echo 0)
        ban_count=$((black_v4 + black_v6))
    fi
    echo "    \"banned_ips\": $ban_count,"

    # Add GUI-required fields for dashboard
    # whitelist_ips: Total whitelist count
    local whitelist_count=0
    if command -v nftban_stats_count_whitelist >/dev/null 2>&1; then
        whitelist_count=$(nftban_stats_count_whitelist 2>/dev/null || echo 0)
    fi
    echo "    \"whitelist_ips\": $whitelist_count,"

    # feed_ips: Count of IPs from threat feeds (part of unified blacklist in v0.7.3)
    # NOTE: In v0.7.3, feeds are loaded into unified blacklist, can't distinguish
    # Return 0 or query feed config files for count
    echo "    \"feed_ips\": 0,"

    # threats_blocked_24h: Bans in last 24 hours
    local threats_24h=0
    if command -v nftban_stats_count_bans >/dev/null 2>&1; then
        local since=$(($(date +%s) - 86400))
        threats_24h=$(nftban_stats_count_bans "$since" 2>/dev/null || echo 0)
    fi
    echo "    \"threats_blocked_24h\": $threats_24h"
    echo "  },"

    # Master control
    local master_enabled="true"
    if [[ -f "${NFTBAN_CONFIG_DIR}/conf.d/services.conf.local" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_CONFIG_DIR}/conf.d/services.conf.local" 2>/dev/null || true
        master_enabled="${NFTBAN_ENABLED:-true}"
    fi
    if grep -q 'nftban=disabled' /proc/cmdline 2>/dev/null; then
        master_enabled="false"
    fi
    echo "  \"master_enabled\": $master_enabled,"

    # Services (detailed)
    echo "  \"services\": {"

    # Helper to get service info as JSON
    _json_service_info() {
        local unit="$1"
        local status="inactive" pid="" mem="" uptime=""

        if ! systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q "$unit"; then
            echo "null"
            return
        fi

        if systemctl is-active "$unit" >/dev/null 2>&1; then
            status="active"
            pid=$(systemctl show "$unit" --property=MainPID --value 2>/dev/null || echo "")
            # pid=0 means no main process, treat as null
            if [[ -n "$pid" ]] && [[ "$pid" != "0" ]]; then
                mem=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{printf "%.1f", $1/1024}' || echo "")
                local start_time
                start_time=$(ps -o lstart= -p "$pid" 2>/dev/null || echo "")
                if [[ -n "$start_time" ]]; then
                    local start_epoch now_epoch
                    start_epoch=$(date -d "$start_time" +%s 2>/dev/null || echo "0")
                    now_epoch=$(date +%s)
                    uptime=$((now_epoch - start_epoch))
                fi
            else
                pid=""  # Reset 0 to empty so it becomes null
            fi
        elif systemctl is-enabled "$unit" >/dev/null 2>&1; then
            status="enabled"
        fi

        # Build JSON with proper null handling
        local pid_json="${pid:-null}"
        [[ -n "$pid" ]] && pid_json="$pid"
        local mem_json="${mem:-null}"
        [[ -n "$mem" ]] && mem_json="$mem"
        local uptime_json="${uptime:-null}"
        [[ -n "$uptime" ]] && uptime_json="$uptime"

        echo "{\"status\": \"$status\", \"pid\": $pid_json, \"memory_mb\": $mem_json, \"uptime_sec\": $uptime_json}"
    }

    echo "    \"nftables\": $(_json_service_info nftables.service),"
    echo "    \"suricata\": $(_json_service_info suricata.service),"
    echo "    \"nftban_core\": $(_json_service_info "${NFTBAN_SERVICE_CORE:-nftban-core.service}"),"
    echo "    \"nftban_api\": $(_json_service_info "${NFTBAN_SERVICE_UI:-nftban-ui.service}"),"
    echo "    \"nftban_suricata\": $(_json_service_info "${NFTBAN_SERVICE_SURICATA:-nftban-suricata.service}"),"
    echo "    \"login_monitor\": $(_json_service_info "${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service}"),"
    echo "    \"metrics_exporter\": $(_json_service_info "${NFTBAN_SERVICE_METRICS_EXPORTER:-nftban-metrics-exporter.service}")"
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
    echo "  },"

    # System info for GUI
    local uptime_sec
    uptime_sec=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)
    local kernel
    kernel=$(uname -r 2>/dev/null || echo "unknown")

    echo "  \"system\": {"
    echo "    \"kernel\": \"$kernel\","
    echo "    \"uptime_sec\": $uptime_sec"
    echo "  },"

    # Protection modules status
    echo "  \"protection\": {"

    # Suricata
    local suricata_enabled=false suricata_banning=false
    systemctl is-active suricata.service >/dev/null 2>&1 && suricata_enabled=true
    systemctl is-active nftban-suricata.service >/dev/null 2>&1 && suricata_banning=true
    echo "    \"suricata\": {\"enabled\": $suricata_enabled, \"banning\": $suricata_banning},"

    # Login Monitor
    local login_enabled=false
    systemctl is-active nftban-login-monitor.service >/dev/null 2>&1 && login_enabled=true
    echo "    \"login_monitor\": {\"enabled\": $login_enabled},"

    # GeoIP
    local geoip_installed=false geoip_countries=0
    if [[ -f "${NFTBAN_DATA_DIR}/geoip/GeoLite2-City.mmdb" ]]; then
        geoip_installed=true
        geoip_countries=$(nftban geoban list 2>/dev/null | grep -c "BLOCKED" 2>/dev/null || true)
        geoip_countries="${geoip_countries:-0}"
    fi
    echo "    \"geoip\": {\"installed\": $geoip_installed, \"blocked_countries\": $geoip_countries},"

    # Feeds
    local feeds_count=0
    if [[ -d "${NFTBAN_DATA_DIR}/feeds" ]]; then
        feeds_count=$(find "${NFTBAN_DATA_DIR}/feeds" -name "*.txt" -type f 2>/dev/null | wc -l || true)
        feeds_count="${feeds_count:-0}"
    fi
    echo "    \"feeds\": {\"count\": $feeds_count}"
    echo "  },"

    # Timers
    echo "  \"timers\": {"
    local timer_list=("nftban-health.timer" "nftban-feeds.timer" "nftban-geoip-update.timer" "nftban-maintenance.timer" "nftban-stats.timer" "nftban-metrics-exporter.timer")
    local timer_json=""
    for timer in "${timer_list[@]}"; do
        local timer_name="${timer%.timer}"
        timer_name="${timer_name#nftban-}"
        local timer_active=false
        systemctl is-active "$timer" >/dev/null 2>&1 && timer_active=true
        [[ -n "$timer_json" ]] && timer_json+=","
        timer_json+="\"$timer_name\": $timer_active"
    done
    echo "    $timer_json"
    echo "  }"

    echo "}"


    # Exit marker for testing validation
    command -v nftban_cmd_exit >/dev/null 2>&1 && nftban_cmd_exit "status"
    return 0
}

check_service_clean() {
    # Check and display service status with clean format (dot leaders)
    # Args: service_name systemd_unit
    local name="$1"
    local unit="$2"

    # Pad name with dots for alignment
    local padded_name
    padded_name=$(printf "%-16s" "$name")
    padded_name="${padded_name// /.}"

    # Check if unit exists
    if ! systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q "$unit"; then
        printf "  %s NOT INSTALLED\n" "$padded_name"
        return 0
    fi

    # Check if active
    if ! systemctl is-active "$unit" >/dev/null 2>&1; then
        # For timer-triggered services, check if the corresponding timer is active
        local timer_unit="${unit%.service}.timer"
        if systemctl is-active "$timer_unit" >/dev/null 2>&1; then
            printf "  %s TIMER (scheduled)\n" "$padded_name"
            return 0
        fi
        # Check if enabled but not running
        if systemctl is-enabled "$unit" >/dev/null 2>&1; then
            printf "  %s ENABLED (stopped)\n" "$padded_name"
        else
            printf "  %s INACTIVE\n" "$padded_name"
        fi
        return 0
    fi

    # Active - get details
    local pid mem_mb uptime_str=""
    pid=$(systemctl show "$unit" --property=MainPID --value 2>/dev/null || echo "")

    if [[ -n "$pid" ]] && [[ "$pid" != "0" ]]; then
        # Memory in MB
        mem_mb=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{printf "%.1fMB", $1/1024}' || echo "")

        # Uptime
        local start_time start_epoch now_epoch
        start_time=$(ps -o lstart= -p "$pid" 2>/dev/null || echo "")
        if [[ -n "$start_time" ]]; then
            start_epoch=$(date -d "$start_time" +%s 2>/dev/null || echo "0")
            now_epoch=$(date +%s)
            local uptime_sec=$((now_epoch - start_epoch))
            if [[ $uptime_sec -ge 86400 ]]; then
                uptime_str="$((uptime_sec / 86400))d"
            elif [[ $uptime_sec -ge 3600 ]]; then
                uptime_str="$((uptime_sec / 3600))h"
            else
                uptime_str="$((uptime_sec / 60))m"
            fi
        fi

        local details=""
        [[ -n "$pid" ]] && details="pid:$pid"
        [[ -n "$mem_mb" ]] && details="${details:+$details }$mem_mb"
        [[ -n "$uptime_str" ]] && details="${details:+$details }up:$uptime_str"

        printf "  %s ACTIVE (%s)\n" "$padded_name" "$details"
    else
        printf "  %s ACTIVE\n" "$padded_name"
    fi
    return 0
}

check_service_detailed() {
    # Check and display detailed service status with memory, CPU, PID, uptime, port
    # Args: service_name systemd_unit
    local name="$1"
    local unit="$2"

    # Check if unit exists
    if ! systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q "$unit"; then
        printf "  %-18s ⚪ Not installed\n" "$name:"
        return 0
    fi

    # Check if active
    if ! systemctl is-active "$unit" >/dev/null 2>&1; then
        # Check if enabled but not running
        if systemctl is-enabled "$unit" >/dev/null 2>&1; then
            printf "  %-18s ⚠️  Enabled (not running)\n" "$name:"
        else
            printf "  %-18s ⚪ Inactive\n" "$name:"
        fi
        return 0
    fi

    # Active - get details
    local pid mem_mb uptime_str port_info=""

    # Get main PID
    pid=$(systemctl show "$unit" --property=MainPID --value 2>/dev/null || echo "")

    if [[ -n "$pid" ]] && [[ "$pid" != "0" ]]; then
        # Get memory usage (RSS in MB)
        mem_mb=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{printf "%.1f", $1/1024}' || echo "?")

        # Get process uptime
        local start_time
        start_time=$(ps -o lstart= -p "$pid" 2>/dev/null || echo "")
        if [[ -n "$start_time" ]]; then
            local start_epoch now_epoch diff_sec
            start_epoch=$(date -d "$start_time" +%s 2>/dev/null || echo "0")
            now_epoch=$(date +%s)
            diff_sec=$((now_epoch - start_epoch))

            if [[ $diff_sec -ge 86400 ]]; then
                uptime_str="$((diff_sec / 86400))d"
            elif [[ $diff_sec -ge 3600 ]]; then
                uptime_str="$((diff_sec / 3600))h"
            elif [[ $diff_sec -ge 60 ]]; then
                uptime_str="$((diff_sec / 60))m"
            else
                uptime_str="${diff_sec}s"
            fi
        else
            uptime_str="?"
        fi

        # Get listening port for certain services
        case "$name" in
            nftban-api)
                port_info=$(ss -tlnp 2>/dev/null | grep "pid=$pid" | awk '{print $4}' | grep -oP ':\d+$' | tr '\n' ',' | sed 's/,$//' || echo "")
                ;;
            metrics-exporter)
                port_info=$(ss -tlnp 2>/dev/null | grep "pid=$pid" | awk '{print $4}' | grep -oP ':\d+$' | tr '\n' ',' | sed 's/,$//' || echo "")
                ;;
            suricata)
                # Suricata uses AF_PACKET, check interface
                local iface
                iface=$(grep -oP 'interface:\s*\K\S+' /etc/suricata/suricata.yaml 2>/dev/null | head -1 || echo "")
                [[ -n "$iface" ]] && port_info="$iface"
                ;;
        esac

        # Build output line
        local detail_str="pid:$pid mem:${mem_mb}MB up:$uptime_str"
        [[ -n "$port_info" ]] && detail_str="$detail_str $port_info"

        printf "  %-18s ✅ Active (%s)\n" "$name:" "$detail_str"
    else
        printf "  %-18s ✅ Active\n" "$name:"
    fi
}

check_service() {
    # Check and display service status (simple version)
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
    • Service status (nftables, login-alert)
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
