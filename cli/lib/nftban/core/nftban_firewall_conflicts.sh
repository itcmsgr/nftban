#!/usr/bin/env bash
# =============================================================================
# NFTBan - Firewall Conflict Detection Library
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Detect and report conflicting firewall systems
#
# meta:name="nftban_firewall_conflicts"
# meta:type="lib"
# meta:header="Firewall Conflict Detection"
# meta:version="1.52.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# **Description & Purpose**
# meta:description="Detects fail2ban, iptables-nft, firewalld, ufw and other conflicts"
# meta:input="System state"
# meta:output="Conflict report"
#
# **Inventory & Requirements**
# meta:depends=""
# meta:inventory.files=""
# meta:inventory.binaries="nft,systemctl,iptables"
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/fail2ban/jail.conf,/etc/fail2ban/jail.local"
# meta:inventory.systemd_units="fail2ban.service,firewalld.service,iptables.service,ufw.service"
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2026-01-18"
# meta:updated_date="2026-01-18"
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# CONFLICT SEVERITY LEVELS
# =============================================================================
# v1.150 (15.10/16.2): these constants are declared BEFORE the load-guard
# return so they are always bound. The load-guard skips re-running the function
# definitions on a re-source, but if `_NFTBAN_FIREWALL_CONFLICTS_LOADED` is
# inherited (e.g. exported into a child shell that re-sources this file under
# `set -u`), an early return would otherwise leave CONFLICT_* unbound and abort
# the first bare reference (`$CONFLICT_NONE`). Keeping the declares above the
# guard makes double-sourcing safe.
declare -g CONFLICT_NONE=0
declare -g CONFLICT_INFO=1
declare -g CONFLICT_WARNING=2
declare -g CONFLICT_CRITICAL=3

# Prevent double-loading (functions/arrays below are re-initialised only once)
[[ -n "${_NFTBAN_FIREWALL_CONFLICTS_LOADED:-}" ]] && return 0
_NFTBAN_FIREWALL_CONFLICTS_LOADED=1

# Global arrays to store detected conflicts
declare -ga NFTBAN_FIREWALL_CONFLICTS=()
declare -ga NFTBAN_FIREWALL_FIXES=()
declare -g NFTBAN_FIREWALL_SEVERITY=$CONFLICT_NONE

# =============================================================================
# FAIL2BAN DETECTION
# =============================================================================

