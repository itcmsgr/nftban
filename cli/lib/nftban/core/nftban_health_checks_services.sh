#!/usr/bin/env bash
# shellcheck disable=SC1090  # Dynamic config paths, cannot follow
# shellcheck disable=SC2034  # NFTBAN_HEALTH_* arrays used by parent module that sources this
# =============================================================================
# NFTBan v1.0 - Health Check Services Functions
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Service-related health check functions (daemon, suricata, timers)
#
# meta:name="nftban_health_checks_services"
# meta:type="lib"
# meta:header="Health Check Services Functions"
# meta:version="1.44.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Service health check functions for system verification"
# meta:depends="nftban_health.sh,nftban_health_checks_core.sh"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="nftban"
# meta:created_date="2026-02-04"
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_NFTBAN_HEALTH_CHECKS_SERVICES_LOADED:-}" ]] && return 0
_NFTBAN_HEALTH_CHECKS_SERVICES_LOADED=1

# =============================================================================
# SHARED LIBRARY DEPENDENCIES
# =============================================================================

# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_file_utils.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_service_control.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_distro_config.sh" 2>/dev/null || true

# =============================================================================
# SERVICE CHECKS
# =============================================================================

nftban_health_check_services() {
    # Check systemd services status
    # Returns: 0=OK, 1=Warning, 2=Error (warnings only, no errors for disabled services)

    local status=$HEALTH_OK
    local service_issues=()

    # Optional services (only check if they exist)
    # v1.23.0 (EVAL-5): Removed nftban-login-monitor.service (deprecated since v1.21.3)
    local optional_services=(
        "${NFTBAN_SERVICE_SURICATA:-nftban-suricata.service}"
        "suricata.service"
    )

    for service in "${optional_services[@]}"; do
        if systemctl list-unit-files "$service" >/dev/null 2>&1; then
            if systemctl is-enabled "$service" >/dev/null 2>&1; then
                if ! systemctl is-active "$service" >/dev/null 2>&1; then
                    service_issues+=("$service is enabled but not running")
                    status=$HEALTH_WARNING
                fi
            fi
        fi
    done

    # Store results
    if [[ ${#service_issues[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["services"]="${service_issues[*]}"
        NFTBAN_HEALTH_WARNINGS+=("Service issues: ${service_issues[*]}")
    fi

    NFTBAN_HEALTH_RESULTS["services"]=$status
    return $status
}

nftban_health_check_daemon() {
    # Check nftband daemon status (CRITICAL for feeds and bans)
    # Returns: 0=OK, 1=Warning (auto-fixed), 2=Error (couldn't fix)
    # Args: $1 = auto_heal (0=check only, 1=auto-fix)

    local auto_heal="${1:-0}"
    local status=$HEALTH_OK
    local daemon_issues=()

    # Check nftband.socket (socket activation)
    if _health_service_exists "nftband.socket"; then
        if _health_service_active "nftband.socket"; then
            daemon_issues+=("✓ nftband.socket: Active")
        else
            daemon_issues+=("nftband.socket not active")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING

            # Auto-heal: Start socket
            if [[ $auto_heal -eq 1 ]] || [[ "${NFTBAN_HEALTH_AUTO_HEAL:-false}" == "true" ]]; then
                if systemctl start nftband.socket 2>/dev/null; then
                    daemon_issues+=("AUTO-FIXED: Started nftband.socket")
                else
                    daemon_issues+=("FAILED to start nftband.socket")
                    status=$HEALTH_ERROR
                fi
            else
                daemon_issues+=("FIX: sudo systemctl start nftband.socket")
            fi
        fi
    else
        daemon_issues+=("ℹ️ nftband.socket: Not installed (optional)")
    fi

    # Check nftband.service (main daemon - CRITICAL)
    if _health_service_exists "nftband.service"; then
        if _health_service_active "nftband.service"; then
            daemon_issues+=("✓ nftband.service: Running")
        else
            daemon_issues+=("CRITICAL: nftband daemon not running - feeds and bans will not work!")
            status=$HEALTH_ERROR

            # Auto-heal: Start daemon
            if [[ $auto_heal -eq 1 ]] || [[ "${NFTBAN_HEALTH_AUTO_HEAL:-false}" == "true" ]]; then
                if systemctl start nftband.service 2>/dev/null; then
                    sleep 2
                    if _health_service_active "nftband.service"; then
                        daemon_issues+=("AUTO-FIXED: Started nftband daemon")
                        status=$HEALTH_WARNING  # Downgrade from error since we fixed it
                    else
                        daemon_issues+=("FAILED: nftband daemon won't start - check: journalctl -u nftband.service")
                    fi
                else
                    daemon_issues+=("FAILED to start nftband daemon")
                fi
            else
                daemon_issues+=("FIX: sudo systemctl start nftband.service")
            fi
        fi

        # Check if daemon is enabled
        if ! _health_service_enabled "nftband.service"; then
            daemon_issues+=("⚠ nftband.service not enabled (won't start on boot)")
            [[ $status -eq $HEALTH_OK ]] && status=$HEALTH_WARNING
            daemon_issues+=("FIX: sudo systemctl enable nftband.service")
        fi

        # Check for stale PID file (case study: lab1 missing metrics due to stale PID)
        local pid_file="${NFTBAN_RUN_DIR:-/run/nftban}/nftband.pid"
        if [[ -f "$pid_file" ]] && _health_service_active "nftband.service"; then
            local stored_pid actual_pid
            stored_pid=$(cat "$pid_file" 2>/dev/null | awk '{print $1}')
            actual_pid=$(pgrep -f "/usr/lib/nftban/bin/nftband" | head -1)

            if [[ -n "$stored_pid" ]] && [[ -n "$actual_pid" ]]; then
                if [[ "$stored_pid" != "$actual_pid" ]]; then
                    daemon_issues+=("⚠ Stale PID file: stored=$stored_pid, actual=$actual_pid (metrics affected)")
                    [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING

                    # Auto-heal: Update PID file
                    if [[ $auto_heal -eq 1 ]] || [[ "${NFTBAN_HEALTH_AUTO_HEAL:-false}" == "true" ]]; then
                        if echo "$actual_pid" > "$pid_file" 2>/dev/null; then
                            daemon_issues+=("AUTO-FIXED: Updated PID file to $actual_pid")
                        else
                            daemon_issues+=("FAILED to update PID file")
                        fi
                    else
                        daemon_issues+=("FIX: echo $actual_pid > $pid_file")
                    fi
                elif [[ ! -d "/proc/$stored_pid" ]]; then
                    daemon_issues+=("⚠ PID file points to non-existent process: $stored_pid")
                    [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
                else
                    daemon_issues+=("✓ PID file valid: $stored_pid")
                fi
            fi
        fi
    else
        daemon_issues+=("ERROR: nftband.service not installed - daemon functionality unavailable")
        status=$HEALTH_ERROR
    fi

    # Store results
    if [[ ${#daemon_issues[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["daemon"]="${daemon_issues[*]}"
        if [[ $status -eq $HEALTH_ERROR ]]; then
            NFTBAN_HEALTH_ERRORS+=("Daemon issues: ${daemon_issues[*]}")
        elif [[ $status -eq $HEALTH_WARNING ]]; then
            NFTBAN_HEALTH_WARNINGS+=("Daemon issues: ${daemon_issues[*]}")
        fi
    fi

    NFTBAN_HEALTH_RESULTS["daemon"]=$status
    return $status
}

nftban_health_check_suricata() {
    # Comprehensive Suricata IDS health check
    # Returns: 0=OK, 1=Warning, 2=Error
    # NOTE: Supports Suricata 7.x threaded logging (eve-alerts.1.json, eve-alerts.2.json, etc.)

    local status=$HEALTH_OK
    local suricata_issues=()

    # 1. Check if Suricata is installed
    if ! command -v suricata >/dev/null 2>&1; then
        # Suricata is optional, not an error if missing
        NFTBAN_HEALTH_RESULTS["suricata"]=$HEALTH_OK
        return $HEALTH_OK
    fi

    # 2. Check if Suricata service is active (if enabled)
    if systemctl list-unit-files 2>/dev/null | grep -q "^suricata.service"; then
        if systemctl is-enabled --quiet suricata.service 2>/dev/null; then
            if ! systemctl is-active --quiet suricata.service; then
                suricata_issues+=("Suricata service enabled but not running")
                status=$HEALTH_ERROR
            fi
        fi
    fi

    # 3. Check eve-alerts*.json log files exist and have recent activity
    # Support Suricata 7.x threaded logging (eve-alerts.1.json, eve-alerts.2.json, etc.)
    local eve_dir="${NFTBAN_LOG_DIR:-/var/log/nftban}/suricata"
    local eve_log="${NFTBAN_SURICATA_EVE_LOG:-${eve_dir}/eve-alerts.json}"

    # Helper: Find freshest mtime across all eve-alerts*.json files
    local freshest_mtime=0
    local freshest_file=""
    local total_size=0

    shopt -s nullglob
    for f in "$eve_dir"/eve-alerts*.json; do
        [[ -f "$f" ]] || continue
        local m s
        m=$(stat -L -c %Y -- "$f" 2>/dev/null) || continue
        s=$(stat -c %s -- "$f" 2>/dev/null) || s=0
        [[ "$m" =~ ^[0-9]+$ ]] || continue
        total_size=$((total_size + s))
        if (( m > freshest_mtime )); then
            freshest_mtime=$m
            freshest_file="$f"
        fi
    done
    shopt -u nullglob

    if [[ $freshest_mtime -gt 0 ]]; then
        # Check if freshest file has been modified in last 10 minutes (600s)
        local current_time age
        current_time=$(date +%s)
        age=$((current_time - freshest_mtime))

        if [[ $age -gt 600 ]]; then
            if [[ "$freshest_file" != "$eve_log" ]]; then
                suricata_issues+=("EVE logs not updated in 10+ minutes (threaded: $freshest_file is ${age}s old)")
            else
                suricata_issues+=("eve-alerts.json not updated in 10+ minutes (may be stalled)")
            fi
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi

        # Check total file size (warn if > 1GB across all EVE files)
        if [[ $total_size -gt 1073741824 ]]; then
            suricata_issues+=("EVE logs large ($(numfmt --to=iec "$total_size" 2>/dev/null || echo "${total_size}B")), consider log rotation")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi
    elif systemctl is-active --quiet suricata.service 2>/dev/null; then
        # Service running but no log files found
        suricata_issues+=("Suricata running but no eve-alerts*.json found in $eve_dir")
        status=$HEALTH_ERROR
    fi

    # 4. CRITICAL: Check if rules are actually loaded (rules_loaded > 0)
    if systemctl is-active --quiet suricata.service 2>/dev/null; then
        local rules_loaded=0
        # Try to get rules_loaded from any EVE JSON file (main or threaded)
        shopt -s nullglob
        for ef in "$eve_log" "$eve_dir"/eve-alerts.*.json; do
            [[ -f "$ef" ]] || continue
            rules_loaded=$(grep -o '"rules_loaded":[0-9]*' "$ef" 2>/dev/null | tail -1 | cut -d: -f2 || echo "0")
            [[ "${rules_loaded:-0}" -gt 0 ]] && break
        done
        shopt -u nullglob

        # Fallback: check suricata.rules file exists and has content
        if [[ "${rules_loaded:-0}" -eq 0 ]]; then
            local rules_file="${DISTRO_PATHS[suricata_rules_dir]:-/var/lib/suricata/rules}/suricata.rules"
            if [[ -f "$rules_file" ]] && [[ -s "$rules_file" ]]; then
                rules_loaded=$(grep -c "^alert" "$rules_file" 2>/dev/null || echo "0")
            fi
        fi

        if [[ "${rules_loaded:-0}" -eq 0 ]]; then
            suricata_issues+=("CRITICAL: Suricata running with 0 rules loaded - NO PROTECTION!")
            suricata_issues+=("FIX: suricata-update && systemctl restart suricata")
            status=$HEALTH_ERROR
        fi
    fi

    # 5. Check Suricata memory usage (if running)
    if systemctl is-active --quiet suricata.service 2>/dev/null; then
        local suricata_pid
        suricata_pid=$(systemctl show -p MainPID --value suricata.service 2>/dev/null)
        if [[ -n "$suricata_pid" && "$suricata_pid" != "0" ]]; then
            local mem_mb
            mem_mb=$(ps -p "$suricata_pid" -o rss= 2>/dev/null | awk '{print int($1/1024)}')
            if [[ -n "$mem_mb" && $mem_mb -gt 1024 ]]; then
                suricata_issues+=("Suricata memory usage high (${mem_mb}MB, expected 300-600MB)")
                [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
            fi
        fi
    fi

    # 5. Check sysctl network buffer tuning
    if [[ -f /etc/sysctl.d/90-suricata.conf ]]; then
        local rmem_max
        rmem_max=$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)
        if [[ $rmem_max -lt 67108864 ]]; then
            suricata_issues+=("Network buffer not optimized (rmem_max: $rmem_max, expected: 67108864)")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi
    elif systemctl is-active --quiet suricata.service 2>/dev/null; then
        suricata_issues+=("Sysctl tuning not applied (/etc/sysctl.d/90-suricata.conf missing)")
        [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
    fi

    # Store results
    if [[ ${#suricata_issues[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["suricata"]="${suricata_issues[*]}"
        if [[ $status -eq $HEALTH_WARNING ]]; then
            NFTBAN_HEALTH_WARNINGS+=("Suricata: ${suricata_issues[*]}")
        elif [[ $status -eq $HEALTH_ERROR ]]; then
            NFTBAN_HEALTH_ERRORS+=("Suricata: ${suricata_issues[*]}")
        fi
    fi

    NFTBAN_HEALTH_RESULTS["suricata"]=$status
    return $status
}

nftban_health_check_suricata_capture() {
    # Check Suricata packet capture health (v1.12.0)
    # Uses Suricata stats (capture.kernel_packets) for verification
    # Returns: 0=OK, 1=Warning, 2=Error

    local status=$HEALTH_OK
    local capture_issues=()

    # Only check if Suricata is running
    if ! systemctl is-active --quiet suricata.service 2>/dev/null; then
        NFTBAN_HEALTH_RESULTS["suricata_capture"]=$HEALTH_OK
        return $HEALTH_OK
    fi

    # Load interface configuration
    local iface_config="${DISTRO_PATHS[suricata_iface_config]:-/etc/nftban/conf.d/suricata/interfaces.conf}"
    local configured_ifaces=""
    local iface_mode="auto"

    if [[ -f "$iface_config" ]]; then
        # shellcheck source=/dev/null
        source "$iface_config" 2>/dev/null || true
        iface_mode="${SURICATA_IFACE_MODE:-auto}"
        configured_ifaces="${SURICATA_IFACES:-}"
    fi

    # Get stats log path
    local stats_log="${DISTRO_PATHS[suricata_stats_log]:-/var/log/suricata/stats.log}"
    local eve_log="${NFTBAN_SURICATA_EVE_LOG:-/var/log/nftban/suricata/eve-alerts.json}"

    # 1. Check configured interface(s) exist and are UP
    if [[ "$iface_mode" == "manual" ]] && [[ -n "$configured_ifaces" ]]; then
        IFS=',' read -ra iface_array <<< "$configured_ifaces"
        for iface in "${iface_array[@]}"; do
            iface=$(echo "$iface" | xargs)
            [[ -z "$iface" ]] && continue

            if [[ ! -d "/sys/class/net/$iface" ]]; then
                capture_issues+=("CRITICAL: Configured interface '$iface' does not exist")
                capture_issues+=("FIX: nftban suricata iface list")
                status=$HEALTH_ERROR
            elif [[ "$(cat /sys/class/net/$iface/operstate 2>/dev/null)" != "up" ]]; then
                capture_issues+=("ERROR: Configured interface '$iface' is DOWN")
                capture_issues+=("FIX: ip link set $iface up")
                status=$HEALTH_ERROR
            fi
        done
    fi

    # 2. Check Suricata stats for packet capture (if stats.log exists)
    if [[ -f "$stats_log" ]]; then
        local last_stats
        last_stats=$(tail -50 "$stats_log" 2>/dev/null | grep "capture.kernel_packets" | tail -1)

        if [[ -n "$last_stats" ]]; then
            local kernel_packets
            kernel_packets=$(echo "$last_stats" | grep -oP 'capture\.kernel_packets\s*\|\s*\K[0-9]+' || echo "0")

            if [[ "${kernel_packets:-0}" -eq 0 ]]; then
                # Check if file was recently modified (within 5 min)
                local stats_age
                stats_age=$(( $(date +%s) - $(stat -c %Y "$stats_log" 2>/dev/null || echo 0) ))

                if [[ $stats_age -lt 300 ]]; then
                    capture_issues+=("CRITICAL: Zero packets captured (kernel_packets=0)")
                    capture_issues+=("FIX: nftban suricata iface list")
                    status=$HEALTH_ERROR
                fi
            fi

            # Check for high drops
            local kernel_drops
            kernel_drops=$(echo "$last_stats" | grep -oP 'capture\.kernel_drops\s*\|\s*\K[0-9]+' || echo "0")

            if [[ "${kernel_drops:-0}" -gt 1000 ]]; then
                capture_issues+=("WARNING: High packet drops (kernel_drops=${kernel_drops})")
                capture_issues+=("FIX: Tune ring buffer size in suricata.yaml or use nftban suricata profile")
                [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
            fi
        fi
    fi

    # 3. Alternative: Check EVE stats if stats.log not available
    if [[ ${#capture_issues[@]} -eq 0 ]] && [[ -f "$eve_log" ]]; then
        # Look for stats events in EVE JSON (if stats output enabled)
        local last_capture_stats
        last_capture_stats=$(tail -500 "$eve_log" 2>/dev/null | grep -o '"capture":{"kernel_packets":[0-9]*' | tail -1)

        if [[ -n "$last_capture_stats" ]]; then
            local eve_kernel_packets
            eve_kernel_packets=$(echo "$last_capture_stats" | grep -oP '"kernel_packets":\K[0-9]+' || echo "0")

            if [[ "${eve_kernel_packets:-0}" -eq 0 ]]; then
                capture_issues+=("WARNING: EVE stats show zero kernel_packets")
                [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
            fi
        fi
    fi

    # Store results
    if [[ ${#capture_issues[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["suricata_capture"]="${capture_issues[*]}"
        if [[ $status -eq $HEALTH_WARNING ]]; then
            NFTBAN_HEALTH_WARNINGS+=("Suricata Capture: ${capture_issues[*]}")
        elif [[ $status -eq $HEALTH_ERROR ]]; then
            NFTBAN_HEALTH_ERRORS+=("Suricata Capture: ${capture_issues[*]}")
        fi
    fi

    NFTBAN_HEALTH_RESULTS["suricata_capture"]=$status
    return $status
}

# =============================================================================
# TIMER CHECKS
# =============================================================================

nftban_health_check_timers() {
    # Check all NFTBan systemd timers (v0.7.3)
    # Returns: 0=OK, 1=WARNING, 2=ERROR, 3=CRITICAL
    # Args: $1 = auto_heal (0=check only, 1=auto-fix)

    local auto_heal="${1:-0}"
    local status=$HEALTH_OK
    local timer_issues=()

    # Core NFTBan timers (REQUIRED - always enabled)
    local -a timers=(
        "nftban-maintenance.timer"      # CRITICAL: SSH/IP protection, auto-heal
        "nftban-health.timer"           # Health checks
        "nftban-queue.timer"            # Ban queue processing
    )

    # Conditionally add feature-specific timers (only if feature is enabled)
    if [[ "${NFTBAN_FEEDS_ENABLED:-false}" == "true" ]]; then
        timers+=("nftban-core-feeds.timer")   # Threat feeds sync
    fi
    if [[ "${NFTBAN_GEOIP_ENABLED:-false}" == "true" ]]; then
        timers+=("nftban-core-geoip.timer")   # GeoIP updates
    fi

    # shellcheck disable=SC2034
    local -a optional_timers=(
        "nftban-watchdog.timer"         # System resource monitoring
        "nftban-unified-exporter.timer" # Unified export
        "nftban-suricata-update.timer"  # Suricata rules
        "nftban-snapshot.timer"         # Firewall snapshots
        "nftban-rollback.timer"         # Auto-rollback checks
    )

    local -A timer_desc=(
        ["nftban-maintenance.timer"]="CRITICAL: SSH/IP lockout prevention, auto-heal"
        ["nftban-health.timer"]="Health checks and auto-heal"
        ["nftban-core-feeds.timer"]="Threat feeds sync (if NFTBAN_FEEDS_ENABLED=true)"
        ["nftban-core-geoip.timer"]="GeoIP database updates"
        ["nftban-queue.timer"]="Ban queue processing"
        ["nftban-watchdog.timer"]="System resource monitoring"
        ["nftban-unified-exporter.timer"]="Unified export (Prometheus+Zabbix+Connectors)"
        ["nftban-suricata-update.timer"]="Suricata rules update (optional)"
        ["nftban-snapshot.timer"]="Firewall snapshot creation (optional)"
        ["nftban-rollback.timer"]="Auto-rollback checks (optional)"
    )

    local total=0
    local enabled=0
    local active=0
    local missing=0
    local disabled=0

    # Check each timer
    for timer in "${timers[@]}"; do
        total=$((total + 1))

        # Check if timer unit file exists
        if ! systemctl list-unit-files "$timer" --no-legend 2>/dev/null | grep -q "^$timer"; then
            timer_issues+=("⚠ $timer not installed - ${timer_desc[$timer]}")
            missing=$((missing + 1))
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING

            # Auto-heal: Try to install if from systemd directory
            if [[ $auto_heal -eq 1 ]]; then
                local timer_file="/home/gituser/github/nftban-dev/install/systemd/$timer"
                if [[ -f "$timer_file" ]]; then
                    echo "  🔧 Auto-heal: Installing $timer..."
                    if cp "$timer_file" /etc/systemd/system/ 2>/dev/null && systemctl daemon-reload 2>/dev/null; then
                        timer_issues+=("✓ Installed $timer")
                    else
                        timer_issues+=("❌ Failed to install $timer")
                    fi
                fi
            fi
            continue
        fi

        # Check if enabled
        if systemctl is-enabled --quiet "$timer" 2>/dev/null; then
            enabled=$((enabled + 1))

            # Check if active
            if systemctl is-active --quiet "$timer" 2>/dev/null; then
                active=$((active + 1))
                timer_issues+=("✓ $timer - Active")
            else
                timer_issues+=("⚠ $timer - Enabled but not active")
                [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING

                # Auto-heal: Start timer
                if [[ $auto_heal -eq 1 ]]; then
                    echo "  🔧 Auto-heal: Starting $timer..."
                    if systemctl start "$timer" 2>/dev/null; then
                        timer_issues+=("✓ Started $timer")
                    else
                        timer_issues+=("❌ Failed to start $timer")
                    fi
                fi
            fi
        else
            disabled=$((disabled + 1))
            timer_issues+=("⚠ $timer - Disabled (${timer_desc[$timer]})")
            timer_issues+=("FIX: sudo systemctl enable --now $timer")
            [[ $status -lt $HEALTH_ERROR ]] && status=$HEALTH_ERROR

            # Auto-heal: Enable and start timer
            if [[ $auto_heal -eq 1 ]]; then
                echo "  🔧 Auto-heal: Enabling $timer..."
                if systemctl enable --now "$timer" 2>/dev/null; then
                    timer_issues+=("✓ Enabled and started $timer")
                    enabled=$((enabled + 1))
                    active=$((active + 1))
                    disabled=$((disabled - 1))
                else
                    timer_issues+=("❌ Failed to enable $timer")
                fi
            fi
        fi
    done

    # Summary
    if [[ $active -eq $total ]]; then
        timer_issues=("✓ All timers active ($active/$total)" "${timer_issues[@]}")
    elif [[ $enabled -eq $total ]]; then
        timer_issues=("⚠ All timers enabled but some not active ($active/$total active)" "${timer_issues[@]}")
    elif [[ $disabled -gt 0 ]]; then
        timer_issues=("⚠ $disabled/$total timers disabled" "${timer_issues[@]}")
    fi

    if [[ $missing -gt 0 ]]; then
        timer_issues+=("⚠ $missing/$total timers not installed")
        timer_issues+=("FIX: Run install script - sudo ./install.sh systemd")
    fi

    # Store results
    # shellcheck disable=SC2034
    NFTBAN_HEALTH_RESULTS["timers"]=$status
    # shellcheck disable=SC2034
    NFTBAN_HEALTH_ISSUES["timers"]="${timer_issues[*]}"

    return $status
}

# =============================================================================
# MAINTENANCE LOCK CHECK (Bug #23: Stale locks block maintenance)
# =============================================================================

nftban_health_check_maintenance_lock() {
    # Check for stale maintenance lock files
    # Bug found: Dual locking (flock + script) causes permanent lock state
    # Returns: 0=OK, 1=Warning (stale lock found or auto-fixed)
    # Args: $1 = auto_heal (0=check only, 1=auto-fix)

    local auto_heal="${1:-0}"
    local status=$HEALTH_OK
    local lock_issues=()
    local lockfile="${NFTBAN_RUN_DIR:-/run/nftban}/maintenance.lock"

    if [[ -f "$lockfile" ]]; then
        local lock_age lock_pid
        # Use shared library function if available, fallback to inline calculation
        if declare -f nftban_file_age >/dev/null 2>&1; then
            lock_age=$(nftban_file_age "$lockfile")
        else
            lock_age=$(( $(date +%s) - $(stat -c %Y "$lockfile" 2>/dev/null || echo 0) ))
        fi
        lock_pid=$(cat "$lockfile" 2>/dev/null | head -1)

        # Check if lock is stale (>30min AND PID not running)
        if [[ $lock_age -gt 1800 ]]; then
            local is_stale=0

            if [[ -n "$lock_pid" ]] && [[ "$lock_pid" =~ ^[0-9]+$ ]]; then
                if ! kill -0 "$lock_pid" 2>/dev/null; then
                    lock_issues+=("Stale maintenance lock: ${lock_age}s old, PID $lock_pid not running")
                    is_stale=1
                fi
            else
                # Invalid PID in lock file
                lock_issues+=("Invalid maintenance lock file (no valid PID)")
                is_stale=1
            fi

            if [[ $is_stale -eq 1 ]]; then
                # Auto-heal: Remove stale lock
                if [[ $auto_heal -eq 1 ]] || [[ "${NFTBAN_HEALTH_AUTO_HEAL:-false}" == "true" ]]; then
                    if rm -f "$lockfile" 2>/dev/null; then
                        lock_issues+=("AUTO-FIXED: Removed stale lock file")
                        status=$HEALTH_WARNING  # Fixed, but note it happened
                    else
                        lock_issues+=("FAILED to remove stale lock (need root)")
                        lock_issues+=("FIX: sudo rm -f \"$lockfile\"")
                        status=$HEALTH_WARNING
                        NFTBAN_HEALTH_WARNINGS+=("Stale maintenance lock blocking scheduled maintenance")
                    fi
                else
                    lock_issues+=("FIX: sudo rm -f \"$lockfile\"")
                    status=$HEALTH_WARNING
                    NFTBAN_HEALTH_WARNINGS+=("Stale maintenance lock blocking scheduled maintenance")
                fi
            fi
        fi
    fi

    NFTBAN_HEALTH_RESULTS["maintenance_lock"]=$status
    [[ ${#lock_issues[@]} -gt 0 ]] && NFTBAN_HEALTH_ISSUES["maintenance_lock"]="${lock_issues[*]}"
    return $status
}

# =============================================================================
# LOGIN MONITOR IPC CHECK (Bug #22: Login monitor can't communicate with daemon)
# =============================================================================

nftban_health_check_login_monitor_ipc() {
    # Check if login monitor can communicate with nftband daemon
    # Bug found: Error message "nftban command not found" is misleading - actual issue is IPC
    # Returns: 0=OK, 2=Error (IPC broken)

    local status=$HEALTH_OK
    local ipc_issues=()
    local socket="${NFTBAN_RUN_DIR:-/run/nftban}/nftband.sock"

    # Only check if login monitor service is active
    if systemctl is-active --quiet nftban-login-monitor.service 2>/dev/null; then
        # Check if daemon socket exists
        if [[ ! -S "$socket" ]]; then
            ipc_issues+=("Login monitor running but IPC socket missing: $socket")
            ipc_issues+=("FIX: sudo systemctl start nftband.service")
            status=$HEALTH_ERROR
            NFTBAN_HEALTH_ERRORS+=("Login monitor cannot ban IPs - daemon socket missing")
        else
            # Check socket permissions (should be 0660 root:nftban)
            local sock_perms sock_group
            sock_perms=$(stat -c %a "$socket" 2>/dev/null || echo "000")
            sock_group=$(stat -c %G "$socket" 2>/dev/null || echo "unknown")

            if [[ "$sock_group" != "nftban" ]]; then
                ipc_issues+=("IPC socket wrong group: $sock_group (expected nftban)")
                status=$HEALTH_WARNING
            fi

            # Warn if socket permissions too open (should be 660)
            if [[ "$sock_perms" != "660" && "$sock_perms" != "770" ]]; then
                ipc_issues+=("IPC socket permissions: $sock_perms (expected 660 or 770)")
            fi
        fi
    fi

    NFTBAN_HEALTH_RESULTS["login_monitor_ipc"]=$status
    [[ ${#ipc_issues[@]} -gt 0 ]] && NFTBAN_HEALTH_ISSUES["login_monitor_ipc"]="${ipc_issues[*]}"
    return $status
}

# =============================================================================
# HUNG PROCESS CHECK (v1.44.0 BUG-009: ban confirmation prompt can hang)
# =============================================================================
# Detects and auto-heals hung nftban CLI processes (e.g. stuck on read/IPC).
# Logs all incidents to /var/log/nftban/health-incidents.log for quality tracking.
# Args: $1 = auto_heal (0=check only, 1=auto-fix by killing hung processes)

nftban_health_check_hung_processes() {
    local auto_heal="${1:-0}"
    local status=$HEALTH_OK
    local hung_issues=()
    local hung_count=0
    local killed_count=0
    local max_age=300  # 5 minutes — CLI commands should never take this long
    local incident_log="${NFTBAN_LOG_DIR:-/var/log/nftban}/health-incidents.log"

    # Find nftban CLI processes (not daemon, not this health check)
    local line
    while IFS= read -r line; do
        local pid elapsed cmd
        pid=$(echo "$line" | awk '{print $1}')
        elapsed=$(echo "$line" | awk '{print $2}')
        cmd=$(echo "$line" | awk '{$1=$2=""; print $0}' | sed 's/^ *//')

        # Skip long-running services (daemon, exporter, health check itself)
        [[ "$cmd" == *nftband* ]] && continue
        [[ "$cmd" == *exporter* ]] && continue
        [[ "$cmd" == *health* ]] && continue
        [[ "$cmd" == *"login-monitor"* ]] && continue
        # Skip non-nftban processes that happen to have "nftban" in args
        # (e.g. postgres connections to nftban_portal database)
        [[ "$cmd" != *"bash"* && "$cmd" != *"/usr/sbin/nftban"* && "$cmd" != *"/usr/lib/nftban"* ]] && continue

        if [[ "$elapsed" -gt "$max_age" ]]; then
            hung_issues+=("Hung PID $pid (${elapsed}s): $cmd")
            ((hung_count++)) || true

            # Diagnose root cause from /proc (best-effort)
            local root_cause="unknown"
            local wchan=""
            wchan=$(cat "/proc/$pid/wchan" 2>/dev/null || echo "")
            local fd_count=0
            fd_count=$(ls "/proc/$pid/fd" 2>/dev/null | wc -l || echo 0)
            if [[ "$wchan" == *"wait_woken"* ]] || [[ "$wchan" == *"pipe_read"* ]]; then
                root_cause="blocked_on_read(likely_stdin_prompt)"
            elif [[ "$wchan" == *"poll"* ]] || [[ "$wchan" == *"select"* ]]; then
                root_cause="blocked_on_io(likely_ipc_socket)"
            elif [[ "$wchan" == *"futex"* ]]; then
                root_cause="blocked_on_lock"
            fi

            # Log incident for quality tracking (always, regardless of auto_heal)
            local timestamp
            timestamp=$(date '+%Y-%m-%d %H:%M:%S')
            mkdir -p "$(dirname "$incident_log")" 2>/dev/null || true
            echo "[$timestamp] [HUNG_PROCESS] pid=$pid elapsed=${elapsed}s cause=$root_cause wchan=$wchan fds=$fd_count cmd=\"$cmd\"" >> "$incident_log" 2>/dev/null || true

            # Syslog for centralized monitoring
            logger -t nftban-health -p user.warning \
                "Hung process detected: pid=$pid elapsed=${elapsed}s cause=$root_cause cmd=$cmd" 2>/dev/null || true

            # Auto-heal: SIGTERM first, SIGKILL if still alive after 3s
            if [[ $auto_heal -eq 1 ]] || [[ "${NFTBAN_HEALTH_AUTO_HEAL:-false}" == "true" ]]; then
                if kill -TERM "$pid" 2>/dev/null; then
                    sleep 3
                    if kill -0 "$pid" 2>/dev/null; then
                        # Still alive — force kill
                        kill -KILL "$pid" 2>/dev/null || true
                        hung_issues+=("AUTO-FIXED: Force-killed PID $pid (SIGKILL)")
                        echo "[$timestamp] [AUTO-HEAL] action=SIGKILL pid=$pid cmd=\"$cmd\"" >> "$incident_log" 2>/dev/null || true
                    else
                        hung_issues+=("AUTO-FIXED: Terminated PID $pid (SIGTERM)")
                        echo "[$timestamp] [AUTO-HEAL] action=SIGTERM pid=$pid cmd=\"$cmd\"" >> "$incident_log" 2>/dev/null || true
                    fi
                    ((killed_count++)) || true
                    logger -t nftban-health -p user.notice \
                        "Auto-healed hung process: pid=$pid killed" 2>/dev/null || true
                fi
            fi
        fi
    done < <(ps -eo pid,etimes,args 2>/dev/null | grep '[n]ftban' | grep -v grep || true)

    if [[ $hung_count -gt 0 ]]; then
        if [[ $killed_count -eq $hung_count ]]; then
            # All hung processes were killed — downgrade to warning
            status=$HEALTH_WARNING
            NFTBAN_HEALTH_WARNINGS+=("AUTO-FIXED: Killed $killed_count hung nftban process(es)")
        elif [[ $killed_count -gt 0 ]]; then
            status=$HEALTH_WARNING
            NFTBAN_HEALTH_WARNINGS+=("Partially fixed: killed $killed_count/$hung_count hung process(es)")
        else
            status=$HEALTH_WARNING
            NFTBAN_HEALTH_WARNINGS+=("$hung_count hung nftban process(es) detected (>${max_age}s)")
            for issue in "${hung_issues[@]}"; do
                NFTBAN_HEALTH_WARNINGS+=("$issue")
            done
            NFTBAN_HEALTH_WARNINGS+=("FIX: nftban health fix  OR  kill <PIDs>")
        fi
    fi

    NFTBAN_HEALTH_RESULTS["hung_processes"]=$status
    [[ ${#hung_issues[@]} -gt 0 ]] && NFTBAN_HEALTH_ISSUES["hung_processes"]="${hung_issues[*]}"
    return $status
}

# Export functions
export -f nftban_health_check_services nftban_health_check_daemon
export -f nftban_health_check_suricata nftban_health_check_suricata_capture
export -f nftban_health_check_timers
export -f nftban_health_check_maintenance_lock nftban_health_check_login_monitor_ipc
export -f nftban_health_check_hung_processes
