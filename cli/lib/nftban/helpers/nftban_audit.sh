#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_audit"
# meta:type="helper"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Logs all security-relevant actions (bans, unbans, config changes) to audit trail"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""

set -Eeuo pipefail

# =============================================================================
# MODULE GUARD
# =============================================================================

# Prevent double-loading
[[ -n "${NFTBAN_AUDIT_LOADED:-}" ]] && return 0
readonly NFTBAN_AUDIT_LOADED=1

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" 2>/dev/null || true

# Source timestamp library for unified timestamp formatting
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_timestamp.sh" 2>/dev/null || true

# =============================================================================
# CONFIGURATION
# =============================================================================

# Audit log file
readonly NFTBAN_AUDIT_LOG="${NFTBAN_AUDIT_LOG:-/var/log/nftban/nftban-actions.log}"

# Enable/disable audit logging
: "${NFTBAN_AUDIT_ENABLED:=true}"

# Audit log format: json, text
: "${NFTBAN_AUDIT_FORMAT:=json}"

# =============================================================================
# CORE AUDIT FUNCTION
# =============================================================================

# Main audit logging function
# Usage: nftban_audit_log <action> <target> [reason] [user] [details]
nftban_audit_log() {
    local action="$1"       # ban, unban, geoban, feed_update, config_change, etc.
    local target="$2"       # IP, country code, feed name, config file, etc.
    local reason="${3:-}"   # Optional reason
    local user="${4:-${USER:-unknown}}"  # User performing action
    local details="${5:-}"  # Optional JSON details

    # Skip if audit is disabled
    [[ "${NFTBAN_AUDIT_ENABLED}" != "true" ]] && return 0

    # Build timestamp
    local timestamp
    timestamp=$(nftban_timestamp)  # ISO 8601 UTC

    # Get hostname
    local hostname
    hostname=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "unknown")

    # Get source IP (if available from SSH)
    local source_ip="${SSH_CLIENT%% *}"
    source_ip="${source_ip:-local}"

    # Ensure audit log directory exists
    local audit_dir
    audit_dir="$(dirname "$NFTBAN_AUDIT_LOG")"

    if [[ ! -d "$audit_dir" ]]; then
        mkdir -p "$audit_dir" 2>/dev/null || true
    fi

    # Create audit log if it doesn't exist (with correct ownership)
    if [[ ! -f "$NFTBAN_AUDIT_LOG" ]]; then
        touch "$NFTBAN_AUDIT_LOG" 2>/dev/null || true
        chown nftban:nftban "$NFTBAN_AUDIT_LOG" 2>/dev/null || true
        chmod 640 "$NFTBAN_AUDIT_LOG" 2>/dev/null || true
    fi

    # Build audit entry based on format
    local audit_entry

    case "${NFTBAN_AUDIT_FORMAT}" in
        json)
            # JSON format (better for parsing)
            if [[ -n "$details" ]]; then
                audit_entry=$(cat <<EOF
{"timestamp":"$timestamp","hostname":"$hostname","action":"$action","target":"$target","reason":"$reason","user":"$user","source_ip":"$source_ip","pid":$$,"details":$details}
EOF
)
            else
                audit_entry=$(cat <<EOF
{"timestamp":"$timestamp","hostname":"$hostname","action":"$action","target":"$target","reason":"$reason","user":"$user","source_ip":"$source_ip","pid":$$}
EOF
)
            fi
            ;;
        text)
            # Human-readable text format
            audit_entry="[$timestamp] [$hostname] [$user@$source_ip] ACTION=$action TARGET=$target REASON=$reason PID=$$"
            ;;
        *)
            # Default to JSON
            audit_entry=$(cat <<EOF
{"timestamp":"$timestamp","hostname":"$hostname","action":"$action","target":"$target","reason":"$reason","user":"$user","source_ip":"$source_ip","pid":$$}
EOF
)
            ;;
    esac

    # Write to audit log (with error handling)
    if [[ -w "$audit_dir" ]] || [[ -w "$NFTBAN_AUDIT_LOG" ]]; then
        echo "$audit_entry" >> "$NFTBAN_AUDIT_LOG" 2>/dev/null || true
    fi
}

