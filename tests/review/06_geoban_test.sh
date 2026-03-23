#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.19.1 - GeoBan Code Review Test (Static Analysis)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="06_geoban_test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Static analysis tests for GeoBan module review checklist"
# meta:inventory.files="nftban_geoban.sh,cmd_geoban.sh,geoban.go,nftban_dataset_cidr.sh"
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# Purpose: Automates the review checklist from NFTBANREVIEW/06_GEOBAN
# Scope:   Static analysis only -- no network, no root, no nftables required
#
# Checks:
#   1. Country code validation exists (ISO 3166 alpha-2 format check)
#   2. Case normalization of country codes (uppercase)
#   3. Large country handling (chunking or batch processing for 50k+ CIDRs)
#   4. CIDR consolidation before applying to nftables
#   5. Set size / element limit awareness
#   6. Logging of country-level statistics (count per country)
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# REPO ROOT DETECTION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Verify we are in the nftban repo
if [[ ! -f "${REPO_ROOT}/VERSION" ]]; then
    echo "FATAL: Cannot find VERSION file. Run from the nftban repo root." >&2
    exit 2
fi

# =============================================================================
# SOURCE FILES UNDER TEST
# =============================================================================

SHELL_CORE="${REPO_ROOT}/cli/lib/nftban/core/nftban_geoban.sh"
SHELL_CLI="${REPO_ROOT}/cli/lib/nftban/cli/cmd_geoban.sh"
SHELL_CIDR="${REPO_ROOT}/cli/lib/nftban/lib/nftban_dataset_cidr.sh"
SHELL_EXPORTER="${REPO_ROOT}/cli/lib/nftban/exporters/nftban_geoban_exporter.sh"
GO_GEOBAN="${REPO_ROOT}/internal/geoban/geoban.go"
CONF_GEOBAN="${REPO_ROOT}/etc/nftban/conf.d/geoban/main.conf"
METRICS_REG="${REPO_ROOT}/cli/lib/nftban/data/metrics-registry.json"

# =============================================================================
# PASS / FAIL COUNTERS
# =============================================================================

PASS=0
FAIL=0
TOTAL=0

# =============================================================================
# HELPERS
# =============================================================================

# check <description> <simple_command...>
# Runs a simple (non-piped) command. Exit 0 = PASS, nonzero = FAIL.
check() {
    local desc="$1"
    shift
    TOTAL=$((TOTAL + 1))

    if "$@" >/dev/null 2>&1; then
        PASS=$((PASS + 1))
        printf "  PASS  %s\n" "$desc"
    else
        FAIL=$((FAIL + 1))
        printf "  FAIL  %s\n" "$desc"
    fi
}

# check_eval <description> <shell_expression>
# Evaluates a shell expression (supports pipes, subshells, redirections).
# Exit 0 = PASS, nonzero = FAIL.
check_eval() {
    local desc="$1"
    local expr="$2"
    TOTAL=$((TOTAL + 1))

    if eval "$expr" >/dev/null 2>&1; then
        PASS=$((PASS + 1))
        printf "  PASS  %s\n" "$desc"
    else
        FAIL=$((FAIL + 1))
        printf "  FAIL  %s\n" "$desc"
    fi
}

# =============================================================================
# PREREQUISITE: Verify all source files exist
# =============================================================================

echo "============================================================"
echo " 06_geoban_test.sh - GeoBan Module Static Analysis"
echo "============================================================"
echo ""
echo "--- Prerequisites ---"

check "Shell core module exists: nftban_geoban.sh" \
    test -f "$SHELL_CORE"

check "Shell CLI handler exists: cmd_geoban.sh" \
    test -f "$SHELL_CLI"

check "CIDR merge library exists: nftban_dataset_cidr.sh" \
    test -f "$SHELL_CIDR"

check "Geoban exporter exists: nftban_geoban_exporter.sh" \
    test -f "$SHELL_EXPORTER"

check "Go geoban package exists: geoban.go" \
    test -f "$GO_GEOBAN"

check "Geoban config exists: main.conf" \
    test -f "$CONF_GEOBAN"

echo ""

# =============================================================================
# CHECK 1: Country code validation exists (ISO 3166 alpha-2)
# =============================================================================
# The invariant requires that country codes are validated against the 2-letter
# uppercase ISO 3166-1 alpha-2 format before any processing occurs.
# We look for an explicit regex check like ^[A-Z]{2}$ in both shell and Go.
# =============================================================================

