#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.170 BUG-STATS-IP-HISTORY: `stats ip` pipefail fix + compressed logs
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="stats_ip_history_v170_test"
# meta:type="test"
# meta:version="1.1.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-10"
# meta:description="Locks the v1.170 fix for nftban_stats_ip_history() (core/nftban_stats_collect.sh). (1) SINGLE-EMIT: a zero-match IP under set -Eeuo pipefail must return exactly one JSON [] (the pre-v1.170 grep|awk||echo[] double-emitted '[]\\n[]' → caller jq length '0\\n0' → cmd_stats.sh:924 [[ -eq ]] arith crash). (2) COMPRESSED-LOG COVERAGE: history reads the live bans.log AND rotated/compressed archives (bans.log.1, bans.log.*.gz) via zgrep, so an IP found only in a .gz appears. (3) SORT: multi-source events sorted by timestamp. (4) CALLER GUARD: cmd_stats.sh sanitizes the jq total to one integer. (5) PACKAGING LOCK: gzip stays a declared dep (DEB Depends + RPM Requires) so zgrep/zcat are guaranteed. (6) v1.230.0 P1-1 BAN-LOG READER BLINDNESS: a NUL run left by an unclean shutdown makes GNU grep classify the log binary and STOP EMITTING MATCHES ON STDOUT while still exiting 0 (count correct, listing silently short). Sections (7)-(10) lock the SEMANTIC INVARIANT records-by-COUNT == records-by-PER-IP-LISTING over a mixed set (bans.log with a real 182-byte NUL run + plain bans.log.1 + real gzip bans.log.2.gz), with the COUNT side computed by awk only (awk is NUL-safe and is not the subject); a DECLARED INVERSION reconstructing the shipped pre-fix reader that must LOSE records; and a per-INVOCATION structural guard (not per-line) asserting every ban-log grep is -a/-c/-q, with its own positive and negative controls. Hermetic: sources the real core funcs against a temp ban log via STATS_BAN_LOG; no host/root/nft."
# meta:input="None (temp ban log + temp .gz archive)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,gzip(zgrep),jq,awk,grep,sort,tr,head"
# meta:inventory.files="cli/lib/nftban/core/nftban_stats_collect.sh,cli/lib/nftban/cli/cmd_stats.sh,cli/lib/nftban/lib/nftban_report_data.sh,cli/lib/nftban/core/nftban_portscan.sh,packaging/deb/control,packaging/build_nftban.sh"
# meta:inventory.binaries="bash,zgrep,gzip,jq,awk,tr,head"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,STATS_BAN_LOG"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="stats_ip_history_v170_test"
# meta:ta.owner="metrics"
# meta:ta.module="stats"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="policy-gates"
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
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
CORE="$REPO_ROOT/cli/lib/nftban/core"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

