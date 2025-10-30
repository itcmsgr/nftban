# NFTBan v0.10.0 - nftables Management Status
**Date:** 2025-10-27
**Status:** ⚠️ NEEDS IMPLEMENTATION
**Purpose:** Track what nftables management commands we HAVE vs NEED

═══════════════════════════════════════════════════════════════════════════════

## ✅ CURRENT STATUS - What We HAVE

### CLI Commands Currently Implemented:

```bash
# From /usr/lib/nftban/cli/
✅ cmd_port.sh       # Port management (scan, list, summary, reports)
✅ cmd_module.sh     # Module reporting (list, summary, reports)
✅ cmd_fhs.sh        # FHS reporting (check, list, summary, reports)
✅ cmd_geoip.sh      # GeoIP lookups (lookup, bulk, status, test, update)
✅ cmd_health.sh     # Health checks (check, report, fix, services, modules, etc.)
✅ cmd_login.sh      # Login monitoring (status, install, enable, disable, logs, test)
✅ cmd_mail.sh       # Email (test, send, configure)
```

### Core Modules Currently Implemented:

```bash
# From /usr/lib/nftban/core/
✅ nftban_output.sh         # Banner and output formatting
✅ nftban_mail.sh           # Email functionality
✅ nftban_geoip_go.sh       # Go GeoIP integration
✅ nftban_login_alert.sh    # Login monitoring
✅ nftban_report_port.sh    # Port reports
✅ nftban_report_module.sh  # Module reports
✅ nftban_report_fhs.sh     # FHS reports
✅ nftban_health.sh         # Health check system
```

### Main CLI Entry Point:

```bash
✅ /usr/sbin/nftban         # Main CLI with auto-loading
```

═══════════════════════════════════════════════════════════════════════════════

## ❌ WHAT'S MISSING - nftables Management Commands

### CRITICAL: nftables Lifecycle Management

```bash
❌ nftban init              # Initialize nftables (create tables, sets, rules)
❌ nftban start             # Start nftables (apply rules)
❌ nftban stop              # Stop nftables (remove rules)
❌ nftban restart           # Restart nftables
❌ nftban reload            # Reload configuration
❌ nftban enable            # Enable at boot (systemd)
❌ nftban disable           # Disable at boot
❌ nftban flush             # Flush all sets (clear IPs)
❌ nftban status            # Show nftables status
❌ nftban verify            # Verify nftables structure
```

**Missing Files:**
- ❌ No cmd_nft.sh (or equivalent)
- ❌ No core nftables management module

---

### CRITICAL: IP Management (nftables set operations)

```bash
❌ nftban ip add <IP> <SET>       # Add IP to nftables set
❌ nftban ip remove <IP> <SET>    # Remove IP from nftables set
❌ nftban ip search <IP>          # Search IP in all sets
❌ nftban ip list <SET>           # List IPs in set
❌ nftban ip flush <SET>          # Flush specific set
```

**Missing Files:**
- ❌ No cmd_ip.sh
- ❌ No core IP management module

---

### CRITICAL: Ban/Unban Aliases

```bash
❌ nftban ban <IP> [timeout]      # Quick ban (alias for ip add temp_ban)
❌ nftban unban <IP>              # Quick unban (alias for ip remove temp_ban)
```

**Can be implemented as:**
- Aliases in main CLI
- Or as cmd_ban.sh

═══════════════════════════════════════════════════════════════════════════════

## 📋 IMPLEMENTATION PLAN

### Step 1: Create Core nftables Module

```bash
# Create: /usr/lib/nftban/core/nftban_nftables.sh

This module will contain:
- nftban_nftables_init()            # Create tables, sets, chains, rules
- nftban_nftables_start()           # Apply all rules
- nftban_nftables_stop()            # Remove all rules
- nftban_nftables_restart()         # Stop + Start
- nftban_nftables_reload()          # Reload configuration
- nftban_nftables_flush()           # Flush all sets
- nftban_nftables_status()          # Check if active
- nftban_nftables_verify()          # Verify structure
- nftban_nftables_enable_boot()     # Systemd enable
- nftban_nftables_disable_boot()    # Systemd disable
```

**Based on OLD v0.9.x:**
- File: /home/gituser/github/nftban/lib/nftban_nftables_module.sh
- Keep LOGIC: tables, sets, rule order, port format
- Migrate to NEW FHS structure

---

### Step 2: Create Core IP Management Module

```bash
# Create: /usr/lib/nftban/core/nftban_ip.sh

This module will contain:
- nftban_ip_add(ip, set, [timeout])     # Add IP to set
- nftban_ip_remove(ip, set)             # Remove IP from set
- nftban_ip_search(ip)                  # Search IP in all sets
- nftban_ip_list(set)                   # List IPs in set
- nftban_ip_flush(set)                  # Flush set
- nftban_ip_validate(ip)                # Validate IP format
```

**Integration with Go:**
- Use Go binary for validation: nftban-geoip validate <IP>
- Use Go binary for GeoIP: nftban-geoip country <IP>
- Bash handles nftables operations (for now)

---

### Step 3: Create CLI Command Handlers

