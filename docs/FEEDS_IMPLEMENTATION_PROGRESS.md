# NFTBan Feeds System - Implementation Progress

**Date:** 2025-10-19
**Status:** Configuration Complete, Module Implementation Pending

---

## ✅ COMPLETED

### 1. Configuration Design (100% Complete)
**File:** `/home/gituser/github/nftban/templates/conf/nftban.conf`

**9 Feed Providers Configured:**
1. ✅ Spamhaus DROP (~1,000 IPs) - Industry standard
2. ✅ Blocklist.de All Attacks (~50,000 IPs) - Aggregated
3. ✅ Blocklist.de SSH (~15,000 IPs) - SSH brute-force
4. ✅ Blocklist.de Mail (~10,000 IPs) - Mail attacks
5. ✅ Blocklist.de Apache (~8,000 IPs) - Web attacks
6. ✅ Abuse.ch Feodo Tracker (~500 IPs) - Botnet C&C
7. ✅ DShield Top 20 (20 IPs) - Most aggressive attackers
8. ✅ TOR Exit Nodes (~1,000 IPs) - TOR network
9. ✅ Emerging Threats (~5,000 IPs) - Compromised hosts

**Each Feed Has 4 Variables:**
```bash
NFTBAN_FEED_<NAME>_ENABLED="FALSE"    # Enable/disable
NFTBAN_FEED_<NAME>_INTERVAL="DAILY"   # HOURLY/DAILY/WEEKLY
NFTBAN_FEED_<NAME>_URL="https://..."  # Source URL
NFTBAN_FEED_<NAME>_FILE="${CONFIG_DIR}/feeds/<name>-blacklist.conf"
```

**Global Settings:**
```bash
NFTBAN_FEEDS_ENABLED="FALSE"
NFTBAN_FEEDS_DOWNLOAD_TIMEOUT="30"
NFTBAN_FEEDS_MIN_ENTRIES="10"
NFTBAN_FEEDS_MAX_ENTRIES="500000"
NFTBAN_FEEDS_MEMORY_LIMIT="512"
```

**Documentation Included:**
- ✅ Comprehensive header explaining how feeds work
- ✅ Storage locations documented
- ✅ Management commands listed
- ✅ Safety features explained
- ✅ Per-feed descriptions with size/reputation/use-case
- ✅ Recommended feed combinations
- ✅ Quick start guide

### 2. Directory Structure (100% Complete)
**File:** `/home/gituser/github/nftban/lib/installer/installer_structure.sh`

**Added Directory:**
```bash
"$INSTALL_DIR/config/feeds"  # Feed IP storage location
```

**Structure:**
```
/etc/nftban/
├── config/
│   ├── nftban.conf           # Main config (user edits this)
│   └── feeds/                # Feed IP storage (NEW)
│       ├── spamhaus-blacklist.conf
│       ├── blocklistde-all-blacklist.conf
│       ├── blocklistde-ssh-blacklist.conf
│       ├── blocklistde-mail-blacklist.conf
│       ├── blocklistde-apache-blacklist.conf
│       ├── abusech-blacklist.conf
│       ├── dshield-blacklist.conf
│       ├── tor-blacklist.conf
│       └── emerging-threats-blacklist.conf
├── cache/
│   └── feeds/                # Temporary download cache
└── templates/
    └── conf/
        └── nftban.conf       # Template with feed config
```

---

## 🔲 PENDING IMPLEMENTATION

### Phase 1: Core Module Functions

#### 1. nftban_feeds_init() - Initialize Feed System
**Status:** Not started
**Priority:** HIGH

**Requirements:**
```bash
nftban_feeds_init() {
    # 1. Create config/feeds directory
    # 2. Create cache/feeds directory
    # 3. Copy nftban.conf template to config/ (if doesn't exist)
    # 4. Create nftables @feeds set (IPv4 and IPv6)
    # 5. Add firewall rules for feeds
}
```

**nftables Sets to Create:**
```bash
nft add set ip nftban_v4 feeds { type ipv4_addr\; flags interval\; auto-merge\; }
nft add set ip6 nftban_v6 feeds { type ipv6_addr\; flags interval\; auto-merge\; }
```

**Firewall Rules:**
```bash
# Add after whitelist, before temp_ban
nft add rule ip nftban_v4 input ip saddr @feeds counter drop comment "Block threat feeds"
nft add rule ip6 nftban_v6 input ip6 saddr @feeds counter drop comment "Block threat feeds"
```

---

#### 2. nftban_feeds_enable() - Enable Feed
**Status:** Not started
**Priority:** HIGH

**Requirements:**
```bash
nftban_feeds_enable() {
    local feed_id="$1"  # e.g., "spamhaus"

    # 1. Validate feed_id exists in config
    # 2. Use sed to change ENABLED="FALSE" → ENABLED="TRUE" in /etc/nftban/config/nftban.conf
    # 3. Validate interval setting (must be HOURLY/DAILY/WEEKLY)
    # 4. Download feed
    # 5. Parse and validate IPs
    # 6. Save to config/feeds/<feed>-blacklist.conf
    # 7. Load IPs to nftables @feeds set
    # 8. Log success
}
```

