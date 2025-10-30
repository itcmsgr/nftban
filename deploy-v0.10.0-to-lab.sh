#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.10.0 - Safe Lab Deployment Script
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Safely deploy v0.10.0 to lab servers with proper service stops
#
# meta:name=deploy_v0_10_0_to_lab
# meta:type=tool
# meta:header=Safe Lab Deployment
# meta:version=1.0.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Safely deploy v0.10.0 to lab servers with service stops and FHS structure
# meta:input=No arguments required
# meta:output=Deployment status and validation results
#
# **Inventory & Requirements**
# meta:depends=ssh,rsync
#
# meta:created_date=2025-10-26

set -Eeuo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

LAB_SERVERS=(
    "lab.example.test"
    "lab1.example.test"
    "lab2.example.test"
)

LAB_USER="root"
LOCAL_SRC_DIR="/home/gituser/nftban-v0.10.0-dev/src"

# Colors
COLOR_GREEN='\033[32m'
COLOR_YELLOW='\033[33m'
COLOR_RED='\033[31m'
COLOR_CYAN='\033[36m'
COLOR_BOLD='\033[1m'
COLOR_RESET='\033[0m'

# =============================================================================
# FUNCTIONS
# =============================================================================

log_info() {
    echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET} $*"
}

log_success() {
    echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $*"
}

log_warning() {
    echo -e "${COLOR_YELLOW}[WARNING]${COLOR_RESET} $*"
}

log_error() {
    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*"
}

log_step() {
    echo ""
    echo -e "${COLOR_BOLD}${COLOR_CYAN}=== $* ===${COLOR_RESET}"
    echo ""
}

# =============================================================================
# DEPLOYMENT TO EACH SERVER
# =============================================================================

