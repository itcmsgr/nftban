# NFTBan v0.9.3 - Security Maturity & Hardening Release

**Type:** Major Security Release
**Focus:** Production-Grade Security Hardening & Industry Best Practices
**Status:** IN DEVELOPMENT
**Target Release:** November 2025
**Estimated Effort:** 60-80 hours

---

## Vision Statement

**v0.9.3 is NOT just bug fixes - it's SECURITY MATURITY**

Transform NFTBan from "functionally secure" to **"production-grade hardened"** with industry best practices, meeting enterprise security standards.

---

## Release Goals

### Primary Objectives:
1. **🔐 Harden all security weaknesses** (6/10 → 9/10)
2. **🛡️ Implement production-grade bash security** (ChatGPT + industry standards)
3. **🔒 Fix all HIGH priority vulnerabilities** (BUG47-50)
4. **📊 Achieve security maturity** (ready for enterprise deployment)
5. **✅ Pass external security audits** (OpenSSF Scorecard 8+/10)

### Success Criteria:
- ✅ Zero HIGH severity vulnerabilities
- ✅ All scripts production-hardened
- ✅ File permissions locked down (750/640/600)
- ✅ All downloads verified (SHA256)
- ✅ Command injection impossible
- ✅ TOCTOU attacks prevented
- ✅ Information disclosure blocked
- ✅ OpenSSF Scorecard 8+/10

---

## Phase 1: Production-Hardened Header (Week 1-2)

**Goal:** Apply ChatGPT security recommendations to all scripts

### 1.1 Create NFTBAN_PRODUCTION_HEADER_V2.sh
**Effort:** 6-8 hours

**Includes:**
- ✅ Minimal PATH (no /tmp, user-writable dirs)
- ✅ Locale standardization (LC_ALL=C.UTF-8)
- ✅ Error traps with line numbers
- ✅ Secure temp directory (mktemp + chmod 700)
- ✅ Command verification
- ✅ Atomic file operations
- ✅ Secret handling (IP privacy)
- ✅ Exit traps with cleanup
- ✅ Structured logging
- ✅ Readonly critical variables

**Deliverable:** Template ready for use in all scripts

---

### 1.2 Update TEMPLATE_module.sh
**Effort:** 2 hours

**Changes:**
- Remove "BUG51 FIX" comments
- Apply production-hardened header
- Module info first, security second
- NFTBan-specific paths (/etc/nftban)
- Integration with existing logging

**Deliverable:** Updated template for future modules

---

### 1.3 Migrate Critical Modules
**Effort:** 12-16 hours

**Priority Order:**
1. **nftban_update_module.sh** (handles downloads from internet)
2. **nftban_feeds_lib.sh** (external data, TOCTOU risk)
3. **nftban_whitelist_module.sh** (security-critical, self-ban risk)
4. **nftban_blacklist_module.sh** (security-critical)
5. **nftban_nftables_module.sh** (core firewall operations)
6. **nftban_core.sh** (base library)

**Testing:** Each module tested on ALL THREE lab servers before next

**Deliverable:** 6 core modules production-hardened

---

## Phase 2: File Permission Hardening (Week 2-3)

**Goal:** Lock down file permissions to prevent information disclosure

### 2.1 Create Permission Hardening Script
**Effort:** 4 hours

**Script:** `scripts/harden-permissions.sh`

**Changes:**
- 755 → 750 (directories)
- 644 → 640 (library files, configs)
- 644 → 600 (sensitive: whitelist, error logs)
- 755 → 700 (temp directory)
- 755 → 750 (executables, except public symlink)

**Deliverable:** Automated hardening script

---

### 2.2 Update Installer
**Effort:** 3 hours

**Files:** `lib/installer/installer_structure.sh`

**Changes:**
- Apply secure permissions during install
- Create sensitive files with 600
- Set directory permissions to 750
- Document permission structure

**Deliverable:** New installs use secure permissions

---

### 2.3 Update Maintenance Module
**Effort:** 2 hours

**File:** `lib/nftban_maintenance_module.sh`

**Changes:**
- Update `validate_permissions()` from 755/644 to 750/640
- Add 600 check for sensitive files
- Add repair function for wrong permissions

**Deliverable:** Validation detects insecure permissions

---

### 2.4 Test & Document
**Effort:** 3 hours

