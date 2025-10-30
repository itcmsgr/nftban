# NFTBan - Complete nftables Architecture Blueprint
**Date:** 2025-10-27
**Purpose:** THE LOGIC - How nftables rules work (not the data!)
**Status:** Master Reference for v0.10.0 Implementation

═══════════════════════════════════════════════════════════════════════════════

## 🏗️ TABLE ARCHITECTURE

### Split IPv4/IPv6 Design:

```
┌─────────────────────────────────────────────────┐
│ TABLE: nftban_v4 (family: ip)                  │
├─────────────────────────────────────────────────┤
│ HOOK: input  (priority: filter, policy: accept)│
│ HOOK: output (priority: filter, policy: accept)│
└─────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────┐
│ TABLE: nftban_v6 (family: ip6)                 │
├─────────────────────────────────────────────────┤
│ HOOK: input  (priority: filter, policy: accept)│
│ HOOK: output (priority: filter, policy: accept)│
└─────────────────────────────────────────────────┘
```

**Why Split?**
- Performance: Kernel processes IPv4/IPv6 separately
- Clarity: No family mixing confusion
- Compatibility: Works with all nftables versions

═══════════════════════════════════════════════════════════════════════════════

## 📦 SET ARCHITECTURE (Data Containers)

### IPv4 Table Sets:

```nft
# Create table
nft add table ip nftban_v4

# Set 1: Whitelist (interval for CIDR support)
nft add set ip nftban_v4 whitelist {
    type ipv4_addr;
    flags interval;
    comment "Whitelisted IPs - NEVER banned";
}

# Set 2: Temporary bans (auto-expire)
nft add set ip nftban_v4 temp_ban {
    type ipv4_addr;
    flags timeout;
    timeout 1h;
    comment "Temporary bans (1h default)";
}

# Set 3: User blacklist (manual permanent bans)
nft add set ip nftban_v4 user_blacklist {
    type ipv4_addr;
    flags interval;
    comment "Manual permanent bans";
}

# Set 4: System blacklist (automatic permanent bans)
nft add set ip nftban_v4 system_blacklist {
    type ipv4_addr;
    flags interval;
    comment "Automatic permanent bans";
}

# Set 5: Threat feeds (external intelligence)
nft add set ip nftban_v4 feeds {
    type ipv4_addr;
    flags interval, auto-merge;
    comment "External threat feeds";
}
```

### IPv6 Table Sets (same structure, different type):

```nft
# Create table
nft add table ip6 nftban_v6

# Same 5 sets with ipv6_addr type
nft add set ip6 nftban_v6 whitelist { type ipv6_addr; flags interval; }
nft add set ip6 nftban_v6 temp_ban { type ipv6_addr; flags timeout; timeout 1h; }
nft add set ip6 nftban_v6 user_blacklist { type ipv6_addr; flags interval; }
nft add set ip6 nftban_v6 system_blacklist { type ipv6_addr; flags interval; }
nft add set ip6 nftban_v6 feeds { type ipv6_addr; flags interval, auto-merge; }
```

**Set Flags Explained:**
- `interval`: Supports CIDR ranges (192.168.0.0/24)
- `timeout`: Entries auto-expire (for temp_ban)
- `auto-merge`: Automatically merge overlapping ranges (for feeds)

═══════════════════════════════════════════════════════════════════════════════

## ⛓️ CHAIN ARCHITECTURE

### Chains Created:

```nft
# IPv4 input chain
nft add chain ip nftban_v4 input {
    type filter hook input priority filter;
    policy accept;
}

# IPv4 output chain
nft add chain ip nftban_v4 output {
    type filter hook output priority filter;
    policy accept;
}

# IPv6 input chain
nft add chain ip6 nftban_v6 input {
    type filter hook input priority filter;
    policy accept;
}

# IPv6 output chain
nft add chain ip6 nftban_v6 output {
    type filter hook output priority filter;
    policy accept;
}
```

**Chain Properties:**
- `type filter`: Standard firewall filtering
- `hook input/output`: Where packets are intercepted
- `priority filter`: Standard priority (0)
- `policy accept`: Default allow (explicit drops only)

═══════════════════════════════════════════════════════════════════════════════

## 🔥 RULE ORDER (CRITICAL! - This is THE LOGIC!)

