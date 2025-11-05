#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.31.0 - GeoIP CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: CLI interface for GO GeoIP lookups
#
# meta:name=cmd_geoip
# meta:type=cli
# meta:header=GeoIP CLI Handler
# meta:version=0.31.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# meta:created_date=2025-11-05
# =============================================================================

# Enhanced strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_CLI_GEOIP_LOADED:-}" ]] && return 0
readonly NFTBAN_CLI_GEOIP_LOADED=1

# =============================================================================
# MAIN CLI HANDLER
# =============================================================================

nftban_cmd_geoip() {
    # Main GeoIP command handler
    # Args: subcommand [options]

    local subcommand="${1:-}"

    if [[ -z "$subcommand" ]]; then
        nftban_geoip_cmd_help
        return 1
    fi

    # Shift to get remaining args
    shift

    case "$subcommand" in
        lookup)
            nftban_geoip_cmd_lookup "$@"
            ;;
        bulk)
            nftban_geoip_cmd_bulk "$@"
            ;;
        status)
            nftban_geoip_cmd_status "$@"
            ;;
        test)
            nftban_geoip_cmd_test "$@"
            ;;
        update)
            nftban_geoip_cmd_update "$@"
            ;;
        ban)
            nftban_geoip_cmd_ban "$@"
            ;;
        unban)
            nftban_geoip_cmd_unban "$@"
            ;;
        whitelist)
            nftban_geoip_cmd_whitelist "$@"
            ;;
        unwhitelist)
            nftban_geoip_cmd_unwhitelist "$@"
            ;;
        list)
            nftban_geoip_cmd_list "$@"
            ;;
        refresh)
            nftban_geoip_cmd_refresh "$@"
            ;;
        config)
            nftban_geoip_cmd_config "$@"
            ;;
        help|--help|-h)
            nftban_geoip_cmd_help
            ;;
        *)
            echo "ERROR: Unknown geoip command: $subcommand" >&2
            echo "Run 'nftban geoip help' for usage information" >&2
            return 1
            ;;
    esac
}

# =============================================================================
# SUBCOMMAND IMPLEMENTATIONS
# =============================================================================

nftban_geoip_cmd_lookup() {
    # Lookup single IP address
    # Args: $1 = IP address, $2 = format (optional: json|compact|country)

    local ip="${1:-}"
    local format="${2:-json}"

    if [[ -z "$ip" ]]; then
        echo "ERROR: IP address required" >&2
        echo "Usage: nftban geoip lookup <IP> [json|compact|country]" >&2
        return 1
    fi

    # Load GeoIP wrapper if not already loaded
    if ! declare -f nftban_geoip_lookup_fast >/dev/null 2>&1; then
        source /usr/lib/nftban/core/nftban_geoip_go.sh || {
            echo "ERROR: Failed to load GeoIP module" >&2
            return 1
        }
    fi

    # Check if GeoIP system is available
    if ! nftban_geoip_check_available; then
        echo "ERROR: GeoIP system not available" >&2
        echo "  Binary: /usr/lib/nftban/bin/nftban-geoip" >&2
        echo "  Database: /var/lib/nftban/geoip/GeoLite2-City.mmdb" >&2
        echo "" >&2
        echo "Run 'nftban geoip status' for details" >&2
        return 1
    fi

    case "$format" in
        json)
            # Full JSON output
            nftban_geoip_lookup_fast "$ip"
            ;;
        compact)
            # Compact format: CC/City/Timezone
            nftban_geoip_get_compact_full "$ip"
            ;;
        country)
            # Country only
            nftban_geoip_get_country "$ip"
            ;;
        *)
            echo "ERROR: Invalid format: $format" >&2
            echo "Valid formats: json, compact, country" >&2
            return 1
            ;;
    esac
}

nftban_geoip_cmd_bulk() {
    # Bulk IP lookup from file or stdin
    # Args: $1 = input file (optional, uses stdin if not provided)

    local input_file="${1:-}"

    # Load GeoIP wrapper
    if ! declare -f nftban_geoip_bulk_lookup >/dev/null 2>&1; then
        source /usr/lib/nftban/core/nftban_geoip_go.sh || {
            echo "ERROR: Failed to load GeoIP module" >&2
            return 1
        }
    fi

    # Check availability
    if ! nftban_geoip_check_available; then
        echo "ERROR: GeoIP system not available" >&2
        return 1
    fi

    if [[ -n "$input_file" ]]; then
        # Read from file
        if [[ ! -f "$input_file" ]]; then
            echo "ERROR: File not found: $input_file" >&2
            return 1
        fi
        nftban_geoip_bulk_lookup "$input_file"
    else
        # Read from stdin
        nftban_geoip_bulk_lookup
    fi
}