deploy_to_server() {
    local server="$1"

    echo "============================================================================="
    echo -e "${COLOR_BOLD}Server: $server${COLOR_RESET}"
    echo "============================================================================="

    # Check connectivity
    if ! ssh -o ConnectTimeout=5 "${LAB_USER}@${server}" "echo 'Connected'" &>/dev/null; then
        log_error "Cannot connect to $server - SKIPPING"
        echo ""
        return 1
    fi
    log_success "Connected to $server"
    echo ""

    # ==========================================================================
    # STEP 1: STOP SERVICES (CRITICAL - DO THIS FIRST!)
    # ==========================================================================

    log_step "STEP 1: Stopping Services"

    log_info "Stopping fail2ban..."
    if ssh "${LAB_USER}@${server}" "systemctl is-active fail2ban >/dev/null 2>&1"; then
        ssh "${LAB_USER}@${server}" "systemctl stop fail2ban"
        log_success "fail2ban stopped"
    else
        log_info "fail2ban not running"
    fi

    log_info "Flushing nftables..."
    ssh "${LAB_USER}@${server}" "nft flush ruleset 2>/dev/null || true"
    log_success "nftables flushed"

    log_info "Stopping any old nftban processes..."
    ssh "${LAB_USER}@${server}" "pkill -f nftban || true"
    log_success "Old processes killed"

    echo ""

    # ==========================================================================
    # STEP 2: BACKUP EXISTING CONFIGS (if any)
    # ==========================================================================

    log_step "STEP 2: Backing Up Existing Configs"

    if ssh "${LAB_USER}@${server}" "test -d /etc/nftban"; then
        log_info "Backing up /etc/nftban to /root/nftban-backup-$(date +%Y%m%d-%H%M%S)"
        ssh "${LAB_USER}@${server}" "cp -a /etc/nftban /root/nftban-backup-\$(date +%Y%m%d-%H%M%S) 2>/dev/null || true"
        log_success "Config backed up"
    else
        log_info "No existing /etc/nftban - fresh install"
    fi

    echo ""

    # ==========================================================================
    # STEP 3: CLEAN UP OLD FILES
    # ==========================================================================

    log_step "STEP 3: Cleaning Up Old Files"

    log_info "Removing old /opt/nftban (if exists)..."
    ssh "${LAB_USER}@${server}" "rm -rf /opt/nftban 2>/dev/null || true"

    log_info "Removing test directory..."
    ssh "${LAB_USER}@${server}" "rm -rf /tmp/nftban-v0.10.0-test 2>/dev/null || true"

    log_info "Removing old cron jobs..."
    ssh "${LAB_USER}@${server}" "rm -f /etc/cron.d/nftban 2>/dev/null || true"

    log_info "Removing old systemd units (if any)..."
    ssh "${LAB_USER}@${server}" "rm -f /etc/systemd/system/nftban* 2>/dev/null || true"
    ssh "${LAB_USER}@${server}" "systemctl daemon-reload 2>/dev/null || true"

    log_info "Removing non-FHS directories from /etc/nftban (old v0.9.x cruft)..."
    ssh "${LAB_USER}@${server}" "cd /etc/nftban 2>/dev/null && rm -rf bin cache .ci .claude completions config docs .github lib data archive backups logs scripts templates 2>/dev/null || true"
    log_info "Removed: bin, cache, docs, lib, data, logs, scripts, templates, etc."

    log_success "Old files cleaned"

    echo ""

    # ==========================================================================
    # STEP 4: CREATE SYSTEM USER
    # ==========================================================================

    log_step "STEP 4: Creating System User"

    log_info "Creating nftban system user..."
    if ! ssh "${LAB_USER}@${server}" "id -u nftban >/dev/null 2>&1"; then
        ssh "${LAB_USER}@${server}" "useradd -r -s /usr/sbin/nologin -d /nonexistent -c 'NFTBan System User' nftban"
        log_success "System user 'nftban' created"
    else
        log_info "System user 'nftban' already exists"
    fi

    log_info "Creating nftban-cli group..."
    if ! ssh "${LAB_USER}@${server}" "getent group nftban-cli >/dev/null 2>&1"; then
        ssh "${LAB_USER}@${server}" "groupadd nftban-cli"
        log_success "Group 'nftban-cli' created"
    else
        log_info "Group 'nftban-cli' already exists"
    fi

    echo ""

    # ==========================================================================
    # STEP 5: CREATE FHS DIRECTORY STRUCTURE
    # ==========================================================================

    log_step "STEP 5: Creating FHS Directory Structure"

    log_info "Creating /usr directories..."
    ssh "${LAB_USER}@${server}" "install -d -o root -g root -m 0755 /usr/lib/nftban/{cli,core,modules,tools,exporters,cron}"
    ssh "${LAB_USER}@${server}" "install -d -o root -g root -m 0755 /usr/share/nftban/{completions,docs,examples,templates,assets}"

    log_info "Creating /etc directories..."
    ssh "${LAB_USER}@${server}" "install -d -o root -g root -m 0750 /etc/nftban/{conf.d,feeds.d,rules.d}"
    ssh "${LAB_USER}@${server}" "install -d -o root -g root -m 0700 /etc/nftban/secrets.d"

    log_info "Creating /var directories..."
    ssh "${LAB_USER}@${server}" "install -d -o nftban -g nftban -m 0750 /var/lib/nftban/{state,snapshots,feeds,keyring,backup,reports,metrics}"
    ssh "${LAB_USER}@${server}" "install -d -o nftban -g nftban -m 0750 /var/cache/nftban/{geoip,tmp}"
    ssh "${LAB_USER}@${server}" "install -d -o nftban -g adm -m 0750 /var/log/nftban"

    log_info "Creating /run directory..."
    ssh "${LAB_USER}@${server}" "install -d -o nftban -g nftban -m 0755 /run/nftban"

    log_success "FHS directories created"

    echo ""

    # ==========================================================================
    # STEP 6: DEPLOY FILES
    # ==========================================================================

    log_step "STEP 6: Deploying NFTBan v0.10.0 Files"

    log_info "Deploying core module (nftban_output.sh)..."
    scp -q "${LOCAL_SRC_DIR}/usr/lib/nftban/core/nftban_output.sh" \
        "${LAB_USER}@${server}:/usr/lib/nftban/core/"
    ssh "${LAB_USER}@${server}" "chmod 0644 /usr/lib/nftban/core/nftban_output.sh"
    ssh "${LAB_USER}@${server}" "chown root:root /usr/lib/nftban/core/nftban_output.sh"

    log_info "Deploying configuration (banner.conf)..."
    scp -q "${LOCAL_SRC_DIR}/etc/nftban/conf.d/banner.conf" \
        "${LAB_USER}@${server}:/etc/nftban/conf.d/"
    ssh "${LAB_USER}@${server}" "chmod 0640 /etc/nftban/conf.d/banner.conf"
    ssh "${LAB_USER}@${server}" "chown root:nftban-cli /etc/nftban/conf.d/banner.conf"

    log_info "Deploying main config (nftban.conf)..."
    if ssh "${LAB_USER}@${server}" "test -f /etc/nftban/nftban.conf"; then
        log_warning "Existing nftban.conf preserved (already backed up)"
    else
        scp -q "${LOCAL_SRC_DIR}/etc/nftban/nftban.conf" \
            "${LAB_USER}@${server}:/etc/nftban/"
        ssh "${LAB_USER}@${server}" "chmod 0640 /etc/nftban/nftban.conf"
        ssh "${LAB_USER}@${server}" "chown root:nftban-cli /etc/nftban/nftban.conf"
        log_success "Main config deployed"
    fi

    log_info "Deploying config example (nftban.conf.local.example)..."
    scp -q "${LOCAL_SRC_DIR}/etc/nftban/nftban.conf.local.example" \
        "${LAB_USER}@${server}:/etc/nftban/"
    ssh "${LAB_USER}@${server}" "chmod 0644 /etc/nftban/nftban.conf.local.example"

    log_info "Deploying CLI stub (nftban)..."
    scp -q "${LOCAL_SRC_DIR}/usr/sbin/nftban" \
        "${LAB_USER}@${server}:/usr/sbin/"
    ssh "${LAB_USER}@${server}" "chmod 0755 /usr/sbin/nftban"
    ssh "${LAB_USER}@${server}" "chown root:root /usr/sbin/nftban"

    log_success "Files deployed"

    echo ""

    # ==========================================================================
    # STEP 6.5: FIX OWNERSHIP & PERMISSIONS (CRITICAL)
    # ==========================================================================

    log_step "STEP 6.5: Fixing Ownership & Permissions"

    log_info "Fixing /etc/nftban permissions (FHS compliance)..."
    ssh "${LAB_USER}@${server}" "chown -R root:nftban-cli /etc/nftban"
    ssh "${LAB_USER}@${server}" "chmod 0750 /etc/nftban"
    ssh "${LAB_USER}@${server}" "chmod 0640 /etc/nftban/nftban.conf"
    ssh "${LAB_USER}@${server}" "chmod 0750 /etc/nftban/conf.d"
    ssh "${LAB_USER}@${server}" "chmod 0640 /etc/nftban/conf.d/*.conf 2>/dev/null || true"
    ssh "${LAB_USER}@${server}" "chmod 0750 /etc/nftban/{feeds.d,rules.d}"
    ssh "${LAB_USER}@${server}" "chmod 0700 /etc/nftban/secrets.d"
    log_success "/etc/nftban permissions: 0750 root:nftban-cli (configs 0640)"

    log_info "Fixing /var directories ownership..."
    ssh "${LAB_USER}@${server}" "chown -R nftban:nftban /var/lib/nftban /var/cache/nftban"
    ssh "${LAB_USER}@${server}" "chown -R nftban:adm /var/log/nftban"
    log_success "/var directories: nftban:nftban (logs: nftban:adm)"

    echo ""

    # ==========================================================================
    # STEP 7: VALIDATION
    # ==========================================================================

    log_step "STEP 7: Validation"

    log_info "Running shellcheck on nftban_output.sh..."
    if ssh "${LAB_USER}@${server}" "command -v shellcheck >/dev/null 2>&1"; then
        if ssh "${LAB_USER}@${server}" "shellcheck /usr/lib/nftban/core/nftban_output.sh"; then
            log_success "ShellCheck PASSED"
        else
            log_warning "ShellCheck found issues"
        fi
    else
        log_warning "ShellCheck not available"
    fi

    log_info "Checking file permissions..."
    ssh "${LAB_USER}@${server}" "ls -l /usr/lib/nftban/core/nftban_output.sh" | grep -q "^-rw-r--r--" && \
        log_success "Core module permissions correct (644)" || \
        log_error "Core module permissions WRONG"

    log_info "Checking directory ownership..."
    ssh "${LAB_USER}@${server}" "ls -ld /var/lib/nftban" | grep -q "nftban nftban" && \
        log_success "State directory ownership correct (nftban:nftban)" || \
        log_error "State directory ownership WRONG"

    log_info "Verifying system user..."
    if ssh "${LAB_USER}@${server}" "id nftban >/dev/null 2>&1"; then
        ssh "${LAB_USER}@${server}" "id nftban"
        log_success "System user verified"
    else
        log_error "System user NOT found"
    fi

    echo ""

    # ==========================================================================
    # STEP 8: FUNCTIONAL TEST
    # ==========================================================================

    log_step "STEP 8: Functional Test"

    log_info "Testing module load..."
    if ssh "${LAB_USER}@${server}" "bash -c 'source /usr/lib/nftban/core/nftban_output.sh && nftban_render_banner simple'"; then
        log_success "Module loads and works!"
    else
        log_error "Module failed to load"
    fi

    echo ""

    log_success "Deployment to $server COMPLETE!"
    echo ""

    return 0
}

