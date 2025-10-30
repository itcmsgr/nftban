#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.10.0 - Stats & Report Deployment Script
# =============================================================================
# Purpose: Deploy stats system to all lab servers and configure daily reports
# Target Servers:
#   - lab.example.test
#   - lab1.example.test
#   - lab2.example.test
# =============================================================================

set -Eeuo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SERVERS=("lab.example.test" "lab1.example.test" "lab2.example.test")
EMAIL="contact@nftban.com"
REPORT_TIME="23:59"
SOURCE_DIR="/home/gituser/nftban-v0.10.0-dev/src"

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# =============================================================================
# DEPLOYMENT FUNCTIONS
# =============================================================================

deploy_to_server() {
    local server="$1"

    log_info "================================================"
    log_info "Deploying to: ${server}"
    log_info "================================================"

    # Test connection
    if ! ssh root@"${server}" "echo 'Connection OK'" &>/dev/null; then
        log_error "Cannot connect to ${server}"
        return 1
    fi

    log_success "Connected to ${server}"

    # 1. Deploy configuration file
    log_info "Deploying stats.conf..."
    scp "${SOURCE_DIR}/etc/nftban/conf.d/stats.conf" \
        root@"${server}":/etc/nftban/conf.d/stats.conf

    # 2. Deploy core stats module
    log_info "Deploying nftban_stats.sh..."
    scp "${SOURCE_DIR}/usr/lib/nftban/core/nftban_stats.sh" \
        root@"${server}":/usr/lib/nftban/core/nftban_stats.sh
    ssh root@"${server}" "chmod 644 /usr/lib/nftban/core/nftban_stats.sh"

    # 3. Deploy CLI commands
    log_info "Deploying CLI commands..."
    scp "${SOURCE_DIR}/usr/lib/nftban/cli/cmd_stats.sh" \
        root@"${server}":/usr/lib/nftban/cli/cmd_stats.sh
    scp "${SOURCE_DIR}/usr/lib/nftban/cli/cmd_report.sh" \
        root@"${server}":/usr/lib/nftban/cli/cmd_report.sh
    ssh root@"${server}" "chmod 644 /usr/lib/nftban/cli/cmd_{stats,report}.sh"

    # 4. Deploy HTML templates
    log_info "Deploying HTML templates..."
    ssh root@"${server}" "mkdir -p /usr/share/nftban/templates/reports"
    ssh root@"${server}" "mkdir -p /usr/share/nftban/templates/mail"

    scp "${SOURCE_DIR}/usr/share/nftban/templates/reports/stats_dashboard.html" \
        root@"${server}":/usr/share/nftban/templates/reports/stats_dashboard.html

    scp "${SOURCE_DIR}/usr/share/nftban/templates/mail/stats_email.html" \
        root@"${server}":/usr/share/nftban/templates/mail/stats_email.html

    ssh root@"${server}" "chmod 644 /usr/share/nftban/templates/reports/stats_dashboard.html"
    ssh root@"${server}" "chmod 644 /usr/share/nftban/templates/mail/stats_email.html"

    # 5. Deploy updated main CLI
    log_info "Deploying updated nftban CLI..."
    scp "${SOURCE_DIR}/usr/sbin/nftban" \
        root@"${server}":/usr/sbin/nftban
    ssh root@"${server}" "chmod 755 /usr/sbin/nftban"

    # 6. Deploy updated FHS module
    log_info "Deploying updated FHS module..."
    scp "${SOURCE_DIR}/usr/lib/nftban/core/nftban_report_fhs.sh" \
        root@"${server}":/usr/lib/nftban/core/nftban_report_fhs.sh
    ssh root@"${server}" "chmod 644 /usr/lib/nftban/core/nftban_report_fhs.sh"

    # 7. Create required directories
    log_info "Creating required directories..."
    ssh root@"${server}" << 'EOSSH'
        mkdir -p /var/lib/nftban/metrics /var/lib/nftban/metrics/cache
        mkdir -p /var/lib/nftban/snapshots
        mkdir -p /var/lib/nftban/reports/{daily,weekly,monthly}
        mkdir -p /var/cache/nftban/stats
        touch /var/log/nftban/stats.log

        # Set permissions
        chown -R nftban:nftban /var/lib/nftban/metrics
        chown -R nftban:nftban /var/lib/nftban/snapshots
        chown -R nftban:nftban /var/lib/nftban/reports
        chown -R nftban:nftban /var/cache/nftban/stats
        chown nftban:nftban /var/log/nftban/stats.log

        chmod 750 /var/lib/nftban/metrics
        chmod 750 /var/lib/nftban/snapshots
        chmod 750 /var/lib/nftban/reports
        chmod 755 /var/cache/nftban/stats
        chmod 640 /var/log/nftban/stats.log
EOSSH

    log_success "Directories created and permissions set"

    # 8. Configure daily report email
    log_info "Configuring daily report to ${EMAIL} at ${REPORT_TIME}..."
    ssh root@"${server}" << EOSSH
        # Update stats.conf with email
        sed -i 's/^STATS_EMAIL_RECIPIENTS=.*/STATS_EMAIL_RECIPIENTS="${EMAIL}"/' /etc/nftban/conf.d/stats.conf
        sed -i 's/^STATS_DAILY_REPORT_TIME=.*/STATS_DAILY_REPORT_TIME="${REPORT_TIME}"/' /etc/nftban/conf.d/stats.conf
        sed -i 's/^STATS_EMAIL_ENABLED=.*/STATS_EMAIL_ENABLED="true"/' /etc/nftban/conf.d/stats.conf
        sed -i 's/^STATS_DAILY_REPORT_ENABLED=.*/STATS_DAILY_REPORT_ENABLED="true"/' /etc/nftban/conf.d/stats.conf

        # Create cron job
        cat > /etc/cron.d/nftban-stats << 'EOCRON'
# NFTBan Statistics Reports - Automated Scheduling
# Generated: $(date)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Daily report at 23:59 to contact@nftban.com
59 23 * * * root /usr/sbin/nftban report run daily >> /var/log/nftban/cron.log 2>&1

# Hourly snapshot
0 * * * * root /usr/sbin/nftban stats snapshot >> /var/log/nftban/cron.log 2>&1

# Daily cleanup (03:00 AM)
0 3 * * * root /usr/sbin/nftban stats cleanup >> /var/log/nftban/cron.log 2>&1
EOCRON

        chmod 644 /etc/cron.d/nftban-stats

        # Create cron log
        touch /var/log/nftban/cron.log
        chown nftban:nftban /var/log/nftban/cron.log
        chmod 640 /var/log/nftban/cron.log
EOSSH

    log_success "Daily report configured: ${EMAIL} at ${REPORT_TIME}"

    # 9. Verify installation
    log_info "Verifying installation..."
    ssh root@"${server}" << 'EOSSH'
        echo "Testing nftban stats command..."
        if /usr/sbin/nftban stats help &>/dev/null; then
            echo "✓ nftban stats - OK"
        else
            echo "✗ nftban stats - FAILED"
        fi

        if /usr/sbin/nftban report help &>/dev/null; then
            echo "✓ nftban report - OK"
        else
            echo "✗ nftban report - FAILED"
        fi

        echo ""
        echo "Checking files..."
        ls -lh /etc/nftban/conf.d/stats.conf
        ls -lh /usr/lib/nftban/core/nftban_stats.sh
        ls -lh /usr/lib/nftban/cli/cmd_{stats,report}.sh
        ls -lh /usr/share/nftban/templates/reports/stats_dashboard.html
        ls -lh /usr/share/nftban/templates/mail/stats_email.html

        echo ""
        echo "Checking directories..."
        ls -ld /var/lib/nftban/metrics
        ls -ld /var/lib/nftban/snapshots
        ls -ld /var/lib/nftban/reports

        echo ""
        echo "Checking cron..."
        cat /etc/cron.d/nftban-stats
EOSSH

    log_success "Deployment to ${server} COMPLETE!"
    echo ""
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    log_info "NFTBan Stats & Report Deployment"
    log_info "================================="
    echo ""
    log_info "Source: ${SOURCE_DIR}"
    log_info "Target servers: ${SERVERS[*]}"
    log_info "Email: ${EMAIL}"
    log_info "Report time: ${REPORT_TIME}"
    echo ""

    # Confirm
    read -p "Deploy to all servers? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        log_warning "Deployment cancelled"
        exit 0
    fi

    echo ""

    # Deploy to each server
    for server in "${SERVERS[@]}"; do
        if deploy_to_server "$server"; then
            log_success "✓ ${server} - SUCCESS"
        else
            log_error "✗ ${server} - FAILED"
        fi
        echo ""
    done

    log_success "================================================"
    log_success "ALL DEPLOYMENTS COMPLETE!"
    log_success "================================================"
    echo ""
    log_info "Next steps:"
    echo "  1. Test on each server: ssh root@SERVER 'nftban stats'"
    echo "  2. Generate test report: ssh root@SERVER 'nftban report run daily'"
    echo "  3. Monitor cron log: ssh root@SERVER 'tail -f /var/log/nftban/cron.log'"
    echo "  4. Check ${EMAIL} for daily reports at ${REPORT_TIME}"
    echo ""
    log_success "Daily reports will be sent automatically to ${EMAIL} at ${REPORT_TIME}"
}

# Run main
main "$@"
