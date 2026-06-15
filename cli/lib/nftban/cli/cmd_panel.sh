#!/usr/bin/env bash

# =============================================================================
# NFTBan - Panel CLI Handler
# =============================================================================
#
# SPDX-License-Identifier: MPL-2.0
# Purpose: Web hosting panel firewall integration and management
#
# meta:name="cmd_panel"
# meta:type="cli"
# meta:header="Panel CLI Command"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Manage web hosting panel firewall integration (DirectAdmin, cPanel, Plesk)"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================

# =============================================================================
# LOAD DEPENDENCIES
# =============================================================================

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

# Load JSON helper for --json support
JSON_HELPER="${NFTBAN_LIB_DIR}/helpers/json_output.sh"
if [[ -f "$JSON_HELPER" ]]; then
    # shellcheck source=/dev/null
    source "$JSON_HELPER" || return 1
fi

# Load NFT schema (single source of truth for table/set names)
# shellcheck source=/usr/lib/nftban/lib/nft_schema.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" || return 1
fi

# Load cmd_port.sh for DirectAdmin port configuration functions
if [[ -f "${NFTBAN_LIB_DIR}/cli/cmd_port.sh" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR}/cli/cmd_port.sh" || return 1
fi

# =============================================================================
# LOAD PANEL LIBRARIES
# =============================================================================

# Load common panel library (shared helpers and simple panel functions)
# shellcheck source=/usr/lib/nftban/lib/nftban_panel_common.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_panel_common.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_panel_common.sh" || return 1
fi

# Load DirectAdmin panel library
# shellcheck source=/usr/lib/nftban/lib/nftban_panel_directadmin.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_panel_directadmin.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_panel_directadmin.sh" || return 1
fi

# Load cPanel panel library
# shellcheck source=/usr/lib/nftban/lib/nftban_panel_cpanel.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_panel_cpanel.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_panel_cpanel.sh" || return 1
fi

# Load Plesk panel library
# shellcheck source=/usr/lib/nftban/lib/nftban_panel_plesk.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_panel_plesk.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_panel_plesk.sh" || return 1
fi

# =============================================================================
# MAIN COMMAND DISPATCHER
# =============================================================================

nftban_cmd_panel() {
    local panel="${1:-}"
    local action="${2:-}"
    local json_mode=false

    # Check for --json flag
    for arg in "$@"; do
        [[ "$arg" == "--json" ]] && json_mode=true && break || true
    done

    # Show banner (skip for JSON output)
    if [[ "$json_mode" != "true" ]]; then
        if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
            # shellcheck source=/dev/null
            source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
            if [[ $(type -t nftban_banner) == "function" ]]; then
                nftban_banner
            fi
        fi
        echo ""
    fi

    if [[ -z "$panel" ]]; then
        nftban_panel_help
        return 1
    fi

    # Normalize panel name
    case "$panel" in
        directadmin|da|DA|DirectAdmin)
            panel="directadmin"
            ;;
        cpanel|cp|CP|cPanel|CPANEL)
            panel="cpanel"
            ;;
        plesk|Plesk|PLESK|psa)
            panel="plesk"
            ;;
        cwp|CWP|centos-web-panel|centoswebpanel)
            panel="cwp"
            ;;
        cyberpanel|CyberPanel|CYBERPANEL|cyber)
            panel="cyberpanel"
            ;;
        interworx|InterWorx|INTERWORX|iworx)
            panel="interworx"
            ;;
        vesta|vestacp|VestaCP|VESTACP|hestia|hestiacp)
            panel="vesta"
            ;;
        help|-h|--help)
            nftban_panel_help
            return 0
            ;;
        *)
            echo "ERROR: Unknown panel: $panel" >&2
            echo "Run 'nftban panel help' for available panels" >&2
            return 1
            ;;
    esac

    if [[ -z "$action" ]]; then
        echo "ERROR: Action required" >&2
        echo "Usage: nftban panel $panel <action>" >&2
        echo "Actions: enable, disable, status, report, repair, test" >&2
        return 1
    fi

    # Route to panel-specific handler
    # C8 fix: validate function exists before dynamic dispatch to prevent crash
    local handler_func="nftban_panel_${panel}_${action}"
    case "$action" in
        enable|disable|status|report|repair|test)
            if ! declare -F "$handler_func" >/dev/null 2>&1; then
                echo "ERROR: Panel '$panel' does not support action '$action'" >&2
                echo "Function '$handler_func' not found" >&2
                return 1
            fi
            "$handler_func"
            ;;
        help|-h|--help)
            nftban_panel_help "$panel"
            ;;
        *)
            echo "ERROR: Unknown action: $action" >&2
            echo "Actions: enable, disable, status, report, repair, test" >&2
            return 1
            ;;
    esac
}

# =============================================================================
# HELP SYSTEM
# =============================================================================

nftban_panel_help() {
    local panel="${1:-}"

    if [[ -n "$panel" ]]; then
        # Panel-specific help
        case "$panel" in
            directadmin)
                nftban_panel_directadmin_help
                ;;
            cpanel)
                nftban_panel_cpanel_help
                ;;
            plesk)
                nftban_panel_plesk_help
                ;;
            cwp|cyberpanel|interworx|vesta)
                nftban_panel_simple_help "$panel"
                ;;
        esac
        return 0
    fi

    cat <<'EOF'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
NFTBan Panel Integration - Control Panel Firewall Management
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Usage:
  nftban panel <panel_name> <action>

Supported Panels:
  directadmin (da)    - DirectAdmin Control Panel
  cpanel (cp)         - cPanel/WHM Control Panel
  plesk               - Plesk Control Panel
  cwp                 - CentOS Web Panel (CWP)
  cyberpanel          - CyberPanel (OpenLiteSpeed)
  interworx           - InterWorx Control Panel
  vesta               - VestaCP / HestiaCP

Actions:
  enable              - Enable panel ports in firewall
  disable             - Disable panel ports in firewall
  status              - Show panel port configuration status
  report              - Generate diagnostic report
  repair              - Fix configuration issues
  test                - Test panel connectivity

Examples:
  nftban panel directadmin enable      # Enable DirectAdmin ports
  nftban panel cpanel enable           # Enable cPanel/WHM ports
  nftban panel plesk enable            # Enable Plesk ports
  nftban panel cwp enable              # Enable CWP ports
  nftban panel cyberpanel enable       # Enable CyberPanel ports
  nftban panel interworx enable        # Enable InterWorx ports
  nftban panel vesta enable            # Enable VestaCP ports
  nftban panel plesk status            # Check Plesk configuration
  nftban panel directadmin test        # Test DirectAdmin connectivity

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================

export -f nftban_cmd_panel
export -f nftban_panel_help
