# NFTBan Main CLI Module

**File:** `lib/nftban_main_cli.sh`  
**Version:** 0.8.5  
**Author:** ITCMS Team (Antonios Voulvoulis)  
**Purpose:** Unified command-line interface and command router for all NFTBan operations

---

## Overview

The Main CLI Module serves as the primary entry point and command router for the NFTBan system. It provides a comprehensive, user-friendly command-line interface that unifies all NFTBan functionality under a single `nftban` command. The module implements a hierarchical command structure with intuitive subcommands, parameter validation, and helpful error messages.

This module acts as a dispatcher, routing user commands to the appropriate specialized modules while handling common tasks like root privilege checking, parameter validation, and usage help. It supports over 100 different command combinations across 15+ major command categories including IP management, statistics, DDoS protection, port scanning detection, geo-blocking, and system maintenance.

The CLI follows modern conventions with support for both long-form commands (`nftban whitelist add`) and convenient aliases (`nftban wl add`, `nftban ban`). All commands provide contextual help and validation to prevent user errors.

---

## Key Functions

### Command Handler Functions (Public)

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `main()` | Main command router | `$@` - command line arguments | Exit code 0/1 |
| `show_usage()` | Display comprehensive help | None | Prints help to stdout |
| `cmd_validate()` | Validation system commands | `$1` - action, `$@` - args | Status code |
| `cmd_feeds()` | Threat feeds management | `$1` - action, `$@` - args | Status code |
| `cmd_update()` | System update operations | `$1` - action, `$@` - args | Status code |
| `cmd_maintenance()` | Maintenance operations | `$1` - action, `$@` - args | Status code |
| `cmd_whitelist()` | Whitelist management | `$1` - action, `$@` - args | Status code |
| `cmd_blacklist()` | Blacklist management | `$1` - action, `$@` - args | Status code |
| `cmd_stats()` | Statistics and reporting | `$1` - action, `$@` - args | Status code |
| `cmd_port()` | Port management | `$1` - action, `$@` - args | Status code |
| `cmd_ddos()` | DDoS protection controls | `$1` - action, `$@` - args | Status code |
| `cmd_portscan()` | Port scan detection | `$1` - action, `$@` - args | Status code |
| `cmd_geo()` | Geographic blocking | `$1` - action, `$@` - args | Status code |
| `cmd_init()` | System initialization | None | Status code |
| `cmd_status()` | Display system status | None | Status code |
| `cmd_verify()` | System verification | None | Error count |
| `cmd_test()` | Smoke testing | `$1` - action, `$@` - args | Status code |
| `cmd_diagnostics()` | Diagnostics collection | `$1` - action, `$@` - args | Status code |

### Internal Functions (Command Routing)

| Function | Purpose | Notes |
|----------|---------|-------|
| Command dispatchers | Route to specialized modules | Each cmd_* function handles one command category |

---

## Configuration Variables

### Script Paths

| Variable | Default | Description |
|----------|---------|-------------|
| `VERSION` | `0.8.5` | CLI version number |
| `SCRIPT_DIR` | Auto-detected | Directory containing CLI script |
| `LIB_DIR` | `${SCRIPT_DIR}/../lib` | Module library directory |

---

## Dependencies

**Required Modules:**
- `nftban_core.sh` - Core functionality (MUST exist)
- `nftban_nftables_module.sh` - nftables operations
- `nftban_whitelist_module.sh` - Whitelist management
- `nftban_blacklist_module.sh` - Blacklist management
- `nftban_search_module.sh` - IP search operations
- `nftban_stats_module.sh` - Statistics generation
- `nftban_port_module.sh` - Port management
- `nftban_ddos_module.sh` - DDoS protection
- `nftban_portscan_module.sh` - Port scan detection
- `nftban_geo_module.sh` - Geographic blocking
- `nftban_feeds_module.sh` - Threat feeds
- `nftban_update_module.sh` - System updates
- `nftban_maintenance_module.sh` - Maintenance tasks
- `nftban_smoketest_module.sh` - Testing framework
- Validator modules: `nftban-validator-github.sh`, `nftban-validator-panel.sh`

**External Commands (Required):**
- `bash` (v4.0+) - Shell interpreter
- `nft` - nftables command

