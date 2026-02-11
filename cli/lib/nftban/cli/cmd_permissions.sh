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
# NFTBan v1.0.0 - Permissions CLI Handler
# =============================================================================

# SPDX-License-Identifier: MPL-2.0
# Purpose: CLI interface for permission management and auditing
#
# meta:name="cmd_permissions"
# meta:type="cli"
# meta:header="Permissions CLI Handler"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="CLI interface for permission management and auditing"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2025-11-05"
# meta:updated_date="2025-11-24"
# =============================================================================


# Enhanced strict mode
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_CLI_PERMISSIONS_LOADED:-}" ]] && return 0
readonly NFTBAN_CLI_PERMISSIONS_LOADED=1

# =============================================================================

# LOAD DEPENDENCIES
# =============================================================================


# Load permissions module
if ! declare -f nftban_permissions_enforce_all >/dev/null 2>&1; then
    if [[ -f "/usr/lib/nftban/core/nftban_permissions.sh" ]]; then
        source "/usr/lib/nftban/core/nftban_permissions.sh" || {
            echo "ERROR: Failed to load permissions module" >&2
            return 1
        }
    else
        echo "ERROR: Permissions module not found" >&2
        return 1
    fi
fi

# =============================================================================

# MAIN CLI HANDLER
# =============================================================================


nftban_cmd_permissions() {
    # Main permissions command handler
    # Usage: nftban permissions [subcommand] [options]

    local subcommand="${1:-help}"

    # Show banner
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"
        if [[ $(type -t nftban_banner) == "function" ]]; then
            nftban_banner
        fi
    fi
    echo ""

    case "$subcommand" in
        help|--help|-h)
            nftban_permissions_cmd_help
            return 0
            ;;
        check)
            shift || true
            nftban_permissions_cmd_check "$@"
            ;;
        enforce|fix)
            shift || true
            nftban_permissions_cmd_enforce "$@"
            ;;
        *)
            echo "ERROR: Unknown permissions command: $subcommand" >&2
            echo "Run 'nftban permissions help' for usage information" >&2
            return 1
            ;;
    esac
}

# =============================================================================

# SUBCOMMAND: HELP
# =============================================================================


nftban_permissions_cmd_help() {
    cat <<'EOF'
Usage: nftban permissions <subcommand> [options]

Manage and audit file permissions and ownership for NFTBan.

SUBCOMMANDS:
  check                Check current permissions and report issues
  enforce, fix         Enforce secure permissions on all NFTBan files
  help                 Show this help message

OPTIONS:
  --dry-run           Show what would be changed without making changes

EXAMPLES:
  # Check current permissions
  sudo nftban permissions check

  # Enforce secure permissions
  sudo nftban permissions enforce

  # Preview changes without applying
  sudo nftban permissions enforce --dry-run

SECURITY MODEL:
  /etc/nftban/*        → root:root, 0750/0640 (configs are code-sensitive!)
  /usr/lib/nftban/*    → root:root, 0755/0644 (immutable system code)
  /var/lib/nftban/*    → nftban:nftban, 0750 (mutable state data)
  /var/log/nftban/*    → nftban:nftban, 0750 (log files)

NOTES:
  - This command requires root privileges
  - Permissions are automatically enforced during FHS auto-heal
  - Regular permission audits run via 'nftban health check'

For more information, see: nftban health help
EOF
}

# =============================================================================

# SUBCOMMAND: CHECK
# =============================================================================


nftban_permissions_cmd_check() {
    # Check current permissions
    # Args: options

    echo "NFTBan Permission Audit"
    echo "======================="
    echo ""

    local result=0
    nftban_permissions_check || result=$?

    return $result
}

# =============================================================================

# SUBCOMMAND: ENFORCE
# =============================================================================


nftban_permissions_cmd_enforce() {
    # Enforce secure permissions
    # Args: options

    local dry_run=0

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                dry_run=1
                shift
                ;;
            *)
                echo "ERROR: Unknown option: $1" >&2
                return 1
                ;;
        esac
    done

    # Set dry-run mode
    export PERMS_DRYRUN=$dry_run

    if [[ $dry_run == 1 ]]; then
        echo "NFTBan Permission Enforcement (DRY-RUN MODE)"
        echo "============================================="
        echo ""
        echo "⚠️  DRY-RUN: No changes will be made"
        echo ""
    else
        echo "NFTBan Permission Enforcement"
        echo "============================="
        echo ""
    fi

    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: This command must be run as root" >&2
        return 1
    fi

    # Run enforcement
    local result=0
    nftban_permissions_enforce_all || result=$?

    if [[ $result -eq 0 ]]; then
        if [[ $dry_run == 1 ]]; then
            echo ""
            echo "✅ DRY-RUN completed successfully"
            echo "   Run without --dry-run to apply changes"
        else
            echo ""
            echo "✅ Permissions enforced successfully"
        fi
    else
        echo ""
        echo "❌ Permission enforcement failed with errors"
    fi

    return $result
}

# =============================================================================

# EXPORTS
# =============================================================================


# Exit marker for testing validation
command -v nftban_cmd_exit >/dev/null 2>&1 && nftban_cmd_exit "permissions"

export -f nftban_cmd_permissions
