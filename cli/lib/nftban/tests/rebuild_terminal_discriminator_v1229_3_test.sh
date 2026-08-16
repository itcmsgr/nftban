#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.229.3 0B — REBUILD TRANSACTION TERMINAL DISCRIMINATOR
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="rebuild-terminal-discriminator-v1229-3-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-16"
# meta:description="Proves ACTIVE vs TERMINAL is structurally observable for every newly created rebuild recovery snapshot, recorded in the existing snapshot_state file rather than a second state file. Eligibility is fail-closed: absent, malformed, unknown, unreadable, still-ACTIVE and write-failure all remain NON-PRUNABLE. Also asserts the terminal transition is reached only from the post-core terminal boundary, so a failed forward rebuild is not stamped terminal before its rollback has finished."
# meta:inventory.files="cli/lib/nftban/cli/cmd_firewall.sh"
# meta:inventory.privileges="none"
# meta:ta.id="rebuild_terminal_discriminator_v1229_3_test"
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
# WHY THIS EXISTS:
#   snapshot_state already answered "did the CAPTURE succeed" (VALID /
#   EMPTY_VERIFIED / FAILED). It could not answer "has the rebuild TRANSACTION
#   finished" -- the snapshot is step 0 of 12. Retention must never delete a
#   snapshot whose owning rebuild is still in flight, so termination has to be a
#   positively observed fact, never inferred from age or from capture state.
#
#       SNAPSHOT_CAPTURE_STATE != REBUILD_TRANSACTION_STATE
#       PENDING != COMPLETE        UNKNOWN != COMPLETE
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="$SCRIPT_DIR/../cli/cmd_firewall.sh"
FAIL=0
pass(){ echo "  PASS  $1"; }
fail(){ echo "  FAIL  $1"; FAIL=1; }

echo "=== rebuild terminal discriminator (v1.229.3 0B) ==="
[[ -f "$SUBJECT" ]] || { echo "  SUBJECT_NOT_FOUND: $SUBJECT"; exit 1; }

fn_body(){ awk -v f="^$1\\\\(\\\\) \\\\{" '$0 ~ f,/^\}/' "$SUBJECT"; }

WRAP="$(fn_body _firewall_rebuild_serialized)"
CORE="$(fn_body _firewall_rebuild_core)"
HELPER_W="$(fn_body _rebuild_tx_state_write)"
HELPER_R="$(fn_body _rebuild_tx_is_terminal)"
for pair in "wrapper:$WRAP" "core:$CORE" "tx_state_write:$HELPER_W" "tx_is_terminal:$HELPER_R"; do
    [[ -n "${pair#*:}" ]] || { echo "  SUBJECT_NOT_FOUND: ${pair%%:*}"; exit 1; }
done
pass "all four subjects located (non-vacuous extraction)"

# --- STATE MODEL: no second state file, VALID not overloaded -------------------
if grep -q 'snapshot_state' <<<"$HELPER_W"; then
    pass "transaction state is recorded in the EXISTING snapshot_state file"
else
    fail "transaction state is not written to snapshot_state (second state file?)"
fi
if grep -qE 'tx_state=.*VALID|VALID.*TERMINAL' <<<"$HELPER_W$HELPER_R"; then
    fail "capture state VALID is overloaded as a transaction state"
else
    pass "VALID is not reused to mean 'completed rebuild'"
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
eval "$HELPER_W"; eval "$HELPER_R"
mkdir -p "$TMP/rb"; printf 'state=VALID\nreason=\n' > "$TMP/rb/snapshot_state"

# --- B1 · new rebuild -> ACTIVE, and ACTIVE is NOT terminal --------------------
_rebuild_tx_state_write "$TMP/rb" ACTIVE
if grep -q '^tx_state=ACTIVE$' "$TMP/rb/snapshot_state"; then pass "B1 new rebuild records ACTIVE"
else fail "B1 ACTIVE not recorded"; fi
if _rebuild_tx_is_terminal "$TMP/rb"; then fail "B1 ACTIVE wrongly classified terminal (PENDING != COMPLETE)"
else pass "B1 ACTIVE is NOT prunable"; fi
grep -q '^state=VALID$' "$TMP/rb/snapshot_state" && pass "B1 existing capture contract preserved (append, not truncate)" \
    || fail "B1 append destroyed the existing snapshot_state contract"

