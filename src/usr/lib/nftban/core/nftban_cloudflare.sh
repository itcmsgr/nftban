#!/usr/bin/env bash
# =============================================================================
# NFTBan Cloudflare Module
# Part of NFTBan v0.10.0 - FHS-Compliant Architecture
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Cloudflare IP range management and whitelist integration
#
# meta:name=nftban_cloudflare
# meta:type=module
# meta:header=Cloudflare Integration Module
# meta:version=0.30.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Downloads and manages Cloudflare IP ranges for whitelisting
# meta:input=Cloudflare API endpoints
# meta:output=Whitelist files and nftables integration
#
# **Inventory & Requirements**
# meta:depends=bash,curl,nftban_output.sh,nftban_system_ip.sh
#
# meta:created_date=2025-10-28
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Module guard - prevent double-loading
[[ -n "${NFTBAN_CLOUDFLARE_LOADED:-}" ]] && return 0
readonly NFTBAN_CLOUDFLARE_LOADED=1

# =============================================================================
# MODULE CONFIGURATION
# =============================================================================
readonly MODULE_NAME="nftban_cloudflare"
readonly MODULE_VERSION="0.10.0"

# FHS Paths (loaded from conf.d/cloudflare.conf)
readonly CF_CACHE_DIR="${CLOUDFLARE_CACHE_DIR:-/var/cache/nftban/cloudflare}"
readonly CF_DATA_DIR="${CLOUDFLARE_DATA_DIR:-/var/lib/nftban/cloudflare}"
readonly CF_WHITELIST_FILE="${CLOUDFLARE_WHITELIST_FILE:-/etc/nftban/whitelist.d/20-cloudflare.conf}"
readonly CF_LOG="${CLOUDFLARE_LOG_FILE:-/var/log/nftban/cloudflare.log}"

# Cache files
readonly CF_IPV4_CACHE="${CF_CACHE_DIR}/cloudflare-ipv4.txt"
readonly CF_IPV6_CACHE="${CF_CACHE_DIR}/cloudflare-ipv6.txt"

# Download URLs (from config)
CF_IPV4_URL="${CLOUDFLARE_IPV4_URL:-https://www.cloudflare.com/ips-v4}"
CF_IPV6_URL="${CLOUDFLARE_IPV6_URL:-https://www.cloudflare.com/ips-v6}"

# Validation limits (from config)
CF_MIN_IPV4="${CLOUDFLARE_MIN_IPV4_RANGES:-10}"
CF_MIN_IPV6="${CLOUDFLARE_MIN_IPV6_RANGES:-5}"
CF_MAX_IPV4="${CLOUDFLARE_MAX_IPV4_RANGES:-100}"
CF_MAX_IPV6="${CLOUDFLARE_MAX_IPV6_RANGES:-50}"

# =============================================================================
# ERROR TRAP
# =============================================================================
_nftban_cloudflare_on_err() {
    local rc=$?
    local line="${1:-unknown}"
    local func="${2:-main}"

    if declare -f nftban_log_error >/dev/null 2>&1; then
        nftban_log_error "CLOUDFLARE MODULE ERROR in ${func} at line ${line}; exit status ${rc}"
    else
        echo "ERROR: CLOUDFLARE MODULE in ${func} at line ${line}; exit status ${rc}" >&2
    fi

    return $rc
}

trap '_nftban_cloudflare_on_err ${LINENO} ${FUNCNAME[0]:-main}' ERR

# =============================================================================
# LOGGING
# =============================================================================
_cf_log() {
    local level="$1"; shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    mkdir -p "$(dirname "$CF_LOG")"
    echo "[${timestamp}] [${level}] ${message}" >> "$CF_LOG"

    # Also log to system if nftban_log_* available
    local log_func="nftban_log_${level,,}"
    if declare -f "$log_func" >/dev/null 2>&1; then
        "$log_func" "CLOUDFLARE: ${message}"
    fi
}

# =============================================================================
# BANNER
# =============================================================================
nftban_cloudflare_banner() {
    cat <<'BANNER'
╔══════════════════════════════════════════════════════════╗
║  ☁️  Cloudflare Integration                              ║
║  nftban — Simplifying Linux Firewall Management         ║
╚══════════════════════════════════════════════════════════╝
BANNER
}

