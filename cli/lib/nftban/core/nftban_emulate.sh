#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Packet Emulation Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_emulate"
# meta:type="core"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Simulates packet evaluation to show what nftban would do"
# meta:inventory.files=""
# meta:inventory.binaries="nft"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================

set -Eeuo pipefail

# Prevent double-sourcing
[[ -n "${_NFTBAN_EMULATE_LOADED:-}" ]] && return 0
_NFTBAN_EMULATE_LOADED=1

# Bootstrap path (may be readonly from nftban.conf)
: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"
source "${NFTBAN_LIB_DIR}/lib/common.sh" 2>/dev/null || true

# =============================================================================
# CIDR MATCHING FUNCTIONS
# =============================================================================

# Convert IP to integer for comparison
_ip_to_int() {
    local ip="$1"
    local a b c d
    IFS='.' read -r a b c d <<< "$ip"
    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

# Convert integer to IP
_int_to_ip() {
    local int="$1"
    echo "$(( (int >> 24) & 255 )).$(( (int >> 16) & 255 )).$(( (int >> 8) & 255 )).$(( int & 255 ))"
}

# Check if IP is within CIDR range
# Returns: 0 if in range, 1 if not
_ip_in_cidr() {
    local ip="$1"
    local cidr="$2"

    # Handle single IP (no /)
    if [[ "$cidr" != *"/"* ]]; then
        [[ "$ip" == "$cidr" ]] && return 0
        return 1
    fi

    local network="${cidr%/*}"
    local prefix="${cidr#*/}"

    local ip_int network_int mask
    ip_int=$(_ip_to_int "$ip")
    network_int=$(_ip_to_int "$network")

    # Calculate mask
    if [[ "$prefix" -eq 0 ]]; then
        mask=0
    else
        mask=$(( 0xFFFFFFFF << (32 - prefix) ))
    fi

    # Check if IP is in network
    [[ $(( ip_int & mask )) -eq $(( network_int & mask )) ]] && return 0
    return 1
}

# Expand IPv6 to full 32-character hex (no colons)
# 2001:db8::1 -> 20010db8000000000000000000000001
_ipv6_expand() {
    local ip="$1"
    local expanded=""

    # Handle :: expansion
    if [[ "$ip" == *"::"* ]]; then
        local left="${ip%%::*}"
        local right="${ip#*::}"

        # Count existing groups (use prefix increment to avoid ((0)) returning false with set -e)
        local left_groups=0 right_groups=0
        if [[ -n "$left" ]]; then
            left_groups=$(echo "$left" | tr -cd ':' | wc -c)
            left_groups=$((left_groups + 1))
        fi
        if [[ -n "$right" ]]; then
            right_groups=$(echo "$right" | tr -cd ':' | wc -c)
            right_groups=$((right_groups + 1))
        fi

        # Calculate missing groups
        local missing
        missing=$((8 - left_groups - right_groups))

        # Build zero groups
        local zeros=""
        for ((i=0; i<missing; i++)); do
            zeros="${zeros}0000"
        done

        # Expand left part
        if [[ -n "$left" ]]; then
            IFS=':' read -ra groups <<< "$left"
            for g in "${groups[@]}"; do
                printf -v g "%04s" "$g"
                expanded="${expanded}${g// /0}"
            done
        fi

        # Add zeros
        expanded="${expanded}${zeros}"

        # Expand right part
        if [[ -n "$right" ]]; then
            IFS=':' read -ra groups <<< "$right"
            for g in "${groups[@]}"; do
                printf -v g "%04s" "$g"
                expanded="${expanded}${g// /0}"
            done
        fi
    else
        # No ::, just expand each group
        IFS=':' read -ra groups <<< "$ip"
        for g in "${groups[@]}"; do
            printf -v g "%04s" "$g"
            expanded="${expanded}${g// /0}"
        done
    fi

    # Ensure lowercase
    echo "${expanded,,}"
}

# Convert hex string to binary string (for bit operations)
_hex_to_bin() {
    local hex="$1"
    local bin=""
    for ((i=0; i<${#hex}; i++)); do
        case "${hex:$i:1}" in
            0) bin+="0000" ;; 1) bin+="0001" ;; 2) bin+="0010" ;; 3) bin+="0011" ;;
            4) bin+="0100" ;; 5) bin+="0101" ;; 6) bin+="0110" ;; 7) bin+="0111" ;;
            8) bin+="1000" ;; 9) bin+="1001" ;; a|A) bin+="1010" ;; b|B) bin+="1011" ;;
            c|C) bin+="1100" ;; d|D) bin+="1101" ;; e|E) bin+="1110" ;; f|F) bin+="1111" ;;
        esac
    done
    echo "$bin"
}

