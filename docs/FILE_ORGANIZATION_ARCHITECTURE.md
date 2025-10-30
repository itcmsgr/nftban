# NFTBan v0.10.0 - File Organization Architecture
**Date:** 2025-10-27
**Status:** 🎯 ARCHITECTURAL DESIGN
**Purpose:** Smart folder structure with deduplication, whitelist priority, CIDR support

═══════════════════════════════════════════════════════════════════════════════

## 🎯 CRITICAL REQUIREMENTS (From User Questions)

### 1. Whitelist ALWAYS Wins
```
IF IP exists in ANY whitelist → Remove from ALL blacklists (AUTO)
```
**Why:** Security! Whitelisted IPs must NEVER be blocked!

### 2. Deduplication
```
- Remove duplicate IPs across all files
- Handle CIDR overlaps (e.g., 1.2.3.0/24 contains 1.2.3.4)
```

### 3. Clear File Ownership
```
- User files: Admin can edit directly
- System files: Managed by nftban (auto-generated)
```

### 4. Scalability
```
- Support future features: feeds, cloudflare, geoip, etc.
- Each feature gets its own subfolder
```

### 5. CIDR Support
```
- Mix of single IPs: 1.2.3.4
- CIDR ranges: 10.0.0.0/8
- Deduplication: If 1.2.3.4 is in whitelist, ignore 1.2.3.0/24 in blacklist
```

═══════════════════════════════════════════════════════════════════════════════

## 📁 PROPOSED FOLDER STRUCTURE (Clean & Scalable)

```
/etc/nftban/
│
├── nftban.conf                      # Main config
├── nftban.conf.local                # User overrides
│
├── whitelist.d/                     # ✅ Whitelist (HIGHEST PRIORITY)
│   ├── 00-localhost.conf            # System: localhost, loopback
│   ├── 10-cloudflare.conf           # System: Cloudflare IPs (auto-updated)
│   ├── 20-office.conf               # User: Office IPs
│   ├── 30-partners.conf             # User: Partner IPs
│   └── 99-manual.conf               # User: Manual entries
│
├── blacklist.d/                     # ❌ Permanent Blacklist
│   ├── 10-persistent-offenders.conf # System: Auto-added (10+ attacks)
│   ├── 20-geoip-blocked.conf        # System: From blocked countries
│   ├── 50-user-manual.conf          # User: Manual bans
│   └── README.txt                   # Explains: IPs in whitelist.d/ override this!
│
├── feeds.d/                         # 🌐 Threat Feeds (HUGE files)
│   ├── 00-spamhaus-drop.conf        # System: Auto-updated
│   ├── 01-firehol-level1.conf       # System: Auto-updated
│   ├── 02-emerging-threats.conf     # System: Auto-updated
│   └── enabled.conf                 # Which feeds are active
│
├── geoip.d/                         # 🌍 GeoIP Configuration
│   ├── blocked-countries.conf       # User: CN, RU, KP, etc.
│   └── geoip-cache.conf             # System: Cached country→IP mappings
│
└── system/                          # 🔧 System Files (DO NOT EDIT)
    ├── compiled-whitelist.txt       # System: Deduplicated whitelist (all sources)
    ├── compiled-blacklist.txt       # System: Deduplicated blacklist (minus whitelist)
    ├── compiled-feeds.txt           # System: Deduplicated feeds
    └── metadata.json                # System: File hashes, last update times
```

### Key Principles:

1. **Numbered Prefixes** (00-, 10-, 20-, etc.)
   - Control load order
   - Lower numbers = higher priority (within same category)

2. **Separate Folders** (whitelist.d/, blacklist.d/, feeds.d/)
   - Clear organization
   - Easy to manage
   - Scalable for future features

3. **System vs User Files**
   - **System files**: Auto-generated (prefix: XX-*.conf where XX < 50)
   - **User files**: Admin edits (prefix: XX-*.conf where XX >= 50)
   - **README.txt** in each folder explains rules

4. **Compiled Files** (system/ folder)
   - After deduplication, create final compiled lists
   - These are loaded to nftables
   - Rebuilt on each sync

═══════════════════════════════════════════════════════════════════════════════

## 🔒 WHITELIST PRIORITY MECHANISM (Auto-Remove from Blacklist)

### How It Works:

