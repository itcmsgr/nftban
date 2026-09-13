#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="nftban_config_split_authority"
# meta:type="lib"
# meta:version="1.230.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="v1.230.0 PR-5c-B3. Fail-closed preflight for configuration subjects whose feature name is served by MORE THAN ONE runtime plane (shell vs Go) with contradictory config chains. It REFUSES the mutation BEFORE any state change, leaves every file byte-identical, names the conflicting authorities, and returns non-zero. SCOPE: refusal only. It does NOT choose a plane, synchronise owners, redirect writes, or resolve the architecture — that stays with CONFIG-WATCHDOG-DUAL-RUNTIME-AUTHORITY-SPLIT (BLOCKED_BY = OWNER_DECISION)."
# meta:inventory.files=""
# meta:inventory.binaries="grep"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR"
# meta:inventory.config_files="/etc/nftban/conf.d/watchdog.conf,/etc/nftban/conf.d/login/main.conf,/etc/nftban/nftban.conf.local"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"

[[ -n "${_NFTBAN_CONFIG_SPLIT_AUTHORITY_LOADED:-}" ]] && return 0
_NFTBAN_CONFIG_SPLIT_AUTHORITY_LOADED=1

# =============================================================================
# THE PREDICATE THIS FILE IMPLEMENTS
# =============================================================================
# A mutation is permitted only when EVERY runtime owner of the subject would
# observe the requested value. Formally:
#
#     observed_by(request)  ==  owners(subject)      -> proceed
#     observed_by(request)  !=  owners(subject)      -> REFUSE, change nothing
#
# "Owner" means an execution plane that consumes the subject at runtime, proven
# from current source — not a filename mention, not a declared variable.
#
# ⛔ A refusal must leave the target BYTE-IDENTICAL. Nothing in this file writes,
#    creates, truncates or renames anything; the only filesystem access is a
#    read-only grep of the central override.
#
# =============================================================================
# REGISTERED SUBJECT 1 — watchdog     handle CONFIG-WATCHDOG-DUAL-RUNTIME-AUTHORITY-SPLIT
# =============================================================================
# subject : ${NFTBAN_CONFIG_DIR}/conf.d/watchdog.conf   key NFTBAN_WATCHDOG_ENABLED
# mutator : cli/lib/nftban/cli/cmd_watchdog.sh:591 (enable) and :635 (disable)
#
# owner A — SHELL, scheduled by install/systemd/nftban-watchdog.service
#           (ExecStart=/usr/sbin/nftban watchdog run)
#             consumes  NFTBAN_WATCHDOG_ENABLED   core/nftban_watchdog.sh:81, :590
#             loads     conf.d/watchdog/main.conf and .local ONLY
#                                                  core/nftban_watchdog.sh:71-77
#           -> the subject file is NOT on this owner's load path, so the write is
#              NOT OBSERVED. (No shell site sources conf.d/watchdog.conf: the only
#              other references are the meta/comment lines at
#              core/nftban_watchdog.sh:24,54 and cmd_watchdog.sh:157.)
#
# owner B — GO, inside nftband
#             reads     conf.d/watchdog.conf, .local, nftban.conf.local
#                                                  internal/watchdog/config_loader.go:36-62
#             consumes  NFTBAN_DYNAMIC_WATCHDOG_ENABLED
#                                                  internal/watchdog/config_loader.go:106
#           -> reads the subject but never the requested key, so the write is
#              NOT OBSERVED.
#
# observed_by = {}   owners = {shell, go}   -> STRUCTURAL SPLIT, always refuse.
#
# =============================================================================
# REGISTERED SUBJECT 2 — login
# =============================================================================
# subject : ${NFTBAN_CONFIG_DIR}/conf.d/login/main.conf.local   key LOGIN_ENABLED
# mutator : cli/lib/nftban/cli/cmd_login.sh:392, :409 (enable) and :484, :496 (disable),
#           through _nftban_login_set_config (cmd_login.sh:513-531)
#
# owner A — SHELL loginmon
#             loads     conf.d/login/main.conf then main.conf.local
#                                                  core/nftban_login.sh:113-121
#             consumes  LOGIN_ENABLED              core/nftban_login.sh:123, :433, :504
#             central   nftban.conf.local is sourced BEFORE the module base
#                       (env.sh:106-114 at startup, core/nftban_login.sh:68) and is
#                       never re-applied — core/nftban_login.sh calls no
#                       nftban_config_apply_final_operator_overlay — so the plain
#                       assignment at etc/nftban/conf.d/login/main.conf:26 overwrites it.
#             -> effective LOGIN_ENABLED = module-local, CENTRAL LOSES.
#
# owner B — GO loginmon, inside nftband
#             loads     conf.d/login/main.conf, main.conf.local, scorer.conf.local
#                                                  internal/loginmon/module.go:699-720
#             then      nftban.conf.local LAST     internal/loginmon/module.go:722-727
#             consumes  LOGIN_ENABLED              internal/loginmon/module.go:754
#             -> effective LOGIN_ENABLED = central, CENTRAL WINS.
#
# The two owners read the SAME key from the SAME files and resolve it in OPPOSITE
# order. So:
#   central override does NOT declare LOGIN_ENABLED -> both owners resolve to the
#       module-local file the mutator writes: observed_by == owners -> proceed.
#   central override DOES declare LOGIN_ENABLED     -> the shell owner takes the
#       requested value and the Go owner takes the central one: observed_by != owners
#       -> REFUSE. The command cannot prove REQUESTED == EFFECTIVE for every owner.
#
# This is a state-dependent split, not a structural one, and the guard says so.
# =============================================================================

