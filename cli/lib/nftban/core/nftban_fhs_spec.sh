#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - FHS Specification
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Canonical FHS directory specification for NFTBan
#
# meta:name=nftban_fhs_spec
# meta:type=core
# meta:header=FHS Specification
# meta:version=1.0.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Single source of truth for FHS directory specifications
# meta:input=None (defines constants)
# meta:output=FHS path constants and validation functions
#
# **Inventory & Requirements**
# meta:depends=bash
#
# meta:created_date=2025-11-05
# meta:updated_date=2025-11-24
# =============================================================================

# Strict mode
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_FHS_SPEC_LOADED:-}" ]] && return 0
readonly NFTBAN_FHS_SPEC_LOADED=1

# =============================================================================
# CANONICAL FHS SPECIFICATION
# =============================================================================

declare -g -A NFTBAN_FHS_DIRECTORIES=()

nftban_fhs_load_spec() {
    # Load canonical FHS directory specification
    # Format: NFTBAN_FHS_DIRECTORIES[path]="perms|owner|group|purpose"

    # ─────────────────────────────────────────────────────────────────────
    # System Directories (root:root) - System libraries and binaries
    # ─────────────────────────────────────────────────────────────────────
    # NOTE: /usr/sbin is SECURITY-CHECK only (owner must be root:root)
    # Perms vary by distro (555 on RHEL/Fedora, 755 on Debian) - use wildcard
    NFTBAN_FHS_DIRECTORIES["/usr/sbin"]="*|root|root|System binaries (SECURITY: must be root:root, perms vary by OS)"
    NFTBAN_FHS_DIRECTORIES["/usr/lib/nftban"]="755|root|root|Application libraries and modules"
    NFTBAN_FHS_DIRECTORIES["/usr/lib/nftban/core"]="755|root|root|Core modules"
    NFTBAN_FHS_DIRECTORIES["/usr/lib/nftban/cli"]="755|root|root|CLI command modules"
    NFTBAN_FHS_DIRECTORIES["/usr/lib/nftban/bin"]="755|root|root|Application binaries (GO, etc.)"
    NFTBAN_FHS_DIRECTORIES["/usr/lib/nftban/tests"]="755|root|root|Test scripts (smoke tests, validation)"
    NFTBAN_FHS_DIRECTORIES["/usr/lib/nftban/helpers"]="755|root|root|Helper scripts (trace, autoheal)"

    # ─────────────────────────────────────────────────────────────────────
    # Configuration (root:nftban, 750/640) - Daemon needs read access
    # ─────────────────────────────────────────────────────────────────────
    NFTBAN_FHS_DIRECTORIES["/etc/nftban"]="750|root|nftban|Configuration files (daemon readable via group)"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/conf.d"]="750|root|nftban|Module configurations (daemon readable via group)"

    # ─────────────────────────────────────────────────────────────────────
    # Variable Data (nftban:nftban) - Application state and runtime data
    # ─────────────────────────────────────────────────────────────────────
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban"]="750|nftban|nftban|Application state data"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/reports"]="750|nftban|nftban|Generated reports (application state)"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/reports/baseline"]="750|nftban|nftban|Baseline reports (service use)"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/reports/watchdog"]="750|nftban|nftban|Watchdog system reports"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/reports/auditors"]="770|root|nftban-auditors|Auditor reports (nftban-auditors group)"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/metrics"]="750|nftban|nftban|Statistics metrics database"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/snapshots"]="750|nftban|nftban|Hourly stats snapshots"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/exports"]="750|nftban|nftban|User data exports (JSON, CSV)"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/geoip"]="750|nftban|nftban|GeoIP database (group readable)"

    # ─────────────────────────────────────────────────────────────────────
    # Logs (nftban:nftban, 750) - Daemon writes, group reads
    # ─────────────────────────────────────────────────────────────────────
    NFTBAN_FHS_DIRECTORIES["/var/log/nftban"]="750|nftban|nftban|Log files (daemon writes, group reads)"
    NFTBAN_FHS_DIRECTORIES["/var/log/nftban/reports"]="750|nftban|nftban|Report files (log-style, daemon writes)"

    # ─────────────────────────────────────────────────────────────────────
    # Cache and Runtime (nftban:nftban, 755) - Temporary files
    # ─────────────────────────────────────────────────────────────────────
    NFTBAN_FHS_DIRECTORIES["/var/cache/nftban"]="755|nftban|nftban|Cache files"
    NFTBAN_FHS_DIRECTORIES["/var/cache/nftban/health"]="750|nftban|nftban|Health check status cache (for banner indicator)"
    NFTBAN_FHS_DIRECTORIES["/run/nftban"]="755|nftban|nftban|Runtime data (PID files, sockets)"

    # ─────────────────────────────────────────────────────────────────────
    # Shared Data (root:root, 755) - Read-only application data
    # ─────────────────────────────────────────────────────────────────────
    NFTBAN_FHS_DIRECTORIES["/usr/share/nftban"]="755|root|root|Shared application data"
    NFTBAN_FHS_DIRECTORIES["/usr/share/nftban/templates"]="755|root|root|Templates"
    NFTBAN_FHS_DIRECTORIES["/usr/share/nftban/templates/mail"]="755|root|root|Mail templates"
    NFTBAN_FHS_DIRECTORIES["/usr/share/nftban/templates/reports"]="755|root|root|Report templates"
}

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

nftban_fhs_get_spec() {
    # Get FHS specification for a path
    # Args: $1 = path
    # Output: perms|owner|group|purpose (or empty if not found)

    local path="$1"

    # Load spec if not already loaded
    if [[ ${#NFTBAN_FHS_DIRECTORIES[@]} -eq 0 ]]; then
        nftban_fhs_load_spec
    fi

    echo "${NFTBAN_FHS_DIRECTORIES[$path]:-}"
}

nftban_fhs_get_all_paths() {
    # Get all defined FHS paths
    # Output: one path per line

    # Load spec if not already loaded
    if [[ ${#NFTBAN_FHS_DIRECTORIES[@]} -eq 0 ]]; then
        nftban_fhs_load_spec
    fi

    printf '%s\n' "${!NFTBAN_FHS_DIRECTORIES[@]}" | sort
}

nftban_fhs_parse_spec() {
    # Parse FHS spec into components
    # Args: $1 = spec string (perms|owner|group|purpose)
    # Output: Sets variables FHS_PERMS, FHS_OWNER, FHS_GROUP, FHS_PURPOSE

    local spec="$1"
    IFS='|' read -r FHS_PERMS FHS_OWNER FHS_GROUP FHS_PURPOSE <<< "$spec"
    export FHS_PERMS FHS_OWNER FHS_GROUP FHS_PURPOSE
}

# =============================================================================
# INITIALIZATION
# =============================================================================

# Auto-load spec on source
nftban_fhs_load_spec

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_fhs_load_spec
export -f nftban_fhs_get_spec
export -f nftban_fhs_get_all_paths
export -f nftban_fhs_parse_spec

# Export the associative array (bash 4.3+)
# NOTE: declare -p removed - was causing debug output in systemd journals (BUG-006)
# The array is already exported via declare -g -A on line 33
