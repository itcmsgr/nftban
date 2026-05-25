#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.3.0 - Firewall Logs Command (real-time-like viewer)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: On-demand firewall log viewer with filtering and live mode
#
# meta:name="cmd_firewall_logs"
# meta:type="cli"
# meta:header="Firewall Logs Command"
# meta:version="1.50.1"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="real-time-like firewall log viewer with structured logging"
# meta:inventory.files="/etc/nftban/conf.d/fwlog.conf"
# meta:inventory.binaries="journalctl,nft"
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/conf.d/fwlog.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root (for enable/disable)"
#
# meta:created_date="2026-01-23"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# Prevent double-loading
[[ -n "${NFTBAN_CLI_FWLOGS_LOADED:-}" ]] && return 0
readonly NFTBAN_CLI_FWLOGS_LOADED=1

# =============================================================================
# CONFIGURATION
# =============================================================================

: "${NFTBAN_CONFIG_DIR:=/etc/nftban}"
readonly FWLOG_CONFIG="${NFTBAN_CONFIG_DIR}/conf.d/fwlog.conf"
readonly FWLOG_INCLUDE="${NFTBAN_CONFIG_DIR}/nftables.d/fwlog.nft"

# Structured log prefix for reliable parsing
readonly LOG_PREFIX="NFTBAN_FW"

# Base schema prefixes (always present in nft rules, no enable needed)
readonly BASE_SCHEMA_PREFIXES="nftban:|NFTBAN_PORTSCAN|NFTBAN_EGRESS_AUDIT"

# Default settings
readonly DEFAULT_LINES=50
readonly DEFAULT_INTERVAL=3
readonly DEFAULT_RATE="10/second"
readonly DEFAULT_BURST="50 packets"

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

_fwlog_die() {
    echo "ERROR: $*" >&2
    return 1
}

_fwlog_info() {
    echo "  $*"
}

_fwlog_ok() {
    echo "  [OK] $*"
}

_fwlog_warn() {
    echo "  [WARN] $*" >&2
}

# =============================================================================
# CONFIGURATION MANAGEMENT
# =============================================================================

_fwlog_load_config() {
    # Set defaults
    FWLOG_ENABLED="false"
    FWLOG_LEVEL="drops"
    FWLOG_REASONS="banlist,invalid_state,policy_drop"
    FWLOG_RATE="$DEFAULT_RATE"
    FWLOG_BURST="$DEFAULT_BURST"

    # Load config if exists
    if [[ -f "$FWLOG_CONFIG" ]]; then
        # shellcheck source=/dev/null
        source "$FWLOG_CONFIG" || true
    fi
}

_fwlog_save_config() {
    mkdir -p "$(dirname "$FWLOG_CONFIG")" || return 1
    cat > "$FWLOG_CONFIG" <<EOF
# NFTBan Firewall Logging Configuration
# Generated: $(date -Iseconds)

FWLOG_ENABLED="${FWLOG_ENABLED}"
FWLOG_LEVEL="${FWLOG_LEVEL}"
FWLOG_REASONS="${FWLOG_REASONS}"
FWLOG_RATE="${FWLOG_RATE}"
FWLOG_BURST="${FWLOG_BURST}"
EOF
}

# =============================================================================
# NFTABLES LOG RULES GENERATION
# =============================================================================

