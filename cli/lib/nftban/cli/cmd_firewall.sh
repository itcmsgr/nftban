#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.3.1 - Firewall Management Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Firewall structure validation, IP/port checking, logs, and statistics
#
# meta:name="cmd_firewall"
# meta:type="cli"
# meta:header="NFTBan Firewall Command"
# meta:version="1.3.1"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Comprehensive firewall management: validate, check, stats, logs, reload"
# meta:inventory.files=""
# meta:inventory.binaries="nft,journalctl"
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/conf.d/fwlog.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root (for reload, logs enable/disable)"
#
# meta:created_date="2025-11-13"
# meta:updated_date="2026-01-23"


# =============================================================================
# CONFIGURATION
# =============================================================================

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
[[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" ]] && source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf"

: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"
: "${NFTBAN_CLI_DIR:=/usr/lib/nftban/cli}"

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


# Load NFT schema (single source of truth for table/set names)
# shellcheck source=/usr/lib/nftban/lib/nft_schema.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nft_schema.sh"
fi

# Load timestamp library (unified timestamp generation)
# shellcheck source=/usr/lib/nftban/lib/nftban_timestamp.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_timestamp.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_timestamp.sh"
fi

# Load service control library (systemd service/timer primitives)
# shellcheck source=/usr/lib/nftban/lib/nftban_service_control.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_service_control.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_service_control.sh"
fi

# Load JSON helper for --json support
JSON_HELPER="${NFTBAN_LIB_DIR}/helpers/json_output.sh"
if [[ -f "$JSON_HELPER" ]]; then
    # shellcheck source=/dev/null
    source "$JSON_HELPER"
fi

# =============================================================================
# MAIN COMMAND HANDLER
# =============================================================================

nftban_cmd_firewall() {
    # Main firewall command handler
    # Usage: nftban firewall <subcommand> [options]

    local subcommand="${1:-help}"

    # Check for --json flag in all args (suppress banner for JSON output)
    local json_mode=false
    for arg in "$@"; do
        [[ "$arg" == "--json" ]] && json_mode=true && break
    done

    # Show banner (skip for JSON output to avoid polluting machine-readable output)
    if [[ "$json_mode" == "false" ]]; then
        if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
            # shellcheck source=/dev/null
            source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"
            if [[ $(type -t nftban_banner) == "function" ]]; then
                nftban_banner
            fi
        fi
        echo ""
    fi

    case "$subcommand" in
        help|-h|--help)
            show_firewall_help
            return 0
            ;;
        validate)
            shift
            firewall_validate "$@"
            ;;
        check)
            shift
            firewall_check "$@"
            ;;
        stats)
            shift
            firewall_stats "$@"
            ;;
        logs)
            shift
            # Load logs command on-demand
            if [[ -f "${NFTBAN_CLI_DIR}/cmd_firewall_logs.sh" ]]; then
                # shellcheck source=/dev/null
                source "${NFTBAN_CLI_DIR}/cmd_firewall_logs.sh"
                nftban_cmd_firewall_logs "$@"
            else
                echo "Error: Firewall logs module not found" >&2
                return 1
            fi
            ;;
        reload)
            shift
            firewall_reload "$@"
            ;;
        *)
            echo "Error: Unknown firewall subcommand: $subcommand" >&2
            echo "Try 'nftban firewall help' for more information." >&2
            return 1
            ;;
    esac
}

# =============================================================================
# SUBCOMMAND: VALIDATE
# =============================================================================

firewall_validate() {
    # Validate nftables structure against NFTBan specification
    # Args: [--json]

    local output_json=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                output_json=true
                shift
                ;;
            -h|--help)
                show_validate_help
                return 0
                ;;
            *)
                echo "Error: Unknown option: $1" >&2
                echo "Try 'nftban firewall validate --help' for more information." >&2
                return 1
                ;;
        esac
    done

    # Load core validator
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_validator.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_validator.sh"
    else
        echo "Error: Cannot find nftban_validator.sh" >&2
        return 1
    fi

    # Run validation
    if [[ "$output_json" == "true" ]]; then
        validate_structure "true"
    else
        validate_structure "false"
    fi
}

# =============================================================================
# SUBCOMMAND: CHECK
# =============================================================================

firewall_check() {
    # Check if IP or port is blocked/allowed
    # Args: <ip|port> [--json]

    local value=""
    local output_json=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                output_json=true
                shift
                ;;
            -h|--help)
                show_check_help
                return 0
                ;;
            -*)
                echo "Error: Unknown option: $1" >&2
                echo "Try 'nftban firewall check --help' for more information." >&2
                return 1
                ;;
            *)
                value="$1"
                shift
                ;;
        esac
    done

    # Validate value provided
    if [[ -z "$value" ]]; then
        echo "Error: No IP or port specified" >&2
        echo "Try 'nftban firewall check --help' for more information." >&2
        return 1
    fi

    # Load core validator
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_validator.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_validator.sh"
    else
        echo "Error: Cannot find nftban_validator.sh" >&2
        return 1
    fi

    # Run check
    if [[ "$output_json" == "true" ]]; then
        check_ip_or_port "$value" "true"
    else
        check_ip_or_port "$value" "false"
    fi
}

# =============================================================================
# SUBCOMMAND: STATS
# =============================================================================

