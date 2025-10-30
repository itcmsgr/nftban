# NFTBan v0.10.0 - Core nftables Architecture (REFINED)
**Date:** 2025-10-27
**Status:** ✅ Ready for Go Integration & GeoIP Discussion
**Focus:** Core firewall rules ONLY (DDoS in separate module)

═══════════════════════════════════════════════════════════════════════════════

## ✅ CONFIRMED - CORE ARCHITECTURE

### Tables & Sets (FINAL):
```
TABLE: ip nftban_v4
├── Set: whitelist        (ipv4_addr, interval)
├── Set: temp_ban         (ipv4_addr, timeout 1h)
├── Set: user_blacklist   (ipv4_addr, interval)
├── Set: system_blacklist (ipv4_addr, interval)
└── Set: feeds            (ipv4_addr, interval, auto-merge)

TABLE: ip6 nftban_v6
├── Set: whitelist        (ipv6_addr, interval)
├── Set: temp_ban         (ipv6_addr, timeout 1h)
├── Set: user_blacklist   (ipv6_addr, interval)
├── Set: system_blacklist (ipv6_addr, interval)
└── Set: feeds            (ipv6_addr, interval, auto-merge)
```

### Core INPUT Chain Rules (SIMPLIFIED - No DDoS):

```nft
# =============================================================================
# PHASE 1: CONNECTION TRACKING (Performance)
# =============================================================================
RULE 1: ct state established,related → ACCEPT
RULE 2: iif lo → ACCEPT

# =============================================================================
# PHASE 2: WHITELIST (Security - MUST BE FIRST!)
# =============================================================================
RULE 3: ip saddr @whitelist → ACCEPT ⭐ CRITICAL!

# =============================================================================
# PHASE 3: PROTOCOL ACCEPTS
# =============================================================================
RULE 4: icmp type { echo-request, echo-reply } → ACCEPT
RULE 5: tcp dport <ssh_port> → ACCEPT ⭐ SSH SAFETY

# =============================================================================
# PHASE 4: PORT RULES (From Config)
# =============================================================================
RULE 6: [Dynamic port rules from /etc/nftban/ports.conf]

# =============================================================================
# PHASE 5: SECURITY DROPS
# =============================================================================
RULE 7: ct state invalid → DROP

# =============================================================================
# PHASE 6: BLACKLISTS (Ordered by Priority)
# =============================================================================
RULE 8:  ip saddr @temp_ban → DROP
RULE 9:  ip saddr @user_blacklist → DROP
RULE 10: ip saddr @system_blacklist → DROP
RULE 11: ip saddr @feeds → DROP

# =============================================================================
# IMPLICIT ACCEPT (policy: accept)
# =============================================================================
```

**NOTE:** DDoS rate limiting will be in separate DDoS module with its own chains!

═══════════════════════════════════════════════════════════════════════════════

## 📝 LOGGING ARCHITECTURE (DECIDED)

### User Decision: Config file + .local override ✅

**Config File Structure:**

```bash
# /etc/nftban/nftables_logging.conf
# ============================================================================
# NFTBan nftables Logging Configuration
# ============================================================================

# Global logging toggle
NFTABLES_LOGGING_ENABLED=1

# What to log (0=disabled, 1=enabled)
LOG_TEMP_BAN_DROPS=1
LOG_USER_BLACKLIST_DROPS=1
LOG_SYSTEM_BLACKLIST_DROPS=1
LOG_FEEDS_DROPS=0          # Usually too noisy
LOG_CT_INVALID_DROPS=1
LOG_RATE_LIMIT_DROPS=0     # Handled by DDoS module

# Log prefix format
LOG_PREFIX_FORMAT="NFTBAN"  # Simple or "NFTBAN_STRUCTURED"

# Rate limit for logs (prevent log flood)
LOG_RATE_LIMIT=5           # Max logs per minute per rule
LOG_RATE_BURST=2           # Burst allowance

# Log level (for structured logging)
LOG_LEVEL=info             # debug, info, warning, error
```

**Local Override:**
```bash
# /etc/nftban/nftables_logging.conf.local
# User overrides (takes precedence)
LOG_TEMP_BAN_DROPS=1
LOG_FEEDS_DROPS=1          # User wants to see feed blocks
```