# =============================================================================
# CONVENIENCE FUNCTIONS FOR COMMON ACTIONS
# =============================================================================

# Audit IP ban
# Usage: nftban_audit_ban <ip> <reason> [timeout]
nftban_audit_ban() {
    local ip="$1"
    local reason="${2:-manual}"
    local timeout="${3:-}"

    local details=""
    if [[ -n "$timeout" ]]; then
        details='{"timeout":"'$timeout'"}'
    fi

    nftban_audit_log "ban" "$ip" "$reason" "${USER:-unknown}" "$details"
}

# Audit IP unban
# Usage: nftban_audit_unban <ip> [reason]
nftban_audit_unban() {
    local ip="$1"
    local reason="${2:-manual}"

    nftban_audit_log "unban" "$ip" "$reason"
}

# Audit GeoBan action
# Usage: nftban_audit_geoban <action> <country_code> [reason]
nftban_audit_geoban() {
    local action="$1"  # block, unblock
    local country="$2"
    local reason="${3:-manual}"

    nftban_audit_log "geoban_${action}" "$country" "$reason"
}

# Audit feed update
# Usage: nftban_audit_feed_update <feed_name> <added> <removed>
nftban_audit_feed_update() {
    local feed_name="$1"
    local added="${2:-0}"
    local removed="${3:-0}"

    local details='{"added":'$added',"removed":'$removed'}'

    nftban_audit_log "feed_update" "$feed_name" "automatic" "${USER:-system}" "$details"
}

# Audit configuration change
# Usage: nftban_audit_config_change <config_file> <change_description>
nftban_audit_config_change() {
    local config_file="$1"
    local change_desc="$2"

    nftban_audit_log "config_change" "$config_file" "$change_desc"
}

# Audit whitelist add
# Usage: nftban_audit_whitelist_add <ip> [reason]
nftban_audit_whitelist_add() {
    local ip="$1"
    local reason="${2:-manual}"

    nftban_audit_log "whitelist_add" "$ip" "$reason"
}

# Audit whitelist remove
# Usage: nftban_audit_whitelist_remove <ip> [reason]
nftban_audit_whitelist_remove() {
    local ip="$1"
    local reason="${2:-manual}"

    nftban_audit_log "whitelist_remove" "$ip" "$reason"
}

# Audit firewall reload
# Usage: nftban_audit_firewall_reload [reason]
nftban_audit_firewall_reload() {
    local reason="${1:-manual}"

    nftban_audit_log "firewall_reload" "nftables" "$reason"
}

# Audit service start/stop
# Usage: nftban_audit_service <action> <service_name>
nftban_audit_service() {
    local action="$1"  # start, stop, restart
    local service="$2"

    nftban_audit_log "service_${action}" "$service" "manual"
}

# =============================================================================
# AUDIT LOG QUERY HELPERS
# =============================================================================

# Get last N audit entries
# Usage: nftban_audit_tail [n]
nftban_audit_tail() {
    local n="${1:-10}"

    if [[ -f "$NFTBAN_AUDIT_LOG" ]]; then
        tail -n "$n" "$NFTBAN_AUDIT_LOG"
    fi
}

# Search audit log for specific action
# Usage: nftban_audit_search <action> [n]
nftban_audit_search() {
    local action="$1"
    local n="${2:-100}"

    if [[ -f "$NFTBAN_AUDIT_LOG" ]]; then
        grep "\"action\":\"$action\"" "$NFTBAN_AUDIT_LOG" | tail -n "$n"
    fi
}

# Get audit entries for specific target
# Usage: nftban_audit_search_target <target> [n]
nftban_audit_search_target() {
    local target="$1"
    local n="${2:-100}"

    if [[ -f "$NFTBAN_AUDIT_LOG" ]]; then
        grep "\"target\":\"$target\"" "$NFTBAN_AUDIT_LOG" | tail -n "$n"
    fi
}

