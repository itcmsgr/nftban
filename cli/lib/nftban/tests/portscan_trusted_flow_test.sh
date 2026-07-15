#!/usr/bin/env bash
# shellcheck disable=SC1090
# =============================================================================
# NFTBan - Portscan Trusted-Monitoring-Flow Exclusion test
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="portscan_trusted_flow_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-15"
# meta:description="Locks the portscan trusted-monitoring-flow exclusion: shell-emit suppression of an exactly-declared, within-rate trusted flow tuple only; exact-match (v4/v6/dst-host/counter-once), negatives (wrong port/multi-port/wrong proto/wrong dst/over-rate/outside-CIDR/empty/malformed-fail-safe/duplicate+overlap-rejected), fixed 60s rate window (over-rate stays visible + spools), parser rejects (0.0.0.0/0, ::/0, wildcard src/proto/port/rate, port 0/ranges/all, unsupported proto, malformed CIDR, unsafe chars, extra columns), counters (declarations/suppressed_total/suppressed_by_rule/over_rate_total/parse_errors), render never silent, config parsed-never-sourced, hooked into classic process_logs before emit+record, 0 Go / firewall+ban+whitelist+classifier unchanged."
# meta:input="the trusted-flow module + synthetic configs + classic.sh/portscan.sh wiring"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,awk,grep,date,flock"
# meta:inventory.files="cli/lib/nftban/core/nftban_portscan_trusted_flow.sh,cli/lib/nftban/core/nftban_portscan_classic.sh,cli/lib/nftban/core/nftban_portscan.sh"
# meta:inventory.binaries="bash,awk,grep,date"
# meta:inventory.env_vars="NFTBAN_PORTSCAN_TRUSTED_FLOWS_FILE,NFTBAN_PTF_STATE_FILE"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
set +eE

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ -f "$SCRIPT_DIR/../core/nftban_portscan_trusted_flow.sh" ]]; then
    LIB="$(cd "$SCRIPT_DIR/.." && pwd)"
else
    LIB="$(cd "$SCRIPT_DIR/../../../.." && pwd)/cli/lib/nftban"
fi
MOD="$LIB/core/nftban_portscan_trusted_flow.sh"
CLASSIC="$LIB/core/nftban_portscan_classic.sh"
PORTSCAN="$LIB/core/nftban_portscan.sh"

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); FAILED+=("$1"); }
eq(){ [ "$1" = "$2" ] && ok "$3" || no "$3 (want [$1] got [$2])"; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export NFTBAN_PORTSCAN_TRUSTED_FLOWS_FILE="$WORK/tf.conf"
export NFTBAN_PTF_STATE_FILE="$WORK/tf.state"

# helper: run one suppress decision in a clean sourced env
sup(){ ( source "$MOD" 2>/dev/null; set +eE; nftban_portscan_trusted_flow_suppress "$1" "$2" "$3" "$4"; echo $?; ) | tail -1; }
reset_state(){ rm -f "$NFTBAN_PTF_STATE_FILE"* 2>/dev/null; }

echo "=== portscan trusted-flow exclusion ==="

# --------------------------------------------------------------------------
# A — exact-match suppression (v4, v6, dst-host), counter increments once
# --------------------------------------------------------------------------
reset_state
cat > "$NFTBAN_PORTSCAN_TRUSTED_FLOWS_FILE" <<'EOF'
2001:db8:c014:5ee1::1/128|tcp|10050|*|30/min
192.0.2.10/32|tcp|10050|192.0.2.20|30/min
198.51.100.0/24|udp|161|*|30/min
EOF
outA="$( source "$MOD" 2>/dev/null; set +eE
  nftban_portscan_trusted_flow_load
  echo "DECL=$_PTF_DECLARATIONS"
  nftban_portscan_trusted_flow_suppress 2001:db8:c014:5ee1::1 fe80::9 10050 tcp; echo "V6=$?"
  nftban_portscan_trusted_flow_suppress 192.0.2.10 192.0.2.20 10050 tcp; echo "V4=$?"
  nftban_portscan_trusted_flow_suppress 198.51.100.77 10.0.0.5 161 udp; echo "V4CIDR=$?"
  echo "TOT=$(_ptf_state_get trusted_flow_suppressed_total)"
)"
g(){ printf '%s\n' "$outA" | sed -n "s/^$1=//p"; }
eq "3" "$(g DECL)" "A1 three valid declarations loaded"
eq "0" "$(g V6)"   "A2 exact IPv6 flow suppressed"
eq "0" "$(g V4)"   "A3 IPv4 /32 + exact dst-host suppressed"
eq "0" "$(g V4CIDR)" "A4 IPv4 /24 CIDR + udp/161 suppressed"
eq "3" "$(g TOT)"  "A5 suppressed_total incremented once per suppressed event (3)"

