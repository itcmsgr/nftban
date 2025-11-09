#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.32.23 - Output & Banner Core Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Standardized output, banners, and formatting for all modules
#
# meta:name=nftban_output
# meta:type=core
# meta:header=Output & Banner Module
# meta:version=0.32.23
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Core output module providing banners, formatting, and module load messages
# meta:input=Configuration from conf.d/banner.conf, module meta fields
# meta:output=Formatted banners, module load messages, error messages
#
# **Inventory & Requirements**
# meta:depends=tput,uname,hostname,nft (optional)
# meta:requires_env=NFTBAN_BANNER_MODE,NFTBAN_COLOR
#
# meta:created_date=2025-11-05
# meta:modified_date=2025-10-26

set -Eeuo pipefail

# =============================================================================
# PREVENT DOUBLE-LOADING
# =============================================================================
[[ -n "${NFTBAN_OUTPUT_LOADED:-}" ]] && return 0
NFTBAN_OUTPUT_LOADED="true"

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

    local pad=$(( (width - len) / 2 ))
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
    elif command -v nftban >/dev/null 2>&1; then
        nftban --version 2>/dev/null | sed -n 's/.*\([0-9]\+\.[0-9]\+\.[0-9]\+\).*/\1/p' || echo "0.31.0"
    else
        echo "0.31.0"
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
    motto="${NFTBAN_MOTTO:-Simplifying Linux Firewall Management}"

    echo -e "${NFTBAN_COLOR_BOLD}${icons} NFTBan v${version}${NFTBAN_COLOR_RESET}"
    echo -e "${NFTBAN_COLOR_DIM}${motto}${NFTBAN_COLOR_RESET}"
}

# =============================================================================
# COMMON BANNER ALIAS (for all CLI modules)
# =============================================================================
# Convenience function for CLI modules to show consistent banner
# Usage: nftban_banner
nftban_banner() {
    nftban_render_banner simple
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
    motto="${NFTBAN_MOTTO:-Simplifying Linux Firewall Management}"

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
        bans=$(echo "$ruleset" | grep -i 'elements = {' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | wc -l || echo 0)
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
nftban_error_banner() {
    local message="$1"
    local style="${NFTBAN_ERROR_BANNER_STYLE:-box}"

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
nftban_warning_banner() {
    local message="$1"
    local style="${NFTBAN_WARNING_BANNER_STYLE:-line}"

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
# PROGRESS INDICATORS (for future use)
# =============================================================================

# TODO: Implement progress spinner/bar for long operations
# nftban_progress_start() { ... }
# nftban_progress_update() { ... }
# nftban_progress_end() { ... }

# =============================================================================
# UPDATE CHECK FUNCTIONS
# =============================================================================

# Check for updates and display notification in banner
nftban_check_updates_banner() {
    local cache_file="/var/cache/nftban/update_check"
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
            mkdir -p "$(dirname "$cache_file")" 2>/dev/null
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
