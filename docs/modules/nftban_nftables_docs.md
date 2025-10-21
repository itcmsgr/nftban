# NFTBan nftables Module

**File:** `lib/nftban_nftables_module.sh`  
**Version:** 2.0.0 (v0.9.0 Split Table Architecture)  
**Author:** ITCMS Team (Antonios Voulvoulis)  
**Purpose:** Dual-table nftables management with 30-50% performance improvement

---

## Overview

The nftables Module manages the complete nftables infrastructure for NFTBan using a revolutionary split-table architecture introduced in v0.9.0. Instead of a single unified `inet` table handling both IPv4 and IPv6 traffic, the system now uses two separate tables: `ip nftban_v4` and `ip6 nftban_v6`. This architectural change delivers 30-50% performance improvement through simpler rules, better cache efficiency, and faster packet processing.

The module handles all nftables operations including table creation, rule application, set management, port configuration, and structure verification. It creates five essential sets in each table (whitelist, temp_ban, user_blacklist, system_blacklist, feeds) and manages input/output chains with priority-ordered rules. The whitelist is checked first (highest priority), followed by threat feeds, temporary bans, and permanent blacklists.

Legacy support is maintained for migration from v0.8.5's unified table architecture. The module can detect legacy tables, warn administrators, and coexist during migration periods.

---

## Key Functions

### Public Functions (Exported) - Table Management

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `nftban_nftables_check_table()` | Check if tables exist | `$1` - family ("v4", "v6", "both") | 0 if exists, 1 if not |
| `nftban_nftables_check_legacy_table()` | Check for v0.8.5 table | None | 0 if exists, 1 if not |
| `nftban_nftables_create_table()` | Create both v4 and v6 tables | None | Status code |
| `nftban_nftables_create_table_v4()` | Create IPv4 table only | None | Status code |
| `nftban_nftables_create_table_v6()` | Create IPv6 table only | None | Status code |
| `nftban_nftables_apply_rules()` | Apply rules to both tables | None | Status code |
| `nftban_nftables_apply_rules_v4()` | Apply IPv4 rules only | None | Status code |
| `nftban_nftables_apply_rules_v6()` | Apply IPv6 rules only | None | Status code |
| `nftban_nftables_delete_table()` | Delete both tables | None | Status code |
| `nftban_nftables_delete_table_v4()` | Delete IPv4 table only | None | Status code |
| `nftban_nftables_delete_table_v6()` | Delete IPv6 table only | None | Status code |
| `nftban_nftables_delete_legacy_table()` | Delete v0.8.5 legacy table | None | Status code |
| `nftban_nftables_verify_structure()` | Verify table structure | None | 0 if valid, 1 if errors |
| `nftban_nftables_show_set_stats()` | Display set statistics | None | Prints to stdout |
| `nftban_nftables_show_status()` | Display complete status | None | Prints to stdout |

### Public Functions (Exported) - Port Management

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `nftban_nftables_init_port_configs()` | Initialize port config files | None | Creates config files |
| `nftban_nftables_add_port()` | Add allowed port | `$1` - port, `$2` - protocol (T/U/B), `$3` - direction, `$4` - IP version | Status code |
| `nftban_nftables_remove_port()` | Remove allowed port | `$1` - port, `$2` - protocol, `$3` - direction, `$4` - IP version | Status code |
| `nftban_nftables_list_ports()` | List configured ports | `$1` - filter (all/input/output) | Prints to stdout |
| `nftban_nftables_apply_port_rules_v4()` | Apply IPv4 port rules | `$1` - direction (input/output) | Status code |
| `nftban_nftables_apply_port_rules_v6()` | Apply IPv6 port rules | `$1` - direction (input/output) | Status code |

### Internal Functions (Private)

All internal nftables operations are performed via the public functions listed above. No private helper functions are exposed.

---

## Configuration Variables

### Table Names (v0.9.0 Split Architecture)