# Check if IPv6 is within CIDR range (full implementation)
_ipv6_in_cidr() {
    local ip="$1"
    local cidr="$2"

    # Handle single IP (no /)
    if [[ "$cidr" != *"/"* ]]; then
        local ip_exp net_exp
        ip_exp=$(_ipv6_expand "$ip")
        net_exp=$(_ipv6_expand "$cidr")
        [[ "$ip_exp" == "$net_exp" ]] && return 0
        return 1
    fi

    local network="${cidr%/*}"
    local prefix="${cidr#*/}"

    # Expand both to full hex
    local ip_hex net_hex
    ip_hex=$(_ipv6_expand "$ip")
    net_hex=$(_ipv6_expand "$network")

    # For /0, everything matches
    [[ "$prefix" -eq 0 ]] && return 0

    # For /128, exact match required
    if [[ "$prefix" -eq 128 ]]; then
        [[ "$ip_hex" == "$net_hex" ]] && return 0
        return 1
    fi

    # Convert to binary for bit comparison
    local ip_bin net_bin
    ip_bin=$(_hex_to_bin "$ip_hex")
    net_bin=$(_hex_to_bin "$net_hex")

    # Compare first 'prefix' bits
    [[ "${ip_bin:0:$prefix}" == "${net_bin:0:$prefix}" ]] && return 0
    return 1
}

# =============================================================================
# SET LOOKUP FUNCTIONS
# =============================================================================

# Check if IP is in a specific nft set
# Returns: matching CIDR or empty string
_check_ip_in_set() {
    local family="$1"  # ip or ip6
    local set_name="$2"
    local check_ip="$3"

    local set_content
    set_content=$(timeout 10s nft list set "$family" nftban "$set_name" 2>/dev/null)
    [[ -z "$set_content" ]] && return 1

    # Extract elements section - handle multi-line nft output
    local elements
    elements=$(echo "$set_content" | \
        sed -n '/elements = {/,/}/p' | \
        sed 's/elements = {//' | \
        tr ',' '\n' | \
        tr -d '{}' | \
        sed 's/^[[:space:]]*//' | \
        sed 's/[[:space:]]*$//' | \
        grep -v '^$')

    local best_match=""
    local best_prefix=0

    while IFS= read -r entry; do
        # Clean entry (remove timeout info, whitespace)
        entry=$(echo "$entry" | sed 's/timeout.*//' | tr -d ' \t')
        [[ -z "$entry" ]] && continue

        # Handle IP ranges (a.b.c.d-e.f.g.h)
        if [[ "$entry" == *"-"* ]]; then
            # Range format - check if IP is within
            local start_ip="${entry%-*}"
            local end_ip="${entry#*-}"
            local ip_int start_int end_int
            ip_int=$(_ip_to_int "$check_ip")
            start_int=$(_ip_to_int "$start_ip")
            end_int=$(_ip_to_int "$end_ip")

            if [[ "$ip_int" -ge "$start_int" && "$ip_int" -le "$end_int" ]]; then
                best_match="$entry"
                best_prefix=32  # Treat range as most specific
                break
            fi
            continue
        fi

        # Check CIDR match
        if [[ "$family" == "ip" ]]; then
            if _ip_in_cidr "$check_ip" "$entry"; then
                local prefix=32
                [[ "$entry" == *"/"* ]] && prefix="${entry#*/}"
                if [[ "$prefix" -gt "$best_prefix" ]]; then
                    best_prefix="$prefix"
                    best_match="$entry"
                fi
            fi
        else
            if _ipv6_in_cidr "$check_ip" "$entry"; then
                best_match="$entry"
                break
            fi
        fi
    done <<< "$elements"

    if [[ -n "$best_match" ]]; then
        echo "$best_match"
        return 0
    fi
    return 1
}

