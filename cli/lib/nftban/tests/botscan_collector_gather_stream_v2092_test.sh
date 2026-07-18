#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.209.2 - BotScan collector gather streaming test
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Prove the v1.209.2 gather hotfix — streaming nftban_http_read_incremental
#          straight to the spool (instead of new="$(...)") preserves cursor/no-dup/no-loss
#          semantics while removing the per-source bash-variable slurp that OOM'd the
#          collector cgroup (256M) on heavy hosts.
#
# meta:name="botscan_collector_gather_stream_v2092_test" meta:type="test" meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:output="Pass/fail; exit 0 all-pass, 1 on any failure"
# meta:inventory.files="botscan_collector_gather_stream_v2092_test.sh"
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_HTTP_LOG_OFFSET_DIR,NFTBAN_HTTP_LOG_MAX_BYTES"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../../../.." && pwd)"
HELPER="$REPO/cli/lib/nftban/lib/nftban_http_logs.sh"
COLLECTOR="$REPO/cli/sbin/nftban-botscan-collector"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

# shellcheck source=/dev/null
source "$HELPER" || { echo "cannot source $HELPER"; exit 1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export NFTBAN_HTTP_LOG_OFFSET_DIR="$WORK/offsets"
export NFTBAN_HTTP_LOG_MAX_BYTES=$((1024*1024))

LOG="$WORK/access.log"; SPF="$WORK/spool"

# gather_one — the EXACT v1.209.2 streaming gather primitive from the collector.
gather_one(){
  local canon="$1" spf="$2" _bsz sz
  _bsz="$(stat -c %s "$spf" 2>/dev/null || echo 0)"
  nftban_http_read_incremental "$canon" 2>/dev/null >> "$spf" || return 1
  sz="$(stat -c %s "$spf" 2>/dev/null || echo 0)"
  [[ "$sz" -le "$_bsz" ]] && return 2   # no NEW bytes
  printf '\n' >> "$spf" 2>/dev/null || true
  return 0
}

echo "=== v1.209.2 BotScan collector gather streaming ==="

# T0: structural — the collector no longer slurps into a bash variable; it streams.
if grep -qE 'new="\$\(nftban_http_read_incremental' "$COLLECTOR"; then
  no "T0 collector still uses new=\$(read_incremental) bash slurp"
else ok "T0 collector no longer captures read into a bash variable (no 10MB/source slurp)"; fi
grep -qE 'nftban_http_read_incremental "\$canon" 2>/dev/null >> "\$spf"' "$COLLECTOR" \
  && ok "T0 collector streams read_incremental >> spool" || no "T0 streaming append not found in collector"

# T1: cycle 1 — new bytes stream to spool, cursor advances.
printf 'A line1\nB line2\nC line3\n' > "$LOG"
rc=0; gather_one "$LOG" "$SPF" || rc=$?
[[ "$rc" == 0 ]] && ok "T1 first gather returns new-data" || no "T1 rc=$rc"
grep -q 'A line1' "$SPF" && grep -q 'C line3' "$SPF" && ok "T1 new bytes reached spool" || no "T1 spool missing lines"
[[ -s "$NFTBAN_HTTP_LOG_OFFSET_DIR/$(printf '%s' "$LOG"|tr '/' '_')" ]] && ok "T1 cursor/offset persisted" || no "T1 no offset state"

# T2: cycle 2 — NO new bytes → no duplicate, spool unchanged, returns no-new.
sz_before="$(stat -c %s "$SPF")"
rc=0; gather_one "$LOG" "$SPF" || rc=$?
[[ "$rc" == 2 ]] && ok "T2 no-new-bytes returns skip" || no "T2 rc=$rc (expected 2)"
[[ "$(stat -c %s "$SPF")" == "$sz_before" ]] && ok "T2 spool unchanged (no duplicate)" || no "T2 spool grew on no-new"
[[ "$(grep -c 'A line1' "$SPF")" == 1 ]] && ok "T2 line A present exactly once (no dup)" || no "T2 line A duplicated"

# T3: append new lines → only the NEW lines appended (no loss, no dup of old).
printf 'D line4\nE line5\n' >> "$LOG"
rc=0; gather_one "$LOG" "$SPF" || rc=$?
[[ "$rc" == 0 ]] && ok "T3 new append returns new-data" || no "T3 rc=$rc"
[[ "$(grep -c 'D line4' "$SPF")" == 1 && "$(grep -c 'E line5' "$SPF")" == 1 ]] && ok "T3 new lines appended exactly once" || no "T3 new lines dup/lost"
[[ "$(grep -c 'A line1' "$SPF")" == 1 && "$(grep -c 'C line3' "$SPF")" == 1 ]] && ok "T3 old lines NOT re-appended (no dup)" || no "T3 old lines duplicated"
# every produced log line is present exactly once → no loss across cycles
miss=0; for l in 'A line1' 'B line2' 'C line3' 'D line4' 'E line5'; do [[ "$(grep -c "$l" "$SPF")" == 1 ]] || miss=1; done
[[ "$miss" == 0 ]] && ok "T3 all 5 lines present exactly once (no loss, no dup)" || no "T3 line accounting off"

# T4: rotation — replace the file (new inode) → re-read from BOF, no loss.
rm -f "$SPF"; : > "$SPF"
printf 'R rotated1\nR rotated2\n' > "$LOG"   # new inode (rm+create) / smaller size → rotation path
rc=0; gather_one "$LOG" "$SPF" || rc=$?
grep -q 'R rotated1' "$SPF" && grep -q 'R rotated2' "$SPF" && ok "T4 rotation re-reads from BOF" || no "T4 rotation lost lines"

# T5: empty file safe (no new bytes, no crash).
LOG2="$WORK/empty.log"; : > "$LOG2"; ESPF="$WORK/espool"; : > "$ESPF"
rc=0; gather_one "$LOG2" "$ESPF" || rc=$?
[[ "$rc" == 2 && ! -s "$ESPF" ]] && ok "T5 empty source safe (no-new, empty spool)" || no "T5 empty source rc=$rc"

# T6: bounded — a large source does NOT materialize a large bash variable in gather_one.
# (gather_one has no `$(...)` capture; read_incremental caps output at MAX_BYTES via head -c.)
LOG3="$WORK/big.log"
yes 'BIGLINE bigbigbig' 2>/dev/null | head -n 200000 > "$LOG3" || true   # head closes → yes SIGPIPE; pipefail-safe
BSPF="$WORK/bspool"; : > "$BSPF"
rc=0; gather_one "$LOG3" "$BSPF" || rc=$?
appended=$(stat -c %s "$BSPF")
[[ "$rc" == 0 && "$appended" -le $((NFTBAN_HTTP_LOG_MAX_BYTES + 16)) ]] && ok "T6 large source bounded to MAX_BYTES ($appended B), streamed not slurped" || no "T6 large source append=$appended"

# T7 (R22A): the collector applies the SHARED class filter (not the old bare case)
# so cPanel ftpxferlog/.offset/.bytes/mail/state files are never spooled.
grep -qE '_nftban_http_is_nonaccess_name "\$f" && continue' "$COLLECTOR" \
  && ok "T7 collector uses shared _nftban_http_is_nonaccess_name class filter (R22A)" || no "T7 collector missing shared class filter"
if grep -qE 'case "\$f" in \*error_log.*\*\.\[0-9\]\) continue' "$COLLECTOR"; then
  no "T7 collector still uses the old insufficient bare-case exclusion"
else ok "T7 old insufficient bare-case exclusion removed from collector"; fi
# T8 (R22A): the collector content-gates a non-empty non-HTTP file before spooling.
grep -qE '_nftban_http_looks_like_access_log "\$canon"' "$COLLECTOR" \
  && ok "T8 collector content-validates (skips non-empty non-HTTP before spool)" || no "T8 collector missing content gate"

echo "=== gather-stream: $PASS passed, $FAIL failed ==="
[[ "$FAIL" == 0 ]]
