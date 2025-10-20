# NFTBan GeoIP Lookup Integration Module

**File:** `lib/nftban_geoip_module.sh`  
**Version:** 1.0.0  
**Author:** ITCMS Team (Antonios Voulvoulis)  
**Purpose:** Advanced GeoIP lookup with multiple providers and intelligent caching

---

## Overview

The GeoIP Lookup Integration Module provides comprehensive IP geolocation services with automatic failover across multiple providers. It delivers country, city, ISP, and threat intelligence data (proxy/hosting/mobile detection) for any IP address.

The module implements a sophisticated multi-tier lookup strategy: local database first, then cached results, and finally online API providers with automatic failover. This ensures high availability even when individual providers are rate-limited or offline.

Key features include 24-hour intelligent caching to minimize API calls, support for both online APIs (ip-api.com, ipinfo.io, ipapi.co, freegeoip.app) and local GeoIP databases, formatted output options for both human and machine consumption, and bulk lookup capabilities for processing IP lists.

---

## Key Functions

### Public Functions (Exported)

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `nftban_geoip_init()` | Initialize module and cache directory | None | Always 0 |
| `nftban_geoip_lookup()` | Main lookup with provider fallback | `$1` - IP address<br>`$2` - force_refresh (true/false) | JSON data or 0/1 |
| `nftban_geoip_get_formatted()` | Human-readable formatted output | `$1` - IP address | Pretty-printed text |
| `nftban_geoip_get_compact()` | Single-line compact format | `$1` - IP address | Country/City/ISP |
| `nftban_geoip_bulk_lookup()` | Process file of IPs | `$1` - IP file path | Summary stats |
| `nftban_geoip_clear_cache()` | Clear all cached data | None | 0 on success |
| `nftban_geoip_stats()` | Display statistics and metrics | None | Formatted report |

### Internal Functions (Private)

| Function | Purpose | Notes |
|----------|---------|-------|
| `nftban_geoip_get_cache_file()` | Get cache file path for IP | MD5 hash-based filename |
| `nftban_geoip_is_cache_valid()` | Check if cache entry is fresh | 24-hour TTL validation |
| `nftban_geoip_save_cache()` | Save lookup result to cache | JSON format |
| `nftban_geoip_load_cache()` | Load cached result | Returns JSON or fails |
| `nftban_geoip_query_ipapi()` | Query ip-api.com provider | Primary provider |
| `nftban_geoip_query_ipinfo()` | Query ipinfo.io provider | Fallback #1 |
| `nftban_geoip_query_ipapico()` | Query ipapi.co provider | Fallback #2 |
| `nftban_geoip_query_freegeoip()` | Query freegeoip.app provider | Fallback #3 |
| `nftban_geoip_query_local()` | Query local GeoIP database | Highest priority if available |

---

## Configuration Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NFTBAN_GEOIP_CACHE_DIR` | `${NFTBAN_CACHE_DIR}/geoip` | Cache storage directory |
| `NFTBAN_GEOIP_LOG` | `${NFTBAN_LOG_DIR}/geoip-lookup.log` | Lookup activity log |
| `NFTBAN_GEOIP_CACHE_TTL` | `86400` | Cache validity (24 hours) |
| `NFTBAN_GEOIP_ENABLE` | `true` | Enable/disable GeoIP lookups |
| `NFTBAN_GEOIP_PROVIDERS` | Array | Provider list in priority order |

---

## Dependencies

**Required Modules:**
- `nftban_core.sh` - Core logging and validation functions

**External Commands:**
- `curl` - HTTP requests to API providers (required)
- `python3` - JSON parsing and formatting (recommended)
- `geoiplookup` - Local GeoIP database queries (optional)
- `md5sum` - Cache key generation (required)
- `stat` - Cache age validation (required)

**Optional Local Databases:**
- GeoIP legacy databases (if geoiplookup available)
- MaxMind GeoIP2 databases (future support)

---

## Usage Examples

### Example 1: Simple IP Lookup (Formatted)
```bash
# Get human-readable GeoIP information
nftban_geoip_get_formatted "8.8.8.8"

# Expected output:
# IP: 8.8.8.8
# Country: United States (US)
# Region: California
# City: Mountain View
# ISP: Google LLC
# ASN: AS15169 Google LLC
# Flags: Hosting
```

