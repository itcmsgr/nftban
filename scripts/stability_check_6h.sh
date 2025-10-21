#!/usr/bin/env bash
# =============================================================================
# nftban 6-Hour Stability Check Script
# =============================================================================
# Run this script 6 hours after deployment to verify stability
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

ISSUES=0

echo "╔═══════════════════════════════════════════════════════╗"
echo "║      nftban 6-Hour Stability Check                   ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""
echo "Running comprehensive stability verification..."
echo "Deployment time: $(date)"
echo ""

# =============================================================================
# CHECK 1: System Services
# =============================================================================
echo "═══════════════════════════════════════════════════════"
echo "  [1/10] System Services Status"
echo "═══════════════════════════════════════════════════════"

echo -n "→ nftables service: "
if systemctl is-active nftables &>/dev/null; then
    echo -e "${GREEN}✓ ACTIVE${NC}"
else
    echo -e "${RED}✗ INACTIVE${NC}"
    ((ISSUES++))
fi

echo -n "→ fail2ban service: "
if systemctl is-active fail2ban &>/dev/null; then
    echo -e "${GREEN}✓ ACTIVE${NC}"
else
    echo -e "${YELLOW}⊘ INACTIVE${NC} (may not be configured)"
fi

echo -n "→ login monitor timer: "
if systemctl is-active nftban-login-monitor.timer &>/dev/null; then
    echo -e "${GREEN}✓ ACTIVE${NC}"
else
    echo -e "${YELLOW}⊘ INACTIVE${NC}"
fi

echo ""

# =============================================================================
# CHECK 2: Error Analysis
# =============================================================================
echo "═══════════════════════════════════════════════════════"
echo "  [2/10] Error Analysis (Last 6 Hours)"
echo "═══════════════════════════════════════════════════════"

if [[ -f /var/log/nftban/nftban.log ]]; then
    ERROR_COUNT=$(grep -i "ERROR\|CRITICAL" /var/log/nftban/nftban.log 2>/dev/null | wc -l || echo "0")
    echo "→ Total errors in main log: $ERROR_COUNT"

    if [[ $ERROR_COUNT -gt 50 ]]; then
        echo -e "${RED}✗ HIGH ERROR COUNT${NC}"
        ((ISSUES++))
        echo ""
        echo "Recent errors:"
        grep -i "ERROR\|CRITICAL" /var/log/nftban/nftban.log 2>/dev/null | tail -10 | sed 's/^/  /'
    elif [[ $ERROR_COUNT -gt 10 ]]; then
        echo -e "${YELLOW}⚠ MODERATE ERROR COUNT${NC}"
        echo ""
        echo "Recent errors:"
        grep -i "ERROR\|CRITICAL" /var/log/nftban/nftban.log 2>/dev/null | tail -5 | sed 's/^/  /'
    else
        echo -e "${GREEN}✓ LOW ERROR COUNT${NC}"
    fi
else
    echo -e "${YELLOW}⊘ No log file found${NC}"
fi

echo ""

# =============================================================================
# CHECK 3: Memory Usage Trend
# =============================================================================
echo "═══════════════════════════════════════════════════════"
echo "  [3/10] Memory Usage Trend"
echo "═══════════════════════════════════════════════════════"

if [[ -f /var/log/nftban/debug_monitor.log ]]; then
    echo "→ Last 10 memory samples:"
    grep "Memory usage" /var/log/nftban/debug_monitor.log 2>/dev/null | tail -10 | sed 's/^/  /' || echo "  No data"

    # Check for memory leak (increasing pattern)
    FIRST_MEM=$(grep "Mem:" /var/log/nftban/debug_monitor.log 2>/dev/null | head -1 | awk '{print $3}' | sed 's/Gi//' || echo "0")
    LAST_MEM=$(grep "Mem:" /var/log/nftban/debug_monitor.log 2>/dev/null | tail -1 | awk '{print $3}' | sed 's/Gi//' || echo "0")

    if command -v bc &>/dev/null && [[ -n "$FIRST_MEM" && -n "$LAST_MEM" ]]; then
        DIFF=$(echo "$LAST_MEM - $FIRST_MEM" | bc 2>/dev/null || echo "0")
        if (( $(echo "$DIFF > 1.0" | bc -l 2>/dev/null || echo 0) )); then
            echo -e "${YELLOW}⚠ Memory increased by ${DIFF}Gi${NC}"
        else
            echo -e "${GREEN}✓ Memory stable${NC}"
        fi
    fi
