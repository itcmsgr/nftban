#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.0.0 - Maintenance Script (Always Active)
# =============================================================================
# meta:name="maintenance"
# meta:type="script"
# meta:version="1.39.0"
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
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nft_ipc.sh" || return 1
else
    echo "FATAL: nft_ipc.sh not found - cannot perform firewall operations" >&2
    exit 1
fi

# Source timestamp library (graceful fallback)
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_timestamp.sh" ]]; then
    # shellcheck source=/usr/lib/nftban/lib/nftban_timestamp.sh
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_timestamp.sh" || return 1
fi

# Source file utilities library (graceful fallback)
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_file_utils.sh" ]]; then
    # shellcheck source=/usr/lib/nftban/lib/nftban_file_utils.sh
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_file_utils.sh" || return 1
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

    # v1.32.0: Cache table existence check (avoids 4 redundant kernel calls)
    local _nft_table_available=false
    if nft list table ${NFTBAN_TABLE_IPV4} >/dev/null 2>&1; then
        _nft_table_available=true
    fi

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
            log "INFO" "SSH port check: config OK (port $SSH_PORT whitelisted)"

            # v1.19.20 FIX: Also verify port is in nftables tcp_ports_in set
            # After firewall rebuild, config may be OK but nftables set is empty
            if [[ "$_nft_table_available" == "true" ]]; then
                if ! nft list set ${NFTBAN_TABLE_IPV4} tcp_ports_in 2>/dev/null | grep -qw "$SSH_PORT"; then
                    log "WARN" "SSH port $SSH_PORT in config but NOT in nftables - auto-fixing..."
                    nft_ipc_add_element "${NFTBAN_TABLE_IPV4}" tcp_ports_in "$SSH_PORT" 2>/dev/null || true
                    nft_ipc_add_element "${NFTBAN_TABLE_IPV6}" tcp_ports_in "$SSH_PORT" 2>/dev/null || true
                    log "INFO" "SSH port $SSH_PORT added to nftables tcp_ports_in set"
                fi
            fi

            # Clear alert state if port is now correct (atomic delete - no TOCTOU)
            rm -f "$SSH_PORT_STATE" 2>/dev/null || true

            # Ensure active port state is current (atomic write)
            mkdir -p "${NFTBAN_DATA_DIR}/state" || return 1
            echo "$SSH_PORT" > "${SSH_PORT_ACTIVE}.tmp" && mv -f "${SSH_PORT_ACTIVE}.tmp" "$SSH_PORT_ACTIVE"
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
            if [[ "$_nft_table_available" == "true" ]]; then
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
                log "INFO" "Run 'nftban firewall rebuild' to activate firewall"
            fi

            # Save alert state to prevent spam (only alert once per port change)
            # Use atomic writes to prevent TOCTOU race conditions
            mkdir -p "${NFTBAN_DATA_DIR}/state" || return 1
            echo "$SSH_PORT" > "${SSH_PORT_STATE}.tmp" && mv -f "${SSH_PORT_STATE}.tmp" "$SSH_PORT_STATE"
            # Update active port state for future cleanup (atomic)
            echo "$SSH_PORT" > "${SSH_PORT_ACTIVE}.tmp" && mv -f "${SSH_PORT_ACTIVE}.tmp" "$SSH_PORT_ACTIVE"

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
        mkdir -p "${NFTBAN_CONFIG_DIR}/ports.d" || return 1
        cat > "$SSH_WHITELIST" <<EOF
