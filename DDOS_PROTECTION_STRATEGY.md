# NFTBan DDOS Protection Strategy for Production Servers
**Date:** 2025-10-30
**Status:** 🔴 CRITICAL - Current Limits Too Aggressive for Production
**Priority:** HIGH

---

## 🚨 PROBLEM IDENTIFIED

### **Current DDOS Limits are TOO LOW for Production:**

| Service | Current Limit | Production Reality | Result |
|---------|---------------|-------------------|---------|
| **HTTP/HTTPS** | 50-80 conn/IP | Need **120-150+** | ❌ **BREAKS MULTI-SITE SERVERS** |
| **SSH** | 5-8 conn/IP | Need **8-10** | ⚠️ **BLOCKS LEGITIMATE ADMIN** |
| **SMTP** | 10-15 conn/IP | Need **25+** | ❌ **BREAKS OFFICE EMAIL** |
| **IMAP** | 20-30 conn/IP | Need **60-100** | ❌ **BREAKS MAIL CLIENTS** |

### **Real-World Scenarios That WILL FAIL:**

1. **Multi-Site Hosting Server:**
   - 50 WordPress sites on one server
   - Site owner checks 10 sites → **BLOCKED at 50 connections**
   - CDN (Cloudflare) making health checks → **BLOCKED**

2. **Office Email Server:**
   - Office with 10 employees
   - Each has Outlook checking 3 email accounts every 5 min
   - 10 × 3 = 30 IMAP connections → **BLOCKED at 20**

3. **DevOps Team:**
   - 5 admins SSH'ing to server during deployment
   - Each opens 2-3 connections (tmux, scp, etc.)
   - 5 × 3 = 15 connections → **BLOCKED at 8**

---

## 🎯 NEW STRATEGY: Safe-by-Default with Auto-Tune

### **Core Principles:**

1. **Ship with ALL limits DISABLED (commented out)**
2. **Provide auto-tune script to detect server profile**
3. **Require explicit user acknowledgment and understanding**
4. **Show prominent warnings about consequences**
5. **Never break legitimate traffic**

### **Three-Tier Approach:**

```
┌─────────────────────────────────────────────────────────────┐
│  TIER 1: CONSERVATIVE (Default - Auto-Detected)            │
│  ├─ Multi-site hosting, shared hosting, cPanel servers     │
│  ├─ HTTP: 200-300 conn/IP                                  │
│  ├─ SSH: 15 conn/IP                                        │
│  ├─ SMTP: 40 conn/IP                                       │
│  └─ IMAP: 100 conn/IP                                      │
└─────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────┐
│  TIER 2: MODERATE (Single-site, small business)            │
│  ├─ Single application server, small office               │
│  ├─ HTTP: 120-150 conn/IP                                  │
│  ├─ SSH: 10 conn/IP                                        │
│  ├─ SMTP: 25 conn/IP                                       │
│  └─ IMAP: 60 conn/IP                                       │
└─────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────┐
│  TIER 3: AGGRESSIVE (Edge/proxy, known traffic patterns)   │
│  ├─ Reverse proxy, API gateway, controlled environment     │
│  ├─ HTTP: 80-100 conn/IP                                   │
│  ├─ SSH: 8 conn/IP                                         │
│  ├─ SMTP: 15 conn/IP                                       │
│  └─ IMAP: 30 conn/IP                                       │
└─────────────────────────────────────────────────────────────┘
```

---

## 📋 IMPLEMENTATION PLAN

### **Step 1: Ship Safe Config (ALL DISABLED)**

**New file:** `/etc/nftban/conf.d/ddos.conf.REFERENCE`

