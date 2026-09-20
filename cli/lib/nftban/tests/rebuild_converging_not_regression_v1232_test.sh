#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.232.0 a convergence window is not a rebuild regression
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="rebuild_converging_not_regression_v1232_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-20"
# meta:description="v1.232.0 blast-radius guard for the new CONVERGING health status. The post-rebuild safety gate in cmd_firewall.sh rolls back from snapshot when a host was PROTECTED before a rebuild and is neither protected nor idle after it. A rebuild is itself what opens a mode-plan convergence window, so introducing CONVERGING without teaching this gate about it would make a perfectly good rebuild satisfy the regression shape and trigger an AUTOMATIC ROLLBACK. Evaluates the REAL condition text extracted from cmd_firewall.sh (not a copy of it) against the full status matrix: converging/idle/protected must NOT roll back, degraded/down and an explicit REGRESSION/FATAL disposition MUST still roll back. Carries the discriminating negative control: the pre-v1.232.0 condition, with the converging clause removed, DOES fire on a converging post state — proving the arm detects the hazard rather than merely passing."
# meta:input="None (self-contained; reads the condition out of the shipped source)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,awk,sed"
# meta:inventory.files=""
# meta:inventory.binaries="bash,awk,sed"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="rebuild_converging_not_regression_v1232_test"
# meta:ta.owner="firewall"
# meta:ta.module="rebuild-rollback-gate"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
FW_SRC="$REPO_ROOT/cli/lib/nftban/cli/cmd_firewall.sh"

PASS=0
FAIL=0
FAILED_TESTS=()
ok()  { printf "  [PASS] %s\n" "$1"; PASS=$((PASS + 1)); }
bad() { printf "  [FAIL] %s\n         %s\n" "$1" "${2:-}"; FAIL=$((FAIL + 1)); FAILED_TESTS+=("$1"); }

[[ -r "$FW_SRC" ]] || { echo "NOT_EXECUTED: missing $FW_SRC" >&2; exit 2; }

# Extract the SHIPPED condition so this test can never drift from the source:
# the two-line `if ... \ || ...; then` is rejoined, and the `if`/`; then`
# scaffolding is stripped, leaving a bare boolean expression to evaluate.
COND=$(awk '
    /if \[\[ "\$_disposition" == "REGRESSION"/ { grab=1 }
    grab { buf = buf $0 "\n" }
    grab && /; then$/ { print buf; exit }
' "$FW_SRC" | sed -e 's/\\$//' -e 's/^[[:space:]]*if //' -e 's/;[[:space:]]*then$//' | tr '\n' ' ')

if [[ -z "${COND// /}" ]]; then
    echo "NOT_EXECUTED: could not extract the post-rebuild regression condition from $FW_SRC" >&2
    exit 2
fi

# The pre-v1.232.0 form of the same condition: identical but without the
# converging clause. This is the immutable negative control — it does not
# invert when the fix merges, because it is reconstructed here, not read from
# a branch that moves.
COND_PRE=$(printf '%s' "$COND" | sed 's/ && "\$post_status" != "converging"//')

# Evaluate a condition with a given (disposition, pre, post) triple.
# rc 0 = the gate FIRES (rollback), rc 1 = it does not.
eval_cond() {
    # shellcheck disable=SC2034  # _disposition/pre_status/post_status are
    # consumed by the evaluated condition text, not by this function body.
    local cond="$1" _disposition="$2" pre_status="$3" post_status="$4"
    local rc=0
    eval "if $cond; then rc=0; else rc=1; fi" || rc=1
    return "$rc"
}

echo ""
echo "=== A. a convergence window must not trigger rollback ==="

rc=0; eval_cond "$COND" "CONTINUE" "protected" "converging" || rc=$?
if [[ "$rc" == "1" ]]; then ok "A1 protected -> converging does NOT roll back"; else
    bad "A1 protected -> converging does NOT roll back" "the gate fired: a healthy rebuild would be rolled back from snapshot"; fi

rc=0; eval_cond "$COND" "CONTINUE" "protected" "idle" || rc=$?
if [[ "$rc" == "1" ]]; then ok "A2 protected -> idle still does not roll back (unchanged)"; else
    bad "A2 protected -> idle still does not roll back (unchanged)" "pre-existing behaviour regressed"; fi

rc=0; eval_cond "$COND" "CONTINUE" "protected" "protected" || rc=$?
if [[ "$rc" == "1" ]]; then ok "A3 protected -> protected does not roll back"; else
    bad "A3 protected -> protected does not roll back" "the gate fired on an unchanged healthy state"; fi

echo ""
echo "=== B. the gate must still catch real regressions ==="

rc=0; eval_cond "$COND" "CONTINUE" "protected" "degraded" || rc=$?
if [[ "$rc" == "0" ]]; then ok "B1 protected -> degraded still rolls back"; else
    bad "B1 protected -> degraded still rolls back" "the safety gate was weakened"; fi

rc=0; eval_cond "$COND" "CONTINUE" "protected" "down" || rc=$?
if [[ "$rc" == "0" ]]; then ok "B2 protected -> down still rolls back"; else
    bad "B2 protected -> down still rolls back" "the safety gate was weakened"; fi

rc=0; eval_cond "$COND" "REGRESSION" "protected" "converging" || rc=$?
if [[ "$rc" == "0" ]]; then ok "B3 an explicit REGRESSION disposition still rolls back even when converging"; else
    bad "B3 an explicit REGRESSION disposition still rolls back even when converging" "the verdict authority was overridden by the shape guard"; fi

rc=0; eval_cond "$COND" "FATAL" "protected" "converging" || rc=$?
if [[ "$rc" == "0" ]]; then ok "B4 an explicit FATAL disposition still rolls back even when converging"; else
    bad "B4 an explicit FATAL disposition still rolls back even when converging" "the verdict authority was overridden by the shape guard"; fi

echo ""
echo "=== C. NEGATIVE CONTROL: the pre-v1.232.0 condition ==="
# Power check. If the converging clause were absent, the gate WOULD fire on a
# converging post state. This arm proves A1 is discriminating and not vacuous.

if [[ "$COND_PRE" == "$COND" ]]; then
    bad "C0 control condition differs from the shipped condition" \
        "the converging clause was not found in the shipped text, so C1 cannot discriminate"
else
    ok "C0 control condition is the shipped condition minus the converging clause"
fi

rc=0; eval_cond "$COND_PRE" "CONTINUE" "protected" "converging" || rc=$?
if [[ "$rc" == "0" ]]; then ok "C1 CONTROL: without the converging clause the gate DOES fire (hazard is real)"; else
    bad "C1 CONTROL: without the converging clause the gate DOES fire (hazard is real)" \
        "the control did not reproduce the hazard, so A1 proves nothing"; fi

rc=0; eval_cond "$COND_PRE" "CONTINUE" "protected" "degraded" || rc=$?
if [[ "$rc" == "0" ]]; then ok "C2 CONTROL: the pre-fix condition still caught real regressions"; else
    bad "C2 CONTROL: the pre-fix condition still caught real regressions" "control is malformed"; fi

echo ""
echo "============================================================"
printf "Passed: %d  Failed: %d\n" "$PASS" "$FAIL"
if (( FAIL > 0 )); then
    printf "Failed tests:\n"
    for t in "${FAILED_TESTS[@]}"; do printf "  - %s\n" "$t"; done
    exit 1
fi
exit 0
