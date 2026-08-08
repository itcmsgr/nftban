#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_service_control" meta:type="lib" meta:version="1.39.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Low-level systemd primitives (nftban_systemd_*) - distinct from config-aware service_control.sh"
# meta:inventory.files=""
# meta:inventory.binaries="systemctl"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"

set -Eeuo pipefail

# =============================================================================
# GUARD: Prevent double-loading
# =============================================================================

[[ -n "${_NFTBAN_SERVICE_CONTROL_LOADED:-}" ]] && return 0
readonly _NFTBAN_SERVICE_CONTROL_LOADED=1

# =============================================================================
# DEPENDENCIES
# =============================================================================

# Source distro config for DISTRO_PATHS (conditional, with fallback defaults)
# shellcheck source=/usr/lib/nftban/lib/nftban_distro_config.sh
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_distro_config.sh" 2>/dev/null || true

# =============================================================================
# SERVICE STATUS FUNCTIONS
# =============================================================================

# Check if a systemd service is active (running)
# Usage: nftban_systemd_is_active "nftables.service"
# Returns: 0 if active, 1 if inactive/failed/not-found
nftban_systemd_is_active() {
    local service="$1"
    systemctl is-active --quiet "$service" 2>/dev/null
}

# Check if a systemd service is enabled (starts at boot)
# Usage: nftban_systemd_is_enabled "nftables.service"
# Returns: 0 if enabled, 1 if disabled/static/not-found
nftban_systemd_is_enabled() {
    local service="$1"
    systemctl is-enabled --quiet "$service" 2>/dev/null
}

# Check if a systemd service unit file exists
# Usage: nftban_systemd_exists "nftables.service"
# Returns: 0 if exists, 1 if not found
nftban_systemd_exists() {
    local service="$1"

    # Ensure .service suffix for consistent matching
    [[ "$service" != *.service ]] && service="${service}.service"

    # Check via systemctl list-unit-files (covers enabled/disabled/static)
    if systemctl list-unit-files "$service" 2>/dev/null | grep -q "^${service}"; then
        return 0
    fi

    # Fallback: check common unit file locations directly
    [[ -f "/etc/systemd/system/${service}" ]] && return 0
    [[ -f "${DISTRO_PATHS[systemd_system]:-/usr/lib/systemd/system}/${service}" ]] && return 0
    [[ -f "/lib/systemd/system/${service}" ]] && return 0

    return 1
}

# Get the status of a systemd service as a string
# Usage: status=$(nftban_systemd_status "nftables.service")
# Returns: "active" | "inactive" | "failed" | "activating" | "deactivating" | "not-found"
nftban_systemd_status() {
    local service="$1"
    local status

    # First check if service exists
    if ! nftban_systemd_exists "$service"; then
        echo "not-found"
        return 0
    fi

    # Get actual status from systemctl
    status=$(systemctl is-active "$service" 2>/dev/null) || status="unknown"

    echo "$status"
}

# =============================================================================
# SERVICE CONTROL FUNCTIONS
# =============================================================================

# Start a systemd service
# Usage: nftban_systemd_start "nftables.service"
# Returns: 0 on success, 1 on failure
nftban_systemd_start() {
    local service="$1"

    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: PolicyKit/polkit authorization failed or insufficient privileges (start service)" >&2
        return 1
    fi

    if ! nftban_systemd_exists "$service"; then
        echo "ERROR: Service '$service' not found" >&2
        return 1
    fi

    systemctl start "$service" 2>/dev/null
}

# Stop a systemd service
# Usage: nftban_systemd_stop "nftables.service"
# Returns: 0 on success, 1 on failure
nftban_systemd_stop() {
    local service="$1"

    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: PolicyKit/polkit authorization failed or insufficient privileges (stop service)" >&2
        return 1
    fi

    if ! nftban_systemd_exists "$service"; then
        echo "ERROR: Service '$service' not found" >&2
        return 1
    fi

    systemctl stop "$service" 2>/dev/null
}

# Restart a systemd service
# Usage: nftban_systemd_restart "nftables.service"
# Returns: 0 on success, 1 on failure
nftban_systemd_restart() {
    local service="$1"

    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: PolicyKit/polkit authorization failed or insufficient privileges (restart service)" >&2
        return 1
    fi

    if ! nftban_systemd_exists "$service"; then
        echo "ERROR: Service '$service' not found" >&2
        return 1
    fi

    systemctl restart "$service" 2>/dev/null
}

# =============================================================================
# TIMER FUNCTIONS
# =============================================================================

# Check if a systemd timer is active
# Usage: nftban_timer_is_active "nftban-sync.timer"
# Returns: 0 if active, 1 if inactive/not-found
nftban_timer_is_active() {
    local timer="$1"

    # Ensure .timer suffix
    [[ "$timer" != *.timer ]] && timer="${timer}.timer"

    systemctl is-active --quiet "$timer" 2>/dev/null
}

# Get the next scheduled run time for a timer
# Usage: next=$(nftban_timer_next_run "nftban-sync.timer")
# Returns: Next run time string (e.g., "Mon 2026-02-07 15:00:00 UTC") or "N/A"
nftban_timer_next_run() {
    local timer="$1"
    local next_run

    # Ensure .timer suffix
    [[ "$timer" != *.timer ]] && timer="${timer}.timer"

    # Check if timer exists and is active
    if ! nftban_timer_is_active "$timer"; then
        echo "N/A"
        return 0
    fi

    # Get next run time from systemctl list-timers
    # Output format: NEXT LEFT LAST PASSED UNIT ACTIVATES
    next_run=$(systemctl list-timers "$timer" --no-legend 2>/dev/null | awk '{print $1, $2, $3, $4}')

    if [[ -z "$next_run" ]]; then
        echo "N/A"
    else
        echo "$next_run"
    fi
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_systemd_is_active
export -f nftban_systemd_is_enabled
export -f nftban_systemd_exists
export -f nftban_systemd_status
export -f nftban_systemd_start
export -f nftban_systemd_stop
export -f nftban_systemd_restart
export -f nftban_timer_is_active
export -f nftban_timer_next_run

# =============================================================================
# LICENSE
# =============================================================================
# Mozilla Public License 2.0 (MPL-2.0)
# Copyright (c) 2024-2026 Antonios Voulvoulis
# Contact: contact@nftban.com | Website: https://nftban.com
# =============================================================================
