#!/usr/bin/env bash
# =============================================================================
# NFTBan - Suricata CLI Command (DORMANT SURFACE)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Report that Suricata integration is dormant. Nothing else.
#
# meta:name="cmd_suricata"
# meta:type="cli"
# meta:header="Suricata Integration (dormant)"
# meta:version="1.228.2"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Read-only dormant-state reporter for the retired Suricata surface; help + status only, never mutates the host"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# meta:created_date="2025-12-28"
# meta:updated_date="2026-07-28"
#
# =============================================================================
# v1.228.2 — SURICATA RETIRED FROM THE ACTIVE PRODUCT SURFACE (owner ruling D1-D4)
# -----------------------------------------------------------------------------
# Suricata is a DORMANT PLACEHOLDER for a much later release. It is NOT an
# active protection module and NFTBan does not manage it.
#
# What this file used to be, and why it is gone:
#
#   * The module loader sourced five submodules — cmd_suricata_setup.sh,
#     cmd_suricata_rules.sh, cmd_suricata_advanced.sh, cmd_suricata_tools.sh
#     and cmd_suricata_iface.sh. FOUR of the five were deleted by ff1865b4.
#     The loader `return 1`d on the first missing one, so the entire command
#     was unreachable — and the router discarded that failure.
#   * The router carried 19 dispatch arms and the file `export -f`d 20
#     subcommand functions. Only four of those functions were defined anywhere
#     in the tree (install/enable/disable/status, all in cmd_suricata_setup.sh).
#     The remaining 15 exports named functions that do not exist.
#   * install/enable/disable MUTATED THE HOST: they installed the external
#     suricata package, rewrote /etc/suricata/suricata.yaml, added the suricata
#     user to the nftban group, wrote /etc/logrotate.d/nftban-suricata, edited
#     nftban.conf.local, and enabled systemd units. A dormant placeholder must
#     do none of that.
#
# Per D3 the public surface is now `help` and `status`, and nothing else.
# Rule verification is NOT reimplemented, and `status` is NOT substituted for
# `rules verify` — the two are not equivalent and never were.
#
# NOT TOUCHED BY THIS FILE (deliberately — different owners):
#   * the Go detection/scoring code under internal/suricata/**
#   * nftban-suricata-stats.service
#   * the loginmon / portscan / ddos Suricata-fed engine paths
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${NFTBAN_CMD_SURICATA_LOADED:-}" ]] && return 0
NFTBAN_CMD_SURICATA_LOADED="true"

# =============================================================================
# DORMANT-STATE CONTRACT
# =============================================================================
# Stable machine-readable token. Monitoring must be able to distinguish
# "deferred by design" from "you typed it wrong" and from "it broke", so the
# token is emitted on the human path as well as under --json.
NFTBAN_SURICATA_STATE_TOKEN="NFTBAN_SURICATA_STATE=DORMANT"
readonly NFTBAN_SURICATA_STATE_TOKEN

# EXIT CODE = 2. Justification, against contracts that are already shipped:
#
#   nftban-installer --verify-install-state (live on 9 hosts, consumed by BOTH
#   package scriptlets) defines exactly this taxonomy in verify_mode.go:
#       0  verified current COMMITTED
#       2  any determinate non-verified verdict
#       4  invalid invocation
#
#   Dormant is a DETERMINATE NON-VERIFIED state: it is certain that Suricata
#   protection is not active, and that certainty is neither a failure nor a
#   usage error. That is verdict 2 — reused, not a new taxonomy.
#
#   It must NOT be 1: D6 keeps CLI_USAGE_ERROR = 1, so 1 here would make
#   "deferred by design" indistinguishable from "unknown subcommand" — the
#   exact conflation this train exists to remove.
#   It must NOT be 0: exit 0 from `status` is the false-success signal being
#   retired; a monitor treating 0 as healthy would read a dormant placeholder
#   as working protection.
#   It must NOT be 4: in the installer space 4 means invalid invocation, and
#   `nftban suricata status` is a perfectly valid invocation.
#
#   The Nagios/Icinga 0/1/2/3 space (cmd_health_core.sh:525-534) is NOT
#   touched: this command is not a check plugin and no check plugin calls it.
#   Its only in-tree caller is cmd_support.sh:1761, which absorbs any exit
#   status with `||`.
NFTBAN_SURICATA_DORMANT_EXIT=2
readonly NFTBAN_SURICATA_DORMANT_EXIT

