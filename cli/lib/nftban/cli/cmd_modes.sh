#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.7.0 - Detection Modes Overview CLI Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Unified overview of detection modes across all protection modules
#
# meta:name="cmd_modes"
# meta:type="cli"
# meta:header="Detection Modes Overview"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Display unified overview of detection modes for all protection modules"
# meta:input="None (reads configuration files)"
# meta:output="Formatted table showing configured vs effective modes"
#
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/conf.d/portscan/main.conf,/etc/nftban/conf.d/ddos/main.conf,/etc/nftban/conf.d/login/main.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# meta:created_date="2026-02-02"
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${NFTBAN_CMD_MODES_LOADED:-}" ]] && return 0
NFTBAN_CMD_MODES_LOADED="true"

# =============================================================================
# CONFIGURATION
# =============================================================================

: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"
: "${NFTBAN_CONFIG_DIR:=/etc/nftban}"

# EVE file path (shared across modules)
: "${SURICATA_EVE_FILE:=${NFTBAN_LOG_DIR:-/var/log/nftban}/suricata/eve-alerts.json}"

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Check if Suricata service is running
_modes_suricata_is_running() {
    systemctl is-active --quiet suricata.service 2>/dev/null || \
    systemctl is-active --quiet nftban-suricata.service 2>/dev/null
}

# Check EVE file freshness, returns seconds since last modification
# Returns empty string if file doesn't exist
_modes_eve_freshness() {
    local eve_file="${SURICATA_EVE_FILE}"
    
    # Check module-specific EVE paths first
    for module_eve in \
        "${PORTSCAN_SURICATA_EVE_FILE:-}" \
        "${DDOS_SURICATA_EVE_FILE:-}" \
        "${LOGIN_SURICATA_EVE_FILE:-}"; do
        if [[ -n "$module_eve" && -f "$module_eve" ]]; then
            eve_file="$module_eve"
            break
        fi
    done
    
    # Fallback to default
    if [[ ! -f "$eve_file" ]]; then
        eve_file="${NFTBAN_LOG_DIR:-/var/log/nftban}/suricata/eve-alerts.json"
    fi
    
    if [[ ! -f "$eve_file" ]]; then
        echo ""
        return 1
    fi
    
    local mtime now age
    # Use -L to follow symlinks (eve-alerts.json -> eve.json)
    mtime=$(stat -L -c %Y "$eve_file" 2>/dev/null) || return 1
    now=$(date +%s)
    age=$((now - mtime))
    echo "$age"
}

# Format age in human-readable format
_modes_format_age() {
    local seconds="$1"
    
    if [[ -z "$seconds" || "$seconds" -lt 0 ]]; then
        echo "N/A"
        return
    fi
    
    if [[ $seconds -lt 60 ]]; then
        echo "${seconds}s ago"
    elif [[ $seconds -lt 3600 ]]; then
        local mins=$((seconds / 60))
        echo "${mins}m ago"
    elif [[ $seconds -lt 86400 ]]; then
        local hours=$((seconds / 3600))
        echo "${hours}h ago"
    else
        local days=$((seconds / 86400))
        echo "${days}d ago"
    fi
}

# Read mode from config file
# Args: $1 = variable name, $2 = config file path
_modes_read_config() {
    local var_name="$1"
    local config_file="$2"
    local value=""
    
    if [[ -f "$config_file" ]]; then
        # Read from config file, handling .local override
        value=$(grep -E "^${var_name}=" "$config_file" 2>/dev/null | tail -1 | cut -d'"' -f2)
        
        # Check for .local override
        local local_file="${config_file}.local"
        if [[ -f "$local_file" ]]; then
            local local_value
            local_value=$(grep -E "^${var_name}=" "$local_file" 2>/dev/null | tail -1 | cut -d'"' -f2)
            [[ -n "$local_value" ]] && value="$local_value"
        fi
    fi
    
    echo "${value:-auto}"
}

# Resolve effective mode based on config and Suricata availability
# Args: $1 = configured mode, $2 = suricata_running (true/false)
_modes_resolve_effective() {
    local config_mode="$1"
    local suricata_running="$2"
    
    case "$config_mode" in
        auto)
            if [[ "$suricata_running" == "true" ]]; then
                echo "suricata"
            else
                echo "classic"
            fi
            ;;
        classic|suricata|hybrid)
            echo "$config_mode"
            ;;
        *)
            echo "classic"
            ;;
    esac
}

