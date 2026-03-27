#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.4.0 - Firewall Management Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Firewall validation, conflicts, stats, logs, and enterprise rollback
#
# meta:name="cmd_firewall"
# meta:type="cli"
# meta:header="NFTBan Firewall Command"
# meta:version="1.47.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Firewall management: validate --strict, conflicts, restore, rebuild, reset"
# meta:inventory.files=""
# meta:inventory.binaries="nft,journalctl,systemctl"
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/conf.d/fwlog.conf"
# meta:inventory.systemd_units="fail2ban.service,firewalld.service,ufw.service,lfd.service"
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2025-11-13"
# meta:updated_date="2026-02-20"
# =============================================================================

set -Eeuo pipefail


# =============================================================================
# CONFIGURATION
# =============================================================================

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" 2>/dev/null || true

: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"
: "${NFTBAN_CLI_DIR:=/usr/lib/nftban/cli}"

# Load strict mode library
# shellcheck source=/usr/lib/nftban/lib/strict.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/strict.sh" || return 1
else
    # Fallback to manual strict mode
    set -Eeuo pipefail
fi

# Load version library
# shellcheck source=/usr/lib/nftban/lib/version.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/version.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/version.sh" || return 1
fi


# Load NFT schema (single source of truth for table/set names)
# shellcheck source=/usr/lib/nftban/lib/nft_schema.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" || return 1
fi

# Load timestamp library (unified timestamp generation)
# shellcheck source=/usr/lib/nftban/lib/nftban_timestamp.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_timestamp.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_timestamp.sh" || return 1
fi

# Load service control library (systemd service/timer primitives)
# shellcheck source=/usr/lib/nftban/lib/nftban_service_control.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_service_control.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_service_control.sh" || return 1
fi

# Load JSON helper for --json support
JSON_HELPER="${NFTBAN_LIB_DIR}/helpers/json_output.sh"
if [[ -f "$JSON_HELPER" ]]; then
    # shellcheck source=/dev/null
    source "$JSON_HELPER" || return 1
fi

# =============================================================================
# MAIN COMMAND HANDLER
# =============================================================================

nftban_cmd_firewall() {
    # Main firewall command handler
    # Usage: nftban firewall <subcommand> [options]

    local subcommand="${1:-help}"

    # Check for --json flag in all args (suppress banner for JSON output)
    local json_mode=false
    for arg in "$@"; do
        [[ "$arg" == "--json" ]] && json_mode=true && break
    done

    # Show banner (skip for JSON output to avoid polluting machine-readable output)
    if [[ "$json_mode" == "false" ]]; then
        if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
            # shellcheck source=/dev/null
            source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
            if [[ $(type -t nftban_banner) == "function" ]]; then
                nftban_banner
            fi
        fi
        echo ""
    fi

    case "$subcommand" in
        help|-h|--help)
            show_firewall_help
            return 0
            ;;
        status)
            shift
            firewall_status "$@"
            ;;
        init)
            # v1.38.0: BUG-002 — alias to rebuild (firewall init was never implemented)
            shift
            firewall_rebuild "$@"
            ;;
        validate)
            shift
            firewall_validate "$@"
            ;;
        check)
            shift
            firewall_check "$@"
            ;;
        stats)
            shift
            firewall_stats "$@"
            ;;
        logs)
            shift
            # Load logs command on-demand
            if [[ -f "${NFTBAN_CLI_DIR}/cmd_firewall_logs.sh" ]]; then
                # shellcheck source=/dev/null
                source "${NFTBAN_CLI_DIR}/cmd_firewall_logs.sh" || return 1
                nftban_cmd_firewall_logs "$@"
            else
                echo "ERROR: Firewall logs module not found" >&2
                return 1
            fi
            ;;
        reload)
            shift
            firewall_reload "$@"
            ;;
        rebuild)
            shift
            firewall_rebuild "$@"
            ;;
        reset)
            shift
            firewall_reset "$@"
            ;;
        conflicts)
            # Delegate to health conflicts (single implementation)
            shift
            if [[ -f "${NFTBAN_CLI_DIR}/cmd_health_analysis.sh" ]]; then
                # shellcheck source=/dev/null
                source "${NFTBAN_CLI_DIR}/cmd_health_analysis.sh" || return 1
                nftban_health_cmd_conflicts "$@"
            else
                echo "ERROR: Health analysis module not found" >&2
                return 1
            fi
            ;;
        restore)
            shift
            firewall_restore "$@"
            ;;
        record)
            shift
            firewall_record "$@"
            ;;
        *)
            echo "ERROR: Unknown firewall subcommand: $subcommand" >&2
            echo "Try 'nftban firewall help' for more information." >&2
            return 1
            ;;
    esac
}

# =============================================================================
# SUBCOMMAND: STATUS (v1.38.0 — BUG-001 fix)
# =============================================================================

firewall_status() {
    # Quick situational awareness: tables, sets, services, conflicts
    # Usage: nftban firewall status [--json]

    local json_mode=false
    for arg in "$@"; do
        [[ "$arg" == "--json" ]] && json_mode=true
    done

    # --- 1. Tables ---
    local ipv4_table="${NFTBAN_TABLE_IPV4:-ip nftban}"
    local ipv6_table="${NFTBAN_TABLE_IPV6:-ip6 nftban}"
    local v4_ok=false v6_ok=false

    nft list table $ipv4_table &>/dev/null 2>&1 && v4_ok=true
    nft list table $ipv6_table &>/dev/null 2>&1 && v6_ok=true

    if [[ "$json_mode" == "true" ]]; then
        # Collect stats for JSON
        local v4_sets=0 v6_sets=0 v4_chains=0 v6_chains=0 v4_elements=0 v6_elements=0
        if [[ "$v4_ok" == "true" ]]; then
            v4_sets=$(nft list sets $ipv4_table 2>/dev/null | grep -c "set " || echo 0)
            v4_chains=$(nft list chains $ipv4_table 2>/dev/null | grep -c "chain " || echo 0)
            v4_elements=$(nft list sets $ipv4_table 2>/dev/null | grep -oP 'elements\s*=\s*\K\d+' | paste -sd+ | bc 2>/dev/null || echo 0)
        fi
        if [[ "$v6_ok" == "true" ]]; then
            v6_sets=$(nft list sets $ipv6_table 2>/dev/null | grep -c "set " || echo 0)
            v6_chains=$(nft list chains $ipv6_table 2>/dev/null | grep -c "chain " || echo 0)
            v6_elements=$(nft list sets $ipv6_table 2>/dev/null | grep -oP 'elements\s*=\s*\K\d+' | paste -sd+ | bc 2>/dev/null || echo 0)
        fi

        local daemon_active=false
        systemctl is-active nftband &>/dev/null 2>&1 && daemon_active=true

        cat <<ENDJSON
{
  "tables": {"ipv4": $v4_ok, "ipv6": $v6_ok},
  "sets": {"ipv4": $v4_sets, "ipv6": $v6_sets},
  "chains": {"ipv4": $v4_chains, "ipv6": $v6_chains},
  "elements": {"ipv4": ${v4_elements:-0}, "ipv6": ${v6_elements:-0}},
  "daemon": $daemon_active
}
ENDJSON
        return 0
    fi

    # --- Text output ---
    echo "Firewall Status"
    echo "==============="
    echo ""

    # Tables
    echo "Tables:"
    if [[ "$v4_ok" == "true" ]]; then
        echo "  IPv4 ($ipv4_table): ACTIVE"
    else
        echo "  IPv4 ($ipv4_table): MISSING"
    fi
    if [[ "$v6_ok" == "true" ]]; then
        echo "  IPv6 ($ipv6_table): ACTIVE"
    else
        echo "  IPv6 ($ipv6_table): MISSING"
    fi

    # Sets summary
    echo ""
    echo "Sets:"
    if [[ "$v4_ok" == "true" ]]; then
        local set_count
        set_count=$(nft list sets $ipv4_table 2>/dev/null | grep -c "set " || echo 0)
        echo "  IPv4: ${set_count} sets"
    fi
    if [[ "$v6_ok" == "true" ]]; then
        local set_count6
        set_count6=$(nft list sets $ipv6_table 2>/dev/null | grep -c "set " || echo 0)
        echo "  IPv6: ${set_count6} sets"
    fi

    # Services
    echo ""
    echo "Services:"
    local services=("nftband" "nftban-maintenance.timer" "nftban-health.timer" "nftban-watchdog.timer")
    for svc in "${services[@]}"; do
        local state
        state=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
        printf "  %-30s %s\n" "$svc" "$state"
    done

    # Conflicts
    echo ""
    echo "Firewall Conflicts:"
    local has_conflict=false
    for fw in fail2ban firewalld ufw csf lfd; do
        if systemctl is-active "${fw}.service" &>/dev/null 2>&1 || systemctl is-active "${fw}d.service" &>/dev/null 2>&1; then
            echo "  WARNING: $fw is ACTIVE (conflicts with NFTBan)"
            has_conflict=true
        fi
    done
    [[ "$has_conflict" == "false" ]] && echo "  None detected"

    echo ""
    echo "For details: nftban firewall validate --strict"
    echo "For stats:   nftban firewall stats"

    return 0
}

# =============================================================================
# SUBCOMMAND: VALIDATE
# =============================================================================

