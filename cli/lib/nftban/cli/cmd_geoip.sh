#!/usr/bin/env bash
# shellcheck disable=SC1090  # Dynamic config paths, cannot follow
# =============================================================================

# Load JSON helper for --json support
[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"
[[ -z "${NFTBAN_CONFIG_DIR:-}" ]] && readonly NFTBAN_CONFIG_DIR="/etc/nftban"
[[ -z "${NFTBAN_DATA_DIR:-}" ]] && readonly NFTBAN_DATA_DIR="/var/lib/nftban"

# Load strict mode library
# shellcheck source=/usr/lib/nftban/lib/strict.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/strict.sh"
else
    # Fallback to manual strict mode
    set -Eeuo pipefail
fi

# Load version library
# shellcheck source=/usr/lib/nftban/lib/version.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/version.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/version.sh"
fi
JSON_HELPER="${NFTBAN_LIB_DIR}/helpers/json_output.sh"
if [[ -f "$JSON_HELPER" ]]; then
    # shellcheck source=/dev/null
    source "$JSON_HELPER"
fi
# NFTBan v1.0.0 - GeoIP CLI Handler
# =============================================================================

# SPDX-License-Identifier: MPL-2.0
# Purpose: CLI interface for GO GeoIP lookups
#
# meta:name="cmd_geoip"
# meta:type="cli"
# meta:header="GeoIP CLI Handler"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="CLI interface for GeoIP lookups"
# meta:inventory.files=""
# meta:inventory.binaries="nftban-core"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# meta:created_date="2025-11-05"
# meta:updated_date="2025-11-24"
# =============================================================================


# Enhanced strict mode
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

    # Note: Banner is shown by help function or caller (geoban)
    # Load output module for help function
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"
    fi

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
            nftban_banner
            echo "ERROR: Unknown geoip command: $subcommand" >&2
            echo "Run 'nftban geoip help' for usage information" >&2
            exit 1
            ;;
    esac
}

# =============================================================================

# SUBCOMMAND IMPLEMENTATIONS
# =============================================================================


nftban_geoip_cmd_lookup() {
    # Lookup single IP address via nftban-core
    # Args: $1 = IP address, $2 = format (optional: json|compact|country)

    local ip="${1:-}"
    local format="${2:-compact}"

    if [[ -z "$ip" ]]; then
        echo "ERROR: IP address required" >&2
        echo "Usage: nftban geoip lookup <IP> [json|compact|country]" >&2
        return 1
    fi

    # Use nftban-core geoip lookup command
    local nftban_core_bin="${NFTBAN_CORE_BIN:-${NFTBAN_LIB_DIR}/bin/nftban-core}"

    # Fallback: try to find nftban-core in PATH
    if [[ ! -x "$nftban_core_bin" ]]; then
        nftban_core_bin=$(command -v nftban-core 2>/dev/null || echo "")
    fi

    if [[ -z "$nftban_core_bin" || ! -x "$nftban_core_bin" ]]; then
        echo "ERROR: nftban-core binary not found" >&2
        echo "" >&2
        echo "The 'geoip lookup' command requires the nftban-core Go binary." >&2
        echo "Expected location: ${NFTBAN_LIB_DIR}/bin/nftban-core" >&2
        echo "" >&2
        echo "This happens in CLI-only mode (bash scripts only)." >&2
        echo "" >&2
        echo "Solutions:" >&2
        echo "  1. Install full NFTBan package:" >&2
        echo "     dnf install nftban  (or: apt install nftban)" >&2
        echo "" >&2
        echo "  2. Check if binary exists:" >&2
        echo "     ls -la ${NFTBAN_LIB_DIR}/bin/nftban-core" >&2
        echo "" >&2
        return 1
    fi

    case "$format" in
        json)
            # JSON format for GUI/API
            "$nftban_core_bin" geoip lookup "$ip" --json
            ;;
        compact)
            # Full format: CC/City/Timezone
            "$nftban_core_bin" geoip lookup "$ip"
            ;;
        country)
            # Country only
            "$nftban_core_bin" geoip lookup "$ip" 2>/dev/null | cut -d'/' -f1 || echo "Unknown"
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
        source "${NFTBAN_LIB_DIR}/core/nftban_geoip_go.sh" || {
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
    # Show GeoIP system status via nftban-core
    # No args

    # Use nftban-core geoip status command
    local nftban_core_bin="${NFTBAN_CORE_BIN:-${NFTBAN_LIB_DIR}/bin/nftban-core}"

    # Fallback: try to find nftban-core in PATH
    if [[ ! -x "$nftban_core_bin" ]]; then
        nftban_core_bin=$(command -v nftban-core 2>/dev/null || echo "")
    fi

    if [[ -z "$nftban_core_bin" || ! -x "$nftban_core_bin" ]]; then
        echo "ERROR: nftban-core binary not found" >&2
        echo "" >&2
        echo "The 'geoip status' command requires the nftban-core Go binary." >&2
        echo "Expected location: ${NFTBAN_LIB_DIR}/bin/nftban-core" >&2
        echo "" >&2
        echo "This happens in CLI-only mode (bash scripts only)." >&2
        echo "" >&2
        echo "Solutions:" >&2
        echo "  1. Install full NFTBan package:" >&2
        echo "     dnf install nftban  (or: apt install nftban)" >&2
        echo "" >&2
        echo "  2. Check if binary exists:" >&2
        echo "     ls -la ${NFTBAN_LIB_DIR}/bin/nftban-core" >&2
        echo "" >&2
        return 1
    fi

    # Call nftban-core geoip status (shows database info and performance)
    "$nftban_core_bin" geoip status
}

