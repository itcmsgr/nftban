#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.83.0 - FHS Specification (GENERATED)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="nftban_fhs_spec"
# meta:type="core"
# meta:header="FHS Specification"
# meta:version="1.83.0"
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
# meta:updated_date="2026-01-10"
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
    NFTBAN_FHS_DIRECTORIES["/usr/lib/nftban/templates"]="0755|root|root|Config templates with placeholders (rendered at install/rebuild)"
    NFTBAN_FHS_DIRECTORIES["/usr/lib/nftban/tools"]="0755|root|root|Utility tools and scripts"

    # Configuration Directories (root:nftban)
    NFTBAN_FHS_DIRECTORIES["/etc/nftban"]="0750|root|nftban|Configuration files (daemon readable via group)"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/conf.d"]="0750|root|nftban|Module configurations"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/conf.d/ddos"]="0750|root|nftban|DDoS protection configuration"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/conf.d/portscan"]="0750|root|nftban|Port scan detection configuration"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/conf.d/login"]="0750|root|nftban|Login monitoring configuration"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/conf.d/panels"]="0750|root|nftban|Control panel configurations"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/conf.d/botscan"]="0750|root|nftban|Bot scanner configuration"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/conf.d/botguard"]="0750|root|nftban|HTTP Bot Guard configuration"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/conf.d/tunnel"]="0750|root|nftban|DNS tunnel suspicion configuration"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/patterns.d"]="0750|root|nftban|Detection pattern files"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/patterns.d/botscan"]="0750|root|nftban|Bot scanner patterns"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/whitelist.d"]="0750|root|nftban|Whitelist entries"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/blacklist.d"]="0750|root|nftban|Blacklist entries"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/ports.d"]="0750|root|nftban|Port whitelist entries"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/rules.d"]="0750|root|nftban|Custom nftables rules"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/access.d"]="0750|root|nftban|Per-IP port access rules (v1.41.0)"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/conf.d/rbl"]="0750|root|nftban|RBL check configuration"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/conf.d/geoban"]="0750|root|nftban|Geographic ban configuration"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/conf.d/geoip"]="0750|root|nftban|GeoIP database configuration"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/nftables.d"]="0750|root|nftban|NFTBan-managed nftables include fragments"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/ssl"]="0750|root|nftban|TLS certificates for GUI/API"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/suricata"]="0750|root|nftban|Suricata integration configuration"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/suricata/profiles"]="0750|root|nftban|Suricata detection profiles"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/suricata/config"]="0750|root|nftban|Suricata configuration files"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/suricata/rules"]="0750|root|nftban|Suricata custom rules"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/suricata/cache"]="0750|root|nftban|Suricata rule cache"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/suricata/state"]="0750|root|nftban|Suricata state tracking"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/suricata/state/last-good"]="0750|root|nftban|Suricata last-good configuration backup"
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
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/botguard"]="0750|nftban|nftban|HTTP Bot Guard state (batch signals, decisions)"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/tunnel"]="0750|nftban|nftban|DNS tunnel suspicion state (scores, history)"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/community"]="0750|nftban|nftban|Community stats data (install ID, submission cache)"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/analytics"]="0750|nftban|nftban|Analytics state data"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/backup"]="0750|root|nftban|Firewall backup snapshots (root-owned for integrity)"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/config"]="0750|nftban|nftban|Runtime configuration state"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/login"]="0750|nftban|nftban|Login monitor state data"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/panels"]="0750|nftban|nftban|Panel integration state"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/portscan"]="0750|nftban|nftban|Port scan detection state"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/recorder"]="0750|nftban|nftban|Flight recorder events and snapshots"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/staging"]="0750|nftban|nftban|Feed staging area (temporary download/validation)"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/state"]="0750|nftban|nftban|Critical runtime state files"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/suricata"]="0750|nftban|nftban|Suricata integration state"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/update-backups"]="0750|root|nftban|Update rollback backups (root-owned for integrity)"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/watchdog"]="0750|nftban|nftban|Watchdog reports and state"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/reports/archive"]="0750|nftban|nftban|Archived reports"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/pro"]="0750|root|nftban|Pro subscription data"

    # Log Directories
    NFTBAN_FHS_DIRECTORIES["/var/log/nftban"]="0750|nftban|nftban|Log files"
    NFTBAN_FHS_DIRECTORIES["/var/log/nftban/watchdog"]="0750|nftban|nftban|Watchdog logs"
    NFTBAN_FHS_DIRECTORIES["/var/log/nftban/reports"]="0750|nftban|nftban|Report logs"
    NFTBAN_FHS_DIRECTORIES["/var/log/nftban/rbl"]="0750|nftban|nftban|RBL check cache"
    NFTBAN_FHS_DIRECTORIES["/var/log/nftban/botguard"]="0750|nftban|nftban|HTTP Bot Guard logs"
    NFTBAN_FHS_DIRECTORIES["/var/log/nftban/metrics"]="0750|nftban|nftban|Metrics export logs"
    NFTBAN_FHS_DIRECTORIES["/var/log/nftban/suricata"]="0770|suricata|nftban|Suricata EVE logs (suricata writes, nftban reads)"

    # Runtime Directories
    NFTBAN_FHS_DIRECTORIES["/var/cache/nftban"]="0755|nftban|nftban|Cache files"
    NFTBAN_FHS_DIRECTORIES["/var/cache/nftban/health"]="0750|nftban|nftban|Health check status cache"
    NFTBAN_FHS_DIRECTORIES["/run/nftban"]="0755|nftban|nftban|Runtime data (PID files, sockets)"
    NFTBAN_FHS_DIRECTORIES["/run/nftban-ui"]="0755|root|nftban|GUI/API runtime socket directory"

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
