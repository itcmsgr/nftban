# NFTBan v0.10.0 - Three Entry Points Complete Analysis
**Date:** 2025-10-29
**Status:** 🟡 IN REVIEW - Complete system audit

═══════════════════════════════════════════════════════════════════

## OVERVIEW

NFTBan has **THREE main entry points** for nftables interaction:

1. **SEARCH** - IP lookup and discovery across all components
2. **BAN/UNBAN** - IP address management (add/remove from ban lists)
3. **PORT** - Firewall port management (allow/deny ports)

---

## ENTRY POINT 1: SEARCH (IP Lookup)

### Purpose
Search for an IP address across ALL NFTBan components and data sources.

### Command
```bash
nftban search <IP> [--no-interactive]
```

### Implementation
- **File:** `/usr/lib/nftban/cli/cmd_search.sh`
- **Type:** Bash script

### What It Searches
1. ✅ nftables sets:
   - `nftban_runtime.temp_ban_v4/v6` (temporary bans)
   - `nftban.whitelist` (whitelisted IPs)
   - `nftban.user_blacklist` (user permanent bans)
   - `nftban.system_blacklist` (system permanent bans)
   - Feed-based sets (if enabled)

2. ✅ Threat intelligence feeds:
   - Downloaded feed files
   - Cached threat lists

3. ✅ Fail2Ban jails:
   - `f2b-table` sets
   - Active jail memberships

### nftables Interaction
```bash
# Read-only operations
nft list set inet nftban_runtime temp_ban_v4
nft list set inet nftban whitelist
nft list set inet f2b-table addr-set-*
```

### Status
✅ **WORKING** - No issues detected

### Missing Features
- ❌ No GeoIP enrichment in output (optional)
- ❌ No reputation score from feeds (optional)

---

## ENTRY POINT 2: BAN/UNBAN (IP Management)

### Purpose
Add or remove IP addresses from ban lists.

### Commands
```bash
nftban ban <IP> [<duration>] [<jail>]      # Add IP to ban list
nftban unban <IP>                           # Remove IP from all ban lists
nftban list                                 # Show all banned IPs
```

### Implementation
- **File:** `/usr/sbin/nftban-complete`
- **Type:** Bash script
- **Architecture:** Two-table design

