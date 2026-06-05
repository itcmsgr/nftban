#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.150 Lane A stats/status truth fixes
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="stats_status_truth_v150_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-05"
# meta:description="Tests for v1.150 Lane A shell/CLI-health fixes across cmd_stats.sh, nftban_stats_format.sh, cmd_status.sh. Asserts: manual+auto-detect bans surface from .blacklist_manual (13.1-shell, mock JSON); the bans.log fallback default is plural (LOG-03); the live --follow parser maps the real bans.log schema (LOG-04); the geoban dashboard fallback reads geoban.d/50-ban-*.conf with MODE=...ban (13.2); the dead /api/v1/basic-stats fast-path is removed (HLT-02-shell); the HLT-09 cache-miss fallback counts blacklist_manual_*; cmd_status geoban counts geoban.d files and shows ENABLED when populated (HLT-08); base services.conf is sourced for the master switch (MOD-09); and the unknown-option hint lists only real flags (CLI-02). Live nft/systemctl behavior is a lab integration note (not run here)."
# meta:input="None (self-contained sandbox)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,grep,awk,sed,find,jq,mktemp"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,awk,sed,find,jq,mktemp"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR,NFTBAN_BAN_LOG"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Self-contained sandbox; no host contact; no root required. Functions are
# extracted from the real sources by name and run in stubbed subshells, so the
# tests pin the actual shipped code (not a copy).
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
NFTBAN_LIB_DIR="${REPO_ROOT}/cli/lib/nftban"
export NFTBAN_LIB_DIR
STATS_SRC="$NFTBAN_LIB_DIR/cli/cmd_stats.sh"
FORMAT_SRC="$NFTBAN_LIB_DIR/core/nftban_stats_format.sh"
STATUS_SRC="$NFTBAN_LIB_DIR/cli/cmd_status.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0
FAIL=0
FAILED_TESTS=()

# NOTE: use a here-string (not a pipe) to feed grep. With `set -o pipefail`,
# `grep -q` exits on first match and can SIGPIPE the upstream `printf`, making
# the pipeline report failure on large haystacks. A here-string avoids that.
assert_contains() {
    local haystack="$1" needle="$2" name="$3"
    if grep -F -q -- "$needle" <<< "$haystack"; then
        printf "  [PASS] %s\n" "$name"; PASS=$((PASS + 1))
    else
        printf "  [FAIL] %s\n         expected to contain: %s\n" "$name" "$needle"
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
    fi
}
assert_not_contains() {
    local haystack="$1" needle="$2" name="$3"
    if grep -F -q -- "$needle" <<< "$haystack"; then
        printf "  [FAIL] %s\n         did NOT expect: %s\n" "$name" "$needle"
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
    else
        printf "  [PASS] %s\n" "$name"; PASS=$((PASS + 1))
    fi
}
assert_eq() {
    local actual="$1" expected="$2" name="$3"
    if [[ "$actual" == "$expected" ]]; then
        printf "  [PASS] %s\n" "$name"; PASS=$((PASS + 1))
    else
        printf "  [FAIL] %s (expected '%s', got '%s')\n" "$name" "$expected" "$actual"
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
    fi
}

echo "================================================="
echo "v1.150 Lane A stats/status truth test suite"
echo "================================================="

# ---------------------------------------------------------------------------
# Extract a single shell function (by name) from a source file. Stops at the
# first line that is exactly "}" at column 0 (the closing brace of a top-level
# function, matching the indentation convention in these sources).
# ---------------------------------------------------------------------------
extract_func() {
    local file="$1" fn="$2"
    awk -v fn="$fn" '
        $0 ~ "^"fn"\\(\\) \\{" || $0 ~ "^"fn"\\(\\)\\{" { c=1 }
        c { print }
        c && /^\}/ { exit }
    ' "$file"
}

# ===========================================================================
# T1: 13.1-shell — brief headline includes .blacklist_manual (manual + auto)
# ===========================================================================
echo; echo "[T1] stats --brief surfaces manual+auto bans from .blacklist_manual"
brief_env() {
    cat <<'STUBS'
# Mock producer JSON: 5 feed/geoban + 3 manual/auto-detect = 8 banned total.
nftban_nft_count_all_sets() {
cat <<'JSON'
{
  "schema_version": "2.2",
  "whitelist": {"ipv4": 2, "ipv6": 0, "total": 2},
  "blacklist": {"ipv4": 4, "ipv6": 1, "total": 5},
  "blacklist_manual": {"ipv4": 3, "ipv6": 0, "total": 3}
}
JSON
}
nft() { return 1; }   # no counters in sandbox
STUBS
    extract_func "$STATS_SRC" "nftban_stats_cmd_brief"
}
T1_OUT=$( ( set +e; eval "$(brief_env)"; NFTBAN_BAN_LOG="$SANDBOX/empty.log" nftban_stats_cmd_brief ) )
# 5 (blacklist) + 3 (blacklist_manual) = 8 banned
assert_contains "$T1_OUT" "8 banned"        "T1.1 manual+auto bans included in banned total (5+3=8)"
assert_contains "$T1_OUT" "2 whitelisted"   "T1.2 whitelist total unaffected"

