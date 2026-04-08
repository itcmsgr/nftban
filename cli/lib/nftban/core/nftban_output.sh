#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Output & Banner Core Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Standardized output, banners, and formatting for all modules
#
# meta:name="nftban_output"
# meta:type="core"
# meta:header="Output & Banner Module"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# **Description & Purpose**
# meta:description="Core output module providing banners, formatting, and module load messages"
# meta:input="Configuration from conf.d/banner.conf, module meta fields"
# meta:output="Formatted banners, module load messages, error messages"
#
# **Inventory & Requirements**
# meta:depends="bash"
# meta:inventory.files=""
# meta:inventory.binaries="tput,uname,hostname"
# meta:inventory.env_vars="NFTBAN_BANNER_MODE,NFTBAN_COLOR,NFTBAN_CACHE_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="nftban"
#
# meta:created_date="2025-11-05"
# meta:updated_date="2026-01-13"

set -Eeuo pipefail


# =============================================================================
# PREVENT DOUBLE-LOADING
# =============================================================================
[[ -n "${NFTBAN_OUTPUT_LOADED:-}" ]] && return 0
NFTBAN_OUTPUT_LOADED="true"

# =============================================================================
# LOAD CENTRAL ENVIRONMENT (ensures vars are set for strict mode)
# =============================================================================
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/env.sh" || return 1

# =============================================================================
# GLOBAL VARIABLES
# =============================================================================

# Terminal detection
NFTBAN_TTY="${NFTBAN_TTY:-$([ -t 1 ] && echo "true" || echo "false")}"

# Terminal width
if [[ "${NFTBAN_WIDTH:-auto}" == "auto" ]]; then
    NFTBAN_WIDTH="$(tput cols 2>/dev/null || echo 80)"
    [[ $NFTBAN_WIDTH -lt 60 ]] && NFTBAN_WIDTH=60
    [[ $NFTBAN_WIDTH -gt 120 ]] && NFTBAN_WIDTH=120
fi

# Color support (respects NO_COLOR standard)
if [[ "${NFTBAN_COLOR:-auto}" == "auto" ]]; then
    NFTBAN_COLOR="$NFTBAN_TTY"
fi
[[ -n "${NO_COLOR:-}" ]] && NFTBAN_COLOR="false"

# Emoji/Unicode support
if [[ "${NFTBAN_BANNER_EMOJI:-auto}" == "auto" ]]; then
    case "${LC_ALL:-}${LC_CTYPE:-}${LANG:-}" in
        *UTF-8*|*utf8*) NFTBAN_BANNER_EMOJI="yes" ;;
        *) NFTBAN_BANNER_EMOJI="no" ;;
    esac
fi

# Auto-escalate settings in DEBUG mode
if [[ "${NFTBAN_DEBUG_MODE:-false}" == "true" ]]; then
    # When debugging, show everything
    [[ "${NFTBAN_BANNER_MODE:-auto}" == "auto" ]] && NFTBAN_BANNER_MODE="full"
    [[ "${NFTBAN_MODULE_LOAD_LEVEL:-auto}" == "auto" ]] && NFTBAN_MODULE_LOAD_LEVEL="debug"
    [[ "${NFTBAN_SHOW_CONFIG_SOURCE:-auto}" == "auto" ]] && NFTBAN_SHOW_CONFIG_SOURCE="true"
    [[ "${NFTBAN_SHOW_LOAD_TIMING:-auto}" == "auto" ]] && NFTBAN_SHOW_LOAD_TIMING="true"
    [[ "${NFTBAN_SHOW_DEPENDENCIES:-auto}" == "auto" ]] && NFTBAN_SHOW_DEPENDENCIES="true"
    [[ "${NFTBAN_SHOW_ENVIRONMENT:-auto}" == "auto" ]] && NFTBAN_SHOW_ENVIRONMENT="true"
    [[ "${NFTBAN_SHOW_LOG_PATHS:-auto}" == "auto" ]] && NFTBAN_SHOW_LOG_PATHS="true"
else
    # Normal mode: disable auto settings
    [[ "${NFTBAN_SHOW_CONFIG_SOURCE:-auto}" == "auto" ]] && NFTBAN_SHOW_CONFIG_SOURCE="false"
    [[ "${NFTBAN_SHOW_LOAD_TIMING:-auto}" == "auto" ]] && NFTBAN_SHOW_LOAD_TIMING="false"
    [[ "${NFTBAN_SHOW_DEPENDENCIES:-auto}" == "auto" ]] && NFTBAN_SHOW_DEPENDENCIES="false"
    [[ "${NFTBAN_SHOW_ENVIRONMENT:-auto}" == "auto" ]] && NFTBAN_SHOW_ENVIRONMENT="false"
    [[ "${NFTBAN_SHOW_LOG_PATHS:-auto}" == "auto" ]] && NFTBAN_SHOW_LOG_PATHS="false"
    [[ "${NFTBAN_MODULE_LOAD_LEVEL:-auto}" == "auto" ]] && NFTBAN_MODULE_LOAD_LEVEL="info"
fi

# Color codes (if enabled)
if [[ "$NFTBAN_COLOR" == "true" ]]; then
    NFTBAN_COLOR_RESET='\033[0m'
    NFTBAN_COLOR_BOLD='\033[1m'
    NFTBAN_COLOR_DIM='\033[2m'
    NFTBAN_COLOR_RED='\033[31m'
    NFTBAN_COLOR_GREEN='\033[32m'  # Reserved for future use
    NFTBAN_COLOR_YELLOW='\033[33m'
    NFTBAN_COLOR_BLUE='\033[34m'   # Reserved for future use
    NFTBAN_COLOR_CYAN='\033[36m'
    NFTBAN_COLOR_WHITE='\033[37m'  # Reserved for future use
    NFTBAN_COLOR_GRAY='\033[90m'
    NFTBAN_COLOR_BRIGHT_WHITE='\033[37;1m'
