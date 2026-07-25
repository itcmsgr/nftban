#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# meta:name="check-repo-authority_test"
# meta:type="script"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Hermetic tests for check-repo-authority.sh. Builds throwaway git repositories and proves each authority check fires on its own known-bad input: the ancestor-repository walk-up trap, borrowed alternates, wrong origin, missing/undescended history-epoch anchor, a surviving pre-rewrite commit, stale local main, shallow clone, tag divergence, and undeterminable-remote refusal. Every negative asserts BOTH the exit code and the specific diagnostic, so a check that stopped matching cannot pass silently."
# meta:inventory.files=""
# meta:inventory.binaries="bash, git, mktemp"
# meta:inventory.env_vars="NFTBAN_AUTHORITY_ROOT, NFTBAN_CANONICAL_ORIGIN, NFTBAN_HISTORY_EPOCH_ANCHOR, NFTBAN_PREREWRITE_FORBIDDEN_COMMIT"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
# TEST HARNESS: deliberately runs cases that exit non-zero and records PASS/FAIL
# rather than aborting. Every invocation is guarded (`|| rc=$?`), so errexit
# still catches real harness bugs while expected failures are captured.
#
# NOTE ON SCOPE: no assertion may run inside a ( subshell ) — the PASS/FAIL
# counters would be incremented in a child and discarded, letting a failing case
# report success. Per-case environment is passed explicitly via RUNENV instead.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT="$HERE/../check-repo-authority.sh"
PASS=0; FAIL=0
ok(){   echo "[PASS] $1"; PASS=$((PASS+1)); }
bad(){  echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

WORKDIRS=()
cleanup(){ local d; for d in "${WORKDIRS[@]:-}"; do [[ -n "$d" && -d "$d" ]] && rm -rf "$d"; done; }
trap cleanup EXIT

export GIT_AUTHOR_NAME="test" GIT_AUTHOR_EMAIL="test@example.invalid"
export GIT_COMMITTER_NAME="test" GIT_COMMITTER_EMAIL="test@example.invalid"

# mkfixture → echoes a base dir containing remote.git (bare, HEAD=main) and
# work/ with: anchor commit, head commit, tag v1.0.0, main pushed, origin fetched.
mkfixture() {
    local base; base="$(mktemp -d)"
    WORKDIRS+=("$base")
    # -b main on the BARE repo matters: a bare repo whose HEAD points at a
    # non-existent 'master' clones as "empty", which silently invalidates any
    # fixture built by cloning it.
    git init -q --bare -b main "$base/remote.git"
    git init -q -b main "$base/work"
    (
        cd "$base/work"
        git config commit.gpgsign false
        echo anchor > a.txt; git add a.txt; git commit -qm "anchor commit"
        echo head   > b.txt; git add b.txt; git commit -qm "head commit"
        git tag v1.0.0
        git remote add origin "$base/remote.git"
        git push -q origin main --tags
        git fetch -q origin
    )
    echo "$base"
}

# Normalised origin the guard will compute for a fixture's remote.
expected_origin(){ echo "$1/remote"; }

# RUNENV holds VAR=VALUE pairs for the next run; set_env resets it to the
# standard four for a fixture, callers then override individual entries.
RUNENV=()
set_env() {  # set_env <base> <anchor_sha>
    RUNENV=(
        "NFTBAN_AUTHORITY_ROOT=$1/work"
        "NFTBAN_CANONICAL_ORIGIN=$(expected_origin "$1")"
        "NFTBAN_HISTORY_EPOCH_ANCHOR=$2"
        "NFTBAN_PREREWRITE_FORBIDDEN_COMMIT=0000000000000000000000000000000000000000"
    )
}

# run <expected_rc> <needle> <label> [args…] — asserts exit code AND diagnostic.
run() {
    local want="$1" needle="$2" label="$3"; shift 3
    local out rc=0
    out="$(env "${RUNENV[@]}" "$SCRIPT" "$@" 2>&1)" || rc=$?
    if [[ "$rc" -ne "$want" ]]; then
        bad "$label (exit $rc, wanted $want)"
        printf '%s\n' "$out" | sed 's/^/       /' | tail -8
        return 0
    fi
    if [[ -n "$needle" ]] && ! grep -qF -- "$needle" <<<"$out"; then
        bad "$label (exit $want correct, but diagnostic missing: '$needle')"
        printf '%s\n' "$out" | sed 's/^/       /' | tail -8
        return 0
    fi
    ok "$label"
}

echo "=== check-repo-authority.sh — hermetic authority tests ==="

# --- 1. POSITIVE -------------------------------------------------------------
B="$(mkfixture)"; B_ANCHOR="$(git -C "$B/work" rev-parse HEAD~1)"
set_env "$B" "$B_ANCHOR"
run 0 "RESULT: PASS" "positive: well-formed repository passes (with remote)"    --mode local
run 0 "RESULT: PASS" "positive: well-formed repository passes (--skip-network)" --mode local --skip-network

# --- 2. ANCESTOR-WALK TRAP ---------------------------------------------------
# A child directory with no .git of its own resolves, via git's upward walk, to
# the PARENT repository. `rev-parse --git-dir` succeeds there; identity must not.
B2="$(mkfixture)"
mkdir -p "$B2/work/child/.claude"
: > "$B2/work/child/.claude/settings.local.json"
set_env "$B2" "$(git -C "$B2/work" rev-parse HEAD~1)"
RUNENV[0]="NFTBAN_AUTHORITY_ROOT=$B2/work/child"
run 1 "repository identity mismatch" "ancestor trap: child dir with no .git is rejected" \
    --mode local --skip-network
if git -C "$B2/work/child" rev-parse --git-dir >/dev/null 2>&1; then
    ok "ancestor trap: naive 'rev-parse --git-dir' does succeed (guard must not rely on it)"
else
    bad "ancestor trap: fixture invalid — rev-parse --git-dir did not walk upward"
fi

# --- 3. BORROWED OBJECT STORE ------------------------------------------------
B3="$(mkfixture)"
mkdir -p "$B3/work/.git/objects/info"
echo "$B/work/.git/objects" > "$B3/work/.git/objects/info/alternates"
set_env "$B3" "$(git -C "$B3/work" rev-parse HEAD~1)"
run 1 "borrowed object store" "alternates: borrowed object store is rejected" \
    --mode local --skip-network

# --- 4. WRONG ORIGIN ---------------------------------------------------------
set_env "$B" "$B_ANCHOR"
RUNENV[1]="NFTBAN_CANONICAL_ORIGIN=github.com/someone-else/not-nftban"
run 1 "origin is not the canonical repository" "origin: non-canonical remote is rejected" \
    --mode local --skip-network
# A fork contributor must still be able to commit: origin is downgraded to a
# notice while every other authority check stays blocking.
run 0 "accepted under --allow-fork-origin" "origin: --allow-fork-origin downgrades a fork remote" \
    --mode local --skip-network --allow-fork-origin
# …but a fork origin must NEVER be accepted by a CI or release gate.
run 2 "refused in --mode ci" "refusal: --allow-fork-origin is refused in CI mode" \
    --mode ci --allow-fork-origin
# The downgrade must be scoped to A3 only — a fork clone on the wrong epoch still fails.
set_env "$B" "$B_ANCHOR"
RUNENV[1]="NFTBAN_CANONICAL_ORIGIN=github.com/someone-else/not-nftban"
RUNENV[3]="NFTBAN_PREREWRITE_FORBIDDEN_COMMIT=$(git -C "$B/work" rev-parse HEAD)"
run 1 "PRE-REWRITE commit is present" \
    "origin: --allow-fork-origin does NOT excuse a wrong history epoch" \
    --mode local --skip-network --allow-fork-origin

# --- 5. HISTORY EPOCH --------------------------------------------------------
set_env "$B" "$B_ANCHOR"
RUNENV[2]="NFTBAN_HISTORY_EPOCH_ANCHOR=1111111111111111111111111111111111111111"
run 1 "epoch anchor is absent" "epoch: missing post-rewrite anchor is rejected" \
    --mode local --skip-network

set_env "$B" "$B_ANCHOR"
RUNENV[3]="NFTBAN_PREREWRITE_FORBIDDEN_COMMIT=$(git -C "$B/work" rev-parse HEAD)"
run 1 "PRE-REWRITE commit is present" "epoch: surviving pre-rewrite commit is rejected" \
    --mode local --skip-network

# HEAD must DESCEND from the anchor — an unrelated (orphan) anchor must fail.
B5="$(mkfixture)"
git -C "$B5/work" checkout -q --orphan sidelane
git -C "$B5/work" rm -qrf . >/dev/null 2>&1 || true
echo side > "$B5/work/s.txt"
git -C "$B5/work" add s.txt
git -C "$B5/work" commit -qm "unrelated epoch"
ORPHAN="$(git -C "$B5/work" rev-parse HEAD)"
git -C "$B5/work" checkout -q main
set_env "$B5" "$ORPHAN"
run 1 "does not descend from the post-rewrite epoch anchor" \
    "epoch: HEAD not descending from the anchor is rejected" --mode local --skip-network

# --- 6. STALE LOCAL MAIN -----------------------------------------------------
B6="$(mkfixture)"
echo drift > "$B6/work/c.txt"
git -C "$B6/work" add c.txt
git -C "$B6/work" commit -qm "local-only commit"
set_env "$B6" "$(git -C "$B6/work" rev-parse HEAD~2)"
run 1 "local main" "stale main: local main ahead of origin/main is rejected" \
    --mode local --skip-network

# --- 7. SHALLOW CLONE --------------------------------------------------------
B7="$(mkfixture)"
git clone -q --depth 1 "file://$B7/remote.git" "$B7/shallow"
if [[ "$(git -C "$B7/shallow" rev-parse --is-shallow-repository)" != "true" ]]; then
    bad "shallow: fixture invalid — clone --depth 1 did not produce a shallow repository"
else
    set_env "$B7" "$(git -C "$B7/shallow" rev-parse HEAD)"
    RUNENV[0]="NFTBAN_AUTHORITY_ROOT=$B7/shallow"
    RUNENV[1]="NFTBAN_CANONICAL_ORIGIN=file://$B7/remote"
    run 1 "shallow clone" "shallow: fetch-depth 1 checkout is rejected" --mode local --skip-network
fi

# --- 8. TAG DIVERGENCE -------------------------------------------------------
B8="$(mkfixture)"
git -C "$B8/work" tag v9.9.9-local-only
set_env "$B8" "$(git -C "$B8/work" rev-parse HEAD~1)"
run 1 "not on origin" "tags: local-only tag is rejected" --mode local

# --- 9. SAFETY REFUSALS (exit 2, never PASS) ---------------------------------
set_env "$B" "$B_ANCHOR"
run 2 "refused in --mode ci" "refusal: --mode ci --skip-network is refused" --mode ci --skip-network
run 2 "unknown argument"     "refusal: unknown argument"   --bogus-flag
run 2 "--mode must be"       "refusal: invalid mode value" --mode nonsense

B9="$(mkfixture)"
git -C "$B9/work" remote set-url origin "$B9/does-not-exist.git"
set_env "$B9" "$(git -C "$B9/work" rev-parse HEAD~1)"
RUNENV[1]="NFTBAN_CANONICAL_ORIGIN=$B9/does-not-exist"
run 2 "UNDETERMINABLE" "refusal: unreachable origin is REFUSED, not passed" --mode local

# --- 10. NOT A REPOSITORY AT ALL ---------------------------------------------
B10="$(mktemp -d)"; WORKDIRS+=("$B10")
set_env "$B" "$B_ANCHOR"
RUNENV[0]="NFTBAN_AUTHORITY_ROOT=$B10"
run 1 "not a git repository" "identity: a non-repository directory is rejected" \
    --mode local --skip-network

# =============================================================================
# 11. FORK-ORIGIN SCOPE MATRIX
#
# Owner requirement: --allow-fork-origin must relax the origin check and NOTHING
# else. Every other authority check is re-run here with the flag ON *and* a
# non-canonical origin set, and must still fail with its own diagnostic. If the
# flag ever widens into a general bypass, exactly one of these turns green and
# this matrix fails.
# =============================================================================
FORK_ORIGIN="github.com/someone-else/not-nftban"

# A1 identity — child directory with no .git of its own
set_env "$B2" "$(git -C "$B2/work" rev-parse HEAD~1)"
RUNENV[0]="NFTBAN_AUTHORITY_ROOT=$B2/work/child"
RUNENV[1]="NFTBAN_CANONICAL_ORIGIN=$FORK_ORIGIN"
run 1 "repository identity mismatch" "fork-matrix A1: identity still blocking" \
    --mode local --skip-network --allow-fork-origin

# A2 alternates — borrowed object store
set_env "$B3" "$(git -C "$B3/work" rev-parse HEAD~1)"
RUNENV[1]="NFTBAN_CANONICAL_ORIGIN=$FORK_ORIGIN"
run 1 "borrowed object store" "fork-matrix A2: alternates still blocking" \
    --mode local --skip-network --allow-fork-origin

# A4 shallow — ancestry not computable
set_env "$B7" "$(git -C "$B7/shallow" rev-parse HEAD)"
RUNENV[0]="NFTBAN_AUTHORITY_ROOT=$B7/shallow"
RUNENV[1]="NFTBAN_CANONICAL_ORIGIN=$FORK_ORIGIN"
run 1 "shallow clone" "fork-matrix A4: shallow still blocking" \
    --mode local --skip-network --allow-fork-origin

# A5a epoch anchor absent
set_env "$B" "$B_ANCHOR"
RUNENV[1]="NFTBAN_CANONICAL_ORIGIN=$FORK_ORIGIN"
RUNENV[2]="NFTBAN_HISTORY_EPOCH_ANCHOR=1111111111111111111111111111111111111111"
run 1 "epoch anchor is absent" "fork-matrix A5a: missing anchor still blocking" \
    --mode local --skip-network --allow-fork-origin

# A5b HEAD does not descend from the anchor
set_env "$B5" "$ORPHAN"
RUNENV[1]="NFTBAN_CANONICAL_ORIGIN=$FORK_ORIGIN"
run 1 "does not descend from the post-rewrite epoch anchor" \
    "fork-matrix A5b: undescended anchor still blocking" \
    --mode local --skip-network --allow-fork-origin

# A5c pre-rewrite commit present  (contamination must never be excused by a fork)
set_env "$B" "$B_ANCHOR"
RUNENV[1]="NFTBAN_CANONICAL_ORIGIN=$FORK_ORIGIN"
RUNENV[3]="NFTBAN_PREREWRITE_FORBIDDEN_COMMIT=$(git -C "$B/work" rev-parse HEAD)"
run 1 "PRE-REWRITE commit is present" "fork-matrix A5c: contaminated epoch still blocking" \
    --mode local --skip-network --allow-fork-origin

# A6 stale local main
set_env "$B6" "$(git -C "$B6/work" rev-parse HEAD~2)"
RUNENV[1]="NFTBAN_CANONICAL_ORIGIN=$FORK_ORIGIN"
run 1 "local main" "fork-matrix A6: stale main still blocking" \
    --mode local --skip-network --allow-fork-origin

# A7 tag divergence (network path)
set_env "$B8" "$(git -C "$B8/work" rev-parse HEAD~1)"
RUNENV[1]="NFTBAN_CANONICAL_ORIGIN=$FORK_ORIGIN"
run 1 "not on origin" "fork-matrix A7: tag divergence still blocking" \
    --mode local --allow-fork-origin

# Undeterminable remains a refusal, not a pass
set_env "$B9" "$(git -C "$B9/work" rev-parse HEAD~1)"
RUNENV[1]="NFTBAN_CANONICAL_ORIGIN=$FORK_ORIGIN"
run 2 "UNDETERMINABLE" "fork-matrix: unreachable origin still REFUSED" \
    --mode local --allow-fork-origin

# The flag is a no-op when the origin is already canonical
set_env "$B" "$B_ANCHOR"
run 0 "RESULT: PASS" "fork-matrix: flag is a no-op on a canonical origin" \
    --mode local --skip-network --allow-fork-origin

# CI and release paths refuse the flag outright
run 2 "refused in --mode ci" "fork-matrix: CI refuses the flag" --mode ci --allow-fork-origin

echo "----------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
