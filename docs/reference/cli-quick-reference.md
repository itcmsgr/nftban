# NFTBan v0.10.0 - CLI Quick Reference Guide
**Last Updated:** 2025-10-30
**Purpose:** Quick command reference for discovering all NFTBan features

═══════════════════════════════════════════════════════════════════

## 🚀 Quick Start - Show Me Everything!

```bash
# Show version
nftban --version

# Show all modules and their versions
nftban module status

# Show all ports and services (open/closed)
sudo nftban port status
sudo nftban port detailed  # With process names

# Show all file paths and permissions
nftban fhs status

# Show firewall status
sudo nftban firewall status

# Show statistics
nftban stats

# Show health check
nftban health check

# Show current security profile
nftban profile show
```

═══════════════════════════════════════════════════════════════════

## 📋 ALL REPORTS - What Can I See?

### 1. MODULE REPORT
**Shows:** All modules, versions, paths, status

```bash
# Basic module list
nftban module status

# Detailed module info (meta tags, dependencies, owners)
nftban module detailed

# HTML report
nftban module html-report

# Email report
nftban module mail-report admin@example.com
```

**Output Example:**
```
NAME              VERSION  TYPE   STATUS    PATH
nftban_ddos       0.10.0   core   ENABLED   /usr/lib/nftban/core/nftban_ddos.sh
nftban_portscan   0.10.0   core   ENABLED   /usr/lib/nftban/core/nftban_portscan.sh
cmd_firewall      0.10.0   cli    ENABLED   /usr/lib/nftban/cli/cmd_firewall.sh
```

**Help:**
```bash
nftban module help
```

---

### 2. PORT/SERVICE REPORT
**Shows:** Ports, protocols, open/closed state, services, processes

```bash
# Basic port status
sudo nftban port status

# Detailed (shows bind address and process name)
sudo nftban port detailed

# Filter specific ports
sudo nftban port status 22,80,443

# HTML report
sudo nftban port html-report

# Email report
sudo nftban port mail-report admin@example.com
```

**Output Example (Basic):**
```
PORT  PROTO  STATE    SERVICE
22    tcp    OPEN     SSH
80    tcp    OPEN     HTTP
443   tcp    OPEN     HTTPS
```

**Output Example (Detailed):**
```
PORT  PROTO  STATE    SERVICE   BIND           PROCESS
22    tcp    OPEN     SSH       0.0.0.0:22     sshd (1234)
80    tcp    OPEN     HTTP      0.0.0.0:80     nginx (5678)
443   tcp    OPEN     HTTPS     0.0.0.0:443    nginx (5678)
```

**Help:**
```bash
nftban port help
```

---

### 3. FHS/PATH REPORT
**Shows:** All directory paths, permissions, ownership

```bash
# Show FHS compliance status
nftban fhs status

# HTML report
nftban fhs html-report

# Email report
nftban fhs mail-report admin@example.com
```

**Output Example:**
```
DIRECTORY              EXPECTED         ACTUAL           STATUS
/usr/lib/nftban        755 root:root    755 root:root    ✔ OK
/etc/nftban            755 root:root    755 root:root    ✔ OK
/var/lib/nftban        750 nftban:nftban 750 nftban:nftban ✔ OK
/var/log/nftban        750 nftban:nftban 750 nftban:nftban ✔ OK
```

**Help:**
```bash
nftban fhs help
```

---

### 4. STATISTICS REPORT
**Shows:** Bans, attacks, activity, trends

```bash
# Current statistics
nftban stats

# Export JSON
nftban stats export json

# Export CSV
nftban stats export csv

# Show graphs (requires data)
nftban stats graphs

# Show top attackers
nftban stats top

# Cleanup old data
sudo nftban stats cleanup
```

**Help:**
```bash
nftban stats help
```

---

### 5. FIREWALL STATUS
**Shows:** Tables, chains, rules, sets

```bash
# Show firewall status
sudo nftban firewall status

# Show detailed rules
sudo nftban firewall show

# Show nftables tables
sudo nftban nftables list

# Reload firewall
sudo nftban firewall reload

# Check configuration syntax
sudo nftban firewall check
```

**Help:**
```bash
nftban firewall help
```

---

### 6. SECURITY PROFILE
**Shows:** Current profile, settings, customizations

```bash
# Show current profile
nftban profile show

# List all available profiles
nftban profile list

# Apply a profile
sudo nftban profile apply web-server

# Interactive selection
sudo nftban profile select
```

**Help:**
```bash
nftban profile help
```

---

### 7. HEALTH CHECK
**Shows:** System health, service status, errors

