# NFTBan Threat Feeds Module

**Module:** `nftban_feeds_module.sh` | **Version:** 0.9.3-dev | **Location:** `/usr/local/lib/nftban/`

## Overview

The Threat Feeds Module integrates external threat intelligence sources into NFTBan's blocking system using atomic swap operations. It downloads, validates, and maintains IP blocklists from 9 major threat intelligence providers, syncing them to nftables sets with zero-downtime updates.

### Key Features

- **9 Threat Providers**: Spamhaus, Blocklist.de (4 feeds), AbuseIPDB, DShield, Tor, Emerging Threats
- **Atomic Swap Updates**: Stage → Load → Swap pattern prevents partial states during updates
- **Smart Scheduling**: HOURLY, DAILY, or WEEKLY intervals per feed
- **Automatic Validation**: IP format checking, whitelist filtering, min/max entry limits
- **systemd Timer**: Automated updates via systemd timer (hourly checks)
- **Split Table Support**: Separate IPv4/IPv6 nftables sets (v0.9.0+)
- **Memory Limits**: Configurable max entries (500k default) to prevent OOM

### Dependencies

- **curl**: For downloading threat feeds
- **nftables**: For feeds set management
- **systemd**: For automated timer (optional)

---

## API Reference

### Initialization

**`nftban_feeds_init()`** - Initialize feeds system
```bash
nftban feeds init

# Creates:
# - /etc/nftban/config/feeds/ directory
# - /var/cache/nftban/feeds/ directory
# - nftables sets: ip nftban_v4 feeds, ip6 nftban_v6 feeds
# - Firewall rules: drop @feeds IPs
```

### Feed Management

**`nftban_feeds_enable(feed_id)`** - Enable specific feed
```bash
nftban feeds enable dshield
# Feed 'DSHIELD' enabled
# Downloading and activating feed...
# Feed DSHIELD updated: 18,432 entries saved
```

**`nftban_feeds_disable(feed_id)`** - Disable specific feed
```bash
nftban feeds disable spamhaus
# Feed 'SPAMHAUS' disabled
# Resyncing nftables...
```

**`nftban_feeds_list()`** - List all available feeds
```bash
nftban feeds list

# ═══════════════════════════════════════════════════════════════
#   NFTBan Threat Feeds - Available Providers
# ═══════════════════════════════════════════════════════════════
#
# St   Feed ID              Interval   IPs
# ───────────────────────────────────────────────────────────────
# [✓]  dshield              DAILY      18432 IPs
# [✓]  tor                  HOURLY     7543 IPs
# [✗]  spamhaus             DAILY      (disabled)
# [✓]  blocklistde_ssh      DAILY      12045 IPs
```

### Update Operations

**`nftban_feeds_update([feed_id])`** - Update feeds
```bash
# Update single feed
nftban feeds update dshield

# Update all enabled feeds
nftban feeds update
# Updating all enabled feeds...
# Update complete: 3 succeeded, 0 failed
```

**`nftban_feeds_update_single(feed_id)`** - Update specific feed
```bash
nftban_feeds_update_single "DSHIELD"
# Updating feed: DSHIELD
# Feed DSHIELD updated: 18,432 entries saved to /etc/nftban/config/feeds/dshield.txt
# Atomic sync complete: 18432 IPv4, 0 IPv6
```

**`nftban_feeds_update_scheduled()`** - Smart scheduled update
```bash
# Called by systemd timer hourly
# Checks each feed's interval and updates if due:
# - HOURLY feeds: Every hour
# - DAILY feeds: At midnight (00:00)
# - WEEKLY feeds: Sunday midnight
```

### Synchronization

**`nftban_feeds_sync_to_nftables()`** - Atomic sync to nftables
```bash
# Syncing feeds to nftables (atomic swap)...
# Building IPv4 atomic swap batch file...
# IPv4 feeds swapped atomically: 45,234 entries
# IPv6 feeds swapped atomically: 1,203 entries
# Atomic sync complete: 45234 IPv4, 1203 IPv6
```

**Atomic Swap Process**:
1. Create staging set: `feeds_new`
2. Load all IPs in single transaction
3. Atomic swap: delete `feeds`, rename `feeds_new` → `feeds`
4. Rollback on failure (cleanup staging set)

### Status & Monitoring

**`nftban_feeds_status()`** - Show feeds status
```bash
nftban feeds status

# ═══════════════════════════════════════════════════════════════
#   NFTBan Threat Feeds Status
# ═══════════════════════════════════════════════════════════════
#
# Enabled Feeds: 3 / 9
#
# NFTables Stats:
#   IPv4 Set: Active
#   IPv6 Set: Active
#
# Update Timer: ACTIVE ✓
#   Trigger: Sun 2025-10-23 00:00:00 UTC
```

**`nftban_feeds_memory()`** - Show memory usage
```bash
nftban feeds memory

# Memory Usage:
#   Feed Files: 12 MB
#   Memory Limit: 512 MB
```

### Timer Management

