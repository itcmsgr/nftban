#!/usr/bin/env bash

# =============================================================================
# NFTBan IP Protection Module
# Version: 0.9.2
# Location: lib/nftban_ipprotect_module.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Automatic protection of server IPs, public IPs, and current user sessions
# =============================================================================

# Strict mode for production-grade security
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_IPPROTECT_LOADED:-}" ]] && return 0
readonly NFTBAN_IPPROTECT_LOADED=1

# =============================================================================
# MODULE CONFIGURATION
# =============================================================================
readonly NFTBAN_IPPROTECT_LOG="${NFTBAN_LOG_DIR}/ip-protection.log"
readonly NFTBAN_PROTECTED_IPS_FILE="${NFTBAN_CONFIG_DIR}/protected-ips.conf"
readonly NFTBAN_AUTO_WHITELIST_FILE="${NFTBAN_CONFIG_DIR}/whitelist-auto.conf"
readonly NFTBAN_SYSTEM_WHITELIST_FILE="${NFTBAN_CONFIG_DIR}/system-whitelist_ips.conf"

# =============================================================================
# IP PROTECTION LOGGING
# =============================================================================

nftban_ipprotect_log() {
    local action="$1"
    local ip="$2"
    local source="$3"
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    
    mkdir -p "$(dirname "$NFTBAN_IPPROTECT_LOG")"
    echo "[${timestamp}] ${action} | ${ip} | ${source}" >> "$NFTBAN_IPPROTECT_LOG"
}

# =============================================================================
# SERVER IP DETECTION
# =============================================================================

