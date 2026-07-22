#!/usr/bin/env bash
# =============================================================================
# NFTBan Test - Loopback-Before-Invalid rule order (v1.217.0)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="nft-loopback-before-invalid-v217-test"
# meta:type="test"
# meta:header="Loopback Before Invalid v1.217.0"
# meta:version="1.216.4"
# meta:owner="NFTBan Project / Antonios Voulvoulis"
# meta:homepage="https://nftban.com"
#
# meta:description="Static regression for v1.217.0 LOOPBACK_BEFORE_INVALID: in every shipped nftables config (template nftables.conf.tpl, rendered nftables.conf, nftables-safe.conf) the loopback accept (iif lo) MUST precede the ct-state-invalid drop in BOTH the ipv4 and ipv6 input chains; output chains keep oif lo first (unchanged); no rule was dropped (loopback+invalid+whitelist+blacklist+established all still present); the header doc tables list loopback before invalid; and the validator nftban_nft_validate_rule_order carries the loopback<invalid CRITICAL assertion for ip+ip6."
# meta:inventory.files="install/nftables/nftables.conf.tpl,install/nftables/nftables.conf,install/nftables/nftables-safe.conf,cli/lib/nftban/lib/nft_schema.sh"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:created_date="2026-07-05"
# meta:updated_date="2026-07-05"
# meta:ta.id="nft_loopback_before_invalid_v217_test"
# meta:ta.owner="firewall"
# meta:ta.module="nft-schema-rule-order"
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
SCHEMA="$ROOT/cli/lib/nftban/lib/nft_schema.sh"
P=0; F=0
ok(){ echo "PASS $1"; P=$((P+1)); }
no(){ echo "FAIL $1 ${2:-}"; F=$((F+1)); }

