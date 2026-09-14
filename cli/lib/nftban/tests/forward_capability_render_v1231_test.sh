#!/usr/bin/env bash
# =============================================================================
# NFTBan - hook-forward capability gate (v1.231.0 F-01)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="forward_capability_render_v1231_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-14"
# meta:description="Hermetic half of the F-01 regression (FORWARD-CHAIN-EMPTY-POLICY-DROP-BLACKHOLES-ROUTED-TRAFFIC). Locks the render side of the hook-forward capability gate: A1 the authority exists and reads the real /proc by default. A2 a NON-FORWARDING host gets a BYTE-IDENTICAL render of both shipped artifacts — the zero-delta proof for every non-routing host. A3 a forwarding host gets policy accept plus ban-set rules in BOTH families. A4 the gate is PER FAMILY. A5 the host-protection input chain is byte-identical in every arm. A6 idempotent. A7 fail-closed when the host forwards and no forward chain is recognised. A8 an unreadable sysctl is NOT forwarding. A9 NEGATIVE CONTROL — the ungated shipped artifact still carries policy drop with zero rules, so A3 discriminates. A10 every set the forwarding chain references is declared in the same table. A11 the real render authority _firewall_substitute_placeholders actually applies the gate. A12 nft -c accepts the forwarding render. PACKET OUTCOME IS NOT TESTED HERE — that is forward_chain_routing_host_f01_test.sh (netns, ROOT_LAB)."
# meta:input="cli/lib/nftban/lib/forward_capability.sh, cli/lib/nftban/cli/cmd_firewall.sh, install/nftables/nftables.conf, install/nftables/nftables.conf.tpl"
# meta:output="PASS/FAIL per assertion; exit 1 on any failure"
# meta:depends="bash,awk,diff,cmp,grep,mktemp"
# meta:ta.id="forward_capability_render_v1231_test"
# meta:ta.owner="firewall"
# meta:ta.module="forward-capability"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.blocking="true"
# meta:ta.timeout="60"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:inventory.files=""
# meta:inventory.binaries="bash,awk,diff,cmp,grep,mktemp"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR,NFTBAN_FORWARD_PROC_ROOT"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LIB="$ROOT/cli/lib/nftban/lib/forward_capability.sh"
CMD="$ROOT/cli/lib/nftban/cli/cmd_firewall.sh"
CONF="$ROOT/install/nftables/nftables.conf"
TPL="$ROOT/install/nftables/nftables.conf.tpl"

FAILS=0
ok()  { printf '  [PASS] %s\n' "$1"; }
bad() { printf '  [FAIL] %s\n' "$1"; FAILS=$((FAILS+1)); }
inf() { printf '  [INFO] %s\n' "$1"; }
skp() { printf '  [SKIP] %s\n' "$1"; }

echo "=== forward_capability_render_v1231 (F-01 render gate) ==="

# ⛔ SUBJECT PRESENCE IS ASSERTED BEFORE ANY VERDICT. A missing subject is not a
# pass and not a fail — it is a test that did not execute, and it exits 3.
for f in "$LIB" "$CMD" "$CONF" "$TPL"; do
    if [[ ! -f "$f" ]]; then
        echo "  [NOT_EXECUTED] subject missing: $f"
        echo "RESULT: NOT_EXECUTED"
        exit 3
    fi
done

SB=$(mktemp -d) || { echo "RESULT: NOT_EXECUTED (mktemp)"; exit 3; }
trap 'rm -rf "$SB"' EXIT

# Synthetic capability roots. The gate reads procfs; these present the four
# host shapes without touching this machine's networking in any way.
mk_proc() { # <dir> <v4> <v6>
    mkdir -p "$1/sys/net/ipv4" "$1/sys/net/ipv6/conf/all"
    printf '%s\n' "$2" > "$1/sys/net/ipv4/ip_forward"
    printf '%s\n' "$3" > "$1/sys/net/ipv6/conf/all/forwarding"
}
mk_proc "$SB/p00" 0 0     # host-only (the 9 fleet hosts, and every non-routing box)
mk_proc "$SB/p11" 1 1     # dual-stack router / container host
mk_proc "$SB/p10" 1 0     # IPv4 forwarding only
mkdir -p "$SB/pXX/sys/net/ipv4" "$SB/pXX/sys/net/ipv6/conf/all"   # sysctls absent

