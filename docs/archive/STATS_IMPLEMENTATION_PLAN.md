# NFTBan v0.10.0 - Stats & Metrics Implementation Plan

**Date:** 2025-10-29
**Status:** Ready for Implementation
**Architecture:** FHS Compliant v0.10.0

---

## 🎯 OVERVIEW

Build production-grade statistics and reporting system integrated with v0.10.0 architecture.

**Key Features:**
- Real-time dashboard with comprehensive metrics
- Beautiful HTML reports with charts (Chart.js)
- Automated email reports (daily/weekly/monthly via cron)
- Multiple export formats (HTML, JSON, CSV)
- GeoIP country analysis
- Attack pattern detection
- Performance optimized with caching

---

## 📁 FILE STRUCTURE (FHS v0.10.0 Compliant)

```
/etc/nftban/conf.d/
├── stats.conf                          # NEW - Stats configuration

/usr/lib/nftban/core/
├── nftban_stats.sh                     # NEW - Core stats engine
├── nftban_mail.sh                      # EXISTS - Use for emails

/usr/lib/nftban/cli/
├── cmd_stats.sh                        # NEW - Stats CLI (nftban stats)
├── cmd_report.sh                       # NEW - Report CLI (nftban report)

/usr/share/nftban/templates/reports/
├── stats_dashboard.html                # NEW - Main stats HTML template
├── stats_email.html                    # NEW - Email-friendly template
├── port_report.html                    # EXISTS - Keep pattern
├── module_report.html                  # EXISTS - Keep pattern
├── fhs_report.html                     # EXISTS - Keep pattern

/var/lib/nftban/
├── metrics/                            # NEW - Metrics storage
│   └── cache/                          # NEW - Cached stats (5min TTL)
├── reports/                            # EXISTS - Generated reports
│   ├── daily/                          # NEW - Daily reports
│   ├── weekly/                         # NEW - Weekly reports
│   └── monthly/                        # NEW - Monthly reports
└── snapshots/                          # NEW - Hourly snapshots

/var/log/nftban/
├── ban.log                             # EXISTS - Main data source
├── stats.log                           # NEW - Stats module log
└── email.log                           # NEW - Email delivery log
```

---

## ⚙️ CONFIGURATION FILE

**File:** `/etc/nftban/conf.d/stats.conf`

**Key Settings:**
```bash
# Core
STATS_ENABLED="true"
STATS_CACHE_TTL="300"                   # 5 minutes
STATS_RETENTION_DAYS="90"

# GeoIP
STATS_GEOIP_ENABLED="true"              # Requires nftban-geoip binary

# Dashboard
STATS_TOP_N="10"                        # Top N items to show

# Reports
REPORTS_ENABLED="true"
REPORTS_DEFAULT_FORMAT="html"
REPORTS_THEME="dark"                    # dark|light
REPORTS_INCLUDE_CHARTS="true"

# Email (integrates with mail.conf)
STATS_EMAIL_ENABLED="true"
STATS_EMAIL_RECIPIENTS=""               # Defaults to NFTBAN_MAIL_RECIPIENT
STATS_EMAIL_DAILY="true"
STATS_EMAIL_DAILY_TIME="08:00"
STATS_EMAIL_WEEKLY="true"
STATS_EMAIL_WEEKLY_DAY="Monday"
STATS_EMAIL_WEEKLY_TIME="09:00"
STATS_EMAIL_MONTHLY="true"
STATS_EMAIL_MONTHLY_DAY="1"
STATS_EMAIL_MONTHLY_TIME="10:00"

# Alerts
STATS_ALERT_HIGH_BAN_RATE="100"         # bans/hour
STATS_ALERT_REPEAT_OFFENDER_THRESHOLD="5"
```

---

## 🔧 CORE MODULE: nftban_stats.sh

**Purpose:** Core statistics engine
**Pattern:** Follow existing core modules (nftban_mail.sh, nftban_health.sh)

**Key Functions:**

