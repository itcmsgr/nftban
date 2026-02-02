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

# Load Suricata rules helper
if [[ -f "${NFTBAN_LIB_DIR}/helpers/suricata_rules.sh" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR}/helpers/suricata_rules.sh"
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
    shift || true

    case "$action" in
        status)
            # Use helper function
            _suricata_rules_status "false"
            ;;

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

            # Create backup before update
            echo "  → Creating backup..."
            _suricata_backup_rules >/dev/null

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

        rollback)
            local backup_name="${1:-}"
            if [[ -z "$backup_name" ]]; then
                echo "ERROR: Backup name required"
                echo ""
                echo "Usage: nftban suricata rules rollback <BACKUP_NAME>"
                echo ""
                echo "List backups with: nftban suricata rules list-backups"
                return 1
            fi
            _suricata_rules_rollback "$backup_name" "false"
            ;;

        list-backups|backups)
            _suricata_rules_list_backups "false"
            ;;

        apply)
            _suricata_rules_apply "false"
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

📜 Suricata Rules Management

USAGE:
    nftban suricata rules <command>

COMMANDS:
    status        Show ruleset status (counts, last update, sources)
    update        Update rules from ET/Open (requires root)
    rollback      Restore from a backup (requires root)
    list-backups  List available rule backups
    apply         Apply pending changes (run suricata-update + reload)
    generate      Generate enabled.list from service scan (requires root)
    stats         Show rules statistics (calls Go backend)
    init          Initialize configuration files
    list          List installed rule files
    help          Show this help message

WORKFLOW:
    1. Check status:     nftban suricata rules status
    2. Make changes:     nftban suricata sid disable <SID>
                         nftban suricata category enable emerging-malware
    3. Apply changes:    nftban suricata rules apply
    4. Verify:           nftban suricata rules status

BACKUP & ROLLBACK:
    # List available backups
    nftban suricata rules list-backups

    # Rollback to a specific backup
    nftban suricata rules rollback 20260202-120000

    Backups are created automatically before any rule changes.

EXAMPLES:
    # Show current ruleset status
    nftban suricata rules status

    # Update to latest ET/Open rules
    nftban suricata rules update

    # Apply local changes (SID/category modifications)
    nftban suricata rules apply

NOTES:
    - Rules are updated automatically via systemd timer (weekly)
    - All changes write to NFTBan config files (never vendor files)
    - Backups are kept in /etc/nftban/suricata/state/last-good/
    - Last 10 backups are retained

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
        enable)
            local sid="${1:-}"
            if [[ -z "$sid" ]]; then
                echo "ERROR: SID required"
                echo ""
                echo "Usage: nftban suricata sid enable <SID>"
                return 1
            fi
            _suricata_sid_enable "$sid" "false"
            ;;

        disable)
            local sid="${1:-}"
            if [[ -z "$sid" ]]; then
                echo "ERROR: SID required"
                echo ""
                echo "Usage: nftban suricata sid disable <SID>"
                return 1
            fi
            _suricata_sid_disable "$sid" "false"
            ;;

        list)
            local type="${1:-all}"
            _suricata_sid_list "$type" "false"
            ;;

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

🔢 Suricata SID Management

USAGE:
    nftban suricata sid <command>

COMMANDS:
    enable <SID>    Force-enable a specific SID (add to enable.conf)
    disable <SID>   Disable a specific SID (add to disable.conf)
    list [type]     List SID overrides (enabled, disabled, or all)
    stats           Show overall SID statistics summary
    info <SID>      Show detailed information for a specific SID
    top             Show top 20 most triggered SIDs
    recent          Show SIDs triggered in last 24 hours
    help            Show this help message

ENABLING/DISABLING RULES:
    # Disable a noisy or false-positive rule
    nftban suricata sid disable 2100498

    # Force-enable a rule from a disabled category
    nftban suricata sid enable 2024792

    # List all overrides
    nftban suricata sid list

    # Apply changes
    nftban suricata rules apply

