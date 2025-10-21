# TODO: v0.9.2 Security & Bug Fixes

**Priority:** CRITICAL
**Target Release:** v0.9.2
**Status:** IN PROGRESS
**Timeline:** 2-3 weeks

---

## Release Focus

v0.9.2 is a **SECURITY-FOCUSED RELEASE** addressing:
- HIGH severity security findings from external audit
- Code quality improvements (ShellCheck compliance)
- Bug fixes discovered during security assessment
- Foundation for OpenSSF Scorecard 8+/10

**NOT included in v0.9.2:**
- New features (deferred to v0.10.0)
- Major refactoring (deferred to v0.10.0)
- fail2ban jails (separate TODO, v0.9.3+)

---

## HIGH Priority Security Fixes (MUST FIX)

### BUG47: Whitelist Bypass via CIDR Feeds
**Severity:** HIGH
**File:** `lib/nftban_feeds_lib.sh`, `lib/nftban_nftables_module.sh`
**Complexity:** Medium
**Estimated Time:** 4-6 hours

**Issue:**
CIDR ranges in feeds can block individual whitelisted IPs because feeds library only checks exact IP equality when `RESPECT_WHITELIST=true`. No set subtraction at nftables layer.

**Example:**
- Feed imports: `1.2.3.0/24`
- Whitelist has: `1.2.3.4`
- Result: `1.2.3.4` gets blocked ❌

**Fix Required:**
```bash
# Option 1: nftables priority enforcement (RECOMMENDED)
# In nftables chains, ensure whitelist ALWAYS checked first
chain input_main {
    type filter hook input priority 0;

    # 1. WHITELIST FIRST (highest priority)
    ip saddr @whitelist_v4 accept
    ip6 saddr @whitelist_v6 accept

    # 2. THEN check feeds/blacklists
    ip saddr @feed_v4 drop
    ip saddr @blacklist_v4 drop
    # ... rest of rules
}

# Option 2: Set subtraction during feed import
# In feeds library, compute overlap before adding
for cidr in $FEED_ENTRIES; do
    if ! overlaps_whitelist "$cidr"; then
        add_to_feed "$cidr"
    fi
done
```

**Test Plan:**
1. Add `192.0.2.10` to whitelist
2. Import feed with `192.0.2.0/24`
3. Verify `192.0.2.10` can still connect
4. Verify `192.0.2.20` (not whitelisted) is blocked

**Files to Modify:**
- `lib/nftban_feeds_lib.sh` - Add overlap checking
- `lib/nftban_nftables_module.sh` - Ensure chain priority
- `lib/nftban_whitelist_module.sh` - Add CIDR overlap function

**Priority:** 🔴 CRITICAL - Fix in Phase 1

---

### BUG48: Update TOCTOU Window (Time-of-Check-Time-of-Use)
**Severity:** HIGH
**File:** `lib/nftban_update_module.sh`
**Complexity:** Medium
**Estimated Time:** 6-8 hours

**Issue:**
Update module fetches from GitHub `main` branch (floating reference). Between version check and download, content can change. If SHA256SUMS.txt is missing, validation is skipped.

**Attack Scenario:**
1. Attacker compromises GitHub account
2. User checks for update (reads version X)
3. Attacker pushes malicious version Y
4. User downloads malicious version Y thinking it's version X

**Fix Required:**
```bash
# Current (VULNERABLE):
curl -sL "https://raw.githubusercontent.com/user/nftban/main/.version"
curl -sL "https://raw.githubusercontent.com/user/nftban/main/SHA256SUMS.txt"

# Fixed (SECURE):
# 1. Resolve latest release tag via API
LATEST_TAG=$(curl -sH "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/user/nftban/releases/latest" | jq -r .tag_name)

# 2. Get immutable commit SHA for that tag
COMMIT_SHA=$(curl -sH "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/user/nftban/git/ref/tags/$LATEST_TAG" | jq -r .object.sha)

# 3. Download ALL files by commit SHA (immutable)
curl -sL "https://raw.githubusercontent.com/user/nftban/$COMMIT_SHA/SHA256SUMS.txt"

# 4. ALWAYS verify checksums (fail if missing)
[[ -f SHA256SUMS.txt ]] || die "Checksum file missing - refusing update"
sha256sum -c SHA256SUMS.txt || die "Checksum verification failed - refusing update"
```

