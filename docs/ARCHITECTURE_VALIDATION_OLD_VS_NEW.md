# NFTBan Architecture Validation - OLD v0.9.x vs NEW v0.10.0
**Date:** 2025-10-27
**Purpose:** VALIDATE the heart of the system BEFORE implementing
**Status:** ⚠️ NEEDS USER APPROVAL - DO NOT IMPLEMENT YET!

═══════════════════════════════════════════════════════════════════════════════

## 🎯 CRITICAL QUESTION: What's Different in v0.10.0?

**Before we implement, we MUST answer:**
1. ✅ What architecture from v0.9.x do we KEEP?
2. ⚠️ What do we CHANGE for v0.10.0?
3. ⚠️ Why are we changing it?
4. ⚠️ What are the risks?

═══════════════════════════════════════════════════════════════════════════════

## 📊 OLD v0.9.x ARCHITECTURE (What We Have)

### Tables & Sets:

```
TABLE: ip nftban_v4
├── Set: whitelist (ipv4_addr, interval)
├── Set: temp_ban (ipv4_addr, timeout 1h)
├── Set: user_blacklist (ipv4_addr, interval)
├── Set: system_blacklist (ipv4_addr, interval)
└── Set: feeds (ipv4_addr, interval, auto-merge)

TABLE: ip6 nftban_v6
├── Set: whitelist (ipv6_addr, interval)
├── Set: temp_ban (ipv6_addr, timeout 1h)
├── Set: user_blacklist (ipv6_addr, interval)
├── Set: system_blacklist (ipv6_addr, interval)
└── Set: feeds (ipv6_addr, interval, auto-merge)
```

### Rule Order (v0.9.x):

```
INPUT CHAIN (12 rules):
1. ct state established,related → ACCEPT
2. iif lo → ACCEPT
3. ip saddr @whitelist → ACCEPT  ⭐ CRITICAL!
4. icmp type { echo-request, echo-reply } → ACCEPT
5. tcp dport <ssh_port> → ACCEPT  ⭐ SSH SAFETY
6. [Port rules from config files]
7. ct state invalid → DROP
8a. ct state new rate limit → DROP
8b. icmp flood rate limit → DROP
8c. tcp syn flood rate limit → DROP
9. ip saddr @temp_ban → DROP
10. ip saddr @user_blacklist → DROP
11. ip saddr @system_blacklist → DROP
12. ip saddr @feeds → DROP
[IMPLICIT ACCEPT - policy: accept]
```

### Storage Model:

```
DUAL STORAGE:
├── Files (persistent, survive reboot)
│   ├── /etc/nftban/config/whitelist_ips.conf
│   ├── /etc/nftban/config/blacklist_ips.conf
│   └── /etc/nftban/config/feeds/*-blacklist.conf
└── nftables Sets (active, fast O(1) lookup)
    ├── @whitelist
    ├── @temp_ban (timeout auto-expire)
    ├── @user_blacklist
    ├── @system_blacklist
    └── @feeds
```

═══════════════════════════════════════════════════════════════════════════════

## 🆕 NEW v0.10.0 ARCHITECTURE (What We Want?)

### ⚠️ CRITICAL QUESTIONS TO ANSWER:

**Question 1: Do we keep the SAME table structure?**
```
Option A: KEEP SAME (2 tables: nftban_v4, nftban_v6)
Option B: CHANGE (new table names? different structure?)

YOUR DECISION: _________________
```

**Question 2: Do we keep the SAME 5 sets?**
```
Current sets:
- whitelist
- temp_ban
- user_blacklist
- system_blacklist
- feeds

Option A: KEEP SAME (5 sets)
Option B: ADD MORE (which sets?)
Option C: REMOVE/RENAME (which ones?)

YOUR DECISION: _________________
```

**Question 3: Do we keep the SAME rule order?**
```
Current order:
1. CT established
2. Loopback
3. Whitelist ⭐
4. ICMP
5. SSH Safety ⭐
6. Port rules
7. CT invalid drop
8. DDoS rate limits
9-12. Blacklists (ordered)

Option A: KEEP SAME ORDER
Option B: CHANGE ORDER (specify new order)
Option C: ADD NEW RULES (which rules? where in order?)

YOUR DECISION: _________________
```