_fwlog_generate_rules() {
    local level="$1"
    local reasons="$2"
    local rate="$3"
    local burst="$4"

    mkdir -p "$(dirname "$FWLOG_INCLUDE")" || return 1

    cat > "$FWLOG_INCLUDE" <<EOF
# =============================================================================
# NFTBan Firewall Logging Rules (auto-generated)
# Level: ${level}
# Reasons: ${reasons}
# Rate: ${rate} burst ${burst}
# Generated: $(date -Iseconds)
# =============================================================================
# Rate-limited logging chains to prevent kernel/journald spam under attack
# These chains are added to existing ip/ip6 nftban tables
# =============================================================================

EOF

    # Generate chains for both IPv4 and IPv6 tables
    for family in ip ip6; do
        cat >> "$FWLOG_INCLUDE" <<EOF
table ${family} nftban {
EOF

        # Generate DROP logging chains based on reasons
        if [[ "$level" == "drops" ]] || [[ "$level" == "all" ]] || [[ "$level" == "alert" ]]; then
            IFS=',' read -ra reason_array <<< "$reasons"
            for reason in "${reason_array[@]}"; do
                reason=$(echo "$reason" | tr -d ' ')
                cat >> "$FWLOG_INCLUDE" <<EOF
    chain nftban_fwlog_drop_${reason} {
        limit rate ${rate} burst ${burst} counter log prefix "${LOG_PREFIX} action=DROP reason=${reason} " flags all
        return
    }
EOF
            done

            # Generic drop chain
            cat >> "$FWLOG_INCLUDE" <<EOF
    chain nftban_fwlog_drop {
        limit rate ${rate} burst ${burst} counter log prefix "${LOG_PREFIX} action=DROP reason=policy_drop " flags all
        return
    }
EOF
        fi

        # Generate ACCEPT logging chains
        if [[ "$level" == "accepts" ]] || [[ "$level" == "all" ]]; then
            cat >> "$FWLOG_INCLUDE" <<EOF
    chain nftban_fwlog_accept {
        limit rate ${rate} burst ${burst} counter log prefix "${LOG_PREFIX} action=ACCEPT reason=allowed " flags all
        return
    }
EOF
        fi

        # Close table block
        cat >> "$FWLOG_INCLUDE" <<EOF
}

EOF
    done

    # Add usage comment
    cat >> "$FWLOG_INCLUDE" <<EOF
# Usage: Add 'jump nftban_fwlog_drop_<reason>' before drop statements
# Example: In main chain: jump nftban_fwlog_drop_banlist; drop
EOF
}

_fwlog_remove_rules() {
    rm -f "$FWLOG_INCLUDE"
}

_fwlog_reload_nftables() {
    # Reload nftables to apply changes
    if command -v nftban &>/dev/null; then
        nftban firewall reload 2>/dev/null || true
    elif command -v nft &>/dev/null; then
        # Resolve nftables config from distro config
        local nft_conf
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/lib/nftban_distro_config.sh" 2>/dev/null || true
        nft_conf=$(nftban_distro_get_path "nftables_conf" 2>/dev/null)
        [[ -z "$nft_conf" ]] && nft_conf="/etc/nftables.conf"
        nft -f "$nft_conf" 2>/dev/null || true
    fi
}

# =============================================================================
# ENABLE/DISABLE COMMANDS
# =============================================================================

_fwlog_enable() {
    local level="drops"
    local reasons=""
    local rate="$DEFAULT_RATE"
    local burst="$DEFAULT_BURST"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --level)
                level="${2:-drops}"
                shift 2
                ;;
            --reason|--reasons)
                reasons="${2:-}"
                shift 2
                ;;
            --rate)
                rate="${2:-$DEFAULT_RATE}"
                shift 2
                ;;
            --burst)
                burst="${2:-$DEFAULT_BURST}"
                shift 2
                ;;
            *)
                _fwlog_die "Unknown option: $1"
                ;;
        esac
    done

    # Validate level
    case "$level" in
        drops|accepts|all|alert|off)
            ;;
        *)
            _fwlog_die "Invalid level: $level (expected: drops, accepts, all, alert)"
            ;;
    esac

    # Set default reasons based on level
    if [[ -z "$reasons" ]]; then
        case "$level" in
            alert)
                reasons="banlist,invalid_state"
                ;;
            *)
                reasons="banlist,invalid_state,ratelimit,policy_drop"
                ;;
        esac
    fi

    # Save configuration
    FWLOG_ENABLED="true"
    FWLOG_LEVEL="$level"
    FWLOG_REASONS="$reasons"
    FWLOG_RATE="$rate"
    FWLOG_BURST="$burst"
    _fwlog_save_config

    # Generate nftables rules
    _fwlog_generate_rules "$level" "$reasons" "$rate" "$burst"

    # Reload
    _fwlog_reload_nftables

    echo ""
    echo "Firewall logging ENABLED"
    echo "  Level:   $level"
    echo "  Reasons: $reasons"
    echo "  Rate:    $rate burst $burst"
    echo ""
    echo "View logs: nftban firewall logs show"
    echo "Live mode: nftban firewall logs show --live"
}

_fwlog_disable() {
    _fwlog_load_config

    FWLOG_ENABLED="false"
    _fwlog_save_config

    _fwlog_remove_rules
    _fwlog_reload_nftables

    echo ""
    echo "Firewall logging DISABLED"
    echo "  No performance overhead when disabled"
}

