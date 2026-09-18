#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# check-ai-coauthor-trailers.sh — v1.231.0 Lane E.
# PR-RANGE AI co-author trailer guard.
#
# WHY THIS EXISTS
# AI_ASSISTED_DEVELOPMENT.md has forbidden AI co-author trailers "going forward"
# since before v1.228.2. v1.228.5 ORDERED a per-PR identity control that included
# an "AI co-author trailer guard (PR range only)" and inversion N9. It was never
# built. The two shipped guards named "identity" — check-license-identity.sh and
# check-core-ownership-identity.sh — inspect FILES and contain zero references to
# `git log`, `%B` or `Co-Authored`. The declared control therefore governed a
# population that was never its subject: measured at 3c5d9286, 2734 of 4219
# commits carry an AI co-author trailer, 26 of them in the last 100.
#
# ⛔ THIS GUARD DOES NOT DEMAND A HISTORY REWRITE.
# The owner ruling is explicit and this guard is built around it: legacy trailers
# STAY, v1.228.2 STAYS published. The population is BASE..HEAD — the commits the
# pull request would INTRODUCE — and nothing else. A prohibited trailer one
# commit before BASE is not this gate's business; T3 in the test file is the
# control that proves it, so the gate can never silently become a rewrite demand.
#
# ⛔ TRAILER SYNTAX, NOT SUBSTRING.
# A commit message that discusses Claude, ChatGPT or OpenAI in prose is NOT a
# violation. Only a line whose KEY matches the co-author trailer token — case
# insensitive, leading whitespace and whitespace before the colon tolerated, as
# git itself tolerates — is inspected, and only its VALUE is matched.
#
# ⛔ NO INLINE IDENTITY LIST.
# Prohibited identities live in scripts/ci/data/ai-coauthor-trailer-registry.tsv
# and are derived from what AI_ASSISTED_DEVELOPMENT.md actually NAMES. The
# registry's header records the deliberately un-widened gap.
#
# EXIT CODES (a verdict is always named; there is no silent green)
#   0  PASS            population inspected, zero violations
#   0  NOT_APPLICABLE  event carries no PR range (named on stdout, never implied)
#   1  VIOLATION       >=1 prohibited trailer in BASE..HEAD, SHA + line reported
#   2  RANGE_UNDETERMINED / POPULATION_EMPTY / REGISTRY_INVALID / NOT_A_REPO /
#      SELFTEST_FAILED — fail loudly, never assume innocence
#
set -Eeuo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
REPO_ROOT_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

REPO="${NFTBAN_TRAILER_REPO:-$REPO_ROOT_DEFAULT}"
REGISTRY="${NFTBAN_TRAILER_REGISTRY:-}"
BASE_IN="${NFTBAN_TRAILER_BASE:-}"
HEAD_IN="${NFTBAN_TRAILER_HEAD:-}"
DEFAULT_BASE_REF="${NFTBAN_TRAILER_DEFAULT_BASE_REF:-origin/main}"
DO_SELFTEST=0

usage() {
    cat <<'USAGE'
usage: check-ai-coauthor-trailers.sh [--base REF] [--head REF] [--repo DIR]
                                     [--registry FILE] [--selftest]

  --base/--head   explicit range override (BASE..HEAD). Both or neither.
  --repo          repository to inspect (default: this checkout)
  --registry      declared identity registry (default: scripts/ci/data/...)
  --selftest      falsify the detector against throwaway git repositories

Range derivation when --base/--head are absent is printed as BASE_SOURCE=... on
every run. See the header for exit codes.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base)     BASE_IN="${2:-}"; shift 2 ;;
        --head)     HEAD_IN="${2:-}"; shift 2 ;;
        --repo)     REPO="${2:-}"; shift 2 ;;
        --registry) REGISTRY="${2:-}"; shift 2 ;;
        --selftest) DO_SELFTEST=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)          printf 'VERDICT=USAGE_ERROR unknown argument %q\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ -n "$REGISTRY" ]] || REGISTRY="$REPO_ROOT_DEFAULT/scripts/ci/data/ai-coauthor-trailer-registry.tsv"

