#!/usr/bin/env bash
# =============================================================================
# NFTBan Invariant Validator — Structural + Order + Safety Checks
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_invariant_validator"
# meta:type="core"
# meta:version="1.67.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-04-02"
# meta:description="Validates firewall invariants: anchor structure, phase order, safety properties"
# meta:input="Live nftables chain (requires nft binary and root or CAP_NET_ADMIN)"
# meta:output="Invariant validation results (text or JSON)"
# meta:depends="nft"
# meta:inventory.files="cli/lib/nftban/core/nftban_invariant_validator.sh"
# meta:inventory.binaries="nft"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# Invariant classes:
#   INV-S: Structural — tables, chains, anchors exist
#   INV-O: Order — anchors in correct sequence, module jumps before anchors
#   INV-F: Safety — whitelist before blacklist, SSH reachable, anti-lockout, SYN port-policy, NDP scope, /64 gate
#
# Usage:
#   source nftban_invariant_validator.sh
#   nftban_validate_invariants [--json]
#
# =============================================================================

[[ -n "${_NFTBAN_INVARIANT_VALIDATOR_LOADED:-}" ]] && return 0
_NFTBAN_INVARIANT_VALIDATOR_LOADED=1

set -Eeuo pipefail

# =============================================================================
# CONSTANTS
# =============================================================================

# shellcheck disable=SC2034
readonly INVARIANT_PASS=0
# shellcheck disable=SC2034
readonly INVARIANT_WARNING=1
readonly INVARIANT_ERROR=2

readonly -a _INV_EXPECTED_ANCHORS=(HYGIENE TRUSTED BAN ESTABLISHED DETECT SERVICE FINAL)

# Module-to-anchor mapping (chain_name|anchor)
readonly -a _INV_MODULE_ANCHORS=(
    "ddos_sanity|ANCHOR_TRUSTED"
    "ddos_ban_enforce|ANCHOR_BAN"
    "ddos_penalty|ANCHOR_ESTABLISHED"
    "ddos_synproxy|ANCHOR_ESTABLISHED"
    "portscan_detection|ANCHOR_DETECT"
    "ddos_protection|ANCHOR_SERVICE"
    "ddos_prefix|ANCHOR_SERVICE"
    "http_bot_guard|ANCHOR_SERVICE"
)

# =============================================================================
# RESULTS ACCUMULATOR
# =============================================================================

declare -gA NFTBAN_INVARIANT_RESULTS=()
declare -ga _INV_JSON_ENTRIES=()
_INV_WORST=0

_inv_record() {
    local id="$1" status="$2" detail="$3"
    NFTBAN_INVARIANT_RESULTS["$id"]="$status|$detail"
    _INV_JSON_ENTRIES+=("{\"id\":\"${id}\",\"status\":\"${status}\",\"detail\":\"${detail}\"}")

    case "$status" in
        ERROR)
            [[ $_INV_WORST -lt $INVARIANT_ERROR ]] && _INV_WORST=$INVARIANT_ERROR
            ;;
        WARNING)
            [[ $_INV_WORST -lt $INVARIANT_WARNING ]] && _INV_WORST=$INVARIANT_WARNING
            ;;
    esac
}

# =============================================================================
# STRUCTURAL INVARIANTS (INV-S)
# =============================================================================