# Get reason for effective mode
# Args: $1 = configured mode, $2 = effective mode, $3 = suricata_running
_modes_get_reason() {
    local config_mode="$1"
    local effective_mode="$2"
    local suricata_running="$3"
    
    if [[ "$config_mode" == "auto" ]]; then
        if [[ "$suricata_running" == "true" ]]; then
            echo "Suricata detected"
        else
            echo "No Suricata config"
        fi
    elif [[ "$config_mode" == "$effective_mode" ]]; then
        echo "Manually configured"
    else
        echo "Forced mode"
    fi
}

# =============================================================================
# MAIN COMMAND
# =============================================================================

nftban_cmd_modes() {
    local subcmd="${1:-}"
    
    case "$subcmd" in
        help|--help|-h)
            _modes_help
            return 0
            ;;
        --json)
            _modes_json
            return $?
            ;;
        "")
            _modes_overview
            return $?
            ;;
        *)
            echo "ERROR: Unknown subcommand '$subcmd'" >&2
            echo "Run 'nftban modes help' for usage" >&2
            return 1
            ;;
    esac
}

# =============================================================================
# COMMAND: overview (default)
# =============================================================================

_modes_overview() {
    # Check Suricata status
    local suricata_running="false"
    if _modes_suricata_is_running; then
        suricata_running="true"
    fi
    
    # Check EVE file
    local eve_age eve_status
    eve_age=$(_modes_eve_freshness) || true
    if [[ -n "$eve_age" ]]; then
        if [[ $eve_age -lt 60 ]]; then
            eve_status="OK ($(_modes_format_age "$eve_age"))"
        elif [[ $eve_age -lt 300 ]]; then
            eve_status="STALE ($(_modes_format_age "$eve_age"))"
        else
            eve_status="OLD ($(_modes_format_age "$eve_age"))"
        fi
    else
        eve_status="NOT FOUND"
    fi
    
    # Suricata status string
    local suricata_status_str
    if [[ "$suricata_running" == "true" ]]; then
        suricata_status_str="RUNNING"
    else
        suricata_status_str="STOPPED"
    fi
    
    # Read module configurations
    local portscan_config ddos_config login_config
    portscan_config=$(_modes_read_config "PORTSCAN_MODE" "${NFTBAN_CONFIG_DIR}/conf.d/portscan/main.conf")
    ddos_config=$(_modes_read_config "DDOS_MODE" "${NFTBAN_CONFIG_DIR}/conf.d/ddos/main.conf")
    login_config=$(_modes_read_config "LOGIN_MODE" "${NFTBAN_CONFIG_DIR}/conf.d/login/main.conf")
    
    # Calculate effective modes
    local portscan_effective ddos_effective login_effective
    portscan_effective=$(_modes_resolve_effective "$portscan_config" "$suricata_running")
    ddos_effective=$(_modes_resolve_effective "$ddos_config" "$suricata_running")
    login_effective=$(_modes_resolve_effective "$login_config" "$suricata_running")
    
    # Get reasons
    local portscan_reason ddos_reason login_reason
    portscan_reason=$(_modes_get_reason "$portscan_config" "$portscan_effective" "$suricata_running")
    ddos_reason=$(_modes_get_reason "$ddos_config" "$ddos_effective" "$suricata_running")
    login_reason=$(_modes_get_reason "$login_config" "$login_effective" "$suricata_running")
    
    # Print formatted output
    echo ""
    echo "NFTBan Detection Modes Overview"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "%-11s  %-8s  %-10s  %-20s\n" "Module" "Config" "Effective" "Reason"
    echo "──────────  ────────  ──────────  ────────────────────"
    printf "%-11s  %-8s  %-10s  %-20s\n" "Portscan" "$portscan_config" "$portscan_effective" "$portscan_reason"
    printf "%-11s  %-8s  %-10s  %-20s\n" "DDoS" "$ddos_config" "$ddos_effective" "$ddos_reason"
    printf "%-11s  %-8s  %-10s  %-20s\n" "Login" "$login_config" "$login_effective" "$login_reason"
    echo ""
    echo "Suricata: ${suricata_status_str} | EVE: ${eve_status}"
    echo ""
    echo "To change modes:"
    echo "  nftban portscan mode set <auto|classic|suricata|hybrid>"
    echo "  nftban ddos mode set <auto|classic|suricata|hybrid>"
    echo ""
}

# =============================================================================
# COMMAND: --json
# =============================================================================

