#!/usr/bin/env bash
# =============================================================================
# NFTBan - SELinux: LoginMon follows a PERSISTENT journal (v1.238.2)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="selinux_loginmon_persistent_journal_v1238_2_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-28"
# meta:description="v1.238.2 control for BUG-LOGINMON-BLIND-ON-PERSISTENT-JOURNAL-SELINUX-WATCH-DENIED. The v1.234 journal grants cover the VOLATILE journal (/run/log/journal, syslogd_var_run_t). With a PERSISTENT journal (/var/log/journal and its machine-id directory, var_log_t) the LoginMon follower (journalctl -f inside nftband_t) could read the files but not inotify-watch the directories, so it never woke and delivered no line. MEASURED on Rocky 10.1 Enforcing (2026-11-28): avc denied { watch } comm=journalctl path=/var/log/journal scontext=nftband_t tcontext=var_log_t tclass=dir; 4 fixture SSH failures, 0 LoginMon detections, no ban. This control asserts the refpolicy interface logging_watch_generic_log_dirs(nftband_t) is granted as a POLICY STATEMENT, that the volatile-journal grants stay, and that the grant is not broadened (no watch on log FILES, no all-log-dirs or audit-log watch, no raw var_log_t/logfile allow). Injection controls prove each assertion can fail. Static - reads policy source only, no SELinux operations, no privileges."
# meta:input="install/selinux/nftban.te"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep"
# meta:ta.id="selinux_loginmon_persistent_journal_v1238_2_test"
# meta:ta.owner="security"
# meta:ta.module="selinux-loginmon-journal"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="policy-gates"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -uo pipefail
PASS=0; FAIL=0
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

TE="$(dirname "${BASH_SOURCE[0]}")/../../../../install/selinux/nftban.te"
[[ -r "$TE" ]] || { echo "cannot read $TE"; exit 1; }

# A call counts only as a policy statement at line start (a comment does not satisfy it).
has_call(){ grep -qE "^[[:space:]]*$1\(nftband_t\)[[:space:]]*(#.*)?$" "$2"; }

# ── P1: the persistent-journal directory watch is granted, as the refpolicy interface ──
has_call logging_watch_generic_log_dirs "$TE" \
  && ok "P1 logging_watch_generic_log_dirs(nftband_t) present" \
  || no "P1 logging_watch_generic_log_dirs(nftband_t) MISSING - LoginMon is blind on a persistent journal under Enforcing"

grep -qE 'BUG-LOGINMON-BLIND-ON-PERSISTENT-JOURNAL-SELINUX-WATCH-DENIED' "$TE" \
  && ok "P2 defect handle documented at the grant" || no "P2 handle not documented"

grep -qE 'denied \{ watch \}.*/var/log/journal' "$TE" && grep -qE 'tcontext=var_log_t tclass=dir' "$TE" \
  && ok "P3 measured denial recorded in policy source" || no "P3 measured denial not recorded"

# ── P4: the VOLATILE-journal grants stay (regression guard for /run/log/journal) ──
for c in logging_read_syslog_pid logging_mmap_journal logging_watch_journal_dir logging_read_generic_logs; do
  has_call "$c" "$TE" && ok "P4 $c(nftband_t) still present" \
    || no "P4 $c(nftband_t) MISSING - journal following regresses"
done

# ── P5: not broadened. Scanned over POLICY STATEMENTS ONLY (comments stripped). ──
FORBIDDEN_RE=(
  '^[[:space:]]*logging_watch_all_log_dirs_path\(nftband_t'                 # every logfile dir + / + /var
  '^[[:space:]]*logging_watch_audit_log_(files|dirs)\(nftband_t'            # audit log
  '^[[:space:]]*logging_watch_[a-z_]*log_files\(nftband_t'                  # watch on log FILES
  '^[[:space:]]*allow[[:space:]]+nftband_t[[:space:]]+(var_log_t|logfile):'  # raw allow instead of the interface
  '^[[:space:]]*allow[[:space:]]+nftband_t[[:space:]]+[a-z_]+:file[[:space:]]+[^;]*watch'   # watch on any file
)
p5_scan(){
  local f=$1 hit=0 re stmts
  stmts="$(grep -vE '^[[:space:]]*#' "$f")"
  for re in "${FORBIDDEN_RE[@]}"; do
    grep -qE "$re" <<<"$stmts" && { echo "      forbidden: $re"; hit=1; }
  done
  return $hit
}
p5_scan "$TE" && ok "P5 no broader log-watch grant (all log dirs, audit log, log files, raw var_log_t allow)" \
  || no "P5 broader grant present - the persistent-journal fix must stay var_log_t:dir watch only"

# ── CONTROLS (throwaway copies; the shipped policy is never written) ──
_g="$(mktemp -d)"; trap 'rm -rf "$_g"' EXIT

grep -vE '^[[:space:]]*logging_watch_generic_log_dirs\(nftband_t\)' "$TE" > "$_g/a.te"
echo '# logging_watch_generic_log_dirs(nftband_t)   <- documented, NOT granted' >> "$_g/a.te"
has_call logging_watch_generic_log_dirs "$_g/a.te" \
  && no "C1 commented-out call satisfies P1 (VACUOUS PASS)" \
  || ok "C1 commented-out call correctly does NOT satisfy P1"

grep -vE 'logging_watch_generic_log_dirs' "$TE" > "$_g/b.te"
has_call logging_watch_generic_log_dirs "$_g/b.te" \
  && no "C2 P1 still passes with the call REMOVED - unfalsifiable" \
  || ok "C2 P1 correctly FAILS when the call is removed"

for c in logging_read_syslog_pid logging_mmap_journal logging_watch_journal_dir logging_read_generic_logs; do
  grep -vE "^[[:space:]]*$c\(nftband_t\)" "$TE" > "$_g/c_$c.te"
  has_call "$c" "$_g/c_$c.te" && no "C3 P4 still passes with $c REMOVED" || ok "C3 P4 correctly FAILS when $c is removed"
done

for inj in 'logging_watch_all_log_dirs_path(nftband_t)' 'logging_watch_audit_log_dirs(nftband_t)' \
           'logging_watch_audit_log_files(nftband_t)' 'logging_watch_generic_log_files(nftband_t)' \
           'allow nftband_t var_log_t:dir watch;' 'allow nftband_t logfile:dir { search watch };' \
           'allow nftband_t var_log_t:file { read watch };'; do
  { cat "$TE"; echo "$inj"; } > "$_g/e.te"
  p5_scan "$_g/e.te" >/dev/null && no "C4 P5 blind to injected grant: $inj" || ok "C4 P5 detects injected: $inj"
done

{ cat "$TE"; echo '# refused: logging_watch_all_log_dirs_path(nftband_t), allow nftband_t var_log_t:dir watch;'; } > "$_g/f.te"
p5_scan "$_g/f.te" >/dev/null && ok "C5 a comment naming refused grants does not trip P5" \
  || no "C5 P5 trips on a COMMENT"

echo
echo "=== RESULT: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
