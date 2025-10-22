# NFTBan GeoIP Lookup Module

**Module:** `nftban_geoip_module.sh` | **Version:** 0.9.3-dev | **Location:** `/usr/local/lib/nftban/`

## Overview

The GeoIP Lookup Module provides real-time IP address geolocation with multiple provider fallback and intelligent caching. It queries free GeoIP APIs to retrieve country, city, ISP, and threat intelligence data for any IP address, supporting audit trails, threat analysis, and geographic access monitoring.

### Key Features

- **Multiple Providers**: Auto-failover through 4 free GeoIP APIs (ip-api.com, ipinfo.io, ipapi.co, freegeoip.app)
- **Intelligent Caching**: 24-hour TTL cache to minimize API calls and improve performance
- **Local Database Support**: Integrates with `geoiplookup` command if MaxMind databases installed
- **Bulk Lookups**: Process lists of IPs from files with rate limiting
- **Formatted Output**: JSON, human-readable, and compact formats for different use cases
- **Threat Intelligence**: Detects mobile, proxy, and hosting IPs (provider-dependent)
- **Zero Cost**: Uses free APIs with no authentication required

### Dependencies

- **Core Module**: `nftban_core.sh`
- **curl**: For API queries (required)
- **python3**: For JSON parsing and formatted output (optional)
- **geoiplookup**: For local database queries (optional)

---

## API Reference

### Lookup Functions

**`nftban_geoip_lookup(ip, [force_refresh])`** - Query GeoIP with caching
```bash
result=$(nftban_geoip_lookup "1.2.3.4")
echo "$result"
# {"ip":"1.2.3.4","country":"China","countryCode":"CN","city":"Beijing","isp":"China Telecom"}
```
- **Parameters**:
  - `ip`: IP address to lookup
  - `force_refresh`: "true" to bypass cache (default: false)
- **Returns**: JSON object with geolocation data
- **Caching**: 24-hour TTL, MD5-hashed filenames
- **Fallback order**: Local DB → ip-api.com → ipinfo.io → ipapi.co → freegeoip.app
- **Logged**: All lookups logged to `/var/log/nftban/geoip-lookup.log`

**`nftban_geoip_get_formatted(ip)`** - Human-readable output
```bash
nftban geoip lookup 8.8.8.8

# Output:
# IP: 8.8.8.8
# Country: United States (US)
# Region: California
# City: Mountain View
# ISP: Google LLC
# ASN: AS15169 Google LLC
# Flags: Hosting
```
- **Use case**: Interactive CLI usage, log analysis
- **Requires**: python3 for parsing

**`nftban_geoip_get_compact(ip)`** - One-line compact format
```bash
compact=$(nftban_geoip_get_compact "203.0.113.50")
echo "$compact"
# Output: China/Beijing/China_Telecom
```
- **Format**: `Country/City/ISP`
- **Use case**: Log entries, CSV exports, scripts
- **Spaces replaced**: Underscores for parsing

---

### Provider-Specific Functions

**`nftban_geoip_query_ipapi(ip)`** - Query ip-api.com (primary provider)
```bash
result=$(nftban_geoip_query_ipapi "1.2.3.4")
```
- **API**: http://ip-api.com/json/{ip}
- **Fields**: country, countryCode, region, city, isp, org, as, mobile, proxy, hosting
- **Rate limit**: 45 requests/minute (free tier)
- **Timeout**: 3 seconds

**`nftban_geoip_query_ipinfo(ip)`** - Query ipinfo.io (fallback 1)
- **API**: https://ipinfo.io/{ip}/json
- **Requires**: HTTPS (encrypted)
- **Rate limit**: 50,000 requests/month

**`nftban_geoip_query_ipapico(ip)`** - Query ipapi.co (fallback 2)
- **API**: https://ipapi.co/{ip}/json/
- **Rate limit**: 1,000 requests/day

**`nftban_geoip_query_freegeoip(ip)`** - Query freegeoip.app (fallback 3)
- **API**: https://freegeoip.app/json/{ip}
- **Rate limit**: 15,000 requests/hour