### Metrics Collection
```bash
stats_count_bans()              # Total bans in time window
stats_count_unique_ips()        # Unique IPs banned
stats_count_active_bans()       # Currently active in nftables
stats_count_whitelist()         # Whitelist entries

# Analysis
stats_ban_sources()             # fail2ban, manual, feeds breakdown
stats_top_jails()               # Top Fail2Ban jails
stats_top_ips()                 # Top banned IPs with GeoIP
stats_top_countries()           # Top countries (requires nftban-geoip)
stats_ip_history()              # Full history for specific IP

# Temporal
stats_timeline()                # Hourly/daily aggregation
```

### Dashboard & Export
```bash
stats_generate_dashboard()      # Terminal dashboard
stats_recent_activity()         # Recent ban events
stats_export_json()             # JSON export
stats_export_csv()              # CSV export
```

### Monitoring & Alerts
```bash
stats_check_high_ban_rate()     # Alert if threshold exceeded
stats_find_repeat_offenders()   # IPs with multiple bans
```

### Maintenance
```bash
stats_cleanup_logs()            # Rotate logs, delete old data
stats_create_snapshot()         # Hourly snapshot for trending
stats_clear_cache()             # Clear cached metrics
```

---

## 🎨 CLI COMMANDS

### `nftban stats` - Statistics Dashboard

```bash
# Quick dashboard
nftban stats

# Detailed dashboard
nftban stats --detailed

# Specific metric
nftban stats --metric=bans
nftban stats --metric=countries
nftban stats --metric=jails

# Time window
nftban stats --since "2025-10-01"
nftban stats --last 24h
nftban stats --last 7d
nftban stats --last 30d

# Top lists
nftban stats top ips 20
nftban stats top countries 10
nftban stats top jails 5

# IP history
nftban stats ip 192.0.2.100
nftban stats ip 192.0.2.100 --detailed

# Recent activity
nftban stats recent 50
nftban stats recent --follow        # tail -f mode

# Real-time monitoring
nftban stats monitor                # Auto-refresh
nftban stats monitor --interval 10

# Export
nftban stats --format json
nftban stats --format csv
nftban stats --output /tmp/stats.json

# Cache management
nftban stats clear-cache
```

### `nftban report` - Report Generation & Scheduling

```bash
# Generate report
nftban report generate
nftban report generate --format html
nftban report generate --format json
nftban report generate --format csv
nftban report generate --format all

# Time window
nftban report generate --last 7d
nftban report generate --last 30d
nftban report generate --since "2025-10-01" --until "2025-10-31"

# Theme
nftban report generate --theme dark
nftban report generate --theme light

# Output location
nftban report generate --output /var/reports/monthly.html

# Email report
nftban report email admin@example.com
nftban report email admin@example.com --format html
nftban report email admin@example.com --attach-csv

# Schedule management
nftban report schedule daily --time "08:00" --email admin@example.com
nftban report schedule weekly --day Monday --time "09:00"
nftban report schedule monthly --day 1 --time "10:00"
nftban report schedule list
nftban report schedule remove daily

# Manual trigger of scheduled reports
nftban report run daily
nftban report run weekly
nftban report run monthly

# Preview in browser
nftban report preview
```

---

## 📊 HTML REPORT TEMPLATE

**File:** `/usr/share/nftban/templates/reports/stats_dashboard.html`

**Features:**
- Modern dark/light theme toggle
- Responsive design
- Chart.js integration
- Interactive charts (timeline, pie, bar)
- Print-friendly
- Mobile-friendly

**Sections:**
1. **Executive Summary** - KPI cards (total bans, unique IPs, active bans)
2. **Activity Timeline** - Line chart showing bans over time
3. **Geographic Analysis** - Pie chart of top countries
4. **Jail Statistics** - Bar chart of top jails
5. **Top Banned IPs** - Table with country, ban count
6. **Alerts & Warnings** - High ban rate, repeat offenders
7. **Recommendations** - IPs to permanently ban, configuration suggestions

**Data Injection:**
```javascript
window.__NFTBAN_DATA__ = {
  // JSON data injected by bash script
};
```

---

## 📧 EMAIL INTEGRATION

**Uses existing mail infrastructure:**
- `nftban_mail.sh` - Core email functions
- `/etc/nftban/conf.d/mail.conf` - Email configuration
- `/usr/share/nftban/templates/mail/` - Email templates

