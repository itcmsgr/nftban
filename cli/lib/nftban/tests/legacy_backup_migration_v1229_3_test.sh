#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.229.3 0C — LEGACY rebuild_* BACKUP MIGRATION
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="legacy-backup-migration-v1229-3-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-16"
# meta:description="Proves the one-time legacy rebuild_* migration only ever removes pre-0B recovery directories it can positively classify, under the canonical nft_operations.lock, preserving the newest two legacy generations by deterministic name order. Keeps every new-format, malformed, unreadable and out-of-namespace object, deletes nothing on any observation failure, never backfills terminal state, and is structurally idempotent."
# meta:inventory.files="cli/lib/nftban/core/nftban_legacy_backup_migration.sh"
# meta:inventory.privileges="none"
# meta:ta.id="legacy_backup_migration_v1229_3_test"
# meta:ta.owner="firewall"
# meta:ta.module="firewall"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
#
#   CURRENT QUIESCENCE  !=  HISTORICAL COMPLETION PROOF
#   SAFE ONE-TIME LEGACY DISPOSAL  !=  HISTORICAL TRANSACTION COMPLETION PROVEN
#
# Holding the canonical lock proves only a present-tense fact. These arms
# therefore also assert that NO terminal state is ever written onto a legacy
# artifact -- disposal is permitted, rewriting history is not.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="$SCRIPT_DIR/../core/nftban_legacy_backup_migration.sh"
FAIL=0
pass(){ echo "  PASS  $1"; }
fail(){ echo "  FAIL  $1"; FAIL=1; }

echo "=== legacy backup migration (v1.229.3 0C) ==="
[[ -f "$SUBJECT" ]] || { echo "  SUBJECT_NOT_FOUND: $SUBJECT"; exit 1; }
command -v flock >/dev/null || { echo "  TEST_INVALID: flock(1) unavailable"; exit 1; }

# --- NO TERMINAL BACKFILL (source-level, before any behaviour) -----------------
if grep -qE 'tx_state=(TERMINAL|ACTIVE)|_rebuild_tx_state_write' "$SUBJECT"; then
    fail "migration writes transaction state — it must never backfill history"
else
    pass "migration never writes tx_state (no fabricated historical completion)"
fi
if grep -qE 'legacy_migration_done|migration\.version|migration_completed' "$SUBJECT"; then
    fail "a completion marker was invented; idempotency must be structural"
else
    pass "no invented completion marker (idempotency is structural)"
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export NFTBAN_DATA_DIR="$TMP/lib" NFTBAN_RUN_DIR="$TMP/run"
mkdir -p "$NFTBAN_DATA_DIR/backup" "$NFTBAN_RUN_DIR"
BK="$NFTBAN_DATA_DIR/backup"
# shellcheck source=/dev/null
source "$SUBJECT"

# valid pre-0B object: the producer's grammar (state in the A2 closed set + captured_at)
mk_legacy(){ mkdir -p "$BK/rebuild_$1"; printf 'state=VALID\nreason=\nnftban_table=yes\nlist_rc=0\njson_rc=0\ncaptured_at=2026-01-01T00:00:00Z\n' > "$BK/rebuild_$1/snapshot_state"; }
# readable, no tx_state, but does NOT satisfy the pre-0B grammar
mk_malformed(){ mkdir -p "$BK/rebuild_$1"; printf '%s\n' "$2" > "$BK/rebuild_$1/snapshot_state"; }
mk_new(){    mkdir -p "$BK/rebuild_$1"; printf 'state=VALID\ntx_state=%s\n' "$2" > "$BK/rebuild_$1/snapshot_state"; }
reset_bk(){  rm -rf "$BK"; mkdir -p "$BK"; }

# --- M5 · population <= floor -> zero deletion ---------------------------------
reset_bk; mk_legacy 20260101_000001; mk_legacy 20260101_000002
nftban_legacy_backup_migrate >/dev/null 2>&1
[[ $(find "$BK" -maxdepth 1 -name 'rebuild_*' | wc -l) -eq 2 ]] \
    && pass "M5 legacy population <= floor -> zero deletion" \
    || fail "M5 deleted below the floor"

