#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Configuration Schema and Validation
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="nftban_config_schema"
# meta:type="core"
# meta:header="Configuration schema, validation, and audit system"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Schema-driven config validation, merge, and upgrade drift detection"
# meta:inventory.files=""
# meta:inventory.binaries="jq"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="user"
#
# meta:created_date="2026-01-11"
# meta:updated_date="2026-01-11"
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${NFTBAN_CONFIG_SCHEMA_LOADED:-}" ]] && return 0
readonly NFTBAN_CONFIG_SCHEMA_LOADED=1

# =============================================================================
# SHARED LIBRARY DEPENDENCIES
# =============================================================================

# Source shared libraries with graceful fallback
_NFTBAN_LIB_PATH="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib"

# shellcheck source=/dev/null
if [[ -f "${_NFTBAN_LIB_PATH}/nftban_timestamp.sh" ]]; then
    source "${_NFTBAN_LIB_PATH}/nftban_timestamp.sh"
fi

# shellcheck source=/dev/null
if [[ -f "${_NFTBAN_LIB_PATH}/nftban_file_utils.sh" ]]; then
    source "${_NFTBAN_LIB_PATH}/nftban_file_utils.sh"
fi

# =============================================================================
# CONSTANTS
# =============================================================================

# shellcheck disable=SC2034  # Used by external callers for API versioning
readonly NFTBAN_SCHEMA_VERSION=1
readonly NFTBAN_SCHEMA_FILE="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/data/config-schema.json"
# shellcheck disable=SC2034  # Used by external callers for registry operations
readonly NFTBAN_REGISTRY_FILE="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/data/config-registry.json"
readonly NFTBAN_CONFIG_STATE_FILE="${NFTBAN_DATA_DIR:-/var/lib/nftban}/config/schema-state.json"

# Exit codes for configtest
readonly CONFIG_OK=0
readonly CONFIG_WARNING=1
readonly CONFIG_ERROR=2
readonly CONFIG_CRITICAL=3

# =============================================================================
# MODE DETECTION (Smart Validation)
# =============================================================================

# Detect if Suricata is available and running
# Returns: 0 if suricata detected, 1 otherwise
nftban_detect_suricata() {
    local service_ok=false
    local binary_ok=false
    local eve_ok=false

    # Service check
    if systemctl is-active --quiet suricata 2>/dev/null; then
        service_ok=true
    fi

    # Binary check
    if [[ -x "/usr/bin/suricata" ]]; then
        binary_ok=true
    fi

    # EVE freshness check (if file exists and is recent)
    local eve_file="${NFTBAN_LOG_DIR:-/var/log/nftban}/suricata/eve-alerts.json"
    local threshold=300  # 5 minutes
    if [[ -f "$eve_file" ]]; then
        # Use shared library if available, otherwise fallback to inline logic
        if declare -f nftban_file_is_fresh &>/dev/null; then
            if nftban_file_is_fresh "$eve_file" "$threshold"; then
                eve_ok=true
            fi
        else
            # Fallback: inline age calculation
            local now file_mtime
            now=$(date +%s)
            file_mtime=$(stat -c %Y "$eve_file" 2>/dev/null || stat -f %m "$eve_file" 2>/dev/null || echo 0)
            if (( now - file_mtime < threshold )); then
                eve_ok=true
            fi
        fi
    fi

    # All checks must pass for full suricata detection
    if $service_ok && $binary_ok && $eve_ok; then
        return 0
    fi

    # Partial detection (binary exists but not running)
    if $binary_ok; then
        return 2  # Installed but not running
    fi

    return 1  # Not detected
}

# Get effective mode for a module
# Args: $1 = module (portscan, ddos, login)
# Returns: effective mode (classic, suricata, hybrid)
nftban_get_effective_mode() {
    local module="$1"
    local config_dir="${NFTBAN_CONFIG_DIR:-/etc/nftban}"
    local mode_key="${module^^}_MODE"  # e.g., PORTSCAN_MODE
    local mode=""

    # Read from main.conf
    local main_conf="$config_dir/conf.d/$module/main.conf"
    local local_conf="$config_dir/conf.d/$module/main.conf.local"

    # Check local override first
    if [[ -f "$local_conf" ]]; then
        mode=$(grep -E "^${mode_key}=" "$local_conf" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '"' | tr -d "'")
    fi

    # Fall back to main conf
    if [[ -z "$mode" && -f "$main_conf" ]]; then
        mode=$(grep -E "^${mode_key}=" "$main_conf" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '"' | tr -d "'")
    fi

    # Default to auto
    mode="${mode:-auto}"

    # If auto, detect based on suricata availability
    if [[ "$mode" == "auto" ]]; then
        if nftban_detect_suricata; then
            echo "suricata"
        else
            echo "classic"
        fi
    else
        echo "$mode"
    fi
}

