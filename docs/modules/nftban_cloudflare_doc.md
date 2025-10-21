# NFTBan Cloudflare Module

**File:** `lib/nftban_cloudflare_module.sh`  
**Version:** 2.0.0 - v0.9.0 Split Table Architecture  
**Author:** ITCMS Team (Antonios Voulvoulis)  
**Purpose:** Cloudflare IP ranges management and whitelist integration for CDN protection

---

## Overview

The Cloudflare Module provides automatic management of Cloudflare's IP ranges for servers behind Cloudflare CDN/proxy services. It downloads, caches, and applies Cloudflare's official IP ranges to the whitelist, ensuring that legitimate Cloudflare traffic is never blocked while still protecting against direct attacks.

When a server uses Cloudflare as a CDN or reverse proxy, all legitimate traffic appears to originate from Cloudflare's IP ranges rather than the actual client IPs. Without whitelisting these ranges, NFTBan would potentially block legitimate traffic from Cloudflare's edge servers, breaking the CDN functionality.

This module implements automatic IP range downloads from Cloudflare's official endpoints, intelligent caching with configurable TTL to minimize API calls, split IPv4/IPv6 support with separate whitelist files (v0.9.0), automatic synchronization with nftables whitelist sets, and optional auto-update functionality via cron for maintenance-free operation.

Key features include dual-stack support (IPv4 and IPv6 separately managed), automatic detection of stale cache requiring updates, seamless integration with the search module for unified IP lookups, and comprehensive status reporting showing range counts, cache age, and activity logs.

---

## Key Functions

### Public Functions (Exported)

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `nftban_cloudflare_download_ips()` | Download IP ranges from Cloudflare | None | 0 on success, 1 on failure |
| `nftban_cloudflare_update_whitelist()` | Update whitelist files with ranges | None | 0 on success |
| `nftban_cloudflare_apply_to_nftables()` | Add ranges to nftables whitelist | None | 0 on success, 1 on error |
| `nftban_cloudflare_remove_from_nftables()` | Remove ranges from nftables | None | 0 on success |
| `nftban_cloudflare_enable()` | Enable Cloudflare whitelisting | None | 0 on success, 1 on error |
| `nftban_cloudflare_disable()` | Disable Cloudflare whitelisting | None | 0 on success |
| `nftban_cloudflare_status()` | Show comprehensive status | None | Display formatted report |
| `nftban_cloudflare_auto_update()` | Auto-update for cron jobs | None | 0 always |

### Internal Functions (Private)

| Function | Purpose | Notes |
|----------|---------|-------|
| `nftban_cf_log()` | Log Cloudflare activity | Separate log file for tracking |
| `nftban_cloudflare_needs_update()` | Check if update needed | Based on cache age |
| `nftban_cloudflare_init()` | Initialize module | Creates directories and template files |

---

## Configuration Variables

### Module Constants

| Variable | Default | Description |
|----------|---------|-------------|
| `NFTBAN_CF_IPV4_CACHE` | `${NFTBAN_CACHE_DIR}/cloudflare-ipv4.txt` | IPv4 ranges cache |
| `NFTBAN_CF_IPV6_CACHE` | `${NFTBAN_CACHE_DIR}/cloudflare-ipv6.txt` | IPv6 ranges cache |
| `NFTBAN_CF_LOG` | `${NFTBAN_LOG_DIR}/cloudflare.log` | Activity log file |

### User-Configurable (in nftban.conf)

| Variable | Default | Description |
|----------|---------|-------------|
| `CLOUDFLARE_ENABLED` | `false` | Master enable/disable |
| `CLOUDFLARE_IPV4_WHITELIST` | `FALSE` | Enable IPv4 whitelisting |
| `CLOUDFLARE_IPV6_WHITELIST` | `FALSE` | Enable IPv6 whitelisting |
| `CLOUDFLARE_AUTO_UPDATE` | `false` | Enable automatic updates |
| `CLOUDFLARE_UPDATE_INTERVAL` | `86400` | Update interval (24 hours) |
| `CLOUDFLARE_IPV4_URL` | `https://www.cloudflare.com/ips-v4` | IPv4 ranges endpoint |
| `CLOUDFLARE_IPV6_URL` | `https://www.cloudflare.com/ips-v6` | IPv6 ranges endpoint |
| `CLOUDFLARE_IPV4_WHITELIST_FILE` | `/etc/nftban/config/cloudflare-whitelist_ipsv4.conf` | IPv4 whitelist file |
| `CLOUDFLARE_IPV6_WHITELIST_FILE` | `/etc/nftban/config/cloudflare-whitelist_ipsv6.conf` | IPv6 whitelist file |

---

## Dependencies

**Required Modules:**
- `nftban_core.sh` - Core logging and configuration management
- `nftban_nftables_module.sh` - nftables operations
- `nftban_search_module.sh` - Search index integration (optional)

**External Commands:**
- `curl` - Download IP ranges from Cloudflare (required)
- `nft` - nftables command (required)
- `stat` - File age detection (required)

