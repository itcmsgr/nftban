#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.30 - Test All Lab Servers
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Run tests on all 5 lab servers and collect results
#
# Usage: ./test_all_labs.sh
# =============================================================================

set -Eeuo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Lab servers
declare -A SERVERS=(
    ["lab.mywebhost.gr"]="CentOS Stream 9"
    ["lab1.mywebhost.gr"]="Ubuntu 24.04"
    ["lab2.mywebhost.gr"]="CentOS Stream 10"
    ["lab3.mywebhost.gr"]="AlmaLinux 10"
    ["lab4.mywebhost.gr"]="Rocky Linux 10"
)

echo "════════════════════════════════════════════════════════════"
echo "  NFTBan v0.30 - Test All Lab Servers"
echo "════════════════════════════════════════════════════════════"
echo

RESULTS_DIR="/tmp/nftban_test_results_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"

echo "Results will be saved to: $RESULTS_DIR"
echo

# Test one server
test_server() {
    local server="$1"
    local os="${SERVERS[$server]}"
    local result_file="$RESULTS_DIR/${server}.txt"

    echo
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Testing: $server ($os)${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"

    {
        echo "NFTBan v0.30 Test Results"
        echo "Server: $server"
        echo "OS: $os"
        echo "Date: $(date -Iseconds)"
        echo "════════════════════════════════════════════════════════════"
        echo
    } > "$result_file"

    # Test SSH connection
    if ! ssh -o ConnectTimeout=5 "root@$server" "echo 'OK'" &>/dev/null; then
        echo -e "${RED}✗ Cannot connect to $server${NC}"
        echo "ERROR: Cannot connect" >> "$result_file"
        return 1
    fi

    echo -e "${GREEN}✓ Connected${NC}"

    # Test 1: Check helpers exist
    echo -n "Testing helpers... "
    {
        echo "TEST: Helpers Installation"
        echo "───────────────────────────────────────────────────────────"
    } >> "$result_file"

    local helpers_ok=0
    for helper in nftban-procnet nftban-pkgs nftban-verify nftban-firewall; do
        if ssh "root@$server" "test -x /usr/libexec/nftban/$helper" 2>/dev/null; then
            echo "✓ $helper" >> "$result_file"
            helpers_ok=$((helpers_ok + 1))
        else
            echo "✗ $helper MISSING" >> "$result_file"
        fi
    done

    if [[ $helpers_ok -eq 4 ]]; then
        echo -e "${GREEN}✓ All helpers present${NC}"
    else
        echo -e "${YELLOW}⚠ Only $helpers_ok/4 helpers found${NC}"
    fi
    echo >> "$result_file"

    # Test 2: Check health commands
    echo -n "Testing health commands... "
    {
        echo "TEST: Health Commands"
        echo "───────────────────────────────────────────────────────────"
    } >> "$result_file"

    if ssh "root@$server" "which nftban-health" &>/dev/null; then
        echo "✓ nftban-health available" >> "$result_file"
        echo -e "${GREEN}✓ Health command available${NC}"
    else
        echo "✗ nftban-health NOT FOUND" >> "$result_file"
        echo -e "${RED}✗ Health command missing${NC}"
    fi
    echo >> "$result_file"

    # Test 3: Run inventory
    echo -n "Testing inventory... "
    {
        echo "TEST: Inventory Collection"
        echo "───────────────────────────────────────────────────────────"
    } >> "$result_file"

    if ssh "root@$server" "/usr/libexec/nftban/nftban-procnet 2>&1" >> "$result_file"; then
        echo -e "${GREEN}✓ Inventory works${NC}"
    else
        echo -e "${YELLOW}⚠ Inventory failed${NC}"
    fi
    echo >> "$result_file"

    # Test 4: Check mail adapter
    echo -n "Testing mail adapter... "
    {
        echo "TEST: Mail Adapter"
        echo "───────────────────────────────────────────────────────────"
    } >> "$result_file"

    if ssh "root@$server" "test -f /usr/lib/nftban/core/nftban_mail_v030.sh" 2>/dev/null; then
        echo "✓ Mail adapter installed" >> "$result_file"

        # Test mail detection
        ssh "root@$server" "source /usr/lib/nftban/core/nftban_mail_v030.sh 2>/dev/null && nftban_v030_mail_info" >> "$result_file" 2>&1 || true

        echo -e "${GREEN}✓ Mail adapter present${NC}"
    else
        echo "✗ Mail adapter NOT FOUND" >> "$result_file"
        echo -e "${RED}✗ Mail adapter missing${NC}"
    fi
    echo >> "$result_file"

    # Test 5: System info
    echo -n "Collecting system info... "
    {
        echo "TEST: System Information"
        echo "───────────────────────────────────────────────────────────"
        ssh "root@$server" "uname -a" 2>&1
        echo
        ssh "root@$server" "cat /etc/os-release | grep -E 'NAME|VERSION'" 2>&1
        echo
    } >> "$result_file"
    echo -e "${GREEN}✓ Info collected${NC}"

    {
        echo "════════════════════════════════════════════════════════════"
        echo "END OF TEST"
        echo "════════════════════════════════════════════════════════════"
    } >> "$result_file"

    echo -e "${GREEN}✓ Test complete for $server${NC}"
    echo "   Results: $result_file"

    return 0
}

# Run tests on all servers
SUCCESS=0
FAILED=0

for server in "${!SERVERS[@]}"; do
    if test_server "$server"; then
        SUCCESS=$((SUCCESS + 1))
    else
        FAILED=$((FAILED + 1))
    fi
done

echo
echo "════════════════════════════════════════════════════════════"
echo "  TEST SUMMARY"
echo "════════════════════════════════════════════════════════════"
echo -e "${GREEN}✓ Tested: $SUCCESS servers${NC}"
echo -e "${RED}✗ Failed: $FAILED servers${NC}"
echo "Total:   ${#SERVERS[@]} servers"
echo
echo "Results saved to: $RESULTS_DIR"
echo

# Show quick summary
echo "Quick Summary:"
echo "───────────────────────────────────────────────────────────"
for server in "${!SERVERS[@]}"; do
    result_file="$RESULTS_DIR/${server}.txt"
    if [[ -f "$result_file" ]]; then
        echo "$server (${SERVERS[$server]}):"
        if grep -q "ERROR: Cannot connect" "$result_file"; then
            echo "  ✗ Connection failed"
        else
            echo "  ✓ Tests completed"
        fi
    fi
done
echo

if [[ $FAILED -eq 0 ]]; then
    echo -e "${GREEN}🎉 ALL SERVERS TESTED SUCCESSFULLY!${NC}"
    exit 0
else
    echo -e "${YELLOW}⚠️  Some tests failed - check results in $RESULTS_DIR${NC}"
    exit 1
fi