nftban_geoip_cmd_status() {
    # Show GeoIP system status
    # No args

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  GeoIP System Status"
    echo "═══════════════════════════════════════════════════════════"
    echo ""

    # Check binary
    local binary_path="/usr/lib/nftban/bin/nftban-geoip"
    if [[ -x "$binary_path" ]]; then
        local version
        version=$("$binary_path" version 2>/dev/null || echo "unknown")
        echo "✓ Binary:   FOUND"
        echo "  Path:     $binary_path"
        echo "  Version:  $version"
    else
        echo "✗ Binary:   NOT FOUND"
        echo "  Path:     $binary_path"
        echo "  Status:   Missing or not executable"
    fi
    echo ""

    # Check database
    local db_path="/var/lib/nftban/geoip/GeoLite2-City.mmdb"
    if [[ -f "$db_path" ]]; then
        local db_size
        db_size=$(du -h "$db_path" | cut -f1)
        local db_date
        db_date=$(stat -c %y "$db_path" 2>/dev/null | cut -d' ' -f1)
        echo "✓ Database: FOUND"
        echo "  Path:     $db_path"
        echo "  Size:     $db_size"
        echo "  Modified: $db_date"
    else
        echo "✗ Database: NOT FOUND"
        echo "  Path:     $db_path"
        echo "  Status:   Missing"
    fi
    echo ""

    # Test lookup if both available
    if [[ -x "$binary_path" && -f "$db_path" ]]; then
        echo "Testing lookup performance..."
        local test_result
        test_result=$("$binary_path" status 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$test_result" | grep -E '(status|database|version|db_type|db_build)' | sed 's/^/  /'
            echo ""

            # Quick performance test
            echo "Quick performance test (8.8.8.8)..."
            local start_time end_time elapsed
            start_time=$(date +%s%N)
            "$binary_path" lookup 8.8.8.8 >/dev/null 2>&1
            end_time=$(date +%s%N)
            elapsed=$(( (end_time - start_time) / 1000 ))
            echo "  Lookup time: ${elapsed} microseconds"

            if (( elapsed < 1000 )); then
                echo "  Performance: ✓ EXCELLENT (<1ms)"
            elif (( elapsed < 5000 )); then
                echo "  Performance: ✓ GOOD (<5ms)"
            else
                echo "  Performance: ⚠ SLOW (>5ms)"
            fi
        else
            echo "⚠ Database test failed"
        fi
    else
        echo "⚠ Cannot test - binary or database missing"
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo ""
}

nftban_geoip_cmd_test() {
    # Run built-in tests
    # No args

    local binary_path="/usr/lib/nftban/bin/nftban-geoip"

    if [[ ! -x "$binary_path" ]]; then
        echo "ERROR: GeoIP binary not found: $binary_path" >&2
        return 1
    fi

    echo "Running GeoIP system tests..."
    echo ""

    # Run GO binary tests
    "$binary_path" test
    local result=$?

    echo ""
    if [[ $result -eq 0 ]]; then
        echo "✓ All tests PASSED!"
    else
        echo "✗ Some tests FAILED"
    fi

    return $result
}

nftban_geoip_cmd_update() {
    # Update GeoLite2 database
    # No args

    echo "Updating GeoLite2 database..."
    echo ""

    local db_dir="/var/lib/nftban/geoip"
    local db_file="$db_dir/GeoLite2-City.mmdb"
    local db_backup="$db_dir/GeoLite2-City.mmdb.backup"
    local db_url="https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-City.mmdb"

    # Check if directory exists
    if [[ ! -d "$db_dir" ]]; then
        echo "Creating directory: $db_dir"
        mkdir -p "$db_dir" || {
            echo "ERROR: Failed to create directory" >&2
            return 1
        }
    fi

    # Backup existing database
    if [[ -f "$db_file" ]]; then
        echo "Backing up existing database..."
        cp "$db_file" "$db_backup" || {
            echo "ERROR: Failed to create backup" >&2
            return 1
        }
        echo "  Backup: $db_backup"
    fi

    # Download new database
    echo "Downloading GeoLite2-City.mmdb..."
    echo "  Source: $db_url"
    echo ""

    if command -v wget >/dev/null 2>&1; then
        wget -O "$db_file" "$db_url" || {
            echo "ERROR: Download failed" >&2
            # Restore backup if exists
            if [[ -f "$db_backup" ]]; then
                echo "Restoring backup..."
                mv "$db_backup" "$db_file"
            fi
            return 1
        }
    elif command -v curl >/dev/null 2>&1; then
        curl -L -o "$db_file" "$db_url" || {
            echo "ERROR: Download failed" >&2
            # Restore backup if exists
            if [[ -f "$db_backup" ]]; then
                echo "Restoring backup..."
                mv "$db_backup" "$db_file"
            fi
            return 1
        }
    else
        echo "ERROR: Neither wget nor curl found" >&2
        echo "Please install wget or curl to update database" >&2
        return 1
    fi

    # Set permissions
    chmod 644 "$db_file" 2>/dev/null || true

    # Verify new database
    local binary_path="/usr/lib/nftban/bin/nftban-geoip"
    if [[ -x "$binary_path" ]]; then
        echo ""
        echo "Verifying new database..."
        if "$binary_path" status >/dev/null 2>&1; then
            echo "✓ Database verified successfully"

            # Show database info
            local db_size
            db_size=$(du -h "$db_file" | cut -f1)
            echo "  Size: $db_size"
            echo "  Path: $db_file"

            # Remove backup
            rm -f "$db_backup"
        else
            echo "ERROR: New database verification failed" >&2
            echo "Restoring backup..." >&2
            mv "$db_backup" "$db_file"
            return 1
        fi
    fi

    echo ""
    echo "✓ GeoLite2 database updated successfully!"
    echo ""
}

nftban_geoip_cmd_ban() {
    # Ban countries (block all traffic from country)
    # Args: $@ = country codes (e.g., CN RU KP)

    # Load GeoBan module
    if ! declare -f nftban_geoban_ban_countries >/dev/null 2>&1; then
        source /usr/lib/nftban/core/nftban_geoban.sh || {
            echo "ERROR: Failed to load GeoBan module" >&2
            return 1
        }
    fi

    if [[ $# -eq 0 ]]; then
        echo "ERROR: At least one country code required" >&2
        echo "Usage: nftban geoip ban <CC> [CC...]" >&2
        echo "Example: nftban geoip ban CN RU KP" >&2
        return 1
    fi

    nftban_geoban_ban_countries "$@"
}

nftban_geoip_cmd_unban() {
    # Remove country bans
    # Args: $@ = country codes

    # Load GeoBan module
    if ! declare -f nftban_geoban_unban_countries >/dev/null 2>&1; then
        source /usr/lib/nftban/core/nftban_geoban.sh || {
            echo "ERROR: Failed to load GeoBan module" >&2
            return 1
        }
    fi

    if [[ $# -eq 0 ]]; then
        echo "ERROR: At least one country code required" >&2
        echo "Usage: nftban geoip unban <CC> [CC...]" >&2
        echo "Example: nftban geoip unban CN RU" >&2
        return 1
    fi

    nftban_geoban_unban_countries "$@"
}

nftban_geoip_cmd_whitelist() {
    # Whitelist countries (allow even if banned)
    # Args: $@ = country codes

    # Load GeoBan module
    if ! declare -f nftban_geoban_whitelist_countries >/dev/null 2>&1; then
        source /usr/lib/nftban/core/nftban_geoban.sh || {
            echo "ERROR: Failed to load GeoBan module" >&2
            return 1
        }
    fi

    if [[ $# -eq 0 ]]; then
        echo "ERROR: At least one country code required" >&2
        echo "Usage: nftban geoip whitelist <CC> [CC...]" >&2
        echo "Example: nftban geoip whitelist US GB DE" >&2
        return 1
    fi

    nftban_geoban_whitelist_countries "$@"
}

nftban_geoip_cmd_unwhitelist() {
    # Remove country whitelists
    # Args: $@ = country codes

    # Load GeoBan module
    if ! declare -f nftban_geoban_unwhitelist_countries >/dev/null 2>&1; then
        source /usr/lib/nftban/core/nftban_geoban.sh || {
            echo "ERROR: Failed to load GeoBan module" >&2
            return 1
        }
    fi

    if [[ $# -eq 0 ]]; then
        echo "ERROR: At least one country code required" >&2
        echo "Usage: nftban geoip unwhitelist <CC> [CC...]" >&2
        return 1
    fi

    nftban_geoban_unwhitelist_countries "$@"
}

nftban_geoip_cmd_list() {
    # List all active GeoBan countries
    # No args

    # Load GeoBan module
    if ! declare -f nftban_geoban_list >/dev/null 2>&1; then
        source /usr/lib/nftban/core/nftban_geoban.sh || {
            echo "ERROR: Failed to load GeoBan module" >&2
            return 1
        }
    fi

    nftban_geoban_list
}

nftban_geoip_cmd_refresh() {
    # Refresh all active GeoBan countries (re-download IPs)
    # No args

    # Load GeoBan module
    if ! declare -f nftban_geoban_update >/dev/null 2>&1; then
        source /usr/lib/nftban/core/nftban_geoban.sh || {
            echo "ERROR: Failed to load GeoBan module" >&2
            return 1
        }
    fi

    nftban_geoban_update
}

nftban_geoip_cmd_config() {
    # Configure GeoIP database source and settings
    # Subcommands: show, set-source, set-key, test-download

    local config_cmd="${1:-show}"
    shift 2>/dev/null || true

    case "$config_cmd" in
        show)
            echo ""
            echo "═══════════════════════════════════════════════════════════"
            echo "  GeoIP Configuration"
            echo "═══════════════════════════════════════════════════════════"
            echo ""

            # Load config
            local config_file="/etc/nftban/conf.d/nftban-go.conf"
            if [[ -f "$config_file" ]]; then
                source "$config_file"
            fi

            echo "Database Source:"
            echo "  Current: ${GEOIP_DB_SOURCE:-github}"
            echo ""

            if [[ "${GEOIP_DB_SOURCE:-github}" == "maxmind" ]]; then
                echo "MaxMind Settings:"
                if [[ -n "${GEOIP_MAXMIND_LICENSE_KEY:-}" ]]; then
                    echo "  License Key: ••••••••${GEOIP_MAXMIND_LICENSE_KEY: -4}"
                else
                    echo "  License Key: NOT SET"
                    echo "  ⚠ MaxMind source requires a license key!"
                fi
                echo "  Account ID:  ${GEOIP_MAXMIND_ACCOUNT_ID:-NOT SET}"
                echo ""
                echo "To get a FREE MaxMind license key:"
                echo "  1. Sign up: https://www.maxmind.com/en/geolite2/signup"
                echo "  2. Generate license key in account dashboard"
                echo "  3. Set key: nftban geoip config set-key YOUR_KEY"
            else
                echo "GitHub Mirror Settings:"
                echo "  URL: https://github.com/P3TERX/GeoLite.mmdb"
                echo "  License: NO KEY REQUIRED"
                echo "  Updates: Community-maintained"
                echo ""
                echo "This is a FREE mirror of MaxMind GeoLite2 database."
                echo "No account or license key needed!"
            fi

            echo ""
            echo "Database Location:"
            echo "  Path: /var/lib/nftban/geoip/GeoLite2-City.mmdb"
            if [[ -f "/var/lib/nftban/geoip/GeoLite2-City.mmdb" ]]; then
                local db_size db_date
                db_size=$(du -h /var/lib/nftban/geoip/GeoLite2-City.mmdb | cut -f1)
                db_date=$(stat -c %y /var/lib/nftban/geoip/GeoLite2-City.mmdb | cut -d' ' -f1)
                echo "  Size: $db_size"
                echo "  Date: $db_date"
            else
                echo "  Status: NOT FOUND"
                echo "  Run: nftban geoip update"
            fi

            echo ""
            echo "═══════════════════════════════════════════════════════════"
            echo ""
            ;;

        set-source)
            local source="${1:-}"
            if [[ "$source" != "github" && "$source" != "maxmind" ]]; then
                echo "ERROR: Invalid source: $source" >&2
                echo "Valid sources: github, maxmind" >&2
                return 1
            fi

            local config_local="/etc/nftban/conf.d/nftban-go.conf.local"

            # Ensure directory exists
            mkdir -p "$(dirname "$config_local")"

            # Update or add setting
            if [[ -f "$config_local" ]] && grep -q "^GEOIP_DB_SOURCE=" "$config_local"; then
                sed -i "s/^GEOIP_DB_SOURCE=.*/GEOIP_DB_SOURCE=\"$source\"/" "$config_local"
            else
                echo "GEOIP_DB_SOURCE=\"$source\"" >> "$config_local"
            fi

            echo "✓ Database source set to: $source"

            if [[ "$source" == "maxmind" ]]; then
                echo ""
                echo "Next steps:"
                echo "  1. Get FREE license key: https://www.maxmind.com/en/geolite2/signup"
                echo "  2. Set key: nftban geoip config set-key YOUR_KEY"
                echo "  3. Test download: nftban geoip config test-download"
                echo "  4. Update database: nftban geoip update"
            fi
            ;;

        set-key)
            local key="${1:-}"
            if [[ -z "$key" ]]; then
                echo "ERROR: License key required" >&2
                echo "Usage: nftban geoip config set-key YOUR_KEY" >&2
                return 1
            fi

            local config_local="/etc/nftban/conf.d/nftban-go.conf.local"

            # Ensure directory exists
            mkdir -p "$(dirname "$config_local")"

            # Update or add setting
            if [[ -f "$config_local" ]] && grep -q "^GEOIP_MAXMIND_LICENSE_KEY=" "$config_local"; then
                sed -i "s/^GEOIP_MAXMIND_LICENSE_KEY=.*/GEOIP_MAXMIND_LICENSE_KEY=\"$key\"/" "$config_local"
            else
                echo "GEOIP_MAXMIND_LICENSE_KEY=\"$key\"" >> "$config_local"
            fi

            # Set restrictive permissions
            chmod 600 "$config_local"

            echo "✓ MaxMind license key saved to $config_local"
            echo "  Permissions: 600 (root only)"
            echo ""
            echo "Test download: nftban geoip config test-download"
            ;;

        test-download)
            echo "Testing database download..."
            echo ""

            # Load config
            source /etc/nftban/conf.d/nftban-go.conf
            [[ -f /etc/nftban/conf.d/nftban-go.conf.local ]] && source /etc/nftban/conf.d/nftban-go.conf.local

            local test_url=""
            if [[ "${GEOIP_DB_SOURCE:-github}" == "maxmind" ]]; then
                if [[ -z "${GEOIP_MAXMIND_LICENSE_KEY:-}" ]]; then
                    echo "ERROR: MaxMind license key not set" >&2
                    echo "Set key: nftban geoip config set-key YOUR_KEY" >&2
                    return 1
                fi
                test_url="https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-City&license_key=${GEOIP_MAXMIND_LICENSE_KEY}&suffix=tar.gz"
                echo "Testing MaxMind download..."
            else
                test_url="https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-City.mmdb"
                echo "Testing GitHub mirror download..."
            fi

            echo "URL: ${test_url%%\?*}..."
            echo ""

            if curl -I -L "$test_url" 2>&1 | head -20; then
                echo ""
                echo "✓ Download test PASSED"
                echo "  Run: nftban geoip update"
            else
                echo ""
                echo "✗ Download test FAILED"
                if [[ "${GEOIP_DB_SOURCE:-github}" == "maxmind" ]]; then
                    echo "  Check your license key is valid"
                fi
            fi
            ;;

        *)
            echo "ERROR: Unknown config command: $config_cmd" >&2
            echo "Usage: nftban geoip config <show|set-source|set-key|test-download>" >&2
            return 1
            ;;
    esac
}

nftban_geoip_cmd_help() {
    # Show help text

    nftban_render_banner simple
    echo ""

    cat << 'EOF'
nftban geoip - Fast IP geolocation lookups + Country blocking (GeoBan)

USAGE:
    nftban geoip <command> [options]

GEOIP LOOKUP COMMANDS:
    lookup <IP> [format]    Lookup single IP address
                            Formats: json (default), compact, country

    bulk [file]             Bulk lookup from file or stdin
                            Outputs JSONL (one JSON per line)

    status                  Show GeoIP system status
                            (binary, database, performance)

    test                    Run built-in tests
                            Tests database and performance

    update                  Update GeoLite2 database
                            Downloads latest database

    config <cmd>            Configure database source and settings
                            show - Show current configuration
                            set-source <github|maxmind> - Set database source
                            set-key <KEY> - Set MaxMind license key
                            test-download - Test database download

GEOBAN COUNTRY BLOCKING COMMANDS:
    ban <CC> [CC...]        Block all traffic from countries
                            Example: nftban geoip ban CN RU KP

    unban <CC> [CC...]      Remove country bans
                            Example: nftban geoip unban CN

    whitelist <CC> [CC...]  Allow countries (bypass blocks)
                            Example: nftban geoip whitelist US GB DE

    unwhitelist <CC> [...]  Remove country whitelists

    list                    Show all active GeoBan countries
                            (banned and whitelisted)

    refresh                 Update all active countries
                            (re-download latest IP ranges)

    help                    Show this help message

GEOIP LOOKUP EXAMPLES:
    # Lookup single IP (JSON)
    nftban geoip lookup 8.8.8.8

    # Lookup with compact format
    nftban geoip lookup 8.8.8.8 compact

    # Get country only
    nftban geoip lookup 8.8.8.8 country

    # Bulk lookup from file
    nftban geoip bulk ip_list.txt

    # Bulk lookup from stdin
    cat ips.txt | nftban geoip bulk

    # Check system status
    nftban geoip status

    # Run tests
    nftban geoip test

    # Update database
    nftban geoip update

GEOBAN EXAMPLES:
    # Block China, Russia, North Korea
    nftban geoip ban CN RU KP

    # Remove China ban
    nftban geoip unban CN

    # Whitelist USA, UK, Germany (allow even if banned)
    nftban geoip whitelist US GB DE

    # Show all active countries
    nftban geoip list

    # Refresh all countries (re-download IPs)
    nftban geoip refresh

DATABASE CONFIGURATION:
    # Show current database configuration
    nftban geoip config show

    # Use GitHub mirror (FREE, no key required - DEFAULT)
    nftban geoip config set-source github

    # Use MaxMind direct (FREE, requires license key)
    nftban geoip config set-source maxmind
    nftban geoip config set-key YOUR_LICENSE_KEY

    # Test database download
    nftban geoip config test-download

    # Get FREE MaxMind key: https://www.maxmind.com/en/geolite2/signup

PERFORMANCE:
    GeoIP Lookup: 50-200 microseconds (0.05-0.2ms)
    GeoBan Load:  Atomic, zero-downtime updates
    Unlimited lookups (no rate limits)
    Offline operation (no internet after database download)

FILES AND LOCATIONS:
    Binary:          /usr/lib/nftban/bin/nftban-geoip (GO 1.21+, ~6MB)
    Database:        /var/lib/nftban/geoip/GeoLite2-City.mmdb (~61MB)
    Configuration:   /etc/nftban/conf.d/nftban-go.conf
    User overrides:  /etc/nftban/conf.d/nftban-go.conf.local
    GeoBan files:    /etc/nftban/geoban.d/
    Country IPs:     /var/cache/nftban/geoban/
    Tracking:        /var/lib/nftban/geoban/tracking/
    Logs:            /var/log/nftban/go-operations.log

nftban — Simplifying Linux Firewall Management
EOF
}

# =============================================================================
# EXPORTS
# =============================================================================

# Export main handler
export -f nftban_cmd_geoip

# Export subcommand functions (GeoIP lookup)
export -f nftban_geoip_cmd_lookup
export -f nftban_geoip_cmd_bulk
export -f nftban_geoip_cmd_status
export -f nftban_geoip_cmd_test
export -f nftban_geoip_cmd_update
export -f nftban_geoip_cmd_config
export -f nftban_geoip_cmd_help

# Export GeoBan subcommand functions
export -f nftban_geoip_cmd_ban
export -f nftban_geoip_cmd_unban
export -f nftban_geoip_cmd_whitelist
export -f nftban_geoip_cmd_unwhitelist
export -f nftban_geoip_cmd_list
export -f nftban_geoip_cmd_refresh