```bash
# ═══════════════════════════════════════════════════════════════
# NFTBan DDOS Protection - REFERENCE CONFIGURATION
# ═══════════════════════════════════════════════════════════════
#
# ⚠️  WARNING: DO NOT COPY THIS FILE AS-IS!
# ⚠️  These limits WILL BLOCK legitimate traffic if misconfigured!
#
# INSTRUCTIONS:
# 1. Run: nftban ddos autotune
# 2. Review suggested limits for YOUR server profile
# 3. Copy ONLY the limits you understand and need
# 4. Test thoroughly before deploying to production
#
# ═══════════════════════════════════════════════════════════════

# ────────────────────────────────────────────────────────────────
# HTTP/HTTPS LIMITS
# ────────────────────────────────────────────────────────────────
#
# TYPICAL VALUES:
# - Multi-site hosting: 200-300
# - Single-site business: 120-150
# - API/reverse proxy: 80-100
#
# CURRENT SETTING: DISABLED (no limit)
#DDOS_HTTP_CONN_PER_IP=150
#DDOS_HTTP_RATE_LIMIT=100   # requests per second
#DDOS_HTTP_RATE_BURST=200   # burst allowance

# ────────────────────────────────────────────────────────────────
# SSH LIMITS
# ────────────────────────────────────────────────────────────────
#
# TYPICAL VALUES:
# - DevOps team (5-10 admins): 15
# - Small team (2-5 admins): 10
# - Single admin: 8
#
# CURRENT SETTING: DISABLED (no limit)
#DDOS_SSH_CONN_PER_IP=10

# ────────────────────────────────────────────────────────────────
# SMTP LIMITS
# ────────────────────────────────────────────────────────────────
#
# TYPICAL VALUES:
# - Office server (10+ users): 40
# - Small office (5-10 users): 25
# - Personal/relay: 15
#
# CURRENT SETTING: DISABLED (no limit)
#DDOS_SMTP_CONN_PER_IP=25

# ────────────────────────────────────────────────────────────────
# IMAP/POP3 LIMITS
# ────────────────────────────────────────────────────────────────
#
# TYPICAL VALUES:
# - Office with many accounts: 100
# - Small office: 60
# - Personal: 30
#
# CURRENT SETTING: DISABLED (no limit)
#DDOS_IMAP_CONN_PER_IP=60
#DDOS_POP3_CONN_PER_IP=30

# ────────────────────────────────────────────────────────────────
# WHITELIST (ALWAYS configure these!)
# ────────────────────────────────────────────────────────────────
#
# CRITICAL: Whitelist these to avoid self-blocking:
# - Localhost: 127.0.0.1, ::1
# - Private networks: 10.0.0.0/8, 192.168.0.0/16
# - Office/VPN IPs
# - CDN IPs (Cloudflare, etc.)
# - Monitoring service IPs
#
#DDOS_WHITELIST="127.0.0.1,::1,10.0.0.0/8,192.168.0.0/16"
#DDOS_OFFICE_IPS="203.0.113.0/24"  # Your office network

# ═══════════════════════════════════════════════════════════════
# END OF REFERENCE CONFIGURATION
# ═══════════════════════════════════════════════════════════════
```

### **Step 2: Auto-Tune Script**

**Command:** `nftban ddos autotune`

**What it does:**
1. Detects server profile (RAM, CPU, hosting panel)
2. Analyzes running services
3. Counts websites/domains
4. Checks existing traffic patterns (if logs available)
5. **Suggests** appropriate limits
6. **Does NOT apply automatically**

**Output:**
```
═══════════════════════════════════════════════════════════════
  NFTBan DDOS Auto-Tune - Server Profile Analysis
═══════════════════════════════════════════════════════════════

SERVER PROFILE DETECTED:
  Type: Multi-site Hosting Server
  RAM: 16 GB
  CPU: 8 cores
  Panel: DirectAdmin
  Websites: 42 sites detected
  Services: nginx, php-fpm, mariadb, postfix, dovecot

CURRENT TRAFFIC ANALYSIS (last 24h):
  HTTP connections per IP (95th percentile): 87
  HTTP requests per second (peak): 156
  SSH connections (max concurrent): 6
  SMTP connections per IP (peak): 18
  IMAP connections per IP (peak): 45

RECOMMENDED TIER: CONSERVATIVE
─────────────────────────────────────────────────────────────

SUGGESTED LIMITS:

# HTTP/HTTPS - Tier 1: Conservative
DDOS_HTTP_CONN_PER_IP=250      # Multi-site: 42 sites × 5 conns + buffer
DDOS_HTTP_RATE_LIMIT=180       # Peak 156 + 15% buffer
DDOS_HTTP_RATE_BURST=360       # 2× rate limit

# SSH - Moderate
DDOS_SSH_CONN_PER_IP=12        # Current peak 6 + 100% buffer

# SMTP - Conservative
DDOS_SMTP_CONN_PER_IP=35       # Current peak 18 + 94% buffer

# IMAP - Conservative
DDOS_IMAP_CONN_PER_IP=90       # Current peak 45 + 100% buffer

# WHITELIST (CRITICAL - ALWAYS CONFIGURE!)
DDOS_WHITELIST="127.0.0.1,::1,10.0.0.0/8,192.168.0.0/16"

═══════════════════════════════════════════════════════════════

⚠️  IMPORTANT WARNINGS:

1. These limits will BLOCK traffic exceeding the thresholds
2. ALWAYS whitelist: localhost, private networks, office IPs, CDNs
3. Monitor logs after applying: /var/log/nftban/ddos-blocks.log
4. Start with HIGHER limits, then reduce gradually
5. Test on non-production first!

NEXT STEPS:

1. Review suggested limits above
2. Adjust as needed for your use case
3. Save to: /etc/nftban/conf.d/ddos.conf
4. Test: nftban ddos test
5. Apply: nftban ddos enable
6. Monitor: nftban ddos stats

SAVE THESE SETTINGS:
  nftban ddos autotune --save /etc/nftban/conf.d/ddos.conf

OR manually copy the settings you want from above.

═══════════════════════════════════════════════════════════════
```

