#!/usr/bin/env bash
# =============================================================================
# NFTBan - Health Check CLI Command - Analysis Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Analysis health checks: conflicts, config, rbl, posture
#
# meta:name="cmd_health_analysis"
# meta:type="cli"
# meta:header="Health Check Analysis Module"
# meta:version="1.48.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Analysis health checks: conflicts, config, rbl, posture"
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
            source "${NFTBAN_LIB_DIR}/core/nftban_firewall_conflicts.sh" || return 1
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

    # CSF — v1.229.0 R0 SITE 2. Observation must not execute vendor binaries.
    # REMOVED the `csf -s ... | grep -q` probe: `csf -s` STARTS CSF (measured
    # 0 -> 129 kernel rules). CORRECTED the activity test to csf.service OR
    # lfd.service — `lfd` alone reported an enforcing CSF as "disabled".
    # _nftban_csf_activity is defined in nftban_firewall_conflicts.sh, which
    # this command sources above before any conflict rendering.
    local csf_activity
    csf_activity="$(_nftban_csf_activity)"

    if [[ ! -f /etc/csf/csf.conf ]] && ! command -v csf &>/dev/null; then
        echo "│  ✓ CSF           not installed                            │"
    elif [[ "$csf_activity" == "cannot-verify" ]]; then
        # Neither ACTIVE nor DISABLED may be asserted. has_conflicts is left
        # unchanged — this line IS the signal; it must not manufacture a clean
        # verdict, nor a conflict that was never observed.
        echo "│  ⚠ CSF           cannot-verify (systemd unavailable)      │"
    elif [[ "$csf_activity" == "active" ]] && [[ -f /etc/csf/csf.conf ]]; then
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

    # v1.48.0: Ghost table detection (live nft state)
    local ghost_found=false
    if command -v nft &>/dev/null; then
        # `|| true` swallowed the read failure and left live_tables empty, and
        # an empty list walks straight into the "sole authority" branch below.
        # The strongest claim this section can make was therefore produced by
        # the case where nothing was read at all. Track readability explicitly.
        local live_tables tables_readable=true
        live_tables=$(nft list tables 2>/dev/null) || tables_readable=false
        # rc=0 with no output is not an empty table list: nft lists what it can
        # see, and this host is running NFTBan's own tables.
        [[ -z "${live_tables//[[:space:]]/}" ]] && tables_readable=false
        echo "┌────────────────────────────────────────────────────────────┐"
        echo "│ GHOST NFT TABLES (live state)                              │"
        echo "├────────────────────────────────────────────────────────────┤"
        local ghost_count=0
        while IFS= read -r tline; do
            [[ -z "$tline" ]] && continue
            local tspec="${tline#table }"
            # Skip NFTBan-owned tables (nftban + SYNPROXY raw tables)
            case "$tspec" in
                "ip nftban"|"ip6 nftban"|"ip raw"|"ip6 raw") continue ;;
            esac
            printf "│  ✗ %-56s│\n" "$tspec"
            ghost_found=true
            ((ghost_count++)) || true
        done <<< "$live_tables"
        if [[ "$tables_readable" != "true" ]]; then
            printf "│  %-58s│\n" "? Cannot read live nft tables — ghost tables NOT checked"
            printf "│  %-58s│\n" "  (this is not evidence of sole authority)"
        elif [[ "$ghost_found" == "false" ]]; then
            echo "│  ✓ No ghost tables — NFTBan has sole authority             │"
        fi
        echo "└────────────────────────────────────────────────────────────┘"
        echo ""
    fi

    # Show verdict
    if [[ "$has_conflicts" == true ]] || [[ "$ghost_found" == true ]]; then
        echo "  ┌──────────────────────────────────────────────────────────┐"
        echo "  │  CONFLICTS DETECTED                                      │"
        echo "  │                                                          │"
        if [[ "$has_conflicts" == true ]]; then
            echo "  │  Conflicting firewalls may interfere with NFTBan.        │"
        fi
        if [[ "$ghost_found" == true ]]; then
            echo "  │  Ghost nft tables found (left by disabled firewalls).    │"
        fi
        echo "  │  Run: nftban health conflicts --fix                      │"
        echo "  └──────────────────────────────────────────────────────────┘"
    else
        echo "  ┌──────────────────────────────────────────────────────────┐"
        echo "  │  NO CONFLICTS DETECTED                                   │"
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
        # v1.48.0: Always run ghost cleanup on --fix (idempotent)
        if declare -f nftban_cleanup_ghost_tables &>/dev/null; then
            echo ""
            echo "Cleaning ghost nftables tables..."
            nftban_cleanup_ghost_tables
            echo ""
            echo "Validating hook authority..."
            nftban_validate_hook_authority || true
        fi
    fi

    # Return based on actual conflicts found
    if [[ "$has_conflicts" == true ]] || [[ "$ghost_found" == true ]]; then
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
        [[ "$arg" == "--verbose" || "$arg" == "-v" ]] && verbose=true || true
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
            [[ -f "$local_conf" ]] && echo "             └─ $local_conf (override)" || true
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
    # v1.206 (TODO-1): the AUTHORITATIVE RBL state store is the cache dir written
    # by nftban_rbl_update_state (/var/cache/nftban/rbl), NOT /var/log. The old
    # /var/log path was a key/state-path drift → health read a non-existent store
    # and could report PROTECTED while the writer recorded degraded/listed.
    local rbl_cache_dir="${NFTBAN_RBL_CACHE_DIR:-${NFTBAN_CACHE_DIR:-/var/cache/nftban}/rbl}"
    local last_check_file="$rbl_cache_dir/last_check"
    local rbl_state_file="$rbl_cache_dir/state.dat"

    # Status tracking
    local overall_status="PROTECTED"
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
        if [[ "$overall_status" == "PROTECTED" ]]; then
            overall_status="WARNING"
            status_color="\033[33m"  # Yellow
        fi
    else
        timer_active="NO"
        if [[ "$rbl_enabled" == "YES" ]]; then
            # RBL enabled but timer not active = warning
            if [[ "$overall_status" == "PROTECTED" ]]; then
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

    # 5. v1.206 (TODO-1): read the AUTHORITATIVE state store and surface degraded/
    # blind RBL results. A degraded entry (resolver-blocked/timeout/error/skipped/
    # unsupported) means reputation is UNKNOWN — posture must NOT read "fully
    # protected" while RBL is blind.
    local rbl_degraded_ips=0 rbl_listed_ips=0
    if [[ -f "$rbl_state_file" ]]; then
        rbl_degraded_ips=$(grep -c '=degraded|' "$rbl_state_file" 2>/dev/null || echo 0)
        rbl_listed_ips=$(grep -c '=listed|' "$rbl_state_file" 2>/dev/null || echo 0)
    fi
    if [[ "$rbl_enabled" == "YES" ]] && [[ "${rbl_degraded_ips:-0}" -gt 0 ]] \
       && [[ "$overall_status" == "PROTECTED" ]]; then
        overall_status="DEGRADED"
        status_color="\033[33m"  # Yellow — RBL blind, reputation not fully verified
    fi

    # If RBL is disabled, overall status should still be OK unless there's an error
    if [[ "$rbl_enabled" == "NO" && "$overall_status" == "WARNING" ]]; then
        # Reset to OK if RBL is disabled - warnings only matter when enabled
        overall_status="PROTECTED"
        status_color="\033[32m"  # Green
    fi

    # Display results
    printf "  RBL Enabled:     %s\n" "$rbl_enabled"
    printf "  Timer Active:    %s\n" "$timer_active"
    printf "  Last Check:      %s\n" "$last_check_status"
    printf "  Cache Dir:       %s\n" "$cache_dir_status"
    printf "  RBL State:       %s degraded / %s listed (authoritative: %s)\n" \
        "${rbl_degraded_ips:-0}" "${rbl_listed_ips:-0}" "$rbl_state_file"
    [[ "${rbl_degraded_ips:-0}" -gt 0 ]] && \
        printf "  Note: RBL coverage DEGRADED — reputation not fully verified for %s IP(s); not 'fully protected'.\n" "${rbl_degraded_ips}"
    echo ""
    printf "  Status: %b%s%b\n" "$status_color" "$overall_status" "\033[0m"
    echo ""

    # Return appropriate exit code
    case "$overall_status" in
        OK|PROTECTED) return 0 ;;
        DEGRADED|WARNING) return 1 ;;
        ERROR) return 2 ;;
        *) return 1 ;;
    esac
}

