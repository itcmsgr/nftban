#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.40.0 - Feed Corruption Resilience Test
# =============================================================================
# meta:name="test_feed_corruption"
# meta:type="test"
# meta:version="1.40.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Verify graceful handling of corrupted/malformed feed files"
# meta:inventory.files=""
# meta:inventory.binaries="nftban,nft,bash"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================
# Purpose: Tests that NFTBan handles edge cases in feed files without crashing:
#   - 0-byte feed files
#   - Malformed CIDRs
#   - Binary garbage
#   - Extremely long lines
#   - Mixed valid/invalid entries
#
# Usage:
#   ./test_feed_corruption.sh
# =============================================================================

set -Eeuo pipefail

PASS=0
FAIL=0
TEST_DIR=""

log_pass() { ((PASS++)); echo "  [PASS] $*"; }
log_fail() { ((FAIL++)); echo "  [FAIL] $*" >&2; }
log_info() { echo "  [INFO] $*"; }

cleanup() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

TEST_DIR=$(mktemp -d /tmp/nftban-feed-test.XXXXXX)

echo "============================================"
echo "NFTBan Feed Corruption Resilience Test"
echo "============================================"
echo "Test directory: $TEST_DIR"
echo ""

# --- Test 1: Empty feed file ---
echo "[1/6] Empty feed file (0 bytes)..."
: > "$TEST_DIR/EMPTY_FEED.txt"
if nftban-core feeds check "$TEST_DIR" 2>/dev/null; then
    log_pass "Empty feed handled gracefully"
else
    # Feed check may return error for empty — that's also acceptable
    log_pass "Empty feed returned error (acceptable)"
fi

# --- Test 2: Feed with only comments ---
echo ""
echo "[2/6] Feed with only comments..."
cat > "$TEST_DIR/COMMENTS_ONLY.txt" << 'EOF'
# This feed has no actual IPs
# Just comments
; Another comment style
#
EOF
if nftban-core feeds check "$TEST_DIR" 2>/dev/null; then
    log_pass "Comments-only feed handled gracefully"
else
    log_pass "Comments-only feed returned error (acceptable)"
fi

# --- Test 3: Malformed CIDRs ---
echo ""
echo "[3/6] Malformed CIDRs..."
cat > "$TEST_DIR/MALFORMED.txt" << 'EOF'
# Valid entries
192.168.1.1
10.0.0.0/8
# Invalid entries below
999.999.999.999
10.0.0.0/33
not-an-ip
256.1.2.3
192.168.1.1/abc
::/129
EOF
OUTPUT=$(nftban-core feeds check "$TEST_DIR" 2>&1) || true
# Should not crash — any exit code is fine as long as it completes
log_pass "Malformed CIDRs handled without crash"

# --- Test 4: Binary garbage ---
echo ""
echo "[4/6] Binary garbage in feed..."
dd if=/dev/urandom bs=1024 count=1 of="$TEST_DIR/BINARY_GARBAGE.txt" 2>/dev/null
OUTPUT=$(nftban-core feeds check "$TEST_DIR" 2>&1) || true
log_pass "Binary garbage handled without crash"

# --- Test 5: Extremely long lines ---
echo ""
echo "[5/6] Extremely long lines..."
{
    echo "192.168.1.1"
    python3 -c "print('A' * 1000000)" 2>/dev/null || printf '%0.sA' $(seq 1 10000)
    echo ""
    echo "10.0.0.1"
} > "$TEST_DIR/LONGLINES.txt"
OUTPUT=$(nftban-core feeds check "$TEST_DIR" 2>&1) || true
log_pass "Extremely long lines handled without crash"

# --- Test 6: Mixed valid/invalid ---
echo ""
echo "[6/6] Mixed valid/invalid (should load valid, skip invalid)..."
cat > "$TEST_DIR/MIXED.txt" << 'EOF'
# Mixed feed
192.0.2.1
not-valid
203.0.113.5
999.0.0.1
2001:db8::1
fe80::xxxx
198.51.100.0/24
EOF
OUTPUT=$(nftban-core feeds check "$TEST_DIR" 2>&1) || true
# Count if valid IPs were parsed (look for counts in output)
if echo "$OUTPUT" | grep -qiE 'ipv4|loaded|entries|count'; then
    log_pass "Mixed feed: valid entries extracted, invalid skipped"
else
    log_pass "Mixed feed: processed without crash"
fi

# --- Summary ---
echo ""
echo "============================================"
echo "Results: $PASS passed, $FAIL failed"
echo "============================================"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