_fwlog_status() {
    _fwlog_load_config

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NFTBan Firewall Logging Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if [[ "$FWLOG_ENABLED" == "true" ]]; then
        echo "  Status:  ENABLED"
        echo "  Level:   $FWLOG_LEVEL"
        echo "  Reasons: $FWLOG_REASONS"
        echo "  Rate:    $FWLOG_RATE burst $FWLOG_BURST"
    else
        echo "  Status:  DISABLED"
        echo "  (Zero performance overhead)"
    fi

    echo ""
    echo "  Log source:  journalctl -k (kernel messages)"
    echo "  Config:      $FWLOG_CONFIG"

    if [[ -f "$FWLOG_INCLUDE" ]]; then
        echo "  Rules:       $FWLOG_INCLUDE"
    fi

    echo ""

    # Show recent log counts — both structured and base schema
    local structured_count base_count
    local journal_hour
    journal_hour=$(journalctl -k --since "1 hour ago" --no-pager 2>/dev/null || true)
    structured_count=$(echo "$journal_hour" | grep -c -F "$LOG_PREFIX" || true)
    structured_count=${structured_count:-0}
    base_count=$(echo "$journal_hour" | grep -c -E "$BASE_SCHEMA_PREFIXES" || true)
    base_count=${base_count:-0}

    echo "  Logs (last hour):"
    echo "    Structured (NFTBAN_FW):    $structured_count entries"
    echo "    Base schema (nftban:drop): $base_count entries"
    echo ""
    if [[ "$FWLOG_ENABLED" != "true" ]] && [[ "$base_count" -gt 0 ]]; then
        echo "  Base schema logs are available. View with: nftban firewall logs show"
        echo ""
    fi
}

# =============================================================================
# LOG PARSING
# =============================================================================

_fwlog_parse_to_tsv() {
    # Parse kernel log lines to TSV — handles BOTH formats:
    #   1. Structured: NFTBAN_FW action=DROP reason=policy_drop SRC=... DPT=...
    #   2. Base schema: nftban: drop: SRC=... DPT=...
    #   3. Portscan:    NFTBAN_PORTSCAN:SYN SRC=... DPT=...
    #   4. Egress:      NFTBAN_EGRESS_AUDIT: SRC=... DPT=...
    # Output: time action reason proto src srcport dst dstport
    awk '
    function extract_kv(line, key,   r, start, end) {
        r = ""
        start = index(line, key"=")
        if (start > 0) {
            start += length(key) + 1
            end = start
            while (end <= length(line) && substr(line, end, 1) != " ") end++
            r = substr(line, start, end - start)
        }
        return r
    }

    /NFTBAN_FW|nftban:|NFTBAN_PORTSCAN|NFTBAN_EGRESS_AUDIT/ {
        # Timestamp from short-iso format: 2026-01-23T20:57:20+0200
        ts = substr($1, 1, 19)
        gsub("T", " ", ts)

        action = ""; reason = ""

        # Format 1: Structured (NFTBAN_FW action=DROP reason=...)
        if (index($0, "NFTBAN_FW") > 0) {
            action = extract_kv($0, "action")
            reason = extract_kv($0, "reason")
        }
        # Format 2: Base schema (nftban: drop: ...)
        else if (index($0, "nftban: drop:") > 0) {
            action = "DROP"
            reason = "base_drop"
        }
        else if (index($0, "nftban: accept:") > 0) {
            action = "ACCEPT"
            reason = "base_accept"
        }
        # Format 3: Portscan (NFTBAN_PORTSCAN:SYN / :UDP)
        else if (index($0, "NFTBAN_PORTSCAN") > 0) {
            action = "DROP"
            if (index($0, "NFTBAN_PORTSCAN:SYN") > 0) reason = "portscan_syn"
            else if (index($0, "NFTBAN_PORTSCAN:UDP") > 0) reason = "portscan_udp"
            else reason = "portscan"
        }
        # Format 4: Egress audit (NFTBAN_EGRESS_AUDIT:)
        else if (index($0, "NFTBAN_EGRESS_AUDIT") > 0) {
            action = "AUDIT"
            reason = "egress_audit"
        }

        # Extract from kernel nft log fields (common to all formats)
        proto = extract_kv($0, "PROTO")
        src   = extract_kv($0, "SRC")
        dst   = extract_kv($0, "DST")
        spt   = extract_kv($0, "SPT")
        dpt   = extract_kv($0, "DPT")

        # Defaults for missing fields
        if (action == "") action = "-"
        if (reason == "") reason = "-"
        if (proto == "") proto = "-"
        if (src == "") src = "-"
        if (dst == "") dst = "-"
        if (spt == "") spt = "-"
        if (dpt == "") dpt = "-"

        print ts "\t" action "\t" reason "\t" proto "\t" src "\t" spt "\t" dst "\t" dpt
    }
    '
}

