#!/usr/bin/env bash
# =============================================================================
# NFTBan Test - Update Warning Taxonomy + Timer-Restore Fix (v1.216.4)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="update-warning-taxonomy-v2164-test"
# meta:type="test"
# meta:header="Update Warning Taxonomy v1.216.4"
# meta:version="1.216.3"
# meta:owner="NFTBan Project / Antonios Voulvoulis"
# meta:homepage="https://nftban.com"
#
# meta:description="Hermetic regression for v1.216.4 lane A. (1) BUG-UPDATE-INHIBITED-TIMER-FALSE-WARN: under the update entrypoint IFS (newline+tab, no space) _update_restore_cadence_timers must still start EACH inhibited timer individually (never as one combined malformed unit) and warn ONLY if a timer is genuinely inactive after restore — a transient start error that self-heals is a recovered advisory, not a WARN. (2) _update_classify_warnings buckets installer-log WARN lines into action/recovered/accepted/external, dedups the tmpfiles firewall-validate exception (W2/W3) and needrestart/kernel advisory (W4), skips the installer meta self-report, and leaves a genuine WARN as REAL. (3) static: Action needed:NONE iff WARN_REAL==0."
# meta:inventory.files="cli/lib/nftban/cli/cmd_update_helpers.sh,cli/lib/nftban/cli/cmd_update.sh"
# meta:inventory.binaries="bash,systemctl(stub)"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units="nftban-watchdog.timer,nftban-maintenance.timer"
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:created_date="2026-07-04"
# meta:updated_date="2026-07-04"
# meta:ta.id="update_warning_taxonomy_v2164_test"
# meta:ta.owner="update"
# meta:ta.module="warning-taxonomy"
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
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT=$(cd "$SD/../../../.." && pwd)
HELPERS="$ROOT/cli/lib/nftban/cli/cmd_update_helpers.sh"
CMDUPD="$ROOT/cli/lib/nftban/cli/cmd_update.sh"
P=0; F=0
ok(){ echo "PASS $1"; P=$((P+1)); }
no(){ echo "FAIL $1 ${2:-}"; F=$((F+1)); }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
CALLS="$WORK/calls"; LOG="$WORK/log"

declare -A ACTIVE=()
FAIL_TIMER=""   # a timer name whose `start` fails and never becomes active (simulates a real stuck timer)
systemctl() {
    local IFS=' '            # record args space-joined regardless of the caller's IFS ($* uses IFS[0])
    echo "$*" >> "$CALLS"
    case "${1:-}" in
        is-active) local u="${*: -1}"; [[ "${ACTIVE[$u]:-0}" = 1 ]] && return 0 || return 1 ;;
        stop)      ACTIVE[${2:-}]=0; return 0 ;;
        start)     if [[ "${2:-}" == "$FAIL_TIMER" ]]; then return 1; fi; ACTIVE[${2:-}]=1; return 0 ;;
        *)         return 0 ;;
    esac
}
# shellcheck source=/dev/null
source "$HELPERS"
set +e
_update_log(){ echo "$1 ${*:2}" >> "$LOG"; }   # capture level+message
calls_have(){ grep -qx -- "$1" "$CALLS"; }

echo "== W1-A: restore under IFS=\$'\\n\\t' starts EACH timer individually (no combined-arg bug) =="
: > "$CALLS"; : > "$LOG"; ACTIVE=(); FAIL_TIMER=""
_NFTBAN_INHIBITED_TIMERS="nftban-watchdog.timer nftban-maintenance.timer"
OLDIFS=$IFS; IFS=$'\n\t'          # reproduce cmd_update.sh:30 (space NOT in IFS)
_update_restore_cadence_timers
IFS=$OLDIFS
calls_have "start nftban-watchdog.timer"     && ok "W1-A started watchdog.timer individually"   || no "W1-A watchdog not started"
calls_have "start nftban-maintenance.timer"  && ok "W1-A started maintenance.timer individually" || no "W1-A maintenance not started"
grep -q "start nftban-watchdog.timer nftban-maintenance.timer" "$CALLS" && no "W1-A combined-arg bug present" || ok "W1-A no combined-arg systemctl call"
grep -qi 'WARN' "$LOG" && no "W1-A emitted a WARN though both timers active" "$(cat "$LOG")" || ok "W1-A no false WARN (both verified active)"
[[ -z "$_NFTBAN_INHIBITED_TIMERS" ]] && ok "W1-A inhibited-list cleared" || no "W1-A list not cleared"

