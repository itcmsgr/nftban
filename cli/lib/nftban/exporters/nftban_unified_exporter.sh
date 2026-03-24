#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_unified_exporter"
# meta:type="exporter"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Unified exporter - collects once, exports to all configured targets"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
#
# SENIOR DESIGN RATIONALE:
# ========================
# Problem: 3 separate timers (metrics, zabbix, connector) = 3x metric collection
# Solution: Collect ONCE, export to ALL targets in single run
#
# Benefits:
# - 66% reduction in metric collection overhead
# - Single timer instead of 3 = less systemd overhead
# - Consistent metric timestamps across all targets
# - Easier debugging (one log, one run)
# - Atomic: either all exports succeed or we know which failed
#
# MODULE STRUCTURE:
# =================
# nftban_unified_exporter.sh          - This loader (config, main)
# nftban_unified_exporter_helpers.sh  - Cleanup, groups, jitter, locking, logging, detection
# nftban_unified_exporter_collect.sh  - collect_all_metrics()
# nftban_unified_exporter_export.sh   - export_prometheus(), export_zabbix(), export_connectors()
# =============================================================================

set -Eeuo pipefail

readonly SCRIPT_VERSION="1.0.0"

# Bootstrap paths (nftban.conf will make them readonly)
: "${NFTBAN_CONFIG_DIR:=/etc/nftban}"
: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"
: "${NFTBAN_RUN_DIR:=/run/nftban}"
: "${NFTBAN_LOG_DIR:=/var/log/nftban}"
: "${NFTBAN_CACHE_DIR:=/var/cache/nftban}"

# Load config (sets readonly paths)
source "${NFTBAN_CONFIG_DIR}/nftban.conf" 2>/dev/null || true

# Load NFT schema (SINGLE SOURCE OF TRUTH for table/set names and counting functions)
# shellcheck source=/usr/lib/nftban/lib/nft_schema.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" || return 1
fi

# Load metrics configuration (unified collector settings)
source "${NFTBAN_CONFIG_DIR}/conf.d/metrics.conf" 2>/dev/null || true
source "${NFTBAN_CONFIG_DIR}/conf.d/metrics.conf.local" 2>/dev/null || true

# Load Zabbix configuration (for export_zabbix)
source "${NFTBAN_CONFIG_DIR}/conf.d/zabbix.conf" 2>/dev/null || true
source "${NFTBAN_CONFIG_DIR}/conf.d/zabbix.conf.local" 2>/dev/null || true

# Load Connectors configuration (for export_connectors)
source "${NFTBAN_CONFIG_DIR}/conf.d/connectors.conf" 2>/dev/null || true
source "${NFTBAN_CONFIG_DIR}/conf.d/connectors.conf.local" 2>/dev/null || true

# Load Portal configuration (for export_portal to pro.nftban.com)
source "${NFTBAN_CONFIG_DIR}/conf.d/portal.conf" 2>/dev/null || true
source "${NFTBAN_CONFIG_DIR}/conf.d/portal.conf.local" 2>/dev/null || true

# =============================================================================
# CONFIGURATION DEFAULTS (from metrics.conf, with fallbacks)
# =============================================================================
: "${NFTBAN_COLLECT_INTERVAL:=60}"
: "${NFTBAN_COLLECT_EXTENDED_MULT:=5}"
: "${NFTBAN_COLLECT_INVENTORY_MULT:=60}"
: "${NFTBAN_COLLECT_JITTER_ENABLED:=true}"
: "${NFTBAN_COLLECT_JITTER_MAX:=30}"
: "${NFTBAN_COLLECT_LOCK_TIMEOUT:=10}"
: "${NFTBAN_COLLECT_USE_STALE_CACHE:=true}"
: "${NFTBAN_COLLECT_STALE_MAX_AGE:=300}"
: "${NFTBAN_COLLECT_DEBUG:=false}"

# Component auto-detection defaults
: "${NFTBAN_COLLECT_SURICATA:=auto}"
: "${NFTBAN_COLLECT_FEEDS:=auto}"
: "${NFTBAN_COLLECT_GEOIP:=auto}"
: "${NFTBAN_COLLECT_WATCHDOG:=auto}"
: "${NFTBAN_COLLECT_PORTSCAN:=auto}"
: "${NFTBAN_COLLECT_EVENTBUS:=auto}"
: "${NFTBAN_COLLECT_KERNEL:=auto}"
: "${NFTBAN_COLLECT_NETWORK:=enabled}"

# Export target defaults
# Note: Prometheus export is an OPTIONAL compatibility adapter.
# NFTBan does NOT require Prometheus - it has its own metrics system (stats.json + bans.log).
: "${NFTBAN_EXPORT_JSON:=true}"
: "${NFTBAN_EXPORT_CONNECTORS:=false}"

# Smart auto-detection for Prometheus export:
# Auto-enable only if node_exporter textfile dir exists AND not explicitly set
if [[ -z "${NFTBAN_EXPORT_PROMETHEUS:-}" ]]; then
    if [[ -d "/var/lib/node_exporter/textfile_collector" ]]; then
        NFTBAN_EXPORT_PROMETHEUS="true"
        # Note: log_info not available yet, logged later in main()
    else
        NFTBAN_EXPORT_PROMETHEUS="false"
    fi
fi

