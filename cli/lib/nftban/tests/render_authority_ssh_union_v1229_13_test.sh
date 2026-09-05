#!/usr/bin/env bash
# =============================================================================
# NFTBan - Lane 3D.2 render authority: SSH union properties, migrated from Go
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="render_authority_ssh_union_v1229_13_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-05"
# meta:description="v1.229.13 Lane 3D.2. Placeholder substitution collapsed to ONE authority: the shell _firewall_substitute_placeholders. These assertions MIGRATE — they do not retire — the security properties previously guarded by the Go renderer tests. Each arm names the historical test it supersedes. V125: primary + every detected additional SSH port survives. V145: tcp_ports_in AND ssh_ports both receive the COMPLETE union in ip AND ip6; the brute-force rule stays set-driven (@ssh_ports), never a literal port; the MAIL anonymous set is untouched; no SSH port leaks into UDP sets. V162: the durable rendered artifact ALONE carries the union, re-render is idempotent, and single-port output stays semantically equivalent."
# meta:input="cli/lib/nftban/cli/cmd_firewall.sh, install/nftables/nftables.conf.tpl"
# meta:output="PASS/FAIL per assertion; exit 1 on any failure"
# meta:depends="bash,sed,awk,grep"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR"
# meta:ta.id="render_authority_ssh_union_v1229_13_test"
# meta:ta.owner="firewall"
# meta:ta.module="render-authority"
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

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/lib/lib" "$SB/lib/templates" "$SB/conf"
cp "$ROOT/install/nftables/nftables.conf.tpl" "$SB/lib/templates/"
# env.sh supplies _source_local, which the substitution authority calls to load
# the optional classic.conf.local override. Present on every real host; the
# sandbox must carry it or the authority runs in a shape production never sees.
cp "$ROOT/cli/lib/nftban/lib/env.sh" "$SB/lib/lib/" 2>/dev/null || true
TPL="$SB/lib/templates/nftables.conf.tpl"

# Deterministic SSH detection stub. The real detector is exercised by its own
# suite; here the SUBJECT is the substitution authority, so detection is pinned.
make_detect_stub(){
    printf 'nftban_detect_ssh_ports(){ printf "%%s\\n" %s; }\nnftban_detect_ssh_primary_port(){ printf "%%s\\n" %s; }\n' \
        "$1" "$2" > "$SB/lib/lib/ssh_port_detect.sh"
}

export NFTBAN_LIB_DIR="$SB/lib" NFTBAN_CONFIG_DIR="$SB/conf"
# shellcheck source=/dev/null
source "$ROOT/cli/lib/nftban/cli/cmd_firewall.sh"

# elements list of the Nth occurrence of `set <name> { ... elements = { ... } }`
set_elements(){ # <file> <setname>  -> one line per occurrence
    awk -v want="$1" '
        $0 ~ ("set " want " \\{") { insid=1 }
        insid && /elements[[:space:]]*=/ { sub(/.*elements[[:space:]]*=[[:space:]]*\{/,""); sub(/\}.*/,""); print; insid=0 }
    ' "$2"
}
tok_count(){ grep -oE '(^|[^0-9])'"$2"'([^0-9]|$)' <<<"$1" | wc -l | tr -d ' '; }

# ---------------------------------------------------------------- MULTI-PORT
make_detect_stub '22 55000' '22'
OUT="$SB/render_multi.conf"
if _firewall_substitute_placeholders "$TPL" "$OUT"; then ok "shell authority rendered the multi-port artifact"
else no "shell authority failed to render"; fi

# V125 — supersedes TestRenderNftablesConfMultiPort_PrimaryFirst_SSHPortSubstitution
if grep -qE '\b22\b' "$OUT" && grep -qE '\b55000\b' "$OUT"; then
    ok "V125 primary AND additional detected SSH port both present in the render"
else no "V125 union lost: primary or additional port missing"; fi

# V145 — supersedes TestRenderNftablesConfMultiPort_V145_SetDriven / _MailReservedSSHPort
for setname in tcp_ports_in ssh_ports; do
    n=0
    while IFS= read -r elems; do
        [[ -z "$elems" ]] && continue
        n=$((n+1))
        for p in 22 55000; do
            c=$(tok_count "$elems" "$p")
            [[ "$c" == "1" ]] || no "V145 $setname block #$n: port $p appears $c time(s), want exactly 1 (elements=$elems)"
        done
    done < <(set_elements "$setname" "$OUT")
    if [[ "$n" == "2" ]]; then ok "V145 $setname present in BOTH families (ip + ip6)"
    else no "V145 $setname: found $n block(s), want 2 (ip + ip6)"; fi
done
grep -q 'tcp dport @ssh_ports ct count' "$OUT" \
    && ok "V145 brute-force rule stays set-driven (@ssh_ports)" \
    || no "V145 set-driven @ssh_ports ct-count rule missing"
if grep -qE 'tcp dport (22|55000) ct count' "$OUT"; then
    no "V145 literal SSH port in a ct-count rule — must read @ssh_ports"
else ok "V145 no literal SSH port ct-count rule"; fi
grep -q 'tcp dport { 25, 465, 587 } ct count' "$OUT" \
    && ok "V145 MAIL anonymous set { 25, 465, 587 } untouched by substitution" \
    || no "V145 MAIL anonymous set was altered"
