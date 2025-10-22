# NFTBan Sync Module Documentation

**Module:** `nftban_sync_module.sh`
**Version:** 0.9.3-dev
**Location:** `/usr/local/lib/nftban/nftban_sync_module.sh`
**Purpose:** Ensures file-based IP lists and nftables sets stay synchronized with drift detection and automatic repair

---

## Overview

### Purpose

The Sync Module detects and repairs synchronization drift between file-based IP lists (whitelist/blacklist configuration files) and nftables firewall sets. It provides health checking, verification, and automatic repair capabilities to maintain system consistency.

### Key Features

- **Drift Detection**: Compares file counts vs. nftables set counts (IPv4/IPv6 separately)
- **Automatic Repair**: One-command sync repair for whitelist and blacklist
- **Health Scoring**: 0-100 health score with issue reporting
- **Split Table Support**: Handles IPv4 (`nftban_v4`) and IPv6 (`nftban_v6`) separately
- **Auto-Sync Hooks**: Called automatically after file modifications
- **Verification Reports**: Detailed sync status with file/nftables comparison

### Dependencies

**Required Modules:**
- `nftban_core.sh` - Core functions, IP version detection
- `nftban_whitelist_module.sh` - Whitelist sync function
- `nftban_blacklist_module.sh` - Blacklist sync function
- `nftban_nftables_module.sh` - nftables table checking

---

## API Reference

### Verification Functions

#### `nftban_sync_verify()`

Comprehensive sync verification with visual report.

**Usage:**
```bash
nftban_sync_verify
```

**Checks Performed:**
1. Whitelist sync (files vs. nftables) - IPv4 and IPv6
2. Blacklist sync (files vs. nftables) - IPv4 and IPv6
3. nftables sets existence (whitelist, temp_ban, user_blacklist, system_blacklist, feeds)

**Example Output:**
```
═══════════════════════════════════════════════════════
  File/nftables Synchronization Status
═══════════════════════════════════════════════════════

Checking whitelist sync...
  Files:    IPv4:   5  IPv6:   1
  nftables: IPv4:   5  IPv6:   1
  ✓ SYNCHRONIZED

Checking blacklist sync...
  Files:    IPv4:   3  IPv6:   0
  nftables: IPv4:   2  IPv6:   0
  ✗ OUT OF SYNC

Checking nftables sets...
  ✓ ALL SETS PRESENT

1 issue(s) found
Run: sudo nftban sync repair
```

**Exit Codes:**
- `0` - All synchronized
- `1` - Drift detected or sets missing

**Source:** `nftban_sync_module.sh:156-238`

---

#### `nftban_sync_check_whitelist_drift()`

Checks whitelist synchronization status.

**Usage:**
```bash
result=$(nftban_sync_check_whitelist_drift)
echo "$result"
```

**Output Format:**
```
WHITELIST|<file_v4>|<nft_v4>|<file_v6>|<nft_v6>|<drift_bool>
```

**Example:**
```bash
result=$(nftban_sync_check_whitelist_drift)
# Output: WHITELIST|5|5|1|1|false

IFS='|' read -r name file_v4 nft_v4 file_v6 nft_v6 drift <<< "$result"
echo "Files: IPv4=$file_v4 IPv6=$file_v6"
echo "nftables: IPv4=$nft_v4 IPv6=$nft_v6"
echo "Drift: $drift"
```

**Files Checked:**
- `/etc/nftban/whitelist-system.conf`
- `/etc/nftban/whitelist-user.conf`
- `/etc/nftban/whitelist-cloudflare.conf`

**nftables Sets Checked:**
- `ip nftban_v4 whitelist`
- `ip6 nftban_v6 whitelist`

**Source:** `nftban_sync_module.sh:46-97`

---

#### `nftban_sync_check_blacklist_drift()`

Checks blacklist synchronization status.

**Usage:**
```bash
result=$(nftban_sync_check_blacklist_drift)
```

**Output Format:**
```
BLACKLIST|<file_v4>|<nft_v4>|<file_v6>|<nft_v6>|<drift_bool>
```

**Files Checked:**
- `/etc/nftban/blacklist-persistent.conf`
- `/etc/nftban/blacklist-user.conf`

**nftables Sets Checked:**
- `ip nftban_v4 user_blacklist`
- `ip6 nftban_v6 user_blacklist`

**Source:** `nftban_sync_module.sh:100-150`

---

### Repair Functions

#### `nftban_sync_repair()`

Automatic synchronization repair.

**Usage:**
```bash
nftban_sync_repair
```

