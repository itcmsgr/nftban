# Ban System Guide

**How banning works in NFTBan v0.10.0**

This guide explains NFTBan's ban system: how IPs are banned, where they're stored, how priority works, and how to manage bans effectively.

---

## Table of Contents

- [Overview](#overview)
- [Ban System Architecture](#ban-system-architecture)
- [nftables Sets Explained](#nftables-sets-explained)
- [Ban Priority & Processing Order](#ban-priority--processing-order)
- [Ban Workflow](#ban-workflow)
- [Manual Banning](#manual-banning)
- [Automatic Banning (Fail2Ban)](#automatic-banning-fail2ban)
- [Whitelisting](#whitelisting)
- [Listing & Searching](#listing--searching)
- [Best Practices](#best-practices)
- [Troubleshooting](#troubleshooting)

---

## Overview

### How NFTBan Bans Work

NFTBan uses **nftables sets** to manage IP bans at the kernel level. When an IP is banned, it's added to a set, and nftables drops all packets from that IP **before they reach your applications**.

### Key Concepts

**3 nftables Tables:**
- `inet nftban_runtime` (Priority -310) - Temporary bans that survive reloads
- `ip nftban_v4` (Priority -300) - IPv4 static rules and bans
- `ip6 nftban_v6` (Priority -300) - IPv6 static rules and bans

**5 Types of Ban Sets per table:**
1. **Whitelist** - Trusted IPs (HIGHEST PRIORITY, cannot be banned)
2. **Temp Ban** - Temporary bans with automatic timeout
3. **User Blacklist** - Permanent manual bans
4. **System Blacklist** - Permanent system-detected bans
5. **Feeds** - Threat intelligence IPs (1M+ known bad actors)

### Why This Design?

✅ **Performance**: Kernel-level blocking (sub-microsecond decisions)
✅ **Persistence**: Runtime table survives nftables reloads
✅ **Priority**: Whitelist checked first (trusted IPs always pass)
✅ **Separation**: Temp vs permanent, manual vs automatic, user vs system

---

## Ban System Architecture

### 3-Table Structure (v0.10.0)

```
┌─────────────────────────────────────────────────────────────┐
│  Priority Order (Highest → Lowest)                          │
└─────────────────────────────────────────────────────────────┘

1. inet nftban_runtime (Priority -310)
   ├── temp_ban_v4 (timeout: 1h)
   └── temp_ban_v6 (timeout: 1h)
   Purpose: Fail2Ban temporary bans that SURVIVE reloads

2. ip nftban_v4 (Priority -300)
   ├── whitelist (interval set)
   ├── temp_ban (timeout: 1h)          ← Rarely used (runtime preferred)
   ├── user_blacklist (interval set)
   ├── system_blacklist (interval set)
   └── feeds (interval set)

3. ip6 nftban_v6 (Priority -300)
   └── (Same structure as v4)
```

### Packet Flow Through Ban System

```
Packet arrives from 192.0.2.50
        │
        ▼
┌─────────────────────────────────────────────────────────────┐
│  Table 1: inet nftban_runtime (Priority -310)               │
│  ─────────────────────────────────────────────────────────  │
│  Checked FIRST (highest priority)                           │
│                                                              │
│  Rule: ip saddr @temp_ban_v4 drop                           │
│  └─ Is 192.0.2.50 in temp_ban_v4?                          │
│      ├─ YES → DROP (packet discarded, done!)               │
│      └─ NO  → Continue to next table                        │
└─────────────────────────────────────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────────────────────────────┐
│  Table 2: ip nftban_v4 (Priority -300)                      │
│  ─────────────────────────────────────────────────────────  │
│  Main IPv4 firewall rules                                   │
│                                                              │
│  Rule 1: ct state {established,related} accept              │
│  └─ Established connection? → ACCEPT (bypass checks)        │
│                                                              │
│  Rule 2: iif lo accept                                      │
│  └─ Loopback interface? → ACCEPT (bypass checks)            │
│                                                              │
│  Rule 3: ip saddr @whitelist accept  ← HIGHEST PRIORITY!    │
│  └─ Is 192.0.2.50 in whitelist?                            │
│      ├─ YES → ACCEPT (trusted IP, bypass all bans!)        │
│      └─ NO  → Continue                                      │
│                                                              │
│  Rule 4: icmp type {echo-request} accept                    │
│  └─ ICMP ping? → ACCEPT                                     │
│                                                              │
│  Rule 5: tcp dport 22 accept                                │
│  └─ SSH port? → ACCEPT (for now)                           │
│                                                              │
│  Rule 6: ct state invalid drop                              │
│  └─ Invalid packet? → DROP                                  │
│                                                              │
│  Rule 7: ip saddr @temp_ban drop                            │
│  └─ Is 192.0.2.50 in temp_ban? → DROP                      │
│                                                              │
│  Rule 8: ip saddr @user_blacklist drop                      │
│  └─ Is 192.0.2.50 in user_blacklist? → DROP                │
│                                                              │
│  Rule 9: ip saddr @system_blacklist drop                    │
│  └─ Is 192.0.2.50 in system_blacklist? → DROP              │
│                                                              │
│  Rule 10: ip saddr @feeds drop                              │
│  └─ Is 192.0.2.50 in feeds (threat intel)? → DROP          │
└─────────────────────────────────────────────────────────────┘
        │
        ▼
   Result: ACCEPT or DROP
```

---

## nftables Sets Explained

### Set 1: Whitelist (Trusted IPs)

**Purpose**: IPs that are ALWAYS allowed, cannot be banned

**Location**:
- `ip nftban_v4 set whitelist`
- `ip6 nftban_v6 set whitelist`

**Properties**:
- **Type**: `ipv4_addr` / `ipv6_addr`
- **Flags**: `interval` (supports CIDR ranges)
- **Priority**: Checked BEFORE all bans (rule order)
- **Source**: `/etc/nftban/whitelist/user_whitelist.list`, system IPs

**Examples**:
```bash
# Single IP
192.168.1.100

# CIDR range
10.0.0.0/8

# Multiple entries
203.0.113.0/24
198.51.100.50
```

**Use cases**:
- Your home/office static IP
- Management networks
- Load balancers
- Monitoring systems
- VPN exit IPs

**Key feature**: Whitelisted IPs **cannot be banned**, even if they trigger Fail2Ban or are in threat feeds!

---

### Set 2: Temp Ban (Temporary Bans)

**Purpose**: Short-term bans that expire automatically

**Location** (2 copies!):
- `inet nftban_runtime set temp_ban_v4` (Priority -310, survives reloads) ← **PREFERRED**
- `ip nftban_v4 set temp_ban` (Priority -300, cleared on reload)

**Properties**:
- **Type**: `ipv4_addr` / `ipv6_addr`
- **Flags**: `timeout` (automatic expiration)
- **Default Timeout**: 1 hour (3600 seconds)
- **Source**: Fail2Ban actions, manual `nftban ban` commands

**Examples**:
```bash
# Entry with timeout
192.0.2.50 timeout 1h

# Entry in nftables list output:
192.0.2.50 expires 55m23s
```

**Use cases**:
- Fail2Ban automatic bans (SSH brute-force, etc.)
- Manual temporary bans (`nftban ban --temp`)
- Testing bans before making permanent

**Key features**:
- ✅ Automatic expiration (kernel manages timeout)
- ✅ Survives `nftban-apply` reloads (runtime table)
- ✅ No cleanup cron needed

---

### Set 3: User Blacklist (Permanent Manual Bans)

**Purpose**: Permanent bans added manually by administrators

**Location**:
- `ip nftban_v4 set user_blacklist`
- `ip6 nftban_v6 set user_blacklist`

**Properties**:
- **Type**: `ipv4_addr` / `ipv6_addr`
- **Flags**: `interval` (supports CIDR ranges)
- **Timeout**: None (permanent)
- **Source**: Manual `nftban ban --permanent`, config files

**Storage**:
- nftables set (active in kernel)
- `/etc/nftban/blacklist/user_blacklist.list` (persistent)

**Examples**:
```bash
# Single IP
198.51.100.25

# CIDR range
203.0.113.0/24

# Subnet
192.0.2.0/28
```

**Use cases**:
- Known attackers
- Confirmed malicious IPs
- Abusive users
- Banned countries (via CIDR)

**Key feature**: Persists across reboots, reloads, and updates

---

### Set 4: System Blacklist (Permanent System Bans)

**Purpose**: Permanent bans added automatically by NFTBan

**Location**:
- `ip nftban_v4 set system_blacklist`
- `ip6 nftban_v6 set system_blacklist`

**Properties**:
- **Type**: `ipv4_addr` / `ipv6_addr`
- **Flags**: `interval`
- **Timeout**: None (permanent)
- **Source**: System-detected threats (e.g., repeated port scans)

**Storage**:
- nftables set (active in kernel)
- `/etc/nftban/blacklist/system_blacklist.list` (persistent)

**Use cases**:
- Repeated offenders (escalated from temp bans)
- Port scan sources
- DDoS attack sources
- Automated threat detection

**Key difference from user_blacklist**: Added by **NFTBan automatically**, not manually by admins

---

### Set 5: Feeds (Threat Intelligence)

**Purpose**: Known malicious IPs from threat intelligence feeds

**Location**:
- `ip nftban_v4 set feeds`
- `ip6 nftban_v6 set feeds`

**Properties**:
- **Type**: `ipv4_addr` / `ipv6_addr`
- **Flags**: `interval` (optimized for CIDR ranges)
- **Timeout**: None (until next feed update)
- **Source**: 14+ threat intelligence feeds (Spamhaus, FireHOL, etc.)

**Scale**:
- **1,000,000+ IPs** from all feeds combined
- Parsed by **Go binary** (10-60x faster than bash)
- Updated via `nftban feeds update`

**Storage**:
- nftables set (active in kernel)
- `/var/lib/nftban/feeds/merged_v4.txt` (cache)

**Use cases**:
- Block known botnets
- Block spam sources
- Block malware C&C servers
- Block Tor exit nodes (if desired)

**Key feature**: Massive scale (1M+ IPs) with minimal performance impact thanks to nftables interval sets

---

## Ban Priority & Processing Order

### Priority Rules

1. **✅ Whitelist WINS** - Whitelisted IPs **always pass**, regardless of bans
2. **🔴 Runtime temp_ban checked FIRST** - Priority -310 (before main tables)
3. **🟡 Static bans checked in order** - temp_ban → user_blacklist → system_blacklist → feeds

### Example Scenarios

**Scenario 1: Whitelisted IP in Threat Feed**
```
IP: 203.0.113.100
Whitelist: ✅ YES
Feeds: ✅ YES (Spamhaus DROP)

Result: ACCEPT (whitelist wins!)
```

**Scenario 2: Temp Ban + Permanent Ban**
```
IP: 192.0.2.50
Runtime temp_ban: ✅ YES (expires in 30 minutes)
User blacklist: ✅ YES (permanent)

Result: DROP (temp ban checked first, drops immediately)
After 30 minutes: DROP (still in user blacklist)
```

**Scenario 3: Not Banned Anywhere**
```
IP: 198.51.100.10
Whitelist: ❌ NO
All bans: ❌ NO
Feeds: ❌ NO

Result: Evaluated against port rules
  - SSH port 22? → ACCEPT
  - Random port? → DROP (default policy)
```

---

## Ban Workflow

### Manual Ban Workflow

```
User: nftban ban 192.0.2.50
        │
        ▼
┌──────────────────────────────────────┐
│  Step 1: Validation                  │
│  ├─ Parse IP address                │
│  ├─ Validate format                 │
│  │   (Supports IPv4, IPv6, CIDR)    │
│  └─ Reject if invalid               │
└──────────┬───────────────────────────┘
           │
           ▼
┌──────────────────────────────────────┐
│  Step 2: Safety Checks               │
│  ├─ Is IP in whitelist?             │
│  │   └─ YES → REJECT (cannot ban!)  │
│  ├─ Is IP current SSH connection?   │
│  │   └─ YES → REJECT (lockout!)     │
│  └─ Is IP already banned?           │
│      └─ YES → SKIP (idempotent)     │
└──────────┬───────────────────────────┘
           │
           ▼
┌──────────────────────────────────────┐
│  Step 3: Determine Ban Type          │
│  ├─ Temporary ban (default)?        │
│  │   └─ Add to: runtime temp_ban_v4│
│  │      with timeout (1h)           │
│  │                                  │
│  └─ Permanent ban (--permanent)?    │
│      ├─ Add to: user_blacklist     │
│      └─ Write to file for persist   │
└──────────┬───────────────────────────┘
           │
           ▼
┌──────────────────────────────────────┐
│  Step 4: Apply to nftables           │
│  └─ nft add element inet             │
│      nftban_runtime temp_ban_v4      │
│      { 192.0.2.50 timeout 1h }       │
└──────────┬───────────────────────────┘
           │
           ▼
┌──────────────────────────────────────┐
│  Step 5: Logging                     │
│  └─ /var/log/nftban/operations.log  │
│      [2025-10-28 14:30:15] BAN       │
│      192.0.2.50 (temp, 1h)           │
└──────────────────────────────────────┘
           │
           ▼
   IP is now BLOCKED at kernel level
```

---

## Manual Banning

### Ban an IP (Temporary)

Default: 1-hour temporary ban

```bash
sudo nftban ban 192.0.2.50
```

**Output:**
```
✓ Validating IP: 192.0.2.50
✓ Safety check: Not whitelisted
✓ Safety check: Not current SSH connection
✓ Added to temp_ban (expires in 1 hour)

IP 192.0.2.50 banned successfully (temporary, 1h)
```

### Ban an IP (Permanent)

```bash
sudo nftban ban 192.0.2.50 --permanent
```

**Output:**
```
✓ Validating IP: 192.0.2.50
✓ Safety check: Not whitelisted
✓ Added to user_blacklist (permanent)
✓ Written to /etc/nftban/blacklist/user_blacklist.list

IP 192.0.2.50 banned permanently
```

### Ban with Reason

```bash
sudo nftban ban 192.0.2.50 --reason "SSH brute force attack"
```

Reason is logged to `/var/log/nftban/operations.log`

### Ban a CIDR Range

```bash
# Ban entire subnet
sudo nftban ban 203.0.113.0/24 --permanent

# Ban ISP range
sudo nftban ban 198.51.100.0/22 --permanent
```

### Ban with Custom Timeout

```bash
# 30-minute ban
sudo nftban ban 192.0.2.50 --timeout 30m

# 6-hour ban
sudo nftban ban 192.0.2.50 --timeout 6h

# 7-day ban
sudo nftban ban 192.0.2.50 --timeout 7d
```

---

## Automatic Banning (Fail2Ban)

### How Fail2Ban Integration Works

```
1. Fail2Ban monitors logs (/var/log/auth.log, etc.)
2. Detects patterns (failed SSH login, etc.)
3. Threshold exceeded (5 failures in 10 minutes)
4. Executes action: nftban ban <IP>
5. IP added to runtime temp_ban (1h default)
6. After timeout, IP auto-unbanned
```

### Enable Fail2Ban Integration

```bash
sudo nftban fail2ban sync
```

**What it does:**
- Discovers all active Fail2Ban jails
- Creates NFTBan actions for each jail
- Configures automatic temp bans

### Check Fail2Ban Status

```bash
sudo nftban fail2ban status
```

**Output:**
```
Fail2Ban Status
═══════════════

Active Jails: 3

1. sshd
   Status: ACTIVE
   Failed: 234
   Banned: 12

2. nginx-http-auth
   Status: ACTIVE
   Failed: 45
   Banned: 3

3. wordpress
   Status: ACTIVE
   Failed: 89
   Banned: 7

Total Banned by Fail2Ban: 22 IPs
```

### View Fail2Ban Bans

```bash
sudo fail2ban-client status sshd
```

---

## Whitelisting

### Why Whitelist?

Whitelisted IPs:
- ✅ **Cannot be banned** (highest priority)
- ✅ Bypass all ban checks
- ✅ Always have access
- ✅ Protected from Fail2Ban false positives

### Add to Whitelist

```bash
# Single IP
sudo nftban whitelist add 203.0.113.100

# CIDR range
sudo nftban whitelist add 192.168.1.0/24

# With comment
sudo nftban whitelist add 198.51.100.50 --comment "Office static IP"
```

### Remove from Whitelist

```bash
sudo nftban whitelist remove 203.0.113.100
```

### List Whitelist

```bash
sudo nftban whitelist list
```

**Output:**
```
Whitelist (Trusted IPs)
═══════════════════════

IPv4:
  192.168.1.0/24      # Local network
  203.0.113.100       # Office static IP
  198.51.100.50       # VPN exit IP

IPv6:
  2001:db8::/32       # Office IPv6 prefix
  fe80::/10           # Link-local (auto-added)

Total: 5 entries
```

### Auto-Whitelist System IPs

NFTBan automatically discovers and whitelists your server's own IPs:

```bash
sudo nftban whitelist-system discover
```

**Output:**
```
Discovering system IPs...

Found:
  ✓ 10.0.1.50 (eth0)
  ✓ 192.168.1.100 (eth1)
  ✓ 2001:db8::1 (eth0)

Added to whitelist: 3 IPs
```

---

## Listing & Searching

### List All Banned IPs

```bash
sudo nftban list banned
```

**Output:**
```
Banned IPs
══════════

Temporary Bans (expire automatically):
  192.0.2.50         expires in 45m (Fail2Ban: sshd)
  198.51.100.25      expires in 12m (Manual)

Permanent Bans (user):
  203.0.113.100      (Manual: confirmed attacker)
  192.0.2.0/28       (Manual: hostile subnet)

Permanent Bans (system):
  198.51.100.75      (Port scan detected)

Threat Feeds:
  1,234,567 IPs from 14 feeds

Total Banned: 1,234,571 IPs
```

### List by Type

```bash
# Only temp bans
sudo nftban list temp

# Only permanent bans
sudo nftban list permanent

# Only feeds
sudo nftban list feeds

# Only whitelist
sudo nftban list whitelist
```

### Search for Specific IP

```bash
sudo nftban search 192.0.2.50
```

**Output:**
```
Searching for: 192.0.2.50

✓ Found in: temp_ban (runtime)
  Type: Temporary ban
  Expires: 45 minutes
  Reason: Fail2Ban: sshd
  Added: 2025-10-28 14:30:15

✓ Found in: SPAMHAUS_DROP feed
  Feed: SPAMHAUS_DROP
  Category: Known spam source

✗ Not in: whitelist
✗ Not in: user_blacklist
✗ Not in: system_blacklist

Status: BLOCKED (2 sources)
```

### Check if IP is Banned

```bash
sudo nftban check 192.0.2.50
```

**Output:**
```
IP: 192.0.2.50
Status: BANNED (temporary)
Expires: 45 minutes
Reason: Fail2Ban: sshd
```

---

## Best Practices

### 1. Whitelist Before Banning

**Always whitelist your management IPs first:**

```bash
# Your home IP
sudo nftban whitelist add 203.0.113.100 --comment "My home IP"

# Office network
sudo nftban whitelist add 198.51.100.0/24 --comment "Office network"

# VPN exit IPs
sudo nftban whitelist add 192.0.2.50 --comment "VPN exit"
```

### 2. Use Temporary Bans by Default

**Start with temp bans, escalate to permanent if needed:**

```bash
# First offense: temp ban (1h)
sudo nftban ban 192.0.2.50

# Repeated offender: longer temp ban
sudo nftban ban 192.0.2.50 --timeout 24h

# Confirmed attacker: permanent ban
sudo nftban ban 192.0.2.50 --permanent
```

### 3. Monitor Bans Regularly

**Check for false positives:**

```bash
# Daily check
sudo nftban list banned | head -20

# Watch real-time
sudo tail -f /var/log/nftban/operations.log
```

### 4. Document Permanent Bans

**Add comments to permanent bans:**

```bash
sudo nftban ban 203.0.113.100 --permanent \
  --reason "Confirmed attacker, ticket #12345"
```

### 5. Review Whitelist Periodically

**Remove outdated entries:**

```bash
# List whitelist
sudo nftban whitelist list

# Remove old VPN that's no longer used
sudo nftban whitelist remove 192.0.2.50
```

---

## Troubleshooting

### Issue: Can't Ban IP

**Problem**: `sudo nftban ban 192.0.2.50` fails

**Possible causes:**
1. IP is whitelisted
2. IP is your current SSH connection
3. Invalid IP format

**Solution:**
```bash
# Check if whitelisted
sudo nftban whitelist list | grep 192.0.2.50

# Check SSH connection
echo $SSH_CONNECTION

# Validate IP format
sudo nftban check 192.0.2.50
```

### Issue: IP Not Getting Blocked

**Problem**: Banned IP still has access

**Solution:**
```bash
# 1. Verify ban was added
sudo nftban list banned | grep 192.0.2.50

# 2. Check nftables sets directly
sudo nft list set inet nftban_runtime temp_ban_v4
sudo nft list set ip nftban_v4 user_blacklist

# 3. Check if IP is whitelisted (overrides bans!)
sudo nftban whitelist list | grep 192.0.2.50

# 4. Check nftables rules are active
sudo nft list ruleset | grep nftban
```

### Issue: Legitimate User Banned

**Problem**: False positive, need to unban immediately

**Solution:**
```bash
# Quick unban
sudo nftban unban 192.0.2.50

# Add to whitelist to prevent future bans
sudo nftban whitelist add 192.0.2.50 --comment "Legit user, false positive"
```

### Issue: Too Many Temp Bans

**Problem**: Disk/memory filling up with temp bans

**Solution**: Temp bans auto-expire, but if you need immediate cleanup:
```bash
# Flush all temp bans (CAREFUL!)
sudo nft flush set inet nftban_runtime temp_ban_v4
sudo nft flush set inet nftban_runtime temp_ban_v6

# Or wait for natural expiration (recommended)
```

---

## Summary

### Quick Reference

```bash
# Ban (temporary, 1h)
sudo nftban ban <IP>

# Ban (permanent)
sudo nftban ban <IP> --permanent

# Ban with reason
sudo nftban ban <IP> --reason "..."

# Ban CIDR range
sudo nftban ban <CIDR> --permanent

# Unban
sudo nftban unban <IP>

# Whitelist (cannot be banned)
sudo nftban whitelist add <IP>

# List banned IPs
sudo nftban list banned

# Search for IP
sudo nftban search <IP>

# Check IP status
sudo nftban check <IP>
```

### Key Takeaways

1. **Whitelist = Highest Priority** - Whitelisted IPs cannot be banned
2. **Runtime Table = Persistent** - Temp bans survive nftables reloads
3. **Automatic Expiration** - Temp bans expire automatically (no cron needed)
4. **Separation** - Temp vs permanent, manual vs automatic, user vs system
5. **Performance** - Kernel-level blocking (sub-microsecond decisions)
6. **Scale** - 1M+ threat feed IPs with minimal performance impact

---

**Next**: [Health Diagnostics Guide →](health-diagnostics.md)

**See also**:
- [Security Profiles](security-profiles.md) - Choose security profile
- [Threat Feeds](feeds.md) - Manage threat intelligence
- [Architecture](../concepts/architecture.md) - How NFTBan works
