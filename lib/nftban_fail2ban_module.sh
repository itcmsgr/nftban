#!/usr/bin/env bash

# =============================================================================
# NFTBan Fail2ban Module
# Version: 0.9.2
# Location: lib/nftban_fail2ban_module.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Fail2ban integration and jail management
# =============================================================================

# Strict mode for production-grade security
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

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
[Definition]
actionstart =
actionstop =
actioncheck =
actionban = /usr/local/bin/nftban blacklist ban <ip> 3600 "fail2ban-<name>" 2>&1 | logger -t nftban-fail2ban
actionunban = /usr/local/bin/nftban blacklist unban <ip> 2>&1 | logger -t nftban-fail2ban
[Init]
name = default
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

    # BUG49 FIX: Validate jail name to prevent path traversal
    if ! validate_jail_name "$jail_name" >/dev/null 2>&1; then
        nftban_log_error "Invalid jail name: '$jail_name' (must be alphanumeric with _ or -, max 64 chars)"
        return 1
    fi

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

    # BUG49 FIX: Validate jail name to prevent path traversal
    if ! validate_jail_name "$jail_name" >/dev/null 2>&1; then
        nftban_log_error "Invalid jail name: '$jail_name' (must be alphanumeric with _ or -, max 64 chars)"
        return 1
    fi

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

