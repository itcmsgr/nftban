#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# check-pipefail-epipe-shortcircuit.sh — v1.228.9 recurrence guard.
#
# THE SHAPE
#     set -o pipefail
#     producer | grep -q PATTERN     # or grep -qF / -qE / -qxF
#
# `grep -q` exits as soon as it matches. The producer then writes into a closed
# pipe, receives EPIPE (exit 141), and `pipefail` propagates that as a FAILED
# pipeline — even though the match succeeded. Whether it fires depends on how
# fast the producer finishes, so the same expression passes on a small local
# output and fails on a slower CI runner.
#
# MEASURED IN THIS TRAIN: seven occurrences across the v1.228.8/.9 control
# plane. It made the control-enforcement gate report "no CI consumer" for gates
# that were correctly wired; made a DEP-5 control claim the ownership gate had
# regressed to string matching; and failed BC8 in CI while passing locally.
# Two sat inside CLASSIFICATION logic, where a flaky negative changes a policy
# disposition rather than just a test result — an EPIPE there would misclassify
# a generated artifact as not generated.
#
# PRECISION — this guard bans one shape, not `grep -q`:
#   flagged      producer | grep -q ...      in a file declaring pipefail
#   NOT flagged  grep -q PATTERN file        (no upstream, cannot EPIPE)
#   NOT flagged  producer | grep -q ...      in a file WITHOUT pipefail
# The fix is to count instead of short-circuit:
#   [[ "$(producer | grep -c PATTERN || true)" -gt 0 ]]
#
# SCOPE: MERGE-DECIDING GATES ONLY — derived from CI WIRING, not from a filename.
#
# v1.231.0 POPULATION CORRECTION. This previously scoped by the filename pattern
# `scripts/ci/check-*.sh`. That proxy is wrong: a script is merge-deciding because
# CI INVOKES IT, not because of how it was named. `scripts/ci/migration-coverage-gate.sh`
# has its own blocking workflow (.github/workflows/ci-migration-coverage.yml) and was
# NEVER SCANNED — and it carried exactly the forbidden form, in the fail-OPEN direction:
#     if [ -d "$d" ] && find "$d" -maxdepth 3 -name '*.go' -type f | grep -q .; then
#         fail_detail+="..."      # a MATCH means VIOLATION FOUND
# An EPIPE there empties fail_detail and the gate reports check_pass. The rule was
# right the whole time; the subject population was wrong.
#
# The population is now DERIVED: every scripts/ci/*.sh a workflow actually invokes,
# UNION the historical check-*.sh set so nothing previously covered is dropped.
#
# The shape was measured repo-wide first: 506 occurrences, 495 of them in test
# suites and 7 in gates (plus the 7 already fixed in the .8/.9 control plane).
# The two populations are not equivalent. A flaky assertion inside a test is
# noise; a flaky assertion inside a gate changes a MERGE decision or a policy
# disposition, which is a truth defect. Wiring this at 506 would block every
# change on pre-existing debt and would be scope expansion by another name.
#
# The 495 test-suite occurrences are RECORDED, not silently accepted — see
# OPEN_PIPEFAIL_EPIPE_TEST_SUITE_TAIL. They are not claimed to be safe.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# gate_population — the authority is CI WIRING, not a naming convention.
# Mechanically derived so it cannot drift into a hand-curated list, which would
# just replace one proxy with another.
gate_population() {
    {
        git ls-files 'scripts/ci/check-*.sh' 2>/dev/null
        grep -rhoE 'scripts/ci/[A-Za-z0-9._-]+\.sh' .github/workflows/ 2>/dev/null
    } | sort -u
}

# ⛔ v1.231.0 SECOND POPULATION CORRECTION (D4).
#
# The note above says "a flaky assertion inside a test is noise; a flaky
# assertion inside a gate changes a MERGE decision". That is FALSE for the
# shell tests the CI runner executes as BLOCKING evidence — their verdicts ARE
# merge decisions.
#
# MEASURED: cli/lib/nftban/tests/v131_pr_a_2_double_zero_sweep_test.sh carried
# exactly this shape in its A1/A2 scan arms. `grep -q` exited on a SUCCESSFUL
# match, `sed` took SIGPIPE, pipefail reported 141, and the arm read "offender
# found" as "no offender". Detection rate measured under load: 11/150 and 6/150
# — the guard was ~95% blind AND non-deterministic. It reported PASS 6/0 on a
# tree carrying FOUR real `grep -c ... || echo 0` sites (cmd_health_analysis.sh
# 535-536, cmd_support.sh 1475-1476), and intermittently went red and blocked
# an unrelated PR. One inverted assertion, both failure directions.
#
# POPULATION = EXECUTION AUTHORITY, same principle as the first correction:
# the tests the runner actually executes for a BLOCKING gate, read from the
# canonical authority index — not a filename pattern, not "every .sh".
test_corpus_population() {
    awk -F'\t' '$7=="ci-bash" || $7=="policy-gates" { print $2 }' \
        scripts/ci/test-authority-index.tsv 2>/dev/null | sort -u
}

# RATCHET, not amnesty. There are pre-existing sites in this corpus; wiring them
# all as hard failures would block every change on inherited debt (the reason
# the first correction stopped at the gate plane). So the test corpus is bound
# to a RECORDED INVENTORY of per-file counts:
#   count > recorded  -> FAIL: new timing-dependent assertion introduced
#   count < recorded  -> FAIL: inventory stale; regenerate so the gain is locked in
#   file not listed   -> FAIL: undeclared population change
# A decrease failing is deliberate — it is what stops the debt silently
# re-accumulating after someone fixes a file. Counts, not line numbers: line
# numbers drift on any edit and would locate the subject by position
# (see feedback_test_subject_location_and_complete_condition).
INVENTORY="scripts/ci/data/pipefail-epipe-test-corpus-inventory.tsv"

