# NFTBan v0.10.0 - Comprehensive TODO

**Date:** 2025-10-28 (Updated Evening)
**Status:** Documentation 60%, Features 75%, SPDX 100%, Packaging 10%
**Priority:** HIGH - Pre-release checklist

---

## ✅ COMPLETED TODAY (2025-10-28)

### 1. Search Command (`nftban search <ip>`)
**Priority:** CRITICAL
**Description:** Unified search across all ban lists and configurations
**Status:** ✅ COMPLETE - Deployed to all lab servers

**Requirements:**
- Search IP across all sets (whitelist, temp_ban, user_blacklist, system_blacklist, feeds)
- Show which jail banned the IP (if from Fail2Ban)
- Show ban source (manual, fail2ban, feeds, etc.)
- Show expiry time (if temp ban)
- Show which feed contains the IP (if in feeds)
- Support CIDR search (e.g., `nftban search 192.168.1.0/24`)

**Example output:**
```
nftban search 192.0.2.100
═══════════════════════════════════════════════════════════════
IP: 192.0.2.100
═══════════════════════════════════════════════════════════════

Status: BANNED ✗

Found in:
  ✓ temp_ban (runtime table)
    - Source: fail2ban
    - Jail: sshd
    - Banned: 2025-10-28 14:32:05 (15 minutes ago)
    - Expires: 2025-10-28 15:32:05 (45 minutes)
    - Reason: 5 failed SSH attempts

Not found in:
  ✗ whitelist
  ✗ user_blacklist
  ✗ system_blacklist
  ✗ feeds

Action: IP is currently blocked, will auto-expire in 45 minutes
```

**Implementation files:**
- `/usr/lib/nftban/cli/cmd_search.sh` (NEW)
- `/usr/lib/nftban/core/nftban_search.sh` (NEW)
- Add to main CLI: `/usr/sbin/nftban`

---

#### Stats & Metrics System
**Priority:** CRITICAL
**Description:** Comprehensive statistics and metrics for monitoring
**Status:** ❌ NOT IMPLEMENTED (partial code exists)

**Requirements:**
1. **Real-time stats:**
   - Total IPs banned (by source: manual, fail2ban, feeds)
   - Active bans vs expired
   - Top banned IPs
   - Top attacking countries (if GeoIP enabled)
   - Ban events per hour/day/week
   - Firewall rule statistics

2. **Report generation:**
   - HTML report with charts
   - Text report for email
   - JSON export for monitoring tools
   - Include health check results

3. **CLI commands:**
   ```bash
   nftban stats                    # Show current stats
   nftban stats --detailed         # Detailed breakdown
   nftban report generate          # Generate HTML report
   nftban report email admin@example.com  # Email report
   nftban report json              # JSON export for monitoring
   ```

**Example output:**
```
NFTBan Statistics v0.10.0
═══════════════════════════════════════════════════════════════

Summary (Last 24 Hours)
───────────────────────
Total Bans: 127 IPs
  - Fail2Ban: 89 (70%)
  - Manual: 12 (9%)
  - Feeds: 26 (21%)

Currently Active: 43 IPs
  - temp_ban: 38 (will expire)
  - user_blacklist: 5 (permanent)

Top Sources:
  1. Fail2Ban (sshd): 67 bans
  2. Fail2Ban (nginx-limit-req): 22 bans
  3. Feeds (FIREHOL_LEVEL1): 15 bans
  4. Manual: 12 bans

Top Banned IPs:
  1. 192.0.2.45 - 15 times (China, SSH brute force)
  2. 198.51.100.89 - 12 times (Russia, Web scanning)
  3. 203.0.113.12 - 8 times (USA, API abuse)

Top Countries:
  1. China: 45 bans
  2. Russia: 32 bans
  3. USA: 18 bans
  4. Brazil: 12 bans

Firewall Performance:
  - Packet drops: 12,456
  - Average lookup time: <1µs
  - Total rules: 234
  - Active sets: 15
```

**Implementation files:**
- `/usr/lib/nftban/core/nftban_stats.sh` (UPDATE - expand existing)
- `/usr/lib/nftban/cli/cmd_stats.sh` (NEW)
- `/usr/lib/nftban/cli/cmd_report.sh` (NEW - expand existing)
- HTML template: `/usr/share/nftban/templates/report.html` (NEW)

---

### 2. PACKAGING (RPM & DEB)

