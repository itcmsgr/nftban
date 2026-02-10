# CLI Reference

NFTBan command-line interface overview.

---

## Table of Contents
- [Basic Usage](#basic-usage)
- [Status Commands](#status-commands)
- [Ban Management](#ban-management)
- [Detection Modules](#detection-modules)
- [Configuration](#configuration)
- [Maintenance](#maintenance)

---

## Basic Usage

```bash
nftban <command> [subcommand] [options]
nftban help
nftban <command> help
```

---

## Status Commands

### System Status
```bash
nftban status              # Overall system status
nftban status summary      # Brief summary
```

### Health Check
```bash
nftban health check        # Run health diagnostics
nftban health check --auto-heal   # Fix issues automatically
nftban health summary      # Quick health overview
```

### Version
```bash
nftban version
```

---

## Ban Management

### Ban/Unban IPs
```bash
nftban ban <IP> [--duration SECONDS] [--reason TEXT]
nftban unban <IP>
```

### Check IP Status
```bash
nftban check <IP>          # Check if IP is banned/whitelisted
```

### List Bans
```bash
nftban list                # List all bans
nftban list --type permanent
nftban list --type temporary
```

### Search
```bash
nftban search <IP|CIDR>    # Search across all lists
```

---

## Detection Modules

### DDoS Protection
```bash
nftban ddos status
nftban ddos enable
nftban ddos disable
```

### Port Scan Detection
```bash
nftban portscan status
nftban portscan enable
nftban portscan disable
```

### Login Monitoring
```bash
nftban login status
nftban login enable
nftban login disable
```

### Threat Feeds
```bash
nftban feeds status
nftban feeds enable
nftban feeds update        # Update feed data
nftban feeds list          # List configured feeds
```

---

## Geographic Blocking

### Country Management
```bash
nftban country block <CC>   # Block country (ISO code)
nftban country allow <CC>   # Allow country
nftban country list         # List blocked countries
```

### GeoIP Lookup
```bash
nftban geoip lookup <IP>   # Lookup IP country
nftban geoip update        # Update GeoIP database
```

---

## Whitelist/Blacklist

### Whitelist
```bash
nftban whitelist add <IP> [--comment TEXT]
nftban whitelist remove <IP>
nftban whitelist list
nftban whitelist sync      # Sync to nftables
```

### System Whitelist
```bash
nftban whitelist-system sync   # Sync server IPs
```

---

## Configuration

### View/Edit Config
```bash
nftban config show
nftban config get <KEY>
nftban config set <KEY> <VALUE>
```

### Audit/Test
```bash
nftban configaudit         # Audit configuration
nftban configtest          # Test configuration validity
```

---

## Maintenance

### Update
```bash
nftban update              # Check and apply updates
nftban update check        # Check only
nftban update auto enable --email admin@example.com
nftban update auto status
```

### Timers
```bash
nftban timers status       # Show timer status
nftban timers enable       # Enable maintenance timers
nftban timers disable
```

### Cleanup
```bash
nftban cleanup             # Remove expired bans
```

### Debug
```bash
nftban debug               # Debug information
nftban smoke               # Run smoke tests
```

---

## nftables

```bash
nftban nftables status     # nftables status
nftban nftables verify     # Verify structure
nftban nftables flush      # Flush rules (careful)
```

---

## References

- Full help: `nftban help`
- Command help: `nftban <command> help`
- Config: `/etc/nftban/`
