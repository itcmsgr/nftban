#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0 - Suricata IDS CLI Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Easy user interface for Suricata IDS management
#
# meta:name="cmd_suricata"
# meta:type="cli"
# meta:header="Suricata IDS Management"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# **Description & Purpose**
# meta:description="User-friendly CLI for Suricata IDS installation and management"
# meta:input="Commands: install, enable, disable, status, rules"
# meta:output="Automated Suricata setup and control"
#
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# meta:created_date="2025-12-28"
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

# Load output library
if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"
fi

# Suricata paths
readonly SURICATA_SETUP_SCRIPT="${NFTBAN_LIB_DIR}/setup/install_suricata.sh"
readonly SURICATA_RULES_SCRIPT="${NFTBAN_LIB_DIR}/setup/setup_suricata_rules.sh"
readonly SURICATA_SERVICE="suricata.service"

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

_check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: This command requires root privileges"
        echo "Usage: sudo nftban suricata $1"
        return 1
    fi
}

# =============================================================================
# COMMAND: install
# =============================================================================

cmd_suricata_install() {
    _check_root install || return 1

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🛡️  NFTBan - Suricata IDS Automated Installation"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Check if already installed
    if _suricata_is_installed; then
        local version
        version=$(suricata -V 2>&1 | head -1 || echo "unknown")
        echo "✓ Suricata is already installed: $version"
        echo ""
        read -p "Do you want to reinstall/upgrade? [y/N]: " reinstall
        if [[ "${reinstall,,}" != "y" ]]; then
            echo "  Installation cancelled"
            return 0
        fi
        echo ""
    fi

    echo "This will:"
    echo "  1. Check for package repository version (EPEL)"
    echo "  2. Install Suricata from packages OR compile from source"
    echo "  3. Configure Suricata for NFTBan integration"
    echo "  4. Setup systemd service"
    echo ""
    read -p "Continue with installation? [Y/n]: " confirm
    confirm=${confirm:-y}
    if [[ "${confirm,,}" != "y" ]]; then
        echo "  Installation cancelled"
        return 0
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Step 1/3: Installing Suricata"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Try package installation first
    local pkg_installed=false
    if command -v dnf &>/dev/null; then
        echo "  → Checking DNF repositories for Suricata..."
        if dnf info suricata &>/dev/null 2>&1; then
            echo "  ✓ Suricata package found in repositories"
            echo "  → Installing via DNF..."
            if dnf install -y suricata; then
                pkg_installed=true
                echo "  ✓ Suricata installed from packages"
            fi
        fi
    elif command -v apt-get &>/dev/null; then
        echo "  → Checking APT repositories for Suricata..."
        apt-get update -qq
        if apt-cache show suricata &>/dev/null 2>&1; then
            echo "  ✓ Suricata package found in repositories"
            echo "  → Installing via APT..."
            if apt-get install -y suricata; then
                pkg_installed=true
                echo "  ✓ Suricata installed from packages"
            fi
        fi
    fi

    # If package install failed, use setup script
    if [[ "$pkg_installed" == false ]]; then
        echo "  ⊘ No package available, installing from source..."
        if [[ -f "$SURICATA_SETUP_SCRIPT" ]]; then
            bash "$SURICATA_SETUP_SCRIPT" || {
                echo "  ✗ Installation from source failed"
                return 1
            }
        else
            echo "  ✗ Setup script not found: $SURICATA_SETUP_SCRIPT"
            return 1
        fi
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Step 2/3: Installing Detection Rules"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Install suricata-update if not present
    if ! command -v suricata-update &>/dev/null; then
        echo "  → Installing suricata-update..."
        pip3 install --upgrade suricata-update || {
            echo "  ✗ Failed to install suricata-update"
            return 1
        }
    fi

    # Run rules setup
    if [[ -f "$SURICATA_RULES_SCRIPT" ]]; then
        bash "$SURICATA_RULES_SCRIPT" || {
            echo "  ⚠  Rules setup had warnings (may be OK)"
        }
    else
        echo "  ⊘ Rules script not found, manual setup required"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Step 3/3: Finalizing Installation"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Set config flags in nftban.conf.local (user overrides — survives package upgrades)
    # Package defaults in nftban.conf are never modified by user operations
    local local_conf="${NFTBAN_CONFIG_DIR}/nftban.conf.local"
    touch "$local_conf"

    if grep -q "^ENABLE_IDS_INTEGRATION=" "$local_conf"; then
        sed -i 's/^ENABLE_IDS_INTEGRATION=.*/ENABLE_IDS_INTEGRATION=1/' "$local_conf"
    else
        echo "ENABLE_IDS_INTEGRATION=1" >> "$local_conf"
    fi

    if grep -q "^NFTBAN_SURICATA_ENABLED=" "$local_conf"; then
        sed -i 's/^NFTBAN_SURICATA_ENABLED=.*/NFTBAN_SURICATA_ENABLED=true/' "$local_conf"
    else
        echo "NFTBAN_SURICATA_ENABLED=true" >> "$local_conf"
    fi
    echo "  ✓ NFTBan config updated (IDS enabled)"

    # Enable Suricata rules update timer (weekly updates)
    if [[ -f /usr/lib/systemd/system/nftban-suricata-update.timer ]]; then
        systemctl enable nftban-suricata-update.timer 2>/dev/null || echo "  ⊘ Timer enable failed (will install manually)"
        echo "  ✓ Rules update timer enabled (weekly Sunday 3 AM)"
    fi

    # Show version
    local version
    version=$(suricata -V 2>&1 | head -1 || echo "unknown")
    echo "  ✓ Installed: $version"
    echo ""

    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  ✅ Suricata IDS Installation Complete!                      ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Next steps:"
    echo "  1. Enable and start: nftban suricata enable"
    echo "  2. Check status:     nftban suricata status"
    echo "  3. View alerts:      tail -f /var/log/nftban/suricata/eve-alerts.json"
    echo ""
}

