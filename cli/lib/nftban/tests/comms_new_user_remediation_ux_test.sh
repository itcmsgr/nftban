#!/usr/bin/env bash
# =============================================================================
# NFTBan - Central-comms new-user remediation UX
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="comms_new_user_remediation_ux_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-07"
# meta:description="Central-comms new-user remediation UX: every Communication WARN/ERROR in nftban health renders an actionable Fix (nftban mail setup <email>) + Verify path; the no-local-MTA case adds the SMTP note; an INFO state (no producer) states an explicit no-action-required outcome. The auto-reports producer heuristic no longer fires on a disk-only reports directory (only when report email delivery is configured). nftban stats comms no-metrics path shows recipient/transport state + remediation instead of a dead end, and keeps counters when mail.prom exists. The readiness pointer points to the fix. Hermetic: isolated tempdir, no real mail, no network."
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,awk"
# meta:inventory.env_vars="NFTBAN_MAIL_RECIPIENT,NFTBAN_MAIL_REPORT_RECIPIENT"
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
STATS="$REPO/cli/lib/nftban/cli/cmd_stats.sh"
OUTPUT="$REPO/cli/lib/nftban/core/nftban_output.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  [PASS] $1"; }
no() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }

echo "=== central-comms new-user remediation UX ==="
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

CFN="$WORK/comps.sh"
awk '/^nftban_health_check_communication\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$MODULES" >  "$CFN"
awk '/^_health_eval_communication_component\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$MODULES" >> "$CFN"
SFN="$WORK/stats.sh"; awk '/^nftban_stats_cmd_comms\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$STATS" > "$SFN"

prelude() {
  cat <<EOF
export NFTBAN_DATA_DIR="$WORK/data" NFTBAN_CONFIG_DIR="$WORK/etc" NFTBAN_RUN_DIR="$WORK/run" NFTBAN_LOG_DIR="$WORK/log" NFTBAN_LIB_DIR="$REPO/cli/lib/nftban"
mkdir -p "\$NFTBAN_DATA_DIR" "\$NFTBAN_CONFIG_DIR/conf.d" "\$NFTBAN_RUN_DIR" "\$NFTBAN_LOG_DIR"
declare -A NFTBAN_HEALTH_RESULTS NFTBAN_HEALTH_ISSUES; declare -a NFTBAN_HEALTH_ERRORS
HEALTH_OK=0; HEALTH_WARNING=1; HEALTH_ERROR=2
source "$MAIL" >/dev/null 2>&1 || true
source "$CFN" >/dev/null 2>&1 || true
systemctl() { return 1; }   # no report-email timer in the hermetic env
set +e; set +o pipefail
EOF
}

# 1. missing recipient + local MTA present (transport ok) -> WARN + Fix/Verify, NO no-MTA note
r=$(bash -c "$(prelude)
unset NFTBAN_MAIL_RECIPIENT; export NFTBAN_MAIL_REPORT_RECIPIENT='r@test.example'
nftban_mail_detect_mta() { echo sendmail; }
_health_eval_communication_component c l r; printf '%s\n' \"\$l\"")
echo "$r" | grep -q 'MISSING_RECIPIENT' && echo "$r" | grep -q 'Fix:    nftban mail setup' && echo "$r" | grep -q 'Verify: nftban mail test' && ok "missing recipient + local MTA -> WARN with Fix/Verify" || no "case1: $r"
echo "$r" | grep -q 'no local mail transport' && no "case1 wrongly showed no-MTA note (MTA present)" || ok "missing recipient + MTA present -> no spurious no-MTA note"

# 2. missing recipient + NO transport -> WARN + no-MTA SMTP note
r=$(bash -c "$(prelude)
unset NFTBAN_MAIL_RECIPIENT; export NFTBAN_MAIL_REPORT_RECIPIENT='r@test.example'
nftban_mail_detect_mta() { echo none; }
_health_eval_communication_component c l r; printf '%s\n' \"\$l\"")
echo "$r" | grep -qE 'MISSING_RECIPIENT|TRANSPORT_UNAVAILABLE' && echo "$r" | grep -q 'nftban mail setup' && echo "$r" | grep -q 'no local mail transport' && ok "missing recipient + no transport -> WARN with no-MTA SMTP note" || no "case2: $r"

