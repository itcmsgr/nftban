#!/usr/bin/env bash
# =============================================================================
# NFTBan - convergence transaction serialization (v1.229.11 lane 7)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="convergence_serialization_v1229_11_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-25"
# meta:description="Enforces ONE LOCK, ONE TRANSACTION OWNER, ONE TARGET GENERATION, ONE COMMIT AUTHORITY. Proves two concurrent transaction owners cannot both open (the second REFUSES rather than converging unserialized), that the refusal mutates nothing, that a re-entrant owner does NOT deadlock against its own held lock, that read-only paths take no lock and are never blocked by a converging writer, that a killed owner's lock is released by the kernel, and that the target generation is chosen INSIDE the lock so two writers cannot both target N+1. Negative control: with the marker forced, the guard must be observably bypassable -- a serialization test that cannot demonstrate the unserialized state proves nothing."
# meta:ta.id="convergence_serialization_v1229_11_test"
# meta:ta.owner="firewall"
# meta:ta.module="mode-authority"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.blocking="true"
# meta:ta.timeout="120"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:inventory.files="cli/lib/nftban/lib/module_authority.sh"
# meta:inventory.binaries="bash,flock"
# meta:inventory.env_vars="NFTBAN_RUN_DIR,NFTBAN_TIMEOUT_NFT_LOCK,NFTBAN_NFTLOCK_HELD"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none (run dir redirected to a temp dir)"
# =============================================================================

set -Eeuo pipefail

ROOT="${NFTBAN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
AUTH="$ROOT/cli/lib/nftban/lib/module_authority.sh"
FAILURES=0
fail() { FAILURES=$((FAILURES + 1)); echo "  FAIL  $1"; }
ok()   { echo "  ok    $1"; }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected [$3], got [$2])"; fi; }

