#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan - Review 02: Core CIDR Engine Static Analysis Tests
# =============================================================================
# meta:name="02_core_cidr_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Static analysis tests for CIDR consolidation engine review"
# meta:inventory.files="pkg/sync/cidr.go,pkg/sync/cidr_test.go,pkg/netutil/ip.go,pkg/feeds/parser.go,pkg/geoban/geoban.go"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Purpose: Automated static analysis for CIDR engine code review (Chat 02).
#          Validates code structure, test coverage, invariant enforcement,
#          and edge case handling WITHOUT requiring Go compilation or a
#          running system.
#
# Usage:
#   ./tests/review/02_core_cidr_test.sh          # Run from repo root
#
# Exit codes:
#   0 - All checks passed
#   1 - One or more checks failed
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

# Determine repo root (script must be run from repo root or we detect it)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# Key source files under review
CIDR_GO="pkg/sync/cidr.go"
CIDR_TEST="pkg/sync/cidr_test.go"
NFT_GO="pkg/sync/nft.go"
DOC_GO="pkg/sync/doc.go"
NETUTIL_IP="pkg/netutil/ip.go"
FEEDS_PARSER="pkg/feeds/parser.go"
# shellcheck disable=SC2034 # Reserved for future tests
FEEDS_GO="pkg/feeds/feeds.go"
GEOBAN_GO="pkg/geoban/geoban.go"

# Counters
PASS=0
FAIL=0
TOTAL=0

# =============================================================================
# HELPERS
# =============================================================================

check() {
    local description="$1"
    local result="$2"  # 0 = pass, non-zero = fail

    TOTAL=$((TOTAL + 1))
    if [[ "$result" -eq 0 ]]; then
        PASS=$((PASS + 1))
        printf "[PASS] %s\n" "$description"
    else
        FAIL=$((FAIL + 1))
        printf "[FAIL] %s\n" "$description"
    fi
}

section() {
    printf "\n=== %s ===\n\n" "$1"
}

# =============================================================================
# SECTION 1: FILE EXISTENCE
# =============================================================================

section "File Existence"

check "CIDR engine source file exists (pkg/sync/cidr.go)" \
    "$(test -f "$CIDR_GO" && echo 0 || echo 1)"

check "CIDR engine test file exists (pkg/sync/cidr_test.go)" \
    "$(test -f "$CIDR_TEST" && echo 0 || echo 1)"

check "NFTables manager source exists (pkg/sync/nft.go)" \
    "$(test -f "$NFT_GO" && echo 0 || echo 1)"

check "Package doc exists (pkg/sync/doc.go)" \
    "$(test -f "$DOC_GO" && echo 0 || echo 1)"

check "Network utilities exist (pkg/netutil/ip.go)" \
    "$(test -f "$NETUTIL_IP" && echo 0 || echo 1)"

check "Feed parser exists (pkg/feeds/parser.go)" \
    "$(test -f "$FEEDS_PARSER" && echo 0 || echo 1)"

check "GeoBan module exists (pkg/geoban/geoban.go)" \
    "$(test -f "$GEOBAN_GO" && echo 0 || echo 1)"

# =============================================================================
# SECTION 2: META TAG VALIDATION
# =============================================================================

section "Meta Tag Validation"

for f in "$CIDR_GO" "$CIDR_TEST" "$NFT_GO" "$DOC_GO"; do
    if [[ -f "$f" ]]; then
        count=$(grep -c 'meta:inventory\.' "$f" 2>/dev/null || true)
        check "$f has 7 inventory meta tags (found: $count)" \
            "$(test "$count" -ge 7 && echo 0 || echo 1)"
    fi
done

# =============================================================================
# SECTION 3: IPv4/IPv6 SEPARATION (INVARIANT #4)
# =============================================================================

section "IPv4/IPv6 Separation"