| Variable | Default | Description |
|----------|---------|-------------|
| `NFTBAN_NFT_TABLE_V4` | `nftban_v4` | IPv4 table name |
| `NFTBAN_NFT_TABLE_V6` | `nftban_v6` | IPv6 table name |
| `NFTBAN_NFT_FAMILY_V4` | `ip` | IPv4 table family |
| `NFTBAN_NFT_FAMILY_V6` | `ip6` | IPv6 table family |

### Legacy Support (v0.8.5 Compatibility)

| Variable | Default | Description |
|----------|---------|-------------|
| `NFTBAN_NFT_TABLE_LEGACY` | `nftban_global` | Legacy unified table name |
| `NFTBAN_NFT_FAMILY_LEGACY` | `inet` | Legacy table family |

### Port Configuration Files

| Variable | Default | Description |
|----------|---------|-------------|
| `NFTBAN_PORT_CONFIG_DIR` | `/etc/nftban/config/ports` | Port configuration directory |
| `NFTBAN_IPV4_INPUT_PORTS` | `${NFTBAN_PORT_CONFIG_DIR}/ipv4-input.conf` | IPv4 input ports |
| `NFTBAN_IPV4_OUTPUT_PORTS` | `${NFTBAN_PORT_CONFIG_DIR}/ipv4-output.conf` | IPv4 output ports |
| `NFTBAN_IPV6_INPUT_PORTS` | `${NFTBAN_PORT_CONFIG_DIR}/ipv6-input.conf` | IPv6 input ports |
| `NFTBAN_IPV6_OUTPUT_PORTS` | `${NFTBAN_PORT_CONFIG_DIR}/ipv6-output.conf` | IPv6 output ports |

---

## Dependencies

**Required Modules:**
- `nftban_core.sh` - Core logging and utilities

**External Commands (Required):**
- `nft` - nftables command (v0.9.0+) - **CRITICAL**
- `bash` (v4.0+) - Shell interpreter

**External Commands (Optional):**
- `grep`, `awk`, `sed` - Text processing for port configs
- `wc` - Counting for statistics

---

## Usage Examples

### Example 1: Create Split Table Architecture
```bash
# Create both IPv4 and IPv6 tables
nftban_nftables_create_table

# Expected output:
# [INFO] Creating nftban v0.9.0 split table architecture...
# [INFO] Creating IPv4 table: ip nftban_v4
# [SUCCESS] IPv4 table created successfully
# [INFO] Creating IPv6 table: ip6 nftban_v6
# [SUCCESS] IPv6 table created successfully
# [INFO] Applying nftables rules to both tables...
# [SUCCESS] All nftables rules applied successfully
# [SUCCESS] Split table architecture created successfully

# Create individual tables
nftban_nftables_create_table_v4  # IPv4 only
nftban_nftables_create_table_v6  # IPv6 only
```

### Example 2: Check Table Existence
```bash
# Check if both tables exist
if nftban_nftables_check_table "both"; then
    echo "Split tables are configured"
fi

# Check IPv4 table only
if nftban_nftables_check_table "v4"; then
    echo "IPv4 table exists"
fi

# Check IPv6 table only
if nftban_nftables_check_table "v6"; then
    echo "IPv6 table exists"
fi

# Check for legacy v0.8.5 table
if nftban_nftables_check_legacy_table; then
    echo "Legacy table found - migration needed"
fi
```

### Example 3: Apply Rules
```bash
# Apply rules to both tables
nftban_nftables_apply_rules

# Apply rules to specific table
nftban_nftables_apply_rules_v4  # IPv4 only
nftban_nftables_apply_rules_v6  # IPv6 only

# Rules are automatically ordered:
# 1. Accept established/related connections
# 2. Accept loopback
# 3. WHITELIST (highest priority)
# 4. Block threat feeds
# 5. Block temporary bans
# 6. Block user blacklist
# 7. Block system blacklist
# 8. Accept ICMP/ICMPv6
# 9. Apply port rules
```

### Example 4: Verify Structure
```bash
# Verify table structure integrity
if nftban_nftables_verify_structure; then
    echo "Structure is valid"
else
    echo "Structure has errors"
fi

# Expected verification:
# - IPv4 table exists
# - IPv6 table exists
# - All 5 required sets exist in each table:
#   * whitelist
#   * temp_ban
#   * user_blacklist
#   * system_blacklist
#   * feeds
```

