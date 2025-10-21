# NFTBan Threat Feeds Module

**File:** `lib/nftban_feeds_module.sh`  
**Version:** 4.0.0 (Single-Config Design with Split Table Architecture)  
**Author:** ITCMS Team (Antonios Voulvoulis)  
**Purpose:** Automated threat intelligence feed integration with smart interval-based updates

---

## Overview

The Threat Feeds Module provides automated integration with external threat intelligence feeds, enabling NFTBan to block known malicious IPs from sources like Spamhaus, Abuse.ch, DShield, Tor exit nodes, and others. The v4.0.0 release introduces a complete rewrite with single-config design, smart interval-based updates, and split-table architecture support.

The module manages nine distinct threat feed providers, each configurable with custom update intervals (HOURLY, DAILY, WEEKLY). All feeds are disabled by default for safety, requiring explicit activation. The system uses a single hourly systemd timer with intelligent interval logic to minimize resource usage while keeping feeds current.

Feed data flows through a comprehensive validation pipeline: download → parse → IP validation → whitelist check → min/max entry validation → file storage → nftables sync. The module automatically separates IPv4 and IPv6 entries, handles CIDR ranges, deduplicates across feeds, and provides detailed statistics and monitoring capabilities.

---

## Key Functions

### Public Functions (Exported) - Feed Management

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `nftban_feeds_init()` | Initialize feeds system | None | 0 on success |
| `nftban_feeds_enable()` | Enable a feed provider | `$1` - feed ID | 0 on success, 1 on error |
| `nftban_feeds_disable()` | Disable a feed provider | `$1` - feed ID | 0 on success, 1 on error |
| `nftban_feeds_update()` | Update feed(s) | `$1` - feed ID or "all" (default) | 0 on success |
| `nftban_feeds_update_single()` | Update one feed | `$1` - feed ID | 0 on success, 1 on error |
| `nftban_feeds_update_scheduled()` | Smart interval-based update | None | 0 on success |
| `nftban_feeds_sync_to_nftables()` | Sync feeds to nftables | None | 0 on success |
| `nftban_feeds_list()` | List all feeds with status | None | Prints formatted table |
| `nftban_feeds_status()` | Show system status | None | Prints status report |
| `nftban_feeds_memory()` | Show memory usage | None | Prints memory stats |
| `nftban_feeds_timer_install()` | Install systemd timer | None | 0 on success |
| `nftban_feeds_timer_remove()` | Remove systemd timer | None | 0 on success |

### Internal Functions (Private)

| Function | Purpose | Notes |
|----------|---------|-------|
| `_nftban_feeds_log()` | Log feed events | Logs to feeds.log |
| `_nftban_feeds_get_config()` | Get feed configuration | Reads from nftban.conf |
| `_nftban_feeds_set_config()` | Set feed configuration | Updates nftban.conf with sed |
| `_nftban_feeds_validate_interval()` | Validate interval value | Accepts: HOURLY, DAILY, WEEKLY |
| `_nftban_feeds_is_ipv4()` | Check if IPv4 | Validates format and octets |
| `_nftban_feeds_is_ipv6()` | Check if IPv6 | Checks for colon presence |
| `_nftban_feeds_is_cidr4()` | Check if IPv4 CIDR | Validates CIDR format |
| `_nftban_feeds_is_cidr6()` | Check if IPv6 CIDR | Validates prefix length |
| `_nftban_feeds_is_valid()` | Validate IP/CIDR | Comprehensive validation |

---

## Configuration Variables

### Directory Paths

| Variable | Default | Description |
|----------|---------|-------------|
| `NFTBAN_FEEDS_CONFIG` | `/etc/nftban/config/nftban.conf` | Main configuration file |
| `NFTBAN_FEEDS_STORAGE_DIR` | `/etc/nftban/config/feeds` | Feed blacklist files |
| `NFTBAN_FEEDS_CACHE_DIR` | `/var/cache/nftban/feeds` | Temporary download cache |
| `NFTBAN_FEEDS_LOG` | `/var/log/nftban/feeds.log` | Feed operations log |

