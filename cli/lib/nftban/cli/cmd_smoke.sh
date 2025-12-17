#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Smoke Test Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: CLI wrapper for smoke test suite
#
# meta:name=cmd_smoke
# meta:type=cli
# meta:header=Smoke Test Command
# meta:version=1.0.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# meta:description=Run CLI health checks and detect stuck/failed scripts
# meta:depends=bash,nftban_trace.sh
#
# meta:created_date=2025-12-04
# meta:updated_date=2025-12-04
# =============================================================================

[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"

# Prevent double-loading
[[ -n "${CMD_SMOKE_LOADED:-}" ]] && return 0
readonly CMD_SMOKE_LOADED=1

# =============================================================================
# COMMAND HANDLER
# =============================================================================

nftban_cmd_smoke() {
    local subcommand="${1:-run}"
    shift || true

    # Source output module for banner
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"
        nftban_banner
    fi
    echo ""

    case "$subcommand" in
        run|test)
            nftban_smoke_run "$@"
            ;;
        quick)
            nftban_smoke_run --quick "$@"
            ;;
        all|detailed)
            # Comprehensive test of ALL 43 CLI commands
            nftban_smoke_run --all "$@"
            ;;
        check|orphans)
            nftban_smoke_check_orphans "$@"
            ;;
        stats)
            nftban_smoke_stats
            ;;
        trace)
            nftban_smoke_trace "$@"
            ;;
        help|--help|-h)
            nftban_cmd_smoke_usage
            ;;
        *)
            echo "ERROR: Unknown subcommand: $subcommand" >&2
            nftban_cmd_smoke_usage
            return 1
            ;;
    esac
}

# =============================================================================
# SUBCOMMAND HANDLERS
# =============================================================================

nftban_smoke_run() {
    # Use central path from config
    local tests_dir="${NFTBAN_TESTS_DIR:-/usr/lib/nftban/tests}"
    local test_script="${tests_dir}/smoke_test.sh"

    if [[ ! -f "$test_script" ]]; then
        echo "ERROR: Smoke test script not found at: $test_script" >&2
        echo "Hint: Run 'sudo ./install.sh tests' to install test suite" >&2
        return 1
    fi

    echo "Running NFTBan Smoke Test Suite..."
    echo ""

    bash "$test_script" "$@"
}

nftban_smoke_check_orphans() {
    local minutes="${1:-5}"

    # Source trace library
    if [[ -f "${NFTBAN_LIB_DIR}/helpers/nftban_trace.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/helpers/nftban_trace.sh"
    else
        echo "ERROR: Trace library not found" >&2
        return 1
    fi

    echo "Checking for orphaned traces (scripts that started but never finished)..."
    echo "Looking for traces older than ${minutes} minutes..."
    echo ""

    nftban_trace_find_orphans "$minutes"
}

nftban_smoke_stats() {
    # Source trace library
    if [[ -f "${NFTBAN_LIB_DIR}/helpers/nftban_trace.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/helpers/nftban_trace.sh"
    else
        echo "ERROR: Trace library not found" >&2
        return 1
    fi

    nftban_trace_stats
}

nftban_smoke_trace() {
    local subcommand="${1:-recent}"
    shift || true

    # Source trace library
    if [[ -f "${NFTBAN_LIB_DIR}/helpers/nftban_trace.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/helpers/nftban_trace.sh"
    else
        echo "ERROR: Trace library not found" >&2
        return 1
    fi

    case "$subcommand" in
        recent)
            local count="${1:-20}"
            nftban_trace_recent "$count"
            ;;
        rotate)
            local days="${1:-7}"
            nftban_trace_rotate "$days"
            ;;
        enable|disable)
            echo "Use 'nftban debug $subcommand' instead"
            echo ""
            echo "Quick reference:"
            echo "  nftban debug enable    Enable debug trace"
            echo "  nftban debug disable   Disable debug trace"
            echo "  nftban debug status    Show debug status"
            ;;
        *)
            echo "Unknown trace command: $subcommand"
            echo "Available: recent, rotate"
            echo ""
            echo "For enable/disable, use: nftban debug enable/disable"
            return 1
            ;;
    esac
}

# =============================================================================
# USAGE
# =============================================================================

nftban_cmd_smoke_usage() {
    cat <<EOF
Usage: nftban smoke <command> [OPTIONS]

CLI health check and debugging tool.

Commands:
  run, test          Run standard smoke test (~20 commands)
  quick              Run quick test (3 core commands only)
  all, detailed      Run ALL CLI tests (43 commands - comprehensive)
  check [MINUTES]    Check for orphaned traces (stuck scripts)
  stats              Show trace statistics
  trace recent [N]   Show last N trace entries
  trace rotate [D]   Rotate trace log, keep D days

Test Modes:
  quick    = 3 tests   (version, help, status)
  run/test = ~20 tests (core + modules + stats + search)
  all      = 43+ tests (every cmd_*.sh gets help tested)

Examples:
  nftban smoke run              # Standard smoke test (~20 commands)
  nftban smoke quick            # Quick test (3 commands)
  nftban smoke all              # Test ALL 43 CLI commands
  nftban smoke check            # Check for stuck scripts
  nftban smoke check 10         # Check traces older than 10 min
  nftban smoke stats            # Trace statistics
  nftban smoke trace recent 50  # Last 50 trace entries

Debug Trace Configuration:
  Set NFTBAN_DEBUG_TRACE="true" in /etc/nftban/nftban.conf to enable
  script execution tracing. Each script logs START/END with unique ID.
  If START exists without END = script crashed/stuck.

  Trace log: /var/log/nftban/debug_trace.log

EOF
}

# Export functions
export -f nftban_cmd_smoke
export -f nftban_cmd_smoke_usage
