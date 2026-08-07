#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.196.0 - CI Gate: IPv4 / IPv6 parity (PR-F)
# =============================================================================
# meta:name="check-ipv4-ipv6-parity"
# meta:type="script"
# meta:version="1.196.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Static guard: every nft set/check that exists for one IP family must exist for the other. Asserts both ip+ip6 nftban tables present, that the canonical set inventory of table ip nftban equals table ip6 nftban (handling _ipv4/_ipv6 + http_bot_X/X6 + unsuffixed service-port conventions), and that family-sensitive matrix fixtures assert both families (or carry an explicit PARITY-GUARD-EXEMPT marker). Read-only, static. Exit 0 = parity holds, 1 = mismatch."
# meta:inventory.files="install/nftables/nftables.conf,cli/lib/nftban/tests/protection_claim_matrix_v194.tsv"
# meta:inventory.binaries="bash,awk,grep,sort,comm"
# meta:inventory.env_vars="PARITY_NFT_CONF,PARITY_MATRIX"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NFTCONF="${PARITY_NFT_CONF:-$REPO_ROOT/install/nftables/nftables.conf}"
MATRIX="${PARITY_MATRIX:-$REPO_ROOT/cli/lib/nftban/tests/protection_claim_matrix_v194.tsv}"
FAIL=0
echo "========================================"
echo "NFTBan IPv4/IPv6 parity guard (PR-F)"
echo "========================================"
[[ -f "$NFTCONF" ]] || { echo "::error::nftables.conf not found: $NFTCONF"; exit 1; }

# --- R1: both family tables present -----------------------------------------
for fam in ip ip6; do
    if grep -qE "^table $fam nftban \{" "$NFTCONF"; then
        echo "  [OK] table $fam nftban present"
    else
        echo "::error::missing table: $fam nftban"; FAIL=1
    fi
done

# Extract set names from a populated table block. The block opener is the
# 'table <fam> nftban {' line with nothing after the brace (the empty stubs
# 'table ip nftban { }' are skipped); the block closes at a column-0 '}'.
extract_sets() {
    awk -v want="$1" '
        $0 ~ ("^table " want " nftban \\{[[:space:]]*$") { intbl=1; next }
        intbl && /^\}/ { intbl=0 }
        intbl && /^[[:space:]]*set [a-z0-9_]+ \{/ {
            line=$0; sub(/^[[:space:]]*set /, "", line); sub(/ \{.*/, "", line); print line
        }
    ' "$NFTCONF" | sort -u
}

# Canonicalize a set name to a family-neutral base, covering all 4 conventions:
#   *_ipv4 / *_ipv6  -> strip suffix          (blacklist_ipv4 -> blacklist)
#   http_bot_X / X6  -> strip trailing 6      (http_bot_ban6  -> http_bot_ban)
#   *_v4 / *_v6      -> strip suffix          (syn_meter_v4   -> syn_meter)
#                       (v1.228.6: the base rate limiters became NAMED dynamic
#                        sets — as meters they were invisible to this guard;
#                        their historical names carry the _v4/_v6 convention)
#   unsuffixed       -> unchanged             (tcp_ports_in   -> tcp_ports_in)
canon() {
    local s b
    while read -r s; do
        [[ -z "$s" ]] && continue
        b="${s%_ipv4}"; b="${b%_ipv6}"
        b="${b%_v4}"; b="${b%_v6}"
        case "$b" in http_bot_*) b="${b%6}";; esac
        printf '%s\n' "$b"
    done | sort -u
}

# Deliberate single-family sets as canonical:family pairs, each carrying the
# recorded decision that justifies the asymmetry. An entry here is a DESIGN
# STATEMENT, not a waiver: the guard verifies the set exists in EXACTLY its
# declared family (a singleton growing an undeclared partner, or appearing in
# the wrong family, still fails), and the capacity-policy manifest row for the
# same object must say the same thing.
#   syn_prefix_meter:ip6 — /64-aggregate SYN pressure exists only for IPv6 by
#   design (v4 prefix pressure is handled by ddos_prefix_syn when the DDoS
#   module is enabled); manifest row: "no v4 counterpart by design".
PARITY_SINGLETONS='syn_prefix_meter:ip6'

# --- R2a: explicit *_ipv4 <-> *_ipv6 suffix parity --------------------------
v4suf=$(grep -oE 'set [a-z0-9_]+_ipv4' "$NFTCONF" | sed 's/set //; s/_ipv4$//' | sort -u)
v6suf=$(grep -oE 'set [a-z0-9_]+_ipv6' "$NFTCONF" | sed 's/set //; s/_ipv6$//' | sort -u)
if [[ "$v4suf" == "$v6suf" ]]; then
    echo "  [OK] *_ipv4 <-> *_ipv6 suffix sets balanced ($(echo "$v4suf" | grep -c . ) pairs)"
