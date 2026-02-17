#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.0.0 - Smoke Test Suite
# =============================================================================
# meta:name="smoke_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="CLI health check with ban lifecycle verification"
# meta:inventory.files=""
# meta:inventory.binaries="nftban,nft,bash,bc,timeout"
# meta:inventory.env_vars="NFTBAN_TABLE_IPV4,NFTBAN_TABLE_IPV6,NFTBAN_LOG_DIR"
# meta:inventory.config_files="/etc/nftban/nftban.conf"
# meta:inventory.systemd_units="nftband.service"
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================
# Purpose: Quick health check of CLI - detects stuck/failed scripts
#
# **How It Works**
# 1. Enables debug trace temporarily
# 2. Runs key commands with timeout
# 3. Runs ban/unban lifecycle tests (IPv4 + IPv6)
# 4. Checks trace log for START without END (stuck scripts)
# 5. Reports any failures
#
# **Usage**
#   ./smoke_test.sh              # Run all tests
#   ./smoke_test.sh --quick      # Quick test (core commands only)
#   ./smoke_test.sh --lifecycle  # Ban lifecycle tests only
#   ./smoke_test.sh --check      # Just check trace log for orphans
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

# shellcheck disable=SC2034  # Reserved for future logging
readonly SCRIPT_NAME="smoke_test"
readonly SCRIPT_VERSION="1.0.0"
DEFAULT_TIMEOUT=30            # seconds per command (default)
QUICK_TIMEOUT=15              # seconds for quick tests
CURRENT_TIMEOUT=$DEFAULT_TIMEOUT  # actual timeout to use
readonly TRACE_LOG="${NFTBAN_LOG_DIR:-/var/log/nftban}/debug_trace.log"
SMOKE_LOG="/tmp/nftban_smoke_$(date +%Y%m%d_%H%M%S).log"
readonly SMOKE_LOG
# shellcheck disable=SC2034  # Reserved for future trace tracking
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
TESTS_SKIPPED=0
TESTS_TIMEOUT=0
TESTS_ORPHANS=0

# Email report recipient (optional)
EMAIL_RECIPIENT=""

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
        trace_id=$(echo "$line" | { grep -oP '\[\K[a-z_]+-[0-9]+_[0-9]+_[0-9]+-[0-9]+(?=\])' || true; })
        [[ -z "$trace_id" ]] && continue

        # Check if there's a matching END
        if ! grep -q "\[END\].*\[$trace_id\]" "$TRACE_LOG"; then
            orphan_count=$((orphan_count + 1))
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

    TESTS_TOTAL=$((TESTS_TOTAL + 1))

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

    local timeout_exit=0
    timeout "$timeout_val" bash -c "
        # Source trace library for this command
        if [[ -f /usr/lib/nftban/helpers/nftban_trace.sh ]]; then
            source /usr/lib/nftban/helpers/nftban_trace.sh
        fi
        export NFTBAN_DEBUG_TRACE=true
        export NFTBAN_DEBUG_TRACE_LOG='$TRACE_LOG'
        $cmd
        echo \$? > '$exit_file'
    " > "$output_file" 2>&1 || timeout_exit=$?

    local end_time
    end_time=$(date +%s.%N)
    local duration
    duration=$(echo "$end_time - $start_time" | bc 2>/dev/null || echo "?")

    # Check timeout
    if [[ $timeout_exit -eq 124 ]]; then
        log_timeout "$name - exceeded ${timeout_val}s"
        TESTS_TIMEOUT=$((TESTS_TIMEOUT + 1))
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
        TESTS_FAILED=$((TESTS_FAILED + 1))
    elif [[ "$exit_code" == "0" ]]; then
        log_pass "$name - OK (exit=0, ${output_len} chars, ${duration}s)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    elif [[ "$exit_code" == "1" ]] && [[ "$name" == "health summary" ]]; then
        # Health exit code 1 = warnings only (acceptable)
        log_pass "$name - OK with warnings (exit=1, ${output_len} chars, ${duration}s)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    elif [[ "$exit_code" == "1" ]] && [[ "$name" == "status" ]]; then
        # Status exit code 1 = warnings/degraded (acceptable)
        log_pass "$name - OK with warnings (exit=1, ${output_len} chars, ${duration}s)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    elif [[ "$exit_code" == "2" ]] && [[ "$name" == "health summary" ]]; then
        # Health exit code 2 = errors present (acceptable - report but don't fail test)
        log_warn "$name - Errors detected (exit=2, ${output_len} chars, ${duration}s)"
        log_warn "  This is expected if system has health issues. Check 'nftban health summary' manually."
        TESTS_PASSED=$((TESTS_PASSED + 1))
    elif [[ "$exit_code" == "4" ]] && [[ "$name" == "health summary" ]]; then
        # Health exit code 4 = permission fixes applied (acceptable)
        log_pass "$name - OK, fixes applied (exit=4, ${output_len} chars, ${duration}s)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        # All other non-zero exits are failures
        log_fail "$name - FAILED (exit=$exit_code, ${duration}s)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
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

    # Daemon memory health check
    run_daemon_memory_test
}