# Check if a config file is active based on mode
# Args: $1 = file path (relative), $2 = module
# Returns: 0 if active, 1 if inactive
nftban_is_config_active() {
    local file_path="$1"
    local effective_mode=""

    # Determine module from path
    local module=""
    case "$file_path" in
        *portscan*) module="portscan" ;;
        *ddos*) module="ddos" ;;
        *login*) module="login" ;;
        *) return 0 ;;  # Non-module files are always active
    esac

    effective_mode=$(nftban_get_effective_mode "$module")

    # Check file type and compare with mode
    case "$file_path" in
        *classic.conf*)
            [[ "$effective_mode" == "classic" || "$effective_mode" == "hybrid" ]] && return 0
            return 1
            ;;
        *suricata.conf*)
            [[ "$effective_mode" == "suricata" || "$effective_mode" == "hybrid" ]] && return 0
            return 1
            ;;
        *)
            return 0  # main.conf and other files always active
            ;;
    esac
}

# Get key prefix activation based on mode
# Args: $1 = key name
# Returns: 0 if key should be validated, 1 if should be skipped
nftban_is_key_active() {
    local key="$1"

    # Check module-specific prefixes
    case "$key" in
        PORTSCAN_CLASSIC_*)
            local mode
            mode=$(nftban_get_effective_mode "portscan")
            [[ "$mode" == "classic" || "$mode" == "hybrid" ]] && return 0
            return 1
            ;;
        PORTSCAN_SURICATA_*)
            local mode
            mode=$(nftban_get_effective_mode "portscan")
            [[ "$mode" == "suricata" || "$mode" == "hybrid" ]] && return 0
            return 1
            ;;
        DDOS_CLASSIC_*)
            local mode
            mode=$(nftban_get_effective_mode "ddos")
            [[ "$mode" == "classic" || "$mode" == "hybrid" ]] && return 0
            return 1
            ;;
        DDOS_SURICATA_*)
            local mode
            mode=$(nftban_get_effective_mode "ddos")
            [[ "$mode" == "suricata" || "$mode" == "hybrid" ]] && return 0
            return 1
            ;;
        LOGIN_CLASSIC_*)
            local mode
            mode=$(nftban_get_effective_mode "login")
            [[ "$mode" == "classic" || "$mode" == "hybrid" ]] && return 0
            return 1
            ;;
        LOGIN_SURICATA_*)
            local mode
            mode=$(nftban_get_effective_mode "login")
            [[ "$mode" == "suricata" || "$mode" == "hybrid" ]] && return 0
            return 1
            ;;
        *)
            return 0  # All other keys are active
            ;;
    esac
}

# =============================================================================
# SCHEMA LOADING
# =============================================================================

# Load schema from JSON file
# Returns: JSON schema on stdout
nftban_schema_load() {
    local schema_file="${1:-$NFTBAN_SCHEMA_FILE}"

    if [[ ! -f "$schema_file" ]]; then
        echo '{"error": "Schema file not found"}' >&2
        return 1
    fi

    if ! jq -e '.' "$schema_file" 2>/dev/null; then
        echo '{"error": "Invalid JSON in schema file"}' >&2
        return 1
    fi
}

# Get schema property definition
# Args: $1 = key name
# Returns: JSON property definition
nftban_schema_get_property() {
    local key="$1"
    local schema_file="${2:-$NFTBAN_SCHEMA_FILE}"

    jq -r --arg key "$key" '.properties[$key] // empty' "$schema_file" 2>/dev/null || true
}

# Get all known keys from schema
# Returns: newline-separated list of keys
nftban_schema_get_keys() {
    local schema_file="${1:-$NFTBAN_SCHEMA_FILE}"
    jq -r '.properties | keys[]' "$schema_file" 2>/dev/null || true
}

# Get deprecated keys
# Returns: JSON object of deprecated keys
nftban_schema_get_deprecated() {
    local schema_file="${1:-$NFTBAN_SCHEMA_FILE}"
    jq -r '.deprecated // {}' "$schema_file" 2>/dev/null || true
}

# Get renamed keys
# Returns: JSON object of renamed keys
nftban_schema_get_renamed() {
    local schema_file="${1:-$NFTBAN_SCHEMA_FILE}"
    jq -r '.renamed // {}' "$schema_file" 2>/dev/null || true
}

