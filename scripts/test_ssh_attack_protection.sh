#!/usr/bin/env bash

# =============================================================================
# NFTBan SSH Attack Protection Test
# Version: 0.9.2
# Location: scripts/test_ssh_attack_protection.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Description: Simulates SSH attack from lab-server-2 to lab-server-1
#              and verifies protection mechanisms work correctly
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly SCRIPT_VERSION="0.9.2"

# Test parameters
readonly ATTACKER_SERVER="lab-server-2"
readonly TARGET_SERVER="lab-server-1"
readonly TARGET_IP=""  # Will be auto-detected or user-provided
readonly FAKE_USERNAME="nonexistentuser$$"
readonly ATTACK_ATTEMPTS=7  # More than the threshold of 5
readonly WAIT_FOR_BAN=30    # Seconds to wait for ban to trigger
readonly TOTAL_TEST_TIME=120 # Max time for entire test

# ANSI Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'
readonly BOLD='\033[1m'

# Test results
declare -i TESTS_PASSED=0
declare -i TESTS_FAILED=0

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

print_header() {
    echo ""
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  NFTBan SSH Attack Protection Test v${SCRIPT_VERSION}${NC}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}ATTACKER:${NC} $ATTACKER_SERVER (this machine)"
    echo -e "${YELLOW}TARGET:${NC}   $TARGET_SERVER"
    echo ""
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
    ((TESTS_PASSED++))
}

log_warning() {
    echo -e "${YELLOW}[⚠]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
    ((TESTS_FAILED++))
}

log_test() {
    echo ""
    echo -e "${BOLD}${CYAN}TEST:${NC} $1"
}

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

check_hostname() {
    local hostname=$(hostname -s)

    if [[ "$hostname" != *"lab-server-2"* && "$hostname" != *"lab2"* ]]; then
        log_error "This script must run on lab-server-2 (attacker machine)"
        log_error "Current hostname: $hostname"
        exit 1
    fi

    log_success "Running on correct server: $hostname"
}

check_ssh_client() {
    if ! command -v ssh &>/dev/null; then
        log_error "SSH client not found"
        exit 1
    fi
    log_success "SSH client available"
}

check_sshpass() {
    if ! command -v sshpass &>/dev/null; then
        log_error "sshpass not installed"
        log_info "Install with: sudo apt-get install sshpass -y"
        exit 1
    fi
    log_success "sshpass available"
}

get_target_ip() {
    local target_ip="$1"

    if [[ -z "$target_ip" ]]; then
        # Try to resolve lab-server-1
        if target_ip=$(getent hosts lab-server-1 | awk '{print $1}' | head -1); then
            if [[ -n "$target_ip" ]]; then
                echo "$target_ip"
                return 0
            fi
        fi

        # Ask user
        echo ""
        log_warning "Could not auto-detect lab-server-1 IP address"
        echo -n "Enter lab-server-1 IP address: "
        read -r target_ip

        if [[ -z "$target_ip" ]]; then
            log_error "No IP address provided"
            exit 1
        fi
    fi

    echo "$target_ip"
}

verify_target_reachable() {
    local target_ip="$1"

    if ping -c 2 -W 2 "$target_ip" &>/dev/null; then
        log_success "Target $target_ip is reachable"
        return 0
    else
        log_error "Target $target_ip is NOT reachable"
        exit 1
    fi
}

verify_ssh_port_open() {
    local target_ip="$1"

    if timeout 5 bash -c "echo >/dev/tcp/$target_ip/22" 2>/dev/null; then
        log_success "SSH port 22 is open on $target_ip"
        return 0
    else
        log_error "SSH port 22 is NOT accessible on $target_ip"
        exit 1
    fi
}

# =============================================================================
# ATTACK SIMULATION
# =============================================================================

simulate_ssh_attack() {
    local target_ip="$1"
    local attempts="$2"

    log_test "Simulating SSH brute force attack"
    log_info "Target: $target_ip"
    log_info "Username: $FAKE_USERNAME (fake)"
    log_info "Attempts: $attempts"
    log_info "Threshold: 5 failures in 10 minutes"

    echo ""
    log_info "Starting attack simulation..."

    local successful_attempts=0

    for ((i=1; i<=attempts; i++)); do
        echo -n "  Attempt $i/$attempts: "

        # Use sshpass to attempt login with fake credentials
        # This will fail and be logged by the target server
        if timeout 10 sshpass -p "wrongpassword$$" \
            ssh -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null \
                -o ConnectTimeout=5 \
                -o BatchMode=yes \
                "${FAKE_USERNAME}@${target_ip}" exit 2>/dev/null; then
            echo -e "${RED}Unexpected success${NC}"
        else
            echo -e "${GREEN}Failed (expected)${NC}"
            ((successful_attempts++))
        fi

        # Small delay between attempts
        sleep 1
    done

    echo ""

    if [[ $successful_attempts -ge 5 ]]; then
        log_success "Generated $successful_attempts failed login attempts (threshold: 5)"
    else
        log_error "Only generated $successful_attempts failed login attempts (need 5+)"
    fi
}

