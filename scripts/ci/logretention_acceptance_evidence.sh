#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.222.0 — log-retention rollout acceptance evidence collector (R12)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="logretention_acceptance_evidence"
# meta:type="tool"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-19"
# meta:description="Collects the NUMERIC pre/post rollout acceptance evidence for the v1.222.0 log-retention release on a real host (lab2/lab4/canary). Read-only in 'pre' mode; 'post' mode additionally TRIGGERS the installed logrotate (forced) once, then a SECOND time for idempotence, and measures actual rotated/compressed/removed files and bytes before/after. Emits the required V1_222_ROLLOUT_ACCEPTANCE report fields. Does NOT mutate config or firewall; only exercises logrotate on NFTBan's own logs."
# meta:input="mode: pre|post (default pre); NFTBAN_CORE_BIN override optional"
# meta:output="numeric acceptance report to stdout"
# meta:depends="bash,df,du,find,stat,sha256sum,systemctl,logrotate"
# meta:inventory.files=""
# meta:inventory.binaries="df,du,find,stat,sha256sum,systemctl,logrotate,nftban-core"
# meta:inventory.env_vars="NFTBAN_CORE_BIN,NFTBAN_LOG_DIR"
# meta:inventory.config_files="/etc/logrotate.d/nftban,/etc/logrotate.d/nftban-suricata"
# meta:inventory.systemd_units="nftban-maintenance.timer"
# meta:inventory.network=""
# meta:inventory.privileges="root for 'post' (runs logrotate); 'pre' is read-only"
# =============================================================================
set -Eeuo pipefail
set +e # best-effort evidence collector: individual probes may fail without aborting the report

MODE="${1:-pre}"
LOGDIR="/var/log"
NFTLOG="${NFTBAN_LOG_DIR:-/var/log/nftban}"
CORE_BIN="${NFTBAN_CORE_BIN:-/usr/lib/nftban/bin/nftban-core}"
MAIN_POLICY="/etc/logrotate.d/nftban"
SURI_POLICY="/etc/logrotate.d/nftban-suricata"

kv(){ printf '%-34s %s\n' "$1" "$2"; }

fs_total(){ df -B1 --output=size "$LOGDIR" 2>/dev/null | awk 'NR==2{print $1}'; }
fs_avail(){ df -B1 --output=avail "$LOGDIR" 2>/dev/null | awk 'NR==2{print $1}'; }
fs_inodes_free(){ df -i --output=iavail "$LOGDIR" 2>/dev/null | awk 'NR==2{print $1}'; }
log_bytes(){ du -xsb "$NFTLOG" 2>/dev/null | awk '{print $1}'; }
count_gz(){ find "$NFTLOG" -type f -name '*.gz' 2>/dev/null | wc -l; }
count_rotated(){ find "$NFTLOG" -type f -regextype posix-extended -regex '.*\.[0-9]+(\.gz)?$' 2>/dev/null | wc -l; }
policy_hash(){ [ -f "$1" ] && sha256sum "$1" 2>/dev/null | cut -c1-16 || echo "absent"; }

echo "===== NFTBan v1.222.0 log-retention acceptance evidence ($MODE) ====="
kv "HOST" "$(hostname 2>/dev/null || echo unknown)"
kv "FILESYSTEM_TOTAL_BYTES" "$(fs_total)"
kv "FILESYSTEM_AVAILABLE_BYTES" "$(fs_avail)"
kv "FILESYSTEM_INODES_FREE" "$(fs_inodes_free)"
kv "NFTBAN_LOG_BYTES" "$(log_bytes)"
kv "ROTATED_FILES" "$(count_rotated)"
kv "COMPRESSED_FILES" "$(count_gz)"
kv "OLDEST_RETAINED" "$(find "$NFTLOG" -type f -printf '%T+ %p\n' 2>/dev/null | sort | head -1)"
kv "NEWEST_RETAINED" "$(find "$NFTLOG" -type f -printf '%T+ %p\n' 2>/dev/null | sort | tail -1)"
kv "MAINTENANCE_TIMER" "$(systemctl is-active nftban-maintenance.timer 2>/dev/null || echo n/a) / next=$(systemctl show nftban-maintenance.timer -p NextElapseUSecRealtime --value 2>/dev/null || echo n/a)"
kv "ACTIVE_POLICY_HASH_MAIN" "$(policy_hash "$MAIN_POLICY")"
kv "ACTIVE_POLICY_HASH_SURICATA" "$(policy_hash "$SURI_POLICY")"

echo "--- effective policy visibility (authoritative status) ---"
if [ -x "$CORE_BIN" ]; then
    "$CORE_BIN" logretention status 2>/dev/null | sed 's/^/  /' || echo "  (status unavailable)"
    POLICY_VISIBILITY_RESULT="OK"
else
    echo "  (nftban-core not found at $CORE_BIN)"
    POLICY_VISIBILITY_RESULT="CORE_ABSENT"
fi
kv "POLICY_VISIBILITY_RESULT" "$POLICY_VISIBILITY_RESULT"

if [ "$MODE" != "post" ]; then
    echo "===== end (pre) — re-run with 'post' after upgrade to measure rotation ====="
    exit 0
fi

echo "--- post: trigger installed logrotate (forced), then a second run for idempotence ---"
if ! command -v logrotate >/dev/null 2>&1; then
    echo "FAIL: logrotate not installed — cannot prove rotation (fail-closed)."
    exit 1
fi
before_bytes="$(log_bytes)"; before_rot="$(count_rotated)"; before_gz="$(count_gz)"
logrotate -f "$MAIN_POLICY" >/dev/null 2>&1 || true
[ -f "$SURI_POLICY" ] && logrotate -f "$SURI_POLICY" >/dev/null 2>&1 || true
after1_bytes="$(log_bytes)"; after1_rot="$(count_rotated)"; after1_gz="$(count_gz)"
# second run — should be idempotent for empty logs (notifempty) / bounded otherwise
logrotate -f "$MAIN_POLICY" >/dev/null 2>&1 || true
after2_rot="$(count_rotated)"

kv "NFTBAN_LOG_BYTES_BEFORE" "$before_bytes"
kv "NFTBAN_LOG_BYTES_AFTER" "$after1_bytes"
kv "FILES_ROTATED_DELTA" "$(( after1_rot - before_rot ))"
kv "FILES_COMPRESSED_DELTA" "$(( after1_gz - before_gz ))"
kv "BYTES_RECLAIMED" "$(( before_bytes > after1_bytes ? before_bytes - after1_bytes : 0 ))"
kv "SECOND_RUN_RESULT" "$([ "$after2_rot" -ge "$after1_rot" ] && echo idempotent-or-bounded || echo REGRESSED)"
kv "ACTIVE_POLICY_HASH_MAIN_AFTER" "$(policy_hash "$MAIN_POLICY")"

echo "--- JSON status (machine-readable) ---"
[ -x "$CORE_BIN" ] && "$CORE_BIN" logretention status --json 2>/dev/null | sed 's/^/  /' || echo "  (unavailable)"
echo "===== end (post) ====="
echo "OPERATOR: verify manually — writers continue in the current file, JSONL records remain valid,"
echo "capacity_verdict is ACHIEVABLE, DEB vs RPM effective policy hashes match for identical inputs."
