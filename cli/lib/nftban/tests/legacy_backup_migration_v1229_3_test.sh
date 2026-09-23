#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.229.3 0C — LEGACY rebuild_* BACKUP MIGRATION
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="legacy-backup-migration-v1229-3-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-16"
# meta:description="Proves the legacy rebuild_* migration only ever removes pre-0B recovery directories it can positively classify, classifying WITHOUT the canonical nft_operations.lock and taking it only for one bounded, re-verified deletion batch (zero candidates = zero acquisitions; candidate AND floor re-verified; observation cache never authorises a deletion), preserving the newest two legacy generations by deterministic name order. Keeps every new-format, malformed, unreadable and out-of-namespace object, deletes nothing on any observation failure, never backfills terminal state, and is structurally idempotent."
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
# LBM_TEST_SUBJECT: run this suite against another revision of the module (inversion only).
SUBJECT="${LBM_TEST_SUBJECT:-$SCRIPT_DIR/../core/nftban_legacy_backup_migration.sh}"
FAIL=0
pass(){ echo "  PASS  $1"; }
fail(){ echo "  FAIL  $1"; FAIL=1; }

echo "=== legacy backup migration (v1.229.3 0C) ==="
[[ -f "$SUBJECT" ]] || { echo "  SUBJECT_NOT_FOUND: $SUBJECT"; exit 1; }
command -v flock >/dev/null || { echo "  TEST_INVALID: flock(1) unavailable"; exit 1; }
# The real flock(1), resolved BEFORE the counting wrapper below shadows the name.
FLOCK_BIN="$(command -v flock)"

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
mkdir -p "$NFTBAN_DATA_DIR/backup" "$NFTBAN_DATA_DIR/state" "$NFTBAN_RUN_DIR"
BK="$NFTBAN_DATA_DIR/backup"
# shellcheck source=/dev/null
source "$SUBJECT"
# Bounded waits keep a refusal arm (and an inversion run against old code) fast.
_LBM_LOCK_WAIT=3
CACHE="$NFTBAN_DATA_DIR/state/legacy-backup-migration.state"

# valid pre-0B object: the producer's grammar (state in the A2 closed set + captured_at)
mk_legacy(){ mkdir -p "$BK/rebuild_$1"; printf 'state=VALID\nreason=\nnftban_table=yes\nlist_rc=0\njson_rc=0\ncaptured_at=2026-01-01T00:00:00Z\n' > "$BK/rebuild_$1/snapshot_state"; }
# readable, no tx_state, but does NOT satisfy the pre-0B grammar
mk_malformed(){ mkdir -p "$BK/rebuild_$1"; printf '%s\n' "$2" > "$BK/rebuild_$1/snapshot_state"; }
mk_new(){    mkdir -p "$BK/rebuild_$1"; printf 'state=VALID\ntx_state=%s\n' "$2" > "$BK/rebuild_$1/snapshot_state"; }
reset_bk(){  rm -rf "$BK"; mkdir -p "$BK"; rm -f "$CACHE"; }

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
exec 7>"$NFTBAN_RUN_DIR/nft_operations.lock"; "$FLOCK_BIN" 7   # simulate a rebuild holding it
out=$(nftban_legacy_backup_migrate 2>&1)
exec 7>&-
if [[ "$out" == *REFUSED_LOCK_BUSY* ]] && [[ $(find "$BK" -maxdepth 1 -name 'rebuild_*' | wc -l) -eq 4 ]]; then
    pass "M2 lock held by another owner -> migration refuses, ZERO deletion"
else
    fail "M2 migration mutated while the canonical lock was held ($out)"
fi

