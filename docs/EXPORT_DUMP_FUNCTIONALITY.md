# NFTBan v0.10.0 - Export/Dump Functionality
**Date:** 2025-10-27
**Status:** 🎯 FEATURE DESIGN
**Purpose:** Export nftables memory to files for reference, backup, debugging

═══════════════════════════════════════════════════════════════════════════════

## 🎯 WHY EXPORT/DUMP?

### Problem: What's ACTUALLY in Memory?

```
Files show:        1000 IPs in blacklist.d/*.conf
nftables memory:   ??? IPs actually loaded

Questions:
- Are files and memory in sync?
- Did deduplication work correctly?
- What IPs are REALLY blocking right now?
- How to backup current state?
```

### Solution: Export/Dump Commands

```bash
# Export what's in nftables RIGHT NOW
sudo nftban export whitelist > /tmp/whitelist-dump.txt
sudo nftban export blacklist > /tmp/blacklist-dump.txt
sudo nftban export all > /tmp/nftban-full-dump.txt

# Result: See EXACTLY what's in memory
```

═══════════════════════════════════════════════════════════════════════════════

## 📤 EXPORT COMMAND - Export nftables to Files

### Basic Usage:

```bash
# Export single set
sudo nftban export whitelist
# Output: List of IPs in @whitelist set (from nftables memory)

# Export to file
sudo nftban export whitelist > /tmp/whitelist-export.txt

# Export all sets
sudo nftban export all
# Output: All sets with headers

# Export with deduplication (clean output)
sudo nftban export blacklist --deduplicate
```

### Example Output:

```bash
$ sudo nftban export whitelist

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
NFTBan Export - Whitelist
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Source: nftables set @whitelist (IPv4)
Exported: 2025-10-27 12:00:00
Total IPs: 150
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Single IPs
127.0.0.1
192.168.1.100
192.168.1.101
8.8.8.8
1.1.1.1

# CIDR Ranges
10.0.0.0/8
172.16.0.0/12
192.168.0.0/16
104.16.0.0/13

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Total: 150 entries (5 single IPs, 145 CIDR ranges)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

═══════════════════════════════════════════════════════════════════════════════

## 🔍 DUMP COMMAND - Memory Snapshot with Stats

### Basic Usage:

```bash
# Dump all sets with statistics
sudo nftban dump

# Dump specific set
sudo nftban dump whitelist

# Dump with comparison (files vs memory)
sudo nftban dump --compare
```

### Example Output (Full Dump):

```bash
$ sudo nftban dump

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
NFTBan Memory Dump
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Generated: 2025-10-27 12:00:00
System: lab.mywebhost.gr
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📊 SUMMARY:

Set                      IPs in Memory    IPs in Files    Status
─────────────────────────────────────────────────────────────────
whitelist                150              150             ✅ SYNC
temp_ban                 25               0               ✅ OK (temporary)
user_blacklist           1,950            1,950           ✅ SYNC
system_blacklist         500              500             ✅ SYNC
feeds                    98,450           98,500          ⚠️  DRIFT (-50)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📁 WHITELIST (@whitelist) - 150 IPs

  Source Files:
    /etc/nftban/whitelist.d/00-localhost.conf          3 IPs
    /etc/nftban/whitelist.d/10-cloudflare.conf       140 IPs
    /etc/nftban/whitelist.d/20-office.conf            10 IPs

  Memory Status:
    ✅ All file IPs loaded
    ✅ No extra IPs in memory
    ✅ No missing IPs

  Sample (first 5):
    127.0.0.1
    192.168.1.100
    8.8.8.8
    104.16.0.0/13
    172.64.0.0/13

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

⏱️  TEMP_BAN (@temp_ban) - 25 IPs (Auto-Expire)

  Memory Status:
    ✅ Temporary bans (not in files - normal)

  Active Bans (with timeouts):
    1.2.3.4          expires in 45m 30s
    5.6.7.8          expires in 12m 05s
    9.9.9.9          expires in 58m 22s
    ...

  Oldest: 2h ago
  Newest: 2m ago

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