**External Services:**
- Cloudflare IP ranges API (public, no authentication)
  - IPv4: https://www.cloudflare.com/ips-v4
  - IPv6: https://www.cloudflare.com/ips-v6

---

## Usage Examples

### Example 1: Enable Cloudflare Whitelisting (Complete Setup)
```bash
# Enable Cloudflare integration (downloads and applies)
nftban cloudflare enable

# Expected output:
# [INFO] Enabling Cloudflare whitelisting...
# [INFO] Downloading Cloudflare IP ranges...
# [INFO]   Downloading IPv4 ranges...
# [SUCCESS]   Downloaded 14 IPv4 ranges
# [INFO]   Downloading IPv6 ranges...
# [SUCCESS]   Downloaded 9 IPv6 ranges
# [SUCCESS] Cloudflare IP ranges downloaded successfully
# [INFO] Updating Cloudflare whitelist files...
# [SUCCESS]   IPv4 whitelist updated: 14 ranges
# [SUCCESS]   IPv6 whitelist updated: 9 ranges
# [SUCCESS] Cloudflare whitelist files updated
# [INFO] Applying Cloudflare ranges to nftables...
# [SUCCESS]   Added 14 IPv4 ranges to nftables
# [SUCCESS]   Added 9 IPv6 ranges to nftables
# [SUCCESS] Cloudflare ranges applied to nftables
# [SUCCESS] Cloudflare whitelisting enabled (IPv4 and IPv6)
```

### Example 2: Check Cloudflare Status
```bash
nftban cloudflare status

# Expected output:
# === Cloudflare Integration Status ===
#
# Status: true
# Auto-update: true
# Update interval: 24 hours
#
# IPv4 Ranges:
#   Count: 14
#   Age: 2 hours
#   File: /var/cache/nftban/cloudflare-ipv4.txt
#
# IPv6 Ranges:
#   Count: 9
#   Age: 2 hours
#   File: /var/cache/nftban/cloudflare-ipv6.txt
#
# Whitelist file:
#   Ranges: 23
#   File: /etc/nftban/config/cloudflare-whitelist_ipsv4.conf
#
# Recent Activity (last 5):
#   [2025-10-20 14:32:15] IPv4 ranges updated: 14 entries
#   [2025-10-20 14:32:16] IPv6 ranges updated: 9 entries
#   [2025-10-20 14:32:18] IPv4 whitelist file updated: 14 ranges
#   [2025-10-20 14:32:19] IPv6 whitelist file updated: 9 ranges
#   [2025-10-20 14:32:21] Applied to nftables: 14 IPv4, 9 IPv6
```

### Example 3: Manual Update (Force Refresh)
```bash
# Download latest Cloudflare ranges
nftban cloudflare download

# Or use the direct function
nftban_cloudflare_download_ips

# Expected output:
# [INFO] Downloading Cloudflare IP ranges...
# [INFO]   Downloading IPv4 ranges...
# [SUCCESS]   Downloaded 14 IPv4 ranges
# [INFO]   Downloading IPv6 ranges...
# [SUCCESS]   Downloaded 9 IPv6 ranges
# [SUCCESS] Cloudflare IP ranges downloaded successfully
```

### Example 4: Disable Cloudflare Whitelisting
```bash
nftban cloudflare disable

# Expected output:
# [INFO] Disabling Cloudflare whitelisting...
# [SUCCESS] Removed Cloudflare ranges: 14 IPv4, 9 IPv6
# [SUCCESS] Cloudflare whitelisting disabled (IPv4 and IPv6)

# Verify disabled
nftban cloudflare status
# Status: false
```

### Example 5: Setup Auto-Update (Cron Integration)
```bash
# Enable auto-update in configuration
nftban_set_config "CLOUDFLARE_AUTO_UPDATE" "true"
nftban_set_config "CLOUDFLARE_UPDATE_INTERVAL" "86400"  # 24 hours

# Add to crontab for daily updates at 3 AM
echo "0 3 * * * /usr/local/bin/nftban cloudflare auto-update" | crontab -

# Or use the nftban scheduler
nftban schedule add "cloudflare-update" \
    "nftban_cloudflare_auto_update" \
    "0 3 * * *" \
    "Update Cloudflare IP ranges"
```

### Example 6: Verify Cloudflare IP is Whitelisted
```bash
# Check if specific Cloudflare IP is whitelisted
nftban search 104.16.0.0

# Expected output:
# ╔═══════════════════════════════════════════════
#  IP Search Result: 104.16.0.0
# ╚═══════════════════════════════════════════════
# Status: ✅ WHITELISTED (Protected - Cannot be banned)
# Found in:
#  • File: /etc/nftban/config/cloudflare-whitelist_ipsv4.conf
#  • nftables: @whitelist (nftban_v4)
#  • Source: Cloudflare CDN Range
```