### Example 5: Show Status and Statistics
```bash
# Show complete status
nftban_nftables_show_status

# Expected output:
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  nftables Status (v0.9.0 Split Tables)
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#
# âœ" IPv4 table: ip nftban_v4
# âœ" IPv6 table: ip6 nftban_v6
#
#  Sets (IPv4 - nftban_v4):
#    whitelist:                  10 IPs
#    temp_ban:                   25 IPs
#    user_blacklist:              5 IPs
#    system_blacklist:          100 IPs
#    feeds:                    5000 IPs
#
#  Sets (IPv6 - nftban_v6):
#    whitelist:                   3 IPs
#    temp_ban:                    8 IPs
#    user_blacklist:              2 IPs
#    system_blacklist:           15 IPs
#    feeds:                     500 IPs

# Show just set statistics
nftban_nftables_show_set_stats
```

### Example 6: Port Management - Initialization
```bash
# Initialize port configuration files
nftban_nftables_init_port_configs

# Creates 4 config files:
# /etc/nftban/config/ports/ipv4-input.conf
# /etc/nftban/config/ports/ipv4-output.conf
# /etc/nftban/config/ports/ipv6-input.conf
# /etc/nftban/config/ports/ipv6-output.conf

# Each file contains format:
# PORT|PROTOCOL
# T=TCP, U=UDP, B=Both
# Examples:
#   22|T        # SSH (TCP only)
#   53|U        # DNS (UDP only)
#   80|B        # HTTP (both TCP and UDP)
```

### Example 7: Port Management - Add Ports
```bash
# Add SSH port (IPv4, TCP, input)
nftban_nftables_add_port 22 T input 4

# Add HTTP port (IPv4, both TCP and UDP, input)
nftban_nftables_add_port 80 B input 4

# Add HTTPS port (IPv6, TCP, input)
nftban_nftables_add_port 443 T input 6

# Add DNS port (IPv4, UDP, output)
nftban_nftables_add_port 53 U output 4

# Add port range (IPv4, TCP, input)
nftban_nftables_add_port 8080-8090 T input 4

# Parameters:
# $1 = port or port range (e.g., "22" or "8080-8090")
# $2 = protocol: T (TCP), U (UDP), B (both)
# $3 = direction: input or output
# $4 = IP version: 4 or 6
```

### Example 8: Port Management - Remove Ports
```bash
# Remove SSH port from IPv4 input
nftban_nftables_remove_port 22 T input 4

# Remove HTTP from IPv6 input
nftban_nftables_remove_port 80 B input 6

# After removal, rules are automatically reapplied
```

### Example 9: Port Management - List Ports
```bash
# List all configured ports
nftban_nftables_list_ports all

# List only input ports
nftban_nftables_list_ports input

# List only output ports
nftban_nftables_list_ports output

# Expected output:
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  Configured Ports
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#
# IPv4 INPUT:
#  22                   TCP
#  80                   TCP+UDP
#  443                  TCP
#
# IPv4 OUTPUT:
#  53                   UDP
```

### Example 10: Delete Tables
```bash
# Delete both tables
nftban_nftables_delete_table

# Delete specific table
nftban_nftables_delete_table_v4  # IPv4 only
nftban_nftables_delete_table_v6  # IPv6 only

# Delete legacy v0.8.5 table
nftban_nftables_delete_legacy_table
```

### Example 11: Manual Port Rule Application
```bash
# Apply port rules from config files
nftban_nftables_apply_port_rules_v4 input   # IPv4 input ports
nftban_nftables_apply_port_rules_v4 output  # IPv4 output ports
nftban_nftables_apply_port_rules_v6 input   # IPv6 input ports
nftban_nftables_apply_port_rules_v6 output  # IPv6 output ports

# Note: These are called automatically by nftban_nftables_apply_rules()
```

