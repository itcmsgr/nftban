#!/bin/bash
set -euo pipefail

# =============================================================================
# NFTBAN Comprehensive Fail2Ban to NFTables Integration Script
# Version: 3.1 (Enhanced with Login Monitoring)
# Description: Complete automation for fail2ban configuration with nftables backend
#Key Changes Made:
#User Configuration File Support:
# Added CONFIG_FILE_USER="$BASE_DIR/config/nftban.conf.local"
# Created functions to check and update user configuration
#Added options to create/update user config via command line
# Configuration Management:
#check_and_update_user_config() - Compares user config with default and adds missing settings
#create_default_config() - Creates default config if it doesn't exist
#Added command-line options for config management
# User Notification:
#Informative messages when user config is created/updated
#Clear instructions to modify the user configuration file
# Preservation of Settings:
#When updating, existing values (especially email) are preserved
#Backup is created before making changes
#Recreation Functionality:
#The script can recreate all jails, filters, etc. based on the user configuration
#Added --update option to refresh configuration from templates
#Usage Examples:
#Create user configuration:
#sudo ./nftban.sh --create-user-config
#Check for missing settings:
#sudo ./nftban.sh --check-config
#Update user configuration:
#sudo ./nftban.sh --update-config
#Full installation with user config:
#sudo ./nftban.sh --install
#The script will automatically handle the user configuration file, creating it if it doesn't exist, and updating it with any missing settings while preserving your custom values.

# =============================================================================

# Configuration
BASE_DIR="/etc/nftban"
LOGFILE="/var/log/nftban/nftban-setup.log"
LOGFILE_IP="/var/log/nftban/nftban-bans.log"
CONFIG_FILE="$BASE_DIR/config/nftban.conf"
CONFIG_FILE_USER="$BASE_DIR/config/nftban.conf.local"
TEMPLATE_DIR="$BASE_DIR/templates/fail2ban"
WHITELIST_FILE="$BASE_DIR/config/nftban-configuration-user-whitelist_ips.conf.local"
BLACKLIST_FILE="$BASE_DIR/config/nftban-configuration-user-blacklist_ips.conf.local"
LOGIN_MONITOR_CONFIG="/etc/fail2ban/nftban-login-monitor.conf"

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

# Setup logrotate configuration
setup_logrotate() {
    local logrotate_conf="/etc/logrotate.d/nftban"
    log_message "INFO" "Setting up log rotation at $logrotate_conf"
    cat > "$logrotate_conf" <<EOF
$LOGFILE {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    create 0640 root adm
}

/var/log/nftban-login-monitor.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
}

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

# Function to create list files
create_list_files() {
    create_whitelist_file
    # Create blacklist file if it doesn't exist
    if [ ! -f "$BLACKLIST_FILE" ]; then
        touch "$BLACKLIST_FILE"
        chmod 644 "$BLACKLIST_FILE"
        log_message "INFO" "Created blacklist file: $BLACKLIST_FILE"
    fi
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
        "directadmin")
            echo "/var/log/directadmin/login.log|http,https|systemd"
            ;;
        "wordpress")
            echo "/var/log/apache2/error.log|http,https|systemd"
            ;;
        "xmlrpc")
            echo "/var/log/apache2/access.log|http,https|systemd"
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
    local config_file="$1"
    log_message "INFO" "Creating default configuration at $config_file..."
    
    cat > "$config_file" << 'EOF'
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

# Login Monitoring Settings
NFTBAN_F2B_LOGIN_MONITOR="true"           # Enable login monitoring service
NFTBAN_F2B_ROOT_LOGIN_ALERT="true"        # Alert on root logins (CRITICAL)
NFTBAN_F2B_SUDO_ALERT="true"              # Alert on sudo usage
NFTBAN_F2B_SSH_LOGIN_ALERT="false"        # Alert on ALL SSH logins (can be noisy)
NFTBAN_F2B_FAILED_LOGIN_THRESHOLD="5"     # Alert after N failed logins from same IP

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

NFTBAN_F2B_WORDPRESS_JAIL="true"
NFTBAN_F2B_WORDPRESS_BAN_TIME="7200"
NFTBAN_F2B_WORDPRESS_MAX_RETRY="3"
NFTBAN_F2B_WORDPRESS_FIND_TIME="600"

NFTBAN_F2B_XMLRPC_JAIL="true"
NFTBAN_F2B_XMLRPC_BAN_TIME="10800"
NFTBAN_F2B_XMLRPC_MAX_RETRY="2"
NFTBAN_F2B_XMLRPC_FIND_TIME="300"

