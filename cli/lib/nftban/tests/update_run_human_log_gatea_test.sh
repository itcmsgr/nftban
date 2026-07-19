#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.199 GATE-A — self-contained per-run lifecycle record
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="update_run_human_log_gatea_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-19"
# meta:description="Hermetic regression for GATE-A of LIFECYCLE_LOG_FORENSICS_AND_ROTATION_SAFETY (OPEN_UPDATE_RUN_HUMAN_LOG_EMPTY). Proves the previously-empty per-run human.log is now populated by the canonical _update_log line (A1), that human.log carries ONLY the update-orchestrator narrative (A2), that a per-run installer.log slice is extracted from the aggregate installer.log via run_id-delimited boundary PRIMARY (A3/A4) with line-count-delta FALLBACK (A5), that sequential runs stay isolated (A6), that a failed/partial installer still yields its partial slice (A7), that no-output/absent installer is represented honestly (A8), that truncation/rotation does not copy unrelated history (A9), that per-run files are 0640 (A10), that the support-bundle collects all three files (A11), that a per-run write failure never breaks _update_log (A12), that the aggregate update.log + installer.log are unchanged (A13), and that run.jsonl stays valid JSONL with an installer_slice event (A14)."
# meta:input="None (temp NFTBAN_LOG_DIR; synthetic aggregate installer.log with logger.go RUN headers)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,python3,wc,sed,grep,stat"
# meta:inventory.files="cli/lib/nftban/cli/cmd_update_helpers.sh,cli/lib/nftban/cli/cmd_update.sh,cli/lib/nftban/cli/cmd_support.sh"
# meta:inventory.binaries="bash,python3,wc,sed,grep,stat"
# meta:inventory.env_vars="NFTBAN_RUN_ID,NFTBAN_LOG_DIR,UPDATE_LOG_FILE,FORENSIC_HUMAN,FORENSIC_INSTALLER,FORENSIC_ILOG_FILE,FORENSIC_ILOG_BEFORE"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
HELPERS="$REPO_ROOT/cli/lib/nftban/cli/cmd_update_helpers.sh"
SUPPORT="$REPO_ROOT/cli/lib/nftban/cli/cmd_support.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1${2:+ — $2}"; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

export NFTBAN_LOG_DIR="$WORK/log"; mkdir -p "$NFTBAN_LOG_DIR"
export UPDATE_LOG_FILE="$NFTBAN_LOG_DIR/update.log"
ILOG="$NFTBAN_LOG_DIR/installer.log"   # the aggregate installer.log
# point _fx_redact at the real redaction authority so run.jsonl values pass through
# faithfully (redaction fails CLOSED to a marker when the lib is unreachable).
export NFTBAN_LIB_DIR="$REPO_ROOT/cli/lib/nftban"

# shellcheck source=/dev/null
source "$HELPERS"; set +e

# emit one installer.log RUN block exactly as internal/installer/logging/logger.go
# RunHeader() writes it: blank, 72×'=', [RUN] version, [RUN] host, [RUN] started…run_id, 72×'='
emit_run_block(){ # <ilog> <version> <mode> <run_id> <body-line...>
    local f="$1" ver="$2" mode="$3" rid="$4"; shift 4
    local sep; sep=$(printf '=%.0s' {1..72})
    {
        printf '\n%s\n' "$sep"
        printf '2026-07-19T10:00:00Z [RUN] nftban-installer %s — %s\n' "$ver" "$mode"
        printf '2026-07-19T10:00:00Z [RUN] host=host1 os=linux\n'
        printf '2026-07-19T10:00:00Z [RUN] started=2026-07-19T10:00:00Z pid=1234 run_id=%s\n' "$rid"
        printf '%s\n' "$sep"
        local l; for l in "$@"; do printf '2026-07-19T10:00:01Z [INFO] %s\n' "$l"; done
    } >> "$f"
}
ev_field(){ python3 - "$1" "$2" "$3" <<'PY'
import sys,json
path,ev,field=sys.argv[1],sys.argv[2],sys.argv[3]
for l in open(path):
    l=l.strip()
    if not l: continue
    o=json.loads(l)
    if o.get("event")==ev and field in o: print(o[field]); break
PY
}
jsonl_valid(){ python3 - "$1" <<'PY'
import sys,json
ok=True
for i,l in enumerate(open(sys.argv[1]),1):
    l=l.strip()
    if not l: continue
    try:
        o=json.loads(l)
        if "run_id" not in o: print(f"line {i}: no run_id"); ok=False
    except Exception as e: print(f"line {i}: {e}"); ok=False
sys.exit(0 if ok else 1)
PY
}

