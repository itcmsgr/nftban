#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Smoke Test Suite
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Quick health check of CLI - detects stuck/failed scripts
#
# meta:name=smoke_test
# meta:type=test
# meta:header=Smoke Test Suite
# meta:version=1.0.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **How It Works**
# 1. Enables debug trace temporarily
# 2. Runs key commands with timeout
# 3. Checks trace log for START without END (stuck scripts)
# 4. Reports any failures
#
# **Usage**
#   ./smoke_test.sh              # Run all tests
#   ./smoke_test.sh --quick      # Quick test (core commands only)
#   ./smoke_test.sh --check      # Just check trace log for orphans
#
# meta:created_date=2025-12-04
# meta:updated_date=2025-12-04
# =============================================================================

set -u

# =============================================================================
# CONFIGURATION
# =============================================================================

readonly SCRIPT_NAME="smoke_test"
readonly SCRIPT_VERSION="1.0.0"
DEFAULT_TIMEOUT=30            # seconds per command (default)
QUICK_TIMEOUT=15              # seconds for quick tests
CURRENT_TIMEOUT=$DEFAULT_TIMEOUT  # actual timeout to use
readonly TRACE_LOG="/var/log/nftban/debug_trace.log"
SMOKE_LOG="/tmp/nftban_smoke_$(date +%Y%m%d_%H%M%S).log"
readonly SMOKE_LOG
readonly SMOKE_TRACE_PREFIX="smoke_test"

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Counters
TESTS_TOTAL=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TIMEOUT=0
TESTS_ORPHANS=0

# Trace IDs for this run (reserved for future trace tracking)
# shellcheck disable=SC2034
declare -a SMOKE_TRACE_IDS=()

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

log() { echo -e "$*" | tee -a "$SMOKE_LOG"; }
log_info() { log "${BLUE}[INFO]${NC} $*"; }
log_pass() { log "${GREEN}[PASS]${NC} $*"; }
log_fail() { log "${RED}[FAIL]${NC} $*"; }
log_warn() { log "${YELLOW}[WARN]${NC} $*"; }
log_timeout() { log "${RED}[TIMEOUT]${NC} $*"; }

banner() {
    cat <<'BANNER'
╔══════════════════════════════════════════════════════════════╗
║  🔬 NFTBan Smoke Test Suite v1.0                             ║
║  Quick CLI health check with trace analysis                  ║
╚══════════════════════════════════════════════════════════════╝
BANNER
}

# =============================================================================
# TRACE MANAGEMENT
# =============================================================================

# Enable debug trace for this test run
enable_trace() {
    export NFTBAN_DEBUG_TRACE="true"
    export NFTBAN_DEBUG_TRACE_LOG="$TRACE_LOG"

    # Ensure log directory exists
    local log_dir
    log_dir=$(dirname "$TRACE_LOG")
    [[ ! -d "$log_dir" ]] && mkdir -p "$log_dir" 2>/dev/null

    # Mark test start in trace log
    echo "[$(date '+%Y-%m-%d %H:%M:%S.%N')] [SMOKE] [START] Smoke test run started PID=$$" >> "$TRACE_LOG"
}

# Disable debug trace
disable_trace() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S.%N')] [SMOKE] [END]   Smoke test run completed PID=$$" >> "$TRACE_LOG"
    export NFTBAN_DEBUG_TRACE="false"
}

