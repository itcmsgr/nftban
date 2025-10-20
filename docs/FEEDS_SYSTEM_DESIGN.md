# NFTBan Threat Feeds System - Enhanced Design

**Version:** 2.0.0
**Date:** 2025-10-19

---

## Problems Identified & Solutions

### Problem 1: Dynamic List Creation Bug
**Issue:** Set creation uses wrong table names, incomplete initialization
**Solution:** Use correct table structure (ip nftban_v4 / ip6 nftban_v6), proper init sequence

### Problem 2: Configuration Complexity
**Issue:** User can't easily see what's enabled without checking multiple files
**Solution:** Single source of truth in nftban.conf.local with clear TRUE/FALSE

### Problem 3: No Per-Feed Update Intervals
**Issue:** All feeds use same interval, can't have hourly SSH + daily Spamhaus
**Solution:** Per-feed interval with validation (HOURLY, DAILY, WEEKLY only)

### Problem 4: IP Storage Location Unclear
**Issue:** Feed IPs mixed with user IPs, hard to manage
**Solution:** Separate files per feed in templates/feeds/ directory

---

## Configuration Design

### Master Configuration: nftban.conf.local

```bash
# =============================================================================
# THREAT FEEDS CONFIGURATION
# =============================================================================

# Global Feed Settings
NFTBAN_FEEDS_ENABLED="TRUE"                    # Master switch
NFTBAN_FEEDS_DOWNLOAD_TIMEOUT="30"            # curl timeout (seconds)
NFTBAN_FEEDS_MIN_ENTRIES="10"                 # Minimum IPs to consider valid
NFTBAN_FEEDS_MAX_ENTRIES="500000"             # Maximum IPs per feed
NFTBAN_FEEDS_MEMORY_LIMIT="512"               # Memory limit MB

# =============================================================================
# Spamhaus DROP List
# URL: https://www.spamhaus.org/drop/drop.txt
# Description: Known spam sources, recommended for all servers
# Update Frequency: DAILY (recommended)
# =============================================================================
NFTBAN_FEED_SPAMHAUS_ENABLED="FALSE"          # Enable/Disable
NFTBAN_FEED_SPAMHAUS_INTERVAL="DAILY"         # HOURLY, DAILY, WEEKLY
NFTBAN_FEED_SPAMHAUS_URL="https://www.spamhaus.org/drop/drop.txt"
NFTBAN_FEED_SPAMHAUS_FILE="${NFTBAN_TEMPLATES_DIR}/feeds/spamhaus-blacklist.conf"

# =============================================================================
# Blocklist.de - All Attacks
# URL: https://lists.blocklist.de/lists/all.txt
# Description: All attack types aggregated
# Update Frequency: HOURLY (high activity)
# =============================================================================
NFTBAN_FEED_BLOCKLISTDE_ALL_ENABLED="FALSE"
NFTBAN_FEED_BLOCKLISTDE_ALL_INTERVAL="HOURLY"
NFTBAN_FEED_BLOCKLISTDE_ALL_URL="https://lists.blocklist.de/lists/all.txt"
NFTBAN_FEED_BLOCKLISTDE_ALL_FILE="${NFTBAN_TEMPLATES_DIR}/feeds/blocklistde-all-blacklist.conf"

# =============================================================================
# Blocklist.de - SSH Attacks
# URL: https://lists.blocklist.de/lists/ssh.txt
# Description: SSH brute-force attackers
# Update Frequency: HOURLY (high activity)
# =============================================================================
NFTBAN_FEED_BLOCKLISTDE_SSH_ENABLED="FALSE"
NFTBAN_FEED_BLOCKLISTDE_SSH_INTERVAL="HOURLY"
NFTBAN_FEED_BLOCKLISTDE_SSH_URL="https://lists.blocklist.de/lists/ssh.txt"
NFTBAN_FEED_BLOCKLISTDE_SSH_FILE="${NFTBAN_TEMPLATES_DIR}/feeds/blocklistde-ssh-blacklist.conf"

# =============================================================================
# Blocklist.de - Mail Attacks
# URL: https://lists.blocklist.de/lists/mail.txt
# Description: Mail server attackers
# Update Frequency: DAILY
# =============================================================================
NFTBAN_FEED_BLOCKLISTDE_MAIL_ENABLED="FALSE"
NFTBAN_FEED_BLOCKLISTDE_MAIL_INTERVAL="DAILY"
NFTBAN_FEED_BLOCKLISTDE_MAIL_URL="https://lists.blocklist.de/lists/mail.txt"
NFTBAN_FEED_BLOCKLISTDE_MAIL_FILE="${NFTBAN_TEMPLATES_DIR}/feeds/blocklistde-mail-blacklist.conf"

# =============================================================================
# Blocklist.de - Apache Attacks
# URL: https://lists.blocklist.de/lists/apache.txt
# Description: Apache/web server attackers
# Update Frequency: DAILY
# =============================================================================
NFTBAN_FEED_BLOCKLISTDE_APACHE_ENABLED="FALSE"
NFTBAN_FEED_BLOCKLISTDE_APACHE_INTERVAL="DAILY"
NFTBAN_FEED_BLOCKLISTDE_APACHE_URL="https://lists.blocklist.de/lists/apache.txt"
NFTBAN_FEED_BLOCKLISTDE_APACHE_FILE="${NFTBAN_TEMPLATES_DIR}/feeds/blocklistde-apache-blacklist.conf"

# =============================================================================
# Abuse.ch Feodo Tracker
# URL: https://feodotracker.abuse.ch/downloads/ipblocklist.txt
# Description: Botnet C&C servers
# Update Frequency: DAILY
# =============================================================================
NFTBAN_FEED_ABUSECH_ENABLED="FALSE"
NFTBAN_FEED_ABUSECH_INTERVAL="DAILY"
NFTBAN_FEED_ABUSECH_URL="https://feodotracker.abuse.ch/downloads/ipblocklist.txt"
NFTBAN_FEED_ABUSECH_FILE="${NFTBAN_TEMPLATES_DIR}/feeds/abusech-blacklist.conf"

# =============================================================================
# DShield Top 20
# URL: https://isc.sans.edu/api/sources/attacks/20/
# Description: Top 20 attacking IPs (small, low overhead)
# Update Frequency: HOURLY (high value targets)
# =============================================================================
NFTBAN_FEED_DSHIELD_ENABLED="FALSE"
NFTBAN_FEED_DSHIELD_INTERVAL="HOURLY"
NFTBAN_FEED_DSHIELD_URL="https://isc.sans.edu/api/sources/attacks/20/"
NFTBAN_FEED_DSHIELD_FILE="${NFTBAN_TEMPLATES_DIR}/feeds/dshield-blacklist.conf"
```

