# NFTBan IP/Port Management - Complete Guide

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    NFTBan IP/Port Management                     │
└─────────────────────────────────────────────────────────────────┘

INPUT METHODS:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

┌──────────────────────┐  ┌──────────────────────┐  ┌──────────────┐
│ Manual .conf Files   │  │  fail2ban Dynamic    │  │  GeoIP Feeds │
│  (NO GO NEEDED)      │  │  (NO GO NEEDED)      │  │ (GO OPTIONAL)│
├──────────────────────┤  ├──────────────────────┤  ├──────────────┤
│ whitelist.d/*.conf   │  │ fail2ban adds/removes│  │ feeds.d/*.conf│
│ blacklist.d/*.conf   │  │ IPs to runtime table │  │ Downloads from│
│ ports.d/*.conf       │  │ via nftables sets    │  │ internet URLs │
└──────┬───────────────┘  └──────┬───────────────┘  └──────┬───────┘
       │                         │                         │
       │                         │                         │
       └─────────────────────────┼─────────────────────────┘
                                 │
                                 ▼
                    ┌────────────────────────┐
                    │  nftban firewall reload│
                    │  (Bash script)         │
                    └────────┬───────────────┘
                             │
                             │ Reads all .conf files
                             │ Generates nftables rules
                             ▼
                    ┌────────────────────────┐
                    │  nftban-complete       │
                    │  (Bash template engine)│
                    └────────┬───────────────┘
                             │
                             │ Creates .nft file
                             ▼
                    ┌────────────────────────┐
                    │  nft -f file.nft       │
                    │  (Apply to firewall)   │
                    └────────────────────────┘
```

---

## Method 1: Manual .conf Files (NO GO REQUIRED)

### Whitelist Example

```bash
# /etc/nftban/whitelist.d/trusted-servers.conf
# Simple text file - one IP per line

# Office IPs
192.168.1.100
192.168.1.101

# Production servers  
95.216.159.238
2a01:4f9:c010:b0b5::1

# Comments are allowed (lines starting with #)
```

### Blacklist Example

```bash
# /etc/nftban/blacklist.d/known-attackers.conf

# Known brute force attackers
45.135.232.92          # Caught by fail2ban on 2025-10-30
91.215.85.45           # SSH brute force

# Bad actor networks
203.0.113.0/24         # CIDR ranges supported
```

### Ports Example

```bash
# /etc/nftban/ports.d/webserver.conf
# Format: protocol:port

tcp:80                 # HTTP
tcp:443                # HTTPS
tcp:22                 # SSH
tcp:3306               # MySQL (only from whitelist)
udp:53                 # DNS
```

### How to Use

```bash
# 1. Edit any .conf file
nano /etc/nftban/whitelist.d/my-ips.conf

# 2. Reload firewall (reads ALL .conf files)
nftban firewall reload

# 3. Verify
nftban firewall status
```

**NO GO NEEDED FOR THIS!**

---

## Method 2: fail2ban Dynamic Bans (NO GO REQUIRED)

fail2ban **automatically** adds/removes IPs from NFTBan:

```
Attack detected → fail2ban → nftables set → NFTBan runtime table
    ↓
SSH brute force on port 22
    ↓
fail2ban detects 5 failed attempts in 10 minutes
    ↓
fail2ban runs: nft add element inet nftban_runtime temp_ban_v4 { 45.135.232.92 }
    ↓
IP banned for 1 hour (configurable)
    ↓
After 1 hour: nft delete element inet nftban_runtime temp_ban_v4 { 45.135.232.92 }
```

**Configuration:**

```bash
# /etc/fail2ban/jail.local
[sshd]
enabled = true
port = 22
filter = sshd
logpath = /var/log/secure          # RHEL
# logpath = /var/log/auth.log      # Debian/Ubuntu
backend = systemd
maxretry = 5                        # 5 failed attempts
bantime = 3600                      # Ban for 1 hour
findtime = 600                      # Within 10 minutes
banaction = nftables-multiport      # Uses nftables!
```

**Check bans:**

```bash
fail2ban-client status sshd
```

**NO GO NEEDED FOR THIS!**

---

## Method 3: GeoIP Feeds (GO OPTIONAL)

Download blocklists from the internet:

### Feed Configuration

```bash
# /etc/nftban/feeds.d/block-iran.conf
feed_name="block-iran"
feed_url="https://www.ipdeny.com/ipblocks/data/countries/ir.zone"
feed_type="geoip-country"
feed_format="zone"
enabled="yes"
update_interval="24h"
```

### How Feeds Work

```
┌─────────────────────────────────────────────────────────┐
│                    Feed Update Process                   │
└─────────────────────────────────────────────────────────┘

1. Cron job runs daily (or on demand):
   └─→ nftban feeds update

2. NFTBan checks if GO is installed:
   ├─→ GO FOUND:
   │   └─→ Use /usr/lib/nftban/modules/feed_processor (compiled GO binary)
   │       ├─→ Supports: JSON, CSV, zone files, GeoIP databases
   │       ├─→ Parallel downloads
   │       ├─→ Validates IP ranges
   │       └─→ Better error handling
   │
   └─→ NO GO:
       └─→ Use /usr/lib/nftban/modules/feed_processor_basic.sh (Bash + curl)
           ├─→ Simple line-by-line parsing only
           ├─→ No complex format support
           └─→ Works for basic IP lists

3. Downloaded IPs saved to:
   └─→ /var/lib/nftban/feeds/block-iran.txt

4. Next firewall reload reads feed files:
   └─→ nftban firewall reload
       └─→ Adds IPs to blacklist_v4/blacklist_v6 sets
```

---

## GO Detection and Auto-Loading

### Detection Script (Built into NFTBan)

```bash
#!/bin/bash
# Part of: /usr/lib/nftban/modules/feed_manager.sh

detect_feed_processor() {
    local processor=""
    
    # Step 1: Check if GO is installed
    if command -v go &>/dev/null; then
        echo "✓ GO detected: $(go version)"
        
        # Step 2: Check if GO feed processor is compiled
        if [[ -x "/usr/lib/nftban/modules/feed_processor" ]]; then
            processor="go"
            echo "✓ Using advanced GO feed processor"
        else
            echo "⚠ GO found but processor not compiled"
            echo "  Falling back to basic bash processor"
            processor="bash"
        fi
    else
        echo "ℹ GO not installed, using basic bash processor"
        processor="bash"
    fi
    
    echo "$processor"
}

# Auto-select processor
PROCESSOR=$(detect_feed_processor)

case "$PROCESSOR" in
    go)
        /usr/lib/nftban/modules/feed_processor --download "$feed_url" --output "$output_file"
        ;;
    bash)
        /usr/lib/nftban/modules/feed_processor_basic.sh "$feed_url" "$output_file"
        ;;
esac
```

### When GO Gets Installed Later

NFTBan automatically detects GO on next run:

```bash
# Before: GO not installed
$ nftban feeds update
ℹ GO not installed, using basic bash processor
✓ Downloaded block-iran feed (basic mode)

# After: GO installed
$ dnf install -y golang
$ nftban feeds update
✓ GO detected: go version go1.25.1
✓ Using advanced GO feed processor
✓ Downloaded block-iran feed (advanced mode with validation)
```

**NO manual configuration needed!** NFTBan auto-detects.

---

## Complete Feature Matrix

| Feature | Without GO | With GO | Notes |
|---------|-----------|---------|-------|
| **Whitelist Management** | ✅ Full | ✅ Full | Edit .conf files manually |
| **Blacklist Management** | ✅ Full | ✅ Full | Edit .conf files manually |
| **Port Management** | ✅ Full | ✅ Full | Edit .conf files manually |
| **Auto-whitelist (SSH)** | ✅ Full | ✅ Full | Built-in lockout prevention |
| **fail2ban Integration** | ✅ Full | ✅ Full | Dynamic temporary bans |
| **Simple IP List Feeds** | ⚠️ Basic | ✅ Advanced | curl + awk vs GO parser |
| **GeoIP Country Blocking** | ❌ No | ✅ Yes | Download country IP ranges |
| **CSV/JSON Feed Parsing** | ❌ No | ✅ Yes | Complex format support |
| **Feed Validation** | ⚠️ Basic | ✅ Advanced | IP range validation |
| **Parallel Downloads** | ❌ No | ✅ Yes | Faster updates |

---

## Practical Examples

### Example 1: Block a Single IP (NO GO)

```bash
echo "203.0.113.50" >> /etc/nftban/blacklist.d/manual-blocks.conf
nftban firewall reload
```

### Example 2: Whitelist Your Office (NO GO)

```bash
cat > /etc/nftban/whitelist.d/office.conf << 'EOF'
# Office network
192.168.1.0/24
203.0.113.100