nftban_geoip_cmd_test() {
    # Run built-in tests
    # No args

    local binary_path="${NFTBAN_LIB_DIR}/bin/nftban-geoip"

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
    # Update GeoLite2 database via nftban-core
    # No args

    # Use nftban-core geoip update command
    local nftban_core_bin="${NFTBAN_CORE_BIN:-${NFTBAN_LIB_DIR}/bin/nftban-core}"

    # Fallback: try to find nftban-core in PATH
    if [[ ! -x "$nftban_core_bin" ]]; then
        nftban_core_bin=$(command -v nftban-core 2>/dev/null || echo "")
    fi

    if [[ -z "$nftban_core_bin" || ! -x "$nftban_core_bin" ]]; then
        echo "ERROR: nftban-core binary not found" >&2
        echo "" >&2
        echo "The 'geoip update' command requires the nftban-core Go binary." >&2
        echo "Expected location: ${NFTBAN_LIB_DIR}/bin/nftban-core" >&2
        echo "" >&2
        echo "This happens in CLI-only mode (bash scripts only)." >&2
        echo "" >&2
        echo "Solutions:" >&2
        echo "  1. Install full NFTBan package:" >&2
        echo "     dnf install nftban  (or: apt install nftban)" >&2
        echo "" >&2
        echo "  2. Check if binary exists:" >&2
        echo "     ls -la ${NFTBAN_LIB_DIR}/bin/nftban-core" >&2
        echo "" >&2
        return 1
    fi

    # Call nftban-core geoip update
    "$nftban_core_bin" geoip update
}

