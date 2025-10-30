# NFTBan nftables Architecture - High-Level Design (HLD)
**Version:** 0.10.0
**Date:** 2025-10-29
**Status:** 🔴 NEEDS REVIEW - Architecture conflicts detected

═══════════════════════════════════════════════════════════════════

## EXECUTIVE SUMMARY

**CRITICAL FINDINGS:**
1. ✅ **Fail2ban Integration Works** - Using `f2b-table` (inet family)
2. ✅ **Ban Management Works** - Using `nftban_runtime` table with temporary bans
3. ⚠️ **Port Management INCOMPLETE** - Missing proper firewall table structure
4. ⚠️ **Multiple Table Naming** - Inconsistency across servers
5. ⚠️ **No Centralized Firewall Rules** - Only ban sets, no port allow/deny rules

---

## CURRENT STATE AUDIT

### Server: lab.example.test
```
TABLES:
  - inet nftban_runtime  (NFTBan - ban management)
  - inet f2b-table       (Fail2ban integration)

CHAINS:
  nftban_runtime:
    - input_tempban (priority: raw-10) - Drop banned IPs
    - input (priority: filter) - 1 rule (TCP 20 from testing)
    - output (priority: filter) - Empty

  f2b-table:
    - f2b-chain (priority: filter-1) - Fail2ban bans
```

### Server: lab1.example.test
```
TABLES:
  - inet filter          (System default filter)
  - inet f2b-table       (Fail2ban integration)
  - inet nftban_runtime  (NFTBan - ban management)

CHAINS:
  filter:
    - input, forward, output (all empty, default policy accept)

  nftban_runtime:
    - input_tempban (priority: raw-10) - Drop banned IPs
    NO input/output chains for port management!
```

### Server: lab2.example.test
```
TABLES:
  - inet nftban_runtime  (NFTBan - ban management only)

CHAINS:
  nftban_runtime:
    - input_tempban (priority: raw-10) - Drop banned IPs
    NO input/output chains for port management!
```

---

## ARCHITECTURE DESIGN

### 1. TABLE STRUCTURE (Proposed)

NFTBan should use a **SINGLE inet table** with clear chain separation:

```
table inet nftban {
    # ═══════════════════════════════════════
    # SETS (IP Lists)
    # ═══════════════════════════════════════

    set temp_ban_v4 {
        type ipv4_addr
        flags timeout
        comment "Temporary bans (1h-7d)"
    }

    set temp_ban_v6 {
        type ipv6_addr
        flags timeout
        comment "Temporary bans (1h-7d)"
    }

    set perm_ban_v4 {
        type ipv4_addr
        comment "Permanent bans"
    }

    set perm_ban_v6 {
        type ipv6_addr
        comment "Permanent bans"
    }

    set whitelist_v4 {
        type ipv4_addr
        comment "Whitelisted IPs (never ban)"
    }

    set whitelist_v6 {
        type ipv6_addr
        comment "Whitelisted IPs (never ban)"
    }

    # ═══════════════════════════════════════
    # CHAINS (Processing Order)
    # ═══════════════════════════════════════

    # PRIORITY ORDER (lower number = earlier processing):
    # raw-10    → BAN ENFORCEMENT (drop banned IPs first)
    # filter-10 → WHITELIST (accept whitelisted IPs)
    # filter-5  → DDOS PROTECTION
    # filter-1  → PORT SCAN DETECTION
    # filter    → PORT RULES (allow/deny specific ports)
    # filter+10 → LOGGING (log remaining packets)

    chain ban_enforcement {
        type filter hook input priority raw - 10; policy accept;
        comment "Drop banned IPs immediately"
        ip saddr @temp_ban_v4 drop
        ip6 saddr @temp_ban_v6 drop
        ip saddr @perm_ban_v4 drop
        ip6 saddr @perm_ban_v6 drop
    }

    chain whitelist_accept {
        type filter hook input priority filter - 10; policy accept;
        comment "Accept whitelisted IPs early"
        ip saddr @whitelist_v4 accept
        ip6 saddr @whitelist_v6 accept
    }

    chain ddos_protection {
        type filter hook input priority filter - 5; policy accept;
        comment "DDoS mitigation rules"
        # SYN flood, connection limits, etc.
    }

    chain portscan_detection {
        type filter hook input priority filter - 1; policy accept;
        comment "Port scan detection"
        # Log and limit port scanning
    }

    chain input {
        type filter hook input priority filter; policy drop;
        comment "Main firewall INPUT rules"

        # Accept loopback
        iif lo accept

        # Accept established/related
        ct state established,related accept

        # Drop invalid
        ct state invalid drop

        # ICMP (ping)
        ip protocol icmp accept
        ip6 nexthdr ipv6-icmp accept

        # Allowed ports (managed by nftban port command)
        # tcp dport {22, 80, 443, ...} accept
        # udp dport {53, ...} accept
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
        comment "Forwarding rules (if router)"
    }

    chain output {
        type filter hook output priority filter; policy accept;
        comment "Outbound firewall rules"

        # Usually accept all outbound
        # Can add restrictions if needed
    }

    chain logging {
        type filter hook input priority filter + 10; policy accept;
        comment "Log dropped packets"
        limit rate 10/minute log prefix "nftban: DROP: "
    }
}
```

