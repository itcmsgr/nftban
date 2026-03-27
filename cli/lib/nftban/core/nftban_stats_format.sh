#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Statistics Display & Trends
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Dashboard generation, export, and trend analysis extracted from nftban_stats.sh
#
# meta:name="nftban_stats_format"
# meta:type="core"
# meta:header="Statistics Display & Trends"
# meta:version="1.48.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# **Description & Purpose**
# meta:description="Dashboard generation, export, and trend analysis extracted from nftban_stats.sh"
# meta:input="Collected metrics from nftban_stats_collect.sh"
# meta:output="Terminal dashboards, JSON/CSV exports, trend reports"
#
# **Inventory & Requirements**
# meta:depends="nftban_stats.sh,nftban_stats_collect.sh"
# meta:inventory.files="/usr/lib/nftban/core/nftban_stats_format.sh"
# meta:inventory.binaries="jq,bc"
# meta:inventory.env_vars="NFTBAN_DATA_DIR,NFTBAN_LOG_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units="none"
# meta:inventory.network="none"
# meta:inventory.privileges="root:read-metrics"
#
# meta:created_date="2026-02-27"
# meta:updated_date="2026-02-27"
# =============================================================================

# Enhanced strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_STATS_FORMAT_LOADED:-}" ]] && return 0
readonly NFTBAN_STATS_FORMAT_LOADED=1

# =============================================================================
# DASHBOARD GENERATION
# =============================================================================

