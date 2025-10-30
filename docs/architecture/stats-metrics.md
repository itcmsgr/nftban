# NFTBan v0.10.0 - Stats & Metrics System Design
**COMPREHENSIVE FANTASTIC REPORT & MONITORING SYSTEM**

**Date:** 2025-10-29
**Version:** 1.0.0
**Status:** Design Complete - Ready for Implementation

---

## 🎯 OVERVIEW

A **production-grade statistics and metrics system** for NFTBan v0.10.0 featuring:

- 📊 **Real-time dashboard** with comprehensive metrics
- 📈 **Beautiful HTML reports** with interactive charts
- 📧 **Automated email reports** (daily, weekly, monthly via cron)
- 🔍 **Advanced analytics** (attack patterns, repeat offenders, effectiveness)
- 📤 **Multiple export formats** (HTML, JSON, CSV, PDF)
- 🌍 **GeoIP intelligence** (country-based attack analysis)
- ⚡ **Performance optimized** (handles millions of events)
- 🎨 **Modern UI** (dark/light theme, responsive, Chart.js)

---

## 📁 FILE STRUCTURE (FHS Compliant)

```
/etc/nftban/conf.d/
├── stats.conf                      # Stats module configuration

/usr/lib/nftban/core/
├── nftban_stats.sh                 # Core stats engine (NEW)

/usr/lib/nftban/cli/
├── cmd_stats.sh                    # Stats CLI command (NEW)
├── cmd_report.sh                   # Report CLI command (NEW)

/usr/share/nftban/templates/reports/
├── stats_report.html               # Main stats HTML template (NEW)
├── email_report.html               # Email-friendly template (NEW)
├── assets/
│   ├── chart.min.js                # Chart.js library
│   └── styles.css                  # Report styling

/var/lib/nftban/
├── stats/
│   ├── metrics.db                  # Metrics database (SQLite or JSON)
│   ├── cache/                      # Cached statistics
│   └── snapshots/                  # Daily snapshots
└── reports/
    ├── daily/                      # Daily reports
    ├── weekly/                     # Weekly reports
    └── monthly/                    # Monthly reports

/var/log/nftban/
├── ban.log                         # Main ban event log
├── stats.log                       # Stats module log
└── email.log                       # Email notification log

/etc/cron.d/
└── nftban-stats                    # Cron jobs for automated reports
```

---

## ⚙️ CONFIGURATION FILE

**File:** `/etc/nftban/conf.d/stats.conf`

