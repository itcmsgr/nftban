#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.126 update-history mixed-install detector fix
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cmd_update_detection_v126_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-22"
# meta:description="Tests for the v1.126 fix that adds a migration-clean unblock path to _detect_install_type. Closes D-DNS2-MIXED-HISTORY-AUTODETECT-FALSE-BLOCK (cleanly source→RPM/DEB migrated hosts previously classified as 'mixed' permanently because the v1.108 strict-detection reads OLDEST history entry). Tests cover: (a) 3 regression-guard cases preserving all existing v1.125 verdicts (clean RPM / clean DEB / pure source), (b) 2 new positive paths for cleanly-migrated hosts (rpm-side dns2-shape + symmetric deb-side), (c) 5 preserved-refusal cases ensuring the new positive path is gated correctly (genuinely broken / failed install / takeover authority / empty history / failed-only history). Uses existing NFTBAN_TEST_* env-var overrides plus the new NFTBAN_TEST_INSTALL_STATE_FILE override. No host contact; no root required."
# meta:input="None (self-contained sandbox)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,jq-optional,mktemp"
# meta:inventory.files="cli/lib/nftban/cli/cmd_update_detection.sh"
# meta:inventory.binaries="bash,mktemp"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_TEST_HISTORY_FILE,NFTBAN_TEST_INSTALL_STATE_FILE,NFTBAN_TEST_RPM_OWNS,NFTBAN_TEST_DPKG_OWNS,NFTBAN_TEST_GIT_REPO_PRESENT"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Defect closed:  D-DNS2-MIXED-HISTORY-AUTODETECT-FALSE-BLOCK
# Scope file:     AUDIT_190_LIFECYCLE/V126_UPDATE_HISTORY_MIXED_INSTALL_DETECTOR_SCOPE.md
# Reproduction:   AUDIT_190_LIFECYCLE/V125_VALIDATE_DNS2_CLOSURE.md §3
# Fix mechanism:  cmd_update_detection.sh::_detect_install_type adds a
#                 migration-clean unblock path. When rpm-db (or dpkg-db)
#                 owns nftban AND the oldest history entry is non-matching
#                 (legacy v1.108 "mixed" trigger), v1.126 now ALSO checks:
#                   a) last successful history entry matches current family
#                   b) install_state shows COMMITTED + AUTHORITY=UPDATE
#                 If both confirm, the host is treated as cleanly migrated
#                 to the current family. All existing v1.125 refusals are
#                 preserved when any positive signal is missing.
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
NFTBAN_LIB_DIR="${REPO_ROOT}/cli/lib/nftban"
export NFTBAN_LIB_DIR

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0
FAIL=0
FAILED_TESTS=()

assert_eq() {
    local actual="$1" expected="$2" name="$3"
    if [[ "$actual" == "$expected" ]]; then
        printf "  [PASS] %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  [FAIL] %s (expected '%s', got '%s')\n" "$name" "$expected" "$actual"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    fi
}

# ---------------------------------------------------------------------------
# Source the detection script. Its double-load guard means we must not
# re-source within this process. Each test case sets its env vars BEFORE
# calling _detect_install_type via a subshell to keep state isolated.
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/cli/cmd_update_detection.sh"

# Reset cross-test env vars at the start of each case.
clean_env() {
    unset NFTBAN_TEST_HISTORY_FILE NFTBAN_TEST_INSTALL_STATE_FILE
    unset NFTBAN_TEST_RPM_OWNS NFTBAN_TEST_DPKG_OWNS
    unset NFTBAN_TEST_GIT_REPO_PRESENT
}

