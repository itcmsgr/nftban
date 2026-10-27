#!/usr/bin/env bash
# =============================================================================
# NFTBan - BotScan HTTP campaign detector test
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="botscan_http_campaign_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-26"
# meta:description="Hermetic guard for the BotScan HTTP campaign detector: (T1) query-complexity candidates are counted per site, per IPv4 /24 and per IPv6 address before any per-IP threshold; (T2) below MIN_TERMS, (T3) stale/future request time, (T4) non-GET or status >= 400 are not candidates; (T5) a confirmed campaign under pressure emits campaign_prefix signals only for /24s with >= PREFIX_MIN_SOURCES sources and campaign_member signals for IPv6 sources; (T6) without pressure enforcement is withheld and reported; (T7) below the site thresholds nothing is a campaign; (T8) the source bound overflows visibly and never widens a prefix; (T9) a /24 holding an unverified crawler claim is kept out; (T10) disabled = inert (no counting, no prefilter line); (T11) the prefilter keeps campaign candidates as a superset; (T12) process_entry feeds the counters; (T13) the campaign.enabled marker is published while enabled and withdrawn when BotScan or the campaign is disabled."
#
# meta:inventory.files="botscan_http_campaign_test.sh"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars="NFTBAN_DATA_DIR,BOTSCAN_BATCH_SIGNAL_FILE,BOTSCAN_CAMPAIGN_ENABLED"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# meta:ta.id="botscan_http_campaign_test"
# meta:ta.owner="botscan"
# meta:ta.module="botscan-http-campaign"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -Eeuo pipefail
export BOTSCAN_SHIPPED_PATTERNS_DIR=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NFTBAN_LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"; export NFTBAN_LIB_DIR
fail() { echo "FAIL: $*" >&2; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export NFTBAN_DATA_DIR="$tmp/data" BOTSCAN_PATTERNS_DIR="$tmp/patterns" \
       BOTSCAN_STATE_FILE="$tmp/s.db" BOTSCAN_LOG_FILE="$tmp/b.log" \
       BOTSCAN_BATCH_SIGNAL_FILE="$tmp/sig.jsonl" NFTBAN_CONFIG_DIR="$tmp/noetc" \
       BOTSCAN_EXEMPT_FILE="$tmp/exempt.list" BOTSCAN_USE_GLOBAL_WHITELIST=false \
       BOTSCAN_ENABLED=true BOTSCAN_VERIFY_CRAWLERS=false \
       BOTSCAN_CAMPAIGN_ENABLED=true BOTSCAN_CAMPAIGN_MIN_REQUESTS=50 BOTSCAN_CAMPAIGN_MIN_SOURCES=20
mkdir -p "$NFTBAN_DATA_DIR/botscan" "$BOTSCAN_PATTERNS_DIR"
# shellcheck source=/dev/null
source "$NFTBAN_LIB_DIR/core/nftban_botscan.sh"; nftban_botscan_load_config
nftban_timestamp_unix() { echo 1781517630; }
NOW=1781517630
DEEP='/shop/?filter_cat=11%2C12%2C13&filter_tag=a'   # 2 parameters + 2 %2C separators = 4 terms
SHALLOW='/shop/?filter_cat=11%2C12'                    # 1 parameter + 1 separator = 2 terms

observe() { nftban_botscan_campaign_observe "$1" "$2" "${3:-GET}" "${4:-200}" "${5:-$NOW}" "$NOW"; }
reset() { nftban_botscan_init_state; _BS_CMP_SITE="site.log"; : > "$BOTSCAN_BATCH_SIGNAL_FILE"; }

# Campaign fixture: 25 distinct sources, 4 per /24 in 5 nets (45.33.40-44), plus 5 single-source
# /24s (45.33.50-54) and 2 IPv6 sources; 3 requests each.
campaign() {
    local n h i
    for n in 40 41 42 43 44; do for h in 1 2 3 4; do for i in 1 2 3; do observe "45.33.$n.$h" "$DEEP"; done; done; done
    for n in 50 51 52 53 54; do for i in 1 2 3; do observe "45.33.$n.9" "$DEEP"; done; done
    for i in 1 2 3; do observe "2a01:4f8:c0c:1234::7" "$DEEP"; observe "2a01:4f8:c0c:5678::9" "$DEEP"; done
}

# --- T1: counting per site, /24 and IPv6 address ---
reset; campaign
[[ "${_BS_CMP_SITE_REQ[site.log]}" -eq 81 ]] || fail "T1 site requests=${_BS_CMP_SITE_REQ[site.log]:-0}, want 81"
[[ "${_BS_CMP_SITE_SRC[site.log]}" -eq 27 ]] || fail "T1 site sources=${_BS_CMP_SITE_SRC[site.log]:-0}, want 27"
[[ "${_BS_CMP_NET_SRC[site.log${_BS_US}45.33.40.0/24]}" -eq 4 ]] || fail "T1 /24 sources"
[[ "${_BS_CMP_NET_SRC[site.log${_BS_US}45.33.50.0/24]}" -eq 1 ]] || fail "T1 single-source /24"
[[ -n "${_BS_CMP_V6[site.log${_BS_US}2a01:4f8:c0c:1234::7]:-}" ]] || fail "T1 IPv6 member not tracked"
echo "PASS T1: candidates counted per site / per /24 / per IPv6 address"

# --- T2: below MIN_TERMS is not a candidate ---
reset; observe 45.33.40.1 "$SHALLOW"
[[ "${_BS_CMP_SITE_REQ[site.log]:-0}" -eq 0 ]] || fail "T2 a 2-term query was counted"
echo "PASS T2: below MIN_TERMS not counted"

# --- T3: stale and future request times are not candidates ---
reset; observe 45.33.40.1 "$DEEP" GET 200 $(( NOW - 601 )); observe 45.33.40.2 "$DEEP" GET 200 $(( NOW + 5 ))
[[ "${_BS_CMP_SITE_REQ[site.log]:-0}" -eq 0 && "$_BS_CMP_STALE" -eq 2 ]] || fail "T3 stale/future counted (stale=$_BS_CMP_STALE)"
echo "PASS T3: stale/future request time excluded and counted as stale"

# --- T4: POST and status >= 400 are not candidates ---
reset; observe 45.33.40.1 "$DEEP" POST 200; observe 45.33.40.2 "$DEEP" GET 404
[[ "${_BS_CMP_SITE_REQ[site.log]:-0}" -eq 0 ]] || fail "T4 POST/404 counted"
echo "PASS T4: POST and 4xx excluded"

# --- T5: confirmed campaign under pressure ---
reset; campaign
nftban_botscan_campaign_eval HIGH > "$tmp/eval.out"
grep -q 'BOTSCAN_CAMPAIGN site=site.log .*enforcement=requested prefix_signals=5 member_signals=2' "$tmp/eval.out" || { cat "$tmp/eval.out"; fail "T5 report line"; }
[[ "$(grep -c '"kind":"campaign_prefix"' "$BOTSCAN_BATCH_SIGNAL_FILE")" -eq 5 ]] || fail "T5 prefix signals != 5"
[[ "$(grep -c '"kind":"campaign_member"' "$BOTSCAN_BATCH_SIGNAL_FILE")" -eq 2 ]] || fail "T5 member signals != 2"
grep -q '"prefix":"45.33.40.0/24"' "$BOTSCAN_BATCH_SIGNAL_FILE" || fail "T5 prefix field"
grep -q '45.33.50.0/24' "$BOTSCAN_BATCH_SIGNAL_FILE" && fail "T5 a single-source /24 was signalled"
grep -q '"campaign_id":"site.log:query_complexity:' "$BOTSCAN_BATCH_SIGNAL_FILE" || fail "T5 campaign_id"
echo "PASS T5: only /24s with >= 3 sources and IPv6 sources are signalled"

# --- T6: no pressure: detected, reported, enforcement withheld ---
reset; campaign
nftban_botscan_campaign_eval NORMAL > "$tmp/eval.out"
grep -q 'enforcement=withheld prefix_signals=0 member_signals=0' "$tmp/eval.out" || fail "T6 withheld not reported"
[[ ! -s "$BOTSCAN_BATCH_SIGNAL_FILE" ]] || fail "T6 signals written without pressure"
echo "PASS T6: without pressure the campaign is reported and nothing is signalled"

# --- T7: below the site thresholds nothing is a campaign ---
reset; for i in 1 2 3; do observe 45.33.40.1 "$DEEP"; observe 45.33.40.2 "$DEEP"; observe 45.33.40.3 "$DEEP"; done
nftban_botscan_campaign_eval HIGH > "$tmp/eval.out"
grep -q BOTSCAN_CAMPAIGN "$tmp/eval.out" && fail "T7 a 3-source burst was a campaign"
[[ ! -s "$BOTSCAN_BATCH_SIGNAL_FILE" ]] || fail "T7 signals written"
echo "PASS T7: below MIN_REQUESTS/MIN_SOURCES no campaign"

# --- T8: the source bound overflows visibly and never widens a prefix ---
reset; BOTSCAN_CAMPAIGN_MAX_SOURCES=10 BOTSCAN_CAMPAIGN_MIN_SOURCES=5 campaign
[[ "$_BS_CMP_TRACKED" -eq 10 && "$_BS_CMP_OVERFLOW" -gt 0 ]] || fail "T8 bound (tracked=$_BS_CMP_TRACKED overflow=$_BS_CMP_OVERFLOW)"
BOTSCAN_CAMPAIGN_MIN_SOURCES=5 nftban_botscan_campaign_eval HIGH > "$tmp/eval.out"
grep -q 'sources_overflow=' "$tmp/eval.out" || fail "T8 overflow not reported"
grep -q '45.33.43.0/24\|45.33.44.0/24' "$BOTSCAN_BATCH_SIGNAL_FILE" && fail "T8 an untracked /24 was signalled"
echo "PASS T8: overflow reported; only fully tracked /24s can be signalled"

# --- T9: a /24 holding a crawler claim that is not proven false is kept out ---
reset; campaign; _BOTSCAN_IP_CRAWLER_CLAIM["45.33.41.2"]="googlebot"
nftban_botscan_campaign_eval HIGH > "$tmp/eval.out"
grep -q '45.33.41.0/24' "$BOTSCAN_BATCH_SIGNAL_FILE" && fail "T9 a crawler-claim /24 was signalled"
grep -q 'crawler_networks_kept=1' "$tmp/eval.out" || fail "T9 kept network not reported"
[[ "$(grep -c '"kind":"campaign_prefix"' "$BOTSCAN_BATCH_SIGNAL_FILE")" -eq 4 ]] || fail "T9 other /24s must still be signalled"
echo "PASS T9: unverified crawler claim keeps its /24 out"

# --- T10: disabled = inert ---
reset; BOTSCAN_CAMPAIGN_ENABLED=false observe 45.33.40.1 "$DEEP"
[[ "${_BS_CMP_SITE_REQ[site.log]:-0}" -eq 0 ]] || fail "T10 counted while disabled"
BOTSCAN_CAMPAIGN_ENABLED=false nftban_botscan_build_prefilter "$tmp/pf.off"
grep -qF '[&,%]' "$tmp/pf.off" && fail "T10 prefilter line present while disabled"
echo "PASS T10: disabled is inert (no counting, no prefilter line)"

# --- T11: the prefilter keeps campaign candidates (sound superset of MIN_TERMS) ---
nftban_botscan_build_prefilter "$tmp/pf.on"
deep_line="45.33.40.1 - - [15/Jun/2026:10:00:00 +0000] \"GET ${DEEP} HTTP/2\" 200 84311 \"-\" \"Mozilla/5.0\""
plain_line="45.33.40.1 - - [15/Jun/2026:10:00:00 +0000] \"GET /shop/ HTTP/2\" 200 84311 \"-\" \"Mozilla/5.0\""
re="$(grep -F '[&,%]' "$tmp/pf.on")"
[[ -n "$re" ]] || fail "T11 no campaign prefilter line"
printf '%s\n' "$deep_line" | grep -qE "$re" || fail "T11 a 4-term candidate is dropped by the prefilter"
printf '%s\n' "$plain_line" | grep -qE "$re" && fail "T11 a plain request matches the campaign line"
BOTSCAN_CAMPAIGN_MIN_TERMS=3 nftban_botscan_build_prefilter "$tmp/pf.3"
re3="$(grep -F '[&,%]' "$tmp/pf.3")"
three_line="45.33.40.1 - - [15/Jun/2026:10:00:00 +0000] \"GET /shop/?a=1&b=2&c=3 HTTP/2\" 200 1 \"-\" \"Mozilla/5.0\""
printf '%s\n' "$three_line" | grep -qE "$re3" || fail "T11 MIN_TERMS=3 superset"
echo "PASS T11: prefilter keeps candidates and follows MIN_TERMS"

# --- T12: process_entry feeds the counters (before any per-IP pattern match) ---
reset; nftban_botscan_process_entry 45.33.40.1 "$DEEP" GET 200 "Mozilla/5.0" "$NOW"
[[ "${_BS_CMP_SITE_REQ[site.log]:-0}" -eq 1 ]] || fail "T12 process_entry did not observe"
echo "PASS T12: process_entry observes campaign evidence"

# --- T13: the campaign marker follows the effective state each cycle ---
marker="$NFTBAN_DATA_DIR/botscan/campaign.enabled"
: > "$tmp/one.log"
nftban_botscan_process_logs "$tmp/one.log" > /dev/null 2>&1 || true
[[ -e "$marker" ]] || fail "T13 marker not published while enabled"
touch -d '2026-01-01 00:00:00' "$marker"; m0="$(stat -c %Y "$marker")"
nftban_botscan_process_logs "$tmp/one.log" > /dev/null 2>&1 || true   # an ordinary (quiet) cycle
[[ "$(stat -c %Y "$marker")" == "$m0" ]] || fail "T13 an ordinary cycle moved the enabled-since time"
BOTSCAN_CAMPAIGN_ENABLED=false nftban_botscan_process_logs "$tmp/one.log" > /dev/null 2>&1 || true
[[ ! -e "$marker" ]] || fail "T13 marker kept while the campaign is disabled"
: > "$marker"
BOTSCAN_ENABLED=false nftban_botscan_process_logs "$tmp/one.log" > /dev/null 2>&1 || true
[[ ! -e "$marker" ]] || fail "T13 marker kept while BotScan is disabled"
echo "PASS T13: marker = enabled state (kept by quiet cycles, withdrawn when disabled)"

echo "ALL PASS: botscan_http_campaign_test"