```bash
# =============================================================================
# NFTBan Statistics & Metrics Configuration
# =============================================================================

# ──────────────────────────────────────────────────────────────────────────
# GENERAL SETTINGS
# ──────────────────────────────────────────────────────────────────────────

# Enable statistics collection
STATS_ENABLED="true"

# Statistics database type (json|sqlite)
STATS_DB_TYPE="json"

# History retention (days)
STATS_RETENTION_DAYS="90"

# Cache statistics for performance (true|false)
STATS_CACHE_ENABLED="true"

# Cache TTL in seconds (default: 300 = 5 minutes)
STATS_CACHE_TTL="300"

# ──────────────────────────────────────────────────────────────────────────
# DATA COLLECTION
# ──────────────────────────────────────────────────────────────────────────

# Collect GeoIP statistics (requires nftban-geoip binary)
STATS_GEOIP_ENABLED="true"

# Track repeat offenders (IPs banned multiple times)
STATS_TRACK_REPEAT_OFFENDERS="true"

# Repeat offender threshold (bans)
STATS_REPEAT_OFFENDER_THRESHOLD="5"

# Track attack patterns (time-based analysis)
STATS_TRACK_ATTACK_PATTERNS="true"

# Track feed effectiveness
STATS_TRACK_FEED_EFFECTIVENESS="true"

# Track fail2ban jail statistics
STATS_TRACK_JAIL_STATS="true"

# ──────────────────────────────────────────────────────────────────────────
# DASHBOARD SETTINGS
# ──────────────────────────────────────────────────────────────────────────

# Default dashboard refresh interval (seconds, for monitor mode)
STATS_MONITOR_REFRESH="5"

# Top N items to show (IPs, countries, jails)
STATS_TOP_N="10"

# Show detailed metrics in dashboard
STATS_SHOW_DETAILED="true"

# ──────────────────────────────────────────────────────────────────────────
# REPORT GENERATION
# ──────────────────────────────────────────────────────────────────────────

# Enable report generation
REPORTS_ENABLED="true"

# Default report format (html|json|csv|all)
REPORTS_DEFAULT_FORMAT="html"

# Report theme (dark|light|auto)
REPORTS_THEME="dark"

# Include charts in HTML reports
REPORTS_INCLUDE_CHARTS="true"

# Chart library (chartjs|apexcharts)
REPORTS_CHART_LIBRARY="chartjs"

# Include executive summary
REPORTS_INCLUDE_SUMMARY="true"

# Include recommendations
REPORTS_INCLUDE_RECOMMENDATIONS="true"

# Compress old reports (gzip after N days)
REPORTS_COMPRESS_AFTER_DAYS="7"

# Delete old reports (after N days)
REPORTS_DELETE_AFTER_DAYS="90"

# ──────────────────────────────────────────────────────────────────────────
# EMAIL NOTIFICATIONS
# ──────────────────────────────────────────────────────────────────────────

# Enable email reports
EMAIL_ENABLED="true"

# Email recipients (comma-separated)
EMAIL_TO="admin@example.com,security@example.com"

# CC recipients (optional)
EMAIL_CC=""

# Email from address
EMAIL_FROM="nftban@$(hostname -f)"

# Email subject prefix
EMAIL_SUBJECT_PREFIX="[NFTBan]"

# Email format (html|text|both)
EMAIL_FORMAT="html"

# Attach CSV data
EMAIL_ATTACH_CSV="true"

# Attach full HTML report
EMAIL_ATTACH_HTML="false"

# Inline HTML in email body
EMAIL_INLINE_HTML="true"

# SMTP settings (if using external SMTP)
SMTP_ENABLED="false"
SMTP_SERVER="smtp.example.com"
SMTP_PORT="587"
SMTP_USERNAME=""
SMTP_PASSWORD=""
SMTP_TLS="true"

# ──────────────────────────────────────────────────────────────────────────
# AUTOMATED REPORTS (CRON SCHEDULING)
# ──────────────────────────────────────────────────────────────────────────

# Daily report
DAILY_REPORT_ENABLED="true"
DAILY_REPORT_TIME="08:00"          # HH:MM format
DAILY_REPORT_FORMAT="html"
DAILY_REPORT_EMAIL="true"

# Weekly report
WEEKLY_REPORT_ENABLED="true"
WEEKLY_REPORT_DAY="Monday"         # Monday, Tuesday, etc.
WEEKLY_REPORT_TIME="09:00"
WEEKLY_REPORT_FORMAT="html"
WEEKLY_REPORT_EMAIL="true"

# Monthly report
MONTHLY_REPORT_ENABLED="true"
MONTHLY_REPORT_DAY="1"             # Day of month (1-31)
MONTHLY_REPORT_TIME="10:00"
MONTHLY_REPORT_FORMAT="html"
MONTHLY_REPORT_EMAIL="true"

# ──────────────────────────────────────────────────────────────────────────
# ALERTS & THRESHOLDS
# ──────────────────────────────────────────────────────────────────────────

# Enable threshold alerts
ALERTS_ENABLED="true"

# High ban rate threshold (bans per hour)
ALERT_HIGH_BAN_RATE="100"

# High ban rate email notification
ALERT_HIGH_BAN_RATE_EMAIL="true"

# Repeat offender alert threshold
ALERT_REPEAT_OFFENDER_THRESHOLD="10"

# Repeat offender email notification
ALERT_REPEAT_OFFENDER_EMAIL="true"

# Failed feed update alert
ALERT_FEED_FAILURE_EMAIL="true"

# Disk space alert threshold (%)
ALERT_DISK_SPACE_THRESHOLD="90"

# Alert cooldown period (seconds, prevent spam)
ALERT_COOLDOWN="3600"

# ──────────────────────────────────────────────────────────────────────────
# PERFORMANCE & OPTIMIZATION
# ──────────────────────────────────────────────────────────────────────────

# Enable parallel processing (faster report generation)
PARALLEL_PROCESSING="true"

# Max concurrent jobs
MAX_PARALLEL_JOBS="4"

# Log rotation size (MB)
STATS_LOG_MAX_SIZE="100"

# Compress logs older than N days
STATS_LOG_COMPRESS_DAYS="7"

# ──────────────────────────────────────────────────────────────────────────
# ADVANCED ANALYTICS
# ──────────────────────────────────────────────────────────────────────────

# Enable attack pattern detection
ANALYTICS_ATTACK_PATTERNS="true"

# Time window for pattern analysis (hours)
ANALYTICS_PATTERN_WINDOW="24"

# Enable effectiveness metrics
ANALYTICS_EFFECTIVENESS="true"

# Calculate false positive rate
ANALYTICS_FALSE_POSITIVE_RATE="true"

# Track mean time to ban (detection → ban time)
ANALYTICS_MEAN_TIME_TO_BAN="true"

# Enable predictive analytics (ML-based, future feature)
ANALYTICS_PREDICTIVE="false"

# ──────────────────────────────────────────────────────────────────────────
# INTEGRATION
# ──────────────────────────────────────────────────────────────────────────

# Export to external systems
EXPORT_TO_GRAFANA="false"
EXPORT_TO_PROMETHEUS="false"
EXPORT_TO_SPLUNK="false"
EXPORT_TO_SYSLOG="false"

# Webhook for real-time notifications (optional)
WEBHOOK_ENABLED="false"
WEBHOOK_URL=""
WEBHOOK_SECRET=""

# API endpoint for external access (optional)
API_ENABLED="false"
API_PORT="8080"
API_TOKEN=""

# ──────────────────────────────────────────────────────────────────────────
# COMPLIANCE & PRIVACY
# ──────────────────────────────────────────────────────────────────────────

# GDPR compliance mode (anonymize IPs in reports)
GDPR_COMPLIANCE="false"

# Anonymize IPs (replace last octet with XXX)
ANONYMIZE_IPS="false"

# Data retention policy enforcement
ENFORCE_RETENTION_POLICY="true"

# Include privacy notice in reports
INCLUDE_PRIVACY_NOTICE="true"

# ──────────────────────────────────────────────────────────────────────────
# DEBUG & LOGGING
# ──────────────────────────────────────────────────────────────────────────

# Debug mode (verbose logging)
STATS_DEBUG="false"

# Log level (error|warn|info|debug)
STATS_LOG_LEVEL="info"

# Log to syslog
STATS_LOG_SYSLOG="false"

# Syslog facility
STATS_SYSLOG_FACILITY="local0"
```

