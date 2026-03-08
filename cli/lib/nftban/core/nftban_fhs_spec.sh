#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - FHS Specification (GENERATED)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="nftban_fhs_spec"
# meta:type="core"
# meta:header="FHS Specification"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Single source of truth for FHS directory specifications (GENERATED)"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="user"
#
# meta:created_date="2026-01-10"
# meta:updated_date="2026-03-08"
#
# WARNING: This file is GENERATED from build/fhs-spec.yaml - DO NOT EDIT
# Run: build/generate-fhs-outputs.sh
# =============================================================================

set -Eeuo pipefail
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

    # System Directories (root:root)
    NFTBAN_FHS_DIRECTORIES["/usr/lib/nftban"]="0755|root|root|Application libraries and modules"
    NFTBAN_FHS_DIRECTORIES["/usr/lib/nftban/core"]="0755|root|root|Core modules"
    NFTBAN_FHS_DIRECTORIES["/usr/lib/nftban/cli"]="0755|root|root|CLI command modules"
    NFTBAN_FHS_DIRECTORIES["/usr/lib/nftban/lib"]="0755|root|root|Library modules"
    NFTBAN_FHS_DIRECTORIES["/usr/lib/nftban/bin"]="0755|root|root|Application binaries (Go, etc.)"
    NFTBAN_FHS_DIRECTORIES["/usr/lib/nftban/exporters"]="0755|root|root|Metrics exporters"
    NFTBAN_FHS_DIRECTORIES["/usr/lib/nftban/setup"]="0755|root|root|Setup and installation scripts"
    NFTBAN_FHS_DIRECTORIES["/usr/lib/nftban/tests"]="0755|root|root|Test scripts (smoke tests, validation)"
    NFTBAN_FHS_DIRECTORIES["/usr/lib/nftban/helpers"]="0755|root|root|Helper scripts (trace, autoheal)"
    NFTBAN_FHS_DIRECTORIES["/usr/lib/nftban/cron"]="0755|root|root|Cron/timer job scripts"
    NFTBAN_FHS_DIRECTORIES["/usr/lib/nftban/modules"]="0755|root|root|Protection modules (portscan, ddos, login)"
    NFTBAN_FHS_DIRECTORIES["/usr/lib/nftban/sbin"]="0755|root|root|System helper binaries"
    NFTBAN_FHS_DIRECTORIES["/usr/lib/nftban/health"]="0755|root|root|Health check modules"
    NFTBAN_FHS_DIRECTORIES["/usr/lib/nftban/data"]="0755|root|root|Static data files (registries, schemas)"
    NFTBAN_FHS_DIRECTORIES["/usr/lib/nftban/tools"]="0755|root|root|Utility tools and scripts"

    # Configuration Directories (root:nftban)
    NFTBAN_FHS_DIRECTORIES["/etc/nftban"]="0750|root|nftban|Configuration files (daemon readable via group)"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/conf.d"]="0750|root|nftban|Module configurations"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/conf.d/ddos"]="0750|root|nftban|DDoS protection configuration"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/conf.d/portscan"]="0750|root|nftban|Port scan detection configuration"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/conf.d/login"]="0750|root|nftban|Login monitoring configuration"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/conf.d/panels"]="0750|root|nftban|Control panel configurations"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/conf.d/botscan"]="0750|root|nftban|Bot scanner configuration"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/patterns.d"]="0750|root|nftban|Detection pattern files"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/patterns.d/botscan"]="0750|root|nftban|Bot scanner patterns"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/whitelist.d"]="0750|root|nftban|Whitelist entries"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/blacklist.d"]="0750|root|nftban|Blacklist entries"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/ports.d"]="0750|root|nftban|Port whitelist entries"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/rules.d"]="0750|root|nftban|Custom nftables rules"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/connectors"]="0750|root|nftban|Connector configurations (Zabbix, Elasticsearch, Kafka)"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/distros"]="0755|root|root|Distro-specific configuration files"

    # Data Directories
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban"]="0750|root|nftban|Application state data (root-owned security boundary)"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/banned"]="0750|nftban|nftban|Banned IP state files"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/whitelist"]="0750|nftban|nftban|Whitelist state files"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/feeds"]="0750|nftban|nftban|Threat feed data"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/reports"]="0750|nftban|nftban|Generated reports"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/reports/baseline"]="0750|nftban|nftban|Baseline reports"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/reports/watchdog"]="0750|nftban|nftban|Watchdog system reports"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/reports/auditors"]="0770|root|nftban-auditor|Auditor reports (nftban-auditor group access)"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/metrics"]="0750|nftban|nftban|Metrics database"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/snapshots"]="0750|nftban|nftban|Hourly stats snapshots"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/exports"]="0750|nftban|nftban|User data exports (JSON, CSV)"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/geoip"]="0750|nftban|nftban|GeoIP database"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/stats"]="0750|nftban|nftban|Runtime statistics"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/stats/history"]="0750|nftban|nftban|Stats history"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/stats/profiles"]="0750|nftban|nftban|Stats profiles"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/queue"]="0750|nftban|nftban|Task queue root"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/queue/pending"]="0750|nftban|nftban|Pending tasks"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/queue/work"]="0750|nftban|nftban|In-progress tasks"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/queue/dlq"]="0750|nftban|nftban|Dead letter queue"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/mailspool"]="0750|nftban|nftban|Failed mail retry queue"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/pro"]="0750|root|nftban|Pro subscription data"

    # Log Directories
    NFTBAN_FHS_DIRECTORIES["/var/log/nftban"]="0750|nftban|nftban|Log files"
    NFTBAN_FHS_DIRECTORIES["/var/log/nftban/watchdog"]="0750|nftban|nftban|Watchdog logs"
    NFTBAN_FHS_DIRECTORIES["/var/log/nftban/reports"]="0750|nftban|nftban|Report logs"
    NFTBAN_FHS_DIRECTORIES["/var/log/nftban/rbl"]="0750|nftban|nftban|RBL check cache"
    # Suricata directory: Use "*" owner to allow either suricata or root
    # (suricata user only exists if Suricata is installed)
    if id suricata >/dev/null 2>&1; then
        NFTBAN_FHS_DIRECTORIES["/var/log/nftban/suricata"]="0770|suricata|nftban|Suricata EVE logs (suricata writes, nftban reads)"
    else
        NFTBAN_FHS_DIRECTORIES["/var/log/nftban/suricata"]="0770|root|nftban|Suricata EVE logs (no suricata user - owned by root)"
    fi

    # Runtime Directories
    NFTBAN_FHS_DIRECTORIES["/var/cache/nftban"]="0755|nftban|nftban|Cache files"
    NFTBAN_FHS_DIRECTORIES["/var/cache/nftban/health"]="0750|nftban|nftban|Health check status cache"
    NFTBAN_FHS_DIRECTORIES["/run/nftban"]="0755|nftban|nftban|Runtime data (PID files, sockets)"

    # Shared Directories
    NFTBAN_FHS_DIRECTORIES["/usr/share/nftban"]="0755|root|root|Shared application data"
    NFTBAN_FHS_DIRECTORIES["/usr/share/nftban/templates"]="0755|root|root|Templates"
    NFTBAN_FHS_DIRECTORIES["/usr/share/nftban/templates/mail"]="0755|root|root|Mail templates"
    NFTBAN_FHS_DIRECTORIES["/usr/share/nftban/templates/reports"]="0755|root|root|Report templates"
    NFTBAN_FHS_DIRECTORIES["/usr/share/nftban/templates/zabbix"]="0755|root|root|Zabbix import templates (5.x XML, 6.x+ YAML)"
    NFTBAN_FHS_DIRECTORIES["/usr/share/nftban/dashboards"]="0755|root|root|Monitoring dashboards"
    NFTBAN_FHS_DIRECTORIES["/usr/share/nftban/dashboards/grafana"]="0755|root|root|Grafana dashboard JSON files"
    NFTBAN_FHS_DIRECTORIES["/usr/share/nftban/specs"]="0755|root|root|Specification files"
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