_modes_json() {
    # Check Suricata status
    local suricata_running="false"
    if _modes_suricata_is_running; then
        suricata_running="true"
    fi
    
    # Check EVE file
    local eve_age eve_status eve_ok="false"
    eve_age=$(_modes_eve_freshness) || true
    if [[ -n "$eve_age" ]]; then
        if [[ $eve_age -lt 60 ]]; then
            eve_status="ok"
            eve_ok="true"
        elif [[ $eve_age -lt 300 ]]; then
            eve_status="stale"
        else
            eve_status="old"
        fi
    else
        eve_status="not_found"
        eve_age="null"
    fi
    
    # Read module configurations
    local portscan_config ddos_config login_config
    portscan_config=$(_modes_read_config "PORTSCAN_MODE" "${NFTBAN_CONFIG_DIR}/conf.d/portscan/main.conf")
    ddos_config=$(_modes_read_config "DDOS_MODE" "${NFTBAN_CONFIG_DIR}/conf.d/ddos/main.conf")
    login_config=$(_modes_read_config "LOGIN_MODE" "${NFTBAN_CONFIG_DIR}/conf.d/login/main.conf")
    
    # Calculate effective modes
    local portscan_effective ddos_effective login_effective
    portscan_effective=$(_modes_resolve_effective "$portscan_config" "$suricata_running")
    ddos_effective=$(_modes_resolve_effective "$ddos_config" "$suricata_running")
    login_effective=$(_modes_resolve_effective "$login_config" "$suricata_running")
    
    # Get reasons
    local portscan_reason ddos_reason login_reason
    portscan_reason=$(_modes_get_reason "$portscan_config" "$portscan_effective" "$suricata_running")
    ddos_reason=$(_modes_get_reason "$ddos_config" "$ddos_effective" "$suricata_running")
    login_reason=$(_modes_get_reason "$login_config" "$login_effective" "$suricata_running")
    
    # Output JSON
    printf '{\n'
    printf '  "modules": {\n'
    printf '    "portscan": {\n'
    printf '      "config": "%s",\n' "$portscan_config"
    printf '      "effective": "%s",\n' "$portscan_effective"
    printf '      "reason": "%s"\n' "$portscan_reason"
    printf '    },\n'
    printf '    "ddos": {\n'
    printf '      "config": "%s",\n' "$ddos_config"
    printf '      "effective": "%s",\n' "$ddos_effective"
    printf '      "reason": "%s"\n' "$ddos_reason"
    printf '    },\n'
    printf '    "login": {\n'
    printf '      "config": "%s",\n' "$login_config"
    printf '      "effective": "%s",\n' "$login_effective"
    printf '      "reason": "%s"\n' "$login_reason"
    printf '    }\n'
    printf '  },\n'
    printf '  "suricata": {\n'
    printf '    "running": %s,\n' "$suricata_running"
    printf '    "eve": {\n'
    printf '      "status": "%s",\n' "$eve_status"
    printf '      "age_seconds": %s,\n' "$eve_age"
    printf '      "ok": %s\n' "$eve_ok"
    printf '    }\n'
    printf '  }\n'
    printf '}\n'
}

# =============================================================================
# COMMAND: help
# =============================================================================

_modes_help() {
    echo ""
    echo "NFTBan Detection Modes Overview"
    echo ""
    echo "USAGE:"
    echo "    nftban modes [options]"
    echo ""
    echo "OPTIONS:"
    echo "    --json      Output in JSON format (for scripts/GUI)"
    echo "    help        Show this help message"
    echo ""
    echo "DESCRIPTION:"
    echo "    Shows a unified view of detection modes across all protection modules"
    echo "    (Portscan, DDoS, Login). Each module can operate in different modes:"
    echo ""
    echo "    auto      - Automatically choose based on Suricata availability"
    echo "    classic   - Traditional log-based detection (no IDS)"
    echo "    suricata  - Use Suricata IDS for signature-based detection"
    echo "    hybrid    - Use both classic and Suricata together"
    echo ""
    echo "    The \"Effective\" column shows what mode is actually being used after"
    echo "    auto-detection resolves. The \"Reason\" column explains why."
    echo ""
    echo "OUTPUT COLUMNS:"
    echo "    Module      Protection module name"
    echo "    Config      Configured mode (from conf.d/<module>/main.conf)"
    echo "    Effective   Actual mode in use after auto-detection"
    echo "    Reason      Why this effective mode was chosen"
    echo ""
    echo "EXAMPLES:"
    echo "    nftban modes              # Show detection modes overview"
    echo "    nftban modes --json       # JSON output for scripts"
    echo ""
    echo "SEE ALSO:"
    echo "    nftban portscan status    # Detailed portscan module status"
    echo "    nftban ddos status        # Detailed DDoS module status"
    echo "    nftban login status       # Detailed login monitor status"
    echo "    nftban suricata status    # Suricata IDS status"
    echo ""
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_cmd_modes
export -f _modes_help

# =============================================================================
# AUTO-EXECUTE
# =============================================================================

# If script is sourced, export the main function
# If executed directly, run with args
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_modes "$@"
fi
