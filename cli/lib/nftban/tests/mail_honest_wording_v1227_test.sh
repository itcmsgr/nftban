#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.227 Lane-1 — MAIL-F4b honest delivery wording (claims-truth)
# =============================================================================
# meta:name="mail_honest_wording_v1227_test"
# meta:type="test"
# meta:version="1.227.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="MAIL claims-truth: transport-accept paths that only know curl/MTA returned 0 must not claim the mail was 'sent successfully'/delivered. Asserts the provably-false success strings are gone and replaced with 'submitted … (delivery not confirmed)', the RBL honest model is untouched, and the send exit code is unchanged (wording-only, no control-flow change)."
# meta:input="None (greps mail/report sources read-only + drives nftban_mail_send via emulate; no network)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,grep"
# meta:inventory.files="cli/lib/nftban/core/nftban_mail.sh,cli/lib/nftban/cli/cmd_report.sh,cli/lib/nftban/core/nftban_report_email.sh,cli/lib/nftban/core/nftban_login_alert.sh,cli/lib/nftban/core/nftban_rbl.sh"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars="NFTBAN_MAIL_METHOD,NFTBAN_MAIL_EMULATE_SINK"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="mail_honest_wording_v1227_test"
# meta:ta.owner="mail"
# meta:ta.module="mail-honest-wording"
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

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
MAIL="$ROOT/cli/lib/nftban/core/nftban_mail.sh"
# shellcheck disable=SC2034  # consumed by assert eval
REPORT="$ROOT/cli/lib/nftban/cli/cmd_report.sh"
# shellcheck disable=SC2034  # consumed by assert eval
REPORT_EMAIL="$ROOT/cli/lib/nftban/core/nftban_report_email.sh"
# shellcheck disable=SC2034  # consumed by assert eval
LOGIN_ALERT="$ROOT/cli/lib/nftban/core/nftban_login_alert.sh"
# shellcheck disable=SC2034  # consumed by assert eval
RBL="$ROOT/cli/lib/nftban/core/nftban_rbl.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }
assert() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

echo "=== mail_honest_wording_v1227 ==="

# --- NO false DELIVERED/sent-successfully claim on transport-accept paths ---
assert "NO 'sent successfully' in nftban_mail.sh"        '! grep -q "Email sent successfully" "$MAIL"'
assert "NO 'Email sent to' in cmd_report.sh"             '! grep -q "\[SUCCESS\] Email sent to" "$REPORT"'
assert "NO 'Report sent to' in nftban_report_email.sh"   '! grep -q "\[SUCCESS\] Report sent to" "$REPORT_EMAIL"'
assert "NO 'digest sent successfully' in login_alert.sh" '! grep -q "digest sent successfully" "$LOGIN_ALERT"'

# --- honest 'submitted / delivery not confirmed' wording present at each site ---
assert "SUBMITTED wording in nftban_mail.sh"             'grep -q "Email submitted to transport for.*(delivery not confirmed)" "$MAIL"'
assert "SUBMITTED wording in cmd_report.sh (x2)"         '[[ "$(grep -c "Email submitted to .*(delivery not confirmed)" "$REPORT")" -eq 2 ]]'
assert "SUBMITTED wording in nftban_report_email.sh"     'grep -q "Report submitted to .*(delivery not confirmed)" "$REPORT_EMAIL"'
assert "SUBMITTED wording in login_alert.sh"             'grep -q "Login digest submitted .*delivery not confirmed" "$LOGIN_ALERT"'

# --- RBL honest model preserved (untouched) ---
assert "RBL honest 'degraded' model intact"             'grep -q "degraded" "$RBL"'

# --- wording-only: the changed lines are still echo/log statements (no exit/return injected) ---
assert "mail.sh line stays an echo (no control-flow)"    'grep -q "echo \"✓ Email submitted to transport" "$MAIL"'
assert "login_alert stays a log call"                    'grep -q "nftban_login_alert_log \"Login digest submitted" "$LOGIN_ALERT"'

# --- behavioral: send exit code unchanged (emulate transport returns 0, no false-success text) ---
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT; mkdir -p "$SB/data"
# shellcheck disable=SC2034  # consumed by assert eval
out="$(
    NFTBAN_LIB_DIR="$ROOT/cli/lib/nftban" NFTBAN_DATA_DIR="$SB/data" \
    NFTBAN_MAIL_METHOD="emulate" NFTBAN_MAIL_EMULATE_SINK="$SB/sink.jsonl" \
    NFTBAN_MAIL_VALIDATE_RECIPIENTS="NO" \
    bash -c 'set -Eeuo pipefail; source "'"$MAIL"'"; nftban_mail_send "body" "to@example.test"; echo "RC=$?"' 2>&1
)" || true
assert "SEND_RC_UNCHANGED (emulate returns 0)"          'grep -q "RC=0" <<<"$out"'
assert "NO false 'sent successfully' in live output"    '! grep -q "sent successfully" <<<"$out"'

echo ""
echo "=== mail_honest_wording_v1227: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
