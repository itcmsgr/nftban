# NFTBan Port Management Module

**File:** `lib/nftban_port_module.sh`  
**Version:** 1.0.0  
**Author:** ITCMS Team (Antonios Voulvoulis)  
**Purpose:** Advanced port configuration with validation and nftables rule generation

---

## Overview

The Port Management Module provides comprehensive port configuration management for NFTBan firewall rules. It handles port definitions for both IPv4 and IPv6 across input and output directions, validates port configurations, and generates nftables rules automatically.

This module uses a simple but powerful configuration format (`PORT|PROTOCOL`) that supports single ports, port ranges, and multiple protocols (TCP, UDP, or both). All configurations are validated before application to prevent firewall misconfigurations.

Key features include separate configuration files for IPv4/IPv6 and input/output, support for TCP, UDP, and dual-protocol ports, port range support (e.g., 8000-9000), comprehensive validation (format, range, protocol), automatic nftables rule generation, and safe add/remove operations with duplicate detection.

---

## Key Functions

### Public Functions (Exported)

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `nftban_port_init()` | Initialize port configuration | None | 0 on success |
| `nftban_port_add()` | Add port to configuration | `$1` - port<br>`$2` - protocol (T/U/B)<br>`$3` - direction (input/output)<br>`$4` - IP version (4/6) | 0 on success, 1 on error |
| `nftban_port_remove()` | Remove port from configuration | `$1` - port<br>`$2` - protocol<br>`$3` - direction<br>`$4` - IP version | 0 on success, 1 on error |
| `nftban_port_list()` | List configured ports | `$1` - filter (all/input/output/ipv4/ipv6) | Display formatted list |
| `nftban_port_validate_line()` | Validate configuration line | `$1` - line (PORT\|PROTOCOL) | 0 if valid, 1 if invalid |
| `nftban_port_validate_all()` | Validate all configurations | None | 0 if all valid, 1 if errors |
| `nftban_port_generate_rules()` | Generate nftables rules | `$1` - config file<br>`$2` - chain (input/output) | Output rules to stdout |
| `nftban_port_apply_to_nftables()` | Apply rules to nftables | `$1` - direction (input/output) | 0 on success |

### Internal Validation Functions (Private)

| Function | Purpose | Notes |
|----------|---------|-------|
| `nftban_port_validate_single()` | Validate single port (1-65535) | Range check |
| `nftban_port_validate_range()` | Validate port range (e.g., 80-443) | Start ≤ end validation |
| `nftban_port_validate_token()` | Validate port or range | Dispatches to single/range |
| `nftban_port_validate_protocol()` | Validate protocol code (T/U/B) | T=TCP, U=UDP, B=Both |

---

## Configuration Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NFTBAN_PORT_CONFIG_DIR` | `${NFTBAN_CONFIG_DIR}/ports` | Port configurations directory |
| `NFTBAN_IPV4_INPUT_PORTS` | `${NFTBAN_PORT_CONFIG_DIR}/ipv4-input.conf` | IPv4 input ports |
| `NFTBAN_IPV4_OUTPUT_PORTS` | `${NFTBAN_PORT_CONFIG_DIR}/ipv4-output.conf` | IPv4 output ports |
| `NFTBAN_IPV6_INPUT_PORTS` | `${NFTBAN_PORT_CONFIG_DIR}/ipv6-input.conf` | IPv6 input ports |
| `NFTBAN_IPV6_OUTPUT_PORTS` | `${NFTBAN_PORT_CONFIG_DIR}/ipv6-output.conf` | IPv6 output ports |
| `NFTBAN_PORT_LOG` | `${NFTBAN_LOG_DIR}/port-management.log` | Port changes log |

---

## Configuration Format

### Port Configuration Syntax

**Format:** `PORT|PROTOCOL`

**Protocol Codes:**
- `T` = TCP only
- `U` = UDP only
- `B` = Both TCP and UDP

**Port Formats:**
- Single port: `22` (port 22)
- Port range: `8000-9000` (ports 8000 through 9000)

### Examples

```bash
# Single ports
22|T         # SSH (TCP only)
53|U         # DNS (UDP only)
80|T         # HTTP (TCP only)
443|T        # HTTPS (TCP only)
3000|B       # Custom app (TCP + UDP)

# Port ranges
8080-8090|T  # Application servers (TCP)
60000-61000|U # Dynamic ports (UDP)
3000-4000|B  # Range for both protocols

# Comments
# This is a comment
80|T         # Inline comment
```

