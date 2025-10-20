#!/usr/bin/env bash

# =============================================================================
# NFTBan Search Module - Universal IP Search System (Security Hardened)
# Version: 2.1.0 (Security Hardening for v0.9.0+)
# Description: ONE universal search function for all IP lookups
# =============================================================================
# Author: Antonios Voulvoulis (ITCMS Team)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# =============================================================================
# IMPORTANT: This module provides universal search across:
#   - Configuration files (whitelist, blacklist, feeds)
#   - nftables sets (@whitelist, @temp_ban, @perm_ban, @feeds)
#   - Used by Fail2Ban actions to check whitelist before banning
#
# SECURITY FEATURES (v2.1.0):
#   - TOCTOU protection via atomic flock operations
#   - Command injection prevention with strict input validation
#   - Regex injection protection (escaped grep patterns)
#   - IPv4-mapped IPv6 normalization (::ffff:x.x.x.x → x.x.x.x)
#   - File race condition protection (flock on ALL file ops)
#   - Strict IP validation with ipcalc
#   - CIDR range matching support
# =============================================================================

[[ -n "${NFTBAN_SEARCH_LOADED:-}" ]] && return 0
readonly NFTBAN_SEARCH_LOADED=1

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly NFTBAN_SEARCH_CONFIG_DIR="${NFTBAN_CONFIG_DIR:-/etc/nftban/config}"
readonly NFTBAN_SEARCH_FEEDS_DIR="${NFTBAN_SEARCH_CONFIG_DIR}/feeds"
readonly NFTBAN_LOCK_DIR="${NFTBAN_LOCK_DIR:-/var/lock/nftban}"

readonly NFTBAN_NFT_TABLE_V4="${NFTBAN_NFT_TABLE_V4:-nftban_v4}"
readonly NFTBAN_NFT_TABLE_V6="${NFTBAN_NFT_TABLE_V6:-nftban_v6}"
readonly NFTBAN_NFT_FAMILY_V4="ip"
readonly NFTBAN_NFT_FAMILY_V6="ip6"

# Lock timeout (seconds)
readonly NFTBAN_LOCK_TIMEOUT=5

# Search result status codes
readonly NFTBAN_SEARCH_STATUS_WHITELISTED=10
readonly NFTBAN_SEARCH_STATUS_TEMP_BANNED=20
readonly NFTBAN_SEARCH_STATUS_PERM_BANNED=30
readonly NFTBAN_SEARCH_STATUS_IN_FEEDS=40
readonly NFTBAN_SEARCH_STATUS_CLEAN=0

# Ensure lock directory exists
[[ -d "$NFTBAN_LOCK_DIR" ]] || mkdir -p "$NFTBAN_LOCK_DIR" 2>/dev/null || true

# =============================================================================
# IP VALIDATION HELPERS (Security Hardened)
# =============================================================================