# Exit codes for strict mode (Single Firewall Authority)
readonly VALIDATE_OK=0
readonly VALIDATE_STRUCTURE_ERROR=1
readonly VALIDATE_POLICYKIT_MISSING=10
readonly VALIDATE_FIREWALL_CONFLICT=20
readonly VALIDATE_NFT_COLLISION=30
readonly VALIDATE_ENV_ERROR=40

firewall_validate() {
    # Validate nftables structure against NFTBan specification
    # Args: [--strict] [--json] [--quiet]
    #
    # --strict: Enforce Single Firewall Authority
    #   - policykit-1 MANDATORY on Debian/Ubuntu
    #   - No competing firewalls (fail2ban, ufw, firewalld, csf)
    #   - No non-NFTBan active input hooks

    local output_json=false
    local strict_mode=false
    local quiet_mode=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                output_json=true
                shift
                ;;
            --strict|-s)
                strict_mode=true
                shift
                ;;
            --quiet|-q)
                quiet_mode=true
                shift
                ;;
            -h|--help)
                show_validate_help
                return 0
                ;;
            *)
                echo "ERROR: Unknown option: $1" >&2
                echo "Try 'nftban firewall validate --help' for more information." >&2
                return 1
                ;;
        esac
    done

    # Load core validator
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_validator.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_validator.sh" || return 1
    else
        [[ "$quiet_mode" != "true" ]] && echo "ERROR: Cannot find nftban_validator.sh" >&2
        return $VALIDATE_ENV_ERROR
    fi

    local validation_result=$VALIDATE_OK

    # Run structure validation (quiet mode suppresses all output)
    if [[ "$quiet_mode" == "true" ]]; then
        validate_structure "false" >/dev/null 2>&1 || validation_result=$VALIDATE_STRUCTURE_ERROR
    elif [[ "$output_json" == "true" ]]; then
        validate_structure "true" || validation_result=$VALIDATE_STRUCTURE_ERROR
    else
        validate_structure "false" || validation_result=$VALIDATE_STRUCTURE_ERROR
    fi

    # If strict mode, run additional checks
    if [[ "$strict_mode" == "true" ]]; then
        local strict_exit=$VALIDATE_OK
        if [[ "$quiet_mode" == "true" ]]; then
            _firewall_validate_strict "$output_json" >/dev/null 2>&1 || strict_exit=$?
        else
            _firewall_validate_strict "$output_json" || strict_exit=$?
        fi

        # Return the more severe exit code
        if [[ $strict_exit -ne $VALIDATE_OK ]]; then
            return $strict_exit
        fi
    fi

    return $validation_result
}

# =============================================================================
# STRICT MODE VALIDATION (Single Firewall Authority)
# =============================================================================

_firewall_validate_strict() {
    # Enforce Single Firewall Authority
    # Returns: 0=OK, 10=policykit, 20=conflict, 30=collision, 40=env
    local json_mode="${1:-false}"

    [[ "$json_mode" == "false" ]] && echo ""
    [[ "$json_mode" == "false" ]] && echo "STRICT MODE: Single Firewall Authority Check"
    [[ "$json_mode" == "false" ]] && echo "=============================================="

    # Check 1: policykit-1 on Debian/Ubuntu
    if ! _check_policykit "$json_mode"; then
        return $VALIDATE_POLICYKIT_MISSING
    fi

    # Check 2: Firewall authority conflicts
    if ! _check_firewall_conflicts "$json_mode"; then
        return $VALIDATE_FIREWALL_CONFLICT
    fi

    # Check 3: NFTables hook collisions (non-NFTBan active input hooks)
    if ! _check_nft_collisions "$json_mode"; then
        return $VALIDATE_NFT_COLLISION
    fi

    [[ "$json_mode" == "false" ]] && echo ""
    [[ "$json_mode" == "false" ]] && echo "STRICT PREFLIGHT: PASSED"
    [[ "$json_mode" == "false" ]] && echo "NFTBan is sole firewall authority - enforce mode OK"

    return $VALIDATE_OK
}

_check_policykit() {
    # Check policykit-1 on Debian/Ubuntu (MANDATORY)
    local json_mode="${1:-false}"

    # Detect distro
    local distro_id=""
    local distro_like=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release || true
        distro_id="${ID:-}"
        distro_like="${ID_LIKE:-}"
    fi

    # Only check on Debian/Ubuntu family
    local is_debian_ubuntu=false
    case "$distro_id" in
        debian|ubuntu) is_debian_ubuntu=true ;;
    esac
    [[ "$distro_like" == *debian* ]] && is_debian_ubuntu=true
    [[ "$distro_like" == *ubuntu* ]] && is_debian_ubuntu=true

    if [[ "$is_debian_ubuntu" == "false" ]]; then
        [[ "$json_mode" == "false" ]] && echo "[OK] policykit-1: Not required (non-Debian/Ubuntu)"
        return 0
    fi

    # Check polkit package (Debian 13+ renamed policykit-1 to polkitd)
    if command -v dpkg-query &>/dev/null; then
        if dpkg-query -W -f='${Status}\n' policykit-1 2>/dev/null | grep -q "install ok installed" || \
           dpkg-query -W -f='${Status}\n' polkitd 2>/dev/null | grep -q "install ok installed"; then
            [[ "$json_mode" == "false" ]] && echo "[OK] polkit: Installed"
            return 0
        else
            [[ "$json_mode" == "false" ]] && echo "[FAIL] polkit: MISSING (required on Debian/Ubuntu)"
            [[ "$json_mode" == "false" ]] && echo "       Fix: apt-get install -y polkitd  (or policykit-1 on older releases)"
            return 1
        fi
    else
        [[ "$json_mode" == "false" ]] && echo "[WARN] polkit: Cannot verify (dpkg-query missing)"
        return 1
    fi
}

_check_firewall_conflicts() {
    # Check for competing firewall authorities
    local json_mode="${1:-false}"

    # Load firewall conflicts library
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_firewall_conflicts.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_firewall_conflicts.sh" || return 1
    else
        [[ "$json_mode" == "false" ]] && echo "[WARN] Cannot load conflict detection library"
        return 0  # Don't fail if library missing
    fi

    # Run all conflict detection
    nftban_detect_all_conflicts
    local severity=$?

    # CRITICAL (3) = hard fail, WARNING (2) = fail in strict mode
    if [[ $severity -ge $CONFLICT_WARNING ]]; then
        [[ "$json_mode" == "false" ]] && echo "[FAIL] Firewall authority conflict detected"
        for conflict in "${NFTBAN_FIREWALL_CONFLICTS[@]}"; do
            [[ "$json_mode" == "false" ]] && echo "       $conflict"
        done
        [[ "$json_mode" == "false" ]] && echo ""
        [[ "$json_mode" == "false" ]] && echo "       Remediation:"
        for fix in "${NFTBAN_FIREWALL_FIXES[@]}"; do
            [[ "$json_mode" == "false" ]] && echo "       $fix"
        done
        return 1
    elif [[ $severity -eq $CONFLICT_INFO ]]; then
        [[ "$json_mode" == "false" ]] && echo "[OK] Firewall conflicts: Minor (non-blocking)"
        return 0
    else
        [[ "$json_mode" == "false" ]] && echo "[OK] Firewall conflicts: None detected"
        return 0
    fi
}

_check_nft_collisions() {
    # Check for non-NFTBan tables with active input hooks
    local json_mode="${1:-false}"

    # Get current ruleset
    local ruleset
    ruleset=$(nft -a list ruleset 2>/dev/null) || {
        [[ "$json_mode" == "false" ]] && echo "[WARN] Cannot read nftables ruleset"
        return 0
    }

    # Parse for non-nftban active input hooks
    # Active = has policy != accept OR has actual rules
    local collisions
    collisions=$(echo "$ruleset" | awk '
        BEGIN { family=""; table=""; chain=""; in_chain=0; has_hook=0; policy=""; rule_count=0; }
        /^table / { family=$2; table=$3; gsub(/{.*/, "", table); next }
        /^[[:space:]]*chain / {
            chain=$2; gsub(/{.*/, "", chain);
            in_chain=1; has_hook=0; policy=""; rule_count=0;
            next
        }
        in_chain && /hook[[:space:]]+input/ {
            has_hook=1
            if (match($0, /policy[[:space:]]+([a-zA-Z]+)/, m)) policy=m[1]
            next
        }
        in_chain && /^[[:space:]]+/ {
            line=$0
            if (index(line, "hook ") > 0) next
            if (index(line, "type ") > 0) next
            if (match(line, /^[[:space:]]*policy[[:space:]]/)) next
            if (match(line, /(saddr|daddr|sport|dport|tcp|udp|icmp|ct |counter|drop|reject|accept|log|meta|iif|oif)/)) {
                rule_count++
            }
            next
        }
        /^[[:space:]]*}[[:space:]]*$/ {
            if (in_chain && has_hook) {
                is_nftban = (table == "nftban") ? 1 : 0
                if (!is_nftban) {
                    is_active = 0
                    if (policy != "" && policy != "accept") is_active = 1
                    if (rule_count > 0) is_active = 1
                    if (is_active) {
                        printf "%s %s|%s|policy=%s|rules=%d\n", family, table, chain, policy, rule_count
                    }
                }
            }
            in_chain=0
            next
        }
    ')

    if [[ -n "$collisions" ]]; then
        [[ "$json_mode" == "false" ]] && echo "[FAIL] Non-NFTBan active input hooks detected:"
        echo "$collisions" | while IFS= read -r line; do
            [[ "$json_mode" == "false" ]] && echo "       $line"
        done
        [[ "$json_mode" == "false" ]] && echo ""
        [[ "$json_mode" == "false" ]] && echo "       Fix: nft flush ruleset && nftban firewall rebuild"
        return 1
    else
        [[ "$json_mode" == "false" ]] && echo "[OK] NFTables hooks: No conflicting input hooks"
        return 0
    fi
}

# =============================================================================
# SUBCOMMAND: CHECK
# =============================================================================

firewall_check() {
    # Check if IP or port is blocked/allowed
    # Args: <ip|port> [--json]

    local value=""
    local output_json=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                output_json=true
                shift
                ;;
            -h|--help)
                show_check_help
                return 0
                ;;
            -*)
                echo "ERROR: Unknown option: $1" >&2
                echo "Try 'nftban firewall check --help' for more information." >&2
                return 1
                ;;
            *)
                value="$1"
                shift
                ;;
        esac
    done

    # Validate value provided
    if [[ -z "$value" ]]; then
        echo "ERROR: No IP or port specified" >&2
        echo "Try 'nftban firewall check --help' for more information." >&2
        return 1
    fi

    # Load core validator
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_validator.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_validator.sh" || return 1
    else
        echo "ERROR: Cannot find nftban_validator.sh" >&2
        return 1
    fi

    # Run check
    if [[ "$output_json" == "true" ]]; then
        check_ip_or_port "$value" "true"
    else
        check_ip_or_port "$value" "false"
    fi
}

