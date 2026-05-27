#!/usr/bin/env bash
# shellcheck disable=SC1090  # dynamic `source "$COMPAT"` in subshells is intentional (module-under-test path)
# =============================================================================
# NFTBan - Tests for v1.136 exporter exit-2 resilience + diagnosability (Phase 1)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="exporter_exit2_resilience_v136_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-27"
# meta:description="Phase-1 tests for the v1.136 exporter exit-2 resilience lane. (a) ERR-trap diagnosability: under set -Eeuo pipefail the permanent ERR trap turns a silent strict-mode abort into a journal line carrying rc + file:line + function + failing command, and re-raises the original rc (strict mode preserved, failure NOT swallowed). (b) Bounded stats.json retry: _read_stats_json_retry accepts only fully-valid JSON, retries a mid-write truncation, and returns non-zero (never crashes / never exit-2) on persistent invalid/missing input. Static guards assert the trap is placed after set -Eeuo pipefail and strict mode is still present. No host contact; no root required."
# meta:input="None (self-contained sandbox)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,jq,mktemp"
# meta:inventory.files="cli/lib/nftban/exporters/nftban_unified_exporter.sh,cli/lib/nftban/exporters/nftban_exporter_json_compat.sh"
# meta:inventory.binaries="bash,jq,mktemp"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Lane:       V1_136_EXPORTER_EXIT2_RESILIENCE_SCOPE.md (Phase 1)
# Origin:     EXPORTER_EXIT2_TRIAGE_READONLY_REPORT.md + EXPORTER_EXIT2_MUTATING_REPRO_REPORT.md
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
EXP_DIR="${REPO_ROOT}/cli/lib/nftban/exporters"
MAIN="${EXP_DIR}/nftban_unified_exporter.sh"
COMPAT="${EXP_DIR}/nftban_exporter_json_compat.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0; FAIL=0; FAILED_TESTS=()
assert_eq() {
    local actual="$1" expected="$2" name="$3"
    if [[ "$actual" == "$expected" ]]; then
        printf "  [PASS] %s\n" "$name"; PASS=$((PASS+1))
    else
        printf "  [FAIL] %s (expected '%s', got '%s')\n" "$name" "$expected" "$actual"
        FAIL=$((FAIL+1)); FAILED_TESTS+=("$name")
    fi
}
assert_contains() {
    local hay="$1" needle="$2" name="$3"
    if [[ "$hay" == *"$needle"* ]]; then
        printf "  [PASS] %s\n" "$name"; PASS=$((PASS+1))
    else
        printf "  [FAIL] %s (missing '%s' in: %s)\n" "$name" "$needle" "$hay"
        FAIL=$((FAIL+1)); FAILED_TESTS+=("$name")
    fi
}

echo "=========================================================="
echo "V136 exporter exit-2 resilience — Phase 1 test"
echo "=========================================================="

# ---------------------------------------------------------------------------
# STATIC: ERR trap placement + strict mode preserved
# ---------------------------------------------------------------------------
echo "--- static guards ---"
strict_ln=$(grep -n '^set -Eeuo pipefail' "$MAIN" | head -1 | cut -d: -f1)
trap_ln=$(grep -n "trap '.*' ERR" "$MAIN" | head -1 | cut -d: -f1)
if [[ -n "$strict_ln" && -n "$trap_ln" && "$trap_ln" -gt "$strict_ln" ]]; then
    assert_eq "ok" "ok" "static_strict_mode_kept_and_trap_after_it"
else
    assert_eq "strict=$strict_ln trap=$trap_ln" "trap>strict" "static_strict_mode_kept_and_trap_after_it"
fi
trap_line=$(grep "trap '.*' ERR" "$MAIN" | head -1)
assert_contains "$trap_line" 'rc=$?' "static_trap_captures_rc"
assert_contains "$trap_line" 'BASH_COMMAND' "static_trap_logs_failing_command"
assert_contains "$trap_line" 'LINENO' "static_trap_logs_line"
assert_contains "$trap_line" 'exit "$rc"' "static_trap_preserves_rc_not_swallow"