nftban_stats_generate_dashboard() {
    # Generate comprehensive terminal dashboard - Clean v1.0 layout
    # Usage: nftban_stats_generate_dashboard [since] [until]
    #
    # SINGLE SOURCE OF TRUTH: Uses unified cache when available

    local since="${1:-$(date -d '24 hours ago' +%Y-%m-%d)}"
    local until="${2:-$(date +%Y-%m-%d)}"

    # Load unified cache once for this dashboard run
    local use_unified_cache=false
    if nftban_stats_unified_available; then
        use_unified_cache=true
    fi

    # Collect metrics (uses unified cache internally)
    local total_bans unique_ips whitelist_count
    total_bans=$(nftban_stats_count_bans "$since" "$until")
    unique_ips=$(nftban_stats_count_unique_ips "$since" "$until")
    whitelist_count=$(nftban_stats_count_whitelist)

    # Header
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NFTBan Statistics Dashboard"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # ─────────────────────────────────────────────────────────────────────
    # SYSTEM
    # ─────────────────────────────────────────────────────────────────────
    echo "SYSTEM"
    echo "───────────────────────────────────────────────────────────"
    printf "  %-20s %s\n" "Hostname............" "$(hostname)"
    printf "  %-20s %s → %s\n" "Period.............." "$since" "$until"
    printf "  %-20s %s\n" "Generated..........." "$(date '+%Y-%m-%d %H:%M:%S')"
    if [[ "$use_unified_cache" == "true" ]]; then
        printf "  %-20s %s\n" "Data source........." "unified cache"
    fi
    echo ""

    # ─────────────────────────────────────────────────────────────────────
    # UNIFIED BLACKLIST (SINGLE SOURCE OF TRUTH from unified cache)
    # ─────────────────────────────────────────────────────────────────────
    local black_v4=0 black_v6=0
    local black_v4_temp=0 black_v4_perm=0
    local black_v6_temp=0 black_v6_perm=0

    if [[ "$use_unified_cache" == "true" ]]; then
        # Read from unified cache (Single Source of Truth)
        black_v4=$(nftban_stats_get_unified ".blacklist.ipv4.total" "0")
        black_v4_perm=$(nftban_stats_get_unified ".blacklist.ipv4.permanent" "0")
        black_v4_temp=$(nftban_stats_get_unified ".blacklist.ipv4.temporary" "0")
        black_v6=$(nftban_stats_get_unified ".blacklist.ipv6.total" "0")
        black_v6_perm=$(nftban_stats_get_unified ".blacklist.ipv6.permanent" "0")
        black_v6_temp=$(nftban_stats_get_unified ".blacklist.ipv6.temporary" "0")
    else
        # Fallback: Direct nftables query
        if timeout 10s nft list set "${NFTBAN_TABLE_IPV4}" blacklist_ipv4 &>/dev/null 2>&1; then
            local v4_output
            v4_output=$(timeout 10s nft list set "${NFTBAN_TABLE_IPV4}" blacklist_ipv4 2>/dev/null || true)
            black_v4_temp=$(echo "$v4_output" | { grep -oP 'timeout \d+[smhd]' 2>/dev/null || true; } | wc -l)
            black_v4=$(echo "$v4_output" | { grep -oP '\d+\.\d+\.\d+\.\d+(/\d+)?' || true; } | wc -l 2>/dev/null || echo "0")
            black_v4=${black_v4:-0}
            black_v4_temp=${black_v4_temp:-0}
            black_v4_perm=$((black_v4 - black_v4_temp))
            [[ $black_v4_perm -lt 0 ]] && black_v4_perm=0
        fi
        if timeout 10s nft list set "${NFTBAN_TABLE_IPV6}" blacklist_ipv6 &>/dev/null 2>&1; then
            local v6_output
            v6_output=$(timeout 10s nft list set "${NFTBAN_TABLE_IPV6}" blacklist_ipv6 2>/dev/null || true)
            black_v6_temp=$(echo "$v6_output" | { grep -oP 'timeout \d+[smhd]' 2>/dev/null || true; } | wc -l)
            black_v6=$(echo "$v6_output" | { grep -oP '[0-9a-fA-F:]+::[0-9a-fA-F:]*(/\d+)?|[0-9a-fA-F:]+:[0-9a-fA-F:]+(/\d+)?' || true; } | wc -l 2>/dev/null || echo "0")
            black_v6=${black_v6:-0}
            black_v6_temp=${black_v6_temp:-0}
            black_v6_perm=$((black_v6 - black_v6_temp))
            [[ $black_v6_perm -lt 0 ]] && black_v6_perm=0
        fi
    fi

    black_v4=${black_v4//[^0-9]/}
    black_v6=${black_v6//[^0-9]/}
    local total_black
    total_black=$((${black_v4:-0} + ${black_v6:-0}))

    # ─────────────────────────────────────────────────────────────────────
    # FIREWALL (CURRENT)
    # ─────────────────────────────────────────────────────────────────────
    echo "FIREWALL (CURRENT)"
    echo "───────────────────────────────────────────────────────────"
    printf "  %-20s %s\n" "Blocked IPs........." "$total_black"
    printf "  %-20s %s\n" "Whitelisted........." "$whitelist_count"
    echo ""

    # ─────────────────────────────────────────────────────────────────────
    # PROTECTION BREAKDOWN (all sources)
    # ─────────────────────────────────────────────────────────────────────
    echo "PROTECTION BREAKDOWN"
    echo "───────────────────────────────────────────────────────────"

    # Direct bans (blacklist sets) - show IPv4/IPv6 and temp/permanent
    echo "  Direct Bans (nftables):"
    printf "      %-16s %'d (perm: %'d, temp: %'d)\n" "IPv4............" "$black_v4" "$black_v4_perm" "$black_v4_temp"
    printf "      %-16s %'d (perm: %'d, temp: %'d)\n" "IPv6............" "$black_v6" "$black_v6_perm" "$black_v6_temp"

    # Count feeds (SINGLE SOURCE OF TRUTH from unified cache)
    local feeds_ipv4_total=0 feeds_ipv6_total=0
    if [[ "$use_unified_cache" == "true" ]]; then
        # Read from unified cache
        feeds_ipv4_total=$(nftban_stats_get_unified ".feeds.ipv4_total" "0")
        feeds_ipv6_total=$(nftban_stats_get_unified ".feeds.ipv6_total" "0")
    else
        # Ensure feeds library is loaded for discovery functions
        if ! type -t nftban_feeds_discover_all >/dev/null 2>&1; then
            if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_feeds.sh" ]]; then
                source "${NFTBAN_LIB_DIR}/core/nftban_feeds.sh" 2>/dev/null || true
            fi
        fi

        # Fallback: Scan feed files
        local feeds_dir="${NFTBAN_DATA_DIR:-/var/lib/nftban}/feeds"
        if [[ -d "$feeds_dir" ]]; then
            if type -t nftban_feeds_discover_all >/dev/null 2>&1 && type -t nftban_feeds_get_property >/dev/null 2>&1; then
                local all_feeds
                all_feeds=$(nftban_feeds_discover_all 2>/dev/null || true)
                for feed in $all_feeds; do
                    local enabled
                    enabled=$(nftban_feeds_get_property "$feed" "ENABLED" 2>/dev/null || echo "false")
                    if [[ "$enabled" == "true" ]]; then
                        local feed_lower="${feed,,}"
                        local feed_file="${feeds_dir}/${feed_lower}.txt"
                        if [[ -f "$feed_file" ]]; then
                            local v4_count v6_count
                            v4_count=$(grep -cE '^[0-9]+\.' "$feed_file" 2>/dev/null) || v4_count=0
                            v6_count=$(grep -cE '^[0-9a-fA-F]*:' "$feed_file" 2>/dev/null) || v6_count=0
                            feeds_ipv4_total=$((feeds_ipv4_total + v4_count))
                            feeds_ipv6_total=$((feeds_ipv6_total + v6_count))
                        fi
                    fi
                done
            fi
        fi
    fi
    echo "  Threat Feeds:"
    printf "      %-16s %'d\n" "IPv4............" "$feeds_ipv4_total"
    printf "      %-16s %'d\n" "IPv6............" "$feeds_ipv6_total"

    # Count geoban entries (SINGLE SOURCE OF TRUTH from unified cache)
    local geoban_total=0
    if [[ "$use_unified_cache" == "true" ]]; then
        # Read from unified cache
        geoban_total=$(nftban_stats_get_unified ".geoban.countries_blocked" "0")
    else
        # Fallback: Scan geoban config files
        local geoban_dir="${NFTBAN_DATA_DIR:-/var/lib/nftban}/geoban"
        if [[ -d "$geoban_dir" ]]; then
            local blocked_countries=0
            shopt -s nullglob 2>/dev/null || true
            for file in "$geoban_dir"/*.conf; do
                # v1.19.20 FIX
                [[ -f "$file" ]] && grep -q "^MODE=.*block" "$file" 2>/dev/null && { ((blocked_countries++)) || true; }
            done
            shopt -u nullglob 2>/dev/null || true
            geoban_total=$blocked_countries
        fi
    fi
    if [[ $geoban_total -gt 0 ]]; then
        printf "  %-20s %d countries\n" "GeoBan.............." "$geoban_total"
    fi

    local total_ipv4=$((black_v4 + feeds_ipv4_total))
    local total_ipv6=$((black_v6 + feeds_ipv6_total))
    local grand_total=$((total_ipv4 + total_ipv6))
    echo "  ─────────────────────────────────────"
    echo "  TOTAL:"
    printf "      %-16s %'d\n" "IPv4............" "$total_ipv4"
    printf "      %-16s %'d\n" "IPv6............" "$total_ipv6"
    printf "      %-16s %'d\n" "TOTAL..........." "$grand_total"
    echo ""

    # ─────────────────────────────────────────────────────────────────────
    # ACTIVITY HISTORY
    # ─────────────────────────────────────────────────────────────────────
    echo "ACTIVITY HISTORY"
    echo "───────────────────────────────────────────────────────────"
    printf "  %-20s %s\n" "New bans (period)..." "$total_bans"
    printf "  %-20s %s\n" "Unique IPs banned..." "$unique_ips"

    # Source breakdown (SINGLE SOURCE OF TRUTH via nftban_stats_ban_sources)
    local sources
    sources=$(nftban_stats_ban_sources "$since" "$until")
    if command -v jq &>/dev/null && [[ -n "$sources" ]]; then
        local login_bans portscan_bans ddos_bans manual feeds suricata_bans
        login_bans=$(echo "$sources" | jq -r '.login // 0')
        portscan_bans=$(echo "$sources" | jq -r '.portscan // 0')
        ddos_bans=$(echo "$sources" | jq -r '.ddos // 0')
        manual=$(echo "$sources" | jq -r '.manual // 0')
        feeds=$(echo "$sources" | jq -r '.feeds // 0')
        suricata_bans=$(echo "$sources" | jq -r '.suricata // 0')

        # Feeds: use actual loaded IPs (not bans.log which doesn't track feed loads)
        if [[ "$use_unified_cache" == "true" ]]; then
            local feeds_loaded
            feeds_loaded=$(nftban_stats_get_unified ".feeds.ips_total" "0")
            [[ "$feeds_loaded" -gt 0 ]] 2>/dev/null && feeds="$feeds_loaded"
        elif [[ "$feeds" == "0" ]]; then
            # Fallback: count feed files directly
            local feeds_dir="${NFTBAN_DATA_DIR:-/var/lib/nftban}/feeds"
            if [[ -d "$feeds_dir" ]]; then
                local feed_count
                feed_count=$(cat "$feeds_dir"/*.txt 2>/dev/null | wc -l)
                [[ "$feed_count" -gt 0 ]] && feeds="$feed_count"
            fi
        fi

        echo "  Modules:"
        printf "      %-14s %s\n" "Login..........." "$login_bans"
        printf "      %-14s %s\n" "Port Scan......." "$portscan_bans"
        printf "      %-14s %s\n" "DDoS............" "$ddos_bans"
        printf "      %-14s %s\n" "Manual.........." "$manual"
        printf "      %-14s %s\n" "Feeds..........." "$feeds"
        [[ "$suricata_bans" != "0" ]] && printf "      %-14s %s\n" "Suricata........" "$suricata_bans"

        if [[ "$login_bans" == "0" ]] && [[ "$portscan_bans" == "0" ]] && [[ "$ddos_bans" == "0" ]] && [[ "$manual" == "0" ]] && [[ "$feeds" == "0" ]] && [[ "$suricata_bans" == "0" ]]; then
            echo ""
            echo "  Summary: No new attacks detected this period."
            if [[ $total_black -gt 0 ]]; then
                echo "           Protection active: $total_black IPs blocked in firewall."
            fi
        fi
    fi
    echo ""

    # ─────────────────────────────────────────────────────────────────────
    # THREAT FEEDS
    # ─────────────────────────────────────────────────────────────────────
    if ! type -t nftban_feeds_discover_all >/dev/null 2>&1; then
        if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_feeds.sh" ]]; then
            source "${NFTBAN_LIB_DIR}/core/nftban_feeds.sh" 2>/dev/null || true
        fi
    fi

    if type -t nftban_feeds_discover_all >/dev/null 2>&1 && type -t nftban_feeds_get_property >/dev/null 2>&1; then
        echo "THREAT FEEDS"
        echo "───────────────────────────────────────────────────────────"

        local all_feeds
        all_feeds=$(nftban_feeds_discover_all 2>/dev/null || true)

        if [[ -n "$all_feeds" ]]; then
            local found_enabled=false
            for feed in $all_feeds; do
                local enabled
                enabled=$(nftban_feeds_get_property "$feed" "ENABLED" 2>/dev/null || echo "false")

                if [[ "$enabled" == "true" ]]; then
                    found_enabled=true
                    local feed_lower="${feed,,}"
                    local feed_file="${NFTBAN_FEEDS_STORAGE_DIR:-/var/lib/nftban/feeds}/${feed_lower}.txt"
                    if [[ -f "$feed_file" ]]; then
                        local count mtime
                        count=$(wc -l < "$feed_file" 2>/dev/null || true)
                        count=${count:-0}
                        mtime=$(date -r "$feed_file" '+%m-%d %H:%M' 2>/dev/null || echo "?")
                        local feed_padded
                        feed_padded=$(printf "%-20s" "$feed")
                        feed_padded="${feed_padded// /.}"
                        printf "  %s %s IPs (Updated: %s)\n" "$feed_padded" "$count" "$mtime"
                    else
                        local feed_padded
                        feed_padded=$(printf "%-20s" "$feed")
                        feed_padded="${feed_padded// /.}"
                        printf "  %s pending download\n" "$feed_padded"
                    fi
                fi
            done

            if [[ "$found_enabled" == "false" ]]; then
                echo "  (no feeds enabled)"
            fi
        else
            echo "  (no feeds configured)"
        fi
        echo ""
    fi

    # ─────────────────────────────────────────────────────────────────────
    # FIREWALL COUNTERS (nftables packet/byte counters since last reboot)
    # ─────────────────────────────────────────────────────────────────────
    local ipv4_pkt_count ipv6_pkt_count
    ipv4_pkt_count=$(nft list table "${NFTBAN_TABLE_IPV4}" 2>/dev/null | grep 'blacklist_ipv4.*counter' | grep -oP 'packets \K[0-9]+' || true)
    ipv4_pkt_count=${ipv4_pkt_count:-0}
    ipv6_pkt_count=$(nft list table "${NFTBAN_TABLE_IPV6}" 2>/dev/null | grep 'blacklist_ipv6.*counter' | grep -oP 'packets \K[0-9]+' || true)
    ipv6_pkt_count=${ipv6_pkt_count:-0}
    local total_pkt_blocked=$((ipv4_pkt_count + ipv6_pkt_count))

    if [[ $total_pkt_blocked -gt 0 ]]; then
        local formatted_ipv4 formatted_ipv6 formatted_total
        formatted_ipv4=$(printf "%'d" "$ipv4_pkt_count" 2>/dev/null || echo "$ipv4_pkt_count")
        formatted_ipv6=$(printf "%'d" "$ipv6_pkt_count" 2>/dev/null || echo "$ipv6_pkt_count")
        formatted_total=$(printf "%'d" "$total_pkt_blocked" 2>/dev/null || echo "$total_pkt_blocked")

        echo "FIREWALL COUNTERS (since last reboot)"
        echo "───────────────────────────────────────────────────────────"
        printf "  %-20s %s packets\n" "IPv4 dropped........" "$formatted_ipv4"
        printf "  %-20s %s packets\n" "IPv6 dropped........" "$formatted_ipv6"
        printf "  %-20s %s packets\n" "Total dropped......." "$formatted_total"
        echo "  (all sources: bans, feeds, geoban — resets on reboot)"
        echo ""
    fi

    # ─────────────────────────────────────────────────────────────────────
    # BANS BY MODULE (SINGLE SOURCE OF TRUTH from unified cache)
    # ─────────────────────────────────────────────────────────────────────
    echo "BANS BY MODULE"
    echo "───────────────────────────────────────────────────────────"

    local feeds_total=0 login_count=0 portscan_count=0 ddos_count=0 manual_count=0 suricata_count=0

    if [[ "$use_unified_cache" == "true" ]]; then
        # Read from unified cache (Single Source of Truth)
        login_count=$(nftban_stats_get_unified ".bans_by_source.login" "0")
        portscan_count=$(nftban_stats_get_unified ".bans_by_source.portscan" "0")
        ddos_count=$(nftban_stats_get_unified ".bans_by_source.ddos" "0")
        manual_count=$(nftban_stats_get_unified ".bans_by_source.manual" "0")
        suricata_count=$(nftban_stats_get_unified ".bans_by_source.suricata" "0")
        # Feeds total from feeds.ips_total (actual IPs loaded from feeds)
        feeds_total=$(nftban_stats_get_unified ".feeds.ips_total" "0")
    else
        # Fallback: Direct calculation
        local feeds_dir="${NFTBAN_DATA_DIR:-/var/lib/nftban}/feeds"
        local bans_log="${NFTBAN_LOG_DIR:-/var/log/nftban}/bans.log"

        # PERFORMANCE FIX: Use awk for O(n+m) instead of O(n*m) loop
        # Guard: only query nftables if table exists (prevents pipefail crash on uninitialized system)
        local counts_result=""
        if nft list table ip nftban &>/dev/null 2>&1; then
            counts_result=$(awk -F'|' '
                # First pass: Build IP->source map from bans.log (most recent entry wins)
                # Format: DATE|TIME|SOURCE|IP|COUNTRY|STATUS|REASON ($1|$2|$3|$4|$5|$6|$7)
                NR==FNR && NF>=4 {
                    ip=$4; src=$3
                    # Normalize source names
                    if (src ~ /login|loginmon/) sources[ip]="login"
                    else if (src ~ /portscan/) sources[ip]="portscan"
                    else if (src ~ /ddos/) sources[ip]="ddos"
                    else if (src ~ /manual|cli/) sources[ip]="manual"
                    else if (src ~ /feed/) sources[ip]="feeds"
                    else if (src ~ /suricata|ids/) sources[ip]="suricata"
                    next
                }
                # Second pass: Count IPs from nftables by their source
                {
                    while (match($0, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) {
                        ip = substr($0, RSTART, RLENGTH)
                        $0 = substr($0, RSTART + RLENGTH)
                        src = sources[ip]
                        if (src == "login") login++
                        else if (src == "portscan") portscan++
                        else if (src == "ddos") ddos++
                        else if (src == "manual") manual++
                        else if (src == "feeds") feeds++
                        else if (src == "suricata") suricata++
                    }
                }
                END {
                    printf "%d %d %d %d %d %d\n", login+0, portscan+0, ddos+0, manual+0, feeds+0, suricata+0
                }
            ' "$bans_log" <(timeout 10s nft list set "${NFTBAN_TABLE_IPV4}" blacklist_ipv4 2>/dev/null) 2>/dev/null) || true
        fi

        if [[ -n "$counts_result" ]]; then
            local counts_array
            # v1.19.21 FIX: IFS-tampering - save and restore IFS
            local OLD_IFS="$IFS"
            IFS=' ' read -ra counts_array <<< "$counts_result"
            IFS="$OLD_IFS"
            login_count="${counts_array[0]:-0}"
            portscan_count="${counts_array[1]:-0}"
            ddos_count="${counts_array[2]:-0}"
            manual_count="${counts_array[3]:-0}"
            local bans_log_feeds="${counts_array[4]:-0}"
            suricata_count="${counts_array[5]:-0}"
            feeds_total=$((feeds_total + bans_log_feeds))
        fi

        # FEEDS: Also count from enabled feed files
        if type -t nftban_feeds_discover_all >/dev/null 2>&1 && type -t nftban_feeds_get_property >/dev/null 2>&1; then
            local all_feeds
            all_feeds=$(nftban_feeds_discover_all 2>/dev/null || true)
            for feed in $all_feeds; do
                local enabled
                enabled=$(nftban_feeds_get_property "$feed" "ENABLED" 2>/dev/null || echo "false")
                if [[ "$enabled" == "true" ]]; then
                    local feed_lower="${feed,,}"
                    local feed_file="${feeds_dir}/${feed_lower}.txt"
                    if [[ -f "$feed_file" ]]; then
                        local count
                        count=$(grep -cE '^[0-9]' "$feed_file" 2>/dev/null) || count=0
                        feeds_total=$((feeds_total + count))
                    fi
                fi
            done
        fi
    fi

    # Display counts
    printf "  %-18s %'d IPs\n" "FEEDS" "$feeds_total"
    printf "  %-18s %'d IPs\n" "LOGIN" "$login_count"
    printf "  %-18s %'d IPs\n" "PORTSCAN" "$portscan_count"
    printf "  %-18s %'d IPs\n" "DDOS" "$ddos_count"
    printf "  %-18s %'d IPs\n" "MANUAL" "$manual_count"
    [[ "$suricata_count" -gt 0 ]] && printf "  %-18s %'d IPs\n" "SURICATA" "$suricata_count"
    echo ""

    # ─────────────────────────────────────────────────────────────────────
    # CURRENT ACTIVE BANS (sample)
    # ─────────────────────────────────────────────────────────────────────
    if [[ $total_black -gt 0 ]]; then
        echo "CURRENT ACTIVE BANS (sample)"
        echo "───────────────────────────────────────────────────────────"
        if timeout 10s nft list set "${NFTBAN_TABLE_IPV4}" blacklist_ipv4 &>/dev/null 2>&1; then
            timeout 10s nft list set "${NFTBAN_TABLE_IPV4}" blacklist_ipv4 2>/dev/null | \
                grep -oP '\d+\.\d+\.\d+\.\d+(/\d+)?' | \
                awk 'NR<=5 {print "  " $1}' 2>/dev/null || true
        fi
        echo ""
    fi

    # Top countries (if GeoIP enabled)
    if [[ "${STATS_GEOIP_ENABLED}" == "true" ]] && command -v nftban-geoip &>/dev/null && command -v jq &>/dev/null; then
        echo "TOP COUNTRIES"
        echo "───────────────────────────────────────────────────────────"
        nftban_stats_top_countries 5 "$since" "$until" | \
            jq -r '.[] | "  \(.country): \(.count)"' 2>/dev/null || true
        echo ""
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# =============================================================================
# RECENT ACTIVITY
# =============================================================================

nftban_stats_recent_activity() {
    # Show recent ban events
    # Usage: nftban_stats_recent_activity [limit]

    local limit="${1:-20}"

    if [[ ! -f "$NFTBAN_BAN_LOG" ]]; then
        echo "[WARN] No ban log available"
        return 0
    fi

    echo ""
    echo "Recent Activity (last ${limit})"
    echo "───────────────────────────────────────────────────────────────"
    echo ""

    # shellcheck disable=SC2034  # Structured log parsing - only some fields used
    tail -n "$limit" "$NFTBAN_BAN_LOG" | \
    while IFS='|' read -r timestamp id jail ip reason action timeout; do
        printf "%s | %-16s | %-12s | %s\n" \
            "$timestamp" "$ip" "$action" "$jail"
    done

    echo ""
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================

nftban_stats_export_json() {
    # Export statistics to JSON
    # Usage: nftban_stats_export_json [output_file] [since] [until]

    local output_file="${1:-$(mktemp /tmp/nftban-stats-XXXXXX.json)}"
    local since="${2:-$(date -d '30 days ago' +%Y-%m-%d)}"
    local until="${3:-$(date +%Y-%m-%d)}"

    if type -t nftban_print_status >/dev/null 2>&1; then
        nftban_print_status "info" "Exporting statistics to JSON: $output_file"
    else
        echo "[INFO] Exporting to: $output_file"
    fi

    # Build JSON structure
    cat > "$output_file" <<EOF
{
  "schema_version": "1.0.0",
  "report": {
    "type": "export",
    "period": {
      "since": "${since}",
      "until": "${until}"
    },
    "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "hostname": "$(hostname)"
  },
  "summary": {
    "total_bans": $(nftban_stats_count_bans "$since" "$until"),
    "unique_ips": $(nftban_stats_count_unique_ips "$since" "$until"),
    "active_bans": $(nftban_stats_count_active_bans),
    "whitelist_total": $(nftban_stats_count_whitelist)
  },
  "ban_sources": $(nftban_stats_ban_sources "$since" "$until"),
  "top_sources": $(nftban_stats_top_sources 10 "$since" "$until"),
  "top_ips": $(nftban_stats_top_ips 20 "$since" "$until"),
  "top_countries": $(nftban_stats_top_countries 10 "$since" "$until"),
  "timeline": $(nftban_stats_timeline "$since 00:00:00" "$until 23:59:59" "day")
}
EOF

    if type -t nftban_print_status >/dev/null 2>&1; then
        nftban_print_status "success" "Statistics exported to: $output_file"
    else
        echo "[SUCCESS] Exported to: $output_file"
    fi

    echo "$output_file"
}

nftban_stats_export_csv() {
    # Export ban log to CSV
    # Usage: nftban_stats_export_csv [output_file] [since] [until]

    local output_file="${1:-$(mktemp /tmp/nftban-stats-XXXXXX.csv)}"
    local since="${2:-$(date -d '30 days ago' +%Y-%m-%d)}"
    local until="${3:-$(date +%Y-%m-%d)}"

    if type -t nftban_print_status >/dev/null 2>&1; then
        nftban_print_status "info" "Exporting ban log to CSV: $output_file"
    else
        echo "[INFO] Exporting to: $output_file"
    fi

    if [[ ! -f "$NFTBAN_BAN_LOG" ]]; then
        echo "[ERROR] No ban log available"
        return 1
    fi

    # Create CSV header
    echo "Timestamp,ID,Source,IP,Reason,Action,Timeout" > "$output_file"

    # Export filtered data
    awk -F'|' -v since="$since" -v until="$until" \
        '$1 >= since && $1 <= until {print $0}' \
        "$NFTBAN_BAN_LOG" | \
    sed 's/|/,/g' >> "$output_file"

    local count
    count=$(($(wc -l < "$output_file") - 1))

    if type -t nftban_print_status >/dev/null 2>&1; then
        nftban_print_status "success" "Exported ${count} records to: $output_file"
    else
        echo "[SUCCESS] Exported ${count} records to: $output_file"
    fi

    echo "$output_file"
}

# =============================================================================
# MONITORING & ALERTS
# =============================================================================

nftban_stats_check_high_ban_rate() {
    # Check for high ban rate (alerts)
    # Usage: nftban_stats_check_high_ban_rate [threshold]
    # Returns: 0=alert triggered, 1=no alert

    local threshold="${1:-${STATS_ALERT_HIGH_BAN_RATE:-100}}"
    local since
    local until
    since="$(date -d '1 hour ago' +%Y-%m-%d\ %H:%M:%S)"
    until="$(date +%Y-%m-%d\ %H:%M:%S)"

    local recent_bans
    recent_bans=$(nftban_stats_count_bans "$since" "$until")

    if [[ $recent_bans -gt $threshold ]]; then
        if type -t nftban_print_status >/dev/null 2>&1; then
            nftban_print_status "warn" "High ban rate detected: ${recent_bans} bans in last hour (threshold: ${threshold})"
        else
            echo "[WARN] High ban rate: ${recent_bans} bans/hour (threshold: ${threshold})"
        fi
        return 0  # Alert triggered
    fi

    return 1  # No alert
}

nftban_stats_find_repeat_offenders() {
    # Identify repeat offenders
    # Usage: nftban_stats_find_repeat_offenders [threshold]
    # Returns: JSON array of IPs with multiple bans

    local threshold="${1:-${STATS_REPEAT_OFFENDER_THRESHOLD:-5}}"

    if [[ ! -f "$NFTBAN_BAN_LOG" ]]; then
        echo "[]"
        return 0
    fi

    awk -F'|' -v thresh="$threshold" '
    $6 == "BANNED" {ips[$4]++}
    END {
        printf "["
        first=1
        for (ip in ips) {
            if (ips[ip] >= thresh) {
                if (!first) printf ","
                printf "{\"ip\":\"%s\",\"count\":%d}", ip, ips[ip]
                first=0
            }
        }
        printf "]"
    }' "$NFTBAN_BAN_LOG"
}

# =============================================================================
# LOG CLEANUP & MAINTENANCE
# =============================================================================

nftban_stats_cleanup_logs() {
    # Rotate and cleanup old logs
    # Usage: nftban_stats_cleanup_logs [days]

    local days="${1:-${STATS_RETENTION_DAYS:-90}}"

    if type -t nftban_print_status >/dev/null 2>&1; then
        nftban_print_status "info" "Cleaning up logs older than ${days} days..."
    else
        echo "[INFO] Cleaning up logs older than ${days} days..."
    fi

    # NOTE: bans.log rotation handled exclusively by logrotate (copytruncate).
    # The previous mv-based rotation here conflicted with copytruncate and could
    # cause data loss when processes hold open file handles. Removed in v1.46.0.

    # Delete old compressed logs
    find "$(dirname "$NFTBAN_BAN_LOG")" -name "*.log.gz" -mtime +"${days}" -type f -delete 2>/dev/null || true

    # Delete old snapshots
    find "$NFTBAN_STATS_SNAPSHOTS_DIR" -type f -mtime +"${days}" -delete 2>/dev/null || true

    if type -t nftban_print_status >/dev/null 2>&1; then
        nftban_print_status "success" "Log cleanup complete"
    else
        echo "[SUCCESS] Log cleanup complete"
    fi
}

# =============================================================================
# SNAPSHOTS (for trending)
# =============================================================================

nftban_stats_create_snapshot() {
    # Create hourly snapshot for trending
    # Usage: nftban_stats_create_snapshot

    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local snapshot_file="${NFTBAN_STATS_SNAPSHOTS_DIR}/snapshot-${timestamp}.json"

    local since
    local until
    since="$(date -d '1 hour ago' +%Y-%m-%d\ %H:%M:%S)"
    until="$(date +%Y-%m-%d\ %H:%M:%S)"

    nftban_stats_export_json "$snapshot_file" "$since" "$until" &>/dev/null

    echo "$snapshot_file"
}

# =============================================================================
# TREND ANALYSIS (7-day rolling history)
# =============================================================================

# Storage paths for trend data
readonly NFTBAN_TREND_DIR="${NFTBAN_DATA_DIR:-/var/lib/nftban}/stats"
readonly NFTBAN_TREND_FILE="${NFTBAN_TREND_DIR}/trend_hourly.json"
readonly NFTBAN_TREND_RETENTION=168  # 7 days in hours

nftban_stats_trend_collect() {
    # Collect current hour statistics and append to trend history
    # Called hourly by maintenance timer
    # Usage: nftban_stats_trend_collect

    mkdir -p "$NFTBAN_TREND_DIR" 2>/dev/null || true

    # shellcheck disable=SC2034  # Reserved for time range queries
    local hour_start hour_end
    # shellcheck disable=SC2034  # Reserved for time range queries
    hour_end=$(date +%Y-%m-%dT%H:%M:%SZ)

    # Count bans/unbans in current hour
    local today bans unbans
    today=$(date +%Y-%m-%d)
    local hour_pattern
    hour_pattern="^${today}|$(date +%H):"

    if [[ -f "$NFTBAN_BAN_LOG" ]]; then
        bans=$(grep -c "BANNED$" "$NFTBAN_BAN_LOG" 2>/dev/null | grep -cE "$hour_pattern" 2>/dev/null) || bans=0
        unbans=$(grep -c "UNBANNED$" "$NFTBAN_BAN_LOG" 2>/dev/null | grep -cE "$hour_pattern" 2>/dev/null) || unbans=0

        # Simpler: count today's bans in current hour
        bans=$(awk -F'|' -v h="$(date +%H)" '$1 ~ /^[0-9]/ && $2 ~ "^"h":" && $6=="BANNED" {c++} END {print c+0}' "$NFTBAN_BAN_LOG" 2>/dev/null) || bans=0
        unbans=$(awk -F'|' -v h="$(date +%H)" '$1 ~ /^[0-9]/ && $2 ~ "^"h":" && $6=="UNBANNED" {c++} END {print c+0}' "$NFTBAN_BAN_LOG" 2>/dev/null) || unbans=0
    else
        bans=0
        unbans=0
    fi

    # Count by source
    local login_c=0 portscan_c=0 feeds_c=0 ddos_c=0 manual_c=0
    if [[ -f "$NFTBAN_BAN_LOG" ]]; then
        login_c=$(awk -F'|' -v h="$(date +%H)" '$2 ~ "^"h":" && $3=="login" && $6=="BANNED" {c++} END {print c+0}' "$NFTBAN_BAN_LOG" 2>/dev/null) || login_c=0
        portscan_c=$(awk -F'|' -v h="$(date +%H)" '$2 ~ "^"h":" && $3=="portscan" && $6=="BANNED" {c++} END {print c+0}' "$NFTBAN_BAN_LOG" 2>/dev/null) || portscan_c=0
        feeds_c=$(awk -F'|' -v h="$(date +%H)" '$2 ~ "^"h":" && $3=="feeds" && $6=="BANNED" {c++} END {print c+0}' "$NFTBAN_BAN_LOG" 2>/dev/null) || feeds_c=0
        ddos_c=$(awk -F'|' -v h="$(date +%H)" '$2 ~ "^"h":" && $3=="ddos" && $6=="BANNED" {c++} END {print c+0}' "$NFTBAN_BAN_LOG" 2>/dev/null) || ddos_c=0
        manual_c=$(awk -F'|' -v h="$(date +%H)" '$2 ~ "^"h":" && $3=="manual" && $6=="BANNED" {c++} END {print c+0}' "$NFTBAN_BAN_LOG" 2>/dev/null) || manual_c=0
    fi

    # Create new sample JSON
    local sample
    sample=$(cat <<EOF
{"hour":"${hour_start}","bans":${bans},"unbans":${unbans},"sources":{"login":${login_c},"portscan":${portscan_c},"feeds":${feeds_c},"ddos":${ddos_c},"manual":${manual_c}}}
EOF
)

    # Load existing data, append, and enforce retention
    local temp_file="${NFTBAN_TREND_FILE}.tmp"

    if [[ -f "$NFTBAN_TREND_FILE" ]] && command -v jq &>/dev/null; then
        # Append and trim to retention limit
        jq --argjson new "$sample" --argjson max "$NFTBAN_TREND_RETENTION" \
            '.samples += [$new] | .samples = .samples[-$max:]' \
            "$NFTBAN_TREND_FILE" > "$temp_file" 2>/dev/null && \
            mv "$temp_file" "$NFTBAN_TREND_FILE"
    else
        # Initialize new file
        echo "{\"samples\":[$sample],\"retention_hours\":$NFTBAN_TREND_RETENTION}" > "$NFTBAN_TREND_FILE"
    fi

    chown nftban:nftban "$NFTBAN_TREND_FILE" 2>/dev/null || true
    chmod 640 "$NFTBAN_TREND_FILE" 2>/dev/null || true
}

nftban_stats_trend_load() {
    # Load trend history
    # Usage: nftban_stats_trend_load
    # Returns: JSON array of samples

    if [[ -f "$NFTBAN_TREND_FILE" ]] && command -v jq &>/dev/null; then
        jq -r '.samples' "$NFTBAN_TREND_FILE" 2>/dev/null
    else
        echo "[]"
    fi
}

nftban_stats_trend_averages() {
    # Calculate averages from trend data
    # Usage: nftban_stats_trend_averages
    # Returns: JSON with avg, min, max, stddev

    if [[ ! -f "$NFTBAN_TREND_FILE" ]] || ! command -v jq &>/dev/null; then
        echo '{"avg_hourly":0,"avg_daily":0,"min":0,"max":0,"stddev":0,"samples":0}'
        return
    fi

    jq '
        .samples as $s |
        ($s | length) as $n |
        if $n == 0 then
            {"avg_hourly":0,"avg_daily":0,"min":0,"max":0,"stddev":0,"samples":0}
        else
            ($s | map(.bans) | add / $n) as $avg |
            ($s | map(.bans) | min) as $min |
            ($s | map(.bans) | max) as $max |
            ($s | map((.bans - $avg) * (.bans - $avg)) | add / $n | sqrt) as $stddev |
            {
                "avg_hourly": ($avg | . * 10 | floor / 10),
                "avg_daily": ($avg * 24 | floor),
                "min": $min,
                "max": $max,
                "stddev": ($stddev | . * 10 | floor / 10),
                "samples": $n
            }
        end
    ' "$NFTBAN_TREND_FILE" 2>/dev/null || echo '{"avg_hourly":0,"avg_daily":0,"min":0,"max":0,"stddev":0,"samples":0}'
}

nftban_stats_trend_thresholds() {
    # Calculate suggested thresholds based on stddev
    # Usage: nftban_stats_trend_thresholds
    # Returns: JSON with warning and critical thresholds

    local stats
    stats=$(nftban_stats_trend_averages)

    if ! command -v jq &>/dev/null; then
        echo '{"warning":10,"critical":25}'
        return
    fi

    echo "$stats" | jq '
        (.avg_hourly + (1.5 * .stddev)) as $warn |
        (.avg_hourly + (3 * .stddev)) as $crit |
        {
            "warning": ([($warn | floor), 10] | max),
            "critical": ([($crit | floor), 25] | max),
            "based_on_samples": .samples
        }
    ' 2>/dev/null || echo '{"warning":10,"critical":25,"based_on_samples":0}'
}

nftban_stats_trend_compare() {
    # Compare current period vs previous periods
    # Usage: nftban_stats_trend_compare
    # Returns: JSON with vs_yesterday and vs_last_week percentages

    if [[ ! -f "$NFTBAN_TREND_FILE" ]] || ! command -v jq &>/dev/null; then
        echo '{"vs_yesterday":0,"vs_last_week":0}'
        return
    fi

    jq '
        .samples as $s |
        ($s | length) as $n |
        if $n < 48 then
            {"vs_yesterday":0,"vs_last_week":0,"insufficient_data":true}
        else
            # Last 24 hours
            ($s[-24:] | map(.bans) | add) as $today |
            # Previous 24 hours (24-48 hours ago)
            ($s[-48:-24] | map(.bans) | add) as $yesterday |
            # Calculate week comparison if enough data
            (if $n >= 168 then ($s[-168:-144] | map(.bans) | add) else 0 end) as $last_week |
            {
                "today_total": $today,
                "yesterday_total": $yesterday,
                "vs_yesterday": (if $yesterday > 0 then ((($today - $yesterday) / $yesterday * 100) | . * 10 | floor / 10) else 0 end),
                "vs_last_week": (if $last_week > 0 and $n >= 168 then ((($today - $last_week) / $last_week * 100) | . * 10 | floor / 10) else null end)
            }
        end
    ' "$NFTBAN_TREND_FILE" 2>/dev/null || echo '{"vs_yesterday":0,"vs_last_week":0}'
}

nftban_stats_trend_top_sources() {
    # Get source breakdown for trend period
    # Usage: nftban_stats_trend_top_sources
    # Returns: JSON with source totals and percentages

    if [[ ! -f "$NFTBAN_TREND_FILE" ]] || ! command -v jq &>/dev/null; then
        echo '[]'
        return
    fi

    jq '
        .samples | map(.sources) |
        reduce .[] as $s ({"login":0,"portscan":0,"feeds":0,"ddos":0,"manual":0};
            . + {
                "login": (.login + $s.login),
                "portscan": (.portscan + $s.portscan),
                "feeds": (.feeds + $s.feeds),
                "ddos": (.ddos + $s.ddos),
                "manual": (.manual + $s.manual)
            }
        ) |
        . as $totals |
        ($totals | add) as $grand_total |
        to_entries | map({
            "source": .key,
            "count": .value,
            "percent": (if $grand_total > 0 then (.value / $grand_total * 100 | . * 10 | floor / 10) else 0 end)
        }) | sort_by(-.count)
    ' "$NFTBAN_TREND_FILE" 2>/dev/null || echo '[]'
}

nftban_stats_trend_display() {
    # Display formatted trend analysis
    # Usage: nftban_stats_trend_display [--json]

    local json_mode=0
    [[ "${1:-}" == "--json" ]] && json_mode=1

    if [[ $json_mode -eq 1 ]]; then
        # JSON output
        local averages compare sources thresholds hourly_data
        averages=$(nftban_stats_trend_averages)
        compare=$(nftban_stats_trend_compare)
        sources=$(nftban_stats_trend_top_sources)
        thresholds=$(nftban_stats_trend_thresholds)

        # Get hourly data points for charting (last 168 hours / 7 days)
        if [[ -f "$NFTBAN_TREND_FILE" ]] && command -v jq &>/dev/null; then
            hourly_data=$(jq '[.samples[] | {hour: .hour, bans: .bans, sources: .sources}]' "$NFTBAN_TREND_FILE" 2>/dev/null || echo '[]')
        else
            hourly_data='[]'
        fi

        jq -n --argjson avg "$averages" --argjson cmp "$compare" \
              --argjson src "$sources" --argjson thr "$thresholds" \
              --argjson hourly "$hourly_data" \
            '{averages: $avg, comparison: $cmp, sources: $src, thresholds: $thr, hourly: $hourly}'
        return
    fi

    # Text output
    echo ""
    echo "BAN STATISTICS TREND (Last 7 Days)"
    echo "══════════════════════════════════════════════════════════════"
    echo ""

    # Get data
    local avg_data compare_data sources_data threshold_data
    avg_data=$(nftban_stats_trend_averages)
    compare_data=$(nftban_stats_trend_compare)
    sources_data=$(nftban_stats_trend_top_sources)
    threshold_data=$(nftban_stats_trend_thresholds)

    if ! command -v jq &>/dev/null; then
        echo "[WARN] jq not installed - trend analysis requires jq"
        return 1
    fi

    local samples avg_h avg_d min_v max_v
    samples=$(echo "$avg_data" | jq -r '.samples')
    avg_h=$(echo "$avg_data" | jq -r '.avg_hourly')
    avg_d=$(echo "$avg_data" | jq -r '.avg_daily')
    min_v=$(echo "$avg_data" | jq -r '.min')
    max_v=$(echo "$avg_data" | jq -r '.max')

    if [[ "$samples" == "0" ]]; then
        echo "  No trend data available yet."
        echo "  Trend data is collected every 15 minutes by the maintenance timer."
        echo ""
        echo "  Enable timer: nftban timers enable nftban-maintenance.timer"
        return 0
    fi

    echo "AVERAGES (${samples} samples)"
    echo "───────────────────────────────────────────────────────────────"
    printf "  %-20s %s (min: %s, max: %s)\n" "Bans per hour......." "$avg_h" "$min_v" "$max_v"
    printf "  %-20s %s\n" "Bans per day........" "$avg_d"
    echo ""

    # Suggested thresholds
    local warn_t crit_t
    warn_t=$(echo "$threshold_data" | jq -r '.warning')
    crit_t=$(echo "$threshold_data" | jq -r '.critical')

    echo "SUGGESTED THRESHOLDS (based on stddev)"
    echo "───────────────────────────────────────────────────────────────"
    printf "  %-20s %s/hour\n" "Warning threshold..." "$warn_t"
    printf "  %-20s %s/hour\n" "Critical threshold.." "$crit_t"
    echo ""

    # Trend direction
    local vs_yest vs_week today_t yest_t
    vs_yest=$(echo "$compare_data" | jq -r '.vs_yesterday')
    vs_week=$(echo "$compare_data" | jq -r '.vs_last_week // "N/A"')
    today_t=$(echo "$compare_data" | jq -r '.today_total // 0')
    yest_t=$(echo "$compare_data" | jq -r '.yesterday_total // 0')

    echo "TREND DIRECTION"
    echo "───────────────────────────────────────────────────────────────"

    local arrow_yest="→"
    if [[ "$vs_yest" != "0" ]] && [[ "$vs_yest" != "null" ]]; then
        if (( $(echo "$vs_yest > 0" | bc -l 2>/dev/null || echo 0) )); then
            arrow_yest="↑"
        elif (( $(echo "$vs_yest < 0" | bc -l 2>/dev/null || echo 0) )); then
            arrow_yest="↓"
        fi
    fi
    printf "  %-20s %s %s%% (%s → %s)\n" "vs Yesterday........" "$arrow_yest" "$vs_yest" "$yest_t" "$today_t"

    if [[ "$vs_week" != "null" ]] && [[ "$vs_week" != "N/A" ]]; then
        local arrow_week="→"
        if (( $(echo "$vs_week > 0" | bc -l 2>/dev/null || echo 0) )); then
            arrow_week="↑"
        elif (( $(echo "$vs_week < 0" | bc -l 2>/dev/null || echo 0) )); then
            arrow_week="↓"
        fi
        printf "  %-20s %s %s%%\n" "vs Last Week........" "$arrow_week" "$vs_week"
    else
        printf "  %-20s %s\n" "vs Last Week........" "(need 7 days of data)"
    fi
    echo ""

    # Top sources
    echo "TOP SOURCES (7-day)"
    echo "───────────────────────────────────────────────────────────────"
    echo "$sources_data" | jq -r '.[] | select(.count > 0) | "  \(.source)............ \(.percent)% (\(.count) bans)"' 2>/dev/null || true
    echo ""
    echo "══════════════════════════════════════════════════════════════"
}
