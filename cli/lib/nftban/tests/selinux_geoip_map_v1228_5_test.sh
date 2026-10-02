#!/usr/bin/env bash
# =============================================================================
# NFTBan - SELinux GeoIP mmap grant (v1.228.5 completion)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="selinux_geoip_map_v1228_5_test"
# meta:type="test"
# meta:version="1.1.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-04"
# meta:description="v1.228.5 completion control for BUG-SELINUX-GEOIP-MMDB-MAP-DENIED. On a stock EL9 host with SELinux Enforcing, nftban-core-geoip.service downloaded the MaxMind database successfully and then failed at the verification step with 'permission denied', leaving a FAILED package-owned unit after an otherwise successful package transaction. Root cause: manage_files_pattern grants open/read/write but NOT map, and map is a DISTINCT SELinux permission; the GeoIP consumer memory-maps the .mmdb during verification. MEASURED denial: avc denied { map } comm=nftban-core path=/var/lib/nftban/geoip/dbip-country-lite.mmdb scontext=nftband_t tcontext=nftban_var_lib_t tclass=file permissive=0. The denial reproduces ONLY in the service domain (nftband_t); an interactive run in unconfined_t succeeds, which is why it stayed invisible until a lab ran EL9 Enforcing. This control asserts the narrow grant is present in the shipped policy source, that it is scoped to file:map on the daemon's own state type, and (v1.234) that the journal/sysctl read grants are present AND LIMITED (a refusal set replaces the old ABSENT assertion, with injection controls proving each class is detected). History: v1.228.5 (3859daab) deliberately asserted the sysctl_net_t grant ABSENT because its consumer and impact were not established (OPEN_NFTBAND_SYSCTL_NET_SEARCH_DENIAL: IMPACT NOT_ESTABLISHED, DO_NOT_GRANT). v1.234 established both on enforcing EL9 and EL10 with a volatile journal: the watchdog conntrack gauges exported 0 against a kernel nf_conntrack_max of 65536, and the LoginMon journalctl follower could not read /run/log/journal (WATCHER_DOWN, zero detections of a fresh SSH attack). The v1.234 grants (four read-only refpolicy interface calls) restored both, and an ablation proved map and dir watch are each required (without watch the child stays alive and reports OK but never delivers a line). Static - reads policy source only, no SELinux operations, no privileges."
# meta:input="install/selinux/nftban.te"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep"
# meta:ta.id="selinux_geoip_map_v1228_5_test"
# meta:ta.owner="security"
# meta:ta.module="selinux-geoip-map"
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

grep -qE '^[[:space:]]*allow[[:space:]]+nftband_t[[:space:]]+nftban_var_lib_t:file[[:space:]]+map;' "$TE" \
  && ok "T1 narrow grant present: allow nftband_t nftban_var_lib_t:file map;" \
  || no "T1 GeoIP map grant MISSING - the EL9 Enforcing defect is not fixed"

grep -qE 'BUG-SELINUX-GEOIP-MMDB-MAP-DENIED' "$TE" \
  && ok "T2 defect handle documented at the grant" || no "T2 rationale not documented"

grep -qE 'avc:? *denied \{ map \}|denied \{ map \}' "$TE" \
  && ok "T3 measured denial recorded in policy source" || no "T3 measured denial not recorded"

# ── T4 (v1.234): journal + conntrack READ grants present, as interface calls ──
# History: v1.228.5 asserted the sysctl_net_t grant ABSENT (impact not established).
# v1.234 measured the impact on enforcing EL9 + EL10 (volatile journal) and loaded the
# candidate: conntrack gauges == kernel, LoginMon journal OK and a fresh attack banned.
# Ablation on EL9: without logging_mmap_journal journalctl exits (WATCHER_DOWN, map AVCs);
# without logging_watch_journal_dir journalctl stays alive and reports OK but delivers
# nothing (0 detections for 12 journal events). Each of the four calls is therefore required.
# Anchored at line start: a commented-out call does not satisfy the assertion (T6d).
REQUIRED_CALLS="kernel_read_net_sysctls logging_read_syslog_pid logging_mmap_journal logging_watch_journal_dir"
has_call(){ grep -qE "^[[:space:]]*$1\(nftband_t\)[[:space:]]*(#.*)?$" "$2"; }
for c in $REQUIRED_CALLS; do
  has_call "$c" "$TE" && ok "T4 $c(nftband_t) present" \
    || no "T4 $c(nftband_t) MISSING - enforcing EL hosts lose conntrack metrics or LoginMon journal detection"
done

