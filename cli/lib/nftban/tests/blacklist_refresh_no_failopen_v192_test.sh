#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.192.0 - Blacklist refresh no-fail-open runtime test (F-FEED / F-GEO)
# =============================================================================
# meta:name="blacklist_refresh_no_failopen_v192_test"
# meta:type="test"
# meta:version="1.192.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Lab-first: a shared-set refresh must never leave blacklist_* empty/partial (no fail-open window)"
# meta:inventory.files=""
# meta:inventory.binaries="bash,nft"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================
# F-FEED / F-GEO (D-NFTBAN-{FEED,GEOBAN}-REFRESH-FAILOPEN) runtime regression.
#
# The DETERMINISTIC, CI-enforced proof is the setsync Go unit test
# (renderSetReplaceScript: flush is the single FIRST statement, every other
# statement is an add → one nft -f transaction). This shell test demonstrates
# the property at the kernel level on a lab host (root + nft): it tight-loops a
# reader over a test set while the atomic flush+add replace runs, and asserts
# the set element count NEVER drops to 0 (no fail-open empty window). It also
# proves the test discriminates: the OLD non-atomic pattern (standalone flush,
# then a separate add) CAN be observed empty.
#
# Skips cleanly (exit 0) without root / nft.
# =============================================================================

set -Eeuo pipefail

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

echo "=== blacklist_refresh_no_failopen_v192 (F-FEED/F-GEO) ==="

if [[ "${EUID:-$(id -u)}" -ne 0 ]] || ! command -v nft >/dev/null 2>&1; then
    echo "  [SKIP] needs root + nft (lab-first); deterministic proof is the"
    echo "         setsync renderSetReplaceScript Go unit test."
    exit 0
fi

T="nftban_failopen_test_$$"
ELEMS="10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 203.0.113.0/24, 198.51.100.0/24"
cleanup() { nft delete table ip "$T" 2>/dev/null || true; }
trap cleanup EXIT

# Throwaway, NON-HOOKED table+set — cannot affect host networking.
nft -f - <<EOF
table ip $T {
    set blacklist_ipv4 {
        type ipv4_addr
        flags interval
        elements = { $ELEMS }
    }
}
EOF

count() { nft list set ip "$T" blacklist_ipv4 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' | wc -l | tr -d ' '; }

# Tight reader loop in background; records the MINIMUM element count seen.
reader() {
    local min=999 c
    local mark="/tmp/${T}_min"
    for _ in $(seq 1 4000); do
        c="$(count)"
        [[ -n "$c" && "$c" -lt "$min" ]] && min="$c"
    done
    echo "$min" > "$mark"
}

# --- Atomic path (the v1.192 fix): flush + add in ONE nft -f -----------------
reader & R=$!
sleep 0.02
for _ in $(seq 1 60); do
    printf 'flush set ip %s blacklist_ipv4\nadd element ip %s blacklist_ipv4 { %s }\n' "$T" "$T" "$ELEMS" | nft -f -
done
wait "$R" 2>/dev/null || true
MIN_ATOMIC="$(cat "/tmp/${T}_min" 2>/dev/null || echo 0)"; rm -f "/tmp/${T}_min"
echo "  [INFO] atomic replace: minimum element count observed = $MIN_ATOMIC (expect 5)"
if [[ "$MIN_ATOMIC" -ge 5 ]]; then
    ok "atomic flush+add: blacklist never observed empty/partial (min=$MIN_ATOMIC)"
else
    bad "atomic flush+add: blacklist dipped to $MIN_ATOMIC (fail-open window!)"
fi

# --- Discriminator: OLD non-atomic pattern CAN be seen empty -----------------
# (standalone flush, then a SEPARATE add — the pre-fix shape). We don't fail the
# test on this; we just confirm the harness can detect an empty window so the
# atomic PASS above is meaningful.
reader & R=$!
sleep 0.02
saw_empty=0
for _ in $(seq 1 60); do
    nft flush set ip "$T" blacklist_ipv4 2>/dev/null || true
    nft add element ip "$T" blacklist_ipv4 "{ $ELEMS }" 2>/dev/null || true
done
wait "$R" 2>/dev/null || true
MIN_OLD="$(cat "/tmp/${T}_min" 2>/dev/null || echo 0)"; rm -f "/tmp/${T}_min"
[[ "$MIN_OLD" -lt 5 ]] && saw_empty=1
echo "  [INFO] non-atomic (pre-fix) pattern: minimum observed = $MIN_OLD (discriminator; <5 expected if window is detectable)"
if [[ "$saw_empty" -eq 1 ]]; then
    ok "harness can detect the pre-fix fail-open window (discriminator valid)"
else
    echo "  [INFO] window not observed this run (timing); atomic PASS above still holds"
fi

echo ""
echo "=== blacklist_refresh_no_failopen_v192: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