# --------------------------------------------------------------------------
# A6 — exact IPv6 destination is NOTATION-ROBUST: the kernel/parse_line dst arrives
# EXPANDED (2001:0db8:...:0001) while a config uses compressed (2001:db8:...::1),
# and /128 on the destination selector is accepted (normalised to the bare IP).
# --------------------------------------------------------------------------
reset_state
printf '2001:db8:c014:5ee1::1/128|tcp|10050|2001:db8:c014:f4da::1/128|120/min\n' > "$NFTBAN_PORTSCAN_TRUSTED_FLOWS_FILE"
out6="$( source "$MOD" 2>/dev/null; set +eE
  nftban_portscan_trusted_flow_load
  echo "DECL=$_PTF_DECLARATIONS PERR=$_PTF_PARSE_ERRORS DST=${_PTF_DST[0]}"
  nftban_portscan_trusted_flow_suppress 2001:0db8:c014:5ee1:0000:0000:0000:0001 2001:0db8:c014:f4da:0000:0000:0000:0001 10050 tcp; echo "EXP=$?"
  nftban_portscan_trusted_flow_suppress 2001:db8:c014:5ee1::1 2001:db8:c014:f4da::1 10050 tcp; echo "CMP=$?"
  nftban_portscan_trusted_flow_suppress 2001:0db8:c014:5ee1:0000:0000:0000:0001 2001:0db8:c014:ffff:0000:0000:0000:0009 10050 tcp; echo "WRONG=$?" )"
k(){ printf '%s\n' "$out6" | sed -n "s/^$1=//p"; }
eq "DECL=1 PERR=0 DST=2001:db8:c014:f4da::1" "$(printf '%s\n' "$out6"|grep -E '^DECL=')" "A6a /128 destination accepted + normalised to bare IP, parses clean"
eq "0" "$(k EXP)" "A6b exact IPv6 dst matches EXPANDED runtime notation (kernel-log form) → suppressed"
eq "0" "$(k CMP)" "A6c exact IPv6 dst matches COMPRESSED runtime notation → suppressed"
eq "1" "$(k WRONG)" "A6d different IPv6 dst → VISIBLE"

# --------------------------------------------------------------------------
# B — negatives: every mismatch generates the event (return 1 = VISIBLE)
# --------------------------------------------------------------------------
reset_state
printf '192.0.2.10/32|tcp|10050|192.0.2.20|30/min\n' > "$NFTBAN_PORTSCAN_TRUSTED_FLOWS_FILE"
eq "1" "$(sup 192.0.2.10 192.0.2.99 10050 tcp)" "B1 wrong destination → VISIBLE"
eq "1" "$(sup 192.0.2.10 192.0.2.20 22    tcp)" "B2 wrong destination port → VISIBLE"
eq "1" "$(sup 192.0.2.10 192.0.2.20 3306  tcp)" "B3 second (fan-out) port → VISIBLE"
eq "1" "$(sup 192.0.2.10 192.0.2.20 10050 udp)" "B4 wrong protocol → VISIBLE"
eq "1" "$(sup 203.0.113.9 192.0.2.20 10050 tcp)" "B5 source outside CIDR → VISIBLE"

# --------------------------------------------------------------------------
# C — fixed 60s rate window: over-rate stays visible AND is counted
# --------------------------------------------------------------------------
reset_state
printf '10.10.10.10/32|tcp|10050|*|3/min\n' > "$NFTBAN_PORTSCAN_TRUSTED_FLOWS_FILE"
outC="$( source "$MOD" 2>/dev/null; set +eE
  nftban_portscan_trusted_flow_load
  r=""
  for _ in 1 2 3 4 5; do nftban_portscan_trusted_flow_suppress 10.10.10.10 10.0.0.1 10050 tcp; r="$r$?"; done
  echo "SEQ=$r"
  echo "SUP=$(_ptf_state_get trusted_flow_suppressed_total)"
  echo "OVR=$(_ptf_state_get trusted_flow_over_rate_total)"
)"
h(){ printf '%s\n' "$outC" | sed -n "s/^$1=//p"; }
eq "00011" "$(h SEQ)" "C1 first 3 suppressed (0), 4th/5th over-rate visible (1) within 60s window"
eq "3" "$(h SUP)" "C2 exactly 3 suppressed under a 3/min bound"
eq "2" "$(h OVR)" "C3 over_rate_total counts the 2 visible-over-bound events"

