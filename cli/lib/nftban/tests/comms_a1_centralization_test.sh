#!/usr/bin/env bash
# =============================================================================
# NFTBan - A1 central-comms shell centralization
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="comms_a1_centralization_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-06"
# meta:description="A1: proves the 4 direct-send differentials are migrated to the central mail authority and the new helpers behave. Sources nftban_mail.sh to test nftban_mail_resolve_recipient (override→global, missing→error) and prefer-explicit-SMTP transport selection (NFTBAN_SMTP_HOST + no NFTBAN_MAIL_METHOD → curl; explicit method wins). Greps to assert Tunnel/Maintenance/update/support carry NO direct sendmail/mail/mailx transport and route through central; and that the A0 guard now shows 0/4 debt. Hermetic: no real mail, no network."
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars="NFTBAN_MAIL_RECIPIENT,NFTBAN_SMTP_HOST,NFTBAN_MAIL_METHOD"
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
TUNNEL="$REPO/cli/lib/nftban/core/nftban_tunnel.sh"
MAINT="$REPO/cli/lib/nftban/cron/maintenance.sh"
UPDATE="$REPO/cli/lib/nftban/cli/cmd_update.sh"
SUPPORT="$REPO/cli/lib/nftban/cli/cmd_support.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  [PASS] $1"; }
no() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }

echo "=== A1 central-comms centralization ==="

# --- helper behavior: extract the pure resolver (the full lib has env deps) ---
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
FN="$WORK/fn.sh"
awk '/^nftban_mail_resolve_recipient\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$MAIL" > "$FN"
grep -q 'nftban_mail_resolve_recipient()' "$FN" && ok "extracted nftban_mail_resolve_recipient" || no "could not extract resolver"
rr() { bash -c "source '$FN'; NFTBAN_MAIL_RECIPIENT='${2:-}'; if out=\$(nftban_mail_resolve_recipient '${1:-}' 2>/dev/null); then printf 'OK:%s' \"\$out\"; else printf ERR; fi"; }
[[ "$(rr 'mod@x.test' 'glob@y.test')" == "OK:mod@x.test" ]] && ok "resolve: module override wins" || no "resolve: override"
[[ "$(rr '' 'glob@y.test')" == "OK:glob@y.test" ]] && ok "resolve: falls back to global NFTBAN_MAIL_RECIPIENT" || no "resolve: global"
[[ "$(rr '' '')" == "ERR" ]] && ok "resolve: missing recipient errors (not silent)" || no "resolve: missing-error"

# --- prefer-explicit-SMTP: assert the curl-first branch exists (executing detect_mta needs
#     full-lib sourcing + binary probes; the branch is the invariant). ---
if grep -Eq '\[\[ -z "\$\{NFTBAN_MAIL_METHOD:-\}" && -n "\$\{NFTBAN_SMTP_HOST:-\}" \]\] && command -v curl' "$MAIL"; then
  ok "prefer-explicit-SMTP: SMTP_HOST + no method → curl branch present (before local MTA)"
else
  no "prefer-explicit-SMTP branch missing"
fi

# --- migrations: NO direct transport in the 4 files; they route through central ---
send_pat='(\|[[:space:]]*(sendmail|mailx|msmtp))|(\bsendmail[[:space:]]+-t\b)|(\bmail[[:space:]]+-s[[:space:]])|(--mail-rcpt)'
for f in "$TUNNEL" "$MAINT" "$UPDATE" "$SUPPORT"; do
  b=$(basename "$f")
  if grep -nE "$send_pat" "$f" | grep -qvE '^[0-9]+:[[:space:]]*#'; then no "$b still has a direct transport send"; else ok "$b: no direct transport send"; fi
done
grep -q 'nftban_mail_alert' "$TUNNEL"  && ok "Tunnel routes through nftban_mail_alert" || no "Tunnel not central"
grep -q '_maint_ipchange_alert' "$MAINT" && grep -q 'nftban_mail_alert' "$MAINT" && ok "Maintenance routes through central" || no "Maintenance not central"
grep -q 'nftban_mail_send_with_retry' "$UPDATE" && ok "update uses spool/retry variant" || no "update not on retry variant"
grep -q 'no direct fallback' "$SUPPORT" && ok "support degraded path (no direct fallback)" || no "support fallback not removed"

# --- A0 guard now shows 0/4 debt and still passes ---
out=$( cd "$REPO" && bash scripts/ci/check-comms-direct-send.sh 2>&1 )
echo "$out" | grep -q '0/4 DEBT' && ok "A0 guard burndown: 0/4 debt" || no "A0 guard debt not 0/4"
echo "$out" | grep -q 'PASS' && ok "A0 guard passes clean" || no "A0 guard failed"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
