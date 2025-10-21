# NFTBan Smoke Test & Diagnostics Module

**File:** `lib/nftban_smoketest_module.sh`
**Version:** 1.0.0
**Author:** ITCMS Team (Antonios Voulvoulis)
**Purpose:** Built-in smoke testing and diagnostics for NFTBan validation

---

## Overview

The Smoke Test & Diagnostics Module provides comprehensive automated testing and system diagnostics capabilities for NFTBan. It performs systematic validation of installation integrity, configuration correctness, module availability, system dependencies, and operational functionality.

This module serves multiple purposes: installation verification after setup, troubleshooting existing installations, pre-upgrade validation, and support bundle generation. It implements a categorized testing framework with 10 distinct test categories covering everything from basic installation structure to network connectivity.

The module features color-coded test results (PASS/FAIL/SKIP/WARN), detailed logging, progress counters, and comprehensive summary reports. It's accessible via the `nftban test` CLI command and is essential for maintaining system health and diagnosing issues.

---

## Key Functions

### Public Functions (Exported)

#### Main Testing Functions

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `nftban_smoketest_run()` | Run smoke tests | `$1` - mode (quick/full/category), `$2` - category name (optional) | 0 if all pass, 1 if any fail |
| `nftban_diagnostics_collect()` | Collect diagnostics report | `$1` - output file path (optional) | 0 on success |
| `nftban_smoketest_show_help()` | Show test command help | None | 0 on success |

#### Test Category Functions

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `smoketest_installation()` | Test installation structure | None | Category test results |
| `smoketest_nftables_structure()` | Test nftables tables/sets | None | Category test results |
| `smoketest_core_modules()` | Test core module files | None | Category test results |
| `smoketest_feature_modules()` | Test feature module files | None | Category test results |
| `smoketest_dependencies()` | Test system dependencies | None | Category test results |
| `smoketest_cli_commands()` | Test CLI command execution | None | Category test results |
| `smoketest_safety_mechanisms()` | Test safety features | None | Category test results |
| `smoketest_configuration()` | Test configuration files | None | Category test results |
| `smoketest_logging()` | Test logging infrastructure | None | Category test results |
| `smoketest_connectivity()` | Test network connectivity | None | Category test results |

### Internal Functions (Private)

| Function | Purpose | Notes |
|----------|---------|-------|
| `smoketest_reset_counters()` | Reset test counters | Called at start of test run |
| `smoketest_log()` | Log test events | Writes to smoketest.log |
| `smoketest_start()` | Begin individual test | Displays test description |
| `smoketest_pass()` | Mark test as passed | Increments PASSED counter |
| `smoketest_fail()` | Mark test as failed | Increments FAILED counter |
| `smoketest_skip()` | Mark test as skipped | Increments SKIPPED counter |
| `smoketest_warn()` | Mark test with warning | Increments WARNINGS counter |
| `smoketest_category()` | Display category header | Visual separator |
| `smoketest_summary()` | Show final test summary | Returns exit code based on failures |

---

## Configuration Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SMOKETEST_LOG` | `/var/log/nftban/smoketest.log` | Smoke test results log |
| `DIAGNOSTICS_LOG` | `/var/log/nftban/diagnostics.log` | Diagnostics output log |
| `SMOKETEST_TOTAL` | `0` | Total tests run counter |
| `SMOKETEST_PASSED` | `0` | Passed tests counter |
| `SMOKETEST_FAILED` | `0` | Failed tests counter |
| `SMOKETEST_SKIPPED` | `0` | Skipped tests counter |
| `SMOKETEST_WARNINGS` | `0` | Warning tests counter |

---

## Dependencies

**Required Modules:**
- `nftban_core.sh` - Core logging and color codes

**External Commands:**
- `nft` - nftables validation
- `systemctl` - Service status checks
- `curl` - Network connectivity tests
- `nslookup` or `host` - DNS resolution tests
- `du` - Disk usage reporting
- `find`, `grep`, `cut`, `sed`, `tail` - Text processing

**Optional Commands:**
- `fail2ban-client` - Fail2Ban status (if integrated)
- `ipcalc` or `sipcalc` - IP calculation validation (v0.9.0+)

---

## Usage Examples

