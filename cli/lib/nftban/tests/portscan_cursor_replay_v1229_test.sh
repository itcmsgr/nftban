#!/usr/bin/env bash
# =============================================================================
# NFTBan — PORTSCAN-CURSOR: replay elimination regression (v1.229.x)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="portscan-cursor-replay-v1229-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-14"
# meta:description="Locks the PortScan cursor contract: a second read of the same file window emits nothing (previously 4.6x replay on srv3); appended records emit exactly once; rotation and truncation recover via the canonical incremental reader; the journald cursor is committed ONLY after processing (abort before commit => no advance => replay, never loss); a broken cursor degrades to the bounded legacy read with a WARN, never to silent empty input. Includes a falsifiability control proving the replay detector can see replay when the cursor is disabled."
# meta:inventory.files="cli/lib/nftban/core/nftban_portscan_classic.sh,cli/lib/nftban/lib/nftban_http_logs.sh"
# meta:inventory.privileges="none"
# meta:ta.id="portscan_cursor_replay_v1229_test"
# meta:ta.owner="portscan"
# meta:ta.module="portscan"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"

PASS=0; FAIL=0
ok(){ echo "  ✅ $1"; PASS=$((PASS+1)); }
no(){ echo "  ❌ $1"; [ -n "${2:-}" ] && echo "       $2"; FAIL=$((FAIL+1)); }

SBX=$(mktemp -d); _owner=$$
trap '[ "$$" = "$_owner" ] && rm -rf "$SBX"' EXIT
mkdir -p "$SBX/data" "$SBX/bin" "$SBX/log"

# --- hermetic module load: the helpers + the canonical reader, nothing live ---
export NFTBAN_LIB_DIR="$REPO_ROOT/cli/lib/nftban"
export NFTBAN_DATA_DIR="$SBX/data"
export PORTSCAN_CLASSIC_CURSOR_DIR="$SBX/data/portscan/log-cursors"
export NFTBAN_HTTP_LOG_MAX_BYTES=1048576
_nftban_portscan_classic_log(){ echo "[$1] $2" >> "$SBX/log/module.log"; }
# shellcheck source=/dev/null
source "$REPO_ROOT/cli/lib/nftban/lib/nftban_http_logs.sh"
# extract ONLY the cursor helpers from the module (comments intact — they are
# not the assertion subject here; behaviour is).
eval "$(awk '/^_nftban_portscan_classic_read_file_source\(\)/,/^}/' "$REPO_ROOT/cli/lib/nftban/core/nftban_portscan_classic.sh")"
eval "$(awk '/^_nftban_portscan_classic_journal_fetch\(\)/,/^}/'    "$REPO_ROOT/cli/lib/nftban/core/nftban_portscan_classic.sh")"
eval "$(awk '/^_nftban_portscan_classic_journal_commit\(\)/,/^}/'   "$REPO_ROOT/cli/lib/nftban/core/nftban_portscan_classic.sh")"
eval "$(awk '/^_nftban_portscan_classic_warn_backlog\(\)/,/^}/'    "$REPO_ROOT/cli/lib/nftban/core/nftban_portscan_classic.sh")"
type -t _nftban_portscan_classic_read_file_source >/dev/null || { echo "helpers not extracted"; exit 1; }
export PORTSCAN_CLASSIC_CURSOR_ENABLED=true
export PORTSCAN_CLASSIC_CURSOR_MAX_BYTES=1048576

LOG="$SBX/kern.log"
seq 1 100 | sed 's/^/NFTBAN_PORTSCAN: line /' > "$LOG"

echo "── ARM 1  same input twice: second pass emits NOTHING ─────────────────"
c1=$(_nftban_portscan_classic_read_file_source "$LOG" | wc -l)
c2=$(_nftban_portscan_classic_read_file_source "$LOG" | wc -l)
[ "$c1" -eq 100 ] && ok "first pass emitted all 100 records" || no "first pass emitted $c1/100" ""
[ "$c2" -eq 0 ]   && ok "second pass emitted 0 (replay eliminated; was 4.6x on srv3)" \
                  || no "second pass RE-EMITTED $c2 records" "replay not eliminated"

echo "── FALSIFIABILITY  cursor disabled => replay IS visible ───────────────"
# Without this, arm 1 could pass because the reader emits nothing at all.
cD=$(PORTSCAN_CLASSIC_CURSOR_ENABLED=false _nftban_portscan_classic_read_file_source "$LOG" | wc -l)
[ "$cD" -eq 100 ] && ok "legacy path re-emits all 100 (detector proven sighted)" \
                  || no "legacy path emitted $cD — the no-replay assertion may be vacuous" ""

