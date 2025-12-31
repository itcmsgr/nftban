# Suricata IDS/IPS Integration

NFTBan v1.0+ includes comprehensive Suricata integration with intelligent rule management, performance profiling, and real-time statistics.

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Quick Start](#quick-start)
- [Installation](#installation)
- [Profile System](#profile-system)
- [Service-Based Rule Filtering](#service-based-rule-filtering)
- [SID Statistics Engine](#sid-statistics-engine)
- [Custom Rules Management](#custom-rules-management)
- [Recommendations Engine](#recommendations-engine)
- [CLI Commands Reference](#cli-commands-reference)
- [Testing Guide](#testing-guide)
- [Troubleshooting](#troubleshooting)

---

## Overview

NFTBan's Suricata integration provides:

- **Automatic Performance Profiling** - Detects system resources and applies optimal configuration
- **Service-Based Rule Filtering** - Reduces loaded rules by 50-70% based on detected services
- **Real-Time Statistics** - Tracks SID triggers, false positives, and attack patterns
- **Custom Rules Manager** - Safe CRUD operations with validation and rollback
- **Intelligent Recommendations** - Analyzes patterns and suggests optimizations

**Architecture:**
```
┌─────────────────────────────────────────────────────────────┐
│ NFTBan Suricata Integration                                 │
├─────────────────────────────────────────────────────────────┤
│ Profile System     │ Auto-detect CPU/RAM → Apply profile    │
│ Service Scanner    │ Scan localhost → Filter rules          │
│ Rules Manager      │ Generate enabled.list (3-layer config) │
│ Stats Engine       │ Parse eve.json → Track SIDs            │
│ Custom Rules       │ CRUD + Validation + Backup/Rollback    │
│ Recommendations    │ Analyze patterns → Optimize ruleset    │
└─────────────────────────────────────────────────────────────┘
```

---

## Features

### 1. Performance Profiles

Three pre-configured profiles optimized for different resource levels:

| Profile | CPU Cores | RAM | Use Case |
|---------|-----------|-----|----------|
| **Minimal** | 2 | 2 GB | Tiny VPS, stability first |
| **Standard** | 4 | 4-8 GB | Most servers (default) |
| **Maximum** | 8+ | 8-16 GB | High traffic, deep inspection |

**Key Settings:**
- Ring buffer size (50k/100k/300k)
- Flow timeouts (60s/120s/300s)
- HTTP body inspection depth
- Detection engine tuning

### 2. Service-Based Rule Filtering

**Problem:** Suricata loads 30,000-40,000 rules by default, wasting CPU/RAM on irrelevant signatures.

**Solution:** Scan localhost services → Enable only relevant rule categories.

**Results:**
- 50-70% reduction in loaded rules
- Faster startup times
- Lower memory usage
- Same security for your actual services

**How it Works:**
```
1. Scan localhost ports (HTTP:80, SSH:22, MySQL:3306, etc.)
2. Map services → Suricata categories (http, ssh, mysql, etc.)
3. Generate auto.conf with detected categories
4. Merge with local.conf (user overrides) → effective.conf
5. Create enabled.list for Suricata
```

### 3. SID Statistics Engine

Real-time monitoring of Suricata signature triggers:

- **Prometheus Metrics** - Time-series data for dashboards
- **In-Memory Cache** - Fast CLI queries without database overhead
- **JSON Snapshots** - Persist across restarts
- **Historical Analysis** - Track patterns over time

**Tracked Metrics:**
- Total triggers per SID
- Unique source IPs
- First/Last trigger timestamps
- Category aggregates
- Alert severity levels

### 4. Custom Rules Management

Safe custom rule operations with SID range enforcement:

- **SID Range:** 9000000-9999999 (prevents conflicts with official rulesets)
- **Validation:** Syntax checking before adding/editing
- **Automatic Backups:** Created before every modification (last 10 kept)
- **Safe Rollback:** Restore previous state at any time
- **Enable/Disable:** Comment/uncomment without deletion

### 5. Recommendations Engine

Intelligent analysis of SID patterns with actionable suggestions:

**Detection Patterns:**

| Type | Pattern | Recommendation |
|------|---------|----------------|
| **False Positive** | 100+ triggers from 1-3 sources | Review threshold, likely misconfiguration |
| **Noise Reduction** | 1000+ triggers, widespread sources | Tighten rule conditions |
| **Drop Mode** | Attack pattern from many sources | Switch from alert to drop/block |
| **Disable Rule** | 10,000+ triggers, very recent | Investigate and disable if needed |

---

## Quick Start

### One-Time Setup (5 minutes)

```bash
# 1. Auto-detect and apply profile
nftban suricata profile detect
nftban suricata profile set standard

# 2. Scan services and generate optimized rules
nftban suricata scan
nftban suricata rules init
nftban suricata rules generate

# 3. Restart Suricata with new config
sudo systemctl restart suricata

# 4. Start statistics collector (optional)
sudo systemctl enable --now nftban-suricata-stats
```

### Daily Operations

```bash
# Check what's triggering
nftban suricata sid top

# Get optimization recommendations
nftban suricata recommend

# Add custom rules
nftban suricata custom add 'alert tcp any any -> any 80 (msg:"Custom Rule"; sid:9000000; rev:1;)'

# Monitor recent activity
nftban suricata sid recent
```

---

## Installation

### Prerequisites

```bash
# Install Suricata
sudo dnf install suricata     # RHEL/Rocky/Alma
sudo apt install suricata     # Debian/Ubuntu

# Install suricata-update (for rules)
sudo pip3 install --upgrade suricata-update
```

### NFTBan Installation

```bash
# 1. Install NFTBan (if not already installed)
sudo dnf install nftban       # RPM
sudo dpkg -i nftban*.deb      # DEB

# 2. Verify installation
nftban suricata help

# 3. Initialize Suricata integration
nftban suricata rules init
```

### Directory Structure

```
/etc/nftban/suricata/
├── profiles/
│   ├── minimal.yaml      # 2 cores / 2GB RAM
│   ├── standard.yaml     # 4 cores / 4-8GB RAM
│   └── maximum.yaml      # 8+ cores / 8-16GB RAM
├── config/
│   ├── suricata.local.conf      # User manual settings (never overwritten)
│   ├── suricata.auto.conf       # Auto-generated from scan
│   ├── suricata.effective.conf  # Merged result (local + auto)
│   ├── enabled.list             # Generated rules list for Suricata
│   └── profile.conf             # Active profile setting
├── rules/
│   ├── custom.rules             # Your custom rules (SID 9000000-9999999)
│   └── backups/                 # Automatic backups
│       └── custom.rules.YYYYMMDD-HHMMSS
└── cache/
    └── sid-stats.json           # SID statistics cache
```

---

## Profile System

### Auto-Detection

```bash
# Detect optimal profile based on CPU and RAM
nftban suricata profile detect
```

**Output:**
```
CPU Cores: 4
RAM: 8 GB
Recommended Profile: standard
```

### Apply Profile

```bash
# Apply profile (minimal/standard/maximum)
nftban suricata profile set standard
```

**What it Does:**
1. Copies profile YAML to `/etc/suricata/suricata.yaml`
2. Updates `/etc/nftban/suricata/config/profile.conf`
3. Configures ring buffers, timeouts, inspection depths

### View Current Profile

```bash
# Show active profile settings
nftban suricata profile show
```

### Validate Profile

```bash
# Check profile configuration
nftban suricata profile validate
```

---

## Service-Based Rule Filtering

### 3-Layer Configuration System

**Layer 1: Auto-Detection** (`suricata.auto.conf`)
- Generated automatically from service scan
- **Never manually edited**
- Overwritten on each scan

**Layer 2: User Overrides** (`suricata.local.conf`)
- Manual user settings
- **Never overwritten by NFTBan**
- Takes precedence over auto.conf

**Layer 3: Effective Config** (`suricata.effective.conf`)
- Merged result: local.conf + auto.conf
- Generated automatically
- Used to create enabled.list

### Quick Scan

```bash
# Fast port scan of localhost
nftban suricata scan
```

**Detects:**
- Common ports (21, 22, 25, 53, 80, 443, 3306, etc.)
- Maps to Suricata categories

**Output:**
```
Detected Services:
  - HTTP (80) → http, web-application
  - HTTPS (443) → tls, ssl, web-application
  - SSH (22) → ssh
  - MySQL (3306) → mysql

Auto-conf generated: /etc/nftban/suricata/config/suricata.auto.conf
```

### Deep Scan

```bash
# Deep scan with protocol probes
nftban suricata scan deep
```

**Probes:**
- **HTTP:** Send GET request, verify response
- **HTTPS:** TLS handshake, verify certificate
- **SSH:** Read banner, verify SSH protocol
- **MySQL:** Protocol handshake, version detection
- **DNS:** Query test, verify response

### Generate Rules List

```bash
# Create enabled.list from effective config
nftban suricata rules generate
```

**Process:**
1. Merges local.conf + auto.conf → effective.conf
2. Filters rule files by enabled categories
3. Applies whitelist/blacklist
4. Writes enabled.list for Suricata

### View Statistics

```bash
# Show rule reduction statistics
nftban suricata rules stats
```

**Output:**
```
Rules Statistics:
  Total rule files: 245
  Enabled rule files: 82 (33.5%)
  Rule reduction: 66.5%

Enabled Categories:
  - http (42 files)
  - tls (18 files)
  - ssh (12 files)
  - mysql (10 files)
```

### Manual Overrides

Edit `/etc/nftban/suricata/config/suricata.local.conf`:

```ini
# Enable additional categories (not detected by scan)
enabled_categories = dns,smtp,ftp

# Disable specific categories
disabled_categories = icmp

# Whitelist specific rule files
whitelist = emerging-exploit.rules

# Blacklist specific rule files
blacklist = emerging-info.rules
```

Then regenerate:
```bash
nftban suricata rules generate
sudo systemctl reload suricata
```

---

## SID Statistics Engine

### Overview Statistics

```bash
# Show overall SID statistics
nftban suricata sid stats
```

**Output:**
```
SID Statistics:
  Total SIDs tracked: 347
  Total triggers: 15,432
  Unique sources: 89

Cache: /etc/nftban/suricata/cache/sid-stats.json
```

### Top Triggered SIDs

```bash
# Show top 20 SIDs by trigger count
nftban suricata sid top
```

**Output:**
```
Rank  SID       Triggers  Sources  Category          Signature
----  --------  --------  -------  ----------------  --------------------
1     2100498   3,421     12       web-application   SQL Injection Attempt
2     2100356   2,103     45       exploit           Buffer Overflow
3     2100287   1,892     8        trojan            Malware Callback
...
```

### SID Details

```bash
# Detailed info for specific SID
nftban suricata sid info 2100498
```

**Output:**
```
SID: 2100498
Category: web-application
Signature: ET WEB_SERVER SQL Injection Attempt

Trigger Count: 3,421
First Trigger: 2025-12-25 08:15:32
Last Trigger: 2025-12-31 14:22:18

Unique Sources: 12
Top Source IPs:
  - 192.168.1.105 (1,203 triggers)
  - 10.0.0.45 (892 triggers)
  - 172.16.0.33 (645 triggers)
  ...
```

### Recent Activity

```bash
# Show SIDs triggered in last 24 hours
nftban suricata sid recent
```

**Output:**
```
SID       Last Trigger  Triggers  Sources  Signature
--------  ------------  --------  -------  --------------------
2100498   5m ago        234       3        SQL Injection Attempt
2100356   2h ago        67        8        Buffer Overflow
2100287   12h ago       45        2        Malware Callback
...
```

### Statistics Daemon

Runs continuously to collect SID statistics from eve.json:

```bash
# Start as systemd service
sudo systemctl start nftban-suricata-stats
sudo systemctl enable nftban-suricata-stats

# Or run manually (foreground)
sudo nftban-core suricata stats-daemon
```

**Features:**
- Tails `/var/log/suricata/eve.json`
- Updates Prometheus metrics in real-time
- Saves cache snapshots every 5 minutes
- Graceful shutdown on SIGTERM/SIGINT

---

## Custom Rules Management

### List Custom Rules

```bash
# Show all custom rules
nftban suricata custom list
```

**Output:**
```
SID       Status      Action  Message
--------  ----------  ------  --------------------
9000000   ✓ Enabled   alert   Test HTTP Traffic
9000001   ✗ Disabled  drop    Block Malicious IP
```

### Add Custom Rule

```bash
# Add new custom rule
nftban suricata custom add 'alert tcp any any -> any 80 (msg:"HTTP Traffic Monitor"; sid:9000000; rev:1;)'
```

**Validation Checks:**
- SID in range 9000000-9999999
- Valid syntax (action, protocol, msg, sid, rev)
- Unique SID (not already in use)
- Optional: Suricata binary validation (`suricata -T`)

**Output:**
```
✓ Custom rule added successfully

SID:     9000000
Action:  alert
Message: HTTP Traffic Monitor

Next steps:
  1. Reload Suricata: systemctl reload suricata
  2. Monitor alerts: nftban suricata sid info 9000000
```

### Edit Custom Rule

```bash
# Update existing rule (must keep same SID)
nftban suricata custom edit 9000000 'alert tcp any any -> any 80 (msg:"Updated Message"; sid:9000000; rev:2;)'
```

### Enable/Disable Rules

```bash
# Disable rule (comments it out, doesn't delete)
nftban suricata custom disable 9000000

# Re-enable rule
nftban suricata custom enable 9000000
```

### Remove Custom Rule

```bash
# Delete rule permanently
nftban suricata custom remove 9000000
```

**Safety:** Automatic backup created before removal.

### Validate Rules

```bash
# Validate all custom rules
nftban suricata custom validate
```

**Output:**
```
✓ SID 9000000: Valid
✓ SID 9000001: Valid

✅ All custom rules are valid
```

### Backup & Rollback

```bash
# Create manual backup
nftban suricata custom backup

# List available backups
nftban suricata custom backup
# Output:
# Available backups (3):
#   - custom.rules.20251231-140500
#   - custom.rules.20251230-093022
#   - custom.rules.20251229-161543

# Rollback to specific backup
nftban suricata custom rollback custom.rules.20251231-140500
```

**Auto-Backups:**
- Created before every modification (add/edit/remove)
- Timestamped: `custom.rules.YYYYMMDD-HHMMSS`
- Last 10 backups kept automatically
- Pre-rollback backup created before restore

---

## Recommendations Engine

### Generate Recommendations

```bash
# Full analysis with detailed recommendations
nftban suricata recommend
```

**Output:**
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  🔴 HIGH SEVERITY (3 recommendations)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

⚠️  SID 2100498: Potential false positive
   Category: web-application
   Signature: ET WEB_SERVER SQL Injection Attempt
   Evidence:
     • 3,421 triggers from only 1 unique source(s)
     • Ratio: 3421.0 triggers per source
     • All triggers from single IP (likely misconfiguration)
   ✅ Action: Review rule configuration and consider tuning threshold

🛡️  SID 2100356: Active attack pattern
   Category: exploit
   Signature: ET EXPLOIT Buffer Overflow Attempt
   Evidence:
     • 2,103 triggers from 45 unique sources
     • Category: exploit (attack pattern)
     • Distributed attack pattern detected
   ✅ Action: Switch rule from 'alert' to 'drop' mode to block attacks

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  🟡 MEDIUM SEVERITY (2 recommendations)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🔇 SID 2100287: Noisy rule
   Category: trojan
   Signature: ET TROJAN Malware Callback
   Evidence:
     • 1,892 triggers from 89 unique sources
     • Ratio: 21.3 triggers per source (widespread activity)
     • May be detecting normal/benign traffic patterns
   ✅ Action: Consider tightening rule conditions or increasing threshold
```

### Quick Summary

```bash
# Show recommendations summary
nftban suricata recommend summary
```

**Output:**
```
Total SIDs tracked:        347
Total recommendations:     5

By Severity:
  🔴 High:   3
  🟡 Medium: 2
  🟢 Low:    0

By Type:
  False Positives:   2
  Noise Reduction:   1
  Drop Mode:         2
  Disable Rule:      0
```

### Analysis Patterns

| Pattern | Threshold | Action |
|---------|-----------|--------|
| **False Positive** | 100+ triggers, 1-3 sources, ratio >50 | Review threshold, tune rule |
| **Noise** | 1000+ triggers, 20+ sources, ratio <20 | Tighten conditions |
| **Drop Mode** | 50+ triggers, 10+ sources, attack category | Switch to drop/block |
| **Disable** | 10,000+ triggers, very recent | Investigate and disable |

---

## CLI Commands Reference

### Profile Commands

```bash
nftban suricata profile detect          # Auto-detect optimal profile
nftban suricata profile set <PROFILE>   # Apply profile (minimal/standard/maximum)
nftban suricata profile show            # Display current profile
nftban suricata profile validate        # Validate profile config
```

### Service Scanner Commands

```bash
nftban suricata scan                    # Quick port scan
nftban suricata scan deep               # Deep scan with protocol probes
nftban suricata services list           # Show detected services config
```

### Rules Management Commands

```bash
nftban suricata rules init              # Initialize config files
nftban suricata rules generate          # Generate enabled.list
nftban suricata rules stats             # Show statistics
nftban suricata rules list              # List rule files
nftban suricata rules update            # Update ET/Open ruleset
```

### SID Statistics Commands

```bash
nftban suricata sid stats               # Overall statistics
nftban suricata sid top                 # Top 20 triggered SIDs
nftban suricata sid recent              # Recent 24h activity
nftban suricata sid info <SID>          # Detailed SID information
```

### Custom Rules Commands

```bash
nftban suricata custom list             # List all custom rules
nftban suricata custom add '<RULE>'     # Add new rule
nftban suricata custom edit <SID> '<RULE>' # Update rule
nftban suricata custom remove <SID>     # Delete rule
nftban suricata custom enable <SID>     # Enable rule
nftban suricata custom disable <SID>    # Disable rule
nftban suricata custom validate         # Validate all rules
nftban suricata custom backup           # Create backup
nftban suricata custom rollback <NAME>  # Restore from backup
```

### Recommendations Commands

```bash
nftban suricata recommend               # Full analysis
nftban suricata recommend summary       # Quick summary
```

---

## Testing Guide

### Quick Smoke Test (5 minutes)

```bash
# 1. Verify profile system
nftban suricata profile detect
nftban suricata profile set standard
nftban suricata profile show

# 2. Test service scanner
nftban suricata scan
nftban suricata rules stats

# 3. Test custom rules
nftban suricata custom add 'alert tcp any any -> any 80 (msg:"Test"; sid:9000000; rev:1;)'
nftban suricata custom list
nftban suricata custom validate
nftban suricata custom remove 9000000

# 4. Test statistics (requires Suricata running)
nftban suricata sid stats
nftban suricata recommend summary
```

### Full Testing Checklist

**Phase 1: Profile System**
- [ ] Auto-detection completes without errors
- [ ] Profile application creates config files
- [ ] Profile validation passes
- [ ] All profiles (minimal/standard/maximum) work

**Phase 2: Service Scanner**
- [ ] Quick scan detects localhost services
- [ ] Deep scan performs protocol probes
- [ ] Auto-conf generated correctly
- [ ] Rules list shows 50-70% reduction

**Phase 3: SID Statistics**
- [ ] Cache created successfully
- [ ] Statistics commands work
- [ ] Data persists across restarts
- [ ] Daemon runs without crashing

**Phase 4: Custom Rules**
- [ ] CRUD operations work correctly
- [ ] SID range validation enforced
- [ ] Automatic backups created
- [ ] Invalid rules rejected
- [ ] Rollback restores state

**Phase 5: Recommendations**
- [ ] Recommendations generated
- [ ] Severity classification correct
- [ ] Evidence clear and actionable

---

## Troubleshooting

### No Statistics Available

**Symptoms:** `sid stats` shows 0 SIDs, empty output

**Solutions:**
```bash
# 1. Verify Suricata is running
sudo systemctl status suricata

# 2. Check eve.json exists and has data
ls -la /var/log/suricata/eve.json
tail -f /var/log/suricata/eve.json | jq 'select(.event_type=="alert")'

# 3. Start stats collector
sudo systemctl start nftban-suricata-stats
sudo journalctl -u nftban-suricata-stats -f

# 4. Generate some traffic to trigger alerts
curl http://localhost/
```

### Services Not Detected

**Symptoms:** `scan` shows no services or missing expected services

**Solutions:**
```bash
# 1. Verify services are actually running
ss -tlnp | grep -E ':(80|443|22|3306|25|53)'

# 2. Check firewall not blocking localhost
sudo iptables -L INPUT -n | grep lo
sudo ip6tables -L INPUT -n | grep lo

# 3. Use deep scan for better detection
nftban suricata scan deep

# 4. Manually edit local.conf if needed
sudo vi /etc/nftban/suricata/config/suricata.local.conf
# Add: enabled_categories = http,ssh,mysql
```

### Custom Rule Validation Failed

**Symptoms:** Rule rejected with syntax errors

**Common Issues:**
```bash
# Missing required fields
# ✗ BAD: alert tcp any any -> any 80 (msg:"Test";)
# ✓ GOOD: alert tcp any any -> any 80 (msg:"Test"; sid:9000000; rev:1;)

# SID out of range
# ✗ BAD: sid:1000000;
# ✓ GOOD: sid:9000000;

# Unbalanced parentheses
# ✗ BAD: alert tcp any any -> any 80 (msg:"Test"; sid:9000000; rev:1;
# ✓ GOOD: alert tcp any any -> any 80 (msg:"Test"; sid:9000000; rev:1;)

# Test manually with Suricata
echo 'alert tcp any any -> any 80 (msg:"Test"; sid:9000000; rev:1;)' | suricata -T -S -
```

### Rules Not Reducing

**Symptoms:** `rules stats` shows 100% or no reduction

**Solutions:**
```bash
# 1. Verify scan was run
cat /etc/nftban/suricata/config/suricata.auto.conf
# Should show: enabled_categories = http,ssh,...

# 2. Check effective.conf
cat /etc/nftban/suricata/config/suricata.effective.conf
# Should merge local + auto

# 3. Regenerate rules list
nftban suricata rules generate

# 4. Verify enabled.list created
wc -l /etc/nftban/suricata/config/enabled.list
```

### Permission Denied Errors

**Symptoms:** Commands fail with permission errors

**Solutions:**
```bash
# 1. Use sudo for root commands
sudo nftban suricata <command>

# 2. Check directory permissions
sudo ls -la /etc/nftban/suricata/
sudo chown -R root:root /etc/nftban/suricata
sudo chmod 755 /etc/nftban/suricata

# 3. Verify nftban-core is executable
sudo chmod +x /usr/local/bin/nftban-core
```

### Recommendations Show Nothing

**Symptoms:** `recommend` shows "No recommendations"

**Expected Behavior:** This is normal if:
- Suricata recently started (no alerts yet)
- All rules performing optimally
- Not enough data collected (wait 24h)

**To Generate Test Data:**
```bash
# Trigger some alerts for testing
# (safely, on your own system)

# Start stats collector
sudo systemctl start nftban-suricata-stats

# Wait for some alerts
sleep 300

# Check again
nftban suricata recommend
```

---

## Performance Impact

### Before Suricata Integration

- **Rules Loaded:** 30,000-40,000
- **Startup Time:** 15-30 seconds
- **Memory Usage:** 800MB-1.5GB
- **CPU Usage:** 20-40% of 1 core (idle)

### After Suricata Integration

- **Rules Loaded:** 10,000-15,000 (50-70% reduction)
- **Startup Time:** 5-10 seconds
- **Memory Usage:** 300-600MB
- **CPU Usage:** 10-20% of 1 core (idle)

**Benchmark Command:**
```bash
# Before
time sudo systemctl restart suricata
top -p $(pgrep suricata)

# Apply service filtering
nftban suricata scan
nftban suricata rules generate
sudo systemctl restart suricata

# After
time sudo systemctl restart suricata
top -p $(pgrep suricata)
```

---

## Best Practices

1. **Run Service Scan After Changes**
   - Added new services? Re-scan and regenerate rules
   - Removed services? Re-scan to reduce rules further

2. **Review Recommendations Weekly**
   - Check for false positives
   - Optimize noisy rules
   - Consider drop mode for active attacks

3. **Use Custom Rules Sparingly**
   - Only add rules for specific needs
   - Keep SID range organized (9000000-9000999 for type A, etc.)
   - Document rule purpose in `msg` field

4. **Monitor Statistics Regularly**
   - Check `sid top` to spot anomalies
   - Investigate high-trigger SIDs
   - Review `sid recent` for active threats

5. **Keep Backups**
   - Automatic backups are created, but verify they exist
   - Test rollback procedure before you need it
   - Keep custom.rules in version control

6. **Profile Selection**
   - Start with auto-detected profile
   - Monitor performance under load
   - Adjust if needed (upsize for more inspection, downsize for stability)

---

## Additional Resources

- **Suricata Documentation:** https://suricata.io/docs/
- **ET/Open Rules:** https://rules.emergingthreats.net/
- **NFTBan GitHub:** https://github.com/itcmsgr/nftban
- **NFTBan Wiki:** https://github.com/itcmsgr/nftban/wiki

---

**Last Updated:** 2025-12-31
**NFTBan Version:** 1.0+
