#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.187.1 - BotScan no-fork parse/match parity test
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="botscan_nofork_parity_v1871_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-14"
# meta:description="v1.187.1 cycle-timeout fix removed the per-line subshell forks in the BotScan main scan loop (parse_line + match_url + timestamp). This proves the new no-fork _g variants are byte-for-byte equivalent to the kept echo-API functions: (P) nftban_botscan_parse_line_g sets _BS_IP/_BS_URL/_BS_METHOD/_BS_STATUS/_BS_UA identically to what nftban_botscan_parse_line echoes, across IPv4/IPv6/bracketed/quoted-UA/no-UA/malformed lines; (M) nftban_botscan_match_url_g sets _BS_MATCHED identically to what nftban_botscan_match_url echoes, across every match_type (url-404/url-post/url-get/url-any/useragent) and the no-match case. Guards the echo API used by cmd_botscan + existing tests against drift."
#
# meta:inventory.files="botscan_nofork_parity_v1871_test.sh"
# meta:inventory.binaries="bash"
# meta:inventory.env_vars="NFTBAN_DATA_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NFTBAN_LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"; export NFTBAN_LIB_DIR
fail() { echo "FAIL: $*" >&2; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export NFTBAN_DATA_DIR="$tmp/data" BOTSCAN_PATTERNS_DIR="$tmp/patterns" \
       BOTSCAN_STATE_FILE="$tmp/s.db" BOTSCAN_LOG_FILE="$tmp/b.log" \
       NFTBAN_CONFIG_DIR="$tmp/noetc" BOTSCAN_ENABLED=true
mkdir -p "$NFTBAN_DATA_DIR" "$BOTSCAN_PATTERNS_DIR"
# shellcheck source=/dev/null
source "$NFTBAN_LIB_DIR/core/nftban_botscan.sh"; nftban_botscan_load_config

# ----------------------------------------------------------------------------
# (P) parse_line: echo API vs no-fork _g, across formats
# ----------------------------------------------------------------------------
parse_lines=(
  '203.0.113.5 - - [14/Jun/2026:10:00:00 +0000] "GET /wp-login.php HTTP/1.1" 404 120 "-" "evilbot/1.0"'
  '2001:db8::1 - - [14/Jun/2026:10:00:00 +0000] "POST /xmlrpc.php HTTP/1.1" 200 5 "-" "Mozilla/5.0"'
  '[2001:db8::2]:8080 - - [x] "HEAD /robots.txt HTTP/1.0" 301 0 "-" "-"'
  '198.51.100.9 - - [x] "GET /noua HTTP/1.1" 500 9'
  'this is not a log line at all'
  ''
)
for line in "${parse_lines[@]}"; do
    # echo API (the authority); rc captured errexit-safe
    echo_out=""; echo_rc=0
    echo_out="$(nftban_botscan_parse_line "$line")" || echo_rc=$?
    # no-fork _g
    g_rc=0
    nftban_botscan_parse_line_g "$line" || g_rc=$?
    # return codes must agree
    [[ "$echo_rc" -eq "$g_rc" ]] || fail "P: rc mismatch echo=$echo_rc g=$g_rc for <$line>"
    if [[ "$g_rc" -eq 0 ]]; then
        g_out="${_BS_IP}|${_BS_URL}|${_BS_METHOD}|${_BS_STATUS}|${_BS_UA}"
        [[ "$g_out" == "$echo_out" ]] || fail "P: field mismatch for <$line>: echo=[$echo_out] g=[$g_out]"
    fi
done
# spot-check exact expected fields (IP|URL|METHOD|STATUS|UA order)
nftban_botscan_parse_line_g '203.0.113.5 - - [x] "GET /a HTTP/1.1" 404 1 "-" "ua x"'
[[ "$_BS_IP" == "203.0.113.5" && "$_BS_URL" == "/a" && "$_BS_METHOD" == "GET" && "$_BS_STATUS" == "404" && "$_BS_UA" == "ua x" ]] \
    || fail "P: explicit field check failed (ip=$_BS_IP url=$_BS_URL m=$_BS_METHOD s=$_BS_STATUS ua=$_BS_UA)"
echo "PASS P: parse_line_g globals == parse_line echo across all formats + explicit fields"

# ----------------------------------------------------------------------------
# (M) match_url: echo API vs no-fork _g, every match_type + no-match
# ----------------------------------------------------------------------------
# def format: pattern<US>match_type<US>threshold<US>window<US>ban<US>desc
# v1.214.0 OPEN_BOTSCAN_PATTERN_DELIMITER_FIX — the internal _BOTSCAN_PATTERNS join/split
# moved from '|' to ASCII Unit Separator (\x1f) so a pattern's own '|' alternation survives
# the downstream re-splits. Build the defs with the module's _BS_US delimiter accordingly.
_us="${_BS_US:-$'\x1f'}"
_BOTSCAN_PATTERNS=(
  [WP_LOGIN]="wp-login${_us}url-404${_us}2${_us}60${_us}3600${_us}wp"
  [XMLRPC]="xmlrpc${_us}url-post${_us}2${_us}60${_us}3600${_us}xr"
  [GITCFG]="\\.git/config${_us}url-get${_us}1${_us}60${_us}86400${_us}git"
  [ANYEVIL]="/evil${_us}url-any${_us}1${_us}60${_us}3600${_us}any"
  [BADUA]="evilbot${_us}useragent${_us}1${_us}60${_us}3600${_us}ua"
)
# cases: url method status ua  -> expected match name ("" = no match)
m_cases=(
  "/wp-login.php|GET|404||WP_LOGIN"        # url-404 hits only on 404
  "/wp-login.php|GET|200||"                # url-404 misses on non-404
  "/xmlrpc.php|POST|200||XMLRPC"           # url-post hits only on POST
  "/xmlrpc.php|GET|200||"                  # url-post misses on GET
  "/x/.git/config|GET|200||GITCFG"        # url-get
  "/x/.git/config|POST|200||"             # url-get misses on POST
  "/evil/thing|HEAD|301||ANYEVIL"         # url-any any method/status
  "/clean|GET|200|evilbot here|BADUA"     # useragent
  "/clean|GET|200|firefox|"               # nothing matches
)
for c in "${m_cases[@]}"; do
    IFS='|' read -r url method status ua expect <<< "$c"
    echo_out=""; echo_rc=0
    echo_out="$(nftban_botscan_match_url "$url" "$method" "$status" "$ua")" || echo_rc=$?
    g_rc=0
    nftban_botscan_match_url_g "$url" "$method" "$status" "$ua" || g_rc=$?
    [[ "$echo_rc" -eq "$g_rc" ]] || fail "M: rc mismatch echo=$echo_rc g=$g_rc for <$c>"
    [[ "$_BS_MATCHED" == "$echo_out" ]] || fail "M: name mismatch for <$c>: echo=[$echo_out] g=[$_BS_MATCHED]"
    if [[ -n "$expect" ]]; then
        [[ "$_BS_MATCHED" == "$expect" && "$g_rc" -eq 0 ]] || fail "M: expected [$expect] got [$_BS_MATCHED] rc=$g_rc for <$c>"
    else
        [[ "$g_rc" -eq 1 && -z "$_BS_MATCHED" ]] || fail "M: expected NO match for <$c> got [$_BS_MATCHED] rc=$g_rc"
    fi
done
echo "PASS M: match_url_g _BS_MATCHED == match_url echo across every match_type + no-match"

echo "PASS: botscan no-fork parse/match parity (v1.187.1)"
