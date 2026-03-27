#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.24 - Polkit Authorization Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: CLI wrapper for Polkit authorization validation
#
# meta:name="cmd_polkit"
# meta:type="cli"
# meta:header="Polkit Authorization Command"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Validate Polkit rules for NFTBan RBAC (operator/auditor/panel)"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2026-01-02"
# meta:updated_date="2026-01-02"
# =============================================================================

set -Eeuo pipefail

[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"

# Prevent double-loading
[[ -n "${CMD_POLKIT_LOADED:-}" ]] && return 0
readonly CMD_POLKIT_LOADED=1

# Source distro config for polkit path detection
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_distro_config.sh" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR}/lib/nftban_distro_config.sh" || return 1
fi

# =============================================================================
# COMMAND HANDLER
# =============================================================================

nftban_cmd_polkit() {
    local subcommand="${1:-help}"
    shift || true

    # Source output module for banner
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
        nftban_banner
    fi
    echo ""

    case "$subcommand" in
        validate|check)
            nftban_polkit_validate "$@"
            ;;
        static)
            nftban_polkit_validate --static-only "$@"
            ;;
        runtime)
            nftban_polkit_runtime "$@"
            ;;
        status)
            nftban_polkit_status
            ;;
        groups)
            nftban_polkit_groups "$@"
            ;;
        rules)
            nftban_polkit_rules "$@"
            ;;
        test)
            nftban_polkit_test "$@"
            ;;
        help|--help|-h)
            nftban_cmd_polkit_usage
            ;;
        *)
            echo "ERROR: Unknown subcommand: $subcommand" >&2
            nftban_cmd_polkit_usage
            return 1
            ;;
    esac
}

# =============================================================================
# SUBCOMMAND HANDLERS
# =============================================================================

nftban_polkit_validate() {
    # Full validation: static + runtime
    local tests_dir="${NFTBAN_TESTS_DIR:-${NFTBAN_LIB_DIR}/tests}"
    local validator="${tests_dir}/polkit_validator.sh"

    if [[ ! -f "$validator" ]]; then
        echo "ERROR: Polkit validator not found at: $validator" >&2
        echo "Hint: Run 'sudo ./install.sh tests' to install test suite" >&2
        return 1
    fi

    # Check if running as root for full validation
    if [[ $EUID -ne 0 ]] && [[ ! "$*" =~ --static-only ]]; then
        echo "WARNING: Running as non-root. Only static checks will be performed."
        echo "         Run with sudo for full runtime authorization tests."
        echo ""
        set -- --static-only "$@"
    fi

    echo "Running NFTBan Polkit Authorization Validator..."
    echo ""

    bash "$validator" "$@"
}

nftban_polkit_runtime() {
    # Runtime tests only (requires root)
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: Runtime tests require root privileges" >&2
        echo "Usage: sudo nftban polkit runtime" >&2
        return 1
    fi

    local tests_dir="${NFTBAN_TESTS_DIR:-${NFTBAN_LIB_DIR}/tests}"
    local validator="${tests_dir}/polkit_validator.sh"

    if [[ ! -f "$validator" ]]; then
        echo "ERROR: Polkit validator not found at: $validator" >&2
        return 1
    fi

    echo "Running Polkit Runtime Authorization Tests..."
    echo ""
    echo "This will test actual authorization using test users."
    echo ""

    bash "$validator" --create-test-users "$@"
}

nftban_polkit_status() {
    # Quick status check of Polkit rules
    echo "Polkit Rules Status"
    echo "==================="
    echo ""

    local polkit_dir
    polkit_dir=$(nftban_distro_get_polkit_dir)
    local rule_dirs=("$polkit_dir")
    local expected_files=("10-nftban-systemd.rules" "20-nftban-auditor.rules" "30-nftban-panel.rules")
    local obsolete_files=("50-nftban-auth.rules" "60-nftban-services.rules")

    # Check expected files
    echo "Expected Rule Files:"
    for f in "${expected_files[@]}"; do
        local found=false
        for dir in "${rule_dirs[@]}"; do
            if [[ -f "$dir/$f" ]]; then
                echo "  [OK] $dir/$f"
                found=true
                break
            fi
        done
        if [[ "$found" != true ]]; then
            echo "  [MISSING] $f"
        fi
    done
    echo ""

    # Check obsolete files
    echo "Obsolete Files (should NOT exist):"
    local has_obsolete=false
    for f in "${obsolete_files[@]}"; do
        for dir in "${rule_dirs[@]}"; do
            if [[ -f "$dir/$f" ]]; then
                echo "  [WARNING] $dir/$f - REMOVE THIS FILE"
                has_obsolete=true
            fi
        done
    done
    if [[ "$has_obsolete" != true ]]; then
        echo "  [OK] No obsolete files found"
    fi
    echo ""

    # Check groups
    echo "NFTBan Groups:"
    for group in "nftban" "nftban-auditor" "nftban-panel"; do
        if getent group "$group" >/dev/null 2>&1; then
            local members
            members=$(getent group "$group" | cut -d: -f4)
            echo "  [OK] $group: ${members:-<no members>}"
        else
            echo "  [MISSING] $group"
        fi
    done
    echo ""

    # Polkit version
    echo "Polkit Version:"
    if command -v pkcheck >/dev/null 2>&1; then
        pkcheck --version 2>&1 | head -1 | sed 's/^/  /'
    else
        echo "  [ERROR] pkcheck not found"
    fi
}

