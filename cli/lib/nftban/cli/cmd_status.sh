#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.3.0 - Global Status Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="cmd_status"
# meta:type="cli"
# meta:header="Global Status Command"
# meta:version="1.43.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Provides consolidated system status overview (firewall, services, protections, alerts)"
# meta:inventory.files=""
# meta:inventory.binaries="nft,systemctl"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2025-11-05"


# =============================================================================
# CONFIGURATION
# =============================================================================

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" 2>/dev/null || true

# Load strict mode library
# shellcheck source=/usr/lib/nftban/lib/strict.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/strict.sh" || return 1
else
    # Fallback to manual strict mode
    set -Eeuo pipefail
fi

# Load version library
# shellcheck source=/usr/lib/nftban/lib/version.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/version.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/version.sh" || return 1
fi


# Load NFT schema (single source of truth for table/set names)
# shellcheck source=/usr/lib/nftban/lib/nft_schema.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" || return 1
elif [[ -f "$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")/lib/nft_schema.sh" ]]; then
    # Development fallback: Load from relative path
    source "$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")/lib/nft_schema.sh" || return 1
else
    # Last resort: Set defaults
    NFTBAN_TABLE_IPV4="${NFTBAN_TABLE_IPV4:-ip nftban}"
    NFTBAN_TABLE_IPV6="${NFTBAN_TABLE_IPV6:-ip6 nftban}"
fi
# Load statistics library (for centralized counting)
# shellcheck source=/usr/lib/nftban/core/nftban_stats.sh
if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_stats.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/core/nftban_stats.sh" || return 1
elif [[ -f "$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")/core/nftban_stats.sh" ]]; then
    # Development fallback: Load from relative path
    source "$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")/core/nftban_stats.sh" || return 1
fi

# Load timestamp library (for unified timestamp formatting)
# shellcheck source=/usr/lib/nftban/lib/nftban_timestamp.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_timestamp.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_timestamp.sh" || return 1
elif [[ -f "$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")/lib/nftban_timestamp.sh" ]]; then
    source "$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")/lib/nftban_timestamp.sh" || return 1
fi

# Load service control library (for systemd service checks)
# shellcheck source=/usr/lib/nftban/lib/nftban_service_control.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_service_control.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_service_control.sh" || return 1
elif [[ -f "$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")/lib/nftban_service_control.sh" ]]; then
    source "$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")/lib/nftban_service_control.sh" || return 1
fi

# =============================================================================
# BINARY INTEGRITY VALIDATION
# =============================================================================

_status_check_binaries() {
    # Check if Go binaries are valid ELF files
    # Returns 0 if all binaries are valid, 1 if any are corrupted
    if ! command -v file >/dev/null 2>&1; then
        # 'file' command not available — skip check silently
        return 0
    fi
    local binaries=(
        "/usr/lib/nftban/bin/nftban-core"
        "/usr/lib/nftban/bin/nftband"
    )
    local has_corruption=0

    for binary in "${binaries[@]}"; do
        if [[ -f "$binary" ]]; then
            local file_type
            file_type=$(file -b "$binary" 2>/dev/null)
            if [[ "$file_type" != *"ELF"* ]]; then
                echo "WARNING: $(basename "$binary") is corrupted (not ELF binary)"
                has_corruption=1
            fi
        fi
    done
    return $has_corruption
}

# =============================================================================
# PROTECTION STATE — Single Source of Truth (v1.66.0)
# =============================================================================
# v1.66.0: 3-state model with kernel-first detection and reason codes.
# Returns: PROTECTED | DEGRADED[:reason] | DOWN
# Exit code contract:
#   0 = PROTECTED    — everything works
#   1 = DEGRADED     — firewall up but issues
#   2 = DOWN         — nothing protecting
# NFTBAN_EXIT_COMPAT=v1 → DEGRADED returns 0 (one-release transition)

_nftban_protection_state() {
    # Determine protection state from live kernel + service checks.
    # Returns: PROTECTED, DEGRADED:D-xxx, or DOWN
    local _nft_active=false _daemon_active=false _rules=0 _timers=0

    systemctl is-active nftables.service >/dev/null 2>&1 && _nft_active=true
    systemctl is-active nftband.service >/dev/null 2>&1 && _daemon_active=true
    if command -v nft >/dev/null 2>&1; then
        _rules=$(nft -a list table ${NFTBAN_TABLE_IPV4} 2>/dev/null | grep -c "# handle" 2>/dev/null || true)
        _rules="${_rules:-0}"
    fi
    _timers=$(systemctl list-timers 'nftban-*' --no-legend 2>/dev/null | wc -l || echo 0)

    # DOWN: kernel disabled, nftables not active, or no rules loaded
    if grep -q 'nftban=disabled' /proc/cmdline 2>/dev/null; then
        echo "DOWN"; return
    fi
    if [[ "$_nft_active" != "true" ]] || [[ "$_rules" -eq 0 ]]; then
        echo "DOWN"; return
    fi

    # nftables is active with rules — check for DEGRADED conditions

    # D-DAEMON: nftband not running
    if [[ "$_daemon_active" != "true" ]]; then
        echo "DEGRADED:D-DAEMON"; return
    fi

    # D-ANCHOR: invariant validator returned ERROR (structural problem)
    local _anchor_ok=true
    local _inv_lib="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_invariant_validator.sh"
    if [[ -f "$_inv_lib" ]]; then
        (
            # Subshell to avoid polluting caller's namespace
            # shellcheck source=/dev/null
            source "$_inv_lib" 2>/dev/null || exit 0
            if type nftban_validate_invariants &>/dev/null; then
                nftban_validate_invariants >/dev/null 2>&1 || exit $?
            fi
            exit 0
        )
        local _inv_exit=$?
        # exit 2 = ERROR (structural problem) → DEGRADED
        # exit 1 = WARNING (SSH port, empty whitelist) → still ok
        [[ $_inv_exit -ge 2 ]] && _anchor_ok=false
    fi
    if [[ "$_anchor_ok" == "false" ]]; then
        echo "DEGRADED:D-ANCHOR"; return
    fi

    # D-NOTIMERS: no nftban timers active
    if [[ "$_timers" -eq 0 ]]; then
        echo "DEGRADED:D-NOTIMERS"; return
    fi

    # v1.66.0: Kernel-first module detection — probe nft chains, not config files
    local _modules_active=0

    # DDoS: check kernel chain has rules
    local _ddos_rules=0
    _ddos_rules=$(nft -a list chain ip nftban ddos_protection 2>/dev/null \
        | grep -c "# handle" || true)
    [[ "${_ddos_rules:-0}" -gt 0 ]] && ((_modules_active++)) || true

    # Portscan: check kernel chain has rules
    local _ps_rules=0
    _ps_rules=$(nft -a list chain ip nftban portscan_detection 2>/dev/null \
        | grep -c "# handle" || true)
    [[ "${_ps_rules:-0}" -gt 0 ]] && ((_modules_active++)) || true

    # Suricata: service check (correct — it's an external service)
    systemctl is-active nftban-suricata >/dev/null 2>&1 && ((_modules_active++)) || true

    # Login monitor: runs inside nftband — check config + daemon
    if [[ "$_daemon_active" == "true" ]]; then
        local _lm_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/login/main.conf"
        local _lm_enabled="false"
        [[ -f "${_lm_conf}.local" ]] && _lm_enabled=$(grep -m1 '^NFTBAN_LOGIN_MONITOR_ENABLED=' "${_lm_conf}.local" 2>/dev/null | cut -d'"' -f2 || echo "false")
        [[ "$_lm_enabled" != "true" ]] && [[ -f "$_lm_conf" ]] && _lm_enabled=$(grep -m1 '^NFTBAN_LOGIN_MONITOR_ENABLED=' "$_lm_conf" 2>/dev/null | cut -d'"' -f2 || echo "false")
        [[ "$_lm_enabled" == "true" ]] && ((_modules_active++)) || true
    fi

    # D-NOMODULE: no detection modules in kernel
    if [[ "$_modules_active" -eq 0 ]]; then
        echo "DEGRADED:D-NOMODULE"; return
    fi

    echo "PROTECTED"
}

# =============================================================================
# CONFIG DIVERGENCE CHECK (v1.66.0)
# =============================================================================

_check_config_divergence() {
    # Compare config-enabled modules with kernel state.
    # Outputs divergent module names (one per line), empty if no divergence.
    local config_dir="${NFTBAN_CONFIG_DIR:-/etc/nftban}"

    # DDoS: config says enabled, kernel says no
    local _ddos_conf="false"
    if [[ -f "${config_dir}/conf.d/ddos/main.conf.local" ]]; then
        _ddos_conf=$(grep -m1 '^DDOS_ENABLED=' "${config_dir}/conf.d/ddos/main.conf.local" 2>/dev/null | cut -d'"' -f2 || echo "")
    fi
    if [[ -z "$_ddos_conf" || "$_ddos_conf" == "false" ]] && [[ -f "${config_dir}/conf.d/ddos/main.conf" ]]; then
        _ddos_conf=$(grep -m1 '^DDOS_ENABLED=' "${config_dir}/conf.d/ddos/main.conf" 2>/dev/null | cut -d'"' -f2 || echo "false")
    fi
    if [[ "$_ddos_conf" == "true" ]]; then
        local _ddos_rules=0
        _ddos_rules=$(nft -a list chain ip nftban ddos_protection 2>/dev/null | grep -c "# handle" || true)
        [[ "${_ddos_rules:-0}" -eq 0 ]] && echo "ddos"
    fi

    # Portscan: config says enabled, kernel says no
    local _ps_conf="false"
    if [[ -f "${config_dir}/conf.d/portscan/main.conf.local" ]]; then
        _ps_conf=$(grep -m1 '^PORTSCAN_ENABLED=' "${config_dir}/conf.d/portscan/main.conf.local" 2>/dev/null | cut -d'"' -f2 || echo "")
    fi
    if [[ -z "$_ps_conf" || "$_ps_conf" == "false" ]] && [[ -f "${config_dir}/conf.d/portscan/main.conf" ]]; then
        _ps_conf=$(grep -m1 '^PORTSCAN_ENABLED=' "${config_dir}/conf.d/portscan/main.conf" 2>/dev/null | cut -d'"' -f2 || echo "false")
    fi
    if [[ "$_ps_conf" == "true" ]]; then
        local _ps_rules=0
        _ps_rules=$(nft -a list chain ip nftban portscan_detection 2>/dev/null | grep -c "# handle" || true)
        [[ "${_ps_rules:-0}" -eq 0 ]] && echo "portscan"
    fi
}

# =============================================================================
# RULE COUNTING — Single Source of Truth (v1.24.0)
# =============================================================================

_nftban_count_rules() {
    # Count nftables rules consistently for both human and JSON output.
    local count
    count=$(nft -a list table ${NFTBAN_TABLE_IPV4} 2>/dev/null | grep -c "# handle" 2>/dev/null || true)
    echo "${count:-0}"
}

# =============================================================================
# STATUS AGGREGATION
# =============================================================================

