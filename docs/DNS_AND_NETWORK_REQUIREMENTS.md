# DNS and Network Requirements for NFTBan

**Version:** v0.31.0
**Priority:** CRITICAL for network-dependent features
**Audience:** System administrators, junior sysadmins

---

## 🚨 Critical Issue: DNS is Required

**Many NFTBan features require working DNS resolution** to download external resources:
- ✅ **Cloudflare** - Downloads IP ranges from cloudflare.com
- ✅ **Threat Feeds** - Downloads from spamhaus.org, greensnow.co, etc.
- ✅ **GeoBan** - Downloads country IPs from ipdeny.com
- ✅ **GeoIP Updates** - Downloads MaxMind database

**If DNS is broken, these features SILENTLY FAIL.**

---

## 🔍 Problem Discovery

### What Happened on Lab Server

**Symptoms:**
- `nftban cloudflare update` - Failed silently
- `nftban feeds update` - Timed out
- `nftban geoip ban CN` - "Cannot resolve ipdeny.com"

**Root Cause:**
```bash
$ cat /etc/resolv.conf
# Empty file or missing!

$ nslookup cloudflare.com
;; connection timed out; no servers could be reached
```

**Impact:**
- Junior sysadmins don't understand why features fail
- No clear error message pointing to DNS
- Wastes hours troubleshooting the wrong thing

---

## ✅ Solution: DNS Health Check

### New Health Check Feature

NFTBan now includes a **DNS Health Check** that:
1. ✅ Checks if `/etc/resolv.conf` exists
2. ✅ Counts configured nameservers
3. ✅ Tests DNS resolution with common domains
4. ✅ Analyzes IPv4 vs IPv6 DNS servers
5. ✅ **Provides clear warnings when DNS is broken**
6. ✅ **Offers to fix DNS automatically** (with user permission)

### Usage

**Check DNS status:**
```bash
nftban health check

# Output includes:
# [INFO] DNS: Checking DNS resolution...
# [WARN] DNS: Only 0 nameservers configured in /etc/resolv.conf
# [FAIL] DNS: Cannot resolve cloudflare.com
# [FAIL] DNS: Cannot resolve google.com
#
# ⚠️  DNS RESOLUTION IS BROKEN
#
# This will cause failures in:
#   - Cloudflare IP updates
#   - Threat feed downloads
#   - GeoBan country downloads
#   - GeoIP database updates
#
# Run: nftban health fix-dns
```

**Auto-fix DNS:**
```bash
nftban health fix-dns

# Adds reliable DNS servers to /etc/resolv.conf:
#   nameserver 1.1.1.1       # Cloudflare DNS
#   nameserver 8.8.8.8       # Google DNS
#   nameserver 2606:4700:4700::1111  # Cloudflare IPv6
```

**Auto-heal mode:**
```bash
nftban health check --auto-heal

# Automatically fixes DNS if broken
# No user interaction required
```

---

## 🛠️ Manual DNS Fix

### Step 1: Check Current DNS

```bash
cat /etc/resolv.conf

# Should see lines like:
# nameserver 8.8.8.8
# nameserver 1.1.1.1
```

### Step 2: Test DNS Resolution

```bash
# Test with dig
dig cloudflare.com

# Test with nslookup
nslookup cloudflare.com

# Test with host
host cloudflare.com

# If ALL fail → DNS is broken
```

### Step 3: Add Reliable DNS Servers

**Temporary Fix (until reboot):**
```bash
echo "nameserver 1.1.1.1" >> /etc/resolv.conf
echo "nameserver 8.8.8.8" >> /etc/resolv.conf
```

**Permanent Fix (Rocky Linux / CentOS / RHEL):**
```bash
# Edit NetworkManager connection
nmcli con mod <connection-name> ipv4.dns "1.1.1.1 8.8.8.8"
nmcli con mod <connection-name> ipv6.dns "2606:4700:4700::1111"
nmcli con up <connection-name>

# Find connection name:
nmcli con show
```

**Permanent Fix (Ubuntu / Debian with systemd-resolved):**
```bash
# Edit /etc/systemd/resolved.conf
[Resolve]
DNS=1.1.1.1 8.8.8.8
FallbackDNS=2606:4700:4700::1111

# Restart
systemctl restart systemd-resolved
```