echo "── ARM 2  appended records emit exactly once ──────────────────────────"
seq 101 120 | sed 's/^/NFTBAN_PORTSCAN: line /' >> "$LOG"
c3=$(_nftban_portscan_classic_read_file_source "$LOG")
n3=$(printf '%s\n' "$c3" | grep -c . || true)
[ "$n3" -eq 20 ] && ok "exactly the 20 new records emitted" || no "emitted $n3, want 20" ""
printf '%s\n' "$c3" | grep -q "line 101" && printf '%s\n' "$c3" | grep -q "line 120" \
    && ok "window is the NEW records (101..120), not a re-read" \
    || no "wrong window content" "$(printf '%s\n' "$c3" | head -2)"

echo "── ARM 3  rotation + truncation recover via the canonical reader ──────"
mv "$LOG" "$LOG.1"; seq 1 5 | sed 's/^/NFTBAN_PORTSCAN: rotated /' > "$LOG"   # new inode
c4=$(_nftban_portscan_classic_read_file_source "$LOG" | wc -l)
[ "$c4" -eq 5 ] && ok "rotation (new inode): read from BOF, 5 records" || no "rotation read $c4/5" ""
seq 1 3 | sed 's/^/NFTBAN_PORTSCAN: shrunk /' > "$LOG"                        # truncation: size < offset
c5=$(_nftban_portscan_classic_read_file_source "$LOG" | wc -l)
[ "$c5" -eq 3 ] && ok "truncation (size < offset): read from BOF, 3 records" || no "truncation read $c5/3" ""

echo "── ARM 4  journald: fetch, COMMIT, second fetch resumes ───────────────"
# journalctl stub: records argv; emits a batch + trailing cursor line.
cat > "$SBX/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "${JSTUB_ARGS:?}"
batch="${JSTUB_BATCH:?}"
cat "$batch" 2>/dev/null
echo "-- cursor: ${JSTUB_CURSOR:?}"
STUB
chmod +x "$SBX/bin/journalctl"
export PATH="$SBX/bin:$PATH" JSTUB_ARGS="$SBX/jargs" JSTUB_BATCH="$SBX/jbatch" JSTUB_CURSOR="CUR_AAA"
seq 1 10 | sed 's/^/NFTBAN_PORTSCAN: j /' > "$JSTUB_BATCH"; : > "$JSTUB_ARGS"

B1="$SBX/b1"
cur=$(_nftban_portscan_classic_journal_fetch "$B1" 60)
[ "$cur" = "CUR_AAA" ] && ok "fetch returned the batch-end cursor" || no "cursor '$cur'" ""
grep -q "after-cursor" "$JSTUB_ARGS" && no "first fetch used --after-cursor with no saved cursor" "" \
                                     || ok "bootstrap fetch used --since (no cursor yet = bootstrap, not failure)"
[ "$(grep -c 'NFTBAN_PORTSCAN' "$B1")" -eq 10 ] && ok "batch buffered for processing (10 records)" || no "batch wrong" ""
_nftban_portscan_classic_journal_commit "$cur"
[ "$(cat "$PORTSCAN_CLASSIC_CURSOR_DIR/journal.cursor" 2>/dev/null)" = "CUR_AAA" ] \
    && ok "cursor COMMITTED after processing" || no "cursor not persisted" ""
: > "$JSTUB_ARGS"; JSTUB_CURSOR="CUR_BBB" _nftban_portscan_classic_journal_fetch "$SBX/b2" 60 >/dev/null
grep -q -- "--after-cursor=CUR_AAA" "$JSTUB_ARGS" \
    && ok "second fetch resumed AFTER the committed cursor (no replay of batch 1)" \
    || no "second fetch did not resume from cursor" "$(cat "$JSTUB_ARGS")"

echo "── ARM 5  abort BEFORE commit => cursor does NOT advance ──────────────"
: > "$JSTUB_ARGS"
JSTUB_CURSOR="CUR_CCC" _nftban_portscan_classic_journal_fetch "$SBX/b3" 60 >/dev/null
# processing "aborts" here — commit is deliberately NOT called.
now=$(cat "$PORTSCAN_CLASSIC_CURSOR_DIR/journal.cursor" 2>/dev/null)
[ "$now" = "CUR_AAA" ] && ok "cursor still CUR_AAA — an aborted batch is REPLAYED next cycle, never lost" \
                       || no "cursor advanced to '$now' without successful processing" "records would be permanently skipped"

