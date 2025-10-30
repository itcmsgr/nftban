# NFTBan v0.10.0 - Ban/Unban/Sync Workflows with Go
**Date:** 2025-10-27
**Status:** 📚 WORKFLOW EXPLANATION
**Purpose:** Explain how ban, unban, and file sync work with Go integration

═══════════════════════════════════════════════════════════════════════════════

## 🎯 WORKFLOW 1: Ban an IP (Temporary)

### User Command:
```bash
sudo nftban ban 1.2.3.4
# Or with custom timeout:
sudo nftban ban 1.2.3.4 7200  # 2 hours
```

### What Happens (Step-by-Step):

```
┌─────────────────────────────────────────────────────────────┐
│ STEP 1: User Command                                        │
└─────────────────────────────────────────────────────────────┘
USER → sudo nftban ban 1.2.3.4

┌─────────────────────────────────────────────────────────────┐
│ STEP 2: Bash CLI Router                                     │
└─────────────────────────────────────────────────────────────┘
/usr/sbin/nftban → Calls → nftban_ip_ban "1.2.3.4" "3600"

┌─────────────────────────────────────────────────────────────┐
│ STEP 3: Bash → Go (Validate IP)                            │
└─────────────────────────────────────────────────────────────┘
Bash: nftban-geoip validate "1.2.3.4"
Go:   Checks IP format → Returns exit code 0 (valid)

┌─────────────────────────────────────────────────────────────┐
│ STEP 4: Bash → Go (Get Country)                            │
└─────────────────────────────────────────────────────────────┘
Bash: country=$(nftban-geoip country "1.2.3.4")
Go:   Reads GeoLite2.mmdb → Returns "US"

┌─────────────────────────────────────────────────────────────┐
│ STEP 5: Bash (Check if Country Blocked)                    │
└─────────────────────────────────────────────────────────────┘
Bash: grep "^US$" /etc/nftban/geoip_blocked.conf
Result: Not found → Country allowed, continue

┌─────────────────────────────────────────────────────────────┐
│ STEP 6: Bash (Add to nftables - TEMPORARY)                 │
└─────────────────────────────────────────────────────────────┘
Bash: nft add element ip nftban_v4 temp_ban { 1.2.3.4 timeout 3600s }
nftables: IP added to temp_ban set with AUTO-EXPIRE in 1 hour

┌─────────────────────────────────────────────────────────────┐
│ STEP 7: Bash (Log to File)                                 │
└─────────────────────────────────────────────────────────────┘
Bash: echo "[2025-10-27 12:00:00] BAN ip=1.2.3.4 country=US timeout=3600" >> /var/log/nftban/ban.log

┌─────────────────────────────────────────────────────────────┐
│ STEP 8: User Sees Result                                   │
└─────────────────────────────────────────────────────────────┘
SUCCESS: Banned 1.2.3.4 (country: US, timeout: 3600s)
```

### Key Points:
- ✅ **Go validates** IP (fast)
- ✅ **Go provides** country info
- ✅ **Bash decides** if ban allowed
- ✅ **Bash adds** to nftables (with timeout)
- ✅ **nftables auto-expires** after timeout (no file needed!)
- ✅ **Bash logs** for history

### Code Example:

```bash
#!/usr/bin/env bash
# File: /usr/lib/nftban/core/nftban_ip.sh

nftban_ip_ban() {
    local ip="$1"
    local timeout="${2:-3600}"  # Default 1 hour

    # Validate with Go
    if ! nftban-geoip validate "$ip" &>/dev/null; then
        nftban_log_error "Invalid IP: $ip"
        return 1
    fi

    # Get country with Go
    local country
    country=$(nftban-geoip country "$ip" 2>/dev/null || echo "Unknown")

    # Check if already banned
    if nft get element ip nftban_v4 temp_ban { "$ip" } &>/dev/null; then
        nftban_log_warning "IP $ip already banned"
        return 0
    fi

    # Add to nftables (TEMPORARY - auto-expire)
    nft add element ip nftban_v4 temp_ban { "$ip" timeout "${timeout}s" }

    # Log
    echo "[$(date -Iseconds)] BAN ip=$ip country=$country timeout=${timeout}s" >> /var/log/nftban/ban.log

    nftban_log_success "Banned $ip (country: $country, timeout: ${timeout}s)"
}
```

