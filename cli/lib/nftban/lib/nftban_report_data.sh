#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_report_data" meta:type="lib" meta:version="1.48.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Centralized data collection using nft_schema.sh SSOT"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"

set -Eeuo pipefail

# Module guard
[[ -n "${NFTBAN_REPORT_DATA_LOADED:-}" ]] && return 0
readonly NFTBAN_REPORT_DATA_LOADED=1

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly REPORT_CACHE_DIR="${NFTBAN_CACHE_DIR:-/var/cache/nftban}"
# shellcheck disable=SC2034  # Reserved for future caching implementation
readonly REPORT_CACHE_FILE="${REPORT_CACHE_DIR}/report_data.json"
# shellcheck disable=SC2034  # Reserved for future caching implementation
readonly REPORT_CACHE_TTL=5  # seconds

# =============================================================================
# CORE DATA COLLECTION (uses nft_schema.sh SSOT)
# =============================================================================

# Collect all report data in one call (cached)
# Returns: associative array via nameref
nftban_report_collect_all() {
    local -n _data="$1"

    # Get counts from nft_schema.sh (SINGLE SOURCE OF TRUTH)
    local counts_json
    if declare -f nftban_nft_count_all_sets &>/dev/null; then
        counts_json=$(nftban_nft_count_all_sets 2>/dev/null || echo '{}')
    else
        counts_json='{}'
    fi

    # Parse ban counts
    if command -v jq &>/dev/null && [[ -n "$counts_json" ]]; then
        _data[BANS_IPV4]=$(echo "$counts_json" | jq -r '.blacklist.ipv4 // 0')
        _data[BANS_IPV6]=$(echo "$counts_json" | jq -r '.blacklist.ipv6 // 0')
        _data[ACTIVE_BANS]=$(echo "$counts_json" | jq -r '.blacklist.total // 0')
        _data[BANS_TEMP]=$(echo "$counts_json" | jq -r '.temporary.total // 0')
        _data[BANS_PERM]=$(echo "$counts_json" | jq -r '.permanent.total // 0')
        _data[WHITELIST_COUNT]=$(echo "$counts_json" | jq -r '.whitelist.total // 0')
    else
        # Fallback without jq
        _data[BANS_IPV4]=0
        _data[BANS_IPV6]=0
        _data[ACTIVE_BANS]=0
        _data[BANS_TEMP]=0
        _data[BANS_PERM]=0
        _data[WHITELIST_COUNT]=0
    fi

    # Basic system info
    _data[HOSTNAME]=$(hostname -f 2>/dev/null || hostname)
    _data[SERVER_IP]=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")
    _data[DATE]=$(date '+%Y-%m-%d')
    _data[TIME]=$(date '+%H:%M:%S')
    _data[NFTBAN_VERSION]="${NFTBAN_VERSION:-unknown}"
    _data[REPORT_PERIOD]="Daily"

    # 24h activity (from logs)
    _data[BANS_24H]=$(_count_bans_24h)
    _data[UNBANS_24H]=$(_count_unbans_24h)
    _data[UNIQUE_IPS_24H]=$(_count_unique_ips_24h)

    # Health status
    local health_status
    health_status=$(_get_health_status)
    _data[HEALTH_STATUS]="$health_status"
    _data[HEALTH_STATUS_CLASS]=$(_health_to_class "$health_status")

    # Module statuses
    _collect_module_status _data

    # Feeds info
    _collect_feeds_info _data

    # RBL info
    _collect_rbl_info _data

    # Security posture (low noise)
    _collect_posture_info _data

    # System resources (from shared checks)
    _collect_system_resources _data

    # Suricata status (from shared checks)
    _collect_suricata_status _data

    # DNS status (from shared checks)
    _collect_dns_status _data
}

# =============================================================================
# 24H ACTIVITY COUNTERS
# =============================================================================

_count_bans_24h() {
    local ban_log="${NFTBAN_LOG_DIR:-/var/log/nftban}/bans.log"
    local since
    since=$(date -d '24 hours ago' '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')

    if [[ -f "$ban_log" ]]; then
        grep -c "^${since}" "$ban_log" 2>/dev/null || echo 0
    else
        echo 0
    fi
}

_count_unbans_24h() {
    local unban_log="${NFTBAN_LOG_DIR:-/var/log/nftban}/unbans.log"
    local since
    since=$(date -d '24 hours ago' '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')

    if [[ -f "$unban_log" ]]; then
        grep -c "^${since}" "$unban_log" 2>/dev/null || echo 0
    else
        echo 0
    fi
}