---

## 📊 METRICS COLLECTED

### 1. **Core Metrics**
- Total bans (all time, 24h, 7d, 30d)
- Unique IPs banned
- Active bans (temp vs permanent)
- Ban rate (per hour/day/week)
- Unban events
- Whitelist entries (system, user, Cloudflare)
- Blacklist entries (persistent, user)

### 2. **Ban Source Analysis**
- Bans by source (fail2ban, manual, feeds)
- Fail2ban jail breakdown (sshd, nginx, postfix, etc.)
- Feed effectiveness (bans per feed)
- Manual ban reasons

### 3. **IP Intelligence**
- Top N banned IPs
- Repeat offenders (multiple bans)
- IP ban history timeline
- First seen / last seen
- Ban count per IP

### 4. **Geographic Analysis** (GeoIP)
- Bans by country (top N)
- Country distribution chart
- Continent breakdown
- High-risk countries identification
- Geographic heatmap data

### 5. **Temporal Analysis**
- Bans over time (hourly, daily, weekly)
- Peak attack hours
- Day of week analysis
- Attack pattern detection (coordinated attacks)
- Trend analysis (increasing/decreasing)

### 6. **System Health**
- nftables set sizes
- Log file sizes
- Feed update status
- Health check scores
- System performance metrics

### 7. **Effectiveness Metrics**
- Mean time to ban (detection → ban)
- Ban duration analysis
- Repeat offender rate
- False positive rate (if tracked)
- Appeal success rate (if appeals enabled)

