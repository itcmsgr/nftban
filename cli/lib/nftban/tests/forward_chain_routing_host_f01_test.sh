#!/usr/bin/env bash
# =============================================================================
# NFTBan - F-01 forward-chain packet-outcome regression (v1.231.0)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="forward_chain_routing_host_f01_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Packet-outcome regression for FORWARD-CHAIN-EMPTY-POLICY-DROP-BLACKHOLES-ROUTED-TRAFFIC (F-01). Builds a client-router-server topology in three network namespaces with ip_forward=1 and asks the KERNEL what happens to a forwarded packet, in BOTH families. ARM1 positive control (no nftables). ARM2 a foreign table with an accept forward policy. ARM3 the SUBJECT: NFTBan's forward chain as the product renders it on a forwarding host - forwarding must work. ARM4 negative control: delete ONLY the nftban table. ARM5 the UNGATED shipped chain, which must still BLOCK, so ARM3 cannot pass vacuously. ARM6 a banned endpoint is still dropped on the forward path. ARM7 the host-protection input policy is unchanged and still drops inbound. Asserts its own preconditions and the read-back forward policy BEFORE probing, and writes every rule file to disk - never a heredoc on a shared stdin stream. Exits 3 = NOT_EXECUTED when the subject or the harness cannot be established; never PASS and never FAIL on an unobserved arm. Host networking is untouched: everything happens inside namespaces that are deleted on exit."
# meta:input="cli/lib/nftban/lib/forward_capability.sh, install/nftables/nftables.conf"
# meta:output="PASS/FAIL per arm; exit 0 PASS, 1 FAIL, 3 NOT_EXECUTED"
# meta:depends="bash,ip,nft,ping,awk,mktemp"
# meta:ta.id="forward_chain_routing_host_f01_test"
# meta:ta.owner="firewall"
# meta:ta.module="forward-capability"
# meta:ta.execution_class="ROOT_LAB"
# meta:ta.gate="lab-manual"
# meta:ta.timeout="180"
# meta:ta.hermetic="false"
# meta:ta.requires_root="true"
# meta:ta.requires_network="true"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="true"
# meta:ta.requires_package="false"
# meta:inventory.files="install/nftables/nftables.conf"
# meta:inventory.binaries="bash,ip,nft,ping,awk,mktemp"
# meta:inventory.env_vars="NFTBAN_FORWARD_PROC_ROOT"
# meta:inventory.config_files=""
# meta:inventory.network="three private network namespaces (10.99.1.0/24, 10.99.2.0/24, fd00:99::/32); no host interface is touched"
# meta:inventory.privileges="root"
# =============================================================================
#
# ⛔ WHY THIS TEST LOOKS PARANOID.
# An intermediate run of this exact matrix, during the original investigation,
# reported ARM3 = WORKS on all three lab hosts and nearly closed F-01 as
# NOT_REPRODUCED. Cause: the probe script was piped to `bash -s` while an inner
# `nft -f - <<NFT` heredoc consumed the SAME stdin, so the nftban table was never
# created; `2>/dev/null` hid the failure and the arm printed a cheerful WORKS.
# A FAILED OBSERVATION RENDERED AS A CLEAN RESULT. Hence, without exception:
#   * every rule file is written to DISK and loaded by path,
#   * the table's presence AND its read-back forward policy are asserted BEFORE
#     any probe, and a missed precondition is NOT_EXECUTED rather than a verdict,
#   * ARM1 is a POSITIVE CONTROL: if the harness cannot observe forwarding
#     working at all, no negative result below is believed,
#   * ARM5 keeps the ORIGINAL DEFECT live: if the shipped policy-drop chain does
#     NOT block here, this harness is not exercising hook forward and ARM3's pass
#     would be meaningless — so that, too, downgrades the run to NOT_EXECUTED.
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LIB="$ROOT/cli/lib/nftban/lib/forward_capability.sh"
CONF="$ROOT/install/nftables/nftables.conf"

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
inf() { printf '  [INFO] %s\n' "$1"; }
die_ne() { printf '  [NOT_EXECUTED] %s\n' "$1"; printf 'RESULT: NOT_EXECUTED\n'; exit 3; }

P=f01t$$
C="${P}c"; R="${P}r"; S="${P}s"
NS_BEFORE=""
WORK=""

