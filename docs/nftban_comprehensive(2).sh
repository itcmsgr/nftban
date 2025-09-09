    # Create list files
    create_list_files
    
    # Detect and add local IPs#!/bin/bash
set -euo pipefail

# =============================================================================
# NFTBAN Comprehensive Fail2Ban to NFTables Integration Script
# Version: 3.0
# Description: Complete automation for fail2ban configuration with nftables backend
# =============================================================================

# Configuration
BASE_DIR="/etc/nftban"
LOGFILE="/var/log/nftban/nftban-setup.log"
LOGFILE_IP="/var/log/nftban/nftban-bans.log"
CONFIG_FILE="$BASE_DIR/config/nftban.conf.local"
TEMPLATE_DIR="$BASE_DIR/templates/fail2ban"
WHITELIST_FILE="$BASE_DIR/config/nftban-configuration-user-whitelist_ips.conf.local"

# Fail2ban directories
F2B_JAIL_DIR="/etc/fail2ban/jail.d"
F2B_FILTER_DIR="/etc/fail2ban/filter.d"
F2B_ACTION_DIR="/etc/fail2ban/action.d"
F2B_JAIL_LOCAL="/etc/fail2ban/jail.local"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Ensure directories exist
mkdir -p "$BASE_DIR"/{config,templates/fail2ban/{jail.d,filter.d,action.d},logs,scripts}
mkdir -p "$F2B_JAIL_DIR" "$F2B_FILTER_DIR" "$F2B_ACTION_DIR"
mkdir -p "$(dirname "$LOGFILE")"
touch "$LOGFILE" "$LOGFILE_IP"
chmod 644 "$LOGFILE" "$LOGFILE_IP"

# Logging function with colors
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local color=""
    
    case "$level" in
        "ERROR") color="$RED" ;;
        "WARN") color="$YELLOW" ;;
        "INFO") color="$GREEN" ;;
        "DEBUG") color="$BLUE" ;;
    esac
    
    echo -e "${color}[$timestamp] [$level]${NC} $message" | tee -a "$LOGFILE"
}

# Function to prompt user for confirmation
confirm_action() {
    local message="$1"
    local default="${2:-y}"
    
    if [[ "$default" == "y" ]]; then
        prompt="[Y/n]"
    else
        prompt="[y/N]"
    fi
    
    while true; do
        echo -n -e "${YELLOW}$message $prompt${NC} "
        read -n 1 -r
        echo
        case "$REPLY" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            "") 
                if [[ "$default" == "y" ]]; then
                    return 0
                else
                    return 1
                fi
                ;;
            *) echo "Please answer yes or no." ;;
        esac
    done
}

# Function to backup existing jail.local
backup_jail_local() {
    if [ -f "$F2B_JAIL_LOCAL" ]; then
        local timestamp=$(date +"%Y%m%d_%H%M%S")
        local backup_name="${F2B_JAIL_LOCAL}_backup_${timestamp}"
        sudo mv "$F2B_JAIL_LOCAL" "$backup_name"
        log_message "INFO" "Backed up existing jail.local to $(basename "$backup_name")"
    fi
}

# Function to detect OS
detect_os() {
    if [ -f /etc/debian_version ]; then
        if grep -q "Ubuntu" /etc/os-release 2>/dev/null; then
            echo "UBUNTU"
        else
            echo "DEBIAN"
        fi
    elif [ -f /etc/redhat-release ] || [ -f /etc/centos-release ]; then
        if grep -q "CentOS" /etc/os-release 2>/dev/null; then
            echo "CENTOS"
        elif grep -q "Red Hat" /etc/os-release 2>/dev/null; then
            echo "RHEL"
        else
            echo "FEDORA"
        fi
    elif [ -f /etc/arch-release ]; then
        echo "ARCH"
    else
        echo "UNKNOWN"
    fi
}

