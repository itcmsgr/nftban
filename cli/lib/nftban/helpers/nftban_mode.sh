#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_mode"
# meta:type="helper"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Shared mode management functions for portscan, ddos, and login modules"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_NFTBAN_MODE_LOADED:-}" ]] && return 0
_NFTBAN_MODE_LOADED=1

# Colors (if not already defined)
: "${RED:=\033[0;31m}"
: "${GREEN:=\033[0;32m}"
: "${YELLOW:=\033[0;33m}"
: "${BLUE:=\033[0;34m}"
: "${CYAN:=\033[0;36m}"
: "${NC:=\033[0m}"

# Valid modes (shared across all modules)
# shellcheck disable=SC2034  # Used by other modules
readonly NFTBAN_VALID_MODES="auto classic suricata hybrid"

# =============================================================================
# SURICATA AVAILABILITY CHECK
# =============================================================================

# Check if Suricata is available and get status
# Usage: _nftban_check_suricata_available
# Sets: SURICATA_AVAILABLE (true/false), SURICATA_STATUS (string)
_nftban_check_suricata_available() {
    SURICATA_AVAILABLE="false"
    SURICATA_STATUS="not installed"

    if command -v suricata &>/dev/null; then
        if systemctl is-active suricata.service &>/dev/null; then
            SURICATA_AVAILABLE="true"
            SURICATA_STATUS="running"
        elif systemctl is-enabled suricata.service &>/dev/null 2>&1; then
            SURICATA_STATUS="installed (not running)"
        else
            SURICATA_STATUS="installed (disabled)"
        fi
    fi
}

# =============================================================================
# MODE DETECTION
# =============================================================================

# Resolve "auto" mode to effective mode based on Suricata availability
# Usage: _nftban_mode_detect_effective <configured_mode>
# Returns: effective mode (classic or suricata)
_nftban_mode_detect_effective() {
    local configured_mode="${1:-auto}"

    if [[ "$configured_mode" != "auto" ]]; then
        echo "$configured_mode"
        return 0
    fi

    # Check Suricata availability
    _nftban_check_suricata_available

    if [[ "$SURICATA_AVAILABLE" == "true" ]]; then
        echo "suricata"
    else
        echo "classic"
    fi
}

# Read mode from config files (main.conf and .local)
# Usage: _nftban_mode_read <mode_var_name> <config_main_path>
# Sets: MODE_CONFIGURED, MODE_OVERRIDE, MODE_OVERRIDE_SOURCE, MODE_EFFECTIVE
_nftban_mode_read() {
    local mode_var_name="$1"
    local config_main="$2"
    local config_local="${config_main}.local"

    # Read configured mode from main.conf
    MODE_CONFIGURED="auto"
    if [[ -f "$config_main" ]]; then
        local mode_val
        mode_val=$(grep "^${mode_var_name}=" "$config_main" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '"' | tr -d "'" | xargs) || true
        [[ -n "$mode_val" ]] && MODE_CONFIGURED="$mode_val"
    fi

    # Check for .local override
    MODE_OVERRIDE=""
    MODE_OVERRIDE_SOURCE=""
    if [[ -f "$config_local" ]]; then
        local local_mode
        local_mode=$(grep "^${mode_var_name}=" "$config_local" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '"' | tr -d "'" | xargs) || true
        if [[ -n "$local_mode" ]]; then
            MODE_OVERRIDE="$local_mode"
            MODE_OVERRIDE_SOURCE="$config_local"
            MODE_CONFIGURED="$local_mode"
        fi
    fi

    # Determine effective mode
    MODE_EFFECTIVE=$(_nftban_mode_detect_effective "$MODE_CONFIGURED")
}

# =============================================================================
# MODE SHOW FUNCTION
# =============================================================================

