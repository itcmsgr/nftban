#!/usr/bin/env bash
# =============================================================================
# NFTBan - A0 no-direct-send CI ratchet: guard self-test
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="comms_no_direct_send_guard_a0_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-06"
# meta:description="Validates scripts/ci/check-comms-direct-send.sh (central-comms A0 ratchet): the clean repo passes (current bypasses allowlisted), a planted un-allowlisted direct send (sendmail -t / mail -s / curl --mail-rcpt) FAILS the guard, and capability probes (command -v) are NOT false positives. Hermetic: builds a sandbox tree; no host/nft/mail."
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,mktemp"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="comms_no_direct_send_guard_a0_test"
# meta:ta.owner="comms"
# meta:ta.module="ci-guard"
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
GUARD="$REPO/scripts/ci/check-comms-direct-send.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  [PASS] $1"; }
no() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }
[[ -x "$GUARD" || -f "$GUARD" ]] || { echo "FATAL: guard not found: $GUARD" >&2; exit 2; }

echo "=== A0 no-direct-send guard self-test ==="

# 1) The real repo passes (current bypasses allowlisted).
if ( cd "$REPO" && bash "$GUARD" >/dev/null 2>&1 ); then ok "clean repo passes (allowlist covers current debt)"; else no "clean repo unexpectedly failed"; fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/cli/lib/nftban/core"

# 2) Planted un-allowlisted direct sendmail → FAIL.
printf 'send() {\n  echo "$body" | sendmail -t\n}\n' > "$WORK/cli/lib/nftban/core/evil_sendmail.sh"
if ( cd "$WORK" && bash "$GUARD" >/dev/null 2>&1 ); then no "planted 'sendmail -t' NOT caught"; else ok "planted 'sendmail -t' caught (guard fails)"; fi
rm -f "$WORK/cli/lib/nftban/core/evil_sendmail.sh"

# 3) Planted un-allowlisted 'mail -s' → FAIL.
printf 'notify() {\n  echo x | mail -s "[NFTBan] hi" root\n}\n' > "$WORK/cli/lib/nftban/core/evil_mail.sh"
if ( cd "$WORK" && bash "$GUARD" >/dev/null 2>&1 ); then no "planted 'mail -s' NOT caught"; else ok "planted 'mail -s' caught (guard fails)"; fi
rm -f "$WORK/cli/lib/nftban/core/evil_mail.sh"

# 4) Planted un-allowlisted curl SMTP → FAIL.
printf 'send() {\n  curl --url smtp://h --mail-from a --mail-rcpt b -T x\n}\n' > "$WORK/cli/lib/nftban/core/evil_curl.sh"
if ( cd "$WORK" && bash "$GUARD" >/dev/null 2>&1 ); then no "planted curl '--mail-rcpt' NOT caught"; else ok "planted curl SMTP caught (guard fails)"; fi
rm -f "$WORK/cli/lib/nftban/core/evil_curl.sh"

# 5) Capability probe is NOT a false positive.
printf 'if command -v sendmail >/dev/null 2>&1; then have=1; fi\nfor mta in postfix sendmail exim4 msmtp mailx; do :; done\nmail_cmd="sendmail"\n' > "$WORK/cli/lib/nftban/core/probe_only.sh"
if ( cd "$WORK" && bash "$GUARD" >/dev/null 2>&1 ); then ok "capability probes / assignments NOT flagged"; else no "probe/assignment false-positive"; fi

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
