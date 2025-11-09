#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.32.22 - Maintenance Script (Always Active)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Critical maintenance tasks that run even when NFTBan is disabled
#
# meta:name=maintenance
# meta:type=cron
# meta:header=Maintenance Runner
# meta:version=0.32.22
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

    # Auto-detect current SSH port from sshd_config
    SSH_PORT=22
    if [[ -f "/etc/ssh/sshd_config" ]]; then
        DETECTED_PORT=$(grep -E '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
        if [[ -n "$DETECTED_PORT" ]] && [[ "$DETECTED_PORT" =~ ^[0-9]+$ ]]; then
            SSH_PORT=$DETECTED_PORT
        fi
    fi

    # Check if SSH port is whitelisted
    SSH_WHITELIST="/etc/nftban/ports.d/00-ssh.conf"
    SSH_PORT_STATE="/var/lib/nftban/state/ssh_port_alert.state"

    if [[ -f "$SSH_WHITELIST" ]]; then
        # Check if current SSH port is in whitelist
        if grep -qE "^${SSH_PORT}\|T" "$SSH_WHITELIST" 2>/dev/null; then
            log "INFO" "SSH port check: OK (port $SSH_PORT whitelisted)"
            # Clear alert state if port is now correct
            [[ -f "$SSH_PORT_STATE" ]] && rm -f "$SSH_PORT_STATE"
        else
            # Check if we already alerted about this port change
            if [[ -f "$SSH_PORT_STATE" ]]; then
                LAST_ALERT_PORT=$(cat "$SSH_PORT_STATE" 2>/dev/null || echo "")
                if [[ "$LAST_ALERT_PORT" == "$SSH_PORT" ]]; then
                    # Already alerted about this port, skip alert (no spam)
                    log "INFO" "SSH port $SSH_PORT already updated (waiting for firewall reload)"
                    return 0
                fi
            fi

            # SSH port changed but not whitelisted - AUTO-FIX
            log "WARN" "SSH port changed to $SSH_PORT but not whitelisted!"
            log "INFO" "Auto-updating SSH port whitelist (lockout prevention)..."

            # Backup old whitelist
            cp "$SSH_WHITELIST" "${SSH_WHITELIST}.backup.$(date +%Y%m%d-%H%M%S)"

            # Update whitelist with new SSH port
            cat > "$SSH_WHITELIST" <<EOF
# SSH port auto-updated by maintenance: $(date '+%Y-%m-%d %H:%M:%S')
# DO NOT DELETE - LOCKOUT RISK!
# Port format: PORT|PROTO where PROTO = T(tcp), U(udp), B(both)
${SSH_PORT}|T
EOF
            chmod 644 "$SSH_WHITELIST"

            log "INFO" "✅ SSH port $SSH_PORT added to whitelist"

            # ATOMIC firewall update - only update whitelist, don't touch other rules
            log "INFO" "Atomically updating firewall whitelist for SSH port..."
            if nft list table inet nftban_main >/dev/null 2>&1; then
                # Firewall is active - do atomic whitelist update
                # This only updates the tcp_ports set, not the entire firewall
                if nft list set inet nftban_main tcp_ports >/dev/null 2>&1; then
                    # Use nftban-complete for atomic reload of whitelists only
                    if /usr/sbin/nftban-complete nftables reload-whitelist 2>/dev/null; then
                        log "INFO" "✅ Whitelist atomically updated - SSH port $SSH_PORT now allowed"
                        log "INFO" "⚠️  ALERT: SSH port changed and firewall updated (no lockout risk)"
                    else
                        # Fallback: full reload is safe for whitelists
                        log "WARN" "Atomic reload not available, using safe full reload..."
                        if nftban firewall reload >/dev/null 2>&1; then
                            log "INFO" "✅ Firewall reloaded - SSH port $SSH_PORT now allowed"
                        else
                            log "WARN" "Reload failed - SSH port whitelisted but not yet applied"
                            log "WARN" "Please run manually: nftban firewall reload"
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
            mkdir -p /var/lib/nftban/state
            echo "$SSH_PORT" > "$SSH_PORT_STATE"

            # Send alert if mail is configured (ONLY ONCE)
            if command -v mail &>/dev/null && [[ -f "/etc/nftban/conf.d/mail.conf" ]]; then
                echo "NFTBan Security Alert: SSH port changed to $SSH_PORT, auto-whitelisted and firewall reloaded on $(hostname) at $(date)" | \
                    mail -s "[NFTBan] SSH Port Auto-Updated on $(hostname)" root 2>/dev/null || true
            fi
        fi
    else
        # SSH whitelist missing - create it
        log "WARN" "SSH whitelist missing - creating..."
        mkdir -p /etc/nftban/ports.d
        cat > "$SSH_WHITELIST" <<EOF
# SSH port auto-added during maintenance: $(date '+%Y-%m-%d %H:%M:%S')
# DO NOT DELETE - LOCKOUT RISK!
# Port format: PORT|PROTO where PROTO = T(tcp), U(udp), B(both)
${SSH_PORT}|T
EOF
        chmod 644 "$SSH_WHITELIST"
        log "INFO" "✅ Created SSH whitelist with port $SSH_PORT"
    fi

    # ==========================================================================
    # 2. System IP Monitoring (Lockout Prevention)
    # ==========================================================================
    log "INFO" "[2/4] Checking system IP addresses..."

    IP_ALERT_STATE="/var/lib/nftban/state/ip_change_alert.state"

    # Create system whitelist if missing (CRITICAL FOR LOCKOUT PREVENTION)
    if [[ ! -f "/etc/nftban/whitelist.d/00-system.conf" ]]; then
        log "WARN" "System whitelist missing - creating now (lockout prevention)..."
        mkdir -p /etc/nftban/whitelist.d
        cat > /etc/nftban/whitelist.d/00-system.conf <<'EOF'
# NFTBan System IP Whitelist (Auto-Generated)
# This file contains server IPs and SSH client IPs for lockout prevention
# DO NOT EDIT - Automatically managed by maintenance script
# Generated: $(date)

# Server IPs (from interfaces)
EOF

        # Add all server IPs from interfaces
        ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' | while read -r ip; do
            echo "$ip  # Server IPv4 (auto-detected)" >> /etc/nftban/whitelist.d/00-system.conf
            log "INFO" "Added server IPv4 to whitelist: $ip"
        done

        ip -6 addr show | grep -oP '(?<=inet6\s)[0-9a-f:]+' | grep -v '^::1$' | grep -v '^fe80:' | while read -r ip; do
            echo "$ip  # Server IPv6 (auto-detected)" >> /etc/nftban/whitelist.d/00-system.conf
            log "INFO" "Added server IPv6 to whitelist: $ip"
        done

        # Add SSH client IP if available
        if [[ -n "${SSH_CLIENT:-}" ]]; then
            SSH_IP="${SSH_CLIENT%% *}"
            echo "$SSH_IP  # SSH client IP (auto-detected)" >> /etc/nftban/whitelist.d/00-system.conf
            log "INFO" "Added SSH client IP to whitelist: $SSH_IP"
        fi

        chmod 640 /etc/nftban/whitelist.d/00-system.conf
        chown root:nftban /etc/nftban/whitelist.d/00-system.conf 2>/dev/null || true
        log "INFO" "✅ System whitelist created with all server and client IPs"

        # Reload firewall to apply whitelist
        if nftban firewall reload >/dev/null 2>&1; then
            log "INFO" "✅ Firewall reloaded - system IPs now protected"
        else
            log "WARN" "Firewall reload failed - whitelist created but not yet active"
        fi
    fi

    # Check if system IPs have changed
    if [[ -f "/etc/nftban/whitelist.d/00-system.conf" ]]; then
        # Get current public IPs
        current_ipv4=$(curl -s -4 --max-time 5 ifconfig.me 2>/dev/null || echo "")
        current_ipv6=$(curl -s -6 --max-time 5 ifconfig.me 2>/dev/null || echo "")

        # Check if IPv4 changed
        if [[ -n "$current_ipv4" ]] && ! grep -q "$current_ipv4" /etc/nftban/whitelist.d/00-system.conf 2>/dev/null; then
            # Check if we already alerted about this IP
            if [[ -f "$IP_ALERT_STATE" ]] && grep -q "$current_ipv4" "$IP_ALERT_STATE" 2>/dev/null; then
                # Already alerted about this IP, skip alert (no spam)
                log "INFO" "IPv4 $current_ipv4 already in pending whitelist"
            else
                log "WARN" "System IPv4 changed: $current_ipv4 (not in whitelist)"
                log "INFO" "Auto-adding to whitelist (lockout prevention)..."

                # Auto-add to whitelist
                echo "# Auto-added by maintenance: $(date)" >> /etc/nftban/whitelist.d/00-system.conf
                echo "$current_ipv4" >> /etc/nftban/whitelist.d/00-system.conf
                log "INFO" "✅ Added $current_ipv4 to whitelist"

                # ATOMIC firewall update - only update IP whitelist
                log "INFO" "Atomically adding IP $current_ipv4 to firewall whitelist..."
                if nft list table inet nftban_main >/dev/null 2>&1; then
                    # Firewall is active - directly add IP to whitelist set atomically
                    if nft add element inet nftban_main whitelist_v4 "{ $current_ipv4 }" 2>/dev/null; then
                        log "INFO" "✅ IP $current_ipv4 atomically whitelisted (no lockout risk)"
                    else
                        # Fallback: use full reload if direct add fails
                        log "WARN" "Atomic IP add failed, using safe full reload..."
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
                mkdir -p /var/lib/nftban/state
                echo "$current_ipv4 $(date)" >> "$IP_ALERT_STATE"

                # Send email alert if configured (ONLY ONCE)
                if command -v mail &>/dev/null && [[ -f "/etc/nftban/conf.d/mail.conf" ]]; then
                    echo "NFTBan Security Alert: System IPv4 changed to $current_ipv4, auto-whitelisted and firewall reloaded on $(hostname) at $(date)" | \
                        mail -s "[NFTBan] IP Address Auto-Updated on $(hostname)" root 2>/dev/null || true
                fi
            fi
        fi

        log "INFO" "System IP check: OK"
    else
        log "WARN" "System whitelist not found: /etc/nftban/whitelist.d/00-system.conf"
    fi

    # ==========================================================================
    # 3. Active SSH Session Protection (Auto-Whitelist Logged-In Users)
    # ==========================================================================
    log "INFO" "[3/5] Protecting active SSH sessions..."

    # File to track active SSH IPs with timestamps
    ACTIVE_SSH_WHITELIST="/var/lib/nftban/state/active_ssh_whitelist.state"
    mkdir -p /var/lib/nftban/state

    # Get all current SSH connections (excluding localhost)
    CURRENT_SSH_IPS=$(ss -tn state established '( dport = :22 or sport = :22 )' 2>/dev/null | \
                      awk 'NR>1 {print $5}' | \
                      grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}|([0-9a-f:]+:+)+[0-9a-f]+' | \
                      grep -v '^127\.' | \
                      grep -v '^::1' | \
                      sort -u)

    # Update active SSH whitelist timestamp file
    > "$ACTIVE_SSH_WHITELIST.new"

    if [[ -n "$CURRENT_SSH_IPS" ]]; then
        log "INFO" "Found active SSH connections, auto-whitelisting..."

        for ip in $CURRENT_SSH_IPS; do
            # Add IP to nftables RUNTIME table (temporary whitelist with 4h timeout)
            # Timeout refreshes every 15min while user stays logged in
            if nft list table inet nftban_runtime >/dev/null 2>&1; then
                # Determine if IPv4 or IPv6
                if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    # IPv4 - add/update with 4 hour timeout (refreshed every run)
                    if ! nft list set inet nftban_runtime temp_whitelist_v4 2>/dev/null | grep -q "$ip"; then
                        nft add element inet nftban_runtime temp_whitelist_v4 "{ $ip timeout 4h }" 2>/dev/null && \
                            log "INFO" "✅ Auto-whitelisted active SSH session: $ip (4h timeout, auto-refresh)"
                    else
                        # IP already whitelisted, refresh timeout to 4h
                        nft add element inet nftban_runtime temp_whitelist_v4 "{ $ip timeout 4h }" 2>/dev/null
                    fi
                else
                    # IPv6 - add/update with 4 hour timeout (refreshed every run)
                    if ! nft list set inet nftban_runtime temp_whitelist_v6 2>/dev/null | grep -q "$ip"; then
                        nft add element inet nftban_runtime temp_whitelist_v6 "{ $ip timeout 4h }" 2>/dev/null && \
                            log "INFO" "✅ Auto-whitelisted active SSH session: $ip (4h timeout, auto-refresh)"
                    else
                        # IP already whitelisted, refresh timeout to 4h
                        nft add element inet nftban_runtime temp_whitelist_v6 "{ $ip timeout 4h }" 2>/dev/null
                    fi
                fi
            fi

            # Track this IP with current timestamp (for monitoring)
            echo "$ip $(date +%s)" >> "$ACTIVE_SSH_WHITELIST.new"
        done

        mv "$ACTIVE_SSH_WHITELIST.new" "$ACTIVE_SSH_WHITELIST"
    else
        log "INFO" "No active SSH sessions to protect"
        > "$ACTIVE_SSH_WHITELIST"
    fi

    # Note: Cleanup handled automatically by nftables timeout
    # IPs expire after 4 hours if not refreshed
    log "INFO" "Active SSH session protection: OK (nftables auto-cleanup after 4h)"

    # ==========================================================================
    # 4. Auto-Heal (Fix Permissions, Directories)
    # ==========================================================================
    log "INFO" "[4/5] Running auto-heal..."

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
    # 5. Configuration Validation (Critical Files)
    # ==========================================================================
    log "INFO" "[5/5] Validating critical configuration..."

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