NFTBAN_F2B_DIRECTADMIN_JAIL="true"
NFTBAN_F2B_DIRECTADMIN_BAN_TIME="14400"
NFTBAN_F2B_DIRECTADMIN_MAX_RETRY="3"
NFTBAN_F2B_DIRECTADMIN_FIND_TIME="600"

# Whitelist file
NFTBAN_F2B_IGNOREIP="$BASE_DIR/config/nftban-configuration-user-whitelist_ips.conf.local"
EOF

    chmod 600 "$config_file"
    log_message "INFO" "Created default configuration: $config_file"
}

# Function to check and update user configuration
check_and_update_user_config() {
    log_message "INFO" "Checking user configuration for missing settings..."
    
    # If user config doesn't exist, create it from default
    if [ ! -f "$CONFIG_FILE_USER" ]; then
        log_message "WARN" "User configuration not found, creating from default"
        cp "$CONFIG_FILE" "$CONFIG_FILE_USER"
        chmod 600 "$CONFIG_FILE_USER"
        echo -e "${YELLOW}User configuration created at: $CONFIG_FILE_USER${NC}"
        echo -e "${YELLOW}Please edit this file to customize your settings${NC}"
        return 0
    fi
    
    # Check for missing settings in user config
    local missing_settings=()
    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && continue
        
        # Extract variable name
        var_name=$(echo "$line" | cut -d'=' -f1 | tr -d '[:space:]')
        
        # Check if this setting exists in user config
        if ! grep -q "^[[:space:]]*$var_name=" "$CONFIG_FILE_USER"; then
            missing_settings+=("$line")
        fi
    done < "$CONFIG_FILE"
    
    # If missing settings found, add them to user config
    if [ ${#missing_settings[@]} -gt 0 ]; then
        log_message "WARN" "Found ${#missing_settings[@]} missing settings in user configuration"
        echo -e "${YELLOW}Adding missing settings to user configuration...${NC}"
        
        # Backup current user config
        local backup_file="${CONFIG_FILE_USER}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$CONFIG_FILE_USER" "$backup_file"
        log_message "INFO" "Backed up user config to $backup_file"
        
        # Append missing settings to user config
        echo -e "\n# Added missing settings on $(date)" >> "$CONFIG_FILE_USER"
        for setting in "${missing_settings[@]}"; do
            echo "$setting" >> "$CONFIG_FILE_USER"
            log_message "INFO" "Added missing setting: $setting"
        done
        
        echo -e "${YELLOW}User configuration updated. Backup saved to $backup_file${NC}"
        echo -e "${YELLOW}Please review and customize the new settings in: $CONFIG_FILE_USER${NC}"
    else
        log_message "INFO" "User configuration is up to date"
    fi
}

# Function to create login monitor configuration
create_login_monitor_config() {
    log_message "INFO" "Creating login monitor configuration..."
    
    cat > "$LOGIN_MONITOR_CONFIG" << 'EOF'
# =============================================================================
# NFTBAN Login Monitor Configuration
# =============================================================================

# Email Settings
NFTBAN_F2B_RECIPIENT="admin@yourdomain.com"
NFTBAN_F2B_SENDER="nftban@$(hostname -f)"
NFTBAN_F2B_SMTP_HOST="localhost"
NFTBAN_F2B_SMTP_PORT="25"

# Alert Settings
NFTBAN_F2B_ALERT_ENABLED="true"      # Enable email alerts: true or false

# Login Monitoring Settings
NFTBAN_F2B_LOGIN_MONITOR="true"           # Enable login monitoring service
NFTBAN_F2B_ROOT_LOGIN_ALERT="true"        # Alert on root logins (CRITICAL)
NFTBAN_F2B_SUDO_ALERT="true"              # Alert on sudo usage
NFTBAN_F2B_SSH_LOGIN_ALERT="false"        # Alert on ALL SSH logins (can be noisy)
NFTBAN_F2B_FAILED_LOGIN_THRESHOLD="5"     # Alert after N failed logins from same IP

# Enhanced Security Settings
NFTBAN_F2B_GEOIP_ENABLE="true"           # Include GeoIP info in alerts
NFTBAN_F2B_WHOIS_ENABLE="true"           # Include WHOIS info in alerts

# Service-specific overrides
NFTBAN_F2B_ROOT_BAN_TIME="86400"         # Root attempt ban time (24 hours)
NFTBAN_F2B_SUDO_BAN_TIME="1800"          # Sudo failure ban time (30 minutes)
EOF

    chmod 644 "$LOGIN_MONITOR_CONFIG"
    log_message "INFO" "Created login monitor configuration: $LOGIN_MONITOR_CONFIG"
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

    # WordPress Filter
    cat > "$TEMPLATE_DIR/filter.d/nftban-wordpress-filter.conf" << 'EOF'
[Definition]
failregex = ^<HOST> .* "POST .*wp-login\.php.* HTTP/.*" 200 .*$
            ^<HOST> .* "POST .*xmlrpc\.php.* HTTP/.*" 200 .*$
            ^<HOST> .* "POST .*/wp-admin/.* HTTP/.*" 200 .*$
            ^<HOST> .* "POST .*wp-login\.php.* HTTP/.*" 302 .*$
            ^<HOST> .* "POST .*wp-login\.php.* HTTP/.*" 404 .*$
            ^<HOST> .* "POST .*wp-admin/admin-ajax\.php.* HTTP/.*" 200 .*$

ignoreregex = ^<HOST> .* "(GET|POST).*wp-(login|admin).* HTTP/.*" (200|302) .*user=(admin|administrator).*$
EOF

    # XML-RPC Filter
    cat > "$TEMPLATE_DIR/filter.d/nftban-xmlrpc-filter.conf" << 'EOF'
[Definition]
failregex = ^<HOST> .* "POST .*xmlrpc\.php.* HTTP/.*" 200 .*$
            ^<HOST> .* "POST .*xmlrpc\.php.* HTTP/.*" 403 .*$
            ^<HOST> .* "POST .*xmlrpc\.php.* HTTP/.*" 405 .*$
            ^<HOST> .* "POST .*xmlrpc\.php.* HTTP/.*" 500 .*$
            ^<HOST> .* "POST .*xmlrpc\.php.* HTTP/.*" 501 .*$
            ^<HOST> .* "POST .*xmlrpc\.php.* HTTP/.*" 200.*system\.multicall.*$

ignoreregex = ^<HOST> .* "POST .*xmlrpc\.php.* HTTP/.*" 200.*wp\.getUsersBlogs.*$
EOF

    # DirectAdmin Filter
    cat > "$TEMPLATE_DIR/filter.d/nftban-directadmin-filter.conf" << 'EOF'
[Definition]
failregex = ^: '<HOST>' \d{1,3} failed login attempt(s)?. \s*$

ignoreregex = 

datepattern = ^%%Y:%%m:%%d-%%H:%%M:%%S
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
        "wordpress") service_info=$(get_os_service_info "$os_type" "wordpress") ;;
        "xmlrpc") service_info=$(get_os_service_info "$os_type" "xmlrpc") ;;
        "directadmin") service_info=$(get_os_service_info "$os_type" "directadmin") ;;
        *) 
            log_message "WARN" "Unknown jail type: $jail_name"
            return 1
            ;;
    esac
    
    IFS='|' read -r logpath port backend <<< "$service_info"
    
    # Create jail configuration
    local jail_file="$F2B_JAIL_DIR/nftban-${jail_name,,}.conf"
    
    cat > "$jail_file" << EOF
