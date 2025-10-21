# Security Scan Quick Start Guide

**Date:** 2025-10-21
**Purpose:** Run security scans on lab servers before public release
**Safety:** Scripts ONLY run on lab servers, never on local/production

---

## What This Does

This security scanning system will:
1. ✅ Install security tools (ShellCheck, Gitleaks, Trivy) on lab servers only
2. ✅ Scan nftban code for vulnerabilities and issues
3. ✅ Compare results across all distributions (CentOS 9, Ubuntu 24.04, CentOS 10)
4. ✅ Generate comprehensive security report
5. ✅ Identify distro-specific issues

**IMPORTANT:** Tools are installed and scans run ONLY on lab servers. Your local environment is never modified.

---

## Prerequisites

- Access to all 3 lab servers (SSH keys configured)
- Lab servers: CentOS 9, Ubuntu 24.04, CentOS 10
- Internet connection on lab servers (to download security tools)

---

## Quick Start (3 commands)

### Option 1: Scan All Lab Servers (Recommended)

```bash
# From your local machine in the nftban repository:
cd /home/gituser/github/nftban

# Run comprehensive security scan on ALL lab servers
bash scripts/security_scan_all_labs.sh
```

**What happens:**
1. Prompts for confirmation (type `y`)
2. Copies scan script to each lab server
3. Installs security tools on each server
4. Runs comprehensive scans on each server
5. Downloads results to local `/tmp/nftban-security-scan-YYYYMMDD-HHMMSS/`
6. Generates cross-distro comparison report

**Duration:** ~15-20 minutes total (all servers in parallel)

### Option 2: Scan Single Lab Server

```bash
# CentOS 9
ssh root@lab.mywebhost.gr 'bash -s' < scripts/security_scan_lab.sh

# Ubuntu 24.04
ssh root@lab1.mywebhost.gr 'bash -s' < scripts/security_scan_lab.sh

# CentOS 10
ssh root@65.21.157.15 'bash -s' < scripts/security_scan_lab.sh
```

**Duration:** ~5-7 minutes per server

---

## What Gets Scanned

### 1. ShellCheck (Bash Static Analysis)
- Checks all `.sh` files in `/etc/nftban`
- Finds: quoting errors, logic bugs, unsafe practices
- **Severity:** Errors, Warnings, Notes
- **Output:** Detailed line-by-line analysis

### 2. Gitleaks (Secret Detection)
- Scans for leaked secrets, API keys, passwords
- Checks: code, comments, configuration files
- **Severity:** HIGH (any secret is critical)
- **Output:** JSON report with findings

### 3. Trivy (Vulnerability Scanner)
- Scans for known vulnerabilities and misconfigurations
- Checks: secrets, configs, dangerous patterns
- **Severity:** HIGH, CRITICAL
- **Output:** Table format with CVE IDs

### 4. File Permissions Audit
- Finds world-writable files
- Identifies SUID/SGID binaries
- Checks unusual ownership
- **Severity:** Context-dependent
- **Output:** File listing with permissions

### 5. Code Pattern Detection
- Searches for dangerous bash patterns
- Checks: `eval`, unquoted variables, missing strict mode
- Identifies temporary file vulnerabilities
- **Severity:** MEDIUM to HIGH
- **Output:** Pattern matches with line numbers

### 6. nftables Security Audit
- Reviews firewall ruleset structure
- Checks chain priorities
- Verifies whitelist/blacklist sets
- **Severity:** Context-dependent
- **Output:** Current ruleset analysis

---

## Reading the Results

### Directory Structure

After running `security_scan_all_labs.sh`, results are in `/tmp/nftban-security-scan-YYYYMMDD-HHMMSS/`:

```
/tmp/nftban-security-scan-20251021-100000/
├── SECURITY_REPORT_ALL_DISTROS.md  ← START HERE
├── CentOS_9/
│   ├── shellcheck-results.txt      ← Detailed ShellCheck findings
│   ├── shellcheck-summary.txt      ← Quick stats
│   ├── gitleaks-results.json       ← Secret detection results
│   ├── gitleaks-summary.txt
│   ├── trivy-results.txt           ← Vulnerability scan
│   ├── permissions-audit.txt       ← File permission issues
│   ├── code-patterns.txt           ← Dangerous code patterns
│   └── nftables-security.txt       ← Firewall ruleset analysis
├── Ubuntu_2404/
│   └── (same structure)
├── CentOS_10/
│   └── (same structure)
├── CentOS_9-console.log           ← Full console output
├── Ubuntu_2404-console.log
└── CentOS_10-console.log
```

### Priority Files to Review

1. **START:** `SECURITY_REPORT_ALL_DISTROS.md`
   - Cross-distro comparison
   - Summary of all findings
   - Priority recommendations

2. **HIGH:** `*/shellcheck-summary.txt`
   - Quick view of error counts
   - Identifies worst offenders

3. **HIGH:** `*/gitleaks-summary.txt`
   - Any secrets found? (should be 0)