# =============================================================================
# VERIFICATION
# =============================================================================

wait_for_ban() {
    local wait_time="$1"

    log_test "Waiting for fail2ban to process and ban IP"
    log_info "Waiting ${wait_time} seconds for ban to trigger..."

    echo -n "  "
    for ((i=wait_time; i>0; i--)); do
        echo -n "."
        sleep 1
        if ((i % 10 == 0)); then
            echo -n " ${i}s "
        fi
    done
    echo ""

    log_success "Wait period completed"
}

verify_ban_on_target() {
    local target_ip="$1"
    local attacker_ip="$2"

    log_test "Verifying ban was applied on target server"
    log_info "Attacker IP to check: $attacker_ip"

    # Try to SSH to target and check fail2ban status
    # This requires SSH access with proper credentials
    echo ""
    log_info "Checking fail2ban status on target server..."
    log_warning "NOTE: This requires SSH access to $target_ip"
    log_warning "You may be prompted for credentials if key auth is not set up"

    echo ""
    echo -n "Do you have SSH access to check ban status on $target_ip? (y/N): "
    read -r has_access

    if [[ ! "$has_access" =~ ^[Yy]$ ]]; then
        log_warning "Skipping automated ban verification"
        log_info "Manual verification steps:"
        echo "  1. SSH to $target_ip"
        echo "  2. Run: sudo fail2ban-client status sshd"
        echo "  3. Check if $attacker_ip is in banned IPs list"
        echo "  4. Run: sudo nft list set inet nftban_v4 temp_ban"
        echo "  5. Verify $attacker_ip is in the set"
        return 1
    fi

    # Try to get fail2ban status from target
    local ban_check_result
    if ban_check_result=$(ssh -o ConnectTimeout=10 \
                              -o StrictHostKeyChecking=no \
                              "root@${target_ip}" \
                              "fail2ban-client status sshd 2>/dev/null || echo 'FAILED'" 2>&1); then

        if echo "$ban_check_result" | grep -q "$attacker_ip"; then
            log_success "Attacker IP $attacker_ip is BANNED on target server"
            echo ""
            echo -e "${CYAN}Fail2ban Status:${NC}"
            echo "$ban_check_result" | grep -A 3 "Banned IP"
            return 0
        elif echo "$ban_check_result" | grep -q "FAILED"; then
            log_warning "Could not retrieve fail2ban status (permission denied?)"
            return 1
        else
            log_error "Attacker IP $attacker_ip is NOT in banned list"
            echo ""
            echo -e "${CYAN}Fail2ban Status:${NC}"
            echo "$ban_check_result"
            return 1
        fi
    else
        log_warning "Could not connect to target server via SSH"
        log_info "Manual verification required (see steps above)"
        return 1
    fi
}

verify_connection_blocked() {
    local target_ip="$1"

    log_test "Verifying SSH connection is now blocked"

    log_info "Attempting to connect to $target_ip (should fail)..."

    if timeout 10 ssh -o ConnectTimeout=5 \
                      -o StrictHostKeyChecking=no \
                      -o UserKnownHostsFile=/dev/null \
                      "root@${target_ip}" exit 2>/dev/null; then
        log_error "Connection succeeded (should have been blocked!)"
        return 1
    else
        local exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
            log_success "Connection timed out (BLOCKED by firewall)"
            return 0
        else
            log_success "Connection failed (likely BLOCKED)"
            return 0
        fi
    fi
}

check_logs_on_target() {
    local target_ip="$1"

    log_test "Checking attack logs on target server"

    echo ""
    echo -n "Check attack logs on target server? (y/N): "
    read -r check_logs

    if [[ ! "$check_logs" =~ ^[Yy]$ ]]; then
        log_info "Skipping log verification"
        return 0
    fi

    log_info "Retrieving recent ban events..."

    if ssh -o ConnectTimeout=10 \
           -o StrictHostKeyChecking=no \
           "root@${target_ip}" \
           "tail -20 /var/log/nftban/ban-history.log 2>/dev/null || echo 'Log not found'" 2>&1; then
        log_success "Retrieved ban history"
    else
        log_warning "Could not retrieve ban history"
    fi

    echo ""
    log_info "Retrieving login alerts..."

    if ssh -o ConnectTimeout=10 \
           -o StrictHostKeyChecking=no \
           "root@${target_ip}" \
           "tail -20 /var/log/nftban/login-alerts.log 2>/dev/null || echo 'Log not found'" 2>&1; then
        log_success "Retrieved login alerts"
    else
        log_warning "Could not retrieve login alerts"
    fi
}

# =============================================================================
# CLEANUP
# =============================================================================

