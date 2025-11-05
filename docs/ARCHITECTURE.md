# NFTBan Architecture

**Version:** 0.30.1
**Philosophy:** Simple, secure, atomic operations

---

## Core Design

### Two-Table nftables Architecture

NFTBan uses **two separate nftables tables** for zero-downtime updates:

```
┌─────────────────────────────────────────┐
│  inet nftban_runtime (priority -5)      │  ← Temporary bans (Fail2ban)
│  • Never replaced during reloads        │
│  • Maintains temp bans with timeouts    │
└─────────────────────────────────────────┘
            ↓ (if not matched)
┌─────────────────────────────────────────┐
│  inet nftban_main (priority 0)          │  ← Permanent rules
│  • Rebuilt atomically from config       │
│  • Whitelist, blacklist, allowed ports  │
└─────────────────────────────────────────┘
```

**Why Two Tables?**
- Runtime bans survive config reloads
- Atomic updates (~10ms, zero packet loss)
- Fail2ban integration without service restarts

---

## Rule Processing Order (CRITICAL)

**Security Fix v0.30.1:** Blacklist checks now run BEFORE port checks.

```nft
chain input {
  type filter hook input priority 0; policy drop;

  # 1. Always allow established connections & loopback
  ct state established,related counter accept
  iif lo counter accept

  # 2. Whitelist ALWAYS wins (highest priority)
  ip saddr @whitelist_v4 counter accept
  ip6 saddr @whitelist_v6 counter accept

  # 3. ICMP for diagnostics (before blacklist)
  ip protocol icmp icmp type {...} counter accept
  ip6 nexthdr ipv6-icmp icmpv6 type {...} counter accept

  # 4. CRITICAL: Blacklist BEFORE ports (v0.30.1 fix)
  ip saddr @blacklist_v4 counter drop
  ip6 saddr @blacklist_v6 counter drop

  # 5. Invalid state
  ct state invalid counter drop

  # 6. Allowed service ports (AFTER blacklist)
  tcp dport @tcp_ports counter accept
  udp dport @udp_ports counter accept

  # 7. Default: drop (secure by default)
}
```

**Why This Order Matters:**
- Whitelist prevents accidental lockout
- Blacklist blocks malicious IPs BEFORE they can reach services
- Default drop = secure by default

**v0.30.0 Bug:** Port checks ran before blacklist → blacklisted IPs could access SSH!
**v0.30.1 Fix:** Blacklist checks run first → blacklisted IPs are blocked from all services.

---

## Set-Based Filtering

nftables **sets** provide O(1) lookup performance:

```
whitelist_v4/v6  → Always allowed (prevent lockout)
blacklist_v4/v6  → Permanently blocked
tcp_ports        → Allowed TCP services
udp_ports        → Allowed UDP services
temp_ban_v4/v6   → Temporary bans (with timeout)
```

**Benefits:**
- Add/remove IPs in ~10ms (atomic)
- No service restart needed
- Thousands of IPs with zero performance impact

---

## Atomic Operations

All firewall updates use **atomic nftables operations**:

```bash
# Atomic IP add (10ms, zero downtime)
nft add element inet nftban_main whitelist_v4 { 192.0.2.1 }

# Atomic table replace (entire ruleset reload)
nft -f /run/nftban/nftban_main.nft
```

**Runtime table is NEVER replaced** → temporary bans survive all config changes.

---

## Directory Structure (FHS Compliant)

```
/etc/nftban/
├── nftban.conf              # Main configuration
├── whitelist.d/*.conf       # Whitelisted IPs (preserved on upgrade)
├── blacklist.d/*.conf       # Blacklisted IPs (preserved on upgrade)
├── ports.d/*.conf           # Allowed ports (preserved on upgrade)
├── conf.d/*.conf            # Module configs (overwritten on upgrade)
└── conf.d/*.conf.local      # User overrides (preserved on upgrade)

/usr/lib/nftban/
├── bin/                     # Go binaries (nftban-geoip, etc.)
├── cli/cmd_*.sh             # CLI command modules (25 commands)
├── core/nftban_*.sh         # Core library functions
├── cron/                    # Maintenance scripts (run every 15min)
├── helpers/                 # Helper scripts (autoheal, etc.)
└── nft-runtime.nft          # Runtime table template

/usr/sbin/
├── nftban                   # Main CLI dispatcher
└── nftban-complete          # Backend (rule generation)

/var/lib/nftban/
├── state/                   # Runtime state
├── feeds/                   # Downloaded threat feeds
├── reports/                 # Generated reports
└── geoip/                   # GeoIP databases

/var/log/nftban/             # All logs
/run/nftban/                 # Runtime files (generated rulesets)
```

---

## Component Overview

### CLI (25 Commands)
```
Core:           status, check, health, version, help
Firewall:       firewall, ban, unban, search, whitelist, profile
Protection:     ddos, portscan, login, fail2ban, feeds, cloudflare
Monitoring:     stats, report, port, module, services
System:         fhs, nftables, geoip, mail, permissions
```

All commands support:
- `--help` for usage
- `--json` for machine-readable output (where applicable)
- Tab completion (via bash-completion)

### Core Modules
```
nftban_health.sh     → Health checks & auto-heal
nftban_nftables.sh   → nftables management
nftban_feeds.sh      → Threat feed integration
nftban_stats.sh      → Statistics & reporting
nftban_portscan.sh   → Port scan detection
```

### Maintenance (Runs Every 15 Minutes)
```
maintenance.sh       → Always runs (even if NFTBan disabled)
  • SSH port monitoring (prevent lockout)
  • System IP changes (auto-whitelist)
  • Auto-heal (fix permissions, directories)
  • Config validation
```

---

## Security Features

