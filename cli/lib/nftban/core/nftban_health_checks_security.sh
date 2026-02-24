#!/usr/bin/env bash
# shellcheck disable=SC1090  # Dynamic config paths, cannot follow
# =============================================================================
# NFTBan v1.0 - Health Check Security Functions
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Security-related health check functions (nftables, firewalls, polkit, etc.)
#
# meta:name="nftban_health_checks_security"
# meta:type="lib"
# meta:header="Health Check Security Functions"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Security health check functions for system verification"
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
[[ -n "${_NFTBAN_HEALTH_CHECKS_SECURITY_LOADED:-}" ]] && return 0
_NFTBAN_HEALTH_CHECKS_SECURITY_LOADED=1

# =============================================================================
# LOAD SHARED LIBRARIES (with graceful fallbacks)
# =============================================================================

_NFTBAN_LIBS_DIR="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib"

# Load timestamp library (provides nftban_timestamp_unix, nftban_timestamp)
if [[ -f "${_NFTBAN_LIBS_DIR}/nftban_timestamp.sh" ]]; then
    # shellcheck source=/dev/null
    source "${_NFTBAN_LIBS_DIR}/nftban_timestamp.sh" 2>/dev/null || true
fi

# Load file utilities library (provides nftban_file_mtime, nftban_file_age)
if [[ -f "${_NFTBAN_LIBS_DIR}/nftban_file_utils.sh" ]]; then
    # shellcheck source=/dev/null
    source "${_NFTBAN_LIBS_DIR}/nftban_file_utils.sh" 2>/dev/null || true
fi

# Load service control library (provides nftban_service_is_active, nftban_service_start)
if [[ -f "${_NFTBAN_LIBS_DIR}/nftban_service_control.sh" ]]; then
    # shellcheck source=/dev/null
    source "${_NFTBAN_LIBS_DIR}/nftban_service_control.sh" 2>/dev/null || true
fi

# =============================================================================
# FALLBACK FUNCTIONS (if libraries are not available)
# =============================================================================

# Fallback for nftban_timestamp_unix if library not loaded
if ! declare -f nftban_timestamp_unix &>/dev/null; then
    nftban_timestamp_unix() { date '+%s'; }
fi

# Fallback for nftban_timestamp if library not loaded
if ! declare -f nftban_timestamp &>/dev/null; then
    nftban_timestamp() { date '+%Y-%m-%d %H:%M:%S'; }
fi

# Fallback for nftban_service_is_active if library not loaded
if ! declare -f nftban_service_is_active &>/dev/null; then
    nftban_service_is_active() { systemctl is-active --quiet "$1" 2>/dev/null; }
fi

# Fallback for nftban_service_start if library not loaded
if ! declare -f nftban_service_start &>/dev/null; then
    nftban_service_start() { systemctl start "$1" 2>/dev/null; }
fi

# File permissions helper (not in file_utils library, so define locally)
# Usage: nftban_file_perms "/path/to/file"
# Returns: octal permissions (e.g., "644") or "000" if file not found
nftban_file_perms() {
    local filepath="$1"
    if [[ ! -e "$filepath" ]]; then
        echo "000"
        return 1
    fi
    # Try GNU stat first, then BSD stat
    stat -c '%a' "$filepath" 2>/dev/null || stat -f '%Lp' "$filepath" 2>/dev/null || echo "000"
}

# =============================================================================
# NFTABLES SECURITY CHECKS
# =============================================================================

