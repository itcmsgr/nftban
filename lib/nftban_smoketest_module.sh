#!/usr/bin/env bash

# BUG51 FIX: Add strict mode for production-grade security
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# =============================================================================
# NFTBan Smoke Test & Diagnostics Module
# Version: 0.9.2
# Location: lib/nftban_smoketest_module.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Built-in smoke testing and diagnostics system
# =============================================================================

# Prevent double-loading
[[ -n "${NFTBAN_SMOKETEST_LOADED:-}" ]] && return 0
readonly NFTBAN_SMOKETEST_LOADED=1

# =============================================================================
# MODULE CONFIGURATION
# =============================================================================

readonly SMOKETEST_LOG="/var/log/nftban/smoketest.log"
readonly DIAGNOSTICS_LOG="/var/log/nftban/diagnostics.log"

# Test result counters
SMOKETEST_TOTAL=0
SMOKETEST_PASSED=0
SMOKETEST_FAILED=0
SMOKETEST_SKIPPED=0
SMOKETEST_WARNINGS=0

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

smoketest_reset_counters() {
    SMOKETEST_TOTAL=0
    SMOKETEST_PASSED=0
    SMOKETEST_FAILED=0
    SMOKETEST_SKIPPED=0
    SMOKETEST_WARNINGS=0
}

smoketest_log() {
    local message="$*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" >> "$SMOKETEST_LOG"
}

smoketest_start() {
    ((++SMOKETEST_TOTAL))
    printf "${NFTBAN_CYAN}[%03d]${NFTBAN_NC} Testing: %s ... " "$SMOKETEST_TOTAL" "$1"
    smoketest_log "START: $1"
}

smoketest_pass() {
    ((++SMOKETEST_PASSED))
    printf "${NFTBAN_GREEN}✓ PASS${NFTBAN_NC}\n"
    smoketest_log "PASS"
}

smoketest_fail() {
    ((++SMOKETEST_FAILED))
    printf "${NFTBAN_RED}✗ FAIL${NFTBAN_NC}"
    [[ -n "$1" ]] && printf ": %s" "$1"
    printf "\n"
    smoketest_log "FAIL: ${1:-no details}"
}

smoketest_skip() {
    ((++SMOKETEST_SKIPPED))
    printf "${NFTBAN_YELLOW}⊘ SKIP${NFTBAN_NC}"
    [[ -n "$1" ]] && printf ": %s" "$1"
    printf "\n"
    smoketest_log "SKIP: ${1:-no reason}"
}

smoketest_warn() {
    ((++SMOKETEST_WARNINGS))
    printf "${NFTBAN_YELLOW}⚠ WARN${NFTBAN_NC}"
    [[ -n "$1" ]] && printf ": %s" "$1"
    printf "\n"
    smoketest_log "WARN: ${1:-no details}"
}

smoketest_category() {
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  CATEGORY: $1"
    echo "═══════════════════════════════════════════════════════"
    smoketest_log "CATEGORY: $1"
}

smoketest_summary() {
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  TEST SUMMARY"
    echo "═══════════════════════════════════════════════════════"
    printf "Total tests:   %3d\n" "$SMOKETEST_TOTAL"
    printf "${NFTBAN_GREEN}Passed:        %3d${NFTBAN_NC}\n" "$SMOKETEST_PASSED"
    printf "${NFTBAN_RED}Failed:        %3d${NFTBAN_NC}\n" "$SMOKETEST_FAILED"
    printf "${NFTBAN_YELLOW}Skipped:       %3d${NFTBAN_NC}\n" "$SMOKETEST_SKIPPED"
    printf "${NFTBAN_YELLOW}Warnings:      %3d${NFTBAN_NC}\n" "$SMOKETEST_WARNINGS"
    echo "═══════════════════════════════════════════════════════"

    smoketest_log "SUMMARY: Total=$SMOKETEST_TOTAL Passed=$SMOKETEST_PASSED Failed=$SMOKETEST_FAILED Skipped=$SMOKETEST_SKIPPED Warnings=$SMOKETEST_WARNINGS"

    if [[ $SMOKETEST_FAILED -eq 0 ]]; then
        echo ""
        printf "${NFTBAN_GREEN}✓ ALL TESTS PASSED${NFTBAN_NC}\n"
        echo ""
        return 0
    else
        echo ""
        printf "${NFTBAN_RED}✗ TESTS FAILED${NFTBAN_NC}\n"
        echo ""
        echo "Review logs at: $SMOKETEST_LOG"
        return 1
    fi
}