- Test on all three lab servers
- Verify non-root users CANNOT read configs
- Verify non-root CAN still use `nftban` (via symlink)
- Document in SECURITY.md

**Deliverable:** Permissions hardened, tested, documented

---

## Phase 3: Critical Vulnerability Fixes (Week 3-4)

**Goal:** Fix all HIGH priority security issues

### 3.1 BUG47: Whitelist Bypass via CIDR Feeds
**Severity:** HIGH
**Effort:** 4-6 hours

**Issue:** Feed CIDR ranges can block individual whitelisted IPs

**Fix:**
```bash
# Ensure whitelist ALWAYS checked first in nftables chain
chain input {
    # 1. WHITELIST FIRST (highest priority)
    ip saddr @whitelist_v4 accept
    ip6 saddr @whitelist_v6 accept

    # 2. THEN check feeds/blacklists
    ip saddr @feed_v4 drop
}
```

**Files:** `lib/nftban_nftables_module.sh`, `lib/nftban_feeds_lib.sh`

**Testing:** Add IP to whitelist, import overlapping CIDR, verify whitelist wins

---

### 3.2 BUG48: Update TOCTOU Window
**Severity:** HIGH
**Effort:** 6-8 hours

**Issue:** Updates fetch from floating `main` branch, content can change

**Fix:**
- Resolve latest release tag via GitHub API
- Get immutable commit SHA
- Download ALL files by commit SHA
- ALWAYS verify SHA256 checksums
- Fail if checksums missing

**File:** `lib/nftban_update_module.sh` (complete rewrite)

**Dependencies:** Add `jq` for JSON parsing

---

### 3.3 BUG49: Path Traversal in Jail Names
**Severity:** HIGH
**Effort:** 2-3 hours

**Issue:** Jail names used in paths without validation

**Fix:**
```bash
validate_jail_name() {
    local name="$1"
    # Only alphanumeric, underscore, hyphen
    [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || {
        echo "Invalid jail name: $name" >&2
        return 1
    }
    [[ ${#name} -le 64 ]] || {
        echo "Jail name too long" >&2
        return 1
    }
    echo "$name"
}
```

**Files:** `lib/nftban_fail2ban_module.sh`, `lib/nftban_template_module.sh`

---

### 3.4 BUG50: Race Conditions in Feed Imports
**Severity:** HIGH
**Effort:** 8-10 hours

**Issue:** Concurrent feed updates can corrupt state

**Fix:**
- Add flock to ALL cron jobs
- Use atomic nft set updates (staging + swap)
- Generate complete nft include file
- Single atomic transaction

**Files:** All cron jobs, `lib/nftban_feeds_lib.sh`, `lib/nftban_ratelimit_module.sh`

---

## Phase 4: Injection & Input Validation (Week 4-5)

**Goal:** Prevent all command injection attacks

### 4.1 IP Validation Functions
**Effort:** 4 hours

**Create:** `lib/nftban_validation_lib.sh`

**Functions:**
```bash
validate_ipv4()     # Strict IPv4 validation
validate_ipv6()     # Strict IPv6 validation
validate_cidr_v4()  # CIDR notation validation
validate_cidr_v6()  # IPv6 CIDR validation
validate_port()     # Port number validation
validate_protocol() # tcp/udp validation
```

**Deliverable:** Reusable validation library

---

### 4.2 Apply Validation Everywhere
**Effort:** 6-8 hours

**Modules to update:**
- whitelist_module (before adding IPs)
- blacklist_module (before banning)
- nftables_module (before nft commands)
- feeds_lib (before importing)
- geo_module (validate country codes)

**Deliverable:** All user input validated

---

### 4.3 Command Array Pattern
**Effort:** 3 hours

**Change from:**
```bash
nft add element ip nftban_v4 whitelist { $ip }
```

**To:**
```bash
safe_ip=$(validate_ipv4 "$ip") || exit 1
cmd=(nft add element ip nftban_v4 whitelist "{ $safe_ip }")
"${cmd[@]}"
```

**Deliverable:** Injection-proof command execution

---

### 4.4 Feed URL Validation (NEW - from security review)
**Effort:** 2 hours
**Source:** External security audit (Oct 2025), Issue #3

**Issue:** Feed URLs from config can contain command injection

**Attack Vector:**
```bash
NFTBAN_FEED_URL="; rm -rf / #"
```

