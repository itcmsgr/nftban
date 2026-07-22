#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.199 - Lifecycle forensics: per-run record + JSONL + snapshot
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="lifecycle_forensics_v1199_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-23"
# meta:description="Hermetic regression for v1.199 lifecycle forensics (BUG-INSTALLER-PER-RUN-FORENSIC-LOG-MISSING + BUG-INSTALLER-LOG-FORMAT-MIXED-JSON). Stubs systemctl/stat/lsattr; asserts run_id is deterministic (NFTBAN_RUN_ID pin), the per-run update-runs/<id>/ dir + run.jsonl/human.log are created, every JSONL line parses and carries run_id, the snapshot emits ONLY allowlisted lifecycle fields (binary mode/mtime/xattr, timer due-time/active, failed-unit detail, install_state) with NO env/secret leakage, secret-bearing values are redacted, and retention keeps newest N + prunes the rest."
# meta:input="None (systemctl/stat/lsattr + temp log/data dirs stubbed)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,python3,find,sort"
# meta:inventory.files="cli/lib/nftban/cli/cmd_update_helpers.sh"
# meta:inventory.binaries="bash,python3"
# meta:inventory.env_vars="NFTBAN_RUN_ID,NFTBAN_LOG_DIR,NFTBAN_DATA_DIR,NFTBAN_FORENSIC_RETAIN,NFTBAN_SBIN,NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units="nftban-watchdog.timer,nftban-maintenance.timer"
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="lifecycle_forensics_v1199_test"
# meta:ta.owner="update"
# meta:ta.module="lifecycle-forensics"
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
HELPERS="$REPO_ROOT/cli/lib/nftban/cli/cmd_update_helpers.sh"
# v1.199 GATE-A harness fix: point _fx_redact at the real redaction authority in the
# repo tree. Production resolves it under /usr/lib/nftban, which is absent in the test
# sandbox → _fx_redact fails CLOSED to a marker and corrupts the allowlisted snapshot
# field assertions (bin_mode / watchdog_timer / install_state / failed-unit). This is
# a test-PATH correction only; section G below proves redaction still fails closed when
# the authority is genuinely unavailable, so no assertion is weakened.
export NFTBAN_LIB_DIR="$REPO_ROOT/cli/lib/nftban"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1${2:+ — $2}"; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

export NFTBAN_LOG_DIR="$WORK/log"; export NFTBAN_DATA_DIR="$WORK/data"
mkdir -p "$NFTBAN_DATA_DIR/state" "$WORK/bin"
printf 'INSTALL_STATE=COMMITTED\n' > "$NFTBAN_DATA_DIR/state/install_state"
# a stub "binary" to stat/lsattr
export NFTBAN_SBIN="$WORK/bin/nftban"; printf '#!/bin/sh\n' > "$NFTBAN_SBIN"; chmod 0750 "$NFTBAN_SBIN"

# stub systemctl + lsattr (PATH shim) so the snapshot is deterministic + offline
cat > "$WORK/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  is-active) case "$*" in *watchdog*) echo active;; *maintenance*) echo active;; *) echo inactive;; esac ;;
  show) for a in "$@"; do case "$a" in NextElapseUSecRealtime) echo "Sat 2026-06-23 12:00:00";; Result) echo exit-code;; ExecMainStatus) echo 203;; ExecMainExitTimestamp) echo "Mon 2026-06-22 20:23:24 UTC";; InactiveEnterTimestamp) echo "Mon 2026-06-22 20:23:24 UTC";; esac; done ;;
  --failed) echo "● nftban-watchdog.service loaded failed failed NFTBan Watchdog" ;;
esac
STUB
cat > "$WORK/bin/lsattr" <<'STUB'
#!/usr/bin/env bash
echo "--------------e------- $2"
STUB
chmod +x "$WORK/bin/systemctl" "$WORK/bin/lsattr"
export PATH="$WORK/bin:$PATH"

# shellcheck source=/dev/null
source "$HELPERS"; set +e
_update_log(){ :; }

jq_lines_valid(){ python3 - "$1" <<'PY'
import sys,json
ok=True
for i,l in enumerate(open(sys.argv[1]),1):
    l=l.strip()
    if not l: continue
    try: json.loads(l)
    except Exception as e: print(f"line {i}: {e}"); ok=False
sys.exit(0 if ok else 1)
PY
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

echo "== A: run_id deterministic via NFTBAN_RUN_ID =="
export NFTBAN_RUN_ID="20260623T120000Z-testpin"
[ "$(_forensic_run_id)" = "20260623T120000Z-testpin" ] && ok "A run_id honors NFTBAN_RUN_ID pin" || no "A run_id not pinned" "$(_forensic_run_id)"
unset NFTBAN_RUN_ID; A1=$(_forensic_run_id)
case "$A1" in *-*[0-9]) ok "A auto run_id has ts-pid shape ($A1)";; *) no "A auto run_id shape" "$A1";; esac
export NFTBAN_RUN_ID="20260623T120000Z-testpin"

echo "== B: begin creates per-run dir + JSONL/human; run_start logged =="
RID=$(_forensic_run_id)
_forensic_begin "$RID" update 1.198.2 1.198.3
D="$NFTBAN_LOG_DIR/update-runs/$RID"
[ -d "$D" ] && ok "B per-run dir created ($D)" || no "B dir missing"
[ -f "$D/run.jsonl" ] && [ -f "$D/human.log" ] && ok "B run.jsonl + human.log created" || no "B files missing"
grep -q '"event":"run_start"' "$D/run.jsonl" && ok "B run_start event present" || no "B no run_start"

