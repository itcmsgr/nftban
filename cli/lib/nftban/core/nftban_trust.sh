#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.1.0 - Trust Core Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Trusted provider IP range management (CDN, Cloud providers)
#
# meta:name="nftban_trust"
# meta:type="module"
# meta:header="Trust Integration Module"
# meta:version="1.1.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Downloads and manages trusted provider IP ranges for whitelisting"
# meta:input="Provider API endpoints (Cloudflare, AWS, Google, Azure, etc.)"
# meta:output="Whitelist files and nftables integration"
# meta:depends="bash,curl,jq,nftban_output.sh,nftban_system_ip.sh"
# meta:created_date="2026-01-15"
# meta:updated_date="2026-01-15"
#
# meta:inventory.files="nftban_output.sh,nftban_system_ip.sh,strict.sh"
# meta:inventory.binaries="curl,jq"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR,TRUST_CACHE_DIR"
# meta:inventory.config_files="conf.d/trust.conf,nftban.conf.local"
# meta:inventory.systemd_units=""
# meta:inventory.network="outbound:https (provider APIs)"
# meta:inventory.privileges="root"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Module guard - prevent double-loading
[[ -n "${NFTBAN_TRUST_LOADED:-}" ]] && return 0
readonly NFTBAN_TRUST_LOADED=1

# =============================================================================
# MODULE CONFIGURATION
# =============================================================================
# shellcheck disable=SC2034  # Module metadata used when sourced
readonly TRUST_MODULE_NAME="nftban_trust"
# shellcheck disable=SC2034  # Module metadata - reserved for future module registry
readonly TRUST_MODULE_VERSION="1.1.0"

# FHS Paths
readonly TRUST_CACHE_DIR="${TRUST_CACHE_DIR:-/var/cache/nftban/trust}"
readonly TRUST_DATA_DIR="${TRUST_DATA_DIR:-/var/lib/nftban/trust}"
readonly TRUST_WHITELIST_DIR="${NFTBAN_CONFIG_DIR:-/etc/nftban}/whitelist.d"
readonly TRUST_LOG="${TRUST_LOG_FILE:-${NFTBAN_LOG_DIR:-/var/log/nftban}/trust.log}"
readonly TRUST_CONFIG_LOCAL="${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf.local"

# NFTables table names
readonly _TRUST_TABLE_IPV4="${NFTBAN_TABLE_IPV4:-ip nftban}"
readonly _TRUST_TABLE_IPV6="${NFTBAN_TABLE_IPV6:-ip6 nftban}"

# =============================================================================
# PROVIDER DEFINITIONS
# =============================================================================
# Each provider has: name, ipv4_url, ipv6_url, parser, min_ranges, max_ranges

declare -A TRUST_PROVIDERS

# Cloudflare
TRUST_PROVIDERS[CLOUDFLARE_NAME]="Cloudflare"
TRUST_PROVIDERS[CLOUDFLARE_DESC]="CDN/Proxy service"
TRUST_PROVIDERS[CLOUDFLARE_IPV4_URL]="https://www.cloudflare.com/ips-v4"
TRUST_PROVIDERS[CLOUDFLARE_IPV6_URL]="https://www.cloudflare.com/ips-v6"
TRUST_PROVIDERS[CLOUDFLARE_PARSER]="plain"
TRUST_PROVIDERS[CLOUDFLARE_MIN]=10
TRUST_PROVIDERS[CLOUDFLARE_MAX]=100

# AWS
TRUST_PROVIDERS[AWS_NAME]="Amazon Web Services"
TRUST_PROVIDERS[AWS_DESC]="AWS IP ranges"
TRUST_PROVIDERS[AWS_IPV4_URL]="https://ip-ranges.amazonaws.com/ip-ranges.json"
TRUST_PROVIDERS[AWS_IPV6_URL]="https://ip-ranges.amazonaws.com/ip-ranges.json"
TRUST_PROVIDERS[AWS_PARSER]="aws_json"
TRUST_PROVIDERS[AWS_MIN]=100
TRUST_PROVIDERS[AWS_MAX]=10000

# Google Cloud
TRUST_PROVIDERS[GOOGLE_NAME]="Google Cloud"
TRUST_PROVIDERS[GOOGLE_DESC]="GCP IP ranges"
TRUST_PROVIDERS[GOOGLE_IPV4_URL]="https://www.gstatic.com/ipranges/cloud.json"
TRUST_PROVIDERS[GOOGLE_IPV6_URL]="https://www.gstatic.com/ipranges/cloud.json"
TRUST_PROVIDERS[GOOGLE_PARSER]="google_json"
TRUST_PROVIDERS[GOOGLE_MIN]=50
TRUST_PROVIDERS[GOOGLE_MAX]=5000

# Azure
TRUST_PROVIDERS[AZURE_NAME]="Microsoft Azure"
TRUST_PROVIDERS[AZURE_DESC]="Azure IP ranges"
TRUST_PROVIDERS[AZURE_IPV4_URL]="https://download.microsoft.com/download/7/1/D/71D86715-5596-4529-9B13-DA13A5DE5B63/ServiceTags_Public_Weekly.json"
TRUST_PROVIDERS[AZURE_IPV6_URL]=""
TRUST_PROVIDERS[AZURE_PARSER]="azure_json"
TRUST_PROVIDERS[AZURE_MIN]=100
TRUST_PROVIDERS[AZURE_MAX]=50000

