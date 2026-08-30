#!/usr/bin/env bash
# =============================================================================
# NFTBan Test - NDP source scope + hop-limit (RFC 4861)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="nft-ndp-rfc4861-source-scope-test"
# meta:type="test"
# meta:header="NDP RFC 4861 Source Scope"
# meta:version="1.229.11"
# meta:owner="NFTBan Project / Antonios Voulvoulis"
# meta:homepage="https://nftban.com"
#
# meta:description="Static regression for NDP-SOURCE-SCOPE: in every shipped nftables config (template nftables.conf.tpl, rendered nftables.conf, nftables-safe.conf) Neighbor Solicitation / Neighbor Advertisement / Router Solicitation MUST be accepted regardless of source address scope, gated on 'ip6 hoplimit 255' (RFC 4861 6.1.1/6.1.2/7.1.1/7.1.2 - a receiver MUST discard ND with Hop Limit != 255); Router Advertisement MUST additionally keep the fe80::/10 source restriction (RFC 4861 4.2). NEGATIVE: no shipped config may reintroduce a single NDP rule that gates nd-neighbor-solicit/advert or nd-router-solicit on 'ip6 saddr fe80::/10', because that drops legitimate global-sourced NS/NA from same-subnet neighbours and every DAD solicitation (source ::), so an on-link IPv6 peer cannot resolve the host and TCP never establishes (measured: peer neighbour entry stuck INCOMPLETE, connect() OSError; after the fix REACHABLE + CONNECTED). Also asserts nd-redirect stays excluded. Hermetic: reads repo source files read-only; no nft, no host, no root."
# meta:inventory.files="install/nftables/nftables.conf.tpl,install/nftables/nftables.conf,install/nftables/nftables-safe.conf"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:created_date="2026-08-29"
# meta:updated_date="2026-08-29"
# meta:ta.id="nft_ndp_rfc4861_source_scope_test"
# meta:ta.owner="firewall"
# meta:ta.module="nft-schema-ndp"
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
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT=$(cd "$SD/../../../.." && pwd)
TPL="$ROOT/install/nftables/nftables.conf.tpl"
CONF="$ROOT/install/nftables/nftables.conf"
SAFE="$ROOT/install/nftables/nftables-safe.conf"
P=0; F=0
ok(){ echo "PASS $1"; P=$((P+1)); }
no(){ echo "FAIL $1 ${2:-}"; F=$((F+1)); }

# Rule lines only: strip comment lines (LINENUM:<spaces>#...) so the RFC citations
# in the surrounding comment block can never satisfy an assertion. A doc comment is
# not a control.
rules_only(){ grep -vE '^[0-9]+:[[:space:]]*#'; }

# Extract the ONE logical nft rule containing line $2 of file $1. Rules span multiple
# lines in the brace form, so a fixed +N window bleeds into the NEXT rule and would
# make an assertion pass or fail for the wrong reason. Walk back to the rule head
# (first non-comment line starting a match expression) and forward to its verdict.
logical_rule(){
    local f="$1" L="$2" start end
    start=$(awk -v L="$L" 'NR<=L && !/^[[:space:]]*#/ && /^[[:space:]]*(ip6|ip|meta|ct|tcp|udp|iif)[[:space:]]/ {s=NR} END{print s+0}' "$f")
    [[ "$start" -gt 0 ]] || return 1
    end=$(awk -v S="$start" 'NR>=S && /(accept|drop|return)[[:space:]]*($|comment)/ {print NR; exit}' "$f")
    [[ -n "$end" ]] || end="$start"
    sed -n "${start},${end}p" "$f"
}

# The accepting rule for a given ND type, as a RULE (not a comment).
nd_rule_lines(){ grep -n "$2" "$1" | rules_only | grep -oE '^[0-9]+' || true; }