else
    NFTBAN_COLOR_RESET=''
    NFTBAN_COLOR_BOLD=''
    NFTBAN_COLOR_DIM=''
    NFTBAN_COLOR_RED=''
    NFTBAN_COLOR_GREEN=''  # Reserved for future use
    NFTBAN_COLOR_YELLOW=''
    NFTBAN_COLOR_BLUE=''   # Reserved for future use
    NFTBAN_COLOR_CYAN=''
    NFTBAN_COLOR_WHITE=''  # Reserved for future use
    NFTBAN_COLOR_GRAY=''
    NFTBAN_COLOR_BRIGHT_WHITE=''
fi

# Export color codes for use by other modules
export NFTBAN_COLOR_RESET NFTBAN_COLOR_BOLD NFTBAN_COLOR_DIM
export NFTBAN_COLOR_RED NFTBAN_COLOR_GREEN NFTBAN_COLOR_YELLOW
export NFTBAN_COLOR_BLUE NFTBAN_COLOR_CYAN NFTBAN_COLOR_WHITE
export NFTBAN_COLOR_GRAY NFTBAN_COLOR_BRIGHT_WHITE

# Module load tracking (for timing and order)
# shellcheck disable=SC2034  # Used by verbose output in nftban_module_loaded_verbose()
declare -g -A NFTBAN_MODULE_LOAD_TIMES=()
declare -g -a NFTBAN_MODULE_LOAD_ORDER=()
declare -g NFTBAN_MODULE_LOAD_START="${EPOCHREALTIME:-$(date +%s.%N)}"

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Strip ANSI color codes from text
nftban_strip_ansi() {
    sed -r 's/\x1B\[[0-9;]*[A-Za-z]//g'
}

# Center text in terminal
nftban_center_text() {
    local text="$1"
    local width="${2:-$NFTBAN_WIDTH}"

    # Strip ANSI codes for length calculation
    local raw_text
    raw_text="$(echo -e "$text" | nftban_strip_ansi)"

    local len=${#raw_text}

    if [[ $len -ge $width ]]; then
        echo -e "$text"
        return
    fi

    local pad
    pad=$(( (width - len) / 2 ))
    printf "%*s%b%*s\n" "$pad" "" "$text" $(( width - len - pad )) ""
}

# Repeat character
nftban_repeat_char() {
    local count="$1"
    local char="${2:- }"
    printf "%*s" "$count" "" | tr ' ' "$char"
}

# Get hostname
nftban_get_hostname() {
    hostname -s 2>/dev/null || uname -n
}

# Get kernel version
nftban_get_kernel() {
    uname -r
}

# Get nftban version
nftban_get_version() {
    if [[ -n "${NFTBAN_VERSION:-}" ]]; then
        echo "$NFTBAN_VERSION"
    elif [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/version.sh" ]]; then
        # Load version.sh (single source of truth)
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/version.sh" 2>/dev/null || true
        echo "${NFTBAN_VERSION:-unknown}"
    elif command -v nftban >/dev/null 2>&1; then
        nftban --version 2>/dev/null | sed -n 's/.*\([0-9]\+\.[0-9]\+\.[0-9]\+\).*/\1/p' || echo "unknown"
    else
        echo "unknown"
    fi
}

# Icon pair (emoji or ASCII)
nftban_icon_pair() {
    if [[ "$NFTBAN_BANNER_EMOJI" == "yes" ]]; then
        echo "🐧🛡️"
    else
        echo "[penguin][shield]"
    fi
}

# Get elapsed time since start
# shellcheck disable=SC2120  # Argument is optional, defaults to NFTBAN_MODULE_LOAD_START
nftban_get_elapsed() {
    local start="${1:-$NFTBAN_MODULE_LOAD_START}"
    local now="${EPOCHREALTIME:-$(date +%s.%N)}"
    echo "$now - $start" | bc -l 2>/dev/null | awk '{printf "%.3f", $0}' || echo "0.000"
}

# =============================================================================
# BANNER FUNCTIONS
# =============================================================================

# Main banner render function
nftban_render_banner() {
    local mode="${1:-${NFTBAN_BANNER_MODE:-full}}"

    # Auto-detect mode
    if [[ "$mode" == "auto" ]]; then
        if [[ "$NFTBAN_TTY" == "true" ]]; then
            mode="full"
        else
            mode="minimal"
        fi
    fi

    # Check if banner suppressed for specific command
    local cmd="${2:-}"
    if [[ -n "$cmd" ]] && [[ "${NFTBAN_SUPPRESS_BANNER_FOR:-}" == *"$cmd"* ]]; then
        return
    fi

    case "$mode" in
        none|minimal)
            return
            ;;
        simple)
            nftban_render_banner_simple
            ;;
        full)
            nftban_render_banner_full
            ;;
        *)
            nftban_render_banner_full
            ;;
    esac
}

# Simple banner (one line + motto)
nftban_render_banner_simple() {
    local icons version motto
    icons="$(nftban_icon_pair)"
    version="$(nftban_get_version)"
    motto="${NFTBAN_MOTTO:-NFTBan — Open-source Linux IPS and nftables firewall manager}"

    echo -e "${NFTBAN_COLOR_BOLD}${icons} NFTBan v${version}${NFTBAN_COLOR_RESET}"
    echo -e "${NFTBAN_COLOR_DIM}${motto}${NFTBAN_COLOR_RESET}"
}

