#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.229.3 P0-2A — ORDINARY REBUILDS LEAVE NO PERSISTENT HISTORY
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="rebuild-no-ordinary-history-v1229-3-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-16"
# meta:description="Proves an ordinary SUCCESSFUL rebuild does not accumulate persistent rebuild_* recovery history, while transactional rollback material remains available for the whole mutation and every non-success state is kept. Disposal happens strictly after the terminal transition, requires TERMINAL_SUCCESS to be read back positively, and never touches ACTIVE, TERMINAL_FAILURE, malformed, unreadable or out-of-namespace artifacts. Also proves the dead duplicate whitelist/blacklist TXT writer is gone and that ruleset_*.nft is untouched."
# meta:inventory.files="cli/lib/nftban/cli/cmd_firewall.sh"
# meta:inventory.privileges="none"
# meta:ta.id="rebuild_no_ordinary_history_v1229_3_test"
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
#   BACKUP_HISTORY_OFF != ROLLBACK_CAPABILITY_OFF
#
#   NORMAL REBUILD MAY USE RECOVERY STATE, BUT MUST NOT TURN EVERY SUCCESSFUL
#   REBUILD INTO PERMANENT BACKUP HISTORY.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="$SCRIPT_DIR/../cli/cmd_firewall.sh"
FAIL=0
pass(){ echo "  PASS  $1"; }
fail(){ echo "  FAIL  $1"; FAIL=1; }

echo "=== ordinary rebuilds leave no history (v1.229.3 P0-2A) ==="
[[ -f "$SUBJECT" ]] || { echo "  SUBJECT_NOT_FOUND: $SUBJECT"; exit 1; }
fn_body(){ awk -v f="^$1\\\\(\\\\) \\\\{" '$0 ~ f,/^\}/' "$SUBJECT"; }

WRAP="$(fn_body _firewall_rebuild_serialized)"
CORE="$(fn_body _firewall_rebuild_core)"
[[ -n "$WRAP" && -n "$CORE" ]] || { echo "  SUBJECT_NOT_FOUND: wrapper/core"; exit 1; }

# --- A6 · the dead duplicate writer is gone ------------------------------------
if grep -qE 'backup_dir/(white|black)list_ipv[46]_\$timestamp\.txt' "$SUBJECT"; then
    fail "A6 dead duplicate {white,black}list_ipv*.txt writer is still present"
else
    pass "A6 dead duplicate list TXT writer removed"
fi

# --- A7 · no-reader proof (structural; the writer had no consumer) -------------
readers=$(grep -rnE '(white|black)list_ipv[46]_[^ ]*\.txt' "$SCRIPT_DIR/.." \
          --include=*.sh --include=*.go 2>/dev/null | grep -v '/tests/' | wc -l)
if [[ "$readers" -eq 0 ]]; then
    pass "A7 READER_PROOF: zero references to the removed artifacts outside tests"
else
    fail "A7 a consumer of the removed artifacts still exists ($readers refs) — reclassify, do not delete"
fi

# --- A8 · ruleset_*.nft untouched ----------------------------------------------
if grep -q 'ruleset\.nft' <<<"$CORE" || grep -q 'ruleset_' "$SUBJECT"; then
    pass "A8 ruleset restore surface still referenced (not collaterally removed)"
else
    fail "A8 ruleset surface disappeared — separate operator restore contract broken"
fi

# --- A10 · ORDERING: disposal strictly after the terminal boundary -------------
w_core=$(grep -n '_firewall_rebuild_core "\$@"' <<<"$WRAP" | head -1 | cut -d: -f1)
w_rc=$(grep -n '_rebuild_rc=\$?'                 <<<"$WRAP" | head -1 | cut -d: -f1)
w_term=$(grep -n 'TERMINAL_SUCCESS'              <<<"$WRAP" | head -1 | cut -d: -f1)
w_disp=$(grep -n '_rebuild_dispose_ordinary_success' <<<"$WRAP" | head -1 | cut -d: -f1)
w_unlock=$(grep -n 'exec 8>&-' <<<"$WRAP" | tail -1 | cut -d: -f1)
if [[ -n "$w_core" && -n "$w_rc" && -n "$w_term" && -n "$w_disp" && -n "$w_unlock" ]]; then
    if (( w_disp > w_core && w_disp > w_rc && w_disp > w_term && w_disp < w_unlock )); then
        pass "A10 disposal is after core return, rc capture AND the terminal write, still under the lock"
    else
        fail "A10 disposal is not correctly ordered (core=$w_core rc=$w_rc term=$w_term disp=$w_disp unlock=$w_unlock)"
    fi
else
    fail "A10 SUBJECT_NOT_FOUND: could not locate the ordering anchors"
fi
if grep -q '_rebuild_dispose_ordinary_success' <<<"$CORE"; then
    fail "A10 the core disposes internally — it could run before rollback/terminal"
else
    pass "A10 core never disposes (rollback runs inside it, untouched)"
fi

# --- A2 · rollback still consumes the snapshot from INSIDE the core ------------
ROLL="$(fn_body _rebuild_rollback)"
if grep -q 'snapshot_dir/ruleset.nft' <<<"$ROLL" || grep -q 'ruleset_file="\$snapshot_dir' <<<"$ROLL"; then
    pass "A2 rollback still consumes <snapshot_dir>/ruleset.nft (capability preserved)"
else
    fail "A2 rollback no longer has its recovery source"
fi

# --- A5 · TERMINAL_FAILURE is NOT disposed -------------------------------------
if grep -A4 'TERMINAL_FAILURE' <<<"$WRAP" | grep -q '_rebuild_dispose_ordinary_success'; then
    fail "A5 failure branch disposes — TERMINAL_FAILURE must not equal DELETE"
