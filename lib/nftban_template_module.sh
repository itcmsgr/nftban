#!/usr/bin/env bash

# =============================================================================
# NFTBan Template Processing Module
# Version: 1.0.0
# Template variable substitution and jail configuration management
# =============================================================================

# Prevent double-loading
[[ -n "${NFTBAN_TEMPLATE_LOADED:-}" ]] && return 0
readonly NFTBAN_TEMPLATE_LOADED=1

# =============================================================================
# MODULE CONFIGURATION
# =============================================================================
readonly NFTBAN_TEMPLATE_BASE_DIR="${NFTBAN_TEMPLATE_DIR}/fail2ban"
readonly NFTBAN_JAIL_CONFIG_PREFIX="NFTBAN_F2B_JAIL"

# =============================================================================
# JAIL CONFIGURATION MANAGEMENT
# =============================================================================

# Get jail-specific configuration value
nftban_jail_get_config() {
    local jail_name="$1"
    local param="$2"  # BAN_TIME, MAX_RETRY, FIND_TIME, ENABLED
    local default="${3:-}"
    
    local var_name="${NFTBAN_JAIL_CONFIG_PREFIX}_${jail_name}_${param}"
    nftban_get_config "$var_name" "$default"
}

# Set jail-specific configuration value
nftban_jail_set_config() {
    local jail_name="$1"
    local param="$2"
    local value="$3"
    
    local var_name="${NFTBAN_JAIL_CONFIG_PREFIX}_${jail_name}_${param}"
    nftban_set_config "$var_name" "$value" "$NFTBAN_LOCAL_CONFIG"
}

# Check if jail is enabled
nftban_jail_is_enabled() {
    local jail_name="$1"
    local enabled
    enabled=$(nftban_jail_get_config "$jail_name" "ENABLED" "false")
    
    [[ "$enabled" == "true" ]] && return 0 || return 1
}

# Ensure jail configuration exists with defaults
nftban_jail_ensure_config() {
    local jail_name="$1"
    
    local enabled
    enabled=$(nftban_jail_get_config "$jail_name" "ENABLED" "")
    
    if [[ -z "$enabled" ]]; then
        nftban_log_info "Creating default configuration for jail: $jail_name"
        
        # Get global defaults
        local def_ban_time def_find_time def_max_retry
        def_ban_time=$(nftban_get_config "NFTBAN_DEFAULT_BAN_TIME" "3600")
        def_find_time=$(nftban_get_config "NFTBAN_DEFAULT_FIND_TIME" "600")
        def_max_retry=$(nftban_get_config "NFTBAN_DEFAULT_MAX_RETRY" "5")
        
        # Add comment section to config file
        {
            echo ""
            echo "# ========================================="
            echo "# ${jail_name} Jail Configuration"
            echo "# ========================================="
        } >> "$NFTBAN_LOCAL_CONFIG"
        
        # Set defaults
        nftban_jail_set_config "$jail_name" "ENABLED" "false"
        nftban_jail_set_config "$jail_name" "BAN_TIME" "$def_ban_time"
        nftban_jail_set_config "$jail_name" "MAX_RETRY" "$def_max_retry"
        nftban_jail_set_config "$jail_name" "FIND_TIME" "$def_find_time"
        
        nftban_log_debug "Created configuration for jail: $jail_name"
    fi
}

# Remove jail configuration from config file
nftban_jail_remove_config() {
    local jail_name="$1"
    
    if [[ ! -f "$NFTBAN_LOCAL_CONFIG" ]]; then
        return 0
    fi
    
    # Remove comment header
    sed -i "/^# ${jail_name} Jail Configuration/d" "$NFTBAN_LOCAL_CONFIG"
    sed -i "/^# =========================================/d" "$NFTBAN_LOCAL_CONFIG"
    
    # Remove all config lines for this jail
    sed -i "/^${NFTBAN_JAIL_CONFIG_PREFIX}_${jail_name}_/d" "$NFTBAN_LOCAL_CONFIG"
    
    nftban_log_debug "Removed configuration for jail: $jail_name"
}

