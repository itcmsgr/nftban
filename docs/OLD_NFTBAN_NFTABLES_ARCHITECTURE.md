# OLD NFTBan (v0.9.x) - nftables Architecture Analysis
**Date:** 2025-10-27
**Purpose:** Document OLD nftban architecture for migration to v0.10.0
**Status:** STEP 1 - Architecture Understanding

═══════════════════════════════════════════════════════════════════════════════

## 🏗️ TABLE ARCHITECTURE (Split IPv4/IPv6)

### Tables Created:

```
┌─────────────────────────────────────────────────────────────┐
│ IPv4 Table                                                   │
├─────────────────────────────────────────────────────────────┤
│ Name:   nftban_v4                                           │
│ Family: ip                                                   │
│ Type:   filter                                              │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ IPv6 Table                                                   │
├─────────────────────────────────────────────────────────────┤
│ Name:   nftban_v6                                           │
│ Family: ip6                                                  │
│ Type:   filter                                              │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ Legacy Table (v0.8.5) - For Migration Only                  │
├─────────────────────────────────────────────────────────────┤
│ Name:   nftban_global                                       │
│ Family: inet                                                 │
│ Type:   filter                                              │
└─────────────────────────────────────────────────────────────┘
```

**Why Split Tables?**
- Performance: Separate processing for IPv4/IPv6
- Clarity: No mixed family rules
- Compatibility: Works with all nftables versions

═══════════════════════════════════════════════════════════════════════════════

## 📦 SETS (IP Storage Containers)

### IPv4 Sets (in nftban_v4 table):

| Set Name          | Type       | Flags          | Timeout | Purpose                    |
|-------------------|------------|----------------|---------|----------------------------|
| **whitelist**     | ipv4_addr  | interval       | none    | Whitelisted IPs            |
| **temp_ban**      | ipv4_addr  | timeout        | 1h      | Temporary bans (auto-expire)|
| **user_blacklist**| ipv4_addr  | interval       | none    | Manual permanent bans      |
| **system_blacklist**| ipv4_addr| interval       | none    | Automatic permanent bans   |
| **feeds**         | ipv4_addr  | interval, auto-merge | none | Threat feeds           |

### IPv6 Sets (in nftban_v6 table):

| Set Name          | Type       | Flags          | Timeout | Purpose                    |
|-------------------|------------|----------------|---------|----------------------------|
| **whitelist**     | ipv6_addr  | interval       | none    | Whitelisted IPs            |
| **temp_ban**      | ipv6_addr  | timeout        | 1h      | Temporary bans (auto-expire)|
| **user_blacklist**| ipv6_addr  | interval       | none    | Manual permanent bans      |
| **system_blacklist**| ipv6_addr| interval       | none    | Automatic permanent bans   |
| **feeds**         | ipv6_addr  | interval, auto-merge | none | Threat feeds           |

**Key Insights:**
- **interval flag:** Supports CIDR ranges (e.g., 192.168.1.0/24)
- **timeout flag:** Entries auto-expire after specified time
- **auto-merge flag:** Automatically merges overlapping ranges (for feeds)
- **No _v4/_v6 suffix:** Sets are table-specific, no suffix needed

═══════════════════════════════════════════════════════════════════════════════

## ⛓️ CHAINS (Rule Processing Flow)

### IPv4 Chains:

```
nftban_v4 table
├── input (type: filter, hook: input, priority: filter, policy: accept)
└── output (type: filter, hook: output, priority: filter, policy: accept)
```

### IPv6 Chains:

```
nftban_v6 table
├── input (type: filter, hook: input, priority: filter, policy: accept)
└── output (type: filter, hook: output, priority: filter, policy: accept)
```

**Chain Properties:**
- **Hook:** input/output (where packets are intercepted)
- **Priority:** filter (standard firewall priority)
- **Policy:** accept (default allow, explicit drops only)

═══════════════════════════════════════════════════════════════════════════════

## 🔥 RULE ORDER (CRITICAL!)

### IPv4 INPUT Chain (Priority Order):

