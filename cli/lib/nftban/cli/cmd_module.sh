#!/usr/bin/env bash

# =============================================================================

# Load JSON helper for --json support
[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"

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
JSON_HELPER="${NFTBAN_LIB_DIR}/helpers/json_output.sh"
if [[ -f "$JSON_HELPER" ]]; then
    # shellcheck source=/dev/null
    source "$JSON_HELPER" || return 1
fi
# NFTBan v1.0.0 - Module CLI Handler
# =============================================================================

# SPDX-License-Identifier: MPL-2.0
# Purpose: Handle module inventory CLI commands with validation
#
# meta:name="cmd_module"
# meta:type="cli"
# meta:header="Module CLI Command"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="CLI interface for module inventory and validation reporting"
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

# Load module report core module if not already loaded
if [[ ! $(type -t nftban_module_report_status) == "function" ]]; then
    if [[ -f "${LIB_DIR}/core/nftban_report_module.sh" ]]; then
        # shellcheck source=/dev/null
        source "${LIB_DIR}/core/nftban_report_module.sh" || return 1
    else
        echo "ERROR: nftban_report_module.sh not found at ${LIB_DIR}/core" >&2
        return 1
    fi
fi

# Load mail module for mail-report functionality
if [[ ! $(type -t nftban_mail_send) == "function" ]]; then
    if [[ -f "${LIB_DIR}/core/nftban_mail.sh" ]]; then
        # shellcheck source=/dev/null
        source "${LIB_DIR}/core/nftban_mail.sh" || return 1
    fi
fi

# =============================================================================
# HELP
# =============================================================================

nftban_cmd_module_help() {
    # Load output module for standard banner
    source "${LIB_DIR}/core/nftban_output.sh" || return 1
    nftban_banner
    echo ""
    echo "Usage:"
    echo "  nftban module [detailed] [--save FILE] [--email ADDR]  # Show inventory"
    echo "  nftban module summary                                   # One-line summary"
    echo "  nftban module json [--save FILE]                       # JSON output"
    echo "  nftban module validate [--save FILE] [--email ADDR]    # Metadata validation"
    echo "  nftban module license [--save FILE] [--email ADDR]     # License compliance"
    echo "  nftban module author [--save FILE] [--email ADDR]      # Author attribution"
    echo "  nftban module depends [--save FILE] [--email ADDR]     # Dependency analysis"
    echo "  nftban module html-report [--save FILE] [--email ADDR] # HTML report"
    echo "  nftban module mail-report [path] [recipient]           # Mail report"
    echo "  nftban module help                                      # Show this help"
    echo ""
    echo "NEW Validation Commands (v1.1.0):"
    echo "  validate   - Check metadata completeness (name, version, type, owner, license)"
    echo "  license    - Check license compliance (MPL-2.0 vs GPL vs missing)"
    echo "  author     - Check author attribution (Antonios Voulvoulis)"
    echo "  depends    - Analyze module dependencies"
    echo ""
    echo "NEW Flags:"
    echo "  --save FILE     Save output to specified file"
    echo "  --email ADDR    Email report to specified address"
    echo ""
    echo "Examples:"
    echo "  nftban module                          # Show all modules (table)"
    echo "  nftban module validate                 # Check metadata compliance"
    echo "  nftban module license                  # Find GPL scripts (should be MPL-2.0)"
    echo "  nftban module author                   # Find wrong/missing authors"
    echo "  nftban module depends                  # Analyze dependencies"
    echo ""
    echo "  # Save reports to files:"
    echo "  nftban module validate --save /tmp/validation.txt"
    echo "  nftban module license --save ${NFTBAN_LOG_DIR}/license_check.txt"
    echo ""
    echo "  # Email reports:"
    echo "  nftban module validate --email admin@example.com"
    echo "  nftban module html-report --email security@example.com"
    echo ""
    echo "  # Combined save and email:"
    echo "  nftban module author --save /tmp/authors.txt --email dev@example.com"
    echo ""
    echo "Output Columns:"
    echo "  NAME     - Module name (from meta:name)"
    echo "  VERSION  - Module version (from meta:version)"
    echo "  TYPE     - Module type (core, cli, util, etc.)"
    echo "  STATUS   - ENABLED or DISABLED"
    echo "  PATH     - File path (relative to /usr/lib/nftban)"
    echo ""
    echo "Validation Reports (INFORMATIONAL ONLY):"
    echo "  ✔ All validation commands are READ-ONLY"
    echo "  ✔ No files are modified"
    echo "  ✔ Reports show compliance issues for review"
    echo "  ✔ Standard: MPL-2.0 license, Antonios Voulvoulis author"
    echo ""
    echo "Notes:"
    echo "  - Scans all .sh files in /usr/lib/nftban/"
    echo "  - Reads meta tags from file headers"
    echo "  - Validation is informational only (no automatic fixes)"
    echo "  - No special privileges required"
    echo ""
}

# =============================================================================

# MODULE COMMAND HANDLER
# =============================================================================

nftban_cmd_module() {
    # Handle module subcommands
    # Args: $@ = module subcommand and arguments

    local subcmd="${1:-status}"
    shift || true

    # Parse flags for save/email
    local save_to_file=""
    local email_to=""
    
    # Check for --save and --email flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --save)
                save_to_file="${2:-}"
                shift 2 || shift
                ;;
            --email)
                email_to="${2:-}"
                shift 2 || shift
                ;;
            *)
                break
                ;;
        esac
    done

    case "$subcmd" in
        status|list|detailed|"")
            # Show module inventory (terminal output - default detailed)
            # "list" is backwards compatible alias for "status"

            # Show standard banner
            nftban_banner

            export NFTBAN_MODULE_OUTPUT_FORMAT="table"
            local result=0

            if [[ -n "$save_to_file" ]]; then
                nftban_module_report_status > "$save_to_file"
                result=$?
                if [[ $result -eq 0 ]]; then
                    echo "✓ Module report saved to: $save_to_file"
                fi
            else
                nftban_module_report_status || result=$?
            fi
            
            # Email if requested
            if [[ -n "$email_to" && $result -eq 0 ]]; then
                local report_file="${save_to_file:-$(mktemp -t nftban-module-report-XXXXXX.txt)}"
                if [[ -z "$save_to_file" ]]; then
                    nftban_module_report_status > "$report_file"
                fi
                nftban_mail_send "$report_file" "$email_to" && echo "✓ Report emailed to: $email_to"
            fi
            
            return $result
            ;;

        summary)
            # Show one-line summary
            local output
            output=$(nftban_module_report_summary)
            local result=$?
            
            if [[ -n "$save_to_file" ]]; then
                echo "$output" > "$save_to_file"
                echo "✓ Summary saved to: $save_to_file"
            else
                echo "$output"
            fi
            
            if [[ -n "$email_to" ]]; then
                local report_file="${save_to_file:-$(mktemp -t nftban-module-summary-XXXXXX.txt)}"
                [[ -z "$save_to_file" ]] && echo "$output" > "$report_file"
                nftban_mail_send "$report_file" "$email_to" && echo "✓ Summary emailed to: $email_to"
            fi

            return $result
            ;;

        json)
            # Show JSON output
            local result=0
            
            if [[ -n "$save_to_file" ]]; then
                nftban_module_report_json > "$save_to_file"
                result=$?
                [[ $result -eq 0 ]] && echo "✓ JSON report saved to: $save_to_file"
            else
                nftban_module_report_json || result=$?
            fi
            
            if [[ -n "$email_to" && $result -eq 0 ]]; then
                local report_file="${save_to_file:-$(mktemp -t nftban-module-report-XXXXXX.json)}"
                [[ -z "$save_to_file" ]] && nftban_module_report_json > "$report_file"
                nftban_mail_send "$report_file" "$email_to" && echo "✓ JSON emailed to: $email_to"
            fi

            return $result
            ;;

        validate)
            # NEW: Validate module metadata (INFORMATIONAL ONLY)
            echo "Running module metadata validation..."
            echo "Note: This is informational only. No files will be modified."
            echo
            
            local result=0
            
            if [[ -n "$save_to_file" ]]; then
                nftban_module_validate_metadata > "$save_to_file"
                result=$?
                [[ $result -eq 0 ]] && echo "✓ Validation report saved to: $save_to_file"
            else
                nftban_module_validate_metadata || result=$?
            fi
            
            if [[ -n "$email_to" && $result -eq 0 ]]; then
                local report_file="${save_to_file:-$(mktemp -t nftban-module-validation-XXXXXX.txt)}"
                [[ -z "$save_to_file" ]] && nftban_module_validate_metadata > "$report_file"
                nftban_mail_send "$report_file" "$email_to" && echo "✓ Validation emailed to: $email_to"
            fi

            return $result
            ;;

        license)
            # NEW: Check license compliance (INFORMATIONAL ONLY)
            echo "Running license compliance check..."
            echo "Note: This is informational only. No files will be modified."
            echo
            
            local result=0
            
            if [[ -n "$save_to_file" ]]; then
                nftban_module_check_license > "$save_to_file"
                result=$?
                [[ $result -eq 0 ]] && echo "✓ License report saved to: $save_to_file"
            else
                nftban_module_check_license || result=$?
            fi
            
            if [[ -n "$email_to" && $result -eq 0 ]]; then
                local report_file="${save_to_file:-$(mktemp -t nftban-module-license-XXXXXX.txt)}"
                [[ -z "$save_to_file" ]] && nftban_module_check_license > "$report_file"
                nftban_mail_send "$report_file" "$email_to" && echo "✓ License report emailed to: $email_to"
            fi

            return $result
            ;;

        duplicates)
            # NEW: Check for duplicate module names and version conflicts (INFORMATIONAL ONLY)
            echo "Running duplicate module and version conflict check..."
            echo "Note: This is informational only. No files will be modified."
            echo

            local result=0

            if [[ -n "$save_to_file" ]]; then
                nftban_module_check_duplicates > "$save_to_file"
                result=$?
                [[ $result -eq 0 ]] && echo "✓ Duplicate check report saved to: $save_to_file"
            else
                nftban_module_check_duplicates || result=$?
            fi

            if [[ -n "$email_to" && $result -eq 0 ]]; then
                local report_file="${save_to_file:-$(mktemp -t nftban-module-duplicates-XXXXXX.txt)}"
                [[ -z "$save_to_file" ]] && nftban_module_check_duplicates > "$report_file"
                nftban_mail_send "$report_file" "$email_to" && echo "✓ Duplicate check report emailed to: $email_to"
            fi

            return $result
            ;;

        author)
            # NEW: Check author attribution (INFORMATIONAL ONLY)
            echo "Running author attribution check..."
            echo "Note: This is informational only. No files will be modified."
            echo
            
            local result=0
            
            if [[ -n "$save_to_file" ]]; then
                nftban_module_check_author > "$save_to_file"
                result=$?
                [[ $result -eq 0 ]] && echo "✓ Author report saved to: $save_to_file"
            else
                nftban_module_check_author || result=$?
            fi
            
            if [[ -n "$email_to" && $result -eq 0 ]]; then
                local report_file="${save_to_file:-$(mktemp -t nftban-module-author-XXXXXX.txt)}"
                [[ -z "$save_to_file" ]] && nftban_module_check_author > "$report_file"
                nftban_mail_send "$report_file" "$email_to" && echo "✓ Author report emailed to: $email_to"
            fi

            return $result
            ;;

        depends)
            # NEW: Analyze module dependencies
            echo "Running dependency analysis..."
            echo
            
            local result=0
            
            if [[ -n "$save_to_file" ]]; then
                nftban_module_analyze_dependencies > "$save_to_file"
                result=$?
                [[ $result -eq 0 ]] && echo "✓ Dependency analysis saved to: $save_to_file"
            else
                nftban_module_analyze_dependencies || result=$?
            fi
            
            if [[ -n "$email_to" && $result -eq 0 ]]; then
                local report_file="${save_to_file:-$(mktemp -t nftban-module-depends-XXXXXX.txt)}"
                [[ -z "$save_to_file" ]] && nftban_module_analyze_dependencies > "$report_file"
                nftban_mail_send "$report_file" "$email_to" && echo "✓ Dependency analysis emailed to: $email_to"
            fi

            return $result
            ;;

        html-report)
            # Generate HTML report
            echo "Generating HTML module report..."
            local report_file
            report_file=$(nftban_module_generate_html_report)
            if [[ $? -eq 0 && -f "$report_file" ]]; then
                echo "✓ HTML report generated successfully:"
                echo "  $report_file"
                
                # If --save specified, copy to that location
                if [[ -n "$save_to_file" ]]; then
                    cp "$report_file" "$save_to_file"
                    echo "✓ Also saved to: $save_to_file"
                    report_file="$save_to_file"
                fi
                
                # If --email specified, send it
                if [[ -n "$email_to" ]]; then
                    nftban_mail_send "$report_file" "$email_to" && echo "✓ HTML report emailed to: $email_to"
                fi
                
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
            # Per-module override: NFTBAN_MAIL_REPORT_RECIPIENT, fallback: NFTBAN_MAIL_RECIPIENT
            local recipient="${2:-${NFTBAN_MAIL_REPORT_RECIPIENT:-${NFTBAN_MAIL_RECIPIENT:-}}}"

            # If no path and recipient is first arg (email pattern)
            if [[ -z "$recipient" && "$report_path" =~ @ ]]; then
                recipient="$report_path"
                report_path=""
            fi

            # --email flag takes precedence
            [[ -n "$email_to" ]] && recipient="$email_to"

            if [[ -z "$recipient" ]]; then
                echo "ERROR: No recipient specified" >&2
                echo "Set NFTBAN_MAIL_RECIPIENT (global) or NFTBAN_MAIL_REPORT_RECIPIENT (override)" >&2
                echo "Quick setup: nftban mail setup your@email.com" >&2
                echo "Usage: nftban module mail-report [path] [recipient]" >&2
                echo "   or: nftban module mail-report recipient@example.com" >&2
                echo "   or: nftban module mail-report --email recipient@example.com" >&2
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
                    
                    # Save if requested
                    [[ -n "$save_to_file" ]] && cp "$report_file" "$save_to_file" && echo "✓ Saved to: $save_to_file"
                    
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
            nftban_cmd_module_help
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