# =============================================================================
# SUBCOMMAND: STATS
# =============================================================================

firewall_stats() {
    # Display firewall statistics
    # Args: [--json]

    local output_json=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                output_json=true
                shift
                ;;
            -h|--help)
                show_stats_help
                return 0
                ;;
            *)
                echo "ERROR: Unknown option: $1" >&2
                echo "Try 'nftban firewall stats --help' for more information." >&2
                return 1
                ;;
        esac
    done

    # Load core validator
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_validator.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_validator.sh" || return 1
    else
        echo "ERROR: Cannot find nftban_validator.sh" >&2
        return 1
    fi

    # Get statistics
    if [[ "$output_json" == "true" ]]; then
        get_firewall_stats "true"
    else
        get_firewall_stats "false"
    fi
}

# =============================================================================
# SUBCOMMAND: RELOAD
# =============================================================================

firewall_reload() {
    # Reload nftables ruleset AND re-apply NFTBan rules
    # v1.23.0 FIX (P1-17): reload now re-applies NFTBan schema + syncs whitelist
    local quiet=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --quiet|-q)
                quiet=true
                shift
                ;;
            *)
                echo "ERROR: Unknown option: $1" >&2
                return 1
                ;;
        esac
    done

    # Step 1: Reload system nftables config
    local nft_conf
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR}/lib/nftban_distro_config.sh" 2>/dev/null || true
    nft_conf=$(nftban_distro_get_path "nftables_conf" 2>/dev/null)
    [[ -z "$nft_conf" ]] && nft_conf="/etc/nftables.conf"

    if [[ ! -f "$nft_conf" ]]; then
        echo "ERROR: nftables config not found: $nft_conf" >&2
        echo "Check distro config in /etc/nftban/distros/" >&2
        return 1
    fi

    [[ "$quiet" == "false" ]] && echo "Reloading nftables configuration..."
    if ! nft -f "$nft_conf" 2>&1; then
        echo "ERROR: Failed to reload nftables" >&2
        return 1
    fi

    # Step 2: Re-apply NFTBan schema
    local nftban_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftables.conf"
    if [[ -f "$nftban_conf" ]]; then
        [[ "$quiet" == "false" ]] && echo "Re-applying NFTBan schema..."
        # v1.24.0: Substitute __SSH_PORT__ placeholder with detected port
        local _ssh_port=22
        local _ssh_port_file="${NFTBAN_DATA_DIR:-/var/lib/nftban}/state/ssh_port_active.state"
        [[ -f "$_ssh_port_file" ]] && _ssh_port=$(cat "$_ssh_port_file" 2>/dev/null) || true
        [[ -z "$_ssh_port" || ! "$_ssh_port" =~ ^[0-9]+$ ]] && _ssh_port=22
        if grep -q '__SSH_PORT__' "$nftban_conf" 2>/dev/null; then
            local _tmp_conf
            _tmp_conf=$(mktemp) || { echo "ERROR: mktemp failed" >&2; return 1; }
            sed "s/__SSH_PORT__/${_ssh_port}/g" "$nftban_conf" > "$_tmp_conf"
            if ! nft -f "$_tmp_conf" 2>&1; then
                echo "Warning: Failed to re-apply NFTBan schema" >&2
                echo "Try: nftban firewall rebuild" >&2
            fi
            rm -f "$_tmp_conf"
        else
            if ! nft -f "$nftban_conf" 2>&1; then
                echo "Warning: Failed to re-apply NFTBan schema" >&2
                echo "Try: nftban firewall rebuild" >&2
            fi
        fi
    fi

    # Step 3: Re-sync system whitelist (ensures admin IPs are protected)
    [[ "$quiet" == "false" ]] && echo "Syncing whitelist..."
    nftban whitelist sync --quick 2>/dev/null || true

    # Step 4 (v1.34.0): Re-apply DDoS protection if it was enabled.
    # firewall reload destroys DDoS chains (synproxy, portscan, ddos_protection).
    # Without this step, reload leaves the server unprotected.
    local _ddos_enabled="false"
    local _ddos_local_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/ddos/main.conf.local"
    if [[ -f "$_ddos_local_conf" ]]; then
        _ddos_enabled=$(grep -oP '^DDOS_ENABLED="\K[^"]+' "$_ddos_local_conf" 2>/dev/null || echo "false")
    fi
    if [[ "$_ddos_enabled" == "true" ]]; then
        [[ "$quiet" == "false" ]] && echo "Re-applying DDoS protection rules..."
        nftban ddos reload 2>/dev/null || {
            [[ "$quiet" == "false" ]] && echo "Warning: Failed to re-apply DDoS rules. Run: nftban ddos reload"
        }
    fi

    if [[ "$quiet" == "false" ]]; then
        echo ""
        echo "═══════════════════════════════════════════════════════"
        echo "Firewall rules reloaded successfully"
    fi
}

# =============================================================================
# SUBCOMMAND: REBUILD
# =============================================================================