# DigitalOcean
TRUST_PROVIDERS[DIGITALOCEAN_NAME]="DigitalOcean"
TRUST_PROVIDERS[DIGITALOCEAN_DESC]="DO IP ranges"
TRUST_PROVIDERS[DIGITALOCEAN_IPV4_URL]="https://digitalocean.com/geo/google.csv"
TRUST_PROVIDERS[DIGITALOCEAN_IPV6_URL]=""
TRUST_PROVIDERS[DIGITALOCEAN_PARSER]="do_csv"
TRUST_PROVIDERS[DIGITALOCEAN_MIN]=10
TRUST_PROVIDERS[DIGITALOCEAN_MAX]=500

# Fastly
TRUST_PROVIDERS[FASTLY_NAME]="Fastly"
TRUST_PROVIDERS[FASTLY_DESC]="Fastly CDN"
TRUST_PROVIDERS[FASTLY_IPV4_URL]="https://api.fastly.com/public-ip-list"
TRUST_PROVIDERS[FASTLY_IPV6_URL]="https://api.fastly.com/public-ip-list"
TRUST_PROVIDERS[FASTLY_PARSER]="fastly_json"
TRUST_PROVIDERS[FASTLY_MIN]=10
TRUST_PROVIDERS[FASTLY_MAX]=200

# QUIC.cloud (LiteSpeed CDN)
TRUST_PROVIDERS[QUICCLOUD_NAME]="QUIC.cloud"
TRUST_PROVIDERS[QUICCLOUD_DESC]="LiteSpeed CDN"
TRUST_PROVIDERS[QUICCLOUD_IPV4_URL]="https://quic.cloud/ips"
TRUST_PROVIDERS[QUICCLOUD_IPV6_URL]=""
TRUST_PROVIDERS[QUICCLOUD_PARSER]="quiccloud_html"
TRUST_PROVIDERS[QUICCLOUD_MIN]=50
TRUST_PROVIDERS[QUICCLOUD_MAX]=500

# Provider list (uppercase keys) - use array to avoid IFS issues
readonly -a TRUST_PROVIDER_LIST=(CLOUDFLARE QUICCLOUD AWS GOOGLE AZURE DIGITALOCEAN FASTLY)

# =============================================================================
# LOGGING
# =============================================================================
_trust_log() {
    local level="$1"; shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    mkdir -p "$(dirname "$TRUST_LOG")" || return 1

    if [[ ! -f "$TRUST_LOG" ]]; then
        touch "$TRUST_LOG"
        if getent group nftban-auditor >/dev/null 2>&1; then
            chown nftban:nftban-auditor "$TRUST_LOG" 2>/dev/null || chown nftban:nftban "$TRUST_LOG" 2>/dev/null || true
        else
            chown nftban:nftban "$TRUST_LOG" 2>/dev/null || true
        fi
        chmod 640 "$TRUST_LOG" 2>/dev/null || true
    fi

    echo "[${timestamp}] [${level}] ${message}" >> "$TRUST_LOG"

    # Also log to system if nftban_log_* available
    local log_func="nftban_log_${level,,}"
    if declare -f "$log_func" >/dev/null 2>&1; then
        "$log_func" "TRUST: ${message}"
    fi
}

# =============================================================================
# BANNER
# =============================================================================
nftban_trust_banner() {
    cat <<'BANNER'
+--------------------------------------------------------------------------+
|  Trusted Providers Management                                            |
|  NFTBan — Open-source Linux IPS and nftables firewall manager            |
+--------------------------------------------------------------------------+
BANNER
}

# =============================================================================
# INITIALIZATION
# =============================================================================
nftban_trust_init() {
    mkdir -p "$TRUST_CACHE_DIR" "$TRUST_DATA_DIR" "$TRUST_WHITELIST_DIR" || return 1
    mkdir -p "$(dirname "$TRUST_LOG")" || return 1
    _trust_log "INFO" "Trust module initialized"
}

# =============================================================================
# PROVIDER HELPERS
# =============================================================================
_trust_is_enabled() {
    local provider="${1^^}"
    local var_name="TRUST_${provider}_ENABLED"
    local value="${!var_name:-false}"
    [[ "$value" == "true" ]]
}

_trust_get_provider_name() {
    local provider="${1^^}"
    echo "${TRUST_PROVIDERS[${provider}_NAME]:-$provider}"
}

_trust_get_whitelist_file() {
    local provider="${1^^}"
    echo "${TRUST_WHITELIST_DIR}/30-trust-${provider,,}.conf"
}

_trust_get_cache_file() {
    local provider="${1^^}"
    local version="$2"  # ipv4 or ipv6
    echo "${TRUST_CACHE_DIR}/${provider,,}-${version}.txt"
}

# =============================================================================
# PARSERS FOR DIFFERENT PROVIDER FORMATS
# =============================================================================
_trust_parse_plain() {
    # Plain text, one CIDR per line
    cat
}

_trust_parse_aws_json() {
    local version="$1"  # ipv4 or ipv6
    if [[ "$version" == "ipv4" ]]; then
        jq -r '.prefixes[].ip_prefix // empty' 2>/dev/null | sort -u
    else
        jq -r '.ipv6_prefixes[].ipv6_prefix // empty' 2>/dev/null | sort -u
    fi
}

_trust_parse_google_json() {
    local version="$1"
    if [[ "$version" == "ipv4" ]]; then
        jq -r '.prefixes[].ipv4Prefix // empty' 2>/dev/null | sort -u
    else
        jq -r '.prefixes[].ipv6Prefix // empty' 2>/dev/null | sort -u
    fi
}

_trust_parse_azure_json() {
    local version="$1"
    if [[ "$version" == "ipv4" ]]; then
        jq -r '.values[].properties.addressPrefixes[]? // empty' 2>/dev/null | grep -E '^[0-9]+\.' | sort -u
    else
        jq -r '.values[].properties.addressPrefixes[]? // empty' 2>/dev/null | grep -E ':' | sort -u
    fi
}