# Write a history.json fixture. Pass entries newest-first via args; each
# arg is a colon-separated "type:status" pair. Output is canonical
# newest-first array shape matching internal/installer/history/history.go.
write_history() {
    local file="$1"; shift
    {
        echo "["
        local first=1
        local entry
        for entry in "$@"; do
            local etype estatus
            etype="${entry%%:*}"
            estatus="${entry#*:}"
            if (( first )); then
                first=0
            else
                echo ","
            fi
            printf '  {\n'
            printf '    "timestamp": "2026-05-22T00:00:00Z",\n'
            printf '    "from": "1.0.0",\n'
            printf '    "to": "1.0.0",\n'
            printf '    "status": "%s",\n' "$estatus"
            printf '    "type": "%s",\n' "$etype"
            printf '    "duration_s": 1,\n'
            printf '    "host": "test"\n'
            printf '  }'
        done
        echo ""
        echo "]"
    } > "$file"
}

# Write an install_state fixture. Args: state, authority.
write_install_state() {
    local file="$1" state="$2" authority="$3"
    cat > "$file" <<EOF
INSTALL_STATE=${state}
INSTALL_MODE=install
INSTALL_VERSION=1.0.0
INSTALL_TIMESTAMP=2026-05-22T00:00:00Z
SSH_PORT=22
AUTHORITY=${authority}
PANEL=
CONFLICTS=
PREFLIGHT_PASSED=1
EOF
}

echo "=========================================================="
echo "V126 Lane B — _detect_install_type migration-clean test"
echo "=========================================================="

# ---------------------------------------------------------------------------
# CASE 1: Clean RPM host — no source history, current rpm-db ownership
# Expected: rpm (preserves existing v1.125 behavior — REGRESSION GUARD)
# ---------------------------------------------------------------------------
clean_env
HISTORY="$SANDBOX/case1.json"
write_history "$HISTORY" "rpm:success" "rpm:success" "rpm:success"
result=$(NFTBAN_TEST_HISTORY_FILE="$HISTORY" NFTBAN_TEST_RPM_OWNS=yes NFTBAN_TEST_DPKG_OWNS=no NFTBAN_TEST_GIT_REPO_PRESENT=no _detect_install_type)
assert_eq "$result" "rpm" "regression_1_clean_rpm_no_source_history_returns_rpm"

# ---------------------------------------------------------------------------
# CASE 2: Clean DEB host — no source history, current dpkg-db ownership
# Expected: deb (REGRESSION GUARD)
# ---------------------------------------------------------------------------
clean_env
HISTORY="$SANDBOX/case2.json"
write_history "$HISTORY" "deb:success" "deb:success"
result=$(NFTBAN_TEST_HISTORY_FILE="$HISTORY" NFTBAN_TEST_RPM_OWNS=no NFTBAN_TEST_DPKG_OWNS=yes NFTBAN_TEST_GIT_REPO_PRESENT=no _detect_install_type)
assert_eq "$result" "deb" "regression_2_clean_deb_no_source_history_returns_deb"

# ---------------------------------------------------------------------------
# CASE 3: Pure source install — only source entries, no pkg-db ownership
# Expected: source (REGRESSION GUARD)
# ---------------------------------------------------------------------------
clean_env
HISTORY="$SANDBOX/case3.json"
write_history "$HISTORY" "source:success" "source:success"
result=$(NFTBAN_TEST_HISTORY_FILE="$HISTORY" NFTBAN_TEST_RPM_OWNS=no NFTBAN_TEST_DPKG_OWNS=no NFTBAN_TEST_GIT_REPO_PRESENT=no _detect_install_type)
assert_eq "$result" "source" "regression_3_pure_source_install_returns_source"

# ---------------------------------------------------------------------------
# CASE 4: dns2-shape — rpm-db owns + oldest=source + last-successful=rpm
#         + install_state=COMMITTED+UPDATE
# Expected: rpm (V126 NEW POSITIVE PATH — was "mixed" pre-v1.126)
# ---------------------------------------------------------------------------
clean_env
HISTORY="$SANDBOX/case4.json"
# newest-first: most recent success is rpm; oldest is source (the dns2 shape)
# install_fail entry in between (proves the new helper skips non-success entries)
write_history "$HISTORY" \
    "mixed:install_fail" \
    "rpm:success" \
    "rpm:success" \
    "rpm:success" \
    "source:success"