echo "--- Check 1: Country Code Validation (ISO 3166 alpha-2) ---"

# Shell: nftban_geoban_validate_country_code must enforce ^[A-Z]{2}$
check "Shell: validate_country_code function exists" \
    grep -q 'nftban_geoban_validate_country_code' "$SHELL_CORE"

check "Shell: regex enforces exactly 2 uppercase letters ([A-Z]{2})" \
    grep -qE '\[A-Z\]\{2\}' "$SHELL_CORE"

check_eval "Shell: validation rejects non-matching codes (return 1 on failure)" \
    "grep -A10 'nftban_geoban_validate_country_code()' '$SHELL_CORE' | grep -q 'return 1'"

# Go: loadCountry should normalize to uppercase (strings.ToUpper)
check "Go: country code normalization present (strings.ToUpper)" \
    grep -q 'strings.ToUpper' "$GO_GEOBAN"

# Shell: ban_countries calls validate before processing
check_eval "Shell: ban_countries calls validate_country_code before fetch" \
    "grep -A30 'nftban_geoban_ban_countries()' '$SHELL_CORE' | grep -q 'nftban_geoban_validate_country_code'"

# Shell: unban_countries also validates
check_eval "Shell: unban_countries calls validate_country_code" \
    "grep -A30 'nftban_geoban_unban_countries()' '$SHELL_CORE' | grep -q 'nftban_geoban_validate_country_code'"

# Shell: whitelist_countries validates
check_eval "Shell: whitelist_countries calls validate_country_code" \
    "grep -A30 'nftban_geoban_whitelist_countries()' '$SHELL_CORE' | grep -q 'nftban_geoban_validate_country_code'"

# Shell: unwhitelist_countries validates
check_eval "Shell: unwhitelist_countries calls validate_country_code" \
    "grep -A30 'nftban_geoban_unwhitelist_countries()' '$SHELL_CORE' | grep -q 'nftban_geoban_validate_country_code'"

# CLI help references ISO 3166-1 alpha-2
check "CLI: help text mentions ISO 3166 format" \
    grep -qi 'ISO 3166' "$SHELL_CLI"

echo ""

# =============================================================================
# CHECK 2: Case normalization of country codes (uppercase)
# =============================================================================
# All entry points must convert user-supplied country codes to uppercase
# before validation or file operations. This prevents mismatches like
# "cn" != "CN" when looking up ban files named 50-ban-CN.conf.
# =============================================================================

echo "--- Check 2: Case Normalization (Uppercase) ---"

# Shell: tr '[:lower:]' '[:upper:]' in ban path
check_eval "Shell: ban_countries normalizes to uppercase (tr lower upper)" \
    "grep -A30 'nftban_geoban_ban_countries' '$SHELL_CORE' | grep -q \"tr '\[:lower:\]' '\[:upper:\]'\""

# Shell: unban path normalizes
check_eval "Shell: unban_countries normalizes to uppercase" \
    "grep -A30 'nftban_geoban_unban_countries' '$SHELL_CORE' | grep -q \"tr '\[:lower:\]' '\[:upper:\]'\""

# Shell: whitelist path normalizes
check_eval "Shell: whitelist_countries normalizes to uppercase" \
    "grep -A30 'nftban_geoban_whitelist_countries' '$SHELL_CORE' | grep -q \"tr '\[:lower:\]' '\[:upper:\]'\""

# Shell: unwhitelist path normalizes
check_eval "Shell: unwhitelist_countries normalizes to uppercase" \
    "grep -A30 'nftban_geoban_unwhitelist_countries' '$SHELL_CORE' | grep -q \"tr '\[:lower:\]' '\[:upper:\]'\""

# Go: loadCountry uses strings.ToUpper for normalization
check_eval "Go: loadCountry normalizes code to uppercase" \
    "grep -B2 -A5 'func loadCountry' '$GO_GEOBAN' | grep -q 'strings.ToUpper'"

# Shell bash fallback: lowercases for URL (ipdeny requires lowercase)
check "Shell: bash fallback lowercases code for IPDENY URL" \
    grep -qE 'cc_lower=.*\,\,' "$SHELL_CORE"

echo ""

