# NFTBan Cloudflare Module

**Module:** `nftban_cloudflare_module.sh` | **Version:** 0.9.3-dev | **Location:** `/usr/local/lib/nftban/`

## Overview

The Cloudflare Module automatically downloads and whitelists Cloudflare's IP ranges to prevent blocking legitimate traffic when using Cloudflare as a CDN/proxy. It maintains separate IPv4 and IPv6 whitelist files with automatic updates.

### Key Features

- **Auto-Download**: Fetches official Cloudflare IP ranges from cloudflare.com
- **Dual-Stack Support**: Separate IPv4/IPv6 management (split table architecture)
- **Auto-Update**: Configurable update intervals (default: 24 hours)
- **Whitelist Integration**: Automatic integration with NFTBan whitelist system
- **nftables Sync**: Direct application to nftables whitelist sets
- **Search Index Integration**: Automatic index rebuild after updates

### Dependencies

- **curl**: For downloading Cloudflare IP ranges
- **Whitelist Module**: For whitelist file integration

---

## API Reference

### Download Functions

**`nftban_cloudflare_download_ips()`** - Download Cloudflare IP ranges
```bash
nftban cloudflare update
# Downloading Cloudflare IP ranges...
#   Downloading IPv4 ranges...
#   Downloaded 14 IPv4 ranges
#   Downloading IPv6 ranges...
#   Downloaded 17 IPv6 ranges
# Cloudflare IP ranges downloaded successfully
```
- **Sources**:
  - IPv4: https://www.cloudflare.com/ips-v4
  - IPv6: https://www.cloudflare.com/ips-v6
- **Cache files**:
  - `/var/cache/nftban/cloudflare-ipv4.txt`
  - `/var/cache/nftban/cloudflare-ipv6.txt`

**`nftban_cloudflare_update_whitelist()`** - Update whitelist files
```bash
# Automatically called after download
# Creates:
# - /etc/nftban/config/cloudflare-whitelist_ipsv4.conf
# - /etc/nftban/config/cloudflare-whitelist_ipsv6.conf
```

### Enable/Disable Functions

**`nftban_cloudflare_enable()`** - Enable Cloudflare whitelisting
```bash
nftban cloudflare enable
# Enabling Cloudflare whitelisting...
# Downloading Cloudflare IP ranges...
# Cloudflare whitelisting enabled (IPv4 and IPv6)
```
- **Actions**:
  1. Sets `CLOUDFLARE_IPV4_WHITELIST="TRUE"`
  2. Sets `CLOUDFLARE_IPV6_WHITELIST="TRUE"`
  3. Downloads IP ranges
  4. Updates whitelist files
  5. Applies to nftables

**`nftban_cloudflare_disable()`** - Disable Cloudflare whitelisting
```bash
nftban cloudflare disable
# Disabling Cloudflare whitelisting...
# Removed Cloudflare ranges: 14 IPv4, 17 IPv6
# Cloudflare whitelisting disabled (IPv4 and IPv6)
```
- **Actions**:
  1. Sets config to "FALSE"
  2. Clears whitelist files (keeps template)
  3. Removes from nftables
  4. Rebuilds search index

### nftables Integration

**`nftban_cloudflare_apply_to_nftables()`** - Apply ranges to nftables
```bash
# Applying Cloudflare ranges to nftables...
#   Added 14 IPv4 ranges to nftables
#   Added 17 IPv6 ranges to nftables
# Cloudflare ranges applied to nftables
```
- **Target sets**: `ip nftban_v4 whitelist`, `ip6 nftban_v6 whitelist`

**`nftban_cloudflare_remove_from_nftables()`** - Remove from nftables
```bash
# Removed Cloudflare ranges: 14 IPv4, 17 IPv6
```

### Status & Monitoring

**`nftban_cloudflare_status()`** - Show status
```bash
nftban cloudflare status

# === Cloudflare Integration Status ===
#
# Status: true
# Auto-update: true
# Update interval: 24 hours
#
# IPv4 Ranges:
#   Count: 14
#   Age: 3 hours
#   File: /var/cache/nftban/cloudflare-ipv4.txt
#
# IPv6 Ranges:
#   Count: 17
#   Age: 3 hours
#   File: /var/cache/nftban/cloudflare-ipv6.txt
#
# Whitelist IPv4 file:
#   Ranges: 14
#   File: /etc/nftban/config/cloudflare-whitelist_ipsv4.conf
#
# Whitelist IPv6 file:
#   Ranges: 17
#   File: /etc/nftban/config/cloudflare-whitelist_ipsv6.conf
#
# Recent Activity (last 5):
#   [2025-10-22 14:30:15] IPv4 ranges updated: 14 entries
#   [2025-10-22 14:30:16] IPv6 ranges updated: 17 entries
#   [2025-10-22 14:30:18] Applied to nftables: 14 IPv4, 17 IPv6
```