**`nftban_feeds_timer_install()`** - Install systemd timer
```bash
nftban feeds timer-install
# Installing systemd timer...
# Timer installed and started
# ● nftban-feeds.timer - NFTBan Threat Feeds Update Timer (Hourly)
#    Loaded: loaded
#    Active: active (waiting)
#    Trigger: Sun 2025-10-22 16:00:00 UTC
```

**`nftban_feeds_timer_remove()`** - Remove systemd timer
```bash
nftban feeds timer-remove
# Removing systemd timer...
# Timer removed
```

---

## Configuration

**Feed Configuration** (`/etc/nftban/nftban.conf`):

```bash
# Feed format: NFTBAN_FEED_{ID}_{PARAMETER}="value"

# DShield Feed (SANS Institute)
NFTBAN_FEED_DSHIELD_ENABLED="TRUE"
NFTBAN_FEED_DSHIELD_URL="https://www.dshield.org/ipsascii.html?limit=10000"
NFTBAN_FEED_DSHIELD_FILE="${CONFIG_DIR}/feeds/dshield.txt"
NFTBAN_FEED_DSHIELD_INTERVAL="DAILY"

# Tor Exit Nodes
NFTBAN_FEED_TOR_ENABLED="TRUE"
NFTBAN_FEED_TOR_URL="https://check.torproject.org/torbulkexitlist"
NFTBAN_FEED_TOR_FILE="${CONFIG_DIR}/feeds/tor.txt"
NFTBAN_FEED_TOR_INTERVAL="HOURLY"

# Spamhaus DROP
NFTBAN_FEED_SPAMHAUS_ENABLED="FALSE"
NFTBAN_FEED_SPAMHAUS_URL="https://www.spamhaus.org/drop/drop.txt"
NFTBAN_FEED_SPAMHAUS_FILE="${CONFIG_DIR}/feeds/spamhaus.txt"
NFTBAN_FEED_SPAMHAUS_INTERVAL="DAILY"
```

**Global Settings**:
```bash
# Download timeout
NFTBAN_FEEDS_DOWNLOAD_TIMEOUT=30  # seconds

# Validation limits
NFTBAN_FEEDS_MIN_ENTRIES=10       # Reject if fewer IPs
NFTBAN_FEEDS_MAX_ENTRIES=500000   # Truncate if more IPs

# Memory limit
NFTBAN_FEEDS_MEMORY_LIMIT=512     # MB
```

**Available Feed IDs**:
- `SPAMHAUS` - Spamhaus DROP list
- `BLOCKLISTDE_ALL` - Blocklist.de all attacks
- `BLOCKLISTDE_SSH` - Blocklist.de SSH attacks
- `BLOCKLISTDE_MAIL` - Blocklist.de mail server attacks
- `BLOCKLISTDE_APACHE` - Blocklist.de Apache attacks
- `ABUSECH` - Abuse.ch threat intelligence
- `DSHIELD` - SANS DShield top attackers
- `TOR` - Tor exit nodes
- `EMERGING_THREATS` - Emerging Threats compromised IPs

---

## CLI Integration

```bash
# Initial setup
nftban feeds init

# Enable feeds
nftban feeds enable dshield
nftban feeds enable tor
nftban feeds enable blocklistde_ssh

# List feeds
nftban feeds list

# Update feeds
nftban feeds update              # All enabled
nftban feeds update dshield      # Single feed

# Status
nftban feeds status
nftban feeds memory

# Install automatic updates
nftban feeds timer-install

# Remove timer
nftban feeds timer-remove
```

---

## Atomic Swap Implementation

### Stage 1: Create Staging Set
```nft
add set ip nftban_v4 feeds_new { type ipv4_addr; flags interval; auto-merge; }
```

### Stage 2: Populate in Single Transaction
```nft
add element ip nftban_v4 feeds_new { 1.2.3.4, 5.6.7.8, 10.0.0.0/8, ... }
```

### Stage 3: Atomic Swap
```nft
delete set ip nftban_v4 feeds
rename set ip nftban_v4 feeds_new feeds
```

**Benefits**:
- **Zero Downtime**: No moment where feeds set is empty
- **All-or-Nothing**: Transaction succeeds completely or rolls back
- **Consistency**: No partial feed states during updates

---

## Testing

### Test 1: Enable and Update Feed

```bash
# Enable DShield
nftban feeds enable dshield

# Verify download
cat /etc/nftban/config/feeds/dshield.txt | head -20

# Check nftables
nft list set ip nftban_v4 feeds | grep -c elements
```

### Test 2: Atomic Swap Verification

```bash
# Update feed
nftban feeds update dshield

# Check logs for atomic swap
tail -20 /var/log/nftban/feeds.log | grep "atomic"
# Output: IPv4 feeds swapped atomically: 18432 entries

# Verify no staging sets left
nft list sets ip nftban_v4 | grep feeds_new
# (should be empty - staging set cleaned up)
```

### Test 3: Timer Functionality

```bash
# Install timer
nftban feeds timer-install

# Check timer status
systemctl status nftban-feeds.timer

# Check next trigger
systemctl list-timers nftban-feeds.timer

# Manual trigger
systemctl start nftban-feeds.service

# Check logs
journalctl -u nftban-feeds.service -n 50
```