# NFTBAN ${jail_name} Jail
[nftban-${jail_name,,}]
enabled = ${!jail_enabled_var}
port = $port
filter = nftban-${jail_name,,}-filter
logpath = $logpath
backend = ${NFTBAN_F2B_BACKEND:-systemd}
bantime = ${NFTBAN_F2B_${jail_name}_BAN_TIME:-${NFTBAN_F2B_DEF_BAN_TIME}}
maxretry = ${NFTBAN_F2B_${jail_name}_MAX_RETRY:-${NFTBAN_F2B_DEF_MAX_RETRY}}
findtime = ${NFTBAN_F2B_${jail_name}_FIND_TIME:-${NFTBAN_F2B_DEF_FIND_TIME}}
ignoreip = file:${NFTBAN_F2B_IGNOREIP}
action = nftban-nftables[name=${jail_name,,}, port="$port"]
         %(nftban_email)s
EOF
    
    log_message "INFO" "Created jail configuration: $jail_file"
    
    # Copy filter if it doesn't exist
    local filter_file="$F2B_FILTER_DIR/nftban-${jail_name,,}-filter.conf"
    if [ ! -f "$filter_file" ]; then
        cp "$TEMPLATE_DIR/filter.d/nftban-${jail_name,,}-filter.conf" "$filter_file"
        log_message "INFO" "Copied filter configuration: $filter_file"
    fi
    
    return 0
}

