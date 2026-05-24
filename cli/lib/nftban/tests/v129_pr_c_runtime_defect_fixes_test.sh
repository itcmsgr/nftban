#!/usr/bin/env bash
# =============================================================================
# V129 PR-C — runtime defect fixes regression test
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="v129_pr_c_runtime_defect_fixes_test"
# meta:type="test"
# meta:version="1.129.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-24"
# meta:description="Deterministic regression tests for the six runtime defects classified cross-family in V129 PR-B and fixed in V129 PR-C: D1 (version --json broken by NFTBAN_GUI_VERSION unbound), D4 (health --verbose unknown as first arg), D5 (config get exit-code contract documented), D6.B (validator polkit-aware wording on permission denied), D7 (well-known IP guard bypassed in --dry-run), D8 (strict-validate prints PASSED when structural validator failed). Tests are pattern-based (grep) for shell paths and execution-based for D1 JSON validity. Full lab2/RPM runtime verification is the PR-C exit gate; this file is the deterministic CI-side guard."
# meta:input="self-contained; sources only the files under test in subshells"
# meta:output="[PASS]/[FAIL] per assertion; exit 1 on first failure; exit 0 if all pass"
# meta:depends="bash,grep,jq (for D1 JSON parse only)"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# Scope: AUDIT_190_LIFECYCLE/V129_PR_B_LAB2_EXECUTION_REPORT.md
#        + AUDIT_190_LIFECYCLE/V129_PR_B_RPM_EXECUTION_REPORT.md
#        + AUDIT_190_LIFECYCLE/V129_DEB_RPM_COMPARISON_MATRIX.md
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
export NFTBAN_LIB_DIR="${_repo_root}/cli/lib/nftban"

_version_cli="${NFTBAN_LIB_DIR}/cli/cmd_version.sh"
_health_cli="${NFTBAN_LIB_DIR}/cli/cmd_health.sh"
_config_cli="${NFTBAN_LIB_DIR}/cli/cmd_config.sh"
_ban_cli="${NFTBAN_LIB_DIR}/cli/cmd_ban.sh"
_firewall_cli="${NFTBAN_LIB_DIR}/cli/cmd_firewall.sh"
_validator_go="${_repo_root}/internal/validator/validator.go"

echo "==============================================================================="
echo "V129 PR-C — runtime defect fixes regression test"
echo "==============================================================================="
echo "  Repo root:    $_repo_root"
echo

# ----------------------------------------------------------------------------
# D1: nftban version --json emits valid JSON; no NFTBAN_GUI_VERSION reference
# ----------------------------------------------------------------------------
echo "--- D1: nftban version --json ---"

# Source check: the JSON heredoc MUST NOT reference NFTBAN_GUI_VERSION or
# NFTBAN_API_VERSION (V127 UX-1 1.3 removed them; v1.129 PR-C removes the
# residual heredoc references).
if grep -qE 'NFTBAN_(GUI|API)_VERSION' "$_version_cli"; then
    _t_assert "D1: cmd_version.sh has no NFTBAN_GUI_VERSION/API_VERSION references" 1 \
        "grep still finds NFTBAN_(GUI|API)_VERSION"
else
    _t_assert "D1: cmd_version.sh has no NFTBAN_GUI_VERSION/API_VERSION references" 0
fi