# =============================================================================
# v1.234.0 R2 — the lock is for the MUTATION, not for the look
# =============================================================================
# Independent witnesses (the module's self-reported fields are never the only proof):
#   * lock acquisitions are counted by a flock(1) wrapper, and a held lock is used
#     as a behavioural witness (a run that touched it would block and refuse);
#   * classification work is counted by wrapping _lbm_classify.
mk_old93(){ mkdir -p "$BK/rebuild_$1"; for f in ruleset.json ruleset.nft sets validator_state; do : > "$BK/rebuild_$1/$f"; done; }
field(){ sed -n "s/.*[[:space:]]$1=\([^[:space:]]*\).*/\1/p" <<<"$2" | head -1; }
FLOCK_CALLS="$TMP/flock.calls"; FLOCK_SENTINEL=""
flock(){ echo x >> "$FLOCK_CALLS"; [[ -n "$FLOCK_SENTINEL" ]] && : > "$FLOCK_SENTINEL"; "$FLOCK_BIN" "$@"; }
eval "$(declare -f _lbm_classify | sed '1s/_lbm_classify/_lbm_classify_real/')"
CLASSIFY_CALLS="$TMP/classify.calls"
_lbm_classify(){ echo x >> "$CLASSIFY_CALLS"; _lbm_classify_real "$@"; }
counts_reset(){ : > "$FLOCK_CALLS"; : > "$CLASSIFY_CALLS"; }
n_flock(){ wc -l < "$FLOCK_CALLS"; }
n_classify(){ wc -l < "$CLASSIFY_CALLS"; }
tree_digest(){ find "$BK" -printf '%P %y\n' | LC_ALL=C sort | sha256sum | cut -d' ' -f1; }
srv3_shape(){ reset_bk; local i; for i in $(seq -w 1 40); do mk_old93 "202604${i:0:1}${i:1:1}_1${i}000"; done
              mk_legacy 20260815_000001; mk_legacy 20260815_000002; mk_new 20260920_000001 TERMINAL_FAILURE; }

# --- R2-I2 · ZERO candidates => ZERO lock acquisitions -------------------------
# srv3's measured shape in miniature: many :93 dirs, LEGACY == floor, one NEW_FORMAT.
# The lock is HELD by "another owner" throughout. A run that so much as tried to take
# it would block _LBM_LOCK_WAIT and refuse; the fixed module never touches it.
srv3_shape; D0=$(tree_digest); counts_reset
exec 7>"$NFTBAN_RUN_DIR/nft_operations.lock"; "$FLOCK_BIN" 7
t0=$SECONDS; out=$(nftban_legacy_backup_migrate 2>&1); dt=$((SECONDS - t0))
exec 7>&-
if [[ "$out" == *"LBM_RESULT=OK "* && $(n_flock) -eq 0 && $dt -lt $_LBM_LOCK_WAIT \
      && "$(field lock_acquisitions "$out")" == "0" && "$(tree_digest)" == "$D0" ]]; then
    pass "R2-I2 zero candidates -> ZERO lock acquisitions (lock held elsewhere, run returned OK in ${dt}s, all preserved)"
else
    fail "R2-I2 zero-candidate run touched the lock or mutated (flock=$(n_flock) dt=${dt}s out=$out)"
fi
[[ "$(field unknown_missing_state "$out")" == "40" && "$(field legacy "$out")" == "2" && "$(field candidates "$out")" == "0" ]] \
    && pass "R2-I7 no-op run still reports the census (unknown_missing_state=40 legacy=2 candidates=0)" \
    || fail "R2-I7 no-op census wrong or missing ($out)"

# --- R2 · observation cache written only from a clean zero-candidate observation ----
if [[ -f "$CACHE" ]] && [[ "$(stat -c %a "$CACHE")" == "600" ]] \
   && grep -q '^SCHEMA=legacy-backup-migration-v1$' "$CACHE" \
   && grep -q '^DELETION_CANDIDATES=0$' "$CACHE" \
   && grep -q "^POPULATION_FINGERPRINT=sha256:$(_lbm_fingerprint)$" "$CACHE" \
   && grep -qE '^OBSERVED_AT=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' "$CACHE"; then
    pass "R2 cache: mode 0600, schema, zero candidates, live fingerprint, UTC observation time"
else
    fail "R2 cache missing or malformed: $(cat "$CACHE" 2>/dev/null | tr '\n' ' ')"
fi
if grep -qiE '^(DONE|COMPLETE|COMPLETED|MIGRATED|SAFE|VALID|STATUS)=' "$CACHE" 2>/dev/null; then
    fail "R2 cache carries a judgement key — it must certify an observation, never 'done/safe/migrated'"