# Extract one chain block by BRACE DEPTH (not by line number, and not by matching
# the single line today's artifact happens to contain).
chain_block() { # <file> <chain-name>
    awk -v want="$2" '
        !inch && $0 ~ ("^[ \t]*chain[ \t]+" want "[ \t]*\\{[ \t]*$") { inch=1; depth=1; print; next }
        inch { o=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=o-c; print; if (depth<=0) inch=0 }
    ' "$1"
}

# shellcheck source=/dev/null
source "$LIB"

# --- A1 authority surface + default read path -------------------------------
missing=""
for fn in nftban_forward_proc_root nftban_forwarding_enabled nftban_forward_capability \
          nftban_forward_chain_policy nftban_forward_chain_body nftban_forward_render; do
    declare -F "$fn" >/dev/null 2>&1 || missing="$missing $fn"
done
if [[ -z "$missing" ]]; then
    ok "A1 capability authority defines its whole surface"
else
    bad "A1 missing from lib/forward_capability.sh:$missing"
fi
# The override exists for THIS test. Production must read the real procfs, so the
# default is asserted rather than assumed — otherwise the gate could ship pointed
# at nothing and every arm below would still be green.
if [[ "$(nftban_forward_proc_root)" == "/proc" ]]; then
    ok "A1 default capability source is the real /proc"
else
    bad "A1 default capability source is '$(nftban_forward_proc_root)', expected /proc"
fi

# --- A2 NON-FORWARDING HOST: byte-identical, both shipped artifacts ----------
# This is the zero-delta proof. Every production host surveyed for F-01 has
# ip_forward=0, so this arm is what they get: the shipped bytes, unedited.
for art in "$CONF" "$TPL"; do
    cp "$art" "$SB/a2"
    if NFTBAN_FORWARD_PROC_ROOT="$SB/p00" nftban_forward_render "$SB/a2"; then
        if cmp -s "$art" "$SB/a2"; then
            ok "A2 host-only render of $(basename "$art") is BYTE-IDENTICAL"
        else
            bad "A2 host-only render of $(basename "$art") CHANGED the artifact"
            diff "$art" "$SB/a2" | head -10 | sed 's/^/         /'
        fi
    else
        bad "A2 host-only render of $(basename "$art") returned non-zero"
    fi
done
if [[ "$(NFTBAN_FORWARD_PROC_ROOT="$SB/p00" nftban_forward_capability)" == "host-only" ]]; then
    ok "A2 capability of a non-forwarding host reads 'host-only'"
else
    bad "A2 non-forwarding host did not report 'host-only'"
fi
if [[ "$(NFTBAN_FORWARD_PROC_ROOT="$SB/p00" nftban_forward_chain_policy ipv4)" == "drop" \
   && "$(NFTBAN_FORWARD_PROC_ROOT="$SB/p00" nftban_forward_chain_policy ipv6)" == "drop" ]]; then
    ok "A2 expected forward policy on a non-forwarding host is still drop (both families)"
else
    bad "A2 expected forward policy on a non-forwarding host is no longer drop"
fi

# --- A9 NEGATIVE CONTROL (runs before A3, because A3's meaning depends on it) -
# The MOTIVATING DEFECT, verbatim from the shipped artifact: an empty base chain
# with policy drop, in both families. If this arm ever stops finding it, A3 is
# asserting something about a subject that no longer exists.
v4_blk="$(chain_block "$CONF" forward | head -20)"
drop_count=$(grep -c 'hook forward priority 0; policy drop;' "$CONF")
rule_lines=$(chain_block "$CONF" forward | grep -cE '^[ \t]*(ip|ip6|ct|counter|meta|tcp|udp)[ \t]')
if [[ "$drop_count" == "2" && "$rule_lines" == "0" ]]; then
    ok "A9 NEGATIVE CONTROL: the shipped artifact still ships 2 empty policy-drop forward chains"
else
    bad "A9 NEGATIVE CONTROL lost its subject: policy-drop forward chains=$drop_count rules=$rule_lines (want 2 / 0)"
    inf "the defect this test exists for is no longer present in the form it asserts"
fi
[[ -n "$v4_blk" ]] || bad "A9 could not extract the forward chain block from $CONF"

# --- A3 FORWARDING HOST: not a blackhole any more, and actually protective ----
cp "$CONF" "$SB/a3"
if NFTBAN_FORWARD_PROC_ROOT="$SB/p11" nftban_forward_render "$SB/a3"; then
    ok "A3 forwarding render succeeded"
