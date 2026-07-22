#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="run-test-suite-selftest"
# meta:type="script"
# meta:version="1.226.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Hermetic self-tests for run-test-suite.sh: selection, isolation, false-green mutation, injection inertness, fail-closed validation"
# meta:inventory.files="scripts/ci/run-test-suite.sh"
# meta:inventory.binaries="bash,git,mktemp,awk,grep,sed,printf,wc,sort"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Self-tests for scripts/ci/run-test-suite.sh (v1.226.0 PR-C).
#
# Hermetic: builds throwaway git repos with a SYNTHETIC index + tiny fixture
# tests and drives the real runner, asserting the 22-point safety contract,
# class semantics, isolation, and a false-green mutation. No network, no root,
# no dependency on the live 241-test corpus. All values are synthetic.
# =============================================================================
# This harness runs the runner with inputs EXPECTED to exit nonzero
# (fail/timeout/safety-refusal). NFTBan coding standards require `set -Eeuo
# pipefail`, so every expected-nonzero call is captured in a compound
# (`... || rc=$?`, or `if ... then/else`) so -e never aborts on an intended failure.
set -Eeuo pipefail

RUNNER="$(cd "$(dirname "$0")" && pwd)/run-test-suite.sh"
FAIL=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s  %s\n' "$1" "${2:-}"; FAIL=1; }

# Header row mirrors the real 16-column index; only id(1) path(2) gate(7) timeout(14) are read.
HEADER=$'id\tpath\towner\ttype\tmodule\texecution_class\tgate\thermetic\trequires_root\trequires_network\trequires_systemd\trequires_nftables\trequires_package\ttimeout\texclusion_reason\tactivation_condition'

mkrepo() {
    local root; root="$(mktemp -d)"
    git init -q "$root"; git -C "$root" config user.email t@t; git -C "$root" config user.name t
    mkdir -p "$root/cli/lib/nftban/tests" "$root/scripts/ci"
    printf '%s' "$root"
}
addtest() {  # root name body
    printf '#!/usr/bin/env bash\n%b\n' "$3" > "$1/cli/lib/nftban/tests/$2"
}
mkindex() {  # root then rows on stdin -> writes index with banner+header
    { printf '# GENERATED FILE — DO NOT EDIT\n#\n#\n%s\n' "$HEADER"; cat; } > "$1/scripts/ci/test-authority-index.tsv"
}
row() {  # id gate [timeout] -> a full 16-col row for cli/lib/nftban/tests/<id>.sh
    local id="$1" gate="$2" tmo="${3:-}"
    printf '%s\tcli/lib/nftban/tests/%s.sh\to\ttest\tm\tCI_HERMETIC_SHELL\t%s\ttrue\tfalse\tfalse\tfalse\tfalse\tfalse\t%s\t\t\n' "$id" "$id" "$gate" "$tmo"
}
runr() { ( cd "$1" && shift && "$RUNNER" "$@" ); }   # run runner inside repo root

