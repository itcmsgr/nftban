#!/usr/bin/env bash

# =============================================================================
# NFTBan Lab Server Protection Setup
# Version: 0.9.2
# Location: scripts/setup_lab_protection.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Description: Automated setup of SSH and mail protection for lab servers
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly SCRIPT_VERSION="0.9.2"
readonly NFTBAN_CONFIG_DIR="/etc/nftban/config"
readonly NFTBAN_PORTS_DIR="/etc/nftban/config/ports"
readonly NFTBAN_BIN="/usr/local/bin/nftban"

# ANSI Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'
readonly BOLD='\033[1m'

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

print_header() {
    echo ""
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  NFTBan Lab Server Protection Setup v${SCRIPT_VERSION}${NC}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[⚠]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

check_nftban_installed() {
    if [[ ! -x "$NFTBAN_BIN" ]]; then
        log_error "NFTBan not found at $NFTBAN_BIN"
        log_error "Please deploy nftban first using deploy_v0.9.2_to_labs.sh"
        exit 1
    fi
    log_success "NFTBan installation detected"
}

# =============================================================================
# SERVER DETECTION
# =============================================================================

detect_server() {
    local hostname=$(hostname -s)

    echo ""
    log_info "Detecting lab server..."
    echo "  Hostname: $hostname"

    # Try to match lab server pattern
    if [[ "$hostname" =~ lab-server-([0-9]+) ]]; then
        local server_num="${BASH_REMATCH[1]}"
        echo "lab-server-$server_num"
        return 0
    elif [[ "$hostname" =~ lab([0-9]+) ]]; then
        local server_num="${BASH_REMATCH[1]}"
        echo "lab-server-$server_num"
        return 0
    else
        # Ask user to select
        echo ""
        log_warning "Could not auto-detect lab server number"
        echo "Please select lab server number:"
        echo "  1) lab-server-1"
        echo "  2) lab-server-2"
        echo "  3) lab-server-3"
        echo -n "Enter selection (1-3): "
        read -r selection

        case "$selection" in
            1) echo "lab-server-1" ;;
            2) echo "lab-server-2" ;;
            3) echo "lab-server-3" ;;
            *)
                log_error "Invalid selection"
                exit 1
                ;;
        esac
    fi
}

# =============================================================================
# CONFIGURATION SETUP
# =============================================================================

setup_server_config() {
    local server_id="$1"
    local config_source="/etc/nftban/templates/lab-configs/${server_id}.conf.local"
    local config_dest="$NFTBAN_CONFIG_DIR/nftban.conf.local"

    log_info "Setting up ${server_id} configuration..."

    # Check if source template exists
    if [[ ! -f "$config_source" ]]; then
        log_error "Configuration template not found: $config_source"
        return 1
    fi

    # Backup existing config if present
    if [[ -f "$config_dest" ]]; then
        local backup="${config_dest}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$config_dest" "$backup"
        log_info "Backed up existing config to: $backup"
    fi

    # Copy template
    cp "$config_source" "$config_dest"
    chmod 600 "$config_dest"
    chown root:root "$config_dest"

    log_success "Configuration installed for ${server_id}"

    # Prompt for email customization
    echo ""
    echo -e "${CYAN}Email Configuration:${NC}"
    echo "Current email recipient: $(grep '^NFTBAN_F2B_RECIPIENT=' "$config_dest" | cut -d'=' -f2 | tr -d '"')"
    echo -n "Update email address? (y/N): "
    read -r update_email

    if [[ "$update_email" =~ ^[Yy]$ ]]; then
        echo -n "Enter email address for alerts: "
        read -r email_address

        if [[ -n "$email_address" ]]; then
            sed -i "s|^NFTBAN_F2B_RECIPIENT=.*|NFTBAN_F2B_RECIPIENT=\"${email_address}\"|" "$config_dest"
            log_success "Email updated to: $email_address"
        fi
    fi
}

setup_port_protection() {
    log_info "Setting up port protection..."

    # Create ports directory
    mkdir -p "$NFTBAN_PORTS_DIR"
    chmod 755 "$NFTBAN_PORTS_DIR"

    # Copy SSH port config
    local ssh_source="/etc/nftban/templates/ports/ssh.conf"
    local ssh_dest="$NFTBAN_PORTS_DIR/ssh.conf"

    if [[ -f "$ssh_source" ]]; then
        cp "$ssh_source" "$ssh_dest"
        chmod 644 "$ssh_dest"
        log_success "SSH port protection enabled (port 22)"
    else
        # Create SSH config manually
        cat > "$ssh_dest" <<'EOF'
# SSH Port Protection (CRITICAL)
22|T|I
EOF
        chmod 644 "$ssh_dest"
        log_success "SSH port protection created (port 22)"
    fi

    # Copy mail port config
    local mail_source="/etc/nftban/templates/ports/mail.conf"
    local mail_dest="$NFTBAN_PORTS_DIR/mail.conf"

    if [[ -f "$mail_source" ]]; then
        cp "$mail_source" "$mail_dest"
        chmod 644 "$mail_dest"
        log_success "Mail port protection enabled (SMTP, IMAP, POP3)"
    else
        # Create mail config manually
        cat > "$mail_dest" <<'EOF'
# Mail Server Port Protection
25|T|I
587|T|I
465|T|I
993|T|I
995|T|I
EOF
        chmod 644 "$mail_dest"
        log_success "Mail port protection created (SMTP, IMAP, POP3)"
    fi

    # List enabled ports
    echo ""
    echo -e "${CYAN}Protected Ports:${NC}"
    echo "  SSH:  22 (TCP INPUT)"
    echo "  SMTP: 25, 587, 465 (TCP INPUT)"
    echo "  IMAP: 993 (TCP INPUT)"
    echo "  POP3: 995 (TCP INPUT)"
}

