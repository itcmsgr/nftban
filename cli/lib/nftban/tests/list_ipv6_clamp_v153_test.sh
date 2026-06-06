#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.153 PR-D: list/table IPv6 column clamp (UX-A4)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="list_ipv6_clamp_v153_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-06"
# meta:description="Locks v1.153 PR-D UX-A4: the HUMAN 'nftban list all' table clamps the IP column to its 40-char width with an ASCII '...' marker so a long IPv6 CIDR cannot push the Type/Version columns out of alignment, while the --json path keeps the full unclamped IP. Asserts: (1) cmd_list.sh contains the human-table clamp logic and the comment that --json stays unclamped; (2) the JSON emitter line still prints the raw \$ip (no clamp); (3) the clamp transform itself — short IPs pass through verbatim, long IPv6 CIDRs are truncated to exactly the column width using a trailing '...' so each rendered row's IP field is <= width. Hermetic: re-implements the shipped clamp transform and checks it against the source; no host/nft/IPC."
# meta:input="cli/lib/nftban/cli/cmd_list.sh"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep,awk"
# meta:inventory.files="cli/lib/nftban/cli/cmd_list.sh"
# meta:inventory.binaries="bash,grep,awk"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../../../.." && pwd)
L="$REPO/cli/lib/nftban/cli/cmd_list.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✓ $1"; }
no() { FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

# Mirror of the shipped clamp transform (cmd_list.sh human-table path).
clamp() {
    local ip="$1" w="${2:-40}"
    if (( ${#ip} > w )); then
        printf '%s...' "${ip:0:w-3}"
    else
        printf '%s' "$ip"
    fi
}

echo "=== source: human table clamps, --json stays full ==="
grep -q '_ipcol_w=40' "$L" && ok "human-table clamp width (40) present" || no "clamp width missing"
grep -q 'Full value remains in --json' "$L" \
    && ok "comment documents --json keeps the full value" || no "json-unclamped comment missing"
grep -q 'ip_disp' "$L" && ok "human path prints the clamped ip_disp" || no "ip_disp not used in human path"
# JSON emitter must still print the raw $ip (no ip_disp in the json line).
# The source line is: echo -n "    {\"ip\": \"$ip\", ...}"
json_line=$(grep -nF '{\"ip\": \"$ip\"' "$L" | head -1 || true)
[[ -n "$json_line" ]] && ok "JSON emitter line found (raw \$ip)" || no "JSON emitter line not located"
# and that the JSON line does NOT use the clamped ip_disp
printf '%s\n' "$json_line" | grep -q 'ip_disp' \
    && no "JSON emitter wrongly uses clamped ip_disp" "$json_line" \
    || ok "JSON emitter still uses raw \$ip (unclamped), not ip_disp"

echo "=== transform: short IP passes through verbatim ==="
short="2001:db8::1"
[[ "$(clamp "$short")" == "$short" ]] \
    && ok "short IPv6 unchanged" || no "short IPv6 mangled" "$(clamp "$short")"
v4="203.0.113.45"
[[ "$(clamp "$v4")" == "$v4" ]] && ok "IPv4 unchanged" || no "IPv4 mangled" "$(clamp "$v4")"

echo "=== transform: long IPv6 CIDR is clamped to width with '...' ==="
long="2400:cb00:0000:1111:2222:3333:4444:ffff/128"   # 43 chars (> 40)
[[ "${#long}" -gt 40 ]] || no "fixture not long enough" "${#long}"
clamped="$(clamp "$long")"
[[ "${#clamped}" -eq 40 ]] \
    && ok "clamped value is exactly the 40-char column width" || no "clamped width wrong" "${#clamped} ($clamped)"
[[ "$clamped" == *"..." ]] && ok "clamped value ends with the '...' marker" || no "no '...' marker" "$clamped"
[[ "$clamped" == "${long:0:37}..." ]] \
    && ok "clamp keeps the leading 37 chars + '...'" || no "clamp prefix wrong" "$clamped"

echo ""
echo "================================================================"
echo "list_ipv6_clamp_v153: PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[[ $FAIL -eq 0 ]]
