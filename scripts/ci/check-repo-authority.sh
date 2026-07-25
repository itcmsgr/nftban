#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# meta:name="check-repo-authority"
# meta:type="script"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="CI gate: the working repository must BE the canonical NFTBan development authority. Asserts repository identity (resolved toplevel, not merely 'git works here'), no borrowed object stores, canonical origin, post-rewrite history epoch, non-shallow ancestry, main==origin/main and local/remote tag parity."
# meta:inventory.files=".git/objects/info/alternates, .git/info/grafts"
# meta:inventory.binaries="bash, git, sort, comm, sed"
# meta:inventory.env_vars="CI, NFTBAN_CANONICAL_ORIGIN, NFTBAN_HISTORY_EPOCH_ANCHOR, NFTBAN_PREREWRITE_FORBIDDEN_COMMIT, NFTBAN_AUTHORITY_ROOT, GIT_ALTERNATE_OBJECT_DIRECTORIES"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network="git ls-remote origin (tag parity; --mode local may skip)"
# meta:inventory.privileges="none"
# =============================================================================
#
# WHY THIS GATE EXISTS
# --------------------
# On 2026-07-25 the pre-rewrite shared repository was retired. Two defects made
# that necessary and both are structural, not accidental:
#
#   1. A local checkout can silently be a DIFFERENT history epoch. The
#      2026-07-15 privacy history rewrite replaced upstream history; the stale
#      local tree still had the scrubbed pre-rewrite commits reachable. Branching
#      from it would have resurrected scrubbed private data.
#
#   2. `git rev-parse --git-dir` SUCCEEDS from a directory that is not a
#      repository, because git walks UPWARD. After the old repository was
#      deleted, its path was recreated holding only a `.claude/` directory with
#      no `.git` — and `rev-parse --git-dir` still resolved, to the unrelated
#      parent repository. Any guard built on "did rev-parse succeed" passes from
#      any subdirectory of any ancestor repository.
#
# Therefore this gate compares the RESOLVED `--show-toplevel` against the root
# derived from this script's own location. Identity, never mere reachability.
#
# EXIT CODES
#   0  authority confirmed
#   1  authority violated (a check failed)
#   2  usage error, or authority COULD NOT BE DETERMINED (safety refusal).
#      Undeterminable is never reported as PASS.
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DEFAULT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
ROOT="${NFTBAN_AUTHORITY_ROOT:-$ROOT_DEFAULT}"

# Canonical identity. Overridable so the gate carries no developer-specific
# literal (a hardcoded home path classifies as PSEUDONYMOUS_DEV_PATH under
# scripts/ci/privacy-scan.py and would add advisory findings on every run).
CANONICAL_ORIGIN="${NFTBAN_CANONICAL_ORIGIN:-github.com/itcmsgr/nftban}"

# History epoch anchors (v1.227.1). The anchor is the post-rewrite commit that
# introduced the privacy scrub and its blocking gates; every legitimate HEAD
# descends from it. The forbidden commit is the pre-rewrite tip, which exists
# ONLY in the abandoned epoch — its presence proves a pre-rewrite object store.
EPOCH_ANCHOR="${NFTBAN_HISTORY_EPOCH_ANCHOR:-f5dae9d13377782ee4803f528ebc7e13b59ffc6d}"
FORBIDDEN_COMMIT="${NFTBAN_PREREWRITE_FORBIDDEN_COMMIT:-3752f68a2c29c63de6d24d20eae269a1a3bafb0d}"

MODE="${CI:+ci}"; MODE="${MODE:-local}"
SKIP_NETWORK=0
ALLOW_FORK_ORIGIN=0
FAIL=0

usage() {
    cat <<'USAGE'
Usage: check-repo-authority.sh [--mode ci|local] [--skip-network] [--allow-fork-origin] [--help]

  --mode ci             blocking; network required for tag parity (default when CI is set)
  --mode local          developer-side; --skip-network permitted
  --skip-network        skip tag parity against the remote (refused in --mode ci)
  --allow-fork-origin   report a non-canonical origin as a NOTICE instead of a failure.
                        For contributors working from a fork: identity, object-store,
                        epoch and branch-base checks still apply in full. Refused in
                        --mode ci — a release or merge gate must not accept a fork.

Exit: 0 authority confirmed · 1 authority violated · 2 usage error or undeterminable.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) MODE="${2:-}"; shift 2 || { echo "::error::--mode requires a value"; exit 2; } ;;
        --skip-network) SKIP_NETWORK=1; shift ;;
        --allow-fork-origin) ALLOW_FORK_ORIGIN=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) echo "::error::unknown argument: $1"; usage; exit 2 ;;
    esac
done

case "$MODE" in
    ci|local) ;;
    *) echo "::error::--mode must be 'ci' or 'local' (got: $MODE)"; exit 2 ;;
esac

