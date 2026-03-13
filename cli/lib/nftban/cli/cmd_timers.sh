#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Timers Management CLI Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cmd_timers"
# meta:type="cli"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2025-10-26"
# meta:description="Manage systemd timers for automated tasks"
# meta:input="Subcommand (status, enable, disable)"
# meta:output="Timer status and management results"
# meta:depends="systemd"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units="nftban-*.timer"
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${NFTBAN_CMD_TIMERS_LOADED:-}" ]] && return 0
NFTBAN_CMD_TIMERS_LOADED="true"

# Load required modules
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/service_control.sh" || return 1
# v1.19.20 FIX (B2, B4): Load nftban_service_control.sh for nftban_timer_is_active()
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/nftban_service_control.sh" || return 1

# =============================================================================
# CONFIGURATION
# =============================================================================

# All NFTBan timers (in priority order)
readonly NFTBAN_TIMERS=(
    "nftban-health.timer"
    "nftban-maintenance.timer"
    "nftban-unified-exporter.timer"
    "nftban-core-geoip.timer"
    "nftban-core-feeds.timer"
    "nftban-queue.timer"
    "nftban-suricata-update.timer"
    "nftban-snapshot.timer"
    "nftban-rollback.timer"
    "nftban-update.timer"
    "nftban-watchdog.timer"
    "nftban-rbl-check.timer"
    "nftban-pro-license.timer"
    "nftban-pro-inventory.timer"
)

# Timer descriptions
declare -A TIMER_DESC=(
    ["nftban-health.timer"]="System health checks and auto-heal"
    ["nftban-maintenance.timer"]="SSH/IP monitoring, trend data (every 15m)"
    ["nftban-unified-exporter.timer"]="Unified metrics collection and export"
    ["nftban-core-geoip.timer"]="GeoIP database updates"
    ["nftban-core-feeds.timer"]="Threat feed synchronization"
    ["nftban-queue.timer"]="Ban queue processing (every 5m)"
    ["nftban-suricata-update.timer"]="Suricata IDS rules update"
    ["nftban-snapshot.timer"]="Config/state snapshot creation"
    ["nftban-rollback.timer"]="Rollback availability check"
    ["nftban-update.timer"]="Weekly auto-update (Sunday 4:00 AM)"
    ["nftban-watchdog.timer"]="System watchdog (every 120s)"
    ["nftban-rbl-check.timer"]="RBL check (every 12h)"
    ["nftban-pro-license.timer"]="Pro license validation (every 6h)"
    ["nftban-pro-inventory.timer"]="Pro daily inventory (04:00)"
)

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Check if timer exists
timer_exists() {
    local timer="$1"
    systemctl list-unit-files "$timer" --no-legend 2>/dev/null | grep -q "^$timer"
}

# Note: Timer status functions are provided by nftban_service_control.sh:
#   - nftban_timer_is_active(timer) - check if timer is active
#   - nftban_timer_next_run(timer) - get next scheduled run
#   - nftban_service_is_enabled(timer) - check if timer is enabled

# Get timer last trigger time
timer_last_trigger() {
    local timer="$1"
    systemctl list-timers "$timer" --all --no-legend 2>/dev/null | awk '{print $3, $4}' || echo "N/A"
}

# =============================================================================
# COMMAND: STATUS
# =============================================================================

# JSON output for timer status
cmd_timers_status_json() {
    local timers_json="["
    local first=true

    for timer in "${NFTBAN_TIMERS[@]}"; do
        local exists="false"
        local enabled="false"
        local active="false"
        local next_run=""
        local description="${TIMER_DESC[$timer]:-}"

        if timer_exists "$timer"; then
            exists="true"
            nftban_service_is_enabled "$timer" && enabled="true"
            nftban_timer_is_active "$timer" && active="true"
            next_run=$(nftban_timer_next_run "$timer" 2>/dev/null || echo "")
        fi

        [[ "$first" == "true" ]] && first=false || timers_json+=","
        timers_json+="{\"name\":\"$timer\",\"description\":\"$description\",\"exists\":$exists,\"enabled\":$enabled,\"active\":$active,\"next_run\":\"$next_run\"}"
    done

    timers_json+="]"
    echo "{\"timers\":$timers_json,\"timestamp\":\"$(date -Iseconds)\"}"
}

