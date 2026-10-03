#!/usr/bin/env bash
# =============================================================================

# Load JSON helper for --json support
[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"

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
JSON_HELPER="${NFTBAN_LIB_DIR}/helpers/json_output.sh"
if [[ -f "$JSON_HELPER" ]]; then
    # shellcheck source=/dev/null
    source "$JSON_HELPER" || return 1
fi

# Load IPC library for single-writer architecture
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/nft_ipc.sh" 2>/dev/null || true

# NFTBan - NFTables Service Management CLI Handler
# =============================================================================

# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# Purpose: Command-line interface for nftables service management
#
# meta:name="cmd_nftables"
# meta:type="cli"
# meta:header="NFTables Service CLI"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="CLI handler for nftables service management"
# meta:inventory.files=""
# meta:inventory.binaries="systemctl,nft"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units="nftables.service"
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2025-11-05"
# meta:updated_date="2025-11-24"
# =============================================================================



# =============================================================================

# CONFIGURATION
# =============================================================================

readonly NFTABLES_SERVICE="nftables.service"

# =============================================================================

# HELP TEXT
# =============================================================================


_nftban_nftables_help() {
    # Load output module for standard banner
    source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1

    # Show standard banner
    nftban_banner

    cat <<'HELP'

USAGE:
    nftban nftables <command>

COMMANDS:
    start               Start nftables service, then converge NFTBan state
    stop                Stop nftables service
    restart             Rebuild the NFTBan ruleset atomically (state preserved)
    reload              Same as restart

    enable              Enable nftables service at boot
    disable             Disable nftables service at boot

    status              Show nftables service status
    check               Check nftables configuration
    list                List current nftables ruleset

    help                Show this help message

DESCRIPTION:
    Manage the nftables firewall service. NFTBan uses nftables as its
    underlying firewall system. These commands allow you to control the
    nftables systemd service and view the current ruleset.

    restart and reload do NOT restart nftables.service while it is running.
    A service restart re-loads the boot projection and drops the live NFTBan
    state (timed bans, reconciled sets). Both verbs run the atomic
    `nftban firewall rebuild` instead: it takes the NFTBan operations lock,
    snapshots the live sets first, loads the complete ruleset in one
    transaction, restores bans and whitelist, re-applies modules and refreshes
    the boot projection. Success is printed only after the rebuild succeeded
    and the effective service ports were verified live.

EXAMPLES:
    # Check nftables status
    nftban nftables status

    # Rebuild the NFTBan ruleset without losing bans, whitelist or ports
    nftban nftables restart

    # Enable nftables at boot
    nftban nftables enable

    # View current ruleset
    nftban nftables list

    # Check configuration
    nftban nftables check

NOTES:
    - Most commands require elevated privileges (members of the nftban group are authorized via PolicyKit/polkit rules)
    - NFTBan manages nftables rules automatically
    - Manual changes to nftables rules may be overwritten by NFTBan

SERVICE INFORMATION:
    Service:  nftables.service
    Binary:   /usr/sbin/nft
    Boot:     /etc/nftban/generated/nftban-boot.nft (generated; refreshed by rebuild)

HELP
}

# =============================================================================

# COMMAND FUNCTIONS
# =============================================================================


# -----------------------------------------------------------------------------
# v1.234 R-11 (BUG-NFTABLES-RESTART-RELOADS-BOOT-FILE-DROPS-PORTS-BANS-WHITELIST)
#
# `nftban nftables restart|reload` used to be `systemctl restart|reload nftables`.
# That re-loads the kernel from the boot projection WITHOUT any reconciliation:
# measured on lab4/lab2, open service ports 16 -> 3, persisted bans 7/68 -> 0,
# a whitelist entry lost — and the verb still printed "restarted successfully".
# Nothing re-applied the state until an explicit `nftban sync`.
#
# The verbs now converge through the EXISTING atomic rebuild, which already owns
# every property the restart lacked:
#   - serialization on the canonical /run/nftban/nft_operations.lock (it refuses,
#     never queues silently, when another convergence holds it);
#   - a snapshot of the LIVE kernel before anything changes, so detector TTL bans
#     are restored with their remaining timeout (a service restart destroys them
#     before any later sync or rebuild could snapshot them);
#   - one atomic `nft -f` with the complete effective service ports;
#   - durable whitelist.d/blacklist.d reconcile + member-level verification;
#   - module re-apply and post-validation with rollback;
#   - republication of the boot projection.
# Success is reported only when the rebuild exits 0 AND the independent
# effective-state check below passes.
#
# ⛔ NO RECURSION: this file must never call `systemctl restart|reload nftables`
#    for these verbs, and the rebuild never calls back into `nftban nftables`.
# ⛔ DO NOT add `ExecStartPost=nftban sync` to nftables.service instead: at boot
#    nftband is ordered After=nftables.service, so the IPC would wait on a daemon
#    that cannot start until nftables finishes (ordering deadlock).
# -----------------------------------------------------------------------------

# _nftban_nftables_verify_effective
# Independent post-convergence check through the EXISTING transition-health
# probe (the same one the rebuild records): every effective service port must be
# live in both families, the management floor must be present, and both nftban
# tables must exist. An observation that cannot be made is UNMEASURED, and
# UNMEASURED is never reported as success.
_nftban_nftables_verify_effective() {
    local helper="${NFTBAN_LIB_DIR}/core/nftban_firewall_transition_health.sh"
    if [[ ! -r "$helper" ]]; then
        echo "ERROR: effective state UNMEASURED — verifier not found: $helper" >&2
        return 1
    fi
    # shellcheck source=/dev/null
    if ! source "$helper"; then
        echo "ERROR: effective state UNMEASURED — verifier could not be loaded" >&2
        return 1
    fi
    if ! declare -F _fth_gather >/dev/null 2>&1 || ! declare -F _fth_compute_breaches >/dev/null 2>&1; then
        echo "ERROR: effective state UNMEASURED — verifier interface missing" >&2
        return 1
    fi
    if ! _fth_gather; then
        echo "ERROR: effective state UNMEASURED — the live ruleset could not be observed" >&2
        return 1
    fi
    # tcp_ports_in always carries at least the SSH safeguard. Empty means the
    # effective-port authority produced nothing, which would make every port
    # comparison below vacuously "complete".
    if [[ -z "${FTH_EFF_TCPIN:-}" ]]; then
        echo "ERROR: effective state UNMEASURED — the effective service-port authority returned nothing" >&2
        return 1
    fi
    if [[ "${FTH_TABLE_PRESENT:-N}" != "Y" ]]; then
        echo "ERROR: the nftban tables are NOT present after the rebuild" >&2
        return 1
    fi
    _fth_compute_breaches
    if (( ${FTH_B_SVC:-1} + ${FTH_B_FLOOR:-1} + ${FTH_B_TABLE:-1} > 0 )); then
        echo "ERROR: effective state NOT converged: ${FTH_REASON:-unspecified breach}" >&2
        return 1
    fi
    echo "  Verified: effective service ports live (tcp_in: ${FTH_EFF_TCPIN}); management floor present (ip, ip6)"
    return 0
}

# -----------------------------------------------------------------------------
# v1.234 §6g.4 — bans and module enforcement survive the convergence.
# The port/floor/table check above cannot see a rebuild that returned 0 but left
# the ban sets empty or a protection module's chain missing. Before the rebuild
# the current enforcement is snapshotted; after it, every ban set that held
# UNEXPIRED bans must still hold bans, and every module chain that was present
# for an effectively-enabled module must still be present. (The whitelist is
# verified inside the rebuild itself.) Counting is `nft -j` + jq only, never text
# parsing. A source that cannot be read is UNMEASURED, never zero, and fails.
# -----------------------------------------------------------------------------
# Ban sets (family set). Feed/geoban interval sets and manual/auto hash sets.
_NFTBAN_NFTABLES_BAN_SETS=("ip blacklist_ipv4" "ip blacklist_manual_ipv4" "ip6 blacklist_ipv6" "ip6 blacklist_manual_ipv6")
# A ban that expires within this many seconds may legitimately lapse during the
# rebuild; only bans with more remaining time are expected to survive.
_NFTBAN_NFTABLES_BAN_MARGIN_SEC=600

# _nftban_nftables_json <nft list args...> — the nft JSON document, or rc 1.
_nftban_nftables_json() {
    local out
    command -v jq >/dev/null 2>&1 || return 1
    out=$(nft -j "$@" 2>/dev/null) || return 1
    [[ -n "${out//[[:space:]]/}" ]] || return 1
    jq -e 'type == "object" and has("nftables")' >/dev/null 2>&1 <<<"$out" || return 1
    printf '%s' "$out"
}

# _nftban_nftables_ban_count <family> <set> <min_remaining_sec>
# Elements with no timeout, or with at least <min_remaining_sec> left. Prints an
# integer, ABSENT (the nftban table of that family does not exist), or UNKNOWN.
_nftban_nftables_ban_count() {
    local fam="$1" set="$2" min="$3" tables json n
    tables=$(_nftban_nftables_json list tables) || { echo UNKNOWN; return 0; }
    if ! jq -e --arg f "$fam" 'any(.nftables[]?; .table? and .table.family == $f and .table.name == "nftban")' \
            >/dev/null 2>&1 <<<"$tables"; then
        echo ABSENT; return 0
    fi
    json=$(_nftban_nftables_json list set "$fam" nftban "$set") || { echo UNKNOWN; return 0; }
    n=$(jq -r --argjson m "$min" '[.nftables[]? | select(.set?) | .set.elem[]?
            | select((type != "object") or (.elem? == null) or ((.elem.expires // $m) >= $m))] | length' \
            2>/dev/null <<<"$json")
    [[ "$n" =~ ^[0-9]+$ ]] && echo "$n" || echo UNKNOWN
}

# _nftban_nftables_chains — "family:name" per nftban chain, or rc 1 (UNMEASURED).
_nftban_nftables_chains() {
    local json
    json=$(_nftban_nftables_json list chains) || return 1
    jq -r '.nftables[]? | select(.chain?) | .chain | select(.table == "nftban") | "\(.family):\(.name)"' \
        2>/dev/null <<<"$json" || return 1
}

# Module -> chain, the same names the rebuild's module verification uses.
_nftban_nftables_module_chains() {
    echo "ddos ${DDOS_NFT_CHAIN:-ddos_protection}"
    echo "portscan ${PORTSCAN_NFT_CHAIN:-portscan_detection}"
    echo "botguard ${BOTGUARD_NFT_CHAIN:-http_bot_guard}"
}

# _nftban_nftables_enforcement_snapshot — prints the pre-convergence snapshot:
#   ban <family> <set> <count|ABSENT|UNKNOWN>
#   chains UNKNOWN            (when the chain list could not be read)
#   chain <family:name>       (one per nftban chain)
_nftban_nftables_enforcement_snapshot() {
    # The dispatcher runs with IFS=$'\n\t' (several cmd_*.sh set it when sourced):
    # never rely on word splitting here.
    local IFS=$' \t\n'
    local s c fam set
    for s in "${_NFTBAN_NFTABLES_BAN_SETS[@]}"; do
        IFS=' ' read -r fam set <<<"$s"
        echo "ban $fam $set $(_nftban_nftables_ban_count "$fam" "$set" "$_NFTBAN_NFTABLES_BAN_MARGIN_SEC")"
    done
    if c=$(_nftban_nftables_chains); then
        while IFS= read -r s; do
            if [[ -n "$s" ]]; then echo "chain $s"; fi
        done <<<"$c"
    else
        echo "chains UNKNOWN"
    fi
    return 0
}

# _nftban_nftables_verify_enforcement <pre-snapshot>
_nftban_nftables_verify_enforcement() {
    local IFS=$' \t\n'
    local pre="$1" line kind fam set cnt now post_chains mod ch f
    local -a missing=() unmeasured=() kept=() mods=()
    while IFS=' ' read -r kind fam set cnt; do
        [[ "$kind" == "ban" ]] || continue
        case "$cnt" in
            UNKNOWN) unmeasured+=("ban set $fam $set before convergence") ;;
            ABSENT|0) ;;
            # An empty or non-numeric count was never measured: it is not "held bans".
            ''|*[!0-9]*) unmeasured+=("ban set $fam $set before convergence (${cnt:-empty})") ;;
            *)  now=$(_nftban_nftables_ban_count "$fam" "$set" 0)
                case "$now" in
                    UNKNOWN|ABSENT|''|*[!0-9]*) unmeasured+=("ban set $fam $set after convergence (${now:-empty})") ;;
                    0) missing+=("ban set $fam $set is EMPTY (held $cnt unexpired ban(s) before)") ;;
                    *) kept+=("$fam $set") ;;
                esac ;;
        esac
    done <<<"$pre"

    if grep -qx 'chains UNKNOWN' <<<"$pre"; then
        unmeasured+=("module chains before convergence")
    else
        if ! declare -F nftban_module_effective_enabled >/dev/null 2>&1; then
            # shellcheck source=/dev/null
            source "${NFTBAN_LIB_DIR}/lib/module_authority.sh" 2>/dev/null || true
        fi
        if ! declare -F nftban_module_effective_enabled >/dev/null 2>&1; then
            unmeasured+=("module enablement (lib/module_authority.sh not loadable)")
        elif ! post_chains=$(_nftban_nftables_chains); then
            unmeasured+=("module chains after convergence")
        else
            while IFS=' ' read -r mod ch; do
                nftban_module_effective_enabled "$mod" || continue
                for f in ip ip6; do
                    grep -qx "chain $f:$ch" <<<"$pre" || continue
                    if grep -qx "$f:$ch" <<<"$post_chains"; then
                        mods+=("$mod($f)")
                    else
                        missing+=("module chain $f nftban $ch ($mod) is MISSING (present before)")
                    fi
                done
            done < <(_nftban_nftables_module_chains)
        fi
    fi

    if (( ${#unmeasured[@]} > 0 )); then
        for line in "${unmeasured[@]}"; do echo "ERROR: enforcement UNMEASURED — $line" >&2; done
    fi
    if (( ${#missing[@]} > 0 )); then
        for line in "${missing[@]}"; do echo "ERROR: enforcement NOT preserved — $line" >&2; done
    fi
    (( ${#unmeasured[@]} + ${#missing[@]} == 0 )) || return 1
    echo "  Verified: unexpired bans present (${kept[*]:-no set held unexpired bans}); module chains present (${mods[*]:-none expected})"
    return 0
}

# _nftban_nftables_converge <verb>
_nftban_nftables_converge() {
    local verb="$1" rc=0
    local cli="${NFTBAN_BIN:-/usr/sbin/nftban}"
    if ! command -v "$cli" >/dev/null 2>&1; then
        echo "ERROR: nftban CLI not found ($cli) — cannot run the atomic rebuild; nothing was changed" >&2
        return 1
    fi
    # §6g.4: what is enforced now (bans, module chains) must still be enforced after.
    local _enf_pre
    _enf_pre=$(_nftban_nftables_enforcement_snapshot)
    echo "  Converging through the atomic rebuild (locked, snapshot-first)..."
    "$cli" firewall rebuild --quiet || rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "ERROR: nftables $verb FAILED — firewall rebuild exited $rc" >&2
        echo "  The rebuild output above states what was changed and whether it rolled back." >&2
        echo "  Nothing was reported as restarted." >&2
        return "$rc"
    fi
    _nftban_nftables_verify_effective || return $?
    _nftban_nftables_verify_enforcement "$_enf_pre" || return $?
    return 0
}

_nftban_nftables_cmd_start() {
    echo "Starting nftables service..."
    local result=0
    systemctl start "${NFTABLES_SERVICE}" || result=$?
    if [[ $result -ne 0 ]]; then
        echo "ERROR: Failed to start nftables service" >&2
        return $result
    fi
    # The unit loaded the boot projection; converge to the current effective
    # configuration (persisted bans, whitelist, modules) before claiming success.
    _nftban_nftables_converge start || return $?
    echo "✓ nftables service started and NFTBan state converged"
}

_nftban_nftables_cmd_stop() {
    echo "Stopping nftables service..."
    systemctl stop "${NFTABLES_SERVICE}"
    local result=$?

    if [[ $result -eq 0 ]]; then
        echo "✓ nftables service stopped successfully"
    else
        echo "ERROR: Failed to stop nftables service" >&2
        return $result
    fi
}

# _nftban_nftables_restart_or_reload <restart|reload>
# Both verbs converge the SAME way. nftables.service is NOT restarted/reloaded
# while it is active: that is precisely the reset R-11 measured. If the unit is
# not active it is started first (there is no unit-loaded state to preserve), and
# the rebuild then converges on top of what it loaded.
_nftban_nftables_restart_or_reload() {
    local verb="$1" result=0
    echo "Converging NFTBan firewall (nftables ${verb})..."
    if ! systemctl is-active --quiet "${NFTABLES_SERVICE}" 2>/dev/null; then
        echo "  ${NFTABLES_SERVICE} is not active — starting it first..."
        systemctl start "${NFTABLES_SERVICE}" || result=$?
        if [[ $result -ne 0 ]]; then
            echo "ERROR: Failed to start ${NFTABLES_SERVICE}" >&2
            return $result
        fi
    fi
    _nftban_nftables_converge "$verb" || return $?
    echo "✓ nftables ${verb} complete — ruleset rebuilt atomically, effective state verified"
}

_nftban_nftables_cmd_restart() {
    _nftban_nftables_restart_or_reload restart
}

_nftban_nftables_cmd_reload() {
    # v1.234 R-11: the former fallback `nft_ipc_apply_ruleset /etc/nftables/nftban.nft`
    # is REMOVED — that file is not the boot authority, and the fallback reported
    # the result of whichever path ran last.
    _nftban_nftables_restart_or_reload reload
}

_nftban_nftables_cmd_enable() {
    echo "Enabling nftables service at boot..."
    systemctl enable "${NFTABLES_SERVICE}"
    local result=$?

    if [[ $result -eq 0 ]]; then
        echo "✓ nftables service enabled at boot"
    else
        echo "ERROR: Failed to enable nftables service" >&2
        return $result
    fi
}

_nftban_nftables_cmd_disable() {
    echo "Disabling nftables service at boot..."
    systemctl disable "${NFTABLES_SERVICE}"
    local result=$?

    if [[ $result -eq 0 ]]; then
        echo "✓ nftables service disabled at boot"
    else
        echo "ERROR: Failed to disable nftables service" >&2
        return $result
    fi
}

_nftban_nftables_cmd_status() {
    # Load output module for standard banner
    source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1

    # Show standard banner
    nftban_banner
    echo ""

    echo "NFTables Service Status:"
    echo "════════════════════════════════════════════════════════════"
    echo ""

    systemctl status "${NFTABLES_SERVICE}" --no-pager

    echo ""
    echo "NFTables Binary:"
    echo "────────────────────────────────────────────────────────────"
    if command -v nft &>/dev/null; then
        echo "  Location: $(command -v nft)"
        echo "  Version:  $(nft --version 2>&1 | head -1)"
    else
        echo "  ERROR: nft binary not found" >&2
    fi

    echo ""
    echo "Boot Status:"
    echo "────────────────────────────────────────────────────────────"
    if systemctl is-enabled "${NFTABLES_SERVICE}" &>/dev/null; then
        echo "  Enabled at boot: ✓ YES"
    else
        echo "  Enabled at boot: ✗ NO"
    fi
}

_nftban_nftables_cmd_check() {
    echo "Checking nftables configuration..."
    echo ""

    # Check if nft binary exists
    if ! command -v nft &>/dev/null; then
        echo "ERROR: nft binary not found" >&2
        echo "Install nftables: sudo dnf install nftables" >&2
        return 1
    fi

    # Check if service is available (loaded or exists)
    if ! systemctl list-units --all --full | grep -q "${NFTABLES_SERVICE}"; then
        if ! systemctl status "${NFTABLES_SERVICE}" &>/dev/null; then
            echo "WARNING: nftables service not found"
            return 1
        fi
    fi

    # Check configuration syntax
    if [[ -f /etc/nftables/nftban.nft ]]; then
        echo "Checking NFTBan configuration..."
        nft -c -f /etc/nftables/nftban.nft
        if [[ $? -eq 0 ]]; then
            echo "✓ Configuration syntax is valid"
        else
            echo "ERROR: Configuration syntax error" >&2
            return 1
        fi
    fi

    # Check if service is active
    if systemctl is-active "${NFTABLES_SERVICE}" &>/dev/null; then
        echo "✓ Service is running"
    else
        echo "WARNING: Service is not running"
    fi

    echo ""
    echo "✓ All checks passed"
}

_nftban_nftables_cmd_list() {
    echo "Current NFTables Ruleset:"
    echo "════════════════════════════════════════════════════════════"
    echo ""

    if ! command -v nft &>/dev/null; then
        echo "ERROR: nft binary not found" >&2
        return 1
    fi

    nft list ruleset
}

# =============================================================================

# MAIN COMMAND HANDLER
# =============================================================================


nftban_cmd_nftables() {
    local action="${1:-help}"
    local json_mode=false

    # Check for --json flag
    for arg in "$@"; do
        [[ "$arg" == "--json" ]] && json_mode=true && break || true
    done

    shift || true

    case "$action" in
        start)
            if [[ $EUID -ne 0 ]]; then
                echo "ERROR: PolicyKit/polkit authorization failed or insufficient privileges" >&2
                return 1
            fi
            _nftban_nftables_cmd_start || return $?
            ;;

        stop)
            if [[ $EUID -ne 0 ]]; then
                echo "ERROR: PolicyKit/polkit authorization failed or insufficient privileges" >&2
                return 1
            fi
            _nftban_nftables_cmd_stop || return $?
            ;;

        restart)
            if [[ $EUID -ne 0 ]]; then
                echo "ERROR: PolicyKit/polkit authorization failed or insufficient privileges" >&2
                return 1
            fi
            _nftban_nftables_cmd_restart || return $?
            ;;

        reload)
            if [[ $EUID -ne 0 ]]; then
                echo "ERROR: PolicyKit/polkit authorization failed or insufficient privileges" >&2
                return 1
            fi
            _nftban_nftables_cmd_reload || return $?
            ;;

        enable)
            if [[ $EUID -ne 0 ]]; then
                echo "ERROR: PolicyKit/polkit authorization failed or insufficient privileges" >&2
                return 1
            fi
            _nftban_nftables_cmd_enable || return $?
            ;;

        disable)
            if [[ $EUID -ne 0 ]]; then
                echo "ERROR: PolicyKit/polkit authorization failed or insufficient privileges" >&2
                return 1
            fi
            _nftban_nftables_cmd_disable || return $?
            ;;

        status)
            if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
                local active="false"
                systemctl is-active --quiet nftables && active="true"
                local data
                data=$(json_build_object "service" "nftables" "active" "$active")
                json_output "true" "$data"
            else
                _nftban_nftables_cmd_status
            fi
            ;;

        check)
            if [[ $EUID -ne 0 ]]; then
                echo "ERROR: PolicyKit/polkit authorization failed or insufficient privileges" >&2
                return 1
            fi
            _nftban_nftables_cmd_check || return $?
            ;;

        list)
            _nftban_nftables_cmd_list
            ;;

        help|--help|-h)
            _nftban_nftables_help
            ;;

        *)
            echo "ERROR: Unknown command: $action" >&2
            echo "" >&2
            echo "Run 'nftban nftables help' for available commands" >&2
            return 1
            ;;
    esac

    return 0
}

# =============================================================================

# EXPORT FOR MAIN CLI
# =============================================================================

export -f nftban_cmd_nftables
