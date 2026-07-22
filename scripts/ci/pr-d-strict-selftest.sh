#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="pr-d-strict-selftest"
# meta:type="script"
# meta:version="1.226.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="PR-D negative-test suite: proves strict authority enforcement + quarantine model fail closed on every drift/regression/quarantine-abuse condition"
# meta:inventory.files="scripts/ci/run-test-suite.sh,scripts/ci/check-quarantine-registry.sh,scripts/ci/test-authority.py"
# meta:inventory.binaries="bash,git,python3,mktemp,awk,grep,sed"
# meta:inventory.env_vars="NFTBAN_TODAY"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# PR-D strict-enforcement negative tests (v1.226.0). Each builds a synthetic git
# repo wrapping the REAL tools (run-test-suite.sh, check-quarantine-registry.sh,
# test-authority.py) and asserts CI FAILS CLOSED on the condition. Hermetic; all
# values synthetic. Expected-nonzero calls are captured in compounds so
# `set -Eeuo pipefail` never aborts on an intended failure.
# =============================================================================
set -Eeuo pipefail

CIDIR="$(cd "$(dirname "$0")" && pwd)"
REAL_RUNNER="$CIDIR/run-test-suite.sh"
REAL_QREG="$CIDIR/check-quarantine-registry.sh"
REAL_TA="$CIDIR/test-authority.py"
FAIL=0
ok()  { printf '  ok   %-4s %s\n' "$1" "$2"; }
bad() { printf '  FAIL %-4s %s  %s\n' "$1" "$2" "${3:-}"; FAIL=1; }

# A migrated _test.sh with a full valid meta:ta.* header (ci-bash, hermetic).
emit_test() {   # path id body [timeout]
    { printf '#!/usr/bin/env bash\n'
      printf '# meta:ta.id="%s"\n' "$2"
      printf '# meta:ta.owner="test-infra"\n# meta:ta.module="cross-cutting"\n'
      printf '# meta:ta.execution_class="CI_HERMETIC_SHELL"\n# meta:ta.gate="ci-bash"\n'
      printf '# meta:ta.hermetic="true"\n# meta:ta.requires_root="false"\n# meta:ta.requires_network="false"\n'
      printf '# meta:ta.requires_systemd="false"\n# meta:ta.requires_nftables="false"\n# meta:ta.requires_package="false"\n'
      [ -n "${4:-}" ] && printf '# meta:ta.timeout="%s"\n' "$4"
      printf 'set -Eeuo pipefail\n%b\n' "$3"
    } > "$1"
}
gen() { ( cd "$1" && python3 scripts/ci/test-authority.py generate >/dev/null 2>&1 ); }
mkrepo() {   # -> root with real tools + a generated index over 2 green tests
    local r; r="$(mktemp -d)"; git init -q "$r"; git -C "$r" config user.email t@t; git -C "$r" config user.name t
    mkdir -p "$r/cli/lib/nftban/tests" "$r/scripts/ci"
    cp "$REAL_RUNNER" "$REAL_QREG" "$r/scripts/ci/"; cp "$REAL_TA" "$r/scripts/ci/test-authority.py"
    emit_test "$r/cli/lib/nftban/tests/green_a_test.sh" green_a_test 'exit 0'
    # green_b asserts a sentinel that appears ONLY in the trailing comment (the
    # grep line itself is built by concatenation so it cannot self-match).
    emit_test "$r/cli/lib/nftban/tests/green_b_test.sh" green_b_test 'M="SEN""TINEL_TOK"; grep -q "$M" "$0" || exit 1; exit 0
# SENTINEL_TOK'
    gen "$r"
    printf '%s' "$r"
}
addfailing() {  # root id [pattern-line] -> a ci-bash test that FAILs, regenerate index
    emit_test "$1/cli/lib/nftban/tests/$2.sh" "$2" "echo \"${3:-boom failure here}\"; exit 1"
    gen "$1"
}
mkreg() {   # root ceiling then QT rows on stdin
    { printf '# synthetic quarantine registry\nQUARANTINE_CEILING=%s\n' "$2"; cat; } > "$1/scripts/ci/ci-bash-quarantine.tsv"
}
# a full valid 12-field QT row: id path disposition efc pattern review lane
qrow() {
    local id="$1" path="$2" disp="$3" efc="${4:-STALE_EXPECTATION}" pat="${5:-}" review="${6:-2026-12-31}" lane="${7:-PR-X}"
    printf 'QT\t%s\t%s\ttest-infra\tsynthetic reason\tV1226-X\t2026-07-22\t%s\t%s\t%s\t%s\t%s' \
        "$id" "$path" "$review" "$disp" "$efc" "$lane" "$pat"
}
inrepo() { ( cd "$1" && shift && "$@" ); }
P() { printf 'cli/lib/nftban/tests/%s.sh' "$1"; }