# Function to get OS-specific service and log paths
get_os_service_info() {
    local os_type="$1"
    local service="$2"
    
    case "$service" in
        "sshd"|"ssh")
            case "$os_type" in
                "UBUNTU"|"DEBIAN")
                    echo "/var/log/auth.log|ssh|systemd"
                    ;;
                "RHEL"|"CENTOS"|"FEDORA")
                    echo "/var/log/secure|ssh|systemd"
                    ;;
                *)
                    echo "/var/log/auth.log|ssh|systemd"
                    ;;
            esac
            ;;
        "apache2"|"httpd")
            case "$os_type" in
                "UBUNTU"|"DEBIAN")
                    echo "/var/log/apache2/error.log|http,https|systemd"
                    ;;
                "RHEL"|"CENTOS"|"FEDORA")
                    echo "/var/log/httpd/error_log|http,https|systemd"
                    ;;
                *)
                    echo "/var/log/httpd/error_log|http,https|systemd"
                    ;;
            esac
            ;;
        "nginx")
            echo "/var/log/nginx/error.log|http,https|systemd"
            ;;
        "postfix")
            echo "/var/log/mail.log|smtp,submission,smtps|systemd"
            ;;
        *)
            echo "/var/log/messages|$service|systemd"
            ;;
    esac
}

# Function to check if email system is available
check_email_system() {
    local email_systems=("postfix" "exim4" "sendmail" "msmtp" "ssmtp")
    
    for system in "${email_systems[@]}"; do
        if systemctl is-active --quiet "$system" 2>/dev/null || command -v "$system" &>/dev/null; then
            echo "$system"
            return 0
        fi
    done
    
    if command -v mail &>/dev/null || command -v mailx &>/dev/null; then
        echo "mail"
        return 0
    fi
    
    echo "none"
    return 1
}

# Function to validate file syntax
validate_file_syntax() {
    local file="$1"
    local file_type="$2"
    
    [ -f "$file" ] || { log_message "ERROR" "$file_type file not found: $file"; return 1; }
    [ -r "$file" ] || { log_message "ERROR" "$file_type file not readable: $file"; return 1; }
    
    case "$file_type" in
        "config")
            # Check for basic key=value pairs and proper variable names
            if grep -q -E '^[[:space:]]*NFTBAN_F2B_[A-Z0-9_]+=' "$file"; then
                return 0
            else
                log_message "ERROR" "Configuration file has invalid format: $file"
                return 1
            fi
            ;;
        "jail")
            if grep -q -E '^\[[^]]+\]' "$file" && grep -q -E '^enabled[[:space:]]*=' "$file"; then
                return 0
            else
                log_message "ERROR" "Jail file missing required sections: $file"
                return 1
            fi
            ;;
        "filter")
            if grep -q -E '^\[Definition\]' "$file" && grep -q -E '^failregex[[:space:]]*=' "$file"; then
                return 0
            else
                log_message "ERROR" "Filter file missing [Definition] or failregex: $file"
                return 1
            fi
            ;;
        "action")
            if grep -q -E '^\[Definition\]' "$file" && grep -q -E '^actionban[[:space:]]*=' "$file"; then
                return 0
            else
                log_message "ERROR" "Action file missing [Definition] or actionban: $file"
                return 1
            fi
            ;;
    esac
    return 1
}

