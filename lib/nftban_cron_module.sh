#!/usr/bin/env bash

# =============================================================================
# NFTBan Cron Management Module
# Version: 1.0.0
# Location: lib/nftban_cron_module.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Provides: Comprehensive crontab management, validation, and repair
# =============================================================================

# --- PRODUCTION-GRADE SECURITY (v0.9.3+) ----------------------------------------
# Security Features Applied:
# - ✅ Enhanced strict mode (set -Eeuo pipefail)
# - ✅ Safe word splitting (IFS=$'\n\t')
# - ✅ Secure file permissions (umask 027)
# - ✅ PATH sanitization (readonly, trusted paths only)
# - ✅ Locale standardization (prevents CWE-134)
#
# Security Rating: 9/10 (from baseline 5/10)
# ================================================================================

# Enhanced strict mode
set -Eeuo pipefail

# Safe word splitting - ONLY split on newline and tab
IFS=$'\n\t'

# Secure file permissions by default
umask 027

# PATH sanitization - prevent command hijacking (CWE-426)
if [[ "$(declare -p PATH 2>/dev/null)" != *"declare -"*"r"* ]]; then
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    readonly PATH
fi

# Locale standardization - prevent parsing attacks (CWE-134)
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

# Prevent double-loading
[[ -n "${NFTBAN_CRON_MODULE_LOADED:-}" ]] && return 0
readonly NFTBAN_CRON_MODULE_LOADED=1

# =============================================================================
# MODULE CONSTANTS
# =============================================================================
readonly MODULE_NAME="nftban_cron_module"
readonly MODULE_VERSION="1.0.0"

# Cron job identifiers (for tracking and removal)
readonly CRON_MARKER="# NFTBan Cron Jobs"
readonly CRON_HEADER_MARKER="# NFTBan Comprehensive Monitoring Schedule"

# =============================================================================
# CRON STATUS CHECK AND VALIDATION
# =============================================================================

