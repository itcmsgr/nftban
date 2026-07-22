#!/usr/bin/env bash
# =============================================================================
# V127 UX-2 well-known infrastructure guard — deterministic test fixtures
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="v127_ux2_well_known_test"
# meta:type="test"
# meta:version="1.127.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-24"
# meta:description="Deterministic shell tests for V127 UX-2 lane (PR-B). Covers item 1.7 (nftban ban well-known IP guard with --yes override) and item 3.2 (nftban search advisory). Helper-library tests verify the inline well-known IP map: positive cases for Cloudflare 1.1.1.1, Google 8.8.8.8, Quad9 9.9.9.9, OpenDNS 208.67.222.222 + IPv6 variants 2606:4700:4700::1111 and 2001:4860:4860::8888; negative cases for TEST-NET 192.0.2.1 and 198.51.100.1 + documentation-prefix 2001:db8::1. cmd_ban.sh + cmd_search.sh integration assertions are code-pattern grep (full runtime behavior validation deferred to lab2/lab4 per umbrella scope §6)."
# meta:input="self-contained; sources nftban_well_known.sh in a subshell with strict mode tolerated"
# meta:output="t.Fatal-style stderr + exit 1 on first failed assertion; exit 0 if all UX-2 items pass"
# meta:depends="bash,grep"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="v127_ux2_well_known_test"
# meta:ta.owner="cli"
# meta:ta.module="well-known-guard"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
#
# Scope: AUDIT_190_LIFECYCLE/V127_FULL_UX_CORRECTION_UMBRELLA_SCOPE.md (UX-2 lane)
# =============================================================================

set -Eeuo pipefail
# Test harness intentionally continues past individual assertion failures.
set +e

# Test harness ----------------------------------------------------------------
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

# Locate the repo root (the test may be run from various working directories)
_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
export NFTBAN_LIB_DIR="${_repo_root}/cli/lib/nftban"

_helper_lib="${NFTBAN_LIB_DIR}/lib/nftban_well_known.sh"
_ban_cli="${NFTBAN_LIB_DIR}/cli/cmd_ban.sh"
_search_cli="${NFTBAN_LIB_DIR}/cli/cmd_search.sh"

echo "==============================================================================="
echo "V127 UX-2 well-known infrastructure guard — deterministic test fixtures"
echo "==============================================================================="
echo "  Repo root:    $_repo_root"
echo "  Helper:       $_helper_lib"
echo

# =============================================================================
# HELPER LIBRARY — IP map correctness
# =============================================================================
echo "[helper] nftban_well_known.sh — IP map + helper function"

if [[ ! -f "$_helper_lib" ]]; then
    _t_assert "helper lib exists" 1 "$_helper_lib not found"
else
    _t_assert "helper lib exists" 0
fi

# Positive cases (well-known IPs — must match)
for ip in 1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 9.9.9.9 149.112.112.112 208.67.222.222 208.67.220.220; do
    rc=0
    out=$(bash -c "source '$_helper_lib' && nftban_is_well_known_infra_ip '$ip'") || rc=$?
    if [[ "$rc" == "0" && -n "$out" ]]; then
        _t_assert "helper recognizes IPv4 $ip" 0
    else
        _t_assert "helper recognizes IPv4 $ip" 1 "rc=$rc out=[$out]"
    fi
done

# Positive cases — IPv6
for ip in '2606:4700:4700::1111' '2001:4860:4860::8888' '2620:fe::fe' '2620:119:35::35'; do
    rc=0
    out=$(bash -c "source '$_helper_lib' && nftban_is_well_known_infra_ip '$ip'") || rc=$?
    if [[ "$rc" == "0" && -n "$out" ]]; then
        _t_assert "helper recognizes IPv6 $ip" 0
    else
        _t_assert "helper recognizes IPv6 $ip" 1 "rc=$rc out=[$out]"
    fi
done