### 2. FAIL2BAN INTEGRATION

**Current:** Fail2ban uses **separate** `f2b-table` table
**Status:** ✅ KEEP AS-IS (works perfectly)

```
table inet f2b-table {
    set addr-set-sshd { ... }
    set addr-set-recidive { ... }

    chain f2b-chain {
        type filter hook input priority filter - 1;
        tcp dport 22 ip saddr @addr-set-sshd reject
        ...
    }
}
```

**Why separate:** Fail2ban manages this table independently. Do NOT merge.

### 3. COMMAND ARCHITECTURE

#### Ban Management (Working ✅)
```
nftban ban <IP>         → Add to temp_ban_v4/v6 set in nftban table
nftban unban <IP>       → Remove from all ban sets
nftban list             → List all banned IPs from sets
nftban search <IP>      → Search IP across all sets
```

**Implementation:** Bash scripts manipulating nftables sets
**Go Integration:** None currently (could add Go binary for performance)

#### Port Management (Broken ⚠️)
```
nftban port status            → Show listening ports + firewall status
nftban port allow-panel <panel> → Configure control panel ports
```

**Current Issues:**
1. No dedicated firewall chains for port rules
2. DirectAdmin command creates chains dynamically (wrong approach)
3. No persistent port configuration
4. Hangs during execution (unknown cause)

**Proposed Fix:**
1. Pre-create `input/output` chains in `nftban` table at install
2. Store port rules persistently
3. Use `nft add rule` for individual ports
4. Add `nftban port add <port>` and `nftban port remove <port>` commands

---

## GO/GOLANG INTEGRATION

### Current Go Programs

1. **nftban-feeds** (`go-feeds/`)
   - Purpose: Parse threat intelligence feeds
   - nftables interaction: **NONE** (outputs JSON only)
   - Status: ✅ Works independently

2. **nftban-geoip** (`go-geoip/`)
   - Purpose: IP geolocation lookups
   - nftables interaction: **NONE** (reads MaxMind DB)
   - Status: ✅ Works independently

### Proposed Go Integration

```
┌────────────────────────────────────────────────────────────┐
│                    NFTBan Architecture                      │
├────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌──────────────┐         ┌──────────────┐                │
│  │ Bash Scripts │◄────────┤ Go Binaries  │                │
│  │              │         │              │                │
│  │ - nftban CLI │         │ - feeds      │                │
│  │ - Core logic │         │ - geoip      │                │
│  │ - Reporting  │         │ - stats (?)  │                │
│  └──────┬───────┘         └──────┬───────┘                │
│         │                        │                         │
│         └────────┬───────────────┘                         │
│                  │                                          │
│                  ▼                                          │
│         ┌────────────────┐                                 │
│         │   nftables     │                                 │
│         │                │                                 │
│         │ - inet nftban  │  Main firewall table           │
│         │ - inet f2b-table│  Fail2ban (separate)          │
│         └────────────────┘                                 │
│                                                             │
└────────────────────────────────────────────────────────────┘
```

