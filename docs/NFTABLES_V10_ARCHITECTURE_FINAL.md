# NFTBan v0.10.0 - nftables Architecture FINAL SPECIFICATION
**Date:** 2025-10-27
**Status:** ✅ APPROVED - Ready for Implementation
**Basis:** User decisions + v0.9.x proven architecture

═══════════════════════════════════════════════════════════════════════════════

## ✅ CONFIRMED DECISIONS (KEEP FROM v0.9.x)

### 1. Table Structure - SAME ✅
```
TABLE: ip nftban_v4
TABLE: ip6 nftban_v6
```
**Decision:** Keep exact same names

### 2. Set Structure - SAME ✅
```
Per table (both IPv4 and IPv6):
├── whitelist        (interval)
├── temp_ban         (timeout 1h)
├── user_blacklist   (interval)
├── system_blacklist (interval)
└── feeds            (interval, auto-merge)
```
**Decision:** Keep exact same 5 sets

### 3. Rule Order - SAME ✅
```
INPUT CHAIN (12 rules):
1. ct state established,related → ACCEPT
2. iif lo → ACCEPT
3. ip saddr @whitelist → ACCEPT ⭐
4. icmp type { echo-request, echo-reply } → ACCEPT
5. tcp dport <ssh_port> → ACCEPT ⭐ SSH SAFETY
6. [Port rules from config files]
7. ct state invalid → DROP
8. [DDoS rate limiting - TO BE ENHANCED]
9. ip saddr @temp_ban → DROP
10. ip saddr @user_blacklist → DROP
11. ip saddr @system_blacklist → DROP
12. ip saddr @feeds → DROP
[IMPLICIT ACCEPT]
```
**Decision:** Keep this proven order

### 4. File Location - SAME BASE PATH ✅
```
Base: /etc/nftban/
```
**Decision:** All config files remain under /etc/nftban/

### 5. Port Format - KEEP ✅
```
Format: PORT|PROTOCOL
- T = TCP only
- U = UDP only
- B = Both TCP and UDP

Examples:
22|T     # SSH (TCP)
80|T     # HTTP (TCP)
53|U     # DNS (UDP)
3306|B   # MySQL (both)
```
**Decision:** Keep this format (easy and clear)

### 6. Backwards Compatibility - DON'T CARE ✅
**Decision:** No need to maintain v0.9.x compatibility
**Impact:** We can break things, clean slate for v0.10.0

═══════════════════════════════════════════════════════════════════════════════

## ⚠️ TO DISCUSS & DECIDE

### DISCUSSION #1: GO Integration & File Sync Logic 🔄

**Question:** How do files work with Go?

**Current v0.9.x Approach:**
```
Bash reads files → Bash parses → Bash loads to nftables sets
```

**Possible v0.10.0 Approaches:**

**Option A: Bash reads, Go validates**
```
Bash reads files → Go validates IPs → Bash loads to nftables
```
Pros: Simple, minimal change
Cons: Go not fully utilized

**Option B: Go reads and loads**
```
Go reads files → Go parses → Go loads to nftables (via nft command)
```
Pros: Go handles all IP operations, fast
Cons: Go needs nftables permissions

**Option C: Hybrid (recommended?)**
```
Bash manages nftables (create tables/sets/rules)
Go handles IP operations (add/remove IPs to sets)
Files: Both can read
```
Pros: Clear separation of concerns
Cons: Need clear API between Bash and Go

**DECISION NEEDED:**
- [ ] Which approach? (A, B, C, or other?)
- [ ] What does Go do? (validation? loading? both?)
- [ ] What does Bash do? (rules? files? both?)
- [ ] How do they communicate? (files? socket? commands?)

---

### DISCUSSION #2: GeoIP Logic 🌍

**Current v0.9.x:**
```
GeoIP NOT in nftables
Check happens BEFORE ban operation:
1. Detect attack
2. Check GeoIP of attacker IP
3. If country blocked → ban
4. Add to nftables set
```