---

## Dependencies

**Required:**
- `nftban_core.sh` - Core logging and utilities
- `nftban_nftables_module.sh` - nftables operations
- `nft` - nftables command (required)

**External Commands:**
- `grep` - Pattern matching (required)
- `sed` - File editing (required)

---

## Usage Examples

### Example 1: Initialize Port Configuration
```bash
nftban port init

# Expected output:
# [INFO] Initializing port configuration...
# [DEBUG] Created port config: ipv4-input.conf
# [DEBUG] Created port config: ipv4-output.conf
# [DEBUG] Created port config: ipv6-input.conf
# [DEBUG] Created port config: ipv6-output.conf
# [SUCCESS] Port configuration initialized

# Check created files
ls -l /etc/nftban/config/ports/
# ipv4-input.conf
# ipv4-output.conf
# ipv6-input.conf
# ipv6-output.conf
```

### Example 2: Add Ports (Single)
```bash
# Add SSH (TCP, IPv4, input)
nftban port add 22 T input 4

# Expected output:
# [SUCCESS] Added port: 22|T to IPv4 input

# Add DNS (UDP, IPv4, output)
nftban port add 53 U output 4

# Add custom app (TCP+UDP, IPv4, input)
nftban port add 3000 B input 4

# Add HTTPS (TCP, IPv6, input)
nftban port add 443 T input 6
```

### Example 3: Add Port Ranges
```bash
# Add web application port range (8000-9000, TCP, IPv4, input)
nftban port add 8000-9000 T input 4

# Expected output:
# [SUCCESS] Added port: 8000-9000|T to IPv4 input

# Add dynamic port range (60000-61000, UDP, IPv4, output)
nftban port add 60000-61000 U output 4
```

### Example 4: List Configured Ports
```bash
# List all ports
nftban port list

# Expected output:
# ═══════════════════════════════════════════════════════
#   Configured Ports
# ═══════════════════════════════════════════════════════
#
# IPv4 INPUT:
#   22                   TCP
#   80                   TCP
#   443                  TCP
#   3000                 TCP+UDP
#   8000-9000            TCP
#
# IPv4 OUTPUT:
#   53                   UDP
#   60000-61000          UDP
#
# IPv6 INPUT:
#   22                   TCP
#   443                  TCP
#
# IPv6 OUTPUT:
#   (none)
#
# ═══════════════════════════════════════════════════════

# List only input ports
nftban port list input

# List only IPv4 ports
nftban port list ipv4

# List only output ports
nftban port list output
```

### Example 5: Remove Ports
```bash
# Remove SSH from IPv4 input
nftban port remove 22 T input 4

# Expected output:
# [SUCCESS] Removed port: 22|T from IPv4 input

# Remove port range
nftban port remove 8000-9000 T input 4

# Try to remove non-existent port
nftban port remove 9999 T input 4

# Expected output:
# [ERROR] Port not found: 9999|T
```

### Example 6: Validate Configuration
```bash
nftban port validate

# Expected output:
# [INFO] Validating all port configurations...
#
# Validating: ipv4-input.conf
#   ✓ 22|T
#   ✓ 80|T
#   ✓ 443|T
#   ✓ 8000-9000|T
#   ✗ 99999|T (INVALID)  # Port out of range
#   ✗ 22|X (INVALID)     # Invalid protocol
#
# Validating: ipv4-output.conf
#   ✓ 53|U
#
# Validating: ipv6-input.conf
#   ✓ 443|T
#
# Validating: ipv6-output.conf
#   (no entries)
#
# ═══════════════════════════════════════════════════════
# Validation Summary:
#   Total entries: 7
#   Valid: 5
#   Invalid: 2
# ═══════════════════════════════════════════════════════
# [WARNING] Found 2 invalid port configurations
```

### Example 7: Apply to nftables
```bash
# Apply input port rules to nftables
nftban port apply input

# Expected output:
# [INFO] Applying port rules to nftables (input)...
# [SUCCESS] Applied 8 port rules to input chain

# Apply output port rules
nftban port apply output

# Verify in nftables
nft list chain inet nftban input | grep "dport"
```

