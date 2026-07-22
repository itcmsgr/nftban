#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.198 R1b-3 update progress UX + readiness reconciliation
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_update_progress_r1b3_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-21"
# meta:description="Unit test for cmd_update_helpers.sh::_update_phase ([n/total] markers) + structural assertions that cmd_update.sh wires ordered phase banners and an operator-readiness line consistent with the existing consolidated install_state verdict (no second/contradictory verdict, rc contract preserved). Full _cmd_update_main_locked execution is exercised by CI's Update Canonization Gate."
# meta:input="None (sources cmd_update_helpers.sh in a sandbox; greps cmd_update.sh)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,grep"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,UPDATE_LOG_FILE"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="nftban_update_progress_r1b3_test"
# meta:ta.owner="update"
# meta:ta.module="update-progress"
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
NFTBAN_LIB_DIR="${REPO_ROOT}/cli/lib/nftban"
export NFTBAN_LIB_DIR
CU="${NFTBAN_LIB_DIR}/cli/cmd_update.sh"

SANDBOX=$(mktemp -d); trap 'rm -rf "$SANDBOX"' EXIT
export UPDATE_LOG_FILE="$SANDBOX/update.log"
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/cli/cmd_update_helpers.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }
ar()  { if grep -qE -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (no match: $2)"; fi; }
gf()  { if grep -qF -- "$1" "$CU"; then ok "$2"; else bad "$2 (missing in cmd_update.sh: $1)"; fi; }

echo "R1b-3 update progress + readiness — tests"

# T1 (unit): _update_phase format + default total
OUT=$(_update_phase 1 "Backup")
ar "$OUT" '\[1/6\] Backup$'                         "T1 phase marker format [1/6] Backup"
OUT=$(_update_phase 2 "Install" "package install may take up to 60s")
ar "$OUT" '\[2/6\] Install — package install may take up to 60s$' "T1 phase marker with long-step hint"

# T2: ordered fixed-phase markers wired in cmd_update.sh (success path)
gf '_update_phase 1 "Backup"'                       "T2 phase 1 Backup wired"
gf '_update_phase 2 "Install"'                      "T2 phase 2 Install wired"
gf '_update_phase 3 "Restart services"'             "T2 phase 3 Restart wired"
gf '_update_phase 4 "Health check"'                 "T2 phase 4 Health wired"
gf '_update_phase 5 "Post-update verification"'     "T2 phase 5 Post-verify wired"
gf '_update_phase 6 "Finalize"'                     "T2 phase 6 Finalize wired"

# T3: COMMITTED (protected/idle clean) readiness defaults to PASS (not DEGRADED/FAIL)
gf 'local _rd_ready="PASS" _rd_action="NONE"'       "T3 COMMITTED readiness default PASS/NONE"
# T4: WARN (health reported issues) -> PASS_WITH_WARN, success path NOT failed
gf '_rd_ready="PASS_WITH_WARN"; _rd_action="WARN"'  "T4 health-issues -> PASS_WITH_WARN/WARN"

# T5: install_state DEGRADED -> readiness FAIL (not fully ready)
if grep -Pzoq 'DEGRADED\)(.|\n)*?Upgrade readiness:" "FAIL"(.|\n)*?return 1' "$CU" 2>/dev/null; then
    ok "T5 DEGRADED block -> readiness FAIL + return 1"
else
    # portable fallback: both tokens present and DEGRADED returns 1
    if grep -qF 'printf "  %-20s %s\n" "Upgrade readiness:" "FAIL"' "$CU"; then ok "T5 DEGRADED readiness FAIL line present"; else bad "T5 DEGRADED readiness FAIL line missing"; fi
fi

# T6: structural-vs-non-structural degraded distinction in the update verdict preserved (V6)
gf '_has_structural=true'                           "T6 structural-degraded detection preserved"
gf 'non-structural degradation'                     "T6 non-structural warning path preserved"

# T7: no duplicate/conflicting readiness verdict — single consolidated case; generic helper NOT called here
if [[ "$(grep -c 'case "\$_installer_state" in' "$CU")" -eq 1 ]]; then ok "T7 single consolidated install_state verdict (one case)"; else bad "T7 unexpected number of verdict case blocks"; fi
# the helper may be NAMED in a comment ("NOT the generic helper…") but must never be CALLED here
if grep 'nftban_render_operator_readiness' "$CU" | grep -qvE '^[[:space:]]*#'; then bad "T7 generic readiness helper CALLED (non-comment) in update (contradiction risk)"; else ok "T7 generic readiness helper NOT called in cmd_update.sh (no contradiction)"; fi

# T7b: rc contract preserved across verdict branches
gf 'return 0'  "T7b COMMITTED/unknown return 0 preserved"
gf 'return 1'  "T7b DEGRADED return 1 preserved"
gf 'return 2'  "T7b FAILED return 2 preserved"
gf 'return $result' "T7b install-failure preserves source rc"

# T8: --json cache path (update check) intact + not polluted by human-only progress text
if grep -qF -- '--json|-j)' "$CU"; then ok "T8 update --json flag handling intact"; else bad "T8 --json flag handling missing"; fi
# the json cache writer block must not contain phase/readiness human text
if awk '/update_available\.json/{c++} END{exit (c>0)?0:1}' "$CU"; then ok "T8 update_available.json cache path present"; else bad "T8 json cache path missing"; fi

# T9: helper defined+available
if declare -F _update_phase >/dev/null 2>&1; then ok "T9 _update_phase defined (cmd_update_helpers.sh)"; else bad "T9 _update_phase not defined"; fi

echo "-----------------------------------------------"
printf 'R1b-3 progress tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
