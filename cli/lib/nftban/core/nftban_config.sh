#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Configuration Management
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Unified configuration file management with .conf.local override support
#
# meta:name="nftban_config"
# meta:type="core"
# meta:header="Configuration Management"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
# meta:description="Read and write configuration files with .conf.local override support"
# meta:input="Configuration module name (portscan, ddos, etc.)"
# meta:output="Merged configuration or write status"
# meta:depends="nftban_file_ops.sh"
# meta:created_date="2025-11-15"
# meta:updated_date="2026-01-22"
#
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_CONFD_DIR"
# meta:inventory.config_files="/etc/nftban/nftban.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# =============================================================================
# SOURCE GUARD - prevent re-sourcing
# =============================================================================
[[ -n "${_NFTBAN_CONFIG_SH_LOADED:-}" ]] && return 0
readonly _NFTBAN_CONFIG_SH_LOADED=1

# =============================================================================
# CONFIGURATION
# =============================================================================
# NOTE: NFTBAN_CONFIG_DIR is defined as readonly in /etc/nftban/nftban.conf
# Only set defaults here if not already defined (for standalone testing)

if [[ -z "${NFTBAN_CONFIG_DIR:-}" ]]; then
    readonly NFTBAN_CONFIG_DIR="/etc/nftban"
fi
if [[ -z "${NFTBAN_CONFD_DIR:-}" ]]; then
    readonly NFTBAN_CONFD_DIR="/etc/nftban/conf.d"
fi
readonly NFTBAN_LOCAL_CONF="${NFTBAN_LOCAL_CONF:-${NFTBAN_CONFIG_DIR}/nftban.conf.local}"

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# =============================================================================
# INI PARSER - Parse INI-style config files with [section] headers
# =============================================================================
# Exports variables as: NFTBAN_<SECTION>_<KEY>=value
# Example: [global] mode=strict → NFTBAN_GLOBAL_MODE=strict

nftban_config_is_ini() {
    # Check if file is INI format (has [section] headers)
    # Args: $1 = file path
    # Returns: 0 if INI, 1 if not
    local file="$1"
    [[ -f "$file" ]] && grep -q '^\[' "$file" 2>/dev/null
}