echo "── ARM 6  broken cursor degrades LOUDLY to bounded read, never empty ──"
: > "$SBX/log/module.log"
RO="$SBX/ro"; mkdir -p "$RO"; chmod 0555 "$RO"
cF=$(PORTSCAN_CLASSIC_CURSOR_DIR="$RO/sub" _nftban_portscan_classic_read_file_source "$LOG" | wc -l)
[ "$cF" -eq 3 ] && ok "unwritable state dir: bounded legacy read still emitted the data (not empty-success)" \
                || no "fallback emitted $cF/3" ""
grep -q "WARN" "$SBX/log/module.log" && ok "degradation is OBSERVABLE (WARN logged)" \
                                     || no "silent degradation — no WARN" "$(cat "$SBX/log/module.log")"
chmod 0755 "$RO"
# corrupt/empty journal cursor file: WARN + bounded window, not silence
: > "$PORTSCAN_CLASSIC_CURSOR_DIR/journal.cursor"; : > "$SBX/log/module.log"; : > "$JSTUB_ARGS"
JSTUB_CURSOR="CUR_DDD" _nftban_portscan_classic_journal_fetch "$SBX/b4" 60 >/dev/null
grep -q -- "--since" "$JSTUB_ARGS" && ok "empty cursor file: bounded --since window used (data still read)" \
                                   || no "no bounded fallback on corrupt cursor" "$(cat "$JSTUB_ARGS")"
grep -q "WARN" "$SBX/log/module.log" && ok "corrupt cursor is OBSERVABLE (WARN logged)" \
                                     || no "corrupt cursor silent" ""

echo "── ARM 7  the WIRED pipeline, not just the helpers ───────────────────"
# Both bugs found during implementation lived in the pipeline, not the helpers,
# so the helpers alone could be perfect while the module was wrong.
eval "$(awk '/^_nftban_portscan_classic_journal_stream\(\)/,/^}/' "$REPO_ROOT/cli/lib/nftban/core/nftban_portscan_classic.sh")"

# 7a — BUG 2 regression: no batch file must still yield DATA, never empty.
: > "$JSTUB_ARGS"
n7=$(_nftban_portscan_classic_journal_stream "" 60 | grep -c 'NFTBAN_PORTSCAN' || true)
[ "${n7:-0}" -gt 0 ] && ok "no batch file: legacy bounded read still yields records ($n7) — degraded, not blind" \
                     || no "no batch file yielded EMPTY input" "a cursor failure must never look like 'nothing happened'"

# 7b — BUG 1 regression: the tail cap must survive the grep-match path.
# Asserted on the SHIPPED pipeline text: an unbraced `grep ... || true` followed
# by a piped tail parses as `grep || (true | tail)` and drops the cap.
line=$(grep -n 'done < <({ _nftban_portscan_classic_journal_stream' "$REPO_ROOT/cli/lib/nftban/core/nftban_portscan_classic.sh" | cut -d: -f1)
if [ -n "$line" ]; then
    txt=$(sed -n "${line}p" "$REPO_ROOT/cli/lib/nftban/core/nftban_portscan_classic.sh")
    case "$txt" in
        *'{ grep -E'*'|| true; }'*) ok "journald pipeline braces grep — tail cap survives a match" ;;
        *) no "journald grep is unbraced — 'grep || true | tail' drops the cap on the match path" "$txt" ;;
    esac
else
    no "journald pipeline line not found" "wiring changed shape; re-verify the cap"
fi

# 7c — falsifiability for 7b: the broken form must be detected as broken.
bad='done < <({ x; } | grep -E -- "p" || true | { tail -1000 || true; })'
case "$bad" in
    *'{ grep -E'*'|| true; }'*) no "detector blind: the BROKEN form matched the safe pattern" "7b is vacuous" ;;
    *) ok "broken (unbraced) form is correctly rejected — 7b non-vacuous" ;;
esac

echo

# =============================================================================
# LARGE-STATE MATRIX (v1.229.x) — SMALL_FIXTURE_PASS != LARGE-STATE_BOOTSTRAP_PROVEN
#
# Every arm above uses a 100-line file. Three production defects lived precisely
# where a small fixture cannot reach, and all three were found only on srv3's
# 484 MB kern.log:
#   D1 cursor never persisted under `set -Eeuo pipefail` (SIGPIPE from the
#      reader's internal `tail -c | head -c` when the file exceeds the cap)
#   D2 first use treated as ROTATION -> start=0 -> forward mode drained backlog
#   D3 the original replay, left unfixed because D1 made the fix inert
# The arms below reproduce the LARGE-state conditions cheaply by shrinking the
# cap instead of growing the file — identical clamp logic, no multi-MB fixtures.
# =============================================================================
_cursor_path() { printf '%s/%s' "$PORTSCAN_CLASSIC_CURSOR_DIR" "$(printf '%s' "$1" | tr '/' '_')"; }

