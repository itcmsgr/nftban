#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.208 BotScan trend-history / reporting-truth
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="botscan_trend_v208_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-26"
# meta:description="Hermetic tests for the v1.208 BotScan durable trend-history (nftban_botscan_trend_append + nftban_botscan_history): one append per recorded run, bounded retention trim, NO_INPUT_DISCOVERED dedupe (no-web host does not fill trend), recording-discipline (disabled+never-run writes no trend), JSON validity, corrupt/partial trend line tolerated by the history summarizer, and that the trend reuses the watchdog host-vitals trend rather than creating a duplicate CPU/RAM store. Self-contained sandbox; no network; no nft."
# meta:input="None (self-contained sandbox)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,jq,awk,mktemp,flock"
# meta:inventory.files=""
# meta:inventory.binaries="bash,jq,awk,mktemp,flock"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_DATA_DIR,BOTSCAN_ENABLED,BOTSCAN_TREND_RETENTION"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
export NFTBAN_LIB_DIR="${REPO_ROOT}/cli/lib/nftban"
SANDBOX=$(mktemp -d); trap 'rm -rf "$SANDBOX"' EXIT
export NFTBAN_DATA_DIR="$SANDBOX/data"; mkdir -p "$NFTBAN_DATA_DIR/botscan"
TREND="$NFTBAN_DATA_DIR/botscan/trend.jsonl"
SRC="$NFTBAN_LIB_DIR/core/nftban_botscan_adaptive.sh"
PASS=0; FAIL=0; FAILED=()
eq(){ [[ "$1" == "$2" ]] && { echo "  [PASS] $3"; PASS=$((PASS+1)); } || { echo "  [FAIL] $3 (want '$2' got '$1')"; FAIL=$((FAIL+1)); FAILED+=("$3"); }; }

# shellcheck source=/dev/null
source "$SRC"
echo "================================================="
echo "v1.208 BotScan trend-history test"
echo "================================================="

echo "[T1] enabled run → one trend record appended (valid JSON)"
export BOTSCAN_ENABLED=true
nftban_botscan_record_runstate ts=100 dur=9 lines_scanned=155 bans=0 health_state=OK_SCANNED_NO_BOTS pressure_state=NORMAL scan_mode=FULL backlog_state=STABLE load_ratio=0.30 >/dev/null 2>&1
eq "$([[ -s "$TREND" ]] && echo yes || echo no)" "yes" "T1.1 trend.jsonl created"
eq "$(wc -l < "$TREND" | tr -d ' ')" "1" "T1.2 exactly one record"
eq "$(jq -r '.scan_mode' "$TREND" 2>/dev/null)" "FULL" "T1.3 valid JSON, scan_mode=FULL"
eq "$(jq -r '.source' "$TREND" 2>/dev/null)" "botscan" "T1.4 source=botscan"

echo "[T2] disabled + never-run → NO trend record (recording-discipline)"
rm -f "$TREND" "$NFTBAN_DATA_DIR/botscan/runstate.json"
export BOTSCAN_ENABLED=false
nftban_botscan_record_runstate ts=101 health_state=DISABLED_BY_CONFIG >/dev/null 2>&1 || true
eq "$([[ -f "$TREND" ]] && echo yes || echo no)" "no" "T2.1 disabled+never-run writes NO trend (no noise)"

