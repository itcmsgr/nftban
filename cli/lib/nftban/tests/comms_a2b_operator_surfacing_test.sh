#!/usr/bin/env bash
# =============================================================================
# NFTBan - A2b central-comms operator surfacing (consume layer)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="comms_a2b_operator_surfacing_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-06"
# meta:description="A2b consume layer: nftban_health_check_communication reads A2a state and reports CLEAN (recipient+transport) / COMMUNICATION_CONFIG_MISSING_RECIPIENT / COMMUNICATION_TRANSPORT_UNAVAILABLE / COMMUNICATION_SPOOL_BACKLOG / COMMUNICATION_LAST_SEND_FAILED; status summary shows transport/recipient/spool/last-failure; stats comms prints the mail.prom counters and degrades gracefully when mail.prom is missing. Re-runs A0/self-test/A1/A1b/A2a. Hermetic: isolated tempdir, no real mail, no network."
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,find,awk"
# meta:inventory.env_vars="NFTBAN_MAIL_METHOD,NFTBAN_MAIL_RECIPIENT,NFTBAN_MAIL_METRICS_FILE"
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

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  [PASS] $1"; }
no() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }

echo "=== A2b central-comms operator surfacing ==="
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Extract the two self-containable functions (the full files carry heavier deps).
HFN="$WORK/hc.sh"; awk '/^nftban_health_check_communication\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$MODULES" > "$HFN"
SFN="$WORK/sc.sh"; awk '/^nftban_stats_cmd_comms\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$STATS" > "$SFN"
grep -q 'nftban_health_check_communication' "$HFN" && ok "extracted health check fn" || no "extract health fn"
grep -q 'nftban_stats_cmd_comms' "$SFN" && ok "extracted stats comms fn" || no "extract stats fn"

prelude() {
  cat <<EOF
export NFTBAN_DATA_DIR="$WORK/data" NFTBAN_CONFIG_DIR="$WORK/etc" NFTBAN_RUN_DIR="$WORK/run" NFTBAN_LOG_DIR="$WORK/log" NFTBAN_LIB_DIR="$REPO/cli/lib/nftban"
mkdir -p "\$NFTBAN_DATA_DIR" "\$NFTBAN_CONFIG_DIR/conf.d" "\$NFTBAN_RUN_DIR" "\$NFTBAN_LOG_DIR" "\$NFTBAN_DATA_DIR/metrics/counters"
declare -A NFTBAN_HEALTH_RESULTS NFTBAN_HEALTH_ISSUES; declare -a NFTBAN_HEALTH_ERRORS
HEALTH_OK=0; HEALTH_WARNING=1; HEALTH_ERROR=2
source "$MAIL" >/dev/null 2>&1 || true
source "$HFN" >/dev/null 2>&1 || true
set +e; set +o pipefail
EOF
}
# Deterministic "no transport": override the detector to none (a host may run a real MTA).
NONE_BINS='nftban_mail_detect_mta() { echo none; }'

hprobe() { bash -c "$(prelude)
$1
nftban_health_check_communication; rc=\$?
echo \"RC=\$rc ISSUE=\${NFTBAN_HEALTH_ISSUES[communication]:-}\""; }

# health: CLEAN when recipient + emulate transport
r=$(hprobe "export NFTBAN_MAIL_METHOD=emulate NFTBAN_MAIL_RECIPIENT='rcpt@test.example'")
echo "$r" | grep -q '^RC=0 ' && ok "health CLEAN (recipient + transport)" || no "health not clean: $r"
# health: missing recipient while an ALERT PRODUCER is enabled (v1.218.1 policy → WARN).
# (mail.conf with MAIL_ENABLED=true is a producer; without a producer this is INFO, tested in the v1.218.1 suite.)
r=$(hprobe "unset NFTBAN_MAIL_RECIPIENT; export NFTBAN_MAIL_METHOD=emulate; printf 'MAIL_ENABLED=true\n' > \"\$NFTBAN_CONFIG_DIR/conf.d/mail.conf\"")
echo "$r" | grep -q 'COMMUNICATION_CONFIG_MISSING_RECIPIENT' && [[ "$r" != RC=0* ]] && ok "health WARN: missing recipient (producer enabled)" || no "missing recipient not flagged: $r"
# health: transport unavailable while an alert producer is enabled → WARN
r=$(hprobe "export NFTBAN_MAIL_RECIPIENT='rcpt@test.example'; printf 'MAIL_ENABLED=true\n' > \"\$NFTBAN_CONFIG_DIR/conf.d/mail.conf\"; $NONE_BINS")
echo "$r" | grep -q 'COMMUNICATION_TRANSPORT_UNAVAILABLE' && ok "health WARN: transport unavailable (producer enabled)" || no "transport-unavailable not flagged: $r"
# health: spool backlog
r=$(hprobe "export NFTBAN_MAIL_METHOD=emulate NFTBAN_MAIL_RECIPIENT='rcpt@test.example'; mkdir -p \"\$NFTBAN_DATA_DIR/mailspool\"; : > \"\$NFTBAN_DATA_DIR/mailspool/x.mail\"")
echo "$r" | grep -q 'COMMUNICATION_SPOOL_BACKLOG' && ok "health WARN: spool backlog" || no "spool backlog not flagged: $r"
# health: last send failed (failure newer than success)
r=$(hprobe "export NFTBAN_MAIL_METHOD=emulate NFTBAN_MAIL_RECIPIENT='rcpt@test.example'; echo \$(date +%s) > \"\$NFTBAN_DATA_DIR/metrics/counters/mail_last_failure_ts\"; echo 0 > \"\$NFTBAN_DATA_DIR/metrics/counters/mail_last_success_ts\"")
echo "$r" | grep -q 'COMMUNICATION_LAST_SEND_FAILED' && echo "$r" | grep -q 'COMMUNICATION_SEND_FAILURE' && ok "health WARN: last send failed + send failure" || no "last-failure not flagged: $r"

