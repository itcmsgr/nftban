#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.150 F3: manual blacklist counts in the stats cache
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="stats_manual_cache_v150_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-05"
# meta:description="Tests for v1.150 F3 (manual-count truth, cache path). The exporter producer (nftban_unified_exporter_collect.sh) now emits a blacklist_manual{ipv4,ipv6,total} block into the stats cache, and the cache-hit dashboard consumer (nftban_stats_format.sh) reads + surfaces it (manual: N). Pre-v1.150 the cache lacked blacklist_manual so manual bans were invisible on cache-hit (cache-miss already counted them via HLT-09). Covers: cache-hit manual read, cache-miss manual read, zero-manual compatibility, existing permanent/temporary unchanged. STRICTLY symmetric IPv4 + IPv6. Hermetic: stubs the unified-cache accessor + kernel-count stubs; no host/nft/IPC, no root."
# meta:input="None (self-contained sandbox)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,jq,grep"
# meta:inventory.files="cli/lib/nftban/exporters/nftban_unified_exporter_collect.sh,cli/lib/nftban/core/nftban_stats_format.sh"
# meta:inventory.binaries="bash,jq,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="stats_manual_cache_v150_test"
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
EXP="$REPO_ROOT/cli/lib/nftban/exporters/nftban_unified_exporter_collect.sh"
FMT="$REPO_ROOT/cli/lib/nftban/core/nftban_stats_format.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✓ $1"; }
no() { FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
have() { if grep -q "$2" "$1"; then ok "$3"; else no "$3"; fi; }

echo "=== F3 producer (exporter) — structure (IPv4 + IPv6) ==="
have "$EXP" 'manual_v4=$bl_manual_v4'  "counts-json branch sets manual_v4"
have "$EXP" 'manual_v6=$bl_manual_v6'  "counts-json branch sets manual_v6"
have "$EXP" 'manual_v4=$fb_manual_v4'  "fallback branch sets manual_v4"
have "$EXP" 'manual_v6=$fb_manual_v6'  "fallback branch sets manual_v6"
have "$EXP" 'blacklist_manual.ipv4 // .sets.blacklist_manual_ipv4.count' "legacy branch reads manual ipv4"
have "$EXP" 'blacklist_manual.ipv6 // .sets.blacklist_manual_ipv6.count' "legacy branch reads manual ipv6"
have "$EXP" '"blacklist_manual": {' "cache emits blacklist_manual block"
have "$EXP" '"ipv4": ${manual_v4:-0}' "cache blacklist_manual.ipv4"
have "$EXP" '"ipv6": ${manual_v6:-0}' "cache blacklist_manual.ipv6"
# existing .blacklist block preserved (compat)
have "$EXP" '"blacklist": {' "existing .blacklist block preserved"

echo "=== F3 producer — functional cache fragment (IPv4 + IPv6 symmetric) ==="
emit() { # $1 manual_v4 $2 manual_v6 — mirrors the exporter heredoc fragment
    local manual_v4="$1" manual_v6="$2"
    printf '{ "blacklist": {"ipv4":{"total":98,"permanent":98,"temporary":0},"ipv6":{"total":10,"permanent":10,"temporary":0},"total":108}, "blacklist_manual": { "ipv4": %s, "ipv6": %s, "total": %s } }\n' \
        "${manual_v4:-0}" "${manual_v6:-0}" "$(( ${manual_v4:-0} + ${manual_v6:-0} ))"
}
J="$(emit 3 1)"
if printf '%s' "$J" | jq -e . >/dev/null 2>&1; then ok "producer JSON valid"; else no "producer JSON valid" "$J"; fi
[[ "$(printf '%s' "$J" | jq '.blacklist_manual.ipv4')" == 3 ]] && ok "producer .blacklist_manual.ipv4=3" || no "producer ipv4"
[[ "$(printf '%s' "$J" | jq '.blacklist_manual.ipv6')" == 1 ]] && ok "producer .blacklist_manual.ipv6=1" || no "producer ipv6"
[[ "$(printf '%s' "$J" | jq '.blacklist_manual.total')" == 4 ]] && ok "producer .blacklist_manual.total=4 (v4+v6)" || no "producer total"
# zero-manual compatibility: existing .blacklist fields intact, manual total 0
JZ="$(emit 0 0)"
[[ "$(printf '%s' "$JZ" | jq '.blacklist_manual.total')" == 0 ]] && ok "zero-manual: total=0" || no "zero-manual total"
[[ "$(printf '%s' "$JZ" | jq '.blacklist.ipv4.permanent')" == 98 ]] && ok "zero-manual: existing perm preserved" || no "perm preserved"
[[ "$(printf '%s' "$JZ" | jq '.blacklist.ipv4.temporary')" == 0 ]] && ok "zero-manual: existing temp preserved" || no "temp preserved"

echo "=== F3 consumer (dashboard) — structure (IPv4 + IPv6) ==="
have "$FMT" '.blacklist_manual.ipv4' "cache-hit reads .blacklist_manual.ipv4"
have "$FMT" '.blacklist_manual.ipv6' "cache-hit reads .blacklist_manual.ipv6"
have "$FMT" 'manual_v4=${v4m_count:-0}' "cache-miss sets manual_v4 from kernel count"
have "$FMT" 'manual_v6=${v6m_count:-0}' "cache-miss sets manual_v6 from kernel count"
have "$FMT" 'manual: %'"'"'d).*IPv4\|IPv4.*manual: %'"'"'d' "display: IPv4 shows manual:"
grep -q '"IPv6............" "\$black_v6" "\$black_v6_perm" "\$black_v6_temp" "\$manual_v6"' "$FMT" \
    && ok "display: IPv6 shows manual (symmetric)" || no "display: IPv6 manual"

echo "=== F3 consumer — functional read+display harness (drift-guarded above) ==="
# Mirrors the real cache-hit read + sanitize + display. Stubs the cache accessor.
declare -A _U
nftban_stats_get_unified() { local k="$1" d="${2:-0}"; echo "${_U[$k]:-$d}"; }
render() { # mirrors nftban_stats_format cache-hit manual read + display
    local black_v4 black_v4_perm black_v4_temp black_v6 black_v6_perm black_v6_temp manual_v4 manual_v6
    black_v4=$(nftban_stats_get_unified ".blacklist.ipv4.total" "0")
    black_v4_perm=$(nftban_stats_get_unified ".blacklist.ipv4.permanent" "0")
    black_v4_temp=$(nftban_stats_get_unified ".blacklist.ipv4.temporary" "0")
    black_v6=$(nftban_stats_get_unified ".blacklist.ipv6.total" "0")
    black_v6_perm=$(nftban_stats_get_unified ".blacklist.ipv6.permanent" "0")
    black_v6_temp=$(nftban_stats_get_unified ".blacklist.ipv6.temporary" "0")
    manual_v4=$(nftban_stats_get_unified ".blacklist_manual.ipv4" "0")
    manual_v6=$(nftban_stats_get_unified ".blacklist_manual.ipv6" "0")
    manual_v4=${manual_v4//[^0-9]/}; manual_v4=${manual_v4:-0}
    manual_v6=${manual_v6//[^0-9]/}; manual_v6=${manual_v6:-0}
    printf "IPv4 %d (perm: %d, temp: %d, manual: %d)\n" "$black_v4" "$black_v4_perm" "$black_v4_temp" "$manual_v4"
    printf "IPv6 %d (perm: %d, temp: %d, manual: %d)\n" "$black_v6" "$black_v6_perm" "$black_v6_temp" "$manual_v6"
}

# cache-hit: manual present in cache
_U=([".blacklist.ipv4.total"]=100 [".blacklist.ipv4.permanent"]=98 [".blacklist.ipv4.temporary"]=2 \
    [".blacklist.ipv6.total"]=10 [".blacklist.ipv6.permanent"]=9 [".blacklist.ipv6.temporary"]=1 \
    [".blacklist_manual.ipv4"]=5 [".blacklist_manual.ipv6"]=2)
OUT="$(render)"
echo "$OUT" | grep -q 'IPv4 100 (perm: 98, temp: 2, manual: 5)' && ok "cache-hit: IPv4 manual=5 surfaced" || no "cache-hit IPv4" "$OUT"
echo "$OUT" | grep -q 'IPv6 10 (perm: 9, temp: 1, manual: 2)'   && ok "cache-hit: IPv6 manual=2 surfaced" || no "cache-hit IPv6" "$OUT"
# perm/temp unchanged by F3
echo "$OUT" | grep -q 'perm: 98, temp: 2' && ok "cache-hit: IPv4 perm/temp unchanged" || no "IPv4 perm/temp"
echo "$OUT" | grep -q 'perm: 9, temp: 1'  && ok "cache-hit: IPv6 perm/temp unchanged" || no "IPv6 perm/temp"

# zero-manual compatibility (no blacklist_manual in cache → defaults 0)
_U=([".blacklist.ipv4.total"]=98 [".blacklist.ipv4.permanent"]=98 [".blacklist.ipv4.temporary"]=0 \
    [".blacklist.ipv6.total"]=0 [".blacklist.ipv6.permanent"]=0 [".blacklist.ipv6.temporary"]=0)
OUT="$(render)"
echo "$OUT" | grep -q 'IPv4 98 (perm: 98, temp: 0, manual: 0)' && ok "zero-manual: IPv4 manual=0, fields intact" || no "zero IPv4" "$OUT"
echo "$OUT" | grep -q 'IPv6 0 (perm: 0, temp: 0, manual: 0)'   && ok "zero-manual: IPv6 manual=0, fields intact" || no "zero IPv6" "$OUT"

# cache-miss parity: manual derived from kernel counts (v4m_count/v6m_count) — mirror
miss() { local v4m_count="$1" v6m_count="$2" manual_v4 manual_v6; manual_v4=${v4m_count:-0}; manual_v6=${v6m_count:-0}; echo "$manual_v4 $manual_v6"; }
[[ "$(miss 3 1)" == "3 1" ]] && ok "cache-miss: manual derived from kernel counts (v4=3,v6=1)" || no "cache-miss derive"

echo ""
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