# ---------------------------------------------------------------------------
echo "== A1/A2/A13: human.log populated with ONLY orchestrator lines; aggregates intact =="
# pre-existing aggregate installer.log content (a prior run) — boundary baseline
emit_run_block "$ILOG" "v1.221.3" update "PRIOR-RUN-0000" "prior installer phase A" "prior installer phase B"
ILOG_SUM_BEFORE=$(cksum "$ILOG")
export NFTBAN_RUN_ID="20260719T100000Z-r1"
RID=$(_forensic_run_id)
_forensic_begin "$RID" update 1.221.3 1.221.4 >/dev/null 2>&1
D="$NFTBAN_LOG_DIR/update-runs/$RID"
# orchestrator narrative via the REAL _update_log
_update_log INFO "=== Update started v1.221.3 -> v1.221.4 ===" >/dev/null 2>&1
_update_log OK   "pre-swap snapshot captured" >/dev/null 2>&1
# now the installer child appends ITS phases to the aggregate installer.log
emit_run_block "$ILOG" "v1.221.4" update "$RID" "installer phase 1: extract" "installer phase 2: validate"
[ -s "$D/human.log" ] && ok "A1 human.log is non-empty after update" || no "A1 human.log still empty"
grep -q "Update started v1.221.3" "$D/human.log" && ok "A1 human.log carries orchestrator line" || no "A1 orchestrator line missing"
grep -q "installer phase 1: extract" "$D/human.log" && no "A2 installer child line leaked into human.log" || ok "A2 human.log excludes installer-child lines"
grep -q "Update started v1.221.3" "$UPDATE_LOG_FILE" && ok "A13 aggregate update.log received the same line" || no "A13 update.log missing line"
[ "$(cksum "$ILOG")" != "$ILOG_SUM_BEFORE" ] && ok "A13 aggregate installer.log grew from installer child (expected)" || no "A13 installer.log unexpectedly unchanged"

echo "== A3/A4/A14: run_id-delimited slice = THIS run's installer block only =="
_forensic_installer_slice "$RID"
[ -s "$D/installer.log" ] && ok "A3 per-run installer.log populated" || no "A3 installer.log empty"
grep -q "installer phase 1: extract" "$D/installer.log" && ok "A3 slice contains this run's installer lines" || no "A3 this-run lines missing"
grep -q "prior installer phase A" "$D/installer.log" && no "A3 slice leaked PRIOR run content" || ok "A3 slice excludes prior-run content"
grep -q "run_id=$RID" "$D/installer.log" && ok "A4 slice includes this run's RUN header" || no "A4 header missing"
[ "$(ev_field "$D/run.jsonl" installer_slice method)" = "run_id_delimited" ] && ok "A4 method=run_id_delimited recorded" || no "A4 wrong method" "$(ev_field "$D/run.jsonl" installer_slice method)"
jsonl_valid "$D/run.jsonl" && ok "A14 run.jsonl valid JSONL + every event carries run_id" || no "A14 run.jsonl invalid"
grep -q '"event":"installer_slice"' "$D/run.jsonl" && ok "A14 installer_slice event present" || no "A14 no installer_slice event"

echo "== A5: line-count-delta FALLBACK when installer stamps no run_id header =="
export NFTBAN_RUN_ID="20260719T100500Z-r5"; RID5=$(_forensic_run_id)
_forensic_begin "$RID5" update 1 2 >/dev/null 2>&1   # captures FORENSIC_ILOG_BEFORE
D5="$NFTBAN_LOG_DIR/update-runs/$RID5"
# old-style installer: append plain lines, NO run_id RUN header
printf '2026-07-19T10:05:01Z [INFO] legacy installer line X\n2026-07-19T10:05:02Z [INFO] legacy installer line Y\n' >> "$ILOG"
_forensic_installer_slice "$RID5"
[ "$(ev_field "$D5/run.jsonl" installer_slice method)" = "line_count_delta" ] && ok "A5 method=line_count_delta" || no "A5 wrong method" "$(ev_field "$D5/run.jsonl" installer_slice method)"
grep -q "legacy installer line X" "$D5/installer.log" && ok "A5 fallback captured new lines" || no "A5 new lines missing"
grep -q "installer phase 1: extract" "$D5/installer.log" && no "A5 fallback over-captured earlier content" || ok "A5 fallback bounded to new lines only"

echo "== A6: two sequential runs remain isolated =="
[ -f "$D/human.log" ] && [ -f "$D5/human.log" ] && ! diff -q "$D/human.log" "$D5/human.log" >/dev/null && ok "A6 run r1 and r5 human.log differ (isolated)" || no "A6 runs not isolated"
grep -q "Update started v1.221.3" "$D5/human.log" 2>/dev/null && no "A6 r1 orchestrator line bled into r5" || ok "A6 no cross-run orchestrator bleed"