# --------------------------------------------------------------------------
# D — parser rejects (fail-safe: bad rows skipped + counted, never suppress)
# --------------------------------------------------------------------------
reset_state
cat > "$NFTBAN_PORTSCAN_TRUSTED_FLOWS_FILE" <<'EOF'
0.0.0.0/0|tcp|10050|*|5/min
::/0|tcp|10050|*|5/min
*|tcp|10050|*|5/min
10.0.0.0/8|icmp|10050|*|5/min
10.0.0.0/8|sctp|10050|*|5/min
10.0.0.0/8|tcp|0|*|5/min
10.0.0.0/8|tcp|70000|*|5/min
10.0.0.0/8|tcp|10050-10060|*|5/min
10.0.0.0/8|tcp|*|*|5/min
10.0.0.0/8|tcp|10050|*|0/min
10.0.0.0/8|tcp|10050|*|-5/min
10.0.0.0/8|tcp|10050|*|9999
10.0.0.0/8|tcp|10050|*|unlimited
10.0.0.999/8|tcp|10050|*|5/min
10.0.0.0/8|tcp|10050|eth0|5/min
10.0.0.0/8|tcp|10050|*|5/min|extra
10.0.0.0/8|tcp|10050|*|5/min;rm -rf /
EOF
outD="$( source "$MOD" 2>/dev/null; set +eE; nftban_portscan_trusted_flow_load 2>/dev/null
  echo "DECL=$_PTF_DECLARATIONS PERR=$_PTF_PARSE_ERRORS" )"
eq "DECL=0 PERR=17" "$outD" "D1 all 17 invalid rows rejected, 0 declarations (fail-safe)"
reset_state
printf '0.0.0.0/0|tcp|10050|*|5/min\n' > "$NFTBAN_PORTSCAN_TRUSTED_FLOWS_FILE"
eq "1" "$(sup 8.8.8.8 1.1.1.1 10050 tcp)" "D2 a rejected any-source row suppresses NOTHING"

# --------------------------------------------------------------------------
# E — duplicate + overlapping(same src+proto+port) rejection
# --------------------------------------------------------------------------
reset_state
cat > "$NFTBAN_PORTSCAN_TRUSTED_FLOWS_FILE" <<'EOF'
192.0.2.10/32|tcp|10050|192.0.2.20|5/min
192.0.2.10/32|tcp|10050|192.0.2.20|9/min
192.0.2.10/32|tcp|10050|192.0.2.99|5/min
EOF
outE="$( source "$MOD" 2>/dev/null; set +eE; nftban_portscan_trusted_flow_load 2>/dev/null
  echo "DECL=$_PTF_DECLARATIONS PERR=$_PTF_PARSE_ERRORS" )"
eq "DECL=1 PERR=2" "$outE" "E1 duplicate + ambiguous-overlap rows rejected (1 kept, 2 rejected)"

# --------------------------------------------------------------------------
# F — empty / absent config changes nothing (default opt-in)
# --------------------------------------------------------------------------
reset_state; : > "$NFTBAN_PORTSCAN_TRUSTED_FLOWS_FILE"
eq "1" "$(sup 192.0.2.10 192.0.2.20 10050 tcp)" "F1 empty config → nothing suppressed"
reset_state; rm -f "$NFTBAN_PORTSCAN_TRUSTED_FLOWS_FILE"
eq "1" "$(sup 192.0.2.10 192.0.2.20 10050 tcp)" "F2 absent config → nothing suppressed"

# --------------------------------------------------------------------------
# G — render never silent + validate rc
# --------------------------------------------------------------------------
reset_state
printf '192.0.2.10/32|tcp|10050|*|5/min\n' > "$NFTBAN_PORTSCAN_TRUSTED_FLOWS_FILE"
REP="$( source "$MOD" 2>/dev/null; set +eE; nftban_portscan_trusted_flow_render )"
{ echo "$REP"|grep -q 'trusted_flow_declarations' && echo "$REP"|grep -q 'trusted_flow_over_rate_total' \
  && echo "$REP"|grep -q 'firewall & ban authority unchanged'; } && ok "G1 render exposes counters + states event-gen-only/no-ban" || no "G1 render"
