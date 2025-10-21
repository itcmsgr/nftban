#!/usr/bin/env bash
#
# Deploy and Run Security Scans on All Lab Servers
#
# Purpose: Run comprehensive security scanning across all distros
# Servers: CentOS 9, Ubuntu 24.04, CentOS 10
#
# Author: ITCMS Team (Antonios Voulvoulis)
# Version: 1.0.0
# Date: 2025-10-21

set -Eeuo pipefail

# Lab servers
SERVERS=(
    "root@lab.example.test|CentOS 9"
    "root@lab1.example.test|Ubuntu 24.04"
    "root@198.51.100.15|CentOS 10"
)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "╔═══════════════════════════════════════════════════════╗"
echo "║   NFTBan Security Scanner - All Lab Servers          ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""
echo "This will:"
echo "1. Deploy security scanning script to all lab servers"
echo "2. Install security tools (ShellCheck, Gitleaks, Trivy, etc.)"
echo "3. Run comprehensive security scans on each server"
echo "4. Download results for comparison"
echo "5. Generate cross-distro security report"
echo ""

read -p "Continue? [y/N]: " -r
if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# Create local results directory
RESULTS_BASE="/tmp/nftban-security-scan-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULTS_BASE"

echo -e "${BLUE}Local results directory: $RESULTS_BASE${NC}"
echo ""

# ============================================================================
# Deploy and Run on Each Server
# ============================================================================

