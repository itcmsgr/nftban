#!/usr/bin/env bash
# shellcheck disable=SC1083  # Braces in nftables syntax are literal, not bash
# =============================================================================
# NFTBan v1.0.0 - NFTables Validator Core Library
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_validator"
# meta:type="core"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Provides validation logic for nftables structure, IP/port checking, and firewall statistics"
# meta:inventory.files=""
# meta:inventory.binaries="nft,jq"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

# NFTBAN_LIB_DIR is set by the calling script (cmd_validator.sh, etc.)
# Don't set it here - just use it with fallback

# Load strict mode library
# shellcheck source=/usr/lib/nftban/lib/strict.sh
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/strict.sh"
else
    # Fallback to manual strict mode
    set -Eeuo pipefail
fi

# Load version library
# shellcheck source=/usr/lib/nftban/lib/version.sh
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/version.sh" ]]; then
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/version.sh"
fi

# Bootstrap NFTBAN_SHARE_DIR (may be readonly from nftban.conf)
: "${NFTBAN_SHARE_DIR:=/usr/share/nftban}"

# =============================================================================
# SPEC FILE MANAGEMENT
# =============================================================================

load_spec() {
    # Load NFTBan structure specification file
    # Priority: user override > default spec
    # Returns: Spec file contents (JSON)

    local spec_file=""

    # Priority: user override > default spec
    if [[ -f "${NFTBAN_CONFIG_DIR}/spec.json" ]]; then
        spec_file="${NFTBAN_CONFIG_DIR}/spec.json"
    elif [[ -f "/usr/share/nftban/specs/structure_default.json" ]]; then
        spec_file="/usr/share/nftban/specs/structure_default.json"
    elif [[ -f "${NFTBAN_SHARE_DIR}/specs/structure_default.json" ]]; then
        spec_file="${NFTBAN_SHARE_DIR}/specs/structure_default.json"
    else
        echo "ERROR: Cannot find spec file" >&2
        return 1
    fi

    if ! jq -e . "$spec_file" >/dev/null 2>&1; then
        echo "ERROR: Invalid JSON in spec file: $spec_file" >&2
        return 1
    fi

    cat "$spec_file"
}

# =============================================================================
# NFTABLES QUERY
# =============================================================================

get_live_ruleset() {
    # Get live nftables ruleset as JSON
    # Returns: Full ruleset in JSON format

    local output
    output=$(nft -j list ruleset 2>&1)
    local rc=$?

    if [[ $rc -ne 0 ]]; then
        echo "{\"error\": \"Failed to get nftables ruleset: $output\"}" >&2
        return 1
    fi

    echo "$output"
}

# =============================================================================
# STRUCTURE VALIDATION
# =============================================================================