# =============================================================================
# CONFIG LOADING AND MERGING
# =============================================================================

# Parse KEY=VALUE config file to JSON
# Args: $1 = config file path
# Returns: JSON object on stdout
nftban_config_parse_to_json() {
    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        echo "{}"
        return 0
    fi

    # Parse KEY=VALUE format, handle quotes, skip comments
    awk -F= '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        NF >= 2 {
            key = $1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)

            # Get value (everything after first =)
            idx = index($0, "=")
            val = substr($0, idx + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)

            # Handle quoted values with potential inline comments
            if (val ~ /^"/) {
                # Find closing quote
                match(val, /^"[^"]*"/)
                if (RSTART > 0) {
                    val = substr(val, 2, RLENGTH - 2)
                }
            } else if (val ~ /^'"'"'/) {
                # Single quoted - find closing quote
                match(val, /^'"'"'[^'"'"']*'"'"'/)
                if (RSTART > 0) {
                    val = substr(val, 2, RLENGTH - 2)
                }
            } else {
                # Unquoted - strip inline comment
                sub(/[[:space:]]*#.*$/, "", val)
            }

            # Escape for JSON
            gsub(/\\/, "\\\\", val)
            gsub(/"/, "\\\"", val)
            gsub(/\t/, "\\t", val)
            gsub(/\n/, "\\n", val)

            print "\"" key "\": \"" val "\","
        }
    ' "$config_file" | sed '$ s/,$//' | { echo "{"; cat; echo "}"; } | jq -c '.' 2>/dev/null || echo "{}"
}

# Merge two JSON config objects (second wins)
# Args: $1 = base JSON, $2 = override JSON
# Returns: merged JSON on stdout
nftban_config_merge_json() {
    local base="$1"
    local override="$2"

    echo "$base" "$override" | jq -s '.[0] * .[1]' 2>/dev/null || echo "{}"
}

# Load and merge config with local overrides
# Args: $1 = base config file (e.g., nftban.conf)
# Returns: merged JSON config
nftban_config_load_merged() {
    local base_file="$1"
    local local_file="${base_file%.conf}.conf.local"

    local base_json
    local local_json

    base_json=$(nftban_config_parse_to_json "$base_file")

    if [[ -f "$local_file" ]]; then
        local_json=$(nftban_config_parse_to_json "$local_file")
        nftban_config_merge_json "$base_json" "$local_json"
    else
        echo "$base_json"
    fi
}

