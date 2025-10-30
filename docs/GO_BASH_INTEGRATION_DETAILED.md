# NFTBan v0.10.0 - Go-Bash Integration Architecture (Detailed)
**Date:** 2025-10-27
**Decision:** Option C - Go as Full IP Manager
**Status:** DETAILED EXPLANATION - Need Confirmation

═══════════════════════════════════════════════════════════════════════════════

## 🎯 OPTION C: Go as Full IP Manager - EXPLAINED

### Core Concept: SEPARATION OF CONCERNS

```
┌─────────────────────────────────────────────────────────────┐
│                    NFTBan v0.10.0                           │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌──────────────────────┐      ┌──────────────────────┐   │
│  │   BASH (Architecture)│      │   GO (Data Manager)  │   │
│  ├──────────────────────┤      ├──────────────────────┤   │
│  │ - Create tables      │      │ - Validate IPs       │   │
│  │ - Create sets        │      │ - GeoIP lookup       │   │
│  │ - Define rules       │      │ - Add/Remove IPs     │   │
│  │ - Rule ORDER         │      │ - Search IPs         │   │
│  │ - Port config        │      │ - File sync          │   │
│  │ - Reports            │      │ - Bulk operations    │   │
│  │ - CLI interface      │      │ - Fast lookups       │   │
│  └──────────┬───────────┘      └──────────┬───────────┘   │
│             │                              │               │
│             │  Commands: add, remove,      │               │
│             │  search, sync, validate      │               │
│             └──────────────────────────────┘               │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              nftables (Kernel)                       │  │
│  │  - Tables: nftban_v4, nftban_v6                     │  │
│  │  - Sets: whitelist, temp_ban, user_blacklist, etc.  │  │
│  │  - Rules: CT, whitelist, blacklists, etc.          │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Files (Persistent Storage)              │  │
│  │  /etc/nftban/whitelist.conf                         │  │
│  │  /etc/nftban/blacklist.conf                         │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### Responsibilities (Clear Division):

**BASH Responsibilities (Structure):**
```bash
1. System initialization
   - Create nftables tables (nftban_v4, nftban_v6)
   - Create nftables sets (whitelist, temp_ban, etc.)
   - Create nftables chains (input, output)

2. Rule management
   - Define rule ORDER (critical for security!)
   - Apply rules in correct sequence
   - Port configuration rules
   - DDoS module integration

3. User interface
   - CLI commands (nftban ban, nftban unban, etc.)
   - Parse command arguments
   - Call Go binary for IP operations

4. Reports & Statistics
   - Query nftables counters
   - Generate HTML reports
   - Display status

5. Configuration
   - Read config files
   - Manage settings
   - Module coordination
```

**GO Responsibilities (Data):**
```go
1. IP Validation
   - Validate IPv4/IPv6 format
   - Validate CIDR notation
   - Normalize IPs (::ffff:1.2.3.4 → 1.2.3.4)

2. GeoIP Operations
   - Query GeoIP database
   - Return country code
   - Cache results (performance)

3. nftables Set Operations
   - Add IP to set (via nft command)
   - Remove IP from set
   - Check if IP in set (O(1) lookup)
   - Bulk add/remove

4. File Sync
   - Read IPs from files
   - Write IPs to files (persistence)
   - Sync files ↔ nftables sets
   - Atomic file operations (prevent corruption)

5. Search Operations
   - Fast IP search across all sets
   - Return which set contains IP
   - Return GeoIP info for IP