### Example 7: Integration with Server Behind Cloudflare
```bash
#!/bin/bash
# setup-cloudflare-server.sh
# Complete setup script for server behind Cloudflare

echo "Setting up NFTBan for Cloudflare-protected server..."

# 1. Enable Cloudflare whitelisting
nftban cloudflare enable

# 2. Configure to get real client IPs from Cloudflare headers
# (This is typically done in web server config, not NFTBan)
echo "Configure your web server to read CF-Connecting-IP header"

# 3. Enable auto-updates
nftban_set_config "CLOUDFLARE_AUTO_UPDATE" "true"

# 4. Verify setup
nftban cloudflare status

# 5. Test with known Cloudflare IP
echo ""
echo "Testing with Cloudflare IP..."
nftban search 104.16.0.0

echo ""
echo "✅ Cloudflare integration configured!"
echo "   - Cloudflare IPs whitelisted"
echo "   - Auto-update enabled"
echo "   - Run 'nftban cloudflare status' to verify"
```

---

## Cloudflare IP Ranges

### Current Range Counts (as of 2025)

**IPv4 Ranges:** ~14 CIDR blocks
- Example: `173.245.48.0/20`, `103.21.244.0/22`, `103.22.200.0/22`
- Total IPs: ~1 million IPv4 addresses

**IPv6 Ranges:** ~9 CIDR blocks
- Example: `2400:cb00::/32`, `2606:4700::/32`, `2803:f800::/32`
- Total IPs: Extremely large (IPv6 address space)

### Download Sources

**Official Cloudflare Endpoints:**
```bash
# IPv4 ranges (text file, one CIDR per line)
curl https://www.cloudflare.com/ips-v4

# Example output:
# 173.245.48.0/20
# 103.21.244.0/22
# 103.22.200.0/22
# 103.31.4.0/22
# 141.101.64.0/18
# ...

# IPv6 ranges (text file, one CIDR per line)
curl https://www.cloudflare.com/ips-v6

# Example output:
# 2400:cb00::/32
# 2606:4700::/32
# 2803:f800::/32
# 2405:b500::/32
# 2405:8100::/32
# ...
```

**Update Frequency:**
- Cloudflare updates infrequently (quarterly or less)
- Typical: 2-4 updates per year
- Default cache: 24 hours (conservative, but safe)

---

## File Operations

### Reads from:

**Configuration:**
- `/etc/nftban/config/nftban.conf` - Module settings

**Cache (existing downloads):**
- `${NFTBAN_CACHE_DIR}/cloudflare-ipv4.txt` - Cached IPv4 ranges
- `${NFTBAN_CACHE_DIR}/cloudflare-ipv6.txt` - Cached IPv6 ranges

### Writes to:

**Cache Files:**
- `${NFTBAN_CACHE_DIR}/cloudflare-ipv4.txt` - Downloaded IPv4 ranges
- `${NFTBAN_CACHE_DIR}/cloudflare-ipv6.txt` - Downloaded IPv6 ranges

**Whitelist Files:**
- `/etc/nftban/config/cloudflare-whitelist_ipsv4.conf` - IPv4 whitelist
- `/etc/nftban/config/cloudflare-whitelist_ipsv6.conf` - IPv6 whitelist

**Logs:**
- `/var/log/nftban/cloudflare.log` - Activity log

### Cache File Format:
```
173.245.48.0/20
103.21.244.0/22
103.22.200.0/22
103.31.4.0/22
141.101.64.0/18
108.162.192.0/18
190.93.240.0/20
188.114.96.0/20
197.234.240.0/22
198.41.128.0/17
162.158.0.0/15
104.16.0.0/13
104.24.0.0/14
172.64.0.0/13
131.0.72.0/22
```

### Whitelist File Format:
```bash
# =============================================================================
# Cloudflare IPv4 Ranges - Auto-generated
# Generated: 2025-10-20 14:32:15
# Source: https://www.cloudflare.com/ips-v4
# =============================================================================

173.245.48.0/20
103.21.244.0/22
103.22.200.0/22
... (all ranges)

# =============================================================================
# Last updated: 2025-10-20 14:32:15
# Status: ENABLED - 14 IPv4 ranges
# =============================================================================
```

### nftables Integration:

**IPv4 (in table `ip nftban_v4`):**
```bash
# Ranges added to existing whitelist set
nft add element ip nftban_v4 whitelist { 173.245.48.0/20 }
nft add element ip nftban_v4 whitelist { 103.21.244.0/22 }
# ... (all ranges)
```

**IPv6 (in table `ip6 nftban_v6`):**
```bash
# Ranges added to existing whitelist set
nft add element ip6 nftban_v6 whitelist { 2400:cb00::/32 }
nft add element ip6 nftban_v6 whitelist { 2606:4700::/32 }
# ... (all ranges)
```

---

## Split Table Architecture (v0.9.0)

### Changes in v0.9.0

**Old Architecture (pre-0.9.0):**
```bash
# Single table for both IPv4 and IPv6
Table: nftban (inet family)
├── set whitelist (mixed IPv4/IPv6)
└── Cloudflare ranges added to single set
```

**New Architecture (v0.9.0+):**
```bash
# Separate tables for IPv4 and IPv6
Table: nftban_v4 (ip family)
└── set whitelist (IPv4 only)
    └── Cloudflare IPv4 ranges

Table: nftban_v6 (ip6 family)
└── set whitelist (IPv6 only)
    └── Cloudflare IPv6 ranges
```

