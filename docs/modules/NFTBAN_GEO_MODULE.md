# NFTBan GEO Blocking Module

**Module:** `nftban_geo_module.sh` | **Version:** 0.9.3-dev | **Location:** `/usr/local/lib/nftban/`

## Overview

The GEO Blocking Module enables country-level IP blocking using MaxMind's GeoIP databases and DB-IP community data. It downloads, caches, and manages IP address ranges by country code (ISO 3166-1 alpha-2), integrating them into nftables sets for high-performance geographic filtering.

### Key Features

- **Country-Level Blocking**: Block/allow entire countries by 2-letter code (CN, RU, US, etc.)
- **Dual-Stack Support**: Independent IPv4 and IPv6 blocking with split table architecture (v0.9.0+)
- **Two Modes**: Blacklist (block specific countries) or whitelist (allow only specific countries)
- **Dry-Run Mode**: Test configuration without actually blocking traffic (recommended for tuning)
- **Auto-Download**: Fetches IP ranges from DB-IP community database (free, monthly updates)
- **Batch Loading**: nftables batch file loading for efficient set population (1000+ entries/second)
- **Persistent Storage**: Cached IP ranges for offline operation and faster reloads
- **Whitelist Protection**: Never blocks whitelisted countries, even if in blacklist

### Dependencies

- **Core Module**: `nftban_core.sh`
- **Utils Module**: `nftban_utils_lib.sh`
- **nftables**: For set creation and IP range matching
- **curl or wget**: For downloading GeoIP databases
- **python3**: Optional, for JSON metadata management

### Data Source

