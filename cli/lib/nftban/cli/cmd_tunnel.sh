#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.30.0 - Tunnel Suspicion CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: CLI interface for DNS tunnel suspicion monitoring
#
# meta:name="cmd_tunnel"
# meta:type="cli"
# meta:header="Tunnel Suspicion CLI Handler"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="CLI commands for DNS tunnel suspicion monitoring (advisory-only)"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/conf.d/tunnel/main.conf"
# meta:inventory.systemd_units="nftban-tunnel.timer,nftban-tunnel.service"
# meta:inventory.network=""
# meta:inventory.privileges="conditional"
#
# meta:created_date="2026-03-21"
# =============================================================================

# Source central config for canonical paths
# shellcheck source=/etc/nftban/nftban.conf
source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" 2>/dev/null || true

[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"

# Load strict mode library
# shellcheck source=/usr/lib/nftban/lib/strict.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/strict.sh" || return 1
else
    set -Eeuo pipefail
fi

# Prevent double-loading
[[ -n "${CMD_TUNNEL_LOADED:-}" ]] && return 0
readonly CMD_TUNNEL_LOADED=1

# Load tunnel engine
# shellcheck source=/dev/null
if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_tunnel.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/core/nftban_tunnel.sh" || return 1
fi

# =============================================================================
# COMMAND HANDLER
# =============================================================================

nftban_cmd_tunnel() {
    # Main tunnel command handler
    # Usage: nftban tunnel <subcommand> [options]

    local subcommand="${1:-help}"
    shift || true

    # Load config
    nftban_tunnel_load_config

    case "$subcommand" in
        status)
            _tunnel_cmd_status "$@"
            ;;
        enable)
            _tunnel_cmd_enable "$@"
            ;;
        disable)
            _tunnel_cmd_disable "$@"
            ;;
        scan)
            _tunnel_cmd_scan "$@"
            ;;
        top)
            _tunnel_cmd_top "$@"
            ;;
        explain)
            _tunnel_cmd_explain "$@"
            ;;
        config)
            _tunnel_cmd_config "$@"
            ;;
        help|--help|-h)
            _tunnel_cmd_usage
            ;;
        *)
            echo "Error: Unknown subcommand: $subcommand" >&2
            echo "Run 'nftban tunnel help' for usage" >&2
            return 1
            ;;
    esac

    echo "# NFTBAN_CMD_EXIT: tunnel"
    return 0
}

# =============================================================================
# SUBCOMMAND: status
# =============================================================================

_tunnel_cmd_status() {
    local json=false
    local brief=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json|-j) json=true; shift ;;
            --brief|-b) brief=true; shift ;;
            *) shift ;;
        esac
    done

    local enabled="${NFTBAN_TUNNEL_ENABLED:-NO}"
    local timer_active="false"
    systemctl is-active nftban-tunnel.timer &>/dev/null && timer_active="true"

    # DNS source detection
    local dns_type="none"
    local dns_path=""
    if nftban_tunnel_detect_dns_source 2>/dev/null; then
        dns_type="${TUNNEL_DNS_TYPE:-none}"
        dns_path="${TUNNEL_DNS_LOG_PATH:-}"
    fi

    # Load scores summary
    local total_tracked=0 high_count=0 medium_count=0 low_count=0
    local state_dir
    state_dir=$(nftban_tunnel_state_dir)
    if [[ -d "$state_dir" ]]; then
        while IFS='|' read -r _ip score level _signals _ts; do
            total_tracked=$((total_tracked + 1))
            case "$level" in
                HIGH) high_count=$((high_count + 1)) ;;
                MEDIUM) medium_count=$((medium_count + 1)) ;;
                LOW) low_count=$((low_count + 1)) ;;
            esac
        done < <(nftban_tunnel_load_scores 2>/dev/null)
    fi

    # Last scan time
    local last_scan=""
    local log_file="${NFTBAN_TUNNEL_LOG:-/var/log/nftban/tunnel.log}"
    if [[ -f "$log_file" ]]; then
        local last_line
        last_line=$(grep "|INFO|Scan complete" "$log_file" 2>/dev/null | tail -1 || true)
        if [[ -n "$last_line" ]]; then
            last_scan=$(echo "$last_line" | cut -d'|' -f1)
        fi
    fi

    if [[ "$json" == "true" ]]; then
        cat <<EOF
{
  "enabled": $([ "$enabled" = "YES" ] && echo "true" || echo "false"),
  "timer_active": $timer_active,
  "dns_source": "$dns_type",
  "dns_log_path": "$dns_path",
  "tracked_ips": $total_tracked,
  "high": $high_count,
  "medium": $medium_count,
  "low": $low_count,
  "last_scan": "$last_scan",
  "advisory_only": true
}
EOF
        return 0
    fi

    if [[ "$brief" == "true" ]]; then
        if [[ "$enabled" == "YES" ]]; then
            echo "ENABLED (H:$high_count M:$medium_count L:$low_count) dns=$dns_type"
        else
            echo "DISABLED"
        fi
        return 0
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "NFTBan Tunnel Suspicion Monitor"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    printf "  %-22s %s\n" "Status:" "$([ "$enabled" = "YES" ] && echo "ENABLED" || echo "DISABLED")"
    printf "  %-22s %s\n" "Timer:" "$([ "$timer_active" = "true" ] && echo "ACTIVE" || echo "INACTIVE")"
    printf "  %-22s %s\n" "DNS Source:" "$dns_type"
    [[ -n "$dns_path" && "$dns_path" != "journalctl" ]] && printf "  %-22s %s\n" "DNS Log:" "$dns_path"
    printf "  %-22s %s\n" "Mode:" "ADVISORY ONLY (never bans)"
    echo ""

    echo "  Suspicion Summary:"
    printf "    %-18s %d\n" "HIGH suspicion:" "$high_count"
    printf "    %-18s %d\n" "MEDIUM suspicion:" "$medium_count"
    printf "    %-18s %d\n" "LOW suspicion:" "$low_count"
    printf "    %-18s %d\n" "Total tracked:" "$total_tracked"
    echo ""

    if [[ -n "$last_scan" ]]; then
        printf "  %-22s %s\n" "Last scan:" "$last_scan"
    fi

    echo ""
    echo "  Commands:"
    echo "    nftban tunnel top        Show top suspects"
    echo "    nftban tunnel scan       Run scan now"
    echo "    nftban tunnel explain IP  Show signal breakdown"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# =============================================================================