# ---- 1. new unclassified test blocks CI (strict validator) -------------------
n1() { local r; r="$(mkrepo)"
    printf '#!/usr/bin/env bash\nset -Eeuo pipefail\nexit 0\n' > "$r/cli/lib/nftban/tests/orphan_test.sh"
    inrepo "$r" python3 scripts/ci/test-authority.py validate --mode strict >/dev/null 2>&1 \
        && bad 1 "unclassified accepted" || ok 1 "new unclassified test blocks (strict)"; rm -rf "$r"; }

# ---- 2/13. missing test file blocks (runtime MISSING; freshness disabled) -----
n2() { local r; r="$(mkrepo)"
    rm -f "$r/scripts/ci/test-authority.py"                   # disable freshness -> exercise runtime MISSING
    rm -f "$r/cli/lib/nftban/tests/green_b_test.sh"           # index still lists it
    local rc=0; inrepo "$r" bash scripts/ci/run-test-suite.sh run --gate ci-bash >/dev/null 2>&1 || rc=$?
    [ "$rc" != "0" ] && ok 2 "missing test file blocks (MISSING/non-zero rc=$rc)" || bad 2 "missing not blocking"; rm -rf "$r"; }

# ---- 3. duplicate id blocks (validator/collect) ------------------------------
n3() { local r; r="$(mkrepo)"
    emit_test "$r/cli/lib/nftban/tests/dupid_test.sh" green_a_test 'exit 0'
    inrepo "$r" python3 scripts/ci/test-authority.py check >/dev/null 2>&1 \
        && bad 3 "dup id accepted" || ok 3 "duplicate id blocks"; rm -rf "$r"; }

# ---- 4. duplicate path blocks (runner structural) ----------------------------
n4() { local r; r="$(mkrepo)"
    local row; row="$(awk -F'\t' '/green_a_test\.sh/{print; exit}' "$r/scripts/ci/test-authority-index.tsv")"
    printf '%s\n' "$row" >> "$r/scripts/ci/test-authority-index.tsv"
    rm -f "$r/scripts/ci/test-authority.py"                   # avoid freshness masking the structural check
    inrepo "$r" bash scripts/ci/run-test-suite.sh verify >/dev/null 2>&1 \
        && bad 4 "dup path accepted" || ok 4 "duplicate path blocks"; rm -rf "$r"; }

# ---- 5. unknown execution class blocks (validator) ---------------------------
n5() { local r; r="$(mkrepo)"
    sed -i 's/ta.execution_class="CI_HERMETIC_SHELL"/ta.execution_class="NONSENSE_CLASS"/' "$r/cli/lib/nftban/tests/green_a_test.sh"
    inrepo "$r" python3 scripts/ci/test-authority.py validate --mode strict >/dev/null 2>&1 \
        && bad 5 "unknown class accepted" || ok 5 "unknown execution class blocks"; rm -rf "$r"; }

