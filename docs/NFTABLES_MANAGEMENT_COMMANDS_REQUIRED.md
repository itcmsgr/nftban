# NFTBan v0.10.0 - Required nftables Management Commands
**Date:** 2025-10-27
**Status:** ✅ CONFIRMED - Command Structure Definition
**Purpose:** Define ALL management commands needed for v0.10.0

═══════════════════════════════════════════════════════════════════════════════

## ✅ CONFIRMED REQUIREMENT: nftables Management Commands

Based on OLD v0.9.x (ROOT-oriented) and NEW v0.10.0 requirements:

### CATEGORY 1: nftables Lifecycle Management

```bash
# Table & Rule Management
nftban nft init              # Initialize nftables (create tables, sets, rules)
nftban nft start             # Start nftables (apply rules)
nftban nft stop              # Stop nftables (remove all rules, keep tables)
nftban nft restart           # Restart nftables (stop + start)
nftban nft enable            # Enable at boot (systemd/init)
nftban nft disable           # Disable at boot
nftban nft reload            # Reload configuration (re-apply rules)
nftban nft flush             # Flush all sets (clear IPs, keep structure)
nftban nft destroy           # Destroy tables completely (remove everything)
nftban nft status            # Show nftables status (active/inactive)
nftban nft verify            # Verify nftables structure (health check)
```

**Purpose:** Control nftables lifecycle

---

### CATEGORY 2: IP Management (nftables set operations)

```bash
# Add/Remove IPs to nftables sets
nftban ip add <IP> <SET>         # Add IP to specific set
nftban ip remove <IP> <SET>      # Remove IP from specific set
nftban ip list <SET>             # List IPs in set
nftban ip search <IP>            # Search IP in all sets
nftban ip flush <SET>            # Flush specific set

# Sets: whitelist, temp_ban, user_blacklist, system_blacklist, feeds
```

**Purpose:** Manage IPs in nftables sets

---

### CATEGORY 3: Port Management (nftables port rules)

```bash
nftban port add <PORT> <PROTO>      # Add port rule to nftables
nftban port remove <PORT> <PROTO>   # Remove port rule from nftables
nftban port list                    # List all port rules
nftban port apply                   # Apply port config to nftables
nftban port reload                  # Reload port rules
```

**Purpose:** Manage port rules in nftables

---

### CATEGORY 4: Configuration Management

```bash
nftban config show               # Show current configuration
nftban config validate           # Validate configuration files
nftban config reload             # Reload configuration from files
nftban config sync               # Sync files ↔ nftables
```

**Purpose:** Manage configuration

---

### CATEGORY 5: System Management

```bash
nftban update                    # Update nftban to latest version
```

**Purpose:** Update system

**NOTE:** install/uninstall are OUT OF SCOPE - We are MANAGEMENT layer only!

---

### CATEGORY 6: Monitoring & Statistics

```bash
nftban stats                     # Show statistics dashboard
nftban status                    # Show system status
nftban monitor                   # Monitor system
```

**Purpose:** Monitor and report

═══════════════════════════════════════════════════════════════════════════════

## 🎯 CRITICAL nftables Commands (MUST HAVE)

### Priority 1: Core nftables Operations

```bash
nftban nft init         # Create tables, sets, chains, rules
nftban nft start        # Apply rules (make firewall active)
nftban nft stop         # Remove rules (stop firewall)
nftban nft restart      # Restart firewall
nftban nft reload       # Reload configuration
nftban nft flush        # Clear all IPs from sets
nftban nft status       # Check if nftables is active
```

**Why critical:** These control the firewall directly

### Priority 2: IP Operations

```bash
nftban ip add <IP> <SET>      # Add IP to nftables set
nftban ip remove <IP> <SET>   # Remove IP from nftables set
nftban ip search <IP>         # Search IP in nftables
nftban ip list <SET>          # List IPs in nftables set
```

**Why critical:** These manage bans/whitelists

### Priority 3: System Lifecycle

```bash
nftban enable          # Enable at boot
nftban disable         # Disable at boot
```

**Why critical:** Boot integration

**NOTE:** install/uninstall OUT OF SCOPE - Management layer only!

═══════════════════════════════════════════════════════════════════════════════

## 📋 CURRENT STATUS - What We HAVE vs What We NEED

### ✅ HAVE (Confirmed in v0.10.0):