### Example 8: Manual Configuration
```bash
# Edit configuration file directly
sudo nano /etc/nftban/config/ports/ipv4-input.conf

# Add entries:
22|T         # SSH
80|T         # HTTP
443|T        # HTTPS
8080|T       # Alt HTTP
3306|T       # MySQL
5432|T       # PostgreSQL
6379|T       # Redis
27017|T      # MongoDB

# Validate after manual edit
nftban port validate

# Apply changes
nftban port apply input
```

---

## Configuration Files

### IPv4 Input Ports

**File:** `/etc/nftban/config/ports/ipv4-input.conf`

**Example Configuration:**
```bash
# =============================================================================
# nftban Port Configuration - IPv4 INPUT
# =============================================================================
# Format: PORT|PROTOCOL
# Protocol codes: T=TCP, U=UDP, B=Both
# =============================================================================

# SSH access
22|T         # SSH

# Web services
80|T         # HTTP
443|T        # HTTPS
8080|T       # Alt HTTP
8443|T       # Alt HTTPS

# Database servers
3306|T       # MySQL
5432|T       # PostgreSQL
27017|T      # MongoDB

# Application servers
3000|T       # Node.js
8000-9000|T  # App server range

# Monitoring
9090|T       # Prometheus
3000|T       # Grafana

# Custom services
5000|B       # Custom app (TCP+UDP)
```

---

### IPv4 Output Ports

**File:** `/etc/nftban/config/ports/ipv4-output.conf`

**Example Configuration:**
```bash
# =============================================================================
# nftban Port Configuration - IPv4 OUTPUT
# =============================================================================

# DNS queries
53|U         # DNS

# Time synchronization
123|U        # NTP

# Web/HTTPS outbound
80|T         # HTTP
443|T        # HTTPS

# Email
25|T         # SMTP
587|T        # SMTP submission
993|T        # IMAPS
995|T        # POP3S

# Package updates
80|T         # HTTP (apt, yum)
443|T        # HTTPS (apt, yum)
```

---

### IPv6 Input Ports

**File:** `/etc/nftban/config/ports/ipv6-input.conf`

**Example Configuration:**
```bash
# =============================================================================
# nftban Port Configuration - IPv6 INPUT
# =============================================================================

# Mirror IPv4 services or IPv6-specific

# SSH
22|T         # SSH

# Web services
80|T         # HTTP
443|T        # HTTPS

# Custom IPv6 services
8080|T       # Alt HTTP
```

---

### IPv6 Output Ports

**File:** `/etc/nftban/config/ports/ipv6-output.conf`

**Example Configuration:**
```bash
# =============================================================================
# nftban Port Configuration - IPv6 OUTPUT
# =============================================================================

# DNS
53|U         # DNS

# NTP
123|U        # NTP

# Web/HTTPS
80|T         # HTTP
443|T        # HTTPS
```

---

## Validation Rules

### Port Number Validation

**Valid Ranges:** 1-65535

**Valid Formats:**
- Single port: `22`, `80`, `443`, `3000`
- Port range: `8000-9000`, `60000-61000`

**Invalid:**
- Port 0: `0|T` ❌
- Port > 65535: `99999|T` ❌
- Negative: `-22|T` ❌
- Invalid range: `9000-8000|T` ❌ (start > end)
- Non-numeric: `http|T` ❌
- Spaces: `22 - 80|T` ❌

---

### Protocol Code Validation

**Valid Codes:**
- `T` - TCP only
- `U` - UDP only
- `B` - Both TCP and UDP

**Invalid:**
- `X`, `Y`, `Z` ❌
- `tcp`, `udp` ❌ (must be uppercase)
- `TCP`, `UDP` ❌ (must be single letter)
- Empty: `22|` ❌

---

### Line Format Validation

**Valid:**
```bash
22|T         ✓
80-443|T     ✓
53|U         ✓
3000|B       ✓
8000-9000|T  ✓
```

**Invalid:**
```bash
22 T         ❌ (missing |)
22|T|extra   ❌ (too many fields)
|T           ❌ (missing port)
22|          ❌ (missing protocol)
-22|T        ❌ (invalid port)
22-|T        ❌ (incomplete range)
22--80|T     ❌ (double dash)
22:80|T      ❌ (wrong separator)
```

---

## nftables Rule Generation

### Single Port Rules

**Configuration:**
```bash
22|T         # SSH (TCP)
53|U         # DNS (UDP)
3000|B       # Custom (Both)
```

