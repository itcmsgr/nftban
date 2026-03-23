#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Installation Wizard
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Interactive wizard for NFTBan configuration
#
# meta:name="cmd_wizard"
# meta:type="cli"
# meta:header="NFTBan Installation Wizard"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Interactive wizard that detects environment and configures NFTBan"
# meta:inventory.files=""
# meta:inventory.binaries="nproc,awk,ss"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2025-12-05"
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${NFTBAN_CMD_WIZARD_LOADED:-}" ]] && return 0
NFTBAN_CMD_WIZARD_LOADED="true"

# Load required modules
[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" 2>/dev/null || true

# =============================================================================
# CONFIGURATION
# =============================================================================

readonly NFTBAN_CONFIG_LOCAL="${NFTBAN_CONFIG_LOCAL:-/etc/nftban/nftban.conf.local}"
readonly NFTBAN_PROFILE_CURRENT="${NFTBAN_PROFILE_CURRENT:-/var/lib/nftban/profile.current}"

# =============================================================================
# ENVIRONMENT DETECTION
# =============================================================================

_wizard_detect_env() {
    # CPU cores
    CPU_CORES=$(nproc 2>/dev/null || echo 1)

    # RAM in MB
    TOTAL_RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 512)

    # Disk free in GB
    DISK_FREE_GB=$(df -Pm / 2>/dev/null | awk 'NR==2 {print int($4/1024)}' || echo 10)

    # Classify environment size
    if [[ "$TOTAL_RAM_MB" -le 1024 ]] || [[ "$CPU_CORES" -le 1 ]]; then
        PROFILE_ENV="small"
    elif [[ "$TOTAL_RAM_MB" -le 8192 ]]; then
        PROFILE_ENV="medium"
    else
        PROFILE_ENV="large"
    fi

    # Detect open ports and roles
    ROLE_SSH=0
    ROLE_WEB=0
    ROLE_MAIL=0
    ROLE_DB=0

    local open_ports
    open_ports=$(ss -lnt 2>/dev/null | awk 'NR>1 {print $4}' | sed 's/.*://' | sort -u)

    echo "$open_ports" | grep -qE '^22$' && ROLE_SSH=1
    echo "$open_ports" | grep -qE '^(80|443)$' && ROLE_WEB=1
    echo "$open_ports" | grep -qE '^(25|465|587|993|995)$' && ROLE_MAIL=1
    echo "$open_ports" | grep -qE '^(3306|5432|27017|6379)$' && ROLE_DB=1

    # Build detected ports strings
    SSH_PORTS="22"
    WEB_TCP_PORTS=""
    MAIL_TCP_PORTS=""
    DB_TCP_PORTS=""

    [[ "$ROLE_WEB" -eq 1 ]] && WEB_TCP_PORTS="80,443"
    [[ "$ROLE_MAIL" -eq 1 ]] && MAIL_TCP_PORTS="25,465,587,993,995"
    [[ "$ROLE_DB" -eq 1 ]] && DB_TCP_PORTS="3306,5432"
}

_wizard_show_env() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Environment Detection"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Hardware:"
    echo "    CPU cores:    $CPU_CORES"
    echo "    RAM:          ${TOTAL_RAM_MB} MB"
    echo "    Disk free:    ${DISK_FREE_GB} GB"
    echo "    Environment:  ${PROFILE_ENV^^}"
    echo ""
    echo "  Detected Services:"
    [[ "$ROLE_SSH" -eq 1 ]] && echo "    ✓ SSH (port 22)"
    [[ "$ROLE_WEB" -eq 1 ]] && echo "    ✓ Web (ports 80, 443)"
    [[ "$ROLE_MAIL" -eq 1 ]] && echo "    ✓ Mail (ports 25, 465, 587, 993, 995)"
    [[ "$ROLE_DB" -eq 1 ]] && echo "    ✓ Database (ports 3306, 5432)"
    [[ "$ROLE_SSH" -eq 0 && "$ROLE_WEB" -eq 0 && "$ROLE_MAIL" -eq 0 && "$ROLE_DB" -eq 0 ]] && echo "    (no common services detected)"
    echo ""
}

# =============================================================================
# WIZARD QUESTIONS (Only 3!)
# =============================================================================