#### Auto-Build System
**Priority:** HIGH
**Description:** Automated RPM and DEB package building
**Status:** ❌ NOT IMPLEMENTED
**Reference:** "WE HAVE GUIDE FOR AUTO RPM DEB IN GIT NEED TO IMPLEMENT TOO"

**Requirements:**
1. **RPM packaging (Rocky/AlmaLinux/Fedora):**
   - Spec file: `/packaging/rpm/nftban.spec`
   - Build script: `/packaging/build-rpm.sh`
   - Auto-detect version from code
   - Include all dependencies
   - Create systemd units
   - Set up sysusers.d and tmpfiles.d

2. **DEB packaging (Ubuntu/Debian):**
   - Debian control files: `/packaging/deb/`
   - Build script: `/packaging/build-deb.sh`
   - Auto-detect version
   - Include dependencies
   - Systemd integration

3. **GitHub Actions:**
   - Auto-build on release tag
   - Upload to GitHub Releases
   - Test installation on multiple distros

**Implementation:**
- `/packaging/rpm/nftban.spec` (NEW)
- `/packaging/deb/control` (NEW)
- `/packaging/deb/rules` (NEW)
- `/packaging/build-rpm.sh` (NEW)
- `/packaging/build-deb.sh` (NEW)
- `/.github/workflows/build-packages.yml` (NEW)

---

### 3. DAEMON IMPLEMENTATION

**Priority:** HIGH
**Description:** NFTBan daemon for background tasks
**Status:** ⚠️  PARTIALLY IMPLEMENTED (needs review)
**Reference:** "remember we have daemon"

**What the daemon should do:**
1. **Feed updates:** Auto-update feeds on schedule
2. **Health monitoring:** Periodic health checks
3. **Ban expiry monitoring:** Track ban expirations (nftables handles this, but daemon can log)
4. **Metrics collection:** Collect stats over time
5. **API endpoint:** Optional HTTP API for monitoring (future)

**Implementation:**
- Review existing daemon code (if any)
- `/usr/lib/systemd/system/nftban.service`
- `/usr/lib/systemd/system/nftban.timer`
- `/usr/lib/nftban/core/nftban_daemon.sh` (NEW or UPDATE)

---

### 4. LICENSING & LEGAL

#### Integrate Legal Pack
**Priority:** HIGH
**Description:** Apply legal files from /tmp/nftban-legal-pack-v2
**Status:** ❌ NOT INTEGRATED

**Files to integrate:**
```
/tmp/nftban-legal-pack-v2/
├── CONTRIBUTING.md           → Copy to repo root
├── LICENSE-INSERT.md         → Review and apply
├── NOTICE.md                 → Copy to repo root
├── README-License-Summary.md → Review
├── SPDX-HEADERS.md          → Apply headers to all files
├── TRADEMARK.md             → Copy to repo root
├── licenses/
│   └── NFTBAN-Docs.txt      → Review
└── branding/                 → Brand assets
```

**Actions:**
1. Copy all legal files to repo root
2. Apply SPDX headers to ALL source files:
   ```bash
   # SPDX-License-Identifier: MPL-2.0
   ```
3. Update README.md with license summary
4. Add CONTRIBUTING.md guidelines
5. Add TRADEMARK.md protection

---

### 5. BUGS & ISSUES FROM TESTING

#### Known Issues (to fix):

1. **Go binary path issue:**
   - Error: "nftban-feeds binary not found"
   - Path: Expected at `/usr/lib/nftban/bin/nftban-feeds`
   - But install.sh puts it at: `/usr/share/nftban/go-binaries/`
   - **Fix:** Update install.sh or fix paths

2. **Bash completion not working:**
   - Completions installed but not loading
   - **Fix:** Test completion script, fix syntax errors

3. **Health check false positives:**
   - Some checks report failure when they shouldn't
   - **Fix:** Review nftban_health.sh logic

4. **Fail2Ban action not auto-installing:**
   - Need explicit `nftban fail2ban install-action` command
   - **Fix:** Auto-create action during install.sh

5. **Profile application doesn't reload firewall:**
   - `nftban profile set` changes config but doesn't apply
   - **Fix:** Add auto-reload or warn user

6. **Feed update timer not auto-enabled:**
   - install.sh doesn't enable nftban-feeds.timer
   - **Fix:** Enable timer during installation

---

## 📚 DOCUMENTATION (For Next Session)

### High Priority Remaining

#### 1. troubleshoot.md
**Priority:** HIGH
**Status:** ❌ TODO
**Est. Size:** 600-800 lines

