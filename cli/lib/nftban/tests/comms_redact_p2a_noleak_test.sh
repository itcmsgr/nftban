#!/usr/bin/env bash
# =============================================================================
# NFTBan - SEC-P1-2 P2a shared redactor no-leak matrix
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="comms_redact_p2a_noleak_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-07"
# meta:description="SEC-P1-2 P2a: the shared redactor (lib/nftban_redact.sh) scrubs every sensitive field class — *_PASS / *_PASSWORD / *_SECRET / *_TOKEN / *_API_KEY / *_AUTH / *_LICENSE_KEY / *_SASL_PASS, Bearer tokens, URL credentials, netrc password+login, SMTP Auth User, Recipient local-part — across string and file (support-bundle) surfaces; benign keys (KAFKA_PARTITION_KEY, bypass=, RBL_ENABLED) survive; redaction is idempotent. Confirms cmd_support delegates its redactors to the shared authority. Re-runs A2a/A2c/v2181 + guard. Uses non-secret LEAKMARK markers; no real secrets."
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,sed"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../../../.." && pwd)"
LIB="$REPO/cli/lib/nftban/lib/nftban_redact.sh"
SUPPORT="$REPO/cli/lib/nftban/cli/cmd_support.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  [PASS] $1"; }
no() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }

echo "=== SEC-P1-2 P2a shared redactor no-leak matrix ==="
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
M="LEAKMARK"   # non-secret marker; MUST NOT survive in redacted output

# redact via the shared lib in a clean subshell
red() { bash -c "source '$LIB' >/dev/null 2>&1 || exit 3; nftban_redact_string \"\$1\"" _ "$1"; }

# --- field-class × string surface ---
declare -A CASES=(
  ["SMTP *_PASS"]="NFTBAN_SMTP_PASS=${M}-smtp"
  ["connector SASL_PASS"]="NFTBAN_CONNECTOR_KAFKA_SASL_PASS=${M}-kafka"
  ["connector WEBHOOK_TOKEN"]="NFTBAN_CONNECTOR_WEBHOOK_TOKEN='${M}-wh'"
  ["connector ES_API_KEY"]="NFTBAN_CONNECTOR_ES_API_KEY=\"${M}-es\""
  ["PRO_TOKEN"]="NFTBAN_PRO_TOKEN=${M}-pro"
  ["PORTAL_API_KEY"]="NFTBAN_PORTAL_API_KEY=${M}-portal"
  ["GEOIP_LICENSE_KEY"]="NFTBAN_GEOIP_LICENSE_KEY=${M}-geoip"
  ["METRICS token"]="NFTBAN_METRICS_REMOTE_WRITE_TOKEN=${M}-metrics"
  ["generic PASSWORD"]="password: ${M}-pw"
  ["generic SECRET"]="CONNECTOR_WEBHOOK_SECRET=${M}-hmac"
  ["Bearer token"]="Authorization: Bearer ${M}abc123.def"
  ["URL credentials"]="url=https://user:${M}urlpw@example.com/path"
  ["netrc password"]="machine h login u password ${M}-netrc"
  ["SMTP Auth User"]="Auth User: ${M}user@relay.example"
)
for name in "${!CASES[@]}"; do
  out=$(red "${CASES[$name]}")
  if printf '%s' "$out" | grep -q "$M"; then no "$name → LEAK ($out)"; else ok "$name redacted"; fi
done
# recipient local-part (context-anchored)
out=$(red "  Recipient: alice@example.com")
echo "$out" | grep -q '\[redacted\]@example.com' && ! echo "$out" | grep -q 'alice@example.com' && ok "Recipient local-part redacted (domain kept)" || no "recipient: $out"

# --- benign survival (must NOT be redacted) ---
for b in "NFTBAN_CONNECTOR_KAFKA_PARTITION_KEY=part-abc" "bypass_count=5" "bypass=5" "surpass=1" "NFTBAN_RBL_ENABLED=YES" "admin_user_id=42"; do
  out=$(red "$b"); v="${b#*=}"
  echo "$out" | grep -q "$v" && ok "benign survives: $b" || no "over-redacted benign: $b → $out"
done

# --- idempotency ---
in="NFTBAN_SMTP_PASS=${M}-x https://u:${M}p@h Bearer ${M}tok"
r1=$(red "$in"); r2=$(red "$r1")
[[ "$r1" == "$r2" ]] && ! printf '%s' "$r1" | grep -q "$M" && ok "idempotent + no marker after 2 passes" || no "idempotency: $r1 // $r2"

# --- file / support-bundle surface: a collected .conf with all secret families ---
FIX="$WORK/connector.conf"; OUTF="$WORK/connector.redacted"
cat > "$FIX" <<CONF
NFTBAN_SMTP_PASS="${M}-smtp"
NFTBAN_CONNECTOR_KAFKA_SASL_PASS=${M}-kafka
NFTBAN_CONNECTOR_WEBHOOK_TOKEN='${M}-wh'
NFTBAN_CONNECTOR_ES_API_KEY=${M}-es
NFTBAN_PRO_TOKEN=${M}-pro
NFTBAN_GEOIP_LICENSE_KEY=${M}-geoip
NFTBAN_CONNECTOR_KAFKA_PARTITION_KEY=part-keep
NFTBAN_RBL_ENABLED=YES
CONF
bash -c "source '$LIB' >/dev/null 2>&1; nftban_redact_file '$FIX' '$OUTF'"
if grep -q "$M" "$OUTF" 2>/dev/null; then no "file redaction LEAKED: $(grep "$M" "$OUTF"|head -1)"; else ok "file redaction: no secret marker in output"; fi
grep -q 'part-keep' "$OUTF" 2>/dev/null && grep -q 'NFTBAN_RBL_ENABLED=YES' "$OUTF" 2>/dev/null && ok "file redaction: benign fields survive" || no "file redaction dropped benign fields"

# --- cmd_support delegates to the shared authority ---
grep -q 'source .*nftban_redact.sh' "$SUPPORT" && ok "cmd_support sources the shared redactor" || no "cmd_support does not source shared redactor"
grep -q 'declare -F nftban_redact_string' "$SUPPORT" && ok "_redact_secrets/_redact_comms delegate to shared" || no "no delegation in cmd_support"

# --- regressions ---
( cd "$REPO" && bash cli/lib/nftban/tests/comms_a2c_support_summary_test.sh >/dev/null 2>&1 ) && ok "A2c support test still passes" || no "A2c regressed"
( cd "$REPO" && bash cli/lib/nftban/tests/comms_a2a_delivery_truth_test.sh >/dev/null 2>&1 ) && ok "A2a delivery-log test still passes" || no "A2a regressed"
( cd "$REPO" && bash cli/lib/nftban/tests/comms_health_render_v2181_test.sh >/dev/null 2>&1 ) && ok "v2181 health-render test still passes" || no "v2181 regressed"
out=$( cd "$REPO" && bash scripts/ci/check-comms-direct-send.sh 2>&1 )
echo "$out" | grep -q '0/4 DEBT' && echo "$out" | grep -q 'PASS' && ok "A0 guard still 0/4" || no "A0 guard regressed"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
