# NFTBan Configuration Locations Reference

**Version:** v0.32.6
**Purpose:** Clear reference for ALL configuration file locations
**Audience:** System administrators, developers, users

---

## 📍 Configuration Files Overview

NFTBan uses a hierarchical configuration system. This document lists **every configuration file** and its exact location.

---

## 🗂️ Main Configuration

### Primary Config File

**Location:** `/etc/nftban/nftban.conf`
**Purpose:** Main NFTBan configuration
**Format:** Bash key=value pairs
**Preserved on upgrade:** No (use .local override instead)

**Key Settings:**
```bash
ENABLED="true"                      # Master switch
NFTABLES_ENABLED="true"             # Enable nftables integration
LOG_LEVEL="INFO"                    # DEBUG, INFO, WARN, ERROR
```

### User Override Config

**Location:** `/etc/nftban/nftban.conf.local`
**Purpose:** User customizations (preserved on upgrade)
**Format:** Bash key=value pairs
**Preserved on upgrade:** YES ✅

**Usage:**
```bash
# Override settings from nftban.conf
# This file is NEVER touched by package updates
ENABLED="true"
LOG_LEVEL="DEBUG"
```

---

## 📂 Module Configurations

**Directory:** `/etc/nftban/conf.d/`
**Pattern:** `{module}.conf`
**Preserved on upgrade:** No (use .local override)

### Module List

| File | Module | Purpose |
|------|--------|---------|
| `banner.conf` | Banner | Login banner warnings |
| `cloudflare.conf` | Cloudflare | Cloudflare IP whitelist |
| `ddos.conf` | DDoS Protection | Rate limiting, connection limits |
| `directadmin.conf` | DirectAdmin | DirectAdmin integration |
| `fail2ban.conf` | Fail2Ban | Fail2Ban integration settings |
| `feeds.conf` | Threat Feeds | Feed URLs and settings |
| `geoip.conf` | GeoIP | MaxMind database settings |
| `health.conf` | Health Check | Health monitoring config |
| `log.conf` | Logging | Log rotation and levels |
| `login_alert.conf` | Login Alerts | SSH login notifications |
| `mail.conf` | Email | SMTP settings for alerts |
| `nftban-go.conf` | **Go Binaries** | **Unified Go config** ⭐ |
| `portscan.conf` | Port Scan | Port scan detection |
| `recovery.conf` | Recovery | Auto-recovery settings |
| `stats.conf` | Statistics | Stats collection |

### Module Override Pattern

**User overrides:** `/etc/nftban/conf.d/{module}.conf.local`
**Preserved on upgrade:** YES ✅

**Example:**
```bash
# /etc/nftban/conf.d/feeds.conf.local
# Override default feed settings
FEEDS_UPDATE_INTERVAL="1800"  # 30 minutes instead of 1 hour
```

---

## ⭐ Go Binary Configuration (NEW)

### Unified Go Config

**Location:** `/etc/nftban/conf.d/nftban-go.conf`
**Purpose:** **ALL Go binary settings** (feeds, geoip, geoban)
**Format:** Bash key=value pairs
**Applies to:**
- `nftban-geoip` (GeoIP lookups + GeoBan)
- `nftban-feeds` (Threat intelligence feeds)

### Configuration Sections

#### 1. System Safety Settings (CRITICAL)

```bash
# CPU Protection
GO_MAX_CPU_PERCENT="80"                     # Max CPU usage (%)
GO_CPU_CHECK_INTERVAL="5"                   # CPU check interval (seconds)
GO_CPU_THROTTLE_DELAY="100"                 # Throttle delay (ms)

# Memory Protection
GO_MAX_MEMORY_MB="4096"                     # Max memory (MB)
GO_MEMORY_PREFLIGHT_CHECK="true"            # Check before large ops
GO_MEMORY_SAFETY_MARGIN="512"               # Reserve for system (MB)

# Network Protection
GO_DOWNLOAD_TIMEOUT="30"                    # HTTP timeout (seconds)
GO_MAX_DOWNLOAD_SIZE_MB="50"                # Max file size (MB)
GO_CONNECTION_TIMEOUT="10"                  # Connection timeout (seconds)
GO_MAX_RETRIES="3"                          # Max retry attempts

# Netlink/NFTables Protection
GO_NFT_CHUNK_SIZE="4096"                    # Elements per transaction
GO_NFT_ENOBUFS_RETRY="true"                 # Retry on buffer full
GO_NFT_ENOBUFS_MAX_RETRIES="5"              # Max ENOBUFS retries
GO_NFT_ENOBUFS_RETRY_DELAY="1000"           # Retry delay (ms)
GO_NFT_TRANSACTION_TIMEOUT="30"             # Transaction timeout (seconds)

# Delta Limiting (Prevent massive changes)
GO_DELTA_LIMIT_ENABLED="true"               # Enable delta limiting
GO_DELTA_MAX_MULTIPLIER="10"                # Max size increase (10x)
GO_DELTA_MIN_ENTRIES="100"                  # Min entries before check

# Logging
GO_LOG_LEVEL="INFO"                         # DEBUG, INFO, WARN, ERROR
GO_LOG_FILE="/var/log/nftban/go-operations.log"
GO_LOG_MAX_SIZE_MB="50"                     # Max log size before rotation
GO_LOG_MAX_BACKUPS="5"                      # Number of old logs to keep
```

