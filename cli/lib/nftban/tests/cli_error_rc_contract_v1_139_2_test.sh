#!/usr/bin/env bash
# =============================================================================
# NFTBan - CLI exit-code contract test (v1.139.2 hotfix)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cli_error_rc_contract_v1_139_2_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-28"
# meta:description="v1.139.2 hotfix test — locks the CLI exit-code contract. The UX Honest Cruel Judge Review of v1.139.1 (NFTBAN_ROADMAP/139_1_ROLLOUT/UX_HONEST_CRUEL_JUDGE_REVIEW_V1_139_1.md) reported four error paths returning rc=0 while printing ERROR/validation text — a class of bug where the CLI lies to automation. Pre-commit verification against the source tree at main@3ba23da9 found ALL FOUR paths already return rc=1; the review's rc=0 evidence likely reflects an older installed binary or wrapper. This test locks the current correct behavior as the contract so future PRs cannot regress: bogus-subcommand, ban (no arg), ban (invalid IP), update --dry-run all must return rc>=1; version, help, and rollback --help must remain rc=0. Hermetic — runs against the source tree, no host contact, no installed binary required."
# meta:input="cli/sbin/nftban + cli/lib/nftban/cli/*.sh"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash"
# meta:inventory.files="cli/sbin/nftban,cli/lib/nftban/cli/cmd_ban.sh,cli/lib/nftban/cli/cmd_update.sh"
# meta:inventory.binaries="bash"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_NONINTERACTIVE,NFTBAN_NO_BANNER"
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
NFTBAN_LIB_DIR="$REPO/cli/lib/nftban"

[[ -x "$NFTBAN_SBIN" ]] || { echo "FAIL: cannot find $NFTBAN_SBIN" >&2; exit 1; }
[[ -d "$NFTBAN_LIB_DIR" ]] || { echo "FAIL: cannot find $NFTBAN_LIB_DIR" >&2; exit 1; }

export NFTBAN_LIB_DIR
export NFTBAN_NONINTERACTIVE=1
export NFTBAN_NO_BANNER=1

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s (%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

run_rc(){
    # Run the CLI with the given args and capture rc. Use bash -c to keep set -e
    # at the test level from being inherited into the subprocess.
    local rc=0
    bash "$NFTBAN_SBIN" "$@" >/dev/null 2>&1 || rc=$?
    printf '%s' "$rc"
}

run_capture(){
    # Capture stdout+stderr + rc for paths where we assert output content.
    bash "$NFTBAN_SBIN" "$@" 2>&1 || true
}

echo "=========================================================="
echo "V1.139.2 hotfix: CLI exit-code contract test"
echo "=========================================================="

# -----------------------------------------------------------------------------
# Tier-0 LIES (must return rc>=1; documented by UX review + locked here)
# -----------------------------------------------------------------------------
echo "--- tier-0 lies (must rc>=1) ---"

# T1: bogus subcommand
rc=$(run_rc bogus-subcommand)
if (( rc >= 1 )); then ok "T1 nftban bogus-subcommand → rc=$rc (must be >=1)"
else no "T1 nftban bogus-subcommand → rc=$rc (LIE: expected >=1)" "regression"; fi

# T2: ban with no arg
rc=$(run_rc ban)
if (( rc >= 1 )); then ok "T2 nftban ban (no arg) → rc=$rc (must be >=1)"
else no "T2 nftban ban (no arg) → rc=$rc (LIE: expected >=1)" "regression"; fi

# T3: ban with invalid IP octet >255
rc=$(run_rc ban 999.0.0.1)
if (( rc >= 1 )); then ok "T3 nftban ban 999.0.0.1 → rc=$rc (must be >=1)"
else no "T3 nftban ban 999.0.0.1 → rc=$rc (LIE: expected >=1)" "regression"; fi

# T4: update --dry-run (unimplemented flag)
rc=$(run_rc update --dry-run)
if (( rc >= 1 )); then ok "T4 nftban update --dry-run → rc=$rc (must be >=1)"
else no "T4 nftban update --dry-run → rc=$rc (LIE: expected >=1)" "regression"; fi

# -----------------------------------------------------------------------------
# Output-content asserts on lies (must mention error AND emit non-zero)
# Prevents a future PR from "fixing" rc by silencing the error message.
# -----------------------------------------------------------------------------
echo "--- tier-0 output content ---"

out=$(run_capture bogus-subcommand)
if [[ "$out" == *"Unknown command"* || "$out" == *"Did you mean"* || "$out" == *"ERROR"* ]]; then
    ok "T5 bogus-subcommand prints error indication"
else
    no "T5 bogus-subcommand prints error indication" "no ERROR/Unknown/Did-you-mean in output"
fi

out=$(run_capture ban 999.0.0.1)
if [[ "$out" == *"ERROR"* || "$out" == *"invalid"* || "$out" == *"Invalid"* ]]; then
    ok "T6 ban 999.0.0.1 prints validation rejection"
else
    no "T6 ban 999.0.0.1 prints validation rejection" "no ERROR/invalid in output"
fi

# -----------------------------------------------------------------------------
# Tier-0 TRUTHS (must remain rc=0)
# -----------------------------------------------------------------------------
echo "--- tier-0 truths (must rc=0) ---"

rc=$(run_rc version)
if (( rc == 0 )); then ok "T7 nftban version → rc=0 (control)"
else no "T7 nftban version → rc=$rc (control broke)" "expected 0"; fi

rc=$(run_rc help)
if (( rc == 0 )); then ok "T8 nftban help → rc=0 (control)"
else no "T8 nftban help → rc=$rc (control broke)" "expected 0"; fi

# T9 — rollback --help (cross-validates the v1.139.2 rollback-help-guard fix)
rc=$(run_rc rollback --help)
if (( rc == 0 )); then ok "T9 nftban rollback --help → rc=0 (v1.139.2 help-guard intact)"
else no "T9 nftban rollback --help → rc=$rc" "expected 0; v1.139.2 rollback help-guard regressed"; fi

# T10 — extra negative control: rollback --help output is help text, NOT
# rollback execution. Ensures the help-guard doesn't just exit 0 silently —
# it actually prints help.
out=$(run_capture rollback --help)
if [[ "$out" == *"nftban rollback"* && "$out" != *"Rolling back to"* && "$out" != *"Looking for backups"* ]]; then
    ok "T10 rollback --help output is help text (no rollback executed)"
else
    no "T10 rollback --help output is help text" "missing help text or work-marker present"
fi

echo "=========================================================="
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
if (( FAIL > 0 )); then
    printf 'FAILED: %s\n' "${FAILED[@]}"
    exit 1
fi
echo "ALL PASS"