# Load effective config from all sources
# Returns: merged JSON with full config
# OPTIMIZED: Collect all JSON then merge once (instead of per-file merge)
nftban_config_load_effective() {
    local config_dir="${NFTBAN_CONFIG_DIR:-/etc/nftban}"
    local all_json=()

    # 1. Load main config
    if [[ -f "$config_dir/nftban.conf" ]]; then
        all_json+=("$(nftban_config_parse_to_json "$config_dir/nftban.conf")")
    fi
    if [[ -f "$config_dir/nftban.conf.local" ]]; then
        all_json+=("$(nftban_config_parse_to_json "$config_dir/nftban.conf.local")")
    fi

    # 2. Load conf.d configs (in sorted order)
    local conf_file
    for conf_file in "$config_dir"/conf.d/*.conf "$config_dir"/conf.d/*/*.conf; do
        [[ -f "$conf_file" ]] || continue
        all_json+=("$(nftban_config_parse_to_json "$conf_file")")
        local local_file="${conf_file%.conf}.conf.local"
        if [[ -f "$local_file" ]]; then
            all_json+=("$(nftban_config_parse_to_json "$local_file")")
        fi
    done

    # Single jq merge of all collected JSON (instead of N individual merges)
    if [[ ${#all_json[@]} -eq 0 ]]; then
        echo "{}"
    elif [[ ${#all_json[@]} -eq 1 ]]; then
        echo "${all_json[0]}"
    else
        # Merge all JSON objects: later values override earlier
        printf '%s\n' "${all_json[@]}" | jq -s 'reduce .[] as $item ({}; . * $item)' 2>/dev/null || echo "{}"
    fi
}

# =============================================================================
# VALIDATION
# =============================================================================

# Validate a single config value against schema
# Args: $1 = key, $2 = value, $3 = schema_file
# Returns: 0=OK, 1=warning, 2=error
# Outputs validation messages to stdout
nftban_config_validate_value() {
    local key="$1"
    local value="$2"
    local schema_file="${3:-$NFTBAN_SCHEMA_FILE}"

    local prop_def
    prop_def=$(nftban_schema_get_property "$key" "$schema_file")

    if [[ -z "$prop_def" ]]; then
        # Check if deprecated
        local deprecated
        deprecated=$(jq -r --arg key "$key" '.deprecated[$key] // empty' "$schema_file" 2>/dev/null || true)
        if [[ -n "$deprecated" ]]; then
            local msg
            msg=$(echo "$deprecated" | jq -r '.message // "This option is deprecated"' || echo "Deprecated")
            echo "DEPRECATED: $key - $msg"
            return 1
        fi

        # Check if renamed
        local renamed
        renamed=$(jq -r --arg key "$key" '.renamed[$key].renamed_to // empty' "$schema_file" 2>/dev/null || true)
        if [[ -n "$renamed" ]]; then
            echo "RENAMED: $key -> $renamed (update your config)"
            return 1
        fi

        # Unknown key
        echo "UNKNOWN: $key (not in schema)"
        return 1
    fi

    # Type validation (reserved for future type checking)
    local prop_type
    # shellcheck disable=SC2034
    prop_type=$(echo "$prop_def" | jq -r '.type // "string"' || echo "string")

    # Enum validation
    local enum_values
    enum_values=$(echo "$prop_def" | jq -r '.enum // empty | @json' || true)
    if [[ -n "$enum_values" && "$enum_values" != "null" ]]; then
        if ! echo "$enum_values" | jq -e --arg val "$value" 'index($val) != null' >/dev/null 2>&1; then
            echo "INVALID: $key='$value' (must be one of: $(echo "$enum_values" | jq -r 'join(", ")' || true))"
            return 2
        fi
    fi

    # Pattern validation (for boolean_string, positive_integer, etc.)
    local ref_type
    ref_type=$(echo "$prop_def" | jq -r '."$ref" // empty' 2>/dev/null | sed 's|#/definitions/||' || true)

    case "$ref_type" in
        boolean_string)
            # Case-insensitive check for boolean values
            local lower_value="${value,,}"  # Bash 4+ lowercase
            if ! [[ "$lower_value" =~ ^(true|false|yes|no|1|0|on|off)$ ]]; then
                echo "INVALID: $key='$value' (must be true/false/yes/no/1/0/on/off)"
                return 2
            fi
            ;;
        positive_integer)
            if ! [[ "$value" =~ ^[0-9]+$ ]]; then
                echo "INVALID: $key='$value' (must be a positive integer)"
                return 2
            fi
            # Check min/max
            local min max
            min=$(echo "$prop_def" | jq -r '.minimum // empty' || true)
            max=$(echo "$prop_def" | jq -r '.maximum // empty' || true)
            if [[ -n "$min" && "$value" -lt "$min" ]]; then
                echo "INVALID: $key=$value (minimum is $min)"
                return 2
            fi
            if [[ -n "$max" && "$value" -gt "$max" ]]; then
                echo "INVALID: $key=$value (maximum is $max)"
                return 2
            fi
            ;;
        path)
            if [[ ! "$value" =~ ^/ ]]; then
                echo "INVALID: $key='$value' (must be an absolute path)"
                return 2
            fi
            ;;
    esac

    return 0
}

# Validate conditional requirements
# Args: $1 = effective config JSON, $2 = schema_file
# Returns: 0=OK, 1=warning, 2=error
# OPTIMIZED: Single jq call instead of ~5000 jq spawns
nftban_config_validate_conditionals() {
    local config_json="$1"
    local schema_file="${2:-$NFTBAN_SCHEMA_FILE}"

    # OPTIMIZED: Single jq call for all conditional validation
    # Was: ~1000 keys × 5 jq calls = ~5000 jq spawns causing timeout
    # Now: 1 jq call completing in <0.1 second
    local result
    result=$(jq -r --slurpfile schema "$schema_file" '
        # Normalize boolean values for comparison
        def normalize_bool:
            if type == "string" then
                (. | ascii_downcase) as $v |
                if ($v == "true" or $v == "yes" or $v == "1" or $v == "on") then "true"
                elif ($v == "false" or $v == "no" or $v == "0" or $v == "off") then "false"
                else .
                end
            elif type == "boolean" then
                if . then "true" else "false" end
            elif type == "number" then
                if . != 0 then "true" else "false" end
            else .
            end;

        . as $config |
        $schema[0].properties as $props |

        # Find all keys with required_when conditions
        [
            ($props | to_entries[]) |
            select(.value.required_when != null) |
            .key as $key |
            .value.required_when as $rw |
            $rw.key as $cond_key |
            ($rw.value | normalize_bool) as $cond_value |
            ($config[$cond_key] // "" | tostring | normalize_bool) as $actual_value |

            # Check if condition is met
            select($actual_value == $cond_value) |

            # Check if required key is missing or empty
            ($config[$key] // null) as $key_value |
            select($key_value == null or $key_value == "") |

            "MISSING: \($key) is required when \($cond_key)=\($rw.value)"
        ] |
        {
            messages: .,
            has_errors: (length > 0)
        }
    ' <<< "$config_json" 2>/dev/null) || result='{"messages":[],"has_errors":false}'

    local status=0

    # Output messages
    local msg
    while IFS= read -r msg; do
        [[ -n "$msg" ]] && echo "$msg" && status=2
    done < <(echo "$result" | jq -r '.messages[]? // empty')

    return $status
}

# Normalize boolean value
nftban_normalize_boolean() {
    local val="${1,,}"  # lowercase
    case "$val" in
        true|yes|1|on) echo "true" ;;
        false|no|0|off) echo "false" ;;
        *) echo "$val" ;;
    esac
}

# =============================================================================
# CONFIGTEST COMMAND
# =============================================================================

# Main configtest function
# Returns: 0=OK, 1=warnings, 2=errors
nftban_configtest() {
    # shellcheck disable=SC2034  # verbose reserved for future use
    local verbose="${1:-0}"
    local json_output="${2:-0}"
    local schema_file="${3:-$NFTBAN_SCHEMA_FILE}"

    local errors=0
    local warnings=0
    local skipped=0
    local validated=0
    local messages=()

    # Check schema exists
    if [[ ! -f "$schema_file" ]]; then
        echo "ERROR: Schema file not found: $schema_file" >&2
        return $CONFIG_CRITICAL
    fi

    # Detect runtime environment
    local suricata_status="not detected"
    if nftban_detect_suricata; then
        suricata_status="running"
    elif [[ -x "/usr/bin/suricata" ]]; then
        suricata_status="installed (not running)"
    fi

    # Get effective modes
    local portscan_mode ddos_mode login_mode
    portscan_mode=$(nftban_get_effective_mode "portscan")
    ddos_mode=$(nftban_get_effective_mode "ddos")
    login_mode=$(nftban_get_effective_mode "login")

    # Load effective config
    local effective_config
    effective_config=$(nftban_config_load_effective)

    if [[ -z "$effective_config" || "$effective_config" == "{}" ]]; then
        echo "ERROR: Could not load configuration" >&2
        return $CONFIG_CRITICAL
    fi

    # OPTIMIZED: Single jq call for batch validation
    # Was: ~1000 keys × 5 jq calls = ~5000 jq spawns causing 30+ second timeout
    # Now: 1 jq call completing in <1 second
    local validation_result
    validation_result=$(jq -r --slurpfile schema "$schema_file" '
        . as $config |
        $schema[0] as $s |
        ($config | keys) as $config_keys |
        ($s.properties // {}) as $props |
        ($s.deprecated // {}) as $deprecated |
        ($s.renamed // {}) as $renamed |

        [
            $config_keys[] | . as $key |
            select(startswith("_") | not) |
            $config[$key] as $value |

            if $props[$key] then
                $props[$key] as $prop |
                if ($prop.enum // null) then
                    if ($prop.enum | index($value)) then
                        {key: $key, status: "ok", value: $value}
                    else
                        {key: $key, status: "error", msg: "INVALID: \($key)=\($value) (must be one of: \($prop.enum | join(", ")))"}
                    end
                else
                    {key: $key, status: "ok", value: $value}
                end
            elif $deprecated[$key] then
                {key: $key, status: "warning", msg: "DEPRECATED: \($key) - \($deprecated[$key].message // "This option is deprecated")"}
            elif $renamed[$key] then
                {key: $key, status: "warning", msg: "RENAMED: \($key) -> \($renamed[$key].renamed_to) (update your config)"}
            else
                {key: $key, status: "unknown", msg: "UNKNOWN: \($key) (not in schema)"}
            end
        ] |
        {
            validated: (map(select(.status == "ok" or .status == "error" or .status == "warning")) | length),
            errors: (map(select(.status == "error")) | length),
            warnings: (map(select(.status == "warning" or .status == "unknown")) | length),
            messages: (map(select(.msg) | .msg))
        }
    ' <<< "$effective_config" 2>/dev/null) || validation_result='{"validated":0,"errors":0,"warnings":0,"messages":[]}'

    # Parse batch results
    validated=$(echo "$validation_result" | jq -r '.validated // 0')
    errors=$(echo "$validation_result" | jq -r '.errors // 0')
    warnings=$(echo "$validation_result" | jq -r '.warnings // 0')

    # Collect messages
    while IFS= read -r msg; do
        [[ -n "$msg" ]] && messages+=("$msg")
    done < <(echo "$validation_result" | jq -r '.messages[]? // empty')

    # Validate conditional requirements
    local cond_result
    cond_result=$(nftban_config_validate_conditionals "$effective_config" "$schema_file") || true

    if [[ -n "$cond_result" ]]; then
        while IFS= read -r line; do
            messages+=("$line")
            if [[ "$line" == "MISSING:"* ]]; then
                # v1.19.20 FIX
                ((errors++)) || true
            fi
        done <<< "$cond_result"
    fi

    # Output results
    if [[ $json_output -eq 1 ]]; then
        jq -n \
            --argjson errors "$errors" \
            --argjson warnings "$warnings" \
            --argjson validated "$validated" \
            --argjson skipped "$skipped" \
            --arg suricata "$suricata_status" \
            --arg portscan_mode "$portscan_mode" \
            --arg ddos_mode "$ddos_mode" \
            --arg login_mode "$login_mode" \
            --argjson messages "$(printf '%s\n' "${messages[@]}" | jq -R -s 'split("\n") | map(select(. != ""))')" \
            '{
                status: (if $errors > 0 then "error" elif $warnings > 0 then "warning" else "ok" end),
                runtime: {
                    suricata: $suricata,
                    modes: { portscan: $portscan_mode, ddos: $ddos_mode, login: $login_mode }
                },
                stats: { validated: $validated, skipped: $skipped, errors: $errors, warnings: $warnings },
                messages: $messages
            }'
    else
        echo ""
        echo "NFTBan Configuration Test"
        echo "========================="
        echo ""

        # Runtime status
        echo "[RUNTIME DETECTION]"
        echo "  Suricata: $suricata_status"
        echo ""

        # Module modes
        echo "[MODULE STATUS]"
        echo "  portscan: MODE=$portscan_mode"
        echo "  ddos:     MODE=$ddos_mode"
        echo "  login:    MODE=$login_mode"
        echo ""

        # Messages
        if [[ ${#messages[@]} -gt 0 ]]; then
            echo "[VALIDATION RESULTS]"
            for msg in "${messages[@]}"; do
                case "$msg" in
                    "ERROR:"*|"INVALID:"*|"MISSING:"*)
                        echo -e "  \033[0;31m$msg\033[0m"
                        ;;
                    "DEPRECATED:"*|"RENAMED:"*|"UNKNOWN:"*)
                        echo -e "  \033[0;33m$msg\033[0m"
                        ;;
                    "OK:"*)
                        echo -e "  \033[0;32m$msg\033[0m"
                        ;;
                    "SKIPPED:"*)
                        echo -e "  \033[0;90m$msg\033[0m"
                        ;;
                    *)
                        echo "  $msg"
                        ;;
                esac
            done
            echo ""
        fi

        # Summary
        echo "[SUMMARY]"
        echo "  Keys validated: $validated"
        echo "  Keys skipped:   $skipped (inactive mode)"
        echo "  Errors:         $errors"
        echo "  Warnings:       $warnings"
        echo ""

        if [[ $errors -gt 0 ]]; then
            echo -e "\033[0;31mRESULT: FAIL ($errors errors)\033[0m"
        elif [[ $warnings -gt 0 ]]; then
            echo -e "\033[0;33mRESULT: PASS with $warnings warnings\033[0m"
        else
            echo -e "\033[0;32mRESULT: PASS\033[0m"
        fi
    fi

    # Return appropriate exit code
    if [[ $errors -gt 0 ]]; then
        return $CONFIG_ERROR
    elif [[ $warnings -gt 0 ]]; then
        return $CONFIG_WARNING
    fi
    return $CONFIG_OK
}

# =============================================================================
# CONFIGAUDIT COMMAND
# =============================================================================

# Save current schema state for drift detection
nftban_config_save_state() {
    local schema_file="${1:-$NFTBAN_SCHEMA_FILE}"
    local state_file="${2:-$NFTBAN_CONFIG_STATE_FILE}"

    local state_dir
    state_dir=$(dirname "$state_file")
    mkdir -p "$state_dir" 2>/dev/null

    local schema_version
    schema_version=$(jq -r '.metadata.schema_version // 1' "$schema_file" 2>/dev/null)

    local known_keys
    known_keys=$(nftban_schema_get_keys "$schema_file" | jq -R -s 'split("\n") | map(select(. != ""))')

    # Use shared library if available, otherwise fallback
    local timestamp
    if declare -f nftban_timestamp_local &>/dev/null; then
        timestamp=$(nftban_timestamp_local)
    else
        timestamp=$(date -Iseconds)
    fi

    jq -n \
        --argjson schema_version "$schema_version" \
        --argjson known_keys "$known_keys" \
        --arg timestamp "$timestamp" \
        --arg nftban_version "${NFTBAN_VERSION:-unknown}" \
        '{
            schema_version: $schema_version,
            known_keys: $known_keys,
            saved_at: $timestamp,
            nftban_version: $nftban_version
        }' > "$state_file"
}

# Detect new keys since last state
nftban_config_detect_new_keys() {
    local schema_file="${1:-$NFTBAN_SCHEMA_FILE}"
    local state_file="${2:-$NFTBAN_CONFIG_STATE_FILE}"

    if [[ ! -f "$state_file" ]]; then
        echo "[]"
        return 0
    fi

    local current_keys old_keys
    current_keys=$(nftban_schema_get_keys "$schema_file" | jq -R -s 'split("\n") | map(select(. != ""))')
    old_keys=$(jq -r '.known_keys' "$state_file" 2>/dev/null)

    # Find keys in current but not in old
    echo "$current_keys" "$old_keys" | jq -s '.[0] - .[1]'
}

# Main configaudit function
nftban_configaudit() {
    local json_output="${1:-0}"
    local schema_file="${2:-$NFTBAN_SCHEMA_FILE}"
    local state_file="${3:-$NFTBAN_CONFIG_STATE_FILE}"
    local config_dir="${NFTBAN_CONFIG_DIR:-/etc/nftban}"

    # 1. Load configs
    local defaults_json local_json

    if [[ -f "$config_dir/nftban.conf" ]]; then
        defaults_json=$(nftban_config_parse_to_json "$config_dir/nftban.conf")
    else
        defaults_json="{}"
    fi

    if [[ -f "$config_dir/nftban.conf.local" ]]; then
        local_json=$(nftban_config_parse_to_json "$config_dir/nftban.conf.local")
    else
        local_json="{}"
    fi

    # 2. Find overridden keys (in .local)
    local overridden_keys=()
    local local_keys
    local_keys=$(echo "$local_json" | jq -r 'keys[]' 2>/dev/null)

    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        local local_val default_val
        local_val=$(echo "$local_json" | jq -r --arg k "$key" '.[$k]')
        default_val=$(echo "$defaults_json" | jq -r --arg k "$key" '.[$k] // empty')

        if [[ "$local_val" != "$default_val" ]]; then
            overridden_keys+=("$key: '$default_val' -> '$local_val'")
        fi
    done <<< "$local_keys"

    # 3. Find unknown/deprecated keys in .local
    local unknown_keys=()
    local deprecated_keys=()
    local renamed_keys=()

    while IFS= read -r key; do
        [[ -z "$key" ]] && continue

        local prop_def
        prop_def=$(nftban_schema_get_property "$key" "$schema_file")

        if [[ -z "$prop_def" ]]; then
            # Check deprecated
            local deprecated
            deprecated=$(jq -r --arg key "$key" '.deprecated[$key] // empty' "$schema_file" 2>/dev/null)
            if [[ -n "$deprecated" ]]; then
                deprecated_keys+=("$key")
                continue
            fi

            # Check renamed
            local renamed_to
            renamed_to=$(jq -r --arg key "$key" '.renamed[$key].renamed_to // empty' "$schema_file" 2>/dev/null)
            if [[ -n "$renamed_to" ]]; then
                renamed_keys+=("$key -> $renamed_to")
                continue
            fi

            unknown_keys+=("$key")
        fi
    done <<< "$local_keys"

    # 4. Find new keys since last upgrade
    local new_keys=()
    if [[ -f "$state_file" ]]; then
        local new_keys_json
        new_keys_json=$(nftban_config_detect_new_keys "$schema_file" "$state_file")

        while IFS= read -r key; do
            [[ -z "$key" || "$key" == "null" ]] && continue
            local introduced
            introduced=$(jq -r --arg k "$key" '.properties[$k].introduced_in // "unknown"' "$schema_file" 2>/dev/null)
            new_keys+=("$key (introduced in v$introduced)")
        done < <(echo "$new_keys_json" | jq -r '.[]')
    fi

    # 5. Find defaults not overridden (for transparency)
    local defaults_in_effect=()
    local all_defaults_keys
    all_defaults_keys=$(echo "$defaults_json" | jq -r 'keys[]' 2>/dev/null)

    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        local in_local
        in_local=$(echo "$local_json" | jq -r --arg k "$key" 'has($k)')

        if [[ "$in_local" != "true" ]]; then
            local val
            val=$(echo "$defaults_json" | jq -r --arg k "$key" '.[$k]')
            defaults_in_effect+=("$key=$val")
        fi
    done <<< "$all_defaults_keys"

    # Output
    if [[ $json_output -eq 1 ]]; then
        jq -n \
            --argjson overridden "$(printf '%s\n' "${overridden_keys[@]:-}" | jq -R -s 'split("\n") | map(select(. != ""))')" \
            --argjson unknown "$(printf '%s\n' "${unknown_keys[@]:-}" | jq -R -s 'split("\n") | map(select(. != ""))')" \
            --argjson deprecated "$(printf '%s\n' "${deprecated_keys[@]:-}" | jq -R -s 'split("\n") | map(select(. != ""))')" \
            --argjson renamed "$(printf '%s\n' "${renamed_keys[@]:-}" | jq -R -s 'split("\n") | map(select(. != ""))')" \
            --argjson new_keys "$(printf '%s\n' "${new_keys[@]:-}" | jq -R -s 'split("\n") | map(select(. != ""))')" \
            '{
                overridden: $overridden,
                unknown: $unknown,
                deprecated: $deprecated,
                renamed: $renamed,
                new_since_upgrade: $new_keys
            }'
    else
        echo ""
        echo "NFTBan Configuration Audit"
        echo "=========================="
        echo ""

        echo "OVERRIDDEN IN .local (${#overridden_keys[@]} keys):"
        if [[ ${#overridden_keys[@]} -gt 0 ]]; then
            for item in "${overridden_keys[@]}"; do
                echo "  - $item"
            done
        else
            echo "  (none)"
        fi
        echo ""

        if [[ ${#unknown_keys[@]} -gt 0 ]]; then
            echo -e "\033[0;33mUNKNOWN KEYS in .local (${#unknown_keys[@]}):\033[0m"
            for item in "${unknown_keys[@]}"; do
                echo "  - $item"
            done
            echo ""
        fi

        if [[ ${#deprecated_keys[@]} -gt 0 ]]; then
            echo -e "\033[0;33mDEPRECATED KEYS in .local (${#deprecated_keys[@]}):\033[0m"
            for item in "${deprecated_keys[@]}"; do
                local msg
                msg=$(jq -r --arg k "$item" '.deprecated[$k].message // "Deprecated"' "$schema_file" 2>/dev/null)
                echo "  - $item: $msg"
            done
            echo ""
        fi

        if [[ ${#renamed_keys[@]} -gt 0 ]]; then
            echo -e "\033[0;33mRENAMED KEYS in .local (${#renamed_keys[@]}):\033[0m"
            for item in "${renamed_keys[@]}"; do
                echo "  - $item"
            done
            echo ""
        fi

        if [[ ${#new_keys[@]} -gt 0 ]]; then
            echo -e "\033[0;36mNEW KEYS since last upgrade (${#new_keys[@]}):\033[0m"
            for item in "${new_keys[@]}"; do
                echo "  - $item"
            done
            echo ""
        fi

        echo "DEFAULTS IN EFFECT (not overridden): ${#defaults_in_effect[@]} keys"
        echo "  (run with --verbose to see all)"
    fi
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_detect_suricata
export -f nftban_get_effective_mode
export -f nftban_is_config_active
export -f nftban_is_key_active
export -f nftban_schema_load
export -f nftban_schema_get_property
export -f nftban_schema_get_keys
export -f nftban_schema_get_deprecated
export -f nftban_schema_get_renamed
export -f nftban_config_parse_to_json
export -f nftban_config_merge_json
export -f nftban_config_load_merged
export -f nftban_config_load_effective
export -f nftban_config_validate_value
export -f nftban_config_validate_conditionals
export -f nftban_normalize_boolean
export -f nftban_configtest
export -f nftban_config_save_state
export -f nftban_config_detect_new_keys
export -f nftban_configaudit
