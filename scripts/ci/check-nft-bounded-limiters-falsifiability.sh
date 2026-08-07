#!/usr/bin/env bash
# =============================================================================
# NFTBan - falsifiability control for the bounded-limiter guard (v1.228.6)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="check-nft-bounded-limiters-falsifiability"
# meta:type="ci-guard"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-07"
# meta:description="Proves check-nft-bounded-limiters.sh discriminates. Injects each violation class the guard claims to reject (meter shorthand, timeout-less declaration, manifest omission, boot-copy divergence) and requires a FAIL that NAMES the injection; injects prose that merely mentions the constructs and requires a PASS. Every mutation is restored; the tree is verified back to baseline."
# meta:input="scripts/ci/check-nft-bounded-limiters.sh and the sources it reads"
# meta:output="PASS/FAIL per injection; exit 0 when the guard discriminates on every case"
# meta:depends="bash,grep,sed,cmp"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,sed,cmp"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

GUARD="scripts/ci/check-nft-bounded-limiters.sh"
CONF="install/nftables/nftables.conf"
FRAG="cli/lib/nftban/lib/nft_fragment.sh"
MANIFEST="scripts/ci/data/nft-limiter-capacity-policy.tsv"

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

BACKUP="$(mktemp -d)"
declare -A BACKED=()
_key() { printf '%s' "$1" | tr '/' '_'; }
backup() { cp -a "$1" "$BACKUP/$(_key "$1")"; BACKED["$1"]=1; }
restore_all() {
    local f
    for f in "${!BACKED[@]}"; do
        [[ -f "$BACKUP/$(_key "$f")" ]] && cp -a "$BACKUP/$(_key "$f")" "$f"
    done
    BACKED=()
}
trap 'restore_all; rm -rf "$BACKUP"' EXIT INT TERM

guard_rc() { bash "$GUARD" >/dev/null 2>&1; echo $?; }

echo "=== falsifiability control for $GUARD ==="
echo ""
echo "--- STAGE 0: baseline ---"
BASE_RC="$(guard_rc)"
if [[ "$BASE_RC" -eq 0 ]]; then
    ok "BASELINE_PASSES (rc=0) — injections below are attributable"
else
    bad "BASELINE_ALREADY_FAILS (rc=$BASE_RC)"
    echo "=== falsifiability: PASS=$PASS FAIL=$FAIL ==="
    exit 1
fi

expect_fail() {
    local name="$1" evidence="$2"; shift 2
    "$@"
    local out rc
    out="$(bash "$GUARD" 2>&1)"; rc=$?
    restore_all
    if [[ "$rc" -eq 0 ]]; then
        bad "BLIND TO: $name (guard returned PASS)"
    elif grep -qE "$evidence" <<<"$out"; then
        ok "DETECTS: $name"
    else
        bad "MISATTRIBUTED: $name (guard failed but never names the injection)"
    fi
}
expect_pass() {
    local name="$1"; shift
    "$@"
    local rc; rc="$(guard_rc)"
    restore_all
    if [[ "$rc" -eq 0 ]]; then ok "ACCEPTS: $name"; else bad "FALSE POSITIVE: $name"; fi
}

echo ""
echo "--- STAGE 1: violations the guard MUST reject ---"

m_shorthand_frag() {
    backup "$FRAG"
    sed -i 's|add rule ${table_ipv4} ${chain} udp dport 53 update @ddos_dns_udp {|add rule ${table_ipv4} ${chain} udp dport 53 meter zz_falsify_meter { ip saddr limit rate 9/second } return\nadd rule ${table_ipv4} ${chain} udp dport 53 update @ddos_dns_udp {|' "$FRAG"
}
# THE original defect shape: a meter-shorthand rule re-entering a render source.
expect_fail "a meter-shorthand rule reintroduced in the fragment authority" 'R1.*meter shorthand|zz_falsify_meter' m_shorthand_frag

m_timeout_less() {
    backup "$FRAG"
    sed -i 's|add set ${table_ipv4} ddos_dns_udp { type ipv4_addr; size 65535; flags dynamic,timeout; timeout 5m;|add set ${table_ipv4} ddos_dns_udp { type ipv4_addr; size 65535; flags dynamic;|' "$FRAG"
}
# The half-fix: named set, still unbounded — exactly what must never ship again.
expect_fail "a limiter declaration stripped of its timeout (unbounded named set)" "R2.*ddos_dns_udp.*timeout" m_timeout_less

m_manifest_row_gone() {
    backup "$MANIFEST"
    sed -i '/^ddos_dns_udp\t/d' "$MANIFEST"
}
expect_fail "a limiter losing its at-capacity policy row" 'R5.*ddos_dns_udp.*NO capacity-policy row' m_manifest_row_gone

m_bootcopy_diverge() {
    backup "$CONF"
    sed -i 's|update @syn_meter_v4 { ip saddr limit rate 25/second|update @syn_meter_v4 { ip saddr limit rate 999/second|' "$CONF"
}
# The gap the 28-anchor count check cannot see: the boot copy quietly diverging
# from the template in a limiter definition.
expect_fail "the pre-rendered boot copy diverging from the template" 'R4.*divergence' m_bootcopy_diverge

m_new_limiter_unclassified() {
    backup "$FRAG"
    sed -i 's|add set ${table_ipv4} ddos_dns_udp {|add set ${table_ipv4} zz_falsify_new { type ipv4_addr; size 100; flags dynamic,timeout; timeout 1m; }\nadd set ${table_ipv4} ddos_dns_udp {|' "$FRAG"
}
expect_fail "a NEW dynamic limiter appearing without a capacity-policy decision" 'R5.*zz_falsify_new' m_new_limiter_unclassified

m_v6_decl_gone() {
    backup "$FRAG"
    sed -i '/add set ${table_ipv6} ddos_dns_udp6 {/d' "$FRAG"
}
expect_fail "the v6 declaration of a paired limiter removed (parity break)" 'ddos_dns_udp6' m_v6_decl_gone

echo ""
echo "--- STAGE 2: correct constructs the guard must NOT reject ---"

m_prose_mention() {
    backup "$FRAG"
    sed -i 's|# --- IPv4 DDoS Protection ---|# --- IPv4 DDoS Protection ---\n# historical note: this used the form meter ddos_dns_udp { ip saddr limit rate N } before v1.228.6|' "$FRAG"
}
# GUARD SUBJECT == GUARD INPUT: prose describing the old construct is not the construct.
expect_pass "a comment DESCRIBING the old meter shorthand" m_prose_mention

echo ""
echo "--- STAGE 3: restoration ---"
FINAL_RC="$(guard_rc)"
if [[ "$FINAL_RC" -eq "$BASE_RC" ]]; then
    ok "TREE_RESTORED (guard rc back to baseline $BASE_RC)"
else
    bad "TREE_NOT_RESTORED (rc=$FINAL_RC, baseline=$BASE_RC) — INSPECT THE WORKING TREE"
fi

echo ""
echo "=== falsifiability: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]]