**`nftban_geoip_query_local(ip)`** - Query local MaxMind database
```bash
# Requires geoiplookup command
apt-get install geoip-bin geoip-database   # Debian/Ubuntu
yum install GeoIP GeoIP-data               # RHEL/CentOS

result=$(nftban_geoip_query_local "8.8.8.8")
# {"ip":"8.8.8.8","country":"United States","source":"local"}
```
- **Advantage**: No API calls, unlimited queries, offline operation
- **Disadvantage**: Requires manual database installation and updates

---

### Cache Management

**`nftban_geoip_init()`** - Initialize cache directory
```bash
nftban_geoip_init
# Creates /var/cache/nftban/geoip/
```

**`nftban_geoip_get_cache_file(ip)`** - Get cache file path for IP
```bash
cache_file=$(nftban_geoip_get_cache_file "1.2.3.4")
# Returns: /var/cache/nftban/geoip/81dc9bdb52d04dc20036dbd8313ed055.json
```
- **Hashing**: MD5 hash of IP for privacy and filesystem compatibility

**`nftban_geoip_is_cache_valid(cache_file)`** - Check if cache is fresh
```bash
if nftban_geoip_is_cache_valid "$cache_file"; then
    echo "Cache is valid (< 24 hours old)"
fi
```
- **TTL**: 24 hours (86,400 seconds)
- **Check**: File modification time vs current time

**`nftban_geoip_clear_cache()`** - Clear all cached data
```bash
nftban geoip clear-cache
# GeoIP cache cleared
```
- **Use case**: Force refresh, troubleshooting, disk space recovery

---

### Bulk Operations