_fwlog_filter_tsv() {
    local ip="$1"
    local src="$2"
    local dst="$3"
    local port="$4"
    local proto="$5"
    local action="$6"
    local reason="$7"

    awk -F'\t' \
        -v ip="$ip" \
        -v srcf="$src" \
        -v dstf="$dst" \
        -v portf="$port" \
        -v protof="$proto" \
        -v actionf="$action" \
        -v reasonf="$reason" \
    '
    {
        time=$1; act=$2; rsn=$3; pro=$4; src=$5; spt=$6; dst=$7; dpt=$8

        if (actionf != "" && toupper(act) != toupper(actionf)) next
        if (reasonf != "" && rsn != reasonf) next
        if (protof != "" && tolower(pro) != tolower(protof)) next

        if (ip != "" && src != ip && dst != ip) next
        if (srcf != "" && src != srcf) next
        if (dstf != "" && dst != dstf) next

        if (portf != "") {
            if (spt != portf && dpt != portf) next
        }

        print $0
    }
    '
}

# =============================================================================
# OUTPUT FORMATTERS
# =============================================================================

_fwlog_print_table() {
    # real-time-style table output
    {
        echo -e "Time\tAction\tReason\tProto\tSource\tSPort\tDestination\tDPort"
        cat
    } | column -t -s $'\t' 2>/dev/null || cat
}

_fwlog_print_fancy() {
    # Compact styled output format
    echo "┌─ NFTBan Firewall Log ────────────────────────────────────────────────────────┐"
    printf "│ %-12s │ %-6s │ %-12s │ %-5s │ %-21s │ %-21s │\n" \
        "Time" "Action" "Reason" "Proto" "Source" "Destination"
    echo "├──────────────┼────────┼──────────────┼───────┼───────────────────────┼───────────────────────┤"

    awk -F'\t' '{
        time = substr($1, 12, 8)  # Extract HH:MM:SS
        action = $2
        reason = substr($3, 1, 12)
        proto = $4
        src = $5 ":" $6
        dst = $7 ":" $8

        # Truncate if needed
        if (length(src) > 21) src = substr(src, 1, 18) "..."
        if (length(dst) > 21) dst = substr(dst, 1, 18) "..."

        printf "│ %-12s │ %-6s │ %-12s │ %-5s │ %-21s │ %-21s │\n", \
            time, action, reason, proto, src, dst
    }'

    echo "└──────────────┴────────┴──────────────┴───────┴───────────────────────┴───────────────────────┘"
}

_fwlog_print_csv() {
    echo "time,action,reason,proto,src,src_port,dst,dst_port"
    awk -F'\t' 'BEGIN{OFS=","} {print $1,$2,$3,$4,$5,$6,$7,$8}'
}

_fwlog_print_json() {
    echo "["
    awk -F'\t' '
    BEGIN { first = 1 }
    {
        if (!first) print ","
        printf "  {\"time\":\"%s\",\"action\":\"%s\",\"reason\":\"%s\",\"proto\":\"%s\",\"src\":\"%s\",\"src_port\":\"%s\",\"dst\":\"%s\",\"dst_port\":\"%s\"}", \
            $1, $2, $3, $4, $5, $6, $7, $8
        first = 0
    }
    END { print "\n]" }
    '
}

# =============================================================================
# SHOW COMMAND
# =============================================================================

