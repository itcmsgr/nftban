#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.92.0 — Suricata Package Installer (Managed Deployment)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="install_suricata"
# meta:type="setup"
# meta:version="1.92.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-04-16"
# meta:description="Install Suricata IDS via package manager (no source build)"
# meta:inventory.files=""
# meta:inventory.binaries="suricata,suricata-update"
# meta:inventory.env_vars="SURICATA_UNMANAGED"
# meta:inventory.config_files="/etc/suricata/suricata.yaml"
# meta:inventory.systemd_units="suricata.service"
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================
#
# v1.92: Rewritten from 636-line source-build installer to package-only.
# NFTBan manages Suricata deployment correctness via package manager.
# Source builds are NOT supported — use SURICATA_UNMANAGED=true for custom installs.
#
# Architecture: V192_FINAL_ARCHITECTURE_DECISION.md
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

NFTBAN_LIB_DIR="${NFTBAN_LIB_DIR:-/usr/lib/nftban}"
NFTBAN_CONFIG_DIR="${NFTBAN_CONFIG_DIR:-/etc/nftban}"
NFTBAN_LOG_DIR="${NFTBAN_LOG_DIR:-/var/log/nftban}"

SURICATA_EVE_DIR="${NFTBAN_LOG_DIR}/suricata"
SURICATA_EVE_FILE="${SURICATA_EVE_DIR}/eve-alerts.json"
SURICATA_OVERLAY="${NFTBAN_CONFIG_DIR}/suricata/suricata.yaml.overlay"

# =============================================================================
# HELPERS
# =============================================================================

_log_info()  { echo "[NFTBan Suricata] $*"; }
_log_error() { echo "[NFTBan Suricata ERROR] $*" >&2; }
_log_warn()  { echo "[NFTBan Suricata WARN] $*" >&2; }

_detect_pkg_manager() {
    if command -v dnf &>/dev/null; then echo "dnf"
    elif command -v yum &>/dev/null; then echo "yum"
    elif command -v apt-get &>/dev/null; then echo "apt"
    else echo "unknown"
    fi
}

# =============================================================================
# INSTALL (package-only)
# =============================================================================

install_suricata_package() {
    local pkg_mgr
    pkg_mgr=$(_detect_pkg_manager)

    if command -v suricata &>/dev/null; then
        _log_info "Suricata already installed: $(suricata --build-info 2>/dev/null | head -1)"
        return 0
    fi

    _log_info "Installing Suricata via $pkg_mgr..."

    case "$pkg_mgr" in
        dnf|yum)
            # EPEL required for Suricata on RHEL family
            $pkg_mgr install -y epel-release 2>/dev/null || true
            $pkg_mgr install -y suricata suricata-update || {
                _log_error "Failed to install suricata package"
                return 1
            }
            ;;
        apt)
            # Add Suricata PPA for latest version on Ubuntu/Debian
            if command -v add-apt-repository &>/dev/null; then
                add-apt-repository -y ppa:oisf/suricata-stable 2>/dev/null || true
            fi
            apt-get update -qq
            apt-get install -y suricata suricata-update || {
                _log_error "Failed to install suricata package"
                return 1
            }
            ;;
        *)
            _log_error "Unsupported package manager: $pkg_mgr"
            _log_error "Install Suricata manually and set SURICATA_UNMANAGED=true"
            return 1
            ;;
    esac

    _log_info "Suricata installed: $(suricata -V 2>&1 | head -1)"
}

# =============================================================================
# CONFIGURE (IDS-only, EVE output for NFTBan)
# =============================================================================

configure_suricata_ids() {
    _log_info "Configuring Suricata for IDS mode..."

    # Create EVE log directory
    mkdir -p "$SURICATA_EVE_DIR"
    chown suricata:nftban "$SURICATA_EVE_DIR" 2>/dev/null || chown suricata:suricata "$SURICATA_EVE_DIR"
    chmod 750 "$SURICATA_EVE_DIR"

    # Apply overlay if not already included
    local suricata_conf="/etc/suricata/suricata.yaml"
    if [[ -f "$suricata_conf" ]] && [[ -f "$SURICATA_OVERLAY" ]]; then
        if ! grep -q "nftban" "$suricata_conf" 2>/dev/null; then
            _log_info "Adding NFTBan overlay include to suricata.yaml..."
            echo "" >> "$suricata_conf"
            echo "# NFTBan integration overlay" >> "$suricata_conf"
            echo "include: $SURICATA_OVERLAY" >> "$suricata_conf"
        else
            _log_info "NFTBan overlay already configured"
        fi
    fi

    # Run initial rule update
    if command -v suricata-update &>/dev/null; then
        _log_info "Running initial rule update..."
        suricata-update 2>/dev/null || _log_warn "Rule update failed — run manually: suricata-update"
    fi

    _log_info "Suricata configured for IDS mode"
}

# =============================================================================
# SERVICE MANAGEMENT
# =============================================================================

start_suricata_service() {
    _log_info "Enabling and starting Suricata service..."

    systemctl enable suricata.service 2>/dev/null || true
    systemctl start suricata.service 2>/dev/null || {
        _log_error "Failed to start suricata.service"
        _log_error "Check: journalctl -u suricata.service"
        return 1
    }

    sleep 2
    if systemctl is-active --quiet suricata.service; then
        _log_info "Suricata service running"
    else
        _log_warn "Suricata service not active after start"
    fi
}

stop_suricata_service() {
    systemctl stop suricata.service 2>/dev/null || true
    systemctl disable suricata.service 2>/dev/null || true
    _log_info "Suricata service stopped and disabled"
}

# =============================================================================
# MAIN ENTRY POINTS
# =============================================================================

# Full managed install: package + config + start
suricata_managed_install() {
    if [[ "${SURICATA_UNMANAGED:-false}" == "true" ]]; then
        _log_info "SURICATA_UNMANAGED=true — skipping managed install"
        _log_info "NFTBan will only read EVE logs from your Suricata deployment"
        return 0
    fi

    install_suricata_package || return 1
    configure_suricata_ids || return 1
    start_suricata_service || return 1

    _log_info "Suricata managed install complete"
    _log_info "Verify: nftban suricata verify"
}

# Disable: stop service, keep package
suricata_managed_disable() {
    stop_suricata_service
    _log_info "Suricata disabled (package retained)"
}

# Status check
suricata_managed_status() {
    echo "Suricata Managed Deployment Status"
    echo "==================================="
    echo ""

    if [[ "${SURICATA_UNMANAGED:-false}" == "true" ]]; then
        echo "  Mode: UNMANAGED (user manages Suricata)"
    else
        echo "  Mode: MANAGED (NFTBan manages Suricata)"
    fi

    if command -v suricata &>/dev/null; then
        echo "  Installed: yes ($(suricata -V 2>&1 | head -1))"
    else
        echo "  Installed: no"
    fi

    if systemctl is-active --quiet suricata.service 2>/dev/null; then
        echo "  Service: active"
    else
        echo "  Service: inactive"
    fi

    if [[ -f "$SURICATA_EVE_FILE" ]]; then
        echo "  EVE log: $SURICATA_EVE_FILE ($(wc -l < "$SURICATA_EVE_FILE") lines)"
    elif [[ -f /var/log/suricata/eve.json ]]; then
        echo "  EVE log: /var/log/suricata/eve.json ($(wc -l < /var/log/suricata/eve.json) lines)"
    else
        echo "  EVE log: not found"
    fi
}