if [[ "$MODE" == "ci" && "$SKIP_NETWORK" -eq 1 ]]; then
    echo "::error::--skip-network is refused in --mode ci: tag parity is not optional in CI"
    exit 2
fi

if [[ "$MODE" == "ci" && "$ALLOW_FORK_ORIGIN" -eq 1 ]]; then
    echo "::error::--allow-fork-origin is refused in --mode ci: a CI gate must not accept a fork origin"
    exit 2
fi

echo "========================================"
echo "NFTBan CI: Repository Authority (mode=$MODE)"
echo "========================================"

# -----------------------------------------------------------------------------
# A1. REPOSITORY IDENTITY — the resolved toplevel must BE this root.
#     This is the check that defeats the upward-walk trap. A directory with no
#     .git of its own resolves to an ancestor repository; comparing paths
#     catches it, asking "did git succeed" does not.
# -----------------------------------------------------------------------------
echo "[A1] repository identity"
actual_top_raw="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$actual_top_raw" ]]; then
    echo "::error::A1 not a git repository: $ROOT"
    FAIL=1
    actual_top=""
else
    actual_top="$(cd "$actual_top_raw" && pwd -P)"
    if [[ "$actual_top" != "$ROOT" ]]; then
        echo "::error::A1 repository identity mismatch — this directory is NOT its own repository"
        echo "::error::A1   expected toplevel: $ROOT"
        echo "::error::A1   resolved toplevel: $actual_top"
        echo "::error::A1   git walked UPWARD to an ancestor repository; a --git-dir success proves nothing"
        FAIL=1
    else
        echo "  toplevel resolves to this root — OK"
    fi
fi

# Everything below needs a real repository at ROOT.
if [[ -z "$actual_top" || "$actual_top" != "$ROOT" ]]; then
    echo "RESULT: FAIL"
    exit 1
fi