_trust_parse_do_csv() {
    # DigitalOcean CSV format: network,country,region
    cut -d',' -f1 2>/dev/null | grep -E '^[0-9]+\.|:' | sort -u
}

_trust_parse_fastly_json() {
    local version="$1"
    if [[ "$version" == "ipv4" ]]; then
        jq -r '.addresses[]' 2>/dev/null | sort -u
    else
        jq -r '.ipv6_addresses[]' 2>/dev/null | sort -u
    fi
}

_trust_parse_quiccloud_html() {
    # QUIC.cloud returns IPs separated by <br /> in HTML
    # Bare IPs (no CIDR) — whitelist parser handles both formats
    # Loaded via whitelist.d/30-trust-quiccloud.conf (same pipeline as all feeds)
    sed 's/<br \/>/\n/g; s/<br>/\n/g; s/<[^>]*>//g' | \
        grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | \
        sed 's/[[:space:]]*$//' | \
        sort -u
}

# =============================================================================
# DOWNLOAD IP RANGES
# =============================================================================
_trust_download_provider() {
    local provider="${1^^}"
    local name="${TRUST_PROVIDERS[${provider}_NAME]:-$provider}"
    local ipv4_url="${TRUST_PROVIDERS[${provider}_IPV4_URL]:-}"
    local ipv6_url="${TRUST_PROVIDERS[${provider}_IPV6_URL]:-}"
    local parser="${TRUST_PROVIDERS[${provider}_PARSER]:-plain}"
    local min="${TRUST_PROVIDERS[${provider}_MIN]:-5}"
    local max="${TRUST_PROVIDERS[${provider}_MAX]:-10000}"
    local success=true

    _trust_log "INFO" "Downloading $name IP ranges..."

    # Download IPv4
    if [[ -n "$ipv4_url" ]]; then
        local ipv4_cache
        ipv4_cache=$(_trust_get_cache_file "$provider" "ipv4")
        local ipv4_tmp="${ipv4_cache}.tmp"

        if curl -sf --max-time 60 "$ipv4_url" -o "$ipv4_tmp" 2>/dev/null; then
            # Parse based on format
            local parsed_file="${ipv4_tmp}.parsed"
            case "$parser" in
                plain)      _trust_parse_plain < "$ipv4_tmp" > "$parsed_file" ;;
                aws_json)   _trust_parse_aws_json "ipv4" < "$ipv4_tmp" > "$parsed_file" ;;
                google_json) _trust_parse_google_json "ipv4" < "$ipv4_tmp" > "$parsed_file" ;;
                azure_json) _trust_parse_azure_json "ipv4" < "$ipv4_tmp" > "$parsed_file" ;;
                do_csv)     _trust_parse_do_csv < "$ipv4_tmp" > "$parsed_file" ;;
                fastly_json) _trust_parse_fastly_json "ipv4" < "$ipv4_tmp" > "$parsed_file" ;;
                quiccloud_html) _trust_parse_quiccloud_html < "$ipv4_tmp" > "$parsed_file" ;;
                *)          _trust_parse_plain < "$ipv4_tmp" > "$parsed_file" ;;
            esac

            local count
            count=$(wc -l < "$parsed_file" 2>/dev/null || echo 0)

            if (( count < min )); then
                _trust_log "ERROR" "$name IPv4 validation failed: only $count ranges (minimum: $min)"
                rm -f "$ipv4_tmp" "$parsed_file"
                success=false
            elif (( count > max )); then
                _trust_log "WARN" "$name IPv4 count high: $count ranges (expected < $max)"
                mv "$parsed_file" "$ipv4_cache"
                rm -f "$ipv4_tmp"
                _trust_log "INFO" "Downloaded $count $name IPv4 ranges"
            else
                mv "$parsed_file" "$ipv4_cache"
                rm -f "$ipv4_tmp"
                _trust_log "INFO" "Downloaded $count $name IPv4 ranges"
            fi
        else
            _trust_log "ERROR" "Failed to download $name IPv4 ranges from $ipv4_url"
            rm -f "$ipv4_tmp"
            success=false
        fi
    fi

    # Download IPv6 (if URL different from IPv4 or provider has separate endpoint)
    if [[ -n "$ipv6_url" && "$ipv6_url" != "$ipv4_url" ]]; then
        local ipv6_cache
        ipv6_cache=$(_trust_get_cache_file "$provider" "ipv6")
        local ipv6_tmp="${ipv6_cache}.tmp"

        if curl -sf --max-time 60 "$ipv6_url" -o "$ipv6_tmp" 2>/dev/null; then
            local parsed_file="${ipv6_tmp}.parsed"
            case "$parser" in
                plain)      _trust_parse_plain < "$ipv6_tmp" > "$parsed_file" ;;
                aws_json)   _trust_parse_aws_json "ipv6" < "$ipv6_tmp" > "$parsed_file" ;;
                google_json) _trust_parse_google_json "ipv6" < "$ipv6_tmp" > "$parsed_file" ;;
                fastly_json) _trust_parse_fastly_json "ipv6" < "$ipv6_tmp" > "$parsed_file" ;;
                *)          cat "$ipv6_tmp" | grep -E ':' > "$parsed_file" || true ;;
            esac

            local count
            count=$(wc -l < "$parsed_file" 2>/dev/null || echo 0)

            if (( count > 0 )); then
                mv "$parsed_file" "$ipv6_cache"
                _trust_log "INFO" "Downloaded $count $name IPv6 ranges"
            fi
            rm -f "$ipv6_tmp" "${ipv6_tmp}.parsed"
        fi
    elif [[ "$ipv6_url" == "$ipv4_url" && -n "$ipv6_url" ]]; then
        # Same URL contains both IPv4 and IPv6 - already downloaded, just extract IPv6
        local ipv4_cache ipv6_cache
        ipv4_cache=$(_trust_get_cache_file "$provider" "ipv4")
        ipv6_cache=$(_trust_get_cache_file "$provider" "ipv6")

        # Re-parse for IPv6 from the same source
        if [[ -f "${ipv4_cache}.tmp" ]] || curl -sf --max-time 60 "$ipv6_url" -o "${ipv6_cache}.raw" 2>/dev/null; then
            local raw_file="${ipv6_cache}.raw"
            [[ ! -f "$raw_file" ]] && raw_file="${ipv4_cache}.tmp"

            if [[ -f "$raw_file" ]]; then
                case "$parser" in
                    aws_json)   _trust_parse_aws_json "ipv6" < "$raw_file" > "$ipv6_cache" ;;
                    google_json) _trust_parse_google_json "ipv6" < "$raw_file" > "$ipv6_cache" ;;
                    fastly_json) _trust_parse_fastly_json "ipv6" < "$raw_file" > "$ipv6_cache" ;;
                    *)          grep -E ':' "$raw_file" > "$ipv6_cache" 2>/dev/null || true ;;
                esac
                rm -f "${ipv6_cache}.raw"
                local count
                count=$(wc -l < "$ipv6_cache" 2>/dev/null || echo 0)
                [[ $count -gt 0 ]] && _trust_log "INFO" "Extracted $count $name IPv6 ranges"
            fi
        fi
    fi

    $success && return 0 || return 1
}

