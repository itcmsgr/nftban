#!/usr/bin/env bash

# =============================================================================
# NFTBan Fail2ban Module
# Version: 1.0.0
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Fail2ban integration and jail management
# =============================================================================

# Prevent double-loading
[[ -n "${NFTBAN_FAIL2BAN_LOADED:-}" ]] && return 0
readonly NFTBAN_FAIL2BAN_LOADED=1

# =============================================================================
# MODULE CONFIGURATION
# =============================================================================
readonly NFTBAN_F2B_ACTION_DIR="/etc/fail2ban/action.d"
readonly NFTBAN_F2B_JAIL_DIR="/etc/fail2ban/jail.d"
readonly NFTBAN_F2B_FILTER_DIR="/etc/fail2ban/filter.d"

# =============================================================================
# FAIL2BAN SETUP
# =============================================================================

# Setup fail2ban integration
nftban_fail2ban_setup() {
    nftban_log_info "Setting up fail2ban integration..."
    
    # Check if fail2ban is installed
    if ! command -v fail2ban-client &>/dev/null; then
        nftban_log_error "fail2ban is not installed"
        echo ""
        echo "Install fail2ban first:"
        echo "  Debian/Ubuntu: sudo apt-get install fail2ban"
        echo "  RHEL/CentOS:   sudo yum install fail2ban"
        return 1
    fi
    
    # Create nftban action
    local action_file="${NFTBAN_F2B_ACTION_DIR}/nftban.conf"
    
    cat > "$action_file" << 'EOF'
# nftban action for fail2ban
# SECURITY: Idempotent actions - safe to call multiple times
[Definition]

actionstart =
actionstop =

# IDEMPOTENCY: Check if IP is already banned before ban action
# Returns success even if already banned (prevents fail2ban errors)
actioncheck =

# BAN action with idempotency
# 1. Check if IP already in nftables blacklist set
# 2. If not present, add to blacklist
# 3. If already present, skip (idempotent)
actionban = if ! nft list set inet nftban_global perm_ban_v4 2>/dev/null | grep -q '<ip>'; then
              nftban blacklist ban '<ip>' '<name>' '<bantime>' 2>&1 | logger -t nftban-f2b
            fi

# UNBAN action with idempotency
# 1. Check if IP exists in blacklist
# 2. If present, remove from blacklist
# 3. If not present, skip (idempotent)
actionunban = if nft list set inet nftban_global perm_ban_v4 2>/dev/null | grep -q '<ip>'; then
                nftban blacklist unban '<ip>' '<name>' 2>&1 | logger -t nftban-f2b
              fi

[Init]
name = default
bantime = 3600

# NOTES:
# - Actions log to syslog via logger for audit trail
# - Conditional execution prevents duplicate entries
# - Safe to call multiple times (idempotent)
# - Works with both nftban CLI and direct fail2ban calls
EOF

    chmod 644 "$action_file"
    nftban_log_success "Created fail2ban action: $action_file"
    
    # Create example jail for SSH
    local jail_file="${NFTBAN_F2B_JAIL_DIR}/nftban-sshd.conf"
    
    cat > "$jail_file" << 'EOF'
# nftban SSHD jail
[sshd]
enabled = true
backend = systemd
port = ssh
maxretry = 5
findtime = 10m
bantime = 1h
action = nftban
ignoreip = 127.0.0.1/8 ::1
EOF

    chmod 644 "$jail_file"
    nftban_log_success "Created example jail: $jail_file"
    
    echo ""
    echo "Fail2ban integration configured!"
    echo ""
    echo "Next steps:"
    echo "  1. Review jail: $jail_file"
    echo "  2. Reload fail2ban: systemctl reload fail2ban"
    echo "  3. Check status: fail2ban-client status sshd"
    echo "  4. Enable more jails: nftban fail2ban jail-enable <name>"
}

# =============================================================================
# JAIL MANAGEMENT
# =============================================================================