### Example 1: Quick Health Check
```bash
# Run essential tests only (~10 seconds)
nftban test quick

# Expected output:
# ╔═════════════════════════════════════════════════════╗
# ║      nftban Smoke Test & Diagnostics                ║
# ╚═════════════════════════════════════════════════════╝
#
# Mode: quick
# Log:  /var/log/nftban/smoketest.log
#
# ═══════════════════════════════════════════════════════
#   CATEGORY: Installation
# ═══════════════════════════════════════════════════════
# [001] Testing: Base directory exists ... ✓ PASS
# [002] Testing: Config directory exists ... ✓ PASS
# [003] Testing: Lib directory exists ... ✓ PASS
# [004] Testing: Scripts directory exists ... ✓ PASS
# [005] Testing: Version file exists ... ✓ PASS
#       → Version: 0.9.0
# [006] Testing: CLI binary exists ... ✓ PASS
#
# ═══════════════════════════════════════════════════════
#   CATEGORY: nftables Structure
# ═══════════════════════════════════════════════════════
# [007] Testing: IPv4 table exists (ip nftban_v4) ... ✓ PASS
# [008] Testing: IPv6 table exists (ip6 nftban_v6) ... ✓ PASS
# [009] Testing: IPv4 set: whitelist ... ✓ PASS
# [010] Testing: IPv4 set: temp_ban ... ✓ PASS
# ...
#
# ═══════════════════════════════════════════════════════
#   TEST SUMMARY
# ═══════════════════════════════════════════════════════
# Total tests:    25
# Passed:         25
# Failed:          0
# Skipped:         0
# Warnings:        0
# ═══════════════════════════════════════════════════════
#
# ✓ ALL TESTS PASSED
```

### Example 2: Comprehensive Test Suite
```bash
# Run all test categories (~30 seconds)
nftban test full

# Tests all categories:
# - Installation (6 tests)
# - nftables Structure (11 tests)
# - Core Modules (6 tests)
# - Feature Modules (6 tests)
# - System Dependencies (10 tests)
# - CLI Commands (10 tests)
# - Safety Mechanisms (4 tests)
# - Configuration Files (4 tests)
# - Logging (4 tests)
# - Network Connectivity (3 tests)
#
# Total: ~64 tests
```

### Example 3: Test Specific Category
```bash
# Test only nftables structure
nftban test category nftables

# Expected output:
# ═══════════════════════════════════════════════════════
#   CATEGORY: nftables Structure
# ═══════════════════════════════════════════════════════
# [001] Testing: IPv4 table exists (ip nftban_v4) ... ✓ PASS
# [002] Testing: IPv6 table exists (ip6 nftban_v6) ... ✓ PASS
# [003] Testing: IPv4 set: whitelist ... ✓ PASS
# [004] Testing: IPv4 set: temp_ban ... ✓ PASS
# [005] Testing: IPv4 set: user_blacklist ... ✓ PASS
# [006] Testing: IPv4 set: system_blacklist ... ✓ PASS
# [007] Testing: IPv4 set: feeds ... ✓ PASS
# [008] Testing: IPv6 set: whitelist ... ✓ PASS
# [009] Testing: IPv6 set: temp_ban ... ✓ PASS
# [010] Testing: IPv6 set: user_blacklist ... ✓ PASS
# [011] Testing: IPv6 set: system_blacklist ... ✓ PASS
# [012] Testing: IPv6 set: feeds ... ✓ PASS
# [013] Testing: Old inet table removed ... ✓ PASS
```

### Example 4: Test After Installation
```bash
# Verify fresh installation
sudo nftban test full

# Check for any failures
if [ $? -eq 0 ]; then
    echo "Installation verified successfully"
else
    echo "Installation has issues - review logs"
    tail -50 /var/log/nftban/smoketest.log
fi
```

### Example 5: Pre-Upgrade Validation
```bash
# Before upgrading NFTBan
echo "Running pre-upgrade validation..."
nftban test full > /tmp/pre-upgrade-test.txt 2>&1

# Perform upgrade
# ...

# Post-upgrade validation
echo "Running post-upgrade validation..."
nftban test full > /tmp/post-upgrade-test.txt 2>&1

# Compare results
diff /tmp/pre-upgrade-test.txt /tmp/post-upgrade-test.txt
```

