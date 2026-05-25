#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0 - Suricata IDS CLI Command (Loader)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Easy user interface for Suricata IDS management
#
# meta:name="cmd_suricata"
# meta:type="cli"
# meta:header="Suricata IDS Management"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="User-friendly CLI for Suricata IDS installation and management"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# meta:created_date="2025-12-28"
#
# =============================================================================
# MODULE LOADER
# =============================================================================
# Suricata CLI functions are split into separate files for maintainability:
#
# cmd_suricata_setup.sh     - Install, Enable, Disable, Status commands
# cmd_suricata_rules.sh     - Rules, SID, Category commands
# cmd_suricata_advanced.sh  - Local, Custom, Recommend commands
# cmd_suricata_tools.sh     - Profile, Scan, Services, EVE commands
# cmd_suricata_iface.sh     - Interface detection and configuration (v1.12.0)
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${NFTBAN_CMD_SURICATA_LOADED:-}" ]] && return 0
NFTBAN_CMD_SURICATA_LOADED="true"

# =============================================================================
# CONFIGURATION
# =============================================================================

: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"
: "${NFTBAN_CONFIG_DIR:=/etc/nftban}"

# Load distro config FIRST (provides DISTRO_PATHS for all paths)
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_distro_config.sh" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR}/lib/nftban_distro_config.sh" || return 1
fi

# Load output library
if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
fi