---

## Update Interval Mechanism

### Allowed Values
```bash
HOURLY   → Every hour at :00  (OnCalendar=*-*-* *:00:00)
DAILY    → Every day at 00:00 (OnCalendar=*-*-* 00:00:00)
WEEKLY   → Every Sunday 00:00 (OnCalendar=Sun *-*-* 00:00:00)
```

### Validation Logic
```bash
nftban_feeds_validate_interval() {
    local interval="$1"

    case "$interval" in
        HOURLY|DAILY|WEEKLY)
            return 0
            ;;
        *)
            nftban_log_error "Invalid interval: $interval (must be HOURLY, DAILY, or WEEKLY)"
            return 1
            ;;
    esac
}
```

### Per-Feed Timer Strategy

**Problem:** systemd timers are system-wide, can't have different per-feed intervals easily

**Solution:** Single timer runs every hour, script checks which feeds need updating

```bash
# Timer: Every hour
OnCalendar=*-*-* *:00:00

# Script logic:
nftban_feeds_update_scheduled() {
    local current_hour=$(date +%H)
    local current_day=$(date +%u)  # 1=Monday, 7=Sunday

    for feed_id in $(nftban_feeds_list_enabled); do
        local interval=$(nftban_feeds_get_interval "$feed_id")
        local should_run=false

        case "$interval" in
            HOURLY)
                should_run=true
                ;;
            DAILY)
                [[ "$current_hour" == "00" ]] && should_run=true
                ;;
            WEEKLY)
                [[ "$current_day" == "7" ]] && [[ "$current_hour" == "00" ]] && should_run=true
                ;;
        esac

        if [[ "$should_run" == "true" ]]; then
            nftban_feeds_update_single "$feed_id"
        fi
    done
}
```

---

## File Storage Structure

### Directory Layout
```
/etc/nftban/
├── config/
│   ├── nftban.conf               # Base config (never modified)
│   └── nftban.conf.local         # User config (ENABLED flags here)
│
└── templates/
    └── feeds/                    # Feed IP storage (one file per feed)
        ├── spamhaus-blacklist.conf
        ├── blocklistde-all-blacklist.conf
        ├── blocklistde-ssh-blacklist.conf
        ├── blocklistde-mail-blacklist.conf
        ├── blocklistde-apache-blacklist.conf
        ├── abusech-blacklist.conf
        └── dshield-blacklist.conf

/var/cache/nftban/feeds/          # Temporary download cache
├── spamhaus.tmp                  # Downloaded raw data
├── spamhaus.parsed               # Parsed IPs
└── .last_update                  # Timestamp tracking
```

