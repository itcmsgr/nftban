# NFTBan DDOS Protection - Complete Guide
**Version:** 0.10.0
**Date:** 2025-10-30
**Status:** Production Ready with Safe Defaults

---

## 🎯 QUICK START (TL;DR)

```bash
# 1. Edit config and remove # from limits you want
vi /etc/nftban/conf.d/ddos.conf

# 2. ALWAYS whitelist localhost and your IPs first!
DDOS_WHITELIST="127.0.0.1,::1,YOUR_OFFICE_IP"

# 3. Remove # from limits (start conservative!)
DDOS_HTTP_CONN_PER_IP=150
DDOS_SSH_CONN_PER_IP=10

# 4. Reload to apply changes
nftban ddos reload

# 5. Monitor for blocks
nftban ddos stats
tail -f /var/log/nftban/ddos-blocks.log
```

---

## 📋 TABLE OF CONTENTS

1. [Understanding DDOS Protection](#understanding)
2. [Configuration Approach](#configuration)
3. [Recommended Values by Server Type](#recommendations)
4. [How to Enable Limits](#enable)
5. [Reload Mechanism](#reload)
6. [Monitoring & Tuning](#monitoring)
7. [Troubleshooting](#troubleshooting)
8. [Real-World Examples](#examples)

---

## <a name="understanding"></a>1. UNDERSTANDING DDOS PROTECTION

### What NFTBan DDOS Protection Does

NFTBan uses **nftables connection tracking** to limit connections per IP address:

```
┌─────────────────────────────────────────────────────────────┐
│  Client IP: 203.0.113.45                                    │
│  ├─ HTTP Connection 1  ✅                                   │
│  ├─ HTTP Connection 2  ✅                                   │
│  ├─ ...                                                     │
│  ├─ HTTP Connection 150 ✅  (at limit!)                    │
│  └─ HTTP Connection 151 ❌  BLOCKED                         │
└─────────────────────────────────────────────────────────────┘
```

### Why Limits Are DISABLED by Default

**Problem:** Every server is different!

| Server Type | HTTP Needs | Why |
|-------------|------------|-----|
| **Multi-site hosting** | 200-300 | User manages 50 sites, opens 5 each = 250 conns |
| **Single business site** | 120-150 | Moderate traffic, office team access |
| **API gateway** | 80-100 | Known patterns, controlled environment |

**Solution:** Ship with ALL limits commented (#). You enable what you need.

---

## <a name="configuration"></a>2. CONFIGURATION APPROACH

### File Location

```
/etc/nftban/conf.d/ddos.conf.REFERENCE   # Reference with all options
/etc/nftban/conf.d/ddos.conf             # Your active config (copy & edit)
```

### How It Works

1. **All values are commented by default:**
   ```bash
   #DDOS_HTTP_CONN_PER_IP=150   # Disabled (no limit)
   ```

2. **Remove # to enable:**
   ```bash
   DDOS_HTTP_CONN_PER_IP=150    # Enabled! Now limiting to 150
   ```

3. **Reload to apply:**
   ```bash
   nftban ddos reload
   ```

4. **Monitor results:**
   ```bash
   nftban ddos stats
   ```

---

## <a name="recommendations"></a>3. RECOMMENDED VALUES BY SERVER TYPE

### 🏢 Multi-Site Hosting (cPanel, DirectAdmin, Plesk)

**Profile:**
- 20-100+ websites on one server
- Users manage multiple sites
- Shared hosting environment

**Recommended:**
```bash
# Whitelist FIRST!
DDOS_WHITELIST="127.0.0.1,::1,10.0.0.0/8,192.168.0.0/16,YOUR_OFFICE_IP"

# HTTP - High limits for many sites
DDOS_HTTP_CONN_PER_IP=300              # 50 sites × 5 conns + buffer
DDOS_HTTP_RATE_LIMIT=200               # High request rate
DDOS_HTTP_RATE_BURST=400               # 2× burst

# SSH - Team of admins
DDOS_SSH_CONN_PER_IP=20                # Multiple admins with automation

# Mail - Office users with multiple domain accounts
DDOS_SMTP_CONN_PER_IP=40               # Many domains
DDOS_IMAP_CONN_PER_IP=120              # Users check multiple accounts
DDOS_POP3_CONN_PER_IP=60
```

**Why these values?**
- User with 50 client sites opens 5 sites = 250 connections
- DevOps team with Ansible/automation = 10-15 SSH connections
- Users checking email for 10 domains × 3 devices = 30 IMAP connections

---

### 🏪 Single Business Site (WordPress, Laravel, etc.)

**Profile:**
- One main application
- Small admin team (2-5 people)
- Office email (5-15 employees)

**Recommended:**
```bash
# Whitelist FIRST!
DDOS_WHITELIST="127.0.0.1,::1,10.0.0.0/8,192.168.0.0/16,YOUR_OFFICE_IP,CLOUDFLARE_IPS"

# HTTP - Moderate for single site
DDOS_HTTP_CONN_PER_IP=150              # Single site traffic
DDOS_HTTP_RATE_LIMIT=120               # Standard rate
DDOS_HTTP_RATE_BURST=240

# SSH - Small team
DDOS_SSH_CONN_PER_IP=10                # 2-5 admins

# Mail - Small office
DDOS_SMTP_CONN_PER_IP=25               # 10-15 employee accounts
DDOS_IMAP_CONN_PER_IP=60               # Office users
DDOS_POP3_CONN_PER_IP=30
```

---

### 🚀 API Gateway / Reverse Proxy

**Profile:**
- Known traffic patterns
- Behind load balancer
- Controlled environment

**Recommended:**
```bash
# Whitelist backend and monitoring
DDOS_WHITELIST="127.0.0.1,::1,10.0.0.0/8,BACKEND_IPS,MONITORING_IPS"

# HTTP - Tighter limits for known patterns
DDOS_HTTP_CONN_PER_IP=100              # Controlled traffic
DDOS_HTTP_RATE_LIMIT=80                # Known API patterns
DDOS_HTTP_RATE_BURST=160

# SSH - Few admins
DDOS_SSH_CONN_PER_IP=8                 # 1-2 admins

# Mail - Minimal or none
DDOS_SMTP_CONN_PER_IP=15               # Relay only
DDOS_IMAP_CONN_PER_IP=30               # Minimal
```

---

### 💼 Office Email Server (Dedicated)

**Profile:**
- Primary purpose: email
- Many user accounts
- Multiple devices per user

**Recommended:**
```bash
# Whitelist office network
DDOS_WHITELIST="127.0.0.1,::1,10.0.0.0/8,OFFICE_NETWORK"

# HTTP - Minimal (webmail only)
DDOS_HTTP_CONN_PER_IP=80               # Webmail access
DDOS_HTTP_RATE_LIMIT=50
DDOS_HTTP_RATE_BURST=100

# SSH - Admins only
DDOS_SSH_CONN_PER_IP=8

# Mail - HIGH limits for office use
DDOS_SMTP_CONN_PER_IP=60               # Office with 50+ employees
DDOS_IMAP_CONN_PER_IP=150              # Multiple accounts per user × devices
DDOS_POP3_CONN_PER_IP=80
```

**Why high mail limits?**
- 50 employees × 2 email accounts = 100 IMAP connections
- Each user has 3 devices (phone, laptop, desktop) = 300 connections total
- Buffer for bursts = 150 per IP (office NAT)

---

## <a name="enable"></a>4. HOW TO ENABLE LIMITS

### Step-by-Step Process

#### **Step 1: Copy Reference Config**
```bash
cp /etc/nftban/conf.d/ddos.conf.REFERENCE /etc/nftban/conf.d/ddos.conf
```

#### **Step 2: Edit Config**
```bash
vi /etc/nftban/conf.d/ddos.conf
```

#### **Step 3: Whitelist Critical IPs (DO THIS FIRST!)**

Find this section and uncomment:
```bash
# BEFORE (disabled):
#DDOS_WHITELIST="127.0.0.1,::1,10.0.0.0/8,192.168.0.0/16"

# AFTER (enabled):
DDOS_WHITELIST="127.0.0.1,::1,10.0.0.0/8,192.168.0.0/16,YOUR_OFFICE_IP"
```

**Always whitelist:**
- `127.0.0.1`, `::1` - Localhost
- `10.0.0.0/8`, `192.168.0.0/16` - Private networks
- Your office/VPN IP
- CDN IPs (Cloudflare: see https://www.cloudflare.com/ips/)
- Monitoring service IPs (UptimeRobot, Pingdom, etc.)

#### **Step 4: Enable Limits Gradually**

**Start conservative (HIGH limits):**
```bash
# Remove # from these lines:
DDOS_HTTP_CONN_PER_IP=200              # Start high!
DDOS_SSH_CONN_PER_IP=15                # Start high!
DDOS_SMTP_CONN_PER_IP=30               # Start high!
DDOS_IMAP_CONN_PER_IP=80               # Start high!
```

#### **Step 5: Reload Configuration**
```bash
nftban ddos reload
```

**Output:**
```
Reloading DDOS protection configuration...
✅ Configuration loaded
✅ nftables rules updated
✅ Whitelist applied (5 IPs/ranges)

Active limits:
  HTTP connections per IP: 200
  SSH connections per IP: 15
  SMTP connections per IP: 30
  IMAP connections per IP: 80

Monitoring: nftban ddos stats
```

#### **Step 6: Monitor for 24-48 Hours**
```bash
# Check block statistics
nftban ddos stats

# Watch real-time blocks
tail -f /var/log/nftban/ddos-blocks.log

# Check recent blocks
nftban ddos blocks --recent
```

#### **Step 7: Adjust Based on Data**

**If block rate < 0.1%:** Limits are good
**If block rate > 1%:** Investigate blocks, may need higher limits
**If seeing legitimate blocks:** Whitelist IPs or increase limits

---

## <a name="reload"></a>5. RELOAD MECHANISM

### How Reload Works

```
┌─────────────────────────────────────────────────────────────┐
│  1. Read /etc/nftban/conf.d/ddos.conf                      │
│  2. Parse enabled values (uncommented lines)               │
│  3. Validate configuration                                  │
│  4. Update nftables rules                                   │
│  5. Apply new connection limits                             │
│  6. Reload whitelist sets                                   │
└─────────────────────────────────────────────────────────────┘
```

### Commands

```bash
# Reload after config changes
nftban ddos reload

# Check current status
nftban ddos status

# Show active limits
nftban ddos show

# Test config without applying (dry-run)
nftban ddos test
```

### Reload Behavior

**Existing connections:** NOT affected (remain open)
**New connections:** Subject to new limits immediately
**Whitelist changes:** Applied immediately to new connections

**Example:**
```bash
# Before reload: DDOS_HTTP_CONN_PER_IP=100
# IP 203.0.113.45 has 80 active connections ✅

# Change to: DDOS_HTTP_CONN_PER_IP=150
nftban ddos reload

# IP 203.0.113.45:
#   - Existing 80 connections: Still open ✅
#   - Can open 70 more (up to new limit of 150) ✅
```

---

## <a name="monitoring"></a>6. MONITORING & TUNING

### Real-Time Statistics

```bash
$ nftban ddos stats

═══════════════════════════════════════════════════════════════
  DDOS Protection Statistics (last hour)
═══════════════════════════════════════════════════════════════

HTTP/HTTPS:
  Allowed: 45,234 connections
  Blocked: 12 connections (0.03%)
  Top blocked: 203.0.113.45 (8 blocks)

  Status: ✅ LOW BLOCK RATE

SSH:
  Allowed: 156 connections
  Blocked: 0 connections (0.00%)

  Status: ✅ NO BLOCKS

SMTP:
  Allowed: 1,234 connections
  Blocked: 18 connections (1.44%)
  Top blocked: 198.51.100.22 (12 blocks)

  Status: ⚠️  HIGH BLOCK RATE - INVESTIGATE

Recommendations:
  - HTTP limits working well (0.03% block rate)
  - SMTP blocks above 1% - check if legitimate
  - Review: nftban ddos blocks --detail

═══════════════════════════════════════════════════════════════
```

### Recent Blocks

```bash
$ nftban ddos blocks --recent

Recent DDOS Blocks (last 20):

Time                Service  IP              Reason
───────────────────────────────────────────────────────────────
2025-10-30 10:45:23 HTTP     203.0.113.45    200+ connections
2025-10-30 10:42:15 SMTP     198.51.100.22   30+ connections
2025-10-30 10:38:44 HTTP     203.0.113.45    200+ connections
2025-10-30 10:35:12 SMTP     198.51.100.22   30+ connections

⚠️  Repeated blocks detected!

IP 203.0.113.45:
  - Blocked 8 times in last hour
  - Service: HTTP
  - Reason: Exceeds limit (200)
  - Current limit: DDOS_HTTP_CONN_PER_IP=200

Possible causes:
  ✓ Legitimate user with many sites
  ✓ CDN health checks
  ✓ Office NAT
  ✗ Attack/bot

Actions:
  1. Investigate: nftban logs --ip 203.0.113.45
  2. Whitelist if legitimate: nftban whitelist add 203.0.113.45
  3. Or increase limit: DDOS_HTTP_CONN_PER_IP=300
```

### Log Monitoring

```bash
# Real-time block log
tail -f /var/log/nftban/ddos-blocks.log

# Example output:
2025-10-30 10:45:23 [DDOS] BLOCK HTTP 203.0.113.45 (200+ connections)
2025-10-30 10:42:15 [DDOS] BLOCK SMTP 198.51.100.22 (30+ connections)
```

### Tuning Guidelines

**Block Rate < 0.1%:** ✅ Perfect - limits are appropriate
**Block Rate 0.1-1%:** ⚠️  Monitor - may need adjustment
**Block Rate > 1%:** 🔴 Review - likely blocking legitimate traffic

**Tuning Process:**
1. Monitor for 24-48 hours
2. Identify patterns in blocks
3. Whitelist legitimate IPs
4. Increase limits if needed
5. Repeat monitoring

---

## <a name="troubleshooting"></a>7. TROUBLESHOOTING

### Problem: Legitimate Users Being Blocked

**Symptoms:**
```
Customer reports: "Can't access my website"
Log shows: 203.0.113.45 blocked for HTTP (150+ connections)
```

**Solution 1: Whitelist the IP**
```bash
# Temporary whitelist (until next reload)
nftban whitelist add 203.0.113.45

# Permanent whitelist (add to config)
vi /etc/nftban/conf.d/ddos.conf
# Add to: DDOS_WHITELIST="...,203.0.113.45"
nftban ddos reload
```

**Solution 2: Increase Limit**
```bash
vi /etc/nftban/conf.d/ddos.conf
# Change: DDOS_HTTP_CONN_PER_IP=150
# To:     DDOS_HTTP_CONN_PER_IP=250
nftban ddos reload
```

---

### Problem: Office Email Constantly Blocked

**Symptoms:**
```
Office staff can't send/receive email
Blocks every few minutes
All from same office IP: 198.51.100.10
```

**Root Cause:** Office behind NAT, all employees share one IP

**Solution:**
```bash
# 1. Whitelist office IP
vi /etc/nftban/conf.d/ddos.conf
DDOS_OFFICE_IPS="198.51.100.10"
DDOS_WHITELIST="127.0.0.1,::1,10.0.0.0/8,192.168.0.0/16,198.51.100.10"

# 2. Or increase mail limits significantly
DDOS_SMTP_CONN_PER_IP=80
DDOS_IMAP_CONN_PER_IP=150

# 3. Reload
nftban ddos reload
```

---

### Problem: Multi-Site Customer Blocked

**Symptoms:**
```
Customer: "I manage 50 websites, can't access them all"
Blocked at 150 HTTP connections
```

**Solution:**
```bash
# Increase HTTP limit for multi-site hosting
vi /etc/nftban/conf.d/ddos.conf
DDOS_HTTP_CONN_PER_IP=300    # 50 sites × 5 conns + buffer

nftban ddos reload
```

---

### Problem: Changes Not Taking Effect

**Check:**
```bash
# 1. Verify config syntax
nftban ddos test

# 2. Check for typos
cat /etc/nftban/conf.d/ddos.conf | grep -v ^#

# 3. Manual reload
nftban ddos reload --force

# 4. Check nftables rules
nft list ruleset | grep -A 10 "ct count"
```

---

## <a name="examples"></a>8. REAL-WORLD EXAMPLES

### Example 1: cPanel Server (30 Sites)

**Scenario:**
- cPanel server with 30 WordPress sites
- 5-person admin team
- Office with 15 employees using email

**Config:**
```bash
# /etc/nftban/conf.d/ddos.conf

# Whitelist
DDOS_WHITELIST="127.0.0.1,::1,10.0.0.0/8,192.168.0.0/16,OFFICE_IP"
DDOS_OFFICE_IPS="198.51.100.0/24"

# HTTP - Conservative for 30 sites
DDOS_HTTP_CONN_PER_IP=250
DDOS_HTTP_RATE_LIMIT=180
DDOS_HTTP_RATE_BURST=360

# SSH - Team server
DDOS_SSH_CONN_PER_IP=20

# Mail - Office use
DDOS_SMTP_CONN_PER_IP=40
DDOS_IMAP_CONN_PER_IP=100
DDOS_POP3_CONN_PER_IP=50

# FTP - Shared hosting
DDOS_FTP_CONN_PER_IP=30
```

**Results after 1 week:**
- Block rate: 0.02% (excellent)
- No legitimate blocks reported
- Successfully blocked 3 actual attacks

---

### Example 2: Single Laravel Application

**Scenario:**
- Single Laravel API
- Behind Cloudflare CDN
- 3-person DevOps team
- No email on this server

**Config:**
```bash
# Whitelist localhost + Cloudflare IPs
DDOS_WHITELIST="127.0.0.1,::1,173.245.48.0/20,103.21.244.0/22,103.22.200.0/22..."

# HTTP - Moderate single app
DDOS_HTTP_CONN_PER_IP=120
DDOS_HTTP_RATE_LIMIT=100
DDOS_HTTP_RATE_BURST=200

# SSH - Small team
DDOS_SSH_CONN_PER_IP=10

# No mail limits (not running mail services)
```

**Results:**
- Block rate: 0.05%
- Cloudflare IPs whitelisted correctly
- Team deployment workflows unaffected

---

### Example 3: Office Email Server

**Scenario:**
- Dedicated email server
- 80 employees
- Each has 2-3 email accounts
- Multiple devices per employee

**Config:**
```bash
# Whitelist office network
DDOS_WHITELIST="127.0.0.1,::1,10.0.0.0/8,192.168.0.0/16"
DDOS_OFFICE_IPS="198.51.100.0/24,203.0.113.0/25"

# HTTP - Webmail only
DDOS_HTTP_CONN_PER_IP=80
DDOS_HTTP_RATE_LIMIT=50
DDOS_HTTP_RATE_BURST=100

# SSH - Minimal
DDOS_SSH_CONN_PER_IP=8

# Mail - HIGH limits for office
DDOS_SMTP_CONN_PER_IP=100
DDOS_IMAP_CONN_PER_IP=200
DDOS_POP3_CONN_PER_IP=100
```

**Calculation:**
- 80 employees × 2.5 accounts average = 200 accounts
- 3 devices per employee = 600 total connections
- Behind office NAT = all from ~3 IPs
- 600 ÷ 3 = 200 IMAP connections per IP

**Results:**
- No blocks during business hours
- Successfully handles morning email rush
- Office staff unaffected

---

## 📝 CHEAT SHEET

### Quick Commands
```bash
# Edit config
vi /etc/nftban/conf.d/ddos.conf

# Reload after changes
nftban ddos reload

# Check status
nftban ddos status

# View statistics
nftban ddos stats

# See recent blocks
nftban ddos blocks --recent

# Whitelist an IP
nftban whitelist add IP_ADDRESS

# Watch logs
tail -f /var/log/nftban/ddos-blocks.log
```

### Safe Starting Values (Conservative)
```bash
DDOS_WHITELIST="127.0.0.1,::1,10.0.0.0/8,192.168.0.0/16,YOUR_OFFICE_IP"
DDOS_HTTP_CONN_PER_IP=200
DDOS_SSH_CONN_PER_IP=15
DDOS_SMTP_CONN_PER_IP=35
DDOS_IMAP_CONN_PER_IP=80
```

### Decision Tree
```
Do you host multiple sites?
  YES → Use 250-300 for HTTP
  NO  → Continue

Is this an office email server?
  YES → Use 100+ for IMAP/SMTP
  NO  → Continue

Single application server?
  YES → Use 120-150 for HTTP
```

---

**END OF GUIDE**

For questions or issues: https://github.com/itcmsgr/nftban/issues

**EOF**