# List all configured jails
nftban_jail_list_configured() {
    if [[ ! -f "$NFTBAN_LOCAL_CONFIG" ]]; then
        return 0
    fi
    
    grep "^${NFTBAN_JAIL_CONFIG_PREFIX}_" "$NFTBAN_LOCAL_CONFIG" 2>/dev/null | \
        sed "s/${NFTBAN_JAIL_CONFIG_PREFIX}_//" | \
        cut -d'_' -f1 | \
        sort -u
}

# =============================================================================
# TEMPLATE VARIABLE SUBSTITUTION
# =============================================================================

# Process template file with variable substitution
nftban_template_process() {
    local template_file="$1"
    local output_file="$2"
    local jail_name="$3"
    
    if [[ ! -f "$template_file" ]]; then
        nftban_log_error "Template file not found: $template_file"
        return 1
    fi
    
    # Get configuration values for this jail
    local ban_time max_retry find_time ignoreip
    ban_time=$(nftban_jail_get_config "$jail_name" "BAN_TIME" "3600")
    max_retry=$(nftban_jail_get_config "$jail_name" "MAX_RETRY" "5")
    find_time=$(nftban_jail_get_config "$jail_name" "FIND_TIME" "600")
    ignoreip=$(nftban_get_config "NFTBAN_WHITELIST_FILE" "${NFTBAN_CONFIG_DIR}/whitelist-system.conf")
    
    nftban_log_debug "Processing template: $template_file"
    nftban_log_debug "  Variables: BAN_TIME=$ban_time, MAX_RETRY=$max_retry, FIND_TIME=$find_time"
    
    # Perform variable substitution
    sed -e "s|{{BANTIME}}|${ban_time}|g" \
        -e "s|{{BAN_TIME}}|${ban_time}|g" \
        -e "s|{{MAXRETRY}}|${max_retry}|g" \
        -e "s|{{MAX_RETRY}}|${max_retry}|g" \
        -e "s|{{FINDTIME}}|${find_time}|g" \
        -e "s|{{FIND_TIME}}|${find_time}|g" \
        -e "s|{{IGNOREIP}}|file:${ignoreip}|g" \
        -e "s|{{JAIL_NAME}}|${jail_name}|g" \
        -e "s|{{JAIL}}|${jail_name}|g" \
        "$template_file" > "$output_file"
    
    chmod 644 "$output_file"
    
    nftban_log_debug "Template processed: $output_file"
    return 0
}

# Process all templates for a jail
nftban_template_process_jail() {
    local jail_name="$1"
    local os="${2:-DEBIAN}"
    
    local jail_lower
    jail_lower=$(echo "$jail_name" | tr '[:upper:]' '[:lower:]')
    
    local template_os_dir="${NFTBAN_TEMPLATE_BASE_DIR}/${os}"
    
    if [[ ! -d "$template_os_dir" ]]; then
        nftban_log_error "Template directory not found: $template_os_dir"
        return 1
    fi
    
    nftban_log_info "Processing templates for jail: $jail_name (OS: $os)"
    
    local processed=0
    
    # Process jail.d template
    local jail_template="${template_os_dir}/jail.d/nftban-${jail_lower}.conf"
    if [[ -f "$jail_template" ]]; then
        nftban_template_process "$jail_template" \
            "/etc/fail2ban/jail.d/nftban-${jail_lower}.conf" \
            "$jail_name"
        ((processed++))
    fi
    
    # Copy filter.d template (usually no substitution needed)
    local filter_template="${template_os_dir}/filter.d/nftban-${jail_lower}.conf"
    if [[ -f "$filter_template" ]]; then
        cp "$filter_template" "/etc/fail2ban/filter.d/nftban-${jail_lower}.conf"
        chmod 644 "/etc/fail2ban/filter.d/nftban-${jail_lower}.conf"
        nftban_log_debug "Copied filter: nftban-${jail_lower}.conf"
        ((processed++))
    fi
    
    # Copy action.d template (usually no substitution needed)
    local action_template="${template_os_dir}/action.d/nftban-${jail_lower}.conf"
    if [[ -f "$action_template" ]]; then
        cp "$action_template" "/etc/fail2ban/action.d/nftban-${jail_lower}.conf"
        chmod 644 "/etc/fail2ban/action.d/nftban-${jail_lower}.conf"
        nftban_log_debug "Copied action: nftban-${jail_lower}.conf"
        ((processed++))
    fi
    
    if [[ $processed -gt 0 ]]; then
        nftban_log_success "Processed $processed template files for jail: $jail_name"
        return 0
    else
        nftban_log_warning "No templates found for jail: $jail_name"
        return 1
    fi
}

