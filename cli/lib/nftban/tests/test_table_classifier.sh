#!/usr/bin/env bash
# =============================================================================
# NFTBan PR26.6 / 6C — nft Table Classifier Fixture Test
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="test_table_classifier"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-04-30"
# meta:description="Locks TAKEOVER-PRESERVES-NON-NFTBAN-AUTHORITY-001 — operator-safety tables (e.g. inet ssh_safety) survive rebuild classification"
# meta:inventory.files="cli/lib/nftban/tests/test_table_classifier.sh"
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/core/nftban_table_classify.sh"
if [[ ! -f "$LIB" ]]; then
    echo "FAIL: classifier lib not found at $LIB" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$LIB"

FAIL=0
expect() {
    local got="$1" want="$2" label="$3"
    if [[ "$got" != "$want" ]]; then
        echo "FAIL: $label — got '$got', want '$want'" >&2
        FAIL=1
    else
        echo "PASS: $label ($got)"
    fi
}

# Class 1: NFTBAN_OWNED
expect "$(nftban_classify_table ip   nftban)"                     "$TC_NFTBAN_OWNED" "ip nftban → NFTBAN_OWNED"
expect "$(nftban_classify_table ip6  nftban)"                     "$TC_NFTBAN_OWNED" "ip6 nftban → NFTBAN_OWNED"
expect "$(nftban_classify_table inet nftban_install_emergency)"   "$TC_NFTBAN_OWNED" "inet nftban_install_emergency → NFTBAN_OWNED"

# Class 2: KERNEL_DEFAULT (ip raw / ip6 raw — preserve silently)
expect "$(nftban_classify_table ip   raw)" "$TC_KERNEL_DEFAULT" "ip raw → KERNEL_DEFAULT"
expect "$(nftban_classify_table ip6  raw)" "$TC_KERNEL_DEFAULT" "ip6 raw → KERNEL_DEFAULT"

# Class 3: EXTERNAL_AUTHORITY_GHOST (CSF/firewalld iptables-nft compat)
for spec in "ip filter" "ip6 filter" "ip nat" "ip6 nat" "ip mangle" "ip6 mangle" "ip security" "ip6 security" "inet firewalld" "inet filter"; do
    fam="${spec%% *}"; nm="${spec#* }"
    expect "$(nftban_classify_table "$fam" "$nm")" "$TC_EXTERNAL_AUTHORITY_GHOST" "$spec → EXTERNAL_AUTHORITY_GHOST"
done

# Class 4: OPERATOR_SAFETY (everything else — must include ssh_safety, dns2 evidence)
expect "$(nftban_classify_table inet ssh_safety)"           "$TC_OPERATOR_SAFETY" "inet ssh_safety → OPERATOR_SAFETY (PR26.6 root cause)"
expect "$(nftban_classify_table inet test_operator_safety)" "$TC_OPERATOR_SAFETY" "inet test_operator_safety → OPERATOR_SAFETY"
expect "$(nftban_classify_table ip   custom_ops)"           "$TC_OPERATOR_SAFETY" "ip custom_ops → OPERATOR_SAFETY"
expect "$(nftban_classify_table bridge filter)"             "$TC_OPERATOR_SAFETY" "bridge filter → OPERATOR_SAFETY"
expect "$(nftban_classify_table netdev ingress)"            "$TC_OPERATOR_SAFETY" "netdev ingress → OPERATOR_SAFETY"

# Line-form classifier (nft list tables output shape)
expect "$(nftban_classify_table_line 'table inet ssh_safety')" "$TC_OPERATOR_SAFETY" "line: table inet ssh_safety → OPERATOR_SAFETY"
expect "$(nftban_classify_table_line 'table ip nftban')"       "$TC_NFTBAN_OWNED"    "line: table ip nftban → NFTBAN_OWNED"
expect "$(nftban_classify_table_line 'table ip filter')"       "$TC_EXTERNAL_AUTHORITY_GHOST" "line: table ip filter → EXTERNAL_AUTHORITY_GHOST"
expect "$(nftban_classify_table_line 'table ip raw')"          "$TC_KERNEL_DEFAULT"  "line: table ip raw → KERNEL_DEFAULT"

# Takeover delete predicate
if nftban_table_should_delete_for_takeover ip filter; then
    echo "PASS: takeover deletes ip filter"
else
    echo "FAIL: takeover should delete ip filter (EXTERNAL_AUTHORITY_GHOST)" >&2; FAIL=1
fi
if nftban_table_should_delete_for_takeover inet ssh_safety; then
    echo "FAIL: takeover MUST NOT delete inet ssh_safety (OPERATOR_SAFETY)" >&2; FAIL=1
else
    echo "PASS: takeover preserves inet ssh_safety (PR26.6 invariant)"
fi
if nftban_table_should_delete_for_takeover ip nftban; then
    echo "FAIL: takeover should not nft-delete ip nftban (NFTBAN_OWNED — flushed elsewhere)" >&2; FAIL=1
else
    echo "PASS: takeover does not nft-delete ip nftban (flush-only path)"
fi
if nftban_table_should_delete_for_takeover ip raw; then
    echo "FAIL: takeover should not delete ip raw (KERNEL_DEFAULT)" >&2; FAIL=1
else
    echo "PASS: takeover preserves ip raw (KERNEL_DEFAULT)"
fi

if [[ "$FAIL" -ne 0 ]]; then
    echo ""
    echo "RESULT: FAIL"
    exit 1
fi
echo ""
echo "RESULT: PASS — TAKEOVER-PRESERVES-NON-NFTBAN-AUTHORITY-001 classifier locked"
