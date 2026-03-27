#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="cmd_common" meta:type="lib" meta:version="1.39.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Reduces boilerplate in CLI handlers by providing common functions"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"

set -Eeuo pipefail

# Guard: Prevent double-loading
[[ -n "${NFTBAN_CMD_COMMON_LOADED:-}" ]] && return 0

# =============================================================================
# INITIALIZATION
# =============================================================================

# Initialize CLI command environment
# Loads standard libraries, sets up paths, enables strict mode
# Usage: cmd_init
# Example: cmd_init
cmd_init() {
    # Source central config for canonical paths
    # shellcheck source=/etc/nftban/nftban.conf
    if [[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" ]]; then
        source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" || true
    fi

    # Set default paths if not defined
    : "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"
    : "${NFTBAN_CONFIG_DIR:=/etc/nftban}"
    : "${NFTBAN_LOG_DIR:=/var/log/nftban}"

    # Load strict mode (or set manually as fallback)
    if [[ -f "${NFTBAN_LIB_DIR}/lib/strict.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/lib/strict.sh" || return 1
    else
        set -Eeuo pipefail
    fi
}

# Load standard helper libraries
# Usage: cmd_load_helpers [json] [schema] [version] [output]
# Example: cmd_load_helpers json schema
cmd_load_helpers() {
    local helpers=("$@")

    # If no args, load common set
    if [[ ${#helpers[@]} -eq 0 ]]; then
        helpers=(json schema version)
    fi

    for helper in "${helpers[@]}"; do
        case "$helper" in
            json)
                [[ -f "${NFTBAN_LIB_DIR}/helpers/json_output.sh" ]] && \
                    source "${NFTBAN_LIB_DIR}/helpers/json_output.sh" || return 1
                ;;
            schema)
                [[ -f "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" ]] && \
                    source "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" || return 1
                ;;
            version)
                [[ -f "${NFTBAN_LIB_DIR}/lib/version.sh" ]] && \
                    source "${NFTBAN_LIB_DIR}/lib/version.sh" || return 1
                ;;
            output)
                [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]] && \
                    source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
                ;;
            ipc)
                [[ -f "${NFTBAN_LIB_DIR}/lib/nft_ipc.sh" ]] && \
                    source "${NFTBAN_LIB_DIR}/lib/nft_ipc.sh" || return 1
                ;;
        esac
    done
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

# Check if help is requested
# Usage: cmd_wants_help "$@" && { show_usage; return 0; }
# Returns: 0 if help requested, 1 otherwise
cmd_wants_help() {
    for arg in "$@"; do
        case "$arg" in
            help|--help|-h)
                return 0
                ;;
        esac
    done
    return 1
}

# Check if JSON mode is requested (delegates to json_output.sh if available)
# Usage: local json_mode; json_mode=$(cmd_is_json_mode "$@")
# Returns: "true" or "false"
cmd_is_json_mode() {
    for arg in "$@"; do
        [[ "$arg" == "--json" ]] && { echo "true"; return 0; }
    done
    echo "false"
}

# Validate required argument
# Usage: cmd_require_arg "$ip" "IP address" "$json_mode" usage_func
# Returns: 0 if valid, 1 if missing (prints error)
cmd_require_arg() {
    local value="$1"
    local name="$2"
    local json_mode="${3:-false}"
    local usage_func="${4:-}"

    if [[ -z "$value" ]]; then
        cmd_error "$name is required" "$json_mode" "$usage_func"
        return 1
    fi
    return 0
}

# Validate IP address format (IPv4 or IPv6)
# Usage: cmd_validate_ip "$ip" "$json_mode" [usage_func]
# Returns: 0 if valid, 1 if invalid (prints error)
cmd_validate_ip() {
    local ip="$1"
    local json_mode="${2:-false}"
    local usage_func="${3:-}"

    # Empty check
    if [[ -z "$ip" ]]; then
        cmd_error "IP address cannot be empty" "$json_mode" "$usage_func"
        return 1
    fi

    # IPv4 validation (x.x.x.x or x.x.x.x/prefix)
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
        # Validate each octet is 0-255
        local ip_part="${ip%/*}"
        local IFS='.'
        # shellcheck disable=SC2206  -- intentional word-split on IFS='.' for octet parsing
        local octets=($ip_part)
        for octet in "${octets[@]}"; do
            if [[ "$octet" -gt 255 ]]; then
                cmd_error "Invalid IPv4 address: octet $octet > 255" "$json_mode" "$usage_func"
                return 1
            fi
        done
        return 0
    fi

    # IPv6 validation (simplified: contains colons, alphanumeric/colons only)
    if [[ "$ip" =~ ^[0-9a-fA-F:]+(/[0-9]{1,3})?$ ]] && [[ "$ip" == *:* ]]; then
        return 0
    fi

    cmd_error "Invalid IP address format: $ip" "$json_mode" "$usage_func"
    return 1
}

# =============================================================================
# ERROR HANDLING
# =============================================================================

# Print error message (JSON-aware)
# Usage: cmd_error "message" "$json_mode" [usage_func]
# Returns: 1 (always)
cmd_error() {
    local message="$1"
    local json_mode="${2:-false}"
    local usage_func="${3:-}"

    if [[ "$json_mode" == "true" ]] && declare -f json_error &>/dev/null; then
        json_error "$message"
    else
        echo "ERROR: $message" >&2
        if [[ -n "$usage_func" ]] && declare -f "$usage_func" &>/dev/null; then
            echo "" >&2
            "$usage_func" >&2
        fi
    fi
    return 1
}

# Print warning message (JSON-aware, doesn't return error)
# Usage: cmd_warn "message" "$json_mode"
cmd_warn() {
    local message="$1"
    local json_mode="${2:-false}"

    if [[ "$json_mode" != "true" ]]; then
        echo "WARNING: $message" >&2
    fi
}

# Print info message (suppressed in JSON mode)
# Usage: cmd_info "message" "$json_mode"
cmd_info() {
    local message="$1"
    local json_mode="${2:-false}"

    if [[ "$json_mode" != "true" ]]; then
        echo "$message"
    fi
}

# =============================================================================
# VALIDATION
# =============================================================================

# Check if binary exists
# Usage: cmd_require_binary "$NFTBAN_CORE" "nftban-core" "$json_mode"
# Returns: 0 if exists, 1 if missing (prints helpful error)
cmd_require_binary() {
    local binary="$1"
    local name="${2:-$(basename "$binary")}"
    local json_mode="${3:-false}"

    if [[ ! -x "$binary" ]]; then
        if [[ "$json_mode" == "true" ]] && declare -f json_error &>/dev/null; then
            json_error "$name binary not found at $binary"
        else
            cat >&2 <<EOF
ERROR: $name binary not found

Expected location: $binary

This command requires the $name Go binary.
In CLI-only mode (bash scripts only), this feature is unavailable.

Solutions:
  1. Install nftban with Go components: ./install.sh
  2. Build from source: go build -o bin/$name ./cmd/$name
EOF
        fi
        return 1
    fi
    return 0
}

# Check if running as root
# Usage: cmd_require_root "$json_mode"
# Returns: 0 if root, 1 otherwise
cmd_require_root() {
    local json_mode="${1:-false}"

    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        cmd_error "This command must be run as root" "$json_mode"
        return 1
    fi
    return 0
}

# Check if daemon is running
# Usage: cmd_require_daemon "$json_mode"
# Returns: 0 if running, 1 otherwise
cmd_require_daemon() {
    local json_mode="${1:-false}"
    local socket="${NFTBAN_SOCKET:-/run/nftban/nftband.sock}"

    if [[ ! -S "$socket" ]]; then
        if [[ "$json_mode" == "true" ]] && declare -f json_error &>/dev/null; then
            json_error "nftband daemon not running"
        else
            cat >&2 <<EOF
ERROR: nftband daemon not running

The daemon socket was not found at: $socket

Start the daemon with:
  sudo systemctl start nftband
EOF
        fi
        return 1
    fi
    return 0
}

# =============================================================================
# OUTPUT HELPERS
# =============================================================================

# Show banner (suppressed in JSON mode)
# Usage: cmd_show_banner "$json_mode" [banner_arg]
cmd_show_banner() {
    local json_mode="${1:-false}"
    local banner_arg="${2:-}"

    [[ "$json_mode" == "true" ]] && return 0

    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
        if declare -f nftban_banner &>/dev/null; then
            if [[ -n "$banner_arg" ]]; then
                nftban_banner "$banner_arg"
            else
                nftban_banner
            fi
        fi
    fi
    echo ""
}

# Print section header (suppressed in JSON mode)
# Usage: cmd_section "Section Title" "$json_mode"
cmd_section() {
    local title="$1"
    local json_mode="${2:-false}"

    [[ "$json_mode" == "true" ]] && return 0

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo " $title"
    echo "═══════════════════════════════════════════════════════════════"
}

# Print key-value pair (suppressed in JSON mode)
# Usage: cmd_kv "Key" "Value" "$json_mode"
cmd_kv() {
    local key="$1"
    local value="$2"
    local json_mode="${3:-false}"

    [[ "$json_mode" == "true" ]] && return 0

    printf "  %-20s %s\n" "${key}:" "$value"
}

# =============================================================================
# SUCCESS/RESULT OUTPUT
# =============================================================================

# Output success result (JSON-aware)
# Usage: cmd_success "message" "$json_data" "$json_mode"
cmd_success() {
    local message="$1"
    local json_data="${2:-{}}"
    local json_mode="${3:-false}"

    if [[ "$json_mode" == "true" ]] && declare -f json_success &>/dev/null; then
        json_success "$json_data"
    else
        echo "$message"
    fi
}

# =============================================================================
# PATH HELPERS
# =============================================================================

# Get nftban-core binary path
# Usage: local core; core=$(cmd_get_core_binary)
cmd_get_core_binary() {
    echo "${NFTBAN_CORE:-${NFTBAN_LIB_DIR}/bin/nftban-core}"
}

# Get nftban-geoip binary path
# Usage: local geoip; geoip=$(cmd_get_geoip_binary)
cmd_get_geoip_binary() {
    echo "${NFTBAN_GEOIP:-${NFTBAN_LIB_DIR}/bin/nftban-geoip}"
}

# Get GeoIP database path (auto-detects if not explicitly configured)
# Usage: local db; db=$(cmd_get_geoip_database)
# Returns: Path to database file, or empty string if not found
cmd_get_geoip_database() {
    local geoip_dir="${NFTBAN_DATA_DIR:-/var/lib/nftban}/geoip"

    # Use explicit config if set
    if [[ -n "${NFTBAN_GEOIP_DATABASE:-}" ]] && [[ -f "${NFTBAN_GEOIP_DATABASE}" ]]; then
        echo "${NFTBAN_GEOIP_DATABASE}"
        return 0
    fi

    # Auto-detect from supported databases (priority order from config)
    # IFS-safe split: strict.sh sets IFS=$'\n\t', so space-separated vars need explicit splitting
    local _geoip_dbs
    IFS=' ' read -ra _geoip_dbs <<< "${NFTBAN_GEOIP_DATABASES:-dbip-country-lite.mmdb GeoLite2-City.mmdb GeoLite2-Country.mmdb}"
    local db_file
    for db_file in "${_geoip_dbs[@]}"; do
        if [[ -f "${geoip_dir}/${db_file}" ]]; then
            echo "${geoip_dir}/${db_file}"
            return 0
        fi
    done

    # Not found
    return 1
}

# =============================================================================
# CONFIG LOADING HELPERS
# =============================================================================

cmd_load_module_config() {
    # Load module configuration with .local override support
    # Usage: cmd_load_module_config "ddos"
    # Loads: /etc/nftban/conf.d/ddos/main.conf
    #        /etc/nftban/conf.d/ddos/main.conf.local (if exists)
    local module="$1"
    local config_base="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/${module}"

    if [[ -f "${config_base}/main.conf" ]]; then
        # shellcheck source=/dev/null
        source "${config_base}/main.conf" || true
    fi

    # Load local overrides if they exist
    if [[ -f "${config_base}/main.conf.local" ]]; then
        # shellcheck source=/dev/null
        source "${config_base}/main.conf.local" || true
    fi
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================

export -f cmd_init
export -f cmd_load_helpers
export -f cmd_wants_help
export -f cmd_is_json_mode
export -f cmd_require_arg
export -f cmd_error
export -f cmd_warn
export -f cmd_info
export -f cmd_require_binary
export -f cmd_require_root
export -f cmd_require_daemon
export -f cmd_show_banner
export -f cmd_section
export -f cmd_kv
export -f cmd_success
export -f cmd_get_core_binary
export -f cmd_get_geoip_binary
export -f cmd_get_geoip_database
export -f cmd_load_module_config

# =============================================================================
# MARK AS LOADED
# =============================================================================

readonly NFTBAN_CMD_COMMON_LOADED=1
export NFTBAN_CMD_COMMON_LOADED

# =============================================================================
# MODULE LOADED SUCCESSFULLY
# =============================================================================

true
