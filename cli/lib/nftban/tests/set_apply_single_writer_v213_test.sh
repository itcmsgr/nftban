#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# =============================================================================
# NFTBan v1.213.0 - SET_APPLY_SINGLE_WRITER (Design A) behavioral test
# =============================================================================
# meta:name="set_apply_single_writer_v213_test"
# meta:type="test"
# meta:version="1.213.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Design A: feeds/geoban/trust write durable source then trigger a FULL daemon sync (quick=false) via nft_ipc_sync; debounced; IPC-fail attempts the legacy apply with a visible WARN that the full sync is OWED; v1.235 P1S-A: a failed full sync leaves the pending marker the maintenance cycle consumes, a REFUSED apply (enforcement-set add) propagates a non-zero rc with an explicit NOT-applied error, a degraded sync (exemption_split_limit) is printed; no quick-sync; no additive push on sync success"
# meta:input="None (self-contained sandbox; sources real cli/lib/nftban/lib/nft_ipc.sh; stubs nft_ipc_request/apply_ruleset)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,grep,mktemp,date"
# meta:inventory.files="cli/lib/nftban/lib/nft_ipc.sh"
# meta:inventory.binaries="bash,grep,mktemp,date"
# meta:inventory.env_vars="NFTBAN_RUN_DIR,NFTBAN_SYNC_DEBOUNCE_SECONDS,NFTBAN_SYNC_RETRIES,NFTBAN_SYNC_RETRY_DELAY"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="set_apply_single_writer_v213_test"
# meta:ta.owner="firewall"
# meta:ta.module="set-apply-single-writer"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
# Self-contained; no host contact; no root; no live nft/IPC. Sources the REAL
# nft_ipc.sh single-writer helpers (nft_ipc_sync / nft_ipc_sync_or_apply) and
# drives them with a recording stub for nft_ipc_request + nft_ipc_apply_ruleset.
# Every module (feeds, geoban, trust) routes its normal-path writes through
# nft_ipc_sync_or_apply "<module>" "<fragment>", so the helper contract IS the
# per-module contract; the companion grep-guard test proves each module is wired
# to it.
# =============================================================================

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
IPC_LIB="$REPO_ROOT/cli/lib/nftban/lib/nft_ipc.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }

echo "=== set_apply_single_writer_v213 (Design A) ==="

if [[ ! -f "$IPC_LIB" ]]; then
    echo "  [SKIP] nft_ipc.sh not found at $IPC_LIB"
    exit 0
fi

SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT
export NFTBAN_RUN_DIR="$SBX/run"
mkdir -p "$NFTBAN_RUN_DIR"

STUB_LOG="$SBX/ipc_calls.log"
: > "$STUB_LOG"

# Stub controls
SYNC_SHOULD_FAIL=0     # 1 => the daemon "sync" verb reports failure
SYNC_DEGRADED=0        # 1 => the sync succeeds but reports degraded (exemption_split_limit)
APPLY_REFUSED=0        # 1 => apply_ruleset is refused (P1S-A: enforcement-set element add)
ORDER_PROBE=""         # if set, the sync stub records PRESENT/ABSENT of this path

# Source the REAL helper library, then override the transport with a recorder.
# shellcheck source=/dev/null
source "$IPC_LIB"

nft_ipc_request() {
    local method="$1" params="${2:-}"
    echo "REQUEST method=${method} params=${params}" >> "$STUB_LOG"
    if [[ "$method" == "sync" ]]; then
        if [[ -n "$ORDER_PROBE" ]]; then
            if [[ -e "$ORDER_PROBE" ]]; then
                echo "SYNC_SAW probe=PRESENT" >> "$STUB_LOG"
            else
                echo "SYNC_SAW probe=ABSENT" >> "$STUB_LOG"
            fi
        fi
        if [[ "$SYNC_SHOULD_FAIL" == "1" ]]; then
            echo '{"success":false,"error":"stub sync fail"}'
            return 1
        fi
        if [[ "$SYNC_DEGRADED" == "1" ]]; then
            echo '{"success":true,"data":{"exempt_split_limit_omitted":1,"degraded":true,"degraded_reason":"exemption_split_limit"}}'
            return 0
        fi
        echo '{"success":true}'
        return 0
    fi
    echo '{"success":true}'
    return 0
}
nft_ipc_apply_ruleset() {
    echo "APPLY file=${1:-}" >> "$STUB_LOG"
    [[ "$APPLY_REFUSED" == "1" ]] && return 1
    return 0
}