for server_info in "${SERVERS[@]}"; do
    IFS='|' read -r server os <<< "$server_info"

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${YELLOW}Server: $server ($os)${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # 1. Copy security scan script to server
    echo "→ Copying security scan script..."
    if scp -q scripts/security_scan_lab.sh "$server:/tmp/security_scan_lab.sh"; then
        echo -e "${GREEN}✓ Script copied${NC}"
    else
        echo -e "${RED}✗ Failed to copy script${NC}"
        continue
    fi

    # 2. Make executable
    ssh "$server" "chmod +x /tmp/security_scan_lab.sh"

    # 3. Run security scan (non-interactive with auto-yes)
    echo "→ Running security scan on $os..."
    echo ""

    if ssh "$server" "echo 'yes' | /tmp/security_scan_lab.sh" 2>&1 | tee "$RESULTS_BASE/${os//[ .]/_}-console.log"; then
        echo -e "${GREEN}✓ Security scan completed on $os${NC}"
    else
        echo -e "${YELLOW}⚠ Security scan completed with warnings on $os${NC}"
    fi

    echo ""

    # 4. Download results archive
    echo "→ Downloading results from $os..."

    # Find the latest archive
    REMOTE_ARCHIVE=$(ssh "$server" "ls -t /tmp/security-scan-*.tar.gz 2>/dev/null | head -1")

    if [[ -n "$REMOTE_ARCHIVE" ]]; then
        LOCAL_ARCHIVE="$RESULTS_BASE/${os//[ .]/_}-results.tar.gz"
        if scp -q "$server:$REMOTE_ARCHIVE" "$LOCAL_ARCHIVE"; then
            echo -e "${GREEN}✓ Results downloaded${NC}"

            # Extract locally
            mkdir -p "$RESULTS_BASE/${os//[ .]/_}"
            tar -xzf "$LOCAL_ARCHIVE" -C "$RESULTS_BASE/${os//[ .]/_}" --strip-components=1

            # Clean up remote archive
            ssh "$server" "rm -f $REMOTE_ARCHIVE /tmp/security_scan_lab.sh"
        else
            echo -e "${RED}✗ Failed to download results${NC}"
        fi
    else
        echo -e "${YELLOW}⚠ No archive found on server${NC}"
    fi

    echo ""
done

# ============================================================================
# Generate Cross-Distro Comparison Report
# ============================================================================

echo "╔═══════════════════════════════════════════════════════╗"
echo "║   Generating Cross-Distro Security Report            ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""

REPORT="$RESULTS_BASE/SECURITY_REPORT_ALL_DISTROS.md"

{
    echo "# NFTBan Security Scan - All Lab Servers"
    echo ""
    echo "**Date:** $(date)"
    echo "**Scan Results:** Comparison across all distributions"
    echo ""
    echo "---"
    echo ""

    echo "## Servers Scanned"
    echo ""
    for server_info in "${SERVERS[@]}"; do
        IFS='|' read -r server os <<< "$server_info"
        echo "- **$os**: $server"
    done
    echo ""
    echo "---"
    echo ""

    echo "## ShellCheck Results Comparison"
    echo ""
    echo "| Distribution | Scripts | Errors | Warnings | Notes |"
    echo "|--------------|---------|--------|----------|-------|"

    for server_info in "${SERVERS[@]}"; do
        IFS='|' read -r server os <<< "$server_info"
        OS_DIR="${os//[ .]/_}"

        if [[ -f "$RESULTS_BASE/$OS_DIR/shellcheck-summary.txt" ]]; then
            TOTAL=$(grep "Total scripts scanned:" "$RESULTS_BASE/$OS_DIR/shellcheck-summary.txt" | awk '{print $NF}')
            ERRORS=$(grep "^Errors:" "$RESULTS_BASE/$OS_DIR/shellcheck-summary.txt" | awk '{print $NF}')
            WARNINGS=$(grep "^Warnings:" "$RESULTS_BASE/$OS_DIR/shellcheck-summary.txt" | awk '{print $NF}')
            NOTES=$(grep "^Notes:" "$RESULTS_BASE/$OS_DIR/shellcheck-summary.txt" | awk '{print $NF}')

            echo "| $os | $TOTAL | $ERRORS | $WARNINGS | $NOTES |"
        else
            echo "| $os | N/A | N/A | N/A | N/A |"
        fi
    done

    echo ""
    echo "---"
    echo ""

    echo "## Gitleaks Secret Detection"
    echo ""
    echo "| Distribution | Secrets Found | Status |"
    echo "|--------------|---------------|--------|"

    for server_info in "${SERVERS[@]}"; do
        IFS='|' read -r server os <<< "$server_info"
        OS_DIR="${os//[ .]/_}"

        if [[ -f "$RESULTS_BASE/$OS_DIR/gitleaks-summary.txt" ]]; then
            if grep -q "No secrets detected" "$RESULTS_BASE/$OS_DIR/gitleaks-summary.txt"; then
                echo "| $os | 0 | ✅ Clean |"
            else
                COUNT=$(grep "Total findings:" "$RESULTS_BASE/$OS_DIR/gitleaks-summary.txt" | awk '{print $NF}')
                echo "| $os | ${COUNT:-Unknown} | ⚠️ Review |"
            fi
        else
            echo "| $os | N/A | ❌ Not scanned |"
        fi
    done

    echo ""
    echo "---"
    echo ""

    echo "## Permission Issues"
    echo ""

    for server_info in "${SERVERS[@]}"; do
        IFS='|' read -r server os <<< "$server_info"
        OS_DIR="${os//[ .]/_}"

        echo "### $os"
        echo ""

        if [[ -f "$RESULTS_BASE/$OS_DIR/permissions-audit.txt" ]]; then
            echo '```'
            echo "World-writable files:"
            grep -A5 "world-writable" "$RESULTS_BASE/$OS_DIR/permissions-audit.txt" | grep -v "None found" || echo "  None"
            echo ""
            echo "SUID/SGID files:"
            grep -A5 "SUID/SGID" "$RESULTS_BASE/$OS_DIR/permissions-audit.txt" | grep -v "None found" || echo "  None"
            echo '```'
        else
            echo "No permission audit data"
        fi
        echo ""
    done

    echo "---"
    echo ""

    echo "## Dangerous Code Patterns"
    echo ""

    for server_info in "${SERVERS[@]}"; do
        IFS='|' read -r server os <<< "$server_info"
        OS_DIR="${os//[ .]/_}"

        echo "### $os"
        echo ""

        if [[ -f "$RESULTS_BASE/$OS_DIR/code-patterns.txt" ]]; then
            echo '```'
            echo "eval usage:"
            grep -A3 "Use of 'eval'" "$RESULTS_BASE/$OS_DIR/code-patterns.txt" | tail -2 || echo "  None"
            echo ""
            echo "Missing strict mode:"
            grep -A5 "Missing strict mode" "$RESULTS_BASE/$OS_DIR/code-patterns.txt" | tail -4 || echo "  All scripts OK"
            echo '```'
        else
            echo "No code pattern data"
        fi
        echo ""
    done

    echo "---"
    echo ""

    echo "## Distro-Specific Issues"
    echo ""

    echo "### Differences Found"
    echo ""

    # Compare shellcheck results
    CENTOS9_ERRORS=$(grep "^Errors:" "$RESULTS_BASE/CentOS_9/shellcheck-summary.txt" 2>/dev/null | awk '{print $NF}' || echo "0")
    UBUNTU_ERRORS=$(grep "^Errors:" "$RESULTS_BASE/Ubuntu_2404/shellcheck-summary.txt" 2>/dev/null | awk '{print $NF}' || echo "0")
    CENTOS10_ERRORS=$(grep "^Errors:" "$RESULTS_BASE/CentOS_10/shellcheck-summary.txt" 2>/dev/null | awk '{print $NF}' || echo "0")

    if [[ "$CENTOS9_ERRORS" != "$UBUNTU_ERRORS" ]] || [[ "$UBUNTU_ERRORS" != "$CENTOS10_ERRORS" ]]; then
        echo "- ⚠️ **ShellCheck error counts differ across distros**"
        echo "  - This may indicate distro-specific code paths or bash version differences"
    else
        echo "- ✅ ShellCheck results consistent across all distros"
    fi

    echo ""
    echo "---"
    echo ""

    echo "## Summary & Recommendations"
    echo ""

    # Calculate totals
    TOTAL_ERRORS=0
    TOTAL_WARNINGS=0

    for server_info in "${SERVERS[@]}"; do
        IFS='|' read -r server os <<< "$server_info"
        OS_DIR="${os//[ .]/_}"

        if [[ -f "$RESULTS_BASE/$OS_DIR/shellcheck-summary.txt" ]]; then
            ERR=$(grep "^Errors:" "$RESULTS_BASE/$OS_DIR/shellcheck-summary.txt" | awk '{print $NF}')
            WARN=$(grep "^Warnings:" "$RESULTS_BASE/$OS_DIR/shellcheck-summary.txt" | awk '{print $NF}')
            ((TOTAL_ERRORS += ERR))
            ((TOTAL_WARNINGS += WARN))
        fi
    done

    echo "### Overall Statistics"
    echo ""
    echo "- **Total ShellCheck Errors:** $TOTAL_ERRORS"
    echo "- **Total ShellCheck Warnings:** $TOTAL_WARNINGS"
    echo "- **Distributions Tested:** ${#SERVERS[@]}"
    echo ""

    echo "### Priority Actions"
    echo ""

    if ((TOTAL_ERRORS > 0)); then
        echo "1. **CRITICAL:** Address $TOTAL_ERRORS ShellCheck errors"
        echo "   - Review detailed reports in each distro directory"
        echo "   - Fix highest severity issues first"
    fi

    if ((TOTAL_WARNINGS > 50)); then
        echo "2. **HIGH:** Address $TOTAL_WARNINGS ShellCheck warnings"
        echo "   - Focus on code quality and maintainability"
    fi

    echo "3. **MEDIUM:** Review code patterns for security issues"
    echo "   - Check for unquoted variables"
    echo "   - Verify all scripts use strict mode"
    echo "4. **LOW:** Compare results across distros for consistency"
    echo "   - Ensure behavior is identical on all platforms"
    echo ""

    echo "---"
    echo ""
    echo "## Detailed Reports"
    echo ""
    echo "Full scan results available in:"
    echo '```'
    echo "$RESULTS_BASE/"
    echo "├── CentOS_9/"
    echo "│   ├── shellcheck-results.txt"
    echo "│   ├── gitleaks-results.json"
    echo "│   ├── trivy-results.txt"
    echo "│   ├── permissions-audit.txt"
    echo "│   ├── code-patterns.txt"
    echo "│   └── nftables-security.txt"
    echo "├── Ubuntu_2404/"
    echo "│   └── (same structure)"
    echo "└── CentOS_10/"
    echo "    └── (same structure)"
    echo '```'
    echo ""

    echo "---"
    echo ""
    echo "**Generated:** $(date)"
    echo "**Tool:** nftban security scanner v1.0.0"

} > "$REPORT"

echo -e "${GREEN}✓ Cross-distro report generated${NC}"
echo ""

# ============================================================================
# Display Summary
# ============================================================================

cat "$REPORT"

echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║   Security Scan Complete - All Servers               ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""
echo "Results saved to: $RESULTS_BASE/"
echo ""
echo "Files generated:"
echo "  - $REPORT"
echo "  - Console logs for each distro"
echo "  - Full scan results for each distro"
echo ""
echo "Next steps:"
echo "1. Review the cross-distro report above"
echo "2. Check detailed results in $RESULTS_BASE/"
echo "3. Address any HIGH/CRITICAL findings"
echo "4. Re-run scan after fixes to verify"
echo ""
