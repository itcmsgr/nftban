#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.229.3 P1-3 — TRUSTED-FLOW TEMP FILES HAVE AN OWNER AND AN END
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="trusted-flow-tempfile-lifecycle-v1229-3-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-18"
# meta:description="P1-3. The per-event trusted-flow state writer must not leak temp files when a process dies between mktemp and mv, and the belt-and-braces reaper must delete ONLY files this module provably creates. Proves creation ownership and cleanup ownership separately, proves the reaper is actually invoked, and proves the lock and the canonical state file are outside its reach."
# meta:inventory.files="cli/lib/nftban/core/nftban_portscan_trusted_flow.sh"
# meta:inventory.privileges="none"
# meta:ta.id="trusted_flow_tempfile_lifecycle_v1229_3_test"
# meta:ta.owner="portscan"
# meta:ta.module="portscan"
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
#   ⛔ A KNOWN FILENAME PATTERN IS NOT PROOF OF OWNERSHIP.
#      Creation ownership and cleanup ownership are proven separately:
#        CREATION  only _ptf_state_set writes "<state>.XXXXXX"
#        CLEANUP   the reaper matches that exact basename + exactly six characters
#
#   ⛔ REAPER EXISTS != REAPER RUNS. A correct prune nothing invokes is the P1-6
#      defect class, so invocation is asserted behaviourally, not by reading a call.
#
#   ⛔ This module's state dir defaults to the DATA-DIR ROOT, so a broad glob would
#      reach unrelated product state. The narrow pattern is the safety mechanism;
#      the age floor is not.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="$SCRIPT_DIR/../core/nftban_portscan_trusted_flow.sh"
FAIL=0
pass(){ echo "  PASS  $1"; }
fail(){ echo "  FAIL  $1"; FAIL=1; }