# Function to create default configuration
create_default_config() {
    log_message "INFO" "Creating default configuration..."
    
    cat > "$CONFIG_FILE" << 'EOF'
# =============================================================================
# NFTBAN Configuration File
# =============================================================================

# Email Settings
NFTBAN_F2B_RECIPIENT="admin@yourdomain.com"
NFTBAN_F2B_SENDER="nftban@$(hostname -f)"
NFTBAN_F2B_ALERT_ENABLED="true"

# Default Settings
NFTBAN_F2B_DEF_BAN_TIME="3600"        # 1 hour
NFTBAN_F2B_DEF_FIND_TIME="600"        # 10 minutes  
NFTBAN_F2B_DEF_MAX_RETRY="5"          # Max attempts
NFTBAN_F2B_BACKEND="systemd"          # Backend: systemd/polling

# Enhanced Security
NFTBAN_F2B_AGGRESSIVE_MODE="false"
NFTBAN_F2B_GEOIP_ENABLE="true"
NFTBAN_F2B_WHOIS_ENABLE="true"

# Jail Configurations - Set to "true" to enable
NFTBAN_F2B_SSH_JAIL="true"
NFTBAN_F2B_SSH_BAN_TIME="1800"
NFTBAN_F2B_SSH_MAX_RETRY="3"
NFTBAN_F2B_SSH_FIND_TIME="600"

NFTBAN_F2B_APACHE_JAIL="false"
NFTBAN_F2B_APACHE_BAN_TIME="3600"
NFTBAN_F2B_APACHE_MAX_RETRY="5"

NFTBAN_F2B_NGINX_JAIL="false" 
NFTBAN_F2B_NGINX_BAN_TIME="3600"
NFTBAN_F2B_NGINX_MAX_RETRY="5"

NFTBAN_F2B_POSTFIX_JAIL="false"
NFTBAN_F2B_POSTFIX_BAN_TIME="3600"
NFTBAN_F2B_POSTFIX_MAX_RETRY="5"

# Whitelist file
NFTBAN_F2B_IGNOREIP="$BASE_DIR/config/nftban-configuration-user-whitelist_ips.conf.local"
EOF

    chmod 600 "$CONFIG_FILE"
    log_message "INFO" "Created default configuration: $CONFIG_FILE"
}

# Function to create whitelist file
create_whitelist_file() {
    if [ ! -f "$WHITELIST_FILE" ]; then
        cat > "$WHITELIST_FILE" << 'EOF'
# NFTBAN IP Whitelist
# Add IP addresses or networks to ignore (one per line)
# Examples:
# 192.168.1.100
# 10.0.0.0/8
# 172.16.0.0/12

127.0.0.1
::1
EOF
        chmod 644 "$WHITELIST_FILE"
        log_message "INFO" "Created whitelist file: $WHITELIST_FILE"
    fi
}

# Function to create jail template
create_jail_template() {
    local jail_name="$1"
    local os_type="$2"
    local service_info="$3"
    
    IFS='|' read -r logpath port backend <<< "$service_info"
    
    local template_file="$TEMPLATE_DIR/jail.d/nftban-${jail_name,,}-jail-${os_type,,}.conf"
    
    cat > "$template_file" << EOF
# NFTBAN ${jail_name} Jail for ${os_type}
[nftban-${jail_name,,}]
enabled = [NFTBAN_F2B_${jail_name}_JAIL]
port = $port
filter = nftban-${jail_name,,}-filter
logpath = $logpath
backend = [NFTBAN_F2B_BACKEND]
bantime = [NFTBAN_F2B_${jail_name}_BAN_TIME]
maxretry = [NFTBAN_F2B_${jail_name}_MAX_RETRY]
findtime = [NFTBAN_F2B_${jail_name}_FIND_TIME]
ignoreip = [NFTBAN_F2B_IGNOREIP]
action = nftban-nftables[name=${jail_name,,}, port="$port"]
         %(nftban_email)s
EOF
    
    log_message "INFO" "Created jail template: $template_file"
}

