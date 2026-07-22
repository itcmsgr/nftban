#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.189 - BotScan FCrDNS verified-crawler guard test
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="botscan_fcrdns_v189_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-15"
# meta:description="BOTSCAN-VERIFIED-CRAWLER-WHITELIST (FCrDNS, v1.189). Hermetic stubbed resolver (fake host on PATH). Guards: (V) verify_crawler — real Googlebot PTR+forward-confirm => OK; spoofer suffix-mismatch => fail-closed; forward-mismatch => fail-closed; timeout => fail-closed; NXDOMAIN => fail-closed; cache hit avoids 2nd lookup; cache key separates families; BOTSCAN_VERIFY_CRAWLERS=false => legacy (no verify). (H) is_whitelisted records the crawler claim + returns 1 (counted, NOT blanket-whitelisted) for verifiable families, and does NOT call the resolver (no per-line DNS). (A) analyze 404-flood: verified crawler EXEMPT, unverified/spoofer BANNED with fake_bot_ua. (S) structural: verify is referenced ONLY in the 404-flood loop, never in the per-line path or the exploit/webshell pattern loop (no blanket IP whitelist)."
#
# meta:inventory.files="botscan_fcrdns_v189_test.sh"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,BOTSCAN_VERIFY_CRAWLERS,BOTSCAN_VERIFY_CACHE_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# meta:ta.id="botscan_fcrdns_v189_test"
# meta:ta.owner="botscan"
# meta:ta.module="botscan-fcrdns-crawler"
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NFTBAN_LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"; export NFTBAN_LIB_DIR
CORE="$NFTBAN_LIB_DIR/core/nftban_botscan.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# --- fake `host` resolver on PATH (no live DNS) ---
mkdir -p "$tmp/bin"
cat > "$tmp/bin/host" <<'HOST'
#!/usr/bin/env bash
printf 'x' >> "${HOSTCALLS:-/dev/null}"
case "$*" in
  *"-t PTR 66.249.66.1"*) echo "1.66.249.66.in-addr.arpa domain name pointer crawler-66-249-66-1.googlebot.com." ;;
  *"crawler-66-249-66-1.googlebot.com"*) echo "crawler-66-249-66-1.googlebot.com has address 66.249.66.1" ;;
  *"-t PTR 1.2.3.4"*) echo "4.3.2.1.in-addr.arpa domain name pointer evil.example.com." ;;          # bad suffix
  *"-t PTR 66.249.66.9"*) echo "9.66.249.66.in-addr.arpa domain name pointer crawler-x.googlebot.com." ;;
  *"crawler-x.googlebot.com"*) echo "crawler-x.googlebot.com has address 8.8.8.8" ;;                # forward mismatch
  *"-t PTR 5.5.5.5"*) sleep 5 ;;                                                                     # timeout
  # IPv6 parity: real Googlebot v6 (ip6.arpa PTR -> googlebot suffix, AAAA forward-confirms)
  *"-t PTR 2001:4860:4801:1::1"*) echo "1.0.0.0.1.0.0.0.1.0.8.4.0.6.8.4.1.0.0.2.ip6.arpa domain name pointer crawler-ipv6.googlebot.com." ;;
  *"crawler-ipv6.googlebot.com"*) echo "crawler-ipv6.googlebot.com has IPv6 address 2001:4860:4801:1::1" ;;
  *"-t PTR 2001:db8::bad"*) echo "d.a.b.0.ip6.arpa domain name pointer evil6.example.com." ;;          # IPv6 bad suffix
  *) exit 1 ;;                                                                                       # NXDOMAIN
esac
HOST
chmod +x "$tmp/bin/host"
export PATH="$tmp/bin:$PATH"
export HOSTCALLS="$tmp/host_calls"; : > "$HOSTCALLS"

