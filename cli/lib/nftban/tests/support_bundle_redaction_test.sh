#!/usr/bin/env bash
# =============================================================================
# NFTBan - SEC-INFRA Guard 7: support-bundle redaction (exported-artifact policy)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="support_bundle_redaction_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-15"
# meta:description="SEC-INFRA Guard 7. The support bundle is an intentionally-EXPORTED artifact, so its redaction contract is release-blocking. Drives the REAL support entrypoint _support_scrub_stream() (extracted from cmd_support.sh) with the shared redactor loaded, over a representative synthetic fixture (IPv4/IPv6, hostname/domain, email, Recipient, secrets/tokens/keys/Bearer/URL-cred/netrc/Auth-User, personal path, username). Asserts POLICY: every SECRET is scrubbed, while forensic identifiers (IPs, hostnames, usernames, personal paths, non-Recipient emails, benign keys) are PRESERVED — identifier-privacy is a separate opt-in mode (SEC-P1-2 P2b-2), not this contract. NONE of the fixtures are real values. Also asserts the collectors fail-closed (no cat-through) and the entrypoint is idempotent."
# meta:input="None (self-contained; synthetic LEAKMARK fixtures)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,grep,sed,awk,mktemp"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,sed,awk,mktemp"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="support_bundle_redaction_test"
# meta:ta.owner="security"
# meta:ta.module="redaction"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="policy-gates"
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

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  [PASS] $1"; }
no() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }

echo "=== SEC-INFRA Guard 7: support-bundle redaction ==="
[[ -f "$LIB" ]] || { echo "missing $LIB"; exit 2; }
[[ -f "$SUPPORT" ]] || { echo "missing $SUPPORT"; exit 2; }

# Extract the REAL support-bundle scrub entrypoint from cmd_support.sh so the
# test exercises the shipped code path, not a re-implementation.
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
FN="$WORK/scrub.sh"
awk '/^_support_scrub_stream\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SUPPORT" > "$FN"
grep -q 'nftban_redact_stream' "$FN" \
  && ok "extracted _support_scrub_stream delegates to shared redactor" \
  || no "could not extract _support_scrub_stream / no delegation"

# Run stdin through the real entrypoint with the shared redactor loaded.
scrub() {
    bash -c "source '$LIB' >/dev/null 2>&1
             source '$FN' >/dev/null 2>&1
             _support_scrub_stream"
}

# --- Representative synthetic support-bundle content (every line REAL newline;
#     sed redaction is per-line). Secret values carry a unique LEAKMARK. ---
M="LEAKMARK"
FIXTURE=$(printf '%s\n' \
  "2026-07-15 [BAN] banned 203.0.113.7 reason=bruteforce user=attacker99" \
  "sshd: Accepted publickey for root from 2001:db8::7 port 51000" \
  "host=host.example.test client=user@example.com path=/home/operator" \
  "NFTBAN_SMTP_PASS=${M}-smtp" \
  "CONNECTOR_WEBHOOK_TOKEN=${M}-tok" \
  "NFTBAN_CONNECTOR_KAFKA_SASL_PASS=${M}-sasl bypass=keepme" \
  "API_KEY=${M}-apikey  LICENSE_KEY=${M}-lic  WEBHOOK_SECRET=${M}-secret" \
  "Authorization: Bearer ${M}-bearer.tok" \
  "feed url https://feeduser:${M}-urlpass@feeds.example.test/list.txt" \
  "password ${M}-netrc" \
  "SMTP handshake -> Auth User: ${M}-authuser" \
  "Recipient: alice@example.com")
OUT="$(printf '%s' "$FIXTURE" | scrub)"

# --- SECRETS: every marked secret value must be gone --------------------------
if printf '%s' "$OUT" | grep -q "$M"; then
    no "a secret LEAKED: $(printf '%s' "$OUT" | grep "$M" | head -1)"
else
    ok "all marked secrets scrubbed (pass/token/key/sasl/bearer/url-cred/netrc/auth-user)"
fi
# Recipient local-part scrubbed, domain kept
echo "$OUT" | grep -q 'Recipient: alice@' && no "Recipient local-part LEAKED" \
    || ok "Recipient local-part scrubbed"
echo "$OUT" | grep -q 'Recipient:.*@example.com' && ok "Recipient domain preserved" \
    || no "Recipient domain lost"

# --- FORENSIC IDENTIFIERS: must SURVIVE (policy: not this contract) -----------
echo "$OUT" | grep -q '203.0.113.7'       && ok "forensic IPv4 survives"        || no "IPv4 lost"
echo "$OUT" | grep -q '2001:db8::7'       && ok "forensic IPv6 survives"        || no "IPv6 lost"
echo "$OUT" | grep -q 'user=attacker99'   && ok "username survives (forensic)"  || no "username lost"
echo "$OUT" | grep -q 'host.example.test' && ok "hostname survives"             || no "hostname lost"
echo "$OUT" | grep -q 'client=user@example.com' && ok "non-Recipient email survives" || no "operational email lost"
echo "$OUT" | grep -q '/home/operator'    && ok "personal path survives (redactor scope: source scanner, not runtime)" || no "path lost"
echo "$OUT" | grep -q 'bypass=keepme'     && ok "benign key (bypass=) survives" || no "benign key over-redacted"

# --- FAIL-CLOSED: with the redactor UNAVAILABLE, no raw cat-through -----------
NOLIB="$(printf '%s' "$FIXTURE" | bash -c "_redact_unavailable() { echo '[REDACTED-UNAVAILABLE]'; }; source '$FN' >/dev/null 2>&1; _support_scrub_stream")"
if printf '%s' "$NOLIB" | grep -q "$M"; then
    no "FAIL-OPEN: secrets passed through when redactor unavailable"
else
    ok "fail-closed when redactor unavailable (no raw cat-through)"
fi

# --- Idempotency --------------------------------------------------------------
OUT2="$(printf '%s' "$OUT" | scrub)"
[[ "$OUT" == "$OUT2" ]] && ok "idempotent" || no "not idempotent"

echo "----"
# Two SEPARATE properties — do not conflate:
#   * SECRET redaction IS the contract this test proves.
#   * IDENTIFIER privacy (redacting forensic IPs/paths/usernames) is a DISTINCT,
#     unimplemented capability (SEC-P1-2 P2b-2, HOLD_DECISION). This test proves
#     the FORMER and explicitly asserts the latter is NOT in effect (identifiers
#     survive). A green run here does NOT mean a support bundle is free of private
#     identifiers.
if [[ "$FAIL" -eq 0 ]]; then
    echo "SUPPORT_BUNDLE_SECRET_REDACTION=PASS"
    echo "SUPPORT_BUNDLE_IDENTIFIER_PRIVACY=HOLD_DECISION (not implemented; forensic identifiers intentionally preserved)"
fi
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
