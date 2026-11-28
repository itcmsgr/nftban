#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.238.2: Suricata PortScan acts on each EVE alert once (read position persists)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="portscan_suricata_eve_position_v1238_2_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-28"
# meta:description="v1.238.2 (owner 2026-11-28; BUG-PORTSCAN-SURICATA-EVE-OFFSET-NEVER-PERSISTED-REPLAYS-EVERY-CYCLE). MEASURED on v1.238.1 EL9 enforcing: 2 EVE alerts -> 2,185 BANNED lines, one per minute for ~36 h: the daemon cycle (a fresh shell each minute) never saved the EVE read offset. Sources the REAL nftban_portscan_suricata.sh; every cycle is a NEW bash (as module.go runs it) with a stub nftban_ban that records each ban attempt. Asserts, in order: alerts written before the fix (old state without the v2 marker) are not acted on; a new marked alert -> exactly 1 action; the next cycle and a 'restart' with the same EVE -> 0 actions; a second new alert -> exactly its 1 action (rules out a reader that simply stopped); a half-written line waits for its newline; a FAILED ban is reported and retried next cycle without repeating the alerts before it; a batch cut continues next cycle without loss or repeat; a FAILED position save is reported on stderr and does not fail the cycle. Non-vacuity: the v1.238.1 code replays. Sandbox only; documentation IPs; no firewall change."
# meta:input="cli/lib/nftban/core/nftban_portscan_suricata.sh (repo, read-only); temp dirs"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,mktemp,grep,awk,od,bc"
# meta:inventory.files="cli/lib/nftban/core/nftban_portscan_suricata.sh"
# meta:inventory.binaries="bash,mktemp,grep,awk,od,bc,tail,head,stat"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR,NFTBAN_LOG_DIR,PORTSCAN_SURICATA_EVE_FILE,PORTSCAN_SURICATA_STATE_FILE,PORTSCAN_SURICATA_BATCH_SIZE"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="portscan_suricata_eve_position_v1238_2_test"
# meta:ta.owner="portscan"
# meta:ta.module="portscan"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -uo pipefail
LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$LIBDIR/core/nftban_portscan_suricata.sh"
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }; no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
command -v bc >/dev/null 2>&1 || { echo "PRECONDITION: bc not installed (the threshold comparison needs it) — NOT_EXECUTED"; exit 3; }
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
mkdir -p "$W/etc" "$W/log" "$W/state"
EVE="$W/eve-alerts.json"; ST="$W/state/portscan-suricata-state.db"; : > "$EVE"; : > "$W/actions"; echo 0 > "$W/ban_rc"

alert() { # $1 = src ip
    printf '{"timestamp":"2026-11-28T09:00:00.000000+0000","event_type":"alert","src_ip":"%s","dest_ip":"192.0.2.1","dest_port":40999,"proto":"TCP","alert":{"signature_id":9238001,"signature":"NFTBAN-TEST PortScan probe","severity":2,"category":"Attempted Information Leak"}}' "$1"
}
flow() { printf '{"timestamp":"2026-11-28T09:00:00.000000+0000","event_type":"flow","src_ip":"192.0.2.99","dest_ip":"192.0.2.1"}'; }

# cycle [state-file] -> runs ONE daemon-like cycle in a fresh shell; stderr to $W/stderr; rc to $W/rc
cycle() {
    local st="${1:-$ST}"
    : > "$W/actions.cycle"
    env -i PATH="/usr/bin:/bin" HOME="$W" NFTBAN_LIB_DIR="$LIBDIR" NFTBAN_CONFIG_DIR="$W/etc" NFTBAN_LOG_DIR="$W/log" \
        PORTSCAN_SURICATA_EVE_FILE="$EVE" PORTSCAN_SURICATA_STATE_FILE="$st" \
        PORTSCAN_SURICATA_BATCH_SIZE="${BATCH:-100}" W="$W" bash -c '
        source "$1" >/dev/null 2>&1 || { echo SOURCE_FAILED >&2; exit 9; }
        set -Eeuo pipefail
        nftban_ban() { echo "$1" >> "$W/actions.cycle"; return "$(cat "$W/ban_rc")"; }
        nftban_portscan_suricata_load_config >/dev/null 2>&1 || true
        nftban_portscan_suricata_init_state
        nftban_portscan_suricata_run' _ "$SRC" 2>"$W/stderr"
    echo $? > "$W/rc"
    cat "$W/actions.cycle" >> "$W/actions"
}
acted() { tr '\n' ' ' < "$W/actions.cycle" | sed 's/ $//'; }

echo "=== 1. alerts from before the fix are not acted on ==="
{ alert 192.0.2.10; echo; flow; echo; alert 192.0.2.11; echo; } >> "$EVE"
printf '# old\nEVE_OFFSET|0|0\n' > "$ST"     # v1.238.1 shape: no reader marker
cycle
[[ -z "$(acted)" && "$(cat "$W/rc")" == 0 ]] && ok "pre-existing alerts: 0 actions" || no "pre-existing alerts acted on" "[$(acted)] rc=$(cat "$W/rc")"
grep -q '^EVE_READER|0|v2$' "$ST" && ok "position saved with the v2 marker" || no "state file" "$(cat "$ST")"