```

═══════════════════════════════════════════════════════════════════════════════

## 🔄 Q2: FILE SYNC - DETAILED EXPLANATION

### Storage Architecture (Dual System):

```
┌────────────────────────────────────────────────────────────┐
│                     DUAL STORAGE                           │
├────────────────────────────────────────────────────────────┤
│                                                            │
│  FILES (Persistent - Survive Reboot)                      │
│  ┌──────────────────────────────────────────────────┐     │
│  │ /etc/nftban/                                     │     │
│  │  ├── whitelist.conf         (manual entries)     │     │
│  │  ├── whitelist.conf.local   (user overrides)     │     │
│  │  ├── blacklist.conf         (manual entries)     │     │
│  │  ├── blacklist.conf.local   (user overrides)     │     │
│  │  └── system_blacklist.conf  (auto-generated)     │     │
│  └──────────────────────────────────────────────────┘     │
│                      ↕ SYNC                                │
│  nftables SETS (Active - In Memory, Fast O(1) Lookup)     │
│  ┌──────────────────────────────────────────────────┐     │
│  │ Kernel Memory:                                   │     │
│  │  ├── @whitelist        (active, fast)            │     │
│  │  ├── @temp_ban         (timeout auto-expire)     │     │
│  │  ├── @user_blacklist   (active, fast)            │     │
│  │  ├── @system_blacklist (active, fast)            │     │
│  │  └── @feeds            (active, fast)            │     │
│  └──────────────────────────────────────────────────┘     │
└────────────────────────────────────────────────────────────┘
```

### File → nftables (LOAD on Boot)

**Scenario:** System boots, nftables sets are empty

**WHO:** Go binary (called by Bash init script)

**Flow:**
```bash
# System boot
systemctl start nftban

# Bash init script:
/usr/sbin/nftban init
  ↓
# Bash creates structure:
1. Create tables (nftban_v4, nftban_v6)
2. Create sets (whitelist, temp_ban, etc.)
3. Create chains (input, output)
4. Apply rules (rule order)
  ↓
# Bash calls Go to load data:
nftban-geoip sync-from-files
  ↓
# Go does:
1. Read /etc/nftban/whitelist.conf → Parse IPs
2. Read /etc/nftban/whitelist.conf.local → Parse IPs (merge)
3. Validate each IP (IPv4/IPv6, CIDR)
4. For each valid IP:
   nft add element ip nftban_v4 whitelist { IP }
5. Repeat for blacklist.conf, system_blacklist.conf
  ↓
# Result: nftables sets populated from files
```

**Code Example (Bash init):**
```bash
nftban_init() {
    echo "Initializing nftables architecture..."

    # 1. Create tables, sets, chains, rules
    nftban_nftables_create_tables
    nftban_nftables_create_sets
    nftban_nftables_apply_rules

    # 2. Load IPs from files (Go handles this)
    echo "Loading IPs from configuration files..."
    nftban-geoip sync-from-files || {
        echo "Warning: Failed to sync from files"
        return 1
    }

    echo "✓ nftban initialized successfully"
}
```

**Code Example (Go sync-from-files):**
```go
// Go binary: nftban-geoip sync-from-files
func SyncFromFiles() error {
    // Read whitelist files
    whitelistIPs := []string{}
    whitelistIPs = append(whitelistIPs, ReadIPsFromFile("/etc/nftban/whitelist.conf")...)
    whitelistIPs = append(whitelistIPs, ReadIPsFromFile("/etc/nftban/whitelist.conf.local")...)

    // Add to nftables
    for _, ip := range whitelistIPs {
        if valid, normalized := ValidateIP(ip); valid {
            AddToNFTablesSet("whitelist", normalized)
        }
    }

    // Repeat for blacklist, system_blacklist, etc.

    return nil
}

func AddToNFTablesSet(setName string, ip string) error {
    // Detect IP family
    family := DetectIPFamily(ip) // "ip" or "ip6"
    table := GetTableForFamily(family) // "nftban_v4" or "nftban_v6"

    // Execute nft command
    cmd := exec.Command("nft", "add", "element", family, table, setName,
                        fmt.Sprintf("{ %s }", ip))
    return cmd.Run()
}
```

---

### nftables → File (SAVE on Shutdown/Persist)

**Scenario:** System has IPs in nftables, needs to save before shutdown

**WHO:** Go binary (called by Bash shutdown/persist command)

**When:**
- System shutdown
- Manual persist: `nftban persist`
- Periodic backup: cron job every hour

**Flow:**
```bash
# Manual persist command:
nftban persist
  ↓