**Generated nftables Rules:**
```bash
# From 22|T
tcp dport 22 accept

# From 53|U
udp dport 53 accept

# From 3000|B
tcp dport 3000 accept
udp dport 3000 accept
```

---

### Port Range Rules

**Configuration:**
```bash
8000-9000|T  # App servers (TCP)
60000-61000|U # Dynamic (UDP)
3000-4000|B  # Range (Both)
```

**Generated nftables Rules:**
```bash
# From 8000-9000|T
tcp dport 8000-9000 accept

# From 60000-61000|U
udp dport 60000-61000 accept

# From 3000-4000|B
tcp dport 3000-4000 accept
udp dport 3000-4000 accept
```

---

### Complete Example

**IPv4 Input Configuration:**
```bash
22|T
80|T
443|T
8000-9000|T
3000|B
```

**Generated nftables Input Chain:**
```nftables
chain input {
    type filter hook input priority 0; policy drop;
    
    # ... (other rules)
    
    # Port rules
    tcp dport 22 accept
    tcp dport 80 accept
    tcp dport 443 accept
    tcp dport 8000-9000 accept
    tcp dport 3000 accept
    udp dport 3000 accept
    
    # ... (other rules)
}
```

---

## File Operations

### Reads from:
- `${NFTBAN_PORT_CONFIG_DIR}/ipv4-input.conf` - IPv4 input ports
- `${NFTBAN_PORT_CONFIG_DIR}/ipv4-output.conf` - IPv4 output ports
- `${NFTBAN_PORT_CONFIG_DIR}/ipv6-input.conf` - IPv6 input ports
- `${NFTBAN_PORT_CONFIG_DIR}/ipv6-output.conf` - IPv6 output ports

### Writes to:
- Same config files (when adding/removing ports)
- `${NFTBAN_LOG_DIR}/port-management.log` - Activity log

### Log Format:
```
[2025-10-20 14:32:15] ADD: 22|T -> ipv4-input.conf
[2025-10-20 14:35:42] ADD: 80|T -> ipv4-input.conf
[2025-10-20 14:40:10] REMOVE: 8080|T <- ipv4-input.conf
[2025-10-20 14:42:30] ADD: 8000-9000|T -> ipv4-input.conf
```

---

## Integration Points

**Called by:**
- `nftban_main_cli.sh` - For `nftban port` commands
- `nftban setup` - During initial configuration
- System administrators - Manual configuration

**Calls:**
- `nftban_log_*()` from `nftban_core.sh` - Logging
- `nftban_check_nftables_table()` from `nftban_nftables_module.sh` - Table verification
- `nft` - Apply rules to nftables

**Integrates with:**
- nftables - Generated rules applied to firewall
- NFTBan setup - Initial configuration
- NFTBan validation - Configuration checks

---

## Common Port Presets

### Web Server
```bash
# HTTP/HTTPS
80|T
443|T
8080|T       # Alt HTTP
8443|T       # Alt HTTPS
```

### Database Server
```bash
# MySQL
3306|T

# PostgreSQL
5432|T

# MongoDB
27017|T

# Redis
6379|T

# Elasticsearch
9200|T
9300|T
```

### Application Server
```bash
# Node.js/Express
3000|T

# Rails/Puma
3000|T

# Django/Gunicorn
8000|T

# Flask
5000|T

# Custom range
8000-9000|T
```

### Mail Server
```bash
# SMTP
25|T
587|T        # Submission

# IMAP/POP3
143|T        # IMAP
993|T        # IMAPS
110|T        # POP3
995|T        # POP3S
```

### Monitoring
```bash
# Prometheus
9090|T

# Grafana
3000|T

# Netdata
19999|T

# Zabbix
10050|T
10051|T
```

---

## Troubleshooting

### Problem: Port Not Applied to nftables

**Diagnostic:**
```bash
# Check configuration file
cat /etc/nftban/config/ports/ipv4-input.conf

# Validate configuration
nftban port validate

# Check nftables
nft list chain inet nftban input
```

**Solution:**
```bash
# Re-apply rules
nftban port apply input

# Or rebuild entire firewall
nftban rebuild
```

---

### Problem: Invalid Port Configuration

**Error:** `[WARNING] Invalid port line: 99999|T`

**Diagnostic:**
```bash
# Run validation
nftban port validate

# Check specific file
cat /etc/nftban/config/ports/ipv4-input.conf | grep 99999
```