### Two-Table Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  TABLE 1: inet nftban_runtime (Priority: -310)             │
│  ────────────────────────────────────────────────            │
│  Purpose: Temporary bans with nftables timeout             │
│  Persistence: RUNTIME ONLY (lost on reboot if not saved)   │
│                                                              │
│  Sets:                                                       │
│  - temp_ban_v4 (flags: timeout)                            │
│  - temp_ban_v6 (flags: timeout)                            │
│                                                              │
│  Chains:                                                     │
│  - input_tempban (hook: input, priority: -310)             │
│      → ip saddr @temp_ban_v4 drop                          │
│      → ip6 saddr @temp_ban_v6 drop                         │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│  TABLE 2: inet nftban (Priority: -300)                     │
│  ────────────────────────────────────────────────            │
│  Purpose: Persistent whitelist/blacklist + firewall rules  │
│  Persistence: Built from config files, atomically reloaded │
│                                                              │
│  Sets:                                                       │
│  - whitelist_v4, whitelist_v6                              │
│  - user_blacklist_v4, user_blacklist_v6                    │
│  - system_blacklist_v4, system_blacklist_v6                │
│  - allowed_tcp_ports, allowed_udp_ports                    │
│                                                              │
│  Chains:                                                     │
│  - input (hook: input, priority: -300)                     │
│  - forward (hook: forward, priority: -300)                 │
│  - output (hook: output, priority: -300)                   │
└─────────────────────────────────────────────────────────────┘
```

### How BAN Works

**Temporary Ban (via Fail2ban):**
```bash
nftban ban 1.2.3.4 1h sshd
```
1. Adds IP to `nftban_runtime.temp_ban_v4` with timeout
2. nftables automatically removes after timeout expires
3. Logs event to SQLite database (if available)
4. Logs JSON event to `/var/log/nftban/nftban-actions.log`

**Permanent Ban:**
```bash
nftban ban 1.2.3.4
```
1. Writes IP to `/etc/nftban/blacklist.d/30-persistent-offenders.conf`
2. Triggers rebuild of main `nftban` table
3. Atomically reloads entire table with new blacklist

### How UNBAN Works
```bash
nftban unban 1.2.3.4
```
1. Removes from `nftban_runtime.temp_ban_v4` (if present)
2. Removes from `/etc/nftban/blacklist.d/*.conf` files (if present)
3. Rebuilds main `nftban` table
4. Checks `f2b-table` and suggests manual removal if found

### nftables Interaction
```bash
# Add temporary ban
nft add element inet nftban_runtime temp_ban_v4 { 1.2.3.4 timeout 3600s }

# Remove temporary ban
nft delete element inet nftban_runtime temp_ban_v4 { 1.2.3.4 }

# Rebuild main table (atomic)
nft -f /run/nftban/nftban_main.nft

# List bans
nft list set inet nftban_runtime temp_ban_v4
nft list set inet nftban user_blacklist_v4
```

### Status
✅ **WORKING** - Fully functional

### Issues Detected
1. ⚠️ **Priority Mismatch:**
   - Template says priority `-310` and `-300`
   - Servers show `raw - 10` = `-510` (priority raw==-500)
   - This is FINE, just inconsistent documentation

2. ⚠️ **Main Table Missing:**
   - Servers only have `nftban_runtime` table
   - No `nftban` main table found!
   - **This is a critical gap**

3. ⚠️ **No Persistent Ports:**
   - Port configuration in `/etc/nftban/ports.d/` not being used
   - Main table builder exists in code but never executed

### Root Cause
**The `nftban` main table is NEVER CREATED on servers!**

Only `nftban_runtime` exists. The main table with persistent rules is missing entirely.

---

## ENTRY POINT 3: PORT (Firewall Management)

### Purpose
Manage firewall port allow/deny rules.

### Commands
```bash
nftban port status [ports]               # Show port status
nftban port detailed [ports]             # Show detailed port info
nftban port allow-panel <panel>          # Configure control panel ports
nftban port html-report                  # Generate HTML report
nftban port mail-report [file] [email]   # Mail port report
```

### Implementation
- **File:** `/usr/lib/nftban/cli/cmd_port.sh`
- **Type:** Bash script

### What It Does

**Status Command:**
1. Uses `ss` to detect all listening services
2. Parses `nftables` rules to check firewall status
3. Shows per-port firewall state (allowed/blocked/no-rule)
4. Displays bind addresses (PUBLIC vs LOCAL-ONLY)
5. Shows process names and PIDs

**Allow-Panel Command:**
1. Loads config from `/etc/nftban/conf.d/directadmin.conf`
2. Detects DirectAdmin installation (checks `/usr/local/directadmin`)
3. Finds appropriate nftables table (tries: `nftban`, `nftban_runtime`, `filter`)
4. Creates input/output chains if needed
5. Adds TCP/UDP rules for all configured ports

### nftables Interaction
```bash
# Read firewall rules
nft list table inet nftban
nft list chain inet nftban input
nft list chain inet nftban output

# Add port rules
nft add rule inet nftban input tcp dport 2222 counter accept
nft add rule inet nftban output tcp dport 2222 counter accept
```

### Status
⚠️ **PARTIALLY WORKING**

**Working:**
- ✅ Port status detection (reads listening services)
- ✅ nftables rule parsing (checks firewall state)
- ✅ HTML report generation
- ✅ Mail report sending

**Broken:**
- ❌ allow-panel command hangs during execution
- ❌ Dynamic chain creation conflicts
- ❌ No persistent port storage

### Issues Detected

1. **Missing Main Table:**
   - Trying to add rules to `nftban` table that doesn't exist
   - Falls back to `nftban_runtime` which is wrong (temporary only)

2. **Dynamic Chain Creation:**
   - Creates `input`/`output` chains on-the-fly
   - Conflicts with existing `input_tempban` chain
   - Causes unpredictable behavior

3. **Execution Hangs:**
   - Command hangs after adding first port
   - Likely due to strict mode + error in loop
   - Root cause unknown (needs debugging)

4. **No Persistence:**
   - Added ports lost on reboot
   - Should write to `/etc/nftban/ports.d/`
   - Should trigger main table rebuild

### Proposed Fix

**Option 1: Create Main Table (RECOMMENDED)**
```bash
# Initialize main nftban table
nftban firewall init

# This creates:
# - inet nftban table
# - input/output/forward chains
# - whitelist/blacklist sets
# - allowed_tcp_ports/allowed_udp_ports sets
```

Then ports can be added persistently:
```bash
nftban port add 2222/tcp        # Add to /etc/nftban/ports.d/
nftban port remove 2222/tcp     # Remove from /etc/nftban/ports.d/
nftban firewall reload          # Rebuild main table
```

**Option 2: Use Runtime Table Only (NOT RECOMMENDED)**
- Keep using `nftban_runtime` for ports
- Accept that ports are lost on reboot
- Simpler but fragile

---

## ARCHITECTURE GAPS - WHAT'S MISSING

### 1. Main nftban Table
**Status:** ❌ NOT CREATED
**Impact:** HIGH - No persistent firewall rules

The main table builder exists in code but is never executed:
- File: `/usr/sbin/nftban-complete` (line 103: `nftban_build_main()`)
- Called by: NOBODY!
- Should be called by: `nftban firewall init`, `nftban firewall reload`

**Fix Required:**
```bash
# Add new commands
nftban firewall init      # Create main table for first time
nftban firewall reload    # Rebuild main table from config files
nftban firewall status    # Show firewall health
```

### 2. Port Persistence
**Status:** ❌ NOT IMPLEMENTED
**Impact:** MEDIUM - Ports lost on reboot

The `/etc/nftban/ports.d/` directory exists and code reads it, but nothing writes to it.

**Fix Required:**
```bash
# Add new commands
nftban port add <port>/<proto>       # Write to ports.d/ and reload
nftban port remove <port>/<proto>    # Remove from ports.d/ and reload
nftban port list                     # Show configured ports
```

### 3. Firewall Initialization
**Status:** ❌ NOT IMPLEMENTED
**Impact:** HIGH - System not fully initialized

No command to set up the complete firewall on a new system.

**Fix Required:**
```bash
nftban firewall init
```

This should:
1. Create `nftban_runtime` table (temporary bans)
2. Create `nftban` main table (persistent rules)
3. Create all required chains
4. Load default whitelist (127.0.0.1, ::1, system IPs)
5. Set default policies (input=drop, output=accept)
6. Save to `/etc/nftables.conf`
7. Enable `nftables.service`

### 4. Health Check
**Status:** ⚠️ PARTIAL
**Impact:** MEDIUM - Hard to diagnose issues

`nftban health` exists but doesn't check nftables properly.

**Fix Required:**
Add `nftban health nftables` subcommand that checks:
- ✓ nftables service running
- ✓ Required tables exist (nftban, nftban_runtime, f2b-table)
- ✓ Required chains exist
- ✓ Required sets exist
- ✓ Priority order correct
- ✓ Default policies set
- ✓ Rule counts
- ✓ Banned IP counts
- ✗ Firewall conflicts

---

## INTERACTION WITH GO/GOLANG

### Current Go Programs

1. **nftban-feeds** (Go)
   - Purpose: Parse threat intel feeds
   - nftables: ❌ NO INTERACTION
   - Used by: `nftban feeds update` (bash)
   - Flow: Go parses → outputs JSON → Bash reads JSON → updates nftables

2. **nftban-geoip** (Go)
   - Purpose: IP geolocation
   - nftables: ❌ NO INTERACTION
   - Used by: `nftban search`, `nftban geoip lookup`
   - Flow: Go reads MaxMind DB → outputs JSON → Bash displays

### Why No Direct Go → nftables?

**Design Decision:**
- Bash scripts call `nft` system binary
- Go programs process data only
- Clean separation of concerns

**Advantages:**
- `nft` binary is stable and well-tested
- No need for Go nftables library dependencies
- Easier to debug (can run `nft` commands manually)
- Works on all Linux distros

**Disadvantages:**
- Subprocess overhead (negligible for this use case)
- Can't use Go's concurrency for batch operations

**Recommendation:** ✅ KEEP CURRENT APPROACH

Go should remain data-processing only. Let Bash + `nft` handle firewall.

---

## FAIL2BAN INTEGRATION

### How It Works

```
┌──────────┐         ┌──────────┐         ┌────────────────┐
│ Fail2Ban │────────>│ NFTBan   │────────>│ nftables       │
│  (jail)  │  action │ (script) │  nft    │ (nftban_runtime)│
└──────────┘         └──────────┘         └────────────────┘
```

**Flow:**
1. Fail2ban detects SSH brute force
2. Triggers action: `nftban ban <IP> 1h sshd`
3. NFTBan adds to `nftban_runtime.temp_ban_v4` with timeout
4. nftables drops all packets from that IP
5. After timeout, nftables auto-removes IP

**Fail2ban's Own Table:**
Fail2ban ALSO uses its own `f2b-table` for legacy compatibility.

**Status:** ✅ WORKING - Both systems coexist

**Optimization:** Could consolidate to use only NFTBan, but current setup works fine.

---

## SUMMARY OF FINDINGS

| Entry Point | Status | nftables Tables Used | Issues |
|-------------|--------|---------------------|--------|
| **SEARCH** | ✅ Working | nftban_runtime (read), nftban (read), f2b-table (read) | None |
| **BAN/UNBAN** | ⚠️ Partial | nftban_runtime (write), nftban (MISSING!) | Main table not created |
| **PORT** | ❌ Broken | nftban_runtime (wrong), nftban (MISSING!) | Hangs, no persistence |

### Critical Gaps

1. **🔴 CRITICAL: Main `nftban` table never created**
   - Only `nftban_runtime` exists
   - Persistent rules (whitelist/blacklist/ports) have nowhere to go
   - Code exists to build it, but never executed

2. **🔴 CRITICAL: No firewall initialization command**
   - No `nftban firewall init`
   - System not fully set up

3. **🟡 HIGH: Port management broken**
   - allow-panel hangs
   - No persistent port storage
   - Uses wrong table

4. **🟡 HIGH: Missing port add/remove commands**
   - Can only configure via `allow-panel`
   - No way to add individual ports
   - No way to persist changes

5. **🟢 MEDIUM: Health check incomplete**
   - Exists but doesn't check nftables thoroughly
   - Should verify full architecture

---

## RECOMMENDED IMMEDIATE ACTIONS

### Priority 1: Create Main Table (TODAY)

```bash
# Add command
nftban firewall init

# Implementation
# - Read /usr/sbin/nftban-complete line 103 function
# - Execute nftban_build_main()
# - Load resulting /run/nftban/nftban_main.nft
# - Save to /etc/nftables.conf
```

### Priority 2: Fix Port Command (TODAY)

```bash
# Fix allow-panel hang
# - Debug loop issue
# - Remove dynamic chain creation
# - Use pre-existing chains only

# Add persistence
# - Write to /etc/nftban/ports.d/
# - Trigger main table rebuild
```

### Priority 3: Add Missing Commands (THIS WEEK)

```bash
nftban firewall init          # Create full architecture
nftban firewall reload        # Rebuild main table
nftban firewall status        # Show health
nftban port add <port>        # Add persistent port
nftban port remove <port>     # Remove persistent port
nftban health nftables        # Comprehensive check
```

### Priority 4: Documentation (THIS WEEK)

- Architecture diagram
- Command reference
- Migration guide from 0.9.5
- Troubleshooting guide

---

## QUESTIONS FOR USER

1. **Should we create the main `nftban` table now?**
   - Yes → Implement `nftban firewall init` immediately
   - No → Document why it's optional

2. **Should ports use main table or runtime table?**
   - Main table (persistent) ← RECOMMENDED
   - Runtime table (temporary)

3. **Should we add `nftban port add/remove` commands?**
   - Yes ← RECOMMENDED for granular control
   - No, only keep `allow-panel` for bulk operations

4. **Should we consolidate Fail2ban to use NFTBan only?**
   - Yes (simpler, one table)
   - No, keep both ← CURRENT (works fine)

5. **Do we need ChatGPT assistance for code review?**
   - This analysis should be sufficient
   - Can involve ChatGPT for specific algorithm optimization

---

═══════════════════════════════════════════════════════════════════
**Status:** 🟡 ANALYSIS COMPLETE - AWAITING USER DECISIONS
**Next Step:** User reviews findings and approves action plan
**Critical:** Main table creation is REQUIRED for v0.10.0 to be complete
═══════════════════════════════════════════════════════════════════