echo "=== convergence transaction serialization (v1.229.11 lane 7) ==="
[[ -f "$AUTH" ]] || { echo "::error::SUBJECT_NOT_FOUND: $AUTH"; exit 1; }
command -v flock >/dev/null || { echo "::error::flock(1) absent — this suite cannot prove serialization"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/conf.d/ddos" "$TMP/conf.d/portscan" "$TMP/run"
printf 'DDOS_ENABLED="true"\nDDOS_MODE="auto"\n'         > "$TMP/conf.d/ddos/main.conf"
printf 'PORTSCAN_ENABLED="true"\nPORTSCAN_MODE="auto"\n' > "$TMP/conf.d/portscan/main.conf"

# A transaction owner, run as an isolated process with a controllable dwell.
# `hold_s` keeps the transaction OPEN so a competitor genuinely overlaps it.
owner() {  # owner <hold_seconds> <lock_wait> [extra-env]
    local hold="$1" wait="$2"; shift 2
    env NFTBAN_CONFIG_DIR="$TMP" NFTBAN_PLAN_RECORD_DIR="$TMP/run" \
        NFTBAN_PLAN_GENERATION_FILE="$TMP/run/convergence-generation" \
        NFTBAN_RUN_DIR="$TMP/run" NFTBAN_TIMEOUT_NFT_LOCK="$wait" "$@" \
    bash -c '
        source "'"$AUTH"'"
        if ! nftban_plan_txn_begin ddos portscan 2>/dev/null; then echo "REFUSED"; exit 9; fi
        echo "OPENED target=${NFTBAN_PLAN_TARGET_GENERATION}"
        sleep '"$hold"'
        nftban_plan_txn_abort
        echo "CLOSED"
    ' 2>&1
}

printf '0\n' > "$TMP/run/convergence-generation"

# -----------------------------------------------------------------------------
# T1 — TWO CONCURRENT OWNERS: the second REFUSES, it does not converge anyway.
# -----------------------------------------------------------------------------
owner 3 1 > "$TMP/a.out" &  APID=$!
sleep 0.7                                    # A is inside the lock, holding it
owner 0 1 > "$TMP/b.out" || true             # B must refuse within its 1s wait
wait $APID || true
eq "T1.1 first owner opened the transaction" \
   "$(grep -c OPENED "$TMP/a.out" || true)" "1"
eq "T1.2 concurrent second owner REFUSED" \
   "$(grep -c REFUSED "$TMP/b.out" || true)" "1"
eq "T1.3 the refused owner opened NOTHING" \
   "$(grep -c OPENED "$TMP/b.out" || true)" "0"

# -----------------------------------------------------------------------------
# T2 — A REFUSAL MUTATES NOTHING. Not a partial transaction: no transaction.
# -----------------------------------------------------------------------------
eq "T2.1 generation unchanged by the refusal" \
   "$(cat "$TMP/run/convergence-generation")" "0"
eq "T2.2 no staged artifacts survived the refusal" \
   "$(find "$TMP/run" -maxdepth 1 -name 'module-plan-*' | wc -l)" "0"

# -----------------------------------------------------------------------------
# T3 — SERIAL OWNERS SUCCEED. Serialization must not mean starvation.
# -----------------------------------------------------------------------------
owner 0 5 > "$TMP/c.out" || true
owner 0 5 > "$TMP/d.out" || true
eq "T3.1 sequential owner 1 opened" "$(grep -c OPENED "$TMP/c.out" || true)" "1"
eq "T3.2 sequential owner 2 opened" "$(grep -c OPENED "$TMP/d.out" || true)" "1"
eq "T3.3 each chose the SAME target — neither committed, so N never moved" \
   "$(grep -ho 'target=[0-9]*' "$TMP/c.out" "$TMP/d.out" | sort -u | wc -l)" "1"

# -----------------------------------------------------------------------------
# T4 — RE-ENTRANCY: an owner that ALREADY holds the lock must not deadlock.
# This is the recorded dual-lock failure shape (health_checks_services.sh:632).
# -----------------------------------------------------------------------------
t0=$(date +%s)
out="$(NFTBAN_CONFIG_DIR="$TMP" NFTBAN_PLAN_RECORD_DIR="$TMP/run" \
  NFTBAN_PLAN_GENERATION_FILE="$TMP/run/convergence-generation" \
  NFTBAN_RUN_DIR="$TMP/run" NFTBAN_TIMEOUT_NFT_LOCK=10 bash -c '
    source "'"$AUTH"'"
    # Simulate _firewall_rebuild_serialized: take the canonical lock, declare it.
    exec 8>>"'"$TMP"'/run/nft_operations.lock"
    flock -w 5 8 || { echo "OUTER_LOCK_FAILED"; exit 1; }
    export NFTBAN_NFTLOCK_HELD=1
    nftban_plan_txn_begin ddos portscan >/dev/null 2>&1 && echo "INNER_OPENED" || echo "INNER_REFUSED"
    nftban_plan_txn_abort
    exec 8>&-; unset NFTBAN_NFTLOCK_HELD
  ' 2>&1)"; t1=$(date +%s)
eq "T4.1 a re-entrant owner opens instead of deadlocking" "$(grep -c INNER_OPENED <<<"$out")" "1"
if (( t1 - t0 < 5 )); then ok "T4.2 it returned immediately ($((t1-t0))s) — it never waited on itself"
else fail "T4.2 took $((t1-t0))s — it blocked against its own held lock"; fi

# -----------------------------------------------------------------------------
# T5 — READ-ONLY TAKES NO LOCK and is not blocked by a converging writer.
#      A status query must never block, or be blocked.
# -----------------------------------------------------------------------------
printf '4\n' > "$TMP/run/convergence-generation"
printf 'NFTBAN_PLAN_MODULE=ddos\nNFTBAN_PLAN_CONFIGURED_MODE=auto\nNFTBAN_PLAN_EFFECTIVE_MODE=classic\nNFTBAN_PLAN_BOUND_GENERATION=4\n' \
    > "$TMP/run/module-plan-ddos.env.4"
owner 3 1 > "$TMP/e.out" & EPID=$!
sleep 0.7                                    # a writer is mid-transaction
t0=$(date +%s)
reff="$(NFTBAN_CONFIG_DIR="$TMP" NFTBAN_PLAN_RECORD_DIR="$TMP/run" \
  NFTBAN_PLAN_GENERATION_FILE="$TMP/run/convergence-generation" NFTBAN_RUN_DIR="$TMP/run" \
  bash -c 'source "'"$AUTH"'"; nftban_module_report_modes ddos | sed -n "s/^NFTBAN_REPORT_EFFECTIVE_MODE=//p"' 2>&1)"
t1=$(date +%s)
wait $EPID || true
eq "T5.1 the reader resolved while a writer held the lock" "$reff" "classic"
if (( t1 - t0 <= 1 )); then ok "T5.2 the reader did not block ($((t1-t0))s)"
else fail "T5.2 reader took $((t1-t0))s — it is participating in the writer's lock"; fi
eq "T5.3 the reader takes no lock at all" \
   "$(grep -c 'flock' <(sed -n '/^nftban_module_report_modes()/,/^}/p' "$AUTH") || true)" "0"

# -----------------------------------------------------------------------------
# T6 — A KILLED OWNER'S LOCK IS RELEASED BY THE KERNEL, not by cleanup code.
#      This is why the design does not depend on a rollback path running.
# -----------------------------------------------------------------------------
rm -f "$TMP/run"/module-plan-* ; printf '4\n' > "$TMP/run/convergence-generation"
NFTBAN_CONFIG_DIR="$TMP" NFTBAN_PLAN_RECORD_DIR="$TMP/run" \
  NFTBAN_PLAN_GENERATION_FILE="$TMP/run/convergence-generation" \
  NFTBAN_RUN_DIR="$TMP/run" NFTBAN_TIMEOUT_NFT_LOCK=1 bash -c '
    source "'"$AUTH"'"; nftban_plan_txn_begin ddos portscan >/dev/null 2>&1; sleep 30' &
KPID=$!
sleep 0.7; kill -9 $KPID 2>/dev/null || true; wait $KPID 2>/dev/null || true
owner 0 3 > "$TMP/f.out" || true
eq "T6.1 a later owner acquires after the holder was SIGKILLed" \
   "$(grep -c OPENED "$TMP/f.out" || true)" "1"
eq "T6.2 the killed owner did not advance the generation" \
   "$(cat "$TMP/run/convergence-generation")" "4"

# -----------------------------------------------------------------------------
# T7 — NEGATIVE CONTROL. Force the marker and the guard MUST be bypassable:
#      two owners then open concurrently. A serialization suite that cannot
#      demonstrate the unserialized state is not measuring serialization.
# -----------------------------------------------------------------------------
rm -f "$TMP/run"/module-plan-*
owner 3 1 > "$TMP/g.out" & GPID=$!
sleep 0.7
owner 0 1 NFTBAN_NFTLOCK_HELD=1 > "$TMP/h.out" || true
wait $GPID || true
eq "T7.1 with the marker forced, a SECOND owner opens concurrently" \
   "$(grep -c OPENED "$TMP/h.out" || true)" "1"
ok "T7.2 the guard is therefore load-bearing, not incidental"

echo
if (( FAILURES == 0 )); then echo "PASS — convergence serialization"; exit 0; fi
echo "FAIL — $FAILURES assertion(s)"; exit 1