else
    echo -e "${YELLOW}⊘ No monitoring data yet${NC}"
fi

echo ""

# =============================================================================
# CHECK 4: nftables Tables
# =============================================================================
echo "═══════════════════════════════════════════════════════"
echo "  [4/10] nftables Tables Verification"
echo "═══════════════════════════════════════════════════════"

echo -n "→ IPv4 table (nftban_v4): "
if nft list table ip nftban_v4 &>/dev/null; then
    echo -e "${GREEN}✓ EXISTS${NC}"
else
    echo -e "${RED}✗ MISSING${NC}"
    ((ISSUES++))
fi

echo -n "→ IPv6 table (nftban_v6): "
if nft list table ip6 nftban_v6 &>/dev/null; then
    echo -e "${GREEN}✓ EXISTS${NC}"
else
    echo -e "${RED}✗ MISSING${NC}"
    ((ISSUES++))
fi

echo ""

# =============================================================================
# CHECK 5: Ban Statistics
# =============================================================================
echo "═══════════════════════════════════════════════════════"
echo "  [5/10] Ban Statistics"
echo "═══════════════════════════════════════════════════════"

if nft list set ip nftban_v4 temp_ban &>/dev/null; then
    TEMP_BANS=$(nft list set ip nftban_v4 temp_ban 2>/dev/null | grep "elements" | wc -l || echo "0")
    echo "→ Temporary bans: $TEMP_BANS"
fi

if nft list set ip nftban_v4 user_blacklist &>/dev/null; then
    USER_BANS=$(nft list set ip nftban_v4 user_blacklist 2>/dev/null | grep "elements" | wc -l || echo "0")
    echo "→ User blacklist: $USER_BANS"
fi

if nft list set ip nftban_v4 whitelist &>/dev/null; then
    WHITELIST=$(nft list set ip nftban_v4 whitelist 2>/dev/null | grep "elements" | wc -l || echo "0")
    echo "→ Whitelist entries: $WHITELIST"
fi

echo ""

# =============================================================================
# CHECK 6: Monitoring Activity
# =============================================================================
echo "═══════════════════════════════════════════════════════"
echo "  [6/10] Monitoring Activity"
echo "═══════════════════════════════════════════════════════"

if [[ -f /var/log/nftban/debug_monitor.log ]]; then
    MONITOR_RUNS=$(grep -c "========================================" /var/log/nftban/debug_monitor.log 2>/dev/null || echo "0")
    echo "→ Monitoring runs completed: $MONITOR_RUNS"

    EXPECTED_RUNS=$((6 * 12))  # 6 hours * 12 runs per hour (every 5 min)

    if [[ $MONITOR_RUNS -lt 10 ]]; then
        echo -e "${YELLOW}⚠ Monitoring just started${NC}"
    elif [[ $MONITOR_RUNS -lt $(($EXPECTED_RUNS / 2)) ]]; then
        echo -e "${YELLOW}⚠ Fewer runs than expected${NC}"
    else
        echo -e "${GREEN}✓ Monitoring active${NC}"
    fi

    echo ""
    echo "→ Last monitoring run:"
    tail -15 /var/log/nftban/debug_monitor.log | sed 's/^/  /'
else
    echo -e "${YELLOW}⊘ No monitoring log found${NC}"
fi

echo ""

# =============================================================================
# CHECK 7: Disk Space
# =============================================================================
echo "═══════════════════════════════════════════════════════"
echo "  [7/10] Disk Space Usage"
echo "═══════════════════════════════════════════════════════"

echo "→ Log directory size:"
du -sh /var/log/nftban 2>/dev/null || echo "  N/A"

DISK_USAGE=$(df /var/log | tail -1 | awk '{print $5}' | sed 's/%//')
echo "→ /var/log partition usage: ${DISK_USAGE}%"

if [[ $DISK_USAGE -gt 90 ]]; then
    echo -e "${RED}✗ DISK SPACE CRITICAL${NC}"
    ((ISSUES++))
elif [[ $DISK_USAGE -gt 80 ]]; then
    echo -e "${YELLOW}⚠ DISK SPACE HIGH${NC}"
else
    echo -e "${GREEN}✓ DISK SPACE OK${NC}"
fi

echo ""

# =============================================================================
# CHECK 8: CPU Load Trend
# =============================================================================
echo "═══════════════════════════════════════════════════════"
echo "  [8/10] CPU Load Trend"
echo "═══════════════════════════════════════════════════════"