( source "$MOD" 2>/dev/null; set +eE; nftban_portscan_trusted_flow_validate >/dev/null 2>&1 ); eq "0" "$?" "G2 validate rc0 on valid config"
printf 'bad|row\n' > "$NFTBAN_PORTSCAN_TRUSTED_FLOWS_FILE"
( source "$MOD" 2>/dev/null; set +eE; nftban_portscan_trusted_flow_validate >/dev/null 2>&1 ); eq "1" "$?" "G3 validate rc1 on invalid config"

# --------------------------------------------------------------------------
# H — structural invariants (0 Go, no firewall/ban/whitelist/classifier change,
#     parsed-not-sourced, hooked before emit+record, empty default ship)
# --------------------------------------------------------------------------
# actual (non-comment) code must not source/eval the config
CODE="$(grep -vE '^[[:space:]]*#' "$MOD")"
printf '%s\n' "$CODE" | grep -qE '(^|[^_[:alnum:]])(eval)[[:space:]]|(^|[[:space:]])(source|\.)[[:space:]]+[^;]*(TRUSTED_FLOWS|trusted-flows)' \
  && no "H1 config sourced/evaled" || ok "H1 config parsed, never sourced/evaled"
# suppress hook sits AFTER whitelist and BEFORE emit+record in classic process_logs
if grep -q 'nftban_portscan_trusted_flow_suppress' "$CLASSIC"; then
  n=$(grep -c 'nftban_portscan_trusted_flow_suppress "\$src_ip"' "$CLASSIC")
  eq "2" "$n" "H2 emit filter wired into both process_logs paths (journalctl + file)"
else no "H2 not wired"; fi
# a suppressed flow reaches neither emit nor record (the continue precedes both)
awk '/trusted_flow_suppress/{f=1} f&&/_nftban_portscan_emit_event/{print "EMIT_AFTER"; exit}' "$CLASSIC" | grep -q EMIT_AFTER \
  && ok "H3 suppress continue precedes emit_event + record_connection (no event, no spool)" || no "H3 ordering"
grep -q 'nftban_portscan_trusted_flow' "$PORTSCAN" && ok "H4 module sourced by portscan.sh + status render wired" || no "H4 not sourced"
# no firewall/ban/whitelist/nft MUTATION in actual (non-comment) code
printf '%s\n' "$CODE" | grep -qiE 'nft[[:space:]]+(add|delete|flush|insert)|nftban_(un)?ban|AddIPWithTimeout|blacklist_(v4|v6|manual)|whitelist_(v4|v6)' \
  && no "H5 module mutates firewall/ban/whitelist" || ok "H5 module does NOT touch firewall/ban/whitelist"
# example config ships; live default absent
[ -f "$LIB/../../../etc/nftban/conf.d/portscan/trusted-flows.conf.example" ] && ok "H6 example template ships" || no "H6 example missing"
[ ! -f "$LIB/../../../etc/nftban/conf.d/portscan/trusted-flows.conf" ] && ok "H7 live config ships ABSENT (empty/opt-in default)" || no "H7 live config should not ship"

# --------------------------------------------------------------------------
# I — set -Eeuo pipefail safety: repeated calls don't error/hang
# --------------------------------------------------------------------------
reset_state
printf '10.0.0.0/8|tcp|10050|*|1000/min\n' > "$NFTBAN_PORTSCAN_TRUSTED_FLOWS_FILE"
outI="$( set -Eeuo pipefail; source "$MOD" 2>/dev/null; set +e
  nftban_portscan_trusted_flow_load
  for _ in $(seq 1 20); do nftban_portscan_trusted_flow_suppress 10.1.2.3 10.0.0.1 10050 tcp >/dev/null 2>&1; done
  echo "SUP=$(_ptf_state_get trusted_flow_suppressed_total)"; echo DONE )"
case "$outI" in *DONE*) ok "I1 20 repeated suppress calls complete under strict mode (no hang/error)";; *) no "I1 repeated calls";; esac
eq "SUP=20" "$(printf '%s\n' "$outI" | sed -n 's/^\(SUP=[0-9]*\)$/\1/p')" "I2 high-volume matching (under bound) all suppressed → no spool entries"

echo "─────────────────────────────────────────────"
printf 'RESULTS: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -ne 0 ] && { printf 'FAILED:\n'; printf '  - %s\n' "${FAILED[@]}"; exit 1; }
echo "ALL PASS"; exit 0