_count_unique_ips_24h() {
    local ban_log="${NFTBAN_LOG_DIR:-/var/log/nftban}/bans.log"
    local since
    since=$(date -d '24 hours ago' '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')

    if [[ -f "$ban_log" ]]; then
        grep "^${since}" "$ban_log" 2>/dev/null | cut -d'|' -f4 | sort -u | wc -l || echo 0
    else
        echo 0
    fi
}

# =============================================================================
# HEALTH STATUS
# =============================================================================

_get_health_status() {
    # Check cached health status first
    local health_cache="${NFTBAN_CACHE_DIR:-/var/cache/nftban}/health/status.json"

    if [[ -f "$health_cache" ]]; then
        local status
        status=$(jq -r '.overall // "unknown"' "$health_cache" 2>/dev/null || echo "unknown")
        case "$status" in
            ok|healthy) echo "OK" ;;
            degraded|warning) echo "Degraded" ;;
            critical|error) echo "Critical" ;;
            *) echo "Unknown" ;;
        esac
    else
        # Fallback: check if critical services are running
        if systemctl is-active nftables &>/dev/null; then
            echo "OK"
        else
            echo "Critical"
        fi
    fi
}

_health_to_class() {
    local status="$1"
    case "$status" in
        OK|ok|healthy) echo "ok" ;;
        Degraded|degraded|warning) echo "degraded" ;;
        Critical|critical|error) echo "critical" ;;
        *) echo "degraded" ;;
    esac
}

# =============================================================================
# MODULE STATUS COLLECTION
# =============================================================================