# Get rule handle for a set reference in chain
_get_set_rule_handle() {
    local family="$1"
    local chain="$2"
    local set_name="$3"

    nft -a list chain "$family" nftban "$chain" 2>/dev/null | \
        grep -E "@${set_name}[[:space:]]" | \
        grep -oE 'handle [0-9]+' | \
        head -1 | \
        awk '{print $2}'
}

# =============================================================================
# MODULE DETECTION
# =============================================================================

# Determine which module added an IP to a set
_detect_module_source() {
    local ip="$1"
    local set_name="$2"

    local module="unknown"
    local source="unknown"

    # Check blacklist config files for source
    local config_dir="${NFTBAN_CONFIG_DIR:-/etc/nftban}"

    # Check feeds
    if [[ -f "${NFTBAN_DATA_DIR:-/var/lib/nftban}/feeds/feed_ips.txt" ]]; then
        if grep -q "$ip" "${NFTBAN_DATA_DIR}/feeds/feed_ips.txt" 2>/dev/null; then
            module="threat_feeds"
            # Try to find which feed
            for feed_file in "${NFTBAN_DATA_DIR}"/feeds/*.txt; do
                [[ -f "$feed_file" ]] || continue
                if grep -q "$ip" "$feed_file" 2>/dev/null; then
                    source=$(basename "$feed_file" .txt | tr '[:lower:]' '[:upper:]')
                    break
                fi
            done
        fi
    fi

    # Check manual blacklist
    if [[ "$module" == "unknown" ]]; then
        for conf_file in "$config_dir"/blacklist.d/*.conf; do
            [[ -f "$conf_file" ]] || continue
            if grep -q "$ip" "$conf_file" 2>/dev/null; then
                module="manual"
                source=$(basename "$conf_file")
                break
            fi
        done
    fi

    # Check whitelist
    if [[ "$set_name" == *"whitelist"* ]]; then
        module="whitelist"
        for conf_file in "$config_dir"/whitelist.d/*.conf; do
            [[ -f "$conf_file" ]] || continue
            if grep -q "$ip" "$conf_file" 2>/dev/null; then
                source=$(basename "$conf_file")
                break
            fi
        done
        [[ "$source" == "unknown" ]] && source="manual"
    fi

    # Check if from login monitor
    if grep -q "$ip" "${NFTBAN_LOG_DIR:-/var/log/nftban}/login-monitor.log" 2>/dev/null; then
        if [[ "$module" == "unknown" ]]; then
            module="login_monitor"
            source="ssh_bruteforce"
        fi
    fi

    # Check if from portscan
    if grep -q "$ip" "${NFTBAN_LOG_DIR:-/var/log/nftban}/portscan.log" 2>/dev/null; then
        if [[ "$module" == "unknown" ]]; then
            module="portscan"
            source="port_scan_detection"
        fi
    fi

    echo "${module}|${source}"
}

# =============================================================================
# PORT CHECKING
# =============================================================================

# Check if port is in allowed ports set
_check_port_allowed() {
    local proto="$1"      # tcp or udp
    local port="$2"
    local direction="$3"  # in or out

    # Directional set names: tcp_ports_in, tcp_ports_out, udp_ports_in, udp_ports_out
    local set_name="${proto}_ports_${direction}"
    local set_content
    set_content=$(nft list set ip nftban "$set_name" 2>/dev/null)

    if [[ -z "$set_content" ]]; then
        # Try non-directional fallback (legacy)
        set_content=$(nft list set ip nftban "${proto}_ports" 2>/dev/null)
        [[ -z "$set_content" ]] && return 1  # No set found = not allowed
    fi

    # Extract all port numbers from set elements and check for match
    # nft output format: "elements = { 20, 21, 22, 80, 443, 55000 }" (may span multiple lines)
    local ports_list
    ports_list=$(echo "$set_content" | \
        sed -n '/elements = {/,/}/p' | \
        sed 's/elements = {//' | \
        tr ',' '\n' | \
        tr -d '{}' | \
        sed 's/^[[:space:]]*//' | \
        sed 's/[[:space:]]*$//' | \
        grep -E '^[0-9]+$')

    if echo "$ports_list" | grep -qxF "$port"; then
        return 0
    fi

    return 1
}

