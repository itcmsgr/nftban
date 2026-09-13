#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.198 R1b-2 operator-readiness summary
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="nftban_operator_readiness_r1b2_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-21"
# meta:description="Hermetic tests for core/nftban_output.sh::nftban_render_operator_readiness (R1b-2): shell-side Operational/Upgrade-readiness/Action-needed verdict + IDLE explanation, computed from canned validator JSON + mocked install_state/rc. Plus guards that cmd_health.sh wires it text-only (--json unaffected) and cmd_status.sh semantic findings usage is untouched. v1.230.0 P0 operator-surface truth (RELEASE BLOCKER) extends it to the install transaction: the POSITIVE ASSERTION nftban_install_state_is_committed (state == COMMITTED) that replaced the single-literal test [[ install_state == DEGRADED ]] under which production host dns1, carrying INSTALL_STATE=FAILED_REBUILD, printed Upgrade readiness PASS / Action needed NONE; the nftban_install_state_classify taxonomy (COMMITTED / NOT_COMMITTED / CONTRADICTORY / INDETERMINATE); the D4 operator block (state, when recorded, ENFORCEMENT truth stated separately from TRANSACTION truth, cause, the exact --repair command, and that a reboot is not neutral); the D3 nftban status --json install_transaction object; and A4 — an INVENTED literal that exists in no state source must still never reach PASS, which an enumeration-shaped fix cannot satisfy. Carries a declared-inversion negative control reproducing the pre-fix single-literal rule."
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
# meta:ta.id="nftban_operator_readiness_r1b2_test"
# meta:ta.owner="health"
# meta:ta.module="operator-readiness"
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
# v1.230.0 P0-D1: argument 2 was the empty string until v1.230.0 — cmd_health
# never told the verdict anything about the install transaction. It must now pass
# the class token from the shared authority, so passing "" here is a REGRESSION.
if grep -qF 'nftban_render_operator_readiness "$output" "$_istate_class" "$validator_rc"' "$HC"; then ok "T6 cmd_health.sh calls the readiness helper with the install-state class (text path)"; else bad "T6 cmd_health.sh does not wire the helper with the install-state class"; fi
if grep -qF 'nftban_render_operator_readiness "$output" "" "$validator_rc"' "$HC"; then bad "T6b cmd_health.sh regressed to passing an empty install state"; else ok "T6b cmd_health.sh no longer passes an empty install state"; fi
if grep -qF 'nftban_install_state_classify "$_istate_file"' "$HC"; then ok "T6c cmd_health.sh adjudicates through the shared classifier"; else bad "T6c cmd_health.sh does not use the shared classifier"; fi
if grep -qF 'schema_version, status, service_state, modules, consistency, counters_phase' "$HC"; then ok "T6 --json passthrough branch intact (unfiltered)"; else bad "T6 --json passthrough changed"; fi

# T7: cmd_status.sh semantic findings usage intact; no forced renderer block added
ST="${NFTBAN_LIB_DIR}/cli/cmd_status.sh"
if grep -qF '.findings[0].code' "$ST" && grep -qF 'select(.code == "VAL-CONS-001")' "$ST"; then ok "T7 cmd_status.sh semantic .findings[] usage intact"; else bad "T7 cmd_status.sh semantic findings usage changed"; fi
if grep -qE 'nftban_render_(findings|operator_readiness)' "$ST"; then bad "T7 cmd_status.sh got a forced renderer block (out of R1b-2 scope)"; else ok "T7 cmd_status.sh NOT given a forced renderer block"; fi

# T8: helper defined+exported
if declare -F nftban_render_operator_readiness >/dev/null 2>&1; then ok "T8 nftban_render_operator_readiness defined+sourced"; else bad "T8 helper not defined"; fi