# =============================================================================
# COMMAND: enable
# =============================================================================

cmd_suricata_enable() {
    _check_root enable || return 1

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🛡️  NFTBan - Enable Suricata IDS"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Check if installed
    if ! _suricata_is_installed; then
        echo "✗ Suricata is not installed"
        echo ""
        echo "Install first:"
        echo "  nftban suricata install"
        return 1
    fi

    # Enable service
    echo "  → Enabling Suricata service..."
    systemctl enable "$SURICATA_SERVICE" || {
        echo "  ✗ Failed to enable service"
        return 1
    }
    echo "  ✓ Service enabled (will start on boot)"

    # Start service
    echo "  → Starting Suricata service..."
    systemctl start "$SURICATA_SERVICE" || {
        echo "  ✗ Failed to start service"
        echo ""
        echo "Check logs:"
        echo "  journalctl -u suricata -n 50"
        return 1
    }

    # Wait for startup
    sleep 2

    # Verify running
    if _suricata_is_running; then
        echo "  ✓ Suricata is running"
    else
        echo "  ✗ Suricata failed to start"
        systemctl status "$SURICATA_SERVICE" --no-pager -l
        return 1
    fi

    # Enable automatic rules update timer
    if [[ -f /usr/lib/systemd/system/nftban-suricata-update.timer ]]; then
        echo "  → Enabling weekly rules update timer..."
        systemctl enable --now nftban-suricata-update.timer 2>/dev/null && \
            echo "  ✓ Rules update timer enabled (weekly Sunday 3 AM)" || \
            echo "  ⊘ Timer enable failed (not critical)"
    fi

    echo ""
    echo "✅ Suricata IDS is now ENABLED and RUNNING"
    echo ""
    echo "Automatic updates:"
    echo "  Rules updated weekly (Sunday 3 AM)"
    echo "  Manual update: nftban suricata rules update"
    echo ""
    echo "Monitor alerts:"
    echo "  tail -f /var/log/nftban/suricata/eve-alerts.json | jq 'select(.event_type==\"alert\")'"
    echo ""
    echo "Check status:"
    echo "  nftban suricata status"
    echo ""
}

# =============================================================================
# COMMAND: disable
# =============================================================================

cmd_suricata_disable() {
    _check_root disable || return 1

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🛡️  NFTBan - Disable Suricata IDS"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Stop service
    echo "  → Stopping Suricata service..."
    systemctl stop "$SURICATA_SERVICE" || true
    echo "  ✓ Service stopped"

    # Disable service
    echo "  → Disabling Suricata service..."
    systemctl disable "$SURICATA_SERVICE" || true
    echo "  ✓ Service disabled (will not start on boot)"

    # Disable rules update timer
    if systemctl is-enabled --quiet nftban-suricata-update.timer 2>/dev/null; then
        echo "  → Disabling weekly rules update timer..."
        systemctl disable --now nftban-suricata-update.timer 2>/dev/null || true
        echo "  ✓ Rules update timer disabled"
    fi

    echo ""
    echo "✅ Suricata IDS is now DISABLED"
    echo ""
}