**Permanent Fix (Old systems with /etc/resolv.conf):**
```bash
# Make it immutable so NetworkManager doesn't overwrite
chattr +i /etc/resolv.conf

# Or configure NetworkManager to not manage DNS:
echo "dns=none" >> /etc/NetworkManager/NetworkManager.conf
systemctl restart NetworkManager
```

### Step 4: Verify Fix

```bash
# Test resolution
dig cloudflare.com

# Should see:
# ;; ANSWER SECTION:
# cloudflare.com.  60  IN  A  104.16.132.229

# Test with NFTBan
nftban health check

# Should see:
# [PASS] DNS: 2 nameservers configured
# [PASS] DNS: Can resolve cloudflare.com
# [PASS] DNS: Can resolve google.com
```

---

## 📋 Recommended DNS Servers

### Cloudflare DNS (Recommended)

**Best for:** Privacy, speed, reliability
**IPv4:** 1.1.1.1, 1.0.0.1
**IPv6:** 2606:4700:4700::1111, 2606:4700:4700::1001

**Pros:**
- ✅ Fastest (usually)
- ✅ Privacy-focused (no logging)
- ✅ Anycast (routes to nearest server)
- ✅ Supports DoH/DoT
- ✅ Free

**Cons:**
- ⚠️ Blocks some malware/phishing domains (configurable)

### Google Public DNS

**Best for:** Reliability, compatibility
**IPv4:** 8.8.8.8, 8.8.4.4
**IPv6:** 2001:4860:4860::8888, 2001:4860:4860::8844

**Pros:**
- ✅ Extremely reliable
- ✅ High availability (99.99%+)
- ✅ Works everywhere
- ✅ Free

**Cons:**
- ⚠️ Google logs queries (privacy concern)

### Quad9 DNS (Security-Focused)

**Best for:** Security, malware blocking
**IPv4:** 9.9.9.9, 149.112.112.112
**IPv6:** 2620:fe::fe, 2620:fe::9

**Pros:**
- ✅ Blocks malware/phishing domains
- ✅ Privacy-focused
- ✅ Free

**Cons:**
- ⚠️ Slower than Cloudflare/Google
- ⚠️ Blocks some domains (could break things)

### Your ISP's DNS

**Best for:** Local caching, compliance
**Find it:** `nmcli dev show | grep DNS`

**Pros:**
- ✅ Already configured
- ✅ Faster for local domains
- ✅ Required for some ISP features (parental controls, etc.)

**Cons:**
- ⚠️ May be slow/unreliable
- ⚠️ May log/inject ads
- ⚠️ May have government restrictions

---

## 🧪 Testing Network-Dependent Features

### Test 1: Cloudflare

```bash
# Enable Cloudflare
nftban cloudflare enable

# Update manually
nftban cloudflare update

# Expected output:
# [INFO] Downloading Cloudflare IPv4 ranges...
# [INFO] Downloaded 18 IPv4 ranges
# [INFO] Downloading Cloudflare IPv6 ranges...
# [INFO] Downloaded 6 IPv6 ranges
# [PASS] Cloudflare IPs updated successfully

# If DNS broken:
# [FAIL] Cannot resolve www.cloudflare.com
# [FAIL] curl: (6) Could not resolve host: www.cloudflare.com
```

### Test 2: Threat Feeds

```bash
# Enable a test feed
nftban feeds enable SPAMHAUS_DROP

# Update
nftban feeds update

# Expected output:
# [INFO] Downloading Spamhaus DROP...
# [INFO] Parsed 1,024 IPs
# [PASS] Feed updated successfully

# If DNS broken:
# [FAIL] Cannot resolve www.spamhaus.org
```

### Test 3: GeoBan

```bash
# Fetch a small country
nftban geoip ban VA  # Vatican City

# Expected output:
# Fetching IP ranges for country: VA
#   IPv4: 4 ranges
#   IPv6: 3 ranges
# ✅ Successfully ban VA

# If DNS broken:
# ERROR: Cannot resolve www.ipdeny.com
# fetch failed: lookup www.ipdeny.com: no such host
```

### Test 4: GeoIP Database Update

```bash
# Update MaxMind database
nftban geoip update

# Expected output:
# [INFO] Downloading GeoLite2-City.mmdb...
# [INFO] Downloaded 70MB
# [PASS] Database updated

# If DNS broken:
# [FAIL] Cannot resolve download.maxmind.com
```