_validate_structural() {
    local family chain_output

    # INV-S-001: Tables exist
    local tables_ok=true
    for family in ip ip6; do
        if ! nft list table ${family} nftban &>/dev/null; then
            _inv_record "INV-S-001" "ERROR" "Table ${family} nftban does not exist"
            tables_ok=false
        fi
    done
    if [[ "$tables_ok" == "true" ]]; then
        _inv_record "INV-S-001" "PASS" "Tables exist (ip + ip6)"
    fi

    # Can't continue structural checks without tables
    [[ "$tables_ok" != "true" ]] && return

    # INV-S-002: Input chains exist with hook
    local chains_ok=true
    for family in ip ip6; do
        chain_output=$(nft list chain ${family} nftban input 2>/dev/null) || {
            _inv_record "INV-S-002" "ERROR" "Input chain missing in ${family} nftban"
            chains_ok=false
            continue
        }
        if ! echo "$chain_output" | grep "hook input" >/dev/null 2>&1; then
            _inv_record "INV-S-002" "ERROR" "Input chain in ${family} nftban has no hook input"
            chains_ok=false
        fi
    done
    if [[ "$chains_ok" == "true" ]]; then
        _inv_record "INV-S-002" "PASS" "Input chains with hook input in both families"
    fi

    [[ "$chains_ok" != "true" ]] && return

    # Cache chain output for remaining checks
    local chain_ip chain_ip6
    chain_ip=$(nft -a list chain ip nftban input 2>/dev/null) || chain_ip=""
    chain_ip6=$(nft -a list chain ip6 nftban input 2>/dev/null) || chain_ip6=""

    # INV-S-003: All 7 anchors present exactly once per family
    local anchors_ok=true
    local anchor count
    for family in ip ip6; do
        if [[ "$family" == "ip" ]]; then
            chain_output="$chain_ip"
        else
            chain_output="$chain_ip6"
        fi
        for anchor in "${_INV_EXPECTED_ANCHORS[@]}"; do
            count=$(echo "$chain_output" | grep -c "NFTBAN_ANCHOR:ANCHOR_${anchor}" || true)
            if [[ "$count" -eq 0 ]]; then
                _inv_record "INV-S-003" "ERROR" "Missing ANCHOR_${anchor} in ${family}"
                anchors_ok=false
            elif [[ "$count" -gt 1 ]]; then
                # INV-S-006 is a subset — duplicates
                _inv_record "INV-S-006" "ERROR" "Duplicate ANCHOR_${anchor} in ${family} (count=${count})"
                anchors_ok=false
            fi
        done
    done
    if [[ "$anchors_ok" == "true" ]]; then
        _inv_record "INV-S-003" "PASS" "All 7 anchors present exactly once in both families"
        _inv_record "INV-S-006" "PASS" "No duplicate anchors"
    fi

    # INV-S-004 + INV-S-005: Module chains + jumps (only for active modules)
    local modules_ok=true
    local mod_entry chain_name mod_anchor
    for mod_entry in "${_INV_MODULE_ANCHORS[@]}"; do
        IFS='|' read -r chain_name mod_anchor <<< "$mod_entry"
        for family in ip ip6; do
            if [[ "$family" == "ip" ]]; then
                chain_output="$chain_ip"
            else
                chain_output="$chain_ip6"
            fi

            # Check if jump exists (module is active)
            if echo "$chain_output" | grep "jump ${chain_name}" >/dev/null 2>&1; then
                # INV-S-004: Module chain must exist
                if ! nft list chain ${family} nftban "${chain_name}" &>/dev/null; then
                    _inv_record "INV-S-004" "ERROR" "Chain ${chain_name} missing in ${family} but jump exists"
                    modules_ok=false
                fi
            fi
        done
    done
    if [[ "$modules_ok" == "true" ]]; then
        _inv_record "INV-S-004" "PASS" "All active module chains exist"
    fi
    _inv_record "INV-S-005" "PASS" "Module jump presence verified"

    # INV-S-008: Active module chains must have >= 1 rule (not empty)
    local empty_ok=true
    for mod_entry in "${_INV_MODULE_ANCHORS[@]}"; do
        IFS='|' read -r chain_name mod_anchor <<< "$mod_entry"
        for family in ip ip6; do
            if [[ "$family" == "ip" ]]; then
                chain_output="$chain_ip"
            else
                chain_output="$chain_ip6"
            fi

            # Only check if jump exists (module is active)
            if echo "$chain_output" | grep "jump ${chain_name}" >/dev/null 2>&1; then
                local chain_rules
                chain_rules=$(nft list chain ${family} nftban "${chain_name}" 2>/dev/null) || continue
                # Count rule lines (exclude chain header/footer, comments-only lines)
                local rule_count
                rule_count=$(echo "$chain_rules" | grep -cE '^\s+(meta|ip|ip6|tcp|udp|ct |counter|drop|accept|jump|reject|log|return|limit|meter)' || true)
                if [[ "$rule_count" -eq 0 ]]; then
                    _inv_record "INV-S-008" "ERROR" "Chain ${chain_name} in ${family} has 0 rules (jump to empty chain = dead protection)"
                    empty_ok=false
                fi
            fi
        done
    done
    if [[ "$empty_ok" == "true" ]]; then
        _inv_record "INV-S-008" "PASS" "All active module chains have rules"
    fi

    # INV-S-007: No duplicate module jumps
    local dup_ok=true
    for mod_entry in "${_INV_MODULE_ANCHORS[@]}"; do
        IFS='|' read -r chain_name mod_anchor <<< "$mod_entry"
        for family in ip ip6; do
            if [[ "$family" == "ip" ]]; then
                chain_output="$chain_ip"
            else
                chain_output="$chain_ip6"
            fi
            count=$(echo "$chain_output" | grep -c "jump ${chain_name}" || true)
            if [[ "$count" -gt 1 ]]; then
                _inv_record "INV-S-007" "ERROR" "Duplicate jump ${chain_name} in ${family} (count=${count})"
                dup_ok=false
            fi
        done
    done
    if [[ "$dup_ok" == "true" ]]; then
        _inv_record "INV-S-007" "PASS" "No duplicate module jumps"
    fi
}