# =============================================================================
# COMMAND: status  (READ-ONLY — no systemctl, no writes, no host probing)
# =============================================================================
# Deliberately declarative. It makes no systemctl call and inspects no host
# state: there is no NFTBan-owned Suricata state left to inspect, and probing
# for an external suricata would imply NFTBan has an opinion about it. Same
# answer on every host, with no side effects, so it is also hermetic to test.
cmd_suricata_status() {
    local json_mode="false"
    local arg
    for arg in "$@"; do
        [[ "$arg" == "--json" ]] && json_mode="true"
    done

    if [[ "$json_mode" == "true" ]]; then
        cat <<'EOF'
{"state":"DORMANT","implemented":false,"protection_active":false,"managed_by_nftban":false,"reason":"Suricata integration is reserved for a future NFTBan release and is not currently an active protection module."}
EOF
        return "$NFTBAN_SURICATA_DORMANT_EXIT"
    fi

    cat <<EOF

Suricata integration

  State:              DORMANT / NOT IMPLEMENTED
  Protection active:  NO
  Managed by NFTBan:  NO

Suricata integration is reserved for a future NFTBan release and is not
currently an active protection module. NFTBan ships no Suricata service, no
rule management and no update timer, and it does not install, configure,
enable or monitor any external Suricata instance.

If an external Suricata is running on this host it is entirely independent of
NFTBan. Manage it with its own tooling.

  ${NFTBAN_SURICATA_STATE_TOKEN}

EOF

    return "$NFTBAN_SURICATA_DORMANT_EXIT"
}

# =============================================================================
# HELP
# =============================================================================

cmd_suricata_help() {
    cat <<'EOF'

NFTBan Suricata integration — DORMANT

USAGE:
    nftban suricata <command>

COMMANDS:
    status      Report the dormant state (read-only; exits 2)
    help        Show this help message

STATE:
    Suricata integration is reserved for a future NFTBan release and is not
    currently an active protection module.

    NFTBan does NOT ship a Suricata service, a rule-update timer, rule
    management, profile management, or an install/enable/disable command, and
    it does not install, configure or manage an external Suricata installation.

EXIT CODES:
    2   dormant — determinate, not implemented, protection NOT active.
        `status` always exits 2. Token: NFTBAN_SURICATA_STATE=DORMANT
    1   usage error (unknown subcommand)

EOF
}

# =============================================================================
# COMMAND ROUTER
# =============================================================================

nftban_cmd_suricata() {
    local action="${1:-help}"
    shift || true

    case "$action" in
        status)
            cmd_suricata_status "$@"
            ;;
        help|--help|-h)
            cmd_suricata_help
            ;;
        *)
            # Usage error is 1 (D6), deliberately NOT the dormant code — a
            # monitor must never read a typo as a design decision.
            echo "ERROR: Unknown command: $action" >&2
            echo "Suricata integration is dormant; only 'status' and 'help' exist." >&2
            echo "Run 'nftban suricata help' for usage" >&2
            return 1
            ;;
    esac
}

# =============================================================================
# EXPORTS
# =============================================================================
# Three functions, all of which are defined in this file. The pre-v1.228.2
# export block named 20 subcommand functions, 15 of which did not exist.

export -f nftban_cmd_suricata
export -f cmd_suricata_status
export -f cmd_suricata_help

# Execute if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_suricata "$@"
fi