# =============================================================================
# TEST CATEGORIES
# =============================================================================

smoketest_installation() {
    smoketest_category "Installation"

    smoketest_start "Base directory exists"
    if [[ -d "$NFTBAN_BASE_DIR" ]]; then
        smoketest_pass
    else
        smoketest_fail "$NFTBAN_BASE_DIR not found"
    fi

    smoketest_start "Config directory exists"
    if [[ -d "$NFTBAN_CONFIG_DIR" ]]; then
        smoketest_pass
    else
        smoketest_fail "$NFTBAN_CONFIG_DIR not found"
    fi

    smoketest_start "Lib directory exists"
    if [[ -d "$NFTBAN_LIB_DIR" ]]; then
        smoketest_pass
    else
        smoketest_fail "$NFTBAN_LIB_DIR not found"
    fi

    smoketest_start "Scripts directory exists"
    if [[ -n "${NFTBAN_SCRIPTS_DIR:-}" ]] && [[ -d "$NFTBAN_SCRIPTS_DIR" ]]; then
        smoketest_pass
    elif [[ -z "${NFTBAN_SCRIPTS_DIR:-}" ]]; then
        smoketest_skip "NFTBAN_SCRIPTS_DIR not defined (optional)"
    else
        smoketest_warn "$NFTBAN_SCRIPTS_DIR not found (optional)"
    fi

    smoketest_start "Version file exists"
    if [[ -f "$NFTBAN_BASE_DIR/.version" ]]; then
        local version=$(cat "$NFTBAN_BASE_DIR/.version")
        smoketest_pass
        echo "      → Version: $version"
    else
        smoketest_fail ".version file not found"
    fi

    smoketest_start "CLI binary exists"
    if [[ -x "$(command -v nftban)" ]]; then
        smoketest_pass
    else
        smoketest_fail "nftban command not found in PATH"
    fi
}

smoketest_nftables_structure() {
    smoketest_category "nftables Structure"

    # Check for v0.9.0+ split tables
    smoketest_start "IPv4 table exists (ip nftban_v4)"
    if nft list table ip nftban_v4 &>/dev/null; then
        smoketest_pass
        NFTBAN_USING_SPLIT_TABLES=1
    else
        # Check for old v0.8.5 inet table
        if nft list table ip nftban_v4 &>/dev/null || nft list table ip6 nftban_v6 &>/dev/null || nft list table inet nftban_global &>/dev/null; then  # v0.9.0 or v0.8.5
            smoketest_warn "Using old inet table (v0.8.5) - upgrade to v0.9.0 recommended"
            NFTBAN_USING_SPLIT_TABLES=0
        else
            smoketest_fail "No nftables tables found"
            return 1
        fi
    fi

    if [[ $NFTBAN_USING_SPLIT_TABLES -eq 1 ]]; then
        smoketest_start "IPv6 table exists (ip6 nftban_v6)"
        if nft list table ip6 nftban_v6 &>/dev/null; then
            smoketest_pass
        else
            smoketest_fail "ip6 nftban_v6 table missing"
        fi

        # Test sets in split tables
        local required_sets=("whitelist" "temp_ban" "user_blacklist" "system_blacklist" "feeds")

        for set_name in "${required_sets[@]}"; do
            smoketest_start "IPv4 set: $set_name"
            if nft list set ip nftban_v4 "$set_name" &>/dev/null; then
                smoketest_pass
            else
                smoketest_fail "Set $set_name not found in nftban_v4"
            fi
        done

        for set_name in "${required_sets[@]}"; do
            smoketest_start "IPv6 set: $set_name"
            if nft list set ip6 nftban_v6 "$set_name" &>/dev/null; then
                smoketest_pass
            else
                smoketest_fail "Set $set_name not found in nftban_v6"
            fi
        done

        # Old table should NOT exist
        smoketest_start "Old inet table removed"
        if nft list table ip nftban_v4 &>/dev/null || nft list table ip6 nftban_v6 &>/dev/null || nft list table inet nftban_global &>/dev/null; then  # v0.9.0 or v0.8.5
            smoketest_fail "Old inet table still exists - migration incomplete"
        else
            smoketest_pass
        fi

    else
        # Testing old inet table structure (v0.8.5)
        # Legacy v0.8.5 set names (for backward compatibility testing)
        local required_sets_old=("whitelist_v4" "whitelist_v6" "temp_ban_v4" "temp_ban_v6"
                                 "user_blacklist_v4" "user_blacklist_v6" "system_blacklist_v4"
                                 "system_blacklist_v6" "feeds_v4" "feeds_v6")

        for set_name in "${required_sets_old[@]}"; do
            smoketest_start "inet set: $set_name"
            if nft list set inet nftban_global "$set_name" &>/dev/null || \
               nft list set ip nftban_v4 "${set_name/_v4/}" &>/dev/null || \
               nft list set ip6 nftban_v6 "${set_name/_v6/}" &>/dev/null; then  # Check both old and new
                smoketest_pass
            else
                smoketest_warn "Set $set_name not found"
            fi
        done
    fi
}