```
┌─────────────────────────────────────────────────────────────┐
│ RULE 1: Accept established/related connections              │
│ ✅ ct state established,related counter accept              │
│ Purpose: Allow ongoing connections (ALWAYS FIRST!)          │
└─────────────────────────────────────────────────────────────┘
                             ↓
┌─────────────────────────────────────────────────────────────┐
│ RULE 2: Accept loopback (lo)                                │
│ ✅ iif lo counter accept                                     │
│ Purpose: Allow local connections                            │
└─────────────────────────────────────────────────────────────┘
                             ↓
┌─────────────────────────────────────────────────────────────┐
│ RULE 3: ⭐ WHITELIST CHECK (HIGHEST PRIORITY!)              │
│ ✅ ip saddr @whitelist counter accept                       │
│ Purpose: Whitelisted IPs MUST NEVER BE BLOCKED              │
│ Security: This rule comes BEFORE all drops                  │
└─────────────────────────────────────────────────────────────┘
                             ↓
┌─────────────────────────────────────────────────────────────┐
│ RULE 4: Accept ICMP                                         │
│ ✅ icmp type { echo-request, echo-reply } counter accept    │
│ Purpose: Network diagnostics                                │
└─────────────────────────────────────────────────────────────┘
                             ↓
┌─────────────────────────────────────────────────────────────┐
│ RULE 4.5: ⭐ SSH SAFETY RULE (BUG56 FIX)                    │
│ ✅ tcp dport <detected_ssh_port> counter accept             │
│ Purpose: PREVENTS LOCKOUTS - hardcoded SSH access           │
│ Note: Runs BEFORE port config files are read               │
└─────────────────────────────────────────────────────────────┘
                             ↓
┌─────────────────────────────────────────────────────────────┐
│ RULE 5: Apply port rules from config files                  │
│ 📋 Read: /etc/nftban/ports/ipv4-input.conf                  │
│ Format: PORT|PROTOCOL (T=TCP, U=UDP, B=Both)                │
└─────────────────────────────────────────────────────────────┘
                             ↓
┌─────────────────────────────────────────────────────────────┐
│ 🚫 DROP ZONE (Order = Priority)                            │
├─────────────────────────────────────────────────────────────┤
│ RULE 6: Drop temp_ban (HIGHEST PRIORITY DROP)               │
│ ❌ ip saddr @temp_ban counter drop                          │
│ Purpose: Active threats (1h timeout)                        │
├─────────────────────────────────────────────────────────────┤
│ RULE 7: Drop user_blacklist                                 │
│ ❌ ip saddr @user_blacklist counter drop                    │
│ Purpose: Manual permanent bans                              │
├─────────────────────────────────────────────────────────────┤
│ RULE 8: Drop system_blacklist                               │
│ ❌ ip saddr @system_blacklist counter drop                  │
│ Purpose: Automatic permanent bans                           │
├─────────────────────────────────────────────────────────────┤
│ RULE 9: Drop feeds (LOWEST PRIORITY DROP)                   │
│ ❌ ip saddr @feeds counter drop                             │
│ Purpose: Threat feeds (last resort)                         │
└─────────────────────────────────────────────────────────────┘
```

### IPv6 INPUT Chain (Mirror Structure):

- Same rule order as IPv4
- Uses `ip6 saddr` instead of `ip saddr`
- ICMPv6 includes: echo-request, echo-reply, nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit, nd-router-advert

### OUTPUT Chains (Both IPv4/IPv6):

```
┌─────────────────────────────────────────────────────────────┐
│ RULE 1: Accept established/related connections              │
│ ✅ ct state established,related counter accept              │
└─────────────────────────────────────────────────────────────┘
                             ↓
┌─────────────────────────────────────────────────────────────┐
│ RULE 2: Accept loopback (lo)                                │
│ ✅ oif lo counter accept                                     │
└─────────────────────────────────────────────────────────────┘
                             ↓
┌─────────────────────────────────────────────────────────────┐
│ RULE 3: Apply port rules from config files                  │
│ 📋 Read: /etc/nftban/ports/ipv4-output.conf                 │
│ 📋 Read: /etc/nftban/ports/ipv6-output.conf                 │
└─────────────────────────────────────────────────────────────┘
```

═══════════════════════════════════════════════════════════════════════════════

## 🔌 PORT CONFIGURATION

### Port Config Files:

**Location:** `/etc/nftban/ports/`

**Files:**
1. `ipv4-input.conf` - IPv4 incoming connections
2. `ipv4-output.conf` - IPv4 outgoing connections
3. `ipv6-input.conf` - IPv6 incoming connections
4. `ipv6-output.conf` - IPv6 outgoing connections

### Format:

```
# Comment lines start with #
PORT|PROTOCOL

# Examples:
22|T         # SSH (TCP only)
80|T         # HTTP (TCP only)
443|T        # HTTPS (TCP only)
53|U         # DNS (UDP only)
3306|B       # MySQL (Both TCP and UDP)
```

**Protocol Codes:**
- `T` = TCP only
- `U` = UDP only
- `B` = Both TCP and UDP

### Auto-Creation (BUG56 FIX):

If port config files are missing, they are auto-created with:
- **Detected SSH port** (from `/etc/ssh/sshd_config`)
- Default web ports (80, 443)
- Default DNS (53 UDP)
- Default NTP (123 UDP)
- Default SMTP (25 TCP)