```bash
# Run health check
nftban health check

# Detailed health report
nftban health detailed

# Auto-fix common issues
sudo nftban health fix
```

**Help:**
```bash
nftban health help
```

---

### 8. DDOS STATUS
**Shows:** DDoS protection settings, status

```bash
# Show DDoS status
nftban ddos status

# Enable DDoS protection
sudo nftban ddos enable

# Disable DDoS protection
sudo nftban ddos disable

# Show thresholds
nftban ddos show
```

**Help:**
```bash
nftban ddos help
```

---

### 9. PORT SCAN STATUS
**Shows:** Port scan detection settings, recent scans

```bash
# Show portscan status
nftban portscan status

# Enable port scan detection
sudo nftban portscan enable

# Disable port scan detection
sudo nftban portscan disable

# Show recent scans
nftban portscan list
```

**Help:**
```bash
nftban portscan help
```

---

### 10. FAIL2BAN STATUS
**Shows:** Fail2ban integration, jails, bans

```bash
# Show fail2ban status
nftban fail2ban status

# Show all jails
nftban fail2ban jails

# Show banned IPs
nftban fail2ban list

# Integration check
nftban fail2ban check
```

**Help:**
```bash
nftban fail2ban help
```

═══════════════════════════════════════════════════════════════════

## 📁 WHERE ARE ALL THE FILES?

### Configuration Files

```
/etc/nftban/
├── nftban.conf                  # Main configuration (DO NOT EDIT)
├── nftban.conf.local            # YOUR CUSTOMIZATIONS (edit this!)
├── baseline.nft                 # Baseline nftables rules
├── conf.d/                      # Module configs
│   ├── banner.conf
│   ├── ddos.conf
│   ├── fail2ban.conf
│   ├── feeds.conf
│   ├── log.conf               # ← LOGGING SETTINGS
│   ├── mail.conf
│   ├── portscan.conf
│   └── stats.conf
├── ports.d/                     # Port definitions
│   ├── 00-defaults.conf
│   └── 10-custom.conf
├── whitelist.d/                 # Whitelisted IPs
│   ├── 00-system.conf
│   └── 10-custom.conf
└── blacklist.d/                 # Blacklisted IPs
    ├── 00-defaults.conf
    └── 30-persistent-offenders.conf  # ← Auto-generated
```

### Security Profiles

```
/usr/share/nftban/profiles/
├── web-server.conf              # Web server profile
├── mail-server.conf             # Mail server profile
├── database.conf                # Database server profile
├── mixed.conf                   # Multi-purpose server
├── development.conf             # Dev/staging environment
├── maximum.conf                 # Maximum security
└── custom.conf                  # Custom template
```

### Application Files

```
/usr/lib/nftban/
├── core/                        # Core modules
│   ├── nftban_ddos.sh
│   ├── nftban_portscan.sh
│   ├── nftban_fail2ban.sh
│   ├── nftban_feeds.sh
│   ├── nftban_geoip_go.sh
│   ├── nftban_stats.sh
│   └── ...
├── cli/                         # CLI command handlers
│   ├── cmd_firewall.sh
│   ├── cmd_ddos.sh
│   ├── cmd_portscan.sh
│   ├── cmd_port.sh
│   ├── cmd_module.sh
│   └── ...
└── nft-runtime.nft              # Runtime table template
```

### State/Data Files

```
/var/lib/nftban/
├── nftban.db                    # SQLite database (bans, stats)
├── profile.current              # Current profile info
├── geoip/                       # GeoIP databases
│   ├── GeoLite2-Country.mmdb
│   └── ...
├── feeds/                       # Downloaded threat feeds
│   └── ...
├── reports/                     # Generated reports
│   ├── module_report_*.html
│   ├── port_report_*.html
│   └── fhs_report_*.html
└── metrics/                     # Statistics snapshots
    └── ...
```

### Log Files

```
/var/log/nftban/
├── nftban.log                   # Main log (human-readable)
├── nftban_debug.log             # Debug log (when debug mode on)
├── events.jsonl                 # Structured events (JSON lines)
├── nftban-actions.log           # Ban/unban actions (JSON)
├── persistent-offenders.log     # Persistent offender escalations
├── cron.log                     # Scheduled task output
└── ai.log                       # AI module decisions (if enabled)
```

### Runtime Files

```
/run/nftban/
├── nftban_main.nft              # Generated main table
└── ...
```

### Executable Files

```
/usr/sbin/
├── nftban                       # Main CLI (frontend)
└── nftban-complete              # Ban backend (internal)
```