**External Commands (Optional, per feature):**
- `mail` or `sendmail` - Email notifications
- `curl` or `wget` - Updates and feeds
- `systemctl` - Timer management
- Various module-specific dependencies

---

## Usage Examples

### Example 1: System Initialization
```bash
# Initialize NFTBan for first time
sudo nftban init

# Expected output:
# [INFO] Initializing nftban system v0.8.5...
# [SUCCESS] nftban initialized successfully

# Check system status
nftban status
```

### Example 2: Validation Commands
```bash
# Check validation status
nftban validate status

# Run full validation
sudo nftban validate run

# Interactive validation panel
sudo nftban validate panel

# Validate specific file
sudo nftban validate file /etc/nftban/lib/nftban_core.sh

# Update SHA256SUMS cache
sudo nftban validate update-sums
```

### Example 3: Whitelist Management
```bash
# Add IP to whitelist
sudo nftban whitelist add 192.168.1.100 "Office server"

# Remove IP from whitelist
sudo nftban whitelist remove 192.168.1.100

# List all whitelisted IPs
nftban whitelist list

# Check if IP is whitelisted
nftban whitelist check 192.168.1.100

# Whitelist current user's IP (protection)
sudo nftban whitelist protect-me

# Show whitelist statistics
nftban whitelist stats

# Verify whitelist integrity
nftban whitelist verify

# Sync whitelist to nftables
sudo nftban whitelist sync

# Using aliases
sudo nftban wl add 10.0.0.1 "Another IP"
```

### Example 4: Blacklist Management
```bash
# Temporarily ban IP (default 1 hour)
sudo nftban blacklist ban 1.2.3.4 3600 "Brute force attempt"

# Quick ban using alias
sudo nftban ban 5.6.7.8 7200

# Unban IP
sudo nftban unban 1.2.3.4

# Permanently ban IP
sudo nftban blacklist permanent 9.9.9.9 "Known malicious"

# Remove permanent ban
sudo nftban blacklist remove-permanent 9.9.9.9

# List permanent bans
nftban blacklist list

# Show ban statistics
nftban blacklist stats

# Show top 20 banned IPs
nftban blacklist top 20

# Sync blacklist to nftables
sudo nftban blacklist sync

# Using aliases
sudo nftban bl ban 11.22.33.44
```

### Example 5: Statistics & Monitoring
```bash
# Show main dashboard
nftban stats dashboard

# Whitelist statistics
nftban stats whitelist

# Blacklist statistics
nftban stats blacklist

# Ban activity
nftban stats bans

# GEO statistics
nftban stats geo

# Cloudflare statistics
nftban stats cloudflare

# nftables statistics
nftban stats nftables

# IP history lookup
nftban stats history 192.168.1.100

# Top 10 banned IPs
nftban stats top 10

# Recent 50 events
nftban stats recent 50

# Export to CSV
nftban stats export /tmp/nftban_stats.csv

# Generate report
nftban stats report /tmp/nftban_report.txt
```

### Example 6: Port Management
```bash
# Add allowed port
sudo nftban port add 8080 tcp "Web application"

# Remove port
sudo nftban port remove 8080 tcp

# List all allowed ports
nftban port list

# Apply port configuration to nftables
sudo nftban port apply

# Validate port configuration
nftban port validate

# Using aliases
sudo nftban ports add 443 tcp "HTTPS"
```

### Example 7: DDoS Protection
```bash
# Show DDoS protection status
nftban ddos status

# Enable all DDoS protections
sudo nftban ddos enable

# Disable all DDoS protections
sudo nftban ddos disable

# SYN flood protection
sudo nftban ddos synflood enable
sudo nftban ddos synflood disable
nftban ddos synflood status

# Connection limit protection
sudo nftban ddos connlimit enable
sudo nftban ddos connlimit add 22 5
nftban ddos connlimit status

# Port flood protection
sudo nftban ddos portflood enable
sudo nftban ddos portflood add 80 20/5
nftban ddos portflood status

# ICMP protection
sudo nftban ddos icmp enable
sudo nftban ddos icmp disable
nftban ddos icmp status
```

