#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0 - DDoS Protection Module - MAIN CONTROLLER
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Dual-mode DDoS protection with auto-detection
#
# meta:name="nftban_ddos"
# meta:type="core"
# meta:header="DDoS Protection"
# meta:version="1.0.0"
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
        source "$main_local" || true
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

nftban_ddos_enable() {
    _nftban_ddos_load_config
    _nftban_ddos_banner

    # Create log file if it doesn't exist
    if [[ ! -f "$NFTBAN_DDOS_LOG_FILE" ]]; then
        mkdir -p "$(dirname "$NFTBAN_DDOS_LOG_FILE")" 2>/dev/null || true
        touch "$NFTBAN_DDOS_LOG_FILE" 2>/dev/null || true
        chmod 640 "$NFTBAN_DDOS_LOG_FILE" 2>/dev/null || true
        chown nftban:nftban "$NFTBAN_DDOS_LOG_FILE" 2>/dev/null || true
    fi

    # Persist DDOS_ENABLED=true to local config override
    local local_conf="${NFTBAN_DDOS_CONFIG_DIR}/conf.d/ddos/main.conf.local"
    mkdir -p "$(dirname "$local_conf")" || return 1
    if grep -q "^DDOS_ENABLED=" "$local_conf" 2>/dev/null; then
        sed -i 's/^DDOS_ENABLED=.*/DDOS_ENABLED="true"/' "$local_conf"
    else
        echo 'DDOS_ENABLED="true"' >> "$local_conf"
    fi
    DDOS_ENABLED="true"

    # Detect mode
    local mode
    mode=$(_nftban_ddos_detect_mode)

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  DDoS Protection - Mode: ${mode^^}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    _nftban_ddos_log "INFO" "Enabling DDoS protection (mode=$mode)"

    case "$mode" in
        classic)
            echo ""
            echo "  Using CLASSIC mode (native nftables)"
            echo "  Suricata: NOT AVAILABLE"
            echo ""
            if type -t nftban_ddos_classic_enable &>/dev/null; then
                nftban_ddos_classic_enable
            else
                echo "  ERROR: Classic module not loaded!"
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
                nftban_ddos_suricata_enable
            else
                echo "  ERROR: Suricata module not loaded!"
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
                nftban_ddos_classic_enable
            fi

            echo ""

            # Enable Suricata as Layer 1
            echo "  [Layer 1] Suricata (intelligent detection)..."
                # shellcheck disable=SC2034  # Reserved for dual-mode toggle
                DDOS_SURICATA_USE_CLASSIC_LAYER0="false"
                nftban_ddos_suricata_enable
            ;;

        *)
            echo "  ERROR: Unknown mode: $mode"
            return 1
            ;;
    esac

    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  ✅ DDoS Protection ENABLED (${mode^^})                   "
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""

    return 0
}

# =============================================================================
# PUBLIC API - DISABLE
# =============================================================================

nftban_ddos_disable() {
    _nftban_ddos_load_config
    _nftban_ddos_banner

    # Persist DDOS_ENABLED=false to local config override
    local local_conf="${NFTBAN_DDOS_CONFIG_DIR}/conf.d/ddos/main.conf.local"
    mkdir -p "$(dirname "$local_conf")" || return 1
    if grep -q "^DDOS_ENABLED=" "$local_conf" 2>/dev/null; then
        sed -i 's/^DDOS_ENABLED=.*/DDOS_ENABLED="false"/' "$local_conf"
    else
        echo 'DDOS_ENABLED="false"' >> "$local_conf"
    fi
    DDOS_ENABLED="false"

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

# =============================================================================
# PUBLIC API - STATUS
# =============================================================================

nftban_ddos_status() {
    _nftban_ddos_load_config
    _nftban_ddos_banner

    local mode
    mode=$(_nftban_ddos_detect_mode)
    local configured_mode="${DDOS_MODE:-auto}"

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