# Bash calls Go:
nftban-geoip sync-to-files
  ↓
# Go does:
1. Query nftables: nft list set ip nftban_v4 whitelist
2. Parse output (extract IPs)
3. Write to temp file: /etc/nftban/whitelist.conf.tmp
4. Atomic rename: mv .tmp → .conf (prevent corruption)
5. Repeat for each set
  ↓
# Result: Files updated with current nftables state
```

**Code Example (Go sync-to-files):**
```go
func SyncToFiles() error {
    // Get IPs from nftables sets
    whitelistIPs := GetIPsFromNFTablesSet("whitelist")
    blacklistIPs := GetIPsFromNFTablesSet("user_blacklist")
    systemBlacklistIPs := GetIPsFromNFTablesSet("system_blacklist")

    // Write to files atomically
    WriteIPsToFileAtomic("/etc/nftban/whitelist.conf", whitelistIPs)
    WriteIPsToFileAtomic("/etc/nftban/blacklist.conf", blacklistIPs)
    WriteIPsToFileAtomic("/etc/nftban/system_blacklist.conf", systemBlacklistIPs)

    return nil
}

func GetIPsFromNFTablesSet(setName string) []string {
    ips := []string{}

    // Query IPv4 table
    cmd := exec.Command("nft", "list", "set", "ip", "nftban_v4", setName)
    output, _ := cmd.Output()
    ips = append(ips, ParseNFTablesOutput(output)...)

    // Query IPv6 table
    cmd = exec.Command("nft", "list", "set", "ip6", "nftban_v6", setName)
    output, _ = cmd.Output()
    ips = append(ips, ParseNFTablesOutput(output)...)

    return ips
}

func WriteIPsToFileAtomic(filename string, ips []string) error {
    tmpFile := filename + ".tmp"

    // Write to temp file
    f, _ := os.Create(tmpFile)
    for _, ip := range ips {
        fmt.Fprintf(f, "%s\n", ip)
    }
    f.Close()

    // Atomic rename
    return os.Rename(tmpFile, filename)
}
```

---

### Command: Add IP (User Action)

**Scenario:** User bans an IP

**Flow:**
```bash
# User command:
nftban ban 1.2.3.4

# Bash CLI handler:
nftban_ban_ip() {
    local ip="$1"
    local jail="${2:-manual}"
    local timeout="${3:-3600}"

    # Call Go to add IP
    nftban-geoip add \
        --set=temp_ban \
        --ip="$ip" \
        --timeout="$timeout" \
        --jail="$jail" || return 1

    # Log success
    echo "✓ Banned $ip for ${timeout}s (jail: $jail)"
}

# Go binary handles:
nftban-geoip add --set=temp_ban --ip=1.2.3.4 --timeout=3600 --jail=manual
  ↓
# Go does:
1. Validate IP: 1.2.3.4 → valid IPv4
2. Check GeoIP: 1.2.3.4 → country=US
3. Check whitelist: Is 1.2.3.4 in whitelist? → NO
4. Add to nftables:
   nft add element ip nftban_v4 temp_ban { 1.2.3.4 timeout 3600s comment "manual" }
5. (Optional) Log to file: append to /var/log/nftban/bans.log
6. Return: success, country=US
  ↓
# Result: IP blocked in nftables (fast!), logged
```

**NOTE:** temp_ban has timeout, so NO file sync needed (auto-expires!)

---

### Command: Add to Permanent Blacklist

**Scenario:** User permanently bans an IP

**Flow:**
```bash
# User command:
nftban blacklist add 1.2.3.4

# Bash CLI handler:
nftban_blacklist_add() {
    local ip="$1"

    # Call Go to add IP (permanent)
    nftban-geoip add \
        --set=user_blacklist \
        --ip="$ip" \
        --permanent || return 1

    echo "✓ Added $ip to permanent blacklist"
}