if [[ -f /var/log/nftban/debug_monitor.log ]]; then
    echo "→ Last 5 CPU load samples:"
    grep "CPU load:" /var/log/nftban/debug_monitor.log 2>/dev/null | tail -5 | sed 's/^/  /' || echo "  No data"
else
    echo "→ Current load:"
    uptime | sed 's/^/  /'
fi

echo ""

# =============================================================================
# CHECK 9: Run Comprehensive Function Tests
# =============================================================================
echo "═══════════════════════════════════════════════════════"
echo "  [9/10] Running Comprehensive Function Tests"
echo "═══════════════════════════════════════════════════════"
echo ""

if [[ -f /etc/nftban/scripts/comprehensive_function_test.sh ]]; then
    if bash /etc/nftban/scripts/comprehensive_function_test.sh 2>&1 | tee /tmp/function_test_results.txt; then
        echo ""
        echo -e "${GREEN}✓ All function tests passed${NC}"
    else
        echo ""
        echo -e "${RED}✗ Some function tests failed${NC}"
        ((ISSUES++))
        echo ""
        echo "Failed tests:"
        grep "✗ FAIL" /tmp/function_test_results.txt | sed 's/^/  /'
    fi
else
    echo -e "${YELLOW}⊘ Test script not found${NC}"
fi

echo ""

# =============================================================================
# CHECK 10: Critical Function Spot Check
# =============================================================================
echo "═══════════════════════════════════════════════════════"
echo "  [10/10] Critical Function Spot Check"
echo "═══════════════════════════════════════════════════════"

echo -n "→ nftban command: "
if command -v nftban &>/dev/null; then
    echo -e "${GREEN}✓ AVAILABLE${NC}"
else
    echo -e "${RED}✗ NOT FOUND${NC}"
    ((ISSUES++))
fi

echo -n "→ DDoS module: "
if nftban ddos status &>/dev/null; then
    echo -e "${GREEN}✓ FUNCTIONAL${NC}"
else
    echo -e "${YELLOW}⊘ ISSUES${NC}"
fi

echo -n "→ Portscan module: "
if nftban portscan status &>/dev/null; then
    echo -e "${GREEN}✓ FUNCTIONAL${NC}"
else
    echo -e "${YELLOW}⊘ ISSUES${NC}"
fi

echo -n "→ Whitelist operations: "
if nftban whitelist list &>/dev/null; then
    echo -e "${GREEN}✓ FUNCTIONAL${NC}"
else
    echo -e "${RED}✗ FAILED${NC}"
    ((ISSUES++))
fi

echo -n "→ Safety checks: "
if nftban check-safety &>/dev/null; then
    echo -e "${GREEN}✓ FUNCTIONAL${NC}"
else
    echo -e "${YELLOW}⊘ ISSUES${NC}"
fi

echo ""

# =============================================================================
# FINAL SUMMARY
# =============================================================================
echo "╔═══════════════════════════════════════════════════════╗"
echo "║      6-HOUR STABILITY CHECK SUMMARY                  ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""

echo "Checks Completed: 10"
echo "Critical Issues Found: $ISSUES"
echo ""

if [[ $ISSUES -eq 0 ]]; then
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║      ✓ SYSTEM STABLE - READY FOR PRODUCTION          ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Recommendations:"
    echo "  • System is stable and functioning correctly"
    echo "  • All critical functions operational"
    echo "  • No significant issues detected"
    echo "  • Safe to deploy to production"
    echo ""
    exit 0
elif [[ $ISSUES -le 2 ]]; then
    echo -e "${YELLOW}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║      ⚠ MINOR ISSUES DETECTED                          ║${NC}"
    echo -e "${YELLOW}╚═══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Recommendations:"
    echo "  • Review issues listed above"
    echo "  • Most functions working correctly"
    echo "  • Consider fixing minor issues before production"
    echo "  • Monitor for another 6 hours if uncertain"
    echo ""
    exit 1
else
    echo -e "${RED}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║      ✗ CRITICAL ISSUES DETECTED                       ║${NC}"
    echo -e "${RED}╚═══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Recommendations:"
    echo "  • Review all errors listed above"
    echo "  • Fix critical issues before production"
    echo "  • Run comprehensive diagnostics"
    echo "  • Consult documentation in docs/BUG_FIX_SUMMARY_2025-10-21.md"
    echo ""
    exit 1
fi