else
    bad "A3 forwarding render returned non-zero"
fi
if [[ "$(grep -c 'hook forward priority 0; policy drop;' "$SB/a3")" == "0" ]]; then
    ok "A3 no policy-drop forward chain survives on a forwarding host"
else
    bad "A3 a policy-drop forward chain SURVIVED — forwarded traffic would still be blackholed"
fi
if [[ "$(grep -c 'hook forward priority 0; policy accept;' "$SB/a3")" == "2" ]]; then
    ok "A3 both families carry policy accept at hook forward"
else
    bad "A3 expected 2 accept-policy forward chains, got $(grep -c 'hook forward priority 0; policy accept;' "$SB/a3")"
fi
# Fail-closed-but-not-protective was the SECONDARY finding: the shipped chain had
# no rules at all, so wherever an operator worked around the drop, forwarded
# traffic got no ban enforcement. Assert the chain now enforces, per family.
fwd_v4="$(awk '/^table ip nftban \{/,/^\}/' "$SB/a3" | sed -n '/chain forward {/,/^    }/p')"
fwd_v6="$(awk '/^table ip6 nftban \{/,/^\}/' "$SB/a3" | sed -n '/chain forward {/,/^    }/p')"
for want in 'ip saddr @blacklist_ipv4 counter drop' 'ip daddr @blacklist_ipv4 counter drop' \
            'ip saddr @blacklist_manual_ipv4 counter drop' 'ip daddr @blacklist_manual_ipv4 counter drop' \
            'ip saddr @whitelist_ipv4 counter accept'; do
    if grep -qF "$want" <<<"$fwd_v4"; then ok "A3 ipv4 forward enforces: $want"
    else bad "A3 ipv4 forward chain is missing: $want"; fi
done
for want in 'ip6 saddr @blacklist_ipv6 counter drop' 'ip6 daddr @blacklist_ipv6 counter drop' \
            'ip6 saddr @blacklist_manual_ipv6 counter drop' 'ip6 daddr @blacklist_manual_ipv6 counter drop' \
            'ip6 saddr @whitelist_ipv6 counter accept'; do
    if grep -qF "$want" <<<"$fwd_v6"; then ok "A3 ipv6 forward enforces: $want"
    else bad "A3 ipv6 forward chain is missing: $want"; fi
done
# The forwarding chain must not introduce a NEW blanket drop. ct-invalid at hook
# forward is exactly the availability class F-01 belongs to (asymmetric routing),
# so its absence is an asserted property, not an accident of drafting.
if grep -q 'ct state invalid' <<<"$fwd_v4$fwd_v6"; then
    bad "A3 forwarding chain drops ct-invalid — a router legitimately sees unclassifiable flows"
else
    ok "A3 forwarding chain adds no ct-invalid drop (only banned endpoints are dropped)"
fi

# --- A4 PER-FAMILY gate ------------------------------------------------------
cp "$CONF" "$SB/a4"
NFTBAN_FORWARD_PROC_ROOT="$SB/p10" nftban_forward_render "$SB/a4"
if [[ "$(grep -c 'hook forward priority 0; policy accept;' "$SB/a4")" == "1" \
   && "$(grep -c 'hook forward priority 0; policy drop;' "$SB/a4")" == "1" ]]; then
    ok "A4 v4-only forwarding rewrites ip and leaves ip6 at policy drop"
else
    bad "A4 per-family gate wrong: forward-accept=$(grep -c 'hook forward priority 0; policy accept;' "$SB/a4") forward-drop=$(grep -c 'hook forward priority 0; policy drop;' "$SB/a4")"
fi
if [[ "$(NFTBAN_FORWARD_PROC_ROOT="$SB/p10" nftban_forward_chain_policy ipv6)" == "drop" ]]; then
    ok "A4 expected ipv6 forward policy stays drop when only v4 forwards"
else
    bad "A4 ipv6 expected policy changed on a v4-only router"
fi

# --- A5 HOST-PROTECTION INPUT POLICY IS UNCHANGED IN EVERY ARM ---------------
# The fix must not buy forwarding by relaxing inbound protection anywhere.
base_in="$(chain_block "$CONF" input)"
if [[ -z "$base_in" ]]; then
    bad "A5 could not extract the input chain from the shipped artifact"