❌ BLACKLIST (@user_blacklist) - 1,950 IPs

  Source Files:
    /etc/nftban/blacklist.d/10-persistent-offenders.conf  100 IPs
    /etc/nftban/blacklist.d/20-geoip-blocked.conf        500 IPs
    /etc/nftban/blacklist.d/50-user-manual.conf        1,350 IPs

  Memory Status:
    ✅ All file IPs loaded
    ✅ No drift detected

  Top Countries:
    CN: 800 IPs (41%)
    RU: 400 IPs (20%)
    KP: 100 IPs (5%)
    Other: 650 IPs (34%)

  Sample (last 5 added):
    10.20.30.40
    11.22.33.44
    50.60.70.80
    90.91.92.93
    100.101.102.103

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🌐 FEEDS (@feeds) - 98,450 IPs

  Source Files:
    /etc/nftban/feeds.d/00-spamhaus-drop.conf         1,000 IPs
    /etc/nftban/feeds.d/01-firehol-level1.conf       10,000 IPs
    /etc/nftban/feeds.d/02-emerging-threats.conf     87,500 IPs

  Memory Status:
    ⚠️  DRIFT DETECTED: -50 IPs (files have 98,500, memory has 98,450)
    → 50 IPs in files NOT loaded (likely whitelisted)

  Last Update:
    spamhaus-drop: 2h ago
    firehol-level1: 5h ago
    emerging-threats: 1d ago

  Feed Health:
    ✅ spamhaus-drop: Up to date
    ✅ firehol-level1: Up to date
    ⚠️  emerging-threats: 1 day old (update recommended)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📊 OVERALL STATUS:

  ✅ Whitelist: Synchronized
  ✅ Temp Bans: Active (25 IPs auto-expiring)
  ✅ User Blacklist: Synchronized
  ✅ System Blacklist: Synchronized
  ⚠️  Feeds: Minor drift (-50 IPs, likely whitelisted)

  Total Blocking: 100,925 IPs
  Total Allowing: 150 IPs

  Recommendations:
    • Consider updating emerging-threats feed (1 day old)
    • Review 50 missing feed IPs (check whitelist overrides)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

═══════════════════════════════════════════════════════════════════════════════

## 🔧 HOW IT WORKS - Go Implementation

### Go Binary: Export Function

```bash
# New Go commands:
nftban-geoip export-set --set=whitelist --table=nftban_v4 --family=ip
nftban-geoip export-set --set=temp_ban --table=nftban_v4 --family=ip --show-timeout

# Output format:
1.2.3.4
5.6.7.0/24
10.20.30.40
```

### Bash Wrapper:

```bash
#!/usr/bin/env bash
# File: /usr/lib/nftban/core/nftban_export.sh

nftban_export_set() {
    local set_name="$1"
    local output_file="${2:-}"

    # Header
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "NFTBan Export - ${set_name^}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Source: nftables set @${set_name} (IPv4)"
    echo "Exported: $(date -Iseconds)"
    echo ""

    # METHOD 1: Direct nft list (simple)
    local ips
    ips=$(nft list set ip nftban_v4 "$set_name" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?')

    # Count IPs
    local count
    count=$(echo "$ips" | wc -l)

    echo "Total IPs: $count"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # List IPs
    echo "$ips"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Save to file if specified
    if [[ -n "$output_file" ]]; then
        echo "$ips" > "$output_file"
        echo "✅ Exported to: $output_file"
    fi
}

nftban_export_all() {
    local output_dir="${1:-/tmp/nftban-export-$(date +%Y%m%d-%H%M%S)}"

    mkdir -p "$output_dir"

    echo "Exporting all sets to: $output_dir"
    echo ""

    # Export each set
    for set in whitelist temp_ban user_blacklist system_blacklist feeds; do
        echo "Exporting $set..."
        nftban_export_set "$set" "${output_dir}/${set}.txt" &>/dev/null
        echo "  ✅ ${output_dir}/${set}.txt"
    done

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ Export complete!"
    echo ""
    echo "Files:"
    ls -lh "$output_dir"/*.txt
    echo ""
    echo "Archive:"
    tar -czf "${output_dir}.tar.gz" -C "$(dirname "$output_dir")" "$(basename "$output_dir")"
    echo "  📦 ${output_dir}.tar.gz"
}
```

═══════════════════════════════════════════════════════════════════════════════

## 📊 DUMP WITH COMPARISON (Files vs Memory)

### Detect Drift:

```bash
sudo nftban dump --compare
```

**What it does:**

```
1. Read files → Count IPs in blacklist.d/*.conf
2. Read nftables → Count IPs in @user_blacklist
3. Compare → Find differences
4. Report:
   - IPs in files but NOT in memory (missing)
   - IPs in memory but NOT in files (extra)
   - IPs in both (synced)
```

**Example Output:**