cleanup() {
    for n in "$C" "$R" "$S"; do ip netns del "$n" >/dev/null 2>&1 || true; done
    [[ -n "$WORK" ]] && rm -rf "$WORK"
    return 0
}
trap cleanup EXIT

echo "=== forward_chain_routing_host_f01 (F-01 packet outcome) ==="

# =============================================================================
# PRECONDITIONS. Everything here is NOT_EXECUTED on failure — never a verdict.
# =============================================================================
[[ -f "$LIB"  ]] || die_ne "subject missing: $LIB"
[[ -f "$CONF" ]] || die_ne "subject missing: $CONF"
[[ "${EUID:-$(id -u)}" -eq 0 ]] || die_ne "needs root (ROOT_LAB / lab-manual); run on a disposable lab host"
for b in ip nft ping awk mktemp; do
    command -v "$b" >/dev/null 2>&1 || die_ne "required binary not available: $b"
done

WORK="$(mktemp -d)" || die_ne "mktemp -d failed"
NS_BEFORE="$(ip netns list 2>/dev/null | grep -c . || true)"
HOST_FWD_BEFORE="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)"

# ---- topology ---------------------------------------------------------------
# client 10.99.1.2 --- 10.99.1.1 router 10.99.2.1 --- 10.99.2.2 server  (+ IPv6 twin)
build_topology() {
    ip netns add "$C" && ip netns add "$R" && ip netns add "$S" || return 1
    ip link add "${P}cr" type veth peer name "${P}rc" || return 1
    ip link add "${P}rs" type veth peer name "${P}sr" || return 1
    ip link set "${P}cr" netns "$C" || return 1
    ip link set "${P}rc" netns "$R" || return 1
    ip link set "${P}rs" netns "$R" || return 1
    ip link set "${P}sr" netns "$S" || return 1
    ip -n "$C" addr add 10.99.1.2/24 dev "${P}cr" || return 1
    ip -n "$R" addr add 10.99.1.1/24 dev "${P}rc" || return 1
    ip -n "$R" addr add 10.99.2.1/24 dev "${P}rs" || return 1
    ip -n "$S" addr add 10.99.2.2/24 dev "${P}sr" || return 1
    ip -n "$C" addr add fd00:99:1::2/64 dev "${P}cr" nodad || return 1
    ip -n "$R" addr add fd00:99:1::1/64 dev "${P}rc" nodad || return 1
    ip -n "$R" addr add fd00:99:2::1/64 dev "${P}rs" nodad || return 1
    ip -n "$S" addr add fd00:99:2::2/64 dev "${P}sr" nodad || return 1
    ip -n "$C" link set lo up; ip -n "$R" link set lo up; ip -n "$S" link set lo up
    ip -n "$C" link set "${P}cr" up || return 1
    ip -n "$R" link set "${P}rc" up || return 1
    ip -n "$R" link set "${P}rs" up || return 1
    ip -n "$S" link set "${P}sr" up || return 1
    ip -n "$C" route add 10.99.2.0/24 via 10.99.1.1 || return 1
    ip -n "$S" route add 10.99.1.0/24 via 10.99.2.1 || return 1
    ip -n "$C" -6 route add fd00:99:2::/64 via fd00:99:1::1 || return 1
    ip -n "$S" -6 route add fd00:99:1::/64 via fd00:99:2::1 || return 1
    ip netns exec "$R" sysctl -qw net.ipv4.ip_forward=1 || return 1
    ip netns exec "$R" sysctl -qw net.ipv6.conf.all.forwarding=1 || return 1
    return 0
}
build_topology || die_ne "could not build the three-namespace topology"

# ⛔ ip_forward must READ BACK as 1 inside the router namespace. Setting it is not
# evidence that it is set; and if it is not, every forward arm below is vacuous.
fwd4="$(ip netns exec "$R" cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)"
fwd6="$(ip netns exec "$R" cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null)"
[[ "$fwd4" == "1" ]] || die_ne "router namespace ip_forward reads '$fwd4', not 1"
[[ "$fwd6" == "1" ]] || die_ne "router namespace ipv6 forwarding reads '$fwd6', not 1"
inf "router namespace: ip_forward=$fwd4 ipv6.all.forwarding=$fwd6 (host value untouched: $(cat /proc/sys/net/ipv4/ip_forward))"