smoketest_core_modules() {
    smoketest_category "Core Modules"

    local core_modules=(
        "nftban_core.sh"
        "nftban_nftables_module.sh"
        "nftban_whitelist_module.sh"
        "nftban_blacklist_module.sh"
        "nftban_safety_module.sh"
    )

    for module in "${core_modules[@]}"; do
        smoketest_start "Module exists: $module"
        if [[ -f "$NFTBAN_LIB_DIR/$module" ]]; then
            smoketest_pass
        else
            smoketest_fail "$module not found"
        fi
    done

    # Test module loading
    smoketest_start "Core module functions loaded"
    if declare -F nftban_log_info &>/dev/null; then
        smoketest_pass
    else
        smoketest_fail "Core functions not available"
    fi
}

smoketest_feature_modules() {
    smoketest_category "Feature Modules"

    local feature_modules=(
        "nftban_ddos_module.sh"
        "nftban_portscan_module.sh"
        "nftban_feeds_module.sh"
        "nftban_fail2ban_module.sh"
    )

    for module in "${feature_modules[@]}"; do
        smoketest_start "Feature module: $module"
        if [[ -f "$NFTBAN_LIB_DIR/$module" ]]; then
            smoketest_pass
        else
            smoketest_warn "$module not found (optional)"
        fi
    done

    # Test v0.9.0 specific modules
    smoketest_start "IPCALC module (v0.9.0+)"
    if [[ -f "$NFTBAN_LIB_DIR/nftban_ipcalc_module.sh" ]]; then
        smoketest_pass
    else
        smoketest_skip "Not on v0.9.0 yet"
    fi

    smoketest_start "Sync module (v0.9.0+)"
    if [[ -f "$NFTBAN_LIB_DIR/nftban_sync_module.sh" ]]; then
        smoketest_pass
    else
        smoketest_skip "Not on v0.9.0 yet"
    fi
}

smoketest_dependencies() {
    smoketest_category "System Dependencies"

    local required_deps=(
        "nft:nftables"
        "systemctl:systemd"
        "ip:iproute2"
        "awk:gawk or mawk"
        "sed:sed"
        "grep:grep"
    )

    for dep_pair in "${required_deps[@]}"; do
        IFS=':' read -r cmd package <<< "$dep_pair"
        smoketest_start "Command: $cmd"
        if command -v "$cmd" &>/dev/null; then
            smoketest_pass
        else
            smoketest_fail "$cmd not found (package: $package)"
        fi
    done

    local optional_deps=(
        "curl:HTTP client"
        "fail2ban-client:Fail2Ban"
        "ipcalc:IP calculator (v0.9.0+)"
        "sipcalc:IPv6 calculator (v0.9.0+)"
    )

    for dep_pair in "${optional_deps[@]}"; do
        IFS=':' read -r cmd desc <<< "$dep_pair"
        smoketest_start "Optional: $cmd"
        if command -v "$cmd" &>/dev/null; then
            smoketest_pass
        else
            smoketest_skip "$desc not installed"
        fi
    done
}