# Function to create filter templates
create_filter_templates() {
    # SSH Filter
    cat > "$TEMPLATE_DIR/filter.d/nftban-ssh-filter.conf" << 'EOF'
[Definition]
failregex = ^%(__prefix_line)s(?:error: PAM: )?[aA]uthentication (?:failure|error|failed) for .* from <HOST>( via \S+)?\s*$
            ^%(__prefix_line)s(?:error: PAM: )?User not known to the underlying authentication module for .* from <HOST>\s*$
            ^%(__prefix_line)sFailed (?:password|publickey) for .* from <HOST>(?: port \d+)?(?: ssh\d*)?\s*$
            ^%(__prefix_line)sROOT LOGIN REFUSED.* FROM <HOST>\s*$
            ^%(__prefix_line)s[iI](?:llegal|nvalid) user .* from <HOST>(?: port \d+)?\s*$
            ^%(__prefix_line)sUser .+ from <HOST> not allowed because not listed in AllowUsers\s*$
            ^%(__prefix_line)sUser .+ from <HOST> not allowed because listed in DenyUsers\s*$
            ^%(__prefix_line)sConnection closed by authenticating user .* <HOST> port \d+.*(?: authentication failure|preauth)$
            ^%(__prefix_line)sReceived disconnect from <HOST>: 3: .*: Auth fail$

ignoreregex = 
EOF

    # Apache Filter  
    cat > "$TEMPLATE_DIR/filter.d/nftban-apache-filter.conf" << 'EOF'
[Definition]
failregex = ^<HOST> .* "(GET|POST|HEAD).*HTTP.*" (4\d\d|5\d\d) .*$
            ^%(__prefix_line)s\[.*:error\] \[pid .*\] \[client <HOST>\] .*$
            ^%(__prefix_line)s\[.*\] \[.*:error\] \[pid .*\] \[client <HOST>\] File does not exist: .*$
            ^%(__prefix_line)s\[.*\] \[.*:error\] \[pid .*\] \[client <HOST>\] script not found or unable to stat: .*$

ignoreregex = 
EOF

    # Nginx Filter
    cat > "$TEMPLATE_DIR/filter.d/nftban-nginx-filter.conf" << 'EOF'
[Definition]
failregex = ^<HOST> .* "(GET|POST|HEAD).*HTTP.*" (4\d\d|5\d\d) .*$
            ^\S+ <HOST> \S+ \S+ \[.*\] "\S+ \S+ HTTP/\S+" (4\d\d|5\d\d) \d+ ".*" ".*"$

ignoreregex = 
EOF

    # Postfix Filter
    cat > "$TEMPLATE_DIR/filter.d/nftban-postfix-filter.conf" << 'EOF'
[Definition]
failregex = ^.*postfix/smtpd\[\d+\]: NOQUEUE: reject: RCPT from \S+\[<HOST>\]: 55\d .*$
            ^.*postfix/smtpd\[\d+\]: warning: \S+\[<HOST>\]: SASL .* authentication failed.*$
            ^.*postfix/smtpd\[\d+\]: lost connection after AUTH from \S+\[<HOST>\]$

ignoreregex = 
EOF

    log_message "INFO" "Created filter templates"
}

# Function to create nftables action
create_nftables_action() {
    cat > "$TEMPLATE_DIR/action.d/nftban-nftables.conf" << 'EOF'
# NFTBAN NFTables Action
[Definition]
actionstart = nft add table inet f2b-<name>
              nft add set inet f2b-<name> banned4 { type ipv4_addr; timeout <bantime>s; }
              nft add set inet f2b-<name> banned6 { type ipv6_addr; timeout <bantime>s; }
              nft add chain inet f2b-<name> input { type filter hook input priority 0; }
              nft add rule inet f2b-<name> input ip saddr @banned4 counter drop
              nft add rule inet f2b-<name> input ip6 saddr @banned6 counter drop

actionstop = nft delete table inet f2b-<name> 2>/dev/null || true

actioncheck = nft list table inet f2b-<name> >/dev/null 2>&1

actionban = nft add element inet f2b-<name> banned4 { <ip> timeout <bantime>s } 2>/dev/null || \
            nft add element inet f2b-<name> banned6 { <ip> timeout <bantime>s }
            echo "$(date '+%%Y-%%m-%%d %%H:%%M:%%S') - Jail: <name> - Banned IP: <ip> - Ban time: <bantime>s" >> /var/log/nftban/nftban-bans.log

actionunban = nft delete element inet f2b-<name> banned4 { <ip> } 2>/dev/null || \
              nft delete element inet f2b-<name> banned6 { <ip> } 2>/dev/null || true

[Init]
bantime = 3600
EOF

    chmod 644 "$TEMPLATE_DIR/action.d/nftban-nftables.conf"
    log_message "INFO" "Created nftables action template"
}

