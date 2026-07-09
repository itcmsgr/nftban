#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.219.0 PR-B BotScan daemon-truth (shell consumes it)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="botscan_daemon_truth_v219_0_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-09"
# meta:description="v1.219.0 PR-B — the shell nftban health BotScan render consumes the daemon-written botscan_consumer_status.json so a BROKEN consumer hand-off (batch_handoff_errors>0 or stale_backlog=true) renders 'CONSUMER HAND-OFF BROKEN — bans NOT reaching the kernel', NOT healthy/enforcing. Asserts: handoff_errors>0 → broken verdict; stale_backlog=true → broken; handoff=0 → not broken; missing consumer status → honest handoff=UNKNOWN (never assumed-healthy). Cheap-read only (jq on the status JSON; no access-log content)."
# meta:input="None (extracts + stubs the health render with consumer-status fixtures)"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,awk,grep,jq"
# meta:inventory.files="cli/lib/nftban/core/nftban_health_checks_modules.sh,internal/botguard/botscan_truth.go"
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
HMOD="$REPO/cli/lib/nftban/core/nftban_health_checks_modules.sh"
GOSRC="$REPO/internal/botguard/botscan_truth.go"

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
PASS=0; FAIL=0; FAILED=()
ok(){ printf "  [PASS] %s\n" "$1"; PASS=$((PASS+1)); }
no(){ printf "  [FAIL] %s\n" "$1"; FAIL=$((FAIL+1)); FAILED+=("$1"); }
has(){ [[ "$1" == *"$2"* ]]; }

echo "=== v1.219.0 PR-B BotScan daemon-truth (shell consumes handoff status) ==="

awk '/^_nftban_health_botscan_facts\(\)/{c=1} c{print} /^_nftban_health_render_botscan\(\)/{r=1} r&&/^}/{print "";exit}' "$HMOD" > "$SB/render.sh"
[[ -s "$SB/render.sh" ]] && ok "extracted health facts+render block" || no "extract render block"

# render <handoff_errors|MISSING> <stale:true|false>
render(){
  local he="$1" stale="$2"
  mkdir -p "$SB/conf.d/botscan" "$SB/data/botscan" "$SB/data/botguard"
  printf 'BOTSCAN_ENABLED="true"\nBOTSCAN_ACTION_MODE="both"\n' > "$SB/conf.d/botscan/main.conf"
  printf '{"health_state":"OK_SCANNED_NO_BOTS","last_run_ts":%s,"bans_emitted_total":5}\n' "$(date +%s)" > "$SB/data/botscan/runstate.json"
  rm -f "$SB/data/botguard/botscan_consumer_status.json"
  if [[ "$he" != MISSING ]]; then
    printf '{"batch_handoff_errors":%s,"batch_consumer_stale_backlog":%s}\n' "$he" "$stale" > "$SB/data/botguard/botscan_consumer_status.json"
  fi
  NFTBAN_CONFIG_DIR="$SB" NFTBAN_DATA_DIR="$SB/data" STIMER=active bash -c '
    set +e
    systemctl(){ [ "${STIMER:-}" = active ] && return 0 || return 1; }
    source "'"$SB/render.sh"'"
    _nftban_health_render_botscan
  '
}

out=$(render 3 true)
has "$out" "CONSUMER HAND-OFF BROKEN" && ok "handoff_errors>0: renders HAND-OFF BROKEN (not healthy)" || no "broken handoff not surfaced"
has "$out" "bans NOT reaching the kernel" && ok "broken handoff: 'bans NOT reaching the kernel'" || no "broken handoff wording"

out=$(render 0 true)
has "$out" "CONSUMER HAND-OFF BROKEN" && ok "stale_backlog=true: broken (even with 0 errors)" || no "stale not treated as broken"

out=$(render 0 false)
has "$out" "CONSUMER HAND-OFF BROKEN" && no "healthy handoff wrongly flagged broken" || ok "handoff_errors=0 + not stale: NOT broken"
has "$out" "ENABLED + timer active" && ok "healthy handoff: enforcing verdict" || no "healthy verdict"

out=$(render MISSING false)
has "$out" "handoff=UNKNOWN" && ok "missing daemon status: honest UNKNOWN (not assumed-healthy)" || no "missing status not UNKNOWN"

# Go side wired + present
grep -q 'defer m.writeBotscanConsumerStatus()' "$REPO/internal/botguard/guard.go" && ok "go: consumer status published every cycle (defer)" || no "go: status not wired"
grep -q 'm.appendBotscanEvidence(sig' "$REPO/internal/botguard/guard.go" && ok "go: durable evidence recorded on ban" || no "go: evidence not wired"
[[ -f "$GOSRC" ]] && grep -q 'batch_signals.jsonl consume/delete' "$GOSRC" && ok "go: evidence documented to survive consume" || no "go: evidence file"

# cheap-read invariant still holds (no access-log content read in the extended facts/render)
if grep -nE 'access\.log|/var/log/(apache|httpd|nginx)|tail .*log' "$SB/render.sh" >/dev/null 2>&1; then
  no "cheap-read invariant: handoff render reads access-log content"
else ok "cheap-read invariant: handoff render still access-log-content-free"; fi

echo
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then printf 'FAILED: %s\n' "${FAILED[@]}"; exit 1; fi
exit 0
