#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.3.0 - Global Status Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="cmd_status"
# meta:type="cli"
# meta:header="Global Status Command"
# meta:version="1.70.0"
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
# PROTECTION STATE — Go Validator Integration (v1.78.0)
# =============================================================================
# v1.84: Go validator is the sole authority for protection state.
# No legacy fallback. Missing validator = DOWN.
# Returns: PROTECTED | DEGRADED[:reason] | DOWN
# Exit code contract:
#   0 = PROTECTED    — everything works
#   1 = DEGRADED     — firewall up but issues
#   2 = DOWN         — nothing protecting
# NFTBAN_EXIT_COMPAT=v1 → DEGRADED returns 0 (one-release transition)

# Go validator binary path
_NFTBAN_VALIDATOR_BIN="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/bin/nftban-validate"

# v1.83 Win-3: Validator JSON cache. The validator is called once per
# nftban status invocation. The result is cached here so downstream
# functions (banner, health render) can reuse it without re-executing
# the binary. This eliminates 2 of 3 validator calls per status run.
_NFTBAN_VALIDATOR_CACHE=""

# =============================================================================
# v1.83 Win-2: Batch systemctl queries
# =============================================================================
# nftban status makes ~75 individual systemctl calls. This prefetch runs
# ONE systemctl is-active call for all known units and caches the results
# in an associative array. Lookup is then a bash array read (zero subprocesses).

declare -gA _UNIT_STATE=()
_UNIT_STATE_LOADED=false

_nftban_prefetch_unit_states() {
    # Batch-query all known units in one systemctl call.
    # systemctl is-active prints one line per unit (active/inactive/failed/etc).
    [[ "$_UNIT_STATE_LOADED" == "true" ]] && return 0

    # v1.83: DEAD-4 removed duplicate "nftband" (nftband.service suffices)
    # v1.83: DEAD-1 removed unused conflict units (fail2ban etc) — no callers
    local -a units=(
        nftband.service nftables.service
        nftban-maintenance.timer nftban-watchdog.timer nftban-queue.timer
        nftban-botscan.timer nftban-health.timer
        nftban-core-feeds.timer nftban-core-geoip.timer
        nftban-update-check.timer nftban-update-apply.timer
        nftban-unified-exporter.timer nftban-unified-exporter.service
        nftban-suricata.service nftban-suricata.timer nftban-suricata-update.timer
        nftban-snapshot.timer nftban-rollback.timer nftban-rbl-check.timer
        nftban-pro-license.timer nftban-pro-inventory.timer
        nftban-tunnel.timer
        suricata.service prometheus victoriametrics
    )

    local output
    output=$(systemctl is-active "${units[@]}" 2>/dev/null || true)

    local i=0
    while IFS= read -r state; do
        if [[ $i -lt ${#units[@]} ]]; then
            _UNIT_STATE["${units[$i]}"]="$state"
        fi
        i=$((i + 1))
    done <<< "$output"

    _UNIT_STATE_LOADED=true
}

# Lookup: returns 0 if unit is active, 1 otherwise.
# Drop-in replacement for: systemctl is-active <unit> >/dev/null 2>&1
_unit_is_active() {
    local unit="${1:-}"
    # Empty unit name = inactive (not a bash error)
    [[ -z "$unit" ]] && return 1
    # Prefetch on first call (lazy init)
    [[ "$_UNIT_STATE_LOADED" != "true" ]] && _nftban_prefetch_unit_states
    [[ "${_UNIT_STATE[$unit]:-inactive}" == "active" ]]
}

_nftban_protection_state_validator() {
    # v1.84: Go validator is the sole authority for protection state.
    # Returns: PROTECTED | DEGRADED[:reason] | DOWN
    # Missing or failed validator = DOWN (no fallback).

    if [[ ! -x "$_NFTBAN_VALIDATOR_BIN" ]]; then
        # v1.84 A2-1: Go validator is required. No legacy fallback.
        echo "ERROR: Go validator not found at $_NFTBAN_VALIDATOR_BIN" >&2
        echo "DOWN"
        return 1   # v1.152 BUG-S1a: ERROR-marked path must return rc>=1 (v1.139.2 rc-contract); DOWN sentinel still on stdout
    fi

    # Call validator with JSON output (or reuse cache)
    local _json _status _exit_code=0
    if [[ -n "$_NFTBAN_VALIDATOR_CACHE" ]]; then
        _json="$_NFTBAN_VALIDATOR_CACHE"
    else
        _json=$("$_NFTBAN_VALIDATOR_BIN" --json 2>/dev/null) || _exit_code=$?
    fi

    if [[ -z "$_json" ]]; then
        # v1.84 A2-1: Validator failure = DOWN. No legacy fallback.
        echo "ERROR: Go validator returned empty output" >&2
        echo "DOWN"
        return 1   # v1.152 BUG-S1b: ERROR-marked path must return rc>=1 (v1.139.2 rc-contract); DOWN sentinel still on stdout
    fi

    # v1.83 Win-3: Cache for downstream reuse (banner, health render)
    _NFTBAN_VALIDATOR_CACHE="$_json"

    # Extract status and schema version from JSON
    local _status _schema_version
    if command -v jq >/dev/null 2>&1; then
        _status=$(echo "$_json" | jq -r '.status' 2>/dev/null)
        _schema_version=$(echo "$_json" | jq -r '.schema_version // empty' 2>/dev/null)
    else
        _status=$(echo "$_json" | grep -oP '"status"\s*:\s*"\K[^"]+' || true)
        _schema_version=$(echo "$_json" | grep -oP '"schema_version"\s*:\s*"\K[^"]+' || true)
    fi

    # v1.83: Schema version guard — warn if validator schema doesn't match expected.
    # Prevents silent breakage if validator binary is from a different version.
    local _expected_schema="1.83.0"
    if [[ -n "$_schema_version" && "$_schema_version" != "$_expected_schema" ]]; then
        echo "WARNING: validator schema $_schema_version does not match expected $_expected_schema — binary may be outdated" >&2
    fi

    # Map validator status to display format with reason codes.
    # v1.83: The validator is the SOLE truth authority for protection state.
    # Shell MUST NOT recompute or override the validator verdict.
    # Daemon state (VAL-SERVICE-001) and timer liveness (VAL-TIMER-001)
    # are both checked inside the Go validator — if they were failing,
    # the validator would have returned "degraded", not "protected".
    case "$_status" in
        protected)
            echo "PROTECTED"
            ;;
        idle)
            echo "PROTECTED"
            ;;
        degraded)
            # Extract first finding code for reason display
            local _first_code=""
            if command -v jq >/dev/null 2>&1; then
                _first_code=$(echo "$_json" | jq -r '.findings[0].code // empty' 2>/dev/null)
            fi
            case "$_first_code" in
                VAL-ANCHOR-*)  echo "DEGRADED:D-ANCHOR" ;;
                VAL-CHAIN-*)   echo "DEGRADED:D-CHAIN" ;;
                VAL-TABLE-*)   echo "DEGRADED:D-TABLE" ;;
                VAL-SERVICE-*) echo "DEGRADED:D-DAEMON" ;;
                VAL-TIMER-*)   echo "DEGRADED:D-NOTIMERS" ;;
                *)             echo "DEGRADED:D-VALIDATOR" ;;
            esac
            ;;
        down)
            echo "DOWN"
            ;;
        *)
            # v1.84 A2-1: Unknown validator status = DOWN. No legacy fallback.
            echo "DOWN"
            ;;
    esac
}

