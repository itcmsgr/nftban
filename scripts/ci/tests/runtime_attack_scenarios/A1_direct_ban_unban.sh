#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# meta:name="A1_direct_ban_unban"
# meta:type="attack-scenario"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="A1 — direct ban/unban authority, proven by REAL cross-VM traffic. Bans the attacker's attack-segment IP, proves the drop rule sits in a HOOKED chain, proves the named counter moves and the attacker is actually blocked, then unbans and proves access is restored. Management path is never touched."
# =============================================================================
#
#   PRECONDITION  target COMMITTED + daemon active; attacker reachable, not
#                 banned, not whitelisted; a port is reachable BEFORE the ban
#                 (the negative control that proves the later block is real).
#   INJECTION     `nftban ban <attacker_ip>` on the target (IPC path).
#   OBSERVATION   membership -> referenced by a drop rule -> that chain is HOOKED
#                 -> counter delta under real attacker traffic -> attacker blocked.
#   CLEANUP       unban, prove access restored, verify not assumed.
#
# Invariants enforced: NO FIREWALL PASS WITHOUT CLEAN RECOVERY, and management
# (MGMT_IP) is never a ban target.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
WORK="$(mktemp -d)"; trap 'attacker_unban_best_effort; rm -rf "$WORK"' EXIT
# shellcheck source=/dev/null
. "$HERE/lib_attack_evidence.sh"

BAN_PORT="${BAN_PORT:-22}"        # an open service port on the target
NFTBAN="${NFTBAN_CLI:-nftban}"

attacker_unban_best_effort(){ $TARGET_RUN "sudo $NFTBAN unban $ATTACKER_IP >/dev/null 2>&1 || true" 2>/dev/null || true; }

echo "===== A1: direct ban/unban enforcement (attacker=$ATTACKER_IP target=$TARGET_IP) ====="

# --- PRECONDITION ------------------------------------------------------------
st="$($TARGET_RUN "sudo grep -m1 '^INSTALL_STATE=' /var/lib/nftban/state/install_state 2>/dev/null | cut -d= -f2" || true)"
[[ "$st" == COMMITTED ]] && pass "precondition: target INSTALL_STATE=COMMITTED" \
                         || fail FAIL_ENVIRONMENT "precondition: target state is '$st' (want COMMITTED)"
d="$($TARGET_RUN "systemctl is-active nftband.service 2>/dev/null | head -1" || true)"
[[ "$d" == active ]] && pass "precondition: nftband.service active" \
                     || fail FAIL_ENVIRONMENT "precondition: nftband.service '$d'"
assert_ban_target_safe || { scenario_summary A1; exit $?; }
attacker_unban_best_effort
in_set ip blacklist_ipv4 "$ATTACKER_IP" && fail FAIL_HARNESS "precondition: attacker already in blacklist" \
                                        || pass "precondition: attacker not currently banned"

# negative control: the port is reachable BEFORE any ban. If it is already
# blocked the later "blocked" proves nothing.
pre="$(attacker_tcp "$BAN_PORT" 4)"
[[ "$pre" == open ]] && pass "negative control: attacker reaches $TARGET_IP:$BAN_PORT before the ban" \
                     || fail FAIL_ENVIRONMENT "negative control: $TARGET_IP:$BAN_PORT already '$pre' before ban — cannot prove a block"

# --- INJECTION ---------------------------------------------------------------
# NFTBan deliberately refuses to blacklist non-public address classes (RFC1918,
# ULA, CGNAT, TEST-NET, benchmark, reserved) — netutil/ip.go:EnforcementClassReject,
# "must never be inferred from a raw ban". That refusal is CORRECT product
# behaviour, so a lab using private addressing makes the ban path untestable.
# Classify it as FAIL_ENVIRONMENT and stop, rather than blaming the product.
c_before="$(counter_val ip input_blacklist_drop || echo 0)"; c_before="${c_before:-0}"
ban_out="$($TARGET_RUN "sudo $NFTBAN ban $ATTACKER_IP 2>&1" || true)"
if grep -qiE 'non-public|non-bannable|private-or-ula|reserved-doc|link-local|loopback' <<<"$ban_out"; then
    fail FAIL_ENVIRONMENT "injection: product correctly REFUSED to ban non-public $ATTACKER_IP — the lab needs a public-class source on the isolated segment (netutil/ip.go)"
    info "refusal: $(grep -iE 'refusing|non-bannable' <<<"$ban_out" | head -1)"
    scenario_summary A1; exit $?
fi
if in_set ip blacklist_ipv4 "$ATTACKER_IP" || in_set ip blacklist_manual_ipv4 "$ATTACKER_IP"; then
    pass "injection: 'nftban ban $ATTACKER_IP' persisted a ban"