echo "== C: snapshot emits allowlisted fields; JSONL parses; carries run_id =="
_forensic_snapshot "$RID" pre-swap
_forensic_event "$RID" inhibit "timers=nftban-watchdog.timer nftban-maintenance.timer"
_forensic_snapshot "$RID" post-swap
_forensic_end "$RID" COMMITTED 0
jq_lines_valid "$D/run.jsonl" && ok "C every JSONL line parses as JSON" || no "C invalid JSONL"
miss=0; while IFS= read -r l; do [ -z "$l" ] && continue; echo "$l"|grep -q '"run_id":' || miss=1; done < "$D/run.jsonl"
[ "$miss" = 0 ] && ok "C every event carries run_id" || no "C an event lacks run_id"
[ "$(ev_field "$D/run.jsonl" snapshot bin_mode)" = "750" ] && ok "C snapshot bin_mode captured (750)" || no "C bin_mode" "$(ev_field "$D/run.jsonl" snapshot bin_mode)"
echo "$(ev_field "$D/run.jsonl" snapshot bin_xattr)" | grep -q 'e' && ok "C snapshot bin_xattr captured" || no "C bin_xattr missing"
[ "$(ev_field "$D/run.jsonl" snapshot watchdog_timer)" = "active" ] && ok "C snapshot watchdog_timer active" || no "C watchdog_timer"
[ -n "$(ev_field "$D/run.jsonl" snapshot watchdog_next)" ] && ok "C snapshot watchdog due-time captured" || no "C watchdog_next missing"
[ "$(ev_field "$D/run.jsonl" snapshot install_state)" = "COMMITTED" ] && ok "C snapshot install_state captured" || no "C install_state"
grep -q '"event":"failed_unit"' "$D/run.jsonl" && [ "$(ev_field "$D/run.jsonl" failed_unit exec_status)" = "203" ] && ok "C failed-unit detail (EXEC 203) captured" || no "C failed_unit detail"

echo "== D: allowlist — NO env/secret leakage in the record =="
export SECRET_TOKEN="hunter2supersecret"; export AWS_SECRET_ACCESS_KEY="leakme123"
RID2="20260623T120001Z-secrettest"; _forensic_begin "$RID2" update 1 2
_forensic_event "$RID2" note "password=hunter2 token=abc123 detail=ok"
_forensic_snapshot "$RID2" pre-swap; _forensic_end "$RID2" COMMITTED 0
D2="$NFTBAN_LOG_DIR/update-runs/$RID2"
grep -qi 'hunter2supersecret\|leakme123\|AWS_SECRET\|SECRET_TOKEN' "$D2/run.jsonl" && no "D env secret leaked into record" || ok "D no env secret in record (allowlist only)"
grep -qi 'hunter2\b\|abc123' "$D2/run.jsonl" && no "D inline secret not redacted" "$(grep -i hunter2 "$D2/run.jsonl"|head -1)" || ok "D inline secret values redacted"
grep -q '<redacted>' "$D2/run.jsonl" && ok "D redaction marker present" || no "D no redaction applied"

echo "== E: retention keeps newest N, prunes the rest =="
export NFTBAN_FORENSIC_RETAIN=3
RDIR="$NFTBAN_LOG_DIR/update-runs"; rm -rf "$RDIR"; mkdir -p "$RDIR"
for i in 1 2 3 4 5 6; do mkdir -p "$RDIR/run-$i"; touch -d "2026-06-0${i} 00:00:00" "$RDIR/run-$i" 2>/dev/null || touch "$RDIR/run-$i"; sleep 0.02; done
_forensic_prune
cnt=$(find "$RDIR" -mindepth 1 -maxdepth 1 -type d | wc -l)
[ "$cnt" -le 3 ] && ok "E retention pruned to N=3 (now $cnt)" || no "E not pruned" "count=$cnt"
[ -d "$RDIR/run-6" ] && [ ! -d "$RDIR/run-1" ] && ok "E newest kept (run-6), oldest pruned (run-1)" || no "E wrong dirs kept"

echo "== F: run_id correlation wiring in cmd_update.sh (installer.log + update.log) =="
CMDUPD="$REPO_ROOT/cli/lib/nftban/cli/cmd_update.sh"
grep -qE 'export NFTBAN_RUN_ID="\$_RUN_ID"' "$CMDUPD" && ok "F exports NFTBAN_RUN_ID (Go installer inherits → installer.log correlates)" || no "F NFTBAN_RUN_ID not exported (installer.log would not correlate)"
grep -qE '_update_log INFO "lifecycle run_id=\$_RUN_ID' "$CMDUPD" && ok "F stamps run_id into update.log (correlation delimiter)" || no "F update.log run_id stamp missing"
# export must precede the install case (so the %post installer inherits it)
awk '/export NFTBAN_RUN_ID/{e=NR} /^    case "\$source" in/{c=NR} END{exit !(e>0 && c>e)}' "$CMDUPD" && ok "F export precedes the install case" || no "F export after install case"

echo "== G: redaction fails CLOSED when the authority is unavailable (assertion-strength guard) =="
# Proves the NFTBAN_LIB_DIR harness fix did NOT weaken redaction: with the stream fn
# undefined AND the lib path unreachable, _fx_redact must SUPPRESS content and emit the
# fail-closed marker (never weak-redact, never raw passthrough).
g_out=$( unset -f nftban_redact_stream 2>/dev/null; NFTBAN_LIB_DIR="$WORK/no-such-lib"; printf 'topsecretvalue' | _fx_redact )
echo "$g_out" | grep -q 'REDACTION-UNAVAILABLE' && ok "G fail-closed marker emitted when redaction unavailable" || no "G no fail-closed marker" "$g_out"
echo "$g_out" | grep -q 'topsecretvalue' && no "G raw content leaked under unavailable redaction" || ok "G raw content suppressed (no passthrough)"

echo ""
echo "=== RESULT: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