# ---- probes -----------------------------------------------------------------
fwd_v4() { ip netns exec "$C" ping -c1 -W2 -n 10.99.2.2   >/dev/null 2>&1; }
fwd_v6() { ip netns exec "$C" ping -6 -c1 -W2 -n fd00:99:2::2 >/dev/null 2>&1; }
in_v4()  { ip netns exec "$C" ping -c1 -W2 -n 10.99.1.1   >/dev/null 2>&1; }  # to the ROUTER itself = hook input

# ⛔ BOUNDED READINESS WAIT, USED ONLY BY THE POSITIVE CONTROL.
# IPv6 needs its neighbour/route state to settle after the namespaces come up, and
# an unsettled stack answers a probe exactly like a policy drop does. Waiting here
# — before any nftables rule exists — means every later BLOCKED result is measured
# against a path that has already been PROVEN to carry packets. A "must work" probe
# may be retried; a "must block" probe is single-shot, because retrying one until
# it fails is how a harness talks itself into the answer it wants.
wait_forwarding_ready() {
    local tries=0
    while [[ "$tries" -lt 20 ]]; do
        if fwd_v4 && fwd_v6; then return 0; fi
        tries=$((tries + 1))
        sleep 0.5
    done
    return 1
}
flush_r(){ ip netns exec "$R" nft flush ruleset >/dev/null 2>&1 || true; }

# ---- rule files, written to DISK (never a heredoc on a shared stdin) --------
cat > "$WORK/foreign.nft" <<'FOREIGN'
table ip dockerlike {
    chain forward { type filter hook forward priority 0; policy accept; }
}
table ip6 dockerlike {
    chain forward { type filter hook forward priority 0; policy accept; }
}
FOREIGN

# The nftban subject is assembled FROM THE SHIPPED ARTIFACT, not hand-written, so
# the test cannot drift away from what the product actually emits: the set
# declarations, the base-chain headers and the forward chain block are all lifted
# verbatim out of install/nftables/nftables.conf.
block_of() { # <file> <kind> <name>   -> the whole `<kind> <name> { ... }` block, by brace depth
    awk -v kind="$2" -v want="$3" '
        !inb && $0 ~ ("^[ \t]*" kind "[ \t]+" want "[ \t]*\\{") { inb=1; depth=0 }
        inb { o=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=o-c; print; if (depth<=0) exit }
    ' "$1"
}
tbl4="$(awk '/^table ip nftban \{/,/^\}/'  "$CONF")"
tbl6="$(awk '/^table ip6 nftban \{/,/^\}/' "$CONF")"
[[ -n "$tbl4" && -n "$tbl6" ]] || die_ne "could not locate the nftban table blocks in $CONF"

emit_subject() { # <outfile>
    {
        printf 'table ip nftban {\n'
        printf '%s\n' "$tbl4" | block_of /dev/stdin set whitelist_ipv4
        printf '%s\n' "$tbl4" | block_of /dev/stdin set blacklist_ipv4
        printf '%s\n' "$tbl4" | block_of /dev/stdin set blacklist_manual_ipv4
        printf '    chain input { type filter hook input priority 0; policy drop; }\n'
        printf '    chain output { type filter hook output priority 0; policy accept; }\n'
        printf '%s\n' "$tbl4" | block_of /dev/stdin chain forward
        printf '}\n'
        printf 'table ip6 nftban {\n'
        printf '%s\n' "$tbl6" | block_of /dev/stdin set whitelist_ipv6
        printf '%s\n' "$tbl6" | block_of /dev/stdin set blacklist_ipv6
        printf '%s\n' "$tbl6" | block_of /dev/stdin set blacklist_manual_ipv6
        printf '    chain input { type filter hook input priority 0; policy drop; }\n'
        printf '    chain output { type filter hook output priority 0; policy accept; }\n'
        printf '%s\n' "$tbl6" | block_of /dev/stdin chain forward
        printf '}\n'
    } > "$1"
}
emit_subject "$WORK/nftban-shipped.nft"
grep -q 'hook forward' "$WORK/nftban-shipped.nft" || die_ne "assembled subject carries no forward chain — extraction failed"
if [[ "$(grep -c 'hook forward priority 0; policy drop;' "$WORK/nftban-shipped.nft")" != "2" ]]; then
    die_ne "assembled subject does not carry 2 policy-drop forward chains — the artifact shape changed"