echo "── ARM 8  FIRST USE on a source LARGER than the cap: tail, not BOF ────"
BIG="$SBX/big.log"
: > "$BIG"
{ echo "NFTBAN_PORTSCAN: OLD_HEAD_MARKER"; seq 1 20000 | sed 's/^/NFTBAN_PORTSCAN: old /'; } > "$BIG"
BIGSZ=$(stat -c %s "$BIG")
rm -f "$(_cursor_path "$BIG")"
PORTSCAN_CLASSIC_CURSOR_MAX_BYTES=65536 _nftban_portscan_classic_read_file_source "$BIG" > "$SBX/out8"
[ "$BIGSZ" -gt 65536 ] && ok "fixture exceeds the cap ($BIGSZ > 65536) — arm is not vacuous" \
                       || no "fixture too small to exercise the clamp" "$BIGSZ"
grep -q "OLD_HEAD_MARKER" "$SBX/out8" \
    && no "FIRST USE drained from BOF — historical backlog emitted" "D2 regression: start=0 on first use" \
    || ok "first use emitted the CURRENT tail, not the head of the backlog"
off8=$(cut -d: -f2 "$(_cursor_path "$BIG")" 2>/dev/null)
[ "${off8:-0}" = "$BIGSZ" ] && ok "cursor seeded at EOF ($off8 == file size)" \
                            || no "cursor not seeded at EOF" "got '${off8:-NONE}', want $BIGSZ"
echo "NFTBAN_PORTSCAN: NEW_AFTER_BOOTSTRAP" >> "$BIG"
n8b=$( PORTSCAN_CLASSIC_CURSOR_MAX_BYTES=65536 _nftban_portscan_classic_read_file_source "$BIG" > "$SBX/out8b"; wc -l < "$SBX/out8b" )
[ "$n8b" -eq 1 ] && grep -q "NEW_AFTER_BOOTSTRAP" "$SBX/out8b" \
    && ok "after bootstrap, exactly the 1 newly appended record is emitted" \
    || no "post-bootstrap read emitted $n8b" "live-tail detection not preserved"

echo "── ARM 8i INVERSION: forward mode MUST drain from BOF (arm 8 falsifiable)"
rm -f "$(_cursor_path "$BIG")"
# `|| true` + subshell: forward mode's internal `tail -c | head -c` SIGPIPEs by
# design on a file larger than the cap, and under `set -o pipefail` that 141 would
# terminate THIS harness before the assertion runs (it did — exit 141). The arm
# asserts on the captured OUTPUT, never on the return code.
( NFTBAN_HTTP_LOG_READ_FORWARD=true PORTSCAN_CLASSIC_CURSOR_MAX_BYTES=65536 \
  _nftban_portscan_classic_read_file_source "$BIG" ) > "$SBX/out8i" 2>/dev/null || true
grep -q "OLD_HEAD_MARKER" "$SBX/out8i" \
    && ok "control: with READ_FORWARD=true the BOF drain IS visible — arm 8 can fail" \
    || no "control BROKEN: forward mode did not drain from BOF" "arm 8 may be vacuous"

echo "── ARM 9  PRODUCTION PIPELINE CONTEXT: set -Eeuo pipefail ────────────"
# The defect that made the whole feature inert was invisible to every direct
# helper call: only errexit+pipefail inside a process substitution loses the
# cursor write. This arm runs the real shell options and the real pipeline shape.
rm -f "$(_cursor_path "$BIG")"
(
  set -Eeuo pipefail
  c=0
  while IFS= read -r _l; do c=$((c+1)); done < <( { PORTSCAN_CLASSIC_CURSOR_MAX_BYTES=65536 _nftban_portscan_classic_read_file_source "$BIG"; } | { tail -5000 || true; } | { grep -E -- "NFTBAN_PORTSCAN:" 2>/dev/null || true; } | { tail -1000 || true; } )
  echo "$c" > "$SBX/n9"
) 2>/dev/null
[ -s "$(_cursor_path "$BIG")" ] \
    && ok "cursor PERSISTED under set -Eeuo pipefail in the wired pipeline (D1 locked out)" \
    || no "cursor LOST under errexit+pipefail — the fix would be INERT in production" "this is the srv3 D1 defect"