ALLOW="scripts/ci/data/pipefail-epipe-allowlist.txt"

fail=0
echo "== pipefail + 'grep -q' downstream of a pipe =="
while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    # only files that actually enable pipefail can be bitten
    grep -qE '^[[:space:]]*set[[:space:]]+-[A-Za-z]*o?[[:space:]]*pipefail|set[[:space:]]+-o[[:space:]]+pipefail' "$f" || continue
    while IFS=: read -r ln _; do
        [[ -z "$ln" ]] && continue
        line="$(sed -n "${ln}p" "$f")"
        # MENTION != CODE. The original test was `\#*`, which only matches a
        # comment at COLUMN 0; an INDENTED comment describing the forbidden form
        # was reported as the form itself. Strip leading whitespace first.
        _stripped="${line#"${line%%[![:space:]]*}"}"
        case "$_stripped" in \#*) continue ;; esac
        case "$line" in *"# epipe-ok"*) continue ;; esac
        [[ -f "$ALLOW" ]] && grep -qxF "$f:$ln" "$ALLOW" 2>/dev/null && continue
        printf 'FAIL [EPIPE_SHORTCIRCUIT] %s:%s — `grep -q` downstream of a pipe under pipefail; count instead: [[ "$(... | grep -c ... || true)" -gt 0 ]]\n' "$f" "$ln"
        fail=$((fail + 1))
        # `||` IS NOT A PIPE. `[ -z "$x" ] || grep -qF pat file` has no pipeline at
        # all — grep reads a FILE — yet the original pattern matched the second bar
        # of the OR operator. Require a SINGLE bar: not preceded and not followed by
        # another bar.
        #
        # A BUILTIN producer cannot be EPIPE'd in practice: echo/printf complete
        # before grep can exit, so the race the guard exists for cannot occur. Those
        # are exempted by mechanism, not by allowlist.
    done < <(grep -nE '[^|]\|[[:space:]]*grep[[:space:]]+-[a-zA-Z]*q' "$f" \
             | grep -vE '(^|[^A-Za-z_])(echo|printf)[^|]*\|[[:space:]]*grep' || true)
done < <(gate_population)

[[ $fail -eq 0 ]] && echo "  [OK] no timing-dependent grep -q pipelines in the control plane"
printf 'PIPEFAIL_EPIPE_SHORT_CIRCUIT_SITES = %d\n' "$fail"

# --- D4: executed-test corpus, bound to the recorded inventory ----------------
count_sites() {
    local f="$1" n=0 ln line _stripped
    grep -qE '^[[:space:]]*set[[:space:]]+-[A-Za-z]*o?[[:space:]]*pipefail|set[[:space:]]+-o[[:space:]]+pipefail' "$f" || { printf '0'; return; }
    while IFS=: read -r ln _; do
        [[ -z "$ln" ]] && continue
        line="$(sed -n "${ln}p" "$f")"
        _stripped="${line#"${line%%[![:space:]]*}"}"
        case "$_stripped" in \#*) continue ;; esac
        case "$line" in *"# epipe-ok"*) continue ;; esac
        n=$((n + 1))
    done < <(grep -nE '[^|]\|[[:space:]]*grep[[:space:]]+-[a-zA-Z]*q' "$f" \
             | grep -vE '(^|[^A-Za-z_])(echo|printf)[^|]*\|[[:space:]]*grep' || true)
    printf '%d' "$n"
}

echo "== executed-test corpus vs recorded inventory =="
corpus_fail=0
if [[ ! -f "$INVENTORY" ]]; then
    echo "FAIL [EPIPE_INVENTORY_MISSING] $INVENTORY absent — cannot ratchet an unmeasured population"
    corpus_fail=1
else
    declare -A RECORDED=()
    while IFS=$'\t' read -r _f _n; do
        [[ "$_f" == \#* || -z "$_f" ]] && continue
        RECORDED["$_f"]="$_n"
    done < "$INVENTORY"
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        n="$(count_sites "$f")"
        r="${RECORDED[$f]-}"
        if [[ -z "$r" ]]; then
            if [[ "$n" -gt 0 ]]; then
                printf 'FAIL [EPIPE_UNDECLARED] %s — %d timing-dependent site(s), not in the inventory\n' "$f" "$n"
                corpus_fail=$((corpus_fail + 1))
            fi
        elif [[ "$n" -gt "$r" ]]; then
            printf 'FAIL [EPIPE_NEW_DEBT] %s — %d site(s), inventory records %d\n' "$f" "$n" "$r"
            corpus_fail=$((corpus_fail + 1))
        elif [[ "$n" -lt "$r" ]]; then
            printf 'FAIL [EPIPE_INVENTORY_STALE] %s — %d site(s), inventory records %d; regenerate to lock the improvement in\n' "$f" "$n" "$r"
            corpus_fail=$((corpus_fail + 1))
        fi
    done < <(test_corpus_population)
    for f in "${!RECORDED[@]}"; do
        [[ -f "$f" ]] || { printf 'FAIL [EPIPE_INVENTORY_STALE] %s — recorded but no longer present; regenerate\n' "$f"; corpus_fail=$((corpus_fail + 1)); }
    done
fi
[[ $corpus_fail -eq 0 ]] && echo "  [OK] executed-test corpus matches the recorded inventory (no new timing-dependent assertions)"
printf 'PIPEFAIL_EPIPE_TEST_CORPUS_DEVIATIONS = %d\n' "$corpus_fail"

exit $(( (fail + corpus_fail) > 0 ? 1 : 0 ))
