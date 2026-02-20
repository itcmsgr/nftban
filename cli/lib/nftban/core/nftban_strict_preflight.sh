#!/usr/bin/env bash
# =============================================================================
# NFTBan Strict Preflight - Single Firewall Authority Enforcement
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Enforce single firewall authority before enabling NFTBan
#
# meta:name="nftban_strict_preflight"
# meta:type="lib"
# meta:header="Strict Preflight Enforcement"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# **Description & Purpose**
# meta:description="Enforces single firewall authority - refuses if conflicts detected"
# meta:input="System state"
# meta:output="Preflight result with exit code"
#
# **Inventory & Requirements**
# meta:depends=""
# meta:inventory.files=""
# meta:inventory.binaries="nft,systemctl,awk,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/os-release"
# meta:inventory.systemd_units="fail2ban.service,firewalld.service,ufw.service,csf.service,lfd.service"
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2026-02-20"
# meta:updated_date="2026-02-20"
# =============================================================================
#
# EXIT CODES:
#   0  = OK (safe to enforce)
#   10 = Missing mandatory dependency (policykit-1 on Debian/Ubuntu)
#   20 = Firewall authority conflict (service/tool active)
#   30 = Nftables hook collision (active non-nftban input hook)
#   40 = Environment unsupported/missing required commands
#
# USAGE:
#   source nftban_strict_preflight.sh
#   strict_preflight          # returns exit code
#   strict_preflight --json   # JSON output
#
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_NFTBAN_STRICT_PREFLIGHT_LOADED:-}" ]] && return 0
_NFTBAN_STRICT_PREFLIGHT_LOADED=1

# =============================================================================
# EXIT CODES
# =============================================================================
declare -gr PREFLIGHT_OK=0
declare -gr PREFLIGHT_POLICYKIT_MISSING=10
declare -gr PREFLIGHT_FIREWALL_CONFLICT=20
declare -gr PREFLIGHT_NFT_COLLISION=30
declare -gr PREFLIGHT_ENV_UNSUPPORTED=40

# =============================================================================
# OUTPUT HELPERS
# =============================================================================

_preflight_want_json=0

_preflight_json_escape() {
    local s="${1:-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    printf '%s' "$s"
}