# ---- 6/11. non-quarantined failing test blocks (no auto-quarantine) ----------
n6() { local r; r="$(mkrepo)"; addfailing "$r" redx_test
    mkreg "$r" 0 </dev/null
    local rc=0; inrepo "$r" bash scripts/ci/run-test-suite.sh run --gate ci-bash --quarantine scripts/ci/ci-bash-quarantine.tsv >/dev/null 2>&1 || rc=$?
    [ "$rc" = "1" ] && ok 6 "non-quarantined failure blocks (no auto-quarantine)" || bad 6 "auto-accepted" "rc=$rc"; rm -rf "$r"; }

# ---- 7. quarantined test executes AND reports (non-blocking) ------------------
n7() { local r; r="$(mkrepo)"; addfailing "$r" redx_test "matcher binary unavailable"
    mkreg "$r" 1 <<< "$(qrow redx_test "$(P redx_test)" ENVIRONMENT_SENSITIVE MISSING_MATCHER "matcher binary unavailable")"
    local rc=0; inrepo "$r" bash scripts/ci/run-test-suite.sh run --gate ci-bash --quarantine scripts/ci/ci-bash-quarantine.tsv --manifest "$r/m.txt" >/dev/null 2>&1 || rc=$?
    if [ "$rc" = "0" ] && grep -q 'TEST	QUARANTINED	redx_test' "$r/m.txt"; then
        ok 7 "quarantined test executes + reports, non-blocking"; else bad 7 "quarantine not honored" "rc=$rc"; fi; rm -rf "$r"; }

# ---- 8. quarantined test missing owner blocks (registry validator) -----------
n8() { local r; r="$(mkrepo)"; addfailing "$r" redx_test
    mkreg "$r" 1 <<< $'QT\tredx_test\tcli/lib/nftban/tests/redx_test.sh\t\treason\tV1226-X\t2026-07-22\t2026-12-31\tENVIRONMENT_SENSITIVE\tEFC\tPR-X\t'
    inrepo "$r" bash scripts/ci/check-quarantine-registry.sh >/dev/null 2>&1 \
        && bad 8 "missing owner accepted" || ok 8 "quarantine missing owner blocks"; rm -rf "$r"; }

# ---- 9. quarantined test missing reason/finding blocks -----------------------
n9() { local r; r="$(mkrepo)"; addfailing "$r" redx_test
    mkreg "$r" 1 <<< $'QT\tredx_test\tcli/lib/nftban/tests/redx_test.sh\ttest-infra\t\t\t2026-07-22\t2026-12-31\tENVIRONMENT_SENSITIVE\tEFC\tPR-X\t'
    inrepo "$r" bash scripts/ci/check-quarantine-registry.sh >/dev/null 2>&1 \
        && bad 9 "missing reason/finding accepted" || ok 9 "quarantine missing reason/finding blocks"; rm -rf "$r"; }

# ---- 10. expired quarantine blocks -------------------------------------------
n10() { local r; r="$(mkrepo)"; addfailing "$r" redx_test
    mkreg "$r" 1 <<< "$(qrow redx_test "$(P redx_test)" ENVIRONMENT_SENSITIVE EFC "" 2026-02-01)"
    NFTBAN_TODAY=2026-07-22 inrepo "$r" bash scripts/ci/check-quarantine-registry.sh >/dev/null 2>&1 \
        && bad 10 "expired accepted" || ok 10 "expired quarantine blocks"; rm -rf "$r"; }

# ---- 12. quarantine count increase over ceiling blocks -----------------------
n12() { local r; r="$(mkrepo)"; addfailing "$r" redx_test; addfailing "$r" redy_test
    mkreg "$r" 1 <<< "$(qrow redx_test "$(P redx_test)" ENVIRONMENT_SENSITIVE EFC)"$'\n'"$(qrow redy_test "$(P redy_test)" ENVIRONMENT_SENSITIVE EFC)"
    inrepo "$r" bash scripts/ci/check-quarantine-registry.sh >/dev/null 2>&1 \
        && bad 12 "over-ceiling accepted" || ok 12 "quarantine count over ceiling blocks"; rm -rf "$r"; }