═══════════════════════════════════════════════════════════════════════════════

## 🔓 WORKFLOW 2: Unban an IP

### User Command:
```bash
sudo nftban unban 1.2.3.4
```

### What Happens:

```
┌─────────────────────────────────────────────────────────────┐
│ STEP 1: User Command                                        │
└─────────────────────────────────────────────────────────────┘
USER → sudo nftban unban 1.2.3.4

┌─────────────────────────────────────────────────────────────┐
│ STEP 2: Bash → Go (Validate IP)                            │
└─────────────────────────────────────────────────────────────┘
Bash: nftban-geoip validate "1.2.3.4"
Go:   Returns exit code 0 (valid)

┌─────────────────────────────────────────────────────────────┐
│ STEP 3: Bash (Remove from nftables)                        │
└─────────────────────────────────────────────────────────────┘
Bash: nft delete element ip nftban_v4 temp_ban { 1.2.3.4 }
nftables: IP removed immediately

┌─────────────────────────────────────────────────────────────┐
│ STEP 4: Bash (Log Unban)                                   │
└─────────────────────────────────────────────────────────────┘
Bash: echo "[2025-10-27 12:30:00] UNBAN ip=1.2.3.4" >> /var/log/nftban/ban.log

┌─────────────────────────────────────────────────────────────┐
│ STEP 5: User Sees Result                                   │
└─────────────────────────────────────────────────────────────┘
SUCCESS: Unbanned 1.2.3.4
```

### Code Example:

```bash
nftban_ip_unban() {
    local ip="$1"

    # Validate with Go
    if ! nftban-geoip validate "$ip" &>/dev/null; then
        nftban_log_error "Invalid IP: $ip"
        return 1
    fi

    # Check if IP is actually banned
    if ! nft get element ip nftban_v4 temp_ban { "$ip" } &>/dev/null; then
        nftban_log_warning "IP $ip is not banned"
        return 0
    fi

    # Remove from nftables
    nft delete element ip nftban_v4 temp_ban { "$ip" }

    # Log
    echo "[$(date -Iseconds)] UNBAN ip=$ip" >> /var/log/nftban/ban.log

    nftban_log_success "Unbanned $ip"
}
```

═══════════════════════════════════════════════════════════════════════════════

## 💾 WORKFLOW 3: Permanent Ban (with File Sync)

### User Command:
```bash
sudo nftban blacklist add 1.2.3.4
# Or:
sudo nftban ip add 1.2.3.4 user_blacklist
```

### What Happens:

```
┌─────────────────────────────────────────────────────────────┐
│ STEP 1: User Command                                        │
└─────────────────────────────────────────────────────────────┘
USER → sudo nftban blacklist add 1.2.3.4

┌─────────────────────────────────────────────────────────────┐
│ STEP 2: Bash → Go (Validate IP)                            │
└─────────────────────────────────────────────────────────────┘
Bash: nftban-geoip validate "1.2.3.4"
Go:   Returns exit code 0 (valid)

┌─────────────────────────────────────────────────────────────┐
│ STEP 3: Bash → Go (Get Country)                            │
└─────────────────────────────────────────────────────────────┘
Bash: country=$(nftban-geoip country "1.2.3.4")
Go:   Returns "US"

┌─────────────────────────────────────────────────────────────┐
│ STEP 4: Bash (Add to File - PERMANENT)                     │
└─────────────────────────────────────────────────────────────┘
Bash: echo "1.2.3.4  # Added 2025-10-27, Country: US" >> /etc/nftban/blacklist.conf

┌─────────────────────────────────────────────────────────────┐
│ STEP 5: Bash (Add to nftables - NO TIMEOUT)                │
└─────────────────────────────────────────────────────────────┘
Bash: nft add element ip nftban_v4 user_blacklist { 1.2.3.4 }
nftables: IP added PERMANENTLY (no auto-expire)

┌─────────────────────────────────────────────────────────────┐
│ STEP 6: Bash (Log)                                         │
└─────────────────────────────────────────────────────────────┘
Bash: echo "[2025-10-27 12:00:00] BLACKLIST ip=1.2.3.4 country=US" >> /var/log/nftban/ban.log

┌─────────────────────────────────────────────────────────────┐
│ STEP 7: User Sees Result                                   │
└─────────────────────────────────────────────────────────────┘
SUCCESS: Added 1.2.3.4 to permanent blacklist (country: US)
```