**Key Points:**
- Go programs do NOT directly manipulate nftables
- Bash scripts call `nft` command (system binary)
- Go programs process data, output JSON
- Bash consumes JSON and updates nftables

**Why not Go for nftables?**
- `nft` command is stable and well-tested
- Bash integration is simpler for admin scripts
- Go nftables libraries exist but add complexity
- Current approach works well

---

## HEALTH CHECK DESIGN

### Proposed: `nftban health nftables`

```bash
#!/bin/bash
# Check nftables health

echo "═══ NFTables Health Check ═══"
echo ""

# 1. Check nftables service
if systemctl is-active --quiet nftables; then
    echo "✅ nftables service: ACTIVE"
else
    echo "❌ nftables service: INACTIVE"
fi

# 2. Check required tables
for table in "inet nftban" "inet f2b-table"; do
    if nft list table $table &>/dev/null; then
        echo "✅ Table exists: $table"
    else
        echo "⚠️  Table missing: $table"
    fi
done

# 3. Check required chains
for chain in "ban_enforcement" "input" "output"; do
    if nft list chain inet nftban $chain &>/dev/null; then
        echo "✅ Chain exists: inet nftban $chain"
    else
        echo "⚠️  Chain missing: inet nftban $chain"
    fi
done

# 4. Check ban sets
echo ""
echo "Ban Sets:"
nft list set inet nftban temp_ban_v4 2>/dev/null | grep "elements" || echo "  temp_ban_v4: empty"
nft list set inet nftban temp_ban_v6 2>/dev/null | grep "elements" || echo "  temp_ban_v6: empty"

# 5. Check rule counts
echo ""
echo "Rule Counts:"
for chain in input output; do
    count=$(nft list chain inet nftban $chain 2>/dev/null | grep -c "accept\|drop\|reject" || echo 0)
    echo "  $chain: $count rules"
done

# 6. Check firewall policy
echo ""
echo "Default Policies:"
nft list chain inet nftban input 2>/dev/null | grep "policy" || echo "  input: not set"
nft list chain inet nftban output 2>/dev/null | grep "policy" || echo "  output: not set"

# 7. Check for conflicts
echo ""
echo "Checking for conflicts..."
all_tables=$(nft list tables | wc -l)
echo "  Total tables: $all_tables"
if [[ $all_tables -gt 3 ]]; then
    echo "  ⚠️  More than expected tables (2-3 normal)"
    nft list tables
fi
```

---

## MIGRATION ISSUES IDENTIFIED

### Issue 1: Table Naming Inconsistency
**Problem:** `nftban_runtime` vs `nftban` vs `filter`
**Impact:** Port command tries multiple table names
**Solution:** Standardize on `inet nftban` across all servers

### Issue 2: Missing Firewall Chains
**Problem:** Only ban chains exist, no port rule chains
**Impact:** Port management doesn't work properly
**Solution:** Create input/output chains at installation

### Issue 3: Dynamic Chain Creation
**Problem:** DirectAdmin command creates chains on-the-fly
**Impact:** Causes hangs, unpredictable behavior
**Solution:** Pre-create chains, only add rules dynamically

### Issue 4: No Persistent Rules
**Problem:** nftables rules not saved after reboot
**Impact:** Configuration lost on server restart
**Solution:** Add `nft list ruleset > /etc/nftables.conf` after changes

### Issue 5: No IP Add/Remove Commands
**Problem:** User mentioned "nftban ip add/remove" but doesn't exist
**Impact:** Confusion about command structure
**Solution:**
- Document that it's `nftban ban/unban` not `nftban ip`
- OR add `nftban ip` as alias to `nftban ban`

