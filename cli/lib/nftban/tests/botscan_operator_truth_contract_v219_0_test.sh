#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.219.0 PR-A BotScan operator-truth contract (shell/docs)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="botscan_operator_truth_contract_v219_0_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-09"
# meta:description="v1.219.0 PR-A (shell/docs, daemon byte-identical) BotScan first-class operator-truth contract. Behaviorally exercises the cheap-read nftban health BotScan render across enabled+active, DEGRADED/blind, and alert-mode fixtures (asserts a blind/degraded scanner renders 'NOT currently enforcing', alert renders DETECT-ONLY, and the render/facts NEVER open access-log content — the cheap-read invariant). Source-asserts: counter truth-fix wiring (signals emitted counter reset+increment+passed, unique_ips passed, lines_prefiltered marked RESERVED_NO_PRODUCER), nftban status DEGRADED honesty + action-mode note + runstate read, search cache-only relabelled 'CACHE ONLY — not currently enforced', support bundle collects botscan + pattern inventory, help draws BotGuard-vs-BotScan and drops 'Automatically bans', docs (TIMERS botscan-not-botguard, README BotScan row, BotGuard-vs-BotScan + recovery-drill docs), dead config keys marked non-functional."
# meta:input="None (extracts + stubs health render; greps sources/docs)"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,awk,grep,jq"
# meta:inventory.files="cli/lib/nftban/core/nftban_botscan.sh,cli/lib/nftban/core/nftban_botscan_adaptive.sh,cli/lib/nftban/cli/cmd_status.sh,cli/lib/nftban/core/nftban_health_checks_modules.sh,cli/lib/nftban/cli/cmd_health.sh,cli/lib/nftban/lib/nftban_botguard_explain.sh,cli/lib/nftban/cli/cmd_support.sh,cli/lib/nftban/cli/cmd_botscan.sh"
# meta:inventory.binaries="bash,awk,grep,jq"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_DATA_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../../../.." && pwd)
BOTSCAN="$REPO/cli/lib/nftban/core/nftban_botscan.sh"
ADAPT="$REPO/cli/lib/nftban/core/nftban_botscan_adaptive.sh"
STATUS="$REPO/cli/lib/nftban/cli/cmd_status.sh"
HMOD="$REPO/cli/lib/nftban/core/nftban_health_checks_modules.sh"
HEALTH="$REPO/cli/lib/nftban/cli/cmd_health.sh"
EXPLAIN="$REPO/cli/lib/nftban/lib/nftban_botguard_explain.sh"
SUPPORT="$REPO/cli/lib/nftban/cli/cmd_support.sh"
CMD="$REPO/cli/lib/nftban/cli/cmd_botscan.sh"

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
PASS=0; FAIL=0; FAILED=()
ok(){ printf "  [PASS] %s\n" "$1"; PASS=$((PASS+1)); }
no(){ printf "  [FAIL] %s\n" "$1"; FAIL=$((FAIL+1)); FAILED+=("$1"); }
has(){ [[ "$1" == *"$2"* ]]; }
hasf(){ grep -Fq -- "$2" "$1"; }

echo "=== v1.219.0 PR-A BotScan operator-truth contract ==="

# ---- Behavioral: extract the cheap-read health render + facts and run with fixtures ----
awk '/^_nftban_health_botscan_facts\(\)/{c=1} c{print} /^_nftban_health_render_botscan\(\)/{r=1} r&&/^}/{print "";exit}' "$HMOD" > "$SB/render.sh"
[[ -s "$SB/render.sh" ]] && ok "extracted health facts+render block" || no "extract health render block"

render(){ # render <enabled> <mode> <timer:active|inactive> <health_state>
  local en="$1" mode="$2" tmr="$3" hs="$4"
  mkdir -p "$SB/conf.d/botscan" "$SB/data/botscan" "$SB/data/botscan/spool"
  printf 'BOTSCAN_ENABLED="%s"\nBOTSCAN_ACTION_MODE="%s"\n' "$en" "$mode" > "$SB/conf.d/botscan/main.conf"
  printf '{"health_state":"%s","last_run_ts":%s,"bans_emitted_total":3}\n' "$hs" "$(date +%s)" > "$SB/data/botscan/runstate.json"
  NFTBAN_CONFIG_DIR="$SB" NFTBAN_DATA_DIR="$SB/data" STIMER="$tmr" bash -c '
    set +e
    systemctl(){ [ "${STIMER:-inactive}" = active ] && return 0 || return 1; }
    export -f systemctl 2>/dev/null || true
    source "'"$SB/render.sh"'"
    _nftban_health_render_botscan
  '
}

out=$(render true both active OK_SCANNED_NO_BOTS)
has "$out" "HTTP Exploit Scanner (BotScan)" && ok "render: BotScan section heading" || no "render heading"
has "$out" "ENABLED + timer active" && has "$out" "enforces via blacklist_manual" && ok "render enabled+active: enforcing" || no "render enabled+active"

out=$(render true both active DEGRADED_INPUT_BLIND)
has "$out" "NOT currently enforcing" && ok "render DEGRADED: 'NOT currently enforcing'" || no "render DEGRADED honesty"

out=$(render true alert active OK_SCANNED_NO_BOTS)
has "$out" "DETECT-ONLY" && ok "render alert-mode: DETECT-ONLY" || no "render alert-mode"

out=$(render false both inactive UNKNOWN)
has "$out" "DISABLED" && ok "render disabled: DISABLED (no bans)" || no "render disabled"