**v0.10.0 Options:**

**Option A: Keep same (pre-check)**
```
Go GeoIP binary checks IP → Returns country → Bash decides → Add to nftables
```
Pros: Flexible, easy to change rules
Cons: Not in firewall (small delay)

**Option B: Add GeoIP set to nftables**
```
nftables new set: geoip_blocked (type ipv4_addr)
Bash/Go pre-populates set with IPs from blocked countries
nftables rule: ip saddr @geoip_blocked → DROP
```
Pros: Firewall-level blocking (fast)
Cons: Need to maintain IP lists for countries (large!)

**Option C: Hybrid (recommended?)**
```
GeoIP check for NEW bans (pre-check)
But existing known-bad countries → Add to system_blacklist
Result: Some GeoIP IPs in nftables, but no separate set
```
Pros: Balance of flexibility and performance
Cons: Two code paths

**DECISION NEEDED:**
- [ ] Which option? (A, B, C, or other?)
- [ ] How does Go GeoIP integrate?
- [ ] Do we need a new nftables set?
- [ ] Or add to existing sets (system_blacklist)?

---

### DISCUSSION #3: Threat Feeds Logic 📡

**Current v0.9.x:**
```
External threat feeds → Download to files → Parse → Load to @feeds set
Files: /etc/nftban/config/feeds/*-blacklist.conf
```

**v0.10.0 Options:**

**Option A: Keep file-based**
```
Download script → Save to files → Bash reads → Load to @feeds
```
Pros: Simple, proven
Cons: File I/O overhead

**Option B: Go handles feeds**
```
Go downloads feeds → Go parses → Go loads to @feeds set
```
Pros: Fast, efficient
Cons: Go needs HTTP client, parsing logic

**Option C: Database approach**
```
Download feeds → Store in database (SQLite?) → Go queries → Load to @feeds
```
Pros: Queryable, versioned, efficient
Cons: Complexity, database overhead

**DECISION NEEDED:**
- [ ] Which option? (A, B, C, or other?)
- [ ] Who downloads feeds? (Bash cron? Go service?)
- [ ] Who loads to nftables? (Bash? Go? Both?)
- [ ] File format? (Keep .conf? Change to JSON?)

---

### DISCUSSION #4: Rate Limiting Strategy 🛡️

**Current v0.9.x (basic):**
```
RULE 8a: ct state new limit rate over 100/minute → DROP
RULE 8b: icmp rate over 10/second → DROP
RULE 8c: tcp syn rate over 50/second → DROP
```

**User says:** "Rate Limiting NOW YES"

**What rate limits to ADD?**

**Proposed Additional Rules:**

**SSH Brute Force Protection:**
```
RULE 8d: tcp dport 22, ct state new, limit rate over 5/minute per source → DROP
```
Purpose: Limit SSH connection attempts per IP (prevents brute force)

**HTTP/HTTPS Flood Protection:**
```
RULE 8e: tcp dport { 80, 443 }, ct state new, limit rate over 50/minute per source → DROP
```
Purpose: Limit HTTP connections per IP (prevents HTTP flood)

**DNS Flood Protection:**
```
RULE 8f: udp dport 53, limit rate over 20/second per source → DROP
```
Purpose: Limit DNS queries per IP (prevents DNS amplification)

**General Packet Flood:**
```
RULE 8g: limit rate over 1000/second per source → DROP
```
Purpose: Catch-all rate limit (any protocol)

**DECISION NEEDED:**
- [ ] Which rate limits to add? (all above? some? others?)
- [ ] What are the thresholds? (5/min SSH? 50/min HTTP? adjust?)
- [ ] Per-source or global? (per IP? or total?)
- [ ] Burst allowance? (how many packets before limit kicks in?)