nftban_health_check_nftables_security() {
    # Check for security vulnerabilities in nftables configuration
    # Specifically: CVE-2025-NFTBAN-001 (inet filter bypass)
    # Returns: 0=OK, 2=Critical Error

    local status=$HEALTH_OK
    local security_issues=()

    # Check for legacy inet filter table (CVE-2025-NFTBAN-001)
    if nft list table inet filter &>/dev/null 2>&1; then
        # Table exists - check if it has ACCEPT policy at priority 0
        local filter_policy
        filter_policy=$(nft list table inet filter 2>/dev/null | grep -E 'chain input.*priority 0.*policy accept' || true)

        if [[ -n "$filter_policy" ]]; then
            security_issues+=("CRITICAL: inet filter table with 'policy accept' at priority 0 bypasses nftban blocking (CVE-2025-NFTBAN-001)")
            security_issues+=("  └─ All banned IPs can still connect!")
            security_issues+=("  └─ FIX: nft delete table inet filter")
            status=$HEALTH_CRITICAL
        else
            # Table exists but not at priority 0 or doesn't have accept policy
            security_issues+=("WARNING: inet filter table exists but may not conflict")
            security_issues+=("  └─ Verify with: nft list table inet filter")
            status=$HEALTH_WARNING
        fi
    fi

    # Check nftban tables exist (v0.7.3: dual-table architecture)
    if ! nft list table ${NFTBAN_TABLE_IPV4} &>/dev/null 2>&1; then
        security_issues+=("ERROR: IPv4 table (${NFTBAN_TABLE_IPV4}) missing - firewall not active")
        status=$HEALTH_CRITICAL
    fi

    if ! nft list table ${NFTBAN_TABLE_IPV6} &>/dev/null 2>&1; then
        security_issues+=("WARNING: IPv6 table (${NFTBAN_TABLE_IPV6}) missing - IPv6 firewall not active")
        [[ $status -eq $HEALTH_OK ]] && status=$HEALTH_WARNING
    fi

    # Store results
    if [[ ${#security_issues[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["nftables_security"]="${security_issues[*]}"
        if [[ $status -eq $HEALTH_CRITICAL ]]; then
            NFTBAN_HEALTH_ERRORS+=("CRITICAL nftables security issue: ${security_issues[*]}")
        elif [[ $status -eq $HEALTH_WARNING ]]; then
            NFTBAN_HEALTH_WARNINGS+=("nftables security warning: ${security_issues[*]}")
        fi
    fi

    NFTBAN_HEALTH_RESULTS["nftables_security"]=$status
    return $status
}

nftban_health_check_conflicting_firewalls() {
    # Check for conflicting firewall services using comprehensive detection
    # Detects: firewalld, iptables, ufw, fail2ban, CSF, iptables-nft, cPHulk
    # Returns: 0=OK, 1=Warning, 2=Critical Error
    #
    # NOTE: cPHulk (cPanel) is treated as INFO only - it's designed to coexist

    local status=$HEALTH_OK

    # Source the comprehensive conflict detection library
    local conflict_lib="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_firewall_conflicts.sh"
    if [[ -f "$conflict_lib" ]]; then
        # shellcheck source=/dev/null
        source "$conflict_lib" 2>/dev/null || true
    fi

    # Check if detection functions are available
    if ! declare -f nftban_detect_all_conflicts &>/dev/null; then
        # Fallback to basic checks if library not available
        local firewall_conflicts=()

        # Basic firewalld check
        if command -v firewall-cmd &>/dev/null; then
            if nftban_service_is_active firewalld; then
                firewall_conflicts+=("ERROR: firewalld is ACTIVE")
                status=$HEALTH_CRITICAL
            fi
        fi

        # Basic iptables check
        if nftban_service_is_active iptables; then
            firewall_conflicts+=("ERROR: iptables service is ACTIVE")
            status=$HEALTH_CRITICAL
        fi

        # Basic ufw check
        if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
            firewall_conflicts+=("ERROR: ufw is ACTIVE")
            status=$HEALTH_CRITICAL
        fi

        if [[ ${#firewall_conflicts[@]} -gt 0 ]]; then
            NFTBAN_HEALTH_ISSUES["conflicting_firewalls"]="${firewall_conflicts[*]}"
            NFTBAN_HEALTH_ERRORS+=("Conflicting firewall(s): ${firewall_conflicts[*]}")
        fi

        NFTBAN_HEALTH_RESULTS["conflicting_firewalls"]=$status
        return $status
    fi

    # Use comprehensive detection
    nftban_detect_all_conflicts

    # Map severity to health status
    case $NFTBAN_FIREWALL_SEVERITY in
        0) status=$HEALTH_OK ;;      # CONFLICT_NONE
        1) status=$HEALTH_OK ;;      # CONFLICT_INFO (e.g., cPHulk - OK to coexist)
        2) status=$HEALTH_WARNING ;; # CONFLICT_WARNING
        3) status=$HEALTH_CRITICAL ;; # CONFLICT_CRITICAL
        *) status=$HEALTH_OK ;;
    esac

    # Store results
    if [[ ${#NFTBAN_FIREWALL_CONFLICTS[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["conflicting_firewalls"]="${NFTBAN_FIREWALL_CONFLICTS[*]}"

        if [[ $status -eq $HEALTH_CRITICAL ]]; then
            NFTBAN_HEALTH_ERRORS+=("Conflicting firewall(s) detected - see: nftban health conflicts")
        elif [[ $status -eq $HEALTH_WARNING ]]; then
            NFTBAN_HEALTH_WARNINGS+=("Firewall conflicts detected - see: nftban health conflicts")
        fi
        # INFO level (cPHulk) doesn't add to warnings/errors
    fi

    NFTBAN_HEALTH_RESULTS["conflicting_firewalls"]=$status
    return $status
}

# =============================================================================
# MEMORY PROTECTION CHECKS
# =============================================================================

nftban_health_check_protection() {
    # Check if memory protection has been triggered (feeds/geoban skipped)
    # Returns: 0=OK (no protection), 1=Warning (protection active)

    local status=$HEALTH_OK
    local protection_issues=()
    local protection_file="${NFTBAN_DATA_DIR:-/var/lib/nftban}/state/protection.json"

    if [[ -f "$protection_file" ]]; then
        # Protection is active - feeds or geoban were skipped
        local feeds_skipped geoban_skipped reason timestamp
        feeds_skipped=$(jq -r '.feeds_skipped // false' "$protection_file" 2>/dev/null)
        geoban_skipped=$(jq -r '.geoban_skipped // false' "$protection_file" 2>/dev/null)
        reason=$(jq -r '.reason // "Unknown"' "$protection_file" 2>/dev/null)
        timestamp=$(jq -r '.timestamp // "Unknown"' "$protection_file" 2>/dev/null)

        if [[ "$feeds_skipped" == "true" || "$geoban_skipped" == "true" ]]; then
            status=$HEALTH_WARNING

            if [[ "$feeds_skipped" == "true" && "$geoban_skipped" == "true" ]]; then
                protection_issues+=("⚠️ Memory protection ACTIVE: Feeds+Geoban skipped")
            elif [[ "$feeds_skipped" == "true" ]]; then
                protection_issues+=("⚠️ Memory protection ACTIVE: Feeds skipped")
            else
                protection_issues+=("⚠️ Memory protection ACTIVE: Geoban skipped")
            fi

            protection_issues+=("   └─ Reason: $reason")
            protection_issues+=("   └─ Since: $timestamp")
            protection_issues+=("   └─ Action: Add more RAM or reduce enabled feeds/geoban countries")
        fi
    else
        protection_issues+=("✓ Memory protection: Not triggered")
    fi

    NFTBAN_HEALTH_ISSUES["protection"]=$(IFS=$'\n'; echo "${protection_issues[*]}")
    NFTBAN_HEALTH_RESULTS["protection"]=$status
    return "$status"
}

nftban_health_check_memory_protection() {
    # Comprehensive check of the memory protection system
    # Reads: protection.json, permanent_bans.json, daemon IPC for memory pressure
    # Returns: 0=OK, 1=Warning, 2=Error

    local status=$HEALTH_OK
    local mp_issues=()

    local protection_file="${NFTBAN_DATA_DIR:-/var/lib/nftban}/state/protection.json"
    local permanent_bans_file="${NFTBAN_DATA_DIR:-/var/lib/nftban}/state/permanent_bans.json"
    local socket_path="${NFTBAN_RUN_DIR:-/run/nftban}/nftband.sock"

    # =========================================================================
    # 1. Memory Pressure Level (from daemon via IPC)
    # =========================================================================
    local pressure_level="unknown"

    if [[ -S "$socket_path" ]] && command -v socat >/dev/null 2>&1; then
        local response
        response=$(echo '{"method":"stats","params":{}}' | timeout "${NFTBAN_TIMEOUT_FAST:-5}" socat - "UNIX-CONNECT:$socket_path" 2>/dev/null) || response=""

        if [[ -n "$response" ]] && command -v jq >/dev/null 2>&1; then
            local success
            success=$(echo "$response" | jq -r '.success // false' 2>/dev/null)
            if [[ "$success" == "true" ]]; then
                pressure_level=$(echo "$response" | jq -r '.data.pressure_level // "unknown"' 2>/dev/null)
            fi
        fi
    fi

    case "$pressure_level" in
        normal)
            mp_issues+=("Memory Pressure: NORMAL")
            ;;
        warning)
            mp_issues+=("Memory Pressure: WARNING (70-85% of budget)")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
            ;;
        high)
            mp_issues+=("Memory Pressure: HIGH (85-95% of budget, geoban may be skipped)")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
            ;;
        critical)
            mp_issues+=("Memory Pressure: CRITICAL (>95% of budget, feeds+geoban skipped)")
            [[ $status -lt $HEALTH_ERROR ]] && status=$HEALTH_ERROR
            ;;
        *)
            mp_issues+=("Memory Pressure: Unable to determine (daemon not responding?)")
            ;;
    esac

    # =========================================================================
    # 2. Protection State (from protection.json)
    # =========================================================================
    if [[ -f "$protection_file" ]]; then
        local feeds_skipped geoban_skipped reason timestamp

        if command -v jq >/dev/null 2>&1; then
            feeds_skipped=$(jq -r '.feeds_skipped // false' "$protection_file" 2>/dev/null)
            geoban_skipped=$(jq -r '.geoban_skipped // false' "$protection_file" 2>/dev/null)
            reason=$(jq -r '.reason // "Unknown"' "$protection_file" 2>/dev/null)
            timestamp=$(jq -r '.timestamp // "Unknown"' "$protection_file" 2>/dev/null)
        else
            feeds_skipped="unknown"
            geoban_skipped="unknown"
            reason="unknown"
            timestamp="unknown"
        fi

        if [[ "$feeds_skipped" == "true" && "$geoban_skipped" == "true" ]]; then
            mp_issues+=("Protection State: ACTIVE (feeds+geoban skipped)")
            mp_issues+=("   Reason: $reason")
            mp_issues+=("   Since: $timestamp")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        elif [[ "$feeds_skipped" == "true" ]]; then
            mp_issues+=("Protection State: ACTIVE (feeds skipped)")
            mp_issues+=("   Reason: $reason")
            mp_issues+=("   Since: $timestamp")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        elif [[ "$geoban_skipped" == "true" ]]; then
            mp_issues+=("Protection State: ACTIVE (geoban skipped)")
            mp_issues+=("   Reason: $reason")
            mp_issues+=("   Since: $timestamp")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        else
            mp_issues+=("Protection State: Not triggered")
        fi
    else
        mp_issues+=("Protection State: Not triggered (no protection.json)")
    fi

    # =========================================================================
    # 3. Permanent Ban Stats (from permanent_bans.json or daemon IPC)
    # =========================================================================
    local total_bans=0 protected_bans=0 evictable_bans=0

    # Try IPC first (more accurate, includes runtime state)
    if [[ -S "$socket_path" ]] && command -v socat >/dev/null 2>&1; then
        local ban_response
        ban_response=$(echo '{"method":"permanent_ban_stats","params":{}}' | timeout "${NFTBAN_TIMEOUT_FAST:-5}" socat - "UNIX-CONNECT:$socket_path" 2>/dev/null) || ban_response=""

        if [[ -n "$ban_response" ]] && command -v jq >/dev/null 2>&1; then
            local ban_success
            ban_success=$(echo "$ban_response" | jq -r '.success // false' 2>/dev/null)
            if [[ "$ban_success" == "true" ]]; then
                total_bans=$(echo "$ban_response" | jq -r '.data.total // 0' 2>/dev/null)
                protected_bans=$(echo "$ban_response" | jq -r '.data.protected // 0' 2>/dev/null)
                evictable_bans=$(echo "$ban_response" | jq -r '.data.evictable // 0' 2>/dev/null)
            fi
        fi
    fi

    # Fall back to reading the file directly if IPC failed
    if [[ $total_bans -eq 0 ]] && [[ -f "$permanent_bans_file" ]]; then
        if command -v jq >/dev/null 2>&1; then
            total_bans=$(jq -r '.bans | length // 0' "$permanent_bans_file" 2>/dev/null)
            protected_bans=$(jq -r '[.bans[] | select(.protected == true)] | length // 0' "$permanent_bans_file" 2>/dev/null)
            # Evictable = not protected and older than 30 days
            local now_ts thirty_days_ago
            now_ts=$(nftban_timestamp_unix)
            thirty_days_ago=$((now_ts - 30*24*60*60))
            evictable_bans=$(jq -r --argjson cutoff "$thirty_days_ago" \
                '[.bans[] | select(.protected != true) | select((.added_at | fromdateiso8601 // 0) < $cutoff)] | length // 0' \
                "$permanent_bans_file" 2>/dev/null) || evictable_bans=0
        fi
    fi

    mp_issues+=("Permanent Bans: Total=$total_bans, Protected=$protected_bans, Evictable=$evictable_bans")

    # =========================================================================
    # 4. CIDR Limit for Server Tier
    # =========================================================================
    local total_ram_kb cidr_limit tier_name
    total_ram_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo "0")
    local total_ram_gb=$(( total_ram_kb / 1024 / 1024 ))

    if [[ $total_ram_gb -le 4 ]]; then
        cidr_limit=75000
        tier_name="small (<=4GB RAM)"
    elif [[ $total_ram_gb -le 8 ]]; then
        cidr_limit=100000
        tier_name="medium (4-8GB RAM)"
    else
        cidr_limit=150000
        tier_name="large (>8GB RAM)"
    fi

    mp_issues+=("CIDR Limit: $cidr_limit (tier: $tier_name)")

    # =========================================================================
    # Store results
    # =========================================================================
    if [[ $status -eq $HEALTH_ERROR ]]; then
        NFTBAN_HEALTH_ERRORS+=("Memory Protection: Critical pressure or protection issues")
    elif [[ $status -eq $HEALTH_WARNING ]]; then
        NFTBAN_HEALTH_WARNINGS+=("Memory Protection: Elevated pressure or protection active")
    fi

    NFTBAN_HEALTH_ISSUES["memory_protection"]=$(IFS=$'\n'; echo "${mp_issues[*]}")
    NFTBAN_HEALTH_RESULTS["memory_protection"]=$status
    return "$status"
}

