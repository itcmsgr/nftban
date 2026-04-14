#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.80 — B80-1 validate_structure shim regression guard
# =============================================================================
# meta:name="test_validate_structure_is_shim"
# meta:type="test"
# meta:version="1.80.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Pins the B80-1 invariant: validate_structure() in nftban_ip_and_stats.sh MUST be a thin shim over nftban-validate and MUST NOT contain independent validation logic"
# meta:inventory.files="cli/lib/nftban/core/nftban_ip_and_stats.sh"
# meta:inventory.binaries="bash,awk,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Background:
#   B80-1 closes the "two validator authorities" drift risk (shell validator
#   alongside Go validator). The v1.81 cleanup will remove the shell file
#   entirely, but during v1.80 hardening the file stays in place for
#   backward compatibility with existing CLI callers (cmd_validate.sh,
#   cmd_firewall.sh rebuild/reload/reset fallback paths). Instead, the
#   function body is rewritten as a thin shim over the Go validator binary.
#
#   This test is the invariant pin: validate_structure() must remain a shim.
#   If anyone re-adds independent validation logic (jq on nftables JSON,
#   nft list ruleset, spec loading, etc.) this test must fail in CI before
#   the PR lands. That is the entire point — the shell code must not
#   accidentally become a parallel truth authority again.
#
# Scope:
#   Static analysis of the file. Hermetic. No runtime dependencies beyond
#   bash, awk, and grep. Safe to run anywhere.
#
# What this test does NOT check:
#   - runtime behaviour (that's covered by the INV-CONS-001 smoke check in
#     cli/lib/nftban/tests/smoke_test.sh run_runtime_tests())
#   - check_ip_or_port / get_firewall_stats in the same file (those are
#     not in B80-1 scope and are v1.81 cleanup targets)
#   - the shell file's existence (it is intentionally kept for backward
#     compat; its DELETION is v1.81 scope, not v1.80)
# =============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
TARGET_FILE="$PROJECT_ROOT/cli/lib/nftban/core/nftban_ip_and_stats.sh"

if [[ ! -f "$TARGET_FILE" ]]; then
    echo "FATAL: target file not found at $TARGET_FILE" >&2
    exit 2
fi

pass_count=0
fail_count=0

assert() {
    local name="$1"
    local ok="$2"
    if [[ "$ok" == "yes" ]]; then
        echo "  PASS  $name"
        ((pass_count++)) || true
    else
        echo "  FAIL  $name"
        ((fail_count++)) || true
    fi
}

# Extract the body of validate_structure() only. We do NOT check the rest
# of the file because check_ip_or_port and get_firewall_stats legitimately
# contain nft/jq parsing — that's not in B80-1 scope.
body=$(awk '
    /^validate_structure\(\)/ { in_fn=1; depth=0 }
    in_fn {
        print
        # Track brace depth to find the matching closing brace
        n=gsub(/\{/, "{"); depth+=n
        n=gsub(/\}/, "}"); depth-=n
        if (depth == 0 && /\}/) { exit }
    }
' "$TARGET_FILE")

if [[ -z "$body" ]]; then
    echo "FATAL: could not extract validate_structure() body from $TARGET_FILE" >&2
    exit 2
fi

body_lines=$(printf '%s\n' "$body" | wc -l)

echo "=========================================================="
echo "B80-1 validate_structure shim regression guard"
echo "  target: cli/lib/nftban/core/nftban_ip_and_stats.sh"
echo "  body lines: $body_lines"
echo "=========================================================="
echo ""
echo "[1] Positive invariants — the shim MUST do these things"

# P1: body must call the Go validator binary
if printf '%s' "$body" | grep -q 'nftban-validate'; then
    assert "body calls the Go validator binary (nftban-validate)" "yes"
else
    assert "body calls the Go validator binary (nftban-validate)" "no"
fi

# P2: body must use NFTBAN_LIB_DIR/bin/ path style for the validator
if printf '%s' "$body" | grep -qE 'NFTBAN_LIB_DIR.*/bin/nftban-validate'; then
    assert "body builds validator path via \$NFTBAN_LIB_DIR/bin/nftban-validate" "yes"
else
    assert "body builds validator path via \$NFTBAN_LIB_DIR/bin/nftban-validate" "no"
fi

# P3: body must contain a B80-1 NOTE comment block so future readers understand
#     this is a shim, not a standalone validator
if printf '%s' "$body" | grep -q 'B80-1'; then
    assert "body contains the B80-1 NOTE comment explaining the shim intent" "yes"
else
    assert "body contains the B80-1 NOTE comment explaining the shim intent" "no"
fi

# P4: body must emit the legacy shell JSON schema
#     {status,errors,warnings,info} — this is the preserved output contract
if printf '%s' "$body" | grep -qE 'status.*errors.*warnings.*info'; then
    assert "body preserves legacy shell JSON schema {status,errors,warnings,info}" "yes"
else
    assert "body preserves legacy shell JSON schema {status,errors,warnings,info}" "no"
fi

# P5: body must map Go status strings (protected/degraded/down) to shell
#     severity words via jq (critical/error/warn → ERROR/WARNING)
if printf '%s' "$body" | grep -qE '(critical|error|warn)'; then
    assert "body maps Go severity levels to shell schema" "yes"
else
    assert "body maps Go severity levels to shell schema" "no"
fi

echo ""
echo "[2] Negative invariants — the shim MUST NOT do these things"

# N1: body must NOT call load_spec() (spec loading belongs to the old path)
if printf '%s' "$body" | grep -vE '^\s*#' | grep -q 'load_spec'; then
    assert "body does NOT call load_spec() (spec loading is Go-side only)" "no"