# ---- 14. required timeout blocks (fresh ta.timeout=1) ------------------------
n14() { local r; r="$(mkrepo)"
    emit_test "$r/cli/lib/nftban/tests/slow_test.sh" slow_test 'sleep 30' 1
    gen "$r"
    local rc=0; inrepo "$r" bash scripts/ci/run-test-suite.sh run --gate ci-bash >/dev/null 2>&1 || rc=$?
    [ "$rc" = "1" ] && ok 14 "required timeout blocks" || bad 14 "timeout not blocking" "rc=$rc"; rm -rf "$r"; }

# ---- 15. every selected test has a result record (completeness) --------------
n15() { local r; r="$(mkrepo)"
    inrepo "$r" bash scripts/ci/run-test-suite.sh run --gate ci-bash --manifest "$r/m.txt" >/dev/null 2>&1
    local sel exe; sel="$(awk -F'\t' '$1=="SELECTED"{print $2}' "$r/m.txt")"
    exe="$(awk -F'\t' '$1=="TEST"{c++}END{print c+0}' "$r/m.txt")"
    [ "$sel" = "$exe" ] && [ "$sel" -gt 0 ] && ok 15 "every selected test has a result record ($exe/$sel)" || bad 15 "result record gap" "sel=$sel exe=$exe"; rm -rf "$r"; }

# ---- 16. duplicate execution (duplicate selected id) blocks ------------------
n16() { local r; r="$(mkrepo)"
    local row; row="$(awk -F'\t' '/green_a_test\.sh/{print}' "$r/scripts/ci/test-authority-index.tsv")"
    cp "$r/cli/lib/nftban/tests/green_a_test.sh" "$r/cli/lib/nftban/tests/green_a_dup_test.sh"
    printf '%s\n' "$row" | awk -F'\t' 'BEGIN{OFS="\t"}{$2="cli/lib/nftban/tests/green_a_dup_test.sh"; print}' >> "$r/scripts/ci/test-authority-index.tsv"
    rm -f "$r/scripts/ci/test-authority.py"
    local rc=0; inrepo "$r" bash scripts/ci/run-test-suite.sh run --gate ci-bash >/dev/null 2>&1 || rc=$?
    [ "$rc" = "2" ] && ok 16 "duplicate execution (dup selected id) blocks" || bad 16 "dup exec not blocked" "rc=$rc"; rm -rf "$r"; }

# ---- 17. stale index blocks --------------------------------------------------
n17() { local r; r="$(mkrepo)"
    sed -i '0,/\tci-bash\t/s//\tpolicy-gates\t/' "$r/scripts/ci/test-authority-index.tsv"
    inrepo "$r" bash scripts/ci/run-test-suite.sh verify >/dev/null 2>&1 \
        && bad 17 "stale index accepted" || ok 17 "stale index blocks (freshness)"; rm -rf "$r"; }

# ---- 18. false-green mutation of a non-quarantined test blocks ----------------
n18() { local r; r="$(mkrepo)"
    local rc=0; inrepo "$r" bash scripts/ci/run-test-suite.sh run --gate ci-bash >/dev/null 2>&1 || rc=$?
    [ "$rc" = "0" ] || { bad 18 "baseline not green" "rc=$rc"; rm -rf "$r"; return; }
    sed -i '/^# SENTINEL_TOK$/d' "$r/cli/lib/nftban/tests/green_b_test.sh"; gen "$r"
    rc=0; inrepo "$r" bash scripts/ci/run-test-suite.sh run --gate ci-bash >/dev/null 2>&1 || rc=$?
    [ "$rc" = "1" ] && ok 18 "false-green mutation of non-quarantined test blocks" || bad 18 "mutation passed" "rc=$rc"; rm -rf "$r"; }

