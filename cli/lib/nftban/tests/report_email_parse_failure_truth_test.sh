#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# =============================================================================
# meta:name="report_email_parse_failure_truth_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Operator-reported on monitor at v1.231.0: `nftban report email` printed a jq parse error and then [SUCCESS] three times; the unparseable section was delivered EMPTY. Asserts the FIXED CONTRACT: jq exit status is tested, an unparseable document marks its section degraded, the payload is captured for the still-unknown producer fault, the command verdict is PARTIAL (rc=2) naming the section rather than SUCCESS, and exactly one layer addresses the operator. Carries an INVERSION arm proving the old unguarded shape would pass silently."
# meta:ta.id="report_email_parse_failure_truth_test"
# meta:ta.owner="mail"
# meta:ta.module="mail-report-parse-truth"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:inventory.files="cli/lib/nftban/core/nftban_report_email.sh,cli/lib/nftban/cli/cmd_report.sh"
# meta:inventory.binaries="bash,jq"
# meta:inventory.env_vars="NFTBAN_DATA_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
PASS=0; FAIL=0; NOT_EXECUTED=0
ok(){ echo "  [PASS] $1"; PASS=$((PASS+1)); }
no(){ echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
ne(){ echo "  [NOT_EXECUTED] $1"; NOT_EXECUTED=$((NOT_EXECUTED+1)); }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SUBJ="$ROOT/cli/lib/nftban/core/nftban_report_email.sh"
CMD="$ROOT/cli/lib/nftban/cli/cmd_report.sh"

command -v jq >/dev/null 2>&1 || { ne "jq absent — subject cannot execute"; echo "=== PASS=$PASS FAIL=$FAIL NOT_EXECUTED=$NOT_EXECUTED ==="; echo "RESULT: NOT_EXECUTED"; exit 0; }
[[ -f "$SUBJ" && -f "$CMD" ]] || { ne "subject files absent"; echo "=== PASS=$PASS FAIL=$FAIL NOT_EXECUTED=$NOT_EXECUTED ==="; echo "RESULT: NOT_EXECUTED"; exit 0; }

SBOX="$(mktemp -d)"; trap 'rm -rf "$SBOX"' EXIT
export NFTBAN_DATA_DIR="$SBOX"

GOOD='{"ok":true,"data":{"load":{"1m":0.39,"5m":0.65,"cpus":8},"memory":{"used_percent":22},"disk":{"path":"/var/log","used_percent":15}}}'
# The operator's own error class: the key/value separator after "5m" is gone.
BAD='{"ok":true,"data":{"load":{"1m":0.39,"5m" 0.65,"cpus":8},"memory":{"used_percent":22}}}'

# Extract the three helpers from the subject WITHOUT executing the whole module.
# ⛔ Extract the helper block as ONE contiguous region between two stable
# anchors. An earlier version of this test used four overlapping awk ranges,
# which interleaved the functions and eval'd malformed text — the SUBJECT was
# fine and the HARNESS was wrong. A range extraction must be contiguous.
helpers="$(sed -n '/^# PARSE-FAILURE TRUTH CONTRACT/,/^# Load main configuration/p' "$SUBJ" | sed '$d')"
if [[ -z "$helpers" ]] || ! grep -q '_nftban_report_jq()' <<<"$helpers"; then
    ne "guarded-jq helpers not found in subject"; echo "=== PASS=$PASS FAIL=$FAIL NOT_EXECUTED=$NOT_EXECUTED ==="; echo "RESULT: NOT_EXECUTED"; exit 0
fi
eval "$helpers"

echo "=== T1 valid document: value returned, rc=0, nothing marked degraded ==="
_NFTBAN_REPORT_DEGRADED_SECTIONS=""
v=$(_nftban_report_jq "$GOOD" '.data.load["5m"] // "0"' "system_resources"); rc=$?
[[ "$rc" == 0 && "$v" == "0.65" ]] && ok "valid -> rc=0 value=0.65" || no "valid -> rc=$rc value=[$v]"
[[ -z "$_NFTBAN_REPORT_DEGRADED_SECTIONS" ]] && ok "valid -> no section marked degraded" || no "valid -> wrongly marked [$_NFTBAN_REPORT_DEGRADED_SECTIONS]"

echo "=== T2 unparseable document: rc=1 and the section is named ==="
_NFTBAN_REPORT_DEGRADED_SECTIONS=""
v=$(_nftban_report_jq "$BAD" '.data // {}' "system_resources"); rc=$?
[[ "$rc" == 1 ]] && ok "unparseable -> rc=1 (failure is SIGNALLED, not swallowed)" || no "unparseable -> rc=$rc"
# ⛔ The helper runs in a SUBSHELL under command substitution, so it cannot mark
# the section itself. The contract lives at the CALL SITE: `|| mark` in the
# parent shell. Assert the shape the product actually uses.
_NFTBAN_REPORT_DEGRADED_SECTIONS=""
v=$(_nftban_report_jq "$BAD" '.data // {}' "system_resources") || _nftban_report_mark_degraded "system_resources"
[[ "$_NFTBAN_REPORT_DEGRADED_SECTIONS" == *"system_resources"* ]] && ok "caller-side marking survives the subshell: [$_NFTBAN_REPORT_DEGRADED_SECTIONS]" || no "section NOT named even at the call site"
grep -q '|| _nftban_report_mark_degraded' "$SUBJ" && ok "product marks degraded in the parent shell at its call sites" || no "product relies on subshell marking (would be lost)"

echo "=== T3 ⛔ the '// default' does NOT rescue a parse failure (why the fix is rc-based) ==="
raw=$(printf '%s\n' "$BAD" | jq -r '.load["5m"] // "0"' 2>/dev/null); rrc=$?
if [[ "$rrc" != 0 && -z "$raw" ]]; then
    ok "bare jq with a // default on an unparseable doc yields EMPTY (not \"0\"), rc=$rrc"
else
    no "expected empty+nonzero from the unguarded shape; got rc=$rrc value=[$raw]"
fi

echo "=== T4 instrumentation captures the payload and NEVER changes the verdict ==="
_NFTBAN_REPORT_DEGRADED_SECTIONS=""
_nftban_report_jq "$BAD" '.data // {}' "system_resources" >/dev/null
capdir="$SBOX/reports/parse-failures"
n=$(find "$capdir" -type f -name '*system_resources.raw' 2>/dev/null | wc -l)
[[ "$n" -ge 1 ]] && ok "unparseable payload captured ($n file)" || no "no capture written to $capdir"
_nftban_report_capture_unparseable "x" "y" >/dev/null 2>&1; crc=$?
[[ "$crc" == 0 ]] && ok "capture helper returns 0 (cannot alter the verdict)" || no "capture helper returned $crc"

echo "=== T5 capture is BOUNDED (must not copy an unbounded payload) ==="
big=$(head -c 40000 /dev/zero | tr '\0' 'A')
_nftban_report_capture_unparseable "bounded_probe" "$big" >/dev/null 2>&1
bf=$(find "$capdir" -type f -name '*bounded_probe.raw' 2>/dev/null | head -1)
if [[ -n "$bf" ]]; then
    sz=$(stat -c%s "$bf")
    [[ "$sz" -le 4400 ]] && ok "capture bounded at ${sz} B for a 40000 B payload" || no "capture NOT bounded: ${sz} B"
else
    no "bounded probe produced no file"
fi

echo "=== T6 verdict contract present in the subject (rc=2 = SENT BUT INCOMPLETE) ==="
grep -q 'return 2' "$SUBJ" && ok "generator can return 2" || no "generator has no rc=2 path"
grep -q 'NFTBAN_REPORT_DEGRADED_SECTIONS' "$SUBJ" && ok "generator publishes the degraded section list" || no "generator does not publish degraded sections"
grep -q '_gen_rc == 2' "$CMD" && ok "command layer handles rc=2 distinctly" || no "command layer does not handle rc=2"
grep -q 'PARTIAL' "$CMD" && ok "command layer emits a PARTIAL verdict" || no "command layer has no PARTIAL verdict"

echo "=== T7 ⛔ exactly ONE layer addresses the operator (defect C) ==="
if grep -q 'SUCCESS\] Report submitted' "$SUBJ"; then
    no "generator still prints its own [SUCCESS] — duplicate operator verdict"
else
    ok "generator no longer addresses the operator"
fi
if grep -qE 'nftban_mail_send "\$html" "\$recipient" >/dev/null 2>&1' "$SUBJ"; then
    ok "transport layer stdout suppressed at this call site"
else
    no "transport stdout not suppressed — third success line survives"
fi

echo "=== T8 INVERSION — the OLD unguarded shape passes silently (test discriminates) ==="
old_shape() { local d v; d=$(echo "$1" | jq -r '.data // {}' 2>/dev/null); v=$(echo "$d" | jq -r '.load["5m"] // "0"' 2>/dev/null); printf '%s' "$v"; return 0; }
ov=$(old_shape "$BAD"); orc=$?
if [[ "$orc" == 0 && -z "$ov" ]]; then
    ok "old shape: empty value AND rc=0 — exactly the defect; the fixed shape returns rc=1"
else
    no "inversion did not reproduce the defect (rc=$orc value=[$ov]) — arm has no power"
fi

echo
echo "=== PASS=$PASS FAIL=$FAIL NOT_EXECUTED=$NOT_EXECUTED ==="
if [[ "$FAIL" -eq 0 ]]; then echo "RESULT: PASS"; exit 0; else echo "RESULT: FAIL"; exit 1; fi