### Benefits

1. **Performance:** Faster lookups without family checking
2. **Clarity:** Separate IPv4/IPv6 makes troubleshooting easier
3. **Flexibility:** Can enable/disable IPv4 or IPv6 independently
4. **Compatibility:** Better support for IPv4-only or IPv6-only environments

### Code Changes

```bash
# Old (pre-0.9.0):
nft add element inet nftban whitelist { 173.245.48.0/20 }

# New (v0.9.0+):
nft add element ip nftban_v4 whitelist { 173.245.48.0/20 }  # IPv4
nft add element ip6 nftban_v6 whitelist { 2400:cb00::/32 }  # IPv6
```

---

## Why Cloudflare Whitelisting is Critical

### Problem Without Whitelisting

When using Cloudflare CDN/proxy:
1. All traffic appears from Cloudflare IPs (not real client IPs)
2. NFTBan sees high volume from Cloudflare ranges
3. Rate limiting or automated banning could block Cloudflare
4. **Result:** Your entire site becomes inaccessible!

### Example Scenario

**Without Cloudflare Whitelisting:**
```
Client (1.2.3.4) → Cloudflare (104.16.0.0) → Your Server

Your server sees:
- Source IP: 104.16.0.0 (Cloudflare, not client!)
- High traffic volume from this IP
- NFTBan may ban 104.16.0.0
- Your site goes down for everyone!
```

**With Cloudflare Whitelisting:**
```
Client (1.2.3.4) → Cloudflare (104.16.0.0) → Your Server

Your server sees:
- Source IP: 104.16.0.0 (whitelisted, never banned)
- Real client IP: 1.2.3.4 (from CF-Connecting-IP header)
- NFTBan protects based on real client IP
- Cloudflare traffic always allowed
```

### Getting Real Client IPs

**Important:** Cloudflare whitelisting only solves half the problem. You must also configure your web server to read real client IPs from Cloudflare headers.

**Apache Configuration:**
```apache
# Install mod_remoteip
LoadModule remoteip_module modules/mod_remoteip.so

# Trust Cloudflare IPs
RemoteIPHeader CF-Connecting-IP
RemoteIPTrustedProxy 173.245.48.0/20
RemoteIPTrustedProxy 103.21.244.0/22
# ... (all Cloudflare ranges)
```

**Nginx Configuration:**
```nginx
# Use real_ip module
set_real_ip_from 173.245.48.0/20;
set_real_ip_from 103.21.244.0/22;
# ... (all Cloudflare ranges)

real_ip_header CF-Connecting-IP;
```

**Result:** Your logs and security tools see the real client IP (1.2.3.4), not Cloudflare's IP (104.16.0.0).

---

## Security Considerations

### Whitelist Integrity

**Protection Mechanism:**
- Cloudflare IPs automatically whitelisted
- Cannot be banned even if attack appears from these ranges
- Search module recognizes Cloudflare IPs instantly

**Risk Mitigation:**
- Only official Cloudflare ranges whitelisted (from Cloudflare.com)
- Regular updates ensure accuracy
- Cache validation prevents stale data

### Attack Vectors Requiring Cloudflare

**1. Direct IP Access Bypass**
- **Risk:** Attackers discover your origin IP, bypassing Cloudflare
- **Solution:** Firewall rules to only allow Cloudflare IPs

```bash
# Example: Block all traffic except from Cloudflare
# (Beyond NFTBan scope - use iptables/nftables directly)

# Allow Cloudflare IPv4
for range in $(cat /var/cache/nftban/cloudflare-ipv4.txt); do
    iptables -A INPUT -s $range -j ACCEPT
done

# Drop all other HTTP/HTTPS
iptables -A INPUT -p tcp --dport 80 -j DROP
iptables -A INPUT -p tcp --dport 443 -j DROP
```

**2. Cloudflare IP Spoofing**
- **Risk:** Attackers spoof Cloudflare IPs to bypass whitelist
- **Mitigation:** Impossible if proper firewall rules (only Cloudflare can reach your origin)

**3. Compromised Cloudflare Account**
- **Risk:** Attacker gains access to your Cloudflare account
- **Mitigation:** Strong Cloudflare credentials, 2FA, audit logs

### False Positive Prevention

**Scenario:** Legitimate traffic from Cloudflare appears as attack
- **Solution:** Cloudflare IPs whitelisted, never blocked
- **Additional:** Rate limiting on real client IPs (from headers), not Cloudflare IPs

---

## Performance Considerations

### Download Impact

**Bandwidth:**
- IPv4 file: ~300 bytes (14 CIDRs)
- IPv6 file: ~200 bytes (9 CIDRs)
- Total: <1 KB per update
- **Negligible impact**

**Time:**
- Download: <1 second (both files)
- Parse and apply: <1 second
- **Total: ~2 seconds**

### Memory Impact

**nftables Sets:**
- IPv4: 14 ranges = ~500 bytes
- IPv6: 9 ranges = ~400 bytes
- **Total: <1 KB**

**Cache Files:**
- IPv4 cache: <1 KB
- IPv6 cache: <1 KB
- Whitelist files: <5 KB (with headers)
- **Total: <10 KB**