_wizard_ask_questions() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Configuration Questions"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Question 1: Security Level
    echo "  1) Security Level:"
    echo ""
    echo "     1. Standard   - Good balance, low false positives"
    echo "     2. Strict     - Stronger blocking, some false positives possible"
    echo "     3. Paranoid   - Maximum protection, may block legit traffic"
    echo ""
    read -rp "     Select [1-3, default=1]: " SEC_CHOICE
    case "$SEC_CHOICE" in
        2) PROFILE_SECURITY_LEVEL="strict" ;;
        3) PROFILE_SECURITY_LEVEL="paranoid" ;;
        *) PROFILE_SECURITY_LEVEL="standard" ;;
    esac
    echo ""

    # Question 2: Traffic Level
    echo "  2) Expected Traffic Level:"
    echo ""
    echo "     1. Low      - Development, small site, internal"
    echo "     2. Medium   - Normal production"
    echo "     3. High     - Heavy traffic, possible DDoS target"
    echo ""
    read -rp "     Select [1-3, default=2]: " TRAF_CHOICE
    case "$TRAF_CHOICE" in
        1) PROFILE_TRAFFIC_LEVEL="low" ;;
        3) PROFILE_TRAFFIC_LEVEL="high" ;;
        *) PROFILE_TRAFFIC_LEVEL="medium" ;;
    esac
    echo ""

    # Question 3: Optional Features
    echo "  3) Optional Features:"
    echo ""

    # Feeds - suggest based on role
    local feeds_suggest=""
    [[ "$ROLE_SSH" -eq 1 ]] && feeds_suggest="BLOCKLIST_DE_SSH"
    [[ "$ROLE_WEB" -eq 1 ]] && feeds_suggest="${feeds_suggest:+$feeds_suggest, }SPAMHAUS_DROP"
    [[ -n "$feeds_suggest" ]] && echo "     (Suggested feeds for your services: $feeds_suggest)"

    read -rp "     Enable threat intelligence feeds? [y/N]: " FEEDS_CHOICE
    [[ "${FEEDS_CHOICE,,}" == "y" ]] && WANT_FEEDS=1 || WANT_FEEDS=0

    # IDS - only ask if not small environment
    WANT_IDS=0
    if [[ "$PROFILE_ENV" != "small" ]]; then
        read -rp "     Enable IDS integration (Suricata) if available? [y/N]: " IDS_CHOICE
        [[ "${IDS_CHOICE,,}" == "y" ]] && WANT_IDS=1
    else
        echo "     IDS integration: Skipped (not recommended for small environments)"
    fi

    # GUI/Metrics - only ask if not small environment
    WANT_GUI=0
    WANT_METRICS=0
    if [[ "$PROFILE_ENV" != "small" ]]; then
        read -rp "     Enable web GUI & metrics? [y/N]: " GUI_CHOICE
        if [[ "${GUI_CHOICE,,}" == "y" ]]; then
            WANT_GUI=1
            # shellcheck disable=SC2034  # Reserved for metrics setup
            WANT_METRICS=1
        fi
    else
        echo "     GUI & metrics: Skipped (not recommended for small environments)"
    fi

    echo ""
}

# =============================================================================
# COMPUTE CONFIGURATION
# =============================================================================