cmd_timers_status() {
    local json_mode=0

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json|-j) json_mode=1; shift ;;
            *) shift ;;
        esac
    done

    # JSON output mode
    if [[ $json_mode -eq 1 ]]; then
        cmd_timers_status_json
        return $?
    fi

    nftban_banner

    echo "🕐 SYSTEMD TIMERS STATUS"
    echo "════════════════════════════════════════════════════════════════"
    echo ""

    local total=0
    local enabled=0
    local active=0
    local missing=0

    for timer in "${NFTBAN_TIMERS[@]}"; do
        total=$((total + 1))

        if ! timer_exists "$timer"; then
            echo "  ❌ $timer"
            echo "     Description: ${TIMER_DESC[$timer]}"
            echo "     Status:      NOT INSTALLED"
            echo ""
            missing=$((missing + 1))
            continue
        fi

        local status_icon="⚪"
        local status_text="Inactive"

        if nftban_service_is_enabled "$timer"; then
            enabled=$((enabled + 1))
            status_icon="✅"
            status_text="Enabled"

            if nftban_timer_is_active "$timer"; then
                active=$((active + 1))
                status_text="Enabled & Active"
            fi
        else
            status_icon="⚠️"
            status_text="Disabled"
        fi

        echo "  $status_icon $timer"
        echo "     Description: ${TIMER_DESC[$timer]}"
        echo "     Status:      $status_text"

        if nftban_timer_is_active "$timer"; then
            local next_run
            next_run=$(nftban_timer_next_run "$timer")
            local last_trigger
            last_trigger=$(timer_last_trigger "$timer")
            echo "     Next run:    $next_run"
            [[ "$last_trigger" != "N/A" && "$last_trigger" != "n/a" ]] && echo "     Last run:    $last_trigger"
        fi

        echo ""
    done

    echo "────────────────────────────────────────────────────────────────"
    echo "Summary:"
    echo "  Total timers:   $total"
    echo "  Enabled:        $enabled/$total"
    echo "  Active:         $active/$total"
    [[ $missing -gt 0 ]] && echo "  Missing:        $missing/$total"
    echo ""

    if [[ $enabled -lt $total ]]; then
        echo "💡 To enable all timers:"
        echo "   nftban timers enable"
        echo ""
    fi

    return 0
}

# =============================================================================
# COMMAND: ENABLE
# =============================================================================

cmd_timers_enable() {
    local timer_name="${1:-}"

    nftban_banner

    echo "🔧 ENABLE SYSTEMD TIMERS"
    echo "════════════════════════════════════════════════════════════════"
    echo ""

    # Enable specific timer
    if [[ -n "$timer_name" ]]; then
        if ! timer_exists "$timer_name"; then
            echo "❌ Error: Timer '$timer_name' not found"
            echo ""
            echo "Available timers:"
            for t in "${NFTBAN_TIMERS[@]}"; do
                timer_exists "$t" && echo "  - $t"
            done
            return 1
        fi

        if nftban_service_is_enabled "$timer_name"; then
            echo "✅ $timer_name is already enabled"
            return 0
        fi

        echo "Enabling $timer_name..."
        if systemctl enable --now "$timer_name" 2>/dev/null; then
            echo "✅ Successfully enabled $timer_name"
        else
            echo "❌ Failed to enable $timer_name"
            return 1
        fi

        return 0
    fi

    # Enable all timers
    local success=0
    local failed=0
    local skipped=0

    for timer in "${NFTBAN_TIMERS[@]}"; do
        if ! timer_exists "$timer"; then
            echo "⚪ $timer - Not installed (skipping)"
            skipped=$((skipped + 1))
            continue
        fi

        if nftban_service_is_enabled "$timer"; then
            echo "✅ $timer - Already enabled"
            success=$((success + 1))
            continue
        fi

        echo "🔧 Enabling $timer..."
        if systemctl enable --now "$timer" 2>/dev/null; then
            echo "   ✅ Success"
            success=$((success + 1))
        else
            echo "   ❌ Failed"
            failed=$((failed + 1))
        fi
    done

    echo ""
    echo "────────────────────────────────────────────────────────────────"
    echo "Summary:"
    echo "  Enabled:  $success"
    [[ $failed -gt 0 ]] && echo "  Failed:   $failed"
    [[ $skipped -gt 0 ]] && echo "  Skipped:  $skipped"
    echo ""

    [[ $failed -eq 0 ]]
}

# =============================================================================
# COMMAND: DISABLE
# =============================================================================

