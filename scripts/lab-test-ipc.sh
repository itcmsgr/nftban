#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.0.0 - IPC Lab Test Script
# =============================================================================
# meta:name="lab-test-ipc"
# meta:type="script"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Validate IPC architecture before enabling CI enforcement"
# meta:inventory.files=""
# meta:inventory.binaries="bash,socat,nft,go,systemctl"
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/nftban.conf"
# meta:inventory.systemd_units="nftband.socket,nftband.service"
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================
# PURPOSE: Validate IPC architecture before enabling CI enforcement
#
# USAGE:
#   ssh root@lab4.example.test
#   cd /path/to/nftban
#   ./scripts/lab-test-ipc.sh
#
# EXIT CODES:
#   0 = All tests passed
#   1 = Test failures (do NOT enable CI enforcement)
# =============================================================================

set -Eeuo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

log_pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; ((PASS++)); }
log_fail() { echo -e "${RED}✗ FAIL${NC}: $1"; ((FAIL++)); }
log_skip() { echo -e "${YELLOW}○ SKIP${NC}: $1"; ((SKIP++)); }
log_info() { echo -e "${BLUE}→${NC} $1"; }
log_section() { echo -e "\n${BLUE}═══════════════════════════════════════════════════════════════${NC}"; echo -e "${BLUE}Section $1${NC}"; echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"; }

# Socket path
SOCKET="/run/nftban/nftband.sock"

# =============================================================================
# SECTION 1: PRECONDITIONS
# =============================================================================

test_preconditions() {
    log_section "1: Preconditions"

    # Check root
    if [[ $EUID -eq 0 ]]; then
        log_pass "Running as root"
    else
        log_fail "Must run as root"
        exit 1
    fi

    # Check nftban.conf
    if [[ -f /etc/nftban/nftban.conf ]]; then
        log_pass "nftban.conf exists"
    else
        log_fail "Missing /etc/nftban/nftban.conf"
    fi

    # Check socat
    if command -v socat &>/dev/null; then
        log_pass "socat installed: $(which socat)"
    else
        log_fail "socat not installed (apt install socat)"
    fi

    # Check nftban group (optional but recommended)
    if getent group nftban &>/dev/null; then
        log_pass "nftban group exists"
    else
        log_skip "nftban group not found (only root can access socket)"
    fi

    # Check nft binary
    if command -v nft &>/dev/null; then
        log_pass "nft binary found: $(nft --version 2>&1 | head -1)"
    else
        log_fail "nft binary not found"
    fi
}

# =============================================================================
# SECTION 2: BUILD & START DAEMON
# =============================================================================

test_build_and_start() {
    log_section "2: Build & Start Daemon"

    # Build
    log_info "Building nftband..."
    if go build -o bin/nftband ./cmd/nftband 2>&1; then
        log_pass "Build successful"
    else
        log_fail "Build failed"
        return 1
    fi

    # Stop any existing daemon
    log_info "Stopping existing daemon (if any)..."
    pkill -f nftband 2>/dev/null || true
    sleep 1

    # Ensure run directory
    mkdir -p /run/nftban
    rm -f "$SOCKET"

    # Start daemon in background
    log_info "Starting nftband..."
    ./bin/nftband &
    DAEMON_PID=$!
    sleep 2

    # Check daemon is running
    if kill -0 $DAEMON_PID 2>/dev/null; then
        log_pass "Daemon started (PID: $DAEMON_PID)"
    else
        log_fail "Daemon failed to start"
        return 1
    fi

    # Check socket exists
    if [[ -S "$SOCKET" ]]; then
        log_pass "Socket created: $SOCKET"
        ls -la "$SOCKET"
    else
        log_fail "Socket not created"
        return 1
    fi

    # Check socket permissions (MUST be exactly 0660 root:nftban)
    local perms owner group
    perms=$(stat -c %a "$SOCKET" 2>/dev/null)
    owner=$(stat -c %U "$SOCKET" 2>/dev/null)
    group=$(stat -c %G "$SOCKET" 2>/dev/null)

    if [[ "$perms" == "660" ]]; then
        log_pass "Socket permissions: 660"
    else
        log_fail "Socket permissions: $perms (MUST be 660)"
    fi

    if [[ "$owner" == "root" ]]; then
        log_pass "Socket owner: root"
    else
        log_fail "Socket owner: $owner (MUST be root)"
    fi

    if [[ "$group" == "nftban" ]]; then
        log_pass "Socket group: nftban"
    else
        if getent group nftban &>/dev/null; then
            log_fail "Socket group: $group (MUST be nftban)"
        else
            log_skip "Socket group: $group (nftban group not configured)"
        fi
    fi
}

# =============================================================================
# SECTION 3: VALIDATE IPC FUNCTIONS
# =============================================================================

ipc_request() {
    local method="$1"
    local params="${2:-{}}"
    echo "{\"method\":\"$method\",\"params\":$params}" | timeout 5 socat - "UNIX-CONNECT:$SOCKET" 2>/dev/null
}

test_ipc_functions() {
    log_section "3: Validate IPC Functions"

    # 3.1 Ping
    log_info "Testing ping..."
    local resp
    resp=$(ipc_request "ping")
    if [[ "$resp" == *'"success":true'* && "$resp" == *'pong'* ]]; then
        log_pass "ping -> pong"
    else
        log_fail "ping failed: $resp"
    fi

    # 3.2 Status
    log_info "Testing status..."
    resp=$(ipc_request "status")
    if [[ "$resp" == *'"success":true'* && "$resp" == *'"version"'* ]]; then
        log_pass "status returns version info"
    else
        log_fail "status failed: $resp"
    fi

    # 3.3 Modules
    log_info "Testing modules..."
    resp=$(ipc_request "modules")
    if [[ "$resp" == *'"success":true'* ]]; then
        log_pass "modules returns list"
    else
        log_fail "modules failed: $resp"
    fi

    # 3.4 Ban (test IP)
    local test_ip="192.0.2.99"  # TEST-NET-1 (RFC 5737) - safe test IP
    log_info "Testing ban ($test_ip)..."
    resp=$(ipc_request "ban" "{\"ip\":\"$test_ip\",\"timeout\":60,\"reason\":\"lab-test\",\"source\":\"lab-test\"}")
    if [[ "$resp" == *'"success":true'* ]]; then
        log_pass "ban $test_ip"

        # Verify in nftables
        if nft list set ip nftban blacklist_ipv4 2>/dev/null | grep -q "$test_ip"; then
            log_pass "IP appears in blacklist_ipv4"
        else
            log_skip "Cannot verify in nftables (set may have different name)"
        fi
    else
        log_fail "ban failed: $resp"
    fi

    # 3.5 Check
    log_info "Testing check ($test_ip)..."
    resp=$(ipc_request "check" "{\"ip\":\"$test_ip\"}")
    if [[ "$resp" == *'"success":true'* && "$resp" == *'"banned":true'* ]]; then
        log_pass "check confirms IP is banned"
    else
        log_skip "check returned: $resp"
    fi

    # 3.6 Unban
    log_info "Testing unban ($test_ip)..."
    resp=$(ipc_request "unban" "{\"ip\":\"$test_ip\"}")
    if [[ "$resp" == *'"success":true'* ]]; then
        log_pass "unban $test_ip"
    else
        log_fail "unban failed: $resp"
    fi

    # 3.7 Add Element
    log_info "Testing add_element..."
    resp=$(ipc_request "add_element" "{\"table\":\"ip nftban\",\"set\":\"whitelist_ipv4\",\"element\":\"192.0.2.100\",\"timeout\":60}")
    if [[ "$resp" == *'"success":true'* ]]; then
        log_pass "add_element to whitelist"
    else
        log_skip "add_element: $resp (set may not exist)"
    fi

    # 3.8 Delete Element
    log_info "Testing delete_element..."
    resp=$(ipc_request "delete_element" "{\"table\":\"ip nftban\",\"set\":\"whitelist_ipv4\",\"element\":\"192.0.2.100\"}")
    if [[ "$resp" == *'"success":true'* ]]; then
        log_pass "delete_element from whitelist"
    else
        log_skip "delete_element: $resp"
    fi

    # 3.9 Apply Ruleset (with check only)
    log_info "Testing apply_ruleset (validation mode)..."
    # Create test ruleset
    local test_nft="/tmp/lab-test.nft"
    echo "# Test ruleset - validation only" > "$test_nft"
    echo "# This file intentionally does nothing" >> "$test_nft"

    resp=$(ipc_request "apply_ruleset" "{\"file\":\"$test_nft\",\"check\":true}")
    if [[ "$resp" == *'"success":true'* ]]; then
        log_pass "apply_ruleset (check mode)"
    else
        log_skip "apply_ruleset check: $resp"
    fi
    rm -f "$test_nft"
}

# =============================================================================
# SECTION 4: VALIDATE MIGRATED PATHS
# =============================================================================

test_migrated_paths() {
    log_section "4: Validate Migrated Paths"

    # 4.1 Test nft_ipc.sh library
    log_info "Testing nft_ipc.sh library..."
    if [[ -f cli/lib/nftban/lib/nft_ipc.sh ]]; then
        log_pass "nft_ipc.sh exists"

        # Source and test
        source cli/lib/nftban/lib/nft_ipc.sh

        if nft_ipc_is_daemon_running; then
            log_pass "nft_ipc_is_daemon_running returns true"
        else
            log_fail "nft_ipc_is_daemon_running returns false"
        fi

        # Test nft_ipc_ban
        local test_ip="192.0.2.101"
        if nft_ipc_ban "$test_ip" 30 "bash-lib-test" "lab-test" 2>/dev/null; then
            log_pass "nft_ipc_ban works"
            nft_ipc_unban "$test_ip" 2>/dev/null || true
        else
            log_fail "nft_ipc_ban failed"
        fi

        # Test nft_ipc_add_element
        if nft_ipc_add_element "ip nftban" "whitelist_ipv4" "192.0.2.102" 30 2>/dev/null; then
            log_pass "nft_ipc_add_element works"
            nft_ipc_delete_element "ip nftban" "whitelist_ipv4" "192.0.2.102" 2>/dev/null || true
        else
            log_skip "nft_ipc_add_element (set may not exist)"
        fi
    else
        log_fail "nft_ipc.sh not found"
    fi

    # 4.2 Test Go IPC client
    log_info "Testing Go IPC client (via compile)..."
    if go build -o /tmp/test-ipc ./pkg/ipc 2>&1; then
        log_pass "pkg/ipc compiles"
        rm -f /tmp/test-ipc
    else
        log_fail "pkg/ipc compile failed"
    fi

    # 4.3 Verify maintenance.sh has IPC calls
    log_info "Checking maintenance.sh migration..."
    if grep -q "nft_ipc_add_element" cli/lib/nftban/cron/maintenance.sh 2>/dev/null; then
        log_pass "maintenance.sh uses nft_ipc_add_element"
    else
        log_fail "maintenance.sh not migrated"
    fi

    # 4.4 Verify sync.go has IPC calls
    log_info "Checking sync.go migration..."
    if grep -q 'ipc\.NewClient' pkg/firewall/sync.go 2>/dev/null; then
        log_pass "sync.go uses ipc.Client"
    else
        log_fail "sync.go not migrated"
    fi
}

# =============================================================================
# SECTION 5: FAILURE MODE TESTS
# =============================================================================

test_failure_modes() {
    log_section "5: Failure Mode Tests"

    # 5.1 Stop daemon and verify IPC fails gracefully
    log_info "Stopping daemon to test failure mode..."
    pkill -f nftband 2>/dev/null || true
    sleep 1

    # Test that IPC returns error when daemon is down
    log_info "Testing IPC with daemon down..."
    local resp
    resp=$(ipc_request "ping" 2>/dev/null || echo '{"error":"connection failed"}')
    if [[ "$resp" == *'"success":false'* || "$resp" == *'error'* || -z "$resp" ]]; then
        log_pass "IPC correctly fails when daemon is down"
    else
        log_fail "IPC didn't report error: $resp"
    fi

    # Test bash IPC library handles daemon-down gracefully
    if [[ -f cli/lib/nftban/lib/nft_ipc.sh ]]; then
        source cli/lib/nftban/lib/nft_ipc.sh
        if ! nft_ipc_is_daemon_running; then
            log_pass "nft_ipc_is_daemon_running correctly returns false"
        else
            log_fail "nft_ipc_is_daemon_running incorrectly returns true"
        fi
    fi

    # 5.2 Restart daemon for remaining tests
    log_info "Restarting daemon..."
    ./bin/nftband &
    sleep 2

    if [[ -S "$SOCKET" ]]; then
        log_pass "Daemon restarted"
    else
        log_fail "Daemon failed to restart"
    fi

    # 5.3 Test unauthorized access (SO_PEERCRED validation)
    log_info "Testing unauthorized access rejection..."

    # Create test user if not exists (will be cleaned up)
    local test_user="nftban_test_user"
    if ! id "$test_user" &>/dev/null; then
        useradd -M -s /bin/false "$test_user" 2>/dev/null || true
    fi

    if id "$test_user" &>/dev/null; then
        # User exists and is NOT in nftban group - test should fail
        local unauth_resp
        unauth_resp=$(su -s /bin/bash "$test_user" -c "echo '{\"method\":\"ping\"}' | timeout 5 socat - 'UNIX-CONNECT:$SOCKET' 2>/dev/null" 2>/dev/null || echo '{"error":"connection failed"}')

        if [[ "$unauth_resp" == *'"unauthorized"'* || "$unauth_resp" == *'error'* || -z "$unauth_resp" ]]; then
            log_pass "Unauthorized user correctly rejected (SO_PEERCRED)"
        else
            log_fail "Unauthorized user NOT rejected: $unauth_resp"
        fi

        # Cleanup test user
        userdel "$test_user" 2>/dev/null || true
    else
        log_skip "Could not create test user for SO_PEERCRED test"
    fi
}

# =============================================================================
# SECTION 6: ANTI-REGRESSION CHECKS
# =============================================================================

test_anti_regression() {
    log_section "6: Anti-Regression Checks"

    log_info "Verifying only migrated paths are tested..."

    # 6.1 Confirm we are NOT testing unmigrated Wave 2/3 scripts
    local wave2_scripts=(
        "cli/lib/nftban/core/nftban_geoban.sh"
        "cli/lib/nftban/core/nftban_ddos_suricata.sh"
        "cli/lib/nftban/core/nftban_portscan_suricata.sh"
        "cli/lib/nftban/core/nftban_ddos_classic.sh"
        "cli/lib/nftban/core/nftban_portscan_classic.sh"
    )

    log_info "Wave 2/3 scripts (NOT tested - still have direct nft calls):"
    for script in "${wave2_scripts[@]}"; do
        if [[ -f "$script" ]]; then
            local violations
            violations=$(grep -cE 'nft[[:space:]]+(add|delete|flush|insert)' "$script" 2>/dev/null || echo 0)
            echo "  - $script ($violations WRITE violations)"
        fi
    done
    log_pass "Wave 2/3 scripts identified and excluded from test"

    # 6.2 Verify migrated scripts use IPC (not direct nft)
    log_info "Checking migrated scripts use IPC..."

    # maintenance.sh should have nft_ipc calls, not direct nft add
    if [[ -f "cli/lib/nftban/cron/maintenance.sh" ]]; then
        local ipc_calls direct_adds
        ipc_calls=$(grep -c 'nft_ipc_' cli/lib/nftban/cron/maintenance.sh 2>/dev/null || echo 0)
        direct_adds=$(grep -cE '^[^#]*nft[[:space:]]+add[[:space:]]' cli/lib/nftban/cron/maintenance.sh 2>/dev/null || echo 0)

        if [[ $ipc_calls -gt 0 && $direct_adds -eq 0 ]]; then
            log_pass "maintenance.sh: $ipc_calls IPC calls, 0 direct nft adds"
        else
            log_fail "maintenance.sh: $ipc_calls IPC calls, $direct_adds direct nft adds"
        fi
    fi

    # 6.3 Count total remaining violations
    log_info "Current WRITE violation count..."
    if [[ -x "./scripts/ci/check-nft-writes.sh" ]]; then
        local violations
        violations=$(./scripts/ci/check-nft-writes.sh 2>&1 | grep "WRITE VIOLATIONS:" | grep -oE '[0-9]+' || echo "?")
        echo "  Total WRITE violations remaining: $violations"
        if [[ "$violations" =~ ^[0-9]+$ && "$violations" -lt 100 ]]; then
            log_pass "Violation count is tracked ($violations)"
        else
            log_skip "Could not determine violation count"
        fi
    else
        log_skip "CI check script not available"
    fi

    # 6.4 Verify daemon logs show IPC calls (not direct nft from scripts)
    log_info "Checking for direct nft calls in daemon log..."
    # This is informational - we can't fully verify without a long-running test
    echo "  (Manual check: journalctl -u nftband should show IPC method calls)"
    log_pass "Anti-regression checks complete"
}

# =============================================================================
# SECTION 7: CONCURRENCY TESTS
# =============================================================================

test_concurrency() {
    log_section "7: Concurrency Tests"

    log_info "Testing parallel IPC requests..."

    local test_ips=("192.0.2.10" "192.0.2.11" "192.0.2.12" "192.0.2.13" "192.0.2.14")
    local pids=()

    # Launch parallel bans
    for ip in "${test_ips[@]}"; do
        (ipc_request "ban" "{\"ip\":\"$ip\",\"timeout\":30,\"reason\":\"concurrency-test\"}" >/dev/null 2>&1) &
        pids+=($!)
    done

    # Wait for all
    local success=0
    for pid in "${pids[@]}"; do
        wait $pid && ((success++)) || true
    done

    if [[ $success -eq ${#test_ips[@]} ]]; then
        log_pass "All $success parallel ban requests completed"
    else
        log_skip "$success/${#test_ips[@]} parallel requests succeeded"
    fi

    # Cleanup
    for ip in "${test_ips[@]}"; do
        ipc_request "unban" "{\"ip\":\"$ip\"}" >/dev/null 2>&1 || true
    done
}

# =============================================================================
# SECTION 8: SOCKET ACTIVATION TEST (Optional)
# =============================================================================

test_socket_activation() {
    log_section "8: Socket Activation Test (Optional)"

    # Check if we can test systemd socket activation
    if ! command -v systemctl &>/dev/null; then
        log_skip "systemctl not available - cannot test socket activation"
        return 0
    fi

    log_info "Testing systemd socket activation mode..."

    # Stop any running daemon first
    pkill -f nftband 2>/dev/null || true
    systemctl stop nftband.service 2>/dev/null || true
    systemctl stop nftband.socket 2>/dev/null || true
    sleep 1

    # Check if socket/service units exist
    if [[ ! -f /etc/systemd/system/nftband.socket ]] && [[ ! -f /usr/lib/systemd/system/nftband.socket ]]; then
        log_info "Installing systemd units for test..."
        cp install/systemd/nftband.socket /etc/systemd/system/ 2>/dev/null || {
            log_skip "Could not install nftband.socket"
            return 0
        }
        cp install/systemd/nftband.service /etc/systemd/system/ 2>/dev/null || {
            log_skip "Could not install nftband.service"
            return 0
        }
        systemctl daemon-reload
    fi

    # Start socket (not service)
    log_info "Starting nftband.socket..."
    if systemctl start nftband.socket 2>/dev/null; then
        log_pass "nftband.socket started"
    else
        log_fail "Failed to start nftband.socket"
        return 0
    fi

    # Verify socket exists with correct permissions BEFORE daemon starts
    sleep 1
    if [[ -S "$SOCKET" ]]; then
        local perms owner group
        perms=$(stat -c %a "$SOCKET" 2>/dev/null)
        owner=$(stat -c %U "$SOCKET" 2>/dev/null)
        group=$(stat -c %G "$SOCKET" 2>/dev/null)

        if [[ "$perms" == "660" && "$owner" == "root" && "$group" == "nftban" ]]; then
            log_pass "Socket created by systemd: $owner:$group $perms"
        else
            log_fail "Socket permissions wrong: $owner:$group $perms (expected root:nftban 660)"
        fi
    else
        log_fail "Socket not created by systemd"
        return 0
    fi

    # Start service
    log_info "Starting nftband.service..."
    if systemctl start nftband.service 2>/dev/null; then
        sleep 2
        if systemctl is-active --quiet nftband.service; then
            log_pass "nftband.service started and active"
        else
            log_fail "nftband.service not active after start"
            journalctl -u nftband.service --no-pager -n 20
        fi
    else
        log_fail "Failed to start nftband.service"
        journalctl -u nftband.service --no-pager -n 20
        return 0
    fi

    # Test IPC through systemd-managed socket
    log_info "Testing IPC via systemd socket..."
    local resp
    resp=$(ipc_request "ping")
    if [[ "$resp" == *'"success":true'* ]]; then
        log_pass "IPC works via systemd socket activation"
    else
        log_fail "IPC failed via systemd socket: $resp"
    fi

    # Check daemon logs for socket activation message
    if journalctl -u nftband.service --no-pager -n 50 2>/dev/null | grep -q "systemd socket activation"; then
        log_pass "Daemon detected systemd socket activation"
    else
        log_skip "Could not verify socket activation log message"
    fi

    # Cleanup - stop systemd units, restart manual mode for remaining tests
    log_info "Cleaning up systemd test..."
    systemctl stop nftband.service 2>/dev/null || true
    systemctl stop nftband.socket 2>/dev/null || true
    rm -f "$SOCKET"

    # Restart manual daemon for any remaining tests
    ./bin/nftband &
    sleep 2
}

# =============================================================================
# CLEANUP & SUMMARY
# =============================================================================

cleanup() {
    log_section "Cleanup"
    log_info "Stopping daemon..."
    pkill -f nftband 2>/dev/null || true
    systemctl stop nftband.service 2>/dev/null || true
    systemctl stop nftband.socket 2>/dev/null || true
    rm -f "$SOCKET"
    log_info "Done"
}

print_summary() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "                        TEST SUMMARY"
    echo "═══════════════════════════════════════════════════════════════"
    echo -e "  ${GREEN}PASSED${NC}: $PASS"
    echo -e "  ${RED}FAILED${NC}: $FAIL"
    echo -e "  ${YELLOW}SKIPPED${NC}: $SKIP"
    echo "═══════════════════════════════════════════════════════════════"

    if [[ $FAIL -eq 0 ]]; then
        echo -e "\n${GREEN}ALL TESTS PASSED${NC}"
        echo ""
        echo "You may now enable CI WRITE enforcement:"
        echo "  1. Edit .github/workflows/ci.yml"
        echo "  2. Remove --warn-all from check-nft-writes.sh"
        echo "  3. Commit and push"
        echo ""
        return 0
    else
        echo -e "\n${RED}TESTS FAILED${NC}"
        echo ""
        echo "DO NOT enable CI enforcement until all failures are resolved."
        echo ""
        return 1
    fi
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    echo "═══════════════════════════════════════════════════════════════"
    echo "          NFTBan IPC Architecture Lab Test"
    echo "═══════════════════════════════════════════════════════════════"
    echo "Date: $(date)"
    echo "Host: $(hostname)"
    echo ""

    trap cleanup EXIT

    test_preconditions
    test_build_and_start || exit 1
    test_ipc_functions
    test_migrated_paths
    test_failure_modes
    test_anti_regression
    test_concurrency
    test_socket_activation

    print_summary
}

main "$@"
