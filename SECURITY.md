# 🛡️ NFTBan Security Architecture

**How NFTBan Protects Your Server - Complete Guide with Diagrams**

This comprehensive guide explains how NFTBan's multi-layer security system works, with detailed diagrams and hardening techniques to maximize your server's security.

---

## 🚨 Security Advisories

### CVE-2024-NFTBAN-001 - Rule Order Bypass (FIXED in v0.31.1)

**Severity:** HIGH
**Affected Versions:** v0.31.0 and earlier
**Fixed in:** v0.31.1 (2025-11-05)

**Issue:** Blacklist checks ran AFTER port allow rules, allowing blacklisted IPs to bypass firewall and access SSH/services.

**Impact:**
- Blacklisted attackers could access SSH (port 22)
- Blacklisted IPs could reach all allowed services
- Threat feeds were ineffective against open ports

**Root Cause:**
```nft
# VULNERABLE (v0.31.0):
tcp dport @tcp_ports accept    ← Port 22 accepted FIRST
ip saddr @blacklist_v4 drop    ← NEVER REACHED!
```

**Fix (v0.31.1):**
```nft
# SECURE (v0.31.1):
ip saddr @blacklist_v4 counter drop    ← Check blacklist FIRST
tcp dport @tcp_ports counter accept    ← Then allow ports
```

**Recommended Action:**
- **Upgrade immediately to v0.31.1 or later**
- Verify fix: `nftban firewall check`
- Validate rule order: `nft list chain inet nftban_main input`

**Security Score:** v0.31.0 = 9/10 (critical bug), v0.31.1 = 10/10 (reference-grade)

---

## 📋 Table of Contents