else
    assert "body does NOT call load_spec() (spec loading is Go-side only)" "yes"
fi

# N2: body must NOT call get_live_ruleset() (nft list ruleset wrapping is
#     Go-side only now)
if printf '%s' "$body" | grep -vE '^\s*#' | grep -q 'get_live_ruleset'; then
    assert "body does NOT call get_live_ruleset() (kernel read is Go-side only)" "no"
else
    assert "body does NOT call get_live_ruleset() (kernel read is Go-side only)" "yes"
fi

# N3: body must NOT run `nft list ruleset` directly
if printf '%s' "$body" | grep -vE '^\s*#' | grep -qE 'nft[[:space:]]+list[[:space:]]+ruleset'; then
    assert "body does NOT run 'nft list ruleset' directly" "no"
else
    assert "body does NOT run 'nft list ruleset' directly" "yes"
fi

# N4: body must NOT use --slurpfile pattern (that was the old batch-jq
#     validation shape — a smoking gun for independent validation logic)
if printf '%s' "$body" | grep -q -- '--slurpfile'; then
    assert "body does NOT use --slurpfile batch validation pattern" "no"
else
    assert "body does NOT use --slurpfile batch validation pattern" "yes"
fi

# N5: body must NOT reference required_tables / required_sets / policy_checks
#     (spec field names — unmistakably independent validation logic)
if printf '%s' "$body" | grep -qE 'required_tables|required_sets|policy_checks|expected_structure'; then
    assert "body does NOT reference spec field names (required_tables etc.)" "no"
else
    assert "body does NOT reference spec field names (required_tables etc.)" "yes"
fi

# N6: body must NOT be too long — a shim grew into a validator is the
#     exact failure mode this test is preventing. 260 lines accommodates:
#       NOTE comment block           ~30 lines
#       missing-binary fail-closed   ~20 lines (printf-based, no jq)
#       empty-output fail-closed     ~20 lines (printf-based, no jq)
#       jq-missing fallback branch   ~35 lines (both modes × both paths)
#       main Go→shell translation    ~30 lines
#       parse-fail fail-closed       ~15 lines (jq -n, jq is present here)
#       status+counts extraction     ~15 lines
#       text rendering               ~30 lines
#       closing exit-code logic      ~10 lines
#     Total realistic ceiling ~205; cap at 260 for headroom, stays well
#     under the old batch validator's ~200 lines of independent validation.
if [[ "$body_lines" -le 260 ]]; then
    assert "body length $body_lines ≤ 260 lines (shim discipline)" "yes"
else
    assert "body length $body_lines ≤ 260 lines (shim discipline)" "no"
fi

# N7: body must use a bounded number of jq invocations. The shim shape after
# Amend-2 (jq-missing fallback) is:
#     1 jq for main Go→shell schema translation
#     1 jq for status+counts extraction (consolidated)
#     2 jq for text rendering (errors[] + warnings[])
#     1 jq -n for parse-fail fail-closed output shaping
#     1 command -v jq (counts as a jq mention)
#     = 6 functional + 1 fallback gate
#     Cap at 12 to leave headroom for the jq-missing path's future growth
#     but still catch re-introduction of per-field validation logic. The
#     old batch validator used 12+ jq calls DIRECTLY on raw nftables JSON —
#     the shape this cap catches is unmistakably different even at 10-11.
jq_count=$(printf '%s' "$body" | grep -vE '^\s*#' | grep -cE '\bjq[[:space:]]' || true)
if [[ "$jq_count" -le 12 ]]; then
    assert "body uses ≤12 jq invocations (jq_count=$jq_count)" "yes"
else
    assert "body uses ≤12 jq invocations (jq_count=$jq_count, too many)" "no"
fi

# N8: body must have a jq-missing fallback — Amend-2 contract enforcement
if printf '%s' "$body" | grep -q 'command -v jq'; then
    assert "body checks 'command -v jq' for jq-missing fallback (Amend-2)" "yes"
else
    assert "body checks 'command -v jq' for jq-missing fallback (Amend-2)" "no"
fi

# N9: body must use 'return 2' for missing-binary path — Amend-1 contract
if printf '%s' "$body" | grep -qE '^\s*return 2\b'; then
    assert "body uses 'return 2' for missing-binary fail (Amend-1)" "yes"
else
    assert "body uses 'return 2' for missing-binary fail (Amend-1)" "no"
fi

echo ""
echo "[3] Static guardrails on the file surface"

# S1: the file still exists (B80-1 does NOT delete it — that's v1.81 scope)
if [[ -f "$TARGET_FILE" ]]; then
    assert "nftban_ip_and_stats.sh exists (relocated from nftban_validator.sh)" "yes"
else
    assert "nftban_ip_and_stats.sh exists (relocated from nftban_validator.sh)" "no"
fi

# S2: the other two non-B80-1 functions are still defined (scope fence proof)
if grep -q '^check_ip_or_port()' "$TARGET_FILE"; then
    assert "check_ip_or_port() preserved (scope fence)" "yes"
else
    assert "check_ip_or_port() preserved (scope fence)" "no"
fi
if grep -q '^get_firewall_stats()' "$TARGET_FILE"; then
    assert "get_firewall_stats() preserved (scope fence)" "yes"
else
    assert "get_firewall_stats() preserved (scope fence)" "no"
fi

echo ""
echo "=========================================================="
echo "Results: $pass_count passed, $fail_count failed"
echo "=========================================================="

[[ "$fail_count" -eq 0 ]]