### Example 8: Port Scan Detection
```bash
# Show port scan detection status
nftban portscan status

# Enable port scan detection
sudo nftban portscan enable

# Disable port scan detection
sudo nftban portscan disable

# Manual check for scanners
sudo nftban portscan check

# Check specific IP
nftban portscan check-ip 192.168.1.100

# Show detection statistics
nftban portscan stats

# Cleanup old tracking data
sudo nftban portscan cleanup

# Whitelist management
sudo nftban portscan whitelist add 192.168.1.1 "Office scanner"
sudo nftban portscan whitelist remove 192.168.1.1
nftban portscan whitelist list
```

### Example 9: Geographic Blocking
```bash
# Show GEO-blocking status
nftban geo status

# Enable GEO-blocking
sudo nftban geo enable

# Disable GEO-blocking
sudo nftban geo disable

# Show comprehensive help
nftban geo help

# Block a country
sudo nftban geo block CN
sudo nftban geo block RU

# Unblock a country
sudo nftban geo unblock CN

# List blocked countries
nftban geo list

# Check if IP is GEO-blocked
nftban geo check 1.2.3.4

# Reload blacklist to nftables
sudo nftban geo reload

# Update GeoIP database
sudo nftban geo update ALL
sudo nftban geo update CN

# Initialize GEO-blocking
sudo nftban geo init
```

### Example 10: Threat Feeds Management
```bash
# Initialize feeds system
sudo nftban feeds init

# List available feed providers
nftban feeds list

# Enable feed provider
sudo nftban feeds enable spamhaus
sudo nftban feeds enable firehol

# Disable feed provider
sudo nftban feeds disable spamhaus

# Update all feeds
sudo nftban feeds update

# Update specific feed
sudo nftban feeds update spamhaus

# Show feeds status
nftban feeds status

# Set update interval (in hours)
sudo nftban feeds set-interval 6

# Install systemd timer for automatic updates
sudo nftban feeds timer-install

# Remove systemd timer
sudo nftban feeds timer-remove

# Show memory usage
nftban feeds memory
```

### Example 11: System Updates
```bash
# Check for updates
sudo nftban update check

# Perform update with confirmation
sudo nftban update perform

# Perform update without confirmation
sudo nftban update auto

# Rollback to previous version
sudo nftban update rollback

# Rollback to specific backup
sudo nftban update rollback /etc/nftban/data/backups/pre_update_20251020

# Show version information
nftban update version
```

### Example 12: Maintenance Operations
```bash
# Show maintenance panel
nftban maintenance panel

# Validate configuration files
nftban maintenance validate

# Repair broken configuration
sudo nftban maintenance repair

# Comprehensive health check
nftban maintenance health

# Basic health check
nftban maintenance health-basic

# Show system statistics
nftban maintenance stats

# Create manual backup
sudo nftban maintenance backup

# List available backups
nftban maintenance list-backups

# Run maintenance cleanup
sudo nftban maintenance clean

# Using aliases
nftban maint panel
```

### Example 13: Testing & Diagnostics
```bash
# Quick smoke test
nftban test quick

# Full comprehensive test
nftban test full

# Test specific category
nftban test category nftables
nftban test category modules
nftban test category safety

# Show test help
nftban test help

# Collect diagnostics
nftban diagnostics
nftban diagnostics collect /tmp/my_diagnostics.txt

# Show diagnostics help
nftban diagnostics help

# Using aliases
nftban smoke-test quick
nftban diag collect
```

### Example 14: System Verification
```bash
# Run full system verification
nftban verify

# Expected output:
# [SUCCESS] nftables structure: OK
# [SUCCESS] Whitelist system: OK
# [SUCCESS] Search index: OK
# [SUCCESS] Verification passed

# Initialize system
sudo nftban init

# Check version
nftban version
nftban --version
nftban -v

# Show help
nftban help
nftban --help
nftban -h
```

---

## Command Structure

### Top-Level Commands

```
nftban <command> [subcommand] [options]
```

### Command Categories

#### System Management
- `init` - Initialize system
- `status` - Show system status
- `verify` - Verify system health
- `version` - Show version
- `help` - Show help

#### Validation
- `validate run` - Full validation
- `validate panel` - Interactive TUI
- `validate status` - Quick status
- `validate update-sums` - Update cache
- `validate file <path>` - Single file

#### IP Management
- `whitelist` (`wl`) - Whitelist operations
- `blacklist` (`bl`) - Blacklist operations
- `ban` - Quick ban alias
- `unban` - Quick unban alias