_collect_module_status() {
    local -n _mdata="$1"

    # DDoS Module
    local ddos_enabled="false"
    [[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/ddos/main.conf" ]] && \
        ddos_enabled=$(grep -E "^DDOS_ENABLED=" "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/ddos/main.conf" 2>/dev/null | cut -d'"' -f2 || echo "false")

    if [[ "$ddos_enabled" == "true" ]]; then
        _mdata[MODULE_DDOS_STATUS]="Active"
        _mdata[MODULE_DDOS_STATUS_CLASS]="status-active"
        _mdata[MODULE_DDOS_CLASS]="active"
        _mdata[MODULE_DDOS_ACTIVITY]=$(_get_module_activity "ddos")
    else
        _mdata[MODULE_DDOS_STATUS]="Disabled"
        _mdata[MODULE_DDOS_STATUS_CLASS]="status-inactive"
        _mdata[MODULE_DDOS_CLASS]="inactive"
        _mdata[MODULE_DDOS_ACTIVITY]="-"
    fi

    # Portscan Module
    local portscan_enabled="false"
    [[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/portscan/main.conf" ]] && \
        portscan_enabled=$(grep -E "^PORTSCAN_ENABLED=" "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/portscan/main.conf" 2>/dev/null | cut -d'"' -f2 || echo "false")

    if [[ "$portscan_enabled" == "true" ]]; then
        _mdata[MODULE_PORTSCAN_STATUS]="Active"
        _mdata[MODULE_PORTSCAN_STATUS_CLASS]="status-active"
        _mdata[MODULE_PORTSCAN_CLASS]="active"
        _mdata[MODULE_PORTSCAN_ACTIVITY]=$(_get_module_activity "portscan")
    else
        _mdata[MODULE_PORTSCAN_STATUS]="Disabled"
        _mdata[MODULE_PORTSCAN_STATUS_CLASS]="status-inactive"
        _mdata[MODULE_PORTSCAN_CLASS]="inactive"
        _mdata[MODULE_PORTSCAN_ACTIVITY]="-"
    fi

    # Login Monitor (v1.48.0: loginmon module runs inside nftband daemon)
    if systemctl is-active nftband.service &>/dev/null; then
        _mdata[MODULE_LOGIN_STATUS]="Active"
        _mdata[MODULE_LOGIN_STATUS_CLASS]="status-active"
        _mdata[MODULE_LOGIN_CLASS]="active"
        _mdata[MODULE_LOGIN_ACTIVITY]=$(_get_module_activity "login")
    else
        _mdata[MODULE_LOGIN_STATUS]="Disabled"
        _mdata[MODULE_LOGIN_STATUS_CLASS]="status-inactive"
        _mdata[MODULE_LOGIN_CLASS]="inactive"
        _mdata[MODULE_LOGIN_ACTIVITY]="-"
    fi

    # Threat Feeds
    local feeds_count
    feeds_count=$(_count_enabled_feeds)
    if [[ "$feeds_count" -gt 0 ]]; then
        _mdata[MODULE_FEEDS_STATUS]="Active"
        _mdata[MODULE_FEEDS_STATUS_CLASS]="status-active"
        _mdata[MODULE_FEEDS_CLASS]="active"
    else
        _mdata[MODULE_FEEDS_STATUS]="Disabled"
        _mdata[MODULE_FEEDS_STATUS_CLASS]="status-inactive"
        _mdata[MODULE_FEEDS_CLASS]="inactive"
    fi
    _mdata[FEEDS_COUNT]="$feeds_count"

    # GeoBan
    local geoban_enabled="false"
    [[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/geoban/main.conf" ]] && \
        geoban_enabled=$(grep -E "^GEOBAN_ENABLED=" "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/geoban/main.conf" 2>/dev/null | cut -d'"' -f2 || echo "false")

    if [[ "$geoban_enabled" == "true" ]]; then
        _mdata[MODULE_GEOBAN_STATUS]="Active"
        _mdata[MODULE_GEOBAN_STATUS_CLASS]="status-active"
        _mdata[MODULE_GEOBAN_CLASS]="active"
        _mdata[MODULE_GEOBAN_ACTIVITY]=$(_get_geoban_countries)
    else
        _mdata[MODULE_GEOBAN_STATUS]="Disabled"
        _mdata[MODULE_GEOBAN_STATUS_CLASS]="status-inactive"
        _mdata[MODULE_GEOBAN_CLASS]="inactive"
        _mdata[MODULE_GEOBAN_ACTIVITY]="-"
    fi
}

_get_module_activity() {
    local module="$1"
    local action_log="${NFTBAN_LOG_DIR:-/var/log/nftban}/nftban-actions.log"
    local since
    since=$(date -d '24 hours ago' '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')

    if [[ -f "$action_log" ]]; then
        local count
        count=$(grep "$module" "$action_log" 2>/dev/null | grep -c "^${since}" || echo 0)
        echo "${count} events"
    else
        echo "0 events"
    fi
}

_get_geoban_countries() {
    local geoban_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/geoban/main.conf"
    if [[ -f "$geoban_conf" ]]; then
        local countries
        countries=$(grep -E "^GEOBAN_COUNTRIES=" "$geoban_conf" 2>/dev/null | cut -d'"' -f2 || echo "")
        local count
        count=$(echo "$countries" | tr ',' '\n' | grep -c . || echo 0)
        echo "${count} countries"
    else
        echo "-"
    fi
}

# =============================================================================
# FEEDS DATA COLLECTION
# =============================================================================

_count_enabled_feeds() {
    local feeds_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/feeds.conf"
    if [[ -f "$feeds_conf" ]]; then
        grep -cE "^FEED_.*_ENABLED=\"true\"" "$feeds_conf" 2>/dev/null || echo 0
    else
        echo 0
    fi
}

_collect_feeds_info() {
    local -n _fdata="$1"
    local feeds_cache="${NFTBAN_CACHE_DIR:-/var/cache/nftban}/feeds"
    local total_ips=0
    local feeds_html=""

    if [[ -d "$feeds_cache" ]]; then
        for feed_file in "$feeds_cache"/*.txt; do
            [[ -f "$feed_file" ]] || continue
            local feed_name
            feed_name=$(basename "$feed_file" .txt)
            local ip_count
            ip_count=$(wc -l < "$feed_file" 2>/dev/null || echo 0)
            total_ips=$((total_ips + ip_count))

            # Get last update time
            local last_update
            last_update=$(stat -c %Y "$feed_file" 2>/dev/null || echo 0)
            local now
            now=$(date +%s)
            local age_hours=$(( (now - last_update) / 3600 ))

            local status_class="feed-status-current"
            local status_text="Current"
            if [[ $age_hours -gt 24 ]]; then
                status_class="feed-status-stale"
                status_text="Stale"
            fi

            local age_display
            if [[ $age_hours -lt 1 ]]; then
                age_display="< 1h ago"
            else
                age_display="${age_hours}h ago"
            fi

            feeds_html+="<tr>"
            feeds_html+="<td>${feed_name}</td>"
            feeds_html+="<td>${ip_count}</td>"
            feeds_html+="<td>${age_display}</td>"
            feeds_html+="<td class=\"${status_class}\">${status_text}</td>"
            feeds_html+="</tr>"
        done
    fi

    [[ -z "$feeds_html" ]] && feeds_html="<tr><td colspan=\"4\" style=\"text-align:center;color:#64748b;\">No feeds configured</td></tr>"

    _fdata[FEEDS_TOTAL_IPS]="$total_ips"
    _fdata[FEEDS_TABLE_HTML]="$feeds_html"
}

# =============================================================================
# TOP LISTS (IPs, Countries, Sources)
# =============================================================================

nftban_report_top_ips() {
    local limit="${1:-5}"
    local ban_log="${NFTBAN_LOG_DIR:-/var/log/nftban}/bans.log"
    local html=""

    if [[ -f "$ban_log" ]]; then
        while IFS='|' read -r count ip; do
            [[ -z "$ip" ]] && continue
            local country
            country=$(_lookup_country "$ip")
            html+="<li><span class=\"ip-code\">${ip}</span> <span class=\"country-flag\">${country}</span> <span class=\"badge\">${count}</span></li>"
        done < <(cut -d'|' -f4 "$ban_log" 2>/dev/null | sort | uniq -c | sort -rn | head -"$limit" | awk '{print $1"|"$2}')
    fi

    [[ -z "$html" ]] && html="<li style=\"color:#64748b;\">No data available</li>"
    echo "$html"
}

nftban_report_top_countries() {
    local limit="${1:-5}"
    local ban_log="${NFTBAN_LOG_DIR:-/var/log/nftban}/bans.log"
    local html=""

    if [[ -f "$ban_log" ]]; then
        while IFS='|' read -r count country; do
            [[ -z "$country" || "$country" == "-" ]] && continue
            html+="<li><span>${country}</span> <span class=\"badge\">${count}</span></li>"
        done < <(cut -d'|' -f5 "$ban_log" 2>/dev/null | sort | uniq -c | sort -rn | head -"$limit" | awk '{print $1"|"$2}')
    fi

    [[ -z "$html" ]] && html="<li style=\"color:#64748b;\">No data available</li>"
    echo "$html"
}

nftban_report_top_sources() {
    local limit="${1:-5}"
    local ban_log="${NFTBAN_LOG_DIR:-/var/log/nftban}/bans.log"
    local html=""

    if [[ -f "$ban_log" ]]; then
        while IFS='|' read -r count source; do
            [[ -z "$source" ]] && continue
            html+="<li><span>${source}</span> <span class=\"badge\">${count}</span></li>"
        done < <(cut -d'|' -f3 "$ban_log" 2>/dev/null | sort | uniq -c | sort -rn | head -"$limit" | awk '{print $1"|"$2}')
    fi

    [[ -z "$html" ]] && html="<li style=\"color:#64748b;\">No data available</li>"
    echo "$html"
}

_lookup_country() {
    local ip="$1"
    # Try GeoIP lookup if available
    if command -v geoiplookup &>/dev/null; then
        geoiplookup "$ip" 2>/dev/null | grep -oP 'GeoIP Country Edition: \K[A-Z]{2}' || echo "??"
    elif command -v mmdbinspect &>/dev/null && [[ -f "/var/lib/nftban/geoip/GeoLite2-Country.mmdb" ]]; then
        mmdbinspect -db "/var/lib/nftban/geoip/GeoLite2-Country.mmdb" "$ip" 2>/dev/null | jq -r '.[0].Records[0].Record.country.iso_code // "??"' || echo "??"
    else
        echo "??"
    fi
}

# =============================================================================
# RECOMMENDATIONS GENERATOR
# =============================================================================

nftban_report_recommendations() {
    local -n _rdata="$1"
    local recommendations=""

    # Check if feeds are enabled
    if [[ "${_rdata[FEEDS_COUNT]:-0}" -eq 0 ]]; then
        recommendations+="<li>Enable threat feeds for automatic IP blocking: <code>nftban feeds enable</code></li>"
    fi

    # Check if GeoBan is enabled for high-volume countries
    if [[ "${_rdata[MODULE_GEOBAN_STATUS]:-Disabled}" == "Disabled" ]]; then
        recommendations+="<li>Consider enabling GeoBan for countries with frequent attacks</li>"
    fi

    # Check health status
    if [[ "${_rdata[HEALTH_STATUS]:-OK}" != "OK" ]]; then
        recommendations+="<li>System health is degraded - run <code>nftban health</code> for details</li>"
    fi

    # High ban rate warning
    if [[ "${_rdata[BANS_24H]:-0}" -gt 100 ]]; then
        recommendations+="<li>High ban rate detected (${_rdata[BANS_24H]} in 24h) - review security measures</li>"
    fi

    [[ -z "$recommendations" ]] && recommendations="<li>All systems operating normally. No recommendations at this time.</li>"

    echo "$recommendations"
}

# =============================================================================
# TEMPLATE VARIABLE SUBSTITUTION
# =============================================================================

# Replace all template variables in content
# Usage: nftban_report_substitute "template_content"
nftban_report_substitute() {
    local content="$1"

    # Collect all data
    declare -A data
    nftban_report_collect_all data

    # Generate dynamic content
    data[TOP_IPS_HTML]=$(nftban_report_top_ips 5)
    data[TOP_COUNTRIES_HTML]=$(nftban_report_top_countries 5)
    data[TOP_SOURCES_HTML]=$(nftban_report_top_sources 5)
    data[RECOMMENDATIONS_HTML]=$(nftban_report_recommendations data)

    # Substitute all variables
    for key in "${!data[@]}"; do
        content="${content//\{$key\}/${data[$key]}}"
    done

    echo "$content"
}

# =============================================================================
# RBL DATA COLLECTION
# =============================================================================

_collect_rbl_info() {
    local -n _rdata="$1"
    local rbl_enabled="NO"
    local rbl_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/rbl/main.conf"

    # Check if RBL is enabled
    if [[ -f "$rbl_conf" ]]; then
        rbl_enabled=$(grep -E "^NFTBAN_RBL_ENABLED=" "$rbl_conf" 2>/dev/null | cut -d'"' -f2 || echo "NO")
    fi

    if [[ "$rbl_enabled" == "YES" ]]; then
        _rdata[MODULE_RBL_STATUS]="Active"
        _rdata[MODULE_RBL_STATUS_CLASS]="status-active"
        _rdata[MODULE_RBL_CLASS]="active"

        # Get RBL state data
        local state_file="${NFTBAN_LOG_DIR:-/var/log/nftban}/rbl/state.dat"
        local listed_count=0
        local clean_count=0
        local watched_count=0

        if [[ -f "$state_file" ]]; then
            listed_count=$(grep -c "=listed|" "$state_file" 2>/dev/null || echo 0)
            clean_count=$(grep -c "=clean|" "$state_file" 2>/dev/null || echo 0)
        fi

        # Count watchlist entries
        local watchlist_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/rbl/watchlist.conf"
        if [[ -f "$watchlist_file" ]]; then
            watched_count=$(grep -v "^#" "$watchlist_file" 2>/dev/null | grep -c '|' || echo 0)
        fi

        _rdata[RBL_LISTED_COUNT]="$listed_count"
        _rdata[RBL_CLEAN_COUNT]="$clean_count"
        _rdata[RBL_WATCHED_COUNT]="$watched_count"

        # Get last check time
        local last_check_file="${NFTBAN_LOG_DIR:-/var/log/nftban}/rbl/last_check"
        if [[ -f "$last_check_file" ]]; then
            _rdata[RBL_LAST_CHECK]=$(cat "$last_check_file" 2>/dev/null || echo "Unknown")
        else
            _rdata[RBL_LAST_CHECK]="Never"
        fi

        # Activity summary
        if [[ $listed_count -gt 0 ]]; then
            _rdata[MODULE_RBL_ACTIVITY]="${listed_count} IPs blacklisted!"
        else
            _rdata[MODULE_RBL_ACTIVITY]="${clean_count} IPs clean"
        fi
    else
        _rdata[MODULE_RBL_STATUS]="Disabled"
        _rdata[MODULE_RBL_STATUS_CLASS]="status-inactive"
        _rdata[MODULE_RBL_CLASS]="inactive"
        _rdata[MODULE_RBL_ACTIVITY]="-"
        _rdata[RBL_LISTED_COUNT]="0"
        _rdata[RBL_CLEAN_COUNT]="0"
        _rdata[RBL_WATCHED_COUNT]="0"
        _rdata[RBL_LAST_CHECK]="N/A"
    fi
}

# Get RBL table HTML for reports
nftban_report_rbl_table() {
    local state_file="${NFTBAN_LOG_DIR:-/var/log/nftban}/rbl/state.dat"
    local html=""

    if [[ -f "$state_file" ]]; then
        while IFS='=' read -r ip data; do
            [[ -z "$ip" ]] && continue
            [[ "$ip" =~ ^# ]] && continue

            local status timestamp
            status=$(echo "$data" | cut -d'|' -f1)
            timestamp=$(echo "$data" | cut -d'|' -f2)

            local status_class="feed-status-current"
            local status_text="Clean"
            if [[ "$status" == "listed" ]]; then
                status_class="feed-status-error"
                status_text="LISTED"
            fi

            html+="<tr>"
            html+="<td><code>${ip}</code></td>"
            html+="<td class=\"${status_class}\">${status_text}</td>"
            html+="<td>${timestamp:-Unknown}</td>"
            html+="</tr>"
        done < "$state_file"
    fi

    [[ -z "$html" ]] && html="<tr><td colspan=\"3\" style=\"text-align:center;color:#64748b;\">No RBL checks recorded</td></tr>"
    echo "$html"
}

# =============================================================================
# SECURITY POSTURE DATA (low noise, smart limited scope)
# =============================================================================

# Collect security posture data - NOT audit-level, just essential hardening status
_collect_posture_info() {
    local -n _pdata="$1"
    local issues=0
    local warnings=0
    local posture_details=""

    # 1. SSH hardening basics (most impactful)
    local ssh_config="/etc/ssh/sshd_config"
    if [[ -f "$ssh_config" ]]; then
        # PasswordAuthentication (should be "no" for key-only)
        local pass_auth
        pass_auth=$(grep -E "^PasswordAuthentication" "$ssh_config" 2>/dev/null | awk '{print $2}' || echo "yes")
        if [[ "$pass_auth" == "yes" ]]; then
            # v1.19.20 FIX
            ((warnings++)) || true
            posture_details+="SSH: PasswordAuth=yes; "
        fi

        # PermitRootLogin (should be "no" or "prohibit-password")
        local root_login
        root_login=$(grep -E "^PermitRootLogin" "$ssh_config" 2>/dev/null | awk '{print $2}' || echo "yes")
        if [[ "$root_login" == "yes" ]]; then
            # v1.19.20 FIX
            ((warnings++)) || true
            posture_details+="SSH: RootLogin=yes; "
        fi
    fi

    # 2. Sudoers NOPASSWD check (only flag if risky patterns)
    local sudoers_dir="/etc/sudoers.d"
    if [[ -d "$sudoers_dir" ]]; then
        # Count files with ALL NOPASSWD (excluding nftban-specific)
        local risky_nopasswd=0
        for sfile in "$sudoers_dir"/*; do
            [[ -f "$sfile" ]] || continue
            [[ "$(basename "$sfile")" == "nftban" ]] && continue  # Skip NFTBan's own
            if grep -qE "NOPASSWD:\s*ALL" "$sfile" 2>/dev/null; then
                # v1.19.20 FIX
                ((risky_nopasswd++)) || true
            fi
        done
        if [[ $risky_nopasswd -gt 0 ]]; then
            # v1.19.20 FIX
            ((warnings++)) || true
            posture_details+="Sudo: ${risky_nopasswd} ALL NOPASSWD file(s); "
        fi
    fi

    # 3. NFTBan systemd hardening (NoNewPrivileges)
    # Deduplicate across unit dirs — same basename may exist in /etc and /lib
    local systemd_hardened=0
    local systemd_total=0
    declare -A _seen_units
    for unit_dir in /etc/systemd/system /usr/lib/systemd/system /lib/systemd/system; do
        [[ -d "$unit_dir" ]] || continue
        for svc in "$unit_dir"/nftban*.service; do
            [[ -f "$svc" ]] || continue
            local _unit_name
            _unit_name=$(basename "$svc")
            # Skip duplicates (same unit in multiple dirs)
            [[ -n "${_seen_units[$_unit_name]:-}" ]] && continue
            _seen_units[$_unit_name]=1
            # Skip template units (e.g. nftban-alert@.service)
            [[ "$_unit_name" == *@.service ]] && continue
            ((systemd_total++)) || true
            # systemd accepts both "true" and "yes" for boolean directives
            if grep -qE "^NoNewPrivileges\s*=\s*(true|yes)" "$svc" 2>/dev/null; then
                ((systemd_hardened++)) || true
            fi
        done
    done
    unset _seen_units
    if [[ $systemd_total -gt 0 && $systemd_hardened -lt $systemd_total ]]; then
        ((warnings++)) || true
        posture_details+="Systemd: ${systemd_hardened}/${systemd_total} hardened; "
    fi

    # 4. Config file integrity (basic check - config modified since install?)
    local conf_dir="${NFTBAN_CONFIG_DIR:-/etc/nftban}"
    local integrity_file="${conf_dir}/.config_checksums"
    if [[ -f "$integrity_file" ]]; then
        # Check if any core configs have changed (drift detection)
        local drift_count=0
        while IFS=' ' read -r stored_hash fpath; do
            [[ -z "$fpath" ]] && continue
            [[ -f "$fpath" ]] || continue
            local current_hash
            current_hash=$(sha256sum "$fpath" 2>/dev/null | cut -d' ' -f1 || echo "")
            if [[ -n "$current_hash" && "$current_hash" != "$stored_hash" ]]; then
                # v1.19.20 FIX
                ((drift_count++)) || true
            fi
        done < "$integrity_file"
        if [[ $drift_count -gt 0 ]]; then
            # v1.19.20 FIX
            ((warnings++)) || true
            posture_details+="Config: ${drift_count} file(s) modified; "
        fi
    fi

    # Determine overall posture status
    local posture_status="OK"
    local posture_class="ok"
    if [[ $warnings -gt 0 ]]; then
        posture_status="${warnings} advisory"
        posture_class="degraded"
    fi
    if [[ $issues -gt 0 ]]; then
        posture_status="${issues} issue(s)"
        posture_class="critical"
    fi

    # Set output variables
    _pdata[POSTURE_STATUS]="$posture_status"
    _pdata[POSTURE_STATUS_CLASS]="$posture_class"
    _pdata[POSTURE_WARNINGS]="$warnings"
    _pdata[POSTURE_ISSUES]="$issues"
    _pdata[POSTURE_DETAILS]="${posture_details%%; }"  # Remove trailing separator
}

# Get posture one-liner for status command
nftban_posture_oneline() {
    declare -A posture_data
    _collect_posture_info posture_data
    echo "${posture_data[POSTURE_STATUS]}"
}

# =============================================================================
# SYSTEM RESOURCES DATA (from shared checks)
# =============================================================================

_collect_system_resources() {
    # shellcheck disable=SC2178  # nameref is intentional
    local -n _rdata="$1"

    # Load shared checks library if needed
    local checks_lib="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_checks.sh"
    if ! declare -f nftban_check_system_resources &>/dev/null; then
        if [[ -f "$checks_lib" ]]; then
            # shellcheck source=/dev/null
            source "$checks_lib" 2>/dev/null || true
        fi
    fi

    # Get system resources
    if declare -f nftban_check_system_resources &>/dev/null; then
        local resources_json
        resources_json=$(nftban_check_system_resources 2>/dev/null)
        if command -v jq &>/dev/null && [[ -n "$resources_json" ]]; then
            local data
            data=$(echo "$resources_json" | jq -r '.data // {}')
            _rdata[LOAD_1M]=$(echo "$data" | jq -r '.load["1m"] // 0')
            _rdata[LOAD_5M]=$(echo "$data" | jq -r '.load["5m"] // 0')
            _rdata[LOAD_15M]=$(echo "$data" | jq -r '.load["15m"] // 0')
            _rdata[CPU_COUNT]=$(echo "$data" | jq -r '.load.cpus // 1')
            _rdata[MEM_USED_PERCENT]=$(echo "$data" | jq -r '.memory.used_percent // 0')
            _rdata[MEM_TOTAL_MB]=$(echo "$data" | jq -r '.memory.total_mb // 0')
            _rdata[DISK_PATH]=$(echo "$data" | jq -r '.disk.path // "/var/log"')
            _rdata[DISK_USED_PERCENT]=$(echo "$data" | jq -r '.disk.used_percent // 0')
            _rdata[RESOURCES_STATUS]=$(echo "$data" | jq -r '.status // "unknown"')
        fi
    else
        # Fallback: get basic info directly
        if [[ -r /proc/loadavg ]]; then
            # shellcheck disable=SC2313  # array indices are string keys
            read -r "_rdata[LOAD_1M]" "_rdata[LOAD_5M]" "_rdata[LOAD_15M]" _ < /proc/loadavg
        fi
        _rdata[CPU_COUNT]=$(nproc 2>/dev/null || echo 1)
        _rdata[RESOURCES_STATUS]="unknown"
    fi
}

# =============================================================================
# SURICATA STATUS DATA (from shared checks)
# =============================================================================

_collect_suricata_status() {
    local -n _sdata="$1"

    # Load shared checks library if needed
    local checks_lib="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_checks.sh"
    if ! declare -f nftban_check_suricata_status &>/dev/null; then
        if [[ -f "$checks_lib" ]]; then
            # shellcheck source=/dev/null
            source "$checks_lib" 2>/dev/null || true
        fi
    fi

    # Default values
    _sdata[SURICATA_INSTALLED]="false"
    _sdata[SURICATA_ACTIVE]="false"
    _sdata[SURICATA_EVE_FRESH]="false"
    _sdata[SURICATA_RULES]="0"
    _sdata[SURICATA_STATUS]="not_installed"
    _sdata[SURICATA_STATUS_CLASS]="inactive"

    # Get Suricata status
    if declare -f nftban_check_suricata_status &>/dev/null; then
        local suricata_json
        suricata_json=$(nftban_check_suricata_status 2>/dev/null)
        if command -v jq &>/dev/null && [[ -n "$suricata_json" ]]; then
            local data
            data=$(echo "$suricata_json" | jq -r '.data // {}')
            _sdata[SURICATA_INSTALLED]=$(echo "$data" | jq -r '.installed // false')
            _sdata[SURICATA_ACTIVE]=$(echo "$data" | jq -r '.service_active // false')
            _sdata[SURICATA_EVE_FRESH]=$(echo "$data" | jq -r '.eve_fresh // false')
            _sdata[SURICATA_RULES]=$(echo "$data" | jq -r '.rules_loaded // 0')
            _sdata[SURICATA_STATUS]=$(echo "$data" | jq -r '.status // "unknown"')

            # Set status class
            case "${_sdata[SURICATA_STATUS]}" in
                active|ok) _sdata[SURICATA_STATUS_CLASS]="active" ;;
                degraded|stale_eve) _sdata[SURICATA_STATUS_CLASS]="warning" ;;
                not_installed|stopped|inactive) _sdata[SURICATA_STATUS_CLASS]="inactive" ;;
                *) _sdata[SURICATA_STATUS_CLASS]="unknown" ;;
            esac
        fi
    fi
}

# =============================================================================
# DNS STATUS DATA (from shared checks)
# =============================================================================

_collect_dns_status() {
    local -n _ddata="$1"

    # Load shared checks library if needed
    local checks_lib="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_checks.sh"
    if ! declare -f nftban_check_dns &>/dev/null; then
        if [[ -f "$checks_lib" ]]; then
            # shellcheck source=/dev/null
            source "$checks_lib" 2>/dev/null || true
        fi
    fi

    # Default values
    _ddata[DNS_WORKING]="false"
    _ddata[DNS_RESOLVER]="unknown"
    _ddata[DNS_LATENCY]="0"
    _ddata[DNS_STATUS]="unknown"

    # Get DNS status
    if declare -f nftban_check_dns &>/dev/null; then
        local dns_json
        dns_json=$(nftban_check_dns 2>/dev/null)
        if command -v jq &>/dev/null && [[ -n "$dns_json" ]]; then
            local data
            data=$(echo "$dns_json" | jq -r '.data // {}')
            _ddata[DNS_WORKING]=$(echo "$data" | jq -r '.working // false')
            _ddata[DNS_RESOLVER]=$(echo "$data" | jq -r '.resolver // "unknown"')
            _ddata[DNS_LATENCY]=$(echo "$data" | jq -r '.latency_ms // 0')
            _ddata[DNS_STATUS]=$(echo "$data" | jq -r '.status // "unknown"')
        fi
    fi
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f nftban_report_collect_all
export -f nftban_report_top_ips
export -f nftban_report_top_countries
export -f nftban_report_top_sources
export -f nftban_report_recommendations
export -f nftban_report_substitute
export -f nftban_report_rbl_table
export -f nftban_posture_oneline

# =============================================================================
# END OF MODULE
# =============================================================================