### **Step 3: Explicit Enable with Confirmation**

**Command:** `nftban ddos enable`

**Flow:**
```bash
$ nftban ddos enable

⚠️  WARNING: DDOS Protection is NOT configured!

Current status: DISABLED (no limits active)

To enable DDOS protection:

1. Run auto-tune to analyze your server:
   nftban ddos autotune

2. Review and configure limits:
   vi /etc/nftban/conf.d/ddos.conf

3. Test configuration (dry-run):
   nftban ddos test

4. Enable with confirmation:
   nftban ddos enable --confirm

═══════════════════════════════════════════════════════════════

$ nftban ddos enable --confirm

⚠️  FINAL CONFIRMATION REQUIRED

You are about to enable DDOS protection with these limits:
  HTTP connections per IP: 150
  SSH connections per IP: 10
  SMTP connections per IP: 25
  IMAP connections per IP: 60

These limits will BLOCK traffic exceeding thresholds!

Have you:
  [✓] Run auto-tune to analyze your server?
  [✓] Configured whitelist for localhost/office/CDN?
  [✓] Tested on non-production environment?
  [✓] Reviewed monitoring and logs?

Type 'I UNDERSTAND' to confirm: _
```

---

## 📚 DOCUMENTATION STRUCTURE

### **1. Quick Start (Prominently Displayed)**

```markdown
# ⚠️  IMPORTANT: DDOS Protection is DISABLED by default

NFTBan ships with DDOS protection DISABLED to avoid breaking legitimate
traffic. You MUST configure it for your specific server profile.

NEVER copy example configs blindly - they WILL block legitimate users!

Follow these steps:
1. nftban ddos autotune       # Analyze your server
2. Review suggested limits    # Understand each setting
3. nftban ddos test           # Test without applying
4. nftban ddos enable --confirm  # Enable with confirmation
5. nftban ddos stats          # Monitor blocks

See: DDOS_PROTECTION_GUIDE.md for detailed instructions
```

### **2. Comprehensive Guide**

**File:** `DDOS_PROTECTION_GUIDE.md`

Sections:
- Understanding DDOS Protection
- Server Profiles and Recommended Limits
- Auto-Tune Explained
- Whitelist Configuration (CRITICAL)
- Testing Before Production
- Monitoring and Tuning
- Troubleshooting Blocked Legitimate Traffic
- Case Studies (multi-site, office, single-app)

### **3. Man Pages**

- `man nftban-ddos` - Overview
- `man nftban-ddos-autotune` - Auto-tune guide
- `man nftban-ddos-config` - Configuration reference

---

## 🔧 TECHNICAL IMPLEMENTATION

### **New Module Structure:**

```
/usr/lib/nftban/modules/
├── nftban_ddos.sh              # Main DDOS module
├── nftban_ddos_autotune.sh     # Auto-tune logic
├── nftban_ddos_profiles.sh     # Server profile detection
└── nftban_ddos_monitor.sh      # Real-time monitoring

/etc/nftban/conf.d/
├── ddos.conf.REFERENCE         # Reference (all commented)
├── ddos.conf.EXAMPLE-multisite # Example: multi-site
├── ddos.conf.EXAMPLE-office    # Example: office server
└── ddos.conf.EXAMPLE-single    # Example: single app

/usr/share/doc/nftban/
└── DDOS_PROTECTION_GUIDE.md    # Comprehensive guide
```

### **Warning System:**

**Every DDOS-related command shows:**
```
═══════════════════════════════════════════════════════════════
⚠️  DDOS PROTECTION WARNING
═══════════════════════════════════════════════════════════════

Misconfigured DDOS limits WILL block legitimate traffic!

Before making changes:
1. Understand your traffic patterns
2. Whitelist trusted IPs (localhost, office, CDN)
3. Test in non-production first
4. Monitor logs after changes

Current status: ENABLED with limits
Active blocks (last hour): 23 IPs
Recent blocks: Run 'nftban ddos blocks --recent'

═══════════════════════════════════════════════════════════════
```

---

## 📊 MONITORING & FEEDBACK LOOP

### **Real-Time Monitoring:**