# =============================================================================
# COMMON BANNER ALIAS (for all CLI modules)
# =============================================================================
# Convenience function for CLI modules to show consistent banner
# Now uses unified banner with health indicator for all commands
# Usage: nftban_banner [mode]
nftban_banner() {
    local mode="${1:-cli}"
    nftban_banner_unified "$mode"
}

# =============================================================================
# UNIFIED BANNER WITH HEALTH INDICATOR
# =============================================================================
# Unified banner for all CLI commands with:
#   - Health indicator (🟢/🟠/🔴) from timer cache
#   - System info: Hostname, Kernel, Uptime
#   - Mode indicator showing current command
#
# Usage: nftban_banner_unified [mode]
# Example: nftban_banner_unified "status"
#
# Health cache: /var/cache/nftban/health/health_status.cache
# Updated by: nftban-health.timer (runs daily)
#
# See also: nftban help banner (for user documentation)
# =============================================================================

nftban_banner_unified() {
    local mode="${1:-cli}"
    # BUG-5: removed `cache_file` declaration — banner no longer reads the
    # health cache file. Posture comes from validator JSON only (see below).
    # The cache file is still written by nftban-health.timer for other
    # consumers (nftban_get_cached_health) but is NOT a posture truth source.

    # Skip for non-interactive or JSON mode
    [[ "${NFTBAN_BANNER_MODE:-auto}" == "none" ]] && return 0
    [[ "${NFTBAN_OUTPUT_JSON:-false}" == "true" ]] && return 0

    # Get version
    local version
    version="$(nftban_get_version)"

    # BUG-5: Health indicator is a PURE PROJECTION of the validator JSON
    # status field. INV-CONS-001: there is exactly one truth source for kernel
    # protection state, and it is nftban-validate. The CLI must NOT compute
    # posture from a parallel path — that is what caused srv1 to display 🟠
    # while the validator reported PROTECTED.
    #
    # Resolution order:
    #   1. nftban-validate --json (canonical)
    #   2. ⚪ if validator unavailable (not a parallel computation; absence)
    #
    # The previous code paths that have been DELETED:
    #   - reading /var/cache/nftban/health/health_status.cache (stale, parallel)
    #   - the systemctl downgrade ("if firewall active, downgrade red to orange")
    #     — the validator already accounts for kernel state authoritatively
    #   - the protection.json override (feeds_skipped/geoban_skipped)
    #     — that signal belongs in validator output, not in parallel CLI logic
    local health_icon="⚪"
    local health_status="unknown"

    local _validator_bin="/usr/lib/nftban/bin/nftban-validate"
    if [[ -x "$_validator_bin" ]] && command -v jq >/dev/null 2>&1; then
        local _validator_json
        _validator_json=$("$_validator_bin" --json 2>/dev/null || true)
        if [[ -n "$_validator_json" ]]; then
            health_status=$(echo "$_validator_json" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
        fi
    fi

    case "$health_status" in
        protected|idle)  health_icon="🟢" ;;
        degraded)        health_icon="🟠" ;;
        down)            health_icon="🔴" ;;
        unknown|*)       health_icon="⚪" ;;
    esac

    # Quick conflict detection (cached or inline)
    local conflict_icon=""
    local conflict_cache="${NFTBAN_CACHE_DIR}/health/conflicts.cache"
    if [[ -f "$conflict_cache" ]]; then
        local conflict_status
        conflict_status=$(cat "$conflict_cache" 2>/dev/null || echo "0")
        if [[ "$conflict_status" -gt 0 ]]; then
            conflict_icon=" ⚔️"  # Conflict indicator
        fi
    else
        # Quick inline check (non-blocking, minimal overhead)
        if systemctl is-active --quiet firewalld 2>/dev/null || \
           systemctl is-active --quiet fail2ban 2>/dev/null || \
           systemctl is-active --quiet iptables 2>/dev/null || \
           systemctl is-active --quiet ip6tables 2>/dev/null || \
           { command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "^Status: active"; } || \
           systemctl is-active --quiet lfd 2>/dev/null; then
            conflict_icon=" ⚔️"
        fi
    fi

    # Memory protection indicator (shows when feeds/geoban skipped).
    # BUG-5: this indicator is purely informational; it must NOT override
    # health_icon. The validator's degraded/down state is the only path that
    # may change the health icon. INV-CONS-001 enforced.
    local protection_icon=""
    local protection_file="/var/lib/nftban/state/protection.json"
    if [[ -f "$protection_file" ]]; then
        local feeds_skipped geoban_skipped
        feeds_skipped=$(jq -r '.feeds_skipped // false' "$protection_file" 2>/dev/null || echo "false")
        geoban_skipped=$(jq -r '.geoban_skipped // false' "$protection_file" 2>/dev/null || echo "false")
        if [[ "$feeds_skipped" == "true" || "$geoban_skipped" == "true" ]]; then
            protection_icon=" 💾"  # Memory protection active (informational)
            # NOTE: health_icon is NOT overridden here. The validator JSON is
            # the only source of posture truth. If memory protection should
            # imply degraded state, the validator must report it.
        fi
    fi

    # Get system info
    local hostname kernel uptime_str
    hostname=$(hostname -f 2>/dev/null || hostname -s 2>/dev/null || uname -n)
    kernel=$(uname -r | cut -d'-' -f1-2)  # Shorten kernel version

    # Format uptime (compact)
    if [[ -f /proc/uptime ]]; then
        local uptime_sec
        uptime_sec=$(awk '{print int($1)}' /proc/uptime)
        local days
        days=$((uptime_sec / 86400))
        local hours
        hours=$(( (uptime_sec % 86400) / 3600 ))
        local mins
        mins=$(( (uptime_sec % 3600) / 60 ))

        if [[ $days -gt 0 ]]; then
            if [[ $days -gt 7 ]]; then
                uptime_str="${days}d"
            else
                uptime_str="${days}d ${hours}h"
            fi
        elif [[ $hours -gt 0 ]]; then
            uptime_str="${hours}h ${mins}m"
        else
            uptime_str="${mins}m"
        fi
    else
        uptime_str=$(uptime -p 2>/dev/null | sed 's/^up //' | head -c 20 || echo "?")
    fi

    # Get icons
    local icons
    icons="$(nftban_icon_pair)"

    # Build banner
    local width
    width=$((NFTBAN_WIDTH - 2))
    [[ $width -lt 60 ]] && width=60
    [[ $width -gt 70 ]] && width=70

    # Colors
    local dim="${NFTBAN_COLOR_DIM}"
    local reset="${NFTBAN_COLOR_RESET}"
    local bold="${NFTBAN_COLOR_BOLD}"
    local cyan="${NFTBAN_COLOR_CYAN}"

    # Top border (use simple ASCII for SSH compatibility)
    echo -e "${dim}+$(nftban_repeat_char $width '-')+${reset}"

    # Emoji width compensation: emojis take 2 visual columns but printf counts ~1
    # 🐧🛡️ (2 emojis) + 🟠/🟢/🔴 (1-3 status icons) = ~5 extra visual columns
    local emoji_offset=5

    # Line 1: Icon + Health + Protection + Conflicts + Version + Tagline
    local line1="${icons}  (${health_icon}${protection_icon}${conflict_icon})  ${bold}NFTBan v${version}${reset}${dim} - Open-source Linux IPS & nftables FW${reset}"
    printf "${dim}|${reset} %-$((width - 2 + emoji_offset))b ${dim}|${reset}\n" "$line1"

    # Line 2: Host, Kernel, Uptime (no emojis, no offset)
    local line2="${dim}Host: ${cyan}${hostname}${reset}${dim} | Kernel: ${kernel}${reset}"
    printf "${dim}|${reset} %-$((width - 2))b ${dim}|${reset}\n" "$line2"

    # Detect panel (cached for performance)
    local panel_info=""
    if [[ -z "${NFTBAN_DETECTED_PANEL:-}" ]]; then
        if [[ -d "/usr/local/cpanel" ]]; then
            NFTBAN_DETECTED_PANEL="cPanel"
        elif [[ -d "/usr/local/directadmin" ]]; then
            NFTBAN_DETECTED_PANEL="DirectAdmin"
        elif [[ -d "/usr/local/psa" ]]; then
            NFTBAN_DETECTED_PANEL="Plesk"
        elif [[ -d "/usr/local/cwpsrv" ]]; then
            NFTBAN_DETECTED_PANEL="CWP"
        elif [[ -d "/usr/local/CyberCP" ]]; then
            NFTBAN_DETECTED_PANEL="CyberPanel"
        else
            NFTBAN_DETECTED_PANEL="none"
        fi
        export NFTBAN_DETECTED_PANEL
    fi

    if [[ "$NFTBAN_DETECTED_PANEL" != "none" ]]; then
        panel_info=" | Panel: ${cyan}${NFTBAN_DETECTED_PANEL}${reset}${dim}"
    fi

    # Line 3: Uptime + Mode + Panel + Cmd
    local cmd_info=" | Cmd: ${cyan}${mode}${reset}${dim}"
    local line3="${dim}Uptime: ${uptime_str} | Mode: cli${panel_info}${cmd_info}${reset}"
    printf "${dim}|${reset} %-$((width - 2))b ${dim}|${reset}\n" "$line3"

    # Bottom border
    echo -e "${dim}+$(nftban_repeat_char $width '-')+${reset}"
    echo ""
}

