#!/usr/bin/env bash
# =============================================================================
# NFTBan - PR-range AI co-author trailer guard test (v1.231.0 Lane E)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="ai_coauthor_trailer_guard_v1231_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-17"
# meta:description="v1.231.0 Lane E - falsifies scripts/ci/check-ai-coauthor-trailers.sh against REAL throwaway git repositories, never a synthetic string. AI_ASSISTED_DEVELOPMENT.md has forbidden AI co-author trailers going forward since before v1.228.2 and v1.228.5 ORDERED a PR-range guard as a required context; it was never built, and the two shipped guards named identity inspect FILES with zero references to git log, %B or Co-Authored. T1 a prohibited trailer inside BASE..HEAD FAILS. T2 ordinary prose naming Claude, ChatGPT and OpenAI, plus allowlisted github-actions and dependabot trailers, PASSES - the subject is git trailer syntax, not the word. T3 a prohibited trailer OUTSIDE BASE..HEAD PASSES, with a declared inversion proving the same commit FAILS when it is inside the range: this is the control that stops the gate becoming an accidental history-rewrite demand, because the owner ruling is that legacy trailers stay. T4 a mixed range FAILS and names the violating SHA while not naming the clean one. T5 case and whitespace variants git trailer syntax permits are still detected. T6 empty range, unresolvable base, half-specified range and a registry declaring zero prohibited identities each produce an explicit exit-2 verdict, never a vacuous green. T7 EXECUTION AUTHORITY - the guard is actually selected by the Policy Gates job of ci-architecture.yml on the pull_request event, with fetch-depth 0, because CONTROL_IMPLEMENTATION is not CONTROL_ENFORCEMENT. Hermetic: fixtures are built under TMPDIR, nothing is created inside the checkout, no host or systemd state is touched."
# meta:input="scripts/ci/check-ai-coauthor-trailers.sh, scripts/ci/data/ai-coauthor-trailer-registry.tsv, .github/workflows/ci-architecture.yml"
# meta:output="PASS/FAIL per assertion; exit 1 on any failure; exit 3 NOT_EXECUTED when a precondition cannot be constructed"
# meta:depends="bash,git,mktemp,grep,printf"
# meta:ta.id="ai_coauthor_trailer_guard_v1231_test"
# meta:ta.owner="cross-cutting"
# meta:ta.module="commit-identity"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="policy-gates"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:inventory.files="scripts/ci/check-ai-coauthor-trailers.sh,scripts/ci/data/ai-coauthor-trailer-registry.tsv,.github/workflows/ci-architecture.yml"
# meta:inventory.binaries="bash,git,mktemp,grep,printf"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
#
# HARNESS CONTRACT
#   - errexit is deliberately NOT armed: the subject is expected to exit 1 and 2,
#     and a bare call under errexit would kill the run instead of reporting it.
#     Every invocation captures rc explicitly (`rc=0; out=$(...) || rc=$?`).
#   - The subject always runs as a REAL CHILD (`bash "$GUARD" ...`), so its own
#     `set -Eeuo pipefail` stays armed inside it.
#   - PASS / FAIL / NOT_EXECUTED are distinct. A precondition that cannot be
#     constructed exits 3 with a named diagnostic: never FAIL, never PASS.
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
GUARD="$ROOT/scripts/ci/check-ai-coauthor-trailers.sh"
REGISTRY="$ROOT/scripts/ci/data/ai-coauthor-trailer-registry.tsv"
WORKFLOW="$ROOT/.github/workflows/ci-architecture.yml"
POLICY="$ROOT/AI_ASSISTED_DEVELOPMENT.md"

FAILS=0
ok()  { printf '  [PASS] %s\n' "$1"; }
bad() { printf '  [FAIL] %s\n' "$1"; FAILS=$((FAILS+1)); }
inf() { printf '  [INFO] %s\n' "$1"; }
notexec() {
    printf '  [NOT_EXECUTED] %s\n' "$1"
    printf 'VERDICT=NOT_EXECUTED %s\n' "$1"
    exit 3
}

# --- preconditions ----------------------------------------------------------
command -v git >/dev/null 2>&1 || notexec "git is absent - the fixture population cannot be constructed"
[[ -x "$GUARD" ]]     || notexec "subject not present or not executable: $GUARD"
[[ -f "$REGISTRY" ]]  || notexec "declared registry absent: $REGISTRY"
[[ -f "$WORKFLOW" ]]  || notexec "consumer workflow absent: $WORKFLOW"

FIX="$(mktemp -d)" || notexec "mktemp -d failed - no place to build the fixture repository"
TMPREG="$(mktemp -d)" || notexec "mktemp -d failed - no place to build the inverted registry"
cleanup() { rm -rf "$FIX" "$TMPREG"; }
trap cleanup EXIT