# Show fail2ban monitoring panel (beautiful colored display)
nftban_fail2ban_monitor_panel() {
    # All possible services to check
    local -a ALL_SERVICES=("SSH" "SMTP" "HTTP" "IMAP/POP3")

    # Get server information
    local hostname
    hostname=$(hostname)

    local os_name
    if [ -f /etc/os-release ]; then
        os_name=$(grep '^PRETTY_NAME=' /etc/os-release | cut -d'"' -f2)
    else
        os_name=$(uname -s)
    fi

    # Print header
    printf '+%*s+\n' 78 '' | tr ' ' '='
    printf "|%*s|\n" 78 " fail2ban SERVICE MONITORING PANEL"
    printf '+%*s+\n' 78 '' | tr ' ' '='
    echo

    # Server info
    echo -e "${NFTBAN_YELLOW}Server Information:${NFTBAN_NC}"
    echo -e "  Hostname: ${NFTBAN_CYAN}${hostname}${NFTBAN_NC}"
    echo -e "  OS:       ${NFTBAN_CYAN}${os_name}${NFTBAN_NC}"
    echo -e "  Time:     ${NFTBAN_CYAN}$(date '+%Y-%m-%d %H:%M:%S')${NFTBAN_NC}"
    echo

    # fail2ban status
    echo -e "${NFTBAN_YELLOW}fail2ban Status:${NFTBAN_NC}"
    if systemctl is-active fail2ban >/dev/null 2>&1; then
        echo -e "  ${NFTBAN_GREEN}●${NFTBAN_NC} Active"
    elif systemctl is-enabled fail2ban >/dev/null 2>&1; then
        echo -e "  ${NFTBAN_YELLOW}●${NFTBAN_NC} Enabled (not running)"
    else
        echo -e "  ${NFTBAN_RED}○${NFTBAN_NC} Disabled"
        echo
        echo "Run 'nftban fail2ban setup' to configure fail2ban integration"
        return 1
    fi
    echo

    # Service monitoring
    echo -e "${NFTBAN_YELLOW}Service Monitoring:${NFTBAN_NC}"
    echo

    local total_bans=0
    local monitored_count=0

    # Get all jails as array
    local -a jail_list=()
    local jails_raw
    jails_raw=$(fail2ban-client status 2>/dev/null | grep 'Jail list:' | sed 's/.*://;s/,/ /g' | xargs || echo "")

    # Convert to array with proper IFS handling
    if [ -n "$jails_raw" ]; then
        local OLD_IFS="$IFS"
        IFS=' '
        read -ra jail_list <<< "$jails_raw"
        IFS="$OLD_IFS"
    fi

    for service in "${ALL_SERVICES[@]}"; do
        local service_jails=""
        local service_bans=0
        local service_enabled=false

        # Check if service has jails
        for jail in "${jail_list[@]}"; do
            [ -z "$jail" ] && continue

            local matches=false
            case "$service" in
                "SSH")
                    [[ "$jail" == "sshd" ]] && matches=true
                    ;;
                "SMTP")
                    [[ "$jail" =~ ^(postfix|smtp|exim) ]] && matches=true
                    ;;
                "HTTP")
                    [[ "$jail" =~ ^(apache|httpd|nginx) ]] && matches=true
                    ;;
                "IMAP/POP3")
                    [[ "$jail" =~ ^(dovecot|imap|pop3) ]] && matches=true
                    ;;
            esac

            if [ "$matches" = true ]; then
                service_enabled=true
                if [ -n "$service_jails" ]; then
                    service_jails+=", "
                fi
                service_jails+="$jail"

                local count
                count=$(fail2ban-client status "$jail" 2>/dev/null | grep 'Currently banned:' | awk '{print $NF}' || echo "0")
                service_bans=$((service_bans + count))
            fi
        done

        # Display service
        if [ "$service_enabled" = true ]; then
            monitored_count=$((monitored_count + 1))
            total_bans=$((total_bans + service_bans))

            if [ "$service_bans" -gt 0 ]; then
                printf "  %b %-12s %b\n" "${NFTBAN_RED}●${NFTBAN_NC}" "$service" "${NFTBAN_RED}CATCHING${NFTBAN_NC} - $service_bans IPs banned"
            else
                printf "  %b %-12s %b\n" "${NFTBAN_GREEN}●${NFTBAN_NC}" "$service" "${NFTBAN_GREEN}Monitoring${NFTBAN_NC} - No bans yet"
            fi

            if [ -n "$service_jails" ]; then
                echo -e "    ${NFTBAN_CYAN}Jails:${NFTBAN_NC} $service_jails"
            fi
        else
            printf "    %-12s ${NFTBAN_NC}Not monitored${NFTBAN_NC}\n" "$service"
        fi
    done

    echo

    # Summary
    echo -e "${NFTBAN_YELLOW}Summary:${NFTBAN_NC}"
    echo -e "  Services Monitored: ${NFTBAN_CYAN}$monitored_count${NFTBAN_NC} / ${#ALL_SERVICES[@]}"
    echo -e "  Total Banned IPs:   ${NFTBAN_CYAN}$total_bans${NFTBAN_NC}"
    echo

    # Legend
    printf '+%*s+\n' 78 '' | tr ' ' '-'
    echo -e "${NFTBAN_YELLOW}Legend:${NFTBAN_NC}"
    echo -e "  ${NFTBAN_GREEN}●${NFTBAN_NC} Monitoring  - Service jail enabled, no attacks detected"
    echo -e "  ${NFTBAN_RED}●${NFTBAN_NC} CATCHING    - Service jail enabled, actively blocking attacks"
    echo -e "      Not monitored - No jail configured for this service"
    printf '+%*s+\n' 78 '' | tr ' ' '-'
}

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
# CONFIGURATION SYNC (v0.9.4)
# =============================================================================

# Load config value (checks both .conf and .conf.local, local overrides global)
nftban_fail2ban_get_config() {
    local key="$1"
    local default="${2:-}"

    # Read from .conf.local first (user overrides)
    if [[ -f "${NFTBAN_MAIN_CONFIG}.local" ]]; then
        local value
        value=$(grep -E "^${key}=" "${NFTBAN_MAIN_CONFIG}.local" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | head -n1)
        if [[ -n "$value" ]]; then
            echo "$value"
            return 0
        fi
    fi

    # Fallback to main .conf
    if [[ -f "$NFTBAN_MAIN_CONFIG" ]]; then
        local value
        value=$(grep -E "^${key}=" "$NFTBAN_MAIN_CONFIG" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | head -n1)
        if [[ -n "$value" ]]; then
            echo "$value"
            return 0
        fi
    fi

    # Return default
    echo "$default"
}

