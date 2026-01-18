#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0 - Firewall Conflict Detection Library
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Detect and report conflicting firewall systems
#
# meta:name="nftban_firewall_conflicts"
# meta:type="lib"
# meta:header="Firewall Conflict Detection"
# meta:version="1.0.0"
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

# Prevent double-loading
[[ -n "${_NFTBAN_FIREWALL_CONFLICTS_LOADED:-}" ]] && return 0
_NFTBAN_FIREWALL_CONFLICTS_LOADED=1

# =============================================================================
# CONFLICT SEVERITY LEVELS
# =============================================================================
declare -g CONFLICT_NONE=0
declare -g CONFLICT_INFO=1
declare -g CONFLICT_WARNING=2
declare -g CONFLICT_CRITICAL=3

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
            NFTBAN_FIREWALL_FIXES+=("Option 1: Disable fail2ban (recommended)")
            NFTBAN_FIREWALL_FIXES+=("  systemctl stop fail2ban && systemctl disable fail2ban")
            NFTBAN_FIREWALL_FIXES+=("Option 2: Migrate fail2ban jails to nftban")
            NFTBAN_FIREWALL_FIXES+=("  nftban migrate fail2ban")
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
# IPTABLES-NFT DETECTION (Translation Layer)
# =============================================================================

nftban_detect_iptables_nft() {
    # Detect if iptables is using nf_tables backend (iptables-nft)
    # This creates shadow nftables rules that conflict with native nftables
    # Returns: 0=legacy/not found, 1=iptables-nft detected, 2=active rules found

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
        NFTBAN_FIREWALL_CONFLICTS+=("IPTABLES-NFT: System uses iptables-nft translation layer")

        # Check for active iptables rules that create nftables tables
        local rule_count
        rule_count=$(iptables -S 2>/dev/null | grep -cv "^-P" || echo "0")

        if [[ $rule_count -gt 0 ]]; then
            status=2
            NFTBAN_FIREWALL_CONFLICTS+=("  WARNING: $rule_count iptables rules creating shadow nftables")

            # Check if 'ip filter' table exists in nftables (created by iptables-nft)
            if nft list table ip filter &>/dev/null 2>&1; then
                NFTBAN_FIREWALL_CONFLICTS+=("  CRITICAL: 'ip filter' table exists (iptables-nft managed)")
                NFTBAN_FIREWALL_CONFLICTS+=("  └─ This table conflicts with nftban's 'ip nftban' table")

                # Show what's in the filter table
                local chains
                chains=$(nft list table ip filter 2>/dev/null | grep "chain " | awk '{print $2}' | tr '\n' ', ' | sed 's/,$//')
                if [[ -n "$chains" ]]; then
                    NFTBAN_FIREWALL_CONFLICTS+=("  └─ Chains: $chains")
                fi

                [[ $NFTBAN_FIREWALL_SEVERITY -lt $CONFLICT_CRITICAL ]] && NFTBAN_FIREWALL_SEVERITY=$CONFLICT_CRITICAL
            else
                [[ $NFTBAN_FIREWALL_SEVERITY -lt $CONFLICT_WARNING ]] && NFTBAN_FIREWALL_SEVERITY=$CONFLICT_WARNING
            fi

            NFTBAN_FIREWALL_FIXES+=("Flush iptables rules to remove shadow nftables:")
            NFTBAN_FIREWALL_FIXES+=("  iptables -F && iptables -X")
            NFTBAN_FIREWALL_FIXES+=("  ip6tables -F && ip6tables -X")
        fi
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

    # Check for known conflicting tables

    # 1. ip filter (created by iptables-nft or direct iptables usage)
    if echo "$tables" | grep -q "^table ip filter"; then
        status=2
        NFTBAN_FIREWALL_CONFLICTS+=("NFTABLES CONFLICT: 'ip filter' table exists")

        # Check if managed by iptables-nft
        if nft list table ip filter 2>/dev/null | head -5 | grep -q "managed by iptables"; then
            NFTBAN_FIREWALL_CONFLICTS+=("  └─ Managed by iptables-nft (DO NOT manually delete)")
            NFTBAN_FIREWALL_CONFLICTS+=("  └─ Fix: Stop program using iptables commands")
        fi
        [[ $NFTBAN_FIREWALL_SEVERITY -lt $CONFLICT_CRITICAL ]] && NFTBAN_FIREWALL_SEVERITY=$CONFLICT_CRITICAL
    fi

    # 2. ip6 filter
    if echo "$tables" | grep -q "^table ip6 filter"; then
        status=2
        NFTBAN_FIREWALL_CONFLICTS+=("NFTABLES CONFLICT: 'ip6 filter' table exists")
        [[ $NFTBAN_FIREWALL_SEVERITY -lt $CONFLICT_CRITICAL ]] && NFTBAN_FIREWALL_SEVERITY=$CONFLICT_CRITICAL
    fi

    # 3. firewalld tables
    if echo "$tables" | grep -q "^table inet firewalld"; then
        status=2
        NFTBAN_FIREWALL_CONFLICTS+=("NFTABLES CONFLICT: firewalld table exists")
        NFTBAN_FIREWALL_CONFLICTS+=("  └─ FIX: systemctl stop firewalld && systemctl disable firewalld")
        [[ $NFTBAN_FIREWALL_SEVERITY -lt $CONFLICT_CRITICAL ]] && NFTBAN_FIREWALL_SEVERITY=$CONFLICT_CRITICAL
    fi

    # 4. Check for INPUT chain priority conflicts
    # nftban uses priority -150 for input, but other systems might use 0 or lower
    local input_chains
    input_chains=$(nft list chains 2>/dev/null | grep -E "hook input.*priority" || echo "")

    if [[ -n "$input_chains" ]]; then
        # Count input chains
        local chain_count
        chain_count=$(echo "$input_chains" | wc -l)
        if [[ $chain_count -gt 1 ]]; then
            # Multiple INPUT chains - potential conflict
            local other_priorities
            other_priorities=$(echo "$input_chains" | grep -v "nftban" | grep -oE "priority [^;]+" || echo "")
            if [[ -n "$other_priorities" ]]; then
                NFTBAN_FIREWALL_CONFLICTS+=("PRIORITY CONFLICT: Multiple INPUT chains detected")
                NFTBAN_FIREWALL_CONFLICTS+=("  └─ Other priorities: $other_priorities")
                [[ $status -eq 0 ]] && status=1
                [[ $NFTBAN_FIREWALL_SEVERITY -lt $CONFLICT_WARNING ]] && NFTBAN_FIREWALL_SEVERITY=$CONFLICT_WARNING
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

    local status=0

    if ! command -v ufw &>/dev/null; then
        return 0
    fi

    local ufw_status
    ufw_status=$(ufw status 2>/dev/null | head -1 || echo "")

    if [[ "$ufw_status" == *"active"* ]]; then
        status=2
        NFTBAN_FIREWALL_CONFLICTS+=("UFW: ACTIVE - Critical conflict with nftban")
        NFTBAN_FIREWALL_FIXES+=("Disable ufw:")
        NFTBAN_FIREWALL_FIXES+=("  ufw disable")
        [[ $NFTBAN_FIREWALL_SEVERITY -lt $CONFLICT_CRITICAL ]] && NFTBAN_FIREWALL_SEVERITY=$CONFLICT_CRITICAL
    elif [[ "$ufw_status" == *"inactive"* ]]; then
        status=1
        # Just info, inactive ufw is fine
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
    # Returns: 0=not found, 1=installed, 2=active

    local status=0

    if [[ -f /etc/csf/csf.conf ]] || command -v csf &>/dev/null; then
        status=1

        if [[ -f /etc/csf/csf.conf ]] && grep -q "^TESTING = \"0\"" /etc/csf/csf.conf 2>/dev/null; then
            status=2
            NFTBAN_FIREWALL_CONFLICTS+=("CSF: ACTIVE - ConfigServer Firewall detected")
            NFTBAN_FIREWALL_CONFLICTS+=("  └─ CSF uses iptables which conflicts with nftban")
            NFTBAN_FIREWALL_FIXES+=("Disable CSF:")
            NFTBAN_FIREWALL_FIXES+=("  csf -x")
            [[ $NFTBAN_FIREWALL_SEVERITY -lt $CONFLICT_CRITICAL ]] && NFTBAN_FIREWALL_SEVERITY=$CONFLICT_CRITICAL
        else
            NFTBAN_FIREWALL_CONFLICTS+=("CSF: Installed (testing mode or disabled)")
            [[ $NFTBAN_FIREWALL_SEVERITY -lt $CONFLICT_WARNING ]] && NFTBAN_FIREWALL_SEVERITY=$CONFLICT_WARNING
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
export -f nftban_detect_conflicting_tables
export -f nftban_detect_firewalld
export -f nftban_detect_ufw
export -f nftban_detect_csf
export -f nftban_is_cpanel_environment
export -f nftban_detect_cphulk
export -f nftban_detect_all_conflicts
export -f nftban_report_conflicts
export -f nftban_report_conflicts_json
export -f nftban_severity_to_string