# =============================================================================
# INITIALIZATION
# =============================================================================
nftban_cloudflare_init() {
    # Create required directories
    mkdir -p "$CF_CACHE_DIR" "$CF_DATA_DIR" "$(dirname "$CF_WHITELIST_FILE")"

    # Create log directory
    mkdir -p "$(dirname "$CF_LOG")"

    _cf_log "INFO" "Cloudflare module initialized"
}

# =============================================================================
# DOWNLOAD CLOUDFLARE IP RANGES
# =============================================================================
nftban_cloudflare_download_ips() {
    _cf_log "INFO" "Downloading Cloudflare IP ranges..."

    local ipv4_enabled="${CLOUDFLARE_IPV4_ENABLED:-true}"
    local ipv6_enabled="${CLOUDFLARE_IPV6_ENABLED:-true}"
    local success=true

    # Download IPv4
    if [[ "$ipv4_enabled" == "true" ]]; then
        _cf_log "INFO" "Downloading IPv4 ranges from: $CF_IPV4_URL"

        if curl -sf --max-time 30 "$CF_IPV4_URL" -o "${CF_IPV4_CACHE}.tmp" 2>/dev/null; then
            local count
            count=$(wc -l < "${CF_IPV4_CACHE}.tmp")

            # Validate count
            if (( count < CF_MIN_IPV4 )); then
                _cf_log "ERROR" "IPv4 validation failed: only $count ranges (minimum: $CF_MIN_IPV4)"
                rm -f "${CF_IPV4_CACHE}.tmp"
                success=false
            elif (( count > CF_MAX_IPV4 )); then
                _cf_log "WARN" "IPv4 count unusually high: $count ranges (expected < $CF_MAX_IPV4)"
                mv "${CF_IPV4_CACHE}.tmp" "$CF_IPV4_CACHE"
                _cf_log "INFO" "Downloaded $count IPv4 ranges"
            else
                mv "${CF_IPV4_CACHE}.tmp" "$CF_IPV4_CACHE"
                _cf_log "INFO" "Downloaded $count IPv4 ranges"
            fi
        else
            _cf_log "ERROR" "Failed to download IPv4 ranges"
            rm -f "${CF_IPV4_CACHE}.tmp"
            success=false
        fi
    fi

    # Download IPv6
    if [[ "$ipv6_enabled" == "true" ]]; then
        _cf_log "INFO" "Downloading IPv6 ranges from: $CF_IPV6_URL"

        if curl -sf --max-time 30 "$CF_IPV6_URL" -o "${CF_IPV6_CACHE}.tmp" 2>/dev/null; then
            local count
            count=$(wc -l < "${CF_IPV6_CACHE}.tmp")

            # Validate count
            if (( count < CF_MIN_IPV6 )); then
                _cf_log "ERROR" "IPv6 validation failed: only $count ranges (minimum: $CF_MIN_IPV6)"
                rm -f "${CF_IPV6_CACHE}.tmp"
                success=false
            elif (( count > CF_MAX_IPV6 )); then
                _cf_log "WARN" "IPv6 count unusually high: $count ranges (expected < $CF_MAX_IPV6)"
                mv "${CF_IPV6_CACHE}.tmp" "$CF_IPV6_CACHE"
                _cf_log "INFO" "Downloaded $count IPv6 ranges"
            else
                mv "${CF_IPV6_CACHE}.tmp" "$CF_IPV6_CACHE"
                _cf_log "INFO" "Downloaded $count IPv6 ranges"
            fi
        else
            _cf_log "ERROR" "Failed to download IPv6 ranges"
            rm -f "${CF_IPV6_CACHE}.tmp"
            success=false
        fi
    fi

    if $success; then
        return 0
    else
        return 1
    fi
}

