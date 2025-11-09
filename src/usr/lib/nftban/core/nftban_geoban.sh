#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.32.21 - GeoBan Core Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Wrapper for Go-based country blocking (nftban-geoip geoban)
#
# meta:name=nftban_geoban
# meta:type=core
# meta:header=GeoBan Core
# meta:version=0.32.21
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Country-based IP blocking using nftban-geoip Go binary
# meta:input=Country codes (ISO alpha-2)
# meta:output=IP lists to nftables, tracking JSON to /etc/nftban/geoban.d/
#
# **Inventory & Requirements**
# meta:depends=bash,nftban-geoip (Go binary)
#
# meta:created_date=2025-11-05
# =============================================================================

set -Eeuo pipefail

# Simple output functions (self-contained, no dependencies)
nftban_info() { echo "[INFO] $*"; }
nftban_success() { echo "[SUCCESS] $*"; }
nftban_error() { echo "[ERROR] $*" >&2; }
nftban_warn() { echo "[WARN] $*" >&2; }

# Load configuration
[[ -f /etc/nftban/conf.d/nftban-go.conf ]] && source /etc/nftban/conf.d/nftban-go.conf
[[ -f /etc/nftban/conf.d/nftban-go.conf.local ]] && source /etc/nftban/conf.d/nftban-go.conf.local

# =============================================================================
# CONFIGURATION DEFAULTS
# =============================================================================

: "${GEOBAN_ENABLED:=true}"
: "${GEOBAN_ATOMIC:=true}"
: "${GEOBAN_FILES_DIR:=/etc/nftban/geoban.d}"
: "${GEOBAN_CACHE_DIR:=/var/cache/nftban/geoban}"
: "${GEOBAN_TRACKING_DIR:=/var/lib/nftban/geoban/tracking}"

# Binary location (architecture detection)
GEOIP_BINARY=""
if [[ -f /usr/lib/nftban/bin/.real/nftban-geoip-x86_64 ]] && [[ "$(uname -m)" == "x86_64" ]]; then
    GEOIP_BINARY="/usr/lib/nftban/bin/.real/nftban-geoip-x86_64"
elif [[ -f /usr/lib/nftban/bin/.real/nftban-geoip-aarch64 ]] && [[ "$(uname -m)" == "aarch64" ]]; then
    GEOIP_BINARY="/usr/lib/nftban/bin/.real/nftban-geoip-aarch64"
elif [[ -f /usr/lib/nftban/bin/nftban-geoip ]]; then
    GEOIP_BINARY="/usr/lib/nftban/bin/nftban-geoip"
fi

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Check if GeoBan is enabled
nftban_geoban_check_enabled() {
    if [[ "${GEOBAN_ENABLED}" != "true" ]]; then
        nftban_error "GeoBan is disabled in configuration"
        nftban_info "Enable it in /etc/nftban/conf.d/nftban-go.conf.local:"
        nftban_info "  GEOBAN_ENABLED=\"true\""
        return 1
    fi
    return 0
}

# Check if Go binary exists
nftban_geoban_check_binary() {
    if [[ -z "${GEOIP_BINARY}" ]] || [[ ! -x "${GEOIP_BINARY}" ]]; then
        nftban_error "nftban-geoip binary not found or not executable"
        nftban_info "Expected location: /usr/lib/nftban/bin/.real/nftban-geoip-$(uname -m)"
        nftban_info "Run: scripts/build-go-binaries.sh to build it"
        return 1
    fi
    return 0
}

# Ensure directories exist
nftban_geoban_ensure_directories() {
    mkdir -p "${GEOBAN_FILES_DIR}" 2>/dev/null
    mkdir -p "${GEOBAN_CACHE_DIR}" 2>/dev/null
    mkdir -p "${GEOBAN_TRACKING_DIR}" 2>/dev/null

    # Set permissions
    chmod 750 "${GEOBAN_FILES_DIR}" 2>/dev/null
    chmod 750 "${GEOBAN_CACHE_DIR}" 2>/dev/null
    chmod 750 "${GEOBAN_TRACKING_DIR}" 2>/dev/null
}

# Validate country code
nftban_geoban_validate_country_code() {
    local cc="$1"

    # Must be exactly 2 uppercase letters
    if [[ ! "${cc}" =~ ^[A-Z]{2}$ ]]; then
        nftban_error "Invalid country code: ${cc}"
        nftban_info "Country codes must be 2-letter ISO alpha-2 (e.g., US, GB, CN, RU)"
        return 1
    fi

    return 0
}

# =============================================================================
# CORE FUNCTIONS
# =============================================================================