# Go binary handles:
nftban-geoip add --set=user_blacklist --ip=1.2.3.4 --permanent
  ↓
# Go does:
1. Validate IP: 1.2.3.4 → valid IPv4
2. Check GeoIP: 1.2.3.4 → country=US
3. Check whitelist: Is 1.2.3.4 in whitelist? → NO
4. Add to nftables:
   nft add element ip nftban_v4 user_blacklist { 1.2.3.4 }
5. Add to FILE (persistence!):
   Append to /etc/nftban/blacklist.conf:
   "1.2.3.4  # Added on 2025-10-27 by admin"
6. Return: success
  ↓
# Result: IP blocked in nftables AND persisted to file
```

**Key Point:** Permanent bans need FILE sync (survive reboot!)

---

### Manual File Edit (Admin Action)

**Scenario:** Admin manually edits /etc/nftban/blacklist.conf

**Flow:**
```bash
# Admin edits file:
vim /etc/nftban/blacklist.conf
# Adds: 5.6.7.8

# Admin reloads:
nftban reload

# Bash reload command:
nftban_reload() {
    echo "Reloading configuration..."

    # Re-sync from files
    nftban-geoip sync-from-files || return 1

    echo "✓ Configuration reloaded"
}

# Go re-syncs:
  ↓
# Go does:
1. Read files again (includes new 5.6.7.8)
2. Get current nftables state
3. Compare: What's in file but NOT in nftables?
   → 5.6.7.8 is NEW
4. Add missing IPs to nftables:
   nft add element ip nftban_v4 user_blacklist { 5.6.7.8 }
5. (Optional) Remove IPs in nftables but NOT in file (if --clean flag)
  ↓
# Result: nftables updated with manual file changes
```

**Alternative (Auto-Reload):**
```
Option: Go daemon watches files with inotify
When file changes → Auto-reload
No manual "nftban reload" needed
```

═══════════════════════════════════════════════════════════════════════════════

## 🔧 GO BINARY INTERFACE (CLI Commands)

### Proposed Commands:

```bash
# ============================================================================
# IP VALIDATION
# ============================================================================
nftban-geoip validate <IP>
  Returns: 0 if valid, 1 if invalid
  Output: "valid" or "invalid: reason"

# ============================================================================
# GEOIP LOOKUP
# ============================================================================
nftban-geoip country <IP>
  Returns: Country code (US, CN, RU, etc.)
  Output: "US" or "UNKNOWN"

nftban-geoip info <IP>
  Returns: Full GeoIP info (JSON)
  Output: {"country":"US","city":"New York","lat":40.7128,"lon":-74.0060}

# ============================================================================
# NFTABLES OPERATIONS
# ============================================================================
nftban-geoip add --set=<SET> --ip=<IP> [--timeout=<SECONDS>] [--permanent]
  Adds IP to nftables set
  If --permanent: Also writes to file
  Returns: 0 if success, 1 if error

nftban-geoip remove --set=<SET> --ip=<IP> [--permanent]
  Removes IP from nftables set
  If --permanent: Also removes from file
  Returns: 0 if success, 1 if error

nftban-geoip search <IP>
  Searches IP across all sets
  Returns: Which set contains IP (or "not found")
  Output: "temp_ban" or "whitelist" or "not_found"

# ============================================================================
# FILE SYNC
# ============================================================================
nftban-geoip sync-from-files
  Reads files → Loads to nftables
  Used on boot, reload

nftban-geoip sync-to-files
  Reads nftables → Writes to files
  Used on shutdown, persist

nftban-geoip sync-both
  Bi-directional sync (smart merge)

# ============================================================================
# BULK OPERATIONS
# ============================================================================
nftban-geoip bulk-add --set=<SET> --file=<FILE>
  Reads IPs from file, adds to set
  Fast batch operation

nftban-geoip bulk-remove --set=<SET> --file=<FILE>
  Removes multiple IPs

