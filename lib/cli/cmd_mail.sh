#!/usr/bin/env bash

# =============================================================================
# NFTBan CLI - Mail Command
# Version: 1.0.0
# Location: lib/cli/cmd_mail.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Dependencies: nftban_utils_lib.sh
# Description: Mail service detection and status
# =============================================================================

# Strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Load dependencies
SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
LIB_DIR="$(dirname "$SCRIPT_DIR")"

if [[ -f "${LIB_DIR}/nftban_utils_lib.sh" ]]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/nftban_utils_lib.sh"
else
    echo "ERROR: nftban_utils_lib.sh not found at ${LIB_DIR}" >&2
    exit 1
fi

# =============================================================================
# MAIL COMMAND HANDLER
# =============================================================================

cmd_mail() {
    local action="${1:-status}"
    shift || true

    case "$action" in
        status|panel)
            show_mail_service_panel
            ;;
        check)
            if check_mail_service; then
                nftban_log_success "Mail service is properly configured"
                exit 0
            else
                local exit_code=$?
                if [[ $exit_code -eq 2 ]]; then
                    nftban_log_error "Multiple SMTP services detected (conflict)"
                    exit 2
                else
                    nftban_log_error "Mail service is NOT properly configured"
                    exit 1
                fi
            fi
            ;;
        detect)
            echo "Detecting mail services..."
            echo ""
            echo "Mail command: $(detect_mail_command)"
            echo "Mail services: $(detect_mta_service)"
            ;;
        *)
            nftban_log_error "Unknown mail action: $action"
            echo ""
            echo "Available actions:"
            echo "  status           Show mail service status panel (default)"
            echo "  check            Quick check (exit 0=OK, 1=not configured, 2=conflict)"
            echo "  detect           Show raw detection output"
            echo ""
            echo "Examples:"
            echo "  nftban mail status          # Show detailed panel"
            echo "  nftban mail check           # Quick check for scripts"
            echo "  nftban mail detect          # Show detection results"
            echo ""
            exit 1
            ;;
    esac
}

# Export function
export -f cmd_mail