```
┌─────────────────────────────────────────────────────────────┐
│ STEP 1: Collect ALL Whitelists                             │
└─────────────────────────────────────────────────────────────┘
Read files:
  whitelist.d/00-localhost.conf       → 127.0.0.1, ::1
  whitelist.d/10-cloudflare.conf      → 1.2.3.4, 5.6.7.8/24
  whitelist.d/20-office.conf          → 192.168.1.0/24
  whitelist.d/99-manual.conf          → 8.8.8.8

Result: Master whitelist set

┌─────────────────────────────────────────────────────────────┐
│ STEP 2: Deduplicate & Expand CIDR                          │
└─────────────────────────────────────────────────────────────┘
Input:
  1.2.3.4
  5.6.7.0/24    (expands to 5.6.7.0 - 5.6.7.255)
  5.6.7.8       (duplicate! already in 5.6.7.0/24)

Output (deduplicated):
  1.2.3.4
  5.6.7.0/24    (CIDR preserved)

┌─────────────────────────────────────────────────────────────┐
│ STEP 3: Collect ALL Blacklists                             │
└─────────────────────────────────────────────────────────────┘
Read files:
  blacklist.d/10-persistent-offenders.conf → 9.9.9.9, 1.2.3.4
  blacklist.d/50-user-manual.conf          → 5.6.7.8, 10.10.10.10

Result: Master blacklist set

┌─────────────────────────────────────────────────────────────┐
│ STEP 4: REMOVE Whitelist IPs from Blacklist (AUTO!)        │
└─────────────────────────────────────────────────────────────┘
Blacklist:   9.9.9.9, 1.2.3.4, 5.6.7.8, 10.10.10.10
Whitelist:   1.2.3.4, 5.6.7.0/24

Check each blacklist IP:
  9.9.9.9      → NOT in whitelist → KEEP
  1.2.3.4      → IN whitelist! → REMOVE ✂️
  5.6.7.8      → In 5.6.7.0/24 whitelist! → REMOVE ✂️
  10.10.10.10  → NOT in whitelist → KEEP

Final blacklist: 9.9.9.9, 10.10.10.10

┌─────────────────────────────────────────────────────────────┐
│ STEP 5: Log Auto-Removals (Important!)                     │
└─────────────────────────────────────────────────────────────┘
[2025-10-27 12:00:00] WHITELIST_OVERRIDE: Removed 1.2.3.4 from blacklist (in whitelist)
[2025-10-27 12:00:00] WHITELIST_OVERRIDE: Removed 5.6.7.8 from blacklist (in 5.6.7.0/24 whitelist)

┌─────────────────────────────────────────────────────────────┐
│ STEP 6: Save Compiled Lists                                │
└─────────────────────────────────────────────────────────────┘
/etc/nftban/system/compiled-whitelist.txt:
  1.2.3.4
  5.6.7.0/24
  192.168.1.0/24
  8.8.8.8

/etc/nftban/system/compiled-blacklist.txt:
  9.9.9.9
  10.10.10.10
  (1.2.3.4 and 5.6.7.8 removed!)

┌─────────────────────────────────────────────────────────────┐
│ STEP 7: Load to nftables                                   │
└─────────────────────────────────────────────────────────────┘
Load compiled-whitelist.txt → @whitelist set
Load compiled-blacklist.txt → @user_blacklist set

Result: Whitelist IPs are NEVER blocked! ✅
```

═══════════════════════════════════════════════════════════════════════════════

## 🔧 DEDUPLICATION MECHANISM (with CIDR Support)

### Problem: Duplicate IPs & CIDR Overlaps

```
Files contain:
  whitelist.d/10-cloudflare.conf:
    1.2.3.4
    5.6.7.0/24
    5.6.7.8        ← Duplicate! (in 5.6.7.0/24)

  whitelist.d/20-office.conf:
    1.2.3.4        ← Duplicate!
    192.168.1.0/24

  blacklist.d/50-user.conf:
    5.6.7.50       ← Overlap with whitelist 5.6.7.0/24
```

### Solution: Go Binary Deduplication

**NEW Go Function: `nftban-geoip deduplicate`**

```bash
# Input: File with IPs and CIDRs (may have duplicates)
cat whitelist.d/*.conf | nftban-geoip deduplicate > compiled-whitelist.txt

# Go does:
# 1. Parse all IPs and CIDRs
# 2. Expand CIDRs to IP ranges
# 3. Remove duplicates
# 4. Merge overlapping CIDRs (e.g., 1.2.3.0/24 + 1.2.3.128/25 → 1.2.3.0/24)
# 5. Output deduplicated list
```