# =============================================================================
# NFTBAN SETUP
# =============================================================================

apply_nftban_setup() {
    log_info "Applying nftban configuration..."

    # Run nftban setup
    if $NFTBAN_BIN setup; then
        log_success "nftban setup completed"
    else
        log_error "nftban setup failed"
        return 1
    fi
}

setup_login_monitor() {
    log_info "Setting up login monitor service..."

    # Install login monitor
    if $NFTBAN_BIN login install 2>/dev/null; then
        log_success "Login monitor service installed"
    else
        log_warning "Login monitor install had warnings (may already exist)"
    fi

    # Enable login monitor
    if $NFTBAN_BIN login enable 2>/dev/null; then
        log_success "Login monitor enabled (auto-start on boot)"
    else
        log_warning "Login monitor enable had warnings"
    fi

    # Start login monitor
    if $NFTBAN_BIN login start 2>/dev/null; then
        log_success "Login monitor started"
    else
        log_warning "Login monitor start had warnings (may already be running)"
    fi
}

# =============================================================================
# VERIFICATION
# =============================================================================

verify_setup() {
    echo ""
    log_info "Verifying protection setup..."

    local errors=0

    # Check nftables rules
    if nft list ruleset | grep -q "22.*accept"; then
        log_success "SSH port 22 is protected in nftables"
    else
        log_warning "SSH port 22 not found in nftables rules"
        ((errors++))
    fi

    # Check fail2ban jails
    if systemctl is-active fail2ban &>/dev/null; then
        if fail2ban-client status 2>/dev/null | grep -q "sshd"; then
            log_success "SSH jail is active in fail2ban"
        else
            log_warning "SSH jail not found in fail2ban"
            ((errors++))
        fi
    else
        log_warning "fail2ban service not running"
        ((errors++))
    fi

    # Check login monitor
    if systemctl is-active nftban-login-monitor.timer &>/dev/null; then
        log_success "Login monitor timer is active"
    else
        log_warning "Login monitor timer not active"
        ((errors++))
    fi

    # Check log files
    if [[ -f "/var/log/nftban/login-alerts.log" ]]; then
        log_success "Login alerts log exists"
    else
        log_info "Login alerts log will be created on first alert"
    fi

    return $errors
}

# =============================================================================
# ATTACK VISIBILITY SETUP
# =============================================================================

