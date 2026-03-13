#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - GeoIP Database Download Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Download and update MaxMind GeoLite2 database
#
# meta:name="nftban_geoip_download"
# meta:type="core"
# meta:header="GeoIP Database Management"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
# meta:description="Manages MaxMind GeoIP database download and updates"
# meta:input="MaxMind license key from config"
# meta:output="Downloaded GeoLite2-City.mmdb database"
# meta:depends="bash,curl,tar,nftban_output.sh"
# meta:created_date="2025-11-05"
# meta:updated_date="2026-02-07"
# meta:inventory.files="/var/lib/nftban/geoip/GeoLite2-City.mmdb"
# meta:inventory.binaries="curl,tar"
# meta:inventory.env_vars="NFTBAN_GEOIP_LICENSE_KEY"
# meta:inventory.config_files="/etc/nftban/conf.d/geoip/main.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network="download.maxmind.com:443"
# meta:inventory.privileges="nftban"
# =============================================================================
set -Eeuo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

# NFTBAN_LIB_DIR is set by the calling script (cmd_geoip.sh, etc.)
# Don't set it here - just use it with fallback

# Load strict mode library
# shellcheck source=/usr/lib/nftban/lib/strict.sh
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/strict.sh" || return 1
else
    # Fallback to manual strict mode
    set -Eeuo pipefail
fi

# Load version library
# shellcheck source=/usr/lib/nftban/lib/version.sh
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/version.sh" ]]; then
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/version.sh" || return 1
fi

# Load timestamp library (with graceful fallback)
# shellcheck source=/usr/lib/nftban/lib/nftban_timestamp.sh
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_timestamp.sh" ]]; then
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_timestamp.sh" || return 1
fi

# Load file utils library (with graceful fallback)
# shellcheck source=/usr/lib/nftban/lib/nftban_file_utils.sh
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_file_utils.sh" ]]; then
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_file_utils.sh" || return 1
fi
readonly NFTBAN_CONFIG_DIR="${NFTBAN_CONFIG_DIR:-/etc/nftban}"

