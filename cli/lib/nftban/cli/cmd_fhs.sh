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
# NFTBan v1.0.0 - FHS CLI Handler
# =============================================================================

# SPDX-License-Identifier: MPL-2.0
# Purpose: Handle FHS compliance CLI commands
#
# meta:name="cmd_fhs"
# meta:type="cli"
# meta:header="FHS CLI Command"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="CLI interface for FHS compliance reporting"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="nftban"
#
# meta:created_date="2025-11-05"
# meta:updated_date="2025-11-24"
# =============================================================================


# Strict mode
IFS=$'\n\t'
umask 027

# Load dependencies
SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
LIB_DIR="$(dirname "$SCRIPT_DIR")"

# Load FHS report core module if not already loaded
if [[ ! $(type -t nftban_fhs_report_status) == "function" ]]; then
    if [[ -f "${LIB_DIR}/core/nftban_report_fhs.sh" ]]; then
        # shellcheck source=/dev/null
        source "${LIB_DIR}/core/nftban_report_fhs.sh"
    else
        echo "ERROR: nftban_report_fhs.sh not found at ${LIB_DIR}/core" >&2
        exit 1
    fi
fi

# Load mail module for mail-report functionality
if [[ ! $(type -t nftban_mail_send) == "function" ]]; then
    if [[ -f "${LIB_DIR}/core/nftban_mail.sh" ]]; then
        # shellcheck source=/dev/null
        source "${LIB_DIR}/core/nftban_mail.sh"
    fi
fi

# =============================================================================

# FHS COMMAND HANDLER
# =============================================================================