# ---- Cheap-read invariant: facts/render must never read access-log CONTENT ----
if grep -nE 'access\.log|access_log|/var/log/(apache|httpd|nginx)|tail .*log|grep .*access' "$SB/render.sh" >/dev/null 2>&1; then
  no "cheap-read invariant: health render reads access-log content"
else ok "cheap-read invariant: health render has NO access-log content read"; fi
# status BotScan row must also be cheap (runstate/jq/systemctl only, no access-log content)
if awk '/HTTP Exploit Scanner \(BotScan\)/,/BotGuard disabled != BotScan disabled/' "$STATUS" | grep -nE 'access\.log|tail .*/var/log|grep .*access\.log' >/dev/null 2>&1; then
  no "cheap-read invariant: status row reads access-log content"
else ok "cheap-read invariant: status row has NO access-log content read"; fi

# ---- Counter truth-fix wiring ----
grep -q '_BOTSCAN_SIGNALS_EMITTED=0' "$BOTSCAN" && ok "counter: signals counter reset in init_state" || no "counter reset"
grep -q '_BOTSCAN_SIGNALS_EMITTED=$(( ${_BOTSCAN_SIGNALS_EMITTED:-0} + 1 ))' "$BOTSCAN" && ok "counter: write_signal increments" || no "write_signal increment"
grep -q 'signals="${_BOTSCAN_SIGNALS_EMITTED:-0}"' "$BOTSCAN" && ok "counter: signals passed to record_runstate" || no "signals passed"
grep -q 'unique_ips="${#_BOTSCAN_IP_HITS\[@\]}"' "$BOTSCAN" && ok "counter: unique_ips passed to record_runstate" || no "unique_ips passed"
grep -q 'unique_ips_flagged_last' "$ADAPT" && ok "runstate: unique_ips_flagged_last field" || no "unique_ips field"
grep -q 'RESERVED_NO_PRODUCER' "$ADAPT" && ok "runstate: lines_prefiltered marked RESERVED (not faked)" || no "lines_prefiltered honesty"

# ---- Status honesty ----
hasf "$STATUS" "NOT currently enforcing (scanner blind/degraded)" && ok "status: DEGRADED honesty branch" || no "status DEGRADED"
hasf "$STATUS" "DETECT-ONLY, does not ban" && ok "status: alert-mode note" || no "status alert note"
hasf "$STATUS" "runstate.json" && ok "status: reads runstate (cheap counters)" || no "status runstate read"

# ---- Search relabel + kernel-authority preserved ----
hasf "$EXPLAIN" "CACHE ONLY — not currently enforced" && ok "search: cache-only relabelled" || no "search relabel"
# kernel authority not weakened: top-level STATUS still derived from nft reads (search unchanged)
grep -q 'nft get element' "$REPO/cli/lib/nftban/cli/cmd_search.sh" && ok "search: top-level still nft/kernel-authoritative" || no "search kernel authority"

# ---- Health wiring ----
grep -q '_nftban_health_render_botscan' "$HEALTH" && ok "health: BotScan render wired into nftban health" || no "health wiring"
grep -q 'nftban_health_check_botscan' "$HMOD" && ok "health: nftban_health_check_botscan present" || no "health check fn"
# must NOT touch the Go four-axis loop (ModulesJSON frozen — deferred v1.220+)
grep -q 'for mod in botguard ddos portscan loginmon botscan' "$HEALTH" && no "health: botscan wrongly added to Go four-axis loop" || ok "health: Go four-axis loop untouched (ModulesJSON frozen)"

# ---- Support bundle ----
hasf "$SUPPORT" 'mod_dir/botscan.txt' && ok "support: collects botscan.txt" || no "support botscan.txt"
hasf "$SUPPORT" 'pattern inventory' && ok "support: pattern inventory collected" || no "support patterns"
hasf "$SUPPORT" '7 modules incl. BotScan' && ok "support: module count updated" || no "support count"

# ---- Help + config honesty ----
hasf "$CMD" 'BotScan vs BotGuard' && ok "help: BotGuard-vs-BotScan distinction" || no "help distinction"
grep -q 'Automatically bans detected bot scanners' "$CMD" && no "help: stale 'Automatically bans' wording remains" || ok "help: 'always bans' wording removed"
grep -c 'NON-FUNCTIONAL / RESERVED' "$REPO/etc/nftban/conf.d/botscan/main.conf" | grep -q '[34]' && ok "config: dead keys marked non-functional" || no "config dead keys"

# ---- Docs ----
grep -q '| .nftban-botscan.timer. | Every 10min | botscan |' "$REPO/docs/systemd/TIMERS.md" && ok "docs: TIMERS botscan not attributed to botguard" || no "docs TIMERS"
grep -qi 'BotScan.*HTTP Exploit Scanner' "$REPO/README.md" && ok "docs: README BotScan row" || no "docs README"
[[ -f "$REPO/docs/operator/BOTGUARD_VS_BOTSCAN.md" ]] && ok "docs: BotGuard-vs-BotScan contract" || no "docs BotGuard-vs-BotScan"
[[ -f "$REPO/docs/operator/FALSE_POSITIVE_AND_RECOVERY_DRILL.md" ]] && ok "docs: FP recovery drill runbook" || no "docs recovery drill"

echo
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then printf 'FAILED: %s\n' "${FAILED[@]}"; exit 1; fi
exit 0