**Fix:** Add strict URL validation
```bash
validate_url() {
    local url="$1"

    # Only allow https:// or http://
    if [[ ! "$url" =~ ^https?://[a-zA-Z0-9._-]+(/.*)?$ ]]; then
        nftban_log_error "Invalid URL format: $url"
        return 1
    fi

    # Production: enforce HTTPS only
    if [[ "$NFTBAN_PRODUCTION" == "true" ]] && [[ ! "$url" =~ ^https:// ]]; then
        nftban_log_error "HTTPS required in production mode"
        return 1
    fi

    return 0
}
```

**Files:** `lib/nftban_validation_lib.sh`, `lib/nftban_feeds_lib.sh`

**Deliverable:** Feed URL injection prevented

---

### 4.5 Search Module Optimization (NEW - from security review)
**Effort:** 1 hour
**Source:** External security audit (Oct 2025), Issue #4

**Issue:** After whitelist match, code continues checking other lists (information leakage)

**Fix:** Early return in `nftban_search_ip()`
```bash
# PRIORITY 1: WHITELIST (Highest Priority - Never Ban)
if [[ ${#whitelist_files[@]} -gt 0 ]] || [[ "$whitelist_nft" == "true" ]]; then
    status=$NFTBAN_SEARCH_STATUS_WHITELISTED
    primary_location="WHITELIST"
    # RETURN IMMEDIATELY - no need to check other lists
    [[ "$quiet" != "true" ]] && _print_whitelist_status
    return $status
fi
```

**Files:** `lib/nftban_search_module.sh`

**Deliverable:** Information leakage prevented, performance improved

---

### 4.6 Idempotency Checks (NEW - from security review)
**Effort:** 2 hours
**Source:** External security audit (Oct 2025), Issue #8

**Issue:** Fail2Ban repeatedly calls ban on already-banned IPs (waste resources)

**Fix:** Check current state before operations
```bash
nftban_fail2ban_ban() {
    local ip="$1"

    # Check whitelist first
    if nftban_check_whitelist "$ip"; then
        nftban_log_warning "REFUSED: $ip is whitelisted"
        return 0  # Success (don't fail Fail2Ban)
    fi

    # Check if already banned (idempotency)
    if _nftban_search_in_nftables_set "$ip" "temp_ban" "$family"; then
        nftban_log_debug "$ip already in temp_ban set, skipping"
        return 0
    fi

    # Proceed with ban
    nft add element ... temp_ban { "$ip" timeout 1h }
}
```

**Files:** `lib/nftban_fail2ban_module.sh`, `lib/nftban_whitelist_module.sh`, `lib/nftban_blacklist_module.sh`

**Deliverable:** Redundant operations eliminated, performance improved

---

### 4.7 IPv4-Mapped IPv6 Normalization (NEW - from security review)
**Effort:** 3 hours
**Source:** External security audit (Oct 2025), Issue #10

**Issue:** `::ffff:192.168.1.1` same as `192.168.1.1` but won't match in whitelist

**Attack Vector:**
```bash
# Whitelist has: 192.168.1.1
# Attack from: ::ffff:192.168.1.1
# Result: NOT detected as whitelisted! (bypass)
```

**Fix:** Normalize IPv4-mapped IPv6 addresses
```bash
normalize_ip() {
    local ip="$1"

    # Convert IPv4-mapped IPv6 to IPv4
    if [[ "$ip" =~ ^::ffff:([0-9.]+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "$ip"
    fi
}
```

**Apply to:**
- All whitelist checks
- All blacklist checks
- All search operations
- Feed imports

**Files:** `lib/nftban_validation_lib.sh`, all IP handling modules

**Deliverable:** IPv4-mapped IPv6 bypass prevented

---

## Phase 5: Atomic Operations & TOCTOU Prevention (Week 5-6)

**Goal:** Prevent race conditions and partial state

### 5.1 Atomic File Updates
**Effort:** 4 hours

**Pattern:**
```bash
tmpfile=$(mktemp -t "update.XXXXXX")
chmod 640 "$tmpfile"
echo "$data" > "$tmpfile"
mv -f "$tmpfile" "$final_file"  # Atomic
```

**Apply to:**
- Feed imports
- Config updates
- Whitelist/blacklist modifications