echo "== NS/NA/RS accepted on hop-limit 255, NOT gated on source scope =="
for spec in "TPL:$TPL" "CONF:$CONF" "SAFE:$SAFE"; do
    label="${spec%%:*}"; f="${spec#*:}"
    [[ -r "$f" ]] || { no "$label: unreadable ($f)"; continue; }

    # Locate nd-neighbor-solicit wherever it appears as a RULE (single-line list or a
    # member of a multi-line brace list), then extract its whole logical rule. Anchoring
    # on the type name rather than on the fixed/defective rule head means this reports
    # the DEFECT ("still gated on fe80::/10") rather than a misleading "rule not found"
    # when the defective form is reintroduced.
    line=$( { grep -nE 'nd-neighbor-solicit' "$f" || true; } \
            | { grep -vE '^[0-9]+:[[:space:]]*#' || true; } | head -1 )
    [[ -n "$line" ]] || { no "$label: no nd-neighbor-solicit accept rule found at all"; continue; }

    n="${line%%:*}"
    blk=$(logical_rule "$f" "$n") || { no "$label: could not extract NS rule at line $n"; continue; }

    grep -q 'hoplimit 255' <<<"$blk" \
        && ok "$label: NS/NA/RS rule gated on hop-limit 255" \
        || no "$label: NS/NA/RS rule missing 'ip6 hoplimit 255'"

    if grep -q 'nd-neighbor-solicit' <<<"$blk" && grep -q 'fe80::/10' <<<"$blk"; then
        no "$label: NS/NA/RS rule still gated on fe80::/10 source scope" \
           "(drops global-sourced NS/NA and all DAD)"
    else
        ok "$label: NS/NA/RS rule not gated on source scope"
    fi
done

echo "== DAD is reachable: no shipped config may exclude the unspecified source =="
for spec in "TPL:$TPL" "CONF:$CONF" "SAFE:$SAFE"; do
    label="${spec%%:*}"; f="${spec#*:}"
    # Any rule line that mentions nd-neighbor-solicit AND fe80::/10 is the defect.
    bad=$( { grep -nE 'nd-neighbor-solicit' "$f" || true; } | { grep -vE '^[0-9]+:[[:space:]]*#' || true; } | { grep -c 'fe80::/10' || true; } )
    [[ "$bad" -eq 0 ]] \
        && ok "$label: DAD (source ::) not excluded by a source-scope match" \
        || no "$label: $bad rule(s) exclude DAD via fe80::/10"
done

echo "== RA keeps the link-local source restriction (RFC 4861 4.2) =="
for spec in "TPL:$TPL" "CONF:$CONF" "SAFE:$SAFE"; do
    label="${spec%%:*}"; f="${spec#*:}"
    ra=$(grep -nE 'nd-router-advert' "$f" | rules_only | head -1 || true)
    [[ -n "$ra" ]] || { no "$label: no RA rule found"; continue; }
    n="${ra%%:*}"
    blk=$(logical_rule "$f" "$n") || { no "$label: could not extract RA rule at line $n"; continue; }
    { grep -q 'fe80::/10' <<<"$blk" && grep -q 'hoplimit 255' <<<"$blk"; } \
        && ok "$label: RA restricted to fe80::/10 AND hop-limit 255" \
        || no "$label: RA rule must keep fe80::/10 and gain hop-limit 255"
done

echo "== nd-redirect stays excluded (unchanged posture) =="
for spec in "TPL:$TPL" "CONF:$CONF" "SAFE:$SAFE"; do
    label="${spec%%:*}"; f="${spec#*:}"
    r=$( { grep -nE 'nd-redirect' "$f" || true; } | { grep -vE '^[0-9]+:[[:space:]]*#' || true; } | wc -l )
    [[ "$r" -eq 0 ]] && ok "$label: nd-redirect not accepted" \
                     || no "$label: nd-redirect appears in $r rule(s)"
done

echo "== template and rendered boot baseline agree on the NDP rules =="
tn=$(grep -cE 'ip6 hoplimit 255' "$TPL" || true)
cn=$(grep -cE 'ip6 hoplimit 255' "$CONF" || true)
{ [[ "$tn" -ge 2 && "$tn" -eq "$cn" ]]; } \
    && ok "tpl/rendered NDP rule count matches ($tn)" \
    || no "tpl vs rendered NDP rule drift" "tpl=$tn conf=$cn"

echo ""
echo "=== nft_ndp_rfc4861_source_scope: PASS=$P FAIL=$F ==="
[[ "$F" -eq 0 ]]
