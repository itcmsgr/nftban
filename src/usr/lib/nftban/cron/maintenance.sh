#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.30.0 - Maintenance Script (Always Active)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Critical maintenance tasks that run even when NFTBan is disabled
#
# meta:name=maintenance
# meta:type=cron
# meta:header=Maintenance Runner
# meta:version=0.30.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Runs critical safety checks (SSH monitoring, autoheal, IP changes)
# meta:input=None (runs automatically every 15 minutes)
# meta:output=Logs to journal and /var/log/nftban/maintenance.log
#
# **Inventory & Requirements**
# meta:depends=bash,nftban_health.sh,autoheal.sh
#
# meta:created_date=2025-11-05
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# =============================================================================
# CONFIGURATION
# =============================================================================

NFTBAN_LIB_DIR="${NFTBAN_LIB_DIR:-/usr/lib/nftban}"
LOGFILE="/var/log/nftban/maintenance.log"
LOCKFILE="/run/nftban/maintenance.lock"

# =============================================================================
# LOGGING
# =============================================================================

log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOGFILE"
}

# =============================================================================
# LOCKING (Prevent concurrent runs)
# =============================================================================

acquire_lock() {
    mkdir -p "$(dirname "$LOCKFILE")"

    # Check for stale lock (>30 minutes old)
    if [[ -f "$LOCKFILE" ]]; then
        local lock_age=$(( $(date +%s) - $(stat -c %Y "$LOCKFILE" 2>/dev/null || echo 0) ))
        if [[ $lock_age -gt 1800 ]]; then
            log "WARN" "Removing stale lock (${lock_age}s old)"
            rm -f "$LOCKFILE"
        else
            log "INFO" "Maintenance already running (lock exists)"
            exit 0
        fi
    fi

    # Create lock
    echo $$ > "$LOCKFILE"
}

release_lock() {
    rm -f "$LOCKFILE"
}

trap release_lock EXIT

# =============================================================================
# MAIN MAINTENANCE TASKS
# =============================================================================

main() {
    acquire_lock

    log "INFO" "NFTBan Maintenance Starting"

    # ==========================================================================
    # 1. SSH Port Monitoring (CRITICAL - Lockout Prevention)
    # ==========================================================================
    log "INFO" "[1/4] Checking SSH port configuration..."

    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_health.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/core/nftban_health.sh"

        # Run SSH port check
        if nftban_health_check_ssh_port >/dev/null 2>&1; then
            log "INFO" "SSH port check: OK"
        else
            log "WARN" "SSH port check found issues (check health log)"
        fi
    else
        log "ERROR" "Health module not found: ${NFTBAN_LIB_DIR}/core/nftban_health.sh"
    fi

    # ==========================================================================
    # 2. System IP Monitoring (Lockout Prevention)
    # ==========================================================================
    log "INFO" "[2/4] Checking system IP addresses..."

    # Check if system IPs have changed
    if [[ -f "/etc/nftban/whitelist.d/00-system.conf" ]]; then
        # Get current public IPs
        current_ipv4=$(curl -s -4 --max-time 5 ifconfig.me 2>/dev/null || echo "")
        current_ipv6=$(curl -s -6 --max-time 5 ifconfig.me 2>/dev/null || echo "")

        # Check if IPs are in whitelist
        if [[ -n "$current_ipv4" ]] && ! grep -q "$current_ipv4" /etc/nftban/whitelist.d/00-system.conf 2>/dev/null; then
            log "WARN" "System IPv4 changed: $current_ipv4 (not in whitelist)"
            # Auto-add to whitelist
            echo "# Auto-added by maintenance: $(date)" >> /etc/nftban/whitelist.d/00-system.conf
            echo "$current_ipv4" >> /etc/nftban/whitelist.d/00-system.conf
            log "INFO" "Added $current_ipv4 to whitelist"
        fi

        log "INFO" "System IP check: OK"
    else
        log "WARN" "System whitelist not found: /etc/nftban/whitelist.d/00-system.conf"
    fi

    # ==========================================================================
    # 3. Auto-Heal (Fix Permissions, Directories)
    # ==========================================================================
    log "INFO" "[3/4] Running auto-heal..."

    if [[ -f "${NFTBAN_LIB_DIR}/helpers/autoheal.sh" ]]; then
        if "${NFTBAN_LIB_DIR}/helpers/autoheal.sh" >> "$LOGFILE" 2>&1; then
            log "INFO" "Auto-heal: OK"
        else
            log "WARN" "Auto-heal reported issues (check log)"
        fi
    else
        log "ERROR" "Autoheal script not found: ${NFTBAN_LIB_DIR}/helpers/autoheal.sh"
    fi

    # ==========================================================================
    # 4. Configuration Validation (Critical Files)
    # ==========================================================================
    log "INFO" "[4/4] Validating critical configuration..."

    local config_ok=true

    # Check SSH port whitelist
    if [[ ! -f "/etc/nftban/ports.d/00-ssh.conf" ]]; then
        log "ERROR" "SSH port whitelist missing: /etc/nftban/ports.d/00-ssh.conf"
        config_ok=false
    fi

    # Check system whitelist
    if [[ ! -f "/etc/nftban/whitelist.d/00-system.conf" ]]; then
        log "WARN" "System whitelist missing: /etc/nftban/whitelist.d/00-system.conf"
        config_ok=false
    fi

    # Check main config
    if [[ ! -f "/etc/nftban/nftban.conf" ]]; then
        log "ERROR" "Main config missing: /etc/nftban/nftban.conf"
        config_ok=false
    fi

    if $config_ok; then
        log "INFO" "Configuration validation: OK"
    else
        log "WARN" "Configuration validation: Issues found"
    fi

    # ==========================================================================
    # COMPLETE
    # ==========================================================================
    log "INFO" "NFTBan Maintenance Complete"

    return 0
}

# =============================================================================
# RUN
# =============================================================================

main "$@"