**Email Report Features:**
1. **Inline HTML** - Beautiful email with embedded charts
2. **Attachments** - Optional CSV/HTML file attachments
3. **Plain text fallback** - For email clients without HTML support
4. **Subject customization** - `[NFTBan] Daily Report - 2025-10-29`

**Email Template:** `/usr/share/nftban/templates/mail/stats_email.html`
- Simplified version of dashboard
- Email-safe CSS (no external resources)
- Mobile-responsive
- Chart.js rendered as static images (base64 embedded)

---

## 🤖 AUTOMATED CRON SCHEDULING

**File:** `/etc/cron.d/nftban-stats`

```bash
# Daily report (08:00 AM)
0 8 * * * root /usr/sbin/nftban report run daily

# Weekly report (Monday 09:00 AM)
0 9 * * 1 root /usr/sbin/nftban report run weekly

# Monthly report (1st of month, 10:00 AM)
0 10 1 * * root /usr/sbin/nftban report run monthly

# Hourly snapshot (for trending)
0 * * * * root /usr/sbin/nftban stats snapshot

# Daily log cleanup (03:00 AM)
0 3 * * * root /usr/sbin/nftban stats cleanup --days 90

# Alert monitoring (every 15 minutes)
*/15 * * * * root /usr/sbin/nftban stats check-alerts
```

**Managed by CLI:**
```bash
nftban report schedule daily --time "08:00"
# Creates/updates cron entry
```

---

## 🔄 DATA FLOW

```
[ban.log] ──┐
            ├──> [nftban_stats.sh] ──┐
[nftables]──┤    (Core Engine)       ├──> [Dashboard] (terminal)
            │                        │
[feeds]─────┘                        ├──> [JSON Export]
                                     │
[GeoIP]─────────────────────────────┤├──> [CSV Export]
                                     │
                                     └──> [HTML Report] ──> [Email]
```

**Data Sources:**
1. `/var/log/nftban/ban.log` - All ban/unban events
2. nftables sets - Active bans (runtime + static)
3. Feed data - Feed effectiveness
4. GeoIP database - Country lookups

**Cache Layer:**
- 5-minute TTL on expensive queries
- Cleared automatically or on-demand
- Stored in `/var/lib/nftban/metrics/cache/`

---

## 🚀 IMPLEMENTATION PHASES

### Phase 1: Core Stats Engine (Day 1)
**Time:** 4-5 hours

- [ ] Create `/etc/nftban/conf.d/stats.conf`
- [ ] Create `/usr/lib/nftban/core/nftban_stats.sh`
  - [ ] Metrics collection functions
  - [ ] Dashboard generation
  - [ ] Export functions (JSON, CSV)
  - [ ] Cache management
- [ ] Test basic metrics collection on lab servers

### Phase 2: CLI Commands (Day 1-2)
**Time:** 3-4 hours

- [ ] Create `/usr/lib/nftban/cli/cmd_stats.sh`
  - [ ] Dashboard display
  - [ ] Top lists (IPs, countries, jails)
  - [ ] IP history
  - [ ] Recent activity
  - [ ] Monitor mode
  - [ ] Export commands
- [ ] Create `/usr/lib/nftban/cli/cmd_report.sh`
  - [ ] Report generation
  - [ ] Email sending
  - [ ] Schedule management
- [ ] Test all CLI commands

### Phase 3: HTML Report Template (Day 2)
**Time:** 3-4 hours

- [ ] Create `/usr/share/nftban/templates/reports/stats_dashboard.html`
  - [ ] Modern UI (dark/light theme)
  - [ ] Chart.js integration
  - [ ] Responsive design
  - [ ] Data injection mechanism
- [ ] Create bash function to populate template with data
- [ ] Test HTML generation and rendering

### Phase 4: Email Integration (Day 2-3)
**Time:** 2-3 hours

- [ ] Create `/usr/share/nftban/templates/mail/stats_email.html`
- [ ] Integrate with `nftban_mail.sh`
- [ ] Test email sending with HTML/attachments
- [ ] Verify delivery on multiple email clients