# Function to create email action
create_email_action() {
    cat > "$TEMPLATE_DIR/action.d/nftban-email.conf" << 'EOF'
# NFTBAN Email Action  
[Definition]
actionstart = 
actionstop = 
actioncheck = 
actionban = /usr/local/bin/nftban-send-alert.sh <name> <ip> ban
actionunban = /usr/local/bin/nftban-send-alert.sh <name> <ip> unban

[Init]
EOF

    chmod 644 "$TEMPLATE_DIR/action.d/nftban-email.conf"
    log_message "INFO" "Created email action template"
}

# Function to create alert script
create_alert_script() {
    cat > /usr/local/bin/nftban-send-alert.sh << 'EOF'
#!/bin/bash
# NFTBAN Alert Script

JAIL="$1"
IP="$2" 
ACTION="${3:-ban}"
CONFIG_FILE="/etc/nftban/config/nftban.conf.local"

# Load configuration
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Configuration file not found: $CONFIG_FILE"
    exit 1
fi

# Exit if alerts disabled
[ "$NFTBAN_F2B_ALERT_ENABLED" = "true" ] || exit 0

# Function to send email
send_email() {
    local recipient="$1"
    local subject="$2"
    local message="$3"
    
    if command -v mail &>/dev/null; then
        echo "$message" | mail -s "$subject" "$recipient"
    elif command -v mailx &>/dev/null; then
        echo "$message" | mailx -s "$subject" "$recipient"
    else
        logger "NFTBAN: Cannot send email - no mail command available"
        return 1
    fi
}

# Create alert message
case "$ACTION" in
    "ban")
        subject="[NFTBAN] IP $IP banned in jail $JAIL on $(hostname)"
        action_text="BANNED"
        ;;
    "unban")  
        subject="[NFTBAN] IP $IP unbanned from jail $JAIL on $(hostname)"
        action_text="UNBANNED"
        ;;
    *)
        exit 1
        ;;
esac

message="IP Address $IP has been $action_text in jail $JAIL on $(hostname -f)

Time: $(date -R)
Action: $action_text  
Jail: $JAIL
IP: $IP
Hostname: $(hostname -f)"

# Add GeoIP information if available
if [ "$NFTBAN_F2B_GEOIP_ENABLE" = "true" ] && command -v geoiplookup &>/dev/null; then
    geoip_info=$(geoiplookup "$IP" 2>/dev/null || echo "GeoIP info unavailable")
    message="$message
GeoIP Location: $geoip_info"
fi

# Add WHOIS information if available  
if [ "$NFTBAN_F2B_WHOIS_ENABLE" = "true" ] && command -v whois &>/dev/null; then
    whois_info=$(timeout 10 whois "$IP" 2>/dev/null | head -10 | grep -E "(NetName|Organization|Country|abuse)" || echo "WHOIS info unavailable")
    message="$message
WHOIS Information:
$whois_info"
fi

message="$message

This is an automated message from NFTBAN monitoring system."

send_email "$NFTBAN_F2B_RECIPIENT" "$subject" "$message"
EOF

    chmod +x /usr/local/bin/nftban-send-alert.sh
    log_message "INFO" "Created alert script: /usr/local/bin/nftban-send-alert.sh"
}

# Function to check if IP is whitelisted
is_whitelisted() {
    local ip="$1"
    [ -f "$WHITELIST_FILE" ] && grep -qF "$ip" "$WHITELIST_FILE"
}

# Function to check if IP is blacklisted  
is_blacklisted() {
    local ip="$1"
    [ -f "$BLACKLIST_FILE" ] && grep -qF "$ip" "$BLACKLIST_FILE"
}