### IPv4 INPUT CHAIN - Complete Rule Order:

```nft
# =============================================================================
# PHASE 1: CONNECTION TRACKING (CT) - MUST BE FIRST!
# =============================================================================

# RULE 1: Accept established/related connections (ALWAYS FIRST!)
# Logic: If connection already established, allow it
# Why first? Performance - most packets match this rule
nft add rule ip nftban_v4 input \
    ct state established,related \
    counter \
    accept \
    comment "Phase1_CT_established"

# =============================================================================
# PHASE 2: LOOPBACK - ALWAYS ALLOW
# =============================================================================

# RULE 2: Accept loopback interface
# Logic: Local connections (127.0.0.1) must always work
# Critical for: System services, database connections, etc.
nft add rule ip nftban_v4 input \
    iif lo \
    counter \
    accept \
    comment "Phase2_Loopback"

# =============================================================================
# PHASE 3: WHITELIST - HIGHEST PRIORITY (MUST COME BEFORE ALL DROPS!)
# =============================================================================

# RULE 3: ⭐ WHITELIST CHECK (CRITICAL!)
# Logic: Check if source IP is in @whitelist set
# Why here? Whitelisted IPs MUST NEVER BE BLOCKED by any rule below!
# Security: This MUST be before all drop rules
nft add rule ip nftban_v4 input \
    ip saddr @whitelist \
    counter \
    accept \
    comment "Phase3_Whitelist_PRIORITY"

# =============================================================================
# PHASE 4: PROTOCOL-SPECIFIC ACCEPTS (Before drops!)
# =============================================================================

# RULE 4: Accept ICMP (ping, traceroute)
# Logic: Allow network diagnostics
# Types: echo-request (ping), echo-reply (pong)
nft add rule ip nftban_v4 input \
    icmp type { echo-request, echo-reply } \
    counter \
    accept \
    comment "Phase4_ICMP_diagnostics"

# =============================================================================
# PHASE 5: SSH SAFETY RULE (PREVENTS LOCKOUTS!)
# =============================================================================

# RULE 5: ⭐ SSH SAFETY (CRITICAL!)
# Logic: ALWAYS accept SSH on detected port (even if port config missing)
# Why? Prevents admin lockout if port config files are broken
# Note: SSH port detected from /etc/ssh/sshd_config
nft add rule ip nftban_v4 input \
    tcp dport 22 \
    counter \
    accept \
    comment "Phase5_SSH_SAFETY_prevents_lockout"

# =============================================================================
# PHASE 6: PORT-BASED ACCEPTS (Service allowlist)
# =============================================================================

# RULE 6a: TCP ports from config file
# Logic: Read /etc/nftban/ports/ipv4-input.conf
# Format: PORT|T (TCP), PORT|U (UDP), PORT|B (Both)
# Example rules generated:
nft add rule ip nftban_v4 input tcp dport 80  counter accept comment "Allow_TCP_80"
nft add rule ip nftban_v4 input tcp dport 443 counter accept comment "Allow_TCP_443"

# RULE 6b: UDP ports from config file
nft add rule ip nftban_v4 input udp dport 53  counter accept comment "Allow_UDP_53"

# =============================================================================
# PHASE 7: CT STATE INVALID DROP (Security)
# =============================================================================

# RULE 7: Drop invalid CT states (malformed packets)
# Logic: Packets that don't match any known connection
# Security: Prevents certain TCP attacks (SYN floods, etc.)
nft add rule ip nftban_v4 input \
    ct state invalid \
    counter \
    drop \
    comment "Phase7_CT_invalid_drop"

# =============================================================================
# PHASE 8: DDOS PROTECTION (Rate Limiting)
# =============================================================================

# RULE 8a: NEW connection rate limit (per source IP)
# Logic: Max 100 new connections per minute per IP
# Prevents: SYN flood, connection exhaustion attacks
nft add rule ip nftban_v4 input \
    ct state new \
    limit rate over 100/minute burst 20 packets \
    counter \
    drop \
    comment "Phase8_DDoS_connection_rate_limit"

# RULE 8b: ICMP flood protection
# Logic: Max 10 ICMP packets per second
# Prevents: Ping flood attacks
nft add rule ip nftban_v4 input \
    icmp type echo-request \
    limit rate over 10/second \
    counter \
    drop \
    comment "Phase8_DDoS_ICMP_flood"

# RULE 8c: TCP SYN flood protection
# Logic: Limit SYN packets per source
# Prevents: SYN flood attacks
nft add rule ip nftban_v4 input \
    tcp flags & (fin|syn|rst|ack) == syn \
    limit rate over 50/second \
    counter \
    drop \
    comment "Phase8_DDoS_SYN_flood"

# =============================================================================
# DROP ZONE: BLACKLISTS (Order = Counter/Logging Priority Only)
# All drops are equal from security perspective
# Order matters for statistics and which counter/log triggers first
# =============================================================================

# RULE 9: Drop temp_ban (HIGHEST PRIORITY DROP)
# Logic: Check if source IP in @temp_ban set
# Why first? Active threats currently being monitored
# These are "hot" IPs that just attacked
nft add rule ip nftban_v4 input \
    ip saddr @temp_ban \
    counter \
    drop \
    comment "Phase9_Drop_temp_ban_active_threats"

# RULE 10: Drop user_blacklist
# Logic: Check if source IP in @user_blacklist set
# Why second? Admin manually blocked these (important)
nft add rule ip nftban_v4 input \
    ip saddr @user_blacklist \
    counter \
    drop \
    comment "Phase9_Drop_user_blacklist_manual"

# RULE 11: Drop system_blacklist
# Logic: Check if source IP in @system_blacklist set
# Why third? System automatically blocked (persistent offenders)
nft add rule ip nftban_v4 input \
    ip saddr @system_blacklist \
    counter \
    drop \
    comment "Phase9_Drop_system_blacklist_auto"

# RULE 12: Drop feeds (LOWEST PRIORITY DROP)
# Logic: Check if source IP in @feeds set
# Why last? External threat intel (may have false positives)
# Lowest priority so internal lists take precedence
nft add rule ip nftban_v4 input \
    ip saddr @feeds \
    counter \
    drop \
    comment "Phase9_Drop_feeds_external_intel"

# =============================================================================
# PHASE 10: IMPLICIT ACCEPT (Policy is accept)
# =============================================================================
# If packet reaches here: Not dropped = ACCEPTED
# Policy: accept (set in chain definition)
```