nftban_detect_fail2ban() {
    # Detect fail2ban installation and configuration
    # Returns: 0=not found, 1=found inactive, 2=found active, 3=active with nftables conflict

    local status=0
    local backend=""
    local jail_count=0

    # Check if fail2ban is installed
    if ! command -v fail2ban-client &>/dev/null; then
        return 0
    fi

    # Check if service is active
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        status=2

        # Get active jails count
        jail_count=$(fail2ban-client status 2>/dev/null | grep "Number of jail" | awk '{print $NF}' || echo "0")

        # Detect backend type
        if [[ -f /etc/fail2ban/jail.conf ]] || [[ -f /etc/fail2ban/jail.local ]]; then
            # Check for banaction configuration
            for conf in /etc/fail2ban/jail.local /etc/fail2ban/jail.conf /etc/fail2ban/jail.d/*.conf; do
                [[ -f "$conf" ]] || continue
                if grep -q "banaction.*=.*nftables" "$conf" 2>/dev/null; then
                    backend="nftables"
                    break
                elif grep -q "banaction.*=.*iptables" "$conf" 2>/dev/null; then
                    backend="iptables"
                    break
                fi
            done

            # Fallback: check default action
            if [[ -z "$backend" ]]; then
                backend=$(fail2ban-client get sshd banaction 2>/dev/null | head -1 || echo "unknown")
                case "$backend" in
                    *nftables*) backend="nftables" ;;
                    *iptables*) backend="iptables" ;;
                    *) backend="unknown" ;;
                esac
            fi
        fi

        # Check for iptables-nft (translation layer creating nftables rules)
        if [[ "$backend" == "iptables" ]] || [[ "$backend" == "unknown" ]]; then
            # Check if iptables is actually iptables-nft
            local ipt_version
            ipt_version=$(iptables --version 2>/dev/null || echo "")
            if [[ "$ipt_version" == *"nf_tables"* ]]; then
                backend="iptables-nft"
                status=3  # Critical conflict
            fi
        elif [[ "$backend" == "nftables" ]]; then
            status=3  # Direct nftables conflict
        fi

        # Store detection info
        NFTBAN_FIREWALL_CONFLICTS+=("FAIL2BAN: Active with $jail_count jail(s), backend=$backend")

        if [[ $status -eq 3 ]]; then
            NFTBAN_FIREWALL_CONFLICTS+=("  CRITICAL: fail2ban creates conflicting nftables rules")
            NFTBAN_FIREWALL_CONFLICTS+=("  └─ Creates 'ip filter' table that conflicts with nftban")
            NFTBAN_FIREWALL_FIXES+=("Disable fail2ban — NFTBan's native login monitoring replaces it:")
            NFTBAN_FIREWALL_FIXES+=("  systemctl stop fail2ban && systemctl disable fail2ban")
            [[ $NFTBAN_FIREWALL_SEVERITY -lt $CONFLICT_CRITICAL ]] && NFTBAN_FIREWALL_SEVERITY=$CONFLICT_CRITICAL
        else
            NFTBAN_FIREWALL_FIXES+=("Consider disabling fail2ban in favor of nftban:")
            NFTBAN_FIREWALL_FIXES+=("  systemctl stop fail2ban && systemctl disable fail2ban")
            [[ $NFTBAN_FIREWALL_SEVERITY -lt $CONFLICT_WARNING ]] && NFTBAN_FIREWALL_SEVERITY=$CONFLICT_WARNING
        fi
    elif systemctl is-enabled --quiet fail2ban 2>/dev/null; then
        status=1
        NFTBAN_FIREWALL_CONFLICTS+=("FAIL2BAN: Enabled but not running")
        NFTBAN_FIREWALL_FIXES+=("Disable fail2ban to prevent future conflicts:")
        NFTBAN_FIREWALL_FIXES+=("  systemctl disable fail2ban")
        [[ $NFTBAN_FIREWALL_SEVERITY -lt $CONFLICT_INFO ]] && NFTBAN_FIREWALL_SEVERITY=$CONFLICT_INFO
    fi

    return $status
}

# =============================================================================
# IPTABLES-NFT DETECTION (Translation Layer) - REQUIRED FOR CPANEL
# =============================================================================

nftban_detect_iptables_nft() {
    # Detect if iptables is using nf_tables backend (iptables-nft)
    # This creates shadow nftables rules that conflict with native nftables
    # Used by cPanel detection - DO NOT REMOVE
    # Returns: 0=not found, 1=iptables-nft detected, 2=active rules found

    local status=0

    # Check if iptables exists
    if ! command -v iptables &>/dev/null; then
        return 0
    fi

    # Check iptables backend
    local ipt_version
    ipt_version=$(iptables --version 2>/dev/null || echo "")

    if [[ "$ipt_version" == *"nf_tables"* ]]; then
        status=1

        # Check for active iptables rules that create nftables tables
        local rule_count
        rule_count=$(iptables -S 2>/dev/null | grep -cv "^-P" 2>/dev/null || true)
        rule_count="${rule_count//[^0-9]/}"
        [[ -z "$rule_count" ]] && rule_count=0

        # Check if all policies are ACCEPT (passthrough mode - harmless)
        local drop_policies
        drop_policies=$(iptables -S 2>/dev/null | grep -c "^-P.*DROP\|^-P.*REJECT" 2>/dev/null || true)
        drop_policies="${drop_policies//[^0-9]/}"
        [[ -z "$drop_policies" ]] && drop_policies=0

        if [[ $rule_count -gt 0 ]]; then
            status=2
            # Only log INFO - actual conflict severity determined by priority check
            # in nftban_detect_conflicting_tables which assesses if NFTBan runs first
            NFTBAN_FIREWALL_CONFLICTS+=("IPTABLES-NFT: $rule_count rules (priority check determines safety)")

            # Don't set severity here - let nftban_detect_conflicting_tables handle it
            # That function checks if NFTBan's priority (-100) runs before filter (0)
            [[ $NFTBAN_FIREWALL_SEVERITY -lt $CONFLICT_INFO ]] && NFTBAN_FIREWALL_SEVERITY=$CONFLICT_INFO

            NFTBAN_FIREWALL_FIXES+=("Flush iptables-nft: iptables -F && iptables -X && ip6tables -F && ip6tables -X")
        elif [[ $drop_policies -eq 0 ]]; then
            # Only default ACCEPT policies, no rules - this is harmless passthrough
            # Don't even report as conflict, just note it exists
            status=1
            # No severity increase - iptables-nft with ACCEPT policies is harmless
        fi
    fi

    return $status
}

# =============================================================================
# IPTABLES SERVICE DETECTION (iptables.service / ip6tables.service)
# =============================================================================

nftban_detect_iptables_service() {
    # Detect if iptables.service or ip6tables.service is active
    # These are systemd services that manage iptables rules
    # Returns: 0=not active, 1=service active

    local status=0

    if systemctl is-active --quiet iptables 2>/dev/null; then
        status=1
        NFTBAN_FIREWALL_CONFLICTS+=("IPTABLES: iptables.service is ACTIVE")
        [[ $NFTBAN_FIREWALL_SEVERITY -lt $CONFLICT_CRITICAL ]] && NFTBAN_FIREWALL_SEVERITY=$CONFLICT_CRITICAL
        NFTBAN_FIREWALL_FIXES+=("Disable iptables: systemctl disable --now iptables")
    fi

    if systemctl is-active --quiet ip6tables 2>/dev/null; then
        status=1
        NFTBAN_FIREWALL_CONFLICTS+=("IP6TABLES: ip6tables.service is ACTIVE")
        [[ $NFTBAN_FIREWALL_SEVERITY -lt $CONFLICT_CRITICAL ]] && NFTBAN_FIREWALL_SEVERITY=$CONFLICT_CRITICAL
        NFTBAN_FIREWALL_FIXES+=("Disable ip6tables: systemctl disable --now ip6tables")
    fi

    return $status
}

# =============================================================================
# XTABLES COMPAT DETECTION (xt target rules in live nftables)
# =============================================================================

nftban_detect_xt_compat() {
    # Detect xtables compatibility rules in the live nftables ruleset
    # These are created when iptables-nft translates iptables rules to nftables
    # and indicate active iptables-nft usage that may conflict with NFTBan
    # Returns: 0=not found, 1=xt compat rules detected

    local status=0

    # Check if nft command exists
    if ! command -v nft &>/dev/null; then
        return 0
    fi

    # Check live ruleset for xt target or xtables compat markers
    if nft list ruleset 2>/dev/null | grep -qE "xt target|xtables compat"; then
        status=1
        NFTBAN_FIREWALL_CONFLICTS+=("XT-COMPAT: iptables-nft compatibility rules detected in live ruleset")
        NFTBAN_FIREWALL_CONFLICTS+=("  └─ These rules are created by iptables-nft and may conflict with NFTBan")
        NFTBAN_FIREWALL_FIXES+=("Flush iptables-nft rules to remove xt compat entries:")
        NFTBAN_FIREWALL_FIXES+=("  iptables -F && iptables -X && ip6tables -F && ip6tables -X")
        NFTBAN_FIREWALL_FIXES+=("  nft delete table ip filter 2>/dev/null; nft delete table ip6 filter 2>/dev/null")
        [[ $NFTBAN_FIREWALL_SEVERITY -lt $CONFLICT_WARNING ]] && NFTBAN_FIREWALL_SEVERITY=$CONFLICT_WARNING
    fi

    return $status
}

# =============================================================================
# CONFLICTING NFTABLES TABLES DETECTION
# =============================================================================

nftban_detect_conflicting_tables() {
    # Detect nftables tables that may conflict with nftban
    # Known conflicts: ip filter (iptables-nft), firewalld tables
    # Returns: 0=none, 1=warning, 2=critical

    local status=0

    if ! command -v nft &>/dev/null; then
        return 0
    fi

    # List all nftables tables
    local tables
    tables=$(nft list tables 2>/dev/null || echo "")

    # Get NFTBan's input chain priority (v1.18.0: standardized to 0)
    # shellcheck disable=SC2034  # nftban_priority documents expected default
    local nftban_priority=0
    local actual_nftban_prio
    # `// 0` plus a fallback of 0 made an unreadable chain indistinguishable
    # from a chain at priority 0 — and priority is what the conflict verdict
    # compares. UNKNOWN is carried so the comparison can refuse instead.
    local _prio_raw
    _prio_raw=$(nft -j list chain ip nftban input 2>/dev/null) || _prio_raw=""
    if [[ -n "${_prio_raw//[[:space:]]/}" ]]; then
        actual_nftban_prio=$(printf '%s' "$_prio_raw" | jq -r '.nftables[]? | select(.chain?) | .chain.prio // 0' 2>/dev/null | head -1)
        [[ "$actual_nftban_prio" =~ ^-?[0-9]+$ ]] || actual_nftban_prio="UNKNOWN"
    else
        actual_nftban_prio="UNKNOWN"
    fi

    # Check for known conflicting tables with PRIORITY-BASED SAFETY

    # 1. ip filter (created by iptables-nft, Plesk, CSF, etc.)
    if echo "$tables" | grep -q "^table ip filter"; then
        # v1.53.0: Check if table has an INPUT chain before checking priority.
        # Empty tables (no chains) are INFO, not CRITICAL — iptables-nft creates
        # empty tables on any iptables invocation but they have no hooks.
        if nft list chain ip filter INPUT &>/dev/null; then
            local filter_prio
            filter_prio=$(nft -j list chain ip filter INPUT 2>/dev/null | jq -r '.nftables[]? | select(.chain?) | .chain.prio // 0' 2>/dev/null | head -1)
            [[ "$filter_prio" =~ ^-?[0-9]+$ ]] || filter_prio="UNKNOWN"

            if [[ ! "$actual_nftban_prio" =~ ^-?[0-9]+$ || ! "$filter_prio" =~ ^-?[0-9]+$ ]]; then
                # Priority ordering decides whether a foreign table shadows us.
                # With either priority unread that ordering is unknown, and a
                # numeric compare against UNKNOWN would error rather than decide.
                NFTBAN_FIREWALL_CONFLICTS+=("UNKNOWN: 'ip filter' present but a chain priority was unreadable (nftban=$actual_nftban_prio, foreign=$filter_prio) — shadowing NOT ruled out")
            elif [[ "$filter_prio" -le "$actual_nftban_prio" ]]; then
                # CRITICAL: filter table has INPUT hook at competing priority
                status=2
                NFTBAN_FIREWALL_CONFLICTS+=("CRITICAL: 'ip filter' table (priority $filter_prio) runs before NFTBan (priority $actual_nftban_prio)")
                [[ $NFTBAN_FIREWALL_SEVERITY -lt $CONFLICT_CRITICAL ]] && NFTBAN_FIREWALL_SEVERITY=$CONFLICT_CRITICAL
            else
                status=1
                NFTBAN_FIREWALL_CONFLICTS+=("INFO: 'ip filter' table exists (priority $filter_prio) - NFTBan has higher priority")
                [[ $NFTBAN_FIREWALL_SEVERITY -lt $CONFLICT_INFO ]] && NFTBAN_FIREWALL_SEVERITY=$CONFLICT_INFO
            fi
        else
            # Table exists but has no INPUT chain — harmless artifact from iptables-nft
            [[ $status -eq 0 ]] && status=1
            NFTBAN_FIREWALL_CONFLICTS+=("INFO: 'ip filter' table exists but has no hooks (iptables-nft artifact, harmless)")
            [[ $NFTBAN_FIREWALL_SEVERITY -lt $CONFLICT_INFO ]] && NFTBAN_FIREWALL_SEVERITY=$CONFLICT_INFO
        fi
    fi

    # 2. ip6 filter
    if echo "$tables" | grep -q "^table ip6 filter"; then
        if nft list chain ip6 filter INPUT &>/dev/null; then
            local filter6_prio
            filter6_prio=$(nft -j list chain ip6 filter INPUT 2>/dev/null | jq -r '.nftables[]? | select(.chain?) | .chain.prio // 0' 2>/dev/null | head -1)
            [[ "$filter6_prio" =~ ^-?[0-9]+$ ]] || filter6_prio="UNKNOWN"

            if [[ ! "$actual_nftban_prio" =~ ^-?[0-9]+$ || ! "$filter6_prio" =~ ^-?[0-9]+$ ]]; then
                # Priority ordering decides whether a foreign table shadows us.
                # With either priority unread that ordering is unknown, and a
                # numeric compare against UNKNOWN would error rather than decide.
                NFTBAN_FIREWALL_CONFLICTS+=("UNKNOWN: 'ip6 filter' present but a chain priority was unreadable (nftban=$actual_nftban_prio, foreign=$filter6_prio) — shadowing NOT ruled out")
            elif [[ "$filter6_prio" -le "$actual_nftban_prio" ]]; then
                status=2
                NFTBAN_FIREWALL_CONFLICTS+=("CRITICAL: 'ip6 filter' table (priority $filter6_prio) runs before NFTBan")
                [[ $NFTBAN_FIREWALL_SEVERITY -lt $CONFLICT_CRITICAL ]] && NFTBAN_FIREWALL_SEVERITY=$CONFLICT_CRITICAL
            else
                status=1
                NFTBAN_FIREWALL_CONFLICTS+=("INFO: 'ip6 filter' table exists (priority $filter6_prio) - NFTBan runs first (safe)")
                [[ $NFTBAN_FIREWALL_SEVERITY -lt $CONFLICT_INFO ]] && NFTBAN_FIREWALL_SEVERITY=$CONFLICT_INFO
            fi
        else
            [[ $status -eq 0 ]] && status=1
            NFTBAN_FIREWALL_CONFLICTS+=("INFO: 'ip6 filter' table exists but has no hooks (harmless)")
            [[ $NFTBAN_FIREWALL_SEVERITY -lt $CONFLICT_INFO ]] && NFTBAN_FIREWALL_SEVERITY=$CONFLICT_INFO
        fi
    fi

    # 3. firewalld tables (always critical - it manages the entire firewall)
    if echo "$tables" | grep -q "^table inet firewalld"; then
        status=2
        NFTBAN_FIREWALL_CONFLICTS+=("CRITICAL: firewalld table exists - conflicts with NFTBan")
        NFTBAN_FIREWALL_CONFLICTS+=("  └─ FIX: systemctl stop firewalld && systemctl disable firewalld")
        [[ $NFTBAN_FIREWALL_SEVERITY -lt $CONFLICT_CRITICAL ]] && NFTBAN_FIREWALL_SEVERITY=$CONFLICT_CRITICAL
    fi

    # 4. Check for INPUT chain priority conflicts (non-nftban chains only)
    # v1.18.0: nftban uses priority 0 for input in both ip/ip6 nftban tables
    # We need to detect if OTHER tables have INPUT chains that might conflict
    local non_nftban_input_chains
    non_nftban_input_chains=""

    # Get tables and check each one for input chains
    local table_line
    while IFS= read -r table_line; do
        [[ -z "$table_line" ]] && continue
        # Skip nftban tables (ip nftban, ip6 nftban)
        if [[ "$table_line" == *"nftban"* ]]; then
            continue
        fi
        # Check if this non-nftban table has an input chain
        local table_input
        table_input=$(nft list table $table_line 2>/dev/null | grep -E "hook input.*priority" || true)
        if [[ -n "$table_input" ]]; then
            non_nftban_input_chains+="$table_line: $table_input"$'\n'
        fi
    done < <(echo "$tables" | sed 's/^table //' 2>/dev/null || true)

    if [[ -n "$non_nftban_input_chains" ]]; then
        local other_priorities
        other_priorities=$(echo "$non_nftban_input_chains" | grep -oE "priority [^;]+" | sort -u || echo "")
        if [[ -n "$other_priorities" ]]; then
            NFTBAN_FIREWALL_CONFLICTS+=("INPUT CHAINS: Non-nftban tables have input hooks")
            NFTBAN_FIREWALL_CONFLICTS+=("  └─ Tables: $(echo "$non_nftban_input_chains" | cut -d: -f1 | tr '\n' ' ')")
            [[ $status -eq 0 ]] && status=1
            # Only WARNING if priority could conflict (>= 0)
            local high_prio
            high_prio=$(echo "$other_priorities" | grep -oE '[-0-9]+' | awk '$1 >= 0' | head -1 || true)
            if [[ -n "$high_prio" ]]; then
                [[ $NFTBAN_FIREWALL_SEVERITY -lt $CONFLICT_WARNING ]] && NFTBAN_FIREWALL_SEVERITY=$CONFLICT_WARNING
            else
                [[ $NFTBAN_FIREWALL_SEVERITY -lt $CONFLICT_INFO ]] && NFTBAN_FIREWALL_SEVERITY=$CONFLICT_INFO
            fi
        fi
    fi

    return $status
}

# =============================================================================
# FIREWALLD DETECTION
# =============================================================================

nftban_detect_firewalld() {
    # Detect firewalld status
    # Returns: 0=not found, 1=enabled, 2=active

    local status=0

    if ! command -v firewall-cmd &>/dev/null; then
        return 0
    fi

    if systemctl is-active --quiet firewalld 2>/dev/null; then
        status=2
        NFTBAN_FIREWALL_CONFLICTS+=("FIREWALLD: ACTIVE - Critical conflict with nftban")
        NFTBAN_FIREWALL_FIXES+=("Disable firewalld:")
        NFTBAN_FIREWALL_FIXES+=("  systemctl stop firewalld && systemctl disable firewalld")
        [[ $NFTBAN_FIREWALL_SEVERITY -lt $CONFLICT_CRITICAL ]] && NFTBAN_FIREWALL_SEVERITY=$CONFLICT_CRITICAL
    elif systemctl is-enabled --quiet firewalld 2>/dev/null; then
        status=1
        NFTBAN_FIREWALL_CONFLICTS+=("FIREWALLD: Enabled but not running")
        NFTBAN_FIREWALL_FIXES+=("Disable firewalld to prevent future conflicts:")
        NFTBAN_FIREWALL_FIXES+=("  systemctl disable firewalld")
        [[ $NFTBAN_FIREWALL_SEVERITY -lt $CONFLICT_WARNING ]] && NFTBAN_FIREWALL_SEVERITY=$CONFLICT_WARNING
    fi

    return $status
}

# =============================================================================
# UFW DETECTION
# =============================================================================

nftban_detect_ufw() {
    # Detect ufw status
    # Returns: 0=not found, 1=installed inactive, 2=active
    # v1.23.0 FIX (P0-4): Use systemctl is-active as primary check (matches postinst behavior)
    # `command -v ufw` finds the binary even when UFW is completely disabled/inactive

    local status=0

    # Primary check: is the service actually running?
    if systemctl is-active ufw.service &>/dev/null; then
        status=2
        NFTBAN_FIREWALL_CONFLICTS+=("UFW: ACTIVE - Critical conflict with nftban")
        NFTBAN_FIREWALL_FIXES+=("Disable ufw:")
        NFTBAN_FIREWALL_FIXES+=("  ufw disable")
        [[ $NFTBAN_FIREWALL_SEVERITY -lt $CONFLICT_CRITICAL ]] && NFTBAN_FIREWALL_SEVERITY=$CONFLICT_CRITICAL
        return $status
    fi

    # Secondary check: binary installed but not active (INFO only)
    if command -v ufw &>/dev/null; then
        status=1
        [[ $NFTBAN_FIREWALL_SEVERITY -lt $CONFLICT_INFO ]] && NFTBAN_FIREWALL_SEVERITY=$CONFLICT_INFO
    fi

    return $status
}

# =============================================================================
# CPANEL / CPHULK DETECTION (SPECIAL CASE)
# =============================================================================

nftban_is_cpanel_environment() {
    # Detect if this is a cPanel server
    # Returns: 0=yes (cPanel), 1=no

    if [[ -d /usr/local/cpanel ]] && [[ -f /usr/local/cpanel/cpanel ]]; then
        return 0
    fi
    return 1
}

nftban_detect_cphulk() {
    # Detect cPHulk (cPanel's brute force protection)
    # NOTE: cPHulk is an EXCEPTION - it's tightly integrated with cPanel
    # and designed to coexist. We report it as INFO, not CRITICAL.
    # Returns: 0=not found, 1=found inactive, 2=found active

    local status=0

    # Only check on cPanel systems
    if ! nftban_is_cpanel_environment; then
        return 0
    fi

    # Check if cPHulk is enabled
    local cphulk_enabled=0
    if [[ -f /var/cpanel/cphulkd.conf ]]; then
        if grep -q "^enable_cphulk=1" /var/cpanel/cphulkd.conf 2>/dev/null; then
            cphulk_enabled=1
        fi
    fi

    # Check if cphulkd is running
    if pgrep -x cphulkd &>/dev/null || systemctl is-active --quiet cphulkd 2>/dev/null; then
        status=2
        NFTBAN_FIREWALL_CONFLICTS+=("CPHULK: Active (cPanel brute-force protection)")
        NFTBAN_FIREWALL_CONFLICTS+=("  └─ INFO: cPHulk is designed to coexist with nftban")
        NFTBAN_FIREWALL_CONFLICTS+=("  └─ NFTBan monitors cPHulk logs at: /usr/local/cpanel/logs/cphulkd.log")
        # INFO only - not a conflict requiring action
        [[ $NFTBAN_FIREWALL_SEVERITY -lt $CONFLICT_INFO ]] && NFTBAN_FIREWALL_SEVERITY=$CONFLICT_INFO
    elif [[ $cphulk_enabled -eq 1 ]]; then
        status=1
        NFTBAN_FIREWALL_CONFLICTS+=("CPHULK: Enabled but not running")
        [[ $NFTBAN_FIREWALL_SEVERITY -lt $CONFLICT_INFO ]] && NFTBAN_FIREWALL_SEVERITY=$CONFLICT_INFO
    fi

    return $status
}

# =============================================================================
# CSF / OTHER SECURITY TOOLS
# =============================================================================

nftban_detect_csf() {
    # Detect ConfigServer Firewall (CSF)
    # Returns: 0=not found, 1=installed but disabled, 2=active

    local status=0

    if [[ -f /etc/csf/csf.conf ]] || command -v csf &>/dev/null; then
        status=1

        # Check if CSF is actually ENABLED (not just installed)
        # CSF can be in production mode (TESTING=0) but still disabled
        local csf_enabled=false
        if systemctl is-active lfd &>/dev/null 2>&1; then
            csf_enabled=true
        elif csf -s 2>&1 | grep -q "csf is enabled"; then
            csf_enabled=true
        fi

        if [[ "$csf_enabled" == "true" ]]; then
            # CSF is actually running
            status=2
            if grep -q "^TESTING = \"0\"" /etc/csf/csf.conf 2>/dev/null; then
                NFTBAN_FIREWALL_CONFLICTS+=("CSF: ACTIVE (production mode)")
            else
                NFTBAN_FIREWALL_CONFLICTS+=("CSF: ACTIVE (testing mode)")
            fi
            NFTBAN_FIREWALL_CONFLICTS+=("  └─ CSF uses iptables which conflicts with nftban")
            NFTBAN_FIREWALL_FIXES+=("Disable CSF:")
            NFTBAN_FIREWALL_FIXES+=("  csf -x")
            [[ $NFTBAN_FIREWALL_SEVERITY -lt $CONFLICT_CRITICAL ]] && NFTBAN_FIREWALL_SEVERITY=$CONFLICT_CRITICAL
        else
            # CSF installed but disabled - no conflict
            NFTBAN_FIREWALL_CONFLICTS+=("CSF: Installed but DISABLED (no conflict)")
            # Don't change severity - disabled CSF is not a conflict
        fi
    fi

    return $status
}

# =============================================================================
# MAIN DETECTION FUNCTION
# =============================================================================

nftban_detect_all_conflicts() {
    # Run all conflict detection and return overall severity
    # Returns: CONFLICT_NONE(0), CONFLICT_INFO(1), CONFLICT_WARNING(2), CONFLICT_CRITICAL(3)

    # Reset global state
    NFTBAN_FIREWALL_CONFLICTS=()
    NFTBAN_FIREWALL_FIXES=()
    NFTBAN_FIREWALL_SEVERITY=$CONFLICT_NONE

    # Run all detectors (order matters for reporting)
    nftban_detect_fail2ban || true
    nftban_detect_iptables_nft || true
    nftban_detect_iptables_service || true
    nftban_detect_xt_compat || true
    nftban_detect_conflicting_tables || true
    nftban_detect_firewalld || true
    nftban_detect_ufw || true
    nftban_detect_csf || true
    nftban_detect_cphulk || true  # INFO level only - cPHulk coexists with nftban

    return $NFTBAN_FIREWALL_SEVERITY
}

# =============================================================================
# REPORTING FUNCTIONS
# =============================================================================

nftban_report_conflicts() {
    # Print conflict report to stdout
    # Usage: nftban_report_conflicts [--quiet]

    local quiet="${1:-}"

    if [[ ${#NFTBAN_FIREWALL_CONFLICTS[@]} -eq 0 ]]; then
        [[ "$quiet" != "--quiet" ]] && echo "No firewall conflicts detected"
        return 0
    fi

    echo "=============================================="
    echo "FIREWALL CONFLICT REPORT"
    echo "=============================================="
    echo ""

    # Print conflicts
    for conflict in "${NFTBAN_FIREWALL_CONFLICTS[@]}"; do
        echo "$conflict"
    done

    # Print fixes if any
    if [[ ${#NFTBAN_FIREWALL_FIXES[@]} -gt 0 ]]; then
        echo ""
        echo "RECOMMENDED FIXES:"
        echo "------------------"
        for fix in "${NFTBAN_FIREWALL_FIXES[@]}"; do
            echo "$fix"
        done
    fi

    echo ""
    echo "Severity: $(nftban_severity_to_string $NFTBAN_FIREWALL_SEVERITY)"

    return $NFTBAN_FIREWALL_SEVERITY
}

nftban_severity_to_string() {
    local severity="${1:-0}"
    case $severity in
        0) echo "NONE (OK)" ;;
        1) echo "INFO" ;;
        2) echo "WARNING" ;;
        3) echo "CRITICAL" ;;
        *) echo "UNKNOWN" ;;
    esac
}

# =============================================================================
# SERVICE-ALERTS EMISSION (v1.138 PR-B, SEC-BYPASS-ALERT)
# =============================================================================
# Emit firewall conflict/bypass alerts to service-alerts.log when severity is
# WARNING (2) or CRITICAL (3). No emission for NONE (0) or INFO (1) — INFO is
# the deliberate cPHulk-coexists state and is not a real alert.
#
# Reads (no detector logic here, no kernel reads): the existing globals
#   NFTBAN_FIREWALL_CONFLICTS[]  ("TAG: detail" primary lines + indented
#                                 "  └─ …" sub-lines from nftban_detect_*)
#   NFTBAN_FIREWALL_SEVERITY     CONFLICT_NONE|INFO|WARNING|CRITICAL
#
# Writes (best-effort, never aborts the caller):
#   ${NFTBAN_LOG_DIR}/service-alerts.log              — one deterministic line
#                                                       per primary entry
#   ${NFTBAN_DATA_DIR}/alert_throttle_firewall_<svc>  — last-emit unix timestamp
#   ${NFTBAN_DATA_DIR}/alert_throttle_firewall_<svc>.sev  — last-emit severity
#                                                            (R3 escalation gate)
#   ${NFTBAN_DATA_DIR}/alert_throttle_firewall_<svc>.lock — per-service flock
#                                                            (R1 parallel safety)
#
# Throttle: default 3600s; override via NFTBAN_ALERT_THROTTLE_SECONDS.
# Namespace: `alert_throttle_firewall_<svc>` — distinct from the OnFailure
# worker's `alert_throttle_<unit>` so the two cannot collide.
#
# Audit residuals R1–R7 from V1_138_PR_B_DUPLICATE_ALERT_LOGS_THIRD_AUDIT.md
# are closed in this implementation:
#   R1 — per-service flock around the read/check/emit/write critical section,
#        so two concurrent invocations (timer + manual `nftban health`) cannot
#        both observe a stale throttle and both emit. Falls back lock-free if
#        the `flock` binary is unavailable.
#   R2 — corrupt/non-numeric throttle file content is treated as stale (0).
#   R3 — severity escalation (WARNING→CRITICAL) inside the throttle window
#        re-emits exactly once and stamps the higher severity. The reverse
#        (CRITICAL stays CRITICAL, or CRITICAL→WARNING) stays throttled.
#   R4 — future-dated throttle timestamps (clock skew) are clamped to 0 so
#        the alert is not silently suppressed forever.
#   R5 — same TAG appearing twice in one array is correctly deduped within
#        the run (first entry stamps throttle; second entry hits fresh
#        throttle). Documented + tested.
#   R6 — non-writable log path: the function exits 0 cleanly (best-effort
#        contract preserved).
#   R7 — sanitizer rule below is **firewall-namespace-specific**: it accepts
#        [a-zA-Z0-9_] and collapses everything else (including '-') to '_'.
#        This deliberately differs from the OnFailure worker's regex (which
#        collapses '_' too); both remain namespace-correct because the prefix
#        `alert_throttle_firewall_` already disambiguates from the worker's
#        `alert_throttle_`.
#
# Line format (deterministic, grep-testable, non-metric):
#   [YYYY-MM-DD HH:MM:SS] [SEVERITY] [FW-CONFLICT] service=<name> detail=<short>
nftban_emit_firewall_conflict_alerts() {
    # Guard: severity below WARNING → no alert (INFO covers cPHulk coexists).
    local severity="${NFTBAN_FIREWALL_SEVERITY:-0}"
    [[ "$severity" -ge "${CONFLICT_WARNING:-2}" ]] || return 0
    [[ "${#NFTBAN_FIREWALL_CONFLICTS[@]}" -gt 0 ]] || return 0

    local log_dir data_dir alert_log throttle_secs
    log_dir="${NFTBAN_LOG_DIR:-/var/log/nftban}"
    data_dir="${NFTBAN_DATA_DIR:-/var/lib/nftban}"
    alert_log="${log_dir}/service-alerts.log"
    throttle_secs="${NFTBAN_ALERT_THROTTLE_SECONDS:-3600}"

    local severity_str now timestamp
    severity_str="$(nftban_severity_to_string "$severity")"
    now="$(date +%s)"
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    # R6: soft-fail mkdirs — non-writable log/data dir returns 0 (the contract
    # is "never abort the health check on emitter trouble"). Lab-tested by
    # pointing NFTBAN_LOG_DIR at a read-only /proc/sys path.
    mkdir -p "$log_dir" 2>/dev/null || return 0
    mkdir -p "$data_dir" 2>/dev/null || return 0

    # Detect flock once per invocation. If absent, fall back to lock-free
    # best-effort emission (race-prone — accepted for hosts without util-linux).
    local _have_flock=0
    if command -v flock >/dev/null 2>&1; then
        _have_flock=1
    fi

    local entry tag detail svc key throttle_file sev_file
    for entry in "${NFTBAN_FIREWALL_CONFLICTS[@]}"; do
        # Skip indented sub-entries ("  └─ …", "  CRITICAL: …" produced by
        # detectors as continuation lines) — only primary "TAG: detail" lines.
        [[ "$entry" =~ ^[[:space:]] ]] && continue

        # Primary line shape: "TAG: detail" where TAG is uppercase + [-_0-9].
        if [[ "$entry" =~ ^([A-Z][A-Z0-9_-]*):[[:space:]]+(.+)$ ]]; then
            tag="${BASH_REMATCH[1]}"
            detail="${BASH_REMATCH[2]}"
        else
            continue
        fi

        svc="${tag,,}"
        # R7: firewall-namespace sanitizer (keeps underscore; see header).
        key="${svc//[^a-zA-Z0-9_]/_}"
        throttle_file="${data_dir}/alert_throttle_firewall_${key}"
        sev_file="${throttle_file}.sev"

        # R1: critical section under per-service flock. Subshell so `exit`
        # cleanly releases the lock (FD 9 closes on subshell end). Errors are
        # swallowed by the outer `|| true` so one bad service can't break others.
        (
            if (( _have_flock )); then
                # Non-blocking: another invocation holds this service's lock
                # → skip this service in this run.
                flock -n 9 || exit 2
            fi

            # R2: parse last-emit timestamp; non-numeric / unreadable → stale (0).
            # R4: future-dated last_alert (clock skew) → clamp to 0 (stale).
            local last_alert=0 raw_ts age
            if [[ -f "$throttle_file" ]]; then
                raw_ts="$(cat "$throttle_file" 2>/dev/null || true)"
                if [[ "$raw_ts" =~ ^[0-9]+$ ]]; then
                    last_alert=$raw_ts
                fi
            fi
            if (( last_alert > now )); then
                last_alert=0
            fi

            # R3: parse prior severity; non-numeric / missing → 0.
            local prior_sev=0 raw_sev
            if [[ -f "$sev_file" ]]; then
                raw_sev="$(cat "$sev_file" 2>/dev/null || true)"
                if [[ "$raw_sev" =~ ^[0-9]+$ ]]; then
                    prior_sev=$raw_sev
                fi
            fi

            # Emit decision:
            #   - if age >= throttle_secs: emit (window expired).
            #   - else if severity > prior_sev: emit (escalation override).
            #   - else: throttle (in-window, no escalation).
            age=$(( now - last_alert ))
            if (( age < throttle_secs )) && (( severity <= prior_sev )); then
                exit 3
            fi

            # Deterministic, grep-testable, non-metric line.
            printf '[%s] [%s] [FW-CONFLICT] service=%s detail=%s\n' \
                "$timestamp" "$severity_str" "$svc" "$detail" \
                >> "$alert_log" 2>/dev/null || exit 4

            # Stamp throttle + severity. Failure here is non-fatal — the worst
            # case is a duplicate on the next run.
            echo "$now" > "$throttle_file" 2>/dev/null || true
            echo "$severity" > "$sev_file" 2>/dev/null || true
            exit 0
        ) 9>>"${throttle_file}.lock" 2>/dev/null || true
    done

    return 0
}

nftban_report_conflicts_json() {
    # Output conflict report as JSON
    # Useful for API integration

    local json="{"
    json+="\"severity\":$NFTBAN_FIREWALL_SEVERITY,"
    json+="\"severity_string\":\"$(nftban_severity_to_string $NFTBAN_FIREWALL_SEVERITY)\","

    # Conflicts array
    json+="\"conflicts\":["
    local first=true
    for conflict in "${NFTBAN_FIREWALL_CONFLICTS[@]}"; do
        [[ "$first" == "true" ]] || json+=","
        json+="\"$(echo "$conflict" | sed 's/"/\\"/g')\""
        first=false
    done
    json+="],"

    # Fixes array
    json+="\"fixes\":["
    first=true
    for fix in "${NFTBAN_FIREWALL_FIXES[@]}"; do
        [[ "$first" == "true" ]] || json+=","
        json+="\"$(echo "$fix" | sed 's/"/\\"/g')\""
        first=false
    done
    json+="]"

    json+="}"
    echo "$json"
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_detect_fail2ban
export -f nftban_detect_iptables_nft
export -f nftban_detect_iptables_service
export -f nftban_detect_conflicting_tables
export -f nftban_detect_firewalld
export -f nftban_detect_ufw
export -f nftban_detect_csf
# =============================================================================
# DISTRO DETECTION
# =============================================================================

nftban_detect_distro() {
    # Detect Linux distribution
    # Returns: rhel, debian, arch, unknown

    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release || true
        case "${ID:-}" in
            rhel|centos|rocky|alma|fedora|ol)
                echo "rhel"
                ;;
            debian|ubuntu|linuxmint|pop)
                echo "debian"
                ;;
            arch|manjaro)
                echo "arch"
                ;;
            *)
                # Check ID_LIKE for derivatives
                case "${ID_LIKE:-}" in
                    *rhel*|*fedora*|*centos*)
                        echo "rhel"
                        ;;
                    *debian*|*ubuntu*)
                        echo "debian"
                        ;;
                    *)
                        echo "unknown"
                        ;;
                esac
                ;;
        esac
    else
        echo "unknown"
    fi
}

# shellcheck disable=SC2120  # Function accepts optional args with defaults
nftban_get_pkg_manager() {
    # Get package manager for current distro
    # Returns: dnf, apt, pacman, unknown

    local distro="${1:-$(nftban_detect_distro)}"

    case "$distro" in
        rhel)
            if command -v dnf &>/dev/null; then
                echo "dnf"
            elif command -v yum &>/dev/null; then
                echo "yum"
            else
                echo "unknown"
            fi
            ;;
        debian)
            echo "apt"
            ;;
        arch)
            echo "pacman"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# =============================================================================
# PANEL DETECTION
# =============================================================================

nftban_detect_panel() {
    # Detect which control panel is installed
    # Returns: cpanel, plesk, directadmin, cwp, cyberpanel, hestia, none

    # cPanel
    if [[ -d /usr/local/cpanel ]] && [[ -f /usr/local/cpanel/cpanel ]]; then
        echo "cpanel"
        return 0
    fi

    # Plesk
    if [[ -d /usr/local/psa ]] && command -v plesk &>/dev/null; then
        echo "plesk"
        return 0
    fi

    # DirectAdmin
    if [[ -d /usr/local/directadmin ]] && [[ -f /usr/local/directadmin/directadmin ]]; then
        echo "directadmin"
        return 0
    fi

    # CWP (CentOS Web Panel / Control Web Panel)
    if [[ -d /usr/local/cwpsrv ]]; then
        echo "cwp"
        return 0
    fi

    # CyberPanel
    if [[ -d /usr/local/CyberCP ]]; then
        echo "cyberpanel"
        return 0
    fi

    # HestiaCP
    if [[ -d /usr/local/hestia ]]; then
        echo "hestia"
        return 0
    fi

    # VestaCP
    if [[ -d /usr/local/vesta ]]; then
        echo "vesta"
        return 0
    fi

    echo "none"
    return 0
}

# =============================================================================
# PANEL-SPECIFIC CONFLICT MAPPING (Panel + Distro aware)
# =============================================================================

# Conflict registry: panel_distro -> "firewall1 firewall2 ..."
# Format: CONFLICT_REGISTRY[panel:distro]="fw1 fw2"
declare -gA NFTBAN_CONFLICT_REGISTRY=(
    # Plesk conflicts per distro
    ["plesk:rhel"]="fail2ban firewalld iptables"
    ["plesk:debian"]="fail2ban ufw iptables"
    ["plesk:default"]="fail2ban ufw firewalld iptables"

    # DirectAdmin conflicts per distro
    ["directadmin:rhel"]="csf firewalld iptables"
    ["directadmin:debian"]="csf ufw iptables"
    ["directadmin:default"]="csf firewalld iptables"

    # cPanel conflicts (cPHulk coexists, don't remove)
    ["cpanel:rhel"]="csf firewalld iptables"
    ["cpanel:debian"]="csf ufw iptables"
    ["cpanel:default"]="csf firewalld iptables"

    # CWP conflicts
    ["cwp:rhel"]="csf firewalld iptables"
    ["cwp:debian"]="csf ufw iptables"
    ["cwp:default"]="csf firewalld iptables"

    # CyberPanel conflicts
    ["cyberpanel:rhel"]="firewalld iptables"
    ["cyberpanel:debian"]="ufw iptables"
    ["cyberpanel:default"]="firewalld ufw iptables"

    # HestiaCP conflicts
    ["hestia:rhel"]="firewalld iptables"
    ["hestia:debian"]="ufw iptables"
    ["hestia:default"]="firewalld ufw iptables"

    # VestaCP conflicts
    ["vesta:rhel"]="firewalld iptables"
    ["vesta:debian"]="ufw iptables"
    ["vesta:default"]="firewalld ufw iptables"

    # Generic server (no panel)
    ["none:rhel"]="firewalld fail2ban csf iptables"
    ["none:debian"]="ufw fail2ban csf iptables"
    ["none:default"]="ufw firewalld fail2ban csf iptables"
)

nftban_get_panel_conflicts() {
    # Get list of conflicting firewalls for panel+distro combination
    # Usage: nftban_get_panel_conflicts [panel] [distro]
    # Returns: Space-separated list of conflicting firewalls

    local panel="${1:-$(nftban_detect_panel)}"
    local distro="${2:-$(nftban_detect_distro)}"

    # Try panel:distro first, then panel:default
    local key="${panel}:${distro}"
    if [[ -n "${NFTBAN_CONFLICT_REGISTRY[$key]:-}" ]]; then
        echo "${NFTBAN_CONFLICT_REGISTRY[$key]}"
    else
        key="${panel}:default"
        echo "${NFTBAN_CONFLICT_REGISTRY[$key]:-}"
    fi
}

# =============================================================================
# FIREWALL REMOVAL FUNCTIONS (Distro-aware)
# =============================================================================

# shellcheck disable=SC2120  # Function accepts optional --uninstall flag
nftban_remove_fail2ban() {
    # Remove/disable fail2ban (distro-aware)
    # Usage: nftban_remove_fail2ban [--uninstall]
    # Returns: 0=success, 1=not installed, 2=failed

    local uninstall=false
    [[ "${1:-}" == "--uninstall" ]] && uninstall=true

    if ! command -v fail2ban-client &>/dev/null; then
        return 1
    fi

    echo "Disabling fail2ban..."

    # Flush any bans first
    fail2ban-client unban --all 2>/dev/null || true

    # Stop and disable service
    systemctl stop fail2ban 2>/dev/null || true
    systemctl disable fail2ban 2>/dev/null || true

    # Uninstall if requested
    if [[ "$uninstall" == true ]]; then
        local pkg_mgr
        pkg_mgr=$(nftban_get_pkg_manager)
        case "$pkg_mgr" in
            dnf|yum)
                $pkg_mgr remove -y fail2ban fail2ban-server 2>/dev/null || true
                ;;
            apt)
                apt-get remove -y fail2ban 2>/dev/null || true
                ;;
            pacman)
                pacman -R --noconfirm fail2ban 2>/dev/null || true
                ;;
        esac
        echo "  ✓ fail2ban uninstalled"
    else
        echo "  ✓ fail2ban disabled"
    fi

    return 0
}

# shellcheck disable=SC2120  # Function accepts optional --uninstall flag
nftban_remove_ufw() {
    # Remove/disable ufw (distro-aware)
    # Usage: nftban_remove_ufw [--uninstall]
    # Returns: 0=success, 1=not installed, 2=failed

    local uninstall=false
    [[ "${1:-}" == "--uninstall" ]] && uninstall=true

    if ! command -v ufw &>/dev/null; then
        return 1
    fi

    echo "Disabling ufw..."

    # Disable ufw (flushes rules)
    ufw disable 2>/dev/null || true
    systemctl stop ufw 2>/dev/null || true
    systemctl disable ufw 2>/dev/null || true

    # Uninstall if requested
    if [[ "$uninstall" == true ]]; then
        local pkg_mgr
        pkg_mgr=$(nftban_get_pkg_manager)
        case "$pkg_mgr" in
            apt)
                apt-get remove -y ufw 2>/dev/null || true
                ;;
            pacman)
                pacman -R --noconfirm ufw 2>/dev/null || true
                ;;
        esac
        echo "  ✓ ufw uninstalled"
    else
        echo "  ✓ ufw disabled"
    fi

    return 0
}

# =============================================================================
# CENTRALIZED GHOST TABLE CLEANUP (v1.48.0)
# =============================================================================
# Single shared function for removing non-NFTBan nftables tables.
# Based on LIVE nft state (not package/service detection).
# Idempotent — safe to call from install, update, rebuild, conflict removal.
# =============================================================================

# Known ghost tables left by iptables-nft, firewalld, CSF, fail2ban, etc.
# These are the tables we know are NOT ours and safe to remove.
readonly -a _NFTBAN_KNOWN_GHOST_TABLES=(
    "ip filter"
    "ip6 filter"
    "ip nat"
    "ip6 nat"
    "ip mangle"
    "ip6 mangle"
    # NOTE: "ip raw" and "ip6 raw" are NOT ghost tables — used by NFTBan SYNPROXY
    "ip security"
    "ip6 security"
    "inet firewalld"
    "inet filter"
    # v1.51.1: nftban_install_emergency is NOT a ghost — it protects SSH during postinst
)

nftban_cleanup_ghost_tables() {
    # Remove known ghost nftables tables left by other firewalls.
    # Uses LIVE nft state as source of truth.
    # Args: [--quiet] [--report-only]
    # Returns: 0=clean (nothing found or all removed), 1=tables remain (report-only)
    #
    # v1.48.0: Centralized, idempotent ghost table cleanup.
    # Called from: conflict removal, install, update, rebuild, health repair.

    local quiet=false report_only=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --quiet|-q) quiet=true; shift ;;
            --report-only) report_only=true; shift ;;
            *) shift ;;
        esac
    done

    if ! command -v nft &>/dev/null; then
        [[ "$quiet" == "false" ]] && echo "  nft not found — skipping ghost table cleanup"
        return 0
    fi

    local live_tables removed=0 found=0
    live_tables=$(nft list tables 2>/dev/null) || return 0

    for ghost in "${_NFTBAN_KNOWN_GHOST_TABLES[@]}"; do
        if echo "$live_tables" | grep -qx "table $ghost"; then
            ((found++)) || true
            if [[ "$report_only" == "true" ]]; then
                [[ "$quiet" == "false" ]] && echo "  Ghost table found: $ghost"
            else
                if nft delete table $ghost 2>/dev/null; then
                    ((removed++)) || true
                    [[ "$quiet" == "false" ]] && echo "  Removed ghost table: $ghost"
                else
                    [[ "$quiet" == "false" ]] && echo "  WARNING: Failed to remove ghost table: $ghost"
                fi
            fi
        fi
    done

    if [[ "$found" -eq 0 ]]; then
        [[ "$quiet" == "false" ]] && echo "  No ghost tables found"
    elif [[ "$report_only" == "true" ]]; then
        [[ "$quiet" == "false" ]] && echo "  Found $found ghost table(s) — use nftban firewall repair-conflicts to remove"
        return 1
    else
        [[ "$quiet" == "false" ]] && echo "  Cleaned $removed ghost table(s)"
    fi
    return 0
}

# shellcheck disable=SC2120  # Function accepts optional --quiet flag
nftban_validate_hook_authority() {
    # =========================================================================
    # CANONICAL FIREWALL AUTHORITY CLASSIFIER
    # =========================================================================
    # Single source of truth for hook authority validation.
    # Consumers: postinst, health, CLI status, config doctor.
    # Callers MUST NOT implement separate hook detection — use this function.
    #
    # Inspects LIVE kernel nftables state only. No file/package assumptions.
    # Checks actual base chain hook registrations, not mere table presence.
    #
    # Severity model (explicit, shared across all callers):
    #   OK       (0): Only NFTBan owns input/forward hooks. Clean authority.
    #   INFO     (0): Foreign tables exist but have NO base chains with hooks.
    #                  Typical: empty ip filter from iptables-nft. Harmless.
    #   WARN     (1): Foreign hooked chains exist outside core authority hooks
    #                  (output-only), or partial/uncertain state needs inspection.
    #   CRITICAL (2): Foreign base chains with hook input or hook forward.
    #                  Active competing filtering authority. Must be resolved.
    #
    # NFTBan claims exclusive ownership of: hook input, hook forward.
    # NFTBan does NOT claim exclusive output ownership — output-only foreign
    # hooks are WARN (inspection recommended), not CRITICAL.
    #
    # Args: [--quiet] [--json]
    # Returns: 0=OK/INFO, 1=WARN, 2=CRITICAL
    # Globals set: NFTBAN_HOOK_AUTHORITY_LEVEL (ok|info|warn|critical)
    #              NFTBAN_HOOK_AUTHORITY_DETAILS (array of detail strings)
    #
    # v1.48.0: Post-cleanup validation step (table-existence only).
    # v1.53.0: Hook-aware rewrite — inspects actual base chain hooks.
    #          Empty tables without hooks → INFO, not false CRITICAL.
    #          Forward hook coverage added. Output treated as WARN.

    local quiet=false json=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --quiet|-q) quiet=true ;;
            --json) json=true ;;
        esac
        shift
    done

    # Export globals for callers that need structured results
    # shellcheck disable=SC2034  # Consumed by postinst, health, config doctor
    NFTBAN_HOOK_AUTHORITY_LEVEL="ok"
    NFTBAN_HOOK_AUTHORITY_DETAILS=()

    if ! command -v nft &>/dev/null; then
        NFTBAN_HOOK_AUTHORITY_LEVEL="ok"
        [[ "$json" == "true" ]] && echo '{"authority":"unknown","reason":"nft not found"}'
        return 0
    fi

    local live_tables
    live_tables=$(nft list tables 2>/dev/null) || return 0

    local critical=0 warn=0 info=0
    local -a critical_details=()
    local -a warn_details=()
    local -a info_details=()

    while IFS= read -r table_line; do
        [[ -z "$table_line" ]] && continue
        local tspec="${table_line#table }"

        # Skip NFTBan-owned tables (nftban + SYNPROXY raw tables)
        case "$tspec" in
            "ip nftban"|"ip6 nftban"|"ip raw"|"ip6 raw") continue ;;
        esac

        # Foreign table found — inspect its actual base chains
        local table_content
        table_content=$(nft list table $tspec 2>/dev/null) || continue

        # Parse for base chains with hook registrations
        local has_input=false has_forward=false has_output=false
        # Match "type filter hook input" / "type nat hook input" etc.
        echo "$table_content" | grep -qE "hook[[:space:]]+input" && has_input=true
        echo "$table_content" | grep -qE "hook[[:space:]]+forward" && has_forward=true
        echo "$table_content" | grep -qE "hook[[:space:]]+output" && has_output=true

        if [[ "$has_input" == "true" || "$has_forward" == "true" ]]; then
            # CRITICAL: foreign table has input or forward hooks.
            # This is a competing filtering authority regardless of priority,
            # rule count, or policy. The hook registration itself is the conflict.
            ((critical++)) || true
            local hooks=""
            [[ "$has_input" == "true" ]] && hooks+="input "
            [[ "$has_forward" == "true" ]] && hooks+="forward "
            [[ "$has_output" == "true" ]] && hooks+="output "
            critical_details+=("CRITICAL: '${tspec}' owns hooks: ${hooks}(competing authority)")
            NFTBAN_HOOK_AUTHORITY_DETAILS+=("CRITICAL: '${tspec}' owns hooks: ${hooks}")
        elif [[ "$has_output" == "true" ]]; then
            # WARN: output-only hook. NFTBan does not claim exclusive output
            # ownership, but this warrants inspection — another system is
            # influencing egress filtering.
            ((warn++)) || true
            warn_details+=("WARN: '${tspec}' has output hook (egress — review recommended)")
            NFTBAN_HOOK_AUTHORITY_DETAILS+=("WARN: '${tspec}' has output hook")
        else
            # INFO: table exists but has NO base chains with hooks.
            # Typical: empty 'ip filter' created by iptables-nft on any
            # iptables invocation. Zero filtering impact. Harmless.
            ((info++)) || true
            info_details+=("INFO: '${tspec}' exists, no hooks (harmless residue)")
            NFTBAN_HOOK_AUTHORITY_DETAILS+=("INFO: '${tspec}' no hooks")
        fi
    done <<< "$live_tables"

    # Determine overall level
    local level="ok" retcode=0
    if [[ "$critical" -gt 0 ]]; then
        level="critical"; retcode=2
    elif [[ "$warn" -gt 0 ]]; then
        level="warn"; retcode=1
    elif [[ "$info" -gt 0 ]]; then
        level="info"; retcode=0
    fi
    # shellcheck disable=SC2034  # Consumed by postinst, health, config doctor
    NFTBAN_HOOK_AUTHORITY_LEVEL="$level"

    # JSON output
    if [[ "$json" == "true" ]]; then
        echo -n "{\"authority\":\"${level}\",\"critical\":${critical},\"warn\":${warn},\"info\":${info}"
        if [[ ${#NFTBAN_HOOK_AUTHORITY_DETAILS[@]} -gt 0 ]]; then
            echo -n ",\"details\":["
            local first=true
            for d in "${NFTBAN_HOOK_AUTHORITY_DETAILS[@]}"; do
                [[ "$first" == "true" ]] && first=false || echo -n ","
                echo -n "\"$(echo "$d" | sed 's/"/\\"/g')\""
            done
            echo -n "]"
        fi
        echo "}"
        return $retcode
    fi

    # Text output
    if [[ "$quiet" == "false" ]]; then
        for d in "${critical_details[@]}"; do echo "  $d"; done
        for d in "${warn_details[@]}"; do echo "  $d"; done
        for d in "${info_details[@]}"; do echo "  $d"; done

        case "$level" in
            critical)
                echo "  Hook authority: VIOLATED ($critical foreign input/forward hook(s))"
                echo "  Fix: nftban firewall repair-conflicts"
                ;;
            warn)
                echo "  Hook authority: CLEAR with warnings ($warn foreign output hook(s))"
                ;;
            info)
                echo "  Hook authority: CLEAR (foreign tables have no hooks)"
                ;;
            ok)
                echo "  Hook authority: CLEAR (NFTBan is sole firewall)"
                ;;
        esac
    fi

    return $retcode
}

# shellcheck disable=SC2120  # Function accepts optional --uninstall flag
nftban_remove_firewalld() {
    # Remove/disable firewalld (distro-aware)
    # Usage: nftban_remove_firewalld [--uninstall]
    # Returns: 0=success, 1=not installed, 2=failed

    local uninstall=false
    [[ "${1:-}" == "--uninstall" ]] && uninstall=true

    if ! command -v firewall-cmd &>/dev/null; then
        return 1
    fi

    echo "Disabling firewalld..."

    systemctl stop firewalld 2>/dev/null || true
    systemctl disable firewalld 2>/dev/null || true
    systemctl mask firewalld 2>/dev/null || true

    # Flush any nftables tables created by firewalld
    nft delete table inet firewalld 2>/dev/null || true

    # Uninstall if requested
    if [[ "$uninstall" == true ]]; then
        local pkg_mgr
        pkg_mgr=$(nftban_get_pkg_manager)
        case "$pkg_mgr" in
            dnf|yum)
                $pkg_mgr remove -y firewalld 2>/dev/null || true
                ;;
            pacman)
                pacman -R --noconfirm firewalld 2>/dev/null || true
                ;;
        esac
        echo "  ✓ firewalld uninstalled"
    else
        echo "  ✓ firewalld disabled"
    fi

    return 0
}

# shellcheck disable=SC2120  # Function accepts optional --uninstall flag
nftban_remove_iptables() {
    # Remove/disable iptables services and flush rules
    # Usage: nftban_remove_iptables [--uninstall]
    # Returns: 0=success, 1=not installed, 2=failed

    local uninstall=false
    [[ "${1:-}" == "--uninstall" ]] && uninstall=true

    echo "Disabling iptables..."

    # Stop and disable iptables/ip6tables services
    systemctl stop iptables 2>/dev/null || true
    systemctl disable iptables 2>/dev/null || true
    systemctl stop ip6tables 2>/dev/null || true
    systemctl disable ip6tables 2>/dev/null || true

    # Flush iptables rules (works for both nft and legacy)
    if command -v iptables &>/dev/null; then
        iptables -F 2>/dev/null || true
        iptables -X 2>/dev/null || true
        iptables -t nat -F 2>/dev/null || true
        iptables -t mangle -F 2>/dev/null || true
    fi

    if command -v ip6tables &>/dev/null; then
        ip6tables -F 2>/dev/null || true
        ip6tables -X 2>/dev/null || true
    fi

    # Also flush legacy if exists
    if command -v iptables-legacy &>/dev/null; then
        iptables-legacy -F 2>/dev/null || true
        iptables-legacy -X 2>/dev/null || true
    fi

    # Remove shadow nftables tables created by iptables-nft
    nft delete table ip filter 2>/dev/null || true
    nft delete table ip6 filter 2>/dev/null || true
    nft delete table ip nat 2>/dev/null || true
    nft delete table ip mangle 2>/dev/null || true

    # Uninstall if requested
    if [[ "$uninstall" == true ]]; then
        local pkg_mgr
        pkg_mgr=$(nftban_get_pkg_manager)
        case "$pkg_mgr" in
            dnf|yum)
                $pkg_mgr remove -y iptables-services 2>/dev/null || true
                ;;
            apt)
                apt-get remove -y iptables-persistent 2>/dev/null || true
                ;;
        esac
        echo "  ✓ iptables services uninstalled"
    else
        echo "  ✓ iptables disabled and flushed"
    fi

    return 0
}

# shellcheck disable=SC2120  # Function accepts optional --uninstall flag
nftban_remove_csf() {
    # Remove/disable CSF (ConfigServer Firewall)
    # Usage: nftban_remove_csf [--uninstall]
    # Returns: 0=success, 1=not installed, 2=failed
    #
    # v1.48.0: Handles ALL CSF states (production, testing, disabled-but-installed).
    #          Cleans ghost iptables-nft tables left by CSF regardless of mode.

    local uninstall=false
    [[ "${1:-}" == "--uninstall" ]] && uninstall=true

    if ! command -v csf &>/dev/null && [[ ! -f /etc/csf/csf.conf ]]; then
        return 1
    fi

    echo "Disabling CSF..."

    # Disable CSF (flushes all iptables rules)
    csf -x 2>/dev/null || true

    # Stop lfd (Login Failure Daemon) — regardless of TESTING mode
    systemctl stop lfd 2>/dev/null || true
    systemctl disable lfd 2>/dev/null || true
    systemctl stop csf 2>/dev/null || true
    systemctl disable csf 2>/dev/null || true

    # v1.48.0: Clean ghost nftables tables left by CSF's iptables-nft backend.
    # CSF uses iptables which on modern systems is iptables-nft, creating
    # shadow tables (ip filter, ip nat, etc.) that persist after CSF is disabled.
    echo "  Cleaning ghost nftables tables from CSF..."
    nftban_cleanup_ghost_tables --quiet

    # Uninstall if requested (CSF has its own uninstaller)
    if [[ "$uninstall" == true ]]; then
        if [[ -x /etc/csf/uninstall.sh ]]; then
            /etc/csf/uninstall.sh 2>/dev/null || true
            echo "  ✓ CSF uninstalled"
        else
            echo "  ✓ CSF disabled (uninstall script not found)"
        fi
    else
        echo "  ✓ CSF disabled"
    fi

    return 0
}

# =============================================================================
# MAIN CONFLICT REMOVAL FUNCTION
# =============================================================================

nftban_remove_conflicts() {
    # Remove all conflicting firewalls based on detected panel
    # Usage: nftban_remove_conflicts [--yes] [--panel <panel>]
    # Returns: 0=success, 1=nothing to remove, 2=failed

    local auto_yes=false
    local panel=""
    local removed_count=0

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes|-y)
                auto_yes=true
                shift
                ;;
            --panel)
                panel="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    # Detect panel if not specified
    if [[ -z "$panel" ]]; then
        panel=$(nftban_detect_panel)
    fi

    # Get conflicts for this panel
    local conflicts
    conflicts=$(nftban_get_panel_conflicts "$panel")

    echo "=============================================="
    echo "NFTBan Conflict Removal"
    echo "=============================================="
    echo ""
    echo "Detected panel: $panel"
    echo "Conflicts to check: $conflicts"
    echo ""

    # Check what's actually installed and active
    local to_remove=()

    for fw in $conflicts; do
        case "$fw" in
            fail2ban)
                if systemctl is-active --quiet fail2ban 2>/dev/null; then
                    to_remove+=("fail2ban")
                fi
                ;;
            ufw)
                if command -v ufw &>/dev/null; then
                    local status
                    status=$(ufw status 2>/dev/null | head -1 || echo "")
                    if [[ -n "$status" && "$status" != *"inactive"* ]]; then
                        to_remove+=("ufw")
                    fi
                fi
                ;;
            firewalld)
                if systemctl is-active --quiet firewalld 2>/dev/null; then
                    to_remove+=("firewalld")
                fi
                ;;
            csf)
                # v1.48.0: Trigger on ANY installed CSF — not just TESTING="0".
                # CSF in any mode (production, testing, disabled) leaves ghost
                # iptables-nft tables that conflict with NFTBan.
                if [[ -f /etc/csf/csf.conf ]] || command -v csf &>/dev/null; then
                    to_remove+=("csf")
                fi
                ;;
        esac
    done

    if [[ ${#to_remove[@]} -eq 0 ]]; then
        echo "No active conflicting firewalls found."
        return 1
    fi

    echo "Active conflicts found:"
    for fw in "${to_remove[@]}"; do
        echo "  - $fw"
    done
    echo ""

    # Confirm unless --yes
    if [[ "$auto_yes" != true ]]; then
        echo "These firewalls will be DISABLED (not uninstalled)."
        echo "NFTBan will take over firewall protection."
        echo ""
        read -p "Continue? (yes/no) [no]: " confirm
        if [[ "$confirm" != "yes" && "$confirm" != "y" ]]; then
            echo "Aborted."
            return 0
        fi
    fi

    echo ""
    echo "Removing conflicts..."
    echo ""

    # v1.19.20 FIX: Added || true to prevent set -e failures
    # Remove each conflict
    for fw in "${to_remove[@]}"; do
        case "$fw" in
            fail2ban) nftban_remove_fail2ban && { ((removed_count++)) || true; } ;;
            ufw) nftban_remove_ufw && { ((removed_count++)) || true; } ;;
            firewalld) nftban_remove_firewalld && { ((removed_count++)) || true; } ;;
            iptables) nftban_remove_iptables && { ((removed_count++)) || true; } ;;
            csf) nftban_remove_csf && { ((removed_count++)) || true; } ;;
        esac
    done

    # v1.48.0: Centralized ghost table cleanup after all service removals.
    # Even after services are stopped, ghost nft tables may persist.
    # Source of truth is LIVE nft state, not service/package detection.
    echo ""
    echo "Cleaning ghost nftables tables..."
    nftban_cleanup_ghost_tables

    echo ""
    echo "Validating hook authority..."
    nftban_validate_hook_authority || true

    echo ""
    echo "=============================================="
    echo "Removed $removed_count conflicting firewall(s)"
    echo "=============================================="
    echo ""
    echo "NFTBan is now the primary firewall."
    echo "Run 'nftban health' to verify."
    echo ""

    return 0
}

# =============================================================================
# FIREWALL AUTHORITY (v1.52.0)
# =============================================================================

# Authority state file path
declare -g _NFTBAN_AUTHORITY_FILE="/etc/nftban/.firewall_authority"

nftban_check_firewall_authority() {
    # Check if NFTBan has live firewall authority (hook chain + table + authority file).
    # Returns: "nftban" if authoritative, "" otherwise.
    # This checks LIVE state — not just file presence.

    # NFTBan table must exist (either IPv4 or IPv6)
    if ! nft list table ip nftban &>/dev/null && ! nft list table ip6 nftban &>/dev/null; then
        echo ""
        return 0
    fi

    # NFTBan input hook chain must exist (table alone is not enough — could be half-loaded)
    if ! nft list chain ip nftban input &>/dev/null && ! nft list chain ip6 nftban input &>/dev/null; then
        echo ""
        return 0
    fi

    # Both table + chain exist — NFTBan is authoritative
    # (authority file is secondary confirmation, not required for pre-v1.52 installs)
    echo "nftban"
    return 0
}

nftban_write_authority() {
    # Write the firewall authority state file.
    # Called ONLY after successful firewall activation + verification.
    local _authority="${1:-nftban}"
    local _dir
    _dir=$(dirname "$_NFTBAN_AUTHORITY_FILE")
    [[ -d "$_dir" ]] || mkdir -p "$_dir" 2>/dev/null || true
    local _tmp_auth="${_NFTBAN_AUTHORITY_FILE}.tmp"
    echo "$_authority" > "$_tmp_auth" 2>/dev/null || true
    chmod 644 "$_tmp_auth" 2>/dev/null || true
    mv -f "$_tmp_auth" "$_NFTBAN_AUTHORITY_FILE" 2>/dev/null || true
}

# =============================================================================
# EXPORTS
# =============================================================================

# Distro detection
export -f nftban_detect_distro
export -f nftban_get_pkg_manager

# Panel detection
export -f nftban_detect_panel
export -f nftban_get_panel_conflicts

# Cleanup functions (v1.48.0)
export -f nftban_cleanup_ghost_tables
export -f nftban_validate_hook_authority

# Authority functions (v1.52.0)
export -f nftban_check_firewall_authority
export -f nftban_write_authority

# Removal functions
export -f nftban_remove_fail2ban
export -f nftban_remove_ufw
export -f nftban_remove_firewalld
export -f nftban_remove_iptables
export -f nftban_remove_csf
export -f nftban_remove_conflicts

# Detection functions
export -f nftban_detect_fail2ban
export -f nftban_detect_iptables_nft
export -f nftban_detect_iptables_service
export -f nftban_detect_xt_compat
export -f nftban_detect_conflicting_tables
export -f nftban_detect_firewalld
export -f nftban_detect_ufw
export -f nftban_detect_csf
export -f nftban_is_cpanel_environment
export -f nftban_detect_cphulk
export -f nftban_detect_all_conflicts

# Reporting functions
export -f nftban_report_conflicts
export -f nftban_report_conflicts_json
export -f nftban_severity_to_string