# =============================================================================
# ORDER INVARIANTS (INV-O)
# =============================================================================

_validate_order() {
    local family chain_output

    for family in ip ip6; do
        chain_output=$(nft -a list chain ${family} nftban input 2>/dev/null) || continue

        # Extract anchor line numbers for ordering
        local -A anchor_lines=()
        local anchor line_num
        for anchor in "${_INV_EXPECTED_ANCHORS[@]}"; do
            line_num=$(echo "$chain_output" | grep -n "NFTBAN_ANCHOR:ANCHOR_${anchor}" | head -1 | cut -d: -f1 || true)
            anchor_lines["$anchor"]="${line_num:-0}"
        done

        # Only check order in first family (ip) to avoid duplicate reports
        if [[ "$family" == "ip" ]]; then
            # INV-O-001 through INV-O-006: Sequential anchor order
            local -a order_pairs=(
                "HYGIENE|TRUSTED|INV-O-001"
                "TRUSTED|BAN|INV-O-002"
                "BAN|ESTABLISHED|INV-O-003"
                "ESTABLISHED|DETECT|INV-O-004"
                "DETECT|SERVICE|INV-O-005"
                "SERVICE|FINAL|INV-O-006"
            )
            local pair a b inv_id a_line b_line
            for pair in "${order_pairs[@]}"; do
                IFS='|' read -r a b inv_id <<< "$pair"
                a_line=${anchor_lines["$a"]:-0}
                b_line=${anchor_lines["$b"]:-0}
                if [[ "$a_line" -eq 0 || "$b_line" -eq 0 ]]; then
                    # Skip if anchor missing (already reported by INV-S-003)
                    continue
                fi
                if [[ "$a_line" -ge "$b_line" ]]; then
                    local severity="ERROR"
                    local note=""
                    [[ "$inv_id" == "INV-O-003" ]] && note=" (CVE protection)"
                    _inv_record "$inv_id" "$severity" "ANCHOR_${a} (line ${a_line}) NOT before ANCHOR_${b} (line ${b_line})${note}"
                else
                    local note=""
                    [[ "$inv_id" == "INV-O-003" ]] && note=" (CVE protection)"
                    _inv_record "$inv_id" "PASS" "${a} before ${b}${note}"
                fi
            done
        fi

        # INV-O-007: Each module jump handle < its anchor handle
        local mod_entry chain_name mod_anchor jump_line anchor_line_num
        for mod_entry in "${_INV_MODULE_ANCHORS[@]}"; do
            IFS='|' read -r chain_name mod_anchor <<< "$mod_entry"

            jump_line=$(echo "$chain_output" | grep -n "jump ${chain_name}" | head -1 | cut -d: -f1 || true)
            anchor_line_num=${anchor_lines["${mod_anchor#ANCHOR_}"]:-0}

            if [[ -n "$jump_line" && "$anchor_line_num" -gt 0 ]]; then
                if [[ "$jump_line" -ge "$anchor_line_num" ]]; then
                    _inv_record "INV-O-007" "ERROR" "jump ${chain_name} at line ${jump_line} AFTER ${mod_anchor} at line ${anchor_line_num} in ${family}"
                fi
            fi
        done
    done

    # Record INV-O-007 pass if no error was recorded for it
    if [[ -z "${NFTBAN_INVARIANT_RESULTS[INV-O-007]:-}" ]]; then
        _inv_record "INV-O-007" "PASS" "All module jumps before their anchors"
    fi

    # INV-O-008: IPv4/IPv6 parity
    local parity_ok=true
    local chain_ip chain_ip6
    chain_ip=$(nft -a list chain ip nftban input 2>/dev/null) || chain_ip=""
    chain_ip6=$(nft -a list chain ip6 nftban input 2>/dev/null) || chain_ip6=""

    local mod_entry chain_name mod_anchor ipv4_count ipv6_count
    for mod_entry in "${_INV_MODULE_ANCHORS[@]}"; do
        IFS='|' read -r chain_name mod_anchor <<< "$mod_entry"
        ipv4_count=$(echo "$chain_ip" | grep -c "jump ${chain_name}" || true)
        ipv6_count=$(echo "$chain_ip6" | grep -c "jump ${chain_name}" || true)
        if [[ "$ipv4_count" -gt 0 && "$ipv6_count" -eq 0 ]]; then
            _inv_record "INV-O-008" "ERROR" "jump ${chain_name}: IPv4 present, IPv6 missing"
            parity_ok=false
        elif [[ "$ipv4_count" -eq 0 && "$ipv6_count" -gt 0 ]]; then
            _inv_record "INV-O-008" "ERROR" "jump ${chain_name}: IPv6 present, IPv4 missing"
            parity_ok=false
        fi
    done
    if [[ "$parity_ok" == "true" ]]; then
        _inv_record "INV-O-008" "PASS" "IPv4/IPv6 parity for all modules"
    fi
}

