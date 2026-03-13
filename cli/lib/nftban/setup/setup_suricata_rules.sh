#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="setup_suricata_rules"
# meta:type="setup"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Download and configure Suricata rules using suricata-update"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""

set -Eeuo pipefail
IFS=$'\n\t'

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

print_status() {
    echo -e "${GREEN}[✓]${NC} $1" >&2
}

print_error() {
    echo -e "${RED}[✗]${NC} $1" >&2
}

print_info() {
    echo -e "${BLUE}[i]${NC} $1" >&2
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1" >&2
}

# Source distro config for distribution-specific paths
: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/nftban_distro_config.sh" 2>/dev/null || true

# Suricata paths (from distro config - NO HARDCODED FALLBACKS)
: "${SURICATA_RULES_DIR:=${DISTRO_PATHS[suricata_rules_dir]}}"

main() {
    print_info "NFTBan Suricata Rules Setup"
    echo ""

    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        exit 1
    fi

    # Check if suricata-update is installed
    if ! command -v suricata-update >/dev/null 2>&1; then
        print_error "suricata-update not found"
        print_info "Install: pip3 install --upgrade suricata-update"
        exit 1
    fi

    # Check if Suricata is installed
    if ! command -v suricata >/dev/null 2>&1; then
        print_error "Suricata not found"
        print_info "Install Suricata first"
        exit 1
    fi

    print_info "Suricata version: $(suricata --version | head -1)"
    print_info "suricata-update version: $(suricata-update --version 2>&1 | grep -oP 'version \K[0-9.]+' || echo 'unknown')"
    echo ""

    # Step 1: Update source index
    print_info "Updating rule source index..."
    if suricata-update update-sources 2>&1 | grep -q "Source index updated"; then
        print_status "Source index updated"
    else
        print_warning "Source index may already be current"
    fi
    echo ""

    # Step 2: List available sources
    print_info "Available rule sources:"
    suricata-update list-sources 2>&1 | grep -E "^Name:|Summary:" | head -10
    echo ""

    # Step 3: Enable ET Open (free ruleset)
    print_info "Enabling ET/Open ruleset (free)..."
    if suricata-update enable-source et/open 2>&1; then
        print_status "ET/Open ruleset enabled"
    else
        print_warning "ET/Open may already be enabled"
    fi
    echo ""

    # Step 4: Download and install rules
    print_info "Downloading Suricata rules (this may take a few minutes)..."
    local _suricata_log
    _suricata_log=$(mktemp /tmp/suricata-update.XXXXXX)
    if suricata-update 2>&1 | tee "$_suricata_log" | grep -q "Writing rules"; then
        print_status "Rules downloaded and installed"
        rm -f "$_suricata_log"

        # Show rule count
        local rule_count
        rule_count=$(find "${SURICATA_RULES_DIR}" -name "*.rules" -exec cat {} \; 2>/dev/null | grep -c "^alert" || echo "0")
        print_info "Total alert rules: $rule_count"
    else
        print_error "Rule download failed"
        cat "$_suricata_log" >&2
        rm -f "$_suricata_log"
        exit 1
    fi
    echo ""

    # Step 5: Restart Suricata to load new rules
    print_info "Restarting Suricata to load rules..."
    if systemctl is-active --quiet suricata.service; then
        systemctl restart suricata.service
        sleep 2

        if systemctl is-active --quiet suricata.service; then
            print_status "Suricata restarted successfully"
        else
            print_error "Suricata failed to restart"
            systemctl status suricata.service --no-pager -l
            exit 1
        fi
    else
        print_warning "Suricata not running, starting it..."
        systemctl start suricata.service
        sleep 2

        if systemctl is-active --quiet suricata.service; then
            print_status "Suricata started successfully"
        else
            print_error "Suricata failed to start"
            systemctl status suricata.service --no-pager -l
            exit 1
        fi
    fi
    echo ""

    # Summary
    print_status "Suricata rules setup complete!"
    echo ""
    print_info "Rule Details:"
    echo "  Rules directory: ${SURICATA_RULES_DIR}/"
    echo "  Enabled sources: et/open"
    echo "  Update schedule: Weekly (Sunday 3 AM)"
    echo ""
    print_info "Manual update command:"
    echo "  suricata-update && systemctl restart suricata"
    echo ""
    print_info "Check eve.json for alerts:"
    echo "  tail -f ${NFTBAN_LOG_DIR}/suricata/eve-alerts.json | jq 'select(.event_type==\"alert\")'"
    echo ""
}

main "$@"