### Example 2: Compact Format (For Scripts)
```bash
# Get single-line format suitable for parsing
result=$(nftban_geoip_get_compact "1.2.3.4")
echo "$result"

# Expected output:
# United_States/New_York/Example_ISP
```

### Example 3: Raw JSON Lookup
```bash
# Get raw JSON data for programmatic processing
nftban_geoip_lookup "192.0.2.1"

# Expected output (JSON):
# {
#   "ip": "192.0.2.1",
#   "status": "success",
#   "country": "United States",
#   "countryCode": "US",
#   "region": "NY",
#   "regionName": "New York",
#   "city": "New York",
#   "isp": "Example ISP",
#   "org": "Example Organization",
#   "as": "AS12345 Example ISP",
#   "mobile": false,
#   "proxy": false,
#   "hosting": true
# }
```

### Example 4: Force Refresh (Bypass Cache)
```bash
# Force fresh lookup even if cached
nftban_geoip_lookup "8.8.8.8" true

# Useful for:
# - Verifying current data
# - Testing provider availability
# - Updating stale entries
```

### Example 5: Bulk Lookup from File
```bash
# Create IP list file
cat > suspicious_ips.txt <<EOF
1.2.3.4
8.8.8.8
192.0.2.1
# This is a comment
203.0.113.0
EOF

# Process all IPs
nftban_geoip_bulk_lookup suspicious_ips.txt

# Expected output:
# Lookup 1: 1.2.3.4
# -----------------------------------
# IP: 1.2.3.4
# Country: United States (US)
# ...
# 
# =======================================================
# Bulk Lookup Summary:
#   Total: 4
#   Success: 4
#   Failed: 0
# =======================================================
```

### Example 6: Integration with Ban Commands
```bash
# Check GeoIP before banning
ip="45.67.89.10"
geoinfo=$(nftban_geoip_get_compact "$ip")

echo "Banning IP from: $geoinfo"
nftban --ban-ip "$ip"

# Example output:
# Banning IP from: Russia/Moscow/Suspicious_Hosting_LLC
```

---

## Provider Failover Strategy

The module uses a cascading fallback system:

1. **Local Database** (if available) - Highest priority, fastest, no rate limits
2. **Cache Lookup** (if valid) - Second priority, instant results, 24-hour freshness
3. **Online Providers** (in order):
   - **ip-api.com** - Primary (45 requests/minute limit)
   - **ipinfo.io** - Fallback #1 (50k requests/month free tier)
   - **ipapi.co** - Fallback #2 (30k requests/month free tier)
   - **freegeoip.app** - Fallback #3 (15k requests/hour)

**Timeout Settings:**
- Connection timeout: 3 seconds per provider
- Automatic retry with next provider on failure
- All providers exhausted: Returns error JSON

---

## File Operations

**Reads from:**
- `/etc/nftban/config/nftban.conf` - For `NFTBAN_GEOIP_ENABLE` setting
- `${NFTBAN_CACHE_DIR}/geoip/*.json` - Cached lookup results

**Writes to:**
- `${NFTBAN_CACHE_DIR}/geoip/<md5>.json` - Individual cache entries
- `${NFTBAN_LOG_DIR}/geoip-lookup.log` - Lookup activity log

**Cache File Format:**
```json
{
  "ip": "8.8.8.8",
  "country": "United States",
  "countryCode": "US",
  "region": "CA",
  "city": "Mountain View",
  "isp": "Google LLC",
  "as": "AS15169 Google LLC",
  "mobile": false,
  "proxy": false,
  "hosting": true
}
```

**Log File Format:**
```
[2025-10-20 14:32:15] 8.8.8.8 | ipapi | SUCCESS
[2025-10-20 14:33:42] 1.2.3.4 | ipinfo | SUCCESS
[2025-10-20 14:35:19] 203.0.113.1 | ALL_PROVIDERS | FAILED
```

---

## Cache Management

### Cache Benefits
- **Performance:** Instant results for repeated lookups
- **Rate Limit Protection:** Avoids hitting API limits
- **Reliability:** Works even when providers are down
- **Cost Savings:** Reduces API usage on paid tiers