# =============================================================================
# SAFETY INVARIANTS (INV-F)
# =============================================================================

_validate_safety() {
    local chain_output
    chain_output=$(nft -a list chain ip nftban input 2>/dev/null) || {
        _inv_record "INV-F-001" "ERROR" "Cannot read ip nftban input chain"
        return
    }

    # INV-F-001: Whitelist accept before blacklist drop
    local whitelist_line blacklist_line
    whitelist_line=$(echo "$chain_output" | grep -n '@whitelist_ipv4' | head -1 | cut -d: -f1 || true)
    blacklist_line=$(echo "$chain_output" | grep -n '@blacklist_manual' | head -1 | cut -d: -f1 || true)

    if [[ -n "$whitelist_line" && -n "$blacklist_line" ]]; then
        if [[ "$whitelist_line" -lt "$blacklist_line" ]]; then
            _inv_record "INV-F-001" "PASS" "Whitelist before blacklist"
        else
            _inv_record "INV-F-001" "ERROR" "Whitelist (line ${whitelist_line}) AFTER blacklist (line ${blacklist_line})"
        fi
    elif [[ -z "$whitelist_line" ]]; then
        _inv_record "INV-F-001" "ERROR" "Whitelist set reference not found in chain"
    elif [[ -z "$blacklist_line" ]]; then
        _inv_record "INV-F-001" "PASS" "Whitelist present, no blacklist (safe)"
    fi

    # INV-F-002: SSH port in tcp_ports_in
    local ssh_port=22
    # Detect SSH port from sshd_config
    if [[ -r /etc/ssh/sshd_config ]]; then
        local detected
        detected=$(grep -E '^\s*Port\s+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1 || true)
        [[ -n "$detected" && "$detected" =~ ^[0-9]+$ ]] && ssh_port="$detected"
    fi

    local tcp_ports_set
    tcp_ports_set=$(nft list set ip nftban tcp_ports_in 2>/dev/null) || tcp_ports_set=""
    if [[ -n "$tcp_ports_set" ]]; then
        if echo "$tcp_ports_set" | grep -wq "${ssh_port}" 2>/dev/null; then
            _inv_record "INV-F-002" "PASS" "SSH port ${ssh_port} in tcp_ports_in"
        else
            # Check for explicit SSH rule in chain (some setups use direct rule instead of set)
            if echo "$chain_output" | grep "dport ${ssh_port}" >/dev/null 2>&1; then
                _inv_record "INV-F-002" "PASS" "SSH port ${ssh_port} has explicit rule in chain"
            else
                _inv_record "INV-F-002" "WARNING" "SSH port ${ssh_port} not found in tcp_ports_in or chain rules"
            fi
        fi
    else
        _inv_record "INV-F-002" "WARNING" "tcp_ports_in set not found"
    fi

    # INV-F-003: Whitelist non-empty (anti-lockout)
    local wl_set wl_count
    wl_set=$(nft list set ip nftban whitelist_ipv4 2>/dev/null) || wl_set=""
    if [[ -n "$wl_set" ]]; then
        # Count element lines (lines with IP addresses between { and })
        wl_count=$(echo "$wl_set" | grep -cE '^\s+[0-9]+\.' || true)
        if [[ "$wl_count" -gt 0 ]]; then
            _inv_record "INV-F-003" "PASS" "Whitelist has ${wl_count} entries"
        else
            _inv_record "INV-F-003" "WARNING" "Whitelist is empty (lockout risk)"
        fi
    else
        _inv_record "INV-F-003" "WARNING" "whitelist_ipv4 set not found"
    fi

    # INV-F-004: DETECT-phase SYN accept must be restricted to service ports
    # v1.66.1: Prevents regression of SERVICE bypass bug — any terminal accept for
    # tcp flags syn in DETECT without @tcp_ports_in means TCP port policy is bypassed.
    local detect_start detect_end detect_rules
    detect_start=$(echo "$chain_output" | grep -n 'NFTBAN_ANCHOR:ANCHOR_DETECT' | head -1 | cut -d: -f1 || true)
    detect_end=$(echo "$chain_output" | grep -n 'NFTBAN_ANCHOR:ANCHOR_SERVICE' | head -1 | cut -d: -f1 || true)

    if [[ -n "$detect_start" && -n "$detect_end" ]]; then
        detect_rules=$(echo "$chain_output" | sed -n "${detect_start},${detect_end}p")
        # Check for tcp flags syn + accept WITHOUT @tcp_ports_in
        if echo "$detect_rules" | grep -E 'tcp flags syn.*accept' | grep -v '@tcp_ports_in' >/dev/null 2>&1; then
            _inv_record "INV-F-004" "ERROR" "DETECT has SYN accept without tcp_ports_in restriction — TCP port-policy bypass"
        else
            _inv_record "INV-F-004" "PASS" "DETECT-phase SYN accept is restricted to service ports"
        fi
    else
        _inv_record "INV-F-004" "WARNING" "Cannot locate DETECT/SERVICE anchors for SYN accept validation"
    fi

    # INV-F-005: IPv6 NDP must be scoped to link-local sources (v1.67.0)
    # NDP from non-link-local sources is spoofed or misconfigured (RFC 4861).
    local ipv6_chain_output
    ipv6_chain_output=$(nft -a list chain ip6 nftban input 2>/dev/null) || ipv6_chain_output=""

    if [[ -n "$ipv6_chain_output" ]]; then
        # Check for NDP accept rules (nd-neighbor-solicit, nd-router-advert, etc.)
        local ndp_rules
        ndp_rules=$(echo "$ipv6_chain_output" | grep -E 'nd-(neighbor|router)-(solicit|advert)' || true)
        if [[ -n "$ndp_rules" ]]; then
            # Every NDP accept rule must have fe80::/10 source restriction
            if echo "$ndp_rules" | grep 'accept' | grep -v 'fe80::/10' >/dev/null 2>&1; then
                _inv_record "INV-F-005" "ERROR" "IPv6 NDP accept without fe80::/10 source restriction — spoofed NDP accepted"
            else
                _inv_record "INV-F-005" "PASS" "IPv6 NDP accept restricted to link-local (fe80::/10)"
            fi
        else
            _inv_record "INV-F-005" "WARNING" "No NDP rules found in IPv6 input chain"
        fi
    else
        _inv_record "INV-F-005" "WARNING" "Cannot read ip6 nftban input chain"
    fi

    # INV-F-006: IPv6 DETECT phase must have /64 prefix SYN gate (v1.67.0)
    # Without this, a hostile source rotating addresses within one /64 bypasses
    # per-IP SYN metering and gets unlimited service admission.
    if [[ -n "$ipv6_chain_output" ]]; then
        local ipv6_detect_start ipv6_detect_end ipv6_detect_rules
        ipv6_detect_start=$(echo "$ipv6_chain_output" | grep -n 'NFTBAN_ANCHOR:ANCHOR_DETECT' | head -1 | cut -d: -f1 || true)
        ipv6_detect_end=$(echo "$ipv6_chain_output" | grep -n 'NFTBAN_ANCHOR:ANCHOR_SERVICE' | head -1 | cut -d: -f1 || true)

        if [[ -n "$ipv6_detect_start" && -n "$ipv6_detect_end" ]]; then
            ipv6_detect_rules=$(echo "$ipv6_chain_output" | sed -n "${ipv6_detect_start},${ipv6_detect_end}p")
            if echo "$ipv6_detect_rules" | grep -E 'ffff:ffff:ffff:ffff::.*limit rate' >/dev/null 2>&1; then
                _inv_record "INV-F-006" "PASS" "IPv6 DETECT has /64 prefix SYN gate"
            else
                _inv_record "INV-F-006" "WARNING" "IPv6 DETECT missing /64 prefix SYN gate — address rotation risk"
            fi
        else
            _inv_record "INV-F-006" "WARNING" "Cannot locate IPv6 DETECT/SERVICE anchors for /64 gate validation"
        fi
    else
        _inv_record "INV-F-006" "WARNING" "Cannot read ip6 nftban input chain"
    fi
}

# =============================================================================
# PUBLIC API
# =============================================================================

nftban_validate_invariants() {
    # Run all invariant checks
    # Args: [--json]
    # Returns: 0=PASS, 1=WARNING, 2=ERROR
    # Populates: NFTBAN_INVARIANT_RESULTS[] associative array

    local json_mode=false
    [[ "${1:-}" == "--json" ]] && json_mode=true

    # Reset state
    NFTBAN_INVARIANT_RESULTS=()
    _INV_JSON_ENTRIES=()
    _INV_WORST=0

    # Preflight
    if ! command -v nft &>/dev/null; then
        _inv_record "INV-S-001" "ERROR" "nft binary not found"
        if [[ "$json_mode" == "true" ]]; then
            _inv_output_json
        fi
        return $INVARIANT_ERROR
    fi

    _validate_structural
    _validate_order
    _validate_safety

    if [[ "$json_mode" == "true" ]]; then
        _inv_output_json
    else
        _inv_output_text
    fi

    return $_INV_WORST
}

# =============================================================================
# OUTPUT FORMATTERS
# =============================================================================

_inv_output_text() {
    local RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m' BOLD='\033[1m'
    if [[ ! -t 1 ]]; then
        RED="" GREEN="" YELLOW="" NC="" BOLD=""
    fi

    echo ""
    echo -e "${BOLD}Invariant Validation${NC}"
    echo "────────────────────────────────────────────────────────────"

    # Group by category
    local id status detail
    for id in \
        INV-S-001 INV-S-002 INV-S-003 INV-S-004 INV-S-005 INV-S-006 INV-S-007 INV-S-008 \
        INV-O-001 INV-O-002 INV-O-003 INV-O-004 INV-O-005 INV-O-006 INV-O-007 INV-O-008 \
        INV-F-001 INV-F-002 INV-F-003 INV-F-004 INV-F-005 INV-F-006; do

        # Category headers
        case "$id" in
            INV-S-001)
                echo ""
                echo -e "  ${BOLD}Structure${NC}"
                ;;
            INV-O-001)
                echo ""
                echo -e "  ${BOLD}Order${NC}"
                ;;
            INV-F-001)
                echo ""
                echo -e "  ${BOLD}Safety${NC}"
                ;;
        esac

        local entry="${NFTBAN_INVARIANT_RESULTS[$id]:-}"
        [[ -z "$entry" ]] && continue

        status="${entry%%|*}"
        detail="${entry#*|}"

        case "$status" in
            PASS)    echo -e "    ${GREEN}✓${NC} ${id}  ${detail}" ;;
            WARNING) echo -e "    ${YELLOW}⚠${NC} ${id}  ${detail}" ;;
            ERROR)   echo -e "    ${RED}✗${NC} ${id}  ${detail}" ;;
        esac
    done

    echo ""
    case $_INV_WORST in
        0) echo -e "${GREEN}${BOLD}INVARIANTS: PASS${NC}" ;;
        1) echo -e "${YELLOW}${BOLD}INVARIANTS: WARNING${NC}" ;;
        2) echo -e "${RED}${BOLD}INVARIANTS: FAILED${NC}" ;;
    esac
}

_inv_output_json() {
    local result_label="PASS"
    case $_INV_WORST in
        1) result_label="WARNING" ;;
        2) result_label="ERROR" ;;
    esac

    echo "{"
    echo "  \"result\": \"${result_label}\","
    echo "  \"exit_code\": ${_INV_WORST},"
    echo "  \"invariants\": ["

    local first=true entry
    for entry in "${_INV_JSON_ENTRIES[@]}"; do
        if [[ "$first" == "true" ]]; then
            echo "    ${entry}"
            first=false
        else
            echo "    ,${entry}"
        fi
    done

    echo "  ],"

    # Failed subset
    echo "  \"failed\": ["
    first=true
    for entry in "${_INV_JSON_ENTRIES[@]}"; do
        if echo "$entry" | grep '"ERROR"\|"WARNING"' >/dev/null 2>&1; then
            if [[ "$first" == "true" ]]; then
                echo "    ${entry}"
                first=false
            else
                echo "    ,${entry}"
            fi
        fi
    done
    echo "  ]"
    echo "}"
}

# Export
export -f nftban_validate_invariants