# Function to apply permanent bans from blacklist
apply_blacklist() {
    [ -f "$BLACKLIST_FILE" ] || return 0
    
    log_message "INFO" "Applying permanent bans from blacklist..."
    
    # Create permanent ban table if it doesn't exist
    if ! nft list table inet nftban-blacklist 2>/dev/null; then
        nft add table inet nftban-blacklist
        nft add set inet nftban-blacklist blacklisted4 { type ipv4_addr; }
        nft add set inet nftban-blacklist blacklisted6 { type ipv6_addr; }  
        nft add chain inet nftban-blacklist input { type filter hook input priority -1; }
        nft add rule inet nftban-blacklist input ip saddr @blacklisted4 counter drop
        nft add rule inet nftban-blacklist input ip6 saddr @blacklisted6 counter drop
        log_message "INFO" "Created permanent blacklist table"
    fi
    
    # Add IPs from blacklist file
    while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        
        # Clean the line
        ip=$(echo "$line" | tr -d '[:space:]')
        [[ -z "$ip" ]] && continue
        
        # Determine IP version and add to appropriate set
        if [[ "$ip" =~ : ]]; then
            # IPv6
            if ! nft list set inet nftban-blacklist blacklisted6 2>/dev/null | grep -q "$ip"; then
                nft add element inet nftban-blacklist blacklisted6 { $ip }
                log_message "INFO" "Added IPv6 $ip to permanent blacklist"
            fi
        else
            # IPv4
            if ! nft list set inet nftban-blacklist blacklisted4 2>/dev/null | grep -q "$ip"; then
                nft add element inet nftban-blacklist blacklisted4 { $ip }
                log_message "INFO" "Added IPv4 $ip to permanent blacklist"  
            fi
        fi
    done < "$BLACKLIST_FILE"
}

# Function to process jail configuration
process_jail_config() {
    local jail_name="$1"
    local os_type="$2"
    
    # Check if jail is enabled
    local jail_enabled_var="NFTBAN_F2B_${jail_name}_JAIL"
    if [ "${!jail_enabled_var:-false}" != "true" ]; then
        log_message "INFO" "Jail $jail_name is disabled, skipping"
        return 0
    fi
    
    log_message "INFO" "Processing jail: $jail_name for OS: $os_type"
    
    # Get service information
    local service_info
    case "${jail_name,,}" in
        "ssh") service_info=$(get_os_service_info "$os_type" "sshd") ;;
        "apache") service_info=$(get_os_service_info "$os_type" "apache2") ;;
        "nginx") service_info=$(get_os_service_info "$os_type" "nginx") ;;
        "postfix") service_info=$(get_os_service_info "$os_type" "postfix") ;;
        *) 
            log_message "WARN" "Unknown jail type: $jail_name"
            return 1
            ;;
    esac
    
    # Create jail template if it doesn't exist
    local jail_template="$TEMPLATE_DIR/jail.d/nftban-${jail_name,,}-jail-${os_type,,}.conf"
    if [ ! -f "$jail_template" ]; then
        create_jail_template "$jail_name" "$os_type" "$service_info"
    fi
    
    # Validate templates
    local filter_template="$TEMPLATE_DIR/filter.d/nftban-${jail_name,,}-filter.conf"
    
    if ! validate_file_syntax "$jail_template" "jail"; then
        log_message "ERROR" "Invalid jail template for $jail_name, skipping"
        return 1
    fi
    
    if ! validate_file_syntax "$filter_template" "filter"; then
        log_message "ERROR" "Invalid filter template for $jail_name, skipping"
        return 1  
    fi
    
    # Process jail template with variable substitution
    local jail_content=$(cat "$jail_template")
    
    # Replace configuration variables
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*[A-Z_]+=.*$ ]] || continue
        
        var_name=$(echo "$line" | cut -d'=' -f1 | tr -d '[:space:]')
        var_value="${!var_name:-}"
        
        # Handle file references
        if [[ "$var_value" == *".conf.local" ]] && [[ -f "$var_value" ]]; then
            jail_content=$(echo "$jail_content" | sed "s|\[${var_name}\]|${var_value}|g")
        else
            # Escape special characters for sed
            var_value_escaped=$(echo "$var_value" | sed 's/[\/&]/\\&/g')
            jail_content=$(echo "$jail_content" | sed "s|\[${var_name}\]|${var_value_escaped}|g")
        fi
    done < "$CONFIG_FILE"
    
    # Write processed jail configuration
    local jail_output="$F2B_JAIL_DIR/nftban-${jail_name,,}.conf"
    echo "$jail_content" > "$jail_output"
    log_message "INFO" "Created jail config: $jail_output"
    
    # Copy filter to fail2ban
    cp "$filter_template" "$F2B_FILTER_DIR/nftban-${jail_name,,}-filter.conf"
    log_message "INFO" "Installed filter: $F2B_FILTER_DIR/nftban-${jail_name,,}-filter.conf"
}