# ---------------------------------------------------------------------------
# BEHAVIORAL: ERR-trap attribution under strict mode (the exact shipped pattern)
# A grep file-error returns 2 → trap must log rc/cmd/line AND exit 2 (preserved).
# ---------------------------------------------------------------------------
echo "--- ERR-trap behavior ---"
TRAPSCRIPT="$SANDBOX/trapcase.sh"
{
    echo '#!/usr/bin/env bash'
    echo 'set -Eeuo pipefail'
    # reuse the EXACT trap line shipped in the exporter
    grep "trap '.*' ERR" "$MAIN" | head -1
    echo 'grep "needle" /no/such/file/v136xyz'   # grep returns 2 on file error
    echo 'echo "SHOULD_NOT_REACH"'
} > "$TRAPSCRIPT"
chmod +x "$TRAPSCRIPT"
set +e
trap_out=$(bash "$TRAPSCRIPT" 2>&1 >/dev/null); trap_rc=$?
set -e
assert_eq "$trap_rc" "2" "behav_trap_preserves_rc_2"
assert_contains "$trap_out" "aborted rc=2" "behav_trap_logs_rc2"
assert_contains "$trap_out" "cmd=[grep" "behav_trap_attributes_failing_cmd"
# the post-failure line must not run (strict mode still aborts)
out_all=$(bash "$TRAPSCRIPT" 2>/dev/null || true)
if [[ "$out_all" == *"SHOULD_NOT_REACH"* ]]; then
    assert_eq "reached" "not-reached" "behav_strict_still_aborts_after_failure"
else
    assert_eq "not-reached" "not-reached" "behav_strict_still_aborts_after_failure"
fi

# ---------------------------------------------------------------------------
# BEHAVIORAL: _read_stats_json_retry — valid / missing / truncated / recovers
# Source the compat module in a subshell (it sets its own strict mode + load guard).
# ---------------------------------------------------------------------------
echo "--- bounded stats.json retry ---"
command -v jq >/dev/null 2>&1 || { echo "  [SKIP] jq not available — retry behavioral tests"; }

if command -v jq >/dev/null 2>&1; then
    # valid JSON → echoes content, rc 0
    good="$SANDBOX/good.json"; printf '{"a":1,"b":[2,3]}' > "$good"
    set +e
    out=$( source "$COMPAT"; _read_stats_json_retry "$good" 2 0 ); rc=$?
    set -e
    assert_eq "$rc" "0" "retry_valid_rc0"
    assert_contains "$out" '"a":1' "retry_valid_echoes_content"

    # missing file → rc 1, no crash, no exit-2
    set +e
    out=$( source "$COMPAT"; _read_stats_json_retry "$SANDBOX/nope.json" 2 0 ); rc=$?
    set -e
    assert_eq "$rc" "1" "retry_missing_rc1_not_crash"

    # truncated/invalid JSON (mid-write race shape) → rc 1 after retries, never exit-2
    bad="$SANDBOX/bad.json"; printf '{"a":1,"b":[2,3' > "$bad"   # truncated
    set +e
    out=$( source "$COMPAT"; _read_stats_json_retry "$bad" 3 0 ); rc=$?
    set -e
    assert_eq "$rc" "1" "retry_truncated_rc1_after_retries"

    # recovers on a later attempt: file invalid then becomes valid mid-loop
    recf="$SANDBOX/recover.json"; printf 'NOT_JSON_YET' > "$recf"
    ( sleep 0.25; printf '{"ok":true}' > "$recf" ) &
    set +e
    out=$( source "$COMPAT"; _read_stats_json_retry "$recf" 5 0.2 ); rc=$?
    set -e
    wait 2>/dev/null || true
    assert_eq "$rc" "0" "retry_recovers_when_write_completes"
    assert_contains "$out" '"ok":true' "retry_recovers_echoes_valid"
fi

echo
echo "=========================================================="
echo "Results: $PASS passed, $FAIL failed"
echo "=========================================================="
if (( FAIL > 0 )); then
    echo "Failed tests:"; for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
    exit 1
fi
echo "All v1.136 exporter exit-2 resilience Phase-1 tests passed."
exit 0