# SSH port auto-added during maintenance: $(date '+%Y-%m-%d %H:%M:%S')
# DO NOT DELETE - LOCKOUT RISK!
# Port format: PORT/PROTOCOL where PROTOCOL = T/tcp, U/udp, or B/both
${SSH_PORT}/T
EOF
        chmod 644 "$SSH_WHITELIST"
        # Track this as the active SSH port (atomic write)
        mkdir -p "${NFTBAN_DATA_DIR}/state" || return 1
        echo "$SSH_PORT" > "${SSH_PORT_ACTIVE}.tmp" && mv -f "${SSH_PORT_ACTIVE}.tmp" "$SSH_PORT_ACTIVE"
        log "INFO" "Created SSH whitelist with port $SSH_PORT"
    fi

    # ==========================================================================
    # 1b. SYNPROXY Jump Order Check (CRITICAL - SSH Lockout Prevention)
    # ==========================================================================
    # v1.33.0: If DDoS SYNPROXY is enabled, its jump in the input chain MUST be
    # BEFORE 'ct state established,related accept'. Otherwise, notracked packets
    # (from SYNPROXY raw rules) never match conntrack and get dropped by policy,
    # causing SSH lockout for non-whitelisted IPs.
    if [[ "$_nft_table_available" == "true" ]]; then
        local family
        for family in ip ip6; do
            local table_fam="${family} nftban"
            # Check if SYNPROXY jump exists in the chain
            local synproxy_handle established_handle
            synproxy_handle=$(nft -a list chain ${table_fam} input 2>/dev/null \
                | grep 'jump ddos_synproxy' | grep -oP 'handle \K\d+' | head -1 || true)
            established_handle=$(nft -a list chain ${table_fam} input 2>/dev/null \
                | grep 'ct state established,related accept' | grep -oP 'handle \K\d+' | head -1 || true)

            if [[ -n "$synproxy_handle" ]] && [[ -n "$established_handle" ]]; then
                # Both exist — check ordering (lower handle = earlier in chain)
                if [[ "$synproxy_handle" -gt "$established_handle" ]]; then
                    log "WARN" "SYNPROXY jump is AFTER established rule in ${family} — SSH lockout risk!"
                    log "INFO" "Auto-fixing: moving SYNPROXY jump before established rule..."
                    # Remove the misplaced jump
                    nft delete rule ${table_fam} input handle "$synproxy_handle" 2>/dev/null || true
                    # Re-insert before established,related
                    nft insert rule ${table_fam} input position "$established_handle" \
                        jump ddos_synproxy comment "\"SYNPROXY protection\"" 2>/dev/null || {
                        log "WARN" "Failed to reposition SYNPROXY jump in ${family}"
                    }
                    log "INFO" "SYNPROXY jump repositioned in ${family} input chain"
                fi
            fi
        done
    fi

    # ==========================================================================
    # 1c. SYNPROXY vs SSH Port Correlation (CRITICAL - SSH Lockout Prevention)
    # ==========================================================================
    # v1.33.0: SYNPROXY notrack on the SSH port breaks conntrack-based whitelist/
    # blacklist. The DDoS module doesn't know which port SSH uses, so if the SSH
    # port is in the SYNPROXY notrack rules (from old defaults or user config),
    # non-whitelisted IPs get locked out of SSH.
    #
    # This check: if SSH port appears in raw prerouting notrack → remove it and
    # rebuild the raw rules without the SSH port.
    if [[ "$_nft_table_available" == "true" ]] && [[ -n "$SSH_PORT" ]]; then
        local family
        for family in ip ip6; do
            # Check if raw prerouting has a notrack rule that includes the SSH port
            local raw_rule
            raw_rule=$(nft -a list chain ${family} raw prerouting 2>/dev/null \
                | grep -i 'SYNPROXY.*notrack' || true)

            if [[ -n "$raw_rule" ]]; then
                # Check if SSH port is in the port list of this rule
                # The rule looks like: tcp dport { 22, 80, 443, ... } ... notrack
                if echo "$raw_rule" | grep -qwE "(dport ${SSH_PORT}[^0-9]|[{,] *${SSH_PORT}[},[:space:]])"; then
                    log "WARN" "SSH port ${SSH_PORT} found in SYNPROXY notrack rules (${family}) — lockout risk!"
                    log "INFO" "Removing SYNPROXY raw rule containing SSH port..."

                    # Remove the offending rule by handle
                    local raw_handle
                    raw_handle=$(echo "$raw_rule" | grep -oP 'handle \K\d+' | head -1 || true)
                    if [[ -n "$raw_handle" ]]; then
                        nft delete rule ${family} raw prerouting handle "$raw_handle" 2>/dev/null && {
                            log "INFO" "Removed SYNPROXY notrack rule (handle ${raw_handle}) from ${family} raw"

                            # Rebuild the rule WITHOUT the SSH port
                            local old_ports new_ports
                            # Extract port list from the removed rule
                            old_ports=$(echo "$raw_rule" | grep -oP '\{ *\K[^}]+' | tr -d ' ')
                            # Remove SSH port from the list
                            new_ports=$(echo "$old_ports" | tr ',' '\n' | grep -vxF "$SSH_PORT" | tr '\n' ',' | sed 's/,$//')

                            if [[ -n "$new_ports" ]]; then
                                nft add rule ${family} raw prerouting \
                                    tcp dport "{ ${new_ports} }" tcp flags syn / "syn,ack,fin,rst" \
                                    notrack comment "\"SYNPROXY: notrack SYN\"" 2>/dev/null && {
                                    log "INFO" "Rebuilt SYNPROXY notrack in ${family} without SSH port (ports: ${new_ports})"
                                } || {
                                    log "WARN" "Failed to rebuild SYNPROXY notrack in ${family}"
                                }
                            else
                                log "INFO" "No ports remaining for SYNPROXY notrack in ${family} — rule removed"
                            fi
                        } || {
                            log "WARN" "Failed to remove SYNPROXY notrack rule from ${family} raw"
                        }
                    fi
                fi
            fi
        done
    fi

    # ==========================================================================
    # 2. System IP Monitoring (Lockout Prevention)
    # ==========================================================================
    log "INFO" "[2/9] Checking system IP addresses..."

    IP_ALERT_STATE="${NFTBAN_DATA_DIR}/state/ip_change_alert.state"

    # Create system whitelist if missing (CRITICAL FOR LOCKOUT PREVENTION)
    # v1.59.0 SEC-2: Atomic write via temp file to prevent TOCTOU race
    if [[ ! -f "${NFTBAN_CONFIG_DIR}/whitelist.d/00-system.conf" ]]; then
        log "WARN" "System whitelist missing - creating now (lockout prevention)..."
        mkdir -p "${NFTBAN_CONFIG_DIR}/whitelist.d" || return 1
        local _wl_tmp
        _wl_tmp="${NFTBAN_CONFIG_DIR}/whitelist.d/.00-system.conf.tmp.$$"
        cat > "$_wl_tmp" <<EOF