echo "=== trusted-flow tempfile lifecycle (v1.229.3 P1-3) ==="
[[ -f "$SUBJECT" ]] || { echo "  SUBJECT_NOT_FOUND: $SUBJECT"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/portscan-trusted-flow.state"

load_module() {
    export NFTBAN_PTF_STATE_FILE="$STATE"
    export NFTBAN_PORTSCAN_TRUSTED_FLOWS_FILE="$TMP/absent.conf"
    export NFTBAN_STATE_DIR="$TMP"
    set +u
    # shellcheck source=/dev/null
    source "$SUBJECT" >/dev/null 2>&1
    set -u
}
load_module

# --- T1 · a successful write leaves no temp behind -----------------------------
_ptf_state_set alpha 1
n=$(find "$TMP" -maxdepth 1 -name 'portscan-trusted-flow.state.??????' | wc -l)
[[ "$n" -eq 0 ]] && pass "T1 successful write leaves zero temp files" \
                 || fail "T1 $n temp file(s) survived a successful write"

# --- T2 · the canonical file is produced and correct ---------------------------
if [[ -f "$STATE" ]] && grep -q '^alpha=1$' "$STATE"; then
    pass "T2 canonical state written (the trap did not eat the renamed file)"
else
    fail "T2 canonical state missing or wrong after write"
fi

# --- T3 · repeated writes do not accumulate ------------------------------------
for i in $(seq 1 25); do _ptf_state_set "k$i" "$i"; done
n=$(find "$TMP" -maxdepth 1 -name 'portscan-trusted-flow.state.??????' | wc -l)
[[ "$n" -eq 0 ]] && pass "T3 25 sequential writes -> 0 temps (no per-event accumulation)" \
                 || fail "T3 $n temp(s) accumulated over 25 writes"

# --- T4 · an aged orphan IS reaped ---------------------------------------------
touch -d '2 hours ago' "$STATE.AB12cd"
_ptf_reap_orphan_temps
[[ -f "$STATE.AB12cd" ]] && fail "T4 aged orphan was not reaped" \
                         || pass "T4 aged orphan reaped"

# --- T5 · a FRESH temp is NOT reaped (a live writer must survive) --------------
: > "$STATE.FRESH1"
_ptf_reap_orphan_temps
[[ -f "$STATE.FRESH1" ]] && pass "T5 fresh temp survives (in-flight writer not destroyed)" \
                         || fail "T5 the reaper destroyed a fresh temp — a live write could be lost"
rm -f "$STATE.FRESH1"

# --- T6 · NAMESPACE: the lock is untouchable -----------------------------------
: > "$STATE.lock"; touch -d '5 hours ago' "$STATE.lock"
_ptf_reap_orphan_temps
[[ -f "$STATE.lock" ]] && pass "T6 .lock survives (4-char suffix cannot match .??????)" \
                       || fail "T6 the reaper deleted the flock file — mutual exclusion destroyed"

# --- T7 · NAMESPACE: the canonical file is untouchable -------------------------
touch -d '9 hours ago' "$STATE"
_ptf_reap_orphan_temps
[[ -f "$STATE" ]] && pass "T7 canonical state survives (no suffix cannot match)" \
                  || fail "T7 the reaper deleted the canonical state file"

# --- T8 · NAMESPACE: a foreign temp in the same dir is untouchable -------------
# The panel modules use the same TEMPLATE SHAPE with a different basename. The
# reaper must be bound to THIS module's basename, not to "anything that looks temp".
touch -d '9 hours ago' "$TMP/enabled.conf.XY99zz" "$TMP/unrelated.state.QQ11ww"
_ptf_reap_orphan_temps
if [[ -f "$TMP/enabled.conf.XY99zz" && -f "$TMP/unrelated.state.QQ11ww" ]]; then
    pass "T8 foreign temps with the same shape but a different basename are untouched"
else
    fail "T8 the reaper reached outside its own namespace — cleanup ownership not bounded"
fi

# --- T9 · REACHABILITY: load() actually invokes the reaper ---------------------
# Behavioural, not a grep: an aged orphan is planted, load() is called, and the
# orphan must be gone. A token search would pass even on a dead call.
touch -d '3 hours ago' "$STATE.RCH001"
nftban_portscan_trusted_flow_load >/dev/null 2>&1
[[ -f "$STATE.RCH001" ]] && fail "T9 load() ran but did NOT invoke the reaper — orphaned prune (P1-6 class)" \
                         || pass "T9 BEHAVIOURAL: load() invokes the reaper (prune is reachable)"

# --- T10 · the reaper is exported alongside its exported caller ----------------
if grep -qE 'export -f .*_ptf_reap_orphan_temps' "$SUBJECT"; then
    pass "T10 reaper exported (its exported caller cannot hit an undefined command)"
else
    fail "T10 reaper not exported while load() is — subshell load() would fail"
fi

# ===================== INVERSIONS =====================
# I1 · a permissive glob DOES destroy the lock -> T6 is falsifiable
: > "$STATE.lock"; touch -d '5 hours ago' "$STATE.lock"
touch -d '5 hours ago' "$STATE.ZZ99yy"
find "$TMP" -maxdepth 1 -type f -name "$(basename "$STATE").*" -mmin +60 -delete 2>/dev/null || true
if [[ ! -f "$STATE.lock" ]]; then
    pass "I1 INVERSION: the naive \"state.*\" glob DOES eat the lock (T6 is falsifiable)"
else
    fail "I1 inversion did not reproduce the hazard — T6 may be vacuous"
fi

# I2 · a writer without the trap DOES leak -> T1 is falsifiable
_leaky_state_set() {
    local tmp; tmp="$(mktemp "${STATE}.XXXXXX")" || return 0
    echo "x=1" > "$tmp"
    return 0     # dies before mv, exactly like a signalled process
}
_leaky_state_set
n=$(find "$TMP" -maxdepth 1 -name 'portscan-trusted-flow.state.??????' | wc -l)
if [[ "$n" -ge 1 ]]; then
    pass "I2 INVERSION: a trap-less writer DOES leak on early return (T1 is falsifiable)"
else
    fail "I2 inversion did not reproduce the leak — T1 may be vacuous"
fi

echo
if [[ $FAIL -eq 0 ]]; then echo "RESULT: PASS"; exit 0; fi
echo "RESULT: FAIL"; exit 1