### Key Difference from Temporary Ban:
- ✅ **Written to file** (/etc/nftban/blacklist.conf)
- ✅ **No timeout** in nftables
- ✅ **Survives reboot** (will be loaded from file on boot)

### Code Example:

```bash
nftban_ip_blacklist_add() {
    local ip="$1"
    local reason="${2:-Manual ban}"

    # Validate with Go
    if ! nftban-geoip validate "$ip" &>/dev/null; then
        nftban_log_error "Invalid IP: $ip"
        return 1
    fi

    # Get country with Go
    local country
    country=$(nftban-geoip country "$ip" 2>/dev/null || echo "Unknown")

    # Check if already in file
    if grep -q "^${ip}\s" /etc/nftban/blacklist.conf 2>/dev/null; then
        nftban_log_warning "IP $ip already in blacklist file"
    else
        # Add to file (PERMANENT)
        echo "${ip}  # Added $(date -Iseconds), Country: $country, Reason: $reason" >> /etc/nftban/blacklist.conf
    fi

    # Add to nftables (NO TIMEOUT - permanent)
    nft add element ip nftban_v4 user_blacklist { "$ip" }

    # Log
    echo "[$(date -Iseconds)] BLACKLIST_ADD ip=$ip country=$country reason=$reason" >> /var/log/nftban/ban.log

    nftban_log_success "Added $ip to permanent blacklist (country: $country)"
}
```

═══════════════════════════════════════════════════════════════════════════════

## 🔄 WORKFLOW 4: Sync from Files (Boot/Reload)

### When Does This Happen?
1. **System boot** - Load IPs from files to nftables
2. **Manual reload** - User runs: `sudo nftban reload`
3. **File edited** - Admin manually edits /etc/nftban/blacklist.conf

### User Command:
```bash
sudo nftban reload
# Or:
sudo nftban sync
```

### What Happens:

```
┌─────────────────────────────────────────────────────────────┐
│ STEP 1: User Command or System Boot                        │
└─────────────────────────────────────────────────────────────┘
USER → sudo nftban reload
OR
SYSTEMD → nftban.service starts on boot

┌─────────────────────────────────────────────────────────────┐
│ STEP 2: Bash (Read Whitelist File)                         │
└─────────────────────────────────────────────────────────────┘
Bash: Read /etc/nftban/whitelist.conf
Found IPs:
  127.0.0.1
  192.168.1.100
  10.0.0.5

┌─────────────────────────────────────────────────────────────┐
│ STEP 3: For Each IP → Go Validate → Bash Add to nftables  │
└─────────────────────────────────────────────────────────────┘
For IP "127.0.0.1":
  Bash → Go: nftban-geoip validate "127.0.0.1"
  Go → Returns: 0 (valid)
  Bash → nftables: nft add element ip nftban_v4 whitelist { 127.0.0.1 }

For IP "192.168.1.100":
  Bash → Go: nftban-geoip validate "192.168.1.100"
  Go → Returns: 0 (valid)
  Bash → nftables: nft add element ip nftban_v4 whitelist { 192.168.1.100 }

(Repeat for all IPs in file...)

┌─────────────────────────────────────────────────────────────┐
│ STEP 4: Bash (Read Blacklist File)                         │
└─────────────────────────────────────────────────────────────┘
Bash: Read /etc/nftban/blacklist.conf
Found IPs:
  1.2.3.4  # Added 2025-10-27, Country: US
  5.6.7.8  # Spam bot

┌─────────────────────────────────────────────────────────────┐
│ STEP 5: For Each IP → Validate → Add to nftables          │
└─────────────────────────────────────────────────────────────┘
For IP "1.2.3.4":
  Bash → Go: nftban-geoip validate "1.2.3.4"
  Go → Returns: 0 (valid)
  Bash → nftables: nft add element ip nftban_v4 user_blacklist { 1.2.3.4 }

For IP "5.6.7.8":
  Bash → Go: nftban-geoip validate "5.6.7.8"
  Go → Returns: 0 (valid)
  Bash → nftables: nft add element ip nftban_v4 user_blacklist { 5.6.7.8 }

┌─────────────────────────────────────────────────────────────┐
│ STEP 6: Summary                                            │
└─────────────────────────────────────────────────────────────┘
Loaded whitelist: 3 IPs
Loaded blacklist: 2 IPs
SUCCESS: Configuration reloaded
```