**Go Implementation (Pseudocode):**

```go
func deduplicate(input []string) []string {
    // Parse all entries
    var singleIPs []net.IP
    var cidrs []*net.IPNet

    for _, line := range input {
        if strings.Contains(line, "/") {
            // CIDR
            _, ipnet, err := net.ParseCIDR(line)
            if err == nil {
                cidrs = append(cidrs, ipnet)
            }
        } else {
            // Single IP
            ip := net.ParseIP(line)
            if ip != nil {
                singleIPs = append(singleIPs, ip)
            }
        }
    }

    // Remove single IPs that are in CIDRs
    var finalIPs []net.IP
    for _, ip := range singleIPs {
        inCIDR := false
        for _, cidr := range cidrs {
            if cidr.Contains(ip) {
                inCIDR = true
                break
            }
        }
        if !inCIDR {
            finalIPs = append(finalIPs, ip)
        }
    }

    // Merge overlapping CIDRs (optional, complex)
    // For v1, just keep all CIDRs

    // Output
    var result []string
    for _, ip := range finalIPs {
        result = append(result, ip.String())
    }
    for _, cidr := range cidrs {
        result = append(result, cidr.String())
    }

    // Remove duplicates
    result = unique(result)
    sort.Strings(result)

    return result
}
```

**Usage in Bash:**

```bash
# Deduplicate whitelist
cat /etc/nftban/whitelist.d/*.conf | nftban-geoip deduplicate > /etc/nftban/system/compiled-whitelist.txt

# Deduplicate blacklist
cat /etc/nftban/blacklist.d/*.conf | nftban-geoip deduplicate > /etc/nftban/system/compiled-blacklist.txt

# Remove whitelist IPs from blacklist
nftban-geoip subtract \
    --from=/etc/nftban/system/compiled-blacklist.txt \
    --subtract=/etc/nftban/system/compiled-whitelist.txt \
    --output=/etc/nftban/system/compiled-blacklist-final.txt
```

**NEW Go Command: `nftban-geoip subtract`**

```go
// Remove all IPs in subtractList from fromList
// Handles CIDR: if fromList has 5.6.7.8 and subtractList has 5.6.7.0/24, remove 5.6.7.8
func subtract(fromList, subtractList []string) []string {
    var result []string

    for _, ip := range fromList {
        shouldRemove := false

        for _, wlEntry := range subtractList {
            if ipInEntry(ip, wlEntry) {
                shouldRemove = true
                break
            }
        }

        if !shouldRemove {
            result = append(result, ip)
        }
    }

    return result
}

func ipInEntry(ipStr, entry string) bool {
    ip := net.ParseIP(ipStr)
    if ip == nil {
        return false
    }

    if strings.Contains(entry, "/") {
        // CIDR
        _, ipnet, _ := net.ParseCIDR(entry)
        return ipnet.Contains(ip)
    } else {
        // Single IP
        return ipStr == entry
    }
}
```

═══════════════════════════════════════════════════════════════════════════════

## 📝 FILE MANAGEMENT - Who Manages What?

### User-Managed Files (Admin Can Edit)

```
✅ whitelist.d/20-office.conf       # Office IPs
✅ whitelist.d/30-partners.conf     # Partner IPs
✅ whitelist.d/99-manual.conf       # Manual whitelists

✅ blacklist.d/50-user-manual.conf  # Manual bans

✅ geoip.d/blocked-countries.conf   # Which countries to block

✅ feeds.d/enabled.conf             # Which feeds are active
```

**User workflow:**
```bash
# Edit file
sudo nano /etc/nftban/whitelist.d/20-office.conf

# Add IP
echo "192.168.1.50  # New admin workstation" >> /etc/nftban/whitelist.d/20-office.conf

# Reload
sudo nftban reload
```

---

### System-Managed Files (Auto-Generated - DO NOT EDIT)

```
⚠️ whitelist.d/00-localhost.conf       # Auto-generated on init
⚠️ whitelist.d/10-cloudflare.conf      # Auto-updated by nftban cloudflare update

⚠️ blacklist.d/10-persistent-offenders.conf  # Auto-added by monitoring
⚠️ blacklist.d/20-geoip-blocked.conf         # Auto-generated from GeoIP

⚠️ feeds.d/00-spamhaus-drop.conf       # Auto-downloaded
⚠️ feeds.d/01-firehol-level1.conf      # Auto-downloaded

⚠️ system/compiled-*.txt               # Compiled lists (after deduplication)
⚠️ system/metadata.json                # File metadata
```