# =============================================================================
# WRITE TO WHITELIST
# =============================================================================
_trust_write_whitelist() {
    local provider="${1^^}"
    local name="${TRUST_PROVIDERS[${provider}_NAME]:-$provider}"
    local whitelist_file
    whitelist_file=$(_trust_get_whitelist_file "$provider")
    local ipv4_cache ipv6_cache
    ipv4_cache=$(_trust_get_cache_file "$provider" "ipv4")
    ipv6_cache=$(_trust_get_cache_file "$provider" "ipv6")

    _trust_log "INFO" "Writing $name IPs to whitelist: $whitelist_file"

    # Create whitelist file with header
    cat > "$whitelist_file" << EOF
# =============================================================================
# NFTBan Trusted Provider Whitelist: $name
# =============================================================================
# This file is automatically managed by nftban trust module
# Generated: $(date -Iseconds)
#
# DO NOT EDIT MANUALLY - Changes will be overwritten on next update
#
# Provider: $name
# =============================================================================

EOF

    local total=0

    # Append IPv4 ranges
    if [[ -f "$ipv4_cache" ]]; then
        {
            echo "# $name IPv4 Ranges"
            cat "$ipv4_cache"
            echo ""
        } >> "$whitelist_file"
        total=$((total + $(wc -l < "$ipv4_cache")))
    fi

    # Append IPv6 ranges
    if [[ -f "$ipv6_cache" ]]; then
        {
            echo "# $name IPv6 Ranges"
            cat "$ipv6_cache"
            echo ""
        } >> "$whitelist_file"
        total=$((total + $(wc -l < "$ipv6_cache")))
    fi

    # Set correct permissions
    chmod 640 "$whitelist_file" 2>/dev/null || true
    chown root:nftban "$whitelist_file" 2>/dev/null || true

    _trust_log "INFO" "Wrote $total $name IP ranges to whitelist"
}

# =============================================================================
# CLEAR WHITELIST
# =============================================================================
_trust_clear_whitelist() {
    local provider="${1^^}"
    local name="${TRUST_PROVIDERS[${provider}_NAME]:-$provider}"
    local whitelist_file
    whitelist_file=$(_trust_get_whitelist_file "$provider")

    if [[ -f "$whitelist_file" ]]; then
        rm -f "$whitelist_file"
        _trust_log "INFO" "Removed $name whitelist file"
    fi

    # Remove cache files
    rm -f "$(_trust_get_cache_file "$provider" "ipv4")"
    rm -f "$(_trust_get_cache_file "$provider" "ipv6")"
}

# =============================================================================
# ATOMIC NFT SET UPDATE VIA IPC
# =============================================================================
# Loads trust provider CIDRs into whitelist nft sets atomically via IPC.
# Same pattern as feeds (nft_ipc_apply_ruleset) and geoban modules.
# No firewall reload needed — elements are added directly to live sets.

