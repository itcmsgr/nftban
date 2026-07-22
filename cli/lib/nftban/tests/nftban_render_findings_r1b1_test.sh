#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.198 R1b-1 shared findings renderer
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_render_findings_r1b1_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-21"
# meta:description="Hermetic tests for core/nftban_output.sh::nftban_render_findings extracted from cmd_health.sh (R1b-1). Proves behavior-equivalence: INFO hidden by default, --verbose shows all, severity filtering, footer hidden-count; plus byte-identical equivalence vs the original inline logic and the non-orphan adopter guard."
# meta:input="None (canned validator JSON, self-contained)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,jq,grep"
# meta:inventory.files=""
# meta:inventory.binaries="bash,jq"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="nftban_render_findings_r1b1_test"
# meta:ta.owner="health"
# meta:ta.module="health-findings-render"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
NFTBAN_LIB_DIR="${REPO_ROOT}/cli/lib/nftban"
export NFTBAN_LIB_DIR

# Source ONLY the output core module (proves the helper is reachable exactly
# where cmd_health.sh sources it — core/nftban_output.sh — with no other deps).
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }
assert_contains()     { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi; }
assert_not_contains() { if grep -qF -- "$2" <<<"$1"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi; }

# Reference = the ORIGINAL inline logic from cmd_health.sh (pre-R1b-1), used to
# prove the extracted helper is byte-identical.
_reference_render() {
    local output="$1" verbose_mode="${2:-false}"
    local total_count info_count visible_count
    total_count=$(echo "$output" | jq '.findings | length' 2>/dev/null || echo "0")
    info_count=$(echo "$output" | jq '[.findings[] | select(.severity == "info" or .severity == "INFO")] | length' 2>/dev/null || echo "0")
    if [[ "$verbose_mode" == "true" ]]; then visible_count="$total_count"; else visible_count=$((total_count - info_count)); fi
    echo ""
    if [[ "$visible_count" -gt 0 ]]; then
        echo "  Findings ($visible_count):"
        if [[ "$verbose_mode" == "true" ]]; then
            echo "$output" | jq -r '.findings[] | "    [\(.severity | ascii_upcase)] \(.code): \(.message)"' 2>/dev/null
        else
            echo "$output" | jq -r '.findings[] | select(.severity != "info" and .severity != "INFO") | "    [\(.severity | ascii_upcase)] \(.code): \(.message)"' 2>/dev/null
        fi
        if [[ "$verbose_mode" != "true" && "$info_count" -gt 0 ]]; then
            echo "    (${info_count} INFO finding(s) hidden — use --verbose to show)"
        fi
    else
        if [[ "$info_count" -gt 0 ]]; then
            echo "  Findings: none (${info_count} INFO finding(s) hidden — use --verbose to show)"
        else
            echo "  Findings: none"
        fi
    fi
}

# ---- Fixtures (canned validator --json shapes; only .findings[] matters here) ----
J_INFO_ONLY='{"findings":[{"severity":"info","code":"VAL-LOGINMON-002","message":"roundcube source reports no input (no_roundcube)"}]}'
J_MIXED='{"findings":[
  {"severity":"info","code":"VAL-LOGINMON-002","message":"benign absent source"},
  {"severity":"warn","code":"VAL-LOGINMON-002","message":"webauth present but starved"},
  {"severity":"error","code":"VAL-CHAIN-001","message":"chain missing"},
  {"severity":"critical","code":"VAL-ANCHOR-003","message":"final guard absent"}
]}'
J_EMPTY='{"findings":[]}'

echo "R1b-1 shared findings renderer — hermetic tests"

# T1: INFO-only hidden by default
OUT=$(nftban_render_findings "$J_INFO_ONLY" false)
assert_contains "$OUT" "Findings: none (1 INFO finding(s) hidden — use --verbose to show)" "T1 INFO-only hidden by default (footer with count)"
assert_not_contains "$OUT" "[INFO]" "T1 INFO line not shown by default"

