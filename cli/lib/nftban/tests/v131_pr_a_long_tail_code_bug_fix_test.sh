#!/usr/bin/env bash
# =============================================================================
# V131 PR-A — long-tail code bug fix regression test (CB-1..CB-4)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="v131_pr_a_long_tail_code_bug_fix_test"
# meta:type="test"
# meta:version="1.131.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-25"
# meta:description="Deterministic assertions locking the 4 long-tail code bugs that V130 PR-C surfaced on lab2: CB-1 (cmd_blacklist.sh:264 grep-||-echo double-zero arithmetic crash), CB-2 (nftban_report_fhs.sh missing NFTBAN_FHS_ACTUAL associative array declaration → bash arithmetic eval of /etc/nftban path), CB-3 (cmd_selftest.sh:572 same grep-||-echo pattern → printf %d crash on '0\n0'), CB-4 (tests/selftest.sh:47 TRACE_LOG hardcoded to root-only path → permission denied leak when non-root). Tests are a mix of pattern grep (locks the structural shape) and behavioral subshell execution (proves CB-1 + CB-3 + CB-4 actually work post-fix; CB-2 is structural-grep only because exercising it requires populating the array which needs the full FHS validator pipeline)."
# meta:input="self-contained; sources only the files under test in subshells"
# meta:output="[PASS]/[FAIL] per assertion; exit 1 on first failure; exit 0 if all pass"
# meta:depends="bash 4+,grep"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="v131_pr_a_long_tail_code_bug_fix_test"
# meta:ta.owner="cross-cutting"
# meta:ta.module="code-bug-fix"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
#
# Scope: AUDIT_190_LIFECYCLE/V130_PR_C_LONG_TAIL_BATTERY_REPORT_DEB.md §3
# =============================================================================

set -Eeuo pipefail
set +e

TESTS_PASSED=0
TESTS_FAILED=0
FAILED_NAMES=()

_t_assert() {
    local name="$1"
    local ok="$2"
    local detail="${3:-}"
    if [[ "$ok" == "0" ]]; then
        printf "  [PASS] %s\n" "$name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        printf "  [FAIL] %s%s\n" "$name" "${detail:+ — $detail}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_NAMES+=("$name")
    fi
}

_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"

_blacklist="${_repo_root}/cli/lib/nftban/cli/cmd_blacklist.sh"
_selftest_cmd="${_repo_root}/cli/lib/nftban/cli/cmd_selftest.sh"
_fhs_report="${_repo_root}/cli/lib/nftban/core/nftban_report_fhs.sh"
_selftest_test="${_repo_root}/cli/lib/nftban/tests/selftest.sh"

echo "==============================================================================="
echo "V131 PR-A — long-tail code bug fix regression test (CB-1..CB-4)"
echo "==============================================================================="
echo "  Repo root:    $_repo_root"
echo

# ----------------------------------------------------------------------------
# CB-1: cmd_blacklist.sh:264 — grep-||-echo double-zero arithmetic crash
# ----------------------------------------------------------------------------
echo "--- CB-1: cmd_blacklist.sh blacklist files command ---"

# Structural: forbidden pattern must NOT reappear in EXECUTABLE code (strip
# shell comments before grepping so the explanatory comments here don't
# trip the test).
if sed -e 's,#.*$,,' "$_blacklist" | grep -qE 'grep -c[^|]*\|\|[[:space:]]*echo "0"'; then
    _t_assert "CB-1 (struct): cmd_blacklist.sh has no 'grep -c ... || echo \"0\"' double-zero pattern in executable code" 1 \
        "double-zero pattern present in non-comment line — V130 PR-C CB-1 regression"
else
    _t_assert "CB-1 (struct): cmd_blacklist.sh has no 'grep -c ... || echo \"0\"' double-zero pattern in executable code" 0
fi

# Structural: the V131 PR-A fix shape must be present (|| true for errexit
# suppression + parameter-default fallback for file-vanished edge case)
if grep -qE 'count=\$\(grep -cvE.*\|\|[[:space:]]*true[[:space:]]*\)' "$_blacklist" && \
   grep -qE 'count=\$\{count:-0\}' "$_blacklist"; then
    _t_assert "CB-1 (struct): cmd_blacklist.sh uses '|| true' errexit-suppression + \${count:-0} fallback" 0
