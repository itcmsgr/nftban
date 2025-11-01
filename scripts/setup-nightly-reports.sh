#!/usr/bin/env bash
# ==============================================================================
# NFTBan - Setup Nightly Reports with Maximum Logging
# ==============================================================================
# Purpose: Enable comprehensive logging and nightly email reports for testing
# Usage: sudo ./setup-nightly-reports.sh
# ==============================================================================

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}NFTBan - Nightly Reports & Maximum Logging Setup${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}ERROR: This script must be run as root${NC}"
   echo "Usage: sudo $0"
   exit 1
fi

# Detect hostname
HOSTNAME=$(hostname)
echo -e "${GREEN}Configuring: $HOSTNAME${NC}"
echo ""

# ==============================================================================
# 1. ENABLE MAIL NOTIFICATIONS
# ==============================================================================
echo -e "${YELLOW}[1/6] Enabling mail notifications...${NC}"

# Check if mail is already enabled
if nftban mail status 2>/dev/null | grep -q "enabled"; then
    echo "✓ Mail already enabled"
else
    # Enable mail
    sed -i 's/MAIL_ENABLED="false"/MAIL_ENABLED="true"/' /etc/nftban/conf.d/mail.conf
    echo "✓ Mail enabled in config"
fi

# Set email to contact@itcms.gr
sed -i 's|MAIL_RECIPIENT=.*|MAIL_RECIPIENT="contact@itcms.gr"|' /etc/nftban/conf.d/mail.conf
echo "✓ Mail recipient set to: contact@itcms.gr"

# ==============================================================================
# 2. ENABLE THREAT FEEDS
# ==============================================================================
echo ""
echo -e "${YELLOW}[2/6] Enabling threat feeds...${NC}"

# List of feeds to enable
FEEDS=(
    "greensnow"
    "blocklist_de"
    "abuse_ch"
)

for feed in "${FEEDS[@]}"; do
    if nftban feeds list 2>/dev/null | grep -q "^$feed.*enabled"; then
        echo "✓ Feed already enabled: $feed"
    else
        nftban feeds enable "$feed" 2>/dev/null || echo "⚠ Failed to enable: $feed"
        echo "✓ Enabled feed: $feed"
    fi
done

# Update feeds immediately
echo "Updating feeds (this may take a minute)..."
nftban feeds update 2>/dev/null || echo "⚠ Feed update had warnings"
echo "✓ Feeds updated"

# ==============================================================================
# 3. ENABLE GEOIP (if configured)
# ==============================================================================
echo ""
echo -e "${YELLOW}[3/6] Checking GeoIP configuration...${NC}"

# Check if GeoIP license key is set
if grep -q "your_license_key_here" /etc/nftban/conf.d/geoip.conf 2>/dev/null; then
    echo "⚠ GeoIP license key not configured (placeholder detected)"
    echo "  To enable GeoIP:"
    echo "  1. Get MaxMind license key: https://www.maxmind.com/en/geolite2/signup"
    echo "  2. Edit /etc/nftban/conf.d/geoip.conf"
    echo "  3. Run: nftban geoip enable"
else
    # Try to enable GeoIP
    if nftban geoip enable 2>/dev/null; then
        echo "✓ GeoIP enabled"
        nftban geoip update 2>/dev/null || echo "⚠ GeoIP update had warnings"
    else
        echo "⚠ GeoIP not available (not configured or disabled)"
    fi
fi

# ==============================================================================
# 4. ENABLE STATS COLLECTION
# ==============================================================================
echo ""
echo -e "${YELLOW}[4/6] Enabling statistics collection...${NC}"

# Enable stats in config
sed -i 's/STATS_ENABLED="false"/STATS_ENABLED="true"/' /etc/nftban/conf.d/stats.conf 2>/dev/null || true
sed -i 's/STATS_COLLECT="false"/STATS_COLLECT="true"/' /etc/nftban/conf.d/stats.conf 2>/dev/null || true

echo "✓ Statistics collection enabled"

# ==============================================================================
# 5. CREATE NIGHTLY REPORT SCRIPT
# ==============================================================================
echo ""
echo -e "${YELLOW}[5/6] Creating nightly report script...${NC}"

# Create script directory if it doesn't exist
mkdir -p /usr/local/sbin

# Create the nightly report script
cat > /usr/local/sbin/nftban-nightly-report.sh <<'SCRIPT'
#!/usr/bin/env bash
# NFTBan Nightly Report Generator
# Runs at 23:59 daily

set -euo pipefail

HOSTNAME=$(hostname)
DATE=$(date +"%Y-%m-%d")
TIME=$(date +"%H:%M:%S")
REPORT_DIR="/var/lib/nftban/reports"
REPORT_FILE="$REPORT_DIR/nightly-report-$DATE.txt"

# Ensure report directory exists
mkdir -p "$REPORT_DIR"

