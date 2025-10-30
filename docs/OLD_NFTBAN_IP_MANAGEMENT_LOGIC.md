# OLD NFTBan (v0.9.x) - IP Management & Search Logic
**Date:** 2025-10-27
**Purpose:** Document OLD nftban IP management for migration to v0.10.0
**Status:** STEP 1 COMPLETE - Ready for Migration Planning

═══════════════════════════════════════════════════════════════════════════════

## 🔍 IP SEARCH LOGIC

### Search Priority (Highest to Lowest):

```
PRIORITY 1: WHITELIST (Highest - Never Ban)
    ├─ Files: whitelist_ips.conf, whitelist_ips.conf.local
    └─ nftables: @whitelist set
           ↓
PRIORITY 2: TEMPORARY BANS
    └─ nftables: @temp_ban set (with 1h timeout)
           ↓
PRIORITY 3: PERMANENT BLACKLIST
    ├─ Files: blacklist_ips.conf, blacklist_ips.conf.local
    ├─ nftables: @user_blacklist set (manual bans)
    └─ nftables: @system_blacklist set (automatic bans)
           ↓
PRIORITY 4: THREAT FEEDS (Lowest - Last Resort)
    ├─ Files: feeds/*-blacklist.conf
    └─ nftables: @feeds set
```

### Search Function Flow:

```
nftban_search_ip(IP)
    │
    ├─► Validate IP (sanitize, normalize IPv4-mapped IPv6)
    │
    ├─► Detect IP family (v4 or v6)
    │
    ├─► SEARCH 1: Whitelist
    │   ├─ Search in files (whitelist_ips.conf*)
    │   └─ Search in nftables (@whitelist)
    │   └─ IF FOUND: Return "WHITELISTED" (status=10)
    │
    ├─► SEARCH 2: Temporary Bans (if not whitelisted)
    │   └─ Search in nftables (@temp_ban)
    │   └─ IF FOUND: Return "TEMP_BANNED" (status=20)
    │
    ├─► SEARCH 3: Permanent Blacklist (if not above)
    │   ├─ Search in files (blacklist_ips.conf*)
    │   ├─ Search in nftables (@user_blacklist)
    │   └─ Search in nftables (@system_blacklist)
    │   └─ IF FOUND: Return "PERM_BANNED" (status=30)
    │
    ├─► SEARCH 4: Threat Feeds (if not above)
    │   ├─ Search in feed files (feeds/*-blacklist.conf)
    │   └─ Search in nftables (@feeds)
    │   └─ IF FOUND: Return "IN_FEEDS" (status=40)
    │
    └─► DEFAULT: Return "CLEAN" (status=0)
```

### Search Methods:

**1. File Search (with CIDR support):**
```bash
_nftban_search_in_file(IP, FILE)
├─ Acquire shared lock (flock -s) # Allows concurrent reads
├─ Search for exact IP match (regex: ^[[:space:]]*IP([[:space:]]|#|$))
├─ Also check CIDR ranges in file
│  └─ Use ipcalc to check if IP is in CIDR range
└─ Return 0 if found, 1 if not
```

**2. nftables Set Search:**
```bash
_nftban_search_in_nftables_set(IP, SET_NAME, FAMILY)
├─ Check if set exists
├─ Use `nft get element` for O(1) lookup (FAST!)
│  └─ nft get element <family> <table> <set> "{ IP }"
└─ Fallback: list + grep (older nftables versions)
```