### Example 6: Generate Diagnostics Report
```bash
# Collect full diagnostics for support
nftban test diagnostics

# Expected output:
# Collecting diagnostics...
# 
# Diagnostics saved to: /tmp/nftban_diagnostics_20251020_143000.txt
#
# You can share this file for support at: https://github.com/itcmsgr/nftban/issues

# View the report
cat /tmp/nftban_diagnostics_20251020_143000.txt
```

### Example 7: Custom Diagnostics Location
```bash
# Save diagnostics to specific location
nftban test diagnostics /root/nftban-diagnostics.txt

# Or use custom filename with timestamp
nftban test diagnostics ~/nftban-diag-$(date +%Y%m%d).txt
```

### Example 8: Test Specific Categories
```bash
# Test installation structure only
nftban test category installation

# Test CLI commands only
nftban test category cli

# Test safety mechanisms only
nftban test category safety

# Test network connectivity only
nftban test category network

# Available categories:
# - installation
# - nftables
# - modules
# - deps
# - cli
# - safety
# - config
# - logging
# - network
```

### Example 9: Automated Testing in Scripts
```bash
#!/bin/bash
# Daily health check script

echo "Running NFTBan health check..."

if nftban test quick &>/dev/null; then
    echo "✓ Health check passed"
    exit 0
else
    echo "✗ Health check failed"
    echo "Generating diagnostics..."
    nftban test diagnostics /var/log/nftban/health-check-failed-$(date +%Y%m%d).txt
    
    # Send alert
    echo "NFTBan health check failed on $(hostname)" | \
        mail -s "NFTBan Health Check Alert" admin@example.com
    
    exit 1
fi
```

### Example 10: Continuous Integration Testing
```bash
#!/bin/bash
# CI/CD test script

set -e

echo "=== NFTBan CI Test Suite ==="

# Quick test
echo "1. Running quick test..."
nftban test quick || exit 1

# Full test
echo "2. Running full test..."
nftban test full || exit 1

# Specific critical categories
echo "3. Testing critical components..."
nftban test category nftables || exit 1
nftban test category safety || exit 1

echo "=== All CI tests passed ==="
```

---

## Test Categories Explained

### 1. Installation Tests

**What it checks:**
- Base directory structure exists (`/etc/nftban`)
- Configuration directory exists
- Library directory exists
- Scripts directory exists
- Version file present and readable
- CLI binary available in PATH

**Why it matters:**
Ensures basic installation integrity. If these fail, NFTBan is not properly installed.

### 2. nftables Structure Tests

**What it checks:**
- IPv4 table exists (`ip nftban_v4`)
- IPv6 table exists (`ip6 nftban_v6`)
- Required sets exist in both tables:
  - `whitelist`
  - `temp_ban`
  - `user_blacklist`
  - `system_blacklist`
  - `feeds`
- Old inet table removed (migration check)
- Backward compatibility with v0.8.5 structure

**Why it matters:**
nftables is the core firewall engine. If sets are missing, ban/whitelist operations will fail.

### 3. Core Modules Tests

**What it checks:**
- Essential module files exist:
  - `nftban_core.sh`
  - `nftban_nftables_module.sh`
  - `nftban_whitelist_module.sh`
  - `nftban_blacklist_module.sh`
  - `nftban_safety_module.sh`
- Core functions are loaded and available

**Why it matters:**
Core modules are required for all operations. Missing modules indicate incomplete installation.

### 4. Feature Modules Tests

**What it checks:**
- Optional feature modules exist:
  - `nftban_ddos_module.sh`
  - `nftban_portscan_module.sh`
  - `nftban_feeds_module.sh`
  - `nftban_fail2ban_module.sh`
- Version-specific modules (v0.9.0+):
  - `nftban_ipcalc_module.sh`
  - `nftban_sync_module.sh`

**Why it matters:**
Feature modules are optional but provide important functionality. Warnings indicate incomplete feature set.

### 5. System Dependencies Tests

**What it checks:**
- Required commands: `nft`, `systemctl`, `ip`, `awk`, `sed`, `grep`
- Optional commands: `curl`, `fail2ban-client`, `ipcalc`, `sipcalc`

**Why it matters:**
Missing dependencies will cause runtime failures. Required commands must be present.

### 6. CLI Commands Tests

