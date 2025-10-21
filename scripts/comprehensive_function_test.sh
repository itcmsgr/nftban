#!/usr/bin/env bash
# =============================================================================
# nftban Comprehensive Function Testing Script
# =============================================================================
# Tests ALL major functions one by one to ensure stability
#
# Author: ITCMS Team
# Version: 0.9.1
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASSED=0
FAILED=0
SKIPPED=0

echo "╔═══════════════════════════════════════════════════════╗"
echo "║   nftban Comprehensive Function Test Suite           ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""
echo "Testing all major functions for stability..."
echo ""

# Test function wrapper
test_function() {
    local category="$1"
    local test_name="$2"
    shift 2
    local command="$@"

    printf "[%-3d] %-50s " "$((PASSED + FAILED + SKIPPED + 1))" "$category: $test_name"

    if eval "$command" &>/dev/null; then
        echo -e "${GREEN}✓ PASS${NC}"
        ((PASSED++))
        return 0
    else
        echo -e "${RED}✗ FAIL${NC}"
        ((FAILED++))
        return 1
    fi
}

test_function_with_output() {
    local category="$1"
    local test_name="$2"
    shift 2
    local command="$@"
    local expected_pattern="$1"

    printf "[%-3d] %-50s " "$((PASSED + FAILED + SKIPPED + 1))" "$category: $test_name"

    local output
    output=$(eval "${command}" 2>&1) || true

    if [[ "$output" =~ $expected_pattern ]]; then
        echo -e "${GREEN}✓ PASS${NC}"
        ((PASSED++))
        return 0
    else
        echo -e "${RED}✗ FAIL${NC}"
        ((FAILED++))
        return 1
    fi
}

skip_test() {
    local category="$1"
    local test_name="$2"
    local reason="$3"

    printf "[%-3d] %-50s " "$((PASSED + FAILED + SKIPPED + 1))" "$category: $test_name"
    echo -e "${YELLOW}⊘ SKIP${NC} ($reason)"
    ((SKIPPED++))
}

echo "═══════════════════════════════════════════════════════"
echo "  CATEGORY 1: Core Module Functions"
echo "═══════════════════════════════════════════════════════"

test_function "Core" "nftban command exists" "command -v nftban"
test_function "Core" "Version display" "nftban --version"
test_function "Core" "Help command" "nftban help"
test_function "Core" "Status command" "nftban status"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  CATEGORY 2: nftables Functions"
echo "═══════════════════════════════════════════════════════"

test_function "nftables" "IPv4 table exists" "nft list table ip nftban_v4"
test_function "nftables" "IPv6 table exists" "nft list table ip6 nftban_v6"
test_function "nftables" "Whitelist set exists (v4)" "nft list set ip nftban_v4 whitelist"
test_function "nftables" "Whitelist set exists (v6)" "nft list set ip6 nftban_v6 whitelist"
test_function "nftables" "Temp ban set exists (v4)" "nft list set ip nftban_v4 temp_ban"
test_function "nftables" "User blacklist set exists (v4)" "nft list set ip nftban_v4 user_blacklist"
test_function "nftables" "System blacklist set exists (v4)" "nft list set ip nftban_v4 system_blacklist"
test_function "nftables" "Feeds set exists (v4)" "nft list set ip nftban_v4 feeds"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  CATEGORY 3: Whitelist Functions"
echo "═══════════════════════════════════════════════════════"

test_function "Whitelist" "Add test IP" "nftban whitelist add 192.0.2.100 test-ip"
test_function "Whitelist" "List whitelist" "nftban whitelist list"
test_function "Whitelist" "Check test IP" "nftban whitelist check 192.0.2.100"
test_function "Whitelist" "Remove test IP" "nftban whitelist remove 192.0.2.100"
test_function "Whitelist" "Sync command" "nftban whitelist sync"
test_function "Whitelist" "Stats command" "nftban stats whitelist"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  CATEGORY 4: Blacklist Functions"
echo "═══════════════════════════════════════════════════════"

test_function "Blacklist" "Add test IP" "nftban blacklist add 198.51.100.100 test-ban"
test_function "Blacklist" "List blacklist" "nftban blacklist list"
test_function "Blacklist" "Check test IP" "nftban blacklist check 198.51.100.100"
test_function "Blacklist" "Remove test IP" "nftban blacklist remove 198.51.100.100"
test_function "Blacklist" "Stats command" "nftban stats blacklist"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  CATEGORY 5: Temporary Ban Functions"
echo "═══════════════════════════════════════════════════════"

test_function "Ban" "Add temporary ban" "nftban ban add 203.0.113.100 300 test-temp-ban"
test_function "Ban" "List bans" "nftban ban list"
test_function "Ban" "Check banned IP" "nftban ban check 203.0.113.100"
test_function "Ban" "Remove ban" "nftban ban remove 203.0.113.100"
test_function "Ban" "Stats command" "nftban stats bans"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  CATEGORY 6: Safety Mechanism Functions"
echo "═══════════════════════════════════════════════════════"

