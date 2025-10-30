# Threat Intelligence Feeds

**Managing threat intelligence feeds in NFTBan v0.10.0**

NFTBan v0.10.0 includes an advanced threat intelligence system that downloads and processes feeds from 14+ reputable sources. The feeds are processed by a Go binary for 10-60x faster performance compared to bash scripts.

---

## Table of Contents

- [What Are Threat Feeds?](#what-are-threat-feeds)
- [Available Feeds](#available-feeds)
- [Feed Categories](#feed-categories)
- [Managing Feeds](#managing-feeds)
- [Performance](#performance)
- [Update Schedule](#update-schedule)
- [Feed Storage](#feed-storage)
- [Best Practices](#best-practices)
- [Troubleshooting](#troubleshooting)

---

## What Are Threat Feeds?

Threat intelligence feeds are regularly updated lists of known malicious IP addresses and networks from security research organizations worldwide.

### Why Use Threat Feeds?

**Proactive Defense**:
- Block known attackers before they reach your services
- Protect against botnets, malware C&C servers, and known compromised hosts
- Reduce noise in logs by filtering out known bad actors

**Intelligence Sources**:
- **Spamhaus**: Anti-spam organization (1,500+ IPs)
- **Abuse.ch**: Malware and botnet tracking (8,000+ IPs)
- **FireHOL**: Community-maintained threat lists (80,000+ IPs)
- **Blocklist.de**: Real-time attack reporting (20,000+ IPs)
- **GreenSnow**: SSH/FTP attack tracking (8,000+ IPs)
- **StopForumSpam**: Forum spam detection (10,000+ IPs)

### How Feeds Work in NFTBan

```
┌──────────────────┐
│  Download Feeds  │ (curl/wget, parallel downloads)
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│  Parse with Go   │ (nftban-feeds binary, <1 second)
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│ Load to nftables │ (atomic reload, no disruption)
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│  Block Traffic   │ (kernel-level, <1µs lookup)
└──────────────────┘
```

**Performance**:
- **v0.9.x (bash)**: 60-90 seconds for 100K IPs
- **v0.10.0 (Go)**: <1 second for 1M IPs (60x faster!)

---

## Available Feeds

NFTBan v0.10.0 includes 14 pre-configured threat feeds across 4 categories.

### All Feeds at a Glance

| Feed Name | Category | Size | Update | Description |
|-----------|----------|------|--------|-------------|
| **SPAMHAUS_DROP** | protection | ~1,000 | Daily | Known spam sources |
| **SPAMHAUS_EDROP** | protection | ~500 | Daily | Extended network blocks |
| **ABUSECH_FEODO** | protection | ~5,000 | Daily | Botnet C&C servers |
| **ABUSECH_SSL** | protection | ~3,000 | Daily | SSL/TLS abuse |
| **FIREHOL_LEVEL1** | protection | ~30,000 | Daily | High-confidence threats |
| **FIREHOL_LEVEL2** | protection | ~50,000 | Weekly | Medium-confidence threats |
| **BLOCKLISTDE_SSH** | ssh | ~10,000 | Daily | SSH brute force attacks |
| **GREENSNOW** | ssh | ~8,000 | Daily | SSH/FTP attacks |
| **FIREHOL_SSH** | ssh | ~15,000 | Daily | SSH password attacks |
| **BLOCKLISTDE_APACHE** | web | ~3,000 | Daily | Web server attacks |
| **BLOCKLISTDE_NGINX** | web | ~2,000 | Daily | Nginx attacks |
| **FIREHOL_WEBCAM** | web | ~2,000 | Weekly | Webcam/IoT attacks |
| **BLOCKLISTDE_MAIL** | email | ~5,000 | Daily | Mail server attacks |
| **STOPFORUMSPAM** | email | ~10,000 | Weekly | Forum spam sources |

**Total**: ~144,500 IPs when all feeds enabled

**⚠️  IMPORTANT**: All feeds are **disabled by default** for safety. You must explicitly enable them.

---

## Feed Categories

Feeds are organized into 4 categories for easy management:

### 1. Protection (General Security)

**Purpose**: Block general threats, botnets, malware C&C servers

**Feeds**:
- **Spamhaus DROP/EDROP**: Known spam sources and hijacked networks (high confidence)
- **Abuse.ch Feodo**: Feodo/Emotet/TrickBot botnet C&C servers (critical)
- **Abuse.ch SSL**: SSL/TLS certificate abuse (malware infrastructure)
- **FireHOL Level 1**: High-confidence threats from multiple sources (recommended)
- **FireHOL Level 2**: Medium-confidence threats (larger, more false positives)

**Recommended for**:
- All servers (especially `maximum` and `mixed` profiles)
- Servers exposed to the internet

**Example**:
```bash
# Enable all protection feeds
sudo nftban feeds enable-category protection
```

### 2. SSH (SSH Attack Protection)

**Purpose**: Block SSH brute force and dictionary attacks

**Feeds**:
- **Blocklist.de SSH**: Real-time SSH brute force reports (community-driven)
- **GreenSnow**: SSH/FTP attack sources (daily updates)
- **FireHOL SSH**: SSH password attack aggregation (multiple sources)

**Recommended for**:
- Servers with SSH exposed to internet (port 22)
- High-value targets
- Servers with many failed login attempts

**Note**: These feeds complement Fail2Ban (which handles dynamic banning). Feeds provide proactive blocking of known SSH attackers.

**Example**:
```bash
# Enable all SSH feeds
sudo nftban feeds enable-category ssh
```

### 3. Web (Web Server Attack Protection)

**Purpose**: Block web application attacks, exploit scanners, bad bots

**Feeds**:
- **Blocklist.de Apache**: Apache-specific attacks (SQL injection, XSS, etc.)
- **Blocklist.de Nginx**: Nginx-specific attacks
- **FireHOL Webcam**: Webcam/IoT exploitation attempts

**Recommended for**:
- Web servers (Nginx, Apache)
- Application servers
- API endpoints
- Servers with `web-server` profile

**Example**:
```bash
# Enable all web feeds
sudo nftban feeds enable-category web
```

### 4. Email (Mail Server & Spam Protection)

**Purpose**: Block mail server attacks and spam sources

**Feeds**:
- **Blocklist.de Mail**: SMTP attacks, dictionary attacks on mail servers
- **StopForumSpam**: Forum spam sources (also targets comment spam)

**Recommended for**:
- Mail servers (Postfix, Exim, Dovecot)
- Servers with `mail-server` profile
- Servers with contact forms or comments

**Example**:
```bash
# Enable all email feeds
sudo nftban feeds enable-category email
```

---

## Managing Feeds

### List All Feeds

View all available feeds and their status:

```bash
nftban feeds list
```

**Output**:
```
NFTBan Threat Intelligence Feeds v0.10.0
════════════════════════════════════════

┌──────────────────────────────────────────────────────────────────┐
│ PROTECTION (General Security & Protection)                       │
├────────────────────┬────────┬──────────┬────────────────────────┤
│ Feed               │ Status │ Size     │ Description            │
├────────────────────┼────────┼──────────┼────────────────────────┤
│ SPAMHAUS_DROP      │ ✓ ON   │ ~1,000   │ Known spam sources     │
│ SPAMHAUS_EDROP     │ ✗ OFF  │ ~500     │ Extended blocks        │
│ ABUSECH_FEODO      │ ✓ ON   │ ~5,000   │ Botnet C&C servers     │
│ ABUSECH_SSL        │ ✗ OFF  │ ~3,000   │ SSL/TLS abuse          │
│ FIREHOL_LEVEL1     │ ✓ ON   │ ~30,000  │ High-confidence        │
│ FIREHOL_LEVEL2     │ ✗ OFF  │ ~50,000  │ Medium-confidence      │
└────────────────────┴────────┴──────────┴────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│ SSH (SSH Attack Protection)                                      │
├────────────────────┬────────┬──────────┬────────────────────────┤
│ BLOCKLISTDE_SSH    │ ✓ ON   │ ~10,000  │ SSH brute force        │
│ GREENSNOW          │ ✓ ON   │ ~8,000   │ SSH/FTP attacks        │
│ FIREHOL_SSH        │ ✗ OFF  │ ~15,000  │ SSH password attacks   │
└────────────────────┴────────┴──────────┴────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│ WEB (Web Server Attack Protection)                               │
├────────────────────┬────────┬──────────┬────────────────────────┤
│ BLOCKLISTDE_APACHE │ ✓ ON   │ ~3,000   │ Apache attacks         │
│ BLOCKLISTDE_NGINX  │ ✓ ON   │ ~2,000   │ Nginx attacks          │
│ FIREHOL_WEBCAM     │ ✗ OFF  │ ~2,000   │ Webcam/IoT attacks     │
└────────────────────┴────────┴──────────┴────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│ EMAIL (Mail Server & Spam Protection)                            │
├────────────────────┬────────┬──────────┬────────────────────────┤
│ BLOCKLISTDE_MAIL   │ ✓ ON   │ ~5,000   │ Mail server attacks    │
│ STOPFORUMSPAM      │ ✗ OFF  │ ~10,000  │ Forum spam sources     │
└────────────────────┴────────┴──────────┴────────────────────────┘

Summary:
  Total Feeds: 14
  Enabled: 7
  Disabled: 7
  Total IPs (enabled): ~64,000
```

### Interactive Feed Selection (Recommended)

Use the interactive menu to select feeds:

```bash
sudo nftban feeds select
```

**Example interaction**:
```
NFTBan Feed Selection v0.10.0
═════════════════════════════

Select feeds to enable/disable:

PROTECTION:
  [1] SPAMHAUS_DROP      (✓ ENABLED)  - Known spam sources (~1,000)
  [2] SPAMHAUS_EDROP     (✗ DISABLED) - Extended blocks (~500)
  [3] ABUSECH_FEODO      (✓ ENABLED)  - Botnet C&C servers (~5,000)
  [4] ABUSECH_SSL        (✗ DISABLED) - SSL/TLS abuse (~3,000)
  [5] FIREHOL_LEVEL1     (✓ ENABLED)  - High-confidence threats (~30,000)
  [6] FIREHOL_LEVEL2     (✗ DISABLED) - Medium-confidence threats (~50,000)

SSH:
  [7] BLOCKLISTDE_SSH    (✓ ENABLED)  - SSH brute force (~10,000)
  [8] GREENSNOW          (✓ ENABLED)  - SSH/FTP attacks (~8,000)
  [9] FIREHOL_SSH        (✗ DISABLED) - SSH password attacks (~15,000)

WEB:
  [10] BLOCKLISTDE_APACHE (✓ ENABLED) - Apache attacks (~3,000)
  [11] BLOCKLISTDE_NGINX  (✓ ENABLED) - Nginx attacks (~2,000)
  [12] FIREHOL_WEBCAM     (✗ DISABLED) - Webcam/IoT attacks (~2,000)

EMAIL:
  [13] BLOCKLISTDE_MAIL   (✓ ENABLED) - Mail server attacks (~5,000)
  [14] STOPFORUMSPAM      (✗ DISABLED) - Forum spam (~10,000)

Commands:
  - Enter numbers: 1 2 3 (toggle individual feeds)
  - Range: 1-6 (toggle feeds 1 through 6)
  - Category: ssh (toggle all SSH feeds)
  - all: Toggle all feeds
  - done: Save and exit

Select feeds> 2 4 9

✓ Enabled SPAMHAUS_EDROP
✓ Enabled ABUSECH_SSL
✓ Enabled FIREHOL_SSH

Select feeds> done

Configuration saved to /etc/nftban/conf.d/feeds.conf
Run 'sudo nftban feeds update' to download and apply changes.
```

### Enable Specific Feed

```bash
# Enable a single feed
sudo nftban feeds enable SPAMHAUS_DROP

# Enable multiple feeds
sudo nftban feeds enable SPAMHAUS_DROP ABUSECH_FEODO FIREHOL_LEVEL1
```

### Enable by Category

```bash
# Enable all protection feeds
sudo nftban feeds enable-category protection

# Enable all SSH feeds
sudo nftban feeds enable-category ssh

# Enable all web feeds
sudo nftban feeds enable-category web

# Enable all email feeds
sudo nftban feeds enable-category email
```

### Disable Feeds

```bash
# Disable a single feed
sudo nftban feeds disable FIREHOL_LEVEL2

# Disable multiple feeds
sudo nftban feeds disable FIREHOL_LEVEL2 STOPFORUMSPAM

# Disable entire category
sudo nftban feeds disable-category web
```

### Update Feeds

Download and apply the latest threat intelligence:

```bash
sudo nftban feeds update
```

**Example output**:
```
NFTBan Feed Update v0.10.0
══════════════════════════

⏳ Updating threat intelligence feeds...

Enabled feeds: 7/14

Downloading feeds (parallel):
  [1/7] SPAMHAUS_DROP       ✓ Downloaded (1,234 IPs)
  [2/7] ABUSECH_FEODO       ✓ Downloaded (4,567 IPs)
  [3/7] FIREHOL_LEVEL1      ✓ Downloaded (28,901 IPs)
  [4/7] BLOCKLISTDE_SSH     ✓ Downloaded (9,876 IPs)
  [5/7] GREENSNOW           ✓ Downloaded (7,654 IPs)
  [6/7] BLOCKLISTDE_APACHE  ✓ Downloaded (2,890 IPs)
  [7/7] BLOCKLISTDE_MAIL    ✓ Downloaded (4,321 IPs)

Processing with Go binary...
  - Parsing: <1 second ✓
  - Deduplicating: 59,443 unique IPs
  - Validating: All valid
  - Formatting: nftables format

Applying to nftables...
  - Loading to nftban_v4:feeds set: ✓
  - Loading to nftban_v6:feeds set: ✓
  - Atomic reload: ✓

════════════════════════════════════════
Total IPs Blocked: 59,443
Update Time: 2.1 seconds
Status: SUCCESS ✓
════════════════════════════════════════

Last updated: 2025-10-28 14:32:05
Next update: 2025-10-29 03:00:00 (via timer)
```

**Performance note**: Go binary processes 1M IPs in <1 second!

### Check Feed Status

```bash
# Show current status
sudo nftban feeds status

# Show detailed statistics
sudo nftban feeds stats
```

**Output**:
```
NFTBan Feeds Status
═══════════════════

Feeds System: ACTIVE ✓
Last Update: 2025-10-28 14:32:05 (2 hours ago)
Next Update: 2025-10-29 03:00:00 (7 hours)

Enabled Feeds: 7/14
Total IPs Blocked: 59,443
  - IPv4: 58,901
  - IPv6: 542

nftables Sets:
  - nftban_v4:feeds: 58,901 elements
  - nftban_v6:feeds: 542 elements

Update Scheduler: ACTIVE (systemd timer)
Update Interval: 3600 seconds (1 hour)

Recent Updates:
  2025-10-28 14:32:05 - SUCCESS (59,443 IPs)
  2025-10-28 13:32:05 - SUCCESS (59,012 IPs)
  2025-10-28 12:32:05 - SUCCESS (58,789 IPs)
```

---

## Performance

NFTBan v0.10.0 uses Go binaries for feed processing, providing massive performance improvements.

### Performance Comparison

| Operation | v0.9.x (bash) | v0.10.0 (Go) | Improvement |
|-----------|---------------|---------------|-------------|
| Parse 100K IPs | 60 seconds | 0.8 seconds | **75x faster** |
| Parse 500K IPs | 300 seconds | 2.1 seconds | **143x faster** |
| Parse 1M IPs | 600+ seconds | 3.5 seconds | **171x faster** |
| Deduplicate 100K | 30 seconds | 0.1 seconds | **300x faster** |
| Memory usage | ~500 MB | ~50 MB | **10x less** |

### Why Go is Faster

**Bash limitations**:
- Spawns processes for every operation (grep, awk, sort, uniq)
- No concurrent processing
- High memory usage with large datasets
- String manipulation is slow

**Go advantages**:
- Compiled to native code (no interpreter overhead)
- Built-in concurrency (goroutines)
- Efficient memory management
- Fast string/regex processing
- Parallel feed downloads

### Real-World Impact

**Scenario**: Web server with 7 feeds enabled (60K IPs)

**v0.9.x (bash)**:
```
Download: 10 seconds (sequential)
Parse: 45 seconds (bash loops)
Deduplicate: 20 seconds (sort | uniq)
Load to nftables: 5 seconds
─────────────────────────────
Total: 80 seconds
```

**v0.10.0 (Go)**:
```
Download: 3 seconds (parallel)
Parse: 0.5 seconds (Go binary)
Deduplicate: 0.1 seconds (Go maps)
Load to nftables: 0.5 seconds
─────────────────────────────
Total: 4.1 seconds (19.5x faster!)
```

### Monitoring Performance

```bash
# Time feed update
time sudo nftban feeds update

# Check Go binary version
/usr/lib/nftban/bin/nftban-feeds --version

# Detailed performance stats
sudo nftban feeds update --verbose
```

---

## Update Schedule

### Automatic Updates (Recommended)

NFTBan updates feeds automatically via systemd timer:

```bash
# Enable automatic updates (runs every hour)
sudo systemctl enable --now nftban-feeds.timer

# Check timer status
systemctl status nftban-feeds.timer

# View next scheduled run
systemctl list-timers nftban-feeds.timer
```

**Default schedule**: Every hour (configurable)

**Configuration** (`/etc/nftban/conf.d/feeds.conf`):
```bash
FEEDS_AUTO_UPDATE="true"
FEEDS_UPDATE_INTERVAL="3600"  # 1 hour (seconds)
```

### Manual Updates

```bash
# Update all enabled feeds
sudo nftban feeds update

# Force update (even if not stale)
sudo nftban feeds update --force

# Update specific feed
sudo nftban feeds update SPAMHAUS_DROP

# Update by category
sudo nftban feeds update-category ssh
```

### Update Frequency Recommendations

| Feed | Recommended | Why |
|------|-------------|-----|
| SPAMHAUS_* | Daily | Updates daily, stable |
| ABUSECH_* | Hourly | Real-time botnet tracking |
| FIREHOL_LEVEL1 | Daily | Curated, stable |
| FIREHOL_LEVEL2 | Weekly | Large, less critical |
| BLOCKLISTDE_* | Hourly | Real-time reports |
| GREENSNOW | Daily | Updates daily |
| STOPFORUMSPAM | Weekly | Slow-changing |

**General rule**:
- **Hourly**: Real-time threat feeds (Abuse.ch, Blocklist.de)
- **Daily**: Curated feeds (Spamhaus, FireHOL Level 1, GreenSnow)
- **Weekly**: Large/stable feeds (FireHOL Level 2, StopForumSpam)

### Cron Alternative

If not using systemd, set up cron:

```bash
# Edit crontab
sudo crontab -e

# Add this line (update every hour)
0 * * * * /usr/sbin/nftban feeds update >> /var/log/nftban/feeds-cron.log 2>&1

# Or daily at 3am
0 3 * * * /usr/sbin/nftban feeds update >> /var/log/nftban/feeds-cron.log 2>&1
```

---

## Feed Storage

### Directory Structure

```
/var/lib/nftban/feeds/          # Parsed feeds (ready for nftables)
├── SPAMHAUS_DROP.txt           # Parsed IP list
├── ABUSECH_FEODO.txt
├── FIREHOL_LEVEL1.txt
└── ...

/var/cache/nftban/feeds/        # Download cache
├── SPAMHAUS_DROP.raw           # Raw downloaded feed
├── ABUSECH_FEODO.raw
└── ...

/var/log/nftban/
└── feeds.log                   # Feed update log
```

### Feed File Formats

**Parsed format** (`/var/lib/nftban/feeds/*.txt`):
```
# Clean IP list (one per line)
192.0.2.1
192.0.2.2
198.51.100.0/24
2001:db8::/32
```

**nftables format**:
```nft
# Loaded directly to nftables sets
define feeds_v4 = {
    192.0.2.1,
    192.0.2.2,
    198.51.100.0/24
}

define feeds_v6 = {
    2001:db8::/32
}
```

### Disk Space

| Feeds Enabled | Raw Size | Parsed Size | Total |
|---------------|----------|-------------|-------|
| 3 feeds | ~10 MB | ~5 MB | ~15 MB |
| 7 feeds | ~25 MB | ~12 MB | ~37 MB |
| 14 feeds (all) | ~50 MB | ~25 MB | ~75 MB |

**Storage location**: `/var/lib/nftban/` and `/var/cache/nftban/`

**Cleanup old feeds**:
```bash
# Remove cache (downloads re-fetched on next update)
sudo rm -rf /var/cache/nftban/feeds/*

# Remove parsed feeds (regenerated on next update)
sudo rm -rf /var/lib/nftban/feeds/*
```

---

## Best Practices

### Choosing Feeds

**Start Small** (Recommended for new installations):
```bash
# Essential protection (low false positive rate)
sudo nftban feeds enable SPAMHAUS_DROP
sudo nftban feeds enable ABUSECH_FEODO
sudo nftban feeds enable FIREHOL_LEVEL1
```

**Add Category-Specific** (Based on server role):
```bash
# Web server
sudo nftban feeds enable-category web

# Mail server
sudo nftban feeds enable-category email

# SSH-exposed server
sudo nftban feeds enable-category ssh
```

**Expand Gradually**:
- Monitor for false positives
- Add more feeds as confidence grows
- Avoid enabling all feeds immediately

### Avoiding False Positives

**High confidence** (low false positives):
- SPAMHAUS_DROP
- SPAMHAUS_EDROP
- ABUSECH_FEODO
- ABUSECH_SSL
- FIREHOL_LEVEL1

**Medium confidence** (some false positives):
- BLOCKLISTDE_* (community-reported)
- GREENSNOW
- FIREHOL_SSH

**Lower confidence** (more false positives):
- FIREHOL_LEVEL2 (large, less curated)
- STOPFORUMSPAM (forum-specific)

**Mitigation**:
```bash
# Whitelist important IPs before enabling aggressive feeds
sudo nftban whitelist add 203.0.113.100  # Your office
sudo nftban whitelist add 198.51.100.0/24  # Your network

# Check if IP is in feeds before whitelisting
nftban feeds check 203.0.113.100
```

### Monitoring Feed Updates

```bash
# Watch feed update log in real-time
tail -f /var/log/nftban/feeds.log

# Check for errors
grep ERROR /var/log/nftban/feeds.log

# Check last update status
sudo nftban feeds status
```

### Testing New Feeds

Before enabling a feed in production:

```bash
# 1. Enable feed
sudo nftban feeds enable FIREHOL_LEVEL2

# 2. Download and check size
sudo nftban feeds update --verbose

# 3. Check if legitimate IPs are blocked
nftban feeds check YOUR_IP
nftban feeds check YOUR_PARTNER_IP

# 4. Monitor for false positives (24 hours)
tail -f /var/log/nftban/nftban.log

# 5. If issues, disable immediately
sudo nftban feeds disable FIREHOL_LEVEL2
sudo nftban feeds update
```

### Performance Tuning

For servers with limited resources:

```bash
# Limit max entries
echo 'FEEDS_MAX_ENTRIES="100000"' >> /etc/nftban/nftban.conf.local

# Reduce update frequency
echo 'FEEDS_UPDATE_INTERVAL="7200"' >> /etc/nftban/nftban.conf.local

# Disable large feeds
sudo nftban feeds disable FIREHOL_LEVEL2
```

### Security Considerations

**Verify feed sources**:
- All feeds in NFTBan use HTTPS URLs
- Sources are reputable organizations
- Feeds are updated regularly

**DNS security**:
```bash
# Ensure DNS is secure (prevent poisoning)
# Use trusted DNS servers in /etc/resolv.conf
nameserver 1.1.1.1  # Cloudflare
nameserver 8.8.8.8  # Google
```

**Feed integrity**:
```bash
# Feeds are validated after download
# Minimum 10 entries required
# Maximum 500K entries enforced
```

---

## Troubleshooting

### Issue: Feed update fails

**Symptoms**:
```
ERROR: Failed to download SPAMHAUS_DROP
```

**Possible causes**:
1. Network connectivity issue
2. Feed source is down
3. Timeout (slow connection)

**Solutions**:
```bash
# Check internet connectivity
ping -c 3 1.1.1.1

# Test feed URL manually
curl -I https://www.spamhaus.org/drop/drop.txt

# Increase timeout
echo 'FEEDS_DOWNLOAD_TIMEOUT="60"' >> /etc/nftban/nftban.conf.local

# Retry update
sudo nftban feeds update --force
```

### Issue: Go binary not found

**Symptoms**:
```
ERROR: nftban-feeds binary not found
```

**Solution**:
```bash
# Check if binary exists
ls -la /usr/lib/nftban/bin/nftban-feeds

# If missing, reinstall NFTBan
sudo ./install.sh

# Or rebuild Go binary
cd /path/to/nftban/src/usr/lib/nftban/bin/
sudo go build -o nftban-feeds nftban-feeds.go
```

### Issue: Feed update takes too long

**Symptoms**:
- Updates take >60 seconds
- High CPU usage during updates

**Possible causes**:
1. Go binary not being used (falling back to bash)
2. Very large feeds enabled
3. Slow disk I/O

**Solutions**:
```bash
# Verify Go binary is working
/usr/lib/nftban/bin/nftban-feeds --version

# Disable large feeds
sudo nftban feeds disable FIREHOL_LEVEL2

# Check disk I/O
iostat -x 1

# Use tmpfs for cache (faster, but volatile)
sudo mount -t tmpfs -o size=100M tmpfs /var/cache/nftban/feeds
```

### Issue: nftables set is full

**Symptoms**:
```
ERROR: Cannot add element to set: No space left on device
```

**Solution**:
```bash
# Check current set sizes
sudo nft list set inet nftban_v4 feeds | grep -i elements

# Reduce max entries
echo 'FEEDS_MAX_ENTRIES="200000"' >> /etc/nftban/nftban.conf.local

# Update feeds with new limit
sudo nftban feeds update
```

### Issue: False positives (legitimate IPs blocked)

**Symptoms**:
- Cannot access service from legitimate IP
- IP is in feed list

**Solution**:
```bash
# Check if IP is in feeds
nftban feeds check 203.0.113.100

# Whitelist the IP (highest priority, overrides feeds)
sudo nftban whitelist add 203.0.113.100

# Or disable problematic feed
sudo nftban feeds disable FIREHOL_LEVEL2
sudo nftban feeds update
```

### Issue: Memory usage too high

**Symptoms**:
- High memory usage on low-RAM systems
- OOM killer triggered

**Solution**:
```bash
# Check memory usage
free -h

# Reduce number of feeds
sudo nftban feeds disable FIREHOL_LEVEL2 STOPFORUMSPAM

# Limit max entries
echo 'FEEDS_MAX_ENTRIES="50000"' >> /etc/nftban/nftban.conf.local

# Update feeds
sudo nftban feeds update
```

### Issue: Feed downloads blocked by firewall

**Symptoms**:
```
ERROR: Connection timeout
```

**Solution**:
```bash
# Temporarily whitelist your IP for feed downloads
sudo nftban whitelist add $(curl -s ifconfig.me)

# Or disable outbound filtering temporarily
sudo nftables-apply-safe

# Update feeds
sudo nftban feeds update

# Re-enable firewall
sudo nftban-confirm
```

### Debug Mode

For detailed troubleshooting:

```bash
# Enable debug logging
echo 'FEEDS_LOG_LEVEL="DEBUG"' >> /etc/nftban/nftban.conf.local

# Run update with verbose output
sudo nftban feeds update --verbose

# Check detailed log
tail -100 /var/log/nftban/feeds.log
```

---

## Adding Custom Feeds

You can add your own threat feeds to NFTBan.

### Step 1: Edit Feeds Config

```bash
sudo nano /etc/nftban/conf.d/feeds.conf
```

### Step 2: Add Feed Definition

Add these 4 required variables:

```bash
# Custom feed example
FEED_MYCUSTOM_URL="https://example.com/blocklist.txt"
FEED_MYCUSTOM_ENABLED="false"
FEED_MYCUSTOM_CATEGORY="protection"
FEED_MYCUSTOM_DESCRIPTION="My custom blocklist"
FEED_MYCUSTOM_INTERVAL="DAILY"
FEED_MYCUSTOM_SIZE="~1,000 IPs"
```

### Step 3: Enable Your Feed

```bash
# NFTBan automatically discovers your feed!
nftban feeds list  # Should show MYCUSTOM

# Enable it
sudo nftban feeds enable MYCUSTOM

# Update
sudo nftban feeds update
```

**Feed format requirements**:
- One IP or CIDR per line
- IPv4 and IPv6 supported
- Comments (lines starting with #) ignored
- Empty lines ignored

---

## Summary

NFTBan's threat intelligence system provides:

- **14 pre-configured feeds** from reputable sources
- **4 categories**: protection, ssh, web, email
- **Go binary processing**: 10-60x faster than bash
- **Dynamic discovery**: No hardcoded arrays
- **Interactive selection**: Beautiful numbered menu
- **Automatic updates**: Via systemd timer
- **Atomic reloads**: No service disruption
- **Whitelist protection**: Cannot block whitelisted IPs

**Quick commands**:
```bash
# List feeds
nftban feeds list

# Interactive selection
sudo nftban feeds select

# Enable by category
sudo nftban feeds enable-category ssh

# Update feeds
sudo nftban feeds update

# Check status
sudo nftban feeds status
```

---

## Next Steps

- **[Ban System Guide](ban-system.md)** - Manual banning and whitelisting
- **[Security Profiles](security-profiles.md)** - Choose security profile
- **[Fail2Ban Integration](fail2ban.md)** - Automatic intrusion detection
- **[Health Diagnostics](health-diagnostics.md)** - Monitor system health

---

**Questions?** See the [troubleshooting section](#troubleshooting) or [full documentation](../index.md).
