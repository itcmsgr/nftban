#!/usr/bin/env bash
# TRANSITIONAL: loaded by unified exporter (unified_exporter.sh:153). Scheduled
# for removal after portal migrates to daemon API. See V190_HANDOFF_PLAN.md.
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_exporter_json_compat"
# meta:type="exporter"
# meta:version="1.56.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Legacy JSON compatibility layer - generates dynamic.json/inventory.json/combined.json from stats.json"
# meta:inventory.files=""
# meta:inventory.binaries="jq"
# meta:inventory.env_vars="NFTBAN_EXPORT_JSON"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
#
# COMPATIBILITY LAYER RATIONALE:
# ==============================
# The former metrics_collector.sh (removed v1.57.0) produced 3 JSON files:
#   - dynamic.json  (every run)
#   - inventory.json (hourly)
#   - combined.json  (merge of both)
#
# These files have zero internal consumers since stats.json (schema v2.0)
# replaced them. However, external tools (user scripts, Zabbix userparams,
# monitoring integrations) may still read them.
#
# This module transforms stats.json into the legacy schema to preserve
# backward compatibility during the transition to unified exporter.
#
# Data source: /var/cache/nftban/metrics/stats.json (Single Source of Truth)
# Gap filling: /run/nftban/health.status, /run/nftban/stats.json (daemon),
#              /sys/class/net/*, /proc/loadavg, /proc/meminfo
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_EXPORTER_JSON_COMPAT_LOADED:-}" ]] && return 0
_EXPORTER_JSON_COMPAT_LOADED="true"

# =============================================================================
# LEGACY JSON COMPATIBILITY EXPORT
# =============================================================================
# Reads stats.json + runtime files, produces legacy dynamic/inventory/combined
# Called from main() in nftban_unified_exporter.sh after collect_all_metrics()
# =============================================================================
export_legacy_json() {
    local metrics_dir="${NFTBAN_CACHE_DIR:-/var/cache/nftban}/metrics"
    local stats_json="${metrics_dir}/stats.json"
    local dynamic_file="${metrics_dir}/dynamic.json"
    local inventory_file="${metrics_dir}/inventory.json"
    local combined_file="${metrics_dir}/combined.json"
    local run_count_file="${RUN_COUNT_FILE:-${NFTBAN_CACHE_DIR:-/var/cache/nftban}/collection.run_count}"
    local inventory_mult="${NFTBAN_COLLECT_INVENTORY_MULT:-60}"

    # Require jq and stats.json
    if ! command -v jq &>/dev/null; then
        log_warn "Legacy JSON compat: jq not found, skipping"
        return 1
    fi
    if [[ ! -f "$stats_json" ]]; then
        log_warn "Legacy JSON compat: stats.json not found at $stats_json"
        return 1
    fi

    mkdir -p "$metrics_dir" || return 1

    # Read stats.json once into a variable (avoid repeated file I/O)
    local stats
    stats=$(cat "$stats_json" 2>/dev/null) || return 1

    local timestamp
    timestamp=$(date +%s)

    # -----------------------------------------------------------------
    # Build dynamic.json from stats.json + runtime gap-filling
    # -----------------------------------------------------------------
    _build_legacy_dynamic "$stats" "$timestamp" > "${dynamic_file}.tmp" || {
        rm -f "${dynamic_file}.tmp"
        log_error "Legacy JSON compat: failed to build dynamic.json"
        return 1
    }
    mv "${dynamic_file}.tmp" "$dynamic_file"

    # -----------------------------------------------------------------
    # Build inventory.json (hourly — check run_count)
    # -----------------------------------------------------------------
    local run_count=0
    [[ -f "$run_count_file" ]] && run_count=$(cat "$run_count_file" 2>/dev/null || echo "0")

    if [[ $((run_count % inventory_mult)) -eq 0 ]] || [[ ! -f "$inventory_file" ]]; then
        _build_legacy_inventory "$stats" "$timestamp" > "${inventory_file}.tmp" || {
            rm -f "${inventory_file}.tmp"
            log_error "Legacy JSON compat: failed to build inventory.json"
            return 1
        }
        mv "${inventory_file}.tmp" "$inventory_file"
    fi

    # -----------------------------------------------------------------
    # Build combined.json = merge of dynamic + inventory
    # -----------------------------------------------------------------
    if [[ -f "$inventory_file" ]]; then
        jq -s 'add' "$dynamic_file" "$inventory_file" > "${combined_file}.tmp" 2>/dev/null || {
            rm -f "${combined_file}.tmp"
            # Fallback: just use dynamic
            cp "$dynamic_file" "${combined_file}.tmp"
        }
        mv "${combined_file}.tmp" "$combined_file"
    else
        cp "$dynamic_file" "$combined_file"
    fi

    log_debug "Legacy JSON compat: wrote dynamic.json + combined.json"
    return 0
}

