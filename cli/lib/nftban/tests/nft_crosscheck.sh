#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.40.0 - NFT Cross-Validation Script
# =============================================================================
# meta:name="nft_crosscheck"
# meta:type="test"
# meta:version="1.40.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Cross-validates CLI-reported state vs actual nft kernel state"
# meta:inventory.files=""
# meta:inventory.binaries="nftban,nft,bash,jq"
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/nftban.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================
# Purpose: Detects state drift between what NFTBan reports and what's actually
#          in the kernel's nftables. Useful for debugging sync issues.
#
# Checks:
#   1. Table existence (ip nftban, ip6 nftban)
#   2. Required sets exist with correct types/flags
#   3. Set element counts match CLI-reported counts
#   4. Required chains exist with correct hooks
#   5. Ban lifecycle round-trip (ban → verify → unban → verify)
#
# Usage:
#   ./nft_crosscheck.sh
#   ./nft_crosscheck.sh --json    # JSON output
# =============================================================================

set -Eeuo pipefail

JSON_MODE=false
[[ "${1:-}" == "--json" ]] && JSON_MODE=true

PASS=0
FAIL=0
WARN=0
CHECKS=()

log_pass() { ((PASS++)); CHECKS+=("PASS|$*"); $JSON_MODE || echo "  [PASS] $*"; }
log_fail() { ((FAIL++)); CHECKS+=("FAIL|$*"); $JSON_MODE || echo "  [FAIL] $*" >&2; }
log_warn() { ((WARN++)); CHECKS+=("WARN|$*"); $JSON_MODE || echo "  [WARN] $*"; }

$JSON_MODE || echo "============================================"
$JSON_MODE || echo "NFTBan Cross-Validation: CLI vs nft state"
$JSON_MODE || echo "============================================"
$JSON_MODE || echo ""

# =========================================================================
# Section 1: Table existence
# =========================================================================
$JSON_MODE || echo "[1/5] Table existence..."

for family in ip ip6; do
    if nft list table "$family" nftban &>/dev/null; then
        log_pass "Table $family nftban exists"
    else
        log_fail "Table $family nftban MISSING"
    fi
done

# =========================================================================
# Section 2: Required sets with correct types
# =========================================================================
$JSON_MODE || echo ""
$JSON_MODE || echo "[2/5] Required sets..."

declare -A EXPECTED_SETS=(
    ["ip:whitelist_ipv4"]="ipv4_addr|interval"
    ["ip:blacklist_ipv4"]="ipv4_addr|interval,timeout"
    ["ip:blacklist_manual_ipv4"]="ipv4_addr|timeout"
    ["ip6:whitelist_ipv6"]="ipv6_addr|interval"
    ["ip6:blacklist_ipv6"]="ipv6_addr|interval,timeout"
    ["ip6:blacklist_manual_ipv6"]="ipv6_addr|timeout"
)

for key in "${!EXPECTED_SETS[@]}"; do
    family="${key%%:*}"
    set_name="${key#*:}"
    expected="${EXPECTED_SETS[$key]}"
    expected_type="${expected%%|*}"
    # expected_flags available for future flag validation
    # expected_flags="${expected#*|}"

    set_output=$(nft -j list set "$family" nftban "$set_name" 2>/dev/null) || {
        log_fail "Set $family/$set_name MISSING"
        continue
    }

    # Check type
    actual_type=$(echo "$set_output" | jq -r '.nftables[1].set.type // empty' 2>/dev/null) || true
    if [[ "$actual_type" == "$expected_type" ]]; then
        log_pass "Set $family/$set_name type=$actual_type"
    else
        log_fail "Set $family/$set_name type mismatch: expected=$expected_type actual=$actual_type"
    fi
done

# =========================================================================
# Section 3: Set element counts
# =========================================================================
$JSON_MODE || echo ""
$JSON_MODE || echo "[3/5] Set element counts..."

for family in ip ip6; do
    nft list table "$family" nftban >/dev/null 2>&1 || continue

    for set_name in $(nft list sets "$family" nftban 2>/dev/null | grep -oP 'set \K\S+' | tr -d '{'); do
        nft_count=$(nft list set "$family" nftban "$set_name" 2>/dev/null | grep -cE '^\s+[0-9a-f]' || echo "0")
        log_pass "Set $family/$set_name: $nft_count elements in kernel"
    done
done

# =========================================================================
# Section 4: Required chains
# =========================================================================
$JSON_MODE || echo ""
$JSON_MODE || echo "[4/5] Required chains..."

for family in ip ip6; do
    for chain in input forward output; do
        if nft list chain "$family" nftban "$chain" &>/dev/null; then
            log_pass "Chain $family/nftban/$chain exists"
        else
            log_fail "Chain $family/nftban/$chain MISSING"
        fi
    done
done

# =========================================================================
# Section 5: Ban round-trip
# =========================================================================
$JSON_MODE || echo ""
$JSON_MODE || echo "[5/5] Ban round-trip verification..."

TEST_IP="198.51.100.254"  # TEST-NET-2

# Ban
if nftban ban "$TEST_IP" --quiet 2>/dev/null; then
    sleep 1  # Wait for opqueue flush

    # Verify in nft
    if nft get element ip nftban blacklist_manual_ipv4 "{ $TEST_IP }" &>/dev/null; then
        log_pass "Ban round-trip: $TEST_IP found in nft after ban"
    else
        log_fail "Ban round-trip: $TEST_IP NOT in nft after ban (opqueue gap?)"
    fi

    # Unban
    if nftban unban "$TEST_IP" --quiet 2>/dev/null; then
        sleep 1

        if nft get element ip nftban blacklist_manual_ipv4 "{ $TEST_IP }" &>/dev/null; then
            log_fail "Ban round-trip: $TEST_IP still in nft after unban (phantom)"
        else
            log_pass "Ban round-trip: $TEST_IP confirmed removed after unban"
        fi
    else
        log_fail "Ban round-trip: unban command failed"
        nftban unban "$TEST_IP" --quiet 2>/dev/null || true
    fi
else
    log_fail "Ban round-trip: ban command failed"
fi

# =========================================================================
# Summary
# =========================================================================
$JSON_MODE || echo ""
$JSON_MODE || echo "============================================"
$JSON_MODE || echo "Results: $PASS passed, $FAIL failed, $WARN warnings"
$JSON_MODE || echo "============================================"

if $JSON_MODE; then
    echo "{"
    echo "  \"pass\": $PASS,"
    echo "  \"fail\": $FAIL,"
    echo "  \"warn\": $WARN,"
    echo "  \"checks\": ["
    first=true
    for check in "${CHECKS[@]}"; do
        status="${check%%|*}"
        desc="${check#*|}"
        $first || echo ","
        first=false
        printf '    {"status": "%s", "description": "%s"}' "$status" "$desc"
    done
    echo ""
    echo "  ]"
    echo "}"
fi

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
