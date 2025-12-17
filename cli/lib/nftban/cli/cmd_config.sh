#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Config CLI Handler
# =============================================================================

# SPDX-License-Identifier: MPL-2.0
# Purpose: Configuration management CLI interface
#
# meta:name=cmd_config
# meta:type=cli
# meta:header=Configuration CLI Handler
# meta:version=1.0.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=CLI interface for configuration management with .conf.local support
# meta:input=Config commands and parameters
# meta:output=Configuration values or status messages
#
# **Inventory & Requirements**
# meta:depends=nftban_config.sh
#
# meta:created_date=2025-11-15
# meta:updated_date=2025-11-24
# =============================================================================

IFS=$'\n\t'
umask 027

# =============================================================================
# CONFIGURATION
# =============================================================================

: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"

# Load JSON helper for --json support
JSON_HELPER="${NFTBAN_LIB_DIR}/helpers/json_output.sh"
if [[ -f "$JSON_HELPER" ]]; then
    # shellcheck source=/dev/null
    source "$JSON_HELPER"
fi

# =============================================================================
# DEPENDENCIES
# =============================================================================

# Load config module
if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_config.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/core/nftban_config.sh"
else
    echo "ERROR: Configuration module not found"
    exit 1
fi

# =============================================================================
# USAGE
# =============================================================================

show_usage() {
    cat <<'EOF'
Usage: nftban config <command> <module> [options]

COMMANDS:
  get <module>              Get current configuration (merged defaults + overrides)
  defaults <module>         Show default configuration values
  overrides <module>        Show local override values
  set <module> KEY=VALUE    Set configuration value in .conf.local
  reset <module> KEY        Reset single key to default (remove override)
  reset-all <module>        Reset all configuration to defaults

MODULES:
  portscan                  Port scan detection configuration
  ddos                      DDoS protection configuration

OPTIONS:
  --json                    Output in JSON format

EXAMPLES:
  # View current portscan configuration (defaults + overrides)
  nftban config get portscan

  # View only default values
  nftban config defaults portscan

  # View only local overrides
  nftban config overrides portscan

  # Set a configuration value (saves to .conf.local)
  sudo nftban config set portscan PORTSCAN_THRESHOLD=15

  # Reset a single value to default
  sudo nftban config reset portscan PORTSCAN_THRESHOLD

  # Reset all portscan config to defaults
  sudo nftban config reset-all portscan

  # Get config in JSON format
  nftban config get portscan --json

CONFIGURATION FILES:
  /etc/nftban/conf.d/*.conf     Default configuration files (DO NOT EDIT)
  /etc/nftban/nftban.conf.local Local overrides (auto-managed by this command)

HOW IT WORKS:
  - Default values come from /etc/nftban/conf.d/<module>.conf
  - Local overrides are stored in /etc/nftban/nftban.conf.local
  - Overrides take precedence over defaults
  - Use 'set' to add/update overrides, 'reset' to remove them

EOF
}

# =============================================================================
# COMMAND HANDLERS
# =============================================================================

nftban_cmd_config_get() {
    # Get merged configuration (defaults + overrides)
    local module="$1"
    shift || true

    local json_mode="false"
    if [[ "${1:-}" == "--json" ]]; then
        json_mode="--json"
    fi

    nftban_config_get_merged "$module" "$json_mode"
}

nftban_cmd_config_defaults() {
    # Get default configuration only
    local module="$1"

    local defaults
    defaults=$(nftban_config_get_defaults "$module")

    if [[ "${2:-}" == "--json" ]]; then
        echo "{\"success\": true, \"data\": $defaults}"
    else
        echo "Default Configuration for: $module"
        echo "════════════════════════════════════════════════════════════"
        echo "$defaults" | jq -r 'to_entries[] | "\(.key)=\(.value)"' | sort
    fi
}

nftban_cmd_config_overrides() {
    # Get local overrides only
    local module="$1"

    local overrides
    overrides=$(nftban_config_get_overrides "$module")

    if [[ "${2:-}" == "--json" ]]; then
        echo "{\"success\": true, \"data\": $overrides}"
    else
        echo "Local Overrides for: $module"
        echo "════════════════════════════════════════════════════════════"
        if [[ "$overrides" == "{}" ]]; then
            echo "(No local overrides - using all defaults)"
        else
            echo "$overrides" | jq -r 'to_entries[] | "\(.key)=\(.value)"' | sort
        fi
    fi
}

nftban_cmd_config_set() {
    # Set a configuration value
    local module="$1"
    local key_value="$2"

    nftban_config_set "$module" "$key_value"
}

nftban_cmd_config_reset() {
    # Reset a single key
    local module="$1"
    local key="$2"

    nftban_config_reset "$module" "$key"
}

nftban_cmd_config_reset_all() {
    # Reset all configuration for module
    local module="$1"

    nftban_config_reset_all "$module"
}

# =============================================================================
# MAIN COMMAND HANDLER
# =============================================================================

nftban_cmd_config() {
    # Main command handler for config
    # Args: subcommand, module, and options

    local subcommand="${1:-help}"
    shift || true

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
        get)
            if [[ -z "${1:-}" ]]; then
                echo "ERROR: Module name required"
                echo "Usage: nftban config get <module> [--json]"
                return 1
            fi
            nftban_cmd_config_get "$@"
            ;;

        defaults)
            if [[ -z "${1:-}" ]]; then
                echo "ERROR: Module name required"
                echo "Usage: nftban config defaults <module> [--json]"
                return 1
            fi
            nftban_cmd_config_defaults "$@"
            ;;

        overrides)
            if [[ -z "${1:-}" ]]; then
                echo "ERROR: Module name required"
                echo "Usage: nftban config overrides <module> [--json]"
                return 1
            fi
            nftban_cmd_config_overrides "$@"
            ;;

        set)
            if [[ -z "${1:-}" ]] || [[ -z "${2:-}" ]]; then
                echo "ERROR: Module name and KEY=VALUE required"
                echo "Usage: nftban config set <module> KEY=VALUE"
                return 1
            fi
            nftban_cmd_config_set "$@"
            ;;

        reset)
            if [[ -z "${1:-}" ]] || [[ -z "${2:-}" ]]; then
                echo "ERROR: Module name and KEY required"
                echo "Usage: nftban config reset <module> KEY"
                return 1
            fi
            nftban_cmd_config_reset "$@"
            ;;

        reset-all)
            if [[ -z "${1:-}" ]]; then
                echo "ERROR: Module name required"
                echo "Usage: nftban config reset-all <module>"
                return 1
            fi
            nftban_cmd_config_reset_all "$@"
            ;;

        help|--help|-h|"")
            show_usage
            return 0
            ;;

        *)
            echo "ERROR: Unknown command: $subcommand" >&2
            echo "" >&2
            show_usage
            return 1
            ;;
    esac
}

# =============================================================================
# EXPORTS
# =============================================================================

# Exit marker for testing validation
command -v nftban_cmd_exit >/dev/null 2>&1 && nftban_cmd_exit "config"

export -f nftban_cmd_config

# =============================================================================
# DIRECT EXECUTION SUPPORT
# =============================================================================

# If executed directly (not sourced), run the command handler
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_config "$@"
fi
