# NFTBan Statistics Module

**File:** `lib/nftban_stats_module.sh`  
**Version:** 1.0.0  
**Author:** ITCMS Team (Antonios Voulvoulis)  
**Purpose:** Statistics collection, reporting, monitoring, and analysis

---

## Overview

The Statistics Module provides comprehensive monitoring, reporting, and analysis capabilities for NFTBan operations. It collects data from all NFTBan components to generate detailed reports on ban activity, whitelist/blacklist usage, GEO blocking effectiveness, and system health.

This module serves as the central dashboard for understanding NFTBan's security posture, tracking attack patterns, identifying repeat offenders, and generating compliance reports. It provides both real-time monitoring and historical analysis capabilities.

Key features include unified dashboard showing all NFTBan components at a glance, detailed IP history tracking (when/why an IP was banned), top offenders list (most frequently banned IPs), ban activity trends and patterns, export capabilities (CSV for spreadsheets, TXT reports for auditing), real-time monitoring mode with auto-refresh, and automatic log rotation and cleanup.

The module aggregates data from multiple sources: whitelist files (system, user, Cloudflare), blacklist files (persistent, user), ban logs (all ban/unban activity), GEO blocking configuration and nftables sets, Cloudflare integration status and cache, and nftables set statistics (element counts).

---

## Key Functions

### Public Functions (Exported)

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `nftban_stats_dashboard()` | Show comprehensive dashboard | None | Display formatted dashboard |
| `nftban_stats_ip_history()` | Show ban history for IP | `$1` - IP address | Display history |
| `nftban_stats_top_banned()` | List most banned IPs | `$1` - limit (default: 10) | Display top list |
| `nftban_stats_recent()` | Show recent activity | `$1` - limit (default: 20) | Display recent events |
| `nftban_stats_export_csv()` | Export to CSV file | `$1` - output file (optional) | CSV file path |
| `nftban_stats_generate_report()` | Generate comprehensive report | `$1` - output file (optional) | Report file path |
| `nftban_stats_monitor()` | Real-time monitoring mode | None | Interactive (Ctrl+C to exit) |
| `nftban_stats_cleanup_logs()` | Cleanup and rotate old logs | `$1` - days to keep (default: 30) | 0 on success |

### Internal Functions (Private)

| Function | Purpose | Notes |
|----------|---------|-------|
| `nftban_stats_whitelist_summary()` | Summarize whitelist statistics | System, user, Cloudflare counts |
| `nftban_stats_blacklist_summary()` | Summarize blacklist statistics | Persistent and user counts |
| `nftban_stats_ban_activity()` | Summarize ban activity | From ban log |
| `nftban_stats_geo_summary()` | Summarize GEO blocking | Blocked countries count |
| `nftban_stats_cloudflare_summary()` | Summarize Cloudflare status | Cache age, range counts |
| `nftban_stats_nftables_summary()` | Summarize nftables sets | Element counts per set |

---

## Configuration Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NFTBAN_STATS_DB` | `${NFTBAN_DATA_DIR}/stats.db` | Statistics database (future use) |
| `NFTBAN_STATS_CACHE` | `${NFTBAN_CACHE_DIR}/stats-cache.json` | Cached statistics (future use) |

### Data Sources (Read-Only)

| File | Purpose |
|------|---------|
| `$NFTBAN_WHITELIST_SYSTEM` | System whitelist entries |
| `$NFTBAN_WHITELIST_USER` | User whitelist entries |
| `$NFTBAN_WHITELIST_CF` | Cloudflare whitelist entries |
| `$NFTBAN_BLACKLIST_PERSISTENT` | Persistent blacklist entries |
| `$NFTBAN_BLACKLIST_USER` | User blacklist entries |
| `$NFTBAN_BAN_LOG` | All ban/unban activity |
| `$NFTBAN_GEO_BLACKLIST` | GEO blacklist configuration |
| `$NFTBAN_CF_IPV4_CACHE` | Cloudflare IPv4 cache |
| `$NFTBAN_CF_IPV6_CACHE` | Cloudflare IPv6 cache |

---

## Dependencies

**Required Modules:**
- `nftban_core.sh` - Core logging and utilities
- `nftban_nftables_module.sh` - nftables queries

**External Commands:**
- `awk` - Text processing (required)
- `grep` - Pattern matching (required)
- `sort`, `uniq` - Data aggregation (required)
- `wc` - Counting (required)
- `gzip` - Log compression (recommended)
- `date` - Timestamp formatting (required)

---

## Usage Examples

