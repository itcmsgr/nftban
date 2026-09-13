#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.230.0 Gate 6R — REFUSAL PRODUCES A MACHINE-READABLE CONTRACT
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="rebuild-refusal-contract-v1230-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-13"
# meta:description="Proves that a firewall rebuild REFUSED by the canonical convergence lock publishes a machine-readable result contract (disposition REFUSED, reason CONVERGENCE_LOCK_HELD, modified=false, enforcement_unchanged=true, transaction NOT_STARTED) instead of dying with a generic rc=1 and no record, that the execution witness is written only once the rebuild actually starts, and that a refused rebuild leaves the boot projection artifact byte-identical (hash, never mtime). Guards the dns1 v1.229.13->v1.229.14 defect where a pre-mutation refusal produced no contract and the installer collapsed ABSENCE OF CONTRACT into FAILED_REBUILD on a host whose enforcement was untouched."
# meta:inventory.files="cli/lib/nftban/cli/cmd_firewall.sh,cli/lib/nftban/core/nftban_rebuild_classify.sh"
# meta:inventory.privileges="none"
# meta:ta.id="rebuild_refusal_contract_v1230_test"
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
# ⛔ NO ARM IN THIS FILE PARSES THE REFUSAL STDERR TEXT.
# The production defect was diagnosed FROM that text, which is exactly why the fix
# must not depend on it. Every assertion below reads the published JSON contract.
# One arm deliberately asserts the contract is complete while stderr is DISCARDED.
#
# R1  lock held -> REFUSED contract, modified=false, enforcement unchanged, core never ran
# R3b a refused rebuild leaves the boot projection artifact IDENTICAL (sha256, not mtime)
# R6a the execution witness is absent when the rebuild never started
# R6b the execution witness is present, and names THIS operation, when it did start
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="$SCRIPT_DIR/../cli/cmd_firewall.sh"
CLASSIFY="$SCRIPT_DIR/../core/nftban_rebuild_classify.sh"
FAIL=0
pass(){ echo "  PASS  $1"; }
fail(){ echo "  FAIL  $1"; FAIL=1; }

echo "=== rebuild refusal contract (v1.230.0 Gate 6R) ==="

[[ -f "$SUBJECT" ]]  || { echo "  SUBJECT_NOT_FOUND: $SUBJECT"; exit 1; }
[[ -f "$CLASSIFY" ]] || { echo "  SUBJECT_NOT_FOUND: $CLASSIFY"; exit 1; }
command -v flock >/dev/null || { echo "  TEST_INVALID: flock(1) unavailable"; exit 1; }
command -v sha256sum >/dev/null || { echo "  TEST_INVALID: sha256sum unavailable"; exit 1; }

# --- extract exactly the functions under test --------------------------------
extract_fn() {
    awk -v fn="$1" 'BEGIN{re="^"fn"\\(\\) \\{"} $0 ~ re,/^\}/' "$SUBJECT"
}
SRC=""
for fn in _rebuild_is_update_lifecycle _rebuild_optval _rebuild_write_execution_witness \
          _rebuild_have_emitter _rebuild_publish_refusal _firewall_rebuild_serialized; do
    body="$(extract_fn "$fn")"
    if [[ -z "$body" ]]; then
        echo "  SUBJECT_NOT_FOUND: $fn not located in $SUBJECT"; exit 1
    fi
    SRC+="$body"$'\n'
done

# The emitter is the SINGLE result producer and lives in the classification library,
# exactly as it does at runtime. Sourcing it here (rather than restating the JSON)
# keeps this test bound to the shipped producer.
# ⛔ The library sets `-Eeuo pipefail` at file scope; restore this harness's own
# options afterwards or the first deliberate non-zero return kills the test run and
# every remaining arm silently disappears (a failed observation, not a finding).
_saved_opts="$(set +o)"
# shellcheck source=/dev/null
source "$CLASSIFY" 2>/dev/null || { echo "  TEST_INVALID: cannot source $CLASSIFY"; exit 1; }
eval "$_saved_opts"
eval "$SRC"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export NFTBAN_RUN_DIR="$TMP/run"
mkdir -p "$NFTBAN_RUN_DIR" "$TMP/results"
LOCK="$NFTBAN_RUN_DIR/nft_operations.lock"

CORE_RAN="$TMP/core_ran"
_firewall_rebuild_core() { echo ran > "$CORE_RAN"; return "${STUB_RC:-0}"; }

# A stand-in for the persistent boot projection. R3b asserts a refused rebuild leaves
# it byte-identical.
#   ⛔ IDENTITY IS CONTENT, NOT TIME. mtime is not provenance: dpkg preserves build
#   timestamps and a publication path may legitimately no-op on a byte-identical
#   candidate, so an unchanged mtime proves nothing and a changed one proves nothing.
PROJ="$TMP/nftables.conf"
printf 'table ip nftban { }\n# established by the previous transaction\n' > "$PROJ"
PROJ_SHA_BEFORE="$(sha256sum "$PROJ" | cut -d' ' -f1)"

jqget() { # jqget <file> <jq-filter>
    if command -v jq >/dev/null 2>&1; then jq -r "$2" "$1" 2>/dev/null; return; fi
    # jq-free fallback: the record is emitted by a fixed printf template, so a
    # line-scoped sed is sufficient and deterministic here.
    local key="${2#.}"; key="${key%%[|[:space:]]*}"
    sed -n "s/.*\"${key//./\\.}\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" "$1" | head -1
}