# The MergeCIDRs function must separate IPv4 and IPv6 before processing
check "MergeCIDRs separates IPv4 and IPv6 CIDRs" \
    "$(grep -q 'ipv4Cidrs\|ipv4 CIDRs' "$CIDR_GO" && grep -q 'ipv6Cidrs\|ipv6 CIDRs' "$CIDR_GO" && echo 0 || echo 1)"

check "Dedicated IPv4 merge function exists (mergeCIDRsIPv4WithStats)" \
    "$(grep -q 'func mergeCIDRsIPv4WithStats' "$CIDR_GO" && echo 0 || echo 1)"

check "Dedicated IPv6 merge function exists (mergeCIDRsIPv6WithStats)" \
    "$(grep -q 'func mergeCIDRsIPv6WithStats' "$CIDR_GO" && echo 0 || echo 1)"

# Verify ip.To4() check is used to distinguish families
check "IPv4 detection uses ip.To4() check" \
    "$(grep -q 'ip\.To4() != nil' "$CIDR_GO" && echo 0 || echo 1)"

# Verify separate interval types for v4 vs v6
check "Separate ipv4Interval struct defined" \
    "$(grep -q 'type ipv4Interval struct' "$CIDR_GO" && echo 0 || echo 1)"

check "Separate ipv6Interval struct defined" \
    "$(grep -q 'type ipv6Interval struct' "$CIDR_GO" && echo 0 || echo 1)"

# IPv6 uses big.Int (not uint32)
check "IPv6 intervals use big.Int (not uint32)" \
    "$(grep -A2 'type ipv6Interval struct' "$CIDR_GO" | grep -q 'big\.Int' && echo 0 || echo 1)"

# netutil also separates families
check "netutil separates IPv4/IPv6 private ranges" \
    "$(grep -q 'privateIPv4Ranges' "$NETUTIL_IP" && grep -q 'privateIPv6Ranges' "$NETUTIL_IP" && echo 0 || echo 1)"

# =============================================================================
# SECTION 4: CONSOLIDATION / MERGE FUNCTION EXISTS AND IS CALLED
# =============================================================================

section "Consolidation Function Presence and Usage"

check "MergeCIDRs public function exists" \
    "$(grep -q 'func MergeCIDRs(' "$CIDR_GO" && echo 0 || echo 1)"

check "MergeCIDRsSafe public function exists (for untrusted data)" \
    "$(grep -q 'func MergeCIDRsSafe(' "$CIDR_GO" && echo 0 || echo 1)"

check "MergeCIDRsSafe calls FilterProblematicCIDRs before merging" \
    "$(grep -A5 'func MergeCIDRsSafe' "$CIDR_GO" | grep -q 'FilterProblematicCIDRs' && echo 0 || echo 1)"

check "nft.go calls MergeCIDRsSafe for set loading" \
    "$(grep -q 'MergeCIDRsSafe' "$NFT_GO" && echo 0 || echo 1)"

check "rangeToCIDRsIPv4 conversion function exists" \
    "$(grep -q 'func rangeToCIDRsIPv4(' "$CIDR_GO" && echo 0 || echo 1)"

check "rangeToCIDRsIPv6 conversion function exists" \
    "$(grep -q 'func rangeToCIDRsIPv6(' "$CIDR_GO" && echo 0 || echo 1)"

# =============================================================================
# SECTION 5: OVERLAP HANDLING (INVARIANT #2 - No overlaps in output)
# =============================================================================

section "Overlap Detection and Merging"

# The algorithm must sort intervals first
check "IPv4 intervals are sorted before merging (sort.Slice)" \
    "$(grep -A40 'func mergeCIDRsIPv4WithStats' "$CIDR_GO" | grep -q 'sort\.Slice' && echo 0 || echo 1)"

check "IPv6 intervals are sorted before merging (sort.Slice)" \
    "$(grep -A40 'func mergeCIDRsIPv6WithStats' "$CIDR_GO" | grep -q 'sort\.Slice' && echo 0 || echo 1)"

# The merge loop must handle overlapping ranges
check "IPv4 merge loop handles overlapping ranges (next.Start <= current.End+1)" \
    "$(grep -q 'next\.Start <= current\.End+1' "$CIDR_GO" && echo 0 || echo 1)"