**`nftban_geoip_bulk_lookup(ip_file)`** - Lookup multiple IPs from file
```bash
# Create IP list
cat > /tmp/ips.txt <<EOF
1.2.3.4
8.8.8.8
203.0.113.50
EOF

# Bulk lookup
nftban geoip bulk /tmp/ips.txt

# Output:
# Lookup 1: 1.2.3.4
# -----------------------------------
# IP: 1.2.3.4
# Country: China (CN)
# ...
#
# Lookup 2: 8.8.8.8
# -----------------------------------
# IP: 8.8.8.8
# Country: United States (US)
# ...
#
# =======================================================
# Bulk Lookup Summary:
#   Total: 3
#   Success: 3
#   Failed: 0
# =======================================================
```
- **Rate limiting**: 0.5 second delay between requests (to avoid API bans)
- **Skips**: Empty lines and comments (#)
- **Use case**: Analyzing ban logs, threat intelligence reports

---

### Statistics

**`nftban_geoip_stats()`** - Show lookup statistics
```bash
nftban geoip stats

# =======================================================
#   GeoIP Lookup Statistics
# =======================================================
#
# Status: true
#
# Cached Entries: 847
# Oldest Cache: 18 hours ago
#
# Recent Lookups (last 100):
#   Total: 100
#   Success: 97
#   Failed: 3
#   Success Rate: 97%
#
# Provider Usage (last 100):
#   ipapi                 65 lookups
#   ipinfo                20 lookups
#   ipapico               10 lookups
#   local                  2 lookups
#   ALL_PROVIDERS          3 lookups  # Failed
#
# =======================================================
```
- **Metrics**:
  - Cache size and age
  - Success/failure rates
  - Provider distribution
  - API reliability

---

## Configuration

**Global Config (`/etc/nftban/nftban.conf`):**
```bash
# Enable/disable GeoIP lookups
NFTBAN_GEOIP_ENABLE="true"
```

**Cache Settings:**
```bash
# Cache directory (automatic)
NFTBAN_GEOIP_CACHE_DIR="/var/cache/nftban/geoip"

# Cache TTL (24 hours)
NFTBAN_GEOIP_CACHE_TTL=86400

# Log file
NFTBAN_GEOIP_LOG="/var/log/nftban/geoip-lookup.log"
```

---

## CLI Integration

```bash
# Single IP lookup (formatted)
nftban geoip lookup 1.2.3.4

# Force refresh (bypass cache)
nftban geoip lookup 1.2.3.4 --refresh

# Compact format
nftban geoip compact 203.0.113.50

# Bulk lookup from file
nftban geoip bulk /path/to/ips.txt

# Statistics
nftban geoip stats

# Clear cache
nftban geoip clear-cache
```

---

## Provider Comparison

| Provider | Rate Limit | Protocol | Fields | Threat Intel | Accuracy |
|----------|-----------|----------|--------|--------------|----------|
| **ip-api.com** | 45/min | HTTP | Most complete | Mobile, proxy, hosting | 95% |
| **ipinfo.io** | 50k/month | HTTPS | Basic | Limited | 97% |
| **ipapi.co** | 1k/day | HTTPS | Moderate | ASN | 96% |
| **freegeoip.app** | 15k/hour | HTTPS | Basic | None | 94% |
| **Local (geoiplookup)** | Unlimited | N/A | Country only | None | 98% |

**Recommendation**: Install local MaxMind database for high-volume deployments.

---

## JSON Response Formats

### ip-api.com Response
```json
{
  "status": "success",
  "country": "United States",
  "countryCode": "US",
  "region": "CA",
  "regionName": "California",
  "city": "Mountain View",
  "isp": "Google LLC",
  "org": "Google Public DNS",
  "as": "AS15169 Google LLC",
  "mobile": false,
  "proxy": false,
  "hosting": true
}
```

### ipinfo.io Response
```json
{
  "ip": "8.8.8.8",
  "hostname": "dns.google",
  "city": "Mountain View",
  "region": "California",
  "country": "US",
  "loc": "37.4056,-122.0775",
  "org": "AS15169 Google LLC",
  "postal": "94043",
  "timezone": "America/Los_Angeles"
}
```

---

## Testing

### Test 1: Basic Lookup

```bash
# Test with known IP
nftban geoip lookup 8.8.8.8

# Expected output:
# IP: 8.8.8.8
# Country: United States (US)
# Region: California
# City: Mountain View
# ISP: Google LLC
# ASN: AS15169 Google LLC
# Flags: Hosting
```

### Test 2: Cache Functionality

```bash
# First lookup (API call)
time nftban geoip lookup 1.2.3.4
# Real: 0.5s (network delay)

# Second lookup (cached)
time nftban geoip lookup 1.2.3.4
# Real: 0.05s (cache hit)

# Verify cache file
ls -lh /var/cache/nftban/geoip/
```

### Test 3: Provider Failover

```bash
# Temporarily block primary provider
iptables -A OUTPUT -d ip-api.com -j DROP

# Lookup should still work (fallback to ipinfo.io)
nftban geoip lookup 203.0.113.50

# Check which provider used
tail -1 /var/log/nftban/geoip-lookup.log
# Should show: ipinfo | SUCCESS
```

### Test 4: Bulk Lookup

```bash
# Extract IPs from auth.log
grep "Failed password" /var/log/auth.log | \
    awk '{print $(NF-3)}' | sort -u > /tmp/failed_ips.txt

# Bulk lookup
nftban geoip bulk /tmp/failed_ips.txt

# Analyze results
grep "Country:" /tmp/geoip_results.txt | sort | uniq -c | sort -rn
```

---

## Performance

### Benchmarks

```bash
# Lookup times:
# - Cache hit: ~0.05s
# - API call: ~0.5s (network-dependent)
# - Local DB: ~0.01s

# Cache efficiency:
# - 100 unique IPs = 100 API calls
# - 1000 repeated lookups = 100 API calls (90% cache hit rate)

# Memory usage:
# - Per cache entry: ~500 bytes JSON
# - 10,000 cached IPs: ~5 MB
```

### Rate Limiting

**ip-api.com** (primary provider):
- Free tier: 45 requests/minute
- Exceeded: 429 error, automatic fallback to next provider
- Recommendation: Implement 1.5s delay for bulk lookups

**Best practices**:
```bash
# For bulk lookups (>45 IPs)
for ip in $(cat ips.txt); do
    nftban geoip lookup "$ip"
    sleep 1.5  # Stay under rate limit
done
```

---

## Troubleshooting

### Issue 1: All Providers Failing

**Symptoms**: `{"error":"All providers failed"}`

**Causes**:
1. No internet connection
2. Firewall blocking HTTPS/HTTP
3. API providers down
4. curl not installed

**Solutions**:
```bash
# Test connectivity
curl -I https://ipinfo.io

# Install curl
apt-get install curl   # Debian/Ubuntu
yum install curl       # RHEL/CentOS

# Check firewall
iptables -L OUTPUT -v -n
nft list ruleset | grep output

# Test specific provider
curl -s "http://ip-api.com/json/8.8.8.8"
```

### Issue 2: Slow Lookups

**Symptoms**: Lookups taking >5 seconds

**Causes**:
1. Network latency
2. API provider overloaded
3. Cache not working

**Solutions**:
```bash
# Verify cache enabled
ls /var/cache/nftban/geoip/

# Check cache hits
tail -f /var/log/nftban/geoip-lookup.log

# Install local database (fastest)
apt-get install geoip-bin geoip-database

# Test local lookup
geoiplookup 8.8.8.8
```

### Issue 3: Python Parsing Errors

**Symptoms**: `Error parsing GeoIP data`

**Causes**:
1. python3 not installed
2. Malformed JSON from provider
3. API response changed format

**Solutions**:
```bash
# Install python3
apt-get install python3

# Test raw JSON
nftban_geoip_lookup "8.8.8.8" 2>&1

# Clear cache (may contain corrupt data)
nftban geoip clear-cache
```

### Issue 4: Rate Limit Exceeded

**Symptoms**: 429 errors, `{"error":"rate limit exceeded"}`

**Causes**: Too many requests to single provider

**Solutions**:
```bash
# Add delays in scripts
sleep 1.5 between lookups

# Install local database
apt-get install geoip-bin geoip-database

# Or use caching aggressively
# (module already caches for 24h)
```

---

## Integration Examples

### With Blacklist Module

```bash
# Lookup IP before banning (for logs)
ip="203.0.113.50"
geo=$(nftban_geoip_get_compact "$ip")
nftban blacklist ban "$ip" "Attack from $geo"
```

### With Stats Module

```bash
# Analyze attack sources by country
grep "Failed password" /var/log/auth.log | \
    awk '{print $(NF-3)}' | sort -u | while read ip; do
        echo "$ip,$(nftban_geoip_get_compact "$ip")"
    done > /tmp/attack_geo.csv

# Top attacking countries
cut -d',' -f2 /tmp/attack_geo.csv | cut -d'/' -f1 | sort | uniq -c | sort -rn
```

### With GEO Module

```bash
# Auto-block countries with high attack volume
threshold=10

# Analyze last 1000 failed logins
grep "Failed password" /var/log/auth.log | tail -1000 | \
    awk '{print $(NF-3)}' | while read ip; do
        nftban_geoip_get_compact "$ip" | cut -d'/' -f1
    done | sort | uniq -c | sort -rn | while read count country; do
        if [[ $count -gt $threshold ]]; then
            echo "High attack volume from $country ($count attempts)"
            nftban geo block "$country" "Auto-block: $count attacks"
        fi
    done
```

---

## Best Practices

### Production Deployment

1. **Install local database** (for high volume):
   ```bash
   apt-get install geoip-bin geoip-database
   apt-get install geoip-database-extra  # More accurate
   ```

2. **Monitor cache hit rate**:
   ```bash
   # Add to daily cron
   nftban geoip stats | mail -s "GeoIP Stats" admin@example.com
   ```

3. **Respect rate limits**:
   ```bash
   # For bulk operations, add delays
   sleep 1.5  # Stay under ip-api.com limit (45/min)
   ```

4. **Handle failures gracefully**:
   ```bash
   geo=$(nftban_geoip_get_compact "$ip" 2>/dev/null || echo "Unknown")
   ```

### Cache Maintenance

```bash
# Add to weekly cron
# Clear cache older than 7 days
find /var/cache/nftban/geoip -name "*.json" -mtime +7 -delete

# Or clear all cache monthly (force refresh)
0 0 1 * * nftban geoip clear-cache
```

---

## Security Considerations

### API Privacy

**Concerns**:
- Lookup IPs sent to third-party APIs
- May reveal investigation targets
- No encryption for HTTP endpoints (ip-api.com)

**Mitigations**:
```bash
# Use local database for sensitive lookups
apt-get install geoip-bin geoip-database

# Or self-host GeoIP API
# (MaxMind GeoLite2, DB-IP community edition)
```

### Rate Limit Attacks

**Attack**: Excessive lookups to exhaust API quota

**Mitigation**:
- Caching (24-hour TTL) reduces API calls by ~90%
- Local database for unlimited queries
- Monitor `/var/log/nftban/geoip-lookup.log` for anomalies

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