### 8. **Feed Statistics**
- Active feeds count
- Total IPs from feeds
- Feed update frequency
- Feed download times
- Failed feed updates

### 9. **Security Profiles**
- Active profile
- Profile effectiveness
- DDoS events blocked
- Port scan events blocked

### 10. **Performance Metrics**
- API latency (if API enabled)
- nftables lookup time
- Log processing speed
- Report generation time

---

## 🎨 CLI COMMANDS

### `nftban stats` - Statistics Dashboard

```bash
# Show dashboard (quick overview)
nftban stats

# Detailed dashboard
nftban stats --detailed

# Show specific metric
nftban stats --metric=bans          # Total bans
nftban stats --metric=countries     # Country breakdown
nftban stats --metric=jails         # Jail statistics
nftban stats --metric=feeds         # Feed statistics

# Time window
nftban stats --since "2025-10-01"
nftban stats --last 24h             # Last 24 hours
nftban stats --last 7d              # Last 7 days
nftban stats --last 30d             # Last 30 days

# Top lists
nftban stats top ips 20             # Top 20 banned IPs
nftban stats top countries 10       # Top 10 countries
nftban stats top jails 5            # Top 5 jails

# IP-specific
nftban stats ip 192.0.2.100         # IP history
nftban stats ip 192.0.2.100 --detailed

# Recent activity
nftban stats recent 50              # Last 50 events
nftban stats recent --follow        # Tail mode (like tail -f)

# Real-time monitoring
nftban stats monitor                # Auto-refresh dashboard
nftban stats monitor --interval 10  # Refresh every 10 seconds

# Export
nftban stats --format json          # JSON output
nftban stats --format csv           # CSV output
nftban stats --output /tmp/stats.json
```

### `nftban report` - Report Generation

```bash
# Generate HTML report
nftban report generate

# Specify format
nftban report generate --format html
nftban report generate --format json
nftban report generate --format csv
nftban report generate --format pdf      # Requires wkhtmltopdf
nftban report generate --format all      # All formats

# Time window
nftban report generate --since "2025-10-01" --until "2025-10-31"
nftban report generate --last 7d
nftban report generate --last 30d

# Theme
nftban report generate --theme dark
nftban report generate --theme light

# Output location
nftban report generate --output /var/reports/monthly.html

# Email report
nftban report email admin@example.com
nftban report email admin@example.com --format html
nftban report email admin@example.com --attach-csv

# Scheduled reports
nftban report schedule daily --time "08:00" --email admin@example.com
nftban report schedule weekly --day Monday --time "09:00"
nftban report schedule monthly --day 1 --time "10:00"

# List scheduled reports
nftban report schedule list

# Remove scheduled report
nftban report schedule remove daily

# Generate all scheduled reports now (manual trigger)
nftban report run daily
nftban report run weekly
nftban report run monthly

# Preview report (open in browser)
nftban report preview
nftban report preview --format html --open

# Compare periods
nftban report compare --period1 "2025-09" --period2 "2025-10"
```

---

## 📧 EMAIL REPORT FEATURES

### Email Report Content

1. **Executive Summary**
   - Total bans this period
   - Change from previous period (%)
   - Top threats identified
   - Key recommendations

2. **Visual Dashboard**
   - Ban activity chart (timeline)
   - Top countries pie chart
   - Top IPs bar chart
   - Jail distribution chart

3. **Key Metrics Table**
   - Total bans / unique IPs
   - Active bans / expired bans
   - Repeat offenders
   - False positive rate

4. **Top Lists**
   - Top 10 banned IPs (with country)
   - Top 10 countries
   - Top 5 jails
   - Top 3 feeds