**What it checks:**
- Basic commands work: `help`, `status`
- List commands work: `whitelist list`, `blacklist list`
- Feature commands work: `ddos status`, `portscan status`
- Version-specific commands: `sync check` (v0.9.0+)
- Self-test command: `test quick`

**Why it matters:**
Validates CLI interface functionality. Failures indicate broken command routing or module issues.

### 7. Safety Mechanisms Tests

**What it checks:**
- Safety module loaded
- Current public IP detection
- Current IP is whitelisted (lockout prevention)
- Backup directory exists with backups

**Why it matters:**
Safety mechanisms prevent accidental lockout. Critical for production systems.

### 8. Configuration Files Tests

**What it checks:**
- Main config file exists
- Feature config files exist (DDoS, portscan)
- User override files (.conf.local) detected

**Why it matters:**
Configuration files store critical settings. Missing files may cause defaults or errors.

### 9. Logging Tests

**What it checks:**
- Log directory exists (`/var/log/nftban`)
- Log files exist and accessible
- Log file sizes reported

**Why it matters:**
Logs are essential for troubleshooting and auditing. Missing logs indicate permission or setup issues.

### 10. Network Connectivity Tests

**What it checks:**
- DNS resolution works
- External internet accessible
- GitHub accessible (for updates)

**Why it matters:**
Network connectivity required for feed updates and external IP detection. Failures may indicate firewall blocking.

---

## Test Result Indicators

### ✓ PASS (Green)
- Test completed successfully
- Expected condition met
- No issues detected

### ✗ FAIL (Red)
- Test failed
- Critical issue detected
- Requires immediate attention

### ⊘ SKIP (Yellow)
- Test skipped (not applicable)
- Optional feature not installed
- Conditional test not met

### ⚠ WARN (Yellow)
- Test passed with warning
- Non-critical issue detected
- May need attention

---

## Diagnostics Report Contents

The diagnostics report includes:

1. **Version Information:**
   - NFTBan version
   - Kernel version
   - OS distribution
   - nftables version

2. **nftables Ruleset:**
   - Complete ruleset dump
   - All tables and chains
   - All rules

3. **nftables Sets:**
   - IPv4 set contents
   - IPv6 set contents
   - Element counts

4. **Configuration Files:**
   - File listing
   - File sizes
   - Permissions

5. **Recent Logs:**
   - Last 50 log entries
   - Error messages
   - Warning messages

6. **Fail2Ban Status:**
   - Service status
   - Active jails
   - Ban statistics

7. **System Status:**
   - nftables service status
   - Fail2Ban service status
   - Systemd unit states

8. **Disk Usage:**
   - Installation size
   - Log directory size
   - Backup directory size

---

## File Operations

**Writes to:**
- `/var/log/nftban/smoketest.log` - Test results log
- `/var/log/nftban/diagnostics.log` - Diagnostics log
- `/tmp/nftban_diagnostics_*.txt` - Diagnostics reports (default location)

**Reads from:**
- All NFTBan configuration files
- All NFTBan module files
- System files: `/etc/os-release`, `/proc/version`
- Log files: `/var/log/nftban/*.log`

**Executes:**
- `nft` commands (read-only)
- `nftban` CLI commands
- System status commands (`systemctl`, `fail2ban-client`)

---

## Security Considerations

### Read-Only Operations

- All smoke tests are **read-only**
- No modifications to configuration
- No changes to nftables rules
- Safe to run in production

### Privilege Requirements

- **Requires root** to:
  - Read nftables ruleset
  - Access system service status
  - Read protected log files
  - Execute privileged commands

### Information Disclosure

- Diagnostics report contains sensitive information:
  - Complete nftables ruleset
  - IP addresses (whitelisted/blacklisted)
  - System configuration
- **Review before sharing** with third parties
- Redact sensitive IPs if needed

### Network Testing

- Connectivity tests make external connections:
  - DNS queries
  - HTTP requests to google.com, cloudflare.com, github.com
- May trigger security alerts or fail in air-gapped environments

---

## Error Handling

**Common Issues:**

- `ERROR: nftables table not found` - NFTBan not initialized, run `nftban init`
- `ERROR: Module not found` - Incomplete installation, reinstall NFTBan
- `ERROR: Command not found: nft` - nftables not installed
- `WARNING: Cannot detect current IP` - No internet connectivity or curl missing
- `WARNING: Current IP not whitelisted` - Lockout risk, whitelist your IP