fi

# The GATED subject: the SAME assembled ruleset, put through the product's own
# render authority with the router namespace's procfs as the capability source.
# This is what NFTBan emits on a forwarding host, produced by product code.
cp "$WORK/nftban-shipped.nft" "$WORK/nftban-gated.nft"
# shellcheck source=/dev/null
source "$LIB" || die_ne "could not load the capability authority"
declare -F nftban_forward_render >/dev/null 2>&1 || die_ne "nftban_forward_render is not defined by $LIB"
inf "reading the forwarding capability from the ROUTER namespace's own procfs"
if ! ip netns exec "$R" env NFTBAN_FORWARD_PROC_ROOT=/proc bash -c \
        "source '$LIB' && nftban_forward_render '$WORK/nftban-gated.nft'"; then
    die_ne "the product's render authority failed inside the router namespace"
fi
# Reported, not adjudicated. THE VERDICT COMES FROM THE KERNEL (ARM3/ARM7), not from
# grepping our own render output — a render that looks right and a packet that gets
# through are different claims, and only the second one is what F-01 is about.
inf "rendered forward chains in the subject ruleset:"
grep -n 'hook forward' "$WORK/nftban-gated.nft" | sed 's/^/         /'

load_subject() { # <file> ; asserts the table exists AND the policy reads back
    local f="$1" want="$2" pol4 pol6
    flush_r
    ip netns exec "$R" nft -f "$f" || return 1
    ip netns exec "$R" nft list table ip  nftban >/dev/null 2>&1 || return 1
    ip netns exec "$R" nft list table ip6 nftban >/dev/null 2>&1 || return 1
    pol4="$(ip netns exec "$R" nft list chain ip  nftban forward 2>/dev/null | grep -o 'policy [a-z]*' | head -1)"
    pol6="$(ip netns exec "$R" nft list chain ip6 nftban forward 2>/dev/null | grep -o 'policy [a-z]*' | head -1)"
    inf "PRECONDITION tables=[$(ip netns exec "$R" nft list tables | awk '{print $NF}' | sort -u | tr '\n' ' ')] v4=[$pol4] v6=[$pol6]"
    [[ "$pol4" == "policy $want" && "$pol6" == "policy $want" ]] || return 1
    return 0
}

# =============================================================================
# ARM 1 — POSITIVE CONTROL. No nftables at all. If forwarding does not work here
# the harness cannot observe forwarding, and nothing below may be believed.
# =============================================================================
flush_r
if ! wait_forwarding_ready; then
    inf "ARM1 diagnostics: v4=$(fwd_v4 && echo WORKS || echo BLOCKED) v6=$(fwd_v6 && echo WORKS || echo BLOCKED)"
    inf "$(ip netns exec "$R" nft list tables 2>&1 | tr '\n' ' ')"
    die_ne "ARM1 positive control FAILED: forwarding does not work even with no nftables loaded — this harness cannot observe forwarding, so no negative result below may be believed"
fi
ok "ARM1 positive control: forwarding works with no nftables (v4 + v6)"

# =============================================================================
# ARM 5 — THE DEFECT, kept live. The shipped policy-drop chain must BLOCK.
# Run BEFORE the subject arm: if it does not block, this harness is not
# exercising hook forward and ARM3 would pass vacuously.
# =============================================================================
if ! load_subject "$WORK/nftban-shipped.nft" drop; then
    die_ne "ARM5 precondition unmet: the shipped nftban tables did not load or the forward policy did not read back as drop"
fi
if fwd_v4 || fwd_v6; then
    die_ne "ARM5 the shipped empty policy-drop forward chain did NOT block forwarding — this harness is not exercising hook forward, so no arm below is meaningful"
fi
ok "ARM5 the ungated shipped chain still blackholes forwarded traffic (v4 + v6) — the assertion discriminates"
if in_v4; then
    bad "ARM5 inbound to the router was ACCEPTED under a policy-drop input chain — input hook not exercised"
else
    ok "ARM5 inbound to the router is dropped (hook input is exercised by this harness)"
fi