═══════════════════════════════════════════════════════════════════════════════

## 🔍 KEY SECURITY FEATURES

### 1. Whitelist Protection

```bash
# RULE 3: WHITELIST CHECK (HIGHEST PRIORITY - MUST BE FIRST ACCEPT!)
# SECURITY: Whitelisted IPs MUST NEVER be blocked
# BUG57 FIX: Must use 'ip saddr' explicitly (required by nftables v1.0.9)
nft add rule ip nftban_v4 input \
    ip saddr @whitelist counter accept \
    comment Accept_whitelisted
```

**Why First?**
- Whitelisted IPs must NEVER be blocked
- Runs BEFORE all drop rules
- Even if IP is in blacklist, whitelist takes precedence

### 2. SSH Safety Rule (BUG56 FIX)

```bash
# RULE 4.5: SSH SAFETY RULE (BUG56 FIX - PREVENTS LOCKOUTS)
# CRITICAL: This hardcoded SSH rule runs BEFORE port config files are read.
# Even if port config files are missing/misconfigured, SSH remains accessible.
local ssh_port
ssh_port=$(nftban_nftables_detect_ssh_port)  # Auto-detect from sshd_config
nft add rule ip nftban_v4 input \
    tcp dport "$ssh_port" counter accept \
    comment SSH_SAFETY_prevents_lockout
```

**Purpose:**
- Prevents admin lockout
- Works even if port config files missing
- Auto-detects SSH port from `/etc/ssh/sshd_config`
- Hardcoded, runs BEFORE dynamic port rules

### 3. Explicit Source Address Syntax (BUG57 FIX)

**Before (WRONG - nftables v1.0.9+ fails):**
```bash
nft add rule ip nftban_v4 input @whitelist accept  # ❌ FAILS
```

**After (CORRECT):**
```bash
nft add rule ip nftban_v4 input ip saddr @whitelist accept  # ✅ WORKS
```

**Why?**
- nftables v1.0.9+ requires explicit `ip saddr` / `ip6 saddr`
- OLD versions accepted shorthand, NEW versions don't

### 4. Empty Set Handling (BUG60 FIX)

**Problem:** Empty sets cause grep to return 1, breaking pipefail

**Solution:**
```bash
local output
output=$(nft list set ip nftban_v4 whitelist 2>/dev/null)
if echo "$output" | grep -q 'elements = '; then
    count=$(echo "$output" | grep -oP 'elements = \{\K[^}]*' | wc -l)
else
    count=0  # Empty set
fi
```

═══════════════════════════════════════════════════════════════════════════════

## 📊 DROP RULE PRIORITY (Why Order Matters)

### Drop Order Explained:

```
Priority 1: temp_ban      (Active threats, being monitored)
Priority 2: user_blacklist (Admin manually blocked)
Priority 3: system_blacklist (System automatically blocked)
Priority 4: feeds          (External threat intelligence)
```

**Why This Order?**

1. **temp_ban first:** Active threats being monitored, highest visibility
2. **user_blacklist second:** Admin knows best, manual blocks important
3. **system_blacklist third:** Automated blocks, less urgent
4. **feeds last:** External data, lowest priority (may have false positives)

**Note:** From security perspective, all drops are equal (all blocked). Order only matters for:
- Counters (which rule hit first)
- Logging (which category triggered)
- Statistics (understanding attack patterns)

═══════════════════════════════════════════════════════════════════════════════

## 🔧 MANAGEMENT OPERATIONS

### Create Tables:

```bash
nftban_nftables_create_table()
├── nftban_nftables_create_table_v4()
│   ├── Create table: ip nftban_v4
│   ├── Create 5 sets (whitelist, temp_ban, user_blacklist, system_blacklist, feeds)
│   └── Create 2 chains (input, output)
└── nftban_nftables_create_table_v6()
    ├── Create table: ip6 nftban_v6
    ├── Create 5 sets (same names, different type)
    └── Create 2 chains (input, output)
```

### Apply Rules:

```bash
nftban_nftables_apply_rules()
├── Validate port configs (auto-create if missing)
├── nftban_nftables_apply_rules_v4()
│   ├── Flush existing rules
│   ├── Add rule 1: established/related
│   ├── Add rule 2: loopback
│   ├── Add rule 3: whitelist
│   ├── Add rule 4: ICMP
│   ├── Add rule 4.5: SSH safety
│   ├── Add rule 5: port rules (from config)
│   ├── Add rule 6: drop temp_ban
│   ├── Add rule 7: drop user_blacklist
│   ├── Add rule 8: drop system_blacklist
│   └── Add rule 9: drop feeds
└── nftban_nftables_apply_rules_v6()
    └── (same structure)
```

