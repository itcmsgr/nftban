#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.30 - Bot Scanner Core Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Detect and block bot scanners, webshell probes, exploit attempts
#
# meta:name="nftban_botscan"
# meta:type="core"
# meta:header="Bot Scanner Detection Engine"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
# meta:description="Bot scanner detection using pattern matching on access logs"
# meta:inventory.files="/usr/lib/nftban/core/nftban_botscan.sh"
# meta:inventory.binaries="nft,grep,awk"
# meta:inventory.env_vars="BOTSCAN_ENABLED,BOTSCAN_PATTERNS_DIR"
# meta:inventory.config_files="/etc/nftban/conf.d/botscan/main.conf"
# meta:inventory.systemd_units="none"
# meta:inventory.network="none"
# meta:inventory.privileges="root:read-logs,nftables"
# meta:created_date="2026-01-11"
# meta:updated_date="2026-01-11"
# =============================================================================

# Enhanced strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_BOTSCAN_LOADED:-}" ]] && return 0
readonly NFTBAN_BOTSCAN_LOADED=1

# =============================================================================
# SHARED LIBRARIES
# =============================================================================

# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_timestamp.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_file_utils.sh" 2>/dev/null || true
# v1.177: shared panel-aware HTTP access-log discovery (DirectAdmin/cPanel/Plesk).
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_http_logs.sh" 2>/dev/null || true

# =============================================================================
# CONFIGURATION
# =============================================================================

# Load config if not already loaded
nftban_botscan_load_config() {
    local config_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/botscan/main.conf"
    local config_local="${config_file}.local"

    # Defaults
    : "${BOTSCAN_ENABLED:=true}"
    : "${BOTSCAN_ACTION_MODE:=both}"
    : "${BOTSCAN_LOG_AUTO:=true}"
    : "${BOTSCAN_LOG_APACHE:=/var/log/apache2/access.log}"
    : "${BOTSCAN_LOG_APACHE_ALT:=/var/log/httpd/access_log}"
    : "${BOTSCAN_LOG_NGINX:=/var/log/nginx/access.log}"
    # v1.177: optional multi-path/glob override (space/newline list). When set it is
    # preferred; if it resolves to no readable file we fall back to panel-aware
    # auto-detect (never silently blind). Legacy single-path vars above stay honored.
    : "${BOTSCAN_LOG_PATHS:=}"
    # v1.178-A: read-authority spool produced by nftban-botscan-collector.service.
    : "${BOTSCAN_SPOOL_DIR:=/run/nftban/botscan}"
    : "${BOTSCAN_DEFAULT_THRESHOLD:=5}"
    : "${BOTSCAN_DEFAULT_WINDOW:=60}"
    : "${BOTSCAN_DEFAULT_BAN_SHORT:=1800}"
    : "${BOTSCAN_DEFAULT_BAN_LONG:=7200}"
    : "${BOTSCAN_404_TRACKING:=true}"
    : "${BOTSCAN_404_THRESHOLD:=50}"
    : "${BOTSCAN_404_WINDOW:=300}"
    : "${BOTSCAN_404_BAN:=3600}"
    # v1.187 Lane A — BOTSCAN-SCAN-THROUGHPUT. Forward-cursor per-file per-cycle window
    # (drains backlog forward instead of the v1.185 64 KiB tail-bias), a C-speed candidate
    # prefilter before the per-line bash matcher, and an independent 404 fixed-tail re-read
    # window (Option 1) that preserves 404-burst detection the forward cursor would fragment.
    : "${BOTSCAN_SCAN_MAX_BYTES_PER_FILE:=1048576}"
    : "${BOTSCAN_SCAN_PREFILTER:=true}"
    : "${BOTSCAN_404_TAIL_BYTES:=2097152}"
    # v1.187.1 — per-cycle A4 404-tail total-bytes backstop (bounds budget=0/interactive runs;
    # the shared soft-deadline bounds normal cycles). Default 32 MiB.
    : "${BOTSCAN_404_TAIL_TOTAL_BYTES:=33554432}"
    : "${BOTSCAN_PROGRESSIVE_ENABLED:=true}"
    : "${BOTSCAN_PROGRESSIVE_MULTIPLIER:=2}"
    : "${BOTSCAN_PROGRESSIVE_MAX:=86400}"
    : "${BOTSCAN_PATTERNS_DIR:=${NFTBAN_CONFIG_DIR:-/etc/nftban}/patterns.d/botscan}"
    : "${BOTSCAN_WHITELIST_BOTS:=googlebot,bingbot,yandexbot,duckduckbot,slurp,facebot}"
    : "${BOTSCAN_WHITELIST_PATHS:=/robots\\.txt|/favicon\\.ico|/sitemap\\.xml|/ads\\.txt}"
    : "${BOTSCAN_USE_GLOBAL_WHITELIST:=true}"
    : "${BOTSCAN_STATE_FILE:=${NFTBAN_DATA_DIR:-/var/lib/nftban}/botscan-state.db}"
    : "${BOTSCAN_LOG_FILE:=${NFTBAN_LOG_DIR:-/var/log/nftban}/botscan.log}"
    : "${BOTSCAN_DEBUG:=false}"

    # Source config files
    # shellcheck source=/dev/null
    source "$config_file" 2>/dev/null || true
    # shellcheck source=/dev/null
    source "$config_local" 2>/dev/null || true
    return 0
}

# =============================================================================
# STATE MANAGEMENT
# =============================================================================

# Associative arrays for tracking
declare -gA _BOTSCAN_IP_HITS        # IP -> hit count
declare -gA _BOTSCAN_IP_PATTERNS    # IP -> matched patterns
declare -gA _BOTSCAN_IP_FIRST_SEEN  # IP -> first seen timestamp
declare -gA _BOTSCAN_IP_LAST_SEEN   # IP -> last seen timestamp
declare -gA _BOTSCAN_IP_404_COUNT      # IP -> 404 count
declare -gA _BOTSCAN_IP_404_FIRST_SEEN # IP -> 404 first seen timestamp
declare -gA _BOTSCAN_PATTERNS          # Pattern name -> pattern definition

# Initialize state
nftban_botscan_init_state() {
    _BOTSCAN_IP_HITS=()
    _BOTSCAN_IP_PATTERNS=()
    _BOTSCAN_IP_FIRST_SEEN=()
    _BOTSCAN_IP_LAST_SEEN=()
    _BOTSCAN_IP_404_COUNT=()
    _BOTSCAN_IP_404_FIRST_SEEN=()
}

# =============================================================================
# PATTERN MANAGEMENT
# =============================================================================