**Behavior:**
1. Detects whitelist drift → calls `nftban_whitelist_sync_to_nftables()`
2. Detects blacklist drift → calls `nftban_blacklist_sync_to_nftables()`
3. Rebuilds search index after repairs
4. Reports summary

**Example Output:**
```
[INFO] Starting synchronization repair...
[WARN] Whitelist out of sync (files: 5v4/1v6, nft: 4v4/1v6)
[SUCCESS] Repaired whitelist synchronization
[INFO] Blacklist already synchronized
[INFO] Rebuilding search index...

✓ Repair complete: 1 item(s) synchronized
```

**Exit Codes:**
- `0` - All repairs successful
- `1` - One or more repairs failed

**Source:** `nftban_sync_module.sh:244-303`

---

#### `nftban_sync_auto([sync_type])`

Automatic sync after file modifications (hook function).

**Parameters:**
- `sync_type` (optional) - "whitelist", "blacklist", or "all" (default: "all")

**Usage:**
```bash
# Sync everything
nftban_sync_auto

# Sync only whitelist
nftban_sync_auto whitelist

# Sync only blacklist
nftban_sync_auto blacklist
```

**Example Integration:**
```bash
# In whitelist module after file modification
nftban_whitelist_add_ip() {
    # ... add IP to file ...

    # Auto-sync to nftables
    nftban_sync_auto whitelist
}
```

**Source:** `nftban_sync_module.sh:309-331`

---

### Health Monitoring

#### `nftban_sync_health()`

System health check with scoring.

**Usage:**
```bash
nftban_sync_health
```

**Health Score Calculation:**
- Start: 100 points
- IPv4 table missing: -30 points
- IPv6 table missing: -30 points
- Whitelist drift: -20 points
- Blacklist drift: -20 points

**Output Format:**
```
HEALTH_SCORE=<0-100>
ISSUES=<issue1 issue2 ...>
```

**Example:**
```bash
nftban_sync_health

# Output (healthy):
HEALTH_SCORE=100

# Output (issues):
HEALTH_SCORE=60
ISSUES=Whitelist out of sync Blacklist out of sync
```

**Exit Codes:**
- `0` - No issues (health = 100)
- `1` - Issues detected (health < 100)

**Use Cases:**
- Monitoring dashboards
- Nagios/Icinga checks
- Automated health reports
- Pre-deployment verification

**Source:** `nftban_sync_module.sh:337-380`

---

## Integration Guide

### CLI Integration

**Command Examples:**
```bash
# Verify sync status
nftban sync verify

# Repair sync issues
nftban sync repair

# Health check
nftban sync health
```

**CLI Implementation:**
```bash
case "$1" in
    sync)
        case "$2" in
            verify)
                nftban_sync_verify
                ;;
            repair)
                nftban_sync_repair
                ;;
            health)
                nftban_sync_health
                ;;
        esac
        ;;
esac
```

---

### Module Integration

**Auto-Sync After File Modifications:**

```bash
# In whitelist module
nftban_whitelist_add_ip() {
    local ip="$1"

    # Add to file
    echo "$ip  # Added $(date)" >> "$NFTBAN_WHITELIST_USER"

    # Auto-sync to nftables
    nftban_sync_auto whitelist
}

# In blacklist module
nftban_blacklist_add_permanent() {
    local ip="$1"

    # Add to file
    echo "$ip  # Permanent" >> "$NFTBAN_BLACKLIST_PERSISTENT"

    # Auto-sync to nftables
    nftban_sync_auto blacklist
}
```

---

### Monitoring Integration

**Nagios/Icinga Check:**

```bash
#!/bin/bash
# /usr/lib/nagios/plugins/check_nftban_sync

source /usr/local/lib/nftban/nftban_sync_module.sh

result=$(nftban_sync_health)
score=$(echo "$result" | grep "HEALTH_SCORE" | cut -d'=' -f2)

if [[ $score -eq 100 ]]; then
    echo "OK - NFTBan sync healthy (score: $score)"
    exit 0
elif [[ $score -ge 80 ]]; then
    echo "WARNING - NFTBan sync issues (score: $score)"
    exit 1
else
    echo "CRITICAL - NFTBan sync problems (score: $score)"
    exit 2
fi
```

---

## Configuration

### File Locations

```bash
# Log file
NFTBAN_SYNC_LOG="/var/log/nftban/sync.log"

# Sync report
NFTBAN_SYNC_REPORT="/var/nftban/sync-report.txt"
```

### nftables Tables/Sets

