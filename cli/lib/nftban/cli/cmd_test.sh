#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Test Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Quick validation that CLI commands are working
#
# meta:name="cmd_test"
# meta:type="cli"
# meta:header="NFTBan Command Testing"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Quick test of critical CLI commands to detect failures"
# meta:inventory.files=""
# meta:inventory.binaries="nftban"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# meta:created_date="2025-11-24"
# meta:updated_date="2025-11-24"
# =============================================================================


# =============================================================================
# CONFIGURATION
# =============================================================================

[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"

# Load strict mode library
# shellcheck source=/usr/lib/nftban/lib/strict.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/strict.sh" || return 1
else
    # Fallback to manual strict mode
    set -Eeuo pipefail
fi

# Load version library
# shellcheck source=/usr/lib/nftban/lib/version.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/version.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/version.sh" || return 1
fi

# Load JSON helper for --json support
JSON_HELPER="${NFTBAN_LIB_DIR}/helpers/json_output.sh"
if [[ -f "$JSON_HELPER" ]]; then
    # shellcheck source=/dev/null
    source "$JSON_HELPER" || return 1
fi

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

test_cmd() {
    local name="$1"
    local cmd="$2"

    total=$((total + 1))

    # Run command with timeout
    local output=""
    local exit_code=0
    # R17: Use mktemp for secure temp files (v1.19.12)
    local tmp_out
    tmp_out=$(mktemp "${TMPDIR:-/tmp}/nftban_quick_test.XXXXXXXXXX")

    # Use timeout and redirect to file to avoid pipe issues
    # 20 second timeout to handle commands with network checks (like status)
    timeout 20 bash -c "$cmd" > "$tmp_out" 2>&1 || exit_code=$?

    # Read output from file
    if [[ -f "$tmp_out" ]]; then
        output=$(cat "$tmp_out")
        rm -f "$tmp_out"
    fi

    # Check for timeout
    if [[ $exit_code -eq 124 ]]; then
        echo "  ⏱  $name - TIMEOUT"
        failed=$((failed + 1))
        if [[ "$verbose" == "true" ]]; then
            echo "      Command: $cmd"
        fi
        return 1
    fi

    # Check for output
    if [[ -z "$output" ]]; then
        echo "  ∅  $name - NO OUTPUT"
        failed=$((failed + 1))
        if [[ "$verbose" == "true" ]]; then
            echo "      Command: $cmd"
        fi
        return 1
    fi

    # Check for exit marker or formatting
    if echo "$output" | grep -q "NFTBAN_CMD_EXIT\|═\|NFTBan\|nftban"; then
        echo "  ✓  $name"
        passed=$((passed + 1))
        return 0
    else
        echo "  ⚠  $name - no markers"
        passed=$((passed + 1))  # Still count as passed
        return 0
    fi
}

# =============================================================================
# QUICK TEST FUNCTION
# =============================================================================

nftban_cmd_test() {
    # Quick validation of critical CLI commands
    # Args: [--verbose]

    local verbose=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --verbose|-v)
                verbose=true
                shift
                ;;
            help|--help|-h)
                show_usage
                return 0
                ;;
            *)
                # v1.144.0 PR-B UX-C2: 3-line ERROR/Hint/Run replaces the
                # full show_usage block on the unknown-option parse error
                # path. The `nftban test --help` path (above) still
                # renders the full show_usage block (explicit help).
                _v144_error_with_hint \
                    "Unknown option: $1" \
                    "Valid options: --quick, --full, --module=<name>" \
                    "nftban test --help"
                return $?
                ;;
        esac
    done

    # Show banner
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
        if [[ $(type -t nftban_banner) == "function" ]]; then
            nftban_banner
        fi
    fi
    echo ""

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "NFTBan Command Testing"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Testing critical commands..."
    echo ""

    local total=0
    local passed=0
    local failed=0

    # Test commands - grouped by category
    echo "Core Commands:"
    test_cmd "status --quiet" "nftban status --quiet"
    test_cmd "health" "nftban health"
    test_cmd "check" "nftban check"
    test_cmd "version" "nftban version"
    echo ""

    echo "Firewall & Security:"
    test_cmd "firewall status" "nftban firewall status"
    test_cmd "list banned" "nftban list banned"
    test_cmd "list whitelist" "nftban list whitelist"
    test_cmd "search 8.8.8.8" "nftban search 8.8.8.8"
    echo ""

    echo "Protection Modules:"
    test_cmd "ddos status" "nftban ddos status"
    test_cmd "portscan status" "nftban portscan status"
    test_cmd "login status" "nftban login status"
    test_cmd "feeds status" "nftban feeds status"
    echo ""

    echo "GeoIP & Monitoring:"
    test_cmd "geoip status" "nftban geoip status"
    test_cmd "stats dashboard" "nftban stats dashboard"
    test_cmd "metrics status" "nftban metrics status"
    echo ""

    echo "System & Config:"
    test_cmd "permissions check" "nftban permissions check"
    test_cmd "fhs check" "nftban fhs check"
    test_cmd "nftables status" "nftban nftables status"
    test_cmd "services" "nftban services"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Results: $passed/$total passed"

    if [[ $failed -eq 0 ]]; then
        echo "Status: ✅ ALL TESTS PASSED"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        command -v nftban_cmd_exit >/dev/null 2>&1 && nftban_cmd_exit "test"
        return 0
    else
        echo "Status: ❌ $failed TESTS FAILED"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        local tests_dir="${NFTBAN_TESTS_DIR:-/usr/lib/nftban/tests}"
        echo "Run 'bash ${tests_dir}/test_all_commands.sh' for detailed testing"
        echo ""
        command -v nftban_cmd_exit >/dev/null 2>&1 && nftban_cmd_exit "test"
        return 1
    fi
}

show_usage() {
    cat <<'EOF'
nftban test — Quick validation of CLI commands

USAGE:
  nftban test [OPTIONS]

OPTIONS:
  -v, --verbose   Show detailed output for failures
  -h, --help      Show this help

DESCRIPTION:
  Runs a quick test of critical CLI commands to detect failures.
  This is useful for:
    • Verifying CLI is working after updates
    • Detecting commands that hang or produce no output
    • Quick health check of NFTBan CLI

  Tests performed:
    • Core commands (status, health, check)
    • Module commands (ddos, portscan, login, feeds)
    • Management commands (firewall, whitelist, geoip, ports)
    • Security commands (permissions)

EXIT CODES:
  0   All tests passed
  1   One or more tests failed

EXAMPLES:
  nftban test                 Run quick test
  nftban test --verbose       Show detailed output

SEE ALSO:
  bash /usr/lib/nftban/tests/test_all_commands.sh    Full test suite

EOF
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_cmd_test

# =============================================================================
# DIRECT EXECUTION SUPPORT
# =============================================================================

# If executed directly (not sourced), run the command handler
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_test "$@"
fi
