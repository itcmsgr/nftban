#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - System Whitelist CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: System IP Whitelist Management
#
# meta:name="cmd_whitelist_system"
# meta:type="cli"
# meta:header="System Whitelist CLI Handler"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="CLI interface for system IP whitelist management and synchronization"
# meta:input="Whitelist commands and IP addresses"
# meta:output="Whitelist status and synchronization results"
# meta:depends="nftban_system_ip.sh,nftban_file_ops.sh"
#
# meta:inventory.files="/etc/nftban/whitelist.d/system.list"
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2025-11-05"
# meta:updated_date="2026-02-10"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# =============================================================================
# CONFIGURATION
# =============================================================================

# Inherit NFTBAN_LIB_DIR from parent script (cmd_whitelist.sh)
# Only set if not already defined (parent sets it as readonly)
: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"

# Load JSON helper for --json support
JSON_HELPER="${NFTBAN_LIB_DIR}/helpers/json_output.sh"
if [[ -f "$JSON_HELPER" ]]; then
    # shellcheck source=/dev/null
    source "$JSON_HELPER" || return 1
fi

# =============================================================================
# DEPENDENCIES
# =============================================================================

# Load system IP module
if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_system_ip.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/core/nftban_system_ip.sh" || return 1
else
    echo "ERROR: System IP module not found" >&2
    return 1
fi

# Load atomic file ops if available
if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_file_ops.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/core/nftban_file_ops.sh" || return 1
fi

# =============================================================================

# USAGE
# =============================================================================


show_usage() {
    cat <<'EOF'
Usage: nftban whitelist-system <command> [options]

COMMANDS:
  sync [options]    Auto-detect and whitelist all system IPs
  show              Show current system whitelist
  whitelistme       Whitelist your current IP (interactive)

OPTIONS:
  --quick             Skip public IP detection (faster, for package install)
  --protect-session   Also protect current SSH session IP (for upgrades/rebuilds)

EXAMPLES:
  # Auto-detect and protect all system IPs
  nftban whitelist-system sync

  # Quick sync (skip public IP HTTP lookups)
  nftban whitelist-system sync --quick

  # Package upgrade: protect admin SSH session + quick sync
  nftban whitelist-system sync --quick --protect-session

  # Show protected system IPs
  nftban whitelist-system show

  # Protect your current IP from being banned
  nftban whitelist-system whitelistme

WHAT IS AUTO-DETECTED:
  • Localhost (127.0.0.1, ::1)
  • All server interface IPs (IPv4 + IPv6)
  • Server public IPv4 (skipped with --quick)
  • Server public IPv6 (skipped with --quick)
  • Current SSH session IP (only with --protect-session)

SESSION PROTECTION (--protect-session):
  When specified, detects your current SSH connection IP and adds it
  to the whitelist BEFORE any firewall changes. Supports both IPv4
  and IPv6. Used by package upgrades to prevent admin lockout.

SAFE TO RUN:
  This command only ADDS IPs to whitelist, never removes them.
  It's safe to run multiple times (skips already whitelisted IPs).

EOF
}

# =============================================================================

# MAIN COMMAND HANDLER
# =============================================================================


nftban_cmd_whitelist_system() {
    # Main command handler for whitelist-system
    # Args: subcommand and options

    local subcommand="${1:-help}"
    shift || true

    # Check for --json flag in remaining args (suppress banner for JSON output)
    local json_mode=false
    for arg in "$@"; do
        [[ "$arg" == "--json" ]] && json_mode=true && break || true
    done

    # Show banner (skip for JSON output to avoid polluting machine-readable output)
    if [[ "$json_mode" == "false" ]]; then
        if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
            # shellcheck source=/dev/null
            source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
            if [[ $(type -t nftban_banner) == "function" ]]; then
                nftban_banner
            fi
        fi
        echo ""
    fi

    case "$subcommand" in
        sync)
            # Auto-detect and whitelist all system IPs
            # --quick: Skip public IP detection (faster, for postinst)
            # --protect-session: Protect current SSH session IP (for upgrades)
            # v1.19.22: Pass all args to sync function for proper flag parsing
            nftban_whitelist_system_sync "$@"
            ;;

        show|list)
            # Show current system whitelist
            # Pass through any additional arguments (like --json)
            nftban_show_system_whitelist "$@"
            ;;

        whitelistme)
            # Whitelist current user's IP
            nftban_whitelistme
            ;;

        help|--help|-h|"")
            show_usage
            return 0
            ;;

        *)
            # v1.144.0 PR-B UX-C2: 3-line ERROR/Hint/Run replaces the
            # full show_usage block on the unknown-subcommand parse
            # error path. The `nftban whitelist-system help` path
            # (above) still renders the full show_usage block.
            _v144_error_with_hint \
                "Unknown command: $subcommand" \
                "Valid subcommands: add, remove, list, init, whitelistme" \
                "nftban whitelist-system help"
            return $?
            ;;
    esac
}

# =============================================================================

# EXPORTS
# =============================================================================


export -f nftban_cmd_whitelist_system

# =============================================================================

# DIRECT EXECUTION SUPPORT (for backward compatibility)
# =============================================================================


# If executed directly (not sourced), run the command handler
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_whitelist_system "$@"
fi