**Deliverable:** No partial/corrupt files

---

### 5.2 Secure Temporary Directories
**Effort:** 3 hours

**Apply to all scripts:**
```bash
TMPDIR=$(mktemp -d -t "${0##*/}.XXXXXX")
chmod 700 "$TMPDIR"
readonly TMPDIR
trap 'rm -rf -- "$TMPDIR"' EXIT
```

**Deliverable:** No temp file leaks, no race conditions

---

### 5.3 Enhance Sync Mechanism (NEW - from security review)
**Effort:** 3 hours
**Source:** External security audit (Oct 2025), Issue #7

**Issue:** Files and nftables sets can diverge (no auto-detection/repair)

**Current:** Manual sync required when files/nftables are inconsistent

**Fix:** Automatic divergence detection and repair
```bash
nftban_sync_check_divergence() {
    local list_type="$1"  # whitelist/blacklist

    # Get IPs from files
    local -a file_ips=()
    while IFS= read -r ip; do
        file_ips+=("$ip")
    done < <(cat "${list_type}_ips.conf"* | grep -vE '^[[:space:]]*(#|$)')

    # Get IPs from nftables
    local -a nft_ips=()
    while IFS= read -r ip; do
        nft_ips+=("$ip")
    done < <(nft list set ip nftban_v4 "$list_type" | grep elements | ...)

    # Compare
    if [[ "${file_ips[*]}" != "${nft_ips[*]}" ]]; then
        nftban_log_warning "Divergence detected in $list_type"
        return 1
    fi

    return 0
}

nftban_sync_auto_repair() {
    local list_type="$1"

    if ! nftban_sync_check_divergence "$list_type"; then
        nftban_log_info "Auto-repairing $list_type..."
        nftban_sync_"${list_type}"
    fi
}
```

**Enhancements:**
- Add `--check-sync` command to detect divergence
- Add `--auto-repair` command to fix divergence
- Run divergence check on critical operations
- Document sync strategy

**Files:** `lib/nftban_sync_module.sh`

**Deliverable:** Automatic divergence detection and repair

---

## Phase 6: Information Disclosure Prevention (Week 6)

**Goal:** Prevent sensitive data leakage

### 6.1 Secret Handling
**Effort:** 3 hours

**Changes:**
- Never log actual IPs (use count instead)
- Redact sensitive data in error messages
- Set whitelist files to 600 (owner only)
- Set error logs to 600 (owner only)

**Example:**
```bash
# ❌ DON'T
nftban_log_debug "Adding IPs: $ip_list"

# ✅ DO
nftban_log_debug "Adding whitelist entries (${count} IPs)"
```

**Deliverable:** No information leakage in logs

---

### 6.2 File Permission Audit
**Effort:** 2 hours

**Verify:**
- All configs: 640 or 600
- All logs: 640 or 600
- All directories: 750 or 700
- No world-readable files
- No world-writable anything

**Deliverable:** Complete permission audit

---

## Phase 7: Testing & Quality Assurance (Week 7)

**Goal:** Comprehensive testing and validation

### 7.1 Lab Server Testing
**Effort:** 8 hours

**Test on ALL THREE lab servers:**
- Fresh install with new permissions
- Upgrade from v0.9.2
- All features functional
- No regressions
- Permission validation passes
- 6-hour stability check

**Deliverable:** Verified on all platforms

---

### 7.2 Security Validation
**Effort:** 4 hours

**Verify:**
- ShellCheck passes (0 errors)
- No command injection possible
- No TOCTOU vulnerabilities
- No information disclosure
- File permissions correct
- Download verification works

**Deliverable:** Security checklist complete

---

### 7.3 Performance Testing
**Effort:** 2 hours

**Measure:**
- Script startup time
- Feed import time
- Whitelist sync time
- Memory usage
- CPU usage

**Deliverable:** No performance regression

---

## Phase 8: Documentation & Release (Week 8)

**Goal:** Professional documentation and release

### 8.1 Security Documentation
**Effort:** 4 hours

**Create/Update:**
- SECURITY.md (security policy)
- SECURITY_HARDENING.md (implementation details)
- UPGRADE_NOTES_v0.9.3.md
- RELEASE_NOTES_v0.9.3.md

**Deliverable:** Complete security documentation

---

### 8.2 Update Workspace Guides
**Effort:** 2 hours

