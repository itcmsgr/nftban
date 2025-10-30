#!/usr/bin/env bash

# =============================================================================
# NFTBan CLI - Module Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Handle module inventory CLI commands
#
# meta:name=cmd_module
# meta:type=cli
# meta:header=Module CLI Command
# meta:version=1.0.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=CLI interface for module inventory reporting
# meta:input=Output format, mail options
# meta:output=Module inventory reports (terminal, HTML, mail)
#
# **Inventory & Requirements**
# meta:depends=bash,nftban_report_module.sh
#
# meta:created_date=2025-10-26
# =============================================================================

# Strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Load dependencies
SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
LIB_DIR="$(dirname "$SCRIPT_DIR")"

# Load module report core module if not already loaded
if [[ ! $(type -t nftban_module_report_status) == "function" ]]; then
    if [[ -f "${LIB_DIR}/core/nftban_report_module.sh" ]]; then
        # shellcheck source=/dev/null
        source "${LIB_DIR}/core/nftban_report_module.sh"
    else
        echo "ERROR: nftban_report_module.sh not found at ${LIB_DIR}/core" >&2
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
# MODULE COMMAND HANDLER
# =============================================================================

nftban_cmd_module() {
    # Handle module subcommands
    # Args: $@ = module subcommand and arguments

    local subcmd="${1:-status}"
    shift || true

    case "$subcmd" in
        status|list|detailed|"")
            # Show module inventory (terminal output - default detailed)
            # "list" is backwards compatible alias for "status"
            export NFTBAN_MODULE_OUTPUT_FORMAT="table"
            local result=0
            nftban_module_report_status || result=$?
            return $result
            ;;

        summary)
            # Show one-line summary
            nftban_module_report_summary
            return $?
            ;;

        json)
            # Show JSON output
            nftban_module_report_json
            return $?
            ;;

        html-report)
            # Generate HTML report
            echo "Generating HTML module report..."
            local report_file
            report_file=$(nftban_module_generate_html_report)
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
            # Mail module report
            # Args: [path] [recipient]
            local report_path="${1:-}"
            local recipient="${2:-${NFTBAN_MAIL_REPORT_RECIPIENT:-}}"

            # If no path and recipient is first arg (email pattern)
            if [[ -z "$recipient" && "$report_path" =~ @ ]]; then
                recipient="$report_path"
                report_path=""
            fi

            if [[ -z "$recipient" ]]; then
                echo "ERROR: No recipient specified" >&2
                echo "Set NFTBAN_MAIL_REPORT_RECIPIENT in config or provide recipient as argument" >&2
                echo "Usage: nftban module mail-report [path] [recipient]" >&2
                echo "   or: nftban module mail-report recipient@example.com" >&2
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
                echo "Sending module report to $recipient..."
                nftban_mail_send "$report_path" "$recipient"
                return $?
            else
                # Generate report and mail it
                echo "Generating HTML report and sending to $recipient..."
                local report_file
                report_file=$(nftban_module_generate_html_report)
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
            echo "  nftban module [detailed]         # Show module inventory (default)"
            echo "  nftban module summary            # Show one-line summary"
            echo "  nftban module json               # Show JSON output"
            echo "  nftban module html-report        # Generate HTML report"
            echo "  nftban module mail-report [path] [recipient]  # Mail report"
            echo "  nftban module help               # Show this help"
            echo ""
            echo "Examples:"
            echo "  nftban module                    # Show all modules (FHS-style table)"
            echo "  nftban module summary            # Output: 'Modules: 23 OK, 0 errors'"
            echo "  nftban module json | jq .        # JSON output for parsing"
            echo "  nftban module mail-report admin@example.com"
            echo "  nftban module mail-report /var/lib/nftban/reports/module_report.html admin@example.com"
            echo ""
            echo "Output Columns:"
            echo "  NAME     - Module name (from meta:name)"
            echo "  VERSION  - Module version (from meta:version)"
            echo "  TYPE     - Module type (core, cli, util, etc.)"
            echo "  STATUS   - ENABLED or DISABLED"
            echo "  CREATED  - Creation date (from meta:created_date)"
            echo "  PATH     - File path (relative to /usr/lib/nftban)"
            echo ""
            echo "Detailed Mode Shows:"
            echo "  - All meta tags for each module"
            echo "  - Dependencies (meta:depends)"
            echo "  - Owner information (meta:owner)"
            echo "  - Homepage (meta:homepage)"
            echo "  - Description (meta:description)"
            echo ""
            echo "Status Detection:"
            echo "  ✔ ENABLED  - Module is in core/ or cli/ directory"
            echo "  ✖ DISABLED - Module is not actively loaded"
            echo ""
            echo "Notes:"
            echo "  - Scans all .sh files in /usr/lib/nftban/"
            echo "  - Reads meta tags from file headers"
            echo "  - No special privileges required"
            echo ""
            return 0
            ;;

        *)
            echo "ERROR: Unknown module command: $subcmd" >&2
            echo "Run 'nftban module help' for available commands" >&2
            return 1
            ;;
    esac
}

# Export function for auto-loading
export -f nftban_cmd_module
