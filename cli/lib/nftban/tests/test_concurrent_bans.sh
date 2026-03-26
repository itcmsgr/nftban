#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.40.0 - Concurrent Ban Safety Test
# =============================================================================
# meta:name="test_concurrent_bans"
# meta:type="test"
# meta:version="1.40.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Verify parallel ban/unban operations under contention"
# meta:inventory.files=""
# meta:inventory.binaries="nftban,nft,bash"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units="nftband.service"
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================
# Purpose: Exercises parallel ban/unban operations to verify flock/IPC
#          safety under contention. Detects race conditions, lost bans,
#          and phantom entries.
#
# Usage:
#   ./test_concurrent_bans.sh              # Default: 20 parallel bans
#   ./test_concurrent_bans.sh --count 50   # Custom count
# =============================================================================

set -Eeuo pipefail

PARALLEL_COUNT="${1:-20}"
[[ "$1" == "--count" ]] && PARALLEL_COUNT="${2:-20}"

PASS=0
FAIL=0
TEST_PREFIX="198.51.100"  # TEST-NET-2 (RFC 5737)

log_pass() { ((PASS++)); echo "  [PASS] $*"; }
log_fail() { ((FAIL++)); echo "  [FAIL] $*" >&2; }
log_info() { echo "  [INFO] $*"; }

cleanup() {
    log_info "Cleaning up test IPs..."
    for i in $(seq 1 "$PARALLEL_COUNT"); do
        nftban unban "${TEST_PREFIX}.${i}" --quiet 2>/dev/null || true
    done
}
trap cleanup EXIT

echo "============================================"
echo "NFTBan Concurrent Ban Safety Test"
echo "============================================"
echo "Parallel operations: $PARALLEL_COUNT"
echo ""

# --- Pre-check ---
echo "[1/5] Pre-check: Verifying nftband is running..."
if ! systemctl is-active nftband &>/dev/null; then
    echo "ERROR: nftband is not running" >&2
    exit 1
fi
log_pass "nftband is active"

# --- Test 1: Parallel bans ---
echo ""
echo "[2/5] Parallel ban: ${PARALLEL_COUNT} simultaneous bans..."
PIDS=()
for i in $(seq 1 "$PARALLEL_COUNT"); do
    nftban ban "${TEST_PREFIX}.${i}" --quiet 2>/dev/null &
    PIDS+=($!)
done

# Wait for all
ERRORS=0
for pid in "${PIDS[@]}"; do
    if ! wait "$pid" 2>/dev/null; then
        ((ERRORS++))
    fi
done

if [[ $ERRORS -eq 0 ]]; then
    log_pass "All $PARALLEL_COUNT parallel bans completed (0 errors)"
else
    log_fail "$ERRORS/$PARALLEL_COUNT parallel bans failed"
fi

# --- Test 2: Verify all IPs are actually banned ---
echo ""
echo "[3/5] Verification: Checking all IPs are in nft set..."
sleep 1  # Allow opqueue flush
MISSING=0
for i in $(seq 1 "$PARALLEL_COUNT"); do
    ip="${TEST_PREFIX}.${i}"
    if ! nft get element ip nftban blacklist_manual_ipv4 "{ $ip }" &>/dev/null; then
        log_fail "IP $ip NOT found in nft set after ban"
        ((MISSING++))
    fi
done

if [[ $MISSING -eq 0 ]]; then
    log_pass "All $PARALLEL_COUNT IPs verified in nft set"
else
    log_fail "$MISSING/$PARALLEL_COUNT IPs missing from nft set"
fi

# --- Test 3: Parallel unbans ---
echo ""
echo "[4/5] Parallel unban: ${PARALLEL_COUNT} simultaneous unbans..."
PIDS=()
for i in $(seq 1 "$PARALLEL_COUNT"); do
    nftban unban "${TEST_PREFIX}.${i}" --quiet 2>/dev/null &
    PIDS+=($!)
done

ERRORS=0
for pid in "${PIDS[@]}"; do
    if ! wait "$pid" 2>/dev/null; then
        ((ERRORS++))
    fi
done

if [[ $ERRORS -eq 0 ]]; then
    log_pass "All $PARALLEL_COUNT parallel unbans completed (0 errors)"
else
    log_fail "$ERRORS/$PARALLEL_COUNT parallel unbans failed"
fi

# --- Test 4: Verify all IPs are actually unbanned ---
echo ""
echo "[5/5] Verification: Checking all IPs removed from nft set..."
sleep 1
PHANTOM=0
for i in $(seq 1 "$PARALLEL_COUNT"); do
    ip="${TEST_PREFIX}.${i}"
    if nft get element ip nftban blacklist_manual_ipv4 "{ $ip }" &>/dev/null; then
        log_fail "IP $ip still in nft set after unban (phantom)"
        ((PHANTOM++))
    fi
done

if [[ $PHANTOM -eq 0 ]]; then
    log_pass "All $PARALLEL_COUNT IPs confirmed removed"
else
    log_fail "$PHANTOM/$PARALLEL_COUNT phantom entries remain"
fi

# --- Summary ---
echo ""
echo "============================================"
echo "Results: $PASS passed, $FAIL failed"
echo "============================================"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