**Files:**
- GUIDES_RULES.md (add new patterns)
- SECURITY_TOOLS.md (document hardening)
- PROJECT_STATUS.md (update to v0.9.3)

**Deliverable:** Guides reflect v0.9.3 changes

---

### 8.3 Release
**Effort:** 2 hours

- Update VERSION to 0.9.3
- Create release notes
- Tag: v0.9.3
- Push to GitHub
- Create GitHub Release
- Update lab servers

**Deliverable:** v0.9.3 released

---

## Effort Summary

| Phase | Description | Hours | Notes |
|-------|-------------|-------|-------|
| 1 | Production-Hardened Header | 20-26 | |
| 2 | File Permission Hardening | 12 | |
| 3 | Critical Vulnerability Fixes | 20-27 | |
| 4 | Injection Prevention | 21-23 | **+8h from security review** |
| 5 | Atomic Operations | 10 | **+3h from security review** |
| 6 | Information Disclosure | 5 | |
| 7 | Testing & QA | 14 | |
| 8 | Documentation & Release | 8 | |
| **TOTAL** | **110-125 hours** | **+11h from external security audit** |

**Previous Estimate:** 99-114 hours
**Security Review Additions:** +11 hours (5 new items from Oct 2025 external audit)
**New Estimate:** 110-125 hours

**Timeline:** 8-9 weeks (part-time) or 3-4 weeks (full-time)

---

## Success Metrics

### Security Rating:
- **Current (v0.9.2):** 6/10
- **Target (v0.9.3):** 9/10
- **Gain:** +3 points

### Vulnerabilities:
- **Current:** 7 HIGH, 15 MEDIUM
- **Target:** 0 HIGH, <5 MEDIUM
- **Reduction:** 100% HIGH, 67% MEDIUM

### CWEs Mitigated:
- CWE-362: Race Condition
- CWE-73: External Control of File Name
- CWE-426: Untrusted Search Path
- CWE-377: Insecure Temp File
- CWE-459: Incomplete Cleanup
- CWE-134: Uncontrolled Format String
- CWE-252: Unchecked Return Value

### OpenSSF Scorecard:
- **Current:** 6/10
- **Target:** 8+/10
- **Gain:** +2 points

---

## Dependencies

### Software:
- `jq` (for JSON parsing in update module)
- `sha256sum` (for download verification)
- `mktemp` (for secure temp files)
- `flock` (for race condition prevention)

### Tools:
- ShellCheck (for linting)
- bats-core (for unit testing - optional)
- shfmt (for formatting - optional)

---

## Risks & Mitigation

### Risk 1: Breaking Changes
**Mitigation:** Extensive testing on all three lab servers, backup/restore capability

### Risk 2: Performance Impact
**Mitigation:** Benchmark before/after, optimize critical paths

### Risk 3: Compatibility Issues
**Mitigation:** Test on CentOS 9, CentOS 10, Ubuntu 24.04

### Risk 4: Time Overrun
**Mitigation:** Prioritize critical items, defer optional enhancements to v0.10.0

---

## After v0.9.3

### v0.10.0 (Major Feature Release):
- BATS unit testing framework
- CI/CD pipeline
- GitHub Actions security scanning
- Signed releases (GPG)
- Web dashboard (optional)
- API endpoints (optional)

### Enterprise Readiness:
- OpenSSF Best Practices Badge
- CII Best Practices compliance
- Professional support documentation
- Enterprise deployment guide

---

## Conclusion

**v0.9.3 is our SECURITY TRANSFORMATION release**

Not just fixing bugs - we're achieving **production-grade security maturity** with industry best practices, making NFTBan ready for enterprise deployment.

**Enhanced with External Security Audit:**
This roadmap has been enhanced with findings from external security reviews (Oct 2025), adding 5 critical items:
- ✅ Feed URL validation (command injection prevention)
- ✅ Search module optimization (information leakage prevention)
- ✅ Idempotency checks (performance improvement)
- ✅ IPv4-mapped IPv6 normalization (whitelist bypass prevention)
- ✅ Sync mechanism enhancement (divergence auto-repair)

**Total:** 14 security issues identified, 8 already in roadmap, 5 added, 1 deferred

**Status:** Ready to begin development
**Next Step:** Update TEMPLATE_module.sh with production header v2.0
