#!/usr/bin/env bash
# =============================================================================
# NFTBan - L2e replace_set legacy-IPC reachability guard
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="l2e_replace_set_reachability_guard_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-06"
# meta:description="Locks the L2e reachability invariants proven in the scope: the non-atomic opqueue replace_set path stays fenced. Asserts (1) OpReplaceSet is constructed only by EnqueueReplace, (2) EnqueueReplace is called only by handleReplaceSetRequest, (3) EnqueueReplaceFromFile has no caller (dead), (4) no shipped feeds/geoban/trust/detector shell module calls nft_ipc_replace_set, (5) feeds/geoban/trust use nft_ipc_sync_or_apply (FULL sync), and (6) the daemon reject-guard denies replace_set for blacklist_ipv4/blacklist_ipv6. Hermetic: greps shipped source; no host/nft/daemon."
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
# NOTE: the counting pipelines below use `|| true` because a `grep -v` that filters out
# every line legitimately exits non-zero, which pipefail would otherwise treat as a
# failure. The captured stdout (the count) is still correct; the test's real exit status
# is the final FAIL==0 check.

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../../../.." && pwd)"
SYNC_GO="$REPO/cmd/nftband/daemon_handlers_sync.go"
FEEDS="$REPO/cli/lib/nftban/core/nftban_feeds.sh"
GEOBAN="$REPO/cli/lib/nftban/core/nftban_geoban.sh"
TRUST="$REPO/cli/lib/nftban/core/nftban_trust.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad() { FAIL=$((FAIL+1)); echo "  [FAIL] $1${2:+ — $2}"; }

echo "=== L2e replace_set reachability guard ==="

# 1) Only EnqueueReplace constructs OpReplaceSet (single producer).
n=$(grep -rn 'Type:[[:space:]]*OpReplaceSet' "$REPO/cmd" "$REPO/internal" 2>/dev/null | grep -v '_test.go' | wc -l || true)
[[ "$n" -eq 1 ]] && ok "OpReplaceSet constructed in exactly 1 place (EnqueueReplace)" \
                 || bad "OpReplaceSet constructed in $n places (want 1)"

# 2) EnqueueReplace is called only by handleReplaceSetRequest.
callers=$(grep -rn '\.EnqueueReplace(' "$REPO/cmd" "$REPO/internal" 2>/dev/null | grep -v '_test.go' | grep -v 'func ' | wc -l || true)
[[ "$callers" -eq 1 ]] && ok "EnqueueReplace has exactly 1 caller (handleReplaceSetRequest)" \
                       || bad "EnqueueReplace has $callers callers (want 1)"
grep -q 'EnqueueReplace(setName, result.Elements, source)' "$SYNC_GO" \
  && ok "the one EnqueueReplace caller is handleReplaceSetRequest" \
  || bad "EnqueueReplace caller is not handleReplaceSetRequest"

# 3) EnqueueReplaceFromFile is dead (no caller).
efc=$(grep -rn 'EnqueueReplaceFromFile(' "$REPO/cmd" "$REPO/internal" "$REPO/cli" 2>/dev/null | grep -v 'func (q' | grep -v '_test.go' | wc -l || true)
[[ "$efc" -eq 0 ]] && ok "EnqueueReplaceFromFile has no caller (dead)" \
                   || bad "EnqueueReplaceFromFile has $efc caller(s) (expected dead)"

# 4) No shipped feeds/geoban/trust shell module calls the legacy nft_ipc_replace_set.
for f in "$FEEDS" "$GEOBAN" "$TRUST"; do
  base=$(basename "$f")
  if grep -q 'nft_ipc_replace_set' "$f" 2>/dev/null; then bad "$base calls nft_ipc_replace_set"; else ok "$base does not call nft_ipc_replace_set"; fi
done

# 5) feeds/geoban/trust use the FULL-sync apply helper (atomic path).
for f in "$FEEDS" "$GEOBAN" "$TRUST"; do
  base=$(basename "$f")
  if grep -q 'nft_ipc_sync_or_apply' "$f" 2>/dev/null; then ok "$base uses nft_ipc_sync_or_apply (FULL sync)"; else bad "$base does not use nft_ipc_sync_or_apply"; fi
done

# 6) Daemon reject-guard denies replace_set for the atomic-owned interval sets.
grep -q 'intervalSetsOwnedByAtomicSync' "$SYNC_GO" \
  && ok "reject-guard set intervalSetsOwnedByAtomicSync present" \
  || bad "reject-guard set missing"
grep -Pzoq '"blacklist_ipv4":\s*true,\s*\n?\s*"blacklist_ipv6":\s*true' "$SYNC_GO" 2>/dev/null \
  && ok "guard set contains blacklist_ipv4 + blacklist_ipv6" \
  || { grep -q '"blacklist_ipv4": true' "$SYNC_GO" && grep -q '"blacklist_ipv6": true' "$SYNC_GO" && ok "guard set contains blacklist_ipv4 + blacklist_ipv6" || bad "guard set missing interval sets"; }
grep -q 'blocked for interval/protection set' "$SYNC_GO" \
  && ok "reject returns explicit blocked error" \
  || bad "reject error message missing"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
