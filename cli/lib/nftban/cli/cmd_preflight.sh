#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.18.4 - Preflight Check Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Pre-installation/pre-enforcement validation
#
# meta:name="cmd_preflight"
# meta:type="cli"
# meta:version="1.39.0"
# meta:header="Preflight Check"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Validate system before enabling NFTBan enforcement"
# meta:input="None"
# meta:output="Exit codes: 0=OK, 10=policykit, 20=conflict, 30=collision, 40=env"
#
# meta:inventory.files=""
# meta:inventory.binaries="nft,systemctl"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2026-02-20"
# meta:updated_date="2026-02-20"
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_NFTBAN_CMD_PREFLIGHT_LOADED:-}" ]] && return 0
_NFTBAN_CMD_PREFLIGHT_LOADED=1

# =============================================================================
# PREFLIGHT COMMAND
# =============================================================================

nftban_cmd_preflight() {
    local json_mode=false
    local quiet_mode=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --strict|-s)
                # Always strict - this flag is accepted but ignored
                shift
                ;;
            --json|-j)
                json_mode=true
                shift
                ;;
            --quiet|-q)
                quiet_mode=true
                shift
                ;;
            help|--help|-h)
                _preflight_help
                return 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                return 1
                ;;
        esac
    done

    # Preflight is ALWAYS strict mode (that's its purpose)

    # Delegate to firewall validate --strict
    local exit_code=0

    if $json_mode; then
        nftban firewall validate --strict --json || exit_code=$?
    elif $quiet_mode; then
        nftban firewall validate --strict --quiet 2>/dev/null || exit_code=$?
    else
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  NFTBan Preflight Check"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""

        nftban firewall validate --strict || exit_code=$?

        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        case $exit_code in
            0)
                echo "  PREFLIGHT: PASSED"
                echo "  Safe to enable NFTBan enforcement."
                ;;
            10)
                echo "  PREFLIGHT: FAILED (polkit missing)"
                echo "  Fix: apt-get install -y polkitd  (or policykit-1 on older releases)"
                ;;
            20)
                echo "  PREFLIGHT: FAILED (firewall conflicts detected)"
                echo "  Fix: nftban health conflicts --fix"
                ;;
            30)
                echo "  PREFLIGHT: FAILED (nftables collision)"
                echo "  Fix: nftban firewall rebuild"
                ;;
            40)
                echo "  PREFLIGHT: FAILED (environment error)"
                echo "  Check: nftban health check"
                ;;
            *)
                echo "  PREFLIGHT: FAILED (exit code: $exit_code)"
                ;;
        esac

        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
    fi

    return $exit_code
}

# =============================================================================
# HELP
# =============================================================================

_preflight_help() {
    cat <<'EOF'
NFTBan Preflight Check
======================

Validates system readiness before enabling NFTBan enforcement.

USAGE
  nftban preflight [OPTIONS]

OPTIONS
  --strict, -s    Enforce Single Firewall Authority (default)
  --json, -j      Output results as JSON
  --quiet, -q     Suppress output, return exit code only
  --help, -h      Show this help

EXIT CODES
  0   OK - safe to enable enforcement
  10  policykit-1 missing (Debian/Ubuntu)
  20  Firewall conflict (fail2ban/ufw/firewalld/csf active)
  30  NFTables collision (non-NFTBan input hooks)
  40  Environment error

EXAMPLES
  # Run preflight check before install
  nftban preflight

  # Check in CI/scripts (quiet mode)
  if nftban preflight --quiet; then
    echo "Safe to enable"
  else
    echo "Fix conflicts first"
  fi

  # JSON output for automation
  nftban preflight --json

SEE ALSO
  nftban firewall validate --strict
  nftban health conflicts --fix
  nftban firewall rebuild

EOF
}

# Export function
export -f nftban_cmd_preflight 2>/dev/null || true
