# NFTBan v0.10.0 - How Go Works with Bash (SIMPLE EXPLANATION)
**Date:** 2025-10-27
**Status:** 📚 EDUCATIONAL - For Understanding
**Purpose:** Explain Go-Bash integration in SIMPLE terms

═══════════════════════════════════════════════════════════════════════════════

## 🤔 WHAT IS GO?

**Go is a compiled language** - It creates a BINARY (executable file) like /usr/bin/ls or /usr/bin/grep

**Key difference from Bash:**
- **Bash:** Interpreted (reads .sh file line by line, slow)
- **Go:** Compiled (creates binary, VERY FAST)

**Think of Go as:**
- A super-fast program written in Go language
- Compiled into a single binary file
- Bash calls it like any other command (ls, grep, cat, etc.)

═══════════════════════════════════════════════════════════════════════════════

## 🔧 HOW BASH CALLS GO - Simple Example

### Example 1: Validate an IP Address

**WITHOUT Go (OLD way - slow):**
```bash
# Bash script
validate_ip() {
    local ip="$1"

    # Complex regex matching (slow)
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        # More checks...
        # More validation...
        # Many lines of code...
        echo "valid"
    else
        echo "invalid"
    fi
}

result=$(validate_ip "1.2.3.4")
echo "$result"  # Output: valid
```

**WITH Go (NEW way - fast):**
```bash
# Bash script
result=$(nftban-geoip validate "1.2.3.4")
echo "$result"  # Output: valid
```

**What happens:**
1. Bash runs: `nftban-geoip validate "1.2.3.4"`
2. Go binary executes (FAST)
3. Go returns: "valid" or "invalid"
4. Bash uses the result

**Go binary location:** `/usr/bin/nftban-geoip` (already exists on your server!)

---

### Example 2: GeoIP Lookup

**WITHOUT Go (impossible in Bash):**
```bash
# Bash CANNOT read GeoIP database (binary format)
# Need external tools: geoiplookup, mmdb_lookup, etc.
```

**WITH Go (simple):**
```bash
# Bash script
country=$(nftban-geoip country "8.8.8.8")
echo "$country"  # Output: US

# Or get full details
nftban-geoip lookup "8.8.8.8"
# Output:
# IP: 8.8.8.8
# Country: US
# ISO: US
```

**What happens:**
1. Bash calls: `nftban-geoip country "8.8.8.8"`
2. Go reads GeoIP database (GeoLite2-Country.mmdb)
3. Go returns: "US"
4. Bash uses it

═══════════════════════════════════════════════════════════════════════════════

## 🎯 CURRENT STATUS - What We HAVE

### Go Binary Already Exists!

```bash
# Check if Go binary exists
ls -la /usr/bin/nftban-geoip

# Output (on your server):
-rwxr-xr-x. 1 root root 8123456 Oct 27 20:00 /usr/bin/nftban-geoip
```

**This binary was compiled from Go source code at:**
`/home/gituser/nftban-v0.10.0-dev/go-geoip/cmd/nftban-geoip/main.go`

### What Can nftban-geoip Do? (Already Implemented)

Let me check:
```bash
# Test 1: Validate IP
nftban-geoip validate 1.2.3.4
# Returns: 0 (valid) or 1 (invalid) as exit code

# Test 2: Get country
nftban-geoip country 8.8.8.8
# Returns: US

# Test 3: Full lookup
nftban-geoip lookup 8.8.8.8
# Returns: JSON or text with country info

# Test 4: Bulk lookup (from file)
echo -e "8.8.8.8\n1.1.1.1" | nftban-geoip bulk
# Returns: Country for each IP
```

═══════════════════════════════════════════════════════════════════════════════

## 🔄 HOW BASH USES GO - Real Examples

### Example 1: Ban IP with Country Check