5. **Alerts & Warnings**
   - High ban rate alerts
   - Repeat offenders requiring action
   - Failed feed updates
   - Disk space warnings

6. **Recommendations**
   - IPs to permanently ban
   - Countries to consider blocking
   - Configuration suggestions
   - Security improvements

7. **Attachments**
   - CSV data file (optional)
   - Full HTML report (optional)
   - PDF report (optional)

### Email Templates

**Daily Report Email:**
```
Subject: [NFTBan] Daily Security Report - 2025-10-29

🛡️ NFTBan Daily Report
Server: web-server-01.example.com
Period: 2025-10-29 00:00 - 23:59

📊 SUMMARY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✓ Total bans: 127 (+15% vs yesterday)
✓ Unique IPs: 98
✓ Active bans: 45 (temp: 38, permanent: 7)
✓ Top country: China (34 bans)
✓ Top jail: fail2ban-sshd (67 bans)

⚠️ ALERTS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
• High ban rate detected at 14:30 (45 bans/hour)
• Repeat offender: 192.0.2.100 (banned 5 times)

💡 RECOMMENDATIONS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
1. Consider permanent ban for 192.0.2.100
2. Review SSH security (70% of bans)
3. Enable rate limiting on /api endpoint

[View Full Report] [Download CSV] [Dashboard]
```

---

## 📈 HTML REPORT DESIGN

### Modern Dashboard UI

