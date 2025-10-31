# Bug: Port Report Doesn't Detect Set-Based nftables Rules

**Date Reported:** 2025-10-30
**Status:** 🐛 CONFIRMED BUG
**Severity:** LOW (cosmetic/reporting issue, doesn't affect firewall functionality)
**Component:** Port Status Report (`nftban port status`)

---

## Issue Description

The `nftban port status` command reports "? No-rule" for ports that ARE actually allowed in nftables, including SSH port 22.

### User Report

```bash
[root@server ~]# nftban port status
════════════════════════════════════════════════════════════════════════════════════
 Port Status Report — 2025-10-30T20:32:39+00:00
════════════════════════════════════════════════════════════════════════════════════
SERVICE        PORT   PROTO  RUNNING  IPv4 IN   IPv4 OUT  IPv6 IN   IPv6 OUT  NOTES
------------------------------------------------------------------------------------
ssh            22     tcp    yes      ? No-rule ? No-rule ? No-rule ? No-rule PUBLIC
brcd           323    udp    yes      ? No-rule ? No-rule ? No-rule ? No-rule LOCAL-ONLY

✔ allowed   ✖ blocked   ? no-rule/unknown
Legend: 'No-rule' = no explicit nft input/output rule for that port; default policy may apply.
```

**User Feedback:**
> "should report correct if allowed or not ??? why to understand no-rule ok its ssh i am connect but should be clear the message"

**Issue:** SSH port 22 is CLEARLY working (user is connected), and IS configured in NFTBan firewall, but report shows "? No-rule" which is confusing and incorrect.

---

## Root Cause Analysis

### 1. How NFTBan Firewall Works

NFTBan v0.10.0 uses **set-based architecture**:

```nft
# Define sets
set tcp_ports {
    type inet_service
    comment "Allowed TCP ports"
    elements = { 22, 80, 443 }
}

# Use sets in rules
chain input_main {
    type filter hook input priority raw; policy accept;
    ...
    tcp dport @tcp_ports accept  ← SET-BASED RULE
    ...
}
```

**Benefits:**
- Efficient for many ports
- Single rule handles all TCP ports
- Easy to update (just modify set)

### 2. How Port Report Scans

Port report module (`nftban_report_port.sh`) scans nftables rules using regex:

**File:** `src/usr/lib/nftban/core/nftban_report_port.sh:165`

```bash
if [[ "$line" =~ (tcp|udp)[[:space:]]+dport[[:space:]]+([0-9]+) ]]; then
    # This matches:   tcp dport 22 accept   ✓
    # This matches:   udp dport 53 accept   ✓
    # Does NOT match: tcp dport @tcp_ports accept   ✗ BUG!
    ...
fi
```

**The regex only matches direct port numbers, not set references.**

### 3. What Actually Exists

**Actual nftables rules:**
```bash
[root@server ~]# nft list table inet nftban_main
...
set tcp_ports {
    type inet_service
    comment "Allowed TCP ports"
    elements = { 22 }  ← SSH PORT IS HERE
}

chain input_main {
    ...
    tcp dport @tcp_ports accept  ← RULE EXISTS BUT NOT DETECTED
    ...
}
```

**Port report sees:** `tcp dport @tcp_ports accept`
**Port report regex expects:** `tcp dport 22 accept`
**Result:** No match → reports "No-rule"

---

## Impact Assessment

### Actual Firewall Status ✅

- ✅ SSH port 22 IS allowed in nftables
- ✅ Firewall IS working correctly
- ✅ Port IS protected by nftban_main table
- ✅ Users CAN connect to SSH

### Port Report Status ❌

- ❌ Port report shows "? No-rule" (incorrect)
- ❌ Confusing for users
- ❌ Makes it look like firewall not working
- ❌ Reduces confidence in NFTBan

### Severity

**Severity:** LOW

**Justification:**
1. Cosmetic/reporting issue only
2. Does NOT affect actual firewall functionality
3. Ports ARE protected correctly
4. Only affects `nftban port status` command
5. Other health checks (firewall check, FHS check) work fine

**Business Impact:**
- User confusion about firewall status
- Reduced trust in reporting accuracy
- Not blocking functionality or causing security issues

---

## Examples of Misreported Ports

### SSH Port 22 (Most Critical)

**Actual Status:**
```bash
nft list table inet nftban_main | grep -A 2 tcp_ports
set tcp_ports {
    type inet_service
    comment "Allowed TCP ports"
    elements = { 22 }
}
...
tcp dport @tcp_ports accept
```

**Port Report Says:** `? No-rule ? No-rule ? No-rule ? No-rule`
**Reality:** ✅ ALLOWED via set-based rule

### Any Port in tcp_ports or udp_ports Sets

**Will Show:** `? No-rule`
**Reality:** ✅ ALLOWED

### Ports with Direct Rules (Non-NFTBan)

**Example:** Some firewall setups use `tcp dport 443 accept`
**Will Show:** ✅ Allowed (correctly detected)
**Why:** Matches the direct port number regex

---

## Why This Matters

### User Experience

1. **Confusing Reports:**
   - Users see "No-rule" for working ports
   - Appears like firewall not configured
   - Contradicts actual behavior

2. **Trust Issues:**
   - If SSH shows "No-rule" but works, what else is wrong?
   - Reduces confidence in other NFTBan reports
   - May lead to unnecessary debugging

3. **Support Burden:**
   - Users will report "bug: SSH shows no-rule"
   - Need to explain set-based architecture
   - Wastes time on non-issues

### Technical Debt

1. **Incomplete Implementation:**
   - Port report written before set-based architecture
   - Never updated for v0.10.0 changes
   - Assumptions no longer valid

2. **Mixed Architectures:**
   - NFTBan uses sets (modern, efficient)
   - Port report expects direct rules (old style)
   - Mismatch causes reporting failures

---

## Fix Required

### Solution 1: Parse Sets and References (Recommended)

**Approach:** Enhance port report to understand set-based rules

**Implementation:**

1. **Parse set definitions:**
   ```bash
   # Find all sets and their contents
   nft list table inet nftban_main | awk '
   /^[[:space:]]*set tcp_ports/ { in_set=1; proto="tcp"; next }
   /^[[:space:]]*set udp_ports/ { in_set=1; proto="udp"; next }
   in_set && /elements = \{/ {
       gsub(/[{}]/, "");
       for (i=3; i<=NF; i++) {
           port=$i; gsub(/[, ]/, "", port);
           print port, proto;
       }
       in_set=0;
   }
   '
   ```

2. **Detect set-based rules:**
   ```bash
   if [[ "$line" =~ (tcp|udp)[[:space:]]+dport[[:space:]]+@([[:alnum:]_]+)[[:space:]]+(accept|drop|reject) ]]; then
       proto="${BASH_REMATCH[1]}"
       set_name="${BASH_REMATCH[2]}"
       action="${BASH_REMATCH[3]}"
       # Mark all ports in this set with this action
   fi
   ```

3. **Match ports to sets:**
   - Build map: `tcp_ports → [22, 80, 443]`
   - Build map: `udp_ports → [53, 123]`
   - When checking port 22 tcp: look in tcp_ports set
   - If found + rule is `tcp dport @tcp_ports accept` → report "Allowed"

**Effort:** MEDIUM (2-3 hours)

**Files to Change:**
- `src/usr/lib/nftban/core/nftban_report_port.sh:152-179` (add set parsing)

### Solution 2: Query nft Directly for Each Port

**Approach:** Instead of parsing full ruleset, query nft for specific port

```bash
# Check if port 22 tcp would be accepted
nft --json list table inet nftban_main | jq '...'
# Or use nft with port matching

# Problem: nft doesn't have a "test packet" mode
# Would need complex JSON parsing
```

**Effort:** HIGH (harder to implement reliably)

### Solution 3: Integrate with nftban_main Builder

**Approach:** When building nftban_main table, also save port→action map

```bash
# In nftban-complete when building table:
# Save metadata file: /var/lib/nftban/port_status.json
{
    "tcp": {
        "22": "accept",
        "80": "accept",
        "443": "accept"
    },
    "udp": {
        "53": "accept"
    }
}

# Port report reads this file instead of parsing nft
```

**Effort:** MEDIUM (requires changes to nftban-complete)

**Benefits:**
- Fastest at runtime (no parsing)
- Always accurate (generated from same source)
- Easy to query

---

## Workaround (Current)

### For Users

**To verify SSH port is actually allowed:**

```bash
# Check nftban_main table directly
nft list table inet nftban_main | grep -A 5 tcp_ports

# Expected output:
set tcp_ports {
    type inet_service
    comment "Allowed TCP ports"
    elements = { 22 }  ← Your port should be here
}

# Check if rule exists
nft list chain inet nftban_main input_main | grep tcp_ports

# Expected output:
tcp dport @tcp_ports accept  ← This allows all ports in set
```

### For Developers

**Use firewall check instead:**

```bash
nftban firewall check
# This checks table existence and basic structure
# Doesn't report per-port status but verifies firewall working
```

---

## Implementation Plan

### Phase 1: Investigation (DONE ✅)

- [x] Reproduce issue on test system
- [x] Identify root cause (regex doesn't match set references)
- [x] Document bug thoroughly
- [x] Assess impact (LOW severity)

### Phase 2: Design (NEXT)

- [ ] Choose implementation approach (Solution 1 recommended)
- [ ] Design set parsing algorithm
- [ ] Design port→set→action mapping
- [ ] Create test cases

### Phase 3: Implementation

- [ ] Implement set parsing in `nftban_report_port.sh`
- [ ] Update port status determination logic
- [ ] Handle edge cases (empty sets, multiple tables)
- [ ] Add comments explaining set-based detection

### Phase 4: Testing

- [ ] Test on production system with current firewall config
- [ ] Verify SSH port 22 shows "Allowed"
- [ ] Test with ports NOT in sets (should show "No-rule")
- [ ] Test with ports in blacklist (should show "Blocked")
- [ ] Test with no nftban tables (should show "No-rule")

### Phase 5: Deployment

- [ ] Deploy fix to lab servers
- [ ] Update documentation
- [ ] Add to CHANGELOG
- [ ] Release in next version (v0.10.1)

---

## Timeline

| Milestone | Target Date | Status |
|-----------|-------------|--------|
| Bug Reported | 2025-10-30 | ✅ DONE |
| Root Cause Found | 2025-10-30 | ✅ DONE |
| Documentation | 2025-10-30 | ✅ DONE |
| Design Solution | 2025-10-31 | ⏸️  PENDING |
| Implementation | TBD | ⏸️  PENDING |
| Testing | TBD | ⏸️  PENDING |
| Release | TBD | ⏸️  PENDING |

---

## Related Issues

### Similar Problems

1. **GeoIP report might have same issue**
   - If using set-based IP matching
   - Need to check `nftban geoip status` output

2. **Feed report might have same issue**
   - Threat feeds use sets
   - Need to check `nftban feeds status` output

3. **Any module parsing nft output**
   - Search for similar regex patterns
   - Update all to handle set-based rules

### Prevention

1. **Add unit tests for port report:**
   - Test with set-based rules
   - Test with direct rules
   - Test with no rules
   - Test with both mixed

2. **Document nftables architecture:**
   - Explain set-based approach
   - Document all modules that parse nft output
   - Flag modules needing updates

3. **Regression testing:**
   - Add port report to health check suite
   - Verify known ports show correct status
   - Alert if "No-rule" for configured ports

---

## References

### Code Locations

- **Port Report Module:** `src/usr/lib/nftban/core/nftban_report_port.sh`
- **Bug Location:** Line 165 (regex pattern)
- **Port Status Command:** `src/usr/lib/nftban/cli/cmd_port.sh`
- **nftban-complete:** `src/usr/sbin/nftban-complete` (builds nftban_main)

### Related Documentation

- [Port Management Guide](../reference/ip-port-management.md)
- [nftables Architecture](../architecture/MAIN_TABLE_EXPLANATION.md)
- [CLI Quick Reference](../reference/cli-quick-reference.md)

### nftables Resources

- nftables Wiki: https://wiki.nftables.org/
- Set-based matching: https://wiki.nftables.org/wiki-nftables/index.php/Sets
- JSON output: https://wiki.nftables.org/wiki-nftables/index.php/JSON

---

## Conclusion

Port report module uses regex pattern designed for direct port rules but NFTBan v0.10.0 uses set-based architecture. Result: ports configured in sets show as "No-rule" even though they're correctly allowed.

**Status:** Confirmed bug, low severity (cosmetic), fix needed but not urgent.

**Recommendation:** Fix in next minor release (v0.10.1), doesn't block v0.10.0 deployment.

---

**Document Status:** COMPLETE
**Bug Status:** 🐛 CONFIRMED, DOCUMENTED, FIX PENDING
**Last Updated:** 2025-10-30 23:00 UTC
