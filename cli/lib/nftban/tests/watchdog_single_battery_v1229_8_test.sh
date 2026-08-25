#!/usr/bin/env bash
# =============================================================================
# NFTBan - one activation, one check battery (v1.229.8 PR-1)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="watchdog_single_battery_v1229_8_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-24"
# meta:description="Pins OPEN_WATCHDOG_DUPLICATE_FULL_BATTERY_PER_ACTIVATION: a watchdog activation must execute the full check battery EXACTLY ONCE, and trend collection must consume that battery's results only when it can PROVE they belong to this activation. Counts real invocations via a stub; it does not trust the call graph."
# meta:ta.id="watchdog_single_battery_v1229_8_test"
# meta:ta.owner="health"
# meta:ta.module="watchdog-orchestration"
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
# meta:inventory.files="cli/lib/nftban/core/nftban_watchdog.sh"
# meta:inventory.binaries="bash,awk,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none (read-only)"
#
# ⛔ COUNT EXECUTIONS, DO NOT READ THE CALL GRAPH.
# "run_all appears once in this function" is a statement about text. The defect was
# that ONE activation reached run_all TWICE through two different functions, each of
# which looked correct on its own. Only counting real invocations can catch that.
#   CALL SITE COUNT != EXECUTION COUNT
# =============================================================================
set -Eeuo pipefail

ROOT="${NFTBAN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
SRC="$ROOT/cli/lib/nftban/core/nftban_watchdog.sh"
FAILURES=0
fail() { FAILURES=$((FAILURES + 1)); echo "  FAIL  $1"; }
ok()   { echo "  ok    $1"; }

[[ -f "$SRC" ]] || { echo "::error::SUBJECT_NOT_FOUND: $SRC"; exit 1; }

# harness <mutation-sed-or-empty> -- prints "count=<n> trendpoints=<n>"
# Extracts the two functions under test and drives them against stubs, so the
# battery is never really executed.
harness() {
    local mutate="${1:-}"
    bash --noprofile --norc -c '
        set -uo pipefail
        src="$1"; mutate="$2"
        work="$(mktemp)"; cp "$src" "$work"
        [[ -n "$mutate" ]] && sed -i "$mutate" "$work"

        declare -gA WATCHDOG_RESULTS=()
        declare -ga WATCHDOG_ALERTS=()
        RUN_ALL_CALLS=0
        TREND_POINTS=0

        # Extract ONLY the two subjects; everything else is stubbed.
        eval "$(awk "/^nftban_watchdog_trend_collect\\(\\) \\{/{i=1} i{print} i&&/^\\}/{exit}" "$work")"

        # Stub the battery: count invocations and populate as the real one does.
        nftban_watchdog_run_all() {
            RUN_ALL_CALLS=$((RUN_ALL_CALLS+1))
            WATCHDOG_RESULTS[check_timestamp]="$(date +%s)"
            WATCHDOG_RESULTS[overall_status]=0
            WATCHDOG_RESULTS[run_id]="stub.$RUN_ALL_CALLS"
            return 0
        }
        mkdir -p /tmp/wdt.$$ ; NFTBAN_DATA_DIR=/tmp/wdt.$$
        NFTBAN_WATCHDOG_TREND_DIR=/tmp/wdt.$$/watchdog
        NFTBAN_WATCHDOG_TREND_FILE=$NFTBAN_WATCHDOG_TREND_DIR/trend_hourly.json
        NFTBAN_WATCHDOG_TREND_RETENTION=168
        watchdog_log() { :; }

        # Simulate ONE activation: battery, then trend collection with identity.
        nftban_watchdog_run_all >/dev/null 2>&1 || true
        nftban_watchdog_trend_collect "${WATCHDOG_RESULTS[run_id]:-}" >/dev/null 2>&1 || true

        [[ -s "$NFTBAN_WATCHDOG_TREND_FILE" ]] && TREND_POINTS=1
        echo "count=$RUN_ALL_CALLS trendpoints=$TREND_POINTS"
        rm -rf /tmp/wdt.$$ "$work"
    ' _ "$SRC" "$mutate" 2>/dev/null
}

echo "=== one activation, one check battery (v1.229.8 PR-1) ==="
echo ""
echo "P. positive — a normal activation runs the battery exactly once"
out="$(harness "")"
cnt="${out#count=}"; cnt="${cnt%% *}"
if [[ "$cnt" == "1" ]]; then
    ok "P run_all executed exactly once per activation ($out)"
else
    fail "P run_all executed $cnt times per activation — expected 1 ($out)"
fi

echo ""
echo "N1. trend collection must not invent current data when none exists"
# Present an identity that does NOT match, and make the fallback battery produce
# nothing: trend_collect must record no point rather than a fabricated one.
out_n1="$(bash --noprofile --norc -c '
    set -uo pipefail
    src="$1"
    declare -gA WATCHDOG_RESULTS=()
    eval "$(awk "/^nftban_watchdog_trend_collect\\(\\) \\{/{i=1} i{print} i&&/^\\}/{exit}" "$src")"
    nftban_watchdog_run_all() { return 0; }   # runs, populates NOTHING
    mkdir -p /tmp/wdn1.$$
    NFTBAN_WATCHDOG_TREND_DIR=/tmp/wdn1.$$; NFTBAN_WATCHDOG_TREND_FILE=/tmp/wdn1.$$/t.json
    NFTBAN_WATCHDOG_TREND_RETENTION=168; watchdog_log() { :; }
    nftban_watchdog_trend_collect "nonmatching-id" >/dev/null 2>&1 || true
    if [[ -s "$NFTBAN_WATCHDOG_TREND_FILE" ]]; then echo INVENTED; else echo NO_POINT; fi
    rm -rf /tmp/wdn1.$$
' _ "$SRC" 2>/dev/null)"
if [[ "$out_n1" == "NO_POINT" ]]; then
    ok "N1 no current battery -> no trend point written (did not invent data)"
else
    fail "N1 trend point written with NO current observation — INVENTED DATA"
fi

echo ""
echo "N2. restoring the duplicate battery must be DETECTED"
# Re-introduce the shipped defect: make trend_collect always run its own battery.
out_n2="$(harness 's/^    if \[\[ -n "\$expect_run" .*$/    if false; then/')"
cnt2="${out_n2#count=}"; cnt2="${cnt2%% *}"
if [[ "$cnt2" == "1" ]]; then
    fail "N2 MUTATION NOT DETECTED — duplicate battery restored and the count still read 1 ($out_n2)"
elif [[ -z "$cnt2" ]]; then
    fail "N2 CONTROL INVALID — harness produced no count ($out_n2)"
else
    ok "N2 duplicate battery detected (count=$cnt2 with the defect restored)"
fi

echo ""
if [[ $FAILURES -gt 0 ]]; then
    echo "::error::watchdog single-battery contract FAILED: $FAILURES"
    exit 1
fi
echo "watchdog single-battery contract PASSED (P + N1 + N2)"
