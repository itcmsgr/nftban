#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.150 F2: stats --json valid JSON (top_sources/top_filters)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="stats_json_top_sources_v150_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-05"
# meta:description="Tests for v1.150 F2. nftban_stats_top_sources (cache-hit path, feeds top_filters in stats --json) previously emitted a trailing/extra comma when some source counts were 0 (awk printed NR>1 comma but a $1>0-conditional object), producing invalid JSON that broke 'nftban stats --json' with 'jq: invalid JSON text passed to --argjson'. Asserts the builder now emits valid JSON for mixed-with-zeros, all-zero (->[]), and all-nonzero, and that the output is accepted by jq --argjson exactly as stats --json uses it. Hermetic: stubs the unified-cache accessors; no host/nft/IPC, no root."
# meta:input="None (self-contained sandbox)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,jq,awk,sort,date"
# meta:inventory.files="cli/lib/nftban/core/nftban_stats_collect.sh"
# meta:inventory.binaries="bash,jq,awk,sort,date"
# meta:inventory.env_vars="STATS_TOP_N,NFTBAN_BAN_LOG"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="stats_json_top_sources_v150_test"
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
SRC="$REPO_ROOT/cli/lib/nftban/core/nftban_stats_collect.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✓ $1"; }
no() { FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — got: $2}"; }

# Minimal env, then source the function library (defensive — it is a lib).
export STATS_TOP_N=10
export NFTBAN_BAN_LOG="/nonexistent/bans.log"
# shellcheck disable=SC1090
source "$SRC" 2>/dev/null || true

if ! declare -f nftban_stats_top_sources >/dev/null 2>&1; then
    echo "  ✗ could not load nftban_stats_top_sources from $SRC"; exit 1
fi

# Drive the cache-hit path with controlled counts (override the real accessors).
declare -A _COUNTS=()
nftban_stats_unified_available() { return 0; }                 # cache "available"
nftban_stats_get_unified() { local k="$1"; local name="${k##*.}"; echo "${_COUNTS[$name]:-0}"; }

TODAY="$(date +%Y-%m-%d)"
gen() { nftban_stats_top_sources 10 "1970-01-01" "$TODAY" 2>/dev/null; }

assert_valid_json() { # desc, json
    if printf '%s' "$2" | jq -e . >/dev/null 2>&1; then ok "$1"; else no "$1" "$2"; fi
}
assert_argjson_ok() { # desc, json  — the exact stats --json usage
    if jq -n --argjson top_filters "$2" '$top_filters | length' >/dev/null 2>&1; then ok "$1"; else no "$1" "$2"; fi
}

echo "=== F2: top_sources cache-hit JSON validity ==="

# Scenario 1: the original failing case — two non-zero, four zero
_COUNTS=([login]=7792 [manual]=17 [portscan]=0 [ddos]=0 [feeds]=0 [suricata]=0)
J="$(gen)"
assert_valid_json  "mixed-with-zeros: valid JSON" "$J"
assert_argjson_ok  "mixed-with-zeros: accepted by jq --argjson (no --argjson failure)" "$J"
if printf '%s' "$J" | grep -q ',]'; then no "mixed-with-zeros: no trailing comma" "$J"; else ok "mixed-with-zeros: no trailing comma"; fi
if [[ "$(printf '%s' "$J" | jq 'length' 2>/dev/null)" == "2" ]]; then ok "mixed-with-zeros: exactly 2 non-zero objects"; else no "mixed-with-zeros: 2 objects" "$J"; fi

# Scenario 2: all zero → []
_COUNTS=([login]=0 [manual]=0 [portscan]=0 [ddos]=0 [feeds]=0 [suricata]=0)
J="$(gen)"
assert_valid_json "all-zero: valid JSON" "$J"
if [[ "$(printf '%s' "$J" | jq -c '.' 2>/dev/null)" == "[]" ]]; then ok "all-zero: emits []"; else no "all-zero: []" "$J"; fi

# Scenario 3: all non-zero → all six objects, valid
_COUNTS=([login]=6 [manual]=5 [portscan]=4 [ddos]=3 [feeds]=2 [suricata]=1)
J="$(gen)"
assert_valid_json "all-nonzero: valid JSON" "$J"
assert_argjson_ok "all-nonzero: accepted by jq --argjson" "$J"
if [[ "$(printf '%s' "$J" | jq 'length' 2>/dev/null)" == "6" ]]; then ok "all-nonzero: 6 objects"; else no "all-nonzero: 6 objects" "$J"; fi

# Scenario 4: single non-zero → one object, no stray comma
_COUNTS=([login]=9 [manual]=0 [portscan]=0 [ddos]=0 [feeds]=0 [suricata]=0)
J="$(gen)"
assert_valid_json "single-nonzero: valid JSON" "$J"
if [[ "$(printf '%s' "$J" | jq -c '.' 2>/dev/null)" == '[{"name":"login","count":9}]' ]]; then ok "single-nonzero: exact shape"; else no "single-nonzero: shape" "$J"; fi

echo ""
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