**README.txt in each folder:**

```
# /etc/nftban/whitelist.d/README.txt

This folder contains whitelist files.

SYSTEM FILES (prefix 00-49):
  00-localhost.conf       - Auto-generated (localhost, loopback)
  10-cloudflare.conf      - Auto-updated by "nftban cloudflare update"

USER FILES (prefix 50-99):
  50-office.conf          - Your office IPs (EDIT THIS)
  99-manual.conf          - Manual entries (EDIT THIS)

To add IPs:
  1. Edit a user file (50-99 prefix)
  2. Add IP: 1.2.3.4  # Optional comment
  3. Reload: sudo nftban reload

IMPORTANT: IPs in this folder will NEVER be blocked!
```

═══════════════════════════════════════════════════════════════════════════════

## 🔄 BAN/UNBAN WORKFLOW (with File Updates)

### Scenario 1: Ban IP (Temporary)

```bash
sudo nftban ban 1.2.3.4
```

**What happens:**
```
1. Check whitelist (compiled-whitelist.txt)
   → 1.2.3.4 NOT in whitelist → OK to ban

2. Add to nftables temp_ban (with timeout)
   → nft add element ip nftban_v4 temp_ban { 1.2.3.4 timeout 3600s }

3. Log
   → [2025-10-27 12:00:00] BAN ip=1.2.3.4 timeout=3600s

4. NO FILE UPDATE (temp ban auto-expires)
```

---

### Scenario 2: Permanent Ban

```bash
sudo nftban blacklist add 1.2.3.4 "Spam bot"
```

**What happens:**
```
1. Check whitelist
   → 1.2.3.4 NOT in whitelist → OK to ban

2. Add to FILE (user-managed)
   → echo "1.2.3.4  # Spam bot, added 2025-10-27" >> /etc/nftban/blacklist.d/50-user-manual.conf

3. Recompile blacklist
   → cat blacklist.d/*.conf | nftban-geoip deduplicate > system/compiled-blacklist.txt
   → nftban-geoip subtract (remove whitelist IPs)

4. Add to nftables
   → nft add element ip nftban_v4 user_blacklist { 1.2.3.4 }

5. Log
   → [2025-10-27 12:00:00] BLACKLIST_ADD ip=1.2.3.4 reason="Spam bot"
```

---

### Scenario 3: Ban IP that's Whitelisted (CONFLICT!)

```bash
sudo nftban ban 1.2.3.4
# But 1.2.3.4 is in whitelist.d/20-office.conf!
```

**What happens:**
```
1. Check whitelist
   → 1.2.3.4 IS in whitelist! → BLOCK BAN

2. Log WARNING
   → [2025-10-27 12:00:00] BAN_BLOCKED ip=1.2.3.4 reason="IP is whitelisted"

3. Return error to user
   → ERROR: Cannot ban 1.2.3.4 - IP is whitelisted
   → To ban this IP, first remove from: /etc/nftban/whitelist.d/20-office.conf
```

---

### Scenario 4: Persistent Offender (Auto-Blacklist)

```
IP 9.9.9.9 attacked 10 times in 24 hours
```

**What happens (auto):**
```
1. Detection trigger
   → nftban_monitor detects persistent offender

2. Check whitelist
   → 9.9.9.9 NOT in whitelist → OK to auto-ban

3. Add to SYSTEM FILE (not user file!)
   → echo "9.9.9.9  # Auto-banned: 10 attacks in 24h" >> /etc/nftban/blacklist.d/10-persistent-offenders.conf

4. Recompile & reload
   → Deduplicate, subtract whitelist, load to nftables

5. Log
   → [2025-10-27 12:00:00] AUTO_BLACKLIST ip=9.9.9.9 reason="10 attacks in 24h"
```

═══════════════════════════════════════════════════════════════════════════════

## 🔄 RELOAD WORKFLOW (Complete)

### User Command:

```bash
sudo nftban reload
```

### What Happens:

```
┌─────────────────────────────────────────────────────────────┐
│ STEP 1: Collect & Deduplicate Whitelists                   │
└─────────────────────────────────────────────────────────────┘
cat /etc/nftban/whitelist.d/*.conf | \
    nftban-geoip deduplicate > \
    /etc/nftban/system/compiled-whitelist.txt

Result: 500 whitelisted IPs/CIDRs (deduplicated)

┌─────────────────────────────────────────────────────────────┐
│ STEP 2: Collect & Deduplicate Blacklists                   │
└─────────────────────────────────────────────────────────────┘
cat /etc/nftban/blacklist.d/*.conf | \
    nftban-geoip deduplicate > \
    /etc/nftban/system/compiled-blacklist-raw.txt

Result: 2,000 blacklisted IPs (deduplicated)

┌─────────────────────────────────────────────────────────────┐
│ STEP 3: Remove Whitelisted IPs from Blacklist              │
└─────────────────────────────────────────────────────────────┘
nftban-geoip subtract \
    --from=system/compiled-blacklist-raw.txt \
    --subtract=system/compiled-whitelist.txt \
    --output=system/compiled-blacklist.txt

Result: 1,950 blacklisted IPs (50 removed due to whitelist)
Logged: 50 IPs auto-removed

┌─────────────────────────────────────────────────────────────┐
│ STEP 4: Collect & Deduplicate Feeds                        │
└─────────────────────────────────────────────────────────────┘
cat /etc/nftban/feeds.d/*.conf | \
    nftban-geoip deduplicate | \
    nftban-geoip subtract --subtract=system/compiled-whitelist.txt > \
    system/compiled-feeds.txt

Result: 98,500 feed IPs (1,500 removed due to whitelist)

┌─────────────────────────────────────────────────────────────┐
│ STEP 5: Flush nftables Sets                                │
└─────────────────────────────────────────────────────────────┘
nft flush set ip nftban_v4 whitelist
nft flush set ip nftban_v4 user_blacklist
nft flush set ip nftban_v4 feeds

┌─────────────────────────────────────────────────────────────┐
│ STEP 6: Load Compiled Lists to nftables (Batch)            │
└─────────────────────────────────────────────────────────────┘
Load system/compiled-whitelist.txt → @whitelist (500 IPs)
Load system/compiled-blacklist.txt → @user_blacklist (1,950 IPs)
Load system/compiled-feeds.txt → @feeds (98,500 IPs)

Time: ~10-30 seconds

┌─────────────────────────────────────────────────────────────┐
│ STEP 7: Summary                                            │
└─────────────────────────────────────────────────────────────┘
✅ Whitelist: 500 IPs loaded
✅ Blacklist: 1,950 IPs loaded (50 auto-removed due to whitelist)
✅ Feeds: 98,500 IPs loaded (1,500 auto-removed due to whitelist)
⚠️  WARNING: 50 blacklisted IPs were in whitelist (removed)
    See: /var/log/nftban/whitelist-overrides.log
```

═══════════════════════════════════════════════════════════════════════════════

## 📝 SUMMARY - Clean Architecture

### ✅ Folder Structure:
```
whitelist.d/    → All whitelists (subfolders for organization)
blacklist.d/    → All blacklists
feeds.d/        → Threat feeds
geoip.d/        → GeoIP config
system/         → Compiled files (auto-generated)
```

### ✅ Whitelist ALWAYS Wins:
- During reload: Auto-remove whitelisted IPs from blacklist
- During ban: Check whitelist first, block if whitelisted
- Logged: All auto-removals

### ✅ Deduplication (Go):
```bash
nftban-geoip deduplicate      # Remove duplicates, merge CIDRs
nftban-geoip subtract         # Remove whitelist from blacklist
```

### ✅ File Ownership:
- **00-49**: System files (auto-generated)
- **50-99**: User files (admin edits)
- **README.txt**: Explains in each folder

### ✅ CIDR Support:
- Go handles CIDR parsing
- Go checks if IP in CIDR range
- Go merges overlapping CIDRs

### ✅ Scalable:
- Each feature = separate folder
- Numbered prefixes = load order
- Easy to add: cloudflare.d/, vpn.d/, custom.d/

═══════════════════════════════════════════════════════════════════════════════

## 🔍 EASY SEARCH & MANUAL DEBUGGING (User-Friendly)

### Requirement: Find IP Quickly

**User needs to find where 1.2.3.4 is:**