# --- B2 · success -> TERMINAL_SUCCESS ------------------------------------------
_rebuild_tx_state_write "$TMP/rb" TERMINAL_SUCCESS
if _rebuild_tx_is_terminal "$TMP/rb"; then pass "B2 TERMINAL_SUCCESS is terminal"
else fail "B2 TERMINAL_SUCCESS not recognised"; fi

# --- B3 · failure with completed rollback -> TERMINAL_FAILURE ------------------
mkdir -p "$TMP/rb3"; : > "$TMP/rb3/snapshot_state"
_rebuild_tx_state_write "$TMP/rb3" ACTIVE
_rebuild_tx_state_write "$TMP/rb3" TERMINAL_FAILURE
if _rebuild_tx_is_terminal "$TMP/rb3"; then pass "B3 TERMINAL_FAILURE is terminal"
else fail "B3 TERMINAL_FAILURE not recognised"; fi

# --- B4 · failure BEFORE the terminal transition -> NON-PRUNABLE ---------------
mkdir -p "$TMP/rb4"; printf 'state=FAILED\n' > "$TMP/rb4/snapshot_state"
_rebuild_tx_state_write "$TMP/rb4" ACTIVE
if _rebuild_tx_is_terminal "$TMP/rb4"; then fail "B4 in-flight snapshot classified terminal"
else pass "B4 no terminal record -> NON-PRUNABLE"; fi

# --- B5 · malformed / unknown terminal value -> NON-PRUNABLE -------------------
for bad in "TERMINAL" "DONE" "terminal_success" "TERMINAL_SUCCESS_EXTRA" ""; do
    d="$TMP/bad$RANDOM$RANDOM"; mkdir -p "$d"
    printf 'state=VALID\ntx_state=%s\n' "$bad" > "$d/snapshot_state"
    if _rebuild_tx_is_terminal "$d"; then fail "B5 malformed value '$bad' accepted as terminal"; fi
done
pass "B5 malformed/unknown terminal values are all NON-PRUNABLE"

# --- B6 · unreadable / missing state -> NON-PRUNABLE ---------------------------
mkdir -p "$TMP/rb6"
if _rebuild_tx_is_terminal "$TMP/rb6"; then fail "B6 missing snapshot_state accepted as terminal"
else pass "B6 missing snapshot_state -> NON-PRUNABLE"; fi
if _rebuild_tx_is_terminal "$TMP/definitely-absent"; then fail "B6 absent directory accepted as terminal"
else pass "B6 absent directory -> NON-PRUNABLE"; fi

# --- B7 · terminal WRITE FAILURE never reads as terminal -----------------------
# WRITE_PRIMITIVE (proven on this head): a guard `[[ -d $_dir ]]` followed by a
# shell append redirection to "$_dir/snapshot_state".
#
# The guard means a wrong fixture can produce the right-looking answer WITHOUT
# reaching the write at all, so this arm proves three things separately:
#   1 the write statement was REACHED   (xtrace observation, not inference)
#   2 the write FAILED
#   3 eligibility is still FALSE
#
# FAILURE_FIXTURE: make the state path itself a DIRECTORY. Appending to a
# directory fails with EISDIR, which is a type error rather than a permission
# check -- so unlike chmod it cannot be bypassed by root/DAC_OVERRIDE. The
# containing dir stays a valid directory so the guard passes and the write is
# genuinely entered.
b7_trace="$TMP/b7.trace"

# B7 POSITIVE CONTROL: same path, normal destination -> write succeeds
b7p="$TMP/rb7pos"; mkdir -p "$b7p"; printf 'state=VALID\ntx_state=ACTIVE\n' > "$b7p/snapshot_state"
if _rebuild_tx_state_write "$b7p" TERMINAL_SUCCESS && _rebuild_tx_is_terminal "$b7p"; then
    pass "B7 POSITIVE CONTROL: same terminal path succeeds on a normal destination"