### Example 1: View Dashboard (Quick Overview)
```bash
nftban stats dashboard

# Expected output:
# ╔══════════════════════════════════════════════╗
# ║         NFTBan Statistics Dashboard          ║
# ╚══════════════════════════════════════════════╝
#
# [SYSTEM]
#   Hostname: web-server-01
#   Date: 2025-10-20 14:32:15
#
# [WHITELIST]
#   System: 45
#   User: 12
#   Cloudflare: 23
#   ──────────────
#   Total: 80
#
# [BLACKLIST]
#   Persistent: 234
#   User: 67
#   ──────────────
#   Total: 301
#
# [BAN ACTIVITY]
#   Total events: 1,523
#
#   Breakdown by action:
#     BANNED               847
#     UNBANNED             432
#     WHITELISTED          189
#     PERMANENT_BAN         55
#
#   Top 5 banned IPs:
#     192.0.2.100            23 times
#     198.51.100.50          18 times
#     203.0.113.75           15 times
#     45.67.89.10            12 times
#     123.45.67.89           11 times
#
#   Recent activity (last 5):
#     2025-10-20 14:30:15 | 192.0.2.100 | BANNED
#     2025-10-20 14:28:42 | 198.51.100.50 | UNBANNED
#     2025-10-20 14:25:10 | 203.0.113.75 | BANNED
#     2025-10-20 14:20:33 | 192.0.2.100 | UNBANNED
#     2025-10-20 14:15:22 | 45.67.89.10 | BANNED
#
# [GEO BLOCKING]
#   Blocked countries: 3
#   Countries:
#     - CN
#     - RU
#     - KP
#   Active nftables sets: 6
#
# [CLOUDFLARE]
#   Status: true
#   IPv4 ranges: 14
#   IPv6 ranges: 9
#   Cache age: 3h
#
# [NFTABLES]
#   Table: nftban
#
#   Sets:
#     whitelist                 80 elements
#     temp_ban                  23 elements
#     user_blacklist            67 elements
#     system_blacklist         234 elements
#     feeds                    156 elements
```

### Example 2: Check IP History (Forensics)
```bash
nftban stats ip-history 192.0.2.100

# Expected output:
# === Ban History for 192.0.2.100 ===
#
# Total events: 8
#
# [BANNED] 2025-10-20 14:30:15
#   Jail: fail2ban-sshd
#   Reason: SSH brute force
#
# [UNBANNED] 2025-10-20 14:20:33
#   Jail: fail2ban-sshd
#   Reason: Ban expired (1 hour)
#
# [BANNED] 2025-10-20 13:15:42
#   Jail: fail2ban-sshd
#   Reason: SSH brute force
#
# [UNBANNED] 2025-10-20 12:15:42
#   Jail: fail2ban-sshd
#   Reason: Ban expired (1 hour)
#
# [BANNED] 2025-10-20 10:42:18
#   Jail: fail2ban-nginx
#   Reason: Rate limit exceeded
#
# [WHITELISTED] 2025-10-19 09:15:00
#   Jail: manual
#   Reason: Temporary whitelist for testing
#
# [PERMANENT_BAN] 2025-10-15 16:30:00
#   Jail: manual
#   Reason: Repeat offender - escalated
#
# [BANNED] 2025-10-15 10:20:15
#   Jail: fail2ban-sshd
#   Reason: SSH brute force
#
# Summary:
#   BANNED            4
#   UNBANNED          2
#   WHITELISTED       1
#   PERMANENT_BAN     1
```

### Example 3: Top Offenders (Security Analysis)
```bash
nftban stats top-banned 20

# Expected output:
# === Top 20 Banned IPs ===
#
#   1. 192.0.2.100          23 bans
#   2. 198.51.100.50        18 bans
#   3. 203.0.113.75         15 bans
#   4. 45.67.89.10          12 bans
#   5. 123.45.67.89         11 bans
#   6. 185.220.101.10        9 bans
#   7. 104.244.76.50         8 bans
#   8. 66.240.205.34         7 bans
#   9. 23.129.64.100         7 bans
#  10. 91.121.109.55         6 bans
#  11. 162.247.74.200        6 bans
#  12. 195.154.133.20        5 bans
#  13. 51.254.186.20         5 bans
#  14. 188.165.240.110       4 bans
#  15. 178.32.248.145        4 bans
#  16. 217.182.65.85         3 bans
#  17. 95.216.96.40          3 bans
#  18. 159.89.220.70         3 bans
#  19. 134.122.36.10         2 bans
#  20. 167.71.142.50         2 bans
```

### Example 4: Recent Activity (Monitoring)
```bash
nftban stats recent 30

# Expected output:
# === Recent Activity (last 30) ===
#
# 2025-10-20 14:30:15 | 192.0.2.100      | BANNED          | fail2ban-sshd
# 2025-10-20 14:28:42 | 198.51.100.50    | UNBANNED        | fail2ban-sshd
# 2025-10-20 14:25:10 | 203.0.113.75     | BANNED          | fail2ban-nginx
# 2025-10-20 14:20:33 | 192.0.2.100      | UNBANNED        | fail2ban-sshd
# 2025-10-20 14:15:22 | 45.67.89.10      | BANNED          | fail2ban-sshd
# 2025-10-20 14:12:05 | 123.45.67.89     | WHITELISTED     | manual
# 2025-10-20 14:10:47 | 185.220.101.10   | BANNED          | fail2ban-sshd
# 2025-10-20 14:08:20 | 104.244.76.50    | PERMANENT_BAN   | manual
# ... (22 more entries)
```

### Example 5: Export to CSV (Spreadsheet Analysis)
```bash
nftban stats export-csv /tmp/nftban-data.csv

# Expected output:
# [INFO] Exporting statistics to CSV: /tmp/nftban-data.csv
# [SUCCESS] Exported 1,523 records to /tmp/nftban-data.csv
# /tmp/nftban-data.csv

# View CSV
head /tmp/nftban-data.csv

# Expected CSV content:
# Timestamp,IP Address,Jail,Action,Reason
# 2025-10-20 14:30:15,192.0.2.100,fail2ban-sshd,BANNED,SSH brute force
# 2025-10-20 14:28:42,198.51.100.50,fail2ban-sshd,UNBANNED,Ban expired
# 2025-10-20 14:25:10,203.0.113.75,fail2ban-nginx,BANNED,Rate limit
# ...

# Import to Excel, LibreOffice, Google Sheets for analysis
```