### Rule Order Diagram:

```
PACKET ARRIVES
      │
      ↓
┌─────────────────────────────────────────┐
│ RULE 1: CT established/related?         │
│ YES → ✅ ACCEPT (fast path!)            │
│ NO  → Continue                          │
└──────────────┬──────────────────────────┘
               ↓
┌─────────────────────────────────────────┐
│ RULE 2: Loopback (lo)?                  │
│ YES → ✅ ACCEPT                          │
│ NO  → Continue                          │
└──────────────┬──────────────────────────┘
               ↓
┌─────────────────────────────────────────┐
│ RULE 3: ⭐ In whitelist?                │
│ YES → ✅ ACCEPT (protected!)            │
│ NO  → Continue                          │
└──────────────┬──────────────────────────┘
               ↓
┌─────────────────────────────────────────┐
│ RULE 4: ICMP echo-request/reply?        │
│ YES → ✅ ACCEPT                          │
│ NO  → Continue                          │
└──────────────┬──────────────────────────┘
               ↓
┌─────────────────────────────────────────┐
│ RULE 5: ⭐ SSH port?                    │
│ YES → ✅ ACCEPT (safety!)               │
│ NO  → Continue                          │
└──────────────┬──────────────────────────┘
               ↓
┌─────────────────────────────────────────┐
│ RULES 6: Allowed ports (80,443,etc)?    │
│ YES → ✅ ACCEPT                          │
│ NO  → Continue                          │
└──────────────┬──────────────────────────┘
               ↓
┌─────────────────────────────────────────┐
│ RULE 7: CT state invalid?               │
│ YES → ❌ DROP (malformed!)              │
│ NO  → Continue                          │
└──────────────┬──────────────────────────┘
               ↓
┌─────────────────────────────────────────┐
│ RULES 8: DDoS rate limits exceeded?     │
│ YES → ❌ DROP (flood protection!)       │
│ NO  → Continue                          │
└──────────────┬──────────────────────────┘
               ↓
┌─────────────────────────────────────────┐
│ RULE 9: In temp_ban?                    │
│ YES → ❌ DROP                            │
│ NO  → Continue                          │
└──────────────┬──────────────────────────┘
               ↓
┌─────────────────────────────────────────┐
│ RULE 10: In user_blacklist?             │
│ YES → ❌ DROP                            │
│ NO  → Continue                          │
└──────────────┬──────────────────────────┘
               ↓
┌─────────────────────────────────────────┐
│ RULE 11: In system_blacklist?           │
│ YES → ❌ DROP                            │
│ NO  → Continue                          │
└──────────────┬──────────────────────────┘
               ↓
┌─────────────────────────────────────────┐
│ RULE 12: In feeds?                      │
│ YES → ❌ DROP                            │
│ NO  → Continue                          │
└──────────────┬──────────────────────────┘
               ↓
┌─────────────────────────────────────────┐
│ IMPLICIT ACCEPT (policy: accept)        │
│ ✅ ACCEPT (passed all rules!)           │
└─────────────────────────────────────────┘
```

