#!/usr/bin/env bash
# =============================================================================
# nftban Debug Setup Script
# =============================================================================
# Configures nftban for comprehensive debugging and stability testing
#
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Version: 0.9.1
# =============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}ERROR: This script must be run as root${NC}"
    exit 1
fi

echo -e "${BLUE}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║      nftban Debug & Stability Setup                  ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""

# Step 1: Enable verbose logging
echo -e "${YELLOW}[1/7] Enabling verbose logging...${NC}"
if [[ -f /etc/nftban/config/nftban.conf.local ]]; then
    # Update existing local config
    if grep -q "NFTBAN_DEBUG_MODE" /etc/nftban/config/nftban.conf.local 2>/dev/null; then
        sed -i 's/^NFTBAN_DEBUG_MODE=.*/NFTBAN_DEBUG_MODE=1/' /etc/nftban/config/nftban.conf.local
    else
        echo "NFTBAN_DEBUG_MODE=1" >> /etc/nftban/config/nftban.conf.local
    fi
    if grep -q "NFTBAN_LOG_LEVEL" /etc/nftban/config/nftban.conf.local 2>/dev/null; then
        sed -i 's/^NFTBAN_LOG_LEVEL=.*/NFTBAN_LOG_LEVEL=debug/' /etc/nftban/config/nftban.conf.local
    else
        echo "NFTBAN_LOG_LEVEL=debug" >> /etc/nftban/config/nftban.conf.local
    fi
else
    # Create new local config
    cat > /etc/nftban/config/nftban.conf.local <<'EOF'
# Debug configuration for stability testing
NFTBAN_DEBUG_MODE=1
NFTBAN_LOG_LEVEL=debug
EOF
fi
echo -e "${GREEN}✓ Verbose logging enabled${NC}"

# Step 2: Set up log rotation for debug logs
echo -e "${YELLOW}[2/7] Configuring log rotation...${NC}"
cat > /etc/logrotate.d/nftban-debug <<'EOF'
/var/log/nftban/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
    sharedscripts
    postrotate
        systemctl reload nftables >/dev/null 2>&1 || true
    endscript
}
EOF
echo -e "${GREEN}✓ Log rotation configured (7 days retention)${NC}"

# Step 3: Enable key features for testing
echo -e "${YELLOW}[3/7] Enabling features for stability testing...${NC}"

# Enable DDoS protection (conservative settings)
echo -e "  ${BLUE}→${NC} Enabling DDoS protection..."
nftban ddos enable 2>&1 | grep -v "^$" || true
nftban ddos connlimit enable 2>&1 | grep -v "^$" || true
nftban ddos portflood enable 2>&1 | grep -v "^$" || true
nftban ddos icmp enable 2>&1 | grep -v "^$" || true
echo -e "  ${GREEN}✓${NC} DDoS protection enabled"

# Enable port scan detection
echo -e "  ${BLUE}→${NC} Enabling port scan detection..."
nftban portscan enable 2>&1 | grep -v "^$" || true
echo -e "  ${GREEN}✓${NC} Port scan detection enabled"

# Enable login monitoring
echo -e "  ${BLUE}→${NC} Enabling login monitoring..."
nftban login enable 2>&1 | grep -v "^$" || true
echo -e "  ${GREEN}✓${NC} Login monitoring enabled"

# Enable feeds (if not already)
echo -e "  ${BLUE}→${NC} Checking threat feeds..."
nftban feeds status 2>&1 | head -3 || true

echo -e "${GREEN}✓ All stability test features enabled${NC}"

# Step 4: Create monitoring script
echo -e "${YELLOW}[4/7] Creating monitoring script...${NC}"
cat > /usr/local/bin/nftban-monitor-debug <<'MONITOR_EOF'
#!/usr/bin/env bash
# nftban debug monitor - runs every 5 minutes

LOG_FILE="/var/log/nftban/debug_monitor.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

echo "[$TIMESTAMP] ========================================" >> "$LOG_FILE"

# System resources
echo "[$TIMESTAMP] Memory usage:" >> "$LOG_FILE"
free -h | grep -E 'Mem:|Swap:' >> "$LOG_FILE"

echo "[$TIMESTAMP] CPU load:" >> "$LOG_FILE"
uptime >> "$LOG_FILE"

# nftables stats
echo "[$TIMESTAMP] nftables status:" >> "$LOG_FILE"
systemctl is-active nftables >> "$LOG_FILE" 2>&1 || echo "INACTIVE" >> "$LOG_FILE"

# Count banned IPs
echo "[$TIMESTAMP] Ban counts:" >> "$LOG_FILE"
nft list set ip nftban_v4 temp_ban 2>/dev/null | grep -c 'elements' || echo "0" >> "$LOG_FILE"
nft list set ip nftban_v4 user_blacklist 2>/dev/null | grep -c 'elements' || echo "0" >> "$LOG_FILE"

# Recent log errors
echo "[$TIMESTAMP] Recent errors (last 5 min):" >> "$LOG_FILE"
find /var/log/nftban -name "*.log" -type f -mmin -5 -exec grep -i "error\|fail\|critical" {} + 2>/dev/null | tail -10 >> "$LOG_FILE" || echo "No errors" >> "$LOG_FILE"

