#!/usr/bin/env bash
# =============================================================================
# NFTBan Uninstall Script
# =============================================================================
# Purpose: Complete removal of NFTBan from system
# Usage: ./uninstall.sh [--purge]
#        --purge: Remove ALL data including configs, logs, and databases
# =============================================================================

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log()   { echo -e "${BLUE}[UNINSTALL]${NC} $*"; }
ok()    { echo -e "${GREEN}[  OK   ]${NC} $*"; }
warn()  { echo -e "${YELLOW}[ WARN  ]${NC} $*"; }
error() { echo -e "${RED}[ ERROR ]${NC} $*"; }

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Parse options
PURGE_DATA=false
if [[ "${1:-}" == "--purge" ]]; then
    PURGE_DATA=true
fi

# =============================================================================
# LOAD SCHEMA FOR TABLE/SET NAMES
# =============================================================================

load_schema() {
    if [[ -f "$SCRIPT_DIR/cli/lib/nftban/lib/nft_schema.sh" ]]; then
        source "$SCRIPT_DIR/cli/lib/nftban/lib/nft_schema.sh"
        ok "Loaded NFT schema"
    else
        warn "NFT schema not found, using fallback table names"
        # Fallback definitions
        export NFTBAN_TABLE_IPV4="ip nftban"
        export NFTBAN_TABLE_IPV6="ip6 nftban"
    fi
}

# =============================================================================
# LOAD DISTRO CONFIG FOR SERVICE NAMES
# =============================================================================

load_distro_config() {
    if [[ -f "$SCRIPT_DIR/cli/lib/nftban/lib/nftban_distro_config.sh" ]]; then
        export NFTBAN_DISTRO_CONF_DIR="$SCRIPT_DIR/etc/nftban/distros"
        source "$SCRIPT_DIR/cli/lib/nftban/lib/nftban_distro_config.sh"

        if nftban_distro_init; then
            ok "Loaded distro config: ${DISTRO_INFO[name]} ${DISTRO_INFO[version]}"
        else
            warn "Failed to load distro config, using defaults"
        fi
    else
        warn "Distro config system not found, using defaults"
    fi
}

# =============================================================================
# UNINSTALL FUNCTIONS
# =============================================================================

uninstall_services() {
    log "Stopping and disabling NFTBan services..."

    # List of service patterns to remove
    local service_patterns=(
        "nftban-*.service"
        "nftban-*.timer"
    )

    local stopped=0

    # Find and stop all NFTBan services
    for pattern in "${service_patterns[@]}"; do
        # Get list of matching units
        local units
        units=$(systemctl list-units --all --no-legend "$pattern" 2>/dev/null | awk '{print $1}' || true)

        for unit in $units; do
            [[ -z "$unit" ]] && continue

            # Stop service
            if systemctl is-active --quiet "$unit" 2>/dev/null; then
                echo "  Stopping: $unit"
                systemctl stop "$unit" 2>/dev/null || true
                stopped=$((stopped + 1))
            fi

            # Disable service
            if systemctl is-enabled --quiet "$unit" 2>/dev/null; then
                echo "  Disabling: $unit"
                systemctl disable "$unit" 2>/dev/null || true
            fi
        done
    done

    if [[ $stopped -gt 0 ]]; then
        ok "Stopped $stopped service(s)"
    else
        ok "No running services found"
    fi
}

uninstall_systemd_units() {
    log "Removing systemd units..."

    local removed=0

    # Remove service and timer files
    for file in /etc/systemd/system/nftban-*.service /etc/systemd/system/nftban-*.timer; do
        if [[ -f "$file" ]]; then
            echo "  Removing: $(basename "$file")"
            rm -f "$file"
            removed=$((removed + 1))
        fi
    done

    # Reload systemd
    if [[ $removed -gt 0 ]]; then
        systemctl daemon-reload
        ok "Removed $removed systemd unit(s)"
    else
        ok "No systemd units found"
    fi
}

uninstall_binaries() {
    log "Removing binaries..."

    local removed=0
    local binaries=(
        "/usr/bin/nftban"
        "/usr/sbin/nftban-ui"
        "/usr/libexec/nftban-ui-auth"
        "/usr/lib/nftban"
    )

    for binary in "${binaries[@]}"; do
        if [[ -e "$binary" ]]; then
            echo "  Removing: $binary"
            rm -rf "$binary"
            removed=$((removed + 1))
        fi
    done

    if [[ $removed -gt 0 ]]; then
        ok "Removed $removed binary/library location(s)"
    else
        ok "No binaries found"
    fi
}

uninstall_bash_completion() {
    log "Removing bash completion..."

    if [[ -f "/usr/share/bash-completion/completions/nftban" ]]; then
        rm -f /usr/share/bash-completion/completions/nftban
        ok "Bash completion removed"
    else
        ok "No bash completion found"
    fi
}

