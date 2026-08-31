#!/usr/bin/env bash
# =============================================================================
# NFTBan - a coalesced sync request may not report the work as done
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="ipc-sync-coalesce-truth-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="D9a. nft_ipc_sync debounces rapid full-sync requests using a HOST-WIDE marker (/run/nftban/.sync_last, 3s), and the suppressed branch returned 0 — a status every caller reads as 'the sync happened'. No IPC is sent, so the daemon never sees the request and performs zero replaces. The docstring even codified it: 'Returns: 0 on success (or coalesced)'. MEASURED on lab4 2026-08-31 through the real recovery path, counting the daemon's own replace lines: back-to-back gave SYNCED(2 replaces) FAILED(0) SYNCED(2) FAILED(0) while the same calls spaced 15s gave SYNCED(2) three times. Because recovery writes its durable source and THEN syncs, 'a sync ran 2s ago' does not imply the caller's state is committed. Propagation alone cannot fix this — the work never happened — so nft_ipc_sync_or_apply, whose contract is to apply, re-issues once with force=1. The debounce still protects direct nft_ipc_sync callers that do not need immediate proof. Counts real IPC requests via a stub transport, and reproduces the defect against the origin/main library so no row passes vacuously."
# meta:ta.id="ipc_sync_coalesce_truth_test"
# meta:ta.owner="firewall"
# meta:ta.module="ipc-sync-contract"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.blocking="true"
# meta:ta.timeout="60"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:inventory.files="cli/lib/nftban/lib/nft_ipc.sh"
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
IPC_LIB="$REPO_ROOT/cli/lib/nftban/lib/nft_ipc.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }

SBX="$(mktemp -d)"; trap 'rm -rf "$SBX"' EXIT
export NFTBAN_RUN_DIR="$SBX/run"; mkdir -p "$NFTBAN_RUN_DIR"
STUB_LOG="$SBX/ipc.log"; : > "$STUB_LOG"
git -C "$REPO_ROOT" show origin/main:cli/lib/nftban/lib/nft_ipc.sh > "$SBX/old_ipc.sh" 2>/dev/null || {
    echo "  [FAIL] cannot read origin/main nft_ipc.sh — the control would be vacuous"; exit 1; }

# Each arm runs in a SUBSHELL with its own library, so old and new never coexist.
# The stub transport RECORDS every request, so "was IPC actually sent" is counted,
# never inferred.
arm() { # $1=lib  $2=body
( set +u
  # shellcheck source=/dev/null
  source "$1" >/dev/null 2>&1
  nft_ipc_request() { echo "REQUEST method=$1" >> "$STUB_LOG"; echo '{"success":true}'; return 0; }
  nft_ipc_apply_ruleset() { echo "APPLY" >> "$STUB_LOG"; return 0; }
  export NFTBAN_SYNC_RETRIES=2 NFTBAN_SYNC_RETRY_DELAY=0 NFTBAN_SYNC_DEBOUNCE_SECONDS=30
  set +e
  eval "$2" ) }
reset() { : > "$STUB_LOG"; rm -f "$NFTBAN_RUN_DIR/.sync_last" "$NFTBAN_RUN_DIR/.sync_last.pending"; }
sent()  { grep -c 'REQUEST method=sync' "$STUB_LOG" 2>/dev/null || echo 0; }

echo "=== NEGATIVE CONTROL: origin/main suppresses request B and calls it success ==="
reset
r=$(arm "$SBX/old_ipc.sh" 'nft_ipc_sync >/dev/null 2>&1; echo "A=$?"; nft_ipc_sync >/dev/null 2>&1; echo "B=$?"')
n=$(sent)
b_rc=$(sed -n 's/^B=//p' <<<"$r")
[[ "$n" -eq 1 ]] && ok "origin/main: only 1 IPC request sent for 2 calls (B suppressed, REPLACE_COUNT=0)" \
                 || bad "origin/main sent $n requests; expected 1"