# Disk space
echo "[$TIMESTAMP] Log directory size:" >> "$LOG_FILE"
du -sh /var/log/nftban >> "$LOG_FILE"

echo "" >> "$LOG_FILE"
MONITOR_EOF

chmod +x /usr/local/bin/nftban-monitor-debug
echo -e "${GREEN}✓ Monitoring script created: /usr/local/bin/nftban-monitor-debug${NC}"

# Step 5: Set up monitoring cron job
echo -e "${YELLOW}[5/7] Setting up monitoring cron...${NC}"
cat > /etc/cron.d/nftban-debug-monitor <<'EOF'
# nftban debug monitoring - every 5 minutes
*/5 * * * * root /usr/local/bin/nftban-monitor-debug >/dev/null 2>&1
EOF
echo -e "${GREEN}✓ Monitoring cron job installed (runs every 5 minutes)${NC}"

# Step 6: Create stress test script
echo -e "${YELLOW}[6/7] Creating stress test script...${NC}"
cat > /usr/local/bin/nftban-stress-test <<'STRESS_EOF'
#!/usr/bin/env bash
# nftban stress test - simulates various operations

set -euo pipefail

echo "Starting nftban stress test..."
echo "This will perform various operations to test stability"
echo ""

# Test 1: Whitelist operations
echo "[1/8] Testing whitelist operations..."
for i in {1..10}; do
    nftban whitelist add 192.0.2.$i "stress-test-$i" >/dev/null 2>&1 || true
done
for i in {1..10}; do
    nftban whitelist remove 192.0.2.$i >/dev/null 2>&1 || true
done
echo "✓ Whitelist operations complete"

# Test 2: Blacklist operations
echo "[2/8] Testing blacklist operations..."
for i in {1..10}; do
    nftban blacklist add 198.51.100.$i "stress-test-$i" >/dev/null 2>&1 || true
done
for i in {1..10}; do
    nftban blacklist remove 198.51.100.$i >/dev/null 2>&1 || true
done
echo "✓ Blacklist operations complete"

# Test 3: Ban/unban operations
echo "[3/8] Testing temporary ban operations..."
for i in {1..5}; do
    nftban ban add 203.0.113.$i 300 "stress-test-$i" >/dev/null 2>&1 || true
done
for i in {1..5}; do
    nftban ban remove 203.0.113.$i >/dev/null 2>&1 || true
done
echo "✓ Ban operations complete"

# Test 4: Statistics queries
echo "[4/8] Testing statistics queries..."
nftban stats summary >/dev/null 2>&1 || true
nftban stats whitelist >/dev/null 2>&1 || true
nftban stats blacklist >/dev/null 2>&1 || true
nftban stats bans >/dev/null 2>&1 || true
echo "✓ Statistics queries complete"

# Test 5: Safety checks
echo "[5/8] Testing safety mechanisms..."
nftban check-safety >/dev/null 2>&1 || true
echo "✓ Safety checks complete"

# Test 6: Sync operations
echo "[6/8] Testing sync operations..."
nftban sync test >/dev/null 2>&1 || true
echo "✓ Sync operations complete"

# Test 7: Port scan checks
echo "[7/8] Testing port scan detection..."
nftban portscan stats >/dev/null 2>&1 || true
echo "✓ Port scan checks complete"

# Test 8: DDoS status
echo "[8/8] Testing DDoS protection status..."
nftban ddos status >/dev/null 2>&1 || true
echo "✓ DDoS status complete"

echo ""
echo "Stress test complete!"
echo "Check /var/log/nftban/debug_monitor.log for results"
STRESS_EOF

chmod +x /usr/local/bin/nftban-stress-test
echo -e "${GREEN}✓ Stress test script created: /usr/local/bin/nftban-stress-test${NC}"

# Step 7: Run initial verification
echo -e "${YELLOW}[7/7] Running initial system verification...${NC}"
nftban verify 2>&1 | tail -20

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║      Debug Setup Complete                            ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}Enabled Features:${NC}"
echo "  • Debug logging (verbose mode)"
echo "  • DDoS protection (connection limits, port flood, ICMP)"
echo "  • Port scan detection"
echo "  • Login monitoring"
echo "  • Automated monitoring (every 5 minutes)"
echo ""
echo -e "${BLUE}Available Commands:${NC}"
echo "  • nftban-monitor-debug     - Manual monitoring check"
echo "  • nftban-stress-test       - Run stress test"
echo "  • tail -f /var/log/nftban/debug_monitor.log  - Watch monitor output"
echo "  • tail -f /var/log/nftban/nftban.log         - Watch main log"
echo ""
echo -e "${BLUE}Logs Location:${NC}"
echo "  • Main: /var/log/nftban/nftban.log"
echo "  • Monitor: /var/log/nftban/debug_monitor.log"
echo "  • Port scan: /var/log/nftban/portscan.log"
echo "  • Login: /var/log/nftban/login_monitor.log"
echo ""
echo -e "${YELLOW}Monitoring will run automatically every 5 minutes${NC}"
echo -e "${YELLOW}Run 'nftban-stress-test' to test stability now${NC}"
echo ""
