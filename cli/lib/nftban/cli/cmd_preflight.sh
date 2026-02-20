#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Preflight Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: CLI interface for strict preflight enforcement
#
# meta:name="cmd_preflight"
# meta:type="cli"
# meta:header="Preflight Command"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Enforce single firewall authority before enabling NFTBan"
# meta:inventory.files=""
# meta:inventory.binaries="nft,systemctl"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units="fail2ban.service,firewalld.service,ufw.service"
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2026-02-20"
# meta:updated_date="2026-02-20"
# =============================================================================

# Strict mode
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${CMD_PREFLIGHT_LOADED:-}" ]] && return 0
readonly CMD_PREFLIGHT_LOADED=1

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
[[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" ]] && source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf"

# Load library directory
[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"

# Load strict mode library
# shellcheck source=/usr/lib/nftban/lib/strict.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/strict.sh"
else
    # Fallback to manual strict mode
    set -Eeuo pipefail
fi

# Load version library
# shellcheck source=/usr/lib/nftban/lib/version.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/version.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/version.sh"
fi

# Load output helpers (for banner)
if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"
fi

# =============================================================================
# LOAD STRICT PREFLIGHT LIBRARY
# =============================================================================

_preflight_lib_loaded=false

_load_preflight_lib() {
    [[ "$_preflight_lib_loaded" == "true" ]] && return 0

    local preflight_lib="${NFTBAN_LIB_DIR}/core/nftban_strict_preflight.sh"

    if [[ -f "$preflight_lib" ]]; then
        # shellcheck source=/dev/null
        source "$preflight_lib"
        _preflight_lib_loaded=true
        return 0
    else
        echo "ERROR: Strict preflight library not found: $preflight_lib" >&2
        return 1
    fi
}

# =============================================================================
# COMMAND HANDLER
# =============================================================================

nftban_cmd_preflight() {
    # Run strict preflight checks
    # Usage: nftban preflight [--strict] [--json]

    local json_mode=false
    # Strict mode is always enabled (default behavior)

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json|-j)
                json_mode=true
                shift
                ;;
            --strict|-s)
                # strict_mode already true by default, this flag is for explicit invocation
                shift
                ;;
            -h|--help|help)
                nftban_cmd_preflight_help
                return 0
                ;;
            -*)
                echo "ERROR: Unknown option: $1" >&2
                nftban_cmd_preflight_help
                return 1
                ;;
            *)
                echo "ERROR: Unknown argument: $1" >&2
                nftban_cmd_preflight_help
                return 1
                ;;
        esac
    done

    # Load preflight library
    _load_preflight_lib || return 1

    # Show banner (skip for JSON output)
    if [[ "$json_mode" != "true" ]]; then
        if [[ $(type -t nftban_banner) == "function" ]]; then
            nftban_banner "preflight"
        fi
        echo ""
    fi

    # Run strict preflight
    local exit_code=0
    local preflight_output

    if [[ "$json_mode" == "true" ]]; then
        # JSON mode - capture output and format
        preflight_output=$(strict_preflight --json 2>&1) || exit_code=$?
        _format_json_output "$exit_code" "$preflight_output"
    else
        # Terminal mode - run and format human-readable output
        preflight_output=$(strict_preflight 2>&1) || exit_code=$?
        _format_terminal_output "$exit_code" "$preflight_output"
    fi

    return $exit_code
}

# =============================================================================
# OUTPUT FORMATTERS
# =============================================================================

_format_terminal_output() {
    local exit_code="$1"
    local output="$2"

    if [[ $exit_code -eq 0 ]]; then
        # SUCCESS
        echo "STRICT PREFLIGHT PASSED"
        echo ""

        # Check policykit status
        if _preflight_is_debian_ubuntu 2>/dev/null; then
            if dpkg-query -W -f='${Status}\n' policykit-1 2>/dev/null | grep -q "install ok installed"; then
                echo "- policykit-1: present"
            fi
        fi

        echo "- No competing firewall authority detected"
        echo "- No non-NFTBan active input hooks detected"
        echo ""
        echo "NFTBan enforce mode OK"
    else
        # FAILURE
        echo "STRICT PREFLIGHT FAILED"
        echo ""

        # Parse the error from preflight output
        local reason=""
        local action=""

        case $exit_code in
            10)
                # POLICYKIT_MISSING
                reason="policykit-1 is REQUIRED on Debian/Ubuntu"
                action="apt-get update && apt-get install -y policykit-1 && nftban preflight --strict"
                ;;
            20)
                # FIREWALL_CONFLICT
                # Extract conflicting service from output
                local conflicts
                conflicts=$(echo "$output" | grep -oP 'conflict\(s\): \K[^.]+' || echo "competing firewall service")
                reason="${conflicts%% *} (firewall authority) is active"
                action="systemctl disable --now ${conflicts%% *} && nftban preflight --strict"
                ;;
            30)
                # NFT_COLLISION
                reason="Non-NFTBan active input hooks detected in nftables"
                action="nft flush ruleset && nftban firewall rebuild && nftban preflight --strict"
                ;;
            40)
                # ENV_UNSUPPORTED
                reason="Required commands missing (nft, systemctl, awk, grep)"
                action="Install missing dependencies and retry"
                ;;
            *)
                reason="Unknown error (exit code: $exit_code)"
                action="Check system logs and retry"
                ;;
        esac

        echo "Reason: $reason"
        echo "Action: $action"
        echo ""

        # Show raw output for debugging if available
        if [[ -n "$output" ]] && [[ "$output" != *"PREFLIGHT_PASSED"* ]]; then
            echo "Details:"
            echo "$output" | sed 's/^/  /'
        fi
    fi
}

