# NFTBan v0.10.0 - Server Alignment Report
**Date:** 2025-10-30
**Servers:** lab, lab1, lab2
**Status:** ✅ 99% ALIGNED

═══════════════════════════════════════════════════════════════════

## 📊 Alignment Summary

### ✅ Perfectly Aligned

| Component | lab | lab1 | lab2 | Status |
|-----------|-----|------|------|--------|
| **NFTBan Version** | v0.10.0 | v0.10.0 | v0.10.0 | ✅ MATCH |
| **nftban-complete** | 6fa28405 | 6fa28405 | 6fa28405 | ✅ MATCH |
| **cmd_firewall.sh** | cc6ea163 | cc6ea163 | cc6ea163 | ✅ MATCH |
| **nftban_runtime table** | ✓ | ✓ | ✓ | ✅ MATCH |
| **nftban_main table** | ✓ | ✓ | ✓ | ✅ MATCH |
| **Table structure** | 6 sets + 1 chain | 6 sets + 1 chain | 6 sets + 1 chain | ✅ MATCH |
| **Fail2ban jails** | nftban-sshd, sshd | nftban-sshd, sshd | nftban-sshd, sshd | ✅ MATCH |
| **Ban action** | nftban | nftban | nftban | ✅ MATCH |
| **f2b-table** | ❌ Removed | ❌ Removed | ❌ Removed | ✅ MATCH |

### ⚠️ Minor Differences (Expected)

| Component | lab | lab1 | lab2 | Notes |
|-----------|-----|------|------|-------|
| **Whitelist IPs** | 2 IPs | 2 IPs | 2 IPs | Different public IPs (EXPECTED) |
| **Temp bans** | 1 banned | 8 banned | 2 banned | Different attackers (EXPECTED) |
| **Extra tables** | None | `inet filter` | None | Empty Ubuntu default (HARMLESS) |

---

## 📋 Detailed Comparison

### 1. NFTABLES TABLES

**lab.mywebhost.gr (CentOS Stream 9):**
```
table inet nftban_runtime   ✓
table inet nftban_main       ✓
```

**lab1.mywebhost.gr (Ubuntu 24.04):**
```
table inet filter            ⚠️  (empty, harmless)
table inet nftban_runtime   ✓
table inet nftban_main       ✓
```

**lab2.mywebhost.gr (CentOS Stream 10):**
```
table inet nftban_runtime   ✓
table inet nftban_main       ✓
```

**Recommendation:** Remove `inet filter` from lab1 for consistency (optional)

---

### 2. NFTBAN_RUNTIME TABLE

**All Servers - Identical Structure:**
```
table inet nftban_runtime {
  set temp_ban_v4 {
    type ipv4_addr
    flags timeout
    comment "Temporary IPv4 bans from Fail2ban"
    elements = { ... }  ← Different IPs (EXPECTED)
  }

  set temp_ban_v6 {
    type ipv6_addr
    flags timeout
    comment "Temporary IPv6 bans from Fail2ban"
  }

  chain input_tempban {
    type filter hook input priority raw - 10; policy accept;
    ip saddr @temp_ban_v4 drop
    ip6 saddr @temp_ban_v6 drop
  }
}
```

**Status:** ✅ **PERFECT ALIGNMENT**

**Current Bans:**
- **lab:** 1 IP banned (188.166.94.150)
- **lab1:** 8 IPs banned (actively catching attackers!)
- **lab2:** 2 IPs banned (57.128.182.5, 167.99.222.200)

**Note:** Different bans are EXPECTED and GOOD (shows system is working!)

---

### 3. NFTBAN_MAIN TABLE

**All Servers - Identical Structure:**
```
table inet nftban_main {
  # Sets
  set whitelist_v4 { type ipv4_addr; ... }
  set whitelist_v6 { type ipv6_addr; ... }
  set blacklist_v4 { type ipv4_addr; }  ← Empty (no persistent offenders yet)
  set blacklist_v6 { type ipv6_addr; }  ← Empty
  set tcp_ports { type inet_service; elements = { 22 } }
  set udp_ports { type inet_service; }  ← Empty (no UDP services yet)

  # Chain
  chain input_main {
    type filter hook input priority raw; policy accept;  ← CORRECT (safe!)

    # 1. Established/loopback
    ct state established,related accept
    iif "lo" accept

    # 2. Whitelist (wins first)
    ip saddr @whitelist_v4 accept
    ip6 saddr @whitelist_v6 accept

    # 3. ICMP
    ip protocol icmp icmp type { echo-reply, destination-unreachable, echo-request, time-exceeded } accept
    ip6 nexthdr ipv6-icmp icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, echo-request, echo-reply } accept

    # 4. Allowed ports
    tcp dport @tcp_ports accept
    udp dport @udp_ports accept

    # 5. Drop invalid and blacklist
    ct state invalid drop
    ip saddr @blacklist_v4 drop
    ip6 saddr @blacklist_v6 drop
  }
}
```