**Content:**
- Common issues and solutions
- Installation problems
- Configuration errors
- Firewall connectivity issues
- Fail2Ban integration problems
- Feed update failures
- Performance issues
- Debug mode usage
- How to get support

---

### Medium Priority

#### 2. concepts/nftables-model.md
**Priority:** MEDIUM
**Est. Size:** 500-700 lines

**Content:**
- Deep dive into 3-table architecture
- Why 3 tables instead of 1
- Priority ordering explained
- Runtime table persistence
- Static tables (v4, v6)
- Set types and sizes
- Performance characteristics
- Comparison with iptables

#### 3. concepts/defense-layers.md
**Priority:** MEDIUM
**Est. Size:** 500-600 lines

**Content:**
- 8 security layers explained:
  1. Connection state tracking
  2. IP whitelist
  3. Port filtering
  4. Static blacklist (user_blacklist)
  5. Dynamic blacklist (temp_ban via Fail2Ban)
  6. Threat intelligence (feeds)
  7. Application layer (DDoS, portscan)
  8. Recovery system (commit-confirm)
- Packet flow through layers
- Layer interaction
- Priority ordering

#### 4. concepts/recovery-system.md
**Priority:** MEDIUM
**Source:** Adapt from existing RECOVERY_GUIDE.md
**Est. Size:** 400-500 lines

**Content:**
- Commit-confirm pattern (JunOS-style)
- 5-minute grace period
- Auto-rollback mechanism
- Manual rollback
- Emergency recovery
- Kernel kill-switch
- Best practices

---

### Lower Priority

#### 5. reference/cli.md
**Priority:** LOW
**Est. Size:** 800-1000 lines

**Content:**
- All 15 CLI commands documented:
  - nftban ban
  - nftban unban
  - nftban whitelist
  - nftban feeds
  - nftban fail2ban
  - nftban profile
  - nftban health
  - nftban ddos
  - nftban portscan
  - nftban port
  - nftban module
  - nftban fhs
  - nftban geoip
  - nftban cloudflare
  - nftban mail
- Full syntax for each
- Options and flags
- Examples
- Return codes

#### 6. reference/modules.md
**Priority:** LOW
**Est. Size:** 1000+ lines

**Content:**
- All 17 core modules documented
- Purpose of each module
- Functions provided
- Dependencies
- Configuration
- Usage examples

#### 7. reference/configuration.md
**Priority:** LOW
**Est. Size:** 700-900 lines

**Content:**
- All config options
- Default values
- Valid ranges
- Examples
- Security implications
- Performance tuning

#### 8. recipes/common-tasks.md
**Priority:** LOW
**Est. Size:** 500-600 lines

**Content:**
- Everyday operations
- Copy-paste examples
- Monitoring
- Maintenance
- Backup/restore

#### 9. recipes/web-server.md
**Priority:** LOW
**Est. Size:** 400-500 lines

**Content:**
- Nginx/Apache hardening
- Web-specific protections
- Cloudflare integration
- Rate limiting
- Bot blocking

#### 10. recipes/ssh-hardening.md
**Priority:** LOW
**Est. Size:** 400-500 lines

**Content:**
- SSH best practices
- Key-only authentication
- Port knocking (optional)
- Fail2Ban integration
- Connection limits

#### 11. recipes/mail-server.md
**Priority:** LOW
**Est. Size:** 400-500 lines

**Content:**
- Postfix/Dovecot hardening
- Mail-specific protections
- RBL integration
- Spam prevention

---

## 🔧 FEATURES & ENHANCEMENTS

### 1. Search Enhancement (CRITICAL)

**Command:** `nftban search <ip>`

**Implementation checklist:**
- [ ] Create `/usr/lib/nftban/cli/cmd_search.sh`
- [ ] Create `/usr/lib/nftban/core/nftban_search.sh`
- [ ] Search all 5 sets per table (whitelist, temp_ban, user_blacklist, system_blacklist, feeds)
- [ ] Search Fail2Ban jails
- [ ] Search feed files
- [ ] Support CIDR notation
- [ ] Show detailed information (source, jail, expiry, reason)
- [ ] Add to main CLI
- [ ] Add bash completion
- [ ] Write tests

---

### 2. Stats & Metrics System (CRITICAL)

**Commands:**
- `nftban stats`
- `nftban stats --detailed`
- `nftban report generate`
- `nftban report email <address>`
- `nftban report json`