# ---- selection + execution ---------------------------------------------------
test_valid_run() {
    echo test_valid_run
    local r; r="$(mkrepo)"
    addtest "$r" a_test.sh 'exit 0'; addtest "$r" b_test.sh 'exit 0'
    mkindex "$r" <<< "$(row a_test ci-bash; row b_test ci-bash)"
    local out rc=0; out="$(runr "$r" run --gate ci-bash 2>/dev/null)" || rc=$?
    [ $rc -eq 0 ] && grep -q 'total=2 pass=2 fail=0' <<<"$out" && ok "valid gate runs and passes" || bad "valid_run" "$out"
    rm -rf "$r"
}
test_fail_propagates() {
    echo test_fail_propagates
    local r; r="$(mkrepo)"
    addtest "$r" a_test.sh 'exit 0'; addtest "$r" f_test.sh 'exit 1'
    mkindex "$r" <<< "$(row a_test ci-bash; row f_test ci-bash)"
    local rc=0; runr "$r" run --gate ci-bash >/dev/null 2>&1 || rc=$?
    [ $rc -eq 1 ] && ok "an executed FAIL propagates nonzero" || bad "fail_propagates" "rc=$rc"
    rm -rf "$r"
}
test_timeout_propagates() {
    echo test_timeout_propagates
    local r; r="$(mkrepo)"
    addtest "$r" slow_test.sh 'sleep 30'
    mkindex "$r" <<< "$(row slow_test ci-bash 1)"   # 1s timeout
    local rc=0 out; out="$(runr "$r" run --gate ci-bash 2>&1)" || rc=$?
    [ $rc -eq 1 ] && grep -q 'timeout=1' <<<"$out" && ok "TIMEOUT propagates nonzero" || bad "timeout" "rc=$rc $out"
    rm -rf "$r"
}
test_deferred_not_executed() {
    echo test_deferred_not_executed
    local r; r="$(mkrepo)"
    addtest "$r" d_test.sh 'exit 1'    # would fail IF executed
    mkindex "$r" <<< "$(row d_test deferred)"
    # run must refuse deferred as non-executable
    local rc=0; runr "$r" run --gate deferred >/dev/null 2>&1 || rc=$?
    [ $rc -eq 2 ] && ok "deferred refused by run (never executed)" || bad "deferred_run" "rc=$rc"
    # report shows it, exit 0, no execution
    local out; out="$(runr "$r" report --gate deferred 2>&1)"
    grep -q 'count=1' <<<"$out" && ok "deferred visible in report (not counted PASS)" || bad "deferred_report" "$out"
    rm -rf "$r"
}
test_lab_manual_and_package() {
    echo test_lab_manual_and_package
    local r; r="$(mkrepo)"
    addtest "$r" l_test.sh 'exit 1'; addtest "$r" p_test.sh 'exit 1'
    mkindex "$r" <<< "$(row l_test lab-manual; row p_test package-build)"
    runr "$r" run --gate lab-manual >/dev/null 2>&1 && bad "lab_run_should_refuse" || ok "lab-manual not executable via run"
    runr "$r" run --gate package-build >/dev/null 2>&1 && bad "pkg_run_should_refuse" || ok "package-build excluded from ordinary run"
    local prc=0; runr "$r" run --gate package-build --allow-package >/dev/null 2>&1 || prc=$?
    [ "$prc" -eq 1 ] && ok "package-build runs only with --allow-package (and the failing fixture fails)" || bad "pkg_allow"
    rm -rf "$r"
}
# ---- validation / safety -----------------------------------------------------
test_reject_unknown_gate() {
    echo test_reject_unknown_gate
    local r; r="$(mkrepo)"; addtest "$r" a_test.sh 'exit 0'
    mkindex "$r" <<< "$(row a_test not-a-gate)"
    runr "$r" verify >/dev/null 2>&1 && bad "unknown_gate_accepted" || ok "unknown gate value rejected (exit 2)"
    rm -rf "$r"
}
test_reject_dupes_and_missing() {
    echo test_reject_dupes_and_missing
    local r
    r="$(mkrepo)"; addtest "$r" a_test.sh 'exit 0'
    mkindex "$r" <<< "$(row a_test ci-bash; row a_test ci-bash)"   # dup id+path
    runr "$r" verify >/dev/null 2>&1 && bad "dup_accepted" || ok "duplicate id/path rejected"
    rm -rf "$r"
    r="$(mkrepo)"   # missing path (no file)
    mkindex "$r" <<< "$(row ghost_test ci-bash)"
    local rc=0 out; out="$(runr "$r" run --gate ci-bash 2>&1)" || rc=$?
    grep -q 'MISSING' <<<"$out" && [ $rc -eq 1 ] && ok "missing test path -> MISSING + nonzero" || bad "missing_path" "rc=$rc"
    rm -rf "$r"
}
test_reject_traversal() {
    echo test_reject_traversal
    local r; r="$(mkrepo)"; addtest "$r" a_test.sh 'exit 0'
    mkindex "$r" <<< $'evil\tcli/lib/nftban/tests/../../../etc/passwd\to\ttest\tm\tCI_HERMETIC_SHELL\tci-bash\ttrue\tfalse\tfalse\tfalse\tfalse\tfalse\t\t\t'
    runr "$r" verify >/dev/null 2>&1 && bad "traversal_accepted" || ok "path traversal rejected"
    rm -rf "$r"
}
test_injection_inert() {
    echo test_injection_inert
    local r; r="$(mkrepo)"
    # a test id/path containing shell metacharacters must be treated as inert data.
    addtest "$r" 'inj_test.sh' 'exit 0'
    mkindex "$r" <<< $'inj_test; touch /tmp/PWNED_rts\tcli/lib/nftban/tests/inj_test.sh\to\ttest\tm\tCI_HERMETIC_SHELL\tci-bash\ttrue\tfalse\tfalse\tfalse\tfalse\tfalse\t\t\t'
    rm -f /tmp/PWNED_rts
    runr "$r" run --gate ci-bash >/dev/null 2>&1 || true
    [ ! -e /tmp/PWNED_rts ] && ok "metadata command-injection is inert (no side effect)" || { bad "injection"; rm -f /tmp/PWNED_rts; }
    rm -rf "$r"
}
test_isolation() {
    echo test_isolation
    local r; r="$(mkrepo)"
    # test 1 changes dir + shell options + exports; test 2 must be unaffected and pass.
    addtest "$r" one_test.sh 'cd /; set +e; export LEAK=1; exit 0'
    addtest "$r" two_test.sh '[ "${LEAK:-}" = "1" ] && exit 1; [ "$(pwd)" = "/" ] && exit 1; exit 0'
    mkindex "$r" <<< "$(row one_test ci-bash; row two_test ci-bash)"
    runr "$r" run --gate ci-bash >/dev/null 2>&1 && ok "subprocess isolation: one test cannot contaminate the next" || bad "isolation"
    rm -rf "$r"
}
test_no_double_exec() {
    echo test_no_double_exec
    local r; r="$(mkrepo)"
    addtest "$r" c_test.sh "printf x >> '$r/counter'; exit 0"
    mkindex "$r" <<< "$(row c_test ci-bash)"
    : > "$r/counter"
    runr "$r" run --gate ci-bash >/dev/null 2>&1
    [ "$(wc -c < "$r/counter")" -eq 1 ] && ok "each selected test executes exactly once" || bad "double_exec count=$(wc -c < "$r/counter")"
    rm -rf "$r"
}
test_empty_and_deterministic() {
    echo test_empty_and_deterministic
    local r; r="$(mkrepo)"; addtest "$r" a_test.sh 'exit 0'
    mkindex "$r" <<< "$(row a_test policy-gates)"
    local out; out="$(runr "$r" run --gate ci-bash 2>&1)"   # ci-bash selects 0 here
    grep -q 'total=0' <<<"$out" && ok "empty selected gate explicitly reported total=0 (exit 0)" || bad "empty_gate" "$out"
    rm -rf "$r"
}
test_false_green_mutation() {
    echo test_false_green_mutation
    local r; r="$(mkrepo)"
    addtest "$r" m_test.sh 'grep -q EXPECTED_TOKEN "$0" && exit 0 || exit 1
# EXPECTED_TOKEN'
    mkindex "$r" <<< "$(row m_test ci-bash)"
    runr "$r" run --gate ci-bash >/dev/null 2>&1 && local base=0 || local base=1
    # mutate: remove the token the test asserts on
    sed -i 's/EXPECTED_TOKEN//g' "$r/cli/lib/nftban/tests/m_test.sh"
    runr "$r" run --gate ci-bash >/dev/null 2>&1 && local mut=0 || local mut=1
    [ $base -eq 0 ] && [ $mut -eq 1 ] && ok "false-green mutation: runner fails when a required test is broken" || bad "mutation base=$base mut=$mut"
    rm -rf "$r"
}
test_missing_index_fail_closed() {
    echo test_missing_index_fail_closed
    local r; r="$(mkrepo)"; rm -f "$r/scripts/ci/test-authority-index.tsv"
    runr "$r" verify >/dev/null 2>&1 && bad "missing_index_accepted" || ok "missing index fails closed (exit 2)"
    rm -rf "$r"
}

for t in test_valid_run test_fail_propagates test_timeout_propagates test_deferred_not_executed \
         test_lab_manual_and_package test_reject_unknown_gate test_reject_dupes_and_missing \
         test_reject_traversal test_injection_inert test_isolation test_no_double_exec \
         test_empty_and_deterministic test_false_green_mutation test_missing_index_fail_closed; do
    "$t"
done
echo
if [ "$FAIL" -eq 0 ]; then echo "RUN_TEST_SUITE_SELFTEST_PASS"; exit 0
else echo "RUN_TEST_SUITE_SELFTEST_FAIL"; exit 1; fi
