#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Validate Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Validate nftables structure against NFTBan specification
#
# meta:name="cmd_validate"
# meta:type="cli"
# meta:header="Validate Command"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Validate nftables structure and ruleset against NFTBan spec"
# meta:inventory.files=""
# meta:inventory.binaries="nft"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2025-11-14"
# meta:updated_date="2025-11-24"
# =============================================================================

# Strict mode
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${CMD_VALIDATE_LOADED:-}" ]] && return 0
readonly CMD_VALIDATE_LOADED=1

# Source core validator
: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"

# Load strict mode library
# shellcheck source=/usr/lib/nftban/lib/strict.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/strict.sh" || return 1
else
    # Fallback to manual strict mode
    set -Eeuo pipefail
fi

# Load version library
# shellcheck source=/usr/lib/nftban/lib/version.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/version.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/version.sh" || return 1
fi
source "${NFTBAN_LIB_DIR}/core/nftban_validator.sh" || return 1

# Load NFT schema (single source of truth for table/set names)
# shellcheck source=/usr/lib/nftban/lib/nft_schema.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" || return 1
fi

# =============================================================================
# COMMAND HANDLER
# =============================================================================

nftban_cmd_validate() {
    # Validate nftables structure
    # Usage: nftban validate [--json]

    local json_output=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                json_output=true
                shift
                ;;
            -h|--help)
                nftban_cmd_validate_help
                return 0
                ;;
            *)
                echo "ERROR: Unknown option: $1" >&2
                nftban_cmd_validate_help
                return 1
                ;;
        esac
    done

    # Show banner (skip for JSON output)
    if [[ "$json_output" != "true" ]]; then
        if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
            # shellcheck source=/dev/null
            source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
            if [[ $(type -t nftban_banner) == "function" ]]; then
                nftban_banner
            fi
        fi
        echo ""
    fi

    # Run validation
    validate_structure "$json_output"
}

nftban_cmd_validate_help() {
    cat << 'EOF'
Usage: nftban validate [OPTIONS]

Validate nftables structure against NFTBan specification.

OPTIONS:
  --json          Output results in JSON format
  -h, --help      Show this help message

DESCRIPTION:
  This command validates your nftables configuration against the NFTBan
  structure specification. It checks for:

  - Required tables (ip nftban, ip6 nftban)
  - Forbidden tables (inet filter, ip filter - these bypass NFTBan!)
  - Required sets (whitelist_ipv4, blacklist_ipv4, tcp_ports_in, etc.)
  - Correct chain policies (input=drop, output=accept)
  - Proper priority ordering

EXAMPLES:
  nftban validate              # Human-readable output
  nftban validate --json       # JSON output for scripts/GUI

EXIT STATUS:
  0  All checks passed (or warnings only)
  1  Validation errors found

SEE ALSO:
  nftban check <ip|port>    Check if specific IP/port is allowed/blocked
  nftban stats               Show firewall statistics
EOF
}

# =============================================================================
# EXPORTS
# =============================================================================

# Exit marker for testing validation
command -v nftban_cmd_exit >/dev/null 2>&1 && nftban_cmd_exit "validate"

export -f nftban_cmd_validate
# Exit marker for testing validation
command -v nftban_cmd_exit >/dev/null 2>&1 && nftban_cmd_exit "validate"

export -f nftban_cmd_validate_help