# Ban countries (add to blacklist)
nftban_geoban_ban_countries() {
    local countries=("$@")

    # Checks
    nftban_geoban_check_enabled || return 1
    nftban_geoban_check_binary || return 1
    nftban_geoban_ensure_directories

    if [[ ${#countries[@]} -eq 0 ]]; then
        nftban_error "No countries specified"
        nftban_info "Usage: nftban geoip ban <CC> [CC...]"
        nftban_info "Example: nftban geoip ban CN RU KP"
        return 1
    fi

    # Process each country
    local success=0
    local failed=0

    for cc in "${countries[@]}"; do
        # Uppercase country code
        cc=$(echo "${cc}" | tr '[:lower:]' '[:upper:]')

        # Validate
        nftban_geoban_validate_country_code "${cc}" || {
            ((failed++))
            continue
        }

        nftban_info "Banning country: ${cc}"

        # Call Go binary
        if "${GEOIP_BINARY}" geoban fetch "${cc}" \
            --action ban \
            --atomic="${GEOBAN_ATOMIC}" \
            --files-dir="${GEOBAN_FILES_DIR}" \
            --tracking-dir="${GEOBAN_TRACKING_DIR}" \
            --cache-dir="${GEOBAN_CACHE_DIR}"; then

            nftban_success "Successfully banned ${cc}"
            ((success++))
        else
            nftban_error "Failed to ban ${cc}"
            ((failed++))
        fi
    done

    # Summary
    echo ""
    nftban_info "Summary: ${success} succeeded, ${failed} failed"

    if [[ ${success} -gt 0 ]]; then
        nftban_info "View banned countries: nftban geoip list"
    fi

    [[ ${failed} -eq 0 ]] && return 0 || return 1
}

# Remove country ban
nftban_geoban_unban_countries() {
    local countries=("$@")

    # Checks
    nftban_geoban_check_enabled || return 1
    nftban_geoban_check_binary || return 1

    if [[ ${#countries[@]} -eq 0 ]]; then
        nftban_error "No countries specified"
        nftban_info "Usage: nftban geoip unban <CC> [CC...]"
        nftban_info "Example: nftban geoip unban CN RU"
        return 1
    fi

    # Process each country
    local success=0
    local failed=0

    for cc in "${countries[@]}"; do
        # Uppercase country code
        cc=$(echo "${cc}" | tr '[:lower:]' '[:upper:]')

        # Validate
        nftban_geoban_validate_country_code "${cc}" || {
            ((failed++))
            continue
        }

        nftban_info "Unbanning country: ${cc}"

        # Call Go binary
        if "${GEOIP_BINARY}" geoban remove "${cc}" \
            --action ban \
            --atomic="${GEOBAN_ATOMIC}" \
            --files-dir="${GEOBAN_FILES_DIR}" \
            --tracking-dir="${GEOBAN_TRACKING_DIR}"; then

            nftban_success "Successfully unbanned ${cc}"
            ((success++))
        else
            nftban_error "Failed to unban ${cc}"
            ((failed++))
        fi
    done

    # Summary
    echo ""
    nftban_info "Summary: ${success} succeeded, ${failed} failed"

    [[ ${failed} -eq 0 ]] && return 0 || return 1
}

# Whitelist countries
nftban_geoban_whitelist_countries() {
    local countries=("$@")

    # Checks
    nftban_geoban_check_enabled || return 1
    nftban_geoban_check_binary || return 1
    nftban_geoban_ensure_directories

    if [[ ${#countries[@]} -eq 0 ]]; then
        nftban_error "No countries specified"
        nftban_info "Usage: nftban geoip whitelist <CC> [CC...]"
        nftban_info "Example: nftban geoip whitelist US GB DE"
        return 1
    fi

    # Process each country
    local success=0
    local failed=0

    for cc in "${countries[@]}"; do
        # Uppercase country code
        cc=$(echo "${cc}" | tr '[:lower:]' '[:upper:]')

        # Validate
        nftban_geoban_validate_country_code "${cc}" || {
            ((failed++))
            continue
        }

        nftban_info "Whitelisting country: ${cc}"

        # Call Go binary
        if "${GEOIP_BINARY}" geoban fetch "${cc}" \
            --action whitelist \
            --atomic="${GEOBAN_ATOMIC}" \
            --files-dir="${GEOBAN_FILES_DIR}" \
            --tracking-dir="${GEOBAN_TRACKING_DIR}" \
            --cache-dir="${GEOBAN_CACHE_DIR}"; then

            nftban_success "Successfully whitelisted ${cc}"
            ((success++))
        else
            nftban_error "Failed to whitelist ${cc}"
            ((failed++))
        fi
    done

    # Summary
    echo ""
    nftban_info "Summary: ${success} succeeded, ${failed} failed"

    if [[ ${success} -gt 0 ]]; then
        nftban_info "View whitelisted countries: nftban geoip list"
    fi

    [[ ${failed} -eq 0 ]] && return 0 || return 1
}

# Remove country whitelist
nftban_geoban_unwhitelist_countries() {
    local countries=("$@")

    # Checks
    nftban_geoban_check_enabled || return 1
    nftban_geoban_check_binary || return 1

    if [[ ${#countries[@]} -eq 0 ]]; then
        nftban_error "No countries specified"
        nftban_info "Usage: nftban geoip unwhitelist <CC> [CC...]"
        nftban_info "Example: nftban geoip unwhitelist US"
        return 1
    fi

    # Process each country
    local success=0
    local failed=0

    for cc in "${countries[@]}"; do
        # Uppercase country code
        cc=$(echo "${cc}" | tr '[:lower:]' '[:upper:]')

        # Validate
        nftban_geoban_validate_country_code "${cc}" || {
            ((failed++))
            continue
        }

        nftban_info "Removing whitelist for country: ${cc}"

        # Call Go binary
        if "${GEOIP_BINARY}" geoban remove "${cc}" \
            --action whitelist \
            --atomic="${GEOBAN_ATOMIC}" \
            --files-dir="${GEOBAN_FILES_DIR}" \
            --tracking-dir="${GEOBAN_TRACKING_DIR}"; then

            nftban_success "Successfully removed whitelist for ${cc}"
            ((success++))
        else
            nftban_error "Failed to remove whitelist for ${cc}"
            ((failed++))
        fi
    done

    # Summary
    echo ""
    nftban_info "Summary: ${success} succeeded, ${failed} failed"

    [[ ${failed} -eq 0 ]] && return 0 || return 1
}

# List active GeoBan countries
nftban_geoban_list() {
    nftban_geoban_check_enabled || return 1

    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  🌍 GeoBan Active Countries                              ║"
    echo "║  nftban — Simplifying Linux Firewall Management         ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""

    # Check for banned countries
    local banned_files=("${GEOBAN_FILES_DIR}"/50-ban-*.conf)
    local banned_count=0

    if [[ -e "${banned_files[0]}" ]]; then
        echo "🚫 Banned Countries:"
        for file in "${banned_files[@]}"; do
            if [[ -f "${file}" ]]; then
                local cc
                cc=$(basename "${file}" | sed -n 's/50-ban-\(.*\)\.conf/\1/p')
                local ipv4_count
                ipv4_count=$(grep -c "^[0-9]" "${file}" 2>/dev/null || echo "0")
                local ipv6_count
                ipv6_count=$(grep -c ":" "${file}" 2>/dev/null || echo "0")
                echo "   ${cc} - ${ipv4_count} IPv4 ranges, ${ipv6_count} IPv6 ranges"
                ((banned_count++))
            fi
        done
        echo ""
    else
        echo "🚫 Banned Countries: None"
        echo ""
    fi

    # Check for whitelisted countries
    local whitelist_files=("${GEOBAN_FILES_DIR}"/40-whitelist-*.conf)
    local whitelist_count=0

    if [[ -e "${whitelist_files[0]}" ]]; then
        echo "✅ Whitelisted Countries:"
        for file in "${whitelist_files[@]}"; do
            if [[ -f "${file}" ]]; then
                local cc
                cc=$(basename "${file}" | sed -n 's/40-whitelist-\(.*\)\.conf/\1/p')
                local ipv4_count
                ipv4_count=$(grep -c "^[0-9]" "${file}" 2>/dev/null || echo "0")
                local ipv6_count
                ipv6_count=$(grep -c ":" "${file}" 2>/dev/null || echo "0")
                echo "   ${cc} - ${ipv4_count} IPv4 ranges, ${ipv6_count} IPv6 ranges"
                ((whitelist_count++))
            fi
        done
        echo ""
    else
        echo "✅ Whitelisted Countries: None"
        echo ""
    fi

    # Summary
    echo "📊 Summary:"
    echo "   Banned: ${banned_count}"
    echo "   Whitelisted: ${whitelist_count}"
    echo "   Files directory: ${GEOBAN_FILES_DIR}"
    echo ""

    # Usage hints
    if [[ ${banned_count} -eq 0 ]] && [[ ${whitelist_count} -eq 0 ]]; then
        echo "💡 Usage:"
        echo "   nftban geoip ban CN RU       - Ban China and Russia"
        echo "   nftban geoip whitelist US GB - Whitelist US and UK"
        echo ""
    fi
}

# Update all active GeoBan countries
nftban_geoban_update() {
    nftban_geoban_check_enabled || return 1
    nftban_geoban_check_binary || return 1

    nftban_info "Updating all active GeoBan countries..."
    echo ""

    # Find all active countries
    local all_files=("${GEOBAN_FILES_DIR}"/*-*.conf)
    local updated=0
    local failed=0

    if [[ ! -e "${all_files[0]}" ]]; then
        nftban_warn "No GeoBan countries configured"
        nftban_info "Use: nftban geoip ban <CC> to add countries"
        return 0
    fi

    for file in "${all_files[@]}"; do
        if [[ -f "${file}" ]]; then
            local basename
            basename=$(basename "${file}" .conf)
            local cc=""
            local action=""

            # Parse filename: 50-ban-CN.conf or 40-whitelist-US.conf
            if [[ "${basename}" =~ ^[0-9]+-ban-(.*)$ ]]; then
                cc="${BASH_REMATCH[1]}"
                action="ban"
            elif [[ "${basename}" =~ ^[0-9]+-whitelist-(.*)$ ]]; then
                cc="${BASH_REMATCH[1]}"
                action="whitelist"
            else
                continue
            fi

            nftban_info "Updating ${action}: ${cc}"

            # Call Go binary
            if "${GEOIP_BINARY}" geoban fetch "${cc}" \
                --action "${action}" \
                --atomic="${GEOBAN_ATOMIC}" \
                --files-dir="${GEOBAN_FILES_DIR}" \
                --tracking-dir="${GEOBAN_TRACKING_DIR}" \
                --cache-dir="${GEOBAN_CACHE_DIR}"; then

                ((updated++))
            else
                nftban_error "Failed to update ${cc}"
                ((failed++))
            fi
        fi
    done

    # Summary
    echo ""
    nftban_info "Update complete: ${updated} updated, ${failed} failed"

    [[ ${failed} -eq 0 ]] && return 0 || return 1
}

# Show GeoBan status
nftban_geoban_status() {
    nftban_geoban_check_enabled || return 1

    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  🌍 GeoBan Status                                        ║"
    echo "║  nftban — Simplifying Linux Firewall Management         ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""

    # Configuration
    echo "📋 Configuration:"
    echo "   Enabled: ${GEOBAN_ENABLED}"
    echo "   Atomic operations: ${GEOBAN_ATOMIC}"
    echo "   Files directory: ${GEOBAN_FILES_DIR}"
    echo "   Cache directory: ${GEOBAN_CACHE_DIR}"
    echo "   Tracking directory: ${GEOBAN_TRACKING_DIR}"
    echo ""

    # Binary status
    echo "🔧 Go Binary:"
    if [[ -n "${GEOIP_BINARY}" ]] && [[ -x "${GEOIP_BINARY}" ]]; then
        local version
        version=$("${GEOIP_BINARY}" version 2>/dev/null | grep -oP 'v\S+' || echo "unknown")
        echo "   Binary: ${GEOIP_BINARY}"
        echo "   Version: ${version}"
        echo "   Status: ✅ Available"
    else
        echo "   Status: ❌ Not found"
    fi
    echo ""

    # Active countries count
    local banned_count
    banned_count=$(ls -1 "${GEOBAN_FILES_DIR}"/50-ban-*.conf 2>/dev/null | wc -l)
    local whitelist_count
    whitelist_count=$(ls -1 "${GEOBAN_FILES_DIR}"/40-whitelist-*.conf 2>/dev/null | wc -l)

    echo "📊 Active Countries:"
    echo "   Banned: ${banned_count}"
    echo "   Whitelisted: ${whitelist_count}"
    echo ""

    # Cache status
    if [[ -d "${GEOBAN_CACHE_DIR}" ]]; then
        local cache_files=$(find "${GEOBAN_CACHE_DIR}" -type f 2>/dev/null | wc -l)
        local cache_size=$(du -sh "${GEOBAN_CACHE_DIR}" 2>/dev/null | awk '{print $1}')
        echo "💾 Cache:"
        echo "   Files: ${cache_files}"
        echo "   Size: ${cache_size}"
    fi
    echo ""

    # Commands
    echo "💡 Commands:"
    echo "   nftban geoip ban <CC>        - Ban country"
    echo "   nftban geoip unban <CC>      - Remove ban"
    echo "   nftban geoip whitelist <CC>  - Whitelist country"
    echo "   nftban geoip list            - List active countries"
    echo "   nftban geoip update          - Update all countries"
    echo ""
}

# =============================================================================
# END OF MODULE
# =============================================================================