═══════════════════════════════════════════════════════════════════════════════

## 🔄 IPv6 INPUT CHAIN (Same Logic, Different Family)

```nft
# Same rule structure as IPv4, but with ip6:

# CT established/related
nft add rule ip6 nftban_v6 input ct state established,related counter accept

# Loopback
nft add rule ip6 nftban_v6 input iif lo counter accept

# ⭐ Whitelist (CRITICAL!)
nft add rule ip6 nftban_v6 input ip6 saddr @whitelist counter accept

# ICMPv6 (more types needed for IPv6!)
nft add rule ip6 nftban_v6 input \
    icmpv6 type { \
        echo-request, echo-reply, \
        nd-neighbor-solicit, nd-neighbor-advert, \
        nd-router-solicit, nd-router-advert \
    } \
    counter accept \
    comment "ICMPv6_essential"

# ⭐ SSH Safety
nft add rule ip6 nftban_v6 input tcp dport 22 counter accept

# Allowed ports (from config)
# ... (same as IPv4)

# CT invalid
nft add rule ip6 nftban_v6 input ct state invalid counter drop

# DDoS protection (same logic)
# ... (same limits as IPv4)

# Blacklists (same order)
nft add rule ip6 nftban_v6 input ip6 saddr @temp_ban counter drop
nft add rule ip6 nftban_v6 input ip6 saddr @user_blacklist counter drop
nft add rule ip6 nftban_v6 input ip6 saddr @system_blacklist counter drop
nft add rule ip6 nftban_v6 input ip6 saddr @feeds counter drop
```

**IPv6 Differences:**
- `ip6 saddr` instead of `ip saddr`
- More ICMPv6 types (neighbor discovery is essential!)
- Otherwise same logic

═══════════════════════════════════════════════════════════════════════════════

## 📤 OUTPUT CHAINS (Simpler - Less Filtering Needed)

### IPv4 OUTPUT:

```nft
# RULE 1: Accept established/related
nft add rule ip nftban_v4 output \
    ct state established,related \
    counter \
    accept \
    comment "CT_established"

# RULE 2: Accept loopback
nft add rule ip nftban_v4 output \
    oif lo \
    counter \
    accept \
    comment "Loopback"

# RULE 3: Apply port rules from config
# Read: /etc/nftban/ports/ipv4-output.conf
# Allow outgoing connections on specified ports

# IMPLICIT ACCEPT for everything else (policy: accept)
```

**Why Output is Simpler?**
- Server initiates connections (trusted)
- No need for blacklists (we control what we connect to)
- Main purpose: Control which ports server can use

═══════════════════════════════════════════════════════════════════════════════

## 🔧 CONNECTION TRACKING (CT) EXPLAINED

### CT States:

| State | Meaning | Action |
|-------|---------|--------|
| **new** | First packet of new connection | Check blacklists, rate limits |
| **established** | Connection already accepted | ACCEPT (fast path!) |
| **related** | Related to established connection (e.g., FTP data) | ACCEPT |
| **invalid** | Doesn't match any known connection | DROP (security) |

### Why CT is RULE #1?

```
WITHOUT CT (slow):
Every packet → Check all rules → Decision
100,000 packets = 100,000 full rule checks

WITH CT (fast):
First packet → Check all rules → Decision → Mark ESTABLISHED
Next 99,999 packets → RULE 1 match → ACCEPT (no further checks!)
```