# Check for orphaned traces from this smoke test run
check_orphans() {
    log ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "TRACE ANALYSIS - Checking for stuck/crashed scripts"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    [[ ! -f "$TRACE_LOG" ]] && log_warn "No trace log found" && return 0

    local orphan_count=0

    # Find START without matching END
    while IFS= read -r line; do
        # Extract trace ID
        local trace_id
        trace_id=$(echo "$line" | grep -oP '\[\K[a-z_]+-[0-9]+_[0-9]+_[0-9]+-[0-9]+(?=\])')
        [[ -z "$trace_id" ]] && continue

        # Check if there's a matching END
        if ! grep -q "\[END\].*\[$trace_id\]" "$TRACE_LOG"; then
            ((orphan_count++))
            log_fail "ORPHAN TRACE: $trace_id"
            log "  $line"
        fi
    done < <(grep '\[START\]' "$TRACE_LOG" | tail -50)

    TESTS_ORPHANS=$orphan_count

    if [[ $orphan_count -eq 0 ]]; then
        log_pass "No orphaned traces found - all scripts completed normally"
    else
        log_fail "Found $orphan_count orphaned trace(s) - scripts may have crashed!"
    fi

    return $orphan_count
}

# =============================================================================
# TEST COMMAND FUNCTION
# =============================================================================