firewall_rebuild() {
    # Rebuild nftables schema from scratch (keeps existing IPs in sets)
    # This is the correct way to fix corrupted schema
    #
    # v1.47.0 DEPLOY-001: Atomic rebuild — validate BEFORE flushing
    # v1.47.0 DEPLOY-002: Detect .rpmnew files from RPM upgrades
    # v1.47.0 DEPLOY-003: Substitute __SSH_PORT__ placeholder
    local force=false
    local quiet=false
    local use_new=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force|-f)
                force=true
                shift
                ;;
            --quiet|-q)
                quiet=true
                shift
                ;;
            --use-new)
                # v1.47.0 DEPLOY-002: Prefer .rpmnew config over existing
                use_new=true
                shift
                ;;
            --help|-h)
                show_rebuild_help
                return 0
                ;;
            *)
                echo "ERROR: Unknown option: $1" >&2
                return 1
                ;;
        esac
    done

    [[ "$quiet" == "false" ]] && echo "Rebuilding NFTBan firewall schema..."

    # Step 1: Backup current IPs from sets (preserve bans/whitelist)
    local backup_dir="/var/lib/nftban/backup"
    mkdir -p "$backup_dir" || return 1
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)

    # v2.1: Only whitelist + blacklist sets exist (feeds/geoban merged into blacklist)
    [[ "$quiet" == "false" ]] && echo "  [1/7] Backing up current sets..."
    timeout 10s nft list set ip nftban whitelist_ipv4 2>/dev/null > "$backup_dir/whitelist_ipv4_$timestamp.txt" || true
    timeout 10s nft list set ip nftban blacklist_ipv4 2>/dev/null > "$backup_dir/blacklist_ipv4_$timestamp.txt" || true
    timeout 10s nft list set ip6 nftban whitelist_ipv6 2>/dev/null > "$backup_dir/whitelist_ipv6_$timestamp.txt" || true
    timeout 10s nft list set ip6 nftban blacklist_ipv6 2>/dev/null > "$backup_dir/blacklist_ipv6_$timestamp.txt" || true

    # v1.47.0 DEPLOY-002: Check for .rpmnew files (RPM upgrade left new config unmerged)
    local nftban_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftables.conf"
    local rpmnew_conf="${nftban_conf}.rpmnew"
    if [[ -f "$rpmnew_conf" ]]; then
        if [[ "$use_new" == "true" ]]; then
            [[ "$quiet" == "false" ]] && echo "  [INFO] Using new config from $rpmnew_conf (--use-new)"
            nftban_conf="$rpmnew_conf"
        else
            echo "" >&2
            echo "WARNING: New config available at $rpmnew_conf" >&2
            echo "  RPM upgrade created a new config but your existing one was modified." >&2
            echo "  The rebuild will use the OLD config. New features (named counters, etc.) may be missing." >&2
            echo "" >&2
            echo "  Options:" >&2
            echo "    1. Review and merge: diff $nftban_conf $rpmnew_conf" >&2
            echo "    2. Use new config:   nftban firewall rebuild --use-new" >&2
            echo "    3. Replace manually:  cp $rpmnew_conf $nftban_conf" >&2
            echo "" >&2
        fi
    fi

    if [[ ! -f "$nftban_conf" ]]; then
        echo "ERROR: NFTBan config not found: $nftban_conf" >&2
        return 1
    fi

    # v1.47.0 DEPLOY-003: Prepare config with placeholder substitution
    [[ "$quiet" == "false" ]] && echo "  [2/7] Preparing schema config..."
    local load_conf="$nftban_conf"
    local tmp_conf=""
    if grep -q '__SSH_PORT__' "$nftban_conf" 2>/dev/null; then
        local _ssh_port=22
        local _ssh_port_file="${NFTBAN_DATA_DIR:-/var/lib/nftban}/state/ssh_port_active.state"
        [[ -f "$_ssh_port_file" ]] && _ssh_port=$(cat "$_ssh_port_file" 2>/dev/null) || true
        [[ -z "$_ssh_port" || ! "$_ssh_port" =~ ^[0-9]+$ ]] && _ssh_port=22
        tmp_conf=$(mktemp) || { echo "ERROR: mktemp failed" >&2; return 1; }
        sed "s/__SSH_PORT__/${_ssh_port}/g" "$nftban_conf" > "$tmp_conf"
        load_conf="$tmp_conf"
        [[ "$quiet" == "false" ]] && echo "    Substituted __SSH_PORT__ → ${_ssh_port}"
    fi

    # v1.47.0 DEPLOY-001: Validate schema BEFORE flushing (atomic rebuild)
    # nft -c -f validates syntax without applying — prevents lockout on bad config
    [[ "$quiet" == "false" ]] && echo "  [3/7] Validating new schema (dry-run)..."
    local validate_output
    if ! validate_output=$(nft -c -f "$load_conf" 2>&1); then
        echo "ERROR: Schema validation FAILED — existing firewall preserved!" >&2
        echo "  Config: $nftban_conf" >&2
        echo "  Error:  $validate_output" >&2
        echo "" >&2
        echo "  Fix the config file and retry: nftban firewall rebuild" >&2
        [[ -n "$tmp_conf" ]] && rm -f "$tmp_conf"
        return 1
    fi
    [[ "$quiet" == "false" ]] && echo "    Schema validation: PASSED"

    # Step 4: Remove rogue tables (keep only NFTBan tables)
    [[ "$quiet" == "false" ]] && echo "  [4/7] Removing rogue tables..."
    # v1.48.0: Include SYNPROXY raw tables in allowed list
    local ALLOWED_TABLES_PATTERN="^table (ip|ip6) (nftban|raw)$|^table inet (filter|nftban)$"
    local ALL_TABLES
    ALL_TABLES=$(nft list tables 2>/dev/null || true)

    while IFS= read -r table_line; do
        [[ -z "$table_line" ]] && continue
        if ! echo "$table_line" | grep -qE "$ALLOWED_TABLES_PATTERN"; then
            local TABLE_SPEC="${table_line#table }"
            if nft delete table "$TABLE_SPEC" 2>/dev/null; then
                [[ "$quiet" == "false" ]] && echo "    Deleted rogue table: $TABLE_SPEC"
            fi
        fi
    done <<< "$ALL_TABLES"

    # Step 5: Flush + load (safe — we validated above)
    [[ "$quiet" == "false" ]] && echo "  [5/7] Flushing and loading new schema..."
    nft flush table ip nftban 2>/dev/null || true
    nft flush table ip6 nftban 2>/dev/null || true

    if ! nft -f "$load_conf" 2>&1; then
        echo "ERROR: Failed to load NFTBan schema from $nftban_conf" >&2
        echo "Try: nftban firewall reset --force" >&2
        [[ -n "$tmp_conf" ]] && rm -f "$tmp_conf"
        return 1
    fi
    [[ -n "$tmp_conf" ]] && rm -f "$tmp_conf"

    # Step 6: Re-sync system whitelist
    [[ "$quiet" == "false" ]] && echo "  [6/7] Re-syncing system whitelist..."
    nftban whitelist sync >/dev/null 2>&1 || true

    # Step 7: Restore blacklist from backup (BUG FIX: R74 - blacklist was never restored)
    [[ "$quiet" == "false" ]] && echo "  [7/7] Restoring blacklist from backup..."
    local restored_count=0
    for backup_file in "$backup_dir/blacklist_ipv4_$timestamp.txt" "$backup_dir/blacklist_ipv6_$timestamp.txt"; do
        [[ -f "$backup_file" ]] || continue
        # Extract elements from backup (format: elements = { ip1, ip2, ... })
        local elements
        # v1.19.20 FIX: Prevent pipefail exit 1 when grep finds no match
        elements=$(grep -oP 'elements = \{ \K[^}]+' "$backup_file" 2>/dev/null | tr -d '\n\t' | sed 's/  */ /g' || true)
        [[ -z "$elements" ]] && continue

        # v1.19.27 SECURITY: Validate elements contain only safe characters (defense-in-depth)
        # Allow: digits, dots, colons (IPv6), slashes (CIDR), commas, spaces, 'timeout', 's/m/h/d'
        if [[ ! "$elements" =~ ^[0-9a-fA-F.:,/[:space:]timeouts]+$ ]]; then
            [[ "$quiet" == "false" ]] && echo "    WARNING: Skipping backup with invalid characters: $backup_file"
            continue
        fi

        # Determine table and set from filename
        local table_family set_name
        if [[ "$backup_file" == *ipv4* ]]; then
            table_family="ip nftban"
            set_name="blacklist_ipv4"
        else
            table_family="ip6 nftban"
            set_name="blacklist_ipv6"
        fi
        # Add elements back to set
        if nft add element $table_family $set_name "{ $elements }" 2>/dev/null; then
            # v1.19.20 FIX
            ((restored_count++)) || true
            [[ "$quiet" == "false" ]] && echo "    Restored: $set_name"
        fi
    done
    [[ "$quiet" == "false" && "$restored_count" -eq 0 ]] && echo "    No blacklist entries to restore"

    # Handle .rpmnew: if --use-new succeeded, move old config to .bak and new to canonical
    if [[ "$use_new" == "true" && -f "$rpmnew_conf" ]]; then
        local canonical_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftables.conf"
        cp "$canonical_conf" "${canonical_conf}.bak.${timestamp}" 2>/dev/null || true
        mv "$rpmnew_conf" "$canonical_conf" 2>/dev/null || true
        [[ "$quiet" == "false" ]] && echo "  Promoted .rpmnew to canonical config (old saved as .bak.${timestamp})"
    fi

    [[ "$quiet" == "false" ]] && echo ""
    [[ "$quiet" == "false" ]] && echo "Schema rebuilt successfully!"
    [[ "$quiet" == "false" ]] && echo "Backup saved to: $backup_dir/*_$timestamp.txt"

    # Validate the new schema
    [[ "$quiet" == "false" ]] && echo ""
    [[ "$quiet" == "false" ]] && firewall_validate --quiet && echo "Schema validation: PASSED" || echo "Schema validation: WARNING (check with nftban firewall validate)"

    return 0
}

# =============================================================================
# SUBCOMMAND: RESET
# =============================================================================

firewall_reset() {
    # Complete firewall reset - flush everything and rebuild clean
    # WARNING: This will remove all bans, whitelists, and geoban data!
    local force=false
    local quiet=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force|-f)
                force=true
                shift
                ;;
            --quiet|-q)
                quiet=true
                shift
                ;;
            --help|-h)
                show_reset_help
                return 0
                ;;
            *)
                echo "ERROR: Unknown option: $1" >&2
                return 1
                ;;
        esac
    done

    if [[ "$force" == "false" ]]; then
        echo "WARNING: This will completely reset the firewall!"
        echo ""
        echo "The following will be DELETED:"
        echo "  - All banned IPs"
        echo "  - All whitelisted IPs (will be re-synced)"
        echo "  - All GeoBan entries"
        echo "  - All threat feed entries"
        echo ""
        echo "Use --force to confirm, or Ctrl+C to cancel."
        return 1
    fi

    [[ "$quiet" == "false" ]] && echo "Performing complete firewall reset..."

    # Step 1: Stop nftban services temporarily
    [[ "$quiet" == "false" ]] && echo "  [1/6] Stopping NFTBan services..."
    systemctl stop nftban-maintenance.timer 2>/dev/null || true
    systemctl stop nftband 2>/dev/null || true

    # Step 2: Backup current ruleset
    local backup_dir="/var/lib/nftban/backup"
    mkdir -p "$backup_dir" || return 1
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    [[ "$quiet" == "false" ]] && echo "  [2/6] Backing up current ruleset..."
    nft list ruleset > "$backup_dir/ruleset_$timestamp.nft" 2>/dev/null || true

    # Step 3: Remove NFTBan tables (preserves Docker/cPanel/foreign tables)
    [[ "$quiet" == "false" ]] && echo "  [3/6] Removing NFTBan tables..."
    nft delete table ip nftban 2>/dev/null || true
    nft delete table ip6 nftban 2>/dev/null || true

    # Step 4: Reload NFTBan schema
    [[ "$quiet" == "false" ]] && echo "  [4/6] Loading clean NFTBan schema..."
    local nftban_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftables.conf"
    if [[ -f "$nftban_conf" ]]; then
        if ! nft -f "$nftban_conf" 2>&1; then
            echo "ERROR: Failed to load NFTBan schema" >&2
            echo "Restoring backup..." >&2
            nft -f "$backup_dir/ruleset_$timestamp.nft" 2>/dev/null || true
            return 1
        fi
    fi

    # Step 5: Re-sync system whitelist (lockout protection)
    [[ "$quiet" == "false" ]] && echo "  [5/6] Re-syncing system whitelist..."
    nftban whitelist sync >/dev/null 2>&1 || true

    # Step 6: Restart services
    [[ "$quiet" == "false" ]] && echo "  [6/6] Restarting NFTBan services..."
    systemctl start nftban-maintenance.timer 2>/dev/null || true
    systemctl start nftband 2>/dev/null || true

    [[ "$quiet" == "false" ]] && echo ""
    [[ "$quiet" == "false" ]] && echo "Firewall reset complete!"
    [[ "$quiet" == "false" ]] && echo "Backup saved to: $backup_dir/ruleset_$timestamp.nft"
    [[ "$quiet" == "false" ]] && echo ""
    [[ "$quiet" == "false" ]] && echo "Next steps:"
    [[ "$quiet" == "false" ]] && echo "  - Run 'nftban geoban sync' to restore GeoBan"
    [[ "$quiet" == "false" ]] && echo "  - Run 'nftban feeds sync' to restore threat feeds"

    return 0
}