else
    pass "R2 cache carries no judgement key (no done / safe / migrated / valid)"
fi

# --- R2 TERMINATION · unchanged population -> cache hit, NO classification ------
counts_reset; out=$(nftban_legacy_backup_migrate 2>&1)
if [[ "$(field cache "$out")" == "hit" && $(n_classify) -eq 0 && $(n_flock) -eq 0 ]]; then
    pass "R2 TERMINATION second run: cache=hit, 0 classify calls, 0 lock acquisitions"
else
    fail "R2 TERMINATION did not short-circuit (cache=$(field cache "$out") classify=$(n_classify) flock=$(n_flock))"
fi

# --- R2 POPULATION-CHANGE · a new dir invalidates the cache -------------------
mk_old93 20260808_000001; counts_reset; out=$(nftban_legacy_backup_migrate 2>&1)
[[ "$(field cache "$out")" == "miss" && $(n_classify) -eq 44 && $(n_flock) -eq 0 ]] \
    && pass "R2 POPULATION-CHANGE new :93 dir -> cache=miss -> full rescan (44 classified), still 0 locks" \
    || fail "R2 POPULATION-CHANGE not detected (cache=$(field cache "$out") classify=$(n_classify))"
mk_legacy 20260816_000003; counts_reset; out=$(nftban_legacy_backup_migrate 2>&1)
if [[ "$(field cache "$out")" == "miss" && "$(field removed "$out")" == "1" && $(n_flock) -eq 1 \
      && ! -d "$BK/rebuild_20260815_000001" && -d "$BK/rebuild_20260815_000002" && -d "$BK/rebuild_20260816_000003" ]]; then
    pass "R2 POPULATION-CHANGE new LEGACY above the floor -> exactly the oldest removed, one lock window"
else
    fail "R2 POPULATION-CHANGE LEGACY arm wrong (out=$out flock=$(n_flock))"
fi
[[ ! -f "$CACHE" || "$(grep -c '' "$CACHE")" -gt 0 ]] && ! grep -q "sha256:$(_lbm_fingerprint)" "$CACHE" 2>/dev/null \
    && pass "R2 a mutating run writes NO cache for the post-mutation population" \
    || fail "R2 a mutating run certified its own result"

# --- R2 IN-DIR-CHANGE · an entry created inside a dir invalidates the cache ----
srv3_shape; nftban_legacy_backup_migrate >/dev/null 2>&1        # writes the cache
sleep 0.05; : > "$BK/rebuild_20260410_110000/snapshot_state"     # a :93 dir gains an entry
counts_reset; out=$(nftban_legacy_backup_migrate 2>&1)
[[ "$(field cache "$out")" == "miss" && $(n_classify) -gt 0 ]] \
    && pass "R2 IN-DIR-CHANGE entry created inside a dir -> dir mtime -> cache=miss" \
    || fail "R2 IN-DIR-CHANGE missed (cache=$(field cache "$out"))"

# --- R2 CACHE-INVALID · never a hit, never a deletion basis -------------------
ci=0
for mut in 's/^SCHEMA=.*/SCHEMA=bogus/' 's/^CLASSIFIER_VERSION=.*/CLASSIFIER_VERSION=999/' \
           's/^FLOOR=.*/FLOOR=0/' 's/^DELETION_CANDIDATES=.*/DELETION_CANDIDATES=1/' \
           's/^OBSERVED_AT_EPOCH=.*/OBSERVED_AT_EPOCH=9999999999/' 's/^POPULATION=.*/POPULATION=x/'; do
    srv3_shape; nftban_legacy_backup_migrate >/dev/null 2>&1; sed -i "$mut" "$CACHE"
    counts_reset; out=$(nftban_legacy_backup_migrate 2>&1)
    [[ "$(field cache "$out")" == "invalid" && $(n_classify) -gt 0 ]] || { fail "R2 CACHE-INVALID '$mut' -> cache=$(field cache "$out") classify=$(n_classify)"; ci=1; }