### Code Example:

```bash
#!/usr/bin/env bash
# File: /usr/lib/nftban/core/nftban_sync.sh

nftban_sync_from_files() {
    nftban_log_info "Syncing IPs from files to nftables..."

    local whitelist_file="/etc/nftban/whitelist.conf"
    local blacklist_file="/etc/nftban/blacklist.conf"
    local loaded_wl=0
    local loaded_bl=0

    # =========================================
    # SYNC WHITELIST
    # =========================================
    if [[ -f "$whitelist_file" ]]; then
        while IFS= read -r line; do
            # Skip comments and empty lines
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$line" ]] && continue

            # Extract IP (first field)
            local ip
            ip=$(echo "$line" | awk '{print $1}')

            # Validate with Go
            if nftban-geoip validate "$ip" &>/dev/null; then
                # Add to nftables
                nft add element ip nftban_v4 whitelist { "$ip" } 2>/dev/null && ((loaded_wl++))
            else
                nftban_log_warning "Invalid IP in whitelist: $ip"
            fi
        done < "$whitelist_file"
    fi

    # =========================================
    # SYNC BLACKLIST
    # =========================================
    if [[ -f "$blacklist_file" ]]; then
        while IFS= read -r line; do
            # Skip comments and empty lines
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$line" ]] && continue

            # Extract IP (first field)
            local ip
            ip=$(echo "$line" | awk '{print $1}')

            # Validate with Go
            if nftban-geoip validate "$ip" &>/dev/null; then
                # Add to nftables
                nft add element ip nftban_v4 user_blacklist { "$ip" } 2>/dev/null && ((loaded_bl++))
            else
                nftban_log_warning "Invalid IP in blacklist: $ip"
            fi
        done < "$blacklist_file"
    fi

    # Summary
    nftban_log_success "Loaded whitelist: $loaded_wl IPs"
    nftban_log_success "Loaded blacklist: $loaded_bl IPs"
}
```

═══════════════════════════════════════════════════════════════════════════════

## 📋 FILE FORMATS

### Whitelist File: /etc/nftban/whitelist.conf

```bash
# NFTBan Whitelist
# One IP per line, comments allowed

# Localhost
127.0.0.1
::1

# Office IPs
192.168.1.100  # Admin workstation
192.168.1.101  # Development server

# Cloud IPs
8.8.8.8  # Google DNS (example)
```

### Blacklist File: /etc/nftban/blacklist.conf

```bash
# NFTBan Permanent Blacklist
# One IP per line, comments allowed

# Manual bans
1.2.3.4  # Added 2025-10-27, Country: CN, Reason: Port scanner
5.6.7.8  # Added 2025-10-26, Country: RU, Reason: Brute force SSH

# Automated bans (persistent offenders)
10.20.30.40  # Auto-banned after 10 attacks
```

### GeoIP Blocked Countries: /etc/nftban/geoip_blocked.conf

```bash
# Block these countries
CN
RU
KP
```

═══════════════════════════════════════════════════════════════════════════════

## 🔄 COMPLETE LIFECYCLE - How Everything Works Together

### Scenario: Admin Workflow

