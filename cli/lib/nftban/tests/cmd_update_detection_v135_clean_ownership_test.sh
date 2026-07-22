#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.135 mixed-drift clean-ownership unblock
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cmd_update_detection_v135_clean_ownership_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-27"
# meta:description="Tests for the v1.135 D-UPDATE-MIXED-DRIFT fix: a third migration-clean unblock path in _detect_install_type based on clean & complete on-disk package ownership (rpm -qf / dpkg -S owns EVERY core binary). Closes the dns2 residual where a genuinely-RPM-migrated host whose last SUCCESS history entry is still source-era (no nftban-updater update ran post-migration) was permanently classified 'mixed' because the v1.126 unblock requires last-successful=rpm + install_state COMMITTED+UPDATE. Cases: (a) dns2 clean-ownership rpm + symmetric deb NEW positive paths, (b) partial/incomplete ownership stays 'mixed' (no unsafe bypass for a genuine source-over-package mix), (c) v1.126 path still fires independently, (d) clean-host regression guards, (e) direct probe unit checks. Uses NFTBAN_TEST_RPM_OWNS_BINARIES / NFTBAN_TEST_DPKG_OWNS_BINARIES / NFTBAN_OWNERSHIP_PROBE_BINS overrides. No host contact; no root required."
# meta:input="None (self-contained sandbox)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,jq-optional,mktemp"
# meta:inventory.files="cli/lib/nftban/cli/cmd_update_detection.sh"
# meta:inventory.binaries="bash,mktemp"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_TEST_HISTORY_FILE,NFTBAN_TEST_INSTALL_STATE_FILE,NFTBAN_TEST_RPM_OWNS,NFTBAN_TEST_DPKG_OWNS,NFTBAN_TEST_RPM_OWNS_BINARIES,NFTBAN_TEST_DPKG_OWNS_BINARIES,NFTBAN_OWNERSHIP_PROBE_BINS,NFTBAN_TEST_GIT_REPO_PRESENT"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="cmd_update_detection_v135_clean_ownership_test"
# meta:ta.owner="update"
# meta:ta.module="update-detection"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
# Defect closed:  D-UPDATE-MIXED-DRIFT (v1.135 Phase 2)
# Scope file:     AUDIT_190_LIFECYCLE/V135_INSTALL_UPDATE_LIFECYCLE_SCOPE.md §2
# Reproduction:   V131_4_FLEET_ROLLOUT_CLOSURE.md Section E (dns2 mixed-drift)
# Fix mechanism:  cmd_update_detection.sh adds _probe_rpm_owns_all_binaries /
#                 _probe_dpkg_owns_all_binaries (clean & complete on-disk
#                 ownership) as a THIRD unblock in _detect_install_type. When
#                 the package db cleanly owns EVERY core binary on disk, the
#                 host is the corresponding package family regardless of stale
#                 source-era history. Incomplete/partial ownership preserves
#                 the "mixed" refusal (no unsafe bypass for a genuine mix).
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

# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/cli/cmd_update_detection.sh"

clean_env() {
    unset NFTBAN_TEST_HISTORY_FILE NFTBAN_TEST_INSTALL_STATE_FILE
    unset NFTBAN_TEST_RPM_OWNS NFTBAN_TEST_DPKG_OWNS
    unset NFTBAN_TEST_RPM_OWNS_BINARIES NFTBAN_TEST_DPKG_OWNS_BINARIES
    unset NFTBAN_OWNERSHIP_PROBE_BINS NFTBAN_TEST_GIT_REPO_PRESENT
}

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
            if (( first )); then first=0; else echo ","; fi
            printf '  {\n'
            printf '    "timestamp": "2026-05-27T00:00:00Z",\n'
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

write_install_state() {
    local file="$1" state="$2" authority="$3"
    cat > "$file" <<EOF
INSTALL_STATE=${state}
INSTALL_MODE=install
INSTALL_VERSION=1.0.0
INSTALL_TIMESTAMP=2026-05-27T00:00:00Z
SSH_PORT=22
AUTHORITY=${authority}
PANEL=
CONFLICTS=
PREFLIGHT_PASSED=1
EOF
}