done
srv3_shape; nftban_legacy_backup_migrate >/dev/null 2>&1; printf 'garbage\n\x00\n' > "$CACHE"
counts_reset; out=$(nftban_legacy_backup_migrate 2>&1)
[[ "$(field cache "$out")" == "invalid" && $(n_classify) -gt 0 ]] || { fail "R2 CACHE-INVALID garbled -> cache=$(field cache "$out")"; ci=1; }
[[ $ci -eq 0 ]] && pass "R2 CACHE-INVALID schema/classifier/floor/candidates/future/garbled -> invalid, full rescan"
srv3_shape; nftban_legacy_backup_migrate >/dev/null 2>&1
sed -i "s/^OBSERVED_AT_EPOCH=.*/OBSERVED_AT_EPOCH=$(( ${EPOCHREALTIME%%[.,]*} - 8*86400 ))/" "$CACHE"
counts_reset; out=$(nftban_legacy_backup_migrate 2>&1)
[[ "$(field cache "$out")" == "expired" && $(n_classify) -gt 0 ]] \
    && pass "R2 TTL an 8-day-old observation -> cache=expired -> full rescan (7-day backstop)" \
    || fail "R2 TTL not enforced (cache=$(field cache "$out"))"

# --- R2 DRY-RUN · reports the cache verdict but ALWAYS classifies; writes nothing, no lock ---
srv3_shape; nftban_legacy_backup_migrate >/dev/null 2>&1; C0=$(sha256sum "$CACHE" | cut -d' ' -f1); D0=$(tree_digest)
counts_reset; out=$(nftban_legacy_backup_migrate --dry-run 2>&1)
if [[ "$(field cache "$out")" == "would-hit" && $(n_classify) -eq 43 && $(n_flock) -eq 0 \
      && "$(sha256sum "$CACHE" | cut -d' ' -f1)" == "$C0" && "$(tree_digest)" == "$D0" ]]; then
    pass "R2 DRY-RUN cache=would-hit AND full classification (43), no lock, cache + tree byte-identical"
else
    fail "R2 DRY-RUN wrong (cache=$(field cache "$out") classify=$(n_classify) flock=$(n_flock))"
fi
mk_legacy 20260816_000003; mk_legacy 20260816_000004; D0=$(tree_digest); counts_reset
out=$(nftban_legacy_backup_migrate --dry-run 2>&1)
[[ "$(field candidates "$out")" == "2" && "$(field removed "$out")" == "0" && $(n_flock) -eq 0 && "$(tree_digest)" == "$D0" ]] \
    && pass "R2 DRY-RUN with candidates: reports 2, deletes nothing, takes no lock" \
    || fail "R2 DRY-RUN with candidates mutated or locked ($out)"

# --- R2 BATCH-BOUND · one bounded lock window per invocation ------------------
reset_bk; for i in $(seq -w 1 10); do mk_legacy "202601${i}_000000"; done
for i in 01 02 03; do mk_old93 "202604${i}_000000"; done
# ${…:-}: an inversion run against a module WITHOUT a batch bound must record FAIL here, not abort under set -u
_LBM_MAX_MUTATION_BATCH_SAVED=${_LBM_MAX_MUTATION_BATCH:-}; _LBM_MAX_MUTATION_BATCH=3
bb=0; expect_removed=(3 3 2 0)
for run in 0 1 2 3; do
    counts_reset; out=$(nftban_legacy_backup_migrate 2>&1)
    want_locks=$(( expect_removed[run] > 0 ? 1 : 0 ))
    [[ "$(field removed "$out")" == "${expect_removed[$run]}" && $(n_flock) -eq $want_locks ]] \
        || { fail "R2 BATCH-BOUND run $((run+1)): removed=$(field removed "$out") (want ${expect_removed[$run]}) locks=$(n_flock) (want $want_locks)"; bb=1; }
done
[[ -n "$_LBM_MAX_MUTATION_BATCH_SAVED" ]] && _LBM_MAX_MUTATION_BATCH=$_LBM_MAX_MUTATION_BATCH_SAVED
survivors=$(find "$BK" -maxdepth 1 -name 'rebuild_2026011*' -o -maxdepth 1 -name 'rebuild_2026010*' | sort | tr '\n' ' ')
[[ -d "$BK/rebuild_20260109_000000" && -d "$BK/rebuild_20260110_000000" && ! -d "$BK/rebuild_20260108_000000" \
   && $(find "$BK" -maxdepth 1 -name 'rebuild_202604*' | wc -l) -eq 3 ]] || { fail "R2 BATCH-BOUND floor/UNKNOWN not intact: $survivors"; bb=1; }