### Test 4: Whitelist Protection

```bash
# Add IP to whitelist
nftban whitelist add 1.2.3.4 "Test IP"

# Add same IP to feed file manually
echo "1.2.3.4" >> /etc/nftban/config/feeds/dshield.txt

# Sync to nftables
nftban feeds sync

# Verify NOT in feeds set (whitelisted)
nft list set ip nftban_v4 feeds | grep 1.2.3.4
# (should not appear - filtered by whitelist check)
```

---

## Performance

**Update Speed**:
- Download: ~1-5 seconds (network-dependent)
- Parse/Validate: ~2-3 seconds for 100k IPs
- Atomic Swap: ~1-2 seconds for 100k IPs
- Total: ~5-10 seconds for large feeds

**Memory Usage**:
- Per IP entry: ~50 bytes in memory
- 100k IPs: ~5 MB RAM
- 500k IPs: ~25 MB RAM

**nftables Lookup**:
- O(log n) interval set lookup
- ~10-50 nanoseconds per packet
- Negligible CPU impact (<0.1% at 10k pps)

---

## Troubleshooting

### Issue 1: Feed Download Fails

**Symptoms**: `Download failed for DSHIELD`

**Solutions**:
```bash
# Test connectivity
curl -v https://www.dshield.org/ipsascii.html?limit=100

# Check firewall
iptables -L OUTPUT -v -n | grep 443

# Increase timeout
echo 'NFTBAN_FEEDS_DOWNLOAD_TIMEOUT=60' >> /etc/nftban/nftban.conf
```

### Issue 2: Atomic Swap Fails

**Symptoms**: `IPv4 atomic swap failed, rolling back...`

**Solutions**:
```bash
# Check nftables table exists
nft list table ip nftban_v4

# Verify feeds set exists
nft list set ip nftban_v4 feeds

# Manual cleanup of staging set
nft delete set ip nftban_v4 feeds_new 2>/dev/null

# Retry sync
nftban feeds sync
```

### Issue 3: Too Many Entries Rejected

**Symptoms**: `Feed DSHIELD has only 5 entries (minimum: 10), rejecting`

**Solutions**:
```bash
# Lower minimum threshold
echo 'NFTBAN_FEEDS_MIN_ENTRIES=1' >> /etc/nftban/nftban.conf

# Or check feed URL is correct
grep DSHIELD_URL /etc/nftban/nftban.conf
```

### Issue 4: Memory Limit Exceeded

**Symptoms**: System OOM, high memory usage

**Solutions**:
```bash
# Check current usage
nftban feeds memory

# Reduce max entries
echo 'NFTBAN_FEEDS_MAX_ENTRIES=100000' >> /etc/nftban/nftban.conf

# Disable large feeds
nftban feeds disable emerging_threats
nftban feeds disable abusech
```

---

## Security Considerations

### Atomic Operations

**Purpose**: Prevent race conditions during feed updates

**Protection**:
- No moment where feeds set is empty (zero downtime)
- All-or-nothing transactions (consistency)
- Automatic rollback on failure

### Whitelist Filtering

All feed IPs checked against NFTBan whitelist before loading:
```bash
# During update_single()
if nftban_whitelist_check_ip "$ip" 2>/dev/null; then
    # Skip whitelisted IPs
    continue
fi
```

### Validation

**IP Format Validation**:
- IPv4: Regex + octet range check (0-255)
- IPv6: Colon presence + CIDR validation
- CIDR: Both IPv4/IPv6 with prefix length

**Entry Limits**:
- Minimum: 10 entries (prevents corrupt downloads)
- Maximum: 500k entries (prevents OOM)

---

## Integration with Other Modules

### With Whitelist Module
```bash
# Feeds automatically exclude whitelisted IPs
nftban whitelist add 8.8.8.8 "Google DNS"
nftban feeds update  # 8.8.8.8 never added to feeds set
```

### With GEO Module
```bash
# Block countries + threat feeds
nftban geo block CN
nftban feeds enable dshield
# Combined: Geographic + threat intelligence blocking
```

### With Stats Module
```bash
# View feeds blocking statistics
nft list chain ip nftban_v4 input | grep feeds
# Shows packet/byte counters for feeds rule
```

---

## Best Practices

1. **Start with conservative feeds**:
   ```bash
   nftban feeds enable dshield      # SANS DShield (high quality)
   nftban feeds enable tor          # Tor exit nodes
   ```

2. **Monitor for false positives**:
   ```bash
   tail -f /var/log/nftban/feeds.log
   # Watch for legitimate IPs being blocked
   ```

3. **Install automated updates**:
   ```bash
   nftban feeds timer-install
   # Ensures feeds stay current
   ```

4. **Set appropriate intervals**:
   - HOURLY: Tor exit nodes (changes frequently)
   - DAILY: Most feeds (DShield, Blocklist.de)
   - WEEKLY: Static lists (Spamhaus DROP)

5. **Monitor memory usage**:
   ```bash
   nftban feeds memory
   # Keep under 50% of NFTBAN_FEEDS_MEMORY_LIMIT
   ```

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