### Lookup Performance

**Whitelist Check:**
- CIDR range matching: O(log n) with interval sets
- 14 IPv4 + 9 IPv6 = 23 ranges
- Typical lookup: <0.1ms
- **No measurable impact on traffic**

---

## Troubleshooting

### Problem: Download Fails

**Diagnostic Steps:**
```bash
# 1. Test connectivity to Cloudflare
ping www.cloudflare.com

# 2. Test manual download
curl -I https://www.cloudflare.com/ips-v4
curl -I https://www.cloudflare.com/ips-v6

# 3. Check firewall egress rules
iptables -L OUTPUT -v | grep -E "80|443"

# 4. Check logs
tail -50 /var/log/nftban/cloudflare.log
```

**Solutions:**
```bash
# Use cached data (automatic fallback)
# Module uses cache if download fails

# Force re-download
rm /var/cache/nftban/cloudflare-*.txt
nftban cloudflare enable

# Check proxy settings if behind corporate firewall
export http_proxy="http://proxy.example.com:8080"
export https_proxy="http://proxy.example.com:8080"
nftban_cloudflare_download_ips
```

---

### Problem: Cloudflare IPs Still Being Blocked

**Diagnostic Steps:**
```bash
# 1. Verify Cloudflare whitelisting enabled
nftban cloudflare status | grep "Status"

# 2. Check if IP is in whitelist
nftban search 104.16.0.0

# 3. Verify nftables whitelist set
nft list set ip nftban_v4 whitelist | grep "104.16"

# 4. Check whitelist file
grep "104.16" /etc/nftban/config/cloudflare-whitelist_ipsv4.conf
```

**Solutions:**
```bash
# Re-enable Cloudflare whitelisting
nftban cloudflare disable
nftban cloudflare enable

# Force reload whitelist
nftban whitelist reload

# Rebuild search index
nftban search rebuild

# Verify fix
nftban search 104.16.0.0
# Should show: ✅ WHITELISTED
```

---

### Problem: Old Cloudflare Ranges in Cache

**Diagnostic Steps:**
```bash
# Check cache age
ls -lh /var/cache/nftban/cloudflare-*.txt

# Check last update
nftban cloudflare status | grep "Age:"
```

**Solutions:**
```bash
# Force update
rm /var/cache/nftban/cloudflare-*.txt
nftban_cloudflare_download_ips

# Or just update normally
nftban cloudflare download

# Verify update
nftban cloudflare status
# Age should be 0 hours
```

---

### Problem: Auto-Update Not Working

**Diagnostic Steps:**
```bash
# Check auto-update configuration
nftban_get_config "CLOUDFLARE_AUTO_UPDATE"

# Check cron job exists
crontab -l | grep cloudflare

# Check update interval
nftban_get_config "CLOUDFLARE_UPDATE_INTERVAL"

# Test manual auto-update
nftban_cloudflare_auto_update
```

**Solutions:**
```bash
# Enable auto-update
nftban_set_config "CLOUDFLARE_AUTO_UPDATE" "true"

# Add cron job
echo "0 3 * * * /usr/local/bin/nftban cloudflare auto-update >> /var/log/nftban/cloudflare-cron.log 2>&1" | crontab -

# Verify cron job
crontab -l

# Test it works
nftban cloudflare auto-update
```

---

## Integration Points

**Called by:**
- `nftban_main_cli.sh` - For `nftban cloudflare` commands
- Cron jobs - For automatic updates
- NFTBan initialization - During system setup

**Calls:**
- `nftban_get_config()` / `nftban_set_config()` from `nftban_core.sh` - Configuration management
- `nftban_log_*()` from `nftban_core.sh` - Logging functions
- `nftban_check_nftables_table()` from `nftban_nftables_module.sh` - Table verification
- `nftban_search_build_index()` from `nftban_search_module.sh` - Search index rebuild (optional)
- External: `curl`, `nft`

**Integration Example:**
```bash
# In server provisioning script
source /usr/local/bin/nftban/lib/nftban_cloudflare_module.sh

# Setup Cloudflare protection
if [[ "$USE_CLOUDFLARE" == "true" ]]; then
    echo "Enabling Cloudflare whitelisting..."
    nftban_cloudflare_enable
    
    # Enable auto-updates
    nftban_set_config "CLOUDFLARE_AUTO_UPDATE" "true"
    
    echo "✅ Cloudflare protection configured"
fi
```

---

## Best Practices

### ✅ DO:

1. **Enable immediately** if using Cloudflare CDN/proxy
2. **Enable auto-update** for maintenance-free operation
3. **Monitor logs** after enabling (first 24 hours)
4. **Configure web server** to read real client IPs from headers
5. **Update cache monthly** minimum (or use auto-update)
6. **Verify whitelisting** with `nftban search <cloudflare-ip>`
7. **Keep firewall rules** to only allow Cloudflare origin access
8. **Test thoroughly** before going live
9. **Document configuration** for team members
10. **Monitor Cloudflare status** for IP range changes

### ❌ DON'T:

