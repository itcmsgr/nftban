#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.186.1 - BotScan pattern-ban IFS word-split guard test
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="botscan_pattern_ban_ifs_v1861_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-14"
# meta:description="Regression guard for the pre-existing BotScan pattern-ban defect: the lib sets a global IFS=\$'\\n\\t' (no space) at source time, so the unquoted 'for pattern_name in \$patterns' over a space-joined list (\" NAME\") kept the leading space, the pattern key lookup missed, and the per-pattern threshold/window/ban-duration were never applied — analyze fell back to defaults (threshold=5/window=60/ban=1800). Effect: threshold=1 single-request patterns (sqlmap, nikto, Log4Shell, webshells) required 5 hits instead of 1 (single-shot probes evaded banning), and high-threshold matches were downgraded to a weaker grey signal. This test uses threshold=1 patterns under the lib's REAL runtime IFS (no manual reset) with the 404-flood path disabled, so a ban can ONLY come from the pattern path — proving useragent AND url-404 pattern bans fire on the FIRST matching hit. Fails before the v1.186.1 fix, passes after."
#
# meta:inventory.files="botscan_pattern_ban_ifs_v1861_test.sh"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars="NFTBAN_DATA_DIR,BOTSCAN_PATTERNS_DIR,BOTSCAN_BATCH_SIGNAL_MODE"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NFTBAN_LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export NFTBAN_LIB_DIR
fail() { echo "FAIL: $*" >&2; exit 1; }
banned_has() { grep -q "\"ip\":\"$1\"" "${NFTBAN_DATA_DIR}/botguard/batch_signals.jsonl" 2>/dev/null; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export NFTBAN_DATA_DIR="$tmp/data" BOTSCAN_SPOOL_DIR="$tmp/spool" \
       BOTSCAN_PATTERNS_DIR="$tmp/patterns" BOTSCAN_STATE_FILE="$tmp/state.db" \
       BOTSCAN_LOG_FILE="$tmp/botscan.log" NFTBAN_CONFIG_DIR="$tmp/noetc" \
       BOTSCAN_ENABLED=true BOTSCAN_BATCH_SIGNAL_MODE=true \
       BOTSCAN_404_THRESHOLD=999    # disable 404-flood → a ban can ONLY be a pattern ban
mkdir -p "$NFTBAN_DATA_DIR/botguard" "$BOTSCAN_SPOOL_DIR" "$BOTSCAN_PATTERNS_DIR"

# useragent + url-404 patterns, each threshold 1.
{
  printf 'BADUA|BadCrawler|useragent|1|60|3600|true|UA pattern\n'
  printf 'WPLOGIN|/wp-login|url-404|1|60|3600|true|url-404 pattern\n'
} > "$BOTSCAN_PATTERNS_DIR/test.patterns"

# One UA-match line (198.51.100.10) + one url-404-match line (198.51.100.11).
{
  printf '198.51.100.10 - - [14/Jun/2026:10:00:00 +0000] "GET /a HTTP/1.1" 200 9 "-" "BadCrawler/1.0"\n'
  printf '198.51.100.11 - - [14/Jun/2026:10:00:00 +0000] "GET /wp-login HTTP/1.1" 404 9 "-" "Mozilla/5.0"\n'
} > "$BOTSCAN_SPOOL_DIR/a.log"

# shellcheck source=/dev/null
source "$NFTBAN_LIB_DIR/core/nftban_botscan.sh"
nftban_botscan_load_config
# IMPORTANT: do NOT reset IFS here — exercise the lib's real runtime IFS=$'\n\t'.
nftban_botscan_process_logs "" 60 >/dev/null 2>&1 || fail "process_logs rc!=0"

banned_has "198.51.100.10" || fail "useragent pattern ban did not fire under runtime IFS (IFS word-split defect)"
banned_has "198.51.100.11" || fail "url-404 pattern ban did not fire under runtime IFS (IFS word-split defect)"

echo "PASS: BotScan pattern bans (useragent + url-404) fire under the lib's runtime IFS"