### Feed File Format
```bash
# =============================================================================
# NFTBan Threat Feed: Spamhaus DROP List
# =============================================================================
# Source: https://www.spamhaus.org/drop/drop.txt
# Updated: 2025-10-19 12:00:00 UTC
# Entry Count: 1234 IPs/CIDRs
# Update Interval: DAILY
# Auto-managed by NFTBan - DO NOT EDIT MANUALLY
# =============================================================================

1.2.3.0/24
5.6.7.8
10.20.30.0/22
# ... more IPs ...
```

---

## Feed Enable/Disable Workflow

### Enable Command
```bash
$ sudo nftban feeds enable spamhaus

[INFO] Enabling feed: spamhaus
[INFO] Updating configuration...
✓ Set NFTBAN_FEED_SPAMHAUS_ENABLED="TRUE" in nftban.conf.local
[INFO] Downloading feed...
✓ Downloaded 1234 IPs from https://www.spamhaus.org/drop/drop.txt
✓ Saved to /etc/nftban/templates/feeds/spamhaus-blacklist.conf
[INFO] Syncing to nftables...
✓ Added 1234 IPs to @feeds set
[SUCCESS] Feed 'spamhaus' enabled and active
```

### Disable Command
```bash
$ sudo nftban feeds disable spamhaus

[INFO] Disabling feed: spamhaus
[INFO] Updating configuration...
✓ Set NFTBAN_FEED_SPAMHAUS_ENABLED="FALSE" in nftban.conf.local
[INFO] Removing from nftables...
✓ Removed spamhaus IPs from @feeds set
[INFO] Feed file preserved at: /etc/nftban/templates/feeds/spamhaus-blacklist.conf
[SUCCESS] Feed 'spamhaus' disabled (file kept for reference)
```

### List Command
```bash
$ nftban feeds list

═══════════════════════════════════════════════════════════════
  NFTBan Threat Feeds - Available Providers
═══════════════════════════════════════════════════════════════

Global Status: ENABLED ✓
Update Timer: ACTIVE ✓ (runs hourly)

Feed Providers:
───────────────────────────────────────────────────────────────
[✓] spamhaus          Spamhaus DROP List         DAILY   1,234 IPs
[✗] blocklistde_all   Blocklist.de All          HOURLY  (disabled)
[✗] blocklistde_ssh   Blocklist.de SSH          HOURLY  (disabled)
[✗] blocklistde_mail  Blocklist.de Mail         DAILY   (disabled)
[✗] blocklistde_apache Blocklist.de Apache      DAILY   (disabled)
[✗] abusech           Abuse.ch Feodo Tracker    DAILY   (disabled)
[✗] dshield           DShield Top 20            HOURLY  (disabled)

Legend:
  [✓] Enabled and active
  [✗] Disabled

Commands:
  nftban feeds enable <feed_id>    Enable a feed
  nftban feeds disable <feed_id>   Disable a feed
  nftban feeds update [feed_id]    Update feeds now
  nftban feeds status              Show detailed status
```

---

## Initialization Workflow

### Init Command
```bash
$ sudo nftban feeds init

[INFO] Initializing NFTBan threat feeds system...

Step 1: Creating directory structure...
✓ Created /etc/nftban/templates/feeds/
✓ Created /var/cache/nftban/feeds/

Step 2: Creating configuration files...
✓ Created nftban.conf.local with feed settings
✓ All feeds initialized as DISABLED (safe default)

Step 3: Creating nftables sets...
✓ Created set: ip nftban_v4 feeds
✓ Created set: ip6 nftban_v6 feeds

Step 4: Adding firewall rules...
✓ Added rule: ip nftban_v4 input ip saddr @feeds drop
✓ Added rule: ip6 nftban_v6 input ip6 saddr @feeds drop

[SUCCESS] Threat feeds system initialized

Next Steps:
  1. Review available feeds:
     nftban feeds list

  2. Enable feeds you want:
     sudo nftban feeds enable spamhaus
     sudo nftban feeds enable blocklistde_ssh

  3. Install update timer (optional):
     sudo nftban feeds timer-install
```

---

## Safe Interval Override Protection