1. **Don't skip whitelisting** if behind Cloudflare (site will break!)
2. **Don't disable auto-update** without manual maintenance plan
3. **Don't forget web server config** (must read CF-Connecting-IP header)
4. **Don't whitelist manually** (use this module for automation)
5. **Don't ignore download failures** (verify connectivity)
6. **Don't expose origin IP** (defeats Cloudflare protection)
7. **Don't mix Cloudflare modes** (either all traffic or no traffic via CF)
8. **Don't skip testing** before production
9. **Don't use stale cache** (update regularly)
10. **Don't forget IPv6** (enable both IPv4 and IPv6)

---

## Maintenance Tasks

### Daily (Automated)
```bash
# Auto-update runs daily (if enabled)
# 0 3 * * * nftban cloudflare auto-update
# No manual action needed
```

### Weekly
```bash
# Check status
nftban cloudflare status

# Verify cache freshness
# Age should be < 7 days
```

### Monthly
```bash
# Force refresh (regardless of cache age)
nftban cloudflare download

# Verify applied to nftables
nft list set ip nftban_v4 whitelist | grep "173.245"

# Check logs for anomalies
tail -100 /var/log/nftban/cloudflare.log
```

### Quarterly
```bash
# Review Cloudflare integration effectiveness
# - No false positives (legitimate traffic blocked)?
# - All Cloudflare IPs whitelisted?
# - Web server reading real client IPs?

# Verify Cloudflare account security
# - Check for unauthorized access
# - Review security rules
# - Update credentials if needed
```

---

## Change Log

### Version 2.0.0 (2025-10-20) - Split Table Architecture
- **Breaking:** Migrated to split IPv4/IPv6 tables (`nftban_v4` / `nftban_v6`)
- **Breaking:** Separate whitelist files for IPv4 and IPv6
- **Added:** Independent enable/disable for IPv4 and IPv6
- **Improved:** Performance with dedicated tables
- **Improved:** Clearer separation of IPv4/IPv6 ranges
- Enhanced logging with separate Cloudflare log file
- Added comprehensive status reporting

### Version 1.x (Pre-0.9.0) - Legacy
- Single `inet` table with mixed IPv4/IPv6
- Single whitelist file for both IP versions
- Basic enable/disable functionality

---

## See Also

**Related Modules:**
- `nftban_whitelist_module.sh` - Whitelist management (Cloudflare IPs added here)
- `nftban_search_module.sh` - IP search (recognizes Cloudflare ranges)
- `nftban_nftables_module.sh` - nftables operations
- `nftban_core.sh` - Core configuration and logging

**Related Documentation:**
- Cloudflare IP Ranges: https://www.cloudflare.com/ips/
- Cloudflare Docs - Restoring Original Visitor IP: https://developers.cloudflare.com/support/troubleshooting/restoring-visitor-ips/
- NFTBan Whitelist Module Documentation
- nftables interval sets documentation

