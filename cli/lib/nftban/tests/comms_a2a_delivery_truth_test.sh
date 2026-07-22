#!/usr/bin/env bash
# =============================================================================
# NFTBan - A2a central-comms delivery-truth (produce layer)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="comms_a2a_delivery_truth_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-06"
# meta:description="A2a produce layer: emulate send writes a delivery-log success line (redacted recipient, no secret); failed/spooled primitives write their lines + last-failure state; retention cap bounds the log; mail metrics expose spool_oldest_age/last_failure_timestamp/transport_selected; validate comms (dry-run) catches missing recipient + incomplete SMTP and stays truthful; mail status summary shows the new fields; A0 0/4, A0 self-test, A1, A1b all still pass. Hermetic: isolated tempdir, no real mail, no network."
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,find"
# meta:inventory.env_vars="NFTBAN_MAIL_METHOD,NFTBAN_MAIL_DELIVERY_LOG,NFTBAN_MAIL_DELIVERY_LOG_MAX,NFTBAN_MAIL_RECIPIENT,NFTBAN_SMTP_PASS"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="comms_a2a_delivery_truth_test"
# meta:ta.owner="comms"
# meta:ta.module="mail"
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

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../../../.." && pwd)"
MAIL="$REPO/cli/lib/nftban/core/nftban_mail.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  [PASS] $1"; }
no() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }

echo "=== A2a central-comms delivery-truth ==="
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
LEAK_PROBE="nftban-a2a-leakprobe-marker"   # non-secret marker placed in NFTBAN_SMTP_PASS

prelude() {
  cat <<EOF
export NFTBAN_DATA_DIR="$WORK/data" NFTBAN_CONFIG_DIR="$WORK/etc" NFTBAN_RUN_DIR="$WORK/run" NFTBAN_LOG_DIR="$WORK/log" NFTBAN_LIB_DIR="$REPO/cli/lib/nftban"
mkdir -p "\$NFTBAN_DATA_DIR" "\$NFTBAN_CONFIG_DIR" "\$NFTBAN_RUN_DIR" "\$NFTBAN_LOG_DIR"
EOF
}

DLOG="$WORK/delivery.jsonl"

# 1) emulate success → delivery-log success line (integration through the retry wrapper)
bash -c "$(prelude)
export NFTBAN_MAIL_METHOD=emulate NFTBAN_MAIL_RECIPIENT='rcpt@test.example' NFTBAN_MAIL_DELIVERY_LOG='$DLOG' NFTBAN_SMTP_PASS='$LEAK_PROBE'
source '$MAIL' >/dev/null 2>&1 || true; set +e; set +o pipefail
nftban_mail_send_with_retry 'body' 'rcpt@test.example' 'subj' >/dev/null 2>&1
" || true
grep -q '"result":"success"' "$DLOG" 2>/dev/null && ok "emulate success wrote delivery-log success line" || no "no success line"
# 5) recipient redacted (local-part@…, not full domain)
grep -q '"recipient":"rcpt@' "$DLOG" 2>/dev/null && ! grep -q 'rcpt@test.example' "$DLOG" 2>/dev/null && ok "recipient redacted in delivery-log" || no "recipient not redacted"
# 4) no secret in delivery-log
grep -q "$LEAK_PROBE" "$DLOG" 2>/dev/null && no "secret LEAKED into delivery-log" || ok "no secret in delivery-log"

# 2) failed primitive → failed line + last-failure state ; 3) spooled line
bash -c "$(prelude)
export NFTBAN_MAIL_DELIVERY_LOG='$DLOG'
source '$MAIL' >/dev/null 2>&1 || true; set +e; set +o pipefail
_mail_delivery_log 'failed' 'curl' 'rcpt@test.example' 'send_failed_rc_1'
_mail_record_last_failure 'send_failed_rc_1'
_mail_delivery_log 'spooled' 'curl' 'rcpt@test.example' 'after_3_retries'
" || true
grep -q '"result":"failed"' "$DLOG" 2>/dev/null && ok "failed primitive wrote failed line" || no "no failed line"
grep -q '"result":"spooled"' "$DLOG" 2>/dev/null && ok "spooled primitive wrote spooled line" || no "no spooled line"
[[ -s "$WORK/data/metrics/counters/mail_last_failure_ts" ]] && ok "last-failure ts persisted" || no "last-failure ts missing"
grep -q 'send_failed_rc_1' "$WORK/data/metrics/counters/mail_last_failure_reason" 2>/dev/null && ok "last-failure reason persisted" || no "last-failure reason missing"

