#!/usr/bin/env bash
# =============================================================================
# NFTBan Chain Order Validator (G4 + G5 + G6)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="validate_chain_order"
# meta:type="ci"
# meta:version="1.61.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-04-01"
# meta:description="Validates module jump placement against anchors in live nft chain"
# meta:input="Live nftables chain (requires nft binary and root or CAP_NET_ADMIN)"
# meta:output="Per-module validation results (text or JSON)"
# meta:depends="nft"
# meta:inventory.files="scripts/validate-chain-order.sh"
# meta:inventory.binaries="nft"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# Gates:
#   G4: Verify each module jump exists and is BEFORE its anchor
#   G5: Verify IPv4/IPv6 family parity (jump exists in both or neither)
#   G6: Verify no duplicate jumps for the same module
#
# Exit codes:
#   0   All modules HEALTHY
#   1   General/usage error
#   10  Required jump missing
#   11  Jump after anchor (mispositioned)
#   12  Duplicate jump detected
#   13  Anchor missing (chain structure broken)
#   14  IPv4/IPv6 family parity broken
#
# Usage:
#   scripts/validate-chain-order.sh [--json] [--fix] [--module <name>]
#
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# MODULE DEFINITIONS
# =============================================================================
# Format: chain_name|anchor_grep|description|optional_flag
#   optional_flag: if "optional", module is not required to exist
#
# Anchor grep must match a UNIQUE line in the chain that the jump MUST precede.
# =============================================================================

declare -a MODULE_DEFS=(
    "ddos_sanity|@whitelist_ip|DDoS sanity|optional"
    "ddos_ban_enforce|@blacklist_manual|DDoS ban enforce|optional"
    "ddos_penalty|established,related|DDoS penalty|optional"
    "portscan_detection|syn_meter_v|Portscan detection|optional"
    "ddos_protection|@tcp_ports_in|DDoS classic|optional"
    "ddos_prefix|@tcp_ports_in|DDoS prefix|optional"
    "http_bot_guard|@tcp_ports_in|HTTP Bot Guard|optional"
    "ddos_synproxy|established,related|SYNPROXY|optional"
)

# =============================================================================
# CONFIGURATION
# =============================================================================

TABLE_IPV4="ip nftban"
TABLE_IPV6="ip6 nftban"
CHAIN="input"
JSON_OUTPUT=false
FIX_MODE=false
FILTER_MODULE=""

# =============================================================================
# OUTPUT HELPERS
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
BOLD='\033[1m'

# Disable colors if not terminal
if [[ ! -t 1 ]]; then
    RED="" GREEN="" YELLOW="" NC="" BOLD=""
fi

# JSON results accumulator
declare -a JSON_RESULTS=()
WORST_EXIT=0

_update_exit() {
    local code="$1"
    # First failure wins (unless we already have a worse one)
    if [[ "$WORST_EXIT" -eq 0 ]] || [[ "$code" -lt "$WORST_EXIT" && "$code" -ne 0 ]]; then
        WORST_EXIT="$code"
    fi
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json|-j) JSON_OUTPUT=true; shift ;;
        --fix)     FIX_MODE=true; shift ;;
        --module)  FILTER_MODULE="$2"; shift 2 ;;
        -h|--help)
            cat <<'HELP'
NFTBan Chain Order Validator

Validates that all placement-sensitive module jumps in the nftables
input chain are positioned BEFORE their respective anchors.

USAGE:
    scripts/validate-chain-order.sh [OPTIONS]

OPTIONS:
    --json          Output results as JSON array
    --fix           Attempt to re-insert mispositioned jumps (requires root)
    --module <name> Only validate a specific module
    -h, --help      Show this help

MODULES CHECKED:
    ddos_sanity       Must be BEFORE @whitelist_ip
    ddos_ban_enforce  Must be BEFORE @blacklist_manual
    ddos_penalty      Must be BEFORE established,related
    portscan_detection Must be BEFORE syn_meter
    ddos_protection   Must be BEFORE @tcp_ports_in
    ddos_prefix       Must be BEFORE @tcp_ports_in
    http_bot_guard    Must be BEFORE @tcp_ports_in
    ddos_synproxy     Must be BEFORE established,related

EXIT CODES:
    0   All validated modules are correctly positioned
    1   General/usage error
    10  Required jump missing (module enabled but jump not found)
    11  Jump after anchor (mispositioned — functionally dead)
    12  Duplicate jump detected (same module has >1 jump)
    13  Anchor missing (chain structure damaged — needs rebuild)
    14  IPv4/IPv6 family parity broken (jump in one family only)

EXAMPLES:
    # Validate all modules
    sudo scripts/validate-chain-order.sh

    # JSON output for CI
    sudo scripts/validate-chain-order.sh --json

    # Check only portscan
    sudo scripts/validate-chain-order.sh --module portscan_detection

    # Attempt auto-fix of mispositioned jumps
    sudo scripts/validate-chain-order.sh --fix