# =============================================================================
# WRITE TO WHITELIST FILE (v0.10.0 Integration)
# =============================================================================
nftban_cloudflare_write_to_whitelist() {
    _cf_log "INFO" "Writing Cloudflare IPs to whitelist file: $CF_WHITELIST_FILE"

    # Create whitelist file with header
    cat > "$CF_WHITELIST_FILE" << 'EOF'
# =============================================================================
# NFTBan Cloudflare Whitelist (Auto-managed)
# =============================================================================
# This file is automatically managed by nftban cloudflare module
# Generated: __TIMESTAMP__
#
# DO NOT EDIT MANUALLY - Changes will be overwritten on next update
#
# Contains Cloudflare IP ranges for CDN/Proxy whitelisting
# When you use Cloudflare, all traffic comes from these IPs
# =============================================================================

EOF

    # Replace timestamp
    sed -i "s/__TIMESTAMP__/$(date -Iseconds)/" "$CF_WHITELIST_FILE"

    # Append IPv4 ranges
    if [[ -f "$CF_IPV4_CACHE" ]]; then
        {
            echo ""
            echo "# Cloudflare IPv4 Ranges"
            cat "$CF_IPV4_CACHE"
        } >> "$CF_WHITELIST_FILE"
    fi

    # Append IPv6 ranges
    if [[ -f "$CF_IPV6_CACHE" ]]; then
        {
            echo ""
            echo "# Cloudflare IPv6 Ranges"
            cat "$CF_IPV6_CACHE"
        } >> "$CF_WHITELIST_FILE"
    fi

    local total
    total=$(grep -v "^#" "$CF_WHITELIST_FILE" | grep -v "^$" | wc -l)

    _cf_log "INFO" "Wrote $total Cloudflare IP ranges to whitelist"

    return 0
}

# =============================================================================
# CLEAR WHITELIST FILE
# =============================================================================
nftban_cloudflare_clear_whitelist() {
    _cf_log "INFO" "Clearing Cloudflare whitelist file"

    cat > "$CF_WHITELIST_FILE" << 'EOF'
# =============================================================================
# NFTBan Cloudflare Whitelist (Auto-managed)
# =============================================================================
# Cloudflare integration is currently DISABLED
# This file will be populated when integration is re-enabled
#
# To enable: nftban cloudflare enable
# =============================================================================

EOF

    # Remove cache files
    rm -f "$CF_IPV4_CACHE" "$CF_IPV6_CACHE"

    _cf_log "INFO" "Cloudflare whitelist cleared"
}

