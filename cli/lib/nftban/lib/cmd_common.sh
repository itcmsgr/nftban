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
        # intentional word-split on IFS='.' for octet parsing
        # shellcheck disable=SC2206
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
        # v1.153 UX-C2: parse-error paths must NOT reprint the ~30-line usage
        # block. When a usage_func is supplied we instead emit a single
        # actionable pointer line. The full usage text remains available via the
        # explicit `--help` path (which calls the usage_func directly). We derive
        # the command name from the conventional usage-func name
        # (nftban_cmd_<name>_usage -> <name>) so the hint points at the right
        # --help. Falls back to a generic pointer when the name is unconventional.
        if [[ -n "$usage_func" ]] && declare -f "$usage_func" &>/dev/null; then
            local _cmd_name="$usage_func"
            _cmd_name="${_cmd_name#nftban_cmd_}"   # strip leading nftban_cmd_
            _cmd_name="${_cmd_name%_usage}"        # strip trailing _usage
            _cmd_name="${_cmd_name//_/ }"          # underscores -> spaces (subcmds)
            if [[ -n "$_cmd_name" && "$_cmd_name" != "$usage_func" ]]; then
                echo "  Run 'nftban ${_cmd_name} --help' for more" >&2
            else
                echo "  Run 'nftban <command> --help' for more" >&2
            fi
        fi
    fi
    return 1
}