**IPv4 Table (`nftban_v4`):**
- `whitelist` - Whitelisted IPs
- `temp_ban` - Temporary bans (with timeout)
- `user_blacklist` - Permanent blacklist
- `system_blacklist` - System blacklist
- `feeds` - Threat feeds

**IPv6 Table (`nftban_v6`):**
- Same sets as IPv4

---

## Troubleshooting

### Common Issues

#### Issue 1: Persistent Drift After Repair

**Symptoms:**
```bash
nftban sync repair
# Reports success

nftban sync verify
# Still shows drift
```

**Causes:**
1. File contains invalid IPs (skipped during sync)
2. nftables set has extra IPs not in files
3. Manual nft commands bypassed file system

**Solutions:**
```bash
# Check for invalid IPs in files
grep -vE '^[[:space:]]*#' /etc/nftban/whitelist-*.conf | \
    while read ip rest; do
        nftban_validate_ip "$ip" || echo "Invalid: $ip"
    done

# Full rebuild from files
nft flush set ip nftban_v4 whitelist
nft flush set ip6 nftban_v6 whitelist
nftban_whitelist_sync_to_nftables

# Check for orphaned IPs in nftables
nft list set ip nftban_v4 whitelist
```

---

#### Issue 2: Health Score Stuck Below 100

**Symptoms:**
```bash
nftban_sync_health
# HEALTH_SCORE=60
# ISSUES=Whitelist out of sync
```

**Solutions:**
```bash
# Run full repair
nftban_sync_repair

# Verify
nftban_sync_verify

# If still failing, check table existence
nft list tables

# Reinitialize if needed
nftban init
```

---

## Testing

### Unit Test

```bash
test_sync_detection() {
    # Add IP to file only (create drift)
    echo "192.168.99.99  # Test" >> /etc/nftban/whitelist-user.conf

    # Check drift detection
    result=$(nftban_sync_check_whitelist_drift)
    IFS='|' read -r name file_v4 nft_v4 file_v6 nft_v6 drift <<< "$result"

    if [[ "$drift" != "true" ]]; then
        echo "FAIL: Drift not detected"
        return 1
    fi

    # Repair
    nftban_sync_repair

    # Verify fixed
    result=$(nftban_sync_check_whitelist_drift)
    IFS='|' read -r name file_v4 nft_v4 file_v6 nft_v6 drift <<< "$result"

    if [[ "$drift" != "false" ]]; then
        echo "FAIL: Drift not repaired"
        return 1
    fi

    # Cleanup
    sed -i '/192.168.99.99/d' /etc/nftban/whitelist-user.conf
    nftban_sync_repair

    echo "PASS: Sync detection and repair"
    return 0
}
```

---

## Performance

**Drift Detection Time:**
- Small lists (< 100 IPs): < 100ms
- Medium lists (< 1000 IPs): < 500ms
- Large lists (< 10000 IPs): < 2s

**Repair Time:**
- Depends on sync functions (whitelist/blacklist modules)
- Typical: 100ms - 2s

---

## Maintenance

**Automated Sync Check (Cron):**

```bash
# /etc/cron.hourly/nftban-sync-check
#!/bin/bash
if ! /usr/local/bin/nftban sync verify > /dev/null 2>&1; then
    /usr/local/bin/nftban sync repair
fi
```

**Log Rotation:**

```bash
# /etc/logrotate.d/nftban-sync
/var/log/nftban/sync.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
}
```

---

## Related Documentation

- [NFTBAN_WHITELIST_MODULE.md](NFTBAN_WHITELIST_MODULE.md)
- [NFTBAN_BLACKLIST_MODULE.md](NFTBAN_BLACKLIST_MODULE.md)
- [NFTBAN_NFTABLES_MODULE.md](NFTBAN_NFTABLES_MODULE.md)

---

## Changelog

### v1.0.0 (0.9.3-dev)
- ✅ Initial sync module implementation
- ✅ Drift detection for whitelist/blacklist
- ✅ Automatic repair functionality
- ✅ Health scoring system

---

## License

**NFTBAN Custom License v3.0**
SPDX-License-Identifier: NFTBAN-Custom-License

© 2025 Antonios Voulvoulis – ITCMS. All rights reserved.

**Summary:**
- ✅ Free to use for any purpose (personal, commercial, production)
- ✅ Free to modify privately
- ✅ Free to deploy unlimited instances
- ❌ NO redistribution, republication, or resale
- ❌ NO public GitHub forks or package uploads

Full license: https://github.com/itcmsgr/nftban/blob/main/LICENSE.md

---

**Made by ITCMS** | https://itcms.gr
Empowering system administrators with simple, powerful security tools.