_fwlog_show() {
    local lines="$DEFAULT_LINES"
    local since=""
    local live="0"
    local interval="$DEFAULT_INTERVAL"

    local ip="" src="" dst="" port="" proto="" action="" reason=""
    local output="fancy"  # fancy|table|json|csv|raw

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --lines|-n)
                lines="${2:-$DEFAULT_LINES}"
                shift 2
                ;;
            --since)
                since="${2:-}"
                shift 2
                ;;
            --live|-f)
                live="1"
                shift
                ;;
            --interval|-i)
                interval="${2:-$DEFAULT_INTERVAL}"
                shift 2
                ;;
            --ip)
                ip="${2:-}"
                shift 2
                ;;
            --src)
                src="${2:-}"
                shift 2
                ;;
            --dst)
                dst="${2:-}"
                shift 2
                ;;
            --port)
                port="${2:-}"
                shift 2
                ;;
            --proto)
                proto="${2:-}"
                shift 2
                ;;
            --action)
                action="${2:-}"
                shift 2
                ;;
            --reason)
                reason="${2:-}"
                shift 2
                ;;
            --json)
                output="json"
                shift
                ;;
            --csv)
                output="csv"
                shift
                ;;
            --table)
                output="table"
                shift
                ;;
            --raw)
                output="raw"
                shift
                ;;
            *)
                _fwlog_die "Unknown option: $1"
                ;;
        esac
    done

    # Live mode with countdown timer
    if [[ "$live" == "1" ]]; then
        _fwlog_live_view "$interval" "$lines" "$since" "$ip" "$src" "$dst" "$port" "$proto" "$action" "$reason" "$output"
        return
    fi

    # One-shot query
    _fwlog_query_and_display "$lines" "$since" "$ip" "$src" "$dst" "$port" "$proto" "$action" "$reason" "$output"
}

_fwlog_query_and_display() {
    local lines="$1"
    local since="$2"
    local ip="$3"
    local src="$4"
    local dst="$5"
    local port="$6"
    local proto="$7"
    local action="$8"
    local reason="$9"
    local output="${10}"

    # Build journalctl command
    local cmd=(journalctl -k -o short-iso --no-pager)

    if [[ -n "$since" ]]; then
        cmd+=(--since "$since")
    fi

    if [[ -n "$lines" ]]; then
        cmd+=(-n "$lines")
    fi

    # Execute and filter — search for structured AND base schema prefixes
    local raw_logs="" log_source=""

    # 1. Try structured logs first (NFTBAN_FW prefix from "logs enable")
    raw_logs=$("${cmd[@]}" 2>/dev/null | grep -F "$LOG_PREFIX" || true)
    if [[ -n "$raw_logs" ]]; then
        log_source="structured"
    fi

    # 2. Also search base schema logs (nftban: drop:, NFTBAN_PORTSCAN:, etc.)
    local base_logs=""
    base_logs=$("${cmd[@]}" 2>/dev/null | grep -E "$BASE_SCHEMA_PREFIXES" || true)
    if [[ -n "$base_logs" ]]; then
        if [[ -n "$raw_logs" ]]; then
            # Merge both (structured + base), deduplicate
            raw_logs=$(printf '%s\n%s' "$raw_logs" "$base_logs" | sort -u)
            log_source="both"
        else
            raw_logs="$base_logs"
            log_source="base"
        fi
    fi

    if [[ -z "$raw_logs" ]]; then
        echo "No firewall log entries found."
        echo ""
        echo "Tips:"
        echo "  - Enable structured logging: nftban firewall logs enable"
        echo "  - Check status:              nftban firewall logs status"
        echo "  - Base schema drops are logged with prefix 'nftban: drop:'"
        return 0
    fi

    if [[ "$log_source" == "base" ]]; then
        echo "  [INFO] Showing base schema logs (structured logging not enabled)"
        echo "         Enable structured logging for richer filtering: nftban firewall logs enable"
        echo ""
    fi

    if [[ "$output" == "raw" ]]; then
        echo "$raw_logs"
        return 0
    fi

    # Parse and filter — use combined parser for both formats
    local filtered
    filtered=$(echo "$raw_logs" | _fwlog_parse_to_tsv | _fwlog_filter_tsv "$ip" "$src" "$dst" "$port" "$proto" "$action" "$reason")

    if [[ -z "$filtered" ]]; then
        echo "No entries match your filter criteria."
        return 0
    fi

    # Format output
    case "$output" in
        fancy)
            echo "$filtered" | _fwlog_print_fancy
            ;;
        table)
            echo "$filtered" | _fwlog_print_table
            ;;
        json)
            echo "$filtered" | _fwlog_print_json
            ;;
        csv)
            echo "$filtered" | _fwlog_print_csv
            ;;
    esac

    # Show count
    local count
    count=$(echo "$filtered" | wc -l)
    echo ""
    echo "Showing $count entries"
}

