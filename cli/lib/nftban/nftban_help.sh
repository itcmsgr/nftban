#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.12.5 - Grouped Help System (Registry-Based)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Generate grouped help output from commands.registry.yml
#
# This file uses the central registry as the SINGLE SOURCE OF TRUTH.
# No hardcoded help content - everything is generated from:
#   - /etc/nftban/commands.registry.yml (installed)
#   - commands.registry.yml (development)
#
# meta:name="nftban_help"
# meta:type="module"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2025-11-05"
# meta:updated_date="2026-02-10"
#
# meta:description="Provides grouped, categorized help output from central registry"
# meta:input="None (called from main router)"
# meta:output="Formatted help text with categories"
# meta:depends="bash,yq,commands.registry.yml"
#
# meta:inventory.files="commands.registry.yml"
# meta:inventory.binaries="yq"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"

set -Eeuo pipefail

# =============================================================================
# REGISTRY LOCATION
# =============================================================================

_nftban_find_registry() {
    # Find commands.registry.yml (installed or development)
    local registry=""

    # 1. Installed location (FHS compliant)
    if [[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/commands.registry.yml" ]]; then
        registry="${NFTBAN_CONFIG_DIR:-/etc/nftban}/commands.registry.yml"
    # 2. Development location (relative to this script)
    elif [[ -f "${BASH_SOURCE[0]%/*}/../../../commands.registry.yml" ]]; then
        registry="$(cd "${BASH_SOURCE[0]%/*}/../../../" && pwd)/commands.registry.yml"
    # 3. Try project root
    elif [[ -f "/opt/nftban/commands.registry.yml" ]]; then
        registry="/opt/nftban/commands.registry.yml"
    fi

    echo "$registry"
}

# =============================================================================
# GROUPED HELP RENDERER (FROM REGISTRY)
# =============================================================================

nftban_print_help() {
    # Renders grouped help menu from central registry
    # Categories: CORE, FIREWALL & SECURITY, PROTECTION MODULES, etc.
    # Uses tput for bold formatting if available (graceful fallback)

    local have_tput=0; command -v tput >/dev/null 2>&1 && have_tput=1
    local bold='' reset=''
    if [[ $have_tput -eq 1 ]] && [[ -t 1 ]]; then
        bold="$(tput bold)"
        reset="$(tput sgr0)"
    fi

    # Show unified banner if function available
    if type -t nftban_banner >/dev/null 2>&1; then
        nftban_banner "help"
        echo ""
    fi

    # Find registry
    local registry
    registry=$(_nftban_find_registry)

    # Check if we can use registry-based help
    if [[ -n "$registry" ]] && [[ -f "$registry" ]] && command -v yq &>/dev/null; then
        _nftban_help_from_registry "$registry" "$bold" "$reset"
    else
        # Fallback: minimal help when yq/registry not available
        _nftban_help_fallback "$bold" "$reset"
    fi
}

# =============================================================================
# REGISTRY-BASED HELP GENERATION
# =============================================================================

_nftban_help_from_registry() {
    local registry="$1"
    local bold="$2"
    local reset="$3"

    echo "USAGE:"
    echo "  nftban <command> [subcommand] [options]"
    echo

    # Category definitions
    declare -A CATEGORY_NAMES=(
        ["setup_discovery"]="SETUP & DISCOVERY"
        ["immediate_action"]="IMMEDIATE ACTION"
        ["active_protection"]="ACTIVE PROTECTION"
        ["infrastructure"]="INFRASTRUCTURE"
        ["intelligence_reporting"]="MONITORING & REPORTING"
        ["developer_sysadmin"]="DEBUG & DEVELOPMENT"
    )

    # Order of categories
    local categories=("setup_discovery" "immediate_action" "active_protection" "infrastructure" "intelligence_reporting" "developer_sysadmin")

    for category in "${categories[@]}"; do
        local cat_name="${CATEGORY_NAMES[$category]}"

        # Get commands for this category
        local commands
        commands=$(yq -r "
            to_entries |
            map(select(.key != \"_metadata\" and .key != \"global_options\" and .key != \"standard_params\" and .value.category == \"$category\")) |
            map(.key) | .[]
        " "$registry" 2>/dev/null) || continue

        [[ -z "$commands" ]] && continue

        printf "%s%s:%s\n" "$bold" "$cat_name" "$reset"

        # Print each command with description
        while read -r cmd; do
            [[ -z "$cmd" ]] && continue
            local desc
            desc=$(yq -r ".\"$cmd\".description // \"\"" "$registry" 2>/dev/null)
            printf "  %-20s %s\n" "$cmd" "$desc"
        done <<< "$commands"

        echo
    done

    # Footer with tips
    _nftban_help_footer "$bold" "$reset"
}

# =============================================================================
# FALLBACK HELP (when registry/yq unavailable)
# =============================================================================

_nftban_help_fallback() {
    local bold="$1"
    local reset="$2"

    echo "USAGE:"
    echo "  nftban <command> [subcommand] [options]"
    echo

    printf "%sNOTE:%s Registry-based help requires yq. Install with:\n" "$bold" "$reset"
    echo "  pip install yq   OR   dnf install yq   OR   apt install yq"
    echo

    printf "%sCORE COMMANDS:%s\n" "$bold" "$reset"
    cat <<'EOF'
  status           Show global system status
  health           System diagnostics and auto-repair
  validate         Firewall structure validation
  version          Show version information
  help             Show this help

  ban              Ban an IP address
  unban            Remove IP ban
  list             List banned/whitelisted IPs
  search           Search IP across all sets

  firewall         Firewall management
  feeds            Threat intelligence feeds
  geoban           Geographic IP blocking
  login            SSH login monitoring
  portscan         Port scan detection
  ddos             DDoS protection

  stats            Statistics and analytics
  health           System health check
  config           Configuration management
EOF
    echo

    _nftban_help_footer "$bold" "$reset"
}

# =============================================================================
# HELP FOOTER
# =============================================================================

_nftban_help_footer() {
    local bold="$1"
    local reset="$2"

    printf "%sTIPS:%s\n" "$bold" "$reset"
    cat <<'EOF'
  • Quick start:    nftban status && nftban health
  • Interactive:    nftban menu (TUI mode)
  • Tab-complete:   Use TAB to auto-complete commands
  • JSON output:    Add --json for machine-readable output
  • Per-command:    nftban <command> help
EOF
    echo

    printf "%sGLOBAL OPTIONS:%s\n" "$bold" "$reset"
    cat <<'EOF'
  --help, -h       Show command help
  --json, -j       Output in JSON format
  --quiet, -q      Suppress informational messages
  --verbose        Enable verbose output
  --dry-run        Preview changes without executing
  --force, -f      Skip confirmation prompts
EOF
    echo

    printf "%sDOCUMENTATION:%s\n" "$bold" "$reset"
    echo "  Wiki:   https://github.com/itcmsgr/nftban/wiki"
    echo "  Issues: https://github.com/itcmsgr/nftban/issues"
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_print_help
export -f _nftban_find_registry
export -f _nftban_help_from_registry
export -f _nftban_help_fallback
export -f _nftban_help_footer

# =============================================================================
# DIRECT EXECUTION SUPPORT
# =============================================================================

# If executed standalone (for testing)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    nftban_print_help
fi
