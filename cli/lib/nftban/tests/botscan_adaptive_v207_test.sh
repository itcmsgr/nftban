#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.207 BotScan smart-adaptive controller
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="botscan_adaptive_v207_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-26"
# meta:description="Hermetic tests for the v1.207 BotScan smart-adaptive controller (nftban_botscan_adaptive.sh): deterministic pressure_state transitions (load/runtime/mem/iowait), backlog_state, scan_mode selection (FULL/PREFILTERED/FAIR_SHARE/SURVIVAL), the health model invariant that 0-scanned is NEVER clean (disabled!=clean, blind!=clean, budget-hit/backlog-growing visible), and the RECORDING-DISCIPLINE guard (a disabled+never-run module writes NO run-state; a disabled module with a prior run records DISABLED_BY_CONFIG; counters accumulate as *_total). Self-contained sandbox; no network; no nft; reads no real host state."
# meta:input="None (self-contained sandbox)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,jq,awk,mktemp"
# meta:inventory.files=""
# meta:inventory.binaries="bash,jq,awk,mktemp"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_DATA_DIR,BOTSCAN_ENABLED"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
export NFTBAN_LIB_DIR="${REPO_ROOT}/cli/lib/nftban"
SANDBOX=$(mktemp -d); trap 'rm -rf "$SANDBOX"' EXIT
export NFTBAN_DATA_DIR="$SANDBOX/data"; mkdir -p "$NFTBAN_DATA_DIR/botscan"
SRC="$NFTBAN_LIB_DIR/core/nftban_botscan_adaptive.sh"
PASS=0; FAIL=0; FAILED=()
eq(){ [[ "$1" == "$2" ]] && { echo "  [PASS] $3"; PASS=$((PASS+1)); } || { echo "  [FAIL] $3 (want '$2' got '$1')"; FAIL=$((FAIL+1)); FAILED+=("$3"); }; }

# shellcheck source=/dev/null
source "$SRC"
echo "================================================="
echo "v1.207 BotScan smart-adaptive controller test"
echo "================================================="

echo "[T1] pressure_state transitions (load_ratio, runtime_ratio, mem, iowait)"
eq "$(nftban_botscan_pressure_state 0.3 0.1 0 10 5)"  "NORMAL"   "T1.1 idle → NORMAL"
eq "$(nftban_botscan_pressure_state 1.2 0.2 0 50 10)" "ELEVATED" "T1.2 load 1.2x → ELEVATED"
eq "$(nftban_botscan_pressure_state 2.5 0.3 0 60 10)" "HIGH"     "T1.3 load 2.5x → HIGH"
eq "$(nftban_botscan_pressure_state 4.1 0.3 0 60 10)" "CRITICAL" "T1.4 load 4.1x → CRITICAL"
eq "$(nftban_botscan_pressure_state 0.3 0.95 0 10 5)" "CRITICAL" "T1.5 runtime 95% of budget → CRITICAL"
eq "$(nftban_botscan_pressure_state 0.3 0.3 1 10 5)"  "CRITICAL" "T1.6 last-run budget-hit → CRITICAL"
eq "$(nftban_botscan_pressure_state 0.3 0.3 0 92 5)"  "HIGH"     "T1.7 mem 92% → HIGH"

echo "[T2] scan_mode selection"
eq "$(nftban_botscan_select_mode NORMAL STABLE)"     "FULL"        "T2.1 NORMAL → FULL"
eq "$(nftban_botscan_select_mode ELEVATED STABLE)"   "PREFILTERED" "T2.2 ELEVATED → PREFILTERED"
eq "$(nftban_botscan_select_mode ELEVATED GROWING)"  "FAIR_SHARE"  "T2.3 ELEVATED+GROWING → FAIR_SHARE"
eq "$(nftban_botscan_select_mode HIGH STABLE)"       "FAIR_SHARE"  "T2.4 HIGH → FAIR_SHARE"
eq "$(nftban_botscan_select_mode CRITICAL STABLE)"   "SURVIVAL"    "T2.5 CRITICAL → SURVIVAL"
eq "$(nftban_botscan_select_mode NORMAL STARVED)"    "FAIR_SHARE"  "T2.6 NORMAL+STARVED → FAIR_SHARE"