echo "[T3] NO_INPUT_DISCOVERED dedupe (no-web host doesn't fill trend)"
export BOTSCAN_ENABLED=true
nftban_botscan_record_runstate ts=200 health_state=NO_INPUT_DISCOVERED pressure_state=NORMAL scan_mode=NONE backlog_state=STABLE >/dev/null 2>&1
nftban_botscan_record_runstate ts=201 health_state=NO_INPUT_DISCOVERED pressure_state=NORMAL scan_mode=NONE backlog_state=STABLE >/dev/null 2>&1
nftban_botscan_record_runstate ts=202 health_state=NO_INPUT_DISCOVERED pressure_state=NORMAL scan_mode=NONE backlog_state=STABLE >/dev/null 2>&1
eq "$(wc -l < "$TREND" | tr -d ' ')" "1" "T3.1 three consecutive NO_INPUT_DISCOVERED → ONE trend record (deduped)"
# a real scan after no-input IS recorded (dedupe only collapses consecutive no-input)
nftban_botscan_record_runstate ts=203 dur=5 lines_scanned=10 health_state=OK_SCANNED_NO_BOTS scan_mode=FULL >/dev/null 2>&1
eq "$(wc -l < "$TREND" | tr -d ' ')" "2" "T3.2 OK scan after no-input IS appended"

echo "[T4] bounded retention trim"
rm -f "$TREND"
export BOTSCAN_TREND_RETENTION=5
for i in $(seq 1 12); do
  nftban_botscan_record_runstate ts=$((300+i)) dur=1 lines_scanned=$i health_state=OK_SCANNED_NO_BOTS scan_mode=FULL >/dev/null 2>&1
done
eq "$(wc -l < "$TREND" | tr -d ' ')" "5" "T4.1 retention trims to last 5"
eq "$(jq -r '.ts' "$TREND" 2>/dev/null | tail -1)" "312" "T4.2 newest record retained (ts=312)"
eq "$(jq -r '.ts' "$TREND" 2>/dev/null | head -1)" "308" "T4.3 oldest retained = 308 (12 written, last 5)"
export BOTSCAN_TREND_RETENTION=500

echo "[T5] history summarizer (modes, budget-hit hosts, corrupt-line tolerance)"
rm -f "$TREND"
nftban_botscan_record_runstate ts=400 dur=9 lines_scanned=100 health_state=OK_SCANNED_NO_BOTS scan_mode=FULL backlog_state=STABLE >/dev/null 2>&1
nftban_botscan_record_runstate ts=401 dur=67 lines_scanned=30000 health_state=OK_SCANNED_NO_BOTS scan_mode=SURVIVAL pressure_state=CRITICAL backlog_state=STABLE >/dev/null 2>&1
nftban_botscan_record_runstate ts=402 dur=219 lines_scanned=27000 budget_hit=1 health_state=DEGRADED_BUDGET_HIT scan_mode=FULL backlog_state=GROWING >/dev/null 2>&1
echo 'THIS IS A CORRUPT NON-JSON LINE' >> "$TREND"   # must be tolerated
hist=$(nftban_botscan_history 2>&1)
# scope to the "Scan modes:" section (SURVIVAL also legitimately appears in the Last-OK-scan line)
eq "$(echo "$hist" | sed -n '/Scan modes:/,/Health states:/p' | grep -c 'SURVIVAL')" "1" "T5.1 history shows SURVIVAL once in mode summary"
echo "$hist" | grep -q 'DEGRADED_BUDGET_HIT' && eq ok ok "T5.2 history shows DEGRADED_BUDGET_HIT" || eq miss ok "T5.2 history shows DEGRADED_BUDGET_HIT"
echo "$hist" | grep -qiE 'budget-hit' && eq ok ok "T5.3 history reports budget-hit section" || eq miss ok "T5.3 history reports budget-hit section"
# corrupt line did not crash the summarizer (we got output)
eq "$([[ -n "$hist" ]] && echo ok || echo empty)" "ok" "T5.4 corrupt trend line tolerated (no crash)"

echo "[T6] no duplicate host-vitals store (trend record carries decision, not a CPU/RAM trend)"
# the trend record must NOT contain mem_percent/iowait_percent fields (those live in watchdog trend)
rm -f "$TREND"
nftban_botscan_record_runstate ts=500 dur=9 lines_scanned=100 health_state=OK_SCANNED_NO_BOTS scan_mode=FULL load_ratio=0.5 >/dev/null 2>&1
eq "$(jq -r 'has("mem_percent") or has("iowait_percent")' "$TREND" 2>/dev/null)" "false" "T6.1 no mem/iowait in trend (no dup host-vitals store)"
eq "$(jq -r 'has("load_ratio")' "$TREND" 2>/dev/null)" "true" "T6.2 carries cheap load_ratio context"