# =============================================================================
# HEALTH CACHE WRITER (called by nftban-health.timer)
# =============================================================================
# Writes health status to cache file for banner display
# Usage: nftban_health_cache_write <status_code>
#   0 = OK (🟢), 1 = WARNING (🟠), 2 = ERROR (🔴), 3 = CRITICAL, 4 = NOT_INSTALLED
#
nftban_health_cache_write() {
    local status_code="${1:-0}"
    local cache_dir="${NFTBAN_CACHE_DIR}/health"
    local cache_file="${cache_dir}/health_status.cache"

    # Create cache directory if needed
    mkdir -p "$cache_dir" 2>/dev/null || true

    # Write status (4=NOT_INSTALLED is OK for banner - optional feature)
    case "$status_code" in
        0|4) echo "OK" > "$cache_file" ;;        # OK or NOT_INSTALLED = green
        1) echo "WARNING" > "$cache_file" ;;
        2) echo "ERROR" > "$cache_file" ;;
        3) echo "CRITICAL" > "$cache_file" ;;
        *) echo "UNKNOWN" > "$cache_file" ;;
    esac

    # Set permissions
    chmod 644 "$cache_file" 2>/dev/null || true
    chown nftban:nftban "$cache_file" 2>/dev/null || true

    return 0
}

# =============================================================================
# HEALTH CACHE READER
# =============================================================================
# Returns cached health status (for scripts that need just the status)
# Usage: status=$(nftban_health_cache_read)
#
nftban_health_cache_read() {
    local cache_file="${NFTBAN_CACHE_DIR}/health/health_status.cache"

    if [[ -f "$cache_file" ]]; then
        cat "$cache_file" 2>/dev/null || echo "UNKNOWN"
    else
        echo "UNKNOWN"
    fi
}