STATE="$SANDBOX/case4.state"
write_install_state "$STATE" "COMMITTED" "UPDATE"
result=$(NFTBAN_TEST_HISTORY_FILE="$HISTORY" NFTBAN_TEST_INSTALL_STATE_FILE="$STATE" \
    NFTBAN_TEST_RPM_OWNS=yes NFTBAN_TEST_DPKG_OWNS=no NFTBAN_TEST_GIT_REPO_PRESENT=no \
    _detect_install_type)
assert_eq "$result" "rpm" "new_4_dns2_shape_rpm_db_plus_migrated_returns_rpm_unblocked"

# ---------------------------------------------------------------------------
# CASE 5: Symmetric DEB — dpkg-db owns + oldest=source + last-successful=deb
#         + install_state=COMMITTED+UPDATE
# Expected: deb (V126 NEW POSITIVE PATH — symmetric to case 4)
# ---------------------------------------------------------------------------
clean_env
HISTORY="$SANDBOX/case5.json"
write_history "$HISTORY" \
    "deb:success" \
    "deb:success" \
    "source:success"
STATE="$SANDBOX/case5.state"
write_install_state "$STATE" "COMMITTED" "UPDATE"
result=$(NFTBAN_TEST_HISTORY_FILE="$HISTORY" NFTBAN_TEST_INSTALL_STATE_FILE="$STATE" \
    NFTBAN_TEST_RPM_OWNS=no NFTBAN_TEST_DPKG_OWNS=yes NFTBAN_TEST_GIT_REPO_PRESENT=no \
    _detect_install_type)
assert_eq "$result" "deb" "new_5_symmetric_deb_migrated_returns_deb_unblocked"

# ---------------------------------------------------------------------------
# CASE 6: Genuinely broken — rpm-db owns + oldest=source + last-successful=source
#         (rpm package somehow added on top of a source install; latest success
#         predates rpm-db ownership). Operator review required.
# Expected: mixed (PRESERVED REFUSAL — new positive path must NOT fire)
# ---------------------------------------------------------------------------
clean_env
HISTORY="$SANDBOX/case6.json"
write_history "$HISTORY" \
    "source:success" \
    "source:success"
STATE="$SANDBOX/case6.state"
write_install_state "$STATE" "COMMITTED" "UPDATE"
result=$(NFTBAN_TEST_HISTORY_FILE="$HISTORY" NFTBAN_TEST_INSTALL_STATE_FILE="$STATE" \
    NFTBAN_TEST_RPM_OWNS=yes NFTBAN_TEST_DPKG_OWNS=no NFTBAN_TEST_GIT_REPO_PRESENT=no \
    _detect_install_type)
assert_eq "$result" "mixed" "preserve_6_genuinely_broken_rpm_over_source_returns_mixed"

# ---------------------------------------------------------------------------
# CASE 7: Failed install — rpm-db owns + oldest=source + last-successful=rpm
#         + install_state=FAILED_REBUILD (install never committed cleanly)
# Expected: mixed (PRESERVED REFUSAL — state gate must NOT fire)
# ---------------------------------------------------------------------------
clean_env
HISTORY="$SANDBOX/case7.json"
write_history "$HISTORY" \
    "rpm:success" \
    "source:success"
STATE="$SANDBOX/case7.state"
write_install_state "$STATE" "FAILED_REBUILD" "UPDATE"
result=$(NFTBAN_TEST_HISTORY_FILE="$HISTORY" NFTBAN_TEST_INSTALL_STATE_FILE="$STATE" \
    NFTBAN_TEST_RPM_OWNS=yes NFTBAN_TEST_DPKG_OWNS=no NFTBAN_TEST_GIT_REPO_PRESENT=no \
    _detect_install_type)
assert_eq "$result" "mixed" "preserve_7_failed_rebuild_state_returns_mixed"