n9b=$( set -Eeuo pipefail; { PORTSCAN_CLASSIC_CURSOR_MAX_BYTES=65536 _nftban_portscan_classic_read_file_source "$BIG"; } | grep -cE "NFTBAN_PORTSCAN:" || true )
[ "${n9b:-0}" -eq 0 ] && ok "second pipeline read emits 0 — replay eliminated in the production context" \
                      || no "second pipeline read emitted $n9b" "replay persists under production shell options"

echo "── ARM 9i INVERSION: forward mode loses the cursor under pipefail ─────"
rm -f "$(_cursor_path "$BIG")"
(
  set -Eeuo pipefail
  while IFS= read -r _l; do :; done < <( { NFTBAN_HTTP_LOG_READ_FORWARD=true PORTSCAN_CLASSIC_CURSOR_MAX_BYTES=65536 _nftban_portscan_classic_read_file_source "$BIG"; } | { tail -5000 || true; } | { grep -E -- "NFTBAN_PORTSCAN:" 2>/dev/null || true; } | { tail -1000 || true; } )
) 2>/dev/null
[ -s "$(_cursor_path "$BIG")" ] \
    && no "control BROKEN: forward mode persisted a cursor here" "arm 9 cannot prove D1" \
    || ok "control: forward mode loses the cursor under errexit+pipefail — arm 9 is falsifiable"

echo "── ARM 10 EMPTY source: no cursor damage, no fabricated records ───────"
EMPTY="$SBX/empty.log"; : > "$EMPTY"
rm -f "$(_cursor_path "$EMPTY")"
n10=$(_nftban_portscan_classic_read_file_source "$EMPTY" | wc -l)
[ "$n10" -eq 0 ] && ok "empty source emits 0 records (no fabrication)" || no "empty source emitted $n10" ""
echo "NFTBAN_PORTSCAN: FIRST_EVER" >> "$EMPTY"
n10b=$(_nftban_portscan_classic_read_file_source "$EMPTY" | wc -l)
[ "$n10b" -eq 1 ] && ok "first record on a previously-empty source is detected" \
                  || no "first record after empty emitted $n10b" "startup detection gap"

echo "── ARM 11 backlog beyond the cap WARNs (a skip must never be silent) ──"
: > "$SBX/log/module.log"
printf '%s:%s\n' "$(stat -c %i "$BIG")" "0" > "$(_cursor_path "$BIG")"   # pretend we are far behind
PORTSCAN_CLASSIC_CURSOR_MAX_BYTES=65536 _nftban_portscan_classic_read_file_source "$BIG" >/dev/null
if grep -q "backlog exceeds incremental read cap" "$SBX/log/module.log"; then
    ok "WARN emitted when records are skipped"
    grep -qE "path=.*backlog_bytes=[0-9]+ cap_bytes=[0-9]+" "$SBX/log/module.log" \
        && ok "WARN carries bounded fields (path, backlog_bytes, cap_bytes)" \
        || no "WARN missing structured fields" "$(tail -1 "$SBX/log/module.log")"
else
    no "no WARN when backlog exceeded the cap" "a silent skip is exactly what this forbids"
fi
: > "$SBX/log/module.log"
PORTSCAN_CLASSIC_CURSOR_MAX_BYTES=65536 _nftban_portscan_classic_read_file_source "$BIG" >/dev/null
grep -q "backlog exceeds incremental read cap" "$SBX/log/module.log" \
    && no "WARN repeated when caught up — this would be log spam" "$(tail -1 "$SBX/log/module.log")" \
    || ok "no WARN once caught up (bounded, not per-record)"

echo "── ARM 12 STATIC: PortScan must not re-enable forward mode ────────────"
if grep -nE '^[^#]*NFTBAN_HTTP_LOG_READ_FORWARD' "$REPO_ROOT/cli/lib/nftban/core/nftban_portscan_classic.sh" >/dev/null 2>&1; then
    no "PortScan sets NFTBAN_HTTP_LOG_READ_FORWARD again" "forward mode is for BotScan's owned spool, not an external live log"
else
    ok "PortScan does not enable forward mode"
fi
grep -qE '^[^#]*NFTBAN_HTTP_LOG_READ_FORWARD=true' "$REPO_ROOT/cli/lib/nftban/core/nftban_botscan.sh" \
    && ok "BotScan still owns its forward mode (unchanged by this fix)" \
    || no "BotScan lost READ_FORWARD" "this patch must not change BotScan semantics"


echo "══ RESULT: PASS=$PASS FAIL=$FAIL ══"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
