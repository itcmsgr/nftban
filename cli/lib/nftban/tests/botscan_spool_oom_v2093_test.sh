#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.209.3 - BotScan collector spool-OOM hybrid fix tests
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="botscan_spool_oom_v2093_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-28"
# meta:description="Locks the v1.209.3 hybrid fix for the remaining BotScan collector OOM (unbounded RAM-backed spool). Hermetic (non-root): off-tmpfs disk-backed spool default; total-dir cap + backpressure (skip appends, no source-offset advance, status file backpressure=1); legacy /run spool one-time cleanup; per-file blind-trim REMOVED; scanner reap of fully-consumed spool files with both safety gates (only files under the spool dir; only when cursor offset>=size); cursor/source-offset preservation under backpressure; spool.status emission; systemd/tmpfiles wiring invariants. tmpfs cgroup-charging itself is proven in lab (live srv3 canary), not here."
# meta:input="None (builds temp fixtures)"
# meta:output="Pass/fail; exit 0 all-pass, 1 on any failure"
# meta:depends="bash,realpath,stat,du,find"
# meta:inventory.files="cli/sbin/nftban-botscan-collector,cli/lib/nftban/core/nftban_botscan.sh,install/systemd/nftban-botscan-collector.service,install/systemd/tmpfiles.d/nftban.conf"
# meta:inventory.binaries="realpath,stat,du,find"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,BOTSCAN_SPOOL_DIR,BOTSCAN_SPOOL_STATUS_FILE,BOTSCAN_SCAN_LOCK_FILE,BOTSCAN_SPOOL_TOTAL_MAX_BYTES,NFTBAN_BOTSCAN_COLLECTOR_OFFSET_DIR,NFTBAN_BOTSCAN_COLLECTOR_ALLOW_ROOTS,BOTSCAN_LOG_PATHS"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="botscan_spool_oom_v2093_test"
# meta:ta.owner="botscan"
# meta:ta.module="botscan-collector"
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
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../../../.." && pwd)"
COLLECTOR="$REPO/cli/sbin/nftban-botscan-collector"
CORE="$REPO/cli/lib/nftban/core/nftban_botscan.sh"
COLLECTOR_UNIT="$REPO/install/systemd/nftban-botscan-collector.service"
TMPFILES="$REPO/install/systemd/tmpfiles.d/nftban.conf"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ALLOW="$WORK/logs"; SPOOL="$WORK/spool"; OFF="$WORK/off"; STATUS="$WORK/spool.status"; LOCK="$WORK/scan.lock"
mkdir -p "$ALLOW"

# run_collector: invoke against fixtures with a test-only allowlist + temp lock/status.
# $1 = BOTSCAN_LOG_PATHS glob, $2 (optional) = BOTSCAN_SPOOL_TOTAL_MAX_BYTES
run_collector(){
  local cap=()
  [[ -n "${2:-}" ]] && cap=("BOTSCAN_SPOOL_TOTAL_MAX_BYTES=$2")
  env NFTBAN_LIB_DIR="$REPO/cli/lib/nftban" \
      BOTSCAN_SPOOL_DIR="$SPOOL" \
      BOTSCAN_SPOOL_STATUS_FILE="$STATUS" \
      BOTSCAN_SCAN_LOCK_FILE="$LOCK" \
      NFTBAN_BOTSCAN_COLLECTOR_OFFSET_DIR="$OFF" \
      NFTBAN_BOTSCAN_COLLECTOR_ALLOW_ROOTS="$ALLOW" \
      BOTSCAN_LOG_PATHS="$1" \
      "${cap[@]}" \
      bash "$COLLECTOR" 2>&1 || true
}
spool_of(){ printf '%s/%s' "$SPOOL" "$(realpath -- "$1" | tr '/' '_')"; }
status_val(){ grep -m1 "^$1=" "$STATUS" 2>/dev/null | cut -d= -f2-; }

echo "=== v1.209.3 BotScan spool-OOM hybrid fix ==="

# T1: default spool path is the DISK-backed /var/lib path (off tmpfs).
if grep -q 'BOTSCAN_SPOOL_DIR:-/var/lib/nftban/botscan/spool' "$COLLECTOR" \
   && grep -q 'BOTSCAN_SPOOL_DIR:=/var/lib/nftban/botscan/spool' "$CORE"; then
  ok "T1 spool default moved off tmpfs → /var/lib/nftban/botscan/spool (collector+scanner)"
else no "T1 off-tmpfs default"; fi

