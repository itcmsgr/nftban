#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.235 - Tunnel DNS parsers honour the scan window (since_ts)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="tunnel_dns_since_window_v1235_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-07"
# meta:description="BUG-TUNNEL-DNS-PARSERS-IGNORE-SINCE-LIFETIME-COUNTS-SCORED-AS-5MIN-WINDOW (v1.235). COUNTING and ALERTING are tested separately (owner 2026-10-07). COUNTING drives the REAL BIND, unbound and dnsmasq parsers (core/nftban_tunnel_parsers.sh) with explicit since values: P1 3 lines in [T-300,T] + 4 older -> 3 counted; P2 the next run (since=T, no new lines) -> 0 counted; P3 boundary: a line at exactly since is in, since-1 is out; P4 unbound [epoch]; P5 RFC3339 with offset (+02:00) converted correctly; P6 traditional syslog without year (times relative to now); P7 a line without a readable timestamp is NOT counted and is reported as UNPARSED on stderr; P8 since=0 -> no filtering. ALERTING drives the REAL _tunnel_maybe_alert (core/nftban_tunnel.sh): A1 the first HIGH alert is sent, a second within NFTBAN_TUNNEL_ALERT_COOLDOWN is suppressed, one after the cooldown is sent: the cooldown, not since, suppresses repeated alerts. The link between the two (a scan with 0 parsed records returns before scoring/alerting) is cited from nftban_tunnel.sh, not driven here. Not covered: the overlap/gap of the fixed 5-min window vs the timer's 4-6 min spacing (a design residual). Set TUN_SINCE_SUBJECT_ROOT to an older tree (e.g. origin/main 7d8381b8): P1-P3 and P5-P7 FAIL there."
# meta:inventory.files="cli/lib/nftban/core/nftban_tunnel_parsers.sh,cli/lib/nftban/core/nftban_tunnel.sh"
# meta:inventory.binaries="bash,gawk,date,mktemp"
# meta:inventory.env_vars="TUN_SINCE_SUBJECT_ROOT"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# meta:ta.id="tunnel_dns_since_window_v1235_test"
# meta:ta.owner="tunnel"
# meta:ta.module="tunnel-dns-parsers"
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
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../../../.." && pwd)"
ROOT="${TUN_SINCE_SUBJECT_ROOT:-$REPO}"
LIB="$ROOT/cli/lib/nftban"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

echo "=== v1.235: tunnel DNS parsers honour the scan window ==="
command -v gawk >/dev/null 2>&1 || { echo "  NOT_EXECUTED: gawk not installed"; echo "RESULT: NOT_EXECUTED"; exit 3; }
[[ -f "$LIB/core/nftban_tunnel_parsers.sh" && -f "$LIB/core/nftban_tunnel.sh" ]] \
    || { echo "  NOT_EXECUTED: subject files missing under $ROOT"; echo "RESULT: NOT_EXECUTED"; exit 3; }

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
export LC_ALL=C TZ=UTC
T=1790000000                       # fixed clock for formats that carry a year

bind_line()   { printf '%s queries: info: client @0x7f 192.0.2.%s#5353 (q%s.example.com): query: q%s.example.com IN TXT +E(0) (198.51.100.1)\n' "$(date -u -d "@$1" '+%d-%b-%Y %H:%M:%S.000')" "$2" "$2" "$2"; }
unb_line()    { printf '[%s] unbound[1234:0] info: 192.0.2.%s q%s.example.com. TXT IN\n' "$1" "$2" "$2"; }
dnsq_iso()    { printf '%s host dnsmasq[77]: query[TXT] q%s.example.com from 192.0.2.%s\n' "$1" "$2" "$2"; }
dnsq_syslog() { printf '%s host dnsmasq[77]: query[TXT] q%s.example.com from 192.0.2.%s\n' "$(date -d "@$1" '+%b %e %H:%M:%S')" "$2" "$2"; }

# parse <fn> <file> <since> -> record count on stdout; stderr kept in $SB/err
parse() {
    env -i PATH="/usr/bin:/bin" LC_ALL=C TZ=UTC bash -c 'source "$1"; "$2" "$3" "$4"' _ \
        "$LIB/core/nftban_tunnel_parsers.sh" "$1" "$2" "$3" 2>"$SB/err" | grep -c . || true
}

# --- BIND
{ bind_line $((T-60)) 1; bind_line $((T-120)) 2; bind_line $((T-200)) 3
  for i in 4 5 6 7; do bind_line $((T-3600)) "$i"; done; } > "$SB/bind.log"
