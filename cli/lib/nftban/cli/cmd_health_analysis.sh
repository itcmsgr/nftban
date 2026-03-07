#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0 - Health Check CLI Command - Analysis Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Analysis health checks: conflicts, config, rbl, posture, gui
#
# meta:name="cmd_health_analysis"
# meta:type="cli"
# meta:header="Health Check Analysis Module"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Analysis health checks: conflicts, config, rbl, posture, gui"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="conditional"
#
# Loaded by: cmd_health.sh (inherits strict mode)
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_CMD_HEALTH_ANALYSIS_LOADED:-}" ]] && return 0
_CMD_HEALTH_ANALYSIS_LOADED="true"

# =============================================================================
# COMMAND: conflicts
# =============================================================================

nftban_health_cmd_conflicts() {
    # Detect and optionally remove conflicting firewalls
    # Usage: nftban health conflicts [--fix] [--yes]
    # Args: --fix = remove conflicts, --yes = auto-confirm

    local fix_mode=false
    local auto_yes=false

    for arg in "$@"; do
        case "$arg" in
            --fix|--remove) fix_mode=true ;;
            --yes|-y) auto_yes=true ;;
            --help|-h)
                echo "Usage: nftban health conflicts [--fix] [--yes]"
                echo ""
                echo "Detect and optionally remove conflicting firewalls."
                echo ""
                echo "Options:"
                echo "  --fix, --remove    Remove detected conflicts"
                echo "  --yes, -y          Auto-confirm removal (no prompts)"
                echo ""
                echo "Detects: fail2ban, ufw, firewalld, CSF, iptables"
                echo "Panel-aware: Uses correct conflicts per panel+distro"
                return 0
                ;;
        esac
    done

    # Load firewall conflicts module
    if ! declare -f nftban_detect_all_conflicts >/dev/null 2>&1; then
        if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_firewall_conflicts.sh" ]]; then
            source "${NFTBAN_LIB_DIR}/core/nftban_firewall_conflicts.sh"
        else
            echo "ERROR: Firewall conflicts module not found" >&2
            return 1
        fi
    fi

    # Detect panel and distro
    local panel distro
    panel=$(nftban_detect_panel)
    distro=$(nftban_detect_distro)

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NFTBan Firewall Conflict Detection"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  System:  $panel on $distro"
    echo ""

    # Run detection FIRST (returns severity as exit code, don't let set -e kill us)
    nftban_detect_all_conflicts || true

    # Show DETECTED CONFLICTS (what's ACTUALLY active)
    echo "┌────────────────────────────────────────────────────────────┐"
    echo "│ ACTIVE CONFLICTS (detected on this system)                 │"
    echo "├────────────────────────────────────────────────────────────┤"

    local has_conflicts=false

    # Check each potential conflict and show status
    # fail2ban
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        echo "│  ✗ fail2ban      ACTIVE (running)                         │"
        has_conflicts=true
    elif systemctl is-enabled --quiet fail2ban 2>/dev/null; then
        echo "│  ⚠ fail2ban      ENABLED (not running)                    │"
        has_conflicts=true
    else
        echo "│  ✓ fail2ban      not installed/disabled                   │"
    fi

    # firewalld
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        echo "│  ✗ firewalld     ACTIVE (running)                         │"
        has_conflicts=true
    elif systemctl is-enabled --quiet firewalld 2>/dev/null; then
        echo "│  ⚠ firewalld     ENABLED (not running)                    │"
        has_conflicts=true
    else
        echo "│  ✓ firewalld     not installed/disabled                   │"
    fi

    # ufw
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "^Status: active"; then
        echo "│  ✗ ufw           ACTIVE (enabled)                         │"
        has_conflicts=true
    elif command -v ufw &>/dev/null; then
        echo "│  ✓ ufw           installed but inactive                   │"
    else
        echo "│  ✓ ufw           not installed                            │"
    fi

    # CSF - Check BOTH service status AND config file
    # Root cause fix: Previously only checked config, not service state
    # CSF can be disabled (csf -x) but config still has TESTING="0"
    local csf_service_active=false
    if systemctl is-active --quiet lfd 2>/dev/null; then
        csf_service_active=true
    elif command -v csf &>/dev/null && csf -s 2>&1 | grep -q "csf is enabled"; then
        csf_service_active=true
    fi

    if [[ "$csf_service_active" == "true" ]] && [[ -f /etc/csf/csf.conf ]]; then
        if grep -q "^TESTING = \"0\"" /etc/csf/csf.conf 2>/dev/null; then
            echo "│  ✗ CSF           ACTIVE (production mode)                 │"
        else
            echo "│  ✗ CSF           ACTIVE (testing mode)                    │"
        fi
        has_conflicts=true
    elif [[ -f /etc/csf/csf.conf ]]; then
        echo "│  ✓ CSF           disabled (no conflict)                   │"
    else
        echo "│  ✓ CSF           not installed                            │"
    fi

    # iptables service
    if systemctl is-active --quiet iptables 2>/dev/null || systemctl is-active --quiet ip6tables 2>/dev/null; then
        echo "│  ✗ iptables      ACTIVE (service running)                 │"
        has_conflicts=true
    elif systemctl is-enabled --quiet iptables 2>/dev/null; then
        echo "│  ⚠ iptables      ENABLED (not running)                    │"
        has_conflicts=true
    else
        echo "│  ✓ iptables      service not active                       │"
    fi

    echo "└────────────────────────────────────────────────────────────┘"
    echo ""

    # Show verdict
    if [[ "$has_conflicts" == true ]]; then
        echo "  ┌──────────────────────────────────────────────────────────┐"
        echo "  │  ⚠️  CONFLICTS DETECTED                                   │"
        echo "  │                                                          │"
        echo "  │  These firewalls may interfere with NFTBan.              │"
        echo "  │  Run: nftban health conflicts --fix                      │"
        echo "  └──────────────────────────────────────────────────────────┘"
    else
        echo "  ┌──────────────────────────────────────────────────────────┐"
        echo "  │  ✅ NO CONFLICTS DETECTED                                 │"
        echo "  │                                                          │"
        echo "  │  System is clean. NFTBan can operate without conflicts.  │"
        echo "  └──────────────────────────────────────────────────────────┘"
    fi
    echo ""

    # Show registry info as reference (smaller, informational)
    local expected_conflicts
    expected_conflicts=$(nftban_get_panel_conflicts "$panel" "$distro")
    echo "  Registry (known conflicts for $panel on $distro):"
    echo "    $expected_conflicts"
    echo ""

    # Fix if requested
    if [[ "$fix_mode" == true ]]; then
        echo ""
        if [[ "$auto_yes" == true ]]; then
            nftban_remove_conflicts --yes --panel "$panel"
        else
            nftban_remove_conflicts --panel "$panel"
        fi
    fi

    # Return based on actual conflicts found
    if [[ "$has_conflicts" == true ]]; then
        return 1
    fi
    return 0
}

