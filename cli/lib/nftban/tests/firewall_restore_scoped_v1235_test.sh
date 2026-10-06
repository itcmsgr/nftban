#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.235 - `firewall restore <file>` applies only the nftban tables
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="firewall_restore_scoped_v1235_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-05"
# meta:description="RESTORE-FROM-FILE-FLUSHES-FOREIGN-TABLES (v1.235 A1). `nftban firewall restore <file>` ran `nft flush ruleset` and then `nft -f` on the whole backup: every live foreign table (Docker nat/filter, ip raw, operator, panel) was destroyed, stale foreign tables from the backup came back, and any nft command in the file ran. Drives the REAL _restore_from_file (extracted from cmd_firewall.sh) against a recording nft/systemctl mock. Arms: R1 a backup with foreign tables + both nftban tables -> exactly one `nft -c -f` and one `nft -f` on the SAME file, which holds only the two nftban tables in the create/delete/define shape, and no flush; R2 the rejection set (top-level flush, include, add rule, unbalanced braces, unbalanced quote, define inside an nftban table, \$variable, only ip nftban, duplicate ip nftban, unterminated block) -> refused with ZERO nft calls and services untouched; R3 validation failure -> no apply and services untouched; R4 braces/hash/dollar inside quoted rule comments are not counted; R5 the restore body carries no `nft flush ruleset`. R1, R2, R5 FAIL on e79a1173 (flush + whole-file load)."
# meta:inventory.files="firewall_restore_scoped_v1235_test.sh"
# meta:inventory.binaries="bash,awk,sed,mktemp,cmp"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# meta:ta.id="firewall_restore_scoped_v1235_test"
# meta:ta.owner="firewall"
# meta:ta.module="firewall-restore"
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
FW="${A1_SUBJECT_ROOT:-$REPO}/cli/lib/nftban/cli/cmd_firewall.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