# Function to setup fail2ban actions
setup_fail2ban_actions() {
    # Copy nftables action if it doesn't exist
    if [ ! -f "$F2B_ACTION_DIR/nftban-nftables.conf" ]; then
        cp "$TEMPLATE_DIR/action.d/nftban-nftables.conf" "$F2B_ACTION_DIR/"
        log_message "INFO" "Copied nftables action: $F2B_ACTION_DIR/nftban-nftables.conf"
    fi
    
    # Copy email action if it doesn't exist
    if [ ! -f "$F2B_ACTION_DIR/nftban-email.conf" ]; then
        cp "$TEMPLATE_DIR/action.d/nftban-email.conf" "$F2B_ACTION_DIR/"
        log_message "INFO" "Copied email action: $F2B_ACTION_DIR/nftban-email.conf"
    fi
    
    # Create action.d/nftban-common.local if it doesn't exist
    local common_local="$F2B_ACTION_DIR/nftban-common.local"
    if [ ! -f "$common_local" ]; then
        cat > "$common_local" << 'EOF'
# NFTBAN Common Actions
[nftban_email]
actionban = nftban-nftables[name=<name>, port="<port>"]
            nftban-email[name=<name>, dest="%(destemail)s"]

actionunban = nftban-nftables[name=<name>, port="<port>"]
              nftban-email[name=<name>, dest="%(destemail)s"]
EOF
        log_message "INFO" "Created common actions: $common_local"
    fi
}

