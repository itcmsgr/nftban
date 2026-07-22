#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.185.0 - BotScan processor deadline + rotation guard test
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="botscan_deadline_rotation_v185_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-14"
# meta:description="CORE-BOTSCAN-PROCESSOR-TIMEOUT-AT-SCALE (v1.185 Lane B) guard: with an unlimited budget the scan processes ALL discovered spool files in one cycle and ALWAYS reaches the analyze/ban step (back-compat); it persists an anti-starvation rotation cursor (valid 0..n-1) and honors a pre-existing cursor without error. The time-bounded partial-batch behavior is validated lab/prod (srv2/srv4); this hermetic test locks the rotation + always-analyze plumbing without timing flakiness."
#
# meta:inventory.files="botscan_deadline_rotation_v185_test.sh"
# meta:inventory.binaries="bash"
# meta:inventory.env_vars="NFTBAN_DATA_DIR,BOTSCAN_SPOOL_DIR,BOTSCAN_SCAN_BUDGET_SECS"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# meta:ta.id="botscan_deadline_rotation_v185_test"
# meta:ta.owner="botscan"
# meta:ta.module="botscan-deadline-rotation"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="policy-gates"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Mirror production: nftban_botscan.sh sources ${NFTBAN_LIB_DIR}/lib/nftban_http_logs.sh
# (which defines the incremental cursor nftban_http_read_incremental). Point LIB_DIR at the
# repo so the cursor is actually loaded — otherwise the scan falls back to a cursor-less
# `tail` and this test would not exercise the real per-file offset behavior.
NFTBAN_LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export NFTBAN_LIB_DIR
LIB_CORE="$NFTBAN_LIB_DIR/core/nftban_botscan.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export NFTBAN_DATA_DIR="$tmp/data"
export BOTSCAN_SPOOL_DIR="$tmp/spool"
export BOTSCAN_PATTERNS_DIR="$tmp/patterns"   # empty → 0 patterns (control-flow only)
export BOTSCAN_STATE_FILE="$tmp/state.db"
export NFTBAN_HTTP_LOG_OFFSET_DIR="$tmp/offsets"
export BOTSCAN_ENABLED="true"
export BOTSCAN_BATCH_SIGNAL_MODE="true"
# v1.209.3: this test re-scans a STATIC spool across cycles to prove the per-file
# cursor is honored (cycle2 reads 0 new bytes). Disable spool reaping so the
# consumed files persist for cycle2; reaping itself is covered by
# botscan_spool_oom_v2093_test.sh.
export BOTSCAN_SPOOL_REAP="false"
mkdir -p "$NFTBAN_DATA_DIR" "$BOTSCAN_SPOOL_DIR" "$BOTSCAN_PATTERNS_DIR" "$tmp/data/botguard"

# 3 spool files with a valid common-log-format line each.
for d in a b c; do
  printf '203.0.113.%s - - [14/Jun/2026:10:00:00 +0000] "GET /x HTTP/1.1" 404 12 "-" "curl"\n' "$d" \
    > "$BOTSCAN_SPOOL_DIR/$d.log"
done

# shellcheck source=/dev/null
source "$LIB_CORE"

rot="$NFTBAN_DATA_DIR/botscan/scan-rotate"

# --- Cycle 1: unlimited budget → all 3 files in one cycle + analyze reached ---
export BOTSCAN_SCAN_BUDGET_SECS=0
out="$(nftban_botscan_process_logs "" 60 2>&1)" || fail "process_logs rc!=0: $out"
echo "$out" | grep -qE '3/3 files this cycle' || fail "expected 3/3 files this cycle; got: $out"
echo "$out" | grep -qE '^Banned: ' || fail "analyze/ban step must always run; got: $out"
[[ -r "$rot" ]] || fail "rotation cursor not persisted"
v="$(cat "$rot")"; [[ "$v" =~ ^[0-9]+$ && "$v" -ge 0 && "$v" -lt 3 ]] || fail "rotation cursor invalid: '$v'"

# --- Cycle 2: same files, unchanged → the per-file cursor must read 0 NEW bytes
#     (proves no whole-file re-scan; the offset from cycle 1 is honored). A pre-existing
#     rotation cursor is also honored without error and stays valid. ---
printf '2\n' > "$rot"
out2="$(nftban_botscan_process_logs "" 60 2>&1)" || fail "process_logs (cycle2) rc!=0: $out2"
echo "$out2" | grep -qE '3/3 files this cycle' || fail "cycle2 expected 3/3 files visited; got: $out2"
echo "$out2" | grep -qE '^Processed: 0 entries' || fail "cycle2 must re-scan NOTHING (cursor); got: $out2"
v2="$(cat "$rot")"; [[ "$v2" =~ ^[0-9]+$ && "$v2" -ge 0 && "$v2" -lt 3 ]] || fail "cycle2 rotation cursor invalid: '$v2'"

# --- budget=0 must NOT print the deadline notice (no false self-bound) ---
echo "$out" | grep -q 'Deadline budget' && fail "unlimited budget must not report a deadline hit"

echo "PASS: botscan deadline/rotation plumbing (full-pass + always-analyze + rotation cursor)"
