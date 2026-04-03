#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.19.24 - Egress CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Outbound firewall policy management and audit
#
# meta:name="cmd_egress"
# meta:type="cli"
# meta:header="Egress CLI Command"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
# meta:description="Outbound policy audit, recommendation, and enforcement"
# meta:inventory.files=""
# meta:inventory.binaries="nft,journalctl"
# meta:inventory.env_vars="NFTBAN_TABLE_IPV4,NFTBAN_TABLE_IPV6"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
# meta:created_date="2026-03-08"
# meta:updated_date="2026-03-08"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Source central config
source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" 2>/dev/null || true
[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"

# Load version library
[[ -f "${NFTBAN_LIB_DIR}/lib/version.sh" ]] && source "${NFTBAN_LIB_DIR}/lib/version.sh"

# Load NFT schema
[[ -f "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" ]] && source "${NFTBAN_LIB_DIR}/lib/nft_schema.sh"

# Table defaults
: "${NFTBAN_TABLE_IPV4:=ip nftban}"
: "${NFTBAN_TABLE_IPV6:=ip6 nftban}"

# Learning data file
NFTBAN_EGRESS_LEARN_FILE="${NFTBAN_DATA_DIR:-/var/lib/nftban}/egress-learn.json"

# =============================================================================
# EGRESS STATS - View counters
# =============================================================================

nftban_egress_stats() {
    echo ""
    echo "OUTBOUND ALLOWED COUNTERS"
    echo "════════════════════════════════════════════════════════════════════"
    echo ""

    # Get IPv4 output chain counters
    echo "IPv4 Output Chain:"
    echo "──────────────────────────────────────────────────────────────────"

    local ipv4_output
    ipv4_output=$(nft list chain ${NFTBAN_TABLE_IPV4} output 2>/dev/null || echo "")

    if [[ -n "$ipv4_output" ]]; then
        # Parse counters for each rule
        echo "$ipv4_output" | while IFS= read -r line; do
            if [[ "$line" =~ counter[[:space:]]+packets[[:space:]]+([0-9]+)[[:space:]]+bytes[[:space:]]+([0-9]+) ]]; then
                local packets="${BASH_REMATCH[1]}"
                local bytes="${BASH_REMATCH[2]}"

                # Extract rule description
                local desc=""
                if [[ "$line" =~ comment[[:space:]]+\"([^\"]+)\" ]]; then
                    desc="${BASH_REMATCH[1]}"
                elif [[ "$line" =~ @tcp_ports_out ]]; then
                    desc="TCP outbound (allowed)"
                elif [[ "$line" =~ @udp_ports_out ]]; then
                    desc="UDP outbound (allowed)"
                elif [[ "$line" =~ established,related ]]; then
                    desc="Established/Related"
                elif [[ "$line" =~ oif.*lo ]]; then
                    desc="Loopback"
                elif [[ "$line" =~ icmp ]]; then
                    desc="ICMP"
                elif [[ "$line" =~ EGRESS_AUDIT ]]; then
                    desc="Unknown egress (audit)"
                fi

                if [[ -n "$desc" ]]; then
                    printf "  %-30s %12s pkts  %12s bytes\n" "$desc" "$packets" "$bytes"
                fi
            fi
        done
    else
        echo "  (No IPv4 output chain found)"
    fi

    echo ""
    echo "IPv6 Output Chain:"
    echo "──────────────────────────────────────────────────────────────────"

    local ipv6_output
    ipv6_output=$(nft list chain ${NFTBAN_TABLE_IPV6} output 2>/dev/null || echo "")

    if [[ -n "$ipv6_output" ]]; then
        echo "$ipv6_output" | while IFS= read -r line; do
            if [[ "$line" =~ counter[[:space:]]+packets[[:space:]]+([0-9]+)[[:space:]]+bytes[[:space:]]+([0-9]+) ]]; then
                local packets="${BASH_REMATCH[1]}"
                local bytes="${BASH_REMATCH[2]}"

                local desc=""
                if [[ "$line" =~ comment[[:space:]]+\"([^\"]+)\" ]]; then
                    desc="${BASH_REMATCH[1]}"
                elif [[ "$line" =~ @tcp_ports_out ]]; then
                    desc="TCP outbound (allowed)"
                elif [[ "$line" =~ @udp_ports_out ]]; then
                    desc="UDP outbound (allowed)"
                elif [[ "$line" =~ established,related ]]; then
                    desc="Established/Related"
                elif [[ "$line" =~ oif.*lo ]]; then
                    desc="Loopback"
                elif [[ "$line" =~ ipv6-icmp ]]; then
                    desc="ICMPv6"
                elif [[ "$line" =~ EGRESS_AUDIT ]]; then
                    desc="Unknown egress (audit)"
                fi

                if [[ -n "$desc" ]]; then
                    printf "  %-30s %12s pkts  %12s bytes\n" "$desc" "$packets" "$bytes"
                fi
            fi
        done
    else
        echo "  (No IPv6 output chain found)"
    fi

    echo ""
    echo "Current Allowed Outbound Ports:"
    echo "──────────────────────────────────────────────────────────────────"

    local tcp_out udp_out
    tcp_out=$(nft list set ${NFTBAN_TABLE_IPV4} tcp_ports_out 2>/dev/null | \
        tr '\n' ' ' | sed -n 's/.*elements[[:space:]]*=[[:space:]]*{[[:space:]]*\([^}]*\).*/\1/p' | tr -d ' ')
    udp_out=$(nft list set ${NFTBAN_TABLE_IPV4} udp_ports_out 2>/dev/null | \
        tr '\n' ' ' | sed -n 's/.*elements[[:space:]]*=[[:space:]]*{[[:space:]]*\([^}]*\).*/\1/p' | tr -d ' ')

    printf "  TCP: %s\n" "${tcp_out:-none}"
    printf "  UDP: %s\n" "${udp_out:-none}"
    echo ""
}

# =============================================================================
# EGRESS AUDIT - Parse logs, find unknown ports
# =============================================================================

nftban_egress_audit() {
    local hours="${1:-24}"

    echo ""
    echo "OUTBOUND AUDIT (last ${hours}h)"
    echo "════════════════════════════════════════════════════════════════════"
    echo ""

    # Parse kernel logs for audit entries
    local since_time
    since_time=$(date -d "${hours} hours ago" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')

    echo "Scanning logs since: $since_time"
    echo ""

    # Get audit log entries
    local audit_entries
    audit_entries=$(journalctl -k --no-pager --since "${hours} hours ago" 2>/dev/null | \
        grep "NFTBAN_EGRESS_AUDIT" || true)

    if [[ -z "$audit_entries" ]]; then
        echo "No unknown outbound ports detected in the last ${hours}h."
        echo ""
        echo "This means all egress traffic matched the allowed sets:"
        local tcp_out udp_out
        tcp_out=$(nft list set ${NFTBAN_TABLE_IPV4} tcp_ports_out 2>/dev/null | \
            tr '\n' ' ' | sed -n 's/.*elements[[:space:]]*=[[:space:]]*{[[:space:]]*\([^}]*\).*/\1/p' | tr -d ' ')
        udp_out=$(nft list set ${NFTBAN_TABLE_IPV4} udp_ports_out 2>/dev/null | \
            tr '\n' ' ' | sed -n 's/.*elements[[:space:]]*=[[:space:]]*{[[:space:]]*\([^}]*\).*/\1/p' | tr -d ' ')
        echo "  TCP: ${tcp_out:-none}"
        echo "  UDP: ${udp_out:-none}"
        echo ""
        return 0
    fi

    # Parse and aggregate by port
    declare -A tcp_ports=()
    declare -A udp_ports=()
    declare -A tcp_dests=()
    declare -A udp_dests=()

    while IFS= read -r line; do
        local proto="" dport="" dst=""

        if [[ "$line" =~ PROTO=TCP ]]; then
            proto="tcp"
        elif [[ "$line" =~ PROTO=UDP ]]; then
            proto="udp"
        else
            continue
        fi

        if [[ "$line" =~ DPT=([0-9]+) ]]; then
            dport="${BASH_REMATCH[1]}"
        fi

        if [[ "$line" =~ DST=([0-9a-fA-F.:]+) ]]; then
            dst="${BASH_REMATCH[1]}"
        fi

        if [[ -n "$dport" ]]; then
            if [[ "$proto" == "tcp" ]]; then
                tcp_ports["$dport"]=$(( ${tcp_ports["$dport"]:-0} + 1 ))
                [[ -n "$dst" ]] && tcp_dests["$dport"]="$dst"
            else
                udp_ports["$dport"]=$(( ${udp_ports["$dport"]:-0} + 1 ))
                [[ -n "$dst" ]] && udp_dests["$dport"]="$dst" || true
            fi
        fi
    done <<< "$audit_entries"

    echo "Unknown Outbound TCP Ports:"
    echo "──────────────────────────────────────────────────────────────────"
    if [[ ${#tcp_ports[@]} -eq 0 ]]; then
        echo "  (none)"
    else
        printf "  %-8s %-10s %-20s %s\n" "PORT" "COUNT" "LAST DEST" "SERVICE"
        for port in $(echo "${!tcp_ports[@]}" | tr ' ' '\n' | sort -n); do
            local count="${tcp_ports[$port]}"
            local dest="${tcp_dests[$port]:-unknown}"
            local svc=""
            # Try to get service name
            svc=$(grep -E "^[^#].*[[:space:]]${port}/tcp" /etc/services 2>/dev/null | head -1 | awk '{print $1}' || echo "")
            printf "  %-8s %-10s %-20s %s\n" "$port" "$count" "$dest" "$svc"
        done
    fi

    echo ""
    echo "Unknown Outbound UDP Ports:"
    echo "──────────────────────────────────────────────────────────────────"
    if [[ ${#udp_ports[@]} -eq 0 ]]; then
        echo "  (none)"
    else
        printf "  %-8s %-10s %-20s %s\n" "PORT" "COUNT" "LAST DEST" "SERVICE"
        for port in $(echo "${!udp_ports[@]}" | tr ' ' '\n' | sort -n); do
            local count="${udp_ports[$port]}"
            local dest="${udp_dests[$port]:-unknown}"
            local svc=""
            svc=$(grep -E "^[^#].*[[:space:]]${port}/udp" /etc/services 2>/dev/null | head -1 | awk '{print $1}' || echo "")
            printf "  %-8s %-10s %-20s %s\n" "$port" "$count" "$dest" "$svc"
        done
    fi

    # Save to learning file
    echo ""
    echo "Saving observations to: $NFTBAN_EGRESS_LEARN_FILE"

    mkdir -p "$(dirname "$NFTBAN_EGRESS_LEARN_FILE")" || return 1

    local json="{"
    json+="\"timestamp\":\"$(date --iso-8601=seconds)\","
    json+="\"hours\":$hours,"
    json+="\"tcp\":{"
    local first=true
    for port in "${!tcp_ports[@]}"; do
        $first || json+=","
        json+="\"$port\":${tcp_ports[$port]}"
        first=false
    done
    json+="},"
    json+="\"udp\":{"
    first=true
    for port in "${!udp_ports[@]}"; do
        $first || json+=","
        json+="\"$port\":${udp_ports[$port]}"
        first=false
    done
    json+="}}"

    echo "$json" > "$NFTBAN_EGRESS_LEARN_FILE"
    chmod 640 "$NFTBAN_EGRESS_LEARN_FILE"

    echo ""
}

# =============================================================================
# EGRESS RECOMMEND - Suggest additions based on audit
# =============================================================================

nftban_egress_recommend() {
    echo ""
    echo "OUTBOUND POLICY RECOMMENDATION"
    echo "════════════════════════════════════════════════════════════════════"
    echo ""

    # Check if learning data exists
    if [[ ! -f "$NFTBAN_EGRESS_LEARN_FILE" ]]; then
        echo "No learning data found."
        echo "Run 'nftban egress audit' first to collect traffic observations."
        echo ""
        return 1
    fi

    # Read current allowed ports
    local tcp_current udp_current
    tcp_current=$(nft list set ${NFTBAN_TABLE_IPV4} tcp_ports_out 2>/dev/null | \
        tr '\n' ' ' | sed -n 's/.*elements[[:space:]]*=[[:space:]]*{[[:space:]]*\([^}]*\).*/\1/p' | tr -d ' ')
    udp_current=$(nft list set ${NFTBAN_TABLE_IPV4} udp_ports_out 2>/dev/null | \
        tr '\n' ' ' | sed -n 's/.*elements[[:space:]]*=[[:space:]]*{[[:space:]]*\([^}]*\).*/\1/p' | tr -d ' ')

    echo "Current Allowed Ports:"
    echo "  TCP: ${tcp_current:-none}"
    echo "  UDP: ${udp_current:-none}"
    echo ""

    # Read learning data
    local learn_data
    learn_data=$(cat "$NFTBAN_EGRESS_LEARN_FILE" 2>/dev/null)

    echo "Observed Unknown Ports (from last audit):"

    # Extract TCP ports from JSON - simple parsing
    local tcp_observed=""
    local tcp_section
    tcp_section=$(echo "$learn_data" | sed -n 's/.*"tcp":{\([^}]*\)}.*/\1/p')
    if [[ -n "$tcp_section" && "$tcp_section" != "{}" ]]; then
        tcp_observed=$(echo "$tcp_section" | grep -oE '"[0-9]+":' | tr -d '":' | tr '\n' ' ')
    fi

    # Extract UDP ports from JSON
    local udp_observed=""
    local udp_section
    udp_section=$(echo "$learn_data" | sed -n 's/.*"udp":{\([^}]*\)}.*/\1/p')
    if [[ -n "$udp_section" && "$udp_section" != "{}" ]]; then
        udp_observed=$(echo "$udp_section" | grep -oE '"[0-9]+":' | tr -d '":' | tr '\n' ' ')
    fi

    echo "  TCP: ${tcp_observed:-none}"
    echo "  UDP: ${udp_observed:-none}"
    echo ""

    # Generate recommendations
    # Note: IFS is set to '\n\t' so we need to use read with tr for space-separated values
    local tcp_add="" udp_add="" current_check="" port

    while read -r port; do
        [[ -z "$port" ]] && continue
        # Check if already in current (handle comma-separated list)
        current_check=",${tcp_current},"
        if [[ ! "$current_check" =~ ,${port}, ]]; then
            tcp_add+="$port "
        fi
    done < <(echo "$tcp_observed" | tr ' ' '\n')

    while read -r port; do
        [[ -z "$port" ]] && continue
        current_check=",${udp_current},"
        if [[ ! "$current_check" =~ ,${port}, ]]; then
            udp_add+="$port "
        fi
    done < <(echo "$udp_observed" | tr ' ' '\n')

    if [[ -z "$tcp_add" && -z "$udp_add" ]]; then
        echo "✓ No additional ports needed."
        echo "  All observed traffic matches current policy."
        echo ""
        return 0
    fi

    echo "────────────────────────────────────────────────────────────────────"
    echo "RECOMMENDED ADDITIONS:"
    echo "────────────────────────────────────────────────────────────────────"

    if [[ -n "$tcp_add" ]]; then
        echo ""
        echo "  TCP ports to add:"
        local svc port_list
        port_list=$(echo "$tcp_add" | tr ' ' '\n')
        while IFS= read -r port; do
            [[ -z "$port" ]] && continue
            svc=$(grep -E "^[^#].*[[:space:]]${port}/tcp" /etc/services 2>/dev/null | head -1 | awk '{print $1}' || true)
            printf "    %-8s (%s)\n" "$port" "${svc:-unknown}"
        done <<< "$port_list"
    fi

    if [[ -n "$udp_add" ]]; then
        echo ""
        echo "  UDP ports to add:"
        local svc port_list
        port_list=$(echo "$udp_add" | tr ' ' '\n')
        while IFS= read -r port; do
            [[ -z "$port" ]] && continue
            svc=$(grep -E "^[^#].*[[:space:]]${port}/udp" /etc/services 2>/dev/null | head -1 | awk '{print $1}' || true)
            printf "    %-8s (%s)\n" "$port" "${svc:-unknown}"
        done <<< "$port_list"
    fi

    echo ""
    echo "To apply these recommendations:"
    if [[ -n "$tcp_add" ]]; then
        port_list=$(echo "$tcp_add" | tr ' ' '\n')
        while IFS= read -r port; do
            [[ -z "$port" ]] && continue
            echo "  nftban port add $port tcp out"
        done <<< "$port_list"
    fi
    if [[ -n "$udp_add" ]]; then
        port_list=$(echo "$udp_add" | tr ' ' '\n')
        while IFS= read -r port; do
            [[ -z "$port" ]] && continue
            echo "  nftban port add $port udp out"
        done <<< "$port_list"
    fi
    echo ""
}

# =============================================================================
# EGRESS ENFORCE - Switch to policy drop
# =============================================================================

nftban_egress_enforce() {
    echo ""
    echo "OUTBOUND ENFORCEMENT"
    echo "════════════════════════════════════════════════════════════════════"
    echo ""

    # Check current policy
    local ipv4_output ipv6_output
    ipv4_output=$(nft list chain ${NFTBAN_TABLE_IPV4} output 2>/dev/null || true)
    ipv6_output=$(nft list chain ${NFTBAN_TABLE_IPV6} output 2>/dev/null || true)

    local ipv4_policy="accept" ipv6_policy="accept"
    [[ "$ipv4_output" =~ policy[[:space:]]+drop ]] && ipv4_policy="drop"
    [[ "$ipv6_output" =~ policy[[:space:]]+drop ]] && ipv6_policy="drop"

    if [[ "$ipv4_policy" == "drop" && "$ipv6_policy" == "drop" ]]; then
        echo "✓ Enforcement is already active (policy drop)"
        echo ""
        return 0
    fi

    echo "⚠  WARNING: This will enable restrictive outbound filtering!"
    echo ""
    echo "Current allowed ports:"
    local tcp_out udp_out
    tcp_out=$(nft list set ${NFTBAN_TABLE_IPV4} tcp_ports_out 2>/dev/null | \
        tr '\n' ' ' | sed -n 's/.*elements[[:space:]]*=[[:space:]]*{[[:space:]]*\([^}]*\).*/\1/p' | tr -d ' ')
    udp_out=$(nft list set ${NFTBAN_TABLE_IPV4} udp_ports_out 2>/dev/null | \
        tr '\n' ' ' | sed -n 's/.*elements[[:space:]]*=[[:space:]]*{[[:space:]]*\([^}]*\).*/\1/p' | tr -d ' ')
    echo "  TCP: ${tcp_out:-none}"
    echo "  UDP: ${udp_out:-none}"
    echo ""
    echo "All other outbound TCP/UDP will be BLOCKED."
    echo ""

    # Confirmation
    echo -n "Type 'ENFORCE' to confirm: "
    read -r confirm

    if [[ "$confirm" != "ENFORCE" ]]; then
        echo ""
        echo "Aborted. No changes made."
        return 1
    fi

    echo ""
    echo "Enabling enforcement..."

    # Change IPv4 policy
    if nft "add chain ${NFTBAN_TABLE_IPV4} output { policy drop; }" 2>/dev/null; then
        echo "  ✓ IPv4 output policy: drop"
    else
        echo "  ✗ Failed to set IPv4 policy"
    fi

    # Change IPv6 policy
    if nft "add chain ${NFTBAN_TABLE_IPV6} output { policy drop; }" 2>/dev/null; then
        echo "  ✓ IPv6 output policy: drop"
    else
        echo "  ✗ Failed to set IPv6 policy"
    fi

    echo ""
    echo "🔒 Outbound enforcement is now ACTIVE"
    echo ""
    echo "To disable enforcement:"
    echo "  nft 'add chain ${NFTBAN_TABLE_IPV4} output { policy accept; }'"
    echo "  nft 'add chain ${NFTBAN_TABLE_IPV6} output { policy accept; }'"
    echo ""
}

# =============================================================================
# HELP
# =============================================================================

nftban_cmd_egress_help() {
    echo ""
    echo "USAGE: nftban port egress <command>"
    echo ""
    echo "COMMANDS:"
    echo "  stats              Show outbound counters and allowed ports"
    echo "  audit [hours]      Parse logs, find unknown ports (default: 24h)"
    echo "  recommend          Suggest policy additions based on audit"
    echo "  enforce            Switch to policy drop (requires confirmation)"
    echo ""
    echo "WORKFLOW:"
    echo "  1. nftban port egress stats       # Check current counters"
    echo "  2. nftban port egress audit 48    # Collect 48h of traffic data"
    echo "  3. nftban port egress recommend   # See suggested additions"
    echo "  4. nftban port add <port> tcp out # Add missing ports"
    echo "  5. nftban emulate --out :443      # Test if port allowed"
    echo "  6. nftban port egress enforce     # Enable restrictive mode"
    echo ""
}

# =============================================================================
# MAIN COMMAND HANDLER
# =============================================================================

nftban_cmd_egress() {
    local subcmd="${1:-help}"
    shift || true

    # Check root
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: Egress commands require root privileges" >&2
        return 1
    fi

    case "$subcmd" in
        stats)
            nftban_egress_stats
            ;;
        audit)
            nftban_egress_audit "${1:-24}"
            ;;
        recommend)
            nftban_egress_recommend
            ;;
        enforce)
            nftban_egress_enforce
            ;;
        help|--help|-h)
            nftban_cmd_egress_help
            ;;
        *)
            echo "ERROR: Unknown egress command: $subcmd" >&2
            echo "Run 'nftban port egress help' for usage" >&2
            return 1
            ;;
    esac
}

# Export for auto-loading
export -f nftban_cmd_egress