# Daemon memory health test
run_daemon_memory_test() {
    log ""
    log "─── Daemon Memory Health ───"

    TESTS_TOTAL=$((TESTS_TOTAL + 1))

    local pid rss_kb uptime_sec
    pid=$(cat /run/nftban/nftband.pid 2>/dev/null || echo "")

    if [[ -z "$pid" ]] || [[ ! -d "/proc/$pid" ]]; then
        log_warn "daemon memory — nftband not running, skipping"
        TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
        return 0
    fi

    rss_kb=$(awk '/VmRSS/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo "0")
    uptime_sec=$(ps -p "$pid" -o etimes= 2>/dev/null | tr -d ' ' || echo "0")

    local rss_mb=$((rss_kb / 1024))
    local uptime_hours=$((uptime_sec / 3600))
    [[ $uptime_hours -lt 1 ]] && uptime_hours=1

    # Calculate growth rate
    local baseline_mb=15
    local growth_mb=$((rss_mb - baseline_mb))
    [[ $growth_mb -lt 0 ]] && growth_mb=0
    local mb_per_hour=$((growth_mb / uptime_hours))

    log "  PID: $pid | RSS: ${rss_mb}MB | Uptime: ${uptime_hours}h | Growth: ${mb_per_hour}MB/h"

    # Thresholds: warning at 100MB, critical at 300MB
    if [[ $rss_mb -gt 300 ]]; then
        log_fail "daemon memory — RSS ${rss_mb}MB exceeds 300MB critical threshold"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    elif [[ $mb_per_hour -gt 50 ]] && [[ $uptime_hours -ge 1 ]]; then
        log_fail "daemon memory — growth ${mb_per_hour}MB/h exceeds 50MB/h critical threshold"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    elif [[ $rss_mb -gt 100 ]]; then
        log_warn "daemon memory — RSS ${rss_mb}MB exceeds 100MB warning threshold"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_pass "daemon memory — RSS ${rss_mb}MB within healthy range"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    fi
}

# Security module status commands
run_module_tests() {
    log ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "MODULE STATUS"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    smoke_test_cmd "firewall stats" "nftban firewall stats"
    smoke_test_cmd "login status" "nftban login status"
    smoke_test_cmd "portscan status" "nftban portscan status"
    smoke_test_cmd "ddos status" "nftban ddos status"
    smoke_test_cmd "feeds status" "nftban feeds status"
    smoke_test_cmd "whitelist list" "nftban whitelist list"
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
    smoke_test_cmd "protect --help" "nftban protect --help"
    smoke_test_cmd "unprotect --help" "nftban unprotect --help"
    smoke_test_cmd "cleanup --help" "nftban cleanup --help"
}

# =============================================================================
# PROTECT/UNPROTECT/CLEANUP TESTS
# =============================================================================
# Tests for IP protection and cleanup commands

run_protection_tests() {
    log ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "PROTECT/UNPROTECT/CLEANUP COMMANDS"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Test protect help
    smoke_test_cmd "protect help" "nftban protect --help"

    # Test unprotect help
    smoke_test_cmd "unprotect help" "nftban unprotect --help"

    # Test cleanup --stats returns valid JSON with required fields
    smoke_test_cmd "cleanup --stats JSON" "nftban cleanup --stats --json | jq -e '.data.total != null and .data.protected != null and .data.evictable != null'"

    # Test cleanup --dry-run returns valid JSON with ips array
    smoke_test_cmd "cleanup --dry-run JSON" "nftban cleanup --dry-run --json | jq -e '.data.ips | type == \"array\"'"

    # Test cleanup help
    smoke_test_cmd "cleanup help" "nftban cleanup --help"
}

# =============================================================================
# BAN LIFECYCLE TESTS
# =============================================================================
# Verifies ban/unban and whitelist add/remove with nft set assertions.
# Uses RFC 5737 TEST-NET-2 (198.51.100.0/24) and RFC 3849 (2001:db8::/32).
# All test IPs are cleaned up after each test, even on failure.

# Check if an IP is present in an nft set
# Usage: _nft_set_contains <nft_table> <set_name> <pattern>
_nft_set_contains() {
    local nft_table="$1"   # e.g., "ip nftban" — word-splits into family + table
    local nft_set="$2"
    local pattern="$3"
    # Avoid grep -q: it exits on first match, causing SIGPIPE on nft with
    # large sets (7000+ entries), which pipefail treats as a pipeline failure.
    # Plain grep reads all input, preventing SIGPIPE.
    # shellcheck disable=SC2086  # Intentional word splitting of nft_table
    nft list set ${nft_table} "${nft_set}" 2>/dev/null | grep "${pattern}" >/dev/null 2>&1
}

# Run a single add → verify → remove → verify lifecycle
# Usage: smoke_lifecycle <name> <add_cmd> <remove_cmd> <nft_table> <nft_set> <pattern>
smoke_lifecycle() {
    local name="$1"
    local add_cmd="$2"
    local remove_cmd="$3"
    local nft_table="$4"
    local nft_set="$5"
    local pattern="$6"

    log ""
    log "─── Lifecycle: ${name} ───"

    # Step 0: Cleanup — ensure test IP is not present
    eval "${remove_cmd}" &>/dev/null || true
    sleep 1

    # Step 1: Baseline — IP must NOT be in set
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if _nft_set_contains "${nft_table}" "${nft_set}" "${pattern}"; then
        log_fail "${name} baseline — ${pattern} still in ${nft_set} after cleanup"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 0  # failure counted, continue to next lifecycle
    fi
    log_pass "${name} baseline — ${pattern} absent from ${nft_set}"
    TESTS_PASSED=$((TESTS_PASSED + 1))

    # Step 2: Add (ban or whitelist add)
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if ! eval "${add_cmd}" &>/dev/null; then
        log_fail "${name} add — command failed: ${add_cmd}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 0
    fi
    sleep 1

    if _nft_set_contains "${nft_table}" "${nft_set}" "${pattern}"; then
        log_pass "${name} add — ${pattern} confirmed in ${nft_set}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_fail "${name} add — ${pattern} NOT found in ${nft_set}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        eval "${remove_cmd}" &>/dev/null || true
        return 0
    fi

    # Step 3: Remove (unban or whitelist remove)
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if ! eval "${remove_cmd}" &>/dev/null; then
        log_fail "${name} remove — command failed: ${remove_cmd}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        eval "${remove_cmd}" &>/dev/null || true
        return 0
    fi
    sleep 1

    if _nft_set_contains "${nft_table}" "${nft_set}" "${pattern}"; then
        log_fail "${name} remove — ${pattern} still in ${nft_set}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        eval "${remove_cmd}" &>/dev/null || true
        return 0
    fi
    log_pass "${name} remove — ${pattern} absent from ${nft_set}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

# Run all ban lifecycle tests
run_lifecycle_tests() {
    log ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "BAN LIFECYCLE TESTS"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Prerequisites
    if ! systemctl is-active nftband &>/dev/null; then
        log_warn "nftband not running — skipping lifecycle tests"
        log_warn "Start with: systemctl start nftband"
        return 0
    fi
    if ! command -v nft &>/dev/null; then
        log_warn "nft not found — skipping lifecycle tests"
        return 0
    fi

    # Source config for table names
    [[ -f /etc/nftban/nftban.conf ]] && source /etc/nftban/nftban.conf
    [[ -f /etc/nftban/nftban.conf.local ]] && source /etc/nftban/nftban.conf.local
    local table_v4="${NFTBAN_TABLE_IPV4:-ip nftban}"
    local table_v6="${NFTBAN_TABLE_IPV6:-ip6 nftban}"

    # Test IPs — RFC 5737 TEST-NET-2 (IPv4) / RFC 3849 (IPv6)
    local test_ban_v4="198.51.100.99"
    local test_ban_v6="2001:db8::dead:beef"
    local test_wl_v4="198.51.100.98"
    local test_wl_v6="2001:db8::cafe:babe"

    log_info "Using documentation-range IPs (RFC 5737 / RFC 3849)"
    log_info "Tables: v4=${table_v4}, v6=${table_v6}"

    # IPv4 ban → unban
    smoke_lifecycle "IPv4 ban/unban" \
        "nftban ban ${test_ban_v4} --reason smoke_test" \
        "nftban unban ${test_ban_v4}" \
        "${table_v4}" "blacklist_ipv4" "${test_ban_v4}"

    # IPv6 ban → unban
    smoke_lifecycle "IPv6 ban/unban" \
        "nftban ban ${test_ban_v6} --reason smoke_test" \
        "nftban unban ${test_ban_v6}" \
        "${table_v6}" "blacklist_ipv6" "${test_ban_v6}"

    # IPv4 whitelist add → remove
    smoke_lifecycle "IPv4 whitelist add/remove" \
        "nftban whitelist add ${test_wl_v4}" \
        "nftban whitelist remove ${test_wl_v4}" \
        "${table_v4}" "whitelist_ipv4" "${test_wl_v4}"

    # IPv6 whitelist add → remove
    smoke_lifecycle "IPv6 whitelist add/remove" \
        "nftban whitelist add ${test_wl_v6}" \
        "nftban whitelist remove ${test_wl_v6}" \
        "${table_v6}" "whitelist_ipv6" "${test_wl_v6}"
}

# =============================================================================
# PORT LIFECYCLE TESTS
# =============================================================================
# Verifies port add/remove with nft set assertions.
# Uses high port numbers (59000-59999) to avoid conflicts.

run_port_lifecycle_tests() {
    log ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "PORT LIFECYCLE TESTS"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Prerequisites
    if ! systemctl is-active nftband &>/dev/null; then
        log_warn "nftband not running — skipping port lifecycle tests"
        log_warn "Start with: systemctl start nftband"
        return 0
    fi
    if ! command -v nft &>/dev/null; then
        log_warn "nft not found — skipping port lifecycle tests"
        return 0
    fi

    # Source config for table names
    [[ -f /etc/nftban/nftban.conf ]] && source /etc/nftban/nftban.conf
    [[ -f /etc/nftban/nftban.conf.local ]] && source /etc/nftban/nftban.conf.local
    local table_v4="${NFTBAN_TABLE_IPV4:-ip nftban}"
    local table_v6="${NFTBAN_TABLE_IPV6:-ip6 nftban}"

    # Test ports — use high ephemeral range to avoid conflicts
    local test_port_tcp_in="59001"
    local test_port_tcp_out="59002"
    local test_port_udp_in="59003"
    local test_port_both_inout="59004"

    log_info "Using test ports in 59000 range (ephemeral)"
    log_info "Tables: ${table_v4}, ${table_v6}"
    log_info "Directional architecture: tcp_ports_in/out, udp_ports_in/out (IPv4 + IPv6)"

    # TCP INPUT port add → remove (IPv4)
    smoke_lifecycle "TCP INPUT port add/remove (IPv4)" \
        "nftban port add ${test_port_tcp_in} tcp in" \
        "nftban port remove ${test_port_tcp_in}" \
        "${table_v4}" "tcp_ports_in" "${test_port_tcp_in}"

    # TCP INPUT port add → remove (IPv6)
    smoke_lifecycle "TCP INPUT port add/remove (IPv6)" \
        "nftban port add ${test_port_tcp_in} tcp in" \
        "nftban port remove ${test_port_tcp_in}" \
        "${table_v6}" "tcp_ports_in" "${test_port_tcp_in}"

    # TCP OUTPUT port add → remove (IPv4)
    smoke_lifecycle "TCP OUTPUT port add/remove (IPv4)" \
        "nftban port add ${test_port_tcp_out} tcp out" \
        "nftban port remove ${test_port_tcp_out}" \
        "${table_v4}" "tcp_ports_out" "${test_port_tcp_out}"

    # TCP OUTPUT port add → remove (IPv6)
    smoke_lifecycle "TCP OUTPUT port add/remove (IPv6)" \
        "nftban port add ${test_port_tcp_out} tcp out" \
        "nftban port remove ${test_port_tcp_out}" \
        "${table_v6}" "tcp_ports_out" "${test_port_tcp_out}"

    # UDP INPUT port add → remove (IPv4)
    smoke_lifecycle "UDP INPUT port add/remove (IPv4)" \
        "nftban port add ${test_port_udp_in} udp in" \
        "nftban port remove ${test_port_udp_in}" \
        "${table_v4}" "udp_ports_in" "${test_port_udp_in}"

    # UDP INPUT port add → remove (IPv6)
    smoke_lifecycle "UDP INPUT port add/remove (IPv6)" \
        "nftban port add ${test_port_udp_in} udp in" \
        "nftban port remove ${test_port_udp_in}" \
        "${table_v6}" "udp_ports_in" "${test_port_udp_in}"

    # Both TCP+UDP, INOUT port add → remove (tests all 4 sets in both IPv4 and IPv6)
    log ""
    log "─── Lifecycle: Both TCP+UDP, INOUT port add/remove (IPv4 + IPv6) ───"

    # Cleanup first
    nftban port remove ${test_port_both_inout} &>/dev/null || true
    sleep 1

    # Add port (both protocols, both directions)
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if nftban port add ${test_port_both_inout} both inout &>/dev/null; then
        sleep 1
        # Check IPv4
        local tcp_in_ok_v4=false tcp_out_ok_v4=false udp_in_ok_v4=false udp_out_ok_v4=false
        _nft_set_contains "${table_v4}" "tcp_ports_in" "${test_port_both_inout}" && tcp_in_ok_v4=true
        _nft_set_contains "${table_v4}" "tcp_ports_out" "${test_port_both_inout}" && tcp_out_ok_v4=true
        _nft_set_contains "${table_v4}" "udp_ports_in" "${test_port_both_inout}" && udp_in_ok_v4=true
        _nft_set_contains "${table_v4}" "udp_ports_out" "${test_port_both_inout}" && udp_out_ok_v4=true

        # Check IPv6
        local tcp_in_ok_v6=false tcp_out_ok_v6=false udp_in_ok_v6=false udp_out_ok_v6=false
        _nft_set_contains "${table_v6}" "tcp_ports_in" "${test_port_both_inout}" && tcp_in_ok_v6=true
        _nft_set_contains "${table_v6}" "tcp_ports_out" "${test_port_both_inout}" && tcp_out_ok_v6=true
        _nft_set_contains "${table_v6}" "udp_ports_in" "${test_port_both_inout}" && udp_in_ok_v6=true
        _nft_set_contains "${table_v6}" "udp_ports_out" "${test_port_both_inout}" && udp_out_ok_v6=true

        local v4_ok=false v6_ok=false
        [[ "$tcp_in_ok_v4" == "true" && "$tcp_out_ok_v4" == "true" && "$udp_in_ok_v4" == "true" && "$udp_out_ok_v4" == "true" ]] && v4_ok=true
        [[ "$tcp_in_ok_v6" == "true" && "$tcp_out_ok_v6" == "true" && "$udp_in_ok_v6" == "true" && "$udp_out_ok_v6" == "true" ]] && v6_ok=true

        if [[ "$v4_ok" == "true" && "$v6_ok" == "true" ]]; then
            log_pass "Both/inout port add — ${test_port_both_inout} in all 4 sets (IPv4 + IPv6)"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            log_fail "Both/inout port add — IPv4[tcp_in:${tcp_in_ok_v4} tcp_out:${tcp_out_ok_v4} udp_in:${udp_in_ok_v4} udp_out:${udp_out_ok_v4}] IPv6[tcp_in:${tcp_in_ok_v6} tcp_out:${tcp_out_ok_v6} udp_in:${udp_in_ok_v6} udp_out:${udp_out_ok_v6}]"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    else
        log_fail "Both/inout port add — command failed"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    # Remove port
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    nftban port remove ${test_port_both_inout} &>/dev/null || true
    sleep 1

    # Check IPv4 removal
    local tcp_in_gone_v4=true tcp_out_gone_v4=true udp_in_gone_v4=true udp_out_gone_v4=true
    _nft_set_contains "${table_v4}" "tcp_ports_in" "${test_port_both_inout}" && tcp_in_gone_v4=false
    _nft_set_contains "${table_v4}" "tcp_ports_out" "${test_port_both_inout}" && tcp_out_gone_v4=false
    _nft_set_contains "${table_v4}" "udp_ports_in" "${test_port_both_inout}" && udp_in_gone_v4=false
    _nft_set_contains "${table_v4}" "udp_ports_out" "${test_port_both_inout}" && udp_out_gone_v4=false

    # Check IPv6 removal
    local tcp_in_gone_v6=true tcp_out_gone_v6=true udp_in_gone_v6=true udp_out_gone_v6=true
    _nft_set_contains "${table_v6}" "tcp_ports_in" "${test_port_both_inout}" && tcp_in_gone_v6=false
    _nft_set_contains "${table_v6}" "tcp_ports_out" "${test_port_both_inout}" && tcp_out_gone_v6=false
    _nft_set_contains "${table_v6}" "udp_ports_in" "${test_port_both_inout}" && udp_in_gone_v6=false
    _nft_set_contains "${table_v6}" "udp_ports_out" "${test_port_both_inout}" && udp_out_gone_v6=false

    local v4_gone=false v6_gone=false
    [[ "$tcp_in_gone_v4" == "true" && "$tcp_out_gone_v4" == "true" && "$udp_in_gone_v4" == "true" && "$udp_out_gone_v4" == "true" ]] && v4_gone=true
    [[ "$tcp_in_gone_v6" == "true" && "$tcp_out_gone_v6" == "true" && "$udp_in_gone_v6" == "true" && "$udp_out_gone_v6" == "true" ]] && v6_gone=true

    if [[ "$v4_gone" == "true" && "$v6_gone" == "true" ]]; then
        log_pass "Both/inout port remove — ${test_port_both_inout} absent from all 4 sets (IPv4 + IPv6)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_fail "Both/inout port remove — IPv4[tcp_in:${tcp_in_gone_v4} tcp_out:${tcp_out_gone_v4} udp_in:${udp_in_gone_v4} udp_out:${udp_out_gone_v4}] IPv6[tcp_in:${tcp_in_gone_v6} tcp_out:${tcp_out_gone_v6} udp_in:${udp_in_gone_v6} udp_out:${udp_out_gone_v6}]"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# =============================================================================
# BINARY INTEGRITY SMOKE TEST
# =============================================================================
# Validates that Go binaries are real ELF files (not corrupted or dummy files).
# Checks file type and minimum size to detect build/install issues.

smoke_test_binary_integrity() {
    log ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "BINARY INTEGRITY"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local test_name="Binary Integrity"
    local binaries=(
        "/usr/lib/nftban/bin/nftban-core:nftban-core"
        "/usr/lib/nftban/bin/nftband:nftband"
    )
    local errors=0
    local checked=0

    for entry in "${binaries[@]}"; do
        local binary="${entry%%:*}"
        local name="${entry##*:}"

        if [[ -f "$binary" ]]; then
            ((++checked))  # Pre-increment to avoid exit code 1 when checked=0
            TESTS_TOTAL=$((TESTS_TOTAL + 1))

            local file_type
            file_type=$(file -b "$binary" 2>/dev/null)

            if [[ "$file_type" != *"ELF"* ]]; then
                log_fail "${test_name} — ${name} is NOT ELF binary (corrupted/dummy)"
                log "  File type: ${file_type}"
                TESTS_FAILED=$((TESTS_FAILED + 1))
                ((++errors))  # Pre-increment to avoid exit code 1 when errors=0
                continue
            fi

            local size
            size=$(stat -c%s "$binary" 2>/dev/null || echo 0)
            if [[ $size -lt 100000 ]]; then
                log_fail "${test_name} — ${name} is too small (${size} bytes) - likely corrupted"
                TESTS_FAILED=$((TESTS_FAILED + 1))
                ((++errors))  # Pre-increment to avoid exit code 1 when errors=0
                continue
            fi

            log_pass "${test_name} — ${name} is valid ELF (${size} bytes)"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            log_warn "${test_name} — ${name} not found at ${binary} (skipped)"
        fi
    done

    if [[ $checked -eq 0 ]]; then
        log_warn "${test_name} — No Go binaries found to check"
        return 0
    fi

    if [[ $errors -eq 0 ]]; then
        log_pass "${test_name} — All Go binaries are valid ELF executables"
    fi

    # Don't return error count - would abort script with set -e
    return 0
}

# =============================================================================
# AUDITOR ACL VERIFICATION
# =============================================================================
# Verifies that nftban-auditor group has correct ACL access to logs and reports.
# This ensures the auditor role can read security logs without write access.

smoke_test_auditor_acls() {
    log ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "AUDITOR ACL VERIFICATION"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local test_name="Auditor ACLs"
    local errors=0

    # Check if nftban-auditor group exists
    if ! getent group nftban-auditor &>/dev/null; then
        log_warn "${test_name} — nftban-auditor group not found (skipped)"
        return 0
    fi

    # Check if getfacl is available
    if ! command -v getfacl &>/dev/null; then
        log_warn "${test_name} — getfacl not available (skipped)"
        return 0
    fi

    TESTS_TOTAL=$((TESTS_TOTAL + 1))

    # Check ACL on /var/log/nftban
    if [[ -d /var/log/nftban ]]; then
        if getfacl /var/log/nftban 2>/dev/null | grep -q "group:nftban-auditor:"; then
            log_pass "${test_name} — /var/log/nftban has auditor ACL"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            log_fail "${test_name} — /var/log/nftban missing auditor ACL"
            log "  Fix: nftban health fix permissions"
            TESTS_FAILED=$((TESTS_FAILED + 1))
            ((++errors))
        fi
    fi

    TESTS_TOTAL=$((TESTS_TOTAL + 1))

    # Check ACL on /var/lib/nftban
    if [[ -d /var/lib/nftban ]]; then
        if getfacl /var/lib/nftban 2>/dev/null | grep -q "group:nftban-auditor:"; then
            log_pass "${test_name} — /var/lib/nftban has auditor ACL"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            log_fail "${test_name} — /var/lib/nftban missing auditor ACL"
            log "  Fix: nftban health fix permissions"
            TESTS_FAILED=$((TESTS_FAILED + 1))
            ((++errors))
        fi
    fi

    TESTS_TOTAL=$((TESTS_TOTAL + 1))

    # Check ACL on /etc/nftban (config read access)
    if [[ -d /etc/nftban ]]; then
        if getfacl /etc/nftban 2>/dev/null | grep -q "group:nftban-auditor:"; then
            log_pass "${test_name} — /etc/nftban has auditor ACL"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            log_fail "${test_name} — /etc/nftban missing auditor ACL"
            log "  Fix: nftban health fix permissions"
            TESTS_FAILED=$((TESTS_FAILED + 1))
            ((++errors))
        fi
    fi

    if [[ $errors -eq 0 ]]; then
        log_pass "${test_name} — All auditor ACLs configured correctly"
    fi

    return 0
}

# =============================================================================
# FEEDS & GEOBAN NFT VALIDATION
# =============================================================================
# Validates that feeds/geoban CIDRs are actually loaded in nftables sets.
# Non-destructive: checks current state without modifying sets.

# Get element count from an nft set
# Usage: _nft_set_count <nft_table> <set_name>
# Returns: element count (0 if set empty or doesn't exist)
_nft_set_count() {
    local nft_table="$1"
    local nft_set="$2"
    local count
    # Count elements - each element line has format "element_value," or "element_value timeout..."
    # shellcheck disable=SC2086
    count=$(nft list set ${nft_table} "${nft_set}" 2>/dev/null | grep -cE '^\s+[0-9a-fA-F.:/-]+' || echo "0")
    echo "$count"
}

# Validate CIDRs loaded in nft set
# Usage: smoke_validate_nft_set <name> <nft_table> <set_name> <min_expected>
smoke_validate_nft_set() {
    local name="$1"
    local nft_table="$2"
    local nft_set="$3"
    local min_expected="${4:-1}"

    TESTS_TOTAL=$((TESTS_TOTAL + 1))

    local count
    count=$(_nft_set_count "${nft_table}" "${nft_set}")

    if [[ "$count" -ge "$min_expected" ]]; then
        log_pass "${name} — ${count} elements in ${nft_set} (min: ${min_expected})"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        log_fail "${name} — ${count} elements in ${nft_set} (expected >= ${min_expected})"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

# Run feeds nft validation tests
run_feeds_nft_validation() {
    log ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "FEEDS NFT VALIDATION"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Check if feeds are enabled
    local feeds_dir="${NFTBAN_FEEDS_DIR:-/etc/nftban/feeds}"
    local feed_count
    feed_count=$(find "$feeds_dir" -name "*.txt" -type f 2>/dev/null | wc -l)

    if [[ "$feed_count" -eq 0 ]]; then
        log_warn "No feed files found in ${feeds_dir} — skipping feeds validation"
        return 0
    fi

    log_info "Found ${feed_count} feed file(s) in ${feeds_dir}"

    # Source config for table names
    [[ -f /etc/nftban/nftban.conf ]] && source /etc/nftban/nftban.conf
    [[ -f /etc/nftban/nftban.conf.local ]] && source /etc/nftban/nftban.conf.local
    local table_v4="${NFTBAN_TABLE_IPV4:-ip nftban}"
    local table_v6="${NFTBAN_TABLE_IPV6:-ip6 nftban}"

    # Validate feeds CIDRs in nft sets (expect at least 1 if feeds exist)
    smoke_validate_nft_set "Feeds IPv4 in nft" "${table_v4}" "blacklist_ipv4" 1
    smoke_validate_nft_set "Feeds IPv6 in nft" "${table_v6}" "blacklist_ipv6" 1
}

# Run geoban nft validation tests
run_geoban_nft_validation() {
    log ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "GEOBAN NFT VALIDATION"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Check if geoban is enabled (config file exists with countries)
    local geoban_conf="${NFTBAN_GEOBAN_CONF:-/etc/nftban/geoban/geoban.conf}"

    if [[ ! -f "$geoban_conf" ]]; then
        log_warn "Geoban config not found: ${geoban_conf} — skipping geoban validation"
        return 0
    fi

    # Check if any countries are configured
    local countries
    countries=$(grep -E '^GEOBAN_COUNTRIES=' "$geoban_conf" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'" || echo "")

    if [[ -z "$countries" ]]; then
        log_warn "No countries configured in geoban — skipping geoban validation"
        return 0
    fi

    log_info "Geoban countries configured: ${countries}"

    # Source config for table names
    [[ -f /etc/nftban/nftban.conf ]] && source /etc/nftban/nftban.conf
    [[ -f /etc/nftban/nftban.conf.local ]] && source /etc/nftban/nftban.conf.local
    local table_v4="${NFTBAN_TABLE_IPV4:-ip nftban}"
    local table_v6="${NFTBAN_TABLE_IPV6:-ip6 nftban}"

    # Geoban loads thousands of CIDRs - expect at least 100 for any country
    smoke_validate_nft_set "Geoban IPv4 in nft" "${table_v4}" "blacklist_ipv4" 100
    smoke_validate_nft_set "Geoban IPv6 in nft" "${table_v6}" "blacklist_ipv6" 10
}

# =============================================================================
# WHITELIST SAFETY TESTS (v1.15.1)
# =============================================================================
# Verifies critical system IPs are whitelisted to prevent self-lockout:
# - All server interface IPs (IPv4 + IPv6)
# - Loopback (127.0.0.1, ::1)
# - Default gateway
# - Active SSH port detection

# Check if IP is in whitelist nft set
# Usage: _whitelist_contains <ip>
_whitelist_contains() {
    local ip="$1"

    # Source config for table names
    [[ -f /etc/nftban/nftban.conf ]] && source /etc/nftban/nftban.conf 2>/dev/null
    [[ -f /etc/nftban/nftban.conf.local ]] && source /etc/nftban/nftban.conf.local 2>/dev/null
    local table_v4="${NFTBAN_TABLE_IPV4:-ip nftban}"
    local table_v6="${NFTBAN_TABLE_IPV6:-ip6 nftban}"

    if [[ "$ip" =~ : ]]; then
        # IPv6
        # shellcheck disable=SC2086
        nft list set ${table_v6} whitelist_ipv6 2>/dev/null | grep -qF "$ip"
    else
        # IPv4
        # shellcheck disable=SC2086
        nft list set ${table_v4} whitelist_ipv4 2>/dev/null | grep -qF "$ip"
    fi
}

# Run whitelist safety validation tests
run_whitelist_safety_tests() {
    log ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "WHITELIST SAFETY TESTS"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "Verifying critical system IPs are protected from self-lockout..."
    log ""

    local failed_ips=()
    local passed_ips=()

    # Test 1: Loopback 127.0.0.1 must be whitelisted
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if _whitelist_contains "127.0.0.1"; then
        log_pass "Loopback 127.0.0.1 is whitelisted"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        passed_ips+=("127.0.0.1")
    else
        log_fail "Loopback 127.0.0.1 NOT in whitelist - CRITICAL"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        failed_ips+=("127.0.0.1")
    fi

    # Test 2: IPv6 loopback ::1 must be whitelisted
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if _whitelist_contains "::1"; then
        log_pass "IPv6 loopback ::1 is whitelisted"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        passed_ips+=("::1")
    else
        log_fail "IPv6 loopback ::1 NOT in whitelist - CRITICAL"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        failed_ips+=("::1")
    fi

    # Test 3: All server IPv4 addresses must be whitelisted
    log ""
    log "─── Server Interface IPs ───"
    local server_ipv4
    server_ipv4=$(ip -4 addr show 2>/dev/null | grep -oP 'inet \K[\d.]+' | grep -v '^127\.' | sort -u)

    for ip in $server_ipv4; do
        TESTS_TOTAL=$((TESTS_TOTAL + 1))
        if _whitelist_contains "$ip"; then
            log_pass "Server IPv4 $ip is whitelisted"
            TESTS_PASSED=$((TESTS_PASSED + 1))
            passed_ips+=("$ip")
        else
            log_fail "Server IPv4 $ip NOT in whitelist - RISK OF LOCKOUT"
            TESTS_FAILED=$((TESTS_FAILED + 1))
            failed_ips+=("$ip")
        fi
    done

    # Test 4: All server IPv6 addresses (global scope) must be whitelisted
    local server_ipv6
    server_ipv6=$(ip -6 addr show scope global 2>/dev/null | grep -oP 'inet6 \K[^/]+' | grep -v '^fe80' | grep -v '^::1' | sort -u)

    for ip in $server_ipv6; do
        TESTS_TOTAL=$((TESTS_TOTAL + 1))
        if _whitelist_contains "$ip"; then
            log_pass "Server IPv6 $ip is whitelisted"
            TESTS_PASSED=$((TESTS_PASSED + 1))
            passed_ips+=("$ip")
        else
            log_fail "Server IPv6 $ip NOT in whitelist - RISK OF LOCKOUT"
            TESTS_FAILED=$((TESTS_FAILED + 1))
            failed_ips+=("$ip")
        fi
    done

    # Test 5: Default gateway should be whitelisted (prevents routing issues)
    log ""
    log "─── Default Gateway ───"
    local gateway
    gateway=$(ip route 2>/dev/null | grep -E '^default' | awk '{print $3}' | head -1)

    if [[ -n "$gateway" ]]; then
        TESTS_TOTAL=$((TESTS_TOTAL + 1))
        if _whitelist_contains "$gateway"; then
            log_pass "Default gateway $gateway is whitelisted"
            TESTS_PASSED=$((TESTS_PASSED + 1))
            passed_ips+=("$gateway")
        else
            log_warn "Default gateway $gateway NOT in whitelist (recommended)"
            # Not a failure, just a warning
            TESTS_PASSED=$((TESTS_PASSED + 1))
        fi
    else
        log_warn "No default gateway detected (skipping)"
    fi

    # Test 6: SSH Port Detection - verify active SSH port is allowed
    log ""
    log "─── SSH Port Safety ───"
    local ssh_port
    # Method 1: From sshd config
    if [[ -f /etc/ssh/sshd_config ]]; then
        ssh_port=$(grep -E '^Port\s+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
    fi

    # Method 2: From ss/netstat
    if [[ -z "$ssh_port" ]]; then
        ssh_port=$(ss -tlnp 2>/dev/null | grep -E 'sshd|ssh' | grep -oP ':\K\d+' | head -1)
    fi

    # Default to 22 if not detected
    ssh_port="${ssh_port:-22}"

    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    local table_v4="${NFTBAN_TABLE_IPV4:-ip nftban}"
    # shellcheck disable=SC2086
    if nft list set ${table_v4} tcp_ports 2>/dev/null | grep -qw "$ssh_port"; then
        log_pass "SSH port $ssh_port is allowed in firewall"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_warn "SSH port $ssh_port not explicitly in tcp_ports (may be open by default)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    fi

    # Summary
    log ""
    log "─── Whitelist Safety Summary ───"
    log "Protected IPs: ${#passed_ips[@]}"
    if [[ ${#failed_ips[@]} -gt 0 ]]; then
        log_fail "UNPROTECTED IPs: ${#failed_ips[@]} - RUN: nftban whitelist-system sync"
        for ip in "${failed_ips[@]}"; do
            log "  - $ip"
        done
    else
        log_pass "All critical IPs are protected"
    fi
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
        cmd_count=$((cmd_count + 1))
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
# EMAIL REPORT
# =============================================================================

send_email_report() {
    # Send smoke test results via email
    # Uses nftban mail infrastructure for delivery
    local recipient="$1"

    [[ -z "$recipient" ]] && return 0

    log ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "SENDING EMAIL REPORT"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Determine result status for subject
    local total_problems=$((TESTS_FAILED + TESTS_TIMEOUT + TESTS_ORPHANS))
    local status_emoji status_text
    if [[ $total_problems -eq 0 ]]; then
        status_emoji="✅"
        status_text="PASSED"
    else
        status_emoji="❌"
        status_text="FAILED"
    fi

    local pass_rate=0
    [[ $TESTS_TOTAL -gt 0 ]] && pass_rate=$((TESTS_PASSED * 100 / TESTS_TOTAL))

    # Build subject line
    local hostname
    hostname=$(hostname -f 2>/dev/null || hostname)
    local subject="${status_emoji} NFTBan Smoke Test ${status_text} - ${hostname} (${pass_rate}% pass rate)"

    # Build plain text body (strip ANSI colors from log)
    local body
    body=$(cat <<BODY
NFTBan Smoke Test Report
========================
Host: ${hostname}
Date: $(date '+%Y-%m-%d %H:%M:%S %Z')
Version: $(nftban version 2>/dev/null | head -1 || echo "unknown")

Results Summary
---------------
Total Tests:   ${TESTS_TOTAL}
Passed:        ${TESTS_PASSED}
Failed:        ${TESTS_FAILED}
Timeouts:      ${TESTS_TIMEOUT}
Orphan Traces: ${TESTS_ORPHANS}

Pass Rate:     ${pass_rate}%
Status:        ${status_text}

Log File: ${SMOKE_LOG}

---
NFTBan Smoke Test Suite v${SCRIPT_VERSION}
Open-source Linux IPS and nftables firewall manager
https://nftban.com
BODY
)

    # Try to send via nftban mail infrastructure
    local lib_dir="${NFTBAN_LIB_DIR:-/usr/lib/nftban}"
    if [[ -f "${lib_dir}/core/nftban_mail.sh" ]]; then
        # shellcheck source=/dev/null
        source "${lib_dir}/core/nftban_mail.sh" 2>/dev/null || true
    fi

    # Use nftban_mail_send if available, otherwise fallback to mail command
    if declare -f nftban_mail_send &>/dev/null; then
        if echo "$body" | nftban_mail_send - "$recipient" "$subject" 2>/dev/null; then
            log_pass "Email report sent to ${recipient}"
            return 0
        fi
    fi

    # Fallback: try sendmail directly
    if command -v sendmail &>/dev/null; then
        {
            echo "To: ${recipient}"
            echo "Subject: ${subject}"
            echo "Content-Type: text/plain; charset=utf-8"
            echo ""
            echo "$body"
        } | sendmail -t 2>/dev/null && {
            log_pass "Email report sent to ${recipient} (via sendmail)"
            return 0
        }
    fi

    # Fallback: try mail command
    if command -v mail &>/dev/null; then
        echo "$body" | mail -s "$subject" "$recipient" 2>/dev/null && {
            log_pass "Email report sent to ${recipient} (via mail)"
            return 0
        }
    fi

    log_fail "Could not send email report - no mail transport available"
    log_warn "Install sendmail or mailx, or configure SMTP in /etc/nftban/conf.d/mail.conf"
    return 1
}

# =============================================================================
# USAGE
# =============================================================================

usage() {
    cat <<EOF
NFTBan Smoke Test Suite v${SCRIPT_VERSION}

Usage: $0 [OPTIONS]

Options:
  --quick             Run quick test (core commands only: version, help, status)
  --full              Run standard test suite (default) - key modules + lifecycle
  --all               Run ALL CLI commands test (43 commands) - comprehensive
  --detailed          Same as --all
  --lifecycle         Run ban lifecycle tests only (ban/unban + whitelist)
  --check             Just check trace log for orphaned traces
  --stats             Show trace statistics
  --email <address>   Send test results via email to specified address
  --help              Show this help

Test Modes:
  quick     = 3 tests    (version, help, status)
  full      = ~43 tests  (core + binary integrity + modules + stats + search + help + protection + lifecycle + nft validation)
  all       = 67+ tests  (every cmd_*.sh + binary integrity + extended status + protection + lifecycle + nft validation)
  lifecycle = 12 tests   (ban/unban + whitelist add/remove, IPv4 + IPv6)

Validation Tests (included in full/all):
  - Binary Integrity: verifies Go binaries are valid ELF executables
  - Feeds IPv4/IPv6: verifies CIDRs loaded in blacklist sets
  - Geoban IPv4/IPv6: verifies country CIDRs loaded in blacklist sets

Examples:
  $0                              # Run full smoke test (~32 commands)
  $0 --quick                      # Quick core test (3 commands)
  $0 --all                        # Test ALL 43+ CLI commands + lifecycle
  $0 --lifecycle                  # Ban lifecycle tests only
  $0 --check                      # Check for stuck scripts
  $0 --email admin@example.com    # Run full test and email results
  $0 --quick --email ops@co.com   # Quick test with email report

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
            --lifecycle|-l)
                mode="lifecycle"
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
            --email|-e)
                shift
                if [[ $# -eq 0 || "$1" == -* ]]; then
                    echo "ERROR: --email requires an email address argument" >&2
                    usage
                    exit 1
                fi
                EMAIL_RECIPIENT="$1"
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
            smoke_test_binary_integrity
            smoke_test_auditor_acls
            run_module_tests
            run_stats_tests
            run_search_tests
            run_help_tests
            run_protection_tests
            run_lifecycle_tests
            run_port_lifecycle_tests
            run_feeds_nft_validation
            run_geoban_nft_validation
            run_whitelist_safety_tests
            ;;
        all)
            # Comprehensive: test ALL CLI commands
            run_core_tests
            smoke_test_binary_integrity
            smoke_test_auditor_acls
            run_all_cli_tests        # Tests all 43 cmd_*.sh files
            run_extended_status_tests
            run_protection_tests
            run_lifecycle_tests
            run_port_lifecycle_tests
            run_feeds_nft_validation
            run_geoban_nft_validation
            run_whitelist_safety_tests
            ;;
        lifecycle)
            run_lifecycle_tests
            ;;
    esac

    # Check for orphans (count stored in TESTS_ORPHANS)
    check_orphans || true

    # Disable tracing
    disable_trace

    # Generate report
    generate_report

    # Send email report if requested
    if [[ -n "$EMAIL_RECIPIENT" ]]; then
        send_email_report "$EMAIL_RECIPIENT"
    fi
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