# Read all IPs from ALL whitelist files for fail2ban ignoreip
nftban_fail2ban_get_whitelist_ips() {
    # Start with localhost
    local ips="127.0.0.1/8 ::1"

    # Read from ALL whitelist files
    local whitelist_files=(
        "${NFTBAN_CONFIG_DIR}/whitelist-system.conf"
        "${NFTBAN_CONFIG_DIR}/whitelist-user.conf"
        "${NFTBAN_CONFIG_DIR}/whitelist-cloudflare.conf"
    )

    for whitelist_file in "${whitelist_files[@]}"; do
        [[ ! -f "$whitelist_file" ]] && continue

        # Read all IPs, skip comments and empty lines
        while IFS= read -r line; do
            # Skip comments and empty lines
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

            # Extract IP (first field)
            local ip
            ip=$(echo "$line" | awk '{print $1}')

            # Validate it looks like an IP
            if [[ "$ip" =~ ^[0-9]+\. ]] || [[ "$ip" =~ ^[0-9a-fA-F]*: ]] || [[ "$ip" =~ / ]]; then
                ips="$ips $ip"
            fi
        done < "$whitelist_file"
    done

    echo "$ips"
}

# Generate /etc/fail2ban/jail.local from nftban config
nftban_fail2ban_sync() {
    nftban_log_info "Syncing nftban config to fail2ban..."

    # Check if fail2ban is installed
    if ! command -v fail2ban-client &> /dev/null; then
        nftban_log_error "fail2ban is not installed"
        echo "ERROR: fail2ban is not installed"
        return 1
    fi

    local jail_local="/etc/fail2ban/jail.local"

    # Backup existing jail.local
    if [[ -f "$jail_local" ]]; then
        cp "$jail_local" "${jail_local}.backup.$(date +%Y%m%d_%H%M%S)"
    fi

    # Get whitelist IPs from whitelist-user.conf
    local ignoreip
    ignoreip=$(nftban_fail2ban_get_whitelist_ips)

    # Get default settings
    local def_bantime def_findtime def_maxretry
    def_bantime=$(nftban_fail2ban_get_config "NFTBAN_F2B_DEF_BAN_TIME" "3600")
    def_findtime=$(nftban_fail2ban_get_config "NFTBAN_F2B_DEF_FIND_TIME" "600")
    def_maxretry=$(nftban_fail2ban_get_config "NFTBAN_F2B_DEF_MAX_RETRY" "5")

    # Generate jail.local
    cat > "$jail_local" << EOF
# =============================================================================
# Fail2ban jail.local - Generated by NFTBan v0.9.4
# =============================================================================
# ⚠️  WARNING: This file is AUTO-GENERATED by nftban
# Do NOT edit manually - changes will be overwritten!
#
# To modify settings:
#   1. Edit /etc/nftban/config/nftban.conf.local
#   2. Run: nftban fail2ban sync
#
# To whitelist IPs:
#   1. Run: nftban whitelist add IP
#   2. Run: nftban fail2ban sync
#
# Generated: $(date +'%Y-%m-%d %H:%M:%S')
# =============================================================================

[DEFAULT]
ignoreip = ${ignoreip}
bantime  = ${def_bantime}
findtime = ${def_findtime}
maxretry = ${def_maxretry}
banaction = nftables-multiport
action = %(action_)s
         nftban

EOF

    # Add SSH jail if enabled
    local sshd_enabled
    sshd_enabled=$(nftban_fail2ban_get_config "NFTBAN_F2B_SSHD_JAIL" "true")

    if [[ "$sshd_enabled" == "true" ]]; then
        cat >> "$jail_local" << EOF
[sshd]
enabled = true
port = ssh
logpath = %(sshd_log)s
maxretry = $(nftban_fail2ban_get_config "NFTBAN_F2B_SSHD_MAX_RETRY" "3")
bantime = $(nftban_fail2ban_get_config "NFTBAN_F2B_SSHD_BAN_TIME" "7200")

EOF
    fi

    # Add Postfix jail if enabled
    local postfix_enabled
    postfix_enabled=$(nftban_fail2ban_get_config "NFTBAN_F2B_POSTFIX_JAIL" "true")

    if [[ "$postfix_enabled" == "true" ]]; then
        cat >> "$jail_local" << EOF
[postfix]
enabled = true
port = smtp,465,submission
logpath = /var/log/maillog
maxretry = $(nftban_fail2ban_get_config "NFTBAN_F2B_POSTFIX_MAX_RETRY" "5")

EOF
    fi

    # Add Postfix-SASL jail if enabled
    local postfix_sasl_enabled
    postfix_sasl_enabled=$(nftban_fail2ban_get_config "NFTBAN_F2B_POSTFIX_SASL_JAIL" "true")

    if [[ "$postfix_sasl_enabled" == "true" ]]; then
        cat >> "$jail_local" << EOF
[postfix-sasl]
enabled = true
port = smtp,465,submission
logpath = /var/log/maillog
maxretry = $(nftban_fail2ban_get_config "NFTBAN_F2B_POSTFIX_SASL_MAX_RETRY" "3")

EOF
    fi

    # Add Recidive jail if enabled
    local recidive_enabled
    recidive_enabled=$(nftban_fail2ban_get_config "NFTBAN_F2B_RECIDIVE_JAIL" "true")

    if [[ "$recidive_enabled" == "true" ]]; then
        cat >> "$jail_local" << EOF
[recidive]
enabled = true
logpath = /var/log/fail2ban.log
banaction = nftables-allports
bantime = $(nftban_fail2ban_get_config "NFTBAN_F2B_RECIDIVE_BAN_TIME" "604800")
findtime = $(nftban_fail2ban_get_config "NFTBAN_F2B_RECIDIVE_FIND_TIME" "86400")
maxretry = $(nftban_fail2ban_get_config "NFTBAN_F2B_RECIDIVE_MAX_RETRY" "3")

EOF
    fi

    nftban_log_success "Generated $jail_local"
    echo "✓ Generated $jail_local"

    # Reload fail2ban
    if systemctl reload fail2ban 2>/dev/null; then
        nftban_log_success "fail2ban reloaded"
        echo "✓ fail2ban reloaded"
    else
        nftban_log_error "Failed to reload fail2ban"
        echo "ERROR: Failed to reload fail2ban"
        return 1
    fi

    return 0
}

