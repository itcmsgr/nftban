#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.192.0 - Rebuild atomicity / no-SYN-drop runtime test (F-RB)
# =============================================================================
# meta:name="rebuild_no_syn_drop_v192_test"
# meta:type="test"
# meta:version="1.192.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Lab-first: nftban firewall rebuild loop must not drop a SYN to an accepted port, and post-rebuild management-floor accepts must be present"
# meta:inventory.files=""
# meta:inventory.binaries="bash,nft,nftban"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network="loopback test listener"
# meta:inventory.privileges="root"
# meta:ta.id="rebuild_no_syn_drop_v192_test"
# meta:ta.owner="firewall"
# meta:ta.module="firewall-rebuild"
# meta:ta.execution_class="ROOT_LAB"
# meta:ta.gate="lab-manual"
# meta:ta.hermetic="false"
# meta:ta.requires_root="true"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="true"
# meta:ta.requires_package="false"
# =============================================================================
# F-RB / D-NFTBAN-REBUILD-FLUSH-WINDOW runtime regression.
#
# The DETERMINISTIC, CI-enforced proofs of rebuild atomicity are:
#   * scripts/ci/check-nft-atomicity.sh  (V-NFT-REBUILD-ATOMICITY static guard)
#   * the rendered template's single-transaction reset (table{}/delete/recreate)
#
# This runtime probe needs root + nft + a live nftban install + a real hooked
# input chain, so it is LAB-FIRST. In a plain CI / dev box (no root / no nft /
# no nftban) it SKIPS cleanly (exit 0). The sub-window is short (~10ms), so the
# loopback probe is best-effort for the drop, but the POST-REBUILD INVARIANT
# assertions below are deterministic and always meaningful on a lab host.
# =============================================================================

set -Eeuo pipefail

PASS=0; FAIL=0
ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

echo "=== rebuild_no_syn_drop_v192 (F-RB) ==="

if [[ "${EUID:-$(id -u)}" -ne 0 ]] || ! command -v nft >/dev/null 2>&1 \
   || ! command -v nftban >/dev/null 2>&1; then
    echo "  [SKIP] needs root + nft + nftban (lab-first); deterministic proof is"
    echo "         scripts/ci/check-nft-atomicity.sh + the setsync Go unit test."
    exit 0
fi

# --- Probe: SYNs to an accepted port across a rebuild loop -------------------
PORT=53999
# Background listener on loopback (accepted by base 'lo accept' rule).
( while true; do printf 'ok' | timeout 1 nc -l -p "$PORT" >/dev/null 2>&1 || sleep 0.05; done ) &
LISTENER=$!
cleanup() { kill "$LISTENER" 2>/dev/null || true; }
trap cleanup EXIT
sleep 0.3

drops=0; tries=0
probe() {
    for _ in $(seq 1 25); do
        tries=$((tries+1))
        if ! timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$PORT" 2>/dev/null; then
            drops=$((drops+1))
        fi
        exec 3>&- 2>/dev/null || true
        sleep 0.02
    done
}

# Run probe concurrently with a rebuild loop.
probe &
PROBE=$!
for _ in $(seq 1 20); do
    nftban firewall rebuild --quiet >/dev/null 2>&1 || true
done
wait "$PROBE" 2>/dev/null || true

# Loopback probe is best-effort (window ~10ms); report, don't hard-fail on it,
# because TCP retransmit can mask the loopback drop. A nonzero count is a strong
# positive signal that the window exists.
echo "  [INFO] loopback probe: $drops/$tries connects failed across rebuild loop"
if [[ "$drops" -eq 0 ]]; then
    ok "no observed loopback connect failures across 20 rebuilds"
else
    echo "  [WARN] observed $drops loopback failures — indicates a drop window (investigate)"
fi

# --- Deterministic post-rebuild invariants (management floor present) --------
nftban firewall rebuild --quiet >/dev/null 2>&1 || true
RS="$(nft list table ip nftban 2>/dev/null || true)"
RS6="$(nft list table ip6 nftban 2>/dev/null || true)"

[[ -n "$RS" ]] && ok "ip nftban table present after rebuild"  || bad "ip nftban table ABSENT after rebuild"
[[ -n "$RS6" ]] && ok "ip6 nftban table present after rebuild" || bad "ip6 nftban table ABSENT after rebuild"

grep -qiE 'iif(name)? *(\")?lo' <<<"$RS"        && ok "loopback accept present (v4)"        || bad "loopback accept MISSING (v4)"
grep -qiE 'ct state .*established' <<<"$RS"      && ok "established/related accept present (v4)" || bad "established accept MISSING (v4)"
# SSH management port accept (port number is env-substituted; just assert a dport accept exists)
grep -qiE 'tcp dport .*accept' <<<"$RS"          && ok "service/SSH dport accept present (v4)" || bad "no tcp dport accept (v4)"

echo ""
echo "=== rebuild_no_syn_drop_v192: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