### Lockout Prevention
1. **SSH port auto-detection** → Always whitelisted
2. **System IP auto-whitelist** → Your IP is protected
3. **Atomic updates** → No service disruption
4. **Commit-confirm** → Auto-rollback on failure (future feature)

### Auto-Heal System
Runs every 15 minutes and on package install/upgrade:
- Creates missing directories
- Fixes file permissions (750/640)
- Creates nftban user/group
- Validates critical configs

### Polkit Integration
Non-root users in `nftban-auditors` group can:
- View status (`nftban status`)
- Check health (`nftban health`)
- View stats (`nftban stats`)
- No privilege escalation (read-only access)

---

## Configuration Philosophy

### .conf vs .conf.local Pattern

```
/etc/nftban/conf.d/
├── mail.conf           ← Overwritten on upgrade
└── mail.conf.local     ← Preserved on upgrade (user customizations)
```

**Logic:** `.conf.local` overrides `.conf` values.

**Example:**
```bash
# mail.conf (default)
MAIL_ENABLED=false

# mail.conf.local (user override)
MAIL_ENABLED=true
MAIL_TO="admin@example.com"
```

Result: Mail enabled with custom recipient, survives upgrades.

### Configuration Directories

**Preserved on upgrade:**
- `whitelist.d/` → Your whitelisted IPs
- `blacklist.d/` → Your blacklisted IPs
- `ports.d/` → Your allowed ports
- `*.conf.local` → Your customizations

**Overwritten on upgrade:**
- `conf.d/*.conf` → Defaults restored
- Package updates won't break your customizations!

---

## Performance

**Atomic Operations:**
- Add/remove IP: ~10ms
- Reload whitelist: ~50ms
- Full firewall reload: ~100-200ms
- Zero packet loss during updates

**Scalability:**
- 10,000+ IPs in sets: No performance impact
- Set lookup: O(1) constant time
- Feed processing: Parallel downloads

---

## Integration Points

### Fail2ban
```
nftables → nftban_runtime table → temp_ban_v4/v6 sets
Action: nftban (adds to runtime table with timeout)
```

### Feeds (Threat Intelligence)
```
Download → Parse → Add to blacklist_v4/v6 → Atomic reload
Sources: Spamhaus, Emerging Threats, custom feeds
```

### GeoIP (Go Binary)
```
/usr/lib/nftban/bin/nftban-geoip <ip>
Uses MaxMind GeoLite2 database
Output: JSON with country, city, ASN
```

---

## Monitoring & Observability

### Counters (v0.30.1)
Every rule has a counter for packet/byte tracking:

```bash
nft list chain inet nftban_main input
# Shows:
#   counter packets 1234 bytes 567890 accept
```

### Health Checks
```bash
nftban health check
# Validates:
# - nftables service active
# - Tables exist
# - Chains present
# - Sets populated
# - SSH port protected
# - System IP whitelisted
```

### Statistics
```bash
nftban stats          # Dashboard
nftban stats top      # Top blocked IPs
nftban stats ip <IP>  # IP history
nftban stats export   # JSON export
```

---

## Common Operations

### Enable/Disable
```bash
nftban enable   # Activate firewall + services
nftban disable  # Deactivate (config preserved)
nftban status   # Check current state
```

### Firewall Management
```bash
nftban firewall init     # First-time setup
nftban firewall reload   # Reload from config
nftban firewall status   # Show tables/sets/chains
```

### IP Management
```bash
nftban ban <ip>          # Add to blacklist
nftban unban <ip>        # Remove from blacklist
nftban search <ip>       # Find IP in all sets
nftban whitelist add <ip>  # Protect IP
```

### Protection Modules
```bash
nftban portscan enable   # Detect port scans
nftban ddos enable       # Enable DDoS protection
nftban feeds enable      # Enable threat feeds
nftban fail2ban setup    # Configure Fail2ban
```

---

## Troubleshooting

### Check Firewall Status
```bash
nftban firewall check    # Full health check
nft list tables          # Show all tables
nft list table inet nftban_main  # Show rules
```

### View Logs
```bash
journalctl -u nftban.service -f
tail -f /var/log/nftban/*.log
```

### Auto-Heal
```bash
nftban health check --auto-heal  # Fix common issues
```

### Manual Reload
```bash
nftban firewall reload   # Rebuild from config
```

---

## Version History

**v0.30.1 (2025-11-05) - Critical Security Release**
- ✅ CRITICAL: Fixed rule order (blacklist before ports)
- ✅ Chain renamed: input_main → input (consistency)
- ✅ Numeric priorities: -5, 0 (not -310, -300)
- ✅ Default policy: drop (secure by default)
- ✅ Counters added: All rules now have packet counters
- ✅ Set name typo fixed: whitelist_ipv4 → whitelist_v4
- ✅ nftables syntax fixed: counter before accept/drop

**v0.30.0 (2025-11-03)**
- Inventory monitoring system
- Baseline management with drift detection
- Advanced health checks with auto-heal
- Alert throttling (prevent notification spam)
- Per-file .local configuration override system
- Polkit-based auditors group

**v0.10.0 (2024)**
- Two-table nftables architecture
- Commit-confirm recovery system
- Go binaries (10-60x faster processing)
- Port scan detection
- Comprehensive feed management
- Automatic SSH port detection

---

## Learn More

- **CLI Help:** `nftban help` or `nftban <command> help`
- **Man Page:** `man nftban` (complete reference)
- **Source Code:** Read the code! `/usr/lib/nftban/` (open source)
- **Issues:** https://github.com/itcmsgr/nftban/issues

---

**Philosophy:** Good CLI + Man page + Code = Users understand.

*Less is more. The code is open, explore it!*