**Question 4: Do we keep the SAME storage model?**
```
Current: Dual storage (Files + nftables sets)

Option A: KEEP DUAL STORAGE (files + sets)
Option B: CHANGE TO DATABASE (PostgreSQL, SQLite, etc.)
Option C: CHANGE FILE LOCATIONS (new FHS paths?)

YOUR DECISION: _________________
```

**Question 5: What about GeoIP blocking?**
```
v0.9.x: GeoIP NOT in nftables (separate check)

Option A: KEEP SEPARATE (GeoIP check before nftables)
Option B: ADD TO NFTABLES (new set: geoip_blocked)
Option C: USE nftables MAPS (IP → country mapping)

YOUR DECISION: _________________
```

**Question 6: What about rate limiting?**
```
v0.9.x: 3 rate limit rules (connection, ICMP, SYN flood)

Option A: KEEP SAME (3 rules)
Option B: ADD MORE (SSH brute force, HTTP flood, etc.)
Option C: REMOVE (handle elsewhere?)

YOUR DECISION: _________________
```

**Question 7: What about logging?**
```
v0.9.x: counter only (no logging in nftables)

Option A: KEEP COUNTER ONLY
Option B: ADD nftables LOG (which rules to log?)
Option C: HYBRID (counter + selective logging)

YOUR DECISION: _________________
```

**Question 8: What about port management?**
```
v0.9.x: Port rules from config files
Format: PORT|PROTOCOL (22|T, 80|T, 53|U, etc.)

Option A: KEEP SAME (config file approach)
Option B: CHANGE FORMAT (JSON, YAML, etc.)
Option C: USE nftables MAPS (port → service mapping)

YOUR DECISION: _________________
```

═══════════════════════════════════════════════════════════════════════════════

## 🔍 KEY DIFFERENCES TO CONSIDER FOR v0.10.0

### Difference #1: FHS Compliance

**OLD v0.9.x:**
```
/etc/nftban/config/whitelist_ips.conf
/etc/nftban/config/blacklist_ips.conf
/etc/nftban/ports/ipv4-input.conf
```

**NEW v0.10.0 (FHS standard):**
```
/etc/nftban/whitelist.conf  (or different name?)
/etc/nftban/blacklist.conf
/etc/nftban/ports.d/input.conf  (or different structure?)
```

**DECISION NEEDED:** What are the NEW file paths?

### Difference #2: Modular Architecture

**OLD v0.9.x:**
- Monolithic modules (one file does everything)

**NEW v0.10.0:**
- Modular design (separate concerns)
- CLI handlers vs core logic vs reports

**IMPACT ON nftables:**
- Do we split nftables logic into multiple modules?
- How do modules interact with nftables?

**DECISION NEEDED:** How does modular design affect nftables?

### Difference #3: Go Integration (GeoIP)

**OLD v0.9.x:**
- Bash-only (ipcalc, sipcalc for IP validation)

**NEW v0.10.0:**
- Go binary for GeoIP (nftban-geoip)
- Ultra-fast lookups

**IMPACT ON nftables:**
- Do we add GeoIP to nftables sets?
- Or keep as pre-check before nftables?

**DECISION NEEDED:** How does Go GeoIP integrate with nftables?

### Difference #4: Report System

**OLD v0.9.x:**
- Reports generated from nftables counters
- Live queries to nftables

**NEW v0.10.0:**
- Reports as dedicated modules
- Possible caching/pre-computed stats?

**IMPACT ON nftables:**
- Do we need additional counters?
- Do we need logging for reports?

**DECISION NEEDED:** What nftables data do reports need?

═══════════════════════════════════════════════════════════════════════════════

## ⚠️ RISKS & CONCERNS

### Risk #1: Breaking Existing Deployments

**Concern:** Users have v0.9.x deployed
**Risk:** v0.10.0 incompatible = broken systems

**Mitigation Options:**
- Option A: Keep 100% compatible (same tables/sets/rules)
- Option B: Provide migration script (auto-convert v0.9.x → v0.10.0)
- Option C: Break compatibility (document clearly, provide rollback)

**DECISION NEEDED:** How do we handle migration?

### Risk #2: Performance Regression

**Concern:** v0.10.0 slower than v0.9.x
**Risk:** Users complain about performance

**Mitigation:**
- Keep CT established as RULE #1 (95% fast path)
- No unnecessary rules
- Benchmark before release

**DECISION NEEDED:** Any performance-critical changes?

### Risk #3: Security Regression