### nftables Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `NFTBAN_NFT_TABLE_V4` | `nftban_v4` | IPv4 table name |
| `NFTBAN_NFT_TABLE_V6` | `nftban_v6` | IPv6 table name |
| `NFTBAN_NFT_FAMILY_V4` | `ip` | IPv4 table family |
| `NFTBAN_NFT_FAMILY_V6` | `ip6` | IPv6 table family |
| `NFTBAN_NFT_SET_FEEDS` | `feeds` | nftables set name for feeds |

### Feed Providers (IDs)

| Feed ID | Source | Typical Size | Description |
|---------|--------|--------------|-------------|
| `SPAMHAUS` | Spamhaus DROP | ~1,000 IPs | Known spam sources |
| `BLOCKLISTDE_ALL` | Blocklist.de | ~50,000 IPs | All attack types |
| `BLOCKLISTDE_SSH` | Blocklist.de | ~10,000 IPs | SSH brute force |
| `BLOCKLISTDE_MAIL` | Blocklist.de | ~5,000 IPs | Mail server attacks |
| `BLOCKLISTDE_APACHE` | Blocklist.de | ~3,000 IPs | Web server attacks |
| `ABUSECH` | Abuse.ch | ~5,000 IPs | Malware & C&C servers |
| `DSHIELD` | SANS DShield | ~20,000 IPs | Top attackers |
| `TOR` | Tor Project | ~7,000 IPs | Tor exit nodes |
| `EMERGING_THREATS` | Emerging Threats | ~30,000 IPs | Comprehensive threats |

### Per-Feed Configuration Variables

Each feed has these configuration variables (example for SPAMHAUS):

| Variable | Example Value | Description |
|----------|---------------|-------------|
| `NFTBAN_FEED_SPAMHAUS_ENABLED` | `FALSE` | Enable/disable feed |
| `NFTBAN_FEED_SPAMHAUS_URL` | `https://...` | Feed download URL |
| `NFTBAN_FEED_SPAMHAUS_FILE` | `${CONFIG_DIR}/feeds/spamhaus-blacklist.conf` | Storage file path |
| `NFTBAN_FEED_SPAMHAUS_INTERVAL` | `DAILY` | Update interval (HOURLY/DAILY/WEEKLY) |

### System Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `NFTBAN_FEEDS_DOWNLOAD_TIMEOUT` | `30` | Download timeout (seconds) |
| `NFTBAN_FEEDS_MIN_ENTRIES` | `10` | Minimum entries (validation) |
| `NFTBAN_FEEDS_MAX_ENTRIES` | `500000` | Maximum entries (truncation) |
| `NFTBAN_FEEDS_MEMORY_LIMIT` | `512` | Memory limit (MB) |

---

## Dependencies

**Required Modules:**
- `nftban_core.sh` - Core logging and utilities
- `nftban_nftables_module.sh` - nftables operations
- `nftban_whitelist_module.sh` - Whitelist checks (optional but recommended)

**External Commands (Required):**
- `curl` - Feed downloads (CRITICAL)
- `nft` - nftables operations
- `grep`, `awk`, `sed` - Text processing
- `sort`, `wc` - Data processing

**External Commands (Optional):**
- `systemctl` - Timer management
- None (all core functionality works without optional commands)

---

## Usage Examples

### Example 1: Initialize Feeds System
```bash
# Initialize feeds infrastructure
sudo nftban feeds init

# Expected output:
# [INFO] Initializing NFTBan Threat Feeds System v4.0.0...
# [INFO] Creating IPv4 feeds set...
# [INFO] Creating IPv6 feeds set...
# [INFO] Adding IPv4 feeds firewall rule...
# [INFO] Adding IPv6 feeds firewall rule...
# [SUCCESS] Feeds system initialized
#
# Next steps:
#   1. List available feeds:    nftban feeds list
#   2. Enable a feed:           sudo nftban feeds enable dshield
#   3. Update feeds:            sudo nftban feeds update
#   4. Install automatic timer: sudo nftban feeds timer-install

# Process:
# 1. Creates /etc/nftban/config/feeds/ directory
# 2. Creates /var/cache/nftban/feeds/ directory
# 3. Creates nftables feeds sets (IPv4 and IPv6)
# 4. Adds firewall rules to block feeds
# 5. All feeds remain DISABLED (safe init)
```

