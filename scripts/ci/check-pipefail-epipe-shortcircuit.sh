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
exit $(( fail > 0 ? 1 : 0 ))