_wizard_compute_config() {
    # Login monitor - ALWAYS enabled
    ENABLE_LOGIN_MONITOR=1

    # SSH protect level based on security level
    case "$PROFILE_SECURITY_LEVEL" in
        strict)   SSH_PROTECT_LEVEL=1 ;;
        paranoid) SSH_PROTECT_LEVEL=2 ;;
        *)        SSH_PROTECT_LEVEL=0 ;;
    esac

    # DDoS - enable if traffic is not low
    ENABLE_DDOS=0
    if [[ "$PROFILE_TRAFFIC_LEVEL" != "low" ]]; then
        ENABLE_DDOS=1
    fi

    # Portscan - enable if security is not standard
    ENABLE_PORTSCAN=0
    if [[ "$PROFILE_SECURITY_LEVEL" != "standard" ]]; then
        ENABLE_PORTSCAN=1
    fi

    # High traffic or paranoid = enable both
    if [[ "$PROFILE_TRAFFIC_LEVEL" == "high" ]] || [[ "$PROFILE_SECURITY_LEVEL" == "paranoid" ]]; then
        ENABLE_DDOS=1
        ENABLE_PORTSCAN=1
    fi

    # Feeds - only if user wants AND not tiny env
    ENABLE_FEEDS=0
    if [[ "$WANT_FEEDS" -eq 1 ]]; then
        ENABLE_FEEDS=1
    fi

    # IDS - only if user wants AND not small
    ENABLE_IDS_INTEGRATION=0
    if [[ "$WANT_IDS" -eq 1 ]] && [[ "$PROFILE_ENV" != "small" ]]; then
        ENABLE_IDS_INTEGRATION=1
    fi

    # GUI/Metrics - only if user wants AND not small
    ENABLE_GUI=0
    ENABLE_METRICS=0
    if [[ "$WANT_GUI" -eq 1 ]] && [[ "$PROFILE_ENV" != "small" ]]; then
        ENABLE_GUI=1
        ENABLE_METRICS=1
    fi

    # Geoban - off by default
    ENABLE_GEOBAN=0

    # Compute DDoS tuning based on environment
    case "$PROFILE_ENV" in
        small)
            DDOS_SYNFLOOD_RATE="30/s"
            DDOS_SYNFLOOD_BURST=60
            DDOS_CONN_LIMIT_PER_IP=50
            ;;
        medium)
            DDOS_SYNFLOOD_RATE="50/s"
            DDOS_SYNFLOOD_BURST=100
            DDOS_CONN_LIMIT_PER_IP=100
            ;;
        large)
            DDOS_SYNFLOOD_RATE="100/s"
            DDOS_SYNFLOOD_BURST=200
            DDOS_CONN_LIMIT_PER_IP=200
            ;;
    esac

    # Compute portscan tuning based on security level
    case "$PROFILE_SECURITY_LEVEL" in
        standard)
            PORTSCAN_THRESHOLD=30
            PORTSCAN_WINDOW_SECONDS=60
            PORTSCAN_BAN_DURATION_SECONDS=$((24 * 3600))
            ;;
        strict)
            PORTSCAN_THRESHOLD=20
            PORTSCAN_WINDOW_SECONDS=60
            PORTSCAN_BAN_DURATION_SECONDS=$((3 * 24 * 3600))
            ;;
        paranoid)
            PORTSCAN_THRESHOLD=10
            PORTSCAN_WINDOW_SECONDS=60
            PORTSCAN_BAN_DURATION_SECONDS=$((7 * 24 * 3600))
            ;;
    esac

    # Login tuning
    case "$PROFILE_SECURITY_LEVEL" in
        standard)
            LOGIN_MAX_ATTEMPTS=6
            LOGIN_BAN_DURATION_SECONDS=$((1 * 3600))
            ;;
        strict)
            LOGIN_MAX_ATTEMPTS=5
            LOGIN_BAN_DURATION_SECONDS=$((12 * 3600))
            ;;
        paranoid)
            LOGIN_MAX_ATTEMPTS=3
            LOGIN_BAN_DURATION_SECONDS=$((24 * 3600))
            ;;
    esac
}

# =============================================================================
# SHOW SUMMARY
# =============================================================================

_wizard_show_summary() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Configuration Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Environment:     ${PROFILE_ENV^^} ($CPU_CORES cores, ${TOTAL_RAM_MB}MB RAM)"
    echo "  Security Level:  ${PROFILE_SECURITY_LEVEL^^}"
    echo "  Traffic Level:   ${PROFILE_TRAFFIC_LEVEL^^}"
    echo ""
    echo "  Modules to Enable:"
    echo "    SSH login monitor:     ✓ ENABLED (always on)"
    echo "    SSH brute-force level: $SSH_PROTECT_LEVEL"

    if [[ "$ENABLE_DDOS" -eq 1 ]]; then
        echo "    DDoS protection:       ✓ ENABLED"
    else
        echo "    DDoS protection:       ✗ disabled"
    fi

    if [[ "$ENABLE_PORTSCAN" -eq 1 ]]; then
        echo "    Portscan detection:    ✓ ENABLED"
    else
        echo "    Portscan detection:    ✗ disabled"
    fi

    if [[ "$ENABLE_FEEDS" -eq 1 ]]; then
        echo "    Threat feeds:          ✓ ENABLED"
    else
        echo "    Threat feeds:          ✗ disabled (enable later: nftban feeds enable)"
    fi

    if [[ "$ENABLE_IDS_INTEGRATION" -eq 1 ]]; then
        echo "    IDS integration:       ✓ ENABLED"
    else
        echo "    IDS integration:       ✗ disabled"
    fi

    if [[ "$ENABLE_GUI" -eq 1 ]]; then
        echo "    Web GUI:               ✓ ENABLED"
        echo "    Metrics exporter:      ✓ ENABLED"
    else
        echo "    Web GUI & Metrics:     ✗ disabled (enable later: nftban gui enable)"
    fi

    echo ""
}