### Cache Operations
```bash
# View cache statistics
nftban_geoip_stats

# Clear all cached data
nftban_geoip_clear_cache

# Manual cache inspection
ls -lh /var/cache/nftban/geoip/

# Find oldest cached entry
find /var/cache/nftban/geoip -name "*.json" -type f -printf '%T+ %p\n' | sort | head -1
```

### Cache Invalidation
- **Automatic:** Entries older than 24 hours are ignored
- **Manual:** `nftban_geoip_clear_cache` command
- **Force Refresh:** Pass `true` as second parameter to `nftban_geoip_lookup`

---

## Error Handling

**Common Errors:**

| Error Message | Cause | Solution |
|--------------|-------|----------|
| `Invalid IP` | IP validation failed | Check IP format (IPv4/IPv6) |
| `GeoIP Disabled` | `NFTBAN_GEOIP_ENABLE=false` | Enable in config file |
| `All providers failed` | Network issues or rate limits | Check connectivity, wait for rate limit reset |
| `GeoIP_Unavailable` | Python3 not installed | Install python3 for formatted output |
| `Error parsing GeoIP data` | Malformed JSON response | Provider issue, try force refresh |

**Return Values:**
- `0` - Success
- `1` - Lookup failed (all providers)
- JSON with `"error"` key - Specific error details

**Debugging Failed Lookups:**
```bash
# Check recent failures in log
grep "FAILED" /var/log/nftban/geoip-lookup.log | tail -20

# Test each provider manually
curl -s "http://ip-api.com/json/8.8.8.8"
curl -s "https://ipinfo.io/8.8.8.8/json"

# Verify local GeoIP database
geoiplookup 8.8.8.8

# Force refresh to bypass cache
nftban_geoip_lookup "8.8.8.8" true
```

---

## Statistics and Monitoring

### View Statistics
```bash
nftban_geoip_stats
```

**Output Includes:**
- GeoIP status (enabled/disabled)
- Cache statistics (total entries, oldest entry age)
- Lookup success/failure rates (last 100 lookups)
- Provider usage distribution
- Success rate percentage

**Example Output:**
```
=======================================================
  GeoIP Lookup Statistics
=======================================================

Status: true

Cached Entries: 147
Oldest Cache: 18 hours ago

Recent Lookups (last 100):
  Total: 100
  Success: 94
  Failed: 6
  Success Rate: 94%

Provider Usage (last 100):
  ipapi                 68 lookups
  local                 20 lookups
  ipinfo                 6 lookups
  ipapico                0 lookups
  ALL_PROVIDERS          6 lookups

=======================================================
```

---

## Performance Considerations

**Lookup Times:**
- Cache hit: <1ms (instant)
- Local database: 2-5ms
- Online API: 200-500ms (with 3s timeout)
- Failed lookup: 12-15s (all providers timeout)

**Optimization Tips:**
1. **Enable local GeoIP database** for fastest lookups without rate limits
2. **Bulk lookup with delays** (0.5s between requests) to respect rate limits
3. **Monitor cache hit rate** - aim for >80% in production
4. **Increase cache TTL** if data freshness isn't critical (modify `NFTBAN_GEOIP_CACHE_TTL`)

**Rate Limit Handling:**
- Automatic failover to next provider
- Cached results serve as fallback
- 0.5s delay in bulk lookups prevents rate limit hits
- Monitor `/var/log/nftban/geoip-lookup.log` for provider failures

---

## Integration Points

**Called by:**
- `nftban_main_cli.sh` - For `nftban --geoip <IP>` command
- `nftban_stats_module.sh` - For enhanced statistics with geolocation
- `nftban_blacklist_module.sh` - For threat intelligence enrichment
- Custom scripts - For IP analysis and reporting

**Calls:**
- `nftban_validate_ip()` from `nftban_core.sh` - IP validation
- `nftban_log_*()` from `nftban_core.sh` - Logging functions
- `nftban_get_config()` from `nftban_core.sh` - Configuration retrieval
- External APIs - Various GeoIP providers

**Integration Example:**
```bash
# In a custom monitoring script
source /usr/local/bin/nftban/lib/nftban_geoip_module.sh

# Check failed login attempts with geolocation
grep "Failed password" /var/log/auth.log | \
awk '{print $11}' | \
while read ip; do
    location=$(nftban_geoip_get_compact "$ip")
    echo "Failed login from: $ip ($location)"
done
```