# v1.84 A2-1: _nftban_protection_state_legacy() deleted.
# Go validator is the sole truth authority. No shell fallback.

_nftban_protection_state() {
    # v1.84: Direct call — no legacy fallback, no force-legacy override.
    _nftban_protection_state_validator
}

# =============================================================================
# CONFIG DIVERGENCE CHECK (v1.66.0)
# =============================================================================

_check_config_divergence() {
    # v1.83 DUP-2: Read config divergence from validator consistency axis.
    # The Go validator (consistency.go) already checks config↔kernel agreement
    # per module and emits VAL-CONS-001 findings. Shell must not re-derive this.
    #
    # Returns: module names with mismatch (one per line), empty if no divergence.
    local _json="${_NFTBAN_VALIDATOR_CACHE:-}"
    if [[ -z "$_json" ]]; then
        return 0  # No validator data — cannot determine divergence
    fi

    if ! command -v jq >/dev/null 2>&1; then
        return 0  # No jq — cannot parse
    fi

    # Extract VAL-CONS-001 findings (config/kernel mismatch)
    echo "$_json" | jq -r '.findings[] | select(.code == "VAL-CONS-001") | .component' 2>/dev/null || true
    return 0
}

# =============================================================================
# RULE COUNTING — Single Source of Truth (v1.24.0)
# =============================================================================