# Function to copy action files
install_actions() {
    # Copy nftables action
    if [ -f "$TEMPLATE_DIR/action.d/nftban-nftables.conf" ]; then
        cp "$TEMPLATE_DIR/action.d/nftban-nftables.conf" "$F2B_ACTION_DIR/"
        log_message "INFO" "Installed nftables action"
    fi
    
    # Copy email action if alerts enabled
    if [ "$NFTBAN_F2B_ALERT_ENABLED" = "true" ] && [ -f "$TEMPLATE_DIR/action.d/nftban-email.conf" ]; then
        cp "$TEMPLATE_DIR/action.d/nftban-email.conf" "$F2B_ACTION_DIR/"
        log_message "INFO" "Installed email action"
    fi
}

# Function to validate system requirements
validate_requirements() {
    local errors=0
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        log_message "ERROR" "This script must be run as root"
        errors=$((errors+1))
    fi
    
    # Check if fail2ban is installed
    if ! command -v fail2ban-server &>/dev/null; then
        log_message "ERROR" "fail2ban is not installed"
        errors=$((errors+1))
    fi
    
    # Check if nftables is installed
    if ! command -v nft &>/dev/null; then
        log_message "ERROR" "nftables is not installed" 
        errors=$((errors+1))
    fi
    
    # Check if fail2ban is running (and offer to stop it)
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        log_message "WARN" "fail2ban is currently running"
        if confirm_action "Stop fail2ban service for configuration?" "y"; then
            systemctl stop fail2ban
            log_message "INFO" "Stopped fail2ban service"
        else
            log_message "ERROR" "Cannot proceed with fail2ban running"
            errors=$((errors+1))
        fi
    fi
    
    return $errors
}

# Function to load and validate configuration
load_configuration() {
    # Create default configuration if it doesn't exist
    if [ ! -f "$CONFIG_FILE" ]; then
        log_message "WARN" "Configuration file not found, creating default"
        create_default_config
    fi
    
    # Validate configuration file
    if ! validate_file_syntax "$CONFIG_FILE" "config"; then
        log_message "ERROR" "Invalid configuration file"
        if confirm_action "Create new default configuration?" "y"; then
            create_default_config
        else
            return 1
        fi
    fi
    
    # Load configuration
    source "$CONFIG_FILE"
    log_message "INFO" "Loaded configuration from: $CONFIG_FILE"
    
    # Create list files
    create_list_files
    
    return 0
}