4. **MEDIUM:** `*/shellcheck-results.txt`
   - Detailed line-by-line fixes needed

5. **MEDIUM:** `*/code-patterns.txt`
   - Security anti-patterns

---

## Understanding ShellCheck Results

ShellCheck reports 3 severity levels:

### Errors (MUST FIX)
```
In lib/example.sh line 42:
  rm -rf $DIR  # SC2086: Quote to prevent word splitting
         ^---^
```
**Fix:** `rm -rf "$DIR"`

### Warnings (SHOULD FIX)
```
In lib/example.sh line 100:
  [[ $? -eq 0 ]]  # SC2181: Check exit status directly
```
**Fix:** `if command; then ...`

### Notes (CONSIDER)
```
In lib/example.sh line 200:
  # SC2034: foo appears unused
  local foo="bar"
```
**Action:** Remove if truly unused, or add comment explaining why

---

## Common Findings & Fixes

### 1. Unquoted Variables

**Bad:**
```bash
rm -rf $DIR
```

**Good:**
```bash
rm -rf "$DIR"
```

**Why:** Without quotes, `$DIR` containing spaces causes word splitting

---

### 2. Missing Strict Mode

**Bad:**
```bash
#!/bin/bash
# Script continues silently on errors
```

**Good:**
```bash
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
```

**Why:** Catches errors immediately instead of cascading failures

---

### 3. Unsafe Temporary Files

**Bad:**
```bash
cat > /tmp/myfile.txt
```

**Good:**
```bash
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT
cat > "$tmpfile"
```

**Why:** Prevents race conditions and predictable temp file attacks

---

### 4. Command Injection

**Bad:**
```bash
eval "nft add element inet nftban blacklist { $IP }"
```

**Good:**
```bash
nft add element inet nftban blacklist "{ $IP }"
```

**Why:** `eval` allows arbitrary command execution if `$IP` is malicious

---

## Interpreting the Cross-Distro Report

The report compares results across all distributions:

### Consistent Results (Good)
```
| Distribution | Scripts | Errors | Warnings | Notes |
|--------------|---------|--------|----------|-------|
| CentOS 9     | 45      | 12     | 34       | 56    |
| Ubuntu 24.04 | 45      | 12     | 34       | 56    |
| CentOS 10    | 45      | 12     | 34       | 56    |
```
✅ Code behaves identically across all platforms

### Inconsistent Results (Investigate)
```
| Distribution | Scripts | Errors | Warnings | Notes |
|--------------|---------|--------|----------|-------|
| CentOS 9     | 45      | 12     | 34       | 56    |
| Ubuntu 24.04 | 45      | 18     | 42       | 71    |  ← Different!
| CentOS 10    | 45      | 12     | 34       | 56    |
```
⚠️ Ubuntu has more issues - likely distro-specific code paths or bash version differences

**Action:** Review Ubuntu-specific findings for:
- Different file paths (`/var/log/auth.log` vs `/var/log/secure`)
- Different package names
- Bash version differences
- Distribution-specific edge cases

---

## Expected Scan Times

| Operation | Duration | Notes |
|-----------|----------|-------|
| Tool installation | 2-3 min | Per server, first run only |
| ShellCheck scan | 1-2 min | ~45 scripts |
| Gitleaks scan | 30-60 sec | No git history in /etc/nftban |
| Trivy scan | 1-2 min | Downloads vuln DB first run |
| Permission audit | 10 sec | Simple file listing |
| Code patterns | 30 sec | Grep-based searches |
| nftables audit | 10 sec | Rule dump |
| **Single server total** | **5-7 min** | |
| **All servers (parallel)** | **15-20 min** | Includes download time |

---

## What to Do with Results

### Phase 1: Triage (30 minutes)

1. **Review:** `SECURITY_REPORT_ALL_DISTROS.md`
2. **Check:** Any secrets found? (Gitleaks) → Delete immediately
3. **Count:** ShellCheck errors across all distros
4. **Identify:** Top 5 most common issues
5. **Prioritize:** HIGH severity findings first

### Phase 2: Fix High Priority (4-6 hours)

Focus on:
- ❌ **Errors:** Must fix before public release
- ⚠️ **Warnings in critical modules:** Core, nftables, whitelist, ban
- 🔐 **Security patterns:** eval, unquoted variables in nft commands
- 🚨 **Secrets:** Any API keys, passwords, tokens

### Phase 3: Fix Medium Priority (2-4 hours)

Address:
- ⚠️ **Warnings in other modules:** Feeds, GeoIP, stats
- 📝 **Missing strict mode:** Add to all scripts
- 🗑️ **Unused variables:** Clean up or document
- 🔧 **Code style:** Consistent quoting, formatting

### Phase 4: Re-scan (20 minutes)

After fixes:
```bash
bash scripts/security_scan_all_labs.sh
```

Compare before/after:
- Error count should be 0 or near-0
- Warnings significantly reduced
- No new issues introduced

