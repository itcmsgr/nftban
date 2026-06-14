#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.187 - BotScan throughput (Lane A) guard test
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="botscan_throughput_v187_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-14"
# meta:description="BOTSCAN-SCAN-THROUGHPUT (v1.187 Lane A) guard. (A) FORWARD cursor drains a backlog larger than the per-file cap across successive cycles with NO skipped bytes (every line processed exactly once; not tail-biased). (B) The C-speed candidate PREFILTER keeps lines that could match a pattern (or carry 404) and drops unrelated lines — soundly (a real hit still recorded). (C) The 404-window OPTION 1 fixed-tail re-read is INDEPENDENT of the forward cursor: a 404 flood is still detected on a cycle where the cursor reads 0 new bytes."
#
# meta:inventory.files="botscan_throughput_v187_test.sh"
# meta:inventory.binaries="bash,grep,tail,head"
# meta:inventory.env_vars="NFTBAN_DATA_DIR,BOTSCAN_SPOOL_DIR,BOTSCAN_SCAN_MAX_BYTES_PER_FILE,BOTSCAN_404_THRESHOLD"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NFTBAN_LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export NFTBAN_LIB_DIR
LIB_CORE="$NFTBAN_LIB_DIR/core/nftban_botscan.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
procof() { sed -n 's/^Processed: \([0-9]*\) entries.*/\1/p' <<<"$1"; }
# In batch-signal mode each ban is appended as a JSONL line to this file; that is the
# authoritative ban evidence (the "Banned:" echo carries analyze stdout, not a count).
sigfile() { printf '%s\n' "${NFTBAN_DATA_DIR}/botguard/batch_signals.jsonl"; }
banned_has() { grep -q "\"ip\":\"$1\"" "$(sigfile)" 2>/dev/null; }

# shellcheck source=/dev/null
source "$LIB_CORE"

# ---------------------------------------------------------------------------
# (A) FORWARD cursor — backlog > per-file cap drains across cycles, no skip
# ---------------------------------------------------------------------------
tA="$(mktemp -d)"; trap 'rm -rf "$tA"' EXIT
export NFTBAN_DATA_DIR="$tA/data" BOTSCAN_SPOOL_DIR="$tA/spool" \
       BOTSCAN_PATTERNS_DIR="$tA/patterns" BOTSCAN_STATE_FILE="$tA/state.db" \
       BOTSCAN_LOG_FILE="$tA/botscan.log" \
       BOTSCAN_ENABLED=true BOTSCAN_BATCH_SIGNAL_MODE=true BOTSCAN_SCAN_BUDGET_SECS=0
mkdir -p "$NFTBAN_DATA_DIR" "$BOTSCAN_SPOOL_DIR" "$BOTSCAN_PATTERNS_DIR" "$NFTBAN_DATA_DIR/botguard"
# Apply pure defaults (no real config dir) so BOTSCAN_DEFAULT_* etc. are bound, matching
# the production path (nftban_botscan_check → load_config → process_logs).
export NFTBAN_CONFIG_DIR="$tA/noetc"
nftban_botscan_load_config