```bash
# QUICK SEARCH (one command):
sudo nftban search 1.2.3.4

# Output:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Searching for: 1.2.3.4
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

✅ WHITELIST (Priority: HIGHEST)
   File: /etc/nftban/whitelist.d/20-office.conf
   Line: 15
   Content: 1.2.3.4  # Office router

⚠️  ALSO FOUND IN BLACKLIST (will be AUTO-REMOVED):
   File: /etc/nftban/blacklist.d/50-user-manual.conf
   Line: 42
   Content: 1.2.3.4  # Old ban (should be removed!)

📊 nftables Status:
   ✅ In set: @whitelist
   ❌ NOT in set: @user_blacklist (removed due to whitelist)

🌍 GeoIP:
   Country: US
   ISO: US

📝 History (last 5 events):
   [2025-10-27 12:00:00] WHITELIST_ADD ip=1.2.3.4 reason="Office router"
   [2025-10-27 11:00:00] BAN_BLOCKED ip=1.2.3.4 reason="IP is whitelisted"

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ACTION NEEDED:
⚠️  Found duplicate in blacklist! Run:
    sudo nano /etc/nftban/blacklist.d/50-user-manual.conf +42
    (Remove line 42 manually)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### Manual Search (Grep All Files)

```bash
# Search ALL config files
sudo grep -r "1.2.3.4" /etc/nftban/whitelist.d/ /etc/nftban/blacklist.d/ /etc/nftban/feeds.d/

# Output shows exact file and line:
/etc/nftban/whitelist.d/20-office.conf:15:1.2.3.4  # Office router
/etc/nftban/blacklist.d/50-user-manual.conf:42:1.2.3.4  # Old ban
```

### Find Duplicates Manually

```bash
# Check for duplicate IPs across ALL files
sudo nftban check duplicates

# Output:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Duplicate IP Check
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

⚠️  DUPLICATES FOUND:

1.2.3.4 (2 occurrences):
  ✅ /etc/nftban/whitelist.d/20-office.conf:15
  ⚠️  /etc/nftban/blacklist.d/50-user-manual.conf:42
  → ACTION: Remove from blacklist (whitelist wins)

5.6.7.8 (3 occurrences):
  ✅ /etc/nftban/whitelist.d/10-cloudflare.conf:8
  ⚠️  /etc/nftban/blacklist.d/10-persistent-offenders.conf:99
  ⚠️  /etc/nftban/feeds.d/00-spamhaus-drop.conf:1520
  → ACTION: Remove from blacklist and feeds (whitelist wins)

Total duplicates: 2 IPs
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
FIX AUTOMATICALLY?
  sudo nftban fix duplicates     (auto-remove from blacklist)
  sudo nftban reload              (manual fix first, then reload)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### List All Files (Easy Overview)

```bash
# List all whitelist files with IP counts
sudo nftban list whitelist

# Output:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Whitelist Files
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📁 /etc/nftban/whitelist.d/

  [SYSTEM] 00-localhost.conf                3 IPs
  [SYSTEM] 10-cloudflare.conf             150 IPs  (auto-updated)
  [USER]   20-office.conf                  25 IPs
  [USER]   30-partners.conf                10 IPs
  [USER]   99-manual.conf                   5 IPs

  TOTAL: 193 IPs (before deduplication)
  After deduplication: 180 IPs (13 duplicates removed)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EDIT:
  User files: sudo nano /etc/nftban/whitelist.d/20-office.conf
  System files: Auto-managed (DO NOT EDIT)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

═══════════════════════════════════════════════════════════════════════════════

## 🚨 EMERGENCY ACCESS & OVERRIDE

### Emergency Scenario: Need to Unblock IP IMMEDIATELY

**Problem:**
```
Production server 1.2.3.4 is blocked!
Website down!
Need to unblock NOW!
```

**FAST Solution (Emergency Commands):**

```bash
# METHOD 1: Direct nftables (INSTANT - no file change)
sudo nft delete element ip nftban_v4 user_blacklist { 1.2.3.4 }
sudo nft delete element ip nftban_v4 temp_ban { 1.2.3.4 }
sudo nft delete element ip nftban_v4 feeds { 1.2.3.4 }

# Result: IP unblocked IMMEDIATELY (but will come back on next reload!)

# METHOD 2: Emergency whitelist (INSTANT + PERMANENT)
sudo nftban emergency-whitelist 1.2.3.4

