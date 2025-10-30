# NFTBan v0.10.0 - Complete Migration Strategy
**Date:** 2025-10-27
**Status:** 📊 COMPLETE ANALYSIS

═══════════════════════════════════════════════════════════════════════════════

## 🎯 DEPLOYMENT STATUS

### ✅ **COMPLETED & DEPLOYED TO LAB**

**Lab Servers:** lab.example.test, lab1.example.test, lab2.example.test

**Core Modules (Deployed):**
1. ✅ `nftban_nftables.sh` - Atomic reload (6.1K)
2. ✅ `nftban_security.sh` - Whitelist hardening (3.2K)
3. ✅ `nftban_file_ops.sh` - Atomic file writes (4.0K)
4. ✅ `nftban_system_ip.sh` - Auto-detect system IPs (16K)
5. ✅ `cmd_whitelist_system.sh` - System IP CLI (2.3K)

**Deployment Files (Deployed):**
6. ✅ Systemd units (8 files) - nftban.service, timers, etc.
7. ✅ System configs - tmpfiles, sysusers, logrotate, auditd
8. ✅ Template files - whitelist.conf, blacklist.conf

**Total Deployed:** 31.6K of production-ready code

═══════════════════════════════════════════════════════════════════════════════

## 📦 MODULES REQUIRING MIGRATION

### **1. Fail2ban Integration Module** ⭐⭐⭐ **HIGHEST PRIORITY**

**File:** `nftban_fail2ban_module.sh`
**Size:** 692 lines
**Effort:** 🟢 **LOW** (2-4 hours)
**Priority:** ⭐⭐⭐ **CRITICAL** (Original requirement!)

**Purpose:**
- Integrate NFTBan with Fail2ban
- Create Fail2ban actions for NFTBan
- Manage jails (SSHD, HTTP, etc.)
- Convert Fail2ban bans → NFTBan blacklist

**Key Features:**
- Creates Fail2ban action: `/etc/fail2ban/action.d/nftban.conf`
- Creates SSHD jail: `/etc/fail2ban/jail.d/nftban-sshd.conf`
- Command: `fail2ban-client set <jail> banip 1.2.3.4` → NFTBan blacklist
- Auto-sync banned IPs to nftables

**Migration Complexity:** LOW
- ✅ Simple integration (just file creation + API calls)
- ✅ Well-defined interface (Fail2ban action format is standard)
- ✅ No complex state management
- ✅ Easy to test (ban test IP, verify in nftables)

**What Needs Adaptation:**
1. Fail2ban action file (`nftban.conf`) - call our CLI
2. Integration with atomic file writes
3. Sync to nftables via atomic reload
4. CLI commands: `nftban fail2ban setup`, `nftban fail2ban status`

**Estimated Time:** 2-4 hours

---

### **2. Port Management Module** ⭐⭐ **HIGH PRIORITY**

**File:** `nftban_port_module.sh`
**Size:** 554 lines
**Effort:** 🟢 **LOW-MEDIUM** (3-5 hours)
**Priority:** ⭐⭐ **HIGH** (Users need to define allowed ports)

**Purpose:**
- Manage allowed ports (TCP/UDP/Both)
- Format: `PORT|PROTOCOL` (e.g., `22|T` for SSH TCP)
- Dynamic port configuration
- Port validation and rule generation

**Key Features:**
- Port validation (single + ranges: `80`, `8000-9000`)
- Protocol normalization (T/U/B = TCP/UDP/Both)
- IPv4 + IPv6 support
- Input + Output port rules

**Config Files:**
```
/etc/nftban/ports.d/
├── 10-ssh.conf           # 22|T
├── 20-web.conf          # 80|T, 443|T
└── 50-custom.conf       # User ports
```

**Migration Complexity:** LOW-MEDIUM
- ✅ Simple concept (just port lists)
- ✅ Well-defined format
- ⚠️ Need to generate nftables rules during atomic reload

**Estimated Time:** 3-5 hours

---

### **3. DDoS Protection Module** ⭐ **MEDIUM PRIORITY**

**File:** `nftban_ddos_module.sh`
**Size:** 985 lines
**Effort:** 🟡 **HIGH** (2-3 days)
**Priority:** ⭐ **MEDIUM** (Nice-to-have, not critical)

**Purpose:**
- SYN flood protection (rate limiting)
- Connection limits per IP
- Port scan detection
- ICMP flood protection

**Key Features:**
- **SYN Flood:** Rate limit SYN packets (100/second, burst 150)
- **Conn Limits:** Max connections per IP (100)
- **Port Flood:** Detect rapid port scanning
- **ICMP:** Limit ping floods

**Config:**
```bash
DDOS_PROTECTION_ENABLED=1
SYNFLOOD_RATE="100/second"
SYNFLOOD_BURST="150"
CONNLIMIT_MAX="100"
```