**Implementation checklist:**
- [ ] Expand `/usr/lib/nftban/core/nftban_stats.sh`
- [ ] Create `/usr/lib/nftban/cli/cmd_stats.sh`
- [ ] Create `/usr/lib/nftban/cli/cmd_report.sh`
- [ ] Metrics collection:
  - [ ] Count bans by source (manual, fail2ban, feeds)
  - [ ] Track ban history (store in `/var/lib/nftban/metrics/`)
  - [ ] Aggregate by time period (hour, day, week, month)
  - [ ] Top IPs, top countries, top jails
- [ ] HTML report template
- [ ] Email integration
- [ ] JSON export for monitoring tools (Prometheus, Grafana, Nagios)

---

### 3. Backup & Restore (HIGH)

**Commands:**
- `nftban backup create [--output <file>]`
- `nftban backup restore <file>`
- `nftban backup list`

**What to backup:**
- Configuration (`/etc/nftban/`)
- Ban lists (all sets)
- State data (`/var/lib/nftban/state/`)
- Feed data (optional)

**Implementation checklist:**
- [ ] Create `/usr/lib/nftban/cli/cmd_backup.sh`
- [ ] Create backup format (tar.gz)
- [ ] Include metadata (version, date, hostname)
- [ ] Verify restore compatibility
- [ ] Add encryption option (optional)

---

### 4. GeoIP Country Banning (HIGH)

**Command:** `nftban country ban <country>`

**Status:** ⚠️  PARTIALLY IMPLEMENTED (Go binary exists)

**Implementation checklist:**
- [ ] Verify Go binary works: `/usr/lib/nftban/bin/nftban-geoip`
- [ ] Create CLI wrapper: `/usr/lib/nftban/cli/cmd_country.sh`
- [ ] Download/update MaxMind GeoLite2 database
- [ ] Ban by country code (e.g., `nftban country ban CN`)
- [ ] Unban by country
- [ ] List banned countries
- [ ] Whitelist before banning (safety)

---

### 5. Cloudflare IP Whitelisting (MEDIUM)

**Command:** `nftban cloudflare update`

**Status:** ⚠️  PARTIALLY IMPLEMENTED

**Implementation checklist:**
- [ ] Verify module exists: `/usr/lib/nftban/core/nftban_cloudflare.sh`
- [ ] Auto-download Cloudflare IP ranges
- [ ] Add to whitelist
- [ ] Update on schedule (weekly)
- [ ] Test Fail2Ban integration

---

### 6. Email Notifications (MEDIUM)

**Integration:**
- Health check failures
- Ban events
- Reports

**Implementation checklist:**
- [ ] Create `/usr/lib/nftban/core/nftban_mail.sh`
- [ ] Support multiple recipients
- [ ] Template system
- [ ] HTML emails
- [ ] Digest mode (daily summary vs per-event)

---

### 7. API/Webhook Support (FUTURE)

**Description:** HTTP API for monitoring and integration

**Use cases:**
- External monitoring tools
- Custom dashboards
- Integration with SIEM

**Implementation:** Post v0.10.0

---

## 🧪 TESTING & QA

### 1. Comprehensive Testing Checklist

- [ ] **Installation tests:**
  - [ ] Test on Rocky Linux 9
  - [ ] Test on AlmaLinux 9
  - [ ] Test on Ubuntu 22.04
  - [ ] Test on Debian 12
  - [ ] Test on Fedora 39

- [ ] **Feature tests:**
  - [ ] Ban/unban IPs
  - [ ] Whitelist
  - [ ] Security profiles (all 6)
  - [ ] Feed updates (all 14 feeds)
  - [ ] Fail2Ban integration (5+ jails)
  - [ ] Health checks
  - [ ] Commit-confirm recovery
  - [ ] GeoIP lookups

- [ ] **Performance tests:**
  - [ ] Go binary speed (feeds)
  - [ ] nftables lookup time
  - [ ] Large feed handling (100K+ IPs)
  - [ ] Memory usage
  - [ ] CPU usage

- [ ] **Security tests:**
  - [ ] Cannot bypass whitelist
  - [ ] Ban priority correct
  - [ ] Recovery system works
  - [ ] No lockout scenarios

---

### 2. Integration Tests

- [ ] **Fail2Ban:**
  - [ ] SSH ban/unban
  - [ ] Nginx ban/unban
  - [ ] Multiple jails
  - [ ] Recidive jail
  - [ ] NFTBan action works

- [ ] **Feeds:**
  - [ ] All 14 feeds download
  - [ ] Go binary processes correctly
  - [ ] Apply to nftables
  - [ ] No conflicts with manual bans

- [ ] **Profiles:**
  - [ ] Apply each profile
  - [ ] Services work
  - [ ] No connectivity loss
  - [ ] Revert to previous profile