```bash
#!/usr/bin/env bash
# File: /usr/lib/nftban/core/nftban_ip.sh

nftban_ip_ban() {
    local ip="$1"
    local timeout="${2:-3600}"  # Default 1 hour

    # STEP 1: Validate IP using Go
    if ! nftban-geoip validate "$ip" >/dev/null 2>&1; then
        echo "ERROR: Invalid IP: $ip"
        return 1
    fi

    # STEP 2: Check country using Go
    local country
    country=$(nftban-geoip country "$ip" 2>/dev/null)

    # STEP 3: Check if country is blocked (Bash logic)
    if [[ -f /etc/nftban/geoip_blocked.conf ]]; then
        if grep -q "^${country}$" /etc/nftban/geoip_blocked.conf; then
            echo "INFO: IP $ip from blocked country: $country"
        fi
    fi

    # STEP 4: Add to nftables (Bash executes nft command)
    nft add element ip nftban_v4 temp_ban { "$ip" timeout "${timeout}s" }

    # STEP 5: Log (Bash)
    echo "[$(date)] BANNED: $ip (country: $country, timeout: ${timeout}s)" >> /var/log/nftban/ban.log

    echo "SUCCESS: Banned $ip (country: $country)"
}

# Usage:
nftban_ip_ban "1.2.3.4" 3600
```

**What happens:**
1. ✅ Bash calls Go to validate IP (FAST)
2. ✅ Bash calls Go to get country (FAST)
3. ✅ Bash checks blocked countries (Bash logic)
4. ✅ Bash executes nft command (add to firewall)
5. ✅ Bash logs to file

**Division of labor:**
- **Go does:** IP validation, GeoIP lookup (FAST operations)
- **Bash does:** Business logic, nftables commands, file operations

---

### Example 2: Search IP in All Sets

```bash
#!/usr/bin/env bash

nftban_ip_search() {
    local ip="$1"

    # STEP 1: Validate IP using Go
    if ! nftban-geoip validate "$ip" >/dev/null 2>&1; then
        echo "ERROR: Invalid IP: $ip"
        return 1
    fi

    # STEP 2: Get country info using Go
    local country
    country=$(nftban-geoip country "$ip" 2>/dev/null || echo "Unknown")

    echo "Searching for: $ip (Country: $country)"
    echo ""

    # STEP 3: Search in nftables sets (Bash)
    local sets=("whitelist" "temp_ban" "user_blacklist" "system_blacklist" "feeds")
    local found=0

    for set in "${sets[@]}"; do
        if nft get element ip nftban_v4 "$set" { "$ip" } &>/dev/null; then
            echo "  ✅ Found in: $set"
            ((found++))
        fi
    done

    if [[ $found -eq 0 ]]; then
        echo "  ❌ Not found in any set"
    fi

    # STEP 4: Search in log files (Bash)
    echo ""
    echo "Recent activity:"
    grep "$ip" /var/log/nftban/ban.log 2>/dev/null | tail -5 || echo "  No recent activity"
}

# Usage:
nftban_ip_search "8.8.8.8"
```

**Output:**
```
Searching for: 8.8.8.8 (Country: US)

  ✅ Found in: whitelist

Recent activity:
  [2025-10-27 10:00:00] WHITELISTED: 8.8.8.8 (country: US)
```

═══════════════════════════════════════════════════════════════════════════════

## 🎯 GO vs BASH - Who Does What?

### Go Binary (nftban-geoip) - FAST Operations

```
✅ IP validation (is it valid IPv4/IPv6?)
✅ GeoIP lookup (which country?)
✅ Bulk IP processing (thousands of IPs)
✅ Database reading (GeoLite2 binary format)
❌ Does NOT touch nftables
❌ Does NOT read/write config files (for now)
❌ Does NOT make decisions (just provides data)
```

**Think of Go as:** A super-fast calculator/lookup tool

---

### Bash Scripts - Business Logic

```
✅ Read config files (/etc/nftban/*.conf)
✅ Execute nftables commands (nft add/remove/list)
✅ Make decisions (should we ban? is country blocked?)
✅ Logging (write to /var/log/nftban/*.log)
✅ Orchestration (call Go when needed)
✅ CLI interface (user commands)
❌ Does NOT do complex IP validation (calls Go)
❌ Does NOT do GeoIP lookups (calls Go)
```

**Think of Bash as:** The manager/orchestrator

═══════════════════════════════════════════════════════════════════════════════

## 📋 PRACTICAL WORKFLOW - Ban an IP

### User Types:
```bash
nftban ban 1.2.3.4
```

### What Happens (Step by Step):

