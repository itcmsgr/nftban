# NFTBan GO GeoIP Module
**Version:** 1.0.0
**Author:** Antonios Voulvoulis <contact@nftban.com>
**Homepage:** https://nftban.com
**Status:** Production Ready

---

## 📋 Table of Contents

1. [Overview](#overview)
2. [Features](#features)
3. [Architecture](#architecture)
4. [Installation](#installation)
5. [CLI Usage](#cli-usage)
6. [Bash API](#bash-api)
7. [Performance](#performance)
8. [Integration Examples](#integration-examples)
9. [Troubleshooting](#troubleshooting)
10. [Technical Details](#technical-details)

---

## Overview

The NFTBan GO GeoIP Module provides **ultra-fast offline IP geolocation** using MaxMind's GeoLite2 database. It replaces slow API calls with local lookups that are **5000x-12500x faster**.

### Key Benefits

- ⚡ **Speed**: 40-50 microseconds per lookup (vs 200-500ms for API)
- 🌐 **Offline**: No internet required, no rate limits
- 💰 **Free**: Uses free GeoLite2 database
- 🔒 **Privacy**: No external services, all data stays local
- 📊 **Comprehensive**: Country, city, timezone, coordinates, ASN

---

## Features

### GO Binary Features

- **Commands**: lookup, bulk, status, test, version
- **Output Formats**: JSON, compact (CC/City/TZ), country-only
- **Performance Testing**: Built-in benchmarking
- **Health Checks**: Database validation, version info
- **Bulk Processing**: JSONL output for piping

### Bash Wrapper Features

- **11 Exported Functions**: Easy integration with bash scripts
- **Error Handling**: Graceful fallbacks, timeout protection
- **Formatting Helpers**: Compact format, log format, country extraction
- **Caching**: Optional result caching (if needed)

### CLI Integration

- **6 Commands**: lookup, bulk, status, test, update, help
- **TAB Completion**: Multi-level completion support
- **Help System**: Comprehensive examples and usage
- **Auto-Update**: Download latest GeoLite2 database

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     NFTBan CLI                              │
│                  nftban geoip <cmd>                         │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│              CLI Handler (cmd_geoip.sh)                     │
│  - Argument parsing                                         │
│  - Command routing                                          │
│  - Help text                                                │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│           Bash Wrapper (nftban_geoip_go.sh)                 │
│  - 11 convenience functions                                 │
│  - Error handling                                           │
│  - Format conversion                                        │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│              GO Binary (nftban-geoip)                       │
│  - MaxMind DB reader                                        │
│  - JSON serialization                                       │
│  - Performance optimized                                    │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│          GeoLite2-City.mmdb (61MB)                          │
│  - 4.7 million locations                                    │
│  - Updated monthly                                          │
│  - Free from MaxMind                                        │
└─────────────────────────────────────────────────────────────┘
```

---

## Installation

### Prerequisites

- GO 1.21 or higher
- git
- wget or curl

### Building from Source

```bash
# 1. Install GO (if not installed)
wget https://go.dev/dl/go1.23.2.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go1.23.2.linux-amd64.tar.gz
export PATH=$PATH:/usr/local/go/bin

# 2. Clone and build
cd /path/to/nftban-v0.10.0-dev/go-geoip
go mod tidy
go build -o nftban-geoip cmd/nftban-geoip/main.go

# 3. Install binary
sudo install -m 755 nftban-geoip /usr/lib/nftban/bin/

# 4. Download GeoLite2 database
sudo mkdir -p /var/lib/nftban/geoip
sudo wget -O /var/lib/nftban/geoip/GeoLite2-City.mmdb \
  https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-City.mmdb

# 5. Install bash wrapper
sudo install -m 644 src/usr/lib/nftban/core/nftban_geoip_go.sh \
  /usr/lib/nftban/core/

# 6. Install CLI handler
sudo install -m 755 src/usr/lib/nftban/cli/cmd_geoip.sh \
  /usr/lib/nftban/cli/
```

### Verify Installation

```bash
# Test binary
/usr/lib/nftban/bin/nftban-geoip test

# Test CLI
nftban geoip test

# Expected: 6/6 tests PASSED
```

---

## CLI Usage

### Basic Lookup

```bash
# Full JSON output
nftban geoip lookup 8.8.8.8

# Output:
{
  "ip": "8.8.8.8",
  "country": "United States",
  "country_code": "US",
  "city": "Mountain View",
  "timezone": "America/Los_Angeles",
  "latitude": 37.386,
  "longitude": -122.0838,
  "accuracy_radius": 1000,
  "lookup_time_us": 46
}
```

### Compact Format

```bash
# Compact: CC/City/Timezone
nftban geoip lookup 8.8.8.8 compact

# Output: US/Mountain View/America/Los_Angeles
```

### Country Only

```bash
# Just the country code
nftban geoip lookup 8.8.8.8 country

# Output: US
```

### Bulk Lookups

```bash
# From file
echo -e "8.8.8.8\n1.1.1.1\n9.9.9.9" > ips.txt
nftban geoip bulk ips.txt

# From stdin
cat access.log | awk '{print $1}' | nftban geoip bulk

# Output: One JSON per line (JSONL)
```

### System Status

```bash
nftban geoip status

# Shows:
# - Binary path and version
# - Database path and size
# - Database age
# - Performance test result
```

### Run Tests

```bash
nftban geoip test

# Runs 6 built-in tests:
# 1. Binary exists
# 2. Database exists
# 3. Lookup Google DNS (8.8.8.8)
# 4. Lookup Cloudflare DNS (1.1.1.1)
# 5. Lookup Quad9 DNS (9.9.9.9)
# 6. Performance benchmark
```

### Update Database

```bash
nftban geoip update

# Downloads latest GeoLite2-City.mmdb
# Creates backup of old database
# Verifies new database
# Restores backup if verification fails
```

### Help

```bash
nftban geoip help

# Shows all commands with examples
```

---

## Bash API

### Exported Functions

```bash
# Source the wrapper
source /usr/lib/nftban/core/nftban_geoip_go.sh

# Available functions:
nftban_geoip_check_available       # Check if system is ready
nftban_geoip_lookup_fast <ip>      # Full JSON lookup
nftban_geoip_get_country <ip>      # Get country code
nftban_geoip_get_city <ip>         # Get city name
nftban_geoip_get_timezone <ip>     # Get timezone
nftban_geoip_get_coordinates <ip>  # Get lat,lon
nftban_geoip_get_compact <ip>      # Get CC/City
nftban_geoip_get_compact_full <ip> # Get CC/City/TZ
nftban_geoip_format_for_log <ip>   # Get [CC/City/TZ]
nftban_geoip_bulk_lookup [file]    # Bulk processing
nftban_geoip_test_performance      # Benchmark
```

### Integration Examples

#### Example 1: Enrich Log Entry

```bash
source /usr/lib/nftban/core/nftban_geoip_go.sh

ip="203.0.113.42"
geo=$(nftban_geoip_format_for_log "$ip")
echo "Access from $ip $geo"

# Output: Access from 203.0.113.42 [AU/Sydney/Australia/Sydney]
```

#### Example 2: Block by Country

```bash
source /usr/lib/nftban/core/nftban_geoip_go.sh

ip="203.0.113.42"
country=$(nftban_geoip_get_country "$ip")

if [[ "$country" == "CN" || "$country" == "RU" ]]; then
    echo "Blocking IP from $country"
    nftban firewall blacklist ban "$ip"
fi
```

#### Example 3: Bulk Processing

```bash
source /usr/lib/nftban/core/nftban_geoip_go.sh

# Process access log
awk '{print $1}' /var/log/nginx/access.log | \
    sort -u | \
    nftban_geoip_bulk_lookup | \
    jq -r 'select(.country_code == "CN") | .ip'

# Output: All IPs from China
```

#### Example 4: Alert with Location

```bash
source /usr/lib/nftban/core/nftban_geoip_go.sh

# SSH login alert
ip="$PAM_RHOST"
user="$PAM_USER"
geo=$(nftban_geoip_get_compact_full "$ip")

echo "SSH login: $user from $ip ($geo)" | \
    mail -s "Login Alert" admin@example.com
```

---

## Performance

### Benchmarks

| Operation | Time | Throughput |
|-----------|------|------------|
| Single lookup | 40-50 μs | ~20,000 lookups/sec |
| Bulk lookup (1000 IPs) | ~45 ms | ~22,000 IPs/sec |
| Database load | ~200 ms | One-time at startup |

### Comparison: API vs Local

| Metric | API (ipapi.co) | GO GeoIP | Improvement |
|--------|----------------|----------|-------------|
| **Latency** | 200-500 ms | 0.04-0.05 ms | **5000x-12500x faster** |
| **Rate Limit** | 1000/day free | Unlimited | ∞ |
| **Internet** | Required | Not required | Offline |
| **Cost** | $10/mo for more | Free | $120/year saved |
| **Privacy** | Sends IPs externally | All local | 100% private |

### Real-World Impact

```bash
# Before (API): 1000 lookups
time: 250 seconds (4+ minutes)
cost: Need paid plan

# After (GO): 1000 lookups
time: 0.045 seconds
cost: $0
```

---

## Integration Examples

### Login Monitoring

```bash
#!/usr/bin/env bash
# /usr/lib/nftban/hooks/login_alert.sh

source /usr/lib/nftban/core/nftban_geoip_go.sh

ip="$1"
user="$2"
service="$3"

# Get location
location=$(nftban_geoip_get_compact_full "$ip")

# Send alert
echo "Login: $user via $service from $ip [$location]" | \
    mail -s "Login Alert" admin@example.com

# Log with location
logger -t nftban-login "user=$user ip=$ip location=$location"
```

### Firewall Rules by Country

```bash
#!/usr/bin/env bash
# Block specific countries

source /usr/lib/nftban/core/nftban_geoip_go.sh

blocked_countries=("CN" "RU" "KP")

# Check incoming connection
ip="$1"
country=$(nftban_geoip_get_country "$ip")

for blocked in "${blocked_countries[@]}"; do
    if [[ "$country" == "$blocked" ]]; then
        nftban firewall blacklist ban "$ip" permanent
        logger -t nftban-geo "Blocked $ip from $country"
        exit 0
    fi
done
```

### Access Log Analysis

```bash
#!/usr/bin/env bash
# Analyze nginx access by country

source /usr/lib/nftban/core/nftban_geoip_go.sh

# Extract unique IPs
awk '{print $1}' /var/log/nginx/access.log | sort -u | \
while read ip; do
    country=$(nftban_geoip_get_country "$ip")
    echo "$country"
done | sort | uniq -c | sort -rn

# Output:
# 1547 US
#  892 GB
#  654 DE
#  321 FR
```

---

## Troubleshooting

### Binary Not Found

```bash
# Check if binary exists
ls -l /usr/lib/nftban/bin/nftban-geoip

# If missing, reinstall
sudo install -m 755 nftban-geoip /usr/lib/nftban/bin/

# Check PATH (if using directly)
export PATH=$PATH:/usr/lib/nftban/bin
```

### Database Not Found

```bash
# Check database
ls -l /var/lib/nftban/geoip/GeoLite2-City.mmdb

# If missing, download
sudo mkdir -p /var/lib/nftban/geoip
sudo wget -O /var/lib/nftban/geoip/GeoLite2-City.mmdb \
  https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-City.mmdb

# Or use CLI
nftban geoip update
```

### Slow Performance

```bash
# Test performance
nftban geoip test

# Expected: <1ms per lookup
# If slower:
# 1. Check disk I/O
# 2. Check database file is not corrupted
# 3. Verify SSD vs HDD

# Benchmark
time nftban geoip lookup 8.8.8.8
# Should be < 100ms total (including startup)
```

### Database Too Old

```bash
# Check database age
nftban geoip status

# Update if >90 days old
nftban geoip update

# Automate monthly updates
# Add to crontab:
0 3 1 * * nftban geoip update
```

### "Unknown" Results

```bash
# Some IPs have no location data
# This is normal for:
# - Private IPs (192.168.x.x, 10.x.x.x)
# - Reserved IPs
# - Very new IP allocations

# Check with:
nftban geoip lookup 192.168.1.1
# Returns: country="Unknown"
```

---

## Technical Details

### File Locations

```
/usr/lib/nftban/bin/nftban-geoip         # GO binary (2.0 MB)
/usr/lib/nftban/core/nftban_geoip_go.sh  # Bash wrapper (230 lines)
/usr/lib/nftban/cli/cmd_geoip.sh         # CLI handler (441 lines)
/var/lib/nftban/geoip/GeoLite2-City.mmdb # Database (61 MB)
/usr/local/go/                           # GO runtime (if installed)
```

### Dependencies

**Runtime:**
- GO binary is statically compiled (no dependencies)
- Database file (GeoLite2-City.mmdb)

**Build-time:**
- GO 1.21+
- github.com/oschwald/maxminddb-golang v1.13.1

### Database Format

- **Format**: MaxMind DB (MMDB)
- **Size**: ~61 MB
- **Records**: ~4.7 million locations
- **Update Frequency**: Monthly (MaxMind updates)
- **License**: Creative Commons Attribution-ShareAlike 4.0

### JSON Output Schema

```json
{
  "ip": "string",              // IP address queried
  "country": "string",         // Full country name
  "country_code": "string",    // ISO 3166-1 alpha-2 code
  "city": "string",            // City name
  "timezone": "string",        // IANA timezone
  "latitude": float,           // Decimal degrees
  "longitude": float,          // Decimal degrees
  "accuracy_radius": int,      // Accuracy in km
  "lookup_time_us": int        // Lookup time in microseconds
}
```

### Performance Characteristics

- **Memory**: ~100 MB (database is memory-mapped)
- **CPU**: Minimal (<1% for typical loads)
- **Disk I/O**: First lookup loads DB into memory, subsequent lookups are RAM-only
- **Concurrency**: Thread-safe, can handle multiple concurrent lookups

---

## API Reference

### GO Binary Commands

```bash
# Lookup single IP
nftban-geoip lookup <IP>

# Bulk lookup
nftban-geoip bulk [file]

# Show status
nftban-geoip status

# Run tests
nftban-geoip test

# Show version
nftban-geoip version
```

### Bash Functions

See [Bash API](#bash-api) section above for complete list.

---

## Future Enhancements

### Planned Features

- [ ] ASN lookup support
- [ ] IPv6 support (database upgrade)
- [ ] Caching layer for repeated lookups
- [ ] Statistics tracking
- [ ] Custom database support
- [ ] GeoIP2 Precision database support (paid)

### Contributing

Contributions welcome! See main NFTBan repository for guidelines.

---

## License

- **NFTBan Code**: MPL-2.0
- **GeoLite2 Database**: Creative Commons Attribution-ShareAlike 4.0

---

## Resources

- **MaxMind GeoLite2**: https://dev.maxmind.com/geoip/geolite2-free-geolocation-data
- **Database Updates**: https://github.com/P3TERX/GeoLite.mmdb
- **GO MaxMind Reader**: https://github.com/oschwald/maxminddb-golang

---

**nftban — Simplifying Linux Firewall Management**

*Last Updated: 2025-10-27*