_trust_apply_to_nft() {
    local provider="${1^^}"
    local ipv4_cache ipv6_cache
    ipv4_cache=$(_trust_get_cache_file "$provider" "ipv4")
    ipv6_cache=$(_trust_get_cache_file "$provider" "ipv6")

    # Source IPC library if not already loaded
    if ! type -t nft_ipc_apply_ruleset >/dev/null 2>&1; then
        local ipc_lib="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nft_ipc.sh"
        if [[ -f "$ipc_lib" ]]; then
            # shellcheck source=/dev/null
            source "$ipc_lib" 2>/dev/null || true
        fi
    fi

    # Guard: IPC must be available
    if ! type -t nft_ipc_apply_ruleset >/dev/null 2>&1; then
        _trust_log "WARNING" "IPC unavailable — run 'nftban sync' to apply trust IPs"
        echo "[!] IPC unavailable — run 'nftban sync' to apply trust IPs"
        return 1
    fi

    # Build atomic nft fragment from cache files
    local nft_fragment
    nft_fragment=$(mktemp "${NFTBAN_RUN_DIR:-/run/nftban}/nftban_trust_frag_XXXXXX.nft") || return 1

    local ipv4_count=0 ipv6_count=0

    # IPv4 CIDRs
    if [[ -f "$ipv4_cache" ]] && [[ -s "$ipv4_cache" ]]; then
        local ipv4_elements
        ipv4_elements=$(grep -v '^#' "$ipv4_cache" | grep -v '^\s*$' | tr '\n' ',' | sed 's/,$//')
        if [[ -n "$ipv4_elements" ]]; then
            echo "add element ${_TRUST_TABLE_IPV4} whitelist_ipv4 { ${ipv4_elements} }" >> "$nft_fragment"
            ipv4_count=$(grep -cv '^\s*$\|^#' "$ipv4_cache" 2>/dev/null || echo 0)
        fi
    fi

    # IPv6 CIDRs
    if [[ -f "$ipv6_cache" ]] && [[ -s "$ipv6_cache" ]]; then
        local ipv6_elements
        ipv6_elements=$(grep -v '^#' "$ipv6_cache" | grep -v '^\s*$' | tr '\n' ',' | sed 's/,$//')
        if [[ -n "$ipv6_elements" ]]; then
            echo "add element ${_TRUST_TABLE_IPV6} whitelist_ipv6 { ${ipv6_elements} }" >> "$nft_fragment"
            ipv6_count=$(grep -cv '^\s*$\|^#' "$ipv6_cache" 2>/dev/null || echo 0)
        fi
    fi

    # Apply via IPC if we have elements
    if [[ -s "$nft_fragment" ]]; then
        if nft_ipc_apply_ruleset "$nft_fragment" 2>/dev/null; then
            _trust_log "INFO" "Applied ${ipv4_count} IPv4 + ${ipv6_count} IPv6 CIDRs to whitelist sets"
            rm -f "$nft_fragment"
            return 0
        else
            _trust_log "ERROR" "Failed to apply trust CIDRs via IPC"
            rm -f "$nft_fragment"
            return 1
        fi
    fi

    rm -f "$nft_fragment"
    return 0
}

_trust_remove_from_nft() {
    local provider="${1^^}"
    local ipv4_cache ipv6_cache
    ipv4_cache=$(_trust_get_cache_file "$provider" "ipv4")
    ipv6_cache=$(_trust_get_cache_file "$provider" "ipv6")

    # Source IPC library if not already loaded
    if ! type -t nft_ipc_apply_ruleset >/dev/null 2>&1; then
        local ipc_lib="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nft_ipc.sh"
        if [[ -f "$ipc_lib" ]]; then
            # shellcheck source=/dev/null
            source "$ipc_lib" 2>/dev/null || true
        fi
    fi

    if ! type -t nft_ipc_apply_ruleset >/dev/null 2>&1; then
        _trust_log "WARNING" "IPC unavailable — run 'nftban sync' to remove trust IPs"
        echo "[!] IPC unavailable — run 'nftban sync' to remove trust IPs"
        return 1
    fi

    # Build atomic nft fragment to delete elements
    local nft_fragment
    nft_fragment=$(mktemp "${NFTBAN_RUN_DIR:-/run/nftban}/nftban_trust_frag_XXXXXX.nft") || return 1

    # IPv4 CIDRs
    if [[ -f "$ipv4_cache" ]] && [[ -s "$ipv4_cache" ]]; then
        local ipv4_elements
        ipv4_elements=$(grep -v '^#' "$ipv4_cache" | grep -v '^\s*$' | tr '\n' ',' | sed 's/,$//')
        if [[ -n "$ipv4_elements" ]]; then
            echo "delete element ${_TRUST_TABLE_IPV4} whitelist_ipv4 { ${ipv4_elements} }" >> "$nft_fragment"
        fi
    fi

    # IPv6 CIDRs
    if [[ -f "$ipv6_cache" ]] && [[ -s "$ipv6_cache" ]]; then
        local ipv6_elements
        ipv6_elements=$(grep -v '^#' "$ipv6_cache" | grep -v '^\s*$' | tr '\n' ',' | sed 's/,$//')
        if [[ -n "$ipv6_elements" ]]; then
            echo "delete element ${_TRUST_TABLE_IPV6} whitelist_ipv6 { ${ipv6_elements} }" >> "$nft_fragment"
        fi
    fi

    if [[ -s "$nft_fragment" ]]; then
        nft_ipc_apply_ruleset "$nft_fragment" 2>/dev/null || true
        _trust_log "INFO" "Removed ${provider} CIDRs from whitelist sets"
    fi

    rm -f "$nft_fragment"
    return 0
}

# =============================================================================
# PUBLIC FUNCTIONS
# =============================================================================

nftban_trust_list_providers() {
    for provider in "${TRUST_PROVIDER_LIST[@]}"; do
        local name="${TRUST_PROVIDERS[${provider}_NAME]:-$provider}"
        local desc="${TRUST_PROVIDERS[${provider}_DESC]:-}"
        printf "    %-15s %s\n" "$provider" "$desc"
    done
}

