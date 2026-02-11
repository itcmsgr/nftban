#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Security & Capability Helper
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_security"
# meta:type="core"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Provides capability checking functions for CAP_NET_ADMIN"
# meta:inventory.files=""
# meta:inventory.binaries="nft"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_SECURITY_LOADED:-}" ]] && return 0
readonly NFTBAN_SECURITY_LOADED=1

# =============================================================================
# CAPABILITY CHECKING FUNCTIONS
# =============================================================================

# Check if current process has CAP_NET_ADMIN capability
# Returns: 0 if capability present, 1 otherwise
nftban_has_net_admin() {
    # Method 1: Preferred - harmless read-only query through nft
    # This works regardless of how capability was granted (ambient, file, etc.)
    #
    # PERFORMANCE FIX: Use 'nft -t list tables' (terse mode) instead of 'nft list tables'
    # Reason: With large feed sets (5000+ IPs), 'list tables' dumps ALL table contents
    #         including all IP addresses, taking 30+ seconds and 100% CPU.
    #         Terse mode only lists table names, completing in <0.1 seconds.
    # Impact: CAP_NET_ADMIN check goes from 30s to 0.1s
    if command -v nft >/dev/null 2>&1; then
        if nft -t list tables >/dev/null 2>&1; then
            return 0
        fi
    fi

    # Method 2: Check CapEff bitmask for CAP_NET_ADMIN
    # CAP_NET_ADMIN is bit 12 in Linux capabilities (0x0000000000001000 in hex)
    # See: linux/capability.h
    if [[ -r /proc/self/status ]]; then
        local hexbits
        hexbits="$(awk '/^CapEff:/ {print $2}' /proc/self/status 2>/dev/null || true)"
        if [[ -n "${hexbits:-}" ]]; then
            # Check if CAP_NET_ADMIN bit is set (bit 12 = 0x1000)
            if (( 0x$hexbits & 0x0000000000001000 )); then
                return 0
            fi
        fi
    fi

    return 1
}

# Require CAP_NET_ADMIN or exit with clear error message
# Usage: nftban_require_net_admin_or_exit
nftban_require_net_admin_or_exit() {
    if ! nftban_has_net_admin; then
        cat <<'ERR' >&2

╔════════════════════════════════════════════════════════════╗
║  ERROR: CAP_NET_ADMIN capability required                 ║
╚════════════════════════════════════════════════════════════╝

NFTBan requires the Linux CAP_NET_ADMIN capability to manage
nftables firewall rules.

RECOMMENDED SOLUTION (service-scoped capability):
  Ensure the systemd service grants CAP_NET_ADMIN:

  [Service]
  User=nftban
  Group=nftban
  AmbientCapabilities=CAP_NET_ADMIN
  CapabilityBoundingSet=CAP_NET_ADMIN

TEMPORARY WORKAROUND (not recommended):
  Run the command as root:

  sudo nftban [command]

DOCUMENTATION:
  See /usr/share/nftban/docs/README.capabilities for details
  on NFTBan's capability-based security model.

SECURITY NOTE:
  NFTBan uses service-scoped capabilities instead of running
  as root, following the principle of least privilege. This
  grants ONLY network administration capability, not full
  root access.

ERR
        exit 1
    fi
}

# Check if running as root (for operations that genuinely need root)
# Usage: nftban_require_root_or_exit "operation description"
nftban_require_root_or_exit() {
    local operation="${1:-this operation}"

    if [[ $EUID -ne 0 ]]; then
        cat <<ERR >&2

ERROR: Root privileges required for ${operation}

This operation requires root access because it modifies system-level
resources outside of NFTBan's data directories.

Run as root:
  sudo nftban [command]

ERR
        exit 1
    fi
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_has_net_admin
export -f nftban_require_net_admin_or_exit
export -f nftban_require_root_or_exit