# =============================================================================
# CHECK 3: Large country handling (chunking/batch for 50k+ CIDRs)
# =============================================================================
# Countries like CN (50k+), US (100k+), and RU (30k+) have massive CIDR lists.
# The code must handle these without OOM or timeout. We check for:
#   a) Streaming/buffered file reading (not loading entire file into memory at once)
#   b) Batched nftables element additions OR single atomic operations
#   c) Queue-based async processing to avoid CLI timeout
# =============================================================================

echo "--- Check 3: Large Country Handling (50k+ CIDRs) ---"

# Go: Uses bufio.Scanner for streaming file reads (memory efficient)
check "Go: uses bufio.Scanner for streaming file reads" \
    grep -q 'bufio.NewScanner' "$GO_GEOBAN"

# Shell: builds comma-separated CIDR list for single nft add element command
# (one atomic transaction rather than 50k individual commands)
check "Shell: atomic element addition (single 'add element' command)" \
    grep -q 'add element.*cidr_list' "$SHELL_CORE"

# Shell: uses IPC for nftables operations (avoids fork-per-element overhead)
check "Shell: uses nft_ipc_apply_ruleset for batch application" \
    grep -q 'nft_ipc_apply_ruleset' "$SHELL_CORE"

# Shell: async queue integration (prevents 30s+ CLI hangs with large sets)
check "Shell: queue-based async for nftables sync (nftban_queue_add)" \
    grep -q 'nftban_queue_add' "$SHELL_CORE"

# Shell: comment acknowledges large-set performance concern
check "Shell: architecture comment about large IP set performance" \
    grep -qi '30.*second.*hang' "$SHELL_CORE"

# Go: streaming parsing (no full-file slurp)
check "Go: line-by-line parsing (scanner.Scan loop)" \
    grep -q 'scanner.Scan()' "$GO_GEOBAN"

# Shell: uses mktemp for temp files (safe concurrent processing)
check "Shell: mktemp for temp fragment files (concurrency safe)" \
    grep -q 'mktemp' "$SHELL_CORE"

echo ""

# =============================================================================
# CHECK 4: CIDR consolidation before applying to nftables
# =============================================================================
# Overlapping CIDRs cause nftables "conflicting intervals" errors in interval
# sets. The code MUST merge/consolidate CIDRs before submitting them to nft.
# We verify:
#   a) The shared CIDR merge library (nftban_dataset_cidr.sh) is sourced
#   b) nftban_cidr_merge is invoked before the "add element" command
#   c) The merge library supports multiple methods (aggregate6, netmask, bash)
# =============================================================================

echo "--- Check 4: CIDR Consolidation Before Apply ---"

# Shell: sources the CIDR merge library
check "Shell: sources nftban_dataset_cidr.sh" \
    grep -q 'nftban_dataset_cidr.sh' "$SHELL_CORE"

# Shell: calls nftban_cidr_merge function
check "Shell: calls nftban_cidr_merge for IPv4" \
    grep -q 'nftban_cidr_merge.*4' "$SHELL_CORE"

# Shell: calls nftban_cidr_merge for IPv6
check "Shell: calls nftban_cidr_merge for IPv6" \
    grep -q 'nftban_cidr_merge.*6' "$SHELL_CORE"

# Shell: merge happens BEFORE the "add element" command (section 2b before section 3)
# We verify the merge block (nftban_cidr_merge) appears before "add element"
check_eval "Shell: CIDR merge block appears before nft add element" \
    "test \"\$(grep -n 'nftban_cidr_merge' '$SHELL_CORE' | head -1 | cut -d: -f1)\" -lt \"\$(grep -n 'add element' '$SHELL_CORE' | head -1 | cut -d: -f1)\""

# Shell: logs merge savings (before -> after count)
check "Shell: logs CIDR merge savings (before -> after)" \
    grep -q 'CIDR merge:.*->.*saved' "$SHELL_CORE"

# CIDR lib: supports aggregate6 method
check "CIDR lib: supports aggregate6 tool (best method)" \
    grep -q 'aggregate6' "$SHELL_CIDR"

# CIDR lib: supports netmask fallback
check "CIDR lib: supports netmask fallback (IPv4)" \
    grep -q 'netmask' "$SHELL_CIDR"