### Example 2: List Available Feeds
```bash
# List all feed providers with status
nftban feeds list

# Expected output:
# ═══════════════════════════════════════════════════════════════
#  NFTBan Threat Feeds - Available Providers
# ═══════════════════════════════════════════════════════════════
#
# Global Status: FALSE
#
# St   Feed ID              Interval   IPs
# ───────────────────────────────────────────────────────────────
# [✗]  spamhaus             DAILY      (disabled)
# [✗]  blocklistde_all      DAILY      (disabled)
# [✗]  blocklistde_ssh      DAILY      (disabled)
# [✗]  blocklistde_mail     DAILY      (disabled)
# [✗]  blocklistde_apache   DAILY      (disabled)
# [✗]  abusech              DAILY      (disabled)
# [✓]  dshield              DAILY      18543 IPs
# [✗]  tor                  DAILY      (disabled)
# [✗]  emerging_threats     WEEKLY     (disabled)
#
# Commands:
#   nftban feeds enable <feed_id>     Enable a feed
#   nftban feeds disable <feed_id>    Disable a feed
#   nftban feeds update [feed_id]     Update feeds
```

### Example 3: Enable and Update a Feed
```bash
# Enable DShield feed
sudo nftban feeds enable dshield

# Expected output:
# [SUCCESS] Feed 'DSHIELD' enabled
# [INFO] Downloading and activating feed...
# [INFO] Updating feed: DSHIELD
# [DEBUG] URL: https://www.dshield.org/block.txt
# [SUCCESS] Feed DSHIELD updated: 18543 entries saved to /etc/nftban/config/feeds/dshield-blacklist.conf
# [INFO] Syncing feeds to nftables...
# [SUCCESS] Sync complete: 18543 IPv4, 0 IPv6

# Process:
# 1. Sets NFTBAN_FEED_DSHIELD_ENABLED="TRUE" in config
# 2. Downloads feed from URL
# 3. Parses and validates IPs
# 4. Checks against whitelist (skips whitelisted IPs)
# 5. Validates minimum entries (10)
# 6. Checks maximum entries (500,000, truncates if needed)
# 7. Saves to /etc/nftban/config/feeds/dshield-blacklist.conf
# 8. Syncs to nftables feeds set
# 9. Feed is now active and blocking
```

### Example 4: Enable Multiple Feeds
```bash
# Enable several feeds at once
sudo nftban feeds enable spamhaus
sudo nftban feeds enable abusech
sudo nftban feeds enable tor

# Each feed:
# - Downloads immediately
# - Validates entries
# - Saves to individual file
# - Syncs to nftables

# Final result: All enabled feeds merged in nftables @feeds set
```

### Example 5: Update All Feeds
```bash
# Update all enabled feeds
sudo nftban feeds update

# Expected output:
# [INFO] Updating all enabled feeds...
# [INFO] Updating feed: SPAMHAUS
# [SUCCESS] Feed SPAMHAUS updated: 987 entries
# [INFO] Updating feed: DSHIELD
# [SUCCESS] Feed DSHIELD updated: 18543 entries
# [INFO] Updating feed: ABUSECH
# [SUCCESS] Feed ABUSECH updated: 5234 entries
# [INFO] Update complete: 3 succeeded, 0 failed
# [INFO] Syncing feeds to nftables...
# [SUCCESS] Sync complete: 24764 IPv4, 0 IPv6

# Process:
# 1. Iterates through all feed IDs
# 2. Checks if feed is enabled
# 3. Downloads and updates each enabled feed
# 4. Aggregates results
# 5. Single sync to nftables at end (efficient)
```

### Example 6: Update Single Feed
```bash
# Update specific feed only
sudo nftban feeds update dshield

# Expected output:
# [INFO] Updating feed: DSHIELD
# [SUCCESS] Feed DSHIELD updated: 18543 entries
# [INFO] Syncing feeds to nftables...
# [SUCCESS] Sync complete: 18543 IPv4, 0 IPv6

# Use cases:
# - Quick update of critical feed
# - Testing new feed
# - Troubleshooting specific feed issues
```

