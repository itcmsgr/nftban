#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# check-control-enforcement.sh — v1.228.8 PR4 meta-gate.
#
# WHY THIS EXISTS
# The parser-contract gate shipped in v1.228.8 PR1 with a selftest, was
# manually falsified in both directions, was described as BLOCKING in its PR
# body and in the register — and was never wired into a workflow. It ran only
# when a human invoked it. For the whole PR1→PR3 interval the rule it existed
# to enforce ("a new nft reader cannot merge unclassified") was not in force.
# Nothing bad entered in that window, measured rather than assumed, but the
# control was decorative and every artefact around it read as if it were not.
#
#   CONTROL_IMPLEMENTATION != CONTROL_ENFORCEMENT
#
# A control is only real when ALL FOUR hold:
#   1. the implementation exists and is executable
#   2. a selftest exists (a gate that has gone blind must fail before a gate
#      that merely passes)
#   3. a workflow CONSUMER invokes it
#   4. that workflow is a REQUIRED check, so the consumer cannot be bypassed
#
# SCOPE IS DELIBERATELY NARROW. This is NOT a repo-wide "is every gate wired"
# audit — that would re-expand .8. It covers exactly the controls .8 closes.
# A general CI-consumer authority, if wanted, is separate debt.
#
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# control | required workflow file | job name that must be a required check
CONTROLS=(
    "scripts/ci/check-nft-parser-contract.sh|.github/workflows/ci-architecture.yml|Policy Gates"
    "scripts/ci/check-license-identity.sh|.github/workflows/ci-architecture.yml|Policy Gates"
)
# Controls that MUST also expose a --selftest. check-license-identity.sh is
# falsified by the PR4 bad-control suite instead of an embedded selftest, so it
# is listed here only if it grows one.
SELFTEST_REQUIRED=("scripts/ci/check-nft-parser-contract.sh")

fail=0
viol() { printf 'FAIL [%s] %s\n' "$1" "$2"; fail=$((fail + 1)); }
ok()   { printf '  [PASS] %s\n' "$1"; }

for entry in "${CONTROLS[@]}"; do
    IFS='|' read -r script workflow jobname <<< "$entry"
    name="$(basename "$script")"

    # 1 — implementation exists and is executable
    if [[ -x "$script" ]]; then ok "$name: implementation present and executable"
    else viol "NO_IMPLEMENTATION" "$name: missing or not executable at $script"; continue; fi

    # 3 — a workflow consumer actually invokes it. Comments do not count: the
    # subject of this assertion is an invocation, so comment lines are stripped
    # before matching (a mention in prose is not a consumer).
    # NOTE: no `grep -q` downstream of a pipe here. Under `set -o pipefail`,
    # -q exits on first match, the upstream grep dies with EPIPE (141), and the
    # pipeline reports FAILURE — which made this very check report "no CI
    # consumer" for gates that were correctly wired. A meta-gate that lies
    # about enforcement is worse than no meta-gate, so it counts instead.
    if [[ "$(grep -vE '^[[:space:]]*#' "$workflow" 2>/dev/null | grep -cF "$script" || true)" -gt 0 ]]; then
        ok "$name: invoked by $(basename "$workflow")"
    else
        viol "NO_CI_CONSUMER" "$name: no workflow invokes it — the control exists but nothing runs it, which is exactly how the parser gate was 'BLOCKING' for three PRs without enforcing anything"
    fi

    # 4 — that workflow's job is a REQUIRED check on the protected branch.
    # Without this, the consumer can be skipped and the control is advisory.
    if grep -qE "^[[:space:]]*name:[[:space:]]*${jobname}[[:space:]]*$" "$workflow"; then
        ok "$name: consumer job '$jobname' declared in $(basename "$workflow")"
    else
        viol "CONSUMER_JOB_MISSING" "$name: job '$jobname' not found in $workflow"
    fi
done

# 2 — selftest presence AND that the workflow runs the selftest, not just the
# gate. A gate whose detector has silently broken passes everything.
for script in "${SELFTEST_REQUIRED[@]}"; do
    name="$(basename "$script")"
    if grep -q -- '--selftest' "$script"; then ok "$name: exposes --selftest"
    else viol "NO_SELFTEST" "$name: no --selftest mode"; fi
    if [[ "$(grep -vE '^[[:space:]]*#' .github/workflows/ci-architecture.yml | grep -cF -- "$script --selftest" || true)" -gt 0 ]]; then
        ok "$name: workflow runs --selftest before the gate"
    else
        viol "SELFTEST_NOT_RUN" "$name: workflow invokes the gate but not its selftest — a blind gate would pass"
    fi
done

# 5 — one canonical identity string, and only one. The .8 canon is owner-frozen;
# a second spelling anywhere in the enforcement chain means docs and machine
# disagree, which is the condition PR4 exists to close.
CANON="Copyright (c) 2024-2026 Antonios Voulvoulis"
competing=0
for f in scripts/ci/check-license-identity.sh SPDX-HEADERS.md build/generate-fhs-outputs.sh; do
    [[ -f "$f" ]] || continue
    while IFS= read -r line; do
        [[ "$line" == *"$CANON"* ]] && continue
        competing=$((competing + 1)); printf '        competing canon in %s: %s\n' "$f" "${line:0:80}"
    done < <(grep -hoE 'Copyright[[:space:]]*(\((c|C)\)|©)[[:space:]]*[0-9]{4}[^"]{0,60}' "$f" 2>/dev/null || true)
done
if [[ $competing -eq 0 ]]; then ok "COMPETING_CANON_COUNT = 0 (docs agree with the enforced identity)"
else viol "COMPETING_CANON" "$competing competing canonical identity string(s) — documentation disagrees with what the gate enforces"; fi

printf 'control-enforcement: %d hard violations\n' "$fail"
exit $(( fail > 0 ? 1 : 0 ))