### Phase 5: Cron Automation (Day 3)
**Time:** 1-2 hours

- [ ] Create cron management functions
- [ ] Create `/etc/cron.d/nftban-stats` template
- [ ] Implement schedule commands
- [ ] Test automated report generation

### Phase 6: Testing & Refinement (Day 3)
**Time:** 2-3 hours

- [ ] Test on all 3 lab servers
- [ ] Generate sample reports with real data
- [ ] Verify email delivery
- [ ] Performance testing (100k+ events)
- [ ] Fix any bugs
- [ ] Update documentation

---

## ✅ SUCCESS CRITERIA

- [ ] Stats dashboard displays correctly with all metrics
- [ ] HTML reports generate with interactive charts
- [ ] JSON/CSV export works correctly
- [ ] Email reports send successfully (HTML + attachments)
- [ ] Cron jobs create and run automatically
- [ ] GeoIP integration works (if nftban-geoip available)
- [ ] Performance: Report generation <5 seconds for 10k events
- [ ] Handles 100k+ ban events efficiently
- [ ] All alerts trigger correctly
- [ ] Works on all 3 lab servers (lab, lab1, lab2)
- [ ] FHS compliant (passes `nftban fhs` check)

---

## 🎯 KEY DESIGN DECISIONS

### 1. **FHS Compliance**
All files follow v0.10.0 FHS architecture:
- Configs in `/etc/nftban/conf.d/`
- Code in `/usr/lib/nftban/`
- Templates in `/usr/share/nftban/`
- Data in `/var/lib/nftban/`
- Logs in `/var/log/nftban/`

### 2. **Integration with Existing Systems**
- Use `nftban_mail.sh` for emails (don't reinvent)
- Follow existing report patterns (port, module, fhs reports)
- Respect existing config structure
- Use existing output module for formatting

### 3. **Performance**
- Cache expensive queries (5min TTL)
- Use efficient awk/grep for log parsing
- Avoid loading entire log into memory
- Parallel processing where possible

### 4. **Security**
- Validate all inputs
- Sanitize data for HTML injection
- Respect file permissions (FHS standards)
- No secrets in logs or reports

### 5. **Maintainability**
- Clear function naming
- Comprehensive comments
- Follow v0.10.0 module patterns
- SPDX headers on all files

---

## 📝 NOTES

### Data Source
- Primary: `/var/log/nftban/ban.log`
- Format: `Timestamp|ID|Jail|IP|Reason|Action|Timeout`
- Actions: BANNED, UNBANNED, WHITELISTED, PERMANENT_BAN

### GeoIP Integration
- Optional (requires nftban-geoip binary)
- If not available, shows "--" for country
- Gracefully degrades

### Email Format
- HTML by default (NFTBAN_MAIL_USE_HTML="YES")
- Plain text fallback available
- Attachments allowed (CSV, HTML)
- Uses existing mail templates

### Cron Management
- Stored in `/etc/cron.d/nftban-stats`
- Managed by `nftban report schedule` commands
- Logs to `/var/log/nftban/cron.log`

---

## 🔗 DEPENDENCIES

**Required:**
- bash >= 5.0
- nft (nftables)
- jq (JSON processing)
- awk, grep, sort, sed
- date (with --iso-8601)

**Optional:**
- nftban-geoip (for country analysis)
- Chart.js (CDN or local copy)
- wkhtmltopdf (for PDF export - future)
- sendmail/postfix (for email)

---

## 📚 REFERENCES

**Existing Modules to Follow:**
- `/usr/lib/nftban/core/nftban_mail.sh` - Email pattern
- `/usr/lib/nftban/core/nftban_report_fhs.sh` - Report pattern
- `/usr/lib/nftban/cli/cmd_search.sh` - CLI pattern
- `/etc/nftban/conf.d/mail.conf` - Config pattern

**Design Documents:**
- `STATS_METRICS_DESIGN_V10.md` - Detailed design
- `TODO_NEXT_SESSION.md` - Implementation checklist

---

**Ready to implement! 🚀**

**Estimated Total Time:** 15-20 hours (2-3 days)
**Priority:** CRITICAL (blocking v0.10.0 release)
