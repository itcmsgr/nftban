#!/usr/bin/env bash
# =============================================================================
# NFTBan - Central-comms producer-signal accuracy
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="comms_producer_signal_accuracy_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-07"
# meta:description="Central-comms producer-signal accuracy: the auto-reports EMAIL producer is keyed on STATS_EMAIL_ENABLED truthy (from conf.d/stats.conf OR the environment) with STATS_EMAIL_RECIPIENTS as the report recipient. A disk-only reports directory never fires a Communication WARN (v1.218.2 regression guard). A resolvable report recipient is deliverable (never MISSING_RECIPIENT). STATS_EMAIL_ENABLED with no recipient anywhere is a MISCONFIGURATION (misconfig wording, not a delivery-failure wording). The check reads conf.d/stats.conf, not just env, and other producers (mail.conf MAIL_ENABLED) still surface. Hermetic: isolated tempdir, no real mail, no network, non-secret markers only."
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,awk"
# meta:inventory.env_vars="NFTBAN_MAIL_RECIPIENT,STATS_EMAIL_ENABLED,STATS_EMAIL_RECIPIENTS"
# meta:inventory.config_files="conf.d/stats.conf,conf.d/mail.conf"
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

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  [PASS] $1"; }
no() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }

echo "=== central-comms producer-signal accuracy ==="
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

CFN="$WORK/comps.sh"
awk '/^nftban_health_check_communication\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$MODULES" >  "$CFN"
awk '/^_health_eval_communication_component\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$MODULES" >> "$CFN"

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

# 1. DISK-ONLY: reports dir exists but STATS_EMAIL disabled + no recipient -> INFO/no-action (CODE=0)
#    Regression guard for the v1.218.2 disk-only fix: the dir alone must NOT fire a Communication WARN.
r=$(bash -c "$(prelude)
unset NFTBAN_MAIL_RECIPIENT STATS_EMAIL_ENABLED STATS_EMAIL_RECIPIENTS
mkdir -p \"\$NFTBAN_DATA_DIR/reports\"
nftban_mail_detect_mta() { echo none; }
_health_eval_communication_component c l r; echo \"CODE=\$c\"; printf '%s\n' \"\$l\"")
echo "$r" | grep -q 'CODE=0' && echo "$r" | grep -qi 'INFO' && echo "$r" | grep -q 'no action required' \
  && ok "row1 disk-only reports dir -> CODE=0 INFO no-action-required" || no "row1: $r"

# 2. CLEAN: STATS_EMAIL_ENABLED=true + report recipient + transport present -> CODE=0, NOT WARN, NOT MISSING_RECIPIENT
#    (deliverable via the report's own recipient even with the general NFTBAN_MAIL_RECIPIENT unset)
r=$(bash -c "$(prelude)
unset NFTBAN_MAIL_RECIPIENT
export STATS_EMAIL_ENABLED=true STATS_EMAIL_RECIPIENTS='r@test.example'
nftban_mail_detect_mta() { echo sendmail; }
_health_eval_communication_component c l r; echo \"CODE=\$c\"; printf '%s\n' \"\$l\"")
echo "$r" | grep -q 'CODE=0' && ! echo "$r" | grep -q 'WARN' && ! echo "$r" | grep -q 'MISSING_RECIPIENT' \
  && ok "row2 report recipient + transport -> CODE=0, not WARN, not MISSING_RECIPIENT" || no "row2: $r"

# 3. WARN transport-none: STATS_EMAIL_ENABLED=true + recipient set + transport none
#    -> CODE=1 WARN TRANSPORT_UNAVAILABLE + Fix/Verify remediation lines
r=$(bash -c "$(prelude)
unset NFTBAN_MAIL_RECIPIENT
export STATS_EMAIL_ENABLED=true STATS_EMAIL_RECIPIENTS='r@test.example'
nftban_mail_detect_mta() { echo none; }
_health_eval_communication_component c l r; echo \"CODE=\$c\"; printf '%s\n' \"\$l\"")
echo "$r" | grep -q 'CODE=1' && echo "$r" | grep -q 'WARN' && echo "$r" | grep -q 'TRANSPORT_UNAVAILABLE' \
  && echo "$r" | grep -q 'nftban mail setup' && echo "$r" | grep -q 'nftban mail test' \
  && ok "row3 transport none -> CODE=1 WARN TRANSPORT_UNAVAILABLE + Fix/Verify" || no "row3: $r"

# 4. WARN misconfig: STATS_EMAIL_ENABLED=true + NO recipient anywhere
#    -> CODE=1 MISSING_RECIPIENT with misconfig wording (NOT the delivery-failure wording)
r=$(bash -c "$(prelude)
unset NFTBAN_MAIL_RECIPIENT STATS_EMAIL_RECIPIENTS
export STATS_EMAIL_ENABLED=true
nftban_mail_detect_mta() { echo sendmail; }
_health_eval_communication_component c l r; echo \"CODE=\$c\"; printf '%s\n' \"\$l\"")
echo "$r" | grep -q 'CODE=1' && echo "$r" | grep -q 'MISSING_RECIPIENT' \
  && echo "$r" | grep -q 'email reports enabled but no recipient configured' \
  && ! echo "$r" | grep -q 'notifications generated but not deliverable' \
  && ok "row4 enabled + no recipient -> CODE=1 MISSING_RECIPIENT + misconfig wording" || no "row4: $r"