# =============================================================================
# WRITE CONFIGURATION
# =============================================================================

_wizard_write_config() {
    mkdir -p /etc/nftban /var/lib/nftban || return 1

    cat > "$NFTBAN_CONFIG_LOCAL" << EOF
# =============================================================================
# NFTBan Configuration - Generated by Wizard
# =============================================================================
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# Environment: $PROFILE_ENV
# Security: $PROFILE_SECURITY_LEVEL
# Traffic: $PROFILE_TRAFFIC_LEVEL
# =============================================================================

# Environment Profile
PROFILE_ENV="$PROFILE_ENV"
PROFILE_SECURITY_LEVEL="$PROFILE_SECURITY_LEVEL"
PROFILE_TRAFFIC_LEVEL="$PROFILE_TRAFFIC_LEVEL"

# Module Enables
ENABLE_DDOS=$ENABLE_DDOS
ENABLE_PORTSCAN=$ENABLE_PORTSCAN
ENABLE_LOGIN_MONITOR=$ENABLE_LOGIN_MONITOR
ENABLE_FEEDS=$ENABLE_FEEDS
ENABLE_GEOBAN=$ENABLE_GEOBAN
ENABLE_IDS_INTEGRATION=$ENABLE_IDS_INTEGRATION
ENABLE_GUI=$ENABLE_GUI
ENABLE_METRICS=$ENABLE_METRICS

# SSH Protection
SSH_PROTECT_LEVEL=$SSH_PROTECT_LEVEL
SSH_PORTS="$SSH_PORTS"

# Detected Ports
WEB_TCP_PORTS="$WEB_TCP_PORTS"
MAIL_TCP_PORTS="$MAIL_TCP_PORTS"
DB_TCP_PORTS="$DB_TCP_PORTS"

# DDoS Tuning
DDOS_SYNFLOOD_RATE="$DDOS_SYNFLOOD_RATE"
DDOS_SYNFLOOD_BURST=$DDOS_SYNFLOOD_BURST
DDOS_CONN_LIMIT_PER_IP=$DDOS_CONN_LIMIT_PER_IP

# Portscan Tuning
PORTSCAN_THRESHOLD=$PORTSCAN_THRESHOLD
PORTSCAN_WINDOW_SECONDS=$PORTSCAN_WINDOW_SECONDS
PORTSCAN_AUTOBAN_ENABLED=1
PORTSCAN_BAN_DURATION_SECONDS=$PORTSCAN_BAN_DURATION_SECONDS

# Login Monitor Tuning
LOGIN_MAX_ATTEMPTS=$LOGIN_MAX_ATTEMPTS
LOGIN_BAN_DURATION_SECONDS=$LOGIN_BAN_DURATION_SECONDS

# Logging
LOG_VERBOSITY="info"
EOF

    # Record profile state
    echo "wizard:ENV=$PROFILE_ENV,SEC=$PROFILE_SECURITY_LEVEL,TRAFFIC=$PROFILE_TRAFFIC_LEVEL" > "$NFTBAN_PROFILE_CURRENT"
    echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')" >> "$NFTBAN_PROFILE_CURRENT"

    echo "  ✓ Configuration written to: $NFTBAN_CONFIG_LOCAL"
}

# =============================================================================
# ENABLE MODULES
# =============================================================================

_wizard_enable_modules() {
    echo ""
    echo "  Enabling modules..."

    # Login monitor - always
    if command -v nftban >/dev/null 2>&1; then
        echo "    → Enabling login monitor..."
        nftban login enable >/dev/null 2>&1 || echo "      (login monitor may need manual setup)"
    fi

    # DDoS
    if [[ "$ENABLE_DDOS" -eq 1 ]]; then
        echo "    → Enabling DDoS protection..."
        nftban ddos enable >/dev/null 2>&1 || echo "      (ddos may need manual setup)"
    fi

    # Portscan
    if [[ "$ENABLE_PORTSCAN" -eq 1 ]]; then
        echo "    → Enabling portscan detection..."
        nftban portscan enable >/dev/null 2>&1 || echo "      (portscan may need manual setup)"
    fi

    # Feeds
    if [[ "$ENABLE_FEEDS" -eq 1 ]]; then
        echo "    → Enabling threat feeds..."
        # Enable suggested feeds based on role
        if [[ "$ROLE_SSH" -eq 1 ]]; then
            nftban feeds enable BLOCKLIST_DE_SSH >/dev/null 2>&1 || true
        fi
        if [[ "$ROLE_WEB" -eq 1 ]]; then
            nftban feeds enable SPAMHAUS_DROP >/dev/null 2>&1 || true
        fi
    fi

    # GUI
    if [[ "$ENABLE_GUI" -eq 1 ]]; then
        echo "    → Enabling web GUI..."
        nftban gui enable >/dev/null 2>&1 || echo "      (GUI may need manual setup)"
    fi

    # Metrics
    if [[ "$ENABLE_METRICS" -eq 1 ]]; then
        echo "    → Enabling metrics exporter..."
        nftban metrics enable >/dev/null 2>&1 || echo "      (metrics may need manual setup)"
    fi

    echo ""
}