# =============================================================================
# TEMPLATE DISCOVERY
# =============================================================================

# Detect OS for template selection
nftban_template_detect_os() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        case "$ID" in
            debian|ubuntu|linuxmint)
                echo "DEBIAN"
                ;;
            rhel|centos|fedora|rocky|almalinux)
                echo "REDHAT"
                ;;
            *)
                nftban_log_warning "Unknown OS: $ID, defaulting to DEBIAN"
                echo "DEBIAN"
                ;;
        esac
    else
        nftban_log_warning "Cannot detect OS, defaulting to DEBIAN"
        echo "DEBIAN"
    fi
}

# Get available jails for current OS
nftban_template_get_available_jails() {
    local os="${1:-$(nftban_template_detect_os)}"
    local jail_dir="${NFTBAN_TEMPLATE_BASE_DIR}/${os}/jail.d"
    
    if [[ ! -d "$jail_dir" ]]; then
        nftban_log_error "Jail template directory not found: $jail_dir"
        return 1
    fi
    
    # Extract jail names from nftban-*.conf files
    find "$jail_dir" -name "nftban-*.conf" -type f 2>/dev/null | while read -r file; do
        basename "$file" | sed 's/nftban-\(.*\)\.conf/\1/' | tr '[:lower:]' '[:upper:]'
    done | sort -u
}

# Check if template exists for jail
nftban_template_exists() {
    local jail_name="$1"
    local os="${2:-$(nftban_template_detect_os)}"
    
    local jail_lower
    jail_lower=$(echo "$jail_name" | tr '[:upper:]' '[:lower:]')
    
    local template_file="${NFTBAN_TEMPLATE_BASE_DIR}/${os}/jail.d/nftban-${jail_lower}.conf"
    
    [[ -f "$template_file" ]] && return 0 || return 1
}

# =============================================================================
# JAIL DEPLOYMENT
# =============================================================================

# Deploy jail (process templates and enable)
nftban_template_deploy_jail() {
    local jail_name="$1"
    local os="${2:-$(nftban_template_detect_os)}"
    
    nftban_log_info "Deploying jail: $jail_name"
    
    # Ensure jail configuration exists
    nftban_jail_ensure_config "$jail_name"
    
    # Check if template exists
    if ! nftban_template_exists "$jail_name" "$os"; then
        nftban_log_error "No template found for jail: $jail_name (OS: $os)"
        return 1
    fi
    
    # Process templates
    if nftban_template_process_jail "$jail_name" "$os"; then
        # Mark as enabled
        nftban_jail_set_config "$jail_name" "ENABLED" "true"
        nftban_log_success "Jail deployed successfully: $jail_name"
        return 0
    else
        nftban_log_error "Failed to deploy jail: $jail_name"
        return 1
    fi
}

# Undeploy jail (remove templates and disable)
nftban_template_undeploy_jail() {
    local jail_name="$1"
    
    nftban_log_info "Undeploying jail: $jail_name"
    
    local jail_lower
    jail_lower=$(echo "$jail_name" | tr '[:upper:]' '[:lower:]')
    
    # Remove fail2ban configuration files
    rm -f "/etc/fail2ban/jail.d/nftban-${jail_lower}.conf"
    rm -f "/etc/fail2ban/filter.d/nftban-${jail_lower}.conf"
    rm -f "/etc/fail2ban/action.d/nftban-${jail_lower}.conf"
    
    # Mark as disabled
    nftban_jail_set_config "$jail_name" "ENABLED" "false"
    
    nftban_log_success "Jail undeployed: $jail_name"
    return 0
}