_format_json_output() {
    local exit_code="$1"
    local output="$2"

    local status="passed"
    local code_string
    local reason=""
    local action=""

    # Get code string from library if available
    if declare -f preflight_exit_code_to_string &>/dev/null; then
        code_string=$(preflight_exit_code_to_string "$exit_code")
    else
        case $exit_code in
            0)  code_string="OK" ;;
            10) code_string="POLICYKIT_MISSING" ;;
            20) code_string="FIREWALL_CONFLICT" ;;
            30) code_string="NFT_COLLISION" ;;
            40) code_string="ENV_UNSUPPORTED" ;;
            *)  code_string="UNKNOWN" ;;
        esac
    fi

    # Get remediation from library if available
    if declare -f preflight_get_remediation &>/dev/null; then
        action=$(preflight_get_remediation "$exit_code")
    fi

    if [[ $exit_code -ne 0 ]]; then
        status="failed"
        # Extract reason from output
        reason=$(echo "$output" | grep -oP 'message":"\K[^"]+' | head -1 || echo "Preflight check failed")
    fi

    # Construct JSON
    cat <<EOF
{
  "success": $([ $exit_code -eq 0 ] && echo "true" || echo "false"),
  "status": "$status",
  "code": "$code_string",
  "exit_code": $exit_code,
  "reason": "$reason",
  "remediation": "$action",
  "checks": {
    "policykit": $([ $exit_code -ne 10 ] && echo "true" || echo "false"),
    "firewall_authority": $([ $exit_code -ne 20 ] && echo "true" || echo "false"),
    "nft_hooks": $([ $exit_code -ne 30 ] && echo "true" || echo "false"),
    "environment": $([ $exit_code -ne 40 ] && echo "true" || echo "false")
  }
}
EOF
}

# =============================================================================
# HELP
# =============================================================================

nftban_cmd_preflight_help() {
    cat << 'EOF'
Usage: nftban preflight [OPTIONS]

Run strict preflight checks to ensure NFTBan can safely take exclusive
firewall authority.

OPTIONS:
  --strict, -s      Enforce strict mode (default)
  --json, -j        Output results in JSON format
  -h, --help        Show this help message

DESCRIPTION:
  The preflight command performs comprehensive checks before enabling
  NFTBan enforce mode. It verifies:

  1. POLICYKIT-1 (Debian/Ubuntu only)
     - Required for PolicyKit authentication
     - Enables non-root users to run nftban via pkexec

  2. FIREWALL AUTHORITY CONFLICTS
     - fail2ban: Creates competing iptables/nftables rules
     - ufw: Ubuntu's firewall manager
     - firewalld: RHEL/Fedora firewall manager
     - iptables.service: systemd-managed legacy firewall
     - csf/lfd: ConfigServer Firewall

  3. NFTABLES HOOK COLLISIONS
     - Detects non-NFTBan tables with active input hooks
     - Empty passthrough tables (policy accept, no rules) are allowed
     - Active hooks with deny policy or rules are blocked

EXIT CODES:
  0   - OK: Safe to enforce NFTBan
  10  - POLICYKIT_MISSING: policykit-1 required on Debian/Ubuntu
  20  - FIREWALL_CONFLICT: Competing firewall service active
  30  - NFT_COLLISION: Non-NFTBan active input hooks detected
  40  - ENV_UNSUPPORTED: Required commands missing

EXAMPLES:
  # Run preflight check (default: strict mode)
  nftban preflight

  # Run with explicit strict flag
  nftban preflight --strict

  # JSON output for automation
  nftban preflight --json

  # Use in scripts
  if nftban preflight --strict; then
    nftban enable all
  else
    echo "Fix issues before enabling NFTBan"
  fi

OUTPUT EXAMPLES:
  Success:
    STRICT PREFLIGHT PASSED
    - policykit-1: present
    - No competing firewall authority detected
    - No non-NFTBan active input hooks detected
    NFTBan enforce mode OK

  Failure:
    STRICT PREFLIGHT FAILED
    Reason: fail2ban (firewall authority) is active
    Action: systemctl disable --now fail2ban && nftban preflight --strict

SEE ALSO:
  nftban health conflicts    - Detect conflicting firewalls
  nftban health check        - Full health diagnostics
  nftban enable all          - Enable all NFTBan services
EOF
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_cmd_preflight
export -f nftban_cmd_preflight_help

# =============================================================================
# DIRECT EXECUTION SUPPORT
# =============================================================================

# If executed directly (not sourced), run the command handler
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_preflight "$@"
fi