### Delete Tables:

```bash
nftban_nftables_delete_table()
├── nftban_nftables_delete_table_v4()
│   └── nft delete table ip nftban_v4
└── nftban_nftables_delete_table_v6()
    └── nft delete table ip6 nftban_v6
```

═══════════════════════════════════════════════════════════════════════════════

## 📈 SET STATISTICS

### Count IPs in Sets:

```bash
nftban_nftables_show_set_stats()
```

**Output Example:**
```
Sets (IPv4 - nftban_v4):
  whitelist:                 12 IPs
  temp_ban:                   5 IPs
  user_blacklist:            23 IPs
  system_blacklist:          89 IPs
  feeds:                  15234 IPs

Sets (IPv6 - nftban_v6):
  whitelist:                  3 IPs
  temp_ban:                   0 IPs
  user_blacklist:             2 IPs
  system_blacklist:           5 IPs
  feeds:                    823 IPs
```

═══════════════════════════════════════════════════════════════════════════════

## 🗺️ ARCHITECTURE DIAGRAM

```
┌───────────────────────────────────────────────────────────────┐
│                     NFTBAN v0.9.x ARCHITECTURE                │
└───────────────────────────────────────────────────────────────┘
                              │
                              │
         ┌────────────────────┴────────────────────┐
         │                                         │
    ┌────▼─────┐                            ┌─────▼────┐
    │  IPv4    │                            │   IPv6   │
    │  Table   │                            │  Table   │
    │ nftban_v4│                            │ nftban_v6│
    └────┬─────┘                            └─────┬────┘
         │                                         │
    ┌────┴─────────────┐                   ┌─────┴──────────┐
    │                  │                   │                │
┌───▼───┐         ┌────▼────┐         ┌───▼───┐       ┌────▼────┐
│ INPUT │         │ OUTPUT  │         │ INPUT │       │ OUTPUT  │
│ chain │         │  chain  │         │ chain │       │  chain  │
└───┬───┘         └────┬────┘         └───┬───┘       └────┬────┘
    │                  │                   │                │
    │ SETS:            │ PORT RULES        │ SETS:          │ PORT RULES
    │ ├─whitelist      │ from config       │ ├─whitelist    │ from config
    │ ├─temp_ban       │                   │ ├─temp_ban     │
    │ ├─user_blacklist │                   │ ├─user_blacklist│
    │ ├─system_blacklist│                  │ ├─system_blacklist│
    │ └─feeds          │                   │ └─feeds        │
    │                  │                   │                │
    └──────────────────┴───────────────────┴────────────────┘
                              │
                              │
                    ┌─────────▼─────────┐
                    │  Port Configs     │
                    │  /etc/nftban/ports│
                    ├───────────────────┤
                    │ ipv4-input.conf   │
                    │ ipv4-output.conf  │
                    │ ipv6-input.conf   │
                    │ ipv6-output.conf  │
                    └───────────────────┘
```

═══════════════════════════════════════════════════════════════════════════════

## 💡 KEY INSIGHTS FOR v0.10.0 MIGRATION

### What Must Be Preserved:

1. ✅ **Split IPv4/IPv6 architecture** (performance)
2. ✅ **5 sets per table** (whitelist, temp_ban, user_blacklist, system_blacklist, feeds)
3. ✅ **Rule order** (whitelist first, drops ordered by priority)
4. ✅ **SSH safety rule** (prevents lockouts)
5. ✅ **Explicit `ip saddr` syntax** (nftables v1.0.9+ compatibility)
6. ✅ **Port config file approach** (user-friendly)

### What Can Be Improved:

1. ⚠️ **Add counters by protocol** (TCP/UDP/ICMP visibility)
2. ⚠️ **Add rate limiting** (DDoS protection)
3. ⚠️ **Add logging options** (debugging)
4. ⚠️ **Add GeoIP integration** (country-based blocking)
5. ⚠️ **Add connection tracking** (SYN flood protection)

### Migration Challenges:

1. **Data migration:** IPs in old sets → new v0.10.0 storage
2. **Port config format:** Keep compatible or convert?
3. **Backwards compatibility:** Support old commands?
4. **Testing:** Verify all rules work on lab servers

═══════════════════════════════════════════════════════════════════════════════

## ✅ STEP 1 COMPLETE!

**Next Steps:**
1. ✅ Architecture documented
2. ⏳ Read search module (IP lookup logic)
3. ⏳ Read blacklist/whitelist modules (IP management)
4. ⏳ Create migration plan for v0.10.0
5. ⏳ Implement in new v0.10.0 structure

═══════════════════════════════════════════════════════════════════════════════

**nftban v0.9.x — Understanding Complete!** ✨
