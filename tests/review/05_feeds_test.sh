#!/usr/bin/env bash
# =============================================================================
# NFTBan - Feeds Module Static Review Test
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="05_feeds_test"
# meta:type="test"
# meta:header="Feeds Module Review Test"
# meta:version="1.19.1"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
# meta:description="Automated static checks for the feeds module code review"
# meta:input="Repository source files (static analysis only)"
# meta:output="PASS/FAIL summary to stdout, exit 1 on any failure"
# meta:depends="bash,grep"
# meta:inventory.files="tests/review/05_feeds_test.sh"
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:created_date="2026-02-27"
# meta:updated_date="2026-02-27"
# =============================================================================
#
# Validates the feeds module against the code review checklist in
# /home/commonfolder/NFTBANREVIEW/05_FEEDS/INSTRUCTIONS.md
#
# Checks performed (static analysis only, no network or runtime):
#   1. Feed downloads use HTTPS (no plain HTTP URLs)
#   2. Timeout/retry configuration exists
#   3. IP/CIDR parsing handles comments and empty lines
#   4. Feed enable/disable toggle exists and persists to config
#   5. Error handling for network failures (curl error checks)
#   6. Timer unit exists for scheduled feed updates
#   7. CIDR consolidation is called after feed download
#
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# REPO ROOT DETECTION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Verify we are in the nftban repository
if [[ ! -f "$REPO_ROOT/VERSION" ]]; then
    echo "FATAL: Cannot find VERSION file. Run from repo root or check REPO_ROOT." >&2
    exit 2
fi

# =============================================================================
# SOURCE FILES UNDER TEST
# =============================================================================

FEEDS_CORE="$REPO_ROOT/cli/lib/nftban/core/nftban_feeds.sh"
FEEDS_CLI="$REPO_ROOT/cli/lib/nftban/cli/cmd_feeds.sh"
FEEDS_CONF="$REPO_ROOT/install/config/feeds.conf"
FEEDS_TIMER="$REPO_ROOT/install/systemd/nftban-core-feeds.timer"
FEEDS_SERVICE="$REPO_ROOT/install/systemd/nftban-core-feeds.service"
FEEDS_CIDR_LIB="$REPO_ROOT/cli/lib/nftban/lib/nftban_dataset_cidr.sh"

# =============================================================================
# TEST FRAMEWORK
# =============================================================================

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

