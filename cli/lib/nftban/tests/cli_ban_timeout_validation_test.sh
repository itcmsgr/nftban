#!/usr/bin/env bash
# =============================================================================
# NFTBan - ban --timeout parser validation test (v1.141 PR-A BUG-A7/A8)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cli_ban_timeout_validation_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-28"
# meta:description="v1.141 PR-A — asserts that `nftban ban X --timeout VALUE` rejects every non-positive-integer VALUE at parse time with rc=1 and a clear ERROR message, and accepts every positive integer (parse-time only — downstream daemon IPC is out of scope for this test). Prior to v1.141, the --timeout arm at cli/lib/nftban/cli/cmd_ban.sh:86-89 had no validation; values like 'abc' / '-5' / '0' / '' / '1.5' propagated to nftban-core which interpreted invalid values as permanent ban — operator surprise reproduced live in the cruel-judge review on observability-node-01.example.test. Hermetic — runs against the source tree."
# meta:input="cli/lib/nftban/cli/cmd_ban.sh + cli/sbin/nftban"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep"
# meta:inventory.files="cli/lib/nftban/cli/cmd_ban.sh,cli/sbin/nftban"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="cli_ban_timeout_validation_test"
# meta:ta.owner="cli"
# meta:ta.module="ban"
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
REPO=$(cd "$SCRIPT_DIR/../../../.." && pwd)
NFTBAN_SBIN="$REPO/cli/sbin/nftban"
export NFTBAN_LIB_DIR="$REPO/cli/lib/nftban"
export NFTBAN_NONINTERACTIVE=1
export NFTBAN_NO_BANNER=1

[[ -x "$NFTBAN_SBIN" ]] || { echo "FAIL: missing $NFTBAN_SBIN" >&2; exit 1; }

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s (%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

# Invariant: invalid values must rc!=0 AND stderr must mention "--timeout".
assert_reject(){
    local label="$1" value="$2"
    local rc=0 out
    out=$(bash "$NFTBAN_SBIN" ban 10.0.0.1 --timeout "$value" 2>&1) || rc=$?
    if (( rc == 0 )); then
        no "$label" "rc=0 (expected non-zero on invalid timeout=$value)"
    elif [[ "$out" != *"--timeout"* ]]; then
        no "$label" "rc=$rc but stderr missing '--timeout' marker"
    elif [[ "$out" != *"ERROR"* && "$out" != *"Error"* ]]; then
        no "$label" "rc=$rc but stderr missing ERROR marker"
    else
        ok "$label (rc=$rc, ERROR mentions --timeout)"
    fi
}

# Invariant: valid positive integer must NOT be rejected by the parser. The
# command may still fail downstream (no daemon in dev env), but the failure
# must NOT be a parser-side --timeout rejection. We check stderr does NOT
# contain "--timeout requires a positive integer".
assert_accept(){
    local label="$1" value="$2"
    local rc=0 out
    out=$(bash "$NFTBAN_SBIN" ban 10.0.0.1 --timeout "$value" 2>&1) || rc=$?
    if [[ "$out" == *"--timeout requires a positive integer"* ]]; then
        no "$label" "parser rejected valid timeout=$value: $out"
    else
        ok "$label (valid timeout=$value passes parser; rc=$rc downstream)"
    fi
}

echo "=========================================================="
echo "v1.141 PR-A — ban --timeout validation test"
echo "=========================================================="

echo "--- invalid values must rc!=0 with --timeout ERROR ---"
assert_reject "T1 abc (non-integer)"                  "abc"
assert_reject "T2 -5 (negative)"                       "-5"
assert_reject "T3 0 (zero)"                             "0"
assert_reject "T4 1.5 (float)"                          "1.5"
assert_reject "T5 +10 (signed positive — strict positive int)" "+10"
assert_reject "T6 1e3 (scientific notation)"            "1e3"
assert_reject "T7 0x10 (hex)"                            "0x10"
assert_reject "T8 01 (leading zero)"                     "01"

echo "--- valid positive integers must pass parser ---"
assert_accept "T9 1 (smallest valid)"                    "1"
assert_accept "T10 60 (one minute)"                     "60"
assert_accept "T11 3600 (one hour)"                     "3600"
assert_accept "T12 86400 (one day)"                     "86400"

echo "=========================================================="
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
if (( FAIL > 0 )); then
    printf 'FAILED: %s\n' "${FAILED[@]}"
    exit 1
fi
echo "ALL PASS"