# Show current jail configuration
nftban_fail2ban_config_show() {
    local jail="${1:-}"

    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  Fail2ban Configuration"
    echo "═══════════════════════════════════════════════════════"
    echo ""

    if [[ -z "$jail" ]]; then
        # Show all jails
        echo "DEFAULT Settings:"
        echo "  Ban Time:    $(nftban_fail2ban_get_config "NFTBAN_F2B_DEF_BAN_TIME" "3600") seconds"
        echo "  Find Time:   $(nftban_fail2ban_get_config "NFTBAN_F2B_DEF_FIND_TIME" "600") seconds"
        echo "  Max Retry:   $(nftban_fail2ban_get_config "NFTBAN_F2B_DEF_MAX_RETRY" "5")"
        echo ""

        echo "SSH Jail:"
        echo "  Enabled:     $(nftban_fail2ban_get_config "NFTBAN_F2B_SSHD_JAIL" "true")"
        echo "  Ban Time:    $(nftban_fail2ban_get_config "NFTBAN_F2B_SSHD_BAN_TIME" "7200") seconds"
        echo "  Max Retry:   $(nftban_fail2ban_get_config "NFTBAN_F2B_SSHD_MAX_RETRY" "3")"
        echo ""

        echo "Postfix Jail:"
        echo "  Enabled:     $(nftban_fail2ban_get_config "NFTBAN_F2B_POSTFIX_JAIL" "true")"
        echo "  Max Retry:   $(nftban_fail2ban_get_config "NFTBAN_F2B_POSTFIX_MAX_RETRY" "5")"
        echo ""

        echo "Recidive Jail:"
        echo "  Enabled:     $(nftban_fail2ban_get_config "NFTBAN_F2B_RECIDIVE_JAIL" "true")"
        echo "  Ban Time:    $(nftban_fail2ban_get_config "NFTBAN_F2B_RECIDIVE_BAN_TIME" "604800") seconds (7 days)"
        echo "  Max Retry:   $(nftban_fail2ban_get_config "NFTBAN_F2B_RECIDIVE_MAX_RETRY" "3")"
    else
        # Show specific jail
        local jail_upper
        jail_upper=$(echo "$jail" | tr '[:lower:]' '[:upper:]' | tr '-' '_')

        echo "${jail} Jail:"
        echo "  Enabled:     $(nftban_fail2ban_get_config "NFTBAN_F2B_${jail_upper}_JAIL" "unknown")"
        echo "  Ban Time:    $(nftban_fail2ban_get_config "NFTBAN_F2B_${jail_upper}_BAN_TIME" "N/A") seconds"
        echo "  Max Retry:   $(nftban_fail2ban_get_config "NFTBAN_F2B_${jail_upper}_MAX_RETRY" "N/A")"
        echo "  Find Time:   $(nftban_fail2ban_get_config "NFTBAN_F2B_${jail_upper}_FIND_TIME" "N/A") seconds"
    fi

    echo ""
    echo "Whitelisted IPs (ALL sources: system + user + cloudflare):"
    nftban_fail2ban_get_whitelist_ips | tr ' ' '\n' | while read -r ip; do
        [[ -n "$ip" ]] && echo "  $ip"
    done

    echo ""
    echo "═══════════════════════════════════════════════════════"
}

