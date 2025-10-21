# NFTBan Port Management Module

**File:** `lib/nftban_port_module.sh`
**Version:** 1.0.0
**Author:** ITCMS Team (Antonios Voulvoulis)
**Purpose:** Advanced port configuration with validation and rule generation

---

## Overview

The Port Management Module provides comprehensive port configuration capabilities for NFTBan, supporting both IPv4 and IPv6 with separate INPUT/OUTPUT chain management. It allows administrators to define which ports should be accessible on the system through a simple configuration format.

The module handles port validation, configuration management, and automatic nftables rule generation. It supports single ports, port ranges, and multiple protocols (TCP, UDP, or both), with separate configuration files for IPv4/IPv6 and INPUT/OUTPUT directions.

This module is essential for firewall management, ensuring only authorized ports are accessible while maintaining security and flexibility.

---

## Key Functions

### Public Functions (Exported)

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `nftban_port_init()` | Initialize port configuration structure | None | 0 on success |
| `nftban_port_add()` | Add port to configuration | `$1` - port/range, `$2` - protocol (T/U/B), `$3` - direction (input/output), `$4` - IP version (4/6) | 0 on success, 1 on error |
| `nftban_port_remove()` | Remove port from configuration | `$1` - port/range, `$2` - protocol, `$3` - direction, `$4` - IP version | 0 on success, 1 on error |
| `nftban_port_list()` | Display configured ports | `$1` - filter (all/input/output/ipv4/ipv6) | 0 on success |
| `nftban_port_validate_line()` | Validate port configuration line | `$1` - line (format: PORT\|PROTOCOL) | 0 if valid, 1 if invalid |
| `nftban_port_validate_all()` | Validate all port configurations | None | 0 if all valid, 1 if errors |
| `nftban_port_generate_rules()` | Generate nftables rules from config | `$1` - config file, `$2` - chain name | Outputs rules to stdout |
| `nftban_port_apply_to_nftables()` | Apply port rules to nftables | `$1` - direction (input/output) | 0 on success, 1 on error |

### Internal Functions (Private)

| Function | Purpose | Notes |
|----------|---------|-------|
| `nftban_port_validate_single()` | Validate single port number | Ensures port is 1-65535 |
| `nftban_port_validate_range()` | Validate port range | Ensures start ≤ end |
| `nftban_port_validate_token()` | Validate port token (single/range) | Determines type and validates |
| `nftban_port_validate_protocol()` | Validate protocol code | Ensures T/U/B only |

---

## Configuration Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NFTBAN_PORT_CONFIG_DIR` | `${NFTBAN_CONFIG_DIR}/ports` | Port configuration directory |
| `NFTBAN_IPV4_INPUT_PORTS` | `${NFTBAN_PORT_CONFIG_DIR}/ipv4-input.conf` | IPv4 INPUT port config |
| `NFTBAN_IPV4_OUTPUT_PORTS` | `${NFTBAN_PORT_CONFIG_DIR}/ipv4-output.conf` | IPv4 OUTPUT port config |
| `NFTBAN_IPV6_INPUT_PORTS` | `${NFTBAN_PORT_CONFIG_DIR}/ipv6-input.conf` | IPv6 INPUT port config |
| `NFTBAN_IPV6_OUTPUT_PORTS` | `${NFTBAN_PORT_CONFIG_DIR}/ipv6-output.conf` | IPv6 OUTPUT port config |
| `NFTBAN_PORT_LOG` | `${NFTBAN_LOG_DIR}/port-management.log` | Port management log file |

### Protocol Codes

- **T** = TCP only
- **U** = UDP only
- **B** = Both TCP and UDP

---

## Dependencies

**Required Modules:**
- `nftban_core.sh` - Core logging and utilities
- `nftban_nftables_module.sh` - nftables table management

**External Commands:**
- `nft` - nftables command (required)
- `grep`, `sed` - Text processing

---

## Usage Examples

