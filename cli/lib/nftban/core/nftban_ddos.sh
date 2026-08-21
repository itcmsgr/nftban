#!/usr/bin/env bash
# =============================================================================
# NFTBan - DDoS Protection Module - MAIN CONTROLLER
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Dual-mode DDoS protection with auto-detection
#
# meta:name="nftban_ddos"
# meta:type="core"
# meta:header="DDoS Protection"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# **Description**
# Main controller for DDoS protection with dual-mode support:
#
#   CLASSIC MODE:  Pure nftables (no Suricata required)
#   SURICATA MODE: IDS-integrated with scoring engine
#   HYBRID MODE:   Classic as Layer 0 + Suricata as Layer 1
#   AUTO MODE:     Auto-detect best mode based on system
#
# **Mode Selection Logic:**
#   1. Check DDOS_MODE in config (auto/classic/suricata/hybrid)
#   2. If "auto": detect Suricata availability
#   3. Load appropriate sub-module
#
# meta:description="Dual-mode DDoS protection with auto-detection"
# meta:depends="bash>=4.0,nftables>=0.9.0"
# meta:inventory.files=""
# meta:inventory.binaries="nft,systemctl"
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/conf.d/ddos/main.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
# meta:created_date="2025-12-01"
# meta:updated_date="2026-02-05"
# =============================================================================

set -Eeuo pipefail

