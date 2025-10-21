#!/usr/bin/env bash

# =============================================================================
# NFTBan CLI - Security Command
# Version: 1.0.0
# Location: lib/cli/cmd_security.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Dependencies: nftban_security_audit_module.sh
# Description: Security audit and compliance checking
# =============================================================================

# Strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# =============================================================================
# SECURITY COMMAND HANDLER
# =============================================================================

cmd_security() {
    local action="${1:-audit}"
    shift || true

    case "$action" in
        audit|check)
            nftban_security_audit_full
            ;;
        check-strict|strict-mode)
            nftban_security_check_strict_mode
            ;;
        check-permissions|permissions)
            nftban_security_check_permissions
            ;;
        check-flock|flock)
            nftban_security_check_flock
            ;;
        check-localhost|localhost)
            nftban_security_check_localhost
            ;;
        quick)
            nftban_security_check_quick
            ;;
        help)
            cat <<'SECHELP'

nftban security - Security Audit & Compliance Checking

USAGE:
    nftban security <action>

ACTIONS:
    audit               Run comprehensive security audit (default)
    quick               Quick security check
    check-strict        Check bash strict mode compliance
    check-permissions   Check file permissions
    check-flock         Check file locking implementation
    check-localhost     Check localhost protection

DESCRIPTION:
    The security audit system performs automated security checks:
    - Bash strict mode (set -euo pipefail) compliance
    - File permission validation
    - File locking (flock) implementation
    - Localhost protection verification

EXAMPLES:
    nftban security audit           # Full security audit
    nftban security quick           # Quick check
    nftban security check-strict    # Check strict mode only
    nftban security check-permissions # Check file permissions

SECURITY CHECKS:
    1. Strict Mode: Verifies all .sh files have 'set -euo pipefail'
    2. Permissions: Validates file/directory permissions
    3. File Locking: Checks for race condition protection
    4. Localhost: Ensures 127.0.0.1/::1 are whitelisted

COMPLIANCE:
    Target: 100% compliance across all checks
    Report: Detailed findings with actionable recommendations

See: docs/SECURITY_AUDIT_2025-10-21.md for detailed audit report

SECHELP
            ;;
        *)
            nftban_log_error "Unknown security action: $action"
            echo ""
            echo "Available actions:"
            echo "  audit               Run comprehensive security audit"
            echo "  quick               Quick security check"
            echo "  check-strict        Check strict mode compliance"
            echo "  check-permissions   Check file permissions"
            echo "  check-flock         Check file locking"
            echo "  check-localhost     Check localhost protection"
            echo "  help                Show detailed help"
            echo ""
            echo "Examples:"
            echo "  nftban security audit"
            echo "  nftban security quick"
            echo "  nftban security check-strict"
            echo ""
            exit 1
            ;;
    esac
}

# Export function
export -f cmd_security