### Example 1: Initialize Port Configuration
```bash
# Create port configuration structure
nftban_port_init

# Expected output:
# [INFO] Initializing port configuration...
# [SUCCESS] Port configuration initialized

# Creates:
# /etc/nftban/config/ports/ipv4-input.conf (with default ports 22, 80, 443)
# /etc/nftban/config/ports/ipv4-output.conf
# /etc/nftban/config/ports/ipv6-input.conf
# /etc/nftban/config/ports/ipv6-output.conf
```

### Example 2: Add Single Port
```bash
# Add SSH port (TCP)
nftban_port_add "22" "T" "input" "4"

# Add DNS port (UDP)
nftban_port_add "53" "U" "input" "4"

# Add custom app (both TCP and UDP)
nftban_port_add "3000" "B" "input" "4"

# Expected output:
# [SUCCESS] Added port: 22|T to IPv4 input
# [SUCCESS] Added port: 53|U to IPv4 input
# [SUCCESS] Added port: 3000|B to IPv4 input
```

### Example 3: Add Port Range
```bash
# Add port range for web applications (TCP)
nftban_port_add "8080-8090" "T" "input" "4"

# Expected output:
# [SUCCESS] Added port: 8080-8090|T to IPv4 input

# In nftables, this generates:
# tcp dport 8080-8090 accept
```

### Example 4: List Configured Ports
```bash
# List all ports
nftban_port_list "all"

# Expected output:
# ═══════════════════════════════════════════════════════
#   Configured Ports
# ═══════════════════════════════════════════════════════
#
# IPv4 INPUT:
#   22                   TCP
#   53                   UDP
#   80                   TCP
#   443                  TCP
#   3000                 TCP+UDP
#   8080-8090            TCP
#
# IPv4 OUTPUT:
#   (none)
#
# IPv6 INPUT:
#   22                   TCP
#   80                   TCP
#   443                  TCP
# ...
```

### Example 5: List Filtered Ports
```bash
# List only INPUT ports
nftban_port_list "input"

# List only IPv4 ports
nftban_port_list "ipv4"

# List only OUTPUT ports
nftban_port_list "output"
```

### Example 6: Remove Port
```bash
# Remove specific port
nftban_port_remove "3000" "B" "input" "4"

# Expected output:
# [SUCCESS] Removed port: 3000|B from IPv4 input
```

### Example 7: Validate Configuration
```bash
# Validate all port configurations
nftban_port_validate_all

# Expected output:
# [INFO] Validating all port configurations...
#
# Validating: ipv4-input.conf
#   ✓ 22|T
#   ✓ 80|T
#   ✓ 443|T
#   ✓ 8080-8090|T
#   ✗ 99999|T (INVALID)
#
# Validating: ipv4-output.conf
#   (no entries)
#
# ═══════════════════════════════════════════════════════
# Validation Summary:
#   Total entries: 5
#   Valid: 4
#   Invalid: 1
# ═══════════════════════════════════════════════════════
# [WARNING] Found 1 invalid port configurations
```

### Example 8: Generate nftables Rules
```bash
# Generate rules for IPv4 INPUT
nftban_port_generate_rules "$NFTBAN_IPV4_INPUT_PORTS" "input"

# Expected output (to stdout):
#     tcp dport 22 accept
#     tcp dport 80 accept
#     tcp dport 443 accept
#     tcp dport 8080-8090 accept
#     udp dport 53 accept
```

### Example 9: Apply Rules to nftables
```bash
# Apply INPUT port rules to nftables
nftban_port_apply_to_nftables "input"

# Expected output:
# [INFO] Applying port rules to nftables (input)...
# [SUCCESS] Applied 6 port rules to input chain

# This adds rules to the running nftables configuration
```

---

## Configuration File Format

Port configuration files use a simple pipe-delimited format:

```
PORT|PROTOCOL
```