# =============================================================================
# MAIN EMULATION FUNCTION
# =============================================================================

# Emulate packet and return JSON result
# Usage: nftban_emulate_packet <ip> [proto] [port] [direction]
nftban_emulate_packet() {
    local ip="$1"
    local proto="${2:-}"
    local port="${3:-}"
    local direction="${4:-in}"

    # =============================================================================
    # PERFORMANCE OPTIMIZATION: Delegate to Go implementation if available
    # =============================================================================
    # The Go implementation uses efficient data structures (O(log n) CIDR matching)
    # instead of pure Bash loops (O(n²) for large threat feeds).
    #
    # Performance comparison:
    #   - Bash: ~30 seconds for 100K IPs (unusable)
    #   - Go:   ~0.1 seconds for 100K IPs (1000x faster)
    #
    # Fallback: If nftban-core emulate is not available, use legacy Bash implementation below.
    # =============================================================================
    if command -v nftban-core >/dev/null 2>&1; then
        # Check if emulate command exists
        if nftban-core help 2>/dev/null | grep -q "emulate"; then
            # Use Go implementation (fast)
            nftban-core emulate "$ip" "$proto" "$port" "$direction" 2>/dev/null && return 0
            # Fall through to Bash on error
        fi
    fi

    # =============================================================================
    # LEGACY BASH IMPLEMENTATION (SLOW - O(n²) for large sets)
    # =============================================================================
    # WARNING: This implementation uses pure Bash loops to check IP membership
    # in nftables sets. For large threat feeds (100,000+ IPs), this becomes
    # extremely slow and may timeout.
    #
    # TODO: Remove this legacy code once Go implementation is deployed everywhere.
    # =============================================================================

    # Detect IP family
    local family="ip"
    if [[ "$ip" == *":"* ]]; then
        family="ip6"
    fi

    # Map direction to chain
    local chain="input"
    case "$direction" in
        in|input)   chain="input" ;;
        out|output) chain="output" ;;
        fwd|forward) chain="forward" ;;
    esac

    # Initialize result
    local decision="allow"
    local matched_set=""
    local matched_cidr=""
    local matched_handle=""
    local module=""
    local source=""
    local list_type=""
    local explanation=""

    # Evaluation order array for JSON
    local eval_order=""

    # 1. Check whitelist first
    local whitelist_set="whitelist_ipv4"
    [[ "$family" == "ip6" ]] && whitelist_set="whitelist_ipv6"

    local wl_match
    wl_match=$(_check_ip_in_set "$family" "$whitelist_set" "$ip")

    if [[ -n "$wl_match" ]]; then
        decision="allow"
        matched_set="$whitelist_set"
        matched_cidr="$wl_match"
        matched_handle=$(_get_set_rule_handle "$family" "$chain" "$whitelist_set")
        list_type="$whitelist_set"
        local mod_src
        mod_src=$(_detect_module_source "$ip" "$whitelist_set")
        module="${mod_src%|*}"
        source="${mod_src#*|}"
        explanation="The address $ip is part of $matched_cidr, which is in the whitelist (trusted IPs)."
        eval_order="{\"set\":\"$whitelist_set\",\"matched\":true,\"entry\":\"$wl_match\"}"
    else
        eval_order="{\"set\":\"$whitelist_set\",\"matched\":false}"

        # 2. Check blacklist_manual (hash set — manual/auto-detect bans)
        # v1.39.0: Check manual set first (O(1) lookup, most common for CLI bans)
        local manual_set="blacklist_manual_ipv4"
        [[ "$family" == "ip6" ]] && manual_set="blacklist_manual_ipv6"

        local manual_match
        manual_match=$(_check_ip_in_set "$family" "$manual_set" "$ip")

        if [[ -n "$manual_match" ]]; then
            decision="block"
            matched_set="$manual_set"
            matched_cidr="$manual_match"
            matched_handle=$(_get_set_rule_handle "$family" "$chain" "$manual_set")
            list_type="$manual_set"
            local mod_src
            mod_src=$(_detect_module_source "$ip" "$manual_set")
            module="${mod_src%|*}"
            source="${mod_src#*|}"
            explanation="The address $ip is part of $manual_match, which is in the manual blacklist (CLI/auto-detect bans)."
            eval_order="${eval_order},{\"set\":\"$manual_set\",\"matched\":true,\"entry\":\"$manual_match\"}"
        else
            eval_order="${eval_order},{\"set\":\"$manual_set\",\"matched\":false}"
        fi

        # 3. Check blacklist (interval set — feeds/geoban CIDRs)
        if [[ "$decision" != "block" ]]; then
        local blacklist_set="blacklist_ipv4"
        [[ "$family" == "ip6" ]] && blacklist_set="blacklist_ipv6"

        local bl_match
        bl_match=$(_check_ip_in_set "$family" "$blacklist_set" "$ip")

        if [[ -n "$bl_match" ]]; then
            decision="block"
            matched_set="$blacklist_set"
            matched_cidr="$bl_match"
            matched_handle=$(_get_set_rule_handle "$family" "$chain" "$blacklist_set")
            list_type="$blacklist_set"
            local mod_src
            mod_src=$(_detect_module_source "$ip" "$blacklist_set")
            module="${mod_src%|*}"
            source="${mod_src#*|}"
            explanation="The address $ip is part of $matched_cidr, which is in the unified blacklist."
            eval_order="${eval_order},{\"set\":\"$blacklist_set\",\"matched\":true,\"entry\":\"$bl_match\"}"
        else
            eval_order="${eval_order},{\"set\":\"$blacklist_set\",\"matched\":false}"
        fi
        fi

        if [[ "$decision" != "block" ]]; then

            # 4. Check port if specified (only for input/output chains)
            if [[ -n "$port" && -n "$proto" ]]; then
                local port_dir="in"
                [[ "$chain" == "output" ]] && port_dir="out"
                local port_set_name="${proto}_ports_${port_dir}"

                if ! _check_port_allowed "$proto" "$port" "$port_dir"; then
                    decision="block"
                    matched_set="$port_set_name"
                    module="port_filter"
                    source="not_in_allowed_ports"
                    list_type="$port_set_name"
                    explanation="Port $port/$proto is not in the allowed ${port_dir}bound ports set (${port_set_name}). Chain policy is drop."
                    eval_order="${eval_order},{\"set\":\"${port_set_name}\",\"matched\":false,\"reason\":\"port_not_allowed\"}"
                else
                    module="port_filter"
                    source="in_allowed_ports"
                    explanation="Port $port/$proto is in the allowed ${port_dir}bound ports set (${port_set_name})."
                    eval_order="${eval_order},{\"set\":\"${port_set_name}\",\"matched\":true}"
                fi
            fi

            # 5. Default policy
            if [[ "$decision" == "allow" && -z "$module" ]]; then
                if [[ -z "$port" || -z "$proto" ]]; then
                    # IP-only check: not in whitelist or blacklist
                    module="default_policy"
                    source="ip_only_check"
                    explanation="IP $ip is not in whitelist or blacklist. Note: chain policy is DROP for new connections — use --proto and --port to check port-level filtering."
                else
                    module="default_policy"
                    source="allowed"
                    explanation="Traffic allowed: IP not blocked, port is in allowed set."
                fi
            fi
        fi
    fi

    # v1.39.0: GeoIP + geoban context lookup
    local geo_country="unknown" geo_city="unknown" geo_banned="false"
    if declare -f nftban_geoip_lookup_fast &>/dev/null; then
        local geo_json
        geo_json=$(nftban_geoip_lookup_fast "$ip" 2>/dev/null) || true
        if [[ -n "$geo_json" ]] && command -v jq &>/dev/null; then
            geo_country=$(echo "$geo_json" | jq -r '.country // "unknown"' 2>/dev/null) || geo_country="unknown"
            geo_city=$(echo "$geo_json" | jq -r '.city // "unknown"' 2>/dev/null) || geo_city="unknown"
        fi
    elif command -v nftban-core &>/dev/null; then
        local geo_result
        geo_result=$(nftban-core geoip lookup "$ip" 2>/dev/null) || true
        if [[ -n "$geo_result" ]]; then
            geo_country="${geo_result%%/*}"
            geo_city="${geo_result#*/}"
        fi
    fi

    # Check if country is geo-banned
    local geoban_dir="${NFTBAN_CONFIG_DIR:-/etc/nftban}/geoban.d"
    local country_lower="${geo_country,,}"
    if [[ -f "${geoban_dir}/50-ban-${country_lower}.conf" ]]; then
        geo_banned="true"
    fi

    # Build JSON output
    cat <<EOF
{
  "query": {
    "ip": "$ip",
    "protocol": "${proto:-null}",
    "port": ${port:-null},
    "direction": "$direction",
    "family": "${family/ip/ipv}4"
  },
  "result": {
    "decision": "$decision",
    "reason": {
      "module": "${module:-unknown}",
      "source": "${source:-unknown}",
      "list_type": "${list_type:-none}",
      "matching_cidr": "${matched_cidr:-null}"
    },
    "nftables": {
      "family": "$family",
      "table": "nftban",
      "chain": "$chain",
      "rule_handle": ${matched_handle:-null},
      "set_name": "${matched_set:-null}"
    },
    "geo": {
      "country": "${geo_country}",
      "city": "${geo_city}",
      "geo_banned": ${geo_banned}
    },
    "explanation": "$explanation"
  },
  "evaluation_order": [${eval_order}]
}
EOF
}