# Generate comprehensive report
{
    echo "════════════════════════════════════════════════════════════"
    echo "NFTBan Nightly Report - $HOSTNAME"
    echo "Date: $DATE $TIME"
    echo "════════════════════════════════════════════════════════════"
    echo ""

    echo "=== System Information ==="
    echo "Hostname: $HOSTNAME"
    echo "OS: $(cat /etc/redhat-release 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
    echo "Kernel: $(uname -r)"
    echo "NFTBan Version: $(nftban version 2>/dev/null || echo "unknown")"
    echo ""

    echo "=== Health Check ==="
    nftban health check 2>&1 || true
    echo ""

    echo "=== Statistics Summary ==="
    nftban stats --summary 2>&1 || true
    echo ""

    echo "=== Active Bans ==="
    echo "Total permanent bans: $(nft list set inet nftban_main ban_v4 2>/dev/null | grep -c "elements" || echo 0)"
    echo "Total temp bans: $(nft list set inet nftban_runtime temp_ban_v4 2>/dev/null | grep -c "elements" || echo 0)"
    echo ""

    echo "=== Feed Status ==="
    nftban feeds list 2>&1 || true
    echo ""

    echo "=== Fail2ban Jails ==="
    fail2ban-client status 2>&1 | head -20 || echo "fail2ban not running"
    echo ""

    echo "=== Recent Log Entries (Last 24h) ==="
    echo "--- NFTBan Main Log ---"
    tail -50 /var/log/nftban/nftban.log 2>/dev/null || echo "No main log"
    echo ""
    echo "--- Audit Log ---"
    tail -20 /var/lib/nftban/audit/permissions.log 2>/dev/null || echo "No audit log"
    echo ""

    echo "=== System Resources ==="
    echo "Memory:"
    free -h
    echo ""
    echo "Disk:"
    df -h / /var | grep -v "Filesystem"
    echo ""

    echo "=== Nftables Rules Count ==="
    nft list ruleset 2>/dev/null | wc -l
    echo ""

    echo "════════════════════════════════════════════════════════════"
    echo "Report generated: $(date)"
    echo "════════════════════════════════════════════════════════════"

} > "$REPORT_FILE"

# Email the report if mail is enabled
if command -v mail >/dev/null 2>&1; then
    if grep -q 'MAIL_ENABLED="true"' /etc/nftban/conf.d/mail.conf 2>/dev/null; then
        RECIPIENT=$(grep "MAIL_RECIPIENT=" /etc/nftban/conf.d/mail.conf | cut -d'"' -f2)
        mail -s "NFTBan Nightly Report - $HOSTNAME - $DATE" "$RECIPIENT" < "$REPORT_FILE" 2>&1 || \
            echo "Failed to send email" >> "$REPORT_FILE"
    fi
fi

# Keep only last 30 days of reports
find "$REPORT_DIR" -name "nightly-report-*.txt" -mtime +30 -delete 2>/dev/null || true

exit 0
SCRIPT

chmod +x /usr/local/sbin/nftban-nightly-report.sh
echo "✓ Nightly report script created: /usr/local/sbin/nftban-nightly-report.sh"

# ==============================================================================
# 6. CREATE CRON JOB FOR 23:59 DAILY
# ==============================================================================
echo ""
echo -e "${YELLOW}[6/6] Setting up cron job for 23:59...${NC}"

# Remove any existing nftban nightly report cron jobs
crontab -l 2>/dev/null | grep -v "nftban-nightly-report" > /tmp/crontab.tmp || true

# Add new cron job at 23:59
echo "59 23 * * * /usr/local/sbin/nftban-nightly-report.sh >/dev/null 2>&1" >> /tmp/crontab.tmp

# Install new crontab
crontab /tmp/crontab.tmp
rm /tmp/crontab.tmp

echo "✓ Cron job installed: Daily at 23:59"
echo "  Command: /usr/local/sbin/nftban-nightly-report.sh"

# ==============================================================================
# SUMMARY
# ==============================================================================
echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Setup Complete!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo ""
echo "Configuration Summary:"
echo "  📧 Email recipient: contact@itcms.gr"
echo "  ⏰ Report schedule: Daily at 23:59"
echo "  📊 Threat feeds enabled: ${FEEDS[*]}"
echo "  📈 Statistics collection: ENABLED"
echo "  🗂️  Report location: /var/lib/nftban/reports/"
echo ""
echo "Testing:"
echo "  Run manual report: sudo /usr/local/sbin/nftban-nightly-report.sh"
echo "  View last report:  cat /var/lib/nftban/reports/nightly-report-*.txt | tail -100"
echo "  Check cron:        crontab -l | grep nftban"
echo ""
echo "Monitoring:"
echo "  tail -f /var/log/nftban/nftban.log"
echo "  tail -f /var/lib/nftban/audit/permissions.log"
echo ""
echo -e "${BLUE}First report will be sent tonight at 23:59!${NC}"
echo ""
