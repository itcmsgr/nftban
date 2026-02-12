#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="fhs-permissions"
# meta:type="setup"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Sets file permissions during package installation (GENERATED)"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
#
# WARNING: This file is GENERATED from build/fhs-spec.yaml - DO NOT EDIT
# Run: build/generate-fhs-outputs.sh

set -Eeuo pipefail

nftban_install_set_file_permissions() {
    # File permissions from FHS spec (single source of truth)

    # /etc/nftban - *.conf
    find "/etc/nftban" -type f -name "*.conf" -exec chown root:nftban {} \; 2>/dev/null || true
    find "/etc/nftban" -type f -name "*.conf" -exec chmod 0640 {} \; 2>/dev/null || true
    # /etc/nftban - *.local
    find "/etc/nftban" -type f -name "*.local" -exec chown root:nftban {} \; 2>/dev/null || true
    find "/etc/nftban" -type f -name "*.local" -exec chmod 0640 {} \; 2>/dev/null || true
    # /usr/lib/nftban - *.sh
    find "/usr/lib/nftban" -type f -name "*.sh" -exec chown root:root {} \; 2>/dev/null || true
    find "/usr/lib/nftban" -type f -name "*.sh" -exec chmod 0755 {} \; 2>/dev/null || true
    # /usr/lib/nftban/bin - *
    chown root:root "/usr/lib/nftban/bin"/* 2>/dev/null || true
    chmod 0755 "/usr/lib/nftban/bin"/* 2>/dev/null || true
    # Set capabilities: cap_net_admin+ep:nftban-core,nftband
    if command -v setcap &>/dev/null; then
        setcap "cap_net_admin+ep" "/usr/lib/nftban/bin/nftban-core" 2>/dev/null || true
    fi
    # /usr/lib/nftban/bin - *
    chown root:root "/usr/lib/nftban/bin"/* 2>/dev/null || true
    chmod 0755 "/usr/lib/nftban/bin"/* 2>/dev/null || true
    # Set capabilities: cap_net_admin+ep:nftban-core,nftband
    if command -v setcap &>/dev/null; then
        setcap "cap_net_admin+ep" "/usr/lib/nftban/bin/nftband" 2>/dev/null || true
    fi
    # /usr/lib/nftban/sbin - *
    chown root:root "/usr/lib/nftban/sbin"/* 2>/dev/null || true
    chmod 0755 "/usr/lib/nftban/sbin"/* 2>/dev/null || true
    # /usr/sbin - nftban*
    chown root:nftban "/usr/sbin"/nftban* 2>/dev/null || true
    chmod 0750 "/usr/sbin"/nftban* 2>/dev/null || true
    # /var/lib/nftban - *
    find "/var/lib/nftban" -type f -name "*" -not -path "/var/lib/nftban/reports/auditors/*" -exec chown nftban:nftban {} \; 2>/dev/null || true
    find "/var/lib/nftban" -type f -name "*" -not -path "/var/lib/nftban/reports/auditors/*" -exec chmod 0640 {} \; 2>/dev/null || true
    # /var/lib/nftban/reports/auditors - *
    find "/var/lib/nftban/reports/auditors" -type f -name "*" -exec chown root:nftban-auditor {} \; 2>/dev/null || true
    find "/var/lib/nftban/reports/auditors" -type f -name "*" -exec chmod 0660 {} \; 2>/dev/null || true
    # /var/log/nftban - *
    find "/var/log/nftban" -type f -name "*" -not -path "/var/log/nftban/suricata/*" -exec chown nftban:nftban {} \; 2>/dev/null || true
    find "/var/log/nftban" -type f -name "*" -not -path "/var/log/nftban/suricata/*" -exec chmod 0640 {} \; 2>/dev/null || true
    # /var/log/nftban/suricata - *
    find "/var/log/nftban/suricata" -type f -name "*" -exec chown suricata:nftban {} \; 2>/dev/null || true
    find "/var/log/nftban/suricata" -type f -name "*" -exec chmod 0640 {} \; 2>/dev/null || true

    # Set up auditor ACLs
    nftban_install_set_auditor_acls

    return 0
}

# =============================================================================
# AUDITOR ACL SETUP (not generated - manually maintained)
# =============================================================================
# Sets ACLs for nftban-auditor group read access to logs and reports.
# ACLs are required because:
#   - Base ownership (nftban:nftban) is needed for daemon writes
#   - Auditors need read-only access without write permissions
#   - ACLs layer on top of base permissions without changing ownership

nftban_install_set_auditor_acls() {
    # Check if setfacl is available
    if ! command -v setfacl &>/dev/null; then
        echo "[NFTBan] setfacl not available - auditor ACLs skipped (install acl package)" >&2
        return 0
    fi

    # Check if nftban-auditor group exists
    if ! getent group nftban-auditor &>/dev/null; then
        return 0  # Silent - group created later or not needed
    fi

    echo "[NFTBan] Setting up auditor ACLs..."

    # Log directory - traverse and read access
    if [[ -d /var/log/nftban ]]; then
        setfacl -m g:nftban-auditor:x /var/log/nftban 2>/dev/null || true
        # Read access on audit-relevant logs
        for logfile in bans.log login_monitor.log feeds.log nftban-actions.log ddos.log portscan.log; do
            [[ -f "/var/log/nftban/$logfile" ]] && setfacl -m g:nftban-auditor:r "/var/log/nftban/$logfile" 2>/dev/null || true
        done
    fi

    # Reports directory - traverse access to reach auditors/ subdir
    if [[ -d /var/lib/nftban ]]; then
        setfacl -m g:nftban-auditor:x /var/lib/nftban 2>/dev/null || true
        [[ -d /var/lib/nftban/reports ]] && setfacl -m g:nftban-auditor:x /var/lib/nftban/reports 2>/dev/null || true
        [[ -d /var/lib/nftban/reports/auditors ]] && setfacl -m g:nftban-auditor:rx /var/lib/nftban/reports/auditors 2>/dev/null || true
    fi

    echo "[NFTBan] Auditor ACLs configured"
    return 0
}

# Export for sourcing
export -f nftban_install_set_file_permissions
export -f nftban_install_set_auditor_acls