# Show current mode configuration
# Usage: _nftban_mode_show <module_name> <mode_var_name> <config_main_path> <display_name> [json_mode]
# Example: _nftban_mode_show "portscan" "PORTSCAN_MODE" "/etc/nftban/conf.d/portscan/main.conf" "Port Scan Detection" "false"
_nftban_mode_show() {
    local module_name="$1"
    local mode_var_name="$2"
    local config_main="$3"
    local display_name="$4"
    local json_mode="${5:-false}"

    # Read current mode configuration
    _nftban_mode_read "$mode_var_name" "$config_main"

    # Check Suricata availability
    _nftban_check_suricata_available

    # JSON output
    if [[ "$json_mode" == "true" ]] && declare -f json_output &>/dev/null; then
        local data
        local has_override="false"
        [[ -n "$MODE_OVERRIDE" ]] && has_override="true"
        local suricata_bool="false"
        [[ "$SURICATA_AVAILABLE" == "true" ]] && suricata_bool="true"

        if command -v jq &>/dev/null; then
            data=$(jq -n \
                --arg module "$module_name" \
                --arg configured "$MODE_CONFIGURED" \
                --arg effective "$MODE_EFFECTIVE" \
                --arg override "$MODE_OVERRIDE" \
                --arg override_source "$MODE_OVERRIDE_SOURCE" \
                --arg has_override "$has_override" \
                --arg suricata_available "$suricata_bool" \
                --arg suricata_status "$SURICATA_STATUS" \
                --arg config_file "$config_main" \
                '{
                    mode: {
                        module: $module,
                        configured: $configured,
                        effective: $effective,
                        has_override: ($has_override == "true"),
                        override_value: (if $override == "" then null else $override end),
                        override_source: (if $override_source == "" then null else $override_source end),
                        suricata_available: ($suricata_available == "true"),
                        suricata_status: $suricata_status,
                        config_file: $config_file
                    }
                }')
        else
            local override_json="null"
            local override_src_json="null"
            [[ -n "$MODE_OVERRIDE" ]] && override_json="\"$MODE_OVERRIDE\""
            [[ -n "$MODE_OVERRIDE_SOURCE" ]] && override_src_json="\"$MODE_OVERRIDE_SOURCE\""
            data="{\"mode\":{\"module\":\"$module_name\",\"configured\":\"$MODE_CONFIGURED\",\"effective\":\"$MODE_EFFECTIVE\",\"has_override\":$has_override,\"override_value\":$override_json,\"override_source\":$override_src_json,\"suricata_available\":$suricata_bool,\"suricata_status\":\"$SURICATA_STATUS\",\"config_file\":\"$config_main\"}}"
        fi
        json_output "true" "$data"
        return 0
    fi

    # Human-readable output
    local title_len=${#display_name}
    local underline
    underline=$(printf '=%.0s' $(seq 1 $((title_len + 5))))

    echo "$display_name Mode"
    echo "$underline"
    echo ""
    echo "  Configured Mode:  $MODE_CONFIGURED"
    if [[ "$MODE_CONFIGURED" == "auto" ]]; then
        echo "  Effective Mode:   $MODE_EFFECTIVE (auto-detected)"
    else
        echo "  Effective Mode:   $MODE_EFFECTIVE"
    fi
    echo ""
    echo "  Config File:      $config_main"
    if [[ -n "$MODE_OVERRIDE" ]]; then
        echo "  Override:         $MODE_OVERRIDE (from $MODE_OVERRIDE_SOURCE)"
    fi
    echo ""
    echo "  Suricata:         $SURICATA_STATUS"
    echo ""
    echo "Available modes:"
    echo "  auto     - Automatically select based on Suricata availability"
    echo "  classic  - Use nftables-based detection/protection only"
    echo "  suricata - Use Suricata IDS for detection"
    echo "  hybrid   - Use both classic and Suricata together"
    echo ""
}

# =============================================================================
# MODE SET FUNCTION
# =============================================================================

# Validate mode value
# Usage: _nftban_mode_validate <mode> [json_mode]
# Returns: 0 if valid, 1 if invalid
_nftban_mode_validate() {
    local mode="$1"
    local json_mode="${2:-false}"

    case "$mode" in
        auto|classic|suricata|hybrid)
            return 0
            ;;
        "")
            if [[ "$json_mode" == "true" ]] && declare -f json_error &>/dev/null; then
                json_error "Mode is required. Valid modes: auto, classic, suricata, hybrid"
            else
                echo "ERROR: Mode is required" >&2
                echo "Valid modes: auto, classic, suricata, hybrid" >&2
            fi
            return 1
            ;;
        *)
            if [[ "$json_mode" == "true" ]] && declare -f json_error &>/dev/null; then
                json_error "Invalid mode: $mode. Valid modes: auto, classic, suricata, hybrid"
            else
                echo "ERROR: Invalid mode: $mode" >&2
                echo "Valid modes: auto, classic, suricata, hybrid" >&2
            fi
            return 1
            ;;
    esac
}