# 5. REPORT-ONLY recipient not mislabeled: report recipient set, general NFTBAN_MAIL_RECIPIENT empty,
#    transport present -> NOT MISSING_RECIPIENT (assert the negative)
r=$(bash -c "$(prelude)
unset NFTBAN_MAIL_RECIPIENT
export STATS_EMAIL_ENABLED=true STATS_EMAIL_RECIPIENTS='r@test.example'
nftban_mail_detect_mta() { echo sendmail; }
_health_eval_communication_component c l r; echo \"CODE=\$c\"; printf '%s\n' \"\$l\"")
! echo "$r" | grep -q 'MISSING_RECIPIENT' \
  && ok "row5 report-only recipient -> not mislabeled MISSING_RECIPIENT" || no "row5: $r"

# 6. CONF-FILE PATH: STATS_EMAIL_ENABLED="true" in conf.d/stats.conf (env unset), no recipient
#    -> CODE=1 WARN (proves the check reads conf.d/stats.conf, not just env)
r=$(bash -c "$(prelude)
unset NFTBAN_MAIL_RECIPIENT STATS_EMAIL_ENABLED STATS_EMAIL_RECIPIENTS
printf 'STATS_EMAIL_ENABLED=\"true\"\n' > \"\$NFTBAN_CONFIG_DIR/conf.d/stats.conf\"
nftban_mail_detect_mta() { echo sendmail; }
_health_eval_communication_component c l r; echo \"CODE=\$c\"; printf '%s\n' \"\$l\"")
echo "$r" | grep -q 'CODE=1' && echo "$r" | grep -q 'WARN' \
  && ok "row6 STATS_EMAIL_ENABLED in conf.d/stats.conf -> CODE=1 WARN" || no "row6: $r"

# 7. OTHER PRODUCERS regression: STATS_EMAIL disabled, MAIL_ENABLED=true in conf.d/mail.conf, no recipient
#    -> still CODE=1 WARN (other producers unaffected by the re-key)
r=$(bash -c "$(prelude)
unset NFTBAN_MAIL_RECIPIENT STATS_EMAIL_ENABLED STATS_EMAIL_RECIPIENTS
printf 'MAIL_ENABLED=true\n' > \"\$NFTBAN_CONFIG_DIR/conf.d/mail.conf\"
nftban_mail_detect_mta() { echo sendmail; }
_health_eval_communication_component c l r; echo \"CODE=\$c\"; printf '%s\n' \"\$l\"")
echo "$r" | grep -q 'CODE=1' && echo "$r" | grep -q 'WARN' \
  && ok "row7 mail.conf MAIL_ENABLED producer -> still CODE=1 WARN" || no "row7: $r"

echo "----"
# 8. (Deputy-2 ISSUE-1) report producer keyed on its OWN recipient: STATS_EMAIL_ENABLED=true +
#    empty STATS_EMAIL_RECIPIENTS + a GENERAL recipient set + transport -> WARN misconfig, NOT CLEAN
#    (the general recipient must NOT mask the missing report recipient; reports self-deliver only).
r=$(bash -c "$(prelude)
unset STATS_EMAIL_RECIPIENTS
export STATS_EMAIL_ENABLED=true NFTBAN_MAIL_RECIPIENT='general@test.example'
nftban_mail_detect_mta() { echo sendmail; }
_health_eval_communication_component c l r; echo \"CODE=\$c\"; printf '%s\n' \"\$l\"")
echo "$r" | grep -q 'CODE=1' && echo "$r" | grep -q 'email reports enabled but no recipient configured' \
  && ok "row8 report producer + general recipient but no report recipient -> WARN misconfig (not false-CLEAN)" || no "row8: $r"

# 9. (Deputy-3 regression) stray STATS_EMAIL_RECIPIENTS must NOT mask a non-report producer's missing
#    recipient: RBL producer enabled, general recipient empty, STATS_EMAIL_ENABLED unset (auto-reports
#    NOT a producer), STATS_EMAIL_RECIPIENTS set, transport present -> WARN (rbl can't deliver), NOT CLEAN.
r=$(bash -c "$(prelude)
unset NFTBAN_MAIL_RECIPIENT STATS_EMAIL_ENABLED
export STATS_EMAIL_RECIPIENTS='stray@test.example'
mkdir -p \"\$NFTBAN_CONFIG_DIR/conf.d/rbl\"; printf 'NFTBAN_RBL_ENABLED=\"YES\"\n' > \"\$NFTBAN_CONFIG_DIR/conf.d/rbl/main.conf\"
nftban_mail_detect_mta() { echo sendmail; }
_health_eval_communication_component c l r; echo \"CODE=\$c\"; printf '%s\n' \"\$l\"")
echo "$r" | grep -q 'CODE=1' && echo "$r" | grep -q 'MISSING_RECIPIENT' && echo "$r" | grep -q 'rbl-alerts' \
  && ok "row9 stray report recipient does NOT mask rbl missing-recipient -> WARN preserved" || no "row9: $r"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