# Redeploy jail (refresh templates with current config)
nftban_template_redeploy_jail() {
    local jail_name="$1"
    local os="${2:-$(nftban_template_detect_os)}"
    
    nftban_log_info "Redeploying jail: $jail_name"
    
    if nftban_jail_is_enabled "$jail_name"; then
        nftban_template_process_jail "$jail_name" "$os"
        nftban_log_success "Jail redeployed: $jail_name"
    else
        nftban_log_warning "Jail is not enabled: $jail_name"
        return 1
    fi
}

# =============================================================================
# BULK OPERATIONS
# =============================================================================

# Deploy all available jails
nftban_template_deploy_all() {
    local os="${1:-$(nftban_template_detect_os)}"
    
    nftban_log_info "Deploying all available jails for OS: $os"
    
    local deployed=0
    local failed=0
    
    while IFS= read -r jail_name; do
        [[ -z "$jail_name" ]] && continue
        
        if nftban_template_deploy_jail "$jail_name" "$os"; then
            ((deployed++))
        else
            ((failed++))
        fi
    done < <(nftban_template_get_available_jails "$os")
    
    echo ""
    nftban_log_info "Deployment summary: $deployed succeeded, $failed failed"
    
    [[ $deployed -gt 0 ]] && return 0 || return 1
}

# Undeploy all jails
nftban_template_undeploy_all() {
    nftban_log_warning "Undeploying all jails..."
    
    local undeployed=0
    
    while IFS= read -r jail_name; do
        [[ -z "$jail_name" ]] && continue
        
        if nftban_template_undeploy_jail "$jail_name"; then
            ((undeployed++))
        fi
    done < <(nftban_jail_list_configured)
    
    nftban_log_info "Undeployed $undeployed jails"
    return 0
}

# Redeploy all enabled jails
nftban_template_redeploy_all() {
    local os="${1:-$(nftban_template_detect_os)}"
    
    nftban_log_info "Redeploying all enabled jails..."
    
    local redeployed=0
    
    while IFS= read -r jail_name; do
        [[ -z "$jail_name" ]] && continue
        
        if nftban_jail_is_enabled "$jail_name"; then
            if nftban_template_redeploy_jail "$jail_name" "$os"; then
                ((redeployed++))
            fi
        fi
    done < <(nftban_jail_list_configured)
    
    nftban_log_info "Redeployed $redeployed jails"
    return 0
}

# =============================================================================
# JAIL STATUS AND LISTING
# =============================================================================

# Show jail status
nftban_template_show_jail_status() {
    local jail_name="$1"
    
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  Jail Status: $jail_name"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    
    local enabled ban_time max_retry find_time
    enabled=$(nftban_jail_get_config "$jail_name" "ENABLED" "false")
    ban_time=$(nftban_jail_get_config "$jail_name" "BAN_TIME" "not set")
    max_retry=$(nftban_jail_get_config "$jail_name" "MAX_RETRY" "not set")
    find_time=$(nftban_jail_get_config "$jail_name" "FIND_TIME" "not set")
    
    echo "Configuration:"
    echo "  Enabled: $enabled"
    echo "  Ban Time: ${ban_time}s"
    echo "  Max Retry: $max_retry"
    echo "  Find Time: ${find_time}s"
    echo ""
    
    # Check if fail2ban files exist
    local jail_lower
    jail_lower=$(echo "$jail_name" | tr '[:upper:]' '[:lower:]')
    
    echo "Deployed Files:"
    
    local jail_file="/etc/fail2ban/jail.d/nftban-${jail_lower}.conf"
    if [[ -f "$jail_file" ]]; then
        echo -e "  ${NFTBAN_GREEN}✓${NFTBAN_NC} jail.d/nftban-${jail_lower}.conf"
    else
        echo -e "  ${NFTBAN_RED}✗${NFTBAN_NC} jail.d/nftban-${jail_lower}.conf"
    fi
    
    local filter_file="/etc/fail2ban/filter.d/nftban-${jail_lower}.conf"
    if [[ -f "$filter_file" ]]; then
        echo -e "  ${NFTBAN_GREEN}✓${NFTBAN_NC} filter.d/nftban-${jail_lower}.conf"
    else
        echo -e "  ${NFTBAN_RED}✗${NFTBAN_NC} filter.d/nftban-${jail_lower}.conf"
    fi
    
    local action_file="/etc/fail2ban/action.d/nftban-${jail_lower}.conf"
    if [[ -f "$action_file" ]]; then
        echo -e "  ${NFTBAN_GREEN}✓${NFTBAN_NC} action.d/nftban-${jail_lower}.conf"
    fi
    
    echo ""
    echo "═══════════════════════════════════════════════════════"
}