# =============================================================================
# MAIN
# =============================================================================

echo ""
echo "============================================================================="
echo -e "${COLOR_BOLD}NFTBan v0.10.0 - Safe Lab Deployment${COLOR_RESET}"
echo "============================================================================="
echo ""
echo -e "${COLOR_YELLOW}${COLOR_BOLD}WARNING: This will:${COLOR_RESET}"
echo "  1. STOP fail2ban"
echo "  2. FLUSH nftables"
echo "  3. REMOVE old scripts"
echo "  4. DEPLOY v0.10.0 to FHS locations"
echo "  5. CREATE system user 'nftban'"
echo ""
echo "Servers to deploy:"
for server in "${LAB_SERVERS[@]}"; do
    echo "  - $server"
done
echo ""
read -p "Continue? (yes/no): " -r confirm

if [[ "$confirm" != "yes" ]]; then
    echo "Deployment cancelled."
    exit 0
fi

echo ""
log_info "Starting deployment to ${#LAB_SERVERS[@]} lab servers..."
echo ""

# Deploy to each server
success_count=0
fail_count=0

for server in "${LAB_SERVERS[@]}"; do
    if deploy_to_server "$server"; then
        ((success_count++))
    else
        ((fail_count++))
    fi
done

# =============================================================================
# SUMMARY
# =============================================================================

echo "============================================================================="
echo -e "${COLOR_BOLD}Deployment Summary${COLOR_RESET}"
echo "============================================================================="
echo ""
echo "Servers deployed: ${success_count}/${#LAB_SERVERS[@]}"
echo "Failures: ${fail_count}"
echo ""

if [[ $success_count -eq ${#LAB_SERVERS[@]} ]]; then
    log_success "ALL servers deployed successfully!"
    echo ""
    echo "Next steps:"
    echo "  1. Test banner: ssh root@lab.example.test 'bash -c \"source /usr/lib/nftban/core/nftban_output.sh && nftban_render_banner full\"'"
    echo "  2. Verify user: ssh root@lab.example.test 'id nftban'"
    echo "  3. Check logs: ssh root@lab.example.test 'ls -la /var/log/nftban/'"
else
    log_error "Some servers failed deployment"
fi

echo ""
echo "============================================================================="