# ---------------------------------------------------------------------------
# CASE 8: Takeover authority — rpm-db owns + oldest=source + last-successful=rpm
#         + install_state=COMMITTED+TAKEOVER (committed but different mode)
# Expected: mixed (PRESERVED REFUSAL — conservative; TAKEOVER ≠ clean UPDATE
#                  migration; operator review required)
# ---------------------------------------------------------------------------
clean_env
HISTORY="$SANDBOX/case8.json"
write_history "$HISTORY" \
    "rpm:success" \
    "source:success"
STATE="$SANDBOX/case8.state"
write_install_state "$STATE" "COMMITTED" "TAKEOVER"
result=$(NFTBAN_TEST_HISTORY_FILE="$HISTORY" NFTBAN_TEST_INSTALL_STATE_FILE="$STATE" \
    NFTBAN_TEST_RPM_OWNS=yes NFTBAN_TEST_DPKG_OWNS=no NFTBAN_TEST_GIT_REPO_PRESENT=no \
    _detect_install_type)
assert_eq "$result" "mixed" "preserve_8_committed_takeover_authority_returns_mixed"

# ---------------------------------------------------------------------------
# CASE 9: Empty history + rpm-db ownership
# Expected: rpm (no drift trigger — preserves existing behavior)
# ---------------------------------------------------------------------------
clean_env
HISTORY="$SANDBOX/case9.json"
echo "[]" > "$HISTORY"
result=$(NFTBAN_TEST_HISTORY_FILE="$HISTORY" \
    NFTBAN_TEST_RPM_OWNS=yes NFTBAN_TEST_DPKG_OWNS=no NFTBAN_TEST_GIT_REPO_PRESENT=no \
    _detect_install_type)
assert_eq "$result" "rpm" "case_9_empty_history_returns_rpm"

# ---------------------------------------------------------------------------
# CASE 10: Only failed entries — rpm-db owns + history has source-old + only
#          failure-status newer entries. _read_history_last_successful_type
#          returns empty; positive path must NOT fire.
# Expected: mixed (PRESERVED REFUSAL — no positive evidence of clean install)
# ---------------------------------------------------------------------------
clean_env
HISTORY="$SANDBOX/case10.json"
write_history "$HISTORY" \
    "mixed:install_fail" \
    "rpm:verify_fail" \
    "rpm:install_fail" \
    "source:success"
STATE="$SANDBOX/case10.state"
write_install_state "$STATE" "COMMITTED" "UPDATE"
result=$(NFTBAN_TEST_HISTORY_FILE="$HISTORY" NFTBAN_TEST_INSTALL_STATE_FILE="$STATE" \
    NFTBAN_TEST_RPM_OWNS=yes NFTBAN_TEST_DPKG_OWNS=no NFTBAN_TEST_GIT_REPO_PRESENT=no \
    _detect_install_type)
# Latest success in this fixture is the oldest source entry, NOT rpm. Positive
# path predicate requires last_successful == "rpm" which is false here.
assert_eq "$result" "mixed" "preserve_10_only_failures_above_old_source_returns_mixed"

# ---------------------------------------------------------------------------
# CASE 11: Bonus — install_state file missing entirely
# Expected: mixed (positive path requires readable install_state; missing
#                  file → _probe_install_state_committed_update_authority
#                  returns non-zero → fallback to mixed)
# ---------------------------------------------------------------------------
clean_env
HISTORY="$SANDBOX/case11.json"
write_history "$HISTORY" "rpm:success" "source:success"
# Point at a non-existent file
result=$(NFTBAN_TEST_HISTORY_FILE="$HISTORY" \
    NFTBAN_TEST_INSTALL_STATE_FILE="$SANDBOX/does-not-exist" \
    NFTBAN_TEST_RPM_OWNS=yes NFTBAN_TEST_DPKG_OWNS=no NFTBAN_TEST_GIT_REPO_PRESENT=no \
    _detect_install_type)
assert_eq "$result" "mixed" "preserve_11_missing_install_state_file_returns_mixed"