echo "[T7] generalized zero-progress dedupe (DEGRADED_INPUT_BLIND empty-log host)"
rm -f "$TREND"
export BOTSCAN_ENABLED=true
# 3 consecutive empty-log scans (0 lines) → DEGRADED_INPUT_BLIND → collapse to 1
nftban_botscan_record_runstate ts=600 dur=2 lines_scanned=0 health_state=DEGRADED_INPUT_BLIND scan_mode=FULL backlog_state=STABLE >/dev/null 2>&1
nftban_botscan_record_runstate ts=601 dur=2 lines_scanned=0 health_state=DEGRADED_INPUT_BLIND scan_mode=FULL backlog_state=STABLE >/dev/null 2>&1
nftban_botscan_record_runstate ts=602 dur=2 lines_scanned=0 health_state=DEGRADED_INPUT_BLIND scan_mode=FULL backlog_state=STABLE >/dev/null 2>&1
eq "$(wc -l < "$TREND" | tr -d ' ')" "1" "T7.1 consecutive DEGRADED_INPUT_BLIND(0-scanned) → ONE record (no spam)"
# a real scan with lines>0 always records (state change / progress)
nftban_botscan_record_runstate ts=603 dur=9 lines_scanned=120 health_state=OK_SCANNED_NO_BOTS scan_mode=FULL >/dev/null 2>&1
eq "$(wc -l < "$TREND" | tr -d ' ')" "2" "T7.2 progress scan after blind IS recorded"
# back to blind → recorded (state change OK→BLIND), then dedupes again
nftban_botscan_record_runstate ts=604 dur=2 lines_scanned=0 health_state=DEGRADED_INPUT_BLIND scan_mode=FULL >/dev/null 2>&1
nftban_botscan_record_runstate ts=605 dur=2 lines_scanned=0 health_state=DEGRADED_INPUT_BLIND scan_mode=FULL >/dev/null 2>&1
eq "$(wc -l < "$TREND" | tr -d ' ')" "3" "T7.3 OK→BLIND transition records once, then dedupes"

echo "[T8] integration: process_logs with ZERO discovered logs → NO_INPUT_DISCOVERED (+ dedupe)"
# authoritative proof of the no-access-log path, independent of any host's log discovery.
T8=$(NFTBAN_LIB_DIR="$NFTBAN_LIB_DIR" NFTBAN_DATA_DIR="$(mktemp -d)" bash -c '
  export BOTSCAN_ENABLED=true
  source "$NFTBAN_LIB_DIR/core/nftban_botscan.sh" >/dev/null 2>&1
  nftban_botscan_discover_logs() { return 0; }   # zero logs discovered
  for _ in 1 2 3; do nftban_botscan_process_logs "" >/dev/null 2>&1 || true; done
  echo "hs=$(jq -r .health_state "$NFTBAN_DATA_DIR/botscan/runstate.json" 2>/dev/null)"
  echo "trec=$(wc -l < "$NFTBAN_DATA_DIR/botscan/trend.jsonl" 2>/dev/null || echo 0)"
' 2>/dev/null)
eq "$(echo "$T8" | grep -oE 'hs=[A-Z_]+' | cut -d= -f2)" "NO_INPUT_DISCOVERED" "T8.1 zero-logs path records NO_INPUT_DISCOVERED (not NO_RUN_YET)"
eq "$(echo "$T8" | grep -oE 'trec=[0-9]+' | cut -d= -f2)" "1" "T8.2 three consecutive no-logs runs → ONE trend record (deduped)"

echo
echo "================================================="
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then printf 'FAILED: %s\n' "${FAILED[@]}"; exit 1; fi
echo "ALL PASS"
