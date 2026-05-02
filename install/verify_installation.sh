#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.0.0 - Installation Verification Script
# =============================================================================
# meta:name="verify_installation"
# meta:type="script"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Verify all files are correctly installed on target system"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Usage: ./verify_installation.sh [--verbose]
# =============================================================================

set -Eeuo pipefail

VERBOSE=false
if [[ "${1:-}" == "--verbose" ]] || [[ "${1:-}" == "-v" ]]; then
    VERBOSE=true
fi

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Counters
TOTAL=0
MISSING=0
PRESENT=0

check_file() {
    local file="$1"
    local required="${2:-true}"

    TOTAL=$((TOTAL + 1))

    if [[ -f "$file" ]]; then
        PRESENT=$((PRESENT + 1))
        if [[ "$VERBOSE" == true ]]; then
            echo -e "${GREEN}✓${NC} $file"
        fi
        return 0
    else
        MISSING=$((MISSING + 1))
        if [[ "$required" == "true" ]]; then
            echo -e "${RED}✗${NC} MISSING (required): $file"
        else
            echo -e "${YELLOW}⚠${NC} MISSING (optional): $file"
        fi
        return 1
    fi
}

echo "========================================================================"
echo "NFTBan Installation Verification"
echo "========================================================================"
echo ""

# ==============================================================================
# Core CLI Files (Required)
# ==============================================================================
echo "Checking Core CLI Files..."
check_file "/usr/sbin/nftban"
check_file "/usr/lib/nftban/core/nftban_output.sh"
check_file "/usr/lib/nftban/core/nftban_file_ops.sh"
check_file "/usr/lib/nftban/core/nftban_system_ip.sh"

# ==============================================================================
# NEW FILES - Added 2025-11-28
# ==============================================================================
echo ""
echo "Checking NEW Files (2025-11-28)..."
check_file "/usr/lib/nftban/lib/nftban_metrics.sh"        # NEW: Shared metrics library
check_file "/usr/lib/nftban/cli/cmd_metrics.sh"           # NEW: Metrics command

# ==============================================================================
# Updated Files - Modified 2025-11-28
# ==============================================================================
echo ""
echo "Checking Updated Files (2025-11-28)..."
check_file "/usr/lib/nftban/cli/cmd_whitelist_system.sh"  # Modified: Removed deprecated
check_file "/usr/lib/nftban/core/nftban_system_ip.sh"     # Modified: meta:depends
check_file "/usr/lib/nftban/cli/cmd_search.sh"            # Modified: meta:depends

# ==============================================================================
# Go Binaries (Required)
# ==============================================================================
echo ""
echo "Checking Go Binaries..."
check_file "/usr/lib/nftban/bin/nftban-core"
# v1.100.1b.A: nftban-ui no longer shipped — check removed.

# ==============================================================================
# Configuration Files
# ==============================================================================
echo ""
echo "Checking Configuration..."
check_file "/etc/nftban/nftban.conf"
check_file "/etc/nftban/blacklist.d/99-manual.conf"
check_file "/etc/nftban/whitelist.d/99-manual.conf"

# ==============================================================================
# Systemd Services
# ==============================================================================
echo ""
echo "Checking Systemd Services..."
check_file "/usr/lib/systemd/system/nftban-unified-exporter.service"
check_file "/usr/lib/systemd/system/nftban-unified-exporter.timer"
# v1.100.1b.A: nftban-ui.service + nftban-ui-auth.socket no longer
# shipped — checks removed. Transitional postinst removes any
# orphaned units from prior installs.

# ==============================================================================
# Library Files
# ==============================================================================
echo ""
echo "Checking Library Files..."
check_file "/usr/lib/nftban/lib/nftban_distro_config.sh"
check_file "/usr/lib/nftban/lib/nft_schema.sh"
check_file "/usr/lib/nftban/lib/strict.sh" false

# ==============================================================================
# CLI Command Modules
# ==============================================================================
echo ""
echo "Checking CLI Commands..."
check_file "/usr/lib/nftban/cli/cmd_status.sh"
check_file "/usr/lib/nftban/cli/cmd_ban.sh"
check_file "/usr/lib/nftban/cli/cmd_feeds.sh"
check_file "/usr/lib/nftban/cli/cmd_geoban.sh"
check_file "/usr/lib/nftban/cli/cmd_stats.sh"
check_file "/usr/lib/nftban/cli/cmd_mail.sh"
check_file "/usr/lib/nftban/cli/cmd_report.sh"

# ==============================================================================
# Templates - Mail and Reports
# ==============================================================================
echo ""
echo "Checking Templates..."
check_file "/usr/share/nftban/templates/mail/header_default.html"
check_file "/usr/share/nftban/templates/mail/footer_default.html"
check_file "/usr/share/nftban/templates/mail/test_email.html"
check_file "/usr/share/nftban/templates/mail/stats_email.html"
check_file "/usr/share/nftban/templates/reports/fhs_report.html"
check_file "/usr/share/nftban/templates/reports/module_report.html"
check_file "/usr/share/nftban/templates/reports/port_report.html"
check_file "/usr/share/nftban/templates/reports/stats_dashboard.html"

# ==============================================================================
# Mail Configuration
# ==============================================================================
echo ""
echo "Checking Mail Configuration..."
check_file "/etc/nftban/conf.d/mail.conf" false  # Optional

# ==============================================================================
# Summary
# ==============================================================================
echo ""
echo "========================================================================"
echo "Summary:"
echo "========================================================================"
echo "Total files checked: $TOTAL"
echo -e "Present: ${GREEN}$PRESENT${NC}"
if [[ $MISSING -gt 0 ]]; then
    echo -e "Missing: ${RED}$MISSING${NC}"
else
    echo -e "Missing: ${GREEN}0${NC}"
fi
echo ""

if [[ $MISSING -eq 0 ]]; then
    echo -e "${GREEN}✅ All required files present!${NC}"
    exit 0
else
    echo -e "${RED}❌ Some files are missing!${NC}"
    echo ""
    echo "To install missing files, run:"
    echo "  cd /path/to/nftban"
    echo "  sudo ./install.sh"
    exit 1
fi
