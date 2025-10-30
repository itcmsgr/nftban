# NFTBan v0.10.0 - Phase 3: Report Engine Design
**Date:** 2025-10-30
**Status:** 🔧 IN DESIGN
**Previous:** Phase 2A Complete (Stats Dashboard Fixed)

---

## 🎯 Phase 3 Goal: Unified Report Mechanism

Create a centralized report engine that can:
1. Generate reports from ANY existing report module (health, module, fhs, services, stats)
2. Output to multiple formats (text, JSON, HTML)
3. Save to files
4. Send via email
5. Schedule automated reports (future: systemd timers)

---

## 📋 Requirements

### **Functional Requirements:**

1. **Report Generation:**
   - Generate reports from: `health`, `module`, `fhs`, `services`, `stats`
   - Support all output modes: `summary`, `detailed`, `json`
   - Allow multiple reports in a single output

2. **Output Formats:**
   - **Text:** Plain text for terminal/logs
   - **JSON:** Machine-readable for APIs/monitoring
   - **HTML:** Formatted for email/web dashboards

3. **Output Destinations:**
   - **Terminal:** Default output (stdout)
   - **File:** Save to specified path
   - **Email:** Send via mail command

4. **Report Options:**
   - Custom title/header
   - Timestamp
   - Hostname
   - Multiple report sections
   - Summary or detailed mode

### **Non-Functional Requirements:**

1. **Backward Compatibility:**
   - All existing commands still work
   - New `nftban report` command is additive

2. **Modular Design:**
   - Easy to add new report sources
   - Easy to add new output formats

3. **Error Handling:**
   - Graceful fallback if module unavailable
   - Clear error messages

---

## 🏗️ Architecture

### **Component Structure:**

```
┌─────────────────────────────────────────────────────────────┐
│  User Commands                                              │
│  ├─ nftban report health --format html --output file.html  │
│  ├─ nftban report all --email admin@example.com            │
│  └─ nftban report custom --sections health,module,fhs      │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│  CLI Handler: cmd_report.sh                                 │
│  - Parse arguments                                          │
│  - Validate options                                         │
│  - Call report engine                                       │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│  Report Engine: nftban_report_engine.sh                     │
│  ├─ nftban_report_generate()     - Main orchestrator       │
│  ├─ nftban_report_collect()      - Gather data from modules│
│  ├─ nftban_report_render_text()  - Text formatter          │
│  ├─ nftban_report_render_json()  - JSON formatter          │
│  ├─ nftban_report_render_html()  - HTML formatter          │
│  ├─ nftban_report_save_file()    - File writer             │
│  └─ nftban_report_send_email()   - Email sender            │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│  Existing Report Modules (Data Sources)                     │
│  ├─ nftban_health_render_summary/json                      │
│  ├─ nftban_module_report_summary/json                      │
│  ├─ nftban_fhs_report_summary/json                         │
│  ├─ nftban_services_report_summary/json                    │
│  └─ nftban_stats_dashboard                                 │
└─────────────────────────────────────────────────────────────┘
```

---

## 📝 Command Interface Design

### **Basic Usage:**

```bash
# Generate health report to terminal (default: text)
nftban report health

# Generate health report as JSON
nftban report health --format json

# Generate health report and save to file
nftban report health --output /var/log/nftban/health-report.txt

# Generate health report as HTML and save
nftban report health --format html --output /var/log/nftban/health-report.html

# Generate health report and email it
nftban report health --email admin@example.com

# Generate HTML health report and email it
nftban report health --format html --email admin@example.com
```

### **Multiple Sections:**

```bash
# Generate report with multiple sections
nftban report all
# Includes: health, module, fhs, services, stats

# Generate custom report with specific sections
nftban report custom --sections health,module,services

# Generate full report as HTML and email
nftban report all --format html --email admin@example.com
```

### **Report Options:**

```bash
# Add custom title
nftban report health --title "Daily Health Check"

# Include/exclude timestamp
nftban report health --no-timestamp

# Detailed vs summary mode
nftban report health --mode summary   # One-line summaries
nftban report health --mode detailed  # Full detailed output (default)
```

---

## 🔧 Implementation Plan

### **Step 1: Create Core Report Engine**

**File:** `/usr/lib/nftban/core/nftban_report_engine.sh`

**Functions to implement:**

