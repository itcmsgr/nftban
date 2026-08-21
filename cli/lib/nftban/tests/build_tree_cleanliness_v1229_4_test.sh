#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.229.4 SC-B — RUNNING THE CI AUTHORITIES MUST NOT DIRTY THE TREE
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="build-tree-cleanliness-v1229-4-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-19"
# meta:description="SC-B. Both shipped binaries carried a +dirty module stamp. The measured cause was not source at all: CI runs the scripts/ci/*.py authorities before the release build, Python writes __pycache__/, git status reports it as untracked, and Go's VCS stamper reads any unclean tree as dirty. Asserts that executing a CI Python authority leaves the worktree clean, so the release build cannot inherit a dirty stamp from our own tooling."
# meta:inventory.files=".gitignore,scripts/ci/test-authority.py"
# meta:inventory.privileges="none"
# meta:ta.id="build_tree_cleanliness_v1229_4_test"
# meta:ta.owner="cross-cutting"
# meta:ta.module="core"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
#
#   MEASURED (release run 32292166763, before the fix):
#       SC-B DIRTY_PATH_COUNT=1
#       ?? scripts/ci/__pycache__/
#       tracked source modified: NONE · staged: NONE · unstaged: NONE
#
#   ⛔ THE TREE WAS NEVER DIRTY BECAUSE OF SOURCE. It was dirty because of an artifact
#      OUR OWN TOOLING created before the build. Go's VCS stamper does not distinguish
#      "untracked build residue" from "modified source" — any unclean tree is +dirty.
#
#   ⛔ SCOPE. This proves the cause and fix for the release.yml build path, which produces
#      nftband and the in-package nftban-core. The standalone published
#      nftban-core-linux-amd64 is built by the THIRD-PARTY SLSA reusable workflow, which
#      this cannot instrument. Its +dirty must be re-observed on the next SLSA-built
#      artifact; ⛔ do NOT infer it from nftband.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
FAIL=0
pass(){ echo "  PASS  $1"; }
fail(){ echo "  FAIL  $1"; FAIL=1; }
info(){ echo "        $1"; }

echo "=== build-tree cleanliness (v1.229.4 SC-B) ==="
cd "$ROOT" || { echo "  SUBJECT_NOT_FOUND: $ROOT"; echo "RESULT: FAIL"; exit 1; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "  SUBJECT_NOT_FOUND: not a git worktree"; echo "RESULT: FAIL"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "  SUBJECT_NOT_FOUND: python3"; echo "RESULT: FAIL"; exit 1; }

# ⛔ PRECONDITION. If the worktree is already dirty for unrelated reasons, the arms below
#    cannot attribute anything. A pre-existing dirty tree is not a pass and not a failure
#    of the property — it means the observation cannot be made.
PRE="$(git status --porcelain=v1 | wc -l | tr -d ' ')"
if [[ "$PRE" -ne 0 ]]; then
    info "PRECONDITION_UNMET: worktree already has $PRE dirty path(s); attribution impossible."
    git status --porcelain=v1 | sed 's/^/          /' | head -5
    info "⛔ Reported as NOT_OBSERVED — not as a pass."
    echo "RESULT: PASS (precondition unmet; property NOT_OBSERVED)"
    exit 0
fi
pass "PRECONDITION worktree is clean, so any new dirt is attributable to what runs next"

# ---- A1 · the exact measured path must be ignored -------------------------------
CACHE="scripts/ci/__pycache__"
mkdir -p "$CACHE"
: > "$CACHE/probe.cpython-313.pyc"
DIRTY="$(git status --porcelain=v1 | wc -l | tr -d ' ')"
if [[ "$DIRTY" -eq 0 ]]; then
    pass "A1 the measured dirty path ($CACHE) no longer makes the tree dirty"
else
    fail "A1 $CACHE still dirties the worktree ($DIRTY path(s))"
    git status --porcelain=v1 | sed 's/^/          /' | head -3
