#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Email Report Generator
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Generate and send HTML email reports with real firewall stats
#
# meta:name="nftban_report_email"
# meta:type="core"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2025-12-03"
#
# meta:description="Generates HTML email reports with real firewall statistics"
# meta:input="Recipient email, optional template path"
# meta:output="HTML email via sendmail or mail command"
# meta:depends="bash,nft,sendmail"
#
# meta:inventory.files="/usr/share/nftban/templates/email/report_template.html"
# meta:inventory.binaries="sendmail,mail"
# meta:inventory.env_vars="NFTBAN_MAIL_RECIPIENT"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail

# Load main configuration (service names, paths)
if [[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" ]]; then
    source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" || true
fi
source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf.local" 2>/dev/null || true

# Prevent double-loading
[[ -n "${NFTBAN_REPORT_EMAIL_LOADED:-}" ]] && return 0
readonly NFTBAN_REPORT_EMAIL_LOADED=1

# =============================================================================
# GENERATE EMAIL REPORT
# =============================================================================

nftban_report_email_generate() {
    local recipient="${1:-${NFTBAN_MAIL_RECIPIENT:-}}"
    local template="/usr/share/nftban/templates/email/report_template.html"

    if [[ -z "$recipient" ]]; then
        echo "ERROR: No recipient specified" >&2
        return 1
    fi

    if [[ ! -f "$template" ]]; then
        echo "ERROR: Email template not found: $template" >&2
        return 1
    fi

    # Get hostname and date
    local hostname
    hostname=$(hostname -f 2>/dev/null || hostname)
    local date_now
    date_now=$(date '+%Y-%m-%d %H:%M')
    local report_id
    report_id=$(date +%Y%m%d%H%M%S)-$(head -c 4 /dev/urandom | xxd -p)

    # ==========================================================================
    # GET REAL DATA FROM NFTABLES
    # ==========================================================================

    # Count blocked IPs from nft blacklist sets (IPv4 + IPv6)
    local blocked_ips=0 _blocked_v4=0 _blocked_v6=0
    if timeout 10s nft list set ip nftban blacklist_ipv4 &>/dev/null; then
        _blocked_v4=$(timeout 10s nft list set ip nftban blacklist_ipv4 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?' | wc -l || echo 0)
    fi
    if timeout 10s nft list set ip6 nftban blacklist_ipv6 &>/dev/null; then
        _blocked_v6=$(timeout 10s nft list set ip6 nftban blacklist_ipv6 2>/dev/null | grep -cE '[0-9a-f:]+/|[0-9a-f]{2,}:' || true)
        _blocked_v6=${_blocked_v6:-0}
    fi
    blocked_ips=$(( _blocked_v4 + _blocked_v6 ))

    # Count whitelist (IPv4 + IPv6)
    local whitelist_count=0 _wl_v4=0 _wl_v6=0
    if timeout 10s nft list set ip nftban whitelist_ipv4 &>/dev/null; then
        _wl_v4=$(timeout 10s nft list set ip nftban whitelist_ipv4 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?' | wc -l || echo 0)
    fi
    if timeout 10s nft list set ip6 nftban whitelist_ipv6 &>/dev/null; then
        _wl_v6=$(timeout 10s nft list set ip6 nftban whitelist_ipv6 2>/dev/null | grep -cE '[0-9a-f:]+/|[0-9a-f]{2,}:' || true)
        _wl_v6=${_wl_v6:-0}
    fi
    whitelist_count=$(( _wl_v4 + _wl_v6 ))

    # ==========================================================================
    # GET THREAT FEEDS STATUS
    # ==========================================================================

    local feeds_status=""
    local feeds_dir="${NFTBAN_DATA_DIR}/feeds"

    if [[ -d "$feeds_dir" ]]; then
        local feed_count=0
        for feed_file in "$feeds_dir"/*.txt; do
            [[ ! -f "$feed_file" ]] && continue
            local feed_name
            feed_name=$(basename "$feed_file" .txt | tr '[:lower:]' '[:upper:]')
            local ip_count
            ip_count=$(wc -l < "$feed_file" 2>/dev/null || echo 0)
            local last_update
            last_update=$(date -r "$feed_file" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "unknown")

            # v1.19.20 FIX
            ((feed_count++)) || true
            local border="border-bottom:1px solid #475569;"

            feeds_status+="<tr>
                <td style=\"padding:12px 16px;${border}\">
                    <span style=\"color:#f1f5f9;\">${feed_name}</span>
                    <div style=\"font-size:11px;color:#64748b;\">Updated: ${last_update}</div>
                </td>
                <td style=\"padding:12px 16px;text-align:right;${border}\">
                    <span style=\"color:#22c55e;font-weight:bold;\">${ip_count} IPs</span>
                </td>
            </tr>"
        done

        if [[ $feed_count -eq 0 ]]; then
            feeds_status="<tr><td style=\"padding:16px;text-align:center;color:#64748b;\" colspan=\"2\">No feeds loaded</td></tr>"
        fi
    else
        feeds_status="<tr><td style=\"padding:16px;text-align:center;color:#64748b;\" colspan=\"2\">Feeds directory not found</td></tr>"
    fi

    # ==========================================================================
    # GET NEW BANS FROM LOG (Last 24h)
    # ==========================================================================

    local login_bans=0 portscan_bans=0 ddos_bans=0 manual_bans=0
    local yesterday
    yesterday=$(date -d '1 day ago' '+%Y-%m-%d')
    local today
    today=$(date '+%Y-%m-%d')

    # Count login bans from login_alert.log (primary source)
    local login_alert_log="${NFTBAN_LOG_DIR}/login_alert.log"
    if [[ -f "$login_alert_log" ]]; then
        # Count actual "Banning" entries from yesterday and today
        login_bans=$(grep "Banning IP" "$login_alert_log" 2>/dev/null | grep -E "^\[${yesterday}|^\[${today}" | wc -l || true)
        login_bans=${login_bans//[^0-9]/}  # Strip non-digits
        login_bans=${login_bans:-0}
    fi

    # Count portscan bans
    local portscan_log="${NFTBAN_LOG_DIR}/portscan.log"
    if [[ -f "$portscan_log" ]]; then
        portscan_bans=$(grep -Ei "ban|block" "$portscan_log" 2>/dev/null | grep -E "^\[${yesterday}|^\[${today}" | wc -l || true)
        portscan_bans=${portscan_bans//[^0-9]/}
        portscan_bans=${portscan_bans:-0}
    fi

    # Count DDoS bans
    local ddos_log="${NFTBAN_LOG_DIR}/ddos.log"
    if [[ -f "$ddos_log" ]]; then
        ddos_bans=$(grep -Ei "ban|block" "$ddos_log" 2>/dev/null | grep -E "^\[${yesterday}|^\[${today}" | wc -l || true)
        ddos_bans=${ddos_bans//[^0-9]/}
        ddos_bans=${ddos_bans:-0}
    fi

    # Fallback: try bans.log if it exists
    # Format: DATE|TIME|SOURCE|IP|COUNTRY|STATUS|REASON ($1|$2|$3|$4|$5|$6|$7)
    local ban_log="${NFTBAN_LOG_DIR}/bans.log"
    if [[ -f "$ban_log" ]]; then
        local bans_login bans_portscan bans_ddos
        local tomorrow
        tomorrow=$(date -d 'tomorrow' '+%Y-%m-%d')
        # Only count BANNED entries (not UNBANNED), with proper date range
        bans_login=$(awk -F'|' -v since="$yesterday" -v until="$tomorrow" '$1 >= since && $1 < until && $6 == "BANNED" && $3 ~ /login|ssh|auth/ {count++} END {print count+0}' "$ban_log")
        bans_portscan=$(awk -F'|' -v since="$yesterday" -v until="$tomorrow" '$1 >= since && $1 < until && $6 == "BANNED" && $3 ~ /portscan|scan/ {count++} END {print count+0}' "$ban_log")
        bans_ddos=$(awk -F'|' -v since="$yesterday" -v until="$tomorrow" '$1 >= since && $1 < until && $6 == "BANNED" && $3 ~ /ddos|flood/ {count++} END {print count+0}' "$ban_log")
        manual_bans=$(awk -F'|' -v since="$yesterday" -v until="$tomorrow" '$1 >= since && $1 < until && $6 == "BANNED" && $3 == "manual" {count++} END {print count+0}' "$ban_log")
        # Strip non-digits and ensure defaults
        bans_login=${bans_login//[^0-9]/}; bans_login=${bans_login:-0}
        bans_portscan=${bans_portscan//[^0-9]/}; bans_portscan=${bans_portscan:-0}
        bans_ddos=${bans_ddos//[^0-9]/}; bans_ddos=${bans_ddos:-0}
        manual_bans=${manual_bans//[^0-9]/}; manual_bans=${manual_bans:-0}
        # Add to totals
        login_bans=$((login_bans + bans_login))
        portscan_bans=$((portscan_bans + bans_portscan))
        ddos_bans=$((ddos_bans + bans_ddos))
    fi

    # ==========================================================================
    # GET PROTECTION STATUS
    # ==========================================================================

    local protection_status=""
    local modules=("ddos:DDoS Protection" "portscan:Port Scan Detection" "login:Login Monitor" "feeds:Threat Feeds" "geoip:GeoIP Blocking")

    for mod_info in "${modules[@]}"; do
        local mod="${mod_info%%:*}"
        local name="${mod_info#*:}"
        local status="Disabled"
        local color="#ef4444"
        local icon="&#10008;"

        case "$mod" in
            ddos)
                # Check via nftban ddos status or config
                local ddos_output
                ddos_output=$(nftban ddos status 2>/dev/null | grep -E "Module Enabled:|Master Switch:" | head -1) || true
                if [[ "$ddos_output" =~ "true" ]] || [[ "$ddos_output" =~ "ENABLED" ]]; then
                    status="Active"; color="#22c55e"; icon="&#10004;"
                fi
                ;;
            portscan)
                # Check via nftban portscan status or config
                local portscan_output
                portscan_output=$(nftban portscan status 2>/dev/null | grep -E "Module Enabled:|Master Switch:|Status:" | head -1) || true
                if [[ "$portscan_output" =~ "true" ]] || [[ "$portscan_output" =~ "ENABLED" ]] || [[ "$portscan_output" =~ "Running" ]]; then
                    status="Active"; color="#22c55e"; icon="&#10004;"
                fi
                ;;
            login)
                # Check both nftban-login-monitor service and login alert status
                local login_svc="${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service}"
                if systemctl is-active "$login_svc" &>/dev/null 2>&1 || \
                   systemctl is-active nftban-login &>/dev/null 2>&1 || \
                   [[ -f "${NFTBAN_RUN_DIR:-/run/nftban}/login.pid" ]] || \
                   [[ "$(grep -s 'NFTBAN_LOGIN_ALERT_ENABLED=true' /etc/nftban/conf.d/login_alert.conf* 2>/dev/null)" ]]; then
                    status="Active"; color="#22c55e"; icon="&#10004;"
                fi
                ;;
            feeds)
                # Feeds are active if we have feed files with content
                local feed_total=0
                for f in /var/lib/nftban/feeds/*.txt; do
                    [[ -f "$f" ]] && feed_total=$((feed_total + $(wc -l < "$f" 2>/dev/null || echo 0)))
                done
                if [[ $feed_total -gt 0 ]]; then
                    status="Active"; color="#22c55e"; icon="&#10004;"
                fi
                ;;
            geoip)
                if timeout 10s nft list set ip nftban geo_block &>/dev/null 2>&1; then
                    status="Active"; color="#22c55e"; icon="&#10004;"
                fi
                ;;
        esac

        protection_status+="<tr>
            <td style=\"padding:12px 16px;border-bottom:1px solid #475569;\">
                <span style=\"color:#94a3b8;\">${name}</span>
            </td>
            <td style=\"padding:12px 16px;text-align:right;border-bottom:1px solid #475569;\">
                <span style=\"color:${color};font-weight:bold;\">${icon} ${status}</span>
            </td>
        </tr>"
    done

    # ==========================================================================
    # GET TOP BLOCKED IPs (from nftables blacklist with GeoIP lookup)
    # OPTIMIZED: Use Go batch GeoIP lookup instead of spawning process per IP
    # ==========================================================================

    local top_ips=""

    # Get IPs from actual nftables blacklist (not config files)
    local blacklist_ips=""
    if timeout 10s nft list set ip nftban blacklist_ipv4 &>/dev/null; then
        blacklist_ips=$(timeout 10s nft list set ip nftban blacklist_ipv4 2>/dev/null | \
            grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | \
            sort -u | tr '\n' ',' | sed 's/,$//')  # Convert to comma-separated for Go
    fi

    # Use Go for batch GeoIP lookup (100x faster than spawning mmdblookup per IP)
    if [[ -n "$blacklist_ips" ]] && command -v nftban-core &>/dev/null; then
        local report_json
        report_json=$(nftban-core analytics report --ips="$blacklist_ips" --limit=5 2>/dev/null)

        if [[ -n "$report_json" ]] && command -v jq &>/dev/null; then
            # Parse JSON and build HTML
            local ip_count=0
            while IFS= read -r ip_json; do
                local ip country
                ip=$(echo "$ip_json" | jq -r '.ip')
                country=$(echo "$ip_json" | jq -r '.country')

                # v1.19.20 FIX
                ((ip_count++)) || true
                local border="border-bottom:1px solid #475569;"
                [[ $ip_count -eq 5 ]] && border=""

                top_ips+="<tr>
                    <td style=\"padding:12px 16px;${border}\">
                        <span style=\"color:#f1f5f9;font-family:monospace;\">${ip}</span>
                    </td>
                    <td style=\"padding:12px 16px;text-align:right;${border}\">
                        <span style=\"color:#f59e0b;font-weight:bold;\">${country}</span>
                    </td>
                </tr>"
            done < <(echo "$report_json" | jq -c '.top_ips[]')
        fi
    fi

    # Fallback to old method if Go command not available or failed
    if [[ -z "$top_ips" ]] && [[ -n "$blacklist_ips" ]]; then
        # Auto-detect GeoIP database from config
        local geoip_db=""
        local geoip_dir="${NFTBAN_DATA_DIR}/geoip"
        if [[ -n "${NFTBAN_GEOIP_DATABASE:-}" ]] && [[ -f "${NFTBAN_GEOIP_DATABASE}" ]]; then
            geoip_db="${NFTBAN_GEOIP_DATABASE}"
        else
            # IFS-safe split: strict.sh sets IFS=$'\n\t', so space-separated vars need explicit splitting
            local _geoip_dbs
            IFS=' ' read -ra _geoip_dbs <<< "${NFTBAN_GEOIP_DATABASES:-dbip-country-lite.mmdb GeoLite2-City.mmdb GeoLite2-Country.mmdb}"
            for db_file in "${_geoip_dbs[@]}"; do
                [[ -f "${geoip_dir}/${db_file}" ]] && geoip_db="${geoip_dir}/${db_file}" && break
            done
        fi

        # Helper: Check if IP is public (not private/reserved)
        is_public_ip() {
            local ip="$1"
            [[ "$ip" =~ ^10\. ]] && return 1
            [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] && return 1
            [[ "$ip" =~ ^192\.168\. ]] && return 1
            [[ "$ip" =~ ^127\. ]] && return 1
            [[ "$ip" =~ ^169\.254\. ]] && return 1
            [[ "$ip" =~ ^224\. ]] && return 1
            [[ "$ip" =~ ^0\. ]] && return 1
            [[ "$ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]] && return 1
            [[ "$ip" =~ ^192\.0\.(0|2)\. ]] && return 1
            [[ "$ip" =~ ^198\.(1[89])\. ]] && return 1
            [[ "$ip" =~ ^203\.0\.113\. ]] && return 1
            return 0
        }

        # Helper: Get country from GeoIP
        get_country() {
            local ip="$1"
            local country="Unknown"

            if command -v mmdblookup &>/dev/null && [[ -f "$geoip_db" ]]; then
                country=$(mmdblookup --file "$geoip_db" --ip "$ip" country names en 2>/dev/null | grep -oP '"\K[^"]+' | head -1)
            elif command -v geoiplookup &>/dev/null; then
                country=$(geoiplookup "$ip" 2>/dev/null | head -1 | sed 's/.*: //' | cut -d',' -f2 | xargs)
            fi

            [[ -z "$country" ]] && country="Unknown"
            echo "$country"
        }

        # Process IPs with old method
        local ip_count=0
        while IFS= read -r ip; do
            [[ -z "$ip" ]] && continue
            is_public_ip "$ip" || continue

            # v1.19.20 FIX
            ((ip_count++)) || true
            [[ $ip_count -gt 5 ]] && break

            local country
            country=$(get_country "$ip")

            local border="border-bottom:1px solid #475569;"
            [[ $ip_count -eq 5 ]] && border=""

            top_ips+="<tr>
                <td style=\"padding:12px 16px;${border}\">
                    <span style=\"color:#f1f5f9;font-family:monospace;\">${ip}</span>
                </td>
                <td style=\"padding:12px 16px;text-align:right;${border}\">
                    <span style=\"color:#f59e0b;font-weight:bold;\">${country}</span>
                </td>
            </tr>"
        done <<< "${blacklist_ips//,/$'\n'}"
    fi

    # Fallback message if no public IPs found
    if [[ -z "$top_ips" ]]; then
        top_ips="<tr><td style=\"padding:16px;text-align:center;color:#64748b;\" colspan=\"2\">No public IPs in blacklist</td></tr>"
    fi

    # ==========================================================================
    # GET SYSTEM RESOURCES (from shared checks)
    # ==========================================================================

    local load_5m="0" cpu_count="1" mem_used_percent="0" disk_used_percent="0" disk_path="/var/log"
    local mem_color="#22d3ee" disk_color="#22d3ee"

    # Load shared checks library if needed
    local checks_lib="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_checks.sh"
    if ! declare -f nftban_check_system_resources &>/dev/null && [[ -f "$checks_lib" ]]; then
        # shellcheck source=/dev/null
        source "$checks_lib" 2>/dev/null || true
    fi

    # Get system resources
    if declare -f nftban_check_system_resources &>/dev/null; then
        local resources_json
        resources_json=$(nftban_check_system_resources 2>/dev/null)
        if command -v jq &>/dev/null && [[ -n "$resources_json" ]]; then
            local data
            data=$(echo "$resources_json" | jq -r '.data // {}')
            load_5m=$(echo "$data" | jq -r '.load["5m"] // "0"')
            cpu_count=$(echo "$data" | jq -r '.load.cpus // 1')
            mem_used_percent=$(echo "$data" | jq -r '.memory.used_percent // 0')
            disk_used_percent=$(echo "$data" | jq -r '.disk.used_percent // 0')
            disk_path=$(echo "$data" | jq -r '.disk.path // "/var/log"')
        fi
    else
        # Fallback to direct reads
        if [[ -r /proc/loadavg ]]; then
            read -r _ load_5m _ < /proc/loadavg
        fi
        cpu_count=$(nproc 2>/dev/null || echo 1)
        if [[ -r /proc/meminfo ]]; then
            local total avail
            total=$(grep '^MemTotal:' /proc/meminfo | awk '{print $2}')
            avail=$(grep '^MemAvailable:' /proc/meminfo | awk '{print $2}')
            [[ $total -gt 0 ]] && mem_used_percent=$(( (total - avail) * 100 / total ))
        fi
        if df -P /var/log &>/dev/null; then
            disk_used_percent=$(df -P /var/log | tail -1 | awk '{print $5}' | tr -d '%')
        fi
    fi

    # Set colors based on thresholds
    [[ $mem_used_percent -ge 80 ]] && mem_color="#fbbf24"
    [[ $mem_used_percent -ge 95 ]] && mem_color="#f87171"
    [[ $disk_used_percent -ge 80 ]] && disk_color="#fbbf24"
    [[ $disk_used_percent -ge 95 ]] && disk_color="#f87171"

    # ==========================================================================
    # GET SURICATA STATUS
    # ==========================================================================

    local suricata_section=""
    if declare -f nftban_check_suricata_status &>/dev/null; then
        local suricata_json
        suricata_json=$(nftban_check_suricata_status 2>/dev/null)
        if command -v jq &>/dev/null && [[ -n "$suricata_json" ]]; then
            local sdata installed active status rules
            sdata=$(echo "$suricata_json" | jq -r '.data // {}')
            installed=$(echo "$sdata" | jq -r '.installed // false')
            active=$(echo "$sdata" | jq -r '.service_active // false')
            status=$(echo "$sdata" | jq -r '.status // "unknown"')
            rules=$(echo "$sdata" | jq -r '.rules_loaded // 0')

            if [[ "$installed" == "true" ]]; then
                local suri_status_color="#22c55e" suri_status_text="Active"
                if [[ "$active" != "true" ]]; then
                    suri_status_color="#f87171"
                    suri_status_text="Inactive"
                elif [[ "$status" == "stale_eve" ]]; then
                    suri_status_color="#fbbf24"
                    suri_status_text="Stale EVE"
                fi

                suricata_section="<tr>
            <td style=\"padding:0 24px 24px;\">
                <h2 style=\"margin:0 0 16px;font-size:16px;color:#f1f5f9;\">Suricata IDS</h2>
                <table width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"background-color:#334155;border-radius:8px;\">
                    <tr>
                        <td style=\"padding:12px 16px;border-bottom:1px solid #475569;\">
                            <span style=\"color:#94a3b8;\">Status</span>
                        </td>
                        <td style=\"padding:12px 16px;text-align:right;border-bottom:1px solid #475569;\">
                            <span style=\"color:${suri_status_color};font-weight:bold;\">${suri_status_text}</span>
                        </td>
                    </tr>
                    <tr>
                        <td style=\"padding:12px 16px;\">
                            <span style=\"color:#94a3b8;\">Rules Loaded</span>
                        </td>
                        <td style=\"padding:12px 16px;text-align:right;\">
                            <span style=\"color:#22d3ee;font-weight:bold;\">${rules}</span>
                        </td>
                    </tr>
                </table>
            </td>
        </tr>"
            fi
        fi
    fi

    # ==========================================================================
    # BUILD HTML FROM TEMPLATE
    # ==========================================================================

    local html
    html=$(cat "$template")

    # Escape & in replacement strings (& is special in bash substitution)
    # For variables containing HTML entities like &#10004;, we must escape &
    local feeds_status_escaped="${feeds_status//&/\\&}"
    local protection_status_escaped="${protection_status//&/\\&}"
    local top_ips_escaped="${top_ips//&/\\&}"
    local suricata_section_escaped="${suricata_section//&/\\&}"

    html="${html//\{\{HOSTNAME\}\}/$hostname}"
    html="${html//\{\{DATE\}\}/$date_now}"
    html="${html//\{\{BLOCKED_IPS\}\}/$blocked_ips}"
    html="${html//\{\{WHITELIST_COUNT\}\}/$whitelist_count}"
    html="${html//\{\{FEEDS_STATUS\}\}/$feeds_status_escaped}"
    html="${html//\{\{LOGIN_BANS\}\}/$login_bans}"
    html="${html//\{\{PORTSCAN_BANS\}\}/$portscan_bans}"
    html="${html//\{\{DDOS_BANS\}\}/$ddos_bans}"
    html="${html//\{\{MANUAL_BANS\}\}/$manual_bans}"
    html="${html//\{\{PROTECTION_STATUS\}\}/$protection_status_escaped}"
    html="${html//\{\{TOP_IPS\}\}/$top_ips_escaped}"
    html="${html//\{\{REPORT_ID\}\}/$report_id}"

    # System resources
    html="${html//\{\{LOAD_5M\}\}/$load_5m}"
    html="${html//\{\{CPU_COUNT\}\}/$cpu_count}"
    html="${html//\{\{MEM_USED_PERCENT\}\}/$mem_used_percent}"
    html="${html//\{\{MEM_COLOR\}\}/$mem_color}"
    html="${html//\{\{DISK_USED_PERCENT\}\}/$disk_used_percent}"
    html="${html//\{\{DISK_PATH\}\}/$disk_path}"
    html="${html//\{\{DISK_COLOR\}\}/$disk_color}"

    # Suricata section (conditional)
    html="${html//\{\{SURICATA_SECTION\}\}/$suricata_section_escaped}"

    # ==========================================================================
    # SEND EMAIL
    # ==========================================================================

    # Send via NFTBan unified mail mechanism (subject embedded in HTML)
    if nftban_mail_send "$html" "$recipient" 2>/dev/null; then
        echo "[SUCCESS] Report sent to ${recipient}"
        return 0
    else
        echo "ERROR: Failed to send report email" >&2
        return 1
    fi
}

# CLI wrapper
nftban_cmd_report_send() {
    local recipient="${1:-}"
    if [[ -z "$recipient" ]]; then
        echo "Usage: nftban report send <email@example.com>" >&2
        return 1
    fi
    nftban_report_email_generate "$recipient"
}

export -f nftban_report_email_generate
export -f nftban_cmd_report_send