# Function to create login monitor service
create_login_monitor_service() {
    if [ "${NFTBAN_F2B_LOGIN_MONITOR:-true}" != "true" ]; then
        log_message "INFO" "Login monitor is disabled, skipping service creation"
        return 0
    fi
    
    # Create login monitor script
    cat > /usr/local/bin/nftban-login-monitor.sh << 'EOF'
#!/bin/bash
# NFTBAN Login Monitor Service

CONFIG_FILE="/etc/fail2ban/nftban-login-monitor.conf"
LOG_FILE="/var/log/nftban-login-monitor.log"
FAILED_LOGINS_FILE="/var/lib/nftban/failed-logins.db"

# Load configuration
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "$(date): Configuration file not found: $CONFIG_FILE" >> "$LOG_FILE"
    exit 1
fi

# Function to send alert
send_alert() {
    local level="$1"
    local message="$2"
    local ip="$3"
    
    local subject="[NFTBAN $level] $message on $(hostname)"
    local full_message="$message
    
Time: $(date -R)
Level: $level
IP: $ip
Hostname: $(hostname -f)"

    # Add GeoIP info if enabled
    if [ "$NFTBAN_F2B_GEOIP_ENABLE" = "true" ] && command -v geoiplookup &>/dev/null; then
        geoip_info=$(geoiplookup "$ip" 2>/dev/null || echo "GeoIP info unavailable")
        full_message="$full_message
GeoIP Location: $geoip_info"
    fi

    # Add WHOIS info if enabled
    if [ "$NFTBAN_F2B_WHOIS_ENABLE" = "true" ] && command -v whois &>/dev/null; then
        whois_info=$(timeout 10 whois "$ip" 2>/dev/null | head -10 | grep -E "(NetName|Organization|Country|abuse)" || echo "WHOIS info unavailable")
        full_message="$full_message
WHOIS Information:
$whois_info"
    fi

    # Send email
    if command -v mail &>/dev/null; then
        echo "$full_message" | mail -s "$subject" "$NFTBAN_F2B_RECIPIENT"
    elif command -v mailx &>/dev/null; then
        echo "$full_message" | mailx -s "$subject" "$NFTBAN_F2B_RECIPIENT"
    fi
    
    echo "$(date): ALERT: $level - $message - IP: $ip" >> "$LOG_FILE"
}

# Function to track failed logins
track_failed_login() {
    local ip="$1"
    local timestamp=$(date +%s)
    
    # Create directory if it doesn't exist
    mkdir -p "$(dirname "$FAILED_LOGINS_FILE")"
    
    # Add or update failed login count
    if grep -q "^$ip:" "$FAILED_LOGINS_FILE" 2>/dev/null; then
        # Update existing entry
        sed -i "s/^$ip:.*/$ip:$timestamp:$(($(grep "^$ip:" "$FAILED_LOGINS_FILE" | cut -d: -f3) + 1))/" "$FAILED_LOGINS_FILE"
    else
        # Add new entry
        echo "$ip:$timestamp:1" >> "$FAILED_LOGINS_FILE"
    fi
    
    # Check if threshold exceeded
    local count=$(grep "^$ip:" "$FAILED_LOGINS_FILE" | cut -d: -f3)
    if [ "$count" -ge "${NFTBAN_F2B_FAILED_LOGIN_THRESHOLD:-5}" ]; then
        send_alert "WARNING" "Multiple failed login attempts detected" "$ip"
        # Reset counter after alert
        sed -i "s/^$ip:.*/$ip:$timestamp:0/" "$FAILED_LOGINS_FILE"
    fi
}

# Function to clean old entries
clean_old_entries() {
    local current_time=$(date +%s)
    local threshold=$((current_time - 3600)) # 1 hour
    
    if [ -f "$FAILED_LOGINS_FILE" ]; then
        # Remove entries older than 1 hour
        while IFS=: read -r ip timestamp count; do
            if [ "$timestamp" -lt "$threshold" ]; then
                sed -i "/^$ip:/d" "$FAILED_LOGINS_FILE"
            fi
        done < <(cat "$FAILED_LOGINS_FILE")
    fi
}

# Main monitoring loop
monitor_logs() {
    local os_type=$(detect_os)
    local auth_log=""
    
    case "$os_type" in
        "UBUNTU"|"DEBIAN") auth_log="/var/log/auth.log" ;;
        "RHEL"|"CENTOS"|"FEDORA") auth_log="/var/log/secure" ;;
        *) auth_log="/var/log/auth.log" ;;
    esac
    
    if [ ! -f "$auth_log" ]; then
        echo "$(date): ERROR: Auth log not found: $auth_log" >> "$LOG_FILE"
        return 1
    fi
    
    # Use tail -F to follow log file
    tail -F "$auth_log" | while read -r line; do
        # Check for root login
        if [ "$NFTBAN_F2B_ROOT_LOGIN_ALERT" = "true" ] && echo "$line" | grep -q "root.*session opened"; then
            ip=$(echo "$line" | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' | head -1)
            if [ -n "$ip" ]; then
                send_alert "CRITICAL" "Root login detected" "$ip"
            fi
        fi
        
        # Check for sudo usage
        if [ "$NFTBAN_F2B_SUDO_ALERT" = "true" ] && echo "$line" | grep -q "sudo.*COMMAND"; then
            user=$(echo "$line" | grep -oE 'sudo:.*USER=[^ ]+' | cut -d= -f2)
            ip=$(echo "$line" | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' | head -1)
            if [ -n "$ip" ] && [ -n "$user" ]; then
                send_alert "INFO" "Sudo command executed by $user" "$ip"
            fi
        fi
        
        # Check for SSH logins
        if [ "$NFTBAN_F2B_SSH_LOGIN_ALERT" = "true" ] && echo "$line" | grep -q "sshd.*session opened"; then
            ip=$(echo "$line" | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' | head -1)
            user=$(echo "$line" | grep -oE 'for.*from' | sed 's/for //;s/ from//')
            if [ -n "$ip" ] && [ -n "$user" ]; then
                send_alert "INFO" "SSH login by $user" "$ip"
            fi
        fi
        
        # Track failed logins
        if echo "$line" | grep -q "authentication failure\|Failed password\|Invalid user"; then
            ip=$(echo "$line" | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' | head -1)
            if [ -n "$ip" ]; then
                track_failed_login "$ip"
            fi
        fi
        
        # Clean old entries every 100 lines
        local line_count=$((line_count + 1))
        if [ $((line_count % 100)) -eq 0 ]; then
            clean_old_entries
        fi
    done
}

# Start monitoring
line_count=0
monitor_logs
EOF

    chmod +x /usr/local/bin/nftban-login-monitor.sh
    
    # Create systemd service
    cat > /etc/systemd/system/nftban-login-monitor.service << 'EOF'
[Unit]
Description=NFTBAN Login Monitor Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/nftban-login-monitor.sh
Restart=always
RestartSec=5
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

    # Create logrotate config for login monitor
    cat > /etc/logrotate.d/nftban-login-monitor << 'EOF'
/var/log/nftban-login-monitor.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF

    log_message "INFO" "Created login monitor service"
}

# Function to install login monitor service
install_login_monitor_service() {
    if [ "${NFTBAN_F2B_LOGIN_MONITOR:-true}" != "true" ]; then
        log_message "INFO" "Login monitor is disabled, skipping installation"
        return 0
    fi
    
    log_message "INFO" "Installing login monitor service..."
    
    # Reload systemd
    systemctl daemon-reload
    
    # Enable and start service
    systemctl enable nftban-login-monitor.service
    systemctl start nftban-login-monitor.service
    
    log_message "INFO" "Login monitor service installed and started"
}

# Function to setup directories
setup_directories() {
    local dirs=(
        "$BASE_DIR"
        "$BASE_DIR/config"
        "$BASE_DIR/templates"
        "$BASE_DIR/templates/fail2ban"
        "$BASE_DIR/templates/fail2ban/jail.d"
        "$BASE_DIR/templates/fail2ban/filter.d"
        "$BASE_DIR/templates/fail2ban/action.d"
        "/var/log/nftban"
        "/var/lib/nftban"
    )
    
    for dir in "${dirs[@]}"; do
        if [ ! -d "$dir" ]; then
            mkdir -p "$dir"
            chmod 755 "$dir"
            log_message "INFO" "Created directory: $dir"
        fi
    done
    
    # Create log files if they don't exist
    touch "$LOGFILE" "$LOGFILE_IP"
    chmod 640 "$LOGFILE" "$LOGFILE_IP"
    chown root:adm "$LOGFILE" "$LOGFILE_IP" 2>/dev/null || true
}

# Function to setup configuration
setup_configuration() {
    log_message "INFO" "Setting up configuration..."
    
    # Create default config if it doesn't exist
    if [ ! -f "$CONFIG_FILE" ]; then
        create_default_config "$CONFIG_FILE"
    fi
    
    # Check and update user config
    check_and_update_user_config
    
    # Load configuration
    if [ -f "$CONFIG_FILE_USER" ]; then
        source "$CONFIG_FILE_USER"
        log_message "INFO" "Loaded user configuration: $CONFIG_FILE_USER"
    else
        source "$CONFIG_FILE"
        log_message "INFO" "Loaded default configuration: $CONFIG_FILE"
    fi
    
    # Create login monitor config
    create_login_monitor_config
    
    # Create list files
    create_list_files
}

# Function to setup templates
setup_templates() {
    log_message "INFO" "Setting up templates..."
    
    # Create filter templates
    create_filter_templates
    
    # Create nftables action
    create_nftables_action
    
    # Create email action
    create_email_action
    
    # Create alert script
    create_alert_script
    
    # Create jail templates for different OS types
    local os_types=("UBUNTU" "DEBIAN" "RHEL" "CENTOS" "FEDORA")
    local jails=("SSH" "Apache" "Nginx" "Postfix" "WordPress" "XMLRPC" "DirectAdmin")
    
    for os_type in "${os_types[@]}"; do
        for jail in "${jails[@]}"; do
            local service_info
            case "${jail,,}" in
                "ssh") service_info=$(get_os_service_info "$os_type" "sshd") ;;
                "apache") service_info=$(get_os_service_info "$os_type" "apache2") ;;
                "nginx") service_info=$(get_os_service_info "$os_type" "nginx") ;;
                "postfix") service_info=$(get_os_service_info "$os_type" "postfix") ;;
                "wordpress") service_info=$(get_os_service_info "$os_type" "wordpress") ;;
                "xmlrpc") service_info=$(get_os_service_info "$os_type" "xmlrpc") ;;
                "directadmin") service_info=$(get_os_service_info "$os_type" "directadmin") ;;
            esac
            create_jail_template "$jail" "$os_type" "$service_info"
        done
    done
}

