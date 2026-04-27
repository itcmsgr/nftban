#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.82 - IP/Port Check + Firewall Stats
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_ip_and_stats"
# meta:type="core"
# meta:version="1.82.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="IP/port membership check and firewall statistics — extracted from nftban_validator.sh (B80-1 structural cleanup)"
# meta:inventory.files=""
# meta:inventory.binaries="nft,jq"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================
# These functions were previously in nftban_validator.sh alongside the
# validate_structure() shim. They have no relationship to validation —
# they are query/reporting functions. Extracted as part of v1.82 structural
# cleanup to enable full deletion of nftban_validator.sh.
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${NFTBAN_IP_AND_STATS_LOADED:-}" ]] && return 0
readonly NFTBAN_IP_AND_STATS_LOADED=1

# =============================================================================
# KERNEL QUERY HELPER (used by check_ip_or_port + get_firewall_stats)
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
    # =========================================================================
    # NOTE (v1.80, B80-1 — truth consolidation):
    # This function is now a THIN SHIM over the Go validator (nftban-validate).
    # It exists ONLY for backward compatibility with existing CLI callers:
    #   - cli/lib/nftban/cli/cmd_validate.sh:103  (nftban validate)
    #   - cli/lib/nftban/cli/cmd_firewall.sh:453+ (firewall reload/rebuild/reset
    #                                             validation fallback paths)
    #
    # It MUST NOT contain independent validation logic (no jq on nftables JSON,
    # no nft list ruleset, no spec loading). The single source of truth is the
    # Go validator binary at ${NFTBAN_LIB_DIR}/bin/nftban-validate — see
    # internal/validator/validator.go and the v1.78.0 kernel truth alignment.
    #
    # Output contract (MUST match legacy shell format byte-for-byte for callers):
    #   JSON: {status:"OK"|"WARNING"|"ERROR", errors:[], warnings:[], info:[]}
    #   Text: "NFTBan Structure Validation" header + status + error/warning lists
    #   Exit: 0 if status=="OK" or "WARNING", 1 if status=="ERROR"
    #
    # Full removal of this shell file (including the still-independent
    # check_ip_or_port and get_firewall_stats below) is v1.81 scope (B80-1).
    # =========================================================================
    #
    # Args: $1 = output_json (true/false)
    # Returns: 0 if OK/WARNING, 1 if ERROR

    local output_json="${1:-false}"
    local validator_bin="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/bin/nftban-validate"

    # Guardrail: the Go validator binary MUST exist. If it doesn't, we fail
    # closed with exit code 2 (distinct from generic validation failure so
    # callers can distinguish "tool missing" from "tool ran but validation
    # failed"). No independent fallback validation logic — that would
    # re-create the exact drift risk B80-1 is closing.
    #
    # NOTE: this fail-closed path must work WITHOUT jq. We use printf with
    # hand-escaped JSON because jq itself may be missing (the jq-missing
    # fallback below handles the happy path; here we must report the error
    # even on a broken-environment host).
    if [[ ! -x "$validator_bin" ]]; then
        local missing_msg="CRITICAL: Go validator binary not found at $validator_bin — reinstall nftban package"
        if [[ "$output_json" == "true" ]]; then
            # Hand-build JSON without jq: escape backslashes then double-quotes.
            local _escaped
            _escaped=$(printf '%s' "$missing_msg" | sed 's/\\/\\\\/g; s/"/\\"/g')
            printf '{"status":"ERROR","errors":["%s"],"warnings":[],"info":[]}\n' "$_escaped"
        else
            echo "NFTBan Structure Validation"
            echo "============================"
            echo ""
            echo "Status: ERROR"
            echo ""
            echo "❌ ERRORS (1):"
            echo "  $missing_msg"
        fi
        return 2
    fi

    # Call the Go validator. Capture its exit code — we derive shell exit
    # from (a) Go status, (b) error-severity finding count, and (c) the
    # validator binary's own exit code. Any of those indicating failure
    # must propagate as non-zero.
    #
    # R-1 (issue #469): prior behaviour derived exit ONLY from jq-mapped
    # error count, so a Go `status: down` with no critical/error findings
    # (or an unexpected jq result) produced exit 0 — the "misleading
    # success" class this release is fixing.
    #
    # BASH GOTCHA: `if ! var=$(cmd); then rc=$?; fi` sets $?=0 inside the
    # then-block (assignment exit 0, not cmd exit). The `|| rc=$?` idiom
    # correctly captures cmd's exit code without firing the ERR trap.
    local go_output=""
    local go_rc=0
    go_output="$("$validator_bin" --json 2>/dev/null)" || go_rc=$?

    if [[ -z "$go_output" ]]; then
        local empty_msg="CRITICAL: Go validator returned empty output"
        if [[ "$output_json" == "true" ]]; then
            local _escaped
            _escaped=$(printf '%s' "$empty_msg" | sed 's/\\/\\\\/g; s/"/\\"/g')
            printf '{"status":"ERROR","errors":["%s"],"warnings":[],"info":[]}\n' "$_escaped"
        else
            echo "NFTBan Structure Validation"
            echo "============================"
            echo ""
            echo "Status: ERROR"
            echo ""
            echo "❌ ERRORS (1):"
            echo "  $empty_msg"
        fi
        return 1
    fi

    # --- jq-missing fallback ---
    # When jq is not installed on this host (a broken-environment case —
    # jq is a declared nftban dependency) we cannot do schema translation
    # or preserve the full legacy output format, but we MUST preserve the
    # exit-code contract so callers see the right behaviour.
    #
    # Conservative grep on the Go output: protected → 0, anything else → 1.
    # Emit a minimal text banner so the caller is never silent.
    if ! command -v jq >/dev/null 2>&1; then
        if printf '%s' "$go_output" | grep -qi '"status"[[:space:]]*:[[:space:]]*"protected"'; then
            if [[ "$output_json" == "true" ]]; then
                printf '{"status":"OK","errors":[],"warnings":[],"info":[]}\n'
            else
                echo "NFTBan Structure Validation"
                echo "============================"
                echo ""
                echo "Status: OK (jq unavailable — reduced reporting)"
                echo ""
                echo "✅ All validation checks passed!"
            fi
            return 0
        else
            if [[ "$output_json" == "true" ]]; then
                printf '{"status":"ERROR","errors":["CRITICAL: validation failed (jq unavailable — reduced reporting; run %s for details)"],"warnings":[],"info":[]}\n' \
                    "$validator_bin"
            else
                echo "NFTBan Structure Validation"
                echo "============================"
                echo ""
                echo "Status: ERROR (jq unavailable — reduced reporting)"
                echo ""
                echo "❌ ERRORS (1):"
                echo "  Validation failed. Run: $validator_bin for details."
            fi
            return 1
        fi
    fi

    # Translate Go validator schema → legacy shell schema.
    #
    # Go schema (internal/validator/types.go):
    #   {status:"protected"|"degraded"|"down", findings:[{severity,message,...}], ...}
    #
    # Shell schema (legacy contract this shim MUST preserve):
    #   {status:"OK"|"WARNING"|"ERROR", errors:[], warnings:[], info:[]}
    #
    # Rules:
    #   Go severity "critical" or "error" → shell errors[] with "CRITICAL: " prefix
    #   Go severity "warn"                → shell warnings[] with "WARNING: " prefix
    #   shell status derived from counts:
    #     errors>0   → "ERROR"
    #     warnings>0 → "WARNING"
    #     else       → "OK"
    local shell_json
    shell_json=$(printf '%s' "$go_output" | jq '
        . as $go |
        (($go.findings // [])
            | map(select(.severity == "critical" or .severity == "error"))
            | map("CRITICAL: " + (.message // "unknown error"))) as $errors |
        (($go.findings // [])
            | map(select(.severity == "warn"))
            | map("WARNING: " + (.message // "unknown warning"))) as $warnings |
        (if ($errors | length) > 0 then "ERROR"
         elif ($warnings | length) > 0 then "WARNING"
         else "OK" end) as $shell_status |
        {
            status: $shell_status,
            errors: $errors,
            warnings: $warnings,
            info: []
        }
    ')

    if [[ -z "$shell_json" ]]; then
        # jq failed to parse Go output — fail closed
        local parse_msg="CRITICAL: Go validator output could not be parsed (jq failed)"
        if [[ "$output_json" == "true" ]]; then
            jq -n --arg m "$parse_msg" \
                '{status:"ERROR",errors:[$m],warnings:[],info:[]}'
        else
            echo "NFTBan Structure Validation"
            echo "============================"
            echo ""
            echo "Status: ERROR"
            echo ""
            echo "❌ ERRORS (1):"
            echo "  $parse_msg"
        fi
        return 1
    fi

    # Extract status + counts in a single jq call (shim discipline: one jq
    # per distinct rendering purpose, not one jq per field).
    local status errors_count warnings_count
    {
        read -r status
        read -r errors_count
        read -r warnings_count
    } < <(printf '%s' "$shell_json" | jq -r '.status, (.errors | length), (.warnings | length)')

    if [[ "$output_json" == "true" ]]; then
        printf '%s\n' "$shell_json"
    else
        echo "NFTBan Structure Validation"
        echo "============================"
        echo ""
        echo "Status: $status"
        echo ""

        if [[ "$errors_count" -gt 0 ]]; then
            echo "❌ ERRORS (${errors_count}):"
            printf '%s' "$shell_json" | jq -r '.errors[] | "  " + .'
            echo ""
        fi

        if [[ "$warnings_count" -gt 0 ]]; then
            echo "⚠️  WARNINGS (${warnings_count}):"
            printf '%s' "$shell_json" | jq -r '.warnings[] | "  " + .'
            echo ""
        fi

        if [[ "$errors_count" -eq 0 && "$warnings_count" -eq 0 ]]; then
            echo "✅ All validation checks passed!"
        fi
    fi

    # R-1 (issue #469): exit code is the MAX of three failure signals:
    #   - shell errors_count > 0      (jq-mapped critical/error findings)
    #   - Go validator rc > 0         (validator binary itself reported failure)
    #   - Go status ∈ {down,degraded} (authoritative Go state, in case no
    #                                  finding carries critical/error severity)
    # Any of these → non-zero exit. All clear → 0.
    local go_status
    go_status=$(printf '%s' "$go_output" | jq -r '.status // empty' 2>/dev/null)

    if [[ "$errors_count" -gt 0 ]]; then
        return 1
    fi
    if (( go_rc != 0 )); then
        return "$go_rc"
    fi
    case "$go_status" in
        down)     return 2 ;;
        degraded) return 1 ;;
    esac
    return 0
}

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
        if nft get element "${table_family}" nftban "whitelist_${set_suffix}" "{ $value }" >/dev/null 2>&1; then
            status="allowed"
            matched_table="${table_family} nftban"
            matched_chain="input"
            matched_set="whitelist_${set_suffix}"
            verdict="accept"
            priority=0
            processing_path+=("  ✅ MATCHED: whitelist_${set_suffix} → ACCEPT (full access)")
        # Check blacklist (permanent + temporary with timeout)
        elif nft get element "${table_family}" nftban "blacklist_${set_suffix}" "{ $value }" >/dev/null 2>&1; then
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
        # Uses directional sets (tcp_ports_in/out, udp_ports_in/out) - v2.1 schema
        processing_path+=("→ Checking ip nftban input (priority 0)")

        local matched_sets=()

        # Check directional TCP port sets (new 4-set architecture)
        if nft get element ${NFTBAN_TABLE_IPV4} tcp_ports_in "{ $value }" >/dev/null 2>&1; then
            matched_sets+=("tcp_ports_in")
        fi
        if nft get element ${NFTBAN_TABLE_IPV4} tcp_ports_out "{ $value }" >/dev/null 2>&1; then
            matched_sets+=("tcp_ports_out")
        fi
        # Check directional UDP port sets
        if nft get element ${NFTBAN_TABLE_IPV4} udp_ports_in "{ $value }" >/dev/null 2>&1; then
            matched_sets+=("udp_ports_in")
        fi
        if nft get element ${NFTBAN_TABLE_IPV4} udp_ports_out "{ $value }" >/dev/null 2>&1; then
            matched_sets+=("udp_ports_out")
        fi
        # NOTE: Legacy tcp_ports/udp_ports sets removed in v2.1 schema
        # Only directional sets (tcp_ports_in, tcp_ports_out, udp_ports_in, udp_ports_out) are supported

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

    # Determine available actions (v1.18.0: use _ipv4/_ipv6 naming)
    local actions=()
    if [[ "$value_type" == "ip" ]]; then
        if [[ "$status" == "allowed" ]]; then
            if [[ "$matched_set" == "whitelist_ipv4" || "$matched_set" == "whitelist_ipv6" ]]; then
                actions+=("remove_from_whitelist" "add_to_blacklist")
            fi
        elif [[ "$status" == "blocked" ]]; then
            # v2.1: All bans are in unified blacklist_ipv4/ipv6 set
            if [[ "$matched_set" == "blacklist_ipv4" || "$matched_set" == "blacklist_ipv6" ]]; then
                actions+=("remove_from_blacklist" "add_to_whitelist")
            else
                # Unknown set - offer whitelist as fallback
                actions+=("add_to_whitelist")
            fi
        else
            actions+=("add_to_whitelist" "add_to_blacklist")
        fi
    elif [[ "$value_type" == "port" ]]; then
        if [[ "$status" == "allowed" ]]; then
            # Suggest removal from directional sets (v2.1 schema)
            actions+=("remove_from_tcp_ports_in" "remove_from_tcp_ports_out")
            actions+=("remove_from_udp_ports_in" "remove_from_udp_ports_out")
        else
            # Suggest adding to directional sets (v2.1 schema)
            actions+=("add_to_tcp_ports_in" "add_to_tcp_ports_out")
            actions+=("add_to_udp_ports_in" "add_to_udp_ports_out")
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

    # v1.47.0: Use normalized wrapper for cross-distro nft JSON compatibility
    whitelist_ipv4_count=$(nftban_nft_count_set_elements ip nftban whitelist_ipv4)
    whitelist_ipv6_count=$(nftban_nft_count_set_elements ip6 nftban whitelist_ipv6)
    blacklist_ipv4_count=$(nftban_nft_count_set_elements ip nftban blacklist_ipv4)
    blacklist_ipv6_count=$(nftban_nft_count_set_elements ip6 nftban blacklist_ipv6)
    # Directional port sets (v2.1 schema)
    tcp_ports_in_count=$(nftban_nft_count_set_elements ip nftban tcp_ports_in)
    tcp_ports_out_count=$(nftban_nft_count_set_elements ip nftban tcp_ports_out)
    udp_ports_in_count=$(nftban_nft_count_set_elements ip nftban udp_ports_in)
    udp_ports_out_count=$(nftban_nft_count_set_elements ip nftban udp_ports_out)

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
                    "ip nftban udp_ports_out": $udp_ports_out
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
        echo "  └─ Port Sets (v2.1 directional):"
        echo "      ├─ tcp_ports_in:   $tcp_ports_in_count ports (inbound TCP)"
        echo "      ├─ tcp_ports_out:  $tcp_ports_out_count ports (outbound TCP)"
        echo "      ├─ udp_ports_in:   $udp_ports_in_count ports (inbound UDP)"
        echo "      └─ udp_ports_out:  $udp_ports_out_count ports (outbound UDP)"
        echo ""
        echo "ip6 nftban (IPv6):"
        echo "  ├─ whitelist_ipv6:   $whitelist_ipv6_count IPs"
        echo "  └─ blacklist_ipv6:   $blacklist_ipv6_count IPs (permanent + temporary)"
    fi
}