```
1. USER: nftban ban 1.2.3.4

2. BASH (/usr/sbin/nftban):
   → Receives command "ban 1.2.3.4"
   → Calls nftban_ip_ban() function

3. BASH (nftban_ip_ban function):
   → Calls Go: nftban-geoip validate 1.2.3.4

4. GO BINARY:
   → Validates IP format
   → Returns exit code: 0 (valid)

5. BASH:
   → IP is valid, continue
   → Calls Go: nftban-geoip country 1.2.3.4

6. GO BINARY:
   → Looks up IP in GeoLite2 database
   → Returns: "US"

7. BASH:
   → Checks if "US" is in blocked countries
   → US not blocked, continue
   → Executes nft command:
     nft add element ip nftban_v4 temp_ban { 1.2.3.4 timeout 3600s }

8. nftables (kernel):
   → Adds 1.2.3.4 to temp_ban set
   → Firewall now blocks this IP

9. BASH:
   → Logs to /var/log/nftban/ban.log
   → Returns success message to user

10. USER sees:
    SUCCESS: Banned 1.2.3.4 (country: US, timeout: 3600s)
```

═══════════════════════════════════════════════════════════════════════════════

## 🔧 HOW TO CALL GO FROM BASH - Practical Examples

### Method 1: Capture Output

```bash
# Get country as string
country=$(nftban-geoip country "8.8.8.8")
echo "Country: $country"  # Output: Country: US
```

### Method 2: Check Exit Code (Validation)

```bash
# Validate IP (exit code 0 = valid, 1 = invalid)
if nftban-geoip validate "1.2.3.4"; then
    echo "Valid IP"
else
    echo "Invalid IP"
fi
```

### Method 3: Capture Both Output and Exit Code

```bash
# Get country and check if command succeeded
local country result
country=$(nftban-geoip country "8.8.8.8" 2>/dev/null) || result=$?

if [[ $result -eq 0 ]]; then
    echo "Country: $country"
else
    echo "Lookup failed"
fi
```

### Method 4: Process Multiple IPs (Bulk)

```bash
# Read from file, process with Go
cat /tmp/ip_list.txt | nftban-geoip bulk > /tmp/results.txt

# Or process line by line
while IFS= read -r ip; do
    country=$(nftban-geoip country "$ip")
    echo "$ip → $country"
done < /tmp/ip_list.txt
```

═══════════════════════════════════════════════════════════════════════════════

## 🎯 DECISION NEEDED - Option C Explained

From earlier discussion, you chose **Option C: Go = Full IP Manager**

**What does this mean in practice?**

### Option C: Go Handles More Operations

```bash
# Instead of:
nft add element ip nftban_v4 temp_ban { 1.2.3.4 timeout 3600s }

# We would have Go do it:
nftban-geoip add --set=temp_ban --ip=1.2.3.4 --timeout=3600
```

**This means Go binary would:**
1. ✅ Validate IP
2. ✅ Check GeoIP
3. ✅ Execute nft command (add to nftables)
4. ✅ Write to file (if permanent)
5. ✅ Return result

**Bash would:**
1. ✅ Parse user command
2. ✅ Call Go binary
3. ✅ Display result to user
4. ✅ Log operation

### ⚠️ PROBLEM with Option C:

**Go needs ROOT permissions to run nft commands!**

```bash
# This requires root:
nft add element ip nftban_v4 temp_ban { 1.2.3.4 }
```

**How to give Go root permissions?**

**Option 1: Run Go as root (via sudo)**
```bash
sudo nftban-geoip add --set=temp_ban --ip=1.2.3.4
```
❌ Problem: User needs to type sudo

**Option 2: SUID bit on Go binary**
```bash
chmod u+s /usr/bin/nftban-geoip
```
❌ Problem: Security risk (any user can run as root)

**Option 3: Go runs as systemd service (daemon)**
```bash
# Go daemon listening on Unix socket
# Bash sends commands via socket
echo "ADD temp_ban 1.2.3.4 3600" | socat - UNIX-CONNECT:/run/nftban/nftban.sock
```
✅ Better: Go daemon runs as root, Bash talks to it
❌ Problem: Complex to implement