#### 2. HTTP Caching Settings

```bash
GO_CACHE_ENABLED="true"                     # Enable ETag caching
GO_CACHE_DIR="/var/cache/nftban/go-cache"   # Cache directory
GO_CACHE_MAX_AGE="86400"                    # Max age (24h)
GO_CACHE_MAX_SIZE_MB="500"                  # Max total cache size
GO_USER_AGENT="NFTBan/0.32.3 (+https://nftban.com)"
```

#### 3. Threat Feeds Settings

```bash
FEEDS_ENABLED="true"
FEEDS_UPDATE_INTERVAL="3600"                # 1 hour
FEEDS_AUTO_UPDATE="true"
FEEDS_MIN_ENTRIES="10"                      # Validation
FEEDS_MAX_ENTRIES="500000"                  # Truncate if exceeded

# Paths
FEEDS_STORAGE_DIR="/var/lib/nftban/feeds"
FEEDS_CACHE_DIR="/var/cache/nftban/feeds"
FEEDS_TRACKING_DIR="/var/lib/nftban/feeds/tracking"

# Logging
FEEDS_LOG_DOWNLOADS="true"
FEEDS_LOG_PARSING="true"
```

#### 4. GeoBan Settings (NEW)

```bash
GEOBAN_ENABLED="true"

# Country lists (comma-separated ISO alpha-2 codes)
GEOBAN_BANNED_COUNTRIES=""                  # e.g., "CN,RU,KP"
GEOBAN_WHITELISTED_COUNTRIES=""             # e.g., "US,GB,DE"

# Update settings
GEOBAN_UPDATE_INTERVAL="86400"              # 24 hours
GEOBAN_AUTO_UPDATE="true"
GEOBAN_SOURCE="ipdeny"                      # IPdeny.com

# Paths
GEOBAN_FILES_DIR="/etc/nftban/geoban.d"     # Country IP config files
GEOBAN_CACHE_DIR="/var/cache/nftban/geoban" # HTTP cache
GEOBAN_TRACKING_DIR="/var/lib/nftban/geoban/tracking"

# Operations
GEOBAN_ATOMIC="true"                        # Atomic nftables ops
GEOBAN_VALIDATE_BEFORE_LOAD="true"

# Logging
GEOBAN_LOG_DOWNLOADS="true"
GEOBAN_LOG_NFTABLES="true"
```

#### 5. GeoIP Settings

```bash
GEOIP_ENABLED="true"
GEOIP_DATABASE="/var/lib/nftban/geoip/GeoLite2-City.mmdb"
GEOIP_AUTO_UPDATE="true"
GEOIP_UPDATE_INTERVAL="604800"              # Weekly

# MaxMind credentials (required for auto-update)
MAXMIND_LICENSE_KEY=""                      # Free key from maxmind.com
MAXMIND_ACCOUNT_ID=""

# Cache
GEOIP_CACHE_ENABLED="true"
GEOIP_CACHE_SIZE="10000"                    # Max cached lookups
GEOIP_CACHE_TTL="3600"                      # Cache TTL (1h)
```

#### 6. NFTables Integration

```bash
# Table names
NFT_TABLE_MAIN="nftban_main"
NFT_TABLE_RUNTIME="nftban_runtime"

# Feed sets
NFT_SET_FEED_V4="feed_v4"
NFT_SET_FEED_V6="feed_v6"

# GeoBan sets
NFT_SET_GEOBAN_V4="blacklist_v4"
NFT_SET_GEOBAN_V6="blacklist_v6"
NFT_SET_GEOWL_V4="whitelist_v4"
NFT_SET_GEOWL_V6="whitelist_v6"
```