echo "== A7: failed/partial installer still yields its partial slice =="
export NFTBAN_RUN_ID="20260719T100700Z-r7"; RID7=$(_forensic_run_id)
_forensic_begin "$RID7" update 1 2 >/dev/null 2>&1
D7="$NFTBAN_LOG_DIR/update-runs/$RID7"
# installer wrote a header + one line, then failed mid-phase (no footer)
emit_run_block "$ILOG" "v1.221.4" update "$RID7" "installer phase 1: extract (then failed)"
_forensic_installer_slice "$RID7"
[ -s "$D7/installer.log" ] && grep -q "then failed" "$D7/installer.log" && ok "A7 partial slice captured on failure" || no "A7 partial slice missing"

echo "== A8: no-output + absent installer represented honestly =="
export NFTBAN_RUN_ID="20260719T100800Z-r8"; RID8=$(_forensic_run_id)
_forensic_begin "$RID8" update 1 2 >/dev/null 2>&1   # before == current total, nothing appended after
D8="$NFTBAN_LOG_DIR/update-runs/$RID8"
_forensic_installer_slice "$RID8"
[ ! -s "$D8/installer.log" ] && ok "A8 no-output → per-run installer.log empty" || no "A8 unexpected content"
[ "$(ev_field "$D8/run.jsonl" installer_slice reason)" = "no_installer_output" ] && ok "A8 reason=no_installer_output recorded" || no "A8 reason" "$(ev_field "$D8/run.jsonl" installer_slice reason)"
# absent aggregate installer.log entirely (move it aside so FORENSIC_ILOG_FILE points at a missing file)
mv "$ILOG" "$ILOG.bak"
export NFTBAN_RUN_ID="20260719T100801Z-r8b"; RID8B=$(_forensic_run_id)
_forensic_begin "$RID8B" update 1 2 >/dev/null 2>&1   # installer.log absent → before=0
D8B="$NFTBAN_LOG_DIR/update-runs/$RID8B"
_forensic_installer_slice "$RID8B"
[ "$(ev_field "$D8B/run.jsonl" installer_slice reason)" = "installer_log_absent" ] && ok "A8 absent installer.log → reason=installer_log_absent" || no "A8 absent reason" "$(ev_field "$D8B/run.jsonl" installer_slice reason)"
mv "$ILOG.bak" "$ILOG"   # restore aggregate for A9

echo "== A9: truncation/rotation does not copy unrelated history =="
export NFTBAN_RUN_ID="20260719T100900Z-r9"; RID9=$(_forensic_run_id)
_forensic_begin "$RID9" update 1 2 >/dev/null 2>&1   # captures before = current (large) line count
D9="$NFTBAN_LOG_DIR/update-runs/$RID9"
# simulate logrotate replacing the aggregate with a fresh small file (no run_id header)
printf '2026-07-19T10:09:00Z [INFO] freshly rotated installer.log unrelated line\n' > "$ILOG"
_forensic_installer_slice "$RID9"
[ ! -s "$D9/installer.log" ] && ok "A9 rotation → empty slice (no history copied)" || no "A9 copied unrelated history" "$(head -1 "$D9/installer.log")"
[ "$(ev_field "$D9/run.jsonl" installer_slice reason)" = "truncated_or_rotated" ] && ok "A9 reason=truncated_or_rotated recorded" || no "A9 reason" "$(ev_field "$D9/run.jsonl" installer_slice reason)"

echo "== A10: per-run files are mode 0640 =="
m_h=$(stat -c '%a' "$D/human.log" 2>/dev/null); m_i=$(stat -c '%a' "$D/installer.log" 2>/dev/null)
[ "$m_h" = "640" ] && ok "A10 human.log mode 0640" || no "A10 human.log mode" "$m_h"
[ "$m_i" = "640" ] && ok "A10 installer.log mode 0640" || no "A10 installer.log mode" "$m_i"

echo "== A11: support bundle collects all three per-run files (structural guard) =="
grep -Eq 'for f in run\.jsonl human\.log installer\.log' "$SUPPORT" && ok "A11 cmd_support.sh collects run.jsonl + human.log + installer.log" || no "A11 support bundle does not collect installer.log"

echo "== A12: per-run write failure never breaks _update_log =="
SAVE_FH="$FORENSIC_HUMAN"
export FORENSIC_HUMAN="$WORK/nonexistent-dir/human.log"   # parent missing → append fails
_update_log INFO "containment probe line" >/dev/null 2>&1; rc=$?
[ "$rc" = "0" ] && ok "A12 _update_log returns 0 despite per-run append failure" || no "A12 non-zero rc" "$rc"
grep -q "containment probe line" "$UPDATE_LOG_FILE" && ok "A12 aggregate update.log still written under failure" || no "A12 update.log not written"
export FORENSIC_HUMAN="$SAVE_FH"

# ---------------------------------------------------------------------------
echo
echo "======================================================================"
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