**Additional Improvements:**
- Add GPG signing for releases (future)
- Use Sigstore for supply chain security (future)
- Fail closed if any validation step fails

**Test Plan:**
1. Create test release with specific commit SHA
2. Verify update resolves to exact commit
3. Test with missing SHA256SUMS.txt → should fail
4. Test with corrupted checksums → should fail
5. Test with valid checksums → should succeed

**Files to Modify:**
- `lib/nftban_update_module.sh` - Complete rewrite of update logic
- Add dependency: `jq` for JSON parsing
- Update documentation

**Priority:** 🔴 CRITICAL - Fix in Phase 1

---

### BUG49: Path Traversal in Jail Names
**Severity:** HIGH
**File:** `lib/nftban_fail2ban_module.sh`, `lib/nftban_template_module.sh`
**Complexity:** Low
**Estimated Time:** 2-3 hours

**Issue:**
Jail names used directly in file path construction without validation. Crafted jail name could attempt path traversal.

**Attack Scenario:**
```bash
# Malicious input:
nftban fail2ban create-jail "../../etc/passwd"

# Results in file creation:
/etc/fail2ban/jail.d/nftban-../../etc/passwd.conf
# Which could overwrite /etc/passwd
```

**Fix Required:**
```bash
# Add strict validation function
validate_jail_name() {
    local name="$1"

    # Only allow alphanumeric, underscore, hyphen
    if [[ ! "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then
        die "Invalid jail name: $name (must be alphanumeric with _ or -)"
    fi

    # Prevent reserved/dangerous names
    case "$name" in
        .|..|/*|*/*|*\\*)
            die "Invalid jail name: $name"
            ;;
    esac

    # Maximum length check
    if [[ ${#name} -gt 64 ]]; then
        die "Jail name too long: $name (max 64 chars)"
    fi

    echo "$name"
}

# Use everywhere jail names are accepted
create_jail_config() {
    local jail_name
    jail_name=$(validate_jail_name "$1") || return 1

    local jail_file="/etc/fail2ban/jail.d/nftban-${jail_name}.conf"
    # Now safe to use
}
```

**Test Plan:**
1. Test valid names: `sshd`, `http-auth`, `my_jail`
2. Test invalid: `../../../etc/passwd` → should fail
3. Test invalid: `jail/../conf` → should fail
4. Test invalid: `jail/name` → should fail
5. Test edge cases: empty string, very long name

**Files to Modify:**
- `lib/nftban_fail2ban_module.sh` - Add validation to all functions
- `lib/nftban_template_module.sh` - Add validation
- `lib/nftban_utils_lib.sh` - Add validation function

**Priority:** 🔴 CRITICAL - Fix in Phase 1

---

### BUG50: Race Conditions in Feed Imports
**Severity:** HIGH
**File:** `lib/nftban_feeds_lib.sh`, feed cron jobs
**Complexity:** High
**Estimated Time:** 8-10 hours

**Issue:**
Feed imports add elements one-by-one creating partial states. No flock on all cron jobs. Multiple concurrent updates can corrupt state.

**Problem:**
```bash
# Current (VULNERABLE):
for ip in $FEED_IPS; do
    nft add element inet nftban blacklist_v4 { $ip }
    # ← Race window here! Partial state visible!
done
```

**Fix Required:**
```bash
# 1. Add flock to ALL cron jobs and update functions
exec 200>/var/lock/nftban-feeds.lock
flock -n 200 || {
    log "Another feed update in progress, skipping"
    exit 0
}

# 2. Use atomic nft set updates
# Method A: Staging set with atomic swap
{
    echo "flush set inet nftban feed_staging_v4"
    for ip in $FEED_IPS; do
        echo "add element inet nftban feed_staging_v4 { $ip }"
    done
    echo "flush set inet nftban feed_v4"
    echo "add element inet nftban feed_v4 { @feed_staging_v4 }"
} | nft -f -  # Single atomic transaction

# Method B: Generate nft include file (RECOMMENDED)
{
    echo "define FEED_IPS_V4 = {"
    printf "    %s,\n" $FEED_IPS
    echo "}"
    echo ""
    echo "flush set inet nftban feed_v4"
    echo "add element inet nftban feed_v4 \$FEED_IPS_V4"
} > /tmp/feed-update.nft

nft -f /tmp/feed-update.nft  # Atomic
rm /tmp/feed-update.nft
```