---

## Security Considerations

### Privacy
- **API Queries:** IP addresses are sent to third-party providers
- **Local Database Recommended:** For sensitive environments, use local GeoIP databases only
- **Cache Security:** Cache files contain IP location mappings (world-readable)

### Threat Intelligence
The module provides valuable security indicators:
- **Mobile Flag:** Detects mobile carrier IPs (unusual for servers)
- **Proxy Flag:** Identifies proxy/VPN services (potential abuse)
- **Hosting Flag:** Marks datacenter IPs (legitimate for servers, suspicious for users)

**Security Use Cases:**
```bash
# Check if IP is from hosting provider (potential bot)
result=$(nftban_geoip_lookup "45.67.89.10")
if echo "$result" | grep -q '"hosting":true'; then
    echo "Warning: IP from hosting provider"
fi

# Detect proxy usage
if echo "$result" | grep -q '"proxy":true'; then
    echo "Alert: Proxy detected"
fi
```

### Rate Limiting
- **Provider Limits:** Respect free tier restrictions
- **Bulk Operations:** Use 0.5s delays between requests
- **Cache First:** Always check cache before API calls
- **Monitor Usage:** Track provider usage in logs

---

## Troubleshooting

### Issue: All Providers Failing
```bash
# Check network connectivity
ping -c 1 ip-api.com
ping -c 1 ipinfo.io

# Test manual API calls
curl -v "http://ip-api.com/json/8.8.8.8"

# Check firewall rules
sudo iptables -L OUTPUT -v | grep -E "80|443"
```

### Issue: Slow Lookups
```bash
# Check cache hit rate
nftban_geoip_stats | grep "Success Rate"

# Test provider response times
time curl -s "http://ip-api.com/json/8.8.8.8" > /dev/null

# Consider installing local GeoIP database
apt-get install geoip-bin geoip-database
```

### Issue: Python3 Not Available
```bash
# Install python3
apt-get install python3  # Debian/Ubuntu
yum install python3      # RHEL/CentOS

# Verify installation
python3 --version
```

### Issue: Cache Growing Too Large
```bash
# Check cache size
du -sh /var/cache/nftban/geoip/

# Clean old entries (older than 7 days)
find /var/cache/nftban/geoip -name "*.json" -mtime +7 -delete

# Clear all cache
nftban_geoip_clear_cache
```

---

## Advanced Usage

### Custom Provider Integration
To add a new GeoIP provider:

1. Create query function following naming pattern:
```bash
nftban_geoip_query_newprovider() {
    local ip="$1"
    local response
    response=$(curl -s --connect-timeout 3 "https://newprovider.com/api/${ip}")
    
    if [[ -n "$response" ]]; then
        echo "$response"
        return 0
    fi
    return 1
}
```

2. Add to provider array in `nftban_geoip_lookup()` function

3. Export the function:
```bash
export -f nftban_geoip_query_newprovider
```

### Webhook Integration
Send GeoIP data to external systems:
```bash
# Example: Send to Slack on suspicious country
ip="1.2.3.4"
result=$(nftban_geoip_lookup "$ip")
country=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('country',''))")

if [[ "$country" == "Suspicious Country" ]]; then
    curl -X POST https://hooks.slack.com/services/YOUR/WEBHOOK/URL \
         -d "{\"text\":\"Alert: Access from $ip ($country)\"}"
fi
```

---

## See Also

**Related Modules:**
- `nftban_geo_module.sh` - Geographic blocking by country
- `nftban_feeds_module.sh` - Threat intelligence feeds
- `nftban_stats_module.sh` - Statistics with geolocation
- `nftban_blacklist_module.sh` - IP blacklist management

**Related Documentation:**
- GeoIP provider documentation (ip-api.com, ipinfo.io, etc.)
- MaxMind GeoIP2 documentation (for local databases)
- NFTBan configuration guide

**External Resources:**
- [ip-api.com Documentation](http://ip-api.com/docs/)
- [ipinfo.io API](https://ipinfo.io/developers)
- [MaxMind GeoIP2](https://dev.maxmind.com/geoip/)