WORKFLOW:
    1. Identify problematic SID:   nftban suricata sid top
    2. Get details:                nftban suricata sid info 2100498
    3. Disable it:                 nftban suricata sid disable 2100498
    4. Apply changes:              nftban suricata rules apply

CONFIG FILES:
    Enable:  /etc/nftban/suricata/rules/enable.conf
    Disable: /etc/nftban/suricata/rules/disable.conf

    These files are processed by suricata-update:
    - enable.conf overrides disable.conf
    - Individual SIDs override category settings

EXAMPLES:
    # Disable a false-positive rule
    nftban suricata sid disable 2100498

    # Enable a rule from disabled category
    nftban suricata sid enable 2024792

    # View all disabled SIDs
    nftban suricata sid list disabled

NOTES:
    - Changes require 'nftban suricata rules apply' to take effect
    - Backups are created automatically before changes
    - SID overrides persist across ruleset updates

EOF
            ;;
    esac
}

# =============================================================================
# COMMAND: category (Rule Category Management)
# =============================================================================

cmd_suricata_category() {
    local action="${1:-help}"
    shift || true

    case "$action" in
        list)
            _suricata_category_list "false"
            ;;

        enable)
            local category="${1:-}"
            if [[ -z "$category" ]]; then
                echo "ERROR: Category name required"
                echo ""
                echo "Usage: nftban suricata category enable <CATEGORY>"
                echo ""
                echo "List categories with: nftban suricata category list"
                return 1
            fi
            _suricata_category_set "$category" "enabled" "false"
            ;;

        disable)
            local category="${1:-}"
            if [[ -z "$category" ]]; then
                echo "ERROR: Category name required"
                echo ""
                echo "Usage: nftban suricata category disable <CATEGORY>"
                echo ""
                echo "List categories with: nftban suricata category list"
                return 1
            fi
            _suricata_category_set "$category" "disabled" "false"
            ;;

        help|*)
            cat << 'EOF'

📂 Suricata Rule Category Management

USAGE:
    nftban suricata category <command>

COMMANDS:
    list              List all categories with their status
    enable <CAT>      Enable a rule category
    disable <CAT>     Disable a rule category
    help              Show this help message

CATEGORY NAMES:
    Common ET Open categories:
    - emerging-malware      Core malware detection
    - emerging-trojan       Trojan/RAT detection
    - emerging-exploit      Exploit attempts
    - emerging-scan         Port scanning/reconnaissance
    - emerging-dos          DoS/DDoS attacks
    - emerging-web_server   Web server attacks
    - emerging-web_client   Client-side attacks
    - emerging-dns          DNS-based threats
    - emerging-policy       Policy violations (noisy)
    - emerging-tor          Tor exit node detection

WORKFLOW:
    # List current category status
    nftban suricata category list

    # Disable noisy policy rules
    nftban suricata category disable emerging-policy

    # Enable SQL injection detection
    nftban suricata category enable emerging-sql

    # Apply changes
    nftban suricata rules apply

EXAMPLES:
    # Disable all policy rules (reduces noise)
    nftban suricata category disable emerging-policy

    # Enable VOIP rules (if you run SIP/VOIP)
    nftban suricata category enable emerging-voip

    # Disable FTP rules (if you don't use FTP)
    nftban suricata category disable emerging-ftp

CONFIG FILE:
    /etc/nftban/suricata/rules/categories.enabled

    Format: category-name = enabled|disabled

NOTES:
    - Changes require 'nftban suricata rules apply' to take effect
    - Individual SID overrides take precedence over categories
    - Disabling unused categories improves performance

EOF
            ;;
    esac
}

# =============================================================================
# COMMAND: local (Local User Rules Management)
# =============================================================================

