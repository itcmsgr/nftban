#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.119 A1 cmd_blacklist list dual-set query (D2 fix)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cmd_blacklist_list_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-18"
# meta:description="V116 §7 Test 9 — asserts nftban_blacklist_list queries BOTH blacklist_ipv4 (interval) AND blacklist_manual_ipv4 (hash) and merges results. Pre-V119 only blacklist_ipv4 was queried, silently hiding all blacklist_manual_ipv4 entries."
# meta:input="None (self-contained sandbox with stubbed nft)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,grep,sort"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,sort"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_TABLE_IPV4,NFTBAN_TABLE_IPV6,NFTBAN_BLACKLIST_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Purpose: Cover the v1.119 A1 D2 fix in cli/lib/nftban/cli/cmd_blacklist.sh
#   nftban_blacklist_list — query both blacklist_ipv4 (interval, CIDRs from
#   feeds/geoban) AND blacklist_manual_ipv4 (hash, single-IP manual bans),
#   merge results, deduplicate. Mirrors canonical cmd_list.sh pattern.
#
# Sandbox: stubs `nft list set` via a fake binary on PATH that returns
# pre-canned `elements = { ... }` output per set name. No real nftables
# touch, no daemon contact.
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
NFTBAN_LIB_DIR="${REPO_ROOT}/cli/lib/nftban"
export NFTBAN_LIB_DIR

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

# =============================================================================
# nft stub — returns fixture output per set name; treats unknown sets as ENOENT
# =============================================================================
NFT_STUB="$SANDBOX/bin/nft"
mkdir -p "$SANDBOX/bin"
cat > "$NFT_STUB" <<'STUB_EOF'
#!/usr/bin/env bash
# Args we expect: `list set <family> <table> <setname>` OR
# `list set '<family> <table>' <setname>` (depending on caller's IFS).
# We only handle the `list set` form; everything else exits 1 (set absent).
# The setname is always the LAST positional arg.
if [[ "$1" == "list" && "$2" == "set" ]]; then
    # shellcheck disable=SC2124
    setname="${!#}"
    fixture="${NFTBAN_NFT_FIXTURE_DIR:-/dev/null}/${setname}.fixture"
    if [[ -f "$fixture" ]]; then
        cat "$fixture"
        exit 0
    fi
fi
exit 1
STUB_EOF
chmod +x "$NFT_STUB"
export PATH="$SANDBOX/bin:$PATH"

# Fixture directory for per-set canned output
FIXTURE_DIR="$SANDBOX/fixtures"
mkdir -p "$FIXTURE_DIR"
export NFTBAN_NFT_FIXTURE_DIR="$FIXTURE_DIR"

# Required env for the function-under-test
export NFTBAN_TABLE_IPV4="ip nftban"
export NFTBAN_TABLE_IPV6="ip6 nftban"
export NFTBAN_BLACKLIST_DIR="$SANDBOX/etc/blacklist.d"
mkdir -p "$NFTBAN_BLACKLIST_DIR"

write_fixture() {
    local set_name="$1"
    local elements="$2"
    cat > "${FIXTURE_DIR}/${set_name}.fixture" <<EOF
table ip nftban {
    set ${set_name} {
        elements = { ${elements} }
    }
}
EOF
}

clear_fixtures() {
    rm -f "${FIXTURE_DIR}"/*.fixture
}

# Source cmd_blacklist.sh and call the list function under stubbed nft
run_blacklist_list() {
    (
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/cli/cmd_blacklist.sh"
        nftban_blacklist_list
    )
}

PASS=0
FAIL=0
log_pass() { echo "  PASS  $*"; PASS=$((PASS + 1)); }
log_fail() { echo "  FAIL  $*"; FAIL=$((FAIL + 1)); }

# =============================================================================
# F1: V116 §7 Test 9 — both sets queried, both visible
# =============================================================================
echo "F1: blacklist_ipv4 (interval, CIDR) AND blacklist_manual_ipv4 (hash, single-IP) both present"
clear_fixtures
write_fixture "blacklist_ipv4"        "1.2.3.0/24"
write_fixture "blacklist_manual_ipv4" "5.6.7.8"
F1_OUT=$(run_blacklist_list || true)

if echo "$F1_OUT" | grep -qF "1.2.3.0/24"; then
    log_pass "F1: 1.2.3.0/24 from blacklist_ipv4 (interval set) appears in output"
else
    log_fail "F1: 1.2.3.0/24 missing from output (interval set not queried)"
fi
if echo "$F1_OUT" | grep -qF "5.6.7.8"; then
    log_pass "F1: 5.6.7.8 from blacklist_manual_ipv4 (hash set) appears in output (V119 fix)"
else
    log_fail "F1: 5.6.7.8 missing — hash set not queried (this is the pre-V119 regression)"
fi

# =============================================================================
# F2: only blacklist_manual_ipv4 has entries, blacklist_ipv4 empty
# =============================================================================
echo "F2: only hash set populated (single-IP manual bans, no CIDR feeds)"
clear_fixtures
write_fixture "blacklist_ipv4"        ""
write_fixture "blacklist_manual_ipv4" "9.9.9.9, 10.10.10.10"
F2_OUT=$(run_blacklist_list || true)

if echo "$F2_OUT" | grep -qF "9.9.9.9"; then
    log_pass "F2: 9.9.9.9 from blacklist_manual_ipv4 visible"
else
    log_fail "F2: 9.9.9.9 missing"
fi
if echo "$F2_OUT" | grep -qF "10.10.10.10"; then
    log_pass "F2: 10.10.10.10 from blacklist_manual_ipv4 visible"
else
    log_fail "F2: 10.10.10.10 missing"
fi

# =============================================================================
# F3: deduplication when same IP appears in both sets (defensive — shouldn't
#     happen in production, but verifies sort -u behavior)
# =============================================================================
echo "F3: same IP in both sets → deduplicated"
clear_fixtures
write_fixture "blacklist_ipv4"        "1.2.3.4"
write_fixture "blacklist_manual_ipv4" "1.2.3.4"
F3_OUT=$(run_blacklist_list || true)
count=$(echo "$F3_OUT" | grep -cF "1.2.3.4")
if [[ "$count" -eq 1 ]]; then
    log_pass "F3: 1.2.3.4 appears exactly once after merge (sort -u)"
else
    log_fail "F3: 1.2.3.4 appears $count times (expected 1)"
fi

# =============================================================================
# F4: both sets empty → "(empty)" message
# =============================================================================
echo "F4: both sets exist but contain no elements"
clear_fixtures
write_fixture "blacklist_ipv4"        ""
write_fixture "blacklist_manual_ipv4" ""
F4_OUT=$(run_blacklist_list || true)
if echo "$F4_OUT" | grep -q "(empty)"; then
    log_pass "F4: '(empty)' marker shown when both sets are empty"
else
    log_fail "F4: '(empty)' marker missing"
fi

# =============================================================================
# F5: neither set exists → "(not available)" message
# =============================================================================
echo "F5: nft list set returns non-zero for both sets (no nftables table)"
clear_fixtures
F5_OUT=$(run_blacklist_list || true)
if echo "$F5_OUT" | grep -q "(not available)"; then
    log_pass "F5: '(not available)' marker shown when no sets exist"
else
    log_fail "F5: '(not available)' marker missing"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "─────────────────────────────────────────────"
echo "Total: PASS=$PASS  FAIL=$FAIL"
echo "─────────────────────────────────────────────"
exit $(( FAIL > 0 ? 1 : 0 ))