**Solution:**
```bash
# Remove invalid entry
nftban port remove 99999 T input 4

# Or edit file manually
sudo nano /etc/nftban/config/ports/ipv4-input.conf
# Remove or fix the invalid line

# Validate again
nftban port validate
```

---

### Problem: Duplicate Port Entry

**Warning:** `[WARNING] Port already configured: 22|T`

**This is not an error** - the module prevents duplicates automatically.

**Solution:**
```bash
# If you want to change protocol, remove first
nftban port remove 22 T input 4
nftban port add 22 B input 4  # Change to both TCP+UDP
```

---

### Problem: Port Configuration Not Taking Effect

**Diagnostic:**
```bash
# Check if service listening
netstat -tulpn | grep :80

# Check nftables rules
nft list chain inet nftban input | grep 80

# Check port config
grep "80|" /etc/nftban/config/ports/ipv4-input.conf
```

**Solution:**
```bash
# Ensure port in config
nftban port list | grep 80

# Re-apply rules
nftban port apply input

# Verify
nft list chain inet nftban input | grep "dport 80"
```

---

## Best Practices

### ✅ DO:

1. **Use comments** in configuration files for documentation
2. **Validate after manual edits** (`nftban port validate`)
3. **Keep ports minimal** (only open what's needed)
4. **Use port ranges** for multiple consecutive ports
5. **Separate IPv4/IPv6** configurations as needed
6. **Document custom ports** with inline comments
7. **Review regularly** (monthly) for unused ports
8. **Test after changes** (verify service accessibility)
9. **Backup configs** before major changes
10. **Use both protocol** (B) only when truly needed

### ❌ DON'T:

1. **Don't open unnecessary ports** (security risk)
2. **Don't use invalid formats** (validate first)
3. **Don't forget to apply** after configuration changes
4. **Don't open wide ranges** unless required (e.g., 1-65535)
5. **Don't duplicate entries** (module prevents, but wasteful)
6. **Don't skip validation** (can break firewall)
7. **Don't edit during high traffic** (use maintenance window)
8. **Don't forget IPv6** if you use IPv6
9. **Don't use both protocol** for everything (specify T or U)
10. **Don't delete all SSH ports** (lockout risk!)

---

## Security Considerations

### Principle of Least Privilege
- Only open ports that are actively used
- Close unused ports immediately
- Review open ports regularly
- Document why each port is open

### Common Security Mistakes
```bash
# ❌ Opening too many ports
1-65535|B    # DON'T DO THIS!

# ❌ Opening all web ports
80|T
443|T
8000|T
8080|T
8443|T
8888|T       # Only if needed!

# ✅ Minimal configuration
22|T         # SSH (required)
80|T         # HTTP (required)
443|T        # HTTPS (required)
```

### Port Scanning Protection
- Minimize open ports (reduces attack surface)
- Use rate limiting (nftban_ratelimit_module)
- Monitor port scan attempts (login monitor)
- Use non-standard ports for services (security through obscurity - limited value)

---

## Change Log

### Version 1.0.0 (2025-10-20) - Initial Release
- Port configuration management (add/remove/list)
- Support for TCP, UDP, and both protocols
- Port range support
- Comprehensive validation (format, range, protocol)
- nftables rule generation
- Separate IPv4/IPv6 and input/output configurations
- Activity logging

---

## See Also

**Related Modules:**
- `nftban_nftables_module.sh` - nftables operations
- `nftban_template_module.sh` - Configuration templates
- `nftban_core.sh` - Core logging and utilities

**Related Documentation:**
- nftables Port Filtering Guide
- NFTBan Setup Guide
- Firewall Best Practices

**External Resources:**
- [IANA Port Numbers](https://www.iana.org/assignments/service-names-port-numbers/service-names-port-numbers.xhtml)
- [nftables Wiki](https://wiki.nftables.org/)
- [Common Ports List](https://en.wikipedia.org/wiki/List_of_TCP_and_UDP_port_numbers)

---

## Summary

The Port Management Module provides comprehensive port configuration with validation (format, range, protocol), support for TCP/UDP/Both protocols and port ranges, separate IPv4/IPv6 and input/output configs, automatic nftables rule generation, duplicate detection and safety checks, and activity logging. Essential for managing firewall port rules systematically and safely.