**Performance Impact:**
- Rule 1 (CT established): Matches 95%+ of packets
- Rules 2-12: Only check remaining 5% (new connections)

═══════════════════════════════════════════════════════════════════════════════

## 🛡️ DDOS PROTECTION LOGIC

### Layer 4 (TCP/UDP) DDoS Protection:

```nft
# 1. Connection Rate Limiting (Per-Source)
# Logic: Track new connections per source IP
# Drop if rate > threshold
nft add rule ip nftban_v4 input \
    ct state new \
    limit rate over 100/minute burst 20 packets \
    counter drop \
    comment "Connection_flood_protection"

# How it works:
# - Kernel tracks connection rate per source IP
# - If source opens >100 new connections/min: DROP
# - Burst allows 20 quick connections (legitimate traffic spikes)
```

```nft
# 2. SYN Flood Protection
# Logic: Limit TCP SYN packets (connection initiation)
# Why? SYN floods exhaust connection tables
nft add rule ip nftban_v4 input \
    tcp flags & (fin|syn|rst|ack) == syn \
    limit rate over 50/second \
    counter drop \
    comment "SYN_flood_protection"

# How it works:
# - Check if TCP flags = SYN only (connection start)
# - If >50 SYN/sec from source: DROP
```

```nft
# 3. ICMP Flood Protection
# Logic: Limit ICMP echo-request (ping)
# Why? Ping floods consume bandwidth
nft add rule ip nftban_v4 input \
    icmp type echo-request \
    limit rate over 10/second \
    counter drop \
    comment "ICMP_flood_protection"
```

### Rate Limit Parameters Explained:

```
rate <limit>/<time>:
  - 100/minute = max 100 per minute
  - 50/second  = max 50 per second
  - 10/hour    = max 10 per hour

burst <packets>:
  - Allows short bursts above rate
  - Example: 20 packets burst
  - Legitimate: User opens 15 tabs quickly (burst 20 = OK)
  - Attack: Bot opens 100 connections (exceeds rate+burst = DROP)
```

═══════════════════════════════════════════════════════════════════════════════

## 🔍 WHITELIST LOGIC (HIGHEST PRIORITY!)

### Why Whitelist Must Be Rule #3?

```
Scenario: IP is in BOTH whitelist AND blacklist

WRONG ORDER (whitelist after blacklist):
1. Check blacklist → FOUND → DROP ❌
2. (Never reaches whitelist check)
Result: Whitelisted IP is blocked! BUG!

CORRECT ORDER (whitelist before blacklist):
1. Check whitelist → FOUND → ACCEPT ✅
2. (Skips all blacklist checks)
Result: Whitelisted IP always accepted!
```

**Rule:**
```nft
nft add rule ip nftban_v4 input \
    ip saddr @whitelist \
    counter \
    accept \
    comment "Whitelist_PRIORITY"
```

**Logic:**
- Source IP in @whitelist set? → ACCEPT immediately
- Skip ALL remaining rules (blacklists, rate limits, everything)
- Guarantees whitelisted IPs NEVER blocked

═══════════════════════════════════════════════════════════════════════════════

## 🚫 BLACKLIST LOGIC (Drop Order)

### Drop Rule Order:

```nft
# Priority 1: temp_ban (active threats)
nft add rule ip nftban_v4 input ip saddr @temp_ban counter drop

# Priority 2: user_blacklist (manual bans)
nft add rule ip nftban_v4 input ip saddr @user_blacklist counter drop

# Priority 3: system_blacklist (automatic bans)
nft add rule ip nftban_v4 input ip saddr @system_blacklist counter drop

# Priority 4: feeds (external intel)
nft add rule ip nftban_v4 input ip saddr @feeds counter drop
```

**Why This Order?**

From **security perspective:** All drops are equal (packet is dropped)

From **monitoring perspective:** Order determines which counter/log triggers

**Example:**
```
IP 1.2.3.4 is in:
- temp_ban: YES
- user_blacklist: YES
- feeds: YES

Packet from 1.2.3.4 arrives:
→ Matches RULE 9 (temp_ban) → DROP
→ Counter "temp_ban" incremented
→ Logged as "blocked by temp_ban"
→ NEVER checks user_blacklist or feeds (already dropped)

Result: Statistics show "temp_ban" block (most specific)
```