---

## Success Criteria

Before considering nftban ready for OpenSSF Scorecard or public release:

### Critical (Must Have)
- ✅ ShellCheck errors: 0
- ✅ Gitleaks secrets: 0
- ✅ Trivy HIGH/CRITICAL: 0
- ✅ No world-writable files in /etc/nftban
- ✅ All scripts have strict mode (`set -Eeuo pipefail`)
- ✅ Consistent results across all distros

### Important (Should Have)
- ✅ ShellCheck warnings: < 20
- ✅ All nft commands use quoted variables
- ✅ No use of `eval` with user data
- ✅ All temp files use `mktemp`
- ✅ Permission audit shows no SUID/SGID
- ✅ Code patterns show no obvious security issues

### Nice to Have (Could Have)
- ✅ ShellCheck notes: < 50
- ✅ Code formatted with shfmt
- ✅ All functions have header comments
- ✅ No unused variables

---

## Troubleshooting

### "ShellCheck not found after installation"

**Fix:**
```bash
# Manually install on lab server
ssh root@lab.mywebhost.gr
dnf install -y ShellCheck
shellcheck --version
```

### "Gitleaks download failed"

**Fix:**
```bash
# Check internet connectivity on lab server
ssh root@lab.mywebhost.gr
ping -c3 github.com

# Manual install
wget https://github.com/gitleaks/gitleaks/releases/download/v8.18.4/gitleaks_8.18.4_linux_x64.tar.gz
tar -xzf gitleaks*.tar.gz
mv gitleaks /usr/local/bin/
```

### "Permission denied on /etc/nftban"

**Cause:** Not running as root on lab server

**Fix:**
```bash
# Ensure you're SSH'd as root
ssh root@lab.mywebhost.gr
# Or use sudo
sudo bash /tmp/security_scan_lab.sh
```

### "Results archive not found"

**Cause:** Scan may have failed or not completed

**Fix:**
```bash
# Check what was created
ssh root@lab.mywebhost.gr "ls -lt /var/log/nftban/security-scan-* 2>/dev/null"
ssh root@lab.mywebhost.gr "ls -lt /tmp/security-scan-*.tar.gz 2>/dev/null"

# Re-run scan manually
ssh root@lab.mywebhost.gr
bash /tmp/security_scan_lab.sh
```

---

## Advanced Usage

### Scan Only Specific Tools

Edit `security_scan_lab.sh` and comment out unwanted scans:

```bash
# In main() function:
scan_shellcheck
# scan_gitleaks      # Skip this
scan_trivy
# scan_permissions   # Skip this
scan_code_patterns
scan_nftables_security
```

### Change Scan Directories

By default scans `/etc/nftban`. To scan development copy:

```bash
# Edit scripts/security_scan_lab.sh
# Change all instances of /etc/nftban to:
/home/gituser/nftban-dev
```

### Save Historical Results

Keep results over time to track progress:

```bash
# Run scan
bash scripts/security_scan_all_labs.sh

# Copy results with date
cp -r /tmp/nftban-security-scan-* ~/security-scans/scan-$(date +%Y%m%d)

# Compare over time
diff ~/security-scans/scan-20251020/SECURITY_REPORT_ALL_DISTROS.md \
     ~/security-scans/scan-20251021/SECURITY_REPORT_ALL_DISTROS.md
```

---

## Next Steps After Scanning

1. **Review Results** (30 min)
   - Read `SECURITY_REPORT_ALL_DISTROS.md`
   - Identify top issues

2. **Create Fix Plan** (1 hour)
   - Group similar issues
   - Prioritize by severity and module
   - Estimate fix time

3. **Fix Issues** (varies)
   - Work through priority list
   - Test after each fix
   - Commit frequently

4. **Re-scan** (20 min)
   - Verify fixes worked
   - Ensure no regressions
   - Compare before/after

5. **Document** (30 min)
   - Update `docs/SECURITY_ASSESSMENT_2025-10-21.md`
   - Note remaining issues
   - Plan for next release

6. **Consider OpenSSF** (when ready)
   - Review `docs/SECURITY_ASSESSMENT_2025-10-21.md`
   - Ensure score target met (7+/10)
   - Run local OpenSSF Scorecard
   - Decide on public release

---

## Security Scan Automation

For ongoing security monitoring, consider adding to CI/CD:

```yaml
# .github/workflows/security.yml (future)
name: Security Scan
on: [push, pull_request]
jobs:
  shellcheck:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ludeeus/action-shellcheck@master
        with:
          scandir: './lib ./bin'
```

**Note:** This is for future implementation after initial cleanup is complete.

---

## Contact & Support

For questions about security scanning:
- Review: `docs/SECURITY_ASSESSMENT_2025-10-21.md`
- Contact: contact@itcms.gr
- Website: https://itcms.gr

---

**Remember:** These scans are for INTERNAL REVIEW only. Results are private until you decide to make repository public and enable OpenSSF Scorecard.