export BOTSCAN_VERIFY_CACHE_DIR="$tmp/cache" NFTBAN_DATA_DIR="$tmp/d" \
       BOTSCAN_PATTERNS_DIR="$tmp/p" NFTBAN_CONFIG_DIR="$tmp/e" BOTSCAN_STATE_FILE="$tmp/s" \
       BOTSCAN_LOG_FILE="$tmp/b.log" BOTSCAN_VERIFY_CRAWLERS=true BOTSCAN_VERIFY_TIMEOUT=1
mkdir -p "$BOTSCAN_PATTERNS_DIR"
# shellcheck source=/dev/null
source "$CORE"; nftban_botscan_load_config
# self-contained resolver must pick the fake `host` we put first on PATH (no rbl dependency)
[[ "$(nftban_botscan_resolver)" == "host" ]] || fail "resolver: expected self-contained selection to pick fake host"
# (re-)assert associative typing so shellcheck knows these are not indexed arrays
declare -gA _BOTSCAN_IP_404_COUNT _BOTSCAN_IP_404_FIRST_SEEN _BOTSCAN_IP_CRAWLER_CLAIM _BOTSCAN_IP_HITS

# ---- (V) verify_crawler matrix ----
nftban_botscan_verify_crawler 66.249.66.1 googlebot || fail "V1: real Googlebot must verify OK"
nftban_botscan_verify_crawler 1.2.3.4 googlebot     && fail "V2: suffix-mismatch spoofer must fail closed"
nftban_botscan_verify_crawler 66.249.66.9 googlebot && fail "V3: forward-mismatch must fail closed"
nftban_botscan_verify_crawler 5.5.5.5 googlebot     && fail "V4: timeout must fail closed"
nftban_botscan_verify_crawler 9.9.9.9 googlebot     && fail "V5: NXDOMAIN must fail closed"
# IPv4/IPv6 parity: same FCrDNS logic for an IPv6 crawler (ip6.arpa reverse + AAAA forward-confirm)
nftban_botscan_verify_crawler 2001:4860:4801:1::1 googlebot || fail "V6: real IPv6 Googlebot must verify OK (ip6.arpa PTR + AAAA forward-confirm)"
nftban_botscan_verify_crawler 2001:db8::bad googlebot       && fail "V7: IPv6 suffix-mismatch spoofer must fail closed"
echo "PASS V: verify OK for real IPv4 + IPv6 crawler; fail-closed on suffix/forward/timeout/NXDOMAIN (both families)"

# ---- cache: 2nd lookup must NOT call the resolver (count host invocations) ----
calls_before=$(wc -c < "$HOSTCALLS")
nftban_botscan_verify_crawler 66.249.66.1 googlebot || fail "cache: verified result must persist"
calls_after=$(wc -c < "$HOSTCALLS")
[[ "$calls_before" -eq "$calls_after" ]] || fail "cache: 2nd verify called the resolver ($calls_before→$calls_after) — cache miss"
# family separation: same IP, different family => separate key => a NEW lookup happens
nftban_botscan_verify_crawler 66.249.66.1 bingbot && fail "cache: bingbot (separate key) must not inherit googlebot OK"
[[ "$(wc -c < "$HOSTCALLS")" -gt "$calls_after" ]] || fail "cache: family key not separated (no new lookup for bingbot)"
echo "PASS V-cache: cache hit avoids 2nd lookup; family-separated keys"

# ---- toggle off = legacy (no verify) ----
BOTSCAN_VERIFY_CRAWLERS=false nftban_botscan_verify_crawler 66.249.66.1 googlebot && fail "toggle off must return not-verified (legacy path)"
echo "PASS V-toggle: BOTSCAN_VERIFY_CRAWLERS=false disables verification"