#### Statistics
- `stats dashboard` - Main dashboard
- `stats whitelist` - Whitelist stats
- `stats blacklist` - Blacklist stats
- `stats bans` - Ban activity
- `stats geo` - GEO stats
- `stats top` - Top banned IPs
- `stats recent` - Recent events
- `stats export` - Export to CSV
- `stats report` - Generate report

#### Port Management
- `port add` - Add allowed port
- `port remove` - Remove port
- `port list` - List ports
- `port apply` - Apply to nftables
- `port validate` - Validate config

#### Security Features
- `ddos` - DDoS protection
- `portscan` - Port scan detection
- `geo` - Geographic blocking
- `feeds` - Threat feeds

#### Maintenance
- `update` - System updates
- `maintenance` (`maint`) - Maintenance tasks
- `test` - Smoke testing
- `diagnostics` (`diag`) - Diagnostics

---

## File Operations

**Reads from:**
- `${LIB_DIR}/nftban_core.sh` - Core module (required)
- All other modules in `${LIB_DIR}/` - Feature modules
- `/etc/nftban/config/*` - Configuration files (via modules)

**Writes to:**
- `/var/log/nftban/nftban.log` - Command execution log (via core)
- Module-specific files (delegated to respective modules)

**Executes:**
- All NFTBan modules based on command routing
- External validator scripts

---

## Security Considerations

### Privilege Management
- **Root Checking:** Most commands require root privileges via `nftban_check_root`
- **Read-Only Commands:** Status, list, check commands can run as non-root
- **Write Commands:** Add, remove, enable, disable require root
- **Explicit Checks:** Each command handler validates privileges before operations

### Parameter Validation
- **Required Parameters:** Commands validate required parameters before execution
- **Parameter Count:** Validates minimum parameter counts with helpful error messages
- **IP Validation:** IP addresses validated by underlying modules
- **Path Validation:** File paths checked for existence before operations

### Command Injection Prevention
- **No Direct Shell Execution:** All parameters passed to module functions
- **Module Encapsulation:** User input processed by specialized modules
- **Error Handling:** Invalid commands logged and rejected

### Safe Defaults
- **Default Actions:** Sensible defaults for optional parameters
- **Confirmation Prompts:** Destructive operations require confirmation (update perform)
- **Auto Mode:** Explicit auto mode for unattended operations

---

## Error Handling

**Common Errors:**

```bash
# Missing core module
ERROR: Core module not found at ${LIB_DIR}/nftban_core.sh

# Unknown command
[ERROR] Unknown command: <command>
Run 'nftban help' to see available commands

# Unknown subcommand action
[ERROR] Unknown <category> action: <action>
Available actions: [list of actions]

# Root privilege required
[ERROR] This operation must be run as root

# Missing required parameters
[ERROR] Usage: nftban <command> <required_params>

# Validator not found
[ERROR] GitHub validator not found: <path>
[ERROR] Validator panel not found: <path>

# Module function not available
[ERROR] Function not found (module not loaded)
```

**Exit Codes:**
- `0` - Success
- `1` - Error (validation failed, command failed, missing parameters)
- Specific error codes returned by individual module functions

**Error Recovery:**
- Helpful error messages guide user to correct usage
- Suggests `nftban help` for unknown commands
- Shows available actions for unknown subcommands
- Provides usage examples in error output

---

## Integration Points

**Called by:**
- **System administrator** - Primary interface via command line
- **Init scripts** - `/etc/init.d/nftban` for service management
- **Cron jobs** - Scheduled tasks (feeds update, maintenance)
- **Fail2Ban** - Ban/unban actions via action scripts
- **Automation scripts** - Third-party integration scripts

**Calls:**
- **All NFTBan modules** - Routes commands to specialized modules
- `nftban_core.sh` functions - Logging, validation, utilities
- `nftban_whitelist_module.sh` - Whitelist operations
- `nftban_blacklist_module.sh` - Blacklist operations
- `nftban_stats_module.sh` - Statistics generation
- `nftban_feeds_module.sh` - Threat feeds management
- `nftban_update_module.sh` - System updates
- `nftban_maintenance_module.sh` - Maintenance tasks
- `nftban_geo_module.sh` - Geographic blocking
- `nftban_ddos_module.sh` - DDoS protection
- `nftban_portscan_module.sh` - Port scan detection
- Validator scripts - File validation operations

