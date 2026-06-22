#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.198 R1b-2 operator-readiness summary
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_operator_readiness_r1b2_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-21"
# meta:description="Hermetic tests for core/nftban_output.sh::nftban_render_operator_readiness (R1b-2): shell-side Operational/Upgrade-readiness/Action-needed verdict + IDLE explanation, computed from canned validator JSON + mocked install_state/rc. Plus guards that cmd_health.sh wires it text-only (--json unaffected) and cmd_status.sh semantic findings usage is untouched."
# meta:input="None (canned validator JSON, self-contained)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,jq,grep"
# meta:inventory.files=""
# meta:inventory.binaries="bash,jq"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
NFTBAN_LIB_DIR="${REPO_ROOT}/cli/lib/nftban"
export NFTBAN_LIB_DIR
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }
# regex matcher (whitespace-tolerant for padded summary lines)
ar()  { if grep -qE -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (no match: $2)"; fi; }
nr()  { if grep -qE -- "$2" <<<"$1"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi; }
# fixed-string matcher (for literal finding lines)
af()  { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi; }
nf()  { if grep -qF -- "$2" <<<"$1"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi; }

echo "R1b-2 operator-readiness summary — hermetic tests"

# T1: protected + info-only -> YES / PASS / NONE, no findings block
OUT=$(nftban_render_operator_readiness '{"status":"protected","findings":[{"severity":"info","code":"X","message":"benign"}]}' "" 0)
ar "$OUT" "Operational:[[:space:]]+YES$"            "T1 protected -> Operational YES"
ar "$OUT" "Upgrade readiness:[[:space:]]+PASS$"     "T1 protected -> readiness PASS"
ar "$OUT" "Action needed:[[:space:]]+NONE$"         "T1 protected -> action NONE"
nf "$OUT" "Findings"                                "T1 no actionable findings block when NONE"

# T2: idle + clean -> YES + IDLE explanation / PASS
OUT=$(nftban_render_operator_readiness '{"status":"idle","findings":[]}' "" 0)
af "$OUT" "YES (running, no active bans currently)" "T2 idle -> IDLE explanation"
ar "$OUT" "Upgrade readiness:[[:space:]]+PASS$"     "T2 idle -> readiness PASS"

# T3: idle + WARN -> YES / PASS_WITH_WARN / WARN. v1.198.2 PR-C: the readiness
# block is the VERDICT surface only — it no longer re-renders the per-finding
# detail (that duplicated the canonical "Findings:" section in cmd_health); it
# emits a one-line pointer instead.
OUT=$(nftban_render_operator_readiness '{"status":"idle","findings":[{"severity":"warn","code":"VAL-LOGINMON-002","message":"webauth present but starved"}]}' "" 0)
ar "$OUT" "Upgrade readiness:[[:space:]]+PASS_WITH_WARN$" "T3 WARN -> readiness PASS_WITH_WARN"
ar "$OUT" "Action needed:[[:space:]]+WARN$"         "T3 WARN -> action WARN"
nf "$OUT" "[WARN] VAL-LOGINMON-002:"                "T3 PR-C: finding detail NOT re-rendered in readiness block (verdict-only)"
ar "$OUT" "see the Findings section below"          "T3 PR-C: readiness points to the Findings section instead of duplicating"

# T4a: degraded status -> FAIL
OUT=$(nftban_render_operator_readiness '{"status":"degraded","findings":[{"severity":"warn","code":"VAL-TIMER-001","message":"x"}]}' "" 0)
ar "$OUT" "Upgrade readiness:[[:space:]]+FAIL$"     "T4a degraded -> readiness FAIL"
ar "$OUT" "Action needed:[[:space:]]+FAIL$"         "T4a degraded -> action FAIL"

# T4b: error-severity finding (status protected) -> FAIL. v1.198.2 PR-C: detail
# rendered once in the canonical Findings section, not duplicated here.
OUT=$(nftban_render_operator_readiness '{"status":"protected","findings":[{"severity":"error","code":"VAL-CHAIN-001","message":"chain missing"}]}' "" 0)
ar "$OUT" "Upgrade readiness:[[:space:]]+FAIL$"     "T4b error finding -> readiness FAIL"
nf "$OUT" "[ERROR] VAL-CHAIN-001:"                  "T4b PR-C: error finding detail NOT re-rendered in readiness block"

# T5: install_state DEGRADED (update path) -> NOT PASS even when protected+clean
OUT=$(nftban_render_operator_readiness '{"status":"protected","findings":[]}' "DEGRADED" 0)
nr "$OUT" "Upgrade readiness:[[:space:]]+PASS"      "T5 install_state DEGRADED -> readiness not PASS/PASS_WITH_WARN"
ar "$OUT" "Upgrade readiness:[[:space:]]+FAIL$"     "T5 install_state DEGRADED -> readiness FAIL"

# T5b: down status -> Operational NO / FAIL
OUT=$(nftban_render_operator_readiness '{"status":"down","findings":[]}' "" 2)
ar "$OUT" "Operational:[[:space:]]+NO$"             "T5b down -> Operational NO"
ar "$OUT" "Upgrade readiness:[[:space:]]+FAIL$"     "T5b down -> readiness FAIL"

# T6: cmd_health.sh wires the summary in the TEXT path; --json passthrough intact
HC="${NFTBAN_LIB_DIR}/cli/cmd_health.sh"
if grep -qF 'nftban_render_operator_readiness "$output" "" "$validator_rc"' "$HC"; then ok "T6 cmd_health.sh calls the readiness helper (text path)"; else bad "T6 cmd_health.sh does not wire the helper"; fi
if grep -qF 'schema_version, status, service_state, modules, consistency, counters_phase' "$HC"; then ok "T6 --json passthrough branch intact (unfiltered)"; else bad "T6 --json passthrough changed"; fi

# T7: cmd_status.sh semantic findings usage intact; no forced renderer block added
ST="${NFTBAN_LIB_DIR}/cli/cmd_status.sh"
if grep -qF '.findings[0].code' "$ST" && grep -qF 'select(.code == "VAL-CONS-001")' "$ST"; then ok "T7 cmd_status.sh semantic .findings[] usage intact"; else bad "T7 cmd_status.sh semantic findings usage changed"; fi
if grep -qE 'nftban_render_(findings|operator_readiness)' "$ST"; then bad "T7 cmd_status.sh got a forced renderer block (out of R1b-2 scope)"; else ok "T7 cmd_status.sh NOT given a forced renderer block"; fi

# T8: helper defined+exported
if declare -F nftban_render_operator_readiness >/dev/null 2>&1; then ok "T8 nftban_render_operator_readiness defined+sourced"; else bad "T8 helper not defined"; fi

echo "-----------------------------------------------"
printf 'R1b-2 readiness tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
