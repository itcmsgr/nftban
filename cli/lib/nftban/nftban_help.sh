#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.12.5 - Help System Wrapper
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Wrapper for generate-help.sh (single source of truth)
#
# This file delegates to scripts/generate-help.sh which reads from
# commands.registry.yml. ONE implementation, no duplication.
#
# meta:name="nftban_help"
# meta:type="module"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2025-11-05"
# meta:updated_date="2026-02-10"
#
# meta:description="Wrapper that calls generate-help.sh for CLI help"
# meta:input="None (called from main router)"
# meta:output="Formatted help text from generate-help.sh"
# meta:depends="bash,generate-help.sh"
#
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"

set -Eeuo pipefail

# =============================================================================
# HELP WRAPPER
# =============================================================================

nftban_print_help() {
    # Delegates to generate-help.sh for all help output
    # Single source of truth: commands.registry.yml

    # Show unified banner if function available
    if type -t nftban_banner >/dev/null 2>&1; then
        nftban_banner "help"
        echo ""
    fi

    # Find generate-help.sh
    local help_script=""

    # 1. Installed location
    if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/scripts/generate-help.sh" ]]; then
        help_script="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/scripts/generate-help.sh"
    # 2. Development location (relative to this script)
    elif [[ -f "${BASH_SOURCE[0]%/*}/../../../scripts/generate-help.sh" ]]; then
        help_script="$(cd "${BASH_SOURCE[0]%/*}/../../../scripts" && pwd)/generate-help.sh"
    # 3. Try common paths
    elif [[ -f "/opt/nftban/scripts/generate-help.sh" ]]; then
        help_script="/opt/nftban/scripts/generate-help.sh"
    fi

    if [[ -n "$help_script" ]] && [[ -f "$help_script" ]]; then
        # Use generate-help.sh (single implementation)
        bash "$help_script" --profile operator
    else
        # Minimal fallback
        _nftban_help_minimal
    fi
}

# =============================================================================
# MINIMAL FALLBACK (when generate-help.sh unavailable)
# =============================================================================

# v1.19.21 FIX: Document exit codes (E2)
_nftban_help_minimal() {
    cat <<'EOF'
USAGE:
  nftban <command> [subcommand] [options]

CORE COMMANDS:
  status      System status overview
  health      Diagnostics and auto-repair
  ban         Ban an IP address
  unban       Remove IP ban
  list        List banned/whitelisted IPs
  search      Search IP across all sets
  firewall    Firewall management
  feeds       Threat intelligence feeds
  help        Show full help

EXIT CODES:
  0  Success   - Command completed without errors
  1  Error     - Command failed (check stderr for details)
  2  Warning   - Command completed with warnings (e.g., missing deps)

Run 'nftban <command> help' for command-specific help.

Documentation: https://github.com/itcmsgr/nftban/wiki
EOF
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_print_help
export -f _nftban_help_minimal

# =============================================================================
# DIRECT EXECUTION
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    nftban_print_help
fi