cmd_suricata_local() {
    local action="${1:-help}"
    shift || true

    case "$action" in
        list)
            _suricata_local_list "false"
            ;;

        add)
            local rule="$*"
            if [[ -z "$rule" ]]; then
                echo "ERROR: Rule required"
                echo ""
                echo "Usage: nftban suricata local add '<RULE>'"
                echo ""
                echo "Example:"
                echo "  nftban suricata local add 'alert tcp any any -> any 22 (msg:\"SSH probe\"; sid:1000001; rev:1;)'"
                echo ""
                echo "SID Range: 1000000-1999999 for user rules"
                return 1
            fi
            _suricata_local_add "$rule" "false"
            ;;

        remove)
            local sid="${1:-}"
            if [[ -z "$sid" ]]; then
                echo "ERROR: SID required"
                echo ""
                echo "Usage: nftban suricata local remove <SID>"
                return 1
            fi
            _suricata_local_remove "$sid" "false"
            ;;

        edit)
            local file="${NFTBAN_SURICATA_DIR:-/etc/nftban/suricata}/rules/local.rules"
            if [[ ! -f "$file" ]]; then
                echo "ERROR: Local rules file not found"
                echo "Create rules first with: nftban suricata local add '<rule>'"
                return 1
            fi
            echo ""
            echo "Opening local rules file in editor..."
            echo "File: $file"
            echo ""
            echo "SID Ranges:"
            echo "  1000000-1999999: User local rules (edit this section)"
            echo "  9000000-9999999: NFTBan auto-generated (DO NOT EDIT)"
            echo ""
            "${EDITOR:-vi}" "$file"
            echo ""
            echo "Don't forget to apply changes:"
            echo "  nftban suricata rules apply"
            echo ""
            ;;

        help|*)
            cat << 'EOF'

📝 Local User Rules Management

USAGE:
    nftban suricata local <command>

COMMANDS:
    list          List local user rules
    add <RULE>    Add a new local rule
    remove <SID>  Remove a local rule by SID
    edit          Open local.rules in editor
    help          Show this help message

SID RANGE:
    User local rules MUST use SID range: 1000000-1999999
    (NFTBan auto-generated rules use: 9000000-9999999)

RULE SYNTAX:
    action protocol src_ip src_port -> dst_ip dst_port (options)

    Actions: alert, drop, reject, pass
    Protocol: tcp, udp, icmp, ip

EXAMPLES:
    # Add a rule to detect SSH brute force
    nftban suricata local add 'alert tcp any any -> any 22 (msg:"SSH brute force attempt"; threshold:type both, track by_src, count 5, seconds 60; sid:1000001; rev:1;)'

    # Add a rule to log outbound DNS queries
    nftban suricata local add 'alert udp any any -> any 53 (msg:"DNS query"; sid:1000002; rev:1;)'

    # List current rules
    nftban suricata local list

    # Remove a rule
    nftban suricata local remove 1000001

    # Edit rules manually
    nftban suricata local edit

WORKFLOW:
    1. Add rule:    nftban suricata local add '<rule>'
    2. Verify:      nftban suricata local list
    3. Apply:       nftban suricata rules apply
    4. Monitor:     nftban suricata sid info 1000001

CONFIG FILE:
    /etc/nftban/suricata/rules/local.rules

NOTES:
    - Rules are validated on add (basic syntax check)
    - Changes require 'nftban suricata rules apply' to take effect
    - User rules section is preserved during updates
    - For NFTBan-managed rules, use 'nftban suricata custom'

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
# COMMAND: eve (EVE JSON Log Management)
# =============================================================================

# Helper: Load EVE path from config
_eve_get_path() {
    # Try central config variable first
    if [[ -n "${NFTBAN_SURICATA_EVE_LOG:-}" ]]; then
        echo "$NFTBAN_SURICATA_EVE_LOG"
        return
    fi

    # Try loading from config files
    local config_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf"
    local local_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf.local"

    if [[ -f "$local_conf" ]]; then
        local val
        val=$(grep -E "^NFTBAN_SURICATA_EVE_LOG=" "$local_conf" 2>/dev/null | cut -d'"' -f2 || true)
        [[ -n "$val" ]] && { echo "$val"; return; }
    fi

    if [[ -f "$config_file" ]]; then
        local val
        val=$(grep -E "^NFTBAN_SURICATA_EVE_LOG=" "$config_file" 2>/dev/null | cut -d'"' -f2 || true)
        [[ -n "$val" ]] && { echo "$val"; return; }
    fi

    # Default path
    echo "/var/log/nftban/suricata/eve-alerts.json"
}