_nftban_count_rules() {
    # Count nftables rules consistently for both human and JSON output.
    local count
    count=$(nft -a list table ${NFTBAN_TABLE_IPV4} 2>/dev/null | grep -c "# handle" 2>/dev/null || true)
    count=${count:-0}
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
                # v1.144.0 PR-B UX-C2: 3-line ERROR/Hint/Run replaces the
                # full show_usage block on the unknown-option parse error
                # path. The explicit `nftban status --help` path (above)
                # still renders the full show_usage block.
                # v1.150 CLI-02: hint now lists ONLY tokens the parser above
                # actually accepts. The old hint advertised --counts/--pending/
                # --quick (none handled) so an operator following it re-hit the
                # same error.
                _v144_error_with_hint \
                    "Unknown option: $1" \
                    "Valid options: --json/-j, --brief/-b, --quiet/-q, pending, queue, --help" \
                    "nftban status --help"
                return $?
                ;;
        esac
    done

    # v1.24.0: Brief mode — one-line output for CI/fleet/monitoring
    if [[ $brief_mode -eq 1 ]]; then
        output_brief
        return $?
    fi

    # v1.83 Win-3: Pre-populate validator cache ONCE before any rendering.
    if [[ -x "$_NFTBAN_VALIDATOR_BIN" && -z "$_NFTBAN_VALIDATOR_CACHE" ]]; then
        _NFTBAN_VALIDATOR_CACHE=$("$_NFTBAN_VALIDATOR_BIN" --json 2>/dev/null || true)
    fi

    # v1.83 Win-2: Batch-prefetch all systemctl unit states in one call.
    _nftban_prefetch_unit_states

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
    # Format: PROTECTED | v1.84.0 | 26 banned | 9 whitelisted | protected
    # Exit codes: 0=PROTECTED, 1=DEGRADED, 2=DOWN

    local protection_state_raw
    protection_state_raw=$(_nftban_protection_state) || true   # v1.152 BUG-S1a/b: DOWN now returns rc>=1; keep the string, don't abort under set -e (exit-code mapped from base_state below)
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
    local health_word=""
    local _hs=""
    if [[ -r "$health_cache" ]]; then
        _hs=$(cat "$health_cache" 2>/dev/null) || _hs=""
    fi

    # v1.80.0: UNKNOWN is forbidden - derive from protection state if cache unavailable
    if [[ -z "$_hs" || "$_hs" == "UNKNOWN" ]]; then
        case "$base_state" in
            PROTECTED) _hs="PROTECTED" ;;
            DEGRADED)  _hs="WARNING" ;;
            DOWN|*)    _hs="ERROR" ;;
        esac
    fi

    # M81-5: "healthy" is a banned term. Use "protected" per vocabulary.
    case "$_hs" in
        OK) health_word="protected" ;;
        WARNING*) health_word="info" ;;
        ERROR*|CRITICAL*) health_word="errors" ;;
        *) health_word="protected" ;; # Default to protected if still unknown
    esac

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
    elif _unit_is_active nftables.service; then
        nft_status="ACTIVE"
    fi
    printf "  %-20s %s\n" "nftables............" "$nft_status"

    # v1.24.0: Use shared rule counting function
    local rule_count=0
    if command -v nft >/dev/null 2>&1; then
        rule_count=$(_nftban_count_rules)
    fi
    printf "  %-20s %s\n" "Rules..............." "$rule_count"

    # v1.141 PR-C (D-headline + D-cache-wording): kernel is authoritative per
    # SELECT_CACHE_KERNEL_AUTHORITY=kernel (operator 2026-05-28). Headline
    # 'Banned IPs' is the sum of kernel blacklist_ipv4 (feed+geoban) +
    # blacklist_manual_ipv4 (admin) + v6 equivalents. Four-way split shown
    # below so an operator sees attribution. Pre-v1.141 'cache may lag' is
    # replaced by an explicit 'reconciled Ns ago' note that only fires when
    # the source-index disagrees with the kernel. (V1_141_0 §2 D-headline.)
    local kernel_v4_auto=0 kernel_v4_manual=0 kernel_v6_auto=0 kernel_v6_manual=0
    if declare -f nftban_nft_count_set >/dev/null 2>&1; then
        kernel_v4_auto=$(nftban_nft_count_set ip nftban blacklist_ipv4 2>/dev/null || echo 0)
        kernel_v4_manual=$(nftban_nft_count_set ip nftban blacklist_manual_ipv4 2>/dev/null || echo 0)
        kernel_v6_auto=$(nftban_nft_count_set ip6 nftban blacklist_ipv6 2>/dev/null || echo 0)
        kernel_v6_manual=$(nftban_nft_count_set ip6 nftban blacklist_manual_ipv6 2>/dev/null || echo 0)
    fi
    local _auto_total=$((kernel_v4_auto + kernel_v6_auto))
    local _manual_total=$((kernel_v4_manual + kernel_v6_manual))
    local kernel_total=$((_auto_total + _manual_total))
    # ban_count stays the headline-authority count so existing quick-commands
    # gating on it works unchanged.
    local ban_count=$kernel_total

    printf "  %-20s %s\n" "Banned IPs.........." "$kernel_total"
    printf "  %-20s %s\n" "  Automatic (feeds)." "$_auto_total"
    printf "  %-20s %s\n" "  Manual (admin)...." "$_manual_total"
    printf "  %-20s %s\n" "  Total kernel......" "$kernel_total"

    if declare -f nftban_stats_count_active_bans >/dev/null 2>&1; then
        local _cache_count
        _cache_count=$(nftban_stats_count_active_bans 2>/dev/null || echo "")
        if [[ -n "$_cache_count" ]] && [[ "$_cache_count" != "$kernel_total" ]]; then
            local _cache_file="${NFTBAN_CACHE_DIR:-/var/cache/nftban}/stats/unified_stats.json"
            local _stale_msg=""
            if [[ -f "$_cache_file" ]]; then
                local _ct _now _age
                _ct=$(stat -c %Y "$_cache_file" 2>/dev/null || echo 0)
                _now=$(date +%s)
                _age=$((_now - _ct))
                if (( _age >= 0 )); then
                    _stale_msg=" (reconciled ${_age}s ago)"
                fi
            fi
            printf "  %-20s %s\n" "  Source-index......" "${_cache_count}${_stale_msg}"
        fi
    fi

    # Count whitelisted IPs (SINGLE SOURCE OF TRUTH: nftban_stats.sh)
    local whitelist_count=0
    if declare -f nftban_stats_count_whitelist >/dev/null 2>&1; then
        whitelist_count=$(nftban_stats_count_whitelist)
    fi
    printf "  %-20s %s\n" "Whitelisted IPs....." "$whitelist_count"

    # Check master switch
    # v1.150 MOD-09: source the BASE services.conf first, then the .local
    # override. Pre-v1.150 only the .local file was sourced, so NFTBAN_ENABLED=false
    # set in the base services.conf was ignored and status reported ENABLED.
    local master_enabled="true"
    if [[ -f "${NFTBAN_CONFIG_DIR}/conf.d/services.conf" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_CONFIG_DIR}/conf.d/services.conf" 2>/dev/null || true
        master_enabled="${NFTBAN_ENABLED:-true}"
    fi
    if [[ -f "${NFTBAN_CONFIG_DIR}/conf.d/services.conf.local" ]]; then
        # shellcheck source=/dev/null
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

    # v1.141 PR-C (D-verify-hint): kernel is the authoritative source per
    # CLAUDE.md project rule ('Kernel verification (nft list set) proves
    # enforcement, not CLI output alone'). Print copy-pasteable nft list set
    # commands so an operator can independently confirm the four blacklist
    # sets that produced the headline above. Gated on quiet mode AND on
    # ban_count > 0 so a fresh install with zero bans isn't given advice it
    # can't act on. (V1_141_0 §2 D-verify-hint.)
    if [[ $quiet_mode -eq 0 ]] && [[ $ban_count -gt 0 ]]; then
        echo ""
        echo "  Verify kernel (authoritative):"
        echo "    nft list set ip nftban blacklist_ipv4"
        echo "    nft list set ip nftban blacklist_manual_ipv4"
        echo "    nft list set ip6 nftban blacklist_ipv6"
        echo "    nft list set ip6 nftban blacklist_manual_ipv6"
    fi
    echo ""
}

