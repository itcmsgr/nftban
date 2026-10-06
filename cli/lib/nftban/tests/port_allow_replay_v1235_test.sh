#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.235 per-IP port grant replay (PORT-ALLOW-NOT-REPLAYED-AFTER-REBUILD)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="port_allow_replay_v1235_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-05"
# meta:description="BEHAVIORAL regression for v1.235 PORT-ALLOW-NOT-REPLAYED-AFTER-REBUILD (measured lab3 2026-10-03: a per-IP `port allow` grant was absent from port_allow_tcp_ipv4 after `firewall rebuild` and stayed absent across maintenance). Drives the REAL cli/lib/nftban/lib/nftban_port_allow.sh with a recording IPC stub: R1 a permanent grant is replayed with timeout 0; R2 a live timed grant is replayed with its REMAINING lifetime (never the full original duration); R3 an expired grant is NOT replayed; R4 an unreadable expiry is NOT replayed as permanent (counted invalid, rc 1); R5 daemon down -> UNMEASURED rc 2, nothing claimed; R6 an IPC failure -> rc 1. D1 removing port 80 keeps the 8080 grant and an IP whose dots differ (pre-v1.235 unanchored sed deleted both); D2 re-adding replaces, never duplicates. W1-W3 the replay is WIRED into firewall rebuild, firewall reset and the maintenance cycle (call-site census from the real files). M1 the maintenance cycle no longer writes the undeclared temp_whitelist sets nor claims active-SSH protection (owner 2026-10-06: dead step removed)."
# meta:input="None (self-contained sandbox)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,awk,jq,date,mktemp"
# meta:inventory.files=""
# meta:inventory.binaries="bash,awk,jq,date,mktemp"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="port_allow_replay_v1235_test"
# meta:ta.owner="firewall"
# meta:ta.module="port"
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
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
LIB="$REPO_ROOT/cli/lib/nftban/lib/nftban_port_allow.sh"
FW="$REPO_ROOT/cli/lib/nftban/cli/cmd_firewall.sh"
MAINT="$REPO_ROOT/cli/lib/nftban/cron/maintenance.sh"
PORT="$REPO_ROOT/cli/lib/nftban/cli/cmd_port.sh"
pass=0; fail=0
ok(){ echo "  [PASS] $1"; pass=$((pass+1)); }
ko(){ echo "  [FAIL] $1"; fail=$((fail+1)); }
for f in "$FW" "$MAINT" "$PORT"; do
    [[ -f "$f" ]] || { echo "  SUBJECT_NOT_FOUND: $f"; echo "TOTAL: pass=0 fail=1"; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "  NOT_EXECUTED: jq not installed"; echo "TOTAL: pass=0 fail=1"; exit 1; }
if [[ ! -f "$LIB" ]]; then
    ko "L0 replay library cli/lib/nftban/lib/nftban_port_allow.sh exists (no replay path at all)"
    echo "TOTAL: pass=$pass fail=$fail"; exit 1
fi

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
export NFTBAN_CONFIG_DIR="$SB/etc"; mkdir -p "$NFTBAN_CONFIG_DIR/access.d"
CONF="$NFTBAN_CONFIG_DIR/access.d/port_allow.conf"