nftban_geoip_cmd_ban() {
    # Ban countries (block all traffic from country)
    # Args: $@ = country codes (e.g., CN RU KP)

    # Load GeoBan module
    if ! declare -f nftban_geoban_ban_countries >/dev/null 2>&1; then
        source "${NFTBAN_LIB_DIR}/core/nftban_geoban.sh" || {
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
        source "${NFTBAN_LIB_DIR}/core/nftban_geoban.sh" || {
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
        source "${NFTBAN_LIB_DIR}/core/nftban_geoban.sh" || {
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
        source "${NFTBAN_LIB_DIR}/core/nftban_geoban.sh" || {
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
        source "${NFTBAN_LIB_DIR}/core/nftban_geoban.sh" || {
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
        source "${NFTBAN_LIB_DIR}/core/nftban_geoban.sh" || {
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
            local config_file="${NFTBAN_CONFIG_DIR}/conf.d/geoip/main.conf"
            if [[ -f "$config_file" ]]; then
                source "$config_file"
            fi

            echo "Database Source:"
            echo "  Current: ${GEOIP_DB_SOURCE:-dbip}"
            echo ""

            if [[ "${GEOIP_DB_SOURCE:-dbip}" == "maxmind" ]]; then
                echo "MaxMind GeoLite2 Settings:"
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
                echo "DB-IP Lite Settings (DEFAULT):"
                echo "  URL: https://download.db-ip.com/free/"
                echo "  License: CC BY 4.0 (Free, no registration)"
                echo "  Updates: Monthly (automatic)"
                echo ""
                echo "DB-IP Lite provides free IP geolocation data."
                echo "No account or license key needed!"
                echo "Attribution: IP Geolocation by DB-IP (https://db-ip.com)"
            fi

            echo ""
            echo "Database Location:"
            local geoip_db="${NFTBAN_DATA_DIR}/geoip/dbip-country-lite.mmdb"
            echo "  Path: ${geoip_db}"
            if [[ -f "${geoip_db}" ]]; then
                local db_size db_date
                db_size=$(du -h "${geoip_db}" | cut -f1)
                db_date=$(stat -c %y "${geoip_db}" | cut -d' ' -f1)
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
            if [[ "$source" != "dbip" && "$source" != "maxmind" ]]; then
                echo "ERROR: Invalid source: $source" >&2
                echo "Valid sources: dbip (default), maxmind" >&2
                return 1
            fi

            local config_local="${NFTBAN_CONFIG_DIR}/conf.d/geoip/main.conf.local"

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

            local config_local="${NFTBAN_CONFIG_DIR}/conf.d/geoip/main.conf.local"

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
            [[ -f "${NFTBAN_CONFIG_DIR}/conf.d/geoip/main.conf" ]] && source "${NFTBAN_CONFIG_DIR}/conf.d/geoip/main.conf"
            [[ -f "${NFTBAN_CONFIG_DIR}/conf.d/geoip/main.conf.local" ]] && source "${NFTBAN_CONFIG_DIR}/conf.d/geoip/main.conf.local"

            local test_url=""
            local current_month
            current_month=$(date +%Y-%m)

            if [[ "${GEOIP_DB_SOURCE:-dbip}" == "maxmind" ]]; then
                if [[ -z "${GEOIP_MAXMIND_LICENSE_KEY:-}" ]]; then
                    echo "ERROR: MaxMind license key not set" >&2
                    echo "Set key: nftban geoip config set-key YOUR_KEY" >&2
                    return 1
                fi
                test_url="https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-Country&license_key=${GEOIP_MAXMIND_LICENSE_KEY}&suffix=tar.gz"
                echo "Testing MaxMind download..."
            else
                test_url="https://download.db-ip.com/free/dbip-country-lite-${current_month}.mmdb.gz"
                echo "Testing DB-IP Lite download..."
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
                if [[ "${GEOIP_DB_SOURCE:-dbip}" == "maxmind" ]]; then
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

    nftban_banner "geoip"
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

    # Use DB-IP Lite (FREE, no key required - DEFAULT)
    nftban geoip config set-source dbip

    # Use MaxMind GeoLite2 (FREE, requires license key)
    nftban geoip config set-source maxmind
    nftban geoip config set-key YOUR_LICENSE_KEY

    # Test database download
    nftban geoip config test-download

    # Get FREE MaxMind key: https://www.maxmind.com/en/geolite2/signup

DATABASE PROVIDERS:
    DB-IP Lite (DEFAULT):
      - Free, no registration required
      - License: CC BY 4.0
      - Country-level accuracy
      - Monthly updates (~7MB)
      - https://db-ip.com

    MaxMind GeoLite2 (OPTIONAL):
      - Free with registration
      - Requires license key
      - City-level accuracy available
      - Weekly updates
      - https://www.maxmind.com

PERFORMANCE:
    GeoIP Lookup: 50-200 microseconds (0.05-0.2ms)
    GeoBan Load:  Atomic, zero-downtime updates
    Unlimited lookups (no rate limits)
    Offline operation (no internet after database download)

FILES AND LOCATIONS:
    Binary:          /usr/lib/nftban/bin/nftban-core (Go 1.21+)
    Database:        /var/lib/nftban/geoip/dbip-country-lite.mmdb (~7MB)
    GeoIP config:    /etc/nftban/conf.d/geoip/main.conf
    GeoBan config:   /etc/nftban/conf.d/geoban/main.conf
    User overrides:  *.conf.local files in same directories
    GeoBan files:    /etc/nftban/geoban.d/
    Country IPs:     /var/cache/nftban/geoban/
    Tracking:        /var/lib/nftban/geoban/tracking/
    Logs:            /var/log/nftban/geoip.log

ATTRIBUTION:
    IP Geolocation by DB-IP (https://db-ip.com)

NFTBan — Open-source Linux IPS and nftables firewall manager
EOF
}

# =============================================================================

# EXPORTS
# =============================================================================


# Export main handler
# Exit marker for testing validation
command -v nftban_cmd_exit >/dev/null 2>&1 && nftban_cmd_exit "geoip"

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
