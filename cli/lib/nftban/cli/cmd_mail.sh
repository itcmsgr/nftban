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
    echo "  setup <email> [options]  Quick email configuration"
    echo "  status                   Check mail system status"
    echo "  port-status              Check mail ports in firewall"
    echo "  test [email]             Send test email"
    echo "  spool                    Mail spool management"
    echo "  help                     Show this help"
    echo ""
    echo "Setup Options:"
    echo "  --all       Enable all notification triggers"
    echo "  --test      Send test email after setup"
    echo "  --dry-run   Show what would be written (no changes)"
    echo "  --show      Show current email configuration"
    echo ""
    echo "Examples:"
    echo "  nftban mail setup admin@example.com --all --test"
    echo "  nftban mail setup --show"
    echo "  nftban mail test"
}

# =============================================================================
# SETUP HELPER
# =============================================================================

_mail_setup_show() {
    # Show effective email configuration
    # Sources config files to get current values

    local mail_conf="/etc/nftban/conf.d/mail.conf"
    local mail_conf_local="/etc/nftban/conf.d/mail.conf.local"

    # Source configs to get current values
    # shellcheck source=/dev/null
    [[ -f "$mail_conf" ]] && source "$mail_conf" 2>/dev/null || true
    # shellcheck source=/dev/null
    [[ -f "$mail_conf_local" ]] && source "$mail_conf_local" 2>/dev/null || true

    echo "Email Configuration Status"
    echo "=========================="
    echo ""
    echo "Global Settings:"
    echo "  Enabled:   ${NFTBAN_MAIL_ENABLED:-NO}"
    echo "  Recipient: ${NFTBAN_MAIL_RECIPIENT:-(not set)}"
    echo "  Method:    ${NFTBAN_MAIL_METHOD:-auto-detect}"
    echo "  Sender:    ${NFTBAN_SENDER:-nftban@\$(hostname)}"
    echo ""
    echo "Notification Triggers:"
    echo "  Health Critical: ${NFTBAN_MAIL_ON_HEALTH_CRITICAL:-NO}"
    echo "  Daily Report:    ${NFTBAN_MAIL_DAILY_REPORT:-NO}"
    echo "  On Ban:          ${NFTBAN_MAIL_ON_BAN:-NO}"
    echo "  Login Alert:     ${NFTBAN_MAIL_ON_LOGIN_ALERT:-NO}"
    echo ""
    echo "Per-Module Overrides (empty = uses global NFTBAN_MAIL_RECIPIENT):"
    echo "  Portscan:    ${PORTSCAN_NOTIFY_EMAIL_TO:-(global)}"
    echo "  RBL:         ${NFTBAN_RBL_ALERT_EMAIL:-(global)}"
    echo "  Updates:     ${NFTBAN_UPDATE_NOTIFY_EMAIL:-(global)}"
    echo "  Reports:     ${STATS_EMAIL_RECIPIENTS:-(global)}"
    echo "  CLI Reports: ${NFTBAN_MAIL_REPORT_RECIPIENT:-(global)}"
    echo ""
    echo "Config Files:"
    echo "  Main:  $mail_conf"
    echo "  Local: $mail_conf_local $([[ -f "$mail_conf_local" ]] && echo "(exists)" || echo "(not created)")"
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

        setup)
            # Quick email setup - writes to mail.conf.local only
            local email=""
            local enable_all=false
            local do_test=false
            local dry_run=false
            local show_only=false

            # Parse arguments
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --all) enable_all=true ;;
                    --test) do_test=true ;;
                    --dry-run) dry_run=true ;;
                    --show) show_only=true ;;
                    --help|-h) cmd_mail_help; return 0 ;;
                    -*)
                        echo "Unknown option: $1" >&2
                        echo "Usage: nftban mail setup <email> [--all] [--test] [--dry-run] [--show]" >&2
                        return 1
                        ;;
                    *)
                        # First non-flag argument is the email
                        [[ -z "$email" ]] && email="$1"
                        ;;
                esac
                shift
            done

            # Show current config
            if [[ "$show_only" == "true" ]]; then
                _mail_setup_show
                return 0
            fi

            # Validate email is provided
            if [[ -z "$email" ]]; then
                echo "Usage: nftban mail setup <email> [--all] [--test] [--dry-run]" >&2
                echo "       nftban mail setup --show" >&2
                echo ""
                echo "Examples:" >&2
                echo "  nftban mail setup admin@example.com --all --test" >&2
                echo "  nftban mail setup admin@example.com" >&2
                return 1
            fi

            # Validate email format
            if ! nftban_mail_validate_address "$email"; then
                echo "Error: Invalid email address: $email" >&2
                return 1
            fi

            local conf_local="/etc/nftban/conf.d/mail.conf.local"

            # Build config content
            local config_content
            config_content="# NFTBan Mail Configuration
# Auto-generated by: nftban mail setup
# Generated: $(date -Iseconds)
#
# This file overrides settings in mail.conf
# Per-module overrides can still be set in module config files

NFTBAN_MAIL_ENABLED=\"YES\"
NFTBAN_MAIL_RECIPIENT=\"${email}\""

            if [[ "$enable_all" == "true" ]]; then
                config_content+="

# All notification triggers enabled (--all flag)
NFTBAN_MAIL_ON_HEALTH_CRITICAL=\"YES\"
NFTBAN_MAIL_DAILY_REPORT=\"YES\"
NFTBAN_MAIL_ON_BAN=\"YES\"
NFTBAN_MAIL_ON_LOGIN_ALERT=\"YES\""
            fi

            # Dry run - just show what would be written
            if [[ "$dry_run" == "true" ]]; then
                echo "Dry run - would write to: $conf_local"
                echo "---"
                echo "$config_content"
                echo "---"
                return 0
            fi

            # Check if we can write
            local conf_dir
            conf_dir=$(dirname "$conf_local")
            if [[ ! -d "$conf_dir" ]]; then
                echo "Error: Config directory does not exist: $conf_dir" >&2
                return 1
            fi

            # Write config
            echo "$config_content" > "$conf_local"
            chmod 640 "$conf_local" 2>/dev/null || true
            chown root:nftban "$conf_local" 2>/dev/null || true

            echo "Email configured successfully"
            echo ""
            echo "  Recipient: $email"
            echo "  Config:    $conf_local"
            [[ "$enable_all" == "true" ]] && echo "  Triggers:  All enabled (--all)"
            echo ""
            echo "All modules will now use this email unless overridden."

            # Test if requested
            if [[ "$do_test" == "true" ]]; then
                echo ""
                echo "Sending test email..."
                # Re-source config to pick up new settings
                # shellcheck source=/dev/null
                source "$conf_local" 2>/dev/null || true
                nftban_mail_send_test "$email"
            fi

            return 0
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
