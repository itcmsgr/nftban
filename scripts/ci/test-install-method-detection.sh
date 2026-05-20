#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.107 — V108 Item 6: install-method detection CI gate
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="test-install-method-detection"
# meta:type="ci-script"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-11"
# meta:description="V108 Item 6 CI gate: validate _detect_install_type + _classify_for_pkg_mgr_update across the 9 classification fixtures (rpm / deb / source / source-git / unknown / mixed-rpm-history-source / mixed-deb-history-rpm / cross-family / history-confirms-db)"
# meta:inventory.files="scripts/ci/test-install-method-detection.sh, scripts/ci/fixtures/install-method-detection/, cli/lib/nftban/cli/cmd_update_detection.sh"
# meta:inventory.binaries="bash, jq (optional)"
# meta:inventory.env_vars="NFTBAN_TEST_HISTORY_FILE, NFTBAN_TEST_RPM_OWNS, NFTBAN_TEST_DPKG_OWNS, NFTBAN_TEST_GIT_REPO_PRESENT"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
#
# Implements V108 Item 6 per scope artifact:
#   /home/commonfolder/LLMAI4NFTBAN/V1.90_AUDIT_WIKI_CODE/AUDIT_190_LIFECYCLE/
#   V108_ITEM6_SOURCE_INSTALL_DETECTION_SCOPE.md
#
# Motivating defect (dns2 v1.107.2 rollout):
# dns2 was source-installed (history "type":"source") but the detector returned
# "unknown" because it never read update-history.json. This gate exercises
# the extended detector (V108 Item 6 PR) against 9 fixtures covering rpm,
# deb, source, source-git, unknown, mixed-rpm-history-source,
# mixed-deb-history-rpm, cross-family, and history-confirms-db scenarios.
#
# Modes:
#   suite          Run all 9 fixtures, emit deterministic report
#   one <fixture>  Run a single named fixture (for local debugging)
#
# Exit codes:
#   0  All fixtures classify as expected
#   1  At least one fixture mismatches expected classification or exit code
#   2  Invalid usage / missing dep
# =============================================================================

set -Eeuo pipefail

SCRIPT_NAME="test-install-method-detection"
SCRIPT_VERSION="1.0.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURE_DIR="$REPO_ROOT/scripts/ci/fixtures/install-method-detection"
DETECTION_SCRIPT="$REPO_ROOT/cli/lib/nftban/cli/cmd_update_detection.sh"

log_info()  { printf '[%s] [INFO] %s\n'  "$SCRIPT_NAME" "$*" >&2; }
log_error() { printf '[%s] [ERROR] %s\n' "$SCRIPT_NAME" "$*" >&2; }
log_pass()  { printf '[%s] [PASS] %s\n'  "$SCRIPT_NAME" "$*" >&2; }
log_fail()  { printf '[%s] [FAIL] %s\n'  "$SCRIPT_NAME" "$*" >&2; }

usage() {
    cat >&2 <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION — V108 Item 6 CI gate

Usage:
  $0 suite
  $0 one <fixture-name>

Fixtures (in $FIXTURE_DIR):
  pass-rpm-installed
  pass-deb-installed
  pass-source-installed                (dns2 reproduction)
  pass-source-git-clone
  pass-unknown
  fail-mixed-rpm-history-source
  fail-mixed-deb-history-rpm
  fail-cross-family-rpm-on-deb
  pass-history-rpm-confirms-db

Exit codes:
  0  PASS    1  FAIL    2  invalid usage / missing dep
EOF
}