smoketest_cli_commands() {
    smoketest_category "CLI Commands"

    smoketest_start "CLI: help"
    if nftban help &>/dev/null; then
        smoketest_pass
    else
        smoketest_fail "help command failed"
    fi

    smoketest_start "CLI: status"
    if nftban status &>/dev/null; then
        smoketest_pass
    else
        smoketest_fail "status command failed"
    fi

    smoketest_start "CLI: whitelist list"
    if nftban whitelist list &>/dev/null; then
        smoketest_pass
    else
        smoketest_fail "whitelist list failed"
    fi

    smoketest_start "CLI: blacklist list"
    if nftban blacklist list &>/dev/null; then
        smoketest_pass
    else
        smoketest_fail "blacklist list failed"
    fi

    smoketest_start "CLI: ddos status"
    if nftban ddos status &>/dev/null; then
        smoketest_pass
    else
        smoketest_warn "ddos status failed (may not be on v0.8.5+)"
    fi

    smoketest_start "CLI: portscan status"
    if nftban portscan status &>/dev/null; then
        smoketest_pass
    else
        smoketest_warn "portscan status failed (may not be on v0.8.5+)"
    fi

    # v0.9.0+ commands
    smoketest_start "CLI: sync check (v0.9.0+)"
    if nftban sync check &>/dev/null; then
        smoketest_pass
    else
        smoketest_skip "Not on v0.9.0 yet"
    fi

    smoketest_start "CLI: test quick (self-test)"
    if nftban test quick &>/dev/null; then
        smoketest_pass
    else
        smoketest_skip "Self-test not available"
    fi
}

smoketest_safety_mechanisms() {
    smoketest_category "Safety Mechanisms"

    smoketest_start "Safety module loaded"
    if declare -F nftban_safety_check &>/dev/null; then
        smoketest_pass
    else
        smoketest_fail "Safety module not loaded"
    fi

    smoketest_start "Current IP detection"
    local current_ip=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "")
    if [[ -n "$current_ip" ]]; then
        smoketest_pass
        echo "      → Detected IP: $current_ip"
    else
        smoketest_warn "Cannot detect current IP (offline?)"
    fi

    if [[ -n "$current_ip" ]]; then
        smoketest_start "Current IP whitelisted"
        if nftban whitelist check "$current_ip" &>/dev/null; then
            smoketest_pass
        else
            smoketest_warn "Current IP ($current_ip) not whitelisted - LOCKOUT RISK"
        fi
    fi

    smoketest_start "Backup directory exists"
    if [[ -d "/var/backups/nftban" ]]; then
        local backup_count=$(find /var/backups/nftban -name "*.tar.gz" 2>/dev/null | wc -l)
        smoketest_pass
        echo "      → Found $backup_count backup(s)"
    else
        smoketest_warn "No backup directory"
    fi
}

smoketest_configuration() {
    smoketest_category "Configuration Files"

    local config_files=(
        "nftban.conf:Main config"
        "ddos_protection.conf:DDoS settings (v0.8.5+)"
        "portscan.conf:Port scan settings (v0.8.5+)"
    )

    for config_pair in "${config_files[@]}"; do
        IFS=':' read -r file desc <<< "$config_pair"
        smoketest_start "Config: $file"
        if [[ -f "$NFTBAN_CONFIG_DIR/$file" ]]; then
            smoketest_pass
        else
            smoketest_warn "$desc not found"
        fi
    done

    smoketest_start "User config overrides (.conf.local)"
    local local_configs=$(find "$NFTBAN_CONFIG_DIR" -name "*.conf.local" 2>/dev/null | wc -l)
    if [[ $local_configs -gt 0 ]]; then
        smoketest_pass
        echo "      → Found $local_configs user override(s)"
    else
        smoketest_skip "No user overrides (using defaults)"
    fi
}

smoketest_logging() {
    smoketest_category "Logging"

    smoketest_start "Log directory exists"
    if [[ -d "/var/log/nftban" ]]; then
        smoketest_pass
    else
        smoketest_fail "/var/log/nftban not found"
    fi

    local log_files=(
        "nftban_operations.log"
        "ddos.log"
        "portscan.log"
    )

    for log_file in "${log_files[@]}"; do
        smoketest_start "Log file: $log_file"
        if [[ -f "/var/log/nftban/$log_file" ]]; then
            local size=$(du -h "/var/log/nftban/$log_file" 2>/dev/null | cut -f1)
            smoketest_pass
            echo "      → Size: $size"
        else
            smoketest_skip "$log_file not created yet"
        fi
    done
}

