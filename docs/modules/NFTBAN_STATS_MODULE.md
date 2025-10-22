# NFTBan Statistics Module

**Module:** `nftban_stats_module.sh` | **Version:** 0.9.3-dev | **Location:** `/usr/local/lib/nftban/`

## Overview

The Statistics Module provides comprehensive reporting and monitoring for NFTBan's blocking activity, resource usage, and system health. It aggregates data from all NFTBan components to deliver real-time dashboards, historical reports, and CSV exports for analysis.

### Key Features

- **Live Dashboard**: Real-time overview of whitelist, blacklist, bans, GEO blocks, Cloudflare, and nftables
- **Split Table Support**: Reports on both IPv4 (`nftban_v4`) and IPv6 (`nftban_v6`) tables (v0.9.0+)
- **Ban Activity Tracking**: Top banned IPs, recent events, IP-specific history
- **CSV Export**: Export ban logs for external analysis (Excel, BI tools)
- **Real-Time Monitor**: Auto-refreshing dashboard (5-second intervals)
- **Report Generation**: Comprehensive text reports with all statistics
- **Log Rotation**: Automatic cleanup and compression of old logs (>10MB)

### Dependencies

- **Core Module**: For configuration and logging
- **nftables**: For set element counting
- **awk/grep**: For log parsing and statistics

---

## API Reference

### Dashboard Functions

**`nftban_stats_dashboard()`** - Show comprehensive dashboard
```bash
nftban stats dashboard

# ╔════════════════════════════════════════════════╗
# ║         NFTBan Statistics Dashboard            ║
# ╚════════════════════════════════════════════════╝
#
# [SYSTEM]
#   Hostname: server.example.com
#   Date: 2025-10-23 14:30:45
#
# [WHITELIST]
#   System: 15
#   User: 8
#   Cloudflare: 31
#   ──────────────
#   Total: 54
#
# [BLACKLIST]
#   Persistent: 42
#   User: 18
#   ──────────────
#   Total: 60
#
# [BAN ACTIVITY]
#   Total events: 1,234
#   ...
```
- **Includes**: Whitelist, Blacklist, Ban Activity, GEO, Cloudflare, nftables stats
- **Auto-updated**: Data from files and nftables sets

**`nftban_stats_whitelist_summary()`** - Whitelist statistics
```bash
# Called internally by dashboard
# Counts: System, User, Cloudflare whitelists
```

**`nftban_stats_blacklist_summary()`** - Blacklist statistics
```bash
# Counts: Persistent, User blacklists
```

**`nftban_stats_ban_activity()`** - Ban activity overview
```bash
# Shows:
# - Total events
# - Breakdown by action (BANNED, UNBANNED, WHITELISTED)
# - Top 5 banned IPs
# - Recent activity (last 5)
```

**`nftban_stats_geo_summary()`** - GEO blocking statistics
```bash
# Shows:
# - Blocked countries count
# - Country list
# - Active nftables GEO sets (IPv4/IPv6)
```

**`nftban_stats_cloudflare_summary()`** - Cloudflare status
```bash
# Shows:
# - Enabled/disabled status
# - IPv4/IPv6 range counts
# - Cache age in hours
```

**`nftban_stats_nftables_summary()`** - nftables set statistics
```bash
# Shows v0.9.0 split tables:
#   IPv4 Table: ip nftban_v4
#   IPv6 Table: ip6 nftban_v6
#
#   Sets:
#     whitelist               542 total (IPv4: 512, IPv6: 30)
#     temp_ban                 15 total (IPv4: 12, IPv6: 3)
#     user_blacklist           60 total (IPv4: 58, IPv6: 2)
#     system_blacklist          0 total (IPv4: 0, IPv6: 0)
#     feeds                 45234 total (IPv4: 45000, IPv6: 234)
```
- **Detects**: Split tables (v0.9.0+) vs legacy table (v0.8.5)
- **Migration warning**: Prompts if legacy table detected

### IP History & Top Lists

**`nftban_stats_ip_history(ip)`** - Show full ban history for IP
```bash
nftban stats ip-history 192.168.1.100

# === Ban History for 192.168.1.100 ===
#
# Total events: 5
#
# [BANNED] 2025-10-22 10:15:23
#   Jail: sshd
#   Reason: Failed password
#
# [UNBANNED] 2025-10-22 11:00:00
#   Jail: system
#   Reason: Temporary ban expired
#
# Summary:
#   BANNED           3
#   UNBANNED         1
#   WHITELISTED      1
```

**`nftban_stats_top_banned([limit])`** - Top N banned IPs
```bash
nftban stats top-banned 10

# === Top 10 Banned IPs ===
#
#   1. 203.0.113.45      23 bans
#   2. 198.51.100.12     18 bans
#   3. 192.0.2.77        15 bans
#   ...
```
- **Default**: 10 IPs
- **Source**: Ban log file

