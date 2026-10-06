#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.219.0 PR-B BotScan daemon-truth (shell consumes it)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="botscan_daemon_truth_v219_0_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-09"
# meta:description="v1.219.0 PR-B — the shell nftban health BotScan render consumes the daemon-written botscan_consumer_status.json so a BROKEN consumer hand-off (batch_handoff_errors>0 or stale_backlog=true) renders 'CONSUMER HAND-OFF BROKEN — bans NOT reaching the kernel', NOT healthy/enforcing. Asserts: handoff_errors>0 → broken verdict; stale_backlog=true → broken; handoff=0 → not broken; missing consumer status → honest handoff=UNKNOWN (never assumed-healthy). Cheap-read only (jq on the status JSON; no access-log content)."
# meta:input="None (extracts + stubs the health render with consumer-status fixtures)"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,awk,grep,jq"
# meta:inventory.files="cli/lib/nftban/core/nftban_health_checks_modules.sh,cli/lib/nftban/tests/health_strict_harness.sh,internal/botguard/botscan_truth.go"
# meta:inventory.binaries="bash,grep,jq,tr"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_DATA_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="botscan_daemon_truth_v219_0_test"
# meta:ta.owner="botscan"
# meta:ta.module="botscan-health-consumer-truth"
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

# The REAL module, sourced under the dispatcher's strict plane (health_strict_harness.sh);
# an aborted facts read is a failure here, not a DISABLED render that passes.
# shellcheck source=cli/lib/nftban/tests/health_strict_harness.sh
source "$SCRIPT_DIR/health_strict_harness.sh"
hs_init "$SB" && ok "strict harness bound to $HMOD" || { no "strict harness: subject files missing"; exit 1; }
hs_fn_source "${HS_BOTSCAN_READERS[@]}" > "$SB/render.sh" || true
[[ -s "$SB/render.sh" ]] && ok "real facts+render definitions read from the module" || no "facts+render definitions not found"

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
  local rc=0
  NFTBAN_CONFIG_DIR="$SB" NFTBAN_DATA_DIR="$SB/data" HS_TIMER=active \
    hs_call _nftban_health_render_botscan || rc=$?
  # Recorded, not asserted here: render() runs inside $(...), where a counter is lost.
  if [[ "$rc" -ne 0 ]] || hs_err_banner; then
    printf 'render(%s,%s) rc=%s %s\n' "$he" "$stale" "$rc" "$(hs_err_first)" >> "$SB/strict.fail"
  fi
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

if [[ -s "$SB/strict.fail" ]]; then
  no "strict plane: a render aborted or printed the ERR banner: $(tr '\n' ';' < "$SB/strict.fail")"
else ok "strict plane: every render exited 0 with no ERR-trap banner"; fi

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
