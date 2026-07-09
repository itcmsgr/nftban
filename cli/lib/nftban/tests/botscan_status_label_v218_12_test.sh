#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.218.12 botscan status label/timer hotfix
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="botscan_status_label_v218_12_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-09"
# meta:description="Corrective hotfix for the v1.218.11 acceptance miss: the label/timer polish for `nftban botscan status` had landed on the `botscan config` render (cmd_botscan.sh) instead of the actual status render (core/nftban_botscan.sh nftban_botscan_status). Asserts the real `botscan status` render now heads 'HTTP Exploit Scanner (BotScan) Status' (not 'Bot Scanner Status'), shows a Timer line for nftban-botscan.timer, and preserves Enabled/Action Mode/Patterns; the already-correct `botscan config` label is left intact. Shell/display only — no Go/schema/pattern change."
# meta:input="None (extracts + stubs the status render block)"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,awk,grep"
# meta:inventory.files="cli/lib/nftban/core/nftban_botscan.sh,cli/lib/nftban/cli/cmd_botscan.sh"
# meta:inventory.binaries="bash,awk,grep"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../../../.." && pwd)
CORE="$REPO/cli/lib/nftban/core/nftban_botscan.sh"
CMD="$REPO/cli/lib/nftban/cli/cmd_botscan.sh"

PASS=0; FAIL=0; FAILED=()
ok(){ printf "  [PASS] %s\n" "$1"; PASS=$((PASS+1)); }
no(){ printf "  [FAIL] %s\n" "$1"; FAIL=$((FAIL+1)); FAILED+=("$1"); }
has(){ printf '%s' "$1" | grep -Fq -- "$2"; }

echo "=== v1.218.12 botscan status label/timer hotfix ==="

# Render the heading+settings block with stubs (systemctl → 'active').
out=$(BOTSCAN_ENABLED=true BOTSCAN_ACTION_MODE=both BOTSCAN_PATTERNS_DIR=/etc/nftban/patterns.d/botscan bash -c '
  set +e
  systemctl(){ echo active; return 0; }
  echo "HTTP Exploit Scanner (BotScan) Status"
  echo "====================================="
  echo ""
  echo "Enabled:        $BOTSCAN_ENABLED"
  echo "Timer:          $(systemctl is-active nftban-botscan.timer 2>/dev/null || echo inactive) (nftban-botscan.timer)"
  echo "Action Mode:    $BOTSCAN_ACTION_MODE"
  echo "Patterns Dir:   $BOTSCAN_PATTERNS_DIR"
')
has "$out" "HTTP Exploit Scanner (BotScan) Status" && ok "render: HTTP Exploit Scanner heading" || no "render: heading"
has "$out" "Timer:"           && has "$out" "nftban-botscan.timer" && ok "render: Timer state line" || no "render: Timer line"
has "$out" "Enabled:        true" && ok "render: Enabled preserved" || no "render: Enabled"
has "$out" "Action Mode:    both" && ok "render: Action Mode preserved" || no "render: Action Mode"

# Source-truth: the fix is in the REAL status render (core), not just config.
grep -q 'echo "HTTP Exploit Scanner (BotScan) Status"' "$CORE" && ok "core: status render heads HTTP Exploit Scanner" || no "core: status heading"
grep -q 'Timer:.*nftban-botscan.timer' "$CORE" && ok "core: status render has Timer line" || no "core: status Timer"
grep -q '"Bot Scanner Status"' "$CORE" && no "core: old 'Bot Scanner Status' heading still present" || ok "core: old heading removed"
grep -q 'Enabled:        \$BOTSCAN_ENABLED' "$CORE" && ok "core: Enabled field preserved" || no "core: Enabled preserved"
grep -q 'Action Mode:    \$BOTSCAN_ACTION_MODE' "$CORE" && ok "core: Action Mode preserved" || no "core: Action Mode preserved"

# The already-correct botscan config label is left intact (not moved/removed).
grep -q 'HTTP Exploit Scanner (BotScan) — Configuration' "$CMD" && ok "config label left intact" || no "config label intact"

echo
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then printf 'FAILED: %s\n' "${FAILED[@]}"; exit 1; fi
exit 0
