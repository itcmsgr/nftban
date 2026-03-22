#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_unified_exporter_collect"
# meta:type="exporter"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Main metrics collection function (collect_all_metrics)"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_UNIFIED_EXPORTER_COLLECT_LOADED:-}" ]] && return 0
_UNIFIED_EXPORTER_COLLECT_LOADED="true"

# =============================================================================
# METRIC COLLECTION (Single collection for all targets)
# =============================================================================
# Groups: live, extended, inventory
# - live:      daemon, bans, memory, nftables, connections (every run)
# - extended:  module_status, feed_health, watchdog, eventbus (every 5 runs)
# - inventory: kernel, geoip, server_info, static config (every 60 runs)
# =============================================================================
collect_all_metrics() {
    local collection_groups="${1:-live extended inventory}"
    log_debug "Collecting metrics (groups: $collection_groups)..."

    local metrics=""
    local timestamp
    timestamp=$(date +%s)

    # Helper: check if a group is active
    # shellcheck disable=SC2076  # Literal match intended (not regex)
    group_active() { [[ " $collection_groups " =~ " $1 " ]]; }

    # =========================================================================
    # LIVE METRICS (every run - 60s)
    # =========================================================================
    local pid=0 status=0 uptime=0
    # Memory metrics (declared at function level for JSON cache access)
    local rss=0 fds=0 threads=0
    # Network metrics (declared at function level for JSON cache access)
    local total_rx_mbps=0 total_tx_mbps=0 peak_rx=0 peak_tx=0
    local conn_active=0 conn_established=0 conn_time_wait=0
    # Network totals for Zabbix compatibility
    local total_rx_bytes=0 total_tx_bytes=0 total_rx_packets=0 total_tx_packets=0
    local total_rx_errors=0 total_tx_errors=0 total_rx_dropped=0 total_tx_dropped=0
    local total_errors=0 total_dropped=0 bandwidth_in_bps=0 bandwidth_out_bps=0
    # Kernel metrics (declared at function level for JSON cache access)
    local conntrack_entries=0 conntrack_max=0 conntrack_utilization=0
    local softnet_drops_total=0 softnet_drops_rate=0
    # Whitelist metrics (declared at function level for JSON cache access - LIVE group)
    local whitelist_v4=0 whitelist_v6=0
    # Feeds metrics (declared at function level for JSON cache access - LIVE group)
    local feeds_enabled=0 feeds_loaded=0 feeds_failed=0
    local feeds_ips=0 feeds_ipv4_total=0 feeds_ipv6_total=0
    # Blacklist active counts (declared at function level for JSON cache and EXTENDED group)
    local active_v4=0 active_v6=0 active_total=0
    local blacklist_v4_perm=0 blacklist_v4_temp=0 blacklist_v6_perm=0 blacklist_v6_temp=0
    if group_active "live"; then

        # --- Daemon Metrics ---
        local version
        version=$(cat "${NFTBAN_LIB_DIR}/VERSION" 2>/dev/null | head -1 || echo "unknown")

        if systemctl is-active nftband.service &>/dev/null; then
            status=1
            pid=$(cat "${NFTBAN_RUN_DIR}/nftband.pid" 2>/dev/null || echo "0")
            local start_time
            start_time=$(systemctl show nftband.service -p ActiveEnterTimestamp --value 2>/dev/null || echo "")
            if [[ -n "$start_time" ]]; then
                local start_epoch
                start_epoch=$(date -d "$start_time" +%s 2>/dev/null || echo "$timestamp")
                uptime=$((timestamp - start_epoch))
            fi
        fi
        local mode
        mode=$(cat "${NFTBAN_RUN_DIR}/mode" 2>/dev/null || echo "normal")

        metrics+="nftban_daemon_up $status $timestamp\n"
        metrics+="nftban_version_info{version=\"$version\"} 1 $timestamp\n"
        metrics+="nftban_mode_info{mode=\"$mode\"} 1 $timestamp\n"
        # Zabbix-specific: send version and mode as string values (template expects these)
        metrics+="nftban.version.info |STRING|$version $timestamp\n"
        metrics+="nftban.mode.info |STRING|$mode $timestamp\n"
        metrics+="nftban_uptime_seconds $uptime $timestamp\n"
        metrics+="nftban_pid $pid $timestamp\n"

        # --- Panel Detection ---
        local panel="none"
        if [[ -d /usr/local/cpanel ]] && [[ -f /usr/local/cpanel/cpanel ]]; then
            panel="cpanel"
        elif [[ -d /usr/local/psa ]] && command -v plesk &>/dev/null; then
            panel="plesk"
        elif [[ -d /usr/local/directadmin ]] && [[ -f /usr/local/directadmin/directadmin ]]; then
            panel="directadmin"
        elif [[ -d /usr/local/cwpsrv ]]; then
            panel="cwp"
        elif [[ -d /usr/local/CyberPanel ]]; then
            panel="cyberpanel"
        elif command -v hestia &>/dev/null || [[ -d /usr/local/hestia ]]; then
            panel="hestia"
        fi
        metrics+="nftban_panel_info{panel=\"$panel\"} 1 $timestamp\n"
        # Zabbix string metric for host inventory
        metrics+="nftban.server.panel |STRING|$panel $timestamp\n"

        # --- Ban Metrics (SINGLE SOURCE OF TRUTH: nft_schema.sh centralized counting) ---
        # These metrics align with nftban_stats.sh dashboard requirements
        # Variables declared at function level: active_v4/v6, blacklist_v4/v6_perm/temp
        if declare -f nftban_nft_count_all_sets_cached >/dev/null 2>&1; then
            # v1.32.0: Use daemon cache (0 kernel calls), falls back to kernel
            local counts_json
            counts_json=$(nftban_nft_count_all_sets_cached 2>/dev/null || echo '{}')

            if [[ -n "$counts_json" ]] && command -v jq &>/dev/null; then
                # v1.32.0: Handle both daemon cache format and legacy kernel format
                if echo "$counts_json" | jq -e '.sets' &>/dev/null; then
                    # Daemon cache format: .sets.<setname>.count
                    # v1.33.0: Sum interval (feeds) + hash (manual) sets
                    local bl_interval_v4 bl_manual_v4 bl_interval_v6 bl_manual_v6
                    bl_interval_v4=$(echo "$counts_json" | jq -r '.sets.blacklist_ipv4.count // 0')
                    bl_manual_v4=$(echo "$counts_json" | jq -r '.sets.blacklist_manual_ipv4.count // 0')
                    bl_interval_v6=$(echo "$counts_json" | jq -r '.sets.blacklist_ipv6.count // 0')
                    bl_manual_v6=$(echo "$counts_json" | jq -r '.sets.blacklist_manual_ipv6.count // 0')
                    active_v4=$((bl_interval_v4 + bl_manual_v4))
                    active_v6=$((bl_interval_v6 + bl_manual_v6))
                    # Temp/perm split not available from daemon cache — report all as permanent
                    blacklist_v4_temp=0
                    blacklist_v6_temp=0
                    blacklist_v4_perm=$active_v4
                    blacklist_v6_perm=$active_v6
                else
                    # Legacy kernel format: .blacklist.ipv4
                    active_v4=$(echo "$counts_json" | jq -r '.blacklist.ipv4 // 0')
                    active_v6=$(echo "$counts_json" | jq -r '.blacklist.ipv6 // 0')
                    blacklist_v4_temp=$(echo "$counts_json" | jq -r '.temporary.ipv4 // 0')
                    blacklist_v6_temp=$(echo "$counts_json" | jq -r '.temporary.ipv6 // 0')
                    blacklist_v4_perm=$(echo "$counts_json" | jq -r '.permanent.ipv4 // 0')
                    blacklist_v6_perm=$(echo "$counts_json" | jq -r '.permanent.ipv6 // 0')
                fi
            fi
        elif command -v nft &>/dev/null; then
            # Fallback: Use direct nft_schema.sh counting functions
            # v1.33.0: Sum interval (feeds) + hash (manual) sets
            local fb_interval_v4 fb_manual_v4 fb_interval_v6 fb_manual_v6
            fb_interval_v4=$(nftban_nft_count_set ip nftban blacklist_ipv4 2>/dev/null || echo 0)
            fb_manual_v4=$(nftban_nft_count_set ip nftban blacklist_manual_ipv4 2>/dev/null || echo 0)
            fb_interval_v6=$(nftban_nft_count_set ip6 nftban blacklist_ipv6 2>/dev/null || echo 0)
            fb_manual_v6=$(nftban_nft_count_set ip6 nftban blacklist_manual_ipv6 2>/dev/null || echo 0)
            active_v4=$((fb_interval_v4 + fb_manual_v4))
            active_v6=$((fb_interval_v6 + fb_manual_v6))
            blacklist_v4_temp=$(nftban_nft_count_set_with_timeout ip nftban blacklist_ipv4 2>/dev/null || echo 0)
            blacklist_v6_temp=$(nftban_nft_count_set_with_timeout ip6 nftban blacklist_ipv6 2>/dev/null || echo 0)
            blacklist_v4_perm=$((active_v4 - blacklist_v4_temp))
            blacklist_v6_perm=$((active_v6 - blacklist_v6_temp))
            [[ $blacklist_v4_perm -lt 0 ]] && blacklist_v4_perm=0
            [[ $blacklist_v6_perm -lt 0 ]] && blacklist_v6_perm=0
        fi
        active_total=$((active_v4 + active_v6))

        metrics+="nftban_active_count $active_total $timestamp\n"
        # Zabbix-specific: nftban.blocks.total is what the template expects
        metrics+="nftban_blocks_total $active_total $timestamp\n"
        # Prometheus-style with labels (for Prometheus)
        metrics+="nftban_active_bans{family=\"ipv4\"} $active_v4 $timestamp\n"
        metrics+="nftban_active_bans{family=\"ipv6\"} $active_v6 $timestamp\n"
        # Zabbix-specific: separate keys without labels (template expects nftban.active.bans)
        metrics+="nftban.active.bans $active_total $timestamp\n"
        metrics+="nftban.active.bans.ipv4 $active_v4 $timestamp\n"
        metrics+="nftban.active.bans.ipv6 $active_v6 $timestamp\n"

        # Perm/temp breakdown (aligned with nftban stats dashboard)
        metrics+="nftban_blacklist_ipv4_perm $blacklist_v4_perm $timestamp\n"
        metrics+="nftban_blacklist_ipv4_temp $blacklist_v4_temp $timestamp\n"
        metrics+="nftban_blacklist_ipv6_perm $blacklist_v6_perm $timestamp\n"
        metrics+="nftban_blacklist_ipv6_temp $blacklist_v6_temp $timestamp\n"

        # --- Whitelist Metrics (moved to LIVE for real-time consistency with nftban stats) ---
        # Use fast JSON API for O(1) counting (same as blacklist)
        whitelist_v4=0
        whitelist_v6=0
        # v1.32.0: Prefer cached counting (0 kernel calls)
        if declare -f nftban_nft_count_set_cached >/dev/null 2>&1; then
            whitelist_v4=$(nftban_nft_count_set_cached whitelist_ipv4 2>/dev/null) || whitelist_v4=0
            [[ -z "$whitelist_v4" || ! "$whitelist_v4" =~ ^[0-9]+$ ]] && whitelist_v4=0
            whitelist_v6=$(nftban_nft_count_set_cached whitelist_ipv6 2>/dev/null) || whitelist_v6=0
            [[ -z "$whitelist_v6" || ! "$whitelist_v6" =~ ^[0-9]+$ ]] && whitelist_v6=0
        elif command -v nft &>/dev/null; then
            whitelist_v4=$(nft -j list set "${NFTBAN_TABLE_IPV4}" whitelist_ipv4 2>/dev/null | jq -r '.nftables[]?.set?.elem // [] | length' 2>/dev/null) || whitelist_v4=0
            [[ -z "$whitelist_v4" || ! "$whitelist_v4" =~ ^[0-9]+$ ]] && whitelist_v4=0
            whitelist_v6=$(nft -j list set "${NFTBAN_TABLE_IPV6}" whitelist_ipv6 2>/dev/null | jq -r '.nftables[]?.set?.elem // [] | length' 2>/dev/null) || whitelist_v6=0
            [[ -z "$whitelist_v6" || ! "$whitelist_v6" =~ ^[0-9]+$ ]] && whitelist_v6=0
        fi
        metrics+="nftban_whitelist{family=\"ipv4\"} $whitelist_v4 $timestamp\n"
        metrics+="nftban_whitelist{family=\"ipv6\"} $whitelist_v6 $timestamp\n"
        metrics+="nftban_whitelist_total $((whitelist_v4 + whitelist_v6)) $timestamp\n"

        # --- Botguard Metrics (LIVE - real-time bot classification set counts) ---
        local bg_suspect=0 bg_pending=0 bg_allow=0 bg_grey=0 bg_ban=0 bg_emergency=0
        if [[ -n "${counts_json:-}" ]] && command -v jq &>/dev/null; then
            if echo "$counts_json" | jq -e '.sets' &>/dev/null; then
                # v1.32.0: Daemon cache format — .sets.http_bot_suspect.count
                bg_suspect=$(echo "$counts_json" | jq -r '((.sets.http_bot_suspect.count // 0) + (.sets.http_bot_suspect6.count // 0))')
                bg_pending=$(echo "$counts_json" | jq -r '((.sets.http_bot_pending.count // 0) + (.sets.http_bot_pending6.count // 0))')
                bg_allow=$(echo "$counts_json" | jq -r '((.sets.http_bot_allow.count // 0) + (.sets.http_bot_allow6.count // 0))')
                bg_grey=$(echo "$counts_json" | jq -r '((.sets.http_bot_grey.count // 0) + (.sets.http_bot_grey6.count // 0))')
                bg_ban=$(echo "$counts_json" | jq -r '((.sets.http_bot_ban.count // 0) + (.sets.http_bot_ban6.count // 0))')
                bg_emergency=$(echo "$counts_json" | jq -r '((.sets.http_bot_emergency.count // 0) + (.sets.http_bot_emergency6.count // 0))')
            else
                # Legacy kernel format: .botguard.suspect.ipv4
                bg_suspect=$(echo "$counts_json" | jq -r '((.botguard.suspect.ipv4 // 0) + (.botguard.suspect.ipv6 // 0))')
                bg_pending=$(echo "$counts_json" | jq -r '((.botguard.pending.ipv4 // 0) + (.botguard.pending.ipv6 // 0))')
                bg_allow=$(echo "$counts_json" | jq -r '((.botguard.allow.ipv4 // 0) + (.botguard.allow.ipv6 // 0))')
                bg_grey=$(echo "$counts_json" | jq -r '((.botguard.grey.ipv4 // 0) + (.botguard.grey.ipv6 // 0))')
                bg_ban=$(echo "$counts_json" | jq -r '((.botguard.ban.ipv4 // 0) + (.botguard.ban.ipv6 // 0))')
                bg_emergency=$(echo "$counts_json" | jq -r '((.botguard.emergency.ipv4 // 0) + (.botguard.emergency.ipv6 // 0))')
            fi
            # Validate numeric — fall back to 0 if jq returns non-numeric
            [[ "$bg_suspect" =~ ^[0-9]+$ ]] || bg_suspect=0
            [[ "$bg_pending" =~ ^[0-9]+$ ]] || bg_pending=0
            [[ "$bg_allow" =~ ^[0-9]+$ ]] || bg_allow=0
            [[ "$bg_grey" =~ ^[0-9]+$ ]] || bg_grey=0
            [[ "$bg_ban" =~ ^[0-9]+$ ]] || bg_ban=0
            [[ "$bg_emergency" =~ ^[0-9]+$ ]] || bg_emergency=0
        fi
        metrics+="nftban_botguard_set_count{category=\"suspect\"} $bg_suspect $timestamp\n"
        metrics+="nftban_botguard_set_count{category=\"pending\"} $bg_pending $timestamp\n"
        metrics+="nftban_botguard_set_count{category=\"allow\"} $bg_allow $timestamp\n"
        metrics+="nftban_botguard_set_count{category=\"grey\"} $bg_grey $timestamp\n"
        metrics+="nftban_botguard_set_count{category=\"ban\"} $bg_ban $timestamp\n"
        metrics+="nftban_botguard_set_count{category=\"emergency\"} $bg_emergency $timestamp\n"
        metrics+="nftban_botguard_total_tracked $((bg_suspect + bg_pending + bg_allow + bg_grey + bg_ban + bg_emergency)) $timestamp\n"

        # --- Feeds Metrics (moved to LIVE for real-time consistency with nftban stats) ---
        # Check for feed data files in /var/lib/nftban/feeds/ (primary) or /var/cache/nftban/feeds/
        # Per-feed details: name, IP count, IPv4/IPv6 breakdown
        local feeds_json="["  # JSON array for Zabbix LLD/discovery
        local feeds_json_first=1
        if should_collect_component "feeds"; then
            local feeds_data_dir="${NFTBAN_DATA_DIR}/feeds"
            [[ ! -d "$feeds_data_dir" ]] && feeds_data_dir="${NFTBAN_CACHE_DIR}/feeds"

            if [[ -d "$feeds_data_dir" ]]; then
                for feed_file in "$feeds_data_dir"/*.txt "$feeds_data_dir"/*.list; do
                    [[ -f "$feed_file" ]] || continue
                    ((feeds_enabled++)) || true  # Prevent set -e failure when var starts at 0
                    ((feeds_loaded++)) || true
                    local total_count v4_count v6_count
                    total_count=$(wc -l < "$feed_file" 2>/dev/null || echo "0")
                    v4_count=$(grep -cE '^[0-9]+\.' "$feed_file" 2>/dev/null) || v4_count=0
                    v6_count=$(grep -cE '^[0-9a-fA-F]*:' "$feed_file" 2>/dev/null) || v6_count=0
                    feeds_ips=$((feeds_ips + total_count))
                    feeds_ipv4_total=$((feeds_ipv4_total + v4_count))
                    feeds_ipv6_total=$((feeds_ipv6_total + v6_count))

                    # Extract feed name from filename (e.g., sshblacklist.txt -> sshblacklist)
                    local feed_name
                    feed_name=$(basename "$feed_file" | sed 's/\.\(txt\|list\)$//')
                    # Per-feed Prometheus metrics
                    metrics+="nftban_feed_ips{name=\"$feed_name\"} $total_count $timestamp\n"
                    metrics+="nftban_feed_ipv4{name=\"$feed_name\"} $v4_count $timestamp\n"
                    metrics+="nftban_feed_ipv6{name=\"$feed_name\"} $v6_count $timestamp\n"
                    # Build JSON for Zabbix discovery
                    [[ $feeds_json_first -eq 0 ]] && feeds_json+=","
                    feeds_json_first=0
                    feeds_json+="{\"name\":\"$feed_name\",\"ips\":$total_count,\"ipv4\":$v4_count,\"ipv6\":$v6_count}"
                done
            fi
        fi
        feeds_json+="]"
        metrics+="nftban_feeds_enabled $feeds_enabled $timestamp\n"
        metrics+="nftban_feeds_loaded $feeds_loaded $timestamp\n"
        metrics+="nftban_feeds_failed $feeds_failed $timestamp\n"
        metrics+="nftban_feeds_ips_total $feeds_ips $timestamp\n"
        metrics+="nftban_feeds_ipv4_total $feeds_ipv4_total $timestamp\n"
        metrics+="nftban_feeds_ipv6_total $feeds_ipv6_total $timestamp\n"
        # Zabbix: JSON with all feeds for LLD/dashboard
        metrics+="nftban.feeds.details |STRING|$feeds_json $timestamp\n"

        # --- Time-based ban stats (from log) ---
        # Format: DATE|TIME|SOURCE|IP|COUNTRY|STATUS|REASON
        local bans_log="${NFTBAN_LOG_DIR}/bans.log"
        if [[ -f "$bans_log" ]]; then
            # Single awk pass for time windows, source breakdown, reason breakdown, AND unique IPs
            local stats
            stats=$(awk -F'|' -v now="$timestamp" '
                BEGIN {
                    # Time window counters
                    h1=0; h24=0; d7=0; d30=0; m5=0; total=0
                    # Source counters (all time)
                    src_login=0; src_portscan=0; src_ddos=0
                    src_manual=0; src_feeds=0; src_suricata=0
                    # Source counters (24h)
                    src_login_24h=0; src_portscan_24h=0; src_ddos_24h=0
                    src_manual_24h=0; src_feeds_24h=0; src_suricata_24h=0
                    # Reason counters (24h) - common SSH reasons
                    rsn_ssh_invalid_user=0; rsn_ssh_preauth_disconnect=0
                    rsn_ssh_auth_failure=0; rsn_module_ban=0; rsn_other=0
                }
                {
                    # Parse date to epoch (DATE|TIME format)
                    if ($1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) {
                        # New format: 2026-01-25|14:30:45|source|ip|country|status|reason
                        # Pure awk: convert "YYYY-MM-DD" "HH:MM:SS" to epoch via mktime()
                        split($1, d, "-")
                        split($2, t, ":")
                        epoch = mktime(d[1] " " d[2] " " d[3] " " t[1] " " t[2] " " t[3])
                        source = $3
                        ip = $4
                        status = $6
                        reason = $7
                    } else if ($1 ~ /^[0-9]+$/) {
                        # Old format: epoch timestamp
                        epoch = $1
                        source = $2
                        ip = $3
                        status = "BANNED"
                        reason = ""
                    } else {
                        next
                    }

                    # Only count BANNED entries
                    if (status != "BANNED") next

                    age = now - epoch
                    if (age < 0) next  # Future timestamps

                    # Time windows
                    if (age <= 300)     m5++
                    if (age <= 3600)    h1++
                    if (age <= 86400)   { h24++; unique_24h[ip]=1 }
                    if (age <= 604800)  d7++
                    if (age <= 2592000) d30++
                    total++
                    unique_all[ip]=1

                    # Source breakdown (all time)
                    if (source == "login")    src_login++
                    if (source == "portscan") src_portscan++
                    if (source == "ddos")     src_ddos++
                    if (source == "manual")   src_manual++
                    if (source == "feeds")    src_feeds++
                    if (source == "suricata") src_suricata++

                    # Source breakdown (24h)
                    if (age <= 86400) {
                        if (source == "login")    src_login_24h++
                        if (source == "portscan") src_portscan_24h++
                        if (source == "ddos")     src_ddos_24h++
                        if (source == "manual")   src_manual_24h++
                        if (source == "feeds")    src_feeds_24h++
                        if (source == "suricata") src_suricata_24h++

                        # Reason breakdown (24h only - for attack pattern analysis)
                        if (reason == "ssh_invalid_user")      rsn_ssh_invalid_user++
                        else if (reason == "ssh_preauth_disconnect") rsn_ssh_preauth_disconnect++
                        else if (reason == "ssh_auth_failure") rsn_ssh_auth_failure++
                        else if (reason == "module_ban")       rsn_module_ban++
                        else if (reason != "")                 rsn_other++
                    }
                }
                END {
                    # Output: time_stats | source_stats_total | source_stats_24h | unique_ips | reason_stats_24h
                    printf "%d %d %d %d %d %d ", m5, h1, h24, d7, d30, total
                    printf "%d %d %d %d %d %d ", src_login, src_portscan, src_ddos, src_manual, src_feeds, src_suricata
                    printf "%d %d %d %d %d %d ", src_login_24h, src_portscan_24h, src_ddos_24h, src_manual_24h, src_feeds_24h, src_suricata_24h
                    printf "%d %d ", length(unique_24h), length(unique_all)
                    printf "%d %d %d %d %d\n", rsn_ssh_invalid_user, rsn_ssh_preauth_disconnect, rsn_ssh_auth_failure, rsn_module_ban, rsn_other
                }
            ' "$bans_log" 2>/dev/null || echo "0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0")

            # Parse all stats (including reason breakdown)
            read -r bans_5m bans_1h bans_24h bans_7d bans_30d bans_total \
                     src_login src_portscan src_ddos src_manual src_feeds src_suricata \
                     src_login_24h src_portscan_24h src_ddos_24h src_manual_24h src_feeds_24h src_suricata_24h \
                     unique_ips_24h unique_ips_total \
                     rsn_ssh_invalid_user rsn_ssh_preauth_disconnect rsn_ssh_auth_failure rsn_module_ban rsn_other \
                     <<< "$stats"

            local rate
            rate=$(echo "scale=2; $bans_5m / 5" | bc 2>/dev/null || echo "0")

            # Time window metrics
            metrics+="nftban_bans_last_1h $bans_1h $timestamp\n"
            metrics+="nftban_bans_last_24h $bans_24h $timestamp\n"
            metrics+="nftban_bans_7d $bans_7d $timestamp\n"
            metrics+="nftban_bans_30d $bans_30d $timestamp\n"
            metrics+="nftban_bans_total $bans_total $timestamp\n"
            metrics+="nftban_throughput_bans_per_minute $rate $timestamp\n"

            # Bans by source (total)
            metrics+="nftban_bans_by_source{source=\"login\"} $src_login $timestamp\n"
            metrics+="nftban_bans_by_source{source=\"portscan\"} $src_portscan $timestamp\n"
            metrics+="nftban_bans_by_source{source=\"ddos\"} $src_ddos $timestamp\n"
            metrics+="nftban_bans_by_source{source=\"manual\"} $src_manual $timestamp\n"
            metrics+="nftban_bans_by_source{source=\"feeds\"} $src_feeds $timestamp\n"
            metrics+="nftban_bans_by_source{source=\"suricata\"} $src_suricata $timestamp\n"

            # Bans by source (24h) - for trend analysis
            metrics+="nftban_bans_by_source_24h{source=\"login\"} $src_login_24h $timestamp\n"
            metrics+="nftban_bans_by_source_24h{source=\"portscan\"} $src_portscan_24h $timestamp\n"
            metrics+="nftban_bans_by_source_24h{source=\"ddos\"} $src_ddos_24h $timestamp\n"
            metrics+="nftban_bans_by_source_24h{source=\"manual\"} $src_manual_24h $timestamp\n"
            metrics+="nftban_bans_by_source_24h{source=\"feeds\"} $src_feeds_24h $timestamp\n"
            metrics+="nftban_bans_by_source_24h{source=\"suricata\"} $src_suricata_24h $timestamp\n"

            # Bans by reason (24h) - for attack pattern analysis
            # Common SSH ban reasons from nftband daemon
            metrics+="nftban_bans_by_reason_24h{reason=\"ssh_invalid_user\"} ${rsn_ssh_invalid_user:-0} $timestamp\n"
            metrics+="nftban_bans_by_reason_24h{reason=\"ssh_preauth_disconnect\"} ${rsn_ssh_preauth_disconnect:-0} $timestamp\n"
            metrics+="nftban_bans_by_reason_24h{reason=\"ssh_auth_failure\"} ${rsn_ssh_auth_failure:-0} $timestamp\n"
            metrics+="nftban_bans_by_reason_24h{reason=\"module_ban\"} ${rsn_module_ban:-0} $timestamp\n"
            metrics+="nftban_bans_by_reason_24h{reason=\"other\"} ${rsn_other:-0} $timestamp\n"

            # Unique IPs (aligned with nftban_stats.sh)
            metrics+="nftban_unique_ips_24h ${unique_ips_24h:-0} $timestamp\n"
            metrics+="nftban_unique_ips_total ${unique_ips_total:-0} $timestamp\n"
        fi

        # --- Memory Metrics ---
        # Variables declared at function level for JSON cache access
        local goroutines=0
        if [[ -n "$pid" ]] && [[ "$pid" != "0" ]] && [[ -d "/proc/$pid" ]]; then
            rss=$(awk '/VmRSS/ {print $2 * 1024}' "/proc/$pid/status" 2>/dev/null || echo "0")
            fds=$(ls -1 "/proc/$pid/fd" 2>/dev/null | wc -l || echo "0")
            threads=$(awk '/Threads/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo "0")

            metrics+="nftban_memory_rss_bytes $rss $timestamp\n"
            metrics+="nftban_open_fds $fds $timestamp\n"
            metrics+="nftban_threads $threads $timestamp\n"

            # Daemon CPU and Memory percentage (from ps)
            local daemon_cpu_pct=0 daemon_mem_pct=0 daemon_vsz=0
            local ps_output
            ps_output=$(ps -p "$pid" -o %cpu,%mem,vsz --no-headers 2>/dev/null || echo "0 0 0")
            if [[ -n "$ps_output" ]]; then
                daemon_cpu_pct=$(echo "$ps_output" | awk '{print $1}')
                daemon_mem_pct=$(echo "$ps_output" | awk '{print $2}')
                daemon_vsz=$(echo "$ps_output" | awk '{print $3 * 1024}')  # VSZ in bytes
            fi
            metrics+="nftban.daemon.cpu_percent $daemon_cpu_pct $timestamp\n"
            metrics+="nftban.daemon.mem_percent $daemon_mem_pct $timestamp\n"
            metrics+="nftban.daemon.vsz_bytes $daemon_vsz $timestamp\n"

            # Goroutines (for Go-based daemon)
            # Try to read from daemon stats file first, then estimate from threads
            local daemon_stats="${NFTBAN_RUN_DIR}/nftband.stats"
            if [[ -f "$daemon_stats" ]]; then
                goroutines=$(jq -r '.goroutines // 0' "$daemon_stats" 2>/dev/null || echo "0")
            fi
            # Fallback: use thread count as approximation if goroutines not available
            [[ "$goroutines" == "0" || -z "$goroutines" ]] && goroutines=$threads
            metrics+="nftban_goroutines $goroutines $timestamp\n"

            # --- Memory Leak Detection Metrics ---
            # Calculate memory growth rate (MB/hour) for leak detection
            local uptime_sec growth_rate_mb_h baseline_mb=15 memory_pressure=0
            uptime_sec=$(ps -p "$pid" -o etimes= 2>/dev/null | tr -d ' ' || echo "0")
            if [[ $uptime_sec -gt 3600 ]]; then
                local current_mb=$((rss / 1024 / 1024))
                local uptime_hours=$((uptime_sec / 3600))
                local growth_mb=$((current_mb - baseline_mb))
                [[ $growth_mb -lt 0 ]] && growth_mb=0
                growth_rate_mb_h=$((growth_mb / uptime_hours))
            else
                growth_rate_mb_h=0
            fi
            metrics+="nftban.daemon.memory_growth_rate $growth_rate_mb_h $timestamp\n"
            metrics+="nftban.daemon.uptime_seconds $uptime_sec $timestamp\n"

            # Cgroup memory pressure (cgroup v2)
            local pressure_file="/sys/fs/cgroup/system.slice/nftband.service/memory.pressure"
            if [[ -f "$pressure_file" ]]; then
                memory_pressure=$(awk '/^some/ {gsub(/avg10=/, ""); printf "%.0f", $2}' "$pressure_file" 2>/dev/null || echo "0")
            fi
            metrics+="nftban.daemon.memory_pressure $memory_pressure $timestamp\n"

            # Memory health status (0=ok, 1=warning, 2=critical)
            local memory_health=0
            local rss_mb=$((rss / 1024 / 1024))
            if [[ $rss_mb -gt 300 ]] || [[ $growth_rate_mb_h -gt 50 ]] || [[ $memory_pressure -gt 80 ]]; then
                memory_health=2  # critical
            elif [[ $rss_mb -gt 100 ]] || [[ $memory_pressure -gt 50 ]]; then
                memory_health=1  # warning
            fi
            metrics+="nftban.daemon.memory_health $memory_health $timestamp\n"
        fi

        # --- Event Bus Metrics (Phase 3) ---
        local eventbus_events_total=0
        local eventbus_events_ban=0 eventbus_events_unban=0 eventbus_events_login_fail=0
        local eventbus_events_ddos_detected=0 eventbus_events_portscan_detected=0
        local eventbus_events_suricata_alert=0 eventbus_events_feed_sync=0
        local eventbus_events_dropped_total=0
        local eventbus_queue_size=0
        local eventbus_handlers_total=0

        # Try to read from eventbus stats file first
        local eventbus_stats="${NFTBAN_RUN_DIR}/eventbus.stats"
        if [[ -f "$eventbus_stats" ]]; then
            # Read stats from eventbus.stats if available
            eventbus_events_total=$(jq -r '.events_total // 0' "$eventbus_stats" 2>/dev/null || echo "0")
            eventbus_events_ban=$(jq -r '.events_by_type.ban // 0' "$eventbus_stats" 2>/dev/null || echo "0")
            eventbus_events_unban=$(jq -r '.events_by_type.unban // 0' "$eventbus_stats" 2>/dev/null || echo "0")
            eventbus_events_login_fail=$(jq -r '.events_by_type.login_fail // 0' "$eventbus_stats" 2>/dev/null || echo "0")
            eventbus_events_ddos_detected=$(jq -r '.events_by_type.ddos_detected // 0' "$eventbus_stats" 2>/dev/null || echo "0")
            eventbus_events_portscan_detected=$(jq -r '.events_by_type.portscan_detected // 0' "$eventbus_stats" 2>/dev/null || echo "0")
            eventbus_events_suricata_alert=$(jq -r '.events_by_type.suricata_alert // 0' "$eventbus_stats" 2>/dev/null || echo "0")
            eventbus_events_feed_sync=$(jq -r '.events_by_type.feed_sync // 0' "$eventbus_stats" 2>/dev/null || echo "0")
            eventbus_events_dropped_total=$(jq -r '.events_dropped_total // 0' "$eventbus_stats" 2>/dev/null || echo "0")
            eventbus_queue_size=$(jq -r '.queue_size // 0' "$eventbus_stats" 2>/dev/null || echo "0")
            eventbus_handlers_total=$(jq -r '.handlers_total // 0' "$eventbus_stats" 2>/dev/null || echo "0")
        else
            # Fallback: derive event counts from ban log
            if [[ -f "$bans_log" ]]; then
                # Count BANNED entries as ban events, UNBANNED as unban events
                eventbus_events_ban=$(grep -c "|BANNED|" "$bans_log" 2>/dev/null) || eventbus_events_ban=0
                eventbus_events_unban=$(grep -c "|UNBANNED|" "$bans_log" 2>/dev/null) || eventbus_events_unban=0
                # Estimate total events from ban activity
                eventbus_events_total=$((eventbus_events_ban + eventbus_events_unban))
            fi

            # Fallback: check queue files for queue size
            local queue_total=0
            for queue_file in "${NFTBAN_RUN_DIR}"/*.queue; do
                [[ -f "$queue_file" ]] || continue
                local queue_count
                queue_count=$(wc -l < "$queue_file" 2>/dev/null | tr -d '[:space:]')
                [[ -z "$queue_count" || ! "$queue_count" =~ ^[0-9]+$ ]] && queue_count=0
                queue_total=$((queue_total + queue_count))
            done
            eventbus_queue_size=$queue_total
        fi

        # Export Event Bus metrics
        metrics+="nftban_eventbus_events_total $eventbus_events_total $timestamp\n"
        metrics+="nftban_eventbus_events_by_type{type=\"ban\"} $eventbus_events_ban $timestamp\n"
        metrics+="nftban_eventbus_events_by_type{type=\"unban\"} $eventbus_events_unban $timestamp\n"
        metrics+="nftban_eventbus_events_by_type{type=\"login_fail\"} $eventbus_events_login_fail $timestamp\n"
        metrics+="nftban_eventbus_events_by_type{type=\"ddos_detected\"} $eventbus_events_ddos_detected $timestamp\n"
        metrics+="nftban_eventbus_events_by_type{type=\"portscan_detected\"} $eventbus_events_portscan_detected $timestamp\n"
        metrics+="nftban_eventbus_events_by_type{type=\"suricata_alert\"} $eventbus_events_suricata_alert $timestamp\n"
        metrics+="nftban_eventbus_events_by_type{type=\"feed_sync\"} $eventbus_events_feed_sync $timestamp\n"
        metrics+="nftban_eventbus_events_dropped_total $eventbus_events_dropped_total $timestamp\n"
        metrics+="nftban_eventbus_queue_size $eventbus_queue_size $timestamp\n"
        metrics+="nftban_eventbus_handlers_total $eventbus_handlers_total $timestamp\n"

        # --- nftables Performance Metrics (Phase 3) ---
        # Rule application latency, error tracking, and detailed set/rule metrics
        if command -v nft &>/dev/null; then
            # nftban_nftables_apply_latency_ms - rule application latency in milliseconds
            local nft_apply_latency=0
            local latency_file="${NFTBAN_CACHE_DIR}/stats/sync_latency"
            if [[ -f "$latency_file" ]]; then
                nft_apply_latency=$(cat "$latency_file" 2>/dev/null || echo "0")
                # Ensure it's a valid number
                [[ ! "$nft_apply_latency" =~ ^[0-9]+(\.[0-9]+)?$ ]] && nft_apply_latency=0
            fi
            metrics+="nftban_nftables_apply_latency_ms $nft_apply_latency $timestamp\n"

            # nftban_nftables_apply_errors_total - count nft errors from log
            local nft_apply_errors=0
            local nftban_log="${NFTBAN_LOG_DIR}/nftban.log"
            if [[ -f "$nftban_log" ]]; then
                # Count lines containing nft command errors (case-insensitive)
                nft_apply_errors=$(grep -ciE '(nft.*error|nft.*failed|nft:.*Error)' "$nftban_log" 2>/dev/null) || nft_apply_errors=0
            fi
            metrics+="nftban_nftables_apply_errors_total $nft_apply_errors $timestamp\n"

            # nftban_nftables_rules_total - count rules in nftban table
            local nft_rules_total=0
            local table_output
            table_output=$(nft list table ${NFTBAN_TABLE_IPV4} 2>/dev/null || echo "")
            if [[ -n "$table_output" ]]; then
                # Count lines that look like rules (contain accept, drop, jump, counter, etc.)
                nft_rules_total=$(echo "$table_output" | grep -cE '^\s+(accept|drop|reject|jump|goto|counter|log|limit|ct )' 2>/dev/null | tr -d '[:space:]') || true
                [[ -z "$nft_rules_total" || ! "$nft_rules_total" =~ ^[0-9]+$ ]] && nft_rules_total=0
            fi
            metrics+="nftban_nftables_rules_total $nft_rules_total $timestamp\n"

            # nftban_nftables_sets_total - count sets in nftban table
            local nft_sets_total=0
            if [[ -n "$table_output" ]]; then
                nft_sets_total=$(echo "$table_output" | grep -c "^\s*set " 2>/dev/null | tr -d '[:space:]') || true
                [[ -z "$nft_sets_total" || ! "$nft_sets_total" =~ ^[0-9]+$ ]] && nft_sets_total=0
            fi
            metrics+="nftban_nftables_sets_total $nft_sets_total $timestamp\n"

            # nftban_nftables_set_elements - element count per set with set label
            # v1.32.0: Use cached counting (0 kernel calls) with kernel fallback
            for set_name in blacklist_ipv4 whitelist_ipv4 blacklist_ipv6 whitelist_ipv6; do
                local set_elem_count=0
                if declare -f nftban_nft_count_set_cached >/dev/null 2>&1; then
                    set_elem_count=$(nftban_nft_count_set_cached "$set_name" 2>/dev/null) || true
                else
                    local _fam="ip"
                    [[ "$set_name" == *"_ipv6" ]] && _fam="ip6"
                    set_elem_count=$(nft -j list set "$_fam" nftban "$set_name" 2>/dev/null | jq -r '.nftables[]?.set?.elem // [] | length' 2>/dev/null) || true
                fi
                [[ -z "$set_elem_count" || ! "$set_elem_count" =~ ^[0-9]+$ ]] && set_elem_count=0
                metrics+="nftban_nftables_set_elements{set=\"${set_name}\"} $set_elem_count $timestamp\n"
            done

            # v1.32.0: Scale-level metrics from daemon cache (0 kernel calls)
            local _scale_cache="/run/nftban/set_counts.json"
            if [[ -f "$_scale_cache" ]] && command -v jq &>/dev/null; then
                local _scale_age
                _scale_age=$(( $(date +%s) - $(stat -c %Y "$_scale_cache" 2>/dev/null || echo 0) ))
                if [[ "$_scale_age" -lt 120 ]]; then
                    # Per-set scale level (numeric: 0=NORMAL, 1=LARGE, ..., 5=CRITICAL_SCALE)
                    while IFS=$'\t' read -r _sname _snum; do
                        [[ -n "$_sname" ]] && metrics+="nftban_set_scale_level{set=\"${_sname}\"} $_snum $timestamp\n"
                    done < <(jq -r '.sets | to_entries[] | [.key, (.value.scale_num | tostring)] | @tsv' "$_scale_cache" 2>/dev/null)

                    # Global scale mode (numeric)
                    local _global_scale
                    _global_scale=$(jq -r '.scale_mode // "NORMAL"' "$_scale_cache" 2>/dev/null)
                    local _global_num=0
                    case "$_global_scale" in
                        LARGE) _global_num=1 ;; VERY_LARGE) _global_num=2 ;; HUGE) _global_num=3 ;;
                        EXTREME) _global_num=4 ;; CRITICAL_SCALE) _global_num=5 ;;
                    esac
                    metrics+="nftban_global_scale_level $_global_num $timestamp\n"
                    metrics+="nftban_scale_cache_age_seconds $_scale_age $timestamp\n"
                fi
            fi

            # nftban_nftables_commands_total - total nft commands executed
            local nft_commands_total=0
            local commands_file="${NFTBAN_CACHE_DIR}/stats/nft_commands_total"
            if [[ -f "$commands_file" ]]; then
                nft_commands_total=$(cat "$commands_file" 2>/dev/null || echo "0")
                [[ ! "$nft_commands_total" =~ ^[0-9]+$ ]] && nft_commands_total=0
            else
                # Fallback: count nft commands from log
                if [[ -f "$nftban_log" ]]; then
                    nft_commands_total=$(grep -ciE '(nft add|nft delete|nft flush|nft list)' "$nftban_log" 2>/dev/null) || nft_commands_total=0
                    [[ -z "$nft_commands_total" || ! "$nft_commands_total" =~ ^[0-9]+$ ]] && nft_commands_total=0
                fi
            fi
            metrics+="nftban_nftables_commands_total $nft_commands_total $timestamp\n"
        fi

    fi  # end LIVE group

    # =========================================================================
    # EXTENDED METRICS (every 5 runs - 5min)
    # =========================================================================
    # Module status variables (declared at function level for JSON cache)
    local mod_enabled=0 mod_active=0 mod_failed=0
    local module_login_status=0 module_portscan_status=0 module_ddos_status=0
    local module_suricata_status=0 module_feeds_status=0 module_geoban_status=0
    local module_watchdog_status=0 module_botguard_status=0
    # Feed health variables
    local feeds_sync_errors=0 feeds_stale_count=0
    # GeoBan variables
    local geoban_countries_blocked=0
    # Server metrics variables (declared at function level for JSON cache)
    local cpu_cores=1 memory_total=0 memory_available=0 memory_used_pct=0
    local server_uptime=0 disk_total=0 disk_used=0 disk_used_pct=0
    # Sets/elements totals
    local sets_count=0 elements_total=0

    if group_active "extended"; then

        # --- Module Status Metrics ---
        for module in login portscan ddos feeds geoban suricata rbl botscan; do
            if [[ -f "${NFTBAN_CONFIG_DIR}/modules/${module}.conf" ]]; then
                # v1.19.20 FIX
                ((mod_enabled++)) || true
                if systemctl is-active "nftban-${module}.timer" &>/dev/null 2>&1; then
                    # v1.19.20 FIX
                    ((mod_active++)) || true
                elif systemctl is-failed "nftban-${module}.service" &>/dev/null 2>&1; then
                    # v1.19.20 FIX
                    ((mod_failed++)) || true
                fi
            fi
        done

        metrics+="nftban_modules_enabled $mod_enabled $timestamp\n"
        metrics+="nftban_modules_active $mod_active $timestamp\n"
        metrics+="nftban_modules_failed $mod_failed $timestamp\n"

        # --- Individual Module Status Metrics ---
        # Status values: 1=active, 0=disabled, -1=failed
        # Checks: config exists, timer/service active, service failed
        for module in login portscan ddos suricata feeds geoban watchdog; do
            local status_val=0
            local config_file="${NFTBAN_CONFIG_DIR}/modules/${module}.conf"

            if [[ -f "$config_file" ]]; then
                # Config exists, check if service/timer is active or failed
                if systemctl is-active "nftban-${module}.timer" &>/dev/null 2>&1 || \
                   systemctl is-active "nftban-${module}.service" &>/dev/null 2>&1; then
                    status_val=1  # active
                elif systemctl is-failed "nftban-${module}.service" &>/dev/null 2>&1; then
                    status_val=-1  # failed
                fi
                # else remains 0 (disabled - config exists but not running)
            fi
            # If config doesnt exist, status remains 0 (disabled)

            # Assign to individual variables for JSON cache
            case "$module" in
                login)    module_login_status=$status_val ;;
                portscan) module_portscan_status=$status_val ;;
                ddos)     module_ddos_status=$status_val ;;
                suricata) module_suricata_status=$status_val ;;
                feeds)    module_feeds_status=$status_val ;;
                geoban)   module_geoban_status=$status_val ;;
                watchdog) module_watchdog_status=$status_val ;;
            esac

            metrics+="nftban_module_${module}_status $status_val $timestamp\n"
        done

        # Botguard module status (uses conf.d config, not modules/ config)
        local botguard_status_val=0
        local botguard_conf="${NFTBAN_CONFIG_DIR}/conf.d/botguard/main.conf"
        if [[ -f "$botguard_conf" ]]; then
            local bg_enabled
            bg_enabled=$(grep -m1 "^HTTP_BOTGUARD_ENABLED=" "$botguard_conf" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || true)
            # Check .local override
            if [[ -f "${botguard_conf}.local" ]]; then
                local bg_local
                bg_local=$(grep -m1 "^HTTP_BOTGUARD_ENABLED=" "${botguard_conf}.local" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || true)
                [[ -n "$bg_local" ]] && bg_enabled="$bg_local"
            fi
            if [[ "$bg_enabled" == "true" ]]; then
                # Check if daemon is running (botguard runs inside nftband)
                if systemctl is-active nftband &>/dev/null 2>&1; then
                    botguard_status_val=1  # active
                else
                    botguard_status_val=-1  # enabled but daemon not running
                fi
            fi
        fi
        module_botguard_status=$botguard_status_val
        metrics+="nftban_module_botguard_status $botguard_status_val $timestamp\n"


        # --- nftables Extended Metrics (EXTENDED only - sets total, elements total) ---
        # Note: Core whitelist/blacklist counts moved to LIVE group for real-time consistency
        if command -v nft &>/dev/null; then
            # Count sets per family (nft list sets FAMILY, not "nft list sets FAMILY TABLE")
            local ipv4_family="${NFTBAN_TABLE_IPV4%% *}"  # "ip" from "ip nftban"
            local ipv6_family="${NFTBAN_TABLE_IPV6%% *}"  # "ip6" from "ip6 nftban"
            sets_count=$(( $(nft list sets "$ipv4_family" 2>/dev/null | grep -c "set " || echo 0) + $(nft list sets "$ipv6_family" 2>/dev/null | grep -c "set " || echo 0) ))
            # Total elements across all standard sets (use function-level whitelist_v4/v6 from LIVE)
            elements_total=$((${active_v4:-0} + ${active_v6:-0} + ${whitelist_v4:-0} + ${whitelist_v6:-0}))
            metrics+="nftban_nft_sets_total $sets_count $timestamp\n"
            metrics+="nftban_nft_elements_total $elements_total $timestamp\n"
        fi

        # --- Feed Health Metrics (Phase 1) ---
        # Note: Basic feeds metrics (enabled, loaded, ips_total) moved to LIVE group for real-time consistency
        # Sync errors: count [ERROR] or [FAIL] entries from last 24 hours in feeds.log
        local feeds_log="${NFTBAN_LOG_DIR}/feeds.log"
        if [[ -f "$feeds_log" ]]; then
            local cutoff_time=$((timestamp - 86400))
            # POSIX-compatible: count errors in last 24h using grep (mawk doesn't support {n} quantifiers)
            feeds_sync_errors=$(grep -cE '\[(ERROR|FAIL)\]' "$feeds_log" 2>/dev/null) || feeds_sync_errors=0
        fi
        metrics+="nftban_feeds_sync_errors_total $feeds_sync_errors $timestamp\n"

        # Stale feeds: count feeds with last_sync > 24 hours from .state files
        local feeds_state_dir="${NFTBAN_DATA_DIR:-/var/lib/nftban}/feeds"
        if [[ -d "$feeds_state_dir" ]]; then
            local cutoff_time=$((timestamp - 86400))
            for state_file in "$feeds_state_dir"/*.state; do
                [[ -f "$state_file" ]] || continue
                local last_sync
                last_sync=$(jq -r '.last_sync // 0' "$state_file" 2>/dev/null || echo "0")
                if [[ "$last_sync" =~ ^[0-9]+$ ]] && [[ $last_sync -gt 0 ]] && [[ $last_sync -lt $cutoff_time ]]; then
                    # v1.19.20 FIX
                    ((feeds_stale_count++)) || true
                fi
            done
        fi
        metrics+="nftban_feeds_stale_count $feeds_stale_count $timestamp\n"

        # --- GeoBan Metrics (count blocked countries) ---
        # Count by 50-ban-*.conf files in geoban.d directory
        local geoban_dir="${NFTBAN_CONFIG_DIR:-/etc/nftban}/geoban.d"
        if [[ -d "$geoban_dir" ]]; then
            geoban_countries_blocked=$(ls -1 "$geoban_dir"/50-ban-*.conf 2>/dev/null | wc -l) || geoban_countries_blocked=0
        fi
        metrics+="nftban_geoban_countries_blocked $geoban_countries_blocked $timestamp\n"

        # --- Watchdog Metrics (component: watchdog) ---
        if should_collect_component "watchdog"; then
            # Pressure scores from watchdog.status file
            if [[ -f "${NFTBAN_RUN_DIR}/watchdog.status" ]]; then
                if head -1 "${NFTBAN_RUN_DIR}/watchdog.status" | grep -q "^{"; then
                    local cpu_score mem_score io_score net_score watchdog_mode
                    cpu_score=$(jq -r '.cpu_score // 0' "${NFTBAN_RUN_DIR}/watchdog.status" 2>/dev/null || echo "0")
                    mem_score=$(jq -r '.mem_score // 0' "${NFTBAN_RUN_DIR}/watchdog.status" 2>/dev/null || echo "0")
                    io_score=$(jq -r '.io_score // 0' "${NFTBAN_RUN_DIR}/watchdog.status" 2>/dev/null || echo "0")
                    net_score=$(jq -r '.net_score // 0' "${NFTBAN_RUN_DIR}/watchdog.status" 2>/dev/null || echo "0")
                    watchdog_mode=$(jq -r '.mode // "NORMAL"' "${NFTBAN_RUN_DIR}/watchdog.status" 2>/dev/null || echo "NORMAL")

                    metrics+="nftban_watchdog_cpu_score $cpu_score $timestamp\n"
                    metrics+="nftban_watchdog_mem_score $mem_score $timestamp\n"
                    metrics+="nftban_watchdog_io_score $io_score $timestamp\n"
                    metrics+="nftban_watchdog_net_score $net_score $timestamp\n"
                    # Mode as numeric: 0=NORMAL, 1=DEGRADED, 2=SURVIVAL
                    local mode_num=0
                    case "$watchdog_mode" in
                        DEGRADED) mode_num=1 ;;
                        SURVIVAL) mode_num=2 ;;
                    esac
                    metrics+="nftban_watchdog_mode $mode_num $timestamp\n"
                fi
                metrics+="nftban_watchdog_up 1 $timestamp\n"
            else
                metrics+="nftban_watchdog_up 0 $timestamp\n"
            fi

            # Daemon runtime stats via IPC (heap, gc, ipc, throughput)
            # Only collect if daemon is running (socket exists)
            if [[ -S "${NFTBAN_RUN_DIR}/nftband.sock" ]]; then
                local daemon_stats_json
                daemon_stats_json=$(timeout 5 nftban watchdog stats --json 2>/dev/null) || daemon_stats_json=""

                if [[ -n "$daemon_stats_json" ]] && echo "$daemon_stats_json" | jq -e '.daemon' &>/dev/null; then
                    # Extract all values in single jq call for efficiency
                    local stats_values
                    stats_values=$(echo "$daemon_stats_json" | jq -r '[
                        .daemon.uptime_seconds // 0,
                        .runtime.memory_heap_mb // 0,
                        .runtime.memory_sys_mb // 0,
                        .runtime.goroutines // 0,
                        .runtime.gc_cycles // 0,
                        .runtime.gc_pause_ms // 0,
                        .throughput.bans_total // 0,
                        .throughput.unbans_total // 0,
                        .throughput.events_total // 0,
                        .throughput.bans_per_min // 0,
                        .ipc.requests_total // 0,
                        .ipc.avg_latency_ms // 0,
                        .ipc.errors_total // 0
                    ] | @tsv' 2>/dev/null) || stats_values=""

                    if [[ -n "$stats_values" ]]; then
                        local d_uptime d_heap d_sys d_goroutines d_gc_cycles d_gc_pause
                        local d_bans d_unbans d_events d_bans_min d_ipc_req d_ipc_lat d_ipc_err
                        IFS=$'\t' read -r d_uptime d_heap d_sys d_goroutines d_gc_cycles d_gc_pause \
                            d_bans d_unbans d_events d_bans_min d_ipc_req d_ipc_lat d_ipc_err <<< "$stats_values"

                        # Daemon runtime metrics
                        metrics+="nftban_daemon_uptime_seconds $d_uptime $timestamp\n"
                        metrics+="nftban_daemon_memory_heap_mb $d_heap $timestamp\n"
                        metrics+="nftban_daemon_memory_sys_mb $d_sys $timestamp\n"
                        metrics+="nftban_daemon_goroutines $d_goroutines $timestamp\n"
                        metrics+="nftban_daemon_gc_cycles_total $d_gc_cycles $timestamp\n"
                        metrics+="nftban_daemon_gc_pause_ms $d_gc_pause $timestamp\n"

                        # Throughput metrics
                        metrics+="nftban_daemon_bans_total $d_bans $timestamp\n"
                        metrics+="nftban_daemon_unbans_total $d_unbans $timestamp\n"
                        metrics+="nftban_daemon_events_total $d_events $timestamp\n"
                        metrics+="nftban_daemon_bans_per_minute $d_bans_min $timestamp\n"

                        # IPC metrics
                        metrics+="nftban_daemon_ipc_requests_total $d_ipc_req $timestamp\n"
                        metrics+="nftban_daemon_ipc_latency_avg_ms $d_ipc_lat $timestamp\n"
                        metrics+="nftban_daemon_ipc_errors_total $d_ipc_err $timestamp\n"
                    fi
                fi
            fi
        fi

        # --- Module Resource Metrics (ACTIVE modules only) ---
        # Timer modules: Read from systemd journal for last run stats
        # Embedded modules: Estimate from daemon CPU/memory using ban ratios

        # Timer modules: feeds, rbl
        # Read last run duration and exit status from systemd journal
        for timer_module in feeds rbl; do
            local timer_unit="nftban-${timer_module}"
            [[ "$timer_module" == "feeds" ]] && timer_unit="nftban-core-feeds"

            # Check if timer is active (only emit metrics for active modules)
            if systemctl is-active "${timer_unit}.timer" &>/dev/null 2>&1; then
                local run_duration=0 run_memory=0 run_status=0

                # Get last invocation stats from systemd (ExecMainExitTimestamp - ExecMainStartTimestamp)
                local start_ts end_ts
                start_ts=$(systemctl show "${timer_unit}.service" -p ExecMainStartTimestampMonotonic --value 2>/dev/null || echo "0")
                end_ts=$(systemctl show "${timer_unit}.service" -p ExecMainExitTimestampMonotonic --value 2>/dev/null || echo "0")
                if [[ "$start_ts" != "0" ]] && [[ "$end_ts" != "0" ]] && [[ "$end_ts" -gt "$start_ts" ]]; then
                    # Monotonic timestamps are in microseconds
                    run_duration=$(( (end_ts - start_ts) / 1000000 ))
                fi

                # Get exit status (0 = success)
                local exit_code
                exit_code=$(systemctl show "${timer_unit}.service" -p ExecMainStatus --value 2>/dev/null || echo "1")
                [[ "$exit_code" == "0" ]] && run_status=1

                # Memory: Get peak memory from systemd (MemoryPeak, requires systemd 250+)
                local mem_peak
                mem_peak=$(systemctl show "${timer_unit}.service" -p MemoryPeak --value 2>/dev/null || echo "")
                if [[ -n "$mem_peak" ]] && [[ "$mem_peak" != "[not set]" ]] && [[ "$mem_peak" =~ ^[0-9]+$ ]]; then
                    run_memory=$mem_peak
                fi

                metrics+="nftban_module_${timer_module}_last_run_duration_seconds $run_duration $timestamp\n"
                metrics+="nftban_module_${timer_module}_last_run_memory_bytes $run_memory $timestamp\n"
                metrics+="nftban_module_${timer_module}_last_run_status $run_status $timestamp\n"
            fi
        done

        # Embedded modules: portscan, ddos, geoban
        # These run within the daemon, estimate resource usage from daemon stats + ban ratios
        # Get daemon CPU/memory (recalculate for EXTENDED - pid is from LIVE group)
        local daemon_cpu=0 daemon_mem=0
        if [[ -n "$pid" ]] && [[ "$pid" != "0" ]] && [[ -d "/proc/$pid" ]]; then
            local ps_stats
            ps_stats=$(ps -p "$pid" -o %cpu,%mem --no-headers 2>/dev/null || echo "0 0")
            daemon_cpu=$(echo "$ps_stats" | awk '{print $1}')
            daemon_mem=$(echo "$ps_stats" | awk '{print $2}')
        fi

        # Calculate ban ratios from src_* variables (collected in LIVE group)
        # Total bans across embedded module sources (portscan, ddos, geoban uses feeds)
        # shellcheck disable=SC2034  # Reserved for future use
        local embedded_total=$((${src_portscan:-0} + ${src_ddos:-0}))
        local all_src_total=$((${src_login:-0} + ${src_portscan:-0} + ${src_ddos:-0} + ${src_feeds:-0} + ${src_suricata:-0}))

        # Estimate resource allocation per embedded module based on ban contribution
        # Note: geoban is static (feed-based), minimal CPU; portscan/ddos are dynamic
        for embed_module in portscan ddos geoban; do
            local mod_cpu=0 mod_mem=0

            # Check if module config exists (active)
            if [[ -f "${NFTBAN_CONFIG_DIR}/modules/${embed_module}.conf" ]] || \
               [[ "$embed_module" == "geoban" && -d "${NFTBAN_CONFIG_DIR}/geoban.d" ]]; then

                if [[ "$embed_module" == "geoban" ]]; then
                    # GeoBan is static (feed-based rules), estimate ~5% of daemon overhead
                    if [[ -d "${NFTBAN_CONFIG_DIR}/geoban.d" ]] && \
                       ls "${NFTBAN_CONFIG_DIR}/geoban.d"/50-ban-*.conf &>/dev/null 2>&1; then
                        mod_cpu=$(awk -v d="$daemon_cpu" 'BEGIN {printf "%.2f", d * 0.05}')
                        mod_mem=$(awk -v d="$daemon_mem" 'BEGIN {printf "%.2f", d * 0.05}')
                    fi
                elif [[ $all_src_total -gt 0 ]]; then
                    # Estimate based on ban ratio
                    local mod_bans=0
                    [[ "$embed_module" == "portscan" ]] && mod_bans=${src_portscan:-0}
                    [[ "$embed_module" == "ddos" ]] && mod_bans=${src_ddos:-0}

                    # Allocate proportional CPU/mem based on ban contribution
                    # Cap embedded modules at 80% of daemon resources (login-monitor takes rest)
                    mod_cpu=$(awk -v d="$daemon_cpu" -v b="$mod_bans" -v t="$all_src_total" \
                        'BEGIN {printf "%.2f", (t > 0) ? (d * 0.8 * b / t) : 0}')
                    mod_mem=$(awk -v d="$daemon_mem" -v b="$mod_bans" -v t="$all_src_total" \
                        'BEGIN {printf "%.2f", (t > 0) ? (d * 0.8 * b / t) : 0}')
                fi

                metrics+="nftban_module_${embed_module}_cpu_percent_estimated $mod_cpu $timestamp\n"
                metrics+="nftban_module_${embed_module}_memory_percent_estimated $mod_mem $timestamp\n"
            fi
        done

        # --- Kernel Softnet Metrics (component: kernel) ---
        # Softnet drops indicate packet processing pressure on CPU
        # Variables declared at function level for JSON cache access
        if should_collect_component "kernel"; then
            if [[ -f /proc/net/softnet_stat ]]; then
                # Column 2 (0-indexed: col 1) is dropped packets, values are in hex
                softnet_drops_total=$(awk '{sum += strtonum("0x" $2)} END {print sum}' /proc/net/softnet_stat 2>/dev/null || echo "0")
            fi
            metrics+="nftban_softnet_drops_total $softnet_drops_total $timestamp\n"

            # Calculate rate from previous value
            local softnet_state="${NFTBAN_RUN_DIR}/softnet_state.dat"
            if [[ -f "$softnet_state" ]]; then
                local prev_drops prev_ts
                read -r prev_drops prev_ts < "$softnet_state" 2>/dev/null || { prev_drops=0; prev_ts=$timestamp; }
                local drops_delta=$((softnet_drops_total - prev_drops))
                local time_delta=$((timestamp - prev_ts))
                [[ $drops_delta -lt 0 ]] && drops_delta=0  # Handle counter wrap
                if [[ $time_delta -gt 0 ]]; then
                    # Rate per minute = (drops_delta / time_delta) * 60
                    softnet_drops_rate=$(awk -v d="$drops_delta" -v t="$time_delta" 'BEGIN {printf "%.2f", (d/t)*60}')
                fi
            fi
            echo "$softnet_drops_total $timestamp" > "$softnet_state"
            metrics+="nftban_softnet_backlog_total $softnet_drops_rate $timestamp\n"
        fi

        # --- Server Load Metrics ---
        local load1 load5 load15
        if [[ -f /proc/loadavg ]]; then
            read -r load1 load5 load15 _ < /proc/loadavg
            metrics+="nftban.server.load_1m $load1 $timestamp\n"
            metrics+="nftban.server.load_5m $load5 $timestamp\n"
            metrics+="nftban.server.load_15m $load15 $timestamp\n"
        fi
        cpu_cores=$(nproc 2>/dev/null || echo "1")
        metrics+="nftban.server.cpu_cores $cpu_cores $timestamp\n"

        # --- Server Memory Metrics ---
        if [[ -f /proc/meminfo ]]; then
            memory_total=$(awk '/^MemTotal:/ {printf "%.0f", $2 * 1024}' /proc/meminfo 2>/dev/null || echo "0")
            memory_available=$(awk '/^MemAvailable:/ {printf "%.0f", $2 * 1024}' /proc/meminfo 2>/dev/null || echo "0")
            if [[ $memory_total -gt 0 ]]; then
                local memory_used=$((memory_total - memory_available))
                memory_used_pct=$(awk -v used="$memory_used" -v total="$memory_total" 'BEGIN {printf "%.2f", (used/total)*100}')
            fi
        fi
        metrics+="nftban.server.memory_total $memory_total $timestamp\n"
        metrics+="nftban.server.memory_available $memory_available $timestamp\n"
        metrics+="nftban.server.mem_used_percent $memory_used_pct $timestamp\n"

        # --- Server Uptime ---
        if [[ -f /proc/uptime ]]; then
            server_uptime=$(awk '{printf "%.0f", $1}' /proc/uptime 2>/dev/null || echo "0")
        fi
        metrics+="nftban.server.uptime $server_uptime $timestamp\n"

        # --- Server Disk Metrics (root filesystem) ---
        if command -v df &>/dev/null; then
            local df_output
            df_output=$(df -B1 / 2>/dev/null | tail -1 || echo "")
            if [[ -n "$df_output" ]]; then
                disk_total=$(echo "$df_output" | awk '{print $2}')
                disk_used=$(echo "$df_output" | awk '{print $3}')
                disk_used_pct=$(echo "$df_output" | awk '{gsub(/%/, "", $5); print $5}')
            fi
        fi
        metrics+="nftban.server.disk_total $disk_total $timestamp\n"
        metrics+="nftban.server.disk_used $disk_used $timestamp\n"
        metrics+="nftban.server.disk_used_percent $disk_used_pct $timestamp\n"

    fi  # end EXTENDED group

    # =========================================================================
    # INVENTORY METRICS (every 60 runs - 1 hour)
    # String metrics for Zabbix host inventory auto-population
    # =========================================================================
    # Server inventory variables (declared at function level for JSON cache)
    local server_hostname="" server_fqdn="" server_os="" server_os_release=""
    local server_kernel="" server_arch="" server_cpu_model="" server_type="physical"
    local server_vendor="" server_model="" server_serial=""
    local server_primary_ip="" server_mac="" server_subnet_mask="" server_networks=""
    local server_location="" nftban_version=""

    if group_active "inventory"; then

        # --- Server Inventory Metrics (for Zabbix host inventory auto-population) ---
        # Hostname and FQDN
        server_hostname=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "unknown")
        server_fqdn=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "unknown")
        metrics+="nftban_server_hostname_info{hostname=\"$server_hostname\"} 1 $timestamp\n"
        metrics+="nftban_server_fqdn_info{fqdn=\"$server_fqdn\"} 1 $timestamp\n"

        # OS information from /etc/os-release
        if [[ -f /etc/os-release ]]; then
            # PRETTY_NAME contains full name like "Fedora Linux 42 (Server Edition)"
            server_os=$(grep -E "^PRETTY_NAME=" /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo "")
            # NAME contains just "Fedora Linux"
            server_os_release=$(grep -E "^NAME=" /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo "")
        fi
        [[ -z "$server_os" ]] && server_os=$(uname -o 2>/dev/null || echo "Linux")
        [[ -z "$server_os_release" ]] && server_os_release=$(uname -o 2>/dev/null || echo "Linux")
        server_kernel=$(uname -r 2>/dev/null || echo "unknown")
        server_arch=$(uname -m 2>/dev/null || echo "unknown")
        metrics+="nftban_server_os_info{os=\"$server_os\"} 1 $timestamp\n"
        metrics+="nftban_server_os_release_info{release=\"$server_os_release\"} 1 $timestamp\n"
        metrics+="nftban_server_kernel_info{kernel=\"$server_kernel\"} 1 $timestamp\n"
        metrics+="nftban_server_arch_info{arch=\"$server_arch\"} 1 $timestamp\n"

        # CPU model name
        if [[ -f /proc/cpuinfo ]]; then
            server_cpu_model=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d':' -f2 | sed 's/^[ \t]*//' || echo "")
        fi
        [[ -z "$server_cpu_model" ]] && server_cpu_model=$(uname -p 2>/dev/null || echo "unknown")
        metrics+="nftban_server_cpu_model_info{model=\"$server_cpu_model\"} 1 $timestamp\n"

        # Server type detection (physical, vm, container)
        server_type="physical"
        if [[ -f /.dockerenv ]] || grep -q 'docker\|lxc\|containerd' /proc/1/cgroup 2>/dev/null; then
            server_type="container"
        elif [[ -d /proc/vz ]] || grep -qiE 'hypervisor|vmware|virtualbox|kvm|qemu|xen|microsoft' /proc/cpuinfo 2>/dev/null; then
            server_type="vm"
        elif command -v systemd-detect-virt &>/dev/null; then
            local virt
            virt=$(systemd-detect-virt 2>/dev/null || echo "none")
            [[ "$virt" != "none" ]] && server_type="vm"
        fi
        metrics+="nftban_server_type_info{type=\"$server_type\"} 1 $timestamp\n"

        # Hardware vendor and model (from DMI if available)
        if [[ -f /sys/class/dmi/id/sys_vendor ]]; then
            server_vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "")
        fi
        if [[ -f /sys/class/dmi/id/product_name ]]; then
            server_model=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "")
        fi
        if [[ -f /sys/class/dmi/id/product_serial ]]; then
            server_serial=$(cat /sys/class/dmi/id/product_serial 2>/dev/null || echo "")
        fi
        [[ -z "$server_vendor" ]] && server_vendor="Unknown"
        [[ -z "$server_model" ]] && server_model="Unknown"
        [[ -z "$server_serial" ]] && server_serial="N/A"
        metrics+="nftban_server_vendor_info{vendor=\"$server_vendor\"} 1 $timestamp\n"
        metrics+="nftban_server_model_info{model=\"$server_model\"} 1 $timestamp\n"
        metrics+="nftban_server_serial_info{serial=\"$server_serial\"} 1 $timestamp\n"

        # Network information (primary IP, MAC, subnet mask)
        # Get primary interface (default route)
        local primary_iface
        primary_iface=$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}' || echo "")
        if [[ -n "$primary_iface" ]]; then
            # Primary IP
            server_primary_ip=$(ip -4 addr show "$primary_iface" 2>/dev/null | awk '/inet / {print $2}' | cut -d'/' -f1 | head -1 || echo "")
            # Subnet mask (CIDR to dotted decimal)
            local cidr
            cidr=$(ip -4 addr show "$primary_iface" 2>/dev/null | awk '/inet / {print $2}' | cut -d'/' -f2 | head -1 || echo "24")
            case "$cidr" in
                8)  server_subnet_mask="255.0.0.0" ;;
                16) server_subnet_mask="255.255.0.0" ;;
                24) server_subnet_mask="255.255.255.0" ;;
                32) server_subnet_mask="255.255.255.255" ;;
                *)  server_subnet_mask="255.255.255.0" ;;  # Default fallback
            esac
            # MAC address
            server_mac=$(ip link show "$primary_iface" 2>/dev/null | awk '/link\/ether/ {print $2}' || echo "")
        fi
        [[ -z "$server_primary_ip" ]] && server_primary_ip="127.0.0.1"
        [[ -z "$server_mac" ]] && server_mac="00:00:00:00:00:00"

        # Collect all network interfaces with IPs
        server_networks=$(ip -4 addr 2>/dev/null | awk '/inet / {gsub(/\/.*/, "", $2); printf "%s:%s ", $NF, $2}' | sed 's/ $//' || echo "")
        [[ -z "$server_networks" ]] && server_networks="lo:127.0.0.1"

        metrics+="nftban_server_primary_ip_info{ip=\"$server_primary_ip\"} 1 $timestamp\n"
        metrics+="nftban_server_mac_info{mac=\"$server_mac\"} 1 $timestamp\n"
        metrics+="nftban_server_subnet_mask_info{mask=\"$server_subnet_mask\"} 1 $timestamp\n"
        metrics+="nftban_server_networks_info{networks=\"$server_networks\"} 1 $timestamp\n"

        # Location (from config or empty)
        server_location="${NFTBAN_SERVER_LOCATION:-}"
        [[ -z "$server_location" ]] && server_location="Not configured"
        metrics+="nftban_server_location_info{location=\"$server_location\"} 1 $timestamp\n"

        # NFTBan version
        nftban_version=$(cat "${NFTBAN_LIB_DIR}/VERSION" 2>/dev/null | head -1 || echo "unknown")
        metrics+="nftban_server_nftban_version_info{version=\"$nftban_version\"} 1 $timestamp\n"

        # NOTE: Memory, uptime, disk metrics moved to EXTENDED group (every 5 min)
        # See: "Server Load Metrics", "Server Memory Metrics", "Server Disk Metrics" in EXTENDED

        # --- Zabbix-compatible String Metrics ---
        # Zabbix trapper items expect the actual string value, not labels
        # These are formatted as: metric_name |STRING|value timestamp
        # The export_zabbix function handles the |STRING| marker specially
        # Using dot notation to match Zabbix template keys exactly
        metrics+="nftban.server.hostname |STRING|$server_hostname $timestamp\n"
        metrics+="nftban.server.fqdn |STRING|$server_fqdn $timestamp\n"
        metrics+="nftban.server.os |STRING|$server_os $timestamp\n"
        metrics+="nftban.server.os_release |STRING|$server_os_release $timestamp\n"
        metrics+="nftban.server.kernel |STRING|$server_kernel $timestamp\n"
        metrics+="nftban.server.arch |STRING|$server_arch $timestamp\n"
        metrics+="nftban.server.cpu_model |STRING|$server_cpu_model $timestamp\n"
        metrics+="nftban.server.type |STRING|$server_type $timestamp\n"
        metrics+="nftban.server.vendor |STRING|$server_vendor $timestamp\n"
        metrics+="nftban.server.model |STRING|$server_model $timestamp\n"
        metrics+="nftban.server.serial |STRING|$server_serial $timestamp\n"
        metrics+="nftban.server.primary_ip |STRING|$server_primary_ip $timestamp\n"
        metrics+="nftban.server.mac_address |STRING|$server_mac $timestamp\n"
        metrics+="nftban.server.subnet_mask |STRING|$server_subnet_mask $timestamp\n"
        metrics+="nftban.server.networks |STRING|$server_networks $timestamp\n"
        metrics+="nftban.server.location |STRING|$server_location $timestamp\n"
        metrics+="nftban.server.nftban_version |STRING|$nftban_version $timestamp\n"

        # --- Kernel Conntrack Metrics (component: kernel) ---
        # Variables declared at function level for JSON cache access
        if should_collect_component "kernel"; then
            if [[ -f /proc/sys/net/netfilter/nf_conntrack_count ]]; then
                conntrack_entries=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "0")
            fi
            if [[ -f /proc/sys/net/netfilter/nf_conntrack_max ]]; then
                conntrack_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo "0")
            fi
            if [[ $conntrack_max -gt 0 ]]; then
                conntrack_utilization=$(awk -v e="$conntrack_entries" -v m="$conntrack_max" 'BEGIN {printf "%.2f", (e/m)*100}')
            fi
            metrics+="nftban_conntrack_entries $conntrack_entries $timestamp\n"
            metrics+="nftban_conntrack_max $conntrack_max $timestamp\n"
            metrics+="nftban_conntrack_utilization $conntrack_utilization $timestamp\n"
        fi

    fi  # end INVENTORY group

    # =========================================================================
    # NETWORK METRICS (LIVE group, component: network)
    # =========================================================================
    if group_active "live" && should_collect_component "network"; then

        # --- Bandwidth Metrics ---
        # Variables declared at function level for JSON cache access
        mkdir -p "$(dirname "$BANDWIDTH_STATE")" || return 1

        # Get all physical interfaces (exclude lo, docker, veth, etc.)
        for iface_path in /sys/class/net/*; do
            [[ ! -d "$iface_path" ]] && continue
            local iface="${iface_path##*/}"
            # Skip virtual interfaces
            [[ "$iface" =~ ^(lo|docker[0-9]*|veth.*|br-.*|virbr.*)$ ]] && continue
            local stats
            stats=$(get_interface_stats "$iface") || continue
        local rx_bytes rx_packets rx_errs rx_drop tx_bytes tx_packets tx_errs tx_drop
        read -r rx_bytes rx_packets rx_errs rx_drop tx_bytes tx_packets tx_errs tx_drop <<< "$stats"

        # Per-interface metrics
        metrics+="nftban_network_rx_bytes{interface=\"${iface}\"} $rx_bytes $timestamp\n"
        metrics+="nftban_network_tx_bytes{interface=\"${iface}\"} $tx_bytes $timestamp\n"
        metrics+="nftban_network_rx_packets{interface=\"${iface}\"} $rx_packets $timestamp\n"
        metrics+="nftban_network_tx_packets{interface=\"${iface}\"} $tx_packets $timestamp\n"
        metrics+="nftban_network_rx_errors{interface=\"${iface}\"} $rx_errs $timestamp\n"
        metrics+="nftban_network_tx_errors{interface=\"${iface}\"} $tx_errs $timestamp\n"
        metrics+="nftban_network_rx_dropped{interface=\"${iface}\"} $rx_drop $timestamp\n"
        metrics+="nftban_network_tx_dropped{interface=\"${iface}\"} $tx_drop $timestamp\n"

        # Accumulate totals for Zabbix compatibility
        total_rx_bytes=$((total_rx_bytes + rx_bytes))
        total_tx_bytes=$((total_tx_bytes + tx_bytes))
        total_rx_packets=$((total_rx_packets + rx_packets))
        total_tx_packets=$((total_tx_packets + tx_packets))
        total_rx_errors=$((total_rx_errors + rx_errs))
        total_tx_errors=$((total_tx_errors + tx_errs))
        total_rx_dropped=$((total_rx_dropped + rx_drop))
        total_tx_dropped=$((total_tx_dropped + tx_drop))

        # Calculate Mbps from previous state
        if [[ -f "$BANDWIDTH_STATE" ]]; then
            local prev_data prev_ts prev_rx prev_tx
            prev_data=$(grep "^${iface} " "$BANDWIDTH_STATE" 2>/dev/null || echo "")
            if [[ -n "$prev_data" ]]; then
                read -r _ prev_rx prev_tx prev_ts <<< "$prev_data"
                local rx_delta=$((rx_bytes - prev_rx))
                local tx_delta=$((tx_bytes - prev_tx))
                local time_delta=$((timestamp - prev_ts))
                [[ $rx_delta -lt 0 ]] && rx_delta=0  # Handle counter wrap
                [[ $tx_delta -lt 0 ]] && tx_delta=0
                local rx_mbps tx_mbps
                rx_mbps=$(calculate_mbps $rx_delta $time_delta)
                tx_mbps=$(calculate_mbps $tx_delta $time_delta)
                metrics+="nftban_network_rx_mbps{interface=\"${iface}\"} $rx_mbps $timestamp\n"
                metrics+="nftban_network_tx_mbps{interface=\"${iface}\"} $tx_mbps $timestamp\n"
                total_rx_mbps=$(echo "$total_rx_mbps + $rx_mbps" | bc -l 2>/dev/null || echo "$total_rx_mbps")
                total_tx_mbps=$(echo "$total_tx_mbps + $tx_mbps" | bc -l 2>/dev/null || echo "$total_tx_mbps")
            fi
        fi

        # Update state file (append/replace for this interface)
        grep -v "^${iface} " "$BANDWIDTH_STATE" 2>/dev/null > "${BANDWIDTH_STATE}.tmp" || true
        echo "${iface} ${rx_bytes} ${tx_bytes} ${timestamp}" >> "${BANDWIDTH_STATE}.tmp"
        mv "${BANDWIDTH_STATE}.tmp" "$BANDWIDTH_STATE"
    done

    # Total bandwidth and peaks
    metrics+="nftban_network_total_rx_mbps $total_rx_mbps $timestamp\n"
    metrics+="nftban_network_total_tx_mbps $total_tx_mbps $timestamp\n"

    local peaks
    peaks=$(update_bandwidth_peaks "$total_rx_mbps" "$total_tx_mbps" "$timestamp")
    read -r peak_rx peak_tx <<< "$peaks"
    metrics+="nftban_bandwidth_peak_rx_mbps $peak_rx $timestamp\n"
    metrics+="nftban_bandwidth_peak_tx_mbps $peak_tx $timestamp\n"

    # -------------------------------------------------------------------------
    # NETWORK TOTALS (Zabbix-compatible aggregated counters)
    # These metrics align with Zabbix template keys:
    #   nftban.network.bytes_in, nftban.network.bytes_out
    #   nftban.network.packets_in, nftban.network.packets_out
    #   nftban.network.errors, nftban.network.packets_dropped
    #   nftban.bandwidth.in, nftban.bandwidth.out
    # -------------------------------------------------------------------------
    # Total bytes (counters)
    metrics+="nftban_network_bytes_received_total $total_rx_bytes $timestamp\n"
    metrics+="nftban_network_bytes_sent_total $total_tx_bytes $timestamp\n"

    # Total packets (counters)
    metrics+="nftban_network_packets_received_total $total_rx_packets $timestamp\n"
    metrics+="nftban_network_packets_sent_total $total_tx_packets $timestamp\n"

    # Total errors (combined RX+TX errors)
    total_errors=$((total_rx_errors + total_tx_errors))
    metrics+="nftban_network_errors_total $total_errors $timestamp\n"

    # Total dropped packets (combined RX+TX dropped)
    total_dropped=$((total_rx_dropped + total_tx_dropped))
    metrics+="nftban_network_packets_dropped_total $total_dropped $timestamp\n"

    # Bandwidth rate in bits per second (for Zabbix nftban.bandwidth.in/out)
    # Convert Mbps to bps: Mbps * 1000000
    bandwidth_in_bps=$(awk -v m="$total_rx_mbps" 'BEGIN {printf "%.0f", m * 1000000}')
    bandwidth_out_bps=$(awk -v m="$total_tx_mbps" 'BEGIN {printf "%.0f", m * 1000000}')
    metrics+="nftban_bandwidth_in_bps $bandwidth_in_bps $timestamp\n"
    metrics+="nftban_bandwidth_out_bps $bandwidth_out_bps $timestamp\n"

        # --- Connection Metrics ---
        # Variables declared at function level for JSON cache access
        conn_active=$(get_connection_stats active)
        conn_established=$(get_connection_stats established)
        conn_time_wait=$(get_connection_stats time_wait)
        metrics+="nftban_connections_active $conn_active $timestamp\n"
        metrics+="nftban_connections_established $conn_established $timestamp\n"
        metrics+="nftban_connections_time_wait $conn_time_wait $timestamp\n"

    fi  # end NETWORK group (live + network component)

    # =========================================================================
    # GEOIP METRICS (INVENTORY group, component: geoip)
    # =========================================================================
    if group_active "inventory" && should_collect_component "geoip"; then
        # Find GeoIP database (DBIP or GeoLite2)
        local geoip_db=""
        for path in "${NFTBAN_CACHE_DIR}/geoip/dbip-country-lite.mmdb" \
                    "${NFTBAN_CACHE_DIR}/geoip/GeoLite2-Country.mmdb" \
                    "/var/lib/nftban/geoip/dbip-country-lite.mmdb" \
                    "/var/lib/nftban/geoip/GeoLite2-Country.mmdb"; do
            [[ -f "$path" ]] && { geoip_db="$path"; break; }
        done
        if [[ -n "$geoip_db" ]]; then
            local db_age_days
            db_age_days=$(( (timestamp - $(stat -c %Y "$geoip_db" 2>/dev/null || echo "$timestamp")) / 86400 ))
            metrics+="nftban_geoip_database_age_days $db_age_days $timestamp\n"
            metrics+="nftban_geoip_database_present 1 $timestamp\n"
        else
            metrics+="nftban_geoip_database_present 0 $timestamp\n"
        fi

        # Count blocked countries
        local countries_blocked=0
        if [[ -d "${NFTBAN_CONFIG_DIR}/geoban.d" ]]; then
            countries_blocked=$(ls -1 "${NFTBAN_CONFIG_DIR}/geoban.d/"50-ban-*.conf 2>/dev/null | wc -l) || countries_blocked=0
        fi
        metrics+="nftban_geoip_countries_blocked $countries_blocked $timestamp\n"
    fi  # end GEOIP group

    # =========================================================================
    # CACHE METRICS (Single Source of Truth)
    # =========================================================================
    mkdir -p "$(dirname "$METRICS_CACHE")" || return 1
    mkdir -p "${NFTBAN_JSON_CACHE_DIR:-/var/cache/nftban/metrics}" || return 1

    # 1. Raw metrics cache (for Prometheus/Zabbix export)
    echo -e "$metrics" > "$METRICS_CACHE"

    # 2. JSON cache (Single Source of Truth for nftban stats and API)
    # This structure EXACTLY matches what nftban_stats.sh dashboard needs
    local json_cache="${NFTBAN_JSON_CACHE_DIR:-/var/cache/nftban/metrics}/stats.json"
    local hostname
    hostname=$(hostname -f 2>/dev/null || hostname)

    # Build JSON from collected metrics - SINGLE SOURCE OF TRUTH
    # All fields align with nftban_stats.sh generate_dashboard() requirements
    cat > "${json_cache}.tmp" <<EOF
{
  "schema_version": "2.0",
  "generated_at": "$(date -Iseconds)",
  "generated_epoch": $timestamp,
  "hostname": "$hostname",
  "collection_groups": "$collection_groups",
  "run_count": $(cat "$RUN_COUNT_FILE" 2>/dev/null || echo 0),
  "daemon": {
    "status": $status,
    "pid": $pid,
    "uptime_seconds": $uptime
  },
  "blacklist": {
    "ipv4": {
      "total": ${active_v4:-0},
      "permanent": ${blacklist_v4_perm:-0},
      "temporary": ${blacklist_v4_temp:-0}
    },
    "ipv6": {
      "total": ${active_v6:-0},
      "permanent": ${blacklist_v6_perm:-0},
      "temporary": ${blacklist_v6_temp:-0}
    },
    "total": ${active_total:-0}
  },
  "whitelist": {
    "ipv4": ${whitelist_v4:-0},
    "ipv6": ${whitelist_v6:-0},
    "total": $((${whitelist_v4:-0} + ${whitelist_v6:-0}))
  },
  "feeds": {
    "enabled": ${feeds_enabled:-0},
    "loaded": ${feeds_loaded:-0},
    "failed": ${feeds_failed:-0},
    "ipv4_total": ${feeds_ipv4_total:-0},
    "ipv6_total": ${feeds_ipv6_total:-0},
    "ips_total": ${feeds_ips:-0}
  },
  "feed_health": {
    "sync_errors_total": ${feeds_sync_errors:-0},
    "stale_count": ${feeds_stale_count:-0}
  },
  "geoban": {
    "countries_blocked": ${geoban_countries_blocked:-0}
  },
  "bans_by_source": {
    "login": ${src_login:-0},
    "portscan": ${src_portscan:-0},
    "ddos": ${src_ddos:-0},
    "manual": ${src_manual:-0},
    "feeds": ${src_feeds:-0},
    "suricata": ${src_suricata:-0}
  },
  "bans_by_source_24h": {
    "login": ${src_login_24h:-0},
    "portscan": ${src_portscan_24h:-0},
    "ddos": ${src_ddos_24h:-0},
    "manual": ${src_manual_24h:-0},
    "feeds": ${src_feeds_24h:-0},
    "suricata": ${src_suricata_24h:-0}
  },
  "bans_by_reason_24h": {
    "ssh_invalid_user": ${rsn_ssh_invalid_user:-0},
    "ssh_preauth_disconnect": ${rsn_ssh_preauth_disconnect:-0},
    "ssh_auth_failure": ${rsn_ssh_auth_failure:-0},
    "module_ban": ${rsn_module_ban:-0},
    "other": ${rsn_other:-0}
  },
  "activity": {
    "total_bans": ${bans_total:-0},
    "unique_ips": ${unique_ips_total:-0},
    "unique_ips_24h": ${unique_ips_24h:-0},
    "bans_1h": ${bans_1h:-0},
    "bans_24h": ${bans_24h:-0},
    "bans_7d": ${bans_7d:-0},
    "bans_30d": ${bans_30d:-0},
    "rate_per_minute": ${rate:-0}
  },
  "firewall": {
    "sets_total": ${sets_count:-0},
    "elements_total": ${elements_total:-0}
  },
  "modules": {
    "enabled": ${mod_enabled:-0},
    "active": ${mod_active:-0},
    "failed": ${mod_failed:-0}
  },
  "module_status": {
    "login": ${module_login_status:-0},
    "portscan": ${module_portscan_status:-0},
    "ddos": ${module_ddos_status:-0},
    "suricata": ${module_suricata_status:-0},
    "feeds": ${module_feeds_status:-0},
    "geoban": ${module_geoban_status:-0},
    "watchdog": ${module_watchdog_status:-0},
    "botguard": ${module_botguard_status:-0}
  },
  "botguard": {
    "suspect": ${bg_suspect:-0},
    "pending": ${bg_pending:-0},
    "allow": ${bg_allow:-0},
    "grey": ${bg_grey:-0},
    "ban": ${bg_ban:-0},
    "emergency": ${bg_emergency:-0},
    "total_tracked": $((${bg_suspect:-0} + ${bg_pending:-0} + ${bg_allow:-0} + ${bg_grey:-0} + ${bg_ban:-0} + ${bg_emergency:-0}))
  },
  "memory": {
    "rss_bytes": ${rss:-0},
    "open_fds": ${fds:-0},
    "threads": ${threads:-0},
    "goroutines": ${goroutines:-0}
  },
  "server": {
    "hostname": "${server_hostname:-unknown}",
    "fqdn": "${server_fqdn:-unknown}",
    "os": "${server_os:-Linux}",
    "os_release": "${server_os_release:-Linux}",
    "kernel": "${server_kernel:-unknown}",
    "arch": "${server_arch:-unknown}",
    "cpu_model": "${server_cpu_model:-unknown}",
    "cpu_cores": ${cpu_cores:-1},
    "type": "${server_type:-physical}",
    "vendor": "${server_vendor:-Unknown}",
    "model": "${server_model:-Unknown}",
    "serial": "${server_serial:-N/A}",
    "primary_ip": "${server_primary_ip:-127.0.0.1}",
    "mac_address": "${server_mac:-00:00:00:00:00:00}",
    "subnet_mask": "${server_subnet_mask:-255.255.255.0}",
    "networks": "${server_networks:-lo:127.0.0.1}",
    "location": "${server_location:-Not configured}",
    "nftban_version": "${nftban_version:-unknown}",
    "memory_total_bytes": ${memory_total:-0},
    "memory_available_bytes": ${memory_available:-0},
    "memory_used_pct": ${memory_used_pct:-0},
    "uptime_seconds": ${server_uptime:-0},
    "disk_total_bytes": ${disk_total:-0},
    "disk_used_bytes": ${disk_used:-0},
    "disk_used_pct": ${disk_used_pct:-0}
  },
  "network": {
    "connections_active": ${conn_active:-0},
    "connections_established": ${conn_established:-0},
    "connections_time_wait": ${conn_time_wait:-0},
    "rx_mbps": ${total_rx_mbps:-0},
    "tx_mbps": ${total_tx_mbps:-0},
    "total_rx_mbps": ${total_rx_mbps:-0},
    "total_tx_mbps": ${total_tx_mbps:-0},
    "peak_rx_mbps": ${peak_rx:-0},
    "peak_tx_mbps": ${peak_tx:-0},
    "bytes_received_total": ${total_rx_bytes:-0},
    "bytes_sent_total": ${total_tx_bytes:-0},
    "packets_received_total": ${total_rx_packets:-0},
    "packets_sent_total": ${total_tx_packets:-0},
    "errors_total": ${total_errors:-0},
    "packets_dropped_total": ${total_dropped:-0},
    "bandwidth_in_bps": ${bandwidth_in_bps:-0},
    "bandwidth_out_bps": ${bandwidth_out_bps:-0}
  },
  "kernel": {
    "conntrack_entries": ${conntrack_entries:-0},
    "conntrack_max": ${conntrack_max:-0},
    "conntrack_utilization_percent": ${conntrack_utilization:-0},
    "softnet_drops_total": ${softnet_drops_total:-0},
    "softnet_drops_rate_per_minute": ${softnet_drops_rate:-0}
  },
  "eventbus": {
    "events_total": ${eventbus_events_total:-0},
    "events_by_type": {
      "ban": ${eventbus_events_ban:-0},
      "unban": ${eventbus_events_unban:-0},
      "login_fail": ${eventbus_events_login_fail:-0},
      "ddos_detected": ${eventbus_events_ddos_detected:-0},
      "portscan_detected": ${eventbus_events_portscan_detected:-0},
      "suricata_alert": ${eventbus_events_suricata_alert:-0},
      "feed_sync": ${eventbus_events_feed_sync:-0}
    },
    "events_dropped_total": ${eventbus_events_dropped_total:-0},
    "queue_size": ${eventbus_queue_size:-0},
    "handlers_total": ${eventbus_handlers_total:-0}
  }
}
EOF

    # Atomic write
    mv "${json_cache}.tmp" "$json_cache"
    chmod 644 "$json_cache"

    log_debug "Collected $(echo -e "$metrics" | wc -l) metrics → $json_cache"

    # =========================================================================
    # GUI CACHE FILES - Generate additional JSON files for GUI charts
    # These files enable the GOTH GUI to display historical and analytical data
    # Split from this file (BUG-L24: large file refactoring)
    # =========================================================================
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/exporters/nftban_exporter_gui_cache.sh" || return 1
    generate_gui_cache_files "$timestamp" "$collection_groups"
}

