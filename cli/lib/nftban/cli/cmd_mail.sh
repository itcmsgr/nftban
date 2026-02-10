#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Mail CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Handle mail-related CLI commands
#
# meta:name="cmd_mail"
# meta:type="cli"
# meta:header="Mail CLI Command"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="CLI interface for mail module commands"
# meta:input="Command line arguments for mail operations"
# meta:output="Mail command results"
# meta:depends="bash,nftban_mail.sh"
# meta:created_date="2025-11-05"
#
# meta:inventory.files="nftban_mail.sh,nftban_output.sh,strict.sh,version.sh,json_output.sh"
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

# Load dependencies
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

# Load JSON helper for --json support
JSON_HELPER="${NFTBAN_LIB_DIR}/helpers/json_output.sh"
if [[ -f "$JSON_HELPER" ]]; then
    # shellcheck source=/dev/null
    source "$JSON_HELPER"
fi

# Strict mode settings
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

# Load panel common module for admin email detection
if [[ -f "${LIB_DIR}/lib/nftban_panel_common.sh" ]]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/lib/nftban_panel_common.sh" 2>/dev/null || true
fi

# =============================================================================
# MAIL COMMAND HANDLER
# =============================================================================

cmd_mail_help() {
    echo "Usage: nftban mail <subcommand>"
    echo ""
    echo "Subcommands:"
    echo "  status      Check mail system status"
    echo "  port-status Check mail ports in firewall"
    echo "  test        Send test email"
    echo "  spool       Mail spool management"
    echo "  help        Show this help"
}

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
            # Auto-detect from panel if not provided
            if [[ -z "$recipient" ]] && declare -f nftban_panel_get_admin_email &>/dev/null; then
                recipient=$(nftban_panel_get_admin_email 2>/dev/null) || true
                if [[ -n "$recipient" ]]; then
                    echo "[INFO] Using panel admin email: $recipient"
                fi
            fi
            nftban_mail_send_test "$recipient"
            return $?
            ;;

        spool)
            # Mail spool management
            local spool_cmd="${1:-status}"
            shift || true
            case "$spool_cmd" in
                status|list)
                    nftban_mail_spool_status
                    ;;
                help)
                    echo "Usage: nftban mail spool <command>"
                    echo ""
                    echo "Commands:"
                    echo "  status    Show spooled mail status (default)"
                    echo "  list      Alias for status"
                    echo ""
                    echo "Spooled mails are automatically retried by the queue processor."
                    echo "To view queue status: nftban queue status"
                    ;;
                *)
                    echo "Unknown spool command: $spool_cmd" >&2
                    echo "Usage: nftban mail spool {status|list|help}" >&2
                    return 1
                    ;;
            esac
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