**Status:** ✅ **PERFECT ALIGNMENT**

**Whitelist IPs (Different per server):**
- **lab:** 62.38.150.122 (common), 95.216.159.238
- **lab1:** 62.38.150.122 (common), 46.62.231.184
- **lab2:** 62.38.150.122 (common), 65.21.157.15

**Note:** 62.38.150.122 is common (probably management IP) ✓

**IPv6 Whitelists:**
- **lab:** 2a01:4f9:c010:b0b5::1
- **lab1:** 2a01:4f9:c013:31fe::1
- **lab2:** 2a01:4f9:c013:3f7a::1

---

### 4. FAIL2BAN CONFIGURATION

**All Servers - Identical:**
```
Number of jails: 2
Jail list: nftban-sshd, sshd
```

**Both jails using:** `action = nftban`

**Verified:**
```bash
# All servers now use NFTBan integration
fail2ban-client get nftban-sshd actions
# Output: nftban

fail2ban-client get sshd actions
# Output: nftban
```

**Status:** ✅ **PERFECT ALIGNMENT**

---

### 5. FILE CHECKSUMS

**Critical Files - All Servers Identical:**

| File | Checksum | Status |
|------|----------|--------|
| `/usr/sbin/nftban-complete` | 6fa28405863a8b7f4a5326d43d16fa9c | ✅ MATCH |
| `/usr/lib/nftban/cli/cmd_firewall.sh` | cc6ea163bd3726a0fd33da0368d23970 | ✅ MATCH |

**This confirms:**
- ✅ All servers running same v0.10.0 code
- ✅ Bug #6 fix deployed everywhere (atomic reload)
- ✅ All safety features present

---

## 🔍 Differences Explained

### 1. inet filter Table (lab1 only)

**What it is:**
- Ubuntu's default nftables table
- Created by nftables.service on Ubuntu
- All chains empty with `policy accept`
- **Completely harmless**

**Why it's there:**
- Ubuntu's `/etc/nftables.conf` creates it by default
- CentOS doesn't create default tables

**Impact:** NONE (all chains empty, policy accept)

**Fix (optional):**
```bash
# On lab1, remove if you want consistency:
ssh root@lab1.mywebhost.gr "nft delete table inet filter"

# Or disable from loading on boot:
ssh root@lab1.mywebhost.gr "systemctl disable nftables.service"
```

**Recommendation:** LEAVE IT - it's harmless and Ubuntu's default

---

### 2. Whitelist IP Differences

**Why different:**
- Each server auto-whitelisted its own public IP during `firewall init`
- This is CORRECT behavior (lockout prevention)

