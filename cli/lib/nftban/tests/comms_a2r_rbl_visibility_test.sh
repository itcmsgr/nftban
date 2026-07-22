#!/usr/bin/env bash
# =============================================================================
# NFTBan - A2r RBL observe-only visibility + honesty label
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="comms_a2r_rbl_visibility_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-07"
# meta:description="A2r: RBL is surfaced observe-only — the DNSBL-only honesty label appears in rbl status + report data (advisory/reputation/not-blocking/cannot-determine-Proofpoint-iCloud-bounce); RBL alerts route through the central authority (nftban_mail_alert) so attempts land in the A2a delivery-log (proven compositionally under A1b emulate); no direct mail transport is introduced (A0 guard 0/4). Re-runs A2a/A2b. Hermetic: isolated tempdir, no real mail, no network, no new RBL probes."
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars="NFTBAN_MAIL_METHOD,NFTBAN_MAIL_DELIVERY_LOG,NFTBAN_MAIL_RECIPIENT"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="comms_a2r_rbl_visibility_test"
# meta:ta.owner="comms"
# meta:ta.module="rbl-alert-routing"
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
RBL="$REPO/cli/lib/nftban/core/nftban_rbl.sh"
CMD_RBL="$REPO/cli/lib/nftban/cli/cmd_rbl.sh"
RDATA="$REPO/cli/lib/nftban/lib/nftban_report_data.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  [PASS] $1"; }
no() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }

echo "=== A2r RBL observe-only visibility ==="
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# --- DNSBL-only honesty label (status + report) ---
grep -qi 'advisory reputation monitoring (observe-only), not firewall blocking' "$RBL" "$CMD_RBL" && ok "status: advisory/observe-only/not-blocking wording" || no "status advisory wording missing"
grep -qi 'cannot determine a provider-specific Proofpoint/iCloud bounce' "$RBL" "$CMD_RBL" && ok "status: DNSBL-only Proofpoint/iCloud honesty label" || no "status DNSBL honesty label missing"
grep -qi 'advisory — not blocked' "$RDATA" && ok "report: listed = advisory, not blocked" || no "report advisory wording missing"

# --- RBL alerts route through central authority (both send sites) ---
alerts=$(grep -c 'nftban_mail_alert' "$RBL")
[[ "${alerts:-0}" -ge 2 ]] && ok "both RBL send sites route via nftban_mail_alert ($alerts)" || no "RBL send sites not routed ($alerts)"

# --- no direct transport introduced in RBL (excluding comments) ---
send_pat='(\|[[:space:]]*(sendmail|mailx|msmtp))|(\bsendmail[[:space:]]+-t\b)|(\bmail[[:space:]]+-s[[:space:]])|(--mail-rcpt)'
if grep -nE "$send_pat" "$RBL" | grep -qvE '^[0-9]+:[[:space:]]*#'; then no "RBL introduced a direct transport send"; else ok "RBL has no direct transport send"; fi

# --- compositional: RBL's routing target (nftban_mail_alert) writes A2a delivery truth under emulate ---
DLOG="$WORK/delivery.jsonl"
bash -c "
export NFTBAN_DATA_DIR='$WORK/data' NFTBAN_CONFIG_DIR='$WORK/etc' NFTBAN_RUN_DIR='$WORK/run' NFTBAN_LOG_DIR='$WORK/log' NFTBAN_LIB_DIR='$REPO/cli/lib/nftban'
mkdir -p \"\$NFTBAN_DATA_DIR\" \"\$NFTBAN_CONFIG_DIR\" \"\$NFTBAN_RUN_DIR\" \"\$NFTBAN_LOG_DIR\"
export NFTBAN_MAIL_METHOD=emulate NFTBAN_MAIL_RECIPIENT='rcpt@test.example' NFTBAN_MAIL_DELIVERY_LOG='$DLOG'
source '$MAIL' >/dev/null 2>&1 || true; set +e; set +o pipefail
nftban_mail_alert '[NFTBAN LISTED] IP reputation' 'RBL advisory body' 'rcpt@test.example' >/dev/null 2>&1
" || true
grep -q '\"result\":\"success\"' "$DLOG" 2>/dev/null && ok "RBL alert path (nftban_mail_alert) writes delivery-log under emulate" || no "delivery-log not written by alert path"
grep -q 'rcpt@test.example' "$DLOG" 2>/dev/null && no "recipient not redacted in delivery-log" || ok "recipient redacted in delivery-log"

# --- RBL computed states remain (clean/listed/degraded) — consume-only, not extended ---
c=0; for s in clean listed degraded; do grep -qE "_rbl_state=.?${s}" "$CMD_RBL" && c=$((c+1)); done
[[ "$c" -ge 2 ]] && ok "RBL clean/listed/degraded states preserved ($c/3)" || no "RBL states missing ($c/3)"

# --- ratchet + prior suites ---
out=$( cd "$REPO" && bash scripts/ci/check-comms-direct-send.sh 2>&1 )
echo "$out" | grep -q '0/4 DEBT' && echo "$out" | grep -q 'PASS' && ok "A0 guard still 0/4 PASS" || no "A0 guard regressed"
( cd "$REPO" && bash cli/lib/nftban/tests/comms_a2a_delivery_truth_test.sh >/dev/null 2>&1 ) && ok "A2a test still passes" || no "A2a regressed"
( cd "$REPO" && bash cli/lib/nftban/tests/comms_a2b_operator_surfacing_test.sh >/dev/null 2>&1 ) && ok "A2b test still passes" || no "A2b regressed"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