command -v jq >/dev/null 2>&1 || { echo "jq required for this test"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
LOG="$WORK/bans.log"
# live log: 2.2.2.2 (newer) ; rotated .gz: 3.3.3.3 + 4.4.4.4 (older)
printf '2026-06-08T14:22:00|jailssh|sshd|2.2.2.2|bruteforce|ban\n'  > "$LOG"
printf '2026-06-09T10:00:00|jailssh|sshd|4.4.4.4|bruteforce|ban\n' >> "$LOG"
printf '2026-06-01T09:00:00|jailssh|sshd|3.3.3.3|bruteforce|ban\n'  > "$WORK/old.txt"
printf '2026-05-15T08:00:00|jailssh|sshd|4.4.4.4|bruteforce|ban\n' >> "$WORK/old.txt"
gzip -c "$WORK/old.txt" > "$LOG.1.gz"

# Call the REAL function (source nftban_stats.sh first — it sets NFTBAN_BAN_LOG
# from STATS_BAN_LOG — then nftban_stats_collect.sh), under the same strict mode.
hist(){ NFTBAN_LIB_DIR="$REPO_ROOT/cli/lib/nftban" STATS_BAN_LOG="$LOG" bash -c '
  source "'"$CORE"'/nftban_stats.sh" >/dev/null 2>&1 || true
  source "'"$CORE"'/nftban_stats_collect.sh" >/dev/null 2>&1 || { echo "SRCFAIL"; exit 99; }
  nftban_stats_ip_history "$1"' _ "$1"; }

echo "=== (1) zero-match IP under pipefail → exactly one [] (no double-emit) ==="
out=$(hist 9.9.9.9)
if [[ "$out" == "[]" ]] && [[ "$(printf '%s' "$out" | wc -l)" -eq 0 ]] && [[ "$(printf '%s' "$out" | jq '. | length')" == "0" ]]; then
  ok "zero-match → single '[]', jq length 0 (no '[]\\n[]', no arith crash)"
else
  no "zero-match double-emit / garbled" "out=[$out]"
fi

echo "=== (2) live-log IP present ==="
out=$(hist 2.2.2.2)
if [[ "$(echo "$out" | jq '. | length')" == "1" && "$(echo "$out" | jq -r '.[0].timestamp')" == "2026-06-08T14:22:00" ]]; then
  ok "live-log IP 2.2.2.2 → 1 event"
else no "live-log IP wrong" "out=[$out]"; fi

echo "=== (3) compressed-only IP (.gz) appears → rotated-archive coverage ==="
out=$(hist 3.3.3.3)
if [[ "$(echo "$out" | jq '. | length')" == "1" && "$(echo "$out" | jq -r '.[0].action')" == "ban" ]]; then
  ok "compressed-only IP 3.3.3.3 read from bans.log.1.gz"
else no "compressed-log coverage failed" "out=[$out]"; fi

echo "=== (4) IP in BOTH live + .gz → merged, sorted by timestamp ==="
out=$(hist 4.4.4.4)
n=$(echo "$out" | jq '. | length'); first=$(echo "$out" | jq -r '.[0].timestamp'); last=$(echo "$out" | jq -r '.[-1].timestamp')
if [[ "$n" == "2" && "$first" == "2026-05-15T08:00:00" && "$last" == "2026-06-09T10:00:00" ]]; then
  ok "4.4.4.4 → 2 events merged (live+gz), ascending by timestamp"
else no "merge/sort wrong" "n=$n first=$first last=$last"; fi

echo "=== (5) caller cmd_stats.sh sanitizes jq total to one integer ==="
if grep -qE 'jq .\. \| length. 2>/dev/null \| head -1' "$REPO_ROOT/cli/lib/nftban/cli/cmd_stats.sh" \
   && grep -qE 'total=\$\{total//\[\^0-9\]/\}' "$REPO_ROOT/cli/lib/nftban/cli/cmd_stats.sh"; then
  ok "cmd_stats.sh total sanitized (head -1 + strip non-digits)"
else no "cmd_stats.sh total not sanitized"; fi

echo "=== (6) packaging lock: gzip declared (DEB Depends + RPM Requires) ==="
if grep -qE '^[[:space:]]*gzip,' "$REPO_ROOT/packaging/deb/control"; then ok "DEB control Depends: gzip"; else no "DEB control missing gzip"; fi
if grep -qE '^Requires:[[:space:]]+gzip' "$REPO_ROOT/packaging/build_nftban.sh"; then ok "RPM spec Requires: gzip"; else no "RPM spec missing Requires: gzip"; fi

# =============================================================================
# v1.230.0 P1-1 — BAN-LOG READER BLINDNESS (NUL bytes silently truncate stdout)
# =============================================================================
# The v1.170 header above CLAIMS per-IP history is "COMPLETE, not silently
# truncated". It was not. An unclean shutdown leaves a run of NUL bytes in the
# ban log (measured on a production host: 182 contiguous NULs in a rotated
# bans.log.1 that `file` still reports as "ASCII text"). GNU grep classifies
# such input as binary and STOPS WRITING MATCHES TO STDOUT while still exiting
# 0 — so `grep -c` stays CORRECT and the per-IP LISTING silently loses records
# (measured: 3055 with `grep -ah` vs 87 with `zgrep -h`, 97.2% lost). The
# "binary file matches" stderr notice is NOT a usable detector: it is emitted
# only for some stdout shapes and every reader here writes 2>/dev/null.
#
# THE INVARIANT UNDER TEST IS SEMANTIC, not textual:
#     records represented by COUNT  ==  records represented by the PER-IP LISTING
# across the supported mix of CURRENT and ROTATED/COMPRESSED members
# (bans.log, bans.log.1, bans.log.*.gz). A count and a listing that can
# disagree IS the defect; their agreement is the invariant.
#
# The COUNT side is computed with awk only (awk is NUL-safe and is NOT the
# subject under test), so the two sides are independent by construction.
# =============================================================================
SKIP=0
skip(){ SKIP=$((SKIP+1)); echo "  ⊘ SKIP (NOT A PASS) $1${2:+ — $2}"; }

W2="$WORK/nul"; mkdir -p "$W2"
NLOG="$W2/bans.log"
NUL_IP="203.0.113.77"        # target IP, present in all three members
OTHER_IP="198.51.100.5"      # noise

gen_recs(){ # $1=start $2=count $3=ip
    awk -v s="$1" -v n="$2" -v ip="$3" 'BEGIN{
        for(i=s;i<s+n;i++)
            printf "2026-09-%02dT%02d:%02d:00|jailssh|sshd|%s|bruteforce|BANNED\n",(i%28)+1,i%24,i%60,ip
    }'
}

# CURRENT member: >32KiB of good records, then a NUL run ON ITS OWN LINE, then
# more good records. The NUL run is isolated so that NO ban record is itself
# corrupted — the ONLY variable is whether the reader still emits. Records must
# precede the NUL run by more than one grep read-buffer so the fixture shows
# PARTIAL loss (the production shape), not merely an empty result.
{
    gen_recs 0    1200 "$NUL_IP"
    gen_recs 0      50 "$OTHER_IP"
} > "$NLOG"
head -c 182 /dev/zero >> "$NLOG"
printf '\n' >> "$NLOG"
gen_recs 1200 300 "$NUL_IP" >> "$NLOG"

# ROTATED plain member (bans.log.1) and ROTATED compressed member (bans.log.2.gz).
gen_recs 1500 100 "$NUL_IP" > "$NLOG.1"
gen_recs 1600  50 "$NUL_IP" | gzip -c > "$NLOG.2.gz"

# --- COUNT side: awk only, never grep. Independent of the subject. -----------
true_count(){ # $1=ip → total records across the whole log set
    local _t=0 _f _n
    for _f in "$NLOG" "$NLOG".*; do
        [[ -e "$_f" ]] || continue
        if [[ "$_f" == *.gz ]]; then
            _n=$(gzip -dc "$_f" | awk -v ip="|$1|" 'index($0,ip){c++} END{print c+0}')
        else
            _n=$(awk -v ip="|$1|" 'index($0,ip){c++} END{print c+0}' "$_f")
        fi
        _t=$((_t + _n))
    done
    printf '%s' "$_t"
}

nhist(){ NFTBAN_LIB_DIR="$REPO_ROOT/cli/lib/nftban" STATS_BAN_LOG="$NLOG" bash -c '
  source "'"$CORE"'/nftban_stats.sh" >/dev/null 2>&1 || true
  source "'"$CORE"'/nftban_stats_collect.sh" >/dev/null 2>&1 || { echo "SRCFAIL"; exit 99; }
  nftban_stats_ip_history "$1"' _ "$1"; }

echo "=== (7) PRECONDITIONS — asserted BEFORE any capability claim ==="
# (7a) the plain member really carries a contiguous NUL run
nul_bytes=$(tr -dc '\0' < "$NLOG" | wc -c)
if [[ "$nul_bytes" -eq 182 ]]; then ok "fixture carries a 182-byte NUL run in the CURRENT plain member"
else no "fixture NUL run absent/short — the rest of this block would be vacuous" "nul_bytes=$nul_bytes"; fi
# (7b) the .gz member is REAL gzip (legitimately binary — the reader must still read it)
if gzip -t "$NLOG.2.gz" 2>/dev/null; then ok "rotated .gz member is real gzip (gzip -t)"
else no ".gz member is not valid gzip"; fi
# (7c) the count side is non-trivial and covers all three members
TRUE_N=$(true_count "$NUL_IP")
if [[ "$TRUE_N" -eq 1650 ]]; then ok "awk COUNT side = 1650 records across bans.log + .1 + .2.gz"
else no "awk COUNT side unexpected — fixture generation drifted" "TRUE_N=$TRUE_N"; fi

echo "=== (8) POSITIVE PROPERTY — COUNT == PER-IP LISTING over plain+NUL+gz ==="
out=$(nhist "$NUL_IP")
LIST_N=$(printf '%s' "$out" | jq '. | length' 2>/dev/null || echo -1)
if [[ "$LIST_N" == "$TRUE_N" ]]; then
  ok "listing == count ($LIST_N == $TRUE_N) — no records lost to the NUL run or to gzip"
else
  no "COUNT/LISTING DISAGREE — reader is blind or over-reads" "listing=$LIST_N count=$TRUE_N"
fi
# the listing must also be well-formed JSON and carry only the target IP
if [[ "$LIST_N" != "-1" ]] && [[ "$(printf '%s' "$out" | jq -r '[.[].ip] | unique | join(",")')" == "$NUL_IP" ]]; then
  ok "listing is valid JSON and contains ONLY $NUL_IP (no NUL-run garbage records)"
else
  no "listing malformed or contaminated"
fi
# a NUL run must not make an absent IP appear, nor break the single-emit contract
out0=$(nhist 192.0.2.222)
if [[ "$out0" == "[]" ]]; then ok "zero-match IP over a NUL-bearing log set → single '[]'"
else no "zero-match contract broken on NUL-bearing log set" "out=[$out0]"; fi

echo "=== (9) DECLARED INVERSION — prove this test DETECTS the loss class ==="
# Reconstruct the SHIPPED pre-fix reader verbatim (zgrep -h, no -a) over the SAME
# fixture. --binary-files=binary makes the inversion DECLARED rather than inferred
# from the platform default. If this does not lose records, sections (7)-(8) prove
# nothing and must not be reported as a pass.
old_reader_n=$(zgrep -h "|${NUL_IP}|" "$NLOG" "$NLOG".* 2>/dev/null | sed '/^$/d' | wc -l)
plat_n=$(grep --binary-files=binary -c "" "$NLOG" >/dev/null 2>&1; \
         grep --binary-files=binary -h "|${NUL_IP}|" "$NLOG" 2>/dev/null | wc -l)
plat_true=$(awk -v ip="|$NUL_IP|" 'index($0,ip){c++} END{print c+0}' "$NLOG")
if [[ "$plat_n" -ge "$plat_true" ]]; then
    skip "platform grep does not truncate on NUL (--binary-files=binary emitted $plat_n/$plat_true)" \
         "the defect class cannot be expressed here; negative control is VACUOUS, not green"
elif [[ "$old_reader_n" -lt "$TRUE_N" ]]; then
    ok "inversion LOSES records: pre-fix reader $old_reader_n vs true $TRUE_N ($(( (TRUE_N-old_reader_n)*100/TRUE_N ))% lost) — the property test can detect the defect"
else
    no "INVERSION DID NOT FAIL — the property test cannot detect the loss class" \
       "old=$old_reader_n true=$TRUE_N"
fi
# and the counter really does stay correct while the listing is wrong (the trap)
plat_c=$(grep -c "|${NUL_IP}|" "$NLOG" 2>/dev/null || true)
if [[ "$plat_c" -eq "$plat_true" ]]; then
  ok "grep -c stays CORRECT ($plat_c) on the same NUL-bearing file — count/listing divergence confirmed as the defect shape"
else no "grep -c disagreed with awk on the plain member" "grep -c=$plat_c awk=$plat_true"; fi

echo "=== (10) STRUCTURAL GUARD — no ban-log grep may emit to stdout without -a ==="
# Located by PATTERN, never by line number. The guard subject is the grep
# INVOCATION, not the line: `grep PAT "$ban_log" | grep -cE PAT2` has a -c on the
# line but its FIRST grep is an unguarded stdout emitter. A line-level rule passes
# that shape — it is exactly the portscan blind site — so each grep token is
# evaluated against its OWN flag cluster.
# RULE: on any line naming a ban-log path, EVERY grep/zgrep invocation must carry
# -a (text-forced), -c (counter) or -q (predicate). Catches NEW sites, not just six.
guard_awk='
/^[[:space:]]*#/ { next }
(/\$NFTBAN_BAN_LOG/ || /\$\{_logs\[@\]\}/ || /\$ban_log/) {
    n = split($0, t, /[ \t]+/)
    for (i = 1; i <= n; i++) {
        tok = t[i]
        sub(/^.*\$\(/, "", tok); sub(/^[({|]+/, "", tok)
        if (tok != "grep" && tok != "zgrep" && tok != "egrep" && tok != "zegrep") continue
        safe = 0
        for (j = i+1; j <= n; j++) {
            if (substr(t[j],1,1) != "-") break
            if (t[j] ~ /^-[A-Za-z]+$/ && t[j] ~ /[acq]/) safe = 1
        }
        if (!safe) { print NR": "$0; next }
    }
}'
guard_bad=0
for gf in "$REPO_ROOT/cli/lib/nftban/core/nftban_stats_collect.sh" \
          "$REPO_ROOT/cli/lib/nftban/lib/nftban_report_data.sh" \
          "$REPO_ROOT/cli/lib/nftban/core/nftban_portscan.sh"; do
    while IFS= read -r bad; do
        [[ -z "$bad" ]] && continue
        echo "      BLIND SITE: ${gf##*/}:$bad"
        guard_bad=$((guard_bad+1))
    done < <(awk "$guard_awk" "$gf")
done
if [[ "$guard_bad" -eq 0 ]]; then ok "all ban-log grep invocations are -a / -c / -q (0 unguarded stdout emitters)"
else no "$guard_bad unguarded ban-log grep invocation(s) would silently truncate on NUL"; fi

# --- guard negative controls: the guard must flag BOTH blind shapes ------------
# (10a) the plain shape, and (10b) the PIPED shape that a line-level rule misses.
printf '%s\n' 'x=$(grep "|1.2.3.4|" "$NFTBAN_BAN_LOG" 2>/dev/null | head -1)' > "$W2/probe_plain.sh"
printf '%s\n' 'n=$(grep "|portscan|" "$ban_log" 2>/dev/null | grep -cE "^2026" || true)' > "$W2/probe_piped.sh"
printf '%s\n' 'n=$(grep -a "|portscan|" "$ban_log" 2>/dev/null | grep -a -cE "^2026" || true)' > "$W2/probe_fixed.sh"
ph=$(awk "$guard_awk" "$W2/probe_plain.sh" | wc -l)
pp=$(awk "$guard_awk" "$W2/probe_piped.sh" | wc -l)
pf=$(awk "$guard_awk" "$W2/probe_fixed.sh" | wc -l)
if [[ "$ph" -eq 1 ]]; then ok "guard control (a): plain blind site IS flagged"
else no "guard blind to the plain shape" "hits=$ph"; fi
if [[ "$pp" -eq 1 ]]; then ok "guard control (b): PIPED blind site (first grep emits, second has -c) IS flagged"
else no "guard blind to the piped shape — a line-level rule; this is the portscan defect" "hits=$pp"; fi
if [[ "$pf" -eq 0 ]]; then ok "guard control (c): the FIXED piped shape is NOT flagged (no false positive)"
else no "guard false-positives on correct code" "hits=$pf"; fi

echo "================================================================"
echo "stats_ip_history_v170_test: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[[ $SKIP -gt 0 ]] && echo "NOTE: $SKIP check(s) SKIPPED — a SKIP is NOT a PASS; see the ⊘ lines above."
echo "================================================================"
[[ $FAIL -eq 0 ]]