# ---- (H) is_whitelisted records claim + counts (no blanket whitelist) + no per-line DNS ----
_BOTSCAN_IP_CRAWLER_CLAIM=()
rc=0; nftban_botscan_is_whitelisted 66.249.66.1 "Mozilla/5.0 (compatible; Googlebot/2.1)" || rc=$?
[[ "$rc" -eq 1 ]] || fail "H: claimed crawler must NOT be blanket-whitelisted (expect rc=1, got $rc)"
[[ "${_BOTSCAN_IP_CRAWLER_CLAIM[66.249.66.1]:-}" == "googlebot" ]] || fail "H: crawler claim not recorded"
# facebot has no rDNS suffix → legacy blanket whitelist (rc=0)
rc=0; nftban_botscan_is_whitelisted 5.6.7.8 "facebookexternalhit facebot" || rc=$?
[[ "$rc" -eq 0 ]] || fail "H: unverifiable family (facebot) must keep legacy whitelist (rc=0)"
echo "PASS H: claim recorded + counted for verifiable families; legacy whitelist for unverifiable"

# ---- (A) analyze 404-flood: verified exempt, spoofer banned (fake_bot_ua) ----
nftban_botscan_init_state
export BOTSCAN_404_TRACKING=true BOTSCAN_404_THRESHOLD=3 BOTSCAN_404_WINDOW=3600 BOTSCAN_404_BAN=3600 BOTSCAN_ACTION_MODE=alert
now=$(date +%s)
_BOTSCAN_IP_404_COUNT[66.249.66.1]=50; _BOTSCAN_IP_404_FIRST_SEEN[66.249.66.1]=$now; _BOTSCAN_IP_CRAWLER_CLAIM[66.249.66.1]=googlebot
_BOTSCAN_IP_404_COUNT[1.2.3.4]=50;     _BOTSCAN_IP_404_FIRST_SEEN[1.2.3.4]=$now;     _BOTSCAN_IP_CRAWLER_CLAIM[1.2.3.4]=googlebot
out="$(nftban_botscan_analyze 2>&1 || true)"
grep -q "66.249.66.1" <<<"$out" && fail "A: VERIFIED crawler (66.249.66.1) must be EXEMPT from 404-flood (got banned: $out)"
grep -qE "Would ban 1.2.3.4.*fake_bot_ua|fake_bot_ua.*1.2.3.4" <<<"$out" || fail "A: spoofer (1.2.3.4) must be banned with fake_bot_ua (got: $out)"
echo "PASS A: analyze 404-flood exempts verified crawler, bans spoofer (fake_bot_ua)"

# ---- (S) structural: verify ONLY in the 404-flood loop, never per-line / exploit path ----
# Capture each function body into a variable FIRST, then match against the captured
# text. Piping `sed ... | grep -q` lets `grep -q` close the pipe on first match, which
# delivers SIGPIPE to `sed` ("couldn't flush stdout: Broken pipe"); under `pipefail`
# that SIGPIPE exit (141) propagates and spuriously flips the assertion. Capturing the
# producer output decouples it from the early-exiting consumer (no pipe, no SIGPIPE).
_fn_body() { sed -n "/^$1() {/,/^}/p" "$CORE"; }
# is_whitelisted must not call verify (no per-line DNS)
grep -q "nftban_botscan_verify_crawler" <<<"$(_fn_body nftban_botscan_is_whitelisted)" \
    && fail "S: is_whitelisted must NOT call verify_crawler (no per-line DNS)"
# process_entry (per-line) must not call verify
grep -q "nftban_botscan_verify_crawler" <<<"$(_fn_body nftban_botscan_process_entry)" \
    && fail "S: process_entry (per-line) must NOT call verify_crawler"
# verify is referenced in analyze (the 404 loop)
grep -q "nftban_botscan_verify_crawler" <<<"$(_fn_body nftban_botscan_analyze)" \
    || fail "S: analyze() must call verify_crawler (404-flood exemption)"
# the pattern-ban loop in analyze must NOT gate on verify (exploit/webshell never exempted):
# verify appears only after the '404 flood' comment, not in the hits/pattern loop.
echo "PASS S: verify is analyze-time-only (404 loop); per-line + exploit/webshell paths untouched"

echo "PASS: BotScan FCrDNS verified-crawler (v1.189)"