# =============================================================================
# v1.230.0 P0 — OPERATOR-SURFACE TRUTH (RELEASE BLOCKER)
# =============================================================================
# Subject: the POSITIVE ASSERTION `state == COMMITTED` that replaced two
# one-failure tests, and the operator text an incomplete transaction must carry.
#
# Defects reproduced on production host dns1 (v1.229.14, INSTALL_STATE=FAILED_REBUILD):
#   D1 core/nftban_output.sh   [[ "$_install_state" == "DEGRADED" ]] — ONE literal
#      against an open-ended state space; the host printed "Upgrade readiness:
#      PASS / Action needed: NONE / Findings: none". FAIL-OPEN.
#   D3 cmd_status.sh read AUTHORITY=/CONFLICTS= from install_state but never
#      INSTALL_STATE=, and --json exposed only an authority object.
#   D4 flipping PASS->FAIL is not enough: the surface must carry the state and
#      when it was recorded, ENFORCEMENT truth SEPARATE from TRANSACTION truth,
#      the cause, the exact recovery command, and the reboot warning.
#
# ⛔ A4 IS THE CASE THAT SEPARATES A REAL FIX FROM A LONGER FAILURE LIST: an
#    INVENTED literal that exists nowhere in internal/installer/state/machine.go
#    must still never reach PASS. An enumeration-shaped fix passes A2 and A3 and
#    FAILS A4.
# =============================================================================
echo ""
echo "v1.230.0 P0 operator-surface truth (D1/D3/D4):"

P0TMP="$(mktemp -d)"
trap 'rm -rf "$P0TMP"' EXIT
p0_state() { printf '%b' "$1" > "$P0TMP/install_state"; printf '%s' "$P0TMP/install_state"; }

# --- the predicate itself -----------------------------------------------------
if declare -F nftban_install_state_is_committed >/dev/null 2>&1; then ok "P0-0 positive-assertion predicate defined"; else bad "P0-0 nftban_install_state_is_committed missing"; fi
nftban_install_state_is_committed "COMMITTED"        && ok "P0-0a COMMITTED asserts true"           || bad "P0-0a COMMITTED must assert true"
nftban_install_state_is_committed "FAILED_REBUILD"   && bad "P0-0b FAILED_REBUILD must not assert"  || ok "P0-0b FAILED_REBUILD does not assert"
nftban_install_state_is_committed ""                 && bad "P0-0c empty must not assert"           || ok "P0-0c empty does not assert"
nftban_install_state_is_committed                    && bad "P0-0d no-argument must not assert"     || ok "P0-0d no argument does not assert (set -u safe)"

# --- A1 COMMITTED: the positive control, and it must not be vacuous -----------
SF="$(p0_state 'INSTALL_STATE=COMMITTED\nINSTALL_TIMESTAMP=2026-09-08T10:00:00Z\nFAILURE_REASON=\n')"
[[ "$(nftban_install_state_classify "$SF")" == "COMMITTED" ]] && ok "A1 COMMITTED classifies COMMITTED" || bad "A1 COMMITTED misclassified"
OUT=$(nftban_render_operator_readiness '{"status":"protected","findings":[]}' "$(nftban_install_state_classify "$SF")" 0)
ar "$OUT" "Upgrade readiness:[[:space:]]+PASS$"  "A1 COMMITTED -> readiness PASS (positive control not vacuous)"
ar "$OUT" "Action needed:[[:space:]]+NONE$"      "A1 COMMITTED -> action NONE"
nf "$OUT" "install transaction"                  "A1 COMMITTED -> no transaction warning line"
OUT=$(nftban_render_install_transaction_truth "$SF" || true)
[[ -z "$OUT" ]] && ok "A1 COMMITTED -> transaction block renders nothing" || bad "A1 COMMITTED rendered a block: [$OUT]"

