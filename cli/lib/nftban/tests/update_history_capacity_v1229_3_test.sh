#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.229.3 P0-2B + P0-3 — BOUNDED UPDATE HISTORY + PATH-LOCAL CAPACITY
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="update-history-capacity-v1229-3-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-16"
# meta:description="Proves the update lifecycle retains between one and two completed recovery generations while ordinary rebuilds retain none, and that the path-local capacity authority evaluates each NFTBan root against the filesystem actually backing it, in both bytes and entries/inodes, sharing one envelope when two roots are on the same device. Capacity may degrade two generations to the mandatory floor but never below it, and an unobservable filesystem yields UNKNOWN rather than permission to act."
# meta:inventory.files="cli/lib/nftban/cli/cmd_firewall.sh,cli/lib/nftban/core/nftban_backup_capacity.sh"
# meta:inventory.privileges="none"
# meta:ta.id="update_history_capacity_v1229_3_test"
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
#   POLICY_MAX_HISTORY is LIFECYCLE POLICY, not a capacity-derived number.
#   Capacity may only answer "can 1..2 safely fit?" -- free space never
#   authorizes MORE history, and pressure never removes the mandatory floor.
#
#   MEAN_SET_SIZE != SAFE RETENTION BOUND   (26x fleet spread)
#   UNKNOWN       != FITS
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FW="$SCRIPT_DIR/../cli/cmd_firewall.sh"
CAP="$SCRIPT_DIR/../core/nftban_backup_capacity.sh"
FAIL=0
pass(){ echo "  PASS  $1"; }
fail(){ echo "  FAIL  $1"; FAIL=1; }

echo "=== update history + path-local capacity (v1.229.3 P0-2B/P0-3) ==="
for f in "$FW" "$CAP"; do [[ -f "$f" ]] || { echo "  SUBJECT_NOT_FOUND: $f"; exit 1; }; done
fn_body(){ awk -v f="^$1\\\\(\\\\) \\\\{" '$0 ~ f,/^\}/' "$2"; }

# shellcheck source=/dev/null
source "$CAP"
eval "$(fn_body _rebuild_tx_state_write "$FW")"
eval "$(fn_body _rebuild_tx_last_state "$FW")"
eval "$(fn_body _rebuild_is_update_lifecycle "$FW")"
eval "$(fn_body _rebuild_update_history_prune "$FW")"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export NFTBAN_DATA_DIR="$TMP/lib" NFTBAN_LOG_DIR="$TMP/log"
mkdir -p "$NFTBAN_DATA_DIR/backup" "$NFTBAN_LOG_DIR"
BK="$NFTBAN_DATA_DIR/backup"
mkhist(){ mkdir -p "$BK/rebuild_$1"; printf 'state=VALID\ncaptured_at=x\n' > "$BK/rebuild_$1/snapshot_state"; _rebuild_tx_state_write "$BK/rebuild_$1" TERMINAL_SUCCESS; }
reset(){ rm -rf "$BK"; mkdir -p "$BK"; }

# --- C1 · context is PASSED, never inferred -----------------------------------
_rebuild_is_update_lifecycle --install-context && pass "C1 --install-context recognised as update lifecycle" \
    || fail "C1 update lifecycle not recognised"
_rebuild_is_update_lifecycle --quiet 2>/dev/null && fail "C1 ordinary rebuild misread as update lifecycle" \
    || pass "C1 ordinary rebuild is NOT update lifecycle"
if grep -q 'systemctl is-active' <<<"$(fn_body _rebuild_is_update_lifecycle "$FW")"; then
    fail "C1 lifecycle is INFERRED from runtime state instead of passed"
else
    pass "C1 lifecycle is passed, never inferred"
fi