**Override this config:**
```bash
# Create /etc/nftban/conf.d/nftban-go.conf.local
GO_MAX_CPU_PERCENT="50"  # Lower CPU limit
GO_MAX_MEMORY_MB="2048"  # Lower memory limit
```

---

## 🌍 GeoBan Country Files

**Directory:** `/etc/nftban/geoban.d/`
**Pattern:** `{priority}-{action}-{CC}.conf`
**Auto-generated:** YES (by `nftban geoip ban/whitelist`)
**Manually edit:** NO (will be overwritten)

### Naming Convention

- **Priority:** `40` (whitelist) or `50` (ban)
- **Action:** `ban` or `whitelist`
- **CC:** ISO alpha-2 country code (uppercase)

### Examples

```
/etc/nftban/geoban.d/
  40-whitelist-US.conf    # United States whitelist
  40-whitelist-GB.conf    # United Kingdom whitelist
  50-ban-CN.conf          # China ban
  50-ban-RU.conf          # Russia ban
  50-ban-KP.conf          # North Korea ban
```

### File Format

```bash
# Auto-generated by NFTBan GeoBan: 2025-11-05T21:57:43Z
# Country: CN (BAN)
# Source: IPdeny.com
#
# DO NOT EDIT - This file is managed by nftban geoip ban
#

# IPv4 Ranges
1.0.1.0/24
1.0.2.0/23
...

# IPv6 Ranges
2001:250::/35
2001:252::/32
...
```

---

## 📝 Data Files

### GeoBan HTTP Cache

**Directory:** `/var/cache/nftban/geoban/`
**Purpose:** Cache downloaded country IP files (ETag support)
**Pattern:** `{CC}-{v4|v6}.{zone|etag}`

```
/var/cache/nftban/geoban/
  CN-v4.zone              # China IPv4 ranges (cached)
  CN-v4.etag              # ETag for cache validation
  CN-v6.zone              # China IPv6 ranges (cached)
  CN-v6.etag              # ETag for cache validation
```

### GeoBan Tracking Metadata

**Directory:** `/var/lib/nftban/geoban/tracking/`
**Purpose:** Track what was loaded and when
**Format:** JSON
**Pattern:** `{action}-{CC}.json`

```
/var/lib/nftban/geoban/tracking/
  ban-CN.json             # Tracks CN ban state
  whitelist-US.json       # Tracks US whitelist state
```

**Example content:**
```json
{
  "country": "CN",
  "action": "ban",
  "timestamp": 1699215463,
  "ipv4": ["1.0.1.0/24", "1.0.2.0/23", ...],
  "ipv6": ["2001:250::/35", "2001:252::/32", ...],
  "ipv4_count": 17432,
  "ipv6_count": 3124
}
```

### Threat Feeds Storage

**Directory:** `/var/lib/nftban/feeds/`
**Purpose:** Parsed feed files ready for loading
**Pattern:** `{feed_name}.txt`

```
/var/lib/nftban/feeds/
  spamhaus-drop.txt       # Parsed Spamhaus DROP feed
  greensnow.txt           # Parsed GreenSnow feed
```

### GeoIP Database

**Location:** `/var/lib/nftban/geoip/GeoLite2-City.mmdb`
**Purpose:** MaxMind GeoLite2 City database
**Size:** ~70MB
**Updated:** Weekly (if GEOIP_AUTO_UPDATE="true")

---

## 📋 Log Files

### Unified Go Operations Log

**Location:** `/var/log/nftban/go-operations.log`
**Purpose:** All Go binary operations (feeds, geoip, geoban)
**Format:** Plain text with timestamps
**Rotation:** Managed by `GO_LOG_MAX_SIZE_MB` and `GO_LOG_MAX_BACKUPS`

**Example entries:**
```
2025-11-05T21:57:40Z [INFO] GeoBan: Fetching country CN
2025-11-05T21:57:42Z [INFO] HTTP: Downloaded 3.2MB from ipdeny.com
2025-11-05T21:57:43Z [INFO] Parser: Found 17,432 IPv4 + 3,124 IPv6 ranges
2025-11-05T21:57:44Z [INFO] NFTables: Loaded 20,556 elements in 4 chunks
2025-11-05T21:57:44Z [INFO] GeoBan: Successfully banned CN
```

### Main NFTBan Log

**Location:** `/var/log/nftban/nftban.log`
**Purpose:** General NFTBan operations (bash modules)
**Format:** Plain text with timestamps
**Rotation:** Managed by `/etc/logrotate.d/nftban`

### Systemd Journal

**Access:** `journalctl -u nftban`
**Purpose:** Service start/stop/errors
**Retention:** Managed by systemd

