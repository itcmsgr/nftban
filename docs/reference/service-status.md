# NFTBan v0.10.0 - Service Status Reference Guide

> **Purpose:** Complete reference for checking service status in NFTBan
> **Last Updated:** 2025-10-30
> **Scope:** fail2ban, nftables, and all NFTBan services

---

## 🎯 Quick Reference

### Check All Services Status

```bash
# ⭐ NEW: Unified services status (like fhs and module)
nftban services                     # Show all services in FHS-style report

# Alternative: Individual service commands
nftban fail2ban status              # fail2ban only
nftban nftables status              # nftables only

# NFTBan infrastructure
nftban check                        # Environment check
nftban module                       # Module inventory
nftban fhs                          # FHS compliance
```

---

## 🆕 Unified Services Status (NEW in v0.10.0)

### Command: `nftban services`

**⭐ NEW MODULE** - FHS-style unified services report

**Location:** `/usr/lib/nftban/cli/cmd_services.sh`
**Core Module:** `/usr/lib/nftban/core/nftban_report_services.sh`

### Available Commands

```bash
# Status Display
nftban services                     # Show all services (default, FHS-style table)
nftban services status              # Same as above
nftban services list                # Alias for status
nftban services compact             # One-line compact status

# Service Management
nftban services fix                 # Auto-start stopped services
nftban services check               # Health check (returns exit code)
nftban services help                # Show help message
```

### Services Monitored

| Service | Type | Required | Purpose |
|---------|------|----------|---------|
| **nftables** | systemd | ✅ Required | Netfilter firewall |
| **fail2ban** | systemd | ✅ Required | Intrusion prevention |
| **golang** | binary | ⚠️ Optional | GeoIP features |
| **mailx** | binary | ⚠️ Optional | Email notifications |
| **curl** | binary | ✅ Required | Feed downloads |
| **jq** | binary | ⚠️ Optional | JSON processing |

### Example Output

```
════════════════════════════════════════════════════════════════════════════════════
 Services Status Report — 2025-10-30T05:11:42+00:00
════════════════════════════════════════════════════════════════════════════════════
SERVICE              STATUS          VERSION      REQUIRED   NOTES
------------------------------------------------------------------------------------
fail2ban             ✔ RUNNING       v1.1.0       required   Intrusion prevention framework
nftables             ✔ RUNNING       v1.0.9       required   Netfilter tables firewall
jq                   ✔ INSTALLED     1.6          optional   JSON processing
curl                 ✔ INSTALLED     7.76.1       required   Feed downloads and API calls
golang               ✔ INSTALLED     1.25.1       optional   GeoIP and advanced features
mailx                ✔ INSTALLED     v14.9.22     optional   Email notifications

Systemd Services: 2 total | 2 running | 0 stopped | 0 missing
Binary Tools: 4 total | 4 installed | 0 missing

✅ All services operational!
```

### Use Cases

```bash
# Daily health check
nftban services && echo "All OK"

# Script integration (exit code based)
if nftban services check; then
    echo "Services healthy"
else
    echo "Issues detected!"
    nftban services fix
fi

# Quick status for monitoring
nftban services compact
# Output: Services: 2/2 running
```

---

## 📊 fail2ban Service Management

### Command: `nftban fail2ban`

**Location:** `/usr/lib/nftban/cli/cmd_fail2ban.sh`
**Core Module:** `/usr/lib/nftban/core/nftban_fail2ban.sh`

### Available Commands

```bash
# Status & Information
nftban fail2ban status              # Show fail2ban status and statistics
nftban fail2ban jails               # List all currently enabled jails
nftban fail2ban available           # Show all available jails on system
nftban fail2ban recommended         # Show recommended jails for your OS
nftban fail2ban jail <name>         # Detailed status for specific jail

# Management
nftban fail2ban enable <jail>       # Enable/start a fail2ban jail
nftban fail2ban disable <jail>      # Disable/stop a fail2ban jail
nftban fail2ban reload              # Reload fail2ban configuration

# Ban Management
nftban fail2ban banned              # List all banned IPs across all jails
nftban fail2ban ban <ip> <jail>     # Manually ban an IP in a jail
nftban fail2ban unban <ip> <jail>   # Unban an IP from a jail

# Integration
nftban fail2ban cloudflare          # Sync fail2ban bans to Cloudflare

# Service Control
nftban fail2ban start               # Start fail2ban service
nftban fail2ban stop                # Stop fail2ban service
nftban fail2ban restart             # Restart fail2ban service
```

### Example Output

```
════════════════════════════════════════════════════════════
  Fail2ban Integration Status
════════════════════════════════════════════════════════════

Service Status: RUNNING
Version:        1.1.0
Detected OS:    centos:9

Active Jails:   2
Total Banned:   2 IPs

Configured Jails:
─────────────────────────────────────────────────────────
  nftban-sshd             1 banned
  sshd                    1 banned
```

