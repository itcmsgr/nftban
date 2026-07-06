#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan - CI Gate: no-direct-send (central communication authority)
# =============================================================================
# meta:name="check-comms-direct-send"
# meta:type="script"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Enforce that mail transport primitives (sendmail/mail -s/mailx/msmtp/curl-SMTP) are invoked ONLY inside the central authority core/nftban_mail.sh. Modules must submit alert payloads to nftban_mail_send(); direct sends bypass validation/spool/retry/dedup/metrics/audit and the daemonless curl-SMTP path. Central-comms Lane A0 RATCHET: the current known bypasses are allowlisted as DEBT so CI passes today; A1 removes each entry as its bypass is closed, and any NEW direct send fails immediately. Model: check-nft-writes.sh."
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Exit codes: 0 = no un-allowlisted direct sends; 1 = violation (PR must not merge)
# =============================================================================

set -Eeuo pipefail

# -----------------------------------------------------------------------------
# SEND-INVOCATION PATTERN — real transport calls only (NOT capability probes,
# assignments, labels, or comments). Matches:
#   | sendmail | mailx | msmtp | $mail_cmd   (pipe into a transport)
#   sendmail -t                              (sendmail send)
#   mail -s <subject>                        (mail send)
#   --mail-rcpt                              (curl SMTP send)
# -----------------------------------------------------------------------------
COMMS_SEND_PATTERN='(\|[[:space:]]*("?\$\{?mail_cmd\}?|(/usr/s?bin/)?(sendmail|mailx|msmtp)([[:space:]]|$)))|(\bsendmail[[:space:]]+-t\b)|(\bmail[[:space:]]+-s[[:space:]])|(--mail-rcpt)'

# -----------------------------------------------------------------------------
# ALLOWED — the central authority + annotated A0 DEBT allowlist (A1 removes each).
#   AUTHORITY:
#     core/nftban_mail.sh        — the sole intended transport owner (nftban_mail_send)
#   DEBT (A1 closes → route through nftban_mail_send_with_retry, then delete entry):
#     core/nftban_tunnel.sh      — Tunnel direct `sendmail` (CENTRAL_COMMS_BYPASS_TUNNEL)
#     cron/maintenance.sh        — IP-change `mail -s … root` (CENTRAL_COMMS_BYPASS_MAINTENANCE_CRON)
#     cli/cmd_update.sh          — update notify direct fallback (sendmail/mail)
#     cli/cmd_support.sh         — support-bundle direct `mail -s`
#   (NOTE: cmd_report.sh is COMPLIANT — sends via nftban_mail_send; the audit's
#    'report direct fallback' was empirically disproven by this guard.)
#   TEST-ONLY:
#     tests/selftest.sh          — self-test report send (never production)
# -----------------------------------------------------------------------------
# TEST-ONLY / this gate itself: scripts/ci/ (the gate carries the pattern string) and
# the A0 self-test (carries planted-violation fixtures) are not runtime senders.
ALLOWED_REGEX='^(cli/lib/nftban/core/nftban_mail\.sh|cli/lib/nftban/core/nftban_tunnel\.sh|cli/lib/nftban/cron/maintenance\.sh|cli/lib/nftban/cli/cmd_update\.sh|cli/lib/nftban/cli/cmd_support\.sh|cli/lib/nftban/tests/selftest\.sh|cli/lib/nftban/tests/comms_no_direct_send_guard_a0_test\.sh|scripts/ci/)'

# Files in the DEBT allowlist that A1 must burn down (excludes AUTHORITY + TEST).
DEBT_REGEX='nftban_tunnel\.sh|maintenance\.sh|cmd_update\.sh|cmd_support\.sh'

echo "========================================"
echo "NFTBan Comms Check: no-direct-send"
echo "========================================"
echo "Policy: mail transport primitives only inside core/nftban_mail.sh."
echo ""

VIO=$(mktemp); trap 'rm -f "$VIO"' EXIT

grep -rnE "$COMMS_SEND_PATTERN" --include="*.sh" cli/ scripts/ install/ 2>/dev/null \
  | grep -vE "$ALLOWED_REGEX" \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
  | grep -vE 'command -v|nftban_have_cmd|type -t|for [a-zA-Z_]+ in' \
  >> "$VIO" || true

if [[ -s "$VIO" ]]; then
  echo "❌ FAIL: direct mail send outside core/nftban_mail.sh (and not allowlisted):"
  echo ""
  cat "$VIO"
  echo ""
  echo "Fix: submit the alert payload to nftban_mail_send()/nftban_mail_send_with_retry()."
  echo "If this is a legitimate transport probe (command -v ...), it should not match; refine the call site."
  exit 1
fi

# Burndown: how many DEBT files still carry a direct send (A1 target). The {…|| true}
# guards against set -e when nothing matches (e.g. an empty sandbox in the self-test).
debt_remaining=$( { grep -rlE "$COMMS_SEND_PATTERN" --include="*.sh" cli/ 2>/dev/null \
  | grep -E "$DEBT_REGEX" || true; } | sort -u | wc -l | tr -d ' ')
echo "✅ PASS: no un-allowlisted direct mail sends."
echo "   A0 ratchet: $debt_remaining/4 DEBT bypass files remaining (A1 burns these down)."
exit 0