**Recommended Rate Limits (Conservative):**
```
SSH:     5 new connections/minute per IP (burst 3)
HTTP:    50 new connections/minute per IP (burst 10)
DNS:     20 queries/second per IP (burst 5)
ICMP:    10 packets/second per IP (burst 5)
SYN:     30 packets/second per IP (burst 10)
Overall: 500 packets/second per IP (burst 50)
```

---

### DISCUSSION #5: Logging Strategy 📝

**Current v0.9.x:**
```
No nftables logging (only counters)
Logging done in Bash (nftban logs to files)
```

**User says:** "Logging DISCUSS - lots of work to do"

**nftables Logging Options:**

**Option A: No nftables logging (keep counters only)**
```
Pros: Clean, fast, minimal overhead
Cons: No packet-level visibility in firewall
```

**Option B: Log drops only (blacklists)**
```
nft add rule ip nftban_v4 input ip saddr @temp_ban log prefix "NFTBAN_TEMP_DROP: " drop
nft add rule ip nftban_v4 input ip saddr @user_blacklist log prefix "NFTBAN_USER_DROP: " drop
...
```
Pros: See what's being blocked
Cons: Can be noisy (many logs)

**Option C: Log rate limit violations**
```
When rate limit triggered → LOG before DROP
```
Pros: Identify attacks
Cons: Logs during attacks (many logs)

**Option D: Selective logging (with limit)**
```
Only log first 5 drops per minute per rule (prevent log flood)
nft add rule ip nftban_v4 input ip saddr @temp_ban limit rate 5/minute log prefix "NFTBAN_DROP: " drop
```
Pros: See blocks, but limited (no log flood)
Cons: May miss some events

**Where do logs go?**
- **Option A:** Kernel log (dmesg, journalctl)
- **Option B:** Separate log file (/var/log/nftban/firewall.log)
- **Option C:** Structured logging (JSON to file)
- **Option D:** Syslog (traditional)

**What to log?**
- [ ] Drop from temp_ban? (YES/NO)
- [ ] Drop from user_blacklist? (YES/NO)
- [ ] Drop from system_blacklist? (YES/NO)
- [ ] Drop from feeds? (YES/NO)
- [ ] Rate limit violations? (YES/NO)
- [ ] CT invalid drops? (YES/NO)
- [ ] Accepts? (NO - too noisy)

**Log format:**
```
Option A: Simple prefix
"NFTBAN_DROP: SRC=1.2.3.4 DST=10.0.0.1 PROTO=TCP DPT=22"

Option B: Structured
"NFTBAN: action=drop set=temp_ban src=1.2.3.4 dst=10.0.0.1 proto=tcp dport=22"

Option C: JSON (if using structured logging)
{"action":"drop","set":"temp_ban","src":"1.2.3.4","dst":"10.0.0.1","proto":"tcp","dport":22}
```

**DECISION NEEDED:**
- [ ] Log in nftables? (YES/NO, if YES: which rules?)
- [ ] Where do logs go? (kernel log? file? syslog?)
- [ ] Log format? (simple? structured? JSON?)
- [ ] Log rate limit? (prevent log flood?)
- [ ] What to log? (drops? rate limits? both? neither?)

**Recommendation:**
```
Logging Strategy (Balanced):
1. Log drops from blacklists (temp_ban, user_blacklist, system_blacklist)
2. Don't log feeds (too noisy)
3. Log rate limit violations (identify attacks)
4. Use rate limit on logging (5/minute per rule)
5. Use structured format (easy to parse)
6. Log to kernel log (journalctl -k, viewable with journalctl)
7. Bash reads kernel log and processes for reports

Example:
nft add rule ip nftban_v4 input ip saddr @temp_ban \
    limit rate 5/minute \
    log prefix "NFTBAN: action=drop set=temp_ban " \
    drop
```

═══════════════════════════════════════════════════════════════════════════════

## 📋 REFINED WORK LIST (In Order)