**Examples:**
```bash
# Single ports
22|T         # SSH (TCP)
53|U         # DNS (UDP)
80|T         # HTTP (TCP)
443|T        # HTTPS (TCP)
123|U        # NTP (UDP)

# Port ranges
8080-8090|T  # Web app range (TCP)
3000-3010|B  # App range (TCP+UDP)

# Both protocols
3000|B       # Custom app (TCP+UDP)

# Comments and blank lines are ignored
# Lines starting with # are comments
```

---

## File Operations

**Creates:**
- `/etc/nftban/config/ports/` - Port configuration directory
- `/etc/nftban/config/ports/ipv4-input.conf` - IPv4 INPUT ports
- `/etc/nftban/config/ports/ipv4-output.conf` - IPv4 OUTPUT ports
- `/etc/nftban/config/ports/ipv6-input.conf` - IPv6 INPUT ports
- `/etc/nftban/config/ports/ipv6-output.conf` - IPv6 OUTPUT ports

**Writes to:**
- `/var/log/nftban/port-management.log` - Port operation log

**Reads from:**
- All port configuration files above

**Permissions:**
- Config files: `644` (readable by all, writable by root)

---

## Security Considerations

### Input Validation

- **Port Numbers:** Strictly validated to be in range 1-65535
- **Port Ranges:** Start must be ≤ end, both must be valid ports
- **Protocol Codes:** Only T, U, or B accepted (case-sensitive)
- **Line Format:** Regex validation prevents malformed entries

### Privilege Requirements

- **Must run as root** to:
  - Write to `/etc/nftban/config/ports/`
  - Apply rules to nftables
  - Write to system logs

### Common Ports Security

**Default ports (SSH, HTTP, HTTPS) are added automatically on init:**
```bash
22|T         # SSH - Consider changing default port
80|T         # HTTP - Use only if needed
443|T        # HTTPS - Recommended for secure services
```

**Recommendations:**
- Remove unused ports from configuration
- Use non-standard ports for SSH (not 22)
- Enable only necessary services
- Use OUTPUT filtering for additional security

---

## Error Handling

**Common Errors:**

- `ERROR: Invalid port format: 99999` - Port number out of valid range (1-65535)
- `ERROR: Invalid protocol: X (use T, U, or B)` - Protocol must be T, U, or B
- `WARNING: Port already configured: 22|T` - Port already exists in config
- `ERROR: Port not found: 3000|B` - Attempted to remove non-existent port
- `ERROR: Config file not found: /path/to/file` - Configuration file missing
- `ERROR: nftables table not initialized` - Run `nftban init` first

**Validation Errors:**
```bash
# Invalid port number
65536|T  # ERROR: Port > 65535
0|T      # ERROR: Port < 1

# Invalid range
100-50|T  # ERROR: Start > end

# Invalid protocol
22|X      # ERROR: Unknown protocol

# Invalid format
22:T      # ERROR: Wrong delimiter (use |)
22 T      # ERROR: Space instead of |
```

---

## Integration Points

**Called by:**
- `nftban_main_cli.sh` - CLI commands for port management
- `nftban_nftables_module.sh` - During firewall initialization
- `nftban_template_module.sh` - When generating nftables templates

**Calls:**
- `nftban_log_*` functions from `nftban_core.sh`
- `nftban_check_nftables_table()` from `nftban_nftables_module.sh`
- External: `nft`, `grep`, `sed`

---

## Port Configuration Examples

### Web Server Configuration
```bash
# /etc/nftban/config/ports/ipv4-input.conf
22|T         # SSH
80|T         # HTTP
443|T        # HTTPS
```

### DNS Server Configuration
```bash
# /etc/nftban/config/ports/ipv4-input.conf
22|T         # SSH
53|B         # DNS (TCP+UDP)
```

### Application Server Configuration
```bash
# /etc/nftban/config/ports/ipv4-input.conf
22|T         # SSH
80|T         # HTTP
443|T        # HTTPS
3000-3010|T  # Application ports
5432|T       # PostgreSQL
6379|T       # Redis
```