### Example 6: Generate Comprehensive Report (Auditing)
```bash
nftban stats generate-report /tmp/nftban-monthly-report.txt

# Expected output:
# [INFO] Generating comprehensive report: /tmp/nftban-monthly-report.txt
# [SUCCESS] Report generated: /tmp/nftban-monthly-report.txt
# /tmp/nftban-monthly-report.txt

# View report
less /tmp/nftban-monthly-report.txt

# Report contains:
# - Full dashboard
# - Top 20 banned IPs
# - Recent 50 activities
# - Configuration snapshot
# - System information
```

### Example 7: Real-Time Monitoring (Live Dashboard)
```bash
nftban stats monitor

# Expected output (auto-refreshes every 5 seconds):
# ╔══════════════════════════════════════════════╗
# ║       NFTBan Real-Time Monitor               ║
# ╚══════════════════════════════════════════════╝
#
# Time: 2025-10-20 14:32:15
#
# [Full dashboard displayed here - auto-refreshes]
#
# Recent activity (last 10):
# 2025-10-20 14:32:10 | 192.0.2.100 | BANNED | fail2ban-sshd
# ... (refreshes every 5 seconds)
#
# Press Ctrl+C to exit
```

### Example 8: Log Cleanup (Maintenance)
```bash
# Cleanup logs older than 30 days (default)
nftban stats cleanup-logs

# Expected output:
# [INFO] Cleaning up logs older than 30 days...
# [SUCCESS] Rotated ban log: /var/log/nftban/ban.log.20251020-143215.gz
# [SUCCESS] Log cleanup complete: 5 files processed

# Custom retention (keep 90 days)
nftban stats cleanup-logs 90

# Expected output:
# [INFO] Cleaning up logs older than 90 days...
# [SUCCESS] Log cleanup complete: 2 files processed
```

---

## File Operations

### Reads from:

**Whitelist Sources:**
- `$NFTBAN_WHITELIST_SYSTEM` - System whitelist
- `$NFTBAN_WHITELIST_USER` - User whitelist
- `$NFTBAN_WHITELIST_CF` - Cloudflare whitelist

**Blacklist Sources:**
- `$NFTBAN_BLACKLIST_PERSISTENT` - Persistent blacklist
- `$NFTBAN_BLACKLIST_USER` - User blacklist

**Activity Logs:**
- `$NFTBAN_BAN_LOG` - All ban/unban events

**Configuration:**
- `$NFTBAN_GEO_BLACKLIST` - GEO blacklist config
- `$NFTBAN_CF_IPV4_CACHE` - Cloudflare IPv4 cache
- `$NFTBAN_CF_IPV6_CACHE` - Cloudflare IPv6 cache
- `$NFTBAN_LOCAL_CONFIG` - NFTBan configuration

**nftables:**
- Queries sets via `nft` command

### Writes to:

**Exports:**
- CSV files (user-specified path or `/tmp/nftban-stats-*.csv`)
- Report files (user-specified path or `/tmp/nftban-report-*.txt`)

**Log Rotation:**
- `$NFTBAN_BAN_LOG.YYYYMMDD-HHMMSS.gz` - Rotated compressed logs

### Ban Log Format:

```
Timestamp|IP Address|Jail|Action|Reason
2025-10-20 14:30:15|192.0.2.100|fail2ban-sshd|BANNED|SSH brute force
2025-10-20 14:28:42|198.51.100.50|fail2ban-sshd|UNBANNED|Ban expired
2025-10-20 14:25:10|203.0.113.75|fail2ban-nginx|BANNED|Rate limit exceeded
```

**Fields:**
- **Timestamp:** When event occurred (YYYY-MM-DD HH:MM:SS)
- **IP Address:** IPv4 or IPv6 address
- **Jail:** Source of ban (fail2ban-sshd, manual, etc.)
- **Action:** BANNED, UNBANNED, WHITELISTED, PERMANENT_BAN
- **Reason:** Human-readable reason

---

## Dashboard Components

### 1. System Information
- Hostname
- Current date/time
- NFTBan version (if available)

### 2. Whitelist Summary
- **System whitelist:** Protected IPs (never ban)
- **User whitelist:** Administrator-added IPs
- **Cloudflare whitelist:** CDN ranges
- **Total:** Sum of all whitelisted entries

### 3. Blacklist Summary
- **Persistent blacklist:** Permanent bans
- **User blacklist:** Administrator-added bans
- **Total:** Sum of all blacklisted entries

### 4. Ban Activity
- **Total events:** All ban/unban operations
- **Breakdown by action:** Count per action type
- **Top 5 banned IPs:** Most frequently banned
- **Recent activity:** Last 5 events

### 5. GEO Blocking
- **Blocked countries:** Count and list
- **Active nftables sets:** GEO sets in firewall

### 6. Cloudflare Integration
- **Status:** Enabled/disabled
- **IPv4/IPv6 ranges:** Count of whitelisted ranges
- **Cache age:** How old the cache is

### 7. nftables Status
- **Table name:** Active table
- **Set statistics:** Element count per set
  - whitelist
  - temp_ban
  - user_blacklist
  - system_blacklist
  - feeds

---

## Report Types

### 1. Dashboard Report (Quick)
**Command:** `nftban stats dashboard`

**Use Case:** Quick health check, daily monitoring

**Contents:**
- System info
- Whitelist/blacklist summary
- Ban activity overview
- GEO blocking status
- Cloudflare status
- nftables status

**Time to Generate:** <1 second