```
1. BOOT TIME:
   systemd starts nftban.service
   → Bash: nftban_nftables_init() creates tables/sets/rules
   → Bash: nftban_sync_from_files() loads IPs from files
   → Go: Validates each IP during sync
   → nftables: Firewall active with all IPs loaded

2. TEMPORARY BAN (from monitoring):
   Attack detected from 1.2.3.4
   → Bash: nftban ban 1.2.3.4
   → Go: Validates IP, provides country
   → Bash: Adds to nftables temp_ban (1 hour timeout)
   → Bash: Logs to /var/log/nftban/ban.log
   → nftables: Blocks IP for 1 hour
   → After 1 hour: nftables auto-removes IP (no file needed!)

3. PERSISTENT ATTACKER (10 attacks in 24h):
   → Bash: Detects repeat offender
   → Bash: nftban blacklist add 1.2.3.4 "Persistent attacker"
   → Go: Validates, provides country
   → Bash: Writes to /etc/nftban/blacklist.conf
   → Bash: Adds to nftables user_blacklist (permanent)
   → nftables: Blocks IP forever
   → Survives reboot (will reload from file)

4. ADMIN MANUALLY ADDS IP:
   Admin edits /etc/nftban/blacklist.conf, adds: 9.9.9.9
   → Admin: nftban reload
   → Bash: Reads all files again
   → Go: Validates 9.9.9.9
   → Bash: Adds new IP to nftables
   → nftables: Now blocking 9.9.9.9

5. FALSE POSITIVE (Unban):
   Oops, 1.2.3.4 was legitimate user!
   → Admin: nftban unban 1.2.3.4
   → Go: Validates IP
   → Bash: Removes from nftables temp_ban
   → Bash: Logs unban
   → nftables: IP now allowed

6. PERMANENT UNBAN (Remove from blacklist):
   → Admin: nftban blacklist remove 1.2.3.4
   → Go: Validates IP
   → Bash: Removes from /etc/nftban/blacklist.conf
   → Bash: Removes from nftables user_blacklist
   → Bash: Logs removal
   → nftables: IP now allowed permanently
```

═══════════════════════════════════════════════════════════════════════════════

## 📊 STORAGE ARCHITECTURE

### Dual Storage System:

```
┌──────────────────────────────────────────────────────────────┐
│ FILES (Persistent - survive reboot)                         │
├──────────────────────────────────────────────────────────────┤
│ /etc/nftban/whitelist.conf      ← Permanent whitelist       │
│ /etc/nftban/blacklist.conf      ← Permanent blacklist       │
│ /etc/nftban/geoip_blocked.conf  ← Blocked countries         │
└──────────────────────────────────────────────────────────────┘
                     ↓ (on boot/reload)
                     ↓ (Go validates each IP)
                     ↓
┌──────────────────────────────────────────────────────────────┐
│ nftables SETS (Active in kernel - fast O(1) lookup)         │
├──────────────────────────────────────────────────────────────┤
│ @whitelist          ← From file (permanent)                 │
│ @temp_ban           ← NOT in file (auto-expire)             │
│ @user_blacklist     ← From file (permanent)                 │
│ @system_blacklist   ← From file (permanent)                 │
│ @feeds              ← From feeds files (permanent)          │
└──────────────────────────────────────────────────────────────┘
```

### What's in Files vs What's NOT:

```
IN FILES (permanent):
  ✅ whitelist.conf         → @whitelist
  ✅ blacklist.conf         → @user_blacklist
  ✅ system_blacklist.conf  → @system_blacklist
  ✅ feeds/*.conf           → @feeds

NOT IN FILES (temporary):
  ❌ @temp_ban              → Auto-expires, no persistence needed
```

═══════════════════════════════════════════════════════════════════════════════

## 📝 SUMMARY

### Ban (Temporary):
1. ✅ Go validates IP
2. ✅ Go provides country
3. ✅ Bash adds to nftables with timeout
4. ✅ nftables auto-expires (NO FILE NEEDED)
5. ✅ Logged for history

### Unban:
1. ✅ Go validates IP
2. ✅ Bash removes from nftables
3. ✅ Logged

### Blacklist (Permanent):
1. ✅ Go validates IP
2. ✅ Go provides country
3. ✅ Bash writes to FILE (persistent)
4. ✅ Bash adds to nftables (no timeout)
5. ✅ Survives reboot

### Sync from Files:
1. ✅ Bash reads files (whitelist.conf, blacklist.conf)
2. ✅ For each IP → Go validates
3. ✅ Bash adds valid IPs to nftables
4. ✅ Invalid IPs → Warning logged

### Go's Role:
- ✅ Validate IP format (fast)
- ✅ Provide country info (fast)
- ❌ Does NOT touch files
- ❌ Does NOT touch nftables
- ❌ No root permissions needed

### Bash's Role:
- ✅ Orchestrates workflow
- ✅ Reads/writes files
- ✅ Executes nftables commands
- ✅ Makes decisions (block country? permanent ban?)
- ✅ Logging

═══════════════════════════════════════════════════════════════════════════════

**✅ ALL WORKING FINE WITH GO! Ready to implement?** 🎯