---

## 🔥 nftables Service Management

### Command: `nftban nftables`

**Location:** `/usr/lib/nftban/cli/cmd_nftables.sh`

### Available Commands

```bash
# Service Control
nftban nftables start               # Start nftables service
nftban nftables stop                # Stop nftables service
nftban nftables restart             # Restart nftables service
nftban nftables reload              # Reload nftables ruleset
nftban nftables status              # Show nftables service status

# Boot Configuration
nftban nftables enable              # Enable nftables at boot
nftban nftables disable             # Disable nftables at boot

# Ruleset Management
nftban nftables save                # Save current ruleset
nftban nftables restore             # Restore saved ruleset
nftban nftables flush               # Flush all rules (dangerous!)
```

### Example Output

```
NFTables Service Status:
════════════════════════════════════════════════════════════

● nftables.service - Netfilter Tables
     Loaded: loaded (/usr/lib/systemd/system/nftables.service; disabled; preset: disabled)
     Active: active (exited) since Wed 2025-10-29 21:48:10 UTC; 7h ago
       Docs: man:nft(8)
   Main PID: 992 (code=exited, status=0/SUCCESS)
        CPU: 28ms
```

---

## 🔍 NFTBan Infrastructure Status

### Command: `nftban check`

**Location:** `/usr/sbin/nftban` (built-in command)

Shows environment status including:
- System user existence
- Core module availability
- Directory structure
- FHS compliance quick check

### Example Output

```
NFTBan Environment Check:

✓ System user 'nftban' exists (uid=995)

FHS Directories:
  ✓ /etc/nftban (root:nftban, 750)
  ✓ /var/lib/nftban (nftban:nftban, 750)
  ✓ /var/log/nftban (nftban:adm, 750)

Core Modules:
  ✓ nftban_output.sh
```

---

## 📦 Module Inventory

### Command: `nftban module`

**Location:** `/usr/lib/nftban/cli/cmd_module.sh`
**Core Module:** `/usr/lib/nftban/core/nftban_report_module.sh`

Shows complete module inventory with:
- Module name, version, type
- Enable/disable status
- Creation date
- File path

### Example Output

```
════════════════════════════════════════════════════════════════════════
 Module Inventory Report — 2025-10-30T05:30:00+00:00
════════════════════════════════════════════════════════════════════════
NAME                      VERSION    TYPE     STATUS     CREATED      PATH
------------------------------------------------------------------------------------
cmd_fail2ban              0.10.0     cli      ✔ ENABLED 2025-10-28   /usr/lib/nftban/cli/cmd_fail2ban.sh
nftban_fail2ban           1.0.0      core     ✔ ENABLED 2025-10-28   /usr/lib/nftban/core/nftban_fail2ban.sh

Total modules: 23 | Enabled: 23 | Disabled: 0
```

---

## 📋 FHS Compliance Check

### Command: `nftban fhs`

**Location:** `/usr/lib/nftban/cli/cmd_fhs.sh`
**Core Module:** `/usr/lib/nftban/core/nftban_report_fhs.sh`

Validates Filesystem Hierarchy Standard compliance:
- Directory permissions
- Ownership
- Missing directories
- Permission mismatches

### Example Output

```
════════════════════════════════════════════════════════════════════════
 FHS Compliance Report — 2025-10-30T05:30:00+00:00
════════════════════════════════════════════════════════════════════════
DIRECTORY                   EXPECTED           ACTUAL             STATUS     NOTES
------------------------------------------------------------------------------------
/etc/nftban                 750 root:nftban    755 nftban:nftban  ✖ ERROR  Mismatch: perms,owner
/var/lib/nftban             755 nftban:nftban  750 nftban:nftban  ✖ ERROR  Mismatch: perms
/var/lib/nftban/exports     750 nftban:nftban  (not found)        ⚠ MISSING Directory does not exist

Total directories: 21 | OK: 5 | Errors: 12 | Missing: 4
```

---

## 🔧 Firewall Management

### Command: `nftban firewall`

**Location:** `/usr/lib/nftban/cli/cmd_firewall.sh`

```bash
nftban firewall init                # Initialize nftables firewall
nftban firewall reload              # Reload firewall rules
nftban firewall status              # Show firewall status
nftban firewall check               # Check firewall dependencies
nftban firewall reset               # Reset firewall to defaults (dangerous!)
```

---

## 📊 Statistics & Monitoring

### Command: `nftban stats`

**Location:** `/usr/lib/nftban/cli/cmd_stats.sh`
**Core Module:** `/usr/lib/nftban/core/nftban_stats.sh`

