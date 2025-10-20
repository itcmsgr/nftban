#!/bin/bash
# =============================================================================
# NFTBAN Installation & Setup Script
# Version: 0.9.0
# Location: lib/nftban_init_script.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Master script that orchestrates complete NFTBAN installation
# =============================================================================

set -euo pipefail

# =============================================================================
# SCRIPT CONFIGURATION
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

# Temporary utilities for this script (before full system is installed)
COLOR_RED="\033[0;31m"
COLOR_GREEN="\033[0;32m"
COLOR_YELLOW="\033[0;33m"
COLOR_BLUE="\033[0;34m"
COLOR_RESET="\033[0m"

log_info() { echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $1"; }
log_success() { echo -e "${COLOR_GREEN}[✓]${COLOR_RESET} $1"; }
log_warning() { echo -e "${COLOR_YELLOW}[WARNING]${COLOR_RESET} $1" >&2; }
log_error() { echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $1" >&2; }
log_fatal() { echo -e "${COLOR_RED}[FATAL]${COLOR_RESET} $1" >&2; exit 1; }

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_fatal "This script must be run as root. Use: sudo $0"
    fi
}

check_system_requirements() {
    log_info "Checking system requirements..."
    
    # Check OS
    if [[ ! -f /etc/os-release ]]; then
        log_fatal "Cannot determine OS. /etc/os-release not found."
    fi
    
    source /etc/os-release
    log_info "Detected OS: $NAME $VERSION"
    
    # Check required commands
    local missing_commands=()
    local required_commands=(
        "curl"
        "nft"
        "fail2ban-client"
        "systemctl"
        "grep"
        "sed"
        "awk"
    )
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_commands+=("$cmd")
        fi
    done
    
    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing_commands[*]}"
        log_info "Install missing packages:"
        log_info "  apt-get install curl nftables fail2ban"
        log_info "  OR"
        log_info "  yum install curl nftables fail2ban"
        return 1
    fi
    
    log_success "All required commands found"
    return 0
}

check_existing_installation() {
    if [[ -f "$BASE_DIR/config/nftban.conf" ]] && [[ -f "/usr/local/bin/nftban" ]]; then
        log_warning "NFTBAN appears to be already installed!"
        read -p "Reinstall/Update? [y/N]: " response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            log_info "Installation cancelled"
            exit 0
        fi
        log_info "Proceeding with reinstallation..."
    fi
}

# =============================================================================
# DIRECTORY STRUCTURE
# =============================================================================

create_directory_structure() {
    log_info "Creating directory structure..."
    
    local directories=(
        "$BASE_DIR/bin"
        "$BASE_DIR/lib"
        "$BASE_DIR/config"
        "$BASE_DIR/config/filters"
        "$BASE_DIR/config/actions"
        "$BASE_DIR/config/whitelist"
        "$BASE_DIR/config/feeds"
        "$BASE_DIR/data"
        "$BASE_DIR/data/feeds"
        "$BASE_DIR/data/cache"
        "$BASE_DIR/data/db"
        "$BASE_DIR/scripts"
        "$BASE_DIR/backups"
        "/var/log/nftban"
    )
    
    for dir in "${directories[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            log_success "Created: $dir"
        else
            log_info "Already exists: $dir"
        fi
    done
    
    # Set proper permissions
    chmod 755 "$BASE_DIR"
    chmod 755 "$BASE_DIR/bin"
    chmod 755 "$BASE_DIR/lib"
    chmod 755 "$BASE_DIR/scripts"
    chmod 750 "$BASE_DIR/config"
    chmod 750 "$BASE_DIR/data"
    chmod 755 "/var/log/nftban"
    
    log_success "Directory structure created"
}

# =============================================================================
# LOG ROTATION SETUP
# =============================================================================