HELP
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# =============================================================================
# PREFLIGHT
# =============================================================================

# Check nft binary
if ! command -v nft &>/dev/null; then
    echo "ERROR: nft binary not found — cannot validate chain order" >&2
    exit 1
fi

# Check chain exists
if ! nft list chain ${TABLE_IPV4} ${CHAIN} &>/dev/null; then
    echo "ERROR: Chain '${TABLE_IPV4} ${CHAIN}' not found (nftban not loaded?)" >&2
    exit 1
fi

# =============================================================================
# CORE VALIDATION
# =============================================================================

# Cache chain output (one nft call per family)
CHAIN_IPV4=$(nft -a list chain ${TABLE_IPV4} ${CHAIN} 2>/dev/null) || CHAIN_IPV4=""
CHAIN_IPV6=$(nft -a list chain ${TABLE_IPV6} ${CHAIN} 2>/dev/null) || CHAIN_IPV6=""

# Validate a single module in a single family
# Usage: _validate_module <chain_output> <family_label> <chain_name> <anchor_grep> <description> <optional>
# Sets result in JSON_RESULTS and updates WORST_EXIT
_validate_module() {
    local chain_output="$1"
    local family="$2"
    local chain_name="$3"
    local anchor_grep="$4"
    local desc="$5"
    local optional="$6"

    local verdict="SKIP"
    local evidence=""
    local auto_fix="false"
    local jump_pos=0
    local anchor_pos=0

    # Find jump line number
    local jump_line
    jump_line=$(echo "$chain_output" | grep -n "jump ${chain_name}" | head -1) || true
    local jump_idx=""
    [[ -n "$jump_line" ]] && jump_idx=$(echo "$jump_line" | cut -d: -f1)

    # Count duplicate jumps (G6)
    local jump_count
    jump_count=$(echo "$chain_output" | grep -c "jump ${chain_name}" 2>/dev/null) || jump_count=0

    # Find anchor line number
    local anchor_line
    anchor_line=$(echo "$chain_output" | grep -n "${anchor_grep}" | head -1) || true
    local anchor_idx=""
    [[ -n "$anchor_line" ]] && anchor_idx=$(echo "$anchor_line" | cut -d: -f1)

    if [[ "$jump_count" -gt 1 ]]; then
        verdict="DUPLICATE"
        evidence="jump ${chain_name} appears ${jump_count} times in ${family} chain"
        _update_exit 12
    elif [[ -z "$jump_idx" ]]; then
        if [[ "$optional" == "optional" ]]; then
            verdict="SKIP"
            evidence="Module not active in ${family} (jump not found)"
        else
            verdict="MISSING"
            evidence="jump ${chain_name} not found in ${family} chain"
            auto_fix="true"
            _update_exit 10
        fi
    elif [[ -z "$anchor_idx" ]]; then
        verdict="ANCHOR_MISSING"
        evidence="Anchor '${anchor_grep}' not found in ${family} — chain structure damaged"
        auto_fix="false"
        _update_exit 13
    elif [[ "$jump_idx" -gt "$anchor_idx" ]]; then
        verdict="MISPOSITIONED"
        evidence="jump at line ${jump_idx}, anchor at line ${anchor_idx} — jump AFTER anchor"
        jump_pos=$jump_idx
        anchor_pos=$anchor_idx
        auto_fix="true"
        _update_exit 11
    else
        verdict="CORRECT"
        evidence="jump at line ${jump_idx}, anchor at line ${anchor_idx}"
        jump_pos=$jump_idx
        anchor_pos=$anchor_idx
    fi

    # JSON result
    JSON_RESULTS+=("{\"module\":\"${chain_name}\",\"family\":\"${family}\",\"jump_exists\":$( [[ -n "$jump_idx" ]] && echo true || echo false ),\"anchor_exists\":$( [[ -n "$anchor_idx" ]] && echo true || echo false ),\"jump_position\":${jump_pos},\"anchor_position\":${anchor_pos},\"verdict\":\"${verdict}\",\"evidence\":\"${evidence}\",\"auto_fix_possible\":${auto_fix}}")

    # Text output
    if [[ "$JSON_OUTPUT" != "true" ]]; then
        case "$verdict" in
            CORRECT)
                echo -e "  ${GREEN}CORRECT${NC}  ${family}  ${desc} (${chain_name}) — jump@${jump_pos} before anchor@${anchor_pos}"
                ;;
            MISPOSITIONED)
                echo -e "  ${RED}BROKEN${NC}   ${family}  ${desc} (${chain_name}) — jump@${jump_pos} AFTER anchor@${anchor_pos}"
                ;;
            MISSING)
                echo -e "  ${RED}MISSING${NC}  ${family}  ${desc} (${chain_name}) — jump not found"
                ;;
            DUPLICATE)
                echo -e "  ${RED}DUPL${NC}     ${family}  ${desc} (${chain_name}) — ${jump_count} jumps found"
                ;;
            ANCHOR_MISSING)
                echo -e "  ${RED}DAMAGED${NC}  ${family}  ${desc} (${chain_name}) — anchor '${anchor_grep}' missing"
                ;;
            SKIP)
                echo -e "  ${YELLOW}SKIP${NC}     ${family}  ${desc} (${chain_name}) — not active"
                ;;
        esac
    fi
}