# SUBCOMMAND: enable
# =============================================================================

_tunnel_cmd_enable() {
    if [[ $EUID -ne 0 ]]; then
        echo "Error: Must run as root to enable tunnel monitoring" >&2
        return 1
    fi

    # Check if timer exists
    if ! systemctl list-unit-files 2>/dev/null | grep -q "nftban-tunnel.timer"; then
        echo "Error: nftban-tunnel.timer not found" >&2
        echo "Please install nftban tunnel systemd units first" >&2
        return 1
    fi

    # Persist to config
    local local_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/tunnel/main.conf.local"
    mkdir -p "$(dirname "$local_conf")" || return 1
    if grep -q "^NFTBAN_TUNNEL_ENABLED=" "$local_conf" 2>/dev/null; then
        sed -i 's/^NFTBAN_TUNNEL_ENABLED=.*/NFTBAN_TUNNEL_ENABLED="YES"/' "$local_conf"
    else
        echo 'NFTBAN_TUNNEL_ENABLED="YES"' >> "$local_conf"
    fi

    # Create state directory
    local state_dir
    state_dir=$(nftban_tunnel_state_dir)
    mkdir -p "$state_dir" 2>/dev/null || true
    chown nftban:nftban "$state_dir" 2>/dev/null || true
    chmod 750 "$state_dir" 2>/dev/null || true

    # Enable and start timer
    systemctl daemon-reload
    systemctl enable nftban-tunnel.timer
    systemctl start nftban-tunnel.timer

    echo "Tunnel suspicion monitoring enabled (advisory-only)"
    echo ""
    echo "Next run:"
    systemctl status nftban-tunnel.timer 2>/dev/null | grep "Trigger:" || echo "  (Check: systemctl status nftban-tunnel.timer)"
    echo ""
    echo "Run 'nftban tunnel scan' to scan immediately"
}

# =============================================================================
# SUBCOMMAND: disable
# =============================================================================

_tunnel_cmd_disable() {
    if [[ $EUID -ne 0 ]]; then
        echo "Error: Must run as root to disable tunnel monitoring" >&2
        return 1
    fi

    # Persist to config
    local local_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/tunnel/main.conf.local"
    mkdir -p "$(dirname "$local_conf")" || return 1
    if grep -q "^NFTBAN_TUNNEL_ENABLED=" "$local_conf" 2>/dev/null; then
        sed -i 's/^NFTBAN_TUNNEL_ENABLED=.*/NFTBAN_TUNNEL_ENABLED="NO"/' "$local_conf"
    else
        echo 'NFTBAN_TUNNEL_ENABLED="NO"' >> "$local_conf"
    fi

    # Stop and disable timer
    systemctl stop nftban-tunnel.timer 2>/dev/null || true
    systemctl disable nftban-tunnel.timer 2>/dev/null || true

    echo "Tunnel suspicion monitoring disabled"
}

