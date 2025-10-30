# NFTBan v0.10.0 - FHS Paths & Ban Workflow CLARIFIED
**Date:** 2025-10-27
**Status:** 🎯 CRITICAL CLARIFICATION
**Purpose:** Proper FHS paths + Clear ban workflow + Mail feature

═══════════════════════════════════════════════════════════════════════════════

## 📁 PROPER FHS DIRECTORY STRUCTURE (CORRECTED)

### ❌ WRONG (Old/Incorrect Paths):
```
/tmp/nftban-export-*          # Wrong! /tmp is temporary, gets cleared
/var/log/nftban/              # Wrong! Should be in proper log location
```

### ✅ CORRECT (FHS-Compliant v0.10.0 Paths):

```
/etc/nftban/                           # Configuration (user edits)
├── nftban.conf                        # Main config
├── nftban.conf.local                  # User overrides
├── whitelist.d/                       # Whitelist configs
│   ├── 00-localhost.conf
│   ├── 10-cloudflare.conf
│   ├── 20-office.conf
│   └── 99-emergency.conf
├── blacklist.d/                       # Blacklist configs
│   ├── 10-persistent-offenders.conf
│   ├── 20-geoip-blocked.conf
│   └── 50-user-manual.conf
├── feeds.d/                           # Threat feeds
├── geoip.d/                           # GeoIP config
└── ports.d/                           # Port configs

/var/lib/nftban/                       # State data (compiled, cache)
├── compiled/                          # Compiled/deduplicated lists
│   ├── whitelist.txt
│   ├── blacklist.txt
│   └── feeds.txt
├── cache/                             # Temporary cache
│   ├── geoip-lookups.db              # GeoIP lookup cache (fast)
│   └── file-hashes.db                # File change detection
├── exports/                           # Exported dumps (not /tmp!)
│   ├── export-20251027-120000/
│   └── export-20251027-130000/
└── metadata.json                      # System state metadata

/var/log/nftban/                       # Logs (systemd journal compatible)
├── nftban.log                         # Main log
├── ban.log                            # Ban/unban history
├── whitelist-overrides.log            # Auto-removed IPs (whitelist won)
├── emergency.log                      # Emergency actions
├── sync.log                           # File sync operations
└── geoip.log                          # GeoIP lookups

/var/backups/nftban/                   # Backups (not /tmp!)
├── backup-20251027-120000.tar.gz
├── backup-20251026-180000.tar.gz
└── backup-latest.tar.gz -> backup-20251027-120000.tar.gz

/var/spool/nftban/                     # Mail queue (reports to send)
└── reports/
    ├── daily-report-20251027.html.gz
    └── weekly-report-20251027.html.gz

/run/nftban/                           # Runtime data (PID files, sockets)
├── nftban.pid                         # Main process PID
└── nftban.sock                        # Unix socket (if daemon mode)
```

### Key FHS Principles:

```
/etc/nftban/         → Configuration (admin edits)
/var/lib/nftban/     → Persistent state data (compiled lists, cache)
/var/log/nftban/     → Log files
/var/backups/nftban/ → Backups (persistent, not /tmp!)
/var/spool/nftban/   → Mail queue (reports waiting to send)
/run/nftban/         → Runtime data (PIDs, sockets)
/tmp/                → AVOID! Use /var/lib/nftban/cache/ instead
```

═══════════════════════════════════════════════════════════════════════════════

## 🚨 BAN WORKFLOW - COMPLETE CLARIFICATION

### User Question: "How does ban work with nftables and Go?"

**SIMPLE ANSWER:**

```
1. USER types:         sudo nftban ban 1.2.3.4
2. BASH receives:      Command in /usr/sbin/nftban
3. BASH calls GO:      nftban-geoip validate 1.2.3.4
4. GO validates:       Returns exit code 0 (valid)
5. BASH calls GO:      nftban-geoip country 1.2.3.4
6. GO looks up:        Returns "CN"
7. BASH checks:        Is "CN" blocked? Yes
8. BASH executes:      nft add element ip nftban_v4 temp_ban { 1.2.3.4 timeout 3600s }
9. NFTABLES blocks:    IP 1.2.3.4 blocked in kernel (IMMEDIATE)
10. BASH logs:         [2025-10-27 12:00:00] BAN ip=1.2.3.4 country=CN
```

**WHO DOES WHAT:**