# ============================================================================
# UTILITY
# ============================================================================
nftban-geoip list --set=<SET>
  Lists all IPs in set
  Output: One IP per line

nftban-geoip count --set=<SET>
  Counts IPs in set
  Output: Number

nftban-geoip stats
  Shows statistics (IPs per set, GeoIP cache, etc.)
```

### Example Usage (Bash calls Go):

```bash
# Ban IP
if nftban-geoip add --set=temp_ban --ip=1.2.3.4 --timeout=3600; then
    echo "Banned successfully"
else
    echo "Ban failed"
fi

# Check country before banning
COUNTRY=$(nftban-geoip country 1.2.3.4)
if [[ "$COUNTRY" == "CN" ]]; then
    echo "IP from China, adding to permanent blacklist"
    nftban-geoip add --set=system_blacklist --ip=1.2.3.4 --permanent
fi

# Search IP
LOCATION=$(nftban-geoip search 1.2.3.4)
case "$LOCATION" in
    whitelist)
        echo "IP is whitelisted"
        ;;
    temp_ban)
        echo "IP is temporarily banned"
        ;;
    not_found)
        echo "IP is clean"
        ;;
esac
```

═══════════════════════════════════════════════════════════════════════════════

## 📋 SUMMARY - OPTION C (Go as Full IP Manager)

### ✅ BENEFITS:

1. **Performance**
   - Go handles IP operations (fast!)
   - O(1) lookups
   - Bulk operations efficient

2. **Clean Separation**
   - Bash = Structure (tables, rules, CLI)
   - Go = Data (IPs, GeoIP, files)

3. **GeoIP Integration**
   - Go has GeoIP database
   - Fast country lookups
   - Can check before adding to nftables

4. **File Sync**
   - Go handles atomic file operations
   - Prevent corruption
   - Smart sync (only changes)

5. **Extensibility**
   - Easy to add new Go features
   - Bash remains simple
   - Clear API boundary

### ⚠️ CONSIDERATIONS:

1. **Go Permissions**
   - Go needs to run `nft` command
   - Need root or capabilities (CAP_NET_ADMIN)
   - Solution: Go binary owned by root, SUID bit? Or run via sudo?

2. **Error Handling**
   - Go operations can fail (nft command fails)
   - Bash needs to handle Go errors
   - Clear error messages

3. **Backwards Compatibility**
   - Old v0.9.x used Bash for everything
   - v0.10.0 uses Go for data operations
   - File formats compatible?

4. **Testing**
   - Need to test Go binary separately
   - Need to test Bash-Go integration
   - End-to-end testing required

═══════════════════════════════════════════════════════════════════════════════

## 🎯 QUESTIONS FOR YOU:

1. **Permissions:** How should Go run nft commands?
   - [ ] Option A: Go binary with SUID root
   - [ ] Option B: Bash calls: sudo nftban-geoip ...
   - [ ] Option C: Go runs as systemd service (root)
   - [ ] Option D: Other approach?

2. **File Format:** Keep same as v0.9.x?
   ```
   # /etc/nftban/whitelist.conf
   192.168.1.1    # Admin workstation
   10.0.0.0/8     # Internal network
   ```
   - [ ] YES, keep simple format
   - [ ] NO, change to JSON/YAML

3. **Sync Timing:** When to sync files?
   - [ ] Manual only (nftban reload, nftban persist)
   - [ ] Auto on boot/shutdown
   - [ ] Periodic (cron every hour)
   - [ ] File watching (inotify, auto-reload)
   - [ ] All of the above?

4. **Go Daemon or CLI:** How should Go run?
   - [ ] Option A: CLI only (Bash spawns Go process each time)
   - [ ] Option B: Daemon (Go runs as background service, Bash talks via socket)
   - [ ] Option C: Hybrid (daemon for bulk ops, CLI for simple ops)

═══════════════════════════════════════════════════════════════════════════════

**🎯 THIS IS OPTION C EXPLAINED IN DETAIL - CONFIRM IF THIS IS WHAT YOU WANT!**