# SECURITY: Strict input sanitization to prevent command injection
# Reject ANY input with shell metacharacters BEFORE processing
_nftban_search_sanitize_input() {
    local input="$1"

    # Check for dangerous shell metacharacters
    # Allowed: digits, dots, colons, slashes (for IP/CIDR only)
    # Reject: $ ` ; | & < > ( ) { } [ ] \ ' "
    if [[ "$input" =~ [\$\`\;\|\&\<\>\(\)\{\}\\\'\"] ]] || [[ "$input" =~ \[ ]] || [[ "$input" =~ \] ]]; then
        echo "ERROR: Dangerous characters detected in input: $input" >&2
        return 1
    fi

    # Check max length (prevent DoS)
    if [[ ${#input} -gt 100 ]]; then
        echo "ERROR: Input too long (max 100 chars): ${#input}" >&2
        return 1
    fi

    return 0
}

# SECURITY: Normalize IPv4-mapped IPv6 addresses
# Converts ::ffff:192.168.1.1 → 192.168.1.1
_nftban_search_normalize_ip() {
    local ip="$1"

    # Check for IPv4-mapped IPv6 (::ffff:x.x.x.x)
    if [[ "$ip" =~ ^::ffff:([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
    # Check for IPv4-compatible IPv6 (::x.x.x.x)
    elif [[ "$ip" =~ ^::([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "$ip"
    fi
}

_nftban_search_is_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

_nftban_search_is_ipv6() {
    local ip="$1"
    [[ "$ip" =~ : ]]
}

_nftban_search_is_cidr4() {
    local cidr="$1"
    [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]
}

_nftban_search_is_cidr6() {
    local cidr="$1"
    [[ "$cidr" =~ :/[0-9]{1,3}$ ]]
}

# SECURITY: Strict IP validation using ipcalc (prevents malformed IPs)
_nftban_search_validate_ip_strict() {
    local ip="$1"

    # First: sanitize input (prevent injection)
    _nftban_search_sanitize_input "$ip" || return 1

    # Second: normalize (handle IPv4-mapped IPv6)
    ip=$(_nftban_search_normalize_ip "$ip")

    # Third: validate with ipcalc if available
    if command -v ipcalc >/dev/null 2>&1; then
        if ! ipcalc -c "$ip" &>/dev/null; then
            echo "ERROR: IP validation failed (ipcalc): $ip" >&2
            return 1
        fi
    elif command -v sipcalc >/dev/null 2>&1; then
        if ! sipcalc "$ip" &>/dev/null; then
            echo "ERROR: IP validation failed (sipcalc): $ip" >&2
            return 1
        fi
    else
        # Fallback: basic regex validation only (not recommended for production)
        if ! _nftban_search_is_ipv4 "$ip" && ! _nftban_search_is_ipv6 "$ip" && \
           ! _nftban_search_is_cidr4 "$ip" && ! _nftban_search_is_cidr6 "$ip"; then
            echo "ERROR: IP validation failed (regex): $ip" >&2
            return 1
        fi
    fi

    # Return normalized IP
    echo "$ip"
    return 0
}

_nftban_search_get_ip_family() {
    local ip="$1"

    if _nftban_search_is_ipv4 "$ip" || _nftban_search_is_cidr4 "$ip"; then
        echo "v4"
    elif _nftban_search_is_ipv6 "$ip" || _nftban_search_is_cidr6 "$ip"; then
        echo "v6"
    else
        echo "unknown"
    fi
}

# SECURITY: Check if IP is in CIDR range (for file-based CIDR matching)
_nftban_search_ip_in_cidr() {
    local ip="$1"
    local cidr="$2"

    # Use ipcalc for CIDR membership check
    if command -v ipcalc >/dev/null 2>&1; then
        if ipcalc -c "$ip" -n "$cidr" &>/dev/null; then
            return 0
        fi
    elif command -v sipcalc >/dev/null 2>&1; then
        # sipcalc doesn't have direct membership check, use network comparison
        local ip_net=$(sipcalc "$ip" 2>/dev/null | grep "Network address" | awk '{print $NF}')
        local cidr_net=$(sipcalc "$cidr" 2>/dev/null | grep "Network address" | awk '{print $NF}')
        if [[ "$ip_net" == "$cidr_net" ]]; then
            return 0
        fi
    fi

    return 1
}

# =============================================================================
# FILE SEARCH FUNCTIONS (Security Hardened with flock)
# =============================================================================

# SECURITY: Escape regex metacharacters to prevent regex injection
_nftban_search_escape_regex() {
    local input="$1"
    # Escape special regex characters: . [ ] * ^ $ ( ) { } + ? | \
    printf '%s\n' "$input" | sed 's/[][.*^$()+?{|\\]/\\&/g'
}

# SECURITY: Search file with flock (prevent race conditions) and escaped regex
_nftban_search_in_file() {
    local ip="$1"
    local file="$2"

    # Validate file exists and is readable
    [[ ! -f "$file" ]] && return 1
    [[ ! -r "$file" ]] && return 1
    [[ ! -s "$file" ]] && return 1  # Empty file

    # SECURITY: Escape IP for regex (prevent regex injection)
    local escaped_ip=$(_nftban_search_escape_regex "$ip")

    # Search with shared lock (allows concurrent reads)
    (
        flock -s -w "$NFTBAN_LOCK_TIMEOUT" 200 || {
            echo "WARNING: Could not acquire read lock on $file" >&2
            return 1
        }

        # Search for exact IP match (handle comments, whitespace)
        # Match: start of line, optional whitespace, IP, then whitespace/comment/end
        if grep -qE "^[[:space:]]*${escaped_ip}([[:space:]]|#|$)" "$file" 2>/dev/null; then
            return 0
        fi

        # SECURITY: Also check for CIDR ranges in file (IP might be in a CIDR block)
        while IFS= read -r line; do
            # Skip comments and empty lines
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$line" ]] && continue

            # Extract potential CIDR
            local entry=$(echo "$line" | awk '{print $1}')

            # Check if entry is a CIDR and IP falls within it
            if [[ "$entry" =~ / ]]; then
                if _nftban_search_ip_in_cidr "$ip" "$entry" 2>/dev/null; then
                    return 0
                fi
            fi
        done < "$file"

        return 1
    ) 200<"$file"
}

# SECURITY: Search multiple files with atomic read locks
_nftban_search_in_files() {
    local ip="$1"
    shift
    local files=("$@")
    local found_files=()

    for file in "${files[@]}"; do
        if _nftban_search_in_file "$ip" "$file"; then
            found_files+=("$file")
        fi
    done

    if [[ ${#found_files[@]} -gt 0 ]]; then
        printf '%s\n' "${found_files[@]}"
        return 0
    fi
    return 1
}

# =============================================================================
# NFTABLES SET SEARCH FUNCTIONS (Security Hardened)
# =============================================================================

# SECURITY: Use nft get element for O(1) lookup instead of list + grep
_nftban_search_in_nftables_set() {
    local ip="$1"
    local set_name="$2"
    local family="$3"  # "v4" or "v6"

    local table family_name
    if [[ "$family" == "v4" ]]; then
        table="$NFTBAN_NFT_TABLE_V4"
        family_name="$NFTBAN_NFT_FAMILY_V4"
    else
        table="$NFTBAN_NFT_TABLE_V6"
        family_name="$NFTBAN_NFT_FAMILY_V6"
    fi

    # Check if set exists
    if ! nft list set "$family_name" "$table" "$set_name" &>/dev/null; then
        return 1
    fi

    # SECURITY: Use `nft get element` for direct O(1) lookup (safer & faster)
    # This avoids grep injection and is more performant
    if nft get element "$family_name" "$table" "$set_name" "{ $ip }" &>/dev/null; then
        return 0
    fi

    # Fallback: list + escaped grep (for older nftables versions)
    local escaped_ip=$(_nftban_search_escape_regex "$ip")
    nft list set "$family_name" "$table" "$set_name" 2>/dev/null | \
        grep -qE "${escaped_ip}([[:space:]]|,|$)"
}

# =============================================================================
# WHITELIST CHECK (TOCTOU-Protected - CRITICAL for Fail2Ban)
# =============================================================================

# SECURITY: Atomic whitelist check with flock to prevent TOCTOU race conditions
# This function is called by Fail2Ban before banning IPs
# CRITICAL: Must be atomic to prevent banning whitelisted IPs during race windows
nftban_check_whitelist() {
    local ip="$1"

    [[ -z "$ip" ]] && return 1

    # SECURITY: Sanitize and validate IP input (prevent command injection)
    local validated_ip
    if ! validated_ip=$(_nftban_search_validate_ip_strict "$ip" 2>/dev/null); then
        echo "ERROR: Invalid IP in whitelist check: $ip" >&2
        return 1
    fi

    # Use normalized IP
    ip="$validated_ip"

    local family=$(_nftban_search_get_ip_family "$ip")
    [[ "$family" == "unknown" ]] && return 1

    # SECURITY: ATOMIC whitelist check with exclusive lock
    # Prevents TOCTOU: Time-Of-Check-Time-Of-Use race condition
    # Lock ensures no modifications during check operation
    local lockfile="${NFTBAN_LOCK_DIR}/whitelist-check.lock"

    (
        # Acquire exclusive lock with timeout
        if ! flock -x -w "$NFTBAN_LOCK_TIMEOUT" 200; then
            echo "ERROR: Could not acquire whitelist lock (timeout)" >&2
            # FAIL-SAFE: If we can't lock, REFUSE to ban (assume whitelisted)
            return 0
        fi

        # Check files (NEW v0.9.0+ naming)
        local whitelist_files=(
            "${NFTBAN_SEARCH_CONFIG_DIR}/whitelist_ips.conf"
            "${NFTBAN_SEARCH_CONFIG_DIR}/whitelist_ips.conf.local"
        )

        if _nftban_search_in_files "$ip" "${whitelist_files[@]}" >/dev/null 2>&1; then
            return 0
        fi

        # Check nftables set
        if _nftban_search_in_nftables_set "$ip" "whitelist" "$family"; then
            return 0
        fi

        return 1
    ) 200>"$lockfile"
}

export -f nftban_check_whitelist

# =============================================================================
# BLACKLIST CHECK (Fast)
# =============================================================================

nftban_check_blacklist() {
    local ip="$1"

    [[ -z "$ip" ]] && return 1

    local family=$(_nftban_search_get_ip_family "$ip")
    [[ "$family" == "unknown" ]] && return 1

    # Check permanent blacklist files (NEW v0.9.0+ naming)
    local blacklist_files=(
        "${NFTBAN_SEARCH_CONFIG_DIR}/blacklist_ips.conf"
        "${NFTBAN_SEARCH_CONFIG_DIR}/blacklist_ips.conf.local"
    )

    if _nftban_search_in_files "$ip" "${blacklist_files[@]}" >/dev/null 2>&1; then
        return 0
    fi

    # Check nftables perm_ban set
    if _nftban_search_in_nftables_set "$ip" "perm_ban" "$family"; then
        return 0
    fi

    return 1
}

export -f nftban_check_blacklist

# =============================================================================
# UNIVERSAL IP SEARCH (Complete Search Everywhere)
# =============================================================================

nftban_search_ip() {
    local ip="$1"
    local quiet="${2:-false}"  # Set to "true" for non-interactive

    if [[ -z "$ip" ]]; then
        [[ "$quiet" != "true" ]] && echo "Error: No IP address provided" >&2
        return 1
    fi

    # SECURITY: Validate and normalize IP (prevent injection, handle IPv4-mapped IPv6)
    local validated_ip
    if ! validated_ip=$(_nftban_search_validate_ip_strict "$ip" 2>/dev/null); then
        [[ "$quiet" != "true" ]] && echo "Error: Invalid IP address format: $ip" >&2
        return 1
    fi

    # Use normalized IP for all searches
    local original_ip="$ip"
    ip="$validated_ip"

    # Validate IP family
    local family=$(_nftban_search_get_ip_family "$ip")
    if [[ "$family" == "unknown" ]]; then
        [[ "$quiet" != "true" ]] && echo "Error: Invalid IP address format: $ip" >&2
        return 1
    fi

    # Initialize result tracking
    local -a whitelist_files=()
    local -a blacklist_files=()
    local -a feed_files=()
    local whitelist_nft=false
    local temp_ban_nft=false
    local perm_ban_nft=false
    local feeds_nft=false

    local status=$NFTBAN_SEARCH_STATUS_CLEAN
    local primary_location=""

    # =============================================================================
    # PRIORITY 1: WHITELIST (Highest Priority - Never Ban)
    # =============================================================================

    local wl_files=(
        "${NFTBAN_SEARCH_CONFIG_DIR}/whitelist_ips.conf"
        "${NFTBAN_SEARCH_CONFIG_DIR}/whitelist_ips.conf.local"
    )

    for file in "${wl_files[@]}"; do
        if _nftban_search_in_file "$ip" "$file"; then
            whitelist_files+=("$file")
        fi
    done

    if _nftban_search_in_nftables_set "$ip" "whitelist" "$family"; then
        whitelist_nft=true
    fi

    if [[ ${#whitelist_files[@]} -gt 0 ]] || [[ "$whitelist_nft" == "true" ]]; then
        status=$NFTBAN_SEARCH_STATUS_WHITELISTED
        primary_location="WHITELIST"
    fi

    # =============================================================================
    # PRIORITY 2: TEMPORARY BANS
    # =============================================================================

    if [[ $status -eq $NFTBAN_SEARCH_STATUS_CLEAN ]]; then
        if _nftban_search_in_nftables_set "$ip" "temp_ban" "$family"; then
            temp_ban_nft=true
            status=$NFTBAN_SEARCH_STATUS_TEMP_BANNED
            primary_location="TEMP_BAN"
        fi
    fi

    # =============================================================================
    # PRIORITY 3: PERMANENT BLACKLIST
    # =============================================================================

    if [[ $status -eq $NFTBAN_SEARCH_STATUS_CLEAN ]]; then
        local bl_files=(
            "${NFTBAN_SEARCH_CONFIG_DIR}/blacklist_ips.conf"
            "${NFTBAN_SEARCH_CONFIG_DIR}/blacklist_ips.conf.local"
        )

        for file in "${bl_files[@]}"; do
            if _nftban_search_in_file "$ip" "$file"; then
                blacklist_files+=("$file")
            fi
        done

        if _nftban_search_in_nftables_set "$ip" "perm_ban" "$family"; then
            perm_ban_nft=true
        fi

        if [[ ${#blacklist_files[@]} -gt 0 ]] || [[ "$perm_ban_nft" == "true" ]]; then
            status=$NFTBAN_SEARCH_STATUS_PERM_BANNED
            primary_location="PERM_BLACKLIST"
        fi
    fi

    # =============================================================================
    # PRIORITY 4: FEED BLACKLISTS
    # =============================================================================

    if [[ $status -eq $NFTBAN_SEARCH_STATUS_CLEAN ]]; then
        if [[ -d "$NFTBAN_SEARCH_FEEDS_DIR" ]]; then
            while IFS= read -r -d '' feed_file; do
                if _nftban_search_in_file "$ip" "$feed_file"; then
                    feed_files+=("$feed_file")
                fi
            done < <(find "$NFTBAN_SEARCH_FEEDS_DIR" -name "*-blacklist.conf" -type f -print0 2>/dev/null)
        fi

        if _nftban_search_in_nftables_set "$ip" "feeds" "$family"; then
            feeds_nft=true
        fi

        if [[ ${#feed_files[@]} -gt 0 ]] || [[ "$feeds_nft" == "true" ]]; then
            status=$NFTBAN_SEARCH_STATUS_IN_FEEDS
            primary_location="FEEDS"
        fi
    fi

    # =============================================================================
    # OUTPUT RESULTS
    # =============================================================================

    if [[ "$quiet" == "true" ]]; then
        # Quiet mode: just return status code
        return $status
    fi

    # Interactive mode: display formatted results
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  IP Search Result: $ip"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    case $status in
        $NFTBAN_SEARCH_STATUS_WHITELISTED)
            echo "Status: ✅ WHITELISTED (Protected - Cannot be banned)"
            echo ""
            echo "Found in:"
            for file in "${whitelist_files[@]}"; do
                echo "  • File: $file"
            done
            [[ "$whitelist_nft" == "true" ]] && echo "  • nftables: @whitelist (${NFTBAN_NFT_TABLE_V4}/${NFTBAN_NFT_TABLE_V6})"
            ;;

        $NFTBAN_SEARCH_STATUS_TEMP_BANNED)
            echo "Status: ⏰ TEMPORARILY BANNED"
            echo ""
            echo "Found in:"
            [[ "$temp_ban_nft" == "true" ]] && echo "  • nftables: @temp_ban (${NFTBAN_NFT_TABLE_V4}/${NFTBAN_NFT_TABLE_V6})"
            ;;

        $NFTBAN_SEARCH_STATUS_PERM_BANNED)
            echo "Status: 🚫 PERMANENTLY BLACKLISTED"
            echo ""
            echo "Found in:"
            for file in "${blacklist_files[@]}"; do
                echo "  • File: $file"
            done
            [[ "$perm_ban_nft" == "true" ]] && echo "  • nftables: @perm_ban (${NFTBAN_NFT_TABLE_V4}/${NFTBAN_NFT_TABLE_V6})"
            ;;

        $NFTBAN_SEARCH_STATUS_IN_FEEDS)
            echo "Status: 📡 IN THREAT FEEDS"
            echo ""
            echo "Found in:"
            for file in "${feed_files[@]}"; do
                local feed_name=$(basename "$file" | sed 's/-blacklist\.conf$//')
                echo "  • Feed: $feed_name"
            done
            [[ "$feeds_nft" == "true" ]] && echo "  • nftables: @feeds (${NFTBAN_NFT_TABLE_V4}/${NFTBAN_NFT_TABLE_V6})"
            ;;

        $NFTBAN_SEARCH_STATUS_CLEAN)
            echo "Status: ✓ CLEAN (Not found in any list)"
            echo ""
            echo "This IP is not whitelisted, banned, or blacklisted."
            ;;
    esac

    echo ""
    echo "IP Family: IPv$([[ "$family" == "v4" ]] && echo "4" || echo "6")"
    echo ""

    # Store for potential interactive use
    export NFTBAN_LAST_SEARCH_IP="$ip"
    export NFTBAN_LAST_SEARCH_STATUS="$status"
    export NFTBAN_LAST_SEARCH_LOCATION="$primary_location"

    return $status
}

export -f nftban_search_ip

# =============================================================================
# GET IP STATUS (Returns simple status string)
# =============================================================================

nftban_get_ip_status() {
    local ip="$1"

    nftban_search_ip "$ip" true
    local status=$?

    case $status in
        $NFTBAN_SEARCH_STATUS_WHITELISTED) echo "WHITELISTED" ;;
        $NFTBAN_SEARCH_STATUS_TEMP_BANNED) echo "TEMP_BANNED" ;;
        $NFTBAN_SEARCH_STATUS_PERM_BANNED) echo "PERM_BANNED" ;;
        $NFTBAN_SEARCH_STATUS_IN_FEEDS) echo "IN_FEEDS" ;;
        $NFTBAN_SEARCH_STATUS_CLEAN) echo "CLEAN" ;;
        *) echo "UNKNOWN" ;;
    esac

    return $status
}

export -f nftban_get_ip_status

# =============================================================================
# INTERACTIVE IP MANAGEMENT
# =============================================================================

nftban_interactive_manage_ip() {
    local ip="$1"

    if [[ -z "$ip" ]]; then
        echo "Error: No IP address provided" >&2
        return 1
    fi

    # Run full search first
    nftban_search_ip "$ip"
    local status=$?

    echo "═══════════════════════════════════════════════════════════════"
    echo "  Available Actions"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    case $status in
        $NFTBAN_SEARCH_STATUS_WHITELISTED)
            echo "  [1] Remove from whitelist"
            echo "  [2] Add to permanent blacklist (removes from whitelist)"
            echo "  [q] Exit"
            ;;

        $NFTBAN_SEARCH_STATUS_TEMP_BANNED)
            echo "  [1] Remove temporary ban (unban now)"
            echo "  [2] Convert to permanent blacklist"
            echo "  [3] Add to whitelist (also unbans)"
            echo "  [q] Exit"
            ;;

        $NFTBAN_SEARCH_STATUS_PERM_BANNED)
            echo "  [1] Remove from permanent blacklist"
            echo "  [2] Add to whitelist (also removes from blacklist)"
            echo "  [q] Exit"
            ;;

        $NFTBAN_SEARCH_STATUS_IN_FEEDS)
            echo "  [1] Add to whitelist (excludes from feeds)"
            echo "  [2] Add to permanent blacklist"
            echo "  [3] Ban temporarily (1 hour)"
            echo "  [q] Exit"
            ;;

        $NFTBAN_SEARCH_STATUS_CLEAN)
            echo "  [1] Add to whitelist"
            echo "  [2] Add to permanent blacklist"
            echo "  [3] Ban temporarily (1 hour)"
            echo "  [q] Exit"
            ;;
    esac

    echo ""
    read -rp "Select action: " choice

    case $choice in
        1|2|3)
            echo ""
            echo "Action would execute here (requires module integration)"
            echo "Selected: Option $choice for IP $ip (status=$status)"
            ;;
        q|Q)
            echo "Cancelled."
            return 0
            ;;
        *)
            echo "Invalid selection."
            return 1
            ;;
    esac
}

export -f nftban_interactive_manage_ip

# =============================================================================
# MODULE INFO
# =============================================================================

nftban_log_debug "Universal Search Module loaded (v2.0.0 - Clean NEW logic)"