echo "== W1-B: WARN_REAL only when a timer stays inactive after restore =="
: > "$CALLS"; : > "$LOG"; ACTIVE=(); FAIL_TIMER="nftban-maintenance.timer"
_NFTBAN_INHIBITED_TIMERS="nftban-watchdog.timer nftban-maintenance.timer"
_update_restore_cadence_timers
grep -qi 'WARN.*still inactive after restore.*nftban-maintenance.timer' "$LOG" && ok "W1-B real WARN when timer genuinely inactive" || no "W1-B no real WARN emitted" "$(cat "$LOG")"

echo "== W1-C: transient start error that self-heals is recovered, not WARN =="
# start 'fails' but is-active still reports active (self-heal via installer reconciliation)
: > "$CALLS"; : > "$LOG"; ACTIVE=( [nftban-watchdog.timer]=1 ); FAIL_TIMER="nftban-watchdog.timer"
_NFTBAN_INHIBITED_TIMERS="nftban-watchdog.timer"
_update_restore_cadence_timers
{ grep -qi 'recovered — verified active' "$LOG" && ! grep -qi 'WARN' "$LOG"; } && ok "W1-C transient→recovered advisory, no WARN" || no "W1-C misclassified" "$(cat "$LOG")"

echo "== W1-D: empty inhibited list is a clean no-op =="
: > "$CALLS"; : > "$LOG"; _NFTBAN_INHIBITED_TIMERS=""
_update_restore_cadence_timers
[[ ! -s "$CALLS" && ! -s "$LOG" ]] && ok "W1-D empty list no-op" || no "W1-D acted on empty list"

echo "== TAX: classify buckets action/recovered/accepted/external, dedups tmpfiles+needrestart, skips meta =="
ILOG="$WORK/installer.log"
cat > "$ILOG" <<'LOGEOF'
[NFTBan WARN] 19:29:56 systemd-tmpfiles --create failed (exit 73) — non-fatal
Detected unsafe path transition /run/nftban (owned by nftban) -> /run/nftban/firewall-validate (owned by root)
Pending kernel upgrade!
  systemctl restart networkd-dispatcher.service (deferred)
[NFTBan] Restored cadence timer(s): nftban-watchdog.timer (recovered — verified active after a transient start error)
[NFTBan WARN] 19:30:00 some genuine unresolved problem needs attention
[NFTBan] Install/upgrade completed (state: COMMITTED, with 1 warning — non-fatal; see log).
LOGEOF
_update_classify_warnings "$ILOG" 0
[[ "${_NFTBAN_WARN_REAL}"      = 1 ]] && ok "TAX real=1 (only the genuine warning)"        || no "TAX real" "$_NFTBAN_WARN_REAL"
[[ "${_NFTBAN_WARN_RECOVERED}" = 1 ]] && ok "TAX recovered=1 (timer transient)"            || no "TAX recovered" "$_NFTBAN_WARN_RECOVERED"
[[ "${_NFTBAN_WARN_ACCEPTED}"  = 1 ]] && ok "TAX accepted=1 (tmpfiles W2+W3 deduped)"       || no "TAX accepted" "$_NFTBAN_WARN_ACCEPTED"
[[ "${_NFTBAN_WARN_EXTERNAL}"  = 1 ]] && ok "TAX external=1 (needrestart+kernel deduped)"   || no "TAX external" "$_NFTBAN_WARN_EXTERNAL"

echo "== TAX-CLEAN: an upgrade with only accepted/external/recovered has WARN_REAL=0 =="
cat > "$ILOG" <<'LOGEOF'
[NFTBan WARN] systemd-tmpfiles --create failed (exit 73) — non-fatal
Pending kernel upgrade!
[NFTBan] Restored cadence timer(s): nftban-watchdog.timer (recovered — verified active after a transient start error)
[NFTBan] Install/upgrade completed (state: COMMITTED, with 1 warning — non-fatal; see log).
LOGEOF
_update_classify_warnings "$ILOG" 0
[[ "${_NFTBAN_WARN_REAL}" = 0 ]] && ok "TAX-CLEAN real=0 → Action needed would be NONE" || no "TAX-CLEAN real not 0" "$_NFTBAN_WARN_REAL"

echo "== STATIC: cmd_update.sh ties Action needed to WARN_REAL, and summary is class-aware =="
grep -q '_update_classify_warnings' "$CMDUPD"      && ok "STATIC cmd_update calls the classifier" || no "STATIC classifier not wired"
grep -q '_NFTBAN_WARN_REAL' "$CMDUPD"              && ok "STATIC action-needed reads WARN_REAL"   || no "STATIC WARN_REAL not used"
grep -q 'action / .* recovered / .* accepted / .* external' "$HELPERS" && ok "STATIC summary prints class breakdown" || no "STATIC breakdown missing"

echo ""
echo "=== update_warning_taxonomy_v2164: PASS=$P FAIL=$F ==="
[[ "$F" -eq 0 ]]