say()  { printf '%s\n' "$*"; }
ok()   { printf '  [OK] %s\n' "$1"; }
bad()  { printf '  [FAIL] %s\n' "$1"; }
die()  { printf 'VERDICT=%s %s\n' "$1" "$2" >&2; exit 2; }

# --- registry ---------------------------------------------------------------
# Parsed into parallel arrays. A registry with zero prohibited rows is a BROKEN
# AUTHORITY, not a permissive one: it would pass everything forever.
declare -a PROHIBITED_PAT=() PROHIBITED_LABEL=() ALLOWED_PAT=() ALLOWED_LABEL=()

load_registry() {
    [[ -f "$REGISTRY" ]] || die REGISTRY_INVALID "registry not found: $REGISTRY"
    local class pattern label rest
    while IFS=$'\t' read -r class pattern label rest || [[ -n "${class:-}" ]]; do
        [[ -z "${class// /}" ]] && continue
        [[ "$class" == \#* ]] && continue
        case "$class" in
            prohibited-ai-identity)
                [[ -n "$pattern" ]] || die REGISTRY_INVALID "prohibited row with empty pattern in $REGISTRY"
                PROHIBITED_PAT+=("$pattern"); PROHIBITED_LABEL+=("${label:-$pattern}") ;;
            allowed-automation|allowed-human)
                [[ -n "$pattern" ]] || die REGISTRY_INVALID "allow row with empty pattern in $REGISTRY"
                ALLOWED_PAT+=("$pattern"); ALLOWED_LABEL+=("${label:-$pattern}") ;;
            *)  die REGISTRY_INVALID "unknown class '$class' in $REGISTRY" ;;
        esac
    done < "$REGISTRY"
    [[ ${#PROHIBITED_PAT[@]} -gt 0 ]] || \
        die REGISTRY_INVALID "registry declares ZERO prohibited identities — a gate that forbids nothing is not a gate ($REGISTRY)"
}

# --- range derivation -------------------------------------------------------
# Every path sets BASE_SOURCE so the run says HOW it decided, and an
# undeterminable PR range is an ERROR, never an assumption of innocence.
BASE=""; HEAD=""; BASE_SOURCE=""

git_in() { git -C "$REPO" "$@"; }

resolve() {  # resolve <rev> -> sha on stdout, rc!=0 if unresolvable
    git_in rev-parse --verify --quiet "${1}^{commit}" 2>/dev/null
}

event_json_field() {  # event_json_field pr_base_sha|push_before
    local ev="${GITHUB_EVENT_PATH:-}"
    [[ -n "$ev" && -r "$ev" ]] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$ev" "$1" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as fh:
        ev = json.load(fh)
except Exception:
    sys.exit(1)
what = sys.argv[2]
if what == "pr_base_sha":
    val = ((ev.get("pull_request") or {}).get("base") or {}).get("sha") or ""
elif what == "push_before":
    val = ev.get("before") or ""
    if val and set(val) <= {"0"}:
        val = ""
else:
    val = ""
if not val:
    sys.exit(1)
print(val)
PY
}

derive_range() {
    git_in rev-parse --git-dir >/dev/null 2>&1 || die NOT_A_REPO "not a git repository: $REPO"

    # 1 — explicit override (CI escape hatch, local use, and the test harness).
    if [[ -n "$BASE_IN" || -n "$HEAD_IN" ]]; then
        [[ -n "$BASE_IN" && -n "$HEAD_IN" ]] || die RANGE_UNDETERMINED "--base and --head must be given together"
        BASE="$(resolve "$BASE_IN")" || die RANGE_UNDETERMINED "base ref does not resolve to a commit: $BASE_IN"
        HEAD="$(resolve "$HEAD_IN")" || die RANGE_UNDETERMINED "head ref does not resolve to a commit: $HEAD_IN"
        BASE_SOURCE="explicit"
        return 0
    fi

    local ev="${GITHUB_EVENT_NAME:-}"
    case "$ev" in
        pull_request|pull_request_target)
            HEAD="$(resolve HEAD)" || die RANGE_UNDETERMINED "HEAD does not resolve in $REPO"
            local baseref=""
            if baseref="$(event_json_field pr_base_sha)" && [[ -n "$baseref" ]] && resolve "$baseref" >/dev/null; then
                BASE_SOURCE="pull_request:event.pull_request.base.sha"
            elif [[ -n "${GITHUB_BASE_REF:-}" ]] && resolve "origin/${GITHUB_BASE_REF}" >/dev/null; then
                baseref="origin/${GITHUB_BASE_REF}"; BASE_SOURCE="pull_request:origin/\$GITHUB_BASE_REF"
            elif [[ -n "${GITHUB_BASE_REF:-}" ]] && resolve "${GITHUB_BASE_REF}" >/dev/null; then
                baseref="${GITHUB_BASE_REF}"; BASE_SOURCE="pull_request:\$GITHUB_BASE_REF"
            else
                die RANGE_UNDETERMINED "pull_request event but the target branch is unresolvable (GITHUB_BASE_REF='${GITHUB_BASE_REF:-}'); a shallow checkout cannot answer this — the consuming workflow must use fetch-depth: 0"
            fi
            # The PR range is what the merge would INTRODUCE: merge-base, never
            # the moving tip of the target branch.
            BASE="$(git_in merge-base "$baseref" "$HEAD" 2>/dev/null)" || BASE=""
            [[ -n "$BASE" ]] || die RANGE_UNDETERMINED "no merge-base between '$baseref' and HEAD — the checkout has insufficient history (needs fetch-depth: 0)"
            ;;
        push)
            HEAD="$(resolve HEAD)" || die RANGE_UNDETERMINED "HEAD does not resolve in $REPO"
            local before=""
            if before="$(event_json_field push_before)" && resolve "$before" >/dev/null; then
                BASE="$(resolve "$before")"; BASE_SOURCE="push:event.before"
            else
                say "VERDICT=NOT_APPLICABLE event=push with no resolvable 'before' commit (branch creation, force-push, or shallow checkout)."
                say "  This guard governs the INCOMING PULL REQUEST RANGE. It is not a history auditor and deliberately"
                say "  reports NOT_APPLICABLE rather than inventing a population. Enforcement happens on pull_request."
                exit 0
            fi
            ;;
        "")
            # Local / manual run: compare against the declared integration branch.
            HEAD="$(resolve HEAD)" || die RANGE_UNDETERMINED "HEAD does not resolve in $REPO"
            resolve "$DEFAULT_BASE_REF" >/dev/null || \
                die RANGE_UNDETERMINED "no CI event and default base ref '$DEFAULT_BASE_REF' does not resolve — pass --base/--head explicitly"
            BASE="$(git_in merge-base "$DEFAULT_BASE_REF" "$HEAD" 2>/dev/null)" || BASE=""
            [[ -n "$BASE" ]] || die RANGE_UNDETERMINED "no merge-base between '$DEFAULT_BASE_REF' and HEAD"
            BASE_SOURCE="local:merge-base($DEFAULT_BASE_REF,HEAD)"
            ;;
        *)
            say "VERDICT=NOT_APPLICABLE event='$ev' carries no pull-request range."
            say "  Enforcement happens on the pull_request event; this is a named verdict, not a silent pass."
            exit 0
            ;;
    esac
}