nftban_cmd_fhs() {
    # Handle FHS subcommands
    # Args: $@ = fhs subcommand and arguments

    local subcmd="${1:-status}"
    shift || true

    # Show banner for main commands (not help/json)
    if [[ "$subcmd" != "help" && "$subcmd" != "json" ]]; then
        if type -t nftban_banner >/dev/null 2>&1; then
            nftban_banner "fhs"
            echo ""
        fi
    fi

    case "$subcmd" in
        status|check|detailed|"")
            # Show FHS compliance status (terminal output - default detailed)
            # NOTE: 'check' is deprecated, use 'status' instead
            export NFTBAN_FHS_OUTPUT_FORMAT="table"
            local result=0
            nftban_fhs_report_status || result=$?
            return $result
            ;;

        summary)
            # Show one-line summary
            nftban_fhs_report_summary
            return $?
            ;;

        json)
            # Show JSON output
            nftban_fhs_report_json
            return $?
            ;;

        html-report)
            # Generate HTML report
            echo "Generating HTML FHS compliance report..."
            local report_file
            report_file=$(nftban_fhs_generate_html_report)
            if [[ $? -eq 0 && -f "$report_file" ]]; then
                echo "✓ HTML report generated successfully:"
                echo "  $report_file"
                echo
                echo "View with: firefox '$report_file' (or your preferred browser)"
                return 0
            else
                echo "ERROR: Failed to generate HTML report" >&2
                return 1
            fi
            ;;

        mail-report)
            # Mail FHS report
            # Args: [path] [recipient]
            local report_path="${1:-}"
            # Per-module override: NFTBAN_MAIL_REPORT_RECIPIENT, fallback: NFTBAN_MAIL_RECIPIENT
            local recipient="${2:-${NFTBAN_MAIL_REPORT_RECIPIENT:-${NFTBAN_MAIL_RECIPIENT:-}}}"

            # If no path and recipient is first arg (email pattern)
            if [[ -z "$recipient" && "$report_path" =~ @ ]]; then
                recipient="$report_path"
                report_path=""
            fi

            if [[ -z "$recipient" ]]; then
                echo "ERROR: No recipient specified" >&2
                echo "Set NFTBAN_MAIL_RECIPIENT (global) or NFTBAN_MAIL_REPORT_RECIPIENT (override)" >&2
                echo "Quick setup: nftban mail setup your@email.com" >&2
                echo "Usage: nftban fhs mail-report [path] [recipient]" >&2
                echo "   or: nftban fhs mail-report recipient@example.com" >&2
                return 1
            fi

            # Check if mail module is available
            if [[ ! $(type -t nftban_mail_send) == "function" ]]; then
                echo "ERROR: Mail module not available" >&2
                echo "Please ensure nftban_mail.sh is installed" >&2
                return 1
            fi

            # If path provided, mail that file
            if [[ -n "$report_path" ]]; then
                if [[ ! -f "$report_path" ]]; then
                    echo "ERROR: Report file not found: $report_path" >&2
                    return 1
                fi
                echo "Sending FHS report to $recipient..."
                nftban_mail_send "$report_path" "$recipient"
                return $?
            else
                # Generate report and mail it
                echo "Generating HTML report and sending to $recipient..."
                local report_file
                report_file=$(nftban_fhs_generate_html_report)
                if [[ $? -eq 0 && -f "$report_file" ]]; then
                    echo "✓ Report generated: $report_file"
                    echo "Sending via email..."
                    nftban_mail_send "$report_file" "$recipient"
                    return $?
                else
                    echo "ERROR: Failed to generate HTML report" >&2
                    return 1
                fi
            fi
            ;;

        help|--help|-h)
            # Show help
            # Load output module for standard banner
            source "${LIB_DIR}/core/nftban_output.sh"
            nftban_banner
            echo ""
            echo "Usage:"
            echo "  nftban fhs [detailed]            # Show FHS compliance (default)"
            echo "  nftban fhs summary               # Show one-line summary"
            echo "  nftban fhs json                  # Show JSON output"
            echo "  nftban fhs html-report           # Generate HTML report"
            echo "  nftban fhs mail-report [path] [recipient]  # Mail report"
            echo "  nftban fhs help                  # Show this help"
            echo ""
            echo "Examples:"
            echo "  nftban fhs                       # Show FHS compliance (FHS-style table)"
            echo "  nftban fhs summary               # Output: 'FHS: 5 OK, 12 errors, 3 missing'"
            echo "  nftban fhs json | jq .           # JSON output for parsing"
            echo "  nftban fhs mail-report admin@example.com"
            echo "  nftban fhs mail-report /var/lib/nftban/reports/fhs_report.html admin@example.com"
            echo ""
            echo "Output Columns:"
            echo "  DIRECTORY - Directory path"
            echo "  EXPECTED  - Expected permissions and ownership"
            echo "  ACTUAL    - Actual permissions and ownership"
            echo "  STATUS    - Compliance status (OK, ERROR, MISSING)"
            echo "  NOTES     - Additional information or issues"
            echo ""
            echo "Status Values:"
            echo "  ✔ OK      - Directory matches expected permissions/ownership"
            echo "  ✖ ERROR   - Permissions or ownership mismatch"
            echo "  ⚠ MISSING - Directory does not exist"
            echo ""
            echo "Checked Directories:"
            echo "  /usr/lib/nftban          - Application libraries (755 root:root)"
            echo "  /etc/nftban              - Configuration files (755 root:root)"
            echo "  /var/lib/nftban          - Application state (750 nftban:nftban)"
            echo "  /var/log/nftban          - Log files (750 nftban:nftban)"
            echo "  /var/cache/nftban        - Cache files (750 nftban:nftban)"
            echo "  /run/nftban              - Runtime data (755 nftban:nftban)"
            echo "  /usr/share/nftban        - Shared data (755 root:root)"
            echo ""
            echo "Notes:"
            echo "  - No special privileges required (reads permissions only)"
            echo "  - Checks against FHS (Filesystem Hierarchy Standard)"
            echo "  - Helps ensure proper security posture"
            echo ""
            return 0
            ;;

        *)
            echo "ERROR: Unknown fhs command: $subcmd" >&2
            echo "Run 'nftban fhs help' for available commands" >&2
            return 1
            ;;
    esac
}

# Export function for auto-loading
export -f nftban_cmd_fhs