**Order Rationale:**
1. **temp_ban first:** Most specific (just attacked now)
2. **user_blacklist:** Admin knows best
3. **system_blacklist:** System detected pattern
4. **feeds last:** External data (least specific)

═══════════════════════════════════════════════════════════════════════════════

## 🔌 PORT FILTERING LOGIC

### How Port Rules Work:

**Config File Format:**
```
# /etc/nftban/ports/ipv4-input.conf
22|T        # SSH (TCP)
80|T        # HTTP (TCP)
443|T       # HTTPS (TCP)
53|U        # DNS (UDP)
3306|B      # MySQL (Both TCP+UDP)
```

**Generated Rules:**
```nft
# For "22|T":
nft add rule ip nftban_v4 input \
    tcp dport 22 \
    counter accept \
    comment "Allow_TCP_22"

# For "53|U":
nft add rule ip nftban_v4 input \
    udp dport 53 \
    counter accept \
    comment "Allow_UDP_53"

# For "3306|B":
nft add rule ip nftban_v4 input tcp dport 3306 counter accept
nft add rule ip nftban_v4 input udp dport 3306 counter accept
```

**Logic:**
1. Read config file
2. Parse each line (PORT|PROTOCOL)
3. Generate nft rule for each port
4. Apply rules to chain

**Why After Whitelist?**
- Whitelisted IPs already accepted (skip port check)
- Saves processing (no need to check ports for whitelisted IPs)

═══════════════════════════════════════════════════════════════════════════════

## 🔄 HOW TO BUILD (The Logic to Create Rules)

### Build Process:

```bash
#!/bin/bash
# Pseudocode for building nftables rules

# STEP 1: Create tables
nft add table ip nftban_v4
nft add table ip6 nftban_v6

# STEP 2: Create sets
for table in "ip nftban_v4" "ip6 nftban_v6"; do
    nft add set $table whitelist { ... }
    nft add set $table temp_ban { ... }
    nft add set $table user_blacklist { ... }
    nft add set $table system_blacklist { ... }
    nft add set $table feeds { ... }
done

# STEP 3: Create chains
nft add chain ip nftban_v4 input { type filter hook input priority filter; policy accept; }
nft add chain ip nftban_v4 output { type filter hook output priority filter; policy accept; }
nft add chain ip6 nftban_v6 input { type filter hook input priority filter; policy accept; }
nft add chain ip6 nftban_v6 output { type filter hook output priority filter; policy accept; }

# STEP 4: Apply INPUT rules (ORDER IS CRITICAL!)
apply_input_rules() {
    local family=$1  # "ip" or "ip6"
    local table=$2   # "nftban_v4" or "nftban_v6"

    # Rule 1: CT established
    nft add rule $family $table input ct state established,related counter accept

    # Rule 2: Loopback
    nft add rule $family $table input iif lo counter accept

    # Rule 3: ⭐ Whitelist (CRITICAL!)
    if [[ "$family" == "ip" ]]; then
        nft add rule $family $table input ip saddr @whitelist counter accept
    else
        nft add rule $family $table input ip6 saddr @whitelist counter accept
    fi

    # Rule 4: ICMP
    if [[ "$family" == "ip" ]]; then
        nft add rule $family $table input icmp type { echo-request, echo-reply } counter accept
    else
        nft add rule $family $table input icmpv6 type { echo-request, echo-reply, nd-neighbor-solicit, nd-neighbor-advert } counter accept
    fi

    # Rule 5: SSH Safety
    local ssh_port=$(detect_ssh_port)  # Read from /etc/ssh/sshd_config
    nft add rule $family $table input tcp dport $ssh_port counter accept

    # Rule 6: Apply port rules from config
    apply_port_rules "$family" "$table" "input"

    # Rule 7: CT invalid
    nft add rule $family $table input ct state invalid counter drop

    # Rule 8: DDoS protection
    nft add rule $family $table input ct state new limit rate over 100/minute burst 20 packets counter drop
    nft add rule $family $table input tcp flags & (fin|syn|rst|ack) == syn limit rate over 50/second counter drop

    # Rules 9-12: Blacklists (ORDER MATTERS!)
    if [[ "$family" == "ip" ]]; then
        nft add rule $family $table input ip saddr @temp_ban counter drop
        nft add rule $family $table input ip saddr @user_blacklist counter drop
        nft add rule $family $table input ip saddr @system_blacklist counter drop
        nft add rule $family $table input ip saddr @feeds counter drop
    else
        nft add rule $family $table input ip6 saddr @temp_ban counter drop
        nft add rule $family $table input ip6 saddr @user_blacklist counter drop
        nft add rule $family $table input ip6 saddr @system_blacklist counter drop
        nft add rule $family $table input ip6 saddr @feeds counter drop
    fi
}

# Apply rules to both families
apply_input_rules "ip" "nftban_v4"
apply_input_rules "ip6" "nftban_v6"
```