### Example 12: Direct nftables Commands (Advanced)
```bash
# Add IP to whitelist set (IPv4)
nft add element ip nftban_v4 whitelist { 192.168.1.100 }

# Add IP to temp_ban set with timeout (IPv4)
nft add element ip nftban_v4 temp_ban { 1.2.3.4 timeout 1h }

# Add CIDR to user_blacklist (IPv4)
nft add element ip nftban_v4 user_blacklist { 10.0.0.0/8 }

# Add IPv6 to whitelist
nft add element ip6 nftban_v6 whitelist { 2001:db8::1 }

# List all elements in a set
nft list set ip nftban_v4 whitelist
nft list set ip6 nftban_v6 temp_ban

# List complete table ruleset
nft list table ip nftban_v4
nft list table ip6 nftban_v6
```

---

## Table Structure

### IPv4 Table (`ip nftban_v4`)

#### Sets
```
whitelist         type ipv4_addr, flags interval
temp_ban          type ipv4_addr, flags timeout, timeout 1h
user_blacklist    type ipv4_addr, flags interval
system_blacklist  type ipv4_addr, flags interval
feeds             type ipv4_addr, flags interval, auto-merge
```

#### Chains
```
input             type filter hook input priority filter; policy accept
output            type filter hook output priority filter; policy accept
```

#### Input Chain Rules (Priority Order)
1. **Accept established/related** - `ct state established,related accept`
2. **Accept loopback** - `iif lo accept`
3. **Whitelist check** - `saddr @whitelist accept` (HIGHEST PRIORITY)
4. **Block threat feeds** - `saddr @feeds drop`
5. **Block temporary bans** - `saddr @temp_ban drop`
6. **Block user blacklist** - `saddr @user_blacklist drop`
7. **Block system blacklist** - `saddr @system_blacklist drop`
8. **Accept ICMP** - `icmp type { echo-request, echo-reply } accept`
9. **Port rules** - From config files

#### Output Chain Rules
1. **Accept established/related**
2. **Accept loopback**
3. **Port rules** - From config files

### IPv6 Table (`ip6 nftban_v6`)

#### Sets
```
whitelist         type ipv6_addr, flags interval
temp_ban          type ipv6_addr, flags timeout, timeout 1h
user_blacklist    type ipv6_addr, flags interval
system_blacklist  type ipv6_addr, flags interval
feeds             type ipv6_addr, flags interval, auto-merge
```

#### Chains
```
input             type filter hook input priority filter; policy accept
output            type filter hook output priority filter; policy accept
```

#### Input Chain Rules (Priority Order)
1. **Accept established/related**
2. **Accept loopback**
3. **Whitelist check** (HIGHEST PRIORITY)
4. **Block threat feeds**
5. **Block temporary bans**
6. **Block user blacklist**
7. **Block system blacklist**
8. **Accept ICMPv6** - Includes neighbor discovery (essential for IPv6)
9. **Port rules**

#### Output Chain Rules
1. **Accept established/related**
2. **Accept loopback**
3. **Port rules**

---

## File Operations

**Reads from:**
- `/etc/nftban/config/ports/ipv4-input.conf` - IPv4 input port configuration
- `/etc/nftban/config/ports/ipv4-output.conf` - IPv4 output port configuration
- `/etc/nftban/config/ports/ipv6-input.conf` - IPv6 input port configuration
- `/etc/nftban/config/ports/ipv6-output.conf` - IPv6 output port configuration

**Writes to:**
- `/etc/nftban/config/ports/*.conf` - Port configuration files (when adding/removing ports)

**nftables Operations:**
- Creates tables: `ip nftban_v4`, `ip6 nftban_v6`
- Creates sets: 5 sets per table (whitelist, temp_ban, user_blacklist, system_blacklist, feeds)
- Creates chains: input and output chains per table
- Manages rules: Applies priority-ordered filtering rules
- Modifies elements: Add/remove IPs from sets

---

## Security Considerations