### Example 7: Disable a Feed
```bash
# Disable feed (stops updates, removes from nftables)
sudo nftban feeds disable tor

# Expected output:
# [SUCCESS] Feed 'TOR' disabled
# [INFO] Resyncing nftables...
# [SUCCESS] Sync complete: 17556 IPv4, 0 IPv6

# Process:
# 1. Sets NFTBAN_FEED_TOR_ENABLED="FALSE" in config
# 2. Resyncs nftables (excludes disabled feed)
# 3. Feed file remains on disk (for quick re-enable)
# 4. Feed no longer blocks IPs

# Note: Feed file NOT deleted (keeps downloaded data)
```

### Example 8: Show Feeds Status
```bash
# Display comprehensive status
nftban feeds status

# Expected output:
# ═══════════════════════════════════════════════════════════════
#  NFTBan Threat Feeds Status
# ═══════════════════════════════════════════════════════════════
#
# Enabled Feeds: 3 / 9
#
# NFTables Stats:
#   IPv4 Set: Active
#   IPv6 Set: Active
#
# Update Timer: ACTIVE ✓
#   Next: Sun 2025-10-20 15:00:00 UTC
#
```

### Example 9: Check Memory Usage
```bash
# Show feed memory consumption
nftban feeds memory

# Expected output:
# Memory Usage:
#   Feed Files: 45 MB
#   Memory Limit: 512 MB
#
# Details:
# - Feed files stored on disk
# - nftables sets in kernel memory
# - Limit configurable via NFTBAN_FEEDS_MEMORY_LIMIT
```

### Example 10: Install Systemd Timer
```bash
# Install automatic hourly updates
sudo nftban feeds timer-install

# Expected output:
# [INFO] Installing systemd timer...
# Created symlink /etc/systemd/system/timers.target.wants/nftban-feeds.timer...
# [SUCCESS] Timer installed and started
# ● nftban-feeds.timer - NFTBan Threat Feeds Update Timer (Hourly)
#    Loaded: loaded (/etc/systemd/system/nftban-feeds.timer; enabled)
#    Active: active (waiting)
#   Trigger: Sun 2025-10-20 15:00:00 UTC

# Creates:
# - /etc/systemd/system/nftban-feeds.service
# - /etc/systemd/system/nftban-feeds.timer
#
# Timer: Runs every hour on the hour
# Service: Calls `nftban feeds update-scheduled`
#
# Smart interval logic:
# - HOURLY feeds: Update every hour
# - DAILY feeds: Update at midnight (00:00)
# - WEEKLY feeds: Update Sunday at midnight
```

### Example 11: Remove Systemd Timer
```bash
# Remove automatic updates
sudo nftban feeds timer-remove

# Expected output:
# [INFO] Removing systemd timer...
# Removed /etc/systemd/system/timers.target.wants/nftban-feeds.timer
# [SUCCESS] Timer removed

# Process:
# 1. Stops timer
# 2. Disables timer
# 3. Deletes service and timer files
# 4. Reloads systemd daemon

# Feeds remain active, just no automatic updates
```

### Example 12: Manual Scheduled Update (Smart Intervals)
```bash
# Run smart interval-based update
sudo nftban feeds update-scheduled

# Behavior:
# Current time: 15:30 (not midnight, not Sunday)
#
# HOURLY feeds:  âœ" Update (always)
# DAILY feeds:   âœ— Skip (only at 00:00)
# WEEKLY feeds:  âœ— Skip (only Sunday 00:00)

# If run at 00:00 on Sunday:
# HOURLY feeds:  âœ" Update
# DAILY feeds:   âœ" Update
# WEEKLY feeds:  âœ" Update

# This minimizes unnecessary updates and bandwidth
```