# ── T7 (v1.234): the new grants stay LIMITED — excessive permissions are refused ──
# The v1.228.5 T4 ("sysctl_net_t grant ABSENT") is REPLACED, not flipped: its intent —
# no unproven access for nftband_t — is kept here as a refusal set derived from the
# audit2allow output the v1.234 root cause REJECTED (SELINUX_DENIAL_ROOT_CAUSE /
# SELINUX_POLICY_CANDIDATE §7): sysctl/journal WRITE, the kernel_t userdb socket,
# the startup ip/who/w execs (a CODE fix), generic exec, and the host-wide mmap boolean.
# Each pattern is a grant that would widen nftband_t beyond read-only journal/sysctl access.
# Scanned over POLICY STATEMENTS ONLY: comment lines are stripped first (t7_scan), so
# documentation may name a refused permission without tripping the guard (T6f).
FORBIDDEN_RE=(
  '^[[:space:]]*kernel_(rw|write|manage)_[a-z_]*sysctls?\(nftband_t'      # write to /proc/sys
  '^[[:space:]]*kernel_(read|rw)_all_sysctls\(nftband_t'                   # every sysctl type
  '^[[:space:]]*allow[[:space:]]+nftband_t[[:space:]]+sysctl[a-z_]*_t:(file|dir|lnk_file)[[:space:]]+[^;]*(write|append|setattr|create|add_name|remove_name|unlink)'
  '^[[:space:]]*logging_(manage|rw|write|create|delete|admin|append)[a-z_]*\(nftband_t'   # journal/log write
  '^[[:space:]]*allow[[:space:]]+nftband_t[[:space:]]+syslogd_var_run_t:(file|dir)[[:space:]]+[^;]*(write|append|unlink|setattr|create|add_name|remove_name)'
  '^[[:space:]]*allow[[:space:]]+nftband_t[[:space:]]+kernel_t:unix_stream_socket'   # userdb connectto (dontaudit or code fix)
  'ifconfig_exec_t'                                                          # startup ip/who/w execs stay a CODE fix
  '^[[:space:]]*corecmd_exec_all_executables\(nftband_t'                   # generic exec
  '^[[:space:]]*can_exec\(nftband_t,[[:space:]]*(bin_t|exec_type|file_type)'
  'domain_can_mmap_files'                                                    # host-wide boolean
  '^[[:space:]]*allow[[:space:]]+nftband_t[[:space:]]+[a-z_]+:file[[:space:]]+[^;]*execmod'
)
t7_scan(){
  local f=$1 hit=0 re stmts
  stmts="$(grep -vE '^[[:space:]]*#' "$f")"
  for re in "${FORBIDDEN_RE[@]}"; do
    grep -qE "$re" <<<"$stmts" && { echo "      forbidden: $re"; hit=1; }
  done
  return $hit
}
t7_scan "$TE" && ok "T7 no excessive grant (sysctl write, log write, kernel_t socket, ifconfig exec, generic exec, mmap boolean)" \
  || no "T7 excessive grant present - the v1.234 grants must stay read-only and narrow"

# The shell-out exec set is FROZEN here: adding a target is a separate reviewed decision.
exec_set="$(grep -E '^[[:space:]]*can_exec\(nftband_t,' "$TE" | tr -d ' \t' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
exec_expected="can_exec(nftband_t,nftband_exec_t) can_exec(nftband_t,{iptables_exec_trpm_exec_tssh_exec_tjournalctl_exec_tsystemd_systemctl_exec_t})"
[[ "$exec_set" == "$exec_expected" ]] && ok "T8 can_exec target set unchanged" \
  || no "T8 can_exec target set drifted - expected [$exec_expected] got [$exec_set]"

# file:map is an ESTABLISHED idiom here - nftban_conf_t and nftban_nftables_conf_t
# already pair manage_files_pattern with file:map. Assert the EXACT permitted set so
# scope creep is caught, rather than a count that would break on any legitimate grant.
expected="nftban_conf_t nftban_nftables_conf_t nftban_var_lib_t"
actual="$(grep -oE '^[[:space:]]*allow[[:space:]]+nftband_t[[:space:]]+[a-z_]+:file[[:space:]]+map;' "$TE" \
          | grep -oE 'nftband_t[[:space:]]+[a-z_]+:file' | awk '{print $2}' | sed 's/:file//' | sort -u | tr '\n' ' ' | sed 's/ $//')"
[[ "$actual" == "$expected" ]] \
  && ok "T5 file:map granted to exactly the expected types [$actual]" \
  || no "T5 file:map type set drifted - expected [$expected] got [$actual]"