```bash
nftban stats dashboard              # Real-time statistics dashboard
nftban stats top                    # Top banned IPs
nftban stats ip <address>           # Statistics for specific IP
nftban stats recent                 # Recent ban activity
nftban stats monitor                # Live monitoring mode
nftban stats export                 # Export statistics data
```

---

## 🔐 Security Modules Status

### DDoS Protection

```bash
nftban ddos status                  # DDoS protection status
nftban ddos enable                  # Enable DDoS protection
nftban ddos disable                 # Disable DDoS protection
nftban ddos test                    # Test DDoS detection
```

### Port Scan Detection

```bash
nftban portscan status              # Port scan detection status
nftban portscan enable              # Enable port scan detection
nftban portscan disable             # Disable port scan detection
nftban portscan check               # Check for port scans
nftban portscan history             # Show scan history
```

### Security Profiles

```bash
nftban profile list                 # List available security profiles
nftban profile show                 # Show current active profile
nftban profile select               # Interactively select profile
nftban profile apply <name>         # Apply specific profile
```

---

## 🌐 Integration Status

### Cloudflare Integration

```bash
nftban cloudflare status            # Cloudflare integration status
nftban cloudflare enable            # Enable Cloudflare sync
nftban cloudflare disable           # Disable Cloudflare sync
nftban cloudflare update            # Update Cloudflare IP lists
nftban cloudflare download          # Download Cloudflare ranges
```

### Threat Feed Status

```bash
nftban feeds status                 # Show all feed statuses
nftban feeds list                   # List available feeds
nftban feeds select                 # Interactively select feeds
nftban feeds enable <feed>          # Enable specific feed
nftban feeds update                 # Update all enabled feeds
```

---

## 📞 System Health

### Command: `nftban health`

**Location:** `/usr/lib/nftban/cli/cmd_health.sh`
**Core Module:** `/usr/lib/nftban/core/nftban_health.sh`

```bash
nftban health check                 # Run complete health check
nftban health report                # Generate health report
nftban health fix                   # Auto-fix common issues
nftban health services              # Check all services
nftban health modules               # Validate all modules
nftban health binaries              # Check required binaries
nftban health permissions           # Verify permissions
```

---

## 🎯 Port Management

### Command: `nftban port`

**Location:** `/usr/lib/nftban/cli/cmd_port.sh`
**Core Module:** `/usr/lib/nftban/core/nftban_report_port.sh`

```bash
nftban port status                  # Show port status
nftban port list                    # List all open ports
nftban port scan                    # Scan for listening services
nftban port protect                 # Auto-protect detected ports
```

---

## 🔄 Quick Status Check Script

Create a comprehensive status check:

```bash
#!/usr/bin/env bash
# Quick NFTBan Status Check

echo "════════════════════════════════════════"
echo "  NFTBan v0.10.0 Status Overview"
echo "════════════════════════════════════════"
echo ""

echo "📊 Infrastructure:"
nftban check | grep -E "✓|✗|⚠"
echo ""

echo "🔥 nftables:"
nftban nftables status | grep -E "Active|Loaded"
echo ""

echo "🛡️  fail2ban:"
nftban fail2ban status | head -10
echo ""

echo "📦 Modules:"
nftban module | tail -2
echo ""

echo "📋 FHS Compliance:"
nftban fhs | tail -3
echo ""
```

---

## 🌐 Lab Server Status (Current)

### server1.example.com (CentOS 9)
- ✅ fail2ban: RUNNING (2 jails, 2 IPs banned)
- ✅ nftables: ACTIVE
- ✅ NFTBan: 39 modules installed
- ⚠️  FHS: 4+ issues

### server2.example.com (Ubuntu 24.04)
- ✅ fail2ban: RUNNING (2 jails, 22 IPs banned)
- ✅ nftables: ACTIVE
- ✅ NFTBan: 39 modules installed
- ⚠️  FHS: 4+ issues

### server3.example.com (CentOS 10)
- ✅ fail2ban: RUNNING (2 jails, 4 IPs banned)
- ✅ nftables: ACTIVE
- ✅ NFTBan: 39 modules installed
- ⚠️  FHS: 4+ issues

---

## 📚 Related Documentation

- `KNOWN_BUGS.md` - Bug registry and fixes
- `CODING_STANDARDS.md` - Development guidelines
- `DEPLOYMENT_GUIDE.md` - Deployment procedures
- `BUG_ANALYSIS_SUMMARY_2025-10-30.md` - Recent bug analysis

---

**Last Updated:** 2025-10-30
**Status:** ✅ All service status functions working correctly
**Tested On:** lab, lab1, lab2 (all passing)

**EOF**