# =============================================================================
# COMMAND: status
# =============================================================================

cmd_suricata_status() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🛡️  Suricata IDS Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Installation status
    if _suricata_is_installed; then
        local version
        version=$(suricata -V 2>&1 | head -1 || echo "unknown")
        echo "  Installed:  ✅ YES - $version"
    else
        echo "  Installed:  ❌ NO"
        echo ""
        echo "Install with:"
        echo "  nftban suricata install"
        return 1
    fi

    # Service status
    if _suricata_is_running; then
        echo "  Running:    ✅ YES"
    else
        echo "  Running:    ❌ NO"
    fi

    if _suricata_is_enabled; then
        echo "  Enabled:    ✅ YES (starts on boot)"
    else
        echo "  Enabled:    ❌ NO"
    fi

    # Auto-update timer status
    if systemctl is-enabled --quiet nftban-suricata-update.timer 2>/dev/null; then
        echo "  Auto-update: ✅ YES (weekly Sunday 3 AM)"
    elif [[ -f /usr/lib/systemd/system/nftban-suricata-update.timer ]]; then
        echo "  Auto-update: ❌ NO (timer not enabled)"
    else
        echo "  Auto-update: ⊘ Timer not installed"
    fi

    # Rules status
    echo ""
    echo "  Rules:"
    if [[ -d /var/lib/suricata/rules ]]; then
        local rule_count
        rule_count=$(find /var/lib/suricata/rules -name "*.rules" -exec cat {} \; 2>/dev/null | grep -c "^alert" || echo "0")
        echo "    Total alert rules: $rule_count"
        echo "    Rules directory:   /var/lib/suricata/rules/"
    else
        echo "    ⚠  No rules directory found"
    fi

    # Recent alerts
    echo ""
    echo "  Recent Alerts (last 5):"
    if [[ -f /var/log/nftban/suricata/eve-alerts.json ]]; then
        tail -100 /var/log/nftban/suricata/eve-alerts.json 2>/dev/null | \
            jq -r 'select(.event_type=="alert") | "    [\(.timestamp)] \(.alert.signature) - \(.src_ip):\(.src_port) -> \(.dest_ip):\(.dest_port)"' 2>/dev/null | \
            tail -5 || echo "    (no recent alerts or jq not installed)"
    else
        echo "    (eve.json not found)"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Show systemd status if running
    if _suricata_is_running; then
        echo "Service Status:"
        systemctl status "$SURICATA_SERVICE" --no-pager -l | head -15
    fi

    echo ""
}

# =============================================================================
# COMMAND: rules
# =============================================================================

