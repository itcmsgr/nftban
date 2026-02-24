#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.3.0 - Update Command Backup Functions
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Backup and rollback functions for update command
#
# meta:name="cmd_update_backup"
# meta:type="cli"
# meta:header="Update Command Backup"
# meta:version="1.3.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Backup and rollback functions for update command"
# meta:depends="cmd_update.sh,cmd_update_helpers.sh,cmd_update_detection.sh"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="nftban"
# meta:created_date="2026-02-04"
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_NFTBAN_CLI_UPDATE_BACKUP_LOADED:-}" ]] && return 0
_NFTBAN_CLI_UPDATE_BACKUP_LOADED=1

# =============================================================================
# BACKUP & ROLLBACK
# =============================================================================

_create_backup() {
    local current_version
    current_version=$(_get_current_version)
    local backup_name
    backup_name="nftban-${current_version}-$(date '+%Y%m%d-%H%M%S')"
    local backup_path="${UPDATE_BACKUP_DIR}/${backup_name}.tar.gz"

    mkdir -p "$UPDATE_BACKUP_DIR" 2>/dev/null || {
        _update_log WARN "Backup failed: Cannot create backup directory $UPDATE_BACKUP_DIR"
        return 1
    }

    _update_log INFO "Creating backup..."

    # Check what directories exist to backup
    local backup_dirs=()
    [[ -d /usr/lib/nftban ]] && backup_dirs+=("usr/lib/nftban")
    [[ -f /usr/sbin/nftban ]] && backup_dirs+=("usr/sbin/nftban")
    [[ -d /etc/nftban ]] && backup_dirs+=("etc/nftban")

    if [[ ${#backup_dirs[@]} -eq 0 ]]; then
        _update_log WARN "Backup failed: No NFTBan directories found to backup"
        return 1
    fi

    local tar_output
    if tar_output=$(tar -czf "$backup_path" -C / "${backup_dirs[@]}" 2>&1); then
        _update_log OK "Backup: $backup_name"

        # Cleanup old backups
        local count=0
        while IFS= read -r -d '' old_backup; do
            count=$((count + 1))
            if [[ $count -gt $NFTBAN_UPDATE_BACKUP_COUNT ]]; then
                rm -f "$old_backup"
            fi
        done < <(find "$UPDATE_BACKUP_DIR" -maxdepth 1 -name "nftban-*.tar.gz" -print0 2>/dev/null | sort -rzV)

        return 0
    else
        _update_log WARN "Backup failed: ${tar_output:-tar command failed}"
        return 1
    fi
}

_do_rollback() {
    _update_log INFO "Looking for backups..."

    if [[ ! -d "$UPDATE_BACKUP_DIR" ]]; then
        _update_log ERROR "No backup directory found"
        return 1
    fi

    # Find latest backup
    local latest_backup=""
    while IFS= read -r -d '' f; do
        latest_backup="$f"
        break
    done < <(find "$UPDATE_BACKUP_DIR" -maxdepth 1 -name "nftban-*.tar.gz" -print0 2>/dev/null | sort -rzV)

    if [[ -z "$latest_backup" ]]; then
        _update_log ERROR "No backups found"
        return 1
    fi

    _update_log INFO "Rolling back to: $(basename "$latest_backup" .tar.gz)"

    # Fix broken dpkg state before rollback (interrupted installs leave dpkg broken)
    _fix_broken_dpkg || {
        _update_log WARN "Could not fully repair dpkg state, attempting rollback anyway"
    }

    # Remove immutable flags from ALL nftban files that would block rollback extraction
    _remove_immutable_flags

    if tar -xzf "$latest_backup" -C / 2>&1; then
        _update_log OK "Rollback successful"

        # After file rollback, fix dpkg database if this was a deb install
        if command -v dpkg &>/dev/null; then
            local pkg_status
            pkg_status=$(dpkg -l nftban 2>/dev/null | tail -1 | awk '{print $1}') || true
            if [[ -n "$pkg_status" ]] && [[ "$pkg_status" != "ii" ]]; then
                _update_log INFO "Repairing dpkg package database after rollback..."
                dpkg --configure -a 2>&1 | while read -r line; do echo "    $line"; done || true
            fi
        fi

        return 0
    else
        _update_log ERROR "Rollback failed"
        return 1
    fi
}

_list_backups() {
    echo ""
    echo "Available backups:"
    echo ""

    if [[ ! -d "$UPDATE_BACKUP_DIR" ]]; then
        echo "  No backups found"
        return 1
    fi

    local count=0
    while IFS= read -r -d '' backup; do
        count=$((count + 1))
        local name size
        name=$(basename "$backup" .tar.gz)
        size=$(du -h "$backup" | cut -f1)
        echo "  [$count] $name ($size)"
    done < <(find "$UPDATE_BACKUP_DIR" -maxdepth 1 -name "nftban-*.tar.gz" -print0 2>/dev/null | sort -rzV)

    if [[ $count -eq 0 ]]; then
        echo "  No backups found"
        return 1
    fi

    echo ""
    return 0
}