# ── R1 ────────────────────────────────────────────────────────────────────────
rm -f "$CORE_RAN"
OPID="rebuild-test-$$-r1"
RES="$TMP/results/$OPID.json"
WIT="$TMP/results/$OPID.exec"
exec 7>"$LOCK"; flock 7                    # another nft operation holds convergence
# ⛔ stderr is DISCARDED here on purpose: if any assertion below needed it, the fix
# would still depend on message text.
NFTBAN_TIMEOUT_NFT_LOCK=1 _firewall_rebuild_serialized \
    --install-context --result-file "$RES" --operation-id "$OPID" \
    --execution-witness "$WIT" >/dev/null 2>/dev/null
rc=$?
exec 7>&-

[[ $rc -eq 1 ]] && pass "R1 refusal returns rc=1 (unchanged; the contract is the authority)" \
                || fail "R1 refusal rc=$rc, want 1"
[[ ! -f "$CORE_RAN" ]] && pass "R1 the rebuild NEVER STARTED (core not invoked)" \
                       || fail "R1 the core ran under a held lock — this is not a refusal"
if [[ -s "$RES" ]]; then
    pass "R1 a result contract WAS published by the refusal path"
    [[ "$(jqget "$RES" .disposition)" == "REFUSED" ]] \
        && pass "R1 disposition=REFUSED" \
        || fail "R1 disposition=$(jqget "$RES" .disposition), want REFUSED"
    if grep -q 'CONVERGENCE_LOCK_HELD' "$RES"; then
        pass "R1 machine-readable reason CONVERGENCE_LOCK_HELD present"
    else
        fail "R1 reason_codes do not carry CONVERGENCE_LOCK_HELD"
    fi
    [[ "$(jqget "$RES" .modified)" == "false" ]] \
        && pass "R1 modified=false" || fail "R1 modified=$(jqget "$RES" .modified), want false"
    [[ "$(jqget "$RES" .enforcement_unchanged)" == "true" ]] \
        && pass "R1 enforcement_unchanged=true" \
        || fail "R1 enforcement_unchanged=$(jqget "$RES" .enforcement_unchanged), want true"
    [[ "$(jqget "$RES" .operation_id)" == "$OPID" ]] \
        && pass "R1 record is bound to THIS operation" \
        || fail "R1 operation_id=$(jqget "$RES" .operation_id), want $OPID"
    if grep -q '"committed": false' "$RES" && grep -q 'NOT_STARTED' "$RES"; then
        pass "R1 transaction committed=false reason=NOT_STARTED"
    else
        fail "R1 transaction block does not report an unstarted, uncommitted transaction"
    fi
else
    fail "R1 NO contract published — this is the dns1 defect verbatim"
fi

# ── R6a ───────────────────────────────────────────────────────────────────────
[[ ! -e "$WIT" ]] && pass "R6a no execution witness: execution provably did NOT occur" \
                  || fail "R6a an execution witness exists for a rebuild that never started"

# ── R3b ───────────────────────────────────────────────────────────────────────
PROJ_SHA_AFTER="$(sha256sum "$PROJ" | cut -d' ' -f1)"
if [[ "$PROJ_SHA_BEFORE" == "$PROJ_SHA_AFTER" ]]; then
    pass "R3b boot projection artifact IDENTICAL across the refusal (sha256 $PROJ_SHA_AFTER)"
else
    fail "R3b boot projection CONTENT changed during a refusal that mutated nothing"
fi

# ── R6b: positive control — the witness appears only when the rebuild starts ──
rm -f "$CORE_RAN"
OPID2="rebuild-test-$$-r6b"
RES2="$TMP/results/$OPID2.json"
WIT2="$TMP/results/$OPID2.exec"
STUB_RC=0 _firewall_rebuild_serialized \
    --install-context --result-file "$RES2" --operation-id "$OPID2" \
    --execution-witness "$WIT2" >/dev/null 2>&1
rc=$?
[[ $rc -eq 0 && -f "$CORE_RAN" ]] && pass "R6b free lock -> the rebuild EXECUTES" \
                                  || fail "R6b free lock -> the rebuild did not execute (rc=$rc)"
if [[ -s "$WIT2" ]] && grep -q "operation_id=$OPID2" "$WIT2"; then
    pass "R6b execution witness present and NAMES this operation (existence is not identity)"
else
    fail "R6b execution witness missing or not bound to this operation"
fi

# ── INVERSION: the pre-fix wrapper must fail R1 ───────────────────────────────
# ⛔ NEGATIVE CONTROL AGAINST THE MOTIVATING DEFECT, synthesised by DECLARED INVERSION
# of the fix (the refusal publishes nothing) rather than by checking out an older ref —
# origin/main stops being "pre-fix" the moment the fix merges. The SUBJECT is the real
# shipped wrapper; only the publication step is reverted to its v1.229.14 shape.
rm -f "$CORE_RAN"
OPID3="rebuild-test-$$-inv"
RES3="$TMP/results/$OPID3.json"
(
  _rebuild_publish_refusal() { return 0; }          # v1.229.14: refuse, publish NOTHING
  exec 7>"$LOCK"; flock 7
  NFTBAN_TIMEOUT_NFT_LOCK=1 _firewall_rebuild_serialized \
      --install-context --result-file "$RES3" --operation-id "$OPID3" \
      >/dev/null 2>&1
  exec 7>&-
)
if [[ ! -e "$RES3" ]]; then
    pass "inversion: the pre-fix refusal path publishes NO contract (R1 is falsifiable)"
else
    fail "inversion did not reproduce the defect — R1 may be vacuous"
fi

echo
if [[ $FAIL -eq 0 ]]; then echo "RESULT: PASS"; exit 0; fi
echo "RESULT: FAIL"; exit 1
