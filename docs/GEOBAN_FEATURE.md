# NFTBan GeoBan - High-Level Design (HLD)
**Date:** 2025-11-05
**Version:** 0.31.0
**Status:** 🎯 DESIGN PROPOSAL

---

## 📋 EXECUTIVE SUMMARY

**Purpose:** Add country-based ban/unban/whitelist functionality to NFTBan using Go for fast IP range management and atomic nftables loading.

**Goal:** Enable users to block or whitelist entire countries by country code (e.g., CN for China, IR for Iran) with:
- Fast Go-based IP range retrieval
- Atomic nftables loading (0ms gap)
- Persistent configuration
- Integration with existing GeoIP system

**Example Commands:**
```bash
# Ban entire country
nftban geoip ban CN IR         # Ban China and Iran

# Unban country
nftban geoip unban CN           # Remove China ban

# Whitelist country
nftban geoip whitelist US UK    # Whitelist USA and UK

# Status
nftban geoip status             # Show banned/whitelisted countries
```

---

## 🔍 CURRENT STATE ANALYSIS

### ✅ What Exists in NFTBan:

#### 1. GeoIP System (v0.31.0)
**Location:** `/usr/lib/nftban/core/nftban_geoip_go.sh`, `/usr/lib/nftban/bin/nftban-geoip`

**Features:**
- MaxMind GeoLite2 database integration
- Fast IP → Country lookups (50-200 microseconds)
- Go binary for performance
- Database auto-update capability

**Configuration:** `/etc/nftban/conf.d/geoip.conf`
```bash
MAXMIND_LICENSE_KEY="your_license_key_here"
GEOIP_DATABASE="/var/lib/nftban/geoip/GeoLite2-City.mmdb"
GEOIP_ENABLED="true"
GEOIP_AUTO_UPDATE="true"
```

**Current Commands:**
```bash
nftban geoip lookup <IP>        # Lookup IP country
nftban geoip bulk <file>        # Bulk lookups
nftban geoip status             # Show system status
nftban geoip test               # Run tests
nftban geoip update             # Update database
```

**Missing:** ❌ NO country ban/unban/whitelist functionality

#### 2. Atomic Operations Pattern
**Location:** `/usr/sbin/nftban-complete:388`

**Existing atomic ban:**
```bash
nft add element inet nftban_runtime temp_ban_v4 "{ $ip timeout ${timeout_s}s }"
```

**Pattern:**
- Direct `nft add element` (atomic)
- Direct `nft delete element` (atomic)
- No reload gap (0ms)
- Same pattern for whitelist/blacklist

#### 3. File-Based Persistence
**Locations:**
- `/etc/nftban/whitelist.d/` - Whitelist files
- `/etc/nftban/blacklist.d/` - Blacklist files

**Example:** `/etc/nftban/whitelist.d/20-cloudflare.conf`
```bash
# Cloudflare IPv4 Ranges
173.245.48.0/20
103.21.244.0/22
...

# Cloudflare IPv6 Ranges
2400:cb00::/32
2606:4700::/32
```

**Format:**
- One IP/CIDR per line
- Comments with `#`
- Auto-managed files marked with headers
- Loaded on boot/reload

#### 4. nftables Sets Structure
**Existing sets:**
```
inet nftban_main {
    set whitelist_v4 { type ipv4_addr; flags interval; }
    set whitelist_v6 { type ipv6_addr; flags interval; }
    set blacklist_v4 { type ipv4_addr; flags interval; }
    set blacklist_v6 { type ipv6_addr; flags interval; }
    set feed_v4      { type ipv4_addr; flags interval; }
    set feed_v6      { type ipv6_addr; flags interval; }
    set tcp_ports    { type inet_service; }
    set udp_ports    { type inet_service; }
}

inet nftban_runtime {
    set temp_ban_v4  { type ipv4_addr; flags timeout; }
    set temp_ban_v6  { type ipv6_addr; flags timeout; }
}
```

#### 5. Feeds System (Similar to What We Need)
**Location:** `/usr/lib/nftban/bin/nftban-feeds`, `/usr/lib/nftban/core/nftban_feeds.sh`

**Pattern:**
- Go binary manages IP lists
- Fast download and parsing
- Atomic loading to nftables
- Configuration persistence

**What we can reuse:**
- Go binary pattern for IP range management
- Atomic loading mechanism
- Configuration file structure

### ❌ What's Missing:

1. **Country → IP Range Mapping**
   - No database/source for country IP ranges
   - MaxMind has country data but not complete IP ranges per country

2. **Country Ban/Unban Commands**
   - No CLI commands for country operations
   - No configuration file for banned/whitelisted countries

3. **Country IP Range Files**
   - No `/etc/nftban/geoban.d/` directory structure
   - No country-specific IP list files

4. **Go Module for Country IP Management**
   - Need Go code to fetch/manage country IP ranges
   - Need integration with atomic loading

5. **nftables Sets for Country Blocking**
   - Could use existing blacklist/whitelist sets
   - Or create dedicated `geoban_v4`, `geoban_v6` sets

6. **Configuration Persistence**
   - No config file to save banned/whitelisted countries
   - Need `/etc/nftban/conf.d/geoban.conf`

---

## 🎯 PROPOSED SOLUTION

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    NFTBan GeoBan System                      │
└─────────────────────────────────────────────────────────────┘
                            │
                            ↓
            ┌───────────────────────────────┐
            │   CLI Commands (Bash)          │
            │   nftban geoip ban <CC>        │
            │   nftban geoip unban <CC>      │
            │   nftban geoip whitelist <CC>  │
            └───────────────────────────────┘
                            │
                            ↓
            ┌───────────────────────────────┐
            │   Go Binary Enhancement        │
            │   nftban-geoip (extended)      │
            │                                 │
            │   • Fetch country IP ranges    │
            │   • Cache IP lists             │
            │   • Fast CIDR merging          │
            │   • Atomic nftables sync       │
            └───────────────────────────────┘
                            │
                            ↓
            ┌───────────────────────────────┐
            │   IP Range Sources             │
            │   • IPdeny.com (free)          │
            │   • Aggregate feeds            │
            │   • Cached locally             │
            └───────────────────────────────┘
                            │
                            ↓
            ┌───────────────────────────────┐
            │   Configuration Files          │
            │   /etc/nftban/conf.d/          │
            │   • geoban.conf                │
            │   • geoban.conf.local          │
            │                                 │
            │   /etc/nftban/geoban.d/        │
            │   • 50-ban-CN.conf             │
            │   • 50-ban-IR.conf             │
            │   • 40-whitelist-US.conf       │
            └───────────────────────────────┘
                            │
                            ↓
            ┌───────────────────────────────┐
            │   nftables Sets (Atomic)       │
            │   inet nftban_main             │
            │   • blacklist_v4               │
            │   • blacklist_v6               │
            │   • whitelist_v4               │
            │   • whitelist_v6               │
            │   (reuse existing sets)        │
            └───────────────────────────────┘