# ⛔ git init happens in TMPDIR, never inside the checkout.
G=(git -C "$FIX" -c user.email=lanee@example.invalid -c user.name="Lane E Fixture"
   -c commit.gpgsign=false -c init.defaultBranch=main)

"${G[@]}" init -q . >/dev/null 2>&1 || notexec "git init failed in $FIX"

mk() {  # mk <file> ; message on stdin -> echoes the new sha
    printf '%s\n' "$1" > "$FIX/$1"
    "${G[@]}" add -A >/dev/null 2>&1 || return 1
    "${G[@]}" commit -q -F - >/dev/null 2>&1 || return 1
    "${G[@]}" rev-parse HEAD
}

C0="$(mk f0 <<'MSG'
base commit
MSG
)" || notexec "fixture commit C0 failed"

# C1 - a LEGACY violation. It exists to be left alone by T3.
C1="$(mk f1 <<'MSG'
legacy commit that predates enforcement

Co-Authored-By: Claude <noreply@anthropic.com>
MSG
)" || notexec "fixture commit C1 failed"

# C2 - prose only. The words appear; no trailer does.
C2="$(mk f2 <<'MSG'
prose commit

This message discusses Claude, ChatGPT and OpenAI at length, and even mentions
that Anthropic publishes a model. None of that is a co-authorship claim, and a
substring detector would wrongly fail this commit.
MSG
)" || notexec "fixture commit C2 failed"

# C3 - real automation identities. Trailers, but not authorship claims by an AI tool.
C3="$(mk f3 <<'MSG'
automation commit

Co-authored-by: github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>
Co-authored-by: dependabot[bot] <49699333+dependabot[bot]@users.noreply.github.com>
MSG
)" || notexec "fixture commit C3 failed"

# C4 - the canonical violation.
C4="$(mk f4 <<'MSG'
violating commit

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
)" || notexec "fixture commit C4 failed"

# C5 - clean, so T4 has something that must NOT be named.
C5="$(mk f5 <<'MSG'
clean commit
MSG
)" || notexec "fixture commit C5 failed"

# C6 - case + whitespace variants git trailer syntax tolerates.
C6="$(mk f6 <<'MSG'
variant commit

   co-authored-by :   ChatGPT <chatgpt@openai.com>
MSG
)" || notexec "fixture commit C6 failed"

for v in C0 C1 C2 C3 C4 C5 C6; do
    [[ -n "${!v}" ]] || notexec "fixture sha $v is empty - the population was not constructed"
done
inf "fixture repo $FIX  C0=${C0:0:8} C1=${C1:0:8} C2=${C2:0:8} C3=${C3:0:8} C4=${C4:0:8} C5=${C5:0:8} C6=${C6:0:8}"

run_guard() {  # run_guard <base> <head> [extra...] ; sets RC and OUT
    RC=0
    OUT="$(bash "$GUARD" --repo "$FIX" --registry "$REGISTRY" --base "$1" --head "$2" "${@:3}" 2>&1)" || RC=$?
}

# --- T1: prohibited trailer INSIDE the range -> FAIL -------------------------
run_guard "$C3" "$C4"
if [[ $RC -eq 1 ]]; then ok "T1 prohibited trailer in BASE..HEAD fails the guard (rc=1)"
else bad "T1 expected rc=1, got rc=$RC"; printf '%s\n' "$OUT"; fi
if grep -qF "$C4" <<<"$OUT"; then ok "T1 the offending commit SHA is reported"
else bad "T1 offending SHA $C4 not reported"; printf '%s\n' "$OUT"; fi
if grep -qF "Co-Authored-By: Claude Opus 5" <<<"$OUT"; then ok "T1 the offending LINE is reported, not just a verdict"
else bad "T1 offending line not reported"; printf '%s\n' "$OUT"; fi

# --- T2: prose + allowlisted automation -> PASS ------------------------------
run_guard "$C1" "$C3"
if [[ $RC -eq 0 ]]; then ok "T2 prose naming Claude/ChatGPT/OpenAI with no trailer passes (rc=0)"
else bad "T2 expected rc=0, got rc=$RC"; printf '%s\n' "$OUT"; fi
if grep -qF "VERDICT=PASS" <<<"$OUT"; then ok "T2 verdict is explicitly PASS"
else bad "T2 no explicit PASS verdict"; printf '%s\n' "$OUT"; fi
# The same range proves the allowlist: C3 carries two real trailers that must be exempt.
if grep -qF "github-actions[bot]" <<<"$OUT" && grep -qF "dependabot[bot]" <<<"$OUT"; then
    ok "T2 github-actions[bot] and dependabot[bot] are exempted BY NAME (allowlist reached, not ignored)"