else
    fail "B7 POSITIVE CONTROL failed — the negative arm would prove nothing"
fi

# B7 NEGATIVE: deterministic, root-proof write failure
b7n="$TMP/rb7neg"; mkdir -p "$b7n/snapshot_state"     # state path is a DIRECTORY
[[ -d "$b7n" ]] && pass "B7 guard precondition holds (containing dir valid -> write is entered)" \
                || fail "B7 fixture invalidates the guard; the write would never be reached"

exec {b7fd}>"$b7_trace"
BASH_XTRACEFD=$b7fd; set -x
_rebuild_tx_state_write "$b7n" TERMINAL_SUCCESS >/dev/null 2>&1
b7rc=$?
set +x; exec {b7fd}>&-

if grep -q 'tx_state=%s' "$b7_trace" 2>/dev/null; then
    pass "B7 TERMINAL_WRITE_REACHED: the append statement provably executed"
else
    fail "B7 write statement was NEVER reached — result would be a guard artifact, not a write failure"
fi
if [[ $b7rc -ne 0 ]]; then
    pass "B7 TERMINAL_WRITE_FAILED: primitive reports non-zero (never silently 'done')"
else
    fail "B7 write unexpectedly SUCCEEDED against a directory destination — fixture invalid"
fi
if _rebuild_tx_is_terminal "$b7n"; then
    fail "B7 failed terminal write still classified terminal — retention safety would depend on the metadata write"
else
    pass "B7 ARTIFACT_NON_PRUNABLE: failed terminal write leaves the snapshot non-prunable"
fi

# --- B8 · ORDERING: terminal is reached only from the post-core boundary -------
# Not a token grep: the transition must appear AFTER the core call and AFTER the
# return-code capture inside the wrapper, and must NOT appear in the core at all.
w_core=$(grep -n '_firewall_rebuild_core "\$@"' <<<"$WRAP" | head -1 | cut -d: -f1)
w_rc=$(grep -n '_rebuild_rc=\$?' <<<"$WRAP" | head -1 | cut -d: -f1)
w_term=$(grep -n 'TERMINAL_SUCCESS' <<<"$WRAP" | head -1 | cut -d: -f1)
if [[ -n "$w_core" && -n "$w_rc" && -n "$w_term" ]]; then
    if (( w_term > w_core && w_term > w_rc )); then
        pass "B8 terminal transition occurs AFTER the core returns and after rc capture"
    else
        fail "B8 terminal transition is not after the core's terminal boundary"
    fi
else
    fail "B8 SUBJECT_NOT_FOUND: could not locate core call / rc capture / terminal write"
fi
if grep -qE 'TERMINAL_SUCCESS|TERMINAL_FAILURE' <<<"$CORE"; then
    fail "B8 core stamps a terminal state internally — could fire before rollback completes"
else
    pass "B8 core never stamps terminal state (rollback completes inside it first)"
fi
if grep -q '_REBUILD_SNAPSHOT_DIR=""' <<<"$WRAP"; then
    pass "B8 wrapper resets the published snapshot dir per invocation (no stale carry-over)"
else
    fail "B8 wrapper does not reset _REBUILD_SNAPSHOT_DIR — a prior run's dir could be stamped"
fi

# --- B9 · INVERSION: an eligibility read that accepts non-terminal must fail ----
_rebuild_tx_is_terminal_BROKEN() {
    local _dir="$1"
    [[ -r "$_dir/snapshot_state" ]] || return 1
    return 0   # accepts anything, the defect this guard exists to prevent
}
inv_fail=0
if _rebuild_tx_is_terminal_BROKEN "$TMP/rb4"; then inv_fail=1; fi   # rb4 is ACTIVE-only
if [[ $inv_fail -eq 1 ]]; then
    pass "B9 inversion: a permissive eligibility read DOES accept an in-flight snapshot (B4/B5/B6 are falsifiable)"
else
    fail "B9 inversion did not reproduce the defect — fail-closed arms may be vacuous"
fi

echo
if [[ $FAIL -eq 0 ]]; then echo "RESULT: PASS"; exit 0; fi
echo "RESULT: FAIL"; exit 1