```

---

## 🔧 DETAILED IMPLEMENTATION

### 1. Configuration Structure

#### `/etc/nftban/conf.d/geoban.conf` (New)
```bash
# =============================================================================
# NFTBan GeoBan Configuration
# =============================================================================

# Enable GeoBan functionality
GEOBAN_ENABLED="false"

# Banned countries (space-separated ISO 3166-1 alpha-2 codes)
GEOBAN_BANNED_COUNTRIES=""

# Whitelisted countries (always allow, even if in banned list)
GEOBAN_WHITELISTED_COUNTRIES=""

# IP Range Source
GEOBAN_SOURCE="ipdeny"  # ipdeny, ip2location, dbip

# Cache directory
GEOBAN_CACHE_DIR="/var/lib/nftban/geoban"

# Cache TTL (how often to refresh country IP ranges)
GEOBAN_CACHE_TTL="604800"  # 7 days in seconds

# Auto-update settings
GEOBAN_AUTO_UPDATE="true"
GEOBAN_UPDATE_INTERVAL="weekly"  # daily, weekly, monthly

# IP Range files location
GEOBAN_FILES_DIR="/etc/nftban/geoban.d"

# Atomic loading (use add/delete element instead of reload)
GEOBAN_ATOMIC_LOADING="true"

# Track current IPs for atomic updates
GEOBAN_TRACKING_DIR="/var/lib/nftban/geoban/tracking"

# =============================================================================
# USAGE EXAMPLES
# =============================================================================
#
# Ban countries:
#   nftban geoip ban CN IR RU
#
# Unban country:
#   nftban geoip unban CN
#
# Whitelist countries:
#   nftban geoip whitelist US UK DE
#
# Status:
#   nftban geoip status
#
# Update IP ranges:
#   nftban geoip update
#
# =============================================================================
```

#### `/etc/nftban/geoban.d/` Directory Structure (New)
```
/etc/nftban/geoban.d/
├── 50-ban-CN.conf          # China banned IPs
├── 50-ban-IR.conf          # Iran banned IPs
├── 50-ban-RU.conf          # Russia banned IPs
├── 40-whitelist-US.conf    # USA whitelisted IPs
└── 40-whitelist-UK.conf    # UK whitelisted IPs

# Naming convention:
# [priority]-[action]-[countrycode].conf
#
# Priority: 40 = whitelist, 50 = ban (whitelist takes precedence)
# Action: ban, whitelist
# Country: ISO 3166-1 alpha-2 code (uppercase)
```

#### Example: `/etc/nftban/geoban.d/50-ban-CN.conf`
```bash
# =============================================================================
# NFTBan GeoBan - China (CN) - BANNED
# =============================================================================
# This file is automatically managed by nftban geoip module
# Generated: 2025-11-05T21:00:00+00:00
#
# DO NOT EDIT MANUALLY - Changes will be overwritten on update
#
# Country: China (CN)
# Action: BAN (blacklist)
# Total IPv4 ranges: 8,404
# Total IPv6 ranges: 3,542
# Source: ipdeny.com
# Last updated: 2025-11-05
# =============================================================================

# IPv4 Ranges
1.0.1.0/24
1.0.2.0/23
1.0.8.0/21
1.0.32.0/19
... (8,404 ranges)

# IPv6 Ranges
240e::/20
240e:1000::/20
240e:2000::/20
... (3,542 ranges)
```

---

### 2. CLI Commands (Bash)

#### `/usr/lib/nftban/cli/cmd_geoip.sh` (Extend existing)

Add new subcommands to existing `nftban_cmd_geoip()`:

```bash
nftban_cmd_geoip() {
    local subcommand="${1:-}"
    shift

    case "$subcommand" in
        lookup)   nftban_geoip_cmd_lookup "$@" ;;
        bulk)     nftban_geoip_cmd_bulk "$@" ;;
        status)   nftban_geoip_cmd_status "$@" ;;
        test)     nftban_geoip_cmd_test "$@" ;;
        update)   nftban_geoip_cmd_update "$@" ;;

        # NEW: GeoBan commands
        ban)      nftban_geoip_cmd_ban "$@" ;;
        unban)    nftban_geoip_cmd_unban "$@" ;;
        whitelist) nftban_geoip_cmd_whitelist "$@" ;;
        unwhitelist) nftban_geoip_cmd_unwhitelist "$@" ;;
        list)     nftban_geoip_cmd_list "$@" ;;

        help)     nftban_geoip_cmd_help ;;
        *)        echo "ERROR: Unknown command: $subcommand" >&2; return 1 ;;
    esac
}

# =============================================================================
# NEW GEOBAN COMMANDS
# =============================================================================