check() {
    local description="$1"
    local result="$2"  # 0 = pass, non-zero = fail

    if [[ "$result" -eq 0 ]]; then
        echo "  [PASS] $description"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  [FAIL] $description"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

skip() {
    local description="$1"
    local reason="$2"
    echo "  [SKIP] $description -- $reason"
    SKIP_COUNT=$((SKIP_COUNT + 1))
}

section() {
    echo ""
    echo "==== $1 ===="
}

# =============================================================================
# PRE-FLIGHT: Verify source files exist
# =============================================================================

section "Pre-flight: source file existence"

for f in "$FEEDS_CORE" "$FEEDS_CLI" "$FEEDS_CONF" "$FEEDS_TIMER" "$FEEDS_SERVICE"; do
    label="$(basename "$f") exists"
    if [[ -f "$f" ]]; then
        check "$label" 0
    else
        check "$label" 1
        echo "         FATAL: $f not found -- most checks will fail" >&2
    fi
done

# =============================================================================
# 1. FEED DOWNLOADS USE HTTPS (no plain HTTP URLs)
# =============================================================================

section "1. TLS enforcement -- all feed URLs must use HTTPS"

# 1a. Config file: every FEED_*_URL value must start with https://
if [[ -f "$FEEDS_CONF" ]]; then
    http_urls_in_conf=$(grep -cE '^FEED_[A-Z0-9_]+_URL="http://' "$FEEDS_CONF" || true)
    check "No plain-HTTP feed URLs in feeds.conf" "$http_urls_in_conf"
else
    skip "No plain-HTTP feed URLs in feeds.conf" "feeds.conf not found"
fi

# 1b. Core module: explicit TLS enforcement guard exists
if [[ -f "$FEEDS_CORE" ]]; then
    tls_guard=$(grep -c 'http://' "$FEEDS_CORE" | head -1)
    # The file SHOULD reference http:// only inside a rejection guard (regex match)
    has_reject=$(grep -cE 'Rejecting.*insecure.*HTTP|TLS required' "$FEEDS_CORE" || true)
    check "Core module has TLS rejection guard" "$(( has_reject > 0 ? 0 : 1 ))"
else
    skip "Core module has TLS rejection guard" "nftban_feeds.sh not found"
fi

# 1c. Runtime enforcement: curl is called with -sSL (follows redirects, silent)
if [[ -f "$FEEDS_CORE" ]]; then
    curl_ssl=$(grep -cE 'curl\s+.*-[a-zA-Z]*s[a-zA-Z]*S[a-zA-Z]*L|curl\s+.*-sSL' "$FEEDS_CORE" || true)
    check "curl invoked with -sSL (HTTPS redirect following)" "$(( curl_ssl > 0 ? 0 : 1 ))"
else
    skip "curl invoked with -sSL" "nftban_feeds.sh not found"
fi

# =============================================================================
# 2. TIMEOUT / RETRY CONFIGURATION EXISTS
# =============================================================================

section "2. Timeout and retry configuration"

# 2a. Config file declares FEEDS_DOWNLOAD_TIMEOUT
if [[ -f "$FEEDS_CONF" ]]; then
    has_timeout_conf=$(grep -c 'FEEDS_DOWNLOAD_TIMEOUT' "$FEEDS_CONF" || true)
    check "FEEDS_DOWNLOAD_TIMEOUT defined in feeds.conf" "$(( has_timeout_conf > 0 ? 0 : 1 ))"
else
    skip "FEEDS_DOWNLOAD_TIMEOUT defined in feeds.conf" "feeds.conf not found"
fi

# 2b. Core module uses --connect-timeout with curl
if [[ -f "$FEEDS_CORE" ]]; then
    has_connect_timeout=$(grep -cF -- '--connect-timeout' "$FEEDS_CORE" || true)
    check "curl uses --connect-timeout" "$(( has_connect_timeout > 0 ? 0 : 1 ))"
fi

# 2c. Core module uses --max-time with curl
if [[ -f "$FEEDS_CORE" ]]; then
    has_max_time=$(grep -cF -- '--max-time' "$FEEDS_CORE" || true)
    check "curl uses --max-time" "$(( has_max_time > 0 ? 0 : 1 ))"
fi

# 2d. Max download size limit (DoS prevention)
if [[ -f "$FEEDS_CORE" ]]; then
    has_max_filesize=$(grep -cF -- '--max-filesize' "$FEEDS_CORE" || true)
    check "curl uses --max-filesize (download size limit)" "$(( has_max_filesize > 0 ? 0 : 1 ))"
fi

# 2e. Systemd service has TimeoutStartSec (prevents hung downloads)
if [[ -f "$FEEDS_SERVICE" ]]; then
    has_svc_timeout=$(grep -c 'TimeoutStartSec' "$FEEDS_SERVICE" || true)
    check "Systemd service has TimeoutStartSec" "$(( has_svc_timeout > 0 ? 0 : 1 ))"
fi

# =============================================================================
# 3. IP/CIDR PARSING HANDLES COMMENTS AND EMPTY LINES
# =============================================================================

section "3. IP/CIDR parsing correctness"

if [[ -f "$FEEDS_CORE" ]]; then
    # 3a. Comments (lines starting with #) are stripped
    strips_hash_comments=$(grep -cE "grep -v.*'\\^\\\\s\\*#'" "$FEEDS_CORE" || true)
    check "Parser strips # comment lines" "$(( strips_hash_comments > 0 ? 0 : 1 ))"

    # 3b. Semicolon comments are stripped (grep -v '^\s*;' and sed 's/...;.*//')
    strips_semi_grep=$(grep -c "grep.*[;]" "$FEEDS_CORE" 2>/dev/null || true)
    strips_semi_sed=$(grep -c "sed.*[;]" "$FEEDS_CORE" 2>/dev/null || true)
    strips_semi_total=$((strips_semi_grep + strips_semi_sed))
    check "Parser strips ; comment lines or inline semicolons" "$(( strips_semi_total > 0 ? 0 : 1 ))"

    # 3c. Empty / whitespace-only lines are filtered
    strips_empty=$(grep -cE "grep -v.*'\\^\\\\s\\*\\\$'" "$FEEDS_CORE" || true)
    check "Parser filters empty / whitespace-only lines" "$(( strips_empty > 0 ? 0 : 1 ))"

    # 3d. IPv4 regex extraction exists
    has_ipv4_regex=$(grep -cE 'grep.*-oE.*[0-9].*\\.' "$FEEDS_CORE" || true)
    check "Parser extracts IPv4 addresses/CIDRs via regex" "$(( has_ipv4_regex > 0 ? 0 : 1 ))"

    # 3e. IPv6 extraction exists
    has_ipv6_regex=$(grep -cE 'grep.*-oE.*[0-9a-fA-F:]' "$FEEDS_CORE" || true)
    check "Parser extracts IPv6 addresses/CIDRs" "$(( has_ipv6_regex > 0 ? 0 : 1 ))"

    # 3f. FEEDS_MIN_ENTRIES validation (reject suspiciously small feeds)
    has_min_entries=$(grep -c 'FEEDS_MIN_ENTRIES' "$FEEDS_CORE" || true)
    check "Minimum entry count validation (FEEDS_MIN_ENTRIES)" "$(( has_min_entries > 0 ? 0 : 1 ))"

    # 3g. FEEDS_MAX_ENTRIES truncation (prevent memory exhaustion)
    has_max_entries=$(grep -c 'FEEDS_MAX_ENTRIES' "$FEEDS_CORE" || true)
    check "Maximum entry count truncation (FEEDS_MAX_ENTRIES)" "$(( has_max_entries > 0 ? 0 : 1 ))"
else
    skip "IP/CIDR parsing checks" "nftban_feeds.sh not found"
fi

# =============================================================================
# 4. FEED ENABLE / DISABLE TOGGLE EXISTS AND PERSISTS TO CONFIG
# =============================================================================

section "4. Enable/disable toggle with config persistence"

if [[ -f "$FEEDS_CORE" ]]; then
    # 4a. nftban_feeds_enable function exists
    has_enable_fn=$(grep -c '^nftban_feeds_enable()' "$FEEDS_CORE" || true)
    check "nftban_feeds_enable() function defined" "$(( has_enable_fn > 0 ? 0 : 1 ))"

    # 4b. nftban_feeds_disable function exists
    has_disable_fn=$(grep -c '^nftban_feeds_disable()' "$FEEDS_CORE" || true)
    check "nftban_feeds_disable() function defined" "$(( has_disable_fn > 0 ? 0 : 1 ))"

    # 4c. set_property function persists to .conf.local (survives upgrades)
    has_set_property=$(grep -c '^nftban_feeds_set_property()' "$FEEDS_CORE" || true)
    check "nftban_feeds_set_property() function defined" "$(( has_set_property > 0 ? 0 : 1 ))"

    # 4d. Persistence writes to .conf.local, not feeds.conf
    writes_local_conf=$(grep -c 'conf\.local' "$FEEDS_CORE" || true)
    check "Toggle persists to .conf.local (not default config)" "$(( writes_local_conf > 0 ? 0 : 1 ))"

    # 4e. Enable sets ENABLED=true
    sets_true=$(grep -cE 'set_property.*ENABLED.*true' "$FEEDS_CORE" || true)
    check "Enable sets ENABLED=true via set_property" "$(( sets_true > 0 ? 0 : 1 ))"

    # 4f. Disable sets ENABLED=false
    sets_false=$(grep -cE 'set_property.*ENABLED.*false' "$FEEDS_CORE" || true)
    check "Disable sets ENABLED=false via set_property" "$(( sets_false > 0 ? 0 : 1 ))"

    # 4g. All feeds DISABLED by default in config
    if [[ -f "$FEEDS_CONF" ]]; then
        enabled_true_count=$(grep -cE '^FEED_[A-Z0-9_]+_ENABLED="true"' "$FEEDS_CONF" || true)
        check "All feeds disabled by default in feeds.conf (none set to true)" "$enabled_true_count"
    fi

    # 4h. Master enable switch exists (NFTBAN_FEEDS_ENABLED)
    has_master_switch=$(grep -c 'NFTBAN_FEEDS_ENABLED' "$FEEDS_CORE" || true)
    check "Master enable switch (NFTBAN_FEEDS_ENABLED) checked" "$(( has_master_switch > 0 ? 0 : 1 ))"
else
    skip "Enable/disable toggle checks" "nftban_feeds.sh not found"
fi

# =============================================================================
# 5. ERROR HANDLING FOR NETWORK FAILURES (curl error checks)
# =============================================================================

section "5. Error handling for network failures"

if [[ -f "$FEEDS_CORE" ]]; then
    # 5a. curl exit code is checked (if ! curl ... or curl ... || ...)
    curl_checked=$(grep -cE 'if\s+!?\s*curl|curl.*\|\|' "$FEEDS_CORE" || true)
    check "curl exit code checked (if ! curl / curl || )" "$(( curl_checked > 0 ? 0 : 1 ))"

    # 5b. Failed download logged
    download_fail_log=$(grep -cE 'Download failed' "$FEEDS_CORE" || true)
    check "Download failure logged with feed name" "$(( download_fail_log > 0 ? 0 : 1 ))"

    # 5c. Temp file cleaned up on failure (rm -f "$temp_file")
    temp_cleanup=$(grep -cE 'rm -f.*temp_file' "$FEEDS_CORE" || true)
    check "Temp file cleaned up on download failure" "$(( temp_cleanup > 0 ? 0 : 1 ))"

    # 5d. Last-known-good preservation (staging file pattern)
    has_staging=$(grep -c 'staging' "$FEEDS_CORE" || true)
    check "Staging file pattern for last-known-good preservation" "$(( has_staging > 0 ? 0 : 1 ))"

    # 5e. Atomic rename (mv staging to production)
    has_atomic_mv=$(grep -cE 'mv.*staging.*parsed_file' "$FEEDS_CORE" || true)
    check "Atomic mv from staging to production file" "$(( has_atomic_mv > 0 ? 0 : 1 ))"

    # 5f. Locking prevents concurrent updates
    has_lock=$(grep -c 'flock' "$FEEDS_CORE" || true)
    check "flock-based locking prevents concurrent updates" "$(( has_lock > 0 ? 0 : 1 ))"

    # 5g. Stale lock detection (> 1 hour)
    has_stale_lock=$(grep -cE 'lock_age.*3600|stale.*lock' "$FEEDS_CORE" || true)
    check "Stale lock detection (> 1 hour)" "$(( has_stale_lock > 0 ? 0 : 1 ))"
else
    skip "Error handling checks" "nftban_feeds.sh not found"
fi

# =============================================================================
# 6. TIMER UNIT EXISTS FOR SCHEDULED FEED UPDATES
# =============================================================================

section "6. Timer unit for scheduled feed updates"

# 6a. Timer file exists
if [[ -f "$FEEDS_TIMER" ]]; then
    check "nftban-core-feeds.timer file exists" 0
else
    check "nftban-core-feeds.timer file exists" 1
fi

# 6b. Service file exists
if [[ -f "$FEEDS_SERVICE" ]]; then
    check "nftban-core-feeds.service file exists" 0
else
    check "nftban-core-feeds.service file exists" 1
fi

# 6c. Timer has OnCalendar directive
if [[ -f "$FEEDS_TIMER" ]]; then
    has_oncalendar=$(grep -c 'OnCalendar' "$FEEDS_TIMER" || true)
    check "Timer has OnCalendar schedule" "$(( has_oncalendar > 0 ? 0 : 1 ))"
fi

# 6d. Timer has Persistent=true (catches up after downtime)
if [[ -f "$FEEDS_TIMER" ]]; then
    has_persistent=$(grep -c 'Persistent=true' "$FEEDS_TIMER" || true)
    check "Timer has Persistent=true (catch up after downtime)" "$(( has_persistent > 0 ? 0 : 1 ))"
fi

# 6e. Timer has RandomizedDelaySec (jitter to avoid thundering herd)
if [[ -f "$FEEDS_TIMER" ]]; then
    has_jitter=$(grep -c 'RandomizedDelaySec' "$FEEDS_TIMER" || true)
    check "Timer has RandomizedDelaySec (jitter)" "$(( has_jitter > 0 ? 0 : 1 ))"
fi

# 6f. Service invokes nftban feeds update
if [[ -f "$FEEDS_SERVICE" ]]; then
    has_exec=$(grep -cE 'nftban\s+feeds\s+update' "$FEEDS_SERVICE" || true)
    check "Service ExecStart calls 'nftban feeds update'" "$(( has_exec > 0 ? 0 : 1 ))"
fi

# 6g. Service has security hardening (NoNewPrivileges)
if [[ -f "$FEEDS_SERVICE" ]]; then
    has_hardening=$(grep -c 'NoNewPrivileges=true' "$FEEDS_SERVICE" || true)
    check "Service has NoNewPrivileges=true hardening" "$(( has_hardening > 0 ? 0 : 1 ))"
fi

# 6h. Meta tags reference the timer unit name
if [[ -f "$FEEDS_CORE" ]]; then
    meta_timer=$(grep -c 'nftban-core-feeds.timer' "$FEEDS_CORE" || true)
    check "Core module meta tags reference nftban-core-feeds.timer" "$(( meta_timer > 0 ? 0 : 1 ))"
fi

# =============================================================================
# 7. CIDR CONSOLIDATION CALLED AFTER FEED DOWNLOAD
# =============================================================================

section "7. CIDR consolidation after feed download"

if [[ -f "$FEEDS_CORE" ]]; then
    # 7a. _feeds_merge_cidrs function defined
    has_merge_fn=$(grep -c '_feeds_merge_cidrs()' "$FEEDS_CORE" || true)
    check "_feeds_merge_cidrs() function defined" "$(( has_merge_fn > 0 ? 0 : 1 ))"

    # 7b. CIDR merge is called in the nftables sync path
    merge_called=$(grep -cE '_feeds_merge_cidrs\s' "$FEEDS_CORE" || true)
    check "_feeds_merge_cidrs called during nftables sync" "$(( merge_called > 0 ? 0 : 1 ))"

    # 7c. Shared library delegation (nftban_cidr_merge)
    has_shared_lib=$(grep -c 'nftban_cidr_merge' "$FEEDS_CORE" || true)
    check "Delegates to shared nftban_cidr_merge library when available" "$(( has_shared_lib > 0 ? 0 : 1 ))"

    # 7d. Shared CIDR library file exists
    if [[ -f "$FEEDS_CIDR_LIB" ]]; then
        check "Shared CIDR merge library (nftban_dataset_cidr.sh) exists" 0
    else
        check "Shared CIDR merge library (nftban_dataset_cidr.sh) exists" 1
    fi

    # 7e. aggregate6 preferred (best CIDR aggregation tool)
    has_aggregate6=$(grep -c 'aggregate6' "$FEEDS_CORE" || true)
    check "aggregate6 is checked as preferred CIDR merge tool" "$(( has_aggregate6 > 0 ? 0 : 1 ))"

    # 7f. Pure bash fallback exists when no external tool available
    has_bash_fallback=$(grep -c '_feeds_merge_cidrs_bash' "$FEEDS_CORE" || true)
    check "Pure bash CIDR merge fallback exists" "$(( has_bash_fallback > 0 ? 0 : 1 ))"

    # 7g. IPv4 and IPv6 merged separately
    merge_ipv4=$(grep -cE '_feeds_merge_cidrs.*4' "$FEEDS_CORE" || true)
    merge_ipv6=$(grep -cE '_feeds_merge_cidrs.*6' "$FEEDS_CORE" || true)
    both_families=$(( (merge_ipv4 > 0 && merge_ipv6 > 0) ? 0 : 1 ))
    check "CIDR merge handles IPv4 and IPv6 separately" "$both_families"

    # 7h. sort -u dedup before merge (reduces merge workload)
    has_sort_u=$(grep -cE 'sort -u' "$FEEDS_CORE" || true)
    check "sort -u deduplication before CIDR merge" "$(( has_sort_u > 0 ? 0 : 1 ))"
else
    skip "CIDR consolidation checks" "nftban_feeds.sh not found"
fi

# =============================================================================
# BONUS: IPC integration for bans (from INSTRUCTIONS.md invariants)
# =============================================================================

section "Bonus: IPC integration"

if [[ -f "$FEEDS_CORE" ]]; then
    has_ipc_source=$(grep -c 'nft_ipc' "$FEEDS_CORE" || true)
    check "IPC library (nft_ipc.sh) sourced" "$(( has_ipc_source > 0 ? 0 : 1 ))"

    has_ipc_apply=$(grep -c 'nft_ipc_apply_ruleset' "$FEEDS_CORE" || true)
    check "nft_ipc_apply_ruleset used for atomic reload" "$(( has_ipc_apply > 0 ? 0 : 1 ))"

    has_flush_source=$(grep -c 'flush_source' "$FEEDS_CORE" || true)
    check "IPC flush_source used for feed disable cleanup" "$(( has_flush_source > 0 ? 0 : 1 ))"
fi

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo "================================================================="
echo " FEEDS MODULE REVIEW TEST SUMMARY"
echo "================================================================="
echo "  PASS: $PASS_COUNT"
echo "  FAIL: $FAIL_COUNT"
echo "  SKIP: $SKIP_COUNT"
echo "  TOTAL: $((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))"
echo "================================================================="

if [[ $FAIL_COUNT -gt 0 ]]; then
    echo "  RESULT: FAILED ($FAIL_COUNT check(s) did not pass)"
    echo "================================================================="
    exit 1
else
    echo "  RESULT: ALL CHECKS PASSED"
    echo "================================================================="
    exit 0
fi