nftban_trust_list() {
    # JSON output mode (v1.19.13)
    if [[ "${NFTBAN_JSON:-}" == "true" ]]; then
        local json_array="["
        local first=true
        for provider in "${TRUST_PROVIDER_LIST[@]}"; do
            local name="${TRUST_PROVIDERS[${provider}_NAME]:-$provider}"
            local enabled="false"
            _trust_is_enabled "$provider" && enabled="true"

            local ipv4_count=0 ipv6_count=0
            local ipv4_cache ipv6_cache
            ipv4_cache=$(_trust_get_cache_file "$provider" "ipv4")
            ipv6_cache=$(_trust_get_cache_file "$provider" "ipv6")
            [[ -f "$ipv4_cache" ]] && ipv4_count=$(wc -l < "$ipv4_cache")
            [[ -f "$ipv6_cache" ]] && ipv6_count=$(wc -l < "$ipv6_cache")

            [[ "$first" == "true" ]] && first=false || json_array+=","
            json_array+="{\"provider\":\"$provider\",\"name\":\"$name\",\"enabled\":$enabled,\"ipv4_count\":$ipv4_count,\"ipv6_count\":$ipv6_count}"
        done
        json_array+="]"
        echo "{\"providers\":$json_array}"
        return 0
    fi

    # Human-readable output
    nftban_trust_banner
    echo ""
    echo "Available Trusted Providers:"
    echo ""
    printf "  %-15s %-25s %-10s\n" "PROVIDER" "NAME" "STATUS"
    printf "  %-15s %-25s %-10s\n" "--------" "----" "------"

    for provider in "${TRUST_PROVIDER_LIST[@]}"; do
        local name="${TRUST_PROVIDERS[${provider}_NAME]:-$provider}"
        local status="disabled"
        _trust_is_enabled "$provider" && status="ENABLED"

        if [[ "$status" == "ENABLED" ]]; then
            printf "  %-15s %-25s \e[32m%-10s\e[0m\n" "$provider" "$name" "$status"
        else
            printf "  %-15s %-25s %-10s\n" "$provider" "$name" "$status"
        fi
    done
    echo ""
}

nftban_trust_enable() {
    local provider="${1^^}"

    # Validate provider
    if [[ ! " ${TRUST_PROVIDER_LIST[*]} " =~ [[:space:]]${provider}[[:space:]] ]]; then
        echo "ERROR: Unknown provider: $provider" >&2
        echo ""
        echo "Available providers:"
        nftban_trust_list_providers
        return 1
    fi

    local name="${TRUST_PROVIDERS[${provider}_NAME]:-$provider}"

    nftban_trust_banner
    echo ""
    echo "Enabling $name..."
    echo ""

    # Initialize
    nftban_trust_init

    # Download IP ranges
    echo "[*] Downloading $name IP ranges..."
    if ! _trust_download_provider "$provider"; then
        echo "[X] Failed to download $name IPs"
        return 1
    fi
    echo "[OK] IP ranges downloaded"

    # Write to whitelist
    echo "[*] Writing to whitelist..."
    _trust_write_whitelist "$provider"
    echo "[OK] Whitelist updated"

    # Update configuration
    if [[ ! -f "$TRUST_CONFIG_LOCAL" ]]; then
        touch "$TRUST_CONFIG_LOCAL"
        chmod 644 "$TRUST_CONFIG_LOCAL"
    fi

    local var_name="TRUST_${provider}_ENABLED"
    if ! grep -q "^${var_name}=" "$TRUST_CONFIG_LOCAL" 2>/dev/null; then
        echo "${var_name}=\"true\"" >> "$TRUST_CONFIG_LOCAL"
    else
        sed -i "s/^${var_name}=.*/${var_name}=\"true\"/" "$TRUST_CONFIG_LOCAL"
    fi

    # v1.25.0: Atomically apply CIDRs to whitelist nft sets via IPC (no reload)
    echo "[*] Applying to firewall..."
    if _trust_apply_to_nft "$provider"; then
        echo "[OK] Firewall updated"
    else
        echo "[!] IPC unavailable — run 'nftban sync' to apply"
    fi

    echo ""
    echo "+----------------------------------------------------------+"
    echo "|  [OK] $name ENABLED"
    echo "+----------------------------------------------------------+"
    echo ""

    # Show stats
    local ipv4_count=0 ipv6_count=0
    local ipv4_cache ipv6_cache
    ipv4_cache=$(_trust_get_cache_file "$provider" "ipv4")
    ipv6_cache=$(_trust_get_cache_file "$provider" "ipv6")
    [[ -f "$ipv4_cache" ]] && ipv4_count=$(wc -l < "$ipv4_cache")
    [[ -f "$ipv6_cache" ]] && ipv6_count=$(wc -l < "$ipv6_cache")

    echo "Statistics:"
    echo "   IPv4 ranges: $ipv4_count"
    echo "   IPv6 ranges: $ipv6_count"
    echo "   Whitelist: $(_trust_get_whitelist_file "$provider")"
    echo ""

    _trust_log "INFO" "$name enabled ($ipv4_count IPv4, $ipv6_count IPv6)"
    return 0
}

nftban_trust_disable() {
    local provider="${1^^}"

    # Validate provider
    if [[ ! " ${TRUST_PROVIDER_LIST[*]} " =~ [[:space:]]${provider}[[:space:]] ]]; then
        echo "ERROR: Unknown provider: $provider" >&2
        return 1
    fi

    local name="${TRUST_PROVIDERS[${provider}_NAME]:-$provider}"

    nftban_trust_banner
    echo ""
    echo "Disabling $name..."
    echo ""

    # v1.25.0: Remove CIDRs from nft sets BEFORE clearing cache files
    echo "[*] Removing from firewall..."
    _trust_remove_from_nft "$provider" && echo "[OK] Firewall updated" || echo "[!] Manual sync may be needed"

    # Clear whitelist and cache files
    echo "[*] Removing whitelist..."
    _trust_clear_whitelist "$provider"
    echo "[OK] Whitelist removed"

    # Update configuration
    local var_name="TRUST_${provider}_ENABLED"
    if [[ -f "$TRUST_CONFIG_LOCAL" ]]; then
        if grep -q "^${var_name}=" "$TRUST_CONFIG_LOCAL" 2>/dev/null; then
            sed -i "s/^${var_name}=.*/${var_name}=\"false\"/" "$TRUST_CONFIG_LOCAL"
        else
            echo "${var_name}=\"false\"" >> "$TRUST_CONFIG_LOCAL"
        fi
    fi

    echo ""
    echo "+----------------------------------------------------------+"
    echo "|  [OK] $name DISABLED"
    echo "+----------------------------------------------------------+"
    echo ""

    _trust_log "INFO" "$name disabled"
    return 0
}