# Driver: the REAL library under strict mode with a recording IPC stub.
# $1 = daemon up (yes|no)  $2 = IPC answer (ok|fail)
cat > "$SB/drive.sh" <<'DRV'
set -Eeuo pipefail
IFS=$'\n\t'
DAEMON="$1"; ANSWER="$2"; REC="$3"
nft_ipc_is_daemon_running(){ [[ "$DAEMON" == yes ]]; }
nft_ipc_request(){ printf '%s %s\n' "$1" "$2" >> "$REC"; [[ "$ANSWER" == ok ]] && echo '{"success":true}' || echo '{"success":false,"error":"stub"}'; }
nft_ipc_success(){ [[ "$1" == *'"success":true'* ]]; }
# shellcheck source=/dev/null
source "$LIBFILE"
rc=0; nftban_port_allow_replay || rc=$?
echo "RC=$rc"
DRV
replay(){ : > "$SB/rec"; LIBFILE="$LIB" bash "$SB/drive.sh" "$1" "$2" "$SB/rec" > "$SB/out" 2>&1 || true; }
rc_of(){ sed -n 's/^RC=//p' "$SB/out"; }
sent_timeout(){ # ip port -> timeout sent for that grant, or NONE
    local t; t=$(awk -v ip="$1" -v p="$2" '$1=="access_allow"{ $1=""; print }' "$SB/rec" \
        | jq -r --arg ip "$1" --argjson p "$2" 'select(.ip==$ip and .port==$p) | .timeout' 2>/dev/null) || t=""
    echo "${t:-NONE}"
}
iso(){ date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
NOW=$(date -u +%s)

echo "==============================================="
echo "v1.235 port allow replay"
echo "==============================================="
{
    echo "18767|192.0.2.10|tcp|0|perm|$(iso $((NOW-86400)))"
    echo "8443|192.0.2.11|tcp|3600|timed|$(iso $((NOW-600)))"
    echo "9000|192.0.2.12|udp|60|old|$(iso $((NOW-7200)))"
} > "$CONF"
replay yes ok
[[ "$(rc_of)" == "0" ]] && ok "R0 replay rc 0 with all grants valid" || ko "R0 rc=$(rc_of) out=$(tr '\n' ' ' < "$SB/out")"
[[ "$(sent_timeout 192.0.2.10 18767)" == "0" ]] && ok "R1 permanent grant replayed with timeout 0" || ko "R1 permanent grant: sent $(sent_timeout 192.0.2.10 18767)"
t=$(sent_timeout 192.0.2.11 8443)
if [[ "$t" =~ ^[0-9]+$ && "$t" -gt 2900 && "$t" -le 3000 ]]; then ok "R2 timed grant replayed with its REMAINING lifetime ($t s of 3600)"
else ko "R2 timed grant: sent '$t' (want ~3000 remaining, never the full 3600)"; fi
[[ "$(sent_timeout 192.0.2.12 9000)" == "NONE" ]] && ok "R3 expired grant NOT replayed" || ko "R3 expired grant replayed with $(sent_timeout 192.0.2.12 9000)"
grep -q 'replayed=2 expired=1 failed=0 invalid=0' "$SB/out" && ok "R0b summary counts replayed=2 expired=1" || ko "R0b summary: $(grep -m1 'port-allow' "$SB/out")"

echo "4000|192.0.2.13|tcp|600|bad|not-a-date" >> "$CONF"
replay yes ok
[[ "$(sent_timeout 192.0.2.13 4000)" == "NONE" && "$(rc_of)" == "1" ]] && ok "R4 unreadable expiry NOT replayed as permanent (rc 1, invalid)" \
    || ko "R4 unreadable expiry: sent $(sent_timeout 192.0.2.13 4000) rc=$(rc_of)"

replay no ok
if [[ "$(rc_of)" == "2" && ! -s "$SB/rec" ]] && grep -q 'UNMEASURED' "$SB/out"; then ok "R5 daemon down -> UNMEASURED rc 2, nothing sent"
else ko "R5 daemon down: rc=$(rc_of) out=$(tr '\n' ' ' < "$SB/out")"; fi

head -2 "$CONF" > "$CONF.2" && mv "$CONF.2" "$CONF"
replay yes fail
[[ "$(rc_of)" == "1" ]] && grep -q 'failed=2' "$SB/out" && ok "R6 IPC failure -> rc 1, failed counted" || ko "R6 IPC failure: rc=$(rc_of) out=$(tr '\n' ' ' < "$SB/out")"

# R7 — NO stubs: a caller that never loaded the IPC client (cmd_firewall.sh does
# not) must still get a working daemon probe from the library itself. On lab3
# the stubbed arms above passed while the real rebuild replay reported the
# running daemon as down ("command not found" read as not running).
r7=$(env -i PATH=/usr/bin:/bin NFTBAN_LIB_DIR="$REPO_ROOT/cli/lib/nftban" bash -c \
    'set -Eeuo pipefail; source "$1"; declare -F nft_ipc_is_daemon_running >/dev/null && echo DEFINED || echo UNDEFINED' _ "$LIB" 2>&1) || r7="ERROR:$r7"
[[ "$r7" == "DEFINED" ]] && ok "R7 library loads the IPC client itself (caller without nft_ipc.sh)" \
    || ko "R7 replay library depends on the caller for nft_ipc.sh ($r7)"

echo "[D] config edits — exact field match"
{
    echo "80|192.0.2.20|tcp|0||x"
    echo "8080|192.0.2.20|tcp|0||x"
    echo "80|192x0x2x20|tcp|0||x"
    echo "80|192.0.2.20|udp|0||x"
} > "$CONF"
n=$(bash -c 'source "$1"; nftban_port_allow_drop_entry 80 192.0.2.20 tcp' _ "$LIB")
if [[ "$n" == "1" ]] && grep -qxF '8080|192.0.2.20|tcp|0||x' "$CONF" && grep -qxF '80|192x0x2x20|tcp|0||x' "$CONF" \
   && grep -qxF '80|192.0.2.20|udp|0||x' "$CONF" && ! grep -qxF '80|192.0.2.20|tcp|0||x' "$CONF"; then
    ok "D1 remove 80/tcp keeps 8080, the udp grant and a dots-differ IP (removed exactly 1)"
else ko "D1 exact removal: removed=$n conf=$(tr '\n' ';' < "$CONF")"; fi
# D2 — add path: drop the existing entry BEFORE appending (census of the real add function)
addfn=$(awk '/^nftban_port_allow_add\(\)/{c=1} c{print} c&&/^}/{exit}' "$PORT")
d_line=$(printf '%s\n' "$addfn" | awk '/nftban_port_allow_drop_entry "\$port" "\$ip" "\$proto"/ && !n {n=NR} END{print n}')
a_line=$(printf '%s\n' "$addfn" | awk '/>> "\$NFTBAN_PORT_ALLOW_CONFIG"/ && !n {n=NR} END{print n}')
if [[ -n "$d_line" && -n "$a_line" && "$d_line" -lt "$a_line" ]]; then ok "D2 add replaces an existing port/ip/proto entry before appending (no duplicate)"
else ko "D2 add path: drop_entry line='${d_line:-none}' append line='${a_line:-none}'"; fi
rmfn=$(awk '/^nftban_port_allow_remove\(\)/{c=1} c{print} c&&/^}/{exit}' "$PORT")
if [[ "$rmfn" == *nftban_port_allow_drop_entry* && "$rmfn" != *'sed -i'* ]]; then
    ok "D3 remove uses the exact-field helper, no regex sed"
else ko "D3 remove still regex-based"; fi

echo "[W] replay wired into every plane that reloads the sets"
rb=$(awk '/^_firewall_rebuild_core\(\)/{c=1} c&&!/^[[:space:]]*#/{print} c&&/^}/{exit}' "$FW")
rbw=$(awk '/^firewall_rebuild\(\)/{c=1} c&&!/^[[:space:]]*#/{print} c&&/^}/{exit}' "$FW")
rbs=$(awk '/^_firewall_rebuild_serialized\(\)/{c=1} c&&!/^[[:space:]]*#/{print} c&&/^}/{exit}' "$FW")
if [[ "$rbw" == *"_firewall_rebuild_serialized \"\$@\""* && "$rbs" == *"_firewall_rebuild_core \"\$@\""* ]]; then ok "W0 firewall rebuild -> _firewall_rebuild_serialized -> _firewall_rebuild_core (code lines, not comments)"
else ko "W0 firewall rebuild does not reach _firewall_rebuild_core"; fi
rs=$(awk '/^firewall_reset\(\)/{c=1} c&&!/^[[:space:]]*#/{print} c&&/^}/{exit}' "$FW")
mt=$(awk '/^main\(\)/{c=1} c&&!/^[[:space:]]*#/{print} c&&/^}/{exit}' "$MAINT")
for pair in "W1 firewall rebuild|$rb" "W2 firewall reset|$rs" "W3 maintenance cycle|$mt"; do
    name="${pair%%|*}"; body="${pair#*|}"
    if [[ -z "$body" ]]; then ko "$name: SUBJECT_FUNCTION_NOT_FOUND"
    elif [[ "$body" == *nftban_port_allow_replay* ]]; then ok "$name calls nftban_port_allow_replay"
    else ko "$name does not replay per-IP port grants"; fi
done

# M1 — v1.235 BUG-MAINTENANCE-ACTIVE-SSH-AUTO-WHITELIST-IS-DEAD-AND-CLAIMS-OK
# (owner 2026-10-06: remove the step and its false claim). The cycle must not
# write to the undeclared temp_whitelist_* sets, and must not log a protection
# that is not applied. Comments are excluded: the removal note may name them.
echo "[M] maintenance makes no false active-SSH protection claim"
if [[ -z "$mt" ]]; then ko "M1 maintenance main(): SUBJECT_FUNCTION_NOT_FOUND"
elif [[ "$mt" == *temp_whitelist_ipv* ]]; then ko "M1 maintenance still writes to the undeclared temp_whitelist sets"
elif [[ "$mt" == *"session protection: OK"* || "$mt" == *"Protecting active SSH sessions"* ]]; then ko "M1 maintenance still claims active SSH session protection"
else ok "M1 no write to undeclared temp_whitelist sets and no protection claim"; fi

echo ""
echo "TOTAL: pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
