# NFTBan v0.10.0 - Stats & Report System - Deployment Guide

**Date:** 2025-10-29
**Version:** 0.10.0
**Status:** ✅ READY FOR DEPLOYMENT

---

## 🎯 OVERVIEW

Complete statistics and reporting system for NFTBan with:
- Real-time dashboard
- Beautiful HTML reports with Chart.js
- Automated daily email reports
- Comprehensive metrics and analytics

---

## 📦 WHAT WAS CREATED

### Configuration Files
- `/etc/nftban/conf.d/stats.conf` - Statistics configuration (350+ lines, 100+ options)

### Core Modules
- `/usr/lib/nftban/core/nftban_stats.sh` - Stats engine (700+ lines, 21 functions)

### CLI Commands
- `/usr/lib/nftban/cli/cmd_stats.sh` - Stats CLI (600+ lines)
- `/usr/lib/nftban/cli/cmd_report.sh` - Report CLI (550+ lines)

### HTML Templates
- `/usr/share/nftban/templates/reports/stats_dashboard.html` - Dashboard with Chart.js
- `/usr/share/nftban/templates/mail/stats_email.html` - Email template

### Updated Files
- `/usr/sbin/nftban` - Main CLI (routing + completion updated)
- `/usr/lib/nftban/core/nftban_report_fhs.sh` - FHS permissions updated

### Directories
- `/var/lib/nftban/metrics/` - Stats database
- `/var/lib/nftban/snapshots/` - Hourly snapshots
- `/var/lib/nftban/reports/{daily,weekly,monthly}/` - Generated reports
- `/var/cache/nftban/stats/` - Cache (5min TTL)
- `/var/log/nftban/stats.log` - Stats log
- `/var/log/nftban/cron.log` - Cron job log

---

## 🚀 DEPLOYMENT

### Quick Deployment (Automated)

```bash
cd /home/gituser/nftban-v0.10.0-dev
./deploy_stats_to_labs.sh
```

This will:
1. ✅ Deploy all files to lab, lab1, lab2
2. ✅ Create required directories
3. ✅ Set proper permissions
4. ✅ Configure daily report to contact@nftban.com at 23:59
5. ✅ Create cron jobs
6. ✅ Verify installation

### Manual Deployment (Step by Step)

For each server (server1.example.com, server2.example.com, server3.example.com):

```bash
SERVER="server1.example.com"

# 1. Copy files
scp src/etc/nftban/conf.d/stats.conf root@$SERVER:/etc/nftban/conf.d/
scp src/usr/lib/nftban/core/nftban_stats.sh root@$SERVER:/usr/lib/nftban/core/
scp src/usr/lib/nftban/cli/cmd_stats.sh root@$SERVER:/usr/lib/nftban/cli/
scp src/usr/lib/nftban/cli/cmd_report.sh root@$SERVER:/usr/lib/nftban/cli/
scp src/usr/share/nftban/templates/reports/stats_dashboard.html root@$SERVER:/usr/share/nftban/templates/reports/
scp src/usr/share/nftban/templates/mail/stats_email.html root@$SERVER:/usr/share/nftban/templates/mail/
scp src/usr/sbin/nftban root@$SERVER:/usr/sbin/

# 2. Create directories
ssh root@$SERVER << 'EOF'
mkdir -p /var/lib/nftban/{metrics,snapshots,reports/{daily,weekly,monthly}}
mkdir -p /var/cache/nftban/stats
touch /var/log/nftban/{stats.log,cron.log}

# Set ownership
chown -R nftban:nftban /var/lib/nftban/metrics
chown -R nftban:nftban /var/lib/nftban/snapshots
chown -R nftban:nftban /var/lib/nftban/reports
chown -R nftban:nftban /var/cache/nftban/stats
chown nftban:nftban /var/log/nftban/stats.log
chown nftban:nftban /var/log/nftban/cron.log

# Set permissions
chmod 750 /var/lib/nftban/metrics
chmod 750 /var/lib/nftban/snapshots
chmod 750 /var/lib/nftban/reports
chmod 755 /var/cache/nftban/stats
chmod 640 /var/log/nftban/stats.log
chmod 640 /var/log/nftban/cron.log
EOF

# 3. Configure email in stats.conf
ssh root@$SERVER "sed -i 's/^STATS_EMAIL_RECIPIENTS=.*/STATS_EMAIL_RECIPIENTS=\"contact@nftban.com\"/' /etc/nftban/conf.d/stats.conf"

# 4. Create cron job
ssh root@$SERVER "cat > /etc/cron.d/nftban-stats" << 'EOF'
# NFTBan Statistics - Automated Reports
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Daily report at 23:59 to contact@nftban.com
59 23 * * * root /usr/sbin/nftban report run daily >> /var/log/nftban/cron.log 2>&1

# Hourly snapshot
0 * * * * root /usr/sbin/nftban stats snapshot >> /var/log/nftban/cron.log 2>&1

# Daily cleanup (03:00 AM)
0 3 * * * root /usr/sbin/nftban stats cleanup >> /var/log/nftban/cron.log 2>&1
EOF

# 5. Verify
ssh root@$SERVER "nftban stats help && nftban report help"
```