```
┌─────────────────────────────────────────────────────────────┐
│ USER                                                        │
│   Types: sudo nftban ban 1.2.3.4                          │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ BASH (/usr/sbin/nftban)                                     │
│   - Parses command                                          │
│   - Calls Go for validation                                 │
│   - Calls Go for GeoIP                                      │
│   - Decides: should we ban?                                 │
│   - Executes nft command                                    │
│   - Logs to file                                            │
└─────────────────────────────────────────────────────────────┘
           ↓                             ↓
┌──────────────────────┐    ┌──────────────────────────────┐
│ GO BINARY            │    │ NFTABLES (kernel)            │
│ /usr/bin/nftban-geoip│    │                              │
│                      │    │ Receives command from Bash:  │
│ - Validates IP       │    │ nft add element ...          │
│ - Looks up country   │    │                              │
│ - Returns to Bash    │    │ Blocks IP in kernel (FAST)   │
│                      │    │                              │
│ Does NOT touch       │    │ Firewall now active!         │
│ nftables directly!   │    │                              │
└──────────────────────┘    └──────────────────────────────┘
```

**CRITICAL POINT:**

```
❌ GO does NOT execute nft commands!
❌ GO does NOT add IPs to nftables!
❌ GO does NOT manage firewall!

✅ GO only: Validates IPs, looks up countries
✅ BASH executes: nft commands (adds to firewall)
✅ NFTABLES: Does the actual blocking
```

═══════════════════════════════════════════════════════════════════════════════

## 🔥 COMPLETE BAN WORKFLOW (Step-by-Step)

### Scenario: Ban IP 1.2.3.4

```
═══════════════════════════════════════════════════════════════
STEP 1: User Command
═══════════════════════════════════════════════════════════════

$ sudo nftban ban 1.2.3.4

═══════════════════════════════════════════════════════════════
STEP 2: Bash CLI Router (/usr/sbin/nftban)
═══════════════════════════════════════════════════════════════

Bash receives: ban 1.2.3.4
Bash calls function: nftban_ip_ban "1.2.3.4" "3600"

═══════════════════════════════════════════════════════════════
STEP 3: Bash → Go (Validate IP)
═══════════════════════════════════════════════════════════════

Bash executes:
  nftban-geoip validate "1.2.3.4"

Go binary:
  - Parses IP: 1.2.3.4
  - Checks format: Valid IPv4 ✅
  - Returns exit code: 0 (valid)

Bash receives: exit code 0 → Continue

═══════════════════════════════════════════════════════════════
STEP 4: Bash → Go (Get Country)
═══════════════════════════════════════════════════════════════

Bash executes:
  country=$(nftban-geoip country "1.2.3.4")

Go binary:
  - Looks up 1.2.3.4 in GeoLite2.mmdb
  - Finds: Country CN (China)
  - Prints to stdout: "CN"
  - Exits with code 0

Bash receives: country="CN"

═══════════════════════════════════════════════════════════════
STEP 5: Bash Checks Configuration
═══════════════════════════════════════════════════════════════

Bash reads: /etc/nftban/geoip.d/blocked-countries.conf
Contains:
  CN
  RU
  KP

Check: Is "CN" in blocked list? → YES

Bash decision: Ban is ALLOWED

═══════════════════════════════════════════════════════════════
STEP 6: Bash Checks Whitelist
═══════════════════════════════════════════════════════════════

Bash checks compiled whitelist:
  /var/lib/nftban/compiled/whitelist.txt

Check: Is 1.2.3.4 in whitelist? → NO

Bash decision: Not whitelisted, proceed with ban

═══════════════════════════════════════════════════════════════
STEP 7: Bash Executes nft Command (ADD TO FIREWALL)
═══════════════════════════════════════════════════════════════

Bash executes:
  nft add element ip nftban_v4 temp_ban { 1.2.3.4 timeout 3600s }

What this does:
  - Tells nftables kernel module
  - Add IP 1.2.3.4 to set "temp_ban"
  - Set timeout to 3600 seconds (1 hour)
  - After 1 hour, IP auto-removed

nftables kernel:
  - Receives command
  - Adds IP to temp_ban set
  - Updates firewall rules
  - IP 1.2.3.4 NOW BLOCKED (IMMEDIATE!)

═══════════════════════════════════════════════════════════════
STEP 8: Bash Logs to File
═══════════════════════════════════════════════════════════════

Bash writes to: /var/log/nftban/ban.log

Log entry:
  [2025-10-27T12:00:00+00:00] BAN ip=1.2.3.4 country=CN timeout=3600s reason="manual"

═══════════════════════════════════════════════════════════════
STEP 9: Bash Returns Success to User
═══════════════════════════════════════════════════════════════

Bash prints:
  ✅ Banned 1.2.3.4 (country: CN, timeout: 3600s)

User sees: Success message

═══════════════════════════════════════════════════════════════
RESULT: IP 1.2.3.4 IS NOW BLOCKED
═══════════════════════════════════════════════════════════════

Firewall state:
  - IP 1.2.3.4 in nftables @temp_ban set
  - All packets from 1.2.3.4 → DROPPED
  - Auto-expires after 1 hour
  - NOT written to file (temporary ban)
```