validate_structure() {
    # Validate nftables structure against spec
    # Args: $1 = output_json (true/false)
    # Returns: 0 if OK, 1 if errors found
    #
    # PERFORMANCE: All validation checks use batch jq operations to avoid
    # spawning jq processes inside loops (which can cause 10,000+ process
    # spawns and 30+ second timeouts on large rulesets).

    local output_json="${1:-false}"
    local spec ruleset
    local errors=() warnings=() info=()

    # Load spec
    spec=$(load_spec) || return 1

    # Get live ruleset
    ruleset=$(get_live_ruleset) || return 1

    # ==========================================================================
    # BATCH CHECK: Required tables
    # Single jq call checks all required tables at once, outputs missing ones
    # ==========================================================================
    local missing_tables
    missing_tables=$(jq -r '
        # First arg ($spec) provides required tables, second ($ruleset) provides live state
        .spec.expected_structure.validation_checks.required_tables // [] |
        . as $required |
        # Build set of existing tables as "family name" strings
        (.ruleset.nftables // [] | map(select(.table?) | "\(.table.family) \(.table.name)")) as $existing |
        # Output only tables that are required but not existing
        $required[] | select(. as $r | $existing | index($r) | not)
    ' <<< "{\"spec\": $spec, \"ruleset\": $ruleset}")

    while IFS= read -r table; do
        [[ -z "$table" ]] && continue
        errors+=("CRITICAL: Missing required table: $table")
    done <<< "$missing_tables"

    # ==========================================================================
    # BATCH CHECK: Priority safety (other firewall chains)
    # Single jq call finds all chains that might bypass NFTBan, outputs as TSV
    # ==========================================================================
    local nftban_priority=-100
    local chain_issues
    chain_issues=$(jq -r --argjson nftban_prio "$nftban_priority" '
        # Find all base chains on input/forward hooks (excluding nftban table)
        (.nftables // []) |
        map(select(.chain? and .chain.table != "nftban" and
                   (.chain.hook == "input" or .chain.hook == "forward"))) |
        # Output as tab-separated: family, table, name, hook, prio, severity
        map([
            .chain.family,
            .chain.table,
            .chain.name,
            .chain.hook,
            (.chain.prio // 0 | tostring),
            (if (.chain.prio // 0) <= $nftban_prio then "critical" else "warning" end)
        ] | join("\t")) |
        .[]
    ' <<< "$ruleset")

    # Process chain issues (no jq in loop - uses tab-separated values)
    while IFS=$'\t' read -r family table name hook prio severity; do
        [[ -z "$family" ]] && continue
        if [[ "$severity" == "critical" ]]; then
            errors+=("CRITICAL: $family $table $name (priority $prio) runs before/with NFTBan (priority $nftban_priority) on $hook hook!")
        else
            warnings+=("WARNING: Other firewall chain detected: $family $table $name (priority $prio) - NFTBan runs first (safe)")
        fi
    done <<< "$chain_issues"

    # ==========================================================================
    # BATCH CHECK: Required sets
    # Single jq call checks all required sets at once, outputs missing ones
    # ==========================================================================
    local missing_sets
    missing_sets=$(jq -r '
        .spec.expected_structure.validation_checks.required_sets // [] |
        . as $required |
        # Build set of existing sets as "family table name" strings
        (.ruleset.nftables // [] | map(select(.set?) | "\(.set.family) \(.set.table) \(.set.name)")) as $existing |
        # Output only sets that are required but not existing
        $required[] | select(. as $r | $existing | index($r) | not)
    ' <<< "{\"spec\": $spec, \"ruleset\": $ruleset}")

    while IFS= read -r set_path; do
        [[ -z "$set_path" ]] && continue
        warnings+=("WARNING: Missing required set: $set_path")
    done <<< "$missing_sets"

    # ==========================================================================
    # BATCH CHECK: Chain policies
    # Single jq call checks all policy requirements, outputs mismatches as TSV
    # ==========================================================================
    local policy_issues
    policy_issues=$(jq -r '
        # Build lookup of actual chain policies: key="family table chain", value=policy
        (.ruleset.nftables // [] |
            map(select(.chain? and .chain.policy?) |
                {key: "\(.chain.family) \(.chain.table) \(.chain.name)", value: .chain.policy}) |
            from_entries
        ) as $actual_policies |
        # Check each expected policy, output mismatches as tab-separated
        (.spec.expected_structure.validation_checks.policy_checks // {}) |
        to_entries |
        map(
            select($actual_policies[.key] != null and $actual_policies[.key] != .value) |
            [.key, .value, $actual_policies[.key]] | join("\t")
        ) |
        .[]
    ' <<< "{\"spec\": $spec, \"ruleset\": $ruleset}")

    while IFS=$'\t' read -r chain_path expected_policy actual_policy; do
        [[ -z "$chain_path" ]] && continue
        errors+=("CRITICAL: Wrong policy on $chain_path: expected '$expected_policy', got '$actual_policy'")
    done <<< "$policy_issues"

    # Determine overall status
    local status="OK"
    if [[ ${#errors[@]} -gt 0 ]]; then
        status="ERROR"
    elif [[ ${#warnings[@]} -gt 0 ]]; then
        status="WARNING"
    fi

    # Output results
    if [[ "$output_json" == "true" ]]; then
        jq -n \
            --arg status "$status" \
            --argjson errors "$(printf '%s\n' "${errors[@]}" | jq -R . | jq -s .)" \
            --argjson warnings "$(printf '%s\n' "${warnings[@]}" | jq -R . | jq -s .)" \
            --argjson info "$(printf '%s\n' "${info[@]}" | jq -R . | jq -s .)" \
            '{status: $status, errors: $errors, warnings: $warnings, info: $info}'
    else
        # Human-readable output
        echo "NFTBan Structure Validation"
        echo "============================"
        echo ""
        echo "Status: $status"
        echo ""

        if [[ ${#errors[@]} -gt 0 ]]; then
            echo "❌ ERRORS (${#errors[@]}):"
            printf '  %s\n' "${errors[@]}"
            echo ""
        fi

        if [[ ${#warnings[@]} -gt 0 ]]; then
            echo "⚠️  WARNINGS (${#warnings[@]}):"
            printf '  %s\n' "${warnings[@]}"
            echo ""
        fi

        if [[ ${#errors[@]} -eq 0 && ${#warnings[@]} -eq 0 ]]; then
            echo "✅ All validation checks passed!"
        fi
    fi

    # Return non-zero if errors
    [[ ${#errors[@]} -eq 0 ]]
}

# =============================================================================
# IP/PORT CHECKING
# =============================================================================

check_ip_or_port() {
    # Check if IP or port is blocked/allowed in nftables
    # Args: $1 = value (IP or port), $2 = output_json (true/false)
    # Returns: Status, matched rule, processing path, available actions

    local value="$1"
    local output_json="${2:-false}"

    if [[ -z "$value" ]]; then
        echo "ERROR: No value provided" >&2
        return 1
    fi

    # Detect type: IP (contains . or :) or port (numeric)
    local value_type="unknown"
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        value_type="port"
    elif [[ "$value" =~ \. || "$value" =~ : ]]; then
        value_type="ip"
    else
        echo "ERROR: Invalid value format: $value" >&2
        return 1
    fi

    # Get live ruleset
    local ruleset
    ruleset=$(get_live_ruleset) || return 1

    # Initialize result
    local status="unknown"
    local matched_table=""
    local matched_chain=""
    local matched_set=""
    local matched_rule=""
    local verdict=""
    local priority=0
    local processing_path=()

    # Check processing path for new architecture (v0.7.3)
    # New architecture uses ip/ip6 nftban tables (not inet)
    # Single blacklist set with timeout support (no separate temp_ban)

    if [[ "$value_type" == "ip" ]]; then
        # Detect if IPv4 or IPv6
        local table_family="ip"
        local set_suffix="ipv4"
        if [[ "$value" =~ : ]]; then
            table_family="ip6"
            set_suffix="ipv6"
        fi

        processing_path+=("→ Checking ${table_family} nftban input (priority 0)")

        # Check whitelist first (highest priority in ruleset)
        if nft get element "${table_family}" nftban "whitelist_${set_suffix}" { "$value" } >/dev/null 2>&1; then
            status="allowed"
            matched_table="${table_family} nftban"
            matched_chain="input"
            matched_set="whitelist_${set_suffix}"
            verdict="accept"
            priority=0
            processing_path+=("  ✅ MATCHED: whitelist_${set_suffix} → ACCEPT (full access)")
        # Check blacklist (permanent + temporary with timeout)
        elif nft get element "${table_family}" nftban "blacklist_${set_suffix}" { "$value" } >/dev/null 2>&1; then
            status="blocked"
            matched_table="${table_family} nftban"
            matched_chain="input"
            matched_set="blacklist_${set_suffix}"
            verdict="drop"
            priority=0
            processing_path+=("  ❌ MATCHED: blacklist_${set_suffix} → DROP")
        else
            processing_path+=("  ⊘ No match in sets")
            processing_path+=("  → Default policy: DROP")
            status="blocked"
            matched_table="${table_family} nftban"
            matched_chain="input"
            verdict="drop"
            matched_rule="default policy"
        fi

    elif [[ "$value_type" == "port" ]]; then
        # For ports, check allowed port sets in ip nftban table
        # Supports both legacy (tcp_ports/udp_ports) and directional sets
        processing_path+=("→ Checking ip nftban input (priority 0)")

        local matched_sets=()

        # Check directional TCP port sets (new 4-set architecture)
        if nft get element ${NFTBAN_TABLE_IPV4} tcp_ports_in { "$value" } >/dev/null 2>&1; then
            matched_sets+=("tcp_ports_in")
        fi
        if nft get element ${NFTBAN_TABLE_IPV4} tcp_ports_out { "$value" } >/dev/null 2>&1; then
            matched_sets+=("tcp_ports_out")
        fi
        # Check directional UDP port sets
        if nft get element ${NFTBAN_TABLE_IPV4} udp_ports_in { "$value" } >/dev/null 2>&1; then
            matched_sets+=("udp_ports_in")
        fi
        if nft get element ${NFTBAN_TABLE_IPV4} udp_ports_out { "$value" } >/dev/null 2>&1; then
            matched_sets+=("udp_ports_out")
        fi
        # Check legacy TCP ports (backward compatibility)
        if nft get element ${NFTBAN_TABLE_IPV4} tcp_ports { "$value" } >/dev/null 2>&1; then
            matched_sets+=("tcp_ports")
        fi
        # Check legacy UDP ports (backward compatibility)
        if nft get element ${NFTBAN_TABLE_IPV4} udp_ports { "$value" } >/dev/null 2>&1; then
            matched_sets+=("udp_ports")
        fi

        if [[ ${#matched_sets[@]} -gt 0 ]]; then
            status="allowed"
            matched_table="${NFTBAN_TABLE_IPV4}"
            matched_chain="input"
            # Report first matched set, but show all in processing path
            matched_set="${matched_sets[0]}"
            verdict="accept"
            priority=0
            local all_matches
            all_matches=$(IFS=', '; echo "${matched_sets[*]}")
            processing_path+=("  ✅ MATCHED: ${all_matches} → ACCEPT")
        else
            processing_path+=("  ⊘ Not in any port sets (tcp/udp _ports_in/_ports_out or legacy)")
            processing_path+=("  → Default policy: DROP")
            status="blocked"
            matched_table="ip/ip6 nftban"
            matched_chain="input"
            verdict="drop"
            matched_rule="default policy"
        fi
    fi

    # Determine available actions
    local actions=()
    if [[ "$value_type" == "ip" ]]; then
        if [[ "$status" == "allowed" ]]; then
            if [[ "$matched_set" == "whitelist_v4" ]]; then
                actions+=("remove_from_whitelist" "add_to_blacklist")
            elif [[ "$matched_set" == "temp_whitelist_v4" ]]; then
                actions+=("remove_from_temp_whitelist" "add_to_blacklist")
            fi
        elif [[ "$status" == "blocked" ]]; then
            if [[ "$matched_set" == "blacklist_v4" ]]; then
                actions+=("remove_from_blacklist" "add_to_whitelist")
            elif [[ "$matched_set" == "temp_ban_v4" ]]; then
                actions+=("remove_from_temp_ban" "add_to_whitelist")
            else
                actions+=("add_to_whitelist")
            fi
        else
            actions+=("add_to_whitelist" "add_to_blacklist")
        fi
    elif [[ "$value_type" == "port" ]]; then
        if [[ "$status" == "allowed" ]]; then
            # Suggest removal from directional sets
            actions+=("remove_from_tcp_ports_in" "remove_from_tcp_ports_out")
            actions+=("remove_from_udp_ports_in" "remove_from_udp_ports_out")
            # Legacy set actions
            actions+=("remove_from_tcp_ports" "remove_from_udp_ports")
        else
            # Suggest adding to directional sets
            actions+=("add_to_tcp_ports_in" "add_to_tcp_ports_out")
            actions+=("add_to_udp_ports_in" "add_to_udp_ports_out")
            # Legacy set actions
            actions+=("add_to_tcp_ports" "add_to_udp_ports")
        fi
    fi

    # Output results
    if [[ "$output_json" == "true" ]]; then
        local matched_rule_json
        if [[ -n "$matched_set" ]]; then
            matched_rule_json=$(jq -n \
                --arg table "$matched_table" \
                --arg chain "$matched_chain" \
                --arg set "$matched_set" \
                --arg verdict "$verdict" \
                --argjson priority "$priority" \
                '{table: $table, chain: $chain, set: $set, verdict: $verdict, priority: $priority}')
        else
            matched_rule_json=$(jq -n \
                --arg table "$matched_table" \
                --arg chain "$matched_chain" \
                --arg rule "$matched_rule" \
                --arg verdict "$verdict" \
                '{table: $table, chain: $chain, rule: $rule, verdict: $verdict}')
        fi

        jq -n \
            --arg value "$value" \
            --arg type "$value_type" \
            --arg status "$status" \
            --argjson matched_rule "$matched_rule_json" \
            --argjson path "$(printf '%s\n' "${processing_path[@]}" | jq -R . | jq -s .)" \
            --argjson actions "$(printf '%s\n' "${actions[@]}" | jq -R . | jq -s .)" \
            '{value: $value, type: $type, status: $status, matched_rule: $matched_rule, path: $path, actions: $actions}'
    else
        # Human-readable output
        echo "IP/Port Check: $value"
        echo "============================"
        echo ""
        echo "Type:   $value_type"

        if [[ "$status" == "allowed" ]]; then
            echo "Status: ✅ ALLOWED"
        elif [[ "$status" == "blocked" ]]; then
            echo "Status: ❌ BLOCKED"
        else
            echo "Status: ❓ UNKNOWN"
        fi

        echo ""
        echo "Matched Rule:"
        echo "  Table:    $matched_table"
        echo "  Chain:    $matched_chain"
        if [[ -n "$matched_set" ]]; then
            echo "  Set:      $matched_set"
        fi
        if [[ -n "$matched_rule" ]]; then
            echo "  Rule:     $matched_rule"
        fi
        echo "  Verdict:  $verdict"
        if [[ $priority -ne 0 ]]; then
            echo "  Priority: $priority"
        fi

        echo ""
        echo "Processing Path:"
        printf '  %s\n' "${processing_path[@]}"

        if [[ ${#actions[@]} -gt 0 ]]; then
            echo ""
            echo "Available Actions:"
            printf '  - %s\n' "${actions[@]}"
        fi
    fi
}

# =============================================================================
# FIREWALL STATISTICS
# =============================================================================

get_firewall_stats() {
    # Get firewall statistics (table/chain/set/rule counts, IP counts per set)
    # Args: $1 = output_json (true/false)
    # Returns: Statistics summary

    local output_json="${1:-false}"

    local ruleset
    ruleset=$(get_live_ruleset) || return 1

    # Count tables
    local table_count
    table_count=$(echo "$ruleset" | jq '[.nftables[] | select(.table?)] | length')

    # Count chains
    local chain_count
    chain_count=$(echo "$ruleset" | jq '[.nftables[] | select(.chain?)] | length')

    # Count sets
    local set_count
    set_count=$(echo "$ruleset" | jq '[.nftables[] | select(.set?)] | length')

    # Count rules
    local rule_count
    rule_count=$(echo "$ruleset" | jq '[.nftables[] | select(.rule?)] | length')

    # Count IPs per set (v0.7.3 architecture: ip/ip6 nftban tables)
    local whitelist_ipv4_count=0
    local whitelist_ipv6_count=0
    local blacklist_ipv4_count=0
    local blacklist_ipv6_count=0
    # Directional port sets (new 4-set architecture)
    local tcp_ports_in_count=0
    local tcp_ports_out_count=0
    local udp_ports_in_count=0
    local udp_ports_out_count=0
    # Legacy port sets (backward compatibility)
    local tcp_ports_count=0
    local udp_ports_count=0

    whitelist_ipv4_count=$(nft -j list set ${NFTBAN_TABLE_IPV4} whitelist_ipv4 2>/dev/null | jq '[.nftables[] | select(.set?) | .set.elem[]? // empty] | length' || echo 0)
    whitelist_ipv6_count=$(nft -j list set ${NFTBAN_TABLE_IPV6} whitelist_ipv6 2>/dev/null | jq '[.nftables[] | select(.set?) | .set.elem[]? // empty] | length' || echo 0)
    blacklist_ipv4_count=$(nft -j list set ${NFTBAN_TABLE_IPV4} blacklist_ipv4 2>/dev/null | jq '[.nftables[] | select(.set?) | .set.elem[]? // empty] | length' || echo 0)
    blacklist_ipv6_count=$(nft -j list set ${NFTBAN_TABLE_IPV6} blacklist_ipv6 2>/dev/null | jq '[.nftables[] | select(.set?) | .set.elem[]? // empty] | length' || echo 0)
    # Directional port sets
    tcp_ports_in_count=$(nft -j list set ${NFTBAN_TABLE_IPV4} tcp_ports_in 2>/dev/null | jq '[.nftables[] | select(.set?) | .set.elem[]? // empty] | length' || echo 0)
    tcp_ports_out_count=$(nft -j list set ${NFTBAN_TABLE_IPV4} tcp_ports_out 2>/dev/null | jq '[.nftables[] | select(.set?) | .set.elem[]? // empty] | length' || echo 0)
    udp_ports_in_count=$(nft -j list set ${NFTBAN_TABLE_IPV4} udp_ports_in 2>/dev/null | jq '[.nftables[] | select(.set?) | .set.elem[]? // empty] | length' || echo 0)
    udp_ports_out_count=$(nft -j list set ${NFTBAN_TABLE_IPV4} udp_ports_out 2>/dev/null | jq '[.nftables[] | select(.set?) | .set.elem[]? // empty] | length' || echo 0)
    # Legacy port sets
    tcp_ports_count=$(nft -j list set ${NFTBAN_TABLE_IPV4} tcp_ports 2>/dev/null | jq '[.nftables[] | select(.set?) | .set.elem[]? // empty] | length' || echo 0)
    udp_ports_count=$(nft -j list set ${NFTBAN_TABLE_IPV4} udp_ports 2>/dev/null | jq '[.nftables[] | select(.set?) | .set.elem[]? // empty] | length' || echo 0)

    # Output results
    if [[ "$output_json" == "true" ]]; then
        jq -n \
            --argjson tables "$table_count" \
            --argjson chains "$chain_count" \
            --argjson sets "$set_count" \
            --argjson rules "$rule_count" \
            --argjson whitelist_ipv4 "$whitelist_ipv4_count" \
            --argjson whitelist_ipv6 "$whitelist_ipv6_count" \
            --argjson blacklist_ipv4 "$blacklist_ipv4_count" \
            --argjson blacklist_ipv6 "$blacklist_ipv6_count" \
            --argjson tcp_ports_in "$tcp_ports_in_count" \
            --argjson tcp_ports_out "$tcp_ports_out_count" \
            --argjson udp_ports_in "$udp_ports_in_count" \
            --argjson udp_ports_out "$udp_ports_out_count" \
            --argjson tcp_ports "$tcp_ports_count" \
            --argjson udp_ports "$udp_ports_count" \
            '{
                summary: {
                    tables: $tables,
                    chains: $chains,
                    sets: $sets,
                    rules: $rules
                },
                sets: {
                    "ip nftban whitelist_ipv4": $whitelist_ipv4,
                    "ip6 nftban whitelist_ipv6": $whitelist_ipv6,
                    "ip nftban blacklist_ipv4": $blacklist_ipv4,
                    "ip6 nftban blacklist_ipv6": $blacklist_ipv6,
                    "ip nftban tcp_ports_in": $tcp_ports_in,
                    "ip nftban tcp_ports_out": $tcp_ports_out,
                    "ip nftban udp_ports_in": $udp_ports_in,
                    "ip nftban udp_ports_out": $udp_ports_out,
                    "ip nftban tcp_ports (legacy)": $tcp_ports,
                    "ip nftban udp_ports (legacy)": $udp_ports
                }
            }'
    else
        # Human-readable output
        echo "NFTBan Firewall Statistics"
        echo "============================"
        echo ""
        echo "Summary:"
        echo "  Tables:  $table_count"
        echo "  Chains:  $chain_count"
        echo "  Sets:    $set_count"
        echo "  Rules:   $rule_count"
        echo ""
        echo "ip nftban (IPv4):"
        echo "  ├─ whitelist_ipv4:   $whitelist_ipv4_count IPs"
        echo "  ├─ blacklist_ipv4:   $blacklist_ipv4_count IPs (permanent + temporary)"
        echo "  │"
        echo "  ├─ Directional Port Sets:"
        echo "  │   ├─ tcp_ports_in:   $tcp_ports_in_count ports (inbound TCP)"
        echo "  │   ├─ tcp_ports_out:  $tcp_ports_out_count ports (outbound TCP)"
        echo "  │   ├─ udp_ports_in:   $udp_ports_in_count ports (inbound UDP)"
        echo "  │   └─ udp_ports_out:  $udp_ports_out_count ports (outbound UDP)"
        echo "  │"
        echo "  └─ Legacy Port Sets:"
        echo "      ├─ tcp_ports:      $tcp_ports_count ports"
        echo "      └─ udp_ports:      $udp_ports_count ports"
        echo ""
        echo "ip6 nftban (IPv6):"
        echo "  ├─ whitelist_ipv6:   $whitelist_ipv6_count IPs"
        echo "  └─ blacklist_ipv6:   $blacklist_ipv6_count IPs (permanent + temporary)"
    fi
}