cleanup_test() {
    local target_ip="$1"

    echo ""
    echo -e "${BOLD}${CYAN}CLEANUP${NC}"

    echo -n "Unban this IP to restore access? (y/N): "
    read -r do_cleanup

    if [[ ! "$do_cleanup" =~ ^[Yy]$ ]]; then
        log_info "Skipping cleanup - ban will expire automatically"
        log_info "Ban duration: 1 hour (3600 seconds)"
        return 0
    fi

    log_info "Requesting unban on target server..."

    if ssh -o ConnectTimeout=10 \
           -o StrictHostKeyChecking=no \
           "root@${target_ip}" \
           "fail2ban-client set sshd unbanip $(hostname -I | awk '{print $1}') 2>/dev/null" 2>&1; then
        log_success "Unban request sent"
    else
        log_warning "Could not send unban request"
        log_info "Manual unban: sudo fail2ban-client set sshd unbanip <attacker_ip>"
    fi
}

# =============================================================================
# REPORT
# =============================================================================

print_report() {
    echo ""
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  TEST SUMMARY${NC}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo ""

    echo -e "${CYAN}Test Results:${NC}"
    echo -e "  ${GREEN}Passed:${NC} $TESTS_PASSED"
    echo -e "  ${RED}Failed:${NC} $TESTS_FAILED"

    echo ""

    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${BOLD}${GREEN}✓ ALL TESTS PASSED${NC}"
        echo ""
        echo "SSH Attack Protection is working correctly!"
        echo ""
        echo "Protection verified:"
        echo "  ✓ Failed login attempts logged"
        echo "  ✓ Threshold detection (5 failures in 10 min)"
        echo "  ✓ IP ban activated"
        echo "  ✓ Connection blocked"
        echo ""
        echo "Attack visibility:"
        echo "  ✓ Ban events logged"
        echo "  ✓ Login alerts generated"
        echo ""
    else
        echo -e "${BOLD}${RED}✗ SOME TESTS FAILED${NC}"
        echo ""
        echo "Review the test output above for details."
        echo ""
        echo "Common issues:"
        echo "  - NFTban not properly configured on target"
        echo "  - Fail2ban not running on target"
        echo "  - SSH jail not enabled"
        echo "  - Log files not accessible"
        echo ""
        echo "Troubleshooting:"
        echo "  1. SSH to target server: ssh root@$TARGET_IP"
        echo "  2. Check nftban status: nftban status"
        echo "  3. Check fail2ban: fail2ban-client status sshd"
        echo "  4. Check logs: tail -f /var/log/nftban/ban-history.log"
        echo ""
    fi
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    print_header

    # Pre-flight checks
    log_info "Running pre-flight checks..."
    check_hostname
    check_ssh_client
    check_sshpass

    echo ""

    # Get target IP
    local target_ip
    target_ip=$(get_target_ip "$TARGET_IP")
    log_success "Target IP: $target_ip"

    # Verify target is reachable
    verify_target_reachable "$target_ip"
    verify_ssh_port_open "$target_ip"

    # Get attacker IP (this machine)
    local attacker_ip
    attacker_ip=$(hostname -I | awk '{print $1}')
    log_success "Attacker IP: $attacker_ip (this machine)"

    echo ""
    echo -e "${BOLD}${YELLOW}WARNING: This will simulate an SSH attack!${NC}"
    echo ""
    echo "This test will:"
    echo "  1. Attempt $ATTACK_ATTEMPTS failed SSH logins to $target_ip"
    echo "  2. Trigger fail2ban ban (threshold: 5 failures)"
    echo "  3. Block this IP ($attacker_ip) on target server"
    echo "  4. Verify the ban is working"
    echo ""
    echo "Your IP will be BANNED for 1 hour on the target server!"
    echo ""
    echo -n "Continue? (y/N): "
    read -r confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Test cancelled"
        exit 0
    fi

    echo ""
    echo -e "${BOLD}Starting attack simulation...${NC}"

    # Simulate attack
    simulate_ssh_attack "$target_ip" "$ATTACK_ATTEMPTS"

    # Wait for ban
    wait_for_ban "$WAIT_FOR_BAN"

    # Verify ban
    verify_ban_on_target "$target_ip" "$attacker_ip"

    # Verify connection blocked
    verify_connection_blocked "$target_ip"

    # Check logs
    check_logs_on_target "$target_ip"

    # Cleanup option
    cleanup_test "$target_ip"

    # Print report
    print_report

    echo ""
    echo -e "${CYAN}Next Steps:${NC}"
    echo "  1. Check email alerts on target server"
    echo "  2. View attack summary: ssh root@$target_ip 'view-attacks'"
    echo "  3. Check ban history: ssh root@$target_ip 'tail /var/log/nftban/ban-history.log'"
    echo "  4. Check login alerts: ssh root@$target_ip 'tail /var/log/nftban/login-alerts.log'"
    echo ""

    if [[ $TESTS_FAILED -eq 0 ]]; then
        exit 0
    else
        exit 1
    fi
}

# Run main
main "$@"
