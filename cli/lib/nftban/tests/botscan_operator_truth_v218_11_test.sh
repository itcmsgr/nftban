#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.218.11 BotScan operator-truth V1 (shell surfacing)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="botscan_operator_truth_v218_11_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-09"
# meta:description="Verifies the v1.218.11 shell surfacing that makes BotScan (the periodic HTTP-log exploit scanner) first-class alongside BotGuard, after the 2026-07-08 incident where BotGuard showed DISABLED while BotScan was enabled and banning via blacklist_manual_*. Extracts the nftban status BotScan render block and exercises it with enabled/disabled fixtures (asserts HTTP Exploit Scan row, ENABLED with action mode + timer state, DISABLED, and the BotGuard-independence note); asserts nftban help exposes botscan with the HTTP-Guard-vs-HTTP-Exploit-Scanner distinction; asserts nftban botscan status carries the HTTP Exploit Scanner label + timer line. Shell/display only — no Go/schema/pattern change."
# meta:input="None (extracts + stubs the status render block; greps help/botscan sources)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,awk,grep,systemctl-stub"
# meta:inventory.files="cli/lib/nftban/cli/cmd_status.sh,cli/lib/nftban/nftban_help.sh,cli/lib/nftban/cli/cmd_botscan.sh"
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
STATUS="$REPO/cli/lib/nftban/cli/cmd_status.sh"
HELP="$REPO/cli/lib/nftban/nftban_help.sh"
BOTSCAN="$REPO/cli/lib/nftban/cli/cmd_botscan.sh"

SANDBOX=$(mktemp -d); trap 'rm -rf "$SANDBOX"' EXIT
PASS=0; FAIL=0; FAILED=()
ok(){ printf "  [PASS] %s\n" "$1"; PASS=$((PASS+1)); }
no(){ printf "  [FAIL] %s\n" "$1"; FAIL=$((FAIL+1)); FAILED+=("$1"); }
has(){ printf '%s' "$1" | grep -Fq -- "$2"; }

# Extract the BotScan render block from cmd_status.sh.
awk '/# HTTP Exploit Scanner \(BotScan\)/{c=1} c{print} /BotGuard disabled != BotScan disabled/{exit}' "$STATUS" > "$SANDBOX/block.sh"
[[ -s "$SANDBOX/block.sh" ]] && ok "status BotScan render block present" || no "status BotScan render block MISSING"

# Render harness: wrap the block in a function with config + systemctl stubs.
render() {  # render <enabled> <action_mode> <timer-active:1|0>
  local en="$1" mode="$2" tmr="$3"
  mkdir -p "$SANDBOX/conf.d/botscan"
  printf 'BOTSCAN_ENABLED="%s"\nBOTSCAN_ACTION_MODE="%s"\n' "$en" "$mode" > "$SANDBOX/conf.d/botscan/main.conf"
  STIMER="$tmr" bash -c '
    set +e
    NFTBAN_CONFIG_DIR="'"$SANDBOX"'"
    _source_local(){ source "$1"; }
    systemctl(){ [ "${STIMER:-0}" = 1 ] && return 0 || return 1; }
    render(){
      '"$(cat "$SANDBOX/block.sh")"'
    }
    render
  '
}

echo "=== v1.218.11 BotScan operator-truth ==="

out=$(render true ban 1)
has "$out" "HTTP Exploit Scan" && ok "enabled: HTTP Exploit Scan row rendered" || no "enabled: row"
has "$out" "ENABLED"           && ok "enabled: shows ENABLED"                   || no "enabled: ENABLED"
has "$out" "action=ban"        && ok "enabled: shows action mode"              || no "enabled: action mode"
has "$out" "timer active"      && ok "enabled: shows timer active"             || no "enabled: timer state"
has "$out" "BotGuard disabled != BotScan disabled" && ok "independence note present" || no "independence note"

out=$(render true ban 0)
has "$out" "timer stopped" && ok "enabled+timer-off: shows timer stopped" || no "timer stopped"

out=$(render false both 0)
has "$out" "HTTP Exploit Scan" && has "$out" "DISABLED" && ok "disabled: row shows DISABLED" || no "disabled: row"

# Bot Guard row relabeled to HTTP Guard (display label)
grep -q 'HTTP Guard' "$STATUS" && ok "status: BotGuard relabeled 'HTTP Guard'" || no "status: HTTP Guard label"

# help exposes botscan + the distinction
help=$(cat "$HELP")
has "$help" "botscan" && ok "help: lists botscan" || no "help: botscan"
has "$help" "HTTP Exploit Scanner" && ok "help: HTTP Exploit Scanner label" || no "help: label"
grep -qiE 'independent of botguard|BotGuard is disabled' "$HELP" && ok "help: BotGuard-independence stated" || no "help: independence"

# botscan status carries the label + timer line
bs=$(cat "$BOTSCAN")
has "$bs" "HTTP Exploit Scanner (BotScan)" && ok "botscan status: HTTP Exploit Scanner label" || no "botscan status: label"
grep -q 'Timer:.*nftban-botscan.timer' "$BOTSCAN" && ok "botscan status: timer state line" || no "botscan status: timer"

echo
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then printf 'FAILED: %s\n' "${FAILED[@]}"; exit 1; fi
exit 0