# What it does:
# 1. Add to nftables @whitelist (INSTANT)
# 2. Add to /etc/nftban/whitelist.d/99-emergency.conf
# 3. Remove from all blacklist sets (INSTANT)
# 4. Log emergency action
```

**Emergency Whitelist Implementation:**

```bash
#!/usr/bin/env bash
# nftban_emergency_whitelist.sh

nftban_emergency_whitelist() {
    local ip="$1"
    local reason="${2:-EMERGENCY UNBLOCK}"

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🚨 EMERGENCY WHITELIST"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "IP: $ip"
    echo "Reason: $reason"
    echo "Time: $(date -Iseconds)"
    echo ""

    # STEP 1: Add to nftables whitelist (INSTANT)
    nft add element ip nftban_v4 whitelist { "$ip" } 2>/dev/null
    echo "✅ Added to nftables @whitelist"

    # STEP 2: Remove from all blacklist sets (INSTANT)
    nft delete element ip nftban_v4 temp_ban { "$ip" } 2>/dev/null
    nft delete element ip nftban_v4 user_blacklist { "$ip" } 2>/dev/null
    nft delete element ip nftban_v4 system_blacklist { "$ip" } 2>/dev/null
    nft delete element ip nftban_v4 feeds { "$ip" } 2>/dev/null
    echo "✅ Removed from all blacklist sets"

    # STEP 3: Add to emergency whitelist file (PERMANENT)
    local emergency_file="/etc/nftban/whitelist.d/99-emergency.conf"
    echo "$ip  # EMERGENCY: $reason - $(date -Iseconds)" >> "$emergency_file"
    echo "✅ Added to: $emergency_file"

    # STEP 4: Log emergency action
    echo "[$(date -Iseconds)] EMERGENCY_WHITELIST ip=$ip reason=\"$reason\"" >> /var/log/nftban/emergency.log
    echo "✅ Logged to: /var/log/nftban/emergency.log"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ EMERGENCY UNBLOCK COMPLETE"
    echo ""
    echo "IP $ip is now:"
    echo "  ✅ Whitelisted in nftables (active now)"
    echo "  ✅ Whitelisted in file (survives reload)"
    echo "  ✅ Removed from all blacklists"
    echo ""
    echo "⚠️  REVIEW LATER:"
    echo "    sudo nano $emergency_file"
    echo "    (Decide if this should be permanent)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}
```

**Usage:**

```bash
# Emergency unblock (instant + permanent)
sudo nftban emergency-whitelist 1.2.3.4 "Production server - false positive"

# Later, review emergency whitelists
sudo nftban list emergency

# Output:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Emergency Whitelists (Review Required)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

File: /etc/nftban/whitelist.d/99-emergency.conf

  1.2.3.4  # EMERGENCY: Production server - 2025-10-27T12:00:00
  5.6.7.8  # EMERGENCY: False positive - 2025-10-26T08:30:00

ACTIONS:
  1. Review each entry
  2. Move to appropriate file (e.g., 20-office.conf) OR
  3. Remove if no longer needed
  4. Clean up: sudo nftban clean emergency
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

### Emergency: Flush All Bans (Nuclear Option)

```bash
# EMERGENCY: Unblock EVERYTHING (except keep whitelist)
sudo nftban emergency-flush

# What it does:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🚨 EMERGENCY FLUSH - ARE YOU SURE?
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

This will:
  ✅ KEEP: Whitelist (safe)
  ❌ FLUSH: temp_ban (all temporary bans removed)
  ❌ FLUSH: user_blacklist (all permanent bans removed)
  ❌ FLUSH: system_blacklist (all system bans removed)
  ❌ FLUSH: feeds (all threat feeds removed)

⚠️  WARNING: This will unblock ALL IPs!

Type 'YES FLUSH ALL' to confirm:
> YES FLUSH ALL

Flushing sets...
  ✅ Flushed: temp_ban
  ✅ Flushed: user_blacklist
  ✅ Flushed: system_blacklist
  ✅ Flushed: feeds

✅ EMERGENCY FLUSH COMPLETE

All IPs unblocked (except whitelist preserved).

TO RESTORE:
  sudo nftban reload  (reload from files)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

═══════════════════════════════════════════════════════════════════════════════

## 📝 HELPER COMMANDS (User-Friendly Operations)

### Command Summary:

```bash
# SEARCH & DEBUGGING
sudo nftban search <IP>              # Find IP in all files + nftables + logs
sudo nftban check duplicates         # Find duplicate IPs across all files
sudo nftban list whitelist           # List all whitelist files with counts
sudo nftban list blacklist           # List all blacklist files with counts
sudo nftban list emergency           # List emergency whitelists (needs review)

# FILE MANAGEMENT
sudo nftban fix duplicates           # Auto-remove duplicates (whitelist wins)
sudo nftban clean emergency          # Clean up emergency whitelist file
sudo nftban validate files           # Check all files for errors

# EMERGENCY
sudo nftban emergency-whitelist <IP> [reason]  # Instant unblock + permanent
sudo nftban emergency-flush                     # Nuclear: flush all bans

# NORMAL OPERATIONS
sudo nftban reload                   # Reload all files (deduplicate, sync)
sudo nftban ban <IP> [timeout]       # Ban IP (temporary)
sudo nftban unban <IP>               # Unban IP
sudo nftban blacklist add <IP>       # Permanent ban
sudo nftban blacklist remove <IP>    # Remove from permanent ban
```

═══════════════════════════════════════════════════════════════════════════════

## 📂 FINAL FILE LAYOUT (with Emergency)

```
/etc/nftban/
│
├── whitelist.d/
│   ├── 00-localhost.conf            # System: localhost
│   ├── 10-cloudflare.conf           # System: Cloudflare IPs
│   ├── 20-office.conf               # User: Office IPs
│   ├── 30-partners.conf             # User: Partner IPs
│   ├── 99-manual.conf               # User: Manual entries
│   ├── 99-emergency.conf            # Emergency: Quick unblocks (REVIEW!)
│   └── README.txt                   # Instructions
│
├── blacklist.d/
│   ├── 10-persistent-offenders.conf # System: Auto-banned (10+ attacks)
│   ├── 20-geoip-blocked.conf        # System: From blocked countries
│   ├── 50-user-manual.conf          # User: Manual bans
│   └── README.txt
│
├── feeds.d/
│   ├── 00-spamhaus-drop.conf        # System: Auto-updated
│   ├── 01-firehol-level1.conf       # System: Auto-updated
│   ├── enabled.conf                 # Which feeds active
│   └── README.txt
│
├── geoip.d/
│   ├── blocked-countries.conf       # User: CN, RU, KP
│   └── README.txt
│
└── system/                          # Auto-generated (DO NOT EDIT)
    ├── compiled-whitelist.txt       # Deduplicated whitelist
    ├── compiled-blacklist.txt       # Deduplicated blacklist (minus whitelist)
    ├── compiled-feeds.txt           # Deduplicated feeds (minus whitelist)
    ├── metadata.json                # File hashes, timestamps
    └── README.txt                   # "DO NOT EDIT - Auto-generated"
```

═══════════════════════════════════════════════════════════════════════════════

## 📝 SUMMARY - User-Friendly Features

### ✅ Easy Search:
```bash
sudo nftban search 1.2.3.4           # Find IP everywhere
grep -r "1.2.3.4" /etc/nftban/       # Manual grep
```

### ✅ Find Duplicates:
```bash
sudo nftban check duplicates         # Show all duplicates
sudo nftban fix duplicates           # Auto-fix (whitelist wins)
```

### ✅ Easy Manual Edit:
- Clear folder structure (whitelist.d/, blacklist.d/)
- Numbered files (00-, 10-, 20-)
- README.txt in each folder
- Simple format: `IP  # comment`

### ✅ Emergency Access:
```bash
sudo nftban emergency-whitelist <IP> # Instant unblock
sudo nftban emergency-flush          # Nuclear option
```

### ✅ File Format (Human-Readable):
```
# Simple format (easy to edit)
1.2.3.4                     # Single IP
5.6.7.0/24                  # CIDR range
192.168.1.100               # No comment needed

# Comments supported
10.20.30.40  # Office router, added 2025-10-27
```

═══════════════════════════════════════════════════════════════════════════════

**🎯 COMPLETE ARCHITECTURE WITH:**

✅ Folder structure (scalable)
✅ Whitelist priority (auto-remove from blacklist)
✅ Deduplication (Go handles)
✅ CIDR support (Go handles)
✅ **Easy search** (`nftban search`, grep)
✅ **Duplicate checking** (`nftban check duplicates`)
✅ **Emergency access** (`emergency-whitelist`, `emergency-flush`)
✅ **Human-readable** files (simple format, comments)

**Ready to implement?** 🚀