```bash
$ nftban ddos stats

DDOS Protection Statistics (last hour)

HTTP/HTTPS:
  Connections allowed: 45,234
  Connections blocked: 12 (0.03%)
  Top blocked IP: 203.0.113.45 (8 blocks)

SSH:
  Connections allowed: 156
  Connections blocked: 0 (0.00%)

SMTP:
  Connections allowed: 1,234
  Connections blocked: 3 (0.24%)
  Top blocked IP: 198.51.100.22 (2 blocks)

⚠️  Recommendations:
  - HTTP blocks are low (0.03%) - limits OK
  - SMTP blocks detected - review if legitimate
  - Run: nftban ddos blocks --detail
```

### **Block Analysis:**

```bash
$ nftban ddos blocks --recent

Recent DDOS Blocks (last 10):

2025-10-30 10:45:23  HTTP  203.0.113.45   150+ connections
2025-10-30 10:42:15  SMTP  198.51.100.22  25+ connections
2025-10-30 10:38:44  HTTP  203.0.113.45   150+ connections

⚠️  203.0.113.45 blocked multiple times!

Possible causes:
  - Legitimate user with many sites on server
  - CDN health checks
  - Office network NAT

Actions:
  - Whitelist: nftban ddos whitelist add 203.0.113.45
  - Increase limit: Edit /etc/nftban/conf.d/ddos.conf
  - Investigate: nftban logs --ip 203.0.113.45
```

---

## 🎯 RECOMMENDED VALUES BY SERVER TYPE

### **Multi-Site Hosting (cPanel, DirectAdmin, Plesk)**

```bash
# Conservative - supports 50+ sites per server
DDOS_HTTP_CONN_PER_IP=300
DDOS_HTTP_RATE_LIMIT=200
DDOS_HTTP_RATE_BURST=400
DDOS_SSH_CONN_PER_IP=15
DDOS_SMTP_CONN_PER_IP=40
DDOS_IMAP_CONN_PER_IP=120
```

**Rationale:**
- 50 sites × 4 conns each = 200 + buffer = 300
- Admins manage multiple customer accounts via SSH
- Email users check multiple domain accounts

### **Single Application Server (WordPress, Laravel, etc.)**

```bash
# Moderate - single application
DDOS_HTTP_CONN_PER_IP=150
DDOS_HTTP_RATE_LIMIT=120
DDOS_HTTP_RATE_BURST=240
DDOS_SSH_CONN_PER_IP=10
DDOS_SMTP_CONN_PER_IP=25
DDOS_IMAP_CONN_PER_IP=60
```

**Rationale:**
- Single site, moderate concurrent users
- Small admin team
- Office email with ~10 employees

### **Reverse Proxy / API Gateway**

```bash
# Aggressive - controlled traffic patterns
DDOS_HTTP_CONN_PER_IP=100
DDOS_HTTP_RATE_LIMIT=80
DDOS_HTTP_RATE_BURST=160
DDOS_SSH_CONN_PER_IP=8
DDOS_SMTP_CONN_PER_IP=15
DDOS_IMAP_CONN_PER_IP=30
```

**Rationale:**
- Known traffic patterns
- Backend behind load balancer
- Fewer admin connections

---

## 🚀 ROLLOUT PLAN

### **Phase 1: Update Existing Installations (v0.10.1)**

1. Ship new reference config (all commented)
2. Add warning to existing ddos.conf files
3. Provide migration command: `nftban ddos migrate`
4. Auto-detect if current limits are too aggressive
5. Notify users to run autotune

### **Phase 2: New Installations (v0.10.1+)**

1. No DDOS limits enabled by default
2. Post-install message guides users to autotune
3. First run wizard offers to configure DDOS
4. Explicit confirmation required to enable

### **Phase 3: Continuous Improvement**

1. Collect anonymized stats on block rates
2. Machine learning suggestions
3. Adaptive limits based on traffic patterns

---

## 📝 KEY TAKEAWAYS

1. ✅ **Ship DISABLED by default** - no limits unless explicitly configured
2. ✅ **Auto-tune script** - analyzes server and suggests appropriate limits
3. ✅ **Prominent warnings** - users must acknowledge risks
4. ✅ **Reference config** - all values commented with explanations
5. ✅ **Monitoring & feedback** - track blocks, adjust limits
6. ✅ **Whitelist enforcement** - require localhost/office/CDN whitelisting
7. ✅ **Documentation** - comprehensive guide with real scenarios
8. ✅ **Testing mode** - dry-run before applying changes

---

**Next Steps:**
1. Create `nftban_ddos_autotune.sh` script
2. Create reference configs for each server type
3. Update module to show warnings
4. Write comprehensive documentation
5. Test on lab servers before production rollout

**EOF**