**`nftban_cloudflare_needs_update()`** - Check if update needed
```bash
if nftban_cloudflare_needs_update; then
    echo "Update required"
fi
```
- **Checks**:
  - Cache file age vs update interval
  - Missing cache files
  - Returns 0 if update needed, 1 otherwise

**`nftban_cloudflare_auto_update()`** - Auto-update (for cron)
```bash
# Called by cron hourly
# Updates only if cache expired
nftban_cloudflare_auto_update
```

---

## Configuration

**Global Settings** (`/etc/nftban/nftban.conf`):
```bash
# Enable/disable Cloudflare integration
CLOUDFLARE_ENABLED="true"

# Enable IPv4/IPv6 whitelisting
CLOUDFLARE_IPV4_WHITELIST="TRUE"
CLOUDFLARE_IPV6_WHITELIST="TRUE"

# Auto-update settings
CLOUDFLARE_AUTO_UPDATE="true"
CLOUDFLARE_UPDATE_INTERVAL="86400"  # 24 hours in seconds

# Download URLs (usually don't need to change)
CLOUDFLARE_IPV4_URL="https://www.cloudflare.com/ips-v4"
CLOUDFLARE_IPV6_URL="https://www.cloudflare.com/ips-v6"

# Whitelist file paths
CLOUDFLARE_IPV4_WHITELIST_FILE="/etc/nftban/config/cloudflare-whitelist_ipsv4.conf"
CLOUDFLARE_IPV6_WHITELIST_FILE="/etc/nftban/config/cloudflare-whitelist_ipsv6.conf"
```

**Cache Files**:
```
/var/cache/nftban/cloudflare-ipv4.txt
/var/cache/nftban/cloudflare-ipv6.txt
```

**Whitelist Files**:
```
/etc/nftban/config/cloudflare-whitelist_ipsv4.conf
/etc/nftban/config/cloudflare-whitelist_ipsv6.conf
```

**Log File**:
```
/var/log/nftban/cloudflare.log
```

---

## CLI Integration

```bash
# Enable Cloudflare whitelisting
nftban cloudflare enable

# Disable Cloudflare whitelisting
nftban cloudflare disable

# Update IP ranges manually
nftban cloudflare update

# Show status
nftban cloudflare status

# Check if update needed (returns exit code)
nftban cloudflare needs-update
```

---

## Automatic Updates

### cron Setup

Add to `/etc/cron.hourly/nftban-cloudflare`:
```bash
#!/bin/bash
/usr/local/bin/nftban cloudflare auto-update
```

Or add to root crontab:
```bash
# Update Cloudflare IPs hourly
0 * * * * /usr/local/bin/nftban cloudflare auto-update >> /var/log/nftban/cloudflare-cron.log 2>&1
```

### systemd Timer

Create `/etc/systemd/system/nftban-cloudflare.service`:
```ini
[Unit]
Description=NFTBan Cloudflare IP Update
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nftban cloudflare auto-update
User=root
```

Create `/etc/systemd/system/nftban-cloudflare.timer`:
```ini
[Unit]
Description=NFTBan Cloudflare IP Update Timer

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
```

Enable:
```bash
systemctl daemon-reload
systemctl enable --now nftban-cloudflare.timer
```

---

## Testing

### Test 1: Download and Enable

```bash
# Enable Cloudflare
nftban cloudflare enable

# Verify download
cat /var/cache/nftban/cloudflare-ipv4.txt
# Should show ~14 CIDR ranges

cat /var/cache/nftban/cloudflare-ipv6.txt
# Should show ~17 CIDR ranges

# Check whitelist files
grep -v '^#' /etc/nftban/config/cloudflare-whitelist_ipsv4.conf | head -5
```

### Test 2: nftables Integration

```bash
# Enable Cloudflare
nftban cloudflare enable

# Check nftables whitelist set
nft list set ip nftban_v4 whitelist | grep 173.245
# Should show Cloudflare ranges (173.245.48.0/20, etc.)

nft list set ip6 nftban_v6 whitelist | grep 2400:cb00
# Should show Cloudflare IPv6 ranges
```

### Test 3: Auto-Update

```bash
# Set short interval for testing
echo 'CLOUDFLARE_UPDATE_INTERVAL="60"' >> /etc/nftban/nftban.conf

# Touch cache to make it old
touch -d '2 hours ago' /var/cache/nftban/cloudflare-ipv4.txt

# Check if update needed
if nftban_cloudflare_needs_update; then
    echo "Update required (as expected)"
fi

# Run auto-update
nftban cloudflare auto-update

# Verify new timestamp
ls -l /var/cache/nftban/cloudflare-ipv4.txt
```

