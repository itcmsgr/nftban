#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.30 - Bot Scanner CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="cmd_botscan"
# meta:type="cli"
# meta:header="Bot Scanner CLI"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="CLI handler for bot scanner detection commands"
# meta:inventory.files=""
# meta:inventory.binaries="nft,grep,awk,tail"
# meta:inventory.env_vars="BOTSCAN_ENABLED"
# meta:inventory.config_files="/etc/nftban/conf.d/botscan/main.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2026-01-11"
# meta:updated_date="2026-01-11"
# =============================================================================

set -Eeuo pipefail

[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"

# Load strict mode library
# shellcheck source=/usr/lib/nftban/lib/strict.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/strict.sh" || return 1
fi

# Load version library
# shellcheck source=/usr/lib/nftban/lib/version.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/version.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/version.sh" || return 1
fi

# Load JSON helper for --json support
JSON_HELPER="${NFTBAN_LIB_DIR}/helpers/json_output.sh"
if [[ -f "$JSON_HELPER" ]]; then
    # shellcheck source=/dev/null
    source "$JSON_HELPER" || return 1
fi

# =============================================================================
# HELP TEXT
# =============================================================================

_nftban_botscan_help() {
    # Load output module for standard banner
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
        nftban_banner "botscan"
    fi

    cat <<'HELP'

USAGE:
    nftban botscan <command> [options]

COMMANDS:
    enable              Enable bot scanner detection
    disable             Disable bot scanner detection
    status              Show detection status and configuration
    check               Run manual log analysis (parse recent entries)
    patterns            List all detection patterns
      patterns list     List patterns (all|enabled|disabled)
      patterns add      Add custom pattern
      patterns remove   Remove custom pattern
      patterns enable   Enable a pattern
      patterns disable  Disable a pattern
    history             Show detected bots (last 24 hours)
    test                Test pattern matching against sample URLs
    help                Show this help message

DESCRIPTION:
    The bot scanner module identifies malicious bots, web shells, exploit
    probes, and reconnaissance scanners by analyzing HTTP access logs.

    Unlike portscan detection which monitors network layer traffic, botscan
    operates at the application layer by parsing Apache/Nginx access logs.

HOW IT WORKS:

    1. Log Monitoring: Parses Apache/Nginx access logs
    2. Pattern Match: Matches URLs against malicious patterns
    3. Threshold: Flags IPs that hit N patterns in M seconds
    4. Auto-Ban: Automatically bans detected bot scanners

DETECTION CATEGORIES:

    Webshell Probes:
      • c99.php, r57.php, shell.php, b374k.php
      • WSO shells, China Chopper, FilesMan
      • Backdoor upload attempts

    Exploit Scanners:
      • Log4j (CVE-2021-44228) probes
      • PHPUnit RCE attempts
      • Spring4Shell exploits
      • ThinkPHP/Laravel exploits
      • Remote File Inclusion (RFI)
      • Local File Inclusion (LFI)

    Reconnaissance:
      • Backup file scanning (.bak, .old, .zip, .sql)
      • Admin panel probes (/admin, /manager, /phpmyadmin)
      • Config file discovery (.env, wp-config.php.bak)
      • Directory traversal attempts

PATTERN FORMAT:

    Patterns are stored in /etc/nftban/patterns.d/botscan/

    Format: NAME|PATTERN|MATCH_TYPE|THRESHOLD|WINDOW|BAN|ENABLED|DESCRIPTION

    MATCH_TYPE options:
      url-404    = Match only if HTTP 404 response (RECOMMENDED)
      url-any    = Match any HTTP response code
      url-post   = Match POST requests only
      url-get    = Match GET requests only
      useragent  = Match against User-Agent header (for bad bots)

PATTERN FILES:

    webshell.patterns   - Web shell and backdoor probes
    exploit.patterns    - Known CVE and exploit attempts
    scanner.patterns    - Reconnaissance and backup scanners
    badbots.patterns    - Bad bots by User-Agent (PetalBot, GPTBot, etc.)
    custom.patterns     - User-defined patterns (preserved on upgrade)

CONFIGURATION:
    /etc/nftban/conf.d/botscan/main.conf

    Key settings:
      BOTSCAN_ENABLED           Enable/disable module (true/false)
      BOTSCAN_ACTION_MODE       alert, ban, or both
      BOTSCAN_DEFAULT_THRESHOLD Hits before ban (default: 5)
      BOTSCAN_DEFAULT_WINDOW    Time window in seconds (default: 60)
      BOTSCAN_404_TRACKING      Track excessive 404s (true/false)
      BOTSCAN_404_THRESHOLD     404s before ban (default: 50)

    User overrides:
      /etc/nftban/conf.d/botscan/main.conf.local

WHITELIST:

    Legitimate bots (user-agent based):
      googlebot, bingbot, yandexbot, duckduckbot

    Whitelisted paths (never trigger):
      /robots.txt, /favicon.ico, /sitemap.xml, /ads.txt

    Global whitelist also applies (if BOTSCAN_USE_GLOBAL_WHITELIST=true)

EXAMPLES:
    # Enable bot scanner detection
    sudo nftban botscan enable

    # Check status
    nftban botscan status

    # Run manual check (parse recent logs)
    sudo nftban botscan check

    # List all patterns
    nftban botscan patterns list

    # List only enabled patterns
    nftban botscan patterns list enabled

    # Add custom pattern
    sudo nftban botscan patterns add MY_PATTERN "malicious\.php" url-404 3 60 3600 "My pattern"

    # Show detection history
    nftban botscan history

LOG FILES:
    Detection logs: ${NFTBAN_LOG_DIR}/botscan.log
    State tracking: /var/lib/nftban/botscan-state.db

SEE ALSO:
    nftban login help      - Login/auth brute-force detection
    nftban portscan help   - Network port scan detection
    nftban ddos help       - DDoS protection

HELP
}

# =============================================================================
# BANNER
# =============================================================================

_nftban_botscan_banner() {
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
        nftban_banner "botscan"
    else
        echo "NFTBan Bot Scanner"
        echo "=================="
    fi
}

# =============================================================================
# JSON STATS FUNCTION (for API/GUI)
# =============================================================================

_nftban_botscan_stats_json() {
    local json_mode="${1:-false}"

    # Get botscan enabled status from config
    local botscan_enabled="false"
    local action_mode="both"
    local patterns_total=0
    local patterns_enabled=0
    local blocked_24h=0
    local blocked_total=0
    local config_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/botscan/main.conf"
    local patterns_dir="${NFTBAN_CONFIG_DIR:-/etc/nftban}/patterns.d/botscan"
    local log_file="${NFTBAN_LOG_DIR:-/var/log/nftban}/botscan.log"

    # Read from main.conf
    if [[ -f "$config_file" ]]; then
        local enabled_val
        enabled_val=$(grep "^BOTSCAN_ENABLED=" "$config_file" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"' | tr -d "'" | tr -d ' ') || true
        [[ "$enabled_val" == "true" ]] && botscan_enabled="true"

        local mode_val
        mode_val=$(grep "^BOTSCAN_ACTION_MODE=" "$config_file" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'") || true
        [[ -n "$mode_val" ]] && action_mode="$mode_val"
    fi

    # Count patterns
    if [[ -d "$patterns_dir" ]]; then
        for pattern_file in "$patterns_dir"/*.patterns; do
            [[ -f "$pattern_file" ]] || continue
            while IFS='|' read -r name _ _ _ _ _ is_enabled _; do
                [[ -z "$name" || "$name" =~ ^# ]] && continue
                patterns_total=$((patterns_total + 1))
                [[ "$is_enabled" == "true" ]] && patterns_enabled=$((patterns_enabled + 1))
            done < "$pattern_file"
        done
    fi

    # Count bans from log
    if [[ -f "$log_file" ]]; then
        blocked_total=$(grep -c "BANNED" "$log_file" 2>/dev/null) || blocked_total=0
        # Count last 24 hours
        local yesterday
        yesterday=$(date -d '24 hours ago' '+%Y-%m-%d' 2>/dev/null) || yesterday=""
        if [[ -n "$yesterday" ]]; then
            blocked_24h=$(grep "BANNED" "$log_file" 2>/dev/null | grep -c "^${yesterday}" 2>/dev/null) || true
            local today
            today=$(date '+%Y-%m-%d')
            local today_count
            today_count=$(grep "BANNED" "$log_file" 2>/dev/null | grep -c "^${today}" 2>/dev/null) || today_count=0
            blocked_24h=$((blocked_24h + today_count))
        fi
    fi

    # Ensure numeric values
    patterns_total=$(echo "$patterns_total" | tr -dc '0-9')
    [[ -z "$patterns_total" ]] && patterns_total=0
    patterns_enabled=$(echo "$patterns_enabled" | tr -dc '0-9')
    [[ -z "$patterns_enabled" ]] && patterns_enabled=0
    blocked_24h=$(echo "$blocked_24h" | tr -dc '0-9')
    [[ -z "$blocked_24h" ]] && blocked_24h=0
    blocked_total=$(echo "$blocked_total" | tr -dc '0-9')
    [[ -z "$blocked_total" ]] && blocked_total=0

    if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
        local data
        if command -v jq &>/dev/null; then
            data=$(jq -n \
                --arg enabled "$botscan_enabled" \
                --arg mode "$action_mode" \
                --arg patterns_total "$patterns_total" \
                --arg patterns_enabled "$patterns_enabled" \
                --arg blocked_24h "$blocked_24h" \
                --arg blocked_total "$blocked_total" \
                '{
                    botscan: {
                        enabled: ($enabled == "true"),
                        action_mode: $mode,
                        patterns_total: ($patterns_total | tonumber),
                        patterns_enabled: ($patterns_enabled | tonumber),
                        blocked_24h: ($blocked_24h | tonumber),
                        blocked_total: ($blocked_total | tonumber)
                    }
                }')
        else
            local enabled_json="false"
            [[ "$botscan_enabled" == "true" ]] && enabled_json="true"
            data="{\"botscan\":{\"enabled\":$enabled_json,\"action_mode\":\"$action_mode\",\"patterns_total\":$patterns_total,\"patterns_enabled\":$patterns_enabled,\"blocked_24h\":$blocked_24h,\"blocked_total\":$blocked_total}}"
        fi

        json_output "true" "$data"
        return 0
    fi

    # Human-readable output
    echo "Bot Scanner Statistics"
    echo "======================"
    echo ""
    echo "  Enabled:           $botscan_enabled"
    echo "  Action Mode:       $action_mode"
    echo "  Patterns Total:    $patterns_total"
    echo "  Patterns Enabled:  $patterns_enabled"
    echo "  Blocked (24h):     $blocked_24h"
    echo "  Blocked (Total):   $blocked_total"
    echo ""
}

# =============================================================================
# COMMAND: config
# =============================================================================

_nftban_botscan_cmd_config() {
    local json_mode="${1:-false}"
    local config_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/botscan/main.conf"
    local config_local="${config_file}.local"

    if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
        local data
        if command -v jq &>/dev/null; then
            data=$(jq -n \
                --arg config_file "$config_file" \
                --arg config_local "$config_local" \
                --arg local_exists "$([[ -f "$config_local" ]] && echo "true" || echo "false")" \
                --arg enabled "${BOTSCAN_ENABLED:-false}" \
                --arg action_mode "${BOTSCAN_ACTION_MODE:-both}" \
                --arg default_threshold "${BOTSCAN_DEFAULT_THRESHOLD:-5}" \
                --arg default_window "${BOTSCAN_DEFAULT_WINDOW:-60}" \
                '{
                    config_file: $config_file,
                    config_local: $config_local,
                    local_exists: ($local_exists == "true"),
                    settings: {
                        enabled: ($enabled == "true"),
                        action_mode: $action_mode,
                        default_threshold: ($default_threshold | tonumber),
                        default_window: ($default_window | tonumber)
                    }
                }')
        else
            data="{\"config_file\":\"$config_file\"}"
        fi
        json_output "true" "$data"
        return 0
    fi

    echo "Bot Scanner Configuration"
    echo "========================="
    echo ""
    echo "  Config File:    $config_file"
    echo "  Override File:  $config_local"
    if [[ -f "$config_local" ]]; then
        echo "  Status:         [Override Active]"
    else
        echo "  Status:         [Using defaults]"
    fi
    echo ""
    echo "Settings:"
    echo "  Enabled:        ${BOTSCAN_ENABLED:-false}"
    echo "  Action Mode:    ${BOTSCAN_ACTION_MODE:-both}"
    echo "  Threshold:      ${BOTSCAN_DEFAULT_THRESHOLD:-5} hits"
    echo "  Time Window:    ${BOTSCAN_DEFAULT_WINDOW:-60} seconds"
    echo "  404 Tracking:   ${BOTSCAN_404_TRACKING:-true}"
    echo "  404 Threshold:  ${BOTSCAN_404_THRESHOLD:-50}"
    echo ""
    echo "To override settings, create/edit: $config_local"
}

# =============================================================================
# COMMAND: enable
# =============================================================================

_nftban_botscan_cmd_enable() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: Requires root privileges" >&2
        return 1
    fi

    local config_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/botscan/main.conf"
    local config_local="${config_file}.local"

    # Ensure local config exists
    if [[ ! -f "$config_local" ]]; then
        mkdir -p "$(dirname "$config_local")" || return 1
        echo "# NFTBan Bot Scanner - User Overrides" > "$config_local"
        chmod 640 "$config_local"
        chown root:nftban "$config_local" 2>/dev/null || true
    fi

    # Persist BOTSCAN_ENABLED=true to local config override
    if grep -q "^BOTSCAN_ENABLED=" "$config_local" 2>/dev/null; then
        sed -i 's/^BOTSCAN_ENABLED=.*/BOTSCAN_ENABLED="true"/' "$config_local"
    else
        echo 'BOTSCAN_ENABLED="true"' >> "$config_local"
    fi

    echo "Bot scanner enabled"
    echo ""
    echo "Run 'nftban botscan check' to analyze current logs"
    echo "Run 'nftban botscan status' to verify configuration"
}

# =============================================================================
# COMMAND: disable
# =============================================================================

_nftban_botscan_cmd_disable() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: Requires root privileges" >&2
        return 1
    fi

    local config_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/botscan/main.conf"
    local config_local="${config_file}.local"

    # Ensure local config exists
    if [[ ! -f "$config_local" ]]; then
        mkdir -p "$(dirname "$config_local")" || return 1
        echo "# NFTBan Bot Scanner - User Overrides" > "$config_local"
        chmod 640 "$config_local"
        chown root:nftban "$config_local" 2>/dev/null || true
    fi

    # Persist BOTSCAN_ENABLED=false to local config override
    if grep -q "^BOTSCAN_ENABLED=" "$config_local" 2>/dev/null; then
        sed -i 's/^BOTSCAN_ENABLED=.*/BOTSCAN_ENABLED="false"/' "$config_local"
    else
        echo 'BOTSCAN_ENABLED="false"' >> "$config_local"
    fi

    echo "Bot scanner disabled"
}

# =============================================================================
# COMMAND: patterns
# =============================================================================

_nftban_botscan_cmd_patterns() {
    local action="${1:-list}"
    shift || true

    # Load core module for pattern functions
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_botscan.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_botscan.sh" || return 1
    else
        echo "ERROR: Bot scanner core module not found" >&2
        return 1
    fi

    case "$action" in
        list)
            local filter="${1:-all}"
            local category="${2:-}"
            echo "Bot Scanner Patterns"
            echo "===================="
            echo ""
            nftban_botscan_list_patterns "$filter" "$category"
            ;;
        add)
            if [[ $EUID -ne 0 ]]; then
                echo "ERROR: Requires root privileges" >&2
                return 1
            fi
            if [[ $# -lt 2 ]]; then
                echo "Usage: nftban botscan patterns add NAME PATTERN [MATCH_TYPE] [THRESHOLD] [WINDOW] [BAN] [DESCRIPTION]" >&2
                echo "" >&2
                echo "Example:" >&2
                echo "  nftban botscan patterns add MY_PATTERN 'evil\\.php' url-404 3 60 3600 'My custom pattern'" >&2
                return 1
            fi
            nftban_botscan_add_pattern "$@"
            ;;
        remove)
            if [[ $EUID -ne 0 ]]; then
                echo "ERROR: Requires root privileges" >&2
                return 1
            fi
            if [[ -z "${1:-}" ]]; then
                echo "Usage: nftban botscan patterns remove NAME" >&2
                return 1
            fi
            nftban_botscan_remove_pattern "$1"
            ;;
        enable)
            if [[ $EUID -ne 0 ]]; then
                echo "ERROR: Requires root privileges" >&2
                return 1
            fi
            if [[ -z "${1:-}" ]]; then
                echo "Usage: nftban botscan patterns enable NAME" >&2
                return 1
            fi
            nftban_botscan_toggle_pattern "$1" "enable"
            ;;
        disable)
            if [[ $EUID -ne 0 ]]; then
                echo "ERROR: Requires root privileges" >&2
                return 1
            fi
            if [[ -z "${1:-}" ]]; then
                echo "Usage: nftban botscan patterns disable NAME" >&2
                return 1
            fi
            nftban_botscan_toggle_pattern "$1" "disable"
            ;;
        *)
            echo "ERROR: Unknown patterns action: $action" >&2
            echo "Usage: nftban botscan patterns <list|add|remove|enable|disable>" >&2
            return 1
            ;;
    esac
}