[[ $bb -eq 0 ]] && pass "R2 BATCH-BOUND 8 candidates, batch 3: runs remove 3,3,2,0 oldest-first, ONE lock window per run, floor + UNKNOWN intact"

# --- R2 TOCTOU-CANDIDATE · a candidate that changes while we wait is KEPT ------
# A REAL race: the test holds the lock; the migration scans lock-free, decides, and
# blocks on flock (the wrapper drops a sentinel). Only then is the candidate mutated.
toctou_run(){   # $1 = mutation to apply while the migration is blocked on the lock
    FLOCK_SENTINEL="$TMP/blocked"; rm -f "$FLOCK_SENTINEL"
    exec 7>"$NFTBAN_RUN_DIR/nft_operations.lock"; "$FLOCK_BIN" 7
    # 7>&- : the child must NOT inherit the test's lock-holding fd -- flock locks belong to the
    # open file description, so an inherited copy would keep the lock after the parent closes it.
    _LBM_LOCK_WAIT=30 nftban_legacy_backup_migrate > "$TMP/toctou.out" 2>&1 7>&- & local bg=$!
    local _; for _ in $(seq 1 200); do [[ -e "$FLOCK_SENTINEL" ]] && break; sleep 0.05; done
    [[ -e "$FLOCK_SENTINEL" ]] || { echo "SENTINEL_NEVER_SEEN"; }
    eval "$1"
    exec 7>&-; wait "$bg"; FLOCK_SENTINEL=""
    cat "$TMP/toctou.out"
}
reset_bk; for t in 20260101_000001 20260102_000002 20260103_000003 20260104_000004; do mk_legacy "$t"; done
out=$(toctou_run 'rm -f "$BK/rebuild_20260101_000001/snapshot_state"')
[[ "$out" == *"LBM_RESULT=ABORTED_TOCTOU"* && "$out" != *SENTINEL_NEVER_SEEN* && -d "$BK/rebuild_20260101_000001" && -d "$BK/rebuild_20260102_000002" ]] \
    && pass "R2 TOCTOU-CANDIDATE candidate became UNKNOWN under the wait -> ABORTED, nothing deleted" \
    || fail "R2 TOCTOU-CANDIDATE ($out)"

# --- R2 TOCTOU-FLOOR · the phantom-LEGACY race (design §2.1) --------------------
# A < B < C all LEGACY-shaped before the lock; C is an in-flight rebuild that gains
# tx_state while we wait. Re-checking only the candidate (A) would delete A and leave
# ONE real LEGACY -- below the floor. Re-verifying the floor must abort instead.
reset_bk; for t in 20260101_000001 20260102_000002 20260103_000003; do mk_legacy "$t"; done
out=$(toctou_run 'printf "tx_state=ACTIVE\n" >> "$BK/rebuild_20260103_000003/snapshot_state"')
[[ "$out" == *"LBM_RESULT=ABORTED_TOCTOU"* && "$out" == *"rebuild_20260103_000003"* && -d "$BK/rebuild_20260101_000001" ]] \
    && pass "R2 TOCTOU-FLOOR phantom LEGACY left the floor under the wait -> ABORTED, the real LEGACY A survives" \
    || fail "R2 TOCTOU-FLOOR ($out)"
# non-vacuity: the same race WITHOUT the floor change deletes A -> the abort above was caused by the floor check
reset_bk; for t in 20260101_000001 20260102_000002 20260103_000003; do mk_legacy "$t"; done
out=$(toctou_run ':')
[[ "$out" == *"LBM_RESULT=OK "* && "$(field removed "$out")" == "1" && ! -d "$BK/rebuild_20260101_000001" ]] \
    && pass "R2 TOCTOU-FLOOR control: identical race with no change removes A (the abort is caused by the floor check)" \
    || fail "R2 TOCTOU-FLOOR control did not delete A — the floor arm may be vacuous ($out)"

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
