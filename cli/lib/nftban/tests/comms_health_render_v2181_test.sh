#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.218.1 Communication health-render patch
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="comms_health_render_v2181_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-07"
# meta:description="v1.218.1: nftban health (four-axis) now surfaces Communication as a NAMED component and its severity RAISES the readiness verdict. Tests: _health_eval_communication_component returns CLEAN/code0 on a healthy comms state and WARN/code1 with a COMMUNICATION_SPOOL_BACKLOG reason on a forced spool backlog; nftban_render_operator_readiness raises PASS->PASS_WITH_WARN on comms_sev>=1 (never forces FAIL) and emits the comms pointer; clean comms leaves PASS. Re-runs A2a/A2b/A2r/A2c + guard. Hermetic: isolated tempdir, no real mail, no network."
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,jq"
# meta:inventory.env_vars="NFTBAN_MAIL_METHOD,NFTBAN_MAIL_RECIPIENT"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../../../.." && pwd)"
MAIL="$REPO/cli/lib/nftban/core/nftban_mail.sh"
MODULES="$REPO/cli/lib/nftban/core/nftban_health_checks_modules.sh"
OUTPUT="$REPO/cli/lib/nftban/core/nftban_output.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  [PASS] $1"; }
no_fail() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }

echo "=== v1.218.1 Communication health-render ==="
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Extract the render verdict fn + the two shell fns (files have load-time deps).
RFN="$WORK/render.sh"; awk '/^nftban_render_operator_readiness\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$OUTPUT" > "$RFN"
CFN="$WORK/comps.sh"
awk '/^nftban_health_check_communication\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$MODULES" >  "$CFN"
awk '/^_health_eval_communication_component\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$MODULES" >> "$CFN"
grep -q 'nftban_render_operator_readiness' "$RFN" && ok "extracted render_operator_readiness" || no_fail "extract render"
grep -q '_health_eval_communication_component' "$CFN" && ok "extracted comms eval fns" || no_fail "extract eval"

CLEAN_JSON='{"status":"protected","findings":[]}'

# --- verdict raise: comms_sev>=1 -> PASS_WITH_WARN + pointer; comms_sev=0 -> PASS ---
r0=$(bash -c "source '$RFN'; set +e; nftban_render_operator_readiness '$CLEAN_JSON' '' 0 '' 0")
echo "$r0" | grep -qE 'Upgrade readiness:[[:space:]]+PASS$' && ok "clean comms -> readiness PASS" || no_fail "clean comms not PASS: $(echo "$r0"|grep -i readiness)"
r1=$(bash -c "source '$RFN'; set +e; nftban_render_operator_readiness '$CLEAN_JSON' '' 0 '' 1")
echo "$r1" | grep -qE 'Upgrade readiness:[[:space:]]+PASS_WITH_WARN' && ok "comms WARN raises verdict -> PASS_WITH_WARN" || no_fail "comms WARN did not raise: $(echo "$r1"|grep -i readiness)"
echo "$r1" | grep -qE 'communication (degraded|needs setup)' && ok "comms pointer emitted" || no_fail "comms pointer missing"
# never forces FAIL from comms (comms ERROR on an otherwise-clean run stays PASS_WITH_WARN, not FAIL)
r2=$(bash -c "source '$RFN'; set +e; nftban_render_operator_readiness '$CLEAN_JSON' '' 0 '' 2")
echo "$r2" | grep -qE 'Upgrade readiness:[[:space:]]+PASS_WITH_WARN' && ok "comms ERROR does not force FAIL (advisory)" || no_fail "comms ERROR wrongly changed verdict: $(echo "$r2"|grep -i readiness)"

# --- eval component: CLEAN on healthy, WARN on forced spool backlog ---
prelude() {
  cat <<EOF
export NFTBAN_DATA_DIR="$WORK/data" NFTBAN_CONFIG_DIR="$WORK/etc" NFTBAN_RUN_DIR="$WORK/run" NFTBAN_LOG_DIR="$WORK/log" NFTBAN_LIB_DIR="$REPO/cli/lib/nftban"
mkdir -p "\$NFTBAN_DATA_DIR" "\$NFTBAN_CONFIG_DIR" "\$NFTBAN_RUN_DIR" "\$NFTBAN_LOG_DIR"
declare -A NFTBAN_HEALTH_RESULTS NFTBAN_HEALTH_ISSUES; declare -a NFTBAN_HEALTH_ERRORS
HEALTH_OK=0; HEALTH_WARNING=1; HEALTH_ERROR=2
export NFTBAN_MAIL_METHOD=emulate NFTBAN_MAIL_RECIPIENT='rcpt@test.example'
source "$MAIL" >/dev/null 2>&1 || true
source "$CFN" >/dev/null 2>&1 || true
set +e; set +o pipefail
EOF
}
ev_clean=$(bash -c "$(prelude)
_health_eval_communication_component c l r
echo \"CODE=\$c\"; echo \"LINE=\$l\"")
echo "$ev_clean" | grep -q 'CODE=0' && echo "$ev_clean" | grep -qi 'Communication:.*CLEAN' && ok "eval: healthy comms -> CLEAN/code0 named line" || no_fail "eval clean wrong: $ev_clean"