else bad "T2 allowlisted automation identities were not reported as exempt"; printf '%s\n' "$OUT"; fi
if grep -qE 'TRAILER_LINES_SEEN = 2 \(allowed: 2\)' <<<"$OUT"; then
    ok "T2 both trailer lines were actually PARSED (2 seen, 2 allowed) - not skipped unseen"
else bad "T2 trailer accounting did not show 2 seen / 2 allowed"; printf '%s\n' "$OUT"; fi

# --- T3: prohibited trailer OUTSIDE the range -> PASS ------------------------
# DECLARED INVERSION first: prove C1 really is a violating commit, so the PASS
# below cannot be explained by a fixture that never violated anything.
run_guard "$C0" "$C1"
if [[ $RC -eq 1 ]]; then ok "T3 inversion: the historical commit C1 DOES violate when it is inside the range"
else bad "T3 inversion failed - C1 is not a violating fixture (rc=$RC); the T3 control below would be meaningless"; printf '%s\n' "$OUT"; fi
run_guard "$C1" "$C3"
if [[ $RC -eq 0 ]]; then ok "T3 the same violation OUTSIDE BASE..HEAD does not fail the guard - no history-rewrite demand"
else bad "T3 expected rc=0 for an out-of-range historical trailer, got rc=$RC"; printf '%s\n' "$OUT"; fi
# C1 legitimately appears ONCE, as the BASE boundary of the range. What must
# never happen is C1 being REPORTED AS A SUBJECT, so the assertion is about the
# violation record, not about the string.
if grep -qE "^[[:space:]]*commit[[:space:]]*:[[:space:]]*$C1\$" <<<"$OUT"; then
    bad "T3 the guard reported an out-of-range commit as a violation - population leak into history"
else ok "T3 the out-of-range commit is never reported as a violation subject"; fi
if grep -qE "^[[:space:]]*BASE[[:space:]]*=[[:space:]]*$C1\$" <<<"$OUT"; then
    ok "T3 C1 appears only as the declared BASE boundary - the range provably starts after it"
else bad "T3 the range did not start at C1; the control is not measuring what it claims"; printf '%s\n' "$OUT"; fi

# --- T4: mixed range -> FAIL and name the violator ---------------------------
run_guard "$C4" "$C6"   # range = C5 (clean) + C6 (violating)
if [[ $RC -eq 1 ]]; then ok "T4 mixed range fails (rc=1)"
else bad "T4 expected rc=1, got rc=$RC"; printf '%s\n' "$OUT"; fi
if grep -qF "$C6" <<<"$OUT"; then ok "T4 names the violating SHA ${C6:0:8}"
else bad "T4 did not name the violating SHA $C6"; printf '%s\n' "$OUT"; fi
if grep -qF "$C5" <<<"$OUT"; then bad "T4 named the CLEAN commit $C5 as well - the report is not specific"
else ok "T4 does not name the clean commit"; fi
if grep -qE 'POPULATION   = 2 commit' <<<"$OUT"; then ok "T4 the asserted population is exactly the 2 commits of the range"
else bad "T4 population was not the expected 2 commits"; printf '%s\n' "$OUT"; fi

# --- T5: case / whitespace variants ------------------------------------------
run_guard "$C5" "$C6"
if [[ $RC -eq 1 ]]; then ok "T5 lowercase key + leading spaces + space before the colon is still detected"
else bad "T5 variant trailer was NOT detected (rc=$RC) - detector is substring-shaped, not trailer-shaped"; printf '%s\n' "$OUT"; fi
if grep -qF "co-authored-by :   ChatGPT" <<<"$OUT"; then ok "T5 the variant line itself is echoed back"
else bad "T5 variant line not echoed"; printf '%s\n' "$OUT"; fi

# --- T6: empty / malformed range and a broken registry -> explicit verdicts --
run_guard "$C6" "$C6"
if [[ $RC -eq 2 ]] && grep -qF "VERDICT=POPULATION_EMPTY" <<<"$OUT"; then
    ok "T6a empty range is POPULATION_EMPTY (exit 2), never a vacuous green"
else bad "T6a expected exit 2 + POPULATION_EMPTY, got rc=$RC"; printf '%s\n' "$OUT"; fi

run_guard "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$C6"
if [[ $RC -eq 2 ]] && grep -qF "VERDICT=RANGE_UNDETERMINED" <<<"$OUT"; then
    ok "T6b unresolvable base is RANGE_UNDETERMINED (exit 2)"