# =============================================================================
# MAIN WIZARD COMMAND
# =============================================================================

cmd_wizard_install() {
    # Check root
    if [[ "$EUID" -ne 0 ]]; then
        echo "ERROR: Wizard requires root privileges" >&2
        echo "Usage: sudo nftban wizard install"
        return 1
    fi

    # Show banner
    if type -t nftban_banner >/dev/null 2>&1; then
        nftban_banner
    fi

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║           NFTBan Installation Wizard v1.0                    ║"
    echo "╚══════════════════════════════════════════════════════════════╝"

    # Step 1: Detect environment
    echo ""
    echo "  Detecting environment..."
    _wizard_detect_env
    _wizard_show_env

    # Step 2: Ask questions
    _wizard_ask_questions

    # Step 3: Compute configuration
    _wizard_compute_config

    # Step 4: Show summary
    _wizard_show_summary

    # Step 5: Confirm and apply
    echo ""
    read -rp "  Apply this configuration? [Y/n]: " APPLY_CHOICE

    if [[ -z "$APPLY_CHOICE" ]] || [[ "${APPLY_CHOICE,,}" == "y" ]]; then
        echo ""
        echo "  Applying configuration..."
        _wizard_write_config
        _wizard_enable_modules

        echo "╔══════════════════════════════════════════════════════════════╗"
        echo "║  ✓ NFTBan Wizard Complete                                    ║"
        echo "╚══════════════════════════════════════════════════════════════╝"
        echo ""
        echo "  Next steps:"
        echo "    • Check status:    nftban status"
        echo "    • View health:     nftban health"
        echo "    • Enable feeds:    nftban feeds enable <FEED_NAME>"
        echo "    • View config:     cat $NFTBAN_CONFIG_LOCAL"
        echo ""
    else
        echo ""
        echo "  Wizard cancelled. No changes made."
        return 0
    fi
}

cmd_wizard_env() {
    # Just show environment detection
    _wizard_detect_env
    _wizard_show_env
}

# =============================================================================
# HELP
# =============================================================================

cmd_wizard_help() {
    cat << 'EOF'

NFTBan Installation Wizard

USAGE:
    nftban wizard <command>

COMMANDS:
    install     Run the interactive installation wizard
    env         Show detected environment only (no changes)
    help        Show this help message

DESCRIPTION:
    The wizard detects your environment (CPU, RAM, open ports) and asks
    3 simple questions to configure NFTBan optimally for your server.

    Questions asked:
    1. Security Level (standard/strict/paranoid)
    2. Traffic Level (low/medium/high)
    3. Optional Features (feeds, IDS, GUI)

    The wizard then:
    - Generates /etc/nftban/nftban.conf.local
    - Enables appropriate modules
    - Suggests feeds based on detected services

DEFAULTS:
    - SSH login monitor: ALWAYS enabled
    - Feeds: OFF (user must opt-in)
    - GUI/Metrics: OFF on small environments
    - IDS: OFF on small environments

EXAMPLES:
    sudo nftban wizard install    # Run full wizard
    nftban wizard env             # Just show environment

EOF
}

# =============================================================================
# COMMAND ROUTER
# =============================================================================

nftban_cmd_wizard() {
    local action="${1:-help}"
    shift || true

    case "$action" in
        install)
            cmd_wizard_install "$@"
            ;;
        env|environment)
            cmd_wizard_env "$@"
            ;;
        help|--help|-h)
            cmd_wizard_help
            ;;
        *)
            echo "ERROR: Unknown wizard command: $action" >&2
            echo "Run 'nftban wizard help' for usage"
            return 1
            ;;
    esac
}

# Export for main CLI
export -f nftban_cmd_wizard

# Execute if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_wizard "$@"
fi