# 6 fixed-length 404 lines, distinct IPs (.101-.106) → identical byte length.
line='203.0.113.101 - - [14/Jun/2026:10:00:00 +0000] "GET /x HTTP/1.1" 404 12 "-" "ua"'
L=$(( ${#line} + 1 ))                     # + newline
: > "$BOTSCAN_SPOOL_DIR/a.log"
for d in 1 2 3 4 5 6; do
  printf '203.0.113.10%s - - [14/Jun/2026:10:00:00 +0000] "GET /x HTTP/1.1" 404 12 "-" "ua"\n' "$d" \
    >> "$BOTSCAN_SPOOL_DIR/a.log"
done
export BOTSCAN_SCAN_MAX_BYTES_PER_FILE=$(( 3 * L ))   # cap = exactly 3 lines/cycle
export BOTSCAN_404_THRESHOLD=999                       # no 404 ban interference here

o1="$(nftban_botscan_process_logs "" 60 2>&1)" || fail "A cycle1 rc!=0: $o1"
o2="$(nftban_botscan_process_logs "" 60 2>&1)" || fail "A cycle2 rc!=0: $o2"
o3="$(nftban_botscan_process_logs "" 60 2>&1)" || fail "A cycle3 rc!=0: $o3"
p1="$(procof "$o1")"; p2="$(procof "$o2")"; p3="$(procof "$o3")"
[[ "$p1" == "3" ]] || fail "A: cycle1 should process 3 (cap), got '$p1' ($o1)"
[[ "$p2" == "3" ]] || fail "A: cycle2 should process the NEXT 3 (forward, no tail-skip), got '$p2' ($o2)"
[[ "$p3" == "0" ]] || fail "A: cycle3 should process 0 (drained), got '$p3'"
[[ $(( p1 + p2 )) -eq 6 ]] || fail "A: total processed must equal all 6 lines (no skip), got $((p1+p2))"
echo "PASS A: forward cursor drains backlog across cycles with no skipped bytes"

# ---------------------------------------------------------------------------
# (B) PREFILTER soundness — candidate kept (hit recorded), unrelated dropped
# ---------------------------------------------------------------------------
tB="$(mktemp -d)"; trap 'rm -rf "$tA" "$tB"' EXIT
export NFTBAN_DATA_DIR="$tB/data" BOTSCAN_SPOOL_DIR="$tB/spool" \
       BOTSCAN_PATTERNS_DIR="$tB/patterns" BOTSCAN_STATE_FILE="$tB/state.db" \
       BOTSCAN_LOG_FILE="$tB/botscan.log"
mkdir -p "$NFTBAN_DATA_DIR" "$BOTSCAN_SPOOL_DIR" "$BOTSCAN_PATTERNS_DIR" "$NFTBAN_DATA_DIR/botguard"
export BOTSCAN_404_TRACKING=false                     # isolate the pattern keeper (no 404 keeper)
unset BOTSCAN_SCAN_MAX_BYTES_PER_FILE
# One enabled useragent pattern. NAME|PATTERN|MATCH|THRESH|WINDOW|BAN|ENABLED|DESC
printf 'BADUA|BadCrawler|useragent|1|60|3600|true|test bad UA\n' > "$BOTSCAN_PATTERNS_DIR/test.patterns"
# Line 1: matching UA + 200 (candidate). Line 2: unrelated UA + 200 (must be dropped).
{
  printf '203.0.113.7 - - [14/Jun/2026:10:00:00 +0000] "GET /a HTTP/1.1" 200 9 "-" "BadCrawler/1.0"\n'
  printf '203.0.113.8 - - [14/Jun/2026:10:00:00 +0000] "GET /b HTTP/1.1" 200 9 "-" "Mozilla/5.0"\n'
} > "$BOTSCAN_SPOOL_DIR/a.log"
# Run NOT in a subshell so the detector state arrays persist for inspection. Assert at the
# DETECTION level (what the prefilter actually governs): the candidate reaches the matcher
# and is tracked; the unrelated line is dropped. (The downstream pattern-BAN word-split is
# a separate pre-existing IFS defect — see V1_187_FINDING_BOTSCAN_PATTERN_BAN_IFS.md — and
# is deliberately NOT relied on here so this lane's test stays scoped to throughput.)
nftban_botscan_process_logs "" 60 > "$tB/out" 2>&1 || fail "B rc!=0: $(cat "$tB/out")"
pb="$(procof "$(cat "$tB/out")")"
[[ "$pb" == "1" ]] || fail "B: prefilter must keep ONLY the candidate (1), got '$pb' ($(cat "$tB/out"))"
[[ -n "${_BOTSCAN_IP_HITS[203.0.113.7]:-}" ]] || fail "B: candidate (matching UA) must reach the matcher and be tracked — prefilter dropped a real candidate"
[[ -z "${_BOTSCAN_IP_HITS[203.0.113.8]:-}" ]] || fail "B: unrelated line must be dropped by the prefilter (not tracked)"
echo "PASS B: prefilter drops unrelated lines, keeps candidates (sound — no detection regression)"

# ---------------------------------------------------------------------------
# (C) 404-window fixed-tail is INDEPENDENT of the forward cursor
# ---------------------------------------------------------------------------
tC="$(mktemp -d)"; trap 'rm -rf "$tA" "$tB" "$tC"' EXIT
export NFTBAN_DATA_DIR="$tC/data" BOTSCAN_SPOOL_DIR="$tC/spool" \
       BOTSCAN_PATTERNS_DIR="$tC/patterns" BOTSCAN_STATE_FILE="$tC/state.db" \
       BOTSCAN_LOG_FILE="$tC/botscan.log" \
       BOTSCAN_404_TRACKING=true BOTSCAN_404_THRESHOLD=3 BOTSCAN_404_WINDOW=300
mkdir -p "$NFTBAN_DATA_DIR" "$BOTSCAN_SPOOL_DIR" "$BOTSCAN_PATTERNS_DIR" "$NFTBAN_DATA_DIR/botguard"
# 4 x 404 from ONE IP → exceeds threshold 3.
for i in 1 2 3 4; do
  printf '198.51.100.5 - - [14/Jun/2026:10:00:0%s +0000] "GET /m%s HTTP/1.1" 404 12 "-" "ua"\n' "$i" "$i" \
    >> "$BOTSCAN_SPOOL_DIR/a.log"
done
oc1="$(nftban_botscan_process_logs "" 60 2>&1)" || fail "C cycle1 rc!=0: $oc1"
banned_has "198.51.100.5" || fail "C: 404 flood must ban on cycle1 ($oc1)"
# Cycle 2: forward cursor reads 0 NEW bytes, yet the fixed-tail re-read still sees the flood.
: > "$(sigfile)"   # clear so a cycle-2 ban is unambiguously NEW
oc2="$(nftban_botscan_process_logs "" 60 2>&1)" || fail "C cycle2 rc!=0: $oc2"
[[ "$(procof "$oc2")" == "0" ]] || fail "C: cycle2 cursor must read 0 new bytes, got '$(procof "$oc2")'"
banned_has "198.51.100.5" || fail "C: 404 detection must be INDEPENDENT of the cursor (still ban on cycle2 with 0 new bytes) ($oc2)"
echo "PASS C: 404 fixed-tail re-read is independent of the forward cursor"

echo "PASS: botscan throughput (Lane A) — forward cursor + prefilter + 404 fixed-tail"