else bad "T6b expected exit 2 + RANGE_UNDETERMINED, got rc=$RC"; printf '%s\n' "$OUT"; fi

RC=0; OUT="$(bash "$GUARD" --repo "$FIX" --registry "$REGISTRY" --base "$C5" 2>&1)" || RC=$?
if [[ $RC -eq 2 ]] && grep -qF "VERDICT=RANGE_UNDETERMINED" <<<"$OUT"; then
    ok "T6c half-specified range (--base without --head) is RANGE_UNDETERMINED (exit 2)"
else bad "T6c expected exit 2 + RANGE_UNDETERMINED, got rc=$RC"; printf '%s\n' "$OUT"; fi

# A registry that declares nothing would pass every commit forever. That is the
# failure mode this repo keeps meeting: a control whose subject is empty.
printf '# only comments, zero declared identities\n' > "$TMPREG/empty.tsv"
RC=0; OUT="$(bash "$GUARD" --repo "$FIX" --registry "$TMPREG/empty.tsv" --base "$C5" --head "$C6" 2>&1)" || RC=$?
if [[ $RC -eq 2 ]] && grep -qF "VERDICT=REGISTRY_INVALID" <<<"$OUT"; then
    ok "T6d a registry with ZERO prohibited identities is REGISTRY_INVALID, not a permissive pass"
else bad "T6d expected exit 2 + REGISTRY_INVALID, got rc=$RC"; printf '%s\n' "$OUT"; fi

# --- T7: EXECUTION AUTHORITY -------------------------------------------------
# CONTROL_IMPLEMENTATION is not CONTROL_ENFORCEMENT. The v1.228.8 parser gate was
# called BLOCKING for three PRs with no workflow consumer. Assert SELECTION.
# Comments are stripped first: a mention in prose is not an invocation.
wf_code() { grep -vE '^[[:space:]]*#' "$WORKFLOW"; }
cnt() { local n; n="$(grep -cF -- "$1" <<<"$2")" || n=0; printf '%s' "$n"; }

WF_CODE="$(wf_code)"
if [[ "$(cnt 'scripts/ci/check-ai-coauthor-trailers.sh' "$WF_CODE")" -gt 0 ]]; then
    ok "T7a the guard is INVOKED by ci-architecture.yml (non-comment line)"
else bad "T7a NO CI CONSUMER - nothing in ci-architecture.yml runs the guard"; fi

if [[ "$(cnt 'check-ai-coauthor-trailers.sh --selftest' "$WF_CODE")" -gt 0 ]]; then
    ok "T7b CI runs the guard's --selftest before the gate (a blind detector would pass everything)"
else bad "T7b the workflow runs the gate but not its selftest"; fi

if grep -qE '^[[:space:]]*pull_request:[[:space:]]*$' "$WORKFLOW"; then
    ok "T7c the consuming workflow triggers on pull_request - the event that carries the range"
else bad "T7c ci-architecture.yml does not declare a pull_request trigger"; fi

if grep -qE '^[[:space:]]*name:[[:space:]]*Policy Gates[[:space:]]*$' "$WORKFLOW"; then
    ok "T7d the consumer job 'Policy Gates' is declared in the workflow"
else bad "T7d consumer job 'Policy Gates' not found - the required context does not exist under that name"; fi

if [[ "$(cnt 'fetch-depth: 0' "$WF_CODE")" -gt 0 ]]; then
    ok "T7e the consumer checks out full history (fetch-depth: 0) - merge-base is computable"
else bad "T7e no fetch-depth: 0 in the consumer; a shallow checkout makes BASE underivable and the gate would exit 2 on every PR"; fi

if grep -qE '^[[:space:]]*- name:.*AI co-author trailer' "$WORKFLOW"; then
    ok "T7f the invoking step carries a named, reviewable step name"
else bad "T7f no named workflow step for the AI co-author trailer gate"; fi

# The policy text is the registry's authority. If the policy surface disappears,
# the registry is orphaned and the gate is enforcing an unsourced rule.
if [[ -f "$POLICY" ]] && grep -qiE 'MUST NOT.*credit AI tools as authors' "$POLICY"; then
    ok "T7g the policy clause the registry is derived from is still present in AI_ASSISTED_DEVELOPMENT.md"
else bad "T7g the policy clause is missing - the registry has no authority to derive from"; fi

# --- verdict -----------------------------------------------------------------
printf '\n'
if [[ $FAILS -eq 0 ]]; then
    printf 'VERDICT=PASS ai_coauthor_trailer_guard_v1231_test: all assertions passed\n'
    exit 0
fi
printf 'VERDICT=FAIL ai_coauthor_trailer_guard_v1231_test: %d assertion(s) failed\n' "$FAILS"
exit 1