**`nftban_stats_recent([limit])`** - Recent activity
```bash
nftban stats recent 20

# === Recent Activity (last 20) ===
#
# 2025-10-23 14:28:15 | 203.0.113.45   | BANNED          | sshd
# 2025-10-23 14:25:03 | 192.0.2.100    | WHITELISTED     | system
# 2025-10-23 14:20:45 | 198.51.100.8   | UNBANNED        | system
# ...
```
- **Default**: 20 events
- **Color-coded**: Red (BANNED), Green (WHITELISTED), Cyan (UNBANNED)

### Export & Reporting

**`nftban_stats_export_csv([output_file])`** - Export to CSV
```bash
nftban stats export-csv /tmp/bans.csv

# Exporting statistics to CSV: /tmp/bans.csv
# Exported 1,234 records to /tmp/bans.csv

# CSV format:
# Timestamp,IP Address,Jail,Action,Reason
# 2025-10-23 14:30:00,203.0.113.45,sshd,BANNED,Failed password
# ...
```
- **Default file**: `/tmp/nftban-stats-YYYYMMDD-HHMMSS.csv`
- **Use case**: Import into Excel, BI tools, analysis scripts

**`nftban_stats_generate_report([output_file])`** - Generate comprehensive report
```bash
nftban stats report /tmp/report.txt

# Generating comprehensive report: /tmp/report.txt
# Report generated: /tmp/report.txt

# Report includes:
# - Full dashboard
# - Top 20 banned IPs
# - Recent 50 events
# - Configuration dump
```
- **Default file**: `/tmp/nftban-report-YYYYMMDD-HHMMSS.txt`

### Real-Time Monitoring

**`nftban_stats_monitor()`** - Live auto-refreshing dashboard
```bash
nftban stats monitor

# ╔════════════════════════════════════════════════╗
# ║       NFTBan Real-Time Monitor                 ║
# ╚════════════════════════════════════════════════╝
#
# Time: 2025-10-23 14:30:15
#
# [Dashboard refreshes every 5 seconds]
# [Press Ctrl+C to exit]
```
- **Refresh rate**: 5 seconds
- **Display**: Full dashboard + last 10 events
- **Exit**: Ctrl+C

### Log Maintenance

**`nftban_stats_cleanup_logs([days])`** - Clean up old logs
```bash
nftban stats cleanup 30

# Cleaning up logs older than 30 days...
# Rotated ban log: /var/log/nftban/ban.log.20251023-143015.gz
# Log cleanup complete: 12 files processed
```
- **Default**: 30 days retention
- **Actions**:
  - Rotates ban log if >10MB
  - Compresses logs older than 7 days (gzip)
  - Deletes compressed logs older than N days

---

## Configuration

**Ban Log** (`/var/log/nftban/ban.log`):
```
# Format: timestamp|ip|jail|action|reason
2025-10-23 14:30:00|203.0.113.45|sshd|BANNED|Failed password
2025-10-23 14:25:00|192.0.2.100|system|WHITELISTED|Trusted server
```

**Stats Cache** (`/var/cache/nftban/stats-cache.json`):
- Caches frequently accessed statistics for performance

**Global Variables**:
```bash
NFTBAN_STATS_DB="${NFTBAN_DATA_DIR}/stats.db"
NFTBAN_STATS_CACHE="${NFTBAN_CACHE_DIR}/stats-cache.json"
```

---

## CLI Integration

```bash
# Dashboard
nftban stats dashboard
nftban stats

# IP history
nftban stats ip-history 192.168.1.100

# Top lists
nftban stats top-banned 20
nftban stats recent 50

# Export
nftban stats export-csv /tmp/bans.csv
nftban stats report /tmp/report.txt

# Real-time monitoring
nftban stats monitor

# Log cleanup
nftban stats cleanup 30
```

---

## Split Table Architecture (v0.9.0+)

### nftables Set Counting

The Stats module automatically detects split table architecture and counts elements from both IPv4 and IPv6 sets:

```bash
# IPv4 sets: ip nftban_v4 [set_name]
# IPv6 sets: ip6 nftban_v6 [set_name]

# Sets counted:
# - whitelist
# - temp_ban
# - user_blacklist
# - system_blacklist
# - feeds
```

### Legacy Table Detection

If v0.8.5 legacy table detected:
```bash
nftban stats dashboard

# [NFTABLES]
#   Legacy v0.8.5 table detected: inet nftban_global
#   Please run: nftban migrate v085-to-v090
```

---

## Testing

### Test 1: Dashboard Display

```bash
# View dashboard
nftban stats dashboard

# Verify sections displayed:
# - SYSTEM (hostname, date)
# - WHITELIST (counts)
# - BLACKLIST (counts)
# - BAN ACTIVITY (breakdown)
# - GEO BLOCKING
# - CLOUDFLARE
# - NFTABLES (split tables)
```

### Test 2: CSV Export

```bash
# Export to CSV
nftban stats export-csv /tmp/test.csv

# Verify file exists
ls -lh /tmp/test.csv

# Check format
head -5 /tmp/test.csv
# Timestamp,IP Address,Jail,Action,Reason
# 2025-10-23 14:30:00,203.0.113.45,sshd,BANNED,Failed password
```