setup_log_rotation() {
    log_info "Setting up log rotation..."
    
    # Create logrotate configuration
    cat > /etc/logrotate.d/nftban <<'EOF'
/var/log/nftban/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 0640 root adm
    sharedscripts
    postrotate
        systemctl reload fail2ban 2>/dev/null || true
    endscript
    size 10M
    maxage 30
}
EOF
    
    # Set proper permissions
    chmod 644 /etc/logrotate.d/nftban
    
    # Test logrotate configuration
    if logrotate -d /etc/logrotate.d/nftban &>/dev/null; then
        log_success "Log rotation configured successfully"
    else
        log_warning "Log rotation configuration may have issues (non-critical)"
    fi
    
    # Create initial log file
    touch /var/log/nftban/nftban.log
    chmod 640 /var/log/nftban/nftban.log
}

# =============================================================================
# CONFIGURATION FILES
# =============================================================================

initialize_configuration() {
    log_info "Initializing configuration files..."
    
    # Check if main config exists
    if [[ ! -f "$BASE_DIR/config/nftban.conf" ]]; then
        log_error "Base configuration not found: $BASE_DIR/config/nftban.conf"
        log_info "Please ensure nftban.conf is in the config directory"
        return 1
    fi
    
    # Create local override file if it doesn't exist
    if [[ ! -f "$BASE_DIR/config/nftban.conf.local" ]]; then
        cat > "$BASE_DIR/config/nftban.conf.local" <<'EOF'
# =============================================================================
# NFTBAN Local Configuration Override
# Put your customizations here - this file is never overwritten
# =============================================================================

# Example: Enable specific feeds
# NFTBAN_FEED_FEODO_ENABLED="true"
# NFTBAN_FEED_SPAMHAUS_DROP_ENABLED="true"

# Example: Customize email
# NFTBAN_F2B_RECIPIENT="your-email@example.com"

# Example: Enable debug mode
# NFTBAN_DEBUG_MODE="true"

# Add your custom settings below:

EOF
        chmod 640 "$BASE_DIR/config/nftban.conf.local"
        log_success "Created: nftban.conf.local"
    fi
    
    # Check if feeds config exists
    if [[ ! -f "$BASE_DIR/config/feeds/feeds.conf" ]]; then
        log_error "Feeds configuration not found: $BASE_DIR/config/feeds/feeds.conf"
        return 1
    fi
    
    # Create feeds local override
    if [[ ! -f "$BASE_DIR/config/feeds/feeds.conf.local" ]]; then
        cat > "$BASE_DIR/config/feeds/feeds.conf.local" <<'EOF'
# =============================================================================
# NFTBAN Feeds Local Configuration
# Enable/disable feeds and add custom feeds here
# =============================================================================

# Example: Enable recommended feeds
# FEED_FEODO_ENABLED="true"
# FEED_SPAMHAUS_DROP_ENABLED="true"
# FEED_BLOCKLISTDE_SSH_ENABLED="true"

# Example: Add custom feed
# FEED_CUSTOM1_ENABLED="true"
# FEED_CUSTOM1_NAME="my-custom-feed"
# FEED_CUSTOM1_URL="https://example.com/blocklist.txt"
# FEED_CUSTOM1_PRIORITY="medium"
# FEED_CUSTOM1_FORMAT="plain"

EOF
        chmod 640 "$BASE_DIR/config/feeds/feeds.conf.local"
        log_success "Created: feeds.conf.local"
    fi
    
    # Create whitelist file if doesn't exist
    if [[ ! -f "$BASE_DIR/config/nftban-fail2ban-ip-whitelist.conf.local" ]]; then
        cat > "$BASE_DIR/config/nftban-fail2ban-ip-whitelist.conf.local" <<'EOF'
# =============================================================================
# NFTBAN IP Whitelist
# Add IPs that should never be banned (one per line)
# =============================================================================

# Localhost
127.0.0.1
::1

# Add your trusted IPs below:

EOF
        chmod 640 "$BASE_DIR/config/nftban-fail2ban-ip-whitelist.conf.local"
        log_success "Created: IP whitelist"
    fi
    
    log_success "Configuration initialized"
}