---

## 📊 USAGE EXAMPLES

### Stats Dashboard

```bash
# Show dashboard (last 24 hours)
nftban stats

# Show dashboard for last 7 days
nftban stats --last 7d

# Show dashboard for last 30 days
nftban stats --last 30d

# Custom date range
nftban stats --since 2025-10-01 --until 2025-10-29
```

### Top Lists

```bash
# Top 20 banned IPs
nftban stats top ips 20

# Top 10 countries (requires GeoIP)
nftban stats top countries 10

# Top 5 Fail2Ban jails
nftban stats top jails 5
```

### IP Intelligence

```bash
# Show full ban history for IP
nftban stats ip 192.0.2.100

# Detailed history
nftban stats ip 192.0.2.100 --detailed
```

### Recent Activity

```bash
# Last 50 ban events
nftban stats recent 50

# Follow ban log in real-time (tail -f mode)
nftban stats recent --follow
```

### Real-time Monitoring

```bash
# Auto-refresh dashboard every 5 seconds
nftban stats monitor

# Custom refresh interval (10 seconds)
nftban stats monitor --interval 10
```

### Export Statistics

```bash
# Export to JSON
nftban stats export --format json --output /tmp/stats.json

# Export to CSV
nftban stats export --format csv --output /tmp/stats.csv

# Export last 30 days
nftban stats export --format json --last 30d
```

### Generate Reports

```bash
# Generate HTML report
nftban report generate --format html

# Generate all formats (HTML, JSON, CSV)
nftban report generate --format all

# Generate report for last 7 days
nftban report generate --format html --last 7d

# Custom date range
nftban report generate --format html --since 2025-10-01 --until 2025-10-31
```

### Email Reports

```bash
# Email report to admin
nftban report email admin@example.com

# Email with CSV attachment
nftban report email admin@example.com --attach-csv

# Email report for last 7 days
nftban report email admin@example.com --last 7d
```

### Scheduled Reports

```bash
# Schedule daily report at 08:00
nftban report schedule daily --time "08:00"

# Schedule weekly report (Monday 09:00)
nftban report schedule weekly --day Monday --time "09:00"

# Schedule monthly report (1st of month, 10:00)
nftban report schedule monthly --day 1 --time "10:00"

# List scheduled reports
nftban report schedule list

# Manually trigger daily report
nftban report run daily
```

### Maintenance

```bash
# Create hourly snapshot
nftban stats snapshot

# Cleanup logs older than 90 days
nftban stats cleanup --days 90

# Clear statistics cache
nftban stats clear-cache

# Check for threshold alerts
nftban stats check-alerts
```

