#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.235 - maintenance skips PortScan ingestion only when the daemon owns it
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="maintenance_portscan_plane_v1235_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-07"
# meta:description="BUG-PORTSCAN-CLASSIC-CURSOR-SHARED-BY-DAEMON-AND-MAINTENANCE-PLANES (v1.235, lead ruling: option A with the daemon-plane condition). Sources the REAL cron/maintenance.sh (main runs only when executed) with every product root in a sandbox, a bound unix socket file and a stub socat returning a chosen `modules` IPC reply, and drives _maint_portscan_daemon_plane. Arms: M1 no socket -> UNKNOWN (maintenance ingests); M2 portscan running in classic mode -> ACTIVE (the only state that skips); M3 daemon reachable but portscan NOT running -> NOT_CLASSIC_RUNNING (ingests: nftband active alone is not proof); M4 portscan running in suricata mode -> NOT_CLASSIC_RUNNING (ingests); M5 reply without a portscan entry -> NOT_REPORTED (ingests); M6 unreadable reply -> UNKNOWN (ingests); S1 step 7 skips process_logs only on ACTIVE (source shape); S2 sourcing maintenance.sh does not run main."
# meta:inventory.files="cli/lib/nftban/cron/maintenance.sh"
# meta:inventory.binaries="bash,python3,jq,mktemp,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# meta:ta.id="maintenance_portscan_plane_v1235_test"
# meta:ta.owner="portscan"
# meta:ta.module="portscan-classic-planes"
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
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(cd "$TEST_DIR/.." && pwd)"
M="$LIB/cron/maintenance.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

echo "=== v1.235: maintenance PortScan ingestion vs the daemon plane ==="
for b in jq python3; do command -v "$b" >/dev/null 2>&1 || { echo "  NOT_EXECUTED: $b missing"; echo "RESULT: NOT_EXECUTED"; exit 3; }; done
[[ -f "$M" ]] || { echo "  NOT_EXECUTED: $M missing"; echo "RESULT: NOT_EXECUTED"; exit 3; }

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/etc" "$SB/data" "$SB/log" "$SB/cache" "$SB/run" "$SB/bin"
# stub socat: prints the reply in $SB/reply (the real IPC is replaced, the socket file is real)
cat > "$SB/bin/socat" <<EOF
#!/usr/bin/env bash
cat > /dev/null
[[ -f "$SB/reply" ]] && cat "$SB/reply"
EOF
chmod 0755 "$SB/bin/socat"

plane(){ # -> what _maint_portscan_daemon_plane prints, the real maintenance.sh sourced in a sandbox
    env -i PATH="$SB/bin:/usr/bin:/bin" HOME="$SB" NFTBAN_LIB_DIR="$LIB" NFTBAN_CONFIG_DIR="$SB/etc" \
        NFTBAN_DATA_DIR="$SB/data" NFTBAN_LOG_DIR="$SB/log" NFTBAN_CACHE_DIR="$SB/cache" NFTBAN_RUN_DIR="$SB/run" \
        M="$M" bash -c 'source "$M" >/dev/null 2>&1; _maint_portscan_daemon_plane' 2>/dev/null
}
reply(){ printf '%s\n' "$1" > "$SB/reply"; }
mods(){ # <running> <mode> -> a modules reply with loginmon + portscan
    printf '{"success":true,"data":[{"name":"loginmon","running":true,"extra":{"mode":"classic"}},{"name":"portscan","enabled":true,"running":%s,"extra":{"mode":"%s","suricata_available":false}}]}' "$1" "$2"
}

r="$(plane)"; [[ "$r" == UNKNOWN ]] && ok "M1 no daemon socket -> UNKNOWN (maintenance ingests)" || no "M1" "$r"

python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$SB/run/nftband.sock"
[[ -S "$SB/run/nftband.sock" ]] || { echo "  NOT_EXECUTED: could not create a unix socket file"; echo "RESULT: NOT_EXECUTED"; exit 3; }

reply "$(mods true classic)"
r="$(plane)"; [[ "$r" == ACTIVE ]] && ok "M2 portscan running in classic mode -> ACTIVE (the only state that skips)" || no "M2" "$r"
reply "$(mods false classic)"
r="$(plane)"; [[ "$r" == "NOT_CLASSIC_RUNNING (false classic)" ]] \
    && ok "M3 daemon reachable, portscan NOT running -> ${r} (maintenance still ingests)" || no "M3 daemon-up alone treated as ownership" "$r"
reply "$(mods true suricata)"
r="$(plane)"; [[ "$r" == "NOT_CLASSIC_RUNNING (true suricata)" ]] && ok "M4 portscan in suricata mode -> ${r} (ingests)" || no "M4" "$r"
reply '{"success":true,"data":[{"name":"loginmon","running":true,"extra":{}}]}'
r="$(plane)"; [[ "$r" == NOT_REPORTED ]] && ok "M5 no portscan entry -> NOT_REPORTED (ingests)" || no "M5" "$r"
reply 'garbage, not JSON'
r="$(plane)"; [[ "$r" == UNKNOWN ]] && ok "M6 unreadable reply -> UNKNOWN (ingests)" || no "M6" "$r"

# S1 — step 7 calls process_logs on every state except ACTIVE.
step7="$(awk '/\[7\/10\]/{p=1} p{print} /\[8\/10\]/{exit}' "$M")"
if grep -qF '_ps_plane="$(_maint_portscan_daemon_plane)"' <<<"$step7" \
   && grep -qF 'if [[ "$_ps_plane" == ACTIVE ]]; then' <<<"$step7" \
   && awk 'index($0, "_ps_plane\" == ACTIVE") {a=1} a && index($0, "else") {e=1} e && index($0, "nftban_portscan_classic_process_logs 2>") {f=1} END {exit f ? 0 : 1}' <<<"$step7"; then
    ok "S1 step 7 ingests in the else branch of ACTIVE (skip only when the daemon reports ownership)"
else no "S1 step 7 shape changed"; fi

# S2 — sourcing does not run maintenance (no step log written).
env -i PATH="/usr/bin:/bin" NFTBAN_LIB_DIR="$LIB" NFTBAN_CONFIG_DIR="$SB/etc" NFTBAN_DATA_DIR="$SB/data" NFTBAN_LOG_DIR="$SB/log" \
    NFTBAN_CACHE_DIR="$SB/cache" NFTBAN_RUN_DIR="$SB/run" M="$M" bash -c 'source "$M" >/dev/null 2>&1; true'
[[ ! -s "$SB/log/maintenance.log" ]] && ok "S2 sourcing maintenance.sh defines functions only (main not run)" || no "S2 sourcing ran maintenance"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
exit 0
