#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.32.0 - Profile CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Interactive security profile selection and management
#
# meta:name=cmd_profile
# meta:type=cli
# meta:header=Profile CLI
# meta:version=0.32.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=CLI handler for security profile selection
# meta:input=Command line arguments (select, apply, show, list, help)
# meta:output=Profile selection and application
#
# **Inventory & Requirements**
# meta:depends=bash
#
# meta:created_date=2025-11-05
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

readonly NFTBAN_PROFILES_DIR="${NFTBAN_PROFILES_DIR:-/usr/share/nftban/profiles}"
readonly NFTBAN_PROFILE_CURRENT="${NFTBAN_PROFILE_CURRENT:-/var/lib/nftban/profile.current}"
readonly NFTBAN_CONFIG_LOCAL="${NFTBAN_CONFIG_LOCAL:-/etc/nftban/nftban.conf.local}"

# =============================================================================
# BANNER
# =============================================================================

_nftban_profile_banner() {
    # Load output module for standard banner
    source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"

    # Show standard banner
    nftban_banner
}

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Get current profile name
_nftban_profile_get_current() {
    if [[ -f "$NFTBAN_PROFILE_CURRENT" ]]; then
        cat "$NFTBAN_PROFILE_CURRENT"
    else
        echo "none"
    fi
}