else
    fail FAIL_PRODUCT "injection: 'nftban ban' did not persist a ban and gave no class-refusal"
    info "output: $(tail -1 <<<"$ban_out")"
fi

# --- OBSERVATION: membership -> reference -> HOOK ----------------------------
set_hit=""
for s in blacklist_ipv4 blacklist_manual_ipv4; do
    if in_set ip "$s" "$ATTACKER_IP"; then set_hit="$s"; break; fi
done
[[ -n "$set_hit" ]] && pass "observation: attacker present in set $set_hit (membership)" \
                    || fail FAIL_PRODUCT "observation: attacker in NO blacklist set after ban"

if [[ -n "$set_hit" ]]; then
    ev="$(set_enforced_by_hooked_drop ip "$set_hit" | head -1)"
    if [[ -z "$ev" ]]; then
        fail FAIL_PRODUCT "ENFORCEMENT: set $set_hit is referenced by NO drop rule — membership without enforcement (the shipped-P0 class)"
    else
        chain="${ev%%|*}"; rest="${ev#*|}"; hook="${rest##*|}"
        if [[ "$hook" == HOOKED ]]; then
            pass "ENFORCEMENT: set $set_hit drops in chain '$chain' which is HOOKED (real enforcement, not membership)"
        else
            fail FAIL_PRODUCT "ENFORCEMENT: set $set_hit drops in chain '$chain' but that chain is NOT hooked — unreachable rule"
        fi
    fi
fi

# --- OBSERVATION: real packet effect + counter delta -------------------------
# The counter is chosen by WHICH set the ban landed in, not hardcoded: a manual
# `nftban ban` lands in blacklist_manual_ipv4 (handle 56, input_blacklist_manual_drop),
# a detector ban in blacklist_ipv4 (handle 57, input_blacklist_drop). Reading the
# wrong one reports a non-moving counter for a drop that did happen.
case "$set_hit" in
    blacklist_manual_ipv4) drop_counter=input_blacklist_manual_drop ;;
    blacklist_ipv4)        drop_counter=input_blacklist_drop ;;
    *)                     drop_counter="" ;;
esac
c_before="$([[ -n "$drop_counter" ]] && counter_val ip "$drop_counter" || echo 0)"; c_before="${c_before:-0}"

post="$(attacker_tcp "$BAN_PORT" 5)"
[[ "$post" == blocked ]] && pass "PACKET EFFECT: attacker can no longer reach $TARGET_IP:$BAN_PORT after ban" \
                         || fail FAIL_PRODUCT "PACKET EFFECT: attacker still reaches $TARGET_IP:$BAN_PORT after ban ('$post')"

if [[ -z "$drop_counter" ]]; then
    nyv "COUNTER DELTA: no known counter maps to set $set_hit"
else
    c_after="$(counter_val ip "$drop_counter" || echo 0)"; c_after="${c_after:-0}"
    if (( c_after > c_before )); then
        pass "COUNTER DELTA: $drop_counter advanced $c_before -> $c_after (packets actually hit the drop rule)"
    else
        fail FAIL_PRODUCT "COUNTER DELTA: $drop_counter did not move ($c_before -> $c_after) — traffic did not reach the drop"
    fi
fi

# --- family isolation: the IPv4 ban must not appear in ip6 -------------------
if $TARGET_RUN "sudo nft list table ip6 nftban >/dev/null 2>&1"; then
    in_set ip6 blacklist_ipv6 "$ATTACKER_IP" 2>/dev/null \
        && fail FAIL_PRODUCT "family isolation: an IPv4 address leaked into an ip6 set" \
        || pass "family isolation: IPv4 ban did not appear in the ip6 table"
fi

# --- duplicate ban is idempotent --------------------------------------------
$TARGET_RUN "sudo $NFTBAN ban $ATTACKER_IP >/dev/null 2>&1" \
    && pass "duplicate ban is idempotent (returns success, no error)" \
    || fail FAIL_PRODUCT "duplicate ban returned failure"

# --- CLEANUP / RECOVERY: NO FIREWALL PASS WITHOUT CLEAN RECOVERY -------------
$TARGET_RUN "sudo $NFTBAN unban $ATTACKER_IP >/dev/null 2>&1" \
    && pass "unban returned success" || fail FAIL_PRODUCT "unban failed"
in_set ip "$set_hit" "$ATTACKER_IP" 2>/dev/null \
    && fail FAIL_PRODUCT "recovery: attacker still in $set_hit after unban" \
    || pass "recovery: attacker removed from $set_hit"
rec="$(attacker_tcp "$BAN_PORT" 5)"
[[ "$rec" == open ]] && pass "RECOVERY: attacker reaches $TARGET_IP:$BAN_PORT again after unban" \
                     || fail FAIL_PRODUCT "RECOVERY: access not restored after unban ('$rec')"

scenario_summary A1