# Function to setup fail2ban
setup_fail2ban() {
    log_message "INFO" "Setting up fail2ban..."
    
    local os_type=$(detect_os)
    
    # Install fail2ban if not installed
    if ! command -v fail2ban-server &>/dev/null; then
        log_message "INFO" "Installing fail2ban..."
        case "$os_type" in
            "UBUNTU"|"DEBIAN")
                apt-get update
                apt-get install -y fail2ban
                ;;
            "RHEL"|"CENTOS"|"FEDORA")
                yum install -y fail2ban
                ;;
            *)
                log_message "ERROR" "Unsupported OS for automatic fail2ban installation: $os_type"
                return 1
                ;;
        esac
    fi
    
    # Backup existing jail.local
    backup_jail_local
    
    # Create fail2ban directories if they don't exist
    mkdir -p "$F2B_JAIL_DIR" "$F2B_FILTER_DIR" "$F2B_ACTION_DIR"
    
    # Setup fail2ban actions
    setup_fail2ban_actions
    
    # Process jail configurations
    local jails=("SSH" "Apache" "Nginx" "Postfix" "WordPress" "XMLRPC" "DirectAdmin")
    for jail in "${jails[@]}"; do
        process_jail_config "$jail" "$os_type"
    done
    
    # Create jail.local
    cat > "$F2B_JAIL_LOCAL" << 'EOF'
# NFTBAN Main Configuration
[DEFAULT]
ignoreip = file:/etc/nftban/config/nftban-configuration-user-whitelist_ips.conf.local
bantime = 3600
findtime = 600
maxretry = 5
backend = systemd
destemail = root@localhost
sender = root@$(hostname -f)
mta = sendmail
action = %(action_)s