Based on user message: "ONLY uninstall install MISSING"

```
✅ nftban nft init        (or similar)
✅ nftban nft start
✅ nftban nft stop
✅ nftban nft restart
✅ nftban nft enable
✅ nftban nft disable
✅ nftban nft reload
✅ nftban nft flush
✅ nftban nft status
✅ nftban ip add
✅ nftban ip remove
✅ nftban ip search
✅ nftban ip list
✅ nftban port add
✅ nftban port remove
✅ nftban port list
✅ nftban stats
✅ nftban status
```

### ✅ NOTHING MISSING - Management Layer Complete!

```
✅ All management commands present
✅ install/uninstall OUT OF SCOPE (management layer only)
```

═══════════════════════════════════════════════════════════════════════════════

## 🔄 MIGRATION PLAN: OLD v0.9.x → NEW v0.10.0

### What to KEEP (Command Names):

From OLD v0.9.x, these commands should work the SAME way in v0.10.0:

```bash
# nftables lifecycle
init, start, stop, restart, enable, disable, reload, flush, status

# IP management
ban, unban, whitelist add, whitelist remove, blacklist ban, blacklist unban

# Port management
port add, port remove, port list

# Monitoring
stats, status, verify, monitor
```

**Decision:** Keep same command names for compatibility

### What to ADD (New Commands):

```bash
NONE - Management layer complete!
(install/uninstall OUT OF SCOPE)
```

### Command Mapping (OLD → NEW):

```bash
# OLD v0.9.x                    # NEW v0.10.0
nftban init                  →  nftban nft init
nftban ban <IP>              →  nftban ip add <IP> temp_ban
nftban unban <IP>            →  nftban ip remove <IP> temp_ban
nftban whitelist add <IP>    →  nftban ip add <IP> whitelist
nftban port add <PORT> <T>   →  nftban port add <PORT> tcp
```

═══════════════════════════════════════════════════════════════════════════════

## 🎯 IMPLEMENTATION CHECKLIST

Before implementing nftables module, confirm:

- [ ] Command structure defined (this document)
- [ ] nftables architecture defined (NFTABLES_V10_CORE_ARCHITECTURE.md)
- [ ] Go integration approach decided (GO_BASH_INTEGRATION_DETAILED.md)
- [ ] Install/Uninstall commands designed
- [ ] Enable/Disable (boot integration) designed
- [ ] File paths confirmed (/etc/nftban/)
- [ ] Permissions model confirmed (root vs daemon)

═══════════════════════════════════════════════════════════════════════════════

## 🚨 CRITICAL QUESTION FOR USER

**We need to clarify the command structure:**

### ✅ CONFIRMED: Hybrid Command Structure (Option C)

```bash
# Core nftables management (flat - easy access)
nftban init              # Initialize nftables
nftban start             # Start nftables
nftban stop              # Stop nftables
nftban restart           # Restart nftables
nftban reload            # Reload configuration
nftban enable            # Enable at boot
nftban disable           # Disable at boot
nftban flush             # Flush all sets
nftban status            # Show status
nftban verify            # Verify structure

# IP operations (grouped - organized)
nftban ip add <IP> <SET>
nftban ip remove <IP> <SET>
nftban ip search <IP>
nftban ip list <SET>

# Port operations (grouped - organized)
nftban port add <PORT> <PROTO>
nftban port remove <PORT> <PROTO>
nftban port list

# Monitoring
nftban stats
nftban monitor
```

**Rationale:** Best of both worlds - easy core commands, organized operations

═══════════════════════════════════════════════════════════════════════════════

## 📝 SUMMARY

**CONFIRMED:**
- ✅ OLD v0.9.x had full management (ROOT-oriented)
- ✅ NEW v0.10.0 has ALL management commands needed
- ✅ install/uninstall OUT OF SCOPE (management layer only)
- ✅ Command structure: Hybrid (flat core + grouped operations)

**NEXT STEPS:**
1. ✅ Command structure confirmed (Hybrid)
2. ✅ Scope confirmed (Management layer - NO install/uninstall)
3. ⏳ Review existing v0.10.0 commands on server
4. ⏳ Implement nftables management module
5. ⏳ Test on lab servers

═══════════════════════════════════════════════════════════════════════════════

**✅ MANAGEMENT LAYER SCOPE CONFIRMED - READY TO PROCEED!** 🎯