**How Bash Reads Config:**
```bash
# Load main config
source /etc/nftban/nftables_logging.conf

# Override with local config (if exists)
[[ -f /etc/nftban/nftables_logging.conf.local ]] && \
    source /etc/nftban/nftables_logging.conf.local
```

**Generated nftables Rules (Example):**
```nft
# If LOG_TEMP_BAN_DROPS=1:
nft add rule ip nftban_v4 input \
    ip saddr @temp_ban \
    limit rate 5/minute burst 2 packets \
    log prefix "NFTBAN: temp_ban " \
    drop

# If LOG_USER_BLACKLIST_DROPS=1:
nft add rule ip nftban_v4 input \
    ip saddr @user_blacklist \
    limit rate 5/minute burst 2 packets \
    log prefix "NFTBAN: user_blacklist " \
    drop

# If LOG_FEEDS_DROPS=0 (disabled):
nft add rule ip nftban_v4 input \
    ip saddr @feeds \
    drop  # No log
```

**Benefits:**
- ✅ User-friendly (simple key=value format)
- ✅ Override support (.local file)
- ✅ No logging if disabled (performance)
- ✅ Rate limit prevents log flood

═══════════════════════════════════════════════════════════════════════════════

## 🔄 DISCUSSION #1: Go Integration & File Sync

### Current Understanding:

**We have:**
- Go binary: `nftban-geoip` (ultra-fast GeoIP lookups)
- Bash: nftables management, file reading, rule creation

**Questions:**

### Q1: What does Go handle?

**Option A: Go = IP Validator Only**
```
Flow:
1. Bash reads IP from file/command
2. Bash calls: echo "1.2.3.4" | nftban-geoip validate
3. Go validates IP format (IPv4/IPv6, CIDR, etc.)
4. Go returns: valid/invalid
5. Bash proceeds with nftables operation
```
Pros: Simple, minimal Go
Cons: Go underutilized

**Option B: Go = IP + GeoIP Handler**
```
Flow:
1. Bash reads IP from file/command
2. Bash calls: nftban-geoip check 1.2.3.4
3. Go validates IP + checks country
4. Go returns: valid, country=US
5. Bash decides action based on country
6. Bash adds to nftables
```
Pros: Go handles all IP logic
Cons: Still Bash-centric

**Option C: Go = Full IP Manager** (recommended?)
```
Flow:
1. Bash creates nftables tables/sets/rules (architecture)
2. Bash delegates IP operations to Go:
   - Add IP: nftban-geoip add --set=temp_ban --ip=1.2.3.4
   - Remove IP: nftban-geoip remove --set=temp_ban --ip=1.2.3.4
   - Search IP: nftban-geoip search 1.2.3.4
3. Go handles:
   - IP validation
   - GeoIP lookup
   - nftables set manipulation (via nft command)
   - File sync (save to files)
4. Bash handles:
   - Rule order
   - Chain management
   - Port configuration
   - Reports
```
Pros: Clear separation (Bash=architecture, Go=data)
Cons: Go needs nftables permissions

**YOUR CHOICE:** Which option? (A, B, C, or describe different approach)

---

### Q2: File Sync Logic

**Current files:**
```
/etc/nftban/whitelist.conf
/etc/nftban/blacklist.conf
/etc/nftban/whitelist.conf.local
/etc/nftban/blacklist.conf.local
```

**Sync Scenarios:**

**Scenario 1: Boot/Restart**
```
System boots → nftables sets empty
WHO loads IPs from files to nftables?
- Option A: Bash reads files → Bash loads to nftables
- Option B: Go reads files → Go loads to nftables
- Option C: Bash calls: nftban-geoip sync-all
```

**Scenario 2: Add IP via Command**
```
User: nftban ban 1.2.3.4
WHO adds IP to nftables AND file?
- Option A: Bash adds to nftables, Bash appends to file
- Option B: Bash calls Go, Go does both
- Option C: Bash adds to nftables, Go syncs to file (async)
```