# 3. disk-only reports (dir exists, NO email config) -> INFO/no-action (NO false WARN)
r=$(bash -c "$(prelude)
unset NFTBAN_MAIL_RECIPIENT NFTBAN_MAIL_REPORT_RECIPIENT
mkdir -p \"\$NFTBAN_DATA_DIR/reports\"
nftban_mail_detect_mta() { echo none; }
_health_eval_communication_component c l r; echo \"CODE=\$c\"; printf '%s\n' \"\$l\"")
echo "$r" | grep -q 'CODE=0' && echo "$r" | grep -qi 'INFO' && echo "$r" | grep -q 'no action required' && ok "disk-only reports -> INFO/no-action (false-positive WARN removed)" || no "case3: $r"

# 4. real email producer (REPORT_RECIPIENT) + missing recipient -> WARN (names auto-reports)
r=$(bash -c "$(prelude)
unset NFTBAN_MAIL_RECIPIENT; export NFTBAN_MAIL_REPORT_RECIPIENT='r@test.example'
mkdir -p \"\$NFTBAN_DATA_DIR/reports\"
nftban_mail_detect_mta() { echo none; }
_health_eval_communication_component c l r; echo \"CODE=\$c\"; printf '%s\n' \"\$l\"")
echo "$r" | grep -q 'CODE=1' && echo "$r" | grep -q 'auto-reports' && ok "report email configured -> WARN names auto-reports producer" || no "case4: $r"

# 5. CLEAN comms -> no remediation noise
r=$(bash -c "$(prelude)
export NFTBAN_MAIL_RECIPIENT='ok@test.example'
nftban_mail_detect_mta() { echo sendmail; }
_health_eval_communication_component c l r; echo \"CODE=\$c\"; printf '%s\n' \"\$l\"")
echo "$r" | grep -q 'CODE=0' && ! echo "$r" | grep -q 'mail setup' && ok "CLEAN comms -> no remediation noise" || no "case5: $r"

# 6. stats comms: no-metrics path shows recipient state + remediation (not a dead end)
r=$(bash -c "$(prelude)
unset NFTBAN_MAIL_RECIPIENT
source \"$SFN\" >/dev/null 2>&1 || true
nftban_mail_detect_mta() { echo none; }
nftban_stats_cmd_comms")
echo "$r" | grep -q 'Recipient: not configured' && echo "$r" | grep -q 'nftban mail setup' && echo "$r" | grep -q 'no delivery metrics yet' && ok "stats comms no-metrics -> recipient state + remediation" || no "case6: $r"

# 7. stats comms: metrics present -> counters preserved + recipient state
r=$(bash -c "$(prelude)
export NFTBAN_MAIL_RECIPIENT='ok@test.example'
mkdir -p \"\$NFTBAN_DATA_DIR/metrics\"
printf 'nftban_mail_send_success_total 5\n' > \"\$NFTBAN_DATA_DIR/metrics/mail.prom\"
source \"$SFN\" >/dev/null 2>&1 || true
nftban_mail_detect_mta() { echo sendmail; }
nftban_stats_cmd_comms")
echo "$r" | grep -q 'Recipient: configured' && echo "$r" | grep -q 'nftban_mail_send_success_total 5' && ok "stats comms with metrics -> recipient state + counters preserved" || no "case7: $r"

# 8. readiness pointer points to the fix command (not just 'nftban stats comms')
RFN="$WORK/render.sh"; awk '/^nftban_render_operator_readiness\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$OUTPUT" > "$RFN"
r=$(bash -c "source '$RFN' >/dev/null 2>&1; set +e +o pipefail
nftban_render_operator_readiness '{\"status\":\"protected\",\"findings\":[]}' '' 0 0 1 2>&1")
echo "$r" | grep -q 'nftban mail setup' && ok "readiness pointer -> nftban mail setup" || no "case8: $r"

# --- regressions ---
( cd "$REPO" && bash cli/lib/nftban/tests/comms_health_render_v2181_test.sh >/dev/null 2>&1 ) && ok "v2181 still passes" || no "v2181 regressed"
( cd "$REPO" && bash cli/lib/nftban/tests/comms_a2b_operator_surfacing_test.sh >/dev/null 2>&1 ) && ok "A2b still passes" || no "A2b regressed"
( cd "$REPO" && bash cli/lib/nftban/tests/comms_a2c_support_summary_test.sh >/dev/null 2>&1 ) && ok "A2c still passes" || no "A2c regressed"
out=$( cd "$REPO" && bash scripts/ci/check-comms-direct-send.sh 2>&1 )
echo "$out" | grep -q '0/4 DEBT' && echo "$out" | grep -q 'PASS' && ok "A0 guard still 0/4" || no "A0 guard regressed"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
