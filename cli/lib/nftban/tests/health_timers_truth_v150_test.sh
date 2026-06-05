#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.150 Lane A (shell CLI health truth-telling)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="health_timers_truth_v150_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-05"
# meta:description="Tests for v1.150 Lane A health/timer truth-telling. Asserts HLT-04 (a failed-but-enabled service is added to missing_required so verify returns non-zero, instead of being counted OK in the ENABLED-stopped branch), 13.7(a) (the watchdog trend enable-timer hint is suppressed when the maintenance timer is enabled, replaced by a data-accrues note), TMR-02 (NFTBAN_TIMERS lists the 6 previously-omitted shipped timers), and TMR-01 (nftban_enable_all's force-enabled core_timers set excludes the apply/confirm-managed rollback + snapshot timers). Real systemctl state transitions (actual is-failed/is-enabled on a host) are lab integration tests."
# meta:input="None (self-contained sandbox)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,grep,awk,sed,jq"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,awk,sed,jq"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Self-contained sandbox; no host contact; no root required. We extract the
# target functions from the source files by name, stub `systemctl` as a bash
# function that returns scripted unit states, and assert behavior. No live
# systemd, nft, or daemon is touched.
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
NFTBAN_LIB_DIR="${REPO_ROOT}/cli/lib/nftban"
export NFTBAN_LIB_DIR

HEALTH_SRC="$NFTBAN_LIB_DIR/core/nftban_health.sh"
WATCHDOG_SRC="$NFTBAN_LIB_DIR/core/nftban_watchdog.sh"
TIMERS_SRC="$NFTBAN_LIB_DIR/cli/cmd_timers.sh"
SVCCTL_SRC="$NFTBAN_LIB_DIR/lib/service_control.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

assert_contains() {
    local haystack="$1" needle="$2" name="$3"
    if printf '%s' "$haystack" | grep -F -q -- "$needle"; then
        printf "  [PASS] %s\n" "$name"; PASS=$((PASS + 1))
    else
        printf "  [FAIL] %s\n         expected to contain: %s\n" "$name" "$needle"
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
    fi
}
assert_not_contains() {
    local haystack="$1" needle="$2" name="$3"
    if printf '%s' "$haystack" | grep -F -q -- "$needle"; then
        printf "  [FAIL] %s\n         did NOT expect: %s\n" "$name" "$needle"
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
    else
        printf "  [PASS] %s\n" "$name"; PASS=$((PASS + 1))
    fi
}
assert_eq() {
    local actual="$1" expected="$2" name="$3"
    if [[ "$actual" == "$expected" ]]; then
        printf "  [PASS] %s\n" "$name"; PASS=$((PASS + 1))
    else
        printf "  [FAIL] %s (expected '%s', got '%s')\n" "$name" "$expected" "$actual"
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
    fi
}

# Extract a single shell function (name() { ... }) from a source file: from the
# line that begins the definition to the first top-level closing brace.
extract_func() {
    local file="$1" fname="$2"
    awk -v f="^${fname}\\\\(\\\\)" '
        $0 ~ f {c=1}
        c {print}
        c && /^}/ {exit}
    ' "$file"
}

echo "================================================="
echo "v1.150 Lane A health/timer truth-telling test suite"
echo "================================================="

# ---------------------------------------------------------------------------
# T1 (HLT-04): a failed-but-enabled REQUIRED service is added to
# missing_required, so verify returns non-zero (INCOMPLETE / rc 2).
# Stub systemctl: nftband.service is installed + enabled + is-failed=true.
# Everything else: installed sets return rc1 so they fail harmlessly (the only
# thing under test is that the FAILED service is NOT swallowed as OK).
# ---------------------------------------------------------------------------
echo; echo "[T1] HLT-04: failed-but-enabled service → missing_required (rc≠0)"

run_verify_failed_svc() {
    (
        set +eu
        # The distro-config loader (which populates DISTRO_PATHS) is guarded out
        # in the sandbox; declare it empty so the function's :- guards resolve.
        # (Consumed by the eval'd verify function below — invisible to shellcheck.)
        # shellcheck disable=SC2034
        declare -A DISTRO_PATHS=()
        # Scripted systemctl: model nftband.service as installed, enabled, FAILED.
        systemctl() {
            local cmd="$1"; shift
            case "$cmd" in
                list-unit-files)
                    # Echo the queried unit name so the grep "^unit" passes
                    # (i.e. report the unit as installed).
                    printf '%s\n' "$1"
                    return 0
                    ;;
                is-failed)
                    # --quiet is $1, unit is $2
                    [[ "$2" == "nftband.service" ]] && return 0
                    return 1
                    ;;
                is-active)  return 1 ;;
                is-enabled)
                    [[ "$2" == "nftband.service" ]] && return 0
                    return 1
                    ;;
            esac
            return 1
        }
        # Neutralize schema/distro sourcing side-effects already handled by guards.
        eval "$(extract_func "$HEALTH_SRC" nftban_health_verify_installation)"
        # Provide the HEALTH_* status constants the function does not declare itself.
        nftban_health_verify_installation 0
        echo "VERIFY_RC=$?"
    )
}

T1_OUT=$(run_verify_failed_svc 2>&1) || true
assert_contains "$T1_OUT" "nftband.service"          "T1.0 service line present"
assert_contains "$T1_OUT" "FAILED"                   "T1.1 service reported FAILED"
assert_contains "$T1_OUT" "INSTALLATION INCOMPLETE"  "T1.2 overall verdict INCOMPLETE"
assert_contains "$T1_OUT" "Service: nftband.service FAILED" "T1.3 added to missing_required list"
assert_contains "$T1_OUT" "VERIFY_RC=2"              "T1.4 verify returns rc=2 (BROKEN)"

