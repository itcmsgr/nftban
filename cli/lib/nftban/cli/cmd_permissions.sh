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
# NFTBan - Permissions CLI Handler
# =============================================================================

# SPDX-License-Identifier: MPL-2.0
# Purpose: CLI interface for permission management and auditing
#
# meta:name="cmd_permissions"
# meta:type="cli"
# meta:header="Permissions CLI Handler"
# meta:version="1.39.0"
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
    if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_permissions.sh" ]]; then
        source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_permissions.sh" || {
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
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
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
  nftban permissions check

  # Enforce secure permissions
  nftban permissions enforce

  # Preview changes without applying
  nftban permissions enforce --dry-run

SECURITY MODEL:
  /etc/nftban/*        → root:root, 0750/0640 (configs are code-sensitive!)
  /usr/lib/nftban/*    → root:root, 0755/0644 (immutable system code)
  /var/lib/nftban/*    → nftban:nftban, 0750 (mutable state data)
  ${NFTBAN_LOG_DIR}/*    → nftban:nftban, 0750 (log files)

NOTES:
  - This command requires elevated privileges (members of the nftban group are authorized via PolicyKit/polkit rules)
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
        echo "ERROR: PolicyKit/polkit authorization failed or insufficient privileges" >&2
        return 1
    fi

    # v1.143 PR-B (FS3-DA): rc-truth lock + actionable failure path.
    # The wrapper already returned $result truthfully — that is what
    # caused the lab4 v1.142 installer log to print
    # `permissions enforce failed (exit 1) — non-fatal` at
    # cmd/nftban-installer/phases.go:573. The installer auto-fix retry
    # intentionally classifies the warning as non-fatal and re-validates;
    # this v1.143 fix does NOT touch that consumer (operator-locked
    # SELECT_V1_143_INSTALL_UPDATE_SCOPE = permission-enforce-only). What
    # we DO change here:
    #   (a) the ❌ failure line now goes to STDERR (not stdout) so script
    #       consumers piping `nftban permissions enforce 2>/dev/null` get
    #       a clean STDOUT — same E1 contract v1.141 PR-B established for
    #       the unknown-command path.
    #   (b) actionable advice (log file location + retry instructions)
    #       follows the ❌ line, also on stderr. The advice helps the
    #       audit's R-PERM-1 follow-up: an operator reading the
    #       installer's swallowed "non-fatal" line now has a path to the
    #       same evidence the wrapper had.
    # (Scope: V1_143_0_PLAN.md §4 PR-B. Audit ref: V1_142_LAB4_UPDATE_LOG_
    # SAFETY_AUDIT.md §4 R-PERM-1.)
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
        # v1.143 PR-B: failure → stderr with actionable advice.
        {
            echo ""
            echo "❌ Permission enforcement failed with errors"
            echo "   See log: ${NFTBAN_LOG_DIR:-/var/log/nftban}/installer.log"
            echo "   Re-check: nftban permissions check"
            echo "   Re-run:   sudo nftban permissions enforce"
        } >&2
    fi

    return $result
}

# =============================================================================

# EXPORTS
# =============================================================================


# Exit marker for testing validation
command -v nftban_cmd_exit >/dev/null 2>&1 && nftban_cmd_exit "permissions"

export -f nftban_cmd_permissions