# T2: INFO visible with --verbose
OUT=$(nftban_render_findings "$J_INFO_ONLY" true)
assert_contains "$OUT" "[INFO] VAL-LOGINMON-002:" "T2 INFO shown with --verbose"
assert_not_contains "$OUT" "hidden — use --verbose" "T2 no hidden-footer in verbose"

# T3: WARN/ERROR/CRITICAL visible by default, INFO hidden + footer
OUT=$(nftban_render_findings "$J_MIXED" false)
assert_contains "$OUT" "Findings (3):" "T3 header counts only the 3 visible (INFO excluded)"
assert_contains "$OUT" "[WARN] VAL-LOGINMON-002:" "T3 WARN visible by default"
assert_contains "$OUT" "[ERROR] VAL-CHAIN-001:" "T3 ERROR visible by default"
assert_contains "$OUT" "[CRITICAL] VAL-ANCHOR-003:" "T3 CRITICAL visible by default"
assert_not_contains "$OUT" "[INFO]" "T3 INFO hidden by default"
assert_contains "$OUT" "(1 INFO finding(s) hidden — use --verbose to show)" "T3 hidden-INFO footer"

# T4: --verbose shows ALL incl INFO, no footer
OUT=$(nftban_render_findings "$J_MIXED" true)
assert_contains "$OUT" "Findings (4):" "T4 header counts all 4 in verbose"
assert_contains "$OUT" "[INFO] VAL-LOGINMON-002:" "T4 INFO shown in verbose"
assert_not_contains "$OUT" "hidden — use --verbose" "T4 no hidden-footer in verbose"

# T5: no findings
OUT=$(nftban_render_findings "$J_EMPTY" false)
assert_contains "$OUT" "Findings: none" "T5 zero findings -> 'Findings: none'"
assert_not_contains "$OUT" "hidden" "T5 no hidden-footer when no INFO"

# T6: BYTE-IDENTICAL equivalence vs the original inline logic, every fixture x mode
t6_fail=0
for fx in "$J_INFO_ONLY" "$J_MIXED" "$J_EMPTY"; do
    for vb in false true; do
        a=$(nftban_render_findings "$fx" "$vb"); b=$(_reference_render "$fx" "$vb")
        if [[ "$a" != "$b" ]]; then t6_fail=1; printf '    diff (verbose=%s):\n--- helper\n%s\n--- reference\n%s\n' "$vb" "$a" "$b"; fi
    done
done
if [[ "$t6_fail" -eq 0 ]]; then ok "T6 helper output byte-identical to original inline logic (3 fixtures x 2 modes)"; else bad "T6 helper output diverges from original"; fi

# T7: non-orphan adopter guard — cmd_health.sh calls the helper
if grep -qE 'nftban_render_findings "\$output" "\$verbose_mode"' "${NFTBAN_LIB_DIR}/cli/cmd_health.sh"; then
    ok "T7 adopter present: cmd_health.sh calls nftban_render_findings (not orphaned)"
else
    bad "T7 cmd_health.sh does not call the helper (orphan/regression)"
fi

# T8: --json path is unaffected — the JSON branch guard + unfiltered passthrough remain
if grep -qF '"$json_mode" == "true"' "${NFTBAN_LIB_DIR}/cli/cmd_health.sh" \
   && grep -qF 'schema_version, status, service_state, modules, consistency, counters_phase' "${NFTBAN_LIB_DIR}/cli/cmd_health.sh"; then
    ok "T8 --json passthrough branch intact (unfiltered, renderer is text-only)"
else
    bad "T8 --json passthrough branch changed unexpectedly"
fi

# T9: helper is exported (available to subshell function calls like the real CLI)
if declare -F nftban_render_findings >/dev/null 2>&1; then ok "T9 nftban_render_findings defined+sourced from nftban_output.sh"; else bad "T9 helper not defined"; fi

echo "-----------------------------------------------"
printf 'R1b-1 renderer tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