**External Resources:**
- [Cloudflare Network Map](https://www.cloudflare.com/network/) - Global presence
- [Cloudflare Status](https://www.cloudflarestatus.com/) - Service status
- [Cloudflare Community](https://community.cloudflare.com/) - Support forum

---

## Advanced Usage

### Scenario 1: Multi-CDN Setup (Cloudflare + Others)

If using multiple CDN providers (Cloudflare, Fastly, etc.):

```bash
# Enable Cloudflare whitelisting
nftban cloudflare enable

# Add other CDN ranges manually
echo "# Fastly CDN Ranges" >> /etc/nftban/config/whitelist_ips.conf
echo "151.101.0.0/16" >> /etc/nftban/config/whitelist_ips.conf
echo "199.232.0.0/16" >> /etc/nftban/config/whitelist_ips.conf

# Reload whitelist
nftban whitelist reload

# Verify both CDNs whitelisted
nftban search 104.16.0.0     # Cloudflare
nftban search 151.101.0.0    # Fastly
```

---

### Scenario 2: Cloudflare Enterprise with Custom IP Ranges

For Cloudflare Enterprise customers with dedicated IPs:

```bash
# Enable standard Cloudflare whitelisting
nftban cloudflare enable

# Add your enterprise IPs
echo "# Cloudflare Enterprise - Dedicated IPs" >> /etc/nftban/config/whitelist_ips.conf.local
echo "192.0.2.0/24  # Enterprise dedicated range" >> /etc/nftban/config/whitelist_ips.conf.local

# Reload
nftban whitelist reload
```

---

### Scenario 3: Staging/Production with Different Cloudflare Zones

Different environments with separate Cloudflare configurations:

```bash
# Production (standard Cloudflare)
nftban cloudflare enable

# Staging (may not use Cloudflare)
if [[ "$ENVIRONMENT" == "staging" ]]; then
    nftban cloudflare disable
    echo "Staging: Cloudflare whitelisting disabled"
fi
```

---

### Scenario 4: Monitoring Cloudflare Traffic

Track traffic from Cloudflare ranges:

```bash
#!/bin/bash
# monitor-cloudflare-traffic.sh

# Parse web server logs for Cloudflare IPs
cloudflare_ips=$(cat /var/cache/nftban/cloudflare-ipv4.txt)

echo "Traffic from Cloudflare ranges in last hour:"
echo "============================================="

for range in $cloudflare_ips; do
    # Extract first 3 octets for matching
    prefix=$(echo "$range" | cut -d'/' -f1 | cut -d'.' -f1-3)
    
    # Count requests
    count=$(grep "$(date -d '1 hour ago' +'%d/%b/%Y:%H')" /var/log/nginx/access.log | \
            grep -c "^${prefix}")
    
    if [[ $count -gt 0 ]]; then
        echo "Range $range: $count requests"
    fi
done
```

---

### Scenario 5: Emergency Disable (Troubleshooting)

If Cloudflare whitelisting causes issues:

```bash
# Quick disable
nftban cloudflare disable

# Verify disabled
nftban cloudflare status

# Test without Cloudflare
# (Your testing here)

# Re-enable when ready
nftban cloudflare enable
```

---

### Scenario 6: Custom Update Schedule

Different update frequency for high-security environments:

```bash
# Update every 6 hours instead of 24
nftban_set_config "CLOUDFLARE_UPDATE_INTERVAL" "21600"  # 6 hours

# Or weekly for stable environments
nftban_set_config "CLOUDFLARE_UPDATE_INTERVAL" "604800"  # 7 days

# Adjust cron accordingly
# Every 6 hours:
crontab -e
# Add: 0 */6 * * * /usr/local/bin/nftban cloudflare auto-update
```

---

## Testing Checklist

Before deploying Cloudflare whitelisting to production:

### Pre-Deployment Testing

```bash
# ✅ 1. Download test
nftban_cloudflare_download_ips
# Verify: Both IPv4 and IPv6 files downloaded

# ✅ 2. Cache verification
ls -lh /var/cache/nftban/cloudflare-*.txt
# Verify: Files exist and contain IP ranges

# ✅ 3. Whitelist file generation
cat /etc/nftban/config/cloudflare-whitelist_ipsv4.conf
# Verify: Contains IP ranges with proper headers

# ✅ 4. nftables application
nft list set ip nftban_v4 whitelist | grep "173.245"
# Verify: Cloudflare ranges present in set

# ✅ 5. Search module recognition
nftban search 104.16.0.0
# Verify: Shows as WHITELISTED

# ✅ 6. Status report
nftban cloudflare status
# Verify: All green, correct counts

# ✅ 7. Auto-update test
nftban_cloudflare_auto_update
# Verify: Runs without errors

# ✅ 8. Disable/enable cycle
nftban cloudflare disable
nftban cloudflare enable
# Verify: Both operations complete successfully
```

### Post-Deployment Monitoring

```bash
# Week 1: Daily checks
nftban cloudflare status
tail -f /var/log/nftban/cloudflare.log

# Week 2-4: Every 3 days
nftban cloudflare status

# Month 2+: Weekly
nftban cloudflare status
```

---

## Common Integration Patterns

### Pattern 1: New Server Setup

```bash
#!/bin/bash
# new-server-cloudflare-setup.sh

echo "NFTBan Cloudflare Setup for New Server"
echo "======================================="

# 1. Install NFTBan first
# (Installation steps)

# 2. Enable Cloudflare whitelisting
echo "Enabling Cloudflare whitelisting..."
nftban cloudflare enable

# 3. Configure auto-update
echo "Configuring auto-update..."
nftban_set_config "CLOUDFLARE_AUTO_UPDATE" "true"

# 4. Add cron job
echo "Adding cron job..."
(crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/nftban cloudflare auto-update") | crontab -

# 5. Configure web server
echo "⚠️  MANUAL STEP REQUIRED:"
echo "Configure your web server to read CF-Connecting-IP header"
echo ""
echo "Apache: Install mod_remoteip and configure RemoteIPHeader"
echo "Nginx: Use set_real_ip_from and real_ip_header directives"

# 6. Verify
echo ""
echo "Verifying setup..."
nftban cloudflare status

echo ""
echo "✅ Cloudflare whitelisting configured!"
```

---

### Pattern 2: Migration to Cloudflare

```bash
#!/bin/bash
# migrate-to-cloudflare.sh

echo "Migrating Server to Cloudflare"
echo "================================"

# 1. Enable Cloudflare whitelisting BEFORE changing DNS
echo "Step 1: Enable Cloudflare whitelisting..."
nftban cloudflare enable

# 2. Verify whitelisting active
echo "Step 2: Verify whitelisting..."
nftban search 104.16.0.0

if nftban search 104.16.0.0 | grep -q "WHITELISTED"; then
    echo "✅ Cloudflare IPs whitelisted"
else
    echo "❌ ERROR: Cloudflare IPs not whitelisted!"
    echo "Do not proceed with DNS change!"
    exit 1
fi

# 3. Configure web server
echo "Step 3: Configure web server (manual)..."
echo "⚠️  Update your web server config now"
read -p "Press Enter when web server configured..."

# 4. Test web server config
echo "Step 4: Testing web server config..."
# (Test commands specific to your setup)

# 5. Ready for DNS change
echo ""
echo "✅ Ready for Cloudflare DNS change"
echo ""
echo "Next steps:"
echo "1. Change DNS to point to Cloudflare"
echo "2. Monitor logs: tail -f /var/log/nginx/access.log"
echo "3. Verify real client IPs being logged"
echo "4. Check NFTBan logs: tail -f /var/log/nftban/cloudflare.log"
```

---

### Pattern 3: Automated Monitoring

```bash
#!/bin/bash
# monitor-cloudflare-health.sh

# Health check script for Cloudflare integration
# Run via cron every hour

LOG_FILE="/var/log/nftban/cloudflare-health.log"
ALERT_EMAIL="admin@example.com"

log_message() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

send_alert() {
    local subject="$1"
    local message="$2"
    echo "$message" | mail -s "$subject" "$ALERT_EMAIL"
}

# Check 1: Cloudflare enabled
cf_enabled=$(nftban_get_config "CLOUDFLARE_IPV4_WHITELIST")
if [[ "$cf_enabled" != "TRUE" ]]; then
    log_message "ALERT: Cloudflare whitelisting is DISABLED!"
    send_alert "NFTBan Alert: Cloudflare Disabled" \
               "Cloudflare whitelisting is unexpectedly disabled on $(hostname)"
fi

# Check 2: Cache age
if [[ -f /var/cache/nftban/cloudflare-ipv4.txt ]]; then
    cache_age=$(( ($(date +%s) - $(stat -c %Y /var/cache/nftban/cloudflare-ipv4.txt)) / 86400 ))
    if [[ $cache_age -gt 7 ]]; then
        log_message "WARNING: Cloudflare cache is $cache_age days old"
        send_alert "NFTBan Warning: Stale Cloudflare Cache" \
                   "Cloudflare cache is $cache_age days old on $(hostname)"
    fi
else
    log_message "ALERT: Cloudflare cache file missing!"
    send_alert "NFTBan Alert: Missing Cloudflare Cache" \
               "Cloudflare cache file is missing on $(hostname)"
fi

# Check 3: Whitelist set in nftables
cf_count=$(nft list set ip nftban_v4 whitelist 2>/dev/null | grep -c "173.245")
if [[ $cf_count -eq 0 ]]; then
    log_message "ALERT: Cloudflare IPs not in nftables whitelist!"
    send_alert "NFTBan Alert: Cloudflare Not in nftables" \
               "Cloudflare ranges missing from nftables on $(hostname)"
fi

log_message "Health check completed: OK"
```

---

## FAQ

### Q: Do I need this module?
**A:** Yes, if your server is behind Cloudflare CDN or proxy. Without it, NFTBan may block Cloudflare's IPs, breaking your site.

### Q: What if I only use Cloudflare for DNS (not proxy)?
**A:** You don't need this module. Cloudflare DNS-only mode doesn't proxy traffic, so IPs aren't changed.

### Q: Can I use this with other CDNs?
**A:** Yes, but you'll need to manually whitelist other CDN ranges. This module only handles Cloudflare.

### Q: How often do Cloudflare IP ranges change?
**A:** Rarely. Typically 2-4 times per year. The 24-hour default update interval is very conservative.

### Q: What happens if Cloudflare download fails?
**A:** The module uses cached data automatically. No action needed unless cache is also missing.

### Q: Can I disable IPv6 support?
**A:** Yes. Set `CLOUDFLARE_IPV6_WHITELIST="FALSE"` in configuration. IPv4 will still work.

### Q: How much memory does this use?
**A:** Minimal. ~1 KB in nftables, ~10 KB for cache files. Negligible impact.

### Q: Will this slow down my site?
**A:** No. Whitelist lookups are O(log n) and take <0.1ms. No measurable impact.

### Q: What if I stop using Cloudflare?
**A:** Run `nftban cloudflare disable` to remove whitelisting and clean up files.

### Q: Can I test before enabling?
**A:** Yes. Review cached files after `nftban_cloudflare_download_ips` before enabling.

---

## Summary

The Cloudflare Module is **essential** for any server behind Cloudflare CDN/proxy. Key points:

**Critical Requirements:**
- ✅ Enable if using Cloudflare proxy/CDN
- ✅ Configure web server to read CF-Connecting-IP header  
- ✅ Enable auto-update for maintenance-free operation
- ✅ Verify whitelisting with `nftban search <cloudflare-ip>`
- ✅ Monitor logs after enabling

**Benefits:**
- Prevents accidental blocking of Cloudflare IPs
- Automatic synchronization with Cloudflare's official ranges
- Split IPv4/IPv6 support (v0.9.0)
- Zero-maintenance with auto-update
- Comprehensive status monitoring

**Commands:**
```bash
# Essential operations
nftban cloudflare enable      # Enable (required!)
nftban cloudflare status       # Check status
nftban cloudflare download     # Update ranges
nftban cloudflare disable      # Disable if needed

# Automation
nftban cloudflare auto-update  # For cron
```

Without this module, using Cloudflare with NFTBan **will break your site**. Always enable before pointing DNS to Cloudflare!