# v1.229.7 PR-3A: the apply/teardown halves consume a RESOLVED MODULE PLAN from
# nftban_module_resolve_plan (lib/module_authority.sh). The daemon sources this
# file standalone (`bash -c 'source "$1" && nftban_ddos_apply'`), so the authority
# must be guard-sourced here rather than assumed present.
# shellcheck source=/usr/lib/nftban/lib/module_authority.sh
if ! declare -F nftban_module_resolve_plan >/dev/null 2>&1 && \
   [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/module_authority.sh" ]]; then
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/module_authority.sh" 2>/dev/null || true
fi
IFS=$'\n\t'
umask 027

# =============================================================================
# MODULE GUARD
# =============================================================================

[[ -n "${NFTBAN_DDOS_LOADED:-}" ]] && return 0
readonly NFTBAN_DDOS_LOADED=1

# =============================================================================
# MODULE METADATA
# =============================================================================

# shellcheck disable=SC2034  # Module metadata used when sourced
readonly DDOS_MODULE_NAME="nftban_ddos"
# shellcheck disable=SC2034  # Module metadata used when sourced
readonly DDOS_MODULE_VERSION="1.0.0"
# shellcheck disable=SC2034  # Module metadata used when sourced
readonly DDOS_MODULE_TYPE="core"
# shellcheck disable=SC2034  # Module metadata used when sourced
readonly DDOS_MODULE_DESCRIPTION="DDoS Protection (Dual-Mode)"

# =============================================================================
# PATHS
# =============================================================================

: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"
NFTBAN_DDOS_LIB_DIR="$NFTBAN_LIB_DIR"
: "${NFTBAN_CONFIG_DIR:=/etc/nftban}"
NFTBAN_DDOS_CONFIG_DIR="$NFTBAN_CONFIG_DIR"
readonly NFTBAN_DDOS_LOG_FILE="${NFTBAN_LOG_DIR:-/var/log/nftban}/ddos.log"

# =============================================================================
# LOAD SHARED LIBRARIES
# =============================================================================

# Source timestamp utilities (with graceful fallback)
if [[ -f "${NFTBAN_DDOS_LIB_DIR}/lib/nftban_timestamp.sh" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_DDOS_LIB_DIR}/lib/nftban_timestamp.sh" || return 1
elif [[ -f "$(dirname "${BASH_SOURCE[0]}")/../lib/nftban_timestamp.sh" ]]; then
    # shellcheck source=/dev/null
    source "$(dirname "${BASH_SOURCE[0]}")/../lib/nftban_timestamp.sh" || return 1
fi

# Source file utilities (with graceful fallback)
if [[ -f "${NFTBAN_DDOS_LIB_DIR}/lib/nftban_file_utils.sh" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_DDOS_LIB_DIR}/lib/nftban_file_utils.sh" || return 1
elif [[ -f "$(dirname "${BASH_SOURCE[0]}")/../lib/nftban_file_utils.sh" ]]; then
    # shellcheck source=/dev/null
    source "$(dirname "${BASH_SOURCE[0]}")/../lib/nftban_file_utils.sh" || return 1
fi

# =============================================================================
# LOAD SUB-MODULES
# =============================================================================

# Source classic module
if [[ -f "${NFTBAN_DDOS_LIB_DIR}/core/nftban_ddos_classic.sh" ]]; then
    source "${NFTBAN_DDOS_LIB_DIR}/core/nftban_ddos_classic.sh" || return 1
elif [[ -f "$(dirname "${BASH_SOURCE[0]}")/nftban_ddos_classic.sh" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/nftban_ddos_classic.sh" || return 1
fi

# Source suricata module
if [[ -f "${NFTBAN_DDOS_LIB_DIR}/core/nftban_ddos_suricata.sh" ]]; then
    source "${NFTBAN_DDOS_LIB_DIR}/core/nftban_ddos_suricata.sh" || return 1
elif [[ -f "$(dirname "${BASH_SOURCE[0]}")/nftban_ddos_suricata.sh" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/nftban_ddos_suricata.sh" || return 1
fi

# =============================================================================
# CONFIGURATION LOADING
# =============================================================================

_nftban_ddos_load_config() {
    local main_config="${NFTBAN_DDOS_CONFIG_DIR}/conf.d/ddos/main.conf"
    local main_local="${NFTBAN_DDOS_CONFIG_DIR}/conf.d/ddos/main.conf.local"

    # Load defaults first
    if [[ -f "$main_config" ]]; then
        # shellcheck source=/dev/null
        source "$main_config" || true
    fi

    # Load user overrides (takes precedence)
    if [[ -f "$main_local" ]]; then
        # shellcheck source=/dev/null
        # IMPL-1: ensure _source_local is defined wherever this file is loaded (env.sh idempotent)
        declare -F _source_local >/dev/null 2>&1 || source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/env.sh" 2>/dev/null || true
        _source_local "$main_local"
    fi

    # Set defaults
    : "${DDOS_ENABLED:=false}"
    : "${DDOS_MODE:=auto}"
    : "${DDOS_AUTO_CHECK_SERVICE:=true}"
    : "${DDOS_AUTO_CHECK_BINARY:=true}"
    : "${DDOS_AUTO_CHECK_EVE_FILE:=true}"
    : "${DDOS_SURICATA_SERVICE_NAME:=suricata}"
    : "${DDOS_SURICATA_BINARY:=/usr/bin/suricata}"
    : "${DDOS_EVE_FRESHNESS_THRESHOLD:=60}"
    : "${DDOS_HYBRID_CLASSIC_LAYER0:=true}"
    : "${DDOS_NFT_TABLE_IPV4:=ip nftban}"
    : "${DDOS_NFT_TABLE_IPV6:=ip6 nftban}"
    : "${DDOS_NFT_CHAIN:=ddos_protection}"
}

# =============================================================================
# LOGGING
# =============================================================================

_nftban_ddos_log() {
    local level="$1"
    local message="$2"

    mkdir -p "$(dirname "$NFTBAN_DDOS_LOG_FILE")" 2>/dev/null || return 1

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DDOS] [$level] $message" >> "$NFTBAN_DDOS_LOG_FILE"
}

# =============================================================================
# BANNER
# =============================================================================

_nftban_ddos_banner() {
    if type -t nftban_banner >/dev/null 2>&1; then
        nftban_banner
    else
        echo "╔═══════════════════════════════════════════════════════════════════════════╗"
        echo "║  🛡️  DDoS Protection                                                      ║"
        echo "║  NFTBan — Open-source Linux IPS and nftables firewall manager            ║"
        echo "╚═══════════════════════════════════════════════════════════════════════════╝"
    fi
}

# =============================================================================
# MODE DETECTION
# =============================================================================

# Detect the best mode based on system state
_nftban_ddos_detect_mode() {
    local configured_mode="${DDOS_MODE:-auto}"

    # If mode is explicitly set (not auto), return it
    if [[ "$configured_mode" != "auto" ]]; then
        echo "$configured_mode"
        return 0
    fi

    # Auto-detection: check if Suricata is available
    if type -t nftban_ddos_suricata_is_available &>/dev/null; then
        if nftban_ddos_suricata_is_available; then
            echo "suricata"
            return 0
        fi
    fi

    # Fallback to classic
    echo "classic"
}

# Get current active mode
nftban_ddos_get_mode() {
    _nftban_ddos_load_config
    _nftban_ddos_detect_mode
}

# Check if Suricata is available (wrapper)
nftban_ddos_suricata_available() {
    _nftban_ddos_load_config

    if type -t nftban_ddos_suricata_is_available &>/dev/null; then
        nftban_ddos_suricata_is_available
        return $?
    fi

    return 1
}

# =============================================================================
# PUBLIC API - ENABLE
# =============================================================================

# -----------------------------------------------------------------------------
# nftban_ddos_reconcile -- THE TRANSACTION ROOT. v1.229.7 PR-3A.
#
# Resolves the module plan EXACTLY ONCE, then dispatches. Every root calls this:
# CLI enable/disable, daemon Start, firewall reload/rebuild. The adapters below
# are pure CONSUMERS and refuse to run without a supplied plan.
#
#   ONE operator intent · ONE mode resolution · ONE effective mode
#   ONE reconciliation path · ZERO cross-mode full-pipeline calls
#
# ⛔ inactive and unknown are DIFFERENT and must stay different:
#     inactive = a VALID resolved state   -> teardown higher tier, success
#     unknown  = an INVALID/unresolved contract state -> REFUSE ALL MUTATION
#   Letting teardown read unknown as inactive would turn malformed intent into
#   destructive cleanup. Base Layer-0 is unconditional either way.
# -----------------------------------------------------------------------------
nftban_ddos_reconcile() {
    local _plan
    # A root OPENS a transaction: clear any inherited plan first, so a nested
    # root cannot silently reuse an outer transaction's identity.
    unset NFTBAN_PLAN_TXN_ID NFTBAN_PLAN_RESOLUTION_ID NFTBAN_PLAN_MODULE
    _plan="$(nftban_module_resolve_plan ddos)" || return 1
    eval "$_plan"
    NFTBAN_PLAN_TXN_ID="$NFTBAN_PLAN_RESOLUTION_ID"
    export NFTBAN_PLAN_TXN_ID

    # Publish the plan as a TRANSIENT DERIVED OBSERVATION for cross-process
    # consumers (the Go validator cannot resolve `auto` and must not become a
    # second resolver). /run is tmpfiles-declared and does not survive reboot --
    # deliberately, because a resolution is valid for ONE transaction.
    # ⛔ DERIVED EVIDENCE, NOT DURABLE CONFIGURATION. MODE=auto stays the
    #    operator's intent; this record only says what it resolved to, and when.
    if [[ -d /run/nftban ]]; then
        local _pf="/run/nftban/module-plan-ddos.env" _tmp
        _tmp="${_pf}.$$"
        {
            printf 'NFTBAN_PLAN_MODULE=%s\n'           "$NFTBAN_PLAN_MODULE"
            printf 'NFTBAN_PLAN_ENABLED=%s\n'          "$NFTBAN_PLAN_ENABLED"
            printf 'NFTBAN_PLAN_CONFIGURED_MODE=%s\n'  "$NFTBAN_PLAN_CONFIGURED_MODE"
            printf 'NFTBAN_PLAN_EFFECTIVE_MODE=%s\n'   "$NFTBAN_PLAN_EFFECTIVE_MODE"
            printf 'NFTBAN_PLAN_RESOLUTION_ID=%s\n'    "$NFTBAN_PLAN_RESOLUTION_ID"
            printf 'NFTBAN_PLAN_RESOLVED_AT=%s\n'      "$NFTBAN_PLAN_RESOLVED_AT"
            printf 'NFTBAN_PLAN_RESOLUTION_BASIS=%s\n' "$NFTBAN_PLAN_RESOLUTION_BASIS"
        } > "$_tmp" 2>/dev/null && { chmod 0640 "$_tmp" 2>/dev/null || true; mv -f "$_tmp" "$_pf" 2>/dev/null || rm -f "$_tmp"; }
    fi
    export NFTBAN_PLAN_MODULE NFTBAN_PLAN_ENABLED NFTBAN_PLAN_CONFIGURED_MODE \
           NFTBAN_PLAN_EFFECTIVE_MODE NFTBAN_PLAN_RESOLUTION_ID \
           NFTBAN_PLAN_RESOLVED_AT NFTBAN_PLAN_RESOLUTION_BASIS

    case "$NFTBAN_PLAN_EFFECTIVE_MODE" in
        unknown)
            echo "  ERROR: effective mode is UNKNOWN (${NFTBAN_PLAN_RESOLUTION_BASIS:-no basis})." >&2
            echo "         Refusing ALL higher-tier DDoS mutation — apply AND teardown." >&2
            echo "         Base Layer-0 protection is unaffected." >&2
            return 1
            ;;
        inactive)
            nftban_ddos_teardown
            ;;
        classic|suricata)
            nftban_ddos_apply
            ;;
        *)
            echo "  ERROR: unhandled effective mode '${NFTBAN_PLAN_EFFECTIVE_MODE}'." >&2
            return 1
            ;;
    esac
}

nftban_ddos_apply() {
    _nftban_ddos_load_config
    _nftban_ddos_banner

    # Create log file if it doesn't exist
    if [[ ! -f "$NFTBAN_DDOS_LOG_FILE" ]]; then
        mkdir -p "$(dirname "$NFTBAN_DDOS_LOG_FILE")" 2>/dev/null || true
        touch "$NFTBAN_DDOS_LOG_FILE" 2>/dev/null || true
        chmod 640 "$NFTBAN_DDOS_LOG_FILE" 2>/dev/null || true
        chown nftban:nftban "$NFTBAN_DDOS_LOG_FILE" 2>/dev/null || true
    fi

    # Detect mode
    # v1.229.7 PR-3A: CONSUME THE PLAN. Do NOT rediscover the mode from disk.
    # A plan supplied by the caller (NFTBAN_PLAN_*) is the transaction's single
    # resolution; only when none is supplied is this the transaction boundary
    # and we resolve here, exactly once.
    #   ONE RESOLVER IMPLEMENTATION != ONE RESOLUTION PER TRANSACTION
    local mode
    if [[ "${NFTBAN_PLAN_MODULE:-}" == "ddos" && -n "${NFTBAN_PLAN_EFFECTIVE_MODE:-}" ]]; then
        # ⛔ PLAN-N2: the plan must belong to THIS transaction. Missing and mixed
        # provenance are different failures and both refuse.
        nftban_module_plan_provenance_ok ddos || {
            echo "  ERROR: plan provenance check failed — refusing to apply." >&2
            return 1
        }
        mode="$NFTBAN_PLAN_EFFECTIVE_MODE"
        _nftban_ddos_log "INFO" "consuming plan ${NFTBAN_PLAN_RESOLUTION_ID:-<no-id>} (${NFTBAN_PLAN_RESOLUTION_BASIS:-})"
    else
        # ⛔ NO PLAN AT A CONSUMER = CONTRACT FAILURE.
        # This deliberately does NOT fall back to resolving one. A downstream
        # helper that resolves "when convenient" is how "resolve once" degrades
        # back into "resolve wherever" -- and it would make PLAN-N1 bypassable,
        # because a forgotten plan parameter would silently mint a second
        # authority instead of failing.
        #   TRANSACTION ROOT   may resolve exactly once
        #   DOWNSTREAM CONSUMER must RECEIVE the plan
        echo "  ERROR: no resolved module plan supplied — refusing to apply." >&2
        echo "         Call nftban_ddos_reconcile (the transaction root) instead." >&2
        _nftban_ddos_log "ERROR" "refusing apply: no plan supplied (consumer must receive a plan)"
        return 1
    fi

    # ⛔ UNKNOWN stops the higher-tier transaction. It must NOT fall back to
    # classic or suricata, must NOT tear down as if disabled, and must NOT
    # fabricate a new plan. Base Layer-0 is unconditional, so this is
    # fail-closed at the HIGHER TIER, never a whole-firewall failure.
    if [[ "$mode" == "unknown" ]]; then
        echo "  ERROR: effective mode is UNKNOWN (${NFTBAN_PLAN_RESOLUTION_BASIS:-no basis}) — refusing to apply higher-tier DDoS." >&2
        echo "         Base Layer-0 protection is unaffected." >&2
        _nftban_ddos_log "ERROR" "refusing apply: effective_mode=unknown basis=${NFTBAN_PLAN_RESOLUTION_BASIS:-}"
        return 1
    fi
    # inactive = module disabled: no higher-tier apply, and not an error.
    if [[ "$mode" == "inactive" ]]; then
        _nftban_ddos_log "INFO" "module disabled — no higher-tier apply"
        return 0
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  DDoS Protection - Mode: ${mode^^}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    _nftban_ddos_log "INFO" "Enabling DDoS protection (mode=$mode)"

    # Step 1: Apply nftables rules FIRST (before persisting config)
    local enable_result=0
    case "$mode" in
        classic)
            echo ""
            echo "  Using CLASSIC mode (native nftables)"
            echo "  Suricata: NOT AVAILABLE"
            echo ""
            if type -t nftban_ddos_classic_enable &>/dev/null; then
                nftban_ddos_classic_enable || enable_result=$?
            else
                echo "  ERROR: Classic module not loaded!" >&2
                return 1
            fi
            ;;

        suricata)
            echo ""
            echo "  Using SURICATA mode (IDS-integrated)"
            if type -t nftban_ddos_suricata_get_status &>/dev/null; then
                echo "  Status: $(nftban_ddos_suricata_get_status)"
            fi
            echo ""
            if type -t nftban_ddos_suricata_enable &>/dev/null; then
                nftban_ddos_suricata_enable || enable_result=$?
            else
                echo "  ERROR: Suricata module not loaded!" >&2
                return 1
            fi
            ;;

        hybrid)
            echo ""
            echo "  Using HYBRID mode (Classic Layer 0 + Suricata Layer 1)"
            echo ""

            # Enable Classic as Layer 0
            echo "  [Layer 0] Classic (hard limits)..."
            if type -t nftban_ddos_classic_enable &>/dev/null; then
                nftban_ddos_classic_enable || enable_result=$?
            fi

            echo ""

            # Enable Suricata as Layer 1
            echo "  [Layer 1] Suricata (signature-based detection)..."
                # shellcheck disable=SC2034  # Reserved for dual-mode toggle
                DDOS_SURICATA_USE_CLASSIC_LAYER0="false"
                nftban_ddos_suricata_enable || enable_result=$?
            ;;

        *)
            echo "  ERROR: Unknown mode: $mode" >&2
            return 1
            ;;
    esac

    # Step 2: Verify nft rules were actually applied
    if [[ $enable_result -ne 0 ]]; then
        echo ""
        echo "  ❌ ERROR: Failed to apply nftables rules!" >&2
        echo "  Check: is nftband daemon running? (systemctl status nftband)" >&2
        _nftban_ddos_log "ERROR" "Failed to apply nftables rules (exit=$enable_result)"
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# nftban_ddos_enable -- OPERATOR ORCHESTRATION. CLI-ONLY.
# v1.229.7 PR-2: persists intent, calls the neutral apply, then performs the
# service lifecycle action. NOT daemon-callable.
# -----------------------------------------------------------------------------
nftban_ddos_enable() {
    _nftban_ddos_load_config
    nftban_ddos_reconcile || return 1

    # v1.229.7 PR-2a: `mode` is local to nftban_ddos_apply, so the success
    # banner below referenced an UNBOUND variable. Under `set -Eeuo pipefail`
    # (:41) that is fatal -- the command aborted AFTER persisting intent and
    # AFTER restarting nftband, returning non-zero to its caller.
    local mode
    mode="$(_nftban_ddos_detect_mode)"

    # Step 3: Persist DDOS_ENABLED=true ONLY after nft rules succeed.
    # v1.229.7 PR-2: routed through the SINGLE durable-intent writer.
    nftban_module_set_enabled ddos true || return 1
    DDOS_ENABLED="true"

    # Step 4: Auto-restart nftband to activate immediately
    if systemctl is-active nftband &>/dev/null; then
        echo "  Restarting nftband daemon..."
        if systemctl restart nftband 2>/dev/null; then
            echo "  ✅ Daemon restarted — DDoS protection is now active"
        else
            echo "  ⚠️  Daemon restart failed — run: systemctl restart nftband" >&2
        fi
    else
        echo "  ⚠️  nftband not running — start with: systemctl start nftband"
    fi

    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  ✅ DDoS Protection ENABLED (${mode^^})"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""

    return 0
}