# T2: collector writes to the configured spool + emits a status file.
printf 'l1 GET /a\nl2 POST /xmlrpc.php\n' > "$ALLOW/site.log"
run_collector "$ALLOW/*.log" >/dev/null
sf="$(spool_of "$ALLOW/site.log")"
[[ -f "$sf" && -f "$STATUS" && "$(status_val backpressure)" == "0" ]] \
  && ok "T2 collect→disk spool + spool.status written (backpressure=0)" || no "T2 collect+status" "sf=$sf status=$(cat "$STATUS" 2>/dev/null)"

# T3: per-file blind trim REMOVED — a big source is spooled in full (not shortened).
rm -rf "$SPOOL" "$OFF" "$STATUS"; head -c 6000 /dev/zero | tr '\0' 'x' > "$ALLOW/big.log"; printf '\n' >> "$ALLOW/big.log"
run_collector "$ALLOW/big.log" >/dev/null
sf="$(spool_of "$ALLOW/big.log")"; sz="$(stat -c %s "$sf" 2>/dev/null || echo 0)"
[[ "$sz" -ge 6000 ]] && ok "T3 per-file blind trim removed (full $sz B spooled; no cursor desync)" || no "T3 trim removed" "size=$sz"
# and the legacy trim code is gone from the source:
grep -q 'tail -c "\$SPOOL_MAX_BYTES"' "$COLLECTOR" && no "T3b trim code still present" || ok "T3b blind tail -c trim code removed from collector"

# T4: total-dir cap → BACKPRESSURE: pre-fill spool over a tiny cap, then collect.
rm -rf "$SPOOL" "$OFF" "$STATUS"; mkdir -p "$SPOOL"
head -c 4096 /dev/zero | tr '\0' 'y' > "$SPOOL/_preexisting_blob"   # > cap below
printf 'newline GET /x\n' > "$ALLOW/bp.log"
out="$(run_collector "$ALLOW/bp.log" 1024)"   # cap = 1024 < 4096 already present
bpf="$(spool_of "$ALLOW/bp.log")"
if [[ "$(status_val backpressure)" == "1" ]] && [[ ! -f "$bpf" ]] && echo "$out" | grep -q 'BACKPRESSURE'; then
  ok "T4 over-cap → backpressure=1, NO new append, audited"
else no "T4 backpressure" "bp=$(status_val backpressure) newfile=$( [[ -f "$bpf" ]] && echo yes || echo no )"; fi

# T5: cursor/source-offset PRESERVED under backpressure (no advance → resumes later).
# Under T4 backpressure the source was never read, so no offset state file exists for it.
off_state="$OFF/$(printf '%s' "$(realpath -- "$ALLOW/bp.log")" | tr '/' '_')"
[[ ! -f "$off_state" ]] && ok "T5 backpressure left source offset untouched (no data consumed/lost)" || no "T5 offset preserved" "state exists: $off_state"

# T6: backpressure self-clears once spool drains below cap.
rm -f "$SPOOL/_preexisting_blob"; rm -f "$STATUS"
run_collector "$ALLOW/bp.log" 1024 >/dev/null
[[ "$(status_val backpressure)" == "0" && -f "$(spool_of "$ALLOW/bp.log")" ]] \
  && ok "T6 backpressure self-clears after drain (append resumes)" || no "T6 self-clear" "bp=$(status_val backpressure)"

# T7: legacy /run spool one-time cleanup (guarded to the legacy dir).
LEGACY="$WORK/legacy_run_botscan"; mkdir -p "$LEGACY"; printf 'stale\n' > "$LEGACY/old_spool_file"
rm -rf "$SPOOL" "$OFF" "$STATUS"; printf 'x\n' > "$ALLOW/lc.log"
NFTBAN_LIB_DIR="$REPO/cli/lib/nftban" BOTSCAN_SPOOL_DIR="$SPOOL" BOTSCAN_SPOOL_STATUS_FILE="$STATUS" \
  BOTSCAN_SCAN_LOCK_FILE="$LOCK" NFTBAN_BOTSCAN_COLLECTOR_OFFSET_DIR="$OFF" \
  NFTBAN_BOTSCAN_COLLECTOR_ALLOW_ROOTS="$ALLOW" BOTSCAN_LOG_PATHS="$ALLOW/lc.log" \
  bash "$COLLECTOR" >/dev/null 2>&1 || true