_status_section_authority() {
    # ─────────────────────────────────────────────────────────────────────
    # AUTHORITY (v1.118 B1)
    # ─────────────────────────────────────────────────────────────────────
    # Surfaces install_state AUTHORITY + CONFLICTS so operators on
    # AMBIGUOUS hosts (CSF/lfd/firewalld still active) see the resolution
    # command without having to read /var/lib/nftban/state/install_state.
    # No-op when the state file is missing or AUTHORITY is empty.
    local state_file="${NFTBAN_STATE_DIR:-/var/lib/nftban/state}/install_state"
    [[ -f "$state_file" ]] || return 0

    local authority conflicts
    authority=$(grep '^AUTHORITY=' "$state_file" 2>/dev/null | head -1 | cut -d= -f2-)
    conflicts=$(grep '^CONFLICTS=' "$state_file" 2>/dev/null | head -1 | cut -d= -f2-)

    [[ -z "$authority" ]] && return 0

    echo "AUTHORITY"
    echo "───────────────────────────────────────────────────────────────"
    printf "  %-20s %s\n" "Install authority..." "$authority"
    if [[ -n "$conflicts" ]]; then
        printf "  %-20s %s\n" "Active conflicts...." "$conflicts"
    fi
    if [[ "$authority" == "AMBIGUOUS" && -n "$conflicts" ]]; then
        echo ""
        echo "  WARNING: $conflicts still active — nftban is not sole authority."
        echo "  ACTION:  Run 'nftban firewall takeover --panel-auto-takeover' to let nftban"
        echo "           disarm detected panel/firewall conflicts and become the active"
        echo "           firewall authority."
        echo "           Note: --panel-auto-takeover permits panel-aware conflict handling;"
        echo "           the wrapper invokes the installer with takeover authorization."
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
        elif _unit_is_active suricata.service; then
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
                [[ $eve_age -le $eve_threshold ]] && eve_fresh=true || true
            fi

            if [[ "$eve_fresh" == "true" ]]; then
                suricata_eve_ok=true
                # Check rules_loaded from any EVE JSON file (main or threaded)
                local rules_loaded=0
                shopt -s nullglob
                for ef in "$eve_file" "$eve_dir"/eve-alerts.*.json; do
                    [[ -f "$ef" ]] || continue
                    rules_loaded=$(grep -o '"rules_loaded":[0-9]*' "$ef" 2>/dev/null | tail -1 | cut -d: -f2 || echo "0")
                    [[ "${rules_loaded:-0}" -gt 0 ]] && break || true
                done
                shopt -u nullglob

                if [[ "${rules_loaded:-0}" -eq 0 ]]; then
                    suricata_status="BROKEN (0 rules loaded!)"
                elif _unit_is_active nftban-suricata.service; then
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

    # DDoS Protection — v1.83 DUP-3: read from validator JSON, not config+kernel
    local ddos_status="DISABLED"
    local _ddos_config _ddos_structural
    if [[ -n "${_NFTBAN_VALIDATOR_CACHE:-}" ]] && command -v jq >/dev/null 2>&1; then
        _ddos_config=$(echo "$_NFTBAN_VALIDATOR_CACHE" | jq -r '.modules.ddos.config // "disabled"' 2>/dev/null)
        _ddos_structural=$(echo "$_NFTBAN_VALIDATOR_CACHE" | jq -r '.modules.ddos.structural // "-"' 2>/dev/null)
        if [[ "$_ddos_config" == "enabled" && "$_ddos_structural" == "present" ]]; then
            ddos_status="ENABLED"
        elif [[ "$_ddos_config" == "enabled" && "$_ddos_structural" != "present" ]]; then
            ddos_status="NOT INSTALLED"
        elif [[ "$_ddos_config" == "disabled" && "$_ddos_structural" == "present" ]]; then
            ddos_status="PRESENT (disabled in config)"
        fi
    fi
    printf "  %-20s %s\n" "DDoS................" "$ddos_status"

    # Port-scan Detection — v1.83 DUP-3: read from validator JSON
    local portscan_status="DISABLED"
    local portscan_enabled="false"
    if [[ -n "${_NFTBAN_VALIDATOR_CACHE:-}" ]] && command -v jq >/dev/null 2>&1; then
        local _ps_config
        _ps_config=$(echo "$_NFTBAN_VALIDATOR_CACHE" | jq -r '.modules.portscan.config // "disabled"' 2>/dev/null)
        if [[ "$_ps_config" == "enabled" ]]; then
            portscan_enabled="true"
            if [[ "$suricata_eve_ok" == "true" ]]; then
                portscan_status="ENABLED (Suricata mode)"
            elif _unit_is_active suricata.service; then
                portscan_status="ENABLED (Classic — Suricata EVE stale)"
            else
                portscan_status="ENABLED (Classic mode)"
            fi
        elif [[ "$suricata_eve_ok" == "true" ]]; then
            portscan_status="AVAILABLE (not enabled)"
        fi
    fi
    printf "  %-20s %s\n" "Port Scan..........." "$portscan_status"

    # Protection module explanation (if not quiet mode)
    local ddos_enabled="false"
    [[ "${_ddos_config:-disabled}" == "enabled" ]] && ddos_enabled="true"
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
                elif _unit_is_active suricata.service; then
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
    if _unit_is_active nftband.service; then
        local _lm_en="false"
        # Check Go daemon loginmon config (LOGIN_ENABLED — written by `nftban login enable`)
        local _lm_go_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/login/main.conf"
        [[ -f "${_lm_go_conf}.local" ]] && _lm_en=$(grep -m1 '^LOGIN_ENABLED=' "${_lm_go_conf}.local" 2>/dev/null | cut -d'"' -f2 || echo "false")
        [[ "$_lm_en" != "true" ]] && [[ -f "$_lm_go_conf" ]] && _lm_en=$(grep -m1 '^LOGIN_ENABLED=' "$_lm_go_conf" 2>/dev/null | cut -d'"' -f2 || echo "false")
        # Fallback: check bash alert config (NFTBAN_LOGIN_ALERT_ENABLED)
        if [[ "$_lm_en" != "true" ]]; then
            local _lm_alert_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/login_alert.conf"
            [[ -f "${_lm_alert_conf}.local" ]] && _lm_en=$(grep -m1 '^NFTBAN_LOGIN_ALERT_ENABLED=' "${_lm_alert_conf}.local" 2>/dev/null | cut -d'"' -f2 || echo "false")
            [[ "$_lm_en" != "true" ]] && [[ -f "$_lm_alert_conf" ]] && _lm_en=$(grep -m1 '^NFTBAN_LOGIN_ALERT_ENABLED=' "$_lm_alert_conf" 2>/dev/null | cut -d'"' -f2 || echo "false") || true
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
    # v1.150 HLT-08: count banned countries by the real geoban.d/50-ban-*.conf
    # files. The previous `geoban list | grep -c "BLOCKED"` never matched: the
    # list output emits "🚫 Banned Countries:" plus country lines, never the
    # token "BLOCKED", so geoban always showed DISABLED even with countries
    # actively banned. The file count mirrors nftban_geoban.sh and the exporter.
    local geoban_status="DISABLED"
    local banned_countries=0
    local _geoban_dir="${NFTBAN_CONFIG_DIR:-/etc/nftban}/geoban.d"
    if [[ -d "$_geoban_dir" ]]; then
        banned_countries=$(find "$_geoban_dir" -maxdepth 1 -name '50-ban-*.conf' -type f 2>/dev/null | wc -l)
    fi
    banned_countries=${banned_countries//[^0-9]/}
    banned_countries=${banned_countries:-0}
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
            # v1.80.0 FIX: Only count within "elements = { }" section
            local _bg_out_v4 _bg_out_v6
            _bg_out_v4=$(nft list set ip nftban http_bot_suspect 2>/dev/null)
            _bg_out_v6=$(nft list set ip6 nftban http_bot_suspect6 2>/dev/null)
            if echo "$_bg_out_v4" | grep -q 'elements = {'; then
                v4_suspects=$(echo "$_bg_out_v4" | sed -n '/elements = {/,/}/p' | grep -o ' timeout ' | wc -l)
            fi
            if echo "$_bg_out_v6" | grep -q 'elements = {'; then
                v6_suspects=$(echo "$_bg_out_v6" | sed -n '/elements = {/,/}/p' | grep -o ' timeout ' | wc -l)
            fi
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
    _unit_is_active "$prometheus_service" && prom_running=true
    _unit_is_active "$victoriametrics_service" && vm_running=true
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
    if _unit_is_active nftban-unified-exporter.timer || \
       _unit_is_active nftban-unified-exporter.service; then
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
        if _unit_is_active nftban-unified-exporter.timer; then
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

        if _unit_is_active nftban-unified-exporter.timer; then
            connector_status="ACTIVE ($connector_count connectors)"
        else
            connector_status="ENABLED ($connector_count connectors, timer inactive)"
        fi
    elif [[ -f "$connectors_conf" ]]; then
        connector_status="DISABLED"
    fi
    printf "  %-20s %s\n" "Connectors.........." "$connector_status"
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
    local health_status=""
    local _health_base_state="${protection_state%%:*}"

    if [[ -r "$health_cache" ]]; then
        health_status=$(cat "$health_cache" 2>/dev/null) || health_status=""
    fi

    # v1.80.0: UNKNOWN is forbidden - derive from protection state if cache unavailable
    # Deterministic mapping: protection_state → health_status
    if [[ -z "$health_status" || "$health_status" == "UNKNOWN" ]]; then
        case "$_health_base_state" in
            PROTECTED) health_status="PROTECTED" ;;
            DEGRADED)  health_status="WARNING" ;;
            DOWN|*)    health_status="ERROR" ;;
        esac
    fi

    # v1.66.0: If firewall is PROTECTED, don't show misleading ERROR from optional checks
    if [[ "$_health_base_state" == "PROTECTED" ]] && [[ "$health_status" == *"ERROR"* || "$health_status" == *"CRITICAL"* ]]; then
        printf "  %-20s %s\n" "Overall Status......" "PROTECTED (info notices)"
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
            [[ $security_issues -gt 0 ]] && break || true
        fi
    done

    local security_status="PROTECTED"
    if [[ $security_issues -gt 0 ]]; then
        security_status="${security_issues} systemd issue(s)"
    fi

    # Get posture status + details (SSH, sudo, systemd, config integrity)
    local posture_status="PROTECTED"
    local posture_details=""
    if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_report_data.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/lib/nftban_report_data.sh" 2>/dev/null || true
        if declare -f _collect_posture_info &>/dev/null; then
            declare -A _posture_data
            _collect_posture_info _posture_data 2>/dev/null || true
            posture_status="${_posture_data[POSTURE_STATUS]:-OK}"
            posture_details="${_posture_data[POSTURE_DETAILS]:-}"
            unset _posture_data
        fi
    fi

    # Combine into single posture line
    local combined_posture="PROTECTED"
    if [[ "$security_status" != "PROTECTED" || "$posture_status" != "PROTECTED" ]]; then
        combined_posture=""
        [[ "$security_status" != "PROTECTED" ]] && combined_posture="$security_status"
        if [[ "$posture_status" != "PROTECTED" ]]; then
            [[ -n "$combined_posture" ]] && combined_posture+=", "
            combined_posture+="$posture_status"
        fi
    fi

    if [[ "$combined_posture" == "PROTECTED" ]]; then
        printf "  %-20s ✅ %s\n" "Security Posture...." "$combined_posture"
    else
        printf "  %-20s ⚠️  %s\n" "Security Posture...." "$combined_posture"
        # Show what the advisories are so the user knows what to fix
        if [[ -n "$posture_details" ]]; then
            # Split semicolon-separated details into individual lines
            local IFS=';'
            for detail in $posture_details; do
                detail="${detail# }"  # trim leading space
                [[ -n "$detail" ]] && printf "      → %s\n" "$detail"
            done
            unset IFS
        fi
    fi

    # Show hints if not OK (only in non-quiet mode)
    if [[ $quiet_mode -eq 0 ]] && { [[ "$health_status" != "PROTECTED" ]] || [[ "$combined_posture" != "PROTECTED" ]]; }; then
        echo "      → Details: nftban health check"
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
        ["nftban-update-check.timer"]="Daily update check"
        ["nftban-update-apply.timer"]="Weekly auto-update apply"
    )

    local timer_count=0
    local timer_active=0
    local timer_output=""

    for timer in "${!timer_desc[@]}"; do
        if systemctl list-unit-files "$timer" --no-legend 2>/dev/null | grep -q "$timer"; then
            timer_count=$((timer_count + 1))
            local status_text="INACTIVE"
            local next_run=""

            if _unit_is_active "$timer"; then
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
        dns_status="AVAILABLE"
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
    protection_state=$(_nftban_protection_state) || true   # v1.152 BUG-S1a/b: DOWN now returns rc>=1; keep the string, don't abort under set -e
    local _base_state="${protection_state%%:*}"

    # Header with version and state
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NFTBan v${NFTBAN_VERSION:-unknown} — System Status — ${protection_state}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    _status_section_system "$protection_state"
    _status_section_firewall "$quiet_mode"
    _status_section_authority
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
    json_state_raw=$(_nftban_protection_state) || true   # v1.152 BUG-S1a/b: DOWN now returns rc>=1; keep the string, don't abort under set -e (json path)
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
    echo "  \"status\": \"$json_base_state\","
    # v1.86 B86-3: "state" backward-compat key removed (was scheduled for v1.83)
    if [[ -n "$json_reason" ]]; then
        echo "  \"degraded_reason\": \"$json_reason\","
    fi
    echo "  \"config_divergence\": [${_json_div_array}],"
    echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"hostname\": \"$(hostname)\","

    # Firewall
    local nft_active=false
    _unit_is_active nftables.service && nft_active=true

    echo "  \"firewall\": {"
    echo "    \"nftables_active\": $nft_active,"

    # v1.24.0: Use shared rule counting function (matches human output)
    local rule_count=0
    if command -v nft >/dev/null 2>&1; then
        rule_count=$(_nftban_count_rules)
    fi
    echo "    \"rule_count\": $rule_count,"

    # v1.141 PR-C (D-json-fork): banned_ips is now ALWAYS the kernel total
    # so the text-mode headline (which also uses kernel total) and the JSON
    # surface never contradict. The four-way kernel split is exposed under
    # counts.kernel_{total,automatic,manual} so JSON consumers can attribute
    # bans to feed/admin sources. cache_count + source_index_count remain
    # below but are clearly subordinate; counts.authority="kernel" marks
    # which field consumers should use. (V1_141_0 §2 D-json-fork.)
    local jk_v4_auto=0 jk_v4_manual=0 jk_v6_auto=0 jk_v6_manual=0
    if declare -f nftban_nft_count_set >/dev/null 2>&1; then
        jk_v4_auto=$(nftban_nft_count_set ip nftban blacklist_ipv4 2>/dev/null || echo 0)
        jk_v4_manual=$(nftban_nft_count_set ip nftban blacklist_manual_ipv4 2>/dev/null || echo 0)
        jk_v6_auto=$(nftban_nft_count_set ip6 nftban blacklist_ipv6 2>/dev/null || echo 0)
        jk_v6_manual=$(nftban_nft_count_set ip6 nftban blacklist_manual_ipv6 2>/dev/null || echo 0)
    fi
    local kernel_automatic=$((jk_v4_auto + jk_v6_auto))
    local kernel_manual=$((jk_v4_manual + jk_v6_manual))
    local kernel_count=$((kernel_automatic + kernel_manual))
    local ban_count=$kernel_count
    echo "    \"banned_ips\": $ban_count,"

    # v1.141 PR-C (D-json-fork): structured counts subordinate to the
    # kernel authority computed above. cache_count + source_index_count are
    # surfaced for transparency / drift detection but `authority`="kernel"
    # tells JSON consumers which field to trust. kernel_elements is kept as
    # a backward-compat alias for kernel_total.
    local cache_count=0 source_index_count=0
    if declare -f nftban_stats_get_unified >/dev/null 2>&1; then
        cache_count=$(nftban_stats_get_unified ".blacklist.total" 2>/dev/null || echo 0)
    fi
    if [[ -S /run/nftban/nftband.sock ]]; then
        local si_resp
        si_resp=$(nftban_ipc_call "source_index_count" 2>/dev/null || echo "")
        if [[ -n "$si_resp" ]]; then
            source_index_count=$(echo "$si_resp" | grep -o '"count":[0-9]*' | head -1 | cut -d: -f2)
            source_index_count=${source_index_count:-0}
        fi
    fi
    echo "    \"counts\": {"
    echo "      \"authority\": \"kernel\","
    echo "      \"kernel_total\": $kernel_count,"
    echo "      \"kernel_automatic\": $kernel_automatic,"
    echo "      \"kernel_manual\": $kernel_manual,"
    echo "      \"kernel_elements\": $kernel_count,"
    echo "      \"cache_count\": $cache_count,"
    echo "      \"source_index_count\": $source_index_count"
    echo "    },"

    # Add dashboard fields for scripts/API consumers
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

    # M81-5/M81-6: renamed from threats_blocked_24h to enforcement_events_24h.
    # "threats blocked" is a banned interpretation per vocabulary.
    # This counter represents enforcement events (bans issued), not threats mitigated.
    local enforcement_24h=0
    if command -v nftban_stats_count_bans >/dev/null 2>&1; then
        local since
        since=$(($(date +%s) - 86400))
        enforcement_24h=$(nftban_stats_count_bans "$since" 2>/dev/null || echo 0)
    fi
    echo "    \"enforcement_events_24h\": $enforcement_24h"
    echo "  },"

    # Authority + conflicts (v1.118 B1)
    local _json_auth_state="" _json_auth_conflicts=""
    local _json_auth_file="${NFTBAN_STATE_DIR:-/var/lib/nftban/state}/install_state"
    if [[ -f "$_json_auth_file" ]]; then
        _json_auth_state=$(grep '^AUTHORITY=' "$_json_auth_file" 2>/dev/null | head -1 | cut -d= -f2-)
        _json_auth_conflicts=$(grep '^CONFLICTS=' "$_json_auth_file" 2>/dev/null | head -1 | cut -d= -f2-)
    fi
    local _json_auth_ambig=false
    [[ "$_json_auth_state" == "AMBIGUOUS" && -n "$_json_auth_conflicts" ]] && _json_auth_ambig=true
    echo "  \"authority\": {"
    echo "    \"state\": \"${_json_auth_state}\","
    echo "    \"conflicts\": \"${_json_auth_conflicts}\","
    echo "    \"ambiguous_with_conflicts\": $_json_auth_ambig"
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

        if _unit_is_active "$unit"; then
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

    # M81-5: "healthy" is a banned term. Use vocabulary-approved states.
    local health_status="unknown"
    case $health_exit in
        0) health_status="protected" ;;
        1) health_status="warnings" ;;
        2) health_status="errors" ;;
    esac

    # v1.66.0: JSON health parity — when PROTECTED, health errors are informational
    if [[ "$json_base_state" == "PROTECTED" ]] && [[ "$health_status" == "errors" ]]; then
        health_status="protected"
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
        [[ "$gs" == "true" ]] && json_geoban_skipped=true || true
    fi

    # Check permanent bans
    local json_perm_file="/var/lib/nftban/state/permanent_bans.json"
    if [[ -f "$json_perm_file" ]]; then
        json_perm_bans=$(jq -r '.bans | length // 0' "$json_perm_file" 2>/dev/null || echo "0")
        json_perm_protected=$(jq -r '[.bans[]] | map(select(.protected == true)) | length // 0' "$json_perm_file" 2>/dev/null || echo "0")
        [[ ! "$json_perm_bans" =~ ^[0-9]+$ ]] && json_perm_bans=0
        [[ ! "$json_perm_protected" =~ ^[0-9]+$ ]] && json_perm_protected=0 || true
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

    # System info for scripts/API
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
    _unit_is_active suricata.service && suricata_enabled=true
    _unit_is_active nftban-suricata.service && suricata_banning=true
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
    # v1.150 HLT-08: count banned countries by the real geoban.d/50-ban-*.conf
    # files (mirrors the terminal-mode fix). The old `geoban list | grep -c
    # "BLOCKED"` never matched the list output, so JSON status reported geoban
    # disabled with 0 countries even while countries were actively banned.
    local geoban_enabled=false geoban_countries=0
    local _json_geoban_dir="${NFTBAN_CONFIG_DIR:-/etc/nftban}/geoban.d"
    if [[ -d "$_json_geoban_dir" ]]; then
        geoban_countries=$(find "$_json_geoban_dir" -maxdepth 1 -name '50-ban-*.conf' -type f 2>/dev/null | wc -l)
    fi
    geoban_countries=${geoban_countries//[^0-9]/}
    geoban_countries=${geoban_countries:-0}
    [[ "$geoban_countries" =~ ^[0-9]+$ ]] && [[ "$geoban_countries" -gt 0 ]] && geoban_enabled=true
    echo "    \"geoban\": {\"enabled\": $geoban_enabled, \"blocked_countries\": $geoban_countries},"

    # Bot Guard
    local json_botguard_enabled=false
    if [[ -f "${NFTBAN_CONFIG_DIR}/conf.d/botguard/main.conf" ]]; then
        local bg_val=""
        bg_val=$(grep -m1 "^HTTP_BOTGUARD_ENABLED=" "${NFTBAN_CONFIG_DIR}/conf.d/botguard/main.conf.local" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || true)
        [[ -z "$bg_val" ]] && bg_val=$(grep -m1 "^HTTP_BOTGUARD_ENABLED=" "${NFTBAN_CONFIG_DIR}/conf.d/botguard/main.conf" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || true)
        [[ "$bg_val" == "true" ]] && json_botguard_enabled=true || true
    fi
    local json_bg_v4=0 json_bg_v6=0
    if [[ "$json_botguard_enabled" == "true" ]]; then
        # v1.80.0 FIX: Only count within "elements = { }" section
        local _json_bg_out_v4 _json_bg_out_v6
        _json_bg_out_v4=$(nft list set ip nftban http_bot_suspect 2>/dev/null)
        _json_bg_out_v6=$(nft list set ip6 nftban http_bot_suspect6 2>/dev/null)
        if echo "$_json_bg_out_v4" | grep -q 'elements = {'; then
            json_bg_v4=$(echo "$_json_bg_out_v4" | sed -n '/elements = {/,/}/p' | grep -o ' timeout ' | wc -l)
        fi
        if echo "$_json_bg_out_v6" | grep -q 'elements = {'; then
            json_bg_v6=$(echo "$_json_bg_out_v6" | sed -n '/elements = {/,/}/p' | grep -o ' timeout ' | wc -l)
        fi
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
    local timer_list=("nftban-health.timer" "nftban-core-feeds.timer" "nftban-core-geoip.timer" "nftban-maintenance.timer" "nftban-unified-exporter.timer" "nftban-queue.timer" "nftban-suricata-update.timer" "nftban-snapshot.timer" "nftban-rollback.timer" "nftban-rbl-check.timer" "nftban-tunnel.timer" "nftban-pro-inventory.timer" "nftban-pro-license.timer" "nftban-update-check.timer" "nftban-update-apply.timer")
    local timer_json=""
    for timer in "${timer_list[@]}"; do
        local timer_name="${timer%.timer}"
        timer_name="${timer_name#nftban-}"
        local timer_active=false
        _unit_is_active "$timer" && timer_active=true
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
    if ! _unit_is_active "$unit"; then
        # For timer-triggered services, check if the corresponding timer is active
        local timer_unit="${unit%.service}.timer"
        if _unit_is_active "$timer_unit"; then
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

SUBCOMMANDS:
  pending, queue  Show pending/queued daemon operations

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
        [[ "$arg" == "--json" || "$arg" == "-j" ]] && json_mode=1 || true
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