- **Provider**: DB-IP Community (https://db-ip.com/)
- **License**: Creative Commons Attribution 4.0
- **Update Frequency**: Monthly
- **Accuracy**: ~95-98% (industry standard for free GeoIP databases)
- **Repository**: https://github.com/sapics/ip-location-db

---

## API Reference

### Initialization

**`nftban_geo_init()`** - Initialize GEO blocking system
```bash
nftban geo init
# Creates directories, config files, blacklist, whitelist
```
- **Creates**:
  - `/etc/nftban/geo-blocking.conf` - Main configuration
  - `/etc/nftban/geo-blacklist.conf` - Countries to block
  - `/etc/nftban/geo-whitelist.conf` - Countries never to block
  - `/var/lib/nftban/geoip/` - Data directory
  - `/var/lib/nftban/geoip/cache/` - Downloaded IP ranges
  - `/var/lib/nftban/geoip/sets/` - nftables batch files
- **Auto-called**: By `nftban geo enable`

---

### Download Management

**`nftban_geo_download_country(country_code, ip_version)`** - Download IP ranges for country
```bash
nftban_geo_download_country "CN" "both"
# Downloading IP ranges for CN (IPv both)...
# Downloaded 8,456 IPv4 ranges for CN
# Downloaded 2,103 IPv6 ranges for CN
```
- **Parameters**:
  - `country_code`: ISO 3166-1 alpha-2 code (CN, RU, US, etc.)
  - `ip_version`: "4", "6", or "both" (default: "both")
- **Downloads from**:
  - IPv4: `https://raw.githubusercontent.com/sapics/ip-location-db/main/dbip-country/{CC}.cidr`
  - IPv6: `https://raw.githubusercontent.com/sapics/ip-location-db/main/dbip-country/{CC}-ipv6.cidr`
- **Caches to**:
  - IPv4: `/var/lib/nftban/geoip/cache/{CC}-ipv4.cidr`
  - IPv6: `/var/lib/nftban/geoip/cache/{CC}-ipv6.cidr`
- **Metadata**: Updates `/var/lib/nftban/geoip/metadata.json` with download timestamp

**`nftban_geo_update_database(country_code)`** - Update cached IP ranges
```bash
# Update single country
nftban geo update CN

# Update all blocked countries
nftban geo update ALL
# Updated 5 countries
```
- **Use case**: Monthly maintenance, database refresh
- **Preserves**: Existing blocks (only updates cached data)

---

### Blocking Operations

**`nftban_geo_block_country(country_code, ip_version)`** - Block a country
```bash
nftban geo block CN
# Blocking country: CN (IPv both)
# Downloading IP ranges for CN (if not cached)...
# Adding IPv4 ranges to nftables...
# Added 8,456 IPv4 ranges
# Adding IPv6 ranges to nftables...
# Added 2,103 IPv6 ranges
# Country CN blocked (10,559 total ranges)
```
- **Workflow**:
  1. Checks whitelist (aborts if country whitelisted)
  2. Downloads IP ranges (if not cached)
  3. Creates nftables sets: `geo_block_{CC}` in both tables
  4. Populates sets from cached CIDR files
  5. Adds entry to `geo-blacklist.conf` (if not present)
  6. Updates metadata with block timestamp
- **nftables sets created**:
  - IPv4: `ip nftban_v4 geo_block_CN` (type ipv4_addr, flags interval)
  - IPv6: `ip6 nftban_v6 geo_block_CN` (type ipv6_addr, flags interval)
- **Batch loading**: Uses batch files for efficient loading (1000 entries at once)

**`nftban_geo_unblock_country(country_code, ip_version)`** - Unblock a country
```bash
nftban geo unblock CN
# Unblocking country: CN (IPv both)
# Removed IPv4 GEO set
# Removed IPv6 GEO set
# Country CN unblocked
```
- **Actions**:
  1. Deletes nftables sets (both IPv4 and IPv6)
  2. Removes from `geo-blacklist.conf`
  3. Updates metadata
- **Note**: Keeps cached IP ranges (for future use)

---

### Query Functions

**`nftban_geo_check_ip(ip)`** - Check if IP is GEO-blocked
```bash
nftban geo check 1.2.3.4
# IP 1.2.3.4 belongs to GEO blocked country: CN
# (exit code 0)

nftban geo check 8.8.8.8
# (no output, exit code 1 - not blocked)
```
- **Validates**: IP format with `nftban_validate_ip()`
- **Detects version**: Auto-detects IPv4 vs IPv6
- **Searches**: All `geo_block_*` sets in appropriate table
- **Performance**: O(log n) lookup using nftables interval sets
- **Use case**: Debugging, testing, audit logs

**`nftban_geo_list_blocked()`** - List all blocked countries with status
```bash
nftban geo list

# === GEO Blocked Countries ===
#
# Configured countries:
#   1. CN   [IPv4 + IPv6 Active]
#   2. RU   [IPv4 + IPv6 Active]
#   3. KP   [IPv4 Active]
#   4. IR   [Not Active]
#
# Active nftables GEO sets:
#   IPv4 table (ip nftban_v4):
#     set geo_block_CN { ... }
#     set geo_block_RU { ... }
#   IPv6 table (ip6 nftban_v6):
#     set geo_block_CN { ... }
#     set geo_block_RU { ... }
```
- **Shows**:
  - Countries in `geo-blacklist.conf`
  - Active status (loaded in nftables or not)
  - IPv4/IPv6 coverage per country
  - All active GEO sets in both tables

---

### Synchronization

**`nftban_geo_sync_blacklist()`** - Sync blacklist file to nftables
```bash
nftban geo sync
# Syncing GEO blacklist to nftables...
# GEO sync complete: 3 succeeded, 0 failed
```
- **Use case**: After manually editing `geo-blacklist.conf`
- **Process**: Reads blacklist file, blocks each country
- **Idempotent**: Safe to run multiple times (updates existing sets)

---

### Control Functions

**`nftban_geo_enable()`** - Enable GEO blocking system
```bash
nftban geo enable

# ======================================================================
#   NFTBan GEO-Blocking Enable
# ======================================================================
#
# ⚠️  WARNING: You are about to enable GEO-blocking!
#
# This will block traffic from countries listed in:
#   /etc/nftban/config/geo-blacklist.conf
#
# Before enabling, make sure you have:
#   1. Reviewed and configured geo-blacklist.conf
#   2. Reviewed and configured geo-whitelist.conf
#   3. Set GEO_DRY_RUN="TRUE" for testing (recommended)
#   4. Understand the risks of blocking entire countries
#
# Countries in blacklist: 3
# Configured countries:
#   - CN  # China
#   - RU  # Russia
#   - KP  # North Korea
#
# ✅ DRY-RUN mode is ENABLED (safe - will only log, not block)
#
# Do you want to enable GEO-blocking? (yes/no): yes
#
# Enabling GEO-blocking...
# Initializing GEO blocking system...
# Syncing GEO blacklist to nftables...
#
# ✅ GEO-blocking ENABLED
#
# Next steps:
#   1. Monitor logs: tail -f /var/log/nftban/geo-blocking.log
#   2. Check status: nftban geo status
#   3. List blocked: nftban geo list
#   4. Test IP: nftban geo check <IP>
```
- **Interactive**: Requires user confirmation
- **Safety warnings**: Recommends dry-run mode
- **Shows preview**: Lists countries that will be blocked
- **Actions**:
  1. Sets `GEO_BLOCKING_ENABLED="TRUE"` in config
  2. Initializes system (creates directories, files)
  3. Syncs blacklist to nftables
  4. Logs enable event

**`nftban_geo_disable()`** - Disable GEO blocking system
```bash
nftban geo disable

# ======================================================================
#   NFTBan GEO-Blocking Disable
# ======================================================================
#
# You are about to disable GEO-blocking.
#
# This will:
#   1. Remove ALL country blocks from nftables
#   2. Allow traffic from previously blocked countries
#   3. Keep blacklist/whitelist files (for future use)
#
# Countries currently blocked: 3
#
# Do you want to disable GEO-blocking? (yes/no): yes
#
# Disabling GEO-blocking...
# Removing GEO sets from nftables...
#
# ✅ GEO-blocking DISABLED
#
# All country blocks have been removed from nftables.
# Blacklist/whitelist files preserved at:
#   - /etc/nftban/config/geo-blacklist.conf
#   - /etc/nftban/config/geo-whitelist.conf
```
- **Interactive**: Requires confirmation
- **Actions**:
  1. Sets `GEO_BLOCKING_ENABLED="FALSE"`
  2. Removes all `geo_block_*` sets from both tables
  3. Preserves configuration files
  4. Logs disable event

**`nftban_geo_status()`** - Show comprehensive status
```bash
nftban geo status

# ======================================================================
#   NFTBan GEO-Blocking Status
# ======================================================================
#
# Master Status:
#   GEO-Blocking: ✅ ENABLED
#
# Configuration:
#   Mode: blacklist
#   Dry-Run: ✅ ENABLED (safe - logging only, no blocking)
#   IPv4 Blocking: TRUE
#   IPv6 Blocking: TRUE
#   Auto-Block: FALSE
#
# Blacklist (/etc/nftban/config/geo-blacklist.conf):
#   Countries configured: 3
#   Countries:
#     - CN    # China
#     - RU    # Russia
#     - KP    # North Korea
#
# Whitelist (/etc/nftban/config/geo-whitelist.conf):
#   Countries configured: 2
#   Countries (always allowed):
#     - US    # United States
#     - GB    # United Kingdom
#
# Active nftables GEO sets:
#   IPv4 GEO sets: 3
#   IPv6 GEO sets: 3
#   Active countries:
#     - CN
#     - RU
#     - KP
#
# Recent Activity (last 5 entries):
#   [2025-10-22 14:30:15] BLOCK - CN (IPv4) - Added 8456 ranges
#   [2025-10-22 14:30:20] BLOCK - CN (IPv6) - Added 2103 ranges
#   [2025-10-22 14:31:05] BLOCK - RU (IPv4) - Added 12203 ranges
#   [2025-10-22 14:31:12] BLOCK - RU (IPv6) - Added 3567 ranges
#   [2025-10-22 14:32:00] BLOCK - KP (IPv4) - Added 1024 ranges
#
# Useful Commands:
#   Disable: nftban geo disable
#   Block country:   nftban geo block CN
#   Unblock country: nftban geo unblock CN
#   List blocked:    nftban geo list
#   Check IP:        nftban geo check <IP>
#   Reload all:      nftban geo reload
```

---

## Configuration

**Files:**
- `/etc/nftban/geo-blocking.conf` - Main configuration
- `/etc/nftban/geo-blacklist.conf` - Countries to block (blacklist mode)
- `/etc/nftban/geo-whitelist.conf` - Countries never to block (whitelist mode)
- `/var/log/nftban/geo-blocking.log` - Activity log
- `/var/lib/nftban/geoip/cache/` - Downloaded IP ranges
- `/var/lib/nftban/geoip/sets/` - nftables batch files
- `/var/lib/nftban/geoip/metadata.json` - Download/block metadata

### Main Configuration

**`/etc/nftban/geo-blocking.conf`:**
```bash
# Enable/Disable GEO-blocking
GEO_BLOCKING_ENABLED="FALSE"

# Blocking mode: "blacklist" or "whitelist"
# blacklist = Allow all EXCEPT countries in geo-blacklist.conf
# whitelist = Block all EXCEPT countries in geo-whitelist.conf
GEO_BLOCKING_MODE="blacklist"

# Dry-run mode (RECOMMENDED for testing)
# TRUE = Log what would be blocked, but don't actually block
# FALSE = Actually block traffic (production)
GEO_DRY_RUN="TRUE"

# Enable IPv4/IPv6 blocking
GEO_BLOCK_IPV4="TRUE"
GEO_BLOCK_IPV6="TRUE"

# Auto-block suspicious countries (future feature)
GEO_AUTO_BLOCK="FALSE"

# Maximum blocked countries (memory limit)
GEO_MAX_BLOCKED_COUNTRIES="50"

# nftables batch size for loading IP ranges
GEO_NFTABLES_BATCH_SIZE="1000"
```

### Blacklist Configuration

**`/etc/nftban/geo-blacklist.conf`:**
```bash
# List country codes (ISO 3166-1 alpha-2) to block
# Format: COUNTRY_CODE  # Comment

CN  # China
RU  # Russia
KP  # North Korea
IR  # Iran
VN  # Vietnam
```

### Whitelist Configuration

**`/etc/nftban/geo-whitelist.conf`:**
```bash
# List country codes that should NEVER be blocked
# Whitelist takes precedence over blacklist

US  # United States
GB  # United Kingdom
GR  # Greece
DE  # Germany
FR  # France
```

---

## CLI Integration

```bash
# Initialization
nftban geo init

# Enable/disable
nftban geo enable
nftban geo disable
nftban geo status

# Block/unblock countries
nftban geo block CN "High attack volume"
nftban geo unblock CN

# List and query
nftban geo list
nftban geo check 1.2.3.4

# Maintenance
nftban geo sync                  # Sync blacklist to nftables
nftban geo reload                # Reload configuration
nftban geo update CN             # Update China IP ranges
nftban geo update ALL            # Update all blocked countries

# Help
nftban geo help
```

---

## Blocking Modes

### Mode 1: Blacklist (Recommended)

**Behavior**: Allow all countries EXCEPT those in `geo-blacklist.conf`

```bash
# Configuration
GEO_BLOCKING_MODE="blacklist"

# Blacklist
CN
RU
KP

# Result: Traffic from CN, RU, KP blocked; all other countries allowed
```

**Use cases**:
- Standard servers with international users
- Block known attack sources
- Most common deployment scenario

### Mode 2: Whitelist (Strict)

**Behavior**: Block all countries EXCEPT those in `geo-whitelist.conf`

```bash
# Configuration
GEO_BLOCKING_MODE="whitelist"

# Whitelist
US
CA
GB

# Result: ONLY US, CA, GB traffic allowed; all other countries blocked
```

**Use cases**:
- Services serving specific regions only
- High-security applications
- Regulatory compliance (e.g., ITAR)

**⚠️ WARNING**: Empty whitelist = block entire world!

---

## Dry-Run Mode (Testing)

### Purpose

Test GEO-blocking configuration without actually blocking traffic.

### How It Works

```bash
GEO_DRY_RUN="TRUE"
```
- **Logs**: What would be blocked
- **Does NOT**: Actually block traffic
- **Perfect for**: Testing blacklist without risk

### Recommended Workflow

1. **Enable dry-run**:
   ```bash
   # Edit /etc/nftban/geo-blocking.conf
   GEO_DRY_RUN="TRUE"
   ```

2. **Enable GEO-blocking**:
   ```bash
   nftban geo enable
   ```

3. **Monitor logs** (1-2 weeks):
   ```bash
   tail -f /var/log/nftban/geo-blocking.log
   ```

4. **Check for false positives**:
   - Legitimate users from blocked countries?
   - VPN/corporate routing issues?
   - Unexpected access patterns?

5. **Disable dry-run for production**:
   ```bash
   # Edit /etc/nftban/geo-blocking.conf
   GEO_DRY_RUN="FALSE"
   nftban geo reload
   ```

---

## Country Codes (ISO 3166-1 alpha-2)

### Common Countries

| Code | Country | Code | Country | Code | Country |
|------|---------|------|---------|------|---------|
| US | United States | CN | China | RU | Russia |
| GB | United Kingdom | DE | Germany | FR | France |
| JP | Japan | IN | India | BR | Brazil |
| CA | Canada | AU | Australia | IT | Italy |
| ES | Spain | MX | Mexico | KR | South Korea |
| NL | Netherlands | SG | Singapore | GR | Greece |

### High-Risk Sources (Research Before Blocking)

| Code | Country | Code | Country | Code | Country |
|------|---------|------|---------|------|---------|
| CN | China | RU | Russia | KP | North Korea |
| IR | Iran | VN | Vietnam | BD | Bangladesh |
| IN | India | BR | Brazil | TR | Turkey |

**Full list**: https://en.wikipedia.org/wiki/ISO_3166-1_alpha-2

---

## Testing

### Test 1: Block Single Country

```bash
# Enable dry-run mode
echo 'GEO_DRY_RUN="TRUE"' >> /etc/nftban/geo-blocking.conf

# Block China
nftban geo block CN

# Verify sets created
nft list sets ip nftban_v4 | grep geo_block_CN
nft list sets ip6 nftban_v6 | grep geo_block_CN

# Check specific Chinese IP
nftban geo check 1.2.3.4
# Output: IP 1.2.3.4 belongs to GEO blocked country: CN

# Check non-Chinese IP
nftban geo check 8.8.8.8
# (no output - not blocked)
```

### Test 2: Whitelist Protection

```bash
# Add US to whitelist
echo "US  # United States" >> /etc/nftban/geo-whitelist.conf

# Try to block US (should fail)
nftban geo block US
# Output: Country US is in GEO whitelist - cannot block

# Verify not blocked
nftban geo list | grep US
# (US not in blocked list)
```

### Test 3: Blacklist vs Whitelist Mode

```bash
# Test blacklist mode
echo 'GEO_BLOCKING_MODE="blacklist"' > /etc/nftban/geo-blocking.conf
echo "CN" > /etc/nftban/geo-blacklist.conf
nftban geo reload
# Result: Only CN blocked, all others allowed

# Test whitelist mode
echo 'GEO_BLOCKING_MODE="whitelist"' > /etc/nftban/geo-blocking.conf
echo "US" > /etc/nftban/geo-whitelist.conf
nftban geo reload
# Result: Only US allowed, all others blocked
```

### Test 4: Database Update

```bash
# Check current cache date
ls -l /var/lib/nftban/geoip/cache/CN-ipv4.cidr

# Update database
nftban geo update CN

# Verify newer timestamp
ls -l /var/lib/nftban/geoip/cache/CN-ipv4.cidr

# Check metadata
cat /var/lib/nftban/geoip/metadata.json
```

---

## Performance

### Memory Usage

**Per country (approximate)**:
- **Small countries** (KP, GR): 1-5 MB
- **Medium countries** (RU, BR): 10-30 MB
- **Large countries** (US, CN): 30-100 MB

**10 countries**: ~200-500 MB total (varies by country size)

### CPU Usage

- **Download**: Minimal (network I/O bound)
- **nftables loading**: ~1-5 seconds per country (batch mode)
- **Lookup**: O(log n) per packet (nftables interval set)

### nftables Set Performance

```bash
# IPv4 China example:
# - 8,456 CIDR blocks
# - nftables interval set (sorted, binary search)
# - Lookup time: ~10-50 nanoseconds per packet
# - Negligible CPU overhead (<0.1% at 10k pps)
```

### Benchmarks

```bash
# Load time (CN - 8,456 IPv4 ranges):
time nftban geo block CN
# Real: 2.3s
# User: 0.8s
# Sys: 1.4s

# Lookup time (nftables):
# 1M packets: ~50ms total CPU time (<0.005% overhead)
```

---

## Troubleshooting

### Issue 1: Legitimate Users Blocked

**Symptoms**: Users from allowed countries cannot connect

**Causes**:
1. VPN routes through blocked country
2. Corporate proxy in blocked country
3. Mobile roaming shows foreign IP
4. CDN IP misclassified

**Solutions**:
```bash
# Add country to whitelist
echo "US  # United States" >> /etc/nftban/geo-whitelist.conf
nftban geo reload

# Or whitelist specific IP
nftban whitelist add 203.0.113.50 "Legitimate user - corporate VPN"

# Or unblock entire country
nftban geo unblock CN
```

### Issue 2: Countries Not Blocking

**Symptoms**: Traffic from blocked countries still getting through

**Causes**:
1. Dry-run mode enabled
2. GEO-blocking disabled
3. Sets not loaded in nftables
4. Rules not applied to traffic

**Solutions**:
```bash
# Check status
nftban geo status

# Verify enabled
grep GEO_BLOCKING_ENABLED /etc/nftban/geo-blocking.conf
# Should be: GEO_BLOCKING_ENABLED="TRUE"

# Check dry-run
grep GEO_DRY_RUN /etc/nftban/geo-blocking.conf
# Should be: GEO_DRY_RUN="FALSE" (for production)

# Verify nftables sets
nft list sets ip nftban_v4 | grep geo_block
nft list sets ip6 nftban_v6 | grep geo_block

# Reload
nftban geo reload
```

### Issue 3: High Memory Usage

**Symptoms**: Server using excessive RAM, OOM errors

**Causes**:
1. Too many large countries blocked (US, CN, IN)
2. Both IPv4 and IPv6 loaded
3. Exceeded `GEO_MAX_BLOCKED_COUNTRIES`

**Solutions**:
```bash
# Check current usage
nftban geo stats

# Reduce countries
# Edit /etc/nftban/geo-blacklist.conf - remove large countries

# Disable IPv6 if not needed
echo 'GEO_BLOCK_IPV6="FALSE"' >> /etc/nftban/geo-blocking.conf

# Reduce limit
echo 'GEO_MAX_BLOCKED_COUNTRIES="20"' >> /etc/nftban/geo-blocking.conf

# Unblock large countries
nftban geo unblock CN
nftban geo unblock US
```

### Issue 4: Download Failures

**Symptoms**: Cannot download IP ranges, errors during block

**Causes**:
1. No internet connection
2. GitHub/DB-IP repository unavailable
3. curl/wget not installed
4. Firewall blocking outbound HTTPS

**Solutions**:
```bash
# Test connectivity
curl -I https://raw.githubusercontent.com/sapics/ip-location-db/main/README.md

# Install curl or wget
apt-get install curl   # Debian/Ubuntu
yum install curl       # RHEL/CentOS

# Check firewall
iptables -L OUTPUT -v -n | grep 443
nft list ruleset | grep 443

# Manual download
cd /var/lib/nftban/geoip/cache
curl -O https://raw.githubusercontent.com/sapics/ip-location-db/main/dbip-country/CN.cidr
curl -O https://raw.githubusercontent.com/sapics/ip-location-db/main/dbip-country/CN-ipv6.cidr
```

### Issue 5: Slow Performance

**Symptoms**: High CPU usage, slow packet processing

**Causes**:
1. Too many countries blocked
2. Small batch size
3. nftables rule ordering issues

**Solutions**:
```bash
# Increase batch size
echo 'GEO_NFTABLES_BATCH_SIZE="5000"' >> /etc/nftban/geo-blocking.conf

# Reduce countries
# Edit /etc/nftban/geo-blacklist.conf

# Pre-download ranges (avoid runtime downloads)
nftban geo update ALL

# Check nftables performance
nft monitor trace | grep geo_block
```

---

## Security Considerations

### Limitations

**GEO-blocking is NOT foolproof**:
- **VPNs**: Users appear from different countries
- **Proxies/Tor**: Can bypass geographic filtering
- **Accuracy**: GeoIP databases are ~95-98% accurate (not 100%)
- **Travelers**: Legitimate users abroad get blocked
- **Cloud services**: May show incorrect country (shared IPs)

### Attack Scenarios

**Scenario 1: VPN Bypass**
- **Attack**: Attacker uses VPN in allowed country
- **Detection**: Not detected by GEO-blocking
- **Mitigation**: Combine with other security layers (Fail2Ban, DDoS protection, threat feeds)

**Scenario 2: False Positives**
- **Attack**: N/A (legitimate user issue)
- **Impact**: Customer from blocked country cannot access service
- **Mitigation**: Whitelist customer's country, provide alternative access (support email)

**Scenario 3: Mobile Roaming**
- **Attack**: N/A (legitimate user issue)
- **Impact**: User traveling abroad gets blocked
- **Mitigation**: Whitelist common travel destinations, provide support contact

**Scenario 4: CDN Misclassification**
- **Attack**: N/A (database accuracy issue)
- **Impact**: CDN IP incorrectly classified as blocked country
- **Mitigation**: Whitelist CDN IP ranges, report to DB-IP for correction

### Best Practices

1. **Use as secondary defense**: Not primary security
2. **Combine with other layers**: Fail2Ban, DDoS protection, threat feeds
3. **Minimal blacklist**: Only block proven threats
4. **Regular review**: Threat landscape changes
5. **Monitor logs**: Watch for false positives
6. **Provide alternatives**: Support contact, alternative access
7. **Document justification**: Business reason for blocking
8. **Test in dry-run**: Always test 1-2 weeks before production

### Legal Considerations

- **Geographic discrimination**: Some jurisdictions prohibit
- **GDPR**: Requires legitimate reason to block EU countries
- **Business justification**: Document why blocking is necessary
- **Consult legal team**: Ensure compliance with regulations

---

## Integration with Other Modules

### With Fail2Ban Module

```bash
# GEO-blocking provides first layer (country)
# Fail2Ban provides second layer (behavior)

# Example workflow:
# 1. GEO blocks CN, RU, KP (high-risk countries)
# 2. Fail2Ban monitors remaining traffic for SSH brute force
# 3. Combined: Reduces Fail2Ban load by 80%+
```

### With Feeds Module

```bash
# Import threat intelligence feeds
nftban feeds enable
nftban feeds update

# Feeds provide IP-specific threat data
# GEO provides country-level filtering
# Combined: Comprehensive geographic + threat intelligence
```

### With DDoS Module

```bash
# DDoS protection for allowed countries
nftban ddos enable

# GEO blocking for entire countries
nftban geo block CN

# Combined: Block bulk sources, rate-limit remaining traffic
```

---

## Production Deployment

### Phase 1: Planning (Week 1)

```bash
# 1. Research attack sources
grep "Failed password" /var/log/auth.log | awk '{print $(NF-3)}' | \
    xargs -I {} geoiplookup {} | sort | uniq -c | sort -rn

# 2. Identify countries to block
# - No legitimate users
# - High attack volume
# - No business presence

# 3. Document justification
echo "# Countries blocked due to high attack volume (>1000 attempts/day)" \
    >> /etc/nftban/geo-blacklist.conf
```

### Phase 2: Testing (Weeks 2-3)

```bash
# 1. Enable dry-run mode
echo 'GEO_DRY_RUN="TRUE"' >> /etc/nftban/geo-blocking.conf

# 2. Add countries to blacklist
echo "CN  # China - 5,234 attacks/day" >> /etc/nftban/geo-blacklist.conf
echo "RU  # Russia - 2,103 attacks/day" >> /etc/nftban/geo-blacklist.conf

# 3. Enable GEO-blocking
nftban geo enable

# 4. Monitor logs daily
tail -f /var/log/nftban/geo-blocking.log

# 5. Watch for false positives
grep "BLOCK" /var/log/nftban/geo-blocking.log | grep -i "legitimate"
```

### Phase 3: Production (Week 4+)

```bash
# 1. Disable dry-run
echo 'GEO_DRY_RUN="FALSE"' >> /etc/nftban/geo-blocking.conf

# 2. Reload configuration
nftban geo reload

# 3. Monitor closely for 1 week
tail -f /var/log/nftban/geo-blocking.log
tail -f /var/log/nftban/nftban.log

# 4. Create monitoring alerts
# Email alert for false positives
grep -i "whitelist" /var/log/nftban/geo-blocking.log | \
    mail -s "GEO Blocking: Whitelist Hit" admin@example.com
```

### Phase 4: Maintenance (Monthly)

```bash
# 1. Update GeoIP databases
nftban geo update ALL

# 2. Review blocked countries
nftban geo status

# 3. Check for changes in attack patterns
# (Add/remove countries as needed)

# 4. Verify memory usage
nftban geo stats

# 5. Review false positive logs
grep -i "false" /var/log/nftban/geo-blocking.log
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