**3. Special Security Features:**
- **IPv4-mapped IPv6 normalization:** `::ffff:192.168.1.1` → `192.168.1.1`
- **Regex injection prevention:** Escape special chars before grep
- **CIDR range matching:** Check if IP is within CIDR blocks
- **Input sanitization:** Reject shell metacharacters ($`;&|<>(){}[]\'")
- **TOCTOU protection:** Atomic operations with flock

═══════════════════════════════════════════════════════════════════════════════

## 🚫 BAN OPERATION (Add IP to Blacklist)

### Ban Function Flow:

```
nftban_blacklist_ban_ip(IP, JAIL, BAN_TIME)
    │
    ├─► 1. Validate IP
    │
    ├─► 2. Check rate limit (max 60 bans/min)
    │   └─ IF EXCEEDED: Return ERROR "Rate limit exceeded"
    │
    ├─► 3. ⚠️  SAFETY CHECK: Current user IP
    │   ├─ Get current user's IP (who is running command)
    │   └─ IF IP == current user: DENY + auto-whitelist
    │       └─ Prevents lockout!
    │
    ├─► 4. ⚠️  SAFETY CHECK: Server IP
    │   ├─ Check if IP is any local interface
    │   │  └─ Use: ip -o addr show | grep IP
    │   └─ IF IP == server IP: DENY + auto-whitelist
    │       └─ Prevents self-ban!
    │
    ├─► 5. ⚠️  SAFETY CHECK: Whitelist
    │   ├─ Check if IP is in whitelist (files + nftables)
    │   └─ IF WHITELISTED: DENY
    │       └─ Whitelisted IPs MUST NEVER be banned!
    │
    ├─► 6. Check if already banned
    │   ├─ Check @temp_ban set
    │   ├─ Check @user_blacklist set
    │   ├─ Check @system_blacklist set
    │   └─ Check @feeds set
    │   └─ IF FOUND: Skip (already banned)
    │
    ├─► 7. Execute ban (all checks passed!)
    │   ├─ Add to nftables @temp_ban set with timeout
    │   │  └─ nft add element <family> <table> temp_ban \
    │   │      "{ IP timeout BAN_TIMEs comment 'JAIL' }"
    │   └─ Log success
    │
    └─► 8. Check persistent offender
        ├─ Count total bans for this IP
        └─ IF count >= THRESHOLD: Add to permanent blacklist
```

### Safety Checks Summary:

| Check | Purpose | Action if Triggered |
|-------|---------|---------------------|
| **Current User IP** | Prevent admin lockout | DENY + auto-whitelist |
| **Server IP** | Prevent self-ban | DENY + auto-whitelist |
| **Whitelist** | Honor whitelist priority | DENY (log protected) |
| **Rate Limit** | Prevent ban storms | DENY temporarily |
| **Already Banned** | Avoid duplicates | Skip silently |

═══════════════════════════════════════════════════════════════════════════════

## ✅ UNBAN OPERATION (Remove IP from Blacklist)

### Unban Function Flow:

```
nftban_blacklist_unban_ip(IP, JAIL, FORCE)
    │
    ├─► 1. Validate IP
    │
    ├─► 2. Remove from @temp_ban set (always allowed)
    │   └─ nft delete element <family> <table> temp_ban { IP }
    │
    ├─► 3. IF FORCE=true: Remove from permanent sets
    │   ├─ Remove from @user_blacklist
    │   ├─ Remove from @system_blacklist
    │   └─ Remove from blacklist files (atomic sed with flock)
    │
    ├─► 4. Remove from @feeds set (if present)
    │   └─ Note: Feed files NOT modified (external source)
    │
    └─► 5. Return summary
        ├─ removed_from: list of locations
        ├─ failed_to_remove: errors
        └─ warnings: issues encountered
```

### Unban Locations:

| Location | Type | Removable Without Force | Removable With Force |
|----------|------|-------------------------|----------------------|
| @temp_ban | nftables | ✅ Yes | ✅ Yes |
| @user_blacklist | nftables | ❌ No | ✅ Yes |
| @system_blacklist | nftables | ❌ No | ✅ Yes |
| @feeds | nftables | ❌ No | ✅ Yes |
| blacklist_ips.conf | file | ❌ No | ✅ Yes |
| feeds/*-blacklist.conf | file | ❌ No (external) | ❌ No (external) |

═══════════════════════════════════════════════════════════════════════════════

## 📝 WHITELIST CHECK (TOCTOU-Protected)

### Critical Function for Fail2Ban Integration:

```
nftban_check_whitelist(IP)
    │
    ├─► 1. Validate & normalize IP
    │
    ├─► 2. Acquire EXCLUSIVE lock (TOCTOU protection)
    │   ├─ Lock file: whitelist-check.lock
    │   ├─ Timeout: 5 seconds
    │   └─ IF LOCK FAILS: FAIL-SAFE → Return 0 (assume whitelisted!)
    │       └─ Better to skip ban than risk banning whitelist!
    │
    ├─► 3. Check whitelist files (under lock)
    │   ├─ whitelist_ips.conf
    │   └─ whitelist_ips.conf.local
    │
    ├─► 4. Check nftables @whitelist set
    │
    └─► Return 0 if whitelisted, 1 if not
```

**Why TOCTOU Protection Matters:**

```
TIME       Thread A (Ban)              Thread B (Whitelist)
────────────────────────────────────────────────────────────
T1         Check whitelist → NOT FOUND
T2                                      Add IP to whitelist
T3         BAN IP (WRONG!)
````

**With TOCTOU Protection (Exclusive Lock):**

```
TIME       Thread A (Ban)              Thread B (Whitelist)
────────────────────────────────────────────────────────────
T1         Acquire lock
T2         Check whitelist → NOT FOUND
T3         BAN IP                       (Waiting for lock...)
T4         Release lock
T5                                      Acquire lock
T6                                      Add IP to whitelist
T7                                      Release lock
```

═══════════════════════════════════════════════════════════════════════════════

## 💾 STORAGE ARCHITECTURE (Dual System)

### Why Dual Storage (Files + nftables)?

| Storage | Purpose | Survives Reboot | Speed | Capacity |
|---------|---------|-----------------|-------|----------|
| **Files** | Persistence | ✅ Yes | Slow | Large (millions) |
| **nftables Sets** | Active blocking | ❌ No | Fast (O(1)) | Limited (10k-100k) |

### Data Flow:

```
┌─────────────────────────────────────────────────────────┐
│                   USER ADDS IP                          │
└──────────────────────┬──────────────────────────────────┘
                       │
         ┌─────────────┴─────────────┐
         │                           │
    ┌────▼────┐                 ┌────▼─────┐
    │  FILES  │                 │ nftables │
    │ (Persist)│                │  (Active) │
    └────┬────┘                 └────┬─────┘
         │                           │
         │ ON REBOOT                 │ BLOCKS
         │ ↓ RELOAD                  │ TRAFFIC
         │ ↓ SYNC                    │ NOW!
         │                           │
         └───────────►───────────────┘
                  RESTORE
```

### File Locations:

```
/etc/nftban/config/
├── whitelist_ips.conf          # System whitelist (persistent)
├── whitelist_ips.conf.local    # User whitelist (persistent)
├── blacklist_ips.conf          # System blacklist (persistent)
├── blacklist_ips.conf.local    # User blacklist (persistent)
└── feeds/
    ├── spamhaus-blacklist.conf
    ├── abuseipdb-blacklist.conf
    └── ...

/var/lib/nftban/
├── rate-limit-tracker.tmp      # Ban rate limiting
└── persistent-offenders.db     # Repeat offender tracking
```

### Sync Process:

```
1. Boot/Init:
   Files → Read → nftables sets

2. Add IP:
   User command → Add to nftables → Add to file (if permanent)

3. Reboot:
   Files still exist → Reload script → Restore to nftables
```

═══════════════════════════════════════════════════════════════════════════════

## 🔐 SECURITY FEATURES

### 1. Input Validation:

```bash
# Reject dangerous characters
if [[ "$input" =~ [\$\`\;\|\&\<\>\(\)\{\}\\\'\"] ]]; then
    return 1  # Command injection prevention
fi

# Check max length (prevent DoS)
if [[ ${#input} -gt 100 ]]; then
    return 1
fi

# Validate with ipcalc
ipcalc -c "$ip" || return 1
```

### 2. IPv4-Mapped IPv6 Normalization:

```bash
# Before search, normalize:
::ffff:192.168.1.1  →  192.168.1.1
::192.168.1.1       →  192.168.1.1

# Why? Prevents bypass:
# Attacker uses ::ffff:evil.ip to bypass IPv4 blacklist
```

### 3. Regex Injection Prevention:

```bash
# Escape special chars before grep:
IP="192.168.1.1"
ESCAPED=$(echo "$IP" | sed 's/[][.*^$()+?{|\\]/\\&/g')
grep "$ESCAPED" file  # Safe!
```

### 4. Atomic File Operations (TOCTOU Protection):

```bash
# WRONG (Race condition possible):
if grep "$IP" file; then  # Check
    # Another process modifies file here!
    sed -i "/$IP/d" file  # Use (outdated check!)
fi

# CORRECT (Atomic with flock):
(
    flock -x 200              # Exclusive lock
    grep "$IP" file && \      # Check under lock
    sed -i "/$IP/d" file      # Use under same lock
) 200>file.lock               # Lock file
```

### 5. Rate Limiting:

```bash
# Prevent ban storms:
MAX_BANS_PER_MIN=60
current_bans=$(count_recent_bans)

if [[ $current_bans -ge $MAX_BANS_PER_MIN ]]; then
    echo "Rate limit exceeded"
    return 1
fi
```

### 6. Persistent Offender Tracking:

```bash
# Auto-escalate repeat offenders:
ban_count=$(count_ip_bans "$IP")

if [[ $ban_count -ge $THRESHOLD ]]; then
    # Move from temp_ban to system_blacklist (permanent)
    add_to_permanent_blacklist "$IP" "Repeat offender: $ban_count bans"
fi
```

═══════════════════════════════════════════════════════════════════════════════

## 🔄 IP LIFECYCLE

### Lifecycle Diagram:

```
┌──────────┐
│   CLEAN  │ (New IP, not seen before)
└─────┬────┘
      │
      │ DETECTED ATTACK
      ↓
┌──────────────┐
│  TEMP_BAN    │ (1h timeout by default)
│ @temp_ban set│
└─────┬────────┘
      │
      ├─► Timeout expires → Back to CLEAN
      │
      └─► Repeat offender (3+ bans) → ESCALATE
          ↓
┌────────────────────┐
│  SYSTEM_BLACKLIST  │ (Automatic permanent ban)
│ @system_blacklist  │
│ + file storage     │
└─────┬──────────────┘
      │
      ├─► Admin unban (force) → Back to CLEAN
      │
      └─► Manual review → User decision
```

### State Transitions:

| From State | To State | Trigger | Reversible |
|------------|----------|---------|------------|
| CLEAN → TEMP_BAN | Attack detected | ✅ Yes (timeout) |
| TEMP_BAN → CLEAN | Timeout expires | - |
| TEMP_BAN → SYSTEM_BLACKLIST | Repeat offender | ✅ Yes (force unban) |
| CLEAN → USER_BLACKLIST | Admin manual ban | ✅ Yes (force unban) |
| CLEAN → FEEDS | External feed | ❌ No (external source) |
| * → WHITELISTED | Admin adds to whitelist | ✅ Yes (remove from whitelist) |

### Special Rules:

1. **Whitelist ALWAYS wins:** Whitelisted IPs cannot be banned (all ban attempts fail)
2. **Temp → Perm escalation:** After N bans, automatically permanent
3. **Feeds are external:** Cannot be modified, only excluded via whitelist
4. **Current user/server IPs:** Auto-whitelisted on ban attempt (safety)

═══════════════════════════════════════════════════════════════════════════════

## 📊 COMMAND EXAMPLES

### Search IP:

```bash
# Interactive search (full output)
nftban search 192.168.1.100

# Quiet search (status code only)
nftban search 192.168.1.100 true
echo $?  # 0=CLEAN, 10=WHITELISTED, 20=TEMP_BAN, 30=PERM_BAN, 40=IN_FEEDS
```

### Ban IP:

```bash
# Temporary ban (1 hour default)
nftban ban 192.168.1.100

# Custom duration
nftban ban 192.168.1.100 manual 7200  # 2 hours

# Custom jail name
nftban ban 192.168.1.100 ssh-brute 3600
```

### Unban IP:

```bash
# Unban from temporary bans only
nftban unban 192.168.1.100

# Force unban from ALL lists (including permanent)
nftban unban 192.168.1.100 manual true
```

### Whitelist Check:

```bash
# Check if IP is whitelisted
if nftban_check_whitelist 192.168.1.100; then
    echo "Whitelisted!"
else
    echo "Not whitelisted"
fi
```

═══════════════════════════════════════════════════════════════════════════════

## ✅ MIGRATION CHECKLIST FOR v0.10.0

### Must Preserve:

1. ✅ **Dual storage** (files + nftables)
2. ✅ **Search priority** (whitelist → temp → perm → feeds)
3. ✅ **Safety checks** (current user, server IP, whitelist)
4. ✅ **TOCTOU protection** (atomic operations)
5. ✅ **IPv4-mapped IPv6 normalization**
6. ✅ **CIDR range support**
7. ✅ **Rate limiting**
8. ✅ **Persistent offender tracking**
9. ✅ **nftables O(1) lookup** (`nft get element`)

### Can Improve:

1. ⚠️ **Better logging** (structured, queryable)
2. ⚠️ **GeoIP integration** (country-based blocking)
3. ⚠️ **API for external integrations**
4. ⚠️ **Real-time statistics**
5. ⚠️ **Web UI/dashboard**

### Migration Challenges:

1. **Data format compatibility:** Ensure old files can be read by v0.10.0
2. **Set name changes:** Map old set names to new (if renamed)
3. **File location changes:** Map old paths to new FHS paths
4. **Command compatibility:** Support old command syntax for backwards compat

═══════════════════════════════════════════════════════════════════════════════

## ✅ STEP 1 COMPLETE!

**Architecture Documented:**
- ✅ nftables tables, sets, chains, rules
- ✅ IP search logic and priority
- ✅ Ban/unban operations and safety checks
- ✅ Whitelist protection (TOCTOU-safe)
- ✅ Storage architecture (dual system)
- ✅ Security features
- ✅ IP lifecycle

**Next Steps:**
1. ⏳ Create migration plan (old → v0.10.0 mapping)
2. ⏳ Design v0.10.0 nftables module
3. ⏳ Implement search functionality in v0.10.0
4. ⏳ Implement ban/unban in v0.10.0
5. ⏳ Test on lab servers

═══════════════════════════════════════════════════════════════════════════════

**nftban v0.9.x — IP Management Logic Complete!** ✨