# =============================================================================
# G5: FAMILY PARITY CHECK
# =============================================================================

# After individual module checks, verify IPv4/IPv6 parity
_check_family_parity() {
    local chain_name="$1"
    local desc="$2"

    local ipv4_exists ipv6_exists
    ipv4_exists=$(echo "$CHAIN_IPV4" | grep -c "jump ${chain_name}" 2>/dev/null) || ipv4_exists=0
    ipv6_exists=$(echo "$CHAIN_IPV6" | grep -c "jump ${chain_name}" 2>/dev/null) || ipv6_exists=0

    # Both present or both absent is fine
    if [[ "$ipv4_exists" -gt 0 && "$ipv6_exists" -eq 0 ]]; then
        if [[ "$JSON_OUTPUT" != "true" ]]; then
            echo -e "  ${RED}PARITY${NC}   ${desc} (${chain_name}) — IPv4 jump exists, IPv6 MISSING"
        fi
        JSON_RESULTS+=("{\"module\":\"${chain_name}\",\"family\":\"parity\",\"jump_exists\":true,\"anchor_exists\":true,\"jump_position\":0,\"anchor_position\":0,\"verdict\":\"PARITY_BROKEN\",\"evidence\":\"IPv4 jump exists but IPv6 missing\",\"auto_fix_possible\":true}")
        _update_exit 14
    elif [[ "$ipv4_exists" -eq 0 && "$ipv6_exists" -gt 0 ]]; then
        if [[ "$JSON_OUTPUT" != "true" ]]; then
            echo -e "  ${RED}PARITY${NC}   ${desc} (${chain_name}) — IPv6 jump exists, IPv4 MISSING"
        fi
        JSON_RESULTS+=("{\"module\":\"${chain_name}\",\"family\":\"parity\",\"jump_exists\":true,\"anchor_exists\":true,\"jump_position\":0,\"anchor_position\":0,\"verdict\":\"PARITY_BROKEN\",\"evidence\":\"IPv6 jump exists but IPv4 missing\",\"auto_fix_possible\":true}")
        _update_exit 14
    fi
}

# =============================================================================
# MAIN
# =============================================================================

if [[ "$JSON_OUTPUT" != "true" ]]; then
    echo -e "${BOLD}NFTBan Chain Order Validator${NC}"
    echo "────────────────────────────────────────────────────────────"
    echo ""
fi

for mod_entry in "${MODULE_DEFS[@]}"; do
    IFS='|' read -r chain_name anchor_grep desc optional <<< "$mod_entry"

    # Filter if --module specified
    if [[ -n "$FILTER_MODULE" && "$chain_name" != "$FILTER_MODULE" ]]; then
        continue
    fi

    # Validate in both families
    _validate_module "$CHAIN_IPV4" "ip" "$chain_name" "$anchor_grep" "$desc" "$optional"
    _validate_module "$CHAIN_IPV6" "ip6" "$chain_name" "$anchor_grep" "$desc" "$optional"

    # Family parity check (G5)
    _check_family_parity "$chain_name" "$desc"
done

# =============================================================================
# OUTPUT
# =============================================================================

if [[ "$JSON_OUTPUT" == "true" ]]; then
    echo "["
    local first=true
    for result in "${JSON_RESULTS[@]}"; do
        if [[ "$first" == "true" ]]; then
            echo "  ${result}"
            first=false
        else
            echo "  ,${result}"
        fi
    done
    echo "]"
else
    echo ""
    if [[ "$WORST_EXIT" -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}RESULT: HEALTHY${NC} — all active module jumps are correctly positioned"
    else
        echo -e "${RED}${BOLD}RESULT: FAILED${NC} (exit ${WORST_EXIT})"
        case "$WORST_EXIT" in
            10) echo "  One or more required jumps are missing" ;;
            11) echo "  One or more jumps are after their anchor (functionally dead)" ;;
            12) echo "  Duplicate jump detected" ;;
            13) echo "  Anchor missing — chain structure damaged, run: nftban firewall rebuild" ;;
            14) echo "  IPv4/IPv6 parity broken — module exists in one family only" ;;
        esac
        if [[ "$FIX_MODE" == "true" ]]; then
            echo ""
            echo "  Auto-fix: restart affected modules or run: nftban firewall rebuild"
        fi
    fi
fi

exit "$WORST_EXIT"
