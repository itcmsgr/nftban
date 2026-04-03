#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - List Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: List banned IPs, whitelisted IPs, and other nftables sets
#
# meta:name="cmd_list"
# meta:type="cli"
# meta:header="List Command"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
# meta:description="List banned IPs, whitelist, and other nftables sets"
# meta:input="Optional: set type (banned, whitelist, all)"
# meta:output="List of IPs with metadata"
# meta:depends="bash,nft"
# meta:created_date="2025-11-24"
#
# meta:inventory.files=""
# meta:inventory.binaries="nft"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================

[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"

# Load strict mode library
# shellcheck source=/usr/lib/nftban/lib/strict.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/strict.sh" || return 1
else
    set -Eeuo pipefail
fi

# Load version library
# shellcheck source=/usr/lib/nftban/lib/version.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/version.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/version.sh" || return 1
fi

# Load NFT schema (single source of truth for table/set names)
# shellcheck source=/usr/lib/nftban/lib/nft_schema.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" || return 1
fi

# Load JSON helper
# shellcheck source=/usr/lib/nftban/helpers/json_output.sh
if [[ -f "${NFTBAN_LIB_DIR}/helpers/json_output.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/helpers/json_output.sh" || return 1
fi

# Prevent double-loading
[[ -n "${CMD_LIST_LOADED:-}" ]] && return 0
readonly CMD_LIST_LOADED=1

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

parse_nft_set() {
    # Parse nft set output and extract IPs (IP only, no metadata)
    # Args: $1 = nft output, $2 = set name
    local output="$1"
    local set_name="$2"

    # Extract elements from the set (multi-line format)
    # Format spans multiple lines:
    #   elements = { 1.2.3.4 timeout 1d expires 19h, 5.6.7.8,
    #                9.10.11.12 }
    #
    # Strategy:
    # 1. Join all lines into one
    # 2. Extract content between "elements = {" and "}"
    # 3. Split by comma and clean up
    # 4. Extract just the IP (first word before any timeout/expires/comment)
    # Note: grep/sed may return exit 1 with no matches, so use || true
    echo "$output" | \
        tr '\n' ' ' | \
        sed -n 's/.*elements = { *\([^}]*\).*/\1/p' | \
        tr ',' '\n' | \
        sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | \
        grep -v '^$' | \
        while IFS= read -r entry; do
            # v1.24.0: Extract just the IP (first word)
            echo "${entry%% *}"
        done || true
}

parse_nft_set_full() {
    # Parse nft set output and extract full entries (IP + timeout + expires)
    # For JSON output that needs structured metadata fields
    # Args: $1 = nft output
    # Output: pipe-delimited "ip|timeout|expires" per line
    local output="$1"

    echo "$output" | \
        tr '\n' ' ' | \
        sed -n 's/.*elements = { *\([^}]*\).*/\1/p' | \
        tr ',' '\n' | \
        sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | \
        grep -v '^$' | \
        while IFS= read -r entry; do
            local ip_only="${entry%% *}"
            local timeout_val="" expires_val=""
            [[ "$entry" =~ timeout[[:space:]]+([^[:space:]]+) ]] && timeout_val="${BASH_REMATCH[1]}"
            [[ "$entry" =~ expires[[:space:]]+([^[:space:]]+) ]] && expires_val="${BASH_REMATCH[1]}"
            echo "${ip_only}|${timeout_val:-permanent}|${expires_val:-never}"
        done || true
}

# =============================================================================
# COMMAND HANDLER
# =============================================================================

nftban_cmd_list() {
    # List IPs from nftables sets
    # Usage: nftban list [banned|whitelist|all] [--json]

    local list_type="banned"  # Default to banned IPs
    local json_output=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            banned|ban)
                list_type="banned"
                shift
                ;;
            whitelist|white)
                list_type="whitelist"
                shift
                ;;
            all)
                list_type="all"
                shift
                ;;
            --json|-j)
                json_output=true
                shift
                ;;
            help|-h|--help)
                nftban_cmd_list_usage
                return 0
                ;;
            *)
                echo "ERROR: Unknown option: $1" >&2
                nftban_cmd_list_usage >&2
                return 1
                ;;
        esac
    done

    # Show banner (skip for JSON output)
    if [[ "$json_output" != "true" ]]; then
        if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
            # shellcheck source=/dev/null
            source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
            nftban_banner
        fi
        echo ""
    fi

    # Collect IPs from sets
    declare -A all_ips=()
    # shellcheck disable=SC2034  # Reserved for pagination
    local ip_count=0

    if [[ "$list_type" == "banned" || "$list_type" == "all" ]]; then
        # v1.33.0: Hash sets first (manual/auto-detect, O(1))
        if timeout 10s nft list set "${NFTBAN_TABLE_IPV4}" blacklist_manual_ipv4 &>/dev/null; then
            while IFS= read -r ip; do
                [[ -n "$ip" ]] && all_ips["$ip"]="blacklist:ipv4"
            done < <(parse_nft_set "$(timeout 10s nft list set "${NFTBAN_TABLE_IPV4}" blacklist_manual_ipv4 2>/dev/null)" "blacklist_manual_ipv4")
        fi
        if timeout 10s nft list set "${NFTBAN_TABLE_IPV6}" blacklist_manual_ipv6 &>/dev/null; then
            while IFS= read -r ip; do
                [[ -n "$ip" ]] && all_ips["$ip"]="blacklist:ipv6"
            done < <(parse_nft_set "$(timeout 10s nft list set "${NFTBAN_TABLE_IPV6}" blacklist_manual_ipv6 2>/dev/null)" "blacklist_manual_ipv6")
        fi

        # Interval sets (feeds/geoban, CIDR aggregation)
        if timeout 10s nft list set "${NFTBAN_TABLE_IPV4}" blacklist_ipv4 &>/dev/null; then
            while IFS= read -r ip; do
                [[ -n "$ip" && -z "${all_ips[$ip]+x}" ]] && all_ips["$ip"]="blacklist:ipv4"
            done < <(parse_nft_set "$(timeout 10s nft list set "${NFTBAN_TABLE_IPV4}" blacklist_ipv4 2>/dev/null)" "blacklist_ipv4")
        fi
        if timeout 10s nft list set "${NFTBAN_TABLE_IPV6}" blacklist_ipv6 &>/dev/null; then
            while IFS= read -r ip; do
                [[ -n "$ip" && -z "${all_ips[$ip]+x}" ]] && all_ips["$ip"]="blacklist:ipv6"
            done < <(parse_nft_set "$(timeout 10s nft list set "${NFTBAN_TABLE_IPV6}" blacklist_ipv6 2>/dev/null)" "blacklist_ipv6")
        fi
    fi

    if [[ "$list_type" == "whitelist" || "$list_type" == "all" ]]; then
        # v0.7.3: Get whitelist_ipv4
        if timeout 10s nft list set "${NFTBAN_TABLE_IPV4}" whitelist_ipv4 &>/dev/null; then
            while IFS= read -r ip; do
                [[ -n "$ip" ]] && all_ips["$ip"]="whitelist:ipv4"
            done < <(parse_nft_set "$(timeout 10s nft list set "${NFTBAN_TABLE_IPV4}" whitelist_ipv4 2>/dev/null)" "whitelist_ipv4")
        fi

        # Get whitelist_ipv6
        if timeout 10s nft list set "${NFTBAN_TABLE_IPV6}" whitelist_ipv6 &>/dev/null; then
            while IFS= read -r ip; do
                [[ -n "$ip" ]] && all_ips["$ip"]="whitelist:ipv6"
            done < <(parse_nft_set "$(timeout 10s nft list set "${NFTBAN_TABLE_IPV6}" whitelist_ipv6 2>/dev/null)" "whitelist_ipv6")
        fi
    fi

    # Output results
    if [[ "$json_output" == "true" ]]; then
        # JSON output
        echo "{"
        echo "  \"success\": true,"
        echo "  \"type\": \"$list_type\","
        echo "  \"total\": ${#all_ips[*]},"
        echo "  \"ips\": ["

        # Safe array iteration compatible with set -u
        if [[ ${#all_ips[@]} -gt 0 ]]; then
            local first=true
            for ip in "${!all_ips[@]}"; do
                local meta="${all_ips[$ip]}"
                local set_name="${meta%:*}"
                local ip_version="${meta#*:}"

                if [[ "$first" == "true" ]]; then
                    first=false
                else
                    echo ","
                fi

                # v1.24.0: Output structured IP field (ip only, no embedded metadata)
                echo -n "    {\"ip\": \"$ip\", \"set\": \"$set_name\", \"version\": \"$ip_version\"}"
            done
        fi

        echo ""
        echo "  ]"
        echo "}"
    else
        # Text output with clear descriptions
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        case "$list_type" in
            banned)
                echo "📋 NFTBan List - BANNED IPs"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                echo "These IPs are currently BLOCKED by the firewall."
                echo "They cannot access any services on this server."
                ;;
            whitelist)
                echo "📋 NFTBan List - WHITELISTED IPs"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                echo "These IPs are TRUSTED and will NEVER be blocked."
                echo "They bypass all ban rules and rate limits."
                ;;
            all)
                echo "📋 NFTBan List - ALL IPs"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                echo "Combined view of both banned and whitelisted IPs."
                ;;
        esac
        echo ""

        # Count by type
        local banned_count=0
        local whitelist_count=0
        local ipv4_count=0
        local ipv6_count=0

        if [[ ${#all_ips[@]} -gt 0 ]]; then
            for ip in "${!all_ips[@]}"; do
                local meta="${all_ips[$ip]}"
                local set_name="${meta%:*}"
                local ip_version="${meta#*:}"

                [[ "$set_name" == "blacklist" ]] && banned_count=$((banned_count + 1))
                [[ "$set_name" == "whitelist" ]] && whitelist_count=$((whitelist_count + 1))
                [[ "$ip_version" == "ipv4" ]] && ipv4_count=$((ipv4_count + 1))
                [[ "$ip_version" == "ipv6" ]] && ipv6_count=$((ipv6_count + 1)) || true
            done
        fi

        echo "📊 Summary:"
        echo "   Total IPs: ${#all_ips[*]}"
        if [[ "$list_type" == "all" ]]; then
            echo "   ├── Banned:     $banned_count"
            echo "   └── Whitelisted: $whitelist_count"
        fi
        echo "   IPv4: $ipv4_count | IPv6: $ipv6_count"
        echo ""
        echo "────────────────────────────────────────────────────────────────────"
        printf "  %-42s %-12s %-8s\n" "IP Address" "Type" "Version"
        echo "────────────────────────────────────────────────────────────────────"

        # Safe array iteration compatible with set -u
        if [[ ${#all_ips[@]} -gt 0 ]]; then
            # Create sorted array of keys first
            local sorted_keys=()
            while IFS= read -r key; do
                sorted_keys+=("$key")
            done < <(printf '%s\n' "${!all_ips[@]}" | sort)

            for ip in "${sorted_keys[@]}"; do
                local meta="${all_ips[$ip]}"
                local set_name="${meta%:*}"
                local ip_version="${meta#*:}"
                local icon=""
                [[ "$set_name" == "blacklist" ]] && icon="🚫"
                [[ "$set_name" == "whitelist" ]] && icon="✅"
                printf "  %s %-40s %-12s %-8s\n" "$icon" "$ip" "$set_name" "$ip_version"
            done
        else
            echo ""
            echo "  (No IPs found)"
        fi

        echo "────────────────────────────────────────────────────────────────────"

        # Check if there are ranges (entries with '-') and explain
        local has_ranges=false
        if [[ ${#all_ips[@]} -gt 0 ]]; then
            for ip in "${!all_ips[@]}"; do
                if [[ "$ip" == *"-"* ]]; then
                    has_ranges=true
                    break
                fi
            done
        fi

        if [[ "$has_ranges" == "true" ]]; then
            echo ""
            echo "ℹ️  Note: Entries with '-' are IP RANGES (e.g., 1.2.3.4-1.2.3.10)"
            echo "   nftables auto-merges adjacent IPs for efficiency."
            echo "   Use 'nftban search <IP>' to check if a specific IP is banned."
        fi

        echo ""
        echo "💡 Commands:"
        case "$list_type" in
            banned)
                echo "   nftban search <IP>       - Check if specific IP is banned"
                echo "   nftban unban <IP>        - Remove IP from blacklist"
                ;;
            whitelist)
                echo "   nftban whitelist add <IP> - Add IP to whitelist"
                echo "   nftban whitelist remove <IP> - Remove IP from whitelist"
                ;;
            all)
                echo "   nftban list banned       - Show only banned IPs"
                echo "   nftban list whitelist    - Show only whitelisted IPs"
                echo "   nftban list all --json   - Export as JSON"
                ;;
        esac
        echo ""
    fi

    return 0
}

nftban_cmd_list_usage() {
    cat <<EOF
Usage: nftban list [TYPE] [OPTIONS]

List IPs from nftables sets (active firewall rules).

TYPES:
  banned        List banned IPs (temp_ban + blacklist) [default]
  whitelist     List whitelisted IPs (from firewall)
  all           List all IPs (banned + whitelist)

OPTIONS:
  --json, -j    Output in JSON format
  --help, -h    Show this help message

EXAMPLES:
  nftban list                    # List all banned IPs
  nftban list banned --json      # List banned IPs in JSON
  nftban list whitelist          # List whitelisted IPs from firewall
  nftban list all --json         # List all IPs in JSON

WHITELIST COMMANDS COMPARISON:
  nftban list whitelist          # Shows IPs loaded in nftables (active now)
  nftban whitelist list          # Shows IPs from config files (persistent)
  nftban whitelist-system show   # Shows only system auto-detected IPs

TIP: Use 'nftban list whitelist' to see what's currently protecting your IPs.
     Use 'nftban whitelist list' to see what's saved in configuration.

EOF
}

# Export functions
export -f nftban_cmd_list
export -f nftban_cmd_list_usage

# =============================================================================
# EXECUTE IF RUN DIRECTLY
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_list "$@"
fi