# --- inspection -------------------------------------------------------------
# One line is a violation when BOTH hold:
#   (a) its KEY is the co-author trailer token under git's own tolerance, and
#   (b) its VALUE matches a prohibited identity and no allow row.
is_trailer_key() {
    local lower="${1,,}"
    [[ "$lower" =~ ^[[:space:]]*co-authored-by[[:space:]]*: ]]
}

trailer_value() {
    local v="${1#*:}"
    v="${v#"${v%%[![:space:]]*}"}"   # ltrim
    v="${v%"${v##*[![:space:]]}"}"   # rtrim
    printf '%s' "$v"
}

# grep -q downstream of a pipe under pipefail gives the producer EPIPE and the
# pipeline reports failure (v1.228.9 PR4). Here-strings, no pipes.
matches_any() {  # matches_any <value> <pattern...>  -> prints index, rc 0 on match
    local value="$1"; shift
    local i=0 pat
    for pat in "$@"; do
        if grep -qiE -- "$pat" <<<"$value"; then printf '%s' "$i"; return 0; fi
        i=$((i + 1))
    done
    return 1
}

run_inspection() {
    local range="$BASE..$HEAD"
    local commits
    commits="$(git_in rev-list --count "$range" 2>/dev/null)" || \
        die RANGE_UNDETERMINED "git rev-list failed for range '$range' — the range is malformed or the objects are absent"
    [[ "$commits" =~ ^[0-9]+$ ]] || die RANGE_UNDETERMINED "non-numeric commit count for range '$range'"

    say "ai-coauthor-trailer guard (v1.231.0)"
    say "  REPO         = $REPO"
    say "  BASE         = $BASE"
    say "  HEAD         = $HEAD"
    say "  BASE_SOURCE  = $BASE_SOURCE"
    say "  REGISTRY     = $REGISTRY (${#PROHIBITED_PAT[@]} prohibited, ${#ALLOWED_PAT[@]} allowed)"
    say "  POPULATION   = $commits commit(s) in $range"

    if [[ "$commits" -eq 0 ]]; then
        bad "POPULATION_EMPTY: BASE..HEAD contains no commits."
        say "  A pull request introduces at least one commit. An empty range means the range was derived"
        say "  wrongly (wrong base, shallow checkout, already-merged head) — the ONE condition under which a"
        say "  green result would be meaningless. Refusing to report PASS over an empty population."
        say "VERDICT=POPULATION_EMPTY"
        exit 2
    fi

    local violations=0 trailer_lines=0 allowed_lines=0 rec sha msg line val idx
    while IFS= read -r -d '' rec; do
        if [[ "$rec" == *$'\n'* ]]; then
            sha="${rec%%$'\n'*}"; msg="${rec#*$'\n'}"
        else
            sha="$rec"; msg=""
        fi
        [[ -n "$sha" ]] || continue
        while IFS= read -r line; do
            is_trailer_key "$line" || continue
            trailer_lines=$((trailer_lines + 1))
            val="$(trailer_value "$line")"
            if idx="$(matches_any "$val" "${ALLOWED_PAT[@]+"${ALLOWED_PAT[@]}"}")"; then
                allowed_lines=$((allowed_lines + 1))
                ok "${sha:0:12}: allowed automation identity '${ALLOWED_LABEL[$idx]}'"
                continue
            fi
            if idx="$(matches_any "$val" "${PROHIBITED_PAT[@]}")"; then
                violations=$((violations + 1))
                bad "PROHIBITED AI CO-AUTHOR TRAILER"
                printf '        commit  : %s\n' "$sha"
                printf '        subject : %s\n' "$(git_in log -1 --format=%s "$sha")"
                printf '        line    : %s\n' "$line"
                printf '        identity: %s (registry pattern: %s)\n' "${PROHIBITED_LABEL[$idx]}" "${PROHIBITED_PAT[$idx]}"
            fi
        done <<<"$msg"
    done < <(git_in log -z --reverse --format='%H%n%B' "$range")

    say "  TRAILER_LINES_SEEN = $trailer_lines (allowed: $allowed_lines)"
    if [[ "$violations" -gt 0 ]]; then
        say ""
        say "  $violations prohibited co-author trailer(s) in the INCOMING range."
        say "  Policy: AI_ASSISTED_DEVELOPMENT.md — commit metadata MUST NOT credit AI tools as authors."
        say "  Fix the INCOMING commits only (interactive rebase / amend on THIS branch)."
        say "  ⛔ Do NOT rewrite published history: commits before the enforcement commit keep their legacy"
        say "     trailers by owner ruling, and this gate never looks at them."
        say "VERDICT=VIOLATION violations=$violations"
        exit 1
    fi
    ok "no prohibited AI co-author trailer in $commits inspected commit(s)"
    say "VERDICT=PASS commits=$commits violations=0"
    exit 0
}

# --- selftest ---------------------------------------------------------------
# A gate whose detector has silently broken passes everything. This falsifies the
# detector against REAL git objects in a throwaway repository, never a synthetic
# string, and it is run by CI BEFORE the gate itself.
selftest() {
    local tmp rc out
    tmp="$(mktemp -d)" || die SELFTEST_FAILED "mktemp -d failed"
    trap 'rm -rf "$tmp"' EXIT
    local g=(git -C "$tmp" -c user.email=ci@example.invalid -c user.name=CI
             -c commit.gpgsign=false -c init.defaultBranch=main)
    "${g[@]}" init -q . >/dev/null 2>&1 || die SELFTEST_FAILED "git init failed in $tmp"
    printf 'a\n' > "$tmp/a"; "${g[@]}" add -A >/dev/null 2>&1
    "${g[@]}" commit -q -m "base commit" >/dev/null 2>&1 || die SELFTEST_FAILED "base commit failed"
    local base; base="$("${g[@]}" rev-parse HEAD)"

    printf 'b\n' > "$tmp/b"; "${g[@]}" add -A >/dev/null 2>&1
    "${g[@]}" commit -q -F - >/dev/null 2>&1 <<'MSG' || die SELFTEST_FAILED "clean commit failed"
clean commit

Discusses Claude, ChatGPT and OpenAI in ordinary prose only.
MSG
    local clean; clean="$("${g[@]}" rev-parse HEAD)"

    printf 'c\n' > "$tmp/c"; "${g[@]}" add -A >/dev/null 2>&1
    "${g[@]}" commit -q -F - >/dev/null 2>&1 <<'MSG' || die SELFTEST_FAILED "dirty commit failed"
dirty commit

  co-authored-by :   Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
    local dirty; dirty="$("${g[@]}" rev-parse HEAD)"

    "${g[@]}" commit -q --allow-empty -m "after the violation" >/dev/null 2>&1 \
        || die SELFTEST_FAILED "trailing commit failed"
    local after; after="$("${g[@]}" rev-parse HEAD)"

    local fails=0
    rc=0; out="$(bash "$SELF" --repo "$tmp" --registry "$REGISTRY" --base "$base" --head "$clean" 2>&1)" || rc=$?
    if [[ $rc -eq 0 ]]; then ok "selftest: prose-only range PASSES"
    else bad "selftest: prose-only range should PASS (rc=$rc)"; printf '%s\n' "$out"; fails=$((fails+1)); fi

    rc=0; out="$(bash "$SELF" --repo "$tmp" --registry "$REGISTRY" --base "$base" --head "$dirty" 2>&1)" || rc=$?
    if [[ $rc -eq 1 ]] && grep -qF "$dirty" <<<"$out"; then ok "selftest: violating range FAILS and names the SHA"
    else bad "selftest: violating range should FAIL(1) and name $dirty (rc=$rc)"; printf '%s\n' "$out"; fails=$((fails+1)); fi

    rc=0; out="$(bash "$SELF" --repo "$tmp" --registry "$REGISTRY" --base "$dirty" --head "$dirty" 2>&1)" || rc=$?
    if [[ $rc -eq 2 ]] && grep -qF "POPULATION_EMPTY" <<<"$out"; then ok "selftest: empty range is POPULATION_EMPTY, not a vacuous green"
    else bad "selftest: empty range should exit 2 POPULATION_EMPTY (rc=$rc)"; printf '%s\n' "$out"; fails=$((fails+1)); fi

    # The control that stops this gate becoming an accidental history-rewrite
    # demand: a prohibited trailer BEFORE base must not be reported.
    rc=0; out="$(bash "$SELF" --repo "$tmp" --registry "$REGISTRY" --base "$dirty" --head "$after" 2>&1)" || rc=$?
    if [[ $rc -eq 0 ]]; then ok "selftest: prohibited trailer BEFORE base is out of scope (no rewrite demand)"
    else bad "selftest: out-of-range historical trailer must not fail the gate (rc=$rc)"; printf '%s\n' "$out"; fails=$((fails+1)); fi

    if [[ $fails -gt 0 ]]; then say "VERDICT=SELFTEST_FAILED failures=$fails"; exit 2; fi
    say "VERDICT=SELFTEST_PASS"
    exit 0
}

load_registry
[[ "$DO_SELFTEST" -eq 1 ]] && selftest
derive_range
run_inspection