# status consume: transport + summary fields
s=$(bash -c "$(prelude)
export NFTBAN_MAIL_METHOD=emulate NFTBAN_MAIL_RECIPIENT='rcpt@test.example'
t=\$(nftban_mail_detect_mta 2>/dev/null); echo \"T=\$t\"; nftban_mail_status_summary 2>/dev/null")
echo "$s" | grep -q 'T=emulate' && echo "$s" | grep -q 'Recipient:' && echo "$s" | grep -q 'Spool: depth=' && echo "$s" | grep -q 'Last success ts:' && ok "status consume shows transport+recipient+spool+last" || no "status consume incomplete: $s"

# stats comms: counters present from a mail.prom carrying the A2a metric names
PROM="$WORK/mail.prom"
cat > "$PROM" <<'PROMEOF'
nftban_mail_send_success_total{transport="curl"} 3
nftban_mail_send_failures_total{transport="curl"} 1
nftban_mail_spool_depth 2
nftban_mail_spool_oldest_age_seconds 120
nftban_mail_last_failure_timestamp 1700000000
nftban_mail_transport_selected{transport="curl"} 1
PROMEOF
so=$(bash -c "source '$SFN'; NFTBAN_MAIL_METRICS_FILE='$PROM' nftban_stats_cmd_comms 2>/dev/null")
c=0; for m in nftban_mail_send_success_total nftban_mail_send_failures_total nftban_mail_spool_depth nftban_mail_spool_oldest_age_seconds nftban_mail_last_failure_timestamp nftban_mail_transport_selected; do echo "$so" | grep -q "$m" && c=$((c+1)); done
[[ "$c" -eq 6 ]] && ok "stats comms shows all 6 counters" || no "stats comms only $c/6 counters"
# stats comms: graceful when mail.prom missing
sm=$(bash -c "source '$SFN'; NFTBAN_MAIL_METRICS_FILE='$WORK/nope.prom' nftban_stats_cmd_comms 2>/dev/null")
echo "$sm" | grep -q 'no mail metrics yet' && ok "stats comms graceful on missing mail.prom" || no "stats comms not graceful: $sm"

# render: communication surfaces in the OPTIONAL FEATURES terminal render (live path via
# cmd_health_core.sh) when a result is set.
RENDER="$REPO/cli/lib/nftban/core/nftban_health_render.sh"
rout=$(bash -c "
declare -A NFTBAN_HEALTH_RESULTS NFTBAN_HEALTH_ISSUES
declare -a NFTBAN_HEALTH_ERRORS NFTBAN_HEALTH_WARNINGS
HEALTH_OK=0; HEALTH_WARNING=1; HEALTH_ERROR=2
NFTBAN_HEALTH_RESULTS[communication]=1
NFTBAN_HEALTH_ISSUES[communication]='COMMUNICATION_SPOOL_BACKLOG: 1 spooled'
source '$RENDER' >/dev/null 2>&1 || true
set +e; set +o pipefail
nftban_health_render_terminal 2>/dev/null | grep -i communication")
echo "$rout" | grep -qi 'Communication' && ok "health render lists Communication (OPTIONAL FEATURES)" || no "render missing Communication: $rout"

# ratchet + prior suites
out=$( cd "$REPO" && bash scripts/ci/check-comms-direct-send.sh 2>&1 )
echo "$out" | grep -q '0/4 DEBT' && echo "$out" | grep -q 'PASS' && ok "A0 guard still 0/4 PASS" || no "A0 guard regressed"
( cd "$REPO" && bash cli/lib/nftban/tests/comms_no_direct_send_guard_a0_test.sh >/dev/null 2>&1 ) && ok "A0 self-test still passes" || no "A0 self-test regressed"
( cd "$REPO" && bash cli/lib/nftban/tests/comms_a1_centralization_test.sh >/dev/null 2>&1 ) && ok "A1 test still passes" || no "A1 test regressed"
( cd "$REPO" && bash cli/lib/nftban/tests/comms_a1b_emulate_test.sh >/dev/null 2>&1 ) && ok "A1b test still passes" || no "A1b test regressed"
( cd "$REPO" && bash cli/lib/nftban/tests/comms_a2a_delivery_truth_test.sh >/dev/null 2>&1 ) && ok "A2a test still passes" || no "A2a test regressed"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