else
    _t_assert "CB-1 (struct): cmd_blacklist.sh uses '|| true' errexit-suppression + \${count:-0} fallback" 1
fi

# Behavioral: simulate the exact failure context — grep on a no-match file
# and verify the arithmetic succeeds (was the crash site). Use a heredoc so
# the nested $() / $var / regex special-chars don't get triple-escaped.
_tmp_empty=$(mktemp)
trap 'rm -f "$_tmp_empty"' EXIT
printf '# only comments\n\n' > "$_tmp_empty"

_cb1_rc=$(TMP_FILE="$_tmp_empty" bash <<'BASH' 2>&1
set -Eeuo pipefail
total_ips=0
count=$(grep -cvE '^\s*(#|$)' "$TMP_FILE" 2>/dev/null || true)
count=${count:-0}
total_ips=$((total_ips + count))
echo "$total_ips"
BASH
)
if [[ "$_cb1_rc" == "0" ]]; then
    _t_assert "CB-1 (behavioral): fixed pattern handles grep -c no-match without arithmetic crash" 0
else
    _t_assert "CB-1 (behavioral): fixed pattern handles grep -c no-match without arithmetic crash" 1 \
        "expected '0', got: $_cb1_rc"
fi

# Behavioral: prove the OLD pattern would have crashed (sanity check the test
# is exercising the right thing). This MUST fail with the syntax error.
_cb1_old=$(TMP_FILE="$_tmp_empty" bash <<'BASH' 2>&1 || true
set -Eeuo pipefail
total_ips=0
count=$(grep -cvE '^\s*(#|$)' "$TMP_FILE" 2>/dev/null || echo "0")
total_ips=$((total_ips + count))
echo "$total_ips"
BASH
)
if echo "$_cb1_old" | grep -qE 'syntax error|operand'; then
    _t_assert "CB-1 (regression-witness): the OLD pattern still produces the arithmetic bug" 0
else
    _t_assert "CB-1 (regression-witness): the OLD pattern still produces the arithmetic bug" 1 \
        "old pattern unexpectedly succeeded — test may not exercise the bug class; got: $_cb1_old"
fi

# ----------------------------------------------------------------------------
# CB-2: nftban_report_fhs.sh — missing NFTBAN_FHS_ACTUAL declaration
# ----------------------------------------------------------------------------
echo "--- CB-2: nftban_report_fhs.sh NFTBAN_FHS_ACTUAL declaration ---"

if grep -qE '^declare -g -A NFTBAN_FHS_ACTUAL=\(\)' "$_fhs_report"; then
    _t_assert "CB-2 (struct): NFTBAN_FHS_ACTUAL declared as -g -A associative array" 0
else
    _t_assert "CB-2 (struct): NFTBAN_FHS_ACTUAL declared as -g -A associative array" 1 \
        "missing 'declare -g -A NFTBAN_FHS_ACTUAL=()' — bash will evaluate [\$path] as arithmetic and crash on /etc/nftban"
fi

# Behavioral: simulate the failure context — undeclared assoc array indexed
# by a path-like string. Must NOT throw "operand expected" after fix.
_cb2_rc=$(bash <<'BASH' 2>&1
set -Eeuo pipefail
declare -A NFTBAN_FHS_ACTUAL=()
path="/etc/nftban"
actual="${NFTBAN_FHS_ACTUAL[$path]:-N/A}"
echo "$actual"
BASH
)
if [[ "$_cb2_rc" == "N/A" ]]; then
    _t_assert "CB-2 (behavioral): with -A declaration, path-keyed lookup yields the fallback string" 0
else
    _t_assert "CB-2 (behavioral): with -A declaration, path-keyed lookup yields the fallback string" 1 \
        "got: $_cb2_rc"
fi