# v1.207 — BotScan health (reads the adaptive run-state; never reports 0-clean when
# input was not scanned). rc: 0=OK/DISABLED, 1=WARN/DEGRADED, 2=ERROR.
nftban_health_cmd_botscan() {
    # v1.208 — `nftban health botscan --history` summarizes the durable trend.
    case "${1:-}" in
        --history)
            if ! declare -F nftban_botscan_history >/dev/null 2>&1; then
                # shellcheck source=/dev/null
                source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_botscan_adaptive.sh" 2>/dev/null || true
            fi
            if declare -F nftban_botscan_history >/dev/null 2>&1; then
                echo ""; nftban_botscan_history; return 0
            fi
            echo "BotScan history unavailable (adaptive module not loaded)."; return 1
            ;;
    esac
    local rs="${NFTBAN_DATA_DIR:-/var/lib/nftban}/botscan/runstate.json"
    echo ""
    echo "BotScan Health"
    echo "─────────────────────────────────────────"
    if [[ ! -f "$rs" ]]; then
        # No run-state: either never enabled+run (recording-discipline), or first boot.
        local en="${BOTSCAN_ENABLED:-true}"
        if [[ "$en" != "true" ]]; then
            printf "  %-16s %s\n" "State:" "DISABLED_BY_CONFIG (not scanning; not 'clean')"
            return 0
        fi
        printf "  %-16s %s\n" "State:" "NO_RUN_YET (enabled; awaiting first scan)"
        return 1
    fi
    if ! command -v jq &>/dev/null; then printf "  %-16s %s\n" "State:" "(jq unavailable)"; return 1; fi
    local hs mode pr bl scan bans dur bh
    IFS=' ' read -r hs mode pr bl scan bans dur bh < <(jq -r '"\(.health_state//"?") \(.scan_mode//"?") \(.pressure_state//"?") \(.backlog_state//"?") \(.lines_scanned_total//0) \(.bans_emitted_total//0) \(.last_duration_sec//0) \(.last_budget_hit//0)"' "$rs" 2>/dev/null)
    printf "  %-16s %s\n" "Health:" "$hs"
    printf "  %-16s %s\n" "Scan mode:" "$mode"
    printf "  %-16s %s\n" "Host pressure:" "$pr"
    printf "  %-16s %s\n" "Backlog:" "$bl"
    printf "  %-16s scanned=%s bans=%s last=%ss budget_hit=%s\n" "Counters:" "$scan" "$bans" "$dur" "$bh"
    # v1.209.3 — disk-backed spool pressure (written by the collector each cycle).
    # backpressure=1 means the collector is throttling on the total-dir cap; surface
    # it and escalate to a non-clean return even when the scan health itself is OK.
    local _spool_degraded=0 _ss="${NFTBAN_DATA_DIR:-/var/lib/nftban}/botscan/spool.status"
    if [[ -r "$_ss" ]]; then
        local _sk _sv _sb=0 _scnt=0 _sbp=0 _spct=0 _sage=0
        while IFS='=' read -r _sk _sv; do case "$_sk" in
            total_bytes) _sb="$_sv" ;; file_count) _scnt="$_sv" ;;
            backpressure) _sbp="$_sv" ;; cap_pct) _spct="$_sv" ;; oldest_age_sec) _sage="$_sv" ;;
        esac; done < "$_ss"
        if [[ "${_sbp:-0}" == "1" ]]; then
            printf "  %-16s %s bytes / %s files / %s%% of cap  ⚠ BACKPRESSURE (collector throttled)\n" "Spool:" "${_sb:-0}" "${_scnt:-0}" "${_spct:-0}"
            _spool_degraded=1
        else
            printf "  %-16s %s bytes / %s files / %s%% of cap (oldest %ss)\n" "Spool:" "${_sb:-0}" "${_scnt:-0}" "${_spct:-0}" "${_sage:-0}"
        fi
    fi
    if declare -F nftban_botscan_advisory >/dev/null 2>&1; then echo ""; echo "  $(nftban_botscan_advisory)"; fi
    case "$hs" in
        OK_*|DISABLED_BY_CONFIG) [[ "$_spool_degraded" == "1" ]] && return 1; return 0 ;;
        ERROR_*) return 2 ;;
        *) return 1 ;;   # WARN_*/DEGRADED_* are visible non-clean states
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

    # v1.150 (15.5): resolve the EFFECTIVE sshd posture. Drop-in overrides live
    # in /etc/ssh/sshd_config.d/*.conf and can flip the main file's values.
    # Prefer `sshd -T` (authoritative merged config, root-only); otherwise merge
    # the main file with the drop-ins (last matching value wins, lexical order).
    # Case-insensitive directive match, matching sshd. Defaults to "yes" when a
    # directive is absent, preserving the prior conservative warning behaviour.
    _ssh_effective_directive() {
        local directive="$1" main_config="$2" value=""
        if [[ "${EUID:-$(id -u)}" -eq 0 ]] && command -v sshd >/dev/null 2>&1; then
            local teff
            teff=$(sshd -T 2>/dev/null | awk -v d="$directive" 'tolower($1)==d {print $2; exit}')
            if [[ -n "$teff" ]]; then
                echo "$teff"
                return 0
            fi
        fi
        local f match
        for f in "$main_config" /etc/ssh/sshd_config.d/*.conf; do
            [[ -f "$f" ]] || continue
            match=$(grep -iE "^[[:space:]]*${directive}[[:space:]]" "$f" 2>/dev/null | awk '{print $2}' | tail -n1)
            [[ -n "$match" ]] && value="$match"
        done
        if [[ -n "$value" ]]; then echo "$value"; else echo "yes"; fi
    }

    local ssh_config="/etc/ssh/sshd_config"
    if [[ -f "$ssh_config" ]]; then
        # v1.19.20 FIX
        ((total_checks++)) || true
        # PasswordAuthentication
        local pass_auth
        pass_auth=$(_ssh_effective_directive "passwordauthentication" "$ssh_config")
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
        root_login=$(_ssh_effective_directive "permitrootlogin" "$ssh_config")
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
        x11_fwd=$(_ssh_effective_directive "x11forwarding" "$ssh_config")
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
        [[ "$systemd_found" == true ]] && break || true
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
    # 5. MAC POSTURE (AppArmor / SELinux) — v1.158
    # ───────────────────────────────────────────────────────────────────────
    # Read-only, non-root-graceful, distro-aware. WARN is advisory only (feeds
    # `warnings`, never `issues`) so health does not fail solely because a MAC
    # profile is missing/not-enforcing. The detection helper lives in
    # nftban_report_data.sh (sourced above when available).
    echo "Mandatory Access Control (MAC)"
    echo "  ─────────────────────────────────────"
    if declare -f _nftban_mac_posture >/dev/null 2>&1; then
        ((total_checks++)) || true
        local _mac_line _mac_system _mac_verdict _mac_mode _mac_summary _mac_detail
        _mac_line=$(_nftban_mac_posture 2>/dev/null) || _mac_line="none|INFO|n/a|MAC not applicable|"
        IFS='|' read -r _mac_system _mac_verdict _mac_mode _mac_summary _mac_detail <<<"$_mac_line"
        case "$_mac_verdict" in
            PASS)
                printf "  %-28s ✅ %s\n" "MAC profile" "$_mac_summary"
                [[ -n "$_mac_detail" ]] && printf "      %s\n" "$_mac_detail"
                ;;
            WARN)
                printf "  %-28s ⚠️  %s\n" "MAC profile" "$_mac_summary"
                [[ -n "$_mac_detail" ]] && printf "      FIX: %s\n" "$_mac_detail"
                ((warnings++)) || true
                ;;
            *)  # INFO / N/A — not applicable on this host; never a warning
                printf "  %-28s ℹ️  %s\n" "MAC profile" "$_mac_summary"
                [[ -n "$_mac_detail" ]] && printf "      %s\n" "$_mac_detail"
                ;;
        esac
    else
        printf "  %-28s ℹ️  %s\n" "MAC profile" "MAC detection unavailable"
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
# HTTP BOT GUARD HEALTH CHECK (v1.21.0)
# =============================================================================

nftban_health_cmd_botguard() {
    # Standalone botguard health check (nftban health botguard)
    local config_dir="${NFTBAN_CONFIG_DIR:-/etc/nftban}"
    local botguard_conf="$config_dir/conf.d/botguard/main.conf"
    local allowed_conf="$config_dir/conf.d/botguard/allowed_crawlers.conf"
    local denied_conf="$config_dir/conf.d/botguard/denied_crawlers.conf"
    local botguard_data="${NFTBAN_DATA_DIR:-/var/lib/nftban}/botguard"
    local botguard_log="${NFTBAN_LOG_DIR:-/var/log/nftban}/botguard"

    local issues=0
    local warnings=0

    echo "=== HTTP Bot Guard Health Check ==="
    echo ""

    # Config file
    if [[ -f "$botguard_conf" ]]; then
        echo "  Config:              ✅ $botguard_conf"
    else
        echo "  Config:              ❌ Missing: $botguard_conf"
        ((issues++)) || true
    fi

    # Allowed crawlers
    if [[ -f "$allowed_conf" ]]; then
        local count
        count=$(grep -c -v '^#\|^$' "$allowed_conf" 2>/dev/null || true)
        count=${count:-0}
        echo "  Allowed crawlers:    ✅ $allowed_conf ($count entries)"
    else
        echo "  Allowed crawlers:    ⚠️  Missing: $allowed_conf"
        ((warnings++)) || true
    fi

    # Denied crawlers
    if [[ -f "$denied_conf" ]]; then
        local count
        count=$(grep -c -v '^#\|^$' "$denied_conf" 2>/dev/null || true)
        count=${count:-0}
        echo "  Denied crawlers:     ✅ $denied_conf ($count entries)"
    else
        echo "  Denied crawlers:     ⚠️  Missing: $denied_conf"
        ((warnings++)) || true
    fi

    # Data directory
    if [[ -d "$botguard_data" ]]; then
        local owner
        owner=$(stat -c '%U:%G' "$botguard_data" 2>/dev/null || echo "unknown")
        local mode
        mode=$(stat -c '%a' "$botguard_data" 2>/dev/null || echo "unknown")
        if [[ "$owner" == "nftban:nftban" && "$mode" == "750" ]]; then
            echo "  Data dir:            ✅ $botguard_data ($owner $mode)"
        else
            echo "  Data dir:            ⚠️  $botguard_data (owner=$owner mode=$mode, expected nftban:nftban 750)"
            echo "                       FIX: chown nftban:nftban $botguard_data && chmod 750 $botguard_data"
            ((warnings++)) || true
        fi
    else
        echo "  Data dir:            ❌ Missing: $botguard_data"
        echo "                       FIX: mkdir -p $botguard_data && chown nftban:nftban $botguard_data && chmod 750 $botguard_data"
        ((issues++)) || true
    fi

    # Log directory
    if [[ -d "$botguard_log" ]]; then
        local owner
        owner=$(stat -c '%U:%G' "$botguard_log" 2>/dev/null || echo "unknown")
        local mode
        mode=$(stat -c '%a' "$botguard_log" 2>/dev/null || echo "unknown")
        if [[ "$owner" == "nftban:nftban" && "$mode" == "750" ]]; then
            echo "  Log dir:             ✅ $botguard_log ($owner $mode)"
        else
            echo "  Log dir:             ⚠️  $botguard_log (owner=$owner mode=$mode, expected nftban:nftban 750)"
            echo "                       FIX: chown nftban:nftban $botguard_log && chmod 750 $botguard_log"
            ((warnings++)) || true
        fi
    else
        echo "  Log dir:             ❌ Missing: $botguard_log"
        echo "                       FIX: mkdir -p $botguard_log && chown nftban:nftban $botguard_log && chmod 750 $botguard_log"
        ((issues++)) || true
    fi

    # Log files
    if [[ -f "$botguard_log/botguard.log" ]]; then
        echo "  Log file:            ✅ $botguard_log/botguard.log"
    else
        echo "  Log file:            ⚠️  Not yet created (starts on first daemon run)"
        ((warnings++)) || true
    fi

    echo ""

    # Enabled status
    local enabled="false"
    local local_conf="$config_dir/conf.d/botguard/main.conf.local"
    if [[ -f "$local_conf" ]]; then
        enabled=$(grep -m1 "^HTTP_BOTGUARD_ENABLED=" "$local_conf" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || echo "")
    fi
    if [[ -z "$enabled" && -f "$botguard_conf" ]]; then
        enabled=$(grep -m1 "^HTTP_BOTGUARD_ENABLED=" "$botguard_conf" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || echo "false")
    fi

    if [[ "$enabled" == "true" ]]; then
        echo "  Module status:       ✅ ENABLED"

        # Check nft sets when enabled
        if nft list set ip nftban http_bot_suspect &>/dev/null 2>&1; then
            echo "  IPv4 suspect set:    ✅ Present"
        else
            echo "  IPv4 suspect set:    ❌ Not found in nftables"
            echo "                       FIX: systemctl restart nftband"
            ((issues++)) || true
        fi

        if nft list set ip6 nftban http_bot_suspect6 &>/dev/null 2>&1; then
            echo "  IPv6 suspect set:    ✅ Present"
        else
            echo "  IPv6 suspect set:    ❌ Not found in nftables"
            echo "                       FIX: systemctl restart nftband"
            ((issues++)) || true
        fi

        # Check daemon running
        if systemctl is-active nftband &>/dev/null; then
            echo "  Daemon:              ✅ Running"
        else
            echo "  Daemon:              ❌ Not running"
            echo "                       FIX: systemctl start nftband"
            ((issues++)) || true
        fi
    else
        echo "  Module status:       ⚠️  DISABLED"
        echo "                       Enable: nftban botguard enable"
    fi

    # v1.191 8B inc6B2 — bounded TEMPORARY decision-cache diagnostic (read-only, aggregate, no
    # per-IP, no schema/install_state/counter impact). WARN only when ENABLED and the explain
    # path is unavailable/degraded; omitted entirely when DISABLED (never WARN while disabled).
    # An EMPTY temporary cache is NOT a warning (the probe still reports available). Durable
    # nft-set checks remain the authority — this never implies unprotected.
    if ! declare -f nftban_botguard_health_cache_diag >/dev/null 2>&1; then
        # shellcheck source=/dev/null
        [[ -f "${NFTBAN_LIB_DIR}/lib/nft_ipc.sh" ]] && source "${NFTBAN_LIB_DIR}/lib/nft_ipc.sh" 2>/dev/null || true
        # shellcheck source=/dev/null
        [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_botguard_explain.sh" ]] && source "${NFTBAN_LIB_DIR}/lib/nftban_botguard_explain.sh" 2>/dev/null || true
    fi
    if declare -f nftban_botguard_health_cache_diag >/dev/null 2>&1; then
        local _bg_diag
        _bg_diag=$(nftban_botguard_health_cache_diag "$enabled" 2>/dev/null || true)
        if [[ -n "$_bg_diag" ]]; then
            if [[ "$_bg_diag" == WARN:* ]]; then
                echo "  Temp cache diag:     ⚠️  ${_bg_diag#WARN: }"
                ((warnings++)) || true
            else
                echo "  Temp cache diag:     ✅ ${_bg_diag#INFO: }"
            fi
        fi
    fi

    echo ""

    # Summary
    if [[ $issues -gt 0 ]]; then
        echo "  Result: ❌ $issues error(s), $warnings warning(s)"
        return 2
    elif [[ $warnings -gt 0 ]]; then
        echo "  Result: ⚠️  $warnings warning(s)"
        return 1
    else
        echo "  Result: ✅ OK"
        return 0
    fi
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_health_cmd_conflicts
export -f nftban_health_cmd_config
export -f nftban_health_cmd_rbl
export -f nftban_health_cmd_botscan
export -f nftban_health_cmd_botguard
export -f nftban_health_cmd_posture
