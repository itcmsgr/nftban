#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.187.1 - BotScan A4 404-tail bounding guard test
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="botscan_404_tail_bound_v1871_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-14"
# meta:description="BOTSCAN-404-TAIL-UNBOUNDED (v1.187.1) guard: nftban_botscan_count_404_tail is now BOUNDED. (A) per-cycle total-bytes backstop covers only a subset of files per cycle and the 404-rotate cursor advances so the remaining files are covered next cycle (anti-starvation). (B) the shared cycle soft-deadline breaks A4 cleanly between files but always covers >=1 file (forward progress). (C) 404-flood detection is preserved: a flooding IP in a covered file's tail still reaches the threshold. Deterministic (byte-cap + rotation + past-deadline), no timing flakiness."
#
# meta:inventory.files="botscan_404_tail_bound_v1871_test.sh"
# meta:inventory.binaries="bash,tail,grep"
# meta:inventory.env_vars="NFTBAN_DATA_DIR,BOTSCAN_404_TAIL_BYTES,BOTSCAN_404_TAIL_TOTAL_BYTES"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NFTBAN_LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"; export NFTBAN_LIB_DIR
fail() { echo "FAIL: $*" >&2; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export NFTBAN_DATA_DIR="$tmp/data" BOTSCAN_PATTERNS_DIR="$tmp/patterns" \
       BOTSCAN_STATE_FILE="$tmp/s.db" BOTSCAN_LOG_FILE="$tmp/b.log" \
       NFTBAN_CONFIG_DIR="$tmp/noetc" BOTSCAN_ENABLED=true BOTSCAN_404_TRACKING=true
mkdir -p "$NFTBAN_DATA_DIR/botscan" "$BOTSCAN_PATTERNS_DIR" "$tmp/spool"
# shellcheck source=/dev/null
source "$NFTBAN_LIB_DIR/core/nftban_botscan.sh"; nftban_botscan_load_config

# 4 spool files; file "c" carries a 404 flood (5x from 198.51.100.9). One 404 line each elsewhere.
mk() { printf '%s - - [14/Jun/2026:10:00:0%s +0000] "GET /x%s HTTP/1.1" 404 9 "-" "ua"\n' "$1" "${3:-0}" "${3:-0}"; }
mk 203.0.113.1 > "$tmp/spool/a.log"
mk 203.0.113.2 > "$tmp/spool/b.log"
for i in 1 2 3 4 5; do mk 198.51.100.9 _ "$i"; done > "$tmp/spool/c.log"
mk 203.0.113.4 > "$tmp/spool/d.log"
FILES=("$tmp/spool/a.log" "$tmp/spool/b.log" "$tmp/spool/c.log" "$tmp/spool/d.log")
rotf="$NFTBAN_DATA_DIR/botscan/404-rotate"

# --- (A) byte-cap covers 2 files/cycle + rotation advances; flood caught when "c" is covered ---
export BOTSCAN_404_TAIL_BYTES=4096 BOTSCAN_404_TAIL_TOTAL_BYTES=8192   # 8192/4096 = 2 files/cycle
rm -f "$rotf"
nftban_botscan_count_404_tail 0 0 "${FILES[@]}"          # cycle 1: covers idx 0,1 (a,b)
v="$(cat "$rotf")"; [[ "$v" == "2" ]] || fail "A: cycle1 should cover 2 files → rot=2, got '$v'"
[[ -z "${_BOTSCAN_IP_404_COUNT[198.51.100.9]:-}" ]] || fail "A: flood file c (idx2) not covered yet in cycle1"
nftban_botscan_count_404_tail 0 0 "${FILES[@]}"          # cycle 2: covers idx 2,3 (c,d)
v="$(cat "$rotf")"; [[ "$v" == "0" ]] || fail "A: cycle2 should wrap → rot=0, got '$v'"
[[ "${_BOTSCAN_IP_404_COUNT[198.51.100.9]:-0}" -ge 3 ]] || fail "A: flood IP must reach threshold when c covered (got ${_BOTSCAN_IP_404_COUNT[198.51.100.9]:-0})"
echo "PASS A: byte-cap covers a subset/cycle, rotation advances, all files covered across cycles, flood preserved"

# --- (B) shared soft-deadline already exceeded → A4 covers exactly 1 file (forward progress), then breaks ---
export BOTSCAN_404_TAIL_TOTAL_BYTES=33554432   # cap not the limiter here
rm -f "$rotf"
# start_secs far in the past so (SECONDS - start_secs) >= budget immediately
nftban_botscan_count_404_tail $(( SECONDS - 9999 )) 1 "${FILES[@]}"
v="$(cat "$rotf")"; [[ "$v" == "1" ]] || fail "B: past-deadline must still cover >=1 file → rot=1, got '$v'"
echo "PASS B: soft-deadline breaks cleanly but always covers >=1 file (no starvation)"

# --- (C) no budget, no tight cap → covers ALL files in one cycle (back-compat for small fleets) ---
export BOTSCAN_404_TAIL_TOTAL_BYTES=33554432
rm -f "$rotf"
nftban_botscan_count_404_tail 0 0 "${FILES[@]}"
v="$(cat "$rotf")"; [[ "$v" == "0" ]] || fail "C: covering all 4 files wraps rot to 0, got '$v'"
[[ "${_BOTSCAN_IP_404_COUNT[198.51.100.9]:-0}" -ge 3 ]] || fail "C: flood counted when all files covered"
echo "PASS C: unbounded-budget small-fleet path still covers all files in one cycle"

echo "PASS: botscan A4 404-tail bounding (cap + rotation + soft-deadline + flood preserved)"
