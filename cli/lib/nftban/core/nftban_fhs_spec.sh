#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.229.3 - FHS Specification (GENERATED)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="nftban_fhs_spec"
# meta:type="core"
# meta:header="FHS Specification"
# meta:version="1.229.3"
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
    NFTBAN_FHS_DIRECTORIES["/usr/lib/nftban/scripts"]="0755|root|root|Helper scripts (generate-help, generate-wiki, soak-check)"

    # Configuration Directories (root:nftban)
    NFTBAN_FHS_DIRECTORIES["/etc/nftban"]="0750|root|nftban|Configuration files (daemon readable via group)"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/conf.d"]="0750|root|nftban|Module configurations"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/conf.d/ddos"]="0750|root|nftban|DDoS protection configuration"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/conf.d/portscan"]="0750|root|nftban|Port scan detection configuration"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/conf.d/login"]="0750|root|nftban|Login monitoring configuration"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/conf.d/panels"]="0750|root|nftban|Control panel configurations"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/conf.d/panels/cpanel"]="0750|root|nftban|cPanel panel adapter config"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/conf.d/panels/cwp"]="0750|root|nftban|CWP (CentOS Web Panel) panel adapter config"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/conf.d/panels/cyberpanel"]="0750|root|nftban|CyberPanel panel adapter config"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/conf.d/panels/directadmin"]="0750|root|nftban|DirectAdmin panel adapter config"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/conf.d/panels/generic"]="0750|root|nftban|Generic panel adapter config"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/conf.d/panels/interworx"]="0750|root|nftban|InterWorx panel adapter config"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/conf.d/panels/plesk"]="0750|root|nftban|Plesk panel adapter config"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/conf.d/panels/vesta"]="0750|root|nftban|Vesta panel adapter config"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/conf.d/botscan"]="0750|root|nftban|Bot scanner configuration"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/conf.d/botguard"]="0750|root|nftban|HTTP Bot Guard configuration"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/conf.d/botguard/profiles"]="0750|root|nftban|BotGuard per-profile YAML configs"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/conf.d/suricata"]="0750|root|nftban|Suricata interface configuration (conf.d-side)"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/conf.d/tunnel"]="0750|root|nftban|DNS tunnel suspicion configuration"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/templates"]="0750|root|nftban|Operator template overrides (logrotate, etc.)"
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
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/ssl"]="0750|root|nftban|TLS certificates for API"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/suricata"]="0750|root|nftban|Suricata integration configuration"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/suricata/profiles"]="0750|root|nftban|Suricata detection profiles"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/suricata/config"]="0750|root|nftban|Suricata configuration files"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/suricata/rules"]="0750|root|nftban|Suricata custom rules"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/suricata/cache"]="0750|root|nftban|Suricata rule cache"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/suricata/state"]="0750|root|nftban|Suricata state tracking"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/suricata/state/last-good"]="0750|root|nftban|Suricata last-good configuration backup"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/connectors"]="0750|root|nftban|Connector configurations (Zabbix, Elasticsearch, Kafka)"
    NFTBAN_FHS_DIRECTORIES["/etc/nftban/distros"]="0750|root|nftban|Distro-specific configuration files"

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
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/portscan/log-cursors"]="0750|nftban|nftban|PortScan read cursors (v1.229.x): per-source position state so a cycle consumes only records it has not already processed. File sources store inode:offset via the canonical incremental reader; the journald source stores its last COMMITTED journal cursor, written only after a batch has been processed."
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/recorder"]="0750|nftban|nftban|Flight recorder events and snapshots"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/staging"]="0750|nftban|nftban|Feed staging area (temporary download/validation)"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/state"]="0750|nftban|nftban|Critical runtime state files"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/suricata"]="0750|nftban|nftban|Suricata integration state"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/suricata/cache"]="0750|nftban|nftban|Suricata SID-statistics cache (sid-stats.json snapshot)"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/alerts"]="0750|nftban|nftban|Service-failure alert bookkeeping (throttle timestamps + diagnostic reports)"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/update-backups"]="0750|root|nftban|Update rollback backups (root-owned for integrity)"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/watchdog"]="0750|nftban|nftban|Watchdog reports and state"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/reports/archive"]="0750|nftban|nftban|Archived reports"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/pro"]="0750|root|nftban|Pro subscription data"
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/botscan"]="0750|nftban|nftban|BotScan scanner persistent state (v1.185.1): scan-rotate rotation cursor written by the unprivileged nftban-botscan.service processor (User=nftban). Must be tmpfiles/package-created — the processor runs as nftban and cannot reliably create a subdir under /var/lib/nftban (root:nftban 0750), so the in-script mkdir fails silently and the rotation cursor never persists."
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/botscan/spool"]="0750|nftban|nftban|BotScan disk-backed read-authority spool (v1.209.3): moved off /run tmpfs so spool pages are reclaimable page-cache rather than unevictable tmpfs pages charged to the collector's 256M cgroup (fixes collector OOM on heavy hosts). nftban:nftban access-log lines written by nftban-botscan-collector.service and read+reaped by the unprivileged nftban-botscan.service scanner; bounded by a total-dir cap + backpressure."
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/botscan/proc-offsets"]="0750|nftban|nftban|BotScan scanner forward-cursor offsets (v1.209.3 made explicit): per-spool-file inode:offset state the scanner advances while draining the disk-backed spool. Reaping a fully-consumed spool file removes its cursor here too, keeping cursor and spool in sync."
    NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/botscan-collector"]="0750|nftban|nftban|BotScan read-collector per-source incremental offset state (v1.178-A). Separate from the scanner's spool offsets so privileged reads only emit new bytes per cycle."

    # Log Directories
    NFTBAN_FHS_DIRECTORIES["/var/log/nftban"]="0750|nftban|nftban|Log files"
    NFTBAN_FHS_DIRECTORIES["/var/log/nftban/watchdog"]="0750|nftban|nftban|Watchdog logs"
    NFTBAN_FHS_DIRECTORIES["/var/log/nftban/reports"]="0750|nftban|nftban|Report logs"
    NFTBAN_FHS_DIRECTORIES["/var/log/nftban/reports/daily"]="0750|nftban|nftban|Daily operational reports (v1.228.5: moved from /var/lib — logrotate-managed)"
    NFTBAN_FHS_DIRECTORIES["/var/log/nftban/reports/weekly"]="0750|nftban|nftban|Weekly operational reports (v1.228.5: declared so ownership does not depend on which code path creates the directory first)"
    NFTBAN_FHS_DIRECTORIES["/var/log/nftban/reports/monthly"]="0750|nftban|nftban|Monthly operational reports (v1.228.5: declared alongside daily/weekly for a complete report topology)"
    NFTBAN_FHS_DIRECTORIES["/var/log/nftban/reports/archive"]="0750|nftban|nftban|logrotate olddir for rotated reports (v1.228.5: moved from /var/lib)"
    NFTBAN_FHS_DIRECTORIES["/var/log/nftban/rbl"]="0750|nftban|nftban|RBL check cache"
    NFTBAN_FHS_DIRECTORIES["/var/log/nftban/botguard"]="0750|nftban|nftban|HTTP Bot Guard logs"
    NFTBAN_FHS_DIRECTORIES["/var/log/nftban/metrics"]="0750|nftban|nftban|Metrics export logs"
    NFTBAN_FHS_DIRECTORIES["/var/log/nftban/soak"]="0750|nftban|nftban|Soak validation per-run JSON + cron.log (v1.98.1)"
    NFTBAN_FHS_DIRECTORIES["/var/log/nftban/update-runs"]="0750|nftban|nftban|Per-run install/update lifecycle forensic records - JSONL + snapshot, bounded retention (v1.199)"
    NFTBAN_FHS_DIRECTORIES["/var/log/nftban/suricata"]="0770|suricata|nftban|Suricata EVE logs (suricata writes, nftban reads)"

    # Runtime Directories
    NFTBAN_FHS_DIRECTORIES["/var/cache/nftban"]="0755|nftban|nftban|Cache files"
    NFTBAN_FHS_DIRECTORIES["/var/cache/nftban/health"]="0750|nftban|nftban|Health check status cache"
    NFTBAN_FHS_DIRECTORIES["/run/nftban"]="0755|nftban|nftban|Runtime data (PID files, sockets)"
    NFTBAN_FHS_DIRECTORIES["/run/nftban/botscan"]="0750|nftban|nftban|BotScan read-authority spool (v1.178-A): nftban:nftban access-log lines written by nftban-botscan-collector.service (CAP_DAC_READ_SEARCH) and read by the unprivileged nftban-botscan.service scanner. tmpfs/ephemeral."
    NFTBAN_FHS_DIRECTORIES["/run/nftban/firewall-validate"]="2750|root|nftban|V131.3 D13 — setgid (2750) group-readable handoff dir for nftban-firewall-validate.service output (last.json); setgid makes wrapper-written files inherit group nftban without CAP_CHOWN"

    # Shared Directories
    NFTBAN_FHS_DIRECTORIES["/usr/share/nftban"]="0755|root|root|Shared application data"
    NFTBAN_FHS_DIRECTORIES["/usr/share/nftban/templates"]="0755|root|root|Templates"
    NFTBAN_FHS_DIRECTORIES["/usr/share/nftban/templates/mail"]="0755|root|root|Mail templates"
    NFTBAN_FHS_DIRECTORIES["/usr/share/nftban/templates/reports"]="0755|root|root|Report templates"
    NFTBAN_FHS_DIRECTORIES["/usr/share/nftban/templates/email"]="0755|root|root|Email templates (HTML)"
    NFTBAN_FHS_DIRECTORIES["/usr/share/nftban/templates/partials"]="0755|root|root|Email/report partial templates (HTML)"
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