_preflight_emit() {
    # emit <level> <code> <message>
    local level="$1" code="$2" msg="$3"
    if (( _preflight_want_json )); then
        printf '{"level":"%s","code":"%s","message":"%s"}\n' \
            "$(_preflight_json_escape "$level")" \
            "$(_preflight_json_escape "$code")" \
            "$(_preflight_json_escape "$msg")"
    else
        printf '[PREFLIGHT] %s: %s\n' "$level" "$msg" >&2
    fi
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

_preflight_have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

_preflight_require_cmds() {
    local missing=0
    for c in "$@"; do
        if ! _preflight_have_cmd "$c"; then
            _preflight_emit "ERROR" "MISSING_CMD" "Required command missing: $c"
            missing=1
        fi
    done
    if (( missing )); then
        return $PREFLIGHT_ENV_UNSUPPORTED
    fi
    return 0
}

_preflight_svc_active() {
    # returns 0 if active, 1 otherwise
    local svc="$1"
    if ! _preflight_have_cmd systemctl; then
        return 1
    fi
    systemctl is-active --quiet "$svc" 2>/dev/null
}

_preflight_detect_distro() {
    # prints ID|ID_LIKE
    local id="" like=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        id="${ID:-}"
        like="${ID_LIKE:-}"
    fi
    printf '%s|%s\n' "$id" "$like"
}

_preflight_is_debian_ubuntu() {
    local id like
    IFS="|" read -r id like < <(_preflight_detect_distro)
    if [[ "$id" == "debian" || "$id" == "ubuntu" || "$like" == *debian* || "$like" == *ubuntu* ]]; then
        return 0
    fi
    return 1
}

# =============================================================================
# CHECK: POLICYKIT-1 (Mandatory on Debian/Ubuntu)
# =============================================================================

_preflight_check_policykit() {
    # Rule: policykit-1 is MANDATORY on Debian/Ubuntu families
    # This is non-negotiable - it's an architectural requirement

    if ! _preflight_is_debian_ubuntu; then
        # Not Debian/Ubuntu - skip this check
        return 0
    fi

    # Debian/Ubuntu: package is policykit-1
    if _preflight_have_cmd dpkg-query; then
        if ! dpkg-query -W -f='${Status}\n' policykit-1 2>/dev/null | grep -q "install ok installed"; then
            _preflight_emit "ERROR" "POLICYKIT_MISSING" \
                "policykit-1 is REQUIRED on Debian/Ubuntu. Install: apt-get install -y policykit-1"
            return $PREFLIGHT_POLICYKIT_MISSING
        fi
    else
        # No dpkg-query => cannot verify, strict mode refuses
        _preflight_emit "ERROR" "POLICYKIT_CHECK_FAILED" \
            "Cannot verify policykit-1 (dpkg-query missing). Refusing in strict mode."
        return $PREFLIGHT_POLICYKIT_MISSING
    fi

    return 0
}

# =============================================================================
# CHECK: FIREWALL AUTHORITY CONFLICTS
# =============================================================================

_preflight_check_firewall_authority() {
    # Hard conflicts: fail2ban, ufw, firewalld, iptables.service, csf/lfd
    # These are firewall authority services - they own rules
    local conflicts=()

    # fail2ban - creates iptables/nftables rules
    if _preflight_svc_active fail2ban; then
        conflicts+=("fail2ban(active)")
    fi

    # ufw - Ubuntu firewall manager
    if _preflight_svc_active ufw; then
        conflicts+=("ufw(active)")
    elif _preflight_have_cmd ufw; then
        local ufw_status
        ufw_status=$(ufw status 2>/dev/null | head -1 || echo "")
        if [[ "$ufw_status" == *"active"* ]]; then
            conflicts+=("ufw(active)")
        fi
    fi

    # firewalld - RHEL/Fedora firewall manager
    if _preflight_svc_active firewalld; then
        conflicts+=("firewalld(active)")
    fi

    # iptables.service - systemd-managed iptables
    if _preflight_svc_active iptables; then
        conflicts+=("iptables.service(active)")
    fi

    # ip6tables.service
    if _preflight_svc_active ip6tables; then
        conflicts+=("ip6tables.service(active)")
    fi

    # CSF/LFD - ConfigServer Firewall
    if _preflight_svc_active lfd; then
        conflicts+=("lfd(active)")
    fi
    if _preflight_svc_active csf; then
        conflicts+=("csf(active)")
    fi

    # CSF command check (more reliable in some installs)
    if _preflight_have_cmd csf; then
        if csf -s 2>/dev/null | grep -Eqi 'enabled|running|active'; then
            # Only add if not already in conflicts
            if [[ ! " ${conflicts[*]} " =~ "csf" ]]; then
                conflicts+=("csf(enabled)")
            fi
        fi
    fi

    if (( ${#conflicts[@]} > 0 )); then
        _preflight_emit "ERROR" "FIREWALL_AUTHORITY_CONFLICT" \
            "Firewall authority conflict(s): ${conflicts[*]}. NFTBan requires exclusive ownership. Disable conflicting services first."
        return $PREFLIGHT_FIREWALL_CONFLICT
    fi

    return 0
}

# =============================================================================
# CHECK: NFTABLES HOOK COLLISIONS
# =============================================================================

_preflight_check_nft_collisions() {
    # Detect non-NFTBan tables with active input hooks
    # Block ONLY if:
    # - Another table has: type filter hook input
    # - AND (policy != accept OR has rules)
    # - AND is not nftban-owned
    #
    # Empty passthrough tables (policy accept, no rules) are ALLOWED

    _preflight_require_cmds nft awk grep || return $?

    local ruleset
    ruleset="$(nft -a list ruleset 2>/dev/null || true)"
    if [[ -z "$ruleset" ]]; then
        _preflight_emit "ERROR" "NFT_LIST_FAILED" "Unable to read nftables ruleset"
        return $PREFLIGHT_ENV_UNSUPPORTED
    fi

    # Parse tables and find non-nftban input hooks that are active
    local collisions
    collisions="$(echo "$ruleset" | awk '
        BEGIN {
            family=""; table=""; chain="";
            in_chain=0; has_hook=0; policy=""; rule_count=0;
        }

        # table line: table ip filter {
        /^table / {
            family=$2; table=$3;
            gsub(/{.*/, "", table);
            next
        }

        # chain start: chain input {
        /^[[:space:]]*chain / {
            chain=$2;
            gsub(/{.*/, "", chain);
            in_chain=1; has_hook=0; policy=""; rule_count=0;
            next
        }

        # hook input line
        in_chain && /hook[[:space:]]+input/ {
            has_hook=1
            # extract policy
            if (match($0, /policy[[:space:]]+([a-zA-Z]+)/, m)) {
                policy=m[1]
            }
            next
        }

        # count rules (lines with rule-like content inside chain)
        in_chain && /^[[:space:]]+/ {
            line=$0
            # skip type/hook/policy declarations
            if (index(line, "hook ") > 0) next
            if (index(line, "type ") > 0) next
            if (match(line, /^[[:space:]]*policy[[:space:]]/)) next
            # detect rule keywords
            if (match(line, /(saddr|daddr|sport|dport|tcp|udp|icmp|ct |counter|drop|reject|accept|log|meta|iif|oif)/)) {
                rule_count++
            }
            next
        }

        # chain end: }
        /^[[:space:]]*}[[:space:]]*$/ {
            if (in_chain && has_hook) {
                # Check if this is nftban-owned
                is_nftban = (table == "nftban") ? 1 : 0

                if (!is_nftban) {
                    # Active means: policy != accept OR has rules
                    is_active = 0
                    if (policy != "" && policy != "accept") {
                        is_active = 1
                    }
                    if (rule_count > 0) {
                        is_active = 1
                    }

                    if (is_active) {
                        printf "%s %s|%s|policy=%s|rules=%d\n", family, table, chain, policy, rule_count
                    }
                }
            }
            in_chain=0
            next
        }
    ')"

    if [[ -n "$collisions" ]]; then
        local collision_list
        collision_list=$(echo "$collisions" | tr '\n' '; ' | sed 's/;*$//')
        _preflight_emit "ERROR" "NFT_HOOK_COLLISION" \
            "Non-NFTBan active input hook(s) detected: $collision_list. Remove or flush these tables before enabling NFTBan."
        return $PREFLIGHT_NFT_COLLISION
    fi

    return 0
}

# =============================================================================
# MAIN: STRICT PREFLIGHT
# =============================================================================

strict_preflight() {
    # Run all strict preflight checks
    # Usage: strict_preflight [--json]
    # Returns: 0=OK, 10/20/30/40=failure (see exit codes above)

    local rc=0

    # Parse args
    _preflight_want_json=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json|-j)
                _preflight_want_json=1
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    # Check 1: Mandatory dependencies (policykit-1 on Debian/Ubuntu)
    _preflight_check_policykit || return $?

    # Check 2: Firewall authority conflicts
    _preflight_check_firewall_authority || return $?

    # Check 3: NFTables hook collisions
    _preflight_check_nft_collisions || return $?

    # All checks passed
    _preflight_emit "OK" "PREFLIGHT_PASSED" \
        "Strict preflight passed: exclusive firewall authority confirmed. NFTBan enforce mode OK."

    return 0
}

# =============================================================================
# PREFLIGHT RESULT HELPERS
# =============================================================================

preflight_exit_code_to_string() {
    local code="${1:-0}"
    case $code in
        0)  echo "OK" ;;
        10) echo "POLICYKIT_MISSING" ;;
        20) echo "FIREWALL_CONFLICT" ;;
        30) echo "NFT_COLLISION" ;;
        40) echo "ENV_UNSUPPORTED" ;;
        *)  echo "UNKNOWN" ;;
    esac
}

preflight_get_remediation() {
    local code="${1:-0}"
    case $code in
        10) echo "apt-get update && apt-get install -y policykit-1" ;;
        20) echo "systemctl disable --now fail2ban ufw firewalld iptables csf lfd 2>/dev/null; then re-run preflight" ;;
        30) echo "nft flush ruleset && nftban firewall rebuild" ;;
        40) echo "Ensure nft, systemctl, awk, grep are installed" ;;
        *)  echo "" ;;
    esac
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f strict_preflight
export -f preflight_exit_code_to_string
export -f preflight_get_remediation

# Allow direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    strict_preflight "$@"
    exit $?
fi
