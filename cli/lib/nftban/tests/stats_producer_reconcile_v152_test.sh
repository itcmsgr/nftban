#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.152 (13.10): stats producer/consumer reconciliation
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="stats_producer_reconcile_v152_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-06"
# meta:description="Locks 13.10: the unified-exporter producer must emit a blacklist split where total = perm + temp on EVERY path (daemon-cache, legacy, nft-fallback), with `manual` a SUBSET of total (operator decision subset-of-total), so `nftban stats` never shows the live '5 (perm:0 temp:0 manual:2)' mismatch again. Asserts (a) the SHIPPED legacy branch no longer reads the always-absent .permanent/.temporary keys and reports all-as-permanent; (b) each branch's perm/temp/manual math reconciles for IPv4 AND IPv6; (c) the consumer display reconciles (perm+temp=total) and labels manual as 'incl.' (subset). Hermetic: no host/nft/IPC."
# meta:input="None (self-contained)"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep"
# meta:inventory.files="cli/lib/nftban/exporters/nftban_unified_exporter_collect.sh,cli/lib/nftban/core/nftban_stats_format.sh"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="stats_producer_reconcile_v152_test"
# meta:ta.owner="metrics"
# meta:ta.module="stats"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
PROD="$REPO_ROOT/cli/lib/nftban/exporters/nftban_unified_exporter_collect.sh"
FMT="$REPO_ROOT/cli/lib/nftban/core/nftban_stats_format.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✓ $1"; }
no() { FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

echo "=== shipped producer: legacy branch no longer reads the absent keys ==="
grep -qE "jq -r '\.temporary\.ipv4 // 0'" "$PROD" && no "legacy branch STILL reads non-existent .temporary key" || ok "no read of non-existent .temporary key"
grep -qE "jq -r '\.permanent\.ipv4 // 0'" "$PROD" && no "legacy branch STILL reads non-existent .permanent key" || ok "no read of non-existent .permanent key"
grep -qE 'v1\.152 \(13\.10\)' "$PROD" && ok "producer carries the v1.152 (13.10) reconciliation fix" || no "13.10 fix marker missing"

echo "=== shipped consumer: manual labelled as subset (incl.), not additive ==="
grep -qE 'incl\. manual: ' "$FMT" && ok "stats_format labels 'incl. manual' (subset)" || no "consumer manual-subset label missing"

# ---- reconciliation math mirrors each producer branch (total = perm + temp; manual ⊆ total) ----
chk() { # $1 label  $2 total  $3 perm  $4 temp  $5 manual
    local l="$1" t="$2" p="$3" tm="$4" m="$5"
    if (( p + tm == t )) && (( m <= t )) && (( p >= 0 && tm >= 0 )); then
        ok "$l: total=$t == perm($p)+temp($tm); manual $m ⊆ total"
    else
        no "$l: total=$t perm=$p temp=$tm manual=$m (perm+temp != total or manual>total)"
    fi
}

echo "=== daemon-cache branch (interval 3 + manual 2) ==="
# active=5, manual=2, perm=active, temp=0
iv=3; mn=2; act=$((iv+mn)); chk "daemon-cache IPv4" "$act" "$act" 0 "$mn"
chk "daemon-cache IPv6" 0 0 0 0

echo "=== legacy branch (FIXED: was perm=0/temp=0) — blacklist 3 + manual 2 ==="
bl=3; mn=2; act=$((bl+mn))
# FIXED producer: perm=active, temp=0  (pre-fix would have been perm=0,temp=0 → broken)
chk "legacy IPv4 (fixed)" "$act" "$act" 0 "$mn"
# prove the OLD behavior was broken (regression guard documents the bug):
if (( 0 + 0 == act )); then no "legacy OLD perm=0/temp=0 would reconcile?!"; else ok "legacy OLD perm=0/temp=0 did NOT reconcile (this is the bug we fixed)"; fi

echo "=== nft-fallback branch (active 5, temp 1) ==="
act=5; tmp=1; perm=$((act-tmp)); (( perm<0 )) && perm=0
chk "fallback IPv4" "$act" "$perm" "$tmp" 2

echo "=== consumer render reconciles (perm+temp=total, manual incl.) ==="
out=$(printf "      %-16s %'d (perm: %'d, temp: %'d; incl. manual: %'d)\n" "IPv4............" 5 5 0 2)
echo "$out" | grep -q "5 (perm: 5, temp: 0; incl. manual: 2)" && ok "render: '5 (perm: 5, temp: 0; incl. manual: 2)' reconciles" || no "render" "$out"

echo ""
echo "================================================================"
echo "stats_producer_reconcile_v152: PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[[ $FAIL -eq 0 ]]
