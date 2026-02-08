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
# meta:updated_date="2026-02-08"
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
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/geoban.d"]="0750|root|nftban|GeoIP country ban lists"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/nftables.d"]="0750|root|nftban|Custom nftables include files"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/suricata"]="0750|root|nftban|Suricata integration configuration"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/suricata/cache"]="0750|root|nftban|Suricata detection cache"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/suricata/config"]="0750|root|nftban|Suricata config snippets"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/suricata/profiles"]="0750|root|nftban|Suricata detection profiles"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/suricata/rules"]="0750|root|nftban|Suricata custom rules"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/suricata/state"]="0750|root|nftban|Suricata rule state management"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/suricata/state/last-good"]="0750|root|nftban|Last known good rules backup"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/ssl"]="0750|root|nftban|UI TLS certificates"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/certs"]="0750|root|nftban|Zabbix integration TLS certificates"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/tls"]="0750|root|nftban|API TLS certificates (self-signed)"

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
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/state"]="0750|nftban|nftban|Protection and filter state JSON files"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/zabbix"]="0750|nftban|nftban|Zabbix event buffer for failed exports"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/profiles"]="0750|nftban|nftban|Watchdog protection profiles"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/recorder"]="0750|nftban|nftban|Watchdog flight recorder audit trail"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/config"]="0755|root|root|Runtime configuration state"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/login"]="0750|nftban|nftban|Login monitor state files"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/portscan"]="0750|nftban|nftban|Portscan tracker database"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/geoban/tracking"]="0750|nftban|nftban|GeoIP ban country tracking"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/reports/archive"]="0750|nftban|nftban|Archived reports"

    # Log Directories
    NFTBAN_FHS_DIRECTORIES["/var/log/nftban"]="0750|nftban|nftban|Log files"
    NFTBAN_FHS_DIRECTORIES["/var/log/nftban/watchdog"]="0750|nftban|nftban|Watchdog logs"
    NFTBAN_FHS_DIRECTORIES["/var/log/nftban/reports"]="0750|nftban|nftban|Report logs"
    NFTBAN_FHS_DIRECTORIES["/var/log/nftban/rbl"]="0750|nftban|nftban|RBL check cache"
    NFTBAN_FHS_DIRECTORIES["/var/log/nftban/suricata"]="0750|nftban|nftban|Suricata EVE JSON alerts"
    NFTBAN_FHS_DIRECTORIES["/var/log/nftban/metrics"]="0750|nftban|nftban|Metrics export NDJSON logs"

    # Runtime Directories
    NFTBAN_FHS_DIRECTORIES["/var/cache/nftban"]="0755|nftban|nftban|Cache files"
    NFTBAN_FHS_DIRECTORIES["/var/cache/nftban/health"]="0750|nftban|nftban|Health check status cache"
    NFTBAN_FHS_DIRECTORIES["/var/cache/nftban/trust"]="0755|nftban|nftban|Trust list and Cloudflare IP cache"
    NFTBAN_FHS_DIRECTORIES["/var/cache/nftban/rbl"]="0755|nftban|nftban|RBL lookup result cache"
    NFTBAN_FHS_DIRECTORIES["/var/cache/nftban/geoban"]="0755|nftban|nftban|GeoIP country list cache"
    NFTBAN_FHS_DIRECTORIES["/var/cache/nftban/metrics"]="0755|nftban|nftban|JSON metrics cache for dashboard"
    NFTBAN_FHS_DIRECTORIES["/var/cache/nftban/feeds"]="0755|nftban|nftban|Feed download cache"
    NFTBAN_FHS_DIRECTORIES["/var/cache/nftban/login"]="0755|nftban|nftban|Login module cache"
    NFTBAN_FHS_DIRECTORIES["/var/cache/nftban/portscan"]="0755|nftban|nftban|Portscan module cache"
    NFTBAN_FHS_DIRECTORIES["/run/nftban"]="0755|nftban|nftban|Runtime data (PID files, sockets)"
    NFTBAN_FHS_DIRECTORIES["/run/nftban-ui"]="0755|nftban|nftban|Web UI daemon runtime data"

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
# FILE PERMISSION RULES (Single Source of Truth)
# =============================================================================
# Format: path|pattern|mode|owner|group|recursive|exclude|capabilities

declare -g -a NFTBAN_FHS_FILE_RULES=()

nftban_fhs_load_file_rules() {
    # Load file permission rules from FHS spec
    NFTBAN_FHS_FILE_RULES=(
        # /etc/nftban - config files
        "/etc/nftban|*.conf|0640|root|nftban|true||"
        "/etc/nftban|*.local|0640|root|nftban|true||"
        # /usr/lib/nftban - shell scripts
        "/usr/lib/nftban|*.sh|0755|root|root|true||"
        # /usr/lib/nftban/bin - Go binaries
        "/usr/lib/nftban/bin|*|0755|root|root|false||cap_net_admin+ep:nftban-core,nftband"
        # /usr/lib/nftban/sbin - helper binaries
        "/usr/lib/nftban/sbin|*|0755|root|root|false||"
        # /usr/sbin/nftban* - CLI binaries
        "/usr/sbin|nftban*|0750|root|nftban|false||"
        # /var/lib/nftban - state files
        "/var/lib/nftban|*|0640|nftban|nftban|true|/var/lib/nftban/reports/auditors|"
        # /var/lib/nftban/reports/auditors
        "/var/lib/nftban/reports/auditors|*|0660|root|nftban-auditor|true||"
        # /var/log/nftban - log files
        "/var/log/nftban|*|0640|nftban|nftban|true|/var/log/nftban/suricata|"
        # /var/log/nftban/suricata
        "/var/log/nftban/suricata|*|0640|suricata|nftban|true||"
    )
}

nftban_fhs_enforce_file_rules() {
    # Enforce all file permission rules
    # Returns: 0 on success, count of errors on failure

    [[ ${#NFTBAN_FHS_FILE_RULES[@]} -eq 0 ]] && nftban_fhs_load_file_rules

    local errors=0

    for rule in "${NFTBAN_FHS_FILE_RULES[@]}"; do
        IFS='|' read -r path pattern mode owner group recursive exclude caps <<< "$rule"

        [[ ! -d "$path" ]] && continue

        local find_opts=("-type" "f")
        [[ "$recursive" != "true" ]] && find_opts+=("-maxdepth" "1")
        [[ -n "$exclude" ]] && find_opts+=("-not" "-path" "${exclude}/*")

        # Apply ownership and mode
        find "$path" "${find_opts[@]}" -name "$pattern" -exec chown "$owner:$group" {} \; 2>/dev/null || ((errors++))
        find "$path" "${find_opts[@]}" -name "$pattern" -exec chmod "$mode" {} \; 2>/dev/null || ((errors++))

        # Apply capabilities if specified
        if [[ -n "$caps" ]]; then
            local cap_str="${caps%%:*}"
            local binaries="${caps#*:}"
            IFS=',' read -ra bins <<< "$binaries"
            for bin in "${bins[@]}"; do
                [[ -f "$path/$bin" ]] && setcap "$cap_str" "$path/$bin" 2>/dev/null || true
            done
        fi
    done

    return $errors
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
export -f nftban_fhs_load_file_rules
export -f nftban_fhs_enforce_file_rules