else
    echo "::error::_ipv4/_ipv6 suffix mismatch:"; comm -3 <(echo "$v4suf") <(echo "$v6suf") | sed 's/^/      /'; FAIL=1
fi

# --- R2b: full table set inventory parity (canonical) -----------------------
v4canon=$(extract_sets ip  | canon)
v6canon=$(extract_sets ip6 | canon)
# Each declared singleton must exist in EXACTLY its declared family; only then
# is it excluded from the two-sided comparison. Stripping blindly from both
# sides would delete the evidence of a singleton that grew an undeclared
# partner — the falsifiability harness proved that exact blindness.
for entry in $PARITY_SINGLETONS; do
    sname="${entry%%:*}"; sfam="${entry##*:}"
    # grep -c exits 1 on a zero count, which set -e would turn into a silent
    # death of the whole guard — the zero is a VALUE here, not a failure.
    in4=$(grep -cxF "$sname" <<<"$v4canon" || true); in6=$(grep -cxF "$sname" <<<"$v6canon" || true)
    case "$sfam" in
        ip)  want4=1; want6=0 ;;
        ip6) want4=0; want6=1 ;;
        *)   echo "::error::PARITY_SINGLETONS entry '$entry' has unknown family"; FAIL=1; continue ;;
    esac
    if [[ "$in4" -eq "$want4" && "$in6" -eq "$want6" ]]; then
        echo "  [OK] declared singleton '$sname' present only in $sfam"
    else
        echo "::error::declared singleton '$sname' family mismatch: in_ip=$in4 in_ip6=$in6 (declared $sfam-only)"
        FAIL=1
    fi
    v4canon=$(grep -vxF "$sname" <<<"$v4canon" || true)
    v6canon=$(grep -vxF "$sname" <<<"$v6canon" || true)
done
if [[ "$v4canon" == "$v6canon" ]]; then
    echo "  [OK] table ip nftban and ip6 nftban have matching canonical set inventories ($(echo "$v4canon" | grep -c .) sets each)"
else
    echo "::error::ip/ip6 table set inventory mismatch (canonical):"
    echo "    only in ip (no ip6 counterpart):";  comm -23 <(echo "$v4canon") <(echo "$v6canon") | sed 's/^/      /'
    echo "    only in ip6 (no ip counterpart):";  comm -13 <(echo "$v4canon") <(echo "$v6canon") | sed 's/^/      /'
    FAIL=1
fi

# --- R3: matrix fixtures must cover BOTH families (or be explicitly exempt) ---
# A fixture that asserts an IPv4 literal must also assert an IPv6 literal, unless
# it carries a '# PARITY-GUARD-EXEMPT: ...' marker documenting it is family-agnostic
# at runtime but single-family in test coverage (recorded debt, never silent).
if [[ -f "$MATRIX" ]]; then
    mapfile -t FIX < <(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$MATRIX" | awk -F'|' '$9 ~ /_test\.(sh|go)$/ {print $9}' | sort -u)
    fix_ok=0; fix_exempt=0
    for fx in "${FIX[@]}"; do
        if [[ "$fx" == *_test.sh ]]; then fp="$REPO_ROOT/cli/lib/nftban/tests/$fx"; else fp="$REPO_ROOT/$fx"; fi
        [[ -f "$fp" ]] || continue
        if grep -qE '#[[:space:]]*PARITY-GUARD-EXEMPT' "$fp"; then fix_exempt=$((fix_exempt+1)); continue; fi
        v4=$(grep -cE '\b[0-9]{1,3}(\.[0-9]{1,3}){3}\b' "$fp" || true)
        # IPv6 literal: '::' compressed form OR 4+ hex:hex groups (avoids HH:MM:SS timestamps).
        v6=$(grep -cE '::[0-9a-fA-F]|[0-9a-fA-F]:[0-9a-fA-F]*::|([0-9a-fA-F]{1,4}:){4,}' "$fp" || true)
        if [[ "$v4" -gt 0 && "$v6" -eq 0 ]]; then
            echo "::error::fixture $fx asserts IPv4 but has no IPv6 case and no '# PARITY-GUARD-EXEMPT' marker"; FAIL=1
        else
            fix_ok=$((fix_ok+1))
        fi
    done
    echo "  [OK] matrix fixtures family-checked: $fix_ok dual-family, $fix_exempt explicitly exempt"
fi

echo "========================================"
if [[ "$FAIL" -eq 0 ]]; then echo "RESULT: PASS — IPv4/IPv6 parity holds"; exit 0; fi
echo "RESULT: FAIL — IPv4/IPv6 parity violation (see ::error:: above)"; exit 1