**Migration Complexity:** HIGH
- ⚠️ Advanced nftables features (rate limiting, ct limits)
- ⚠️ Complex configuration with overrides
- ⚠️ Requires extensive testing (can't easily test DDoS!)
- ⚠️ Performance impact on high-traffic servers

**Recommendation:** **Defer to v0.11.0** (after v0.10.0 stabilizes)

**Estimated Time:** 2-3 days (with testing)

---

### **4. Other Modules** (Future)

**GeoIP Blocking:** Already have `nftban_geoip_go.sh`, needs integration
**Threat Feeds:** Cloudflare, AbuseIPDB, etc. - Complex
**Login Monitor:** SSH/auth log monitoring - Nice-to-have
**Rate Limiting:** Similar to DDoS, defer to later

═══════════════════════════════════════════════════════════════════════════════

## ⚖️ EFFORT ESTIMATION SUMMARY

| Module | Lines | Effort | Time | Priority | When |
|--------|-------|--------|------|----------|------|
| Fail2ban | 692 | 🟢 LOW | 2-4h | ⭐⭐⭐ CRITICAL | **NOW** |
| Port Mgmt | 554 | 🟢 LOW-MED | 3-5h | ⭐⭐ HIGH | **THIS WEEK** |
| DDoS | 985 | 🟡 HIGH | 2-3d | ⭐ MEDIUM | **v0.11.0** |
| GeoIP | ? | 🟡 MEDIUM | 1-2d | ⭐ MEDIUM | **v0.11.0** |
| Feeds | ? | 🟡 HIGH | 3-5d | ⭐ MEDIUM | **v0.11.0** |

**Recommended Order:**
1. **Fail2ban** (2-4h) - Do ASAP!
2. **Port Management** (3-5h) - This week
3. **Test & Stabilize v0.10.0**
4. **DDoS + others** (v0.11.0) - After stabilization

═══════════════════════════════════════════════════════════════════════════════

## 📝 COMPLETE CHATGPT QUESTIONS DOCUMENT

Save this to a file and send to ChatGPT for implementation guidance.

═══════════════════════════════════════════════════════════════════════════════

```markdown
# NFTBan v0.10.0 - Module Migration Help Request

## CONTEXT

I'm migrating NFTBan from v0.9.x (Bash-only, monolithic) to v0.10.0 (Go+Bash hybrid, modular).

**NEW ARCHITECTURE:**
- **Atomic Reload:** Build new nftables table, swap atomically (no downtime)
- **Atomic File Writes:** tmpfile + mv pattern (no race conditions)
- **Split Tables:** nftban_v4 (IPv4), nftban_v6 (IPv6)
- **FHS Compliant:** `/etc/nftban/`, `/var/lib/nftban/`, `/var/log/nftban/`
- **Security Hardened:** Whitelist always wins, auto-remove from blacklists
- **Go Integration:** IP validation, GeoIP, deduplication

**ALREADY IMPLEMENTED:**
✅ Atomic reload with table swap
✅ Whitelist security hardening
✅ Atomic file operations
✅ System IP auto-detection
✅ Systemd units with security hardening

═══════════════════════════════════════════════════════════════════════════════

## 1. FAIL2BAN INTEGRATION (HIGHEST PRIORITY)

### MODULE INFO:
**File:** `nftban_fail2ban_module.sh` (692 lines)
**Purpose:** Integrate Fail2ban bans with NFTBan blacklist

### CURRENT IMPLEMENTATION:
- Creates Fail2ban action: `/etc/fail2ban/action.d/nftban.conf`
- Creates SSHD jail: `/etc/fail2ban/jail.d/nftban-sshd.conf`
- On ban: `fail2ban-client set sshd banip 1.2.3.4` → calls NFTBan
- NFTBan adds IP to temp_ban set (temporary ban with nftables timer)

### CRITICAL REQUIREMENTS (User Clarifications):
1. **Temporary Bans Only:** Fail2ban ALWAYS bans temporarily (not permanent)
2. **No Unban Action:** nftables timer handles unban automatically (no actionunban needed)
3. **Go Validation:** Go binary validates IPs before adding
4. **Persistent Offenders:** Repeated offenders → blacklist files → permanent ban
5. **CLI Management:** Enable/disable Fail2ban + nftables separately AND together
6. **Master Switch:** `nftban disable` → stops both Fail2ban AND nftables

### FAIL2BAN ACTION FORMAT:
```ini
[Definition]
actionstart = <command on jail start>
actionstop = <command on jail stop>
actioncheck = <command to check if ban exists>
actionban = <command to ban IP>
actionunban = <command to unban IP>
```

### QUESTIONS:

**Q1: Fail2ban Action Implementation (Temporary Bans Only)**
The NFTBan action should ONLY ban temporarily (no unban action needed).

NEW action (temporary bans with nftables timer):
```bash
actionban = /usr/sbin/nftban ban <ip> --temp --timeout 3600 --source fail2ban
# NO actionunban - nftables timer handles automatic unban!
```

How should we implement temporary bans with nftables timeout?

Option A: temp_ban set with timeout
```bash
# Add to temp_ban set with 1-hour timeout
nft add element ip nftban_v4 temp_ban { 1.2.3.4 timeout 3600s }
```

Option B: Dynamic timeout per jail
```bash
# SSH: 1 hour, HTTP: 24 hours, etc.
nft add element ip nftban_v4 temp_ban { 1.2.3.4 timeout ${BANTIME}s }
```

Which is better? Should timeout be configurable per jail?

**Q2: Temporary Ban Workflow (Go Validation + Persistent Offender Detection)**
When Fail2ban bans an IP, the workflow should be:

```
fail2ban → nftban ban <ip> --temp --source fail2ban
           ↓
         Go binary validates IP (valid format, not in whitelist)
           ↓
         Add to temp_ban set with timeout (live, no reload!)
           ↓
         Track ban count in /var/lib/nftban/ban_counts/<ip>
           ↓
         If ban count >= THRESHOLD (e.g., 3 bans in 24h):
           → Add to blacklist.d/persistent-offenders.conf
           → Permanent ban on next atomic reload
```

Questions:
1. How to track ban counts efficiently? (File per IP vs SQLite vs Redis?)
2. What's a good threshold? (3 bans in 24h? 5 bans in 7 days?)
3. Should we use `nft add element` (live) or queue for batch processing?
4. How to handle high-volume attacks (100+ IPs/min)?

**Q3: Live Temporary Bans (No Reload Required)**
Temporary bans should be LIVE (no atomic reload):

```bash
# Direct nftables add (instant, no reload!)
nft add element ip nftban_v4 temp_ban { 1.2.3.4 timeout 3600s }
nft add element ip6 nftban_v6 temp_ban { 2001:db8::1 timeout 3600s }
```

Questions:
1. Should temp_ban set exist in both atomic reload AND live adds?
2. How to ensure consistency? (temp_ban set created during atomic reload, entries added live)
3. What if atomic reload happens while temp bans exist? (nft replace clears temp_ban?)
4. Best practice: preserve temp_ban during atomic reload?

**Q4: Jail Configuration**
What's the recommended jail configuration for NFTBan integration?

Should we:
- Create separate jail configs for each service (SSH, HTTP, etc.)?
- Use single jail with action=nftban?
- Configure findtime, bantime, maxretry defaults?

**Q5: Automatic Unban (nftables Timer - NO ACTION NEEDED)**
**IMPORTANT:** No unban action required! nftables handles it automatically:

```bash
# Ban with timeout (automatic expiry)
nft add element ip nftban_v4 temp_ban { 1.2.3.4 timeout 3600s }

# After 3600 seconds (1 hour), nftables AUTOMATICALLY removes the entry!
# No unban script, no cron, no monitoring needed!
```

This means:
- ✅ NO actionunban in Fail2ban action file
- ✅ NO unban tracking needed
- ✅ NO cleanup scripts
- ✅ Fail2ban just bans, nftables unbans automatically

**Q6: CLI Enable/Disable Management (Master Switch + Individual)**
The CLI should manage Fail2ban and nftables separately AND together:

```bash
# Master switch (controls BOTH)
nftban enable               # Enable nftables + Fail2ban
nftban disable              # Disable BOTH (stop systemd units)

# Individual control
nftban nftables enable      # Enable nftables only
nftban nftables disable     # Disable nftables only
nftban fail2ban enable      # Enable Fail2ban only
nftban fail2ban disable     # Disable Fail2ban only

# Status
nftban status               # Show status of both
nftban nftables status      # nftables status only
nftban fail2ban status      # Fail2ban status only
```

Questions:
1. How to implement the master switch logic?
   - `nftban disable` → stop both systemd units + disable services?
2. Where to store enabled/disabled state?
   - `/etc/nftban/nftban.conf` with `NFTBAN_ENABLED=true/false`?
   - `/var/lib/nftban/state/enabled`?
3. Should `nftban enable` check dependencies?
   - If nftables disabled, warn user before enabling Fail2ban?
4. Integration with systemd:
   - `systemctl enable/disable nftban.service`?
   - `systemctl enable/disable fail2ban.service`?

**Q7: Jail/Action File Management + Permissions**
Need commands to manage Fail2ban jails and actions:

```bash
# Setup (creates /etc/fail2ban/jail.d/ and /etc/fail2ban/action.d/ files)
nftban fail2ban setup       # Create nftban.conf action + default jails

# Enable/disable specific jails
nftban fail2ban jail enable sshd
nftban fail2ban jail disable sshd
nftban fail2ban jail delete sshd

# Start/stop Fail2ban service
nftban fail2ban start
nftban fail2ban stop
nftban fail2ban restart

# List jails
nftban fail2ban jail list
```

Questions:
1. What permissions for jail/action files?
   - `/etc/fail2ban/jail.d/*.conf` → 0644 root:root?
   - `/etc/fail2ban/action.d/nftban.conf` → 0644 root:root?
2. How to handle existing jails?
   - Backup before setup?
   - Merge with existing configs?
3. Template files location?
   - `/usr/share/nftban/templates/fail2ban/`?
4. Should setup be idempotent?
   - Safe to run multiple times?

**Q8: Comprehensive Logging + Statistics (CRITICAL)**
We need detailed logs under `/var/log/nftban/` for tracking, statistics, and troubleshooting:

```
/var/log/nftban/
├── fail2ban-bans.log           # All Fail2ban ban events
├── persistent-offenders.log    # IPs moved to permanent blacklist
├── nftban-actions.log          # All NFTBan actions (ban/unban/whitelist)
├── validation-errors.log       # Go validation failures
└── statistics.log              # Daily summaries
```

**Log Format Examples:**

`fail2ban-bans.log`:
```
2025-10-27 14:32:15 [BAN] IP=1.2.3.4 JAIL=sshd ACTION=temp_ban TIMEOUT=3600s REASON="5 failed SSH attempts" COUNT=1
2025-10-27 15:45:22 [BAN] IP=1.2.3.4 JAIL=sshd ACTION=temp_ban TIMEOUT=3600s REASON="5 failed SSH attempts" COUNT=2
2025-10-27 16:12:08 [PERSISTENT] IP=1.2.3.4 JAIL=sshd ACTION=blacklist REASON="3 bans in 24h" TOTAL_BANS=3
```

`persistent-offenders.log`:
```
2025-10-27 16:12:08 [BLACKLIST] IP=1.2.3.4 SOURCE=fail2ban TRIGGER=3_bans_in_24h JAILS=sshd,sshd,sshd
```

`nftban-actions.log`:
```
2025-10-27 14:32:15 [ACTION] CMD="ban" IP=1.2.3.4 TYPE=temp TIMEOUT=3600 SOURCE=fail2ban RESULT=success
2025-10-27 16:12:08 [ACTION] CMD="ban" IP=1.2.3.4 TYPE=permanent SOURCE=persistent-offender RESULT=success
```

Questions:
1. Log rotation settings? (size, retention, compression)
2. Log format: JSON vs plain text vs structured?
3. Real-time statistics dashboard? (`nftban stats show`)
4. Integration with logrotate (already have /etc/logrotate.d/nftban)

**Q9: Statistics and Reporting**
Need commands to view statistics and troubleshoot:

```bash
# View recent bans
nftban fail2ban logs --tail 50

# Statistics
nftban stats                    # Overall statistics
nftban stats today              # Today's bans
nftban stats week               # Weekly summary

# Top offenders
nftban stats top-ips            # Top 10 banned IPs
nftban stats top-jails          # Most triggered jails

# Troubleshooting
nftban logs errors              # Show validation errors
nftban logs ip 1.2.3.4          # All logs for specific IP
```

Questions:
1. Should stats be generated on-demand or cached?
2. Database for statistics? (SQLite vs log parsing)
3. Export format? (CSV, JSON for external tools)

### PLEASE PROVIDE:

1. Complete `/etc/fail2ban/action.d/nftban.conf` file (actionban only, NO actionunban)
2. Example `/etc/fail2ban/jail.d/nftban-sshd.conf` file
3. Bash function: `nftban_fail2ban_ban()` - Add to temp_ban with timeout + logging
4. Bash function: `nftban_fail2ban_track_offender()` - Track ban counts + log
5. Bash function: `nftban_fail2ban_check_persistent()` - Check if IP should be blacklisted
6. Bash function: `nftban_log_action()` - Centralized logging function
7. Bash function: `nftban_stats_generate()` - Generate statistics from logs
8. CLI commands for enable/disable/start/stop/status (master switch + individual)
9. CLI commands for logs and statistics viewing
10. File permissions for jails and actions (correct ownership and modes)
11. Log rotation configuration (size, retention, compression)
12. Best practice workflow for temporary bans → persistent offender detection → logging
13. Testing methodology (test ban, verify timeout, test persistent offender, check logs)

═══════════════════════════════════════════════════════════════════════════════

## 2. PORT MANAGEMENT MODULE

### MODULE INFO:
**File:** `nftban_port_module.sh` (554 lines)
**Purpose:** Manage allowed ports dynamically

### CURRENT IMPLEMENTATION:
Format: `PORT|PROTOCOL`
- `22|T` = Port 22 TCP (SSH)
- `80|T` = Port 80 TCP (HTTP)
- `53|B` = Port 53 Both (DNS on TCP+UDP)
- `8000-9000|T` = Port range TCP

Config files:
```
/etc/nftban/ports.d/
├── 10-ssh.conf       # 22|T
├── 20-web.conf       # 80|T, 443|T
└── 50-custom.conf    # User ports
```

### QUESTIONS:

**Q1: Port Rules in Atomic Reload**
Where should port rules go in the nftables rule order?

Current rule order:
```
1. ct state established,related accept
2. iif lo accept
3. ip saddr @whitelist accept
4. icmp type { echo-request, echo-reply } accept
5. tcp dport $SSH_PORT accept  ← WHERE DO DYNAMIC PORTS GO?
6. [Port rules from config?]
7. ct state invalid drop
8. ip saddr @temp_ban drop
9-11. Blacklist drops
```

Should port rules be:
- A) Single rule with set: `tcp dport @allowed_ports accept`?
- B) Multiple individual rules (one per port)?
- C) Ranges: `tcp dport 8000-9000 accept`?

**Q2: Port Set vs Individual Rules**
What's better for performance with 20-50 ports?

Option A: nftables set
```bash
add set ip nftban_v4 tcp_ports { type inet_service; }
add element ip nftban_v4 tcp_ports { 22, 80, 443, 8000-9000 }
tcp dport @tcp_ports accept
```

Option B: Individual rules
```bash
tcp dport 22 accept
tcp dport 80 accept
tcp dport 443 accept
tcp dport 8000-9000 accept
```

**Q3: Protocol Handling**
How to handle "Both" (TCP+UDP) elegantly?

Port: `53|B` (DNS on both protocols)

Option A: Meta
```bash
meta l4proto { tcp, udp } th dport 53 accept
```

Option B: Separate rules
```bash
tcp dport 53 accept
udp dport 53 accept
```

**Q4: Integration with Atomic Reload**
Where in `_build_new_tables_batch()` should we generate port rules?

```bash
_build_new_tables_batch() {
  # ... create tables, sets ...

  # Add base rules (ct, lo, whitelist, icmp)

  # ADD PORT RULES HERE?

  # Add blacklist rules
}
```

Should we:
- Parse all /etc/nftban/ports.d/*.conf files?
- Build nftables syntax dynamically?
- Cache parsed port rules?

### PLEASE PROVIDE:

1. Recommended nftables port rule syntax
2. Bash function: `nftban_port_generate_rules()`
3. Integration approach with atomic reload
4. Performance comparison (sets vs individual rules)
5. Example config files

═══════════════════════════════════════════════════════════════════════════════

## 3. DDOS PROTECTION MODULE (OPTIONAL - v0.11.0)

### MODULE INFO:
**File:** `nftban_ddos_module.sh` (985 lines)
**Purpose:** Protect against DDoS attacks

### PROTECTION TYPES:

**A. SYN Flood Protection**
- Rate limit SYN packets: 100/second, burst 150
- nftables: `ct state new tcp flags syn limit rate 100/second burst 150 packets`

**B. Connection Limits**
- Max connections per IP: 100
- nftables: `ct count over 100 drop`

**C. Port Flood Protection**
- Detect rapid port scanning
- nftables: `tcp flags syn / syn,ack limit rate 50/second`

**D. ICMP Flood Protection**
- Limit ping rate: 10/second
- nftables: `icmp type echo-request limit rate 10/second`

### QUESTIONS:

**Q1: Architecture Decision**
Should DDoS protection be:
- A) Integrated in main table (nftban_v4)?
- B) Separate table (ddos_v4)?
- C) Optional add-on chains?
- D) Prerouting hook (before routing)?

**Q2: Rule Placement**
Where in rule order for minimal performance impact?

```
1. ct state established,related accept  ← BEFORE OR AFTER DDoS checks?
2. DDoS checks (SYN flood, conn limits)?
3. Whitelist accept
4. Port rules
5. Blacklist drops
```

**Q3: Rate Limiting Syntax**
What's the correct nftables syntax for each protection?

Provide complete rules for:
- SYN flood protection (IPv4 + IPv6)
- Connection limits (ct count)
- Port scan detection
- ICMP rate limiting

**Q4: Testing Methodology**
How to test without actually DDoSing ourselves?

- Safe SYN flood simulation?
- Connection limit testing?
- How to verify rate limits work?

**Q5: Performance Impact**
What's the overhead of ct limits on high-traffic servers?

- 10K req/sec?
- 100K req/sec?
- Optimization tips?

### PLEASE PROVIDE:

1. Recommended architecture (separate table vs integrated)
2. Complete nftables rules for each protection type
3. Configuration file format
4. Safe testing methodology
5. Performance impact assessment
6. Bash function: `nftban_ddos_enable()`
7. Bash function: `nftban_ddos_configure()`

═══════════════════════════════════════════════════════════════════════════════

## GENERAL QUESTIONS

**Q1: Module Loading Order**
What order should modules be sourced?

```bash
source nftban_file_ops.sh
source nftban_nftables.sh
source nftban_security.sh
source nftban_system_ip.sh
source nftban_port.sh       # NEW
source nftban_fail2ban.sh   # NEW
source nftban_ddos.sh       # NEW
```

**Q2: CLI Integration**
How to structure CLI for new modules?

```bash
nftban fail2ban setup
nftban fail2ban status
nftban fail2ban test

nftban port add 8080|T
nftban port remove 8080|T
nftban port list

nftban ddos enable
nftban ddos disable
nftban ddos status
```

**Q3: FHS Compliance Review**
Are our paths correct?

```
/etc/nftban/           # Configs
/var/lib/nftban/       # State data
/var/log/nftban/       # Logs
/var/backups/nftban/   # Backups
/run/nftban/           # Runtime (PIDs, sockets)
/usr/lib/nftban/       # Modules
```

═══════════════════════════════════════════════════════════════════════════════

## EXPECTED DELIVERABLES

For each module, please provide:

1. ✅ **Code:** Complete Bash functions (production-ready)
2. ✅ **Config:** Example configuration files
3. ✅ **nftables:** Complete rule syntax
4. ✅ **Integration:** How to integrate with atomic reload
5. ✅ **Testing:** Step-by-step testing methodology
6. ✅ **Performance:** Impact assessment
7. ✅ **Security:** Security considerations

═══════════════════════════════════════════════════════════════════════════════

## OUR STANDARDS

All code must follow our production standards:
- Strict mode: `set -Eeuo pipefail`
- Safe word splitting: `IFS=$'\n\t'`
- Secure permissions: `umask 027`
- Atomic operations (tmpfile + mv)
- Error handling (trap on failure)
- Logging to `/var/log/nftban/`
- SELinux aware (restorecon)

═══════════════════════════════════════════════════════════════════════════════
```

═══════════════════════════════════════════════════════════════════════════════

## 📋 RECOMMENDED ACTION PLAN

### **Phase 1: THIS WEEK (v0.10.0 Release)**

**Day 1-2:**
1. ✅ Send ChatGPT questions document (above)
2. ⏳ Implement Fail2ban integration (2-4h)
3. ⏳ Test Fail2ban on lab servers

**Day 3-4:**
4. ⏳ Implement Port Management (3-5h)
5. ⏳ Test port rules on lab servers

**Day 5:**
6. ⏳ Integration testing (Fail2ban + Ports + System IPs)
7. ⏳ Documentation updates
8. ✅ **RELEASE v0.10.0**

---

### **Phase 2: NEXT MONTH (v0.11.0)**

**Week 1:**
- DDoS module implementation with ChatGPT help
- Extensive testing (SYN floods, conn limits, etc.)

**Week 2:**
- GeoIP blocking integration
- Threat feeds (Cloudflare, AbuseIPDB)

**Week 3:**
- Testing and stabilization
- Performance optimization

**Week 4:**
- Documentation
- ✅ **RELEASE v0.11.0**

═══════════════════════════════════════════════════════════════════════════════

## ✅ CURRENT STATUS

**✅ COMPLETED:**
- Core security fixes (atomic reload, whitelist, file ops)
- System IP auto-detection
- Deployment to 3 lab servers
- Systemd integration
- Security hardening

**⏳ IN PROGRESS:**
- Documentation (this file!)
- Module migration analysis

**📋 TODO THIS WEEK:**
- Fail2ban integration
- Port management

**📅 TODO LATER (v0.11.0):**
- DDoS protection
- GeoIP blocking
- Threat feeds

═══════════════════════════════════════════════════════════════════════════════

═══════════════════════════════════════════════════════════════════════════════

## 🎯 COMPLETE FAIL2BAN IMPLEMENTATION PLAN

This section combines ALL requirements into a cohesive implementation plan.

═══════════════════════════════════════════════════════════════════════════════

### **OVERVIEW: End-to-End Workflow**

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ 1. FAIL2BAN DETECTS ATTACK                                                  │
│    - 5 failed SSH login attempts from 1.2.3.4                               │
│    - Triggers SSHD jail                                                     │
└─────────────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────────────┐
│ 2. FAIL2BAN CALLS NFTBAN ACTION                                             │
│    - actionban = /usr/sbin/nftban ban <ip> --temp --source fail2ban         │
│    - Passes: IP=1.2.3.4, JAIL=sshd, BANTIME=3600                            │
└─────────────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────────────┐
│ 3. NFTBAN BAN FUNCTION (nftban_fail2ban_ban)                                │
│    ┌──────────────────────────────────────────────────────────────────────┐│
│    │ a) Go binary validates IP (format, not whitelisted)                  ││
│    │    → If invalid: Log error, exit                                     ││
│    │                                                                       ││
│    │ b) Add to temp_ban set (LIVE, no reload)                             ││
│    │    → nft add element ip nftban_v4 temp_ban { 1.2.3.4 timeout 3600s } ││
│    │                                                                       ││
│    │ c) Log ban action                                                     ││
│    │    → /var/log/nftban/fail2ban-bans.log                               ││
│    │    → [BAN] IP=1.2.3.4 JAIL=sshd ACTION=temp_ban TIMEOUT=3600s        ││
│    │                                                                       ││
│    │ d) Track ban count (nftban_fail2ban_track_offender)                  ││
│    │    → /var/lib/nftban/ban_counts/1.2.3.4                              ││
│    │    → Increment count (e.g., COUNT=1)                                 ││
│    │                                                                       ││
│    │ e) Check if persistent offender (nftban_fail2ban_check_persistent)   ││
│    │    → If COUNT >= 3 in 24h:                                           ││
│    │       - Add to /etc/nftban/blacklist.d/persistent-offenders.conf     ││
│    │       - Log to /var/log/nftban/persistent-offenders.log              ││
│    │       - Trigger atomic reload (permanent ban!)                       ││
│    └──────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────────────┐
│ 4. NFTABLES ENFORCES BAN                                                    │
│    - Temporary: IP in temp_ban set with timeout (automatic unban)          │
│    - Permanent: IP in blacklist set (manual unban only)                    │
└─────────────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────────────┐
│ 5. AUTOMATIC UNBAN (nftables timer)                                         │
│    - After 3600 seconds, nftables AUTOMATICALLY removes IP from temp_ban    │
│    - NO unban action needed from Fail2ban                                   │
│    - Persistent offenders remain in blacklist (permanent)                   │
└─────────────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────────────┐
│ 6. STATISTICS & TROUBLESHOOTING                                             │
│    - nftban stats                 → View overall statistics                 │
│    - nftban stats top-ips         → Top 10 banned IPs                       │
│    - nftban logs ip 1.2.3.4       → All logs for specific IP                │
│    - nftban fail2ban logs         → Recent Fail2ban bans                    │
└─────────────────────────────────────────────────────────────────────────────┘
```

═══════════════════════════════════════════════════════════════════════════════

### **FILE STRUCTURE**

```
/etc/nftban/
├── nftban.conf                     # Main config (NFTBAN_ENABLED=true/false)
├── whitelist.d/
│   ├── 00-system-ips.conf          # Auto-detected system IPs
│   └── 99-user-whitelist.conf      # User manual whitelist
├── blacklist.d/
│   ├── 50-user-blacklist.conf      # User manual blacklist
│   └── 90-persistent-offenders.conf # Auto-added persistent offenders
└── ports.d/
    ├── 10-ssh.conf                 # 22|T
    └── 20-web.conf                 # 80|T, 443|T

/var/lib/nftban/
├── ban_counts/                     # Track ban counts per IP
│   ├── 1.2.3.4                     # COUNT=3 FIRST_BAN=... LAST_BAN=...
│   └── 5.6.7.8                     # COUNT=1 FIRST_BAN=...
├── state/
│   └── enabled                     # Master enabled/disabled state
└── compiled/
    └── last_reload.nft             # Last successful reload

/var/log/nftban/
├── fail2ban-bans.log               # All Fail2ban ban events
├── persistent-offenders.log        # IPs moved to permanent blacklist
├── nftban-actions.log              # All NFTBan actions
├── validation-errors.log           # Go validation failures
└── statistics.log                  # Daily summaries

/etc/fail2ban/
├── action.d/
│   └── nftban.conf                 # NFTBan action (actionban only)
└── jail.d/
    ├── nftban-sshd.conf            # SSH jail
    ├── nftban-http.conf            # HTTP jail (optional)
    └── nftban-custom.conf          # User jails
```

═══════════════════════════════════════════════════════════════════════════════

### **MODULES TO CREATE**

**1. Core Module: `nftban_fail2ban.sh`**
```bash
# Functions:
- nftban_fail2ban_ban()              # Ban IP temporarily with timeout
- nftban_fail2ban_track_offender()   # Increment ban count
- nftban_fail2ban_check_persistent() # Check if should be blacklisted
- nftban_fail2ban_setup()            # Create jail/action files
- nftban_fail2ban_enable()           # Enable Fail2ban service
- nftban_fail2ban_disable()          # Disable Fail2ban service
- nftban_fail2ban_start()            # Start Fail2ban
- nftban_fail2ban_stop()             # Stop Fail2ban
- nftban_fail2ban_status()           # Show Fail2ban status
```

**2. Logging Module: `nftban_logging.sh`**
```bash
# Functions:
- nftban_log_action()                # Log to nftban-actions.log
- nftban_log_ban()                   # Log to fail2ban-bans.log
- nftban_log_persistent()            # Log to persistent-offenders.log
- nftban_log_error()                 # Log to validation-errors.log
```

**3. Statistics Module: `nftban_stats.sh`**
```bash
# Functions:
- nftban_stats_generate()            # Generate statistics from logs
- nftban_stats_show()                # Show overall stats
- nftban_stats_today()               # Today's bans
- nftban_stats_week()                # Weekly summary
- nftban_stats_top_ips()             # Top 10 banned IPs
- nftban_stats_top_jails()           # Most triggered jails
```

**4. CLI Commands:**
```bash
# cli/cmd_fail2ban.sh - Fail2ban management
# cli/cmd_stats.sh    - Statistics viewing
# cli/cmd_logs.sh     - Log viewing
# cli/cmd_enable.sh   - Master enable/disable
```

═══════════════════════════════════════════════════════════════════════════════

### **CLI COMMAND STRUCTURE**

```bash
# Master switch (enable/disable BOTH nftables + Fail2ban)
nftban enable                       # Enable everything
nftban disable                      # Disable everything
nftban status                       # Show status of both

# Individual nftables control
nftban nftables enable
nftban nftables disable
nftban nftables status
nftban nftables reload              # Trigger atomic reload

# Individual Fail2ban control
nftban fail2ban enable              # Enable Fail2ban service
nftban fail2ban disable             # Disable Fail2ban service
nftban fail2ban start               # Start Fail2ban
nftban fail2ban stop                # Stop Fail2ban
nftban fail2ban restart             # Restart Fail2ban
nftban fail2ban status              # Show Fail2ban status

# Fail2ban setup
nftban fail2ban setup               # Create action + jails

# Jail management
nftban fail2ban jail list           # List all jails
nftban fail2ban jail enable sshd    # Enable SSHD jail
nftban fail2ban jail disable sshd   # Disable SSHD jail
nftban fail2ban jail delete sshd    # Delete SSHD jail

# Ban operations
nftban ban <ip> --temp              # Temporary ban (default 3600s)
nftban ban <ip> --temp --timeout 7200  # Custom timeout
nftban ban <ip> --permanent         # Permanent ban (add to blacklist)
nftban unban <ip>                   # Remove from blacklist (temp bans auto-expire)

# Logs
nftban logs                         # All logs (tail)
nftban logs --tail 100              # Last 100 lines
nftban logs ip 1.2.3.4              # All logs for specific IP
nftban logs errors                  # Show validation errors
nftban fail2ban logs                # Fail2ban ban logs

# Statistics
nftban stats                        # Overall statistics
nftban stats today                  # Today's bans
nftban stats week                   # Weekly summary
nftban stats top-ips                # Top 10 banned IPs
nftban stats top-jails              # Most triggered jails
```

═══════════════════════════════════════════════════════════════════════════════

### **IMPLEMENTATION CHECKLIST**

**Phase 1: Core Fail2ban Integration (Day 1-2)**
- [ ] Create `nftban_fail2ban.sh` module
- [ ] Create `nftban_logging.sh` module
- [ ] Create `/etc/fail2ban/action.d/nftban.conf` template
- [ ] Create `/etc/fail2ban/jail.d/nftban-sshd.conf` template
- [ ] Implement `nftban_fail2ban_ban()` function
- [ ] Implement Go IP validation integration
- [ ] Implement temporary ban with nftables timeout
- [ ] Test temporary ban (verify auto-unban after timeout)

**Phase 2: Persistent Offender Detection (Day 2-3)**
- [ ] Implement `nftban_fail2ban_track_offender()` function
- [ ] Create `/var/lib/nftban/ban_counts/` tracking
- [ ] Implement `nftban_fail2ban_check_persistent()` function
- [ ] Auto-add to `/etc/nftban/blacklist.d/persistent-offenders.conf`
- [ ] Trigger atomic reload on persistent offender detection
- [ ] Test persistent offender workflow (3 bans → blacklist)

**Phase 3: CLI & Management (Day 3-4)**
- [ ] Create `cli/cmd_enable.sh` (master switch)
- [ ] Create `cli/cmd_fail2ban.sh` (Fail2ban management)
- [ ] Implement enable/disable/start/stop/status commands
- [ ] Implement jail management commands
- [ ] Test master switch (nftban disable → stops both)
- [ ] Test individual switches

**Phase 4: Logging & Statistics (Day 4-5)**
- [ ] Implement comprehensive logging functions
- [ ] Create log files under `/var/log/nftban/`
- [ ] Create `nftban_stats.sh` module
- [ ] Implement `cli/cmd_stats.sh`
- [ ] Implement `cli/cmd_logs.sh`
- [ ] Test log viewing and statistics

**Phase 5: Testing & Documentation (Day 5)**
- [ ] Integration testing on lab servers
- [ ] Test Fail2ban → NFTBan workflow
- [ ] Test persistent offender detection
- [ ] Test master enable/disable
- [ ] Verify logs and statistics
- [ ] Update documentation

═══════════════════════════════════════════════════════════════════════════════

### **TESTING PLAN**

**Test 1: Basic Temporary Ban**
```bash
# Ban IP manually
nftban ban 1.2.3.4 --temp --timeout 60

# Verify in nftables
nft list set ip nftban_v4 temp_ban

# Wait 60 seconds, verify auto-unban
nft list set ip nftban_v4 temp_ban  # Should be empty

# Check logs
tail /var/log/nftban/nftban-actions.log
```

**Test 2: Fail2ban Integration**
```bash
# Enable Fail2ban
nftban fail2ban enable
nftban fail2ban start

# Trigger ban (5 failed SSH attempts)
ssh root@localhost  # fail 5 times

# Verify ban in nftables
nft list set ip nftban_v4 temp_ban

# Check logs
tail /var/log/nftban/fail2ban-bans.log
```

**Test 3: Persistent Offender Detection**
```bash
# Ban same IP 3 times manually (simulate)
nftban ban 1.2.3.4 --temp --source fail2ban
sleep 2
nftban ban 1.2.3.4 --temp --source fail2ban
sleep 2
nftban ban 1.2.3.4 --temp --source fail2ban

# Verify moved to blacklist
cat /etc/nftban/blacklist.d/persistent-offenders.conf

# Check logs
tail /var/log/nftban/persistent-offenders.log

# Verify in nftables (after atomic reload)
nft list set ip nftban_v4 blacklist
```

**Test 4: Master Enable/Disable**
```bash
# Disable everything
nftban disable

# Verify both stopped
systemctl status nftban.service
systemctl status fail2ban.service

# Enable everything
nftban enable

# Verify both running
nftban status
```

**Test 5: Statistics**
```bash
# View statistics
nftban stats
nftban stats today
nftban stats top-ips
nftban stats top-jails

# View logs
nftban logs --tail 50
nftban logs ip 1.2.3.4
```

═══════════════════════════════════════════════════════════════════════════════

**READY TO PROCEED?** Send the ChatGPT questions section to ChatGPT! 🚀