nftban_trust_update() {
    local provider="${1^^}"

    if ! _trust_is_enabled "$provider"; then
        echo "ERROR: $provider is not enabled" >&2
        echo "Enable first: sudo nftban trust enable $provider" >&2
        return 1
    fi

    local name="${TRUST_PROVIDERS[${provider}_NAME]:-$provider}"

    echo "[*] Updating $name IP ranges..."

    if ! _trust_download_provider "$provider"; then
        echo "[X] Failed to update $name"
        return 1
    fi

    _trust_write_whitelist "$provider"
    echo "[OK] $name updated"

    _trust_log "INFO" "$name IP ranges updated"
    return 0
}

nftban_trust_update_all() {
    nftban_trust_banner
    echo ""
    echo "Updating all enabled providers..."
    echo ""

    local updated=0
    local failed=0

    for provider in "${TRUST_PROVIDER_LIST[@]}"; do
        if _trust_is_enabled "$provider"; then
            local name="${TRUST_PROVIDERS[${provider}_NAME]:-$provider}"
            echo "[*] Updating $name..."
            if _trust_download_provider "$provider" && _trust_write_whitelist "$provider"; then
                echo "[OK] $name updated"
                # v1.19.20 FIX
                ((updated++)) || true
            else
                echo "[X] $name failed"
                # v1.19.20 FIX
                ((failed++)) || true
            fi
        fi
    done

    echo ""
    echo "Summary: $updated updated, $failed failed"

    # v1.25.0: Atomically apply all enabled provider CIDRs via IPC
    if (( updated > 0 )); then
        echo "[*] Applying to firewall..."
        local apply_ok=true
        for provider in "${TRUST_PROVIDER_LIST[@]}"; do
            if _trust_is_enabled "$provider"; then
                _trust_apply_to_nft "$provider" || apply_ok=false
            fi
        done
        $apply_ok && echo "[OK] Firewall updated" || echo "[!] Some providers failed — run 'nftban sync'"
    fi

    _trust_log "INFO" "Trust update complete: $updated updated, $failed failed"
    return 0
}

nftban_trust_load() {
    echo "[*] Loading trust whitelists into firewall..."

    local loaded=0
    for provider in "${TRUST_PROVIDER_LIST[@]}"; do
        if _trust_is_enabled "$provider"; then
            local whitelist_file
            whitelist_file=$(_trust_get_whitelist_file "$provider")
            if [[ -f "$whitelist_file" ]]; then
                # v1.25.0: Atomically apply to nft sets via IPC
                if _trust_apply_to_nft "$provider"; then
                    echo "   Loaded: $provider"
                    ((loaded++)) || true
                else
                    echo "   Failed: $provider"
                fi
            fi
        fi
    done

    if (( loaded > 0 )); then
        echo "[OK] $loaded trust provider(s) loaded into firewall"
    else
        echo "[!] No providers loaded — check enabled status with 'nftban trust list'"
    fi
    return 0
}

nftban_trust_status() {
    local provider="${1^^}"
    local name="${TRUST_PROVIDERS[${provider}_NAME]:-$provider}"
    local ipv4_cache ipv6_cache whitelist_file
    ipv4_cache=$(_trust_get_cache_file "$provider" "ipv4")
    ipv6_cache=$(_trust_get_cache_file "$provider" "ipv6")
    whitelist_file=$(_trust_get_whitelist_file "$provider")

    local enabled="false"
    _trust_is_enabled "$provider" && enabled="true"

    local ipv4_count=0 ipv6_count=0 ipv4_age_hours=0 ipv6_age_hours=0
    local whitelist_entries=0 last_refresh=""

    if [[ -f "$ipv4_cache" ]]; then
        ipv4_count=$(wc -l < "$ipv4_cache")
        ipv4_age_hours=$(( ($(date +%s) - $(stat -c %Y "$ipv4_cache")) / 3600 ))
        last_refresh=$(date -d "@$(stat -c %Y "$ipv4_cache")" -Iseconds 2>/dev/null || stat -c %Y "$ipv4_cache")
    fi

    if [[ -f "$ipv6_cache" ]]; then
        ipv6_count=$(wc -l < "$ipv6_cache")
        ipv6_age_hours=$(( ($(date +%s) - $(stat -c %Y "$ipv6_cache")) / 3600 ))
    fi

    if [[ -f "$whitelist_file" ]]; then
        whitelist_entries=$({ grep -v "^#" "$whitelist_file" | grep -v "^$" || true; } | wc -l)
    fi

    # JSON output mode (v1.19.13)
    if [[ "${NFTBAN_JSON:-}" == "true" ]]; then
        cat <<EOF
{"provider":"$provider","name":"$name","enabled":$enabled,"ipv4_count":$ipv4_count,"ipv6_count":$ipv6_count,"ipv4_age_hours":$ipv4_age_hours,"ipv6_age_hours":$ipv6_age_hours,"whitelist_entries":$whitelist_entries,"last_refresh":"$last_refresh"}
EOF
        return 0
    fi

    # Human-readable output
    echo ""
    echo "Provider: $name ($provider)"
    echo "Status: $([[ "$enabled" == "true" ]] && echo "ENABLED" || echo "disabled")"
    echo ""

    if [[ -f "$ipv4_cache" ]]; then
        echo "IPv4 Cache:"
        echo "   Ranges: $ipv4_count"
        echo "   Age: ${ipv4_age_hours} hours"
    else
        echo "IPv4 Cache: Not downloaded"
    fi

    if [[ -f "$ipv6_cache" ]]; then
        local count age
        count=$(wc -l < "$ipv6_cache")
        age=$(( ($(date +%s) - $(stat -c %Y "$ipv6_cache")) / 3600 ))
        echo "IPv6 Cache:"
        echo "   Ranges: $count"
        echo "   Age: ${age} hours"
    else
        echo "IPv6 Cache: Not available"
    fi

    if [[ -f "$whitelist_file" ]]; then
        local total
        total=$({ grep -v "^#" "$whitelist_file" | grep -v "^$" || true; } | wc -l)
        echo "Whitelist: $whitelist_file ($total entries)"
    else
        echo "Whitelist: Not created"
    fi
    echo ""
}