cmd_timers_disable() {
    local timer_name="${1:-}"

    nftban_banner

    echo "🔧 DISABLE SYSTEMD TIMERS"
    echo "════════════════════════════════════════════════════════════════"
    echo ""

    # Disable specific timer
    if [[ -n "$timer_name" ]]; then
        if ! timer_exists "$timer_name"; then
            echo "❌ Error: Timer '$timer_name' not found"
            return 1
        fi

        if ! nftban_service_is_enabled "$timer_name"; then
            echo "✅ $timer_name is already disabled"
            return 0
        fi

        echo "⚠️  WARNING: Disabling $timer_name"
        echo "   This will stop automated: ${TIMER_DESC[$timer_name]}"
        echo ""
        read -p "Continue? [y/N] " -n 1 -r
        echo

        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Cancelled"
            return 0
        fi

        echo "Disabling $timer_name..."
        if systemctl disable --now "$timer_name" 2>/dev/null; then
            echo "✅ Successfully disabled $timer_name"
        else
            echo "❌ Failed to disable $timer_name"
            return 1
        fi

        return 0
    fi

    # Disable all timers
    echo "⚠️  WARNING: This will disable ALL automated tasks:"
    for timer in "${NFTBAN_TIMERS[@]}"; do
        echo "   - ${TIMER_DESC[$timer]}"
    done
    echo ""
    read -p "Are you sure? [y/N] " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Cancelled"
        return 0
    fi

    local success=0
    local failed=0

    for timer in "${NFTBAN_TIMERS[@]}"; do
        if ! timer_exists "$timer"; then
            continue
        fi

        if ! nftban_service_is_enabled "$timer"; then
            echo "⚪ $timer - Already disabled"
            continue
        fi

        echo "🔧 Disabling $timer..."
        if systemctl disable --now "$timer" 2>/dev/null; then
            echo "   ✅ Success"
            success=$((success + 1))
        else
            echo "   ❌ Failed"
            failed=$((failed + 1))
        fi
    done

    echo ""
    echo "────────────────────────────────────────────────────────────────"
    echo "Summary:"
    echo "  Disabled: $success"
    [[ $failed -gt 0 ]] && echo "  Failed:   $failed"
    echo ""

    [[ $failed -eq 0 ]]
}

# =============================================================================
# COMMAND: MAIN ROUTER
# =============================================================================

nftban_cmd_timers() {
    local subcommand="${1:-status}"
    shift || true

    case "$subcommand" in
        status)
            cmd_timers_status "$@"
            ;;
        enable)
            cmd_timers_enable "$@"
            ;;
        disable)
            cmd_timers_disable "$@"
            ;;
        help|--help|-h)
            cat << 'EOF'
Usage: nftban timers <subcommand> [options]

Manage systemd timers for automated NFTBan tasks.

SUBCOMMANDS:
  status [--json]     Show status of all timers (default)
  enable [TIMER]      Enable timer(s) - all if no timer specified
  disable [TIMER]     Disable timer(s) - all if no timer specified
  help                Show this help message

OPTIONS:
  --json, -j          Output in JSON format (for status command)

TIMERS:
  nftban-health.timer              System health checks and auto-heal
  nftban-maintenance.timer         SSH/IP monitoring, trend data (every 15m)
  nftban-unified-exporter.timer    Unified metrics collection and export
  nftban-core-geoip.timer          GeoIP database updates
  nftban-core-feeds.timer          Threat feed synchronization
  nftban-queue.timer               Ban queue processing
  nftban-suricata-update.timer     Suricata IDS rules update
  nftban-snapshot.timer            Config/state snapshot creation
  nftban-rollback.timer            Rollback availability check
  nftban-update.timer              Weekly auto-update (Sunday 4:00 AM)

EXAMPLES:
  nftban timers                         # Show status
  nftban timers status                  # Show status (explicit)
  nftban timers enable                  # Enable all timers
  nftban timers enable nftban-health.timer    # Enable specific timer
  nftban timers disable nftban-queue.timer    # Disable specific timer

EOF
            ;;
        *)
            echo "Error: Unknown subcommand '$subcommand'" >&2
            echo "Run 'nftban timers help' for usage" >&2
            return 1
            ;;
    esac
}

# Backwards compatibility alias
cmd_timers() {
    nftban_cmd_timers "$@"
}

# Export functions
export -f nftban_cmd_timers
export -f cmd_timers

return 0 2>/dev/null || :