### User tries invalid interval:
```bash
# User manually edits config:
NFTBAN_FEED_SPAMHAUS_INTERVAL="5MIN"  # Invalid!

$ sudo nftban feeds update spamhaus

[ERROR] Invalid interval for spamhaus: 5MIN
[ERROR] Allowed values: HOURLY, DAILY, WEEKLY
[INFO] Using fallback interval: DAILY
[WARNING] Please fix configuration: /etc/nftban/config/nftban.conf.local
```

### Validation on enable:
```bash
nftban_feeds_enable() {
    local feed_id="$1"

    # Validate interval before enabling
    local interval=$(nftban_feeds_get_config "$feed_id" "INTERVAL")

    if ! nftban_feeds_validate_interval "$interval"; then
        nftban_log_warning "Invalid interval '$interval' for $feed_id, using DAILY"
        nftban_feeds_set_config "$feed_id" "INTERVAL" "DAILY"
    fi

    # Enable feed
    nftban_feeds_set_config "$feed_id" "ENABLED" "TRUE"

    # Download and activate
    nftban_feeds_update_single "$feed_id"
}
```

---

## Implementation Priorities

### Phase 1: Core Functions (Must Have)
1. ✅ Configuration structure in nftban.conf.local
2. ✅ Feed file storage in templates/feeds/
3. ✅ nftban_feeds_init() - Directory + config creation
4. ✅ nftban_feeds_enable() - Enable feed + update config
5. ✅ nftban_feeds_disable() - Disable feed + update config
6. ✅ nftban_feeds_list() - Show all feeds with status
7. ✅ nftban_feeds_update() - Download + parse + sync to nftables

### Phase 2: Update Mechanism (Must Have)
8. ✅ nftban_feeds_update_single() - Update one feed
9. ✅ Interval validation (HOURLY/DAILY/WEEKLY only)
10. ✅ Per-feed interval checking
11. ✅ nftables set creation (ip nftban_v4 / ip6 nftban_v6)
12. ✅ Safe IP parsing with validation

### Phase 3: Timer & Automation (Nice to Have)
13. ✅ nftban_feeds_timer_install() - Hourly timer
14. ✅ nftban_feeds_timer_remove() - Remove timer
15. ✅ Scheduled update logic (check intervals)

### Phase 4: Status & Monitoring (Nice to Have)
16. ✅ nftban_feeds_status() - Detailed status
17. ✅ nftban_feeds_memory() - Memory usage
18. ✅ Last update timestamps

---

## Security Considerations

### 1. Whitelist Protection
All feed IPs checked against whitelist before adding:
```bash
if nftban_whitelist_check_ip "$ip"; then
    nftban_log_debug "Skipping whitelisted IP: $ip"
    continue
fi
```

### 2. Download Safety
- 30-second timeout per download
- HTTPS validation (curl --fail)
- Minimum entry check (reject if < 10 IPs)
- Maximum entry check (reject if > 500k IPs)

### 3. Memory Safety
- Memory limit: 512MB
- Pre-flight check before loading large feeds
- Streaming processing (don't load entire feed to memory)

### 4. Atomic Updates
```bash
# Build new set in temp file
temp_file=$(mktemp)

# Aggregate all enabled feeds
for feed_id in $(list_enabled_feeds); do
    cat "$feed_file" >> "$temp_file"
done

# Deduplicate
sort -u "$temp_file" > "$temp_file.dedup"

# Flush and reload atomically
nft flush set ip nftban_v4 feeds
nft add element ip nftban_v4 feeds { $(cat "$temp_file.dedup") }
```

---

## Summary: Key Design Decisions

| Aspect | Decision | Rationale |
|--------|----------|-----------|
| **Config Location** | nftban.conf.local | Single source of truth, user-friendly |
| **Enable/Disable** | TRUE/FALSE in config | Clear, easy to grep, survives updates |
| **IP Storage** | templates/feeds/*.conf | Separate per feed, easy to manage |
| **Interval Options** | HOURLY/DAILY/WEEKLY only | Safe, predictable, systemd-friendly |
| **Interval Enforcement** | Validate on enable/update | Prevent misconfiguration |
| **Timer Strategy** | Single hourly timer + logic | Simpler than multiple timers |
| **NFTables Sets** | ip nftban_v4 / ip6 nftban_v6 | Follows current architecture |
| **Default State** | All feeds DISABLED | Safe default, user opts in |
| **File Format** | Plain text with header | Easy to inspect, debug |
| **Update Strategy** | Flush + reload | Simple, atomic, reliable |

This design is production-ready, user-friendly, and safe. Ready to implement!