# =============================================================================
# SUBCOMMAND: RESTORE (Enterprise Rollback)
# =============================================================================

firewall_restore() {
    # Enterprise rollback - restore previous firewall state
    # Usage: nftban firewall restore <action>
    # Actions:
    #   list      - Show available backups
    #   backup    - Create manual backup
    #   <file>    - Restore from specific backup file
    #   fail2ban  - Re-enable fail2ban
    #   csf       - Re-enable CSF
    #   ufw       - Re-enable UFW
    #   firewalld - Re-enable firewalld

    local action="${1:-list}"
    shift 2>/dev/null || true

    case "$action" in
        -h|--help|help)
            show_restore_help
            return 0
            ;;
        list)
            _restore_list_backups
            ;;
        backup)
            _restore_create_backup "$@"
            ;;
        fail2ban|csf|ufw|firewalld)
            _restore_previous_firewall "$action"
            ;;
        *)
            # Assume it's a backup file path
            if [[ -f "$action" ]]; then
                _restore_from_file "$action"
            elif [[ -f "/var/lib/nftban/backup/$action" ]]; then
                _restore_from_file "/var/lib/nftban/backup/$action"
            else
                echo "ERROR: Unknown action or backup file not found: $action" >&2
                show_restore_help
                return 1
            fi
            ;;
    esac
}

_restore_list_backups() {
    local backup_dir="/var/lib/nftban/backup"

    echo "Available NFTBan Backups"
    echo "========================"
    echo ""

    if [[ ! -d "$backup_dir" ]]; then
        echo "No backup directory found: $backup_dir"
        return 0
    fi

    local count=0
    for f in "$backup_dir"/ruleset_*.nft; do
        [[ -f "$f" ]] || continue
        local fname
        fname=$(basename "$f")
        local fsize
        fsize=$(stat -c%s "$f" 2>/dev/null || echo "?")
        local fdate
        fdate=$(stat -c%y "$f" 2>/dev/null | cut -d. -f1 || echo "?")
        printf "  %-40s %8s bytes  %s\n" "$fname" "$fsize" "$fdate"
        count=$((count + 1))
    done

    if [[ $count -eq 0 ]]; then
        echo "  No backups found"
    fi

    echo ""
    echo "To restore: nftban firewall restore <filename>"
}

_restore_create_backup() {
    local backup_dir="/var/lib/nftban/backup"
    local label="${1:-manual}"

    mkdir -p "$backup_dir" || return 1

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="$backup_dir/ruleset_${label}_$timestamp.nft"

    echo "Creating backup..."
    if nft list ruleset > "$backup_file" 2>/dev/null; then
        echo "Backup saved: $backup_file"
        return 0
    else
        echo "ERROR: Failed to create backup" >&2
        return 1
    fi
}

_restore_from_file() {
    local backup_file="$1"

    echo "Restoring from: $backup_file"
    echo ""

    # Safety: stop NFTBan services first
    echo "[1/4] Stopping NFTBan services..."
    systemctl stop nftban-maintenance.timer 2>/dev/null || true
    systemctl stop nftband 2>/dev/null || true

    # Flush current ruleset
    echo "[2/4] Flushing current ruleset..."
    nft flush ruleset 2>/dev/null || true

    # Restore backup
    echo "[3/4] Restoring backup..."
    if ! nft -f "$backup_file" 2>&1; then
        echo "ERROR: Failed to restore backup" >&2
        echo "Attempting to reload NFTBan schema..." >&2
        # v1.24.0: Substitute __SSH_PORT__ if present
        local _nftban_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftables.conf"
        if grep -q '__SSH_PORT__' "$_nftban_conf" 2>/dev/null; then
            local _ssh_port=22 _tmp_f
            local _sp_f="${NFTBAN_DATA_DIR:-/var/lib/nftban}/state/ssh_port_active.state"
            [[ -f "$_sp_f" ]] && _ssh_port=$(cat "$_sp_f" 2>/dev/null) || true
            [[ -z "$_ssh_port" || ! "$_ssh_port" =~ ^[0-9]+$ ]] && _ssh_port=22
            _tmp_f=$(mktemp 2>/dev/null) || _tmp_f=""
            if [[ -n "$_tmp_f" ]]; then
                sed "s/__SSH_PORT__/${_ssh_port}/g" "$_nftban_conf" > "$_tmp_f"
                nft -f "$_tmp_f" 2>/dev/null || true
                rm -f "$_tmp_f"
            else
                nft -f "$_nftban_conf" 2>/dev/null || true
            fi
        else
            nft -f "$_nftban_conf" 2>/dev/null || true
        fi
        return 1
    fi

    # Restart services
    echo "[4/4] Restarting NFTBan services..."
    systemctl start nftban-maintenance.timer 2>/dev/null || true
    systemctl start nftband 2>/dev/null || true

    echo ""
    echo "Restore complete!"
}

_restore_previous_firewall() {
    local firewall="$1"

    echo "Restoring previous firewall: $firewall"
    echo "======================================="
    echo ""
    echo "WARNING: This will disable NFTBan and re-enable $firewall"
    echo ""

    # Step 1: Disable NFTBan
    echo "[1/4] Disabling NFTBan services..."
    systemctl stop nftban-maintenance.timer 2>/dev/null || true
    systemctl stop nftband 2>/dev/null || true
    systemctl disable nftban-maintenance.timer 2>/dev/null || true
    systemctl disable nftband 2>/dev/null || true

    # Step 2: Flush NFTBan tables
    echo "[2/4] Flushing NFTBan nftables..."
    nft delete table ip nftban 2>/dev/null || true
    nft delete table ip6 nftban 2>/dev/null || true

    # Step 3: Re-enable previous firewall
    echo "[3/4] Re-enabling $firewall..."
    case "$firewall" in
        fail2ban)
            systemctl enable fail2ban 2>/dev/null || true
            systemctl start fail2ban 2>/dev/null || true
            ;;
        csf)
            if command -v csf &>/dev/null; then
                csf -e 2>/dev/null || true
            fi
            systemctl enable lfd 2>/dev/null || true
            systemctl start lfd 2>/dev/null || true
            ;;
        ufw)
            systemctl enable ufw 2>/dev/null || true
            systemctl start ufw 2>/dev/null || true
            ufw enable 2>/dev/null || true
            ;;
        firewalld)
            systemctl enable firewalld 2>/dev/null || true
            systemctl start firewalld 2>/dev/null || true
            ;;
    esac

    # Step 4: Verify
    echo "[4/4] Verifying..."
    if systemctl is-active --quiet "$firewall" 2>/dev/null; then
        echo ""
        echo "$firewall is now ACTIVE"
        echo "NFTBan has been disabled"
        echo ""
        echo "To return to NFTBan:"
        echo "  systemctl disable --now $firewall"
        echo "  nftban enable all"
    else
        echo ""
        echo "WARNING: $firewall may not have started correctly"
        echo "Check: systemctl status $firewall"
    fi
}

# =============================================================================
# SUBCOMMAND: RECORD (Schema Snapshot for Audit/Comparison)
# =============================================================================