# Get all local server IPs (IPv4 and IPv6)
nftban_ipprotect_get_local_ips() {
    local ips=()
    local ip_list=""

    # ==========================================================================
    # METHOD 1: ip command with awk (most reliable)
    # ==========================================================================
    # Get all IPv4 addresses
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        ips+=("$line")
    done < <(ip -4 addr show 2>/dev/null | awk '/inet / {print $2}' | cut -d'/' -f1 | grep -v '^127\.')

    # Get all IPv6 addresses (excluding link-local fe80:: and loopback ::1)
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        ips+=("$line")
    done < <(ip -6 addr show 2>/dev/null | awk '/inet6 / {print $2}' | cut -d'/' -f1 | grep -v '^::1' | grep -v '^fe80:')

    # ==========================================================================
    # METHOD 2: hostname -I (fallback for IPv4)
    # ==========================================================================
    # If no IPs found via ip command, try hostname -I
    if [[ ${#ips[@]} -eq 0 ]]; then
        while IFS= read -r line; do
            [[ -z "$line" || "$line" == "127.0.0.1" || "$line" == "::1" ]] && continue
            # Skip link-local IPv6
            [[ "$line" =~ ^fe80: ]] && continue
            ips+=("$line")
        done < <(hostname -I 2>/dev/null | tr ' ' '\n')
    fi

    # ==========================================================================
    # METHOD 3: ifconfig (legacy fallback)
    # ==========================================================================
    # If still no IPs and ifconfig exists, try that
    if [[ ${#ips[@]} -eq 0 ]] && command -v ifconfig &>/dev/null; then
        # IPv4 from ifconfig
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            ips+=("$line")
        done < <(ifconfig 2>/dev/null | awk '/inet / {print $2}' | grep -v '^127\.')

        # IPv6 from ifconfig
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            ips+=("$line")
        done < <(ifconfig 2>/dev/null | awk '/inet6 / {print $2}' | grep -v '^::1' | grep -v '^fe80:')
    fi

    # ==========================================================================
    # Remove duplicates and output
    # ==========================================================================
    printf '%s\n' "${ips[@]}" | sort -u | grep -v '^$'
}

# Get public IPv4 address
nftban_ipprotect_get_public_ipv4() {
    nftban_get_public_ip "ipv4"
}

# Get public IPv6 address
nftban_ipprotect_get_public_ipv6() {
    nftban_get_public_ip "ipv6"
}

# Get all server IPs (local + public)
nftban_ipprotect_get_all_server_ips() {
    local all_ips=()
    
    # Get local IPs
    while IFS= read -r ip; do
        [[ -n "$ip" ]] && all_ips+=("$ip")
    done < <(nftban_ipprotect_get_local_ips)
    
    # Get public IPv4
    local public_ipv4
    public_ipv4=$(nftban_ipprotect_get_public_ipv4)
    [[ -n "$public_ipv4" ]] && all_ips+=("$public_ipv4")
    
    # Get public IPv6
    local public_ipv6
    public_ipv6=$(nftban_ipprotect_get_public_ipv6)
    [[ -n "$public_ipv6" ]] && all_ips+=("$public_ipv6")
    
    # Remove duplicates and sort
    printf '%s\n' "${all_ips[@]}" | sort -u
}

# Write all system IPs to system-whitelist_ips.conf
nftban_ipprotect_write_system_whitelist() {
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')

    nftban_log_info "Writing system IPs to system-whitelist_ips.conf..."

    # Create temporary file
    local temp_file="${NFTBAN_SYSTEM_WHITELIST_FILE}.tmp"

    # Write header
    cat > "$temp_file" <<'EOF'
# =============================================================================
# NFTBan Template File
# Version: init 1.0
# Template Name: system-whitelist_ips.conf
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Template Directory: /etc/nftban/templates/conf
# User Customization Path: /etc/nftban/config
#
# Description:
# This template stores all system-related IP addresses to be whitelisted.
# It includes:
#   - Loopback IPs (127.0.0.1, ::1)
#   - All public and local IPs detected on the system
#   - Server network interfaces IPs
#
# Behavior:
# - This file is automatically generated and managed by NFTBan scripts.
# - Any manual changes will be overwritten during updates or reinitialization.
# - DO NOT edit this file directly. Use NFTBan's ipprotect module commands.
# - File is refreshed on every: nftban ipprotect update
# - File is refreshed on every: nftban setup
#
# Notes:
# - Ensures system IPs are always trusted and excluded from blocking rules.
# - Regeneration occurs on every NFTBan update or network change detection.
# - These IPs are automatically added to the nftables whitelist set.
# =============================================================================

# Loopback addresses (always included)
127.0.0.1  # IPv4 Loopback
::1        # IPv6 Loopback

# =============================================================================
# System Local IPs (Auto-detected)
# =============================================================================
EOF

    # Get and write local IPs
    local local_count=0
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        echo "$ip  # Local interface - detected at $timestamp" >> "$temp_file"
        ((local_count++)) || true
    done < <(nftban_ipprotect_get_local_ips)

    echo "" >> "$temp_file"
    echo "# =============================================================================" >> "$temp_file"
    echo "# System Public IPs (Auto-detected)" >> "$temp_file"
    echo "# =============================================================================" >> "$temp_file"

    # Get and write public IPv4
    local public_ipv4
    public_ipv4=$(nftban_ipprotect_get_public_ipv4)
    if [[ -n "$public_ipv4" ]]; then
        echo "$public_ipv4  # Public IPv4 - detected at $timestamp" >> "$temp_file"
    else
        echo "# (No public IPv4 detected)" >> "$temp_file"
    fi

    # Get and write public IPv6
    local public_ipv6
    public_ipv6=$(nftban_ipprotect_get_public_ipv6)
    if [[ -n "$public_ipv6" ]]; then
        echo "$public_ipv6  # Public IPv6 - detected at $timestamp" >> "$temp_file"
    else
        echo "# (No public IPv6 detected)" >> "$temp_file"
    fi

    echo "" >> "$temp_file"
    echo "# =============================================================================" >> "$temp_file"
    echo "# Last updated: $timestamp" >> "$temp_file"
    echo "# Total system IPs protected: $local_count local IPs" >> "$temp_file"
    if [[ -n "$public_ipv4" ]]; then
        echo "# Public IPv4: $public_ipv4" >> "$temp_file"
    fi
    if [[ -n "$public_ipv6" ]]; then
        echo "# Public IPv6: $public_ipv6" >> "$temp_file"
    fi
    echo "# =============================================================================" >> "$temp_file"

    # Move temp file to final location
    mv "$temp_file" "$NFTBAN_SYSTEM_WHITELIST_FILE"
    chmod 644 "$NFTBAN_SYSTEM_WHITELIST_FILE"

    nftban_log_success "System whitelist updated: $local_count local IPs"

    return 0
}

# =============================================================================
# CURRENT USER IP DETECTION
# =============================================================================

# Get current SSH user's IP
nftban_ipprotect_get_current_user_ip() {
    nftban_get_current_user_ip
}

# Get all active SSH session IPs
nftban_ipprotect_get_all_ssh_ips() {
    local ssh_ips=()
    
    # Method 1: SSH_CLIENT environment variable
    if [[ -n "${SSH_CLIENT:-}" ]]; then
        local ip="${SSH_CLIENT%% *}"
        [[ -n "$ip" ]] && ssh_ips+=("$ip")
    fi
    
    # Method 2: who command
    while IFS= read -r ip; do
        [[ -z "$ip" || "$ip" == "0.0.0.0" || "$ip" == ":0" ]] && continue
        ssh_ips+=("$ip")
    done < <(who | awk '{print $NF}' | tr -d '()' | grep -v '^:')
    
    # Method 3: last command (currently logged in)
    while IFS= read -r ip; do
        [[ -z "$ip" || "$ip" == "0.0.0.0" ]] && continue
        ssh_ips+=("$ip")
    done < <(last -i 2>/dev/null | grep "still logged in" | awk '{print $3}')
    
    # Method 4: netstat/ss for established SSH connections
    if command -v ss &>/dev/null; then
        while IFS= read -r ip; do
            [[ -z "$ip" ]] && continue
            ssh_ips+=("$ip")
        done < <(ss -tn state established '( dport = :22 or sport = :22 )' 2>/dev/null | \
                 awk '{print $5}' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}|([0-9a-f:]+:+)+[0-9a-f]+' | \
                 cut -d: -f1)
    fi
    
    # Remove duplicates and sort
    printf '%s\n' "${ssh_ips[@]}" | sort -u
}

# =============================================================================
# AUTOMATIC IP PROTECTION
# =============================================================================

# Initialize auto-whitelist file
nftban_ipprotect_init() {
    nftban_log_info "Initializing IP protection system..."
    
    if [[ ! -f "$NFTBAN_AUTO_WHITELIST_FILE" ]]; then
        cat > "$NFTBAN_AUTO_WHITELIST_FILE" << 'EOF'
# =============================================================================
# nftban Auto-Whitelist (Auto-Protected IPs)
# =============================================================================
# This file is automatically managed by the IP protection system
# IPs are automatically added to protect:
#   - Server's local IPs
#   - Server's public IP
#   - Current SSH session IPs
#   - Active user login IPs
# =============================================================================
# DO NOT EDIT MANUALLY - Use: nftban ipprotect update
# =============================================================================

EOF
        chmod 644 "$NFTBAN_AUTO_WHITELIST_FILE"
        nftban_log_success "Created auto-whitelist file"
    fi
    
    if [[ ! -f "$NFTBAN_PROTECTED_IPS_FILE" ]]; then
        cat > "$NFTBAN_PROTECTED_IPS_FILE" << 'EOF'
# =============================================================================
# nftban Protected IPs Reference
# =============================================================================
# This file tracks all auto-protected IPs with their source
# Format: IP_ADDRESS | SOURCE | TIMESTAMP
# =============================================================================

EOF
        chmod 644 "$NFTBAN_PROTECTED_IPS_FILE"
    fi

    # Initialize system-whitelist_ips.conf if it doesn't exist
    if [[ ! -f "$NFTBAN_SYSTEM_WHITELIST_FILE" ]]; then
        nftban_ipprotect_write_system_whitelist
        nftban_log_success "Created system-whitelist_ips.conf"
    fi

    nftban_log_success "IP protection system initialized"
}

# Add IP to auto-whitelist
nftban_ipprotect_add() {
    local ip="$1"
    local source="$2"  # SERVER_LOCAL, SERVER_PUBLIC, SSH_SESSION, etc.
    
    # Validate IP
    nftban_validate_ip "$ip" || return 1
    
    # Check if already in auto-whitelist
    if grep -qE "^${ip}([[:space:]]|$)" "$NFTBAN_AUTO_WHITELIST_FILE" 2>/dev/null; then
        nftban_log_debug "IP already in auto-whitelist: $ip"
        return 0
    fi
    
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    
    # Add to auto-whitelist
    echo "${ip}  # ${source} - ${timestamp}" >> "$NFTBAN_AUTO_WHITELIST_FILE"
    
    # Add to protected IPs reference
    echo "${ip}|${source}|${timestamp}" >> "$NFTBAN_PROTECTED_IPS_FILE"
    
    # Add to whitelist module
    if declare -f nftban_whitelist_add_ip &>/dev/null; then
        nftban_whitelist_add_ip "$ip" "Auto-protected: ${source}"
    fi
    
    nftban_log_success "Auto-protected IP: $ip (${source})"
    nftban_ipprotect_log "PROTECTED" "$ip" "$source"
    
    return 0
}

# Update auto-whitelist with all server and user IPs
nftban_ipprotect_update() {
    nftban_log_info "Updating auto-protected IPs..."
    
    local auto_protect_enabled
    auto_protect_enabled=$(nftban_get_config "NFTBAN_AUTO_PROTECT_IPS" "true")
    
    if [[ "$auto_protect_enabled" != "true" ]]; then
        nftban_log_warning "Auto-protect is disabled in configuration"
        return 0
    fi
    
    local protected_count=0
    
    # Protect localhost
    nftban_ipprotect_add "127.0.0.1" "LOCALHOST_IPV4" && ((protected_count++)) || true
    nftban_ipprotect_add "::1" "LOCALHOST_IPV6" && ((protected_count++)) || true
    
    # Protect server local IPs
    nftban_log_info "  Detecting server local IPs..."
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        nftban_ipprotect_add "$ip" "SERVER_LOCAL" && ((protected_count++)) || true
    done < <(nftban_ipprotect_get_local_ips)
    
    # Protect server public IPs
    nftban_log_info "  Detecting server public IPs..."
    local public_ipv4
    public_ipv4=$(nftban_ipprotect_get_public_ipv4)
    if [[ -n "$public_ipv4" ]]; then
        nftban_ipprotect_add "$public_ipv4" "SERVER_PUBLIC_IPV4" && ((protected_count++)) || true
    fi
    
    local public_ipv6
    public_ipv6=$(nftban_ipprotect_get_public_ipv6)
    if [[ -n "$public_ipv6" ]]; then
        nftban_ipprotect_add "$public_ipv6" "SERVER_PUBLIC_IPV6" && ((protected_count++)) || true
    fi
    
    # Protect current SSH user IP
    nftban_log_info "  Detecting current user IP..."
    local current_user_ip
    current_user_ip=$(nftban_ipprotect_get_current_user_ip)
    if [[ -n "$current_user_ip" ]]; then
        nftban_ipprotect_add "$current_user_ip" "CURRENT_USER" && ((protected_count++)) || true
    fi
    
    # Protect all active SSH session IPs
    local protect_all_ssh
    protect_all_ssh=$(nftban_get_config "NFTBAN_PROTECT_ALL_SSH_SESSIONS" "true")
    
    if [[ "$protect_all_ssh" == "true" ]]; then
        nftban_log_info "  Detecting all SSH session IPs..."
        while IFS= read -r ip; do
            [[ -z "$ip" ]] && continue
            nftban_ipprotect_add "$ip" "SSH_SESSION" && ((protected_count++)) || true
        done < <(nftban_ipprotect_get_all_ssh_ips)
    fi
    
    nftban_log_success "Auto-protection updated: $protected_count IPs protected"

    # Write system IPs to system-whitelist_ips.conf
    nftban_ipprotect_write_system_whitelist

    # Rebuild search index
    if declare -f nftban_search_build_index &>/dev/null; then
        nftban_search_build_index
    fi

    return 0
}

# Force protection of specific IP
nftban_ipprotect_force() {
    local ip="$1"
    local reason="${2:-Manual protection}"
    
    nftban_ipprotect_add "$ip" "MANUAL: ${reason}"
}

# =============================================================================
# PROTECTION STATUS AND LISTING
# =============================================================================

# Check if IP is auto-protected
nftban_ipprotect_is_protected() {
    local ip="$1"
    
    if [[ ! -f "$NFTBAN_AUTO_WHITELIST_FILE" ]]; then
        return 1
    fi
    
    grep -qE "^${ip}([[:space:]]|$)" "$NFTBAN_AUTO_WHITELIST_FILE" 2>/dev/null
}

# Show protected IPs
nftban_ipprotect_list() {
    echo ""
    echo "======================================================="
    echo "  Auto-Protected IPs"
    echo "======================================================="
    echo ""
    
    if [[ ! -f "$NFTBAN_PROTECTED_IPS_FILE" ]]; then
        echo "No protected IPs found"
        return 0
    fi
    
    local count=0
    
    echo "Current Protection Status:"
    echo ""
    printf "%-3s %-40s %-20s %-20s\n" "No." "IP Address" "Source" "Protected At"
    echo "-------------------------------------------------------"
    
    while IFS='|' read -r ip source timestamp; do
        [[ -z "$ip" || "$ip" =~ ^# ]] && continue
        ((count++)) || true
        printf "%-3s %-40s %-20s %-20s\n" "$count" "$ip" "$source" "$timestamp"
    done < "$NFTBAN_PROTECTED_IPS_FILE"
    
    if [[ $count -eq 0 ]]; then
        echo "No protected IPs"
    fi
    
    echo ""
    echo "Total protected: $count IPs"
    echo ""
    echo "======================================================="
}

# Show protection summary
nftban_ipprotect_summary() {
    echo ""
    echo "======================================================="
    echo "  IP Protection Summary"
    echo "======================================================="
    echo ""
    
    local auto_protect
    auto_protect=$(nftban_get_config "NFTBAN_AUTO_PROTECT_IPS" "true")
    echo "Auto-Protection: $auto_protect"
    
    local protect_all_ssh
    protect_all_ssh=$(nftban_get_config "NFTBAN_PROTECT_ALL_SSH_SESSIONS" "true")
    echo "Protect All SSH: $protect_all_ssh"
    echo ""
    
    # Count by source
    if [[ -f "$NFTBAN_PROTECTED_IPS_FILE" ]]; then
        echo "Protected IPs by Source:"
        awk -F'|' '{print $2}' "$NFTBAN_PROTECTED_IPS_FILE" | grep -v '^#' | sort | uniq -c | while read -r count source; do
            printf "  %-30s %3d IPs\n" "$source" "$count"
        done
        echo ""
    fi
    
    echo "Current Server IPs:"
    echo "  Local IPs:"
    nftban_ipprotect_get_local_ips | sed 's/^/    /'
    echo ""
    
    local pub4
    pub4=$(nftban_ipprotect_get_public_ipv4)
    if [[ -n "$pub4" ]]; then
        echo "  Public IPv4: $pub4"
    fi
    
    local pub6
    pub6=$(nftban_ipprotect_get_public_ipv6)
    if [[ -n "$pub6" ]]; then
        echo "  Public IPv6: $pub6"
    fi
    echo ""
    
    echo "Current SSH Sessions:"
    local ssh_count
    ssh_count=$(nftban_ipprotect_get_all_ssh_ips | wc -l)
    echo "  Active sessions: $ssh_count"
    if [[ $ssh_count -gt 0 ]]; then
        nftban_ipprotect_get_all_ssh_ips | sed 's/^/    /'
    fi
    
    echo ""
    echo "======================================================="
}

# =============================================================================
# INSTALLATION AND SETUP
# =============================================================================

# Run initial protection setup
nftban_ipprotect_setup() {
    nftban_log_info "Running IP protection setup..."
    
    # Initialize files
    nftban_ipprotect_init
    
    # Enable auto-protection by default
    nftban_set_config "NFTBAN_AUTO_PROTECT_IPS" "true"
    nftban_set_config "NFTBAN_PROTECT_ALL_SSH_SESSIONS" "true"
    
    # Run initial protection
    nftban_ipprotect_update
    
    nftban_log_success "IP protection setup complete"
    
    echo ""
    echo "IP Protection Configuration:"
    echo "  Auto-protect: ENABLED"
    echo "  Protect SSH sessions: ENABLED"
    echo ""
    echo "Protected IPs:"
    nftban_ipprotect_list
    echo ""
    echo "To update protection:"
    echo "  nftban ipprotect update"
    echo ""
    echo "To disable auto-protection:"
    echo "  nftban config set NFTBAN_AUTO_PROTECT_IPS false"
}

# Add protection check to ban workflow
nftban_ipprotect_check_before_ban() {
    local ip="$1"
    
    # Check if IP is auto-protected
    if nftban_ipprotect_is_protected "$ip"; then
        nftban_log_error "CRITICAL: Cannot ban auto-protected IP: $ip"
        nftban_log_error "This IP is protected (server IP or active SSH session)"
        
        # Log to protection log
        nftban_ipprotect_log "BAN_DENIED" "$ip" "AUTO_PROTECTED"
        
        # Send alert
        local recipient
        recipient=$(nftban_get_config "NFTBAN_EMAIL_RECIPIENT" "")
        if [[ -n "$recipient" ]]; then
            local subject="[nftban] CRITICAL: Attempt to ban protected IP"
            local body="WARNING: An attempt was made to ban a protected IP address

IP Address: $ip
Protection Reason: Auto-protected (server or SSH session)
Time: $(date +'%Y-%m-%d %H:%M:%S')
Server: $(hostname -f)

This IP is automatically protected because it is either:
- A server local IP
- The server's public IP
- An active SSH session IP

Action: Ban request was automatically denied.

If this IP should not be protected, update the protection configuration."
            
            nftban_send_email "$recipient" "$subject" "$body" "critical"
        fi
        
        return 1
    fi
    
    return 0
}

# =============================================================================
# CLEANUP AND MAINTENANCE
# =============================================================================

# Remove stale SSH session IPs
nftban_ipprotect_cleanup_stale() {
    nftban_log_info "Cleaning up stale SSH session protections..."
    
    local current_ssh_ips
    current_ssh_ips=$(nftban_ipprotect_get_all_ssh_ips | sort)
    
    local removed=0
    local temp_file="${NFTBAN_PROTECTED_IPS_FILE}.tmp"
    
    # Keep header
    grep '^#' "$NFTBAN_PROTECTED_IPS_FILE" > "$temp_file"
    
    # Check each protected IP
    while IFS='|' read -r ip source timestamp; do
        [[ -z "$ip" || "$ip" =~ ^# ]] && continue
        
        # If it's an SSH session, check if still active
        if [[ "$source" == "SSH_SESSION" ]]; then
            if ! echo "$current_ssh_ips" | grep -q "^${ip}$"; then
                nftban_log_debug "Removing stale SSH protection: $ip"
                ((removed++)) || true
                continue
            fi
        fi
        
        # Keep this entry
        echo "${ip}|${source}|${timestamp}" >> "$temp_file"
    done < <(grep -v '^#' "$NFTBAN_PROTECTED_IPS_FILE")
    
    mv "$temp_file" "$NFTBAN_PROTECTED_IPS_FILE"
    
    nftban_log_success "Removed $removed stale SSH session protections"
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f nftban_ipprotect_init
export -f nftban_ipprotect_get_local_ips
export -f nftban_ipprotect_get_public_ipv4
export -f nftban_ipprotect_get_public_ipv6
export -f nftban_ipprotect_get_all_server_ips
export -f nftban_ipprotect_write_system_whitelist
export -f nftban_ipprotect_get_current_user_ip
export -f nftban_ipprotect_get_all_ssh_ips
export -f nftban_ipprotect_add
export -f nftban_ipprotect_update
export -f nftban_ipprotect_force
export -f nftban_ipprotect_is_protected
export -f nftban_ipprotect_list
export -f nftban_ipprotect_summary
export -f nftban_ipprotect_setup
export -f nftban_ipprotect_check_before_ban
export -f nftban_ipprotect_cleanup_stale

nftban_log_debug "NFTBan IP Protection Module loaded"