# CIDR lib: supports pure bash fallback
check "CIDR lib: supports pure bash fallback" \
    grep -q '_nftban_cidr_merge_bash' "$SHELL_CIDR"

# CIDR lib: double-load prevention guard
check "CIDR lib: has double-load prevention guard" \
    grep -q '_NFTBAN_DATASET_CIDR_LOADED' "$SHELL_CIDR"

echo ""

# =============================================================================
# CHECK 5: Set size / element limit awareness
# =============================================================================
# nftables interval sets have practical limits. The codebase should be aware
# of set element limits. We check for:
#   a) Metrics tracking set sizes (nftban_set_size metric)
#   b) Hard CIDR limit metric (nftban_cidr_limit_hard)
#   c) Timeout flags on sets (auto-expiry prevents unbounded growth)
#   d) Unified blacklist approach (v2.1: single set, not per-country sets)
# =============================================================================

echo "--- Check 5: Set Size / Element Limit Awareness ---"

# Shell: unified blacklist sets (not per-country sets that multiply limits)
check "Shell: uses unified blacklist_ipv4 set (v2.1 architecture)" \
    grep -q 'blacklist_ipv4' "$SHELL_CORE"

check "Shell: uses unified blacklist_ipv6 set (v2.1 architecture)" \
    grep -q 'blacklist_ipv6' "$SHELL_CORE"

# Exporter: tracks set sizes as Prometheus metrics
check "Exporter: collects set sizes (nftban_geoban_ips_blocked)" \
    grep -q 'nftban_geoban_ips_blocked' "$SHELL_EXPORTER"

# Exporter: tracks country count metric
check "Exporter: collects country count metric" \
    grep -q 'nftban_geoban_countries_blocked' "$SHELL_EXPORTER"

# Shell: verifies set existence before adding elements (prevents silent failures)
check "Shell: verifies nft set exists before adding elements" \
    grep -q 'nft list set' "$SHELL_CORE"

# Go: SetData tracks Count field for total elements
check "Go: SetData tracks element Count" \
    grep -q 'Count' "$GO_GEOBAN"

# Shell: CIDR merge reduces element count (consolidation lowers set pressure)
check "Shell: consolidation reduces set element count before apply" \
    grep -q 'saved.*overlaps' "$SHELL_CORE"

# Metrics registry defines nftban_set_size metric
check "Metrics registry: nftban_set_size metric defined" \
    grep -q 'nftban_set_size' "$METRICS_REG"

# Metrics registry defines nftban_cidr_limit_hard metric
check "Metrics registry: nftban_cidr_limit_hard metric defined" \
    grep -q 'nftban_cidr_limit_hard' "$METRICS_REG"

echo ""

# =============================================================================
# CHECK 6: Logging of country-level statistics (count per country)
# =============================================================================
# The observability invariant requires logging how many CIDRs were loaded for
# each country, the final merged count, and summary totals. This enables
# operators to audit geoban effectiveness and catch data source regressions.
# =============================================================================

echo "--- Check 6: Country-Level Statistics Logging ---"

# Shell: logs IPv4 CIDR count per set application
check "Shell: logs IPv4 CIDR count on apply" \
    grep -q 'Adding.*IPv4 CIDRs' "$SHELL_CORE"

# Shell: logs IPv6 CIDR count per set application
check "Shell: logs IPv6 CIDR count on apply" \
    grep -q 'Adding.*IPv6 CIDRs' "$SHELL_CORE"

# Shell: success message includes per-set count
check "Shell: success log includes CIDR count per set" \
    grep -q 'Added.*CIDRs to' "$SHELL_CORE"

# Shell: summary section logs total applied
check "Shell: summary logs total IPv4 CIDRs applied" \
    grep -q 'IPv4:.*cidr_count_v4.*CIDRs' "$SHELL_CORE"

# Shell: logs per-country success/failure in ban loop
check "Shell: logs per-country ban success" \
    grep -q 'Successfully banned' "$SHELL_CORE"

# Shell: logs per-country ban failure
check "Shell: logs per-country ban failure" \
    grep -q 'Failed to ban' "$SHELL_CORE"

# Shell: summary counter (success/failed per operation)
check "Shell: summary shows success/failed counts" \
    grep -q 'succeeded.*failed' "$SHELL_CORE"