### Example 13: Feed Update Validation Process
```bash
# What happens during feed update:

# 1. Download
curl --max-time 30 --silent --location --fail "$URL" > temp.tmp

# 2. Parse (remove comments, extract IPs)
grep -vE '^(#|;|//|$)' temp.tmp | awk '{print $1}' > temp.parsed

# 3. Validate each IP
while read ip; do
    if _nftban_feeds_is_valid "$ip"; then
        # 4. Check whitelist
        if ! nftban_whitelist_check_ip "$ip"; then
            echo "$ip" >> temp.valid
        fi
    fi
done < temp.parsed

# 5. Count validation
count=$(wc -l < temp.valid)

# 6. Check minimum (default: 10)
if [[ $count -lt 10 ]]; then
    ERROR "Feed has only $count entries, rejecting"
    exit 1
fi

# 7. Check maximum (default: 500,000)
if [[ $count -gt 500000 ]]; then
    WARN "Feed has $count entries, truncating to 500000"
    head -n 500000 temp.valid > temp.final
fi

# 8. Save to file with header
cat > /etc/nftban/config/feeds/feed-blacklist.conf << EOF
# NFTBan Threat Feed: FEED_NAME
# Updated: 2025-10-20 15:30:00
# Entry Count: $count IPs/CIDRs
# [... header ...]

[... IPs ...]
EOF

# 9. Sync to nftables
nftban_feeds_sync_to_nftables
```

### Example 14: Feed File Format
```bash
# View a feed file
cat /etc/nftban/config/feeds/dshield-blacklist.conf

# Format:
# =============================================================================
# NFTBan Threat Feed: DSHIELD
# =============================================================================
# Source: https://www.dshield.org/block.txt
# Updated: 2025-10-20 15:30:00 UTC
# Entry Count: 18543 IPs/CIDRs
# Update Interval: DAILY
# Auto-managed by NFTBan - DO NOT EDIT MANUALLY
# =============================================================================

1.2.3.0/24
5.6.7.8
10.20.30.0/25
# [... 18540 more entries ...]
```

---

## File Structure

### Feed Blacklist Files

**Location:** `/etc/nftban/config/feeds/`

**Naming:** `<feed-id>-blacklist.conf`

**Format:**
```
# Header with metadata
# Source URL
# Update timestamp
# Entry count
# Update interval

[IP addresses and CIDR ranges, one per line]
```

**Management:** Automatically created and updated by module

### Configuration File Integration

**File:** `/etc/nftban/config/nftban.conf`

**Feed Configuration Section:**
```bash
# Threat Feeds Configuration
NFTBAN_FEED_SPAMHAUS_ENABLED="FALSE"
NFTBAN_FEED_SPAMHAUS_URL="https://www.spamhaus.org/drop/drop.txt"
NFTBAN_FEED_SPAMHAUS_FILE="${CONFIG_DIR}/feeds/spamhaus-blacklist.conf"
NFTBAN_FEED_SPAMHAUS_INTERVAL="DAILY"

NFTBAN_FEED_DSHIELD_ENABLED="TRUE"
NFTBAN_FEED_DSHIELD_URL="https://www.dshield.org/block.txt"
NFTBAN_FEED_DSHIELD_FILE="${CONFIG_DIR}/feeds/dshield-blacklist.conf"
NFTBAN_FEED_DSHIELD_INTERVAL="DAILY"

# [... more feeds ...]
```

**Modification:** Done via sed (preserves structure and comments)

---

## File Operations

**Reads from:**
- `/etc/nftban/config/nftban.conf` - Feed configuration
- `/etc/nftban/config/feeds/*-blacklist.conf` - Feed data files

**Writes to:**
- `/etc/nftban/config/nftban.conf` - Configuration updates (via sed)
- `/etc/nftban/config/feeds/*-blacklist.conf` - Feed blacklists
- `/var/cache/nftban/feeds/*.tmp` - Temporary download files
- `/var/log/nftban/feeds.log` - Feed operation log

**Downloads from:**
- External threat intelligence URLs (via curl)

**nftables Operations:**
- Creates sets: `feeds` (in both ip nftban_v4 and ip6 nftban_v6)
- Adds rules: Block traffic from @feeds set
- Operations: `nft add set`, `nft add rule`, `nft flush set`, `nft add element`