# -----------------------------------------------------------------------------
# Run one fixture and check expected classification + exit code
# -----------------------------------------------------------------------------
run_fixture() {
    local fname="$1"
    local fdir="$FIXTURE_DIR/$fname"
    if [[ ! -d "$fdir" ]]; then
        log_fail "$fname: fixture directory missing ($fdir)"
        return 1
    fi

    # Required fixture files
    local fixture_env="$fdir/fixture.vars"
    local fixture_history="$fdir/update-history.json"
    local expected_classify="$fdir/expected.classification"
    local expected_classify_rpm_exit="$fdir/expected.classify-rpm-exit"
    local expected_classify_deb_exit="$fdir/expected.classify-deb-exit"

    if [[ ! -f "$fixture_env" ]]; then
        log_fail "$fname: missing fixture.vars"
        return 1
    fi

    # Load env: NFTBAN_TEST_RPM_OWNS, NFTBAN_TEST_DPKG_OWNS, NFTBAN_TEST_GIT_REPO_PRESENT
    local NFTBAN_TEST_RPM_OWNS="" NFTBAN_TEST_DPKG_OWNS="" NFTBAN_TEST_GIT_REPO_PRESENT=""
    set +u
    # v1.124.1: directive moved to be immediately before `source` so shellcheck
    # applies it to the right command. Previously SC1090 was attached to the
    # `local` declaration above and didn't suppress the warning on the actual
    # source line, producing a baseline Project Health workflow failure.
    # shellcheck source=/dev/null
    source "$fixture_env"
    set -u

    # Build a runner that sources the detector + invokes both functions
    local driver
    driver=$(mktemp)
    cat > "$driver" <<DRIVER
#!/usr/bin/env bash
# Source the detection script first (it sets set -Eeuo pipefail internally)
source "$DETECTION_SCRIPT"
# Now disable -e AFTER source so non-zero classify exits don't kill the driver
set +e
classification=\$(_detect_install_type)
echo "CLASSIFICATION=\$classification"
_classify_for_pkg_mgr_update rpm
echo "CLASSIFY_RPM_EXIT=\$?"
_classify_for_pkg_mgr_update deb
echo "CLASSIFY_DEB_EXIT=\$?"
DRIVER

    # Set env, then invoke driver
    local actual_output
    actual_output=$(
        export NFTBAN_TEST_RPM_OWNS NFTBAN_TEST_DPKG_OWNS NFTBAN_TEST_GIT_REPO_PRESENT
        if [[ -f "$fixture_history" ]]; then
            export NFTBAN_TEST_HISTORY_FILE="$fixture_history"
        else
            export NFTBAN_TEST_HISTORY_FILE="/nonexistent/path/to/history.json"
        fi
        bash "$driver"
    )
    rm -f "$driver"

    local actual_classification
    local actual_rpm_exit
    local actual_deb_exit
    actual_classification=$(echo "$actual_output" | grep '^CLASSIFICATION=' | sed 's/^CLASSIFICATION=//')
    actual_rpm_exit=$(echo "$actual_output" | grep '^CLASSIFY_RPM_EXIT=' | sed 's/^CLASSIFY_RPM_EXIT=//')
    actual_deb_exit=$(echo "$actual_output" | grep '^CLASSIFY_DEB_EXIT=' | sed 's/^CLASSIFY_DEB_EXIT=//')

    # Compare with expected
    local exp_class exp_rpm exp_deb
    exp_class=$(cat "$expected_classify" 2>/dev/null | tr -d '[:space:]')
    exp_rpm=$(cat "$expected_classify_rpm_exit" 2>/dev/null | tr -d '[:space:]')
    exp_deb=$(cat "$expected_classify_deb_exit" 2>/dev/null | tr -d '[:space:]')

    local ok=1
    [[ "$actual_classification" == "$exp_class" ]] || ok=0
    [[ "$actual_rpm_exit"      == "$exp_rpm" ]]   || ok=0
    [[ "$actual_deb_exit"      == "$exp_deb" ]]   || ok=0

    if [[ $ok -eq 1 ]]; then
        log_pass "$fname: classification=$actual_classification classify-rpm=$actual_rpm_exit classify-deb=$actual_deb_exit"
        return 0
    else
        log_fail "$fname:"
        log_fail "  expected: classification=$exp_class classify-rpm=$exp_rpm classify-deb=$exp_deb"
        log_fail "  actual:   classification=$actual_classification classify-rpm=$actual_rpm_exit classify-deb=$actual_deb_exit"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    if [[ $# -lt 1 ]]; then
        usage; exit 2
    fi
    local mode="$1"; shift

    case "$mode" in
        suite)
            local fixtures=(
                pass-rpm-installed
                pass-deb-installed
                pass-source-installed
                pass-source-git-clone
                pass-unknown
                fail-mixed-rpm-history-source
                fail-mixed-deb-history-rpm
                fail-cross-family-rpm-on-deb
                pass-history-rpm-confirms-db
            )
            log_info "$SCRIPT_NAME v$SCRIPT_VERSION"
            log_info "Running ${#fixtures[@]} fixtures from $FIXTURE_DIR"
            log_info ""
            local total_pass=0 total_fail=0
            local f
            for f in "${fixtures[@]}"; do
                if run_fixture "$f"; then
                    total_pass=$((total_pass + 1))
                else
                    total_fail=$((total_fail + 1))
                fi
            done
            log_info ""
            log_info "─────────────────────────────────────────────────────────"
            log_info "Summary"
            log_info "─────────────────────────────────────────────────────────"
            log_info "  Total fixtures: ${#fixtures[@]}"
            log_info "  PASS:           $total_pass"
            log_info "  FAIL:           $total_fail"
            log_info "─────────────────────────────────────────────────────────"
            if [[ $total_fail -eq 0 ]]; then
                log_pass "All fixtures classify as expected. V108 Item 6 gate PASSED."
                exit 0
            else
                log_fail "$total_fail fixture(s) failed. V108 Item 6 gate FAILED."
                exit 1
            fi
            ;;
        one)
            [[ $# -ge 1 ]] || { log_error "Usage: $0 one <fixture-name>"; exit 2; }
            run_fixture "$1" || exit 1
            exit 0
            ;;
        -h|--help|help) usage; exit 0 ;;
        *) log_error "Unknown mode: $mode"; usage; exit 2 ;;
    esac
}

main "$@"