# IPv6 merge uses adjacentThreshold comparison
check "IPv6 merge loop handles overlapping ranges (adjacentThreshold)" \
    "$(grep -q 'adjacentThreshold' "$CIDR_GO" && echo 0 || echo 1)"

# Adjacent range merging (current.End + 1 pattern)
check "Adjacent IPv4 ranges are merged (End+1 adjacency check)" \
    "$(grep -q 'current\.End+1' "$CIDR_GO" && echo 0 || echo 1)"

check "Adjacent IPv6 ranges are merged (big.Int Add one)" \
    "$(grep 'adjacentThreshold' "$CIDR_GO" | grep -q 'Add.*big\.NewInt(1)' && echo 0 || echo 1)"

# =============================================================================
# SECTION 6: SORTING COMPLEXITY (INVARIANT #5 - O(n log n) minimum)
# =============================================================================

section "Algorithm Complexity"

# Using sort.Slice guarantees O(n log n)
check "Uses sort.Slice (Go stdlib O(n log n) guaranteed)" \
    "$(grep -c 'sort\.Slice' "$CIDR_GO" | xargs test 2 -le && echo 0 || echo 1)"

# No O(n^2) patterns: nested loops over intervals
# We check there are no double for-loops iterating intervals
nested_loops=$(awk '
    /for.*intervals/ { in_loop++; if (in_loop > 1) found=1 }
    /^[[:space:]]*}/ { if (in_loop > 0) in_loop-- }
    END { print (found ? 1 : 0) }
' "$CIDR_GO")
check "No nested O(n^2) loops over interval arrays" \
    "$nested_loops"

# =============================================================================
# SECTION 7: EDGE CASE TEST COVERAGE
# =============================================================================

section "Edge Case Test Coverage in cidr_test.go"

# Single IP (/32)
check "Test exists for /32 single-host IPv4" \
    "$(grep -q 'SingleHost_IPv4\|/32' "$CIDR_TEST" && echo 0 || echo 1)"

# Single IP (/128)
check "Test exists for /128 single-host IPv6" \
    "$(grep -q 'SingleHost_IPv6\|/128' "$CIDR_TEST" && echo 0 || echo 1)"

# Adjacent ranges
check "Test exists for adjacent IPv4 ranges" \
    "$(grep -q 'Adjacent' "$CIDR_TEST" && echo 0 || echo 1)"

# Overlapping ranges
check "Test exists for overlapping IPv4 ranges" \
    "$(grep -q 'Overlapping' "$CIDR_TEST" && echo 0 || echo 1)"

# Overlapping IPv6
check "Test exists for overlapping IPv6 ranges" \
    "$(grep -q 'IPv6_Overlapping' "$CIDR_TEST" && echo 0 || echo 1)"

# Empty input
check "Test exists for empty input" \
    "$(grep -q 'Empty\|empty' "$CIDR_TEST" && echo 0 || echo 1)"

# Nil input
check "Test exists for nil input" \
    "$(grep -q 'Nil\|nil input' "$CIDR_TEST" && echo 0 || echo 1)"

# Duplicate CIDRs
check "Test exists for duplicate CIDRs" \
    "$(grep -q 'Duplicates\|dedup' "$CIDR_TEST" && echo 0 || echo 1)"

# Mixed IPv4/IPv6
check "Test exists for mixed IPv4/IPv6 input" \
    "$(grep -q 'Mixed' "$CIDR_TEST" && echo 0 || echo 1)"

# Malformed CIDRs
check "Test exists for malformed/invalid CIDRs" \
    "$(grep -q 'Malformed\|invalid\|MalformedCIDRs' "$CIDR_TEST" && echo 0 || echo 1)"

# Supernet containing subnets
check "Test exists for supernet containing subnets" \
    "$(grep -q 'Supernet' "$CIDR_TEST" && echo 0 || echo 1)"