# -----------------------------------------------------------------------------
# A2. NO BORROWED OBJECT STORE. An alternates file (or the env equivalent) means
#     objects come from another repository — including, historically, the
#     pre-rewrite one. Clones must be independent.
# -----------------------------------------------------------------------------
echo "[A2] object-store independence"
common_dir="$(git -C "$ROOT" rev-parse --git-common-dir)"
[[ "$common_dir" = /* ]] || common_dir="$ROOT/$common_dir"
alt_file="$common_dir/objects/info/alternates"
if [[ -s "$alt_file" ]]; then
    echo "::error::A2 borrowed object store: $alt_file is present and non-empty"
    sed 's/^/::error::A2   alternate: /' "$alt_file"
    FAIL=1
elif [[ -n "${GIT_ALTERNATE_OBJECT_DIRECTORIES:-}" ]]; then
    echo "::error::A2 GIT_ALTERNATE_OBJECT_DIRECTORIES is set — objects may come from another repository"
    FAIL=1
else
    echo "  no alternates — OK"
fi

# -----------------------------------------------------------------------------
# A3. CANONICAL ORIGIN. Normalised so ssh and https spellings compare equal.
# -----------------------------------------------------------------------------
echo "[A3] canonical origin"
origin_url="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
if [[ -z "$origin_url" ]]; then
    echo "::error::A3 no 'origin' remote configured"
    FAIL=1
else
    norm="$origin_url"
    norm="${norm#https://}"; norm="${norm#http://}"; norm="${norm#ssh://}"
    norm="${norm#git@}"; norm="${norm/://}"
    norm="${norm%.git}"; norm="${norm%/}"
    if [[ "$norm" != "$CANONICAL_ORIGIN" ]]; then
        if [[ "$ALLOW_FORK_ORIGIN" -eq 1 ]]; then
            echo "  NOTICE: origin is not canonical (expected $CANONICAL_ORIGIN, got $norm)"
            echo "  NOTICE: accepted under --allow-fork-origin; every other authority check still applies"
        else
            echo "::error::A3 origin is not the canonical repository"
            echo "::error::A3   expected: $CANONICAL_ORIGIN"
            echo "::error::A3   actual:   $norm"
            FAIL=1
        fi
    else
        echo "  origin = $CANONICAL_ORIGIN — OK"
    fi
fi

# -----------------------------------------------------------------------------
# A4. NON-SHALLOW, UNGRAFTED. Ancestry claims are meaningless in a shallow or
#     grafted clone, so this must be established BEFORE A5 is trusted.
#     (This is why ci-architecture.yml checks out with fetch-depth: 0.)
# -----------------------------------------------------------------------------
echo "[A4] ancestry is computable"
if [[ "$(git -C "$ROOT" rev-parse --is-shallow-repository)" == "true" ]]; then
    echo "::error::A4 shallow clone — history-epoch ancestry cannot be evaluated"
    echo "::error::A4   the workflow must check out with fetch-depth: 0 and fetch-tags: true"
    FAIL=1
else
    echo "  full history — OK"
fi
if [[ -s "$common_dir/info/grafts" ]]; then
    echo "::error::A4 grafts file present — ancestry is rewritten locally"
    FAIL=1
fi
if [[ -n "$(git -C "$ROOT" replace -l 2>/dev/null)" ]]; then
    echo "::error::A4 replace refs present — ancestry is rewritten locally"
    FAIL=1
fi

# -----------------------------------------------------------------------------
# A5. HISTORY EPOCH. HEAD must descend from the post-rewrite anchor, and the
#     pre-rewrite tip must not exist at all.
# -----------------------------------------------------------------------------
echo "[A5] history epoch"
if ! git -C "$ROOT" cat-file -e "${EPOCH_ANCHOR}^{commit}" 2>/dev/null; then
    echo "::error::A5 post-rewrite epoch anchor is absent: $EPOCH_ANCHOR"
    echo "::error::A5   this history is not the canonical post-rewrite epoch"
    FAIL=1
elif ! git -C "$ROOT" merge-base --is-ancestor "$EPOCH_ANCHOR" HEAD 2>/dev/null; then
    echo "::error::A5 HEAD does not descend from the post-rewrite epoch anchor $EPOCH_ANCHOR"
    FAIL=1
else
    echo "  HEAD descends from the post-rewrite anchor — OK"
fi

if git -C "$ROOT" cat-file -e "${FORBIDDEN_COMMIT}^{commit}" 2>/dev/null; then
    echo "::error::A5 PRE-REWRITE commit is present: $FORBIDDEN_COMMIT"
    echo "::error::A5   this object store predates the privacy history rewrite — branching from it"
    echo "::error::A5   would resurrect scrubbed private infrastructure data"
    FAIL=1
else
    echo "  pre-rewrite tip absent — OK"
fi

# -----------------------------------------------------------------------------
# A6. BRANCH BASE. A stale local `main` is what made the retired tree dangerous:
#     it looked like main and was 7 releases behind on a dead epoch.
# -----------------------------------------------------------------------------
echo "[A6] local main tracks origin/main"
if git -C "$ROOT" show-ref --verify --quiet refs/heads/main \
   && git -C "$ROOT" show-ref --verify --quiet refs/remotes/origin/main; then
    lm="$(git -C "$ROOT" rev-parse refs/heads/main)"
    rm_="$(git -C "$ROOT" rev-parse refs/remotes/origin/main)"
    if [[ "$lm" != "$rm_" ]]; then
        echo "::error::A6 local main ($lm) != origin/main ($rm_) — never branch from a stale main"
        FAIL=1
    else
        echo "  main == origin/main — OK"
    fi
else
    echo "  NOTICE: refs/heads/main or refs/remotes/origin/main absent (typical CI checkout) — not evaluated"
fi

# -----------------------------------------------------------------------------
# A7. TAG PARITY. The retired repository held 12 of 530 tags and still looked
#     healthy. Undeterminable parity is a refusal (exit 2), never a pass.
# -----------------------------------------------------------------------------
echo "[A7] tag parity with origin"
if [[ "$SKIP_NETWORK" -eq 1 ]]; then
    echo "  SKIPPED (--skip-network, mode=local)"
else
    remote_tags_raw=""
    if ! remote_tags_raw="$(git -C "$ROOT" ls-remote --tags origin 2>/dev/null)"; then
        echo "::error::A7 cannot reach origin to verify tag parity — authority is UNDETERMINABLE"
        echo "RESULT: REFUSED"
        exit 2
    fi
    tmp_remote="$(mktemp)"; tmp_local="$(mktemp)"
    # shellcheck disable=SC2064  # expand paths now: the temp names must not change
    trap "rm -f '$tmp_remote' '$tmp_local'" EXIT
    printf '%s\n' "$remote_tags_raw" \
        | sed -n 's#.*refs/tags/\(.*\)#\1#p' | sed 's/\^{}$//' | sort -u > "$tmp_remote"
    git -C "$ROOT" tag | sort -u > "$tmp_local"
    only_remote="$(comm -13 "$tmp_local" "$tmp_remote" | head -20)"
    only_local="$(comm -23 "$tmp_local" "$tmp_remote" | head -20)"
    if [[ -n "$only_remote" ]]; then
        echo "::error::A7 tags on origin but missing locally (fetch-tags: true required):"
        printf '%s\n' "$only_remote" | sed 's/^/::error::A7   /'
        FAIL=1
    fi
    if [[ -n "$only_local" ]]; then
        echo "::error::A7 tags present locally but not on origin (local-only or pre-rewrite tags):"
        printf '%s\n' "$only_local" | sed 's/^/::error::A7   /'
        FAIL=1
    fi
    [[ -z "$only_remote$only_local" ]] && \
        echo "  $(wc -l < "$tmp_local" | tr -d ' ') local == $(wc -l < "$tmp_remote" | tr -d ' ') remote — OK"
fi

echo "========================================"
if [[ "$FAIL" -ne 0 ]]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
exit 0
