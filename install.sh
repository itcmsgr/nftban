#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.98.x - Installation Bootstrap (≤20-line entry point)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Thin bootstrap that hands off to the Go installer for source install
#
# meta:name="nftban_install"
# meta:type="cli"
# meta:header="NFTBan Installer Bootstrap"
# meta:version="1.98.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Thin bootstrap: root+Linux preflight, locate nftban-installer, exec --source"
# meta:input="CLI args forwarded to nftban-installer"
# meta:output="Exec'd nftban-installer process (see /var/log/nftban/installer.log)"
# meta:depends="bash"
# meta:created_date="2025-10-26"
# meta:updated_date="2026-04-19"
#
# meta:inventory.files=""
# meta:inventory.binaries="nftban-installer"
# meta:inventory.env_vars="NFTBAN_SOURCE_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# =============================================================================
# PR-14: bootstrap reduction
#
# Previously 401 lines of orchestration (install_dependencies,
# create_users_groups, install_core, install_cli, install_libraries,
# install_completion, install_configs, install_nftables, install_tmpfiles,
# install_polkit, install_logrotate, install_systemd, download_geoip_database,
# auto-enable-features, ...).
#
# All of that logic now lives in the Go installer's phaseDetect/Prepare/Switch/
# Configure/Validate with the --source flag (PR-14-pre / PR #462). This
# bootstrap is a thin handoff: preflight checks + locate the installer
# binary + exec.
#
# Non-goals (strict — review rejects violations):
#   - No installer logic (users/groups, payload copy, systemd enable, etc.)
#   - No fallback logic ("if Go fails, do X the old way")
#   - No config decisions (sed/interactive prompts)
#   - No lifecycle branching (detect install vs upgrade — Go does that)
#   - No authority expansion (systemctl disable, package removal, nft flushes)
# =============================================================================

set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo "Error: install.sh must run as root" >&2; exit 1; }
[[ "$(uname -s)" == "Linux" ]] || { echo "Error: Linux only" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$SCRIPT_DIR/bin/nftban-installer"
[[ -x "$INSTALLER" ]] || INSTALLER="/usr/lib/nftban/bin/nftban-installer"
[[ -x "$INSTALLER" ]] || {
    echo "Error: nftban-installer not found." >&2
    echo "Run: $SCRIPT_DIR/install/download-binaries.sh" >&2
    exit 1
}

export NFTBAN_SOURCE_DIR="$SCRIPT_DIR"
exec "$INSTALLER" --source --mode=install "$@"
