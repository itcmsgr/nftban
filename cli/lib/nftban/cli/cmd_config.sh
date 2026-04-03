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
# meta:version="1.51.0"
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
    source "$JSON_HELPER" || return 1
fi

# =============================================================================
# DEPENDENCIES
# =============================================================================

# Load config module
if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_config.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/core/nftban_config.sh" || return 1
else
    echo "ERROR: Configuration module not found" >&2
    return 1
fi

# Load schema validation module
if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_config_schema.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/core/nftban_config_schema.sh" || return 1
fi

# Load config doctor module (v1.51.0)
if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_config_doctor.sh" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR}/core/nftban_config_doctor.sh" || return 1
fi

# Load IPC library for reload verification
if [[ -f "${NFTBAN_LIB_DIR}/lib/nft_ipc.sh" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR}/lib/nft_ipc.sh" || return 1
fi

# =============================================================================
# USAGE
# =============================================================================

show_usage() {
    cat <<'EOF'
Usage: nftban config <command> [module] [options]

INTEGRITY COMMANDS:
  validate [--verbose] [--json]    Validate config values against schema
  audit [--json]                   Semantic override analysis (dead/stale/unapplied)
  diff [--kernel] [--json]         Value-level diff (base<>local, config<>kernel)
  doctor [--module M] [--json]     Full system integrity audit (config+kernel+runtime)

CONFIGURATION COMMANDS:
  show                             Show effective merged configuration
  get <module> [--json]            Get module configuration
  defaults <module> [--json]       Show module default values
  overrides <module> [--json]      Show module local overrides
  set <module> KEY=VALUE           Set override in .conf.local
  reset <module> KEY               Remove single override
  reset-all <module>               Remove all module overrides

SERVICE COMMANDS:
  apply [module]                   Apply config to running services
  status                           Show config reload status

MODULES: portscan, ddos, login, geoip, geoban, botguard, suricata, feeds, trust

  health = "Is my system running correctly RIGHT NOW?" (services, processes, perms)
  doctor = "Is my system CONFIGURED correctly?" (config<>kernel<>runtime alignment)

EXAMPLES:
  nftban config validate              # Schema validation
  nftban config doctor                # Full system integrity audit
  nftban config doctor --module ddos  # Audit single module
  nftban config diff                  # Base vs local overrides
  nftban config diff --kernel         # Config vs kernel state
  nftban config get portscan --json   # Module config in JSON
  sudo nftban config set portscan PORTSCAN_BAN_THRESHOLD=15
  sudo nftban config apply portscan   # Apply to running service

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
        echo "ERROR: Schema validation module not available" >&2
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
        echo "ERROR: Schema validation module not available" >&2
        return 1
    fi

    nftban_configaudit "$json_mode"
}

nftban_cmd_config_show() {
    # Show effective merged configuration
    local json_mode="${1:-0}"

    # Check if schema module is loaded
    if ! command -v nftban_config_load_effective >/dev/null 2>&1; then
        echo "ERROR: Schema validation module not available" >&2
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

        # v1.43.0 P3-35: Divergence explanation footer
        echo ""
        echo "────────────────────────────────────────────────────────"
        echo "NOTE: Config values above reflect files on disk."
        echo "The running nftables ruleset may differ if:"
        echo "  1. Config was changed but daemon not reloaded"
        echo "  2. Manual nft commands were run outside NFTBan"
        echo "  3. A health fix or rebuild is in progress"
        echo ""
        echo "To compare:  nftban config diff"
        echo "To reload:   nftban config reload"
        echo "To verify:   nftban validate"
    fi
}

# =============================================================================
# CONFIG RELOAD - Smart reload for all NFTBan services
# =============================================================================
# Module -> Service mapping (persistent daemons only)
declare -A _CONFIG_MODULE_SERVICE=(
    ["portscan"]="nftband"
    ["ddos"]="nftband"
    ["login"]="nftban-login-monitor"
    ["geoban"]="nftband"
    ["suricata"]="nftban-suricata"
    ["ui"]="nftban-ui"
    ["daemon"]="nftband"
)

# Services that support SIGHUP reload
declare -a _CONFIG_SIGHUP_SERVICES=(
    "nftband"
    "nftban-login-monitor"
    "nftban-ui"
    "nftban-suricata"
)

# Timer-based services (no reload needed - pick up config on next run)
declare -a _CONFIG_TIMER_SERVICES=(
    "feeds"
    "metrics"
    "zabbix"
    "geoip"
)

# Config tracking directory
readonly _CONFIG_TRACK_DIR="/run/nftban/config-loaded"

# Check if daemon supports IPC reload (returns config_hash in status)
# Returns: 0 if supports reload, 1 if not
_config_daemon_supports_reload() {
    local service="$1"
    # Only nftband has IPC socket
    [[ "$service" != "nftband" ]] && return 1

    # Check if daemon responds to status with config_hash
    # Use the helper function from nft_ipc.sh
    nft_ipc_supports_reload 2>/dev/null
}

# Request reload via IPC and verify
# Returns: 0 if reload confirmed, 1 if failed
_config_ipc_reload() {
    local service="$1"
    [[ "$service" != "nftband" ]] && return 1

    local response
    response=$(nft_ipc_reload 2>/dev/null) || return 1
    nft_ipc_success "$response"
}

_config_service_running() {
    systemctl is-active "${1}.service" &>/dev/null
}

_config_send_sighup() {
    local service="$1"
    local pid
    pid=$(systemctl show "${service}.service" -p MainPID --value 2>/dev/null)
    [[ -z "$pid" || "$pid" == "0" ]] && return 1
    kill -HUP "$pid" 2>/dev/null
}

_config_get_checksum() {
    # Get SHA256 checksum of config file
    local file="$1"
    if [[ -f "$file" ]]; then sha256sum "$file" 2>/dev/null | cut -d' ' -f1; else echo "missing"; fi
}

_config_save_loaded() {
    # Save checksums of currently loaded config (called after reload)
    mkdir -p "$_CONFIG_TRACK_DIR" || return 1
    local config_dir="${NFTBAN_CONFIG_DIR:-/etc/nftban}"

    # Main config
    _config_get_checksum "$config_dir/nftban.conf" > "$_CONFIG_TRACK_DIR/nftban.conf.sha256.tmp" && mv -f "$_CONFIG_TRACK_DIR/nftban.conf.sha256.tmp" "$_CONFIG_TRACK_DIR/nftban.conf.sha256"
    [[ -f "$config_dir/nftban.conf.local" ]] && \
        { _config_get_checksum "$config_dir/nftban.conf.local" > "$_CONFIG_TRACK_DIR/nftban.conf.local.sha256.tmp" && mv -f "$_CONFIG_TRACK_DIR/nftban.conf.local.sha256.tmp" "$_CONFIG_TRACK_DIR/nftban.conf.local.sha256"; }

    # Module configs
    for conf in "$config_dir"/conf.d/*/*.conf "$config_dir"/conf.d/*.conf; do
        [[ -f "$conf" ]] || continue
        local name
        name=$(basename "$conf")
        _config_get_checksum "$conf" > "$_CONFIG_TRACK_DIR/${name}.sha256.tmp" && mv -f "$_CONFIG_TRACK_DIR/${name}.sha256.tmp" "$_CONFIG_TRACK_DIR/${name}.sha256"
        [[ -f "${conf}.local" ]] && \
            { _config_get_checksum "${conf}.local" > "$_CONFIG_TRACK_DIR/${name}.local.sha256.tmp" && mv -f "$_CONFIG_TRACK_DIR/${name}.local.sha256.tmp" "$_CONFIG_TRACK_DIR/${name}.local.sha256"; }
    done

    date +%s > "$_CONFIG_TRACK_DIR/.timestamp.tmp" && mv -f "$_CONFIG_TRACK_DIR/.timestamp.tmp" "$_CONFIG_TRACK_DIR/.timestamp"
}

_config_check_changes() {
    # Check if config files changed since last load
    # Returns: 0 if changed, 1 if same
    local config_dir="${NFTBAN_CONFIG_DIR:-/etc/nftban}"
    local changed=1

    [[ ! -d "$_CONFIG_TRACK_DIR" ]] && return 0  # Never loaded = changed

    # Check main config
    local current loaded
    current=$(_config_get_checksum "$config_dir/nftban.conf")
    loaded=$(cat "$_CONFIG_TRACK_DIR/nftban.conf.sha256" 2>/dev/null || echo "none")
    [[ "$current" != "$loaded" ]] && changed=0

    # Check .conf.local
    if [[ -f "$config_dir/nftban.conf.local" ]]; then
        current=$(_config_get_checksum "$config_dir/nftban.conf.local")
        loaded=$(cat "$_CONFIG_TRACK_DIR/nftban.conf.local.sha256" 2>/dev/null || echo "none")
        [[ "$current" != "$loaded" ]] && changed=0 || true
    fi

    return $changed
}

nftban_cmd_config_reload() {
    # Smart reload: prefers IPC reload with verification, falls back to SIGHUP
    # Timer-based services auto-reload on next run (no action needed)
    local module="${1:-all}"
    local reloaded=0
    local signaled=0
    local failed=0
    local needs_restart=0

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NFTBan Configuration Reload"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Check for timer-based module (no reload needed)
    local timer_module=""
    for tm in "${_CONFIG_TIMER_SERVICES[@]}"; do
        if [[ "$module" == "$tm" ]]; then
            timer_module="$tm"
            break
        fi
    done
    if [[ -n "$timer_module" ]]; then
        echo "Module '$timer_module' is timer-based."
        echo "Config changes take effect on next scheduled run."
        echo ""
        echo "To force immediate update: nftban $timer_module update"
        return 0
    fi

    # Step 1: Validate config
    echo "[1/2] Validating configuration..."
    local conf_local="${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf.local"
    if [[ -f "$conf_local" ]] && ! bash -n "$conf_local" 2>/dev/null; then
        echo "  ERROR: Syntax error in $conf_local"
        return 1
    fi
    echo "  Config syntax: OK"
    echo ""

    # Step 2: Reload services
    echo "[2/2] Reloading services..."

    # Helper to reload a single service
    _reload_service() {
        local svc="$1"
        printf "  %-30s " "$svc"

        # Try IPC reload first (only nftband supports this)
        if _config_daemon_supports_reload "$svc"; then
            if _config_ipc_reload "$svc"; then
                echo "[RELOADED via IPC]"
                # v1.19.20 FIX
                ((reloaded++)) || true
                return 0
            else
                echo "[IPC FAILED]"
                # v1.19.20 FIX
                ((failed++)) || true
                return 1
            fi
        fi

        # Fall back to SIGHUP (signal sent, but daemon may not reload)
        if _config_send_sighup "$svc"; then
            echo "[SIGHUP sent - restart required]"
            # v1.19.20 FIX
            ((signaled++)) || true
            ((needs_restart++)) || true
            return 0
        else
            echo "[FAILED]"
            # v1.19.20 FIX
            ((failed++)) || true
            return 1
        fi
    }

    if [[ "$module" == "all" || "$module" == "--all" ]]; then
        # Reload all running SIGHUP-capable services
        local svc
        for svc in "${_CONFIG_SIGHUP_SERVICES[@]}"; do
            if _config_service_running "$svc"; then
                _reload_service "$svc"
            fi
        done
    else
        # Reload specific module's service
        local service="${_CONFIG_MODULE_SERVICE[$module]:-}"
        if [[ -z "$service" ]]; then
            echo "  Unknown module: $module"
            echo "  Valid modules: ${!_CONFIG_MODULE_SERVICE[*]}"
            return 1
        fi

        if ! _config_service_running "$service"; then
            printf "  %-30s " "$service"
            echo "[NOT RUNNING]"
        else
            _reload_service "$service"
        fi
    fi

    # Save checksums of loaded config (only if IPC confirmed reload)
    if [[ $reloaded -gt 0 ]]; then
        _config_save_loaded 2>/dev/null || true
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ $reloaded -gt 0 ]]; then
        echo "  Reloaded: $reloaded (verified via IPC)"
    fi
    if [[ $signaled -gt 0 ]]; then
        echo "  Signaled: $signaled (SIGHUP sent)"
    fi
    if [[ $failed -gt 0 ]]; then
        echo "  Failed: $failed"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Warning if services need restart
    if [[ $needs_restart -gt 0 ]]; then
        echo ""
        echo "⚠ WARNING: $needs_restart service(s) received SIGHUP but daemon does not"
        echo "  support hot-reload yet. Config changes may require service restart:"
        echo ""
        for svc in "${_CONFIG_SIGHUP_SERVICES[@]}"; do
            if _config_service_running "$svc" && ! _config_daemon_supports_reload "$svc"; then
                echo "    systemctl restart $svc"
            fi
        done
    fi

    echo ""
    echo "Note: Timer-based services (feeds, metrics, zabbix, geoip) auto-reload"
    echo "      on their next scheduled run."

    [[ $failed -eq 0 ]]
}

nftban_cmd_config_status() {
    # Show config status: what's loaded vs what's on disk (only for enabled modules)
    local config_dir="${NFTBAN_CONFIG_DIR:-/etc/nftban}"

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NFTBan Configuration Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Show last reload time
    if [[ -f "$_CONFIG_TRACK_DIR/.timestamp" ]]; then
        local ts
        ts=$(cat "$_CONFIG_TRACK_DIR/.timestamp" 2>/dev/null)
        echo "Last reload: $(date -d "@$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$ts")"
    else
        echo "Last reload: Never (services using startup config)"
    fi
    echo ""

    # Check which services are running (only check those)
    printf "%-25s %-12s %-15s\n" "SERVICE" "STATUS" "CONFIG"
    echo "─────────────────────────────────────────────────────"

    local needs_reload=0
    for svc in "${_CONFIG_SIGHUP_SERVICES[@]}"; do
        local status="stopped"
        local config_status="-"

        if _config_service_running "$svc"; then
            status="running"

            # Check if config changed since load
            if [[ -f "$_CONFIG_TRACK_DIR/.timestamp" ]]; then
                if _config_check_changes; then
                    config_status="CHANGED"
                    needs_reload=1
                else
                    config_status="current"
                fi
            else
                config_status="not tracked"
            fi
        fi

        printf "%-25s %-12s %-15s\n" "$svc" "$status" "$config_status"
    done

    echo ""
    if [[ $needs_reload -eq 1 ]]; then
        echo "Config has changed. Run: nftban config reload"
    else
        echo "All running services have current config."
    fi
    echo ""
}

nftban_cmd_config_diff() {
    # Show differences between defaults and local overrides
    # v1.51.0: --kernel mode compares config vs kernel state
    local json_mode="0"
    local kernel_mode="0"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json_mode="1" ;;
            --kernel) kernel_mode="1" ;;
            *) ;;
        esac
        shift
    done

    # --kernel mode: config vs kernel state
    if [[ "$kernel_mode" == "1" ]]; then
        if command -v _doctor_diff_kernel >/dev/null 2>&1; then
            _doctor_diff_kernel "$json_mode"
        else
            echo "ERROR: Config doctor module not loaded (required for --kernel)" >&2
            return 1
        fi
        return $?
    fi

    local config_dir="${NFTBAN_CONFIG_DIR:-/etc/nftban}"

    echo "═══ Config Diff: BASE ↔ LOCAL ═══"
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
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
        if [[ $(type -t nftban_banner) == "function" ]]; then
            nftban_banner
        fi
    fi
    echo ""

    case "$subcommand" in
        get)
            if [[ -z "${1:-}" ]]; then
                echo "ERROR: Module name required" >&2
                echo "Usage: nftban config get <module> [--json]" >&2
                return 1
            fi
            nftban_cmd_config_get "$@"
            ;;

        defaults)
            if [[ -z "${1:-}" ]]; then
                echo "ERROR: Module name required" >&2
                echo "Usage: nftban config defaults <module> [--json]" >&2
                return 1
            fi
            nftban_cmd_config_defaults "$@"
            ;;

        overrides)
            if [[ -z "${1:-}" ]]; then
                echo "ERROR: Module name required" >&2
                echo "Usage: nftban config overrides <module> [--json]" >&2
                return 1
            fi
            nftban_cmd_config_overrides "$@"
            ;;

        set)
            if [[ -z "${1:-}" ]] || [[ -z "${2:-}" ]]; then
                echo "ERROR: Module name and KEY=VALUE required" >&2
                echo "Usage: nftban config set <module> KEY=VALUE" >&2
                return 1
            fi
            nftban_cmd_config_set "$@"
            ;;

        reset)
            if [[ -z "${1:-}" ]] || [[ -z "${2:-}" ]]; then
                echo "ERROR: Module name and KEY required" >&2
                echo "Usage: nftban config reset <module> KEY" >&2
                return 1
            fi
            nftban_cmd_config_reset "$@"
            ;;

        reset-all)
            if [[ -z "${1:-}" ]]; then
                echo "ERROR: Module name required" >&2
                echo "Usage: nftban config reset-all <module>" >&2
                return 1
            fi
            nftban_cmd_config_reset_all "$@"
            ;;

        validate|test)
            nftban_cmd_config_test "$@"
            ;;

        audit)
            nftban_cmd_config_audit "$@"
            ;;

        doctor)
            nftban_cmd_config_doctor "$@"
            ;;

        show)
            nftban_cmd_config_show "$@"
            ;;

        diff)
            nftban_cmd_config_diff "$@"
            ;;

        status)
            nftban_cmd_config_status "$@"
            ;;

        apply|reload)
            nftban_cmd_config_reload "$@"
            ;;

        help|-h|--help|"")
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