# Include NFTBAN jails
[INCLUDES]
before = jail.d/*.conf
EOF
    
    log_message "INFO" "Created main fail2ban configuration: $F2B_JAIL_LOCAL"
    
    # Restart fail2ban
    systemctl restart fail2ban
    systemctl enable fail2ban
    
    log_message "INFO" "Fail2ban setup completed"
}

# Function to setup login monitor
setup_login_monitor() {
    if [ "${NFTBAN_F2B_LOGIN_MONITOR:-true}" != "true" ]; then
        log_message "INFO" "Login monitor is disabled, skipping setup"
        return 0
    fi
    
    log_message "INFO" "Setting up login monitor..."
    
    # Create login monitor service
    create_login_monitor_service
    
    # Install the service
    install_login_monitor_service
    
    log_message "INFO" "Login monitor setup completed"
}

# Function to apply nftables configuration
apply_nftables_config() {
    log_message "INFO" "Applying nftables configuration..."
    
    # Check if nftables is installed
    if ! command -v nft &>/dev/null; then
        log_message "ERROR" "nftables is not installed"
        return 1
    fi
    
    # Create base nftables configuration if it doesn't exist
    if [ ! -f /etc/nftables.conf ]; then
        cat > /etc/nftables.conf << 'EOF'
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        
        # Established connections
        ct state established,related accept
        
        # Loopback interface
        iif lo accept
        
        # ICMP
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept
        
        # SSH
        tcp dport 22 accept
        
        # HTTP/HTTPS
        tcp dport {80, 443} accept
        
        # Drop invalid packets
        ct state invalid drop
    }
    
    chain forward {
        type filter hook forward priority 0; policy drop;
    }
    
    chain output {
        type filter hook output priority 0; policy accept;
    }
}
EOF
        log_message "INFO" "Created base nftables configuration"
    fi
    
    # Apply nftables rules
    nft -f /etc/nftables.conf
    
    # Enable nftables at boot
    systemctl enable nftables
    systemctl start nftables
    
    # Apply permanent blacklist
    apply_blacklist
    
    log_message "INFO" "nftables configuration applied"
}

# Function to validate configuration
validate_configuration() {
    log_message "INFO" "Validating configuration..."
    
    local errors=0
    
    # Check if configuration files exist
    if [ ! -f "$CONFIG_FILE" ]; then
        log_message "ERROR" "Main configuration file not found: $CONFIG_FILE"
        errors=$((errors + 1))
    fi
    
    if [ -f "$CONFIG_FILE_USER" ] && ! validate_file_syntax "$CONFIG_FILE_USER" "config"; then
        errors=$((errors + 1))
    fi
    
    # Check if fail2ban is installed
    if ! command -v fail2ban-server &>/dev/null; then
        log_message "ERROR" "fail2ban is not installed"
        errors=$((errors + 1))
    fi
    
    # Check if nftables is installed
    if ! command -v nft &>/dev/null; then
        log_message "ERROR" "nftables is not installed"
        errors=$((errors + 1))
    fi
    
    # Check email system if alerts are enabled
    if [ "${NFTBAN_F2B_ALERT_ENABLED:-false}" = "true" ]; then
        local email_system=$(check_email_system)
        if [ "$email_system" = "none" ]; then
            log_message "WARN" "Email alerts enabled but no email system found"
        else
            log_message "INFO" "Email system detected: $email_system"
        fi
    fi
    
    if [ $errors -eq 0 ]; then
        log_message "INFO" "Configuration validation passed"
        return 0
    else
        log_message "ERROR" "Configuration validation failed with $errors errors"
        return 1
    fi
}

# Function to show status
show_status() {
    echo -e "${GREEN}=== NFTBAN Status ===${NC}"
    echo
    
    # Fail2ban status
    if systemctl is-active --quiet fail2ban; then
        echo -e "${GREEN}✓ Fail2ban is running${NC}"
        echo "Jails:"
        fail2ban-client status | grep -A 100 "Jail list" | tr ',' '\n' | sed 's/^/  /'
    else
        echo -e "${RED}✗ Fail2ban is not running${NC}"
    fi
    echo
    
    # NFTables status
    if systemctl is-active --quiet nftables; then
        echo -e "${GREEN}✓ NFTables is running${NC}"
        echo "Rules:"
        nft list ruleset | grep -E "(chain|drop|accept)" | head -10 | sed 's/^/  /'
    else
        echo -e "${RED}✗ NFTables is not running${NC}"
    fi
    echo
    
    # Login monitor status
    if systemctl is-active --quiet nftban-login-monitor 2>/dev/null; then
        echo -e "${GREEN}✓ Login monitor is running${NC}"
    elif [ "${NFTBAN_F2B_LOGIN_MONITOR:-true}" = "true" ]; then
        echo -e "${YELLOW}⚠ Login monitor is not running${NC}"
    fi
    echo
    
    # Configuration status
    echo -e "${BLUE}Configuration Files:${NC}"
    echo "  Main config: $CONFIG_FILE"
    echo "  User config: $CONFIG_FILE_USER"
    echo "  Whitelist: $WHITELIST_FILE"
    echo "  Blacklist: $BLACKLIST_FILE"
    echo
    
    # Recent bans
    if [ -f "$LOGFILE_IP" ]; then
        echo -e "${BLUE}Recent Bans:${NC}"
        tail -5 "$LOGFILE_IP" | sed 's/^/  /'
    fi
}

# Function to show usage
usage() {
    cat << EOF
NFTBAN Comprehensive Fail2Ban to NFTables Integration Script

Usage: $0 [OPTIONS]

Options:
  -i, --install          Full installation and setup
  -c, --configure        Configure only (no installation)
  -u, --update           Update configuration from templates
  -s, --status           Show current status
  -v, --validate         Validate configuration
  -r, --reload           Reload services (fail2ban, nftables)
  -l, --logs             Show recent logs
  -h, --help             Show this help message

Configuration Management:
  --create-user-config   Create user configuration file
  --check-config         Check for missing settings in user config
  --update-config        Update user config with missing settings

Examples:
  $0 --install           # Full installation
  $0 --status            # Show status
  $0 --update-config     # Update user configuration
EOF
}

# Function to show logs
show_logs() {
    echo -e "${GREEN}=== Recent NFTBAN Logs ===${NC}"
    echo -e "${BLUE}Setup Log:${NC}"
    tail -20 "$LOGFILE" 2>/dev/null || echo "No log file found: $LOGFILE"
    echo
    echo -e "${BLUE}Bans Log:${NC}"
    tail -20 "$LOGFILE_IP" 2>/dev/null || echo "No bans log file found: $LOGFILE_IP"
    echo
    if [ -f "/var/log/nftban-login-monitor.log" ]; then
        echo -e "${BLUE}Login Monitor Log:${NC}"
        tail -20 "/var/log/nftban-login-monitor.log"
    fi
}

# Function to reload services
reload_services() {
    log_message "INFO" "Reloading services..."
    
    systemctl reload fail2ban 2>/dev/null || systemctl restart fail2ban
    systemctl reload nftables 2>/dev/null || systemctl restart nftables
    
    if systemctl is-active --quiet nftban-login-monitor 2>/dev/null; then
        systemctl restart nftban-login-monitor
    fi
    
    log_message "INFO" "Services reloaded"
}

# Main function
main() {
    local action=""
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i|--install)
                action="install"
                shift
                ;;
            -c|--configure)
                action="configure"
                shift
                ;;
            -u|--update)
                action="update"
                shift
                ;;
            -s|--status)
                action="status"
                shift
                ;;
            -v|--validate)
                action="validate"
                shift
                ;;
            -r|--reload)
                action="reload"
                shift
                ;;
            -l|--logs)
                action="logs"
                shift
                ;;
            --create-user-config)
                action="create_user_config"
                shift
                ;;
            --check-config)
                action="check_config"
                shift
                ;;
            --update-config)
                action="update_config"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo -e "${RED}Unknown option: $1${NC}"
                usage
                exit 1
                ;;
        esac
    done
    
    # Default action if none specified
    if [ -z "$action" ]; then
        action="install"
    fi
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Please run as root${NC}"
        exit 1
    fi
    
    # Setup directories first
    setup_directories
    setup_logrotate
    
    # Execute requested action
    case "$action" in
        "install")
            echo -e "${GREEN}Starting NFTBAN installation...${NC}"
            setup_configuration
            setup_templates
            setup_fail2ban
            setup_login_monitor
            apply_nftables_config
            validate_configuration
            show_status
            ;;
        "configure")
            echo -e "${GREEN}Configuring NFTBAN...${NC}"
            setup_configuration
            setup_fail2ban
            setup_login_monitor
            apply_nftables_config
            show_status
            ;;
        "update")
            echo -e "${GREEN}Updating NFTBAN configuration...${NC}"
            setup_configuration
            setup_templates
            setup_fail2ban
            apply_nftables_config
            reload_services
            show_status
            ;;
        "status")
            show_status
            ;;
        "validate")
            setup_configuration
            validate_configuration
            ;;
        "reload")
            reload_services
            show_status
            ;;
        "logs")
            show_logs
            ;;
        "create_user_config")
            if [ ! -f "$CONFIG_FILE_USER" ]; then
                cp "$CONFIG_FILE" "$CONFIG_FILE_USER"
                chmod 600 "$CONFIG_FILE_USER"
                echo -e "${GREEN}Created user configuration: $CONFIG_FILE_USER${NC}"
                echo -e "${YELLOW}Please edit this file to customize your settings${NC}"
            else
                echo -e "${YELLOW}User configuration already exists: $CONFIG_FILE_USER${NC}"
            fi
            ;;
        "check_config")
            check_and_update_user_config
            ;;
        "update_config")
            check_and_update_user_config
            echo -e "${GREEN}User configuration updated${NC}"
            ;;
        *)
            echo -e "${RED}Unknown action: $action${NC}"
            usage
            exit 1
            ;;
    esac
    
    echo -e "${GREEN}Action completed: $action${NC}"
}

# Handle script execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