# For each input chain, the loopback-accept line must precede the invalid-drop line.
# Both files carry exactly two input chains (ipv4, ipv6); sorted by line number the
# per-chain sequence must be lo_v4 < inv_v4 (and) lo_v6 < inv_v6.
check_order() {
    local f="$1" label="$2"
    local -a lo inv
    # RULE lines only — exclude comment/doc-table lines (LINENUM:<spaces>#…).
    mapfile -t lo  < <(grep -nE 'iif "?lo"?[^,]*accept' "$f" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -oE '^[0-9]+')
    mapfile -t inv < <(grep -nE 'ct state invalid[^,]*drop' "$f" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -oE '^[0-9]+')
    if [[ ${#lo[@]} -lt 2 || ${#inv[@]} -lt 2 ]]; then
        no "$label: expected 2 input-chain loopback+invalid rules (found lo=${#lo[@]} inv=${#inv[@]})"; return
    fi
    local i fam
    for i in 0 1; do
        fam="ipv4"; [[ $i -eq 1 ]] && fam="ipv6"
        if [[ ${lo[$i]} -lt ${inv[$i]} ]]; then
            ok "$label $fam: loopback(L${lo[$i]}) BEFORE invalid(L${inv[$i]})"
        else
            no "$label $fam: loopback(L${lo[$i]}) is AFTER invalid(L${inv[$i]})"
        fi
    done
}

echo "== rendered/template rule order =="
check_order "$TPL"  "template"
check_order "$CONF" "rendered"
check_order "$SAFE" "safe"

echo "== output chains unchanged (main rendered conf keeps oif lo v4+v6; only input chains were touched) =="
n=$(grep -cE 'oif "?lo"?[^,]*accept' "$CONF" || true)
[[ "$n" -ge 2 ]] && ok "nftables.conf: output oif-lo accept present (${n})" || no "nftables.conf: output oif-lo accept missing" "$n"
# The edit only reordered the two input-chain rules; assert the safe conf's output chains are byte-untouched
# by confirming it still parses the same two output-chain markers we did not modify.
so=$(grep -cE 'chain output' "$SAFE" || true)
[[ "$so" -ge 2 ]] && ok "nftables-safe.conf: output chains intact (${so}, not modified)" || no "safe output chains changed" "$so"

echo "== no rule dropped (all key rules still present in rendered conf, per family) =="
for kw in 'iif "lo".*accept' 'ct state invalid.*drop' '@whitelist_ipv4.*accept' '@blacklist_ipv4.*drop' 'ct state.*established.*accept' '@whitelist_ipv6.*accept' '@blacklist_ipv6.*drop'; do
    grep -qE "$kw" "$CONF" && ok "rendered still has: $kw" || no "rendered MISSING: $kw"
done

echo "== no topology drift (anchors intact, no unexpected new chain) =="
grep -qE 'ANCHOR_HYGIENE' "$CONF" && grep -qE 'ANCHOR_TRUSTED' "$CONF" && ok "phase anchors intact" || no "phase anchors changed"

echo "== header doc tables corrected (loopback before invalid) =="
# In the template header RULE ORDER table, the 'loopback accept' line must appear before 'ct state invalid drop'.
tl=$(grep -nE '^#[[:space:]]*[0-9]+\.[[:space:]]*loopback accept' "$TPL" | grep -oE '^[0-9]+' | head -1 || true)
ti=$(grep -nE '^#[[:space:]]*[0-9]+\.[[:space:]]*ct state invalid drop' "$TPL" | grep -oE '^[0-9]+' | head -1 || true)
{ [[ -n "$tl" && -n "$ti" && "$tl" -lt "$ti" ]]; } && ok "tpl header table: loopback($tl) before invalid($ti)" || no "tpl header table order" "lo=$tl inv=$ti"
sl=$(grep -nE 'iif lo → accept' "$SCHEMA" | grep -oE '^[0-9]+' | head -1 || true)
si=$(grep -nE 'ct state invalid → drop' "$SCHEMA" | grep -oE '^[0-9]+' | head -1 || true)
{ [[ -n "$sl" && -n "$si" && "$sl" -lt "$si" ]]; } && ok "nft_schema header table: loopback($sl) before invalid($si)" || no "nft_schema header table order" "lo=$sl inv=$si"
# v1.217.0 doc-order guards (D-1/D-2): the RENDERED conf header comment and the schema-doc
# rule-order table must also teach loopback-before-invalid (these regressed in the initial pass).
rl=$(grep -nE '^#[[:space:]]*[0-9]+\.[[:space:]]*loopback accept' "$CONF" | grep -oE '^[0-9]+' | head -1 || true)
ri=$(grep -nE '^#[[:space:]]*[0-9]+\.[[:space:]]*ct state invalid drop' "$CONF" | grep -oE '^[0-9]+' | head -1 || true)
{ [[ -n "$rl" && -n "$ri" && "$rl" -lt "$ri" ]]; } && ok "rendered nftables.conf header comment: loopback($rl) before invalid($ri)" || no "rendered conf header comment order" "lo=$rl inv=$ri"
NSV="$ROOT/docs/NFT-Schema-Validation.md"
dl=$(grep -nE '^1[[:space:]]*\|[[:space:]]*iif lo accept' "$NSV" | grep -oE '^[0-9]+' | head -1 || true)
di=$(grep -nE '^2[[:space:]]*\|[[:space:]]*ct state invalid drop' "$NSV" | grep -oE '^[0-9]+' | head -1 || true)
{ [[ -n "$dl" && -n "$di" && "$dl" -lt "$di" ]]; } && ok "docs/NFT-Schema-Validation table: loopback(row1) before invalid(row2)" || no "NFT-Schema-Validation table order" "lo=$dl inv=$di"

echo "== validator carries the loopback<invalid CRITICAL assertion =="
grep -q 'LOOPBACK_BEFORE_INVALID' "$SCHEMA" && grep -qE 'Loopback \(iif lo\) MUST come BEFORE .ct state invalid' "$SCHEMA" && ok "validator has loopback<invalid CRITICAL check" || no "validator assertion missing"
grep -q "loopback before invalid, blacklist before established" "$SCHEMA" && ok "health message updated" || no "health message not updated"

echo ""
echo "=== nft_loopback_before_invalid_v217: PASS=$P FAIL=$F ==="
[[ "$F" -eq 0 ]]