# Result vocabulary — a caller must be able to tell WHY it may not proceed.
: "${NFTBAN_SPLIT_OK:=0}"
: "${NFTBAN_SPLIT_REFUSED:=9}"
: "${NFTBAN_SPLIT_UNKNOWN_SUBJECT:=8}"

# nftban_config_split_guard <subject>
#
#   rc 0                            -> no split proven for the CURRENT state; caller may proceed
#   rc $NFTBAN_SPLIT_REFUSED        -> SPLIT; caller MUST abort WITHOUT changing any state
#   rc $NFTBAN_SPLIT_UNKNOWN_SUBJECT-> the subject is not registered; caller MUST abort too
#                                      (an unregistered subject is UNKNOWN, and UNKNOWN
#                                       fails closed — it is never silently permitted)
nftban_config_split_guard() {
    local subject="${1:-}"
    local cfgdir="${NFTBAN_CONFIG_DIR:-/etc/nftban}"

    case "$subject" in
        watchdog) _nftban_config_split_watchdog "$cfgdir" ;;
        login)    _nftban_config_split_login    "$cfgdir" ;;
        *)
            printf 'nftban: split-authority: UNKNOWN subject %q — refusing to classify a subject that has not been proven\n' \
                "$subject" >&2
            return "$NFTBAN_SPLIT_UNKNOWN_SUBJECT"
            ;;
    esac
}

_nftban_config_split_watchdog() {
    local cfgdir="$1"
    cat >&2 <<EOF
nftban: REFUSING the watchdog configuration mutation — SPLIT RUNTIME AUTHORITY.
  subject      ${cfgdir}/conf.d/watchdog.conf   key NFTBAN_WATCHDOG_ENABLED
  authority 1  SHELL  (nftban-watchdog.service -> nftban watchdog run)
               consumes NFTBAN_WATCHDOG_ENABLED  core/nftban_watchdog.sh:81,:590
               but loads only conf.d/watchdog/main.conf[.local]
                                                 core/nftban_watchdog.sh:71-77
               => it never reads the subject; the write would NOT be observed.
  authority 2  GO     (watchdog inside nftband)
               reads the subject                 internal/watchdog/config_loader.go:36-62
               but consumes NFTBAN_DYNAMIC_WATCHDOG_ENABLED
                                                 internal/watchdog/config_loader.go:106
               => it never reads the key; the write would NOT be observed.
  verdict      0 of 2 runtime owners would observe the requested value.
  effect       NOTHING was changed — no file written, no unit enabled or disabled.
  handle       CONFIG-WATCHDOG-DUAL-RUNTIME-AUTHORITY-SPLIT (BLOCKED_BY = OWNER_DECISION).
               Until that authority is chosen, each plane must be controlled explicitly
               and separately by the operator:
                 shell plane  systemctl {enable|disable} --now nftban-watchdog.timer
                 go plane     NFTBAN_DYNAMIC_WATCHDOG_ENABLED in
                              ${cfgdir}/conf.d/watchdog.conf.local
EOF
    return "$NFTBAN_SPLIT_REFUSED"
}

_nftban_config_split_login() {
    local cfgdir="$1"
    local central="${cfgdir}/nftban.conf.local"

    # Read-only probe. No mutation, no file creation.
    [[ -f "$central" && -r "$central" ]] || return "$NFTBAN_SPLIT_OK"
    grep -qE '^[[:space:]]*LOGIN_ENABLED=' "$central" 2>/dev/null \
        || return "$NFTBAN_SPLIT_OK"

    cat >&2 <<EOF
nftban: REFUSING the login configuration mutation — SPLIT RUNTIME AUTHORITY.
  subject      ${cfgdir}/conf.d/login/main.conf.local   key LOGIN_ENABLED
  conflict     ${central} also declares LOGIN_ENABLED, and the two runtime
               owners resolve that declaration in OPPOSITE order.
  authority 1  SHELL loginmon
               loads conf.d/login/main.conf[.local]     core/nftban_login.sh:113-121
               consumes LOGIN_ENABLED                   core/nftban_login.sh:433,:504
               applies nftban.conf.local BEFORE the module base and never re-applies it
                                                        core/nftban_login.sh:68
               => central LOSES; this owner would take the requested value.
  authority 2  GO loginmon (inside nftband)
               loads the same two files                 internal/loginmon/module.go:699-720
               then applies nftban.conf.local LAST      internal/loginmon/module.go:722-727
               consumes LOGIN_ENABLED                   internal/loginmon/module.go:754
               => central WINS; this owner would keep the central value.
  verdict      1 of 2 runtime owners would observe the requested value; the command
               cannot prove REQUESTED == EFFECTIVE for every owner.
  effect       NOTHING was changed — no file written or created.
  handle       CONFIG-WATCHDOG-DUAL-RUNTIME-AUTHORITY-SPLIT (BLOCKED_BY = OWNER_DECISION).
               Resolve by hand: remove LOGIN_ENABLED from ${central} and set it in
               ${cfgdir}/conf.d/login/main.conf.local, or the reverse — but the two
               planes must not both be told, because they disagree about which wins.
EOF
    return "$NFTBAN_SPLIT_REFUSED"
}