```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>NFTBan Security Report</title>
    <!-- Chart.js -->
    <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
    <style>
        /* Dark theme by default */
        :root {
            --bg-primary: #0b0d12;
            --bg-secondary: #111826;
            --bg-tertiary: #1a202e;
            --text-primary: #e9eef5;
            --text-secondary: #9fb3c8;
            --text-muted: #6b7c93;
            --accent: #6aa9ff;
            --accent-hover: #5a99ef;
            --success: #10b981;
            --warning: #f59e0b;
            --danger: #ef4444;
            --border: #223046;
        }

        /* Light theme */
        [data-theme="light"] {
            --bg-primary: #ffffff;
            --bg-secondary: #f9fafb;
            --bg-tertiary: #f3f4f6;
            --text-primary: #111827;
            --text-secondary: #4b5563;
            --text-muted: #9ca3af;
            --border: #e5e7eb;
        }

        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
            background: var(--bg-primary);
            color: var(--text-primary);
            line-height: 1.6;
            padding: 24px;
        }

        .container {
            max-width: 1400px;
            margin: 0 auto;
        }

        header {
            margin-bottom: 32px;
        }

        h1 {
            font-size: 32px;
            font-weight: 700;
            margin-bottom: 8px;
        }

        .meta {
            color: var(--text-secondary);
            font-size: 14px;
        }

        .grid {
            display: grid;
            gap: 20px;
            margin-bottom: 32px;
        }

        .grid-2 { grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); }
        .grid-3 { grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); }
        .grid-4 { grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); }

        .card {
            background: var(--bg-secondary);
            border: 1px solid var(--border);
            border-radius: 12px;
            padding: 24px;
            box-shadow: 0 1px 3px rgba(0,0,0,0.1);
        }

        .kpi-card {
            text-align: center;
        }

        .kpi-value {
            font-size: 36px;
            font-weight: 700;
            color: var(--accent);
            margin-bottom: 4px;
        }

        .kpi-label {
            font-size: 14px;
            color: var(--text-secondary);
        }

        .kpi-change {
            font-size: 12px;
            margin-top: 4px;
        }

        .kpi-change.positive { color: var(--success); }
        .kpi-change.negative { color: var(--danger); }

        table {
            width: 100%;
            border-collapse: collapse;
        }

        th, td {
            padding: 12px;
            text-align: left;
            border-bottom: 1px solid var(--border);
        }

        th {
            font-weight: 600;
            color: var(--text-secondary);
            font-size: 13px;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }

        .chart-container {
            position: relative;
            height: 300px;
        }

        .alert {
            padding: 16px;
            border-radius: 8px;
            margin-bottom: 16px;
        }

        .alert-warning {
            background: rgba(245, 158, 11, 0.1);
            border: 1px solid var(--warning);
            color: var(--warning);
        }

        .alert-danger {
            background: rgba(239, 68, 68, 0.1);
            border: 1px solid var(--danger);
            color: var(--danger);
        }

        .btn {
            display: inline-block;
            padding: 10px 20px;
            background: var(--accent);
            color: white;
            text-decoration: none;
            border-radius: 6px;
            font-weight: 500;
            transition: background 0.2s;
        }

        .btn:hover {
            background: var(--accent-hover);
        }

        .theme-toggle {
            position: fixed;
            top: 24px;
            right: 24px;
            background: var(--bg-secondary);
            border: 1px solid var(--border);
            border-radius: 6px;
            padding: 8px 16px;
            cursor: pointer;
        }
    </style>
</head>
<body>
    <button class="theme-toggle" onclick="toggleTheme()">🌓 Theme</button>

    <div class="container">
        <header>
            <h1>🛡️ NFTBan Security Report</h1>
            <p class="meta">
                Server: <strong id="hostname">-</strong> |
                Period: <strong id="period">-</strong> |
                Generated: <strong id="generated">-</strong>
            </p>
        </header>

        <!-- KPI Cards -->
        <section>
            <h2>📊 Key Metrics</h2>
            <div class="grid grid-4" id="kpi-grid"></div>
        </section>

        <!-- Charts -->
        <section>
            <h2>📈 Activity Timeline</h2>
            <div class="card">
                <div class="chart-container">
                    <canvas id="timeline-chart"></canvas>
                </div>
            </div>
        </section>

        <div class="grid grid-2">
            <section class="card">
                <h3>🌍 Top Countries</h3>
                <div class="chart-container">
                    <canvas id="countries-chart"></canvas>
                </div>
            </section>

            <section class="card">
                <h3>🚨 Top Jails</h3>
                <div class="chart-container">
                    <canvas id="jails-chart"></canvas>
                </div>
            </section>
        </div>

        <!-- Alerts -->
        <section id="alerts-section"></section>

        <!-- Tables -->
        <section>
            <h2>🔝 Top Banned IPs</h2>
            <div class="card">
                <table id="top-ips-table"></table>
            </div>
        </section>

        <!-- Recommendations -->
        <section id="recommendations-section"></section>
    </div>

    <script>
        // Data will be injected here by bash script
        window.__NFTBAN_DATA__ = {
            // Data structure defined below
        };

        // Theme toggle
        function toggleTheme() {
            const current = document.documentElement.getAttribute('data-theme');
            document.documentElement.setAttribute('data-theme', current === 'light' ? 'dark' : 'light');
        }

        // Render dashboard
        // ... Chart.js code ...
    </script>
</body>
</html>
```

### JSON Data Schema

```json
{
  "schema_version": "1.0.0",
  "report": {
    "type": "daily|weekly|monthly",
    "period": {
      "since": "2025-10-29T00:00:00Z",
      "until": "2025-10-29T23:59:59Z"
    },
    "generated_at": "2025-10-29T23:59:59Z",
    "hostname": "web-server-01.example.com"
  },
  "summary": {
    "total_bans": 127,
    "unique_ips": 98,
    "active_bans": 45,
    "temp_bans": 38,
    "permanent_bans": 7,
    "unbans": 82,
    "whitelist_total": 54,
    "blacklist_total": 60,
    "change_vs_previous": 15.3
  },
  "ban_sources": {
    "fail2ban": 89,
    "manual": 12,
    "feeds": 26
  },
  "jails": [
    {"name": "fail2ban-sshd", "count": 67},
    {"name": "fail2ban-nginx", "count": 22}
  ],
  "top_ips": [
    {
      "ip": "192.0.2.100",
      "country": "CN",
      "bans": 5,
      "first_seen": "2025-10-25T10:30:00Z",
      "last_seen": "2025-10-29T14:30:00Z"
    }
  ],
  "top_countries": [
    {"country": "CN", "name": "China", "count": 34},
    {"country": "RU", "name": "Russia", "count": 21}
  ],
  "timeline": [
    {"timestamp": "2025-10-29T00:00:00Z", "bans": 5},
    {"timestamp": "2025-10-29T01:00:00Z", "bans": 3}
  ],
  "feeds": [
    {
      "name": "FIREHOL_LEVEL1",
      "status": "active",
      "ips": 45234,
      "last_update": "2025-10-29T06:00:00Z"
    }
  ],
  "health": {
    "score": 85,
    "issues": []
  },
  "alerts": [
    {
      "severity": "warning",
      "message": "High ban rate detected at 14:30 (45 bans/hour)",
      "timestamp": "2025-10-29T14:30:00Z"
    }
  ],
  "recommendations": [
    {
      "priority": "high",
      "action": "permanent_ban",
      "target": "192.0.2.100",
      "reason": "Repeat offender (5 bans)"
    }
  ],
  "performance": {
    "report_generation_time_ms": 1250,
    "nftables_lookup_time_ms": 15,
    "total_events_processed": 127
  }
}
```

