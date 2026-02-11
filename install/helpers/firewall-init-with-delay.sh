#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.0.0 - Firewall Init Helper (systemd-safe)
# =============================================================================
# meta:name="firewall_init_with_delay"
# meta:type="script"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Initialize firewall with optional startup delay"
# meta:inventory.files=""
# meta:inventory.binaries="nft"
# meta:inventory.env_vars="NFTBAN_STARTUP_DELAY"
# meta:inventory.config_files="/etc/nftban/nftban.conf"
# meta:inventory.systemd_units="nftban-firewall-init.service"
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================
#
# SECURITY: This script is called directly by systemd to prevent command
# injection via EnvironmentFile variable interpolation. Variables are
# validated before use.
#
# =============================================================================

set -Eeuo pipefail

# Load configuration from file
if [[ -f /etc/nftban/nftban.conf ]]; then
    # Source config file (safe - we validate before use)
    # shellcheck disable=SC1091
    source /etc/nftban/nftban.conf
fi

# Get startup delay (default: 0 seconds)
DELAY="${NFTBAN_STARTUP_DELAY:-0}"

# CRITICAL: Validate delay is a non-negative integer (prevents injection)
# This blocks: "0 ]; rm -rf /", "$(whoami)", "`id`", etc.
if ! [[ "$DELAY" =~ ^[0-9]+$ ]]; then
    echo "ERROR: NFTBAN_STARTUP_DELAY must be a non-negative integer, got: $DELAY" >&2
    echo "       Defaulting to 0 (no delay)" >&2
    DELAY=0  # Fallback to safe default
fi

# Load IPC library if available
# shellcheck source=/dev/null
source /usr/lib/nftban/lib/nft_ipc.sh 2>/dev/null || true

# Optional: Load snapshot if delay is disabled
# This provides fast firewall activation on boot
if [[ "$DELAY" -eq 0 ]]; then
    if [[ -f /var/lib/nftban/snapshots/last.nft ]]; then
        echo "Loading snapshot (delay=0)..." >&2
        # Try IPC first (if daemon is ready), fallback to direct nft
        if type -t nft_ipc_apply_ruleset &>/dev/null && [[ -S /run/nftban/nftband.sock ]]; then
            nft_ipc_apply_ruleset /var/lib/nftban/snapshots/last.nft 2>/dev/null || true
        elif command -v nft >/dev/null 2>&1; then
            # Boot-time fallback: daemon not ready yet, use direct nft
            # This is safe because we're loading our own snapshot
            nft -f /var/lib/nftban/snapshots/last.nft 2>/dev/null || true
        fi
    fi
fi

# Find nftban CLI binary (verify config or auto-detect)
# Config may have NFTBAN_BIN but path might be wrong for this distro
if [[ -n "${NFTBAN_BIN:-}" ]] && [[ -x "$NFTBAN_BIN" ]]; then
    : # Config-provided path exists and is executable
elif [[ -x /usr/sbin/nftban ]]; then
    NFTBAN_BIN="/usr/sbin/nftban"
elif [[ -x /usr/bin/nftban ]]; then
    NFTBAN_BIN="/usr/bin/nftban"
else
    echo "ERROR: nftban CLI not found in /usr/sbin or /usr/bin" >&2
    exit 1
fi

# Initialize firewall via CLI
# Command: "nftban init" (forwards to nftban-core for safety-first initialization)
# Note: Pipe 'y' for non-interactive systemd context (auto-confirm whitelist)
# If delay=0: run in background for fast boot
# If delay>0: run synchronously so delay happens before firewall loads
if [[ "$DELAY" -eq 0 ]]; then
    # No delay: run in background for fast boot
    echo "Initializing firewall (background, no delay)..." >&2
    echo "y" | "$NFTBAN_BIN" init &
else
    # With delay: sleep first, then initialize
    echo "Waiting ${DELAY}s before firewall initialization (troubleshooting window)..." >&2
    sleep "$DELAY"
    echo "Initializing firewall now..." >&2
    echo "y" | "$NFTBAN_BIN" init
fi

exit 0
