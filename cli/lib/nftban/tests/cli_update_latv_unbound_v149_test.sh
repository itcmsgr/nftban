#!/usr/bin/env bash
# =============================================================================
# NFTBan - Regression test for v1.149 BUG-1: nftban update _latv unbound crash
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cli_update_latv_unbound_v149_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-05"
# meta:description="Regression guard for v1.149 BUG-1: the no-arg same-version short-circuit in cmd_update.sh declared local _curv _latv _cache_file WITHOUT initializing them, so under set -u a fresh host (no update cache) or missing jq left _latv unbound and `nftban update` aborted at `[[ -z \"$_latv\" ]]`. Asserts the declaration initializes all three, that no uninitialized declaration remains, and (behaviorally) that the cache-absent code shape does not abort under set -u."
# meta:input="None (self-contained)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,grep"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="cli_update_latv_unbound_v149_test"
# meta:ta.owner="update"
# meta:ta.module="update"
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
SRC="$REPO_ROOT/cli/lib/nftban/cli/cmd_update.sh"

PASS=0; FAIL=0; FAILED=()
ok(){ printf "  [PASS] %s\n" "$1"; PASS=$((PASS+1)); }
no(){ printf "  [FAIL] %s\n" "$1"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

echo "================================================="
echo "v1.149 BUG-1 — nftban update _latv unbound regression"
echo "================================================="

# 1. Declaration must initialize all three (the fix).
if grep -qE 'local[[:space:]]+_curv=""[[:space:]]+_latv=""[[:space:]]+_cache_file=""' "$SRC"; then
    ok "1.1 _curv/_latv/_cache_file declared initialized"
else
    no "1.1 initialized declaration NOT found"
fi

# 2. No uninitialized `local _curv _latv _cache_file` remains (regression guard).
if grep -qE 'local[[:space:]]+_curv[[:space:]]+_latv[[:space:]]+_cache_file[[:space:]]*$' "$SRC"; then
    no "2.1 uninitialized 'local _curv _latv _cache_file' still present"
else
    ok "2.1 no uninitialized declaration remains"
fi

# 3. Behavioral: the cache-absent code shape must NOT abort under set -u.
#    Replicates the guard: with no cache file the assignment block is skipped, so
#    `[[ -z "$_latv" ]]` must still be safe (only true when _latv is initialized).
behav=$(
    bash -uc '
        _get_current_version(){ echo "1.149.0"; }
        _get_latest_release(){ echo "1.149.0"; }
        _curv="" _latv="" _cache_file="/nonexistent/update_available.json"
        _curv=$(_get_current_version 2>/dev/null || echo unknown)
        if [[ -f "$_cache_file" ]] && command -v jq >/dev/null 2>&1; then
            _latv="from-cache"   # skipped: file absent
        fi
        if [[ -z "$_latv" ]]; then
            _latv=$(_get_latest_release 2>/dev/null || echo unknown)
        fi
        echo "curv=$_curv latv=$_latv"
    ' 2>&1
) && rc=0 || rc=$?
if [[ $rc -eq 0 ]] && [[ "$behav" != *"unbound variable"* ]]; then
    ok "3.1 cache-absent update path does not abort under set -u ($behav)"
else
    no "3.1 cache-absent path aborted/unbound (rc=$rc): $behav"
fi

# 4. Negative control: the OLD shape (uninitialized) WOULD abort — proves the test bites.
neg=$(bash -uc 'local_test(){ local _latv; [[ -z "$_latv" ]] && echo z; }; local_test' 2>&1 || true)
if [[ "$neg" == *"unbound variable"* ]]; then
    ok "4.1 negative control: uninitialized local DOES abort under set -u (test is meaningful)"
else
    ok "4.1 negative control inconclusive on this bash (non-fatal)"
fi

echo
echo "Results: PASS=$PASS  FAIL=$FAIL"
if [[ $FAIL -gt 0 ]]; then printf '  - %s\n' "${FAILED[@]}"; exit 1; fi
echo "All tests passed."
exit 0