# =============================================================================
# COMMAND: history
# =============================================================================

_nftban_botscan_cmd_history() {
    local lines="${1:-50}"
    local log_file="${NFTBAN_LOG_DIR:-/var/log/nftban}/botscan.log"

    _nftban_botscan_banner
    echo ""
    echo "Bot Scanner Detection History (last $lines entries)"
    echo ""

    if [[ ! -f "$log_file" ]]; then
        echo "  (no detections yet - log file not created)"
        echo ""
        echo "Log file: $log_file"
        return 0
    fi

    local banned_count
    banned_count=$(grep -c "BANNED" "$log_file" 2>/dev/null) || banned_count=0

    if [[ "$banned_count" -eq 0 ]]; then
        echo "  (no bans recorded yet)"
    else
        echo "Format: TIMESTAMP|SOURCE|IP|DURATION|ACTION|REASON"
        echo ""
        grep "BANNED" "$log_file" | tail -n "$lines" | sed 's/^/  /'
    fi

    echo ""
    echo "Total bans: $banned_count"
    echo "Log file: $log_file"
}

# =============================================================================
# COMMAND: test
# =============================================================================

_nftban_botscan_cmd_test() {
    local test_input="${1:-}"
    local test_type="${2:-}"

    _nftban_botscan_banner
    echo ""
    echo "Testing Bot Scanner Pattern Matching"
    echo ""

    # Load core module
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_botscan.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_botscan.sh" || return 1
    else
        echo "ERROR: Bot scanner core module not found" >&2
        return 1
    fi

    # Load patterns
    nftban_botscan_load_patterns

    echo "Loaded ${#_BOTSCAN_PATTERNS[@]} patterns"
    echo ""

    if [[ -n "$test_input" ]]; then
        if [[ "$test_type" == "ua" || "$test_type" == "useragent" ]]; then
            echo "Testing User-Agent: $test_input"
            echo ""
            local matched
            matched=$(nftban_botscan_match_url "/" "GET" "200" "$test_input") || matched=""
            if [[ -n "$matched" ]]; then
                echo "MATCH: Pattern '$matched' matched this User-Agent"
            else
                echo "NO MATCH: User-Agent did not match any pattern"
            fi
        else
            echo "Testing URL: $test_input"
            echo ""
            local matched
            matched=$(nftban_botscan_match_url "$test_input" "GET" "404" "") || matched=""
            if [[ -n "$matched" ]]; then
                echo "MATCH: Pattern '$matched' matched this URL"
            else
                echo "NO MATCH: URL did not match any pattern"
            fi
        fi
    else
        echo "Sample URL tests:"
        echo ""

        local test_urls=(
            "/shell.php"
            "/c99.php"
            "/wp-content/uploads/backdoor.php"
            "/jndi:\${env:AWS_SECRET}"
            "/.env"
            "/backup.sql"
            "/phpMyAdmin/index.php"
            "/favicon.ico"
            "/normal-page.html"
        )

        for url in "${test_urls[@]}"; do
            local matched
            matched=$(nftban_botscan_match_url "$url" "GET" "404" "") || matched=""
            if [[ -n "$matched" ]]; then
                printf "  %-40s -> MATCH (%s)\n" "$url" "$matched"
            else
                printf "  %-40s -> no match\n" "$url"
            fi
        done

        echo ""
        echo "Sample User-Agent tests:"
        echo ""

        local test_uas=(
            "Mozilla/5.0 (compatible; PetalBot;+https://webmaster.petalsearch.com/site/petalbot)"
            "Mozilla/5.0 (compatible; AwarioBot/1.0; +https://awario.com/bots.html)"
            "Mozilla/5.0 (compatible; GPTBot/1.0; +https://openai.com/gptbot)"
            "masscan/1.3"
            "sqlmap/1.5"
            "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0"
        )

        for ua in "${test_uas[@]}"; do
            local matched
            matched=$(nftban_botscan_match_url "/" "GET" "200" "$ua") || matched=""
            local display_ua="${ua:0:60}"
            [[ ${#ua} -gt 60 ]] && display_ua="${display_ua}..."
            if [[ -n "$matched" ]]; then
                printf "  %-63s -> MATCH (%s)\n" "$display_ua" "$matched"
            else
                printf "  %-63s -> no match\n" "$display_ua"
            fi
        done
    fi

    echo ""
    echo "Usage: nftban botscan test [URL|USER-AGENT] [ua]"
    echo "       Add 'ua' as second argument to test user-agent strings"
}

# =============================================================================
# MAIN COMMAND HANDLER
# =============================================================================

nftban_cmd_botscan() {
    local action="${1:-status}"
    local json_mode=false

    # Check for --json flag
    for arg in "$@"; do
        [[ "$arg" == "--json" ]] && json_mode=true && break
    done
    shift || true

    case "$action" in
        enable)
            _nftban_botscan_cmd_enable "$@"
            ;;

        disable)
            _nftban_botscan_cmd_disable "$@"
            ;;

        status)
            # Load core module for status
            if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_botscan.sh" ]]; then
                # shellcheck source=/dev/null
                source "${NFTBAN_LIB_DIR}/core/nftban_botscan.sh" || return 1
            else
                echo "ERROR: Bot scanner core module not found" >&2
                return 1
            fi
            _nftban_botscan_banner
            echo ""
            nftban_botscan_status
            ;;

        stats)
            _nftban_botscan_stats_json "$json_mode"
            ;;

        config)
            _nftban_botscan_cmd_config "$json_mode"
            ;;

        check)
            # Load core module for check
            if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_botscan.sh" ]]; then
                # shellcheck source=/dev/null
                source "${NFTBAN_LIB_DIR}/core/nftban_botscan.sh" || return 1
            else
                echo "ERROR: Bot scanner core module not found" >&2
                return 1
            fi
            _nftban_botscan_banner
            echo ""
            echo "Running bot scanner check..."
            echo ""
            nftban_botscan_check "$@"
            ;;

        patterns)
            _nftban_botscan_cmd_patterns "$@"
            ;;

        history)
            _nftban_botscan_cmd_history "$@"
            ;;

        test)
            _nftban_botscan_cmd_test "$@"
            ;;

        help|--help|-h)
            _nftban_botscan_help
            ;;

        *)
            echo "ERROR: Unknown command: $action" >&2
            echo ""
            echo "Available commands: enable, disable, status, stats, check, patterns, history, test, help"
            echo "Run 'nftban botscan help' for detailed usage information"
            return 1
            ;;
    esac

    return 0
}

# =============================================================================
# EXPORT FOR MAIN CLI
# =============================================================================

export -f nftban_cmd_botscan
export -f _nftban_botscan_banner
export -f _nftban_botscan_cmd_config
export -f _nftban_botscan_cmd_disable
export -f _nftban_botscan_cmd_enable
export -f _nftban_botscan_cmd_history
export -f _nftban_botscan_cmd_patterns
export -f _nftban_botscan_cmd_test
export -f _nftban_botscan_help
export -f _nftban_botscan_stats_json

# Execute if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_botscan "$@"
fi