# ---------------------------------------------------------------------------
# Sub-test: _read_history_last_successful_type helper behavior
# ---------------------------------------------------------------------------
echo
echo "----- helper: _read_history_last_successful_type direct probes -----"

# h1: empty array → empty
echo "[]" > "$SANDBOX/h1.json"
result=$(NFTBAN_TEST_HISTORY_FILE="$SANDBOX/h1.json" _read_history_last_successful_type)
assert_eq "$result" "" "helper_h1_empty_array_returns_empty"

# h2: only failed entries → empty
write_history "$SANDBOX/h2.json" "rpm:install_fail" "rpm:verify_fail"
result=$(NFTBAN_TEST_HISTORY_FILE="$SANDBOX/h2.json" _read_history_last_successful_type)
assert_eq "$result" "" "helper_h2_only_failures_returns_empty"

# h3: newest success is rpm (mid-array), oldest is source-success
write_history "$SANDBOX/h3.json" \
    "rpm:install_fail" \
    "rpm:success" \
    "source:success"
result=$(NFTBAN_TEST_HISTORY_FILE="$SANDBOX/h3.json" _read_history_last_successful_type)
assert_eq "$result" "rpm" "helper_h3_newest_success_rpm_returns_rpm"

# h4: latest success is source (no later success)
write_history "$SANDBOX/h4.json" \
    "rpm:install_fail" \
    "source:success"
result=$(NFTBAN_TEST_HISTORY_FILE="$SANDBOX/h4.json" _read_history_last_successful_type)
assert_eq "$result" "source" "helper_h4_only_source_success_returns_source"

# h5: unreadable file
result=$(NFTBAN_TEST_HISTORY_FILE="$SANDBOX/does-not-exist" _read_history_last_successful_type)
assert_eq "$result" "" "helper_h5_unreadable_returns_empty"

# ---------------------------------------------------------------------------
# Sub-test: _probe_install_state_committed_update_authority helper behavior
# ---------------------------------------------------------------------------
echo
echo "----- helper: _probe_install_state_committed_update_authority direct -----"

# p1: COMMITTED + UPDATE → 0 (success)
write_install_state "$SANDBOX/p1.state" "COMMITTED" "UPDATE"
NFTBAN_TEST_INSTALL_STATE_FILE="$SANDBOX/p1.state" _probe_install_state_committed_update_authority && p1_rc=0 || p1_rc=$?
assert_eq "$p1_rc" "0" "helper_p1_committed_update_returns_0"

# p2: COMMITTED + TAKEOVER → non-zero
write_install_state "$SANDBOX/p2.state" "COMMITTED" "TAKEOVER"
NFTBAN_TEST_INSTALL_STATE_FILE="$SANDBOX/p2.state" _probe_install_state_committed_update_authority && p2_rc=0 || p2_rc=$?
assert_eq "$p2_rc" "1" "helper_p2_committed_takeover_returns_1"

# p3: FAILED_REBUILD + UPDATE → non-zero
write_install_state "$SANDBOX/p3.state" "FAILED_REBUILD" "UPDATE"
NFTBAN_TEST_INSTALL_STATE_FILE="$SANDBOX/p3.state" _probe_install_state_committed_update_authority && p3_rc=0 || p3_rc=$?
assert_eq "$p3_rc" "1" "helper_p3_failed_rebuild_returns_1"

# p4: missing file
NFTBAN_TEST_INSTALL_STATE_FILE="$SANDBOX/does-not-exist-p4" _probe_install_state_committed_update_authority && p4_rc=0 || p4_rc=$?
assert_eq "$p4_rc" "1" "helper_p4_missing_file_returns_1"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "=========================================================="
echo "Results: $PASS passed, $FAIL failed"
echo "=========================================================="
if (( FAIL > 0 )); then
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do
        echo "  - $t"
    done
    exit 1
fi
echo "All v1.126 Lane B mixed-install detector tests passed."
exit 0
