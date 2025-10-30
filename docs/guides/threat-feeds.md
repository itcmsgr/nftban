# NFTBan Threat Intelligence Feeds - User Guide
**NFTBan v0.10.0**

## Table of Contents
- [Quick Start](#quick-start)
- [Overview](#overview)
- [Available Feeds](#available-feeds)
- [Categories](#categories)
- [Commands](#commands)
- [Usage Examples](#usage-examples)
- [Safety & Best Practices](#safety--best-practices)
- [Troubleshooting](#troubleshooting)
- [Technical Details](#technical-details)

---

## Quick Start

The easiest way to get started is with the interactive selection menu:

```bash
sudo nftban feeds select
```

This will show you all 14 available feeds organized by category. Just type:
- `1 3 6` to enable feeds 1, 3, and 6
- `ssh` to enable all SSH protection feeds
- `all` to enable all feeds
- `q` to quit

That's it! The feeds will be downloaded, parsed, and automatically added to your firewall.

---

## Overview

NFTBan includes 14 pre-configured threat intelligence feeds from trusted sources:

- **14 feeds** covering different threat types
- **4 categories**: protection, ssh, web, email
- **All disabled by default** for safety
- **Dynamic discovery** - easily add new feeds by config only
- **Fast parsing** with Go binary (10-60x faster than bash)
- **Automatic updates** - keep your protection current
- **Dedicated logging** at `/var/log/nftban/feeds.log`

### Why Use Threat Feeds?

Threat intelligence feeds provide real-time lists of malicious IP addresses that have been:
- Attacking other servers
- Sending spam
- Conducting brute force attacks
- Running botnet command & control servers
- Hosting malware

By blocking these IPs proactively, you protect your server before they even attempt an attack.

---

## Available Feeds

### Protection Category (6 feeds)

| Feed Name | Description | Size | Update |
|-----------|-------------|------|--------|
| **SPAMHAUS_DROP** | Known spam sources | ~1,000 IPs | Daily |
| **SPAMHAUS_EDROP** | Extended network blocks | ~500 IPs | Daily |
| **ABUSECH_FEODO** | Botnet C&C servers | ~5,000 IPs | Daily |
| **ABUSECH_SSL** | SSL/TLS abuse | ~3,000 IPs | Daily |
| **FIREHOL_LEVEL1** | High-confidence threats | ~30,000 IPs | Daily |
| **FIREHOL_LEVEL2** | Medium-confidence threats | ~50,000 IPs | Weekly |

### SSH Category (3 feeds)

| Feed Name | Description | Size | Update |
|-----------|-------------|------|--------|
| **BLOCKLISTDE_SSH** | SSH brute force | ~10,000 IPs | Daily |
| **GREENSNOW** | SSH/FTP attacks | ~8,000 IPs | Daily |
| **FIREHOL_SSH** | SSH password attacks | ~15,000 IPs | Daily |

### Web Category (3 feeds)

| Feed Name | Description | Size | Update |
|-----------|-------------|------|--------|
| **BLOCKLISTDE_APACHE** | Web server attacks | ~3,000 IPs | Daily |
| **BLOCKLISTDE_NGINX** | Nginx attacks | ~2,000 IPs | Daily |
| **FIREHOL_WEBCAM** | Webcam/IoT attacks | ~2,000 IPs | Weekly |

### Email Category (2 feeds)

| Feed Name | Description | Size | Update |
|-----------|-------------|------|--------|
| **BLOCKLISTDE_MAIL** | Mail server attacks | ~5,000 IPs | Daily |
| **STOPFORUMSPAM** | Forum spam | ~10,000 IPs | Weekly |

---

## Categories

Feeds are organized into logical categories:

### 🛡️ protection
General security and protection feeds covering various threat types:
- Spam sources
- Botnets
- Known malicious hosts
- General threats

**Recommended for**: All servers

### 🔐 ssh
SSH-specific attack protection:
- Brute force attempts
- Dictionary attacks
- SSH scanner bots

**Recommended for**: Servers with SSH exposed to the internet

### 🌐 web
Web server attack protection:
- Web application attacks
- HTTP/HTTPS scanners
- Exploit attempts

**Recommended for**: Web servers, hosting providers

### 📧 email
Email and spam protection:
- Mail server attacks
- Spam sources
- Forum spam

**Recommended for**: Mail servers, forums, comment systems

---

## Commands

### List Feeds

```bash
nftban feeds list
```

Shows all available feeds with their current status, organized by category.

### Interactive Selection

```bash
sudo nftban feeds select
```

Opens an interactive numbered menu for easy feed selection. **Recommended!**

### Enable Specific Feed

```bash
sudo nftban feeds enable SPAMHAUS_DROP
```

Enables a specific feed by name. The feed will be:
1. Enabled in config
2. Downloaded from source
3. Parsed with Go binary
4. Synced to nftables

### Disable Feed

```bash
sudo nftban feeds disable SPAMHAUS_DROP
```

Disables a feed and removes its IPs from the firewall.

### Enable Category

```bash
sudo nftban feeds enable-category ssh
```

Enables all feeds in a category. Available categories:
- `protection`
- `ssh`
- `web`
- `email`

### Update Feeds

```bash
# Update all enabled feeds
sudo nftban feeds update

# Update specific feed
sudo nftban feeds update SPAMHAUS_DROP
```

Downloads the latest feed data and updates your firewall rules.

### Check Status

```bash
nftban feeds status
```

Shows detailed status including:
- Number of enabled feeds
- Total IPs blocked
- Last update time for each feed
- Log file location

### Help

```bash
nftban feeds help
```

Shows complete help with all commands and examples.

---

## Usage Examples

### Example 1: Quick Start for SSH Server

Protect your SSH server with 3 feeds:

```bash
sudo nftban feeds select
# Type: ssh
# This enables all 3 SSH protection feeds
```

Or enable individually:
```bash
sudo nftban feeds enable BLOCKLISTDE_SSH
sudo nftban feeds enable GREENSNOW
sudo nftban feeds enable FIREHOL_SSH
```

### Example 2: Web Server Protection

Enable basic protection for a web server:

```bash
sudo nftban feeds select
# Type: 1,protection
# This enables feed 1 and all protection feeds
```

### Example 3: Comprehensive Protection

Enable multiple categories:

```bash
sudo nftban feeds enable-category protection
sudo nftban feeds enable-category ssh
sudo nftban feeds enable-category web
```

### Example 4: Selective Protection

Enable only high-confidence feeds:

```bash
sudo nftban feeds select
# Type: 1 2 7 8
# Enables: SPAMHAUS_DROP, SPAMHAUS_EDROP, BLOCKLISTDE_SSH, GREENSNOW
```

### Example 5: Check Your Current Protection

```bash
# Quick summary
nftban feeds list

# Detailed status
nftban feeds status

# View recent feed updates
tail -f /var/log/nftban/feeds.log
```

---

## Safety & Best Practices

### All Feeds Disabled by Default

For safety, **ALL feeds are disabled by default**. You must explicitly enable them.

This prevents:
- Accidentally blocking legitimate traffic
- Service disruptions
- Lockouts from important services

### Start Small, Scale Up

**Best Practice**: Start with 1-2 feeds and monitor for false positives before enabling more.

Recommended starting feeds:
1. `SPAMHAUS_DROP` - Very high confidence, low false positive rate
2. `BLOCKLISTDE_SSH` - If you run an SSH server

### Monitor Your Logs

After enabling feeds, monitor your logs for:

```bash
# Watch feed updates
tail -f /var/log/nftban/feeds.log

# Check for blocked connections
journalctl -u nftables -f
```

### Whitelist Important IPs First

Before enabling feeds, whitelist:
- Your office/home IP
- Monitoring services
- CDN providers (if using Cloudflare/Cloudfront)
- API partners

```bash
nftban whitelist-system add <your-ip>
```

### Regular Updates

Enable automatic updates in `/etc/nftban/conf.d/feeds.conf`:

```bash
FEEDS_AUTO_UPDATE="true"
FEEDS_UPDATE_INTERVAL="86400"  # 24 hours
```

Or manually update daily:
```bash
sudo nftban feeds update
```

### Test Before Production

Always test feed blocking on a **non-production server** first:
1. Enable feeds on test server
2. Monitor for 24-48 hours
3. Check logs for false positives
4. If all good, enable on production

---

## Troubleshooting

### Feeds Not Downloading

**Problem**: Feed enable command succeeds but no IPs downloaded

**Check**:
```bash
# Check feed log
tail -50 /var/log/nftban/feeds.log

# Manually test download
curl -sSL https://www.spamhaus.org/drop/drop.txt
```

**Solutions**:
- Check internet connectivity
- Verify feed URL is accessible
- Check firewall allows outbound HTTPS

### Feed Parsing Errors

**Problem**: Feed downloads but parsing fails

**Check**:
```bash
# Check Go binary
/usr/lib/nftban/bin/nftban-feeds --version

# Test parsing
echo "8.8.8.8" | /usr/lib/nftban/bin/nftban-feeds parse
```

**Solutions**:
- Verify Go binary is installed and executable
- Check feed format matches parser expectations

### Feed Not Blocking Traffic

**Problem**: Feed enabled but IPs not being blocked

**Check**:
```bash
# Verify feed file exists
ls -lh /var/lib/nftban/feeds/

# Check nftables sets
nft list set ip nftban_v4 feeds
nft list set ip6 nftban_v6 feeds

# Verify feed IPs in set
nft list set ip nftban_v4 feeds | head -50
```

**Solutions**:
- Ensure nftables is running: `systemctl status nftables`
- Verify feed sync completed: `tail -50 /var/log/nftban/feeds.log`
- Check nftban_v4/v6 tables exist

### High Memory Usage

**Problem**: Large feeds consuming too much memory

**Solution**: Use smaller feeds or enable only what you need
```bash
# Disable large feeds
sudo nftban feeds disable FIREHOL_LEVEL2

# Use targeted feeds instead
sudo nftban feeds enable BLOCKLISTDE_SSH
```

### False Positives

**Problem**: Legitimate service being blocked

**Check**:
```bash
# Find which feed contains the IP
grep "1.2.3.4" /var/lib/nftban/feeds/*.txt

# Check feed reputation
nftban feeds list
```

**Solutions**:
1. Whitelist the specific IP:
   ```bash
   nftban whitelist-system add 1.2.3.4
   ```

2. Disable the problematic feed:
   ```bash
   sudo nftban feeds disable <feed_name>
   ```

3. Report false positive to feed provider

---

## Technical Details

### Architecture

The feeds system uses a hybrid **Go + Bash** architecture:

- **Bash**: Orchestration, downloading, configuration
- **Go**: Fast parsing, validation, deduplication

This provides:
- 10-60x faster parsing than pure bash
- Easy configuration and extensibility
- Robust error handling

### Dynamic Discovery

Unlike v0.9.5, v0.10.0 uses **dynamic feed discovery**:

```bash
# NO hardcoded arrays!
# Feeds auto-discovered from config file
grep -oP 'FEED_\K[A-Z0-9_]+(?=_URL=)' /etc/nftban/conf.d/feeds.conf
```

Adding a new feed is simple:
1. Add `FEED_NEWFEED_*` variables to config
2. No code changes needed!

### File Locations

```
/etc/nftban/conf.d/feeds.conf          - Feed configuration
/usr/lib/nftban/core/nftban_feeds.sh   - Core functions
/usr/lib/nftban/cli/cmd_feeds.sh       - CLI commands
/usr/lib/nftban/bin/nftban-feeds       - Go binary
/var/lib/nftban/feeds/                 - Downloaded feeds
/var/log/nftban/feeds.log              - Feed logs
/var/cache/nftban/feeds/               - Temporary cache
```

### Performance

**Parsing Speed** (Go binary):
- 1,000 IPs: ~50ms
- 10,000 IPs: ~200ms
- 50,000 IPs: ~1-2 seconds

**Download Time**:
- Small feeds (1-5K IPs): 1-2 seconds
- Large feeds (50K IPs): 3-5 seconds

### nftables Integration

Feeds are stored in nftables sets:

```bash
# View feed IPs
nft list set ip nftban_v4 feeds
nft list set ip6 nftban_v6 feeds

# Check rule
nft list ruleset | grep -A 5 feeds
```

### Adding Custom Feeds

To add your own threat feed:

1. Edit `/etc/nftban/conf.d/feeds.conf`
2. Add feed definition:
   ```bash
   FEED_MYFEED_URL="https://example.com/feed.txt"
   FEED_MYFEED_ENABLED="false"
   FEED_MYFEED_CATEGORY="protection"
   FEED_MYFEED_DESCRIPTION="My custom feed"
   FEED_MYFEED_INTERVAL="DAILY"
   FEED_MYFEED_SIZE="~1,000 IPs"
   ```
3. Enable it:
   ```bash
   sudo nftban feeds enable MYFEED
   ```

The feed will be automatically discovered and integrated!

---

## Support & Resources

### Log Files
```bash
# Feed operations
/var/log/nftban/feeds.log

# General nftban logs
/var/log/nftban/nftban.log

# nftables logs
journalctl -u nftables
```

### Verification
```bash
# Check feed status
nftban feeds status

# Verify downloads
ls -lh /var/lib/nftban/feeds/

# Test Go binary
/usr/lib/nftban/bin/nftban-feeds --version
```

### Getting Help
```bash
# Command help
nftban feeds help

# General help
nftban help

# Module help
nftban module list
```

---

## Quick Reference

```bash
# 🚀 QUICK START
sudo nftban feeds select              # Interactive menu (recommended!)

# 📋 INFORMATION
nftban feeds list                     # List all feeds
nftban feeds status                   # Detailed status
nftban feeds help                     # Command help

# ✅ ENABLE FEEDS
sudo nftban feeds enable <feed>       # Enable specific feed
sudo nftban feeds enable-cat ssh      # Enable category

# ❌ DISABLE FEEDS
sudo nftban feeds disable <feed>      # Disable specific feed

# 🔄 UPDATE
sudo nftban feeds update              # Update all enabled
sudo nftban feeds update <feed>       # Update specific

# 📝 LOGS
tail -f /var/log/nftban/feeds.log     # Watch feed operations
nftban feeds status                   # Check last update times
```

---

**NFTBan v0.10.0** — Simplifying Linux Firewall Management

For more information, visit: https://nftban.com