---

## 📊 DNS Health Check Implementation

### Function: `nftban_health_check_dns()`

**Location:** `/usr/lib/nftban/core/nftban_health.sh`

**What it checks:**

1. **Resolv.conf exists**
   ```bash
   if [[ ! -f /etc/resolv.conf ]]; then
       FAIL "DNS: /etc/resolv.conf missing"
   fi
   ```

2. **Nameservers configured**
   ```bash
   nameserver_count=$(grep -c "^nameserver" /etc/resolv.conf)
   if [[ $nameserver_count -eq 0 ]]; then
       FAIL "DNS: No nameservers configured"
   fi
   ```

3. **Can resolve common domains**
   ```bash
   for domain in cloudflare.com google.com github.com; do
       if ! host "$domain" >/dev/null 2>&1; then
           FAIL "DNS: Cannot resolve $domain"
       fi
   done
   ```

4. **IPv6 DNS support**
   ```bash
   if ! host -6 google.com >/dev/null 2>&1; then
       WARN "DNS: IPv6 resolution not working"
   fi
   ```

**Exit codes:**
- `0` - DNS working perfectly
- `1` - DNS partially broken (warnings)
- `2` - DNS completely broken (failures)

---

## 🎓 Educational: Why DNS Matters

### For Junior Sysadmins

**Q: Why can't NFTBan just use IP addresses?**

A: Security. IP addresses change frequently:
- Cloudflare uses 100+ IPs (Anycast)
- Feeds move to new servers
- IPdeny.com could change hosting
- MaxMind uses CDN (different IPs per region)

**Q: Can I disable DNS-dependent features?**

A: Yes! Set these to `false`:
```bash
# /etc/nftban/conf.d/cloudflare.conf.local
CLOUDFLARE_ENABLED="false"

# /etc/nftban/conf.d/feeds.conf.local
FEEDS_ENABLED="false"

# /etc/nftban/conf.d/nftban-go.conf.local
GEOBAN_ENABLED="false"
GEOIP_AUTO_UPDATE="false"
```

**Q: What if my server has no internet access?**

A: Use **offline mode**:
1. Download IP lists on a connected machine
2. Copy to air-gapped server
3. Load manually:
   ```bash
   nftban ban file --file /path/to/ips.txt
   ```

**Q: What if I'm behind a firewall?**

A: Configure proxy:
```bash
# /etc/environment
http_proxy="http://proxy.company.com:8080"
https_proxy="http://proxy.company.com:8080"
no_proxy="localhost,127.0.0.1"

# Reload
source /etc/environment
```

---

## ⚠️ Common DNS Problems

### Problem 1: Empty /etc/resolv.conf

**Symptom:**
```bash
$ cat /etc/resolv.conf
# Empty or comments only
```

**Cause:** NetworkManager or systemd-resolved not configured

**Fix:**
```bash
# Quick fix
echo "nameserver 1.1.1.1" > /etc/resolv.conf

# Permanent fix - see "Step 3: Add Reliable DNS Servers" above
```

### Problem 2: Localhost in resolv.conf

**Symptom:**
```bash
$ cat /etc/resolv.conf
nameserver 127.0.0.1
```

**Cause:** systemd-resolved stub resolver

**Fix:**
```bash
# Symlink to real resolv.conf
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
```

### Problem 3: DNS Works But NFTBan Fails

**Symptom:**
```bash
$ dig cloudflare.com
# Works!

$ nftban cloudflare update
# [FAIL] Cannot resolve www.cloudflare.com
```

**Cause:** SELinux or AppArmor blocking network access

**Fix:**
```bash
# Check SELinux denials
ausearch -m avc -ts recent

# Temporarily disable (for testing)
setenforce 0

# If that fixes it, create policy:
audit2allow -a -M nftban_network
semodule -i nftban_network.pp
setenforce 1
```

### Problem 4: IPv6 DNS Broken

**Symptom:**
```bash
$ dig -6 google.com
# Timeout or error
```

**Cause:** IPv6 not configured or disabled

**Fix:**
```bash
# Check if IPv6 enabled
ip -6 addr show

# If no IPv6 addresses, disable IPv6 features:
# /etc/nftban/conf.d/cloudflare.conf.local
CLOUDFLARE_IPV6_ENABLED="false"
```