# =============================================================================
# FAIL2BAN INTEGRATION
# =============================================================================

setup_fail2ban_integration() {
    log_info "Setting up Fail2ban integration..."
    
    # Check if fail2ban is installed
    if ! command -v fail2ban-client &>/dev/null; then
        log_error "Fail2ban is not installed"
        log_info "Install with: apt-get install fail2ban"
        return 1
    fi
    
    # Check if fail2ban init script exists
    if [[ -f "$SCRIPT_DIR/nftban_init_fail2ban_conf.sh" ]]; then
        log_info "Running Fail2ban configuration setup..."
        bash "$SCRIPT_DIR/nftban_init_fail2ban_conf.sh" setup
        log_success "Fail2ban integration configured"
    else
        log_warning "Fail2ban init script not found: nftban_init_fail2ban_conf.sh"
        log_info "Fail2ban integration skipped (can be set up later)"
    fi
}

# =============================================================================
# NFTABLES SETUP
# =============================================================================

setup_nftables() {
    log_info "Setting up nftables..."
    
    # Check if nftables is installed
    if ! command -v nft &>/dev/null; then
        log_error "nftables is not installed"
        log_info "Install with: apt-get install nftables"
        return 1
    fi
    
    # Check if nftables is running
    if ! systemctl is-active --quiet nftables; then
        log_info "Starting nftables service..."
        systemctl enable nftables
        systemctl start nftables
    fi
    
    # Create feed blocklist set if it doesn't exist
    if ! nft list set inet filter feed_blocklist &>/dev/null; then
        log_info "Creating nftables set for feeds..."
        nft add table inet filter 2>/dev/null || true
        nft add set inet filter feed_blocklist "{ type ipv4_addr; flags interval; auto-merge; }" 2>/dev/null || true
        log_success "Created nftables feed set"
    else
        log_info "nftables feed set already exists"
    fi
    
    log_success "nftables configured"
}

# =============================================================================
# INSTALL EXECUTABLES
# =============================================================================