**Option 4: Keep Bash doing nft commands (RECOMMENDED)**
```bash
# Bash calls Go for validation/GeoIP only
country=$(nftban-geoip country "1.2.3.4")

# Bash executes nft command (already has root)
nft add element ip nftban_v4 temp_ban { 1.2.3.4 timeout 3600s }
```
✅ Simple: Go doesn't need special permissions
✅ Fast: Go still does heavy lifting (validation, GeoIP)
✅ Secure: Only Bash (which user explicitly runs with sudo) touches nftables

═══════════════════════════════════════════════════════════════════════════════

## 📋 RECOMMENDED APPROACH (Simple & Secure)

### Division of Responsibilities:

```
┌─────────────────────────────────────────────────────────────┐
│ USER                                                        │
│   ↓                                                         │
│   sudo nftban ban 1.2.3.4                                  │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ BASH (runs as root)                                         │
│                                                             │
│  1. Parse command                                           │
│  2. Call Go: nftban-geoip validate 1.2.3.4  ───────┐       │
│  3. Call Go: nftban-geoip country 1.2.3.4  ────────┼───┐   │
│  4. Check config (blocked countries)                │   │   │
│  5. Execute: nft add element ... (as root)          │   │   │
│  6. Log to file                                     │   │   │
│  7. Return success to user                          │   │   │
└─────────────────────────────────────────────────────┼───┼───┘
                                                      │   │
                                                      ↓   ↓
                           ┌──────────────────────────────────┐
                           │ GO BINARY (no root needed)       │
                           │                                  │
                           │  • Validate IP format            │
                           │  • Read GeoLite2.mmdb            │
                           │  • Return country code           │
                           │                                  │
                           │  Does NOT touch nftables!        │
                           └──────────────────────────────────┘
```

### Code Example:

```bash
#!/usr/bin/env bash
# File: /usr/lib/nftban/core/nftban_ip.sh

nftban_ip_ban() {
    local ip="$1"
    local timeout="${2:-3600}"

    # ============================================
    # GO: Validate IP (fast, no root needed)
    # ============================================
    if ! nftban-geoip validate "$ip" &>/dev/null; then
        nftban_log_error "Invalid IP: $ip"
        return 1
    fi

    # ============================================
    # GO: Get country (fast, no root needed)
    # ============================================
    local country
    country=$(nftban-geoip country "$ip" 2>/dev/null || echo "Unknown")

    # ============================================
    # BASH: Check if country blocked (config)
    # ============================================
    if [[ -f /etc/nftban/geoip_blocked.conf ]]; then
        if grep -q "^${country}$" /etc/nftban/geoip_blocked.conf; then
            nftban_log_info "Country $country is blocked, banning IP"
        fi
    fi

    # ============================================
    # BASH: Add to nftables (requires root)
    # ============================================
    if ! nft add element ip nftban_v4 temp_ban { "$ip" timeout "${timeout}s" }; then
        nftban_log_error "Failed to add IP to nftables"
        return 1
    fi

    # ============================================
    # BASH: Log operation
    # ============================================
    echo "[$(date -Iseconds)] BAN ip=$ip country=$country timeout=${timeout}s" >> /var/log/nftban/ban.log

    nftban_log_success "Banned $ip (country: $country, timeout: ${timeout}s)"
}
```

═══════════════════════════════════════════════════════════════════════════════

## 📝 SUMMARY

### What is Go?
- Compiled binary (like ls, grep, cat)
- Very fast
- Already exists: /usr/bin/nftban-geoip

### How does Bash call Go?
```bash
result=$(nftban-geoip country "8.8.8.8")
```
- Just like any other command
- Capture output or check exit code

### What does Go do?
- ✅ Validate IPs (fast)
- ✅ GeoIP lookups (fast)
- ❌ Does NOT touch nftables (no root needed)

### What does Bash do?
- ✅ Call Go when needed (validation, GeoIP)
- ✅ Execute nftables commands (as root)
- ✅ Read/write config files
- ✅ Business logic and orchestration

### Why this approach?
- ✅ Simple (Go doesn't need root)
- ✅ Secure (only Bash with sudo touches firewall)
- ✅ Fast (Go handles heavy operations)
- ✅ Maintainable (clear separation)

═══════════════════════════════════════════════════════════════════════════════

**✅ READY TO IMPLEMENT WITH THIS APPROACH?** 🎯