# =============================================================================
# COMMAND: config
# =============================================================================

nftban_health_cmd_config() {
    # Show enabled modules and their config status
    # Usage: nftban health config [--verbose]
    # Shows: Module enabled/disabled, config files, reload needed

    local verbose=false
    for arg in "$@"; do
        [[ "$arg" == "--verbose" || "$arg" == "-v" ]] && verbose=true
    done

    local config_dir="${NFTBAN_CONFIG_DIR:-/etc/nftban}"
    local track_dir="/run/nftban/config-loaded"

    echo ""
    echo "┌────────────────────────────────────────────────────────────┐"
    echo "│           NFTBan Configuration Status                     │"
    echo "└────────────────────────────────────────────────────────────┘"
    echo ""

    # Protection modules and their status
    # shellcheck disable=SC2034  # modules used for reference/future expansion
    declare -A modules=(
        ["portscan"]="Port Scan Detection"
        ["ddos"]="DDoS Protection"
        ["login"]="Login Monitor"
        ["geoban"]="GeoIP Blocking"
        ["feeds"]="Threat Feeds"
        ["suricata"]="Suricata IDS"
    )

    declare -A module_services=(
        ["portscan"]="nftband"
        ["ddos"]="nftband"
        ["login"]="nftban-login-monitor"
        ["geoban"]="nftband"
        ["feeds"]="timer"
        ["suricata"]="nftban-suricata"
    )

    local needs_reload=false

    printf "%-12s %-8s %-18s %-20s\n" "MODULE" "STATUS" "SERVICE" "CONFIG"
    echo "────────────────────────────────────────────────────────────"

    for module in portscan ddos login geoban feeds suricata; do
        local enabled="OFF"
        local service="${module_services[$module]}"
        local config_status="-"
        local conf_file=""

        # Check if module is enabled
        # Look for ENABLED=true in module config or check service status
        if [[ -f "$config_dir/conf.d/$module/main.conf" ]]; then
            conf_file="$config_dir/conf.d/$module/main.conf"
            if grep -qE "^[A-Z_]*ENABLED.*=.*[\"']?true" "$conf_file" 2>/dev/null || \
               grep -qE "^[A-Z_]*ENABLED.*=.*[\"']?YES" "$conf_file" 2>/dev/null; then
                enabled="ON"
            fi
        elif [[ -f "$config_dir/conf.d/${module}.conf" ]]; then
            conf_file="$config_dir/conf.d/${module}.conf"
            enabled="ON"  # Presence means enabled for simple configs
        fi

        # Check local override
        local local_conf="${conf_file}.local"
        [[ -f "$config_dir/conf.d/$module/main.conf.local" ]] && local_conf="$config_dir/conf.d/$module/main.conf.local"

        # Service status
        local svc_status="stopped"
        if [[ "$service" == "timer" ]]; then
            svc_status="timer"
        elif systemctl is-active "${service}.service" &>/dev/null; then
            svc_status="running"
        fi

        # Config status (only if service running)
        if [[ "$svc_status" == "running" && -f "$track_dir/.timestamp" ]]; then
            # Check if local config changed since load
            if [[ -f "$local_conf" ]]; then
                local curr_hash loaded_hash hash_file
                curr_hash=$(sha256sum "$local_conf" 2>/dev/null | cut -d' ' -f1)
                hash_file="$track_dir/$(basename "$local_conf").sha256"
                loaded_hash=$(cat "$hash_file" 2>/dev/null || echo "none")
                if [[ "$curr_hash" != "$loaded_hash" && "$loaded_hash" != "none" ]]; then
                    config_status="CHANGED"
                    needs_reload=true
                else
                    config_status="current"
                fi
            else
                config_status="default"
            fi
        elif [[ "$svc_status" == "running" ]]; then
            config_status="not tracked"
        fi

        # Format output
        local status_icon="○"
        [[ "$enabled" == "ON" ]] && status_icon="●"

        printf "%-12s %-8s %-18s %-20s\n" "$module" "$status_icon $enabled" "$svc_status" "$config_status"

        # Verbose: show config files
        if [[ "$verbose" == true && -n "$conf_file" ]]; then
            echo "             └─ $conf_file"
            [[ -f "$local_conf" ]] && echo "             └─ $local_conf (override)"
        fi
    done

    echo ""

    # Show last reload time
    if [[ -f "$track_dir/.timestamp" ]]; then
        local ts
        ts=$(cat "$track_dir/.timestamp" 2>/dev/null)
        echo "Last config reload: $(date -d "@$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")"
    else
        echo "Last config reload: Never (using startup config)"
    fi

    echo ""

    # Show reload hint if needed
    if [[ "$needs_reload" == true ]]; then
        echo "┌────────────────────────────────────────────────────────────┐"
        echo "│  ⚠️  Config changed on disk. Run: nftban config reload     │"
        echo "└────────────────────────────────────────────────────────────┘"
    else
        echo "✓ All running services have current config"
    fi
    echo ""
}