# Large prefix blocks (/8, /9)
check "Test exists for large prefix blocks" \
    "$(grep -q 'LargePrefixes' "$CIDR_TEST" && echo 0 || echo 1)"

# Max aggregation (256 /32s -> /24)
check "Test exists for max aggregation (many /32s)" \
    "$(grep -q 'MaxAggregation\|256' "$CIDR_TEST" && echo 0 || echo 1)"

# Separate (non-overlapping) ranges
check "Test exists for separate non-overlapping ranges (IPv4)" \
    "$(grep -q 'Separate' "$CIDR_TEST" && echo 0 || echo 1)"

check "Test exists for separate non-overlapping ranges (IPv6)" \
    "$(grep -q 'IPv6_Separate' "$CIDR_TEST" && echo 0 || echo 1)"

# =============================================================================
# SECTION 8: MISSING EDGE CASE TESTS (GAPS)
# =============================================================================

section "Edge Case Test Gaps"

# Full range 0.0.0.0/0
has_full_range=$(grep -c '0\.0\.0\.0/0' "$CIDR_TEST" 2>/dev/null || true)
check "Test exists for full IPv4 range (0.0.0.0/0)" \
    "$(test "$has_full_range" -gt 0 && echo 0 || echo 1)"

# 100k+ entries scalability test
has_large_scale=$(grep -cE '(100000|100k|100_000|large.*(scale|entries|CIDRs))' "$CIDR_TEST" 2>/dev/null || true)
check "Test or benchmark exists for 100k+ entries scalability" \
    "$(test "$has_large_scale" -gt 0 && echo 0 || echo 1)"

# Benchmark tests
has_benchmark=$(grep -c 'func Benchmark' "$CIDR_TEST" 2>/dev/null || true)
check "Benchmark test functions exist in cidr_test.go" \
    "$(test "$has_benchmark" -gt 0 && echo 0 || echo 1)"

# FilterProblematicCIDRs tests
has_filter_test=$(grep -c 'FilterProblematicCIDRs\|TestFilter' "$CIDR_TEST" 2>/dev/null || true)
check "Test exists for FilterProblematicCIDRs (bogon filtering)" \
    "$(test "$has_filter_test" -gt 0 && echo 0 || echo 1)"

# MergeCIDRsSafe tests
has_safe_test=$(grep -c 'MergeCIDRsSafe\|TestMergeCIDRsSafe' "$CIDR_TEST" 2>/dev/null || true)
check "Test exists for MergeCIDRsSafe (safe wrapper)" \
    "$(test "$has_safe_test" -gt 0 && echo 0 || echo 1)"

# =============================================================================
# SECTION 9: NO SILENT DROPS (INVARIANT #3)
# =============================================================================

section "No Silent Drops"

# Invalid CIDRs should return errors, not be silently skipped
check "MergeCIDRs returns error on invalid CIDR (not silent)" \
    "$(grep -A20 'func MergeCIDRs(' "$CIDR_GO" | grep -q 'return nil, nil, fmt\.Errorf' && echo 0 || echo 1)"

# FilterProblematicCIDRs tracks stats on filtered entries
check "FilterProblematicCIDRs tracks filtered count in stats" \
    "$(grep -q 'stats\.Filtered++' "$CIDR_GO" && echo 0 || echo 1)"

check "FilterProblematicCIDRs tracks bogon count separately" \
    "$(grep -q 'stats\.Bogon++' "$CIDR_GO" && echo 0 || echo 1)"

check "FilterProblematicCIDRs tracks oversized count separately" \
    "$(grep -q 'stats\.TooLarge++' "$CIDR_GO" && echo 0 || echo 1)"

# nft.go logs when CIDRs are filtered
check "nft.go logs filtered CIDR count for troubleshooting" \
    "$(grep -q 'log\.Printf.*filter\|filterStats.*Filtered' "$NFT_GO" && echo 0 || echo 1)"

# =============================================================================
# SECTION 10: MEMORY SAFETY
# =============================================================================

section "Memory Safety"