[[ "$b_rc" == "0" ]] && ok "origin/main: suppressed request B returned rc=0 — THE MOTIVATING DEFECT" \
                     || bad "origin/main B returned rc=$b_rc; expected the false success 0"

echo "=== FIXED: bare nft_ipc_sync still coalesces, but says so ==="
reset
r=$(arm "$IPC_LIB" 'nft_ipc_sync >/dev/null 2>&1; echo "A=$?"; nft_ipc_sync >/dev/null 2>&1; echo "B=$?"')
n=$(sent); b_rc=$(sed -n 's/^B=//p' <<<"$r")
[[ "$n" -eq 1 ]] && ok "debounce PRESERVED for direct callers: still 1 IPC request for 2 calls" \
                 || bad "debounce lost: $n requests sent"
[[ "$b_rc" != "0" ]] && ok "coalesced request returns a DISTINCT non-success status (rc=$b_rc)" \
                     || bad "coalesced request still returns 0"

echo "=== FIXED: the apply helper performs the work its caller needs ==="
for pair in "feeds geoban" "geoban feeds" "feeds feeds" "trust geoban"; do
    set -- $pair
    reset
    arm "$IPC_LIB" "nft_ipc_sync_or_apply $1 '' >/dev/null 2>&1; echo \"rc1=\$?\"; nft_ipc_sync_or_apply $2 '' >/dev/null 2>&1; echo \"rc2=\$?\"" >"$SBX/o"
    n=$(sent); r1=$(sed -n 's/^rc1=//p' "$SBX/o"); r2=$(sed -n 's/^rc2=//p' "$SBX/o")
    if [[ "$n" -eq 2 && "$r1" == "0" && "$r2" == "0" ]]; then
        ok "$1 -> $2 back-to-back: IPC_SENT=2 (forced re-issue), both rc=0"
    else
        bad "$1 -> $2: IPC_SENT=$n rc1=$r1 rc2=$r2 (want 2/0/0)"
    fi
done

echo "=== FIXED: A-B-A and a 4-call burst all reach the daemon ==="
reset
arm "$IPC_LIB" 'for m in feeds geoban feeds; do nft_ipc_sync_or_apply $m "" >/dev/null 2>&1; done' >/dev/null
n=$(sent); [[ "$n" -eq 3 ]] && ok "A-B-A: IPC_SENT=3 (no request silently dropped)" || bad "A-B-A IPC_SENT=$n, want 3"
reset
arm "$IPC_LIB" 'for i in 1 2 3 4; do nft_ipc_sync_or_apply geoban "" >/dev/null 2>&1; done' >/dev/null
n=$(sent); [[ "$n" -eq 4 ]] && ok "4-call rapid burst: IPC_SENT=4" || bad "burst IPC_SENT=$n, want 4"

echo "=== the SAME burst on origin/main is where the work disappeared ==="
reset
arm "$SBX/old_ipc.sh" 'for i in 1 2 3 4; do nft_ipc_sync_or_apply geoban "" >/dev/null 2>&1; done' >/dev/null
n=$(sent)
[[ "$n" -eq 1 ]] && ok "origin/main burst: only 1 of 4 requests reached the daemon (3 lost, all reported success)" \
                 || bad "origin/main burst sent $n; expected 1"

echo "=== spaced control: no forced re-issue when the window has passed ==="
reset
arm "$IPC_LIB" 'nft_ipc_sync_or_apply feeds "" >/dev/null 2>&1' >/dev/null
rm -f "$NFTBAN_RUN_DIR/.sync_last"       # simulate the window elapsing
arm "$IPC_LIB" 'nft_ipc_sync_or_apply geoban "" >/dev/null 2>&1' >/dev/null
n=$(sent); [[ "$n" -eq 2 ]] && ok "spaced calls: 2 requests, no coalescing to undo" || bad "spaced IPC_SENT=$n, want 2"

echo
echo "=== ipc_sync_coalesce_truth: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