# =============================================================================
# COMMAND: rbl
# =============================================================================

nftban_health_cmd_rbl() {
    # Check RBL (Real-time Blocklist) system health
    # Args: none
    # Checks: enabled status, timer, last check, cache directory

    local config_dir="${NFTBAN_CONFIG_DIR:-/etc/nftban}"
    local rbl_config="$config_dir/conf.d/rbl/main.conf"
    local rbl_cache_dir="${NFTBAN_LOG_DIR:-/var/log/nftban}/rbl"
    local last_check_file="$rbl_cache_dir/last_check"

    # Status tracking
    local overall_status="OK"
    local status_color="\033[32m"  # Green

    # Check results
    local rbl_enabled="NO"
    local timer_active="NO"
    local last_check_status="N/A"
    local last_check_time=""
    local cache_dir_status="missing"

    echo ""
    echo "RBL Health Check"
    echo "─────────────────────────────────────────"

    # 1. Check RBL enabled status from main.conf
    if [[ -f "$rbl_config" ]]; then
        if grep -qE "^RBL_ENABLED.*=.*[\"']?(true|yes|1|YES|TRUE)" "$rbl_config" 2>/dev/null; then
            rbl_enabled="YES"
        fi
    fi

    # 2. Check timer status
    if systemctl is-active --quiet nftban-rbl-check.timer 2>/dev/null; then
        timer_active="YES"
    elif systemctl is-enabled --quiet nftban-rbl-check.timer 2>/dev/null; then
        timer_active="ENABLED (not running)"
        if [[ "$overall_status" == "OK" ]]; then
            overall_status="WARNING"
            status_color="\033[33m"  # Yellow
        fi
    else
        timer_active="NO"
        if [[ "$rbl_enabled" == "YES" ]]; then
            # RBL enabled but timer not active = warning
            if [[ "$overall_status" == "OK" ]]; then
                overall_status="WARNING"
                status_color="\033[33m"  # Yellow
            fi
        fi
    fi

    # 3. Check last check timestamp
    if [[ -f "$last_check_file" ]]; then
        local last_ts current_ts age_seconds age_hours
        last_ts=$(cat "$last_check_file" 2>/dev/null | head -1)

        # Handle both epoch timestamp and ISO date formats
        if [[ "$last_ts" =~ ^[0-9]+$ ]]; then
            # Epoch timestamp
            current_ts=$(date +%s)
            age_seconds=$((current_ts - last_ts))
        else
            # Try to parse as date string
            last_ts=$(date -d "$last_ts" +%s 2>/dev/null || echo "0")
            current_ts=$(date +%s)
            age_seconds=$((current_ts - last_ts))
        fi

        age_hours=$((age_seconds / 3600))

        if [[ $age_hours -lt 1 ]]; then
            local age_minutes=$((age_seconds / 60))
            last_check_time="${age_minutes} minutes ago"
        elif [[ $age_hours -lt 24 ]]; then
            last_check_time="${age_hours} hours ago"
        else
            local age_days=$((age_hours / 24))
            last_check_time="${age_days} days ago"
        fi

        # Check if within 48 hours (172800 seconds)
        if [[ $age_seconds -le 172800 ]]; then
            last_check_status="$last_check_time (OK)"
        else
            last_check_status="$last_check_time (STALE)"
            if [[ "$rbl_enabled" == "YES" ]]; then
                overall_status="WARNING"
                status_color="\033[33m"  # Yellow
            fi
        fi
    else
        last_check_status="Never"
        if [[ "$rbl_enabled" == "YES" ]]; then
            overall_status="WARNING"
            status_color="\033[33m"  # Yellow
        fi
    fi

    # 4. Check cache directory
    if [[ -d "$rbl_cache_dir" ]]; then
        if [[ -w "$rbl_cache_dir" ]]; then
            cache_dir_status="$rbl_cache_dir (writable)"
        else
            cache_dir_status="$rbl_cache_dir (not writable)"
            overall_status="ERROR"
            status_color="\033[31m"  # Red
        fi
    else
        cache_dir_status="$rbl_cache_dir (missing)"
        if [[ "$rbl_enabled" == "YES" ]]; then
            overall_status="ERROR"
            status_color="\033[31m"  # Red
        fi
    fi

    # If RBL is disabled, overall status should still be OK unless there's an error
    if [[ "$rbl_enabled" == "NO" && "$overall_status" == "WARNING" ]]; then
        # Reset to OK if RBL is disabled - warnings only matter when enabled
        overall_status="OK"
        status_color="\033[32m"  # Green
    fi

    # Display results
    printf "  RBL Enabled:     %s\n" "$rbl_enabled"
    printf "  Timer Active:    %s\n" "$timer_active"
    printf "  Last Check:      %s\n" "$last_check_status"
    printf "  Cache Dir:       %s\n" "$cache_dir_status"
    echo ""
    printf "  Status: %b%s%b\n" "$status_color" "$overall_status" "\033[0m"
    echo ""

    # Return appropriate exit code
    case "$overall_status" in
        OK) return 0 ;;
        WARNING) return 1 ;;
        ERROR) return 2 ;;
        *) return 1 ;;
    esac
}