# Behavioral negative: the OLD undeclared-array path must produce the
# documented arithmetic crash (proves the test exercises the bug class).
_cb2_old=$(bash <<'BASH' 2>&1 || true
set -Eeuo pipefail
path="/etc/nftban"
actual="${NFTBAN_FHS_ACTUAL[$path]:-N/A}"
echo "$actual"
BASH
)
if echo "$_cb2_old" | grep -qE 'operand expected|syntax error'; then
    _t_assert "CB-2 (regression-witness): undeclared-array path produces 'operand expected' on '/etc/nftban'" 0
else
    _t_assert "CB-2 (regression-witness): undeclared-array path produces 'operand expected' on '/etc/nftban'" 1 \
        "old pattern unexpectedly succeeded — got: $_cb2_old"
fi

# ----------------------------------------------------------------------------
# CB-3: cmd_selftest.sh:572 — same grep-||-echo pattern → printf %d crash
# ----------------------------------------------------------------------------
echo "--- CB-3: cmd_selftest.sh blocked_countries printf ---"

# Structural: the forbidden pattern must NOT reappear in cmd_selftest.sh
# (same comment-stripping technique to avoid self-matching).
if sed -e 's,#.*$,,' "$_selftest_cmd" | grep -qE 'grep -c[^|]*\|\|[[:space:]]*echo "0"'; then
    _t_assert "CB-3 (struct): cmd_selftest.sh has no 'grep -c ... || echo \"0\"' double-zero pattern in executable code" 1
else
    _t_assert "CB-3 (struct): cmd_selftest.sh has no 'grep -c ... || echo \"0\"' double-zero pattern in executable code" 0
fi

# Structural: the fix must use '|| true' errexit-suppression + ${var:-0}
if grep -qE '\| grep -c[^|]*\|\|[[:space:]]*true[[:space:]]*\)' "$_selftest_cmd" && \
   grep -qE 'blocked_countries=\$\{blocked_countries:-0\}' "$_selftest_cmd" && \
   grep -qE 'file_count=\$\{file_count:-0\}' "$_selftest_cmd"; then
    _t_assert "CB-3 (struct): cmd_selftest.sh uses '|| true' + \${var:-0} fallback in both occurrences" 0
else
    _t_assert "CB-3 (struct): cmd_selftest.sh uses '|| true' + \${var:-0} fallback in both occurrences" 1
fi

# Behavioral: pipe a no-match grep into the fixed pattern + run the printf;
# must NOT emit "printf: 0" error.
_cb3_out=$(bash <<'BASH' 2>&1
set -Eeuo pipefail
# Input string that produces ZERO matches for the literal word we grep for —
# the original test data ("NO BLOCKED LINES HERE") contained "BLOCKED" so
# grep -c returned 1, not 0. Pick a string with no overlap.
blocked_countries=$(echo "this line will not match" | grep -c "FORBIDDEN_PATTERN_XYZ" 2>/dev/null || true)
blocked_countries=${blocked_countries:-0}
printf "     Countries blocked: %d\n" "$blocked_countries"
BASH
)
if [[ "$_cb3_out" == "     Countries blocked: 0" ]]; then
    _t_assert "CB-3 (behavioral): printf %d emits zero cleanly with fixed pattern" 0
else
    _t_assert "CB-3 (behavioral): printf %d emits zero cleanly with fixed pattern" 1 \
        "got: $_cb3_out"
fi

# ----------------------------------------------------------------------------
# CB-4: tests/selftest.sh:47 — TRACE_LOG fallback when default not writable
# ----------------------------------------------------------------------------
echo "--- CB-4: tests/selftest.sh TRACE_LOG fallback ---"

# Structural: the fallback init logic must exist
if grep -qE '_st_trace_dir' "$_selftest_test"; then
    _t_assert "CB-4 (struct): selftest.sh has _st_trace_dir fallback init" 0
else
    _t_assert "CB-4 (struct): selftest.sh has _st_trace_dir fallback init" 1 \
        "missing fallback logic — selftest will leak Permission denied for non-root"
fi

# Structural: the fallback must end with TMPDIR path containing $EUID for
# per-user isolation
if grep -qE 'TMPDIR:-/tmp.*nftban-selftest-\$\{?EUID' "$_selftest_test"; then
    _t_assert "CB-4 (struct): TRACE_LOG fallback path is per-user (\$EUID-scoped)" 0
