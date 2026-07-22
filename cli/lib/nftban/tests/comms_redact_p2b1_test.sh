#!/usr/bin/env bash
# =============================================================================
# NFTBan - SEC-P1-2 P2b-1 remaining secret-coverage (forensics/journal/connector)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="comms_redact_p2b1_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-07"
# meta:description="SEC-P1-2 P2b-1: update-forensics _fx_redact delegates to the shared redactor; support-bundle journal/logs are secret-scrubbed; nftban connector show masks credentials. CRITICAL forensic invariant: attacker IPs and usernames SURVIVE by default (identifier-privacy is a separate opt-in mode, P2b-2) while secret values do NOT. Also asserts the netrc 'login <user>' pattern was removed so journal usernames survive. Re-runs P2a/A2c/v2181 + guard. Non-secret LEAKMARK markers; no real secrets."
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,sed,awk"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="comms_redact_p2b1_test"
# meta:ta.owner="security"
# meta:ta.module="redaction"
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
LIB="$REPO/cli/lib/nftban/lib/nftban_redact.sh"
SUPPORT="$REPO/cli/lib/nftban/cli/cmd_support.sh"
CONNECTOR="$REPO/cli/lib/nftban/cli/cmd_connector.sh"
UPD="$REPO/cli/lib/nftban/cli/cmd_update_helpers.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  [PASS] $1"; }
no() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }

echo "=== SEC-P1-2 P2b-1 remaining secret-coverage ==="
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
M="LEAKMARK"
red() { bash -c "source '$LIB' >/dev/null 2>&1; nftban_redact_string \"\$1\"" _ "$1"; }

# --- CRITICAL: journal/log surface — secrets scrubbed, IPs + usernames SURVIVE ---
# Built with printf so every line-break is a REAL newline (sed redacts per line).
JLINES=$(printf '%s\n' \
  "2026-07-07 [BAN] banned 203.0.113.45 reason=bruteforce user=attacker99" \
  "NFTBAN_SMTP_PASS=${M}-jrnl" \
  "password ${M}-netrc" \
  "LoginMon: failed login for admin from 198.51.100.7" \
  "sshd: Accepted publickey for root from 2001:db8::1234" \
  "Authorization: Bearer ${M}tok.abc")
jr=$(red "$JLINES")
printf '%s' "$jr" | grep -q "$M" && no "journal: secret LEAKED" || ok "journal: all secrets scrubbed"
echo "$jr" | grep -q '203.0.113.45' && ok "journal: attacker IPv4 SURVIVES (forensic)" || no "IPv4 lost: $jr"
echo "$jr" | grep -q '198.51.100.7'  && echo "$jr" | grep -q '2001:db8::1234' && ok "journal: more IPv4/IPv6 survive" || no "IP lost"
echo "$jr" | grep -q 'user=attacker99' && ok "journal: username (user=attacker99) SURVIVES" || no "username lost: $jr"
echo "$jr" | grep -q 'login for admin' && ok "journal: 'login <user>' username SURVIVES (netrc login pattern removed)" || no "login-username lost: $jr"
echo "$jr" | grep -q 'for root from' && ok "journal: 'root' identifier survives" || no "root lost"

# --- update forensics _fx_redact delegates to shared (functional + wiring) ---
FX="$WORK/fx.sh"; awk '/^_fx_redact\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$UPD" > "$FX"
fo=$(bash -c "export NFTBAN_LIB_DIR='$REPO/cli/lib/nftban'; source '$FX' >/dev/null 2>&1; printf '%s\n' 'NFTBAN_CONNECTOR_KAFKA_SASL_PASS=${M}-fx bypass=5' | _fx_redact")
printf '%s' "$fo" | grep -q "$M" && no "_fx_redact leaked *_PASS" || ok "_fx_redact scrubs *_PASS (shared coverage)"
echo "$fo" | grep -q 'bypass=5' && ok "_fx_redact: benign survives" || no "_fx_redact over-redacted"
grep -q 'nftban_redact_stream' "$UPD" && ok "_fx_redact delegates to shared authority" || no "_fx_redact not delegated"

# --- connector show masks credentials, keeps non-secret fields ---
CONF="$WORK/es.conf"; printf '%s\n' "# comment" "CONNECTOR_TYPE=webhook" "NFTBAN_CONNECTOR_WEBHOOK_TOKEN=${M}-wh" "CONNECTOR_WEBHOOK_SECRET=${M}-hmac" "CONNECTOR_ES_URL=https://es.example:9200" > "$CONF"
co=$(bash -c "source '$LIB' >/dev/null 2>&1; grep -v '^#' '$CONF' | grep -v '^\$' | nftban_redact_stream")
printf '%s' "$co" | grep -q "$M" && no "connector show LEAKED credential" || ok "connector show: credentials masked"
echo "$co" | grep -q 'CONNECTOR_ES_URL=https://es.example:9200' && echo "$co" | grep -q 'CONNECTOR_TYPE=webhook' && ok "connector show: non-secret fields (URL/type) survive" || no "connector show dropped non-secret fields"
grep -q 'nftban_redact_stream' "$CONNECTOR" && ok "connector show wired to shared redactor" || no "connector show not wired"

# --- support-bundle log wiring ---
grep -q '_support_scrub_stream' "$SUPPORT" && grep -q 'journalctl .* | _support_scrub_stream\|_support_scrub_stream > ' "$SUPPORT" && ok "_collect_logs scrubs journal/logs (identifiers untouched)" || no "_collect_logs not wired"

# --- idempotency ---
r1=$(red "$JLINES"); r2=$(red "$r1")
[[ "$r1" == "$r2" ]] && ok "idempotent" || no "not idempotent"

# --- regressions (coverage never shrinks) ---
( cd "$REPO" && bash cli/lib/nftban/tests/comms_redact_p2a_noleak_test.sh >/dev/null 2>&1 ) && ok "P2a no-leak still passes" || no "P2a regressed"
( cd "$REPO" && bash cli/lib/nftban/tests/comms_a2c_support_summary_test.sh >/dev/null 2>&1 ) && ok "A2c support still passes" || no "A2c regressed"
( cd "$REPO" && bash cli/lib/nftban/tests/comms_health_render_v2181_test.sh >/dev/null 2>&1 ) && ok "v2181 still passes" || no "v2181 regressed"
out=$( cd "$REPO" && bash scripts/ci/check-comms-direct-send.sh 2>&1 )
echo "$out" | grep -q '0/4 DEBT' && echo "$out" | grep -q 'PASS' && ok "A0 guard still 0/4" || no "A0 guard regressed"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