---

## 🔐 Secrets

### Directory

**Location:** `/etc/nftban/secrets.d/`
**Purpose:** Sensitive credentials (API keys, passwords)
**Permissions:** 0600 (owner read/write only)
**Never commit:** YES - Add to `.gitignore`

### Files

```
/etc/nftban/secrets.d/
  maxmind.key             # MaxMind license key
  smtp.password           # SMTP password for email alerts
```

---

## 📂 Directory Structure (Complete)

```
/etc/nftban/                           # Main configuration directory
  ├── nftban.conf                      # Main config
  ├── nftban.conf.local                # User overrides (preserved)
  ├── nftban.env.example               # Environment variables template
  ├── baseline.nft                     # Base nftables rules
  │
  ├── conf.d/                          # Module configurations
  │   ├── banner.conf
  │   ├── cloudflare.conf
  │   ├── ddos.conf
  │   ├── fail2ban.conf
  │   ├── feeds.conf
  │   ├── geoip.conf
  │   ├── health.conf
  │   ├── log.conf
  │   ├── login_alert.conf
  │   ├── mail.conf
  │   ├── nftban-go.conf               # ⭐ Unified Go config
  │   ├── portscan.conf
  │   ├── recovery.conf
  │   └── stats.conf
  │   └── *.conf.local                 # User overrides (preserved)
  │
  ├── geoban.d/                        # ⭐ GeoBan country files (NEW)
  │   ├── 40-whitelist-US.conf
  │   ├── 40-whitelist-GB.conf
  │   ├── 50-ban-CN.conf
  │   └── 50-ban-RU.conf
  │
  ├── feeds.d/                         # Feed-specific includes
  ├── ports.d/                         # Port configurations (00-ssh.conf, etc.)
  ├── rules.d/                         # Custom nftables rules
  ├── secrets.d/                       # Sensitive credentials (0600)
  ├── blacklist.d/                     # Manual IP blacklist
  └── whitelist.d/                     # Manual IP whitelist

/var/lib/nftban/                       # State and data files
  ├── feeds/                           # Threat feeds
  │   ├── spamhaus-drop.txt
  │   ├── greensnow.txt
  │   └── tracking/                    # Feed tracking metadata
  │
  ├── geoban/                          # ⭐ GeoBan data (NEW)
  │   └── tracking/                    # GeoBan tracking metadata
  │       ├── ban-CN.json
  │       └── whitelist-US.json
  │
  ├── geoip/                           # GeoIP database
  │   └── GeoLite2-City.mmdb
  │
  ├── backup/                          # Configuration backups
  ├── config/                          # Runtime config cache
  ├── keyring/                         # Stored secrets
  ├── metrics/                         # Stats and metrics
  ├── reports/                         # Generated reports
  ├── snapshots/                       # NFTables snapshots
  └── state/                           # Service state files

/var/cache/nftban/                     # Temporary cache
  ├── feeds/                           # Feed HTTP cache
  ├── geoban/                          # ⭐ GeoBan HTTP cache (NEW)
  │   ├── CN-v4.zone
  │   ├── CN-v4.etag
  │   ├── CN-v6.zone
  │   └── CN-v6.etag
  ├── geoip/                           # GeoIP cache
  ├── go-cache/                        # ⭐ Unified Go cache
  └── tmp/                             # Temporary files

/var/log/nftban/                       # Log files
  ├── nftban.log                       # Main log
  ├── go-operations.log                # ⭐ Unified Go log (NEW)
  ├── feeds.log                        # Feeds log (legacy)
  └── archived/                        # Rotated logs
```

---

## 🔍 Finding Configuration Values

### "Where is the setting for..."

**...CPU limits for Go operations?**
→ `/etc/nftban/conf.d/nftban-go.conf` → `GO_MAX_CPU_PERCENT`

**...country blocklist?**
→ `/etc/nftban/conf.d/nftban-go.conf` → `GEOBAN_BANNED_COUNTRIES`
→ OR generated files in `/etc/nftban/geoban.d/`

**...GeoIP database location?**
→ `/etc/nftban/conf.d/nftban-go.conf` → `GEOIP_DATABASE`

**...threat feed URLs?**
→ `/etc/nftban/conf.d/feeds.conf` → `FEED_*_URL` variables

**...MaxMind license key?**
→ `/etc/nftban/conf.d/nftban-go.conf` → `MAXMIND_LICENSE_KEY`

**...log file location?**
→ `/etc/nftban/conf.d/nftban-go.conf` → `GO_LOG_FILE`