---

## 🤖 AUTOMATED CRON JOBS

**File:** `/etc/cron.d/nftban-stats`

```bash
# NFTBan Statistics & Reports Automation
# Managed by: nftban report schedule

SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Daily report (08:00 AM)
0 8 * * * root /usr/sbin/nftban report run daily >> /var/log/nftban/cron.log 2>&1

# Weekly report (Monday 09:00 AM)
0 9 * * 1 root /usr/sbin/nftban report run weekly >> /var/log/nftban/cron.log 2>&1

# Monthly report (1st of month, 10:00 AM)
0 10 1 * * root /usr/sbin/nftban report run monthly >> /var/log/nftban/cron.log 2>&1

# Hourly stats snapshot (for trending)
*/60 * * * * root /usr/sbin/nftban stats snapshot >> /var/log/nftban/cron.log 2>&1

# Daily log cleanup (03:00 AM)
0 3 * * * root /usr/sbin/nftban stats cleanup --days 90 >> /var/log/nftban/cron.log 2>&1

# Alert monitoring (every 15 minutes)
*/15 * * * * root /usr/sbin/nftban stats check-alerts >> /var/log/nftban/cron.log 2>&1
```

---

## 🚀 IMPLEMENTATION PLAN

### Phase 1: Core Stats Engine (4 hours)
- [ ] Create `nftban_stats.sh` core module
- [ ] Implement metrics collection functions
- [ ] Add caching layer
- [ ] Database/JSON storage implementation

### Phase 2: CLI Commands (3 hours)
- [ ] Implement `cmd_stats.sh`
- [ ] Implement `cmd_report.sh`
- [ ] Add all command options
- [ ] Integrate with main CLI

### Phase 3: HTML Reports (3 hours)
- [ ] Create HTML template
- [ ] Add Chart.js integration
- [ ] Implement theme switching
- [ ] Responsive design

### Phase 4: Email System (2 hours)
- [ ] Email report template
- [ ] SMTP integration
- [ ] Attachment handling
- [ ] Email scheduling logic

### Phase 5: Cron Automation (1 hour)
- [ ] Create cron file
- [ ] Schedule management commands
- [ ] Log rotation setup

### Phase 6: Testing (2 hours)
- [ ] Test on lab servers
- [ ] Generate sample reports
- [ ] Verify email delivery
- [ ] Performance testing

**Total Estimated Time:** 15 hours

---

## ✅ SUCCESS CRITERIA

- [ ] Stats dashboard displays correctly with all metrics
- [ ] HTML reports generate with charts
- [ ] JSON/CSV export works
- [ ] Email reports send successfully
- [ ] Cron jobs run automatically
- [ ] Performance: Report generation <5 seconds
- [ ] Handles 100k+ ban events efficiently
- [ ] GeoIP integration works
- [ ] All alerts trigger correctly
- [ ] Works on all 3 lab servers

---

**Ready to implement! 🚀**