# Shell: bash fallback logs download count
check "Shell: bash fallback logs downloaded IP range count" \
    grep -q 'Downloaded.*IPv4 ranges' "$SHELL_CORE"

# Shell: tracking JSON records ipv4_count per country
check "Shell: tracking JSON includes ipv4_count per country" \
    grep -q '"ipv4_count"' "$SHELL_CORE"

# Shell: list command shows per-country IPv4/IPv6 range counts
check "Shell: list command shows per-country range counts" \
    grep -q 'IPv4 ranges' "$SHELL_CORE"

# Shell: CIDR merge logs reduction statistics
check "Shell: CIDR merge logs IPv4 reduction stats" \
    grep -q 'IPv4 CIDR merge:' "$SHELL_CORE"

check "Shell: CIDR merge logs IPv6 reduction stats" \
    grep -q 'IPv6 CIDR merge:' "$SHELL_CORE"

# Shell: audit logging for geoban actions
check "Shell: audit logging for ban actions (nftban_audit_geoban)" \
    grep -q 'nftban_audit_geoban' "$SHELL_CORE"

# Go: stderr warnings for per-country load failures
check "Go: logs per-country load warnings to stderr" \
    grep -q 'WARNING.*Failed to load country' "$GO_GEOBAN"

# Go: Stats struct tracks per-country totals
check "Go: Stats struct tracks Countries + TotalCIDRs" \
    grep -q 'TotalCIDRs' "$GO_GEOBAN"

# Exporter: collection duration metric (observability SLO)
check "Exporter: records collection duration metric" \
    grep -q 'exporter_duration_seconds' "$SHELL_EXPORTER"

echo ""

# =============================================================================
# BONUS: Structural / hygiene checks
# =============================================================================

echo "--- Bonus: Structural Hygiene ---"

# Shell core: has set -Eeuo pipefail
check "Shell core: strict mode (set -Eeuo pipefail)" \
    grep -q 'set -Eeuo pipefail' "$SHELL_CORE"

# Shell CLI: has set -Eeuo pipefail
check "Shell CLI: strict mode (set -Eeuo pipefail)" \
    grep -q 'set -Eeuo pipefail' "$SHELL_CLI"

# CIDR lib: has set -Eeuo pipefail
check "CIDR lib: strict mode (set -Eeuo pipefail)" \
    grep -q 'set -Eeuo pipefail' "$SHELL_CIDR"

# Shell core: 7 inventory meta lines
check_eval "Shell core: has 7 inventory meta lines" \
    "test \"\$(grep -c 'meta:inventory\\.' '$SHELL_CORE')\" -ge 7"

# Shell CLI: 7 inventory meta lines
check_eval "Shell CLI: has 7 inventory meta lines" \
    "test \"\$(grep -c 'meta:inventory\\.' '$SHELL_CLI')\" -ge 7"

# Go: 7 inventory meta lines
check_eval "Go: has 7 inventory meta lines" \
    "test \"\$(grep -c 'meta:inventory\\.' '$GO_GEOBAN')\" -ge 7"

# Shell core: uses IPC (single-writer architecture)
check "Shell core: loads nft_ipc.sh for single-writer architecture" \
    grep -q 'nft_ipc.sh' "$SHELL_CORE"

# Shell CLI: double-load prevention
check "Shell CLI: double-load prevention guard" \
    grep -q 'NFTBAN_CLI_GEOBAN_LOADED' "$SHELL_CLI"

# Shell: mktemp uses XXXXXX pattern (not predictable PID-based names)
check "Shell: mktemp uses XXXXXX template (not PID-based)" \
    grep -q 'mktemp.*XXXXXX' "$SHELL_CORE"

# Shell: apply function has timeout on nft list set
check "Shell: timeout guard on nft list set" \
    grep -q 'timeout.*nft list set' "$SHELL_CORE"

echo ""

# =============================================================================
# SUMMARY
# =============================================================================

echo "============================================================"
echo " SUMMARY"
echo "============================================================"
echo ""
printf "  Total : %d\n" "$TOTAL"
printf "  Pass  : %d\n" "$PASS"
printf "  Fail  : %d\n" "$FAIL"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
    echo "  RESULT: FAIL ($FAIL of $TOTAL checks failed)"
    echo ""
    exit 1
else
    echo "  RESULT: PASS (all $TOTAL checks passed)"
    echo ""
    exit 0
fi
