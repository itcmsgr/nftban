#!/usr/bin/env bash
# =============================================================================
# NFTBan - BotScan admin/management-IP exemption (F2) — scanner-gate tests
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="botscan_admin_ip_exemption_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-29"
# meta:description="Locks the F2 admin/management-IP exemption SCANNER gate: nftban_botscan_is_whitelisted consults the daemon-published never-ban exempt list (BOTSCAN_EXEMPT_FILE) via a cheap EXACT match that needs no nft read (works under the unprivileged scanner). Exempt IPs are suppressed (never signaled); non-exempt IPs are NOT suppressed (still bannable). The AUTHORITATIVE range-aware never-ban invariant is enforced daemon-side at Backend.Ban (Go test internal/nftbackend/exemption_test.go) — this covers the shell defense-in-depth half."
# meta:inventory.files="cli/lib/nftban/core/nftban_botscan.sh"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,BOTSCAN_EXEMPT_FILE,BOTSCAN_USE_GLOBAL_WHITELIST"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../../../.." && pwd)"
CORE="$REPO/cli/lib/nftban/core/nftban_botscan.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
EXEMPT="$WORK/exempt.list"
printf '# generated\n203.0.113.7\n192.0.2.122\n2001:db8::1\n' > "$EXEMPT"

echo "=== F2 BotScan scanner exemption gate ==="
# shellcheck source=/dev/null
( export NFTBAN_LIB_DIR="$REPO/cli/lib/nftban" BOTSCAN_EXEMPT_FILE="$EXEMPT" BOTSCAN_USE_GLOBAL_WHITELIST=false
  source "$CORE" >/dev/null 2>&1

  # T1: exact-listed exempt IP (the F2 admin IP) → suppressed (rc0 = whitelisted/exempt)
  if nftban_botscan_is_whitelisted "192.0.2.122" ""; then echo T1ok; fi
  # T2: another exact-listed exempt IP → suppressed
  if nftban_botscan_is_whitelisted "203.0.113.7" ""; then echo T2ok; fi
  # T3: exempt v6 → suppressed
  if nftban_botscan_is_whitelisted "2001:db8::1" ""; then echo T3ok; fi
  # T4: NON-exempt IP → NOT suppressed (must remain bannable)
  if nftban_botscan_is_whitelisted "198.51.100.9" ""; then echo T4bad; else echo T4ok; fi
  # T5: partial/substring must NOT match (exact-line only)
  if nftban_botscan_is_whitelisted "192.0.2.12" ""; then echo T5bad; else echo T5ok; fi
) > "$WORK/out" 2>&1

grep -q T1ok "$WORK/out" && ok "T1 exempt admin IP suppressed" || no "T1"
grep -q T2ok "$WORK/out" && ok "T2 exempt IP suppressed" || no "T2"
grep -q T3ok "$WORK/out" && ok "T3 exempt v6 suppressed" || no "T3"
grep -q T4ok "$WORK/out" && ok "T4 non-exempt IP NOT suppressed (still bannable)" || no "T4" "$(cat "$WORK/out")"
grep -q T5ok "$WORK/out" && ok "T5 substring does NOT match (exact-line only)" || no "T5"

echo ""
echo "=== RESULT: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