# Full banner (decorative with stats)
nftban_render_banner_full() {
    local icons version host kernel motto line1 line2 line3
    local debug_marker=""

    # Debug mode indicator
    [[ "${NFTBAN_DEBUG_MODE:-false}" == "true" ]] && debug_marker=" ${NFTBAN_COLOR_YELLOW}[DEBUG MODE]${NFTBAN_COLOR_RESET}"

    icons="$(nftban_icon_pair)"
    version="$(nftban_get_version)"
    host="$(nftban_get_hostname)"
    kernel="$(nftban_get_kernel)"
    motto="${NFTBAN_MOTTO:-NFTBan — Open-source Linux IPS and nftables firewall manager}"

    # Top border
    if [[ "$NFTBAN_COLOR" == "true" ]]; then
        echo -e "${NFTBAN_COLOR_DIM}╭$(nftban_repeat_char $((NFTBAN_WIDTH - 2)) '─')╮${NFTBAN_COLOR_RESET}"
    fi

    # Line 1: icon + name + version + host + kernel + debug marker
    line1="${NFTBAN_COLOR_BRIGHT_WHITE}${icons} NFTBan v${version}${NFTBAN_COLOR_RESET} @ ${host} · ${kernel}${debug_marker}"
    nftban_center_text "$line1"

    # Line 2: motto (if enabled)
    if [[ "${NFTBAN_BANNER_MOTTO:-true}" == "true" ]] && [[ -n "$motto" ]]; then
        line2="${NFTBAN_COLOR_DIM}${motto}${NFTBAN_COLOR_RESET}"
        nftban_center_text "$line2"
    fi

    # Line 3: stats (if enabled)
    if [[ "${NFTBAN_BANNER_STATS:-true}" == "true" ]]; then
        line3="$(nftban_get_stats_line)"
        if [[ -n "$line3" ]]; then
            nftban_center_text "${NFTBAN_COLOR_DIM}${line3}${NFTBAN_COLOR_RESET}"
        fi
    fi

    # Bottom border
    if [[ "$NFTBAN_COLOR" == "true" ]]; then
        echo -e "${NFTBAN_COLOR_DIM}╰$(nftban_repeat_char $((NFTBAN_WIDTH - 2)) '─')╯${NFTBAN_COLOR_RESET}"
    fi

    # Hints (if enabled)
    if [[ "${NFTBAN_SHOW_HINTS:-false}" == "true" ]]; then
        echo -e "${NFTBAN_COLOR_DIM}Quick: nftban help | status | feeds${NFTBAN_COLOR_RESET}"
    fi

    # Debug info (if enabled)
    if [[ "${NFTBAN_SHOW_ENVIRONMENT:-false}" == "true" ]]; then
        nftban_show_debug_environment
    fi

    if [[ "${NFTBAN_SHOW_LOG_PATHS:-false}" == "true" ]]; then
        nftban_show_log_paths
    fi

    # Update check notification (if enabled)
    if [[ "${NFTBAN_BANNER_UPDATE_CHECK:-false}" == "true" ]]; then
        nftban_check_updates_banner
    fi

    echo ""
}

# Get stats line (tables, chains, rules, bans)
nftban_get_stats_line() {
    command -v nft >/dev/null 2>&1 || return

    local tables chains rules bans
    local ruleset

    ruleset="$(nft -a list ruleset 2>/dev/null)" || return

    tables=$(echo "$ruleset" | grep -cE '^table[[:space:]]' || echo 0)
    chains=$(echo "$ruleset" | grep -cE '^[[:space:]]*chain[[:space:]]' || echo 0)
    rules=$(echo "$ruleset" | grep -cE '[[:space:]]handle[[:space:]][0-9]+' || echo 0)

    # Count ban set elements (simplified heuristic)
    bans=0
    if echo "$ruleset" | grep -qi "set.*ban"; then
        # Count elements in sets with "ban" in name
        bans=$(echo "$ruleset" | { grep -i 'elements = {' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true; } | wc -l || echo 0)
    fi

    local stats="tables $tables · chains $chains · rules $rules"
    [[ $bans -gt 0 ]] && stats="$stats · bans $bans"

    echo "$stats"
}

# Show debug environment info
nftban_show_debug_environment() {
    echo -e "${NFTBAN_COLOR_GRAY}[DEBUG] Environment:${NFTBAN_COLOR_RESET}"
    echo -e "  ${NFTBAN_COLOR_GRAY}User:   $(whoami) (effective), groups: $(groups | cut -d' ' -f1-3)${NFTBAN_COLOR_RESET}"
    echo -e "  ${NFTBAN_COLOR_GRAY}Config: ${NFTBAN_CONFIG_DIR:-/etc/nftban}${NFTBAN_COLOR_RESET}"
    echo -e "  ${NFTBAN_COLOR_GRAY}Modules: ${NFTBAN_LIB_DIR:-/usr/lib/nftban}${NFTBAN_COLOR_RESET}"
}

# Show log file paths
nftban_show_log_paths() {
    echo -e "${NFTBAN_COLOR_GRAY}[DEBUG] Logs:${NFTBAN_COLOR_RESET}"
    echo -e "  ${NFTBAN_COLOR_GRAY}Main:  ${NFTBAN_LOG_FILE:-/var/log/nftban/nftban.log}${NFTBAN_COLOR_RESET}"
    [[ "${NFTBAN_DEBUG_MODE:-false}" == "true" ]] && \
        echo -e "  ${NFTBAN_COLOR_GRAY}Debug: ${NFTBAN_DEBUG_FILE:-/var/log/nftban/nftban_debug.log}${NFTBAN_COLOR_RESET}"
}

# =============================================================================
# MODULE LOAD MESSAGES
# =============================================================================