echo "[T3] backlog_state"
eq "$(nftban_botscan_backlog_state 0 1000)"        "DRAINING" "T3.1 0 backlog → DRAINING"
eq "$(nftban_botscan_backlog_state 2000 1000)"     "GROWING"  "T3.2 2x prior → GROWING"
eq "$(nftban_botscan_backlog_state 100000000 100000000)" "STARVED" "T3.3 >64MiB → STARVED"

echo "[T4] health model — 0-scanned is NEVER clean"
eq "$(nftban_botscan_health_state true 0 0 0 STABLE 1 0)"   "DEGRADED_INPUT_BLIND"   "T4.1 enabled, input present, 0 scanned → BLIND (not clean)"
eq "$(nftban_botscan_health_state false 0 0 0 STABLE 0 0)"  "DISABLED_BY_CONFIG"     "T4.2 disabled → DISABLED (not clean)"
eq "$(nftban_botscan_health_state true 5000 0 1 STABLE 1 0)" "DEGRADED_BUDGET_HIT"   "T4.3 budget hit → DEGRADED"
eq "$(nftban_botscan_health_state true 5000 0 0 GROWING 1 0)" "DEGRADED_BACKLOG_GROWING" "T4.4 backlog growing → DEGRADED"
eq "$(nftban_botscan_health_state true 5000 3 0 STABLE 1 0)" "OK_SCANNED_BOTS_FOUND" "T4.5 scanned + bots → OK_BOTS"
eq "$(nftban_botscan_health_state true 5000 0 0 STABLE 1 0)" "OK_SCANNED_NO_BOTS"   "T4.6 scanned, no bots → OK_NO_BOTS (clean ONLY because scanned)"
eq "$(nftban_botscan_health_state true 0 0 0 STABLE 1 1)"   "ERROR_RUNTIME_FAILURE" "T4.7 error flag → ERROR"

echo "[T5] recording-discipline guard"
BOTSCAN_ENABLED=false
nftban_botscan_record_runstate ts=1 health_state=DISABLED_BY_CONFIG >/dev/null 2>&1 || true
eq "$([[ -f "$NFTBAN_DATA_DIR/botscan/runstate.json" ]] && echo yes || echo no)" "no" "T5.1 disabled + never-run → NO run-state file written"
BOTSCAN_ENABLED=true
nftban_botscan_record_runstate ts=2 dur=10 lines_scanned=1000 bans=2 health_state=OK_SCANNED_BOTS_FOUND pressure_state=NORMAL scan_mode=FULL >/dev/null 2>&1
eq "$([[ -f "$NFTBAN_DATA_DIR/botscan/runstate.json" ]] && echo yes || echo no)" "yes" "T5.2 enabled run → run-state written"
eq "$(jq -r '.bans_emitted_total' "$NFTBAN_DATA_DIR/botscan/runstate.json")" "2" "T5.3 bans_total recorded"
BOTSCAN_ENABLED=false
nftban_botscan_record_runstate ts=3 health_state=DISABLED_BY_CONFIG disabled_reason="off" >/dev/null 2>&1
eq "$(jq -r '.health_state' "$NFTBAN_DATA_DIR/botscan/runstate.json")" "DISABLED_BY_CONFIG" "T5.4 disabled WITH prior run → records DISABLED (not clean)"

echo "[T6] counters accumulate (*_total)"
BOTSCAN_ENABLED=true
nftban_botscan_record_runstate ts=4 lines_scanned=500 bans=3 health_state=OK_SCANNED_BOTS_FOUND >/dev/null 2>&1
eq "$(jq -r '.bans_emitted_total' "$NFTBAN_DATA_DIR/botscan/runstate.json")" "5" "T6.1 bans_total accumulates (2+3)"
eq "$(jq -r '.lines_scanned_total' "$NFTBAN_DATA_DIR/botscan/runstate.json")" "1500" "T6.2 lines_scanned_total accumulates (1000+500)"

echo
echo "================================================="
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then printf 'FAILED: %s\n' "${FAILED[@]}"; exit 1; fi
echo "ALL PASS"