# --- M4 · population > floor -> deterministic order, newest 2 preserved --------
reset_bk
for t in 20260101_000001 20260102_000002 20260103_000003 20260104_000004 20260105_000005; do mk_legacy "$t"; done
nftban_legacy_backup_migrate >/dev/null 2>&1
survivors=$(find "$BK" -maxdepth 1 -name 'rebuild_*' -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')
if [[ "$survivors" == "rebuild_20260104_000004 rebuild_20260105_000005 " ]]; then
    pass "M4 newest 2 preserved by NAME order; older legacy removed"
else
    fail "M4 wrong survivors: $survivors"
fi

# --- ORDERING AUTHORITY: mtime must not override name order -------------------
reset_bk
for t in 20260101_000001 20260102_000002 20260103_000003 20260104_000004; do mk_legacy "$t"; done
touch -d '2020-01-01' "$BK/rebuild_20260104_000004"      # newest by name, oldest by mtime
nftban_legacy_backup_migrate >/dev/null 2>&1
if [[ -d "$BK/rebuild_20260104_000004" ]]; then
    pass "ordering authority is the NAME — a touched mtime cannot evict a protected generation"
else
    fail "mtime perturbation evicted a name-newest generation (ordering authority wrong)"
fi

# --- M6 · new-format / malformed / unreadable are never subjects ---------------
reset_bk
mk_legacy 20260101_000001; mk_legacy 20260102_000002; mk_legacy 20260103_000003
mk_new 20260201_000001 ACTIVE
mk_new 20260202_000002 TERMINAL_SUCCESS
mk_new 20260203_000003 TERMINAL_FAILURE
mk_new 20260204_000004 GARBAGE_VALUE
mkdir -p "$BK/rebuild_20260205_000005"                       # no snapshot_state -> UNKNOWN
mkdir -p "$BK/rebuild_20260206_000006"; printf 'state=VALID\n' > "$BK/rebuild_20260206_000006/snapshot_state"
chmod 0000 "$BK/rebuild_20260206_000006/snapshot_state" 2>/dev/null   # unreadable -> UNKNOWN
nftban_legacy_backup_migrate >/dev/null 2>&1
chmod 0644 "$BK/rebuild_20260206_000006/snapshot_state" 2>/dev/null
m6=0
for keep in 20260201_000001 20260202_000002 20260203_000003 20260204_000004 20260205_000005 20260206_000006; do
    [[ -d "$BK/rebuild_$keep" ]] || { fail "M6 removed a non-legacy object: rebuild_$keep"; m6=1; }
done
[[ $m6 -eq 0 ]] && pass "M6 ACTIVE / TERMINAL_* / malformed / missing / unreadable all KEPT"

# --- MIXED-GENERATION ARM (catches 'sort everything, keep two') ---------------
# Only the eligible OLD legacy object may disappear; every other object survives.
if [[ ! -d "$BK/rebuild_20260101_000001" ]] \
   && [[ -d "$BK/rebuild_20260102_000002" && -d "$BK/rebuild_20260103_000003" ]]; then
    pass "MIXED: only eligible old legacy removed; newest-2 legacy + all new-format survive"
else
    fail "MIXED: candidate selection is not legacy-scoped (survivors: $(find "$BK" -maxdepth 1 -name 'rebuild_*' -printf '%f ' ))"
fi

# --- M3b · READABLE, no tx_state, MALFORMED grammar -> UNKNOWN / KEEP -----------
#     ABSENCE_OF_NEW_FIELD != PROOF_OF_VALID_LEGACY_OBJECT
# Each of these is readable and carries no tx_state, so a classifier that only
# checks for the NEW field would call them LEGACY and delete them.
reset_bk
mk_legacy 20260301_000001; mk_legacy 20260302_000002; mk_legacy 20260303_000003
mk_malformed 20260101_000001 "state=BOGUS_VALUE"                  # state outside the closed set
mk_malformed 20260101_000002 "reason=truncated"                   # no state= at all
mk_malformed 20260101_000003 "state=VALID"                        # state ok, captured_at missing
mk_malformed 20260101_000004 ""                                   # empty file
mk_malformed 20260101_000005 "random junk without any key"        # not key=value at all
m3b=0
for d in 20260101_000001 20260101_000002 20260101_000003 20260101_000004 20260101_000005; do
    cls=$(_lbm_classify "$BK/rebuild_$d")
    [[ "$cls" == "UNKNOWN" ]] || { fail "M3b readable-but-malformed classified $cls (must be UNKNOWN): rebuild_$d"; m3b=1; }
done
nftban_legacy_backup_migrate >/dev/null 2>&1
for d in 20260101_000001 20260101_000002 20260101_000003 20260101_000004 20260101_000005; do
    [[ -d "$BK/rebuild_$d" ]] || { fail "M3b deleted a malformed (UNKNOWN) object: rebuild_$d"; m3b=1; }
done
[[ $m3b -eq 0 ]] && pass "M3b readable + no tx_state + malformed grammar -> UNKNOWN / KEEP (5 shapes)"

# CLASSIFIER_INVERSION: weaken to "readable + no tx_state = LEGACY" -> M3b must fail
_lbm_classify_WEAK() {
    local _d="$1"; local _s="$_d/snapshot_state"
    [[ -r "$_s" ]] || { echo "UNKNOWN"; return 0; }
    grep -q '^tx_state=' "$_s" 2>/dev/null && { echo "NEW_FORMAT"; return 0; }
    echo "LEGACY"
}
weak_bad=0
for d in 20260101_000001 20260101_000002 20260101_000003 20260101_000004 20260101_000005; do
    [[ "$(_lbm_classify_WEAK "$BK/rebuild_$d")" == "LEGACY" ]] && weak_bad=$((weak_bad+1))
done
if (( weak_bad == 5 )); then
    pass "CLASSIFIER_INVERSION: the weakened rule calls all 5 malformed objects LEGACY (M3b is falsifiable)"
else
    fail "CLASSIFIER_INVERSION did not reproduce the defect ($weak_bad/5) — M3b may be vacuous"
fi

# --- M1 · exact namespace ------------------------------------------------------
reset_bk
for t in 20260101_000001 20260102_000002 20260103_000003; do mk_legacy "$t"; done
mkdir -p "$BK/rebuild_bogus" "$BK/backups" "$BK/rebuild_20260101"     # wrong shapes
: > "$BK/ruleset_20260101_000001.nft"
: > "$BK/whitelist_ipv4_20260101.txt"
mkdir -p "$BK/sub/rebuild_20260101_000009"                            # not directly beneath backup/
nftban_legacy_backup_migrate >/dev/null 2>&1
m1=0
for keep in "$BK/rebuild_bogus" "$BK/backups" "$BK/rebuild_20260101" "$BK/sub/rebuild_20260101_000009"; do
    [[ -e "$keep" ]] || { fail "M1 removed out-of-namespace object: $keep"; m1=1; }
done
for keep in "$BK/ruleset_20260101_000001.nft" "$BK/whitelist_ipv4_20260101.txt"; do
    [[ -e "$keep" ]] || { fail "M1 removed a separate artifact class: $keep"; m1=1; }
done
[[ $m1 -eq 0 ]] && pass "M1 exact namespace only — ruleset_*.nft, list txt, backups/, odd names untouched"

# --- M2 · serialization --------------------------------------------------------
reset_bk
for t in 20260101_000001 20260102_000002 20260103_000003 20260104_000004; do mk_legacy "$t"; done
exec 7>"$NFTBAN_RUN_DIR/nft_operations.lock"; flock 7        # simulate a rebuild holding it
out=$(NFTBAN_TIMEOUT_NFT_LOCK=1 nftban_legacy_backup_migrate 2>&1)
exec 7>&-
if [[ "$out" == *REFUSED_LOCK_BUSY* ]] && [[ $(find "$BK" -maxdepth 1 -name 'rebuild_*' | wc -l) -eq 4 ]]; then
    pass "M2 lock held by another owner -> migration refuses, ZERO deletion"
else
    fail "M2 migration mutated while the canonical lock was held ($out)"
fi

# --- M3 · observation failure -> zero deletion ---------------------------------
reset_bk
for t in 20260101_000001 20260102_000002 20260103_000003; do mk_legacy "$t"; done
chmod 0000 "$BK" 2>/dev/null
out=$(nftban_legacy_backup_migrate 2>&1); orc=$?
chmod 0755 "$BK" 2>/dev/null
if [[ "$(id -u)" == "0" ]]; then
    echo "  SKIP  M3 running as root: DAC_OVERRIDE prevents inducing the read failure"
elif [[ "$out" == *REFUSED_OBSERVATION_FAILED* && $orc -ne 0 ]] \
     && [[ $(find "$BK" -maxdepth 1 -name 'rebuild_*' | wc -l) -eq 3 ]]; then
    pass "M3 observation failure -> REFUSED, zero deletion (not an empty candidate set)"
else
    fail "M3 observation failure did not fail closed (out=$out rc=$orc)"
fi

# --- M7 · structural idempotency ----------------------------------------------
reset_bk
for t in 20260101_000001 20260102_000002 20260103_000003 20260104_000004 20260105_000005; do mk_legacy "$t"; done
o1=$(nftban_legacy_backup_migrate 2>&1); n1=$(find "$BK" -maxdepth 1 -name 'rebuild_*' | wc -l)
o2=$(nftban_legacy_backup_migrate 2>&1); n2=$(find "$BK" -maxdepth 1 -name 'rebuild_*' | wc -l)
if [[ "$o1" == *"removed=3"* && "$o2" == *"removed=0"* && "$n1" -eq 2 && "$n2" -eq 2 ]]; then
    pass "M7 idempotent: first run removed 3, second removed 0, floor stable"
else
    fail "M7 not idempotent (run1=$o1 n1=$n1 / run2=$o2 n2=$n2)"
fi

# --- no terminal state was fabricated on survivors -----------------------------
if grep -rq '^tx_state=' "$BK" 2>/dev/null; then
    fail "migration wrote tx_state onto a legacy survivor (history rewritten)"
else
    pass "no legacy survivor gained a terminal record"
fi

# --- M8 · FALSIFIABILITY -------------------------------------------------------
# Namespace inversion: a candidate finder without the exact-name gate sweeps
# unrelated objects. Proven here rather than asserted.
reset_bk; mkdir -p "$BK/rebuild_bogus"; mk_legacy 20260101_000001
broad=$(find "$BK" -mindepth 1 -maxdepth 1 -type d -name 'rebuild*' | wc -l)
strict=0
for d in "$BK"/rebuild_*; do _lbm_is_exact_namespace "$d" && strict=$((strict+1)); done
if (( broad > strict )); then
    pass "M8 NAMESPACE_INVERSION: a broad matcher selects $broad, the exact gate selects $strict"
else
    fail "M8 namespace gate is not narrowing anything — arm is vacuous"
fi
# Floor inversion: with the floor at 0 every legacy object becomes eligible.
reset_bk
for t in 20260101_000001 20260102_000002 20260103_000003; do mk_legacy "$t"; done
_LBM_LEGACY_FLOOR_SAVED=$_LBM_LEGACY_FLOOR; _LBM_LEGACY_FLOOR=0
c=$(_lbm_candidates | grep -c . )
_LBM_LEGACY_FLOOR=$_LBM_LEGACY_FLOOR_SAVED
c2=$(_lbm_candidates | grep -c . )
if (( c == 3 && c2 == 1 )); then
    pass "M8 FLOOR_INVERSION: floor=0 exposes all 3; floor=2 exposes only 1"
else
    fail "M8 floor inversion did not change the candidate set (floor may be inert): c=$c c2=$c2"
fi

echo
if [[ $FAIL -eq 0 ]]; then echo "RESULT: PASS"; exit 0; fi
echo "RESULT: FAIL"; exit 1