### PHASE 1: Core nftables Architecture (CONFIRMED)
- [x] Table structure defined (nftban_v4, nftban_v6)
- [x] Set structure defined (5 sets per table)
- [x] Rule order defined (12 rules)
- [x] Port format defined (PORT|PROTOCOL)
- [ ] **NEXT:** Implement nftables module in Bash

### PHASE 2: Rate Limiting (NEEDS DECISIONS)
**Questions to answer:**
1. Which rate limits to add? (SSH, HTTP, DNS, SYN, ICMP, Overall)
2. What are the thresholds? (numbers per second/minute)
3. Per-source or global limits?
4. Burst allowance?

**Action:** Decide on rate limit rules → Add to RULE 8 section

### PHASE 3: Logging (NEEDS DECISIONS)
**Questions to answer:**
1. Log in nftables? (YES/NO)
2. What to log? (drops? rate limits? both?)
3. Where? (kernel log? file? syslog?)
4. Format? (simple? structured? JSON?)
5. Rate limit on logs? (prevent flood?)

**Action:** Decide on logging strategy → Implement in nftables rules

### PHASE 4: Go Integration (NEEDS DECISIONS)
**Questions to answer:**
1. What does Go do? (validate IPs? load sets? GeoIP? all?)
2. What does Bash do? (manage rules? read files? both?)
3. How do they communicate? (files? API? commands?)

**Action:** Design Go-Bash interface → Implement integration

### PHASE 5: GeoIP Logic (NEEDS DECISIONS)
**Questions to answer:**
1. Pre-check or nftables set?
2. If set: new set or use existing system_blacklist?
3. Who populates? (Go? Bash? both?)

**Action:** Decide approach → Implement GeoIP integration

### PHASE 6: Feed Logic (NEEDS DECISIONS)
**Questions to answer:**
1. Keep file-based or change?
2. Who downloads? (Bash cron? Go?)
3. Who loads to nftables? (Bash? Go?)
4. File format? (.conf? JSON?)

**Action:** Decide feed handling → Implement feed system

═══════════════════════════════════════════════════════════════════════════════

## 🎯 IMMEDIATE NEXT STEPS

**I need your decisions on:**

1. **Rate Limiting:**
   - Add SSH protection? (YES/NO, threshold?)
   - Add HTTP protection? (YES/NO, threshold?)
   - Add DNS protection? (YES/NO, threshold?)
   - Other rate limits? (specify)

2. **Logging:**
   - Log drops? (YES/NO)
   - Log rate limits? (YES/NO)
   - Where? (kernel log / file / syslog)
   - Format? (simple / structured / JSON)

3. **Go Integration:**
   - What does Go handle? (validation / loading / GeoIP / all)
   - What does Bash handle? (rules / files / both)
   - How do they talk? (files / API / commands)

4. **GeoIP:**
   - Pre-check or nftables set? (or hybrid)
   - New set or existing set?

5. **Feeds:**
   - Keep file-based? (YES/NO)
   - Go handles? (YES/NO)
   - Format change? (YES/NO, what format?)

═══════════════════════════════════════════════════════════════════════════════

## ✅ SUMMARY

**CONFIRMED (Ready to implement):**
- ✅ Tables: nftban_v4, nftban_v6
- ✅ Sets: 5 sets (whitelist, temp_ban, user_blacklist, system_blacklist, feeds)
- ✅ Rule order: 12 rules (proven, secure)
- ✅ File path: /etc/nftban/
- ✅ Port format: PORT|PROTOCOL (T/U/B)

**PENDING DECISIONS (Need your input):**
- ⏳ Rate limiting details
- ⏳ Logging strategy
- ⏳ Go-Bash integration approach
- ⏳ GeoIP implementation
- ⏳ Feed handling approach

**Once you provide decisions above, I can:**
1. Write complete nftables module
2. Implement rate limiting
3. Implement logging
4. Design Go integration
5. Test on lab servers

═══════════════════════════════════════════════════════════════════════════════

**Ready for your decisions on the 5 discussion topics!** 🎯