# --- C2 · MAX 2 completed generations -----------------------------------------
reset; for t in 20260101_000001 20260102_000002 20260103_000003 20260104_000004 20260105_000005; do mkhist "$t"; done
_rebuild_update_history_prune 2>/dev/null
n=$(find "$BK" -maxdepth 1 -name 'rebuild_*' | wc -l)
surv=$(find "$BK" -maxdepth 1 -name 'rebuild_*' -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')
if [[ "$n" -le 2 && "$surv" == *20260105_000005* ]]; then
    pass "C2 update history bounded to <=2, newest retained ($surv)"
else
    fail "C2 wrong history bound: n=$n surv=$surv"
fi

# --- C3 · MIN 1 mandatory floor never removed ---------------------------------
reset; mkhist 20260101_000001
_rebuild_update_history_prune 2>/dev/null
[[ -d "$BK/rebuild_20260101_000001" ]] \
    && pass "C3 single generation is the mandatory floor and is never removed" \
    || fail "C3 removed the mandatory recovery floor"

# --- C4 · ordering authority is the NAME, not mtime ---------------------------
reset; for t in 20260101_000001 20260102_000002 20260103_000003; do mkhist "$t"; done
touch -d '2020-01-01' "$BK/rebuild_20260103_000003"
_rebuild_update_history_prune 2>/dev/null
[[ -d "$BK/rebuild_20260103_000003" ]] \
    && pass "C4 name order governs; a touched mtime cannot evict the newest generation" \
    || fail "C4 mtime perturbation evicted the newest generation"

# --- C5 · non-TERMINAL_SUCCESS is never treated as history --------------------
reset; mkhist 20260101_000001; mkhist 20260102_000002; mkhist 20260103_000003
mkdir -p "$BK/rebuild_20260104_000004"; printf 'state=VALID\ntx_state=ACTIVE\n' > "$BK/rebuild_20260104_000004/snapshot_state"
mkdir -p "$BK/rebuild_20260105_000005"; printf 'state=VALID\ntx_state=TERMINAL_FAILURE\n' > "$BK/rebuild_20260105_000005/snapshot_state"
_rebuild_update_history_prune 2>/dev/null
c5=0
for keep in 20260104_000004 20260105_000005; do
    [[ -d "$BK/rebuild_$keep" ]] || { fail "C5 pruned a non-history object: rebuild_$keep"; c5=1; }
done
[[ $c5 -eq 0 ]] && pass "C5 ACTIVE and TERMINAL_FAILURE are not update history and are untouched"

# --- C6 · PATH INDEPENDENCE: each root against its OWN backing filesystem ------
_bcap_fs_facts "$NFTBAN_DATA_DIR" >/dev/null && pass "C6 fs facts observed for /var/lib root" || fail "C6 could not observe lib root"
_bcap_fs_facts "$NFTBAN_LOG_DIR"  >/dev/null && pass "C6 fs facts observed for /var/log root" || fail "C6 could not observe log root"
if grep -qE 'stat -c %d' "$CAP"; then
    pass "C6 device identity (stat %d) is the backing-filesystem authority, not a path prefix"
else
    fail "C6 backing filesystem is decided by path prefix — a separate /var/lib volume would be misread"
fi

# --- C7 · SHARED-DEVICE envelope ----------------------------------------------
if _bcap_same_device "$NFTBAN_DATA_DIR" "$NFTBAN_LOG_DIR"; then
    pass "C7 same-device correctly detected for two roots on one filesystem"
else
    fail "C7 same-device detection failed for two roots that share a device"
fi
if ! _bcap_same_device "$NFTBAN_DATA_DIR" "/proc"; then
    pass "C7 different-device correctly distinguished (independent envelopes)"
else
    fail "C7 two roots on different filesystems reported as same device"
fi

# --- C8 · TWO DIMENSIONS: entries bind even when bytes are green ---------------
v_bytes=$(_bcap_verdict "$NFTBAN_DATA_DIR" 1 1)
v_ent=$(_bcap_verdict "$NFTBAN_DATA_DIR" 1 999999999999)
if [[ "$v_bytes" == "FITS" && "$v_ent" == "NO_FIT" ]]; then
    pass "C8 entry/inode dimension binds independently of bytes (byte-only model rejected)"
else
    fail "C8 entry dimension does not bind (bytes=$v_bytes entries=$v_ent)"
fi
v_big=$(_bcap_verdict "$NFTBAN_DATA_DIR" 999999999999999 1)
[[ "$v_big" == "NO_FIT" ]] && pass "C8 byte dimension binds" || fail "C8 byte dimension inert ($v_big)"

# --- C9 · UNKNOWN != FITS ------------------------------------------------------
v_unk=$(_bcap_verdict "$TMP/definitely-absent" 1 1)
[[ "$v_unk" == "UNKNOWN" ]] && pass "C9 unobservable path -> UNKNOWN (never FITS)" || fail "C9 got $v_unk"
v_bad=$(_bcap_verdict "$NFTBAN_DATA_DIR" "not-a-number" 1)
[[ "$v_bad" == "UNKNOWN" ]] && pass "C9 malformed need -> UNKNOWN" || fail "C9 malformed need gave $v_bad"

# --- C10 · NO MEAN-SIZE FORECASTING -------------------------------------------
# Bind to CODE, not prose: this file mentions "mean" only to state that mean-size
# forecasting is rejected. A comment-blind grep would flag its own rationale.
CAP_CODE="$(grep -vE '^\s*#' "$CAP")"
if grep -qiE 'mean|average|avg_|forecast' <<<"$CAP_CODE"; then
    fail "C10 capacity CODE contains mean/average forecasting"
else
    pass "C10 no mean-size forecasting in code (actual object cost only)"
fi
if grep -qiE 'mean' "$CAP"; then
    pass "C10 falsifiability: the file does discuss 'mean', so the guard is code-scoped by design"
fi
mkdir -p "$TMP/obj"; head -c 4096 /dev/zero > "$TMP/obj/f1" 2>/dev/null
cost=$(_bcap_object_cost "$TMP/obj") && pass "C10 actual object cost measured ($cost)" || fail "C10 object cost unmeasurable"

# --- C11 · capacity may degrade 2 -> 1 but NEVER below the floor --------------
if grep -q '_keep=1' <<<"$(fn_body _rebuild_update_history_prune "$FW")" \
   && grep -qE 'NO_FIT\)\s+_keep=1' <<<"$(fn_body _rebuild_update_history_prune "$FW")"; then
    pass "C11 NO_FIT degrades to the floor (1), never to 0"
else
    fail "C11 capacity pressure path does not clamp to the mandatory floor"
fi
if grep -qE '_keep=0' <<<"$(fn_body _rebuild_update_history_prune "$FW")"; then
    fail "C11 a code path can reduce retention to zero"
else
    pass "C11 no code path reduces retention below the floor"
fi

# --- C13 · WRAPPER ROUTING: update -> retain, ordinary -> dispose ---------------
# Without this the helpers can be perfectly correct while the wrapper never calls
# the retention path at all (proven necessary: disabling the branch left every
# other arm green).
WRAP="$(fn_body _firewall_rebuild_serialized "$FW")"
[[ -n "$WRAP" ]] || fail "C13 SUBJECT_NOT_FOUND: serialization wrapper"
if grep -q '_rebuild_is_update_lifecycle "\$@"' <<<"$WRAP"; then
    pass "C13 wrapper branches on the PASSED lifecycle context"
else
    fail "C13 wrapper does not branch on _rebuild_is_update_lifecycle — update rebuilds would be disposed"
fi
w_if=$(grep -n '_rebuild_is_update_lifecycle' <<<"$WRAP" | head -1 | cut -d: -f1)
w_ret=$(grep -n '_rebuild_update_history_prune' <<<"$WRAP" | head -1 | cut -d: -f1)
w_dis=$(grep -n '_rebuild_dispose_ordinary_success' <<<"$WRAP" | head -1 | cut -d: -f1)
# NOTE: do not anchor on the LAST `else` -- the wrapper's outer rc!=0 branch owns
# that one. The routing property is simply: the lifecycle test comes first, the
# retention call sits in its true branch, and disposal follows in the false branch.
if [[ -n "$w_if" && -n "$w_ret" && -n "$w_dis" ]] && (( w_if < w_ret && w_ret < w_dis )); then
    pass "C13 retention precedes disposal inside the lifecycle branch (update retains, ordinary disposes)"
else
    fail "C13 routing is wrong (if=$w_if retain=$w_ret dispose=$w_dis)"
fi

# --- C12 · INVERSION: a floor-less prune destroys the last generation ----------
reset; mkhist 20260101_000001
_prune_NOFLOOR(){ rm -rf -- "$BK"/rebuild_* 2>/dev/null; }
_prune_NOFLOOR
if [[ ! -d "$BK/rebuild_20260101_000001" ]]; then
    pass "C12 INVERSION: a floor-less prune DOES destroy the last generation (C3 is falsifiable)"
else
    fail "C12 inversion did not reproduce the defect — C3 may be vacuous"
fi

echo
if [[ $FAIL -eq 0 ]]; then echo "RESULT: PASS"; exit 0; fi
echo "RESULT: FAIL"; exit 1