# List available profiles
_nftban_profile_list_available() {
    if [[ ! -d "$NFTBAN_PROFILES_DIR" ]]; then
        echo ""
        return 1
    fi

    local profiles=()
    for profile_file in "$NFTBAN_PROFILES_DIR"/*.conf; do
        if [[ -f "$profile_file" ]]; then
            local profile_name
            profile_name=$(basename "$profile_file" .conf)
            profiles+=("$profile_name")
        fi
    done

    printf '%s\n' "${profiles[@]}"
}

# Get profile description
_nftban_profile_get_description() {
    local profile_name="$1"
    local profile_file="$NFTBAN_PROFILES_DIR/${profile_name}.conf"

    if [[ ! -f "$profile_file" ]]; then
        echo "Unknown profile"
        return 1
    fi

    # Extract PROFILE_DESCRIPTION from file
    grep "^PROFILE_DESCRIPTION=" "$profile_file" 2>/dev/null | cut -d'"' -f2 || echo "$profile_name"
}

# Apply profile
_nftban_profile_apply() {
    local profile_name="$1"
    local profile_file="$NFTBAN_PROFILES_DIR/${profile_name}.conf"

    if [[ ! -f "$profile_file" ]]; then
        echo "❌ ERROR: Profile not found: $profile_name"
        echo "   File: $profile_file"
        return 1
    fi

    echo "⏳ Applying profile: $profile_name"
    echo ""

    # Auto-initialize firewall if not already initialized
    if ! nft list tables 2>/dev/null | grep -q "nftban"; then
        echo "⚠️  Firewall not initialized. Initializing now..."
        echo ""
        if command -v nftban >/dev/null 2>&1; then
            if nftban firewall init; then
                echo "  ✅ Firewall initialized successfully"
            else
                echo "  ❌ ERROR: Failed to initialize firewall"
                echo "     Please run manually: nftban firewall init"
                return 1
            fi
        else
            echo "  ❌ ERROR: nftban command not found"
            echo "     Please initialize firewall manually: nftban firewall init"
            return 1
        fi
        echo ""
    fi

    # Create backup of current config.local
    if [[ -f "$NFTBAN_CONFIG_LOCAL" ]]; then
        cp "$NFTBAN_CONFIG_LOCAL" "${NFTBAN_CONFIG_LOCAL}.backup.$(date +%Y%m%d-%H%M%S)"
        echo "  📋 Backed up existing configuration"
    fi

    # Copy profile to config.local
    mkdir -p "$(dirname "$NFTBAN_CONFIG_LOCAL")"
    cp "$profile_file" "$NFTBAN_CONFIG_LOCAL"

    # Record current profile
    mkdir -p "$(dirname "$NFTBAN_PROFILE_CURRENT")"
    echo "$profile_name" > "$NFTBAN_PROFILE_CURRENT"
    echo "$(date '+%Y-%m-%d %H:%M:%S')" >> "$NFTBAN_PROFILE_CURRENT"

    echo "  ✅ Profile applied: $profile_name"
    echo "  📁 Configuration: $NFTBAN_CONFIG_LOCAL"
    echo ""

    # Show profile summary
    local description
    description=$(_nftban_profile_get_description "$profile_name")
    echo "Profile: $description"
    echo ""

    # Extract key settings
    echo "Key Settings:"
    if grep -q "^DDOS_PROTECTION_ENABLED=" "$profile_file"; then
        local ddos_enabled
        ddos_enabled=$(grep "^DDOS_PROTECTION_ENABLED=" "$profile_file" | cut -d'"' -f2)
        echo "  DDoS Protection: $ddos_enabled"
    fi
    if grep -q "^PORTSCAN_ENABLED=" "$profile_file"; then
        local portscan_enabled
        portscan_enabled=$(grep "^PORTSCAN_ENABLED=" "$profile_file" | cut -d'"' -f2)
        echo "  Port Scan Detection: $portscan_enabled"
    fi
    if grep -q "^PORTSCAN_AUTO_BAN=" "$profile_file"; then
        local auto_ban
        auto_ban=$(grep "^PORTSCAN_AUTO_BAN=" "$profile_file" | cut -d'"' -f2)
        echo "  Auto-Ban: $auto_ban"
    fi

    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  ✅ Profile Applied Successfully                         ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    echo "Next steps:"
    echo "  1. Review settings: nftban profile show"
    echo "  2. Enable DDoS protection: sudo nftban ddos enable"
    echo "  3. Enable port scan detection: sudo nftban portscan enable"

    return 0
}

# =============================================================================
# INTERACTIVE SELECTION
# =============================================================================

_nftban_profile_select() {
    _nftban_profile_banner
    echo ""
    echo "Select a security profile for your server:"
    echo ""

    # Build profile menu
    local -a profiles=()
    local -a descriptions=()

    # Read all available profiles
    mapfile -t profiles < <(_nftban_profile_list_available)

    if [[ ${#profiles[@]} -eq 0 ]]; then
        echo "❌ ERROR: No profiles found in $NFTBAN_PROFILES_DIR"
        return 1
    fi

    # Display menu
    local i=1
    for profile in "${profiles[@]}"; do
        local desc
        desc=$(_nftban_profile_get_description "$profile")

        # Add emoji based on profile type
        local emoji="📦"
        case "$profile" in
            web-server)     emoji="🌐" ;;
            mail-server)    emoji="📧" ;;
            database)       emoji="🗄️" ;;
            mixed)          emoji="🔀" ;;
            development)    emoji="🧪" ;;
            maximum)        emoji="🛡️" ;;
            custom)         emoji="✏️" ;;
        esac

        printf "  %d) %s %-15s - %s\n" "$i" "$emoji" "$profile" "$desc"
        i=$((i + 1))
    done

    echo "  $i) ❌ Cancel          - Exit without changes"
    echo ""

    # Get user choice
    local choice
    read -rp "Enter choice [1-$i]: " choice

    # Validate choice
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt "$i" ]]; then
        echo ""
        echo "❌ Invalid choice"
        return 1
    fi

    # Handle cancel
    if [[ "$choice" -eq "$i" ]]; then
        echo ""
        echo "Cancelled"
        return 0
    fi

    # Apply selected profile
    local selected_profile="${profiles[$((choice - 1))]}"
    echo ""
    _nftban_profile_apply "$selected_profile"

    return 0
}

# =============================================================================
# SHOW CURRENT PROFILE
# =============================================================================

_nftban_profile_show() {
    _nftban_profile_banner
    echo ""

    local current_profile
    current_profile=$(_nftban_profile_get_current)

    if [[ "$current_profile" == "none" ]]; then
        echo "No profile currently applied"
        echo ""
        echo "Available commands:"
        echo "  nftban profile select     - Interactive profile selection"
        echo "  nftban profile list       - List available profiles"
        return 0
    fi

    echo "Current Profile: $current_profile"

    # Show when applied
    if [[ -f "$NFTBAN_PROFILE_CURRENT" ]]; then
        local applied_time
        applied_time=$(sed -n '2p' "$NFTBAN_PROFILE_CURRENT" 2>/dev/null || echo "Unknown")
        echo "Applied: $applied_time"
    fi

    # Check if modified
    if [[ -f "$NFTBAN_CONFIG_LOCAL" ]]; then
        local profile_file="$NFTBAN_PROFILES_DIR/${current_profile}.conf"
        if [[ -f "$profile_file" ]]; then
            if diff -q "$profile_file" "$NFTBAN_CONFIG_LOCAL" &>/dev/null; then
                echo "Modified: No (pristine)"
            else
                echo "Modified: Yes (custom changes detected)"
            fi
        fi
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  📊 Configuration Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Show DDoS settings if config exists
    if [[ -f "$NFTBAN_CONFIG_LOCAL" ]]; then
        echo "DDoS Protection:"
        local ddos_enabled=$(grep "^DDOS_PROTECTION_ENABLED=" "$NFTBAN_CONFIG_LOCAL" 2>/dev/null | cut -d'"' -f2 || echo "unknown")
        local synflood=$(grep "^DDOS_SYNFLOOD_ENABLED=" "$NFTBAN_CONFIG_LOCAL" 2>/dev/null | cut -d'"' -f2 || echo "unknown")
        local connlimit=$(grep "^DDOS_CONNLIMIT_ENABLED=" "$NFTBAN_CONFIG_LOCAL" 2>/dev/null | cut -d'"' -f2 || echo "unknown")

        echo "  Master Switch: $ddos_enabled"
        echo "  SYN Flood: $synflood"
        echo "  Connection Limits: $connlimit"

        echo ""
        echo "Port Scan Detection:"
        local portscan=$(grep "^PORTSCAN_ENABLED=" "$NFTBAN_CONFIG_LOCAL" 2>/dev/null | cut -d'"' -f2 || echo "unknown")
        local threshold=$(grep "^PORTSCAN_THRESHOLD=" "$NFTBAN_CONFIG_LOCAL" 2>/dev/null | cut -d'"' -f2 || echo "unknown")
        local auto_ban=$(grep "^PORTSCAN_AUTO_BAN=" "$NFTBAN_CONFIG_LOCAL" 2>/dev/null | cut -d'"' -f2 || echo "unknown")

        echo "  Enabled: $portscan"
        echo "  Threshold: $threshold ports"
        echo "  Auto-Ban: $auto_ban"
    fi

    echo ""
    echo "Configuration file: $NFTBAN_CONFIG_LOCAL"
    echo ""

    return 0
}

# =============================================================================
# LIST PROFILES
# =============================================================================

_nftban_profile_list() {
    _nftban_profile_banner
    echo ""
    echo "Available Security Profiles:"
    echo ""

    mapfile -t profiles < <(_nftban_profile_list_available)

    if [[ ${#profiles[@]} -eq 0 ]]; then
        echo "  (no profiles found)"
        return 0
    fi

    for profile in "${profiles[@]}"; do
        local desc emoji best_for
        desc=$(_nftban_profile_get_description "$profile")

        # Add emoji and best-for text
        case "$profile" in
            web-server)
                emoji="🌐"
                best_for="nginx, Apache, web applications"
                ;;
            mail-server)
                emoji="📧"
                best_for="Postfix, Dovecot, mail servers"
                ;;
            database)
                emoji="🗄️"
                best_for="MySQL, PostgreSQL, MongoDB"
                ;;
            mixed)
                emoji="🔀"
                best_for="Shared hosting, multi-purpose servers"
                ;;
            development)
                emoji="🧪"
                best_for="Development, staging environments"
                ;;
            maximum)
                emoji="🛡️"
                best_for="High-security requirements"
                ;;
            custom)
                emoji="✏️"
                best_for="User-defined configuration"
                ;;
            *)
                emoji="📦"
                best_for="Custom profile"
                ;;
        esac

        printf "%s %-15s\n" "$emoji" "$profile"
        printf "   Description: %s\n" "$desc"
        printf "   Best for: %s\n" "$best_for"
        echo ""
    done

    echo "Apply a profile:"
    echo "  nftban profile select           # Interactive selection"
    echo "  nftban profile apply <name>     # Apply specific profile"
    echo ""

    return 0
}

# =============================================================================
# HELP TEXT
# =============================================================================

_nftban_profile_help() {
    # Load output module for standard banner
    source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"

    # Show standard banner
    nftban_banner

    cat <<'HELP'

USAGE:
    nftban profile <command> [profile-name]

COMMANDS:
    select              Interactive profile selection (recommended)
    apply <name>        Apply specific profile
    show                Show currently applied profile
    list                List all available profiles
    help                Show this help message

DESCRIPTION:
    Security profiles are pre-configured settings for DDoS protection
    and port scan detection, optimized for different server roles.

    Instead of manually configuring dozens of parameters, simply select
    a profile that matches your server's purpose and get optimal security
    settings automatically.

AVAILABLE PROFILES:

    🌐 web-server
       Optimized for: nginx, Apache, web applications
       DDoS: High HTTP/HTTPS limits, connection tracking
       Port Scan: 10 ports in 5 minutes, 1-hour temp ban

    📧 mail-server
       Optimized for: Postfix, Dovecot, mail servers
       DDoS: SMTP/POP3/IMAP limits, SYN flood protection
       Port Scan: 8 ports in 3 minutes, 2-hour temp ban

    🗄️  database
       Optimized for: MySQL, PostgreSQL, MongoDB
       DDoS: Database connection limits
       Port Scan: 5 ports in 2 minutes, PERMANENT ban

    🔀 mixed
       Optimized for: Shared hosting, multi-purpose servers
       DDoS: Balanced limits for all services
       Port Scan: 10 ports in 5 minutes, 1-hour temp ban

    🧪 development
       Optimized for: Development, staging, testing
       DDoS: DISABLED (no production protections)
       Port Scan: Log only, NO AUTO-BAN

    🛡️  maximum
       Optimized for: High-security, paranoid mode
       DDoS: All protections enabled, strict limits
       Port Scan: 3 ports in 1 minute, PERMANENT ban

    ✏️  custom
       User-defined configuration template
       Customize all settings to your specific needs

HOW IT WORKS:

    1. Profile Selection: Choose profile matching your server role
    2. Configuration: Profile settings copied to nftban.conf.local
    3. Application: Enable protections with ddos/portscan commands
    4. Customization: Edit nftban.conf.local for fine-tuning

EXAMPLES:

    # Interactive selection (recommended for beginners)
    sudo nftban profile select

    # Apply specific profile (for scripts/automation)
    sudo nftban profile apply web-server

    # Show current profile and settings
    nftban profile show

    # List all available profiles
    nftban profile list

AFTER APPLYING A PROFILE:

    1. Review settings:
       nftban profile show

    2. Enable DDoS protection:
       sudo nftban ddos enable

    3. Enable port scan detection:
       sudo nftban portscan enable

    4. Check status:
       nftban ddos status
       nftban portscan status

CUSTOMIZATION:

    After applying a profile, you can customize settings by editing:
      /etc/nftban/nftban.conf.local

    Example custom changes:
      DDOS_CONNLIMIT_HTTP="100"        # Increase HTTP limit
      PORTSCAN_THRESHOLD="5"           # More aggressive detection

    Changes in nftban.conf.local override profile defaults.

FILES:

    Profiles: /usr/share/nftban/profiles/*.conf
    Current: /var/lib/nftban/profile.current
    Config: /etc/nftban/nftban.conf.local

SEE ALSO:
    nftban ddos help         - DDoS protection help
    nftban portscan help     - Port scan detection help

HELP
}

# =============================================================================
# MAIN COMMAND HANDLER
# =============================================================================

nftban_cmd_profile() {
    local action="${1:-select}"
    shift || true

    # Check root privileges for state-changing operations
    case "$action" in
        select|apply)
            if [[ "$EUID" -ne 0 ]]; then
                echo "ERROR: This command requires root privileges"
                echo "Usage: sudo nftban profile $action"
                exit 1
            fi
            ;;
    esac

    # Handle commands
    case "$action" in
        select)
            _nftban_profile_select
            ;;

        apply)
            if [[ -z "${1:-}" ]]; then
                echo "ERROR: Profile name required"
                echo "Usage: nftban profile apply <profile-name>"
                echo ""
                echo "Available profiles:"
                _nftban_profile_list_available | sed 's/^/  /'
                exit 1
            fi
            _nftban_profile_apply "$1"
            ;;

        show)
            _nftban_profile_show
            ;;

        list)
            _nftban_profile_list
            ;;

        help|--help|-h)
            _nftban_profile_help
            ;;

        *)
            echo "ERROR: Unknown command: $action"
            echo ""
            echo "Available commands: select, apply, show, list, help"
            echo "Run 'nftban profile help' for detailed usage information"
            exit 1
            ;;
    esac

    return 0
}

# =============================================================================
# EXPORT FOR MAIN CLI
# =============================================================================
export -f nftban_cmd_profile

# Execute if called directly (shouldn't happen, but handle gracefully)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_profile "$@"
fi