smoketest_connectivity() {
    smoketest_category "Network Connectivity"

    smoketest_start "Can resolve DNS"
    if nslookup google.com &>/dev/null || host google.com &>/dev/null; then
        smoketest_pass
    else
        smoketest_fail "DNS resolution failed"
    fi

    smoketest_start "Can reach external internet"
    if curl -s --max-time 5 google.com &>/dev/null || \
       curl -s --max-time 5 cloudflare.com &>/dev/null; then
        smoketest_pass
    else
        smoketest_warn "Cannot reach internet (may be blocked)"
    fi

    smoketest_start "Can reach GitHub"
    if curl -s --max-time 5 github.com &>/dev/null; then
        smoketest_pass
    else
        smoketest_warn "Cannot reach GitHub (updates may fail)"
    fi
}

smoketest_installer_mechanisms() {
    smoketest_category "Installer & Update Mechanisms"

    # Check installer scripts exist
    smoketest_start "Installer script exists"
    if [[ -f "$NFTBAN_BASE_DIR/nftban_init.sh" ]]; then
        smoketest_pass
    else
        smoketest_fail "nftban_init.sh not found"
    fi

    smoketest_start "Init script module exists"
    if [[ -f "$NFTBAN_LIB_DIR/nftban_init_script.sh" ]]; then
        smoketest_pass
    else
        smoketest_fail "nftban_init_script.sh not found"
    fi

    smoketest_start "Uninstaller module exists"
    if [[ -f "$NFTBAN_LIB_DIR/installer/nftban_uninstall_script.sh" ]]; then
        smoketest_pass
    else
        smoketest_fail "nftban_uninstall_script.sh not found"
    fi

    # Check update mechanism
    smoketest_start "Update module exists"
    if [[ -f "$NFTBAN_LIB_DIR/nftban_update_module.sh" ]]; then
        smoketest_pass
    else
        smoketest_fail "nftban_update_module.sh not found"
    fi

    smoketest_start "Update functions loaded"
    if declare -F nftban_update_check &>/dev/null; then
        smoketest_pass
    else
        smoketest_fail "Update functions not available"
    fi

    # Check commit pin file (security)
    smoketest_start "Commit PIN file exists"
    if [[ -f "$NFTBAN_BASE_DIR/.commit_pin" ]]; then
        local pin=$(cat "$NFTBAN_BASE_DIR/.commit_pin")
        smoketest_pass
        echo "      → PIN: ${pin:0:8}..."
    else
        smoketest_warn "No commit PIN (updates disabled for security)"
    fi

    # Check update directory structure
    smoketest_start "Update staging directory"
    if [[ -d "$NFTBAN_BASE_DIR/.update_tmp" ]]; then
        smoketest_warn "Staging directory exists (update in progress or failed?)"
    else
        smoketest_pass
    fi

    # Check backup mechanism
    smoketest_start "Backup directory exists"
    local backup_dir="${NFTBAN_UPDATE_BACKUP_DIR:-/etc/nftban/data/backups}"
    if [[ -d "$backup_dir" ]]; then
        local backup_count=$(find "$backup_dir" -maxdepth 1 -type d -name "pre_update_*" 2>/dev/null | wc -l)
        smoketest_pass
        echo "      → Found $backup_count backup(s)"
    else
        smoketest_skip "Backup directory not created yet"
    fi

    # Test uninstall command availability
    smoketest_start "Uninstall command available"
    if nftban uninstall --help &>/dev/null; then
        smoketest_pass
    else
        smoketest_fail "uninstall command not working"
    fi

    # Check bash completion installation
    smoketest_start "Bash completion installed"
    if [[ -f "/etc/bash_completion.d/nftban" ]] || [[ -f "/usr/share/bash-completion/completions/nftban" ]]; then
        smoketest_pass
    else
        smoketest_warn "Bash completion not installed (tab completion unavailable)"
    fi

    # Check update log
    smoketest_start "Update log exists"
    if [[ -f "/var/log/nftban/update.log" ]]; then
        local size=$(du -h "/var/log/nftban/update.log" 2>/dev/null | cut -f1)
        smoketest_pass
        echo "      → Size: $size"
    else
        smoketest_skip "No updates performed yet"
    fi
}

