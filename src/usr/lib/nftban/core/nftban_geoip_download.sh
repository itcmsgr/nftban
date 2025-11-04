#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.10.0 - GeoIP Database Download Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Download and update MaxMind GeoLite2 database
#
# meta:name=nftban_geoip_download
# meta:type=core
# meta:header=GeoIP Database Management
# meta:version=0.30.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Manages MaxMind GeoIP database download and updates
# meta:input=MaxMind license key from config
# meta:output=Downloaded GeoLite2-City.mmdb database
#
# **Inventory & Requirements**
# meta:depends=bash,curl,tar,nftban_output.sh
#
# meta:created_date=2025-10-31
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

readonly NFTBAN_LIB_DIR="${NFTBAN_LIB_DIR:-/usr/lib/nftban}"
readonly NFTBAN_CONF_DIR="${NFTBAN_CONF_DIR:-/etc/nftban}"

# Load GeoIP configuration
if [[ -f "${NFTBAN_CONF_DIR}/conf.d/geoip.conf" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_CONF_DIR}/conf.d/geoip.conf"
fi

# Load output module
if [[ ! $(type -t nftban_render_banner) == "function" ]]; then
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"
    fi
fi

# =============================================================================
# FUNCTIONS
# =============================================================================

# Check if license key is configured
_check_license_key() {
    if [[ -z "${MAXMIND_LICENSE_KEY:-}" ]]; then
        echo "[ERROR] MaxMind license key not configured"
        echo ""
        echo "Please add your license key to:"
        echo "  /etc/nftban/conf.d/geoip.conf"
        echo ""
        echo "Get a free license key at:"
        echo "  https://www.maxmind.com/en/geolite2/signup"
        return 1
    fi
    return 0
}

# Download GeoIP database
_download_geoip() {
    local license_key="${MAXMIND_LICENSE_KEY}"
    local edition="${GEOIP_EDITION:-GeoLite2-City}"
    local db_url="${GEOIP_DOWNLOAD_URL:-https://download.maxmind.com/app/geoip_download}"
    local timeout="${GEOIP_TIMEOUT:-300}"
    local db_dir="${GEOIP_DATABASE_DIR:-/var/lib/nftban/geoip}"
    local tmp_file="/tmp/geoip-${edition}-$$.tar.gz"

    echo "[INFO] Downloading ${edition} database..."
    echo "[DEBUG] URL: ${db_url}"

    # Build download URL with parameters
    local download_url="${db_url}?edition_id=${edition}&license_key=${license_key}&suffix=tar.gz"

    # Download database
    if curl --proto '=https' --tlsv1.2 -sSf \
            --connect-timeout 30 \
            --max-time "${timeout}" \
            -o "${tmp_file}" \
            "${download_url}"; then
        echo "[INFO] Download complete"
    else
        echo "[ERROR] Download failed"
        rm -f "${tmp_file}"
        return 1
    fi

    # Create directory if it doesn't exist
    if [[ ! -d "${db_dir}" ]]; then
        mkdir -p "${db_dir}"
        chown nftban:nftban "${db_dir}"
        chmod 750 "${db_dir}"
    fi

    # Extract database
    echo "[INFO] Extracting database..."
    local extract_dir="/tmp/geoip-extract-$$"
    mkdir -p "${extract_dir}"

    if tar -xzf "${tmp_file}" -C "${extract_dir}"; then
        echo "[INFO] Extraction complete"
    else
        echo "[ERROR] Extraction failed"
        rm -rf "${tmp_file}" "${extract_dir}"
        return 1
    fi

    # Find and move .mmdb file
    local mmdb_file=$(find "${extract_dir}" -name "*.mmdb" | head -1)
    if [[ -z "${mmdb_file}" ]]; then
        echo "[ERROR] Database file not found in archive"
        rm -rf "${tmp_file}" "${extract_dir}"
        return 1
    fi

    # Move database to final location
    local db_file="${db_dir}/$(basename ${edition}).mmdb"
    mv "${mmdb_file}" "${db_file}"
    chown nftban:nftban "${db_file}"
    chmod 640 "${db_file}"

    echo "[INFO] Database installed: ${db_file}"
    echo "[INFO] File size: $(du -h ${db_file} | cut -f1)"

    # Cleanup
    rm -rf "${tmp_file}" "${extract_dir}"

    return 0
}

# Check database status
_check_database() {
    local db_file="${GEOIP_DATABASE:-/var/lib/nftban/geoip/GeoLite2-City.mmdb}"

    if [[ ! -f "${db_file}" ]]; then
        echo "[WARNING] GeoIP database not found: ${db_file}"
        return 1
    fi

    echo "[INFO] GeoIP database found"
    echo "[INFO] Location: ${db_file}"
    echo "[INFO] Size: $(du -h ${db_file} | cut -f1)"
    echo "[INFO] Modified: $(stat -c %y ${db_file} | cut -d. -f1)"

    # Check if database is old (> 30 days)
    local mtime=$(stat -c %Y "${db_file}")
    local now=$(date +%s)
    local age=$(( (now - mtime) / 86400 ))

    if [[ ${age} -gt 30 ]]; then
        echo "[WARNING] Database is ${age} days old (recommended: update monthly)"
    else
        echo "[INFO] Database age: ${age} days (OK)"
    fi

    return 0
}

# =============================================================================
# MAIN FUNCTIONS
# =============================================================================

nftban_geoip_download() {
    echo "═══════════════════════════════════════════════════════════════"
    echo "  MaxMind GeoIP Database Download"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    _check_license_key || return 1
    _download_geoip || return 1

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Download Complete!"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "Test GeoIP lookup:"
    echo "  nftban geoip lookup 8.8.8.8"
    echo ""

    return 0
}

nftban_geoip_status() {
    echo "═══════════════════════════════════════════════════════════════"
    echo "  GeoIP Database Status"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    _check_license_key
    echo ""
    _check_database

    echo ""
    echo "═══════════════════════════════════════════════════════════════"

    return 0
}

nftban_geoip_update() {
    echo "[INFO] Updating GeoIP database..."
    nftban_geoip_download
}

# =============================================================================
# HELP TEXT
# =============================================================================

_nftban_geoip_help() {
    nftban_render_banner simple

    cat <<'HELP'

USAGE:
    nftban geoip <command>

COMMANDS:
    download        Download GeoIP database (first time)
    update          Update GeoIP database
    status          Show database status
    lookup <ip>     Test GeoIP lookup for IP

CONFIGURATION:
    Edit: /etc/nftban/conf.d/geoip.conf

    Required:
      MAXMIND_LICENSE_KEY="your_key_here"

    Get free license key at:
      https://www.maxmind.com/en/geolite2/signup

EXAMPLES:
    # Initial setup
    sudo nftban geoip download

    # Check status
    nftban geoip status

    # Update database
    sudo nftban geoip update

    # Test lookup
    nftban geoip lookup 8.8.8.8

AUTO-UPDATE:
    Enable weekly updates:
      sudo systemctl enable --now nftban-geoip-update.timer

    Check timer status:
      systemctl status nftban-geoip-update.timer

NOTES:
    - GeoLite2 database is free but requires license key
    - Database updated weekly by MaxMind
    - Recommended: enable auto-update timer
    - Database size: ~70 MB

HELP
}

# =============================================================================
# CLI ENTRY POINT
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-help}" in
        download)
            nftban_geoip_download
            ;;
        update)
            nftban_geoip_update
            ;;
        status)
            nftban_geoip_status
            ;;
        help|--help|-h)
            _nftban_geoip_help
            ;;
        *)
            echo "ERROR: Unknown command: ${1:-}"
            echo "Run: nftban geoip help"
            exit 1
            ;;
    esac
fi
