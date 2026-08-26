#!/usr/bin/env bash
# =============================================================================
# NFTBan - maintenance step 9d config precondition (v1.229.8 PR-2)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="maintenance_stats_config_precondition_v1229_8_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-24"
# meta:description="Pins OPEN_MAINTENANCE_SANDBOX_NFT_OBSERVATION_RESTART_LOOP. maintenance.sh step 9d sourced nftban_stats_format.sh (the consumer) without nftban_stats.sh (which defines NFTBAN_BAN_LOG and NFTBAN_STATS_SNAPSHOTS_DIR). Under set -u the first dereference terminated the whole run before step 10, so the unit exited 1 and systemd restarted it forever."
# meta:ta.id="maintenance_stats_config_precondition_v1229_8_test"
# meta:ta.owner="core"
# meta:ta.module="maintenance-orchestration"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.blocking="true"
# meta:ta.timeout="60"
# meta:ta.hermetic="true"
# meta:ta.requires_systemd="false"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:inventory.files="cli/lib/nftban/cron/maintenance.sh,cli/lib/nftban/core/nftban_stats.sh,cli/lib/nftban/core/nftban_stats_format.sh"
# meta:inventory.binaries="bash,awk,grep"
# meta:inventory.env_vars="NFTBAN_BAN_LOG,NFTBAN_STATS_SNAPSHOTS_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units="nftban-maintenance.service"
# meta:inventory.network=""
# meta:inventory.privileges="none (read-only)"
#
# ⛔ THE RULE THIS DEFECT TEACHES:
#   AN `if` CONDITION SUPPRESSES `set -e`.
#   IT DOES NOT MAKE AN UNBOUND VARIABLE SAFE UNDER `set -u`.
# The call was guarded by `if` AND redirected to /dev/null, and still killed the
# process. Any guard that reasons only about `set -e` will miss this class.
# =============================================================================
set -Eeuo pipefail

ROOT="${NFTBAN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
SRC="$ROOT/cli/lib/nftban/cron/maintenance.sh"
FAILURES=0
fail() { FAILURES=$((FAILURES + 1)); echo "  FAIL  $1"; }
ok()   { echo "  ok    $1"; }

[[ -f "$SRC" ]] || { echo "::error::SUBJECT_NOT_FOUND: $SRC"; exit 1; }

# The subject is the 9d block only, comments stripped: a dependency named in a
# comment is documentation, not a load.   MENTION != LOAD
block="$(awk '/nftban_stats_format\.sh/{i=1} i{print} i&&/^    fi$/{exit}' "$SRC" | sed 's/[[:space:]]*#.*$//')"

echo "=== maintenance step 9d config precondition (v1.229.8 PR-2) ==="
echo ""
echo "1. the canonical dependency is loaded BEFORE its consumer"
# ⛔ Compare the SOURCE statements, not every mention. The block opens with an
# `[[ -f ...format.sh ]]` existence test, so matching any occurrence made the
# consumer look like it came first and the guard failed on correct code.
#   EXISTENCE TEST != LOAD
dep_ln="$(grep -n "^[[:space:]]*source .*core/nftban_stats\.sh" <<<"$block" | head -1 | cut -d: -f1 || true)"
con_ln="$(grep -n "^[[:space:]]*source .*core/nftban_stats_format\.sh" <<<"$block" | head -1 | cut -d: -f1 || true)"
call_ln="$(grep -n "nftban_stats_cleanup_logs" <<<"$block" | head -1 | cut -d: -f1 || true)"
if [[ -z "$call_ln" ]]; then
    fail "subject invalid — step 9d no longer calls nftban_stats_cleanup_logs"
elif [[ -z "$dep_ln" ]]; then
    fail "step 9d loads the consumer without nftban_stats.sh — NFTBAN_BAN_LOG/NFTBAN_STATS_SNAPSHOTS_DIR stay unset and \`set -u\` kills the run before step 10"
elif (( dep_ln < con_ln && dep_ln < call_ln )); then
    ok "nftban_stats.sh sourced (line $dep_ln) before the consumer ($con_ln) and the call ($call_ln)"
else
    fail "nftban_stats.sh is loaded at line $dep_ln, not before consumer ($con_ln)/call ($call_ln) — LOADED AFTER USE IS NOT LOADED"
fi

echo ""
echo "2. the required config is asserted before the call, and never defaulted"
if grep -q 'NFTBAN_BAN_LOG' <<<"$block" && grep -q 'NFTBAN_STATS_SNAPSHOTS_DIR' <<<"$block"; then
    ok "step 9d checks both required variables before invoking cleanup"
else
    fail "step 9d does not assert its required config — UNSET REQUIRED CONFIG != EMPTY/DEFAULT VALUE"
fi
if grep -qE 'NFTBAN_BAN_LOG:=|NFTBAN_STATS_SNAPSHOTS_DIR:=' <<<"$block"; then
    fail "step 9d DEFAULTS a required path — inventing one hides the orchestration defect and aims a delete-by-age sweep at an unconfigured directory"
else
    ok "no invented defaults for required paths"
fi

echo ""
echo "3. the leaf function still declares its dependency (not silently tolerant)"
fmt="$ROOT/cli/lib/nftban/core/nftban_stats_format.sh"
if [[ -f "$fmt" ]] && grep -qE 'NFTBAN_BAN_LOG:=|NFTBAN_STATS_SNAPSHOTS_DIR:=' "$fmt"; then
    fail "nftban_stats_format.sh now defaults the required config — the leaf must not absorb an orchestration defect"
else
    ok "leaf function does not invent defaults for required authority fields"
fi

echo ""
echo "4. set -u discipline is preserved in the subject"
if head -40 "$SRC" | grep -qE '^set -[A-Za-z]*u|set -o nounset'; then
    ok "maintenance.sh still runs under set -u (the discipline that exposed this)"
else
    fail "maintenance.sh no longer runs under set -u — weakening the discipline is not a fix for the defect it revealed"
fi

echo ""
if [[ $FAILURES -gt 0 ]]; then
    echo "::error::maintenance stats config precondition FAILED: $FAILURES"
    exit 1
fi
echo "maintenance stats config precondition PASSED"
