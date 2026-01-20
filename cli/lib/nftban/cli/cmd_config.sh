#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Config CLI Handler
# =============================================================================

# SPDX-License-Identifier: MPL-2.0
# Purpose: Configuration management CLI interface
#
# meta:name="cmd_config"
# meta:type="cli"
# meta:header="Configuration CLI Handler"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="CLI interface for configuration management with schema validation"
# meta:inventory.files=""
# meta:inventory.binaries="jq"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="user"
#
# meta:created_date="2025-11-15"
# meta:updated_date="2026-01-11"
# =============================================================================

set -Eeuo pipefail
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

# Load schema validation module
if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_config_schema.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/core/nftban_config_schema.sh"
fi

# =============================================================================
# USAGE
# =============================================================================

show_usage() {
    cat <<'EOF'
Usage: nftban config <command> [module] [options]

COMMANDS:
  get <module>              Get current configuration (merged defaults + overrides)
  defaults <module>         Show default configuration values
  overrides <module>        Show local override values
  set <module> KEY=VALUE    Set configuration value in .conf.local
  reset <module> KEY        Reset single key to default (remove override)
  reset-all <module>        Reset all configuration to defaults

VALIDATION COMMANDS:
  test [--verbose] [--json] Validate all configuration against schema
  audit [--json]            Audit config for drift, deprecated, and new options
  show                      Show effective merged configuration (all sources)
  diff                      Show differences between defaults and local overrides

MODULES:
  portscan                  Port scan detection configuration
  ddos                      DDoS protection configuration
  login                     Login monitoring configuration

OPTIONS:
  --json                    Output in JSON format
  --verbose                 Show detailed output (for test command)

EXAMPLES:
  # Validate all configuration
  nftban config test

  # Validate with verbose output
  nftban config test --verbose

  # Audit configuration for drift and deprecated options
  nftban config audit

  # Show effective merged configuration
  nftban config show

  # Show what has been overridden locally
  nftban config diff

  # View current portscan configuration (defaults + overrides)
  nftban config get portscan

  # Set a configuration value (saves to .conf.local)
  sudo nftban config set portscan PORTSCAN_BAN_THRESHOLD=15

  # Reset a single value to default
  sudo nftban config reset portscan PORTSCAN_BAN_THRESHOLD

  # Get config in JSON format
  nftban config get portscan --json

CONFIGURATION FILES:
  /etc/nftban/nftban.conf           Main config defaults (DO NOT EDIT)
  /etc/nftban/nftban.conf.local     Main config local overrides
  /etc/nftban/conf.d/*.conf         Module config defaults (DO NOT EDIT)
  /etc/nftban/conf.d/*.conf.local   Module config local overrides

HOW IT WORKS:
  - Default values come from .conf files (shipped with packages)
  - Local overrides are stored in .conf.local files
  - Overrides take precedence over defaults
  - Use 'set' to add/update overrides, 'reset' to remove them
  - The 'test' command validates against the schema
  - The 'audit' command detects drift, deprecated keys, and new options

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

nftban_cmd_config_test() {
    # Validate configuration against schema
    local verbose=0
    local json_mode=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --verbose|-v) verbose=1 ;;
            --json) json_mode=1 ;;
            *) ;;
        esac
        shift
    done

    # Check if schema module is loaded
    if ! command -v nftban_configtest >/dev/null 2>&1; then
        echo "ERROR: Schema validation module not available"
        return 1
    fi

    nftban_configtest "$verbose" "$json_mode"
}

nftban_cmd_config_audit() {
    # Audit configuration for drift, deprecated keys, etc.
    local json_mode=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json_mode=1 ;;
            *) ;;
        esac
        shift
    done

    # Check if schema module is loaded
    if ! command -v nftban_configaudit >/dev/null 2>&1; then
        echo "ERROR: Schema validation module not available"
        return 1
    fi

    nftban_configaudit "$json_mode"
}

nftban_cmd_config_show() {
    # Show effective merged configuration
    local json_mode="${1:-0}"

    # Check if schema module is loaded
    if ! command -v nftban_config_load_effective >/dev/null 2>&1; then
        echo "ERROR: Schema validation module not available"
        return 1
    fi

    local effective
    effective=$(nftban_config_load_effective)

    if [[ "$json_mode" == "--json" || "$json_mode" == "1" ]]; then
        echo "$effective" | jq '.'
    else
        echo "Effective Configuration (all sources merged)"
        echo "════════════════════════════════════════════════════════════"
        echo ""

        # OPTIMIZED: Single jq call, sorted alphabetically
        # Category grouping removed for performance (was causing 100+ jq calls)
        echo "$effective" | jq -r '
            to_entries | sort_by(.key) | .[] |
            "  \(.key)\("                                   "[0:35-(.key|length)]) = \(.value)"
        '
    fi
}

nftban_cmd_config_diff() {
    # Show differences between defaults and local overrides
    local json_mode="${1:-0}"
    local config_dir="${NFTBAN_CONFIG_DIR:-/etc/nftban}"

    echo "Configuration Differences (defaults vs local overrides)"
    echo "════════════════════════════════════════════════════════════"
    echo ""

    local has_diff=0

    # Check main config
    if [[ -f "$config_dir/nftban.conf.local" ]]; then
        local local_json defaults_json
        local_json=$(nftban_config_parse_to_json "$config_dir/nftban.conf.local" 2>/dev/null || echo "{}")
        defaults_json=$(nftban_config_parse_to_json "$config_dir/nftban.conf" 2>/dev/null || echo "{}")

        local local_keys
        local_keys=$(echo "$local_json" | jq -r 'keys[]' 2>/dev/null)

        if [[ -n "$local_keys" ]]; then
            echo "[nftban.conf.local]"
            while IFS= read -r key; do
                [[ -z "$key" ]] && continue
                local local_val default_val
                local_val=$(echo "$local_json" | jq -r --arg k "$key" '.[$k]')
                default_val=$(echo "$defaults_json" | jq -r --arg k "$key" '.[$k] // "<not in defaults>"')

                if [[ "$local_val" != "$default_val" ]]; then
                    printf "  %-30s: %s -> %s\n" "$key" "$default_val" "$local_val"
                    has_diff=1
                fi
            done <<< "$local_keys"
            echo ""
        fi
    fi

    # Check conf.d/*.conf.local files
    local local_file
    for local_file in "$config_dir"/conf.d/*.conf.local "$config_dir"/conf.d/*/*.conf.local; do
        [[ -f "$local_file" ]] || continue

        local base_file="${local_file%.local}"
        local module_name
        module_name=$(basename "$local_file" .conf.local)

        local local_json defaults_json
        local_json=$(nftban_config_parse_to_json "$local_file" 2>/dev/null || echo "{}")
        defaults_json=$(nftban_config_parse_to_json "$base_file" 2>/dev/null || echo "{}")

        local local_keys
        local_keys=$(echo "$local_json" | jq -r 'keys[]' 2>/dev/null)

        if [[ -n "$local_keys" ]]; then
            echo "[${module_name}.conf.local]"
            while IFS= read -r key; do
                [[ -z "$key" ]] && continue
                local local_val default_val
                local_val=$(echo "$local_json" | jq -r --arg k "$key" '.[$k]')
                default_val=$(echo "$defaults_json" | jq -r --arg k "$key" '.[$k] // "<not in defaults>"')

                if [[ "$local_val" != "$default_val" ]]; then
                    printf "  %-30s: %s -> %s\n" "$key" "$default_val" "$local_val"
                    has_diff=1
                fi
            done <<< "$local_keys"
            echo ""
        fi
    done

    if [[ $has_diff -eq 0 ]]; then
        echo "No local overrides found. Using all defaults."
    fi
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

        test|validate)
            nftban_cmd_config_test "$@"
            ;;

        audit)
            nftban_cmd_config_audit "$@"
            ;;

        show)
            nftban_cmd_config_show "$@"
            ;;

        diff)
            nftban_cmd_config_diff "$@"
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