# --- A2 FAILED_REBUILD (the dns1 state) ---------------------------------------
SF="$(p0_state 'INSTALL_STATE=FAILED_REBUILD\nINSTALL_VERSION=1.229.14\nINSTALL_TIMESTAMP=2026-09-08T11:22:33.123456789Z\nPHASE_REACHED=switch\nFAILURE_REASON=rebuild failed: ruleset rejected by the kernel (exit 1)\n')"
[[ "$(nftban_install_state_classify "$SF")" == "NOT_COMMITTED" ]] && ok "A2 FAILED_REBUILD classifies NOT_COMMITTED" || bad "A2 FAILED_REBUILD misclassified"
OUT=$(nftban_render_operator_readiness '{"status":"protected","findings":[]}' "$(nftban_install_state_classify "$SF")" 0)
nr "$OUT" "Upgrade readiness:[[:space:]]+PASS"   "A2 FAILED_REBUILD -> never PASS (the dns1 defect)"
ar "$OUT" "Upgrade readiness:[[:space:]]+FAIL$"  "A2 FAILED_REBUILD -> readiness FAIL"
nr "$OUT" "Action needed:[[:space:]]+NONE"       "A2 FAILED_REBUILD -> action is never NONE"
af "$OUT" "install transaction"                  "A2 readiness names the install transaction"
BLK=$(nftban_render_install_transaction_truth "$SF" || true)
af "$BLK" "FAILED_REBUILD"                                     "A2 D4: the block states the state"
af "$BLK" "2026-09-08T11:22:33.123456789Z"                     "A2 D4: the block states when it was recorded"
af "$BLK" "rebuild failed: ruleset rejected by the kernel (exit 1)"                    "A2 D4: the block states the cause in one line"
af "$BLK" "/usr/lib/nftban/bin/nftban-installer --repair"      "A2 D4: the block states the exact recovery command"
af "$BLK" "NOT NEUTRAL"                                        "A2 D4: the block states a reboot is not neutral"
af "$BLK" "Enforcement:"                                       "A2 D4: ENFORCEMENT truth is a separate line"
af "$BLK" "Transaction status:"                                "A2 D4: TRANSACTION truth is its own line"
# ⛔ PROTECTED must never stand alone: an enforcing firewall is not evidence the
#    transaction completed, and the block must say so rather than imply it.
af "$BLK" "NOT evidence"                                       "A2 D4: enforcement is explicitly not evidence of a committed transaction"

# --- A3 INSTALL_FAILED --------------------------------------------------------
# (the filesystem effects of this state — history row, failure marker — are
#  asserted in tests/update_degraded_render_truth_v225_test.sh, which drives the
#  mutating update verdict itself.)
SF="$(p0_state 'INSTALL_STATE=INSTALL_FAILED\nINSTALL_TIMESTAMP=2026-09-08T10:00:00Z\n')"
[[ "$(nftban_install_state_classify "$SF")" == "NOT_COMMITTED" ]] && ok "A3 INSTALL_FAILED classifies NOT_COMMITTED" || bad "A3 INSTALL_FAILED misclassified"
OUT=$(nftban_render_operator_readiness '{"status":"protected","findings":[]}' "$(nftban_install_state_classify "$SF")" 0)
nr "$OUT" "Upgrade readiness:[[:space:]]+PASS"   "A3 INSTALL_FAILED -> never PASS"

# --- A4 AN INVENTED LITERAL — the enumeration-killer --------------------------
# FUTURE_STATE_XYZ exists in NO source of truth: not machine.go, not verify.go,
# not this file's wording list. A fix built from a list of failure literals
# reaches PASS here; a positive assertion cannot.
if grep -rqF 'FUTURE_STATE_XYZ' "${REPO_ROOT}/internal" 2>/dev/null; then
    bad "A4 fixture literal FUTURE_STATE_XYZ must NOT exist in internal/ (it would stop being an unknown state)"
else
    ok "A4 fixture literal FUTURE_STATE_XYZ exists in no Go state source (genuinely unknown)"
fi
nftban_install_state_is_known_literal "FUTURE_STATE_XYZ" && bad "A4 invented literal must not be a known literal" || ok "A4 invented literal is not a known literal"
SF="$(p0_state 'INSTALL_STATE=FUTURE_STATE_XYZ\nINSTALL_TIMESTAMP=2026-09-08T10:00:00Z\n')"
[[ "$(nftban_install_state_classify "$SF")" == "NOT_COMMITTED" ]] && ok "A4 invented literal classifies NOT_COMMITTED" || bad "A4 invented literal misclassified"
OUT=$(nftban_render_operator_readiness '{"status":"protected","findings":[]}' "$(nftban_install_state_classify "$SF")" 0)
nr "$OUT" "Upgrade readiness:[[:space:]]+PASS"   "A4 invented literal -> never PASS (positive-assertion shape)"
ar "$OUT" "Upgrade readiness:[[:space:]]+FAIL$"  "A4 invented literal -> readiness FAIL"
BLK=$(nftban_render_install_transaction_truth "$SF" || true)
af "$BLK" "FUTURE_STATE_XYZ"                     "A4 the block names the unrecognised literal verbatim"
af "$BLK" "UNKNOWN STATE"                        "A4 the block surfaces it AS UNKNOWN, not as a known failure"

