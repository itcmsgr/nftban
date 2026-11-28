#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.238.2: the stealth aggregate acts once per evidence; an unban holds
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="portscan_aggregate_acted_evidence_v1238_2_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-28"
# meta:description="v1.238.2 (owner 2026-11-28; BUG-PORTSCAN-AGGREGATE-24H-RESCAN-RE-BANS-EVERY-CYCLE-AND-FALLBACK-UNWINDOWED). MEASURED on EL10 enforcing: the 15-min stealth aggregate re-banned two addresses from two-day-old file records at every run, and an operator unban did not hold. Sources the REAL nftban_portscan_classic.sh; every run is a fresh bash (as the maintenance timer runs it) with the FILE source (no journalctl on PATH, as on EL enforcing where the event logger is denied) and a stub nftban_ban that writes the daemon's bans.log line (DATE|TIME|portscan|IP|..|BANNED|..). Owner table: qualifying records older than 24 h -> 0 actions; fresh qualifying records -> 1 action, then 0 on the next run with identical input; after an operator unban -> still 0 (also in a fresh shell = restart); fresh qualifying evidence after the unban -> 1 action again. Also: an unreadable event time is skipped, never counted as now. Non-vacuity: the v1.238.1 code re-bans on every run. Sandbox only; documentation IPs; no firewall change."
# meta:input="cli/lib/nftban/core/nftban_portscan_classic.sh (repo, read-only); temp dirs"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,mktemp,date,awk"
# meta:inventory.files="cli/lib/nftban/core/nftban_portscan_classic.sh"
# meta:inventory.binaries="bash,mktemp,date,awk"
# meta:inventory.env_vars="NFTBAN_LOG_DIR,NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="portscan_aggregate_acted_evidence_v1238_2_test"
# meta:ta.owner="portscan"
# meta:ta.module="portscan-classic"
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
SRC="$LIBDIR/core/nftban_portscan_classic.sh"
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }; no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
mkdir -p "$W/log" "$W/etc" "$W/bin"
EV="$W/log/portscan-events.log"; BL="$W/log/bans.log"; : > "$EV"; : > "$BL"
# PATH without journalctl: the file source is used, as on EL enforcing.
for b in bash date awk sort tr grep wc cat mkdir dirname tail head sed cut; do
    p=$(command -v "$b") && ln -s "$p" "$W/bin/$b"
done

# qualifying batch: 25 events from <ip> to 25 distinct ports, times starting at <epoch>
batch() { local ip=$1 t=$2 i
    for i in $(seq 0 24); do
        printf 'ts=%s src=%s dst=192.0.2.1 proto=TCP dpt=%s flags=SYN\n' \
            "$(date -u -d "@$((t + i))" +%Y-%m-%dT%H:%M:%S+00:00)" "$ip" "$((41001 + i))"
    done >> "$EV"
}
# run one scheduled aggregate in a fresh shell; prints the addresses banned in this run
run() {
    : > "$W/act"
    env -i PATH="$W/bin" HOME="$W" NFTBAN_LOG_DIR="$W/log" NFTBAN_LIB_DIR="$LIBDIR" NFTBAN_CONFIG_DIR="$W/etc" W="$W" bash -c '
        source "$1" >/dev/null 2>&1 || { echo SOURCE_FAILED; exit 9; }
        nftban_ban() { echo "$1" >> "$W/act"
            printf "%s|%s|portscan|%s|ZZ|BANNED|portscan:stealth|t\n" "$(date +%Y-%m-%d)" "$(date +%H:%M:%S)" "$1" >> "$W/log/bans.log"; }
        nftban_portscan_aggregate --since 24h --ban >/dev/null 2>&1' _ "$SRC"
    tr '\n' ' ' < "$W/act" | sed 's/ $//'
}
now=$(date +%s)

echo "=== 1. qualifying records older than 24 h -> zero actions ==="
batch 192.0.2.10 $((now - 2*86400))
r=$(run); [[ -z "$r" ]] && ok "2-day-old batch: 0 actions" || no "old batch acted on" "[$r]"

echo "=== 2. fresh qualifying records -> one action, then none on identical input ==="
batch 192.0.2.20 $((now - 600))
r=$(run); [[ "$r" == "192.0.2.20" ]] && ok "first run: 1 action (192.0.2.20)" || no "first run" "[$r]"
sleep 1
r=$(run); [[ -z "$r" ]] && ok "next run, identical input: 0 actions" || no "re-ban on identical input" "[$r]"

echo "=== 3. operator unban, identical input -> the address stays unbanned ==="
printf '%s|%s|manual|192.0.2.20|ZZ|UNBANNED|operator|t\n' "$(date +%Y-%m-%d)" "$(date +%H:%M:%S)" >> "$BL"
r=$(run); [[ -z "$r" ]] && ok "after unban: 0 actions" || no "unban undone" "[$r]"
r=$(run); [[ -z "$r" ]] && ok "after a restart (fresh shell): still 0" || no "unban undone after restart" "[$r]"

echo "=== 4. fresh qualifying evidence after the unban -> acts again ==="
sleep 2
batch 192.0.2.20 $(( $(date +%s) + 1 ))
r=$(run); [[ "$r" == "192.0.2.20" ]] && ok "new evidence: 1 action" || no "new evidence after unban" "[$r]"

echo "=== 5. an unreadable event time is skipped, never 'now' ==="
for i in $(seq 0 24); do printf 'ts=notatime src=192.0.2.30 dst=192.0.2.1 proto=TCP dpt=%s flags=SYN\n' "$((42001 + i))"; done >> "$EV"
r=$(run); [[ "$r" != *192.0.2.30* ]] && ok "unreadable times: no action for 192.0.2.30" || no "unreadable time counted as now" "[$r]"

echo ""
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