1. `nftban_report_init()` - Initialize report engine, load dependencies
2. `nftban_report_generate()` - Main orchestrator
3. `nftban_report_collect_health()` - Collect health data
4. `nftban_report_collect_module()` - Collect module data
5. `nftban_report_collect_fhs()` - Collect FHS data
6. `nftban_report_collect_services()` - Collect services data
7. `nftban_report_collect_stats()` - Collect stats data
8. `nftban_report_render_text()` - Format as text
9. `nftban_report_render_json()` - Format as JSON
10. `nftban_report_render_html()` - Format as HTML
11. `nftban_report_save_file()` - Save to file
12. `nftban_report_send_email()` - Send via email

### **Step 2: Create CLI Handler**

**File:** `/usr/lib/nftban/cli/cmd_report.sh`

**Subcommands:**
- `nftban report health` - Health report only
- `nftban report module` - Module report only
- `nftban report fhs` - FHS report only
- `nftban report services` - Services report only
- `nftban report stats` - Stats report only
- `nftban report all` - All reports
- `nftban report custom --sections health,module` - Custom sections

**Options:**
- `--format text|json|html` - Output format (default: text)
- `--output FILE` - Save to file
- `--email ADDRESS` - Send via email
- `--title TITLE` - Custom report title
- `--mode summary|detailed` - Summary or detailed (default: detailed)
- `--no-timestamp` - Exclude timestamp

### **Step 3: HTML Template**

Create attractive HTML template with:
- CSS styling (embedded)
- Responsive design
- Color-coded status (green=OK, yellow=WARNING, red=ERROR)
- Collapsible sections
- Professional header/footer

### **Step 4: Email Integration**

Use `mail` command (mailx) to send reports:
- Support HTML email (MIME multipart)
- Support plain text fallback
- Custom subject line
- From/To/CC/BCC support

### **Step 5: Testing**

Test on all lab servers:
- Generate text reports
- Generate JSON reports
- Generate HTML reports
- Save to files
- Send emails (if mail configured)

---

## 📄 Data Collection Strategy

### **How to Collect Data from Existing Modules:**

Each existing module already has summary/json functions. The report engine will:

1. **Load the module:**
   ```bash
   source /usr/lib/nftban/core/nftban_health.sh
   ```

2. **Run the check (if needed):**
   ```bash
   nftban_health_check_all >/dev/null 2>&1 || exit_code=$?
   ```

3. **Collect the output:**
   ```bash
   # Summary mode
   summary_output=$(nftban_health_render_summary)

   # JSON mode
   json_output=$(nftban_health_render_json)
   ```

4. **Store in report data structure:**
   ```bash
   declare -A REPORT_DATA
   REPORT_DATA["health_summary"]="$summary_output"
   REPORT_DATA["health_json"]="$json_output"
   REPORT_DATA["health_exit_code"]="$exit_code"
   ```

---

## 🎨 HTML Template Design

### **Structure:**

```html
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>NFTBan Report - {HOSTNAME} - {DATE}</title>
    <style>
        body { font-family: monospace; background: #1e1e1e; color: #d4d4d4; }
        .container { max-width: 1200px; margin: 0 auto; padding: 20px; }
        .header { background: #2d2d30; padding: 20px; border-radius: 5px; }
        .section { background: #252526; margin: 20px 0; padding: 20px; border-radius: 5px; }
        .status-ok { color: #4ec9b0; }
        .status-warning { color: #ce9178; }
        .status-error { color: #f48771; }
        pre { background: #1e1e1e; padding: 15px; border-radius: 3px; overflow-x: auto; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>NFTBan System Report</h1>
            <p>Hostname: {HOSTNAME}</p>
            <p>Generated: {TIMESTAMP}</p>
        </div>

        <div class="section">
            <h2>Health Status</h2>
            <div class="status-{STATUS}">
                {HEALTH_SUMMARY}
            </div>
            <details>
                <summary>Details</summary>
                <pre>{HEALTH_DETAILED}</pre>
            </details>
        </div>

        <!-- More sections... -->
    </div>
</body>
</html>
```

### **Features:**
- Dark theme (matches terminal aesthetic)
- Monospace font (technical feel)
- Color-coded status (green/yellow/red)
- Collapsible details (`<details>` tag)
- Responsive layout
- Print-friendly CSS

---

## 📧 Email Format

### **Plain Text Email:**