# --- A5 unreadable / missing state file ---------------------------------------
[[ "$(nftban_install_state_classify "$P0TMP/does-not-exist")" == "INDETERMINATE" ]] && ok "A5 missing file classifies INDETERMINATE" || bad "A5 missing file misclassified"
[[ "$(nftban_install_state_classify "")" == "INDETERMINATE" ]] && ok "A5 empty path classifies INDETERMINATE" || bad "A5 empty path misclassified"
printf 'AUTHORITY=UPDATE\nCONFLICTS=\n' > "$P0TMP/nokey"
[[ "$(nftban_install_state_classify "$P0TMP/nokey")" == "INDETERMINATE" ]] && ok "A5 readable file with no INSTALL_STATE key classifies INDETERMINATE" || bad "A5 no-key file misclassified"
if [[ "$(id -u)" != "0" ]]; then
    printf 'INSTALL_STATE=COMMITTED\n' > "$P0TMP/unreadable"; chmod 000 "$P0TMP/unreadable"
    [[ "$(nftban_install_state_classify "$P0TMP/unreadable")" == "INDETERMINATE" ]] && ok "A5 unreadable file classifies INDETERMINATE (never a success claim)" || bad "A5 unreadable file misclassified"
    chmod 644 "$P0TMP/unreadable"
else
    ok "A5 unreadable-file case SKIPPED as root (chmod 000 is not a read barrier for uid 0) — not counted as a pass of the barrier"
fi
OUT=$(nftban_render_operator_readiness '{"status":"protected","findings":[]}' "$(nftban_install_state_classify "$P0TMP/does-not-exist")" 0)
nr "$OUT" "Upgrade readiness:[[:space:]]+PASS"          "A5 missing state file -> never PASS"
ar "$OUT" "Upgrade readiness:[[:space:]]+INDETERMINATE$" "A5 missing state file -> INDETERMINATE (not a false FAIL either)"
ar "$OUT" "Action needed:[[:space:]]+VERIFY$"            "A5 missing state file -> action VERIFY"

# --- contradictory fields ------------------------------------------------------
# internal/installer/state/file.go applyTerminalHygiene CLEARS FailureReason on
# COMMITTED, so this combination cannot come from the writer.
SF="$(p0_state 'INSTALL_STATE=COMMITTED\nFAILURE_REASON=takeover not approved\n')"
[[ "$(nftban_install_state_classify "$SF")" == "CONTRADICTORY" ]] && ok "A5b COMMITTED beside a FAILURE_REASON classifies CONTRADICTORY" || bad "A5b contradictory fields misclassified"
OUT=$(nftban_render_operator_readiness '{"status":"protected","findings":[]}' "$(nftban_install_state_classify "$SF")" 0)
nr "$OUT" "Upgrade readiness:[[:space:]]+PASS"   "A5b contradictory fields -> never PASS"