---

### 2. IP History Report (Forensic)
**Command:** `nftban stats ip-history <IP>`

**Use Case:** Investigate specific IP, track repeat offenders

**Contents:**
- All events for specific IP (chronological)
- Event summary (count by action type)
- Full details (timestamp, jail, action, reason)

**Time to Generate:** <1 second

---

### 3. Top Banned Report (Security Analysis)
**Command:** `nftban stats top-banned [limit]`

**Use Case:** Identify attack sources, prioritize permanent bans

**Contents:**
- Ranked list of most-banned IPs
- Ban count per IP
- Configurable limit (default: 10)

**Time to Generate:** <2 seconds (depends on log size)

---

### 4. CSV Export (Data Analysis)
**Command:** `nftban stats export-csv [file]`

**Use Case:** Import to Excel/Google Sheets, custom analysis

**Contents:**
- All ban log entries in CSV format
- Headers: Timestamp, IP, Jail, Action, Reason
- Compatible with spreadsheet software

**Time to Generate:** <5 seconds (depends on log size)

---

### 5. Comprehensive Report (Auditing)
**Command:** `nftban stats generate-report [file]`

**Use Case:** Monthly reviews, compliance auditing, management reporting

**Contents:**
- Full dashboard
- Top 20 banned IPs
- Recent 50 activities
- Configuration snapshot
- System information

**Time to Generate:** <5 seconds

---

## Real-Time Monitoring

### Monitor Mode Features

**Auto-Refresh:**
- Updates every 5 seconds
- Clears screen for clean display
- Shows timestamp of refresh

**Displayed Information:**
- Full dashboard (all components)
- Recent activity (last 10 events)
- Color-coded actions (red=banned, green=whitelisted, cyan=unbanned)

**Controls:**
- `Ctrl+C` - Exit monitor mode
- Screen auto-clears between updates

**Use Cases:**
- Active attack monitoring
- Real-time threat response
- Security operations center (SOC) display
- Training and demonstrations

**Example Session:**
```bash
nftban stats monitor

# Monitor displays and refreshes every 5 seconds
# Watch for new bans in real-time
# Identify attack patterns as they happen
# Press Ctrl+C when done
```

---

## Integration Points

**Called by:**
- `nftban_main_cli.sh` - For `nftban stats` commands
- System administrators - For reporting and monitoring
- Automated scripts - For scheduled reports
- Monitoring systems - For alerting

**Calls:**
- `nftban_log_*()` from `nftban_core.sh` - Logging
- `nftban_check_nftables_table()` from `nftban_nftables_module.sh` - Table verification
- `nftban_get_config()` from `nftban_core.sh` - Configuration retrieval
- External: `nft`, `grep`, `awk`, `sort`, `uniq`, `wc`, `gzip`

**Data Sources:**
- All NFTBan modules contribute to statistics
- Whitelist module → whitelist counts
- Blacklist module → blacklist counts, ban log entries
- GEO module → blocked countries
- Cloudflare module → CDN statistics
- Fail2ban module → ban events

**Integration Example:**
```bash
# In a monitoring script
source /usr/local/bin/nftban/lib/nftban_stats_module.sh

# Generate daily report
daily_report="/var/reports/nftban-daily-$(date +%Y%m%d).txt"
nftban_stats_generate_report "$daily_report"

# Email to admin
mail -s "NFTBan Daily Report" admin@example.com < "$daily_report"

# Check for high ban rate (alert threshold)
total_bans=$(grep "BANNED" "$NFTBAN_BAN_LOG" | wc -l)
if [[ $total_bans -gt 1000 ]]; then
    echo "ALERT: High ban rate detected ($total_bans total bans)" | \
        mail -s "NFTBan Alert: High Ban Rate" security@example.com
fi
```

---

## Performance Considerations

### Dashboard Generation

**Time Complexity:**
- Whitelist counts: O(n) - linear scan of files
- Blacklist counts: O(n) - linear scan of files
- Ban activity: O(n) - scan entire ban log
- Top banned: O(n log n) - sort all IPs
- **Total: O(n)** where n = number of log entries

**Optimization:**
- Counts cached for repeated calls (future improvement)
- Only scans relevant files (skips if missing)
- Uses efficient grep/awk instead of reading into memory

### Large Log Handling

**10,000 entries:**
- Dashboard: ~1 second
- Top banned: ~2 seconds
- CSV export: ~3 seconds

**100,000 entries:**
- Dashboard: ~5 seconds
- Top banned: ~10 seconds
- CSV export: ~15 seconds

**1,000,000+ entries:**
- Consider log rotation (automatic at 10MB)
- Archive old logs after analysis
- Use external analytics tools for historical data

### Memory Usage