echo "=========================================================="
echo "V135 D-UPDATE-MIXED-DRIFT — clean-ownership unblock test"
echo "=========================================================="

# ---------------------------------------------------------------------------
# CASE 1: dns2 residual — rpm-db owns + oldest=source + last-successful=source
#         (NOT rpm: no nftban-updater update ran since migration) + install_state
#         COMMITTED+UPDATE + rpm cleanly owns ALL core binaries on disk.
# v1.126 unblock CANNOT fire (last-successful != rpm). v1.135 clean-ownership
# unblock fires.
# Expected: rpm (V135 NEW POSITIVE PATH — was "mixed" through v1.134)
# ---------------------------------------------------------------------------
clean_env
HISTORY="$SANDBOX/case1.json"
write_history "$HISTORY" "source:success" "source:success"
STATE="$SANDBOX/case1.state"
write_install_state "$STATE" "COMMITTED" "UPDATE"
result=$(NFTBAN_TEST_HISTORY_FILE="$HISTORY" NFTBAN_TEST_INSTALL_STATE_FILE="$STATE" \
    NFTBAN_TEST_RPM_OWNS=yes NFTBAN_TEST_DPKG_OWNS=no NFTBAN_TEST_GIT_REPO_PRESENT=no \
    NFTBAN_TEST_RPM_OWNS_BINARIES=yes \
    _detect_install_type)
assert_eq "$result" "rpm" "new_1_dns2_clean_binary_ownership_unblocks_rpm"

# ---------------------------------------------------------------------------
# CASE 2: Symmetric DEB — dpkg-db owns + oldest=source + last-successful=source
#         + dpkg cleanly owns ALL core binaries.
# Expected: deb (V135 NEW POSITIVE PATH — symmetric to case 1)
# ---------------------------------------------------------------------------
clean_env
HISTORY="$SANDBOX/case2.json"
write_history "$HISTORY" "source:success" "source:success"
result=$(NFTBAN_TEST_HISTORY_FILE="$HISTORY" \
    NFTBAN_TEST_RPM_OWNS=no NFTBAN_TEST_DPKG_OWNS=yes NFTBAN_TEST_GIT_REPO_PRESENT=no \
    NFTBAN_TEST_DPKG_OWNS_BINARIES=yes \
    _detect_install_type)
assert_eq "$result" "deb" "new_2_symmetric_deb_clean_binary_ownership_unblocks_deb"

# ---------------------------------------------------------------------------
# CASE 3: Genuine source-over-rpm mix — rpm-db owns the package NAME but a
#         source `make install` clobbered a binary, so on-disk ownership is
#         INCOMPLETE. last-successful=source, COMMITTED+UPDATE.
# Neither v1.126 (last-successful != rpm) nor v1.135 (binary ownership = no)
# unblock fires.
# Expected: mixed (PRESERVED REFUSAL — no unsafe bypass for a genuine mix)
# ---------------------------------------------------------------------------
clean_env
HISTORY="$SANDBOX/case3.json"
write_history "$HISTORY" "source:success" "source:success"
STATE="$SANDBOX/case3.state"
write_install_state "$STATE" "COMMITTED" "UPDATE"
result=$(NFTBAN_TEST_HISTORY_FILE="$HISTORY" NFTBAN_TEST_INSTALL_STATE_FILE="$STATE" \
    NFTBAN_TEST_RPM_OWNS=yes NFTBAN_TEST_DPKG_OWNS=no NFTBAN_TEST_GIT_REPO_PRESENT=no \
    NFTBAN_TEST_RPM_OWNS_BINARIES=no \
    _detect_install_type)
assert_eq "$result" "mixed" "preserve_3_incomplete_binary_ownership_stays_mixed"