# v1.153 UX-C6 — _require_root_or_sudo_hint: a small guard that prints the
# inline sudo / root-shell re-run guidance (via _v142_sudo_hint) when the
# caller is not root, and returns non-zero so the caller can abort. Unlike
# cmd_require_root this does NOT also emit the PolicyKit advisory line — it is
# the minimal "you need root, here is how" guard for command entry points that
# want the hint without the full advisory. Returns 0 when already root.
#
# Usage: _require_root_or_sudo_hint ["operation description"] ["$json_mode"]
_require_root_or_sudo_hint() {
    local operation="${1:-this operation}"
    local json_mode="${2:-false}"
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        if [[ "$json_mode" != "true" ]]; then
            echo "ERROR: '${operation}' requires root privileges" >&2
        fi
        _v142_sudo_hint "$operation" "$json_mode"
        return 1
    fi
    return 0
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

# v1.142 UX-C6 — inline sudo / root-shell guidance helper.
# Prints to STDERR (never STDOUT, never JSON). Caller controls whether to
# also emit a structured error via cmd_error / json_error first; this
# helper only adds the actionable re-run hint.
#
# Why this exists: the codebase's existing privilege-check helpers
# (cmd_require_root, nftban_require_root, nftban_require_root_or_exit)
# previously printed the PolicyKit advisory without the actual command
# operators need to run. v1.139.2 UX review C6 flagged the gap: an
# operator hitting EUID-required failure had to know to write
# `sudo NFTBAN_FORCE=1 /usr/lib/nftban/bin/nftban update` rather than
# the anti-pattern `export NFTBAN_FORCE=1; sudo nftban update` (the
# export is lost across the sudo boundary).
#
# Args:
#   $1 — optional operation description (e.g. "ban an IP")
#   $2 — optional json_mode ("true" suppresses the hint chrome — JSON
#        consumers got the structured error via the caller's cmd_error /
#        json_error and don't need re-run guidance in stderr).
#
# Output (stderr only, no banner chrome, no decorative ━━━ runs):
#   (blank line)
#   Need root for "<operation>". Re-run with one of:
#     sudo VAR=value /usr/lib/nftban/bin/nftban <command>     # sudo user
#         VAR=value /usr/lib/nftban/bin/nftban <command>     # root shell
#   (Inline VAR=value is preserved across the sudo boundary. Do NOT use
#    `export VAR=value; sudo nftban X` — the export is dropped.)
#   (blank line)
#
# Returns 0 always; never short-circuits the caller's own return value.
# (Scope: NFTBAN_ROADMAP/V1_142_0_CLEANUP_PLAN.md §2 UX-RESIDUAL UX-C6.)
_v142_sudo_hint() {
    local _op="${1:-this operation}"
    local _json="${2:-false}"
    [[ "$_json" == "true" ]] && return 0
    # Resolve the operator-facing binary path. The dispatcher at
    # /usr/sbin/nftban is the typical wrapper; the actual binary is at
    # /usr/lib/nftban/bin/nftban-core for daemon calls, but the user-
    # facing CLI lives at the canonical /usr/lib/nftban/bin/nftban
    # symlink target. We print the canonical lib path because (a) that
    # path is stable under PATH rewrites and (b) it bypasses any /usr/
    # sbin alias that might require its own sudo policy.
    local _bin="${NFTBAN_BIN:-/usr/lib/nftban/bin/nftban}"
    {
        echo ""
        echo "Need root for \"${_op}\". Re-run with one of:"
        echo "  sudo VAR=value ${_bin} <command>     # sudo user"
        echo "      VAR=value ${_bin} <command>     # root shell"
        echo "(Inline VAR=value is preserved across the sudo boundary. Do NOT use"
        echo " \`export VAR=value; sudo nftban X\` — the export is dropped.)"
        echo ""
    } >&2
    return 0
}

# _v144_error_with_hint — concise three-line operator error format.
#
# UX-C2 closure (v1.144.0 PR-B): the historical pattern across many
# cmd_*.sh files was to print a one-line ERROR followed by the full
# ~30-line show_usage block on every parse error. That's wall-of-text
# noise — and many error paths don't even need usage context, just a
# pointer to the right next command. This helper emits at most three
# stderr lines:
#
#   ERROR: <err>
#     Hint: <hint>            (omitted if empty)
#     Run:  <runhelp>         (omitted if empty)
#
# The full multi-line `show_usage` block remains the rendering for
# `--help` paths (explicit user request) — it is NOT replaced. Only
# parse-error paths migrate to this helper. The v1.143.0 rc-contract
# (rc=1 on ERROR + ERROR-to-STDERR) is preserved: this helper always
# returns 1 unless an explicit rc override is passed as $4.
#
# Args:
#   $1 — error message (required; the "ERROR: <err>" line)
#   $2 — optional one-line hint (e.g. "missing --type argument")
#   $3 — optional "Run: <hint>" cmd string (e.g. "nftban connector help")
#   $4 — optional rc override (default 1; pass 2 for warning-class)
#
# Output: stderr only; no banner, no decorative chrome.
# Returns: 1 by default; $4 if provided.
# (Scope: NFTBAN_ROADMAP/V1_144_0_DOC_UX_DRIFT_PLAN.md §3.2 UX-C2.)
_v144_error_with_hint() {
    local _err="${1:-Unspecified error}"
    local _hint="${2:-}"
    local _runhelp="${3:-}"
    local _rc="${4:-1}"
    {
        echo "ERROR: ${_err}"
        [[ -n "${_hint}" ]]     && echo "  Hint: ${_hint}"
        [[ -n "${_runhelp}" ]]  && echo "  Run:  ${_runhelp}"
    } >&2
    return "${_rc}"
}

# Check if running as root
# Usage: cmd_require_root "$json_mode" ["operation description"]
# Returns: 0 if root, 1 otherwise
cmd_require_root() {
    local json_mode="${1:-false}"
    local operation="${2:-this operation}"

    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        cmd_error "PolicyKit/polkit authorization failed or insufficient privileges" "$json_mode"
        # v1.142 UX-C6: emit actionable re-run guidance on the same error
        # path. Honors json_mode (no hint chrome in JSON mode).
        _v142_sudo_hint "$operation" "$json_mode"
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
  systemctl start nftband    # nftban group members are polkit-authorized
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

# v1.228.7: cmd_get_geoip_binary REMOVED — it returned the retired standalone
# nftban-geoip path and had no callers. GeoIP is `nftban-core geoip` now.

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
        # IMPL-1: ensure _source_local is defined wherever this file is loaded (env.sh idempotent)
        declare -F _source_local >/dev/null 2>&1 || source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/env.sh" 2>/dev/null || true
        _source_local "${config_base}/main.conf.local"
    fi
}

# v1.228.7: the single "is module X enabled?" authority lives in
# lib/module_authority.sh (nftban_module_effective_enabled). Source it here so
# every consumer that loads cmd_common.sh gets it; the lib is idempotent.
if ! declare -F nftban_module_effective_enabled >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/module_authority.sh" 2>/dev/null || true
fi

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
export -f _v142_sudo_hint  # v1.142 UX-C6 — inline sudo / root-shell guidance
export -f _v144_error_with_hint  # v1.144.0 PR-B UX-C2 — three-line ERROR/Hint/Run
export -f _require_root_or_sudo_hint  # v1.153 UX-C6 — root guard + inline sudo hint
export -f cmd_show_banner
export -f cmd_section
export -f cmd_kv
export -f cmd_success
export -f cmd_get_core_binary
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