```bash
# Create: /usr/lib/nftban/cli/cmd_nft.sh

nftban_cmd_nft() {
    local action="${1:-status}"

    case "$action" in
        init)     nftban_nftables_init ;;
        start)    nftban_nftables_start ;;
        stop)     nftban_nftables_stop ;;
        restart)  nftban_nftables_restart ;;
        reload)   nftban_nftables_reload ;;
        enable)   nftban_nftables_enable_boot ;;
        disable)  nftban_nftables_disable_boot ;;
        flush)    nftban_nftables_flush ;;
        status)   nftban_nftables_status ;;
        verify)   nftban_nftables_verify ;;
        help)     show_nft_help ;;
        *)        nftban_log_error "Unknown nft action: $action" ;;
    esac
}
```

```bash
# Create: /usr/lib/nftban/cli/cmd_ip.sh

nftban_cmd_ip() {
    local action="${1:-list}"
    shift || true

    case "$action" in
        add)      nftban_ip_add "$@" ;;
        remove)   nftban_ip_remove "$@" ;;
        search)   nftban_ip_search "$@" ;;
        list)     nftban_ip_list "$@" ;;
        flush)    nftban_ip_flush "$@" ;;
        help)     show_ip_help ;;
        *)        nftban_log_error "Unknown ip action: $action" ;;
    esac
}
```

---

### Step 4: Update Main CLI

```bash
# Update: /usr/sbin/nftban

Add to completion:
- "nft" with subcommands: init, start, stop, restart, reload, enable, disable, flush, status, verify
- "ip" with subcommands: add, remove, search, list, flush
- "ban" (flat command)
- "unban" (flat command)

Add flat command shortcuts:
case "$cmd" in
    init|start|stop|restart|reload|enable|disable|flush)
        # Shortcut for nftban nft <cmd>
        nftban_cmd_nft "$cmd" "$@"
        ;;
    ban)
        # Shortcut for nftban ip add temp_ban
        nftban_ip_add "$1" temp_ban "${2:-3600}"
        ;;
    unban)
        # Shortcut for nftban ip remove temp_ban
        nftban_ip_remove "$1" temp_ban
        ;;
    status|verify)
        # System-wide status (both nftables + general)
        nftban_show_status
        ;;
    ...
esac
```

═══════════════════════════════════════════════════════════════════════════════

## 🎯 IMPLEMENTATION ORDER (Priority)

### Phase 1: Core nftables Management (HIGHEST PRIORITY)

1. ✅ Read OLD nftban_nftables_module.sh (DONE - documented)
2. ⏳ Create nftban_nftables.sh (new core module)
3. ⏳ Create cmd_nft.sh (CLI handler)
4. ⏳ Update main CLI (add nft command + flat shortcuts)
5. ⏳ Test: init, start, stop, status, verify

**Files to create:**
- `/usr/lib/nftban/core/nftban_nftables.sh`
- `/usr/lib/nftban/cli/cmd_nft.sh`

**Files to update:**
- `/usr/sbin/nftban` (add nft to completion + case statement)

---

### Phase 2: IP Management (HIGH PRIORITY)

1. ✅ Read OLD nftban_search_module.sh + nftban_blacklist_module.sh (DONE)
2. ⏳ Create nftban_ip.sh (new core module)
3. ⏳ Create cmd_ip.sh (CLI handler)
4. ⏳ Update main CLI (add ip command + ban/unban aliases)
5. ⏳ Test: ban, unban, search, list

**Files to create:**
- `/usr/lib/nftban/core/nftban_ip.sh`
- `/usr/lib/nftban/cli/cmd_ip.sh`

**Files to update:**
- `/usr/sbin/nftban` (add ip + ban/unban)

---

### Phase 3: Go Integration (MEDIUM PRIORITY)

1. ✅ Go binary exists: nftban-geoip (deployed)
2. ⏳ Integrate Go validation in nftban_ip.sh
3. ⏳ Integrate Go GeoIP checks
4. ⏳ Test Go-Bash integration

**Files to update:**
- `/usr/lib/nftban/core/nftban_ip.sh` (call Go binary)
- `/usr/lib/nftban/core/nftban_geoip_go.sh` (already exists, may need updates)

---

### Phase 4: Boot Integration (MEDIUM PRIORITY)

1. ⏳ Create systemd service: nftban.service
2. ⏳ Implement enable/disable commands
3. ⏳ Test boot integration

**Files to create:**
- `/usr/lib/systemd/system/nftban.service` (or in src/usr/share/nftban/systemd/)

═══════════════════════════════════════════════════════════════════════════════

## 📝 SUMMARY

**CURRENT STATE:**
- ✅ v0.10.0 has excellent infrastructure (FHS, reports, health, GeoIP, mail)
- ❌ v0.10.0 MISSING core nftables management (init, start, stop, ban, unban)

**CRITICAL MISSING:**
1. nftables lifecycle (init, start, stop, enable, disable, flush, reload)
2. IP management (ban, unban, search, list)
3. Core modules for above (nftban_nftables.sh, nftban_ip.sh)
4. CLI handlers (cmd_nft.sh, cmd_ip.sh)

**NEXT STEP:**
Implement Phase 1 (nftables management) based on OLD v0.9.x logic

═══════════════════════════════════════════════════════════════════════════════

**🚨 READY TO IMPLEMENT nftables MANAGEMENT MODULE!** 🎯
