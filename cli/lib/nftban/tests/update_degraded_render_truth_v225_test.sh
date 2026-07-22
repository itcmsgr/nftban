#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.225.0 PR-A: update DEGRADED render truth (E1a + E1b)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="update_degraded_render_truth_v225_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-22"
# meta:description="Regression guard for v1.225.0 PR-A. E1a (BUG-V1_222_1-UPDATE-STATEFILE-GREP-UNGUARDED): _render_degraded_failed_units must NOT abort under set -Eeuo pipefail when SERVICES_FAILED is ABSENT from a readable DEGRADED install_state (grep rc=1 = key absent, not a read error), and must not fabricate success on a missing/unreadable file. E1b (BUG-V1_222_1-UPDATE-DEGRADED-ALL-UNITS-FILTERED-NO-HINT): a non-empty raw SERVICES_FAILED whose tokens are all non-canonical must still print a truthful 'recorded-but-all-filtered' hint distinct from the 'no list recorded' fallback; canonical units render; no false-health claims. Hermetic: sources cmd_update.sh, drives the helper with temp fixtures, no root/systemd/network/real state."
# meta:inventory.files="cli/lib/nftban/cli/cmd_update.sh"
# meta:inventory.binaries="bash,grep,cut"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="update_degraded_render_truth_v225_test"
# meta:ta.owner="update"
# meta:ta.module="update"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="policy-gates"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
CMD_UPDATE="$REPO_ROOT/cli/lib/nftban/cli/cmd_update.sh"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

echo "v1.225.0 PR-A update DEGRADED render truth (E1a+E1b):"

# Source only the function (definitions only; the file auto-runs nothing when sourced).
# shellcheck disable=SC1090
if ! source "$CMD_UPDATE" 2>/dev/null; then :; fi
if ! declare -F _render_degraded_failed_units >/dev/null; then
    no "_render_degraded_failed_units is defined after sourcing cmd_update.sh" "not found"
    echo "RESULT: $PASS passed, $FAIL failed"; exit 1
fi
ok "_render_degraded_failed_units defined after sourcing cmd_update.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# render <state-body...>  → writes fixture, runs helper under strict mode, captures out/rc/err
run_render() {
    local body=$1 sf="$TMP/state"
    printf '%s' "$body" > "$sf"
    local out rc err
    err="$TMP/err"
    set +e
    out=$( set -Eeuo pipefail; _render_degraded_failed_units "$sf" 2>"$err" ); rc=$?
    set -e
    LAST_OUT="$out"; LAST_RC=$rc; LAST_ERR="$(cat "$err")"
}
no_false_health() { # assert output makes no false-health / recovery claim
    if echo "$LAST_OUT" | grep -qiE "no failed units|all services healthy|state recovered|recovered\b|healthy"; then
        no "$1 makes no false-health claim" "found health claim"
    else ok "$1 makes no false-health claim"; fi
}

# ---- E1a: strict-mode abort must be prevented ----
# A. key present, canonical value
run_render $'INSTALL_STATE=DEGRADED\nSERVICES_FAILED=nftban-botscan.service\n'
{ [[ $LAST_RC -eq 0 ]] && echo "$LAST_OUT" | grep -q "Failed unit: nftban-botscan.service"; } \
  && ok "E1a-A present canonical → rc0 + unit rendered" || no "E1a-A present canonical" "rc=$LAST_RC"

# B. key present, empty value
run_render $'INSTALL_STATE=DEGRADED\nSERVICES_FAILED=\n'
{ [[ $LAST_RC -eq 0 ]] && echo "$LAST_OUT" | grep -q "structured failed-unit list unavailable"; } \
  && ok "E1a-B present-empty → rc0 + no-list fallback" || no "E1a-B present-empty" "rc=$LAST_RC out=[$LAST_OUT]"

# C. key ABSENT (the strict-mode abort bug) — must NOT abort
# (missing/unreadable-file cases are UNREACHABLE in this renderer — INSTALL_STATE defaults to
#  COMMITTED upstream on any unreadable/missing file — so they are intentionally NOT tested here.)
run_render $'INSTALL_STATE=DEGRADED\nFAILURE_REASON=resource policy\n'
{ [[ $LAST_RC -eq 0 ]] && echo "$LAST_OUT" | grep -q "structured failed-unit list unavailable"; } \
  && ok "E1a-C absent-key → NO strict-mode abort (rc0) + fallback" || no "E1a-C absent-key strict abort" "rc=$LAST_RC"

# absent key must never invent a Failed-unit line
run_render $'INSTALL_STATE=DEGRADED\nFAILURE_REASON=resource policy\n'
echo "$LAST_OUT" | grep -q "Failed unit:" && no "E1a absent-key never invents a unit line" "invented unit" \
  || ok "E1a absent-key never invents a Failed-unit line"

# stderr clean on the benign absent-key path
run_render $'INSTALL_STATE=DEGRADED\n'
[[ -z "$LAST_ERR" ]] && ok "E1a absent-key emits no stderr noise" || no "E1a stderr clean" "err=[$LAST_ERR]"

# ---- E1b: filtered-units hint ----
# canonical single
run_render $'SERVICES_FAILED=nftban-health.service\n'
echo "$LAST_OUT" | grep -q "Failed unit: nftban-health.service" \
  && ok "E1b canonical single rendered" || no "E1b canonical single"

# canonical multiple
run_render $'SERVICES_FAILED=nftban-health.service,nftban-maintenance.timer\n'
{ echo "$LAST_OUT" | grep -q "nftban-health.service" && echo "$LAST_OUT" | grep -q "nftban-maintenance.timer"; } \
  && ok "E1b multiple canonical rendered" || no "E1b multiple canonical"

# mixed canonical / non-canonical → only canonical rendered, no filtered-hint (>=1 rendered)
run_render $'SERVICES_FAILED=nftban-health.service,evil;rm -rf,notaunit\n'
{ echo "$LAST_OUT" | grep -q "Failed unit: nftban-health.service" \
  && ! echo "$LAST_OUT" | grep -q "evil" \
  && ! echo "$LAST_OUT" | grep -q "remained after filtering"; } \
  && ok "E1b mixed → only canonical rendered, no filtered-hint" || no "E1b mixed"

# ALL non-canonical → the E1b truthful 'recorded-but-all-filtered' hint (distinct from no-list)
run_render $'INSTALL_STATE=DEGRADED\nSERVICES_FAILED=sshd.service,foo.bar,notaunit\n'
{ [[ $LAST_RC -eq 0 ]] && echo "$LAST_OUT" | grep -q "remained after filtering" \
  && ! echo "$LAST_OUT" | grep -q "Failed unit:"; } \
  && ok "E1b all-filtered → truthful 'recorded but all filtered' hint" || no "E1b all-filtered hint" "out=[$LAST_OUT]"
no_false_health "E1b all-filtered"

# the all-filtered hint is DISTINCT from the no-list fallback
run_render $'SERVICES_FAILED=onlyjunk\n'; ALLFILT="$LAST_OUT"
run_render $'SERVICES_FAILED=\n'; NOLIST="$LAST_OUT"
[[ "$ALLFILT" != "$NOLIST" ]] && ok "E1b all-filtered hint distinct from no-list fallback" || no "E1b hint distinctness"

# whitespace-only field → deterministic (non-empty → all-filtered hint), rc0
run_render $'SERVICES_FAILED=   \n'
[[ $LAST_RC -eq 0 ]] && ok "E1b whitespace-only field → deterministic rc0" || no "E1b whitespace-only" "rc=$LAST_RC"

echo "RESULT: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