# Show module load message
# Usage: nftban_module_loaded "name" "version" "header" "type" ["depends"]
nftban_module_loaded() {
    local name="${1:-unknown}"
    local version="${2:-0.0.0}"
    local header="${3:-$name}"
    local type="${4:-module}"
    local depends="${5:-}"

    local level="${NFTBAN_MODULE_LOAD_LEVEL:-info}"
    local load_time=""

    # Track load order
    NFTBAN_MODULE_LOAD_ORDER+=("$name")

    # Calculate load time if timing enabled
    if [[ "${NFTBAN_SHOW_LOAD_TIMING:-false}" == "true" ]]; then
        load_time="$(nftban_get_elapsed)"
        # shellcheck disable=SC2034  # Used in test-banner.sh and verbose output
        NFTBAN_MODULE_LOAD_TIMES["$name"]="$load_time"
    fi

    case "$level" in
        none)
            return
            ;;
        error)
            # Only show if there's an error (not implemented here)
            return
            ;;
        info)
            nftban_module_loaded_info "$name" "$version" "$header" "$type"
            ;;
        debug)
            nftban_module_loaded_debug "$name" "$version" "$header" "$type" "$depends" "$load_time"
            ;;
        verbose)
            nftban_module_loaded_verbose "$name" "$version" "$header" "$type" "$depends" "$load_time"
            ;;
    esac
}

# Info level module load message
nftban_module_loaded_info() {
    local name="$1" version="$2" header="$3" type="$4"
    local format="${NFTBAN_MODULE_LOAD_FORMAT:-[INFO] {header} loaded (v{version})}"

    # Replace placeholders
    format="${format//\{name\}/$name}"
    format="${format//\{version\}/$version}"
    format="${format//\{header\}/$header}"
    format="${format//\{type\}/$type}"

    echo -e "${NFTBAN_COLOR_CYAN}${format}${NFTBAN_COLOR_RESET}"
}

# Debug level module load message
nftban_module_loaded_debug() {
    local name="$1" version="$2" header="$3" type="$4" depends="$5" load_time="$6"

    echo -e "${NFTBAN_COLOR_GRAY}[DEBUG] Module loaded${load_time:+ in ${load_time}s}:${NFTBAN_COLOR_RESET}"
    echo -e "  ${NFTBAN_COLOR_GRAY}Name:    ${name}${NFTBAN_COLOR_RESET}"
    echo -e "  ${NFTBAN_COLOR_GRAY}Version: ${version}${NFTBAN_COLOR_RESET}"
    echo -e "  ${NFTBAN_COLOR_GRAY}Header:  ${header}${NFTBAN_COLOR_RESET}"
    echo -e "  ${NFTBAN_COLOR_GRAY}Type:    ${type}${NFTBAN_COLOR_RESET}"
    [[ -n "$depends" ]] && echo -e "  ${NFTBAN_COLOR_GRAY}Depends: ${depends}${NFTBAN_COLOR_RESET}"
}

# Verbose level module load message
nftban_module_loaded_verbose() {
    local name="$1" version="$2" header="$3" type="$4" depends="$5" load_time="$6"
    local load_num="${#NFTBAN_MODULE_LOAD_ORDER[@]}"
    local total_time
    total_time="$(nftban_get_elapsed)"

    echo -e "${NFTBAN_COLOR_GRAY}[VERBOSE] Module load sequence #${load_num} (${total_time}s elapsed):${NFTBAN_COLOR_RESET}"
    echo -e "  ${NFTBAN_COLOR_GRAY}Name:        ${name}${NFTBAN_COLOR_RESET}"
    echo -e "  ${NFTBAN_COLOR_GRAY}Version:     ${version}${NFTBAN_COLOR_RESET}"
    echo -e "  ${NFTBAN_COLOR_GRAY}Header:      ${header}${NFTBAN_COLOR_RESET}"
    echo -e "  ${NFTBAN_COLOR_GRAY}Type:        ${type}${NFTBAN_COLOR_RESET}"
    echo -e "  ${NFTBAN_COLOR_GRAY}Load time:   ${load_time}s${NFTBAN_COLOR_RESET}"
    [[ -n "$depends" ]] && echo -e "  ${NFTBAN_COLOR_GRAY}Dependencies: ${depends}${NFTBAN_COLOR_RESET}"
}

# =============================================================================
# ERROR/WARNING BANNERS
# =============================================================================

# Show error banner (always shown, even in minimal mode)
# Also logs to journald for centralized error tracking (BUG-003 fix)
nftban_error_banner() {
    local message="$1"
    local style="${NFTBAN_ERROR_BANNER_STYLE:-box}"

    # Log to journald
    logger -t nftban -p user.err "[ERROR] ${message}" 2>/dev/null || true

    case "$style" in
        box)
            nftban_error_banner_box "$message"
            ;;
        line)
            nftban_error_banner_line "$message"
            ;;
        minimal)
            nftban_error_banner_minimal "$message"
            ;;
    esac
}

# Error banner: box style
nftban_error_banner_box() {
    local message="$1"
    local width=$NFTBAN_WIDTH
    local line

    line="$(nftban_repeat_char $((width - 4)) '═')"

    echo -e "${NFTBAN_COLOR_RED}"
    echo "╔${line}╗"
    nftban_center_text "  ${NFTBAN_COLOR_BOLD}ERROR${NFTBAN_COLOR_RESET}${NFTBAN_COLOR_RED}" "$width"
    nftban_center_text "  $message  " "$width"
    echo "╚${line}╝"
    echo -e "${NFTBAN_COLOR_RESET}"
}

# Error banner: line style
nftban_error_banner_line() {
    local message="$1"
    echo -e "${NFTBAN_COLOR_RED}${NFTBAN_COLOR_BOLD}[ERROR]${NFTBAN_COLOR_RESET}${NFTBAN_COLOR_RED} $message${NFTBAN_COLOR_RESET}"
}

# Error banner: minimal style
nftban_error_banner_minimal() {
    local message="$1"
    echo "ERROR: $message"
}