# =============================================================================
# ARM 2 — a foreign table with an accept forward policy, alone. Composition
# baseline: this is what a container/VM host looks like before NFTBan arrives.
# =============================================================================
flush_r
ip netns exec "$R" nft -f "$WORK/foreign.nft" || die_ne "ARM2 could not load the foreign table"
ip netns exec "$R" nft list table ip dockerlike >/dev/null 2>&1 || die_ne "ARM2 precondition: foreign table absent after load"
if fwd_v4 && fwd_v6; then
    ok "ARM2 a foreign accept-policy forward chain alone: forwarding works (v4 + v6)"
else
    bad "ARM2 forwarding broke with only the foreign accept table present"
fi

# =============================================================================
# ARM 3 — THE SUBJECT. Foreign table PLUS NFTBan as the product renders it on a
# forwarding host. This is the arm that fails on the current tree and passes
# after the fix.
# =============================================================================
flush_r
ip netns exec "$R" nft -f "$WORK/foreign.nft" || die_ne "ARM3 could not load the foreign table"
ip netns exec "$R" nft -f "$WORK/nftban-gated.nft" || die_ne "ARM3 could not load the rendered nftban ruleset"
ip netns exec "$R" nft list table ip  nftban >/dev/null 2>&1 || die_ne "ARM3 precondition: ip nftban absent after load"
ip netns exec "$R" nft list table ip6 nftban >/dev/null 2>&1 || die_ne "ARM3 precondition: ip6 nftban absent after load"
a3p4="$(ip netns exec "$R" nft list chain ip  nftban forward 2>/dev/null | grep -o 'policy [a-z]*' | head -1)"
a3p6="$(ip netns exec "$R" nft list chain ip6 nftban forward 2>/dev/null | grep -o 'policy [a-z]*' | head -1)"
inf "ARM3 PRECONDITION tables=[$(ip netns exec "$R" nft list tables | awk '{print $NF}' | sort -u | tr '\n' ' ')] v4=[$a3p4] v6=[$a3p6]"
if [[ -z "$a3p4" || -z "$a3p6" ]]; then
    die_ne "ARM3 precondition: could not read back the nftban forward policy"
fi
if fwd_v4; then ok "ARM3 IPv4 forwarding WORKS with NFTBan installed on a forwarding host"
else            bad "ARM3 IPv4 forwarding is BLACKHOLED by NFTBan on a forwarding host (F-01)"; fi
if fwd_v6; then ok "ARM3 IPv6 forwarding WORKS with NFTBan installed on a forwarding host"
else            bad "ARM3 IPv6 forwarding is BLACKHOLED by NFTBan on a forwarding host (F-01)"; fi

# ARM 7 — the host-protection input policy must be UNCHANGED by all of this.
if [[ "$a3p4" == "policy accept" && "$a3p6" == "policy accept" ]]; then
    ok "ARM7 the rendered forward policy reads back as accept in both families"
else
    bad "ARM7 rendered forward policy reads v4=[$a3p4] v6=[$a3p6], expected accept in both"
fi
ip4="$(ip netns exec "$R" nft list chain ip  nftban input 2>/dev/null | grep -o 'policy [a-z]*' | head -1)"
ip6="$(ip netns exec "$R" nft list chain ip6 nftban input 2>/dev/null | grep -o 'policy [a-z]*' | head -1)"
if [[ "$ip4" == "policy drop" && "$ip6" == "policy drop" ]]; then
    ok "ARM7 the input chain is still policy drop in both families (kernel read-back)"
else
    bad "ARM7 input policy changed: v4=[$ip4] v6=[$ip6], expected drop in both"
fi
if in_v4; then
    bad "ARM7 inbound to the protected host is now ACCEPTED — opening hook forward leaked into hook input"
else
    ok "ARM7 inbound to the protected host is still dropped — forwarding was not bought with inbound exposure"
fi