**Files Needing flock:**
- All cron jobs in `/etc/cron.d/nftban-*`
- `lib/nftban_feeds_lib.sh` - All update functions
- `lib/nftban_ratelimit_module.sh` - Tracker updates
- `lib/nftban_geoip_module.sh` - Update functions

**Test Plan:**
1. Run feed update
2. While running, start another update → should exit gracefully
3. Check for "in progress" message in logs
4. Verify atomic updates: no partial IP lists visible
5. Stress test: rapid concurrent updates

**Files to Modify:**
- `lib/nftban_feeds_lib.sh` - Complete rewrite of import logic
- `lib/nftban_ratelimit_module.sh` - Add flock
- `lib/nftban_geoip_module.sh` - Add flock
- All cron job files - Add flock wrapper

**Priority:** 🔴 CRITICAL - Fix in Phase 1

---

### BUG51: Missing Strict Mode
**Severity:** HIGH (aggregate)
**File:** Multiple scripts
**Complexity:** Low
**Estimated Time:** 2 hours

**Issue:**
Some scripts missing `set -Eeuo pipefail`, allowing silent failures.

**Fix Required:**
```bash
# Add to EVERY script entrypoint:
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Add trap for better error reporting:
trap 'echo "Error in $BASH_SOURCE at line $LINENO" >&2' ERR
```

**Find Missing:**
```bash
# Run this to find all scripts missing strict mode:
cd /home/gituser/github/nftban
for script in bin/* lib/*.sh scripts/*.sh; do
    [[ -f "$script" ]] || continue
    if ! grep -q "set -.*e" "$script" 2>/dev/null; then
        echo "Missing strict mode: $script"
    fi
done
```

**Test Plan:**
1. Run audit script above
2. Add strict mode to all found files
3. Test each modified script
4. Verify no regressions

**Files to Modify:**
- (Will be identified by scan results)
- Likely: some older helper scripts, cron scripts

**Priority:** 🔴 CRITICAL - Fix in Phase 1

---

## MEDIUM Priority Fixes (SHOULD FIX)

### BUG52: IPv6 Port Module Invalid Selector
**Severity:** MEDIUM
**File:** `lib/nftban_port_module.sh`
**Estimated Time:** 1 hour

**Issue:**
```bash
# Wrong:
ip6 version 6 tcp dport 22 accept

# Correct:
ip6 nexthdr tcp tcp dport 22 accept
# Or in inet table:
tcp dport 22 accept  # Works for both v4 and v6
```

**Priority:** 🟡 MEDIUM - Fix in Phase 2

---

### BUG53: curl Usage Not Hardened
**Severity:** MEDIUM
**File:** Multiple modules using curl
**Estimated Time:** 3 hours

**Fix:**
Create safe_curl wrapper:
```bash
safe_curl() {
    curl --fail-with-body \
         --proto '=https' \
         --tlsv1.2 \
         --retry 2 \
         --retry-delay 2 \
         --connect-timeout 10 \
         --max-time 30 \
         --silent \
         --show-error \
         "$@"
}
```

**Priority:** 🟡 MEDIUM - Fix in Phase 2

---

### BUG54: ShellCheck Warnings
**Severity:** MEDIUM (aggregate)
**File:** Multiple
**Estimated Time:** 4-6 hours

**Fix:** Address all ShellCheck warnings in critical modules:
- Quoting issues
- Unused variables
- Logic improvements

**Priority:** 🟡 MEDIUM - Fix in Phase 2

---

## Code Quality Improvements

### Improvement 1: Replace echo | grep with [[]]
**Estimated Time:** 2 hours

```bash
# Instead of:
if echo "$value" | grep -q "pattern"; then

# Use:
if [[ "$value" =~ pattern ]]; then
```

---

### Improvement 2: Email Alert Sanitization
**Estimated Time:** 1 hour

Sanitize paths and content in email alerts to prevent information leakage.

---

## v0.9.2 Release Checklist

### Phase 1: Critical Fixes (Week 1-2)
- [ ] BUG47 - Whitelist bypass (4-6 hrs)
- [ ] BUG48 - Update TOCTOU (6-8 hrs)
- [ ] BUG49 - Path traversal (2-3 hrs)
- [ ] BUG50 - Race conditions (8-10 hrs)
- [ ] BUG51 - Strict mode audit (2 hrs)
- [ ] Run security re-scan
- [ ] Verify 0 HIGH severity issues

**Total Phase 1:** 22-29 hours