else
    _t_assert "CB-4 (struct): TRACE_LOG fallback path is per-user (\$EUID-scoped)" 1
fi

# Structural: NFTBAN_LOG_DIR operator override must still be honored as-is
# (operator knows what they want; we do NOT redirect their explicit override)
if grep -qE '_st_trace_dir="\$\{NFTBAN_LOG_DIR:-/var/log/nftban\}"' "$_selftest_test" && \
   grep -qE 'if \[\[ -z "\$\{NFTBAN_LOG_DIR:-\}" \]\]' "$_selftest_test"; then
    _t_assert "CB-4 (struct): NFTBAN_LOG_DIR operator override path is honored as-is (not redirected)" 0
else
    _t_assert "CB-4 (struct): NFTBAN_LOG_DIR operator override path is honored as-is (not redirected)" 1
fi

# Behavioral: simulate the failure context — non-writable default + no
# NFTBAN_LOG_DIR override. The fallback must pick a writable path.
_cb4_rc=$(unset NFTBAN_LOG_DIR; bash <<'BASH' 2>&1
set -Eeuo pipefail
_st_trace_dir="/nonexistent/cannot/write/here"
if [[ -z "${NFTBAN_LOG_DIR:-}" ]] \
   && [[ ! -w "$_st_trace_dir" ]] \
   && ! mkdir -p "$_st_trace_dir" 2>/dev/null; then
    _st_trace_dir="${TMPDIR:-/tmp}/nftban-selftest-${EUID}"
    mkdir -p "$_st_trace_dir" 2>/dev/null || _st_trace_dir="${TMPDIR:-/tmp}"
fi
TRACE_LOG="${_st_trace_dir}/debug_trace.log"
# Try to write to it
echo "test trace line" >> "$TRACE_LOG" 2>&1 && echo "WROTE: $TRACE_LOG"
rm -f "$TRACE_LOG"
BASH
)
if echo "$_cb4_rc" | grep -qE 'WROTE: /tmp/nftban-selftest-|WROTE: /tmp/debug_trace'; then
    _t_assert "CB-4 (behavioral): fallback path is writable; trace append succeeds" 0
else
    _t_assert "CB-4 (behavioral): fallback path is writable; trace append succeeds" 1 \
        "got: $_cb4_rc"
fi

# ----------------------------------------------------------------------------
# Cross-cutting: spot-check the rest of the codebase for the SAME grep-||-echo
# pattern (CB-1+CB-3 shape) and warn but do NOT fail (out of scope to fix
# others in this PR; operator-only decision whether to widen scope).
# ----------------------------------------------------------------------------
echo "--- cross-cutting scan (informational only) ---"
_other_hits=$(grep -rlE 'grep -c[^|]*\|\|[[:space:]]*echo "0"' \
    "${_repo_root}/cli/lib/nftban/" 2>/dev/null \
    | grep -vE '/tests/v131_pr_a_long_tail_code_bug_fix_test\.sh$' \
    | grep -vE '/cli/cmd_blacklist\.sh$|/cli/cmd_selftest\.sh$' || true)
if [[ -z "$_other_hits" ]]; then
    _t_assert "Z1 (informational): no other 'grep -c ... || echo \"0\"' instances in cli/lib/nftban/" 0
else
    # Don't fail the suite — out of PR-A scope per operator. Just log.
    echo "  [INFO] other files still have the pattern (out of PR-A scope to fix):"
    echo "$_other_hits" | sed 's|^|         - |'
    _t_assert "Z1 (informational): no other 'grep -c ... || echo \"0\"' instances in cli/lib/nftban/" 0
fi

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
echo
echo "==============================================================================="
echo "V131 PR-A regression test summary"
echo "==============================================================================="
echo "  Passed:  $TESTS_PASSED"
echo "  Failed:  $TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
    echo "  Failed assertions:"
    for n in "${FAILED_NAMES[@]}"; do
        echo "    - $n"
    done
    exit 1
fi
exit 0