# =============================================================================
# PUBLIC API - DISABLE
# =============================================================================

# -----------------------------------------------------------------------------
# nftban_ddos_teardown -- NEUTRAL RUNTIME TEARDOWN. Daemon-callable.
# v1.229.7 PR-2: removes runtime enforcement ONLY. Writes no config and
# restarts no service. Stopping a service must not turn a module off durably.
# -----------------------------------------------------------------------------
nftban_ddos_teardown() {
    _nftban_ddos_load_config
    _nftban_ddos_banner

    local mode
    mode=$(_nftban_ddos_detect_mode)

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Disabling DDoS Protection..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    _nftban_ddos_log "INFO" "Disabling DDoS protection"

    # Disable both modes to ensure clean state
    if type -t nftban_ddos_classic_disable &>/dev/null; then
        nftban_ddos_classic_disable 2>/dev/null || true
    fi

    if type -t nftban_ddos_suricata_disable &>/dev/null; then
        nftban_ddos_suricata_disable 2>/dev/null || true
    fi

    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  ✅ DDoS Protection DISABLED                             ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""

    return 0
}

# -----------------------------------------------------------------------------
# nftban_ddos_disable -- OPERATOR ORCHESTRATION. CLI-ONLY.
# v1.229.7 PR-2: persists intent, then tears down runtime. NOT daemon-callable.
# -----------------------------------------------------------------------------
nftban_ddos_disable() {
    _nftban_ddos_load_config
    nftban_module_set_enabled ddos false || return 1
    DDOS_ENABLED="false"
    nftban_ddos_reconcile
}