---

## 📧 DAILY EMAIL REPORT

### Configuration

The daily report is automatically sent to **contact@nftban.com** at **23:59** every day.

Configuration in `/etc/nftban/conf.d/stats.conf`:

```bash
# Email settings
STATS_EMAIL_ENABLED="true"
STATS_EMAIL_RECIPIENTS="contact@nftban.com"
STATS_EMAIL_FORMAT="html"
STATS_EMAIL_ATTACH_CSV="true"

# Daily report schedule
STATS_DAILY_REPORT_ENABLED="true"
STATS_DAILY_REPORT_TIME="23:59"
STATS_DAILY_REPORT_FORMAT="html"
STATS_DAILY_REPORT_EMAIL="true"
```

### Email Content

The daily email includes:

1. **Executive Summary**
   - Server hostname
   - Report period (full day 00:00 - 23:59)
   - Total bans, unique IPs, active bans, whitelist

2. **Alerts** (if any)
   - High ban rate warnings
   - Repeat offenders detected

3. **Top 5 Banned IPs**
   - IP address with country
   - Ban count

4. **Top 5 Countries** (if GeoIP enabled)
   - Country name
   - Ban count

5. **Top 5 Fail2Ban Jails**
   - Jail name (e.g., fail2ban-sshd)
   - Ban count

6. **Recommendations** (if any)
   - IPs to permanently ban
   - Security suggestions

7. **Attachments** (optional)
   - CSV export with all ban data

### Testing Email

```bash
# Manually trigger daily report now
nftban report run daily

# Or email directly to test
nftban report email contact@nftban.com --last 1d
```

---

## 🔍 VERIFICATION

### Check Installation

```bash
# Test commands
nftban stats help
nftban report help

# Check files exist
ls -lh /etc/nftban/conf.d/stats.conf
ls -lh /usr/lib/nftban/core/nftban_stats.sh
ls -lh /usr/lib/nftban/cli/cmd_{stats,report}.sh
ls -lh /usr/share/nftban/templates/reports/stats_dashboard.html

# Check directories
ls -ld /var/lib/nftban/{metrics,snapshots,reports}
ls -ld /var/cache/nftban/stats

# Check cron
cat /etc/cron.d/nftban-stats
crontab -l
```

### Test Stats Collection

```bash
# Generate quick dashboard
nftban stats

# Should show:
# - Total bans
# - Unique IPs
# - Active bans
# - Top jails
# - Top IPs
```

### Test Report Generation

```bash
# Generate test report
nftban report generate --format html --output /tmp/test-report.html

# Check file was created
ls -lh /tmp/test-report.html

# View in browser (if GUI available)
firefox /tmp/test-report.html
```

### Test Email Delivery

```bash
# Send test email
nftban report email contact@nftban.com --last 1d

# Check mail logs
tail -f /var/log/nftban/email.log
tail -f /var/log/maillog
```

### Monitor Cron Jobs

```bash
# Watch cron log
tail -f /var/log/nftban/cron.log

# Check cron is running
systemctl status crond

# Verify cron file
cat /etc/cron.d/nftban-stats
```

---

## 🐛 TROUBLESHOOTING

### Stats Dashboard Shows No Data

**Problem:** `nftban stats` shows zeros
**Solution:**
```bash
# Check ban log exists
ls -lh /var/log/nftban/ban.log

# Check if there are any bans
wc -l /var/log/nftban/ban.log

# If empty, no bans recorded yet - this is normal
```

### Email Not Sending

**Problem:** Daily report not arriving at contact@nftban.com
**Solution:**
```bash
# Check mail system
nftban mail test

# Check SMTP configuration
cat /etc/nftban/conf.d/mail.conf | grep -v '^#'

# Check cron is running
systemctl status crond

# Check cron log for errors
tail -100 /var/log/nftban/cron.log

# Manually trigger to see errors
/usr/sbin/nftban report run daily
```