# Negative cases (TEST-NET + documentation prefix — must NOT match)
for ip in 192.0.2.1 198.51.100.1 203.0.113.1 '2001:db8::1' 10.0.0.1 192.168.1.1; do
    rc=0
    out=$(bash -c "source '$_helper_lib' && nftban_is_well_known_infra_ip '$ip'") || rc=$?
    if [[ "$rc" != "0" && -z "$out" ]]; then
        _t_assert "helper rejects non-well-known $ip" 0
    else
        _t_assert "helper rejects non-well-known $ip" 1 "rc=$rc out=[$out] (should be rc=1 + empty)"
    fi
done

# Provider name extraction
prov=$(bash -c "source '$_helper_lib' && nftban_well_known_provider '1.1.1.1'" 2>/dev/null || echo "")
if [[ "$prov" == "Cloudflare" ]]; then
    _t_assert "provider extraction for 1.1.1.1 returns 'Cloudflare'" 0
else
    _t_assert "provider extraction for 1.1.1.1 returns 'Cloudflare'" 1 "got [$prov]"
fi

prov=$(bash -c "source '$_helper_lib' && nftban_well_known_provider '8.8.8.8'" 2>/dev/null || echo "")
if [[ "$prov" == "Google" ]]; then
    _t_assert "provider extraction for 8.8.8.8 returns 'Google'" 0
else
    _t_assert "provider extraction for 8.8.8.8 returns 'Google'" 1 "got [$prov]"
fi

# Empty input + nonsense input must not match
rc=0
bash -c "source '$_helper_lib' && nftban_is_well_known_infra_ip ''" >/dev/null 2>&1 || rc=$?
if [[ "$rc" != "0" ]]; then
    _t_assert "helper rejects empty input" 0
else
    _t_assert "helper rejects empty input" 1 "rc=0 means empty matched"
fi

rc=0
bash -c "source '$_helper_lib' && nftban_is_well_known_infra_ip 'not-an-ip'" >/dev/null 2>&1 || rc=$?
if [[ "$rc" != "0" ]]; then
    _t_assert "helper rejects 'not-an-ip' string" 0
else
    _t_assert "helper rejects 'not-an-ip' string" 1 "rc=0 means garbage matched"
fi

# Warn-block output goes to stderr by default; switches to stdout on demand
out_stderr=$(bash -c "source '$_helper_lib' && nftban_well_known_warn_block '8.8.8.8' 2>&1 >/dev/null")
if grep -q "Well-known public infrastructure detected: 8.8.8.8" <<< "$out_stderr"; then
    _t_assert "warn_block default goes to stderr" 0
else
    _t_assert "warn_block default goes to stderr" 1 "expected stderr line not found"
fi

out_stdout=$(bash -c "source '$_helper_lib' && nftban_well_known_warn_block '8.8.8.8' stdout 2>/dev/null")
if grep -q "Well-known public infrastructure detected: 8.8.8.8" <<< "$out_stdout"; then
    _t_assert "warn_block stdout-mode goes to stdout" 0
else
    _t_assert "warn_block stdout-mode goes to stdout" 1 "expected stdout line not found"
fi
echo

# =============================================================================
# ITEM 1.7 — cmd_ban.sh well-known guard (code-pattern assertions)
# =============================================================================
echo "[1.7] cmd_ban.sh well-known infrastructure guard"

if grep -q 'V127 UX-2 item 1.7' "$_ban_cli"; then
    _t_assert "1.7 cmd_ban.sh contains UX-2 guard block" 0
else
    _t_assert "1.7 cmd_ban.sh contains UX-2 guard block" 1 "comment anchor missing"
fi

if grep -q 'nftban_is_well_known_infra_ip' "$_ban_cli"; then
    _t_assert "1.7 cmd_ban.sh calls helper function" 0
else
    _t_assert "1.7 cmd_ban.sh calls helper function" 1 "helper call missing"
fi

