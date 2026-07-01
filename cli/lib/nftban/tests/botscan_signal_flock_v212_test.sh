#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.212.0 - BotScan write_signal flock-guarded append test
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="botscan_signal_flock_v212_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-01"
# meta:description="OPEN_BOTSCAN_LOST_BAN_SIGNAL (v1.212) producer guard: nftban_botscan_write_signal appends the batch signal under a SHARED flock on a stable sibling lockfile so it cooperates with the Go consumer's atomic rename-then-consume hand-off. (A) concurrent writers never corrupt/interleave/lose JSONL lines and the lockfile is created (lock is used). (B) when the flock binary is ABSENT the append still happens (safe degrade, O_APPEND line-atomic) and no lockfile is created. (C) a real write failure (missing dir) is VISIBLE (rc!=0 + stderr ERROR), never silently dropped. Deterministic; shellcheck-clean."
#
# meta:inventory.files="botscan_signal_flock_v212_test.sh"
# meta:inventory.binaries="bash,flock,date,grep,wc"
# meta:inventory.env_vars="NFTBAN_DATA_DIR,BOTSCAN_BATCH_SIGNAL_FILE"
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

export NFTBAN_DATA_DIR="$tmp/data"
mkdir -p "$NFTBAN_DATA_DIR/botguard"
signal_file="$NFTBAN_DATA_DIR/botguard/batch_signals.jsonl"
export BOTSCAN_BATCH_SIGNAL_FILE="$signal_file"

# shellcheck source=/dev/null
source "$NFTBAN_LIB_DIR/core/nftban_botscan.sh"

# --- (A) concurrent writers: no corruption / no interleave / no loss + lock used ---
command -v flock >/dev/null 2>&1 || { echo "SKIP A: flock binary not present on this host"; }
if command -v flock >/dev/null 2>&1; then
    rm -f "$signal_file" "${signal_file}.lock"
    N=40
    for i in $(seq 1 "$N"); do
        ( nftban_botscan_write_signal "10.0.0.$i" 80 ban "testsrc" "reason_$i" ) &
    done
    wait

    total="$(wc -l < "$signal_file")"
    [[ "$total" -eq "$N" ]] || fail "A: expected $N lines, got $total (loss/corruption under concurrency)"

    # every line must be a complete, well-formed JSONL record (no partial/interleaved lines).
    valid="$(grep -cE '^\{"ip":"10\.0\.0\.[0-9]+","score":80,"reasons":\[.*\],"action":"ban","ts":[0-9]+,"family":"ipv4","request_class":".*"\}$' "$signal_file" || true)"
    [[ "$valid" -eq "$N" ]] || fail "A: only $valid/$N lines well-formed (corruption/interleave)"

    # every writer's unique IP present exactly once (no lost writes).
    for i in $(seq 1 "$N"); do
        c="$(grep -cF "\"ip\":\"10.0.0.$i\"" "$signal_file" || true)"
        [[ "$c" -eq 1 ]] || fail "A: ip 10.0.0.$i appears $c times (want 1)"
    done

    [[ -f "${signal_file}.lock" ]] || fail "A: sibling lockfile ${signal_file}.lock was not created (lock not used)"
    echo "PASS A: $N concurrent writers → $N intact JSONL lines, no interleave/loss, lock used"
fi

# --- (B) flock binary ABSENT → safe degrade: append still happens, no lockfile created ---
# Restrict PATH to a fake bin dir that has `date` (the only external tool write_signal needs
# before the flock branch) but NOT flock → `command -v flock` fails → the unlocked-append path.
fakebin="$tmp/fakebin"; mkdir -p "$fakebin"
ln -s "$(command -v date)" "$fakebin/date"
rm -f "$signal_file" "${signal_file}.lock"
( export PATH="$fakebin"; nftban_botscan_write_signal "10.9.9.9" 80 ban "testsrc" "noflock" )
[[ -s "$signal_file" ]] || fail "B: append must still happen when flock is absent (safe degrade)"
grep -qF '"ip":"10.9.9.9"' "$signal_file" || fail "B: absent-flock append missing the signal"
[[ ! -e "${signal_file}.lock" ]] || fail "B: no lockfile should be created on the absent-flock path"
echo "PASS B: flock absent → append still made (safe degrade), no lockfile created"

# --- (C) write failure is VISIBLE (rc!=0 + stderr ERROR), never a silent drop ---
export BOTSCAN_BATCH_SIGNAL_FILE="$tmp/does_not_exist_dir/sig.jsonl"  # parent dir missing → append fails
set +e
err="$(nftban_botscan_write_signal "10.8.8.8" 80 ban "testsrc" "willfail" 2>&1 >/dev/null)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "C: a write failure must return non-zero (got rc=$rc)"
[[ "$err" == *ERROR* ]] || fail "C: a write failure must be visible on stderr (got: '$err')"
echo "PASS C: write failure surfaced (rc=$rc, stderr has ERROR), never silently dropped"

echo "PASS: botscan write_signal flock-guarded append (concurrency-safe + lock used + safe degrade + visible failure)"