nftban_cmd_status() {
    # Display global system status overview
    # Args: [--json] [--quiet]

    local json_mode=0
    local quiet_mode=0
    local brief_mode=0

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json|-j)
                json_mode=1
                shift
                ;;
            --quiet|-q)
                quiet_mode=1
                shift
                ;;
            --brief|-b)
                brief_mode=1
                shift
                ;;
            pending|queue)
                # v1.43.0 P3-25: Show pending/queued operations
                shift || true
                _nftban_status_pending "$@"
                return $?
                ;;
            help|-h|--help)
                show_usage
                return 0
                ;;
            *)
                echo "ERROR: Unknown option: $1" >&2
                show_usage >&2
                return 1
                ;;
        esac
    done

    # v1.24.0: Brief mode — one-line output for CI/fleet/monitoring
    if [[ $brief_mode -eq 1 ]]; then
        output_brief
        return $?
    fi

    # Show unified banner with health indicator (skip for JSON/quiet output)
    if [[ $json_mode -eq 0 ]] && [[ $quiet_mode -eq 0 ]]; then
        if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
            # shellcheck source=/dev/null
            source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
            # Use unified banner with health indicator
            if [[ $(type -t nftban_banner_unified) == "function" ]]; then
                nftban_banner_unified "status"
            elif [[ $(type -t nftban_banner) == "function" ]]; then
                nftban_banner
            fi
        fi
    fi

    # JSON mode
    if [[ $json_mode -eq 1 ]]; then
        output_json
        return $?
    fi

    # Terminal mode (default)
    output_terminal "$quiet_mode"
    return $?
}

output_brief() {
    # v1.66.0: One-line status output for CI/fleet/monitoring
    # Format: PROTECTED | v1.66.0 | 26 banned | 9 whitelisted | healthy
    # Exit codes: 0=PROTECTED, 1=DEGRADED, 2=DOWN

    local protection_state_raw
    protection_state_raw=$(_nftban_protection_state)
    local base_state="${protection_state_raw%%:*}"
    local reason="${protection_state_raw#*:}"
    [[ "$reason" == "$base_state" ]] && reason=""

    local ban_count=0
    if declare -f nftban_stats_count_active_bans >/dev/null 2>&1; then
        ban_count=$(nftban_stats_count_active_bans 2>/dev/null || echo 0)
    fi

    local whitelist_count=0
    if declare -f nftban_stats_count_whitelist >/dev/null 2>&1; then
        whitelist_count=$(nftban_stats_count_whitelist 2>/dev/null || echo 0)
    fi

    local health_cache="${NFTBAN_CACHE_DIR:-/var/cache/nftban}/health/health_status.cache"
    local health_word="unknown"
    if [[ -r "$health_cache" ]]; then
        local _hs
        _hs=$(cat "$health_cache" 2>/dev/null) || _hs="UNKNOWN"
        case "$_hs" in
            OK) health_word="healthy" ;;
            WARNING*) health_word="info" ;;
            ERROR*|CRITICAL*) health_word="errors" ;;
            *) health_word="unknown" ;;
        esac
    fi

    # When PROTECTED, health issues are informational not errors
    if [[ "$base_state" == "PROTECTED" && "$health_word" == "errors" ]]; then
        health_word="info"
    fi

    # v1.66.0: Include reason code for DEGRADED
    local display_state="$base_state"
    [[ -n "$reason" ]] && display_state="${base_state}:${reason}"

    echo "${display_state} | v${NFTBAN_VERSION:-unknown} | ${ban_count} banned | ${whitelist_count} whitelisted | ${health_word}"

    # v1.66.0: Exit code contract — 0=PROTECTED, 1=DEGRADED, 2=DOWN
    case "$base_state" in
        PROTECTED) return 0 ;;
        DEGRADED)
            # NFTBAN_EXIT_COMPAT=v1 → DEGRADED returns 0 (one-release transition)
            [[ "${NFTBAN_EXIT_COMPAT:-}" == "v1" ]] && return 0
            return 1
            ;;
        *) return 2 ;;
    esac
}

# =============================================================================
# STATUS SECTION HELPERS (v1.38.0)
# Each function renders one section of the terminal status output.
# Placed before output_terminal() to allow forward references.
# =============================================================================

_status_section_system() {
    # ─────────────────────────────────────────────────────────────────────
    # SYSTEM
    # ─────────────────────────────────────────────────────────────────────
    local protection_state_raw="$1"
    local base_state="${protection_state_raw%%:*}"
    local reason="${protection_state_raw#*:}"
    [[ "$reason" == "$base_state" ]] && reason=""

    # v1.66.0: Show reason in parentheses for DEGRADED
    local state_display="$base_state"
    [[ -n "$reason" ]] && state_display="${base_state} (${reason})"

    echo "SYSTEM"
    echo "───────────────────────────────────────────────────────────────"
    printf "  %-20s %s\n" "Hostname............" "$(hostname)"
    printf "  %-20s %s\n" "Kernel.............." "$(uname -r)"
    printf "  %-20s %s\n" "Uptime.............." "$(uptime -p 2>/dev/null | sed 's/^up //' || uptime | awk '{print $3, $4}' | sed 's/,$//')"
    printf "  %-20s %s\n" "NFTBan.............." "v${NFTBAN_VERSION:-unknown}"
    printf "  %-20s %s\n" "State..............." "$state_display"

    # v1.66.0: Config divergence hint
    local _divergence
    _divergence=$(_check_config_divergence 2>/dev/null)
    if [[ -n "$_divergence" ]]; then
        local _div_mod
        while IFS= read -r _div_mod; do
            [[ -n "$_div_mod" ]] && printf "  %-20s %s\n" "" "Config divergence: ${_div_mod} enabled in config but not in kernel — run 'nftban firewall rebuild'"
        done <<< "$_divergence"
    fi

    echo ""
}

_status_section_firewall() {
    # ─────────────────────────────────────────────────────────────────────
    # FIREWALL
    # ─────────────────────────────────────────────────────────────────────
    local quiet_mode="$1"

    echo "FIREWALL"
    echo "───────────────────────────────────────────────────────────────"

    local nft_status="INACTIVE"
    # Use service control library with graceful fallback
    if declare -f nftban_service_is_active &>/dev/null; then
        nftban_service_is_active nftables.service && nft_status="ACTIVE"
    elif systemctl is-active nftables.service >/dev/null 2>&1; then
        nft_status="ACTIVE"
    fi
    printf "  %-20s %s\n" "nftables............" "$nft_status"

    # v1.24.0: Use shared rule counting function
    local rule_count=0
    if command -v nft >/dev/null 2>&1; then
        rule_count=$(_nftban_count_rules)
    fi
    printf "  %-20s %s\n" "Rules..............." "$rule_count"

    # Count banned IPs (use centralized function)
    local ban_count=0
    if declare -f nftban_stats_count_active_bans >/dev/null 2>&1; then
        ban_count=$(nftban_stats_count_active_bans)
    fi
    printf "  %-20s %s\n" "Banned IPs.........." "$ban_count"

    # v1.38.0: Show footnote if cache and kernel counts differ
    if declare -f nftban_nft_count_blacklist >/dev/null 2>&1; then
        local _kernel_total
        _kernel_total=$(nftban_nft_count_blacklist 2>/dev/null | awk '{print $3}')
        _kernel_total=${_kernel_total:-0}
        if [[ "$_kernel_total" != "$ban_count" ]] && [[ "$_kernel_total" -gt 0 ]]; then
            printf "  %-20s %s\n" "" "(kernel: $_kernel_total, cache may lag)"
        fi
    fi

    # Count whitelisted IPs (SINGLE SOURCE OF TRUTH: nftban_stats.sh)
    local whitelist_count=0
    if declare -f nftban_stats_count_whitelist >/dev/null 2>&1; then
        whitelist_count=$(nftban_stats_count_whitelist)
    fi
    printf "  %-20s %s\n" "Whitelisted IPs....." "$whitelist_count"

    # Check master switch
    local master_enabled="true"
    if [[ -f "${NFTBAN_CONFIG_DIR}/conf.d/services.conf.local" ]]; then
        source "${NFTBAN_CONFIG_DIR}/conf.d/services.conf.local" 2>/dev/null || true
        master_enabled="${NFTBAN_ENABLED:-true}"
    fi

    local master_status="ENABLED"
    if grep -q 'nftban=disabled' /proc/cmdline 2>/dev/null; then
        master_status="DISABLED (kernel)"
    elif [[ "${master_enabled,,}" =~ ^(no|false|0|off)$ ]]; then
        master_status="DISABLED (config)"
    fi
    printf "  %-20s %s\n" "Master Control......" "$master_status"

    # Helpful hints (only in non-quiet mode)
    if [[ $quiet_mode -eq 0 ]] && [[ $ban_count -gt 0 || $whitelist_count -gt 0 ]]; then
        echo ""
        echo "  Quick Commands:"
        if [[ $ban_count -gt 0 ]]; then
            echo "    View banned IPs:     nftban list banned"
        fi
        if [[ $whitelist_count -gt 0 ]]; then
            echo "    View whitelist:      nftban list whitelist"
        fi
        echo "    View all:            nftban list all"
    fi
    echo ""
}

_status_section_services() {
    # ─────────────────────────────────────────────────────────────────────
    # SERVICES
    # ─────────────────────────────────────────────────────────────────────
    echo "SERVICES"
    echo "───────────────────────────────────────────────────────────────"

    check_service_clean "nftables" "nftables.service"
    check_service_clean "nftband" "nftband.service"
    check_service_clean "suricata" "suricata.service"
    check_service_clean "nftban-ui" "${NFTBAN_SERVICE_UI:-nftban-ui.service}"
    check_service_clean "nftban-suricata" "${NFTBAN_SERVICE_SURICATA:-nftban-suricata.service}"
    # v1.23.0: login-monitor removed (replaced by nftband loginmon module)
    check_service_clean "metrics-exporter" "${NFTBAN_SERVICE_METRICS_EXPORTER:-nftban-unified-exporter.service}"
    echo ""
}