# =============================================================================
# ENABLE CLOUDFLARE INTEGRATION
# =============================================================================
nftban_cloudflare_enable() {
    nftban_cloudflare_banner
    echo ""
    echo "Enabling Cloudflare Integration..."
    echo ""

    # Initialize directories
    nftban_cloudflare_init

    # Download IP ranges
    echo "⏳ Downloading Cloudflare IP ranges..."
    if ! nftban_cloudflare_download_ips; then
        echo "❌ Failed to download Cloudflare IPs"
        _cf_log "ERROR" "Failed to enable Cloudflare integration"
        return 1
    fi
    echo "✅ IP ranges downloaded successfully"

    # Write to whitelist file
    echo "⏳ Writing to whitelist file..."
    nftban_cloudflare_write_to_whitelist
    echo "✅ Whitelist file updated: $CF_WHITELIST_FILE"

    # Trigger system whitelist rebuild (v0.10.0 integration)
    if declare -f nftban_system_ip_rebuild >/dev/null 2>&1; then
        echo "⏳ Rebuilding system whitelist..."
        nftban_system_ip_rebuild
        echo "✅ System whitelist rebuilt"
    fi

    # Trigger atomic reload (v0.10.0 integration)
    if declare -f nftban_atomic_reload >/dev/null 2>&1; then
        echo "⏳ Applying to nftables..."
        nftban_atomic_reload
        echo "✅ nftables updated"
    fi

    # Update configuration
    if [[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf.local" ]]; then
        if ! grep -q "^CLOUDFLARE_ENABLED=" "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf.local" 2>/dev/null; then
            echo 'CLOUDFLARE_ENABLED="true"' >> "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf.local"
        else
            sed -i 's/^CLOUDFLARE_ENABLED=.*/CLOUDFLARE_ENABLED="true"/' "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf.local"
        fi
    fi

    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  ✅ Cloudflare Integration ENABLED                       ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""

    # Show stats
    local ipv4_count=0 ipv6_count=0
    [[ -f "$CF_IPV4_CACHE" ]] && ipv4_count=$(wc -l < "$CF_IPV4_CACHE")
    [[ -f "$CF_IPV6_CACHE" ]] && ipv6_count=$(wc -l < "$CF_IPV6_CACHE")

    echo "📊 Statistics:"
    echo "   IPv4 ranges: $ipv4_count"
    echo "   IPv6 ranges: $ipv6_count"
    echo "   Whitelist file: $CF_WHITELIST_FILE"
    echo ""

    _cf_log "INFO" "Cloudflare integration enabled ($ipv4_count IPv4, $ipv6_count IPv6)"

    return 0
}

# =============================================================================
# DISABLE CLOUDFLARE INTEGRATION
# =============================================================================
nftban_cloudflare_disable() {
    nftban_cloudflare_banner
    echo ""
    echo "Disabling Cloudflare Integration..."
    echo ""

    # Clear whitelist file
    echo "⏳ Clearing whitelist file..."
    nftban_cloudflare_clear_whitelist
    echo "✅ Whitelist file cleared"

    # Trigger system whitelist rebuild (v0.10.0 integration)
    if declare -f nftban_system_ip_rebuild >/dev/null 2>&1; then
        echo "⏳ Rebuilding system whitelist..."
        nftban_system_ip_rebuild
        echo "✅ System whitelist rebuilt"
    fi

    # Trigger atomic reload (v0.10.0 integration)
    if declare -f nftban_atomic_reload >/dev/null 2>&1; then
        echo "⏳ Applying to nftables..."
        nftban_atomic_reload
        echo "✅ nftables updated"
    fi

    # Update configuration
    if [[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf.local" ]]; then
        if ! grep -q "^CLOUDFLARE_ENABLED=" "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf.local" 2>/dev/null; then
            echo 'CLOUDFLARE_ENABLED="false"' >> "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf.local"
        else
            sed -i 's/^CLOUDFLARE_ENABLED=.*/CLOUDFLARE_ENABLED="false"/' "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf.local"
        fi
    fi

    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  ✅ Cloudflare Integration DISABLED                      ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""

    _cf_log "INFO" "Cloudflare integration disabled"

    return 0
}

# =============================================================================
# UPDATE CLOUDFLARE IP RANGES
# =============================================================================
nftban_cloudflare_update() {
    local cf_enabled="${CLOUDFLARE_ENABLED:-false}"

    if [[ "$cf_enabled" != "true" ]]; then
        echo "❌ Cloudflare integration is disabled"
        echo "   Enable first: nftban cloudflare enable"
        return 1
    fi

    nftban_cloudflare_banner
    echo ""
    echo "Updating Cloudflare IP Ranges..."
    echo ""

    # Download latest ranges
    echo "⏳ Downloading latest IP ranges..."
    if ! nftban_cloudflare_download_ips; then
        echo "❌ Failed to download IP ranges"
        return 1
    fi
    echo "✅ IP ranges downloaded"

    # Update whitelist file
    echo "⏳ Updating whitelist file..."
    nftban_cloudflare_write_to_whitelist
    echo "✅ Whitelist file updated"

    # Trigger system whitelist rebuild
    if declare -f nftban_system_ip_rebuild >/dev/null 2>&1; then
        echo "⏳ Rebuilding system whitelist..."
        nftban_system_ip_rebuild
        echo "✅ System whitelist rebuilt"
    fi

    # Trigger atomic reload
    if declare -f nftban_atomic_reload >/dev/null 2>&1; then
        echo "⏳ Applying to nftables..."
        nftban_atomic_reload
        echo "✅ nftables updated"
    fi

    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  ✅ Cloudflare IP Ranges UPDATED                         ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""

    _cf_log "INFO" "Cloudflare IP ranges updated"

    return 0
}

# =============================================================================
# SHOW CLOUDFLARE STATUS
# =============================================================================
nftban_cloudflare_status() {
    nftban_cloudflare_banner
    echo ""

    local cf_enabled="${CLOUDFLARE_ENABLED:-false}"
    local ipv4_enabled="${CLOUDFLARE_IPV4_ENABLED:-true}"
    local ipv6_enabled="${CLOUDFLARE_IPV6_ENABLED:-true}"
    local auto_update="${CLOUDFLARE_AUTO_UPDATE:-true}"

    echo "📋 Configuration:"
    echo "   Master switch: $cf_enabled"
    echo "   IPv4 enabled: $ipv4_enabled"
    echo "   IPv6 enabled: $ipv6_enabled"
    echo "   Auto-update: $auto_update"
    echo ""

    # IPv4 Cache Status
    if [[ -f "$CF_IPV4_CACHE" ]]; then
        local ipv4_count ipv4_age
        ipv4_count=$(wc -l < "$CF_IPV4_CACHE")
        ipv4_age=$(( ($(date +%s) - $(stat -c %Y "$CF_IPV4_CACHE")) / 3600 ))

        echo "📊 IPv4 Cache:"
        echo "   Ranges: $ipv4_count"
        echo "   Age: ${ipv4_age} hours"
        echo "   File: $CF_IPV4_CACHE"
    else
        echo "❌ IPv4 Cache: Not downloaded"
    fi
    echo ""

    # IPv6 Cache Status
    if [[ -f "$CF_IPV6_CACHE" ]]; then
        local ipv6_count ipv6_age
        ipv6_count=$(wc -l < "$CF_IPV6_CACHE")
        ipv6_age=$(( ($(date +%s) - $(stat -c %Y "$CF_IPV6_CACHE")) / 3600 ))

        echo "📊 IPv6 Cache:"
        echo "   Ranges: $ipv6_count"
        echo "   Age: ${ipv6_age} hours"
        echo "   File: $CF_IPV6_CACHE"
    else
        echo "❌ IPv6 Cache: Not downloaded"
    fi
    echo ""

    # Whitelist file status
    if [[ -f "$CF_WHITELIST_FILE" ]]; then
        local total
        total=$(grep -v "^#" "$CF_WHITELIST_FILE" | grep -v "^$" | wc -l)
        echo "📄 Whitelist File:"
        echo "   Total entries: $total"
        echo "   Location: $CF_WHITELIST_FILE"
    else
        echo "❌ Whitelist file not found"
    fi
    echo ""

    # Recent activity
    if [[ -f "$CF_LOG" ]]; then
        echo "📜 Recent Activity (last 5):"
        tail -5 "$CF_LOG" 2>/dev/null | sed 's/^/   /' || echo "   No activity logged"
    fi
    echo ""
}

# =============================================================================
# AUTO-UPDATE (for cron/systemd timer)
# =============================================================================
nftban_cloudflare_auto_update() {
    local cf_enabled="${CLOUDFLARE_ENABLED:-false}"
    local auto_update="${CLOUDFLARE_AUTO_UPDATE:-false}"

    if [[ "$cf_enabled" != "true" ]]; then
        _cf_log "DEBUG" "Cloudflare integration disabled, skipping auto-update"
        return 0
    fi

    if [[ "$auto_update" != "true" ]]; then
        _cf_log "DEBUG" "Auto-update disabled, skipping"
        return 0
    fi

    _cf_log "INFO" "Running auto-update..."

    # Run update silently
    if nftban_cloudflare_update &>> "$CF_LOG"; then
        _cf_log "INFO" "Auto-update completed successfully"
    else
        _cf_log "ERROR" "Auto-update failed"
    fi
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f nftban_cloudflare_banner
export -f nftban_cloudflare_init
export -f nftban_cloudflare_download_ips
export -f nftban_cloudflare_write_to_whitelist
export -f nftban_cloudflare_clear_whitelist
export -f nftban_cloudflare_enable
export -f nftban_cloudflare_disable
export -f nftban_cloudflare_update
export -f nftban_cloudflare_status
export -f nftban_cloudflare_auto_update

# =============================================================================
# END OF MODULE
# =============================================================================
