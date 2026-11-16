#!/usr/bin/env bash
# =============================================================================
# NFTBan - FHS exact-entry policy (GENERATED)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="fhs-state-policy"
# meta:type="setup"
# meta:header="FHS exact-entry policy"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Restores owner and mode of the exact file_permissions entries (exact: true) IN PLACE: chown -h / chmod, inode and held locks kept; regular files or directories only (directories never recursive), never through a symlink, only when the parent is root-owned and closed to group/other writes. Sourced (function definitions only, no shell options changed) by fhs-permissions.sh, nftban_permissions.sh perms_enforce_var_files and helpers/autoheal.sh. GENERATED"
# meta:inventory.files="/var/lib/nftban/state"
# meta:inventory.binaries="chown,chmod,stat"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# WARNING: This file is GENERATED from build/fhs-spec.yaml - DO NOT EDIT
# Run: build/generate-fhs-outputs.sh
# =============================================================================

# Parent of PATH is root-owned and not writable by group/other (else nothing is touched: the
# directory policy must establish the boundary first, so no entry can be swapped mid-repair).
_nftban_fhs_parent_root_closed() {
    local d u m
    d=$(dirname -- "$1")
    read -r u m < <(stat -c '%u %a' -- "$d" 2>/dev/null) || return 1
    [[ "$u" == 0 ]] && (( (8#${m:-777} & 8#022) == 0 ))
}

# _nftban_fhs_exact TYPE OWNER:GROUP MODE PATH
_nftban_fhs_exact() {
    local t="$1" og="$2" m="$3" p="$4"
    [[ -e "$p" || -L "$p" ]] || return 0
    if ! _nftban_fhs_parent_root_closed "$p"; then
        echo "fhs-state-policy: skipped $p (parent not root-owned or writable by group/other)" >&2
        return 0
    fi
    # A declared entry is never a link. One planted while the parent was writable by the service
    # account could redirect a later root write, so it is removed (the link only, never its target).
    if [[ -L "$p" ]]; then
        rm -f -- "$p" && echo "fhs-state-policy: removed symlink at declared entry $p" >&2
        return 0
    fi
    case "$t" in
        file) [[ -f "$p" ]] || return 0 ;;
        dir)  [[ -d "$p" ]] || return 0 ;;
        *)    return 0 ;;
    esac
    chown -h "$og" -- "$p" 2>/dev/null || true
    [[ -L "$p" ]] || chmod "$m" -- "$p" 2>/dev/null || true
}

nftban_fhs_enforce_exact_entries() {
    # directories first, then files
    _nftban_fhs_exact dir root:root 0700 "/var/lib/nftban/state/applied"
    _nftban_fhs_exact dir root:root 0700 "/var/lib/nftban/state/commit-confirm"
    _nftban_fhs_exact file root:root 0600 "/var/lib/nftban/state/legacy-backup-migration.state"
    _nftban_fhs_exact file root:root 0600 "/var/lib/nftban/state/installer.lock"
    _nftban_fhs_exact file root:root 0600 "/var/lib/nftban/state/commit-confirm.lock"
    _nftban_fhs_exact file root:nftban 0640 "/var/lib/nftban/state/commit-confirm.state"
    _nftban_fhs_exact file root:nftban 0640 "/var/lib/nftban/state/commit-confirm.rollback-failed"
    _nftban_fhs_exact file root:nftban 0640 "/var/lib/nftban/state/install_state"
    _nftban_fhs_exact file root:nftban 0640 "/var/lib/nftban/state/authority"
    _nftban_fhs_exact file root:nftban 0640 "/var/lib/nftban/state/feed_authority"
    _nftban_fhs_exact file root:nftban 0640 "/var/lib/nftban/state/immutable-owned"
    _nftban_fhs_exact file root:nftban 0640 "/var/lib/nftban/state/permanent_bans.json"
    _nftban_fhs_exact file root:nftban 0640 "/var/lib/nftban/state/ssh_port_active.state"
    _nftban_fhs_exact file root:nftban 0640 "/var/lib/nftban/state/ip_change_alert.state"
    _nftban_fhs_exact file root:nftban 0640 "/var/lib/nftban/state/firewall_transition_health.json"
    _nftban_fhs_exact file root:nftban 0640 "/var/lib/nftban/state/ruleset_fingerprint.json"
    return 0
}