```bash
$ sudo nftban dump --compare

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
File vs Memory Comparison
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📁 WHITELIST:
  Files:  150 IPs
  Memory: 150 IPs
  Status: ✅ SYNCHRONIZED

📁 BLACKLIST:
  Files:  2,000 IPs
  Memory: 1,950 IPs
  Status: ⚠️  DRIFT (-50 IPs)

  Missing from memory (in files, not loaded):
    1.2.3.4   # Found in: blacklist.d/50-user-manual.conf
    5.6.7.8   # Found in: blacklist.d/10-persistent-offenders.conf
    ... (48 more)

  Reason: IPs in whitelist (auto-removed)
  Location: See /var/log/nftban/whitelist-overrides.log

  Extra in memory (loaded, not in files):
    NONE

📁 FEEDS:
  Files:  98,500 IPs
  Memory: 98,450 IPs
  Status: ⚠️  DRIFT (-50 IPs)

  Missing from memory:
    50 IPs in whitelist (auto-removed)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

RECOMMENDATIONS:
  ⚠️  50 blacklist IPs were in whitelist (auto-removed)
      → This is EXPECTED behavior (whitelist wins)
      → Review: sudo nftban search <IP>

  ✅ No action needed (drift is intentional)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

═══════════════════════════════════════════════════════════════════════════════

## 🔄 EXPORT FORMATS

### Format 1: Plain Text (Default)

```bash
sudo nftban export blacklist > blacklist.txt

# Output:
1.2.3.4
5.6.7.8
10.20.30.0/24
192.168.1.100
```

**Use case:** Simple backup, easy to read

---

### Format 2: CSV (with metadata)

```bash
sudo nftban export blacklist --format=csv > blacklist.csv

# Output:
IP,Type,Added,Expires,Source
1.2.3.4,single,2025-10-27T10:00:00,,blacklist.d/50-user-manual.conf
5.6.7.8,single,2025-10-27T11:00:00,,blacklist.d/10-persistent-offenders.conf
10.20.30.0/24,cidr,2025-10-26T08:00:00,,blacklist.d/50-user-manual.conf
```

**Use case:** Excel analysis, reporting

---

### Format 3: JSON (structured)

```bash
sudo nftban export blacklist --format=json > blacklist.json

# Output:
{
  "export_date": "2025-10-27T12:00:00Z",
  "set": "user_blacklist",
  "table": "nftban_v4",
  "family": "ip",
  "total_ips": 1950,
  "entries": [
    {
      "ip": "1.2.3.4",
      "type": "single",
      "added": "2025-10-27T10:00:00Z",
      "source": "blacklist.d/50-user-manual.conf"
    },
    {
      "ip": "10.20.30.0/24",
      "type": "cidr",
      "added": "2025-10-26T08:00:00Z",
      "source": "blacklist.d/50-user-manual.conf"
    }
  ]
}
```

**Use case:** API integration, automation

---

### Format 4: nftables-compatible (reload format)

```bash
sudo nftban export blacklist --format=nft > blacklist.nft

# Output (can be loaded with nft -f):
add element ip nftban_v4 user_blacklist { 1.2.3.4 }
add element ip nftban_v4 user_blacklist { 5.6.7.8 }
add element ip nftban_v4 user_blacklist { 10.20.30.0/24 }
```

**Use case:** Direct nftables reload, migration

═══════════════════════════════════════════════════════════════════════════════

## 💾 BACKUP & RESTORE

### Backup Current State:

```bash
# Full system backup
sudo nftban backup

# What it does:
1. Export all sets to files
2. Copy all config files
3. Export metadata (file hashes, timestamps)
4. Create tar.gz archive

# Output:
/var/backups/nftban/backup-20251027-120000.tar.gz

# Contents:
nftban-backup-20251027-120000/
├── exports/
│   ├── whitelist.txt       # Current nftables memory
│   ├── temp_ban.txt
│   ├── user_blacklist.txt
│   ├── system_blacklist.txt
│   └── feeds.txt
├── configs/
│   ├── whitelist.d/        # Copy of all config files
│   ├── blacklist.d/
│   ├── feeds.d/
│   └── geoip.d/
├── system/
│   ├── compiled-whitelist.txt
│   ├── compiled-blacklist.txt
│   └── metadata.json
└── backup-info.json        # Backup metadata
```

### Restore from Backup:

```bash
# List available backups
sudo nftban backup list

# Output:
Available backups:
  1. backup-20251027-120000.tar.gz  (2.3 GB, 100,925 IPs)
  2. backup-20251026-180000.tar.gz  (2.1 GB, 98,500 IPs)
  3. backup-20251025-120000.tar.gz  (1.9 GB, 95,200 IPs)

# Restore specific backup
sudo nftban restore backup-20251027-120000.tar.gz