═══════════════════════════════════════════════════════════════════

## 🔍 HOW TO FIND THINGS

### "What version am I running?"

```bash
# Quick version
nftban --version

# Backend version
/usr/sbin/nftban-complete --version

# All module versions
nftban module status
```

### "What modules are installed?"

```bash
# List all modules
nftban module status

# Show detailed module info
nftban module detailed
```

### "What ports are open?"

```bash
# Show all ports
sudo nftban port status

# Show with process names
sudo nftban port detailed

# Check specific ports
sudo nftban port status 22,80,443
```

### "What security profile am I using?"

```bash
# Show current profile
nftban profile show

# List available profiles
nftban profile list
```

### "Where are my configuration files?"

```bash
# Show all paths
nftban fhs status

# Main config
/etc/nftban/nftban.conf

# Your customizations
/etc/nftban/nftban.conf.local

# Module configs
/etc/nftban/conf.d/
```

### "Where are my logs?"

```bash
# All log locations
ls -lh /var/log/nftban/

# Main log
tail -f /var/log/nftban/nftban.log

# Debug log (if enabled)
tail -f /var/log/nftban/nftban_debug.log

# JSON events
jq . /var/log/nftban/events.jsonl | less
```

### "What IPs are currently banned?"

```bash
# Show temp bans (from fail2ban)
sudo nft list set inet nftban_runtime temp_ban_v4

# Show permanent bans
cat /etc/nftban/blacklist.d/30-persistent-offenders.conf

# Show statistics
nftban stats
```

### "Is everything working?"

```bash
# Health check
nftban health check

# Detailed check
nftban health detailed

# Check fail2ban integration
nftban fail2ban check

# Check nftables
sudo nftban nftables check
```

═══════════════════════════════════════════════════════════════════

## 🔧 COMMON TASKS

### Enable Debug Logging (Stability Testing)

```bash
# Add to /etc/nftban/nftban.conf.local
cat <<'EOF' >> /etc/nftban/nftban.conf.local

# Debug logging for stability testing
NFTBAN_DEBUG_MODE="true"
NFTBAN_DEBUG_LOG_LEVEL="DEBUG"
NFTBAN_LOG_RETENTION_DAYS="7"
EOF

# Reload (if running as service)
systemctl reload nftban 2>/dev/null || true

# Watch debug log
tail -f /var/log/nftban/nftban_debug.log
```

### View All Configuration Settings

```bash
# Show all loaded settings
grep -v '^#' /etc/nftban/nftban.conf | grep '='

# Show your custom settings
cat /etc/nftban/nftban.conf.local

# Show specific module config
cat /etc/nftban/conf.d/ddos.conf
```

### Generate All Reports

```bash
# Module report
nftban module status
nftban module html-report

# Port report
sudo nftban port status
sudo nftban port html-report

# FHS report
nftban fhs status
nftban fhs html-report

# Statistics
nftban stats
nftban stats export json
```

### Check Everything

```bash
# Health check
nftban health check

# Firewall status
sudo nftban firewall status

# DDoS status
nftban ddos status

# Portscan status
nftban portscan status

# Fail2ban status
nftban fail2ban status

# Statistics
nftban stats
```

═══════════════════════════════════════════════════════════════════

## 📚 GET HELP

Every command has built-in help:

```bash
nftban <command> help
```

Examples:
```bash
nftban firewall help
nftban ddos help
nftban portscan help
nftban profile help
nftban port help
nftban module help
nftban fhs help
nftban stats help
nftban health help
nftban fail2ban help
```

═══════════════════════════════════════════════════════════════════

## 🎯 TLDR - Most Useful Commands

```bash
# Show everything
nftban module status           # All modules + versions + paths
sudo nftban port detailed      # All ports + services + processes
nftban fhs status              # All paths + permissions
nftban stats                   # Statistics
nftban health check            # Health status

# Get help
nftban <command> help          # Command-specific help

# Check version
nftban --version               # Quick version
nftban module status           # All module versions

# Enable debug logging
echo 'NFTBAN_DEBUG_MODE="true"' >> /etc/nftban/nftban.conf.local

# View logs
tail -f /var/log/nftban/nftban_debug.log

# Check what's banned
sudo nft list set inet nftban_runtime temp_ban_v4
```

═══════════════════════════════════════════════════════════════════

**Document Version:** 1.0
**Created:** 2025-10-30
**Purpose:** Quick reference for discovering all NFTBan CLI features

**For detailed audit, see:** `CLI_AUDIT_2025-10-30.md`

═══════════════════════════════════════════════════════════════════