else
    for arm in a3 a4; do
        if [[ "$(chain_block "$SB/$arm" input)" == "$base_in" ]]; then
            ok "A5 input chain byte-identical after the $arm render"
        else
            bad "A5 input chain CHANGED after the $arm render"
            diff <(printf '%s\n' "$base_in") <(chain_block "$SB/$arm" input) | head -10 | sed 's/^/         /'
        fi
    done
    for arm in a3 a4; do
        if [[ "$(grep -c 'hook input priority 0; policy drop;' "$SB/$arm")" == "2" ]]; then
            ok "A5 both input chains still policy drop after the $arm render"
        else
            bad "A5 input policy drop count changed after the $arm render"
        fi
    done
    # Output chain too — the render must touch hook forward and nothing else.
    if [[ "$(chain_block "$CONF" output)" == "$(chain_block "$SB/a3" output)" ]]; then
        ok "A5 output chain byte-identical after the forwarding render"
    else
        bad "A5 output chain CHANGED after the forwarding render"
    fi
fi

# --- A6 idempotency ----------------------------------------------------------
cp "$SB/a3" "$SB/a6"
NFTBAN_FORWARD_PROC_ROOT="$SB/p11" nftban_forward_render "$SB/a6"
if cmp -s "$SB/a3" "$SB/a6"; then
    ok "A6 re-rendering an already-rendered forwarding ruleset is a no-op"
else
    bad "A6 render is NOT idempotent"
    diff "$SB/a3" "$SB/a6" | head -10 | sed 's/^/         /'
fi

# --- A7 FAIL-CLOSED on an unrecognised ruleset shape -------------------------
# A forwarding host whose ruleset shape we cannot rewrite must NOT get a silent
# pass-through: that is the F-01 outage, applied with a clean exit code.
cat > "$SB/a7" <<'UNRECOGNISED'
table ip nftban {
    chain input { type filter hook input priority 0; policy drop; }
}
UNRECOGNISED
a7_before="$(cat "$SB/a7")"
if NFTBAN_FORWARD_PROC_ROOT="$SB/p11" nftban_forward_render "$SB/a7" 2>/dev/null; then
    bad "A7 render returned SUCCESS on a forwarding host with no rewritable forward chain"
else
    ok "A7 render FAILS CLOSED when the host forwards and no forward chain was rewritten"
fi
if [[ "$(cat "$SB/a7")" == "$a7_before" ]]; then
    ok "A7 the input file is left untouched on failure"
else
    bad "A7 a failed render mutated its input file"
fi

# --- A8 an unreadable sysctl is NOT 'forwarding' -----------------------------
if NFTBAN_FORWARD_PROC_ROOT="$SB/pXX" nftban_forwarding_enabled ipv4; then
    bad "A8 an absent ip_forward sysctl was read as FORWARDING"
else
    ok "A8 an absent/unreadable sysctl is not forwarding (failed observation is not a verdict)"
fi
cp "$CONF" "$SB/a8"
NFTBAN_FORWARD_PROC_ROOT="$SB/pXX" nftban_forward_render "$SB/a8"
if cmp -s "$CONF" "$SB/a8"; then
    ok "A8 an unreadable capability leaves the shipped behaviour exactly as-is"
else
    bad "A8 an unreadable capability changed the ruleset"
fi

# --- A10 set-reference coherence --------------------------------------------
# Every @set the forwarding chain names must be DECLARED in the same table block
# of the shipped artifact, or the render produces a ruleset nft will reject.
v4_decl="$(awk '/^table ip nftban \{/,/^\}/' "$CONF" | grep -oE '^[ \t]*set [a-z0-9_]+' | awk '{print $2}')"
v6_decl="$(awk '/^table ip6 nftban \{/,/^\}/' "$CONF" | grep -oE '^[ \t]*set [a-z0-9_]+' | awk '{print $2}')"
a10=0
while read -r s; do
    [[ -z "$s" ]] && continue
    grep -qx "$s" <<<"$v4_decl" || { bad "A10 ipv4 forward chain references undeclared set @$s"; a10=1; }
done < <(nftban_forward_chain_body ipv4 | grep -oE '@[a-z0-9_]+' | tr -d '@' | sort -u)
while read -r s; do
    [[ -z "$s" ]] && continue
    grep -qx "$s" <<<"$v6_decl" || { bad "A10 ipv6 forward chain references undeclared set @$s"; a10=1; }