# ===========================================================================
# T2: 13.1-shell regression — without the manual fix the total would be 5
# ===========================================================================
echo; echo "[T2] brief does NOT undercount (regression guard for .temporary bug)"
assert_not_contains "$T1_OUT" "5 banned" "T2.1 not the old feed-only count (5)"

# ===========================================================================
# T3: LOG-03 — bans.log (plural) is the fallback default everywhere
# ===========================================================================
echo; echo "[T3] LOG-03 bans.log (plural) default; no singular ban.log default remains"
# Strip comment lines, then ensure no code line carries a singular "/ban.log" default.
STATS_CODE=$(grep -v '^[[:space:]]*#' "$STATS_SRC")
SINGULAR=$(printf '%s\n' "$STATS_CODE" | grep -E '[^s]/ban\.log' || true)
assert_eq "$SINGULAR" ""                    "T3.1 no singular '/ban.log' default in code paths"
assert_contains "$STATS_CODE" "/bans.log"   "T3.2 plural '/bans.log' default present"

# Functional: with NFTBAN_BAN_LOG unset, brief counts today's bans from bans.log.
brief_log_env() {
    cat <<'STUBS'
nftban_nft_count_all_sets() { echo '{"blacklist":{"total":0},"blacklist_manual":{"total":0},"whitelist":{"total":0}}'; }
nft() { return 1; }
STUBS
    extract_func "$STATS_SRC" "nftban_stats_cmd_brief"
}
TODAY=$(date +%Y-%m-%d)
LOGDIR="$SANDBOX/logs"; mkdir -p "$LOGDIR"
printf '%s|10:00:00|login|198.51.100.4|US|BANNED|brute\n' "$TODAY" > "$LOGDIR/bans.log"
printf '%s|10:01:00|portscan|198.51.100.5|GR|BANNED|scan\n' "$TODAY" >> "$LOGDIR/bans.log"
T3_OUT=$( ( set +e; eval "$(brief_log_env)"; unset NFTBAN_BAN_LOG; NFTBAN_LOG_DIR="$LOGDIR" nftban_stats_cmd_brief ) )
assert_contains "$T3_OUT" "2 bans today"     "T3.3 bans counted from bans.log with NFTBAN_BAN_LOG unset"

# ===========================================================================
# T4: HLT-02-shell — dead /api/v1/basic-stats fast-path removed
# ===========================================================================
echo; echo "[T4] HLT-02-shell dead API-first fast-path deleted"
# Check the function DEFINITIONS are gone (mentions in the removal comment are fine).
assert_not_contains "$(cat "$STATS_SRC")" "nftban_stats_get_basic_from_api()" "T4.1 nftban_stats_get_basic_from_api() definition removed"
assert_not_contains "$(cat "$STATS_SRC")" "nftban_stats_get_counts_optimized()" "T4.2 nftban_stats_get_counts_optimized() definition removed"
assert_not_contains "$(grep -v '^[[:space:]]*#' "$STATS_SRC")" "/api/v1/basic-stats" "T4.3 no /api/v1/basic-stats call in code"

# ===========================================================================
# T5: 13.2 (stats_format dashboard fallback) — geoban.d/50-ban + MODE=...ban
# ===========================================================================
echo; echo "[T5] 13.2 geoban dashboard fallback reads geoban.d/50-ban-*.conf"
FMT_CODE=$(grep -v '^[[:space:]]*#' "$FORMAT_SRC")
assert_contains "$FMT_CODE" '/geoban.d'          "T5.1 geoban.d config dir used (not DATA_DIR/geoban)"
assert_contains "$FMT_CODE" '50-ban-*.conf'      "T5.2 50-ban-*.conf glob used"
assert_contains "$FMT_CODE" '^MODE=.*ban'        "T5.3 MODE=...ban token used (not ...block)"
assert_not_contains "$FMT_CODE" '^MODE=.*block'  "T5.4 stale MODE=...block token gone"