# ---- pattern binding: quarantined failure whose CATEGORY changes blocks -------
nsig() { local r; r="$(mkrepo)"; addfailing "$r" sigx_test "matcher binary unavailable"
    mkreg "$r" 1 <<< "$(qrow sigx_test "$(P sigx_test)" ENVIRONMENT_SENSITIVE MISSING_MATCHER "matcher binary unavailable")"
    local rc=0; inrepo "$r" bash scripts/ci/run-test-suite.sh run --gate ci-bash --quarantine scripts/ci/ci-bash-quarantine.tsv >/dev/null 2>&1 || rc=$?
    [ "$rc" = "0" ] || { bad sig "matched pattern should be non-blocking" "rc=$rc"; rm -rf "$r"; return; }
    addfailing "$r" sigx_test "a totally different failure category"   # same outcome, different category
    rc=0; inrepo "$r" bash scripts/ci/run-test-suite.sh run --gate ci-bash --quarantine scripts/ci/ci-bash-quarantine.tsv >/dev/null 2>&1 || rc=$?
    [ "$rc" = "1" ] && ok sig "changed failure category (pattern absent) blocks" || bad sig "category change not blocked" "rc=$rc"; rm -rf "$r"; }

# ---- disappear: a quarantined test not in the selected set blocks -------------
nvanish() { local r; r="$(mkrepo)"
    # quarantine an id that does not exist as a ci-bash test in the index
    mkreg "$r" 1 <<< "$(qrow ghost_test cli/lib/nftban/tests/ghost_test.sh ENVIRONMENT_SENSITIVE EFC)"
    local rc=0; inrepo "$r" bash scripts/ci/run-test-suite.sh run --gate ci-bash --quarantine scripts/ci/ci-bash-quarantine.tsv >/dev/null 2>&1 || rc=$?
    [ "$rc" = "1" ] && ok van "quarantined test that never executes (disappeared) blocks" || bad van "vanish not blocked" "rc=$rc"; rm -rf "$r"; }

# ---- unexpected pass: a quarantined test that now PASSES blocks ---------------
npass() { local r; r="$(mkrepo)"                              # green_a passes but is quarantined
    mkreg "$r" 1 <<< "$(qrow green_a_test "$(P green_a_test)" TEST_EXPECTATION_STALE EFC)"
    local rc=0; inrepo "$r" bash scripts/ci/run-test-suite.sh run --gate ci-bash --quarantine scripts/ci/ci-bash-quarantine.tsv >/dev/null 2>&1 || rc=$?
    [ "$rc" = "1" ] && ok pass "quarantined test unexpectedly passing blocks (reconcile)" || bad pass "quar-pass not blocked" "rc=$rc"; rm -rf "$r"; }

# ---- PR-E ownership: PR_E_RBL_FIXTURE with non-PR-E lane blocks ---------------
nprE() { local r; r="$(mkrepo)"; addfailing "$r" redx_test
    mkreg "$r" 1 <<< "$(qrow redx_test "$(P redx_test)" PR_E_RBL_FIXTURE RBL_FIXTURE "" 2026-12-31 PR-X)"
    inrepo "$r" bash scripts/ci/check-quarantine-registry.sh >/dev/null 2>&1 \
        && bad prE "PR-E lost ownership accepted" || ok prE "PR-E item without PR-E lane blocks"; rm -rf "$r"; }

for t in n1 n2 n3 n4 n5 n6 n7 n8 n9 n10 n12 n14 n15 n16 n17 n18 nsig nvanish npass nprE; do "$t"; done
echo
if [ "$FAIL" -eq 0 ]; then echo "PR_D_STRICT_SELFTEST_PASS"; exit 0
else echo "PR_D_STRICT_SELFTEST_FAIL"; exit 1; fi