cmd_suricata_rules() {
    local action="${1:-help}"

    case "$action" in
        update)
            _check_root "rules update" || return 1

            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  🛡️  Updating Suricata Rules"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            if ! command -v suricata-update &>/dev/null; then
                echo "✗ suricata-update not installed"
                echo ""
                echo "Install:"
                echo "  pip3 install --upgrade suricata-update"
                return 1
            fi

            echo "  → Downloading latest rules from ET/Open..."
            suricata-update || {
                echo "  ✗ Rule update failed"
                return 1
            }

            echo ""
            echo "  → Restarting Suricata to load new rules..."
            systemctl restart "$SURICATA_SERVICE" || {
                echo "  ✗ Failed to restart Suricata"
                return 1
            }

            sleep 2
            if _suricata_is_running; then
                echo "  ✓ Suricata restarted successfully"
            else
                echo "  ✗ Suricata failed to restart"
                return 1
            fi

            echo ""
            echo "✅ Rules updated successfully"
            echo ""
            ;;

        list)
            echo ""
            echo "Suricata Rule Files:"
            if [[ -d /var/lib/suricata/rules ]]; then
                ls -lh /var/lib/suricata/rules/*.rules 2>/dev/null || echo "No rule files found"
            else
                echo "Rules directory not found"
            fi
            echo ""
            ;;

        generate)
            _check_root "rules generate" || return 1

            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  📝 Generating Suricata Rules List"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata rules-generate; then
                echo "✗ Rules generation failed"
                return 1
            fi

            echo ""
            ;;

        stats)
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  📊 Suricata Rules Statistics"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata rules-stats; then
                echo "✗ Failed to get stats"
                return 1
            fi

            echo ""
            ;;

        init)
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  🔧 Initializing Suricata Configuration"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata rules-init; then
                echo "✗ Initialization failed"
                return 1
            fi

            echo ""
            ;;

        help|*)
            cat << 'EOF'

Suricata Rules Management

USAGE:
    nftban suricata rules <command>

COMMANDS:
    update      Update rules from ET/Open (requires root)
    generate    Generate enabled.list from service scan (requires root)
    stats       Show rules statistics
    init        Initialize configuration files
    list        List installed rule files
    help        Show this help message

WORKFLOW:
    1. Scan services:    nftban suricata scan
    2. Generate list:    nftban suricata rules generate
    3. Restart Suricata: systemctl restart suricata

EXAMPLES:
    # Generate rules list from scan
    nftban suricata rules generate

    # Show statistics
    nftban suricata rules stats

    # Update ET/Open ruleset
    nftban suricata rules update

NOTES:
    - Rules are updated automatically via systemd timer (weekly)
    - Service-based filtering reduces CPU/RAM by 50-70%
    - Only relevant rules are loaded based on detected services

EOF
            ;;
    esac
}

# =============================================================================
# COMMAND: profile
# =============================================================================

cmd_suricata_profile() {
    local action="${1:-help}"
    shift || true

    case "$action" in
        detect)
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  🔍 Detecting Optimal Suricata Profile"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend for detection
            if ! nftban-core suricata profile-detect; then
                echo "✗ Profile detection failed"
                return 1
            fi

            echo ""
            ;;

        set|apply)
            local profile_name="${1:-}"

            if [[ -z "$profile_name" ]]; then
                echo "ERROR: Profile name required"
                echo ""
                echo "Usage: nftban suricata profile set <PROFILE>"
                echo ""
                echo "Available profiles:"
                echo "  minimal   - 2 cores / 2 GB RAM (low resource usage)"
                echo "  standard  - 4 cores / 4-8 GB RAM (balanced, default)"
                echo "  maximum   - 8+ cores / 8-16 GB RAM (deep inspection)"
                echo ""
                return 1
            fi

            _check_root "profile set" || return 1

            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  ⚙️  Applying Suricata Profile: $profile_name"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend to apply profile
            if ! nftban-core suricata profile-apply "$profile_name"; then
                echo ""
                echo "✗ Failed to apply profile"
                return 1
            fi

            echo ""
            echo "  ✓ Profile applied successfully"
            echo ""

            # Restart Suricata if running
            if _suricata_is_running; then
                echo "  → Restarting Suricata to load new configuration..."
                if systemctl restart "$SURICATA_SERVICE" 2>/dev/null; then
                    sleep 2
                    if _suricata_is_running; then
                        echo "  ✓ Suricata restarted successfully"
                    else
                        echo "  ✗ Suricata failed to restart - check logs"
                        return 1
                    fi
                else
                    echo "  ⚠  Could not restart Suricata (not running?)"
                fi
            else
                echo "  ℹ  Suricata is not running - start it to use new profile"
            fi

            echo ""
            echo "✅ Profile configuration complete"
            echo ""
            ;;

        show|current|status)
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  📊 Current Suricata Profile"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend to show current profile
            if ! nftban-core suricata profile-show; then
                echo "✗ Failed to determine current profile"
                return 1
            fi

            echo ""
            ;;

        validate|check)
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  ✅ Validating Suricata Profile Configuration"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend to validate profile
            if nftban-core suricata profile-validate; then
                echo ""
                echo "✅ Profile configuration is valid"
                echo ""
            else
                echo ""
                echo "✗ Profile validation failed"
                echo ""
                echo "Fix this by running:"
                echo "  nftban suricata profile detect"
                echo "  nftban suricata profile set <PROFILE>"
                echo ""
                return 1
            fi
            ;;

        help|*)
            cat << 'EOF'

🛡️  Suricata Profile Management

USAGE:
    nftban suricata profile <command>

COMMANDS:
    detect      Auto-detect optimal profile based on CPU/RAM
    set         Apply a specific profile (minimal/standard/maximum)
    show        Display current active profile
    validate    Validate profile configuration
    help        Show this help message

PROFILES:
    minimal     2 cores / 2 GB RAM
                - Ring size: 50k
                - Flow timeout: 60s
                - HTTP body: disabled
                - Detection: low
                - Use case: Tiny VPS, stability first

    standard    4 cores / 4-8 GB RAM (DEFAULT)
                - Ring size: 100k
                - Flow timeout: 120s
                - HTTP body: 30KB
                - Detection: medium
                - Use case: Most servers, balanced

    maximum     8+ cores / 8-16 GB RAM
                - Ring size: 300k
                - Flow timeout: 300s
                - HTTP body: 30KB (full)
                - Detection: high
                - Use case: High traffic, deep inspection

EXAMPLES:
    # Auto-detect and apply optimal profile:
    nftban suricata profile detect
    nftban suricata profile set standard

    # Check current profile:
    nftban suricata profile show

    # Validate configuration:
    nftban suricata profile validate

NOTES:
    - Profile changes require Suricata restart to take effect
    - Profiles are YAML templates in /etc/nftban/suricata/profiles/
    - Active config: /etc/suricata/suricata.yaml (symlink)
    - Profile setting stored in: /etc/nftban/suricata/config/profile.conf

EOF
            ;;
    esac
}

# =============================================================================
# COMMAND: scan
# =============================================================================

cmd_suricata_scan() {
    local action="${1:-quick}"

    case "$action" in
        quick)
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  🔍 Scanning localhost for services..."
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata scan; then
                echo "✗ Service scan failed"
                return 1
            fi

            echo ""
            ;;

        deep)
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  🔬 Deep scanning localhost (protocol probes)..."
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata scan-deep; then
                echo "✗ Deep scan failed"
                return 1
            fi

            echo ""
            ;;

        help|*)
            cat << 'EOF'

🔍 Suricata Service Scanner

USAGE:
    nftban suricata scan [quick|deep]

COMMANDS:
    quick       Quick port scan (default)
    deep        Deep scan with protocol probes
    help        Show this help message

DESCRIPTION:
    Scans localhost for running services and auto-configures
    Suricata to enable only relevant rule categories.

    This reduces CPU/RAM usage by 50-70% by loading only
    the rules needed for your actual services.

EXAMPLES:
    # Quick scan
    nftban suricata scan

    # Deep scan with protocol detection
    nftban suricata scan deep

WHAT IT DOES:
    1. Scans common ports (HTTP, HTTPS, SSH, MySQL, DNS, etc.)
    2. Detects running services
    3. Maps services to Suricata rule categories
    4. Generates /etc/nftban/suricata/config/suricata.auto.conf
    5. Merges with local.conf to create effective.conf

NEXT STEPS:
    After scanning, generate the rules list:
      nftban suricata rules generate

    Then restart Suricata:
      systemctl restart suricata

EOF
            ;;
    esac
}

# =============================================================================
# COMMAND: services
# =============================================================================

cmd_suricata_services() {
    local action="${1:-list}"

    case "$action" in
        list)
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  📋 Suricata Service Configuration"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Show current config files
            local config_dir="/etc/nftban/suricata/config"

            if [[ -f "$config_dir/suricata.auto.conf" ]]; then
                echo "Auto-detected configuration:"
                echo "  (from last scan)"
                echo ""
                cat "$config_dir/suricata.auto.conf" | grep -v "^#" | grep -v "^$"
                echo ""
            else
                echo "⚠  No auto-detected configuration found"
                echo "   Run: nftban suricata scan"
                echo ""
            fi

            if [[ -f "$config_dir/suricata.local.conf" ]]; then
                echo "Manual overrides:"
                echo "  (from local.conf)"
                echo ""
                cat "$config_dir/suricata.local.conf" | grep -v "^#" | grep -v "^$"
                echo ""
            fi

            ;;

        help|*)
            cat << 'EOF'

📋 Suricata Service Management

USAGE:
    nftban suricata services <command>

COMMANDS:
    list        Show current service configuration
    help        Show this help message

CONFIGURATION FILES:
    /etc/nftban/suricata/config/
    ├── suricata.auto.conf       (auto-detected, generated)
    ├── suricata.local.conf      (manual overrides, user-edited)
    └── suricata.effective.conf  (merged result, generated)

WORKFLOW:
    1. Scan:     nftban suricata scan
    2. Override: Edit /etc/nftban/suricata/config/suricata.local.conf
    3. Generate: nftban suricata rules generate
    4. Restart:  systemctl restart suricata

EOF
            ;;
    esac
}

# =============================================================================
# COMMAND: sid (SID Statistics)
# =============================================================================

cmd_suricata_sid() {
    local action="${1:-help}"
    shift || true

    case "$action" in
        stats)
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  📊 Suricata SID Statistics"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata sid-stats; then
                echo "✗ Failed to get SID statistics"
                return 1
            fi

            echo ""
            ;;

        info)
            local sid="${1:-}"

            if [[ -z "$sid" ]]; then
                echo "ERROR: SID required"
                echo ""
                echo "Usage: nftban suricata sid info <SID>"
                echo ""
                echo "Example:"
                echo "  nftban suricata sid info 2100498"
                echo ""
                return 1
            fi

            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  🔍 SID Information: $sid"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata sid-info "$sid"; then
                echo "✗ SID not found or failed to retrieve information"
                return 1
            fi

            echo ""
            ;;

        top)
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  🏆 Top 20 Most Triggered SIDs"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata sid-top; then
                echo "✗ Failed to get top SIDs"
                return 1
            fi

            echo ""
            ;;

        recent)
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  ⏱️  Recent SID Triggers (Last 24 Hours)"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata sid-recent; then
                echo "✗ Failed to get recent SIDs"
                return 1
            fi

            echo ""
            ;;

        help|*)
            cat << 'EOF'

📊 Suricata SID Statistics

USAGE:
    nftban suricata sid <command>

COMMANDS:
    stats       Show overall SID statistics summary
    info        Show detailed information for a specific SID
    top         Show top 20 most triggered SIDs
    recent      Show SIDs triggered in last 24 hours
    help        Show this help message

DESCRIPTION:
    Track and analyze Suricata signature (SID) triggers in real-time.
    Statistics are collected from eve.json and cached for fast queries.

EXAMPLES:
    # Overall statistics
    nftban suricata sid stats

    # Top triggered SIDs
    nftban suricata sid top

    # Recent triggers
    nftban suricata sid recent

    # Detailed info for specific SID
    nftban suricata sid info 2100498

WHAT IT SHOWS:
    - Total unique SIDs triggered
    - Total trigger count across all SIDs
    - Unique source IPs that triggered alerts
    - Trigger timestamps (first/last)
    - Source IP addresses for each SID
    - Rule categories and signatures

DATA SOURCE:
    - Real-time: Tails /var/log/nftban/suricata/eve-alerts.json
    - Cache: /etc/nftban/suricata/cache/sid-stats.json
    - Metrics: Prometheus (if nftban-core metrics server running)

NOTES:
    - Statistics persist across restarts via JSON snapshots
    - Historical data loaded on startup
    - Auto-saves every 5 minutes
    - No database required (in-memory + snapshots)

EOF
            ;;
    esac
}

# =============================================================================
# COMMAND: custom (Custom Rules Management)
# =============================================================================

cmd_suricata_custom() {
    local action="${1:-help}"
    shift || true

    case "$action" in
        add)
            _check_root "custom add" || return 1

            local rule="$1"
            if [[ -z "$rule" ]]; then
                echo "ERROR: Rule required"
                echo ""
                echo "Usage: nftban suricata custom add '<RULE>'"
                echo ""
                echo "Example:"
                echo "  nftban suricata custom add 'alert tcp any any -> any 80 (msg:\"HTTP Traffic\"; sid:9000000; rev:1;)'"
                echo ""
                return 1
            fi

            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  ➕ Adding Custom Suricata Rule"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata custom-add "$rule"; then
                echo "✗ Failed to add custom rule"
                return 1
            fi

            echo ""
            ;;

        remove)
            _check_root "custom remove" || return 1

            local sid="$1"
            if [[ -z "$sid" ]]; then
                echo "ERROR: SID required"
                echo ""
                echo "Usage: nftban suricata custom remove <SID>"
                echo ""
                echo "Example:"
                echo "  nftban suricata custom remove 9000000"
                echo ""
                return 1
            fi

            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  🗑️  Removing Custom Suricata Rule"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata custom-remove "$sid"; then
                echo "✗ Failed to remove custom rule"
                return 1
            fi

            echo ""
            ;;

        edit)
            _check_root "custom edit" || return 1

            local sid="$1"
            local new_rule="$2"

            if [[ -z "$sid" ]] || [[ -z "$new_rule" ]]; then
                echo "ERROR: SID and new rule required"
                echo ""
                echo "Usage: nftban suricata custom edit <SID> '<NEW_RULE>'"
                echo ""
                echo "Example:"
                echo "  nftban suricata custom edit 9000000 'alert tcp any any -> any 80 (msg:\"Updated\"; sid:9000000; rev:2;)'"
                echo ""
                return 1
            fi

            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  ✏️  Editing Custom Suricata Rule"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata custom-edit "$sid" "$new_rule"; then
                echo "✗ Failed to edit custom rule"
                return 1
            fi

            echo ""
            ;;

        list)
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  📋 Custom Suricata Rules"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata custom-list; then
                echo "✗ Failed to list custom rules"
                return 1
            fi

            echo ""
            ;;

        validate)
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  ✅ Validating Custom Suricata Rules"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata custom-validate; then
                echo "✗ Validation failed"
                return 1
            fi

            echo ""
            ;;

        enable)
            _check_root "custom enable" || return 1

            local sid="$1"
            if [[ -z "$sid" ]]; then
                echo "ERROR: SID required"
                echo ""
                echo "Usage: nftban suricata custom enable <SID>"
                echo ""
                return 1
            fi

            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  ✅ Enabling Custom Rule"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata custom-enable "$sid"; then
                echo "✗ Failed to enable custom rule"
                return 1
            fi

            echo ""
            ;;

        disable)
            _check_root "custom disable" || return 1

            local sid="$1"
            if [[ -z "$sid" ]]; then
                echo "ERROR: SID required"
                echo ""
                echo "Usage: nftban suricata custom disable <SID>"
                echo ""
                return 1
            fi

            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  ❌ Disabling Custom Rule"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata custom-disable "$sid"; then
                echo "✗ Failed to disable custom rule"
                return 1
            fi

            echo ""
            ;;

        backup)
            _check_root "custom backup" || return 1

            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  💾 Backup Custom Rules"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata custom-backup; then
                echo "✗ Failed to create backup"
                return 1
            fi

            echo ""
            ;;

        rollback)
            _check_root "custom rollback" || return 1

            local backup_name="$1"
            if [[ -z "$backup_name" ]]; then
                echo "ERROR: Backup name required"
                echo ""
                echo "Usage: nftban suricata custom rollback <BACKUP_NAME>"
                echo ""
                echo "List backups with: nftban suricata custom backup"
                echo ""
                return 1
            fi

            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  ⏮️  Rollback Custom Rules"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata custom-rollback "$backup_name"; then
                echo "✗ Failed to rollback"
                return 1
            fi

            echo ""
            ;;

        help|*)
            cat << 'EOF'

🔧 Custom Suricata Rules Management

USAGE:
    nftban suricata custom <command>

COMMANDS:
    add         Add a new custom rule
    remove      Remove a custom rule by SID
    edit        Edit an existing custom rule
    list        List all custom rules
    validate    Validate all custom rules
    enable      Enable a disabled rule
    disable     Disable an enabled rule
    backup      Create a backup of custom rules
    rollback    Restore from a backup
    help        Show this help message

SID RANGE:
    Custom rules MUST use SID range: 9000000-9999999
    This prevents conflicts with official rulesets

EXAMPLES:
    # Add a new rule
    nftban suricata custom add 'alert tcp any any -> any 80 (msg:"HTTP Traffic"; sid:9000000; rev:1;)'

    # List all custom rules
    nftban suricata custom list

    # Validate all rules
    nftban suricata custom validate

    # Remove a rule
    nftban suricata custom remove 9000000

    # Disable a rule (comment out)
    nftban suricata custom disable 9000000

    # Create backup
    nftban suricata custom backup

    # Rollback to backup
    nftban suricata custom rollback custom.rules.20240101-120000

WORKFLOW:
    1. Add rule:        nftban suricata custom add '<RULE>'
    2. Validate:        nftban suricata custom validate
    3. Reload Suricata: systemctl reload suricata
    4. Monitor:         nftban suricata sid info <SID>

BACKUPS:
    - Automatic backup before any modification
    - Backups stored in: /etc/nftban/suricata/rules/backups/
    - Last 10 backups are kept
    - Rollback restores previous state

NOTES:
    - All modifications require root
    - Rules are validated before adding/editing
    - Invalid rules will be rejected
    - Changes require Suricata reload to take effect
    - Custom rules file: /etc/nftban/suricata/rules/custom.rules

EOF
            ;;
    esac
}

# =============================================================================
# COMMAND: recommend (Recommendations Engine)
# =============================================================================

cmd_suricata_recommend() {
    local action="${1:-analyze}"

    case "$action" in
        analyze|all)
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  💡 Suricata Rule Recommendations"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata recommend; then
                echo "✗ Failed to generate recommendations"
                return 1
            fi

            echo ""
            ;;

        summary)
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  📊 Recommendations Summary"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata recommend-summary; then
                echo "✗ Failed to generate summary"
                return 1
            fi

            echo ""
            ;;

        help|*)
            cat << 'EOF'

💡 Suricata Recommendations Engine

USAGE:
    nftban suricata recommend [analyze|summary]

COMMANDS:
    analyze     Generate detailed recommendations (default)
    summary     Show summary statistics
    help        Show this help message

DESCRIPTION:
    Analyzes SID trigger statistics and provides intelligent
    recommendations for optimizing your Suricata ruleset.

RECOMMENDATION TYPES:
    ⚠️  False Positives   - Rules triggering excessively from few sources
    🔇 Noise Reduction   - Very noisy rules affecting many sources
    🛡️  Drop Mode        - Attack patterns that should be blocked
    ❌ Disable Rule      - Extremely problematic rules to disable

SEVERITY LEVELS:
    🔴 High    - Immediate action recommended
    🟡 Medium  - Should be addressed soon
    🟢 Low     - Optional optimization

EXAMPLES:
    # Generate detailed recommendations
    nftban suricata recommend

    # Show summary only
    nftban suricata recommend summary

WORKFLOW:
    1. Generate recommendations: nftban suricata recommend
    2. Review high severity items first
    3. Investigate: nftban suricata sid info <SID>
    4. Apply fixes: disable/modify rules as needed
    5. Monitor: nftban suricata sid top

ANALYSIS PATTERNS:
    - False Positive: 100+ triggers from 1-3 sources
    - Noise: 1000+ triggers, widespread sources, low ratio
    - Drop Mode: Attack patterns from many sources
    - Disable: 10,000+ triggers, very recent activity

NOTES:
    - Recommendations based on current statistics
    - Run after collecting data for at least 24 hours
    - Review recommendations before applying changes
    - Some "noisy" rules may be legitimate for your environment

EOF
            ;;
    esac
}

# =============================================================================
# HELP
# =============================================================================

cmd_suricata_help() {
    cat << 'EOF'

🛡️  NFTBan - Suricata IDS Management

USAGE:
    nftban suricata <command>

COMMANDS:
    install     Install Suricata IDS (automated)
    enable      Enable and start Suricata service
    disable     Stop and disable Suricata service
    status      Show Suricata status and recent alerts
    profile     Manage performance profiles (see: nftban suricata profile help)
    scan        Scan services and auto-configure (see: nftban suricata scan help)
    services    Manage service configuration (see: nftban suricata services help)
    rules       Manage Suricata rules (see: nftban suricata rules help)
    sid         SID statistics and analysis (see: nftban suricata sid help)
    custom      Manage custom rules (see: nftban suricata custom help)
    recommend   Get intelligent rule recommendations (see: nftban suricata recommend help)
    help        Show this help message

INSTALLATION PROCESS:
    1. Checks for package availability (EPEL/APT)
    2. Installs from packages OR compiles from source
    3. Downloads ET/Open ruleset (free)
    4. Configures for NFTBan integration
    5. Sets up systemd service

EXAMPLES:
    # Full automated setup (one command):
    nftban suricata install
    nftban suricata enable

    # Check status:
    nftban suricata status

    # Update rules:
    nftban suricata rules update

    # View live alerts:
    tail -f /var/log/nftban/suricata/eve-alerts.json | jq 'select(.event_type=="alert")'

REQUIREMENTS:
    - Root privileges (sudo)
    - EPEL repository (RHEL/Rocky) or standard repos (Debian/Ubuntu)
    - 2+ cores, 2+ GB RAM recommended
    - Python 3 + pip (for suricata-update)

PERFORMANCE:
    - CPU: 10-30% of 1 core (medium traffic)
    - RAM: 300-800 MB typical
    - Optimized for VPS/cloud environments

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
        custom)
            cmd_suricata_custom "$@"
            ;;
        recommend)
            cmd_suricata_recommend "$@"
            ;;
        help|--help|-h)
            cmd_suricata_help
            ;;
        *)
            echo "ERROR: Unknown command: $action"
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

# Export sub-commands for external access
export -f cmd_suricata_install
export -f cmd_suricata_enable
export -f cmd_suricata_disable
export -f cmd_suricata_status
export -f cmd_suricata_rules
export -f cmd_suricata_profile
export -f cmd_suricata_scan
export -f cmd_suricata_services
export -f cmd_suricata_sid
export -f cmd_suricata_custom
export -f cmd_suricata_recommend
export -f cmd_suricata_help

# Export helper functions
export -f _suricata_is_installed
export -f _suricata_is_running
export -f _suricata_is_enabled
export -f _check_root

# Execute if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_suricata "$@"
fi
