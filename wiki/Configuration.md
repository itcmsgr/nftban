# Configuration

NFTBan configuration files and options.

---

## Table of Contents
- [File Locations](#file-locations)
- [Main Configuration](#main-configuration)
- [Module Configs](#module-configs)
- [Local Overrides](#local-overrides)

---

## File Locations

| Path | Purpose |
|------|---------|
| `/etc/nftban/main.conf` | Main configuration |
| `/etc/nftban/conf.d/` | Module-specific configs |
| `/etc/nftban/whitelist.d/` | IP whitelist files |
| `/etc/nftban/blacklist.d/` | IP blacklist files |

---

## Main Configuration

Path: `/etc/nftban/main.conf`

```bash
# Operating mode
NFTBAN_MODE="normal"           # normal, degraded, survival

# Logging
NFTBAN_LOG_LEVEL="INFO"        # DEBUG, INFO, WARN, ERROR
NFTBAN_LOG_FILE="/var/log/nftban/nftban.log"

# Ban defaults
NFTBAN_DEFAULT_BAN_DURATION="3600"    # seconds (1 hour)
NFTBAN_MAX_BAN_DURATION="604800"      # seconds (7 days)
```

---

## Module Configs

### DDoS Detection
Path: `/etc/nftban/conf.d/ddos.conf`

```bash
DDOS_ENABLED="true"
DDOS_THRESHOLD_PPS="10000"     # Packets per second
DDOS_THRESHOLD_BPS="100000000" # Bytes per second (100 Mbps)
```

### Port Scan Detection
Path: `/etc/nftban/conf.d/portscan.conf`

```bash
PORTSCAN_ENABLED="true"
PORTSCAN_THRESHOLD="10"        # Ports in window
PORTSCAN_WINDOW="60"           # Seconds
```

### Login Monitoring
Path: `/etc/nftban/conf.d/login.conf`

```bash
LOGIN_ENABLED="true"
LOGIN_MAX_FAILURES="5"
LOGIN_BAN_DURATION="3600"
```

### Threat Feeds
Path: `/etc/nftban/conf.d/feeds.conf`

```bash
FEEDS_ENABLED="true"
FEEDS_UPDATE_INTERVAL="86400"  # Daily
FEEDS_SOURCES="spamhaus,blocklist_de"
```

### GeoIP
Path: `/etc/nftban/conf.d/geoip.conf`

```bash
GEOIP_ENABLED="true"
GEOIP_DATABASE="/var/lib/nftban/geoip/dbip-country-lite.mmdb"
```

### Metrics
Path: `/etc/nftban/conf.d/metrics.conf`

```bash
METRICS_ENABLED="true"
METRICS_FORMAT="prometheus"
METRICS_RETENTION_WEEKS="2"
```

---

## Local Overrides

To customize without modifying shipped configs, create `.local` files:

```bash
# Override main config
/etc/nftban/main.conf.local

# Override module configs
/etc/nftban/conf.d/ddos.conf.local
/etc/nftban/conf.d/feeds.conf.local
```

Local files are loaded after main configs and take precedence.

---

## Whitelist Management

### System Whitelist (auto-managed)
```bash
# Auto-generated, do not edit
/etc/nftban/whitelist.d/00-system.conf
```

### Custom Whitelist
```bash
# Create custom whitelist
/etc/nftban/whitelist.d/10-custom.conf
```

Format:
```
192.168.1.0/24 # Office network
10.0.0.1       # Management server
```

### Sync to nftables
```bash
nftban whitelist sync
```

---

## References

- CLI: `nftban config show`
- Audit: `nftban configaudit`
- Test: `nftban configtest`