# =============================================================================
# PUBLIC API - STATUS
# =============================================================================

# v1.141 PR-B (J-DDOS) — JSON renderer for `nftban ddos status --json`.
# Built with jq -n (no string concatenation) so output is valid JSON even
# when any field carries quotes / unicode / shell-special chars. Fields
# match the text-mode status section labels exactly.
_nftban_ddos_status_json() {
    local mode="${1:-unknown}"
    local configured_mode="${2:-auto}"

    # Suricata sub-status — best-effort, never block JSON emission.
    local suricata_binary="unknown" suricata_service="unknown"
    local suricata_eve="unknown" suricata_available="unknown"
    local suricata_version=""
    if type -t nftban_ddos_suricata_binary_exists &>/dev/null; then
        if nftban_ddos_suricata_binary_exists; then
            suricata_binary="present"
            suricata_version=$(suricata -V 2>/dev/null | head -1 | grep -oP '\d+\.\d+\.\d+' || true)
        else
            suricata_binary="absent"
        fi
    fi
    if type -t nftban_ddos_suricata_service_running &>/dev/null; then
        if nftban_ddos_suricata_service_running; then suricata_service="running"; else suricata_service="stopped"; fi
    fi
    if type -t nftban_ddos_suricata_eve_active &>/dev/null; then
        if nftban_ddos_suricata_eve_active; then suricata_eve="active"; else suricata_eve="stale"; fi
    fi
    if type -t nftban_ddos_suricata_is_available &>/dev/null; then
        if nftban_ddos_suricata_is_available; then suricata_available="available"; else suricata_available="unavailable"; fi
    fi

    if command -v jq >/dev/null 2>&1; then
        jq -n \
            --arg enabled    "${DDOS_ENABLED:-false}" \
            --arg cfg_mode   "$configured_mode" \
            --arg act_mode   "$mode" \
            --arg s_bin      "$suricata_binary" \
            --arg s_ver      "$suricata_version" \
            --arg s_svc      "$suricata_service" \
            --arg s_eve      "$suricata_eve" \
            --arg s_avail    "$suricata_available" \
            '{
                module: "ddos",
                enabled: ($enabled == "true" or $enabled == "1"),
                configured_mode: $cfg_mode,
                active_mode: $act_mode,
                suricata: {
                    binary: $s_bin,
                    version: (if $s_ver == "" then null else $s_ver end),
                    service: $s_svc,
                    eve_log: $s_eve,
                    available: $s_avail
                }
            }'
        return $?
    fi
    # jq absent — emit a minimal hand-built object (still valid JSON; safe
    # because every value is a known constrained string from above).
    printf '{"module":"ddos","enabled":%s,"configured_mode":"%s","active_mode":"%s","suricata":{"binary":"%s","service":"%s","eve_log":"%s","available":"%s","jq_unavailable":true}}\n' \
        "$([[ "${DDOS_ENABLED:-false}" == "true" ]] && echo true || echo false)" \
        "$configured_mode" "$mode" "$suricata_binary" "$suricata_service" "$suricata_eve" "$suricata_available"
}