# What it does:
1. Extract archive
2. Show what will change (diff)
3. Ask for confirmation
4. Restore config files
5. Reload nftables from backup
```

═══════════════════════════════════════════════════════════════════════════════

## 📋 COMMAND SUMMARY

### Export Commands:

```bash
# Export single set
sudo nftban export whitelist
sudo nftban export blacklist
sudo nftban export temp_ban
sudo nftban export feeds

# Export to file
sudo nftban export whitelist > /tmp/whitelist.txt
sudo nftban export blacklist --format=csv > blacklist.csv
sudo nftban export feeds --format=json > feeds.json

# Export all sets
sudo nftban export all
# Creates: /tmp/nftban-export-YYYYMMDD-HHMMSS/
```

### Dump Commands:

```bash
# Dump all sets with stats
sudo nftban dump

# Dump specific set
sudo nftban dump whitelist

# Dump with comparison (files vs memory)
sudo nftban dump --compare

# Dump with detailed stats
sudo nftban dump --verbose
```

### Backup/Restore:

```bash
# Backup current state
sudo nftban backup
# Creates: /var/backups/nftban/backup-YYYYMMDD-HHMMSS.tar.gz

# List backups
sudo nftban backup list

# Restore from backup
sudo nftban restore <backup-file>
```

═══════════════════════════════════════════════════════════════════════════════

## 🎯 USE CASES

### Use Case 1: Verify Deduplication Worked

```bash
# Before reload
cat /etc/nftban/blacklist.d/*.conf | wc -l
# Output: 2,050 IPs (with duplicates)

# Reload
sudo nftban reload

# After reload - check memory
sudo nftban export blacklist | wc -l
# Output: 1,950 IPs (deduplicated!)

# Difference: 100 duplicates removed ✅
```

---

### Use Case 2: Debugging - Find Missing IPs

```bash
# User reports: "IP 1.2.3.4 should be banned but isn't!"

# Step 1: Search files
grep -r "1.2.3.4" /etc/nftban/blacklist.d/
# Output: Found in blacklist.d/50-user-manual.conf

# Step 2: Check memory
sudo nftban dump --compare
# Output: 1.2.3.4 is in files but NOT in memory (whitelisted!)

# Step 3: Search whitelist
sudo nftban search 1.2.3.4
# Output: Found in whitelist.d/20-office.conf

# Root cause: IP is whitelisted → Auto-removed from blacklist ✅
```

---

### Use Case 3: Migration to Another Server

```bash
# Server A (source):
sudo nftban backup
# Creates: backup-20251027-120000.tar.gz

# Transfer to Server B
scp backup-20251027-120000.tar.gz root@serverB:/tmp/

# Server B (destination):
sudo nftban restore /tmp/backup-20251027-120000.tar.gz
# Restores all IPs, configs, settings ✅
```

---

### Use Case 4: Regular Audits

```bash
# Weekly audit: Export all sets for records
sudo nftban export all

# Creates timestamped directory
/tmp/nftban-export-20251027-120000/
├── whitelist.txt        (150 IPs)
├── blacklist.txt        (1,950 IPs)
├── temp_ban.txt         (25 IPs)
├── feeds.txt            (98,450 IPs)
└── export-summary.txt   (stats)

# Archive for compliance
tar -czf weekly-audit-$(date +%Y%m%d).tar.gz /tmp/nftban-export-*
```

═══════════════════════════════════════════════════════════════════════════════

## 📝 SUMMARY

### ✅ Export Features:

```bash
nftban export <set>          # Export nftables memory to stdout
nftban export all            # Export all sets
nftban export --format=csv   # Different formats (csv, json, nft)
```

**Why:** See what's ACTUALLY in memory (not just files)

### ✅ Dump Features:

```bash
nftban dump                  # Full memory dump with stats
nftban dump --compare        # Compare files vs memory (drift detection)
```

**Why:** Debugging, verification, health checks

### ✅ Backup/Restore:

```bash
nftban backup                # Full system backup
nftban restore <file>        # Restore from backup
```

**Why:** Migration, disaster recovery, rollback

### ✅ Use Cases:

1. **Verify deduplication** worked correctly
2. **Debug** why IP not blocking (files vs memory)
3. **Migrate** to another server (export/import)
4. **Audit** regularly (export for compliance)
5. **Compare** files vs memory (drift detection)

═══════════════════════════════════════════════════════════════════════════════

**🎯 COMPLETE EXPORT/DUMP SYSTEM DESIGNED!**

**Should I add this to the implementation plan?** 🚀

This gives users:
- ✅ Export nftables memory (see what's REALLY blocking)
- ✅ Dump with stats (easy verification)
- ✅ Compare files vs memory (drift detection)
- ✅ Backup/restore (migration, disaster recovery)
- ✅ Multiple formats (text, csv, json, nft)