install_executables() {
    log_info "Installing executables..."
    
    # Make CLI executable
    if [[ -f "$BASE_DIR/bin/nftban_cli.sh" ]]; then
        chmod +x "$BASE_DIR/bin/nftban_cli.sh"
        log_success "Made nftban_cli.sh executable"
    else
        log_error "CLI script not found: $BASE_DIR/bin/nftban_cli.sh"
        return 1
    fi
    
    # Make libraries executable
    for lib in "$BASE_DIR/lib"/*.sh; do
        if [[ -f "$lib" ]]; then
            chmod +x "$lib"
        fi
    done
    log_success "Made libraries executable"
    
    # Create symlink in /usr/local/bin
    if [[ -L /usr/local/bin/nftban ]]; then
        rm -f /usr/local/bin/nftban
    fi
    
    ln -sf "$BASE_DIR/bin/nftban_cli.sh" /usr/local/bin/nftban
    chmod +x /usr/local/bin/nftban
    log_success "Created symlink: /usr/local/bin/nftban"
}

# =============================================================================
# FEEDS INITIALIZATION
# =============================================================================

initialize_feeds() {
    log_info "Initializing threat intelligence feeds..."
    
    # Create feeds data directory
    mkdir -p "$BASE_DIR/data/feeds"
    chmod 755 "$BASE_DIR/data/feeds"
    
    log_info "Feeds system ready. Enable feeds with:"
    log_info "  nftban feed list --all"
    log_info "  nftban feed enable <feed-name>"
    log_info "  nftban feed update"
    
    log_success "Feeds initialized"
}

# =============================================================================
# POST-INSTALLATION
# =============================================================================

post_installation_steps() {
    log_info "Running post-installation steps..."
    
    # Restart fail2ban if running
    if systemctl is-active --quiet fail2ban; then
        log_info "Restarting fail2ban..."
        systemctl restart fail2ban
        log_success "Fail2ban restarted"
    fi
    
    # Create initial backup
    local backup_dir="$BASE_DIR/backups"
    local backup_file="$backup_dir/initial-install-$(date +%Y%m%d-%H%M%S).tar.gz"
    
    tar -czf "$backup_file" \
        "$BASE_DIR/config" \
        "$BASE_DIR/lib" \
        "$BASE_DIR/bin" \
        2>/dev/null || true
    
    log_success "Initial backup created: $backup_file"
}

# =============================================================================
# INSTALLATION SUMMARY
# =============================================================================

show_installation_summary() {
    cat << EOF

${COLOR_GREEN}╔═══════════════════════════════════════════════════════════════╗
║                                                               ║
║           ✓ NFTBAN INSTALLATION COMPLETED SUCCESSFULLY       ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝${COLOR_RESET}

${COLOR_BLUE}Installation Details:${COLOR_RESET}
  • Base Directory: $BASE_DIR
  • Command: /usr/local/bin/nftban
  • Config: $BASE_DIR/config/nftban.conf.local
  • Feeds: $BASE_DIR/config/feeds/feeds.conf.local
  • Logs: /var/log/nftban/nftban.log

${COLOR_BLUE}Quick Start Guide:${COLOR_RESET}

  1. Check system status:
     ${COLOR_GREEN}nftban status${COLOR_RESET}

  2. List available feeds:
     ${COLOR_GREEN}nftban feed list --all${COLOR_RESET}

  3. Enable recommended feeds:
     ${COLOR_GREEN}nftban feed enable feodo${COLOR_RESET}
     ${COLOR_GREEN}nftban feed enable spamhaus-drop${COLOR_RESET}
     ${COLOR_GREEN}nftban feed enable blocklist-de-ssh${COLOR_RESET}

  4. Update feeds:
     ${COLOR_GREEN}nftban feed update${COLOR_RESET}

  5. View statistics:
     ${COLOR_GREEN}nftban feed stats${COLOR_RESET}

  6. Monitor logs:
     ${COLOR_GREEN}nftban logs tail${COLOR_RESET}

${COLOR_BLUE}Configuration:${COLOR_RESET}
  • Edit settings: ${COLOR_GREEN}nftban config edit${COLOR_RESET}
  • Enable feeds: Edit $BASE_DIR/config/nftban.conf.local

${COLOR_BLUE}Documentation:${COLOR_RESET}
  • View all commands: ${COLOR_GREEN}nftban help${COLOR_RESET}
  • Check status: ${COLOR_GREEN}nftban status${COLOR_RESET}

${COLOR_YELLOW}⚠ Important:${COLOR_RESET}
  • Customize $BASE_DIR/config/nftban.conf.local
  • Add trusted IPs to whitelist
  • Review and enable feeds as needed

EOF
}

# =============================================================================
# MAIN INSTALLATION FLOW
# =============================================================================

main() {
    echo
    log_info "╔═══════════════════════════════════════════════╗"
    log_info "║   NFTBAN Installation & Setup                ║"
    log_info "║   Advanced Firewall & Threat Intelligence    ║"
    log_info "╚═══════════════════════════════════════════════╝"
    echo
    
    # Pre-flight checks
    check_root
    check_system_requirements || exit 1
    check_existing_installation
    
    echo
    log_info "Starting installation..."
    echo
    
    # Installation steps
    create_directory_structure
    setup_log_rotation
    initialize_configuration || exit 1
    setup_nftables
    setup_fail2ban_integration
    install_executables || exit 1
    initialize_feeds
    post_installation_steps
    
    # Show summary
    show_installation_summary
    
    log_success "Installation complete! 🚀"
    echo
}

# =============================================================================
# ENTRY POINT
# =============================================================================

# Handle arguments
case "${1:-}" in
    --help|-h)
        echo "Usage: $0"
        echo "Install NFTBAN system"
        exit 0
        ;;
    *)
        main "$@"
        ;;
esac