firewall_record() {
    # Snapshot current live nft schema to JSON for audit/comparison.
    # Usage: nftban firewall record [--output <path>] [--json] [--diff <path>]

    local output_file="/var/lib/nftban/schema/schema_record.json"
    local to_stdout=false
    local diff_file=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output|-o)
                shift
                if [[ $# -eq 0 || "$1" == -* ]]; then
                    echo "ERROR: --output requires a file path" >&2
                    return 1
                fi
                output_file="$1"
                shift
                ;;
            --json)
                to_stdout=true
                shift
                ;;
            --diff|-d)
                shift
                if [[ $# -eq 0 || "$1" == -* ]]; then
                    echo "ERROR: --diff requires a file path" >&2
                    return 1
                fi
                diff_file="$1"
                shift
                ;;
            -h|--help)
                show_record_help
                return 0
                ;;
            *)
                echo "ERROR: Unknown option: $1" >&2
                echo "Try 'nftban firewall record --help' for more information." >&2
                return 1
                ;;
        esac
    done

    # Diff mode: compare current schema against a previously recorded file
    if [[ -n "$diff_file" ]]; then
        _firewall_record_diff "$diff_file"
        return $?
    fi

    # Ensure jq is available (required for JSON generation)
    if ! command -v jq &>/dev/null; then
        echo "ERROR: jq is required for schema recording. Install with: apt install jq" >&2
        return 1
    fi

    # Ensure nft_schema.sh is loaded
    if [[ -z "${NFTBAN_NFT_SCHEMA_LOADED:-}" ]]; then
        if [[ -f "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" ]]; then
            # shellcheck source=/dev/null
            source "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" || {
                echo "ERROR: Cannot load nft_schema.sh" >&2
                return 1
            }
        fi
    fi

    # Get nftban version
    local nftban_version="unknown"
    if [[ -f /VERSION ]]; then
        nftban_version=$(cat /VERSION 2>/dev/null | tr -d '[:space:]')
    fi

    # ── Collect table information ──
    local tables_json="[]"
    local existing_tables
    existing_tables=$(nft list tables 2>/dev/null || true)
    local table_arr=()
    if echo "$existing_tables" | grep -q "^table ${NFTBAN_TABLE_IPV4}$"; then
        table_arr+=("\"${NFTBAN_TABLE_IPV4}\"")
    fi
    if echo "$existing_tables" | grep -q "^table ${NFTBAN_TABLE_IPV6}$"; then
        table_arr+=("\"${NFTBAN_TABLE_IPV6}\"")
    fi
    if [[ ${#table_arr[@]} -gt 0 ]]; then
        tables_json=$(printf '%s\n' "${table_arr[@]}" | jq -s '.')
    fi

    # ── Collect set information (IPv4) ──
    local ipv4_sets_json="{}"
    local ipv4_set_entries=""
    for set_name in "${!NFTBAN_IPV4_SETS[@]}"; do
        local set_spec="${NFTBAN_IPV4_SETS[$set_name]}"
        local _expected_type _expected_flags
        IFS='|' read -r _expected_type _expected_flags _ <<< "$set_spec"

        local count=0
        local actual_type="" actual_flags=""
        if nft list set ip nftban "$set_name" &>/dev/null; then
            count=$(nftban_nft_count_set ip nftban "$set_name" 2>/dev/null || echo 0)
            local set_info
            set_info=$(nft list set ip nftban "$set_name" 2>/dev/null)
            actual_type=$(echo "$set_info" | grep -oP 'type \K[a-z0-9_]+' | head -1 || true)
            actual_flags=$(echo "$set_info" | grep -oP 'flags \K[a-z,]+' | head -1 || true)
        fi

        local entry
        entry=$(jq -n \
            --arg type "${actual_type:-missing}" \
            --arg flags "${actual_flags:-}" \
            --argjson elements "${count:-0}" \
            '{type: $type, flags: $flags, elements: $elements}')
        ipv4_set_entries="${ipv4_set_entries}$(jq -n --arg k "$set_name" --argjson v "$entry" '{($k): $v}')"$'\n'
    done
    if [[ -n "$ipv4_set_entries" ]]; then
        ipv4_sets_json=$(echo "$ipv4_set_entries" | jq -s 'add')
    fi

    # ── Collect set information (IPv6) ──
    local ipv6_sets_json="{}"
    local ipv6_set_entries=""
    for set_name in "${!NFTBAN_IPV6_SETS[@]}"; do
        local set_spec="${NFTBAN_IPV6_SETS[$set_name]}"
        local _expected_type _expected_flags
        IFS='|' read -r _expected_type _expected_flags _ <<< "$set_spec"

        local count=0
        local actual_type="" actual_flags=""
        if nft list set ip6 nftban "$set_name" &>/dev/null; then
            count=$(nftban_nft_count_set ip6 nftban "$set_name" 2>/dev/null || echo 0)
            local set_info
            set_info=$(nft list set ip6 nftban "$set_name" 2>/dev/null)
            actual_type=$(echo "$set_info" | grep -oP 'type \K[a-z0-9_]+' | head -1 || true)
            actual_flags=$(echo "$set_info" | grep -oP 'flags \K[a-z,]+' | head -1 || true)
        fi

        local entry
        entry=$(jq -n \
            --arg type "${actual_type:-missing}" \
            --arg flags "${actual_flags:-}" \
            --argjson elements "${count:-0}" \
            '{type: $type, flags: $flags, elements: $elements}')
        ipv6_set_entries="${ipv6_set_entries}$(jq -n --arg k "$set_name" --argjson v "$entry" '{($k): $v}')"$'\n'
    done
    if [[ -n "$ipv6_set_entries" ]]; then
        ipv6_sets_json=$(echo "$ipv6_set_entries" | jq -s 'add')
    fi

    # ── Collect chain information ──
    local ipv4_chains_json="{}"
    local ipv4_chain_entries=""
    for chain_name in "${!NFTBAN_IPV4_CHAINS[@]}"; do
        local chain_spec="${NFTBAN_IPV4_CHAINS[$chain_name]}"
        local chain_type chain_hook chain_priority _chain_policy
        IFS='|' read -r chain_type chain_hook chain_priority _chain_policy _ <<< "$chain_spec"

        local actual_policy=""
        if nft list chain ip nftban "$chain_name" &>/dev/null; then
            local chain_info
            chain_info=$(nft list chain ip nftban "$chain_name" 2>/dev/null || true)
            chain_info=$(echo "$chain_info" | head -3)
            actual_policy=$(echo "$chain_info" | grep -oP 'policy \K[a-z]+' || true)
        fi

        local entry
        entry=$(jq -n \
            --arg type "$chain_type" \
            --arg hook "$chain_hook" \
            --argjson priority "$chain_priority" \
            --arg policy "${actual_policy:-missing}" \
            '{type: $type, hook: $hook, priority: $priority, policy: $policy}')
        ipv4_chain_entries="${ipv4_chain_entries}$(jq -n --arg k "$chain_name" --argjson v "$entry" '{($k): $v}')"$'\n'
    done
    if [[ -n "$ipv4_chain_entries" ]]; then
        ipv4_chains_json=$(echo "$ipv4_chain_entries" | jq -s 'add')
    fi

    local ipv6_chains_json="{}"
    local ipv6_chain_entries=""
    for chain_name in "${!NFTBAN_IPV6_CHAINS[@]}"; do
        local chain_spec="${NFTBAN_IPV6_CHAINS[$chain_name]}"
        local chain_type chain_hook chain_priority _chain_policy
        IFS='|' read -r chain_type chain_hook chain_priority _chain_policy _ <<< "$chain_spec"

        local actual_policy=""
        if nft list chain ip6 nftban "$chain_name" &>/dev/null; then
            local chain_info
            chain_info=$(nft list chain ip6 nftban "$chain_name" 2>/dev/null || true)
            chain_info=$(echo "$chain_info" | head -3)
            actual_policy=$(echo "$chain_info" | grep -oP 'policy \K[a-z]+' || true)
        fi

        local entry
        entry=$(jq -n \
            --arg type "$chain_type" \
            --arg hook "$chain_hook" \
            --argjson priority "$chain_priority" \
            --arg policy "${actual_policy:-missing}" \
            '{type: $type, hook: $hook, priority: $priority, policy: $policy}')
        ipv6_chain_entries="${ipv6_chain_entries}$(jq -n --arg k "$chain_name" --argjson v "$entry" '{($k): $v}')"$'\n'
    done
    if [[ -n "$ipv6_chain_entries" ]]; then
        ipv6_chains_json=$(echo "$ipv6_chain_entries" | jq -s 'add')
    fi

    # ── Collect rule order validation ──
    local rule_order_json="{}"
    local ip_wl_before_bl=false ip_bl_before_est=false
    local ip6_wl_before_bl=false ip6_bl_before_est=false

    for family in ip ip6; do
        local wl_set="whitelist_ipv4" bl_set="blacklist_ipv4"
        [[ "$family" == "ip6" ]] && wl_set="whitelist_ipv6" && bl_set="blacklist_ipv6"

        local rules
        rules=$(nft -a list chain "$family" nftban input 2>/dev/null || true)
        [[ -z "$rules" ]] && continue

        local wl_h bl_h est_h
        wl_h=$(echo "$rules" | grep -E "@${wl_set}.*accept" | grep -oP 'handle \K[0-9]+' | head -1 || true)
        bl_h=$(echo "$rules" | grep -E "@${bl_set}.*drop" | grep -oP 'handle \K[0-9]+' | head -1 || true)
        est_h=$(echo "$rules" | grep -E 'ct state.*established' | grep -oP 'handle \K[0-9]+' | head -1 || true)

        wl_h=${wl_h:-0}; bl_h=${bl_h:-0}; est_h=${est_h:-0}

        local wl_bl=false bl_est=false
        [[ $wl_h -gt 0 && $bl_h -gt 0 && $wl_h -lt $bl_h ]] && wl_bl=true
        [[ $bl_h -gt 0 && $est_h -gt 0 && $bl_h -lt $est_h ]] && bl_est=true

        if [[ "$family" == "ip" ]]; then
            ip_wl_before_bl=$wl_bl
            ip_bl_before_est=$bl_est
        else
            ip6_wl_before_bl=$wl_bl
            ip6_bl_before_est=$bl_est
        fi
    done

    rule_order_json=$(jq -n \
        --argjson ip_wl "$ip_wl_before_bl" \
        --argjson ip_bl "$ip_bl_before_est" \
        --argjson ip6_wl "$ip6_wl_before_bl" \
        --argjson ip6_bl "$ip6_bl_before_est" \
        '{ip: {whitelist_before_blacklist: $ip_wl, blacklist_before_established: $ip_bl}, ip6: {whitelist_before_blacklist: $ip6_wl, blacklist_before_established: $ip6_bl}}')

    # ── Run validation checks ──
    local tables_ok=false sets_ok=false chains_ok=false types_ok=false rule_order_ok=false
    nftban_nft_validate_tables &>/dev/null && tables_ok=true
    nftban_nft_validate_sets &>/dev/null && sets_ok=true
    nftban_nft_validate_chains &>/dev/null && chains_ok=true
    nftban_nft_validate_set_flags &>/dev/null && types_ok=true
    nftban_nft_validate_rule_order &>/dev/null && rule_order_ok=true

    local overall="PASS"
    if [[ "$tables_ok" != "true" || "$sets_ok" != "true" || "$chains_ok" != "true" || "$types_ok" != "true" || "$rule_order_ok" != "true" ]]; then
        overall="FAIL"
    fi

    local validation_json
    validation_json=$(jq -n \
        --argjson tables_ok "$tables_ok" \
        --argjson sets_ok "$sets_ok" \
        --argjson chains_ok "$chains_ok" \
        --argjson types_ok "$types_ok" \
        --argjson rule_order_ok "$rule_order_ok" \
        --arg overall "$overall" \
        '{tables_ok: $tables_ok, sets_ok: $sets_ok, chains_ok: $chains_ok, types_ok: $types_ok, rule_order_ok: $rule_order_ok, overall: $overall}')

    # ── Assemble final JSON ──
    local recorded_at
    recorded_at=$(date -Is 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')

    local final_json
    final_json=$(jq -n \
        --arg recorded_at "$recorded_at" \
        --arg nftban_version "$nftban_version" \
        --argjson tables "$tables_json" \
        --argjson ipv4_sets "$ipv4_sets_json" \
        --argjson ipv6_sets "$ipv6_sets_json" \
        --argjson ipv4_chains "$ipv4_chains_json" \
        --argjson ipv6_chains "$ipv6_chains_json" \
        --argjson rule_order "$rule_order_json" \
        --argjson validation "$validation_json" \
        '{
            recorded_at: $recorded_at,
            nftban_version: $nftban_version,
            schema: {
                tables: $tables,
                sets: {
                    "ip nftban": $ipv4_sets,
                    "ip6 nftban": $ipv6_sets
                },
                chains: {
                    "ip nftban": $ipv4_chains,
                    "ip6 nftban": $ipv6_chains
                },
                rule_order: $rule_order,
                validation: $validation
            }
        }')

    # ── Output ──
    if [[ "$to_stdout" == "true" ]]; then
        echo "$final_json"
    else
        # Write to file
        local output_dir
        output_dir=$(dirname "$output_file")
        if [[ ! -d "$output_dir" ]]; then
            mkdir -p "$output_dir" 2>/dev/null || {
                echo "ERROR: Cannot create directory: $output_dir" >&2
                return 1
            }
        fi
        echo "$final_json" > "$output_file" || {
            echo "ERROR: Cannot write to: $output_file" >&2
            return 1
        }
        echo "Schema recorded to: $output_file"
        echo "Version: $nftban_version"
        echo "Validation: $overall"
        echo "Tables: $(echo "$tables_json" | jq -r 'length') | Sets: $((${#NFTBAN_IPV4_SETS[@]} + ${#NFTBAN_IPV6_SETS[@]})) | Chains: $((${#NFTBAN_IPV4_CHAINS[@]} + ${#NFTBAN_IPV6_CHAINS[@]}))"
    fi

    return 0
}

_firewall_record_diff() {
    # Compare current live schema against a previously recorded JSON file
    local baseline_file="$1"

    if [[ ! -f "$baseline_file" ]]; then
        echo "ERROR: Baseline file not found: $baseline_file" >&2
        return 1
    fi

    if ! command -v jq &>/dev/null; then
        echo "ERROR: jq is required for schema diff. Install with: apt install jq" >&2
        return 1
    fi

    # Validate JSON
    if ! jq empty "$baseline_file" 2>/dev/null; then
        echo "ERROR: Invalid JSON in baseline file: $baseline_file" >&2
        return 1
    fi

    # Record current state to temp file
    local current_file
    current_file=$(mktemp /tmp/nftban_schema_current_XXXXXX.json) || return 1

    # Capture current schema to stdout
    firewall_record --json > "$current_file" 2>/dev/null || {
        echo "ERROR: Failed to record current schema" >&2
        rm -f "$current_file"
        return 1
    }

    local baseline_time baseline_version
    baseline_time=$(jq -r '.recorded_at // "unknown"' "$baseline_file")
    baseline_version=$(jq -r '.nftban_version // "unknown"' "$baseline_file")
    local current_version
    current_version=$(jq -r '.nftban_version // "unknown"' "$current_file")

    echo "NFTBan Schema Diff"
    echo "==================="
    echo ""
    echo "Baseline: $baseline_file"
    echo "  Recorded: $baseline_time"
    echo "  Version:  $baseline_version"
    echo ""
    echo "Current:"
    echo "  Version:  $current_version"
    echo ""

    local changes=0

    # Compare tables
    local baseline_tables current_tables
    baseline_tables=$(jq -r '.schema.tables // [] | sort | .[]' "$baseline_file" 2>/dev/null)
    current_tables=$(jq -r '.schema.tables // [] | sort | .[]' "$current_file" 2>/dev/null)

    if [[ "$baseline_tables" != "$current_tables" ]]; then
        echo "Tables: CHANGED"
        local added removed
        added=$(comm -13 <(echo "$baseline_tables" | sort) <(echo "$current_tables" | sort) 2>/dev/null || true)
        removed=$(comm -23 <(echo "$baseline_tables" | sort) <(echo "$current_tables" | sort) 2>/dev/null || true)
        [[ -n "$added" ]] && echo "  Added: $added"
        [[ -n "$removed" ]] && echo "  Removed: $removed"
        changes=$((changes + 1))
    else
        echo "Tables: unchanged"
    fi

    # Compare sets (count changes)
    echo ""
    echo "Set Element Counts:"
    for table_key in "ip nftban" "ip6 nftban"; do
        local jq_key="$table_key"
        local baseline_sets current_sets
        baseline_sets=$(jq -r --arg t "$jq_key" '.schema.sets[$t] // {} | keys[]' "$baseline_file" 2>/dev/null | sort)
        current_sets=$(jq -r --arg t "$jq_key" '.schema.sets[$t] // {} | keys[]' "$current_file" 2>/dev/null | sort)

        for set_name in $(echo -e "${baseline_sets}\n${current_sets}" | sort -u); do
            local b_count c_count
            b_count=$(jq -r --arg t "$jq_key" --arg s "$set_name" '.schema.sets[$t][$s].elements // 0' "$baseline_file" 2>/dev/null)
            c_count=$(jq -r --arg t "$jq_key" --arg s "$set_name" '.schema.sets[$t][$s].elements // 0' "$current_file" 2>/dev/null)
            if [[ "$b_count" != "$c_count" ]]; then
                local delta=$((c_count - b_count))
                local sign="+"
                [[ $delta -lt 0 ]] && sign=""
                echo "  ${table_key} ${set_name}: ${b_count} -> ${c_count} (${sign}${delta})"
                changes=$((changes + 1))
            fi
        done
    done

    # Compare validation results
    echo ""
    local baseline_overall current_overall
    baseline_overall=$(jq -r '.schema.validation.overall // "unknown"' "$baseline_file" 2>/dev/null)
    current_overall=$(jq -r '.schema.validation.overall // "unknown"' "$current_file" 2>/dev/null)
    if [[ "$baseline_overall" != "$current_overall" ]]; then
        echo "Validation: ${baseline_overall} -> ${current_overall}"
        changes=$((changes + 1))
    else
        echo "Validation: ${current_overall} (unchanged)"
    fi

    echo ""
    if [[ $changes -eq 0 ]]; then
        echo "Result: No differences detected"
    else
        echo "Result: ${changes} change(s) detected"
    fi

    rm -f "$current_file"
    return 0
}

# =============================================================================
# HELP FUNCTIONS
# =============================================================================

show_firewall_help() {
    cat <<'EOF'
Usage: nftban firewall <subcommand> [options]

Firewall structure validation, IP/port checking, and management.

Overview:
  status        Quick overview (tables, sets, services, conflicts)
  stats         Show firewall statistics (tables, chains, sets, IPs)

Validation & Diagnostics:
  validate      Validate nftables structure (use --strict for full check)
  conflicts     Detect conflicting firewalls (fail2ban, ufw, etc.)
  check         Check if IP or port is blocked/allowed
  logs          View and filter firewall logs
  record        Snapshot current nft schema to JSON for audit/comparison

Operations:
  init          Initialize firewall tables (alias for rebuild)
  reload        Reload nftables ruleset from config
  rebuild       Rebuild schema (fix corruption, keeps IPs)
  reset         Complete reset (flush all, rebuild clean)
  restore       Enterprise rollback (restore previous state)

Examples:
  # Validate with strict mode (recommended before enabling)
  nftban firewall validate --strict

  # Check for conflicting firewalls
  nftban firewall conflicts

  # Quick checks
  nftban firewall check 1.2.3.4
  nftban firewall stats

  # Schema audit
  nftban firewall record               # Snapshot schema to JSON
  nftban firewall record --json        # Output to stdout
  nftban firewall record --diff file   # Compare against baseline

  # Recovery operations
  nftban firewall rebuild              # Fix corruption
  nftban firewall reset --force        # Full reset
  nftban firewall restore list         # Show backups
  nftban firewall restore fail2ban     # Rollback to fail2ban

Global options:
  --json        Output results as JSON (for GUI integration)
  -h, --help    Show help for specific subcommand

Exit codes (validate --strict):
  0   OK - NFTBan is sole firewall authority
  10  policykit-1 missing (Debian/Ubuntu)
  20  Firewall conflict (fail2ban/ufw/firewalld/csf active)
  30  NFTables collision (non-NFTBan input hooks)

For detailed help:
  nftban firewall validate --help
  nftban firewall restore --help

EOF
}

show_restore_help() {
    cat <<'EOF'
Usage: nftban firewall restore <action>

Enterprise rollback - restore previous firewall state.

Actions:
  list              Show available backup files
  backup [label]    Create manual backup with optional label
  <filename>        Restore from specific backup file
  fail2ban          Disable NFTBan, re-enable fail2ban
  csf               Disable NFTBan, re-enable CSF
  ufw               Disable NFTBan, re-enable UFW
  firewalld         Disable NFTBan, re-enable firewalld

Examples:
  # List available backups
  nftban firewall restore list

  # Create manual backup
  nftban firewall restore backup pre-upgrade

  # Restore from backup file
  nftban firewall restore ruleset_20260220_143000.nft

  # Rollback to previous firewall
  nftban firewall restore fail2ban

Backup location: /var/lib/nftban/backup/

What 'restore <firewall>' does:
  1. Stops NFTBan services
  2. Disables NFTBan services
  3. Flushes NFTBan nftables
  4. Re-enables specified firewall
  5. Starts specified firewall

To return to NFTBan after rollback:
  systemctl disable --now <firewall>
  nftban enable all

EOF
}

show_validate_help() {
    cat <<'EOF'
Usage: nftban firewall validate [OPTIONS]

Validate nftables structure against NFTBan specification.

Standard Checks:
  - Required tables exist (ip nftban, ip6 nftban)
  - Forbidden tables don't exist (inet filter - bypasses NFTBan!)
  - Required sets exist (whitelist_ipv4, blacklist_ipv4, tcp_ports_in, etc.)
  - Chain policies are correct (input=drop, output=accept)
  - Priority order is correct (-10, -5, 0)

Strict Mode (--strict): Single Firewall Authority
  - policykit-1 MANDATORY on Debian/Ubuntu
  - No competing firewalls (fail2ban, ufw, firewalld, csf, iptables)
  - No non-NFTBan active input hooks in nftables

Options:
  --strict, -s  Enforce Single Firewall Authority (recommended)
  --json        Output results as JSON
  -h, --help    Show this help message

Exit codes:
  0   All validation checks passed (OK)
  1   Structure validation errors
  10  policykit-1 missing (Debian/Ubuntu only)
  20  Firewall authority conflict (fail2ban/ufw/firewalld/csf active)
  30  NFTables hook collision (non-NFTBan active input hooks)
  40  Environment error (missing commands/libraries)

Examples:
  # Standard validation
  nftban firewall validate

  # Strict mode - enforce single firewall authority
  nftban firewall validate --strict

  # JSON output for automation
  nftban firewall validate --strict --json

  # Use in scripts
  if nftban firewall validate --strict; then
    nftban enable all
  else
    echo "Fix issues before enabling NFTBan"
    exit $?
  fi

See also:
  nftban health conflicts    - Detect and fix conflicting firewalls
  nftban firewall rebuild    - Rebuild schema (preserves IPs)
  nftban firewall reset      - Complete reset (flush all data)

EOF
}

show_check_help() {
    cat <<'EOF'
Usage: nftban firewall check <IP|PORT> [OPTIONS]

Check if IP address or port is blocked or allowed in nftables.

The command:
  1. Detects if value is an IP (contains . or :) or port (numeric)
  2. Checks nftables processing path (priority -10 → -5 → 0)
  3. Shows which rule matched (table, chain, set, verdict)
  4. Displays available actions (block, unblock, whitelist, etc.)

Arguments:
  IP|PORT       IP address (1.2.3.4 or 2001:db8::1) or port number (22)

Options:
  --json        Output results as JSON
  -h, --help    Show this help message

Exit codes:
  0   Check completed successfully
  1   Error (invalid input, nftables error)

Examples:
  # Check if IP is blocked
  nftban firewall check 1.2.3.4

  # Check if port is allowed
  nftban firewall check 22

  # JSON output (for GUI)
  nftban firewall check 1.2.3.4 --json

Processing Path:
  Priority: ip/ip6 nftban input_temp_whitelist (temp whitelist)
  Priority: ip/ip6 nftban input_tempban (temp bans)
  Priority: ip/ip6 nftban input (whitelist, blacklist, ports, default deny)

Output includes:
  - Status: allowed / blocked / unknown
  - Matched rule: table, chain, set/rule, verdict
  - Processing path: shows which chains were checked
  - Available actions: block, unblock, whitelist, etc.

EOF
}

show_stats_help() {
    cat <<'EOF'
Usage: nftban firewall stats [OPTIONS]

Display firewall statistics (tables, chains, sets, rules, IP counts).

Statistics include:
  - Summary: total tables, chains, sets, rules
  - Per-set counts: number of IPs in whitelist, blacklist, temp bans, etc.
  - Per-table breakdown: main table vs runtime table

Options:
  --json        Output results as JSON
  -h, --help    Show this help message

Exit codes:
  0   Statistics retrieved successfully
  1   Error (nftables error, permission denied)

Examples:
  # Display statistics
  nftban firewall stats

  # JSON output (for GUI)
  nftban firewall stats --json

Output includes:
  - Total counts (tables, chains, sets, rules)
  - ip/ip6 nftban: whitelist, blacklist, tcp_ports_in/out, udp_ports_in/out
  - ip/ip6 nftban: temp_whitelist, temp_ban (with auto-expire)

EOF
}

show_rebuild_help() {
    cat <<'EOF'
Usage: nftban firewall rebuild [OPTIONS]

Rebuild nftables schema from scratch while preserving IP data.

Use this when:
  - Schema is corrupted (validation errors)
  - Rogue tables detected (ip raw, ip6 raw, etc.)
  - After manual nft commands broke the structure
  - After RPM upgrade when .rpmnew config exists

What it does:
  1. Backs up current IPs from all sets
  2. Detects .rpmnew config files (RPM upgrades)
  3. Substitutes __SSH_PORT__ placeholder with detected port
  4. Validates new schema (dry-run) BEFORE flushing
  5. Removes rogue tables (non-NFTBan tables)
  6. Flushes and loads validated schema
  7. Re-syncs system whitelist + restores blacklist

Safety: Schema is validated with 'nft -c -f' before any changes.
If validation fails, existing firewall is preserved (no lockout).

Options:
  --force, -f   Skip confirmation prompts
  --quiet, -q   Suppress progress output
  --use-new     Prefer .rpmnew config over existing (after RPM upgrade)
  -h, --help    Show this help message

Examples:
  nftban firewall rebuild
  nftban firewall rebuild --force
  nftban firewall rebuild --use-new   # Use RPM-provided new config

Note: For complete reset (lose all data), use:
  nftban firewall reset --force

EOF
}

show_reset_help() {
    cat <<'EOF'
Usage: nftban firewall reset [OPTIONS]

Complete firewall reset - flush everything and rebuild clean.

WARNING: This DELETES all:
  - Banned IPs
  - Whitelisted IPs (auto-resynced after)
  - GeoBan entries
  - Threat feed entries

Use this when:
  - Schema is completely broken
  - Need to start fresh
  - firewall rebuild fails

What it does:
  1. Stops NFTBan services
  2. Backs up current ruleset
  3. Flushes ALL nftables rules
  4. Loads clean NFTBan schema
  5. Re-syncs system whitelist (lockout protection)
  6. Restarts NFTBan services

Options:
  --force, -f   Required to confirm the reset
  --quiet, -q   Suppress progress output
  -h, --help    Show this help message

Examples:
  nftban firewall reset --force

After reset, restore data with:
  nftban geoban sync
  nftban feeds sync

EOF
}

show_record_help() {
    cat <<'EOF'
Usage: nftban firewall record [OPTIONS]

Snapshot the current live nft schema to a JSON file for audit/comparison.
Creates a "known good" baseline that can later be diffed against.

Options:
  --output, -o <path>   Where to save (default: /var/lib/nftban/schema/schema_record.json)
  --json                Output to stdout instead of file (for piping)
  --diff, -d <path>     Compare current schema against a previously recorded file
  -h, --help            Show this help message

What it records:
  - Tables present (ip nftban, ip6 nftban)
  - All sets with types, flags, and element counts
  - All chains with types, hooks, priorities, and policies
  - Rule order validation (whitelist -> blacklist -> established)
  - Overall validation result (PASS/FAIL)

Examples:
  # Record current schema to default location
  nftban firewall record

  # Record to custom path
  nftban firewall record --output /tmp/schema_before_upgrade.json

  # Output JSON to stdout (for piping)
  nftban firewall record --json | jq .schema.validation

  # Compare current schema against a baseline
  nftban firewall record --diff /var/lib/nftban/schema/schema_record.json

Workflow:
  # Before upgrade: record baseline
  nftban firewall record --output /var/lib/nftban/schema/pre_upgrade.json

  # After upgrade: compare
  nftban firewall record --diff /var/lib/nftban/schema/pre_upgrade.json

Output location: /var/lib/nftban/schema/

EOF
}

# Export functions
export -f nftban_cmd_firewall