nftban_geoip_cmd_ban() {
    # Ban one or more countries
    # Args: $@ = country codes (e.g., CN IR RU)

    local countries=("$@")

    if [[ ${#countries[@]} -eq 0 ]]; then
        echo "ERROR: At least one country code required" >&2
        echo "Usage: nftban geoip ban <CC> [CC...]" >&2
        echo "Example: nftban geoip ban CN IR RU" >&2
        return 1
    fi

    # Validate country codes (2-letter uppercase)
    for cc in "${countries[@]}"; do
        if [[ ! "$cc" =~ ^[A-Z]{2}$ ]]; then
            echo "ERROR: Invalid country code: $cc" >&2
            echo "Must be 2-letter ISO 3166-1 alpha-2 code (uppercase)" >&2
            return 1
        fi
    done

    # Load GeoBan module
    if ! declare -f nftban_geoban_ban_countries >/dev/null 2>&1; then
        source /usr/lib/nftban/core/nftban_geoban.sh || {
            echo "ERROR: Failed to load GeoBan module" >&2
            return 1
        }
    fi

    # Call Go binary to ban countries
    nftban_geoban_ban_countries "${countries[@]}"
}

nftban_geoip_cmd_unban() {
    # Unban one or more countries
    # Args: $@ = country codes

    local countries=("$@")

    if [[ ${#countries[@]} -eq 0 ]]; then
        echo "ERROR: At least one country code required" >&2
        echo "Usage: nftban geoip unban <CC> [CC...]" >&2
        return 1
    fi

    # Load GeoBan module
    if ! declare -f nftban_geoban_unban_countries >/dev/null 2>&1; then
        source /usr/lib/nftban/core/nftban_geoban.sh || {
            echo "ERROR: Failed to load GeoBan module" >&2
            return 1
        }
    fi

    # Call Go binary to unban countries
    nftban_geoban_unban_countries "${countries[@]}"
}

nftban_geoip_cmd_whitelist() {
    # Whitelist one or more countries
    # Args: $@ = country codes

    local countries=("$@")

    if [[ ${#countries[@]} -eq 0 ]]; then
        echo "ERROR: At least one country code required" >&2
        echo "Usage: nftban geoip whitelist <CC> [CC...]" >&2
        return 1
    fi

    # Load GeoBan module
    if ! declare -f nftban_geoban_whitelist_countries >/dev/null 2>&1; then
        source /usr/lib/nftban/core/nftban_geoban.sh || {
            echo "ERROR: Failed to load GeoBan module" >&2
            return 1
        }
    fi

    # Call Go binary to whitelist countries
    nftban_geoban_whitelist_countries "${countries[@]}"
}

nftban_geoip_cmd_list() {
    # List banned/whitelisted countries
    # No args

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  GeoBan Status"
    echo "═══════════════════════════════════════════════════════════"
    echo ""

    # Load config
    local config_file="/etc/nftban/conf.d/geoban.conf"
    if [[ -f "$config_file" ]]; then
        source "$config_file"
    fi

    # Check if enabled
    local enabled="${GEOBAN_ENABLED:-false}"
    if [[ "$enabled" == "true" ]]; then
        echo "Status: ✓ ENABLED"
    else
        echo "Status: ✗ DISABLED"
    fi
    echo ""

    # Banned countries
    local banned="${GEOBAN_BANNED_COUNTRIES:-}"
    if [[ -n "$banned" ]]; then
        echo "🚫 Banned Countries:"
        for cc in $banned; do
            local count_v4 count_v6
            count_v4=$(wc -l < "/etc/nftban/geoban.d/50-ban-${cc}.conf" 2>/dev/null | grep -v '^#' | wc -l || echo "0")
            echo "   • $cc (${count_v4} IPv4 ranges)"
        done
    else
        echo "🚫 Banned Countries: (none)"
    fi
    echo ""

    # Whitelisted countries
    local whitelisted="${GEOBAN_WHITELISTED_COUNTRIES:-}"
    if [[ -n "$whitelisted" ]]; then
        echo "✓ Whitelisted Countries:"
        for cc in $whitelisted; do
            local count_v4 count_v6
            count_v4=$(wc -l < "/etc/nftban/geoban.d/40-whitelist-${cc}.conf" 2>/dev/null | grep -v '^#' | wc -l || echo "0")
            echo "   • $cc (${count_v4} IPv4 ranges)"
        done
    else
        echo "✓ Whitelisted Countries: (none)"
    fi
    echo ""

    # Statistics
    local total_banned_ips total_whitelisted_ips
    total_banned_ips=$(nft list set inet nftban_main blacklist_v4 2>/dev/null | grep -c 'elements' || echo "0")
    total_whitelisted_ips=$(nft list set inet nftban_main whitelist_v4 2>/dev/null | grep -c 'elements' || echo "0")

    echo "📊 Current nftables:"
    echo "   Blacklist IPv4: ${total_banned_ips} ranges"
    echo "   Whitelist IPv4: ${total_whitelisted_ips} ranges"
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo ""
}
```

---

### 3. Core Module (Bash Wrapper)

#### `/usr/lib/nftban/core/nftban_geoban.sh` (New file)

```bash
#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.31.0 - GeoBan Core Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Country-based IP banning/whitelisting with atomic operations
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${NFTBAN_GEOBAN_LOADED:-}" ]] && return 0
readonly NFTBAN_GEOBAN_LOADED=1

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly NFTBAN_GEOBAN_BIN="${NFTBAN_GEOBAN_BIN:-/usr/lib/nftban/bin/nftban-geoip}"
readonly NFTBAN_GEOBAN_CONFIG="${NFTBAN_GEOBAN_CONFIG:-/etc/nftban/conf.d/geoban.conf}"
readonly NFTBAN_GEOBAN_DIR="${NFTBAN_GEOBAN_DIR:-/etc/nftban/geoban.d}"
readonly NFTBAN_GEOBAN_CACHE="${NFTBAN_GEOBAN_CACHE:-/var/lib/nftban/geoban}"
readonly NFTBAN_GEOBAN_TRACKING="${NFTBAN_GEOBAN_TRACKING:-/var/lib/nftban/geoban/tracking}"

# =============================================================================
# INITIALIZATION
# =============================================================================

nftban_geoban_init() {
    # Initialize GeoBan directories and config

    # Create directories
    mkdir -p "$NFTBAN_GEOBAN_DIR" 2>/dev/null || true
    mkdir -p "$NFTBAN_GEOBAN_CACHE" 2>/dev/null || true
    mkdir -p "$NFTBAN_GEOBAN_TRACKING" 2>/dev/null || true

    # Create config if doesn't exist
    if [[ ! -f "$NFTBAN_GEOBAN_CONFIG" ]]; then
        cat > "$NFTBAN_GEOBAN_CONFIG" << 'EOF'
# NFTBan GeoBan Configuration
GEOBAN_ENABLED="false"
GEOBAN_BANNED_COUNTRIES=""
GEOBAN_WHITELISTED_COUNTRIES=""
GEOBAN_SOURCE="ipdeny"
GEOBAN_CACHE_TTL="604800"
GEOBAN_ATOMIC_LOADING="true"
EOF
    fi
}

# =============================================================================
# BAN COUNTRIES
# =============================================================================

nftban_geoban_ban_countries() {
    # Ban one or more countries
    # Args: $@ = country codes

    local countries=("$@")

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  Banning Countries: ${countries[*]}"
    echo "═══════════════════════════════════════════════════════════"
    echo ""

    # Initialize
    nftban_geoban_init

    # Load current config
    source "$NFTBAN_GEOBAN_CONFIG"

    for cc in "${countries[@]}"; do
        echo "⏳ Processing country: $cc"

        # Call Go binary to fetch and process country IPs
        "$NFTBAN_GEOBAN_BIN" geoban fetch "$cc" --action ban --atomic || {
            echo "ERROR: Failed to fetch IPs for $cc" >&2
            continue
        }

        # Add to config if not already present
        if [[ ! "$GEOBAN_BANNED_COUNTRIES" =~ (^|[[:space:]])$cc($|[[:space:]]) ]]; then
            GEOBAN_BANNED_COUNTRIES="${GEOBAN_BANNED_COUNTRIES} $cc"
        fi

        echo "✓ Country $cc banned successfully"
        echo ""
    done

    # Save config
    _nftban_geoban_save_config

    # Enable GeoBan
    sed -i 's/^GEOBAN_ENABLED=.*/GEOBAN_ENABLED="true"/' "$NFTBAN_GEOBAN_CONFIG"

    echo "═══════════════════════════════════════════════════════════"
    echo "✓ Ban complete"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
}

nftban_geoban_unban_countries() {
    # Unban one or more countries
    # Args: $@ = country codes

    local countries=("$@")

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  Unbanning Countries: ${countries[*]}"
    echo "═══════════════════════════════════════════════════════════"
    echo ""

    # Load current config
    source "$NFTBAN_GEOBAN_CONFIG"

    for cc in "${countries[@]}"; do
        echo "⏳ Processing country: $cc"

        # Call Go binary to remove country IPs atomically
        "$NFTBAN_GEOBAN_BIN" geoban remove "$cc" --action ban --atomic || {
            echo "ERROR: Failed to remove IPs for $cc" >&2
            continue
        }

        # Remove from config
        GEOBAN_BANNED_COUNTRIES=$(echo "$GEOBAN_BANNED_COUNTRIES" | sed "s/\<$cc\>//g" | xargs)

        # Remove file
        rm -f "/etc/nftban/geoban.d/50-ban-${cc}.conf"

        echo "✓ Country $cc unbanned successfully"
        echo ""
    done

    # Save config
    _nftban_geoban_save_config

    echo "═══════════════════════════════════════════════════════════"
    echo "✓ Unban complete"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
}

nftban_geoban_whitelist_countries() {
    # Whitelist one or more countries
    # Args: $@ = country codes

    local countries=("$@")

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  Whitelisting Countries: ${countries[*]}"
    echo "═══════════════════════════════════════════════════════════"
    echo ""

    # Initialize
    nftban_geoban_init

    # Load current config
    source "$NFTBAN_GEOBAN_CONFIG"

    for cc in "${countries[@]}"; do
        echo "⏳ Processing country: $cc"

        # Call Go binary to fetch and whitelist country IPs
        "$NFTBAN_GEOBAN_BIN" geoban fetch "$cc" --action whitelist --atomic || {
            echo "ERROR: Failed to fetch IPs for $cc" >&2
            continue
        }

        # Add to config if not already present
        if [[ ! "$GEOBAN_WHITELISTED_COUNTRIES" =~ (^|[[:space:]])$cc($|[[:space:]]) ]]; then
            GEOBAN_WHITELISTED_COUNTRIES="${GEOBAN_WHITELISTED_COUNTRIES} $cc"
        fi

        echo "✓ Country $cc whitelisted successfully"
        echo ""
    done

    # Save config
    _nftban_geoban_save_config

    # Enable GeoBan
    sed -i 's/^GEOBAN_ENABLED=.*/GEOBAN_ENABLED="true"/' "$NFTBAN_GEOBAN_CONFIG"

    echo "═══════════════════════════════════════════════════════════"
    echo "✓ Whitelist complete"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
}

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

_nftban_geoban_save_config() {
    # Save configuration to geoban.conf.local

    local local_config="/etc/nftban/conf.d/geoban.conf.local"

    cat > "$local_config" << EOF
# NFTBan GeoBan Configuration (User Overrides)
# Auto-generated: $(date -Iseconds)

GEOBAN_ENABLED="true"
GEOBAN_BANNED_COUNTRIES="${GEOBAN_BANNED_COUNTRIES}"
GEOBAN_WHITELISTED_COUNTRIES="${GEOBAN_WHITELISTED_COUNTRIES}"
EOF

    chmod 640 "$local_config" 2>/dev/null || true
}

# Export functions
export -f nftban_geoban_init
export -f nftban_geoban_ban_countries
export -f nftban_geoban_unban_countries
export -f nftban_geoban_whitelist_countries
```

---

### 4. Go Binary Extension

#### Extend `/usr/lib/nftban/bin/nftban-geoip` (Go code)

Add new subcommands to existing Go binary:

```go
// cmd/nftban-geoip/main.go

func main() {
    app := &cli.App{
        Name:  "nftban-geoip",
        Usage: "Fast GeoIP lookups and GeoBan management",
        Commands: []*cli.Command{
            // Existing commands
            {
                Name:   "lookup",
                Usage:  "Lookup IP address",
                Action: lookupCommand,
            },
            {
                Name:   "status",
                Usage:  "Show database status",
                Action: statusCommand,
            },

            // NEW: GeoBan commands
            {
                Name:   "geoban",
                Usage:  "Country IP range management",
                Subcommands: []*cli.Command{
                    {
                        Name:   "fetch",
                        Usage:  "Fetch country IP ranges",
                        Flags: []cli.Flag{
                            &cli.StringFlag{
                                Name:     "action",
                                Usage:    "Action: ban or whitelist",
                                Required: true,
                            },
                            &cli.BoolFlag{
                                Name:  "atomic",
                                Usage: "Use atomic nftables operations",
                                Value: true,
                            },
                        },
                        Action: geobanFetchCommand,
                    },
                    {
                        Name:   "remove",
                        Usage:  "Remove country IPs from nftables",
                        Flags: []cli.Flag{
                            &cli.StringFlag{
                                Name:     "action",
                                Usage:    "Action: ban or whitelist",
                                Required: true,
                            },
                            &cli.BoolFlag{
                                Name:  "atomic",
                                Usage: "Use atomic nftables operations",
                                Value: true,
                            },
                        },
                        Action: geobanRemoveCommand,
                    },
                    {
                        Name:   "update",
                        Usage:  "Update all country IP ranges",
                        Action: geobanUpdateCommand,
                    },
                },
            },
        },
    }

    app.Run(os.Args)
}

// =============================================================================
// GEOBAN COMMANDS
// =============================================================================

func geobanFetchCommand(c *cli.Context) error {
    // Get country code
    cc := c.Args().First()
    if cc == "" {
        return fmt.Errorf("country code required")
    }

    // Validate country code
    if len(cc) != 2 {
        return fmt.Errorf("invalid country code: %s", cc)
    }
    cc = strings.ToUpper(cc)

    action := c.String("action")  // "ban" or "whitelist"
    atomic := c.Bool("atomic")

    fmt.Printf("⏳ Fetching IP ranges for country: %s\n", cc)

    // Fetch country IP ranges from source
    ipv4Ranges, ipv6Ranges, err := fetchCountryIPRanges(cc)
    if err != nil {
        return fmt.Errorf("failed to fetch IP ranges: %w", err)
    }

    fmt.Printf("✓ Fetched %d IPv4 ranges, %d IPv6 ranges\n", len(ipv4Ranges), len(ipv6Ranges))

    // Merge overlapping CIDRs
    fmt.Println("⏳ Merging overlapping CIDRs...")
    ipv4Merged := mergeCIDRs(ipv4Ranges)
    ipv6Merged := mergeCIDRs(ipv6Ranges)
    fmt.Printf("✓ Merged to %d IPv4 ranges, %d IPv6 ranges\n", len(ipv4Merged), len(ipv6Merged))

    // Save to file
    var filePath string
    if action == "ban" {
        filePath = fmt.Sprintf("/etc/nftban/geoban.d/50-ban-%s.conf", cc)
    } else {
        filePath = fmt.Sprintf("/etc/nftban/geoban.d/40-whitelist-%s.conf", cc)
    }

    err = saveCountryIPFile(filePath, cc, action, ipv4Merged, ipv6Merged)
    if err != nil {
        return fmt.Errorf("failed to save file: %w", err)
    }
    fmt.Printf("✓ Saved to: %s\n", filePath)

    // Load to nftables (atomic)
    if atomic {
        fmt.Println("⏳ Loading to nftables (atomic)...")
        err = loadToNftablesAtomic(action, cc, ipv4Merged, ipv6Merged)
        if err != nil {
            return fmt.Errorf("failed to load to nftables: %w", err)
        }
        fmt.Println("✓ Loaded atomically to nftables")
    }

    return nil
}

func geobanRemoveCommand(c *cli.Context) error {
    // Get country code
    cc := c.Args().First()
    if cc == "" {
        return fmt.Errorf("country code required")
    }
    cc = strings.ToUpper(cc)

    action := c.String("action")  // "ban" or "whitelist"
    atomic := c.Bool("atomic")

    fmt.Printf("⏳ Removing country %s from %s\n", cc, action)

    // Read tracking file to know which IPs to remove
    var filePath string
    if action == "ban" {
        filePath = fmt.Sprintf("/etc/nftban/geoban.d/50-ban-%s.conf", cc)
    } else {
        filePath = fmt.Sprintf("/etc/nftban/geoban.d/40-whitelist-%s.conf", cc)
    }

    ipv4Ranges, ipv6Ranges, err := readCountryIPFile(filePath)
    if err != nil {
        return fmt.Errorf("failed to read file: %w", err)
    }

    // Remove from nftables (atomic)
    if atomic {
        fmt.Println("⏳ Removing from nftables (atomic)...")
        err = removeFromNftablesAtomic(action, cc, ipv4Ranges, ipv6Ranges)
        if err != nil {
            return fmt.Errorf("failed to remove from nftables: %w", err)
        }
        fmt.Println("✓ Removed atomically from nftables")
    }

    return nil
}

// =============================================================================
// IP RANGE FETCHING
// =============================================================================

func fetchCountryIPRanges(cc string) ([]string, []string, error) {
    // Fetch from IPdeny.com (free, no API key needed)
    // Alternative: IP2Location, DB-IP

    ipv4URL := fmt.Sprintf("https://www.ipdeny.com/ipblocks/data/aggregated/%s-aggregated.zone", strings.ToLower(cc))
    ipv6URL := fmt.Sprintf("https://www.ipdeny.com/ipv6/ipaddresses/aggregated/%s-aggregated.zone", strings.ToLower(cc))

    // Download IPv4 ranges
    ipv4Ranges, err := downloadIPRanges(ipv4URL)
    if err != nil {
        return nil, nil, fmt.Errorf("failed to download IPv4: %w", err)
    }

    // Download IPv6 ranges
    ipv6Ranges, err := downloadIPRanges(ipv6URL)
    if err != nil {
        // IPv6 might not be available for all countries, that's OK
        ipv6Ranges = []string{}
    }

    return ipv4Ranges, ipv6Ranges, nil
}

func downloadIPRanges(url string) ([]string, error) {
    client := &http.Client{Timeout: 30 * time.Second}

    resp, err := client.Get(url)
    if err != nil {
        return nil, err
    }
    defer resp.Body.Close()

    if resp.StatusCode != 200 {
        return nil, fmt.Errorf("HTTP %d: %s", resp.StatusCode, resp.Status)
    }

    var ranges []string
    scanner := bufio.NewScanner(resp.Body)
    for scanner.Scan() {
        line := strings.TrimSpace(scanner.Text())
        if line == "" || strings.HasPrefix(line, "#") {
            continue
        }

        // Validate CIDR format
        _, _, err := net.ParseCIDR(line)
        if err == nil {
            ranges = append(ranges, line)
        }
    }

    return ranges, scanner.Err()
}

// =============================================================================
// CIDR MERGING (Reuse from go-feeds)
// =============================================================================

func mergeCIDRs(cidrs []string) []string {
    // Use existing CIDR merge logic from go-feeds/internal/parser/cidr_merge.go
    // This reduces overlapping ranges to minimal set

    // Parse all CIDRs
    var networks []*net.IPNet
    for _, cidr := range cidrs {
        _, ipnet, err := net.ParseCIDR(cidr)
        if err == nil {
            networks = append(networks, ipnet)
        }
    }

    // Merge (implementation from existing code)
    merged := mergeIPNets(networks)

    // Convert back to strings
    var result []string
    for _, ipnet := range merged {
        result = append(result, ipnet.String())
    }

    return result
}

// =============================================================================
// ATOMIC NFTABLES LOADING
// =============================================================================

func loadToNftablesAtomic(action string, cc string, ipv4Ranges []string, ipv6Ranges []string) error {
    // Determine target set
    var setV4, setV6 string
    if action == "ban" {
        setV4 = "inet nftban_main blacklist_v4"
        setV6 = "inet nftban_main blacklist_v6"
    } else {
        setV4 = "inet nftban_main whitelist_v4"
        setV6 = "inet nftban_main whitelist_v6"
    }

    // Load IPv4 ranges atomically
    if len(ipv4Ranges) > 0 {
        // Build comma-separated list
        elements := strings.Join(ipv4Ranges, ", ")

        // Single atomic nft command
        cmd := exec.Command("nft", "add", "element", setV4, fmt.Sprintf("{ %s }", elements))
        output, err := cmd.CombinedOutput()
        if err != nil {
            return fmt.Errorf("nft add element failed: %w\n%s", err, output)
        }
    }

    // Load IPv6 ranges atomically
    if len(ipv6Ranges) > 0 {
        elements := strings.Join(ipv6Ranges, ", ")
        cmd := exec.Command("nft", "add", "element", setV6, fmt.Sprintf("{ %s }", elements))
        output, err := cmd.CombinedOutput()
        if err != nil {
            return fmt.Errorf("nft add element failed: %w\n%s", err, output)
        }
    }

    // Save tracking for next update
    saveTrackingFile(action, cc, ipv4Ranges, ipv6Ranges)

    return nil
}

func removeFromNftablesAtomic(action string, cc string, ipv4Ranges []string, ipv6Ranges []string) error {
    // Determine target set
    var setV4, setV6 string
    if action == "ban" {
        setV4 = "inet nftban_main blacklist_v4"
        setV6 = "inet nftban_main blacklist_v6"
    } else {
        setV4 = "inet nftban_main whitelist_v4"
        setV6 = "inet nftban_main whitelist_v6"
    }

    // Remove IPv4 ranges atomically
    if len(ipv4Ranges) > 0 {
        elements := strings.Join(ipv4Ranges, ", ")
        cmd := exec.Command("nft", "delete", "element", setV4, fmt.Sprintf("{ %s }", elements))
        output, err := cmd.CombinedOutput()
        if err != nil {
            // Continue even if some elements fail (might not exist)
            log.Printf("Warning: nft delete element partial failure: %s", output)
        }
    }

    // Remove IPv6 ranges atomically
    if len(ipv6Ranges) > 0 {
        elements := strings.Join(ipv6Ranges, ", ")
        cmd := exec.Command("nft", "delete", "element", setV6, fmt.Sprintf("{ %s }", elements))
        output, err := cmd.CombinedOutput()
        if err != nil {
            log.Printf("Warning: nft delete element partial failure: %s", output)
        }
    }

    // Remove tracking file
    removeTrackingFile(action, cc)

    return nil
}

// =============================================================================
// FILE I/O
// =============================================================================

func saveCountryIPFile(filePath string, cc string, action string, ipv4 []string, ipv6 []string) error {
    f, err := os.Create(filePath)
    if err != nil {
        return err
    }
    defer f.Close()

    w := bufio.NewWriter(f)

    // Write header
    fmt.Fprintf(w, "# =============================================================================\n")
    fmt.Fprintf(w, "# NFTBan GeoBan - %s (%s) - %s\n", getCountryName(cc), cc, strings.ToUpper(action))
    fmt.Fprintf(w, "# =============================================================================\n")
    fmt.Fprintf(w, "# This file is automatically managed by nftban geoip module\n")
    fmt.Fprintf(w, "# Generated: %s\n", time.Now().Format(time.RFC3339))
    fmt.Fprintf(w, "#\n")
    fmt.Fprintf(w, "# DO NOT EDIT MANUALLY - Changes will be overwritten on update\n")
    fmt.Fprintf(w, "#\n")
    fmt.Fprintf(w, "# Country: %s (%s)\n", getCountryName(cc), cc)
    fmt.Fprintf(w, "# Action: %s\n", strings.ToUpper(action))
    fmt.Fprintf(w, "# Total IPv4 ranges: %d\n", len(ipv4))
    fmt.Fprintf(w, "# Total IPv6 ranges: %d\n", len(ipv6))
    fmt.Fprintf(w, "# Source: ipdeny.com\n")
    fmt.Fprintf(w, "# =============================================================================\n\n")

    // Write IPv4 ranges
    if len(ipv4) > 0 {
        fmt.Fprintf(w, "# IPv4 Ranges\n")
        for _, ip := range ipv4 {
            fmt.Fprintf(w, "%s\n", ip)
        }
        fmt.Fprintf(w, "\n")
    }

    // Write IPv6 ranges
    if len(ipv6) > 0 {
        fmt.Fprintf(w, "# IPv6 Ranges\n")
        for _, ip := range ipv6 {
            fmt.Fprintf(w, "%s\n", ip)
        }
    }

    w.Flush()

    // Set permissions
    os.Chmod(filePath, 0640)

    return nil
}

func saveTrackingFile(action string, cc string, ipv4 []string, ipv6 []string) error {
    // Save current IPs for next update (to know what to remove)
    trackingFile := fmt.Sprintf("/var/lib/nftban/geoban/tracking/%s-%s.json", action, cc)

    data := map[string]interface{}{
        "country":   cc,
        "action":    action,
        "timestamp": time.Now().Unix(),
        "ipv4":      ipv4,
        "ipv6":      ipv6,
    }

    jsonData, err := json.MarshalIndent(data, "", "  ")
    if err != nil {
        return err
    }

    return os.WriteFile(trackingFile, jsonData, 0640)
}
```

---

## 📊 DATA SOURCES

### IP Range Sources for Countries

#### 1. IPdeny.com (Recommended - FREE)
**URL:** https://www.ipdeny.com/ipblocks/data/aggregated/

**Pros:**
- ✓ Free, no API key required
- ✓ Aggregated (pre-merged) CIDR blocks
- ✓ Updated daily
- ✓ All countries available
- ✓ IPv4 and IPv6 support

**Format:**
```
https://www.ipdeny.com/ipblocks/data/aggregated/cn-aggregated.zone
https://www.ipdeny.com/ipv6/ipaddresses/aggregated/cn-aggregated.zone
```

**Example:**
```bash
# China IPv4 ranges
curl https://www.ipdeny.com/ipblocks/data/aggregated/cn-aggregated.zone
# Output:
1.0.1.0/24
1.0.2.0/23
1.0.8.0/21
...
```

#### 2. IP2Location (Fallback - FREE with limits)
**URL:** https://www.ip2location.com/free/visitor-blocker

**Pros:**
- ✓ Free tier available
- ✓ Country-level blocking
- ✓ Regular updates

**Cons:**
- ⚠ Requires account (free)
- ⚠ Rate limits

#### 3. DB-IP (Alternative - FREE)
**URL:** https://db-ip.com/db/download/ip-to-country-lite

**Pros:**
- ✓ Free database
- ✓ Monthly updates
- ✓ CSV format

**Cons:**
- ⚠ Requires parsing (not direct CIDR lists)

---

## 🚀 IMPLEMENTATION PHASES

### Phase 1: Basic GeoBan (v0.31.0)
**Timeline:** Now
**Features:**
- ✓ CLI commands: `nftban geoip ban/unban/whitelist`
- ✓ Go binary extensions for IP range fetching
- ✓ Atomic nftables loading
- ✓ Configuration persistence
- ✓ File-based storage in `/etc/nftban/geoban.d/`

**Deliverables:**
1. `/usr/lib/nftban/core/nftban_geoban.sh` (bash wrapper)
2. Extended Go binary with GeoBan commands
3. `/etc/nftban/conf.d/geoban.conf` (configuration)
4. CLI commands in `cmd_geoip.sh`
5. Bash completion updates

### Phase 2: Auto-Update (v0.32.0)
**Timeline:** Future
**Features:**
- ✓ Automatic IP range updates (weekly/monthly)
- ✓ Systemd timer for updates
- ✓ Email notifications on changes
- ✓ Update logs

### Phase 3: Advanced Features (v0.33.0)
**Timeline:** Future
**Features:**
- ✓ Country groups (e.g., "asia", "middle-east")
- ✓ Whitelist exceptions within banned countries
- ✓ Statistics and reporting
- ✓ Web dashboard integration

---

## ⚡ PERFORMANCE ESTIMATES

### IP Range Sizes (Typical)

| Country | IPv4 Ranges | IPv6 Ranges | Total IPs (approx) |
|---------|-------------|-------------|--------------------|
| China (CN) | ~8,400 | ~3,500 | 330 million |
| USA (US) | ~15,000 | ~12,000 | 1.5 billion |
| Russia (RU) | ~7,200 | ~2,800 | 180 million |
| Iran (IR) | ~2,100 | ~800 | 32 million |
| Germany (DE) | ~5,800 | ~4,200 | 115 million |

### Loading Times (Estimated)

**Atomic Loading:**
- Fetch + parse: ~2-5 seconds per country
- CIDR merge: ~0.5-1 second
- nftables atomic load: ~0.1-0.5 seconds
- **Total: ~3-7 seconds per country**

**Batch Operations:**
- Ban 5 countries: ~15-35 seconds
- Update existing: ~5-10 seconds (only changed ranges)

**Memory Usage:**
- Go binary: ~50 MB
- nftables sets: ~10-50 MB (depending on countries)
- **Total: ~60-100 MB additional**

---

## 🔐 SECURITY CONSIDERATIONS

### 1. Atomic Operations
- ✓ No gap in firewall protection
- ✓ All-or-nothing loading (transaction-like)
- ✓ Rollback on failure

### 2. Configuration Security
- ✓ Files owned by root:nftban
- ✓ Permissions: 640 (rw-r-----)
- ✓ .local configs preserved during updates

### 3. IP Range Validation
- ✓ Validate all CIDRs before loading
- ✓ Reject invalid/malformed data
- ✓ Checksum verification (optional)

### 4. Rate Limiting
- ✓ Cache IP ranges locally
- ✓ TTL: 7 days (configurable)
- ✓ Avoid excessive downloads

### 5. Whitelist Priority
- ✓ Whitelist always takes precedence over blacklist
- ✓ Priority: 40 (whitelist) < 50 (ban)
- ✓ Explicit whitelist for safety (e.g., own country)

---

## 📝 CONFIGURATION EXAMPLES

### Example 1: Ban China and Iran
```bash
# Ban countries
nftban geoip ban CN IR

# Result:
# - Creates /etc/nftban/geoban.d/50-ban-CN.conf
# - Creates /etc/nftban/geoban.d/50-ban-IR.conf
# - Adds ~10,500 IPv4 ranges to blacklist_v4
# - Adds ~4,300 IPv6 ranges to blacklist_v6
# - Saves to /etc/nftban/conf.d/geoban.conf.local
```

### Example 2: Whitelist USA (allow even if banned)
```bash
# Whitelist USA (safety measure)
nftban geoip whitelist US

# Result:
# - Creates /etc/nftban/geoban.d/40-whitelist-US.conf
# - Adds ~15,000 IPv4 ranges to whitelist_v4
# - Takes precedence over any bans
```

### Example 3: Block entire continent except own country
```bash
# Ban multiple Asian countries
nftban geoip ban CN RU IN ID JP KR

# Whitelist own country (Greece)
nftban geoip whitelist GR

# Result: All listed countries banned except Greece
```

### Example 4: Remove all bans
```bash
# List current bans
nftban geoip list

# Unban all
nftban geoip unban CN IR RU

# Or disable GeoBan entirely
echo 'GEOBAN_ENABLED="false"' >> /etc/nftban/conf.d/geoban.conf.local
nftban firewall reload
```

---

## 🧪 TESTING CHECKLIST

### Unit Tests (Go)
- [ ] IP range fetching from IPdeny.com
- [ ] CIDR parsing and validation
- [ ] CIDR merging logic
- [ ] File I/O operations
- [ ] nftables command generation

### Integration Tests (Bash)
- [ ] Ban country command
- [ ] Unban country command
- [ ] Whitelist country command
- [ ] List command output
- [ ] Config file creation/update
- [ ] nftables sets populated correctly

### End-to-End Tests
- [ ] Ban CN → verify China IPs blocked
- [ ] Whitelist US → verify USA IPs allowed
- [ ] Unban CN → verify China IPs allowed again
- [ ] Reboot persistence test
- [ ] Update test (IP ranges change)

### Performance Tests
- [ ] Fetch 1 country: < 5 seconds
- [ ] Fetch 5 countries: < 30 seconds
- [ ] Atomic loading: < 1 second
- [ ] Memory usage: < 100 MB

### Security Tests
- [ ] Invalid country code handling
- [ ] Malformed CIDR rejection
- [ ] File permission verification
- [ ] Atomic operation rollback
- [ ] Whitelist priority enforcement

---

## 📋 DEPLOYMENT PLAN

### Step 1: Prepare Infrastructure
```bash
# Create directories
mkdir -p /etc/nftban/geoban.d
mkdir -p /var/lib/nftban/geoban/cache
mkdir -p /var/lib/nftban/geoban/tracking

# Set permissions
chown -R root:nftban /etc/nftban/geoban.d
chown -R root:nftban /var/lib/nftban/geoban
chmod 750 /etc/nftban/geoban.d
chmod 750 /var/lib/nftban/geoban
```

### Step 2: Deploy Go Binary
```bash
# Compile Go binary with GeoBan features
cd /tmp/GO_FEED_INTEGRATION/go-feeds
go build -o nftban-geoip cmd/nftban-geoip/main.go

# Deploy binary
cp nftban-geoip /usr/lib/nftban/bin/nftban-geoip
chmod 755 /usr/lib/nftban/bin/nftban-geoip
```

### Step 3: Deploy Bash Modules
```bash
# Deploy GeoBan core module
cp /tmp/GEOBAN_IMPLEMENTATION/nftban_geoban.sh /usr/lib/nftban/core/
chmod 644 /usr/lib/nftban/core/nftban_geoban.sh

# Update CLI module
# Add GeoBan commands to cmd_geoip.sh
```

### Step 4: Deploy Configuration
```bash
# Create default config
cp /tmp/GEOBAN_IMPLEMENTATION/geoban.conf /etc/nftban/conf.d/
chmod 640 /etc/nftban/conf.d/geoban.conf
chown root:nftban /etc/nftban/conf.d/geoban.conf
```

### Step 5: Update Bash Completion
```bash
# Add GeoBan commands to completion
# Update /usr/share/bash-completion/completions/nftban
```

### Step 6: Test
```bash
# Test GeoBan
nftban geoip ban CN
nftban geoip list
nftban geoip unban CN
```

---

## 🔄 UPDATE MECHANISM

### Automatic Updates (Future)

**Systemd Timer:** `/etc/systemd/system/nftban-geoban-update.timer`
```ini
[Unit]
Description=NFTBan GeoBan IP Range Update Timer

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
```

**Systemd Service:** `/etc/systemd/system/nftban-geoban-update.service`
```ini
[Unit]
Description=NFTBan GeoBan IP Range Update
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/nftban geoip update-all
User=root
```

**Update Process:**
1. Fetch new IP ranges from source
2. Compare with cached ranges
3. Calculate diff (added/removed ranges)
4. Atomically remove old ranges
5. Atomically add new ranges
6. Log changes
7. Send email notification (optional)

---

## 💡 DISCUSSION POINTS

### 1. IP Range Source
**Q:** Use IPdeny.com or IP2Location?
**A:** Recommend IPdeny.com (free, no API key, daily updates)

### 2. nftables Sets
**Q:** Reuse existing blacklist/whitelist sets or create dedicated geoban sets?
**A:** Recommend reuse (simpler, consistent with current architecture)

### 3. Country Code Format
**Q:** ISO 3166-1 alpha-2 (CN) or alpha-3 (CHN)?
**A:** Recommend alpha-2 (shorter, more common)

### 4. File Location
**Q:** `/etc/nftban/geoban.d/` or `/etc/nftban/blacklist.d/50-geo-*.conf`?
**A:** Recommend separate `geoban.d/` directory (cleaner separation)

### 5. Cache TTL
**Q:** How often to update country IP ranges?
**A:** Recommend weekly (IP allocations change slowly)

### 6. Large Country Handling
**Q:** Some countries have 15,000+ ranges. Performance concern?
**A:** nftables handles this well. Atomic loading ~0.5s. Not a problem.

### 7. Whitelist Priority
**Q:** What if a country is in both banned and whitelisted list?
**A:** Whitelist always wins (safety first). Use priority: 40 < 50.

### 8. Update Strategy
**Q:** Replace all IPs or calculate diff?
**A:** Calculate diff for atomic updates (remove old, add new). More efficient.

---

## ✅ READY FOR IMPLEMENTATION

**Status:** 🎯 HLD Complete
**Next Steps:**
1. Review and approve HLD
2. Implement Go binary extensions
3. Create bash wrapper module
4. Write integration tests
5. Deploy to lab server for testing
6. Release as v0.31.0

**Credits Available:** 144,467 tokens (72%)
**Estimated Implementation Time:** 4-6 hours
**Complexity:** Medium (reuses existing patterns)

---

**End of GeoBan HLD**