- [Architecture Overview](#architecture-overview)
- [Packet Flow Diagram](#packet-flow-diagram)
- [DDoS Protection](#ddos-protection)
- [Threat Feed Integration](#threat-feed-integration)
- [Geo-Blocking](#geo-blocking)
- [Fail2Ban Integration](#fail2ban-integration)
- [Security Layers](#security-layers)
- [Commit-Confirm Safety System](#commit-confirm-safety-system)
- [Initial Security Setup](#initial-security-setup)
- [SSH Hardening](#ssh-hardening)
- [Firewall Hardening](#firewall-hardening)
- [Monitoring and Alerting](#monitoring-and-alerting)
- [Health Checks and Auto-Repair](#health-checks-and-auto-repair)
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

NFTBan v0.10.0 consists of multiple integrated security layers working together:

```
┌─────────────────────────────────────────────────────────────┐
│                      NFTBan v0.10.0 System                   │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Kernel Space (nftables)                  │  │
│  │  ┌────────────────────────────────────────────────┐  │  │
│  │  │  Packet Filter (inet nftban)                   │  │  │
│  │  │  • Whitelist Sets (highest priority)           │  │  │
│  │  │  • Blacklist Sets (temp & permanent bans)      │  │  │
│  │  │  • DDoS Protection (SYN flood, rate limits)    │  │  │
│  │  │  • Geo-blocking (country-based filtering)      │  │  │
│  │  │  • Connection Limits (per-port)                │  │  │
│  │  └────────────────────────────────────────────────┘  │  │
│  └──────────────────────────────────────────────────────┘  │
│                           ↓                                 │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              User Space Modules                       │  │
│  │  ┌────────────────────────────────────────────────┐  │  │
│  │  │  Core Modules (/usr/lib/nftban/core/)         │  │  │
│  │  │  • nftban_rules.sh (rule generation)           │  │  │
│  │  │  • nftban_stats.sh (statistics tracking)       │  │  │
│  │  │  • nftban_report.sh (report generation)        │  │  │
│  │  │  • nftban_health.sh (health monitoring)        │  │  │
│  │  └────────────────────────────────────────────────┘  │  │
│  │                                                        │  │
│  │  ┌────────────────────────────────────────────────┐  │  │
│  │  │  Go Binaries (/usr/lib/nftban/bin/)           │  │  │
│  │  │  • nftban-feeds (threat feed processor)        │  │  │
│  │  │  • nftban-geoip (GeoIP database handler)       │  │  │
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
│  │  nftban ban <IP> "Fail2Ban: jail_name"                │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Data Flow Between Components

```
Log Files               Configuration Files
(/var/log/)            (/etc/nftban/)
    │                          │
    │                          ↓
    │                  ┌───────────────┐
    │                  │ Config Parser │
    │                  └───────┬───────┘
    │                          │
    ↓                          ↓
┌──────────┐           ┌──────────────┐
│ Fail2Ban │ ←────────→│  nftban CLI  │
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

## Packet Flow Diagram

### How Packets Are Processed

Every network packet arriving at your server goes through this evaluation chain:

```
                    Incoming Network Packet
                            │
                            ↓
        ┌───────────────────────────────────────┐
        │    nftables INPUT Chain               │
        │    (inet nftban table)                │
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
                                                │ [4] Geo-Block? │
                                                │ Country check  │
                                                └────────────────┘
                                                    │          │
                                                    │ ALLOWED  │ BLOCKED
                                                    ↓          ↓
                                            ┌─────────────┐  [DROP]
                                            │ [5] DDoS    │
                                            │ Protection  │
                                            │ • SYN flood │
                                            │ • Conn lim  │
                                            │ • Port flood│
                                            └─────────────┘
                                                │      │
                                                │ PASS │ FAIL
                                                ↓      ↓
                                        ┌──────────┐ [DROP/
                                        │ [6] Temp │  REJECT]
                                        │ Ban?     │
                                        │ @banned  │
                                        └──────────┘
                                            │    │
                                            │ NO │ YES
                                            ↓    ↓
                                    ┌────────────┐ [DROP]
                                    │ [7] Threat │
                                    │ Feed Ban?  │
                                    │ @threats   │
                                    └────────────┘
                                        │    │
                                        │ NO │ YES
                                        ↓    ↓
                                ┌────────────┐ [DROP]
                                │ [8] Port   │
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
4. **Geo-blocking** - Block/allow by country (if enabled)
5. **DDoS Protection** - Rate limiting and connection limits
6. **Temporary Bans** - IPs banned by Fail2Ban or manual action
7. **Threat Feed Bans** - IPs from security threat feeds
8. **Port Rules** - Allowed services (SSH, HTTP, etc.)
9. **Default Policy (LOWEST)** - DROP all other traffic

**Key Point:** Whitelist has the highest priority, so whitelisted IPs bypass all other checks including bans.

---

## DDoS Protection

NFTBan v0.10.0 includes comprehensive DDoS protection with multiple components.

### DDoS Protection Architecture

```
┌─────────────────────────────────────────────────────────┐
│              DDoS Protection Module                      │
│         (/etc/nftban/conf.d/ddos.conf)                  │
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

### Configuration

DDoS protection can be enabled and configured via:
- Main configuration: `/etc/nftban/conf.d/ddos.conf`
- Local overrides: `/etc/nftban/nftban.conf.local`

**Key settings to configure:**
- Enable/disable DDoS protection
- Connection limits per service (SSH, HTTP, HTTPS)
- Rate limits for new connections
- SYN flood thresholds
- ICMP rate limiting

See `nftban help` for command syntax or `man nftban` for complete reference.

---

## Threat Feed Integration

NFTBan v0.10.0 includes a high-performance Go-based threat feed processor.

### Threat Feed Architecture

```
┌─────────────────────────────────────────────────────────┐
│           Threat Feed System (nftban-feeds)              │
└─────────────────────────────────────────────────────────┘
                            │
        ┌───────────────────┼───────────────────┐
        │                   │                   │
        ↓                   ↓                   ↓
┌──────────────┐  ┌──────────────────┐  ┌──────────────┐
│  Spamhaus    │  │  Emerging Threats│  │  Abuse.ch    │
│  DROP/EDROP  │  │  Compromised IPs │  │  Feodo, SSL  │
└──────────────┘  └──────────────────┘  └──────────────┘
        │                   │                   │
        └───────────────────┼───────────────────┘
                            │
                            ↓
                ┌───────────────────────┐
                │  Feed Processor (Go)  │
                │  • Download feeds     │
                │  • Validate IPs       │
                │  • Deduplicate        │
                │  • Apply to nftables  │
                └───────────────────────┘
                            │
                            ↓
                ┌───────────────────────┐
                │  inet nftban table    │
                │  @threat_ips set      │
                └───────────────────────┘
```

### Configuration

Threat feeds are configured via:
- Feed definitions: `/etc/nftban/conf.d/feeds.conf`
- Feed storage: `/var/lib/nftban/feeds/`
- Feed cache: `/var/cache/nftban/feeds/`

**Available feed sources:**
- Spamhaus (DROP, EDROP lists)
- Emerging Threats (compromised IPs)
- Abuse.ch (Feodo, SSL blacklists)
- Custom feeds (user-defined URLs)

See `nftban feeds help` for feed management commands.

### Feed Performance

NFTBan's Go-based feed processor delivers:
- **10-60x faster** than traditional shell-based processing
- **Concurrent downloads** for multiple feeds
- **Intelligent caching** to avoid re-downloading unchanged feeds
- **Atomic updates** to prevent partial application of rules

---

## Geo-Blocking

NFTBan v0.10.0 includes GeoIP-based country filtering using MaxMind databases.

### Geo-Blocking Architecture

```
┌─────────────────────────────────────────────────────────┐
│           GeoIP System (nftban-geoip)                    │
└─────────────────────────────────────────────────────────┘
                            │
                            ↓
                ┌───────────────────────┐
                │  MaxMind GeoLite2 DB  │
                │  • Country database   │
                │  • City database      │
                └───────────────────────┘
                            │
                            ↓
                ┌───────────────────────┐
                │  GeoIP Processor (Go) │
                │  • IP → Country map   │
                │  • Generate sets      │
                │  • Update nftables    │
                └───────────────────────┘
                            │
                            ↓
                ┌───────────────────────┐
                │  inet nftban table    │
                │  @geoblock_ssh set    │
                │  @geoblock_all set    │
                └───────────────────────┘
```

### Configuration

Geo-blocking requires MaxMind GeoLite2 database (free tier available).

**Setup requirements:**
1. Obtain MaxMind license key from maxmind.com
2. Store securely in `/etc/nftban/secrets.d/maxmind.conf`
3. Download GeoIP database
4. Configure allowed/denied countries
5. Apply rules

**Geo-blocking options:**
- **Per-service blocking** (e.g., SSH from specific countries only)
- **Global blocking** (block countries across all services)
- **Allow-list mode** (only allow specified countries)
- **Deny-list mode** (block specified countries)

See [README.md](README.md) for installation and `nftban help` for setup commands.

---

## Fail2Ban Integration

NFTBan integrates seamlessly with Fail2Ban for comprehensive intrusion prevention.

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
                  │  NFTBan Action  │
                  └────────┬────────┘
                           │
                           ↓
          Command: nftban ban <IP> "Fail2Ban: jail_name" --expires <time>
                           │
                           ↓
                  ┌─────────────────┐
                  │  nftban adds IP │
                  │  to banned set  │
                  │  with timeout   │
                  └────────┬────────┘
                           │
                           ↓
                  ┌─────────────────┐
                  │  nftables drops │
                  │  all traffic    │
                  │  from banned IP │
                  └─────────────────┘
```

### Integration Setup

NFTBan provides a Fail2Ban action that integrates seamlessly:

**Action file:** `/etc/fail2ban/action.d/nftban.conf`
- Defines how Fail2Ban calls NFTBan to ban/unban IPs
- Supports temporary bans with automatic expiration
- Passes jail name and reason to NFTBan

**Jail configuration:** `/etc/fail2ban/jail.local`
- Configure ban times (e.g., 1 hour, 24 hours)
- Set detection thresholds (failures before ban)
- Set time windows for counting failures
- Specify NFTBan as the ban action

**Recommended jails:**
- **sshd** - SSH brute-force protection
- **sshd-ddos** - SSH connection flooding
- **recidive** - Repeat offenders (longer bans)
- **nginx-limit-req** - HTTP rate limit violations
- **postfix/dovecot** - Mail server attacks

See [README.md](README.md) for installation and `nftban fail2ban help` for integration setup.

---

## Security Layers

NFTBan implements defense-in-depth with multiple security layers.

### Multi-Layer Security Model

```
┌─────────────────────────────────────────────────────────┐
│                    Layer 8: Monitoring                   │
│  • Health checks (automated)                            │
│  • Statistics tracking                                  │
│  • Email alerts on attacks                              │
│  • Report generation (JSON, HTML, CSV)                  │
└─────────────────────────────────────────────────────────┘
                            ↑
┌─────────────────────────────────────────────────────────┐
│           Layer 7: Application Security                  │
│  • Service hardening (SSH, HTTP, Mail)                  │
│  • Authentication policies                              │
│  • Access controls                                      │
└─────────────────────────────────────────────────────────┘
                            ↑
┌─────────────────────────────────────────────────────────┐
│          Layer 6: Intrusion Prevention                   │
│  • Fail2Ban automatic banning                           │
│  • Behavioral analysis                                  │
│  • Repeat offender tracking                             │
└─────────────────────────────────────────────────────────┘
                            ↑
┌─────────────────────────────────────────────────────────┐
│          Layer 5: Threat Intelligence                    │
│  • Real-time threat feeds (Spamhaus, etc.)              │
│  • Known attacker databases                             │
│  • Community blacklists                                 │
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
│            Layer 3: Geo-Blocking                         │
│  • Country-based filtering (SSH, all services)          │
│  • GeoIP database lookups                               │
│  • Whitelist/blacklist by region                        │
└─────────────────────────────────────────────────────────┘
                            ↑
┌─────────────────────────────────────────────────────────┐
│           Layer 2: Access Control Lists                  │
│  • Whitelist (trusted IPs - highest priority)           │
│  • Blacklist (banned IPs - temp & permanent)            │
│  • Per-service IP restrictions                          │
└─────────────────────────────────────────────────────────┘
                            ↑
┌─────────────────────────────────────────────────────────┐
│              Layer 1: Packet Filtering                   │
│  • Stateful connection tracking                         │
│  • Port-based rules (allow/deny)                        │
│  • Protocol filtering                                   │
│  • Default deny policy                                  │
└─────────────────────────────────────────────────────────┘
                            ↑
                   Incoming Network Traffic
```

---

## Commit-Confirm Safety System

NFTBan v0.10.0 includes a commit-confirm system to prevent SSH lockouts.

### How It Works

```
User runs: sudo nftban apply
        │
        ↓
┌───────────────────────────────┐
│ 1. Create backup of current   │
│    nftables configuration     │
└───────────────────────────────┘
        │
        ↓
┌───────────────────────────────┐
│ 2. Generate new rules         │
│    based on current config    │
└───────────────────────────────┘
        │
        ↓
┌───────────────────────────────┐
│ 3. Apply rules to nftables    │
│    (IMMEDIATE EFFECT)         │
└───────────────────────────────┘
        │
        ↓
┌───────────────────────────────┐
│ 4. Start 5-minute countdown   │
│    WAITING FOR CONFIRMATION   │
│    (Press Enter to confirm)   │
└───────────────────────────────┘
        │
        ├────────────────┐
        │ User confirms  │ Timeout (no confirmation)
        ↓                ↓
┌──────────────┐  ┌─────────────────────────┐
│ 5. Rules     │  │ 5. AUTO-ROLLBACK        │
│    confirmed │  │    Restore backup       │
│    ✓ SUCCESS │  │    ✗ RULES REVERTED     │
└──────────────┘  └─────────────────────────┘
```

### How To Use Safely

**Best practices:**
1. **Keep SSH session open** - Don't close it until rules are confirmed
2. **Test in another terminal** - Open a new SSH connection to verify connectivity
3. **Have console access ready** - Know how to access server console if locked out
4. **Document rollback procedure** - Know emergency recovery steps
5. **Never disable** - Commit-confirm is your safety net

**If you lose connectivity:**
- **Option 1:** Wait for auto-rollback (5 minutes by default)
- **Option 2:** Access via console and run manual rollback
- **Option 3:** Use emergency recovery procedures (see Emergency Procedures section)

**Configuration:**
- Timeout duration is configurable (default: 300 seconds / 5 minutes)
- Can be disabled (NOT RECOMMENDED except for automation)
- Automatic rollback prevents permanent lockouts

See `nftban help` for command syntax or `man nftban` for complete reference.

---

## Initial Security Setup

### First Steps After Installation

**Critical first actions:**

1. **Whitelist your management IP** - Before enabling any rules, add your IP to whitelist to prevent lockout
2. **Document console access** - Know how to access your server's console (VNC/IPMI/provider panel)
3. **Review default configuration** - Understand what ports will be open and what will be blocked
4. **Test with dry-run** - See what rules will be generated before applying
5. **Use commit-confirm** - Always apply with the safety system enabled
6. **Keep SSH open** - Don't close your session until rules are confirmed

**Consider backup access:**
- Configure alternate SSH port (e.g., 2222) as fallback
- Test backup port before relying on it
- Update Fail2Ban configuration for non-standard ports
- Document all access methods

See [README.md](README.md) for installation and setup instructions.

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

**Use SSH keys only** - This is one of the most important security measures.

**Key security settings in `/etc/ssh/sshd_config`:**

**Authentication:**
- `PasswordAuthentication no` - Disable password login
- `ChallengeResponseAuthentication no` - Disable challenge-response
- `PermitRootLogin no` - Prevent root login entirely
- `AllowUsers` - Restrict to specific usernames only
- `MaxAuthTries 3` - Limit authentication attempts

**Cryptography:**
- `KexAlgorithms` - Use only modern key exchange (curve25519)
- `Ciphers` - Use only strong ciphers (chacha20-poly1305, aes256-gcm)
- `MACs` - Use only strong MACs (hmac-sha2-512-etm, hmac-sha2-256-etm)

**Timeouts and limits:**
- `LoginGraceTime 30s` - Short grace period for login
- `ClientAliveInterval 300` - Check client every 5 minutes
- `ClientAliveCountMax 2` - Drop after 2 failed checks

**Disable unnecessary features:**
- `X11Forwarding no` - Disable X11
- `PermitTunnel no` - Disable tunneling
- `AllowAgentForwarding no` - Disable agent forwarding
- `AllowTcpForwarding no` - Disable TCP forwarding

**Before changing SSH configuration:**
1. Generate ED25519 SSH key pair locally
2. Copy public key to server with `ssh-copy-id`
3. Test key-based login in a NEW session
4. Only then disable password authentication
5. Always test configuration with `sshd -t` before restarting
6. Keep current session open until new session works

**Additional hardening:**
- Enable two-factor authentication (2FA/TOTP)
- Change default SSH port (security through obscurity, but helps reduce noise)
- Limit source IPs with `AllowUsers user@specific.ip.address`
- Use fail2ban to auto-ban brute-force attempts

### Change Default SSH Port

Changing the SSH port reduces automated attack noise but is NOT a security measure by itself.

**Important considerations:**

**Before changing:**
1. Whitelist your IP in NFTBan first
2. Have console access available as backup
3. Choose a port between 1024-65535 (avoid well-known ports)
4. Document the new port securely

**Changes required:**
1. **NFTBan configuration** - Add new port to allowed ports
2. **SSH daemon** - Update `/etc/ssh/sshd_config` with `Port` directive
3. **Fail2Ban** - Update SSH jail configuration with new port
4. **SELinux** (if enabled) - Update SSH port policy

**Testing procedure:**
1. Apply NFTBan rules with new port
2. Restart SSH daemon
3. Test connection in NEW terminal before closing current session
4. Only close original session after confirming new port works
5. Update Fail2Ban and test ban/unban functionality

**Pros:**
- Reduces log noise from automated scanners
- Makes casual port scans less likely to find SSH
- Compliance with some security policies

**Cons:**
- Not a substitute for proper SSH hardening
- May cause confusion for legitimate users
- Requires coordination when multiple admins access server
- Some networks block non-standard ports

---

## Firewall Hardening

### Strict Default Policy

NFTBan implements **deny-by-default** - all traffic is dropped unless explicitly allowed.

**Why this matters:**
- **Fail-safe** - Services installed later don't automatically become accessible
- **Minimal attack surface** - Only explicitly allowed services are reachable
- **Compliance** - Meets security frameworks requiring default-deny policies
- **Visibility** - Forces conscious decision for each open port

**Verification:**
Check nftables rules to confirm default DROP policy is applied.

### Minimize Open Ports

**Principle: Only open what you need**

**Common minimal configurations:**
- **Web server** - Ports 22 (SSH), 80 (HTTP), 443 (HTTPS)
- **Database server** - Port 22 (SSH) only - databases bind to localhost
- **Mail server** - Ports 22, 25 (SMTP), 143 (IMAP), 993 (IMAPS), 587 (submission)
- **Minimal server** - Port 22 (SSH) only

**Audit procedure:**
1. List configured allowed ports
2. Check what services are actually listening
3. Identify discrepancies
4. Close unused ports
5. Bind services to localhost if only local access needed

**Service binding examples:**
- **MySQL/PostgreSQL** - Bind to 127.0.0.1 if only local apps need access
- **Redis/Memcached** - Bind to localhost unless cluster setup
- **Development servers** - Never expose debug/development ports externally

### Connection Tracking Optimization

Linux kernel connection tracking (conntrack) needs tuning for high-traffic servers.

**Key sysctl parameters in `/etc/sysctl.conf` or `/etc/sysctl.d/`:**

**Connection tracking:**
- `net.netfilter.nf_conntrack_max` - Maximum tracked connections (increase for busy servers)
- `net.netfilter.nf_conntrack_tcp_timeout_established` - Timeout for established TCP connections

**SYN flood protection:**
- `net.ipv4.tcp_syncookies = 1` - Enable SYN cookies (CRITICAL for DDoS protection)
- `net.ipv4.tcp_max_syn_backlog` - Maximum SYN backlog queue size
- `net.ipv4.tcp_synack_retries` - Reduce SYN-ACK retries

**Routing security:**
- `net.ipv4.conf.all.accept_redirects = 0` - Ignore ICMP redirects (prevents MITM)
- `net.ipv6.conf.all.accept_redirects = 0` - Same for IPv6
- `net.ipv4.conf.all.accept_source_route = 0` - Reject source-routed packets
- `net.ipv6.conf.all.accept_source_route = 0` - Same for IPv6
- `net.ipv4.conf.all.rp_filter = 1` - Enable reverse path filtering (anti-spoofing)

**Apply changes:**
After editing sysctl configuration, apply with `sysctl -p` or reboot.

---

## Monitoring and Alerting

### Health Checks and Auto-Repair

NFTBan v0.10.0 includes comprehensive automated health monitoring that can detect and auto-fix issues.

**What health checks monitor:**
- **Binary dependencies** - Ensures nft, systemctl, jq, etc. are installed
- **FHS path structure** - Verifies all required directories exist
- **File permissions** - Checks ownership and permissions on critical files
- **System configuration** - Validates UID/GID in system.conf
- **Service status** - Ensures systemd services are available
- **Module availability** - Confirms all core modules are present

**Auto-repair capabilities:**
- Fix file permissions automatically
- Recreate missing directories
- Regenerate system.conf if corrupted
- Repair broken systemd units

**Automated monitoring:**
- Runs via systemd timer (hourly by default)
- Logs to `/var/log/nftban/health.log`
- Can trigger email alerts on failures
- Self-healing prevents manual intervention

See `nftban health help` or `man nftban` for health check commands.

### Statistics and Reporting

NFTBan tracks comprehensive statistics about:
- **Ban statistics** - Total bans, active bans, expired bans
- **Category breakdown** - Bans by source (Fail2Ban, feeds, manual, DDoS)
- **Geo-blocking stats** - Blocked countries, allowed countries
- **Feed statistics** - Feed update times, IP counts, errors
- **DDoS metrics** - Connection limits hit, rate limits triggered

**Report formats:**
- **JSON** - For automation and integration with monitoring tools
- **HTML** - Human-readable web page with charts and graphs
- **CSV** - For spreadsheet analysis and data processing

**Report storage:**
- Saved to `/var/lib/nftban/reports/`
- Automatic retention policy (configurable)
- Can be emailed automatically on schedule

See `nftban stats help` or `man nftban` for statistics and reporting commands.

### Email Alerts Configuration

**Fail2Ban integration:**
Configure email notifications in `/etc/fail2ban/jail.local`:
- Set destination email for security alerts
- Set sender address
- Choose action (mail with logs, mail without logs, etc.)

**NFTBan integration:**
Email alerts can be triggered by:
- Health check failures
- Critical security events
- Scheduled reports (daily, weekly)
- Threshold breaches (e.g., > 100 bans/hour)

### Automated Reporting

**Best practices for automated reports:**
- Schedule daily summary reports
- Include health check status
- Show ban statistics and top attackers
- Review recent successful logins
- Track failed authentication attempts
- Monitor feed update status

**Delivery methods:**
- Email (via mail/sendmail)
- Log aggregation systems (rsyslog, syslog-ng)
- Monitoring platforms (Nagios, Zabbix, Prometheus)
- SIEM integration (Splunk, ELK stack)

---

## Health Checks and Auto-Repair

NFTBan v0.10.0 provides automated health monitoring to ensure system integrity.

### What Gets Checked

**Dependencies:** Verifies required binaries are installed (nft, systemctl, jq, curl, etc.)

**File System:** Checks FHS-compliant directory structure exists with correct permissions

**Permissions:** Validates ownership (nftban:nftban) and modes on critical files and directories

**Configuration:** Verifies system.conf contains valid UID/GID matching actual system users

**Services:** Ensures systemd units are installed and enabled

**Modules:** Confirms all core modules and binaries are present

### Auto-Repair Capabilities

The health system can automatically fix:
- Incorrect file ownership and permissions
- Missing directories
- Corrupted system.conf
- Broken symlinks
- Missing systemd units

**Safety features:**
- Dry-run mode to preview changes
- Detailed logging of all repairs
- Backup before making changes
- Rollback capability

### Automated Monitoring

Health checks run automatically via systemd timer (hourly by default):
- Logs results to `/var/log/nftban/health.log`
- Can trigger email alerts on failures
- Auto-repairs minor issues
- Escalates critical issues to administrator

See `nftban health help` or `man nftban` for health check commands.

---

## Advanced Security Configurations

### Rate Limiting

Rate limiting protects against:
- **Brute-force attacks** - Limit login attempts per time period
- **Connection flooding** - Prevent resource exhaustion
- **API abuse** - Control request rates
- **Web scraping** - Limit page requests

**Configuration areas:**
- **SSH rate limiting** - Limit new connections per IP over time window
- **HTTP/HTTPS rate limiting** - Control web traffic flow
- **Per-service limits** - Custom limits for specific ports/services

**Strategy:**
- Set limits based on legitimate use patterns
- Start conservative, relax as needed
- Monitor for false positives
- Whitelist known good actors

### SYN Flood Protection

SYN flood attacks exhaust server resources by opening many half-open TCP connections.

**Kernel-level defenses in `/etc/sysctl.d/99-ddos-protection.conf`:**

**SYN cookies:** Enable `net.ipv4.tcp_syncookies = 1` - Allows server to handle SYN floods without tracking state

**SYN backlog:** Increase `net.ipv4.tcp_max_syn_backlog` - Larger queue for SYN packets

**Retry limits:** Reduce `net.ipv4.tcp_syn_retries` and `net.ipv4.tcp_synack_retries` - Faster timeout for failed connections

**Connection cleanup:** Reduce `net.ipv4.tcp_fin_timeout` - Faster cleanup of closed connections

**TCP reuse:** Enable `net.ipv4.tcp_tw_reuse` - Reuse TIME_WAIT sockets faster

**Additional protections:**
- Reverse path filtering (`rp_filter`) - Prevents IP spoofing
- Disable ICMP redirects - Prevents MITM attacks
- Disable source routing - Prevents routing manipulation

---

## Regular Maintenance

### Weekly Security Checklist

**Essential weekly tasks:**
1. **Health check** - Verify system integrity
2. **Ban statistics** - Review ban activity and patterns
3. **Service status** - Confirm Fail2Ban and NFTBan services running
4. **Feed updates** - Verify threat feeds are current
5. **Whitelist review** - Audit whitelisted IPs for changes
6. **Disk space** - Check log file sizes
7. **System updates** - Review and apply security patches

**Automation:**
Create a weekly check script that runs these tasks and emails results. Schedule via cron for Sunday mornings.

### Update Schedule

**Weekly:**
- System security patches
- Package updates
- Configuration review

**Automatic (via systemd timers):**
- Threat feed updates (every 5 minutes)
- Health checks (hourly)
- Statistics collection (continuous)

**Monthly:**
- GeoIP database updates
- Full system upgrades
- Configuration backup review
- Access control audit

**Quarterly:**
- Security policy review
- Whitelist/blacklist audit
- Performance optimization
- Capacity planning

### Log Rotation

NFTBan generates logs in `/var/log/nftban/` that need rotation to prevent disk space issues.

**Configuration via `/etc/logrotate.d/nftban`:**
- **Rotation frequency** - Daily, weekly, or monthly
- **Retention period** - How long to keep old logs (30 days typical)
- **Compression** - Compress old logs to save space
- **Permissions** - Maintain nftban:nftban ownership
- **Post-rotation actions** - Reload rsyslog after rotation

**Key files to rotate:**
- `/var/log/nftban/nftban.log` - Main log file
- `/var/log/nftban/health.log` - Health check log
- `/var/log/nftban/feeds.log` - Feed update log
- `/var/log/fail2ban.log` - Fail2Ban log (separate rotation)

---

## Backup and Recovery

### What To Backup

**Critical NFTBan files:**
- `/etc/nftban/` - All configuration files
- `/var/lib/nftban/config/system.conf` - System configuration with UID/GID
- `/var/lib/nftban/state/` - Current ban state
- `/etc/fail2ban/jail.d/` - Custom Fail2Ban jails
- `/etc/fail2ban/filter.d/` - Custom Fail2Ban filters
- Systemd unit files for NFTBan

**Backup strategy:**
- **Daily automated backups** - Via cron at off-peak hours
- **Retention policy** - Keep 30 days of daily backups
- **Off-site copies** - Store backups remotely for disaster recovery
- **Encrypted backups** - Protect sensitive configuration data
- **Test restores** - Regularly verify backups can be restored

### Restore Procedures

**Standard restore process:**
1. Stop NFTBan and Fail2Ban services
2. Extract backup to root filesystem
3. Verify file permissions and ownership
4. Run health check to identify issues
5. Apply firewall rules
6. Restart services
7. Verify functionality

**Common restore scenarios:**
- **Configuration corruption** - Restore /etc/nftban/ only
- **State loss** - Restore /var/lib/nftban/state/
- **Complete system recovery** - Full backup restore
- **Migration to new server** - Restore and update system.conf

### Disaster Recovery Plan

**Essential documentation (store securely offline):**

**Access methods:**
- Console access URL and credentials
- Root password location
- SSH key backup location
- Emergency contact information

**Emergency procedures:**
1. **Lockout recovery** - Console access and whitelist commands
2. **Service failure** - Restart procedures
3. **Configuration corruption** - Restore from backup
4. **Complete system failure** - Rebuild and restore

**Recovery objectives:**
- **RTO (Recovery Time Objective)** - How quickly to restore service
- **RPO (Recovery Point Objective)** - Acceptable data loss window
- **Priority order** - What to restore first

See `nftban help` or `man nftban` for backup and restore commands.

---

## Common Security Mistakes

### ❌ Mistake 1: Not Whitelisting Your Own IP

**Problem:** Locking yourself out after enabling strict rules.

**Solution:**
```bash
# Always whitelist first!
sudo nftban whitelist add $(curl -s ifconfig.me) "My management IP"
```

### ❌ Mistake 2: Disabling Commit-Confirm

**Problem:** No safety net if you apply wrong rules.

**Solution:**
```bash
# ALWAYS use commit-confirm (enabled by default)
sudo nftban config set commit_confirm_enabled true
sudo nftban apply  # Uses commit-confirm automatically
```

### ❌ Mistake 3: Too Aggressive Ban Times

**Problem:** Banning legitimate users for minor issues.

**Solution:**
```bash
# Start with moderate Fail2Ban settings
sudo vim /etc/fail2ban/jail.local
# Set: bantime = 3600 (1 hour)
# Set: maxretry = 5
```

### ❌ Mistake 4: Not Monitoring Logs

**Problem:** Missing security incidents.

**Solution:**
```bash
# Set up daily reports
sudo /usr/local/bin/nftban-daily-report.sh

# Enable automated health checks
sudo systemctl enable --now nftban-health.timer
```

### ❌ Mistake 5: Ignoring Updates

**Problem:** Running outdated, vulnerable software.

**Solution:**
```bash
# Enable automatic updates (use with caution)
sudo dnf install dnf-automatic             # Rocky/AlmaLinux/Fedora
sudo apt-get install unattended-upgrades  # Ubuntu/Debian

# Or schedule manual updates weekly
```

### ❌ Mistake 6: Single Point of Failure

**Problem:** Relying only on firewall.

**Solution:**
- Use SSH keys + 2FA
- Regular backups
- Monitoring and alerting
- Update all software regularly
- Minimize attack surface
- Defense in depth strategy

---

## Emergency Procedures

### Lockout Recovery

**Symptoms:** Cannot SSH to server after applying firewall rules.

**Recovery options (in order of preference):**

1. **Wait for auto-rollback** - If you just applied rules with commit-confirm, wait 5 minutes for automatic rollback

2. **Console access** - Log in via hosting provider's console (VNC/IPMI) and whitelist your IP

3. **Manual rollback** - Via console, run rollback command to restore previous rules

4. **Emergency flush** - Last resort: flush all rules via console (leaves server unprotected)

**Prevention:**
- Always use commit-confirm when applying rules
- Keep console access credentials documented
- Whitelist management IPs before making changes
- Test rules in another terminal before confirming
- Have documented recovery procedures

### Under Active Attack

**Signs of active attack:**
- Flood of failed login attempts
- High CPU usage from authentication
- Network saturation
- Many IPs attempting connections

**Immediate response:**
1. **Identify attack source** - Check auth logs for patterns
2. **Emergency ban** - Manually ban attacking IPs or ranges
3. **Enable geo-blocking** - Block entire countries if needed
4. **Review current bans** - Check if Fail2Ban is catching attacks
5. **Contact provider** - For DDoS mitigation if attack is large
6. **Document incident** - Log attack details for analysis

**Post-attack:**
- Analyze logs to understand attack vector
- Adjust Fail2Ban thresholds if needed
- Review and update security policies
- Consider additional protections (geo-blocking, rate limits)

### Service Recovery

**Symptoms:** NFTBan or Fail2Ban services not working correctly.

**Diagnostic steps:**
1. **Health check** - Identify specific issues
2. **Auto-repair** - Let health system fix common problems
3. **Service status** - Check if services are running
4. **Review logs** - Look for errors in systemd journal
5. **Firewall rules** - Verify nftables rules are loaded
6. **Configuration validation** - Check for syntax errors

**Recovery actions:**
- Restart affected services
- Restore from backup if configuration corrupted
- Manually fix permissions if health check fails
- Reapply firewall rules if rules missing
- Contact support if issue persists

See `nftban help` or `man nftban` for emergency commands.

---

## Compliance and Auditing

### Logging for Compliance

**Enable comprehensive logging:**

```bash
# Configure auditd (if required for compliance)
sudo apt-get install auditd
sudo systemctl enable --now auditd

# Add firewall audit rules
sudo vim /etc/audit/rules.d/nftban.rules
```

```conf
# Monitor NFTBan configuration changes
-w /etc/nftban/ -p wa -k nftban_config
-w /etc/fail2ban/ -p wa -k fail2ban_config

# Monitor firewall changes
-w /usr/sbin/nft -p x -k nftables_exec
-w /usr/sbin/nftban -p x -k nftban_exec
```

### Audit Trail

**Generate audit report:**

```bash
#!/bin/bash
# Save as /usr/local/bin/nftban-audit-report.sh

echo "=== NFTBan Security Audit Report ==="
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
echo "=== Health Check Status ==="
sudo nftban health check
```

### Retention Policies

```bash
# Configure log retention
sudo vim /etc/logrotate.d/nftban
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
    create 0640 nftban nftban
}
```

---

## Download Integrity Verification

### Package Checksums

NFTBan publishes SHA256 checksums for all packages and releases.

**Why this matters:**

Verifying downloads against published hashes helps ensure integrity and detect tampering. This protects against:

- **Man-in-the-middle attacks** during download
- **Compromised mirrors** or CDNs
- **Accidental file corruption** during transfer
- **Unauthorized modifications** to packages

### Verify Package Installation

**RPM packages (Rocky/AlmaLinux/Fedora):**

```bash
# Download package and checksum
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban.el9.x86_64.rpm
wget https://github.com/itcmsgr/nftban/releases/latest/download/SHA256SUMS

# Verify checksum
sha256sum -c SHA256SUMS 2>&1 | grep nftban-0.10.0-1.el9.x86_64.rpm

# Expected output:
# nftban-0.10.0-1.el9.x86_64.rpm: OK
```

**DEB packages (Ubuntu/Debian):**

```bash
# Download package and checksum
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban.ubuntu.amd64.deb
wget https://github.com/itcmsgr/nftban/releases/latest/download/SHA256SUMS

# Verify checksum
sha256sum -c SHA256SUMS 2>&1 | grep nftban_0.10.0-1_amd64.deb

# Expected output:
# nftban_0.10.0-1_amd64.deb: OK
```

### Verify Installed Files

**After installation, verify file integrity:**

```bash
# Verify all installed files match checksums
sudo nftban health check --category=integrity

# This checks:
# - Core modules in /usr/lib/nftban/core/
# - Go binaries in /usr/lib/nftban/bin/
# - CLI commands in /usr/lib/nftban/cli/
# - Configuration files in /etc/nftban/
```

### Security Best Practices

1. **Always verify before installation:**
   ```bash
   sha256sum -c SHA256SUMS
   # Only install if all files show: OK
   ```

2. **Verify after upgrades:**
   ```bash
   sudo nftban health check --category=integrity
   ```

3. **Monitor for unauthorized changes:**
   ```bash
   # Set up weekly integrity check
   echo "0 2 * * 0 /usr/sbin/nftban health check --category=integrity" | sudo crontab -
   ```

4. **Investigate failures immediately:**
   ```bash
   # If verification fails:
   sudo nftban health check --verbose

   # Check for unauthorized changes:
   sudo find /usr/lib/nftban -type f -mtime -7  # Files modified in last week

   # Restore from package if needed:
   sudo dnf reinstall nftban  # Rocky/AlmaLinux/Fedora
   sudo apt-get install --reinstall nftban  # Ubuntu/Debian
   ```

### Limitations

**What SHA256 verification provides:**
- ✓ Detects file corruption during transfer
- ✓ Detects unauthorized modifications
- ✓ Verifies files match official release
- ✓ Defense-in-depth layer

**What it does NOT provide:**
- ✗ Code signing (GPG signatures) - planned for future releases
- ✗ Encryption of file contents
- ✗ Protection if GitHub account is compromised
- ✗ Guarantee of code security (only integrity)

**Recommended additional security:**
- Always download from official repository: `https://github.com/itcmsgr/nftban`
- Verify GitHub repository ownership
- Review commit history for suspicious changes
- Use release tags for production deployments
- Enable GitHub security advisories notifications

---

## Security Hardening Checklist

Use this checklist to verify your security posture:

### Initial Setup
- [ ] Whitelist your IP address
- [ ] Test commit-confirm with dry-run
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
- [ ] Enable DDoS protection
- [ ] Configure connection tracking
- [ ] Enable commit-confirm safety
- [ ] Review rules regularly

### Threat Intelligence
- [ ] Enable threat feeds
- [ ] Configure feed update schedule
- [ ] Enable geo-blocking (if needed)
- [ ] Download GeoIP database
- [ ] Review blocked countries

### Fail2Ban Setup
- [ ] Enable SSH jail
- [ ] Enable SSH DDoS jail
- [ ] Enable recidive jail
- [ ] Configure appropriate ban times
- [ ] Set up email alerts
- [ ] Create custom jails as needed
- [ ] Whitelist legitimate services

### Monitoring
- [ ] Enable automated health checks
- [ ] Configure statistics tracking
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
- [ ] Configure SYN flood protection
- [ ] Set up geo-blocking policies
- [ ] Integrate with SIEM (optional)
- [ ] Enable audit logging (if required)

---

## Additional Resources

### Official Documentation
- [NFTBan GitHub Repository](https://github.com/itcmsgr/nftban)
- [NFTBan Installation & Quick Start](README.md)
- [NFTBan Documentation Guide](docs/README.md)
- [nftables Wiki](https://wiki.nftables.org/)
- [Fail2ban Manual](https://fail2ban.readthedocs.io/)

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

**Documentation:**
- [Installation & Quick Start](README.md)
- [Documentation Guide](docs/README.md)
- [Architecture Guide](docs/ARCHITECTURE.md)
- Man page: `man nftban`

---

<p align="center">
  <b>Stay Secure! 🛡️</b><br>
  <sub>Remember: Security is a process, not a product.</sub>
</p>

<p align="center">
  <sub>Copyright © 2025 NFTBan Project. Licensed under Mozilla Public License 2.0 (MPL-2.0).</sub>
</p>