# Get audit entries by user
# Usage: nftban_audit_search_user <user> [n]
nftban_audit_search_user() {
    local user="$1"
    local n="${2:-100}"

    if [[ -f "$NFTBAN_AUDIT_LOG" ]]; then
        grep "\"user\":\"$user\"" "$NFTBAN_AUDIT_LOG" | tail -n "$n"
    fi
}

# Get audit summary (counts by action)
# Usage: nftban_audit_summary
nftban_audit_summary() {
    if [[ ! -f "$NFTBAN_AUDIT_LOG" ]]; then
        echo "No audit log found"
        return 0
    fi

    echo "Audit Log Summary:"
    echo "==================="
    echo ""
    echo "Total entries: $(wc -l < "$NFTBAN_AUDIT_LOG")"
    echo ""
    echo "Actions breakdown:"

    if command -v jq &>/dev/null; then
        # Use jq for better parsing
        jq -r '.action' "$NFTBAN_AUDIT_LOG" 2>/dev/null | sort | uniq -c | sort -rn
    else
        # Fallback to grep
        grep -oP '"action":"[^"]*"' "$NFTBAN_AUDIT_LOG" | cut -d'"' -f4 | sort | uniq -c | sort -rn
    fi
}

# =============================================================================
# AUDIT LOG ROTATION
# =============================================================================

# Rotate audit log if too large
# Usage: nftban_audit_rotate [max_size_mb]
nftban_audit_rotate() {
    local max_size_mb="${1:-50}"  # Default 50MB

    [[ ! -f "$NFTBAN_AUDIT_LOG" ]] && return 0

    local size_bytes
    size_bytes=$(stat -f%z "$NFTBAN_AUDIT_LOG" 2>/dev/null || stat -c%s "$NFTBAN_AUDIT_LOG" 2>/dev/null || echo "0")
    local size_mb=$((size_bytes / 1024 / 1024))

    if ((size_mb >= max_size_mb)); then
        # Rotate with timestamp
        local backup
        backup="${NFTBAN_AUDIT_LOG}.$(nftban_timestamp_file)"
        mv "$NFTBAN_AUDIT_LOG" "$backup"
        touch "$NFTBAN_AUDIT_LOG"
        chown nftban:nftban "$NFTBAN_AUDIT_LOG" 2>/dev/null || true
        chmod 640 "$NFTBAN_AUDIT_LOG" 2>/dev/null || true

        # Compress old audit log
        if command -v gzip &>/dev/null; then
            gzip "$backup" &
        fi

        nftban_audit_log "audit_rotate" "$backup" "size_exceeded:${size_mb}MB"
    fi
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================

# Export audit functions for use by other scripts
export -f nftban_audit_log
export -f nftban_audit_ban
export -f nftban_audit_unban
export -f nftban_audit_geoban
export -f nftban_audit_feed_update
export -f nftban_audit_config_change
export -f nftban_audit_whitelist_add
export -f nftban_audit_whitelist_remove
export -f nftban_audit_firewall_reload
export -f nftban_audit_service
export -f nftban_audit_tail
export -f nftban_audit_search
export -f nftban_audit_search_target
export -f nftban_audit_search_user
export -f nftban_audit_summary
export -f nftban_audit_rotate

# =============================================================================
# MODULE LOADED
# =============================================================================

# Initialize audit log on first load (with correct ownership)
if [[ ! -f "$NFTBAN_AUDIT_LOG" ]] && [[ "${NFTBAN_AUDIT_ENABLED}" == "true" ]]; then
    _nftban_audit_init_dir="$(dirname "$NFTBAN_AUDIT_LOG")"
    mkdir -p "$_nftban_audit_init_dir" 2>/dev/null || true
    touch "$NFTBAN_AUDIT_LOG" 2>/dev/null || true
    chown nftban:nftban "$NFTBAN_AUDIT_LOG" 2>/dev/null || true
    chmod 640 "$NFTBAN_AUDIT_LOG" 2>/dev/null || true
    unset _nftban_audit_init_dir
fi