# Format emulation result as pretty text
nftban_emulate_format_text() {
    local json="$1"

    # Parse JSON (using jq if available, or basic parsing)
    local ip decision module source list_type matching_cidr chain handle explanation
    local geo_country="unknown" geo_city="unknown" geo_banned="false"

    if command -v jq &>/dev/null; then
        ip=$(echo "$json" | jq -r '.query.ip')
        decision=$(echo "$json" | jq -r '.result.decision')
        module=$(echo "$json" | jq -r '.result.reason.module')
        source=$(echo "$json" | jq -r '.result.reason.source')
        list_type=$(echo "$json" | jq -r '.result.reason.list_type')
        matching_cidr=$(echo "$json" | jq -r '.result.reason.matching_cidr')
        chain=$(echo "$json" | jq -r '.result.nftables.chain')
        handle=$(echo "$json" | jq -r '.result.nftables.rule_handle')
        explanation=$(echo "$json" | jq -r '.result.explanation')
        geo_country=$(echo "$json" | jq -r '.result.geo.country // "unknown"')
        geo_city=$(echo "$json" | jq -r '.result.geo.city // "unknown"')
        geo_banned=$(echo "$json" | jq -r '.result.geo.geo_banned // false')
    else
        # Basic parsing without jq
        ip=$(echo "$json" | grep -o '"ip": *"[^"]*"' | head -1 | cut -d'"' -f4)
        decision=$(echo "$json" | grep -o '"decision": *"[^"]*"' | cut -d'"' -f4)
        module=$(echo "$json" | grep -o '"module": *"[^"]*"' | cut -d'"' -f4)
        source=$(echo "$json" | grep -o '"source": *"[^"]*"' | cut -d'"' -f4)
        list_type=$(echo "$json" | grep -o '"list_type": *"[^"]*"' | cut -d'"' -f4)
        matching_cidr=$(echo "$json" | grep -o '"matching_cidr": *"[^"]*"' | cut -d'"' -f4)
        chain=$(echo "$json" | grep -o '"chain": *"[^"]*"' | cut -d'"' -f4)
        handle=$(echo "$json" | grep -o '"rule_handle": *[0-9]*' | grep -o '[0-9]*')
        explanation=$(echo "$json" | grep -o '"explanation": *"[^"]*"' | cut -d'"' -f4)
        geo_country=$(echo "$json" | grep -o '"country": *"[^"]*"' | head -1 | cut -d'"' -f4)
        geo_city=$(echo "$json" | grep -o '"city": *"[^"]*"' | cut -d'"' -f4)
        geo_banned=$(echo "$json" | grep -o '"geo_banned": *[a-z]*' | grep -o '[a-z]*$')
    fi

    # Colors
    local RED='\033[0;31m'
    local GREEN='\033[0;32m'
    local YELLOW='\033[1;33m'
    local CYAN='\033[0;36m'
    local NC='\033[0m'
    local BOLD='\033[1m'

    # Disable colors if not terminal or disabled
    if [[ ! -t 1 ]] || [[ "${NFTBAN_COLOR_OUTPUT:-true}" != "true" ]]; then
        RED="" GREEN="" YELLOW="" CYAN="" NC="" BOLD=""
    fi

    local result_icon result_text result_color
    if [[ "$decision" == "block" ]]; then
        result_icon="❌"
        result_text="BLOCKED"
        result_color="$RED"
    else
        result_icon="✅"
        result_text="ALLOWED"
        result_color="$GREEN"
    fi

    cat <<EOF

${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
NFTBan Packet Emulation
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}

${BOLD}INPUT:${NC}   ${CYAN}${ip}${NC}
${BOLD}RESULT:${NC}  ${result_color}${result_icon} ${result_text}${NC}

${BOLD}GEO${NC}
────────────────────────────────────────────────────────────
  Country............ ${geo_country}${geo_city:+ (${geo_city})}
  Geo-banned......... $(if [[ "$geo_banned" == "true" ]]; then echo "${RED}YES${NC}"; else echo "${GREEN}no${NC}"; fi)

${BOLD}REASON${NC}
────────────────────────────────────────────────────────────
  Module............. ${YELLOW}${module}${NC}
  Source............. ${source}
  List type.......... ${list_type}
  Matching entry..... ${matching_cidr:-N/A}
  Table/Chain........ ip nftban → ${chain}
  Rule handle........ ${handle:-N/A}

${BOLD}EXPLANATION${NC}
────────────────────────────────────────────────────────────
  ${explanation}

${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
EOF
}

# Quick check function - returns just allow/block
nftban_emulate_quick() {
    local ip="$1"
    local result
    result=$(nftban_emulate_packet "$ip")
    echo "$result" | grep -o '"decision": *"[^"]*"' | cut -d'"' -f4
}

# Export functions
export -f nftban_emulate_packet
export -f nftban_emulate_format_text
export -f nftban_emulate_quick
export -f _ip_to_int
export -f _int_to_ip
export -f _ip_in_cidr
export -f _check_ip_in_set