check "Memory budget constant defined (DefaultMemoryBudget)" \
    "$(grep -q 'DefaultMemoryBudget' "$CIDR_GO" && echo 0 || echo 1)"

check "Memory budget check function exists (checkMemoryBudget)" \
    "$(grep -q 'func checkMemoryBudget' "$CIDR_GO" && echo 0 || echo 1)"

check "ErrMemoryBudgetExceeded error defined" \
    "$(grep -q 'ErrMemoryBudgetExceeded' "$CIDR_GO" && echo 0 || echo 1)"

check "rangeToCIDRsIPv4 checks memory budget" \
    "$(grep -A30 'func rangeToCIDRsIPv4' "$CIDR_GO" | grep -q 'checkMemoryBudget' && echo 0 || echo 1)"

check "rangeToCIDRsIPv6 checks memory budget" \
    "$(grep -A30 'func rangeToCIDRsIPv6' "$CIDR_GO" | grep -q 'checkMemoryBudget' && echo 0 || echo 1)"

# MinAllowedPrefixLen prevents absurdly large CIDRs
check "MinAllowedPrefixLen defined to cap maximum range size" \
    "$(grep -q 'MinAllowedPrefixLen' "$CIDR_GO" && echo 0 || echo 1)"

# =============================================================================
# SECTION 11: BOGON FILTERING
# =============================================================================

section "Bogon/Reserved Range Filtering"

check "BogonPrefixes list defined" \
    "$(grep -q 'BogonPrefixes' "$CIDR_GO" && echo 0 || echo 1)"

# Verify key bogon ranges are included
for bogon in "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" "127.0.0.0/8" "169.254.0.0/16" "224.0.0.0/4" "240.0.0.0/4"; do
    check "Bogon list includes $bogon" \
        "$(grep -q "$bogon" "$CIDR_GO" && echo 0 || echo 1)"
done

check "bogonNets cache is initialized at startup (init())" \
    "$(grep -q 'func init()' "$CIDR_GO" && grep -A5 'func init()' "$CIDR_GO" | grep -q 'bogonNets' && echo 0 || echo 1)"

# =============================================================================
# SECTION 12: FEED PARSER IPv4/IPv6 CONSISTENCY
# =============================================================================

section "Feed Parser IPv4/IPv6 Consistency"

check "Feed parser detects IPv4 via To4() != nil" \
    "$(grep -q 'To4() != nil' "$FEEDS_PARSER" && echo 0 || echo 1)"

check "Feed parser normalizes CIDRs with net.ParseCIDR" \
    "$(grep -q 'net\.ParseCIDR' "$FEEDS_PARSER" && echo 0 || echo 1)"

check "Feed parser handles IP ranges (dash notation)" \
    "$(grep -q 'strings.Contains.*"-"' "$FEEDS_PARSER" && echo 0 || echo 1)"

check "Feed parser has OOM protection for range expansion (maxExpand)" \
    "$(grep -q 'maxExpand' "$FEEDS_PARSER" && echo 0 || echo 1)"

# =============================================================================
# SECTION 13: GEOBAN CIDR INTEGRATION
# =============================================================================

section "GeoBan CIDR Integration"

check "GeoBan uses feeds.ParseFeedLine for CIDR parsing" \
    "$(grep -q 'feeds\.ParseFeedLine' "$GEOBAN_GO" && echo 0 || echo 1)"

check "GeoBan separates IPv4 and IPv6 entries (AddIPv4/AddIPv6)" \
    "$(grep -q 'AddIPv4\|data\.AddIPv4' "$GEOBAN_GO" && grep -q 'AddIPv6\|data\.AddIPv6' "$GEOBAN_GO" && echo 0 || echo 1)"

check "GeoBan logs warnings on invalid CIDRs (not silent)" \
    "$(grep -q 'WARNING.*invalid CIDR\|WARNING.*Failed' "$GEOBAN_GO" && echo 0 || echo 1)"

# =============================================================================
# SECTION 14: NETUTIL VALIDATION
# =============================================================================

section "Netutil IP Validation"