uninstall_nftables() {
    log "Removing nftables rules..."

    local removed=0

    # Use schema-defined table names
    local tables=("${NFTBAN_TABLE_IPV4}" "${NFTBAN_TABLE_IPV6}")

    for table in "${tables[@]}"; do
        if nft list table "$table" >/dev/null 2>&1; then
            echo "  Deleting table: $table"
            nft delete table "$table" 2>/dev/null || true
            removed=$((removed + 1))
        fi
    done

    if [[ $removed -gt 0 ]]; then
        ok "Removed $removed nftables table(s)"
    else
        ok "No NFTBan nftables found"
    fi

    # Remove nftables.conf if it looks like NFTBan's
    if [[ -f "/etc/nftables.conf" ]] && grep -q "NFTBan" /etc/nftables.conf 2>/dev/null; then
        warn "NFTBan nftables.conf found at /etc/nftables.conf"
        echo "    Leaving in place (may contain user modifications)"
        echo "    Remove manually if needed: sudo rm /etc/nftables.conf"
    fi
}

uninstall_polkit() {
    log "Removing polkit policies..."

    if [[ -f "/usr/share/polkit-1/actions/com.nftban.auth.policy" ]]; then
        rm -f /usr/share/polkit-1/actions/com.nftban.auth.policy
        ok "Polkit policy removed"
    else
        ok "No polkit policy found"
    fi
}

uninstall_configs() {
    if [[ "$PURGE_DATA" == true ]]; then
        log "Purging configuration files..."

        if [[ -d "/etc/nftban" ]]; then
            echo "  Removing: /etc/nftban"
            rm -rf /etc/nftban
            ok "Configuration directory purged"
        else
            ok "No configuration directory found"
        fi
    else
        log "Keeping configuration files..."
        echo "    Config directory: /etc/nftban"
        echo "    (Use --purge to remove)"
        ok "Configuration preserved"
    fi
}

uninstall_data() {
    if [[ "$PURGE_DATA" == true ]]; then
        log "Purging data directories..."

        local data_dirs=(
            "/var/lib/nftban"
            "/var/log/nftban"
            "/var/cache/nftban"
        )

        local removed=0

        for dir in "${data_dirs[@]}"; do
            if [[ -d "$dir" ]]; then
                echo "  Removing: $dir"
                rm -rf "$dir"
                removed=$((removed + 1))
            fi
        done

        if [[ $removed -gt 0 ]]; then
            ok "Purged $removed data directory/directories"
        else
            ok "No data directories found"
        fi
    else
        log "Keeping data directories..."
        echo "    Data: /var/lib/nftban"
        echo "    Logs: /var/log/nftban"
        echo "    Cache: /var/cache/nftban"
        echo "    (Use --purge to remove)"
        ok "Data preserved"
    fi
}

# =============================================================================
# MAIN UNINSTALL LOGIC
# =============================================================================

echo ""
log "════════════════════════════════════════════════════════════"
log "  NFTBan Uninstall"
log "════════════════════════════════════════════════════════════"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
    echo "Try: sudo $0 ${1:-}"
    exit 1
fi

# Show mode
if [[ "$PURGE_DATA" == true ]]; then
    warn "PURGE MODE: All data will be removed"
else
    log "STANDARD MODE: Configs and data will be preserved"
    echo "    Use --purge to remove everything"
fi
echo ""

# Confirmation
if [[ "$PURGE_DATA" == true ]]; then
    warn "⚠️  WARNING: This will remove ALL NFTBan files and data"
    echo ""
    echo "This includes:"
    echo "  • All binaries and libraries"
    echo "  • All configuration files (/etc/nftban)"
    echo "  • All data and logs (/var/lib/nftban, /var/log/nftban)"
    echo "  • All nftables rules (tables: ip nftban, ip6 nftban)"
    echo "  • All systemd services"
    echo ""
    read -p "Type 'YES' to confirm purge: " confirm

    if [[ "$confirm" != "YES" ]]; then
        echo "Cancelled."
        exit 0
    fi
    echo ""
fi

# Load configurations
load_schema
load_distro_config
echo ""

# Execute uninstall steps
uninstall_services
echo ""

uninstall_systemd_units
echo ""

uninstall_binaries
echo ""

uninstall_bash_completion
echo ""

uninstall_nftables
echo ""

uninstall_polkit
echo ""

uninstall_configs
echo ""

uninstall_data
echo ""

# Summary
log "════════════════════════════════════════════════════════════"
if [[ "$PURGE_DATA" == true ]]; then
    ok "NFTBan completely removed (purged)"
    echo ""
    echo "✅ All NFTBan components have been removed"
else
    ok "NFTBan uninstalled (data preserved)"
    echo ""
    echo "✅ NFTBan binaries and services removed"
    echo "📁 Configuration and data preserved:"
    echo "   • /etc/nftban (configs)"
    echo "   • /var/lib/nftban (data)"
    echo "   • /var/log/nftban (logs)"
    echo ""
    echo "To completely remove everything:"
    echo "   sudo $0 --purge"
fi
echo ""
log "════════════════════════════════════════════════════════════"
