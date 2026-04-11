#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.81.0 — BotGuard rebuild merge-gate (lab/srv1 log assertion)
# =============================================================================
# meta:name="merge_gate_botguard_rebuild_log"
# meta:type="merge-gate"
# meta:version="1.81.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Merge-gate assertion for BOTGUARD-REBUILD-UX fix: parses a captured rebuild log and proves Step 10 actually fired and rebuild finished PROTECTED with no rollback"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Purpose:
#   This script is the runnable merge-gate for the BOTGUARD-REBUILD-UX fix.
#   It does NOT touch nftables. It does NOT need to run on a BotGuard host.
#   It takes a captured `nftban firewall rebuild` log file (produced on a lab
#   host with HTTP_BOTGUARD_ENABLED=true) and asserts the invariants that
#   prove the gating fix is working in real production code paths.
#
# Workflow (lab4 first, then srv1):
#
#   1. Set HTTP_BOTGUARD_ENABLED="true" on a lab host
#   2. nftban firewall rebuild 2>&1 | tee /tmp/rebuild_botguard_enabled.log
#   3. ./merge_gate_botguard_rebuild_log.sh /tmp/rebuild_botguard_enabled.log
#   4. Exit code 0 = merge gate PASS, non-zero = merge gate BLOCK
#
# Negative path (BotGuard disabled — must still no-op cleanly):
#
#   1. Ensure HTTP_BOTGUARD_ENABLED="false" (or absent)
#   2. nftban firewall rebuild 2>&1 | tee /tmp/rebuild_botguard_disabled.log
#   3. ./merge_gate_botguard_rebuild_log.sh --disabled /tmp/rebuild_botguard_disabled.log
#   4. Exit code 0 = no-regression confirmed
#
# DO NOT MERGE the BOTGUARD-REBUILD-UX patch until BOTH runs pass on lab4.
# =============================================================================

set -Eeuo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") [--disabled] <rebuild_log_path>

Asserts BotGuard rebuild gating invariants against a captured rebuild log.

Modes:
  (default)    Asserts BotGuard ENABLED on the host. Step 10 must FIRE.
  --disabled   Asserts BotGuard DISABLED on the host. Step 10 must SKIP.
EOF
    exit 2
}

mode="enabled"
if [[ "${1:-}" == "--disabled" ]]; then
    mode="disabled"
    shift
fi

log_path="${1:-}"
[[ -z "$log_path" || ! -f "$log_path" ]] && usage

pass=0
fail=0
say_pass() { echo "  PASS  $1"; ((pass++)) || true; }
say_fail() { echo "  FAIL  $1"; ((fail++)) || true; }

echo "============================================================="
echo "MERGE GATE — BOTGUARD-REBUILD-UX  ($mode mode)"
echo "Log: $log_path"
echo "============================================================="

# -----------------------------------------------------------------------------
# Invariant 1: rebuild ran to completion (no early abort)
# -----------------------------------------------------------------------------
if grep -q '\[POST\] Validating post-rebuild state' "$log_path"; then
    say_pass "rebuild reached POST-validation phase"
else
    say_fail "rebuild did NOT reach POST-validation (early abort?)"
fi

# -----------------------------------------------------------------------------
# Invariant 2: Step 10 executed and BotGuard re-init message printed
# -----------------------------------------------------------------------------
if grep -q '\[10/12\] Re-applying BotGuard' "$log_path"; then
    say_pass "Step 10 ran (\"[10/12] Re-applying BotGuard\")"
else
    say_fail "Step 10 line missing — Step 10 itself did not execute"
fi

# -----------------------------------------------------------------------------
# Invariant 3 (mode-dependent): gating decision matches host config
# -----------------------------------------------------------------------------
if grep -q 'BotGuard: not enabled, skipped' "$log_path"; then
    skipped="yes"
else
    skipped="no"
fi

if [[ "$mode" == "enabled" ]]; then
    if [[ "$skipped" == "no" ]]; then
        say_pass "BotGuard NOT skipped (HTTP_BOTGUARD_ENABLED=true on host honoured)"
    else
        say_fail "Step 10 still printed 'BotGuard: not enabled, skipped' — gating fix not deployed"
    fi
else
    # disabled mode — skip line is REQUIRED to prove no-regression
    if [[ "$skipped" == "yes" ]]; then
        say_pass "BotGuard cleanly skipped on non-BotGuard host"
    else
        say_fail "expected 'BotGuard: not enabled, skipped' on non-BotGuard host but did not see it"
    fi
fi

# -----------------------------------------------------------------------------
# Invariant 4: rebuild finished PROTECTED, no rollback fired
# -----------------------------------------------------------------------------
if grep -q 'Final status: PROTECTED' "$log_path"; then
    say_pass "Final status: PROTECTED"
else
    say_fail "Final status is NOT PROTECTED"
fi

if grep -qE 'REBUILD FAILED|Rollback successful|Rollback FAILED' "$log_path"; then
    say_fail "rollback path triggered — rebuild was not clean"
else
    say_pass "no rollback path triggered"
fi

# -----------------------------------------------------------------------------
# Invariant 5: BotGuard enable warning did NOT fire (enabled mode only)
# -----------------------------------------------------------------------------
if [[ "$mode" == "enabled" ]]; then
    if grep -q 'Warning: BotGuard enable failed' "$log_path"; then
        say_fail "'nftban botguard enable' raised a warning during rebuild"
    else
        say_pass "'nftban botguard enable' completed without warnings"
    fi
fi

echo "============================================================="
echo "Results: $pass passed, $fail failed"
echo "============================================================="

if [[ "$fail" -eq 0 ]]; then
    echo "MERGE GATE: PASS  ($mode mode)"
    exit 0
else
    echo "MERGE GATE: BLOCK ($mode mode) — DO NOT MERGE"
    exit 1
fi