check "netutil provides IsIPv4 function" \
    "$(grep -q 'func IsIPv4(' "$NETUTIL_IP" && echo 0 || echo 1)"

check "netutil provides IsIPv6 function" \
    "$(grep -q 'func IsIPv6(' "$NETUTIL_IP" && echo 0 || echo 1)"

check "netutil provides IsCIDR validation" \
    "$(grep -q 'func IsCIDR(' "$NETUTIL_IP" && echo 0 || echo 1)"

check "netutil provides ValidateAndNormalizeIP for list loading" \
    "$(grep -q 'func ValidateAndNormalizeIP(' "$NETUTIL_IP" && echo 0 || echo 1)"

check "netutil provides NormalizeIP for consistent map keys" \
    "$(grep -q 'func NormalizeIP(' "$NETUTIL_IP" && echo 0 || echo 1)"

# =============================================================================
# SECTION 15: NFT.GO CIDR RANGE-AWARE OPERATIONS
# =============================================================================

section "NFT Manager Range-Aware Operations"

check "nft.go has IPv4 interval set helper (ipv4ToUint32)" \
    "$(grep -q 'func ipv4ToUint32(' "$NFT_GO" && echo 0 || echo 1)"

check "nft.go has IPv6 interval set helper (ipv6ToBytes16)" \
    "$(grep -q 'func ipv6ToBytes16(' "$NFT_GO" && echo 0 || echo 1)"

check "nft.go has IPv6 increment helper (ipv6Inc)" \
    "$(grep -q 'func ipv6Inc(' "$NFT_GO" && echo 0 || echo 1)"

check "nft.go has IPv6 decrement helper (ipv6Dec)" \
    "$(grep -q 'func ipv6Dec(' "$NFT_GO" && echo 0 || echo 1)"

check "nft.go has IPv6 compare helper (ipv6Compare)" \
    "$(grep -q 'func ipv6Compare(' "$NFT_GO" && echo 0 || echo 1)"

check "nft.go creates interval sets with auto-merge flag" \
    "$(grep -q 'auto-merge' "$NFT_GO" && echo 0 || echo 1)"

check "DeleteFromIntervalSetCLI handles range splitting" \
    "$(grep -q 'func.*DeleteFromIntervalSetCLI\|splitRangeAndRemoveIP' "$NFT_GO" && echo 0 || echo 1)"

check "IPv6 range-aware deletion exists (deleteFromIntervalSetIPv6)" \
    "$(grep -q 'func.*deleteFromIntervalSetIPv6' "$NFT_GO" && echo 0 || echo 1)"

# =============================================================================
# SECTION 16: TEST FUNCTION COUNT
# =============================================================================

section "Test Coverage Summary"

test_count=$(grep -c '^func Test' "$CIDR_TEST" 2>/dev/null || true)
check "cidr_test.go has at least 15 test functions (found: $test_count)" \
    "$(test "$test_count" -ge 15 && echo 0 || echo 1)"

# Check for table-driven tests (indicates thorough testing)
has_table_driven=$(grep -c 'testCases\|tc\.name\|t\.Run' "$CIDR_TEST" 2>/dev/null || true)
check "cidr_test.go uses table-driven tests (found: $has_table_driven references)" \
    "$(test "$has_table_driven" -gt 0 && echo 0 || echo 1)"

# =============================================================================
# SUMMARY
# =============================================================================

printf "\n%s\n" "=============================================="
printf "REVIEW 02 - CORE CIDR ENGINE STATIC ANALYSIS\n"
printf "%s\n" "=============================================="
printf "Total checks : %d\n" "$TOTAL"
printf "Passed       : %d\n" "$PASS"
printf "Failed       : %d\n" "$FAIL"
printf "%s\n" "=============================================="

if [[ "$FAIL" -gt 0 ]]; then
    printf "\nRESULT: FAIL (%d check(s) failed)\n" "$FAIL"
    exit 1
else
    printf "\nRESULT: PASS (all %d checks passed)\n" "$TOTAL"
    exit 0
fi