# 6) retention cap
CAP="$WORK/cap.jsonl"
bash -c "$(prelude)
export NFTBAN_MAIL_DELIVERY_LOG='$CAP' NFTBAN_MAIL_DELIVERY_LOG_MAX=5
source '$MAIL' >/dev/null 2>&1 || true; set +e; set +o pipefail
for i in \$(seq 1 20); do _mail_delivery_log 'success' 'emulate' 'r@t.example' \"n\$i\"; done
"
capn=$(wc -l < "$CAP" 2>/dev/null | tr -d ' ')
[[ "${capn:-0}" -le 5 ]] && ok "retention cap bounds delivery-log ($capn<=5)" || no "retention cap failed ($capn)"

# 7-9) new metrics present
MET="$WORK/mail.prom"
bash -c "$(prelude)
export NFTBAN_MAIL_METRICS_FILE='$MET' NFTBAN_MAIL_SPOOL_DIR='$WORK/spool'
mkdir -p '$WORK/spool'; : > '$WORK/spool/old.mail'
source '$MAIL' >/dev/null 2>&1 || true; set +e; set +o pipefail
_mail_write_metrics
"
grep -q 'nftban_mail_spool_oldest_age_seconds' "$MET" 2>/dev/null && ok "metric: spool_oldest_age_seconds" || no "missing spool_oldest_age"
grep -q 'nftban_mail_last_failure_timestamp' "$MET" 2>/dev/null && ok "metric: last_failure_timestamp" || no "missing last_failure_timestamp"
grep -q 'nftban_mail_transport_selected{transport=' "$MET" 2>/dev/null && ok "metric: transport_selected" || no "missing transport_selected"

# 10-12) validate comms (dry-run) catches
mrc=$(bash -c "$(prelude)
unset NFTBAN_MAIL_RECIPIENT; export NFTBAN_MAIL_METHOD=emulate
source '$MAIL' >/dev/null 2>&1 || true; set +e; set +o pipefail
nftban_mail_test_dryrun '' >/dev/null 2>&1; echo \$?")
[[ "$mrc" != "0" ]] && ok "validate comms catches missing recipient (rc!=0)" || no "missing recipient not caught"
src=$(bash -c "$(prelude)
export NFTBAN_MAIL_RECIPIENT='r@t.example' NFTBAN_MAIL_METHOD=curl NFTBAN_SMTP_HOST='smtp.test' NFTBAN_SMTP_USER='u@t' NFTBAN_SMTP_PASS=''
source '$MAIL' >/dev/null 2>&1 || true; set +e; set +o pipefail
nftban_mail_test_dryrun '' 2>/dev/null | grep -c 'SMTP incomplete'")
[[ "${src:-0}" -ge 1 ]] && ok "validate comms catches incomplete SMTP (user w/o pass)" || no "incomplete SMTP not caught"

# 15) mail status summary shows new fields
sout=$(bash -c "$(prelude)
export NFTBAN_MAIL_RECIPIENT='r@t.example'
source '$MAIL' >/dev/null 2>&1 || true; set +e; set +o pipefail
nftban_mail_status_summary 2>/dev/null")
echo "$sout" | grep -q 'Recipient:' && echo "$sout" | grep -q 'Spool: depth=' && echo "$sout" | grep -q 'Last success ts:' && ok "mail status summary shows new fields" || no "status summary fields missing"

# 16-19) ratchet + prior suites unaffected
out=$( cd "$REPO" && bash scripts/ci/check-comms-direct-send.sh 2>&1 )
echo "$out" | grep -q '0/4 DEBT' && echo "$out" | grep -q 'PASS' && ok "A0 guard still 0/4 PASS" || no "A0 guard regressed"
( cd "$REPO" && bash cli/lib/nftban/tests/comms_no_direct_send_guard_a0_test.sh >/dev/null 2>&1 ) && ok "A0 self-test still passes" || no "A0 self-test regressed"
( cd "$REPO" && bash cli/lib/nftban/tests/comms_a1_centralization_test.sh >/dev/null 2>&1 ) && ok "A1 test still passes" || no "A1 test regressed"
( cd "$REPO" && bash cli/lib/nftban/tests/comms_a1b_emulate_test.sh >/dev/null 2>&1 ) && ok "A1b test still passes" || no "A1b test regressed"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