---

### 3. Documentation Tests

- [ ] **MkDocs build:**
  ```bash
  mkdocs build --strict
  mkdocs serve
  ```

- [ ] **Link checking:**
  - All internal links work
  - All external links work
  - All code references valid

- [ ] **Example verification:**
  - All examples tested
  - All output current
  - All commands work

---

## 🚀 DEPLOYMENT & RELEASE

### 1. Pre-Release Checklist

- [ ] All critical bugs fixed
- [ ] Search command implemented
- [ ] Stats/metrics system complete
- [ ] RPM/DEB packages built
- [ ] All high-priority documentation complete
- [ ] Legal files integrated (licenses, NOTICE, etc.)
- [ ] Comprehensive testing passed
- [ ] Security audit complete

### 2. Release Process

1. **Version bump:**
   - Update all version strings
   - Update CHANGELOG.md

2. **Build packages:**
   ```bash
   ./packaging/build-rpm.sh
   ./packaging/build-deb.sh
   ```

3. **Tag release:**
   ```bash
   git tag -a v0.10.0 -m "NFTBan v0.10.0 Release"
   git push origin v0.10.0
   ```

4. **GitHub Release:**
   - Upload RPM packages
   - Upload DEB packages
   - Upload tarball
   - Include CHANGELOG
   - Include LICENSE

5. **Deploy documentation:**
   - Push to GitHub (triggers GitHub Pages deploy)
   - Verify live site

6. **Announce:**
   - GitHub Discussions
   - Website
   - Social media

---

## 📋 CHECKLIST SUMMARY

### Critical (Must-Have for v0.10.0)

- [ ] `nftban search <ip>` command
- [ ] Stats & metrics system
- [ ] RPM packaging
- [ ] DEB packaging
- [ ] License integration
- [ ] Fix all critical bugs
- [ ] Documentation: troubleshoot.md

### High Priority

- [ ] Backup/restore system
- [ ] GeoIP country banning (complete)
- [ ] Daemon review/update
- [ ] Email notifications
- [ ] Feed update timer auto-enable
- [ ] Comprehensive testing

### Medium Priority

- [ ] Documentation: nftables-model.md
- [ ] Documentation: defense-layers.md
- [ ] Documentation: recovery-system.md
- [ ] Cloudflare integration (complete)
- [ ] Bash completion fixes

### Low Priority (Post v0.10.0)

- [ ] Documentation: CLI reference
- [ ] Documentation: Module reference
- [ ] Documentation: Configuration reference
- [ ] Documentation: Recipes
- [ ] API/Webhook support
- [ ] Web UI (future)

---

## 📊 COMPLETION STATUS

**Overall:** 65% complete

**By Category:**
- Documentation: 60% (7/12 high-priority guides done)
- Core Features: 85% (main features work, search/stats missing)
- Packaging: 0% (RPM/DEB not done)
- Testing: 40% (manual testing done, automated tests needed)
- Legal: 0% (files not integrated)

**Estimated Time to v0.10.0 Release:**
- Critical features: 2-3 days
- Packaging: 1-2 days
- Testing: 2-3 days
- Documentation: 1-2 days
- **Total:** 6-10 days

---

## 🎯 NEXT SESSION PRIORITIES

**Order of execution:**

1. ✅ **Implement search command** (4-6 hours) - DONE
   - Most requested feature
   - Critical for usability
   - Deployed to lab servers

2. ✅ **Integrate licenses** (1-2 hours) - DONE
   - Legal requirement
   - Files integrated
   - SPDX script created

3. **Finish SPDX headers** (30 minutes) - IN PROGRESS
   - Apply to remaining 4 files
   - Run: `./apply-spdx-headers.sh --apply`

4. **Stats & metrics system** (6-8 hours) - HIGH PRIORITY
   - Critical for monitoring
   - Enables reporting
   - `nftban stats`, `nftban report`

5. **RPM/DEB packaging** (17-24 hours) - DISCUSSION READY
   - See PACKAGING_DISCUSSION.md
   - Need decisions before implementation
   - Docker + GitHub Actions

6. **Fix critical bugs** (4-6 hours)
   - Go binary paths
   - Profile application
   - Timer auto-enable

7. **Complete troubleshoot.md** (2-3 hours)
   - Final high-priority doc
   - Completes essential guides

**Total remaining time:** 30-43 hours (4-6 work days)

---

**Last Updated:** 2025-10-28
**Next Review:** After critical features implemented
