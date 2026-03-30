#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Profile CLI Handler (Wizard Redirect)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cmd_profile"
# meta:type="cli"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2025-11-05"
# meta:version="1.45.0"
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
    local json_mode="${NFTBAN_JSON:-false}"

    # Helper to extract a config value
    _profile_get() {
        local key="$1"
        if [[ -f "$NFTBAN_CONFIG_LOCAL" ]]; then
            grep "^${key}=" "$NFTBAN_CONFIG_LOCAL" 2>/dev/null | cut -d'"' -f2
        fi
    }

    if [[ "$json_mode" == "true" ]] && command -v jq &>/dev/null; then
        local configured_by="manual"
        local config_date=""
        if [[ -f "$NFTBAN_CONFIG_LOCAL" ]]; then
            if grep -q "^# Configured by: NFTBan Wizard" "$NFTBAN_CONFIG_LOCAL" 2>/dev/null; then
                configured_by="wizard"
                config_date=$(grep "^# Timestamp:" "$NFTBAN_CONFIG_LOCAL" 2>/dev/null | cut -d':' -f2- | xargs || echo "")
            fi
        fi

        jq -n \
            --arg config_file "$NFTBAN_CONFIG_LOCAL" \
            --argjson config_exists "$([[ -f "$NFTBAN_CONFIG_LOCAL" ]] && echo true || echo false)" \
            --arg configured_by "$configured_by" \
            --arg config_date "$config_date" \
            --arg login_monitor "$(_profile_get LOGIN_MONITOR_ENABLED)" \
            --arg ddos_protection "$(_profile_get DDOS_PROTECTION_ENABLED)" \
            --arg portscan "$(_profile_get PORTSCAN_ENABLED)" \
            --arg feeds "$(_profile_get NFTBAN_FEEDS_ENABLED)" \
            --arg feeds_list "$(_profile_get NFTBAN_FEEDS_ENABLED_LIST)" \
            --arg suricata "$(_profile_get SURICATA_ENABLED)" \
            --arg metrics "$(_profile_get METRICS_EXPORTER_ENABLED)" \
            --arg web_ui "$(_profile_get UI_ENABLED)" \
            '{
                config_file: $config_file,
                config_exists: $config_exists,
                configured_by: $configured_by,
                config_date: (if $config_date == "" then null else $config_date end),
                settings: {
                    login_monitor: (if $login_monitor == "" then null else $login_monitor end),
                    ddos_protection: (if $ddos_protection == "" then null else $ddos_protection end),
                    portscan: (if $portscan == "" then null else $portscan end),
                    feeds: (if $feeds == "" then null else $feeds end),
                    feeds_list: (if $feeds_list == "" then null else $feeds_list end),
                    suricata: (if $suricata == "" then null else $suricata end),
                    metrics: (if $metrics == "" then null else $metrics end),
                    web_ui: (if $web_ui == "" then null else $web_ui end)
                }
            }'
        return 0
    fi

    _nftban_profile_banner
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Current Configuration"
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
        setting_value=$(_profile_get LOGIN_MONITOR_ENABLED)
        [[ -n "$setting_value" ]] && echo "  Login Monitor: $setting_value"

        # DDoS Protection
        setting_value=$(_profile_get DDOS_PROTECTION_ENABLED)
        [[ -n "$setting_value" ]] && echo "  DDoS Protection: $setting_value"

        # Port Scan Detection
        setting_value=$(_profile_get PORTSCAN_ENABLED)
        [[ -n "$setting_value" ]] && echo "  Port Scan Detection: $setting_value"

        # Threat Feeds
        setting_value=$(_profile_get NFTBAN_FEEDS_ENABLED)
        if [[ -n "$setting_value" ]]; then
            echo "  Threat Feeds: $setting_value"
            if [[ "$setting_value" == "yes" ]]; then
                local enabled_feeds
                enabled_feeds=$(_profile_get NFTBAN_FEEDS_ENABLED_LIST)
                [[ -n "$enabled_feeds" ]] && echo "  Enabled Feeds: $enabled_feeds"
            fi
        fi

        # Suricata IDS
        setting_value=$(_profile_get SURICATA_ENABLED)
        [[ -n "$setting_value" ]] && echo "  Suricata IDS: $setting_value"

        # Metrics Exporter
        setting_value=$(_profile_get METRICS_EXPORTER_ENABLED)
        [[ -n "$setting_value" ]] && echo "  Metrics Exporter: $setting_value"

        # Web UI
        setting_value=$(_profile_get UI_ENABLED)
        [[ -n "$setting_value" ]] && echo "  Web UI: $setting_value"
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
    nftban profile <command> [--json]

COMMANDS:
    show                Show current configuration
    help                Show this help message

OPTIONS:
    --json, -j          Output in JSON format (machine-readable)

DEPRECATED (use wizard instead):
    select              → Use: sudo nftban wizard
    apply <name>        → Use: sudo nftban wizard
    list                → Static profiles removed

MIGRATION TO WIZARD:

    The wizard replaces static profiles with an adaptive setup that:

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
    # Strip --json flag before parsing action
    local -a positional=()
    for arg in "$@"; do
        case "$arg" in
            --json|-j) export NFTBAN_JSON="true" ;;
            *)         positional+=("$arg") ;;
        esac
    done

    local action="${positional[0]:-show}"

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