# =============================================================================
# DYNAMIC.JSON BUILDER
# =============================================================================
# Maps stats.json (schema v2.0) → legacy dynamic.json schema
# Fills gaps from runtime files where stats.json lacks coverage
# =============================================================================
_build_legacy_dynamic() {
    local stats="$1"
    local timestamp="$2"

    # --- Extract all needed values from stats.json in a single jq call ---
    local extracted
    extracted=$(echo "$stats" | jq -r '
        [
            # daemon (0-2)
            (.daemon.status // 0),
            (.daemon.pid // 0),
            (.daemon.uptime_seconds // 0),
            # bans (3-9)
            (.blacklist.total // 0),
            (.activity.bans_24h // 0),
            (.activity.bans_1h // 0),
            (.activity.rate_per_minute // 0),
            (.activity.total_bans // 0),
            ((.blacklist.ipv4.permanent // 0) + (.blacklist.ipv6.permanent // 0)),
            (.whitelist.total // 0),
            # memory (10-13)
            (.memory.rss_bytes // 0),
            (.memory.open_fds // 0),
            (.memory.threads // 0),
            (.memory.goroutines // 0),
            # modules (14-16)
            (.modules.enabled // 0),
            (.modules.active // 0),
            (.modules.failed // 0),
            # module_status (17-24)
            (.module_status.suricata // 0),
            (.module_status.login // 0),
            (.module_status.portscan // 0),
            (.module_status.ddos // 0),
            (.module_status.feeds // 0),
            (.module_status.geoban // 0),
            (.module_status.watchdog // 0),
            (.module_status.botguard // 0),
            # eventbus (25-34)
            (.eventbus.events_total // 0),
            (.eventbus.events_by_type.ban // 0),
            (.eventbus.events_by_type.unban // 0),
            (.eventbus.events_by_type.login_fail // 0),
            (.eventbus.events_by_type.ddos_detected // 0),
            (.eventbus.events_by_type.portscan_detected // 0),
            (.eventbus.events_by_type.suricata_alert // 0),
            (.eventbus.events_by_type.feed_sync // 0),
            (.eventbus.events_dropped_total // 0),
            (.eventbus.queue_size // 0),
            # eventbus handlers (35)
            (.eventbus.handlers_total // 0),
            # firewall (36-37)
            (.firewall.sets_total // 0),
            (.firewall.elements_total // 0),
            # ban_details from bans_by_source (38-43)
            (.bans_by_source.manual // 0),
            (.bans_by_source.feeds // 0),
            (.bans_by_source.login // 0),
            (.bans_by_source.portscan // 0),
            (.bans_by_source.ddos // 0),
            (.bans_by_source.suricata // 0),
            # feeds (44-47)
            (.feeds.enabled // 0),
            (.feeds.loaded // 0),
            (.feeds.failed // 0),
            (.feeds.ips_total // 0),
            # network (48-52)
            (.network.connections_active // 0),
            (.network.connections_established // 0),
            (.network.connections_time_wait // 0),
            (.network.bytes_received_total // 0),
            (.network.bytes_sent_total // 0),
            # activity/analytics (53-55)
            (.activity.unique_ips_24h // 0),
            (.activity.unique_ips // 0),
            (.activity.bans_7d // 0),
            # geoban (56)
            (.geoban.countries_blocked // 0),
            # kernel (57-61)
            (.kernel.conntrack_entries // 0),
            (.kernel.conntrack_max // 0),
            (.kernel.conntrack_utilization_percent // 0),
            (.kernel.softnet_drops // 0),
            (.kernel.softnet_drops_rate_per_minute // 0),
            # server version (62)
            (.server.nftban_version // "unknown"),
            # feed_health (63-64)
            (.feed_health.sync_errors_total // 0),
            (.feed_health.stale_count // 0)
        ] | @tsv
    ' 2>/dev/null) || {
        log_error "Legacy JSON compat: jq extraction failed"
        return 1
    }

    # Parse all extracted values
    # shellcheck disable=SC2034  # Variables assigned via read, used in heredoc JSON template
    local d_status d_pid d_uptime
    local b_active b_24h b_1h b_rate b_total b_permanent b_whitelist
    local m_rss m_fds m_threads m_goroutines
    local mod_enabled mod_active mod_failed
    local ms_suricata ms_loginmon ms_portscan ms_ddos ms_feeds ms_geoban ms_watchdog ms_botguard
    local eb_total eb_ban eb_unban eb_login_fail eb_ddos eb_portscan eb_suricata eb_feed_sync
    local eb_dropped eb_queue eb_handlers
    local fw_sets fw_elements
    local bd_manual bd_feeds bd_loginmon bd_portscan bd_ddos bd_suricata
    local f_enabled f_loaded f_failed f_ips
    local n_active n_established n_time_wait n_rx_bytes n_tx_bytes
    local a_unique_24h a_unique_total a_bans_7d
    local g_countries
    local k_ct_entries k_ct_max k_ct_util k_sn_drops k_sn_rate
    local s_version
    local fh_errors fh_stale

    # shellcheck disable=SC2034  # All variables used in heredoc JSON template below
    IFS=$'\t' read -r \
        d_status d_pid d_uptime \
        b_active b_24h b_1h b_rate b_total b_permanent b_whitelist \
        m_rss m_fds m_threads m_goroutines \
        mod_enabled mod_active mod_failed \
        ms_suricata ms_loginmon ms_portscan ms_ddos ms_feeds ms_geoban ms_watchdog ms_botguard \
        eb_total eb_ban eb_unban eb_login_fail eb_ddos eb_portscan eb_suricata eb_feed_sync \
        eb_dropped eb_queue \
        eb_handlers \
        fw_sets fw_elements \
        bd_manual bd_feeds bd_loginmon bd_portscan bd_ddos bd_suricata \
        f_enabled f_loaded f_failed f_ips \
        n_active n_established n_time_wait n_rx_bytes n_tx_bytes \
        a_unique_24h a_unique_total a_bans_7d \
        g_countries \
        k_ct_entries k_ct_max k_ct_util k_sn_drops k_sn_rate \
        s_version \
        fh_errors fh_stale \
        <<< "$extracted"

    # --- Gap filling: fields not in stats.json ---

    # Daemon mode from runtime file
    local d_mode="normal"
    [[ -f "${NFTBAN_RUN_DIR:-/run/nftban}/mode" ]] && d_mode=$(cat "${NFTBAN_RUN_DIR:-/run/nftban}/mode" 2>/dev/null || echo "normal")
    [[ -z "$d_mode" ]] && d_mode="normal"

    # Health status from /run/nftban/health.status
    local h_status=0 h_passed=0 h_failed=0
    local health_file="${NFTBAN_RUN_DIR:-/run/nftban}/health.status"
    if [[ -f "$health_file" ]]; then
        local health_data
        health_data=$(jq -r '[(.healthy // false), (.passed // 0), (.failed // 0)] | @tsv' "$health_file" 2>/dev/null || echo "false	0	0")
        local h_healthy
        IFS=$'\t' read -r h_healthy h_passed h_failed <<< "$health_data"
        [[ "$h_healthy" == "true" ]] && h_status=1
    fi

    # Suricata section from legacy collection approach
    # Minimal: enabled flag + stub for fields not in stats.json
    local suricata_json
    suricata_json=$(_build_legacy_suricata)

    # nftables_perf from daemon stats + nft (gap fill)
    # shellcheck disable=SC2034  # Variables used in heredoc JSON template
    local nftp_latency=0 nftp_errors=0 nftp_rules=0 nftp_commands=0
    local daemon_stats_file="${NFTBAN_RUN_DIR:-/run/nftban}/stats.json"
    if [[ -f "$daemon_stats_file" ]]; then
        local nftp_data
        nftp_data=$(jq -r '[(.nftables.apply_latency_ms // 0), (.nftables.apply_errors // 0), (.nftables.commands_total // 0)] | @tsv' "$daemon_stats_file" 2>/dev/null || echo "0	0	0")
        IFS=$'\t' read -r nftp_latency nftp_errors nftp_commands <<< "$nftp_data"
    fi

    # Network interfaces array from /sys/class/net
    local iface_array=""
    local iface_path iface
    for iface_path in /sys/class/net/*; do
        [[ -d "$iface_path" ]] || continue
        iface=$(basename "$iface_path")
        [[ "$iface" == "lo" ]] && continue
        local i_rx i_tx i_rxp i_txp
        i_rx=$(cat "/sys/class/net/$iface/statistics/rx_bytes" 2>/dev/null || echo "0")
        i_tx=$(cat "/sys/class/net/$iface/statistics/tx_bytes" 2>/dev/null || echo "0")
        i_rxp=$(cat "/sys/class/net/$iface/statistics/rx_packets" 2>/dev/null || echo "0")
        i_txp=$(cat "/sys/class/net/$iface/statistics/tx_packets" 2>/dev/null || echo "0")
        [[ -n "$iface_array" ]] && iface_array+=","
        iface_array+="{\"name\":\"$iface\",\"rx_bytes\":$i_rx,\"tx_bytes\":$i_tx,\"rx_packets\":$i_rxp,\"tx_packets\":$i_txp}"
    done

    # Connection close_wait (not in stats.json)
    local n_close_wait=0
    if command -v ss &>/dev/null; then
        n_close_wait=$(ss -t state close-wait 2>/dev/null | wc -l) || n_close_wait=0
        # Subtract header line
        [[ "$n_close_wait" -gt 0 ]] && n_close_wait=$((n_close_wait - 1))
    fi

    # Runtime/throughput/ipc/watchdog from daemon stats or zero defaults
    local rt_goroutines=0 rt_heap_mb=0 rt_alloc_mb=0 rt_sys_mb=0 rt_gc_cycles=0 rt_gc_pause_ms=0
    local tp_bans=0 tp_unbans=0 tp_events=0 tp_bans_per_min=0
    local ipc_requests=0 ipc_latency=0 ipc_errors=0
    local wd_status_val=0 wd_mode="unknown" wd_cpu=0 wd_mem=0 wd_io=0
    local daemon_mode_val="unknown" server_region="unknown"
    if [[ -f "$daemon_stats_file" ]]; then
        local wd_data
        wd_data=$(jq -r '
            [
                (.runtime.goroutines // 0), (.runtime.memory_heap_mb // 0),
                (.runtime.memory_alloc_mb // 0), (.runtime.memory_sys_mb // 0),
                (.runtime.gc_cycles // 0), (.runtime.gc_pause_ms // 0),
                (.throughput.bans_total // 0), (.throughput.unbans_total // 0),
                (.throughput.events_total // 0), (.throughput.bans_per_min // 0),
                (.ipc.requests_total // 0), (.ipc.avg_latency_ms // 0),
                (.ipc.errors_total // 0),
                (.watchdog.status // 0), (.watchdog.mode // "unknown"),
                (.watchdog.cpu_score // 0), (.watchdog.mem_score // 0),
                (.watchdog.io_score // 0),
                (.daemon.mode // "unknown"), (.server.region // "unknown")
            ] | @tsv
        ' "$daemon_stats_file" 2>/dev/null || echo "")
        if [[ -n "$wd_data" ]]; then
            IFS=$'\t' read -r \
                rt_goroutines rt_heap_mb rt_alloc_mb rt_sys_mb rt_gc_cycles rt_gc_pause_ms \
                tp_bans tp_unbans tp_events tp_bans_per_min \
                ipc_requests ipc_latency ipc_errors \
                wd_status_val wd_mode wd_cpu wd_mem wd_io \
                daemon_mode_val server_region <<< "$wd_data"
        fi
    fi

    # System metrics from /proc (not in stats.json)
    local sys_load_1m=0 sys_load_5m=0 sys_load_15m=0
    [[ -f /proc/loadavg ]] && read -r sys_load_1m sys_load_5m sys_load_15m _ _ < /proc/loadavg
    local sys_mem_used_pct=0 sys_mem_avail_mb=0
    if [[ -f /proc/meminfo ]]; then
        local mem_total mem_avail
        mem_total=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo "0")
        mem_avail=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null || echo "0")
        sys_mem_avail_mb=$((mem_avail / 1024))
        if [[ "$mem_total" -gt 0 ]]; then
            sys_mem_used_pct=$(awk "BEGIN {printf \"%.0f\", (($mem_total - $mem_avail) / $mem_total) * 100}")
        fi
    fi
    local sys_iowait=0 sys_disk_used_pct=0
    # iowait from /proc/stat (cpu line, 5th field)
    sys_iowait=$(awk '/^cpu / {printf "%.1f", ($6 / ($2+$3+$4+$5+$6+$7+$8)) * 100}' /proc/stat 2>/dev/null || echo "0")
    # disk usage of root partition
    sys_disk_used_pct=$(df / 2>/dev/null | awk 'NR==2 {gsub(/%/,""); print $5}' || echo "0")

    # GeoIP database age
    local geoip_db_age=0
    local geoip_db=""
    for path in "${NFTBAN_DATA_DIR:-/var/lib/nftban}/geoip/dbip-country-lite.mmdb" \
                "${NFTBAN_DATA_DIR:-/var/lib/nftban}/geoip/GeoLite2-Country.mmdb" \
                "${NFTBAN_CACHE_DIR:-/var/cache/nftban}/geoip/dbip-country-lite.mmdb" \
                "${NFTBAN_CACHE_DIR:-/var/cache/nftban}/geoip/GeoLite2-Country.mmdb"; do
        [[ -f "$path" ]] && { geoip_db="$path"; break; }
    done
    if [[ -n "$geoip_db" ]]; then
        local db_mtime
        db_mtime=$(stat -c %Y "$geoip_db" 2>/dev/null || echo "0")
        geoip_db_age=$(( (timestamp - db_mtime) / 86400 ))
    fi

    # Feed health per-feed detail (gap fill from feed state files)
    local feed_health_json
    feed_health_json=$(_build_legacy_feed_health)

    # Ban details: escalations, persistent, recidivist (not in stats.json)
    local bd_escalations=0 bd_persistent=0 bd_recidivist=0
    local escalation_log="${NFTBAN_LOG_DIR:-/var/log/nftban}/escalations.log"
    [[ -f "$escalation_log" ]] && bd_escalations=$(wc -l < "$escalation_log" 2>/dev/null || echo "0")
    local permanent_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/permanent.list"
    [[ -f "$permanent_file" ]] && { bd_persistent=$(grep -cE "^[0-9]" "$permanent_file" 2>/dev/null) || bd_persistent=0; }
    local bans_log="${NFTBAN_LOG_DIR:-/var/log/nftban}/bans.log"
    [[ -f "$bans_log" ]] && { bd_recidivist=$(awk -F'|' '{print $3}' "$bans_log" 2>/dev/null | sort | uniq -d | wc -l) || bd_recidivist=0; }

    # Analytics: recidivism_rate, top_attackers
    local a_recidivism=0 a_top_attackers=0
    if [[ -f "$bans_log" ]]; then
        local total_unique repeat_ips
        total_unique=$(awk -F'|' '{print $3}' "$bans_log" 2>/dev/null | sort -u | wc -l) || total_unique=1
        repeat_ips=$(awk -F'|' '{print $3}' "$bans_log" 2>/dev/null | sort | uniq -d | wc -l) || repeat_ips=0
        [[ "$total_unique" -gt 0 ]] && a_recidivism=$(echo "scale=2; $repeat_ips / $total_unique * 100" | bc 2>/dev/null || echo "0")
        a_top_attackers=$(awk -F'|' '{print $3}' "$bans_log" 2>/dev/null | sort | uniq -c | awk '$1 > 5' | wc -l) || a_top_attackers=0
    fi

    # nftables rules/packets (gap fill — not in stats.json)
    local nft_rules=0 nft_pkt_v4=0 nft_pkt_v6=0
    if command -v nft &>/dev/null; then
        nft_rules=$(nft list table ${NFTBAN_TABLE_IPV4:-ip\ nftban} 2>/dev/null | grep -cE "^\s+(accept|drop|reject|return|jump|goto)") || nft_rules=0
        nft_pkt_v4=$(nft -j list chain ${NFTBAN_TABLE_IPV4:-ip\ nftban} input 2>/dev/null | jq -r '[.nftables[]?.rule?.expr[]? | select(.counter) | .counter.packets] | add // 0' 2>/dev/null || echo "0")
        nft_pkt_v6=$(nft -j list chain ${NFTBAN_TABLE_IPV6:-ip6\ nftban} input6 2>/dev/null | jq -r '[.nftables[]?.rule?.expr[]? | select(.counter) | .counter.packets] | add // 0' 2>/dev/null || echo "0")
    fi

    # --- Output legacy dynamic.json ---
    cat <<EOF
{
  "daemon": {
    "status": ${d_status:-0},
    "version": "${s_version:-unknown}",
    "uptime": ${d_uptime:-0},
    "pid": ${d_pid:-0},
    "mode": "$d_mode"
  },
  "bans": {
    "active": ${b_active:-0},
    "bans_24h": ${b_24h:-0},
    "bans_1h": ${b_1h:-0},
    "rate": ${b_rate:-0},
    "total": ${b_total:-0},
    "permanent": ${b_permanent:-0},
    "whitelist": ${b_whitelist:-0}
  },
  "memory": {
    "rss": ${m_rss:-0},
    "fds": ${m_fds:-0},
    "threads": ${m_threads:-0},
    "goroutines": ${m_goroutines:-0}
  },
  "health": {
    "status": $h_status,
    "passed": $h_passed,
    "failed": $h_failed
  },
  "modules": {
    "enabled": ${mod_enabled:-0},
    "active": ${mod_active:-0},
    "failed": ${mod_failed:-0}
  },
  "module_status": {
    "suricata": ${ms_suricata:-0},
    "loginmon": ${ms_loginmon:-0},
    "portscan": ${ms_portscan:-0},
    "ddos": ${ms_ddos:-0},
    "feeds": ${ms_feeds:-0},
    "geoban": ${ms_geoban:-0},
    "watchdog": ${ms_watchdog:-0}
  },
  ${feed_health_json},
  ${suricata_json},
  "eventbus": {
    "events_total": ${eb_total:-0},
    "events_by_type": {
      "ban": ${eb_ban:-0},
      "unban": ${eb_unban:-0},
      "login_fail": ${eb_login_fail:-0},
      "ddos_detected": ${eb_ddos:-0},
      "portscan_detected": ${eb_portscan:-0},
      "suricata_alert": ${eb_suricata:-0},
      "feed_sync": ${eb_feed_sync:-0}
    },
    "events_dropped": ${eb_dropped:-0},
    "queue_size": ${eb_queue:-0},
    "handlers_total": ${eb_handlers:-0}
  },
  "nftables_perf": {
    "apply_latency_ms": ${nftp_latency:-0},
    "apply_errors_total": ${nftp_errors:-0},
    "rules_total": ${nft_rules:-0},
    "rules_by_table": {
      "nftban": ${nft_rules:-0}
    },
    "sets_total": ${fw_sets:-0},
    "set_elements": {
      "blacklist_ipv4": 0,
      "blacklist_ipv6": 0,
      "whitelist_ipv4": 0,
      "whitelist_ipv6": 0
    },
    "commands_total": ${nftp_commands:-0}
  },
  "ban_details": {
    "bans_by_source": {
      "manual": ${bd_manual:-0},
      "feeds": ${bd_feeds:-0},
      "loginmon": ${bd_loginmon:-0},
      "portscan": ${bd_portscan:-0},
      "ddos": ${bd_ddos:-0},
      "suricata": ${bd_suricata:-0},
      "geoban": 0
    },
    "escalations_total": $bd_escalations,
    "persistent_offenders_total": $bd_persistent,
    "recidivist_ips_total": $bd_recidivist,
    "ban_failures_total": 0,
    "unban_failures_total": 0
  },
  "nftables": {
    "sets": ${fw_sets:-0},
    "elements": ${fw_elements:-0},
    "rules": $nft_rules,
    "packets_blocked_ipv4": $nft_pkt_v4,
    "packets_blocked_ipv6": $nft_pkt_v6
  },
  "analytics": {
    "unique_ips_24h": ${a_unique_24h:-0},
    "recidivism_rate": $a_recidivism,
    "top_attackers_total": $a_top_attackers,
    "watchdog_mode_transitions_total": 0,
    "alerts_active": {
      "info": 0,
      "warning": 0,
      "critical": 0
    },
    "geoban_database_age_seconds": $((geoip_db_age * 86400))
  },
  "feeds": {
    "enabled": ${f_enabled:-0},
    "loaded": ${f_loaded:-0},
    "failed": ${f_failed:-0},
    "ips_total": ${f_ips:-0}
  },
  "network": {
    "interfaces": [${iface_array}],
    "connections": {
      "active": ${n_active:-0},
      "established": ${n_established:-0},
      "time_wait": ${n_time_wait:-0},
      "close_wait": $n_close_wait
    }
  },
  "runtime": {
    "goroutines": $rt_goroutines,
    "heap_mb": $rt_heap_mb,
    "alloc_mb": $rt_alloc_mb,
    "sys_mb": $rt_sys_mb,
    "gc_cycles": $rt_gc_cycles,
    "gc_pause_ms": $rt_gc_pause_ms
  },
  "throughput": {
    "bans_total": $tp_bans,
    "unbans_total": $tp_unbans,
    "events_total": $tp_events,
    "bans_per_min": $tp_bans_per_min
  },
  "ipc": {
    "requests_total": $ipc_requests,
    "avg_latency_ms": $ipc_latency,
    "errors_total": $ipc_errors
  },
  "watchdog": {
    "status": $wd_status_val,
    "mode": "$wd_mode",
    "cpu_score": $wd_cpu,
    "mem_score": $wd_mem,
    "io_score": $wd_io
  },
  "daemon_mode": "$daemon_mode_val",
  "server_region": "$server_region",
  "system": {
    "load_1m": $sys_load_1m,
    "load_5m": $sys_load_5m,
    "load_15m": $sys_load_15m,
    "mem_used_percent": $sys_mem_used_pct,
    "mem_available_mb": $sys_mem_avail_mb,
    "iowait_percent": $sys_iowait,
    "disk_used_percent": $sys_disk_used_pct
  },
  "geoip": {
    "database_age": $geoip_db_age,
    "countries_blocked": ${g_countries:-0}
  },
  "kernel": {
    "conntrack_entries": ${k_ct_entries:-0},
    "conntrack_max": ${k_ct_max:-0},
    "conntrack_utilization": ${k_ct_util:-0},
    "softnet_drops": ${k_sn_drops:-0},
    "softnet_backlog": 0
  },
  "timestamp": $timestamp,
  "type": "dynamic"
}
EOF
}

# =============================================================================
# SURICATA SECTION BUILDER
# =============================================================================
# Suricata metrics are NOT in stats.json — collect from original sources
# Returns JSON fragment (without outer braces) for embedding
# =============================================================================
_build_legacy_suricata() {
    if [[ "${NFTBAN_SURICATA_ENABLED:-false}" != "true" ]]; then
        echo '"suricata": {"enabled": false}'
        return 0
    fi

    local up=0 alerts_total=0 rules_total=0 bans_total=0 eve_errors=0 last_alert=0
    local rule_profile="standard" rules_filtered=0

    # Check if running
    if systemctl is-active suricata.service &>/dev/null 2>&1; then
        up=1
    fi

    # EVE JSON alert count (last 10000 lines)
    local eve_log="/var/log/suricata/eve.json"
    if [[ -f "$eve_log" ]]; then
        alerts_total=$(tail -10000 "$eve_log" 2>/dev/null | jq -r 'select(.event_type == "alert") | .alert.severity' 2>/dev/null | wc -l) || alerts_total=0
        local last_ts
        last_ts=$(tail -1000 "$eve_log" 2>/dev/null | jq -r 'select(.event_type == "alert") | .timestamp' 2>/dev/null | tail -1)
        [[ -n "$last_ts" ]] && last_alert=$(date -d "$last_ts" +%s 2>/dev/null || echo "0")
    fi

    # Bans from suricata source
    local bans_log="${NFTBAN_LOG_DIR:-/var/log/nftban}/bans.log"
    [[ -f "$bans_log" ]] && { bans_total=$(grep -ci "suricata" "$bans_log" 2>/dev/null) || bans_total=0; }

    # Rule profile
    local suricata_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/modules/suricata.conf"
    if [[ -f "$suricata_conf" ]]; then
        rule_profile=$(grep -E "^NFTBAN_SURICATA_PROFILE=" "$suricata_conf" 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "standard")
        [[ -z "$rule_profile" ]] && rule_profile="standard"
    fi

    cat <<EOF
"suricata": {
    "enabled": true,
    "up": $up,
    "alerts_total": $alerts_total,
    "alerts_by_severity": {"1": 0, "2": 0, "3": 0, "4": 0},
    "alerts_by_category": {},
    "rules_total": $rules_total,
    "rules_filtered": $rules_filtered,
    "bans_total": $bans_total,
    "eve_parse_errors": $eve_errors,
    "last_alert_timestamp": $last_alert,
    "rule_profile": "$rule_profile",
    "performance": {
      "memory_rss_mb": 0,
      "capture_kernel_packets": 0,
      "capture_kernel_drops": 0,
      "decoder_pkts": 0,
      "decoder_bytes": 0,
      "decoder_invalid": 0,
      "flow_total": 0,
      "flow_memuse": 0,
      "tcp_sessions": 0,
      "tcp_memuse": 0,
      "tcp_reassembly_gap": 0,
      "memcap_pressure": 0,
      "ring_size": 0,
      "tpacket_version": "unknown",
      "capture_threads": 0,
      "uptime_seconds": 0
    },
    "capacity_drops": {
      "tcp_ssn_memcap_drop": 0,
      "tcp_segment_memcap_drop": 0,
      "flow_memcap_drops": 0,
      "flow_emerg_mode_entered": 0
    },
    "system": {
      "cpu_cores": 0,
      "memory_available_mb": 0
    }
  }
EOF
}

# =============================================================================
# FEED HEALTH SECTION BUILDER
# =============================================================================
# Rebuilds per-feed detail from feed state files (not in stats.json)
# Returns JSON fragment for embedding in dynamic.json
# =============================================================================
_build_legacy_feed_health() {
    local total=0 active=0 stale=0 errors=0 last_sync=0
    local feeds_json=""
    local now
    now=$(date +%s)
    local stale_threshold=$((24 * 3600))

    local config_dir="${NFTBAN_CONFIG_DIR:-/etc/nftban}"
    local data_dir="${NFTBAN_DATA_DIR:-/var/lib/nftban}"

    for conf in "${config_dir}/feeds"/*.conf; do
        [[ -f "$conf" ]] || continue
        local feed_name
        feed_name=$(basename "$conf" .conf)
        ((total++)) || true

        local state_file="${data_dir}/feeds/${feed_name}.state"
        local feed_sync=0 feed_ips=0
        if [[ -f "$state_file" ]]; then
            local state_values
            state_values=$(jq -r '[(.last_sync // 0), (.ips_loaded // 0)] | @tsv' "$state_file" 2>/dev/null || echo "0	0")
            IFS=$'\t' read -r feed_sync feed_ips <<< "$state_values"
        fi

        [[ "$feed_sync" -gt "$last_sync" ]] && last_sync="$feed_sync"

        local feed_active=0
        local feed_age=$((now - feed_sync))
        if [[ "$feed_sync" -gt 0 ]] && [[ "$feed_age" -lt "$stale_threshold" ]]; then
            feed_active=1
            ((active++)) || true
        elif [[ "$feed_sync" -gt 0 ]]; then
            ((stale++)) || true
        fi

        [[ -n "$feeds_json" ]] && feeds_json+=","
        feeds_json+="\"$feed_name\": {\"active\": $feed_active, \"last_sync\": $feed_sync, \"ips_loaded\": $feed_ips, \"errors\": 0}"
    done

    cat <<EOF
"feed_health": {
    "total_feeds": $total,
    "active_feeds": $active,
    "stale_feeds": $stale,
    "sync_errors_24h": $errors,
    "last_sync_timestamp": $last_sync,
    "feeds": {${feeds_json}}
  }
EOF
}

# =============================================================================
# INVENTORY.JSON BUILDER
# =============================================================================
# Maps stats.json .server section → legacy inventory.json schema
# =============================================================================
_build_legacy_inventory() {
    local stats="$1"
    local timestamp="$2"

    # Extract server fields from stats.json
    local inv_data
    inv_data=$(echo "$stats" | jq -r '
        [
            (.server.hostname // "unknown"),
            (.server.fqdn // "unknown"),
            (.server.os // "unknown"),
            (.server.os_release // "unknown"),
            (.server.kernel // "unknown"),
            (.server.arch // "unknown"),
            (.server.cpu_cores // 1),
            (.server.cpu_model // "unknown"),
            (.server.memory_total_bytes // 0),
            (.server.primary_ip // "127.0.0.1"),
            (.server.mac_address // ""),
            (.server.subnet_mask // "255.255.255.0"),
            (.server.uptime_seconds // 0)
        ] | @tsv
    ' 2>/dev/null) || return 1

    local i_hostname i_fqdn i_os i_os_release i_kernel i_arch
    local i_cpu_cores i_cpu_model i_memory_total
    local i_primary_ip i_mac i_subnet i_uptime

    IFS=$'\t' read -r \
        i_hostname i_fqdn i_os i_os_release i_kernel i_arch \
        i_cpu_cores i_cpu_model i_memory_total \
        i_primary_ip i_mac i_subnet i_uptime \
        <<< "$inv_data"

    # Fields not in stats.json — collect directly (same as legacy collector)
    local i_ipv6=""
    i_ipv6=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2; exit}' | cut -d'/' -f1 || echo "")

    local i_gateway=""
    i_gateway=$(ip route show default 2>/dev/null | awk '{print $3; exit}' || echo "")

    local i_public_ip=""
    i_public_ip=$(curl -4 -s -m 2 https://api.ipify.org 2>/dev/null || echo "")
    [[ ! "${i_public_ip:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && i_public_ip=""

    local i_interfaces i_networks
    i_interfaces=$(ip -j link show 2>/dev/null | jq -c '[.[].ifname]' 2>/dev/null || echo '[]')
    i_networks=$(ip -j addr show 2>/dev/null | jq -c '[.[] | select(.ifname != "lo") | {iface: .ifname, mac: .address, ips: [.addr_info[]? | select(.family == "inet" or .family == "inet6") | {ip: .local, prefix: .prefixlen, family: .family}]}]' 2>/dev/null || echo '[]')

    local i_timezone
    i_timezone=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "UTC")

    local i_virt="none"
    if grep -q "^flags.*hypervisor" /proc/cpuinfo 2>/dev/null; then
        i_virt="vm"
        grep -qi "kvm" /sys/class/dmi/id/product_name 2>/dev/null && i_virt="kvm"
        grep -qi "vmware" /sys/class/dmi/id/sys_vendor 2>/dev/null && i_virt="vmware"
    fi
    [[ -f /.dockerenv ]] && i_virt="docker"

    local i_cloud="none"
    curl -s -m 1 http://169.254.169.254/latest/meta-data/ &>/dev/null && i_cloud="aws"
    curl -s -m 1 -H "Metadata-Flavor: Google" http://169.254.169.254/computeMetadata/v1/ &>/dev/null && i_cloud="gcp"

    local i_boot_time
    i_boot_time=$(( $(date +%s) - $(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo "0") ))

    cat <<EOF
{
  "server": {
    "hostname": "$i_hostname",
    "fqdn": "$i_fqdn",
    "os": "$i_os",
    "os_release": "$i_os_release",
    "kernel": "$i_kernel",
    "arch": "$i_arch",
    "cpu_cores": $i_cpu_cores,
    "cpu_model": "$i_cpu_model",
    "memory_total": $i_memory_total,
    "primary_ip": "$i_primary_ip",
    "ipv6": "$i_ipv6",
    "mac_address": "$i_mac",
    "subnet_mask": "$i_subnet",
    "gateway": "$i_gateway",
    "public_ip": "$i_public_ip",
    "interfaces": $i_interfaces,
    "networks": $i_networks,
    "timezone": "$i_timezone",
    "virtualization": "$i_virt",
    "cloud_provider": "$i_cloud",
    "boot_time": $i_boot_time,
    "uptime": ${i_uptime:-0}
  },
  "timestamp": $timestamp,
  "type": "inventory"
}
EOF
}