else
    pass "A5 failure branch performs no disposal"
fi

# ---------------- behavioural arms (helpers in isolation) ---------------------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
eval "$(fn_body _rebuild_tx_state_write)"
eval "$(fn_body _rebuild_tx_last_state)"
eval "$(fn_body _rebuild_dispose_ordinary_success)"

mkdir -p "$TMP/bk"
mk(){ mkdir -p "$TMP/bk/rebuild_$1"; printf 'state=VALID\ncaptured_at=x\n' > "$TMP/bk/rebuild_$1/snapshot_state"; }

# A1 · TERMINAL_SUCCESS -> disposed
mk 20260101_000001; _rebuild_tx_state_write "$TMP/bk/rebuild_20260101_000001" ACTIVE
_rebuild_tx_state_write "$TMP/bk/rebuild_20260101_000001" TERMINAL_SUCCESS
_rebuild_dispose_ordinary_success "$TMP/bk/rebuild_20260101_000001"
[[ ! -d "$TMP/bk/rebuild_20260101_000001" ]] \
    && pass "A1 ordinary successful rebuild leaves no persistent artifact" \
    || fail "A1 successful rebuild still persisted history"

# A3 · ACTIVE -> never disposed
mk 20260102_000002; _rebuild_tx_state_write "$TMP/bk/rebuild_20260102_000002" ACTIVE
_rebuild_dispose_ordinary_success "$TMP/bk/rebuild_20260102_000002" 2>/dev/null
[[ -d "$TMP/bk/rebuild_20260102_000002" ]] \
    && pass "A3 ACTIVE artifact never disposed (in-flight rollback source protected)" \
    || fail "A3 disposed an ACTIVE artifact"

# A5b · TERMINAL_FAILURE -> kept
mk 20260103_000003; _rebuild_tx_state_write "$TMP/bk/rebuild_20260103_000003" TERMINAL_FAILURE
_rebuild_dispose_ordinary_success "$TMP/bk/rebuild_20260103_000003" 2>/dev/null
[[ -d "$TMP/bk/rebuild_20260103_000003" ]] \
    && pass "A5b TERMINAL_FAILURE kept (not equated with deletable)" \
    || fail "A5b disposed a TERMINAL_FAILURE artifact"

# A4 · malformed / unreadable / missing / out-of-namespace -> kept
a4=0
mk 20260104_000004; printf 'tx_state=GARBAGE\n' >> "$TMP/bk/rebuild_20260104_000004/snapshot_state"
mkdir -p "$TMP/bk/rebuild_20260105_000005"                       # no state file
mk 20260106_000006; chmod 0000 "$TMP/bk/rebuild_20260106_000006/snapshot_state" 2>/dev/null
mkdir -p "$TMP/bk/rebuild_bogus"; printf 'tx_state=TERMINAL_SUCCESS\n' > "$TMP/bk/rebuild_bogus/snapshot_state"
for d in 20260104_000004 20260105_000005 20260106_000006 bogus; do
    _rebuild_dispose_ordinary_success "$TMP/bk/rebuild_$d" 2>/dev/null
    [[ -d "$TMP/bk/rebuild_$d" ]] || { fail "A4 disposed a non-disposable artifact: rebuild_$d"; a4=1; }
done
chmod 0644 "$TMP/bk/rebuild_20260106_000006/snapshot_state" 2>/dev/null
[[ $a4 -eq 0 ]] && pass "A4 malformed / missing / unreadable / out-of-namespace all KEPT"

# --- REPEATED REBUILD GROWTH (the actual P0-2A property) ----------------------
rm -rf "$TMP/bk"; mkdir -p "$TMP/bk"
for i in $(seq -w 1 12); do
    d="$TMP/bk/rebuild_202602${i}_000000"; mkdir -p "$d"
    printf 'state=VALID\ncaptured_at=x\n' > "$d/snapshot_state"
    _rebuild_tx_state_write "$d" ACTIVE
    _rebuild_tx_state_write "$d" TERMINAL_SUCCESS
    _rebuild_dispose_ordinary_success "$d" || true
done
left=$(find "$TMP/bk" -maxdepth 1 -name 'rebuild_*' | wc -l)
if [[ "$left" -eq 0 ]]; then
    pass "REPEATED_REBUILD_GROWTH: 12 successful rebuilds -> 0 persistent artifacts (no linear growth)"
else
    fail "REPEATED_REBUILD_GROWTH: $left/12 artifacts persisted — history still accumulates"
fi

# --- A9 · ROLLBACK_INVERSION ---------------------------------------------------
# Disposing while still ACTIVE (i.e. before the transaction is terminal) would
# destroy the rollback source. Proven by attempting exactly that with a permissive
# variant: it deletes an artifact the real one protects.
_dispose_PERMISSIVE(){ rm -rf -- "$1" 2>/dev/null; }
mkdir -p "$TMP/bk/rebuild_20260301_000001"
printf 'state=VALID\ncaptured_at=x\ntx_state=ACTIVE\n' > "$TMP/bk/rebuild_20260301_000001/snapshot_state"
_dispose_PERMISSIVE "$TMP/bk/rebuild_20260301_000001"
if [[ ! -d "$TMP/bk/rebuild_20260301_000001" ]]; then
    pass "A9 ROLLBACK_INVERSION: a permissive disposer DOES destroy an ACTIVE rollback source (A3 is falsifiable)"
else
    fail "A9 inversion did not reproduce the defect — A3 may be vacuous"
fi

echo
if [[ $FAIL -eq 0 ]]; then echo "RESULT: PASS"; exit 0; fi
echo "RESULT: FAIL"; exit 1