# Warning banner
# Also logs to journald for centralized warning tracking (BUG-003 fix)
nftban_warning_banner() {
    local message="$1"
    local style="${NFTBAN_WARNING_BANNER_STYLE:-line}"

    # Log to journald
    logger -t nftban -p user.warning "[WARN] ${message}" 2>/dev/null || true

    case "$style" in
        line)
            echo -e "${NFTBAN_COLOR_YELLOW}${NFTBAN_COLOR_BOLD}[WARNING]${NFTBAN_COLOR_RESET}${NFTBAN_COLOR_YELLOW} $message${NFTBAN_COLOR_RESET}"
            ;;
        minimal)
            echo "WARNING: $message"
            ;;
    esac
}

# =============================================================================
# PROGRESS INDICATORS
# =============================================================================

# Progress spinner state
declare -g _NFTBAN_SPINNER_PID=""
declare -g _NFTBAN_SPINNER_MSG=""

# Start a background spinner for long operations
# Usage: nftban_progress_start "Loading feeds..."
nftban_progress_start() {
    local message="${1:-Processing...}"
    _NFTBAN_SPINNER_MSG="$message"

    # Don't start spinner if not a terminal
    [[ ! -t 1 ]] && return 0

    # Kill any existing spinner
    nftban_progress_end 2>/dev/null

    # Start spinner in background
    (
        local spinchars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
        local i=0
        while true; do
            printf "\r${NFTBAN_COLOR_CYAN}%s${NFTBAN_COLOR_RESET} %s " "${spinchars:i++%${#spinchars}:1}" "$message"
            sleep 0.1
        done
    ) &
    _NFTBAN_SPINNER_PID=$!

    # Ensure spinner is killed on script exit
    trap 'nftban_progress_end 2>/dev/null' EXIT
}

# Update spinner message (optional)
# Usage: nftban_progress_update "Step 2 of 5..."
nftban_progress_update() {
    local message="${1:-Processing...}"
    _NFTBAN_SPINNER_MSG="$message"

    # If spinner is running, it will pick up new message on next iteration
    # For simplicity, restart with new message
    if [[ -n "$_NFTBAN_SPINNER_PID" ]] && kill -0 "$_NFTBAN_SPINNER_PID" 2>/dev/null; then
        nftban_progress_end
        nftban_progress_start "$message"
    fi
}

# Stop the spinner and optionally show completion message
# Usage: nftban_progress_end "Done!" or nftban_progress_end
# Function accepts optional arguments for progress customization
# called with and without args depending on context
# shellcheck disable=SC2120
nftban_progress_end() {
    local message="${1:-}"

    # Kill spinner process
    if [[ -n "$_NFTBAN_SPINNER_PID" ]]; then
        kill "$_NFTBAN_SPINNER_PID" 2>/dev/null
        wait "$_NFTBAN_SPINNER_PID" 2>/dev/null
        _NFTBAN_SPINNER_PID=""
    fi

    # Clear line and show completion message
    if [[ -t 1 ]]; then
        printf "\r\033[K"  # Clear line
        if [[ -n "$message" ]]; then
            echo -e "${NFTBAN_COLOR_GREEN}✓${NFTBAN_COLOR_RESET} $message"
        fi
    fi
}

# Simple progress bar for operations with known count
# Usage: nftban_progress_bar 50 100 "Processing feeds"
nftban_progress_bar() {
    local current="${1:-0}"
    local total="${2:-100}"
    local message="${3:-Progress}"
    local width=40

    [[ ! -t 1 ]] && return 0
    [[ $total -eq 0 ]] && total=1

    local percent
    percent=$((current * 100 / total))
    local filled
    filled=$((current * width / total))
    local empty
    empty=$((width - filled))

    printf "\r${NFTBAN_COLOR_CYAN}%s${NFTBAN_COLOR_RESET} [" "$message"
    printf "%${filled}s" | tr ' ' '█'
    printf "%${empty}s" | tr ' ' '░'
    printf "] %3d%%" "$percent"

    # Newline when complete
    [[ $current -ge $total ]] && echo ""
}

export -f nftban_progress_start
export -f nftban_progress_update
export -f nftban_progress_end
export -f nftban_progress_bar

# =============================================================================
# UPDATE CHECK FUNCTIONS
# =============================================================================

# Check for updates and display notification in banner
nftban_check_updates_banner() {
    local cache_file="${NFTBAN_CACHE_DIR}/update_check"
    local cache_ttl="${NFTBAN_UPDATE_TTL:-86400}" # 24 hours default
    local repo="${NFTBAN_REPO:-itcmsgr/nftban}"
    local current_version latest_version

    # Get current version
    current_version="$(nftban_get_version)"

    # Check cache validity
    if [[ -f "$cache_file" ]]; then
        local cache_age
        cache_age=$(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo "0") ))

        # Use cached result if fresh
        if [[ $cache_age -lt $cache_ttl ]]; then
            latest_version="$(cat "$cache_file" 2>/dev/null)"
        fi
    fi

    # Fetch latest version if no valid cache
    if [[ -z "$latest_version" ]]; then
        # Quick check with timeout (3 seconds)
        latest_version=$(curl -sf --max-time 3 "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null | \
            grep -oP '"tag_name":\s*"v?\K[0-9]+\.[0-9]+\.[0-9]+' | head -1)

        # Cache the result (create dir if needed)
        if [[ -n "$latest_version" ]]; then
            mkdir -p "$(dirname "$cache_file")" 2>/dev/null || return 1
            echo "$latest_version" > "$cache_file" 2>/dev/null || true
        else
            # Failed to fetch, don't show anything
            return 0
        fi
    fi

    # Compare versions and show notification if update available
    if [[ -n "$latest_version" ]] && [[ "$latest_version" != "$current_version" ]]; then
        nftban_version_compare "$current_version" "$latest_version"
        local cmp=$?

        # 0 = equal, 1 = current < latest (update available), 2 = current > latest
        if [[ $cmp -eq 1 ]]; then
            echo ""
            echo -e "${NFTBAN_COLOR_YELLOW}╭────────────────────────────────────────────────────────────╮${NFTBAN_COLOR_RESET}"
            echo -e "${NFTBAN_COLOR_YELLOW}│  📦 Update Available: v${latest_version}$(printf ' %.0s' {1..28})│${NFTBAN_COLOR_RESET}"
            echo -e "${NFTBAN_COLOR_YELLOW}│  Current: v${current_version}                                      │${NFTBAN_COLOR_RESET}"
            echo -e "${NFTBAN_COLOR_YELLOW}│  Download: github.com/${repo}/releases   │${NFTBAN_COLOR_RESET}"
            echo -e "${NFTBAN_COLOR_YELLOW}╰────────────────────────────────────────────────────────────╯${NFTBAN_COLOR_RESET}"
        fi
    fi
}