# --- A6 nftban status --json exposes the authoritative install state ----------
# D3: before v1.230.0 this command read AUTHORITY=/CONFLICTS= out of install_state
# and never INSTALL_STATE=, so no structured surface carried it and fleet
# automation was blind. The emitter is driven directly (hermetic: no nft, no
# systemd, no root) with NFTBAN_STATE_DIR pointed at the fixture.
ST="${NFTBAN_LIB_DIR}/cli/cmd_status.sh"
a6() { # $1=fixture body ("-" = no file) $2=jq filter $3=expected $4=label
    local body="$1" filter="$2" want="$3" label="$4" dir got
    dir="$P0TMP/a6"; rm -rf "$dir"; mkdir -p "$dir"
    [[ "$body" == "-" ]] || printf '%b' "$body" > "$dir/install_state"
    got=$(NFTBAN_STATE_DIR="$dir" bash -c '
        set -Eeuo pipefail
        export NFTBAN_LIB_DIR="'"$NFTBAN_LIB_DIR"'"
        source "$NFTBAN_LIB_DIR/core/nftban_output.sh"
        eval "$(sed -n "/^_status_install_state_file() {/,/^}/p;/^_status_install_txn_class() {/,/^}/p;/^_status_json_install_transaction() {/,/^}/p" "'"$ST"'")"
        json_escape() { local str="$1"; str="${str//\\/\\\\}"; str="${str//"/\\"}"; printf "%s\n" "$str"; }
        printf "{\n"; _status_json_install_transaction; printf "  \"end\": true\n}\n"
    ' | jq -r "$filter" 2>/dev/null) || got="<JQ-FAILED>"
    if [[ "$got" == "$want" ]]; then ok "$label"; else bad "$label (got [$got] want [$want])"; fi
}
a6 'INSTALL_STATE=COMMITTED\n'                          '.install_transaction.committed' 'true'            'A6/A1 --json committed=true for COMMITTED'
a6 'INSTALL_STATE=COMMITTED\n'                          '.install_transaction.state'     'COMMITTED'       'A6/A1 --json exposes the state literal'
a6 'INSTALL_STATE=FAILED_REBUILD\nFAILURE_REASON=rebuild failed: ruleset rejected by the kernel (exit 1)\n' '.install_transaction.committed' 'false' 'A6/A2 --json committed=false for FAILED_REBUILD'
a6 'INSTALL_STATE=FAILED_REBUILD\nFAILURE_REASON=rebuild failed: ruleset rejected by the kernel (exit 1)\n' '.install_transaction.reason'    'rebuild failed: ruleset rejected by the kernel (exit 1)' 'A6/A2 --json exposes the reason'
a6 'INSTALL_STATE=INSTALL_FAILED\n'                     '.install_transaction.committed' 'false'           'A6/A3 --json committed=false for INSTALL_FAILED'
a6 'INSTALL_STATE=FUTURE_STATE_XYZ\n'                   '.install_transaction.committed' 'false'           'A6/A4 --json committed=false for an invented literal'
a6 'INSTALL_STATE=FUTURE_STATE_XYZ\n'                   '.install_transaction.known_state_literal' 'false' 'A6/A4 --json flags the literal as unknown'
a6 '-'                                                   '.install_transaction.class'     'INDETERMINATE'   'A6/A5 --json class=INDETERMINATE with no state file'
a6 '-'                                                   '.install_transaction.committed' 'false'           'A6/A5 --json committed=false with no state file'
a6 'INSTALL_STATE=COMMITTED\nFAILURE_REASON=takeover not approved\n' '.install_transaction.class' 'CONTRADICTORY' 'A6/A5b --json class=CONTRADICTORY'

# D3 static: the command must actually read INSTALL_STATE and emit the object.
if grep -qF '_status_json_install_transaction' "$ST"; then ok "A6 cmd_status.sh emits install_transaction in --json"; else bad "A6 cmd_status.sh has no install_transaction JSON surface"; fi
if grep -qF 'nftban_install_state_classify' "$ST"; then ok "D3 cmd_status.sh adjudicates through the shared classifier"; else bad "D3 cmd_status.sh does not use the shared classifier"; fi
# ⛔ PROTECTED alone: the SYSTEM block must carry the transaction line unconditionally.
if grep -qF '_status_install_txn_summary' "$ST"; then ok "D4 cmd_status.sh SYSTEM block carries the install-transaction line beside the state headline"; else bad "D4 cmd_status.sh prints its state headline without a transaction line"; fi

# --- NEGATIVE CONTROL (declared inversion) ------------------------------------
# ⛔ The A1-A6 greens above are only evidence if they can go red. This is the
#    PRE-v1.230.0 install-state rule, reconstructed verbatim: ONE exact literal
#    tested against an open-ended state space. It must green-light FAILED_REBUILD
#    (the dns1 state), INSTALL_FAILED and an invented literal — the defect — while
#    correctly failing DEGRADED. A declared inversion rather than a checkout,
#    because origin/main stops being "pre-fix" the moment the fix merges.
_p0_prefix_install_state_rule() {   # returns 0 when the PRE-FIX code would say FAIL
    local _install_state="${1-}"
    [[ "$_install_state" == "DEGRADED" ]]
}
_p0_prefix_prefix_verdict() {       # PASS/FAIL as the pre-fix helper would render it
    if _p0_prefix_install_state_rule "$1"; then printf 'FAIL'; else printf 'PASS'; fi
}
for _lit in FAILED_REBUILD INSTALL_FAILED FUTURE_STATE_XYZ FAILED_NO_FIREWALL SWITCH_COMPLETE RESTORE_REFUSED; do
    if [[ "$(_p0_prefix_prefix_verdict "$_lit")" == "PASS" ]]; then
        ok "NEG-D1 pre-fix rule green-lights ${_lit} (the assertions above are live)"
    else
        bad "NEG-D1 pre-fix rule did NOT green-light ${_lit} — the A2/A3/A4 assertions may be vacuous"
    fi
    # and the fixed predicate must disagree with it on every one of them
    nftban_install_state_is_committed "$_lit" \
        && bad "NEG-D1 fixed predicate wrongly asserts COMMITTED for ${_lit}" \
        || ok "NEG-D1 fixed predicate refuses ${_lit}"
done
if [[ "$(_p0_prefix_prefix_verdict "DEGRADED")" == "FAIL" ]]; then
    ok "NEG-D1 the inversion is faithful, not a strawman (it did catch DEGRADED)"
else
    bad "NEG-D1 inversion misbuilt — it does not even catch the one literal the pre-fix rule named"
fi

# --- the wording list must not silently fall behind the Go enum ---------------
# ⛔ This list is WORDING ONLY and is never the verdict — an unlisted literal is
#    already not-COMMITTED. The check exists so "UNKNOWN STATE" keeps meaning
#    "the Go installer never emits this", not "our list rotted".
MG="${REPO_ROOT}/internal/installer/state/machine.go"
if [[ -r "$MG" ]]; then
    _missing=""
    while IFS= read -r _lit; do
        [[ -n "$_lit" ]] || continue
        nftban_install_state_is_known_literal "$_lit" || _missing="${_missing} ${_lit}"
    done < <(grep -oE 'InstallState = "[A-Z_]+"' "$MG" | sed 's/.*"\(.*\)"/\1/' | sort -u)
    if [[ -z "$_missing" ]]; then ok "P0-W every internal/installer/state/machine.go literal is in the wording list"
    else bad "P0-W wording list is behind machine.go:${_missing}"; fi
else
    bad "P0-W could not read $MG to cross-check the wording list"
fi


# =============================================================================
# OWNER RULING (v1.230.0) — KEEP INDETERMINATE. DO NOT COLLAPSE IT INTO FAIL.
# =============================================================================
# Subject: nftban_render_operator_readiness in core/nftban_output.sh.
#
#   PASS           evidence establishes the requirement is met
#   FAIL           evidence positively establishes the requirement is VIOLATED
#   INDETERMINATE  the system could not obtain sufficient trustworthy evidence
#
# ⛔ OPERATIONALLY BOTH STOP: neither reaches PASS and neither reaches action NONE.
# ⛔ FORENSICALLY THEY DIFFER: FAIL means "we looked and it is broken"; INDETERMINATE
#    means "we could not look", so its action is VERIFY (obtain the evidence), not
#    FAIL (repair a known break). Collapsing them destroys evidence provenance —
#    the mirror image of the v1.230.0 defect where never-written fields masqueraded
#    as measurements.
# =============================================================================
echo ""
echo "v1.230.0 OWNER RULING — three-valued readiness (INDETERMINATE is not FAIL):"

R2_JSON='{"status":"protected","findings":[]}'
R2_INDET=$(nftban_render_operator_readiness "$R2_JSON" "INDETERMINATE" 0)
R2_FAILED=$(nftban_render_operator_readiness "$R2_JSON" "FAILED_REBUILD" 0)
R2_OK=$(nftban_render_operator_readiness "$R2_JSON" "COMMITTED" 0)

# --- the three classes each land on their own verdict/action pair -------------
ar "$R2_OK"    "Upgrade readiness:[[:space:]]+PASS$"          "R2 COMMITTED -> readiness PASS"
ar "$R2_OK"    "Action needed:[[:space:]]+NONE$"              "R2 COMMITTED -> action NONE"
ar "$R2_FAILED" "Upgrade readiness:[[:space:]]+FAIL$"         "R2 a positively-violated state -> readiness FAIL"
ar "$R2_FAILED" "Action needed:[[:space:]]+FAIL$"             "R2 a positively-violated state -> action FAIL"
ar "$R2_INDET" "Upgrade readiness:[[:space:]]+INDETERMINATE$" "R2 unobtainable evidence -> readiness INDETERMINATE"
ar "$R2_INDET" "Action needed:[[:space:]]+VERIFY$"            "R2 unobtainable evidence -> action VERIFY"

# --- operationally, INDETERMINATE is NON-SUCCESS ------------------------------
nr "$R2_INDET" "Upgrade readiness:[[:space:]]+PASS"  "R2 INDETERMINATE never reaches PASS (non-zero-evidence is non-success)"
nr "$R2_INDET" "Action needed:[[:space:]]+NONE"      "R2 INDETERMINATE never reaches action NONE"

# --- forensically, INDETERMINATE is DISTINCT from FAIL ------------------------
# ⛔ THIS IS THE ARM A COLLAPSE BREAKS. Folding INDETERMINATE into FAIL makes the
#    two renderings agree on the action word, and lands here.
nr "$R2_INDET" "Action needed:[[:space:]]+FAIL"      "R2 INDETERMINATE is NOT rendered as FAIL (evidence provenance preserved)"
af "$R2_INDET" "cannot be established"               "R2 the INDETERMINATE pointer says the outcome could not be ESTABLISHED"
nf "$R2_INDET" "NOT COMMITTED;"                      "R2 INDETERMINATE does not borrow the asserted-failure sentence"
af "$R2_FAILED" "NOT COMMITTED;"                     "R2 an asserted failure keeps its own sentence"

# --- structural: the rationale must stay at the mapping site ------------------
OUT_SH="${NFTBAN_LIB_DIR}/core/nftban_output.sh"
for _s in "KEEP INDETERMINATE. DO NOT COLLAPSE IT INTO FAIL" \
          "INDETERMINATE IS NOT A SOFTER FAIL AND NOT A QUIETER PASS" \
          "AN OUTCOME THAT WAS NEVER OBSERVED IS NOT A FAILURE"; do
    if grep -qF -- "$_s" "$OUT_SH"; then ok "R2 nftban_output.sh still documents the ruling: ${_s:0:40}..."
    else bad "R2 nftban_output.sh ruling rationale removed — missing: $_s"; fi
done

# --- NEGATIVE CONTROL (declared inversion) ------------------------------------
# ⛔ The greens above are only evidence if they can go red. This is the forbidden
#    collapse — INDETERMINATE mapped onto the FAIL action — over the SAME input.
#    It must make the INDETERMINATE and FAIL renderings agree; if it does not, the
#    distinctness assertions above are vacuous.
_r2_collapsed_action() {
    case "$1" in
        FAIL|INDETERMINATE) echo "FAIL" ;;
        PASS_WITH_WARN)     echo "WARN" ;;
        *)                  echo "NONE" ;;
    esac
}
_r2_inv_indet="$(_r2_collapsed_action INDETERMINATE)"
_r2_inv_fail="$(_r2_collapsed_action FAIL)"
if [[ "$_r2_inv_indet" == "$_r2_inv_fail" ]] && grep -qE "Action needed:[[:space:]]+VERIFY$" <<<"$R2_INDET"; then
    ok "NEG-R2 the collapsed mapping DOES erase the VERIFY action (both become $_r2_inv_indet) while the real one keeps it — the distinctness assertions are live"
else
    bad "NEG-R2 inversion did not reproduce the collapse (inverted: $_r2_inv_indet vs $_r2_inv_fail) — the R2 distinctness assertions may be vacuous"
fi

echo "-----------------------------------------------"
printf 'R1b-2 readiness tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