# Load Suricata rules helper
if [[ -f "${NFTBAN_LIB_DIR}/helpers/suricata_rules.sh" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR}/helpers/suricata_rules.sh" || return 1
fi

# Suricata paths (exported for submodules)
export SURICATA_SETUP_SCRIPT="${NFTBAN_LIB_DIR}/setup/install_suricata.sh"
export SURICATA_RULES_SCRIPT="${NFTBAN_LIB_DIR}/setup/setup_suricata_rules.sh"
export SURICATA_SERVICE="suricata.service"

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

_suricata_is_installed() {
    command -v suricata &>/dev/null
}

_suricata_is_running() {
    systemctl is-active --quiet "$SURICATA_SERVICE" 2>/dev/null
}

_suricata_is_enabled() {
    systemctl is-enabled --quiet "$SURICATA_SERVICE" 2>/dev/null
}

# Use shared _suricata_check_access from suricata_rules.sh helper
# Checks nftban group membership (polkit handles systemd operations)
_check_root() {
    local operation="${1:-this operation}"

    # Use shared helper if available
    if declare -f _suricata_check_access &>/dev/null; then
        _suricata_check_access "$operation"
        return $?
    fi

    # Fallback: check nftban group membership
    if id -nG 2>/dev/null | grep -qw "nftban"; then
        return 0
    fi

    # Root always has access
    if [[ $EUID -eq 0 ]]; then
        return 0
    fi

    echo "ERROR: nftban group membership required for $operation" >&2
    echo "Add user to nftban group: sudo usermod -a -G nftban \$USER" >&2
    return 1
}

# =============================================================================
# MODULE LOADER
# =============================================================================

# Get the directory where this script is located
_cmd_suricata_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_cmd_suricata_modules=(
    "cmd_suricata_setup.sh"
    "cmd_suricata_rules.sh"
    "cmd_suricata_advanced.sh"
    "cmd_suricata_tools.sh"
    "cmd_suricata_iface.sh"
)

for _module in "${_cmd_suricata_modules[@]}"; do
    _module_path="${_cmd_suricata_dir}/${_module}"
    if [[ -f "$_module_path" ]]; then
        # shellcheck source=/dev/null
        source "$_module_path" || {
            echo "ERROR: Failed to load suricata module: $_module" >&2
            return 1
        }
    else
        echo "ERROR: Suricata module not found: $_module_path" >&2
        return 1
    fi
done

# Cleanup temporary variables
unset _cmd_suricata_modules _module _module_path _cmd_suricata_dir

# =============================================================================
# STATS AND TEST COMMANDS
# =============================================================================

cmd_suricata_stats() {
    # Show Suricata statistics for monitoring/API
    local json_mode="false"
    for arg in "$@"; do
        [[ "$arg" == "--json" ]] && json_mode="true" || true
    done

    local installed="false"
    local running="false"
    local enabled="false"
    local version=""
    local alert_count=0
    local eve_size=0

    # Check installation
    if _suricata_is_installed; then
        installed="true"
        version=$(suricata --build-info 2>/dev/null | grep -oP 'Suricata version \K[0-9.]+' | head -1) || version=""
    fi

    # Check service status
    _suricata_is_running && running="true"
    _suricata_is_enabled && enabled="true"

    # Get EVE log stats
    local eve_path
    eve_path=$(_eve_get_path 2>/dev/null) || eve_path=""
    if [[ -n "$eve_path" ]] && [[ -f "$eve_path" ]]; then
        eve_size=$(stat -c%s "$eve_path" 2>/dev/null || stat -f%z "$eve_path" 2>/dev/null || echo "0")
        # Count alerts in last 24h (approximate from last 100 lines)
        alert_count=$(tail -1000 "$eve_path" 2>/dev/null | grep -c '"event_type":"alert"' || true)
        alert_count=${alert_count:-0}
    fi

    if [[ "$json_mode" == "true" ]]; then
        cat <<EOF
{"installed":$installed,"running":$running,"enabled":$enabled,"version":"$version","alerts_recent":$alert_count,"eve_size_bytes":$eve_size}
EOF
        return 0
    fi

    echo "Suricata Statistics"
    echo "==================="
    echo ""
    echo "  Installed:      $installed"
    echo "  Version:        ${version:-(unknown)}"
    echo "  Running:        $running"
    echo "  Enabled:        $enabled"
    echo "  Recent Alerts:  $alert_count (from last 1000 EVE entries)"
    echo "  EVE Log Size:   $(_eve_format_bytes "$eve_size")"
    echo ""
}

cmd_suricata_config() {
    # Show Suricata configuration settings
    local json_mode="false"
    for arg in "$@"; do
        [[ "$arg" == "--json" ]] && json_mode="true" || true
    done

    # Configuration values
    local suricata_yaml=""
    local eve_path=""
    local interface=""
    local rules_dir=""
    local log_dir=""
    local run_mode=""
    local home_net=""
    local external_net=""

    # Find Suricata config file
    local suricata_config_dirs=("/etc/suricata" "/usr/local/etc/suricata" "/opt/suricata/etc")
    for dir in "${suricata_config_dirs[@]}"; do
        if [[ -f "$dir/suricata.yaml" ]]; then
            suricata_yaml="$dir/suricata.yaml"
            break
        fi
    done

    # Get EVE log path from nftban config or suricata
    eve_path=$(_eve_get_path 2>/dev/null) || eve_path=""

    # Parse suricata.yaml if found
    if [[ -n "$suricata_yaml" ]] && [[ -f "$suricata_yaml" ]]; then
        # Get interface (af-packet interface)
        interface=$(grep -A10 "^af-packet:" "$suricata_yaml" 2>/dev/null | grep -E "^\s+-\s+interface:" | head -1 | sed 's/.*interface:\s*//' | tr -d ' "' || true)

        # Get default log directory
        log_dir=$(grep -E "^\s*default-log-dir:" "$suricata_yaml" 2>/dev/null | head -1 | sed 's/.*default-log-dir:\s*//' | tr -d ' "' || true)

        # Get rules directory (rule-files or default-rule-path)
        rules_dir=$(grep -E "^\s*default-rule-path:" "$suricata_yaml" 2>/dev/null | head -1 | sed 's/.*default-rule-path:\s*//' | tr -d ' "' || true)
        [[ -z "$rules_dir" ]] && rules_dir="/var/lib/suricata/rules"

        # Get run mode
        run_mode=$(grep -E "^runmode:" "$suricata_yaml" 2>/dev/null | head -1 | sed 's/runmode:\s*//' | tr -d ' "' || true)

        # Get HOME_NET
        home_net=$(grep -E "^\s*HOME_NET:" "$suricata_yaml" 2>/dev/null | head -1 | sed 's/.*HOME_NET:\s*//' | tr -d '"' | xargs || true)

        # Get EXTERNAL_NET
        external_net=$(grep -E "^\s*EXTERNAL_NET:" "$suricata_yaml" 2>/dev/null | head -1 | sed 's/.*EXTERNAL_NET:\s*//' | tr -d '"' | xargs || true)
    fi

    # Fallbacks for missing values
    [[ -z "$log_dir" ]] && log_dir="/var/log/suricata"
    [[ -z "$run_mode" ]] && run_mode="autofp"
    [[ -z "$home_net" ]] && home_net="(not configured)"
    [[ -z "$external_net" ]] && external_net="(not configured)"
    [[ -z "$interface" ]] && interface="(not configured)"
    [[ -z "$eve_path" ]] && eve_path="(not configured)"
    [[ -z "$suricata_yaml" ]] && suricata_yaml="(not found)"

    # Get nftban-specific config
    local nftban_suricata_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/suricata.conf"
    local nftban_iface_conf
    nftban_iface_conf=$(_suricata_iface_get_config_path 2>/dev/null) || nftban_iface_conf=""

    # Count rule files
    local rule_count=0
    if [[ -d "$rules_dir" ]]; then
        rule_count=$(find "$rules_dir" -name "*.rules" 2>/dev/null | wc -l)
    fi

    if [[ "$json_mode" == "true" ]]; then
        # v1.25: Use shared json_escape() from json_output.sh (dedup)
        if ! declare -f json_escape &>/dev/null; then
            source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/helpers/json_output.sh" 2>/dev/null || true
        fi
        cat <<EOF
{"suricata_yaml":"$(json_escape "$suricata_yaml")","eve_path":"$(json_escape "$eve_path")","interface":"$(json_escape "$interface")","rules_dir":"$(json_escape "$rules_dir")","rule_count":$rule_count,"log_dir":"$(json_escape "$log_dir")","run_mode":"$(json_escape "$run_mode")","home_net":"$(json_escape "$home_net")","external_net":"$(json_escape "$external_net")","nftban_suricata_conf":"$(json_escape "$nftban_suricata_conf")","nftban_iface_conf":"$(json_escape "${nftban_iface_conf:-}")"}
EOF
        return 0
    fi

    echo "Suricata Configuration"
    echo "======================"
    echo ""
    echo "  Main Config:    $suricata_yaml"
    echo "  Run Mode:       $run_mode"
    echo "  Interface:      $interface"
    echo ""
    echo "  Logging:"
    echo "    Log Dir:      $log_dir"
    echo "    EVE Path:     $eve_path"
    echo ""
    echo "  Rules:"
    echo "    Rules Dir:    $rules_dir"
    echo "    Rule Files:   $rule_count"
    echo ""
    echo "  Network Variables:"
    echo "    HOME_NET:     $home_net"
    echo "    EXTERNAL_NET: $external_net"
    echo ""
    echo "  NFTBan Config:"
    echo "    Suricata:     $nftban_suricata_conf"
    if [[ -n "$nftban_iface_conf" ]]; then
        echo "    Interface:    $nftban_iface_conf"
    fi
    echo ""
}

cmd_suricata_test() {
    # Test Suricata module configuration
    echo "Suricata Module Test"
    echo "===================="
    echo ""

    local errors=0

    # Test 1: Check Suricata installation
    if _suricata_is_installed; then
        local version
        version=$(suricata --build-info 2>/dev/null | grep -oP 'Suricata version \K[0-9.]+' | head -1) || version="unknown"
        echo "  [PASS] Suricata installed (version: $version)"
    else
        echo "  [FAIL] Suricata not installed"
        ((errors++)) || true
    fi

    # Test 2: Check service file
    if systemctl list-unit-files "$SURICATA_SERVICE" &>/dev/null 2>&1; then
        echo "  [PASS] Systemd service exists"
    else
        echo "  [FAIL] Systemd service not found: $SURICATA_SERVICE"
        ((errors++)) || true
    fi

    # Test 3: Check EVE log path
    local eve_path
    eve_path=$(_eve_get_path 2>/dev/null) || eve_path=""
    if [[ -n "$eve_path" ]]; then
        if [[ -f "$eve_path" ]]; then
            echo "  [PASS] EVE log exists: $eve_path"
        else
            echo "  [INFO] EVE log path configured but file not yet created"
        fi
    else
        echo "  [WARN] EVE log path not configured"
    fi

    # Test 4: Check rules directory
    local rules_dir="/var/lib/suricata/rules"
    if [[ -d "$rules_dir" ]]; then
        local rule_count
        rule_count=$(find "$rules_dir" -name "*.rules" 2>/dev/null | wc -l)
        echo "  [PASS] Rules directory exists ($rule_count rule files)"
    else
        echo "  [WARN] Rules directory not found: $rules_dir"
    fi

    # Test 5: Check suricata-update
    if command -v suricata-update &>/dev/null; then
        echo "  [PASS] suricata-update available"
    else
        echo "  [WARN] suricata-update not found (rule updates may fail)"
    fi

    echo ""
    if [[ $errors -eq 0 ]]; then
        echo "All tests passed!"
        return 0
    else
        echo "Tests completed with $errors error(s)"
        return 1
    fi
}

# =============================================================================
# HELP
# =============================================================================

cmd_suricata_help() {
    cat << 'EOF'

🛡️  NFTBan Suricata IDS Management
    Open-source Linux IPS and nftables firewall manager

USAGE:
    nftban suricata <command>

COMMANDS:
    install     Install Suricata IDS (automated)
    enable      Enable and start Suricata service
    disable     Stop and disable Suricata service
    status      Show Suricata status and recent alerts
    config      Show Suricata configuration settings (--json for JSON output)
    iface       Interface detection & configuration (see: nftban suricata iface help)
    eve         EVE JSON log health check (see: nftban suricata eve help)
    profile     Manage performance profiles (see: nftban suricata profile help)
    scan        Scan services and auto-configure (see: nftban suricata scan help)
    services    Manage service configuration (see: nftban suricata services help)
    rules       Manage Suricata rules (see: nftban suricata rules help)
    category    Manage rule categories (see: nftban suricata category help)
    sid         SID enable/disable and stats (see: nftban suricata sid help)
    local       Manage local user rules (see: nftban suricata local help)
    custom      Manage nftban auto-rules (see: nftban suricata custom help)
    recommend   Get data-driven rule recommendations (see: nftban suricata recommend help)
    help        Show this help message

QUICK START:
    # Install and enable Suricata
    nftban suricata install
    nftban suricata enable

    # Check health
    nftban suricata status
    nftban suricata eve check

RULE MANAGEMENT:
    # View ruleset status
    nftban suricata rules status

    # Enable/disable rule categories
    nftban suricata category list
    nftban suricata category disable emerging-policy

    # Enable/disable specific SIDs
    nftban suricata sid disable 2100498
    nftban suricata sid enable 2024792

    # Add local rules
    nftban suricata local add '<rule>'

    # Apply all changes
    nftban suricata rules apply

EXAMPLES:
    # Update rules
    nftban suricata rules update

    # View top triggered SIDs
    nftban suricata sid top

    # Rollback rule changes
    nftban suricata rules rollback 20260202-120000

    # View live alerts
    tail -f ${NFTBAN_LOG_DIR}/suricata/eve-alerts.json | jq 'select(.event_type=="alert")'

REQUIREMENTS:
    - Elevated privileges (members of the nftban group are authorized via PolicyKit/polkit rules)
    - EPEL repository (RHEL/Rocky) or standard repos (Debian/Ubuntu)
    - 2+ cores, 2+ GB RAM recommended
    - Python 3 + pip (for suricata-update)

DOCUMENTATION:
    - Suricata: https://suricata.io/
    - NFTBan Suricata guide: https://github.com/itcmsgr/nftban/wiki/Suricata-Integration

EOF
}

# =============================================================================
# COMMAND ROUTER
# =============================================================================

nftban_cmd_suricata() {
    local action="${1:-help}"
    shift || true

    case "$action" in
        install)
            cmd_suricata_install "$@"
            ;;
        enable)
            cmd_suricata_enable "$@"
            ;;
        disable)
            cmd_suricata_disable "$@"
            ;;
        status)
            cmd_suricata_status "$@"
            ;;
        stats)
            cmd_suricata_stats "$@"
            ;;
        config)
            cmd_suricata_config "$@"
            ;;
        test)
            cmd_suricata_test "$@"
            ;;
        eve)
            cmd_suricata_eve "$@"
            ;;
        rules)
            cmd_suricata_rules "$@"
            ;;
        profile)
            cmd_suricata_profile "$@"
            ;;
        scan)
            cmd_suricata_scan "$@"
            ;;
        services)
            cmd_suricata_services "$@"
            ;;
        sid)
            cmd_suricata_sid "$@"
            ;;
        category)
            cmd_suricata_category "$@"
            ;;
        local)
            cmd_suricata_local "$@"
            ;;
        custom)
            cmd_suricata_custom "$@"
            ;;
        recommend)
            cmd_suricata_recommend "$@"
            ;;
        iface|interface)
            cmd_suricata_iface "$@"
            ;;
        help|--help|-h)
            cmd_suricata_help
            ;;
        *)
            echo "ERROR: Unknown command: $action" >&2
            echo "Run 'nftban suricata help' for usage"
            return 1
            ;;
    esac
}

# =============================================================================
# EXPORTS
# =============================================================================

# Export main command router
export -f nftban_cmd_suricata

# Export sub-commands for external access (loaded from modules)
export -f cmd_suricata_install
export -f cmd_suricata_enable
export -f cmd_suricata_disable
export -f cmd_suricata_status
export -f cmd_suricata_stats
export -f cmd_suricata_config
export -f cmd_suricata_test
export -f cmd_suricata_eve
export -f cmd_suricata_eve_check
export -f cmd_suricata_rules
export -f cmd_suricata_profile
export -f cmd_suricata_scan
export -f cmd_suricata_services
export -f cmd_suricata_sid
export -f cmd_suricata_category
export -f cmd_suricata_local
export -f cmd_suricata_custom
export -f cmd_suricata_recommend
export -f cmd_suricata_iface
export -f cmd_suricata_help

# Export helper functions
export -f _suricata_is_installed
export -f _suricata_is_running
export -f _suricata_is_enabled
export -f _check_root
export -f _eve_get_path
export -f _eve_format_bytes
export -f _eve_format_age

# Execute if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_suricata "$@"
fi
