#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="observability_counters_v1229_12_test" meta:type="test" meta:version="1.229.12" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="A08 counter primitive: cumulative semantics, timestamps, UNKNOWN-never-zero, and counters-never-decide"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
set -uo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck source=/dev/null
source "$LIB/observability_counters.sh"
SB=$(mktemp -d); export NFTBAN_DATA_DIR="$SB"
trap 'rm -rf "$SB"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
eq(){ [[ "$2" == "$3" ]] && ok "$1 ($3)" || no "$1: expected '$3' got '$2'"; }

echo "== UNKNOWN is never zero =="
eq "absent namespace"      "$(nftban_obs_get nsx penalty_scan_runs)" "UNKNOWN"
nftban_obs_bump ddos_penalty penalty_scan_runs
eq "absent key in present file" "$(nftban_obs_get ddos_penalty never_written)" "UNKNOWN"
chmod 000 "$SB/state/ddos_penalty_counters" 2>/dev/null
if [[ $EUID -ne 0 ]]; then
  eq "unreadable file" "$(nftban_obs_get ddos_penalty penalty_scan_runs)" "UNKNOWN"
else
  ok "unreadable-file case skipped (running as root)"
fi
chmod 644 "$SB/state/ddos_penalty_counters" 2>/dev/null

echo "== cumulative semantics =="
eq "first bump" "$(nftban_obs_get ddos_penalty penalty_scan_runs)" "1"
nftban_obs_bump ddos_penalty penalty_scan_runs
nftban_obs_bump ddos_penalty penalty_scan_runs
eq "accumulates across calls" "$(nftban_obs_get ddos_penalty penalty_scan_runs)" "3"
nftban_obs_bump ddos_penalty candidate_sources_seen 5
eq "explicit increment" "$(nftban_obs_get ddos_penalty candidate_sources_seen)" "5"
nftban_obs_bump ddos_penalty candidate_sources_seen 2
eq "independent keys do not collide" "$(nftban_obs_get ddos_penalty penalty_scan_runs)" "3"
eq "increment adds"     "$(nftban_obs_get ddos_penalty candidate_sources_seen)" "7"

echo "== timestamps answer 'recently?', totals cannot =="
ts=$(nftban_obs_get ddos_penalty penalty_scan_runs_at)
[[ "$ts" =~ ^[0-9]+$ ]] && ok "last-event timestamp recorded ($ts)" || no "timestamp missing: $ts"

echo "== non-cumulative facts =="
nftban_obs_set ddos_penalty last_scan_rc 0
eq "set rc=0" "$(nftban_obs_get ddos_penalty last_scan_rc)" "0"
nftban_obs_set ddos_penalty last_scan_rc 7
eq "set overwrites, does not accumulate" "$(nftban_obs_get ddos_penalty last_scan_rc)" "7"
eq "set did not disturb counters" "$(nftban_obs_get ddos_penalty penalty_scan_runs)" "3"

echo "== COUNTERS OBSERVE, COUNTERS DO NOT DECIDE =="
# Every entry point must return 0 even when the destination is unusable, so a
# telemetry fault can never alter an enforcement path.
export NFTBAN_DATA_DIR=/proc/nonexistent-cannot-create
nftban_obs_bump ddos_penalty penalty_scan_runs; rc=$?
eq "bump returns 0 on unwritable destination" "$rc" "0"
nftban_obs_set ddos_penalty last_scan_rc 1; rc=$?
eq "set returns 0 on unwritable destination" "$rc" "0"
eq "get still reports UNKNOWN, not 0" "$(nftban_obs_get ddos_penalty penalty_scan_runs)" "UNKNOWN"
nftban_obs_bump "" ""; rc=$?
eq "empty args return 0" "$rc" "0"
export NFTBAN_DATA_DIR="$SB"

echo
echo "TOTAL: pass=$pass fail=$fail"
[[ $fail -eq 0 ]] || exit 1
