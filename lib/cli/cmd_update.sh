#!/usr/bin/env bash

# =============================================================================
# NFTBan CLI - Update Command
# Version: 1.0.0
# Location: lib/cli/cmd_update.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Dependencies: nftban_update_module.sh
# Description: System update and version management
# =============================================================================

# Strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# =============================================================================
# UPDATE COMMAND HANDLER
# =============================================================================

cmd_update() {
    local action="${1:-check}"
    shift || true

    case "$action" in
        check)
            nftban_check_root || exit 1
            nftban_update_check "true"
            ;;
        perform|upgrade|install)
            nftban_check_root || exit 1
            nftban_update_perform "false"
            ;;
        auto)
            nftban_check_root || exit 1
            nftban_update_perform "true"  # Skip confirmation
            ;;
        rollback)
            nftban_check_root || exit 1
            nftban_log_warning "Rolling back to previous version..."
            nftban_update_rollback "$1"
            ;;
        version)
            echo "Current version: $(nftban_update_get_local_version)"
            if remote_ver=$(nftban_update_get_remote_version 2>/dev/null); then
                echo "Available version: $remote_ver"
            fi
            ;;
        pin)
            nftban_check_root || exit 1
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban update pin <commit-sha>"; exit 1; }
            nftban_update_set_commit_pin "$1"
            ;;
        show-commit|show-pin)
            echo "Pinned commit:"
            local pinned
            pinned=$(nftban_update_get_pinned_commit)
            if [[ -n "$pinned" ]]; then
                echo "  $pinned"
                echo "  https://github.com/itcmsgr/nftban/commit/$pinned"
            else
                echo "  (not configured - updates disabled)"
            fi
            echo ""
            echo "Remote commit:"
            if remote_sha=$(nftban_update_get_remote_commit_sha 2>/dev/null); then
                echo "  $remote_sha"
                echo "  https://github.com/itcmsgr/nftban/commit/$remote_sha"
            else
                echo "  (failed to fetch)"
            fi
            ;;
        *)
            nftban_log_error "Unknown update action: $action"
            echo ""
            echo "Available actions:"
            echo "  check                   Check for available updates"
            echo "  perform                 Perform update (with confirmation)"
            echo "  auto                    Perform update (no confirmation)"
            echo "  rollback [DIR]          Rollback to previous version"
            echo "  version                 Show current and available versions"
            echo "  pin <commit-sha>        Pin updates to specific commit (security)"
            echo "  show-commit             Show pinned and remote commit SHAs"
            echo ""
            echo "Security (Commit Pinning):"
            echo "  Updates are verified against a pinned git commit SHA"
            echo "  This prevents man-in-the-middle attacks and compromises"
            echo ""
            echo "Examples:"
            echo "  nftban update show-commit           # Show current commits"
            echo "  sudo nftban update pin <sha>        # Pin to trusted commit"
            echo "  nftban update check                 # Check for updates"
            echo "  sudo nftban update perform          # Perform update"
            echo ""
            exit 1
            ;;
    esac
}

# Export function
export -f cmd_update