# v1.141 PR-B (J-DDOS): function now takes optional json_mode arg.
# shellcheck disable=SC2120
# (Internal callers may invoke without args; `${1:-false}` default handles
# that. SC2120 over-fires on optional args.)
nftban_ddos_status() {
    # v1.141 PR-B (J-DDOS): json_mode-aware status. When called with
    # json_mode="true", short-circuit ALL decorative chrome (banner +
    # ━━━ heading bars + text body) and emit a single valid JSON object
    # constructed via jq -n (no string concatenation). Pre-v1.141 this
    # function had no json_mode parameter; the dispatcher arm at
    # cmd_ddos.sh:384 called it bare, producing banner + text on
    # `nftban ddos status --json` (cruel-judge §3 E_J6).
    local json_mode="${1:-false}"

    _nftban_ddos_load_config

    local mode
    mode=$(_nftban_ddos_detect_mode)
    local configured_mode="${DDOS_MODE:-auto}"

    if [[ "$json_mode" == "true" ]]; then
        _nftban_ddos_status_json "$mode" "$configured_mode"
        return $?
    fi

    _nftban_ddos_banner

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  DDoS Protection Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Module Enabled:    ${DDOS_ENABLED}"
    echo "  Configured Mode:   ${configured_mode}"
    echo "  Active Mode:       ${mode}"
    echo ""

    # Suricata availability
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Suricata Detection"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if type -t nftban_ddos_suricata_binary_exists &>/dev/null; then
        if nftban_ddos_suricata_binary_exists; then
            local version
            version=$(suricata -V 2>/dev/null | head -1 | grep -oP '\d+\.\d+\.\d+' || echo "?")
            echo "  Binary:    ✅ FOUND (v$version)"
        else
            echo "  Binary:    ❌ NOT FOUND"
        fi
    else
        echo "  Binary:    ⚠️  Check unavailable"
    fi

    if type -t nftban_ddos_suricata_service_running &>/dev/null; then
        if nftban_ddos_suricata_service_running; then
            echo "  Service:   ✅ RUNNING"
        else
            echo "  Service:   ❌ STOPPED"
        fi
    else
        echo "  Service:   ⚠️  Check unavailable"
    fi

    if type -t nftban_ddos_suricata_eve_active &>/dev/null; then
        local eve_file="${DDOS_SURICATA_EVE_FILE:-/var/log/nftban/suricata/eve-alerts.json}"
        if [[ -f "$eve_file" ]]; then
            if nftban_ddos_suricata_eve_active; then
                local size
                size=$(du -h "$eve_file" 2>/dev/null | cut -f1)
                echo "  EVE Log:   ✅ ACTIVE ($size)"
            else
                echo "  EVE Log:   ⚠️  STALE (not updated recently)"
            fi
        else
            echo "  EVE Log:   ❌ NOT FOUND ($eve_file)"
        fi
    fi

    if type -t nftban_ddos_suricata_is_available &>/dev/null; then
        echo ""
        if nftban_ddos_suricata_is_available; then
            echo "  Suricata:  ✅ AVAILABLE (ready for use)"
        else
            echo "  Suricata:  ❌ NOT AVAILABLE"
            # Explain WHY it's not available (same pattern as portscan)
            if ! type -t nftban_ddos_suricata_binary_exists &>/dev/null || ! nftban_ddos_suricata_binary_exists; then
                echo "  Reason:    Binary not installed"
                echo "  Fix:       apt install suricata / dnf install suricata"
            elif ! type -t nftban_ddos_suricata_service_running &>/dev/null || ! nftban_ddos_suricata_service_running; then
                echo "  Reason:    Service not running"
                echo "  Fix:       systemctl start suricata"
            else
                # Binary + service OK → EVE log must be the issue
                # Support Suricata 7.x threaded logging: check all eve-alerts*.json files
                local diag_eve_dir="${NFTBAN_LOG_DIR:-/var/log/nftban}/suricata"
                local diag_freshest_mtime=0

                shopt -s nullglob
                for f in "$diag_eve_dir"/eve-alerts*.json; do
                    [[ -f "$f" ]] || continue
                    local m
                    m=$(stat -L -c %Y -- "$f" 2>/dev/null) || continue
                    [[ "$m" =~ ^[0-9]+$ ]] || continue
                    (( m > diag_freshest_mtime )) && diag_freshest_mtime=$m
                done
                shopt -u nullglob

                if [[ $diag_freshest_mtime -eq 0 ]]; then
                    echo "  Reason:    EVE log not found in $diag_eve_dir"
                    echo "  Fix:       Check Suricata output config (suricata.yaml)"
                else
                    local diag_age=$(( $(date +%s) - diag_freshest_mtime ))
                    echo "  Reason:    EVE log stale (last update ${diag_age}s ago, threshold: ${DDOS_EVE_FRESHNESS_THRESHOLD:-60}s)"
                    echo "  Fix:       Check Suricata is processing traffic: suricata --build-info"
                    echo "             Verify EVE output: grep eve-log /etc/suricata/suricata.yaml"
                fi
            fi
        fi
    fi

    echo ""

    # Show mode-specific status
    case "$mode" in
        classic)
            if type -t nftban_ddos_classic_status &>/dev/null; then
                nftban_ddos_classic_status
            fi
            ;;
        suricata|hybrid)
            if type -t nftban_ddos_suricata_status &>/dev/null; then
                nftban_ddos_suricata_status
            fi
            ;;
    esac

    # ==========================================================================
    # DETECTION MODES EXPLAINED
    # ==========================================================================
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Detection Modes"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  classic   - Uses nftables rate limiting and connection tracking"
    echo "              Good for basic protection without external dependencies"
    echo ""
    echo "  suricata  - Uses Suricata IDS for advanced threat detection"
    echo "              Better accuracy, detects complex attack patterns"
    echo ""
    echo "  hybrid    - Combines both classic and Suricata detection"
    echo "              Maximum protection with redundant detection layers"
    echo ""
    echo "  auto      - Auto-selects based on Suricata availability"
    echo "              Uses suricata if available, otherwise classic"
    echo ""

    # ==========================================================================
    # CONFIGURATION
    # ==========================================================================
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Configuration"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Config File:  /etc/nftban/conf.d/ddos/main.conf"
    local local_file="/etc/nftban/conf.d/ddos/main.conf.local"
    if [[ -f "$local_file" ]]; then
        echo "  Override File:  $local_file  [Active]"
    else
        echo "  Override File:  $local_file  [Not created]"
    fi
    echo "  Log File:     ${NFTBAN_DDOS_LOG_FILE}"
    echo ""
    echo "  Key Settings:"
    echo "    DDOS_ENABLED=true|false     - Enable/disable DDoS protection"
    echo "    DDOS_MODE=auto|classic|suricata|hybrid"
    echo "    DDOS_SYN_RATE=25            - SYN packets per second limit"
    echo "    DDOS_CONN_LIMIT=100         - Max connections per IP"
    echo ""
    echo "  Note: Put custom settings in main.conf.local (survives upgrades)"
    echo ""

    # ==========================================================================
    # COMMANDS
    # ==========================================================================
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Commands"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  nftban ddos enable            - Enable DDoS protection"
    echo "  nftban ddos disable           - Disable DDoS protection"
    echo "  nftban ddos test              - Test protection rules"
    echo "  nftban ddos help              - Show all available commands"
    echo ""

    return 0
}

