#!/usr/bin/env bash
# =============================================================================
# NFTBan - BotScan endpoint-flood detector test (BOTSCAN-ENDPOINT-FLOOD)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="botscan_endpoint_flood_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-15"
# meta:description="Hermetic guard for the BotScan endpoint-flood detector that closes the advertised WordPress/XML-RPC protection gap (PROTECTION-CLAIM-MATRIX HIGH). Proves, with fixture access logs (no ad-hoc tail/cursor injection): (T1/T2) POST /xmlrpc.php and /wp-login.php volume above threshold is counted per-IP/per-endpoint in the proven count_404_tail re-read; (T3) STATUS-INDEPENDENT — 200 AND non-200 POSTs count (not tied to 404); (T4) below-threshold does NOT ban; (T5) non-POST does NOT count; (T6) 404-flood tracker still works and endpoint counting does not interfere; (T7) emission uses the BATCH-SIGNAL path (write_signal JSONL + |SIGNAL| botscan.log line), NEVER the direct ban_ip --duration branch (BUG-BOTSCAN-DIRECT-BAN-FLAG); (T8) an unconfigured endpoint does not count; (T9) per-endpoint keys are independent."
#
# meta:inventory.files="botscan_endpoint_flood_test.sh"
# meta:inventory.binaries="bash,tail,grep"
# meta:inventory.env_vars="NFTBAN_DATA_DIR,BOTSCAN_ENDPOINT_FLOOD_THRESHOLD,BOTSCAN_BATCH_SIGNAL_FILE"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# meta:ta.id="botscan_endpoint_flood_test"
# meta:ta.owner="botscan"
# meta:ta.module="botscan-endpoint-flood"
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
       BOTSCAN_BATCH_SIGNAL_FILE="$tmp/sig.jsonl" NFTBAN_CONFIG_DIR="$tmp/noetc" \
       BOTSCAN_ENABLED=true BOTSCAN_404_TRACKING=true BOTSCAN_VERIFY_CRAWLERS=false \
       BOTSCAN_ENDPOINT_FLOOD_ENABLED=true BOTSCAN_ENDPOINT_FLOOD_THRESHOLD=30 \
       BOTSCAN_ENDPOINT_FLOOD_WINDOW=60 BOTSCAN_SCAN_PREFILTER=true
mkdir -p "$NFTBAN_DATA_DIR/botscan" "$BOTSCAN_PATTERNS_DIR" "$tmp/spool"
# shellcheck source=/dev/null
source "$NFTBAN_LIB_DIR/core/nftban_botscan.sh"; nftban_botscan_load_config

# emit one combined-log line: <ip> <method> <url> <status>
line() { printf '%s - - [15/Jun/2026:10:00:00 +0000] "%s %s HTTP/1.1" %s 350 "-" "Mozilla/5.0"\n' "$1" "$2" "$3" "$4"; }
runcycle() { rm -f "$NFTBAN_DATA_DIR/botscan/404-rotate"; nftban_botscan_init_state; nftban_botscan_count_404_tail 0 0 "$1"; }

# --- T1: xmlrpc POST 200 flood (40 > 30) counted per ip|endpoint ---
f="$tmp/spool/t1.log"; : > "$f"; for i in $(seq 1 40); do line 198.51.100.11 POST /xmlrpc.php 200; done > "$f"
runcycle "$f"
[[ "${_BOTSCAN_IP_ENDPOINT_COUNT[198.51.100.11|xmlrpc.php]:-0}" -eq 40 ]] || fail "T1 xmlrpc count != 40 (got ${_BOTSCAN_IP_ENDPOINT_COUNT[198.51.100.11|xmlrpc.php]:-0})"
echo "PASS T1: POST /xmlrpc.php 200 volume counted (40)"

# --- T2: wp-login POST 200 flood counted under its own key ---
f="$tmp/spool/t2.log"; : > "$f"; for i in $(seq 1 40); do line 198.51.100.12 POST /wp-login.php 200; done > "$f"
runcycle "$f"
[[ "${_BOTSCAN_IP_ENDPOINT_COUNT[198.51.100.12|wp-login.php]:-0}" -eq 40 ]] || fail "T2 wp-login count != 40"
echo "PASS T2: POST /wp-login.php 200 volume counted (40)"

# --- T3: STATUS-INDEPENDENT — mix 200 + 403 + 500, all count ---
f="$tmp/spool/t3.log"; : > "$f"; { for i in $(seq 1 20); do line 198.51.100.16 POST /xmlrpc.php 200; done; for i in $(seq 1 12); do line 198.51.100.16 POST /xmlrpc.php 403; done; for i in $(seq 1 8); do line 198.51.100.16 POST /xmlrpc.php 500; done; } > "$f"
runcycle "$f"
[[ "${_BOTSCAN_IP_ENDPOINT_COUNT[198.51.100.16|xmlrpc.php]:-0}" -eq 40 ]] || fail "T3 status-independent count != 40 (got ${_BOTSCAN_IP_ENDPOINT_COUNT[198.51.100.16|xmlrpc.php]:-0})"
echo "PASS T3: status-independent (200/403/500 all count = 40)"