ev_warn=$(bash -c "$(prelude)
mkdir -p \"\$NFTBAN_DATA_DIR/mailspool\"; : > \"\$NFTBAN_DATA_DIR/mailspool/probe.mail\"
_health_eval_communication_component c l r
echo \"CODE=\$c\"; echo \"LINE=\$l\"")
echo "$ev_warn" | grep -q 'CODE=1' && echo "$ev_warn" | grep -qi 'Communication:.*WARN' && echo "$ev_warn" | grep -q 'COMMUNICATION_SPOOL_BACKLOG' && ok "eval: spool backlog -> WARN/code1 + COMMUNICATION_SPOOL_BACKLOG reason" || no_fail "eval warn wrong: $ev_warn"

# v1.218.1 policy: NOT configured + NO alert producer + no evidence -> INFO (declared, not WARN)
ev_info=$(bash -c "$(prelude)
rm -rf \"\$NFTBAN_DATA_DIR/mailspool\" \"\$NFTBAN_DATA_DIR/reports\" \"\$NFTBAN_DATA_DIR/metrics\"
unset NFTBAN_MAIL_RECIPIENT
nftban_mail_detect_mta() { echo none; }
_health_eval_communication_component c l r
echo \"CODE=\$c\"; echo \"LINE=\$l\"")
echo "$ev_info" | grep -q 'CODE=0' && echo "$ev_info" | grep -qi 'Communication:.*INFO' && echo "$ev_info" | grep -q 'NOT CONFIGURED' && ok "eval: no config + no producer -> INFO/NOT CONFIGURED (code0, no verdict raise)" || no_fail "eval info wrong: $ev_info"

# v1.218.1 policy: NOT configured but an alert PRODUCER is enabled -> WARN.
# UX slice: auto-reports is a producer only when configured for EMAIL delivery
# (NFTBAN_MAIL_REPORT_RECIPIENT set), NOT merely because the reports dir exists.
ev_warn_prod=$(bash -c "$(prelude)
rm -rf \"\$NFTBAN_DATA_DIR/mailspool\" \"\$NFTBAN_DATA_DIR/metrics\"
unset NFTBAN_MAIL_RECIPIENT
export NFTBAN_MAIL_REPORT_RECIPIENT='reports@test.example'
nftban_mail_detect_mta() { echo none; }
_health_eval_communication_component c l r
echo \"CODE=\$c\"; echo \"LINE=\$l\"")
echo "$ev_warn_prod" | grep -q 'CODE=1' && echo "$ev_warn_prod" | grep -qi 'Communication:.*WARN' && echo "$ev_warn_prod" | grep -qE 'MISSING_RECIPIENT|TRANSPORT_UNAVAILABLE' && echo "$ev_warn_prod" | grep -q 'auto-reports' && ok "eval: not-configured + producer enabled -> WARN (names the producer)" || no_fail "eval warn-producer wrong: $ev_warn_prod"
# UX slice: the WARN must carry an actionable Fix/Verify remediation
echo "$ev_warn_prod" | grep -q 'nftban mail setup' && echo "$ev_warn_prod" | grep -q 'Verify: nftban mail test' && ok "eval: WARN carries Fix/Verify remediation" || no_fail "no remediation in WARN: $ev_warn_prod"

# UX slice: DISK-ONLY reports (reports dir exists, NO email config) must NOT WARN -> INFO
ev_disk=$(bash -c "$(prelude)
rm -rf \"\$NFTBAN_DATA_DIR/mailspool\" \"\$NFTBAN_DATA_DIR/metrics\"
unset NFTBAN_MAIL_RECIPIENT NFTBAN_MAIL_REPORT_RECIPIENT
mkdir -p \"\$NFTBAN_DATA_DIR/reports\"
systemctl() { return 1; }   # no report-email timer
nftban_mail_detect_mta() { echo none; }
_health_eval_communication_component c l r
echo \"CODE=\$c\"; echo \"LINE=\$l\"")
echo "$ev_disk" | grep -q 'CODE=0' && echo "$ev_disk" | grep -qi 'Communication:.*INFO' && echo "$ev_disk" | grep -q 'no action required' && ok "eval: disk-only reports -> INFO/no-action (no false WARN)" || no_fail "disk-only reports wrongly WARNed: $ev_disk"

# --- prior suites unaffected ---
out=$( cd "$REPO" && bash scripts/ci/check-comms-direct-send.sh 2>&1 )
echo "$out" | grep -q '0/4 DEBT' && echo "$out" | grep -q 'PASS' && ok "A0 guard still 0/4 PASS" || no_fail "A0 guard regressed"
for t in comms_a2a_delivery_truth comms_a2b_operator_surfacing comms_a2r_rbl_visibility comms_a2c_support_summary; do
  ( cd "$REPO" && bash "cli/lib/nftban/tests/${t}"*.sh >/dev/null 2>&1 ) && ok "${t} still passes" || no_fail "${t} regressed"
done

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