**sed Command Example:**
```bash
sed -i "s/^NFTBAN_FEED_${FEED_ID}_ENABLED=\"FALSE\"/NFTBAN_FEED_${FEED_ID}_ENABLED=\"TRUE\"/" /etc/nftban/config/nftban.conf
```

---

#### 3. nftban_feeds_disable() - Disable Feed
**Status:** Not started
**Priority:** HIGH

**Requirements:**
```bash
nftban_feeds_disable() {
    local feed_id="$1"

    # 1. Use sed to change ENABLED="TRUE" → ENABLED="FALSE"
    # 2. Remove feed IPs from nftables @feeds set
    # 3. Keep feed file (don't delete, just deactivate)
    # 4. Log success
}
```

---

#### 4. nftban_feeds_list() - List All Feeds
**Status:** Not started
**Priority:** MEDIUM

**Requirements:**
```bash
nftban_feeds_list() {
    # Display table:
    # [✓] feed_id    Description    Interval    IP_Count    Status
    # [✗] feed_id    Description    Interval    (disabled)

    # Read config to get ENABLED status
    # Read feed files to get IP counts
    # Show in formatted table
}
```

**Expected Output:**
```
═══════════════════════════════════════════════════════════════
  NFTBan Threat Feeds - Available Providers
═══════════════════════════════════════════════════════════════

[✓] spamhaus          Spamhaus DROP           DAILY    1,234 IPs
[✗] blocklistde_all   Blocklist.de All       HOURLY   (disabled)
[✓] blocklistde_ssh   Blocklist.de SSH       HOURLY   15,432 IPs
...
```

---

#### 5. nftban_feeds_update() - Update Feeds
**Status:** Not started
**Priority:** HIGH

**Requirements:**
```bash
nftban_feeds_update() {
    local feed_id="${1:-all}"  # Specific feed or all

    if [[ "$feed_id" == "all" ]]; then
        # Update all enabled feeds
        for feed in $(get_enabled_feeds); do
            nftban_feeds_update_single "$feed"
        done
    else
        nftban_feeds_update_single "$feed_id"
    fi
}
```

---

#### 6. nftban_feeds_update_single() - Update One Feed
**Status:** Not started
**Priority:** HIGH

**Core Logic:**
```bash
nftban_feeds_update_single() {
    local feed_id="$1"

    # 1. Read URL from config
    # 2. Download with timeout (curl --max-time 30)
    # 3. Parse IPs/CIDRs:
    #    - Remove comments (lines starting with #, ;, //)
    #    - Extract IPs and CIDRs
    #    - Validate IP format
    #    - Check against whitelist (skip whitelisted IPs)
    #    - Deduplicate
    # 4. Validate minimum entries (reject if < 10)
    # 5. Validate maximum entries (reject if > 500,000)
    # 6. Save to config/feeds/<feed>-blacklist.conf with header
    # 7. Reload nftables @feeds set
}
```

**Feed File Format:**
```bash
# =============================================================================
# NFTBan Threat Feed: Spamhaus DROP List
# =============================================================================
# Source: https://www.spamhaus.org/drop/drop.txt
# Updated: 2025-10-19 14:30:00 UTC
# Entry Count: 1,234 IPs/CIDRs
# Update Interval: DAILY
# Auto-managed by NFTBan - DO NOT EDIT MANUALLY
# =============================================================================

1.2.3.0/24
5.6.7.8
10.20.30.0/22
```

---

### Phase 2: nftables Integration

#### 7. nftban_feeds_sync_to_nftables() - Load to nftables
**Status:** Not started
**Priority:** HIGH

**Requirements:**
```bash
nftban_feeds_sync_to_nftables() {
    # 1. Flush existing @feeds set
    nft flush set ip nftban_v4 feeds
    nft flush set ip6 nftban_v6 feeds

    # 2. Aggregate all enabled feed files
    local temp_v4=$(mktemp)
    local temp_v6=$(mktemp)

    for feed in $(get_enabled_feeds); do
        local feed_file=$(get_feed_file "$feed")

        # Separate IPv4 and IPv6
        grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}' "$feed_file" >> "$temp_v4"
        grep -E '^[0-9a-fA-F:]+' "$feed_file" >> "$temp_v6"
    done

    # 3. Deduplicate
    sort -u "$temp_v4" > "$temp_v4.dedup"
    sort -u "$temp_v6" > "$temp_v6.dedup"

    # 4. Load to nftables (batch operation)
    while read -r ip; do
        nft add element ip nftban_v4 feeds { "$ip" }
    done < "$temp_v4.dedup"

    while read -r ip; do
        nft add element ip6 nftban_v6 feeds { "$ip" }
    done < "$temp_v6.dedup"

    # 5. Cleanup
    rm -f "$temp_v4" "$temp_v6" "$temp_v4.dedup" "$temp_v6.dedup"
}
```

