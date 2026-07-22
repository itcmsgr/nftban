#!/usr/bin/env bash
# =============================================================================
# NFTBan - BotScan request_class classifier (v1.191 8B / increment 3)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="botscan_request_class_classifier_v1913_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-16"
# meta:description="Hermetic tests for nftban_botscan_classify_request_class (v1.191 8B increment 3). Verifies the pure HTTP-evidence -> request_class taxonomy mapping (static/static404/eshop_fanout/admin_ajax/dynamic_abuse/login_api/scanner/mixed), the ordering rule (clear scanner/dynamic abuse wins over browser-like; browser-like admin/ajax/static wins over crude .php=abuse; never classify on rate alone), and that the shell emit path writes the structured request_class+family into batch_signals.jsonl for both IPv4 and IPv6. The 'invalid class -> mixed' guard is the increment-2 Go test TestBatchSignal_InvalidRequestClassMapsMixed; this test additionally proves the shell classifier NEVER emits an out-of-enum value."
#
# meta:inventory.files="botscan_request_class_classifier_v1913_test.sh"
# meta:inventory.binaries="bash,grep,python3"
# meta:inventory.env_vars="NFTBAN_DATA_DIR,BOTSCAN_BATCH_SIGNAL_MODE,BOTSCAN_SIGNAL_REQUEST_CLASS,BOTSCAN_BATCH_SIGNAL_FILE"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# meta:ta.id="botscan_request_class_classifier_v1913_test"
# meta:ta.owner="botscan"
# meta:ta.module="botscan"
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
fail() { echo "FAIL: $*" >&2; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export NFTBAN_DATA_DIR="$tmp/data" BOTSCAN_PATTERNS_DIR="$tmp/patterns" \
       BOTSCAN_STATE_FILE="$tmp/s.db" BOTSCAN_LOG_FILE="$tmp/b.log" \
       NFTBAN_CONFIG_DIR="$tmp/noetc" BOTSCAN_ENABLED=true \
       BOTSCAN_BATCH_SIGNAL_MODE=true BOTSCAN_VERIFY_CRAWLERS=false
mkdir -p "$NFTBAN_DATA_DIR/botscan" "$BOTSCAN_PATTERNS_DIR"
# shellcheck source=/dev/null
source "$NFTBAN_LIB_DIR/core/nftban_botscan.sh"; nftban_botscan_load_config

VALID="static static404 eshop_fanout admin_ajax dynamic_abuse login_api scanner mixed"

# assert <name> <method> <path> <status> <hint> <want>
assert() {
    local name="$1" method="$2" path="$3" status="$4" hint="$5" want="$6" got
    got="$(nftban_botscan_classify_request_class "$method" "$path" "$status" "$hint")"
    [[ " $VALID " == *" $got "* ]] || fail "$name: classifier emitted out-of-enum value '$got'"
    [[ "$got" == "$want" ]] || fail "$name: got '$got' want '$want' (m=$method p=$path s=$status h=$hint)"
    echo "PASS: $name -> $got"
}

# ---- classification cases (the 13 required, minus the two emit/guard checks below) ----
assert STATIC_ASSET_CLASSIFIES_STATIC                       GET  "/assets/app.css"                                   200 "" static
assert STATIC_404_CLASSIFIES_STATIC404                      GET  "/css/missing.css"                                  404 "" static404
assert RETINA_404_CLASSIFIES_STATIC404_NOT_DYNAMIC_ABUSE    GET  "/wp-content/uploads/2024/06/hero-photo@2x.png"     404 "" static404
assert ESHOP_GALLERY_FANOUT_CLASSIFIES_ESHOP_FANOUT         GET  "/wp-content/uploads/2024/gallery/product-300x300.jpg" 200 "" eshop_fanout
assert WOOCOMMERCE_ADMIN_AJAX_CLASSIFIES_ADMIN_AJAX         GET  "/wp-json/wc-analytics/reports/orders"              200 "" admin_ajax
assert ADMIN_AJAX_NOT_DYNAMIC_ABUSE_BY_DOTPHP_ONLY          POST "/wp-admin/admin-ajax.php"                          200 "" admin_ajax
assert XMLRPC_POST_CLASSIFIES_DYNAMIC_ABUSE                 POST "/xmlrpc.php"                                       200 "" dynamic_abuse
assert WP_LOGIN_POST_CLASSIFIES_DYNAMIC_ABUSE               POST "/wp-login.php"                                     200 "" dynamic_abuse
assert PHP_API_LOOP_CLASSIFIES_DYNAMIC_ABUSE                POST "/wp-content/plugins/foo/api.php"                   200 "" dynamic_abuse
assert SCANNER_PATH_CLASSIFIES_SCANNER                      GET  "/.env"                                             404 "" scanner
assert UNKNOWN_PATTERN_CLASSIFIES_MIXED                     GET  "/about/team/random-page"                          200 "" mixed

# Extra coverage so login_api is not untested dead code (not in the required 13, kept for hygiene).
assert LOGIN_API_MARKER_CLASSIFIES_LOGIN_API                POST "/api/session"                                     401 "login_api" login_api

# ---- INVALID_CLASS_REMAINS_MIXED_VIA_INCREMENT_2_GUARD ----
# The authoritative guard is the increment-2 Go test TestBatchSignal_InvalidRequestClassMapsMixed
# (an invalid/missing request_class normalizes to "mixed" in the daemon). Here we prove the
# complementary shell invariant: the classifier itself can NEVER produce an out-of-enum value, so
# an invalid class can only ever originate from a hand-edited signal, which the Go guard then maps
# to mixed. Feed deliberately weird/unsupported evidence and confirm the output stays in-enum.
for probe in \
    'PATCH|/totally/unknown/thing|418|garbage-hint-zzz' \
    'TRACE||999|' \
    'CONNECT|/%00%00|000|<<<bogus>>>'; do
    IFS='|' read -r _m _p _s _h <<< "$probe"
    g="$(nftban_botscan_classify_request_class "$_m" "$_p" "$_s" "$_h")"
    [[ " $VALID " == *" $g "* ]] || fail "INVALID_CLASS_REMAINS_MIXED_VIA_INCREMENT_2_GUARD: out-of-enum '$g' for [$probe]"
done
echo "PASS: INVALID_CLASS_REMAINS_MIXED_VIA_INCREMENT_2_GUARD (classifier always in-enum; Go guard maps any stray value to mixed)"

# ---- IPV4_IPV6_SIGNAL_CLASS_PRESERVED ----
# Emit through the real write path and confirm the structured request_class + derived family land
# in batch_signals.jsonl for both an IPv4 and an IPv6 source, and the JSON parses.
emit_and_check() {
    local label="$1" ip="$2" cls="$3" wantfam="$4" sig
    sig="$tmp/sig_${label}.jsonl"; : > "$sig"
    BOTSCAN_BATCH_SIGNAL_FILE="$sig" BOTSCAN_SIGNAL_REQUEST_CLASS="$cls" \
        nftban_botscan_write_signal "$ip" 80 ban botscan-endpoint-flood "endpoint_flood POST /xmlrpc.php"
    python3 - "$sig" "$ip" "$cls" "$wantfam" <<'PY' || fail "$label: signal JSON invalid or fields not preserved"
import json,sys
sig,ip,cls,fam=sys.argv[1:5]
line=open(sig).read().strip().splitlines()[-1]
o=json.loads(line)
assert o["ip"]==ip, o
assert o["request_class"]==cls, o
assert o["family"]==fam, o
PY
    echo "PASS: IPV4_IPV6_SIGNAL_CLASS_PRESERVED ($label: $ip -> family=$wantfam request_class=$cls)"
}
emit_and_check ipv4 "203.0.113.7"  dynamic_abuse ipv4
emit_and_check ipv6 "2001:db8::dead:beef" dynamic_abuse ipv6

echo
echo "ALL PASS: botscan request_class classifier (v1.191 8B increment 3)"