**Concern:** New architecture has security holes
**Risk:** Users get hacked

**Critical Points:**
- Whitelist MUST be before drops (security guarantee)
- SSH safety MUST remain (lockout prevention)
- CT invalid MUST drop (malformed packet protection)

**DECISION NEEDED:** Any security-critical changes?

### Risk #4: Complexity Increase

**Concern:** v0.10.0 too complex to maintain
**Risk:** Bugs, hard to troubleshoot

**Mitigation:**
- Keep architecture simple
- Document thoroughly
- Maintain backwards compatibility where possible

**DECISION NEEDED:** How complex can we go?

═══════════════════════════════════════════════════════════════════════════════

## 🎯 RECOMMENDED ARCHITECTURE FOR v0.10.0

### My Recommendation (Conservative Approach):

**✅ KEEP FROM v0.9.x:**
1. Table structure (nftban_v4, nftban_v6)
2. 5 sets (whitelist, temp_ban, user_blacklist, system_blacklist, feeds)
3. Rule order (proven, secure, fast)
4. Dual storage (files + nftables sets)
5. CT as RULE #1 (performance critical)
6. Whitelist BEFORE drops (security critical)
7. SSH safety rule (lockout prevention)

**⚠️ CHANGE FOR v0.10.0:**
1. File paths (FHS compliance)
   - OLD: `/etc/nftban/config/whitelist_ips.conf`
   - NEW: `/etc/nftban/whitelist.conf`
2. Add logging (selective, not all rules)
   - Log drops from blacklists (for reports)
   - Don't log accepts (too noisy)
3. Add GeoIP set (optional)
   - NEW: `geoip_blocked` set (if country blocking enabled)
   - Add as RULE 13 (after feeds, before implicit accept)
4. Modular code structure
   - Same nftables architecture
   - Better organized code (modules)

**➕ ADD FOR v0.10.0:**
1. Optional: More DDoS rules
   - HTTP flood protection (tcp dport 80/443 rate limit)
   - SSH brute force (tcp dport 22 rate limit per IP)
2. Optional: Logging for debugging
   - Log temp_ban drops (helps troubleshooting)
   - Log rate limit drops (identify attacks)

**❌ DON'T CHANGE:**
1. Core rule order (too risky)
2. Set names (breaks compatibility)
3. Table names (migration nightmare)
4. Performance-critical paths (CT established)

═══════════════════════════════════════════════════════════════════════════════

## 📋 VALIDATION CHECKLIST

Before implementing, confirm:

- [ ] Table names: `nftban_v4`, `nftban_v6` (same as v0.9.x?)
- [ ] Set names: whitelist, temp_ban, user_blacklist, system_blacklist, feeds (same?)
- [ ] Rule order: CT → loopback → whitelist → ... (same?)
- [ ] File paths: New FHS locations (what are they?)
- [ ] Port config format: Same as v0.9.x (PORT|PROTOCOL)?
- [ ] GeoIP integration: Where in architecture? (new set? separate check?)
- [ ] Logging: What to log? (drops? accepts? rate limits?)
- [ ] Backwards compatibility: Migration plan? (script? manual?)

═══════════════════════════════════════════════════════════════════════════════

## 🚨 STOP! DO NOT PROCEED UNTIL ANSWERS PROVIDED!

**I NEED YOUR ANSWERS TO:**

1. **Keep same tables/sets?** (YES/NO, if NO: specify changes)
2. **Keep same rule order?** (YES/NO, if NO: specify new order)
3. **New file paths?** (Specify FHS paths for v0.10.0)
4. **GeoIP in nftables?** (YES/NO/SEPARATE, specify approach)
5. **Add logging?** (NONE/SELECTIVE/ALL, specify what to log)
6. **Backwards compatibility?** (FULL/MIGRATION/BREAK, specify approach)
7. **Any other changes?** (Specify anything else you want different)

═══════════════════════════════════════════════════════════════════════════════

## 🎯 NEXT STEPS (After Validation)

**Once you provide answers:**

1. ✅ Finalize architecture specification
2. ✅ Create implementation plan
3. ✅ Write nftables module code
4. ✅ Test on lab servers
5. ✅ Deploy to production

**But we CANNOT proceed without your decisions above!**

═══════════════════════════════════════════════════════════════════════════════

**⚠️ WAITING FOR YOUR INPUT - THE HEART MUST BE PERFECT!** ⚠️
