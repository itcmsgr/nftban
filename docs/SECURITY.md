# 🛡️ nftban Security Architecture

**How nftban Protects Your Server - Complete Guide with Diagrams**

This comprehensive guide explains how nftban's multi-layer security system works, with detailed diagrams and hardening techniques to maximize your server's security.

---

## 📋 Table of Contents

- [Architecture Overview](#architecture-overview)
- [Packet Flow Diagram](#packet-flow-diagram)
- [DDoS Protection](#ddos-protection)
- [Port Scan Detection](#port-scan-detection)
- [Fail2Ban Integration](#fail2ban-integration)
- [Security Layers](#security-layers)
- [Initial Security Setup](#initial-security-setup)
- [SSH Hardening](#ssh-hardening)
- [Firewall Hardening](#firewall-hardening)
- [Fail2Ban Optimization](#fail2ban-optimization)
- [Monitoring and Alerting](#monitoring-and-alerting)
- [Rate Limiting and DDoS Protection](#rate-limiting-and-ddos-protection)
- [Advanced Security Configurations](#advanced-security-configurations)
- [Regular Maintenance](#regular-maintenance)
- [Backup and Recovery](#backup-and-recovery)
- [Common Security Mistakes](#common-security-mistakes)
- [Emergency Procedures](#emergency-procedures)
- [Compliance and Auditing](#compliance-and-auditing)
- [Download Integrity Verification](#download-integrity-verification)

---

## Architecture Overview

### System Components

nftban consists of multiple integrated security layers working together:

```
┌─────────────────────────────────────────────────────────────┐
│                         nftban System                        │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Kernel Space (nftables)                  │  │
│  │  ┌────────────────────────────────────────────────┐  │  │
│  │  │  Packet Filter (inet nftban_global)            │  │  │
│  │  │  • Whitelist Sets (highest priority)           │  │  │
│  │  │  • Blacklist Sets (temp & permanent bans)      │  │  │
│  │  │  • DDoS Protection (SYN flood, rate limits)    │  │  │
│  │  │  • Port Scan Detection (nftables logging)      │  │  │
│  │  │  • Connection Limits (per-port)                │  │  │
│  │  └────────────────────────────────────────────────┘  │  │
│  └──────────────────────────────────────────────────────┘  │
│                           ↓                                 │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              User Space Modules                       │  │
│  │  ┌────────────────────────────────────────────────┐  │  │
│  │  │  Core Module (nftban_core.sh)                  │  │  │
│  │  │  • Configuration loading                       │  │  │
│  │  │  • Module management                           │  │  │
│  │  │  • Utility functions                           │  │  │
│  │  └────────────────────────────────────────────────┘  │  │
│  │                                                        │  │
│  │  ┌────────────────────────────────────────────────┐  │  │
│  │  │  Security Modules                              │  │  │
│  │  │  • Whitelist Module (whitelist management)     │  │  │
│  │  │  • Blacklist Module (ban management)           │  │  │
│  │  │  • DDoS Module (attack mitigation)             │  │  │
│  │  │  • Port Scan Module (scanner detection)        │  │  │
│  │  │  • Safety Module (lockout prevention)          │  │  │
│  │  └────────────────────────────────────────────────┘  │  │
│  └──────────────────────────────────────────────────────┘  │
│                           ↓                                 │
│  ┌──────────────────────────────────────────────────────┐  │
│  │            Fail2Ban Integration                       │  │
│  │  ┌────────────────────────────────────────────────┐  │  │
│  │  │  Fail2Ban Jails                                │  │  │
│  │  │  • SSH Jail (brute-force protection)           │  │  │
│  │  │  • SSH DDoS Jail (connection flood)            │  │  │
│  │  │  • Recidive Jail (repeat offenders)            │  │  │
│  │  │  • Service-specific Jails (HTTP, Mail, etc.)   │  │  │
│  │  └────────────────────────────────────────────────┘  │  │
│  │          ↓ (calls nftban on detection)                │  │
│  │  nftban --temp-ban <IP> "Fail2Ban: jail_name"         │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Data Flow Between Components

```
Log Files               Configuration Files
(/var/log/)            (/etc/nftban/config/)
    │                          │
    │                          ↓
    │                  ┌───────────────┐
    │                  │ Config Parser │
    │                  └───────┬───────┘
    │                          │
    ↓                          ↓
┌──────────┐           ┌──────────────┐
│ Fail2Ban │ ←────────→│ nftban Core  │
└────┬─────┘           └──────┬───────┘
     │                        │
     │ Ban action             │ Manage sets
     ↓                        ↓
┌─────────────────────────────────────┐
│      nftables Kernel Module         │
│  ┌───────────────────────────────┐  │
│  │  Sets (whitelist/blacklist)   │  │
│  │  Rules (accept/drop/reject)    │  │
│  │  Counters (statistics)         │  │
│  └───────────────────────────────┘  │
└─────────────────┬───────────────────┘
                  │
                  ↓ (packet filtering)
            Network Traffic
```

---

## 🆕 v0.9.0 Security Enhancements

nftban v0.9.0 introduces comprehensive security hardening based on systematic security audits and industry best practices.

### New Security Features

**1. Commit SHA Pinning**
- Updates validate commit SHAs before applying
- Prevents unauthorized code execution from compromised sources
- Fail-closed by default (rejects updates without valid SHA)
- Configurable pinning in `nftban.conf.local`

**2. HTTPS-Only Enforcement**
- All downloads require HTTPS (HTTP blocked)
- TLS 1.2+ minimum requirement
- Certificate validation enforced
- Private/local IP blocking in URLs
- GeoIP lookups upgraded to HTTPS

**3. Atomic File Operations with flock**
- Race condition (TOCTOU) protection
- Exclusive file locking on all critical operations
- Prevents concurrent modification conflicts
- Automatic lock cleanup on stale locks

**4. Input Sanitization Functions**
- `nftban_sanitize_jail_name()` - Path traversal prevention
- `nftban_sanitize_identifier()` - Strict alphanumeric validation
- `nftban_sanitize_path_component()` - Component-level safety
- `nftban_sanitize_port()` - Port range validation (1-65535)
- `nftban_sanitize_shell_arg()` - Shell metacharacter removal
- `nftban_validate_email()` - RFC 5322 compliance

**5. CIDR Validation with Dangerous Range Blocking**
- Blocks dangerous CIDR ranges automatically:
  - `0.0.0.0/0` (entire internet)
  - Private ranges (`10.0.0.0/8`, `192.168.0.0/16`)
  - Loopback, link-local, multicast, reserved
- Minimum prefix enforcement (/8 for IPv4, /32 for IPv6)
- Network address correction warnings

**6. Secure Temp File Management**
- `nftban_mktemp()` - Secure temp file creation
- `nftban_mktemp_dir()` - Secure temp directory creation
- Automatic cleanup traps
- Atomic write operations with `nftban_secure_atomic_write()`

**7. Single-Instance Locking**
- `nftban_with_lock()` - Prevents concurrent execution
- PID-based lock holders
- Stale lock detection
- Non-blocking lock acquisition

**8. Rate Limiting Protection**
- Configurable ban operation rate limits (default: 60/min)
- Email alerts on rate limit violations
- DDoS attack detection
- Automatic throttling

**9. Whitelist Protection Logging**
- All whitelist protection events logged
- Audit trail for banned IP attempts
- Source tracking (Fail2Ban jail, CLI, module)
- Detailed context logging

**10. Configuration Security**
- Sensitive value redaction in logs (passwords, tokens, API keys)
- Secure file permissions enforcement (600/640/750)
- Root-only configuration sourcing
- Privilege escalation prevention

### Security Audit Compliance

The v0.9.0 security audit verified:
- ✅ No `eval` with user input
- ✅ No hardcoded credentials
- ✅ No insecure file permissions (`777`, `666`)
- ✅ No insecure curl (`-k`, `--insecure` flags)
- ✅ Proper input validation on all user data
- ✅ Safe word splitting (IFS handling)
- ✅ Atomic file operations throughout
- ✅ Comprehensive error handling

**Security Rating:** 8.5/10 (STRONG)

### Usage Examples

**HTTPS-Only Downloads:**
```bash
# Old (insecure HTTP - blocked)
curl http://example.com/file  # ✗ REJECTED

# New (secure HTTPS - required)
nftban_secure_curl "https://example.com/file" "output.txt"  # ✓ OK
```

**Input Sanitization:**
```bash
# Sanitize jail name (prevents path traversal)
safe_name=$(nftban_sanitize_jail_name "../../etc/passwd")
# Returns error - invalid characters

safe_name=$(nftban_sanitize_jail_name "ssh-ddos")
# Returns: "ssh-ddos" ✓
```

**Atomic File Operations:**
```bash
# Old (race condition possible)
echo "data" > /etc/nftban/config/file.conf

# New (atomic with lock)
nftban_secure_atomic_write "/etc/nftban/config/file.conf" "data"
# Uses flock + temp file + atomic move ✓
```

**CIDR Validation:**
```bash
# Dangerous CIDR (automatically blocked)
nftban_validate_cidr "0.0.0.0/0"  # ✗ REJECTED (entire internet)
nftban_validate_cidr "192.168.0.0/16"  # ✗ REJECTED (private range)

# Safe CIDR (allowed)
nftban_validate_cidr "203.0.113.0/24"  # ✓ OK
```

**Single-Instance Locking:**
```bash
# Prevent concurrent execution
nftban_with_lock "update" nftban_update_system
# If already running → immediate rejection with PID info
```

### Migration to v0.9.0 Security

Existing installations automatically gain v0.9.0 security features on upgrade:
1. **No configuration changes required** - Security hardening is automatic
2. **Backward compatible** - All existing configurations work
3. **Enhanced validation** - Stricter input validation (may reject previously accepted invalid inputs)
4. **HTTPS enforcement** - HTTP URLs in custom configs will be rejected

**Recommended Actions After Upgrade:**
```bash
# 1. Verify file integrity
sudo nftban validate integrity

# 2. Check permissions
sudo nftban --validate-sync

# 3. Review security logs
tail -100 /var/log/nftban/nftban.log | grep "SECURITY\|ERROR"

# 4. Test email notifications
sudo nftban login test
```

---

## Packet Flow Diagram

### How Packets Are Processed

Every network packet arriving at your server goes through this evaluation chain:

```
                    Incoming Network Packet
                            │
                            ↓
        ┌───────────────────────────────────────┐
        │    nftables INPUT Chain               │
        │    (inet nftban_global table)         │
        └───────────────────────────────────────┘
                            │
                            ↓
        ┌───────────────────────────────────────┐
        │  [1] Connection State Check           │
        │  ct state established,related ?       │
        └───────────────────────────────────────┘
                    │              │
                    │ YES          │ NO
                    ↓              ↓
                [ACCEPT]    ┌──────────────────┐
                            │  [2] Loopback?   │
                            │  iif lo ?        │
                            └──────────────────┘
                                │          │
                                │ YES      │ NO
                                ↓          ↓
                            [ACCEPT]  ┌────────────────────┐
                                      │  [3] Whitelist?    │
                                      │  @whitelist_v4/v6  │
                                      └────────────────────┘
                                          │          │
                                          │ YES      │ NO
                                          ↓          ↓
                                      [ACCEPT]  ┌────────────────┐
                                                │ [4] DDoS Check │
                                                │ • SYN flood?   │
                                                │ • Conn limit?  │
                                                │ • Port flood?  │
                                                │ • ICMP limit?  │
                                                └────────────────┘
                                                    │          │
                                                    │ PASS     │ FAIL
                                                    ↓          ↓
                                            ┌─────────────┐  [DROP/
                                            │ [5] Temp    │  REJECT]
                                            │ Ban Check?  │
                                            │ @temp_ban_* │
                                            └─────────────┘
                                                │      │
                                                │ NO   │ YES
                                                ↓      ↓
                                        ┌──────────┐ [DROP]
                                        │ [6] Perm │
                                        │ Ban?     │
                                        │ @perm_*  │
                                        └──────────┘
                                            │    │
                                            │ NO │ YES
                                            ↓    ↓
                                    ┌────────────┐ [DROP]
                                    │ [7] Port   │
                                    │ Allowed?   │
                                    └────────────┘
                                        │    │
                                        │YES │ NO
                                        ↓    ↓
                                    [ACCEPT] [DROP]
                                             │
                                             ↓
                                    (logged if enabled)
```

### Rule Evaluation Priority

Rules are evaluated **in order** - first match wins:

1. **Established/Related (HIGHEST)** - Accept existing connections
2. **Loopback** - Accept localhost traffic
3. **Whitelist** - Accept trusted IPs (cannot be banned)
4. **DDoS Protection** - Rate limiting and connection limits
5. **Temporary Bans** - IPs banned by Fail2Ban or manual action
6. **Permanent Bans** - Persistent blacklist
7. **Port Rules** - Allowed services (SSH, HTTP, etc.)
8. **Default Policy (LOWEST)** - DROP all other traffic

**Key Point:** Whitelist has the highest priority, so whitelisted IPs bypass all other checks including bans.

---

## DDoS Protection

nftban v0.8.5 includes comprehensive DDoS protection with four major components.

### DDoS Protection Architecture

```
┌─────────────────────────────────────────────────────────┐
│              DDoS Protection Module                      │
│         (/etc/nftban/config/ddos_protection.conf)        │
└─────────────────────────────────────────────────────────┘
                            │
        ┌───────────────────┼───────────────────┐
        │                   │                   │
        ↓                   ↓                   ↓
┌──────────────┐  ┌──────────────────┐  ┌──────────────┐
│  SYN Flood   │  │ Connection Limit │  │  Port Flood  │
│  Protection  │  │   Per Port       │  │  Protection  │
└──────────────┘  └──────────────────┘  └──────────────┘
        │                   │                   │
        └───────────────────┼───────────────────┘
                            │
                            ↓
                ┌───────────────────────┐
                │   ICMP Rate Limiting  │
                │   (Ping Protection)   │
                └───────────────────────┘
```

### 1. SYN Flood Protection

Protects against TCP SYN flood attacks by rate limiting new connection attempts.

**How it works:**
```
New TCP Connection (SYN packet)
        │
        ↓
┌───────────────────────────┐
│ Rate Limit Check          │
│ limit rate 100/second     │
│ burst 150                 │
└───────────────────────────┘
        │           │
        │ OK        │ EXCEEDED
        ↓           ↓
    [ACCEPT]    [REJECT]
                    │
                    └─→ Send TCP RST
```

**Configuration:**
```bash
# config/ddos_protection.conf
SYNFLOOD_ENABLE="0"              # Disabled by default (can be intensive)
SYNFLOOD_RATE="100/second"       # Allow 100 SYN/second
SYNFLOOD_BURST="150"             # Allow burst of 150
SYNFLOOD_PORTS="22,80,443"       # Protected ports
```

**Commands:**
```bash
sudo nftban ddos synflood enable   # Enable SYN flood protection
sudo nftban ddos synflood disable  # Disable protection
sudo nftban ddos synflood status   # Check status
```

### 2. Connection Limit Protection

Limits concurrent connections per IP address per port to prevent resource exhaustion.

**How it works:**
```
New Connection to Port
        │
        ↓
┌────────────────────────────┐
│ Count Active Connections   │
│ ct count over <limit>      │
└────────────────────────────┘
        │              │
        │ UNDER LIMIT  │ OVER LIMIT
        ↓              ↓
    [ACCEPT]       [REJECT]
                       │
                       └─→ Send TCP RST
```

**Configuration:**
```bash
# config/ddos_protection.conf
CONNLIMIT_ENABLE="1"             # Enabled by default
CONNLIMIT_SSH="5"                # Max 5 concurrent SSH connections
CONNLIMIT_HTTP="20"              # Max 20 concurrent HTTP connections
CONNLIMIT_HTTPS="20"             # Max 20 concurrent HTTPS connections
CONNLIMIT_CUSTOM="25;10,3306;5" # Port;Limit pairs
```

**Commands:**
```bash
sudo nftban ddos connlimit enable          # Enable all connection limits
sudo nftban ddos connlimit add-port 3306 5 # Add MySQL limit (5 connections)
sudo nftban ddos connlimit remove-port 3306 # Remove limit
sudo nftban ddos connlimit status          # Show current limits
```

### 3. Port Flood Protection

Prevents rapid-fire connection attempts by rate limiting new connections over time.

**How it works:**
```
New Connection Attempt
        │
        ↓
┌─────────────────────────────────┐
│ Check Connection Rate           │
│ limit rate over 5/300s          │  (Example: SSH)
│ (5 connections per 5 minutes)   │
└─────────────────────────────────┘
        │                  │
        │ OK              │ EXCEEDED
        ↓                 ↓
    [ACCEPT]          [REJECT]
                          │
                          └─→ Send TCP RST
```

**Configuration:**
```bash
# config/ddos_protection.conf
PORTFLOOD_ENABLE="1"              # Enabled by default
PORTFLOOD_SSH="5/300"             # SSH: 5 connections per 300 seconds
PORTFLOOD_HTTP="20/5"             # HTTP: 20 connections per 5 seconds
PORTFLOOD_HTTPS="20/5"            # HTTPS: 20 connections per 5 seconds
PORTFLOOD_CUSTOM="25;10/60,3306;5/300" # Port;Rate/Time pairs
```

**Commands:**
```bash
sudo nftban ddos portflood enable              # Enable port flood protection
sudo nftban ddos portflood add-port 3306 5/300 # Add MySQL rate limit
sudo nftban ddos portflood remove-port 3306    # Remove limit
sudo nftban ddos portflood status              # Show current rates
```

### 4. ICMP Rate Limiting

Controls ping requests to prevent ICMP flood attacks and comply with PCI DSS.

**How it works:**
```
ICMP Echo Request (ping)
        │
        ↓
┌───────────────────────────┐
│ ICMP Rate Limit           │
│ Inbound: 1/second         │
│ Outbound: 5/second        │
└───────────────────────────┘
        │           │
        │ OK        │ EXCEEDED
        ↓           ↓
    [ACCEPT]    [DROP]
```

**Configuration:**
```bash
# config/ddos_protection.conf
ICMP_RATELIMIT_ENABLE="1"        # Enabled by default
ICMP_IN_RATE="1/second"          # Inbound ping rate
ICMP_IN_BURST="5"                # Inbound burst
ICMP_OUT_RATE="5/second"         # Outbound ping rate
ICMP_OUT_BURST="10"              # Outbound burst
ICMP_PCI_COMPLIANT="0"           # PCI compliance mode (blocks all ICMP)
```

**Commands:**
```bash
sudo nftban ddos icmp enable       # Enable ICMP rate limiting
sudo nftban ddos icmp disable      # Disable (allow all pings)
sudo nftban ddos icmp status       # Check status
sudo nftban ddos icmp pci-mode     # Enable PCI compliance (block all ICMP)
```

### DDoS Protection Summary Commands

```bash
# Enable all DDoS protections at once
sudo nftban ddos enable

# Check complete DDoS protection status
sudo nftban ddos status

# Disable all DDoS protections
sudo nftban ddos disable
```

---

## Port Scan Detection

nftban v0.8.5 includes intelligent port scan detection to identify and automatically ban port scanners.

### Port Scan Detection Architecture

```
┌─────────────────────────────────────────────────────────┐
│              Port Scan Detection System                  │
└─────────────────────────────────────────────────────────┘
                            │
        ┌───────────────────┼───────────────────┐
        │                   │                   │
        ↓                   ↓                   ↓
┌──────────────┐  ┌──────────────────┐  ┌──────────────┐
│   nftables   │  │   Log Parser     │  │   Tracker    │
│   Logging    │  │   (kernel log)   │  │  (in-memory) │
└──────┬───────┘  └────────┬─────────┘  └──────┬───────┘
       │                   │                    │
       │ Dropped packets   │ Parse IPs/ports    │ Track patterns
       └───────────────────┴────────────────────┘
                            │
                            ↓
                ┌───────────────────────┐
                │   Detection Logic     │
                │   • Count ports/IP    │
                │   • Check diversity   │
                │   • Time window       │
                │   • Whitelist check   │
                └───────────┬───────────┘
                            │
                ┌───────────┴────────────┐
                │ Threshold Exceeded?    │
                │ YES                    │ NO
                ↓                        ↓
        ┌───────────────┐          [Continue
        │  Auto-Ban IP  │           Monitoring]
        │  (temporary)  │
        └───────────────┘
```

### Detection Algorithm

```
Packet arrives at closed/filtered port
        │
        ↓
┌────────────────────────────┐
│ nftables logs drop event   │
│ "PORTSCAN: SRC=<IP> DPT=X" │
└────────────────────────────┘
        │
        ↓
┌──────────────────────────────────────┐
│ Port Scan Module Parses Log          │
│ Extracts: IP address, Port number    │
└──────────────────────────────────────┘
        │
        ↓
┌──────────────────────────────────────┐
│ Check if IP is whitelisted           │
└──────────────────────────────────────┘
        │ NO                   │ YES
        ↓                      ↓
┌──────────────────┐      [IGNORE]
│ Track IP Data:   │
│ • Port list      │
│ • First seen     │
│ • Port count     │
└──────────────────┘
        │
        ↓
┌──────────────────────────────────────┐
│ Calculate Port Diversity             │
│ Range = max_port - min_port          │
│ Diversity = Range / Port_count       │
└──────────────────────────────────────┘
        │
        ↓
┌──────────────────────────────────────┐
│ Check Detection Thresholds           │
│ • Ports accessed >= 10?              │
│ • Within 300 seconds?                │
│ • High diversity? (if enabled)       │
└──────────────────────────────────────┘
        │ YES                  │ NO
        ↓                      ↓
┌──────────────────┐      [Continue
│  SCANNER         │       Tracking]
│  DETECTED        │
└──────────────────┘
        │
        ↓
┌──────────────────────────────────────┐
│ Auto-Ban Actions (if enabled)        │
│ • Log detection event                │
│ • Call: nftban --temp-ban <IP>       │
│ • Send email alert (if configured)   │
│ • Record in detection log            │
└──────────────────────────────────────┘
```

### Port Diversity Detection

The system can differentiate between legitimate services and actual scanners:

```
Example 1: FTP Passive Mode (NOT a scanner)
┌────────────────────────────────────┐
│ Ports: 21, 35000-35999 (15 ports) │
│ Range: 35999 - 21 = 35978         │
│ Diversity: 35978 / 15 = 2398.5    │
│ Result: LOW diversity              │
│ Action: Likely legitimate FTP      │
└────────────────────────────────────┘

Example 2: Port Scanner (IS a scanner)
┌────────────────────────────────────┐
│ Ports: 21,22,25,80,443,3306,5432  │
│        8080,8443,9000 (10 ports)  │
│ Range: 9000 - 21 = 8979           │
│ Diversity: 8979 / 10 = 897.9      │
│ Result: HIGH diversity             │
│ Action: Likely scanner - BAN       │
└────────────────────────────────────┘
```

### Configuration

```bash
# config/portscan.conf
PORTSCAN_ENABLED="1"                  # Enable detection
PORTSCAN_CHECK_INTERVAL="300"        # Check every 5 minutes
PORTSCAN_TIME_WINDOW="300"           # Detection window: 5 minutes
PORTSCAN_THRESHOLD="10"              # Trigger at 10 ports
PORTSCAN_DIVERSITY="1"               # Enable diversity checking
PORTSCAN_MIN_DIVERSITY="100"         # Minimum diversity ratio
PORTSCAN_AUTO_BAN="1"                # Auto-ban detected scanners
PORTSCAN_BAN_TYPE="temporary"        # Use temp bans
PORTSCAN_BAN_TIME="3600"             # Ban for 1 hour
PORTSCAN_MONITOR_PORTS="closed"      # Monitor: closed, filtered, or all
PORTSCAN_LOG_ALL_ATTEMPTS="0"        # Log only detections (not all drops)
```

### Commands

```bash
# Enable port scan detection
sudo nftban portscan enable

# Check detection status
sudo nftban portscan status

# View detection statistics
sudo nftban portscan stats

# Check specific IP
sudo nftban portscan check-ip 203.0.113.45

# Manually check for scanners now
sudo nftban portscan check

# Whitelist security tool (won't be detected/banned)
sudo nftban portscan whitelist add 198.51.100.10

# View port scan whitelist
sudo nftban portscan whitelist list

# Clean up old tracking data
sudo nftban portscan cleanup

# Disable detection
sudo nftban portscan disable
```

### Port Scan Logs

Detection events are logged to:
- `/var/log/nftban/portscan.log` - Detection events
- `/var/log/nftban/portscan_detections.log` - Confirmed scanner detections

**Example log entry:**
```
2025-01-17 10:32:45 [DETECTION] IP: 203.0.113.45 | Ports: 10 | Diversity: 945.6 | Action: AUTO-BAN (3600s)
```

---

## Fail2Ban Integration

nftban integrates seamlessly with Fail2Ban for comprehensive intrusion prevention.

### Integration Architecture

```
┌─────────────────────────────────────────────────────────┐
│                 Fail2Ban Integration                     │
└─────────────────────────────────────────────────────────┘
                            │
        ┌───────────────────┼──────────────────┐
        │                   │                  │
        ↓                   ↓                  ↓
┌──────────────┐  ┌──────────────────┐  ┌─────────────┐
│ Service Logs │  │  Fail2Ban Jails  │  │   Filters   │
│ (auth.log,   │→ │  • SSH           │←─│  (regex)    │
│  access.log) │  │  • SSH DDoS      │  │  patterns   │
└──────────────┘  │  • Recidive      │  └─────────────┘
                  │  • HTTP Auth     │
                  │  • WordPress     │
                  │  • Postfix       │
                  └────────┬─────────┘
                           │
                           ↓ (attack detected)
                  ┌─────────────────┐
                  │  Fail2Ban       │
                  │  Triggers       │
                  │  nftban Action  │
                  └────────┬────────┘
                           │
                           ↓
          Command: nftban --temp-ban <IP> "Fail2Ban: jail_name"
                           │
                           ↓
                  ┌─────────────────┐
                  │  nftban adds IP │
                  │  to temp_ban    │
                  │  set with       │
                  │  timeout        │
                  └────────┬────────┘
                           │
                           ↓
                  ┌─────────────────┐
                  │  nftables drops │
                  │  all traffic    │
                  │  from banned IP │
                  └─────────────────┘
```

### How It Works: Step by Step

```
1. Attack occurs
   └─→ Failed SSH login attempt
       │
       ↓
2. Log entry created
   └─→ /var/log/auth.log: "Failed password for root from 203.0.113.45"
       │
       ↓
3. Fail2Ban monitors log
   └─→ SSH jail filter matches pattern
       │
       ↓
4. Count failures
   └─→ 3 failures within 600 seconds (findtime)
       │
       ↓
5. Threshold exceeded
   └─→ maxretry = 3 → TRIGGER
       │
       ↓
6. Execute nftban action
   └─→ nftban --temp-ban 203.0.113.45 "Fail2Ban: sshd" 3600
       │
       ↓
7. IP added to nftables
   └─→ nft add element inet nftban_global temp_ban_v4 { 203.0.113.45 timeout 3600s }
       │
       ↓
8. Traffic blocked
   └─→ All packets from 203.0.113.45 are dropped at kernel level
       │
       ↓
9. Auto-expire after bantime
   └─→ After 3600 seconds, nftables automatically removes IP
```

### Fail2Ban Jails Integrated with nftban

**1. SSH Jail**
- Protects against SSH brute-force attacks
- Default: 3 failures in 10 minutes = 1 hour ban

**2. SSH DDoS Jail**
- Protects against SSH connection floods
- Default: 10 connections in 60 seconds = 10 minute ban

**3. Recidive Jail**
- Bans repeat offenders (IPs banned multiple times)
- Default: 3 bans in 24 hours = 7 day ban

**4. Service-Specific Jails**
- HTTP Authentication failures
- WordPress login attacks
- Postfix/Dovecot (mail server) attacks
- Apache/Nginx attacks

### Key Benefits of Integration

1. **Automated Response** - No manual intervention needed
2. **Intelligent Detection** - Fail2Ban uses advanced regex patterns
3. **Temporary Bans** - Auto-expire when bantime completed
4. **Email Alerts** - Get notified when attacks occur
5. **Whitelisted IPs** - Never ban trusted addresses
6. **Coordinated Action** - nftban safety checks + Fail2Ban detection

---

## Security Layers

nftban implements defense-in-depth with multiple security layers.

### Multi-Layer Security Model

```
┌─────────────────────────────────────────────────────────┐
│                    Layer 7: Monitoring                   │
│  • Email alerts on attacks                              │
│  • Daily security reports                               │
│  • Log analysis and statistics                          │
└─────────────────────────────────────────────────────────┘
                            ↑
┌─────────────────────────────────────────────────────────┐
│           Layer 6: Application Security                  │
│  • Service hardening (SSH, HTTP, Mail)                  │
│  • Authentication policies                              │
│  • Access controls                                      │
└─────────────────────────────────────────────────────────┘
                            ↑
┌─────────────────────────────────────────────────────────┐
│          Layer 5: Intrusion Prevention                   │
│  • Fail2Ban automatic banning                           │
│  • Port scan detection and auto-ban                     │
│  • Behavioral analysis                                  │
└─────────────────────────────────────────────────────────┘
                            ↑
┌─────────────────────────────────────────────────────────┐
│               Layer 4: DDoS Protection                   │
│  • SYN flood protection                                 │
│  • Connection limits per port                           │
│  • Port flood rate limiting                             │
│  • ICMP rate limiting                                   │
└─────────────────────────────────────────────────────────┘
                            ↑
┌─────────────────────────────────────────────────────────┐
│           Layer 3: Access Control Lists                  │
│  • Whitelist (trusted IPs - highest priority)           │
│  • Blacklist (banned IPs - temp & permanent)            │
│  • Per-service IP restrictions                          │
└─────────────────────────────────────────────────────────┘
                            ↑
┌─────────────────────────────────────────────────────────┐
│              Layer 2: Packet Filtering                   │
│  • Stateful connection tracking                         │
│  • Port-based rules (allow/deny)                        │
│  • Protocol filtering                                   │
└─────────────────────────────────────────────────────────┘
                            ↑
┌─────────────────────────────────────────────────────────┐
│         Layer 1: Network-Level Firewall                  │
│  • nftables kernel packet filter                        │
│  • Default deny policy                                  │
│  • Drop invalid packets                                 │
└─────────────────────────────────────────────────────────┘
                            ↑
                   Incoming Network Traffic
```

### How Layers Work Together

**Example: SSH Attack Scenario**

```
Attacker attempts SSH brute-force attack
        │
        ↓
┌─────────────────────────────────────────┐
│ Layer 1: nftables Firewall              │
│ ✓ Port 22 is open (SSH allowed)         │
│ → Packet forwarded to SSH service       │
└─────────────────────────────────────────┘
        │
        ↓
┌─────────────────────────────────────────┐
│ Layer 2: Packet Filtering               │
│ ✓ TCP port 22, valid packet             │
│ → Connection tracked                     │
└─────────────────────────────────────────┘
        │
        ↓
┌─────────────────────────────────────────┐
│ Layer 3: Access Control                 │
│ ? Check whitelist → NOT whitelisted     │
│ ? Check blacklist → NOT banned (yet)    │
│ → Allow to continue                      │
└─────────────────────────────────────────┘
        │
        ↓
┌─────────────────────────────────────────┐
│ Layer 4: DDoS Protection                │
│ ✓ Connection limit not exceeded         │
│ ✓ Rate limit not exceeded               │
│ → Allow connection                       │
└─────────────────────────────────────────┘
        │
        ↓
┌─────────────────────────────────────────┐
│ Layer 5: Intrusion Prevention           │
│ • Fail2Ban monitors auth.log            │
│ • Detects 3 failed login attempts       │
│ • Threshold exceeded!                   │
│ → TRIGGER: nftban --temp-ban <IP>       │
└─────────────────────────────────────────┘
        │
        ↓
┌─────────────────────────────────────────┐
│ Layer 3: Access Control (UPDATED)       │
│ ✓ IP added to temp_ban set              │
│ → All future packets DROPPED             │
└─────────────────────────────────────────┘
        │
        ↓
┌─────────────────────────────────────────┐
│ Layer 7: Monitoring                     │
│ • Email alert sent to admin             │
│ • Event logged                          │
│ • Statistics updated                    │
└─────────────────────────────────────────┘
```

**Result:** Attacker is now completely blocked at Layer 1 (nftables), preventing all further packets from reaching higher layers or consuming resources.

---

## Initial Security Setup

### First Steps After Installation

**Always whitelist your IP immediately:**

```bash
# Add your current IP
sudo nftban --add-ip

# Verify it's added
sudo nftban --verify-ip $(curl -s ifconfig.me)

# Check whitelist file
cat /etc/nftban/config/nftban-configuration-user-whitelist_ips.conf.local
```

**Test firewall rules before finalizing:**

```bash
# Test sync without applying changes (dry-run mode)
sudo nftban sync test

# Review configuration status
sudo nftban validate

# Apply when satisfied
sudo nftban sync
```

**Keep emergency access available:**

```bash
# Always have console/VNC access
# Document your hosting provider's console access method

# Consider a backup SSH port (advanced)
echo "2222T    # Backup SSH port" >> /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf.local
sudo nftban --sync

# Configure SSH to listen on multiple ports
sudo nano /etc/ssh/sshd_config
# Add: Port 2222
sudo systemctl restart sshd
```

### Defense in Depth Strategy

Never rely on a single security layer:

```
Layer 1: Network Firewall (nftables)
    ↓
Layer 2: Intrusion Prevention (Fail2Ban)
    ↓
Layer 3: SSH Hardening (keys, port changes)
    ↓
Layer 4: Service Hardening (minimal services)
    ↓
Layer 5: Monitoring & Alerting
    ↓
Layer 6: Regular Updates & Patches
```

---

## SSH Hardening

### Disable Password Authentication

**Use SSH keys only:**

```bash
# Generate SSH key on your local machine (if you don't have one)
ssh-keygen -t ed25519 -C "your_email@example.com"

# Copy to server
ssh-copy-id -i ~/.ssh/id_ed25519.pub user@server

# Test key login before disabling passwords!
ssh -i ~/.ssh/id_ed25519 user@server

# Disable password authentication
sudo nano /etc/ssh/sshd_config
```

**Recommended SSH settings:**

```bash
# /etc/ssh/sshd_config

# Disable password authentication
PasswordAuthentication no
ChallengeResponseAuthentication no

# Disable root login
PermitRootLogin no

# Allow only specific users (optional)
AllowUsers yourusername adminuser

# Use only strong key exchange algorithms
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org

# Use only strong ciphers
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com

# Use only strong MACs
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com

# Limit login grace time
LoginGraceTime 30s

# Maximum authentication attempts
MaxAuthTries 3

# Session timeouts
ClientAliveInterval 300
ClientAliveCountMax 2

# Disable unused features
X11Forwarding no
PermitTunnel no
AllowAgentForwarding no
AllowTcpForwarding no
```

**Apply changes:**

```bash
# Test configuration
sudo sshd -t

# Restart SSH (keep current session open!)
sudo systemctl restart sshd
```

### Change Default SSH Port

**Important:** Always whitelist your IP first!

```bash
# Choose a non-standard port (1024-65535)
NEW_PORT=2222

# Update nftban configuration
echo "${NEW_PORT}T    # Custom SSH port" >> /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf.local

# Apply firewall rules
sudo nftban --sync

# Verify port is open
sudo nft list ruleset | grep $NEW_PORT

# Update SSH configuration
sudo nano /etc/ssh/sshd_config
# Change: Port 2222

# Restart SSH
sudo systemctl restart sshd

# Test new port (in another terminal!)
ssh -p 2222 user@server

# Update Fail2Ban SSH jail
sudo nano /etc/fail2ban/jail.d/sshd.local
# Add: port = 2222
sudo systemctl restart fail2ban
```

### Enable Two-Factor Authentication (2FA)

```bash
# Install Google Authenticator
sudo apt-get install libpam-google-authenticator  # Debian/Ubuntu
sudo dnf install google-authenticator             # RHEL/CentOS

# Setup for your user
google-authenticator

# Answer:
# Time-based tokens: y
# Update .google_authenticator: y
# Disallow reuse: y
# Rate limiting: y
# Window of 3 codes: y

# Configure PAM
sudo nano /etc/pam.d/sshd
# Add at the top:
# auth required pam_google_authenticator.so

# Configure SSH
sudo nano /etc/ssh/sshd_config
# Set:
# ChallengeResponseAuthentication yes
# AuthenticationMethods publickey,keyboard-interactive

# Restart SSH
sudo systemctl restart sshd
```

---

## Firewall Hardening

### Strict Default Policy

nftban uses a **deny-by-default** policy. Verify this:

```bash
# Check default policy
sudo nft list ruleset | grep "policy drop"

# Should see:
# chain input { type filter hook input priority filter; policy drop; }
# chain forward { type filter hook forward priority filter; policy drop; }
```

### Minimize Open Ports

**Audit currently open ports:**

```bash
# List all allowed ports
cat /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf
cat /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf.local

# Check what's actually listening
sudo ss -tlnp
sudo netstat -tlnp
```

**Close unnecessary ports:**

```bash
# Example: Close MySQL to external access
# Remove or comment out in .conf.local:
sudo nano /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf.local

# If you need MySQL but only locally, use localhost binding
sudo nano /etc/mysql/my.cnf
# Set: bind-address = 127.0.0.1

# Apply changes
sudo nftban --sync
```

### Rate Limiting on Critical Services

Add rate limiting to prevent brute-force attacks:

```bash
# Create custom rate limit rules
sudo nano /etc/nftban/config/nftban-custom-rules.conf
```

```nft
# Rate limit SSH connections (example)
table inet filter {
    chain input {
        # Allow established connections
        ct state established,related accept
        
        # Rate limit new SSH connections
        tcp dport 22 ct state new limit rate 3/minute burst 5 packets accept
        tcp dport 22 reject with tcp reset
        
        # Rate limit HTTP/HTTPS
        tcp dport { 80, 443 } ct state new limit rate 100/second burst 200 packets accept
        
        # Rate limit DNS queries
        udp dport 53 limit rate 50/second burst 100 packets accept
    }
}
```

### Connection Tracking Optimization

```bash
# Increase connection tracking table size for busy servers
sudo nano /etc/sysctl.conf
```

```conf
# Connection tracking
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 1800

# Protection against SYN floods
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2

# Ignore ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0

# Ignore source routed packets
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# Ignore ICMP ping requests (optional)
# net.ipv4.icmp_echo_ignore_all = 1
```

**Apply sysctl changes:**

```bash
sudo sysctl -p
```

### Logging Strategy

**Enable comprehensive logging:**

```bash
# Add logging rules
sudo nano /etc/nftban/config/nftban-logging-rules.conf
```

```nft
# Log dropped packets (be careful, can generate lots of logs)
table inet filter {
    chain input {
        # Log dropped SSH attempts
        tcp dport 22 ct state new limit rate 1/second burst 3 packets log prefix "DROPPED SSH: "
        
        # Log all other drops (rate limited)
        limit rate 5/minute burst 5 packets log prefix "DROPPED: "
    }
}
```

**Monitor logs:**

```bash
# Watch firewall logs
sudo tail -f /var/log/syslog | grep "DROPPED"

# Analyze most common attackers
sudo grep "DROPPED SSH" /var/log/syslog | awk '{print $(NF-3)}' | sort | uniq -c | sort -rn | head -20
```

---

## Fail2Ban Optimization

### Fine-Tune Ban Times

```bash
# Edit Fail2Ban configuration
sudo nano /etc/nftban/config/nftban.conf.local
```

```bash
# Aggressive banning
NFTBAN_F2B_BANTIME="86400"        # 24 hours
NFTBAN_F2B_FINDTIME="600"         # 10 minutes
NFTBAN_F2B_MAXRETRY="3"           # 3 attempts

# For high-security environments
# NFTBAN_F2B_BANTIME="604800"     # 7 days
# NFTBAN_F2B_MAXRETRY="2"         # 2 attempts

# Recidive jail (repeat offenders)
NFTBAN_F2B_RECIDIVE_BANTIME="2592000"  # 30 days
NFTBAN_F2B_RECIDIVE_FINDTIME="86400"   # 24 hours
NFTBAN_F2B_RECIDIVE_MAXRETRY="3"
```

### Enable Important Jails

```bash
# Enable all security jails
sudo nano /etc/nftban/config/nftban.conf.local
```

```bash
NFTBAN_F2B_SSH_JAIL="true"
NFTBAN_F2B_SSH_DDOS_JAIL="true"
NFTBAN_F2B_RECIDIVE_JAIL="true"
NFTBAN_F2B_WORDPRESS_JAIL="true"      # If using WordPress
NFTBAN_F2B_POSTFIX_JAIL="true"        # If using mail server
NFTBAN_F2B_DOVECOT_JAIL="true"        # If using mail server
```

**Apply changes:**

```bash
sudo systemctl restart fail2ban

# Verify jails are active
sudo fail2ban-client status
```

### Create Custom Jails

**Example: Protect custom web application:**

```bash
# Create custom jail
sudo nano /etc/fail2ban/jail.d/custom-app.local
```

```ini
[custom-app-auth]
enabled = true
port = 8080
filter = custom-app-auth
logpath = /var/log/custom-app/access.log
maxretry = 5
findtime = 300
bantime = 3600
action = nftables-multiport[name=custom-app, port="8080"]
```

**Create filter:**

```bash
sudo nano /etc/fail2ban/filter.d/custom-app-auth.conf
```

```ini
[Definition]
failregex = ^<HOST> .* "POST /login HTTP.*" 401
            ^<HOST> .* "POST /api/auth HTTP.*" 403
ignoreregex =
```

**Test and reload:**

```bash
# Test filter
sudo fail2ban-regex /var/log/custom-app/access.log /etc/fail2ban/filter.d/custom-app-auth.conf

# Reload Fail2Ban
sudo systemctl reload fail2ban
```

### Whitelist Legitimate Services

```bash
# Whitelist monitoring services, APIs, etc.
sudo nano /etc/fail2ban/jail.local
```

```ini
[DEFAULT]
ignoreip = 127.0.0.1/8 
           ::1
           192.168.1.0/24
           203.0.113.10      # Your monitoring server
           198.51.100.20     # Your API gateway
```

---

## Monitoring and Alerting

### Email Alerts Configuration

```bash
# Configure email alerts
sudo nano /etc/nftban/config/nftban.conf.local
```

```bash
# Email configuration
NFTBAN_F2B_DESTEMAIL="security@yourdomain.com"
NFTBAN_F2B_SENDER="nftban@$(hostname -f)"
NFTBAN_F2B_ACTION="%(action_mwl)s"  # Mail with logs

# Enable email notifications
NFTBAN_F2B_ENABLE_EMAIL="true"
```

**Test email delivery:**

```bash
# Test mail system
echo "Test email from nftban" | mail -s "Test Email" security@yourdomain.com

# Test Fail2Ban email
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh test-mail security@yourdomain.com
```

### Enable Login Monitoring

```bash
# Enable comprehensive login monitoring
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh login-monitor enable hybrid

# This monitors:
# - SSH logins
# - sudo usage
# - root access
# - Failed login attempts
```

**Monitor login logs:**

```bash
# View recent login activity
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh login-monitor status

# Check specific log
sudo tail -f /var/log/nftban/nftban_login_monitor.log

# View failed SSH attempts
sudo grep "Failed password" /var/log/auth.log | tail -20
```

### Set Up Centralized Logging (Optional)

```bash
# Install rsyslog (usually pre-installed)
sudo apt-get install rsyslog

# Configure remote logging
sudo nano /etc/rsyslog.d/50-nftban.conf
```

```conf
# Send nftban logs to remote server
if $programname == 'nftban' then @@logserver.example.com:514
& stop

# Send firewall logs
if $msg contains 'DROPPED' then @@logserver.example.com:514
& stop
```

### Daily Security Reports

**Create automated daily report:**

```bash
# Create report script
sudo nano /usr/local/bin/nftban-daily-report.sh
```

```bash
#!/bin/bash

REPORT_EMAIL="security@yourdomain.com"
REPORT_FILE="/tmp/nftban-report-$(date +%Y%m%d).txt"

{
    echo "=== nftban Daily Security Report - $(date) ==="
    echo ""
    
    echo "=== Currently Banned IPs ==="
    sudo nftban --view-banned
    echo ""
    
    echo "=== Fail2Ban Statistics ==="
    sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh stats
    echo ""
    
    echo "=== Top 10 Attacking IPs (Today) ==="
    sudo grep "Ban " /var/log/fail2ban.log | grep "$(date +%Y-%m-%d)" | awk '{print $NF}' | sort | uniq -c | sort -rn | head -10
    echo ""
    
    echo "=== New SSH Logins (Last 24h) ==="
    sudo grep "Accepted" /var/log/auth.log | grep "$(date +%Y-%m-%d)" | tail -20
    echo ""
    
    echo "=== Failed SSH Attempts (Last 24h) ==="
    sudo grep "Failed password" /var/log/auth.log | grep "$(date +%Y-%m-%d)" | wc -l
    echo ""
    
    echo "=== System Status ==="
    sudo nftban status
    
} > "$REPORT_FILE"

# Email report
mail -s "nftban Daily Report - $(hostname)" "$REPORT_EMAIL" < "$REPORT_FILE"

# Clean up old reports (keep 30 days)
find /tmp -name "nftban-report-*.txt" -mtime +30 -delete
```

**Make executable and schedule:**

```bash
sudo chmod +x /usr/local/bin/nftban-daily-report.sh

# Add to crontab
sudo crontab -e
# Add: 0 8 * * * /usr/local/bin/nftban-daily-report.sh
```

---

## Rate Limiting and DDoS Protection

### Basic DDoS Protection

```bash
# Enable SSH DDoS jail
sudo nano /etc/nftban/config/nftban.conf.local
```

```bash
NFTBAN_F2B_SSH_DDOS_JAIL="true"
NFTBAN_F2B_SSH_DDOS_MAXRETRY="10"
NFTBAN_F2B_SSH_DDOS_FINDTIME="60"
```

### Advanced Rate Limiting

**Create advanced rate limit rules:**

```bash
sudo nano /etc/nftban/config/nftban-ratelimit.conf
```

```nft
table inet filter {
    # Create sets for rate limiting
    set ratelimit_v4 {
        type ipv4_addr
        size 65535
        flags dynamic,timeout
        timeout 1m
    }
    
    set ratelimit_v6 {
        type ipv6_addr
        size 65535
        flags dynamic,timeout
        timeout 1m
    }
    
    chain input {
        # HTTP/HTTPS rate limiting (100 req/sec per IP)
        tcp dport { 80, 443 } add @ratelimit_v4 { ip saddr limit rate over 100/second } drop
        tcp dport { 80, 443 } add @ratelimit_v6 { ip6 saddr limit rate over 100/second } drop
        
        # DNS rate limiting (50 queries/sec per IP)
        udp dport 53 add @ratelimit_v4 { ip saddr limit rate over 50/second } drop
        udp dport 53 add @ratelimit_v6 { ip6 saddr limit rate over 50/second } drop
    }
}
```

### SYN Flood Protection

```bash
# Kernel-level protection
sudo nano /etc/sysctl.d/99-ddos-protection.conf
```

```conf
# SYN flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_max_syn_backlog = 4096

# Reduce TIME_WAIT connections
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1

# Protect against IP spoofing
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Disable ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
```

**Apply:**

```bash
sudo sysctl -p /etc/sysctl.d/99-ddos-protection.conf
```

---

## Advanced Security Configurations

### GeoIP Blocking (Preparation)

*Note: Full GeoIP blocking is planned for future nftban versions. Here's manual setup:*

```bash
# Install GeoIP utilities
sudo apt-get install geoip-bin geoip-database  # Debian/Ubuntu
sudo dnf install GeoIP GeoIP-data              # RHEL/CentOS

# Test GeoIP lookup
geoiplookup 8.8.8.8

# Manual country blocking (example: block China and Russia)
sudo nano /etc/nftban/config/nftban-geoip-block.sh
```

```bash
#!/bin/bash
# Block countries by downloading their IP ranges

COUNTRIES="cn ru"  # ISO country codes

for country in $COUNTRIES; do
    # Download IP list (example source)
    wget -qO- "https://www.ipdeny.com/ipblocks/data/countries/${country}.zone" | \
    while read ip; do
        sudo nftban --perm-ban "$ip" "GeoIP block: $country"
    done
done
```

### Application-Specific Protection

**WordPress hardening:**

```bash
# Enable WordPress jails
sudo nano /etc/nftban/config/nftban.conf.local
```

```bash
NFTBAN_F2B_WORDPRESS_JAIL="true"
NFTBAN_F2B_WORDPRESS_MAXRETRY="3"
NFTBAN_F2B_WORDPRESS_BANTIME="86400"
```

**Protect wp-login.php:**

```bash
# Create custom WordPress filter
sudo nano /etc/fail2ban/filter.d/wordpress-extra.conf
```

```ini
[Definition]
failregex = ^<HOST> .* "POST /wp-login\.php
            ^<HOST> .* "POST /xmlrpc\.php
ignoreregex =
```

### Honeypot Ports

**Set up honeypot to identify scanners:**

```bash
# Create honeypot jail
sudo nano /etc/fail2ban/jail.d/honeypot.local
```

```ini
[honeypot]
enabled = true
port = 23,3389,5900,8888
filter = honeypot
logpath = /var/log/syslog
maxretry = 1
findtime = 3600
bantime = 604800
action = nftables-multiport[name=honeypot, port="23,3389,5900,8888"]
```

**Create filter:**

```bash
sudo nano /etc/fail2ban/filter.d/honeypot.conf
```

```ini
[Definition]
failregex = kernel:.*SRC=<HOST>.*DPT=(23|3389|5900|8888)
ignoreregex =
```

---

## Regular Maintenance

### Weekly Security Checklist

```bash
#!/bin/bash
# Save as /usr/local/bin/nftban-weekly-check.sh

echo "=== Weekly nftban Security Check ==="

# 1. Validate configuration sync
echo "[1/7] Checking configuration sync..."
sudo nftban --validate-sync

# 2. Check for banned IPs count
echo "[2/7] Checking banned IP count..."
BANNED_COUNT=$(sudo nftban --view-banned | grep -c ".")
echo "Currently banned IPs: $BANNED_COUNT"

# 3. Verify Fail2Ban status
echo "[3/7] Checking Fail2Ban status..."
sudo systemctl is-active fail2ban

# 4. Check for failed login attempts
echo "[4/7] Failed login attempts (last 7 days)..."
sudo grep "Failed password" /var/log/auth.log | wc -l

# 5. Review whitelist
echo "[5/7] Current whitelist..."
cat /etc/nftban/config/nftban-configuration-user-whitelist_ips.conf.local

# 6. Check disk space for logs
echo "[6/7] Log disk usage..."
du -sh /var/log/nftban/

# 7. System updates available
echo "[7/7] System updates..."
apt list --upgradable 2>/dev/null || dnf check-update

echo "=== Check Complete ==="
```

### Update Schedule

```bash
# Weekly system updates
sudo apt-get update && sudo apt-get upgrade -y  # Debian/Ubuntu
sudo dnf update -y                               # RHEL/CentOS

# Monthly full upgrade
sudo apt-get dist-upgrade -y     # Debian/Ubuntu
sudo dnf upgrade --refresh -y    # RHEL/CentOS

# Update nftban (if auto-update not enabled)
sudo /etc/nftban/scripts/nftban_init.sh --github --upgrade
```

### Log Rotation

```bash
# Configure log rotation
sudo nano /etc/logrotate.d/nftban
```

```conf
/var/log/nftban/*.log {
    daily
    rotate 30
    compress
    delaycompress
    notifempty
    create 0640 root root
    sharedscripts
    postrotate
        systemctl reload rsyslog > /dev/null 2>&1 || true
    endscript
}

/var/log/fail2ban.log {
    daily
    rotate 30
    compress
    delaycompress
    notifempty
    create 0640 root adm
    postrotate
        fail2ban-client flushlogs >/dev/null || true
    endscript
}
```

---

## Backup and Recovery

### Automated Backup Script

```bash
#!/bin/bash
# Save as /usr/local/bin/nftban-backup.sh

BACKUP_DIR="/var/backups/nftban"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/nftban-backup-$DATE.tar.gz"

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Backup all nftban configurations
tar -czf "$BACKUP_FILE" \
    /etc/nftban/ \
    /etc/fail2ban/jail.d/ \
    /etc/fail2ban/filter.d/ \
    /etc/systemd/system/nftables.service

# Keep only last 30 backups
find "$BACKUP_DIR" -name "nftban-backup-*.tar.gz" -mtime +30 -delete

echo "Backup saved: $BACKUP_FILE"
```

**Schedule daily backups:**

```bash
sudo chmod +x /usr/local/bin/nftban-backup.sh

# Add to crontab
sudo crontab -e
# Add: 0 2 * * * /usr/local/bin/nftban-backup.sh
```

### Restore from Backup

```bash
# List available backups
ls -lh /var/backups/nftban/

# Restore from specific backup
BACKUP_FILE="/var/backups/nftban/nftban-backup-20250111_020000.tar.gz"
sudo tar -xzf "$BACKUP_FILE" -C /

# Reload services
sudo nftban --sync
sudo systemctl restart fail2ban
```

### Disaster Recovery Plan

**Create recovery documentation:**

```bash
# Save this information in a secure, offline location

# 1. Emergency access credentials
# - Console access URL: https://your-provider.com/console
# - Root password location: [secure location]
# - SSH key backup: [secure location]

# 2. Emergency firewall flush
sudo nft flush ruleset
sudo nftban sync

# 3. Reset Fail2Ban
sudo systemctl stop fail2ban
sudo fail2ban-client unban --all
sudo systemctl start fail2ban

# 4. Emergency whitelist
sudo nftban --add-ip YOUR.IP.ADDRESS.HERE

# 5. Restore from backup
sudo tar -xzf /var/backups/nftban/latest.tar.gz -C /
sudo nftban --sync
```

---

## Common Security Mistakes

### ❌ Mistake 1: Not Whitelisting Your Own IP

**Problem:** Locking yourself out after enabling strict rules.

**Solution:**
```bash
# Always whitelist first!
sudo nftban --add-ip
```

### ❌ Mistake 2: Closing All Ports

**Problem:** Accidentally blocking legitimate traffic.

**Solution:**
```bash
# Review before applying
sudo nftban --validate-sync

# Test with dry-run
sudo nftban sync test
```

### ❌ Mistake 3: Too Aggressive Ban Times

**Problem:** Banning legitimate users for minor issues.

**Solution:**
```bash
# Start with moderate settings
NFTBAN_F2B_BANTIME="3600"      # 1 hour
NFTBAN_F2B_MAXRETRY="5"        # 5 attempts

# Increase gradually based on monitoring
```

### ❌ Mistake 4: Not Monitoring Logs

**Problem:** Missing security incidents.

**Solution:**
```bash
# Set up daily reports
sudo /usr/local/bin/nftban-daily-report.sh

# Enable email alerts
NFTBAN_F2B_ENABLE_EMAIL="true"
```

### ❌ Mistake 5: Ignoring Updates

**Problem:** Running outdated, vulnerable software.

**Solution:**
```bash
# Enable automatic updates (use with caution)
sudo apt-get install unattended-upgrades  # Debian/Ubuntu
sudo dnf install dnf-automatic             # RHEL/CentOS

# Or schedule manual updates
# Weekly: sudo apt-get update && sudo apt-get upgrade -y
```

### ❌ Mistake 6: Single Point of Failure

**Problem:** Relying only on firewall.

**Solution:**
- Use SSH keys + 2FA
- Regular backups
- Monitoring and alerting
- Update all software regularly
- Minimize attack surface

---

## Emergency Procedures

### Lockout Recovery

**If locked out via SSH:**

```bash
# Option 1: Use console access (best)
# Log in via your hosting provider's console
# Then whitelist your IP:
sudo nftban --add-ip

# Option 2: Temporary firewall flush (dangerous!)
# Only use if absolutely necessary
sudo nft flush ruleset
# Fix issue quickly, then reapply:
sudo nftban sync
```

### Under Active Attack

**Immediate response to active attack:**

```bash
# 1. Identify attacking IPs
sudo tail -f /var/log/auth.log | grep "Failed password"

# 2. Ban attacker immediately
sudo nftban --perm-ban ATTACKER.IP.ADDRESS "Active attack"

# 3. Check Fail2Ban statistics
sudo fail2ban-client status sshd

# 4. Review all current bans
sudo nftban --view-banned

# 5. Temporarily block entire country (if needed)
# Use GeoIP blocking or contact your hosting provider
```

### Service Recovery

**If services become unreachable:**

```bash
# 1. Check service status
sudo systemctl status nftables
sudo systemctl status fail2ban

# 2. Validate configuration
sudo nftban --validate-sync

# 3. Review firewall rules
sudo nft list ruleset | less

# 4. Check for errors
sudo journalctl -u nftables -n 50
sudo journalctl -u fail2ban -n 50

# 5. Restart services
sudo systemctl restart nftables
sudo systemctl restart fail2ban
```

---

## Compliance and Auditing

### Logging for Compliance

**Enable comprehensive logging:**

```bash
# Configure auditd (if required for compliance)
sudo apt-get install auditd
sudo systemctl enable --now auditd

# Add firewall audit rules
sudo nano /etc/audit/rules.d/nftban.rules
```

```conf
# Monitor nftban configuration changes
-w /etc/nftban/ -p wa -k nftban_config
-w /etc/fail2ban/ -p wa -k fail2ban_config

# Monitor firewall changes
-w /usr/sbin/nft -p x -k nftables_exec
-w /etc/nftables.conf -p wa -k nftables_config
```

### Audit Trail

**Generate audit report:**

```bash
#!/bin/bash
# Save as /usr/local/bin/nftban-audit-report.sh

echo "=== nftban Security Audit Report ==="
echo "Generated: $(date)"
echo ""

echo "=== Configuration Changes (Last 30 days) ==="
sudo ausearch -k nftban_config -ts recent | grep -v "type=CONFIG_CHANGE"

echo ""
echo "=== Ban Statistics (Last 30 days) ==="
sudo grep "Ban " /var/log/fail2ban.log | wc -l

echo ""
echo "=== Most Banned IPs ==="
sudo grep "Ban " /var/log/fail2ban.log | awk '{print $NF}' | sort | uniq -c | sort -rn | head -20

echo ""
echo "=== Current Security Status ==="
sudo nftban status
```

### Retention Policies

```bash
# Configure log retention
sudo nano /etc/logrotate.d/nftban
```

```conf
# Retain logs based on compliance requirements
# Example: PCI DSS requires 1 year
/var/log/nftban/*.log {
    daily
    rotate 365
    compress
    delaycompress
    notifempty
    create 0640 root root
}
```

---

## Download Integrity Verification

### SHA256 Checksums

nftban publishes SHA256 checksums for every commit to the main branch, allowing you to verify the integrity of downloaded files and detect potential tampering.

**Why this matters:**

We publish `SHA256SUMS.txt` for every commit to main. Verifying downloads against these hashes helps ensure integrity and detect tampering. While this doesn't encrypt content or replace code signing, it's a simple, effective defense-in-depth step that protects against:

- **Man-in-the-middle attacks** during download
- **Compromised mirrors** or CDNs
- **Accidental file corruption** during transfer
- **Unauthorized modifications** to project files

### How It Works

```
GitHub Push → Workflow Triggers → Generate SHA256SUMS.txt → Commit to Repo
                                          │
                                          ↓
                              Calculate hash for every file
                              Format: <hash>  <filepath>
                              Sort by filepath
                              Commit automatically
```

### Manual Verification

**Verify a single file:**

```bash
# Download SHA256SUMS.txt from GitHub
curl -fsSL https://raw.githubusercontent.com/itcmsgr/nftban/main/SHA256SUMS.txt -o SHA256SUMS.txt

# Calculate hash of your local file
sha256sum lib/nftban_core.sh

# Compare with expected hash
grep "lib/nftban_core.sh" SHA256SUMS.txt

# Expected output:
# <hash>  lib/nftban_core.sh
#
# If the hashes match → File is authentic ✓
# If they differ → File may be corrupted or tampered with ✗
```

**Verify all files in a directory:**

```bash
# Download SHA256SUMS.txt
curl -fsSL https://raw.githubusercontent.com/itcmsgr/nftban/main/SHA256SUMS.txt -o SHA256SUMS.txt

# Verify all .sh files in lib/
cd /etc/nftban
sha256sum -c SHA256SUMS.txt 2>&1 | grep "lib/.*\.sh"

# Output:
# lib/nftban_core.sh: OK
# lib/nftban_safety_module.sh: OK
# lib/nftban_whitelist_module.sh: OK
# ...
```

### Automated Verification (Built-in)

nftban includes built-in validation tools to automatically verify file integrity:

```bash
# Validate all installed files
sudo nftban validate integrity

# Validate specific directory
sudo nftban validate directory /etc/nftban/lib

# View validation report
cat /var/log/nftban/validation_report.log

# Example output:
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# VALIDATION SUMMARY
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#   Total files:    78
#   ✓ Valid:        76
#   ✗ Failed:       0
#   ? Unknown:      2 (new/not tracked)
#   ⊘ Missing:      0
#   ⊝ Skipped:      0
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### Verification During Installation

The installer automatically validates downloaded files:

```bash
# Install with automatic validation
sudo bash lib/installer/installer_main.sh install

# Installation process includes:
# 1. Download files from GitHub
# 2. Download SHA256SUMS.txt
# 3. Validate each file against checksum
# 4. Proceed only if all files pass validation
# 5. Report any mismatches

# Example validation output during install:
# [INFO] Downloading nftban files...
# [INFO] Validating file integrity...
# [OK]   lib/nftban_core.sh
# [OK]   lib/nftban_safety_module.sh
# [OK]   lib/nftban_whitelist_module.sh
# ...
# [INFO] All files validated successfully
```

### SHA256SUMS.txt Format

The checksum file follows standard SHA256 format with metadata header:

```
# nftban SHA256 Checksums
# Generated: 2025-01-18 12:29:45 UTC
# Commit: 5d8e046 (5d8e046abc123...)
# Branch: main
# Total files: 100
#
# This file contains SHA256 checksums for all tracked files in the repository.
# Use 'sha256sum -c SHA256SUMS.txt' to verify file integrity (ignores comment lines).
# Format: <hash>  <filepath> (standard SHA256 format, two spaces)
#

27bc601747697ac484ed80b2bae80ab2996e3a27dd0850222525252200e8ad20  lib/nftban_core.sh
117c5cc2fe48c0b61b5cff2873e953d2a6fd699581c86b7caeaf686c0df31d9c  lib/nftban_safety_module.sh
5814df1535b0402e296ab0d2cb7a010d12c4abca8bc4a1ebffae37d2ee10a98e  lib/nftban_whitelist_module.sh
...
```

**Key features:**
- **Header metadata** - Shows generation timestamp, commit hash, branch, and file count
- **Standard SHA256 format** - Two spaces between hash and filepath (compatible with `sha256sum -c`)
- **Comment lines** - Header lines start with `#` and are ignored by verification tools
- **Sorted alphabetically** - Files sorted by filepath for stability
- **Comprehensive coverage** - Includes all tracked files except SHA256SUMS.txt itself
- **Automatic updates** - Regenerated on every push to main
- **Change detection** - Only commits when file checksums change (not just timestamp)

### Security Best Practices

1. **Always verify after download:**
   ```bash
   git clone https://github.com/itcmsgr/nftban.git
   cd nftban
   sha256sum -c SHA256SUMS.txt
   ```

2. **Verify before upgrades:**
   ```bash
   sudo nftban validate integrity
   # Check output before proceeding
   sudo nftban upgrade
   ```

3. **Monitor validation reports:**
   ```bash
   # Set up weekly validation
   echo "0 2 * * 0 /usr/local/bin/nftban validate integrity" | sudo crontab -
   ```

4. **Investigate failures immediately:**
   ```bash
   # If validation fails:
   sudo nftban validate panel  # View detailed report

   # Check for unauthorized changes:
   sudo find /etc/nftban -type f -mtime -7  # Files modified in last week

   # Restore from backup if needed:
   sudo tar -xzf /var/backups/nftban/latest.tar.gz -C /
   ```

### Limitations

**What SHA256 verification provides:**
- ✓ Detects file corruption during transfer
- ✓ Detects unauthorized modifications
- ✓ Verifies files match official release
- ✓ Defense-in-depth layer

**What it does NOT provide:**
- ✗ Code signing (GPG signatures)
- ✗ Encryption of file contents
- ✗ Protection if GitHub account is compromised
- ✗ Guarantee of code security (only integrity)

**Recommended additional security:**
- Always download from official repository
- Verify GitHub repository URL: `https://github.com/itcmsgr/nftban`
- Review commit history for suspicious changes
- Use release tags for production deployments
- Enable GitHub security advisories notifications

---

## Security Hardening Checklist

Use this checklist to verify your security posture:

### Initial Setup
- [ ] Whitelist your IP address
- [ ] Test firewall rules with dry-run
- [ ] Keep console access available
- [ ] Document emergency procedures

### SSH Security
- [ ] Disable password authentication
- [ ] Use SSH keys only
- [ ] Disable root login
- [ ] Change default SSH port
- [ ] Enable 2FA (recommended)
- [ ] Set login grace timeout
- [ ] Limit authentication attempts

### Firewall Configuration
- [ ] Verify deny-by-default policy
- [ ] Minimize open ports
- [ ] Enable rate limiting
- [ ] Configure connection tracking
- [ ] Enable logging (with limits)
- [ ] Review rules regularly

### Fail2Ban Setup
- [ ] Enable SSH jail
- [ ] Enable SSH DDoS jail
- [ ] Enable recidive jail
- [ ] Configure appropriate ban times
- [ ] Set up email alerts
- [ ] Create custom jails as needed
- [ ] Whitelist legitimate services

### Monitoring
- [ ] Enable login monitoring
- [ ] Configure email alerts
- [ ] Set up daily reports
- [ ] Review logs regularly
- [ ] Monitor disk space
- [ ] Check ban statistics

### Maintenance
- [ ] Schedule regular updates
- [ ] Configure log rotation
- [ ] Set up automated backups
- [ ] Test restore procedures
- [ ] Document changes
- [ ] Review security weekly

### Advanced
- [ ] Implement rate limiting
- [ ] Configure DDoS protection
- [ ] Set up honeypot ports (optional)
- [ ] Plan GeoIP blocking (optional)
- [ ] Integrate with SIEM (optional)
- [ ] Enable audit logging (if required)

---

## Additional Resources

### Official Documentation
- [nftables Wiki](https://wiki.nftables.org/)
- [Fail2ban Manual](https://fail2ban.readthedocs.io/)
- [SSH Hardening Guide](https://www.ssh.com/academy/ssh/security-hardening)

### Security Standards
- [CIS Benchmarks](https://www.cisecurity.org/cis-benchmarks/)
- [NIST Cybersecurity Framework](https://www.nist.gov/cyberframework)
- [OWASP Guidelines](https://owasp.org/)

### Testing Tools
- `nmap` - Port scanning and security auditing
- `fail2ban-regex` - Test Fail2Ban filters
- `nft` - View and test firewall rules
- `ss` / `netstat` - Check open ports

---

## Need Help?

**Community Support:**
- [GitHub Issues](https://github.com/itcmsgr/nftban/issues)
- [GitHub Discussions](https://github.com/itcmsgr/nftban/discussions)

**Professional Support:**
- Email: support@itcms.gr
- Website: [https://itcms.gr](https://itcms.gr)

---

<p align="center">
  <b>Stay Secure! 🛡️</b><br>
  <sub>Remember: Security is a process, not a product.</sub>
</p>

<p align="center">
  <sub>Copyright © 2025 Antonios Voulvoulis – ITCMS. All rights reserved.</sub>
</p>
