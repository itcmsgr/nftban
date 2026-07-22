#!/usr/bin/env bash
# =============================================================================
# v1.128 PR-D DOC_CLARITY_AUDIT — deterministic test fixtures
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="v128_doc_clarity_audit_test"
# meta:type="test"
# meta:version="1.128.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-24"
# meta:description="Deterministic clarity-lint across operator-facing repo markdown (README.md + docs/**/*.md). Locks the v1.128 invariant after PR-A.1/.2 (polkit wording sweep), PR-B (help/code correlation), and PR-C (wiki + docs alignment): operator-facing markdown must not contain TODO/XXX/FIXME placeholders, vague qualifier phrases ('for various reasons', 'usually works', 'should work', 'in general'), double-negative constructions (heuristic check excluding technical double-negatives), or any residual sudo/root drift that escaped PR-A.2. The clarity-lint is conservative and additive: it locks a small set of high-signal patterns rather than attempting subjective prose review. Wiki (the nftban.wiki sibling git repo) is separate and not available to CI — that surface was aligned in PR-C wiki commit 312fdb3 on the nftban.wiki master branch and lives outside this test's reach. The 1 known technical double-negative in docs/THREAT_MODEL.md ('over-blocking but not under-blocking') is explicitly allowlisted as legitimate technical contrast wording."
# meta:input="static scan of README.md + docs/**/*.md"
# meta:output="exit 0 if clarity invariants hold; exit 1 with offender list otherwise"
# meta:depends="bash,grep,find"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="v128_doc_clarity_audit_test"
# meta:ta.owner="cross-cutting"
# meta:ta.module="docs"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
#
# Scope: AUDIT_190_LIFECYCLE/V128_CLI_TEXT_AUTHORITY_ALIGNMENT_SCOPE.md (PR-D lane)
# =============================================================================

set -Eeuo pipefail
set +e

TESTS_PASSED=0
TESTS_FAILED=0
FAILED_NAMES=()

_t_assert() {
    local name="$1"
    local ok="$2"
    local detail="${3:-}"
    if [[ "$ok" == "0" ]]; then
        printf "  [PASS] %s\n" "$name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        printf "  [FAIL] %s%s\n" "$name" "${detail:+ — $detail}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_NAMES+=("$name")
    fi
}

_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
_readme="${_repo_root}/README.md"
_docs_dir="${_repo_root}/docs"

# Allowlist: technical contexts where a "lint" hit is actually correct content
_ALLOWLIST=(
    'docs/THREAT_MODEL.md.*over-blocking.*but not under-blocking'  # legitimate technical contrast
)

_apply_allowlist() {
    local pattern
    for pattern in "${_ALLOWLIST[@]}"; do
        set -- "$@" -e "$pattern"
    done
    grep -v "$@"
}

echo "==============================================================================="
echo "v1.128 PR-D DOC_CLARITY_AUDIT — deterministic test fixtures"
echo "==============================================================================="

# =============================================================================
# (A) Placeholder markers — operator-facing markdown must not ship with these
# =============================================================================
hits=$(grep -rnE 'TODO:|XXX:|FIXME:' --include='*.md' "$_readme" "$_docs_dir" 2>/dev/null | wc -l)
hits=${hits:-0}
[[ "$hits" -eq 0 ]]
_t_assert "A1: zero TODO/XXX/FIXME placeholder markers in README + docs/ (got: $hits)" "$?"

# =============================================================================
# (B) Vague qualifier phrases — undermine operator confidence
# =============================================================================
hits=$(grep -rniE 'for various reasons|should work|usually works|in general,' --include='*.md' "$_readme" "$_docs_dir" 2>/dev/null | wc -l)
hits=${hits:-0}
[[ "$hits" -eq 0 ]]
_t_assert "B1: zero vague qualifier phrases ('for various reasons' / 'should work' / 'usually works' / 'in general,') in README + docs/ (got: $hits)" "$?"

# =============================================================================
# (C) Double-negative constructions — heuristic with explicit allowlist
# =============================================================================
hits=$(grep -rniE "don'?t not|not un[a-z]+|cannot not" --include='*.md' "$_readme" "$_docs_dir" 2>/dev/null \
       | _apply_allowlist | wc -l)
hits=${hits:-0}
[[ "$hits" -eq 0 ]]
_t_assert "C1: zero double-negative constructions (allowlist: legitimate technical contrast in THREAT_MODEL.md) (got: $hits)" "$?"

# =============================================================================
# (D) Residual sudo/root drift in operator-facing markdown
# (cross-check that PR-A.2 + PR-C polkit wording didn't regress here)
# =============================================================================
hits=$(grep -rnE 'sudo nftban |must run as root|requires root|Run with sudo|Permission denied \(not root|root privileges' \
       --include='*.md' "$_readme" "$_docs_dir" 2>/dev/null | wc -l)
hits=${hits:-0}
[[ "$hits" -eq 0 ]]
_t_assert "D1: zero residual sudo/root drift in README + docs/ markdown (got: $hits)" "$?"

# =============================================================================
# (E) Scope/sanity sample counts
# =============================================================================
md_count=$(find "$_docs_dir" -name '*.md' 2>/dev/null | wc -l)
md_count=${md_count:-0}
[[ "$md_count" -ge 10 ]]
_t_assert "E1: docs/ contains at least 10 .md files audited (got: $md_count)" "$?"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "==============================================================================="
echo "v1.128 PR-D test summary: ${TESTS_PASSED} PASS, ${TESTS_FAILED} FAIL"
echo "==============================================================================="
if [[ "$TESTS_FAILED" -gt 0 ]]; then
    echo "Failed tests:"
    for name in "${FAILED_NAMES[@]}"; do
        echo "  - $name"
    done
    exit 1
fi
exit 0