# =============================================================================
# COMMAND: posture
# =============================================================================

nftban_health_cmd_posture() {
    # Check security posture (low noise, limited scope - NOT audit replacement)
    # Args: none
    # Checks: SSH config, sudoers basics, systemd hardening, config integrity

    echo ""
    echo "Security Posture Check"
    echo "─────────────────────────────────────────"
    echo "  (Low noise, limited scope - not an audit replacement)"
    echo ""

    local warnings=0
    local issues=0
    local total_checks=0

    # Load posture collection if available
    if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_report_data.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/lib/nftban_report_data.sh" 2>/dev/null || true
    fi

    # ───────────────────────────────────────────────────────────────────────
    # 1. SSH CONFIGURATION BASICS
    # ───────────────────────────────────────────────────────────────────────
    echo "SSH Configuration"
    echo "  ─────────────────────────────────────"

    local ssh_config="/etc/ssh/sshd_config"
    if [[ -f "$ssh_config" ]]; then
        # v1.19.20 FIX
        ((total_checks++)) || true
        # PasswordAuthentication
        local pass_auth
        pass_auth=$(grep -E "^PasswordAuthentication" "$ssh_config" 2>/dev/null | awk '{print $2}' || echo "yes")
        if [[ "$pass_auth" == "no" ]]; then
            printf "  %-28s ✅ Disabled (key-only)\n" "PasswordAuthentication"
        else
            printf "  %-28s ⚠️  Enabled (consider disabling)\n" "PasswordAuthentication"
            # v1.19.20 FIX
            ((warnings++)) || true
        fi

        # v1.19.20 FIX
        ((total_checks++)) || true
        # PermitRootLogin
        local root_login
        root_login=$(grep -E "^PermitRootLogin" "$ssh_config" 2>/dev/null | awk '{print $2}' || echo "yes")
        if [[ "$root_login" == "no" || "$root_login" == "prohibit-password" ]]; then
            printf "  %-28s ✅ %s\n" "PermitRootLogin" "$root_login"
        else
            printf "  %-28s ⚠️  %s (consider 'no' or 'prohibit-password')\n" "PermitRootLogin" "$root_login"
            # v1.19.20 FIX
            ((warnings++)) || true
        fi

        # v1.19.20 FIX
        ((total_checks++)) || true
        # X11Forwarding
        local x11_fwd
        x11_fwd=$(grep -E "^X11Forwarding" "$ssh_config" 2>/dev/null | awk '{print $2}' || echo "yes")
        if [[ "$x11_fwd" == "no" ]]; then
            printf "  %-28s ✅ Disabled\n" "X11Forwarding"
        else
            printf "  %-28s ℹ️  Enabled (minor risk)\n" "X11Forwarding"
        fi
    else
        printf "  %-28s ⚠️  Config not found\n" "sshd_config"
        # v1.19.20 FIX
        ((warnings++)) || true
    fi
    echo ""

    # ───────────────────────────────────────────────────────────────────────
    # 2. SUDOERS BASICS
    # ───────────────────────────────────────────────────────────────────────
    echo "Sudoers Configuration"
    echo "  ─────────────────────────────────────"

    local sudoers_dir="/etc/sudoers.d"
    if [[ -d "$sudoers_dir" ]]; then
        # v1.19.20 FIX
        ((total_checks++)) || true
        local risky_count=0
        local nftban_sudoers_ok=false

        for sfile in "$sudoers_dir"/*; do
            [[ -f "$sfile" ]] || continue
            local sname
            sname=$(basename "$sfile")

            # NFTBan's own sudoers file is expected
            if [[ "$sname" == "nftban" ]]; then
                nftban_sudoers_ok=true
                continue
            fi

            # Skip backup files
            [[ "$sname" == *~ ]] && continue
            [[ "$sname" == *.bak ]] && continue

            # Flag ALL NOPASSWD (risky)
            if grep -qE "NOPASSWD:\s*ALL" "$sfile" 2>/dev/null; then
                printf "  %-28s ⚠️  %s has ALL NOPASSWD\n" "Sudoers" "$sname"
                # v1.19.20 FIX
                ((risky_count++)) || true
            fi
        done

        if [[ $risky_count -eq 0 ]]; then
            printf "  %-28s ✅ No risky NOPASSWD patterns\n" "Sudoers"
        else
            ((warnings += risky_count))
        fi

        if [[ "$nftban_sudoers_ok" == true ]]; then
            printf "  %-28s ✅ Present (scoped)\n" "NFTBan sudoers"
        fi
    else
        printf "  %-28s ℹ️  /etc/sudoers.d not found\n" "Sudoers"
    fi
    echo ""

    # ───────────────────────────────────────────────────────────────────────
    # 3. SYSTEMD SERVICE HARDENING
    # ───────────────────────────────────────────────────────────────────────
    echo "Systemd Service Hardening"
    echo "  ─────────────────────────────────────"

    local hardening_checks=("NoNewPrivileges" "PrivateTmp" "ProtectSystem")
    local systemd_found=false

    for unit_dir in /etc/systemd/system /usr/lib/systemd/system /lib/systemd/system; do
        [[ -d "$unit_dir" ]] || continue
        for svc in "$unit_dir"/nftban*.service; do
            [[ -f "$svc" ]] || continue
            systemd_found=true
            local svc_name
            svc_name=$(basename "$svc" .service)
            local hardened=0
            local total=${#hardening_checks[@]}

            for check in "${hardening_checks[@]}"; do
                if grep -qE "^${check}=(true|yes|strict|full)" "$svc" 2>/dev/null; then
                    # v1.19.20 FIX
                    ((hardened++)) || true
                fi
            done

            # v1.19.20 FIX
            ((total_checks++)) || true
            if [[ $hardened -eq $total ]]; then
                printf "  %-28s ✅ %d/%d hardening options\n" "$svc_name" "$hardened" "$total"
            elif [[ $hardened -gt 0 ]]; then
                printf "  %-28s ℹ️  %d/%d hardening options\n" "$svc_name" "$hardened" "$total"
            else
                printf "  %-28s ⚠️  No hardening options\n" "$svc_name"
                # v1.19.20 FIX
                ((warnings++)) || true
            fi
        done
        [[ "$systemd_found" == true ]] && break
    done

    [[ "$systemd_found" != true ]] && printf "  %-28s ℹ️  No NFTBan services found\n" "Services"
    echo ""

    # ───────────────────────────────────────────────────────────────────────
    # 4. CONFIG INTEGRITY
    # ───────────────────────────────────────────────────────────────────────
    echo "Config Integrity"
    echo "  ─────────────────────────────────────"

    local conf_dir="${NFTBAN_CONFIG_DIR:-/etc/nftban}"
    local integrity_file="${conf_dir}/.config_checksums"

    # v1.19.20 FIX
    ((total_checks++)) || true
    if [[ -f "$integrity_file" ]]; then
        local drift_count=0
        local checked_count=0

        while IFS=' ' read -r stored_hash fpath; do
            [[ -z "$fpath" ]] && continue
            [[ "$fpath" == "#"* ]] && continue
            [[ -f "$fpath" ]] || continue
            # v1.19.20 FIX
            ((checked_count++)) || true
            local current_hash
            current_hash=$(sha256sum "$fpath" 2>/dev/null | cut -d' ' -f1 || echo "")
            if [[ -n "$current_hash" && "$current_hash" != "$stored_hash" ]]; then
                # v1.19.20 FIX
                ((drift_count++)) || true
            fi
        done < "$integrity_file"

        if [[ $drift_count -eq 0 ]]; then
            printf "  %-28s ✅ %d files verified\n" "Config integrity" "$checked_count"
        else
            printf "  %-28s ⚠️  %d file(s) modified since install\n" "Config integrity" "$drift_count"
            # v1.19.20 FIX
            ((warnings++)) || true
        fi
    else
        printf "  %-28s ℹ️  Checksums not available\n" "Config integrity"
    fi
    echo ""

    # ───────────────────────────────────────────────────────────────────────
    # SUMMARY
    # ───────────────────────────────────────────────────────────────────────
    echo "─────────────────────────────────────────"
    if [[ $warnings -eq 0 && $issues -eq 0 ]]; then
        echo "  Status: ✅ OK ($total_checks checks passed)"
        echo ""
        echo "  Note: This is a basic posture check, not a security audit."
        echo "  For comprehensive auditing, use dedicated tools like:"
        echo "    - lynis audit system"
        echo "    - oscap xccdf eval"
        return 0
    elif [[ $issues -eq 0 ]]; then
        echo "  Status: ⚠️  $warnings advisory finding(s)"
        echo ""
        echo "  These are recommendations, not critical issues."
        echo "  Review and address as appropriate for your environment."
        return 1
    else
        echo "  Status: ❌ $issues issue(s), $warnings warning(s)"
        return 2
    fi
}

# =============================================================================
# COMMAND: gui
# =============================================================================

nftban_health_cmd_gui() {
    # Validate GOTH GUI components against ui-registry.json
    # Args: [--json]
    # Usage: nftban health gui [--json]

    local json_mode=""
    for arg in "$@"; do
        [[ "$arg" == "--json" ]] && json_mode="--json"
    done

    echo "NFTBan GUI Registry Validation"
    echo "==============================="
    echo ""

    # Find the GUI check script
    local gui_check_script="${NFTBAN_LIB_DIR}/health/check_gui.sh"

    # Also check in development location
    local dev_check_script
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    dev_check_script="${script_dir}/../health/check_gui.sh"

    if [[ -f "$gui_check_script" ]]; then
        bash "$gui_check_script" $json_mode
        return $?
    elif [[ -f "$dev_check_script" ]]; then
        bash "$dev_check_script" $json_mode
        return $?
    else
        echo "❌ GUI check script not found"
        echo "  Expected: $gui_check_script"
        return 1
    fi
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_health_cmd_conflicts
export -f nftban_health_cmd_config
export -f nftban_health_cmd_rbl
export -f nftban_health_cmd_posture
export -f nftban_health_cmd_gui
