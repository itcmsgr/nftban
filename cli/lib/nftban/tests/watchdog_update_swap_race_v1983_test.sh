#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.198.3 - watchdog/update-swap race: cadence-timer inhibit/restore
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="watchdog_update_swap_race_v1983_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-22"
# meta:description="Hermetic regression for BUG-WATCHDOG-TIMER-UPDATE-SWAP-EXEC203-RACE (v1.198.3 PR-A). systemctl is stubbed: asserts _update_inhibit_cadence_timers stops ONLY the active racing timers, _update_restore_cadence_timers restores EXACTLY those (idempotent; restores on the failure path; never mask; never enable a disabled/inactive timer), _update_verify_watchdog passes on a clean run and fails on a persistently-broken watchdog, and static guards that cmd_update.sh wraps the [2/6] Install phase (inhibit before the case, restore after, scoped INT/TERM trap, NO EXIT trap) and runs the post-update watchdog verification."
# meta:input="None (systemctl + _update_log stubs)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,grep,mktemp"
# meta:inventory.files="cli/lib/nftban/cli/cmd_update_helpers.sh,cli/lib/nftban/cli/cmd_update.sh"
# meta:inventory.binaries="bash"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units="nftban-watchdog.timer,nftban-maintenance.timer,nftban-watchdog.service"
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="watchdog_update_swap_race_v1983_test"
# meta:ta.owner="update"
# meta:ta.module="watchdog-update-swap"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
HELPERS="$REPO_ROOT/cli/lib/nftban/cli/cmd_update_helpers.sh"
CMDUPD="$REPO_ROOT/cli/lib/nftban/cli/cmd_update.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1${2:+ — $2}"; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
CALLS="$WORK/calls"; : > "$CALLS"
declare -A ACTIVE=()      # ACTIVE[unit]=1 when "running"
WD_FAILS=0                # 1 => stubbed watchdog stays failed after start

# stub systemctl (a function is found by `command -v`); records every call.
systemctl() {
    echo "$*" >> "$CALLS"
    case "${1:-}" in
        is-active) local u="${*: -1}"; [[ "${ACTIVE[$u]:-0}" = 1 ]] && return 0 || return 1 ;;
        stop)      ACTIVE[${2:-}]=0; return 0 ;;
        start)     ACTIVE[${2:-}]=1; return 0 ;;
        is-failed) [[ "$WD_FAILS" = 1 ]] && return 0 || return 1 ;;
        reset-failed|cat) return 0 ;;
        *) return 0 ;;
    esac
}
# quiet logger stub (helpers call _update_log) — but source defines it; override after.
# shellcheck source=/dev/null
source "$HELPERS"
set +e                    # helpers set -Eeuo at source; this test drives non-zero returns
_update_log(){ :; }       # silence

calls_have(){ grep -qx -- "$1" "$CALLS"; }

echo "== A: inhibit stops ONLY active racing timers; records them =="
: > "$CALLS"; ACTIVE=( [nftban-watchdog.timer]=1 )   # maintenance INACTIVE
_update_inhibit_cadence_timers
calls_have "stop nftban-watchdog.timer" && ok "A stopped active watchdog timer" || no "A watchdog not stopped"
calls_have "stop nftban-maintenance.timer" && no "A stopped an INACTIVE timer (should not)" || ok "A did NOT stop the inactive maintenance timer"
[[ "$_NFTBAN_INHIBITED_TIMERS" == "nftban-watchdog.timer" ]] && ok "A recorded exactly the stopped timer" || no "A inhibited-list" "$_NFTBAN_INHIBITED_TIMERS"

echo "== B: restore re-starts EXACTLY those; never enable; idempotent =="
: > "$CALLS"; _update_restore_cadence_timers
calls_have "start nftban-watchdog.timer" && ok "B restored the watchdog timer" || no "B watchdog not restored"
calls_have "start nftban-maintenance.timer" && no "B started a never-stopped timer" || ok "B did NOT start the maintenance timer"
[[ -z "$_NFTBAN_INHIBITED_TIMERS" ]] && ok "B inhibited-list cleared after restore" || no "B list not cleared"
: > "$CALLS"; _update_restore_cadence_timers   # idempotent
[[ ! -s "$CALLS" ]] && ok "B restore is idempotent (no-op when list empty)" || no "B second restore acted" "$(tr '\n' ' ' <"$CALLS")"

echo "== C: never mask, never enable (any case) =="
: > "$CALLS"; ACTIVE=( [nftban-watchdog.timer]=1 [nftban-maintenance.timer]=1 )
_update_inhibit_cadence_timers; _update_restore_cadence_timers
grep -qiE '^(mask|enable|disable) ' "$CALLS" && no "C used mask/enable/disable" "$(grep -iE '^(mask|enable|disable) ' "$CALLS"|tr '\n' ' ')" || ok "C never mask/enable/disable (only stop/start)"
calls_have "stop nftban-watchdog.timer" && calls_have "stop nftban-maintenance.timer" && ok "C both active timers stopped" || no "C both not stopped"
calls_have "start nftban-watchdog.timer" && calls_have "start nftban-maintenance.timer" && ok "C both restored" || no "C both not restored"

echo "== D: failure-path restore (timers restored even if install 'fails') =="
: > "$CALLS"; ACTIVE=( [nftban-watchdog.timer]=1 )
_update_inhibit_cadence_timers
false   # simulate a failed install step (handled-failure path)
_update_restore_cadence_timers   # the explicit restore runs before the failure return
calls_have "start nftban-watchdog.timer" && ok "D timer restored on the handled-failure path" || no "D not restored on failure"

echo "== E: post-update watchdog verification =="
WD_FAILS=0; _update_verify_watchdog && ok "E clean watchdog → verify passes (rc0)" || no "E clean verify failed"
WD_FAILS=1; _update_verify_watchdog && no "E broken watchdog → verify should FAIL" || ok "E persistently-broken watchdog → verify fails (not masked)"
WD_FAILS=0

echo "== F: static guards on cmd_update.sh (wraps the install phase; scoped trap; no EXIT trap) =="
awk '/_update_phase 2 "Install"/{i=NR} /_update_inhibit_cadence_timers/&&!h{h=NR} /^    case "\$source" in/{c=NR} END{exit !(i>0 && h>i && c>h)}' "$CMDUPD" && ok "F inhibit sits between phase-2 and the install case (order)" || no "F inhibit placement"
grep -q "_update_inhibit_cadence_timers" "$CMDUPD" && ok "F cmd_update calls inhibit" || no "F inhibit not wired"
grep -q "_update_restore_cadence_timers" "$CMDUPD" && ok "F cmd_update calls restore" || no "F restore not wired"
grep -q "trap '_update_restore_cadence_timers' INT TERM" "$CMDUPD" && ok "F scoped INT/TERM trap present" || no "F scoped trap missing"
grep -qE "trap '_update_restore_cadence_timers' (INT TERM )?EXIT" "$CMDUPD" && no "F uses an EXIT trap (clobbers lock cleanup)" || ok "F no EXIT trap (lock cleanup not clobbered)"
grep -q "trap - INT TERM" "$CMDUPD" && ok "F scoped trap cleared after restore" || no "F trap not cleared"
grep -q "_update_verify_watchdog" "$CMDUPD" && ok "F post-update watchdog verification wired" || no "F verify not wired"

echo ""
echo "=== RESULT: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