nftban_polkit_groups() {
    # Manage group memberships
    local action="${1:-list}"
    shift || true

    case "$action" in
        list)
            echo "NFTBan Authorization Groups"
            echo "==========================="
            echo ""
            echo "GROUP             ROLE              DESCRIPTION"
            echo "----------------  ----------------  --------------------------------"
            echo "nftban            Operator          Full CLI + service management"
            echo "nftban-auditor    Auditor           Read-only access (status/logs)"
            echo "nftban-panel      Panel             Limited reload (panel integration)"
            echo ""

            for group in "nftban" "nftban-auditor" "nftban-panel"; do
                echo "$group members:"
                if getent group "$group" >/dev/null 2>&1; then
                    local members
                    members=$(getent group "$group" | cut -d: -f4)
                    if [[ -n "$members" ]]; then
                        echo "$members" | tr ',' '\n' | sed 's/^/  - /'
                    else
                        echo "  (no members)"
                    fi
                else
                    echo "  (group does not exist)"
                fi
                echo ""
            done
            ;;
        add)
            local user="${1:-}"
            local group="${2:-nftban}"
            if [[ -z "$user" ]]; then
                echo "Usage: nftban polkit groups add <username> [group]" >&2
                echo "Groups: nftban (operator), nftban-auditor, nftban-panel" >&2
                return 1
            fi
            if [[ $EUID -ne 0 ]]; then
                echo "ERROR: Adding users to groups requires root privileges" >&2
                return 1
            fi
            echo "Adding user '$user' to group '$group'..."
            usermod -aG "$group" "$user"
            echo "Done. User must log out and back in for changes to take effect."
            ;;
        remove)
            local user="${1:-}"
            local group="${2:-}"
            if [[ -z "$user" ]] || [[ -z "$group" ]]; then
                echo "Usage: nftban polkit groups remove <username> <group>" >&2
                return 1
            fi
            if [[ $EUID -ne 0 ]]; then
                echo "ERROR: Removing users from groups requires root privileges" >&2
                return 1
            fi
            echo "Removing user '$user' from group '$group'..."
            gpasswd -d "$user" "$group"
            echo "Done. User must log out and back in for changes to take effect."
            ;;
        create)
            if [[ $EUID -ne 0 ]]; then
                echo "ERROR: Creating groups requires root privileges" >&2
                return 1
            fi
            echo "Creating NFTBan authorization groups..."
            for group in "nftban" "nftban-auditor" "nftban-panel"; do
                if ! getent group "$group" >/dev/null 2>&1; then
                    groupadd -r "$group"
                    echo "  Created: $group"
                else
                    echo "  Exists: $group"
                fi
            done
            echo "Done."
            ;;
        *)
            echo "Usage: nftban polkit groups <list|add|remove|create>" >&2
            return 1
            ;;
    esac
}

nftban_polkit_rules() {
    # View/install rules
    local action="${1:-list}"
    shift || true

    case "$action" in
        list|show)
            echo "NFTBan Polkit Rules"
            echo "==================="
            echo ""
            local polkit_dir
            polkit_dir=$(nftban_distro_get_polkit_dir)
            local rule_dirs=("$polkit_dir")
            for dir in "${rule_dirs[@]}"; do
                if [[ -d "$dir" ]]; then
                    echo "Directory: $dir"
                    # ls piped to grep for display only, not parsed
                    # shellcheck disable=SC2010
                    ls -la "$dir" 2>/dev/null | grep -E 'nftban|^total' | sed 's/^/  /'
                    echo ""
                fi
            done
            ;;
        view)
            local file="${1:-10-nftban-systemd.rules}"
            local polkit_dir
            polkit_dir=$(nftban_distro_get_polkit_dir)
            if [[ -f "$polkit_dir/$file" ]]; then
                echo "=== $polkit_dir/$file ==="
                cat "$polkit_dir/$file"
            else
                echo "ERROR: Rule file not found: $file" >&2
                return 1
            fi
            ;;
        install)
            if [[ $EUID -ne 0 ]]; then
                echo "ERROR: Installing rules requires root privileges" >&2
                return 1
            fi
            local src_dir="${NFTBAN_LIB_DIR}/../packaging/polkit-1/rules.d"
            local polkit_dir
            polkit_dir=$(nftban_distro_get_polkit_dir)
            local dest_dir="$polkit_dir"

            # Try to find source directory
            if [[ ! -d "$src_dir" ]]; then
                src_dir="/usr/share/nftban/polkit-1/rules.d"
            fi
            if [[ ! -d "$src_dir" ]]; then
                echo "ERROR: Polkit rules source directory not found" >&2
                return 1
            fi

            echo "Installing Polkit rules from $src_dir to $dest_dir..."
            for f in "10-nftban-systemd.rules" "20-nftban-auditor.rules" "30-nftban-panel.rules"; do
                if [[ -f "$src_dir/$f" ]]; then
                    cp -v "$src_dir/$f" "$dest_dir/"
                    chmod 644 "$dest_dir/$f"
                    chown root:root "$dest_dir/$f"
                else
                    echo "WARNING: Source file not found: $src_dir/$f" >&2
                fi
            done
            echo ""
            echo "Restarting polkit service..."
            systemctl restart polkit || true
            echo "Done."
            ;;
        *)
            echo "Usage: nftban polkit rules <list|view|install>" >&2
            return 1
            ;;
    esac
}

