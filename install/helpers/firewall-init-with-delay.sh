#!/bin/bash
# =============================================================================
# NFTBan Firewall Init Helper (systemd-safe)
# =============================================================================
# Purpose: Initialize firewall with optional startup delay
# Called by: systemd (nftban-firewall-init.service)
# Runs as: root
#
# SECURITY: This script is called directly by systemd to prevent command
# injection via EnvironmentFile variable interpolation. Variables are
# validated before use.
# =============================================================================

set -euo pipefail

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

# Optional: Load snapshot if delay is disabled
# This provides fast firewall activation on boot
if [[ "$DELAY" -eq 0 ]]; then
    if command -v nft >/dev/null 2>&1; then
        if [[ -f /var/lib/nftban/snapshots/last.nft ]]; then
            echo "Loading snapshot (delay=0)..." >&2
            nft -f /var/lib/nftban/snapshots/last.nft 2>/dev/null || true
        fi
    fi
fi

# Initialize firewall via CLI
# If delay=0: run in background for fast boot
# If delay>0: run synchronously so delay happens before firewall loads
if [[ "$DELAY" -eq 0 ]]; then
    # No delay: run in background for fast boot
    echo "Initializing firewall (background, no delay)..." >&2
    /usr/sbin/nftban firewall init &
else
    # With delay: run synchronously
    echo "Initializing firewall (synchronous, delay=${DELAY}s)..." >&2
    /usr/sbin/nftban firewall init
fi

exit 0
