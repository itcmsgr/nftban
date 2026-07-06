#!/usr/bin/env bash
# =============================================================================
# NFTBan - L1 EXPORTER-GOROUTINES-DUP regression guard (NEW-01 / MX-1 / FAB-01)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="exporter_no_duplicate_goroutines_emit_v217_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-06"
# meta:description="Regression lock for the L1 P0 observability fix: the shell unified exporter must emit nftban_runtime_goroutines EXACTLY ONCE (from the authoritative live-IPC path, using \$d_goroutines), never twice. Two emissions on a healthy daemon produced a duplicate .prom series that node_exporter/promtool reject, blanking all NFTBan metrics. Also asserts nftban_threads is still emitted (covers the thread-count use case) and the JSON stats-cache goroutines field is intact. Hermetic: greps the shipped exporter source; no host/nft/IPC/daemon."
# meta:input="None (self-contained)"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep"
# meta:inventory.files="cli/lib/nftban/exporters/nftban_unified_exporter_collect.sh"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
SRC="$REPO_ROOT/cli/lib/nftban/exporters/nftban_unified_exporter_collect.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✓ $1"; }
no() { FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

[[ -f "$SRC" ]] || { echo "FATAL: exporter source not found: $SRC" >&2; exit 2; }

# 1) nftban_runtime_goroutines must be emitted by EXACTLY ONE metrics+= line.
emit_count="$(grep -cE 'metrics\+="nftban_runtime_goroutines ' "$SRC" || true)"
if [[ "$emit_count" == "1" ]]; then
    ok "nftban_runtime_goroutines emitted exactly once (was 2 → duplicate .prom series)"
else
    no "nftban_runtime_goroutines emitted $emit_count time(s), expected exactly 1" \
       "$(grep -nE 'metrics\+="nftban_runtime_goroutines ' "$SRC" | tr '\n' '|')"
fi

# 2) The surviving emission must be the authoritative live-IPC path ($d_goroutines),
#    not the removed proc/stats-file fallback path ($goroutines).
if grep -qE 'metrics\+="nftban_runtime_goroutines \$d_goroutines ' "$SRC"; then
    ok "surviving emission is the authoritative live-IPC path (\$d_goroutines)"
else
    no "surviving nftban_runtime_goroutines emission is not the live-IPC (\$d_goroutines) path"
fi
if grep -qE 'metrics\+="nftban_runtime_goroutines \$goroutines ' "$SRC"; then
    no "the removed proc/stats-file emission (\$goroutines) is back — regression"
else
    ok "removed proc/stats-file emission (\$goroutines) is absent"
fi

# 3) nftban_threads must still be emitted (covers the thread-count use case).
if grep -qE 'metrics\+="nftban_threads ' "$SRC"; then
    ok "nftban_threads still emitted (thread-count use case preserved)"
else
    no "nftban_threads emission missing — thread-count use case lost"
fi

# 4) The JSON stats-cache goroutines field must remain intact (the fallback var still feeds it).
if grep -qE '"goroutines":[[:space:]]*\$\{goroutines' "$SRC"; then
    ok "JSON stats-cache goroutines field intact (fallback var still consumed)"
else
    no "JSON stats-cache goroutines field missing — fallback removal broke the cache"
fi

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