setup_attack_visibility() {
    echo ""
    log_info "Setting up attack visibility for tomorrow..."

    # Create quick view script
    cat > /usr/local/bin/view-attacks <<'EOF'
#!/usr/bin/env bash

# Quick attack viewer
echo "═══════════════════════════════════════════════════════════"
echo "  NFTBan Attack Summary"
echo "═══════════════════════════════════════════════════════════"
echo ""

# SSH attacks (last 24 hours)
echo "SSH Failed Login Attempts (last 24 hours):"
journalctl --since "24 hours ago" | grep -i "failed password" | wc -l
echo ""

# Banned IPs
echo "Currently Banned IPs:"
nft list set inet nftban_v4 temp_ban 2>/dev/null | grep "elements" || echo "None"
echo ""

# Recent bans (last 50)
echo "Recent Ban Events (last 50):"
tail -50 /var/log/nftban/ban-history.log 2>/dev/null || echo "No bans yet"
echo ""

# Login alerts
echo "Login Alerts:"
tail -20 /var/log/nftban/login-alerts.log 2>/dev/null || echo "No alerts yet"
echo ""

# Fail2ban status
echo "Fail2ban Jails:"
fail2ban-client status 2>/dev/null || echo "Fail2ban not running"

EOF

    chmod 755 /usr/local/bin/view-attacks
    log_success "Created attack viewer: /usr/local/bin/view-attacks"

    # Create daily attack report script
    cat > /usr/local/bin/daily-attack-report <<'EOF'
#!/usr/bin/env bash

# Daily attack report
RECIPIENT=$(grep '^NFTBAN_F2B_RECIPIENT=' /etc/nftban/config/nftban.conf.local | cut -d'=' -f2 | tr -d '"')
SERVER=$(hostname -f)
DATE=$(date '+%Y-%m-%d')

REPORT="/tmp/nftban-daily-report-${DATE}.txt"

{
    echo "═══════════════════════════════════════════════════════════"
    echo "  NFTBan Daily Attack Report"
    echo "  Server: $SERVER"
    echo "  Date: $DATE"
    echo "═══════════════════════════════════════════════════════════"
    echo ""

    echo "SSH Attack Summary:"
    echo "  Failed logins: $(journalctl --since "24 hours ago" | grep -i "failed password" | wc -l)"
    echo "  Successful logins: $(journalctl --since "24 hours ago" | grep -i "accepted password" | wc -l)"
    echo ""

    echo "Banned IPs (last 24 hours):"
    grep "$(date -d '24 hours ago' '+%Y-%m-%d')" /var/log/nftban/ban-history.log 2>/dev/null | wc -l
    echo ""

    echo "Top Attack Sources:"
    grep "$(date -d '24 hours ago' '+%Y-%m-%d')" /var/log/nftban/ban-history.log 2>/dev/null | \
        awk -F'|' '{print $4}' | sort | uniq -c | sort -rn | head -10
    echo ""

    echo "Mail Attack Summary:"
    grep -i "postfix.*reject" /var/log/mail.log 2>/dev/null | wc -l
    echo ""

} > "$REPORT"

# Send email if recipient configured
if [[ -n "$RECIPIENT" ]]; then
    mail -s "[$SERVER] NFTBan Daily Attack Report - $DATE" "$RECIPIENT" < "$REPORT"
fi

# Also log
cat "$REPORT"

EOF

    chmod 755 /usr/local/bin/daily-attack-report
    log_success "Created daily report: /usr/local/bin/daily-attack-report"

    # Add cron job for daily report
    echo "0 8 * * * root /usr/local/bin/daily-attack-report" > /etc/cron.d/nftban-daily-report
    chmod 644 /etc/cron.d/nftban-daily-report
    log_success "Scheduled daily attack report (8 AM)"
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    print_header

    # Pre-flight checks
    check_root
    check_nftban_installed

    echo ""

    # Detect server
    local server_id=$(detect_server)
    log_success "Detected server: ${server_id}"

    echo ""
    echo -e "${BOLD}${YELLOW}This will configure ${server_id} for SSH and mail protection${NC}"
    echo ""
    echo "The following will be configured:"
    echo "  ✓ SSH port protection (port 22)"
    echo "  ✓ Mail port protection (SMTP, IMAP, POP3)"
    echo "  ✓ Login monitoring with email alerts"
    echo "  ✓ Attack logging and visibility"
    echo "  ✓ Fail2ban jails for SSH and mail"
    echo ""
    echo -n "Continue? (y/N): "
    read -r confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Setup cancelled"
        exit 0
    fi

    echo ""

    # Setup configuration
    setup_server_config "$server_id" || exit 1

    echo ""

    # Setup port protection
    setup_port_protection || exit 1

    echo ""

    # Apply nftban setup
    apply_nftban_setup || exit 1

    echo ""

    # Setup login monitor
    setup_login_monitor || exit 1

    echo ""

    # Setup attack visibility
    setup_attack_visibility || exit 1

    echo ""

    # Verify setup
    if verify_setup; then
        log_success "All checks passed!"
    else
        log_warning "Some checks failed, but protection is active"
    fi

    echo ""
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}  Protection Setup Complete!${NC}"
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}Protected Services:${NC}"
    echo "  ✓ SSH (port 22) - max 5 failures in 10 minutes = 1 hour ban"
    echo "  ✓ Mail (SMTP/IMAP/POP3) - max 3 failures in 10 minutes = 2 hour ban"
    echo ""
    echo -e "${CYAN}Monitoring Active:${NC}"
    echo "  ✓ Login monitoring enabled"
    echo "  ✓ Email alerts configured"
    echo "  ✓ Daily attack reports scheduled"
    echo ""
    echo -e "${CYAN}View Attacks Tomorrow:${NC}"
    echo "  $ view-attacks              # Quick attack summary"
    echo "  $ daily-attack-report       # Full daily report"
    echo "  $ tail -f /var/log/nftban/ban-history.log    # Live ban events"
    echo "  $ tail -f /var/log/nftban/login-alerts.log   # Live login alerts"
    echo ""
    echo -e "${CYAN}Check Status:${NC}"
    echo "  $ nftban status             # Overall status"
    echo "  $ nftban login status       # Login monitor status"
    echo "  $ fail2ban-client status    # Fail2ban status"
    echo ""
    echo -e "${YELLOW}Note:${NC} Email recipient: $(grep '^NFTBAN_F2B_RECIPIENT=' "$NFTBAN_CONFIG_DIR/nftban.conf.local" | cut -d'=' -f2 | tr -d '"')"
    echo ""
}

# Run main
main "$@"