# Compare two semantic versions (X.Y.Z)
# Returns: 0 if equal, 1 if v1 < v2, 2 if v1 > v2
nftban_version_compare() {
    local v1="$1" v2="$2"

    # Remove 'v' prefix if present
    v1="${v1#v}"
    v2="${v2#v}"

    # Split versions into components
    IFS='.' read -r v1_major v1_minor v1_patch <<< "$v1"
    IFS='.' read -r v2_major v2_minor v2_patch <<< "$v2"

    # Default to 0 if empty
    v1_major="${v1_major:-0}"
    v1_minor="${v1_minor:-0}"
    v1_patch="${v1_patch:-0}"
    v2_major="${v2_major:-0}"
    v2_minor="${v2_minor:-0}"
    v2_patch="${v2_patch:-0}"

    # Compare major
    if [[ $v1_major -lt $v2_major ]]; then
        return 1
    elif [[ $v1_major -gt $v2_major ]]; then
        return 2
    fi

    # Compare minor
    if [[ $v1_minor -lt $v2_minor ]]; then
        return 1
    elif [[ $v1_minor -gt $v2_minor ]]; then
        return 2
    fi

    # Compare patch
    if [[ $v1_patch -lt $v2_patch ]]; then
        return 1
    elif [[ $v1_patch -gt $v2_patch ]]; then
        return 2
    fi

    # Equal
    return 0
}

# =============================================================================
# MAIN OUTPUT FUNCTION - nftban_output
# =============================================================================
# This is the core output function used throughout the codebase
# Usage: nftban_output <type> <message>
# Types: info, success, error, warning, header, debug
#
# Errors and warnings are also logged to journald via logger -t nftban
#
# BUG-008 fix: Uses NFTBAN_COLOR_* variables instead of hardcoded ANSI codes.
# When NFTBAN_COLOR is false (e.g., output redirected to file), these variables
# are empty strings, preventing ANSI escape codes from appearing in log files.
#
nftban_output() {
    local type="${1:-info}"
    local message="${2:-}"
    local prefix=""
    local color_code=""

    # Log errors and warnings to journald (BUG-003 fix)
    case "$type" in
        error)
            logger -t nftban -p user.err "[ERROR] ${message}" 2>/dev/null || true
            ;;
        warning)
            logger -t nftban -p user.warning "[WARN] ${message}" 2>/dev/null || true
            ;;
    esac

    # Determine prefix based on type
    # BUG-008: Use NFTBAN_COLOR_* variables (empty when colors disabled)
    case "$type" in
        error)   prefix="[ERROR]"; color_code="${NFTBAN_COLOR_RED}" ;;
        warning) prefix="[WARN]";  color_code="${NFTBAN_COLOR_YELLOW}" ;;
        success) prefix="[OK]";    color_code="${NFTBAN_COLOR_GREEN}" ;;
        info)    prefix="[INFO]";  color_code="${NFTBAN_COLOR_BLUE:-${NFTBAN_COLOR_CYAN}}" ;;
        header)  prefix="==>";     color_code="${NFTBAN_COLOR_BOLD}${NFTBAN_COLOR_CYAN}" ;;
        debug)   prefix="[DEBUG]"; color_code="${NFTBAN_COLOR_GRAY}" ;;
        *)       prefix="[$type]"; color_code="" ;;
    esac

    # Output with or without colors (NFTBAN_COLOR_* are empty strings when disabled)
    echo -e "${color_code}${prefix}${NFTBAN_COLOR_RESET} ${message}"
}

# Export function for subshells
export -f nftban_output 2>/dev/null || true

# =============================================================================
# FOOTER - Debug & Module Info
# =============================================================================

# Auto-report module load (only if DEBUG_MODE is true)
# IMPORTANT: These values MUST match the meta: fields in the header above
#   - meta:name         → "nftban_output"
#   - meta:version      → "1.0.0"
#   - meta:header       → "Output & Banner Module"
#   - meta:type         → "core"
#   - meta:depends      → "tput,uname,hostname"
#
# This pattern should be followed by ALL modules:
#   nftban_module_loaded "<meta:name>" "<meta:version>" "<meta:header>" "<meta:type>" "<meta:depends>"
#
if [[ "${NFTBAN_DEBUG_MODE:-false}" == "true" ]]; then
    nftban_module_loaded "nftban_output" "1.0.0" "Output & Banner Module" "core" "tput,uname,hostname"
fi

# Guard: do not exit on source
# shellcheck disable=SC2317  # This is reachable when script is sourced
return 0 2>/dev/null || :