---

## Security Considerations

### All Feeds Disabled by Default

**Safety First:**
- New installations have ALL feeds disabled
- Requires explicit admin action to enable
- Prevents accidental blocking of legitimate traffic
- Allows selective feed activation

**Rationale:**
- Some feeds may be overly aggressive
- Allows testing individual feeds
- Prevents surprise lockouts
- Gives admin control

### Whitelist Bypass Protection

**Critical Check:**
```bash
# During feed processing:
while read ip; do
    if _nftban_feeds_is_valid "$ip"; then
        # CHECK WHITELIST
        if ! nftban_whitelist_check_ip "$ip"; then
            # Only add if NOT whitelisted
            echo "$ip" >> valid_ips
        fi
    fi
done
```

**Behavior:**
- Whitelisted IPs NEVER added to feeds
- Protects server IPs, admin IPs, trusted networks
- Prevents feed-based lockouts
- Silent skip (not an error)

### Validation Pipeline (7 Stages)

**Stage 1: Download**
- Timeout: 30 seconds (configurable)
- Silent mode (no progress output)
- Follows redirects
- Fails on HTTP errors

**Stage 2: Parse**
- Removes comments (#, ;, //)
- Removes empty lines
- Extracts first field (IP/CIDR)

**Stage 3: Format Validation**
- IPv4: Regex + octet range check
- IPv6: Colon presence check
- CIDR4: Prefix validation (0-32)
- CIDR6: Prefix validation (0-128)

**Stage 4: Whitelist Check**
- Calls `nftban_whitelist_check_ip()`
- Skips whitelisted IPs
- Protects critical infrastructure

**Stage 5: Minimum Entry Check**
- Default: 10 entries minimum
- Rejects suspiciously small feeds
- Prevents feed poisoning
- Configurable via `NFTBAN_FEEDS_MIN_ENTRIES`

**Stage 6: Maximum Entry Check**
- Default: 500,000 entries maximum
- Prevents memory exhaustion
- Truncates if exceeded (with warning)
- Configurable via `NFTBAN_FEEDS_MAX_ENTRIES`

**Stage 7: Deduplication**
- Across all enabled feeds
- Sorts and uniq during sync
- Prevents redundant nftables entries

### Split Table Architecture

**IPv4 and IPv6 Separation:**
```bash
# Separate tables for better performance
ip nftban_v4 {
    set feeds {
        type ipv4_addr
        flags interval, auto-merge
    }
}

ip6 nftban_v6 {
    set feeds {
        type ipv6_addr
        flags interval, auto-merge
    }
}
```

**Benefits:**
- 30-50% faster lookups
- Simpler rules (no protocol checking)
- Better cache efficiency
- auto-merge optimizes overlapping ranges

### Smart Interval Logic

**Prevents Unnecessary Updates:**
- HOURLY: Updates every hour
- DAILY: Updates only at midnight
- WEEKLY: Updates only Sunday midnight

**Resource Savings:**
- Reduces bandwidth usage
- Reduces CPU usage
- Reduces disk I/O
- Maintains feed currency

**Single Timer:**
- One hourly timer for all feeds
- Smart logic checks each feed's interval
- No separate timers needed
- Simpler systemd management

---

## Error Handling

**Common Errors:**

```bash
# Unknown feed ID
sudo nftban feeds enable invalid_feed
# Output: [ERROR] Unknown feed: INVALID_FEED
# Output: [INFO] Available feeds: spamhaus blocklistde_all dshield ...
# Returns: 1

# Download failure
# Output: [ERROR] Download failed for DSHIELD
# Returns: 1
# Cause: Network timeout, URL changed, service down

# Too few entries
# Output: [ERROR] Feed DSHIELD has only 5 entries (minimum: 10), rejecting
# Returns: 1
# Cause: Feed source issue, parsing problem

# Too many entries
# Output: [WARN] Feed BLOCKLISTDE_ALL has 600000 entries (max: 500000), truncating
# Note: Not an error, feed still loaded (truncated)

# Invalid interval
# Output: [WARN] Invalid interval 'MONTHLY' for SPAMHAUS, using DAILY as fallback
# Behavior: Falls back to DAILY, continues operation

# Config file missing
# Output: [ERROR] Config file not found: /etc/nftban/config/nftban.conf
# Returns: 1
# Solution: Run `nftban init`

# nftables set creation failure
# Output: [ERROR] Failed to create IPv4 feeds set
# Cause: nftables not running, permissions issue
```

**Exit Codes:**
- `0` - Success
- `1` - Error (invalid feed, download failure, validation failure)

**Error Recovery:**
- Download failure: Retry next scheduled update
- Validation failure: Keeps previous feed data
- Too few entries: Rejects update, keeps old data
- Too many entries: Truncates, continues
- Invalid interval: Falls back to DAILY

---

## Integration Points

**Called by:**
- `nftban_main_cli.sh` - For CLI commands (`nftban feeds ...`)
- Systemd timer - Hourly scheduled updates
- `nftban init` - During initialization
- Cron jobs - Alternative to systemd timer

**Calls:**
- `nftban_core.sh` functions - Logging
- `nftban_whitelist_module.sh` - `nftban_whitelist_check_ip()` (optional)
- External: `curl`, `nft`, `grep`, `awk`, `sed`, `sort`, `wc`

**Provides Data To:**
- nftables @feeds set - Blocks malicious IPs
- Search module - Feed IPs searchable
- Statistics module - Feed metrics

---

## Performance Characteristics

### Download Speed
- **Per feed:** 5-30 seconds (depends on size and network)
- **All feeds:** 1-3 minutes (parallel not implemented)

### Processing Speed
- **Parse:** ~1-5 seconds per 100,000 entries
- **Validation:** ~2-10 seconds per 100,000 entries
- **Sync to nftables:** ~5-30 seconds per 100,000 entries

### Resource Usage
- **CPU:** Moderate during update (~10-30%)
- **Memory:** <100MB during update
- **Disk:** Varies by feeds (typically 10-100MB total)
- **Network:** 1-50MB download per update

### Scalability
- **Tested:** Up to 500,000 entries per feed
- **Maximum:** 500,000 entries (configurable)
- **nftables:** Handles 1M+ entries efficiently
- **Auto-merge:** Optimizes overlapping ranges

---

## Change Log

### Version 4.0.0 (2025-10-20) - Complete Rewrite
- **BREAKING:** Single-config design (all settings in nftban.conf)
- **BREAKING:** Split-table architecture (ip nftban_v4, ip6 nftban_v6)
- Smart interval-based updates (HOURLY/DAILY/WEEKLY)
- Single hourly timer with intelligent logic
- All feeds disabled by default (safe init)
- Enhanced validation pipeline (7 stages)
- Whitelist bypass protection
- Per-feed interval configuration
- Automatic deduplication across feeds
- Memory limit enforcement
- Comprehensive logging

### Version 3.x (Previous)
- Multi-config design
- Unified table architecture
- Basic interval support

---

## See Also

**Related Modules:**
- `nftban_core.sh` - Core logging
- `nftban_nftables_module.sh` - nftables infrastructure
- `nftban_whitelist_module.sh` - Whitelist checks (protection)
- `nftban_feeds_lib.sh` - Feed library helpers (if exists)
- `nftban_search_module.sh` - IP search (includes feeds)

**Related Documentation:**
- `THREAT_FEEDS.md` - Comprehensive feeds guide
- `FEED_PROVIDERS.md` - Provider details and URLs
- `PERFORMANCE_TUNING.md` - Optimization guide

**CLI Commands:**
```bash
# Initialize
sudo nftban feeds init

# List feeds
nftban feeds list

# Enable feed
sudo nftban feeds enable <feed_id>

# Disable feed
sudo nftban feeds disable <feed_id>

# Update all
sudo nftban feeds update

# Update one
sudo nftban feeds update <feed_id>

# Show status
nftban feeds status

# Memory usage
nftban feeds memory

# Install timer
sudo nftban feeds timer-install

# Remove timer
sudo nftban feeds timer-remove
```