### Key Clarifications:

```
WHO DOES WHAT:

GO (/usr/bin/nftban-geoip):
  ✅ Validates IP format (fast)
  ✅ Looks up country in GeoLite2.mmdb (fast)
  ✅ Returns data to Bash
  ❌ Does NOT touch nftables
  ❌ Does NOT execute nft commands
  ❌ Does NOT add IPs to firewall

BASH (/usr/sbin/nftban, /usr/lib/nftban/core/*.sh):
  ✅ Receives user command
  ✅ Calls Go for validation/GeoIP
  ✅ Checks configuration (blocked countries, whitelist)
  ✅ Makes decision (ban or not?)
  ✅ Executes nft command (adds to firewall)
  ✅ Logs to file
  ✅ Returns result to user

NFTABLES (kernel module):
  ✅ Receives nft commands from Bash
  ✅ Updates firewall sets in kernel
  ✅ Blocks/allows packets (FAST, O(1) lookup)
  ✅ Auto-expires timeouts
```

═══════════════════════════════════════════════════════════════════════════════

## 📧 MAIL FEATURE - Email Dumps & Reports

### Configuration:

```bash
# /etc/nftban/nftban.conf

# Mail settings
NFTBAN_MAIL_ENABLED=1
NFTBAN_MAIL_FROM="nftban@$(hostname -f)"
NFTBAN_MAIL_TO="admin@example.com"
NFTBAN_MAIL_COMPRESS=1                 # Compress attachments (gzip)

# What to email
NFTBAN_MAIL_DAILY_REPORT=1             # Daily HTML report
NFTBAN_MAIL_WEEKLY_REPORT=1            # Weekly summary
NFTBAN_MAIL_DUMPS=0                    # Email exports (large!)
NFTBAN_MAIL_EMERGENCY_ALERTS=1         # Emergency actions
```

### Email Dump:

```bash
# Manual: Email current dump
sudo nftban dump --mail

# What it does:
1. Create dump:    /var/lib/nftban/exports/dump-$(date +%Y%m%d-%H%M%S)/
2. Compress:       tar -czf dump.tar.gz dump-*/
3. Email:          Send to NFTBAN_MAIL_TO with attachment
4. Subject:        [NFTBan] Memory Dump - server1.example.com - 2025-10-27
5. Body:           Summary stats (IPs blocked, drift detected, etc.)
6. Attachment:     dump.tar.gz (compressed)
```

### Email Report:

```bash
# Daily report (HTML)
sudo nftban report daily --mail

# Weekly report (HTML)
sudo nftban report weekly --mail

# What it does:
1. Generate HTML report
2. Compress:       gzip report.html → report.html.gz
3. Queue:          Save to /var/spool/nftban/reports/
4. Send:           Email with inline HTML + attachment
```

### Example Email:

```
From: nftban@server1.example.com
To: admin@example.com
Subject: [NFTBan] Daily Report - server1.example.com - 2025-10-27
Date: 2025-10-27 23:59:00

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
NFTBan Daily Report
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Server: server1.example.com
Date: 2025-10-27
Period: Last 24 hours

📊 SUMMARY:

  Total IPs Blocked:    101,025
  New Bans Today:       125
  Unbanned Today:       10
  Whitelist:            150 IPs
  Feeds Updated:        3 (spamhaus, firehol, emerging-threats)

🔥 TOP ATTACKERS:

  1. 1.2.3.4        (CN) - 500 attempts (SSH brute force)
  2. 5.6.7.8        (RU) - 320 attempts (Port scan)
  3. 9.9.9.9        (KP) - 150 attempts (HTTP flood)

🌍 TOP COUNTRIES:

  1. CN (China)     - 50 new bans
  2. RU (Russia)    - 30 new bans
  3. KP (N. Korea)  - 20 new bans

⚠️  ALERTS:

  • 3 IPs auto-banned (persistent offenders)
  • 1 emergency whitelist action (see emergency.log)
  • Feed drift detected: -50 IPs (whitelisted)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Full HTML report attached (compressed).

Logs: /var/log/nftban/
Exports: /var/lib/nftban/exports/

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Attachment: daily-report-20251027.html.gz (45 KB)
```