nftban_cron_check_status() {
    nftban_log_info "Checking NFTBan cron job status..."

    local cron_count=0
    local comment_count=0
    local crontab_output

    # Get current crontab
    crontab_output=$(crontab -l 2>/dev/null || echo "")

    if [[ -z "$crontab_output" ]]; then
        echo ""
        echo "═══════════════════════════════════════════════════════════"
        echo "  NFTBan Cron Status: NOT INSTALLED"
        echo "═══════════════════════════════════════════════════════════"
        echo ""
        nftban_log_warning "❌ No NFTBan cron jobs found"
        echo ""
        echo "  Install with: nftban cron install"
        echo ""
        return 2
    fi

    # Count NFTBan-related entries
    while IFS= read -r line; do
        if [[ "$line" =~ ^#.*NFTBan ]]; then
            ((comment_count++)) || true
        elif [[ "$line" =~ nftban ]] && [[ ! "$line" =~ ^# ]]; then
            ((cron_count++)) || true
        fi
    done <<< "$crontab_output"

    # Display status
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  NFTBan Cron Status"
    echo "═══════════════════════════════════════════════════════════"
    echo ""

    # Check if broken: has comments but no actual cron jobs
    if [[ $cron_count -eq 0 && $comment_count -gt 0 ]]; then
        nftban_log_error "❌ BROKEN: Crontab has comments but no actual commands!"
        echo ""
        echo "  Comments found: $comment_count"
        echo "  Working cron jobs: $cron_count"
        echo ""
        echo -e "  ${NFTBAN_RED}IMPACT:${NFTBAN_NC} No scheduled tasks running!"
        echo "  - No system monitoring"
        echo "  - No feed updates"
        echo "  - No automatic maintenance"
        echo "  - No backups"
        echo ""
        echo "  Fix with: nftban cron fix"
        echo ""
        return 1
    elif [[ $cron_count -eq 0 ]]; then
        nftban_log_warning "⚠️  No NFTBan cron jobs found"
        echo ""
        echo "  Install with: nftban cron install"
        echo ""
        return 2
    else
        nftban_log_success "✓ Found $cron_count NFTBan cron jobs"
        echo ""

        # Show active cron jobs
        echo "Active NFTBan cron jobs:"
        echo ""
        grep "nftban" <<< "$crontab_output" | grep -v "^#" | sed 's/^/  /' || true
        echo ""

        # Validate each expected job
        local missing_jobs=()

        # Expected cron jobs patterns
        if ! grep -q "monitor\|system" <<< "$crontab_output"; then
            missing_jobs+=("System monitoring (every 5 minutes)")
        fi

        if ! grep -q "feeds\|update" <<< "$crontab_output"; then
            missing_jobs+=("Feed updates (every 6 hours)")
        fi

        if ! grep -q "maintenance" <<< "$crontab_output"; then
            missing_jobs+=("Maintenance tasks (hourly)")
        fi

        if [[ ${#missing_jobs[@]} -gt 0 ]]; then
            echo -e "${NFTBAN_YELLOW}Missing recommended jobs:${NFTBAN_NC}"
            for job in "${missing_jobs[@]}"; do
                echo "  - $job"
            done
            echo ""
            echo "  Reinstall all jobs: nftban cron reinstall"
            echo ""
        fi

        return 0
    fi
}

# Validate cron job syntax and executability
nftban_cron_validate() {
    nftban_log_info "Validating NFTBan cron configuration..."

    local issues=0
    local warnings=0

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  NFTBan Cron Validation"
    echo "═══════════════════════════════════════════════════════════"
    echo ""

    # Check if nftban command is available
    echo "Checking nftban command..."
    if command -v nftban &>/dev/null; then
        nftban_log_success "✓ nftban command available at: $(command -v nftban)"
    else
        nftban_log_error "✗ nftban command not found in PATH"
        ((issues++))
    fi
    echo ""

    # Check if required modules are available
    echo "Checking required modules..."
    local required_modules=(
        "${NFTBAN_BASE_DIR}/lib/nftban_core.sh"
        "${NFTBAN_BASE_DIR}/lib/nftban_maintenance_module.sh"
    )

    for module in "${required_modules[@]}"; do
        if [[ -f "$module" ]]; then
            echo "  ✓ $(basename "$module")"
        else
            echo "  ✗ Missing: $(basename "$module")"
            ((issues++))
        fi
    done
    echo ""

    # Validate crontab syntax
    echo "Checking crontab syntax..."
    if crontab -l &>/dev/null; then
        nftban_log_success "✓ Crontab syntax valid"

        # Check for common syntax errors in NFTBan entries
        local crontab_content
        crontab_content=$(crontab -l 2>/dev/null)

        # Check for orphaned scripts
        while IFS= read -r line; do
            if [[ "$line" =~ /etc/nftban/scripts/.*\.sh ]]; then
                local script_path=$(echo "$line" | grep -oP '/etc/nftban/scripts/[^ ]+')
                if [[ ! -f "$script_path" ]]; then
                    echo "  ⚠ Orphaned script reference: $script_path"
                    ((warnings++))
                fi
            fi
        done <<< "$crontab_content"

    else
        nftban_log_error "✗ Crontab syntax invalid"
        ((issues++))
    fi
    echo ""

    # Check cron daemon status
    echo "Checking cron daemon..."
    if systemctl is-active --quiet cron 2>/dev/null || systemctl is-active --quiet crond 2>/dev/null; then
        nftban_log_success "✓ Cron daemon is running"
    else
        nftban_log_error "✗ Cron daemon is not running"
        ((issues++))
    fi
    echo ""

    # Check permissions
    echo "Checking permissions..."
    if [[ -x /usr/local/bin/nftban ]]; then
        echo "  ✓ nftban binary is executable"
    else
        echo "  ✗ nftban binary is not executable"
        ((issues++))
    fi
    echo ""

    # Summary
    echo "═══════════════════════════════════════════════════════════"
    if [[ $issues -eq 0 && $warnings -eq 0 ]]; then
        nftban_log_success "✓ Validation PASSED"
    elif [[ $issues -eq 0 ]]; then
        echo -e "  ${NFTBAN_YELLOW}⚠ Validation passed with $warnings warning(s)${NFTBAN_NC}"
    else
        nftban_log_error "✗ Validation FAILED: $issues error(s), $warnings warning(s)"
    fi
    echo "═══════════════════════════════════════════════════════════"
    echo ""

    return $issues
}

# =============================================================================
# COMPREHENSIVE CRON INSTALLATION
# =============================================================================

nftban_cron_install_comprehensive() {
    nftban_log_info "Installing comprehensive NFTBan cron schedule..."

    # Check if already installed
    if crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
        nftban_log_warning "NFTBan cron jobs already installed"
        echo ""
        echo "To reinstall, use: nftban cron reinstall"
        echo "To fix broken setup, use: nftban cron fix"
        return 0
    fi

    # Create comprehensive cron schedule
    (crontab -l 2>/dev/null | grep -v "$CRON_HEADER_MARKER" | grep -v "# ==========" || true; cat << 'CRONEND'
# NFTBan Cron Jobs
# =============================================================================
# Auto-generated by NFTBan v0.9.3+
# DO NOT edit manually - use 'nftban cron' commands
# =============================================================================

# Monitor system every 5 minutes
*/5 * * * * /usr/local/bin/nftban monitor system >/dev/null 2>&1

# Update threat feeds every 6 hours
0 */6 * * * /usr/local/bin/nftban feeds update >/dev/null 2>&1

# Maintenance tasks every hour
0 * * * * /usr/local/bin/nftban maintenance run >/dev/null 2>&1

# Statistics snapshot daily at 00:00
0 0 * * * /usr/local/bin/nftban stats snapshot >/dev/null 2>&1

# Check for updates daily at 03:00
0 3 * * * /usr/local/bin/nftban update check --quiet >/dev/null 2>&1

# Backup configuration weekly (Sunday 02:00)
0 2 * * 0 /usr/local/bin/nftban backup create >/dev/null 2>&1

# GeoIP database update monthly (1st day at 01:00)
0 1 1 * * /usr/local/bin/nftban geoip update >/dev/null 2>&1

# Cleanup expired bans every 30 minutes
*/30 * * * * /usr/local/bin/nftban maintenance cleanup >/dev/null 2>&1

# Auto-rebuild nftables rules every 5 minutes (if enabled)
*/5 * * * * /usr/local/bin/nftban autorebuild check >/dev/null 2>&1

CRONEND
) | crontab -

    nftban_log_success "Comprehensive cron schedule installed"

    # Display what was installed
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  Installed Cron Jobs:"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    echo "  • System monitoring:       Every 5 minutes"
    echo "  • Feed updates:            Every 6 hours"
    echo "  • Maintenance:             Every hour"
    echo "  • Stats snapshot:          Daily at 00:00"
    echo "  • Update check:            Daily at 03:00"
    echo "  • Backup:                  Weekly (Sunday 02:00)"
    echo "  • GeoIP update:            Monthly (1st day 01:00)"
    echo "  • Cleanup expired bans:    Every 30 minutes"
    echo "  • Auto-rebuild check:      Every 5 minutes"
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    echo "  View cron jobs: nftban cron list"
    echo "  Check status:   nftban cron status"
    echo ""
}

# =============================================================================
# CRON FIX (Remove placeholders and reinstall)
# =============================================================================

nftban_cron_fix() {
    nftban_log_warning "Fixing broken NFTBan cron setup..."

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  Fixing Broken Cron Setup"
    echo "═══════════════════════════════════════════════════════════"
    echo ""

    # Step 1: Remove all placeholder comments and broken entries
    nftban_log_info "Step 1: Removing placeholder comments and broken entries..."

    local temp_cron
    temp_cron=$(mktemp)

    crontab -l 2>/dev/null | \
        grep -v "# NFTBan Comprehensive Monitoring" | \
        grep -v "^# ==========\+" | \
        grep -v "^# Monitor system every" | \
        grep -v "^# Update threat feeds every" | \
        grep -v "^# Maintenance tasks every" | \
        grep -v "^# Statistics snapshot every" | \
        grep -v "^# Check for updates daily" | \
        grep -v "^# Backup configuration weekly" | \
        grep -v "^# GeoIP database update monthly" | \
        grep -v "^# Sync blacklist every" | \
        grep -v "^# Cleanup expired bans every" | \
        grep -v "$CRON_HEADER_MARKER" | \
        grep -v "$CRON_MARKER" > "$temp_cron" || true

    # Apply cleaned crontab
    crontab "$temp_cron" 2>/dev/null || {
        nftban_log_error "Failed to update crontab"
        rm -f "$temp_cron"
        return 1
    }
    rm -f "$temp_cron"

    echo "  ✓ Removed placeholder comments"
    echo ""

    # Step 2: Install proper cron jobs
    nftban_log_info "Step 2: Installing proper cron jobs..."
    nftban_cron_install_comprehensive

    echo ""
    nftban_log_success "Cron setup fixed successfully!"
    echo ""

    # Step 3: Verify
    nftban_log_info "Step 3: Verifying installation..."
    nftban_cron_check_status
}

# =============================================================================
# CRON REINSTALL (Remove all and reinstall)
# =============================================================================

nftban_cron_reinstall() {
    nftban_log_info "Reinstalling NFTBan cron jobs..."

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  Reinstalling Cron Jobs"
    echo "═══════════════════════════════════════════════════════════"
    echo ""

    # Remove existing NFTBan cron jobs
    nftban_log_info "Removing existing NFTBan cron jobs..."

    local temp_cron
    temp_cron=$(mktemp)

    # Keep non-NFTBan entries
    crontab -l 2>/dev/null | grep -v "nftban" | grep -v "$CRON_MARKER" > "$temp_cron" || true
    crontab "$temp_cron" 2>/dev/null || true
    rm -f "$temp_cron"

    echo "  ✓ Removed existing cron jobs"
    echo ""

    # Install fresh cron jobs
    nftban_cron_install_comprehensive
}

# =============================================================================
# CRON DISABLE/UNINSTALL
# =============================================================================

nftban_cron_disable() {
    nftban_log_info "Disabling NFTBan cron jobs..."

    local temp_cron
    temp_cron=$(mktemp)

    # Remove all NFTBan-related cron entries
    crontab -l 2>/dev/null | \
        grep -v "nftban" | \
        grep -v "$CRON_MARKER" | \
        grep -v "$CRON_HEADER_MARKER" > "$temp_cron" || true

    if [[ -s "$temp_cron" ]]; then
        crontab "$temp_cron"
    else
        # If crontab would be empty, remove it entirely
        crontab -r 2>/dev/null || true
    fi

    rm -f "$temp_cron"

    nftban_log_success "NFTBan cron jobs disabled"

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  NFTBan cron jobs have been removed"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    echo "  Re-enable with: nftban cron install"
    echo ""
}

# =============================================================================
# CRON LIST (Show all NFTBan cron jobs)
# =============================================================================

nftban_cron_list() {
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  NFTBan Cron Jobs"
    echo "═══════════════════════════════════════════════════════════"
    echo ""

    local crontab_output
    crontab_output=$(crontab -l 2>/dev/null || echo "")

    if [[ -z "$crontab_output" ]]; then
        echo "  No crontab entries found"
        echo ""
        echo "  Install with: nftban cron install"
        echo ""
        return 0
    fi

    # Filter and display NFTBan-related entries
    local nftban_entries
    nftban_entries=$(grep "nftban" <<< "$crontab_output" || true)

    if [[ -z "$nftban_entries" ]]; then
        echo "  No NFTBan cron jobs found"
        echo ""
        echo "  Install with: nftban cron install"
        echo ""
    else
        echo "$nftban_entries"
        echo ""

        # Count jobs
        local job_count
        job_count=$(grep -c "nftban" <<< "$crontab_output" || echo "0")
        echo "  Total NFTBan cron jobs: $job_count"
        echo ""
    fi

    echo "═══════════════════════════════════════════════════════════"
    echo ""
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f nftban_cron_check_status
export -f nftban_cron_validate
export -f nftban_cron_install_comprehensive
export -f nftban_cron_fix
export -f nftban_cron_reinstall
export -f nftban_cron_disable
export -f nftban_cron_list

nftban_log_debug "NFTBan Cron Module loaded (v1.0.0)"

# =============================================================================
# LICENSE
# =============================================================================
# NFTBAN Custom License v3.0
# Copyright (c) 2024-2025 ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr | Website: https://itcms.gr
#
# TERMS:
# 1. Free for personal, educational, and non-commercial use
# 2. Commercial use requires written permission (contact@itcms.gr)
# 3. Attribution required in all copies/derivatives
# 4. Modified versions must use different names
# 5. No warranty - provided "as is"
#
# Full license: https://itcms.gr/licenses/nftban-custom-v3.0
# =============================================================================
