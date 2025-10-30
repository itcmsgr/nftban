# NFTBan DDOS Protection - Implementation Plan
**Date:** 2025-10-30
**Priority:** 🔴 CRITICAL - Current Defaults Will Break Production

---

## 📋 SUMMARY

**Current State:**
- ❌ DDOS limits enabled by default with aggressive values
- ❌ HTTP: 20 connections per IP (need 120-150+)
- ❌ SSH: 5 connections per IP (need 8-10+)
- ❌ SMTP: 5 connections per IP (need 25+)
- ❌ Will break multi-site hosting, office email, teams

**Proposed State:**
- ✅ Ship with all limits COMMENTED (#) by default
- ✅ Provide reference config with safe examples
- ✅ Create profile templates for common server types
- ✅ Require explicit user enable with warnings
- ✅ Provide autotune to detect and suggest values

---

## 🎯 IMPLEMENTATION APPROACH

### Option A: ALL DISABLED by Default (RECOMMENDED)

**Ship config:**
```bash
# All limits commented - nothing active
#DDOS_CONNLIMIT_SSH="10"
#DDOS_CONNLIMIT_HTTP="150"
#DDOS_CONNLIMIT_SMTP="25"
```

**User enables:**
```bash
# User removes # for what they want
DDOS_CONNLIMIT_SSH="10"
DDOS_CONNLIMIT_HTTP="150"
```

**Pros:**
- ✅ Safe by default - won't break anything
- ✅ User explicitly chooses what to enable
- ✅ Clear understanding of each limit

**Cons:**
- ⚠️  DDOS protection off by default
- ⚠️  Requires user action

---

### Option B: Safe Defaults, Easy Override (ALTERNATIVE)

**Ship config with CONSERVATIVE defaults:**
```bash
# Safe defaults - won't break production
DDOS_CONNLIMIT_SSH="20"        # High limit
DDOS_CONNLIMIT_HTTP="300"      # High limit
DDOS_CONNLIMIT_SMTP="40"       # High limit
```

**With prominent warnings:**
```bash
# ⚠️  IMPORTANT: These are CONSERVATIVE defaults!
# They provide minimal protection to avoid breaking legitimate traffic.
# Run 'nftban ddos autotune' to get optimized values for your server.
```

**Pros:**
- ✅ Some protection by default
- ✅ Won't break most servers

**Cons:**
- ⚠️  Weak protection (high limits)
- ⚠️  May still break edge cases

---

## 📊 CURRENT vs PROPOSED VALUES

### File: `/etc/nftban/conf.d/ddos.conf`

| Setting | Current | Problem | Proposed (Conservative) |
|---------|---------|---------|------------------------|
| `DDOS_CONNLIMIT_SSH` | 5 | ❌ Breaks teams | 20 (or commented) |
| `DDOS_CONNLIMIT_HTTP` | 20 | ❌ Breaks multi-site | 300 (or commented) |
| `DDOS_CONNLIMIT_HTTPS` | 20 | ❌ Breaks multi-site | 300 (or commented) |
| `DDOS_CONNLIMIT_SMTP` | 5 | ❌ Breaks office email | 40 (or commented) |
| `DDOS_CONNLIMIT_IMAP` | ? | Missing | 100 (or commented) |
| `DDOS_CONNLIMIT_POP3` | ? | Missing | 60 (or commented) |

---

## 🏗️ PROFILE TEMPLATES

Create these templates in `/usr/share/nftban/profiles/`:

### 1. `multisite-hosting.conf`
```bash
# Profile: Multi-Site Hosting (cPanel, DirectAdmin, Plesk)
# Best for: 20-100+ websites on one server

DDOS_CONNLIMIT_SSH="20"
DDOS_CONNLIMIT_HTTP="300"
DDOS_CONNLIMIT_HTTPS="300"
DDOS_CONNLIMIT_SMTP="40"
DDOS_CONNLIMIT_IMAP="120"
DDOS_CONNLIMIT_POP3="60"
```

### 2. `single-business.conf`
```bash
# Profile: Single Business Application
# Best for: WordPress, Laravel, single site

DDOS_CONNLIMIT_SSH="10"
DDOS_CONNLIMIT_HTTP="150"
DDOS_CONNLIMIT_HTTPS="150"
DDOS_CONNLIMIT_SMTP="25"
DDOS_CONNLIMIT_IMAP="60"
DDOS_CONNLIMIT_POP3="30"
```

### 3. `api-gateway.conf`
```bash
# Profile: API Gateway / Reverse Proxy
# Best for: Known traffic patterns, controlled environment

DDOS_CONNLIMIT_SSH="8"
DDOS_CONNLIMIT_HTTP="100"
DDOS_CONNLIMIT_HTTPS="100"
DDOS_CONNLIMIT_SMTP="15"
DDOS_CONNLIMIT_IMAP="30"
DDOS_CONNLIMIT_POP3="20"
```

### 4. `office-email.conf`
```bash
# Profile: Office Email Server
# Best for: Dedicated mail server for office

DDOS_CONNLIMIT_SSH="8"
DDOS_CONNLIMIT_HTTP="80"
DDOS_CONNLIMIT_HTTPS="80"
DDOS_CONNLIMIT_SMTP="100"
DDOS_CONNLIMIT_IMAP="200"
DDOS_CONNLIMIT_POP3="100"
```

### 5. `disabled.conf`
```bash
# Profile: All Protections Disabled
# Use for troubleshooting or testing

#DDOS_CONNLIMIT_SSH="0"
#DDOS_CONNLIMIT_HTTP="0"
#DDOS_CONNLIMIT_HTTPS="0"
#DDOS_CONNLIMIT_SMTP="0"
#DDOS_CONNLIMIT_IMAP="0"
#DDOS_CONNLIMIT_POP3="0"
```

---

## 🔧 PROFILE MANAGEMENT COMMANDS

### Apply Profile
```bash
$ nftban ddos profile list

Available profiles:
  1. multisite-hosting   - Multi-site hosting (cPanel, etc.)
  2. single-business     - Single application server
  3. api-gateway         - API/reverse proxy
  4. office-email        - Office email server
  5. disabled            - All protections off
  6. custom              - Current custom configuration

$ nftban ddos profile apply multisite-hosting

⚠️  WARNING: Applying profile will modify DDOS limits!

Current limits will be replaced with:
  SSH connections per IP: 20
  HTTP connections per IP: 300
  HTTPS connections per IP: 300
  SMTP connections per IP: 40
  IMAP connections per IP: 120
  POP3 connections per IP: 60

This profile is recommended for:
  - Multi-site hosting servers
  - cPanel, DirectAdmin, Plesk environments
  - Shared hosting

Type 'YES' to confirm: _
```

### Check Current Profile
```bash
$ nftban ddos profile show

Current DDOS Configuration:
  Profile: custom (not matching any template)

  SSH: 10 connections per IP
  HTTP: 150 connections per IP
  SMTP: 25 connections per IP

Closest matching profile: single-business (85% match)

Suggested action:
  nftban ddos profile apply single-business
```

### Compare Profiles
```bash
$ nftban ddos profile compare single-business multisite-hosting

Comparing: single-business vs multisite-hosting

Setting                  single-business    multisite-hosting   Difference
─────────────────────────────────────────────────────────────────────────
SSH connections/IP                10                   20           +10
HTTP connections/IP              150                  300          +150
SMTP connections/IP               25                   40           +15
IMAP connections/IP               60                  120           +60

Recommendation: Use multisite-hosting if you host 20+ websites
```

---

## 🤖 AUTO-TUNE IMPLEMENTATION

### Command: `nftban ddos autotune`

**Detection Logic:**
```bash
1. Detect RAM/CPU
   └─> <4GB RAM = lower limits
   └─> 4-16GB = moderate limits
   └─> >16GB = higher limits

2. Detect hosting panel
   └─> cPanel/DirectAdmin/Plesk found = multisite-hosting profile
   └─> No panel = check website count

3. Count websites
   └─> >20 sites = multisite-hosting
   └─> 5-20 sites = shared hosting (similar to multisite)
   └─> 1-5 sites = single-business

4. Check running services
   └─> Postfix + Dovecot + many domains = office-email profile
   └─> nginx + single vhost = single-business
   └─> HAProxy/nginx reverse proxy = api-gateway

5. Analyze traffic (if logs available)
   └─> Parse last 24h of logs
   └─> Calculate 95th percentile connections per IP
   └─> Suggest limit = 95th percentile + 50% buffer

6. Suggest profile or custom values
```

**Example Output:**
```bash
$ nftban ddos autotune

═══════════════════════════════════════════════════════════════
  NFTBan DDOS Auto-Tune - Server Analysis
═══════════════════════════════════════════════════════════════

Analyzing server...

SERVER PROFILE:
  RAM: 16 GB
  CPU: 8 cores
  Panel: DirectAdmin detected
  Websites: 42 sites found
  Services: nginx, php-fpm, postfix, dovecot

TRAFFIC ANALYSIS (last 24h):
  HTTP connections per IP:
    Average: 45
    95th percentile: 87
    Peak: 156

  SSH connections per IP:
    Peak: 6

  SMTP connections per IP:
    Peak: 18

RECOMMENDATION: multisite-hosting profile

Suggested limits:
  SSH: 20  (peak 6 + buffer)
  HTTP: 300  (peak 156 × 2 + buffer)
  SMTP: 40  (peak 18 × 2 + buffer)

═══════════════════════════════════════════════════════════════

Apply this profile:
  nftban ddos profile apply multisite-hosting

Or save custom values:
  nftban ddos autotune --save-custom

═══════════════════════════════════════════════════════════════
```

---

## ⚠️  WARNING SYSTEM

### Before ANY DDOS Change

**Show prominent warning:**
```
═══════════════════════════════════════════════════════════════
⚠️  DDOS PROTECTION CONFIGURATION WARNING
═══════════════════════════════════════════════════════════════

You are about to modify DDOS protection limits!

IMPORTANT:
  ✓ Limits that are TOO LOW will block legitimate users
  ✓ Limits that are TOO HIGH provide weak protection
  ✓ ALWAYS whitelist: localhost, office, CDN IPs

BEFORE YOU CONTINUE:
  1. Understand your traffic patterns
  2. Run: nftban ddos autotune (for suggestions)
  3. Start with HIGHER limits, reduce gradually
  4. Monitor logs after changes
  5. Test on non-production first!

Current operation: Enabling SSH limit (10 connections/IP)

This will:
  ✓ Block IPs exceeding 10 SSH connections
  ✓ Affect admin team if they use automation
  ✓ Log blocks to /var/log/nftban/ddos-blocks.log

Have you whitelisted trusted IPs? (yes/no): _
═══════════════════════════════════════════════════════════════
```

### During Reload

```bash
$ nftban ddos reload

Reloading DDOS configuration...

⚠️  Changes detected:
  SSH limit: 5 → 10 (increased ✅)
  HTTP limit: 20 → 150 (increased ✅)

Applying changes...
✅ Configuration loaded
✅ nftables rules updated

Monitoring recommended:
  nftban ddos stats
  tail -f /var/log/nftban/ddos-blocks.log

Done!
```

---

## 📝 RECOMMENDED IMPLEMENTATION STEPS

### Step 1: Update Default Config (URGENT)

**File:** `/etc/nftban/conf.d/ddos.conf`

**Change ALL limits to COMMENTED:**
```bash
# Before:
DDOS_CONNLIMIT_SSH="5"
DDOS_CONNLIMIT_HTTP="20"

# After:
#DDOS_CONNLIMIT_SSH="10"     # Remove # to enable
#DDOS_CONNLIMIT_HTTP="150"   # Remove # to enable
```

### Step 2: Create Profile Templates

**Create directory:**
```bash
mkdir -p /usr/share/nftban/profiles/
```

**Create 5 profile files** (see above)

### Step 3: Update CLI Commands

**Add profile management:**
```bash
nftban ddos profile list
nftban ddos profile apply <name>
nftban ddos profile show
nftban ddos profile compare <profile1> <profile2>
```

### Step 4: Implement Auto-Tune

**Create script:**
`/usr/lib/nftban/core/nftban_ddos_autotune.sh`

**Add command:**
```bash
nftban ddos autotune
nftban ddos autotune --save-custom
```

### Step 5: Add Warning System

**Update:** `/usr/lib/nftban/cli/cmd_ddos.sh`

**Add warnings before:**
- Profile apply
- Manual config changes
- Enable/disable

### Step 6: Update Documentation

**Create/update:**
- `/usr/share/doc/nftban/DDOS_COMPLETE_GUIDE.md` ✅ Done
- Man pages: `man nftban-ddos`
- README section

### Step 7: Migration for Existing Installations

**On update, check if user has custom config:**
```bash
# If /etc/nftban/conf.d/ddos.conf has been modified:
echo "⚠️  DDOS config detected - review recommended values"
echo "Run: nftban ddos autotune"
echo "See: /usr/share/doc/nftban/DDOS_COMPLETE_GUIDE.md"
```

---

## 🚀 ROLLOUT PHASES

### Phase 1: Emergency Fix (v0.10.1 - ASAP)

**Priority:** 🔴 CRITICAL

**Changes:**
1. Comment ALL default limits in ddos.conf
2. Add warning banner to ddos commands
3. Update documentation

**Timeline:** 1-2 days

### Phase 2: Profile System (v0.10.2)

**Priority:** 🟡 HIGH

**Changes:**
1. Create profile templates
2. Implement profile commands
3. Add profile selection to wizard

**Timeline:** 1 week

### Phase 3: Auto-Tune (v0.10.3)

**Priority:** 🟢 MEDIUM

**Changes:**
1. Implement server detection
2. Traffic analysis
3. Automated suggestions

**Timeline:** 2 weeks

---

## ✅ DECISION NEEDED

**Which approach for v0.10.1 emergency fix?**

**Option A: ALL DISABLED (Safest)**
- Ship with everything commented
- No DDOS protection by default
- User explicitly enables

**Option B: CONSERVATIVE DEFAULTS**
- Ship with high limits (300 HTTP, 20 SSH, etc.)
- Weak but safe protection
- Easy to tighten later

**Recommendation:** Option A for v0.10.1, then add profiles in v0.10.2

---

**EOF**