# =============================================================================
# MAIN SMOKE TEST FUNCTION
# =============================================================================

nftban_smoketest_run() {
    local mode="${1:-full}"  # full, quick, category
    local category="${2:-}"

    smoketest_reset_counters

    # Initialize log
    mkdir -p "$(dirname "$SMOKETEST_LOG")"
    echo "=== Smoke Test Started: $(date) ===" >> "$SMOKETEST_LOG"

    echo ""
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║      nftban Smoke Test & Diagnostics                  ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo ""
    echo "Mode: $mode"
    echo "Log:  $SMOKETEST_LOG"
    echo ""

    case "$mode" in
        quick)
            # Quick test - essential checks only
            smoketest_installation
            smoketest_nftables_structure
            smoketest_cli_commands
            smoketest_safety_mechanisms
            ;;

        full)
            # Full comprehensive test
            smoketest_installation
            smoketest_nftables_structure
            smoketest_core_modules
            smoketest_feature_modules
            smoketest_dependencies
            smoketest_cli_commands
            smoketest_safety_mechanisms
            smoketest_configuration
            smoketest_logging
            smoketest_connectivity
            smoketest_installer_mechanisms
            ;;

        category)
            # Test specific category
            case "$category" in
                installation) smoketest_installation ;;
                nftables) smoketest_nftables_structure ;;
                modules) smoketest_core_modules; smoketest_feature_modules ;;
                deps) smoketest_dependencies ;;
                cli) smoketest_cli_commands ;;
                safety) smoketest_safety_mechanisms ;;
                config) smoketest_configuration ;;
                logging) smoketest_logging ;;
                network) smoketest_connectivity ;;
                installer|update) smoketest_installer_mechanisms ;;
                *)
                    echo "Unknown category: $category"
                    echo "Available categories: installation, nftables, modules, deps, cli, safety, config, logging, network, installer"
                    return 1
                    ;;
            esac
            ;;

        *)
            echo "Unknown mode: $mode"
            echo "Available modes: quick, full, category"
            return 1
            ;;
    esac

    # Show summary
    smoketest_summary
    local exit_code=$?

    echo "=== Smoke Test Completed: $(date) ===" >> "$SMOKETEST_LOG"

    return $exit_code
}

# =============================================================================
# DIAGNOSTICS FUNCTION
# =============================================================================

