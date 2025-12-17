#!/usr/bin/env bash

# =============================================================================

# Load JSON helper for --json support
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
fi
JSON_HELPER="${NFTBAN_LIB_DIR}/helpers/json_output.sh"
if [[ -f "$JSON_HELPER" ]]; then
    # shellcheck source=/dev/null
    source "$JSON_HELPER"
fi
# NFTBan v1.0.0 - Mail CLI Handler
# =============================================================================

# SPDX-License-Identifier: MPL-2.0
# Purpose: Handle mail-related CLI commands
#
# meta:name=cmd_mail
# meta:type=cli
# meta:header=Mail CLI Command
# meta:version=1.0.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=CLI interface for mail module commands
# meta:input=Command line arguments for mail operations
# meta:output=Mail command results
#
# **Inventory & Requirements**
# meta:depends=bash,nftban_mail.sh
#
# meta:created_date=2025-11-05
# meta:updated_date=2025-11-24
# =============================================================================


# Strict mode
IFS=$'\n\t'
umask 027

# Load dependencies
SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
LIB_DIR="$(dirname "$SCRIPT_DIR")"

# Load mail core module if not already loaded
if [[ ! $(type -t nftban_mail_check_status) == "function" ]]; then
    if [[ -f "${LIB_DIR}/core/nftban_mail.sh" ]]; then
        # shellcheck source=/dev/null
        source "${LIB_DIR}/core/nftban_mail.sh"
    else
        echo "ERROR: nftban_mail.sh not found at ${LIB_DIR}/core" >&2
        exit 1
    fi
fi

# =============================================================================

# MAIL COMMAND HANDLER
# =============================================================================


nftban_cmd_mail() {
    # Handle mail subcommands
    # Args: $@ = mail subcommand and arguments

    local subcmd="${1:-help}"
    shift || true

    # Load output module for banner (used in help)
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"
    fi

    case "$subcmd" in
        status)
            # Check mail system status
            nftban_mail_check_status
            return $?
            ;;

        port-status)
            # Check mail ports in firewall
            nftban_mail_check_ports
            return $?
            ;;

        test)
            # Send test email
            local recipient="${1:-}"
            nftban_mail_send_test "$recipient"
            return $?
            ;;

        help|--help|-h)
            # Show help
            nftban_mail_show_help
            return 0
            ;;

        *)
            # Default: send email
            # Args: $subcmd = content (text or file)
            #       $1 = recipient (optional)
            local content="$subcmd"
            local recipient="${1:-}"

            if [[ -z "$content" ]]; then
                echo "Error: No content specified" >&2
                echo "Usage: nftban mail {content} [recipient]" >&2
                echo "       nftban mail help" >&2
                return 1
            fi

            nftban_mail_send "$content" "$recipient"
            return $?
            ;;
    esac
}

# Export function for auto-loading
export -f nftban_cmd_mail
