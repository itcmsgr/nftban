#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0 - Suricata IDS CLI Command - Setup Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Install, enable, disable, and status commands for Suricata
#
# meta:name="cmd_suricata_setup"
# meta:type="submodule"
# meta:version="1.0.0"
# meta:description="Install, enable, disable, and status commands for Suricata"
# meta:parent="cmd_suricata.sh"
#
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# Loaded by: cmd_suricata.sh (inherits strict mode)
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_CMD_SURICATA_SETUP_LOADED:-}" ]] && return 0
_CMD_SURICATA_SETUP_LOADED="true"

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

    # Check if rules exist, download if missing (like GeoIP auto-download)
    local rules_dir="${SURICATA_RULES_DIR}"
    local rule_count=0
    if [[ -d "$rules_dir" ]]; then
        rule_count=$(find "$rules_dir" -name "*.rules" -type f 2>/dev/null | wc -l)
    fi

    if [[ "$rule_count" -eq 0 ]]; then
        echo "  → No rules found, downloading initial ruleset..."
        echo "    (This may take a moment)"

        # Update sources and download rules
        if command -v suricata-update &>/dev/null; then
            suricata-update update-sources --quiet 2>/dev/null || true
            if suricata-update --quiet 2>/dev/null; then
                local new_count
                new_count=$(find "$rules_dir" -name "*.rules" -type f 2>/dev/null | wc -l)
                echo "  ✓ Downloaded $new_count rule files"
            else
                echo "  ⚠ Warning: Failed to download rules"
                echo "    Suricata will start but may have limited detection"
                echo "    Run manually: suricata-update"
            fi
        else
            echo "  ⚠ Warning: suricata-update not found"
            echo "    Install it to enable automatic rule updates"
        fi
    else
        echo "  ✓ Found $rule_count rule files"
    fi

    # Verify suricata.yaml uses correct rule path (fix Debian/Ubuntu default)
    local suricata_yaml="${DISTRO_PATHS[suricata_yaml]}"
    if [[ -f "$suricata_yaml" ]]; then
        local yaml_rules_path
        yaml_rules_path=$(grep -E "^default-rule-path:" "$suricata_yaml" 2>/dev/null | awk '{print $2}' | tr -d '"' || echo "")
        if [[ -n "$yaml_rules_path" ]] && [[ "$yaml_rules_path" != "$rules_dir" ]]; then
            echo "  → Fixing rule path in suricata.yaml..."
            echo "    Was: $yaml_rules_path"
            echo "    Now: $rules_dir"
            sed -i "s|^default-rule-path:.*|default-rule-path: $rules_dir|" "$suricata_yaml"
            echo "  ✓ Rule path updated"
        fi
    fi

    # Configure EVE output to nftban path (critical for integration)
    local eve_log="${DISTRO_PATHS[suricata_eve_log]:-/var/log/nftban/suricata/eve-alerts.json}"
    local eve_dir
    eve_dir=$(dirname "$eve_log")

    # Create EVE directory with correct permissions
    if [[ ! -d "$eve_dir" ]]; then
        echo "  → Creating EVE log directory..."
        mkdir -p "$eve_dir"
        chmod 750 "$eve_dir"
        # Use nftban group for access
        chown root:nftban "$eve_dir" 2>/dev/null || chown root:root "$eve_dir"
        echo "  ✓ Created $eve_dir"
    fi

    # Check if EVE output is configured to nftban path
    if [[ -f "$suricata_yaml" ]]; then
        local current_eve
        current_eve=$(grep -A10 'eve-log:' "$suricata_yaml" 2>/dev/null | grep 'filename:' | head -1 | awk '{print $2}' | tr -d '"' || echo "")

        if [[ "$current_eve" == "eve.json" ]] || [[ "$current_eve" != "$eve_log" && -n "$current_eve" ]]; then
            echo "  → Configuring EVE output path..."
            echo "    Was: ${current_eve:-eve.json}"
            echo "    Now: $eve_log"
            # Update filename in eve-log section (handles indented YAML)
            sed -i "/eve-log:/,/^[^ ]/ s|filename:.*|filename: $eve_log|" "$suricata_yaml"
            echo "  ✓ EVE output configured for nftban integration"
        fi
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

    # Rules status - check both file count AND actual loaded rules
    echo ""
    echo "  Rules:"
    local rules_loaded=0
    local rule_file_count=0

    # Check rules_loaded from EVE JSON stats (most accurate)
    if [[ -f /var/log/suricata/eve.json ]]; then
        rules_loaded=$(grep -o '"rules_loaded":[0-9]*' /var/log/suricata/eve.json 2>/dev/null | tail -1 | cut -d: -f2 || echo "0")
    elif [[ -f /var/log/nftban/suricata/eve-alerts.json ]]; then
        rules_loaded=$(grep -o '"rules_loaded":[0-9]*' /var/log/nftban/suricata/eve-alerts.json 2>/dev/null | tail -1 | cut -d: -f2 || echo "0")
    fi

    # Count rule files
    if [[ -d "${SURICATA_RULES_DIR}" ]]; then
        rule_file_count=$(find "${SURICATA_RULES_DIR}" -name "*.rules" -type f 2>/dev/null | wc -l)
    fi

    # Display status with color coding
    if [[ "${rules_loaded:-0}" -eq 0 ]]; then
        echo "    ❌ Rules Loaded:   ${RED:-}0 (NO PROTECTION!)${NC:-}"
        echo "    ⚠  FIX:           suricata-update && systemctl restart suricata"
    else
        echo "    ✓  Rules Loaded:   ${GREEN:-}${rules_loaded}${NC:-}"
    fi
    echo "    Rule Files:        $rule_file_count"
    echo "    Rules Directory:   ${SURICATA_RULES_DIR}/"

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
# EXPORTS
# =============================================================================

export -f cmd_suricata_install
export -f cmd_suricata_enable
export -f cmd_suricata_disable
export -f cmd_suricata_status