# List all jails with status
nftban_template_list_jails() {
    local os="${1:-$(nftban_template_detect_os)}"
    
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  Available Jails (OS: $os)"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    
    printf "%-5s %-20s %-10s %-12s %-12s\n" "No." "Jail Name" "Status" "Ban Time" "Max Retry"
    echo "───────────────────────────────────────────────────────"
    
    local count=0
    while IFS= read -r jail_name; do
        [[ -z "$jail_name" ]] && continue
        
        ((count++))
        
        local enabled ban_time max_retry
        enabled=$(nftban_jail_get_config "$jail_name" "ENABLED" "false")
        ban_time=$(nftban_jail_get_config "$jail_name" "BAN_TIME" "3600")
        max_retry=$(nftban_jail_get_config "$jail_name" "MAX_RETRY" "5")
        
        local status_color
        if [[ "$enabled" == "true" ]]; then
            status_color="${NFTBAN_GREEN}ENABLED${NFTBAN_NC}"
        else
            status_color="${NFTBAN_RED}DISABLED${NFTBAN_NC}"
        fi
        
        printf "%-5s %-20s " "$count" "$jail_name"
        echo -e "$status_color    ${ban_time}s      $max_retry"
        
    done < <(nftban_template_get_available_jails "$os")
    
    if [[ $count -eq 0 ]]; then
        echo "No jails found"
    fi
    
    echo ""
    echo "═══════════════════════════════════════════════════════"
}

# =============================================================================
# TEMPLATE VALIDATION
# =============================================================================

# Validate template syntax
nftban_template_validate() {
    local template_file="$1"
    
    if [[ ! -f "$template_file" ]]; then
        nftban_log_error "Template file not found: $template_file"
        return 1
    fi
    
    nftban_log_info "Validating template: $template_file"
    
    # Check for required placeholders
    local required_vars=("{{BANTIME}}" "{{MAXRETRY}}" "{{FINDTIME}}")
    local missing=0
    
    for var in "${required_vars[@]}"; do
        if ! grep -q "$var" "$template_file"; then
            nftban_log_warning "Missing placeholder: $var"
            ((missing++))
        fi
    done
    
    if [[ $missing -gt 0 ]]; then
        nftban_log_warning "Template validation completed with $missing warnings"
        return 1
    fi
    
    nftban_log_success "Template validation passed"
    return 0
}

# Validate all templates for OS
nftban_template_validate_all() {
    local os="${1:-$(nftban_template_detect_os)}"
    local template_os_dir="${NFTBAN_TEMPLATE_BASE_DIR}/${os}"
    
    nftban_log_info "Validating all templates for OS: $os"
    
    if [[ ! -d "$template_os_dir" ]]; then
        nftban_log_error "Template directory not found: $template_os_dir"
        return 1
    fi
    
    local total=0
    local valid=0
    local invalid=0
    
    # Validate jail.d templates
    if [[ -d "${template_os_dir}/jail.d" ]]; then
        while IFS= read -r template; do
            [[ -z "$template" ]] && continue
            ((total++))
            
            if nftban_template_validate "$template" &>/dev/null; then
                ((valid++))
            else
                ((invalid++))
            fi
        done < <(find "${template_os_dir}/jail.d" -name "*.conf" -type f 2>/dev/null)
    fi
    
    echo ""
    nftban_log_info "Validation summary: $valid valid, $invalid invalid (total: $total)"
    
    [[ $invalid -eq 0 ]] && return 0 || return 1
}