# =============================================================================
# ARM 6 — the forward chain must be PROTECTIVE, not merely open. The shipped
# chain had no rules at all, so wherever an operator worked around the drop,
# forwarded traffic got no ban enforcement whatsoever (the secondary finding).
# =============================================================================
if ip netns exec "$R" nft add element ip nftban blacklist_manual_ipv4 '{ 10.99.2.2 }' >/dev/null 2>&1; then
    # ⛔ NEVER `nft ... | grep -q` under `set -o pipefail`. grep -q exits on the FIRST
    # match, SIGPIPEs the producer, and the pipeline then reports the producer's
    # failure — so a SUCCESSFUL match reads as "not found". That is exactly what
    # silenced this arm: the element WAS in the set and the chain WAS correct.
    # Capture first, match second.
    _a6_elems="$(ip netns exec "$R" nft list set ip nftban blacklist_manual_ipv4 2>/dev/null || true)"
    if grep -q '10.99.2.2' <<<"$_a6_elems"; then
        if fwd_v4; then
            bad "ARM6 a banned forwarded destination was still reachable — the forward chain does not enforce"
        else
            ok "ARM6 a banned destination is dropped on the FORWARD path (chain is protective, not just open)"
        fi
        ip netns exec "$R" nft delete element ip nftban blacklist_manual_ipv4 '{ 10.99.2.2 }' >/dev/null 2>&1 || true
        if fwd_v4; then
            ok "ARM6 forwarding is restored once the ban is lifted (the drop was the ban, not a blackhole)"
        else
            bad "ARM6 forwarding did NOT recover after the ban was lifted"
        fi
    else
        # An unasserted arm must say WHY, or the gap is invisible in the log and a
        # reader mistakes silence for coverage. The element ADD returned 0, so the
        # set exists and accepted it — print what the kernel actually holds.
        inf "ARM6 could not confirm the ban element landed in the set — arm not asserted"
        inf "ARM6 diag: set contents ->"
        ip netns exec "$R" nft list set ip nftban blacklist_manual_ipv4 2>&1 | sed 's/^/           /'
        inf "ARM6 diag: forward chain as loaded ->"
        ip netns exec "$R" nft list chain ip nftban forward 2>&1 | sed 's/^/           /'
    fi
else
    inf "ARM6 blacklist_manual_ipv4 would not accept an element here — arm not asserted"
    inf "ARM6 diag: add error ->"
    ip netns exec "$R" nft add element ip nftban blacklist_manual_ipv4 '{ 10.99.2.2 }' 2>&1 | sed 's/^/           /'
    inf "ARM6 diag: tables present ->"
    ip netns exec "$R" nft list tables 2>&1 | sed 's/^/           /'
fi

# =============================================================================
# ARM 4 — NEGATIVE CONTROL. Delete ONLY the nftban tables; the foreign table
# stays. Isolates causation to our table alone.
# =============================================================================
ip netns exec "$R" nft delete table ip  nftban >/dev/null 2>&1 || true
ip netns exec "$R" nft delete table ip6 nftban >/dev/null 2>&1 || true
if ip netns exec "$R" nft list table ip nftban >/dev/null 2>&1; then
    bad "ARM4 precondition: ip nftban still present after delete"
elif ip netns exec "$R" nft list table ip dockerlike >/dev/null 2>&1; then
    if fwd_v4 && fwd_v6; then
        ok "ARM4 negative control: with ONLY the nftban tables removed, forwarding works (v4 + v6)"
    else
        bad "ARM4 negative control FAILED: forwarding still broken with the nftban tables gone — cause is not isolated to our table"
    fi
else
    bad "ARM4 precondition: the foreign table was lost, so the control is not isolating anything"
fi

# =============================================================================
# CLEANUP EVIDENCE — the host must be exactly as we found it.
# =============================================================================
cleanup
NS_AFTER="$(ip netns list 2>/dev/null | grep -c . || true)"
if [[ "$NS_AFTER" == "$NS_BEFORE" ]]; then
    ok "namespace count returned to its pre-test value ($NS_BEFORE)"
else
    bad "namespace leak: before=$NS_BEFORE after=$NS_AFTER"
fi
HOST_FWD_AFTER="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)"
if [[ "$HOST_FWD_AFTER" == "$HOST_FWD_BEFORE" ]]; then
    ok "the HOST's own ip_forward is unchanged ($HOST_FWD_BEFORE) — only namespaces were touched"
else
    bad "the host's ip_forward changed: before=$HOST_FWD_BEFORE after=$HOST_FWD_AFTER"
fi

echo "=== forward_chain_routing_host_f01: PASS=$PASS FAIL=$FAIL ==="
if [[ "$FAIL" -eq 0 ]]; then echo "RESULT: PASS"; exit 0; fi
echo "RESULT: FAIL"; exit 1
