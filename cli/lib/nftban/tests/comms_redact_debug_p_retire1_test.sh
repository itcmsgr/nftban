#!/usr/bin/env bash
# =============================================================================
# NFTBan - Duplicate-redactor retirement P-retire-1: nftban debug uses the shared authority
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="comms_redact_debug_p_retire1_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-07"
# meta:description="SEC-P1-2 duplicate-redactor retirement P-retire-1: nftban debug config/env output is scrubbed through the SHARED redaction authority (_debug_scrub_stream -> nftban_redact_stream), not a divergent local sed. Closes the *_PASS leak (NFTBAN_SMTP_PASS + connector *_PASS were printed cleartext because the old sed matched PASSWORD but not PASS) and the bare-KEY over-redaction (KAFKA_PARTITION_KEY was wrongly redacted). Asserts the leak is closed, benign keys survive, and cmd_debug no longer carries a raw redaction sed. Hermetic: extracted fn, no real mail, no network, non-secret markers."
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,sed,awk"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../../../.." && pwd)"
DEBUG="$REPO/cli/lib/nftban/cli/cmd_debug.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  [PASS] $1"; }
no() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }

echo "=== duplicate-redactor retirement P-retire-1: nftban debug shared-authority scrub ==="
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
M="LEAKMARK"

# extract _debug_scrub_stream (it sources the shared lib on-demand via NFTBAN_LIB_DIR)
FN="$WORK/scrub.sh"; awk '/^_debug_scrub_stream\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$DEBUG" > "$FN"
grep -q '_debug_scrub_stream' "$FN" && ok "extracted _debug_scrub_stream" || no "extract failed"

# drive a debug-config-like block through it
scrub() { bash -c "export NFTBAN_LIB_DIR='$REPO/cli/lib/nftban'; source '$FN' >/dev/null 2>&1; _debug_scrub_stream"; }

INPUT=$(printf '%s\n' \
  "NFTBAN_SMTP_PASS=${M}-smtp" \
  "NFTBAN_CONNECTOR_KAFKA_SASL_PASS=${M}-sasl" \
  "NFTBAN_CONNECTOR_WEBHOOK_PASSWORD=${M}-pw" \
  "NFTBAN_CONNECTOR_WEBHOOK_SECRET=${M}-sec" \
  "NFTBAN_CONNECTOR_WEBHOOK_TOKEN=${M}-tok" \
  "NFTBAN_CONNECTOR_ES_API_KEY=${M}-api" \
  "NFTBAN_CONNECTOR_WEBHOOK_AUTH=${M}-auth" \
  "NFTBAN_CONNECTOR_KAFKA_PARTITION_KEY=part-keep" \
  "bypass=5" \
  "surpass=1" \
  "NFTBAN_RBL_ENABLED=YES")
OUT=$(printf '%s' "$INPUT" | scrub)

# leak closed: NO secret marker survives (the *_PASS class the old sed leaked)
printf '%s' "$OUT" | grep -q "$M" && no "debug scrub LEAKED: $(printf '%s' "$OUT"|grep "$M"|head -1)" || ok "debug scrub: all secret markers redacted (incl *_PASS)"
# specifically prove the SMTP_PASS line the old sed missed is now redacted
echo "$OUT" | grep -qE 'NFTBAN_SMTP_PASS=.*(REDACTED|\[)' && ! echo "$OUT" | grep -q "${M}-smtp" && ok "NFTBAN_SMTP_PASS redacted (old sed leaked it)" || no "SMTP_PASS not redacted: $(echo "$OUT"|grep SMTP_PASS)"

# benign survival (the bare-KEY over-redaction is gone)
echo "$OUT" | grep -q 'NFTBAN_CONNECTOR_KAFKA_PARTITION_KEY=part-keep' && ok "KAFKA_PARTITION_KEY survives (over-redaction fixed)" || no "PARTITION_KEY over-redacted: $(echo "$OUT"|grep PARTITION)"
echo "$OUT" | grep -q 'bypass=5' && echo "$OUT" | grep -q 'surpass=1' && echo "$OUT" | grep -q 'NFTBAN_RBL_ENABLED=YES' && ok "benign keys survive (bypass/surpass/RBL_ENABLED)" || no "benign over-redacted"

# reviewer rule: cmd_debug no longer carries a raw redaction sed in config/env, and uses the shared authority
grep -qE "sed -E 's/\(TOKEN\|PASSWORD\|SECRET\|KEY" "$DEBUG" && no "cmd_debug STILL has the raw redaction sed" || ok "cmd_debug: raw redaction sed removed"
grep -q '_debug_scrub_stream' "$DEBUG" && grep -q 'nftban_redact_stream' "$DEBUG" && ok "cmd_debug uses the shared authority (_debug_scrub_stream -> nftban_redact_stream)" || no "cmd_debug not wired to shared authority"

# idempotency
r1=$(printf '%s' "$INPUT" | scrub); r2=$(printf '%s' "$r1" | scrub)
[[ "$r1" == "$r2" ]] && ok "idempotent" || no "not idempotent"

# regressions: the shared authority + SEC-P1-2 suites stay green
for t in comms_redact_p2a_noleak comms_redact_p2b1; do
  ( cd "$REPO" && bash "cli/lib/nftban/tests/${t}_test.sh" >/dev/null 2>&1 ) && ok "${t} still passes" || no "${t} regressed"
done
out=$( cd "$REPO" && bash scripts/ci/check-comms-direct-send.sh 2>&1 )
echo "$out" | grep -q '0/4 DEBT' && echo "$out" | grep -q 'PASS' && ok "A0 guard still 0/4" || no "A0 guard regressed"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