# =============================================================================
# INTERACTIVE JAIL MENU
# =============================================================================

nftban_template_interactive_menu() {
    local os
    os=$(nftban_template_detect_os)
    
    while true; do
        echo ""
        echo "═══════════════════════════════════════════════════════"
        echo "  nftban Jail Manager"
        echo "═══════════════════════════════════════════════════════"
        echo ""
        
        local -a jails
        mapfile -t jails < <(nftban_template_get_available_jails "$os")
        
        if [[ ${#jails[@]} -eq 0 ]]; then
            nftban_log_error "No jails found for OS: $os"
            return 1
        fi
        
        printf "%-5s %-20s %-10s\n" "No." "Jail Name" "Status"
        echo "───────────────────────────────────────────────────────"
        
        local i=1
        for jail in "${jails[@]}"; do
            local enabled
            enabled=$(nftban_jail_get_config "$jail" "ENABLED" "false")
            
            local status_text
            if [[ "$enabled" == "true" ]]; then
                status_text="${NFTBAN_GREEN}ENABLED${NFTBAN_NC}"
            else
                status_text="${NFTBAN_RED}DISABLED${NFTBAN_NC}"
            fi
            
            printf "%-5s %-20s " "$i" "$jail"
            echo -e "$status_text"
            ((i++))
        done
        
        echo ""
        echo "Options:"
        echo "  [1-${#jails[@]}]  Toggle jail"
        echo "  a) Enable all"
        echo "  d) Disable all"
        echo "  r) Reload fail2ban"
        echo "  q) Quit"
        echo ""
        read -rp "Select option: " choice
        
        case "$choice" in
            q|Q)
                break
                ;;
            a|A)
                nftban_template_deploy_all "$os"
                read -rp "Reload fail2ban? (y/N): " reload
                [[ "$reload" =~ ^[Yy]$ ]] && systemctl reload fail2ban
                ;;
            d|D)
                nftban_template_undeploy_all
                read -rp "Reload fail2ban? (y/N): " reload
                [[ "$reload" =~ ^[Yy]$ ]] && systemctl reload fail2ban
                ;;
            r|R)
                systemctl reload fail2ban
                nftban_log_success "fail2ban reloaded"
                ;;
            [0-9]*)
                if [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#jails[@]} ]]; then
                    local jail="${jails[$((choice-1))]}"
                    
                    if nftban_jail_is_enabled "$jail"; then
                        nftban_template_undeploy_jail "$jail"
                    else
                        nftban_template_deploy_jail "$jail" "$os"
                    fi
                    
                    read -rp "Reload fail2ban? (y/N): " reload
                    [[ "$reload" =~ ^[Yy]$ ]] && systemctl reload fail2ban
                else
                    nftban_log_error "Invalid selection"
                fi
                ;;
            *)
                nftban_log_error "Invalid option"
                ;;
        esac
    done
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f nftban_jail_get_config
export -f nftban_jail_set_config
export -f nftban_jail_is_enabled
export -f nftban_jail_ensure_config
export -f nftban_jail_remove_config
export -f nftban_jail_list_configured
export -f nftban_template_process
export -f nftban_template_process_jail
export -f nftban_template_detect_os
export -f nftban_template_get_available_jails
export -f nftban_template_exists
export -f nftban_template_deploy_jail
export -f nftban_template_undeploy_jail
export -f nftban_template_redeploy_jail
export -f nftban_template_deploy_all
export -f nftban_template_undeploy_all
export -f nftban_template_redeploy_all
export -f nftban_template_show_jail_status
export -f nftban_template_list_jails
export -f nftban_template_validate
export -f nftban_template_validate_all
export -f nftban_template_interactive_menu

nftban_log_debug "NFTBan Template Processing Module loaded"