nftban_diagnostics_collect() {
    local output_file="${1:-/tmp/nftban_diagnostics_$(date +%Y%m%d_%H%M%S).txt}"

    echo "Collecting diagnostics..."
    echo ""

    {
        echo "╔═══════════════════════════════════════════════════════╗"
        echo "║      nftban Diagnostics Report                         ║"
        echo "╚═══════════════════════════════════════════════════════╝"
        echo ""
        echo "Generated: $(date)"
        echo "Hostname: $(hostname)"
        echo "User: $(whoami)"
        echo ""

        echo "═══════════════════════════════════════════════════════"
        echo "  VERSION INFORMATION"
        echo "═══════════════════════════════════════════════════════"
        if [[ -f "$NFTBAN_BASE_DIR/.version" ]]; then
            echo "nftban version: $(cat "$NFTBAN_BASE_DIR/.version")"
        fi
        echo "Kernel: $(uname -r)"
        echo "OS: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2 || echo "Unknown")"
        nft --version 2>/dev/null || echo "nftables: not found"
        echo ""

        echo "═══════════════════════════════════════════════════════"
        echo "  NFTABLES RULESET"
        echo "═══════════════════════════════════════════════════════"
        nft list ruleset 2>/dev/null || echo "Cannot list ruleset"
        echo ""

        echo "═══════════════════════════════════════════════════════"
        echo "  NFTABLES SETS (IPv4)"
        echo "═══════════════════════════════════════════════════════"
        if nft list table ip nftban_v4 &>/dev/null; then
            for set in whitelist temp_ban user_blacklist system_blacklist feeds; do
                echo "--- Set: $set ---"
                nft list set ip nftban_v4 "$set" 2>/dev/null | grep -A 999 "elements" || echo "(empty set)"
                echo ""
            done
        else
            echo "Split tables not found - checking old inet table..."
            nft list table ip nftban_v4 2>/dev/null || nft list table ip6 nftban_v6 2>/dev/null || nft list table inet nftban_global 2>/dev/null || echo "No tables found"
        fi
        echo ""

        echo "═══════════════════════════════════════════════════════"
        echo "  CONFIGURATION FILES"
        echo "═══════════════════════════════════════════════════════"
        ls -lh "$NFTBAN_CONFIG_DIR" 2>/dev/null || echo "Config dir not found"
        echo ""

        echo "═══════════════════════════════════════════════════════"
        echo "  RECENT LOGS (last 50 lines)"
        echo "═══════════════════════════════════════════════════════"
        if [[ -f "/var/log/nftban/nftban_operations.log" ]]; then
            tail -50 /var/log/nftban/nftban_operations.log
        else
            echo "No operations log found"
        fi
        echo ""

        echo "═══════════════════════════════════════════════════════"
        echo "  FAIL2BAN STATUS"
        echo "═══════════════════════════════════════════════════════"
        if command -v fail2ban-client &>/dev/null; then
            fail2ban-client status 2>/dev/null || echo "Fail2Ban not running"
        else
            echo "Fail2Ban not installed"
        fi
        echo ""

        echo "═══════════════════════════════════════════════════════"
        echo "  SYSTEM STATUS"
        echo "═══════════════════════════════════════════════════════"
        echo "nftables service:"
        systemctl status nftables 2>/dev/null || echo "Service status unknown"
        echo ""
        echo "Fail2Ban service:"
        systemctl status fail2ban 2>/dev/null || echo "Service not installed"
        echo ""

        echo "═══════════════════════════════════════════════════════"
        echo "  DISK USAGE"
        echo "═══════════════════════════════════════════════════════"
        du -sh /etc/nftban 2>/dev/null || echo "Installation not found"
        du -sh /var/log/nftban 2>/dev/null || echo "Logs not found"
        du -sh /var/backups/nftban 2>/dev/null || echo "Backups not found"
        echo ""

    } > "$output_file"

    echo "Diagnostics saved to: $output_file"
    echo ""
    echo "You can share this file for support at: https://github.com/itcmsgr/nftban/issues"
}

# =============================================================================
# CLI INTERFACE FUNCTIONS
# =============================================================================

nftban_smoketest_show_help() {
    cat <<'EOF'

nftban test - Built-in smoke testing and diagnostics

USAGE:
    nftban test <command> [options]

COMMANDS:
    quick                   Run quick smoke test (essential checks only)
    full                    Run comprehensive smoke test (all categories)
    category <name>         Test specific category only

    diagnostics             Collect full diagnostics report
    help                    Show this help message

CATEGORIES:
    installation            Installation directory structure
    nftables                nftables table and set structure
    modules                 Core and feature modules
    deps                    System dependencies
    cli                     CLI command functionality
    safety                  Safety mechanisms and lockout prevention
    config                  Configuration files
    logging                 Log files and directories
    network                 Network connectivity
    installer               Installer/uninstaller/update mechanisms

EXAMPLES:
    nftban test quick                      # Quick health check
    nftban test full                       # Comprehensive test
    nftban test category nftables          # Test only nftables structure
    nftban test diagnostics                # Generate support bundle

LOGS:
    /var/log/nftban/smoketest.log         # Smoke test results
    /var/log/nftban/diagnostics.log       # Diagnostics log

EOF
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================

export -f nftban_smoketest_run
export -f nftban_diagnostics_collect
export -f nftban_smoketest_show_help

# Module-specific exports
export -f smoketest_installation
export -f smoketest_nftables_structure
export -f smoketest_core_modules
export -f smoketest_feature_modules
export -f smoketest_dependencies
export -f smoketest_cli_commands
export -f smoketest_safety_mechanisms
export -f smoketest_configuration
export -f smoketest_logging
export -f smoketest_connectivity
export -f smoketest_installer_mechanisms

nftban_log_debug "Smoke Test & Diagnostics Module loaded (v1.0.0)"
