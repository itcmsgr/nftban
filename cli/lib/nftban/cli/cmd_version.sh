#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Version Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Display version information
#
# meta:name=cmd_version
# meta:type=cli
# meta:header=Version Command
# meta:version=1.0.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Display NFTBan version information
# meta:input=Optional flags: --short, --numeric, --check
# meta:output=Version information
#
# **Inventory & Requirements**
# meta:depends=bash,version.sh
#
# meta:created_date=2025-11-24
# =============================================================================

[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"

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
else
    echo "ERROR: version.sh library not found" >&2
    exit 1
fi

# Prevent double-loading
[[ -n "${CMD_VERSION_LOADED:-}" ]] && return 0
readonly CMD_VERSION_LOADED=1

# =============================================================================
# COMMAND HANDLER
# =============================================================================

nftban_cmd_version() {
    # Display version information
    # Usage: nftban version [--short|--numeric|--check|--json]

    local format="full"
    local json_output=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --short|-s)
                format="short"
                shift
                ;;
            --numeric|-n)
                format="numeric"
                shift
                ;;
            --check|-c)
                format="check"
                shift
                ;;
            --json|-j)
                json_output=true
                shift
                ;;
            --help|-h)
                nftban_cmd_version_usage
                return 0
                ;;
            *)
                echo "ERROR: Unknown option: $1" >&2
                nftban_cmd_version_usage
                return 1
                ;;
        esac
    done

    # Show banner (skip for JSON, short, and numeric output)
    if [[ "$json_output" != "true" ]] && [[ "$format" != "short" ]] && [[ "$format" != "numeric" ]]; then
        if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
            # shellcheck source=/dev/null
            source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"
            if [[ $(type -t nftban_banner) == "function" ]]; then
                nftban_banner
            fi
        fi
        echo ""
    fi

    # Output based on format
    if [[ "$json_output" == "true" ]]; then
        cat <<EOF
{
  "version": "${NFTBAN_VERSION}",
  "version_name": "${NFTBAN_VERSION_NAME}",
  "version_date": "${NFTBAN_VERSION_DATE}",
  "build_date": "${NFTBAN_BUILD_DATE}",
  "components": {
    "cli": "${NFTBAN_CLI_VERSION}",
    "core": "${NFTBAN_CORE_VERSION}",
    "gui": "${NFTBAN_GUI_VERSION}",
    "api": "${NFTBAN_API_VERSION}"
  },
  "requirements": {
    "bash_min": "${NFTBAN_MIN_BASH_VERSION}",
    "nftables_min": "${NFTBAN_MIN_NFT_VERSION}"
  }
}
EOF
    elif [[ "$format" == "short" ]]; then
        nftban_version_short
    elif [[ "$format" == "numeric" ]]; then
        nftban_version_numeric
    elif [[ "$format" == "check" ]]; then
        nftban_version_check_requirements
        if [[ $? -eq 0 ]]; then
            echo "✅ All requirements met"
            return 0
        else
            echo "❌ Requirements not met"
            return 1
        fi
    else
        nftban_version_info
    fi

    echo "# NFTBAN_CMD_EXIT: version"
    return 0
}

nftban_cmd_version_usage() {
    cat <<EOF
Usage: nftban version [OPTIONS]

Display NFTBan version information.

OPTIONS:
  --short, -s       Show version number only (e.g., "0.6.5")
  --numeric, -n     Show numeric version for comparison (e.g., "605")
  --check, -c       Check system requirements
  --json, -j        Output in JSON format
  --help, -h        Show this help message

EXAMPLES:
  nftban version                 # Show full version information
  nftban version --short         # Show version number only
  nftban version --json          # Get version in JSON format
  nftban version --check         # Check system requirements

EOF
}

# =============================================================================
# EXECUTE IF RUN DIRECTLY
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_version "$@"
fi
