#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="generate_polkit_rules"
# meta:type="helper"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Generate polkit rules from templates using central config values"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""

set -Eeuo pipefail

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
[[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" ]] && source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf"

# Paths
readonly NFTBAN_CONF="${NFTBAN_CONF:-${NFTBAN_CONFIG_DIR}/nftban.conf}"
readonly POLKIT_RULES_DIR="${POLKIT_RULES_DIR:-/usr/share/polkit-1/rules.d}"
readonly TEMPLATE_DIR="${1:-/usr/share/nftban/polkit-templates}"

# Colors
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_ok() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

# =============================================================================
# MAIN
# =============================================================================

main() {
    # Load central config
    if [[ -f "$NFTBAN_CONF" ]]; then
        # shellcheck source=/dev/null
        source "$NFTBAN_CONF"
    else
        log_warn "Config not found: $NFTBAN_CONF - using defaults"
    fi

    # Ensure required variables are set (use defaults if not in config)
    : "${NFTBAN_BIN:=/usr/sbin/nftban}"
    : "${NFTBAN_AUTH_BIN:=/usr/libexec/nftban-ui-auth}"

    # Ensure output directory exists
    mkdir -p "$POLKIT_RULES_DIR"

    # Generate 50-nftban-port-status.rules
    local port_template="$TEMPLATE_DIR/50-nftban-port-status.rules.in"
    if [[ -f "$port_template" ]]; then
        sed "s|@NFTBAN_BIN@|$NFTBAN_BIN|g" "$port_template" \
            > "$POLKIT_RULES_DIR/50-nftban-port-status.rules"
        chmod 644 "$POLKIT_RULES_DIR/50-nftban-port-status.rules"
        log_ok "Generated: 50-nftban-port-status.rules (NFTBAN_BIN=$NFTBAN_BIN)"
    else
        log_warn "Template not found: $port_template"
    fi

    # Generate 50-nftban-auth.rules
    local auth_template="$TEMPLATE_DIR/50-nftban-auth.rules.in"
    if [[ -f "$auth_template" ]]; then
        sed "s|@NFTBAN_AUTH_BIN@|$NFTBAN_AUTH_BIN|g" "$auth_template" \
            > "$POLKIT_RULES_DIR/50-nftban-auth.rules"
        chmod 644 "$POLKIT_RULES_DIR/50-nftban-auth.rules"
        log_ok "Generated: 50-nftban-auth.rules (NFTBAN_AUTH_BIN=$NFTBAN_AUTH_BIN)"
    else
        log_warn "Template not found: $auth_template"
    fi

    # Restart polkit to apply changes
    if command -v systemctl &>/dev/null; then
        systemctl restart polkit 2>/dev/null || log_warn "Failed to restart polkit"
    fi

    log_ok "Polkit rules generated successfully"
}

main "$@"