nftban_config_parse_ini() {
    # Parse INI-style config file and export as NFTBAN_<SECTION>_<KEY> variables
    # Args: $1 = file path, $2 = optional prefix (default: NFTBAN)
    # Output: Exports variables to current shell

    local file="$1"
    local prefix="${2:-NFTBAN}"
    local section="GLOBAL"

    [[ ! -f "$file" ]] && return 1

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Trim whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[#\;] ]] && continue

        # Section header: [section_name]
        if [[ "$line" =~ ^\[([^\]]+)\]$ ]]; then
            section="${BASH_REMATCH[1]}"
            # Normalize: uppercase, replace - with _
            section="${section^^}"
            section="${section//-/_}"
            continue
        fi

        # Key-value pair: key = value
        if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"

            # Trim whitespace from key and value
            key="${key#"${key%%[![:space:]]*}"}"
            key="${key%"${key##*[![:space:]]}"}"
            value="${value#"${value%%[![:space:]]*}"}"
            value="${value%"${value##*[![:space:]]}"}"

            # Remove surrounding quotes from value
            value="${value#\"}"
            value="${value%\"}"
            value="${value#\'}"
            value="${value%\'}"

            # Normalize key: uppercase, replace - with _
            key="${key^^}"
            key="${key//-/_}"

            # Export variable (declare -gx creates global exported variable)
            local varname="${prefix}_${section}_${key}"
            declare -gx "$varname=$value"
        fi
    done < "$file"
}

nftban_config_load() {
    # Auto-detect config format and load appropriately
    # Args: $1 = file path
    # Returns: 0 on success, 1 on failure

    local file="$1"

    [[ ! -f "$file" ]] && return 1

    if nftban_config_is_ini "$file"; then
        # INI format - use parser
        nftban_config_parse_ini "$file"
    else
        # Bash format - source it
        # shellcheck disable=SC1090
        source "$file" || true
    fi
}

nftban_config_parse_file() {
    # Parse a config file and extract KEY=VALUE pairs
    # Args: $1 = file path
    # Output: KEY=VALUE lines (one per line)

    local file="$1"

    [[ ! -f "$file" ]] && return 0

    # Extract lines that look like KEY="VALUE" or KEY=VALUE
    # Skip comments and empty lines
    grep -E '^[A-Z_]+=' "$file" 2>/dev/null || true
}

nftban_config_get_value() {
    # Get a specific config value from a file
    # Args: $1 = file path, $2 = key name
    # Output: value (without quotes)

    local file="$1"
    local key="$2"

    [[ ! -f "$file" ]] && return 0

    local line
    line=$(grep -E "^${key}=" "$file" 2>/dev/null | tail -n1 || true)

    if [[ -n "$line" ]]; then
        # Extract value, remove quotes
        local value="${line#*=}"
        value="${value#\"}"
        value="${value%\"}"
        echo "$value"
    fi
}

# =============================================================================
# MAIN FUNCTIONS
# =============================================================================

nftban_config_get_defaults() {
    # Get default configuration for a module
    # Args: $1 = module name (portscan, ddos, etc.)
    # Output: JSON object with all default config values

    local module="$1"
    local conf_file=""

    # Check for config in subdirectory structure (e.g., conf.d/portscan/main.conf)
    if [[ -f "${NFTBAN_CONFD_DIR}/${module}/main.conf" ]]; then
        conf_file="${NFTBAN_CONFD_DIR}/${module}/main.conf"
    # Fallback to flat file structure (e.g., conf.d/portscan.conf)
    elif [[ -f "${NFTBAN_CONFD_DIR}/${module}.conf" ]]; then
        conf_file="${NFTBAN_CONFD_DIR}/${module}.conf"
    else
        echo "{\"error\": \"Configuration file not found for module: ${module}\"}"
        return 1
    fi

    # Parse config file and build JSON
    local json="{"
    local first=true

    while IFS='=' read -r key value; do
        [[ -z "$key" ]] && continue

        # Remove quotes from value
        value="${value#\"}"
        value="${value%\"}"

        # Escape JSON special characters
        value="${value//\\/\\\\}"
        value="${value//\"/\\\"}"

        if [[ "$first" == true ]]; then
            first=false
        else
            json+=","
        fi

        json+="\"${key}\": \"${value}\""
    done < <(nftban_config_parse_file "$conf_file")

    json+="}"
    echo "$json"
}

nftban_config_get_overrides() {
    # Get override configuration for a module from .conf.local
    # Args: $1 = module name (portscan, ddos, etc.)
    # Output: JSON object with override config values

    local module="$1"

    if [[ ! -f "$NFTBAN_LOCAL_CONF" ]]; then
        echo "{}"
        return 0
    fi

    # Find section for this module in .conf.local
    # Format: # --- MODULE_NAME Configuration ---
    local section_marker="# --- ${module^^} Configuration ---"
    local in_section=false
    local json="{"
    local first=true

    while IFS= read -r line; do
        # Check if we're entering the section
        if [[ "$line" == *"$section_marker"* ]]; then
            in_section=true
            continue
        fi

        # Check if we're leaving the section (next section marker or EOF)
        if [[ "$in_section" == true ]] && [[ "$line" == "# --- "* ]] && [[ "$line" != *"$section_marker"* ]]; then
            break
        fi

        # If in section, parse KEY=VALUE
        if [[ "$in_section" == true ]] && [[ "$line" =~ ^[A-Z_]+=.* ]]; then
            local key="${line%%=*}"
            local value="${line#*=}"

            # Remove quotes
            value="${value#\"}"
            value="${value%\"}"

            # Escape JSON special characters
            value="${value//\\/\\\\}"
            value="${value//\"/\\\"}"

            if [[ "$first" == true ]]; then
                first=false
            else
                json+=","
            fi

            json+="\"${key}\": \"${value}\""
        fi
    done < "$NFTBAN_LOCAL_CONF"

    json+="}"
    echo "$json"
}

nftban_config_get_merged() {
    # Get merged configuration (defaults + overrides)
    # Args: $1 = module name, $2 = --json flag (optional)
    # Output: JSON object with merged config

    local module="$1"
    local json_mode="${2:-false}"

    local defaults overrides
    defaults=$(nftban_config_get_defaults "$module")
    overrides=$(nftban_config_get_overrides "$module")

    # Merge JSON objects (overrides take precedence) - use -c for compact output
    local merged
    merged=$(jq -c -n --argjson defaults "$defaults" --argjson overrides "$overrides" \
        '$defaults + $overrides')

    if [[ "$json_mode" == "--json" ]]; then
        echo "{\"success\": true, \"data\": {\"defaults\": $defaults, \"overrides\": $overrides, \"merged\": $merged}}"
    else
        echo "$merged"
    fi
}

nftban_config_set() {
    # Set a configuration value in .conf.local
    # Args: $1 = module name, $2 = KEY=VALUE
    # Output: success/error message

    local module="$1"
    local key_value="$2"

    # Validate KEY=VALUE format
    if [[ ! "$key_value" =~ ^[A-Z_]+= ]]; then
        echo "ERROR: Invalid format. Use KEY=VALUE"
        return 1
    fi

    local key="${key_value%%=*}"
    local value="${key_value#*=}"

    # Ensure .conf.local exists
    if [[ ! -f "$NFTBAN_LOCAL_CONF" ]]; then
        echo "# NFTBan Local Configuration Overrides" > "$NFTBAN_LOCAL_CONF"
        echo "# Auto-generated by nftban config command" >> "$NFTBAN_LOCAL_CONF"
        echo "" >> "$NFTBAN_LOCAL_CONF"
        chmod 640 "$NFTBAN_LOCAL_CONF"
    fi

    local section_marker="# --- ${module^^} Configuration ---"
    local temp_file="${NFTBAN_LOCAL_CONF}.tmp"

    # Check if section exists
    if ! grep -q "$section_marker" "$NFTBAN_LOCAL_CONF" 2>/dev/null; then
        # Add new section at end
        {
            cat "$NFTBAN_LOCAL_CONF"
            echo ""
            echo "$section_marker"
            echo "${key}=\"${value}\""
            echo ""
        } > "$temp_file"
        mv "$temp_file" "$NFTBAN_LOCAL_CONF"
        echo "✓ Configuration saved: ${key}=${value}"
        return 0
    fi

    # Section exists, update or add key
    local in_section=false
    local key_found=false

    while IFS= read -r line; do
        # Entering section
        if [[ "$line" == *"$section_marker"* ]]; then
            in_section=true
            echo "$line"
            continue
        fi

        # Leaving section
        if [[ "$in_section" == true ]] && [[ "$line" == "# --- "* ]] && [[ "$line" != *"$section_marker"* ]]; then
            # If key wasn't found, add it before leaving section
            if [[ "$key_found" == false ]]; then
                echo "${key}=\"${value}\""
            fi
            in_section=false
            echo "$line"
            continue
        fi

        # In section, check if this is our key
        if [[ "$in_section" == true ]] && [[ "$line" =~ ^${key}= ]]; then
            echo "${key}=\"${value}\""
            key_found=true
            continue
        fi

        echo "$line"
    done < "$NFTBAN_LOCAL_CONF" > "$temp_file"

    # If we reached EOF while in section and key not found, add it
    if [[ "$in_section" == true ]] && [[ "$key_found" == false ]]; then
        echo "${key}=\"${value}\""
        echo ""
    fi >> "$temp_file"

    mv "$temp_file" "$NFTBAN_LOCAL_CONF"
    echo "✓ Configuration saved: ${key}=${value}"
}

nftban_config_reset() {
    # Reset a configuration value (remove from .conf.local)
    # Args: $1 = module name, $2 = KEY
    # Output: success/error message

    local module="$1"
    local key="$2"

    if [[ ! -f "$NFTBAN_LOCAL_CONF" ]]; then
        echo "✓ No local overrides to reset"
        return 0
    fi

    local section_marker="# --- ${module^^} Configuration ---"
    local temp_file="${NFTBAN_LOCAL_CONF}.tmp"
    local in_section=false
    local key_found=false

    while IFS= read -r line; do
        # Entering section
        if [[ "$line" == *"$section_marker"* ]]; then
            in_section=true
            echo "$line"
            continue
        fi

        # Leaving section
        if [[ "$in_section" == true ]] && [[ "$line" == "# --- "* ]] && [[ "$line" != *"$section_marker"* ]]; then
            in_section=false
            echo "$line"
            continue
        fi

        # In section, skip our key
        if [[ "$in_section" == true ]] && [[ "$line" =~ ^${key}= ]]; then
            key_found=true
            continue
        fi

        echo "$line"
    done < "$NFTBAN_LOCAL_CONF" > "$temp_file"

    mv "$temp_file" "$NFTBAN_LOCAL_CONF"

    if [[ "$key_found" == true ]]; then
        echo "✓ Configuration reset: ${key} (using default value)"
    else
        echo "✓ Key not found in overrides: ${key}"
    fi
}

nftban_config_reset_all() {
    # Reset all configuration for a module (remove entire section from .conf.local)
    # Args: $1 = module name
    # Output: success/error message

    local module="$1"

    if [[ ! -f "$NFTBAN_LOCAL_CONF" ]]; then
        echo "✓ No local overrides to reset"
        return 0
    fi

    local section_marker="# --- ${module^^} Configuration ---"
    local temp_file="${NFTBAN_LOCAL_CONF}.tmp"
    local in_section=false

    while IFS= read -r line; do
        # Entering section - skip it
        if [[ "$line" == *"$section_marker"* ]]; then
            in_section=true
            continue
        fi

        # Leaving section
        if [[ "$in_section" == true ]] && [[ "$line" == "# --- "* ]] && [[ "$line" != *"$section_marker"* ]]; then
            in_section=false
            echo "$line"
            continue
        fi

        # Skip lines in section
        if [[ "$in_section" == true ]]; then
            continue
        fi

        echo "$line"
    done < "$NFTBAN_LOCAL_CONF" > "$temp_file"

    mv "$temp_file" "$NFTBAN_LOCAL_CONF"
    echo "✓ All ${module} configuration reset to defaults"
}

# =============================================================================
# SIMPLE CONFIG GET/SET (for global settings like GUI_MODE)
# =============================================================================

nftban_config_get() {
    # Get a global config value
    # Args: $1 = key name (e.g., NFTBAN_GUI_MODE)
    # Output: value (without quotes), or empty if not found
    # v1.19.0: Check .local override first, then fall back to base config (R12)

    local key="$1"
    local conf_file="${NFTBAN_CONFIG_DIR}/nftban.conf"
    local local_file="${NFTBAN_CONFIG_DIR}/nftban.conf.local"

    # Check .local override first (user overrides take precedence)
    if [[ -f "$local_file" ]]; then
        local local_val
        local_val=$(nftban_config_get_value "$local_file" "$key")
        if [[ -n "$local_val" ]]; then
            echo "$local_val"
            return 0
        fi
    fi

    # Fall back to main config file
    if [[ -f "$conf_file" ]]; then
        nftban_config_get_value "$conf_file" "$key"
        return 0
    fi

    # Default: return empty (false)
    echo ""
}

nftban_config_set_global() {
    # Set a global config value in nftban.conf.local (user overrides)
    # Package defaults in nftban.conf are NEVER modified by user operations
    # Args: $1 = key name, $2 = value

    local key="$1"
    local value="$2"
    local conf_file="${NFTBAN_CONFIG_DIR}/nftban.conf.local"

    # Create config directory if needed
    mkdir -p "${NFTBAN_CONFIG_DIR}" || return 1

    # Create local override file if it doesn't exist
    if [[ ! -f "$conf_file" ]]; then
        cat > "$conf_file" << 'EOF'
# NFTBan Local Configuration Overrides
# User-changed values — survives package upgrades
# Package defaults are in nftban.conf (never edit directly)
EOF
    fi

    # Update or add the key
    if grep -q "^${key}=" "$conf_file"; then
        # Key exists, update it
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$conf_file"
    else
        # Key doesn't exist, append it
        echo "${key}=\"${value}\"" >> "$conf_file"
    fi
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_config_get_defaults
export -f nftban_config_get_overrides
export -f nftban_config_get_merged
export -f nftban_config_set
export -f nftban_config_set_global
export -f nftban_config_reset
export -f nftban_config_reset_all
export -f nftban_config_get