# Enable jail
nftban_fail2ban_enable_jail() {
    local jail_name="$1"
    
    nftban_log_info "Enabling jail: $jail_name"
    
    # Check if jail exists
    if ! fail2ban-client status | grep -q "$jail_name"; then
        nftban_log_error "Jail not found: $jail_name"
        return 1
    fi
    
    # Jail is managed in config files, just reload
    systemctl reload fail2ban
    
    nftban_log_success "Jail enabled (fail2ban reloaded)"
}

# Disable jail
nftban_fail2ban_disable_jail() {
    local jail_name="$1"
    
    nftban_log_info "Disabling jail: $jail_name"
    
    # Find and disable in config
    local jail_file="${NFTBAN_F2B_JAIL_DIR}/${jail_name}.conf"
    
    if [[ -f "$jail_file" ]]; then
        sed -i 's/^enabled = true/enabled = false/' "$jail_file"
        systemctl reload fail2ban
        nftban_log_success "Jail disabled"
    else
        nftban_log_error "Jail config not found: $jail_file"
        return 1
    fi
}

# List available jails
nftban_fail2ban_list_jails() {
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  Fail2ban Jails"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    
    if ! command -v fail2ban-client &>/dev/null; then
        echo "fail2ban not installed"
        return 1
    fi
    
    if systemctl is-active fail2ban &>/dev/null; then
        echo -e "${NFTBAN_CYAN}Active Jails:${NFTBAN_NC}"
        fail2ban-client status | grep "Jail list" | sed 's/.*://' | tr ',' '\n' | while read -r jail; do
            jail=$(echo "$jail" | xargs)
            [[ -z "$jail" ]] && continue
            
            local banned_count
            banned_count=$(fail2ban-client status "$jail" 2>/dev/null | grep "Currently banned:" | awk '{print $NF}')
            
            printf "  %-20s %s banned\n" "$jail" "${banned_count:-0}"
        done
    else
        echo "fail2ban service is not running"
    fi
    
    echo ""
}

# =============================================================================
# STATUS AND MONITORING
# =============================================================================

# Show fail2ban status
nftban_fail2ban_show_status() {
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  Fail2ban Status"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    
    if ! command -v fail2ban-client &>/dev/null; then
        echo "fail2ban is not installed"
        return 1
    fi
    
    # Service status
    echo -e "${NFTBAN_CYAN}Service:${NFTBAN_NC}"
    if systemctl is-active fail2ban &>/dev/null; then
        echo -e "  ${NFTBAN_GREEN}● ACTIVE${NFTBAN_NC}"
    else
        echo -e "  ${NFTBAN_RED}○ INACTIVE${NFTBAN_NC}"
        return 1
    fi
    
    if systemctl is-enabled fail2ban &>/dev/null; then
        echo -e "  Boot: ${NFTBAN_GREEN}ENABLED${NFTBAN_NC}"
    else
        echo -e "  Boot: ${NFTBAN_YELLOW}DISABLED${NFTBAN_NC}"
    fi
    
    echo ""
    
    # General status
    echo -e "${NFTBAN_CYAN}Overview:${NFTBAN_NC}"
    fail2ban-client status
    
    echo ""
    
    # Detailed jail status
    echo -e "${NFTBAN_CYAN}Jail Details:${NFTBAN_NC}"
    fail2ban-client status | grep "Jail list" | sed 's/.*://' | tr ',' '\n' | while read -r jail; do
        jail=$(echo "$jail" | xargs)
        [[ -z "$jail" ]] && continue
        
        echo ""
        echo "Jail: $jail"
        fail2ban-client status "$jail" | grep -E "Currently|Total" | sed 's/^/  /'
    done
    
    echo ""
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f nftban_fail2ban_setup
export -f nftban_fail2ban_enable_jail
export -f nftban_fail2ban_disable_jail
export -f nftban_fail2ban_list_jails
export -f nftban_fail2ban_show_status

nftban_log_debug "NFTBan Fail2ban Module loaded"