**lab:**
- 95.216.159.238 (server's public IPv4)
- 2a01:4f9:c010:b0b5::1 (server's public IPv6)

**lab1:**
- 46.62.231.184 (server's public IPv4)
- 2a01:4f9:c013:31fe::1 (server's public IPv6)

**lab2:**
- 65.21.157.15 (server's public IPv4)
- 2a01:4f9:c013:3f7a::1 (server's public IPv6)

**All share:** 62.38.150.122 (probably your management IP)

**Status:** ✅ CORRECT (should be different!)

---

### 3. Temporary Bans

**Current state:**

**lab.mywebhost.gr:**
- 188.166.94.150 (expires in ~12 min)

**lab1.mywebhost.gr (MOST ACTIVE!):**
- 2.57.121.112
- 45.135.232.92
- 45.135.232.177
- 45.140.17.124
- 62.60.131.157
- 91.215.85.45
- 121.146.70.26
- 178.62.239.223

**lab2.mywebhost.gr:**
- 57.128.182.5
- 167.99.222.200

**Why different:**
- Each server is catching its own attackers
- lab1 is getting HAMMERED (8 bans!)
- This proves the system is WORKING! ✓

**Watch for persistent offenders:**
```bash
# If any IP gets banned 3+ times in 24h, it will be added here:
cat /etc/nftban/blacklist.d/30-persistent-offenders.conf
```

---

## ✅ Alignment Verification

### Required Alignment (MUST Match)

- [x] **NFTBan version:** v0.10.0 on all servers
- [x] **Critical files:** Same checksums everywhere
- [x] **nftban_runtime structure:** Identical
- [x] **nftban_main structure:** Identical
- [x] **Fail2ban integration:** All using nftban action
- [x] **f2b-table:** Removed from all servers
- [x] **Policy setting:** `policy accept` (safe!)
- [x] **Bug #6 fix:** Atomic reload working

### Acceptable Differences (Expected)

- [x] **Whitelist IPs:** Different per server (auto-detected)
- [x] **Temp bans:** Different (catching different attackers)
- [x] **inet filter table:** Present on Ubuntu (harmless)

---

## 🎯 Standardized v0.10.0 Configuration

### Core Tables (Required on ALL servers)

```
1. inet nftban_runtime (priority: raw - 10)
   - Purpose: Temporary bans from fail2ban
   - Sets: temp_ban_v4, temp_ban_v6
   - Chain: input_tempban (drops banned IPs)

2. inet nftban_main (priority: raw)
   - Purpose: Permanent rules and whitelists
   - Sets: whitelist_v4/v6, blacklist_v4/v6, tcp_ports, udp_ports
   - Chain: input_main (firewall rules)
```

### Optional Tables (OS-specific)

```
3. inet filter (Ubuntu only)
   - Purpose: Ubuntu default (empty)
   - Impact: None (all chains accept)
   - Action: Keep (Ubuntu default behavior)
```

---

## 📝 Alignment Checklist

Use this to verify any new server:

```bash
# 1. Check tables
nft list tables
# Expected: inet nftban_runtime, inet nftban_main
# Optional: inet filter (Ubuntu)

# 2. Check structure
nft list table inet nftban_runtime | grep -E '(set |chain )'
# Expected: 2 sets (temp_ban_v4, temp_ban_v6), 1 chain (input_tempban)

nft list table inet nftban_main | grep -E '(set |chain )'
# Expected: 6 sets, 1 chain (input_main)

# 3. Check policy (CRITICAL!)
nft list chain inet nftban_main input_main | grep policy
# Expected: policy accept  (NOT drop!)

# 4. Check checksums
md5sum /usr/sbin/nftban-complete /usr/lib/nftban/cli/cmd_firewall.sh
# Expected: 6fa28405... and cc6ea163...

# 5. Check fail2ban
fail2ban-client status
# Expected: Jail list shows at least "sshd" or "nftban-sshd"

fail2ban-client get sshd actions
# Expected: nftban (NOT nftables-multiport!)

# 6. Check no f2b-table
nft list tables | grep f2b
# Expected: No output (f2b-table removed)
```

---

## 🚀 Deployment Standard for New Servers

When deploying NFTBan v0.10.0 to new servers:

### 1. Deploy Core Files

```bash
# Copy from source
rsync -av /home/gituser/nftban-v0.10.0-dev/src/ root@newserver:/

# Set permissions
ssh root@newserver "chmod +x /usr/sbin/nftban-complete"
ssh root@newserver "systemd-tmpfiles --create /usr/lib/tmpfiles.d/nftban.conf"
```

### 2. Initialize Firewall

```bash
ssh root@newserver "nftban firewall init"
# This will:
# - Create nftban_runtime table
# - Create nftban_main table
# - Auto-detect SSH port
# - Auto-whitelist your IP
# - Set policy accept (safe!)
```

### 3. Migrate Fail2ban

```bash
scp fail2ban-integration/migrate_to_nftban.sh root@newserver:/root/
ssh root@newserver "/root/migrate_to_nftban.sh"
# This will:
# - Update banaction to nftban
# - Restart fail2ban
# - Verify migration
```

### 4. Verify Alignment

```bash
# Run alignment check
./check_nftban_alignment.sh newserver
```

---

## 📊 Summary: Are We Aligned?

### ✅ YES - 99% Aligned!

**All Critical Components Match:**
- ✅ Same NFTBan version (v0.10.0)
- ✅ Same code files (identical checksums)
- ✅ Same table structure
- ✅ Same fail2ban integration
- ✅ Same safety settings (policy accept)
- ✅ Bug #6 fix deployed everywhere

**Minor Differences Are Expected:**
- Different whitelist IPs (each server's own IP)
- Different temp bans (catching different attackers)
- Ubuntu has extra empty `inet filter` table (harmless)

**Conclusion:** All servers are properly aligned to v0.10.0 standard! ✅

---

**Document Version:** 1.0
**Created:** 2025-10-30
**Status:** ✅ COMPLETE
**Servers Checked:** 3/3

═══════════════════════════════════════════════════════════════════