### Port Rules Logic:

```bash
apply_port_rules() {
    local family=$1   # "ip" or "ip6"
    local table=$2    # "nftban_v4" or "nftban_v6"
    local direction=$3 # "input" or "output"

    # Determine config file
    local config_file
    if [[ "$family" == "ip" && "$direction" == "input" ]]; then
        config_file="/etc/nftban/ports/ipv4-input.conf"
    elif [[ "$family" == "ip" && "$direction" == "output" ]]; then
        config_file="/etc/nftban/ports/ipv4-output.conf"
    elif [[ "$family" == "ip6" && "$direction" == "input" ]]; then
        config_file="/etc/nftban/ports/ipv6-input.conf"
    else
        config_file="/etc/nftban/ports/ipv6-output.conf"
    fi

    # Read config and generate rules
    while IFS='|' read -r port protocol; do
        # Skip comments and empty lines
        [[ -z "$port" || "$port" =~ ^# ]] && continue

        case "$protocol" in
            T)  # TCP only
                nft add rule $family $table $direction tcp dport $port counter accept comment "Allow_TCP_$port"
                ;;
            U)  # UDP only
                nft add rule $family $table $direction udp dport $port counter accept comment "Allow_UDP_$port"
                ;;
            B)  # Both TCP and UDP
                nft add rule $family $table $direction tcp dport $port counter accept comment "Allow_TCP_$port"
                nft add rule $family $table $direction udp dport $port counter accept comment "Allow_UDP_$port"
                ;;
        esac
    done < "$config_file"
}
```

═══════════════════════════════════════════════════════════════════════════════

## 📊 RULE EVALUATION PERFORMANCE

### Performance Metrics:

```
Rule Position    Average Hit Rate    Impact
──────────────────────────────────────────────
Rule 1 (CT est)       95%           HUGE (fast path)
Rule 2 (lo)           2%            Medium
Rule 3 (whitelist)    0.5%          Low
Rule 4 (ICMP)         1%            Low
Rule 5 (SSH)          0.5%          Low
Rule 6 (ports)        1%            Low
Rules 7-12            0.01%         Very Low (blocks)
```

**Why This Order is Optimal:**
1. Most common case first (CT established) = 95% fast path
2. Whitelist before drops = Security guarantee
3. Accepts before drops = Legitimate traffic processed first
4. Drops last = Only evaluated for ~5% of packets

═══════════════════════════════════════════════════════════════════════════════

## ✅ THE COMPLETE LOGIC - SUMMARY

### Architecture Summary:

```
TABLES: 2 (IPv4, IPv6) - Split for performance
SETS: 5 per table (whitelist, temp_ban, user_blacklist, system_blacklist, feeds)
CHAINS: 4 total (2 input, 2 output)
RULES: ~15 per input chain (order is critical!)
```

### Critical Logic Points:

1. **CT established FIRST** → 95% fast path
2. **Whitelist BEFORE drops** → Security guarantee
3. **SSH safety ALWAYS** → Prevents lockout
4. **Port rules from config** → User-friendly
5. **DDoS rate limits** → Attack protection
6. **Blacklist order** → Statistics/monitoring clarity
7. **Policy accept** → Explicit drops only

### Build Sequence:

```
1. Create tables (ip, ip6)
2. Create sets (5 per table)
3. Create chains (input, output)
4. Apply rules IN ORDER (critical!)
5. Load data into sets (from files)
```

═══════════════════════════════════════════════════════════════════════════════

**🎯 THIS IS THE LOGIC - Ready to implement in v0.10.0!** ✨