# --- T4: below threshold (10 < 30) → no ban on analyze ---
f="$tmp/spool/t4.log"; : > "$f"; for i in $(seq 1 10); do line 198.51.100.13 POST /xmlrpc.php 200; done > "$f"
runcycle "$f"; : > "$tmp/sig.jsonl"; : > "$BOTSCAN_LOG_FILE"
nftban_botscan_analyze >/dev/null 2>&1 || true
grep -q '198.51.100.13' "$tmp/sig.jsonl" 2>/dev/null && fail "T4 below-threshold IP must NOT be signalled"
echo "PASS T4: below-threshold (10) does not ban"

# --- T5: non-POST (GET) does NOT count ---
f="$tmp/spool/t5.log"; : > "$f"; for i in $(seq 1 40); do line 198.51.100.14 GET /xmlrpc.php 200; done > "$f"
runcycle "$f"
[[ -z "${_BOTSCAN_IP_ENDPOINT_COUNT[198.51.100.14|xmlrpc.php]:-}" ]] || fail "T5 GET must NOT count as endpoint-flood"
echo "PASS T5: non-POST (GET) does not count"

# --- T6: 404-flood tracker still works + endpoint counting does not interfere ---
f="$tmp/spool/t6.log"; : > "$f"; for i in $(seq 1 55); do line 198.51.100.15 GET "/missing-$i.php" 404; done > "$f"
runcycle "$f"
[[ "${_BOTSCAN_IP_404_COUNT[198.51.100.15]:-0}" -ge 50 ]] || fail "T6 404-flood broken (got ${_BOTSCAN_IP_404_COUNT[198.51.100.15]:-0})"
[[ -z "${_BOTSCAN_IP_ENDPOINT_COUNT[198.51.100.15|xmlrpc.php]:-}" ]] || fail "T6 404 lines must not count as endpoint-flood"
echo "PASS T6: 404-flood preserved + no endpoint interference"

# --- T7: emission via BATCH-SIGNAL path (write_signal JSONL + |SIGNAL| log), not direct ban_ip ---
f="$tmp/spool/t7.log"; : > "$f"; for i in $(seq 1 40); do line 198.51.100.11 POST /xmlrpc.php 200; done > "$f"
runcycle "$f"; : > "$tmp/sig.jsonl"; : > "$BOTSCAN_LOG_FILE"
nftban_botscan_analyze >/dev/null 2>&1 || true
grep -q '"ip":"198.51.100.11"' "$tmp/sig.jsonl" || fail "T7 batch-signal JSONL missing endpoint-flood IP"
grep -q 'endpoint_flood' "$tmp/sig.jsonl" || fail "T7 batch-signal reason missing endpoint_flood"
grep -qE '\|botscan-endpoint-flood\|198\.51\.100\.11\|.*\|SIGNAL\|' "$BOTSCAN_LOG_FILE" || fail "T7 botscan.log must record |botscan-endpoint-flood|...|SIGNAL| (batch path, not direct BANNED)"
grep -q 'BANNED' "$BOTSCAN_LOG_FILE" && fail "T7 must NOT use the direct ban_ip path (no BANNED line for endpoint-flood)"
echo "PASS T7: emits via batch-signal path (write_signal + |SIGNAL|), avoids direct ban_ip"

# --- T8: an UNCONFIGURED endpoint does not count ---
f="$tmp/spool/t8.log"; : > "$f"; for i in $(seq 1 40); do line 198.51.100.17 POST /wp-admin/admin-ajax.php 200; done > "$f"
runcycle "$f"
for k in "${!_BOTSCAN_IP_ENDPOINT_COUNT[@]}"; do [[ "$k" == 198.51.100.17* ]] && fail "T8 unconfigured endpoint must not count ($k)"; done
echo "PASS T8: unconfigured endpoint does not count"

# --- T9: per-endpoint keys are independent (xmlrpc vs wp-login from same IP) ---
f="$tmp/spool/t9.log"; : > "$f"; { for i in $(seq 1 31); do line 198.51.100.18 POST /xmlrpc.php 200; done; for i in $(seq 1 33); do line 198.51.100.18 POST /wp-login.php 200; done; } > "$f"
runcycle "$f"
[[ "${_BOTSCAN_IP_ENDPOINT_COUNT[198.51.100.18|xmlrpc.php]:-0}" -eq 31 && "${_BOTSCAN_IP_ENDPOINT_COUNT[198.51.100.18|wp-login.php]:-0}" -eq 33 ]] || fail "T9 per-endpoint keys not independent"
echo "PASS T9: per-endpoint keys independent (xmlrpc=31, wp-login=33)"

# --- T10: IPv6 source compatibility (same detector, IPv6 key) ---
f="$tmp/spool/t10.log"; : > "$f"; for i in $(seq 1 40); do line 2001:db8::dead POST /xmlrpc.php 200; done > "$f"
runcycle "$f"
[[ "${_BOTSCAN_IP_ENDPOINT_COUNT[2001:db8::dead|xmlrpc.php]:-0}" -eq 40 ]] || fail "T10 IPv6 endpoint count != 40 (got ${_BOTSCAN_IP_ENDPOINT_COUNT[2001:db8::dead|xmlrpc.php]:-0})"
# emit path must carry the IPv6 address intact (key split on first '|')
: > "$tmp/sig.jsonl"; : > "$BOTSCAN_LOG_FILE"; nftban_botscan_analyze >/dev/null 2>&1 || true
grep -q '"ip":"2001:db8::dead"' "$tmp/sig.jsonl" || fail "T10 IPv6 batch-signal missing/garbled IPv6 address"
echo "PASS T10: IPv6 source counted + signalled with address intact"

echo "ALL PASS: botscan endpoint-flood detector"