# V129 PR-C D7: the pre-fix condition `[[ "$auto_confirm" != "true" && "$dry_run" != "true" ]]`
# bypassed the guard in --dry-run mode (silently mis-confirming "would ban 8.8.8.8" on
# dry-run preview). The v1.129 corrected condition is auto_confirm-only — dry-run is
# ALSO refused unless --yes is set. See AUDIT_190_LIFECYCLE/V129_PR_B_LAB2_EXECUTION_REPORT.md
# §3 D7 + cli/lib/nftban/tests/v129_pr_c_runtime_defect_fixes_test.sh.
if grep -q 'if \[\[ "\$auto_confirm" != "true" \]\]; then' "$_ban_cli"; then
    _t_assert "1.7 guard refuses on dry-run AND live unless --yes (V129 PR-C D7 corrected)" 0
else
    _t_assert "1.7 guard refuses on dry-run AND live unless --yes (V129 PR-C D7 corrected)" 1 "post-V129-PR-C auto_confirm-only condition missing"
fi

if grep -q 'override accepted' "$_ban_cli"; then
    _t_assert "1.7 explicit --yes path logs override acknowledgement" 0
else
    _t_assert "1.7 explicit --yes path logs override acknowledgement" 1 "override-acknowledgement missing"
fi

# JSON mode emits structured refusal
if grep -q 'json_output "false".*Refused.*well-known' "$_ban_cli"; then
    _t_assert "1.7 JSON mode emits structured refusal" 0
else
    _t_assert "1.7 JSON mode emits structured refusal" 1 "json refusal pattern missing"
fi
echo

# =============================================================================
# ITEM 3.2 — cmd_search.sh Quick Actions advisory
# =============================================================================
echo "[3.2] cmd_search.sh Quick Actions advisory"

if grep -q 'V127 UX-2 item 3.2' "$_search_cli"; then
    _t_assert "3.2 cmd_search.sh contains UX-2 advisory block" 0
else
    _t_assert "3.2 cmd_search.sh contains UX-2 advisory block" 1 "comment anchor missing"
fi

if grep -q 'nftban_is_well_known_infra_ip' "$_search_cli"; then
    _t_assert "3.2 cmd_search.sh calls helper function" 0
else
    _t_assert "3.2 cmd_search.sh calls helper function" 1 "helper call missing"
fi

if grep -q 'well-known public infrastructure' "$_search_cli"; then
    _t_assert "3.2 advisory text present in cmd_search.sh" 0
else
    _t_assert "3.2 advisory text present in cmd_search.sh" 1 "advisory phrase missing"
fi

# Advisory appears BEFORE the Quick Actions header
# (so the operator reads warning context first, then the ban suggestion)
if awk '/V127 UX-2 item 3\.2/{found_advisory=1} /💡 Quick Actions:/{if(found_advisory){print "OK"; exit 0}}' "$_search_cli" | grep -q OK; then
    _t_assert "3.2 advisory positioned BEFORE Quick Actions header" 0
else
    _t_assert "3.2 advisory positioned BEFORE Quick Actions header" 1 "ordering wrong"
fi
echo

# =============================================================================
# OUT-OF-SCOPE GUARD — no UX-3..UX-6 surfaces touched
# =============================================================================
echo "[scope-creep guard] UX-3..UX-6 keywords absent from UX-2 diff"

# Verify the new helper does NOT contain anything that would belong to other lanes
for unwanted_pattern in "stats.*BLC" "RESYNC" "suricata.*desurface" "levenshtein" "Ctrl+C" "edit_distance"; do
    if grep -qiE "$unwanted_pattern" "$_helper_lib" 2>/dev/null; then
        _t_assert "scope-creep: '$unwanted_pattern' absent from helper" 1 "found scope-creep keyword"
    else
        _t_assert "scope-creep: '$unwanted_pattern' absent from helper" 0
    fi
done
echo

# =============================================================================
# SUMMARY
# =============================================================================
echo "==============================================================================="
echo "V127 UX-2 test summary: ${TESTS_PASSED} PASS, ${TESTS_FAILED} FAIL"
echo "==============================================================================="
if [[ "$TESTS_FAILED" -gt 0 ]]; then
    echo "FAILED tests:"
    for n in "${FAILED_NAMES[@]}"; do
        echo "  - $n"
    done
    exit 1
fi
exit 0