# Load patterns from file
# Format: NAME|PATTERN|MATCH_TYPE|THRESHOLD|WINDOW|BAN|ENABLED|DESCRIPTION
nftban_botscan_load_patterns() {
    local patterns_dir="${BOTSCAN_PATTERNS_DIR}"
    local pattern_count=0

    _BOTSCAN_PATTERNS=()

    # v1.188 B2 — 3-tier no-clobber precedence: shipped *.patterns (config(noreplace))
    # are the base; operator enable/disable decisions live in override.local
    # (NAME|true|false), which WINS over the shipped ENABLED column WITHOUT editing
    # the shipped files. override.local is operator-created (NOT package-owned), so
    # it survives DEB/RPM upgrades intact. Read first so per-pattern effective-enabled
    # can consult it. It is NOT a *.patterns file, so the glob below never loads it.
    local override_file="${patterns_dir}/override.local"
    local -A _override=()
    if [[ -r "$override_file" ]]; then
        local oname ostate
        while IFS='|' read -r oname ostate _; do
            [[ -z "$oname" || "$oname" =~ ^# ]] && continue
            oname="${oname// /}"; ostate="${ostate// /}"
            [[ "$ostate" == "true" || "$ostate" == "false" ]] && _override["$oname"]="$ostate"
        done < "$override_file"
    fi

    for pattern_file in "$patterns_dir"/*.patterns; do
        [[ -f "$pattern_file" ]] || continue

        while IFS='|' read -r name pattern match_type threshold window ban enabled description; do
            # Skip comments and empty lines
            [[ -z "$name" || "$name" =~ ^# ]] && continue

            # override.local wins over the shipped ENABLED column (no-clobber).
            local eff_enabled="${_override[$name]:-$enabled}"
            [[ "$eff_enabled" != "true" ]] && continue

            # Store pattern: name -> "pattern|match_type|threshold|window|ban|description"
            _BOTSCAN_PATTERNS["$name"]="${pattern}|${match_type}|${threshold}|${window}|${ban}|${description}"
            pattern_count=$((pattern_count + 1))

        done < "$pattern_file"
    done

    [[ "$BOTSCAN_DEBUG" == "true" ]] && echo "[DEBUG] Loaded $pattern_count patterns" >&2
    return 0
}

# List all patterns
nftban_botscan_list_patterns() {
    local filter="${1:-all}"  # all, enabled, disabled, category
    local category="${2:-}"

    printf "%-20s %-8s %-10s %-6s %-6s %-6s %s\n" "NAME" "ENABLED" "MATCH" "THRESH" "WINDOW" "BAN" "DESCRIPTION"
    printf "%s\n" "$(printf '=%.0s' {1..100})"

    for pattern_file in "$BOTSCAN_PATTERNS_DIR"/*.patterns; do
        [[ -f "$pattern_file" ]] || continue

        # Category filter
        if [[ -n "$category" ]]; then
            local file_category
            file_category=$(basename "$pattern_file" .patterns)
            [[ "$file_category" != "$category" ]] && continue
        fi

        while IFS='|' read -r name pattern match_type threshold window ban enabled description; do
            [[ -z "$name" || "$name" =~ ^# ]] && continue

            # Filter
            case "$filter" in
                enabled)  [[ "$enabled" != "true" ]] && continue ;;
                disabled) [[ "$enabled" == "true" ]] && continue ;;
            esac

            printf "%-20s %-8s %-10s %-6s %-6s %-6s %s\n" \
                "$name" "$enabled" "$match_type" "$threshold" "$window" "$ban" "${description:0:40}"

        done < "$pattern_file"
    done
}

# Add custom pattern
nftban_botscan_add_pattern() {
    local name="$1"
    local pattern="$2"
    local match_type="${3:-url-404}"
    local threshold="${4:-$BOTSCAN_DEFAULT_THRESHOLD}"
    local window="${5:-$BOTSCAN_DEFAULT_WINDOW}"
    local ban="${6:-$BOTSCAN_DEFAULT_BAN_SHORT}"
    local description="${7:-Custom pattern}"

    local custom_file="${BOTSCAN_PATTERNS_DIR}/custom.patterns"

    # Check if pattern already exists
    if grep -q "^${name}|" "$custom_file" 2>/dev/null; then
        echo "ERROR: Pattern '$name' already exists" >&2
        return 1
    fi

    # Add pattern
    echo "${name}|${pattern}|${match_type}|${threshold}|${window}|${ban}|true|${description}" >> "$custom_file"
    echo "Added pattern: $name"
    return 0
}

# Remove custom pattern
nftban_botscan_remove_pattern() {
    local name="$1"
    local custom_file="${BOTSCAN_PATTERNS_DIR}/custom.patterns"

    if ! grep -q "^${name}|" "$custom_file" 2>/dev/null; then
        echo "ERROR: Pattern '$name' not found in custom.patterns" >&2
        return 1
    fi

    # v1.19.0: Escape pattern name for safe sed usage (R23)
    local safe_name
    safe_name=$(printf '%s' "$name" | sed 's/[[\.*^$()+?{}|/]/\\&/g')
    sed -i "/^${safe_name}|/d" "$custom_file"
    echo "Removed pattern: $name"
    return 0
}

# Enable/disable pattern
nftban_botscan_toggle_pattern() {
    local name="$1"
    local action="$2"  # enable or disable
    local new_state

    [[ "$action" == "enable" ]] && new_state="true" || new_state="false"

    local found=0
    for pattern_file in "$BOTSCAN_PATTERNS_DIR"/*.patterns; do
        [[ -f "$pattern_file" ]] || continue

        if grep -q "^${name}|" "$pattern_file"; then
            # Toggle the enabled field (7th field)
            sed -i "s/^\(${name}|[^|]*|[^|]*|[^|]*|[^|]*|[^|]*|\)[^|]*/\1${new_state}/" "$pattern_file"
            echo "${action^}d pattern: $name"
            found=1
            break
        fi
    done

    [[ $found -eq 0 ]] && echo "ERROR: Pattern '$name' not found" >&2 && return 1
    return 0
}

# =============================================================================
# v1.188 B2 — BOT POLICY (bots / blockbot / allowbot) helpers
# =============================================================================

# Never-ban guard. These tokens must NEVER be hard-banned on User-Agent:
#   robots.txt-only control tokens (Google-Extended/Applebot-Extended have NO request
#   UA → a ban can never match; it is a category error), legitimate index UAs
#   (Googlebot/Bingbot/Applebot — banning delists the site), and user-action fetchers
#   (ChatGPT-User/Perplexity-User/Claude-User — a human triggered the fetch).
# Returns 0 (guarded) / 1 (not guarded). Case-insensitive substring match.
nftban_botscan_neverban_token() {
    local q; q=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
    [[ -z "$q" ]] && return 1
    local t
    for t in google-extended applebot-extended googlebot bingbot applebot \
             facebookexternalhit chatgpt-user perplexity-user claude-user; do
        [[ "$q" == *"$t"* ]] && return 0
    done
    return 1
}

# Resolve a user token (pattern NAME or UA substring, case-insensitive) to the
# canonical pattern NAME used as the override.local / loader key. Echoes NAME, or
# nothing + rc=1 if not found. Interactive-only (blockbot/allowbot), never hot-path.
nftban_botscan_resolve_name() {
    local q; q=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
    [[ -z "$q" ]] && return 1
    local f name pattern lc_name lc_pat
    for f in "${BOTSCAN_PATTERNS_DIR}"/*.patterns; do
        [[ -f "$f" ]] || continue
        while IFS='|' read -r name pattern _; do
            [[ -z "$name" || "$name" =~ ^# ]] && continue
            lc_name=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
            lc_pat=$(printf '%s' "$pattern" | tr '[:upper:]' '[:lower:]')
            if [[ "$q" == "$lc_name" || "$q" == "$lc_pat" ]]; then
                printf '%s' "$name"; return 0
            fi
        done < "$f"
    done
    return 1
}

# Write an enable/disable decision to override.local (3-tier no-clobber; NEVER edits
# the shipped config(noreplace) *.patterns). Args: NAME, state(true|false). The file
# is operator-created (not package-owned) so DEB/RPM upgrades never clobber it.
nftban_botscan_set_override() {
    local name="${1:-}" state="${2:-}"
    [[ -n "$name" && ( "$state" == "true" || "$state" == "false" ) ]] || return 2
    local dir="${BOTSCAN_PATTERNS_DIR}"
    local override_file="${dir}/override.local"
    mkdir -p "$dir" 2>/dev/null || true
    local tmp; tmp=$(mktemp "${override_file}.XXXXXX" 2>/dev/null) || return 1
    # carry forward all OTHER entries; replace any prior line for this name
    if [[ -r "$override_file" ]]; then
        grep -viE "^[[:space:]]*${name}[[:space:]]*\|" "$override_file" 2>/dev/null >> "$tmp" || true
    fi
    printf '%s|%s\n' "$name" "$state" >> "$tmp"
    mv -f "$tmp" "$override_file" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    return 0
}

# blockbot <token> — enable a bot pattern (operator opt-in) via override.local.
# Refuses never-ban tokens with an explanation. Resolves token→NAME.
nftban_botscan_blockbot() {
    local token="${1:-}"
    [[ -n "$token" ]] || { echo "Usage: nftban botscan blockbot <bot-name>" >&2; return 2; }
    if nftban_botscan_neverban_token "$token"; then
        echo "✗ Refusing to ban '$token': it is a never-ban token." >&2
        echo "  robots.txt-only (Google-Extended/Applebot-Extended) have no request UA to match;" >&2
        echo "  legitimate index UAs (Googlebot/Bingbot/Applebot) would delist the site;" >&2
        echo "  user-action fetchers (ChatGPT-User/Perplexity-User) are human-initiated. Not banned." >&2
        return 1
    fi
    local name; name=$(nftban_botscan_resolve_name "$token") || {
        echo "✗ Unknown bot '$token'. See: nftban botscan bots" >&2; return 1; }
    nftban_botscan_set_override "$name" "true" || { echo "✗ Could not write override for $name" >&2; return 1; }
    echo "✓ blockbot: $name enabled (override.local) — bans on next scan cycle."
    return 0
}

# allowbot <token> — disable a bot pattern (operator allow) via override.local.
nftban_botscan_allowbot() {
    local token="${1:-}"
    [[ -n "$token" ]] || { echo "Usage: nftban botscan allowbot <bot-name>" >&2; return 2; }
    local name; name=$(nftban_botscan_resolve_name "$token") || {
        echo "✗ Unknown bot '$token'. See: nftban botscan bots" >&2; return 1; }
    nftban_botscan_set_override "$name" "false" || { echo "✗ Could not write override for $name" >&2; return 1; }
    echo "✓ allowbot: $name disabled (override.local) — no longer banned."
    return 0
}

# bots [category] [--enabled|--disabled] — friendly category listing (override-aware).
# Shows the EFFECTIVE enabled state (shipped ENABLED column overridden by override.local).
nftban_botscan_bots() {
    local category="" filter="all" a
    for a in "$@"; do
        case "$a" in
            --enabled)  filter="enabled" ;;
            --disabled) filter="disabled" ;;
            scanner|badbots|aibots|custom|webshell|exploit) category="$a" ;;
        esac
    done
    # Load effective state via the override-aware loader.
    nftban_botscan_load_patterns >/dev/null 2>&1
    local override_file="${BOTSCAN_PATTERNS_DIR}/override.local"
    local -A _ov=()
    if [[ -r "$override_file" ]]; then
        local on os
        while IFS='|' read -r on os _; do
            [[ -z "$on" || "$on" =~ ^# ]] && continue
            _ov["${on// /}"]="${os// /}"
        done < "$override_file"
    fi
    printf "%-22s %-9s %-9s %-10s %s\n" "NAME" "CATEGORY" "EFFECTIVE" "MATCH" "DESCRIPTION"
    printf '%s\n' "$(printf '=%.0s' {1..92})"
    local f cat name pattern match_type threshold window ban enabled description eff
    for f in "${BOTSCAN_PATTERNS_DIR}"/*.patterns; do
        [[ -f "$f" ]] || continue
        cat=$(basename "$f" .patterns)
        [[ -n "$category" && "$cat" != "$category" ]] && continue
        while IFS='|' read -r name pattern match_type threshold window ban enabled description; do
            [[ -z "$name" || "$name" =~ ^# ]] && continue
            eff="${_ov[$name]:-$enabled}"
            case "$filter" in
                enabled)  [[ "$eff" != "true" ]] && continue ;;
                disabled) [[ "$eff" == "true" ]] && continue ;;
            esac
            local mark="$eff"; [[ -n "${_ov[$name]:-}" ]] && mark="${eff}*"
            printf "%-22s %-9s %-9s %-10s %s\n" "$name" "$cat" "$mark" "$match_type" "${description:0:38}"
        done < "$f"
    done
    echo ""
    echo "  EFFECTIVE '*' = set by override.local (your blockbot/allowbot decision)."
    return 0
}

# =============================================================================
# LOG PARSING
# =============================================================================

# Find access log
# v1.177: full panel-aware discovery — emits ALL access logs to scan (one per line),
# deduped. Source order: BOTSCAN_LOG_PATHS override / panel-aware auto (shared helper)
# PLUS the legacy single-path vars as an existence-filtered back-compat safety net.
nftban_botscan_discover_logs() {
    local -a logs=()
    local f
    # v1.178-A read-authority: SPOOL-FIRST. If the separate privileged collector
    # (nftban-botscan-collector.service, CAP_DAC_READ_SEARCH) produced a spool, the
    # unprivileged scanner reads ONLY the spool — it already holds the privileged-read
    # content the scanner cannot obtain directly on DA/cPanel/0640 hosts. If no spool
    # (collector absent/empty), fall back to direct discovery (legacy behavior; will
    # report DEGRADED on blocked hosts via the v1.177 diagnostic).
    local _spool="${BOTSCAN_SPOOL_DIR:-/run/nftban/botscan}"
    if [[ -d "$_spool" ]]; then
        local -a _sp=()
        for f in "$_spool"/*; do [[ -f "$f" && -r "$f" && -s "$f" ]] && _sp+=("$f"); done
        if [[ ${#_sp[@]} -gt 0 ]]; then printf '%s\n' "${_sp[@]}"; return 0; fi
    fi
    if declare -F nftban_http_discover_access_logs >/dev/null 2>&1; then
        while IFS= read -r f; do [[ -n "$f" ]] && logs+=("$f"); done \
            < <(nftban_http_discover_access_logs "${BOTSCAN_LOG_PATHS:-}")
    fi
    # Legacy single-file vars (back-compat; honors a custom-pointed path).
    for f in "$BOTSCAN_LOG_NGINX" "$BOTSCAN_LOG_APACHE" "$BOTSCAN_LOG_APACHE_ALT"; do
        [[ -n "$f" && -f "$f" && -r "$f" ]] && logs+=("$f")
    done
    [[ ${#logs[@]} -eq 0 ]] && return 1
    # Dedup, preserve order.
    local -A seen=(); local -a uniq=()
    for f in "${logs[@]}"; do [[ -n "${seen[$f]:-}" ]] && continue; seen[$f]=1; uniq+=("$f"); done
    printf '%s\n' "${uniq[@]}"
    return 0
}

# Back-compat single-path finder (status display, optional arg default). Returns
# the first discovered log, or "" if none.
nftban_botscan_find_log() {
    nftban_botscan_discover_logs 2>/dev/null | head -1
}

# Parse access log line
# Returns: IP|URL|METHOD|STATUS|USER_AGENT
# v1.187.1 — NO-FORK parser. Sets the globals _BS_IP/_BS_URL/_BS_METHOD/_BS_STATUS/_BS_UA
# and returns 0 (parsed) / 1 (no match). The hot scan loops call THIS directly so a busy
# host no longer forks a subshell per log line (the v1.187.1 cycle-timeout fix: a 4.2 MB DA
# log was ~123s / 5497 lines = ~22 ms/line, dominated by per-line command-substitution forks
# — parse + match + timestamp). Regex semantics are byte-identical to the previous version.
nftban_botscan_parse_line_g() {
    local line="$1"

    # Combined Log Format: IP - - [date] "METHOD URL PROTO" STATUS SIZE "REFERER" "UA"
    # IPv4 and IPv6 compatible (v1.19.0, v1.19.12 bracket fix R22)
    # Handles: 192.168.1.1, 2001:db8::1, [2001:db8::1]:8080
    if [[ "$line" =~ ^\[?([0-9a-fA-F.:]+)\]?.*\"([A-Z]+)\ ([^\"\ ]+).*\"\ ([0-9]+) ]]; then
        _BS_IP="${BASH_REMATCH[1]}"
        _BS_METHOD="${BASH_REMATCH[2]}"
        _BS_URL="${BASH_REMATCH[3]}"
        _BS_STATUS="${BASH_REMATCH[4]}"

        # Extract user agent
        if [[ "$line" =~ \"([^\"]+)\"$ ]]; then
            _BS_UA="${BASH_REMATCH[1]}"
        else
            _BS_UA="-"
        fi

        return 0
    fi

    return 1
}

# Echo-API wrapper — UNCHANGED output contract (IP|URL|METHOD|STATUS|UA). Used by
# cmd_botscan (emulate) and existing tests. Delegates to the no-fork parser so the two
# can never drift.
nftban_botscan_parse_line() {
    nftban_botscan_parse_line_g "$1" || return 1
    echo "${_BS_IP}|${_BS_URL}|${_BS_METHOD}|${_BS_STATUS}|${_BS_UA}"
}

# Check if IP is whitelisted — v1.19.0: IPv4/IPv6 parity
nftban_botscan_is_whitelisted() {
    local ip="$1"
    local ua="${2:-}"

    # Localhost (both families)
    [[ "$ip" == "127.0.0.1" || "$ip" == "::1" ]] && return 0

    # Private networks (both families — never ban internal traffic)
    [[ "$ip" =~ ^10\. ]] && return 0
    [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
    [[ "$ip" =~ ^192\.168\. ]] && return 0
    [[ "$ip" =~ ^[Ff][CcDd] ]] && return 0
    [[ "$ip" =~ ^[Ff][Ee]80: ]] && return 0

    # Check global whitelist
    if [[ "$BOTSCAN_USE_GLOBAL_WHITELIST" == "true" ]]; then
        if type -t nftban_is_whitelisted &>/dev/null; then
            nftban_is_whitelisted "$ip" && return 0
        fi
    fi

    # Check bot whitelist (user agent)
    if [[ -n "$ua" ]]; then
        # IFS-safe split: strict.sh sets IFS=$'\n\t', so space-separated vars need explicit splitting
        local bot _whitelist_bots
        IFS=' ' read -ra _whitelist_bots <<< "${BOTSCAN_WHITELIST_BOTS//,/ }"
        for bot in "${_whitelist_bots[@]}"; do
            if [[ "${ua,,}" =~ ${bot,,} ]]; then
                return 0
            fi
        done
    fi

    return 1
}

# Check if URL is whitelisted
nftban_botscan_is_path_whitelisted() {
    local url="$1"

    if [[ "$url" =~ $BOTSCAN_WHITELIST_PATHS ]]; then
        return 0
    fi

    return 1
}

# =============================================================================
# DETECTION ENGINE
# =============================================================================

# Match URL against patterns
# Returns: matched pattern name or empty
# v1.187.1 — NO-FORK matcher. Sets _BS_MATCHED to the matched pattern name ("" if none) and
# returns 0 (match) / 1 (no match). Same iteration order + match-type semantics as the echo
# API; called directly from the hot path (process_entry) to drop the per-line subshell fork.
nftban_botscan_match_url_g() {
    local url="$1"
    local method="$2"
    local status="$3"
    local ua="${4:-}"
    _BS_MATCHED=""

    local name def pattern match_type
    for name in "${!_BOTSCAN_PATTERNS[@]}"; do
        def="${_BOTSCAN_PATTERNS[$name]}"

        IFS='|' read -r pattern match_type _ _ _ _ <<< "$def"

        # Check match type
        case "$match_type" in
            url-404)
                [[ "$status" != "404" ]] && continue
                # Match URL pattern
                if [[ "$url" =~ $pattern ]]; then _BS_MATCHED="$name"; return 0; fi
                ;;
            url-post)
                [[ "$method" != "POST" ]] && continue
                if [[ "$url" =~ $pattern ]]; then _BS_MATCHED="$name"; return 0; fi
                ;;
            url-get)
                [[ "$method" != "GET" ]] && continue
                if [[ "$url" =~ $pattern ]]; then _BS_MATCHED="$name"; return 0; fi
                ;;
            url-any)
                if [[ "$url" =~ $pattern ]]; then _BS_MATCHED="$name"; return 0; fi
                ;;
            useragent)
                # Match against user-agent string
                if [[ -n "$ua" && "$ua" =~ $pattern ]]; then _BS_MATCHED="$name"; return 0; fi
                ;;
        esac
    done

    return 1
}

# Echo-API wrapper — UNCHANGED contract (echoes the matched pattern name, returns 1 on no
# match). Used by cmd_botscan (emulate). Delegates to the no-fork matcher.
nftban_botscan_match_url() {
    nftban_botscan_match_url_g "$@" || return 1
    echo "$_BS_MATCHED"
}

# Process log entry
nftban_botscan_process_entry() {
    local ip="$1"
    local url="$2"
    local method="$3"
    local status="$4"
    local ua="$5"
    # v1.187.1 — fork-free per-line timestamp (was now=$(nftban_timestamp_unix||date), a third
    # subshell fork per log line). printf '%(%s)T' is a bash builtin (4.2+, all targets 5.x);
    # falls back to the old fork only on ancient bash. Same epoch-seconds value.
    local now
    printf -v now '%(%s)T' -1 2>/dev/null || now=$(nftban_timestamp_unix 2>/dev/null || date +%s)

    # Check whitelists
    nftban_botscan_is_whitelisted "$ip" "$ua" && return 0
    nftban_botscan_is_path_whitelisted "$url" && return 0

    # Track 404s
    if [[ "$BOTSCAN_404_TRACKING" == "true" && "$status" == "404" ]]; then
        _BOTSCAN_IP_404_COUNT["$ip"]=$(( ${_BOTSCAN_IP_404_COUNT[$ip]:-0} + 1 ))
        [[ -z "${_BOTSCAN_IP_404_FIRST_SEEN[$ip]:-}" ]] && _BOTSCAN_IP_404_FIRST_SEEN["$ip"]="$now"
    fi

    # Match against patterns (URL and user-agent) — v1.187.1 no-fork matcher (was a per-line
    # command-substitution fork). errexit-safe: the && only assigns on a match.
    local matched_pattern=""
    nftban_botscan_match_url_g "$url" "$method" "$status" "$ua" && matched_pattern="$_BS_MATCHED"

    if [[ -n "$matched_pattern" ]]; then
        # Update tracking
        _BOTSCAN_IP_HITS["$ip"]=$(( ${_BOTSCAN_IP_HITS[$ip]:-0} + 1 ))
        _BOTSCAN_IP_PATTERNS["$ip"]="${_BOTSCAN_IP_PATTERNS[$ip]:-} $matched_pattern"
        _BOTSCAN_IP_LAST_SEEN["$ip"]="$now"
        [[ -z "${_BOTSCAN_IP_FIRST_SEEN[$ip]:-}" ]] && _BOTSCAN_IP_FIRST_SEEN["$ip"]="$now"

        [[ "$BOTSCAN_DEBUG" == "true" ]] && echo "[DEBUG] $ip matched $matched_pattern: $url" >&2
    fi

    return 0
}

# Analyze tracked IPs and ban if threshold exceeded
nftban_botscan_analyze() {
    local now
    now=$(nftban_timestamp_unix 2>/dev/null || date +%s)
    local banned=0

    for ip in "${!_BOTSCAN_IP_HITS[@]}"; do
        local hits="${_BOTSCAN_IP_HITS[$ip]}"
        local first_seen="${_BOTSCAN_IP_FIRST_SEEN[$ip]:-$now}"
        local time_window=$((now - first_seen))
        local patterns="${_BOTSCAN_IP_PATTERNS[$ip]:-}"

        # Get threshold from most severe matched pattern
        local threshold="$BOTSCAN_DEFAULT_THRESHOLD"
        local ban_duration="$BOTSCAN_DEFAULT_BAN_SHORT"
        local window="$BOTSCAN_DEFAULT_WINDOW"

        # Split the space-joined matched-pattern list IFS-INDEPENDENTLY. The lib sets a
        # global IFS=$'\n\t' (no space) at source time, so an unquoted `for x in $patterns`
        # over " NAME" keeps the leading space → key lookup misses → the pattern threshold
        # is never applied → URL/UA pattern bans never fire (only 404-flood did). Use the
        # same `IFS=$' \t\n' read -ra` idiom already used for the http-log override split.
        local -a _ip_pats=()
        IFS=$' \t\n' read -ra _ip_pats <<< "$patterns"
        for pattern_name in "${_ip_pats[@]}"; do
            [[ -z "$pattern_name" ]] && continue
            local def="${_BOTSCAN_PATTERNS[$pattern_name]:-}"
            [[ -z "$def" ]] && continue

            local p_threshold p_window p_ban
            IFS='|' read -r _ _ p_threshold p_window p_ban _ <<< "$def"

            # Use lowest threshold (most sensitive)
            [[ "$p_threshold" -lt "$threshold" ]] && threshold="$p_threshold"
            # Use longest ban
            [[ "$p_ban" -gt "$ban_duration" ]] && ban_duration="$p_ban"
            # Use shortest window
            [[ "$p_window" -lt "$window" ]] && window="$p_window"
        done

        # Check threshold
        if [[ "$hits" -ge "$threshold" && "$time_window" -le "$window" ]]; then
            nftban_botscan_ban_ip "$ip" "$ban_duration" "botscan" "Matched patterns: $patterns (hits: $hits)"
            banned=$((banned + 1))
        fi
    done

    # Check 404 flood (enforce BOTSCAN_404_WINDOW)
    if [[ "$BOTSCAN_404_TRACKING" == "true" ]]; then
        local now_ts
        now_ts=$(date +%s)
        for ip in "${!_BOTSCAN_IP_404_COUNT[@]}"; do
            local count="${_BOTSCAN_IP_404_COUNT[$ip]}"
            local first_seen="${_BOTSCAN_IP_404_FIRST_SEEN[$ip]:-$now_ts}"
            local elapsed=$(( now_ts - first_seen ))
            if [[ "$count" -ge "$BOTSCAN_404_THRESHOLD" && "$elapsed" -le "$BOTSCAN_404_WINDOW" ]]; then
                nftban_botscan_ban_ip "$ip" "$BOTSCAN_404_BAN" "botscan-404" "404 flood: $count in ${elapsed}s"
                banned=$((banned + 1))
            fi
        done
    fi

    return $banned
}

# v1.187 Lane A — build a C-speed candidate prefilter (ERE) from the ENABLED patterns
# plus a 404-status keeper, into file $1. A line is a CANDIDATE if it could match ANY
# enabled pattern OR (when 404-tracking is on) carries a 404 status. The filter is a
# SOUND SUPERSET of the accurate bash matcher: patterns are emitted as ERE (same engine
# semantics as the matcher's `[[ =~ ]]`) with line-anchors (^ $) stripped so a URL/UA-
# anchored pattern still matches its field anywhere inside the WHOLE log line (broadening
# only). GNU grep -E is DFA-based → linear time, so this cannot ReDoS-stall (the bash
# regex matcher then runs only on the surviving candidates). Returns non-zero (→ caller
# skips the prefilter, no behavior change) when there is nothing to filter on.
nftban_botscan_build_prefilter() {
    local out="$1"
    : > "$out" 2>/dev/null || return 1
    local n=0 name def pat
    for name in "${!_BOTSCAN_PATTERNS[@]}"; do
        def="${_BOTSCAN_PATTERNS[$name]}"
        IFS='|' read -r pat _ _ _ _ _ <<< "$def"
        [[ -z "$pat" ]] && continue
        pat="${pat#^}"; pat="${pat%\$}"   # strip line-anchors → match the field within the line
        [[ -z "$pat" ]] && continue
        printf '%s\n' "$pat" >> "$out"
        n=$((n + 1))
    done
    if [[ "${BOTSCAN_404_TRACKING:-true}" == "true" ]]; then
        # Keep every 404-status line (common/combined format: "...REQUEST..." 404 <bytes>),
        # independent of patterns, so the 404-flood path never loses candidates.
        printf '%s\n' '" 404 ' >> "$out"
        printf '%s\n' ' 404 ' >> "$out"
        n=$((n + 1))
    fi
    [[ "$n" -gt 0 ]]
}

# v1.187 Lane A / v1.187.1 — 404-window OPTION 1 (fixed-tail re-read), INDEPENDENT of the
# forward processor cursor (does NOT read/advance its offset). Re-reads a bounded tail of
# each file, prefilters to 404 lines (C-speed), counts per-IP 404s into analyze()'s arrays.
# v1.187.1 BOUNDS this stage (v1.187.0 A4 was unbounded → srv2 126-log/131MB cycle blew past
# TimeoutStartSec=300; `V1_187_1_BOTSCAN_404_TAIL_BOUND_HOTFIX_SCOPE.md`):
#   (1) shares the cycle soft-deadline (start_secs + BOTSCAN_SCAN_BUDGET_SECS) — checked
#       BETWEEN files, breaks cleanly (always processing ≥1 file so 404 coverage + rotation
#       make forward progress even when the main loop consumed most of the budget);
#   (2) a per-cycle total-bytes backstop (BOTSCAN_404_TAIL_TOTAL_BYTES) for budget=0 runs;
#   (3) an anti-starvation rotation cursor (404-rotate, separate from the main scan-rotate)
#       so every file's 404 tail is covered across successive cycles.
# 404-flood detection is preserved: each scanned file's full tail is counted; rotation +
# the (steady-state) freed budget cover the rest across cycles. Honors the whitelists.
# Args: <start_secs> <budget_secs> -- <file>...
nftban_botscan_count_404_tail() {
    [[ "${BOTSCAN_404_TRACKING:-true}" == "true" ]] || return 0
    local start_secs="${1:-$SECONDS}" budget="${2:-0}"; shift 2
    local now; now=$(nftban_timestamp_unix 2>/dev/null || date +%s)
    local tail_bytes="${BOTSCAN_404_TAIL_BYTES:-2097152}"
    local max_total="${BOTSCAN_404_TAIL_TOTAL_BYTES:-33554432}"
    # Reset so the count reflects ONLY this cycle's scanned tails.
    _BOTSCAN_IP_404_COUNT=()
    _BOTSCAN_IP_404_FIRST_SEEN=()
    local files=("$@")
    local n=${#files[@]}
    [[ "$n" -eq 0 ]] && return 0
    # Anti-starvation rotation cursor (next cycle resumes where this one stopped).
    local rot_file="${NFTBAN_DATA_DIR:-/var/lib/nftban}/botscan/404-rotate" rot=0
    mkdir -p "${rot_file%/*}" 2>/dev/null || true
    [[ -r "$rot_file" ]] && IFS= read -r rot < "$rot_file" 2>/dev/null
    [[ "$rot" =~ ^[0-9]+$ ]] || rot=0
    rot=$(( rot % n ))
    local consumed=0 covered=0 i idx f line
    for (( i=0; i<n; i++ )); do
        # Shared cycle soft-deadline — but always cover ≥1 file (forward 404 progress + rotation).
        if [[ "$covered" -gt 0 && "$budget" -gt 0 && $(( SECONDS - start_secs )) -ge "$budget" ]]; then break; fi
        # Per-cycle total-bytes backstop (bounds budget=0 / interactive runs); ≥1 file always.
        if [[ "$covered" -gt 0 && "$max_total" -gt 0 && "$consumed" -ge "$max_total" ]]; then break; fi
        idx=$(( (rot + i) % n ))
        f="${files[$idx]}"
        covered=$(( covered + 1 ))
        [[ -f "$f" && -r "$f" ]] || continue
        consumed=$(( consumed + tail_bytes ))
        while IFS= read -r line; do
            nftban_botscan_parse_line_g "$line" || continue   # v1.187.1 no-fork
            [[ "$_BS_STATUS" == "404" ]] || continue
            nftban_botscan_is_whitelisted "$_BS_IP" "$_BS_UA" && continue
            nftban_botscan_is_path_whitelisted "$_BS_URL" && continue
            _BOTSCAN_IP_404_COUNT["$_BS_IP"]=$(( ${_BOTSCAN_IP_404_COUNT[$_BS_IP]:-0} + 1 ))
            [[ -z "${_BOTSCAN_IP_404_FIRST_SEEN[$_BS_IP]:-}" ]] && _BOTSCAN_IP_404_FIRST_SEEN["$_BS_IP"]="$now"
        done < <( tail -c "$tail_bytes" -- "$f" 2>/dev/null | LC_ALL=C grep -E '" 404 | 404 ' 2>/dev/null || true )
    done
    # Persist rotation: next cycle starts after the last file covered this cycle.
    printf '%s\n' "$(( (rot + covered) % n ))" > "${rot_file}.tmp" 2>/dev/null && mv -f "${rot_file}.tmp" "$rot_file" 2>/dev/null || true
    return 0
}

# Write a batch signal to JSONL for Go daemon (Clock 2) consumption
# Args: ip, score, action, reasons...
nftban_botscan_write_signal() {
    local ip="$1"
    local score="$2"
    local action="$3"
    shift 3
    local reasons=("$@")

    local signal_file="${BOTSCAN_BATCH_SIGNAL_FILE:-${NFTBAN_DATA_DIR:-/var/lib/nftban}/botguard/batch_signals.jsonl}"

    # Build JSON reasons array
    local reasons_json="["
    local first=true
    for r in "${reasons[@]}"; do
        if [[ "$first" == "true" ]]; then
            reasons_json+="\"${r//\"/\\\"}\""
            first=false
        else
            reasons_json+=",\"${r//\"/\\\"}\""
        fi
    done
    reasons_json+="]"

    local ts
    ts=$(date +%s)

    # Atomic append (single write, no partial lines)
    printf '{"ip":"%s","score":%d,"reasons":%s,"action":"%s","ts":%d}\n' \
        "${ip//\"/\\\"}" "$score" "$reasons_json" "${action//\"/\\\"}" "$ts" \
        >> "$signal_file"
}

# Ban IP
nftban_botscan_ban_ip() {
    local ip="$1"
    local duration="$2"
    local source="$3"
    local reason="$4"

    [[ "$BOTSCAN_ACTION_MODE" == "alert" ]] && {
        echo "[ALERT] Would ban $ip for ${duration}s: $reason"
        return 0
    }

    # Clock 3 batch signal mode: write JSONL for Go daemon instead of direct ban
    if [[ "${BOTSCAN_BATCH_SIGNAL_MODE:-false}" == "true" ]]; then
        local score=80
        local action="ban"
        # Shorter bans → grey instead of ban
        if [[ "$duration" -le 1800 ]]; then
            score=50
            action="grey"
        fi
        nftban_botscan_write_signal "$ip" "$score" "$action" "$source" "$reason"
        echo "$(date -Iseconds)|$source|$ip|${duration}|SIGNAL|$reason" >> "$BOTSCAN_LOG_FILE"
        return 0
    fi

    # Direct ban mode (legacy/standalone)
    if type -t nftban_ban &>/dev/null; then
        nftban_ban "$ip" "$duration" "$source" "$reason"
    elif [[ -x "${NFTBAN_BIN:-/usr/sbin/nftban}" ]]; then
        "${NFTBAN_BIN:-/usr/sbin/nftban}" ban "$ip" --duration "$duration" --source "$source" --reason "$reason" 2>/dev/null
    else
        echo "[ERROR] Cannot ban $ip - nftban not available" >&2
        return 1
    fi

    # Log
    echo "$(date -Iseconds)|$source|$ip|${duration}|BANNED|$reason" >> "$BOTSCAN_LOG_FILE"

    return 0
}

# =============================================================================
# MAIN FUNCTIONS
# =============================================================================

# Process logs (main entry point)
nftban_botscan_process_logs() {
    local log_file="${1:-}"
    local time_window="${2:-60}"

    [[ "$BOTSCAN_ENABLED" != "true" ]] && {
        echo "Bot scanner is disabled"
        return 0
    }

    # v1.177: discover ALL panel-aware access logs (multi-log), not just the first.
    # An explicit single arg still pins one file (back-compat / tests).
    local -a logs=()
    local f
    if [[ -n "$log_file" ]]; then
        logs+=("$log_file")
    else
        while IFS= read -r f; do [[ -n "$f" ]] && logs+=("$f"); done < <(nftban_botscan_discover_logs)
        if [[ ${#logs[@]} -eq 0 ]]; then
            echo "ERROR: No access log found" >&2
            echo "  Hint: run 'nftban botscan logs --detect' to see candidate paths and panel detection." >&2
            echo "  Or set BOTSCAN_LOG_PATHS in /etc/nftban/conf.d/botscan/main.conf to your access-log glob(s)." >&2
            return 1
        fi
    fi

    # Initialize
    nftban_botscan_init_state
    nftban_botscan_load_patterns

    echo "Processing: ${#logs[@]} access log(s)"
    echo "Patterns loaded: ${#_BOTSCAN_PATTERNS[@]}"

    # v1.185 CORE-BOTSCAN-PROCESSOR-TIMEOUT-AT-SCALE — DEADLINE-AWARE SELF-BOUND.
    # Fleet-proven failure: on high-ENTRY-VOLUME hosts (srv2 120 logs 0/53, srv4 17 logs
    # 0/46, dns2 5 logs 0/55 — VOLUME, not file count) one cycle's burst × 137-pattern
    # matching can't finish before the systemd TimeoutStartSec SIGTERM, so analyze/ban
    # (below) never runs and BotScan bans nothing. Fix = bound the WORK per cycle so the
    # scan finishes and BANS cleanly before the kill, and resumes next cycle:
    #   (1) per-file read cap (NFTBAN_HTTP_LOG_MAX_BYTES, scoped here to the botscan scan)
    #       so each WHOLE file's chunk is bounded and always fully processed in this cycle
    #       — the cursor's offset then correctly reflects processed bytes (no within-file
    #       break, which would strand emitted-but-unconsumed bytes since the shared reader
    #       commits offset=size on READ);
    #   (2) a SOFT time budget (BOTSCAN_SCAN_BUDGET_SECS; 0 = unlimited for interactive
    #       `botscan check`) checked BETWEEN files — stop cleanly at a file boundary;
    #   (3) anti-starvation rotation so every file is scanned across successive cycles.
    # KNOWN LIMITATION (follow-up, NOT v1.185 — touches the shared reader, out of locked
    # scope): under sustained traffic exceeding the per-file cap each cycle the shared
    # reader is tail-biased (processes newest, advances offset to size), so the oldest
    # over-cap bytes of that cycle are not scanned. v1.185 fixes the never-completes/
    # never-bans class; full zero-loss is a separate shared-reader lane.
    local budget="${BOTSCAN_SCAN_BUDGET_SECS:-0}"
    local start_secs=$SECONDS
    local deadline_hit=0
    # Bound each file's per-cycle read so a single whole file is always processable inside a
    # budget slice. v1.187.1 lowered the default 1 MiB → 256 KiB (~1.3k lines) as a cheap
    # time backstop: combined with the no-fork parse/match path a 256 KiB slice processes in
    # well under a second, so no single file can push the cycle toward TimeoutStartSec even on
    # a 126-log/921 MB DA host. The rotation cursor still covers every file across cycles.
    # Scoped to this scan process only — the privileged collector keeps its own (larger) cap.
    # Only narrow it (never widen a caller-set smaller value).
    local _scan_cap="${BOTSCAN_SCAN_MAX_BYTES_PER_FILE:-262144}"
    if [[ -z "${NFTBAN_HTTP_LOG_MAX_BYTES:-}" || "${NFTBAN_HTTP_LOG_MAX_BYTES}" -gt "$_scan_cap" ]]; then
        export NFTBAN_HTTP_LOG_MAX_BYTES="$_scan_cap"
    fi
    # v1.187 Lane A — FORWARD cursor on a DEDICATED offset dir (distinct offset semantics,
    # and distinct from the collector's offsets) so the scanner drains a backlog FORWARD
    # across cycles instead of tail-skipping. Auto-discovered incremental path only (an
    # explicit pinned log_file / interactive `check` keeps the simple tail read).
    if [[ -z "$log_file" ]]; then
        export NFTBAN_HTTP_LOG_READ_FORWARD=true
        export NFTBAN_HTTP_LOG_OFFSET_DIR="${NFTBAN_DATA_DIR:-/var/lib/nftban}/botscan/proc-offsets"
    fi
    # v1.187 Lane A — build the C-speed candidate prefilter once for this cycle.
    local _pf=""
    if [[ "${BOTSCAN_SCAN_PREFILTER:-true}" == "true" ]]; then
        _pf="$(mktemp 2>/dev/null)" || _pf=""
        [[ -n "$_pf" ]] && { nftban_botscan_build_prefilter "$_pf" || { rm -f "$_pf"; _pf=""; }; }
    fi
    # Anti-starvation rotation: persist where the last cycle stopped so a host whose
    # backlog exceeds one budget still scans EVERY file over successive cycles instead
    # of always draining the first files and starving the tail.
    local rot_file="${NFTBAN_DATA_DIR:-/var/lib/nftban}/botscan/scan-rotate"
    local n=${#logs[@]} rot=0
    if [[ -z "$log_file" && "$n" -gt 0 ]]; then
        mkdir -p "${rot_file%/*}" 2>/dev/null || true
        [[ -r "$rot_file" ]] && IFS= read -r rot < "$rot_file" 2>/dev/null
        [[ "$rot" =~ ^[0-9]+$ ]] || rot=0
        rot=$(( rot % n ))
    fi

    local processed=0 files_done=0 i idx f
    for (( i=0; i<n; i++ )); do
        # Deadline check BETWEEN files only (clean boundary). A whole file is always read+
        # processed atomically so the cursor offset reflects exactly what was processed;
        # never break mid-file (that would strand emitted-but-unconsumed bytes).
        if [[ "$budget" -gt 0 && $(( SECONDS - start_secs )) -ge "$budget" ]]; then
            deadline_hit=1; break
        fi
        idx=$(( (rot + i) % n ))
        f="${logs[$idx]}"
        while IFS= read -r line; do
            nftban_botscan_parse_line_g "$line" || continue   # v1.187.1 no-fork (was $(parse_line))
            nftban_botscan_process_entry "$_BS_IP" "$_BS_URL" "$_BS_METHOD" "$_BS_STATUS" "$_BS_UA"
            processed=$((processed + 1))
        done < <(
            {
                if [[ -n "$log_file" ]]; then tail -1000 -- "$f" 2>/dev/null
                elif declare -F nftban_http_read_incremental >/dev/null 2>&1; then nftban_http_read_incremental "$f"
                else tail -1000 -- "$f" 2>/dev/null; fi
            } | { if [[ -n "$_pf" ]]; then LC_ALL=C grep -E -f "$_pf" 2>/dev/null || true; else cat; fi; }
        )
        files_done=$((files_done + 1))
    done

    # Persist rotation cursor: next cycle starts at the first file we did NOT finish.
    if [[ -z "$log_file" && "$n" -gt 0 ]]; then
        printf '%s\n' "$(( (rot + files_done) % n ))" > "${rot_file}.tmp" 2>/dev/null \
            && mv -f "${rot_file}.tmp" "$rot_file" 2>/dev/null || true
    fi

    echo "Processed: $processed entries (${files_done}/${n} files this cycle)"
    [[ "$deadline_hit" -eq 1 ]] && echo "Deadline budget (${budget}s) reached — analyzing partial batch; remaining files resume next cycle"
    echo "IPs tracked: ${#_BOTSCAN_IP_HITS[@]}"

    # v1.187 Lane A — 404-window OPTION 1: independent fixed-tail re-read (does NOT touch
    # the forward cursor offset) so 404-burst detection is preserved despite the forward
    # cursor only seeing one slice per cycle. Authoritative source for the 404 counters.
    nftban_botscan_count_404_tail "$start_secs" "$budget" "${logs[@]}"
    [[ -n "$_pf" ]] && rm -f "$_pf"

    # Analyze and ban — ALWAYS runs (even on a partial/deadline-bounded batch) so a
    # high-volume host still produces bans every cycle instead of zero.
    local banned
    banned=$(nftban_botscan_analyze) || banned=0
    echo "Banned: $banned IPs"

    return 0
}

# Check/run once
nftban_botscan_check() {
    nftban_botscan_load_config
    nftban_botscan_process_logs "$@"
}

# Status
nftban_botscan_status() {
    nftban_botscan_load_config

    echo "Bot Scanner Status"
    echo "=================="
    echo ""
    echo "Enabled:        $BOTSCAN_ENABLED"
    echo "Action Mode:    $BOTSCAN_ACTION_MODE"
    echo "Patterns Dir:   $BOTSCAN_PATTERNS_DIR"
    echo ""

    # Count patterns
    local total=0 enabled=0
    for pattern_file in "$BOTSCAN_PATTERNS_DIR"/*.patterns; do
        [[ -f "$pattern_file" ]] || continue
        while IFS='|' read -r name _ _ _ _ _ is_enabled _; do
            [[ -z "$name" || "$name" =~ ^# ]] && continue
            total=$((total + 1))
            [[ "$is_enabled" == "true" ]] && enabled=$((enabled + 1))
        done < "$pattern_file"
    done

    echo "Patterns:       $enabled enabled / $total total"
    echo ""

    # Log source
    local log
    log=$(nftban_botscan_find_log)
    echo "Log Source:     ${log:-NOT FOUND}"

    # Service-account readability health (v1.177). Evaluated AS the service account
    # (nftban), not the caller — root could read panel logs the timer cannot.
    if declare -F nftban_http_classify_candidates >/dev/null 2>&1; then
        local svc="${NFTBAN_BOTSCAN_SERVICE_USER:-nftban}"
        nftban_http_classify_candidates "${BOTSCAN_LOG_PATHS:-}" >/dev/null 2>&1 || true
        local verdict="${_NFTBAN_HTTP_READ_VERDICT:-UNKNOWN}"
        # v1.178-A: collector spool feeds the scanner even when direct source is unreadable.
        local _spool="${BOTSCAN_SPOOL_DIR:-/run/nftban/botscan}" _spool_fed=0 _sf
        if [[ -d "$_spool" ]]; then
            for _sf in "$_spool"/*; do [[ -f "$_sf" && -r "$_sf" && -s "$_sf" ]] && { _spool_fed=1; break; }; done
        fi
        if [[ "$_spool_fed" -eq 1 && ( "$verdict" == "DEGRADED" || "$verdict" == "UNKNOWN" ) ]]; then
            echo "Readability:    OK via collector spool (direct source ${verdict} for ${svc}; collector feeding ${_spool})"
        else
            echo "Readability:    ${verdict} (${_NFTBAN_HTTP_READ_COUNT_READABLE}/${_NFTBAN_HTTP_READ_COUNT_TOTAL} readable by ${svc})"
            if [[ "$verdict" == "DEGRADED" ]]; then
                echo "                BOTSCAN_READ_AUTHORITY open: access logs discovered but unreadable by the"
                echo "                service account — install/enable nftban-botscan-collector.service (read-authority)."
            fi
        fi
    fi

    return 0
}

# Initialize on source
nftban_botscan_load_config