### Problem 5: Corporate DNS Filtering

**Symptom:**
- Some domains resolve, others don't
- `ipdeny.com` blocked but `google.com` works

**Cause:** Corporate DNS filters "security" domains

**Fix:**
```bash
# Use alternative DNS (Cloudflare, Google)
# See "Step 3: Add Reliable DNS Servers" above

# Or contact IT to whitelist:
#   - ipdeny.com (for GeoBan)
#   - spamhaus.org (for feeds)
#   - maxmind.com (for GeoIP)
```

---

## 🔒 Security Considerations

### DNS Hijacking

**Risk:** ISP/government could hijack DNS to block features

**Mitigation:**
```bash
# Use DNS over HTTPS (DoH)
# Install stubby (DNS privacy daemon)
dnf install stubby -y
systemctl enable --now stubby

# Configure resolv.conf to use stubby
echo "nameserver 127.0.0.1" > /etc/resolv.conf
chattr +i /etc/resolv.conf
```

### DNS Spoofing

**Risk:** Attacker could spoof DNS to redirect downloads

**Mitigation:**
- ✅ NFTBan validates SSL certificates (HTTPS)
- ✅ Uses ETag caching (detects tampering)
- ✅ Validates IP count ranges (detects fake lists)

### DNS Logging

**Risk:** DNS provider logs all your queries

**Mitigation:**
- Use Cloudflare 1.1.1.1 (privacy-focused)
- Use Quad9 (doesn't log)
- Avoid Google DNS (logs everything)
- Use DoH/DoT for encryption

---

## 📈 Monitoring DNS Health

### Proactive Monitoring

**Add to cron:**
```bash
# /etc/cron.daily/nftban-dns-check
#!/bin/bash
if ! nftban health check-dns --silent; then
    echo "DNS is broken!" | mail -s "NFTBan DNS Alert" admin@example.com
fi
```

**Add to systemd timer:**
```ini
# /etc/systemd/system/nftban-dns-check.timer
[Unit]
Description=NFTBan DNS Health Check

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
```

**Check logs:**
```bash
# DNS-related errors in main log
grep "DNS\|resolve\|timeout" /var/log/nftban/nftban.log

# Go operations log (feeds, geoban)
grep "DNS\|resolve\|lookup" /var/log/nftban/go-operations.log
```

---

## 🎯 Quick Reference

### Essential Commands

| Command | Purpose |
|---------|---------|
| `nftban health check` | Check DNS status |
| `nftban health fix-dns` | Auto-fix DNS |
| `cat /etc/resolv.conf` | View DNS servers |
| `dig cloudflare.com` | Test DNS resolution |
| `nslookup google.com` | Alternative DNS test |
| `systemctl status systemd-resolved` | Check systemd-resolved |

### Essential Files

| File | Purpose |
|------|---------|
| `/etc/resolv.conf` | DNS configuration |
| `/etc/systemd/resolved.conf` | systemd-resolved config |
| `/etc/NetworkManager/NetworkManager.conf` | NetworkManager DNS config |
| `/var/log/nftban/nftban.log` | NFTBan main log |
| `/var/log/nftban/go-operations.log` | Go operations log |

### Reliable DNS Servers

| Provider | IPv4 | IPv6 | Privacy |
|----------|------|------|---------|
| Cloudflare | 1.1.1.1 | 2606:4700:4700::1111 | ⭐⭐⭐ |
| Google | 8.8.8.8 | 2001:4860:4860::8888 | ⭐ |
| Quad9 | 9.9.9.9 | 2620:fe::fe | ⭐⭐⭐ |

---

## 📚 Related Documentation

- **[INDEX.md](INDEX.md)** - Documentation index
- **[GEOBAN_FEATURE.md](GEOBAN_FEATURE.md)** - GeoBan requires DNS
- **[GO_SYSTEM_PROTECTION.md](GO_SYSTEM_PROTECTION.md)** - Network protection
- **[CONFIGURATION_LOCATIONS.md](CONFIGURATION_LOCATIONS.md)** - Config file locations

---

**Last Updated:** 2025-11-06
**Maintained By:** NFTBan Development Team
**License:** MPL-2.0