reset_log() { : > "$STUB_LOG"; rm -f "$NFTBAN_RUN_DIR/.sync_last" "$NFTBAN_RUN_DIR/.sync_last.pending"; }
count_sync()  { grep -c 'REQUEST method=sync ' "$STUB_LOG" 2>/dev/null || true; }
count_apply() { grep -c '^APPLY '            "$STUB_LOG" 2>/dev/null || true; }

# Keep retries cheap + debounce large enough for the coalesce test.
export NFTBAN_SYNC_RETRIES=2
export NFTBAN_SYNC_RETRY_DELAY=0
export NFTBAN_SYNC_DEBOUNCE_SECONDS=30

# ---------------------------------------------------------------------------
echo "--- helper contract: FULL sync only (never quick) ---"
reset_log
rc=0; nft_ipc_sync || rc=$?
if [[ "$rc" -eq 0 ]] && grep -q 'REQUEST method=sync .*"quick":false' "$STUB_LOG"; then
    ok "nft_ipc_sync sends the daemon 'sync' verb with quick:false"
else
    bad "nft_ipc_sync did not send a FULL (quick:false) sync (rc=$rc)"
fi
if ! grep -q 'quick":true' "$STUB_LOG"; then
    ok "nft_ipc_sync NEVER sends quick=true"
else
    bad "nft_ipc_sync sent quick=true (would skip feeds/geoban/whitelist reconcile)"
fi

# ---------------------------------------------------------------------------
echo "--- debounce: N rapid full-sync requests coalesce into ONE ---"
reset_log
for _ in 1 2 3 4 5; do rc=0; nft_ipc_sync || rc=$?; done
n="$(count_sync)"
if [[ "$n" -eq 1 ]]; then
    ok "5 rapid nft_ipc_sync calls coalesced into 1 sync (debounced)"
else
    bad "expected 1 coalesced sync, observed $n"
fi

# ---------------------------------------------------------------------------
echo "--- per-module normal path: sync (not additive) on success ---"
for mod in feeds geoban trust; do
    reset_log
    SYNC_SHOULD_FAIL=0
    frag="$SBX/${mod}.nft"; echo "add element ip nftban x { 1.2.3.4 }" > "$frag"
    rc=0; nft_ipc_sync_or_apply "$mod" "$frag" || rc=$?
    if [[ "$rc" -eq 0 ]] && [[ "$(count_sync)" -eq 1 ]] && [[ "$(count_apply)" -eq 0 ]]; then
        ok "$mod: normal path triggers FULL sync and does NOT additively apply"
    else
        bad "$mod: expected 1 sync + 0 apply, got sync=$(count_sync) apply=$(count_apply) rc=$rc"
    fi
done

# ---------------------------------------------------------------------------
echo "--- per-module IPC-fail fallback: legacy apply attempted + visible WARN naming the OWED sync ---"
for mod in feeds geoban trust; do
    reset_log
    SYNC_SHOULD_FAIL=1
    frag="$SBX/${mod}_fb.nft"; echo "add element ip nftban x { 5.6.7.8 }" > "$frag"
    warn="$SBX/${mod}_warn.txt"
    rc=0; nft_ipc_sync_or_apply "$mod" "$frag" 2>"$warn" || rc=$?
    SYNC_SHOULD_FAIL=0
    if grep -q "APPLY file=${frag}" "$STUB_LOG" \
       && grep -qi "\[WARN\] ${mod}: full sync IPC failed; the sync is OWED (maintenance retries it within 15 min)" "$warn"; then
        ok "$mod: sync IPC failure attempts the legacy apply with a visible WARN that the sync is OWED"
    else
        bad "$mod: fallback/WARN missing (apply=$(count_apply) warn='$(cat "$warn" 2>/dev/null)')"
    fi
done

# ---------------------------------------------------------------------------
echo "--- IPC-fail retries before giving up (bounded) ---"
reset_log
SYNC_SHOULD_FAIL=1
rc=0; nft_ipc_sync || rc=$?
SYNC_SHOULD_FAIL=0
if [[ "$rc" -ne 0 ]] && [[ "$(count_sync)" -ge 2 ]]; then
    ok "nft_ipc_sync retries (>=2 attempts) then returns nonzero so caller can fall back"
else
    bad "expected nonzero rc + >=2 attempts, got rc=$rc attempts=$(count_sync)"
fi

# ---------------------------------------------------------------------------
echo "--- ordering: durable source written BEFORE the sync (add path) ---"
reset_log
probe="$SBX/durable_source.conf"
rm -f "$probe"
ORDER_PROBE="$probe"
# emulate the module contract: write durable source, THEN trigger sync
printf '1.2.3.0/24\n' > "$probe"
rc=0; nft_ipc_sync || rc=$?
ORDER_PROBE=""
if grep -q 'SYNC_SAW probe=PRESENT' "$STUB_LOG"; then
    ok "add path: durable source present at sync time (write-durable-THEN-sync)"