# =============================================================================
# POLKIT AUTHORIZATION CHECK
# =============================================================================

nftban_health_check_polkit() {
    # Check Polkit authorization rules installation
    # Args: $1 = auto_heal (1 to auto-fix, 0 to just report)
    # Returns: 0=OK, 1=Warning, 2=Error (CRITICAL security violation)

    local auto_heal="${1:-0}"
    local status=$HEALTH_OK
    local polkit_issues=()

    # Check if Polkit is available on the system
    # Polkit is required for non-root privilege separation
    # Root-only deployments can operate without polkit
    if ! command -v pkaction >/dev/null 2>&1; then
        polkit_issues+=("Polkit not installed - privilege separation unavailable")
        polkit_issues+=("FIX (Debian/Ubuntu): apt install polkitd  (or policykit-1 on older releases)")
        polkit_issues+=("FIX (RHEL/Rocky/Fedora): dnf install polkit")
        # Downgrade to WARNING if running as root (polkit optional for root)
        if [[ $EUID -eq 0 ]]; then
            polkit_issues+=("INFO: Running as root - polkit is optional unless enabling group access")
            status=$HEALTH_WARNING
        else
            polkit_issues+=("ERROR: Non-root execution requires polkit for privilege separation")
            status=$HEALTH_ERROR
        fi
    else
        # Check if NFTBAN systemd authorization rules are installed (v1.0.19+ naming)
        local polkit_rules_dir="${NFTBAN_POLKIT_RULES_DIR:-/etc/polkit-1/rules.d}"

        local polkit_systemd_rules="${polkit_rules_dir}/10-nftban-systemd.rules"
        if [[ ! -f "$polkit_systemd_rules" ]]; then
            polkit_issues+=("CRITICAL: Polkit systemd rules missing at $polkit_systemd_rules")
            polkit_issues+=("This violates NFTBAN security model - privilege separation not functional!")
            polkit_issues+=("Users in nftban group CANNOT manage services without sudo")
            polkit_issues+=("FIX: Re-run install.sh or reinstall nftban package")
            status=$HEALTH_ERROR
        else
            # Verify file permissions using shared helper
            local perms
            perms=$(nftban_file_perms "$polkit_systemd_rules")
            if [[ "$perms" != "644" ]]; then
                polkit_issues+=("Polkit systemd rules have wrong permissions: $perms (should be 644)")
                status=$HEALTH_WARNING
            fi
        fi

        # Check if NFTBAN Auditor authorization rules are installed (v1.0.19+)
        local polkit_auditor_rules="${polkit_rules_dir}/20-nftban-auditor.rules"
        if [[ ! -f "$polkit_auditor_rules" ]]; then
            polkit_issues+=("WARNING: Polkit auditor rules missing at $polkit_auditor_rules")
            polkit_issues+=("Users in nftban-auditor group cannot run inventory helpers without sudo")
            polkit_issues+=("FIX: Re-run install.sh or reinstall nftban package")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        else
            # Verify file permissions using shared helper
            local perms
            perms=$(nftban_file_perms "$polkit_auditor_rules")
            if [[ "$perms" != "644" ]]; then
                polkit_issues+=("Polkit auditor rules have wrong permissions: $perms (should be 644)")
                [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
            fi
        fi

        # Check if NFTBAN Panel authorization rules are installed (v1.0.19+)
        local polkit_panel_rules="${polkit_rules_dir}/30-nftban-panel.rules"
        if [[ ! -f "$polkit_panel_rules" ]]; then
            polkit_issues+=("WARNING: Polkit panel rules missing at $polkit_panel_rules")
            polkit_issues+=("Control panel integrations may not work without sudo")
            polkit_issues+=("FIX: Re-run install.sh or reinstall nftban package")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        else
            # Verify file permissions using shared helper
            local perms
            perms=$(nftban_file_perms "$polkit_panel_rules")
            if [[ "$perms" != "644" ]]; then
                polkit_issues+=("Polkit panel rules have wrong permissions: $perms (should be 644)")
                [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
            fi
        fi

        # Check if polkit service is running (using shared library)
        if command -v systemctl >/dev/null 2>&1; then
            local polkit_service="polkit"
            # Use distro config if available
            if declare -F nftban_distro_get_service >/dev/null 2>&1; then
                polkit_service=$(nftban_distro_get_service polkit)
                [[ -z "$polkit_service" ]] && polkit_service="polkit"
            fi

            if ! nftban_service_is_active "$polkit_service"; then
                if [[ "$auto_heal" == "1" ]]; then
                    if nftban_service_start "$polkit_service"; then
                        polkit_issues+=("Polkit service was stopped - AUTO-HEALED: started successfully")
                        [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
                    else
                        polkit_issues+=("Polkit service not running (optional for minimal installs)")
                        polkit_issues+=("Only needed if non-root users manage services")
                        [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
                    fi
                else
                    polkit_issues+=("Polkit service not running (optional for minimal installs)")
                    polkit_issues+=("Only needed if non-root users manage services")
                    polkit_issues+=("FIX: sudo systemctl start $polkit_service")
                    [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
                fi
            fi
        fi
    fi

    # Store results
    if [[ ${#polkit_issues[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["polkit"]="${polkit_issues[*]}"
        if [[ $status -eq $HEALTH_ERROR ]]; then
            NFTBAN_HEALTH_ERRORS+=("Polkit issues: ${polkit_issues[*]}")
        else
            NFTBAN_HEALTH_WARNINGS+=("Polkit issues: ${polkit_issues[*]}")
        fi
    fi

    NFTBAN_HEALTH_RESULTS["polkit"]=$status
    return $status
}

# =============================================================================
# SYSTEMD HARDENING CHECK
# =============================================================================

nftban_health_check_systemd_hardening() {
    # Check systemd service hardening (NoNewPrivileges, security scores)
    # Returns: 0=OK, 1=Warning, 2=Error, 3=Critical

    local status=$HEALTH_OK
    local hardening_issues=()

    # =========================================================================
    # CHECK 1: Scan all NFTBan systemd units for NoNewPrivileges=false
    # =========================================================================

    local units_with_nnp_false=()
    local systemd_unit_paths=(
        "/etc/systemd/system"
        "/usr/lib/systemd/system"
        "/lib/systemd/system"
    )

    # Find all nftban*.service files
    local nftban_units=()
    for unit_path in "${systemd_unit_paths[@]}"; do
        if [[ -d "$unit_path" ]]; then
            while IFS= read -r -d '' unit_file; do
                nftban_units+=("$unit_file")
            done < <(find "$unit_path" -maxdepth 1 -name 'nftban*.service' -type f -print0 2>/dev/null)
        fi
    done

    # Scan each unit for NoNewPrivileges=false
    for unit_file in "${nftban_units[@]}"; do
        if grep -qE '^\s*NoNewPrivileges\s*=\s*false\s*$' "$unit_file" 2>/dev/null; then
            local unit_name
            unit_name=$(basename "$unit_file")
            units_with_nnp_false+=("$unit_name")
        fi
    done

    # Report NoNewPrivileges=false findings
    if [[ ${#units_with_nnp_false[@]} -gt 0 ]]; then
        hardening_issues+=("CRITICAL: ${#units_with_nnp_false[@]} systemd service(s) have NoNewPrivileges=false")
        hardening_issues+=("  └─ This allows privilege escalation via setuid/setcap executables")
        for unit in "${units_with_nnp_false[@]}"; do
            hardening_issues+=("  └─ $unit")
        done
        hardening_issues+=("  └─ FIX: Set NoNewPrivileges=yes in all units")
        status=$HEALTH_CRITICAL
    fi

    # =========================================================================
    # CHECK 2: Run systemd-analyze security on key services
    # =========================================================================

    if command -v systemd-analyze >/dev/null 2>&1; then
        # Key security-sensitive services to check
        local key_services=(
            "nftban-maintenance.service"
            "nftban-ui.service"
            "nftband.service"
        )

        local poor_scores=()
        for service in "${key_services[@]}"; do
            # Check if service exists
            if systemctl list-unit-files "$service" &>/dev/null; then
                # Run systemd-analyze security (extract exposure score)
                local score_output
                score_output=$(systemd-analyze security "$service" 2>/dev/null | grep -E '^→ Overall exposure level:' | head -1)

                if [[ -n "$score_output" ]]; then
                    # Extract exposure level (SAFE, OK, MEDIUM, EXPOSED, UNSAFE)
                    local exposure_level
                    exposure_level=$(echo "$score_output" | awk '{print $NF}')

                    # Warn on EXPOSED or UNSAFE
                    if [[ "$exposure_level" == "EXPOSED" || "$exposure_level" == "UNSAFE" ]]; then
                        poor_scores+=("$service: $exposure_level")
                    fi
                fi
            fi
        done

        if [[ ${#poor_scores[@]} -gt 0 ]]; then
            hardening_issues+=("WARNING: ${#poor_scores[@]} service(s) have poor systemd security scores")
            for score in "${poor_scores[@]}"; do
                hardening_issues+=("  └─ $score")
            done
            hardening_issues+=("  └─ Run: systemd-analyze security <service> for details")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi
    fi

    # =========================================================================
    # Store results
    # =========================================================================

    if [[ ${#hardening_issues[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["systemd_hardening"]="${hardening_issues[*]}"
        if [[ $status -eq $HEALTH_CRITICAL ]]; then
            NFTBAN_HEALTH_ERRORS+=("CRITICAL systemd hardening issues: ${hardening_issues[*]}")
        elif [[ $status -eq $HEALTH_ERROR ]]; then
            NFTBAN_HEALTH_ERRORS+=("systemd hardening issues: ${hardening_issues[*]}")
        elif [[ $status -eq $HEALTH_WARNING ]]; then
            NFTBAN_HEALTH_WARNINGS+=("systemd hardening warnings: ${hardening_issues[*]}")
        fi
    fi

    NFTBAN_HEALTH_RESULTS["systemd_hardening"]=$status
    return $status
}

# =============================================================================
# SSH PORT CHECK
# =============================================================================

nftban_health_check_ssh_port() {
    # Check and auto-update SSH port whitelist
    # Returns: 0=OK, 1=Warning (auto-fixed), 2=Error (couldn't fix)

    local status=$HEALTH_OK
    local ssh_issues=()

    # State file to track the currently active SSH port (for cleanup)
    local ssh_port_active="${NFTBAN_DATA_DIR}/state/ssh_port_active.state"

    # Detect current SSH port from sshd_config
    local current_ssh_port=22
    if [[ -f "/etc/ssh/sshd_config" ]]; then
        local detected_port
        detected_port=$(grep -E '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
        if [[ -n "$detected_port" ]] && [[ "$detected_port" =~ ^[0-9]+$ ]]; then
            current_ssh_port=$detected_port
        fi
    fi

    # Check current whitelisted SSH port in config
    local config_ssh_port=""
    if [[ -f "${NFTBAN_CONFIG_DIR}/ports.d/00-ssh.conf" ]]; then
        config_ssh_port=$(grep -oP '^\d+' "${NFTBAN_CONFIG_DIR}/ports.d/00-ssh.conf" 2>/dev/null | head -1)
    fi

    # Get old SSH port from state (for cleanup)
    local old_ssh_port=""
    if [[ -f "$ssh_port_active" ]]; then
        old_ssh_port=$(cat "$ssh_port_active" 2>/dev/null || echo "")
        # Validate it's a number and different from current
        if [[ -z "$old_ssh_port" ]] || ! [[ "$old_ssh_port" =~ ^[0-9]+$ ]] || [[ "$old_ssh_port" == "$current_ssh_port" ]]; then
            old_ssh_port=""
        fi
    fi

    # Compare and auto-update if needed
    if [[ "$current_ssh_port" != "$config_ssh_port" ]]; then
        ssh_issues+=("SSH port mismatch: sshd_config=$current_ssh_port, nftban=$config_ssh_port")

        # Auto-fix: Update the SSH port config (format: PORT/PROTOCOL)
        if mkdir -p "${NFTBAN_CONFIG_DIR}/ports.d" 2>/dev/null; then
            cat > "${NFTBAN_CONFIG_DIR}/ports.d/00-ssh.conf" << EOF
# SSH port auto-updated by health check ($(nftban_timestamp))
# Port format: PORT/PROTOCOL where PROTOCOL = T/tcp, U/udp, or B/both
$current_ssh_port/T
EOF
            chown nftban:nftban "${NFTBAN_CONFIG_DIR}/ports.d/00-ssh.conf" 2>/dev/null || true
            chmod 644 "${NFTBAN_CONFIG_DIR}/ports.d/00-ssh.conf" 2>/dev/null || true

            ssh_issues+=("AUTO-FIXED: Updated SSH port to $current_ssh_port in ${NFTBAN_CONFIG_DIR}/ports.d/00-ssh.conf")

            # Track if old port needs cleanup
            if [[ -n "$old_ssh_port" ]]; then
                ssh_issues+=("Old SSH port $old_ssh_port will be removed from firewall on reload")
            fi

            ssh_issues+=("Action required: Run 'nftban firewall reload' to apply changes")

            status=$HEALTH_WARNING  # Warning because reload needed
        else
            ssh_issues+=("FAILED to auto-fix: Cannot write to ${NFTBAN_CONFIG_DIR}/ports.d/")
            status=$HEALTH_ERROR
        fi
    fi

    # Update the active SSH port state file (tracks what port is currently in use)
    if mkdir -p "${NFTBAN_DATA_DIR}/state" 2>/dev/null; then
        echo "$current_ssh_port" > "$ssh_port_active" 2>/dev/null || true
    fi

    # Verify SSH port is actually in nftables (v0.7.3: check IPv4 table)
    if nft list table ${NFTBAN_TABLE_IPV4} >/dev/null 2>&1; then
        if ! timeout 10s nft list set ${NFTBAN_TABLE_IPV4} tcp_ports_in 2>/dev/null | grep -qw "$current_ssh_port"; then
            ssh_issues+=("WARNING: SSH port $current_ssh_port NOT in nftables tcp_ports_in set")
            ssh_issues+=("LOCKOUT RISK! Run: nftban firewall reload")
            status=$HEALTH_ERROR
        fi

        # Check for stale old SSH port in firewall (cleanup detection)
        if [[ -n "$old_ssh_port" ]]; then
            if timeout 10s nft list set ${NFTBAN_TABLE_IPV4} tcp_ports_in 2>/dev/null | grep -qw "$old_ssh_port"; then
                ssh_issues+=("CLEANUP: Old SSH port $old_ssh_port still in firewall tcp_ports_in set")
                ssh_issues+=("Run 'nftban firewall reload' to remove old port")
                [[ $status -eq $HEALTH_OK ]] && status=$HEALTH_WARNING
            fi
        fi
    fi

    # Store results
    if [[ ${#ssh_issues[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["ssh_port"]="${ssh_issues[*]}"
        if [[ $status -eq $HEALTH_ERROR ]]; then
            NFTBAN_HEALTH_ERRORS+=("SSH port issues: ${ssh_issues[*]}")
        else
            NFTBAN_HEALTH_WARNINGS+=("SSH port issues: ${ssh_issues[*]}")
        fi
    fi

    NFTBAN_HEALTH_RESULTS["ssh_port"]=$status
    return $status
}

# =============================================================================
# NFT SCHEMA VALIDATION CHECK
# =============================================================================

nftban_health_check_nft_schema() {
    # Validate nftables structure against canonical schema
    # Checks: tables, sets, chains, set types/flags, rule order
    # Returns: 0=OK, 1=Warning, 2=Error

    local status=$HEALTH_OK
    local schema_issues=()
    local output

    # Ensure nft command is available
    if ! command -v nft &>/dev/null; then
        schema_issues+=("nft command not found - cannot validate schema")
        NFTBAN_HEALTH_RESULTS["nft_schema"]=$HEALTH_WARNING
        NFTBAN_HEALTH_WARNINGS+=("NFT Schema: nft command not available")
        return 1
    fi

    # Ensure schema is loaded
    if ! declare -f nftban_nft_validate_tables >/dev/null 2>&1; then
        if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nft_schema.sh" ]]; then
            source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nft_schema.sh" 2>/dev/null || {
                schema_issues+=("Cannot load nft_schema.sh")
                NFTBAN_HEALTH_RESULTS["nft_schema"]=$HEALTH_WARNING
                NFTBAN_HEALTH_WARNINGS+=("NFT Schema: Cannot load schema module")
                return 1
            }
        else
            schema_issues+=("nft_schema.sh not found")
            NFTBAN_HEALTH_RESULTS["nft_schema"]=$HEALTH_WARNING
            NFTBAN_HEALTH_WARNINGS+=("NFT Schema: Schema module not installed")
            return 1
        fi
    fi

    local errors=0

    # 1. Validate tables exist
    if output=$(nftban_nft_validate_tables 2>&1); then
        schema_issues+=("Tables: OK")
    else
        schema_issues+=("Tables: FAILED - $output")
        errors=$((errors + 1))
    fi

    # 2. Validate sets exist
    if output=$(nftban_nft_validate_sets 2>&1); then
        schema_issues+=("Sets: OK")
    else
        schema_issues+=("Sets: FAILED - $output")
        errors=$((errors + 1))
    fi

    # 3. Validate chains
    if output=$(nftban_nft_validate_chains 2>&1); then
        schema_issues+=("Chains: OK")
    else
        schema_issues+=("Chains: FAILED - $output")
        errors=$((errors + 1))
    fi

    # 4. Validate set types and flags
    if output=$(nftban_nft_validate_set_flags 2>&1); then
        schema_issues+=("Set flags: OK")
    else
        schema_issues+=("Set flags: WARNING - $output")
    fi

    # 5. SECURITY-CRITICAL: Validate rule order (blacklist before established)
    if output=$(nftban_nft_validate_rule_order 2>&1); then
        schema_issues+=("Rule order: OK (blacklist before established)")
    else
        schema_issues+=("CRITICAL: Rule order incorrect - $output")
        errors=$((errors + 1))
        status=$HEALTH_CRITICAL
    fi

    # 6. Check for deprecated tables
    local existing_tables
    existing_tables=$(nft list tables 2>/dev/null)
    for deprecated_table in "${!NFTBAN_DEPRECATED_TABLES[@]}"; do
        if echo "$existing_tables" | grep -q "^table ${deprecated_table}$"; then
            schema_issues+=("Legacy table present: ${deprecated_table}")
        fi
    done

    # Set status
    if [[ $status -ne $HEALTH_CRITICAL ]]; then
        if [[ $errors -gt 0 ]]; then
            status=$HEALTH_ERROR
        fi
    fi

    # Store results
    # shellcheck disable=SC2034  # Used by render functions externally
    NFTBAN_HEALTH_ISSUES["nft_schema"]="${schema_issues[*]}"
    if [[ $status -ge $HEALTH_ERROR ]]; then
        NFTBAN_HEALTH_ERRORS+=("NFT Schema: $errors validation errors")
    elif [[ $status -eq $HEALTH_WARNING ]]; then
        NFTBAN_HEALTH_WARNINGS+=("NFT Schema: validation warnings")
    fi

    # shellcheck disable=SC2034  # Used by render functions externally
    NFTBAN_HEALTH_RESULTS["nft_schema"]=$status
    return $status
}

# Export functions
export -f nftban_health_check_nftables_security nftban_health_check_conflicting_firewalls
export -f nftban_health_check_protection nftban_health_check_memory_protection
export -f nftban_health_check_polkit nftban_health_check_systemd_hardening
export -f nftban_health_check_ssh_port nftban_health_check_nft_schema
