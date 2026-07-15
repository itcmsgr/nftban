#!/usr/bin/env bash
# =============================================================================
# NFTBan - RBL/Tunnel producer-recipient accuracy (central-comms deliverability)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="comms_rbl_tunnel_producer_recipient_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-07"
# meta:description="Central-comms deliverability now credits each producer's OWN recipient: rbl-alerts↔NFTBAN_RBL_ALERT_EMAIL, tunnel-alerts↔NFTBAN_TUNNEL_ALERT_EMAIL (both fall back to the general NFTBAN_MAIL_RECIPIENT), auto-reports↔STATS_EMAIL_RECIPIENTS, mail-enabled↔general. A producer with its own recipient set is deliverable even when the general recipient is empty (no false COMMUNICATION_CONFIG_MISSING_RECIPIENT); a producer's own recipient satisfies ONLY that producer (no cross-masking). Hermetic: extracted fns, no real mail, no network, no DNSBL queries."
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,awk"
# meta:inventory.env_vars="NFTBAN_RBL_ALERT_EMAIL,NFTBAN_TUNNEL_ALERT_EMAIL,NFTBAN_MAIL_RECIPIENT,STATS_EMAIL_RECIPIENTS"
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

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  [PASS] $1"; }
no() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }

echo "=== RBL/Tunnel producer-recipient accuracy ==="
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
CFN="$WORK/comps.sh"
awk '/^nftban_health_check_communication\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$MODULES" >  "$CFN"
awk '/^_health_eval_communication_component\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$MODULES" >> "$CFN"

prelude() {
  cat <<EOF
export NFTBAN_DATA_DIR="$WORK/data" NFTBAN_CONFIG_DIR="$WORK/etc" NFTBAN_RUN_DIR="$WORK/run" NFTBAN_LOG_DIR="$WORK/log" NFTBAN_LIB_DIR="$REPO/cli/lib/nftban"
mkdir -p "\$NFTBAN_DATA_DIR" "\$NFTBAN_CONFIG_DIR/conf.d/rbl" "\$NFTBAN_RUN_DIR" "\$NFTBAN_LOG_DIR"
declare -A NFTBAN_HEALTH_RESULTS NFTBAN_HEALTH_ISSUES; declare -a NFTBAN_HEALTH_ERRORS
HEALTH_OK=0; HEALTH_WARNING=1; HEALTH_ERROR=2
unset NFTBAN_MAIL_RECIPIENT STATS_EMAIL_ENABLED STATS_EMAIL_RECIPIENTS NFTBAN_RBL_ALERT_EMAIL NFTBAN_TUNNEL_ALERT_EMAIL NFTBAN_ALERT_EMAIL
source "$MAIL" >/dev/null 2>&1 || true
source "$CFN" >/dev/null 2>&1 || true
systemctl() { return 1; }
rbl_on() { printf 'NFTBAN_RBL_ENABLED="YES"\n' > "\$NFTBAN_CONFIG_DIR/conf.d/rbl/main.conf"; }
set +e; set +o pipefail
EOF
}
run() { bash -c "$(prelude)
$1
nftban_mail_detect_mta() { echo ${2:-sendmail}; }
_health_eval_communication_component c l r; echo \"CODE=\$c\"; printf '%s\n' \"\$l\""; }

# 1. RBL enabled + RBL_ALERT_EMAIL set + no general + transport -> CLEAN (THE FIX)
r=$(run "rbl_on; export NFTBAN_RBL_ALERT_EMAIL='rbl@test.example'")
echo "$r" | grep -q 'CODE=0' && ! echo "$r" | grep -q 'MISSING_RECIPIENT' && ok "RBL + own recipient + no general -> CLEAN (was false-WARN)" || no "case1: $r"

# 2. RBL enabled + no RBL recipient + general set + transport -> CLEAN
r=$(run "rbl_on; export NFTBAN_MAIL_RECIPIENT='gen@test.example'")
echo "$r" | grep -q 'CODE=0' && ! echo "$r" | grep -q 'MISSING_RECIPIENT' && ok "RBL + no own + general -> CLEAN" || no "case2: $r"

# 3. RBL enabled + no RBL recipient + no general -> WARN
r=$(run "rbl_on")
echo "$r" | grep -q 'CODE=1' && echo "$r" | grep -q 'MISSING_RECIPIENT' && echo "$r" | grep -q 'rbl-alerts' && ok "RBL + no own + no general -> WARN MISSING_RECIPIENT" || no "case3: $r"