### Development Environment
```bash
# /etc/nftban/config/ports/ipv4-input.conf
22|T         # SSH
80|T         # HTTP
443|T        # HTTPS
3000-4000|T  # Dev servers
5000-6000|T  # Test services
8080-8090|T  # Web apps
```

---

## Best Practices

### Port Management

1. **Minimal Exposure:** Only open ports that are actively used
2. **Regular Audits:** Periodically review `nftban_port_list` output
3. **Documentation:** Comment why each port is open in config files
4. **Testing:** Use `nftban_port_validate_all` before applying changes
5. **Logging:** Monitor `/var/log/nftban/port-management.log` for changes

### Security Hardening

```bash
# 1. Change default SSH port
nftban_port_remove "22" "T" "input" "4"
nftban_port_add "2222" "T" "input" "4"

# 2. Disable HTTP if not needed
nftban_port_remove "80" "T" "input" "4"

# 3. Use OUTPUT filtering (whitelist approach)
nftban_port_add "80" "T" "output" "4"   # HTTP client
nftban_port_add "443" "T" "output" "4"  # HTTPS client
nftban_port_add "53" "U" "output" "4"   # DNS client
```

### IPv6 Configuration

Always configure IPv6 ports separately:
```bash
# IPv4
nftban_port_add "22" "T" "input" "4"
nftban_port_add "80" "T" "input" "4"
nftban_port_add "443" "T" "input" "4"

# IPv6 (same ports)
nftban_port_add "22" "T" "input" "6"
nftban_port_add "80" "T" "input" "6"
nftban_port_add "443" "T" "input" "6"
```

---

## Workflow Integration

### Initial Setup
```bash
# 1. Initialize port configuration
nftban_port_init

# 2. Review default ports
nftban_port_list

# 3. Add custom ports
nftban_port_add "3000" "T" "input" "4"

# 4. Validate configuration
nftban_port_validate_all

# 5. Apply to nftables
nftban_port_apply_to_nftables "input"
```

### Adding a New Service
```bash
# 1. Add port
nftban_port_add "8080" "T" "input" "4"

# 2. Verify addition
nftban_port_list "input"

# 3. Apply changes
nftban_port_apply_to_nftables "input"

# 4. Test connectivity
curl http://localhost:8080
```

### Removing a Service
```bash
# 1. Remove port
nftban_port_remove "8080" "T" "input" "4"

# 2. Apply changes immediately
nftban_port_apply_to_nftables "input"

# 3. Verify removal
nftban_port_list "input"
```

---

## Performance

- **Validation:** O(1) per port entry
- **File Operations:** O(n) where n = number of configured ports
- **Rule Generation:** O(n) linear with port count
- **nftables Application:** O(n) per rule addition

**Tested with:**
- 100+ ports configured: No performance impact
- Port ranges: Efficient handling of large ranges
- Concurrent validation: Safe for parallel operations

---

## Change Log

### Version 1.0.0 (2025-10-20)
- Initial release
- Support for IPv4/IPv6 separate configurations
- INPUT/OUTPUT chain separation
- Single port and port range support
- TCP, UDP, and combined protocol support
- Validation and error handling
- nftables rule generation
- Comprehensive logging

---

## See Also

**Related Modules:**
- `nftban_nftables_module.sh` - nftables management
- `nftban_template_module.sh` - Firewall template generation
- `nftban_core.sh` - Core utilities

**Related Documentation:**
- `nftables.md` - nftables syntax reference
- `SECURITY_BEST_PRACTICES.md` - Port security guidelines
- `DEPLOYMENT_GUIDE.md` - Production deployment

**Configuration Files:**
- `/etc/nftban/config/ports/ipv4-input.conf`
- `/etc/nftban/config/ports/ipv4-output.conf`
- `/etc/nftban/config/ports/ipv6-input.conf`
- `/etc/nftban/config/ports/ipv6-output.conf`
