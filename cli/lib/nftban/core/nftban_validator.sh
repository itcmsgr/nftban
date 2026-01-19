#!/usr/bin/env bash
# shellcheck disable=SC1083  # Braces in nftables syntax are literal, not bash
# =============================================================================
# NFTBan v1.0.0 - NFTables Validator Core Library
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Core validation and checking functions for nftables structure
#
# meta:name="nftban_validator"
# meta:type="core"
# meta:header="NFTBan Validator Library"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# **Description & Purpose**
# meta:description="Provides validation logic for nftables structure, IP/port checking, and firewall statistics"
# meta:input="Spec file (JSON), live nftables ruleset, IP/port values"
# meta:output="Validation results, IP/port status, firewall statistics (JSON or human-readable)"
#
# **Inventory & Requirements**
# meta:depends="bash,nft,jq"
# meta:inventory.files=""
# meta:inventory.binaries="nft,jq"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2025-11-13"
# meta:updated_date="2026-01-20"


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
NFTBAN_SHARE_DIR="${NFTBAN_SHARE_DIR:-/usr/share/nftban}"

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

    local output_json="${1:-false}"
    local spec ruleset
    local errors=() warnings=() info=()

    # Load spec
    spec=$(load_spec) || return 1

    # Get live ruleset
    ruleset=$(get_live_ruleset) || return 1

    # Check required tables
    local required_tables
    required_tables=$(echo "$spec" | jq -r '.expected_structure.validation_checks.required_tables[]')

    while IFS= read -r table; do
        [[ -z "$table" ]] && continue

        local table_family="${table%% *}"
        local table_name="${table#* }"

        if ! echo "$ruleset" | jq -e ".nftables[] | select(.table? and .table.family == \"$table_family\" and .table.name == \"$table_name\")" >/dev/null 2>&1; then
            errors+=("CRITICAL: Missing required table: $table")
        fi
    done <<< "$required_tables"

    # Check priority safety (NFTBan must run BEFORE other firewalls)
    # NFTBan uses priority -100, panel firewalls (CSF, Plesk, DirectAdmin) use 0
    local nftban_priority=-100

    # Check for other firewall chains on input/forward hooks
    for family in ip ip6; do
        for hook in input forward; do
            # Get all base chains on this hook (excluding nftban)
            local other_chains
            other_chains=$(echo "$ruleset" | jq -r ".nftables[] | select(.chain? and .chain.family == \"$family\" and .chain.hook == \"$hook\" and .chain.table != \"nftban\") | \"\(.chain.table) \(.chain.name) \(.chain.prio // 0)\"" 2>/dev/null || true)

            while IFS= read -r chain_info; do
                [[ -z "$chain_info" ]] && continue
                local other_table other_name other_prio
                read -r other_table other_name other_prio <<< "$chain_info"

                # Check if other chain could bypass NFTBan
                if [[ "$other_prio" -le "$nftban_priority" ]]; then
                    errors+=("CRITICAL: $family $other_table $other_name (priority $other_prio) runs before/with NFTBan (priority $nftban_priority) on $hook hook!")
                else
                    warnings+=("WARNING: Other firewall chain detected: $family $other_table $other_name (priority $other_prio) - NFTBan runs first (safe)")
                fi
            done <<< "$other_chains"
        done
    done

    # Check required sets
    local required_sets
    required_sets=$(echo "$spec" | jq -r '.expected_structure.validation_checks.required_sets[]')

    while IFS= read -r set_path; do
        [[ -z "$set_path" ]] && continue

        local set_family="${set_path%% *}"
        local set_table="${set_path#* }"
        set_table="${set_table%% *}"
        local set_name="${set_path##* }"

        if ! echo "$ruleset" | jq -e ".nftables[] | select(.set? and .set.family == \"$set_family\" and .set.table == \"$set_table\" and .set.name == \"$set_name\")" >/dev/null 2>&1; then
            warnings+=("WARNING: Missing required set: $set_path")
        fi
    done <<< "$required_sets"

    # Check chain policies
    local policy_checks
    policy_checks=$(echo "$spec" | jq -r '.expected_structure.validation_checks.policy_checks | to_entries[] | "\(.key)=\(.value)"')

    while IFS= read -r policy_check; do
        [[ -z "$policy_check" ]] && continue

        local chain_path="${policy_check%%=*}"
        local expected_policy="${policy_check##*=}"

        local chain_family="${chain_path%% *}"
        local chain_table="${chain_path#* }"
        chain_table="${chain_table%% *}"
        local chain_name="${chain_path##* }"

        local actual_policy
        actual_policy=$(echo "$ruleset" | jq -r ".nftables[] | select(.chain? and .chain.family == \"$chain_family\" and .chain.table == \"$chain_table\" and .chain.name == \"$chain_name\") | .chain.policy // empty")

        if [[ -n "$actual_policy" && "$actual_policy" != "$expected_policy" ]]; then
            errors+=("CRITICAL: Wrong policy on $chain_path: expected '$expected_policy', got '$actual_policy'")
        fi
    done <<< "$policy_checks"

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
        processing_path+=("→ Checking ip nftban input (priority 0)")

        # Check TCP ports
        if nft get element ${NFTBAN_TABLE_IPV4} tcp_ports { "$value" } >/dev/null 2>&1; then
            status="allowed"
            matched_table="${NFTBAN_TABLE_IPV4}"
            matched_chain="input"
            matched_set="tcp_ports"
            verdict="accept"
            priority=0
            processing_path+=("  ✅ MATCHED: tcp_ports → ACCEPT")
        # Check UDP ports
        elif nft get element ${NFTBAN_TABLE_IPV4} udp_ports { "$value" } >/dev/null 2>&1; then
            status="allowed"
            matched_table="${NFTBAN_TABLE_IPV4}"
            matched_chain="input"
            matched_set="udp_ports"
            verdict="accept"
            priority=0
            processing_path+=("  ✅ MATCHED: udp_ports → ACCEPT")
        else
            processing_path+=("  ⊘ Not in tcp_ports or udp_ports")
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
            actions+=("remove_from_tcp_ports" "remove_from_udp_ports")
        else
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
    local tcp_ports_count=0
    local udp_ports_count=0

    whitelist_ipv4_count=$(nft -j list set ${NFTBAN_TABLE_IPV4} whitelist_ipv4 2>/dev/null | jq '[.nftables[] | select(.set?) | .set.elem[]? // empty] | length' || echo 0)
    whitelist_ipv6_count=$(nft -j list set ${NFTBAN_TABLE_IPV6} whitelist_ipv6 2>/dev/null | jq '[.nftables[] | select(.set?) | .set.elem[]? // empty] | length' || echo 0)
    blacklist_ipv4_count=$(nft -j list set ${NFTBAN_TABLE_IPV4} blacklist_ipv4 2>/dev/null | jq '[.nftables[] | select(.set?) | .set.elem[]? // empty] | length' || echo 0)
    blacklist_ipv6_count=$(nft -j list set ${NFTBAN_TABLE_IPV6} blacklist_ipv6 2>/dev/null | jq '[.nftables[] | select(.set?) | .set.elem[]? // empty] | length' || echo 0)
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
                    "ip nftban tcp_ports": $tcp_ports,
                    "ip nftban udp_ports": $udp_ports
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
        echo "  ├─ tcp_ports:        $tcp_ports_count ports"
        echo "  └─ udp_ports:        $udp_ports_count ports"
        echo ""
        echo "ip6 nftban (IPv6):"
        echo "  ├─ whitelist_ipv6:   $whitelist_ipv6_count IPs"
        echo "  └─ blacklist_ipv6:   $blacklist_ipv6_count IPs (permanent + temporary)"
    fi
}