### Permission Denied Errors

**Problem:** Cannot write to directories
**Solution:**
```bash
# Fix permissions
chown -R nftban:nftban /var/lib/nftban/{metrics,snapshots,reports}
chown -R nftban:nftban /var/cache/nftban/stats
chmod 750 /var/lib/nftban/{metrics,snapshots,reports}
chmod 755 /var/cache/nftban/stats
```

### Command Not Found

**Problem:** `nftban stats` or `nftban report` not recognized
**Solution:**
```bash
# Check main CLI
ls -l /usr/sbin/nftban

# Check CLI modules
ls -l /usr/lib/nftban/cli/cmd_{stats,report}.sh

# Test sourcing directly
source /usr/lib/nftban/cli/cmd_stats.sh
nftban_cmd_stats help
```

### Charts Not Showing in HTML Report

**Problem:** HTML report generated but charts are blank
**Solution:**
```bash
# Check template exists
ls -l /usr/share/nftban/templates/reports/stats_dashboard.html

# Check internet connectivity (Chart.js loaded from CDN)
curl -I https://cdn.jsdelivr.net/npm/chart.js

# View browser console for JavaScript errors
```

---

## 📈 MONITORING

### Check Stats System Health

```bash
# Dashboard (quick overview)
nftban stats

# Check alerts
nftban stats check-alerts

# View recent activity
nftban stats recent 20

# Cache status
ls -lh /var/cache/nftban/stats/
```

### Monitor Disk Usage

```bash
# Check stats data size
du -sh /var/lib/nftban/metrics
du -sh /var/lib/nftban/snapshots
du -sh /var/lib/nftban/reports

# Check logs
du -sh /var/log/nftban/*.log

# Cleanup if needed
nftban stats cleanup --days 60
```

### Performance Monitoring

```bash
# Test report generation time
time nftban report generate --format html --output /tmp/perf-test.html

# Should complete in < 5 seconds for 10k events

# Check cache effectiveness
ls -lh /var/cache/nftban/stats/

# Clear cache and compare
nftban stats clear-cache
time nftban stats  # First run (no cache)
time nftban stats  # Second run (cached)
```

---

## 🎯 KEY FEATURES

### ✅ Real-time Dashboard
- Comprehensive terminal dashboard
- Auto-refresh monitor mode
- Time-window filtering (24h, 7d, 30d, custom)

### ✅ HTML Reports with Chart.js
- Interactive charts (timeline, pie, bar)
- Dark/light theme toggle
- Responsive design (mobile-friendly)
- Print-friendly

### ✅ Email Automation
- Daily/weekly/monthly reports
- HTML email with inline images
- CSV attachments
- Customizable schedule

### ✅ Advanced Analytics
- Top banned IPs with GeoIP
- Country-based analysis
- Jail effectiveness tracking
- Repeat offender detection
- Attack pattern analysis

### ✅ Multiple Export Formats
- JSON (for APIs/processing)
- CSV (for spreadsheets)
- HTML (for viewing/sharing)

### ✅ Performance Optimized
- 5-minute cache TTL
- Handles 100k+ events efficiently
- Parallel processing
- Automatic log rotation

### ✅ FHS Compliant
- Proper directory structure
- Correct permissions (nftban:nftban)
- Standard log locations

---

## 📞 SUPPORT

**Email:** contact@nftban.com
**Website:** https://nftban.com
**NFTBan:** https://nftban.com

---

## 📝 CHANGELOG

### v0.10.0 (2025-10-29)
- ✅ Initial stats & metrics system
- ✅ Real-time dashboard
- ✅ HTML reports with Chart.js
- ✅ Email automation
- ✅ Cron scheduling
- ✅ Daily reports to contact@nftban.com at 23:59
- ✅ 21 core functions
- ✅ ~2,200 lines of code

---

**🚀 Ready for Production!**
