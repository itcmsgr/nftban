# Security Profiles Guide

**Choose the right security profile for your server**

NFTBan includes 6 pre-configured security profiles optimized for different server types and security requirements. This guide helps you choose and manage the right profile.

---

## Table of Contents

- [Overview](#overview)
- [Available Profiles](#available-profiles)
- [Profile Comparison](#profile-comparison)
- [Managing Profiles](#managing-profiles)
- [Customizing Profiles](#customizing-profiles)
- [Profile Details](#profile-details)
- [Best Practices](#best-practices)

---

## Overview

### What are Security Profiles?

Security profiles are **pre-configured sets of security rules** that enable or disable specific protections based on your server's purpose. Instead of manually configuring dozens of options, you choose a profile that matches your needs.

### What Profiles Control

Each profile configures:

- **DDoS Protection** - SYN flood, connection limits, port flood, ICMP flood
- **Port Scan Detection** - Thresholds, auto-ban, monitoring scope
- **Connection Limits** - Per-service concurrent connections
- **Rate Limiting** - Request rates per protocol
- **Auto-Ban Behavior** - Temporary vs permanent, ban duration

### Why Use Profiles?

✅ **Quick Setup** - One command instead of dozens of configuration changes
✅ **Tested Configurations** - Pre-tested for specific use cases
✅ **Easy Switching** - Change security posture in seconds
✅ **Consistent** - All settings coordinated properly

---

## Available Profiles

NFTBan includes **6 security profiles**:

```
┌────────────────────────────────────────────────────────────┐
│  Profile         Best For                  Security Level  │
│  ─────────────── ──────────────────────── ───────────────  │
│  maximum         High-value targets       ████████████ 10  │
│  web-server      Nginx, Apache            ████████░░░░  8  │
│  mail-server     Postfix, Dovecot         ████████░░░░  8  │
│  database        MySQL, PostgreSQL        ███████░░░░░  7  │
│  mixed           Multi-purpose servers     ██████░░░░░░  6  │
│  development     Dev/test environments     ██░░░░░░░░░░  2  │
└────────────────────────────────────────────────────────────┘
```

### List Profiles

```bash
sudo nftban profile list
```

**Output:**
```
Available Security Profiles:
════════════════════════════

1. maximum        - Maximum Security (All protections enabled)
2. web-server     - Web Server (High HTTP/HTTPS traffic)
3. mail-server    - Mail Server (SMTP/IMAP/POP3 optimized)
4. database       - Database Server (MySQL/PostgreSQL)
5. mixed          - Mixed Services (Balanced approach)
6. development    - Development Mode (Minimal restrictions)
```

---

## Profile Comparison

### Quick Comparison Table

| Feature | maximum | web-server | mail-server | database | mixed | development |
|---------|---------|-----------|-------------|----------|-------|-------------|
| **DDoS Protection** |  |  |  |  |  |  |
| SYN Flood | ✅ Aggressive | ❌ Off¹ | ✅ Moderate | ✅ Moderate | ✅ Balanced | ❌ Off |
| Connection Limits | ✅ Very Strict | ✅ High Web | ✅ High Mail | ✅ Moderate | ✅ Balanced | ❌ Off |
| Port Flood | ✅ Aggressive | ✅ Web Focused | ✅ Mail Focused | ✅ DB Focused | ✅ Balanced | ❌ Off |
| ICMP Flood | ✅ Strict | ✅ Standard | ✅ Standard | ✅ Standard | ✅ Standard | ❌ Off |
| **Port Scan Detection** |  |  |  |  |  |  |
| Enabled | ✅ Yes | ✅ Yes | ✅ Yes | ✅ Yes | ✅ Yes | ❌ No |
| Threshold | 3 ports/1min | 10 ports/5min | 8 ports/3min | 5 ports/2min | 10 ports/5min | N/A |
| Auto-Ban | ✅ Permanent | ✅ 1 hour | ✅ 2 hours | ✅ 6 hours | ✅ 1 hour | N/A |
| **Connection Limits²** |  |  |  |  |  |  |
| SSH | 3 | 5 | 5 | 3 | 5 | ∞ |
| HTTP | 20 | 50 | 10 | 10 | 30 | ∞ |
| HTTPS | 20 | 50 | 10 | 10 | 30 | ∞ |
| SMTP | 3 | 0³ | 20 | 0³ | 5 | ∞ |
| MySQL | 2 | 0³ | 0³ | 15 | 5 | ∞ |

¹ SYN Flood protection disabled for web servers to avoid false positives during traffic spikes. Enable manually during attacks.
² Per source IP concurrent connections
³ 0 = Service disabled for this profile (port blocked)

---

## Managing Profiles

### View Current Profile

```bash
sudo nftban profile show
```

**Output:**
```
Current Security Profile
════════════════════════

Profile: mixed
Description: Mixed Services - Balanced approach
Applied: 2025-10-28 14:23:15

Key Settings:
  DDoS Protection: ENABLED
  Port Scan Detection: ENABLED
  Auto-Ban: ENABLED (temporary, 1 hour)

Configuration: /etc/nftban/nftban.conf.local
```

### Apply a Profile

```bash
sudo nftban profile set <profile-name>
```

**Example:**
```bash
sudo nftban profile set web-server
```

**What happens:**
1. ✓ Backs up current configuration
2. ✓ Copies profile to `/etc/nftban/nftban.conf.local`
3. ✓ Records profile name in `/var/lib/nftban/profile.current`
4. ✓ Shows summary of key settings

**Output:**
```
⏳ Applying profile: web-server

  📋 Backed up existing configuration
  ✅ Profile applied: web-server
  📁 Configuration: /etc/nftban/nftban.conf.local

Profile: Web Server - High HTTP/HTTPS traffic

Key Settings:
  DDoS Protection: ENABLED
  Port Scan Detection: ENABLED
  Auto-Ban: ENABLED (temporary, 1 hour)

✅ Profile applied successfully!

⚠️  IMPORTANT: Apply firewall rules to activate:
    sudo nftban-apply
```

### Apply Firewall Rules

After changing profiles, **apply rules with commit-confirm**:

```bash
sudo nftban-apply
```

Test connectivity, then confirm:
```bash
sudo nftban-confirm
```

---

## Customizing Profiles

### Option 1: Modify Profile Settings (Recommended)

Edit your local configuration:
```bash
sudo nano /etc/nftban/nftban.conf.local
```

**Example**: Increase SSH connection limit:
```bash
# Before (profile default)
DDOS_CONNLIMIT_SSH="5"

# After (your override)
DDOS_CONNLIMIT_SSH="10"
```

Save and apply:
```bash
sudo nftban-apply
sudo nftban-confirm
```

### Option 2: Module-Specific Overrides

Override specific module settings:
```bash
sudo nano /etc/nftban/conf.d/ddos.conf.local
```

**Example**: Disable SYN flood for web server:
```bash
# Override just SYN flood protection
DDOS_SYNFLOOD_ENABLED="false"
```

**Configuration Precedence:**
```
Highest → Lowest:
1. /etc/nftban/conf.d/*.conf.local  (module overrides)
2. /etc/nftban/nftban.conf.local    (profile settings)
3. /etc/nftban/conf.d/*.conf        (module defaults)
4. /etc/nftban/nftban.conf          (global defaults)
```

Your `.local` files are **NEVER overwritten** by updates!

---

## Profile Details

### 1. Maximum Security (Paranoid Mode)

**Best for**: High-value targets, sensitive servers, paranoid administrators

```yaml
Use cases:
  - Financial servers
  - Healthcare systems (HIPAA compliance)
  - Government servers
  - Honeypots
  - High-security environments

Features:
  ✓ All protections enabled
  ✓ Very strict connection limits
  ✓ Aggressive rate limiting
  ✓ Permanent bans for port scans
  ✓ Only 3 ports trigger scan detection

Trade-offs:
  ⚠️  May block legitimate traffic during spikes
  ⚠️  Requires careful monitoring
  ⚠️  Not suitable for high-traffic servers
```

**Apply:**
```bash
sudo nftban profile set maximum
```

**Connection Limits:**
- SSH: 3 concurrent (very low)
- HTTP: 20 concurrent
- HTTPS: 20 concurrent
- All other services: 2-3 concurrent

**Port Scan:**
- Threshold: 3 ports in 1 minute
- Action: **Permanent ban** immediately

---

### 2. Web Server Profile

**Best for**: Nginx, Apache, API servers, content delivery

```yaml
Use cases:
  - Web applications
  - REST APIs
  - Static content servers
  - Reverse proxies
  - CDN origins

Features:
  ✓ High HTTP/HTTPS connection limits
  ✓ Optimized for web traffic patterns
  ✓ Port flood protection for web ports
  ✓ Minimal mail/DB restrictions
  ✓ SYN flood disabled (enable during attacks)

Trade-offs:
  ⚠️  SYN flood protection off by default
  ⚠️  Higher scan detection threshold
```

**Apply:**
```bash
sudo nftban profile set web-server
```

**Connection Limits:**
- SSH: 5 concurrent (management only)
- HTTP: **50 concurrent** (high!)
- HTTPS: **50 concurrent** (high!)
- SMTP/FTP: Disabled (ports blocked)
- MySQL: Disabled (use remote DB)

**Port Scan:**
- Threshold: 10 ports in 5 minutes (relaxed)
- Action: Temporary ban (1 hour)

**Tuning for High Traffic:**
```bash
# Edit /etc/nftban/nftban.conf.local
DDOS_CONNLIMIT_HTTP="100"      # Increase to 100
DDOS_CONNLIMIT_HTTPS="100"     # Increase to 100
DDOS_PORTFLOOD_RATE="2000/second"  # Increase rate limit
```

---

### 3. Mail Server Profile

**Best for**: Postfix, Dovecot, Exim, SMTP/IMAP/POP3 servers

```yaml
Use cases:
  - Email servers
  - Webmail backends
  - Mail relays
  - IMAP/POP3 servers

Features:
  ✓ High mail protocol connection limits
  ✓ Optimized SMTP/IMAP/POP3 rate limits
  ✓ Moderate port scan detection
  ✓ Greylisting-friendly settings

Trade-offs:
  ⚠️  May need tuning for mass mailers
  ⚠️  Adjust for legitimate bulk senders
```

**Apply:**
```bash
sudo nftban profile set mail-server
```

**Connection Limits:**
- SSH: 5 concurrent
- HTTP: 10 concurrent (webmail)
- SMTP: **20 concurrent** (high!)
- IMAP: **20 concurrent** (high!)
- POP3: **15 concurrent**

**Port Scan:**
- Threshold: 8 ports in 3 minutes
- Action: Temporary ban (2 hours)

**Integration with SpamAssassin/Amavis:**
```bash
# Whitelist mail scanners
sudo nftban whitelist add 127.0.0.1
sudo nftban whitelist add ::1
```

---

### 4. Database Server Profile

**Best for**: MySQL, PostgreSQL, MariaDB, MongoDB

```yaml
Use cases:
  - Database servers
  - Data warehouses
  - Analytics databases
  - Backend data stores

Features:
  ✓ Optimized DB connection limits
  ✓ Protection for common DB ports
  ✓ Stricter port scan detection
  ✓ Lower web/mail limits (not primary purpose)

Trade-offs:
  ⚠️  May block connection poolers
  ⚠️  Requires whitelisting app servers
```

**Apply:**
```bash
sudo nftban profile set database
```

**Connection Limits:**
- SSH: 3 concurrent
- MySQL: **15 concurrent**
- PostgreSQL: **15 concurrent**
- MongoDB: **10 concurrent**
- HTTP: 10 concurrent (admin panels)

**Port Scan:**
- Threshold: 5 ports in 2 minutes (strict)
- Action: Temporary ban (6 hours)

**Whitelist Application Servers:**
```bash
# Add app servers to whitelist
sudo nftban whitelist add 192.168.1.0/24
```

---

### 5. Mixed Services Profile (Recommended Default)

**Best for**: General-purpose servers, VPS, multi-service servers

```yaml
Use cases:
  - Multi-purpose servers
  - VPS hosting
  - Development/staging servers
  - Mixed workloads

Features:
  ✓ Balanced protection for all services
  ✓ Moderate connection limits
  ✓ Suitable for most scenarios
  ✓ Good default choice

Trade-offs:
  ⚠️  Not optimized for any specific service
  ⚠️  May need tuning for specialized workloads
```

**Apply:**
```bash
sudo nftban profile set mixed
```

**Connection Limits:**
- SSH: 5 concurrent
- HTTP: 30 concurrent
- HTTPS: 30 concurrent
- SMTP: 5 concurrent
- MySQL: 5 concurrent
- All other services: Balanced

**Port Scan:**
- Threshold: 10 ports in 5 minutes (moderate)
- Action: Temporary ban (1 hour)

**Why This is the Default:**
- ✓ Protects against common attacks
- ✓ Doesn't break legitimate traffic
- ✓ Easy to tune for specific needs
- ✓ Good starting point

---

### 6. Development Profile

**Best for**: Development servers, testing environments, local VMs

```yaml
Use cases:
  - Development environments
  - Testing servers
  - Local VMs
  - CI/CD builders
  - Learning environments

Features:
  ✓ Minimal restrictions
  ✓ No connection limits
  ✓ No port scan detection
  ✓ No DDoS protection
  ✓ Easy debugging

Trade-offs:
  ⚠️  Provides NO real protection
  ⚠️  DO NOT use in production!
  ⚠️  Suitable for trusted networks only
```

**Apply:**
```bash
sudo nftban profile set development
```

**Connection Limits:**
- All services: **Unlimited**

**Protections:**
- DDoS: Disabled
- Port Scan: Disabled
- Rate Limiting: Disabled

**⚠️  WARNING**: This profile provides minimal security. Only use in trusted environments!

---

## Best Practices

### 1. Start Conservative

**Recommendation**: Start with `mixed` profile, then adjust:

```bash
# Start with mixed
sudo nftban profile set mixed

# Monitor for 24-48 hours
sudo nftban health check
sudo tail -f /var/log/nftban/operations.log

# Adjust if needed
# - Too restrictive? → Switch to development temporarily
# - Need more security? → Switch to maximum
# - Specific service? → Switch to web-server/mail-server/database
```

### 2. Monitor After Changes

After applying a profile, monitor for false positives:

```bash
# Watch operations log
sudo tail -f /var/log/nftban/operations.log

# Check banned IPs
sudo nftban list banned

# Check Fail2Ban status
sudo nftban fail2ban status
```

### 3. Whitelist Before Tightening

**Before switching to stricter profiles**, whitelist critical IPs:

```bash
# Whitelist your management IPs
sudo nftban whitelist add 203.0.113.0/24

# Whitelist monitoring systems
sudo nftban whitelist add 198.51.100.50

# Whitelist load balancers
sudo nftban whitelist add 192.0.2.10
```

### 4. Test With Commit-Confirm

**Always use commit-confirm** when changing profiles:

```bash
# Apply profile
sudo nftban profile set maximum

# Apply with safety
sudo nftban-apply

# Test from another terminal
ssh user@server

# If OK, confirm
sudo nftban-confirm

# If broken, wait for auto-rollback (5 min)
```

### 5. Document Your Customizations

Keep notes on your changes:

```bash
# Add comments to your .local file
sudo nano /etc/nftban/nftban.conf.local

# Example:
# Increased SSH limit for team access (2025-10-28)
DDOS_CONNLIMIT_SSH="10"

# Disabled SYN flood during peak traffic (2025-10-29)
DDOS_SYNFLOOD_ENABLED="false"
```

---

## Common Scenarios

### Scenario 1: Web Server Getting DDoS

```bash
# Current: web-server profile
# Problem: Under DDoS attack

# Enable SYN flood protection (disabled by default in web-server)
sudo nano /etc/nftban/nftban.conf.local

# Add:
DDOS_SYNFLOOD_ENABLED="true"
DDOS_SYNFLOOD_RATE="50/second"  # Strict during attack

# Apply
sudo nftban-apply
sudo nftban-confirm

# After attack subsides, disable again
```

### Scenario 2: Database Server False Positives

```bash
# Current: database profile
# Problem: Connection pooler getting blocked

# Whitelist the pooler
sudo nftban whitelist add 192.168.1.100

# Or increase connection limit
sudo nano /etc/nftban/nftban.conf.local

# Add:
DDOS_CONNLIMIT_MYSQL="30"  # Increased from 15

# Apply
sudo nftban-apply
sudo nftban-confirm
```

### Scenario 3: Moving From Dev to Production

```bash
# Current: development profile
# Goal: Production-ready security

# Step 1: Switch to mixed (test first!)
sudo nftban profile set mixed
sudo nftban-apply
# Test thoroughly...
sudo nftban-confirm

# Step 2: Monitor for 48 hours
sudo tail -f /var/log/nftban/operations.log

# Step 3: If stable, switch to stricter profile
sudo nftban profile set maximum  # or web-server/mail-server
sudo nftban-apply
sudo nftban-confirm
```

---

## Troubleshooting

### Profile Won't Apply

**Problem**: `sudo nftban profile set maximum` shows error

**Solution**:
```bash
# Check profiles directory exists
ls -la /usr/share/nftban/profiles/

# Check profile file exists
ls -la /usr/share/nftban/profiles/maximum.conf

# Check permissions
sudo chown -R root:root /usr/share/nftban/profiles/
sudo chmod 644 /usr/share/nftban/profiles/*.conf
```

### Too Restrictive - Legitimate Traffic Blocked

**Problem**: Users complain about connection errors

**Solution**:
```bash
# Check operations log for blocks
sudo tail -100 /var/log/nftban/operations.log | grep DROP

# Identify false positives
# Option 1: Whitelist the IPs
sudo nftban whitelist add <IP>

# Option 2: Switch to more permissive profile
sudo nftban profile set mixed

# Option 3: Increase connection limits
sudo nano /etc/nftban/nftban.conf.local
# Increase DDOS_CONNLIMIT_* values
```

### Can't Confirm Rules After Profile Change

**Problem**: Locked out after `nftban-apply`

**Solution**:
```bash
# Wait 5 minutes for automatic rollback
# Or access via console/IPMI:
sudo nftban-rollback --force
```

---

## Summary

### Quick Reference

| Need | Profile | Command |
|------|---------|---------|
| Maximum security | `maximum` | `sudo nftban profile set maximum` |
| Web server | `web-server` | `sudo nftban profile set web-server` |
| Mail server | `mail-server` | `sudo nftban profile set mail-server` |
| Database | `database` | `sudo nftban profile set database` |
| General purpose | `mixed` | `sudo nftban profile set mixed` |
| Development | `development` | `sudo nftban profile set development` |

### Decision Tree

```
What type of server?
│
├─ High-value target, maximum security needed?
│  └─ Use: maximum
│
├─ Primarily serving web traffic (HTTP/HTTPS)?
│  └─ Use: web-server
│
├─ Primarily handling email (SMTP/IMAP/POP3)?
│  └─ Use: mail-server
│
├─ Primarily running databases (MySQL/PostgreSQL)?
│  └─ Use: database
│
├─ Multi-purpose or unsure?
│  └─ Use: mixed (recommended default)
│
└─ Development/testing environment?
   └─ Use: development
```

---

**Next**: [Health Diagnostics Guide →](health-diagnostics.md)

**See also**:
- [Ban System Guide](ban-system.md) - Manual IP banning
- [Architecture](../concepts/architecture.md) - How NFTBan works
- [CLI Reference](../reference/cli.md) - All commands