---

### Phase 3: Scheduling & Automation

#### 8. nftban_feeds_timer_install() - Install Systemd Timer
**Status:** Not started
**Priority:** MEDIUM

**Service File:** `/etc/systemd/system/nftban-feeds.service`
```ini
[Unit]
Description=NFTBan Threat Feeds Update Service
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nftban feeds update
User=root
WorkingDirectory=/etc/nftban
StandardOutput=journal
StandardError=journal
```

**Timer File:** `/etc/systemd/system/nftban-feeds.timer`
```ini
[Unit]
Description=NFTBan Threat Feeds Update Timer (Hourly)

[Timer]
OnCalendar=*-*-* *:00:00
AccuracySec=1m
Persistent=true

[Install]
WantedBy=timers.target
```

**Commands:**
```bash
systemctl daemon-reload
systemctl enable nftban-feeds.timer
systemctl start nftban-feeds.timer
```

---

#### 9. nftban_feeds_update_scheduled() - Interval Logic
**Status:** Not started
**Priority:** MEDIUM

**Smart Interval Checking:**
```bash
nftban_feeds_update_scheduled() {
    # Called by timer every hour

    local current_hour=$(date +%H)
    local current_day=$(date +%u)  # 1=Mon, 7=Sun

    for feed_id in $(get_enabled_feeds); do
        local interval=$(get_feed_interval "$feed_id")
        local should_run=false

        case "$interval" in
            HOURLY)
                should_run=true
                ;;
            DAILY)
                [[ "$current_hour" == "00" ]] && should_run=true
                ;;
            WEEKLY)
                [[ "$current_day" == "7" && "$current_hour" == "00" ]] && should_run=true
                ;;
            *)
                # Invalid interval, use DAILY as fallback
                [[ "$current_hour" == "00" ]] && should_run=true
                ;;
        esac

        if [[ "$should_run" == "true" ]]; then
            nftban_feeds_update_single "$feed_id"
        fi
    done
}
```

---

### Phase 4: Status & Monitoring

#### 10. nftban_feeds_status() - Show Status
**Status:** Not started
**Priority:** LOW

**Requirements:**
```bash
nftban_feeds_status() {
    # Display:
    # - Global enabled/disabled status
    # - Total IPs in @feeds set
    # - Per-feed status with last update time
    # - Memory usage
    # - Timer status (active/inactive)
}
```

---

#### 11. nftban_feeds_memory() - Memory Usage
**Status:** Not started
**Priority:** LOW

**Requirements:**
```bash
nftban_feeds_memory() {
    # Calculate:
    # - Total feed file sizes
    # - nftables set memory usage
    # - Warn if > NFTBAN_FEEDS_MEMORY_LIMIT
}
```

---

## Implementation Order (Recommended)

### Week 1: Core Functions
1. ✅ Configuration design
2. ✅ Directory structure
3. 🔲 nftban_feeds_init()
4. 🔲 nftban_feeds_enable()
5. 🔲 nftban_feeds_disable()
6. 🔲 nftban_feeds_update_single()
7. 🔲 nftban_feeds_sync_to_nftables()

### Week 2: User Interface
8. 🔲 nftban_feeds_list()
9. 🔲 nftban_feeds_update()
10. 🔲 CLI integration (cmd_feeds)

### Week 3: Automation
11. 🔲 nftban_feeds_timer_install()
12. 🔲 nftban_feeds_timer_remove()
13. 🔲 nftban_feeds_update_scheduled()

### Week 4: Polish & Testing
14. 🔲 nftban_feeds_status()
15. 🔲 nftban_feeds_memory()
16. 🔲 Integration testing
17. 🔲 Documentation

---

## Key Design Decisions Summary

| Aspect | Decision |
|--------|----------|
| **Config File** | Single file: `/etc/nftban/config/nftban.conf` |
| **Feed Storage** | `/etc/nftban/config/feeds/<feed>-blacklist.conf` |
| **Enable/Disable** | sed in-place replacement of `FALSE`↔`TRUE` |
| **Intervals** | HOURLY, DAILY, WEEKLY only (validated) |
| **Timer** | Single hourly timer + smart interval logic |
| **nftables** | Split tables: `ip nftban_v4` + `ip6 nftban_v6` |
| **Default State** | All feeds DISABLED (safe init) |
| **Whitelist** | Always respected (never block whitelisted IPs) |
| **Feed Count** | 9 feeds total |

---

## Next Steps

1. **Continue implementation** of core functions
2. **Test each function** individually before integration
3. **Document** each function with examples
4. **Create** comprehensive test suite

**Current Blocker:** None (ready to continue implementation)