# Function to show status
show_status() {
    echo -e "\n${GREEN}=== NFTBAN Status ===${NC}"
    echo "Configuration: $CONFIG_FILE"
    echo "Log file: $LOGFILE"
    echo "IP log: $LOGFILE_IP"
    echo "OS Type: $(detect_os)"
    echo "Email system: $(check_email_system)"
    
    echo -e "\n${BLUE}=== File Status ===${NC}"
    echo "Whitelist: $([ -f "$WHITELIST_FILE" ] && echo "EXISTS" || echo "MISSING")"
    echo "Blacklist: $([ -f "$BLACKLIST_FILE" ] && echo "EXISTS" || echo "MISSING")"
    
    echo -e "\n${BLUE}=== Jail Configurations ===${NC}"
    ls -1 "$F2B_JAIL_DIR"/nftban-*.conf 2>/dev/null | wc -l | xargs echo "Active jails:"
    
    echo -e "\n${BLUE}=== Service Status ===${NC}"
    echo "fail2ban: $(systemctl is-active fail2ban 2>/dev/null || echo "inactive")"
    echo "nftables: $(systemctl is-active nftables 2>/dev/null || echo "inactive")"
    
    echo -e "\n${BLUE}=== NFTables Status ===${NC}"
    if command -v nft &>/dev/null; then
        nft list tables 2>/dev/null | grep -E "(f2b-|nftban-)" | wc -l | xargs echo "Active ban tables:"
    fi
}

# Main deployment function
deploy() {
    log_message "INFO" "Starting NFTBAN deployment..."
    
    # Validate requirements
    if ! validate_requirements; then
        log_message "ERROR" "System requirements not met"
        return 1
    fi
    
    # Load configuration
    if ! load_configuration; then
        log_message "ERROR" "Failed to load configuration"
        return 1
    fi
    
    # Backup existing jail.local
    backup_jail_local
    
    # Create template files
    create_filter_templates
    create_nftables_action
    
    if [ "$NFTBAN_F2B_ALERT_ENABLED" = "true" ]; then
        create_email_action
        create_alert_script
    fi
    
    # Detect OS and process jails
    local os_type=$(detect_os)
    log_message "INFO" "Detected OS: $os_type"
    
    # Process each configured jail
    local jails=("SSH" "APACHE" "NGINX" "POSTFIX")
    for jail in "${jails[@]}"; do
        process_jail_config "$jail" "$os_type"
    done
    
    # Install action files
    install_actions
    
    # Apply permanent blacklist
    apply_blacklist
    
    log_message "INFO" "NFTBAN deployment completed successfully"
    
    echo -e "\n${GREEN}Deployment completed!${NC}"
    echo -e "${YELLOW}Next steps:${NC}"
    echo "1. Review configuration: $CONFIG_FILE"
    echo "2. Update whitelist: $WHITELIST_FILE" 
    echo "3. Add permanent bans: $BLACKLIST_FILE"
    echo "4. Start fail2ban: systemctl start fail2ban"
    echo "5. Check status: $0 status"
}

# Main function
main() {
    local action="${1:-deploy}"
    
    case "$action" in
        deploy)
            deploy
            ;;
        status)
            show_status
            ;;
        test-alert)
            load_configuration
            if [ "$NFTBAN_F2B_ALERT_ENABLED" = "true" ]; then
                /usr/local/bin/nftban-send-alert.sh "TEST" "203.0.113.1" "ban"
                log_message "INFO" "Test alert sent"
            else
                log_message "INFO" "Email alerts are disabled"
            fi
            ;;
        reload)
            log_message "INFO" "Reloading NFTBAN configuration..."
            load_configuration
            systemctl reload fail2ban 2>/dev/null || true
            log_message "INFO" "Configuration reloaded"
            ;;
        blacklist-apply)
            load_configuration  
            apply_blacklist
            ;;
        *)
            echo "Usage: $0 {deploy|status|test-alert|reload|blacklist-apply}"
            echo ""
            echo "Commands:"
            echo "  deploy          - Deploy NFTBAN configuration"
            echo "  status          - Show current status"
            echo "  test-alert      - Send test email alert"  
            echo "  reload          - Reload configuration"
            echo "  blacklist-apply - Apply permanent blacklist"
            exit 1
            ;;
    esac
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi