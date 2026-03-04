#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.0.0 - Maintenance Script (Always Active)
# =============================================================================
# meta:name="maintenance"
# meta:type="script"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Runs critical safety checks (SSH monitoring, autoheal, IP changes)"
# meta:inventory.files=""
# meta:inventory.binaries="systemctl,nft"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_LOG_DIR"
# meta:inventory.config_files="/etc/nftban/nftban.conf"
# meta:inventory.systemd_units="nftban-maintenance.timer"
# meta:inventory.network=""
# meta:inventory.privileges="nft read/write via IPC"
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# IPC CLIENT (Single-Writer Architecture)
# =============================================================================
# All nft WRITE operations go through daemon via IPC
# See: ARCHITECTURE-NFT-POLICY.md

# Source IPC client library
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nft_ipc.sh" ]]; then
    # shellcheck source=/usr/lib/nftban/lib/nft_ipc.sh
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nft_ipc.sh"
else
    echo "FATAL: nft_ipc.sh not found - cannot perform firewall operations" >&2
    exit 1
fi

# Source timestamp library (graceful fallback)
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_timestamp.sh" ]]; then
    # shellcheck source=/usr/lib/nftban/lib/nftban_timestamp.sh
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_timestamp.sh"
fi

# Source file utilities library (graceful fallback)
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_file_utils.sh" ]]; then
    # shellcheck source=/usr/lib/nftban/lib/nftban_file_utils.sh
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_file_utils.sh"
fi
IFS=$'\n\t'
umask 027

# =============================================================================
# CONFIGURATION
# =============================================================================

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" 2>/dev/null || true
# v1.19.0: Source .local override (user customizations survive package updates)
source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf.local" 2>/dev/null || true

# NFTables table names (must match nft_schema.sh)
: "${NFTBAN_TABLE_IPV4:=ip nftban}"
: "${NFTBAN_TABLE_IPV6:=ip6 nftban}"

LOGFILE="${NFTBAN_LOG_DIR}/maintenance.log"
LOCKFILE="${NFTBAN_RUN_DIR}/maintenance.lock"

# =============================================================================
# LOGGING
# =============================================================================

log() {
    local level="$1"
    shift
    # BUG-L65 FIX: Strip ANSI escape codes before writing to log file
    # Terminal output keeps colors, file output is clean
    local msg
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
    echo "$msg"
    echo "$msg" | sed -r 's/\x1B\[[0-9;]*[A-Za-z]//g' >> "$LOGFILE"
}

# =============================================================================
# LOCKING (Prevent concurrent runs)
# =============================================================================
# NOTE: Locking is handled by systemd via flock (see nftban-maintenance.service)
# The flock command wraps this script: flock -n /run/nftban/maintenance.lock
# This means systemd creates the lock file BEFORE the script runs.
# DO NOT add internal lock checks here - they conflict with flock and cause
# "Maintenance already running (lock exists)" false positives.
# =============================================================================

acquire_lock() {
    # Locking handled by systemd flock - just ensure directory exists
    mkdir -p "$(dirname "$LOCKFILE")" 2>/dev/null || true
    # Write PID for debugging (flock already holds the lock)
    echo $$ > "$LOCKFILE" 2>/dev/null || true
}

release_lock() {
    # Lock file released automatically by flock when script exits
    # Just clean up our PID marker
    rm -f "$LOCKFILE" 2>/dev/null || true
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
    log "INFO" "[1/9] Checking SSH port configuration..."

    # Auto-detect current SSH port from sshd_config
    SSH_PORT=22
    if [[ -f "/etc/ssh/sshd_config" ]]; then
        DETECTED_PORT=$(grep -E '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1 || true)
        if [[ -n "$DETECTED_PORT" ]] && [[ "$DETECTED_PORT" =~ ^[0-9]+$ ]]; then
            SSH_PORT=$DETECTED_PORT
        fi
    fi

    # Check if SSH port is whitelisted
    SSH_WHITELIST="${NFTBAN_CONFIG_DIR}/ports.d/00-ssh.conf"
    SSH_PORT_STATE="${NFTBAN_DATA_DIR}/state/ssh_port_alert.state"
    # Track the currently active SSH port (for cleanup when port changes back)
    SSH_PORT_ACTIVE="${NFTBAN_DATA_DIR}/state/ssh_port_active.state"

    if [[ -f "$SSH_WHITELIST" ]]; then
        # Check if current SSH port is in whitelist (format: PORT/PROTOCOL)
        if grep -qE "^${SSH_PORT}/(T|tcp)" "$SSH_WHITELIST" 2>/dev/null; then
            log "INFO" "SSH port check: OK (port $SSH_PORT whitelisted)"
            # Clear alert state if port is now correct
            [[ -f "$SSH_PORT_STATE" ]] && rm -f "$SSH_PORT_STATE"

            # Ensure active port state is current (for future cleanup)
            mkdir -p "${NFTBAN_DATA_DIR}/state"
            echo "$SSH_PORT" > "$SSH_PORT_ACTIVE"
        else
            # Check if we already alerted about this port change
            if [[ -f "$SSH_PORT_STATE" ]]; then
                LAST_ALERT_PORT=$(cat "$SSH_PORT_STATE" 2>/dev/null || echo "")
                if [[ "$LAST_ALERT_PORT" == "$SSH_PORT" ]]; then
                    # Already alerted about this port, skip alert (no spam)
                    # C10 fix: use 'true' instead of 'return 0' to continue remaining maintenance tasks
                    log "INFO" "SSH port $SSH_PORT already updated (waiting for firewall reload)"
                    true
                fi
            fi

            # SSH port changed but not whitelisted - AUTO-FIX
            log "WARN" "SSH port changed to $SSH_PORT but not whitelisted!"
            log "INFO" "Auto-updating SSH port whitelist (lockout prevention)..."

            # Get the OLD SSH port that was auto-added (for cleanup)
            OLD_SSH_PORT=""
            if [[ -f "$SSH_PORT_ACTIVE" ]]; then
                OLD_SSH_PORT=$(cat "$SSH_PORT_ACTIVE" 2>/dev/null || echo "")
                # Validate it's a number and different from current
                if [[ -n "$OLD_SSH_PORT" ]] && [[ "$OLD_SSH_PORT" =~ ^[0-9]+$ ]] && [[ "$OLD_SSH_PORT" != "$SSH_PORT" ]]; then
                    log "INFO" "Detected old SSH port $OLD_SSH_PORT (will be removed from firewall)"
                else
                    OLD_SSH_PORT=""
                fi
            fi

            # Backup old whitelist (use library timestamp with fallback)
            local backup_timestamp
            if declare -f nftban_timestamp_file >/dev/null 2>&1; then
                backup_timestamp=$(nftban_timestamp_file)
            else
                backup_timestamp=$(date +%Y%m%d_%H%M%S)
            fi
            cp "$SSH_WHITELIST" "${SSH_WHITELIST}.backup.${backup_timestamp}"

            # Update whitelist with new SSH port (format: PORT/PROTOCOL)
            cat > "$SSH_WHITELIST" <<EOF
# SSH port auto-updated by maintenance: $(date '+%Y-%m-%d %H:%M:%S')
# DO NOT DELETE - LOCKOUT RISK!
# Port format: PORT/PROTOCOL where PROTOCOL = T/tcp, U/udp, or B/both
${SSH_PORT}/T
EOF
            chmod 644 "$SSH_WHITELIST"

            log "INFO" "SSH port $SSH_PORT added to whitelist"

            # ATOMIC firewall update - only update whitelist, don't touch other rules
            log "INFO" "Atomically updating firewall whitelist for SSH port..."
            if nft list table ${NFTBAN_TABLE_IPV4} >/dev/null 2>&1; then
                # Firewall is active - do atomic whitelist update
                # This only updates the tcp_ports_in set, not the entire firewall
                if nft list set ${NFTBAN_TABLE_IPV4} tcp_ports_in >/dev/null 2>&1; then
                    # FIRST: Add the NEW port (safety - ensure SSH access before removing old)
                    if nft_ipc_add_element "${NFTBAN_TABLE_IPV4}" tcp_ports_in "$SSH_PORT"; then
                        log "INFO" "SSH port $SSH_PORT added to firewall (via daemon)"
                        # Also add to IPv6 table
                        nft_ipc_add_element "${NFTBAN_TABLE_IPV6}" tcp_ports_in "$SSH_PORT" 2>/dev/null || true

                        # THEN: Remove the OLD port if it was auto-added and is different
                        if [[ -n "$OLD_SSH_PORT" ]]; then
                            log "INFO" "Removing old SSH port $OLD_SSH_PORT from firewall..."
                            if nft_ipc_delete_element "${NFTBAN_TABLE_IPV4}" tcp_ports_in "$OLD_SSH_PORT"; then
                                log "INFO" "Old SSH port $OLD_SSH_PORT removed from IPv4 firewall"
                            else
                                log "WARN" "Failed to remove old port $OLD_SSH_PORT from IPv4 (may not exist)"
                            fi
                            # Also remove from IPv6
                            nft_ipc_delete_element "${NFTBAN_TABLE_IPV6}" tcp_ports_in "$OLD_SSH_PORT" 2>/dev/null || true
                        fi

                        log "INFO" "ALERT: SSH port changed and firewall updated (no lockout risk)"
                    else
                        # IPC failed - daemon may be down, try systemctl restart
                        log "WARN" "Daemon IPC failed, restarting nftables service..."
                        if systemctl restart nftables 2>/dev/null; then
                            log "INFO" "Firewall reloaded - SSH port $SSH_PORT now allowed"
                        else
                            log "WARN" "Reload failed - SSH port whitelisted but not yet applied"
                            log "WARN" "Please run: systemctl restart nftables"
                        fi
                    fi
                else
                    log "WARN" "Whitelist sets not found - firewall may need reinitialization"
                fi
            else
                log "WARN" "Firewall not initialized - whitelist updated but not applied"
                log "INFO" "Run 'nftban firewall init' to activate firewall"
            fi

            # Save alert state to prevent spam (only alert once per port change)
            mkdir -p "${NFTBAN_DATA_DIR}/state"
            echo "$SSH_PORT" > "$SSH_PORT_STATE"
            # Update active port state for future cleanup
            echo "$SSH_PORT" > "$SSH_PORT_ACTIVE"

            # Send alert via NFTBan unified mail mechanism (ONLY ONCE)
            if [[ -f "${NFTBAN_CONFIG_DIR}/conf.d/mail.conf" ]]; then
                local alert_msg="NFTBan Security Alert: SSH port changed to $SSH_PORT"
                [[ -n "$OLD_SSH_PORT" ]] && alert_msg+=", old port $OLD_SSH_PORT removed"
                alert_msg+=", auto-whitelisted and firewall reloaded on $(hostname) at $(date)"
                nftban_mail_send "$alert_msg" 2>/dev/null || true
            fi
        fi
    else
        # SSH whitelist missing - create it
        log "WARN" "SSH whitelist missing - creating..."
        mkdir -p "${NFTBAN_CONFIG_DIR}/ports.d"
        cat > "$SSH_WHITELIST" <<EOF
# SSH port auto-added during maintenance: $(date '+%Y-%m-%d %H:%M:%S')
# DO NOT DELETE - LOCKOUT RISK!
# Port format: PORT/PROTOCOL where PROTOCOL = T/tcp, U/udp, or B/both
${SSH_PORT}/T
EOF
        chmod 644 "$SSH_WHITELIST"
        # Track this as the active SSH port
        mkdir -p "${NFTBAN_DATA_DIR}/state"
        echo "$SSH_PORT" > "$SSH_PORT_ACTIVE"
        log "INFO" "Created SSH whitelist with port $SSH_PORT"
    fi

    # ==========================================================================
    # 2. System IP Monitoring (Lockout Prevention)
    # ==========================================================================
    log "INFO" "[2/9] Checking system IP addresses..."

    IP_ALERT_STATE="${NFTBAN_DATA_DIR}/state/ip_change_alert.state"

    # Create system whitelist if missing (CRITICAL FOR LOCKOUT PREVENTION)
    if [[ ! -f "${NFTBAN_CONFIG_DIR}/whitelist.d/00-system.conf" ]]; then
        log "WARN" "System whitelist missing - creating now (lockout prevention)..."
        mkdir -p "${NFTBAN_CONFIG_DIR}/whitelist.d"
        cat > "${NFTBAN_CONFIG_DIR}/whitelist.d/00-system.conf" <<EOF
# NFTBan System IP Whitelist (Auto-Generated)
# This file contains server IPs and SSH client IPs for lockout prevention
# DO NOT EDIT - Automatically managed by maintenance script
# Generated: $(date)

# Server IPs (from interfaces)
EOF

        # Add all server IPs from interfaces
        ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' | while read -r ip; do
            echo "$ip  # Server IPv4 (auto-detected)" >> "${NFTBAN_CONFIG_DIR}/whitelist.d/00-system.conf"
            log "INFO" "Added server IPv4 to whitelist: $ip"
        done || true

        ip -6 addr show | grep -oP '(?<=inet6\s)[0-9a-f:]+' | grep -v '^::1$' | grep -v '^fe80:' | while read -r ip; do
            echo "$ip  # Server IPv6 (auto-detected)" >> "${NFTBAN_CONFIG_DIR}/whitelist.d/00-system.conf"
            log "INFO" "Added server IPv6 to whitelist: $ip"
        done || true

        # Add SSH client IP if available
        if [[ -n "${SSH_CLIENT:-}" ]]; then
            SSH_IP="${SSH_CLIENT%% *}"
            echo "$SSH_IP  # SSH client IP (auto-detected)" >> "${NFTBAN_CONFIG_DIR}/whitelist.d/00-system.conf"
            log "INFO" "Added SSH client IP to whitelist: $SSH_IP"
        fi

        chmod 640 "${NFTBAN_CONFIG_DIR}/whitelist.d/00-system.conf"
        chown root:nftban "${NFTBAN_CONFIG_DIR}/whitelist.d/00-system.conf" 2>/dev/null || true
        log "INFO" "✅ System whitelist created with all server and client IPs"

        # Reload firewall to apply whitelist
        if nftban firewall reload >/dev/null 2>&1; then
            log "INFO" "✅ Firewall reloaded - system IPs now protected"
        else
            log "WARN" "Firewall reload failed - whitelist created but not yet active"
        fi
    fi

    # Check if system IPs have changed
    if [[ -f "${NFTBAN_CONFIG_DIR}/whitelist.d/00-system.conf" ]]; then
        # Get current public IPs
        current_ipv4=$(curl -s -4 --max-time 5 ifconfig.me 2>/dev/null || echo "")
        # shellcheck disable=SC2034  # Reserved for IPv6 monitoring
        current_ipv6=$(curl -s -6 --max-time 5 ifconfig.me 2>/dev/null || echo "")

        # Validate IPv4 format - reject HTTP error messages and non-IP responses
        # Must match exact IPv4 pattern: 1-3 digits, dot, 1-3 digits, dot, 1-3 digits, dot, 1-3 digits
        if [[ -n "$current_ipv4" ]] && ! [[ "$current_ipv4" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            log "WARN" "Invalid IPv4 response from ifconfig.me (got: ${current_ipv4:0:50}...)"
            current_ipv4=""
        fi

        # Check if IPv4 changed
        if [[ -n "$current_ipv4" ]] && ! grep -q "$current_ipv4" "${NFTBAN_CONFIG_DIR}/whitelist.d/00-system.conf" 2>/dev/null; then
            # Check if we already alerted about this IP
            if [[ -f "$IP_ALERT_STATE" ]] && grep -q "$current_ipv4" "$IP_ALERT_STATE" 2>/dev/null; then
                # Already alerted about this IP, skip alert (no spam)
                log "INFO" "IPv4 $current_ipv4 already in pending whitelist"
            else
                log "WARN" "System IPv4 changed: $current_ipv4 (not in whitelist)"
                log "INFO" "Auto-adding to whitelist (lockout prevention)..."

                # Auto-add to whitelist
                echo "# Auto-added by maintenance: $(date)" >> "${NFTBAN_CONFIG_DIR}/whitelist.d/00-system.conf"
                echo "$current_ipv4" >> "${NFTBAN_CONFIG_DIR}/whitelist.d/00-system.conf"
                log "INFO" "✅ Added $current_ipv4 to whitelist"

                # ATOMIC firewall update via daemon IPC (single-writer architecture)
                log "INFO" "Adding IP $current_ipv4 to firewall whitelist via daemon..."
                if nft list table ${NFTBAN_TABLE_IPV4} >/dev/null 2>&1; then
                    # Firewall is active - add IP via IPC
                    if nft_ipc_add_element "${NFTBAN_TABLE_IPV4}" whitelist_ipv4 "$current_ipv4"; then
                        log "INFO" "✅ IP $current_ipv4 whitelisted via daemon (no lockout risk)"
                    else
                        # IPC failed - daemon may be down, use full reload
                        log "WARN" "Daemon IPC failed, using safe full reload..."
                        if nftban firewall reload >/dev/null 2>&1; then
                            log "INFO" "✅ Firewall reloaded - IP $current_ipv4 now protected"
                        else
                            log "WARN" "Reload failed - IP whitelisted in config but not yet active"
                        fi
                    fi
                else
                    log "WARN" "Firewall not initialized - IP whitelist updated but not applied"
                fi

                # Save alert state to prevent spam (only alert once per IP)
                mkdir -p "${NFTBAN_DATA_DIR}/state"
                echo "$current_ipv4 $(date)" >> "$IP_ALERT_STATE"

                # Send email alert if configured (ONLY ONCE)
                if command -v mail &>/dev/null && [[ -f "${NFTBAN_CONFIG_DIR}/conf.d/mail.conf" ]]; then
                    echo "NFTBan Security Alert: System IPv4 changed to $current_ipv4, auto-whitelisted and firewall reloaded on $(hostname) at $(date)" | \
                        mail -s "[NFTBan] IP Address Auto-Updated on $(hostname)" root 2>/dev/null || true
                fi
            fi
        fi

        # v1.19.5: Ensure ALL IPs in 00-system.conf are loaded into nftables sets
        # After reboot, nftables sets are recreated empty — re-sync from file
        while IFS= read -r line; do
            # Strip comments and whitespace
            local entry="${line%%#*}"
            entry="${entry%% *}"
            entry="${entry%%	*}"
            [[ -z "$entry" ]] && continue
            if [[ "$entry" == *:* ]]; then
                # IPv6
                if ! nft get element ip6 nftban whitelist_ipv6 "{ $entry }" &>/dev/null; then
                    if nft add element ip6 nftban whitelist_ipv6 "{ $entry }" 2>/dev/null; then
                        log "INFO" "Re-synced IPv6 to nftables whitelist: $entry"
                    fi
                fi
            elif [[ "$entry" =~ ^[0-9]+\.[0-9]+ ]]; then
                # IPv4
                if ! nft get element ip nftban whitelist_ipv4 "{ $entry }" &>/dev/null; then
                    if nft add element ip nftban whitelist_ipv4 "{ $entry }" 2>/dev/null; then
                        log "INFO" "Re-synced IPv4 to nftables whitelist: $entry"
                    fi
                fi
            fi
        done < "${NFTBAN_CONFIG_DIR}/whitelist.d/00-system.conf"

        log "INFO" "System IP check: OK"
    else
        log "WARN" "System whitelist not found: ${NFTBAN_CONFIG_DIR}/whitelist.d/00-system.conf"
    fi

    # ==========================================================================
    # 3. Active SSH Session Protection (Auto-Whitelist Logged-In Users)
    # ==========================================================================
    log "INFO" "[3/9] Protecting active SSH sessions..."

    # File to track active SSH IPs with timestamps
    ACTIVE_SSH_WHITELIST="${NFTBAN_DATA_DIR}/state/active_ssh_whitelist.state"
    mkdir -p "${NFTBAN_DATA_DIR}/state"

    # Get all current SSH connections (excluding localhost)
    CURRENT_SSH_IPS=$(ss -tn state established '( dport = :22 or sport = :22 )' 2>/dev/null | \
                      awk 'NR>1 {print $5}' | \
                      grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}|([0-9a-f:]+:+)+[0-9a-f]+' | \
                      grep -v '^127\.' | \
                      grep -v '^::1' | \
                      sort -u || true)

    # Update active SSH whitelist timestamp file
    : > "$ACTIVE_SSH_WHITELIST.new"

    if [[ -n "$CURRENT_SSH_IPS" ]]; then
        log "INFO" "Found active SSH connections, auto-whitelisting..."

        for ip in $CURRENT_SSH_IPS; do
            # Add IP to temp_whitelist via daemon IPC (single-writer architecture)
            # Timeout refreshes every 15min while user stays logged in
            # 4h = 14400 seconds
            if nft list table ${NFTBAN_TABLE_IPV4} >/dev/null 2>&1; then
                # Determine if IPv4 or IPv6 and add to temp_whitelist via daemon
                if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    # IPv4 - add/update with 4 hour timeout (refreshed every run)
                    if ! nft list set ${NFTBAN_TABLE_IPV4} temp_whitelist_ipv4 2>/dev/null | grep -q "$ip"; then
                        if nft_ipc_add_element "${NFTBAN_TABLE_IPV4}" temp_whitelist_ipv4 "$ip" 14400; then
                            log "INFO" "✅ Auto-whitelisted active SSH session: $ip (4h timeout, via daemon)"
                        fi
                    else
                        # IP already whitelisted, refresh timeout to 4h via daemon
                        nft_ipc_add_element "${NFTBAN_TABLE_IPV4}" temp_whitelist_ipv4 "$ip" 14400 2>/dev/null || true
                    fi
                else
                    # IPv6 - add/update with 4 hour timeout (refreshed every run)
                    if ! nft list set ${NFTBAN_TABLE_IPV6} temp_whitelist_ipv6 2>/dev/null | grep -q "$ip"; then
                        if nft_ipc_add_element "${NFTBAN_TABLE_IPV6}" temp_whitelist_ipv6 "$ip" 14400; then
                            log "INFO" "✅ Auto-whitelisted active SSH session: $ip (4h timeout, via daemon)"
                        fi
                    else
                        # IP already whitelisted, refresh timeout to 4h via daemon
                        nft_ipc_add_element "${NFTBAN_TABLE_IPV6}" temp_whitelist_ipv6 "$ip" 14400 2>/dev/null || true
                    fi
                fi
            fi

            # Track this IP with current timestamp (for monitoring)
            local current_ts
            if declare -f nftban_timestamp_unix >/dev/null 2>&1; then
                current_ts=$(nftban_timestamp_unix)
            else
                current_ts=$(date +%s)
            fi
            echo "$ip $current_ts" >> "$ACTIVE_SSH_WHITELIST.new"
        done

        mv "$ACTIVE_SSH_WHITELIST.new" "$ACTIVE_SSH_WHITELIST"
    else
        log "INFO" "No active SSH sessions to protect"
        : > "$ACTIVE_SSH_WHITELIST"
    fi

    # Note: Cleanup handled automatically by nftables timeout
    # IPs expire after 4 hours if not refreshed
    log "INFO" "Active SSH session protection: OK (nftables auto-cleanup after 4h)"

    # ==========================================================================
    # 4. Auto-Heal (Fix Permissions, Directories)
    # ==========================================================================
    log "INFO" "[4/9] Running auto-heal..."

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
    # 5. Trend Data Collection (Hourly)
    # ==========================================================================
    # Check if this is an hourly run (first run at minute 00-14)
    local current_minute
    current_minute=$(date +%M)
    if [[ $current_minute -lt 15 ]]; then
        log "INFO" "[5/9] Collecting trend data (hourly)..."

        # Collect stats trend data
        if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_stats.sh" ]]; then
            source "${NFTBAN_LIB_DIR}/core/nftban_stats.sh" 2>/dev/null || true
            if declare -f nftban_stats_trend_collect >/dev/null 2>&1; then
                nftban_stats_trend_collect 2>/dev/null && log "INFO" "Stats trend collected" || true
            fi
        fi

        # Collect watchdog trend data
        if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_watchdog.sh" ]]; then
            source "${NFTBAN_LIB_DIR}/core/nftban_watchdog.sh" 2>/dev/null || true
            if declare -f nftban_watchdog_trend_collect >/dev/null 2>&1; then
                nftban_watchdog_trend_collect 2>/dev/null && log "INFO" "Watchdog trend collected" || true
            fi
            # Comprehensive cleanup of all watchdog/stats directories
            if declare -f nftban_watchdog_cleanup_all >/dev/null 2>&1; then
                local cleanup_count
                cleanup_count=$(nftban_watchdog_cleanup_all 2>/dev/null) || cleanup_count=0
                [[ $cleanup_count -gt 0 ]] && log "INFO" "Cleanup: removed $cleanup_count old files total"
            fi
        fi
    else
        log "INFO" "[5/9] Trend collection: Skipped (not hourly run)"
    fi

    # ==========================================================================
    # 6. Configuration Validation (Critical Files)
    # ==========================================================================
    log "INFO" "[6/9] Validating critical configuration..."

    local config_ok=true

    # Check SSH port whitelist
    if [[ ! -f "${NFTBAN_CONFIG_DIR}/ports.d/00-ssh.conf" ]]; then
        log "ERROR" "SSH port whitelist missing: ${NFTBAN_CONFIG_DIR}/ports.d/00-ssh.conf"
        config_ok=false
    fi

    # Check system whitelist
    if [[ ! -f "${NFTBAN_CONFIG_DIR}/whitelist.d/00-system.conf" ]]; then
        log "WARN" "System whitelist missing: ${NFTBAN_CONFIG_DIR}/whitelist.d/00-system.conf"
        config_ok=false
    fi

    # Check main config
    if [[ ! -f "${NFTBAN_CONFIG_DIR}/nftban.conf" ]]; then
        log "ERROR" "Main config missing: ${NFTBAN_CONFIG_DIR}/nftban.conf"
        config_ok=false
    fi

    if $config_ok; then
        log "INFO" "Configuration validation: OK"
    else
        log "WARN" "Configuration validation: Issues found"
    fi

    # ==========================================================================
    # 7. Portscan Stealth Aggregation (Every 15 min)
    # ==========================================================================
    log "INFO" "[7/9] Running portscan stealth aggregation..."

    # Load portscan module for aggregation
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_portscan_classic.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/core/nftban_portscan_classic.sh" 2>/dev/null || true

        # Run aggregation if function exists
        if declare -f nftban_portscan_aggregate >/dev/null 2>&1; then
            if nftban_portscan_aggregate --since 24h --ban 2>/dev/null; then
                log "INFO" "Portscan aggregation: OK"
            else
                log "WARN" "Portscan aggregation: Issues found"
            fi
        else
            log "INFO" "Portscan aggregation: Skipped (function not available)"
        fi
    else
        log "INFO" "Portscan aggregation: Skipped (module not loaded)"
    fi

    # ==========================================================================
    # 8. Firewall Conflict Drift Detection (Every 15 min)
    # ==========================================================================
    log "INFO" "[8/9] Checking for firewall conflicts (drift guard)..."

    # Load conflict detection library
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_firewall_conflicts.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/core/nftban_firewall_conflicts.sh" 2>/dev/null || true

        # Reset conflict state (these are populated by nftban_detect_all_conflicts)
        NFTBAN_FIREWALL_CONFLICTS=()
        # shellcheck disable=SC2034  # Used by conflict detection library
        NFTBAN_FIREWALL_FIXES=()
        NFTBAN_FIREWALL_SEVERITY=${CONFLICT_NONE:-0}

        # Run all conflict detectors
        if declare -f nftban_detect_all_conflicts >/dev/null 2>&1; then
            nftban_detect_all_conflicts 2>/dev/null || true

            # Check severity (CONFLICT_CRITICAL=3)
            if [[ ${NFTBAN_FIREWALL_SEVERITY:-0} -ge 3 ]]; then
                log "CRITICAL" "Firewall conflicts detected!"
                for conflict in "${NFTBAN_FIREWALL_CONFLICTS[@]}"; do
                    log "WARN" "  $conflict"
                done

                # Read policy from config (default: alert)
                local drift_policy="${NFTBAN_DRIFT_POLICY:-alert}"

                case "$drift_policy" in
                    auto)
                        log "INFO" "DRIFT_POLICY=auto - Auto-disabling conflicts..."
                        # Use existing removal functions
                        for conflict in "${NFTBAN_FIREWALL_CONFLICTS[@]}"; do
                            case "$conflict" in
                                *CSF*|*LFD*)
                                    declare -f nftban_remove_csf >/dev/null 2>&1 && nftban_remove_csf 2>/dev/null || true
                                    ;;
                                *UFW*)
                                    declare -f nftban_remove_ufw >/dev/null 2>&1 && nftban_remove_ufw 2>/dev/null || true
                                    ;;
                                *firewalld*|*FIREWALLD*)
                                    declare -f nftban_remove_firewalld >/dev/null 2>&1 && nftban_remove_firewalld 2>/dev/null || true
                                    ;;
                                *fail2ban*|*FAIL2BAN*)
                                    declare -f nftban_remove_fail2ban >/dev/null 2>&1 && nftban_remove_fail2ban 2>/dev/null || true
                                    ;;
                            esac
                        done
                        log "INFO" "Conflicts auto-disabled"
                        ;;
                    alert)
                        log "WARN" "DRIFT_POLICY=alert - Admin action required!"
                        log "WARN" "Run: nftban health conflicts --fix"
                        # Send alert if mail configured
                        if declare -f nftban_mail_send >/dev/null 2>&1; then
                            nftban_mail_send "NFTBan DRIFT ALERT: Firewall conflicts detected on $(hostname). Run: nftban health conflicts --fix" 2>/dev/null || true
                        fi
                        ;;
                    quarantine)
                        log "CRITICAL" "DRIFT_POLICY=quarantine - Stopping NFTBan to prevent firewall fight!"
                        systemctl stop nftban 2>/dev/null || true
                        ;;
                    *)
                        log "INFO" "DRIFT_POLICY=$drift_policy - No action taken"
                        ;;
                esac
            else
                log "INFO" "Firewall conflict check: OK (no conflicts)"
            fi
        else
            log "WARN" "Conflict detection function not available"
        fi
    else
        log "INFO" "Conflict detection: Skipped (library not found)"
    fi

    # ==========================================================================
    # 9. Complete
    # ==========================================================================
    log "INFO" "[9/9] NFTBan Maintenance Complete"

    return 0
}

# =============================================================================
# RUN
# =============================================================================

main "$@"