echo "=== 2. a new marked alert -> exactly one action ==="
{ alert 192.0.2.20; echo; } >> "$EVE"
cycle
[[ "$(acted)" == "192.0.2.20" ]] && ok "first cycle: 1 action (192.0.2.20)" || no "first cycle" "[$(acted)]"

echo "=== 3. same EVE, no new alert: next cycle and a restart -> 0 actions ==="
cycle;  [[ -z "$(acted)" ]] && ok "next cycle: 0 actions" || no "next cycle repeated" "[$(acted)]"
cycle;  [[ -z "$(acted)" ]] && ok "after a restart (fresh shell, state from disk): 0 actions" || no "restart repeated" "[$(acted)]"

echo "=== 4. a second new alert -> its one action (the reader did not just stop) ==="
{ flow; echo; alert 192.0.2.21; echo; } >> "$EVE"
cycle
[[ "$(acted)" == "192.0.2.21" ]] && ok "second alert: 1 action (192.0.2.21), nothing repeated" || no "second alert" "[$(acted)]"

echo "=== 5. a half-written line waits for its newline ==="
alert 192.0.2.22 >> "$EVE"
cycle;  [[ -z "$(acted)" ]] && ok "partial line: 0 actions" || no "partial line acted on" "[$(acted)]"
echo >> "$EVE"
cycle;  [[ "$(acted)" == "192.0.2.22" ]] && ok "completed line: 1 action" || no "completed line" "[$(acted)]"

echo "=== 6. a failed ban is reported and retried; nothing before it repeats ==="
{ alert 192.0.2.23; echo; alert 192.0.2.24; echo; } >> "$EVE"
echo 1 > "$W/ban_rc"
cycle
[[ "$(acted)" == "192.0.2.23" ]] && ok "failing ban: one attempt, the cycle stops at it" || no "failing ban attempts" "[$(acted)]"
grep -q 'a ban for an EVE alert failed' "$W/stderr" && ok "the failure is visible (stderr)" || no "failure not visible" "$(cat "$W/stderr")"
grep -q 'Blocked 192.0.2.23' "$W/log/portscan-suricata.log" 2>/dev/null && no "a failed ban was logged as Blocked" || ok "no 'Blocked' line for the failed ban"
[[ "$(cat "$W/rc")" == 0 ]] && ok "the cycle itself does not fail" || no "cycle rc" "$(cat "$W/rc")"
echo 0 > "$W/ban_rc"
cycle
[[ "$(acted)" == "192.0.2.23 192.0.2.24" ]] && ok "next cycle: the failed alert is retried, then the next one" || no "retry" "[$(acted)]"
cycle;  [[ -z "$(acted)" ]] && ok "then 0 actions" || no "after retry" "[$(acted)]"

echo "=== 7. a batch cut continues next cycle without loss or repeat ==="
{ alert 192.0.2.25; echo; alert 192.0.2.26; echo; alert 192.0.2.27; echo; } >> "$EVE"
BATCH=2 cycle; [[ "$(acted)" == "192.0.2.25 192.0.2.26" ]] && ok "batch 2: first two" || no "batch first" "[$(acted)]"
BATCH=2 cycle; [[ "$(acted)" == "192.0.2.27" ]] && ok "batch 2: the third next cycle" || no "batch second" "[$(acted)]"
BATCH=2 cycle; [[ -z "$(acted)" ]] && ok "batch 2: then 0" || no "batch third" "[$(acted)]"

echo "=== 8. the ban succeeds but the position cannot be saved ==="
if [[ "$(id -u)" == 0 ]]; then
    echo "  - SKIP (root): a read-only directory is still writable for root; run this test as an unprivileged user"
else
    # A readable v2 state at the current end, in a directory the cycle cannot write to.
    mkdir -p "$W/ro"
    printf '# copy\nEVE_READER|0|v2\nEVE_OFFSET|0|%s\n' "$(stat -c %s "$EVE")" > "$W/ro/state.db"
    chmod 0555 "$W/ro"
    { alert 192.0.2.28; echo; } >> "$EVE"
    cycle "$W/ro/state.db"
    chmod 0755 "$W/ro"
    [[ "$(acted)" == "192.0.2.28" ]] && ok "the ban happens (once) in this cycle" || no "ban in the save-fail cycle" "[$(acted)]"
    grep -q 'EVE read position not saved' "$W/stderr" && ok "the failed save is visible (stderr)" || no "failed save not visible" "$(cat "$W/stderr")"
    grep -q 'may be acted on again' "$W/log/portscan-suricata.log" 2>/dev/null && ok "the log says the alerts may be acted on again" || no "log line for the failed save" "missing"
    [[ "$(cat "$W/rc")" == 0 ]] && ok "a failed save does not fail the cycle (hybrid: classic still runs)" || no "cycle rc on save failure" "$(cat "$W/rc")"
fi

echo ""
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
