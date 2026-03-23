#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Profile CLI Handler (Wizard Redirect)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cmd_profile"
# meta:type="cli"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2025-11-05"
# meta:description="CLI handler that redirects profile commands to wizard"
# meta:input="Command line arguments (select, apply, show, list, help)"
# meta:output="Redirects to wizard or shows current config"
# meta:depends="bash"
# meta:platform="linux"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_CONFIG_LOCAL"
# meta:inventory.config_files="/etc/nftban/nftban.conf.local"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# Static profiles have been replaced by an interactive wizard in v1.0.
# The wizard detects your environment and asks 3 simple questions to
# configure NFTBan optimally for your server.
# =============================================================================

# Load strict mode library
[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"

# shellcheck source=/usr/lib/nftban/lib/strict.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/strict.sh" || return 1
else
    set -Eeuo pipefail
fi

# Load version library
# shellcheck source=/usr/lib/nftban/lib/version.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/version.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/version.sh" || return 1
fi

# =============================================================================
# CONFIGURATION
# =============================================================================

readonly NFTBAN_CONFIG_LOCAL="${NFTBAN_CONFIG_LOCAL:-/etc/nftban/nftban.conf.local}"
readonly NFTBAN_CONFIG_MAIN="${NFTBAN_CONFIG_MAIN:-/etc/nftban/nftban.conf}"

# =============================================================================
# BANNER
# =============================================================================

_nftban_profile_banner() {
    # Load output module for standard banner
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
        nftban_banner
    else
        echo "╔════════════════════════════════════════════════════════════╗"
        echo "║  NFTBan - Enterprise Firewall Security                     ║"
        echo "╚════════════════════════════════════════════════════════════╝"
    fi
}

# =============================================================================
# DEPRECATION NOTICE
# =============================================================================

_nftban_profile_deprecated_notice() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  📢 NOTICE: Static profiles replaced by Interactive Wizard"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  In NFTBan v1.0, static profiles have been replaced with an"
    echo "  interactive wizard that:"
    echo ""
    echo "    • Auto-detects your environment (CPU, RAM, ports)"
    echo "    • Asks only 3 simple questions"
    echo "    • Configures optimal settings for your server"
    echo ""
    echo "  Run the wizard:"
    echo "    sudo nftban wizard"
    echo ""
}

# =============================================================================
# SHOW CURRENT CONFIGURATION
# =============================================================================

_nftban_profile_show() {
    _nftban_profile_banner
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  📊 Current Configuration"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Check if wizard-generated config exists
    if [[ -f "$NFTBAN_CONFIG_LOCAL" ]]; then
        echo "Configuration file: $NFTBAN_CONFIG_LOCAL"
        echo ""

        # Show configured by
        if grep -q "^# Configured by: NFTBan Wizard" "$NFTBAN_CONFIG_LOCAL" 2>/dev/null; then
            echo "Configured by: NFTBan Wizard v1.0"
            local config_date
            config_date=$(grep "^# Timestamp:" "$NFTBAN_CONFIG_LOCAL" 2>/dev/null | cut -d':' -f2- | xargs || echo "Unknown")
            echo "Configured on: $config_date"
        else
            echo "Configured by: Manual configuration"
        fi

        echo ""
        echo "Key Settings:"

        # Extract settings from config
        local setting_value

        # Login Monitor
        if grep -q "^LOGIN_MONITOR_ENABLED=" "$NFTBAN_CONFIG_LOCAL" 2>/dev/null; then
            setting_value=$(grep "^LOGIN_MONITOR_ENABLED=" "$NFTBAN_CONFIG_LOCAL" | cut -d'"' -f2)
            echo "  Login Monitor: $setting_value"
        fi

        # DDoS Protection
        if grep -q "^DDOS_PROTECTION_ENABLED=" "$NFTBAN_CONFIG_LOCAL" 2>/dev/null; then
            setting_value=$(grep "^DDOS_PROTECTION_ENABLED=" "$NFTBAN_CONFIG_LOCAL" | cut -d'"' -f2)
            echo "  DDoS Protection: $setting_value"
        fi

        # Port Scan Detection
        if grep -q "^PORTSCAN_ENABLED=" "$NFTBAN_CONFIG_LOCAL" 2>/dev/null; then
            setting_value=$(grep "^PORTSCAN_ENABLED=" "$NFTBAN_CONFIG_LOCAL" | cut -d'"' -f2)
            echo "  Port Scan Detection: $setting_value"
        fi

        # Threat Feeds
        if grep -q "^NFTBAN_FEEDS_ENABLED=" "$NFTBAN_CONFIG_LOCAL" 2>/dev/null; then
            setting_value=$(grep "^NFTBAN_FEEDS_ENABLED=" "$NFTBAN_CONFIG_LOCAL" | cut -d'"' -f2)
            echo "  Threat Feeds: $setting_value"
            if [[ "$setting_value" == "yes" ]]; then
                local enabled_feeds
                enabled_feeds=$(grep "^NFTBAN_FEEDS_ENABLED_LIST=" "$NFTBAN_CONFIG_LOCAL" 2>/dev/null | cut -d'"' -f2 || echo "")
                [[ -n "$enabled_feeds" ]] && echo "  Enabled Feeds: $enabled_feeds"
            fi
        fi

        # Suricata IDS
        if grep -q "^SURICATA_ENABLED=" "$NFTBAN_CONFIG_LOCAL" 2>/dev/null; then
            setting_value=$(grep "^SURICATA_ENABLED=" "$NFTBAN_CONFIG_LOCAL" | cut -d'"' -f2)
            echo "  Suricata IDS: $setting_value"
        fi

        # Metrics Exporter
        if grep -q "^METRICS_EXPORTER_ENABLED=" "$NFTBAN_CONFIG_LOCAL" 2>/dev/null; then
            setting_value=$(grep "^METRICS_EXPORTER_ENABLED=" "$NFTBAN_CONFIG_LOCAL" | cut -d'"' -f2)
            echo "  Metrics Exporter: $setting_value"
        fi

        # Web UI
        if grep -q "^UI_ENABLED=" "$NFTBAN_CONFIG_LOCAL" 2>/dev/null; then
            setting_value=$(grep "^UI_ENABLED=" "$NFTBAN_CONFIG_LOCAL" | cut -d'"' -f2)
            echo "  Web UI: $setting_value"
        fi
    else
        echo "No configuration file found at: $NFTBAN_CONFIG_LOCAL"
        echo ""
        echo "Run the wizard to configure NFTBan:"
        echo "  sudo nftban wizard"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "To reconfigure, run: sudo nftban wizard"
    echo ""

    return 0
}