**Scenario 3: Edit File Manually**
```
Admin edits /etc/nftban/blacklist.conf
WHO reloads nftables?
- Option A: Admin runs: nftban reload
- Option B: Go watches file (inotify), auto-reloads
- Option C: Systemd timer runs sync every X minutes
```

**YOUR CHOICE:** How should sync work? (describe flow)

---

### Q3: Go Binary Interface

**How does Bash communicate with Go?**

**Option A: Command Line (Simple)**
```bash
# Validate IP
nftban-geoip validate 1.2.3.4
echo $?  # 0=valid, 1=invalid

# Check GeoIP
COUNTRY=$(nftban-geoip country 1.2.3.4)
echo $COUNTRY  # US, CN, RU, etc.

# Add to set
nftban-geoip add-to-set --set=temp_ban --ip=1.2.3.4 --timeout=3600
```
Pros: Simple, no dependencies
Cons: Process spawn overhead

**Option B: JSON API (Structured)**
```bash
# Input (JSON)
echo '{"action":"add","set":"temp_ban","ip":"1.2.3.4","timeout":3600}' | nftban-geoip

# Output (JSON)
{"status":"success","country":"US","message":"IP added"}
```
Pros: Structured, easy to parse
Cons: Need jq or JSON parsing in Bash

**Option C: Unix Socket (Fast)**
```bash
# Go runs as daemon with Unix socket
echo "ADD temp_ban 1.2.3.4 3600" | socat - UNIX-CONNECT:/run/nftban/geoip.sock
```
Pros: Fast, no process spawn
Cons: Go daemon required, complexity

**Option D: Hybrid (CLI for simple, Socket for bulk)**
```bash
# Simple operations: CLI
nftban-geoip validate 1.2.3.4

# Bulk operations: Socket
cat ip_list.txt | nftban-geoip bulk-add --set=feeds
```
Pros: Best of both worlds
Cons: Two interfaces to maintain

**YOUR CHOICE:** Which interface? (A, B, C, D, or other)

═══════════════════════════════════════════════════════════════════════════════

## 🌍 DISCUSSION #2: GeoIP Logic

### Current Understanding:

**We have:**
- Go binary with GeoIP database (GeoLite2)
- Ultra-fast lookups (tested, working)

**Questions:**

### Q1: When to Check GeoIP?

**Option A: Pre-Check (Before nftables)**
```
Flow:
1. Detect attack from IP 1.2.3.4
2. Check GeoIP: nftban-geoip country 1.2.3.4 → CN
3. Check config: Is CN blocked? → YES
4. Ban IP: Add to @temp_ban set
5. nftables blocks future packets
```
Pros: Flexible (can change country rules without nftables reload)
Cons: First packet from country not blocked (small delay)

**Option B: Pre-Populate nftables**
```
Flow:
1. Admin enables: nftban geoip block CN RU
2. Go queries GeoIP database for all CN/RU IPs
3. Go adds ALL CN/RU IPs to nftables set
4. nftables blocks immediately
```
Pros: Immediate blocking at firewall level
Cons: HUGE IP lists (millions!), impractical

**Option C: Hybrid (Pre-check + Cache)**
```
Flow:
1. Detect attack from IP 1.2.3.4
2. Check GeoIP: CN → Blocked
3. Add to @system_blacklist (permanent set)
4. Future attacks from 1.2.3.4 → Blocked by nftables (no GeoIP check)
5. Periodic: Go scans @temp_ban, checks GeoIP, moves to @system_blacklist if country blocked
```
Pros: Balance of flexibility and performance
Cons: Two code paths

**YOUR CHOICE:** Which option? (A, B, C, or describe different approach)

---

### Q2: Which nftables Set for GeoIP?

**If we add GeoIP-blocked IPs to nftables, which set?**

**Option A: New Set (geoip_blocked)**
```nft
nft add set ip nftban_v4 geoip_blocked { type ipv4_addr; flags interval; }
nft add rule ip nftban_v4 input ip saddr @geoip_blocked drop
```
Pros: Clear separation (can see GeoIP blocks vs manual blocks)
Cons: New set to manage, rule order needs updating

