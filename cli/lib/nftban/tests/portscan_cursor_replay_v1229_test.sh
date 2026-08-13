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
echo "══ RESULT: PASS=$PASS FAIL=$FAIL ══"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