**...cache directory?**
→ `/etc/nftban/conf.d/nftban-go.conf` → `GO_CACHE_DIR`

**...nftables chunk size?**
→ `/etc/nftban/conf.d/nftban-go.conf` → `GO_NFT_CHUNK_SIZE`

---

## ⚙️ Configuration Priority

NFTBan loads configuration in this order (later overrides earlier):

1. **Built-in defaults** (in bash/Go code)
2. `/etc/nftban/nftban.conf` (main config)
3. `/etc/nftban/conf.d/*.conf` (module configs)
4. `/etc/nftban/nftban.conf.local` (user main override)
5. `/etc/nftban/conf.d/*.conf.local` (user module overrides)

**Example:**
```bash
# Default (in code)
GO_MAX_CPU_PERCENT=80

# Module config (/etc/nftban/conf.d/nftban-go.conf)
GO_MAX_CPU_PERCENT=80

# User override (/etc/nftban/conf.d/nftban-go.conf.local)
GO_MAX_CPU_PERCENT=50  # ← This wins!
```

---

## 📝 Best Practices

### 1. Never Edit Package-Managed Files

**DON'T edit these directly** (will be overwritten on upgrade):
- `/etc/nftban/nftban.conf`
- `/etc/nftban/conf.d/*.conf`
- `/etc/nftban/geoban.d/*.conf` (auto-generated)

**DO create .local overrides**:
- `/etc/nftban/nftban.conf.local`
- `/etc/nftban/conf.d/*.conf.local`

### 2. Use .local Files For Customization

```bash
# WRONG: Edit feeds.conf directly
vi /etc/nftban/conf.d/feeds.conf

# RIGHT: Create override file
vi /etc/nftban/conf.d/feeds.conf.local
```

### 3. Document Your Changes

```bash
# /etc/nftban/conf.d/nftban-go.conf.local
# Changed 2025-11-05: Lower CPU limit for shared hosting
GO_MAX_CPU_PERCENT=40

# Changed 2025-11-05: Increase timeout for slow WAN
GO_DOWNLOAD_TIMEOUT=60
```

### 4. Keep Secrets Secure

```bash
# Set strict permissions on secrets
chmod 600 /etc/nftban/secrets.d/*

# Never commit to git
echo "secrets.d/" >> .gitignore
```

### 5. Backup Before Changes

```bash
# Backup current config
cp /etc/nftban/conf.d/nftban-go.conf /etc/nftban/conf.d/nftban-go.conf.backup

# Now make changes to .local file
vi /etc/nftban/conf.d/nftban-go.conf.local
```

---

## 🆘 Troubleshooting

### "My changes aren't taking effect"

1. **Check you edited the right file**
   - Use `.local` files, not package-managed files

2. **Check syntax**
   ```bash
   # No spaces around =
   GO_MAX_CPU_PERCENT=80   # ✅ Correct
   GO_MAX_CPU_PERCENT = 80 # ❌ Wrong
   ```

3. **Check file permissions**
   ```bash
   ls -l /etc/nftban/conf.d/nftban-go.conf.local
   # Should be: -rw-r--r-- (644)
   ```

4. **Reload configuration**
   ```bash
   sudo nftban reload
   # Or restart service
   sudo systemctl restart nftban
   ```

5. **Check logs for errors**
   ```bash
   tail -f /var/log/nftban/go-operations.log
   ```

### "Where is this setting defined?"

```bash
# Search all config files
grep -r "GO_MAX_CPU_PERCENT" /etc/nftban/

# Check what value is being used
nftban config show | grep GO_MAX_CPU_PERCENT
```

### "I want to reset to defaults"

```bash
# Remove your overrides
rm /etc/nftban/conf.d/nftban-go.conf.local

# Reinstall package (restores defaults)
sudo dnf reinstall nftban
```

---

## 📚 Related Documentation

- **[INDEX.md](INDEX.md)** - Documentation index
- **[GO_COMPILATION_GUIDE.md](GO_COMPILATION_GUIDE.md)** - Build procedures
- **[GO_SYSTEM_PROTECTION.md](GO_SYSTEM_PROTECTION.md)** - Safety limits explained
- **[GEOBAN_FEATURE.md](GEOBAN_FEATURE.md)** - GeoBan user guide
- **[GEOBAN_ACHIEVEMENT.md](GEOBAN_ACHIEVEMENT.md)** - GeoBan achievement overview

---

**Last Updated:** 2025-11-05
**Maintained By:** NFTBan Development Team
**License:** MPL-2.0