echo "=== v1.235 A1: scoped firewall restore ==="
[[ -f "$FW" ]] || { echo "  NOT_EXECUTED: subject not found: $FW"; echo "RESULT: NOT_EXECUTED"; exit 3; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ---- extract the REAL functions (whole bodies, by brace-free top-level markers) ----
FNS="$WORK/fns.sh"
: > "$FNS"
for fn in _restore_extract_nftban_txn _restore_from_file; do
    body="$(sed -n "/^${fn}() {/,/^}/p" "$FW")"
    [[ -n "$body" ]] && printf '%s\n' "$body" >> "$FNS"
done
grep -q '^_restore_from_file() {' "$FNS" || { echo "  NOT_EXECUTED: _restore_from_file not found in subject"; echo "RESULT: NOT_EXECUTED"; exit 3; }

# ---- recording mocks: nft and systemctl as functions (defined after sourcing) -----
LOG="$WORK/calls.log"; APPLIED="$WORK/applied"; mkdir -p "$APPLIED"
NFT_CHECK_RC=0
nft(){
    local i=0 a next
    local -a args=("$@")
    # Log with explicit single spaces: under IFS=$'\n\t' "$*" would join with newlines.
    { printf 'nft'; printf ' %s' "$@"; printf '\n'; } >> "$LOG"
    for a in "$@"; do
        i=$((i+1))
        if [[ "$a" == "-f" ]]; then
            next="${args[i]:-}"   # i is the 1-based position of -f; args[i] is the next argument
            [[ -f "$next" ]] && cp "$next" "$APPLIED/$(wc -l < "$LOG" | tr -d ' ').nft"
        fi
    done
    if [[ "$1" == "-c" ]]; then return "$NFT_CHECK_RC"; fi
    return 0
}
systemctl(){ { printf 'systemctl'; printf ' %s' "$@"; printf '\n'; } >> "$LOG"; return 0; }
# shellcheck source=/dev/null
source "$FNS"

reset_log(){ : > "$LOG"; rm -f "$APPLIED"/*.nft; }
count(){ local n; n=$(grep -c -- "$1" "$LOG" 2>/dev/null) || n=0; printf '%s' "$n"; }

run_restore(){ local rc=0; _restore_from_file "$1" > "$WORK/out" 2>&1 || rc=$?; return $rc; }

# ---- fixtures -------------------------------------------------------------------
NFTBAN_V4='table ip nftban {
	set whitelist_ipv4 {
		type ipv4_addr
		flags interval
		elements = { 192.0.2.10 }
	}
	chain input {
		type filter hook input priority filter; policy drop;
		iif "lo" accept
		ip saddr @whitelist_ipv4 accept comment "trusted { not a brace } # not a comment $not_a_var"
	}
	chain forward {
		type filter hook forward priority filter; policy drop;
	}
}'
NFTBAN_V6='table ip6 nftban {
	chain input {
		type filter hook input priority filter; policy drop;
		iif "lo" accept
	}
}'
FOREIGN='table ip nat {
	chain DOCKER {
		iifname != "br-938df9175c79" tcp dport 5432 dnat to 172.18.0.3:5432
	}
}
table ip raw {
	chain PREROUTING {
		type filter hook prerouting priority raw; policy accept;
		ip daddr 172.18.0.2 iifname != "br-938df9175c79" drop
	}
}
table inet ops {
	chain c {
		type filter hook input priority 10; policy accept;
	}
}'
mk(){ printf '%s\n' "$2" > "$WORK/$1.nft"; printf '%s' "$WORK/$1.nft"; }

# ---- R1 · full backup: only nftban tables, one validate + one load, same file, no flush ----
reset_log; NFT_CHECK_RC=0
B="$(mk full "# backup
$FOREIGN
$NFTBAN_V4
$NFTBAN_V6")"
r1_rc=0; run_restore "$B" || r1_rc=$?
n_check=$(count '^nft -c -f '); n_load=$(count '^nft -f '); n_flush=$(count 'flush ruleset')
if [[ "$r1_rc" -eq 0 && "$n_check" -eq 1 && "$n_load" -eq 1 && "$n_flush" -eq 0 ]]; then
    ok "R1 one 'nft -c -f' + one 'nft -f', no 'flush ruleset' (rc=0)"
else
    no "R1 restore did not run exactly validate+load without flush" "rc=$r1_rc check=$n_check load=$n_load flush=$n_flush"
fi
chk_file=$(grep -m1 '^nft -c -f ' "$LOG" | sed 's/^nft -c -f //' || true)
load_file=$(grep -m1 '^nft -f ' "$LOG" | sed 's/^nft -f //' || true)
if [[ -n "$chk_file" && "$chk_file" == "$load_file" && "$load_file" != "$B" ]]; then
    ok "R1 the validated file IS the loaded file, and it is not the raw backup"
else
    no "R1 validated and loaded files differ, or the raw backup was loaded" "check=$chk_file load=$load_file backup=$B"
fi
applied=""
for f in "$APPLIED"/*.nft; do [[ -e "$f" ]] && applied="$f"; done
if [[ -n "$applied" ]]; then
    body="$(cat "$applied")"
    if [[ "$body" != *"table ip nat"* && "$body" != *"table ip raw"* && "$body" != *"table inet ops"* && "$body" != *"flush"* ]]; then
        ok "R1 applied transaction contains no foreign table and no flush"
    else
        no "R1 applied transaction carries foreign tables or a flush"
    fi
    first4="$(sed -n '1,2p' "$applied")"
    if [[ "$first4" == $'table ip nftban {}\ndelete table ip nftban' && "$body" == *$'table ip6 nftban {}\ndelete table ip6 nftban'* && "$body" == *"set whitelist_ipv4"* && "$body" == *"chain forward"* ]]; then
        ok "R1 transaction shape: create/delete/define for ip and ip6, nftban content intact"
    else
        no "R1 transaction shape wrong" "head=${first4//$'\n'/ | }"
    fi
else
    no "R1 no applied transaction was captured"
fi

# ---- R2 · rejection set: refused, ZERO nft calls, services untouched ----------
reject(){ # <name> <content> <label>
    reset_log
    local f rc=0
    f="$(mk "$1" "$2")"
    run_restore "$f" || rc=$?
    local n_nft n_sys
    n_nft=$(count '^nft '); n_sys=$(count '^systemctl ')
    if [[ "$rc" -ne 0 && "$n_nft" -eq 0 && "$n_sys" -eq 0 ]]; then
        ok "R2 refused with zero nft calls: $3"
    else
        no "R2 not refused cleanly: $3" "rc=$rc nft_calls=$n_nft systemctl_calls=$n_sys"
    fi
}
reject top_flush   "flush ruleset
$NFTBAN_V4
$NFTBAN_V6"                                                        "top-level flush ruleset"
reject top_include "include \"/etc/x.nft\"
$NFTBAN_V4
$NFTBAN_V6"                                                        "top-level include"
reject top_add     "$NFTBAN_V4
$NFTBAN_V6
add rule ip nftban input drop"                                     "top-level add rule"
reject unbal_brace "$NFTBAN_V6
table ip nftban {
	chain input {
		type filter hook input priority filter; policy drop;
	}"                                                             "unbalanced braces / unterminated block"
reject unbal_quote "$NFTBAN_V6
table ip nftban {
	chain input {
		type filter hook input priority filter; policy drop;
		accept comment \"open
	}
}"                                                                 "unbalanced quote"
reject inner_define "$NFTBAN_V6
table ip nftban {
	define X = 1
}"                                                                 "define inside an nftban table"
reject inner_var   "$NFTBAN_V6
table ip nftban {
	chain input {
		type filter hook input priority filter; policy drop;
		ip saddr \$TRUSTED accept
	}
}"                                                                 "\$variable inside an nftban table"
reject only_v4     "$FOREIGN
$NFTBAN_V4"                                                        "only ip nftban present"
reject dup_v4      "$NFTBAN_V4
$NFTBAN_V4
$NFTBAN_V6"                                                        "duplicate table ip nftban"

# ---- R3 · validation failure: no apply, services untouched --------------------
reset_log; NFT_CHECK_RC=1
B3="$(mk val "$NFTBAN_V4
$NFTBAN_V6")"
r3_rc=0; run_restore "$B3" || r3_rc=$?
NFT_CHECK_RC=0
if [[ "$r3_rc" -ne 0 && $(count '^nft -c -f ') -eq 1 && $(count '^nft -f ') -eq 0 && $(count '^systemctl ') -eq 0 ]]; then
    ok "R3 failed validation: nothing applied, services not stopped"
else
    no "R3 validation failure still applied or touched services" "rc=$r3_rc"
fi

# ---- R4 · quoted braces/#/\$ inside a rule comment do not break the parse --------
# (covered by the NFTBAN_V4 fixture in R1: comment "trusted { not a brace } # … \$not_a_var")
if [[ "$r1_rc" -eq 0 ]]; then
    ok "R4 braces, '#' and '\$' inside a quoted comment were not counted (R1 accepted)"
else
    no "R4 quoted comment content broke the parse (R1 refused)"
fi

# ---- R5 · static: the restore body has no global flush ----------------------------
rbody="$(sed -n '/^_restore_from_file() {/,/^}/p' "$FW")"
if [[ "$rbody" == *"nft flush ruleset"* ]]; then
    no "R5 _restore_from_file still runs 'nft flush ruleset'"
else
    ok "R5 _restore_from_file has no 'nft flush ruleset'"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -eq 0 ]]; then echo "RESULT: PASS"; exit 0; fi
echo "RESULT: FAIL"; exit 1