# =============================================================================
# SUBCOMMAND: scan
# =============================================================================

_tunnel_cmd_scan() {
    nftban_tunnel_scan "$@"
}

# =============================================================================
# SUBCOMMAND: top
# =============================================================================

_tunnel_cmd_top() {
    local limit=10
    local json=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --limit|-l)
                limit="${2:-10}"
                shift 2
                ;;
            --json|-j)
                json=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    local scores
    scores=$(nftban_tunnel_load_scores 2>/dev/null)

    if [[ -z "$scores" ]]; then
        if [[ "$json" == "true" ]]; then
            echo '{"suspects": []}'
        else
            echo "No tunnel suspicion data. Run 'nftban tunnel scan' first."
        fi
        return 0
    fi

    if [[ "$json" == "true" ]]; then
        echo '{"suspects": ['
        local first=true
        local count=0
        while IFS='|' read -r ip score level signals ts; do
            [[ $count -ge $limit ]] && break
            [[ "$first" == "true" ]] && first=false || echo ","
            local ts_human
            ts_human=$(date -d "@${ts}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$ts")
            echo "  {\"ip\": \"$ip\", \"score\": $score, \"level\": \"$level\", \"signals\": \"$signals\", \"last_seen\": \"$ts_human\"}"
            count=$((count + 1))
        done <<< "$scores"
        echo ""
        echo "]}"
        return 0
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "NFTBan Tunnel Suspicion — Top Suspects"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    printf "  %-6s %-40s %-8s %-8s\n" "SCORE" "IP ADDRESS" "LEVEL" "LAST SEEN"
    printf "  %-6s %-40s %-8s %-8s\n" "-----" "----------------------------------------" "--------" "--------"

    local count=0
    while IFS='|' read -r ip score level signals ts; do
        [[ $count -ge $limit ]] && break
        local ts_human
        ts_human=$(date -d "@${ts}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$ts")
        local age
        local now
        now=$(date +%s)
        local diff=$((now - ts))
        if [[ $diff -lt 3600 ]]; then
            age="$((diff / 60))m ago"
        elif [[ $diff -lt 86400 ]]; then
            age="$((diff / 3600))h ago"
        else
            age="$((diff / 86400))d ago"
        fi

        printf "  %-6d %-40s %-8s %s\n" "$score" "$ip" "$level" "$age"
        count=$((count + 1))
    done <<< "$scores"

    echo ""
    echo "  Advisory only — no IPs have been blocked"
    echo "  Use 'nftban tunnel explain <IP>' for signal breakdown"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# =============================================================================
# SUBCOMMAND: explain
# =============================================================================