```
Subject: NFTBan Report - lab.example.test - 2025-10-30

═══════════════════════════════════════════════════════════════
  NFTBan System Report
═══════════════════════════════════════════════════════════════

Hostname: lab.example.test
Generated: 2025-10-30 06:30:45

[HEALTH]
Health: ERROR (1 errors, 2 warnings)

[MODULES]
Modules: 25 OK, 0 errors

[FHS]
FHS: 3 OK, 14 errors, 4 missing

[SERVICES]
Services: 0/0 running, 0/0 tools

[STATS]
Active Bans: 5
Whitelist Entries: 3

═══════════════════════════════════════════════════════════════
Generated with NFTBan v0.10.0
═══════════════════════════════════════════════════════════════
```

### **HTML Email:**

```bash
# MIME multipart email with HTML and text fallback
mail -s "$(echo -e "NFTBan Report - lab.example.test\nContent-Type: text/html")" \
     admin@example.com < report.html
```

---

## 🔒 Security Considerations

1. **Email Credentials:**
   - Use system mail command (no credentials in scripts)
   - Rely on system mail configuration

2. **File Permissions:**
   - Reports may contain sensitive data
   - Default permissions: 0600 (owner read/write only)
   - Configurable via option

3. **Path Traversal:**
   - Validate output file paths
   - Prevent writing outside allowed directories

4. **Command Injection:**
   - Sanitize email addresses
   - Validate all user input

---

## 📊 JSON Output Format

### **Structure:**

```json
{
  "report": {
    "hostname": "lab.example.test",
    "timestamp": "2025-10-30T06:30:45+00:00",
    "format": "json",
    "sections": ["health", "module", "fhs", "services", "stats"]
  },
  "health": {
    "status": "error",
    "exit_code": 2,
    "summary": "Health: ERROR (1 errors, 2 warnings)",
    "details": { ... }
  },
  "module": {
    "status": "ok",
    "exit_code": 0,
    "summary": "Modules: 25 OK, 0 errors",
    "details": { ... }
  },
  "fhs": {
    "status": "error",
    "exit_code": 2,
    "summary": "FHS: 3 OK, 14 errors, 4 missing",
    "details": { ... }
  },
  "services": {
    "status": "ok",
    "exit_code": 0,
    "summary": "Services: 0/0 running, 0/0 tools",
    "details": { ... }
  },
  "stats": {
    "active_bans": 5,
    "whitelist_entries": 3,
    "total_bans": 0,
    "unique_ips": 0
  }
}
```

---

## 🔄 Integration with Existing Commands

### **Backward Compatibility:**

All existing commands continue to work:
```bash
nftban health check        # Still works
nftban module summary      # Still works
nftban fhs json            # Still works
```

### **New Report Command:**

New `nftban report` command provides centralized reporting:
```bash
nftban report health       # Same data as 'nftban health check'
nftban report all          # Combine all reports
```

### **Difference:**

- **Existing commands:** Direct access to specific module
- **Report command:** Centralized, formatted, multi-destination output

---

## 📅 Future Enhancements (Post Phase 3)

1. **Systemd Timer Integration:**
   - Daily/weekly/monthly scheduled reports
   - Automatic email delivery
   - Configurable schedule

2. **Report Templates:**
   - Custom report templates
   - User-defined sections
   - Template variables

3. **Dashboard Integration:**
   - Web dashboard to view reports
   - Historical report archive
   - Interactive charts

4. **Advanced Filtering:**
   - Filter by severity (errors only)
   - Filter by component
   - Time range selection

5. **Multiple Email Recipients:**
   - Distribution lists
   - CC/BCC support
   - Per-section recipients

---

## 🎯 Success Criteria

Phase 3 is complete when:

1. ✅ `nftban report health` generates text report
2. ✅ `nftban report all` generates combined report
3. ✅ `--format json` outputs valid JSON
4. ✅ `--format html` outputs attractive HTML
5. ✅ `--output FILE` saves to file with correct permissions
6. ✅ `--email ADDRESS` sends email (if mail configured)
7. ✅ All tests pass on 3 lab servers
8. ✅ Documentation complete

---

## 📝 Implementation Order

1. **Step 1:** Create core report engine with text output (30 min)
2. **Step 2:** Add data collection for all modules (30 min)
3. **Step 3:** Add JSON output format (20 min)
4. **Step 4:** Add HTML output format (40 min)
5. **Step 5:** Add file output support (15 min)
6. **Step 6:** Add email support (25 min)
7. **Step 7:** Create CLI handler (30 min)
8. **Step 8:** Test on all servers (20 min)
9. **Step 9:** Create documentation (20 min)

**Total Estimated Time:** 3.5 hours

---

**Status:** 🔧 Design Complete - Ready to Implement

**Next:** Create `/usr/lib/nftban/core/nftban_report_engine.sh`

**EOF**
