#!/usr/bin/env bash
# =============================================================================
# NFTBan 24-Hour Stability Monitoring Script
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Monitor NFTBan health and collect logs for 24-hour stability test
#
# Usage:
#   ./scripts/monitor-24h.sh [server]
#
# Example:
#   ./scripts/monitor-24h.sh lab4.mywebhost.gr
#   ./scripts/monitor-24h.sh all  # Monitor all lab servers
# =============================================================================

set -Eeuo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SERVERS=(
    "lab.mywebhost.gr"
    "lab1.mywebhost.gr"
    "lab2.mywebhost.gr"
    "lab4.mywebhost.gr"
)

REPORT_DIR="/tmp/nftban-24h-monitoring"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# =============================================================================
# Functions
# =============================================================================

print_header() {
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE} $1${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo ""
}

check_server() {
    local server=$1
    local report_file="${REPORT_DIR}/${server}_${TIMESTAMP}.log"

    print_header "Monitoring: $server"

    echo "Timestamp: $(date)" | tee -a "$report_file"
    echo "" | tee -a "$report_file"

    # Check if server is reachable
    if ! ssh -o ConnectTimeout=5 root@"$server" "echo 'connected'" &>/dev/null; then
        echo -e "${RED}✗ Server unreachable${NC}" | tee -a "$report_file"
        return 1
    fi

    echo -e "${GREEN}✓ Server reachable${NC}" | tee -a "$report_file"
    echo "" | tee -a "$report_file"

    # Collect system info
    ssh root@"$server" bash <<'ENDSSH' | tee -a "$report_file"
echo "=== System Information ==="
echo "Hostname: $(hostname)"
echo "Uptime: $(uptime)"
echo "Load: $(cat /proc/loadavg)"
echo ""

echo "=== NFTBan Health Check ==="
nftban health check 2>&1 | head -40
echo ""

echo "=== FHS Compliance ==="
nftban fhs check 2>&1 | grep -E "(OK|ERROR|Total)" | head -10
echo ""

echo "=== Timer Status ==="
systemctl list-timers | grep nftban
echo ""

echo "=== Service Status ==="
systemctl is-active nftban-health.timer || echo "nftban-health.timer: inactive"
systemctl is-active nftban-permissions-audit.timer || echo "nftban-permissions-audit.timer: inactive"
echo ""

echo "=== Recent Health Check Runs ==="
journalctl -u nftban-health.service --since "24 hours ago" --no-pager | tail -20
echo ""

echo "=== Recent Permission Audits ==="
journalctl -u nftban-permissions-audit.service --since "24 hours ago" --no-pager | tail -20
echo ""

echo "=== Error Count (last 24h) ==="
journalctl --since "24 hours ago" --no-pager | grep -i "nftban" | grep -ci "error" || echo "0 errors"
echo ""

echo "=== Polkit Activity ==="
journalctl -u polkit --since "1 hour ago" --no-pager | grep -i nftban | tail -10 || echo "No Polkit activity"
echo ""

echo "=== Disk Usage ==="
df -h | grep -E "(Filesystem|nftban|var|tmp)"
echo ""

echo "=== Memory Usage ==="
free -h
echo ""

ENDSSH

    echo -e "${GREEN}✓ Monitoring complete for $server${NC}"
    echo "Report saved to: $report_file"
}

generate_summary() {
    local summary_file="${REPORT_DIR}/SUMMARY_${TIMESTAMP}.md"

    print_header "Generating Summary Report"

    cat > "$summary_file" <<EOF
# NFTBan 24-Hour Stability Monitoring Summary

**Generated:** $(date)
**Duration:** 24 hours
**Servers Monitored:** ${#SERVERS[@]}

---

## Executive Summary

EOF

    for server in "${SERVERS[@]}"; do
        local report_file="${REPORT_DIR}/${server}_${TIMESTAMP}.log"

        if [[ -f "$report_file" ]]; then
            cat >> "$summary_file" <<EOF
### $server

**Status:**
$(grep -q "Server reachable" "$report_file" && echo "✅ Online" || echo "❌ Offline")

**Health Check:**
\`\`\`
$(grep -A 5 "Overall Status:" "$report_file" | head -6)
\`\`\`

**Errors (24h):**
$(grep "Error Count" "$report_file" -A 1 | tail -1)

**Timers:**
$(grep -A 2 "Timer Status" "$report_file" | tail -2)

---

EOF
        fi
    done

    cat >> "$summary_file" <<EOF

## Next Steps

1. Review individual server reports in: $REPORT_DIR/
2. Check for any recurring errors
3. Verify timer execution patterns
4. Monitor resource usage trends

---

**Report Location:** $REPORT_DIR/
**For detailed logs, check:** Individual server log files

EOF

    echo -e "${GREEN}✓ Summary report generated: $summary_file${NC}"
}

# =============================================================================
# Main
# =============================================================================

main() {
    local target=${1:-all}

    # Create report directory
    mkdir -p "$REPORT_DIR"

    print_header "NFTBan 24-Hour Stability Monitoring"

    echo "Start Time: $(date)"
    echo "Report Directory: $REPORT_DIR"
    echo ""

    if [[ "$target" == "all" ]]; then
        echo "Monitoring all servers..."
        for server in "${SERVERS[@]}"; do
            check_server "$server"
            echo ""
        done
    else
        echo "Monitoring single server: $target"
        check_server "$target"
    fi

    # Generate summary
    generate_summary

    print_header "Monitoring Complete"

    echo "Reports available in: $REPORT_DIR"
    echo ""
    echo "To view summary:"
    echo "  cat ${REPORT_DIR}/SUMMARY_${TIMESTAMP}.md"
    echo ""
    echo "To set up continuous monitoring (run every hour for 24h):"
    echo "  watch -n 3600 ./scripts/monitor-24h.sh all"
    echo ""
}

# Run main
main "$@"