n=$(parse nftban_tunnel_parse_bind "$SB/bind.log" $((T-300)))
[[ "$n" == 3 ]] && ok "P1 BIND: 3 lines in [T-300,T], 4 older -> 3 counted" || no "P1 BIND window" "counted=$n (expected 3)"
n=$(parse nftban_tunnel_parse_bind "$SB/bind.log" "$T")
[[ "$n" == 0 ]] && ok "P2 next run (since=T), no new lines -> 0 counted (the lines of [T-300,T) are not counted again)" || no "P2 next run" "counted=$n (expected 0)"

# --- unbound [epoch] + boundary
{ unb_line $((T-300)) 1; unb_line $((T-301)) 2; unb_line $((T-10)) 3; } > "$SB/unb.log"
n=$(parse nftban_tunnel_parse_unbound "$SB/unb.log" $((T-300)))
[[ "$n" == 2 ]] && ok "P3 boundary: line at exactly since is IN, since-1 is OUT (2 of 3)" || no "P3 boundary" "counted=$n (expected 2)"
n=$(parse nftban_tunnel_parse_unbound "$SB/unb.log" $((T-20)))
[[ "$n" == 1 ]] && ok "P4 unbound [epoch]: only the line after since counted" || no "P4 unbound epoch" "counted=$n (expected 1)"

# --- dnsmasq RFC3339 with an offset: 12:00:00+02:00 == 10:00:00Z
ten=$(date -u -d '2026-10-07 10:00:00' +%s)
{ dnsq_iso '2026-10-07T12:00:00.123456+02:00' 1; dnsq_iso '2026-10-07T11:59:00+02:00' 2; } > "$SB/dnsq_iso.log"
n=$(parse nftban_tunnel_parse_dnsmasq "$SB/dnsq_iso.log" "$ten")
[[ "$n" == 1 ]] && ok "P5 RFC3339 offset honoured (12:00+02:00 = 10:00Z in, 11:59+02:00 out)" || no "P5 RFC3339 offset" "counted=$n (expected 1)"

# --- dnsmasq traditional syslog (no year), times relative to now
now=$(date +%s)
{ dnsq_syslog $((now-60)) 1; dnsq_syslog $((now-3600)) 2; } > "$SB/dnsq_sys.log"
n=$(parse nftban_tunnel_parse_dnsmasq "$SB/dnsq_sys.log" $((now-300)))
[[ "$n" == 1 ]] && ok "P6 syslog without year: recent line in, 1h-old line out" || no "P6 syslog" "counted=$n (expected 1)"

# --- unparsed timestamp
{ unb_line $((T-10)) 1; echo 'unbound[1234:0] info: 192.0.2.9 q9.example.com. TXT IN'; } > "$SB/unb_bad.log"
n=$(parse nftban_tunnel_parse_unbound "$SB/unb_bad.log" $((T-300)))
if [[ "$n" == 1 ]] && grep -q '^UNPARSED 1 ' "$SB/err"; then ok "P7 unreadable timestamp: not counted, reported as UNPARSED on stderr"
else no "P7 unparsed handling" "counted=$n stderr=$(tr '\n' ' ' < "$SB/err")"; fi

# --- since=0: no filtering
n=$(parse nftban_tunnel_parse_bind "$SB/bind.log" 0)
[[ "$n" == 7 ]] && ok "P8 since=0 -> no filtering (all 7)" || no "P8 since=0" "counted=$n (expected 7)"

# --- ALERTING (separate from counting): the cooldown decides repeated alerts
mkdir -p "$SB/state" "$SB/etc"
alerts=$(env -i PATH="/usr/bin:/bin" LC_ALL=C SBX="$SB" NFTBAN_LIB_DIR="$LIB/.." NFTBAN_CONFIG_DIR="$SB/etc" \
    NFTBAN_TUNNEL_STATE_DIR="$SB/state" NFTBAN_TUNNEL_ALERT_COOLDOWN=3600 bash -c '
        set +e
        nftban_mail_alert() { echo sent >> "$SBX/mail"; }
        source "$1" >/dev/null 2>&1
        T=1790000000
        _tunnel_maybe_alert 1 "$T"; _tunnel_maybe_alert 1 $((T+300)); _tunnel_maybe_alert 1 $((T+3700))
        grep -c sent "$SBX/mail" 2>/dev/null || echo 0
    ' _ "$LIB/core/nftban_tunnel.sh")
[[ "$alerts" == 2 ]] && ok "A1 alert at T sent, at T+300 suppressed (cooldown), at T+3700 sent again" || no "A1 cooldown" "alerts=$alerts (expected 2)"

echo ""
echo "RESULT: $([[ $FAIL -eq 0 ]] && echo PASS || echo FAIL) (pass=$PASS fail=$FAIL)"
[[ $FAIL -eq 0 ]]