# ---------------------------------------------------------------------------
# T2 (HLT-04 regression guard): a clean enabled-but-stopped service is still
# counted OK (the failed-check must not over-trigger on healthy units).
# ---------------------------------------------------------------------------
echo; echo "[T2] HLT-04 guard: enabled+stopped (not failed) service stays OK"

run_verify_stopped_svc() {
    (
        set +eu
        # shellcheck disable=SC2034  # consumed by the eval'd verify function
        declare -A DISTRO_PATHS=()
        systemctl() {
            local cmd="$1"; shift
            case "$cmd" in
                list-unit-files) printf '%s\n' "$1"; return 0 ;;
                is-failed)  return 1 ;;            # nothing failed
                is-active)  return 1 ;;            # not running
                is-enabled) return 0 ;;            # everything enabled
            esac
            return 1
        }
        eval "$(extract_func "$HEALTH_SRC" nftban_health_verify_installation)"
        # Capture output for the ENABLED(stopped) assertion (trailing : keeps
        # the subshell exit status zero so the outer command-substitution
        # assignment does not trip set -e).
        nftban_health_verify_installation 0
        :
    )
}
T2_OUT=$(run_verify_stopped_svc 2>&1) || true
assert_contains "$T2_OUT" "ENABLED (stopped)"                  "T2.1 stopped service shown as enabled"
assert_not_contains "$T2_OUT" "Service: nftband.service FAILED" "T2.2 not flagged as FAILED when healthy"

# ---------------------------------------------------------------------------
# T3 (13.7a): watchdog trend hint suppressed when maintenance timer is ENABLED.
# Stub trend averages/thresholds to report 0 samples and systemctl is-enabled
# = true (rc 0) → expect the "data accrues" note, NOT the enable-timer hint.
# ---------------------------------------------------------------------------
echo; echo "[13.7a] trend hint gated on maintenance.timer being disabled"

run_trend_display() {
    local enabled_rc="$1"
    (
        set +eu
        systemctl() {
            local cmd="$1"; shift
            case "$cmd" in
                is-enabled)
                    # --quiet is $1, unit is $2 → return scripted state
                    return "$enabled_rc"
                    ;;
            esac
            return 1
        }
        nftban_watchdog_trend_averages()   { echo '{"samples":0}'; }
        nftban_watchdog_trend_thresholds() { echo '{}'; }
        eval "$(extract_func "$WATCHDOG_SRC" nftban_watchdog_trend_display)"
        nftban_watchdog_trend_display
    )
}

# Timer ENABLED (is-enabled rc=0) → hint suppressed, accrues-note shown.
T3A=$(run_trend_display 0 2>&1) || true
assert_not_contains "$T3A" "Enable timer: nftban timers enable" "13.7a.1 enable hint suppressed when timer enabled"
assert_contains "$T3A" "data accrues after the next maintenance cycle" "13.7a.2 accrues note shown when enabled"

# Timer DISABLED (is-enabled rc=1) → original enable hint shown.
T3B=$(run_trend_display 1 2>&1) || true
assert_contains "$T3B" "Enable timer: nftban timers enable nftban-maintenance.timer" "13.7a.3 enable hint shown when timer disabled"
assert_not_contains "$T3B" "data accrues after the next maintenance cycle" "13.7a.4 accrues note absent when disabled"

# ---------------------------------------------------------------------------
# T4 (TMR-02): NFTBAN_TIMERS includes the 6 previously-omitted shipped timers.
# ---------------------------------------------------------------------------
echo; echo "[TMR-02] NFTBAN_TIMERS contains the 6 added units"

# Pull just the readonly NFTBAN_TIMERS=( ... ) block to evaluate it safely.
timers_block=$(awk '/^readonly NFTBAN_TIMERS=\(/{c=1} c{print} c&&/^\)/{exit}' "$TIMERS_SRC")
eval "$timers_block"
joined=$(printf '%s\n' "${NFTBAN_TIMERS[@]}")
for u in nftban-botscan.timer nftban-community-stats.timer nftban-rebuild-recovery.timer \
         nftban-report-daily.timer nftban-soak.timer nftban-tunnel.timer; do
    assert_contains "$joined" "$u" "TMR-02 NFTBAN_TIMERS has $u"
done

# ---------------------------------------------------------------------------
# T5 (TMR-01): nftban_enable_all's force-enabled core_timers set must exclude
# the apply/confirm-managed rollback (and snapshot) timers. We inspect the
# core_timers=( ... ) array literal inside the function source.
# ---------------------------------------------------------------------------
echo; echo "[TMR-01] enable_all core_timers excludes rollback/snapshot"

core_block=$(awk '/local core_timers=\(/{c=1} c{print} c&&/^[[:space:]]*\)/{exit}' "$SVCCTL_SRC")
assert_not_contains "$core_block" "tmr_rollback" "TMR-01.1 core_timers omits rollback timer"
assert_not_contains "$core_block" "tmr_snapshot" "TMR-01.2 core_timers omits snapshot timer"
assert_contains "$core_block" "tmr_maintenance" "TMR-01.3 core_timers still has maintenance"
assert_contains "$core_block" "tmr_health"      "TMR-01.4 core_timers still has health"
assert_contains "$core_block" "tmr_watchdog"    "TMR-01.5 core_timers still has watchdog"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo; echo "================================================="
echo "Results: PASS=$PASS  FAIL=$FAIL"
if [[ $FAIL -gt 0 ]]; then
    echo "Failed tests:"; for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
    exit 1
fi
echo "All tests passed."
exit 0