# Helper: Format bytes to human readable
_eve_format_bytes() {
    local bytes="$1"
    if command -v numfmt &>/dev/null; then
        numfmt --to=iec --suffix=B "$bytes" 2>/dev/null || echo "${bytes}B"
    else
        if [[ $bytes -ge 1073741824 ]]; then
            echo "$(( bytes / 1073741824 ))GB"
        elif [[ $bytes -ge 1048576 ]]; then
            echo "$(( bytes / 1048576 ))MB"
        elif [[ $bytes -ge 1024 ]]; then
            echo "$(( bytes / 1024 ))KB"
        else
            echo "${bytes}B"
        fi
    fi
}

# Helper: Format time difference to human readable
_eve_format_age() {
    local seconds="$1"
    if [[ $seconds -lt 60 ]]; then
        echo "${seconds}s ago"
    elif [[ $seconds -lt 3600 ]]; then
        echo "$(( seconds / 60 ))m $(( seconds % 60 ))s ago"
    elif [[ $seconds -lt 86400 ]]; then
        echo "$(( seconds / 3600 ))h $(( (seconds % 3600) / 60 ))m ago"
    else
        echo "$(( seconds / 86400 ))d $(( (seconds % 86400) / 3600 ))h ago"
    fi
}

cmd_suricata_eve_check() {
    # Color definitions (use globals if available, fallback to local)
    local C_RESET="${NFTBAN_COLOR_RESET:-\033[0m}"
    local C_BOLD="${NFTBAN_COLOR_BOLD:-\033[1m}"
    local C_RED="${NFTBAN_COLOR_RED:-\033[31m}"
    local C_GREEN="${NFTBAN_COLOR_GREEN:-\033[32m}"
    local C_YELLOW="${NFTBAN_COLOR_YELLOW:-\033[33m}"
    local C_CYAN="${NFTBAN_COLOR_CYAN:-\033[36m}"
    local C_DIM="${NFTBAN_COLOR_DIM:-\033[2m}"

    # Disable colors if not a terminal
    if [[ ! -t 1 ]] || [[ "${NO_COLOR:-}" == "1" ]]; then
        C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_CYAN="" C_DIM=""
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  📋 Suricata EVE JSON Health Check"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    local eve_path
    eve_path=$(_eve_get_path)

    # -------------------------------------------------------------------------
    # Section 1: File Information
    # -------------------------------------------------------------------------
    echo -e "${C_BOLD}EVE File Information${C_RESET}"
    echo "─────────────────────────────────────────────────────────"
    echo -e "  Path:          ${C_CYAN}${eve_path}${C_RESET}"

    # Check file exists
    if [[ ! -e "$eve_path" ]]; then
        echo -e "  Status:        ${C_RED}✗ FILE NOT FOUND${C_RESET}"
        echo ""
        echo -e "${C_YELLOW}Troubleshooting:${C_RESET}"
        echo "  1. Ensure Suricata is installed: nftban suricata status"
        echo "  2. Check if Suricata is running: systemctl status suricata"
        echo "  3. Verify EVE output in Suricata config"
        echo "  4. Check log directory exists: ls -la /var/log/nftban/suricata/"
        echo ""
        return 1
    fi

    # Check readable
    if [[ ! -r "$eve_path" ]]; then
        echo -e "  Status:        ${C_RED}✗ NOT READABLE${C_RESET} (permission denied)"
        echo ""
        echo -e "${C_YELLOW}Fix:${C_RESET}"
        echo "  sudo chmod 640 $eve_path"
        echo "  sudo chown suricata:nftban $eve_path"
        echo ""
        return 1
    fi

    echo -e "  Status:        ${C_GREEN}✓ EXISTS & READABLE${C_RESET}"

    # File stats
    local file_size file_mtime now age_seconds
    file_size=$(stat -c %s "$eve_path" 2>/dev/null || echo "0")
    file_mtime=$(stat -c %Y "$eve_path" 2>/dev/null || echo "0")
    now=$(date +%s)
    age_seconds=$(( now - file_mtime ))

    local mtime_human
    mtime_human=$(date -d "@$file_mtime" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -r "$file_mtime" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "unknown")

    echo -e "  Size:          ${C_BOLD}$(_eve_format_bytes "$file_size")${C_RESET}"
    echo -e "  Last Modified: ${mtime_human} ($(_eve_format_age "$age_seconds"))"

    # Staleness warning
    if [[ $age_seconds -gt 600 ]]; then
        echo -e "  ${C_YELLOW}⚠ File not updated in 10+ minutes - Suricata may be stalled${C_RESET}"
    elif [[ $age_seconds -gt 300 ]]; then
        echo -e "  ${C_YELLOW}⊘ File not updated in 5+ minutes${C_RESET}"
    else
        echo -e "  Activity:      ${C_GREEN}✓ Recently updated${C_RESET}"
    fi

    echo ""

    # -------------------------------------------------------------------------
    # Section 2: JSON Validity Check
    # -------------------------------------------------------------------------
    echo -e "${C_BOLD}JSON Validity${C_RESET}"
    echo "─────────────────────────────────────────────────────────"

    if [[ $file_size -eq 0 ]]; then
        echo -e "  Status:        ${C_YELLOW}⊘ FILE IS EMPTY${C_RESET}"
        echo "  (No events logged yet - this is normal for fresh installs)"
        echo ""
    else
        # Sample last 100 lines and check JSON validity
        local sample_lines=100
        local valid_count=0
        local invalid_count=0
        local total_sampled=0

        if command -v jq &>/dev/null; then
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                ((total_sampled++)) || true
                if echo "$line" | jq -e . &>/dev/null; then
                    ((valid_count++)) || true
                else
                    ((invalid_count++)) || true
                fi
            done < <(tail -n "$sample_lines" "$eve_path" 2>/dev/null)

            if [[ $total_sampled -eq 0 ]]; then
                echo -e "  Status:        ${C_YELLOW}⊘ NO DATA TO SAMPLE${C_RESET}"
            elif [[ $invalid_count -eq 0 ]]; then
                echo -e "  Status:        ${C_GREEN}✓ VALID${C_RESET} (${valid_count}/${total_sampled} lines OK)"
            elif [[ $invalid_count -lt 5 ]]; then
                echo -e "  Status:        ${C_YELLOW}⊘ MOSTLY VALID${C_RESET} (${valid_count} valid, ${invalid_count} invalid)"
                echo -e "  ${C_DIM}(Minor corruption may occur during log rotation)${C_RESET}"
            else
                echo -e "  Status:        ${C_RED}✗ INVALID JSON${C_RESET} (${invalid_count}/${total_sampled} lines corrupted)"
                echo -e "  ${C_YELLOW}Consider rotating or recreating the log file${C_RESET}"
            fi
        else
            # Fallback: basic JSON structure check without jq
            local first_char last_char
            first_char=$(tail -n 1 "$eve_path" 2>/dev/null | head -c 1)
            if [[ "$first_char" == "{" ]]; then
                echo -e "  Status:        ${C_GREEN}✓ APPEARS VALID${C_RESET} (jq not installed for full check)"
            else
                echo -e "  Status:        ${C_YELLOW}⊘ UNKNOWN${C_RESET} (install jq for validation)"
            fi
        fi
        echo ""
    fi

    # -------------------------------------------------------------------------
    # Section 3: Alert Counts by Time Window
    # -------------------------------------------------------------------------
    echo -e "${C_BOLD}Alert Statistics${C_RESET}"
    echo "─────────────────────────────────────────────────────────"

    if [[ $file_size -eq 0 ]]; then
        echo "  No alerts to analyze (file is empty)"
        echo ""
    elif ! command -v jq &>/dev/null; then
        echo -e "  ${C_YELLOW}⊘ jq not installed - cannot analyze alerts${C_RESET}"
        echo "  Install: sudo dnf install jq  OR  sudo apt install jq"
        echo ""
    else
        local now_epoch
        now_epoch=$(date +%s)
        local one_min_ago=$((now_epoch - 60))
        local five_min_ago=$((now_epoch - 300))
        local one_hour_ago=$((now_epoch - 3600))

        # Read recent portion of file (last 10000 lines for performance)
        local alerts_1m=0
        local alerts_5m=0
        local alerts_1h=0
        local total_alerts=0

        # Use a single pass through the file for efficiency
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue

            # Parse timestamp and check if it's an alert
            local ts event_type
            if ! ts=$(echo "$line" | jq -r '.timestamp // empty' 2>/dev/null); then
                continue
            fi
            event_type=$(echo "$line" | jq -r '.event_type // empty' 2>/dev/null)

            [[ "$event_type" != "alert" ]] && continue
            ((total_alerts++)) || true

            # Convert timestamp to epoch
            local event_epoch
            # Handle ISO 8601 format: 2024-01-15T10:30:00.123456+0000
            event_epoch=$(date -d "${ts}" +%s 2>/dev/null || echo "0")
            [[ "$event_epoch" == "0" ]] && continue

            if [[ $event_epoch -ge $one_min_ago ]]; then
                ((alerts_1m++)) || true
            fi
            if [[ $event_epoch -ge $five_min_ago ]]; then
                ((alerts_5m++)) || true
            fi
            if [[ $event_epoch -ge $one_hour_ago ]]; then
                ((alerts_1h++)) || true
            fi
        done < <(tail -n 10000 "$eve_path" 2>/dev/null)

        # Display with color coding
        local rate_1m rate_5m rate_1h
        rate_1m=$(echo "scale=1; $alerts_1m / 1" | bc 2>/dev/null || echo "$alerts_1m")
        rate_5m=$(echo "scale=1; $alerts_5m / 5" | bc 2>/dev/null || echo "$(( alerts_5m / 5 ))")
        rate_1h=$(echo "scale=1; $alerts_1h / 60" | bc 2>/dev/null || echo "$(( alerts_1h / 60 ))")

        # Color based on alert rate
        local c_1m="$C_GREEN" c_5m="$C_GREEN" c_1h="$C_GREEN"
        [[ $alerts_1m -gt 10 ]] && c_1m="$C_YELLOW"
        [[ $alerts_1m -gt 50 ]] && c_1m="$C_RED"
        [[ $alerts_5m -gt 50 ]] && c_5m="$C_YELLOW"
        [[ $alerts_5m -gt 200 ]] && c_5m="$C_RED"
        [[ $alerts_1h -gt 500 ]] && c_1h="$C_YELLOW"
        [[ $alerts_1h -gt 2000 ]] && c_1h="$C_RED"

        printf "  %-16s ${c_1m}%6d${C_RESET}  (%s/min)\n" "Last 1 minute:" "$alerts_1m" "$rate_1m"
        printf "  %-16s ${c_5m}%6d${C_RESET}  (%s/min avg)\n" "Last 5 minutes:" "$alerts_5m" "$rate_5m"
        printf "  %-16s ${c_1h}%6d${C_RESET}  (%s/min avg)\n" "Last 1 hour:" "$alerts_1h" "$rate_1h"

        if [[ $total_alerts -eq 0 ]]; then
            echo ""
            echo -e "  ${C_DIM}No alerts found in sampled data${C_RESET}"
        fi
        echo ""

        # -------------------------------------------------------------------------
        # Section 4: Top Signatures (Last 10 Minutes)
        # -------------------------------------------------------------------------
        echo -e "${C_BOLD}Top Signatures (Last 10 Minutes)${C_RESET}"
        echo "─────────────────────────────────────────────────────────"

        local ten_min_ago=$((now_epoch - 600))
        local sig_data

        # Extract signatures from last 10 minutes
        sig_data=$(tail -n 10000 "$eve_path" 2>/dev/null | \
            jq -r --argjson cutoff "$ten_min_ago" '
                select(.event_type == "alert") |
                select((.timestamp | sub("\\.[0-9]+.*"; "") | strptime("%Y-%m-%dT%H:%M:%S") | mktime) >= $cutoff) |
                "\(.alert.signature_id // "unknown")|\(.alert.signature // "Unknown Signature")"
            ' 2>/dev/null || echo "")

        if [[ -z "$sig_data" ]]; then
            echo "  No signatures triggered in last 10 minutes"
        else
            # Count and sort signatures
            echo "$sig_data" | sort | uniq -c | sort -rn | head -5 | while read -r count sig_info; do
                local sid sig_name
                sid=$(echo "$sig_info" | cut -d'|' -f1)
                sig_name=$(echo "$sig_info" | cut -d'|' -f2-)
                # Truncate long signature names
                [[ ${#sig_name} -gt 45 ]] && sig_name="${sig_name:0:42}..."
                printf "  ${C_CYAN}%5d${C_RESET}  [SID:%-8s] %s\n" "$count" "$sid" "$sig_name"
            done
        fi
        echo ""
    fi

    # -------------------------------------------------------------------------
    # Section 5: Quick Actions
    # -------------------------------------------------------------------------
    echo -e "${C_BOLD}Quick Actions${C_RESET}"
    echo "─────────────────────────────────────────────────────────"
    echo "  View live alerts:   tail -f $eve_path | jq 'select(.event_type==\"alert\")'"
    echo "  Top SIDs all time:  nftban suricata sid top"
    echo "  SID details:        nftban suricata sid info <SID>"
    echo "  Full status:        nftban suricata status"
    echo ""
}

cmd_suricata_eve() {
    local action="${1:-check}"
    shift || true

    case "$action" in
        check)
            cmd_suricata_eve_check
            ;;
        help|--help|-h)
            cat << 'EOF'

📋 Suricata EVE JSON Log Check

USAGE:
    nftban suricata eve [check]

COMMANDS:
    check       Check EVE JSON health and statistics (default)
    help        Show this help message

DESCRIPTION:
    Comprehensive health check for Suricata's EVE JSON log file.
    Validates file accessibility, JSON integrity, and provides
    alert statistics with time-based breakdowns.

WHAT IT CHECKS:
    - EVE file path from configuration
    - File existence and read permissions
    - Last write time and file size
    - JSON validity (samples last 100 lines)
    - Alert counts: last 1m, 5m, 1h
    - Top 5 signatures from last 10 minutes

EXAMPLES:
    # Run health check
    nftban suricata eve check

    # Or simply (check is default)
    nftban suricata eve

OUTPUT SECTIONS:
    1. EVE File Information
       - Path, status, size, last modified

    2. JSON Validity
       - Validates JSON structure of recent entries
       - Detects corruption from log rotation

    3. Alert Statistics
       - Time-windowed alert counts
       - Rate calculations (alerts/min)

    4. Top Signatures
       - Most triggered rules in last 10 minutes
       - Includes SID and signature name

COLOR CODING:
    Green   - Healthy / low activity
    Yellow  - Warning / moderate activity
    Red     - Issue / high activity

REQUIREMENTS:
    - jq (recommended for full functionality)
    - Read access to EVE log file

EOF
            ;;
        *)
            echo "ERROR: Unknown eve subcommand: $action"
            echo "Run 'nftban suricata eve help' for usage"
            return 1
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
    eve         EVE JSON log health check (see: nftban suricata eve help)
    profile     Manage performance profiles (see: nftban suricata profile help)
    scan        Scan services and auto-configure (see: nftban suricata scan help)
    services    Manage service configuration (see: nftban suricata services help)
    rules       Manage Suricata rules (see: nftban suricata rules help)
    category    Manage rule categories (see: nftban suricata category help)
    sid         SID enable/disable and stats (see: nftban suricata sid help)
    local       Manage local user rules (see: nftban suricata local help)
    custom      Manage nftban auto-rules (see: nftban suricata custom help)
    recommend   Get intelligent rule recommendations (see: nftban suricata recommend help)
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
    tail -f /var/log/nftban/suricata/eve-alerts.json | jq 'select(.event_type=="alert")'

REQUIREMENTS:
    - Root privileges (sudo)
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