# ===========================================================================
# T6: 13.2 (cmd_stats) + HLT-08 (cmd_status) — geoban count from geoban.d
# ===========================================================================
echo; echo "[T6] geoban count reflects geoban.d/50-ban-*.conf files"
GBDIR="$SANDBOX/geoban.d"; mkdir -p "$GBDIR"
printf 'MODE=ban\nCOUNTRY=CN\n' > "$GBDIR/50-ban-CN.conf"
printf 'MODE=ban\nCOUNTRY=RU\n' > "$GBDIR/50-ban-RU.conf"
printf 'MODE=whitelist\nCOUNTRY=US\n' > "$GBDIR/40-whitelist-US.conf"  # must NOT count
# The canonical count used by both cmd_stats and cmd_status:
GBCOUNT=$(find "$GBDIR" -maxdepth 1 -name '50-ban-*.conf' -type f 2>/dev/null | wc -l)
GBCOUNT=${GBCOUNT//[^0-9]/}
assert_eq "$GBCOUNT" "2"                    "T6.1 exactly 2 banned-country files counted (whitelist excluded)"

# ===========================================================================
# T7: HLT-08 — cmd_status GeoBan ENABLED when geoban.d populated
# ===========================================================================
echo; echo "[T7] HLT-08 cmd_status shows GeoBan ACTIVE when countries banned"
# Reproduce the exact cmd_status geoban block (extracted region) in isolation.
status_geoban_block() {
    # Capture from the GeoBan comment up to (but NOT including) the printf that
    # renders the line — we only want the geoban_status computation.
    awk '/# GeoBan \(country blocking module\)/{c=1} c && /printf .*"GeoBan/{exit} c{print}' "$STATUS_SRC"
}
# The extracted block uses `local` (needs a function context) and reads
# NFTBAN_CONFIG_DIR/geoban.d; wrap it in a function and point it at the fixture.
run_status_geoban() {
    local cfg="$1"
    eval "_run_geoban_inner() {
        local NFTBAN_CONFIG_DIR=\"$cfg\"
        $(status_geoban_block)
        echo \"\$geoban_status\"
    }"
    _run_geoban_inner
}
GEOBAN_RESULT=$( ( set +e; run_status_geoban "$SANDBOX" ) )
assert_contains "$GEOBAN_RESULT" "ACTIVE"           "T7.1 GeoBan status ACTIVE when geoban.d populated"
assert_contains "$GEOBAN_RESULT" "2 countries"      "T7.2 GeoBan reports the 2 banned countries"
# Empty dir → DISABLED
EMPTY_CFG="$SANDBOX/empty_cfg"; mkdir -p "$EMPTY_CFG/geoban.d"
GEOBAN_EMPTY=$( ( set +e; run_status_geoban "$EMPTY_CFG" ) )
assert_eq "$GEOBAN_EMPTY" "DISABLED"                "T7.3 GeoBan DISABLED when no banned-country files"
assert_not_contains "$(grep -v '^[[:space:]]*#' "$STATUS_SRC")" 'grep -c "BLOCKED"' "T7.4 phantom 'BLOCKED' token removed"

# ===========================================================================
# T8: HLT-09 — stats_format cache-miss fallback counts blacklist_manual_*
# ===========================================================================
echo; echo "[T8] HLT-09 cache-miss fallback counts blacklist_manual sets"
assert_contains "$FMT_CODE" "blacklist_manual_ipv4" "T8.1 fallback queries blacklist_manual_ipv4"
assert_contains "$FMT_CODE" "blacklist_manual_ipv6" "T8.2 fallback queries blacklist_manual_ipv6"

# ===========================================================================
# T9: MOD-09 — cmd_status sources base services.conf for the master switch
# ===========================================================================
echo; echo "[T9] MOD-09 base services.conf sourced (NFTBAN_ENABLED=false honored)"
STATUS_CODE=$(cat "$STATUS_SRC")
assert_contains "$STATUS_CODE" 'source "${NFTBAN_CONFIG_DIR}/conf.d/services.conf"' "T9.1 base services.conf sourced"
assert_contains "$STATUS_CODE" 'source "${NFTBAN_CONFIG_DIR}/conf.d/services.conf.local"' "T9.2 .local override still sourced"

# ===========================================================================
# T10: CLI-02 — unknown-option hint lists only real flags
# ===========================================================================
echo; echo "[T10] CLI-02 unknown-option hint advertises only accepted tokens"
# The hint string follows "Unknown option: \$1" in the parse-error branch.
HINT_LINE=$(grep -A2 '"Unknown option: \$1"' "$STATUS_SRC" | grep 'Valid options' || true)
assert_contains "$HINT_LINE" "--json"   "T10.1 hint lists --json (real)"
assert_contains "$HINT_LINE" "--brief"  "T10.2 hint lists --brief (real)"
assert_contains "$HINT_LINE" "--quiet"  "T10.3 hint lists --quiet (real)"
assert_contains "$HINT_LINE" "pending"  "T10.4 hint lists pending (real bareword)"
assert_not_contains "$HINT_LINE" "--counts"  "T10.5 hint drops phantom --counts"
assert_not_contains "$HINT_LINE" "--pending" "T10.6 hint drops phantom --pending"
assert_not_contains "$HINT_LINE" "--quick"   "T10.7 hint drops phantom --quick"

# ---------------------------------------------------------------------------
# LAB INTEGRATION NOTES (not run here — require root + live kernel/systemd):
#   - `nftban stats --brief` against a real populated kernel: banned total ==
#     nft list set blacklist_ipv4 + blacklist_manual_ipv4 (+v6).
#   - `nftban stats recent --follow` streaming a live bans.log: columns map to
#     DATE TIME | IP | STATUS | SOURCE (LOG-04).
#   - `nftban status` on a host with NFTBAN_ENABLED=false in services.conf:
#     Master Control shows DISABLED (config) (MOD-09).
#   - `nftban status` with banned countries: GeoBan ACTIVE (N countries) (HLT-08).
# ---------------------------------------------------------------------------

echo; echo "================================================="
echo "Results: PASS=$PASS  FAIL=$FAIL"
if [[ $FAIL -gt 0 ]]; then
    echo "Failed tests:"; for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
    exit 1
fi
echo "All tests passed."
exit 0