# NFTBan System IP Whitelist (Auto-Generated)
# This file contains server IPs and SSH client IPs for lockout prevention
# DO NOT EDIT - Automatically managed by maintenance script
# Generated: $(date)

# Server IPs (from interfaces)
EOF

        # Add all server IPs from interfaces
        ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' | while read -r ip; do
            echo "$ip  # Server IPv4 (auto-detected)" >> "$_wl_tmp"
            log "INFO" "Added server IPv4 to whitelist: $ip"
        done || true

        ip -6 addr show | grep -oP '(?<=inet6\s)[0-9a-f:]+' | grep -v '^::1$' | grep -v '^fe80:' | while read -r ip; do
            echo "$ip  # Server IPv6 (auto-detected)" >> "$_wl_tmp"
            log "INFO" "Added server IPv6 to whitelist: $ip"
        done || true

        # Add SSH client IP if available
        if [[ -n "${SSH_CLIENT:-}" ]]; then
            SSH_IP="${SSH_CLIENT%% *}"
            echo "$SSH_IP  # SSH client IP (auto-detected)" >> "$_wl_tmp"
            log "INFO" "Added SSH client IP to whitelist: $SSH_IP"
        fi

        # Atomic: set permissions on temp file, then move into place
        chmod 640 "$_wl_tmp"
        chown root:nftban "$_wl_tmp" 2>/dev/null || true
        mv -f "$_wl_tmp" "${NFTBAN_CONFIG_DIR}/whitelist.d/00-system.conf"
        log "INFO" "System whitelist created with all server and client IPs"

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
                if [[ "$_nft_table_available" == "true" ]]; then
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
                mkdir -p "${NFTBAN_DATA_DIR}/state" || return 1
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

            # v1.19.27 SECURITY: Strict IP validation before nft command (defense-in-depth)
            # Prevents command injection if whitelist file is compromised
            if [[ "$entry" == *:* ]]; then
                # IPv6: Only allow hex digits and colons
                if [[ ! "$entry" =~ ^[0-9a-fA-F:]+(/[0-9]+)?$ ]]; then
                    log "WARN" "Skipping invalid IPv6 entry in whitelist: $entry"
                    continue
                fi
                if ! nft get element ip6 nftban whitelist_ipv6 "{ $entry }" &>/dev/null; then
                    # v1.32.0: Route writes through daemon IPC (lock + OpQueue)
                    if nft_ipc_add_element "ip6 nftban" whitelist_ipv6 "$entry" 2>/dev/null; then
                        log "INFO" "Re-synced IPv6 to nftables whitelist: $entry"
                    fi
                fi
            elif [[ "$entry" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]+)?$ ]]; then
                # IPv4: Strict format check (4 octets, optional CIDR)
                if ! nft get element ip nftban whitelist_ipv4 "{ $entry }" &>/dev/null; then
                    # v1.32.0: Route writes through daemon IPC (lock + OpQueue)
                    if nft_ipc_add_element "ip nftban" whitelist_ipv4 "$entry" 2>/dev/null; then
                        log "INFO" "Re-synced IPv4 to nftables whitelist: $entry"
                    fi
                fi
            else
                log "WARN" "Skipping invalid entry in whitelist: $entry"
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
    mkdir -p "${NFTBAN_DATA_DIR}/state" || return 1

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
            # v1.32.0: Simplified — nft_ipc_add_element with timeout is idempotent
            # (upserts: creates if missing, refreshes timeout if exists, 0 kernel reads)
            if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                # IPv4 - add/refresh with 4 hour timeout via daemon IPC
                if nft_ipc_add_element "${NFTBAN_TABLE_IPV4}" temp_whitelist_ipv4 "$ip" 14400 2>/dev/null; then
                    log "INFO" "Auto-whitelisted active SSH session: $ip (4h timeout, via daemon)"
                fi
            else
                # IPv6 - add/refresh with 4 hour timeout via daemon IPC
                if nft_ipc_add_element "${NFTBAN_TABLE_IPV6}" temp_whitelist_ipv6 "$ip" 14400 2>/dev/null; then
                    log "INFO" "Auto-whitelisted active SSH session: $ip (4h timeout, via daemon)"
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
    # 5. Trend Data Collection — REMOVED in v1.46.0
    # ==========================================================================
    # Trend collection + cleanup now handled exclusively by:
    #   - nftban-watchdog.timer (every 2min) — trend collection + cleanup
    #   - Go daemon (stats.CleanupHistory, stats.CleanupProfiles, Recorder.Cleanup)
    # Removed from maintenance to eliminate duplicate execution (L1 audit finding).
    log "INFO" "[5/9] Trend collection: Handled by watchdog timer (skipped)"

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