# NOTE: LEGACY_SPOOL_DIR is hardcoded to /run/nftban/botscan in the collector; in this
# hermetic run that real dir is empty/absent so cleanup is a no-op. Assert the cleanup
# LOGIC exists and is guarded to the exact legacy path (static guard).
if grep -q 'LEGACY_SPOOL_DIR="/run/nftban/botscan"' "$COLLECTOR" \
   && grep -Eq 'rm -f "\$LEGACY_SPOOL_DIR"/\*' "$COLLECTOR"; then
  ok "T7 legacy /run spool cleanup present + guarded to exact legacy path"
else no "T7 legacy cleanup"; fi

# ---- Scanner reap helper (source the core, call the function directly) ----
reap_env(){
  export NFTBAN_LIB_DIR="$REPO/cli/lib/nftban"
  # shellcheck source=/dev/null
  source "$CORE" >/dev/null 2>&1
}

# T8: fully-consumed spool file (offset>=size) IS reaped (file + cursor removed).
( reap_env
  sd="$WORK/rspool"; od="$WORK/roff"; mkdir -p "$sd" "$od"
  f="$sd/_var_log_site_log"; printf 'abcdef\n' > "$f"; sz=$(stat -c %s "$f")
  printf '12345:%s\n' "$sz" > "$od/$(printf '%s' "$f" | tr '/' '_')"   # cursor at EOF
  nftban_botscan_reap_consumed_spool "$f" "$sd" "$od"
  [[ ! -f "$f" && ! -f "$od/$(printf '%s' "$f" | tr '/' '_')" ]] && exit 0 || exit 1
) && ok "T8 fully-consumed spool file reaped (file + cursor)" || no "T8 reap consumed"

# T9: PARTIALLY-consumed spool file is NOT reaped (offset < size).
( reap_env
  sd="$WORK/rspool2"; od="$WORK/roff2"; mkdir -p "$sd" "$od"
  f="$sd/_var_log_site_log"; printf 'abcdefghij\n' > "$f"
  printf '12345:3\n' > "$od/$(printf '%s' "$f" | tr '/' '_')"   # cursor at 3 < size
  nftban_botscan_reap_consumed_spool "$f" "$sd" "$od" || true
  [[ -f "$f" ]] && exit 0 || exit 1
) && ok "T9 partially-consumed spool file NOT reaped (cursor < size)" || no "T9 partial kept"

# T10: GATE 1 — a file OUTSIDE the spool dir is NEVER reaped (real-log safety).
( reap_env
  sd="$WORK/rspool3"; od="$WORK/roff3"; mkdir -p "$sd" "$od"
  reallog="$WORK/real_access.log"; printf 'do-not-delete\n' > "$reallog"; sz=$(stat -c %s "$reallog")
  printf '1:%s\n' "$sz" > "$od/$(printf '%s' "$reallog" | tr '/' '_')"   # even if "consumed"
  nftban_botscan_reap_consumed_spool "$reallog" "$sd" "$od" && exit 1 || true   # must return non-0
  [[ -f "$reallog" ]] && exit 0 || exit 1
) && ok "T10 GATE-1: non-spool file (real log) never reaped" || no "T10 real-log safety"

# T11: empty spool file (size 0) is NOT reaped even if cursor present.
( reap_env
  sd="$WORK/rspool4"; od="$WORK/roff4"; mkdir -p "$sd" "$od"
  f="$sd/_empty"; : > "$f"; printf '1:0\n' > "$od/$(printf '%s' "$f" | tr '/' '_')"
  nftban_botscan_reap_consumed_spool "$f" "$sd" "$od" || true
  [[ -f "$f" ]] && exit 0 || exit 1
) && ok "T11 empty (size 0) spool file not reaped" || no "T11 empty-not-reaped"

# T12: systemd unit ReadWritePaths includes the disk spool + keeps MemoryMax=256M.
if grep -Eq '^ReadWritePaths=.*/var/lib/nftban/botscan( |$)' "$COLLECTOR_UNIT" \
   && grep -q '^MemoryMax=256M' "$COLLECTOR_UNIT"; then
  ok "T12 collector unit: RW disk spool + MemoryMax=256M UNCHANGED (no MemoryMax workaround)"
else no "T12 unit RW/MemoryMax"; fi

# T13: tmpfiles creates the disk-backed spool + proc-offsets dirs.
if grep -q 'd /var/lib/nftban/botscan/spool ' "$TMPFILES" \
   && grep -q 'd /var/lib/nftban/botscan/proc-offsets ' "$TMPFILES"; then
  ok "T13 tmpfiles creates botscan/spool + proc-offsets (0750 nftban)"
else no "T13 tmpfiles wiring"; fi

echo ""
echo "=== RESULT: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