_status_section_protection() {
    # ─────────────────────────────────────────────────────────────────────
    # PROTECTION MODULES
    # ─────────────────────────────────────────────────────────────────────
    local quiet_mode="$1"

    echo "PROTECTION MODULES"
    echo "───────────────────────────────────────────────────────────────"

    # Suricata IDS (check binary + service + EVE freshness for consistent reporting)
    # Matches the same 3-tier check used by portscan and ddos modules
    local suricata_status="NOT INSTALLED"
    local suricata_eve_ok=false
    local eve_threshold="${PORTSCAN_EVE_FRESHNESS_THRESHOLD:-60}"
    if command -v suricata &>/dev/null; then
        # Binary exists — check service (use library with fallback)
        local _suricata_active=false
        if declare -f nftban_service_is_active &>/dev/null; then
            nftban_service_is_active suricata.service && _suricata_active=true
        elif systemctl is-active suricata.service >/dev/null 2>&1; then
            _suricata_active=true
        fi

        if [[ "$_suricata_active" == "true" ]]; then
            # Service is running — verify EVE log is fresh (same check as portscan/ddos)
            # Support Suricata 7.x threaded logging: check all eve-alerts*.json files
            local eve_dir="${NFTBAN_LOG_DIR:-/var/log/nftban}/suricata"
            local eve_file="${PORTSCAN_SURICATA_EVE_FILE:-${eve_dir}/eve-alerts.json}"
            local eve_fresh=false
            local freshest_mtime=0

            shopt -s nullglob
            for f in "$eve_dir"/eve-alerts*.json; do
                [[ -f "$f" ]] || continue
                local m
                m=$(stat -L -c %Y -- "$f" 2>/dev/null) || continue
                [[ "$m" =~ ^[0-9]+$ ]] || continue
                (( m > freshest_mtime )) && freshest_mtime=$m
            done
            shopt -u nullglob

            if [[ $freshest_mtime -gt 0 ]]; then
                local now_ts eve_age
                # Use timestamp library with fallback
                if declare -f nftban_timestamp_unix &>/dev/null; then
                    now_ts=$(nftban_timestamp_unix)
                else
                    now_ts=$(date +%s)
                fi
                eve_age=$(( now_ts - freshest_mtime ))
                [[ $eve_age -le $eve_threshold ]] && eve_fresh=true
            fi

            if [[ "$eve_fresh" == "true" ]]; then
                suricata_eve_ok=true
                # Check rules_loaded from any EVE JSON file (main or threaded)
                local rules_loaded=0
                shopt -s nullglob
                for ef in "$eve_file" "$eve_dir"/eve-alerts.*.json; do
                    [[ -f "$ef" ]] || continue
                    rules_loaded=$(grep -o '"rules_loaded":[0-9]*' "$ef" 2>/dev/null | tail -1 | cut -d: -f2 || echo "0")
                    [[ "${rules_loaded:-0}" -gt 0 ]] && break
                done
                shopt -u nullglob

                if [[ "${rules_loaded:-0}" -eq 0 ]]; then
                    suricata_status="BROKEN (0 rules loaded!)"
                elif systemctl is-active nftban-suricata.service >/dev/null 2>&1; then
                    suricata_status="ACTIVE (IDS + Banning, ${rules_loaded} rules)"
                else
                    suricata_status="ACTIVE (IDS only, ${rules_loaded} rules)"
                fi
            else
                suricata_status="DEGRADED (running, EVE log stale)"
            fi
        else
            suricata_status="INSTALLED (stopped)"
        fi
    fi
    printf "  %-20s %s\n" "Suricata IDS........" "$suricata_status"

    # DDoS Protection (check config AND verify rules exist)
    local ddos_status="DISABLED"
    local ddos_main="${NFTBAN_CONFIG_DIR}/conf.d/ddos/main.conf"
    local ddos_local="${NFTBAN_CONFIG_DIR}/conf.d/ddos/main.conf.local"
    local ddos_enabled="false"

    # Load ddos config (new directory structure)
    [[ -f "$ddos_main" ]] && source "$ddos_main" 2>/dev/null || true
    [[ -f "$ddos_local" ]] && source "$ddos_local" 2>/dev/null || true
    ddos_enabled="${DDOS_ENABLED:-${NFTBAN_DDOS_ENABLED:-false}}"
    # Normalize boolean (config may use YES/NO, true/false, 1/0, on/off)
    [[ "${ddos_enabled,,}" =~ ^(yes|true|1|on)$ ]] && ddos_enabled="true" || ddos_enabled="false"

    # Check if DDoS rules actually exist in nftables
    local ddos_rules_exist="false"
    if nft list chain ip nftban ddos_protection &>/dev/null 2>&1; then
        ddos_rules_exist="true"
    fi

    if [[ "$ddos_enabled" == "true" ]] && [[ "$ddos_rules_exist" == "true" ]]; then
        ddos_status="ENABLED"
    elif [[ "$ddos_enabled" == "true" ]] && [[ "$ddos_rules_exist" == "false" ]]; then
        ddos_status="NOT INSTALLED"
    elif [[ "$ddos_enabled" != "true" ]] && [[ "$ddos_rules_exist" == "true" ]]; then
        ddos_status="RULES LOADED (use 'nftban ddos enable' to activate)"
    fi
    printf "  %-20s %s\n" "DDoS................" "$ddos_status"

    # Port-scan Detection (check config directly to avoid recursion)
    local portscan_status="DISABLED"
    local portscan_main="${NFTBAN_CONFIG_DIR}/conf.d/portscan/main.conf"
    local portscan_local="${NFTBAN_CONFIG_DIR}/conf.d/portscan/main.conf.local"
    local portscan_enabled="false"

    # Load portscan config (new directory structure)
    [[ -f "$portscan_main" ]] && source "$portscan_main" 2>/dev/null || true
    [[ -f "$portscan_local" ]] && source "$portscan_local" 2>/dev/null || true
    portscan_enabled="${PORTSCAN_ENABLED:-false}"
    # Normalize boolean (config may use YES/NO, true/false, 1/0, on/off)
    [[ "${portscan_enabled,,}" =~ ^(yes|true|1|on)$ ]] && portscan_enabled="true" || portscan_enabled="false"

    if [[ "$portscan_enabled" == "true" ]]; then
        if [[ "$suricata_eve_ok" == "true" ]]; then
            portscan_status="ENABLED (Suricata mode)"
        elif systemctl is-active suricata.service >/dev/null 2>&1; then
            portscan_status="ENABLED (Classic — Suricata EVE stale)"
        else
            portscan_status="ENABLED (Classic mode)"
        fi
    elif [[ "$suricata_eve_ok" == "true" ]]; then
        portscan_status="AVAILABLE (not enabled)"
    fi
    printf "  %-20s %s\n" "Port Scan..........." "$portscan_status"

    # Protection module explanation (if not quiet mode)
    if [[ $quiet_mode -eq 0 ]]; then
        local show_note=false

        # Show note if portscan or ddos are enabled
        if [[ "$portscan_enabled" == "true" ]] || [[ "$ddos_enabled" == "true" ]]; then
            show_note=true
        fi

        if [[ "$show_note" == "true" ]]; then
            echo ""
            echo "  Detection Modes:"
            if [[ "$portscan_enabled" == "true" ]]; then
                if [[ "$suricata_eve_ok" == "true" ]]; then
                    echo "    Port Scan: Using Suricata IDS (deep packet inspection)"
                elif systemctl is-active suricata.service >/dev/null 2>&1; then
                    echo "    Port Scan: Classic mode (Suricata running but EVE stale)"
                else
                    echo "    Port Scan: Classic mode (nftables log monitoring)"
                fi
            fi
            if [[ "$ddos_enabled" == "true" ]]; then
                echo "    DDoS: Active (connection rate limiting + SYN flood protection)"
            fi
            echo ""
            echo "  View details: nftban portscan status | nftban ddos status"
        fi
    fi
    echo ""

    # Trust Feeds (CDN whitelist - including Cloudflare)
    local trust_status="NOT INSTALLED"
    local trust_count=0
    if command -v nftban-core &>/dev/null; then
        local trust_output
        trust_output=$(nftban-core trust list 2>/dev/null) || true
        trust_count=$(echo "$trust_output" | grep -c "enabled" 2>/dev/null) || trust_count=0
        if [[ $trust_count -gt 0 ]]; then
            trust_status="ENABLED ($trust_count feeds)"
        else
            trust_status="DISABLED"
        fi
    fi
    printf "  %-20s %s\n" "Trust Feeds........." "$trust_status"
    # Show last-updated timestamp if trust data exists
    local trust_data_dir="${NFTBAN_DATA_DIR:-/var/lib/nftban}/trust"
    if [[ -d "$trust_data_dir" ]]; then
        local newest_file
        newest_file=$(find "$trust_data_dir" -name "*.txt" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
        if [[ -n "$newest_file" ]]; then
            local last_updated
            last_updated=$(stat -c '%Y' "$newest_file" 2>/dev/null) || true
            if [[ -n "$last_updated" ]]; then
                printf "      %-16s %s\n" "Last updated...." "$(date -d "@$last_updated" '+%Y-%m-%d %H:%M' 2>/dev/null || echo 'unknown')"
            fi
        fi
    fi

    # Feeds
    local feeds_enabled=0
    if [[ -d "${NFTBAN_DATA_DIR}/feeds" ]]; then
        feeds_enabled=$(find "${NFTBAN_DATA_DIR}/feeds" -name "*.txt" -type f 2>/dev/null | wc -l)
    fi
    printf "  %-20s %s Active\n" "Threat Feeds........" "$feeds_enabled"
    [[ "$feeds_enabled" -eq 0 ]] && printf "      %-16s %s\n" "" "(list: nftban feeds list | enable: nftban feeds enable <FEED>)"

    # Login Monitor (v1.52.0: runs inside nftband as loginmon module)
    # v1.56.0 FIX: Check both LOGIN_ENABLED (Go daemon config) and
    #   NFTBAN_LOGIN_ALERT_ENABLED (bash alert config) — `nftban login enable` writes LOGIN_ENABLED
    local login_mon_status="DISABLED"
    if systemctl is-active --quiet nftband.service 2>/dev/null; then
        local _lm_en="false"
        # Check Go daemon loginmon config (LOGIN_ENABLED — written by `nftban login enable`)
        local _lm_go_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/login/main.conf"
        [[ -f "${_lm_go_conf}.local" ]] && _lm_en=$(grep -m1 '^LOGIN_ENABLED=' "${_lm_go_conf}.local" 2>/dev/null | cut -d'"' -f2 || echo "false")
        [[ "$_lm_en" != "true" ]] && [[ -f "$_lm_go_conf" ]] && _lm_en=$(grep -m1 '^LOGIN_ENABLED=' "$_lm_go_conf" 2>/dev/null | cut -d'"' -f2 || echo "false")
        # Fallback: check bash alert config (NFTBAN_LOGIN_ALERT_ENABLED)
        if [[ "$_lm_en" != "true" ]]; then
            local _lm_alert_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/login_alert.conf"
            [[ -f "${_lm_alert_conf}.local" ]] && _lm_en=$(grep -m1 '^NFTBAN_LOGIN_ALERT_ENABLED=' "${_lm_alert_conf}.local" 2>/dev/null | cut -d'"' -f2 || echo "false")
            [[ "$_lm_en" != "true" ]] && [[ -f "$_lm_alert_conf" ]] && _lm_en=$(grep -m1 '^NFTBAN_LOGIN_ALERT_ENABLED=' "$_lm_alert_conf" 2>/dev/null | cut -d'"' -f2 || echo "false")
        fi
        if [[ "$_lm_en" == "true" ]]; then
            login_mon_status="ACTIVE (nftband loginmon)"
        fi
    fi
    printf "  %-20s %s\n" "Login Monitor......." "$login_mon_status"
    [[ "$login_mon_status" == "DISABLED" ]] && printf "      %-16s %s\n" "" "(enable: nftban login enable)"

    # GeoIP (database module) - use nftban-core directly for accurate detection
    local geoip_status="NOT INSTALLED"
    local nftban_core="${NFTBAN_LIB_DIR}/bin/nftban-core"
    [[ ! -x "$nftban_core" ]] && nftban_core=$(command -v nftban-core 2>/dev/null || echo "")
    if [[ -n "$nftban_core" ]] && [[ -x "$nftban_core" ]]; then
        if "$nftban_core" geoip status >/dev/null 2>&1; then
            # Get database info from status output
            local db_info
            db_info=$("$nftban_core" geoip status 2>/dev/null | grep -i "database" | head -1 || echo "")
            if [[ -n "$db_info" ]]; then
                geoip_status="ACTIVE"
            else
                geoip_status="ACTIVE"
            fi
        else
            geoip_status="DB MISSING (run: nftban geoip update)"
        fi
    fi
    printf "  %-20s %s\n" "GeoIP..............." "$geoip_status"

    # GeoBan (country blocking module) - separate from GeoIP database
    local geoban_status="DISABLED"
    local banned_countries
    banned_countries=$(nftban geoban list 2>/dev/null | grep -c "BLOCKED" 2>/dev/null || echo "0")
    banned_countries=$(echo "$banned_countries" | tr -d '\n' | tr -d ' ')
    if [[ "$banned_countries" =~ ^[0-9]+$ ]] && [[ "$banned_countries" -gt 0 ]]; then
        geoban_status="ACTIVE ($banned_countries countries blocked)"
    fi
    printf "  %-20s %s\n" "GeoBan.............." "$geoban_status"
    [[ "$geoban_status" == "DISABLED" ]] && printf "      %-16s %s\n" "" "(enable: nftban geoban add <CC>)"

    # RBL Monitoring
    local rbl_status="DISABLED"
    local rbl_last_check=""

    if [[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/rbl/main.conf" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/rbl/main.conf" || true
    fi
    # v1.19.0: Source .local override (user customizations survive package updates)
    if [[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/rbl/main.conf.local" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/rbl/main.conf.local" || true
    fi
    if [[ "${NFTBAN_RBL_ENABLED:-NO}" == "YES" ]]; then
        rbl_status="ENABLED"
    fi

    # Check last check time
    local rbl_last_file="${NFTBAN_LOG_DIR:-/var/log/nftban}/rbl/last_check"
    if [[ -f "$rbl_last_file" ]]; then
        local last_ts
        last_ts=$(cat "$rbl_last_file" 2>/dev/null)
        if [[ -n "$last_ts" ]]; then
            local now_ts
            now_ts=$(date +%s)
            local diff=$((now_ts - last_ts))
            if [[ $diff -lt 3600 ]]; then
                rbl_last_check="$((diff / 60)) min ago"
            elif [[ $diff -lt 86400 ]]; then
                rbl_last_check="$((diff / 3600)) hours ago"
            else
                rbl_last_check="$((diff / 86400)) days ago"
            fi
        fi
    fi

    printf "  %-21s %s" "RBL Monitoring........" "$rbl_status"
    if [[ -n "$rbl_last_check" ]]; then
        printf " (last: %s)" "$rbl_last_check"
    fi
    echo ""

    # HTTP Bot Guard (v1.20.0)
    local botguard_status="DISABLED"
    local botguard_enabled="false"
    if [[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/botguard/main.conf" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/botguard/main.conf" || true
    fi
    # Source .local override (user customizations survive package updates)
    if [[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/botguard/main.conf.local" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/botguard/main.conf.local" || true
    fi
    botguard_enabled="${HTTP_BOTGUARD_ENABLED:-false}"
    if [[ "$botguard_enabled" == "true" ]]; then
        if nft list set ip nftban http_bot_suspect &>/dev/null 2>&1; then
            local v4_suspects=0 v6_suspects=0
            v4_suspects=$(nft list set ip nftban http_bot_suspect 2>/dev/null | grep -c "timeout" || echo "0")
            v6_suspects=$(nft list set ip6 nftban http_bot_suspect6 2>/dev/null | grep -c "timeout" || echo "0")
            botguard_status="ACTIVE (${v4_suspects}v4+${v6_suspects}v6 suspects)"
        else
            botguard_status="ENABLED (sets not loaded)"
        fi
    fi
    printf "  %-20s %s\n" "Bot Guard..........." "$botguard_status"

    # Tunnel Suspicion (v1.30.0)
    local tunnel_status="DISABLED"
    if [[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/tunnel/main.conf" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/tunnel/main.conf" || true
    fi
    if [[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/tunnel/main.conf.local" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/tunnel/main.conf.local" || true
    fi
    if [[ "${NFTBAN_TUNNEL_ENABLED:-NO}" == "YES" ]]; then
        local tunnel_high=0 tunnel_med=0
        local tunnel_state_dir="${NFTBAN_DATA_DIR:-/var/lib/nftban}/tunnel"
        if [[ -d "$tunnel_state_dir" ]]; then
            for _sf in "${tunnel_state_dir}"/*.state; do
                [[ ! -f "$_sf" ]] && continue
                local _lvl
                _lvl=$(head -1 "$_sf" 2>/dev/null | cut -d'|' -f3)
                case "$_lvl" in
                    HIGH) tunnel_high=$((tunnel_high + 1)) ;;
                    MEDIUM) tunnel_med=$((tunnel_med + 1)) ;;
                esac
            done
        fi
        if [[ $tunnel_high -gt 0 ]]; then
            tunnel_status="ACTIVE (H:${tunnel_high} M:${tunnel_med}) advisory-only"
        elif [[ $tunnel_med -gt 0 ]]; then
            tunnel_status="ACTIVE (M:${tunnel_med}) advisory-only"
        else
            tunnel_status="ENABLED (advisory-only)"
        fi
    fi
    printf "  %-20s %s\n" "Tunnel Suspicion...." "$tunnel_status"

    # Metrics Database
    local metrics_db_status="NOT INSTALLED"
    local prom_running=false vm_running=false
    # Use distro abstraction layer for service names (with fallback if not loaded)
    local prometheus_service victoriametrics_service
    prometheus_service=$(nftban_distro_get_service prometheus 2>/dev/null || echo "prometheus")
    victoriametrics_service=$(nftban_distro_get_service victoriametrics 2>/dev/null || echo "victoriametrics")
    systemctl is-active "$prometheus_service" >/dev/null 2>&1 && prom_running=true
    systemctl is-active "$victoriametrics_service" >/dev/null 2>&1 && vm_running=true
    if [[ "$prom_running" == "true" ]]; then
        metrics_db_status="Prometheus (running)"
    elif [[ "$vm_running" == "true" ]]; then
        metrics_db_status="VictoriaMetrics (running)"
    elif systemctl list-unit-files 2>/dev/null | grep -qE "^(${prometheus_service}|${victoriametrics_service}).service"; then
        metrics_db_status="INSTALLED (stopped)"
    fi
    printf "  %-20s %s\n" "Metrics DB.........." "$metrics_db_status"

    # Metrics Exporter
    local metrics_exp_status="NOT INSTALLED"
    if systemctl is-active nftban-unified-exporter.timer >/dev/null 2>&1 || \
       systemctl is-active nftban-unified-exporter.service >/dev/null 2>&1; then
        metrics_exp_status="ACTIVE"
    elif systemctl list-unit-files 2>/dev/null | grep -q "nftban-unified-exporter"; then
        metrics_exp_status="INACTIVE"
    fi
    printf "  %-20s %s\n" "Metrics Exporter...." "$metrics_exp_status"

    # Zabbix Exporter (v1.3.0)
    local zabbix_status="NOT CONFIGURED"
    # Load Zabbix config
    local zabbix_conf="${NFTBAN_CONFIG_DIR}/conf.d/zabbix.conf"
    local zabbix_local="${NFTBAN_CONFIG_DIR}/conf.d/zabbix.conf.local"
    [[ -f "$zabbix_conf" ]] && source "$zabbix_conf" 2>/dev/null || true
    [[ -f "$zabbix_local" ]] && source "$zabbix_local" 2>/dev/null || true

    if [[ "${NFTBAN_ZABBIX_ENABLED:-false}" =~ ^([Yy][Ee][Ss]|[Tt][Rr][Uu][Ee]|1|[Oo][Nn])$ ]]; then
        if systemctl is-active nftban-unified-exporter.timer >/dev/null 2>&1; then
            zabbix_status="ACTIVE (${NFTBAN_ZABBIX_SERVER:-unconfigured})"
        else
            zabbix_status="ENABLED (timer inactive)"
        fi
        # Check transport binary availability
        if ! command -v zabbix_sender &>/dev/null && ! command -v nc &>/dev/null && ! command -v ncat &>/dev/null; then
            zabbix_status+=" [NO TRANSPORT]"
        fi
    elif [[ -f "$zabbix_conf" ]]; then
        zabbix_status="DISABLED"
    fi
    printf "  %-20s %s\n" "Zabbix Exporter....." "$zabbix_status"

    # Generic Connectors (v1.3.0)
    local connector_status="NOT CONFIGURED"
    local connectors_conf="${NFTBAN_CONFIG_DIR}/conf.d/connectors.conf"
    local connectors_local="${NFTBAN_CONFIG_DIR}/conf.d/connectors.conf.local"
    [[ -f "$connectors_conf" ]] && source "$connectors_conf" 2>/dev/null || true
    [[ -f "$connectors_local" ]] && source "$connectors_local" 2>/dev/null || true

    if [[ "${NFTBAN_CONNECTOR_ENABLED:-false}" == "true" ]]; then
        local connector_count=0
        [[ "${NFTBAN_CONNECTOR_ES_ENABLED:-false}" == "true" ]] && connector_count=$((connector_count + 1))
        [[ "${NFTBAN_CONNECTOR_KAFKA_ENABLED:-false}" == "true" ]] && connector_count=$((connector_count + 1))
        [[ "${NFTBAN_CONNECTOR_FILE_ENABLED:-false}" == "true" ]] && connector_count=$((connector_count + 1))
        [[ "${NFTBAN_CONNECTOR_SYSLOG_ENABLED:-false}" == "true" ]] && connector_count=$((connector_count + 1))
        [[ "${NFTBAN_CONNECTOR_WEBHOOK_ENABLED:-false}" == "true" ]] && connector_count=$((connector_count + 1))

        if systemctl is-active nftban-unified-exporter.timer >/dev/null 2>&1; then
            connector_status="ACTIVE ($connector_count connectors)"
        else
            connector_status="ENABLED ($connector_count connectors, timer inactive)"
        fi
    elif [[ -f "$connectors_conf" ]]; then
        connector_status="DISABLED"
    fi
    printf "  %-20s %s\n" "Connectors.........." "$connector_status"

    # GUI
    local gui_status="NOT INSTALLED"
    if systemctl is-active nftban-ui >/dev/null 2>&1; then
        gui_status="ACTIVE"
    elif systemctl list-unit-files 2>/dev/null | grep -q nftban-ui; then
        gui_status="INACTIVE"
    fi
    printf "  %-20s %s\n" "GUI................." "$gui_status"
    echo ""
}

_status_section_health() {
    # ─────────────────────────────────────────────────────────────────────
    # HEALTH
    # ─────────────────────────────────────────────────────────────────────
    local protection_state="$1"
    local quiet_mode="$2"

    echo "HEALTH"
    echo "───────────────────────────────────────────────────────────────"

    # Load health module
    # Read from health cache (written by nftban-health.timer)
    local health_cache="${NFTBAN_CACHE_DIR:-/var/cache/nftban}/health/health_status.cache"
    local health_status="UNKNOWN"

    if [[ -r "$health_cache" ]]; then
        health_status=$(cat "$health_cache" 2>/dev/null) || health_status="UNKNOWN"
    fi

    # v1.66.0: If firewall is PROTECTED, don't show misleading ERROR from optional checks
    local _health_base_state="${protection_state%%:*}"
    if [[ "$_health_base_state" == "PROTECTED" ]] && [[ "$health_status" == *"ERROR"* || "$health_status" == *"CRITICAL"* ]]; then
        printf "  %-20s %s\n" "Overall Status......" "OK (info notices)"
    else
        printf "  %-20s %s\n" "Overall Status......" "$health_status"
    fi

    # Check binary integrity (show warning if corrupted)
    local binary_warning
    binary_warning=$(_status_check_binaries 2>&1)
    if [[ -n "$binary_warning" ]]; then
        # Display each warning line
        while IFS= read -r warning_line; do
            if [[ -n "$warning_line" ]]; then
                printf "  %-20s %s\n" "Binary Integrity...." "$warning_line"
            fi
        done <<< "$binary_warning"
    fi

    # ==========================================================================
    # Memory Protection Status (only show if notable)
    # ==========================================================================
    local protection_file="/var/lib/nftban/state/protection.json"
    local permanent_bans_file="/var/lib/nftban/state/permanent_bans.json"

    # Check memory pressure level from cgroup (v2)
    local pressure_file="/sys/fs/cgroup/system.slice/nftband.service/memory.pressure"
    local memory_pressure=0
    local pressure_level="normal"
    if [[ -f "$pressure_file" ]]; then
        memory_pressure=$(awk '/^some/ {gsub(/avg10=/, ""); printf "%.0f", $2}' "$pressure_file" 2>/dev/null || echo "0")
        if [[ $memory_pressure -gt 80 ]]; then
            pressure_level="critical"
        elif [[ $memory_pressure -gt 50 ]]; then
            pressure_level="high"
        elif [[ $memory_pressure -gt 25 ]]; then
            pressure_level="warning"
        fi
    fi

    # Show memory pressure if not normal
    if [[ "$pressure_level" != "normal" ]]; then
        local pressure_icon="⚠️"
        [[ "$pressure_level" == "critical" ]] && pressure_icon="🔴"
        [[ "$pressure_level" == "high" ]] && pressure_icon="🟠"
        printf "  %-20s %s %s (%d%%)\n" "Memory Pressure....." "$pressure_icon" "$pressure_level" "$memory_pressure"
    fi

    # Check if memory protection is active (feeds/geoban skipped)
    if [[ -f "$protection_file" ]]; then
        local feeds_skipped geoban_skipped
        feeds_skipped=$(jq -r '.feeds_skipped // false' "$protection_file" 2>/dev/null || echo "false")
        geoban_skipped=$(jq -r '.geoban_skipped // false' "$protection_file" 2>/dev/null || echo "false")

        if [[ "$feeds_skipped" == "true" || "$geoban_skipped" == "true" ]]; then
            local skipped_items=""
            [[ "$feeds_skipped" == "true" ]] && skipped_items="feeds"
            [[ "$geoban_skipped" == "true" ]] && skipped_items="${skipped_items:+$skipped_items+}geoban"
            printf "  %-20s 💾 Active (%s skipped)\n" "Memory Protection..." "$skipped_items"
        fi
    fi

    # Count permanent bans if any exist
    if [[ -f "$permanent_bans_file" ]]; then
        local perm_count
        perm_count=$(jq -r '.bans | length // 0' "$permanent_bans_file" 2>/dev/null || echo "0")
        if [[ "$perm_count" =~ ^[0-9]+$ ]] && [[ "$perm_count" -gt 0 ]]; then
            local protected_count
            protected_count=$(jq -r '[.bans[]] | map(select(.protected == true)) | length // 0' "$permanent_bans_file" 2>/dev/null || echo "0")
            if [[ "$protected_count" =~ ^[0-9]+$ ]] && [[ "$protected_count" -gt 0 ]]; then
                printf "  %-20s %d (%d protected)\n" "Permanent Bans......" "$perm_count" "$protected_count"
            else
                printf "  %-20s %d\n" "Permanent Bans......" "$perm_count"
            fi
        fi
    fi

    # Quick security hardening check (systemd NoNewPrivileges)
    local security_issues=0
    local systemd_unit_paths=("/etc/systemd/system" "/usr/lib/systemd/system" "/lib/systemd/system")
    for unit_path in "${systemd_unit_paths[@]}"; do
        if [[ -d "$unit_path" ]]; then
            # Count service files with NoNewPrivileges=false (security weakness)
            local count
            count=$(find "$unit_path" -maxdepth 1 -name 'nftban*.service' -type f \
                    -exec grep -l '^\s*NoNewPrivileges\s*=\s*false\s*$' {} + 2>/dev/null | wc -l) || count=0
            security_issues=$((count + 0))  # Ensure numeric
            [[ $security_issues -gt 0 ]] && break
        fi
    done

    local security_status="OK"
    if [[ $security_issues -gt 0 ]]; then
        security_status="${security_issues} systemd issue(s)"
    fi

    # Get posture status (SSH, sudo, config integrity)
    local posture_status="OK"
    if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_report_data.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/lib/nftban_report_data.sh" 2>/dev/null || true
        if declare -f nftban_posture_oneline &>/dev/null; then
            posture_status=$(nftban_posture_oneline 2>/dev/null || echo "OK")
        fi
    fi

    # Combine into single posture line
    local combined_posture="OK"
    if [[ "$security_status" != "OK" || "$posture_status" != "OK" ]]; then
        combined_posture=""
        [[ "$security_status" != "OK" ]] && combined_posture="$security_status"
        if [[ "$posture_status" != "OK" ]]; then
            [[ -n "$combined_posture" ]] && combined_posture+=", "
            combined_posture+="$posture_status"
        fi
    fi

    if [[ "$combined_posture" == "OK" ]]; then
        printf "  %-20s ✅ %s\n" "Security Posture...." "$combined_posture"
    else
        printf "  %-20s ⚠️  %s\n" "Security Posture...." "$combined_posture"
    fi

    # Show hints if not OK (only in non-quiet mode)
    if [[ $quiet_mode -eq 0 ]] && { [[ "$health_status" != "OK" ]] || [[ $security_issues -gt 0 ]]; }; then
        echo "      → Details: nftban health check"
        echo "      → Fix:     sudo nftban health fix all  (for root-only fixes)"
    fi
    echo ""
}

_status_section_activity() {
    # ─────────────────────────────────────────────────────────────────────
    # RECENT ACTIVITY
    # ─────────────────────────────────────────────────────────────────────
    echo "RECENT ACTIVITY"
    echo "───────────────────────────────────────────────────────────────"

    # Count bans in last 24 hours from bans.log (consistent with nftban stats)
    local bans_24h="0"
    local unbans_24h="0"
    local ban_log="${NFTBAN_LOG_DIR}/bans.log"
    local since_date
    local until_date
    since_date=$(date -d '24 hours ago' +%Y-%m-%d)
    until_date=$(date +%Y-%m-%d)

    if [[ -r "$ban_log" ]]; then
        # Use awk to count bans in last 24 hours (same logic as nftban_stats_count_bans)
        bans_24h=$(awk -F'|' -v since="$since_date" -v until="$until_date" \
            '$1 >= since && $1 <= until && $6 == "BANNED" {count++} END {print count+0}' \
            "$ban_log" 2>/dev/null) || bans_24h=0
        unbans_24h=$(awk -F'|' -v since="$since_date" -v until="$until_date" \
            '$1 >= since && $1 <= until && $6 == "UNBANNED" {count++} END {print count+0}' \
            "$ban_log" 2>/dev/null) || unbans_24h=0
    fi

    printf "  %-20s %s\n" "Bans (24h).........." "$bans_24h"
    printf "  %-20s %s\n" "Unbans (24h)........" "$unbans_24h"
    echo ""
}

_status_section_timers() {
    # ─────────────────────────────────────────────────────────────────────
    # TIMERS
    # ─────────────────────────────────────────────────────────────────────
    local quiet_mode="$1"

    echo "TIMERS"
    echo "───────────────────────────────────────────────────────────────"

    # Define all NFTBan timers with their descriptions
    local -A timer_desc=(
        ["nftban-health.timer"]="Health check"
        ["nftban-maintenance.timer"]="Maintenance tasks"
        ["nftban-unified-exporter.timer"]="Unified metrics export"
        ["nftban-core-feeds.timer"]="Threat feeds update"
        ["nftban-core-geoip.timer"]="GeoIP database update"
        ["nftban-watchdog.timer"]="System watchdog"
        ["nftban-queue.timer"]="Queue processing"
        ["nftban-suricata-update.timer"]="Suricata rules update"
        ["nftban-snapshot.timer"]="Snapshot creation"
        ["nftban-rollback.timer"]="Rollback check"
        ["nftban-rbl-check.timer"]="RBL Check"
        ["nftban-tunnel.timer"]="Tunnel suspicion scan"
        ["nftban-pro-inventory.timer"]="Pro inventory collection"
        ["nftban-pro-license.timer"]="Pro license check"
        ["nftban-update.timer"]="Self-update check"
    )

    local timer_count=0
    local timer_active=0
    local timer_output=""

    for timer in "${!timer_desc[@]}"; do
        if systemctl list-unit-files "$timer" --no-legend 2>/dev/null | grep -q "$timer"; then
            timer_count=$((timer_count + 1))
            local status_text="INACTIVE"
            local next_run=""

            if systemctl is-active "$timer" >/dev/null 2>&1; then
                timer_active=$((timer_active + 1))

                # Get time left until next trigger
                # systemctl show gives seconds until next elapse (reliable, locale-independent)
                local next_usec
                next_usec=$(systemctl show "$timer" --property=NextElapseUSecRealtime --value 2>/dev/null || true)
                if [[ -n "$next_usec" ]] && [[ "$next_usec" != "n/a" ]] && [[ "$next_usec" != "0" ]]; then
                    local next_epoch now_epoch
                    next_epoch=$(date -d "$next_usec" +%s 2>/dev/null || true)
                    now_epoch=$(date +%s)
                    if [[ -n "$next_epoch" ]] && [[ "$next_epoch" -gt "$now_epoch" ]]; then
                        local secs_left=$((next_epoch - now_epoch))
                        if [[ $secs_left -ge 86400 ]]; then
                            next_run="$((secs_left / 86400))d $((secs_left % 86400 / 3600))h"
                        elif [[ $secs_left -ge 3600 ]]; then
                            next_run="$((secs_left / 3600))h $((secs_left % 3600 / 60))m"
                        elif [[ $secs_left -ge 60 ]]; then
                            next_run="$((secs_left / 60))m"
                        else
                            next_run="${secs_left}s"
                        fi
                    fi
                fi

                if [[ -n "$next_run" ]] && [[ "$next_run" != "n/a" ]]; then
                    status_text="OK — next in $next_run"
                else
                    status_text="ACTIVE"
                fi
            elif systemctl is-enabled "$timer" >/dev/null 2>&1; then
                status_text="ENABLED (stopped)"
            fi

            # Format timer name (remove .timer suffix and prefix)
            local timer_name="${timer%.timer}"
            timer_name="${timer_name#nftban-}"
            [[ "$timer_name" == "nftban" ]] && timer_name="main"
            timer_name=$(printf "%-16s" "$timer_name")
            timer_name="${timer_name// /.}"

            timer_output+=$(printf "  %s %s\n" "$timer_name" "$status_text")
            timer_output+=$'\n'
        fi
    done

    if [[ $timer_count -gt 0 ]]; then
        printf "  %-20s %s\n" "Active timers......." "$timer_active / $timer_count"
        echo ""
        echo -n "$timer_output"
    else
        printf "  %-20s %s\n" "Active timers......." "None installed"
    fi

    # Timer status explanation
    if [[ $timer_count -gt 0 ]] && [[ $quiet_mode -eq 0 ]]; then
        echo "  Timer Status Guide:"
        echo "    OK              - Running automatically"
        echo "    ENABLED (stopped) - Will start at boot (or run: systemctl start <timer>)"
        echo "    INACTIVE        - Disabled (optional feature)"
        echo ""
        if [[ $timer_active -lt $timer_count ]]; then
            echo "  To enable all timers: nftban timers enable"
        fi
    fi
    echo ""
}

_status_section_logs() {
    # ─────────────────────────────────────────────────────────────────────
    # LOGS
    # ─────────────────────────────────────────────────────────────────────
    echo "LOGS"
    echo "───────────────────────────────────────────────────────────────"

    local log_rotation_status="NOT CONFIGURED"
    local log_size="N/A"
    local last_rotate="N/A"

    if [[ -f /etc/logrotate.d/nftban ]]; then
        log_rotation_status="CONFIGURED"
    fi

    if [[ -d "${NFTBAN_LOG_DIR}" ]]; then
        log_size=$(du -sh "${NFTBAN_LOG_DIR}" 2>/dev/null | awk '{print $1}' || echo "N/A")
    fi

    if [[ -f /var/lib/logrotate/status ]] && grep -q "nftban" /var/lib/logrotate/status 2>/dev/null; then
        last_rotate=$(grep "nftban" /var/lib/logrotate/status 2>/dev/null | head -1 | awk '{print $NF}' || echo "N/A")
    elif [[ -f /var/lib/logrotate.status ]] && grep -q "nftban" /var/lib/logrotate.status 2>/dev/null; then
        last_rotate=$(grep "nftban" /var/lib/logrotate.status 2>/dev/null | head -1 | awk '{print $NF}' || echo "N/A")
    fi

    printf "  %-20s %s\n" "Log rotation........" "$log_rotation_status"
    printf "  %-20s %s\n" "Size................" "$log_size"
    printf "  %-20s %s\n" "Last rotation......." "$last_rotate"
    echo ""
}

_status_section_requirements() {
    # ─────────────────────────────────────────────────────────────────────
    # SYSTEM REQUIREMENTS
    # ─────────────────────────────────────────────────────────────────────
    echo "SYSTEM REQUIREMENTS"
    echo "───────────────────────────────────────────────────────────────"

    # Check DNS
    local dns_status="NOT WORKING"
    if host google.com >/dev/null 2>&1 || nslookup google.com >/dev/null 2>&1; then
        dns_status="OK"
    fi
    printf "  %-20s %s\n" "DNS................." "$dns_status"

    # Check Email capability
    local email_status="NOT CONFIGURED"
    local email_working=false
    if [[ -f "${NFTBAN_CONFIG_DIR}/conf.d/mail.conf" ]]; then
        if grep -q "MAIL_ENABLED=true" "${NFTBAN_CONFIG_DIR}/conf.d/mail.conf" 2>/dev/null; then
            if command -v sendmail >/dev/null 2>&1 || \
               command -v msmtp >/dev/null 2>&1 || \
               command -v mailx >/dev/null 2>&1; then
                email_status="CONFIGURED"
                # shellcheck disable=SC2034  # Reserved for email test status
                email_working=true
            else
                email_status="CONFIGURED (no mail cmd)"
            fi
        fi
    fi
    printf "  %-20s %s\n" "Email..............." "$email_status"

    # Check Auto-Reports
    local report_status="DISABLED"
    if [[ -d "${NFTBAN_DATA_DIR}/reports" ]]; then
        local report_count
        report_count=$(find "${NFTBAN_DATA_DIR}/reports" -type f \( -name "*.html" -o -name "*.json" \) 2>/dev/null | wc -l)
        if [[ $report_count -gt 0 ]]; then
            report_status="ENABLED ($report_count reports)"
        else
            report_status="ENABLED (no reports yet)"
        fi
    fi
    printf "  %-20s %s\n" "Auto-Reports........" "$report_status"
    echo "      → ${NFTBAN_DATA_DIR}/reports/"
    echo ""
}

# =============================================================================
# TERMINAL OUTPUT (orchestrator)
# =============================================================================

output_terminal() {
    # Output formatted terminal status - Clean professional layout v1.0
    # Decomposed in v1.38.0: each section is a _status_section_*() helper.
    local quiet_mode="$1"

    # v1.66.0: Use unified protection state function (single source of truth)
    local protection_state
    protection_state=$(_nftban_protection_state)
    local _base_state="${protection_state%%:*}"

    # Header with version and state
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NFTBan v${NFTBAN_VERSION:-unknown} — System Status — ${protection_state}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    _status_section_system "$protection_state"
    _status_section_firewall "$quiet_mode"
    _status_section_services
    _status_section_protection "$quiet_mode"
    _status_section_health "$protection_state" "$quiet_mode"
    _status_section_activity
    _status_section_timers "$quiet_mode"
    _status_section_logs
    _status_section_requirements

    # ─────────────────────────────────────────────────────────────────────
    # QUICK COMMANDS
    # ─────────────────────────────────────────────────────────────────────
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "QUICK COMMANDS"
    echo "  nftban menu              Interactive TUI menu"
    echo "  nftban health check      Full diagnostics"
    echo "  nftban stats dashboard   Detailed statistics"
    echo "  nftban firewall validate Firewall details"
    echo "  nftban help              Show all commands"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # v1.66.0: Exit code contract — 0=PROTECTED, 1=DEGRADED, 2=DOWN
    case "$_base_state" in
        PROTECTED) return 0 ;;
        DEGRADED)
            [[ "${NFTBAN_EXIT_COMPAT:-}" == "v1" ]] && return 0
            return 1
            ;;
        *) return 2 ;;
    esac
}

output_json() {
    # Output JSON format

    # v1.66.0: Use unified protection state function (single source of truth)
    local json_state_raw
    json_state_raw=$(_nftban_protection_state)
    local json_base_state="${json_state_raw%%:*}"
    local json_reason="${json_state_raw#*:}"
    [[ "$json_reason" == "$json_base_state" ]] && json_reason=""

    # v1.66.0: Config divergence detection
    local _json_divergence
    _json_divergence=$(_check_config_divergence 2>/dev/null)
    local _json_div_array=""
    if [[ -n "$_json_divergence" ]]; then
        local _first=true _div_item
        while IFS= read -r _div_item; do
            if [[ -n "$_div_item" ]]; then
                [[ "$_first" == "true" ]] && _first=false || _json_div_array+=", "
                _json_div_array+="\"${_div_item}\""
            fi
        done <<< "$_json_divergence"
    fi

    echo "{"
    echo "  \"version\": \"${NFTBAN_VERSION:-unknown}\","
    echo "  \"state\": \"$json_base_state\","
    if [[ -n "$json_reason" ]]; then
        echo "  \"degraded_reason\": \"$json_reason\","
    fi
    echo "  \"config_divergence\": [${_json_div_array}],"
    echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"hostname\": \"$(hostname)\","

    # Firewall
    local nft_active=false
    systemctl is-active nftables.service >/dev/null 2>&1 && nft_active=true

    echo "  \"firewall\": {"
    echo "    \"nftables_active\": $nft_active,"

    # v1.24.0: Use shared rule counting function (matches human output)
    local rule_count=0
    if command -v nft >/dev/null 2>&1; then
        rule_count=$(_nftban_count_rules)
    fi
    echo "    \"rule_count\": $rule_count,"

    # v1.0: Use unified blacklist_ipv4/ipv6 sets (all bans consolidated)
    # SINGLE SOURCE OF TRUTH: nftban_stats.sh → nft_schema.sh counting functions
    local ban_count=0
    if declare -f nftban_stats_count_active_bans >/dev/null 2>&1; then
        # Use stats module function (calls nft_schema.sh internally)
        ban_count=$(nftban_stats_count_active_bans 2>/dev/null || echo 0)
    elif declare -f nftban_nft_count_blacklist >/dev/null 2>&1; then
        # Fallback: Use nft_schema.sh centralized counting (fast JSON API)
        local bl_counts
        bl_counts=$(nftban_nft_count_blacklist 2>/dev/null || echo "0 0 0")
        ban_count=$(echo "$bl_counts" | awk '{print $3}')  # Total is field 3
    fi
    echo "    \"banned_ips\": $ban_count,"

    # v1.38.0: Count disambiguation — show all counting sources
    # kernel_elements: Direct nft kernel query (authoritative)
    # cache_count: From /var/cache/nftban stats cache (fast, may lag)
    # source_index_count: From daemon source index (tracks per-module attribution)
    local kernel_count=0 cache_count=0 source_index_count=0
    if declare -f nftban_nft_count_blacklist >/dev/null 2>&1; then
        local bl_raw
        bl_raw=$(nftban_nft_count_blacklist 2>/dev/null || echo "0 0 0")
        kernel_count=$(echo "$bl_raw" | awk '{print $3}')
    fi
    if declare -f nftban_stats_get_unified >/dev/null 2>&1; then
        cache_count=$(nftban_stats_get_unified ".blacklist.total" 2>/dev/null || echo 0)
    fi
    # Source index count comes from daemon IPC if available
    if [[ -S /run/nftban/nftband.sock ]]; then
        local si_resp
        si_resp=$(nftban_ipc_call "source_index_count" 2>/dev/null || echo "")
        if [[ -n "$si_resp" ]]; then
            source_index_count=$(echo "$si_resp" | grep -o '"count":[0-9]*' | head -1 | cut -d: -f2)
            source_index_count=${source_index_count:-0}
        fi
    fi
    echo "    \"counts\": {"
    echo "      \"kernel_elements\": $kernel_count,"
    echo "      \"cache_count\": $cache_count,"
    echo "      \"source_index_count\": $source_index_count"
    echo "    },"

    # Add GUI-required fields for dashboard
    # whitelist_ips: Total whitelist count
    local whitelist_count=0
    if command -v nftban_stats_count_whitelist >/dev/null 2>&1; then
        whitelist_count=$(nftban_stats_count_whitelist 2>/dev/null || echo 0)
    fi
    echo "    \"whitelist_ips\": $whitelist_count,"

    # feed_ips: Count of IPs from threat feeds (part of unified blacklist in v0.7.3)
    # NOTE: In v0.7.3, feeds are loaded into unified blacklist, can't distinguish
    # Return 0 or query feed config files for count
    echo "    \"feed_ips\": 0,"

    # threats_blocked_24h: Bans in last 24 hours
    local threats_24h=0
    if command -v nftban_stats_count_bans >/dev/null 2>&1; then
        local since
        since=$(($(date +%s) - 86400))
        threats_24h=$(nftban_stats_count_bans "$since" 2>/dev/null || echo 0)
    fi
    echo "    \"threats_blocked_24h\": $threats_24h"
    echo "  },"

    # Master control
    local master_enabled="true"
    if [[ -f "${NFTBAN_CONFIG_DIR}/conf.d/services.conf.local" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_CONFIG_DIR}/conf.d/services.conf.local" 2>/dev/null || true
        master_enabled="${NFTBAN_ENABLED:-true}"
    fi
    if grep -q 'nftban=disabled' /proc/cmdline 2>/dev/null; then
        master_enabled="false"
    fi
    echo "  \"master_enabled\": $master_enabled,"

    # Services (detailed)
    echo "  \"services\": {"

    # Helper to get service info as JSON
    _json_service_info() {
        local unit="$1"
        local status="inactive" pid="" mem="" uptime=""

        if ! systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q "$unit"; then
            echo "null"
            return
        fi

        if systemctl is-active "$unit" >/dev/null 2>&1; then
            status="active"
            pid=$(systemctl show "$unit" --property=MainPID --value 2>/dev/null || echo "")
            # pid=0 means no main process, treat as null
            if [[ -n "$pid" ]] && [[ "$pid" != "0" ]]; then
                mem=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{printf "%.1f", $1/1024}' || echo "")
                local start_time
                start_time=$(ps -o lstart= -p "$pid" 2>/dev/null || echo "")
                if [[ -n "$start_time" ]]; then
                    local start_epoch now_epoch
                    start_epoch=$(date -d "$start_time" +%s 2>/dev/null || echo "0")
                    now_epoch=$(date +%s)
                    uptime=$((now_epoch - start_epoch))
                fi
            else
                pid=""  # Reset 0 to empty so it becomes null
            fi
        elif systemctl is-enabled "$unit" >/dev/null 2>&1; then
            status="enabled"
        fi

        # Build JSON with proper null handling
        local pid_json="${pid:-null}"
        [[ -n "$pid" ]] && pid_json="$pid"
        local mem_json="${mem:-null}"
        [[ -n "$mem" ]] && mem_json="$mem"
        local uptime_json="${uptime:-null}"
        [[ -n "$uptime" ]] && uptime_json="$uptime"

        echo "{\"status\": \"$status\", \"pid\": $pid_json, \"memory_mb\": $mem_json, \"uptime_sec\": $uptime_json}"
    }

    echo "    \"nftables\": $(_json_service_info nftables.service),"
    echo "    \"suricata\": $(_json_service_info suricata.service),"
    echo "    \"nftban_core\": $(_json_service_info "${NFTBAN_SERVICE_CORE:-nftban-core.service}"),"
    echo "    \"nftban_api\": $(_json_service_info "${NFTBAN_SERVICE_UI:-nftban-ui.service}"),"
    echo "    \"nftban_suricata\": $(_json_service_info "${NFTBAN_SERVICE_SURICATA:-nftban-suricata.service}"),"
    # v1.23.0: login_monitor removed (replaced by nftband loginmon module)
    echo "    \"metrics_exporter\": $(_json_service_info "${NFTBAN_SERVICE_METRICS_EXPORTER:-nftban-unified-exporter.service}")"
    echo "  },"

    # Health
    local health_exit=0
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_health.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/core/nftban_health.sh" || return 1
        nftban_health_check_all 0 >/dev/null 2>&1 || health_exit=$?
    fi

    local health_status="unknown"
    case $health_exit in
        0) health_status="healthy" ;;
        1) health_status="warnings" ;;
        2) health_status="errors" ;;
    esac

    # v1.66.0: JSON health parity — when PROTECTED, health errors are informational
    if [[ "$json_base_state" == "PROTECTED" ]] && [[ "$health_status" == "errors" ]]; then
        health_status="healthy"
    fi

    # Memory protection state for JSON
    local json_pressure_level="normal"
    local json_pressure_pct=0
    local json_feeds_skipped=false
    local json_geoban_skipped=false
    local json_perm_bans=0
    local json_perm_protected=0

    # Check memory pressure from cgroup
    local json_pressure_file="/sys/fs/cgroup/system.slice/nftband.service/memory.pressure"
    if [[ -f "$json_pressure_file" ]]; then
        json_pressure_pct=$(awk '/^some/ {gsub(/avg10=/, ""); printf "%.0f", $2}' "$json_pressure_file" 2>/dev/null || echo "0")
        if [[ $json_pressure_pct -gt 80 ]]; then
            json_pressure_level="critical"
        elif [[ $json_pressure_pct -gt 50 ]]; then
            json_pressure_level="high"
        elif [[ $json_pressure_pct -gt 25 ]]; then
            json_pressure_level="warning"
        fi
    fi

    # Check protection state
    local json_protection_file="/var/lib/nftban/state/protection.json"
    if [[ -f "$json_protection_file" ]]; then
        local fs gs
        fs=$(jq -r '.feeds_skipped // false' "$json_protection_file" 2>/dev/null || echo "false")
        gs=$(jq -r '.geoban_skipped // false' "$json_protection_file" 2>/dev/null || echo "false")
        [[ "$fs" == "true" ]] && json_feeds_skipped=true
        [[ "$gs" == "true" ]] && json_geoban_skipped=true
    fi

    # Check permanent bans
    local json_perm_file="/var/lib/nftban/state/permanent_bans.json"
    if [[ -f "$json_perm_file" ]]; then
        json_perm_bans=$(jq -r '.bans | length // 0' "$json_perm_file" 2>/dev/null || echo "0")
        json_perm_protected=$(jq -r '[.bans[]] | map(select(.protected == true)) | length // 0' "$json_perm_file" 2>/dev/null || echo "0")
        [[ ! "$json_perm_bans" =~ ^[0-9]+$ ]] && json_perm_bans=0
        [[ ! "$json_perm_protected" =~ ^[0-9]+$ ]] && json_perm_protected=0
    fi

    # Check binary integrity for JSON output
    local json_binaries_valid=true
    local json_corrupted_binaries=""
    local json_binaries=(
        "/usr/lib/nftban/bin/nftban-core"
        "/usr/lib/nftban/bin/nftband"
    )
    if command -v file >/dev/null 2>&1; then
        for json_binary in "${json_binaries[@]}"; do
            if [[ -f "$json_binary" ]]; then
                local json_file_type
                json_file_type=$(file -b "$json_binary" 2>/dev/null)
                if [[ "$json_file_type" != *"ELF"* ]]; then
                    json_binaries_valid=false
                    [[ -n "$json_corrupted_binaries" ]] && json_corrupted_binaries+=","
                    json_corrupted_binaries+="\"$(basename "$json_binary")\""
                fi
            fi
        done
    fi

    echo "  \"health\": {"
    echo "    \"status\": \"$health_status\","
    echo "    \"exit_code\": $health_exit,"
    echo "    \"binary_integrity\": {"
    echo "      \"valid\": $json_binaries_valid,"
    echo "      \"corrupted\": [${json_corrupted_binaries}]"
    echo "    },"
    echo "    \"memory_pressure\": {"
    echo "      \"level\": \"$json_pressure_level\","
    echo "      \"percent\": $json_pressure_pct"
    echo "    },"
    echo "    \"memory_protection\": {"
    echo "      \"active\": $( [[ "$json_feeds_skipped" == "true" || "$json_geoban_skipped" == "true" ]] && echo "true" || echo "false" ),"
    echo "      \"feeds_skipped\": $json_feeds_skipped,"
    echo "      \"geoban_skipped\": $json_geoban_skipped"
    echo "    },"
    echo "    \"permanent_bans\": {"
    echo "      \"total\": $json_perm_bans,"
    echo "      \"protected\": $json_perm_protected"
    echo "    }"
    echo "  },"

    # System info for GUI
    local uptime_sec
    uptime_sec=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)
    local kernel
    kernel=$(uname -r 2>/dev/null || echo "unknown")

    echo "  \"system\": {"
    echo "    \"kernel\": \"$kernel\","
    echo "    \"uptime_sec\": $uptime_sec"
    echo "  },"

    # Protection modules status
    echo "  \"protection\": {"

    # Suricata
    local suricata_enabled=false suricata_banning=false
    systemctl is-active suricata.service >/dev/null 2>&1 && suricata_enabled=true
    systemctl is-active nftban-suricata.service >/dev/null 2>&1 && suricata_banning=true
    echo "    \"suricata\": {\"enabled\": $suricata_enabled, \"banning\": $suricata_banning},"

    # Login monitoring (nftband loginmon module, replaces deprecated login-monitor service)
    local loginmon_enabled=false
    [[ -f "${NFTBAN_RUN_DIR:-/run/nftban}/loginmon.pid" ]] && loginmon_enabled=true
    echo "    \"login_monitor\": {\"enabled\": $loginmon_enabled},"

    # GeoIP (database) - use nftban-core for accurate detection
    local geoip_installed=false
    local nftban_core="${NFTBAN_LIB_DIR}/bin/nftban-core"
    [[ ! -x "$nftban_core" ]] && nftban_core=$(command -v nftban-core 2>/dev/null || echo "")
    if [[ -n "$nftban_core" ]] && [[ -x "$nftban_core" ]]; then
        "$nftban_core" geoip status >/dev/null 2>&1 && geoip_installed=true
    fi
    echo "    \"geoip\": {\"installed\": $geoip_installed},"

    # GeoBan (country blocking) - separate from GeoIP
    local geoban_enabled=false geoban_countries=0
    geoban_countries=$(nftban geoban list 2>/dev/null | grep -c "BLOCKED" 2>/dev/null || true)
    geoban_countries="${geoban_countries:-0}"
    [[ "$geoban_countries" =~ ^[0-9]+$ ]] && [[ "$geoban_countries" -gt 0 ]] && geoban_enabled=true
    echo "    \"geoban\": {\"enabled\": $geoban_enabled, \"blocked_countries\": $geoban_countries},"

    # Bot Guard
    local json_botguard_enabled=false
    if [[ -f "${NFTBAN_CONFIG_DIR}/conf.d/botguard/main.conf" ]]; then
        local bg_val=""
        bg_val=$(grep -m1 "^HTTP_BOTGUARD_ENABLED=" "${NFTBAN_CONFIG_DIR}/conf.d/botguard/main.conf.local" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || true)
        [[ -z "$bg_val" ]] && bg_val=$(grep -m1 "^HTTP_BOTGUARD_ENABLED=" "${NFTBAN_CONFIG_DIR}/conf.d/botguard/main.conf" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || true)
        [[ "$bg_val" == "true" ]] && json_botguard_enabled=true
    fi
    local json_bg_v4=0 json_bg_v6=0
    if [[ "$json_botguard_enabled" == "true" ]]; then
        json_bg_v4=$(nft list set ip nftban http_bot_suspect 2>/dev/null | grep -c "timeout" || echo "0")
        json_bg_v6=$(nft list set ip6 nftban http_bot_suspect6 2>/dev/null | grep -c "timeout" || echo "0")
    fi
    echo "    \"botguard\": {\"enabled\": $json_botguard_enabled, \"ipv4_suspects\": $json_bg_v4, \"ipv6_suspects\": $json_bg_v6},"

    # Tunnel Suspicion
    local json_tunnel_enabled=false
    local tunnel_val=""
    tunnel_val=$(grep -m1 "^NFTBAN_TUNNEL_ENABLED=" "${NFTBAN_CONFIG_DIR}/conf.d/tunnel/main.conf.local" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || true)
    [[ -z "$tunnel_val" ]] && tunnel_val=$(grep -m1 "^NFTBAN_TUNNEL_ENABLED=" "${NFTBAN_CONFIG_DIR}/conf.d/tunnel/main.conf" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || true)
    [[ "$tunnel_val" == "YES" ]] && json_tunnel_enabled=true
    local json_tunnel_high=0 json_tunnel_med=0
    if [[ "$json_tunnel_enabled" == "true" ]]; then
        local _tsd="${NFTBAN_DATA_DIR:-/var/lib/nftban}/tunnel"
        if [[ -d "$_tsd" ]]; then
            for _tsf in "${_tsd}"/*.state; do
                [[ ! -f "$_tsf" ]] && continue
                local _tlvl
                _tlvl=$(head -1 "$_tsf" 2>/dev/null | cut -d'|' -f3)
                case "$_tlvl" in
                    HIGH) json_tunnel_high=$((json_tunnel_high + 1)) ;;
                    MEDIUM) json_tunnel_med=$((json_tunnel_med + 1)) ;;
                esac
            done
        fi
    fi
    echo "    \"tunnel\": {\"enabled\": $json_tunnel_enabled, \"high\": $json_tunnel_high, \"medium\": $json_tunnel_med, \"advisory_only\": true},"

    # Feeds
    local feeds_count=0
    if [[ -d "${NFTBAN_DATA_DIR}/feeds" ]]; then
        feeds_count=$(find "${NFTBAN_DATA_DIR}/feeds" -name "*.txt" -type f 2>/dev/null | wc -l || true)
        feeds_count="${feeds_count:-0}"
    fi
    echo "    \"feeds\": {\"count\": $feeds_count}"
    echo "  },"

    # Timers
    echo "  \"timers\": {"
    local timer_list=("nftban-health.timer" "nftban-core-feeds.timer" "nftban-core-geoip.timer" "nftban-maintenance.timer" "nftban-unified-exporter.timer" "nftban-queue.timer" "nftban-suricata-update.timer" "nftban-snapshot.timer" "nftban-rollback.timer" "nftban-rbl-check.timer" "nftban-tunnel.timer" "nftban-pro-inventory.timer" "nftban-pro-license.timer" "nftban-update.timer")
    local timer_json=""
    for timer in "${timer_list[@]}"; do
        local timer_name="${timer%.timer}"
        timer_name="${timer_name#nftban-}"
        local timer_active=false
        systemctl is-active "$timer" >/dev/null 2>&1 && timer_active=true
        [[ -n "$timer_json" ]] && timer_json+=","
        timer_json+="\"$timer_name\": $timer_active"
    done
    echo "    $timer_json"
    echo "  }"

    echo "}"


    # Exit marker for testing validation
    command -v nftban_cmd_exit >/dev/null 2>&1 && nftban_cmd_exit "status"

    # v1.66.0: Exit code contract — 0=PROTECTED, 1=DEGRADED, 2=DOWN
    case "$json_base_state" in
        PROTECTED) return 0 ;;
        DEGRADED)
            [[ "${NFTBAN_EXIT_COMPAT:-}" == "v1" ]] && return 0
            return 1
            ;;
        *) return 2 ;;
    esac
}

check_service_clean() {
    # Check and display service status with clean format (dot leaders)
    # Args: service_name systemd_unit
    local name="$1"
    local unit="$2"

    # Pad name with dots for alignment
    local padded_name
    padded_name=$(printf "%-16s" "$name")
    padded_name="${padded_name// /.}"

    # Check if unit exists
    if ! systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q "$unit"; then
        printf "  %s NOT INSTALLED (optional)\n" "$padded_name"
        return 0
    fi

    # Check if active
    if ! systemctl is-active "$unit" >/dev/null 2>&1; then
        # For timer-triggered services, check if the corresponding timer is active
        local timer_unit="${unit%.service}.timer"
        if systemctl is-active "$timer_unit" >/dev/null 2>&1; then
            printf "  %s TIMER (scheduled)\n" "$padded_name"
            return 0
        fi
        # Check if enabled but not running
        if systemctl is-enabled "$unit" >/dev/null 2>&1; then
            printf "  %s ENABLED (stopped)\n" "$padded_name"
        else
            printf "  %s INACTIVE (optional)\n" "$padded_name"
        fi
        return 0
    fi

    # Active - get details
    local pid mem_mb uptime_str=""
    pid=$(systemctl show "$unit" --property=MainPID --value 2>/dev/null || echo "")

    if [[ -n "$pid" ]] && [[ "$pid" != "0" ]]; then
        # Memory in MB
        mem_mb=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{printf "%.1fMB", $1/1024}' || echo "")

        # Uptime
        local start_time start_epoch now_epoch
        start_time=$(ps -o lstart= -p "$pid" 2>/dev/null || echo "")
        if [[ -n "$start_time" ]]; then
            start_epoch=$(date -d "$start_time" +%s 2>/dev/null || echo "0")
            now_epoch=$(date +%s)
            local uptime_sec
            uptime_sec=$((now_epoch - start_epoch))
            if [[ $uptime_sec -ge 86400 ]]; then
                uptime_str="$((uptime_sec / 86400))d"
            elif [[ $uptime_sec -ge 3600 ]]; then
                uptime_str="$((uptime_sec / 3600))h"
            else
                uptime_str="$((uptime_sec / 60))m"
            fi
        fi

        local details=""
        [[ -n "$pid" ]] && details="pid:$pid"
        [[ -n "$mem_mb" ]] && details="${details:+$details }$mem_mb"
        [[ -n "$uptime_str" ]] && details="${details:+$details }up:$uptime_str"

        printf "  %s ACTIVE (%s)\n" "$padded_name" "$details"
    else
        printf "  %s ACTIVE\n" "$padded_name"
    fi
    return 0
}

show_usage() {
    cat <<'EOF'
nftban status — Global system status overview

USAGE:
  nftban status [OPTIONS]

OPTIONS:
  --json          Output in JSON format
  --brief         One-line output for CI/fleet/monitoring
  --quiet         Suppress suggestions and tips
  --help          Show this help

DESCRIPTION:
  Displays a consolidated overview of:
    • System information (hostname, kernel, uptime)
    • Firewall status (nftables, rules, bans)
    • Service status (nftables, login-alert)
    • Protection modules (DDoS, port-scan, Cloudflare, feeds)
    • Health check summary
    • Recent activity statistics

EXAMPLES:
  nftban status                Show full status dashboard
  nftban status --json         Output as JSON
  nftban status --quiet        Show status without tips

SEE ALSO:
  nftban health check         Full diagnostics
  nftban firewall validate    Detailed firewall info
  nftban stats dashboard      Detailed statistics
EOF
}

# =============================================================================
# SUBCOMMAND: pending (v1.43.0 P3-25)
# =============================================================================

_nftban_status_pending() {
    # Show pending/queued operations from the daemon opqueue
    # Args: [--json]

    local json_mode=0
    for arg in "$@"; do
        [[ "$arg" == "--json" || "$arg" == "-j" ]] && json_mode=1
    done

    # Load IPC module
    if ! declare -f nft_ipc_queue_status >/dev/null 2>&1; then
        if [[ -f "${NFTBAN_LIB_DIR}/lib/nft_ipc.sh" ]]; then
            # shellcheck source=/dev/null
            source "${NFTBAN_LIB_DIR}/lib/nft_ipc.sh" || true
        fi
    fi

    # Check daemon availability
    if ! declare -f nft_ipc_is_daemon_running >/dev/null 2>&1 || ! nft_ipc_is_daemon_running; then
        if [[ $json_mode -eq 1 ]]; then
            echo '{"success":false,"error":"daemon not running","pending":[]}'
        else
            echo "Daemon is not running — no pending operations"
        fi
        return 1
    fi

    # Query daemon status (includes queue depth)
    local response
    response=$(nft_ipc_queue_status 2>/dev/null) || {
        if [[ $json_mode -eq 1 ]]; then
            echo '{"success":false,"error":"IPC query failed","pending":[]}'
        else
            echo "ERROR: Failed to query daemon status" >&2
        fi
        return 1
    }

    if [[ $json_mode -eq 1 ]]; then
        echo "$response" | jq '{
            success: true,
            queue_depth: (.queue_depth // .pending_count // 0),
            total_applied: (.total_applied // 0),
            total_dropped: (.total_dropped // 0)
        }' 2>/dev/null || echo "$response"
    else
        local depth applied dropped
        depth=$(echo "$response" | jq -r '.queue_depth // .pending_count // 0' 2>/dev/null || echo "0")
        applied=$(echo "$response" | jq -r '.total_applied // 0' 2>/dev/null || echo "0")
        dropped=$(echo "$response" | jq -r '.total_dropped // 0' 2>/dev/null || echo "0")

        echo "NFTBan Pending Operations"
        echo "========================="
        echo ""
        echo "  Queue depth:     $depth"
        echo "  Total applied:   $applied"
        echo "  Total dropped:   $dropped"
        echo ""
        if [[ "$depth" == "0" ]]; then
            echo "  No pending operations."
        else
            echo "  $depth operations waiting to be applied."
        fi
    fi
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_cmd_status

# =============================================================================
# DIRECT EXECUTION SUPPORT
# =============================================================================

# If executed directly (not sourced), run the command handler
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_status "$@"
fi