test_function "Safety" "Check safety" "nftban check-safety"
test_function "Safety" "Whitelist protect-server" "nftban whitelist protect-server"
test_function "Safety" "Verify installation" "nftban verify"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  CATEGORY 7: Sync Functions"
echo "═══════════════════════════════════════════════════════"

test_function "Sync" "Sync test (dry-run)" "nftban sync test"
test_function "Sync" "Sync status" "nftban sync status"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  CATEGORY 8: Statistics Functions"
echo "═══════════════════════════════════════════════════════"

test_function "Stats" "Summary stats" "nftban stats summary"
test_function "Stats" "Whitelist stats" "nftban stats whitelist"
test_function "Stats" "Blacklist stats" "nftban stats blacklist"
test_function "Stats" "Ban stats" "nftban stats bans"
test_function "Stats" "Feed stats" "nftban stats feeds"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  CATEGORY 9: DDoS Protection Functions"
echo "═══════════════════════════════════════════════════════"

test_function "DDoS" "Status command" "nftban ddos status"
test_function "DDoS" "Connection limit status" "nftban ddos connlimit status"
test_function "DDoS" "Port flood status" "nftban ddos portflood status"
test_function "DDoS" "ICMP status" "nftban ddos icmp status"
test_function "DDoS" "SYN flood status" "nftban ddos synflood status"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  CATEGORY 10: Port Scan Detection Functions"
echo "═══════════════════════════════════════════════════════"

test_function "Portscan" "Status command" "nftban portscan status"
test_function "Portscan" "Stats command" "nftban portscan stats"
test_function "Portscan" "Check command" "nftban portscan check"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  CATEGORY 11: Login Monitor Functions"
echo "═══════════════════════════════════════════════════════"

test_function "Login" "Status command" "nftban login status"

if systemctl list-unit-files | grep -q nftban-login-monitor.timer; then
    test_function "Login" "Timer exists" "systemctl list-timers | grep -q nftban-login-monitor"
else
    skip_test "Login" "Timer exists" "Not installed"
fi

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  CATEGORY 12: Maintenance Functions"
echo "═══════════════════════════════════════════════════════"

test_function "Maintenance" "Panel command" "nftban maintenance panel"
test_function "Maintenance" "Backup command" "nftban maintenance backup"
test_function "Maintenance" "Status command" "nftban maintenance status"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  CATEGORY 13: Feed Functions"
echo "═══════════════════════════════════════════════════════"

test_function "Feeds" "Status command" "nftban feeds status"
test_function "Feeds" "List command" "nftban feeds list"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  CATEGORY 14: Port Management Functions"
echo "═══════════════════════════════════════════════════════"

test_function "Ports" "List command" "nftban ports list"
test_function "Ports" "Show command" "nftban ports show"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  CATEGORY 15: Geo Blocking Functions"
echo "═══════════════════════════════════════════════════════"

test_function "Geo" "Status command" "nftban geo status"
test_function "Geo" "List command" "nftban geo list"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  CATEGORY 16: CloudFlare Functions"
echo "═══════════════════════════════════════════════════════"

test_function "CloudFlare" "Status command" "nftban cloudflare status"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  CATEGORY 17: Smoketest Functions"
echo "═══════════════════════════════════════════════════════"

test_function "Test" "Installation tests" "nftban test category installation"
test_function "Test" "nftables tests" "nftban test category nftables"
test_function "Test" "Modules tests" "nftban test category modules"
test_function "Test" "Dependencies tests" "nftban test category deps"
test_function "Test" "CLI tests" "nftban test category cli"
test_function "Test" "Safety tests" "nftban test category safety"
test_function "Test" "Config tests" "nftban test category config"
test_function "Test" "Logging tests" "nftban test category logging"
test_function "Test" "Network tests" "nftban test category network"
test_function "Test" "Installer tests" "nftban test category installer"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  CATEGORY 18: Update Functions"
echo "═══════════════════════════════════════════════════════"

test_function "Update" "Check command" "nftban update check"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  TEST SUMMARY"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "Total Tests:    $((PASSED + FAILED + SKIPPED))"
echo -e "${GREEN}Passed:         $PASSED${NC}"
echo -e "${RED}Failed:         $FAILED${NC}"
echo -e "${YELLOW}Skipped:        $SKIPPED${NC}"
echo ""

PASS_RATE=0
if [[ $((PASSED + FAILED)) -gt 0 ]]; then
    PASS_RATE=$((PASSED * 100 / (PASSED + FAILED)))
fi

echo "Pass Rate:      $PASS_RATE%"
echo ""

if [[ $FAILED -eq 0 ]]; then
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║      ✓ ALL TESTS PASSED                               ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
    exit 0
else
    echo -e "${RED}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║      ✗ SOME TESTS FAILED                              ║${NC}"
    echo -e "${RED}╚═══════════════════════════════════════════════════════╝${NC}"
    exit 1
fi