---

## RECOMMENDED ACTIONS

### Immediate (High Priority)

1. **Standardize Table Name**
   ```bash
   # Rename nftban_runtime → nftban on all servers
   nft add table inet nftban
   # Migrate sets and chains
   # Delete old nftban_runtime table
   ```

2. **Create Missing Chains**
   ```bash
   nft add chain inet nftban input '{ type filter hook input priority filter; policy drop; }'
   nft add chain inet nftban output '{ type filter hook output priority filter; policy accept; }'
   ```

3. **Fix DirectAdmin Implementation**
   - Remove dynamic chain creation
   - Pre-check chains exist
   - Add rules only (not chains)

4. **Add Health Check Command**
   - Implement `nftban health nftables`
   - Show table/chain status
   - Detect conflicts

### Short Term (This Week)

5. **Document Architecture**
   - Publish this HLD
   - Create diagrams
   - Update README

6. **Add Persistence**
   - Save rules to `/etc/nftables.conf`
   - Enable nftables.service
   - Test reboot recovery

7. **Test Suite**
   - Test ban/unban
   - Test port add/remove
   - Test fail2ban integration

### Long Term (Future Versions)

8. **Unified CLI**
   - Add `nftban ip` as alias
   - Add `nftban firewall` commands
   - Improve help text

9. **Go Performance**
   - Consider Go binary for ban operations
   - Benchmark vs bash+nft
   - Only if needed

10. **Web Interface**
    - Dashboard for firewall status
    - Real-time ban monitoring
    - Port management GUI

---

## QUESTIONS FOR REVIEW

1. **Should we keep separate `f2b-table` or merge into `nftban`?**
   - Recommendation: KEEP SEPARATE (Fail2ban manages it)

2. **Should we use `inet nftban` or `inet nftban_runtime`?**
   - Recommendation: Use `nftban` (shorter, clearer)

3. **Should we add `nftban ip add/remove` commands?**
   - Recommendation: YES, as aliases to ban/unban

4. **Should Go binaries interact with nftables directly?**
   - Recommendation: NO, keep bash+nft approach

5. **How to handle port persistence across reboots?**
   - Recommendation: Save to /etc/nftables.conf after changes

6. **Should we create a firewall initialization script?**
   - Recommendation: YES, `nftban firewall init` command

---

## COMPATIBILITY MATRIX

| Component | Bash | Go | nftables | Status |
|-----------|------|----|---------|----|
| Ban/Unban | ✅ | ❌ | ✅ | Working |
| Port Management | ⚠️ | ❌ | ⚠️ | Broken |
| Feeds | ✅ | ✅ | ❌ | Working |
| GeoIP | ✅ | ✅ | ❌ | Working |
| Fail2ban | ✅ | ❌ | ✅ | Working |
| Health Check | ❌ | ❌ | ❌ | Missing |

**Legend:**
- ✅ Implemented and working
- ⚠️ Partially working or broken
- ❌ Not implemented

---

## CONCLUSION

**Current Status:** NFTBan v0.10.0 has a **split architecture** with:
- ✅ Working ban management (IP blocking)
- ✅ Working Fail2ban integration
- ⚠️ Broken port management (firewall rules)
- ❌ Missing health checks
- ❌ Missing persistent storage

**Root Cause:** Migration from 0.9.5 → 0.10.0 focused on features but didn't establish a solid nftables foundation.

**Next Steps:**
1. Review and approve this HLD
2. Implement immediate fixes (standardize tables, create chains)
3. Fix DirectAdmin port command
4. Add comprehensive health checks
5. Document everything

═══════════════════════════════════════════════════════════════════
**Document Status:** 🔴 DRAFT - REQUIRES APPROVAL
**Last Updated:** 2025-10-29
**Author:** Claude Code + User Review
═══════════════════════════════════════════════════════════════════