firewall_stats() {
    # Display firewall statistics
    # Args: [--json]

    local output_json=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                output_json=true
                shift
                ;;
            -h|--help)
                show_stats_help
                return 0
                ;;
            *)
                echo "Error: Unknown option: $1" >&2
                echo "Try 'nftban firewall stats --help' for more information." >&2
                return 1
                ;;
        esac
    done

    # Load core validator
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_validator.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_validator.sh"
    else
        echo "Error: Cannot find nftban_validator.sh" >&2
        return 1
    fi

    # Get statistics
    if [[ "$output_json" == "true" ]]; then
        get_firewall_stats "true"
    else
        get_firewall_stats "false"
    fi
}

# =============================================================================
# SUBCOMMAND: RELOAD
# =============================================================================

firewall_reload() {
    # Reload nftables ruleset
    local quiet=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --quiet|-q)
                quiet=true
                shift
                ;;
            *)
                echo "Error: Unknown option: $1" >&2
                return 1
                ;;
        esac
    done

    if ! nft -f "${NFTBAN_NFTABLES_CONF:-/etc/nftables.conf}" 2>&1; then
        echo "Error: Failed to reload nftables" >&2
        return 1
    fi

    if [[ "$quiet" == "false" ]]; then
        echo "Firewall rules reloaded successfully"
    fi
}

# =============================================================================
# HELP FUNCTIONS
# =============================================================================

show_firewall_help() {
    cat <<'EOF'
Usage: nftban firewall <subcommand> [options]

Firewall structure validation, IP/port checking, and statistics.

Subcommands:
  validate      Validate nftables structure against NFTBan spec
  check         Check if IP or port is blocked/allowed
  stats         Show firewall statistics (tables, chains, sets, IPs)
  logs          View and filter firewall logs (on-demand)
  reload        Reload nftables ruleset
  help          Show this help message

Examples:
  nftban firewall validate
  nftban firewall check 1.2.3.4
  nftban firewall check 22
  nftban firewall stats
  nftban firewall logs show --live
  nftban firewall reload

Global options:
  --json        Output results as JSON (for GUI integration)
  -h, --help    Show help for specific subcommand

For detailed help on a subcommand:
  nftban firewall validate --help
  nftban firewall check --help
  nftban firewall stats --help

EOF
}

show_validate_help() {
    cat <<'EOF'
Usage: nftban firewall validate [OPTIONS]

Validate nftables structure against NFTBan specification.

Checks:
  - Required tables exist (ip nftban, ip6 nftban)
  - Forbidden tables don't exist (inet filter - bypasses NFTBan!)
  - Required sets exist (whitelist_ipv4, blacklist_ipv4, tcp_ports, etc.)
  - Chain policies are correct (input=drop, output=accept)
  - Priority order is correct (-10, -5, 0)

Options:
  --json        Output results as JSON
  -h, --help    Show this help message

Exit codes:
  0   All validation checks passed (OK)
  1   Validation warnings or errors found

Examples:
  nftban firewall validate
  nftban firewall validate --json

Spec file location (priority order):
  1. /etc/nftban/spec.json (user override)
  2. /usr/share/nftban/specs/structure_default.json (default)

EOF
}

show_check_help() {
    cat <<'EOF'
Usage: nftban firewall check <IP|PORT> [OPTIONS]

Check if IP address or port is blocked or allowed in nftables.

The command:
  1. Detects if value is an IP (contains . or :) or port (numeric)
  2. Checks nftables processing path (priority -10 → -5 → 0)
  3. Shows which rule matched (table, chain, set, verdict)
  4. Displays available actions (block, unblock, whitelist, etc.)

Arguments:
  IP|PORT       IP address (1.2.3.4 or 2001:db8::1) or port number (22)

Options:
  --json        Output results as JSON
  -h, --help    Show this help message

Exit codes:
  0   Check completed successfully
  1   Error (invalid input, nftables error)

Examples:
  # Check if IP is blocked
  nftban firewall check 1.2.3.4

  # Check if port is allowed
  nftban firewall check 22

  # JSON output (for GUI)
  nftban firewall check 1.2.3.4 --json

Processing Path:
  Priority: ip/ip6 nftban input_temp_whitelist (temp whitelist)
  Priority: ip/ip6 nftban input_tempban (temp bans)
  Priority: ip/ip6 nftban input (whitelist, blacklist, ports, default deny)

Output includes:
  - Status: allowed / blocked / unknown
  - Matched rule: table, chain, set/rule, verdict
  - Processing path: shows which chains were checked
  - Available actions: block, unblock, whitelist, etc.

EOF
}

show_stats_help() {
    cat <<'EOF'
Usage: nftban firewall stats [OPTIONS]

Display firewall statistics (tables, chains, sets, rules, IP counts).

Statistics include:
  - Summary: total tables, chains, sets, rules
  - Per-set counts: number of IPs in whitelist, blacklist, temp bans, etc.
  - Per-table breakdown: main table vs runtime table

Options:
  --json        Output results as JSON
  -h, --help    Show this help message

Exit codes:
  0   Statistics retrieved successfully
  1   Error (nftables error, permission denied)

Examples:
  # Display statistics
  nftban firewall stats

  # JSON output (for GUI)
  nftban firewall stats --json

Output includes:
  - Total counts (tables, chains, sets, rules)
  - ip/ip6 nftban: whitelist, blacklist, tcp_ports, udp_ports
  - ip/ip6 nftban: temp_whitelist, temp_ban (with auto-expire)

EOF
}

# Export functions
export -f nftban_cmd_firewall