### Phase 2: Medium Fixes (Week 2-3)
- [ ] BUG52 - IPv6 selector (1 hr)
- [ ] BUG53 - curl hardening (3 hrs)
- [ ] BUG54 - ShellCheck warnings (4-6 hrs)
- [ ] Code quality improvements (3 hrs)
- [ ] Run security re-scan
- [ ] Verify <20 warnings

**Total Phase 2:** 11-13 hours

### Phase 3: Testing & Release (Week 3)
- [ ] Comprehensive testing on all 3 lab servers
- [ ] 6-hour stability check on all servers
- [ ] Update CHANGELOG.md
- [ ] Update version to v0.9.2 in all files
- [ ] Create release notes
- [ ] Tag release: `git tag -s v0.9.2 -m "Security-focused release"`
- [ ] Generate SHA256SUMS.txt
- [ ] Create GitHub release

**Total Phase 3:** 6-8 hours

---

## Total Effort Estimate

**v0.9.2 Security Release:**
- Phase 1 (Critical Fixes): 22-29 hours
- Phase 2 (Medium Fixes): 11-13 hours
- Phase 3 (Testing & Release): 6-8 hours
- **fail2ban Jails (Parallel)**: 6-8 hours
- **TOTAL: 45-58 hours**

**Timeline:**
- Part-time (10 hrs/week): 5-6 weeks
- Full-time (40 hrs/week): 1-1.5 weeks

**Note:** fail2ban work can be done in parallel with security fixes by different person, or sequentially as a break from security work.

---

## Feature Addition (Can Work in Parallel)

### FEATURE: fail2ban Jails Configuration
**Priority:** MEDIUM
**Can be done:** In parallel with security fixes
**Estimated Time:** 6-8 hours
**See:** `docs/TODO_fail2ban_jails.md`

**Issue:**
fail2ban is installed but has NO jail configurations, so it's running idle doing nothing.

**Solution:**
Create default jail configurations during install:
- SSH protection (sshd) - **Essential**
- HTTP/HTTPS protection - Optional
- Panel protection (DirectAdmin, cPanel, Plesk) - Optional
- Mail/FTP protection - Optional

**Why Include in v0.9.2:**
- **Security-focused release** - fail2ban is a security feature
- **No dependencies** on security bug fixes
- **Can be worked on in parallel**
- **Adds immediate value** - auto-protection from brute force
- **Low complexity** - just config files + templates

**Implementation Tasks:**
1. Create `/etc/fail2ban/action.d/nftban-ban.conf` (30 min)
2. Create jail templates (1 hour)
3. Add jail creation to init script (1 hour)
4. Add CLI commands (`nftban fail2ban ...`) (2 hours)
5. Add service auto-detection (1 hour)
6. Test on all 3 distros (2 hours)
7. Documentation (1 hour)

**Total:** 6-8 hours (can overlap with Phase 1/2 security fixes)

**Benefits:**
- ✅ Complete v0.9.2 as a comprehensive security release
- ✅ Automated SSH brute force protection
- ✅ Works out of the box
- ✅ Integrates with existing nftban ban system

**Decision:** INCLUDE in v0.9.2 (work in parallel with security fixes)

---

## After v0.9.2

**v0.9.3+ Planning:**
- BATS testing framework
- Additional code quality improvements
- Performance optimizations

**v0.10.0+ Planning:**
- Main CLI refactoring (see TODO_v0.9.2_main_cli_refactor.md)
- Major feature additions
- Advanced monitoring

**OpenSSF Readiness:**
- After v0.9.2: Add SECURITY.md, LICENSE
- Enable GitHub security features
- Set up CI/CD security workflows
- Run OpenSSF Scorecard (target 8+/10)

---

## Success Criteria for v0.9.2

**Security:**
- ✅ All 5 HIGH severity issues fixed
- ✅ ShellCheck errors: 0
- ✅ ShellCheck warnings: < 20
- ✅ Gitleaks: 0 secrets
- ✅ Trivy HIGH/CRITICAL: 0

**Stability:**
- ✅ 6-hour stability check passed on all distros
- ✅ No regressions from v0.9.1
- ✅ All existing features working

**Quality:**
- ✅ All scripts have strict mode
- ✅ Consistent code style
- ✅ Professional error handling
- ✅ Complete documentation

---

**Status:** Ready to begin Phase 1
**Next Step:** Review security scan results, then start fixing BUG47-51