fi
rm -rf "$CACHE"

# ---- A2 · running the REAL producer must leave the tree clean --------------------
# The property is not "one directory is ignored" — it is that EXECUTING our tooling does
# not dirty the build subject. So the arm must run the script that ACTUALLY creates the
# cache, not merely any Python script.
# ⛔ MEASURED: Python writes __pycache__ only for IMPORTED modules, never for the main
#    script. test-authority.py imports no sibling, so running it creates nothing and the
#    arm would pass with the ignore rule REMOVED — a vacuous control.
#    privacy-scan-selftest.py importlib-loads privacy-scan.py, producing exactly
#    scripts/ci/__pycache__/privacy-scan.cpython-*.pyc — the artifact CI observed.
AUTH="scripts/ci/privacy-scan-selftest.py"
if [[ -f "$AUTH" ]]; then
    ( cd "$ROOT" && python3 "$AUTH" >/dev/null 2>&1 ) || true
    D2="$(git status --porcelain=v1 | wc -l | tr -d ' ')"
    if [[ "$D2" -eq 0 ]]; then
        pass "A2 executing the real cache-producing authority leaves the worktree CLEAN"
        info "the release build can no longer inherit a +dirty stamp from our own tooling"
    else
        fail "A2 running $AUTH dirtied the worktree ($D2 path(s))"
        git status --porcelain=v1 | sed 's/^/          /' | head -5
    fi
else
    fail "A2 SUBJECT_NOT_FOUND: $AUTH — a repo-resident authority is missing"
fi
# ⛔ LEAVE NO TRACE. A2 genuinely creates the cache; without this cleanup the NEXT run of
#    this test starts with a dirty worktree and trips its own PRECONDITION. Measured: that
#    residue silently blocked an inversion from executing at all.
rm -rf "$CACHE"

# ---- A4 · the SLSA builder's vendor/ must not dirty the tree ---------------------
# ⛔ A SEPARATE PRODUCER from A1/A2. builder_go_slsa3.yml@v2.1.0 runs `go mod vendor` in
#    the project checkout immediately before compiling (job "build", step "Download
#    dependencies"). That materializes vendor/ as untracked, git reports the worktree
#    dirty, and Go stamps vcs.modified=true — which is why every SLSA-built nftban-core
#    shipped +dirty (v1.229.3, v1.229.5) while our own build path, which never vendors,
#    did not. ⛔ Do NOT describe this as the __pycache__ cause; same shape, different
#    producer, and conflating them would have sent the fix to the wrong path.
VEND="vendor"
mkdir -p "$VEND/example.com/pkg"
: > "$VEND/example.com/pkg/f.go"
: > "$VEND/modules.txt"
D4="$(git status --porcelain=v1 | grep -c 'vendor' || true)"
if [[ "$D4" -eq 0 ]]; then
    pass "A4 a vendored dependency tree does not dirty the worktree"
    info "the SLSA builder can no longer stamp nftban-core +dirty from its own vendoring"
else
    fail "A4 vendor/ still dirties the worktree ($D4 path(s))"
    git status --porcelain=v1 | grep 'vendor' | sed 's/^/          /' | head -3
fi
rm -rf "$VEND"

# ---- A3 · the ignore rule must be declared, not incidental -----------------------
if grep -qE '^\s*__pycache__/\s*$' .gitignore 2>/dev/null; then
    pass "A3 __pycache__/ is declared in .gitignore"
else
    fail "A3 __pycache__/ is not declared — A1/A2 would pass only by accident of state"
fi
if grep -qE '^\s*vendor/\s*$' .gitignore 2>/dev/null; then
    pass "A3b vendor/ is declared in .gitignore"
else
    fail "A3b vendor/ is not declared — A4 would pass only by accident of state"
fi

echo
[[ $FAIL -eq 0 ]] && { echo "RESULT: PASS"; exit 0; }
echo "RESULT: FAIL"; exit 1