# Validate Suricata is available (for suricata/hybrid modes)
# Usage: _nftban_mode_validate_suricata <mode> [json_mode]
# Returns: 0 if ok, 1 if Suricata required but not available
_nftban_mode_validate_suricata() {
    local mode="$1"
    local json_mode="${2:-false}"

    # Only validate for suricata or hybrid modes
    if [[ "$mode" != "suricata" && "$mode" != "hybrid" ]]; then
        return 0
    fi

    if ! command -v suricata &>/dev/null; then
        if [[ "$json_mode" == "true" ]] && declare -f json_error &>/dev/null; then
            json_error "Suricata is not installed. Install suricata package first."
        else
            echo "ERROR: Suricata is not installed" >&2
            echo "Install the suricata package first, then try again." >&2
        fi
        return 1
    fi

    # Validate Suricata configuration (warning only)
    if ! suricata -T -c /etc/suricata/suricata.yaml &>/dev/null; then
        if [[ "$json_mode" == "true" ]]; then
            : # Silent warning in JSON mode
        else
            echo "WARNING: Suricata configuration test failed" >&2
            echo "Run 'suricata -T' to diagnose configuration issues." >&2
            echo "Proceeding anyway..." >&2
        fi
    fi

    return 0
}

# Set mode in local config file
# Usage: _nftban_mode_set <module_name> <mode_var_name> <config_main_path> <display_name> <new_mode> [json_mode]
# Example: _nftban_mode_set "portscan" "PORTSCAN_MODE" "/etc/nftban/conf.d/portscan/main.conf" "Port Scan Detection" "classic" "false"
_nftban_mode_set() {
    local module_name="$1"
    local mode_var_name="$2"
    local config_main="$3"
    local display_name="$4"
    local new_mode="$5"
    local json_mode="${6:-false}"
    local config_local="${config_main}.local"

    # Validate mode
    if ! _nftban_mode_validate "$new_mode" "$json_mode"; then
        return 1
    fi

    # Check root privileges
    if [[ $EUID -ne 0 ]]; then
        if [[ "$json_mode" == "true" ]] && declare -f json_error &>/dev/null; then
            json_error "PolicyKit/polkit authorization failed or insufficient privileges to change mode"
        else
            echo "ERROR: Root privileges required to change mode" >&2
        fi
        return 1
    fi

    # Validate Suricata availability for suricata/hybrid modes
    if ! _nftban_mode_validate_suricata "$new_mode" "$json_mode"; then
        return 1
    fi

    # Get current mode for comparison
    _nftban_mode_read "$mode_var_name" "$config_main"
    local old_mode="$MODE_CONFIGURED"

    # Ensure local config directory exists
    mkdir -p "$(dirname "$config_local")" || return 1

    # Ensure local config file exists with header
    if [[ ! -f "$config_local" ]]; then
        cat > "$config_local" << HEADER
# NFTBan ${display_name} - User Overrides
# This file overrides settings from main.conf
# Do not edit main.conf directly - changes here take precedence
HEADER
        chmod 640 "$config_local"
        chown root:nftban "$config_local" 2>/dev/null || true
    fi

    # Update or add mode in local config
    if grep -q "^${mode_var_name}=" "$config_local" 2>/dev/null; then
        sed -i "s|^${mode_var_name}=.*|${mode_var_name}=\"$new_mode\"|" "$config_local"
    else
        echo "" >> "$config_local"
        echo "# Detection mode: auto, classic, suricata, hybrid" >> "$config_local"
        echo "${mode_var_name}=\"$new_mode\"" >> "$config_local"
    fi

    # Determine effective mode for display
    local effective_mode
    effective_mode=$(_nftban_mode_detect_effective "$new_mode")

    # JSON output
    if [[ "$json_mode" == "true" ]] && declare -f json_output &>/dev/null; then
        local data
        if command -v jq &>/dev/null; then
            data=$(jq -n \
                --arg module "$module_name" \
                --arg old "$old_mode" \
                --arg new "$new_mode" \
                --arg effective "$effective_mode" \
                --arg config_file "$config_local" \
                '{
                    success: true,
                    mode: {
                        module: $module,
                        previous: $old,
                        new: $new,
                        effective: $effective,
                        config_file: $config_file
                    }
                }')
        else
            data="{\"success\":true,\"mode\":{\"module\":\"$module_name\",\"previous\":\"$old_mode\",\"new\":\"$new_mode\",\"effective\":\"$effective_mode\",\"config_file\":\"$config_local\"}}"
        fi
        json_output "true" "$data"
        return 0
    fi

    # Human-readable output
    local title_len=${#display_name}
    local underline
    underline=$(printf '=%.0s' $(seq 1 $((title_len + 13))))

    echo "$display_name Mode Changed"
    echo "$underline"
    echo ""
    echo "  Previous Mode:    $old_mode"
    echo "  New Mode:         $new_mode"
    if [[ "$new_mode" == "auto" ]]; then
        echo "  Effective Mode:   $effective_mode (auto-detected)"
    fi
    echo ""
    echo "  Config File:      $config_local"
    echo ""
    echo "Note: Restart nftban daemon to apply changes:"
    echo "  sudo systemctl restart nftban"
    echo ""
}

# =============================================================================
# MAIN MODE COMMAND HANDLER
# =============================================================================

# Generic mode command handler (show/set dispatcher)
# Usage: _nftban_mode_handler <module_name> <mode_var_name> <config_main_path> <display_name> <subcommand> [json_mode] [mode_arg]
# Example: _nftban_mode_handler "portscan" "PORTSCAN_MODE" "/etc/nftban/conf.d/portscan/main.conf" "Port Scan Detection" "set" "false" "classic"
_nftban_mode_handler() {
    local module_name="$1"
    local mode_var_name="$2"
    local config_main="$3"
    local display_name="$4"
    local subcommand="${5:-show}"
    local json_mode="${6:-false}"
    local mode_arg="${7:-}"

    case "$subcommand" in
        show|"")
            _nftban_mode_show "$module_name" "$mode_var_name" "$config_main" "$display_name" "$json_mode"
            ;;
        set)
            _nftban_mode_set "$module_name" "$mode_var_name" "$config_main" "$display_name" "$mode_arg" "$json_mode"
            ;;
        *)
            if [[ "$json_mode" == "true" ]] && declare -f json_error &>/dev/null; then
                json_error "Unknown mode subcommand: $subcommand. Use: show, set"
            else
                echo "ERROR: Unknown mode subcommand: $subcommand" >&2
                echo "Usage: nftban $module_name mode show" >&2
                echo "       nftban $module_name mode set <auto|classic|suricata|hybrid>" >&2
            fi
            return 1
            ;;
    esac
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================

export -f _nftban_check_suricata_available 2>/dev/null || true
export -f _nftban_mode_detect_effective 2>/dev/null || true
export -f _nftban_mode_read 2>/dev/null || true
export -f _nftban_mode_show 2>/dev/null || true
export -f _nftban_mode_validate 2>/dev/null || true
export -f _nftban_mode_validate_suricata 2>/dev/null || true
export -f _nftban_mode_set 2>/dev/null || true
export -f _nftban_mode_handler 2>/dev/null || true