# =============================================================================
# HELP TEXT
# =============================================================================

_nftban_profile_help() {
    _nftban_profile_banner
    _nftban_profile_deprecated_notice

    cat <<'HELP'
USAGE:
    nftban profile <command>

COMMANDS:
    show                Show current configuration
    help                Show this help message

DEPRECATED (use wizard instead):
    select              → Use: sudo nftban wizard
    apply <name>        → Use: sudo nftban wizard
    list                → Static profiles removed

MIGRATION TO WIZARD:

    The wizard replaces static profiles with an intelligent setup that:

    1. Detects your environment automatically:
       • CPU cores, RAM, disk space
       • Open ports (SSH, HTTP, HTTPS, Mail, Database)
       • Running services

    2. Asks 3 simple questions:
       • Security Level: minimal / basic / advanced
       • Traffic Level: low / medium / high
       • Optional Features: feeds, IDS, GUI, metrics

    3. Generates optimal configuration:
       • Creates /etc/nftban/nftban.conf.local
       • Enables appropriate modules
       • Suggests relevant threat feeds

RUN THE WIZARD:

    sudo nftban wizard

SEE ALSO:
    nftban wizard help       - Wizard help
    nftban ddos help         - DDoS protection help
    nftban portscan help     - Port scan detection help
    nftban login help        - Login monitor help
    nftban feeds help        - Threat feeds help

HELP
}

# =============================================================================
# REDIRECT TO WIZARD
# =============================================================================

_nftban_profile_redirect_to_wizard() {
    _nftban_profile_banner
    _nftban_profile_deprecated_notice

    # Check if wizard module exists
    local wizard_module="${NFTBAN_LIB_DIR}/cli/cmd_wizard.sh"
    if [[ -f "$wizard_module" ]]; then
        echo "Launching wizard..."
        echo ""

        # Source and run wizard
        # shellcheck source=/dev/null
        source "$wizard_module" || return 1
        cmd_wizard_install
    else
        echo "❌ ERROR: Wizard module not found"
        echo ""
        echo "Expected: $wizard_module"
        echo ""
        echo "Please reinstall NFTBan to get the wizard module."
        return 1
    fi
}

# =============================================================================
# MAIN COMMAND HANDLER
# =============================================================================

nftban_cmd_profile() {
    local action="${1:-show}"

    # Handle commands
    case "$action" in
        show)
            _nftban_profile_show
            ;;

        select|apply|list)
            # Redirect deprecated commands to wizard
            _nftban_profile_redirect_to_wizard
            ;;

        help|--help|-h)
            _nftban_profile_help
            ;;

        *)
            echo "ERROR: Unknown command: $action" >&2
            echo ""
            echo "Available commands: show, help"
            echo ""
            echo "For configuration, use the wizard:"
            echo "  sudo nftban wizard"
            return 1
            ;;
    esac

    return 0
}

# =============================================================================
# EXPORT FOR MAIN CLI
# =============================================================================

export -f nftban_cmd_profile

# Execute if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_profile "$@"
fi