# Set jail configuration value
nftban_fail2ban_config_set() {
    local jail="$1"
    local setting="$2"
    local value="$3"

    # Convert jail and setting to config variable name
    local jail_upper
    jail_upper=$(echo "$jail" | tr '[:lower:]' '[:upper:]' | tr '-' '_')

    local setting_upper
    setting_upper=$(echo "$setting" | tr '[:lower:]' '[:upper:]' | tr '-' '_')

    local var_name="NFTBAN_F2B_${jail_upper}_${setting_upper}"

    # Update in nftban.conf.local
    local conf_local="${NFTBAN_MAIN_CONFIG}.local"

    # Create .local if it doesn't exist
    if [[ ! -f "$conf_local" ]]; then
        cat > "$conf_local" << EOF
# =============================================================================
# NFTBan Local Configuration (User Overrides)
# =============================================================================
# This file overrides values from nftban.conf
# Safe to edit - preserved during package updates
# Auto-managed by: nftban fail2ban config set

EOF
        chmod 640 "$conf_local"
    fi

    # Check if variable exists in .local
    if grep -q "^${var_name}=" "$conf_local" 2>/dev/null; then
        # UPDATE existing value
        sed -i "s|^${var_name}=.*|${var_name}=\"${value}\"|" "$conf_local"
        echo "✓ Updated ${var_name}=\"${value}\" in nftban.conf.local"
    else
        # ADD new value
        echo "${var_name}=\"${value}\"" >> "$conf_local"
        echo "✓ Added ${var_name}=\"${value}\" to nftban.conf.local"
    fi

    nftban_log_info "Updated ${var_name}=${value}"

    # Auto-sync to fail2ban
    echo ""
    echo "Syncing to fail2ban..."
    nftban_fail2ban_sync
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f nftban_fail2ban_setup
export -f nftban_fail2ban_enable_jail
export -f nftban_fail2ban_disable_jail
export -f nftban_fail2ban_list_jails
export -f nftban_fail2ban_monitor_panel
export -f nftban_fail2ban_show_status
export -f nftban_fail2ban_get_config
export -f nftban_fail2ban_get_whitelist_ips
export -f nftban_fail2ban_sync
export -f nftban_fail2ban_config_show
export -f nftban_fail2ban_config_set

nftban_log_debug "NFTBan Fail2ban Module loaded (v0.9.4)"