### Test 4: Disable and Cleanup

```bash
# Disable
nftban cloudflare disable

# Verify whitelist files cleared
grep -v '^#' /etc/nftban/config/cloudflare-whitelist_ipsv4.conf
# Should be empty (only comments)

# Verify removed from nftables
nft list set ip nftban_v4 whitelist | grep 173.245
# Should not appear
```

---

## Troubleshooting

### Issue 1: Download Fails

**Symptoms**: `Failed to download IPv4 ranges`

**Solutions**:
```bash
# Test connectivity
curl -v https://www.cloudflare.com/ips-v4

# Check DNS
nslookup www.cloudflare.com

# Check firewall
iptables -L OUTPUT -v -n | grep 443

# Manual download
curl -o /tmp/cf-ips.txt https://www.cloudflare.com/ips-v4
```

### Issue 2: Cache Not Updating

**Symptoms**: Old IP ranges, update doesn't run

**Solutions**:
```bash
# Check auto-update enabled
grep CLOUDFLARE_AUTO_UPDATE /etc/nftban/nftban.conf

# Manual update
nftban cloudflare update

# Check cron/timer
systemctl status nftban-cloudflare.timer
crontab -l | grep cloudflare

# Force update
rm /var/cache/nftban/cloudflare-*.txt
nftban cloudflare enable
```

### Issue 3: Whitelist Not Applied

**Symptoms**: Cloudflare IPs still being blocked

**Solutions**:
```bash
# Check whitelist files exist and have IPs
cat /etc/nftban/config/cloudflare-whitelist_ipsv4.conf

# Check nftables whitelist set
nft list set ip nftban_v4 whitelist

# Reapply to nftables
nftban_cloudflare_apply_to_nftables

# Rebuild search index
nftban search rebuild
```

### Issue 4: Duplicate Entries

**Symptoms**: Same IP ranges multiple times

**Solutions**:
```bash
# Disable and re-enable
nftban cloudflare disable
nftban cloudflare enable

# Or flush and reapply
nft flush set ip nftban_v4 whitelist
nft flush set ip6 nftban_v6 whitelist
nftban whitelist reload
```

---

## Security Considerations

### Whitelist Scope

**Important**: Whitelisting Cloudflare IPs means:
- ✅ Cloudflare proxy traffic **will not be blocked**
- ⚠️ Direct attacks from Cloudflare IPs **will not be blocked**
- ⚠️ Compromised Cloudflare accounts **could bypass protection**

**Recommendation**: Only enable if using Cloudflare as CDN/proxy

### Verification

Always verify Cloudflare IP ranges from official source:
```bash
# Official Cloudflare IP list
curl https://www.cloudflare.com/ips-v4
curl https://www.cloudflare.com/ips-v6

# Compare with cache
diff <(curl -s https://www.cloudflare.com/ips-v4) /var/cache/nftban/cloudflare-ipv4.txt
```

### Update Frequency

- **Default**: 24 hours (Cloudflare rarely changes IPs)
- **Aggressive**: 6 hours (for critical systems)
- **Conservative**: 7 days (for stable deployments)

---

## Integration with Other Modules

### With Whitelist Module

Cloudflare ranges automatically added to whitelist:
```bash
nftban cloudflare enable
# Whitelist files updated → Search index rebuilt → Whitelist active
```

### With Search Module

Search index automatically rebuilt after Cloudflare updates:
```bash
nftban search 104.16.0.1
# IP 104.16.0.1 found in: cloudflare-whitelist_ipsv4.conf
```

### With Blacklist Module

Cloudflare IPs cannot be banned (whitelist priority):
```bash
nftban blacklist ban 104.16.0.1
# ⚠️ BLOCKED: Cannot ban whitelisted IP
```

---

## Best Practices

1. **Verify Cloudflare Usage**:
   - Only enable if actually using Cloudflare as CDN
   - Disable if Cloudflare not in use (reduces whitelist size)

2. **Monitor Updates**:
   ```bash
   tail -f /var/log/nftban/cloudflare.log
   ```

3. **Test After Enabling**:
   ```bash
   # Test Cloudflare IP not blocked
   nftban search 104.16.0.1
   # Should show: whitelisted
   ```

4. **Automatic Updates**:
   - Enable auto-update for production
   - Set 24-hour interval (Cloudflare IPs stable)

5. **Backup Whitelist**:
   ```bash
   cp /etc/nftban/config/cloudflare-whitelist_ipsv4.conf /backup/
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