**Troubleshooting Failed Tests:**

```bash
# 1. Review detailed log
cat /var/log/nftban/smoketest.log

# 2. Run specific category
nftban test category [category]

# 3. Generate diagnostics
nftban test diagnostics

# 4. Check installation
nftban version
ls -la /etc/nftban

# 5. Verify nftables
nft list ruleset | grep nftban
```

---

## Integration Points

**Called by:**
- `nftban_main_cli.sh` - CLI `test` command
- Installation scripts - Post-install verification
- Upgrade scripts - Pre/post-upgrade validation
- Monitoring scripts - Health checks

**Calls:**
- All `nftban_log_*` functions from `nftban_core.sh`
- `nftban` CLI commands (via subprocess)
- `nft` command for ruleset inspection
- `systemctl` for service status

---

## Best Practices

### Post-Installation

```bash
# Always run after installing
sudo nftban test full

# Save results
sudo nftban test full > /var/log/nftban/installation-test.log 2>&1
```

### Regular Health Checks

```bash
# Weekly cron job
cat > /etc/cron.weekly/nftban-health << 'EOF'
#!/bin/bash
nftban test quick || \
    nftban test diagnostics /var/log/nftban/health-check-$(date +%Y%m%d).txt
EOF
chmod +x /etc/cron.weekly/nftban-health
```

### Before/After Upgrades

```bash
# Pre-upgrade baseline
nftban test full > /tmp/pre-upgrade.log

# Perform upgrade
# ...

# Post-upgrade validation
nftban test full > /tmp/post-upgrade.log

# Compare
diff /tmp/pre-upgrade.log /tmp/post-upgrade.log
```

### Troubleshooting Workflow

```bash
# 1. Quick check
nftban test quick

# 2. If failures, run full test
nftban test full

# 3. Focus on failing category
nftban test category [category]

# 4. Generate diagnostics
nftban test diagnostics

# 5. Review logs
tail -100 /var/log/nftban/nftban.log
```

---

## Performance

- **Quick Test:** ~5-10 seconds (25 tests)
- **Full Test:** ~20-30 seconds (64+ tests)
- **Category Test:** ~2-5 seconds (varies by category)
- **Diagnostics:** ~5-10 seconds (includes ruleset dump)

**Resource Usage:**
- Minimal CPU impact
- Minimal memory (~10 MB)
- No disk I/O except logging
- Network tests: ~1 MB bandwidth

---

## Extending the Test Suite

### Adding Custom Tests

```bash
# Example: Add custom test category
smoketest_custom_app() {
    smoketest_category "Custom Application"
    
    smoketest_start "Custom app service running"
    if systemctl is-active my-app &>/dev/null; then
        smoketest_pass
    else
        smoketest_fail "my-app service not running"
    fi
    
    smoketest_start "Custom app responding"
    if curl -sf http://localhost:8080/health &>/dev/null; then
        smoketest_pass
    else
        smoketest_fail "my-app health check failed"
    fi
}

# Call in full test mode
# Add to nftban_smoketest_run() function
```

---

## Change Log

### Version 1.0.0 (2025-10-20)
- Initial release
- 10 test categories
- 64+ individual tests
- Color-coded results
- Comprehensive diagnostics collection
- Support for v0.8.5 and v0.9.0+ structure
- Backward compatibility checking
- Network connectivity tests
- Safety mechanism validation

---

## See Also

**Related Modules:**
- `nftban_core.sh` - Core functionality being tested
- `nftban_nftables_module.sh` - nftables structure being validated
- `nftban_safety_module.sh` - Safety mechanisms being tested

**Related Documentation:**
- `INSTALLATION.md` - Installation guide
- `TROUBLESHOOTING.md` - Troubleshooting procedures
- `UPGRADE_GUIDE.md` - Upgrade procedures

**Log Files:**
- `/var/log/nftban/smoketest.log` - Test results
- `/var/log/nftban/diagnostics.log` - Diagnostics output
- `/var/log/nftban/nftban.log` - Main operational log

**Support:**
- GitHub Issues: https://github.com/itcmsgr/nftban/issues
- Include diagnostics report when requesting support
