#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.100 PR-P2-3 — CI kernel/service snapshot helper
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="ci-snapshot-kernel-service"
# meta:type="script"
# meta:version="1.100.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-04-20"
# meta:description="Emit stable before/after snapshot of nft tables + firewall-adjacent service states"
# meta:inventory.files="scripts/ci-snapshot-kernel-service.sh"
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units="nftband.service, ufw.service, firewalld.service, csf.service, lfd.service, iptables.service"
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================
#
# Prints a deterministic, line-oriented snapshot of:
#
#   1. Kernel nftables tables (`nft list tables`, sorted)
#   2. Firewall-adjacent systemd unit states (nftband + every external
#      firewall unit the lifecycle may interact with)
#
# Used by CI gates to assert that dry-run paths leave kernel and
# service state unchanged. The caller captures the output twice
# (before + after the dry-run) and fails CI if the two snapshots
# differ.
#
# Degrades gracefully on container environments that lack nft or
# systemctl — both sides of the comparison emit the same placeholder,
# so diff remains empty for environments that cannot probe.
#
# Contract (PR-P2-3, frozen 2026-04-20):
#   - Output is stable (sorted) and purely from read-only probes.
#   - Never invokes nft / systemctl with mutation verbs.
#   - Never writes to the filesystem.
#   - Exit code 0 always; the CALLER decides whether differences fail.
#
# =============================================================================
set -Eeuo pipefail

# PR-P2-3 monitored-units: every unit that is either owned by nftban or
# represents an external firewall the lifecycle code touches. Kept in
# lockstep with internal/installer/extfw/detect.go so the CI gate and
# the production detector agree on "what counts as a firewall service."
UNITS=(
    nftband.service
    ufw.service
    firewalld.service
    csf.service
    lfd.service
    iptables.service
)

echo "## kernel-nft-tables"
if command -v nft >/dev/null 2>&1; then
    # Redirect stderr so a missing kernel module doesn't pollute the
    # snapshot with different messages across before/after invocations.
    sudo nft list tables 2>/dev/null | sort || echo "nft:exec_failed"
else
    echo "nft:not_installed"
fi

echo "## service-states"
if command -v systemctl >/dev/null 2>&1 && systemctl --version >/dev/null 2>&1; then
    for u in "${UNITS[@]}"; do
        # Always emit "unit=state" for every monitored unit — even
        # inactive/missing — so both sides of the before/after diff
        # produce the same lines unless state actually changes.
        # `is-active` exits non-zero for inactive; we capture the
        # string and swallow the exit code intentionally.
        state=$(systemctl is-active "$u" 2>&1 || true)
        echo "$u=$state"
    done
else
    echo "systemctl:not_available"
fi