# ---------------------------------------------------------------------------
# CASE 4: v1.126 path independence — rpm-db owns + last-successful=rpm +
#         COMMITTED+UPDATE, but binary-ownership probe says NO. The v1.126
#         unblock must still fire on its own signals (it is checked first).
# Expected: rpm (v1.126 regression guard; proves v1.135 probe is additive)
# ---------------------------------------------------------------------------
clean_env
HISTORY="$SANDBOX/case4.json"
write_history "$HISTORY" "rpm:success" "source:success"
STATE="$SANDBOX/case4.state"
write_install_state "$STATE" "COMMITTED" "UPDATE"
result=$(NFTBAN_TEST_HISTORY_FILE="$HISTORY" NFTBAN_TEST_INSTALL_STATE_FILE="$STATE" \
    NFTBAN_TEST_RPM_OWNS=yes NFTBAN_TEST_DPKG_OWNS=no NFTBAN_TEST_GIT_REPO_PRESENT=no \
    NFTBAN_TEST_RPM_OWNS_BINARIES=no \
    _detect_install_type)
assert_eq "$result" "rpm" "regress_4_v126_unblock_still_fires_independently"

# ---------------------------------------------------------------------------
# CASE 5: Clean RPM host, no source drift at all — binary probe not reached.
# Expected: rpm (regression guard — happy path unaffected)
# ---------------------------------------------------------------------------
clean_env
HISTORY="$SANDBOX/case5.json"
write_history "$HISTORY" "rpm:success" "rpm:success"
result=$(NFTBAN_TEST_HISTORY_FILE="$HISTORY" \
    NFTBAN_TEST_RPM_OWNS=yes NFTBAN_TEST_DPKG_OWNS=no NFTBAN_TEST_GIT_REPO_PRESENT=no \
    NFTBAN_TEST_RPM_OWNS_BINARIES=no \
    _detect_install_type)
assert_eq "$result" "rpm" "regress_5_clean_rpm_no_drift_returns_rpm"

# ---------------------------------------------------------------------------
# CASE 6: Pure source install — no pkg-db ownership at all. Clean-ownership
#         probe is never consulted (no rpm/dpkg ownership branch entered).
# Expected: source (regression guard)
# ---------------------------------------------------------------------------
clean_env
HISTORY="$SANDBOX/case6.json"
write_history "$HISTORY" "source:success" "source:success"
result=$(NFTBAN_TEST_HISTORY_FILE="$HISTORY" \
    NFTBAN_TEST_RPM_OWNS=no NFTBAN_TEST_DPKG_OWNS=no NFTBAN_TEST_GIT_REPO_PRESENT=no \
    _detect_install_type)
assert_eq "$result" "source" "regress_6_pure_source_returns_source"

# ---------------------------------------------------------------------------
# Direct probe unit checks (real filesystem, no rpm/dpkg db calls — the
# override short-circuits AND the on-disk completeness path is exercised via
# NFTBAN_OWNERSHIP_PROBE_BINS).
# ---------------------------------------------------------------------------
echo
echo "--- direct probe checks ---"

# d1: override=yes → 0
clean_env
NFTBAN_TEST_RPM_OWNS_BINARIES=yes _probe_rpm_owns_all_binaries && d1=0 || d1=$?
assert_eq "$d1" "0" "probe_d1_rpm_override_yes_returns_0"

# d2: override=no → 1
clean_env
NFTBAN_TEST_RPM_OWNS_BINARIES=no _probe_rpm_owns_all_binaries && d2=0 || d2=$?
assert_eq "$d2" "1" "probe_d2_rpm_override_no_returns_1"

# d3: dpkg override=yes → 0
clean_env
NFTBAN_TEST_DPKG_OWNS_BINARIES=yes _probe_dpkg_owns_all_binaries && d3=0 || d3=$?
assert_eq "$d3" "0" "probe_d3_dpkg_override_yes_returns_0"

# d4: probe-bin list points at a MISSING file → incomplete → non-zero
# (exercises the [[ -e ]] completeness guard without touching rpm db; rpm may
# be absent on the dev host, in which case the command-check returns 1 first —
# either way the contract "missing/unowned binary ⇒ non-zero" holds).
clean_env
NFTBAN_OWNERSHIP_PROBE_BINS="$SANDBOX/definitely-not-present-binary" \
    _probe_rpm_owns_all_binaries && d4=0 || d4=$?
assert_eq "$d4" "1" "probe_d4_missing_binary_returns_nonzero"

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
echo "All v1.135 mixed-drift clean-ownership tests passed."
exit 0
