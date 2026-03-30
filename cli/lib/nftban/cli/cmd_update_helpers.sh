#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.3.0 - Update Command Helper Functions
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Helper functions for update command
#
# meta:name="cmd_update_helpers"
# meta:type="cli"
# meta:header="Update Command Helpers"
# meta:version="1.60.1"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Helper functions for update command (logging, dpkg repair, immutable flags)"
# meta:depends="cmd_update.sh"
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
[[ -n "${_NFTBAN_CLI_UPDATE_HELPERS_LOADED:-}" ]] && return 0
_NFTBAN_CLI_UPDATE_HELPERS_LOADED=1

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

_update_log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Log to file
    mkdir -p "$(dirname "$UPDATE_LOG_FILE")" 2>/dev/null || true
    echo "[$timestamp] [$level] $msg" >> "$UPDATE_LOG_FILE" 2>/dev/null || true

    # Output to terminal
    case "$level" in
        INFO)  echo "  $msg" ;;
        OK)    echo "  ✓ $msg" ;;
        WARN)  echo "  ⚠ $msg" ;;
        ERROR) echo "  ✗ $msg" >&2 ;;
    esac
}

_update_banner() {
    local current_ver
    current_ver=$(_get_current_version 2>/dev/null || echo "unknown")

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NFTBan Update (current: v${current_ver})"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

_fix_broken_dpkg() {
    # Fix broken dpkg state left by interrupted installs
    # Safe to call even when dpkg is healthy - it will be a no-op
    # Returns: 0 on success or no dpkg, 1 on failure to repair

    if ! command -v dpkg &>/dev/null; then
        return 0
    fi

    # Check if dpkg has interrupted/broken packages
    local dpkg_audit
    dpkg_audit=$(dpkg --audit 2>&1) || true

    local needs_configure=0

    # dpkg --audit outputs nothing when everything is clean
    if [[ -n "$dpkg_audit" ]]; then
        needs_configure=1
        _update_log WARN "Broken dpkg state detected"
        _update_log INFO "dpkg audit: $(echo "$dpkg_audit" | head -3)"
    fi

    # Also check for packages in an inconsistent state
    if dpkg -l nftban 2>/dev/null | grep -qE "^(iF|iU|iW|iH|.R|.H)"; then
        needs_configure=1
        _update_log WARN "NFTBan package in inconsistent dpkg state"
    fi
    if dpkg -l nftban-core 2>/dev/null | grep -qE "^(iF|iU|iW|iH|.R|.H)"; then
        needs_configure=1
        _update_log WARN "NFTBan-core package in inconsistent dpkg state"
    fi

    # Also check /var/lib/dpkg/updates for pending triggers
    if [[ -d /var/lib/dpkg/updates ]] && compgen -G "/var/lib/dpkg/updates/*" >/dev/null 2>&1; then
        needs_configure=1
        _update_log WARN "Pending dpkg updates found"
    fi

    if [[ "$needs_configure" -eq 1 ]]; then
        _update_log INFO "Running dpkg --configure -a to fix broken state..."
        if dpkg --configure -a 2>&1 | while read -r line; do echo "    $line"; done; then
            _update_log OK "dpkg state repaired"
            return 0
        else
            _update_log ERROR "dpkg --configure -a failed"
            _update_log INFO "Manual intervention may be needed: sudo dpkg --configure -a"
            return 1
        fi
    fi

    return 0
}

_remove_immutable_flags() {
    # Remove immutable (chattr +i) flags from ALL nftban files
    # This is needed before any install/update/rollback can modify files
    # Safe to call even if no immutable flags are set

    _update_log INFO "Removing immutable flags from nftban files..."

    # Locate chattr binary (may not be in minimal PATH during package operations)
    local chattr_bin
    chattr_bin=$(command -v chattr 2>/dev/null || echo "")
    if [[ -z "$chattr_bin" ]]; then
        for p in /usr/bin/chattr /bin/chattr /sbin/chattr /usr/sbin/chattr; do
            [[ -x "$p" ]] && chattr_bin="$p" && break
        done
    fi

    if [[ -z "$chattr_bin" ]]; then
        _update_log WARN "chattr not found - cannot remove immutable flags"
        return 0
    fi

    # Locate lsattr binary
    local lsattr_bin
    lsattr_bin=$(command -v lsattr 2>/dev/null || echo "")
    [[ -z "$lsattr_bin" ]] && for p in /usr/bin/lsattr /bin/lsattr; do
        [[ -x "$p" ]] && lsattr_bin="$p" && break
    done

    # Critical file that is known to be immutable
    local schema="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nft_schema.sh"

    # Helper to check if file has immutable flag
    _has_immutable() {
        local file="$1"
        [[ -z "$lsattr_bin" ]] && return 1
        [[ ! -f "$file" ]] && return 1
        # lsattr output: "----i--------e-- /path/to/file"
        # The 'i' at position 5 indicates immutable
        local attrs
        attrs=$("$lsattr_bin" "$file" 2>/dev/null | awk '{print $1}') || return 1
        [[ "${attrs:4:1}" == "i" ]]
    }

    # Remove immutable flag from the critical file first (most common failure point)
    if [[ -f "$schema" ]] && _has_immutable "$schema"; then
        local err
        if ! err=$("$chattr_bin" -i "$schema" 2>&1); then
            _update_log WARN "chattr -i failed on $schema: $err"
        fi
    fi

    local dirs_to_check=(
        "${NFTBAN_LIB_DIR:-/usr/lib/nftban}"
        "/usr/sbin/nftban"
        "${NFTBAN_CONFIG_DIR:-/etc/nftban}"
    )

    for path in "${dirs_to_check[@]}"; do
        if [[ -e "$path" ]]; then
            if [[ -d "$path" ]]; then
                # Use find to locate immutable files and remove flag individually
                # This is more reliable than -R which can fail silently
                if [[ -n "$lsattr_bin" ]]; then
                    while IFS= read -r -d '' file; do
                        "$chattr_bin" -i "$file" 2>/dev/null || true
                    done < <(find "$path" -type f -print0 2>/dev/null)
                else
                    # Fallback: brute-force recursive removal
                    "$chattr_bin" -i -R "$path" 2>/dev/null || true
                fi
            else
                "$chattr_bin" -i "$path" 2>/dev/null || true
            fi
        fi
    done

    # Verify the critical file is no longer immutable
    if [[ -f "$schema" ]]; then
        if _has_immutable "$schema"; then
            _update_log WARN "Immutable flag on nft_schema.sh persists, retrying with verbose..."
            # Final attempt - show actual error
            local err
            err=$("$chattr_bin" -i "$schema" 2>&1) || true
            [[ -n "$err" ]] && _update_log WARN "chattr output: $err"

            if _has_immutable "$schema"; then
                _update_log ERROR "Cannot remove immutable flag from $schema"
                _update_log ERROR "Possible causes:"
                _update_log ERROR "  - Filesystem doesn't support extended attributes"
                _update_log ERROR "  - File is on a read-only mount"
                _update_log ERROR "  - SELinux/AppArmor policy blocking"
                _update_log ERROR "Run manually: chattr -i $schema"
                # Don't fail - let dpkg try anyway, it might work
                return 0
            fi
        fi
        _update_log OK "Immutable flags cleared"
    else
        _update_log INFO "No immutable files found"
    fi
}

_load_config() {
    if [[ -f "$UPDATE_CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$UPDATE_CONFIG_FILE" || true
    fi
}

_update_write_history() {
    # Write update result to JSON history file (keep last 20 entries)
    # Args: $1=from_version $2=to_version $3=status(ok|fail) $4=install_type $5=duration_secs
    local from_ver="$1" to_ver="$2" status="$3" install_type="$4" duration="$5"
    local history_file="${NFTBAN_DATA_DIR:-/var/lib/nftban}/update-history.json"
    local hostname_val
    hostname_val=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "unknown")
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    local new_entry
    new_entry=$(printf '{"timestamp":"%s","from":"%s","to":"%s","status":"%s","type":"%s","duration_s":%s,"host":"%s"}' \
        "$ts" "$from_ver" "$to_ver" "$status" "$install_type" "$duration" "$hostname_val")

    mkdir -p "$(dirname "$history_file")" 2>/dev/null || true

    if command -v jq &>/dev/null && [[ -f "$history_file" ]] && jq empty "$history_file" 2>/dev/null; then
        # Prepend new entry + keep last 20
        local tmp_hist
        tmp_hist=$(mktemp "${history_file}.XXXXXX") || return 0
        jq --argjson entry "$new_entry" '[$entry] + . | .[0:20]' "$history_file" > "$tmp_hist" 2>/dev/null && \
            mv -f "$tmp_hist" "$history_file" || rm -f "$tmp_hist"
    else
        # First entry or no jq — write single-element array
        printf '[%s]\n' "$new_entry" > "$history_file" 2>/dev/null || true
    fi
    chmod 0640 "$history_file" 2>/dev/null || true
}