_fwlog_live_view() {
    local interval="$1"
    local lines="$2"
    local since="$3"
    local ip="$4"
    local src="$5"
    local dst="$6"
    local port="$7"
    local proto="$8"
    local action="$9"
    local reason="${10}"
    local output="${11}"

    echo "Starting live firewall log viewer (Ctrl+C to stop)"
    echo "Refresh interval: ${interval}s"
    echo ""

    trap 'echo ""; echo "Live view stopped."; exit 0' INT TERM

    while true; do
        clear
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  NFTBan Firewall Log (LIVE)"
        echo "  $(date '+%Y-%m-%d %H:%M:%S')  |  Interval: ${interval}s  |  Ctrl+C to stop"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""

        _fwlog_query_and_display "$lines" "$since" "$ip" "$src" "$dst" "$port" "$proto" "$action" "$reason" "$output"

        # Countdown timer
        local i
        for ((i=interval; i>=1; i--)); do
            printf "\rRefreshing in %2ds... " "$i"
            sleep 1
        done
        echo ""
    done
}

# =============================================================================
# HELP
# =============================================================================

_fwlog_help() {
    # V127 UX-5 D-8: alias display. nftban firewall-logs is the hyphenated
    # alias dispatched through cli/sbin/nftban (special-case routing) to the
    # underlying `nftban firewall logs` two-word command implemented in this
    # file. Surfaced here so operators reading `nftban firewall-logs help`
    # understand the relationship and can choose either form.
    # (Scope: AUDIT_190_LIFECYCLE/V127_FULL_UX_CORRECTION_UMBRELLA_SCOPE.md UX-5)
    cat <<'EOF'
NFTBan Firewall Logs - real-time-like firewall log viewer

ALIAS:
    nftban firewall-logs   -> alias for `nftban firewall logs`
    Both forms accept the same subcommands and options.

USAGE:
    nftban firewall logs <COMMAND> [OPTIONS]

COMMANDS:
    enable      Enable firewall logging (modifies nftables rules)
    disable     Disable firewall logging (zero overhead)
    status      Show logging configuration and statistics
    show        View and filter firewall logs

ENABLE OPTIONS:
    --level <LEVEL>      Logging level: drops, accepts, all, alert
                         (default: drops)
    --reason <REASONS>   Comma-separated reasons to log:
                         banlist, invalid_state, ratelimit, policy_drop
    --rate <RATE>        Rate limit (default: 10/second)
    --burst <BURST>      Burst limit (default: 50 packets)

SHOW OPTIONS:
    --lines, -n <N>      Number of entries (default: 50)
    --since <TIME>       Time filter (e.g., "10 min ago", "1 hour ago")
    --live, -f           Live tail mode with auto-refresh
    --interval, -i <S>   Refresh interval in seconds (default: 3)

    Filter options:
    --ip <IP>            Filter by IP (source or destination)
    --src <IP>           Filter by source IP only
    --dst <IP>           Filter by destination IP only
    --port <PORT>        Filter by port (source or destination)
    --proto <PROTO>      Filter by protocol: tcp, udp, icmp
    --action <ACTION>    Filter by action: drop, accept
    --reason <REASON>    Filter by reason: banlist, invalid_state, etc.

    Output format:
    --json               JSON output
    --csv                CSV output
    --table              Plain table output
    --raw                Raw kernel log format

EXAMPLES:
    # Enable drop logging (default)
    nftban firewall logs enable

    # Enable high-signal alerts only
    nftban firewall logs enable --level alert

    # View recent drops
    nftban firewall logs show --action drop

    # Live view of SSH-related traffic
    nftban firewall logs show --live --port 22

    # Search for specific IP
    nftban firewall logs show --ip 1.2.3.4 --since "1 hour ago"

    # Export to JSON
    nftban firewall logs show --since "24 hours ago" --json > logs.json

RESOURCE PROTECTION:
    - Logging disabled by default (zero overhead)
    - Rate limiting prevents log floods under attack
    - On-demand parsing (no background daemon)
    - journald handles log rotation automatically

EOF
}

# =============================================================================
# MAIN ENTRY POINT
# =============================================================================

nftban_cmd_firewall_logs() {
    local subcmd="${1:-}"
    shift || true

    case "$subcmd" in
        enable)
            _fwlog_enable "$@"
            ;;
        disable)
            _fwlog_disable
            ;;
        status)
            _fwlog_status
            ;;
        show)
            _fwlog_show "$@"
            ;;
        help|--help|-h|"")
            _fwlog_help
            ;;
        *)
            echo "Unknown command: $subcmd" >&2
            echo "Run 'nftban firewall logs help' for usage" >&2
            return 1
            ;;
    esac
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_cmd_firewall_logs

# If executed directly, run
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_firewall_logs "$@"
fi