### Test 3: Real-Time Monitor

```bash
# Start monitor
nftban stats monitor

# Verify:
# - Dashboard displays
# - Refreshes every 5 seconds
# - Shows last 10 events
# - Ctrl+C exits cleanly
```

### Test 4: Log Cleanup

```bash
# Create test log
dd if=/dev/zero of=/var/log/nftban/test.log bs=1M count=15

# Run cleanup (should rotate logs >10MB)
nftban stats cleanup 30

# Verify rotation
ls -lh /var/log/nftban/test.log*
# test.log.20251023-143015.gz
```

---

## Performance

**Dashboard Generation**:
- File-based stats: <100ms
- nftables set counting: ~50ms per set
- Total: <1 second for full dashboard

**CSV Export**:
- 1,000 events: <1 second
- 10,000 events: ~2-3 seconds
- 100,000 events: ~10-15 seconds

**Log Rotation**:
- 10MB log compression: ~2-3 seconds
- gzip ratio: ~90% reduction (10MB → 1MB)

**Real-Time Monitor**:
- Refresh cycle: <1 second
- CPU impact: Negligible (<0.1%)

---

## Troubleshooting

### Issue 1: No Ban Activity Displayed

**Symptoms**: Dashboard shows "No ban activity recorded"

**Solutions**:
```bash
# Check ban log exists
ls -l /var/log/nftban/ban.log

# Check permissions
chmod 644 /var/log/nftban/ban.log

# Verify log format
tail -5 /var/log/nftban/ban.log
# Should be: timestamp|ip|jail|action|reason
```

### Issue 2: nftables Set Count Incorrect

**Symptoms**: Stats show 0 elements but IPs are blocked

**Solutions**:
```bash
# Check if tables exist
nft list tables

# Verify set exists
nft list set ip nftban_v4 user_blacklist

# Check NFTBan config
grep NFTBAN_NFT_TABLE /etc/nftban/nftban.conf
# Should be: nftban_v4 and nftban_v6 (v0.9.0+)
```

### Issue 3: CSV Export Fails

**Symptoms**: "No ban log available" error

**Solutions**:
```bash
# Create log directory if missing
mkdir -p /var/log/nftban
touch /var/log/nftban/ban.log

# Fix ownership
chown root:root /var/log/nftban/ban.log
```

### Issue 4: Real-Time Monitor Doesn't Refresh

**Symptoms**: Monitor freezes or doesn't update

**Solutions**:
```bash
# Check terminal supports ANSI codes
echo $TERM
# Should be: xterm, screen, or similar

# Try with larger terminal window
# Minimum: 80x24

# Exit and restart
# Press Ctrl+C to exit, then restart monitor
```

---

## Integration with Other Modules

### With Blacklist Module

Ban events automatically logged to ban log:
```bash
# When IP banned via Blacklist module:
# Logs: timestamp|ip|jail|action|reason

# Stats module reads this log for:
# - Top banned IPs
# - Ban activity breakdown
# - IP-specific history
```

### With Whitelist Module

Whitelist counts displayed in dashboard:
```bash
nftban stats dashboard

# [WHITELIST]
#   System: 15  # From whitelist-system.conf
#   User: 8     # From whitelist-user.conf
#   Cloudflare: 31  # From Cloudflare module
```

### With GEO Module

GEO blocking statistics:
```bash
# Shows blocked countries
# Counts active GEO nftables sets (IPv4/IPv6)
```

### With Feeds Module

Feed statistics:
```bash
# nftables summary shows feeds set element count
# feeds: 45,234 total (IPv4: 45,000, IPv6: 234)
```

---

## Best Practices

1. **Regular Reports**:
   ```bash
   # Generate weekly report
   nftban stats report /var/reports/nftban-$(date +%Y%m%d).txt
   ```

2. **Export for Analysis**:
   ```bash
   # Monthly CSV export
   nftban stats export-csv /backup/bans-$(date +%Y%m).csv
   ```

3. **Monitor High-Traffic Systems**:
   ```bash
   # Run real-time monitor during attacks
   nftban stats monitor
   ```

4. **Automated Cleanup**:
   ```bash
   # Add to weekly cron
   0 2 * * 0 /usr/local/bin/nftban stats cleanup 30
   ```

5. **Track Persistent Offenders**:
   ```bash
   # Check top banned IPs weekly
   nftban stats top-banned 50 > /var/reports/top-offenders.txt
   ```

---

## License

**NFTBAN Custom License v3.0**
SPDX-License-Identifier: NFTBAN-Custom-License

© 2025 Antonios Voulvoulis – ITCMS. All rights reserved.

**Summary:**
- ✅ Free to use for any purpose (personal, commercial, production)
- ✅ Free to modify privately
- ✅ Free to deploy unlimited instances
- ❌ NO redistribution, republication, or resale
- ❌ NO public GitHub forks or package uploads

Full license: https://github.com/itcmsgr/nftban/blob/main/LICENSE.md

---

**Made by ITCMS** | https://itcms.gr
Empowering system administrators with simple, powerful security tools.