nftban_trust_status_all() {
    local enabled_count=0
    local total_ranges=0
    local total_providers=${#TRUST_PROVIDER_LIST[@]}

    # Collect data for all providers
    for provider in "${TRUST_PROVIDER_LIST[@]}"; do
        if _trust_is_enabled "$provider"; then
            # v1.19.20 FIX
            ((enabled_count++)) || true
            local ipv4_cache ipv6_cache
            ipv4_cache=$(_trust_get_cache_file "$provider" "ipv4")
            ipv6_cache=$(_trust_get_cache_file "$provider" "ipv6")
            [[ -f "$ipv4_cache" ]] && total_ranges=$((total_ranges + $(wc -l < "$ipv4_cache")))
            [[ -f "$ipv6_cache" ]] && total_ranges=$((total_ranges + $(wc -l < "$ipv6_cache")))
        fi
    done

    # JSON output mode (v1.19.13)
    if [[ "${NFTBAN_JSON:-}" == "true" ]]; then
        local json_array="["
        local first=true
        for provider in "${TRUST_PROVIDER_LIST[@]}"; do
            local name="${TRUST_PROVIDERS[${provider}_NAME]:-$provider}"
            local enabled="false"
            local ipv4_count=0 ipv6_count=0
            if _trust_is_enabled "$provider"; then
                enabled="true"
                local ipv4_cache ipv6_cache
                ipv4_cache=$(_trust_get_cache_file "$provider" "ipv4")
                ipv6_cache=$(_trust_get_cache_file "$provider" "ipv6")
                [[ -f "$ipv4_cache" ]] && ipv4_count=$(wc -l < "$ipv4_cache")
                [[ -f "$ipv6_cache" ]] && ipv6_count=$(wc -l < "$ipv6_cache")
            fi
            [[ "$first" == "true" ]] && first=false || json_array+=","
            json_array+="{\"provider\":\"$provider\",\"name\":\"$name\",\"enabled\":$enabled,\"ipv4_count\":$ipv4_count,\"ipv6_count\":$ipv6_count}"
        done
        json_array+="]"
        echo "{\"enabled_count\":$enabled_count,\"total_providers\":$total_providers,\"total_ranges\":$total_ranges,\"providers\":$json_array}"
        return 0
    fi

    # Human-readable output
    nftban_trust_banner
    echo ""

    echo "Summary:"
    echo "   Enabled providers: $enabled_count / $total_providers"
    echo "   Total IP ranges: $total_ranges"
    echo ""

    echo "Provider Status:"
    printf "  %-15s %-10s %10s %10s\n" "PROVIDER" "STATUS" "IPv4" "IPv6"
    printf "  %-15s %-10s %10s %10s\n" "--------" "------" "----" "----"

    for provider in "${TRUST_PROVIDER_LIST[@]}"; do
        local status="disabled"
        local ipv4_count="-" ipv6_count="-"

        if _trust_is_enabled "$provider"; then
            status="ENABLED"
            local ipv4_cache ipv6_cache
            ipv4_cache=$(_trust_get_cache_file "$provider" "ipv4")
            ipv6_cache=$(_trust_get_cache_file "$provider" "ipv6")
            [[ -f "$ipv4_cache" ]] && ipv4_count=$(wc -l < "$ipv4_cache")
            [[ -f "$ipv6_cache" ]] && ipv6_count=$(wc -l < "$ipv6_cache")
        fi

        if [[ "$status" == "ENABLED" ]]; then
            printf "  %-15s \e[32m%-10s\e[0m %10s %10s\n" "$provider" "$status" "$ipv4_count" "$ipv6_count"
        else
            printf "  %-15s %-10s %10s %10s\n" "$provider" "$status" "$ipv4_count" "$ipv6_count"
        fi
    done
    echo ""

    # Recent activity
    if [[ -f "$TRUST_LOG" ]]; then
        echo "Recent Activity:"
        tail -5 "$TRUST_LOG" 2>/dev/null | sed 's/^/   /' || echo "   No activity logged"
    fi
    echo ""
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f nftban_trust_banner
export -f nftban_trust_init
export -f nftban_trust_list
export -f nftban_trust_list_providers
export -f nftban_trust_enable
export -f nftban_trust_disable
export -f nftban_trust_update
export -f nftban_trust_update_all
export -f nftban_trust_load
export -f nftban_trust_status
export -f nftban_trust_status_all

# =============================================================================
# END OF MODULE
# =============================================================================