_tunnel_cmd_explain() {
    local ip="${1:-}"
    local json=false

    if [[ -z "$ip" ]]; then
        echo "Usage: nftban tunnel explain <IP>" >&2
        return 1
    fi

    shift || true
    [[ "${1:-}" == "--json" || "${1:-}" == "-j" ]] && json=true

    # Load state for this IP
    local state_dir
    state_dir=$(nftban_tunnel_state_dir)
    local safe_ip="${ip//:/_}"
    local state_file="${state_dir}/${safe_ip}.state"

    if [[ ! -f "$state_file" ]]; then
        if [[ "$json" == "true" ]]; then
            echo "{\"error\": \"No data for IP $ip\"}"
        else
            echo "No tunnel suspicion data for IP: $ip"
            echo "Run 'nftban tunnel scan' to collect data"
        fi
        return 1
    fi

    local line
    line=$(head -1 "$state_file")
    local ts score level signals
    IFS='|' read -r ts score level signals <<< "$line"

    # Parse signals: AVG_ENTROPY|TXT_RATIO|MAX_DEPTH|QUERY_COUNT|NXDOMAIN_RATIO
    local avg_entropy txt_ratio max_depth query_count nxdomain_ratio
    IFS='|' read -r avg_entropy txt_ratio max_depth query_count nxdomain_ratio <<< "$signals"

    local ts_human
    ts_human=$(date -d "@${ts}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$ts")

    # Load thresholds
    local entropy_thresh="${NFTBAN_TUNNEL_ENTROPY_THRESHOLD:-3.5}"
    local txt_thresh="${NFTBAN_TUNNEL_TXT_RATIO_THRESHOLD:-0.15}"
    local depth_thresh="${NFTBAN_TUNNEL_SUBDOMAIN_DEPTH_THRESHOLD:-4}"
    local volume_thresh="${NFTBAN_TUNNEL_QUERY_VOLUME_THRESHOLD:-100}"
    local nxdomain_thresh="${NFTBAN_TUNNEL_NXDOMAIN_RATIO_THRESHOLD:-0.20}"

    if [[ "$json" == "true" ]]; then
        cat <<EOF
{
  "ip": "$ip",
  "score": $score,
  "level": "$level",
  "last_scan": "$ts_human",
  "signals": {
    "label_entropy": {"value": $avg_entropy, "threshold": $entropy_thresh, "weight": ${NFTBAN_TUNNEL_WEIGHT_ENTROPY:-25}},
    "txt_frequency": {"value": $txt_ratio, "threshold": $txt_thresh, "weight": ${NFTBAN_TUNNEL_WEIGHT_TXT_FREQ:-20}},
    "subdomain_depth": {"value": $max_depth, "threshold": $depth_thresh, "weight": ${NFTBAN_TUNNEL_WEIGHT_SUBDOMAIN_DEPTH:-20}},
    "query_volume": {"value": $query_count, "threshold": $volume_thresh, "weight": ${NFTBAN_TUNNEL_WEIGHT_QUERY_VOLUME:-20}},
    "nxdomain_ratio": {"value": $nxdomain_ratio, "threshold": $nxdomain_thresh, "weight": ${NFTBAN_TUNNEL_WEIGHT_NXDOMAIN_RATIO:-15}}
  },
  "advisory_only": true
}
EOF
        return 0
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "NFTBan Tunnel Suspicion — Signal Breakdown"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    printf "  %-22s %s\n" "IP Address:" "$ip"
    printf "  %-22s %d / 100\n" "Composite Score:" "$score"
    printf "  %-22s %s\n" "Suspicion Level:" "$level"
    printf "  %-22s %s\n" "Last Scanned:" "$ts_human"
    echo ""

    echo "  Signal Breakdown:"
    echo "  ┌──────────────────────┬──────────┬───────────┬────────┐"
    echo "  │ Signal               │ Value    │ Threshold │ Weight │"
    echo "  ├──────────────────────┼──────────┼───────────┼────────┤"
    printf "  │ %-20s │ %8s │ %9s │ %5s%% │\n" "Label Entropy" "$avg_entropy" "$entropy_thresh" "${NFTBAN_TUNNEL_WEIGHT_ENTROPY:-25}"
    printf "  │ %-20s │ %8s │ %9s │ %5s%% │\n" "TXT Frequency" "$txt_ratio" "$txt_thresh" "${NFTBAN_TUNNEL_WEIGHT_TXT_FREQ:-20}"
    printf "  │ %-20s │ %8s │ %9s │ %5s%% │\n" "Subdomain Depth" "$max_depth" "$depth_thresh" "${NFTBAN_TUNNEL_WEIGHT_SUBDOMAIN_DEPTH:-20}"
    printf "  │ %-20s │ %8s │ %9s │ %5s%% │\n" "Query Volume" "$query_count" "$volume_thresh" "${NFTBAN_TUNNEL_WEIGHT_QUERY_VOLUME:-20}"
    printf "  │ %-20s │ %8s │ %9s │ %5s%% │\n" "NXDOMAIN Ratio" "$nxdomain_ratio" "$nxdomain_thresh" "${NFTBAN_TUNNEL_WEIGHT_NXDOMAIN_RATIO:-15}"
    echo "  └──────────────────────┴──────────┴───────────┴────────┘"
    echo ""

    # Interpretation
    echo "  Interpretation:"
    local _warn=""
    # Check each signal against threshold using awk for float comparison
    if awk "BEGIN {exit !($avg_entropy >= $entropy_thresh)}" 2>/dev/null; then
        echo "    - Label entropy ($avg_entropy) exceeds threshold ($entropy_thresh)"
        echo "      Subdomain labels contain high-entropy data (possible encoded payload)"
        _warn=1
    fi
    if awk "BEGIN {exit !($txt_ratio >= $txt_thresh)}" 2>/dev/null; then
        echo "    - TXT query ratio ($txt_ratio) exceeds threshold ($txt_thresh)"
        echo "      Abnormally high TXT record usage (common in DNS data channels)"
        _warn=1
    fi
    if [[ "$max_depth" -ge "$depth_thresh" ]]; then
        echo "    - Subdomain depth ($max_depth) exceeds threshold ($depth_thresh)"
        echo "      Deeply nested labels suggest data encoding in DNS names"
        _warn=1
    fi
    if [[ "$query_count" -ge "$volume_thresh" ]]; then
        echo "    - Query volume ($query_count) exceeds threshold ($volume_thresh)"
        echo "      Abnormally high DNS query rate from this source"
        _warn=1
    fi
    if awk "BEGIN {exit !($nxdomain_ratio >= $nxdomain_thresh)}" 2>/dev/null; then
        echo "    - NXDOMAIN ratio ($nxdomain_ratio) exceeds threshold ($nxdomain_thresh)"
        echo "      High rate of non-existent domain responses"
        _warn=1
    fi
    if [[ -z "$_warn" ]]; then
        echo "    No signals exceed their thresholds. Score is below detection level."
    fi
    echo ""
    echo "  Advisory only — no action has been taken against this IP"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# =============================================================================
# SUBCOMMAND: config
# =============================================================================

_tunnel_cmd_config() {
    local json=false
    [[ "${1:-}" == "--json" || "${1:-}" == "-j" ]] && json=true

    if [[ "$json" == "true" ]]; then
        cat <<EOF
{
  "enabled": $([ "${NFTBAN_TUNNEL_ENABLED:-NO}" = "YES" ] && echo "true" || echo "false"),
  "scan_interval_min": ${NFTBAN_TUNNEL_SCAN_INTERVAL:-5},
  "dns_source": "${NFTBAN_TUNNEL_DNS_SOURCE:-auto}",
  "thresholds": {
    "low": ${NFTBAN_TUNNEL_THRESHOLD_LOW:-30},
    "medium": ${NFTBAN_TUNNEL_THRESHOLD_MEDIUM:-60},
    "high": ${NFTBAN_TUNNEL_THRESHOLD_HIGH:-80}
  },
  "weights": {
    "entropy": ${NFTBAN_TUNNEL_WEIGHT_ENTROPY:-25},
    "txt_freq": ${NFTBAN_TUNNEL_WEIGHT_TXT_FREQ:-20},
    "subdomain_depth": ${NFTBAN_TUNNEL_WEIGHT_SUBDOMAIN_DEPTH:-20},
    "query_volume": ${NFTBAN_TUNNEL_WEIGHT_QUERY_VOLUME:-20},
    "nxdomain_ratio": ${NFTBAN_TUNNEL_WEIGHT_NXDOMAIN_RATIO:-15}
  },
  "signal_thresholds": {
    "entropy": ${NFTBAN_TUNNEL_ENTROPY_THRESHOLD:-3.5},
    "txt_ratio": ${NFTBAN_TUNNEL_TXT_RATIO_THRESHOLD:-0.15},
    "subdomain_depth": ${NFTBAN_TUNNEL_SUBDOMAIN_DEPTH_THRESHOLD:-4},
    "query_volume": ${NFTBAN_TUNNEL_QUERY_VOLUME_THRESHOLD:-100},
    "nxdomain_ratio": ${NFTBAN_TUNNEL_NXDOMAIN_RATIO_THRESHOLD:-0.20}
  },
  "state_ttl_hours": ${NFTBAN_TUNNEL_STATE_TTL:-24},
  "max_tracked_ips": ${NFTBAN_TUNNEL_MAX_TRACKED_IPS:-1000},
  "alert_on_high": $([ "${NFTBAN_TUNNEL_ALERT_ON_HIGH:-YES}" = "YES" ] && echo "true" || echo "false"),
  "alert_cooldown_sec": ${NFTBAN_TUNNEL_ALERT_COOLDOWN:-3600}
}
EOF
        return 0
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "NFTBan Tunnel Suspicion — Configuration"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    printf "  %-30s %s\n" "Enabled:" "${NFTBAN_TUNNEL_ENABLED:-NO}"
    printf "  %-30s %s min\n" "Scan Interval:" "${NFTBAN_TUNNEL_SCAN_INTERVAL:-5}"
    printf "  %-30s %s\n" "DNS Source:" "${NFTBAN_TUNNEL_DNS_SOURCE:-auto}"
    echo ""
    echo "  Suspicion Thresholds:"
    printf "    %-26s %s\n" "LOW:" ">= ${NFTBAN_TUNNEL_THRESHOLD_LOW:-30}"
    printf "    %-26s %s\n" "MEDIUM:" ">= ${NFTBAN_TUNNEL_THRESHOLD_MEDIUM:-60}"
    printf "    %-26s %s\n" "HIGH:" ">= ${NFTBAN_TUNNEL_THRESHOLD_HIGH:-80}"
    echo ""
    echo "  Signal Weights (sum=100):"
    printf "    %-26s %s%%\n" "Label Entropy:" "${NFTBAN_TUNNEL_WEIGHT_ENTROPY:-25}"
    printf "    %-26s %s%%\n" "TXT Frequency:" "${NFTBAN_TUNNEL_WEIGHT_TXT_FREQ:-20}"
    printf "    %-26s %s%%\n" "Subdomain Depth:" "${NFTBAN_TUNNEL_WEIGHT_SUBDOMAIN_DEPTH:-20}"
    printf "    %-26s %s%%\n" "Query Volume:" "${NFTBAN_TUNNEL_WEIGHT_QUERY_VOLUME:-20}"
    printf "    %-26s %s%%\n" "NXDOMAIN Ratio:" "${NFTBAN_TUNNEL_WEIGHT_NXDOMAIN_RATIO:-15}"
    echo ""
    echo "  Signal Thresholds:"
    printf "    %-26s %s bits/char\n" "Entropy:" "${NFTBAN_TUNNEL_ENTROPY_THRESHOLD:-3.5}"
    printf "    %-26s %s\n" "TXT Ratio:" "${NFTBAN_TUNNEL_TXT_RATIO_THRESHOLD:-0.15}"
    printf "    %-26s %s labels\n" "Subdomain Depth:" "${NFTBAN_TUNNEL_SUBDOMAIN_DEPTH_THRESHOLD:-4}"
    printf "    %-26s %s queries/interval\n" "Query Volume:" "${NFTBAN_TUNNEL_QUERY_VOLUME_THRESHOLD:-100}"
    printf "    %-26s %s\n" "NXDOMAIN Ratio:" "${NFTBAN_TUNNEL_NXDOMAIN_RATIO_THRESHOLD:-0.20}"
    echo ""
    echo "  State:"
    printf "    %-26s %s hours\n" "TTL:" "${NFTBAN_TUNNEL_STATE_TTL:-24}"
    printf "    %-26s %s\n" "Max Tracked IPs:" "${NFTBAN_TUNNEL_MAX_TRACKED_IPS:-1000}"
    printf "    %-26s %s\n" "State Dir:" "$(nftban_tunnel_state_dir)"
    echo ""
    echo "  Config files:"
    echo "    ${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/tunnel/main.conf"
    echo "    ${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/tunnel/main.conf.local"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# =============================================================================
# USAGE
# =============================================================================

_tunnel_cmd_usage() {
    cat <<'EOF'
Usage: nftban tunnel <subcommand> [options]

DNS Tunnel Suspicion Monitoring (ADVISORY ONLY — never bans)

SUBCOMMANDS:
  status       Show monitoring status and summary
  enable       Enable scheduled tunnel scans (systemd timer)
  disable      Disable scheduled tunnel scans
  scan         Run a tunnel suspicion scan now
  top          Show top suspected IPs by score
  explain IP   Show detailed signal breakdown for an IP
  config       Show current configuration

OPTIONS:
  --json, -j   Output in JSON format (status, top, explain, config)
  --brief, -b  One-line summary (status only)
  --limit N    Number of results (top only, default: 10)
  --quiet, -q  Minimal output (scan only, for timer use)

EXAMPLES:
  nftban tunnel enable               Enable monitoring
  nftban tunnel status               Show status summary
  nftban tunnel scan                 Scan DNS logs now
  nftban tunnel top                  Show top 10 suspects
  nftban tunnel top --limit 20       Show top 20 suspects
  nftban tunnel explain 192.168.1.1  Signal breakdown for IP
  nftban tunnel config --json        Show config in JSON

SIGNALS:
  1. Label Entropy    — high-entropy subdomain labels (encoded data)
  2. TXT Frequency    — excessive TXT record queries (data channel)
  3. Subdomain Depth  — deeply nested subdomains (data encoding)
  4. Query Volume     — abnormally high query rate
  5. NXDOMAIN Ratio   — high non-existent domain responses

EOF
}

# Export functions
export -f nftban_cmd_tunnel

# =============================================================================
# EXECUTE IF RUN DIRECTLY
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_tunnel "$@"
fi
