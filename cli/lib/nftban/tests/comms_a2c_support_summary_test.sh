#!/usr/bin/env bash
# =============================================================================
# NFTBan - A2c support-bundle sanitized comms/RBL summary
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="comms_a2c_support_summary_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-07"
# meta:description="A2c: _collect_communications writes a sanitized central-comms + RBL observe-only summary into the support bundle — comms section (transport/recipient/spool/last), delivery-log tail, and RBL section with the DNSBL-only honesty label. Reuses the existing redactor plus a narrow local _redact_comms: NFTBAN_SMTP_PASS / Auth User redacted, recipient local-part redacted, no secret marker. Driven with a nftban stub + fake delivery-log. Re-runs A2a/A2b/A2r. Hermetic: no real mail, no network, full SEC-P1-2 remains open."
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,sed"
# meta:inventory.env_vars="NFTBAN_MAIL_DELIVERY_LOG,NFTBAN_DATA_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="comms_a2c_support_summary_test"
# meta:ta.owner="comms"
# meta:ta.module="support"
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
SUPPORT="$REPO/cli/lib/nftban/cli/cmd_support.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  [PASS] $1"; }
no_fail() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }

echo "=== A2c support-bundle comms/RBL summary ==="
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
LEAK="LEAKMARK-not-a-real-secret-123"

# nftban stub: mail status leaks a recipient + Auth User + an SMTP pass; rbl status prints state.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/nftban" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "mail status") printf '%s\n' "Mail System: postfix" "  Recipient: alice@example.com" "  Auth User: relayuser@relay.example" "  NFTBAN_SMTP_PASS=$LEAK" "  Spool: depth=0 oldest_age_s=0" ;;
  "rbl status")  printf '%s\n' "RBL Monitoring Status" "  Enabled:      NO" "  Providers:    24 active" ;;
  *) echo stub ;;
esac
STUB
chmod +x "$WORK/bin/nftban"

# delivery-log with an A2a-shaped line
BDIR="$WORK/bundle"; mkdir -p "$BDIR"
DLOG="$WORK/delivery.jsonl"
printf '%s\n' '{"ts":"2026-07-07T00:00:00Z","transport":"emulate","recipient":"bob@…","result":"success","reason":""}' > "$DLOG"

# Extract the self-containable functions (sourcing the whole CLI file has heavy load-time deps).
FN="$WORK/fns.sh"
{
  awk '/^_redact_unavailable\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SUPPORT"
  awk '/^_redact_secrets\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SUPPORT"
  awk '/^_redact_comms\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SUPPORT"
  awk '/^_collect_communications\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SUPPORT"
  echo '_support_log() { :; }'
} > "$FN"
grep -q '_collect_communications' "$FN" && ok "extracted _collect_communications + redactors" || no_fail "extract failed"

# run _collect_communications with the stub in PATH
bash -c "
export PATH='$WORK/bin:'\$PATH NFTBAN_MAIL_DELIVERY_LOG='$DLOG' NFTBAN_DATA_DIR='$WORK/data'
source '$REPO/cli/lib/nftban/lib/nftban_redact.sh' >/dev/null 2>&1 || true
source '$FN' >/dev/null 2>&1 || true
set +e; set +o pipefail
_collect_communications '$BDIR'
" || true
OUT="$BDIR/communications.txt"

[[ -f "$OUT" ]] && ok "communications.txt written" || no_fail "no communications.txt"
grep -q 'Communication (central-comms)' "$OUT" 2>/dev/null && ok "comms summary section present" || no_fail "comms section missing"
grep -q 'RBL (observe-only advisory reputation)' "$OUT" 2>/dev/null && ok "RBL summary section present" || no_fail "RBL section missing"
grep -q 'cannot determine a provider-specific Proofpoint/iCloud bounce' "$OUT" 2>/dev/null && ok "DNSBL-only honesty label present" || no_fail "honesty label missing"
grep -q 'not firewall blocking' "$OUT" 2>/dev/null && ok "RBL observe-only/not-blocking wording present" || no_fail "observe-only wording missing"
grep -q 'Delivery-log tail' "$OUT" 2>/dev/null && ok "delivery-log tail included" || no_fail "delivery-log tail missing"
grep -q '"transport":"emulate"' "$OUT" 2>/dev/null && ok "delivery-log tail content present" || no_fail "delivery-log content missing"
# sanitization
if grep -q "$LEAK" "$OUT" 2>/dev/null; then no_fail "SMTP secret LEAKED into bundle"; else ok "no SMTP secret in bundle"; fi
if grep -q 'alice@example.com' "$OUT" 2>/dev/null; then no_fail "full recipient leaked"; else ok "recipient local-part redacted"; fi
if grep -q 'relayuser@relay.example' "$OUT" 2>/dev/null; then no_fail "SMTP Auth User leaked"; else ok "SMTP Auth User redacted"; fi

# ratchet + prior suites
out=$( cd "$REPO" && bash scripts/ci/check-comms-direct-send.sh 2>&1 )
echo "$out" | grep -q '0/4 DEBT' && echo "$out" | grep -q 'PASS' && ok "A0 guard still 0/4 PASS" || no_fail "A0 guard regressed"
( cd "$REPO" && bash cli/lib/nftban/tests/comms_a2a_delivery_truth_test.sh >/dev/null 2>&1 ) && ok "A2a test still passes" || no_fail "A2a regressed"
( cd "$REPO" && bash cli/lib/nftban/tests/comms_a2b_operator_surfacing_test.sh >/dev/null 2>&1 ) && ok "A2b test still passes" || no_fail "A2b regressed"
( cd "$REPO" && bash cli/lib/nftban/tests/comms_a2r_rbl_visibility_test.sh >/dev/null 2>&1 ) && ok "A2r test still passes" || no_fail "A2r regressed"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