done < <(nftban_forward_chain_body ipv6 | grep -oE '@[a-z0-9_]+' | tr -d '@' | sort -u)
[[ "$a10" -eq 0 ]] && ok "A10 every set the forwarding chain references is declared in its own table"

# --- A11 THE REAL RENDER AUTHORITY APPLIES THE GATE --------------------------
# ⛔ Proving the library in isolation proves nothing about what reaches the kernel.
# _firewall_substitute_placeholders is the ONE path rebuild, reload and the boot
# projection all render through; this arm asserts the gate is actually wired into it.
mkdir -p "$SB/liba11/lib"
cp "$LIB" "$SB/liba11/lib/"
(
    export NFTBAN_LIB_DIR="$SB/liba11" NFTBAN_CONFIG_DIR="$SB/confa11"
    mkdir -p "$SB/confa11"
    # shellcheck source=/dev/null
    source "$CMD" >/dev/null 2>&1
    declare -F _firewall_substitute_placeholders >/dev/null 2>&1 || exit 20
    NFTBAN_FORWARD_PROC_ROOT="$SB/p11" _firewall_substitute_placeholders "$TPL" "$SB/a11.fwd" >/dev/null 2>&1 || exit 21
    NFTBAN_FORWARD_PROC_ROOT="$SB/p00" _firewall_substitute_placeholders "$TPL" "$SB/a11.host" >/dev/null 2>&1 || exit 22
) ; a11_rc=$?
case "$a11_rc" in
    0)
        if [[ "$(grep -c 'hook forward priority 0; policy accept;' "$SB/a11.fwd")" == "2" ]]; then
            ok "A11 the real render authority applies the gate on a forwarding host"
        else
            bad "A11 the real render authority did NOT apply the gate — the fix is not wired in"
        fi
        if [[ "$(grep -c 'hook forward priority 0; policy drop;' "$SB/a11.host")" == "2" ]]; then
            ok "A11 the real render authority is unchanged on a non-forwarding host"
        else
            bad "A11 the real render authority altered a non-forwarding host's forward policy"
        fi
        if grep -qE '__[A-Z0-9_]+__' "$SB/a11.fwd"; then
            bad "A11 placeholders survived the render (the gate broke substitution)"
        else
            ok "A11 placeholder substitution still completes alongside the gate"
        fi
        ;;
    20) bad "A11 _firewall_substitute_placeholders is not defined by $CMD" ;;
    21) bad "A11 the real render authority FAILED on a forwarding host" ;;
    22) bad "A11 the real render authority FAILED on a non-forwarding host" ;;
    *)  bad "A11 harness error (rc=$a11_rc)" ;;
esac

# --- A12 the forwarding render must still parse ------------------------------
# A privilege error is a SKIP, never a PASS: absence of a verdict is not a verdict.
if [[ -f "$SB/a11.fwd" ]]; then
    probe="$SB/probe.nft"; printf 'table ip nftban_probe {\n}\n' > "$probe"
    nft_mode=""
    if command -v nft >/dev/null 2>&1; then
        if nft -c -f "$probe" >/dev/null 2>&1; then nft_mode="host"
        elif command -v unshare >/dev/null 2>&1 && unshare -rn nft -c -f "$probe" >/dev/null 2>&1; then nft_mode="netns"; fi
    fi
    case "$nft_mode" in
        host)  if nft -c -f "$SB/a11.fwd" >/dev/null 2>&1; then ok "A12 forwarding render parses under nft -c"
               else bad "A12 forwarding render FAILS nft -c:"; nft -c -f "$SB/a11.fwd" 2>&1 | head -5 | sed 's/^/         /'; fi ;;
        netns) if unshare -rn nft -c -f "$SB/a11.fwd" >/dev/null 2>&1; then ok "A12 forwarding render parses under nft -c (user+net namespace)"
               else bad "A12 forwarding render FAILS nft -c:"; unshare -rn nft -c -f "$SB/a11.fwd" 2>&1 | head -5 | sed 's/^/         /'; fi ;;
        *)     skp "A12 nft -c needs privileges and no namespace is available — NOT a pass" ;;
    esac
else
    bad "A12 no forwarding render available to validate"
fi

echo "=== forward_capability_render_v1231: FAILS=$FAILS ==="
[[ "$FAILS" -eq 0 ]] || exit 1
echo "RESULT: PASS"
exit 0