# ── T6 CONTROLS: prove T1 measures a POLICY STATEMENT, not source text ──────
# T1/T4/T5 anchor on '^[[:space:]]*allow', which already excludes comment lines by
# construction. That is an ASSUMPTION until it is tested. A sibling guard on this
# same branch reported PASS off a comment quoting the call it existed to verify, so
# the anchor is proven here rather than trusted. Injection into a THROWAWAY copy —
# the shipped policy is never written to.
_g="$(mktemp -d)"; trap 'rm -rf "$_g"' EXIT

# CONTROL A: grant present only as a COMMENT -> T1 must FAIL (no vacuous pass).
grep -vE '^[[:space:]]*allow[[:space:]]+nftband_t[[:space:]]+nftban_var_lib_t:file[[:space:]]+map;' "$TE" \
  > "$_g/a.te"
echo '# allow nftband_t nftban_var_lib_t:file map;   <- documented, NOT granted' >> "$_g/a.te"
if grep -qE '^[[:space:]]*allow[[:space:]]+nftband_t[[:space:]]+nftban_var_lib_t:file[[:space:]]+map;' "$_g/a.te"; then
  no "T6a commented-out grant satisfies T1 (VACUOUS PASS - the fix could be absent)"
else
  ok "T6a commented-out grant correctly does NOT satisfy T1"
fi

# CONTROL B: grant removed entirely -> T1 must FAIL. Proves T1 can fail at all.
if grep -qE '^[[:space:]]*allow[[:space:]]+nftband_t[[:space:]]+nftban_var_lib_t:file[[:space:]]+map;' \
     <(grep -vE 'nftban_var_lib_t:file[[:space:]]+map;' "$TE"); then
  no "T6b T1 still passes with the grant REMOVED - assertion is unfalsifiable"
else
  ok "T6b T1 correctly FAILS when the grant is removed"
fi

# CONTROL C (v1.234): removing ANY one required call must make T4 fail.
for c in $REQUIRED_CALLS; do
  grep -vE "^[[:space:]]*$c\(nftband_t\)" "$TE" > "$_g/c_$c.te"
  if has_call "$c" "$_g/c_$c.te"; then
    no "T6c T4 still passes with $c REMOVED - assertion is unfalsifiable"
  else
    ok "T6c T4 correctly FAILS when $c is removed"
  fi
done

# CONTROL D: a commented-out call must NOT satisfy T4.
grep -vE '^[[:space:]]*logging_watch_journal_dir\(nftband_t\)' "$TE" > "$_g/d.te"
echo '# logging_watch_journal_dir(nftband_t)   <- documented, NOT granted' >> "$_g/d.te"
if has_call logging_watch_journal_dir "$_g/d.te"; then
  no "T6d commented-out call satisfies T4 (VACUOUS PASS)"
else
  ok "T6d commented-out call correctly does NOT satisfy T4"
fi

# CONTROL E: T7 must DETECT each class of excessive grant when injected (not just pass on absence).
for inj in 'kernel_rw_net_sysctls(nftband_t)' 'logging_manage_generic_logs(nftband_t)' \
           'allow nftband_t kernel_t:unix_stream_socket connectto;' \
           'allow nftband_t ifconfig_exec_t:file { execute execute_no_trans map };' \
           'corecmd_exec_all_executables(nftband_t)' \
           'allow nftband_t syslogd_var_run_t:file { read write };' \
           'allow nftband_t syslogd_var_run_t:dir { add_name write };' \
           'allow nftband_t sysctl_net_t:file { read write };' \
           'allow nftband_t sysctl_net_t:dir { search write };' \
           'kernel_read_all_sysctls(nftband_t)' \
           "tunable_policy(\`domain_can_mmap_files',\`')" \
           'can_exec(nftband_t, bin_t)'; do
  { cat "$TE"; echo "$inj"; } > "$_g/e.te"
  if t7_scan "$_g/e.te" >/dev/null; then
    no "T6e T7 blind to injected excessive grant: $inj"
  else
    ok "T6e T7 detects injected: $inj"
  fi
done

# CONTROL F: a COMMENT naming refused permissions must NOT trip T7 (stmts-only scan).
{ cat "$TE"; echo '# refused: kernel_rw_net_sysctls(nftband_t) ifconfig_exec_t domain_can_mmap_files'; } > "$_g/f.te"
if t7_scan "$_g/f.te" >/dev/null; then
  ok "T6f a comment naming refused grants does not trip T7"
else
  no "T6f T7 trips on a COMMENT - it would block documenting the refusal set"
fi

echo
echo "=== RESULT: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