# Runtime check: when run with strict mode + --json, output parses as valid JSON
# and contains a version key. Skip jq-based parse if jq missing.
if command -v jq >/dev/null 2>&1; then
    _json_out=$(bash -Eeuo pipefail -c '
        export NFTBAN_VERSION="1.129.0-test"
        export NFTBAN_VERSION_NAME="PR-C-test"
        export NFTBAN_VERSION_DATE="2026-05-24"
        export NFTBAN_BUILD_DATE="2026-05-24"
        export NFTBAN_CLI_VERSION="1.129.0-test"
        export NFTBAN_CORE_VERSION="1.129.0-test"
        export NFTBAN_MIN_BASH_VERSION="4.4"
        export NFTBAN_MIN_NFT_VERSION="0.9.0"
        export NFTBAN_LIB_DIR="'"$NFTBAN_LIB_DIR"'"
        # shellcheck source=/dev/null
        source "'"$_version_cli"'" 2>/dev/null || true
        if declare -f nftban_cmd_version >/dev/null; then
            nftban_cmd_version --json 2>/dev/null
        fi
    ' 2>/dev/null)
    # Strip post-JSON sentinel line `# NFTBAN_CMD_EXIT: version` emitted by
    # cmd_version.sh at the end of every invocation.
    _json_clean=$(printf '%s\n' "$_json_out" | sed '/^# NFTBAN_CMD_EXIT/,$d')
    if echo "$_json_clean" | jq -e '.version' >/dev/null 2>&1; then
        _t_assert "D1: --json output parses as JSON with .version key" 0
    else
        _t_assert "D1: --json output parses as JSON with .version key" 1 \
            "output was: $_json_out"
    fi
else
    echo "  [SKIP] D1 runtime jq check (jq not installed)"
fi

# ----------------------------------------------------------------------------
# D4: nftban health --verbose works as first arg (does NOT route to "Unknown")
# ----------------------------------------------------------------------------
echo "--- D4: nftban health --verbose ---"

# The cmd_health.sh dispatcher MUST handle --verbose / -v / --json as first arg
# by routing to default "check" subcommand without consuming them as subcommand.
if grep -qE '^\s*--verbose\|-v\|--json\)' "$_health_cli"; then
    _t_assert "D4: cmd_health.sh routes --verbose/-v/--json first-arg to default subcommand" 0
else
    _t_assert "D4: cmd_health.sh routes --verbose/-v/--json first-arg to default subcommand" 1 \
        "expected case branch '--verbose|-v|--json)' near subcommand parser"
fi

# Negative pattern: there must NOT be an executable assignment that sets
# subcommand="--verbose" (ignoring comments). The pre-fix bug was the literal
# "local subcommand=\"${1:-check}\"" line being the sole subcommand setter
# without flag detection.
if grep -vE '^\s*#' "$_health_cli" | grep -qE 'subcommand="--verbose"'; then
    _t_assert "D4: no executable code assigns subcommand=\"--verbose\"" 1 \
        "found explicit subcommand=\"--verbose\" assignment outside comments"
else
    _t_assert "D4: no executable code assigns subcommand=\"--verbose\"" 0
fi

# ----------------------------------------------------------------------------
# D5: cmd_config.sh help has EXIT CODES block documenting rc=1 for not-found
# ----------------------------------------------------------------------------
echo "--- D5: nftban config exit-code documentation ---"

if grep -qE '^EXIT CODES:' "$_config_cli"; then
    _t_assert "D5: cmd_config.sh usage block contains EXIT CODES section" 0
else
    _t_assert "D5: cmd_config.sh usage block contains EXIT CODES section" 1 \
        "missing 'EXIT CODES:' header in show_usage heredoc"
fi

if grep -qE '^\s+1\s+Generic failure' "$_config_cli"; then
    _t_assert "D5: cmd_config.sh EXIT CODES documents '1 Generic failure'" 0
else
    _t_assert "D5: cmd_config.sh EXIT CODES documents '1 Generic failure'" 1
fi

# Verify the not-found path actually returns 1 (the intended v1.127 UX-1 1.9 contract)
if grep -A 3 'Configuration file not found for module' "${NFTBAN_LIB_DIR}/core/nftban_config.sh" | grep -qE '^\s*return 1$'; then
    _t_assert "D5: nftban_config.sh not-found path returns 1 (per UX-1 1.9 contract)" 0
else
    _t_assert "D5: nftban_config.sh not-found path returns 1 (per UX-1 1.9 contract)" 1 \
        "expected 'return 1' immediately after not-found stderr block"
fi

# ----------------------------------------------------------------------------
# D6.B: no "you must be root" wording in NFTBan-emitted text; polkit-aware
# remediation in validator
# ----------------------------------------------------------------------------
echo "--- D6.B: polkit-aware wording on permission denied ---"

# CLI shell tree must never contain the forbidden V128 PR-A.1 wording.
_root_hits=$(grep -rln "you must be root" "${NFTBAN_LIB_DIR}" 2>/dev/null | grep -v -E '/tests/|/V129_' || true)
if [[ -z "$_root_hits" ]]; then
    _t_assert "D6.B: no 'you must be root' wording in cli/lib/nftban/ (non-test)" 0
else
    _t_assert "D6.B: no 'you must be root' wording in cli/lib/nftban/ (non-test)" 1 \
        "hits in: $_root_hits"
fi

# Validator must scrub the upstream nft "(you must be root)" pattern when wrapping.
if grep -qE '\(you must be root\)' "$_validator_go"; then
    _t_assert "D6.B: validator.go strips/handles '(you must be root)' upstream wording" 0
else
    _t_assert "D6.B: validator.go strips/handles '(you must be root)' upstream wording" 1 \
        "expected explicit (you must be root) handling — fix dropped or pattern changed"
fi

# Validator remediation must be polkit/capability-aware, not legacy "permissions" wording.
if grep -qE 'CAP_NET_ADMIN' "$_validator_go"; then
    _t_assert "D6.B: validator.go remediation mentions CAP_NET_ADMIN" 0
else
    _t_assert "D6.B: validator.go remediation mentions CAP_NET_ADMIN" 1
fi

# ----------------------------------------------------------------------------
# D7: nftban ban --dry-run on well-known IP must be rejected
# ----------------------------------------------------------------------------
echo "--- D7: well-known guard fires in --dry-run ---"

# The guard condition must NOT include `&& "$dry_run" != "true"` (the original bug)
if grep -qE 'auto_confirm.*!=.*"true".*&&.*dry_run.*!=.*"true"' "$_ban_cli"; then
    _t_assert "D7: cmd_ban.sh guard condition does NOT exclude dry-run" 1 \
        "found pre-fix condition that excluded dry-run from the refusal branch"
else
    _t_assert "D7: cmd_ban.sh guard condition does NOT exclude dry-run" 0
fi

# Positive: the new condition checks only auto_confirm
if grep -qE 'if \[\[ "\$auto_confirm" != "true" \]\]; then' "$_ban_cli"; then
    _t_assert "D7: cmd_ban.sh guard uses auto_confirm-only condition" 0
else
    _t_assert "D7: cmd_ban.sh guard uses auto_confirm-only condition" 1 \
        "expected the refusal branch to be gated on auto_confirm only"
fi

# Documentation comment must be updated to reflect that dry-run is also refused
if grep -qE '(dry.run|dry_run)' "$_ban_cli" | head -1 >/dev/null && \
   grep -qE 'V129 PR-C D7' "$_ban_cli"; then
    _t_assert "D7: cmd_ban.sh comments reference V129 PR-C D7 fix" 0
else
    _t_assert "D7: cmd_ban.sh comments reference V129 PR-C D7 fix" 1
fi

# ----------------------------------------------------------------------------
# D8: strict-validate must NOT say PASSED when structural validator failed
# ----------------------------------------------------------------------------
echo "--- D8: strict-validate PASSED only when structural_ok ---"

# The strict-mode function must accept a structural_ok parameter
if grep -qE 'structural_ok="?\$\{2:-true\}"?' "$_firewall_cli"; then
    _t_assert "D8: _firewall_validate_strict accepts structural_ok 2nd arg" 0
else
    _t_assert "D8: _firewall_validate_strict accepts structural_ok 2nd arg" 1
fi

# The function must emit "NOT VERIFIED" label when structural_ok != "true"
if grep -qE 'STRICT PREFLIGHT: NOT VERIFIED' "$_firewall_cli"; then
    _t_assert "D8: 'STRICT PREFLIGHT: NOT VERIFIED' label exists" 0
else
    _t_assert "D8: 'STRICT PREFLIGHT: NOT VERIFIED' label exists" 1
fi

# The PASSED label must be gated on structural_ok=="true"
_passed_branch=$(awk '/structural_ok.*==.*"true"/,/else/' "$_firewall_cli" 2>/dev/null | grep -c 'STRICT PREFLIGHT: PASSED' || true)
if [[ "$_passed_branch" -ge 1 ]]; then
    _t_assert "D8: 'STRICT PREFLIGHT: PASSED' is inside structural_ok==true branch" 0
else
    _t_assert "D8: 'STRICT PREFLIGHT: PASSED' is inside structural_ok==true branch" 1 \
        "PASSED not found inside structural_ok==\"true\" branch"
fi

# Caller must pass structural_ok based on validation_result
if grep -qE '_struct_ok="false"' "$_firewall_cli" && \
   grep -qE '_firewall_validate_strict.*"\$_struct_ok"' "$_firewall_cli"; then
    _t_assert "D8: firewall_validate caller passes structural_ok to strict mode" 0
else
    _t_assert "D8: firewall_validate caller passes structural_ok to strict mode" 1
fi

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
echo
echo "==============================================================================="
echo "V129 PR-C regression test summary"
echo "==============================================================================="
echo "  Passed:  $TESTS_PASSED"
echo "  Failed:  $TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
    echo "  Failed assertions:"
    for n in "${FAILED_NAMES[@]}"; do
        echo "    - $n"
    done
    exit 1
fi
exit 0