# =============================================================================
# PUBLIC API - TEST (For scripting/automation)
# =============================================================================

nftban_ddos_test() {
    _nftban_ddos_load_config

    local mode
    mode=$(_nftban_ddos_detect_mode)

    echo "mode=$mode"
    echo "enabled=$DDOS_ENABLED"
    echo "configured_mode=$DDOS_MODE"

    if type -t nftban_ddos_suricata_is_available &>/dev/null; then
        if nftban_ddos_suricata_is_available; then
            echo "suricata_available=true"
        else
            echo "suricata_available=false"
        fi
    else
        echo "suricata_available=unknown"
    fi

    return 0
}

# =============================================================================
# CLI DISPATCHER (for direct script execution)
# =============================================================================

_nftban_ddos_cli() {
    local cmd="${1:-status}"
    shift || true

    case "$cmd" in
        enable)
            nftban_ddos_enable "$@"
            ;;
        disable)
            nftban_ddos_disable "$@"
            ;;
        status)
            nftban_ddos_status "$@"
            ;;
        test)
            nftban_ddos_test "$@"
            ;;
        mode)
            nftban_ddos_get_mode
            ;;
        help|--help|-h)
            echo "Usage: nftban ddos <command>"
            echo ""
            echo "Commands:"
            echo "  enable     Enable DDoS protection (auto-detects mode)"
            echo "  disable    Disable DDoS protection"
            echo "  status     Show current status"
            echo "  mode       Show active mode (classic/suricata/hybrid)"
            echo "  test       Output status in key=value format"
            echo ""
            echo "Modes:"
            echo "  auto       Auto-detect (use Suricata if available, else Classic)"
            echo "  classic    Force Classic mode (nftables-only)"
            echo "  suricata   Force Suricata mode (requires Suricata)"
            echo "  hybrid     Both: Classic Layer 0 + Suricata Layer 1"
            echo ""
            echo "Configuration:"
            echo "  ${NFTBAN_DDOS_CONFIG_DIR}/conf.d/ddos/main.conf"
            echo "  ${NFTBAN_DDOS_CONFIG_DIR}/conf.d/ddos/classic.conf"
            echo "  ${NFTBAN_DDOS_CONFIG_DIR}/conf.d/ddos/suricata.conf"
            echo ""
            ;;
        *)
            echo "Unknown command: $cmd"
            echo "Run 'nftban ddos help' for usage"
            return 1
            ;;
    esac
}

# Run CLI if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    _nftban_ddos_cli "$@"
fi

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_ddos_enable
export -f nftban_ddos_disable
export -f nftban_ddos_status
export -f nftban_ddos_test
export -f nftban_ddos_get_mode
export -f nftban_ddos_suricata_available