nftban_polkit_test() {
    # Quick authorization test for current user
    local user="${1:-$(whoami)}"

    echo "Testing Polkit Authorization for: $user"
    echo "======================================="
    echo ""

    # Check group memberships
    echo "Group Memberships:"
    local groups
    groups=$(id -nG "$user" 2>/dev/null || echo "unknown")
    echo "  $groups"
    echo ""

    # Check nftban group membership
    echo "NFTBan Role:"
    if echo "$groups" | grep -qw "nftban"; then
        echo "  [OPERATOR] Full CLI and service management access"
    elif echo "$groups" | grep -qw "nftban-auditor"; then
        echo "  [AUDITOR] Read-only access (status, logs, reports)"
    elif echo "$groups" | grep -qw "nftban-panel"; then
        echo "  [PANEL] Limited reload access (panel integration)"
    else
        echo "  [NONE] User is not in any NFTBan authorization group"
        echo ""
        echo "To grant access:"
        echo "  sudo usermod -aG nftban $user          # Operator access"
        echo "  sudo usermod -aG nftban-auditor $user  # Auditor access"
        echo "  sudo usermod -aG nftban-panel $user    # Panel access"
    fi
    echo ""

    # Test nft access (should be denied for non-root)
    echo "Direct nftables Access:"
    if nft list tables >/dev/null 2>&1; then
        if [[ $EUID -eq 0 ]]; then
            echo "  [OK] Allowed (running as root)"
        else
            echo "  [WARNING] Allowed for non-root - check capabilities"
        fi
    else
        echo "  [OK] Denied (correct - use nftban CLI instead)"
    fi
}

# =============================================================================
# USAGE
# =============================================================================

nftban_cmd_polkit_usage() {
    cat <<'EOF'
NFTBan Polkit Authorization Management

USAGE:
  nftban polkit <subcommand> [options]

SUBCOMMANDS:
  validate      Full validation (static + runtime checks)
  static        Static-only checks (no test users needed)
  runtime       Runtime tests with temporary test users (requires root)
  status        Quick status of Polkit rules and groups
  groups        Manage authorization group memberships
  rules         View/install Polkit rule files
  test          Test authorization for current user
  help          Show this help

EXAMPLES:
  nftban polkit status                    # Quick status check
  nftban polkit validate                  # Full validation (sudo for runtime)
  nftban polkit static                    # Static checks only
  sudo nftban polkit runtime              # Full runtime tests with test users
  nftban polkit groups list               # List groups and members
  sudo nftban polkit groups add john      # Add user to operator group
  sudo nftban polkit groups create        # Create NFTBan groups
  nftban polkit rules list                # List installed rules
  nftban polkit rules view 10-nftban-systemd.rules  # View rule file
  nftban polkit test                      # Test your authorization

AUTHORIZATION GROUPS:
  nftban            Operators - Full CLI and service management
  nftban-auditor    Auditors - Read-only access (status, logs)
  nftban-panel      Panels - Limited reload for hosting panels

SECURITY MODEL:
  - Operators can start/stop/restart NFTBan services
  - Auditors can only view status (no modifications)
  - Panels can only reload specific core services
  - nftables access is ALWAYS via IPC to daemon (no direct nft)

For detailed security documentation:
  man nftban-polkit
  https://nftban.com/docs/security/polkit
EOF
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_cmd_polkit
export -f nftban_polkit_validate
export -f nftban_polkit_status
export -f nftban_polkit_groups
export -f nftban_polkit_rules
export -f nftban_polkit_test
export -f nftban_cmd_polkit_usage

# =============================================================================
# DIRECT EXECUTION
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    nftban_cmd_polkit "$@"
fi