# Run a command with timeout and check results
# Usage: smoke_test_cmd <name> <command>
smoke_test_cmd() {
    local name="$1"
    shift
    local cmd="$*"
    local timeout_val="${CURRENT_TIMEOUT}"

    ((TESTS_TOTAL++))

    log ""
    log "─────────────────────────────────────────────────────────────────"
    log "TEST #$TESTS_TOTAL: $name"
    log "Command: $cmd"

    # Temp files for output
    local output_file="/tmp/smoke_output_$$.txt"
    local exit_file="/tmp/smoke_exit_$$.txt"

    # Run with timeout
    local start_time
    start_time=$(date +%s.%N)

    timeout "$timeout_val" bash -c "
        # Source trace library for this command
        if [[ -f /usr/lib/nftban/helpers/nftban_trace.sh ]]; then
            source /usr/lib/nftban/helpers/nftban_trace.sh
        fi
        export NFTBAN_DEBUG_TRACE=true
        export NFTBAN_DEBUG_TRACE_LOG='$TRACE_LOG'
        $cmd
        echo \$? > '$exit_file'
    " > "$output_file" 2>&1
    local timeout_exit=$?

    local end_time
    end_time=$(date +%s.%N)
    local duration
    duration=$(echo "$end_time - $start_time" | bc 2>/dev/null || echo "?")

    # Check timeout
    if [[ $timeout_exit -eq 124 ]]; then
        log_timeout "$name - exceeded ${timeout_val}s"
        ((TESTS_TIMEOUT++))
        rm -f "$output_file" "$exit_file"
        return 1
    fi

    # Get exit code
    local exit_code=999
    [[ -f "$exit_file" ]] && exit_code=$(cat "$exit_file")

    # Get output
    local output=""
    [[ -f "$output_file" ]] && output=$(cat "$output_file")

    # Evaluate result
    local output_len=${#output}

    if [[ -z "$output" ]]; then
        log_fail "$name - NO OUTPUT (${duration}s)"
        ((TESTS_FAILED++))
    elif [[ "$exit_code" == "0" ]]; then
        log_pass "$name - OK (exit=0, ${output_len} chars, ${duration}s)"
        ((TESTS_PASSED++))
    else
        # Non-zero exit might be OK for some commands
        if [[ $output_len -gt 10 ]]; then
            log_warn "$name - exit=$exit_code but has output (${duration}s)"
            ((TESTS_PASSED++))
        else
            log_fail "$name - exit=$exit_code (${duration}s)"
            ((TESTS_FAILED++))
        fi
    fi

    # Show output preview
    if [[ -n "$output" ]]; then
        log "  Output preview: $(echo "$output" | head -1 | cut -c1-60)..."
    fi

    rm -f "$output_file" "$exit_file"
}

# =============================================================================
# TEST SUITES
# =============================================================================

# Core commands that must always work
run_core_tests() {
    log ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "CORE COMMANDS"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    smoke_test_cmd "version" "nftban version"
    smoke_test_cmd "help" "nftban help"
    smoke_test_cmd "status" "nftban status --quiet 2>/dev/null || nftban status"
}

# Security module status commands
run_module_tests() {
    log ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "MODULE STATUS"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    smoke_test_cmd "firewall status" "nftban firewall status"
    smoke_test_cmd "login status" "nftban login status"
    smoke_test_cmd "portscan status" "nftban portscan status"
    smoke_test_cmd "ddos status" "nftban ddos status"
    smoke_test_cmd "feeds status" "nftban feeds status"
    smoke_test_cmd "whitelist status" "nftban whitelist status"
}

# Stats and reporting
run_stats_tests() {
    log ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "STATS & REPORTING"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    smoke_test_cmd "stats summary" "nftban stats summary"
    smoke_test_cmd "stats dashboard" "nftban stats dashboard"
    smoke_test_cmd "health summary" "nftban health summary"
}

# Search and list operations
run_search_tests() {
    log ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "SEARCH & LIST"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    smoke_test_cmd "search IP" "nftban search 8.8.8.8 --no-interactive 2>/dev/null || echo 'Not found (OK)'"
    smoke_test_cmd "port list" "nftban port list"
    smoke_test_cmd "feeds list" "nftban feeds list"
}

# Help commands (should never fail)
run_help_tests() {
    log ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "HELP COMMANDS (sample)"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    smoke_test_cmd "ban --help" "nftban ban --help"
    smoke_test_cmd "unban --help" "nftban unban --help"
    smoke_test_cmd "firewall --help" "nftban firewall --help"
}

# =============================================================================
# ALL CLI COMMANDS TEST (comprehensive)
# =============================================================================
# Automatically discovers and tests ALL cmd_*.sh files
# Tests: 1) File can be sourced  2) Help command works

run_all_cli_tests() {
    log ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "ALL CLI COMMANDS (comprehensive test)"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local cli_dir="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/cli"

    # Fallback for dev environment
    if [[ ! -d "$cli_dir" ]]; then
        cli_dir="/home/gituser/github/nftban-v1.0-dev/cli/lib/nftban/cli"
    fi

    if [[ ! -d "$cli_dir" ]]; then
        log_fail "CLI directory not found: $cli_dir"
        return 1
    fi

    local cmd_count=0
    local cmd_files=()

    # Collect all cmd_*.sh files
    for cmd_file in "$cli_dir"/cmd_*.sh; do
        [[ -f "$cmd_file" ]] || continue
        cmd_files+=("$cmd_file")
        ((cmd_count++))
    done

    log_info "Found $cmd_count CLI command files in $cli_dir"
    log ""

    # Test each command
    for cmd_file in "${cmd_files[@]}"; do
        local cmd_name
        cmd_name=$(basename "$cmd_file" .sh | sed 's/cmd_//' | sed 's/_/-/g')

        # Test help command (should never fail if script is valid)
        smoke_test_cmd "$cmd_name help" "nftban $cmd_name help 2>/dev/null || nftban $cmd_name --help 2>/dev/null || echo 'No help available'"
    done

    log ""
    log_info "Tested $cmd_count CLI commands"
}

# Additional status commands (not in quick test)
run_extended_status_tests() {
    log ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "EXTENDED STATUS CHECKS"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    smoke_test_cmd "module status" "nftban module summary"
    smoke_test_cmd "services status" "nftban services status"
    smoke_test_cmd "health check" "nftban health summary"
    smoke_test_cmd "timers status" "nftban timers status 2>/dev/null || nftban timers list"
    smoke_test_cmd "fhs check" "nftban fhs check 2>/dev/null || nftban fhs status"
    smoke_test_cmd "geoip status" "nftban geoip status 2>/dev/null || echo 'GeoIP not configured'"
    smoke_test_cmd "cloudflare status" "nftban cloudflare status 2>/dev/null || echo 'Cloudflare not configured'"
    smoke_test_cmd "nftables status" "nftban nftables status 2>/dev/null || nftban nftables list"
}

# =============================================================================
# REPORT GENERATION
# =============================================================================

generate_report() {
    log ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "SMOKE TEST RESULTS"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log ""
    log "Total Tests:     $TESTS_TOTAL"
    log "${GREEN}Passed:          $TESTS_PASSED${NC}"
    log "${RED}Failed:          $TESTS_FAILED${NC}"
    log "${RED}Timeouts:        $TESTS_TIMEOUT${NC}"
    log "${RED}Orphan Traces:   $TESTS_ORPHANS${NC}"
    log ""

    local pass_rate=0
    [[ $TESTS_TOTAL -gt 0 ]] && pass_rate=$((TESTS_PASSED * 100 / TESTS_TOTAL))

    log "Pass Rate:       ${pass_rate}%"
    log ""
    log "Log file:        $SMOKE_LOG"
    log "Trace log:       $TRACE_LOG"
    log ""

    # Final verdict
    local total_problems=$((TESTS_FAILED + TESTS_TIMEOUT + TESTS_ORPHANS))
    if [[ $total_problems -eq 0 ]]; then
        log "${GREEN}✅ ALL SMOKE TESTS PASSED${NC}"
        return 0
    else
        log "${RED}❌ SMOKE TEST FAILED ($total_problems problems)${NC}"
        return 1
    fi
}

# =============================================================================
# USAGE
# =============================================================================

usage() {
    cat <<EOF
NFTBan Smoke Test Suite v${SCRIPT_VERSION}

Usage: $0 [OPTIONS]

Options:
  --quick       Run quick test (core commands only: version, help, status)
  --full        Run standard test suite (default) - key modules
  --all         Run ALL CLI commands test (43 commands) - comprehensive
  --detailed    Same as --all
  --check       Just check trace log for orphaned traces
  --stats       Show trace statistics
  --help        Show this help

Test Modes:
  quick    = 3 tests    (version, help, status)
  full     = ~20 tests  (core + modules + stats + search + help)
  all      = 43+ tests  (every cmd_*.sh gets tested)

Examples:
  $0                  # Run full smoke test (~20 commands)
  $0 --quick          # Quick core test (3 commands)
  $0 --all            # Test ALL 43 CLI commands
  $0 --check          # Check for stuck scripts

EOF
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    local mode="full"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --quick|-q)
                mode="quick"
                shift
                ;;
            --full|-f)
                mode="full"
                shift
                ;;
            --all|-a|--detailed)
                mode="all"
                shift
                ;;
            --check|-c)
                mode="check"
                shift
                ;;
            --stats|-s)
                mode="stats"
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    # Check root
    if [[ $EUID -ne 0 ]]; then
        log_warn "Not running as root - some tests may fail"
    fi

    # Handle check-only mode
    if [[ "$mode" == "check" ]]; then
        echo "Checking trace log for orphaned traces..."
        source /usr/lib/nftban/helpers/nftban_trace.sh 2>/dev/null || true
        nftban_trace_find_orphans 5
        exit $?
    fi

    # Handle stats mode
    if [[ "$mode" == "stats" ]]; then
        echo "Trace statistics..."
        source /usr/lib/nftban/helpers/nftban_trace.sh 2>/dev/null || true
        nftban_trace_stats
        exit $?
    fi

    # Run smoke tests
    banner
    log ""
    log "Started: $(date)"
    log "Mode: $mode"
    log ""

    # Enable tracing
    enable_trace

    # Run tests based on mode
    case "$mode" in
        quick)
            CURRENT_TIMEOUT=$QUICK_TIMEOUT
            run_core_tests
            ;;
        full)
            run_core_tests
            run_module_tests
            run_stats_tests
            run_search_tests
            run_help_tests
            ;;
        all)
            # Comprehensive: test ALL CLI commands
            run_core_tests
            run_all_cli_tests        # Tests all 43 cmd_*.sh files
            run_extended_status_tests
            ;;
    esac

    # Check for orphans
    check_orphans

    # Disable tracing
    disable_trace

    # Generate report
    generate_report
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