**Option B: Use system_blacklist**
```
Just add GeoIP-blocked IPs to existing @system_blacklist set
No new set, no new rule
```
Pros: Simple, reuses existing infrastructure
Cons: Can't distinguish GeoIP blocks from other auto-blocks

**Option C: Use feeds**
```
Treat GeoIP like a threat feed
Add to @feeds set
```
Pros: Logical grouping (external intelligence)
Cons: Mixed with actual threat feeds

**YOUR CHOICE:** Which set? (A, B, C, or other)

---

### Q3: GeoIP Config Format

**How does user configure GeoIP blocking?**

**Option A: Simple List**
```bash
# /etc/nftban/geoip.conf
GEOIP_ENABLED=1
GEOIP_BLOCKED_COUNTRIES="CN,RU,KP"
GEOIP_ALLOWED_COUNTRIES=""  # Empty = all except blocked
GEOIP_WHITELIST_EXCEPTIONS=1  # Whitelist overrides GeoIP
```

**Option B: Action-Based**
```bash
# /etc/nftban/geoip.conf
GEOIP_ENABLED=1

# Actions: DROP, REJECT, LOG, ALLOW
GEOIP_ACTION_CN=DROP
GEOIP_ACTION_RU=DROP
GEOIP_ACTION_US=ALLOW
GEOIP_ACTION_DEFAULT=ALLOW  # For countries not listed
```

**Option C: JSON (Structured)**
```json
{
  "enabled": true,
  "default_action": "allow",
  "countries": {
    "CN": "drop",
    "RU": "drop",
    "KP": "drop",
    "US": "allow"
  },
  "whitelist_override": true
}
```

**YOUR CHOICE:** Which format? (A, B, C, or other)

---

### Q4: GeoIP + Whitelist Priority

**What if IP is whitelisted BUT from blocked country?**

**Example:**
```
IP: 1.2.3.4 (country: CN)
CN is blocked
BUT 1.2.3.4 is in whitelist
```

**Option A: Whitelist ALWAYS wins**
```
Check order:
1. Is IP in whitelist? → YES → ALLOW (skip GeoIP check)
2. Check GeoIP → (never reached)
```
Pros: Whitelist is absolute
Cons: Can't block whitelisted IPs by country

**Option B: GeoIP ALWAYS wins**
```
Check order:
1. Check GeoIP → CN → BLOCKED
2. (Whitelist never checked for blocked countries)
```
Pros: Country blocking absolute
Cons: Breaks whitelist guarantee!

**Option C: User configurable**
```bash
# /etc/nftban/geoip.conf
GEOIP_WHITELIST_OVERRIDE=1  # 1=whitelist wins, 0=geoip wins
```

**YOUR CHOICE:** Which priority? (A, B, C)

**RECOMMENDATION:** Option A (whitelist always wins) for security consistency

═══════════════════════════════════════════════════════════════════════════════

## 📋 SUMMARY - NEED YOUR DECISIONS

### CONFIRMED (No More Discussion):
- ✅ Tables: nftban_v4, nftban_v6
- ✅ Sets: 5 sets (whitelist, temp_ban, user_blacklist, system_blacklist, feeds)
- ✅ Rule order: 11 core rules (no DDoS in core)
- ✅ Logging: Config file + .local override
- ✅ DDoS: Separate module (don't add to core rules)
- ✅ Feeds: Discuss later
- ✅ Port format: PORT|PROTOCOL (T/U/B)

### NEED YOUR ANSWERS:

**Go Integration:**
1. What does Go handle? (Validator only? IP+GeoIP? Full IP manager?)
2. File sync: Who loads files to nftables? (Bash? Go? Both?)
3. Bash-Go interface? (CLI? JSON? Socket? Hybrid?)

**GeoIP:**
1. When check? (Pre-check? Pre-populate? Hybrid?)
2. Which set? (New geoip_blocked? system_blacklist? feeds?)
3. Config format? (Simple list? Action-based? JSON?)
4. Whitelist priority? (Whitelist wins? GeoIP wins? Configurable?)

═══════════════════════════════════════════════════════════════════════════════

**⏳ WAITING FOR YOUR DECISIONS ON GO INTEGRATION & GEOIP!** 🎯