# Load GeoIP configuration (base + local override)
if [[ -f "${NFTBAN_CONFIG_DIR}/conf.d/geoip/main.conf" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_CONFIG_DIR}/conf.d/geoip/main.conf" || true
fi
if [[ -f "${NFTBAN_CONFIG_DIR}/conf.d/geoip/main.conf.local" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_CONFIG_DIR}/conf.d/geoip/main.conf.local" || true
fi

# Load output module
if [[ ! $(type -t nftban_render_banner) == "function" ]]; then
    if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_output.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_output.sh" || return 1
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
        echo "  ${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/geoip/main.conf.local"
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
    local db_dir="${GEOIP_DATABASE_DIR:-${NFTBAN_DATA_DIR:-/var/lib/nftban}/geoip}"
    # v1.19.0: Use mktemp instead of PID-based temp files (R16)
    local tmp_file
    tmp_file=$(mktemp "${NFTBAN_RUN_DIR:-/run/nftban}/geoip-${edition}.XXXXXX.tar.gz")

    echo "[INFO] Downloading ${edition} database..."
    echo "[DEBUG] URL: ${db_url} (key masked)"

    # v1.19.0: Use config file to pass license key, avoiding exposure in process args (R23)
    local curl_config
    curl_config=$(mktemp "${NFTBAN_RUN_DIR:-/run/nftban}/nftban-geoip-curl.XXXXXX.conf")
    chmod 600 "$curl_config"
    echo "url = \"${db_url}?edition_id=${edition}&license_key=${license_key}&suffix=tar.gz\"" > "$curl_config"

    # Download database (key in config file, not visible in /proc/*/cmdline)
    if curl --proto '=https' --tlsv1.2 -sSf \
            --connect-timeout 30 \
            --max-time "${timeout}" \
            -o "${tmp_file}" \
            -K "${curl_config}"; then
        rm -f "$curl_config"
        echo "[INFO] Download complete"
    else
        rm -f "$curl_config"
        echo "[ERROR] Download failed"
        rm -f "${tmp_file}"
        return 1
    fi

    # Create directory if it doesn't exist
    if [[ ! -d "${db_dir}" ]]; then
        mkdir -p "${db_dir}" || return 1
        chown nftban:nftban "${db_dir}"
        chmod 750 "${db_dir}"
    fi

    # Extract database
    echo "[INFO] Extracting database..."
    local extract_dir
    extract_dir=$(mktemp -d /tmp/geoip-extract.XXXXXX)

    if tar -xzf "${tmp_file}" -C "${extract_dir}"; then
        echo "[INFO] Extraction complete"
    else
        echo "[ERROR] Extraction failed"
        rm -rf "${tmp_file}" "${extract_dir}"
        return 1
    fi

    # Find and move .mmdb file
    local mmdb_file
    mmdb_file=$(find "${extract_dir}" -name "*.mmdb" | head -1)
    if [[ -z "${mmdb_file}" ]]; then
        echo "[ERROR] Database file not found in archive"
        rm -rf "${tmp_file}" "${extract_dir}"
        return 1
    fi

    # v1.19.0: Backup existing DB before overwrite + basic size validation (R04)
    local db_file
    db_file="${db_dir}/$(basename ${edition}).mmdb"

    # Validate extracted file is non-trivial (> 100KB = likely valid mmdb)
    local mmdb_size
    mmdb_size=$(stat -c %s "$mmdb_file" 2>/dev/null || echo 0)
    if [[ $mmdb_size -lt 102400 ]]; then
        echo "[ERROR] Extracted database file is too small (${mmdb_size} bytes), possibly corrupt"
        rm -rf "${tmp_file}" "${extract_dir}"
        return 1
    fi

    # Backup existing database before overwrite
    if [[ -f "${db_file}" ]]; then
        cp -p "${db_file}" "${db_file}.backup"
        echo "[INFO] Backed up existing database to ${db_file}.backup"
    fi

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
    # Auto-detect GeoIP database from config
    local db_file=""
    local geoip_dir="${NFTBAN_DATA_DIR:-/var/lib/nftban}/geoip"
    if [[ -n "${NFTBAN_GEOIP_DATABASE:-}" ]] && [[ -f "${NFTBAN_GEOIP_DATABASE}" ]]; then
        db_file="${NFTBAN_GEOIP_DATABASE}"
    else
        for db_name in ${NFTBAN_GEOIP_DATABASES:-dbip-country-lite.mmdb GeoLite2-City.mmdb GeoLite2-Country.mmdb}; do
            [[ -f "${geoip_dir}/${db_name}" ]] && db_file="${geoip_dir}/${db_name}" && break
        done
    fi

    if [[ -z "${db_file}" ]] || [[ ! -f "${db_file}" ]]; then
        echo "[WARNING] GeoIP database not found in ${geoip_dir}"
        return 1
    fi

    echo "[INFO] GeoIP database found"
    echo "[INFO] Location: ${db_file}"
    echo "[INFO] Size: $(du -h "${db_file}" | cut -f1)"

    # Get modification time - use shared library with graceful fallback
    local db_mtime db_modified
    if declare -f nftban_file_mtime &>/dev/null; then
        db_mtime=$(nftban_file_mtime "${db_file}")
    else
        # Fallback: cross-platform stat
        db_mtime=$(stat -c %Y "${db_file}" 2>/dev/null || stat -f %m "${db_file}" 2>/dev/null || echo 0)
    fi
    # Format modification time
    if declare -f nftban_timestamp_from_unix &>/dev/null; then
        db_modified=$(nftban_timestamp_from_unix "${db_mtime}")
    else
        # Fallback: GNU date with BSD fallback
        db_modified=$(date -d "@${db_mtime}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || \
                      date -r "${db_mtime}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || \
                      echo "unknown")
    fi
    echo "[INFO] Modified: ${db_modified}"

    # Check if database is old (> 30 days)
    local age_seconds age
    # Use shared library with graceful fallback
    if declare -f nftban_file_age &>/dev/null; then
        age_seconds=$(nftban_file_age "${db_file}")
    else
        # Fallback: inline calculation using mtime already obtained
        local now
        now=$(date +%s)
        age_seconds=$(( now - db_mtime ))
    fi
    age=$(( age_seconds / 86400 ))

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

nftban_geoip_db_status() {
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
    nftban_banner "geoip"

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
      sudo systemctl enable --now nftban-core-geoip.timer

    Check timer status:
      systemctl status nftban-core-geoip.timer

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
            nftban_geoip_db_status
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