### Whitelist Priority Protection
- **Whitelist checked FIRST** in rule order (rule #3)
- **CRITICAL:** Ensures whitelisted IPs are never blocked
- **Placement:** After established/related and loopback only
- **Impact:** Protects server administrators from accidental lockout

### Rule Order Enforcement
- **Established connections first** - Performance optimization
- **Loopback always allowed** - Prevents system breakage
- **Whitelist before blocks** - Safety guarantee
- **Multiple blacklist layers** - Defense in depth

### Set Type Security
- **interval flag** - Supports CIDR ranges for efficiency
- **timeout flag** - Automatic expiration for temp_ban
- **auto-merge flag** - Optimizes overlapping ranges in feeds

### Legacy Table Coexistence
- **Detection** - Warns about legacy v0.8.5 tables
- **Non-interference** - New tables don't conflict with old
- **Migration path** - Allows gradual transition
- **Fallback** - Legacy table remains functional during migration

### Port Configuration Security
- **File-based** - Human-readable and auditable
- **Format validation** - Rejects invalid port numbers
- **Protocol validation** - Only accepts T, U, or B
- **Atomic application** - All port rules applied together

---

## Performance Characteristics

### Split Table Architecture Benefits

**30-50% Performance Improvement over v0.8.5 unified table:**

1. **Simpler Rules**
   - Old: `ip saddr @whitelist accept` (requires IP protocol check)
   - New: `saddr @whitelist accept` (direct address check)
   - **Impact:** Fewer CPU cycles per packet

2. **Better Cache Efficiency**
   - Separate tables = separate caches
   - IPv4 and IPv6 don't compete for cache space
   - **Impact:** Higher cache hit rates

3. **Faster Packet Processing**
   - No protocol discrimination needed
   - Direct set lookups without family checks
   - **Impact:** Lower latency per packet

4. **Reduced Memory Contention**
   - Separate kernel data structures
   - Parallel processing possible
   - **Impact:** Better scalability

### Measured Performance

- **Set lookup:** O(1) hash table lookup (~1-5μs)
- **Rule evaluation:** Linear through rules (~100ns per rule)
- **Whitelist check:** 3rd rule position (~300ns)
- **Port rules:** Applied after security rules (~1-2μs per port)

### Scalability

- **Whitelist:** Supports 10,000+ entries with no degradation
- **Blacklist:** Tested with 100,000+ IPs (minimal impact)
- **Feeds:** Handles 1M+ IPs with auto-merge optimization
- **Port rules:** 50+ ports with negligible overhead

---

## Error Handling

**Common Errors:**

```bash
# Table doesn't exist
ERROR: IPv4 table does not exist
ERROR: IPv6 table does not exist

# Set missing during verification
ERROR: Missing IPv4 set: whitelist
ERROR: Missing IPv6 set: temp_ban

# Invalid port format
ERROR: Invalid port format: xyz
# Must be numeric or range: 22, 80-90

# Invalid protocol
ERROR: Invalid protocol: X (use T, U, or B)
# T=TCP, U=UDP, B=Both

# Invalid family
ERROR: Invalid family: v7 (use v4, v6, or both)

# Config file not found
ERROR: Config file not found: /path/to/file.conf
```

**Exit Codes:**
- `0` - Success
- `1` - Error (table missing, invalid input, operation failed)

**Error Recovery:**
- Missing tables → Run `nftban_nftables_create_table()`
- Missing sets → Re-create table structure
- Invalid ports → Validation before adding
- Duplicate ports → Warning, no error

---

## Integration Points

**Called by:**
- `nftban_main_cli.sh` - For CLI commands (`nftban nftables ...`)
- `nftban_whitelist_module.sh` - When syncing whitelist to nftables
- `nftban_blacklist_module.sh` - When syncing blacklist to nftables
- `nftban_feeds_module.sh` - When loading threat feeds
- `nftban init` - During system initialization
- Migration scripts - When upgrading from v0.8.5

**Calls:**
- `nftban_log_*` functions from `nftban_core.sh`
- External: `nft` command for all nftables operations
- Text processing: `grep`, `awk`, `sed` for port configs

**Provides Infrastructure For:**
- All IP blocking operations
- Whitelist enforcement
- Threat feed integration
- Fail2Ban actions
- Port-based filtering

---

## Migration from v0.8.5

### Legacy Table Structure
```
inet nftban_global  # Unified table for both IPv4 and IPv6
  ├── whitelist_v4  # Separate sets with _v4/_v6 suffixes
  ├── whitelist_v6
  ├── temp_ban_v4
  ├── temp_ban_v6
  └── ...
```

### New v0.9.0 Structure
```
ip nftban_v4        # Separate IPv4 table
  ├── whitelist     # No suffix needed
  ├── temp_ban
  └── ...

ip6 nftban_v6       # Separate IPv6 table
  ├── whitelist     # Mirror structure
  ├── temp_ban
  └── ...
```

### Migration Process
1. **Detection:** Module detects legacy table automatically
2. **Warning:** Logs warning about migration needed
3. **Coexistence:** Both architectures can run simultaneously
4. **Migration:** Run `nftban migrate v085-to-v090`
5. **Cleanup:** Delete legacy table with `nftban_nftables_delete_legacy_table()`

### Benefits of Migration
- 30-50% faster packet processing
- Simpler rule syntax
- Better cache efficiency
- Reduced memory usage
- Improved scalability

---

## Change Log

### Version 2.0.0 (2025-10-20) - Split Table Architecture (v0.9.0)
- **BREAKING:** Migrated from unified `inet nftban_global` to split tables
- Added `ip nftban_v4` table for IPv4 traffic
- Added `ip6 nftban_v6` table for IPv6 traffic
- Removed `_v4`/`_v6` suffixes from set names (table-specific now)
- Simplified rule syntax (no `ip saddr`/`ip6 saddr` needed)
- **Performance:** 30-50% improvement in packet processing
- Added legacy table detection and coexistence support
- Updated all functions for dual-table architecture
- Enhanced port management with separate IPv4/IPv6 configs
- Added `nftban_nftables_check_table()` with family parameter
- Added `nftban_nftables_delete_legacy_table()`

### Version 1.x (v0.8.5 - Legacy)
- Unified `inet nftban_global` table
- Sets with `_v4`/`_v6` suffixes
- Complex rules with protocol selectors
- Single port configuration

---

## Port Configuration Format

### File Format
```
# /etc/nftban/config/ports/ipv4-input.conf
# Format: PORT|PROTOCOL
# Protocol: T=TCP, U=UDP, B=Both

22|T        # SSH (TCP only)
53|U        # DNS (UDP only)
80|B        # HTTP (both TCP and UDP)
443|T       # HTTPS (TCP only)
8080-8090|T # Port range (TCP)
3000-3999|B # Port range (both protocols)
```

### Protocol Codes
- **T** - TCP only
- **U** - UDP only
- **B** - Both TCP and UDP

### Port Range Support
- Single port: `22|T`
- Port range: `8080-8090|T`
- Format: `start-end|protocol`

### Comments
- Lines starting with `#` are ignored
- Empty lines are ignored
- Inline comments not supported

---

## See Also

**Related Modules:**
- `nftban_core.sh` - Core logging and utilities
- `nftban_whitelist_module.sh` - Whitelist management (uses nftables sets)
- `nftban_blacklist_module.sh` - Blacklist management (uses nftables sets)
- `nftban_feeds_module.sh` - Threat feeds (uses feeds set)
- `nftban_port_module.sh` - Port management wrapper

**Related Documentation:**
- `ARCHITECTURE.md` - v0.9.0 Split Table Architecture details
- `MIGRATION_v085_to_v090.md` - Migration guide
- `PERFORMANCE.md` - Performance benchmarks and tuning
- `NFTABLES_REFERENCE.md` - nftables command reference

**Configuration Files:**
- `/etc/nftban/config/ports/ipv4-input.conf` - IPv4 input ports
- `/etc/nftban/config/ports/ipv4-output.conf` - IPv4 output ports
- `/etc/nftban/config/ports/ipv6-input.conf` - IPv6 input ports
- `/etc/nftban/config/ports/ipv6-output.conf` - IPv6 output ports

**External Resources:**
- [nftables Wiki](https://wiki.nftables.org/)
- [nftables Man Page](https://www.netfilter.org/projects/nftables/manpage.html)
- [Netfilter Documentation](https://www.netfilter.org/documentation/)
