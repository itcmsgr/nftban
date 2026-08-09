#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
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
# SCOPE: MERGE-DECIDING GATES ONLY (scripts/ci/check-*.sh).
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
        case "$line" in \#*|*"# epipe-ok"*) continue ;; esac
        [[ -f "$ALLOW" ]] && grep -qxF "$f:$ln" "$ALLOW" 2>/dev/null && continue
        printf 'FAIL [EPIPE_SHORTCIRCUIT] %s:%s — `grep -q` downstream of a pipe under pipefail; count instead: [[ "$(... | grep -c ... || true)" -gt 0 ]]\n' "$f" "$ln"
        fail=$((fail + 1))
    done < <(grep -nE '\|[[:space:]]*grep[[:space:]]+-[a-zA-Z]*q' "$f" || true)
done < <(git ls-files 'scripts/ci/check-*.sh' 2>/dev/null)

[[ $fail -eq 0 ]] && echo "  [OK] no timing-dependent grep -q pipelines in the control plane"
printf 'PIPEFAIL_EPIPE_SHORT_CIRCUIT_SITES = %d\n' "$fail"
exit $(( fail > 0 ? 1 : 0 ))
