#!/usr/bin/env bash
# =============================================================================
# NFTBan - stdout/stderr contract test (v1.141 PR-B E1)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cli_stderr_contract_v141_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-28"
# meta:description="v1.141 PR-B E1 — asserts that the dispatcher's unknown-command ERROR block (banner + ERROR text + suggestion) goes to STDERR, leaving STDOUT clean for `nftban X 2>/dev/null`-style script consumers. Pre-v1.141 the banner+ERROR went to stdout, polluting any pipe consumer. Hermetic — no host contact; runs against the source tree."
# meta:input="cli/sbin/nftban dispatcher"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash"
# meta:inventory.files="cli/sbin/nftban"
# meta:inventory.binaries="bash"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../../../.." && pwd)
NFTBAN_SBIN="$REPO/cli/sbin/nftban"
export NFTBAN_LIB_DIR="$REPO/cli/lib/nftban"
export NFTBAN_NONINTERACTIVE=1
export NFTBAN_NO_BANNER=1   # exercise the suppression too — error still must hit stderr

[[ -x "$NFTBAN_SBIN" ]] || { echo "FAIL: missing $NFTBAN_SBIN" >&2; exit 1; }

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s (%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

# Run a subcommand and split stdout/stderr/rc. Returns via global vars.
run_split() {
    local cmd=("$@")
    local sb; sb=$(mktemp -d -t nftban-stdcap.XXXXXX)
    set +e
    bash "$NFTBAN_SBIN" "${cmd[@]}" >"$sb/out" 2>"$sb/err"
    LAST_RC=$?
    set -e
    LAST_OUT=$(cat "$sb/out")
    LAST_ERR=$(cat "$sb/err")
    rm -rf "$sb"
}

echo "=========================================================="
echo "v1.141 PR-B — E1 stderr contract (unknown-command path)"
echo "=========================================================="

echo "--- T1: nftban bogus-subcommand → ERROR text on STDERR, STDOUT clean ---"
run_split bogus-subcommand
if (( LAST_RC == 0 )); then
    no "T1 rc=$LAST_RC (expected non-zero on unknown command)" "rc check"
elif [[ "$LAST_OUT" == *"ERROR: Unknown command"* ]]; then
    no "T1 ERROR text leaked to STDOUT" "stdout had: ${LAST_OUT:0:120}…"
elif [[ "$LAST_ERR" != *"ERROR: Unknown command"* ]]; then
    no "T1 ERROR text MISSING from STDERR" "stderr: ${LAST_ERR:0:200}"
else
    ok "T1 ERROR on STDERR; STDOUT clean (rc=$LAST_RC)"
fi

echo "--- T2: STDOUT must not contain the unknown-command name ---"
# When a script does `nftban bogus 2>/dev/null | grep something`, stdout must be empty.
run_split totally-fake-cmd-name
if [[ "$LAST_OUT" == *"totally-fake-cmd-name"* ]]; then
    no "T2 STDOUT leaks the bogus command name" "stdout: ${LAST_OUT:0:120}…"
else
    ok "T2 STDOUT does not echo the bogus command name"
fi

echo "--- T3: STDERR contains the bogus command name ---"
if [[ "$LAST_ERR" == *"totally-fake-cmd-name"* ]]; then
    ok "T3 STDERR contains the bogus command name (user feedback intact)"
else
    no "T3 STDERR missing bogus name" "stderr: ${LAST_ERR:0:200}"
fi

echo "--- T4: known valid subcommand keeps STDOUT useful ---"
# `nftban version` should put its version line on STDOUT.
run_split version --no-banner
if [[ "$LAST_OUT" =~ [0-9]+\.[0-9]+\.[0-9]+ ]]; then
    ok "T4 nftban version --no-banner emits version on STDOUT"
elif [[ "$LAST_OUT" == *"NFTBan"* ]]; then
    ok "T4 nftban version --no-banner emits 'NFTBan' on STDOUT (no version regex match — accepted)"
else
    no "T4 STDOUT empty / unexpected" "stdout: ${LAST_OUT:0:120}…"
fi

echo "=========================================================="
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
if (( FAIL > 0 )); then
    printf 'FAILED: %s\n' "${FAILED[@]}"
    exit 1
fi
echo "ALL PASS"