### Automatic Scheduled Emails:

```bash
# Daily report (via cron or systemd timer)
# /etc/cron.daily/nftban-daily-report

#!/usr/bin/env bash
/usr/sbin/nftban report daily --mail

# Weekly report (via cron)
# /etc/cron.weekly/nftban-weekly-report

#!/usr/bin/env bash
/usr/sbin/nftban report weekly --mail
```

═══════════════════════════════════════════════════════════════════════════════

## 📋 UPDATED COMMAND SUMMARY

### Ban/Unban (Corrected):

```bash
# Temporary ban (Go validates, Bash executes nft)
sudo nftban ban 1.2.3.4 [timeout]

# How it works:
1. Bash → Go: validate IP
2. Bash → Go: get country
3. Bash: check whitelist
4. Bash: execute nft add element ... (ADD TO FIREWALL)
5. Bash: log to /var/log/nftban/ban.log
```

### Export/Dump (FHS-compliant):

```bash
# Export to FHS-compliant location
sudo nftban export all
# Creates: /var/lib/nftban/exports/export-YYYYMMDD-HHMMSS/

# Dump with stats
sudo nftban dump
sudo nftban dump --compare

# Email dump
sudo nftban dump --mail
# Compresses and emails to NFTBAN_MAIL_TO
```

### Backup (FHS-compliant):

```bash
# Backup to proper location
sudo nftban backup
# Creates: /var/backups/nftban/backup-YYYYMMDD-HHMMSS.tar.gz

# NOT /tmp! Persistent storage!
```

### Reports (with mail):

```bash
# Generate report (save to /var/spool/nftban/reports/)
sudo nftban report daily
sudo nftban report weekly

# Generate and email
sudo nftban report daily --mail
sudo nftban report weekly --mail
```

═══════════════════════════════════════════════════════════════════════════════

## 📝 SUMMARY - CLARIFICATIONS

### ✅ FHS Paths (Corrected):

```
/etc/nftban/           → Configuration (user edits)
/var/lib/nftban/       → State data (compiled, cache, exports)
/var/log/nftban/       → Logs
/var/backups/nftban/   → Backups (NOT /tmp!)
/var/spool/nftban/     → Mail queue
/run/nftban/           → Runtime (PIDs, sockets)
```

**NO MORE /tmp usage!** Everything persistent goes to /var/lib/nftban/

### ✅ Ban Workflow (Clarified):

```
1. User: sudo nftban ban 1.2.3.4
2. Bash: Receives command
3. Bash → Go: validate IP (Go returns valid/invalid)
4. Bash → Go: get country (Go returns "CN")
5. Bash: Check config (is CN blocked? is IP whitelisted?)
6. Bash: Execute nft add element ... (ADDS TO FIREWALL)
7. nftables: Blocks IP in kernel (IMMEDIATE)
8. Bash: Logs to /var/log/nftban/ban.log
9. User: Sees success message
```

**GO DOES NOT TOUCH NFTABLES!** Only Bash executes nft commands.

### ✅ Mail Feature (Added):

```bash
# Email reports (compressed HTML)
sudo nftban report daily --mail
sudo nftban report weekly --mail

# Email dumps (compressed tar.gz)
sudo nftban dump --mail
sudo nftban export all --mail

# Automatic (cron/systemd timer)
/etc/cron.daily/nftban-daily-report
```

### ✅ Compression:

```
All emails use gzip compression:
  report.html → report.html.gz (smaller attachments)
  dump/ → dump.tar.gz (much smaller)
```

═══════════════════════════════════════════════════════════════════════════════

**🎯 IS THIS CLEAR NOW?**

**Ban workflow:**
- User → Bash → Go (validate/GeoIP) → Bash → nft (firewall) ✅

**FHS paths:**
- /var/lib/nftban/ (state), /var/log/nftban/ (logs), /var/backups/ (backups) ✅

**Mail feature:**
- Reports and dumps can be emailed (compressed) ✅

**Ready to implement?** 🚀