udp_leak=0
while IFS= read -r elems; do
    for p in 22 55000; do [[ "$(tok_count "$elems" "$p")" == "0" ]] || udp_leak=1; done
done < <(set_elements udp_ports_in "$OUT")
[[ "$udp_leak" == "0" ]] && ok "V145 no SSH port leaked into udp_ports_in" || no "V145 SSH port leaked into udp_ports_in"

# No unsubstituted or retired placeholders survive the single authority.
if grep -qE '__SSH_PORT__|__CT_LIMIT_|__SSH_PORTS_LIST__' "$OUT"; then
    no "unsubstituted/retired placeholder survived the render"
else ok "no unsubstituted or retired placeholder in the rendered artifact"; fi

# V162 — supersedes TestRenderV162_MultiPort_DurableUnionInBothFamilies /
#        _RebootSim_DurableStringAloneCarriesUnion / _SinglePort_ByteCompat
# "Reboot": nothing but the durable artifact survives. Re-read it from disk.
n=0
while IFS= read -r elems; do
    [[ -z "$elems" ]] && continue
    n=$((n+1))
    for p in 22 55000; do
        grep -qE '(^|[^0-9])'"$p"'([^0-9]|$)' <<<"$elems" \
            || no "V162 post-reboot durable ssh_ports block #$n missing port $p"
    done
done < <(set_elements ssh_ports "$OUT")
[[ "$n" == "2" ]] && ok "V162 durable artifact ALONE carries the union in both families" \
                  || no "V162 durable artifact has $n ssh_ports block(s), want 2"

# Idempotent re-render from the same template.
OUT2="$SB/render_multi2.conf"
_firewall_substitute_placeholders "$TPL" "$OUT2" >/dev/null 2>&1
if cmp -s "$OUT" "$OUT2"; then ok "V162 re-render is byte-idempotent"
else no "V162 re-render diverged from the first render"; fi

# ---------------------------------------------------------------- SINGLE PORT
make_detect_stub '22' '22'
OUTS="$SB/render_single.conf"
_firewall_substitute_placeholders "$TPL" "$OUTS" >/dev/null 2>&1
n=0; single_ok=1
while IFS= read -r elems; do
    [[ -z "$elems" ]] && continue
    n=$((n+1))
    [[ "$(tok_count "$elems" 22)" == "1" ]] || single_ok=0
    [[ "$(tok_count "$elems" 55000)" == "0" ]] || single_ok=0
done < <(set_elements ssh_ports "$OUTS")
[[ "$single_ok" == "1" && "$n" == "2" ]] \
    && ok "V162 single-port compat: exactly one token 22, no stray multi-port element" \
    || no "V162 single-port compat failed (blocks=$n)"
grep -q 'tcp dport @ssh_ports ct count' "$OUTS" \
    && ok "V162 single-port render keeps the set-driven SSH rule" \
    || no "V162 single-port render lost the set-driven SSH rule"

# ------------------------------------------------------- CT FALLBACK ALIGNMENT
# No classic.conf present -> the fallback must render CURRENT CONFIG TRUTH
# (15/200/30, measured live on lab2/lab3/lab4). This asserts CONFIG-AUTHORITY
# ALIGNMENT ONLY. Whether these caps should exist at all is owned by A02-3.
for want in '15' '200' '30'; do
    grep -qE "ct count over $want\b" "$OUTS" \
        && ok "CT fallback renders $want (current config authority)" \
        || no "CT fallback did not render $want"
done

# ------------------------------------------------------- NEGATIVE CONTROLS
# ⛔ A green union suite proves nothing unless it can FAIL on the motivating
# defect. The historical V125/V162 regression was PRIMARY-ONLY collapse: a
# multi-port host rendering only the primary, silently locking out an operator
# connected on a secondary SSH port. Reproduce it and assert we detect it.
NC="$SB/nc_primary_only.conf"
sed -e 's/__SSH_PORT__/22/g' -e 's/__CT_LIMIT_SSH__/15/g' \
    -e 's/__CT_LIMIT_HTTP__/200/g' -e 's/__CT_LIMIT_MAIL__/30/g' "$TPL" > "$NC"
nc_detected=0
while IFS= read -r elems; do
    [[ -z "$elems" ]] && continue
    grep -qE '(^|[^0-9])55000([^0-9]|$)' <<<"$elems" || nc_detected=1
done < <(set_elements ssh_ports "$NC")
[[ "$nc_detected" == "1" ]] \
    && ok "NEGATIVE CONTROL: primary-only collapse IS detected by the union assertion" \
    || no "NEGATIVE CONTROL FAILED — a primary-only render passed the union check (test is vacuous)"

# Second inversion: an unsubstituted template must NOT be accepted as rendered.
if grep -qE '__SSH_PORT__|__CT_LIMIT_' "$TPL"; then
    ok "NEGATIVE CONTROL: the raw template still carries placeholders (fixture is live, not pre-rendered)"
else
    no "NEGATIVE CONTROL FAILED — template has no placeholders; every substitution arm above is vacuous"
fi

printf '\n  passed=%d failed=%d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