**Environment:**
- Exports functions via sourced modules
- Inherits environment from parent shell
- Sets `set -euo pipefail` for strict error handling

---

## Command Aliases

The CLI supports convenient aliases for common operations:

| Alias | Full Command | Purpose |
|-------|--------------|---------|
| `wl` | `whitelist` | Whitelist operations |
| `bl` | `blacklist` | Blacklist operations |
| `ban` | `blacklist ban` | Quick ban |
| `unban` | `blacklist unban` | Quick unban |
| `maint` | `maintenance` | Maintenance operations |
| `ports` | `port` | Port management |
| `smoke-test` | `test` | Testing operations |
| `smoketest` | `test` | Testing operations |
| `diag` | `diagnostics` | Diagnostics collection |
| `debug` | `diagnostics` | Diagnostics collection |
| `validator` | `validate` | Validation operations |
| `-v` | `version` | Show version |
| `--version` | `version` | Show version |
| `-h` | `help` | Show help |
| `--help` | `help` | Show help |

---

## Performance Characteristics

- **Command Routing:** <1ms (pure bash case statement)
- **Module Loading:** 200-500ms (via core module initialization)
- **Command Execution:** Varies by operation (delegated to modules)
- **Help Display:** <10ms (static text output)
- **Validation Operations:** 100-2000ms (depends on file count and checksums)

**Optimization Notes:**
- Core module loaded once on script start
- Modules auto-loaded by core (lazy loading pattern)
- Fast command routing using bash case statements
- No unnecessary external command execution
- Efficient parameter parsing

---

## CLI Design Principles

### Hierarchical Structure
```
nftban
├── System Commands (init, status, verify)
├── IP Management (whitelist, blacklist, ban, unban)
├── Statistics (stats)
├── Port Management (port)
├── Security Features (ddos, portscan, geo)
├── Feeds (feeds)
├── Maintenance (update, maintenance)
└── Testing (test, diagnostics, validate)
```

### Consistent Patterns
- **Action-based:** `nftban <noun> <verb> <params>`
- **Resource-oriented:** Commands organized by resource type
- **CRUD operations:** add, remove, list, show for most resources
- **Status queries:** status, check, verify commands don't require root

### User-Friendly
- **Helpful errors:** Clear error messages with usage hints
- **Auto-complete friendly:** Short, memorable command names
- **Flexible syntax:** Supports aliases and abbreviations
- **Rich help:** Comprehensive help with examples

---

## Change Log

### Version 0.8.5 (Current)
- Added comprehensive validation system (`validate` commands)
- Added threat feeds management (`feeds` commands)
- Added system update functionality (`update` commands)
- Added maintenance operations (`maintenance` commands)
- Enhanced testing framework (`test` commands)
- Added diagnostics collection (`diagnostics` commands)
- Improved help system with detailed examples
- Added command aliases for convenience
- Enhanced error messages with contextual help

### Version 0.8.x (Previous)
- Added DDoS protection commands
- Added port scan detection commands
- Added geographic blocking commands
- Added statistics and reporting commands
- Improved command structure and organization

---

## See Also

**Related Modules:**
- `nftban_core.sh` - Core functionality
- `nftban_whitelist_module.sh` - Whitelist operations
- `nftban_blacklist_module.sh` - Blacklist operations
- `nftban_stats_module.sh` - Statistics generation
- `nftban_feeds_module.sh` - Threat feeds
- `nftban_update_module.sh` - System updates
- `nftban_maintenance_module.sh` - Maintenance tasks
- `nftban_geo_module.sh` - Geographic blocking
- `nftban_ddos_module.sh` - DDoS protection
- `nftban_portscan_module.sh` - Port scan detection
- `nftban_smoketest_module.sh` - Testing framework

**Related Documentation:**
- `README.md` - System overview
- `COMMANDS.md` - Complete command reference
- `EXAMPLES.md` - Usage examples and tutorials
- `API.md` - Module API reference

**Scripts:**
- `nftban` - Main executable (symlinked to this module)
- `/etc/init.d/nftban` - System service init script
- Fail2Ban action scripts in `/etc/fail2ban/action.d/`

**Help Resources:**
```bash
# Show main help
nftban help

# Show category-specific help
nftban <command> help
nftban geo help
nftban test help
nftban diagnostics help
nftban validate help
```