**Dashboard:** <10 MB RAM (streams data, doesn't load all)
**CSV Export:** <50 MB RAM (for 100k entries)
**Monitor Mode:** <20 MB RAM (continuous refresh)

---

## Log Rotation Strategy

### Automatic Rotation

**Trigger:** Ban log exceeds 10 MB

**Process:**
1. Rename log with timestamp: `ban.log` → `ban.log.20251020-143215`
2. Compress: `ban.log.20251020-143215.gz`
3. Create new empty log: `ban.log`

**Benefits:**
- Prevents log files from growing indefinitely
- Preserves historical data (compressed)
- Maintains system performance

### Manual Cleanup

**Command:** `nftban stats cleanup-logs [days]`

**Actions:**
1. Rotate ban log if >10MB
2. Compress logs older than 7 days (`.log` → `.log.gz`)
3. Delete compressed logs older than specified days (default: 30)

**Recommended Schedule:**
```bash
# Weekly cleanup (keep 30 days)
0 3 * * 0 /usr/local/bin/nftban stats cleanup-logs 30

# Or monthly with longer retention (keep 90 days)
0 3 1 * * /usr/local/bin/nftban stats cleanup-logs 90
```

---

## Troubleshooting

### Problem: Dashboard Shows "No ban log available"

**Cause:** Ban log file doesn't exist or is empty

**Diagnostic:**
```bash
# Check if log exists
ls -lh "$NFTBAN_BAN_LOG"

# Check permissions
ls -l "$(dirname "$NFTBAN_BAN_LOG")"

# Check if logging is working
nftban blacklist ban 192.0.2.100 test 3600
cat "$NFTBAN_BAN_LOG"
```

**Solution:**
```bash
# Create log directory if missing
mkdir -p "$(dirname "$NFTBAN_BAN_LOG")"

# Create empty log
touch "$NFTBAN_BAN_LOG"
chmod 644 "$NFTBAN_BAN_LOG"

# Test ban (should create log entry)
nftban blacklist ban 192.0.2.100 test 3600
nftban blacklist unban 192.0.2.100 test
```

---

### Problem: Stats Taking Too Long

**Symptom:** Dashboard or reports take >10 seconds

**Diagnostic:**
```bash
# Check log size
ls -lh "$NFTBAN_BAN_LOG"

# Count entries
wc -l "$NFTBAN_BAN_LOG"

# Check if log needs rotation
stat -c %s "$NFTBAN_BAN_LOG"  # Size in bytes
```

**Solution:**
```bash
# Rotate large log manually
nftban stats cleanup-logs 0

# Or archive and start fresh
mv "$NFTBAN_BAN_LOG" "$NFTBAN_BAN_LOG.archive"
gzip "$NFTBAN_BAN_LOG.archive"
touch "$NFTBAN_BAN_LOG"

# Enable automatic rotation (if not enabled)
# Add to cron:
0 3 * * * /usr/local/bin/nftban stats cleanup-logs 30
```

---

### Problem: Monitor Mode Not Refreshing

**Symptom:** Monitor stuck, not updating

**Diagnostic:**
```bash
# Check if process is hung
ps aux | grep "nftban stats monitor"

# Test dashboard manually
nftban stats dashboard
```

**Solution:**
```bash
# Kill hung process
pkill -f "nftban stats monitor"

# Restart monitor
nftban stats monitor

# If issue persists, check system load
top
# High load may slow refresh
```

---

### Problem: CSV Export Fails

**Error:** "Permission denied" or "No such file or directory"

**Diagnostic:**
```bash
# Check output directory exists
ls -ld /tmp

# Check permissions
ls -l /tmp

# Try different output location
nftban stats export-csv ~/nftban-export.csv
```

**Solution:**
```bash
# Use home directory if /tmp not writable
nftban stats export-csv ~/nftban-export.csv

# Or create specific directory
mkdir -p /var/reports/nftban
nftban stats export-csv /var/reports/nftban/export.csv
```

---

## Best Practices

### ✅ DO:

1. **Review dashboard daily** during first month of operation
2. **Generate monthly reports** for compliance/auditing
3. **Monitor top banned IPs** for repeat offenders
4. **Enable automatic log rotation** (cron job)
5. **Export CSV monthly** for long-term analysis
6. **Check IP history** before escalating to permanent ban
7. **Use monitor mode** during active attacks
8. **Archive old reports** for historical reference
9. **Set up automated reports** (cron + email)
10. **Review stats after configuration changes**

### ❌ DON'T:

1. **Don't let logs grow indefinitely** (enable rotation!)
2. **Don't ignore high ban rates** (investigate patterns)
3. **Don't skip regular reviews** (weekly minimum)
4. **Don't delete logs without archiving** (compliance risk)
5. **Don't run monitor mode on production** (resource usage)
6. **Don't overlook repeat offenders** (escalate to permanent)
7. **Don't ignore whitelist anomalies** (review regularly)
8. **Don't export sensitive data** without encryption
9. **Don't share reports** without redacting IPs (privacy)
10. **Don't disable statistics logging** (needed for forensics)

---

## Automated Reporting

### Daily Dashboard Email
```bash
#!/bin/bash
# daily-dashboard-email.sh

# Generate dashboard
dashboard=$(nftban stats dashboard)

# Email to admin
echo "$dashboard" | mail -s "NFTBan Daily Dashboard - $(date +%Y-%m-%d)" admin@example.com

# Add to cron:
# 0 8 * * * /usr/local/bin/daily-dashboard-email.sh
```

---

### Weekly Report Generation
```bash
#!/bin/bash
# weekly-report.sh

# Generate comprehensive report
report_file="/var/reports/nftban/weekly-$(date +%Y%m%d).txt"
nftban stats generate-report "$report_file"

# Compress
gzip "$report_file"

# Email
echo "Weekly NFTBan report attached" | \
    mail -s "NFTBan Weekly Report" \
         -a "${report_file}.gz" \
         security@example.com

# Add to cron (Sunday 6 AM):
# 0 6 * * 0 /usr/local/bin/weekly-report.sh
```

---

### Alert on High Ban Rate
```bash
#!/bin/bash
# ban-rate-alert.sh

THRESHOLD=100  # Alert if >100 bans in last hour

# Count recent bans
recent_bans=$(grep "BANNED" "$NFTBAN_BAN_LOG" | \
    awk -v cutoff="$(date -d '1 hour ago' +'%Y-%m-%d %H:%M:%S')" \
    '$1" "$2 > cutoff' | wc -l)

if [[ $recent_bans -gt $THRESHOLD ]]; then
    # Alert email
    cat <<EOF | mail -s "ALERT: High Ban Rate Detected" security@example.com
NFTBan Alert: High Ban Rate

Detected $recent_bans bans in the last hour (threshold: $THRESHOLD)

Top 10 banned IPs in last hour:
$(grep "BANNED" "$NFTBAN_BAN_LOG" | \
    awk -v cutoff="$(date -d '1 hour ago' +'%Y-%m-%d %H:%M:%S')" \
    '$1" "$2 > cutoff {print $0}' | \
    awk -F'|' '{print $2}' | sort | uniq -c | sort -rn | head -10)

View full dashboard: nftban stats dashboard

Time: $(date)
Hostname: $(hostname)
EOF

    # Log alert
    echo "[$(date)] ALERT: High ban rate detected ($recent_bans bans)" >> \
        /var/log/nftban/alerts.log
fi

# Add to cron (every 15 minutes):
# */15 * * * * /usr/local/bin/ban-rate-alert.sh
```

---

### Monthly CSV Archive
```bash
#!/bin/bash
# monthly-csv-archive.sh

# Create monthly archive directory
archive_dir="/var/archives/nftban/$(date +%Y)"
mkdir -p "$archive_dir"

# Export CSV with month in filename
csv_file="$archive_dir/nftban-$(date +%Y-%m).csv"
nftban stats export-csv "$csv_file"

# Compress
gzip "$csv_file"

# Backup to remote storage (example: S3, rsync, etc.)
# aws s3 cp "${csv_file}.gz" s3://backups/nftban/
# or
# rsync -av "${csv_file}.gz" backup-server:/backups/nftban/

# Email confirmation
echo "Monthly NFTBan CSV archive created: ${csv_file}.gz" | \
    mail -s "NFTBan Monthly Archive - $(date +%Y-%m)" admin@example.com

# Add to cron (1st day of month, 2 AM):
# 0 2 1 * * /usr/local/bin/monthly-csv-archive.sh
```

---

## Advanced Analytics

### Scenario 1: Attack Pattern Analysis

Identify coordinated attacks (multiple IPs, similar timing):

```bash
#!/bin/bash
# analyze-attack-patterns.sh

echo "NFTBan Attack Pattern Analysis"
echo "==============================="
echo ""

# Bans by hour
echo "Bans by Hour (last 24 hours):"
grep "BANNED" "$NFTBAN_BAN_LOG" | \
    awk -v cutoff="$(date -d '24 hours ago' +'%Y-%m-%d %H:%M:%S')" \
    '$1" "$2 > cutoff' | \
    awk -F'|' '{print substr($1,12,2)}' | \
    sort | uniq -c | sort -rn | \
    while read count hour; do
        printf "  Hour %s: %3d bans\n" "$hour" "$count"
    done

echo ""

# Ban sources (jails)
echo "Bans by Source (last 24 hours):"
grep "BANNED" "$NFTBAN_BAN_LOG" | \
    awk -v cutoff="$(date -d '24 hours ago' +'%Y-%m-%d %H:%M:%S')" \
    '$1" "$2 > cutoff' | \
    awk -F'|' '{print $3}' | \
    sort | uniq -c | sort -rn | \
    while read count jail; do
        printf "  %-25s %3d bans\n" "$jail" "$count"
    done

echo ""

# Geographic distribution (if GeoIP available)
echo "Bans by Country (last 24 hours):"
grep "BANNED" "$NFTBAN_BAN_LOG" | \
    awk -v cutoff="$(date -d '24 hours ago' +'%Y-%m-%d %H:%M:%S')" \
    '$1" "$2 > cutoff' | \
    awk -F'|' '{print $2}' | \
while read ip; do
    # Get country (requires nftban_geoip_module)
    if command -v nftban_geoip_get_compact &>/dev/null; then
        nftban_geoip_get_compact "$ip" 2>/dev/null | cut -d'/' -f1
    fi
done | sort | uniq -c | sort -rn | head -10 | \
while read count country; do
    printf "  %-20s %3d bans\n" "$country" "$count"
done
```

---

### Scenario 2: Repeat Offender Detection

Find IPs that should be escalated to permanent ban:

```bash
#!/bin/bash
# detect-repeat-offenders.sh

THRESHOLD=5  # Ban 5+ times = repeat offender

echo "NFTBan Repeat Offender Report"
echo "============================="
echo ""

# Find IPs with multiple bans
grep "BANNED" "$NFTBAN_BAN_LOG" | \
    awk -F'|' '{print $2}' | \
    sort | uniq -c | sort -rn | \
    awk -v thresh="$THRESHOLD" '$1 >= thresh {print $0}' | \
while read count ip; do
    echo "IP: $ip ($count bans)"
    
    # Get geographic info
    if command -v nftban_geoip_get_compact &>/dev/null; then
        geo=$(nftban_geoip_get_compact "$ip" 2>/dev/null || echo "Unknown")
        echo "  Location: $geo"
    fi
    
    # First and last ban time
    first_ban=$(grep "BANNED.*|${ip}|" "$NFTBAN_BAN_LOG" | head -1 | cut -d'|' -f1)
    last_ban=$(grep "BANNED.*|${ip}|" "$NFTBAN_BAN_LOG" | tail -1 | cut -d'|' -f1)
    echo "  First ban: $first_ban"
    echo "  Last ban: $last_ban"
    
    # Ban sources
    echo "  Jails:"
    grep "BANNED.*|${ip}|" "$NFTBAN_BAN_LOG" | \
        awk -F'|' '{print $3}' | sort | uniq -c | sort -rn | \
        while read jail_count jail; do
            echo "    - $jail: $jail_count times"
        done
    
    # Check if already permanently banned
    if grep -q "^${ip}" /etc/nftban/config/blacklist_ips.conf; then
        echo "  Status: ✓ Already permanently banned"
    else
        echo "  Status: ⚠ Candidate for permanent ban"
        echo "  Action: nftban blacklist add $ip \"Repeat offender ($count bans)\""
    fi
    
    echo ""
done
```

---

### Scenario 3: Effectiveness Metrics

Measure NFTBan's effectiveness over time:

```bash
#!/bin/bash
# effectiveness-metrics.sh

echo "NFTBan Effectiveness Metrics"
echo "============================"
echo ""

# Calculate metrics for last 30 days
cutoff=$(date -d '30 days ago' +'%Y-%m-%d %H:%M:%S')

# Total unique IPs banned
unique_banned=$(grep "BANNED" "$NFTBAN_BAN_LOG" | \
    awk -v cutoff="$cutoff" '$1" "$2 > cutoff' | \
    awk -F'|' '{print $2}' | sort -u | wc -l)
echo "Unique IPs banned (30 days): $unique_banned"

# Total ban events
total_bans=$(grep "BANNED" "$NFTBAN_BAN_LOG" | \
    awk -v cutoff="$cutoff" '$1" "$2 > cutoff' | wc -l)
echo "Total ban events (30 days): $total_bans"

# Average bans per IP
if [[ $unique_banned -gt 0 ]]; then
    avg_bans=$((total_bans / unique_banned))
    echo "Average bans per IP: $avg_bans"
fi

# Ban duration (for temporary bans that expired)
echo ""
echo "Ban Duration Analysis:"
grep "UNBANNED" "$NFTBAN_BAN_LOG" | \
    awk -v cutoff="$cutoff" '$1" "$2 > cutoff' | \
    awk -F'|' '{print $5}' | \
    grep -o '[0-9]\+ hour\|[0-9]\+ minute' | \
    sort | uniq -c | sort -rn | \
    while read count duration; do
        printf "  %-15s %3d unbans\n" "$duration" "$count"
    done

# Repeat offender rate
repeat_offenders=$(grep "BANNED" "$NFTBAN_BAN_LOG" | \
    awk -v cutoff="$cutoff" '$1" "$2 > cutoff' | \
    awk -F'|' '{print $2}' | \
    sort | uniq -c | awk '$1 > 1' | wc -l)
if [[ $unique_banned -gt 0 ]]; then
    repeat_rate=$((repeat_offenders * 100 / unique_banned))
    echo ""
    echo "Repeat offender rate: ${repeat_rate}% ($repeat_offenders of $unique_banned)"
fi

# Most attacked services
echo ""
echo "Most Attacked Services:"
grep "BANNED" "$NFTBAN_BAN_LOG" | \
    awk -v cutoff="$cutoff" '$1" "$2 > cutoff' | \
    awk -F'|' '{print $3}' | \
    sort | uniq -c | sort -rn | head -5 | \
    while read count jail; do
        printf "  %-25s %4d bans\n" "$jail" "$count"
    done
```

---

## Compliance and Auditing

### GDPR Compliance

**Data Protection Considerations:**

1. **IP Address Storage:** IPs are personal data under GDPR
2. **Retention Period:** Define and enforce retention limits
3. **Purpose Limitation:** Log only for security purposes
4. **Right to Erasure:** Ability to remove specific IP data

**Implementation:**

```bash
#!/bin/bash
# gdpr-compliance-audit.sh

echo "GDPR Compliance Audit for NFTBan"
echo "================================"
echo ""

# Check data retention
log_age=$(( ($(date +%s) - $(stat -c %Y "$NFTBAN_BAN_LOG")) / 86400 ))
echo "Current log age: $log_age days"
echo "GDPR recommendation: <90 days for security logs"

if [[ $log_age -gt 90 ]]; then
    echo "⚠ WARNING: Log exceeds GDPR recommended retention"
    echo "Action: Run 'nftban stats cleanup-logs 90'"
fi

echo ""

# Check for archived logs
archived_logs=$(find "$NFTBAN_LOG_DIR" -name "*.log.gz" -mtime +90 | wc -l)
if [[ $archived_logs -gt 0 ]]; then
    echo "⚠ Found $archived_logs archived logs older than 90 days"
    echo "Action: Review and delete if no longer needed"
fi

echo ""

# Data subject rights
echo "Data Subject Rights Implementation:"
echo "  - Right to access: nftban stats ip-history <IP>"
echo "  - Right to erasure: Manual removal from logs required"
echo "  - Right to portability: nftban stats export-csv"

echo ""
echo "Recommendations:"
echo "  1. Implement automated 90-day log rotation"
echo "  2. Document data retention policy"
echo "  3. Create procedure for data subject requests"
echo "  4. Regular compliance audits (quarterly)"
```

---

### SOC 2 Audit Support

Generate audit-ready reports:

```bash
#!/bin/bash
# soc2-audit-report.sh

audit_date=$(date +%Y%m%d)
output_file="/var/reports/nftban/soc2-audit-${audit_date}.txt"

cat > "$output_file" <<EOF
═══════════════════════════════════════════════════════════
                NFTBan Security Controls Audit
                     SOC 2 Compliance Report
═══════════════════════════════════════════════════════════

Audit Date: $(date +'%Y-%m-%d %H:%M:%S')
Audit Period: Last 90 days
System: $(hostname)
Auditor: $(whoami)

───────────────────────────────────────────────────────────
CONTROL OBJECTIVE: Access Control (CC6.1)
───────────────────────────────────────────────────────────

EOF

# Access control metrics
nftban stats dashboard >> "$output_file"

cat >> "$output_file" <<EOF

───────────────────────────────────────────────────────────
CONTROL OBJECTIVE: Logging and Monitoring (CC7.2)
───────────────────────────────────────────────────────────

Total security events logged: $(wc -l < "$NFTBAN_BAN_LOG")
Log retention period: 90 days
Log integrity: Protected by file permissions (644)

Recent Ban Activity (Last 7 Days):
EOF

grep "BANNED" "$NFTBAN_BAN_LOG" | \
    awk -v cutoff="$(date -d '7 days ago' +'%Y-%m-%d')" \
    '$1 >= cutoff' | wc -l >> "$output_file"

cat >> "$output_file" <<EOF

───────────────────────────────────────────────────────────
CONTROL OBJECTIVE: Incident Response (CC7.3)
───────────────────────────────────────────────────────────

EOF

# Incident response metrics
nftban stats top-banned 20 >> "$output_file"

cat >> "$output_file" <<EOF

───────────────────────────────────────────────────────────
CONTROL OBJECTIVE: Configuration Management (CC8.1)
───────────────────────────────────────────────────────────

Current Configuration:
EOF

cat "$NFTBAN_LOCAL_CONFIG" | grep -v '^#' | grep -v '^ >> "$output_file"

cat >> "$output_file" <<EOF

═══════════════════════════════════════════════════════════
                        End of Report
═══════════════════════════════════════════════════════════
EOF

echo "SOC 2 audit report generated: $output_file"
```

---

## Change Log

### Version 1.0.0 (2025-10-20) - Initial Release
- Comprehensive dashboard with all NFTBan components
- IP history tracking for forensic analysis
- Top banned IPs report for security analysis
- Recent activity monitoring
- CSV export for data analysis
- Comprehensive report generation
- Real-time monitoring mode
- Automatic log rotation and cleanup
- Integration with all NFTBan modules

---

## See Also

**Related Modules:**
- `nftban_blacklist_module.sh` - Generates ban log entries
- `nftban_whitelist_module.sh` - Contributes whitelist statistics
- `nftban_geo_module.sh` - GEO blocking statistics
- `nftban_cloudflare_module.sh` - CDN statistics
- `nftban_fail2ban_module.sh` - Automated ban triggers
- `nftban_core.sh` - Core logging infrastructure

**Related Documentation:**
- Log Management Best Practices
- Security Incident Response Procedures
- Compliance Requirements (GDPR, SOC 2)

**External Resources:**
- [GDPR Guidelines for Security Logs](https://gdpr.eu/)
- [SOC 2 Security Controls](https://www.aicpa.org/interestareas/frc/assuranceadvisoryservices/aicpasoc2report)
- [Security Information and Event Management (SIEM)](https://en.wikipedia.org/wiki/Security_information_and_event_management)

---

## Summary

The Statistics Module provides complete visibility into NFTBan operations through comprehensive dashboards, detailed reports, and real-time monitoring. Essential capabilities:

**Core Features:**
- ✅ Unified dashboard (all components at a glance)
- ✅ IP history tracking (forensic analysis)
- ✅ Top offenders identification (security insights)
- ✅ Multiple export formats (CSV, TXT reports)
- ✅ Real-time monitoring (live attack tracking)
- ✅ Automatic log rotation (maintenance-free)

**Key Metrics:**
- 📊 Whitelist/Blacklist counts
- 📊 Ban activity statistics
- 📊 GEO blocking effectiveness
- 📊 nftables set sizes
- 📊 Repeat offender tracking
- 📊 Attack pattern analysis

**Use Cases:**
- 🔍 Daily security monitoring
- 🔍 Weekly/monthly reporting
- 🔍 Compliance auditing (GDPR, SOC 2)
- 🔍 Incident investigation
- 🔍 Attack pattern analysis
- 🔍 Performance optimization

**Essential Commands:**
```bash
# Quick overview
nftban stats dashboard

# Investigate specific IP
nftban stats ip-history 192.0.2.100

# Security analysis
nftban stats top-banned 20

# Export data
nftban stats export-csv /tmp/data.csv
nftban stats generate-report /tmp/report.txt

# Real-time monitoring
nftban stats monitor

# Maintenance
nftban stats cleanup-logs 30
```

**Automated Workflows:**
```bash
# Daily dashboard email (cron: 0 8 * * *)
nftban stats dashboard | mail -s "NFTBan Daily" admin@example.com

# Weekly report (cron: 0 6 * * 0)
nftban stats generate-report /var/reports/weekly.txt

# Monthly archive (cron: 0 2 1 * *)
nftban stats export-csv /var/archives/$(date +%Y-%m).csv

# Log cleanup (cron: 0 3 * * 0)
nftban stats cleanup-logs 30
```

This module transforms raw security data into actionable intelligence!