# 3b. RBL_ALERT_EMAIL read from conf.d/rbl/main.conf (not just env)
r=$(run "rbl_on; printf 'NFTBAN_RBL_ALERT_EMAIL=\"rblconf@test.example\"\n' >> \"\$NFTBAN_CONFIG_DIR/conf.d/rbl/main.conf\"")
echo "$r" | grep -q 'CODE=0' && ! echo "$r" | grep -q 'MISSING_RECIPIENT' && ok "RBL recipient read from conf.d/rbl/main.conf -> CLEAN" || no "case3b: $r"

# 4. Tunnel enabled (own recipient) + no general + transport -> CLEAN (THE FIX)
r=$(run "export NFTBAN_TUNNEL_ALERT_EMAIL='tun@test.example'")
echo "$r" | grep -q 'CODE=0' && ! echo "$r" | grep -q 'MISSING_RECIPIENT' && ok "Tunnel + own recipient + no general -> CLEAN (was false-WARN)" || no "case4: $r"

# 5. Tunnel enabled + transport none -> WARN TRANSPORT
r=$(run "export NFTBAN_TUNNEL_ALERT_EMAIL='tun@test.example'" none)
echo "$r" | grep -q 'CODE=1' && echo "$r" | grep -q 'TRANSPORT_UNAVAILABLE' && ok "Tunnel + own recipient + no transport -> WARN TRANSPORT" || no "case5: $r"

# 6. RBL enabled + RBL_ALERT_EMAIL set + transport none -> WARN TRANSPORT
r=$(run "rbl_on; export NFTBAN_RBL_ALERT_EMAIL='rbl@test.example'" none)
echo "$r" | grep -q 'CODE=1' && echo "$r" | grep -q 'TRANSPORT_UNAVAILABLE' && ok "RBL + own recipient + no transport -> WARN TRANSPORT" || no "case6: $r"

# 7. CROSS-MASK: RBL (no own) + stray STATS_EMAIL_RECIPIENTS (auto-reports NOT enabled) + no general -> WARN
r=$(run "rbl_on; export STATS_EMAIL_RECIPIENTS='reports@test.example'")
echo "$r" | grep -q 'CODE=1' && echo "$r" | grep -q 'rbl-alerts' && ok "cross-mask: stray STATS_EMAIL_RECIPIENTS does NOT satisfy RBL -> WARN" || no "case7: $r"

# 8. CROSS-MASK: mail-enabled + RBL_ALERT_EMAIL set + no general -> WARN (RBL email must not satisfy mail-enabled)
r=$(run "printf 'MAIL_ENABLED=true\n' > \"\$NFTBAN_CONFIG_DIR/conf.d/mail.conf\"; export NFTBAN_RBL_ALERT_EMAIL='rbl@test.example'")
echo "$r" | grep -q 'CODE=1' && echo "$r" | grep -q 'mail-enabled' && ok "cross-mask: RBL recipient does NOT satisfy mail-enabled -> WARN" || no "case8: $r"

# 9. CROSS-MASK: tunnel own recipient must not satisfy an RBL that lacks its own + no general -> WARN
r=$(run "rbl_on; export NFTBAN_TUNNEL_ALERT_EMAIL='tun@test.example'")
echo "$r" | grep -q 'CODE=1' && echo "$r" | grep -q 'rbl-alerts' && ok "cross-mask: tunnel recipient does NOT satisfy RBL -> WARN (RBL undeliverable)" || no "case9: $r"

# --- regressions ---
( cd "$REPO" && bash cli/lib/nftban/tests/comms_producer_signal_accuracy_test.sh >/dev/null 2>&1 ) && ok "producer_signal_accuracy still passes" || no "producer_signal regressed"
( cd "$REPO" && bash cli/lib/nftban/tests/comms_a2b_operator_surfacing_test.sh >/dev/null 2>&1 ) && ok "A2b still passes" || no "A2b regressed"
( cd "$REPO" && bash cli/lib/nftban/tests/comms_a2r_rbl_visibility_test.sh >/dev/null 2>&1 ) && ok "A2r still passes" || no "A2r regressed"
o=$( cd "$REPO" && bash scripts/ci/check-comms-direct-send.sh 2>&1 ); echo "$o" | grep -q '0/4 DEBT' && echo "$o" | grep -q 'PASS' && ok "A0 guard 0/4" || no "A0 guard regressed"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