# Metrics cache file (collected once, used by all exporters)
# NOTE: Use /var/cache/nftban for state files written by nftban user
#       NOT /run/nftban which may have broken permissions (root:root)
#       This avoids chicken-and-egg where exporter can't fix perms it can't write to
: "${NFTBAN_CACHE_DIR:=/var/cache/nftban}"
# Exported for submodules (helpers, collect, export)
export METRICS_CACHE="${NFTBAN_CACHE_DIR}/metrics.cache"
export METRICS_LOCK="${NFTBAN_CACHE_DIR}/exporter.lock"
export BANDWIDTH_STATE="${NFTBAN_CACHE_DIR}/bandwidth_state.dat"
export BANDWIDTH_PEAKS="${NFTBAN_CACHE_DIR}/bandwidth_peaks.dat"
export PEAK_WINDOW=300  # 5 minutes for peak tracking

# Run count tracking for collection groups
export RUN_COUNT_FILE="${NFTBAN_CACHE_DIR}/collection.run_count"

# =============================================================================
# MODULE LOADER
# =============================================================================
# Get the directory where this script is located
_exporter_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_exporter_modules=(
    "nftban_unified_exporter_helpers.sh"
    "nftban_unified_exporter_collect.sh"
    "nftban_unified_exporter_export.sh"
)

for _module in "${_exporter_modules[@]}"; do
    _module_path="${_exporter_dir}/${_module}"
    if [[ -f "$_module_path" ]]; then
        # shellcheck source=/dev/null
        source "$_module_path" || {
            echo "ERROR: Failed to load exporter module: $_module" >&2
            exit 1
        }
    else
        echo "ERROR: Exporter module not found: $_module_path" >&2
        exit 1
    fi
done

# Cleanup temporary variables
unset _exporter_modules _module _module_path _exporter_dir

# Setup cleanup trap (function from helpers module)
trap cleanup_temp_files EXIT INT TERM HUP

# =============================================================================
# MAIN
# =============================================================================
main() {
    # Early exit if NO export target is enabled
    # Each target has its own enable flag — don't gate everything behind METRICS_ENABLED
    if [[ "${NFTBAN_METRICS_ENABLED:-false}" != "true" ]] \
        && [[ "${NFTBAN_ZABBIX_ENABLED:-false}" != "true" ]] \
        && [[ "${NFTBAN_EXPORT_PROMETHEUS:-false}" != "true" ]] \
        && [[ "${NFTBAN_EXPORT_CONNECTORS:-false}" != "true" ]] \
        && [[ "${NFTBAN_PORTAL_ENABLED:-false}" != "true" ]]; then
        log_debug "No export targets enabled — skipping collection"
        exit 0
    fi

    local start_time
    start_time=$(date +%s%N)

    # Acquire lock to prevent concurrent runs
    acquire_lock

    # Apply hostname-based jitter (only on first boot, not every run)
    if [[ "${NFTBAN_COLLECT_JITTER_ENABLED:-true}" == "true" ]] && [[ "${NFTBAN_APPLY_JITTER:-false}" == "true" ]]; then
        local jitter
        jitter=$(calculate_host_jitter "${NFTBAN_COLLECT_JITTER_MAX:-30}")
        log_debug "Applying hostname-based jitter: ${jitter}s"
        sleep "$jitter"
    fi

    # Increment run count and determine collection groups
    local run_count collection_groups
    run_count=$(increment_run_count)
    collection_groups=$(determine_collection_groups "$run_count")

    log_info "NFTBan Unified Exporter v${SCRIPT_VERSION} starting (run #${run_count}, groups: ${collection_groups})"

    # Log auto-detection status on first run
    if [[ "$run_count" -eq 1 ]]; then
        if [[ "${NFTBAN_EXPORT_PROMETHEUS}" == "true" ]] && [[ -d "/var/lib/node_exporter/textfile_collector" ]]; then
            log_info "Prometheus export auto-enabled (node_exporter detected)"
        fi
    fi

    # Step 1: Collect metrics based on collection groups (smart collection)
    collect_all_metrics "$collection_groups"

    # Step 2: Export to enabled targets only
    local export_count=0

    # Prometheus export (only if enabled)
    if [[ "${NFTBAN_EXPORT_PROMETHEUS:-false}" == "true" ]]; then
        export_prometheus && ((export_count++)) || true
    fi

    # Zabbix export (only if enabled)
    if [[ "${NFTBAN_ZABBIX_ENABLED:-false}" == "true" ]]; then
        export_zabbix && ((export_count++)) || true
    fi

    # Connector exports (only if enabled)
    if [[ "${NFTBAN_EXPORT_CONNECTORS:-false}" == "true" ]]; then
        export_connectors && ((export_count++)) || true
    fi

    # Portal export (pro.nftban.com - only if enabled)
    if [[ "${NFTBAN_PORTAL_ENABLED:-false}" == "true" ]]; then
        export_portal && ((export_count++)) || true
    fi

    # Calculate duration
    local end_time duration_ms
    end_time=$(date +%s%N)
    duration_ms=$(( (end_time - start_time) / 1000000 ))

    # Log timing if enabled
    if [[ "${NFTBAN_COLLECT_LOG_TIMING:-false}" == "true" ]]; then
        log_info "Run #${run_count}: ${duration_ms}ms (groups: ${collection_groups}, exports: ${export_count})"
    else
        log_info "Completed: $export_count export targets in ${duration_ms}ms"
    fi
}

# Run
main "$@"