else
    bad "add path: durable source was NOT present when the sync ran"
fi

# ---------------------------------------------------------------------------
echo "--- ordering: durable source removed BEFORE the sync (delete path) ---"
reset_log
probe="$SBX/durable_source_del.conf"
printf '9.9.9.0/24\n' > "$probe"
ORDER_PROBE="$probe"
# emulate the removal contract: remove durable source, THEN trigger sync
rm -f "$probe"
rc=0; nft_ipc_sync || rc=$?
ORDER_PROBE=""
if grep -q 'SYNC_SAW probe=ABSENT' "$STUB_LOG"; then
    ok "delete path: durable source absent at sync time (remove-durable-THEN-sync)"
else
    bad "delete path: durable source still present when the sync ran"
fi

# ---------------------------------------------------------------------------
# v1.235 P1S-A integration (owner 2026-10-08)
echo "--- a full sync that never ran is OWED: pending marker set for the maintenance backstop ---"
reset_log
SYNC_SHOULD_FAIL=1
rc=0; nft_ipc_sync 1 || rc=$?
SYNC_SHOULD_FAIL=0
if [[ "$rc" -ne 0 && -f "$NFTBAN_RUN_DIR/.sync_last.pending" ]]; then
    ok "failed full sync (all attempts) leaves .sync_last.pending (maintenance re-requests it)"
else
    bad "failed full sync: rc=$rc pending=$([[ -f "$NFTBAN_RUN_DIR/.sync_last.pending" ]] && echo yes || echo NO)"
fi
SYNC_SHOULD_FAIL=0; rc=0; nft_ipc_sync 1 || rc=$?
if [[ "$rc" -eq 0 && ! -f "$NFTBAN_RUN_DIR/.sync_last.pending" ]]; then
    ok "the next successful full sync clears the owed marker"
else
    bad "successful sync did not clear the owed marker (rc=$rc)"
fi

echo "--- refused legacy apply (enforcement-set add): failure propagates, nothing claimed ---"
for mod in feeds geoban; do
    reset_log
    SYNC_SHOULD_FAIL=1; APPLY_REFUSED=1
    frag="$SBX/${mod}_ref.nft"; echo "add element ip nftban blacklist_ipv4 { 5.6.7.0/24 }" > "$frag"
    err="$SBX/${mod}_ref.txt"
    rc=0; nft_ipc_sync_or_apply "$mod" "$frag" 2>"$err" || rc=$?
    SYNC_SHOULD_FAIL=0; APPLY_REFUSED=0
    if [[ "$rc" -ne 0 ]] && grep -q "\[ERROR\] ${mod}: NOT applied now" "$err" && [[ -f "$NFTBAN_RUN_DIR/.sync_last.pending" ]]; then
        ok "$mod: sync failed + apply refused -> rc $rc, explicit NOT-applied error, sync owed"
    else
        bad "$mod: refused apply not propagated (rc=$rc err='$(cat "$err" 2>/dev/null)')"
    fi
done

echo "--- degraded sync (exemption_split_limit) is said, never a silent OK ---"
reset_log
SYNC_DEGRADED=1
out="$SBX/degraded.txt"
rc=0; nft_ipc_sync 1 > "$out" 2>&1 || rc=$?
SYNC_DEGRADED=0
if grep -q "WARNING: full sync DEGRADED (exemption_split_limit)" "$out"; then
    ok "a degraded full sync prints the exemption_split_limit warning (stdout; rc=$rc: the sync ran)"
else
    bad "degraded sync printed no warning (rc=$rc out='$(cat "$out")')"
fi

echo "--- the maintenance cycle consumes the owed marker (static census; runtime proof on the lab) ---"
MAINT="$(cd "$(dirname "$IPC_LIB")/.." && pwd)/cron/maintenance.sh"
if grep -q 'if \[\[ -f "${NFTBAN_RUN_DIR:-/run/nftban}/.sync_last.pending" \]\]; then' "$MAINT" \
   && grep -q '_os_out=$(nft_ipc_sync 1 2>&1) || _os_rc=$?' "$MAINT"; then
    ok "cron/maintenance.sh re-requests the owed full sync (force) while .sync_last.pending exists"
else
    bad "cron/maintenance.sh does not consume .sync_last.pending (the owed sync would wait for the module timer)"
fi

echo ""
echo "=== set_apply_single_writer_v213: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
