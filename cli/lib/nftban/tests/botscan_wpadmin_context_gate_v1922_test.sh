#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.192.2 -> v1.234.0 - BotScan WP-admin "context gate" RETIRED (generic pattern contract)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="botscan_wpadmin_context_gate_v1922_test"
# meta:type="test"
# meta:version="1.234.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-17"
# meta:description="v1.234.0 (BUG-BOTSCAN-WPADMIN-AUTH-CONTEXT-IS-CYCLE-SCOPED-BANS-LOGGED-IN-EDITORS): the v1.192.2 per-IP login-inferred suppression is RETIRED. The WP editor traffic it protected is no longer a pattern hit for ANY client (route-bounded EXP_WPREST counting distinct targets; WS_WPADMIN on the request path only), with or without a login in the same cycle, on IPv4 and IPv6; enumeration and exploit probes still ban with or without a login-looking 302; the retired BOTSCAN_WPADMIN_CONTEXT_GATE knob is inert; a negative control restoring the pre-v1.234 EXP_WPREST record makes the no-login editor ban (the fixture discriminates). Uses the SHIPPED records. Drives process_entry + analyze directly; pattern path only (404/endpoint-flood disabled); public TEST-NET IPs."
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
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
export NFTBAN_LIB_DIR
PASS=0; FAIL=0
ok(){ echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad(){ echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export NFTBAN_DATA_DIR="$tmp/data" BOTSCAN_PATTERNS_DIR="$tmp/patterns" NFTBAN_CONFIG_DIR="$tmp/noetc" \
       BOTSCAN_STATE_FILE="$tmp/state.db" BOTSCAN_LOG_FILE="$tmp/botscan.log" BOTSCAN_ENABLED=true \
       BOTSCAN_BATCH_SIGNAL_MODE=true BOTSCAN_404_THRESHOLD=999 BOTSCAN_ENDPOINT_FLOOD_ENABLED=false
mkdir -p "$NFTBAN_DATA_DIR/botguard" "$BOTSCAN_PATTERNS_DIR"
# The SHIPPED records under test (never a hand-written copy that could drift), plus one exploit.
SHIP="$REPO_ROOT/etc/nftban/patterns.d/botscan"
{
  grep -h '^EXP_WPREST|' "$SHIP/exploit.patterns"
  grep -h '^WS_WPADMIN|' "$SHIP/webshell.patterns"
  grep -h '^CVE_LOG4J|' "$SHIP/exploit.patterns"
} > "$BOTSCAN_PATTERNS_DIR/test.patterns"
[[ "$(grep -c . "$BOTSCAN_PATTERNS_DIR/test.patterns")" -eq 3 ]] || { echo "NOT_EXECUTED: shipped records not found under $SHIP" >&2; exit 2; }

# shellcheck source=/dev/null
source "$NFTBAN_LIB_DIR/core/nftban_botscan.sh"
set +e   # driver tolerates non-zero rc from the lib calls; assertions read the signals file
nftban_botscan_load_config
nftban_botscan_load_patterns
[[ "${#_BOTSCAN_PATTERNS[@]}" -eq 3 ]] || { echo "NOT_EXECUTED: loader accepted ${#_BOTSCAN_PATTERNS[@]}/3 shipped records" >&2; exit 2; }

SIG="$NFTBAN_DATA_DIR/botguard/batch_signals.jsonl"
pe(){ nftban_botscan_process_entry "$@" >/dev/null 2>&1 || true; }   # ip url method status ua (API caller: event at cycle now)
analyze(){ : > "$SIG"; nftban_botscan_analyze >/dev/null 2>&1 || true; }
banned(){ grep -q "\"ip\":\"$1\"" "$SIG" 2>/dev/null; }
UA="Mozilla/5.0 (Mac) Chrome/148"
editor(){ # the block editor's own traffic: author list + current user polling + admin-ajax with a .php in the query
  local ip="$1" _
  for _ in 1 2 3 4 5 6; do
    pe "$ip" "/wp-json/wp/v2/users/?who=authors&per_page=100" GET 200 "$UA"
    pe "$ip" "/wp-json/wp/v2/users/me?context=edit" GET 200 "$UA"
  done
  pe "$ip" "/wp-admin/admin-ajax.php?f=skin.php" GET 200 "$UA"
}

nftban_botscan_init_state
# A  = editor WITH a login 302 in the same cycle            -> no ban (no pattern evidence)
pe 198.51.100.1 "/wp-login.php?redirect_to=/wp-admin/" POST 302 "$UA"; editor 198.51.100.1
# A2 = the SAME editor traffic with NO login (IP change)    -> no ban (auth is not needed)
editor 198.51.100.11
# B  = enumeration of user IDs, no login                    -> bans
for i in 1 2 3 4 5; do pe 198.51.100.2 "/wp-json/wp/v2/users/$i" GET 200 "python-requests/2.31"; done
# B2 = enumeration AFTER a login-looking 302 (lostpassword) -> bans (a 302 grants no trust)
pe 198.51.100.12 "/wp-login.php?action=lostpassword" POST 302 "$UA"
for i in 1 2 3 4 5; do pe 198.51.100.12 "/wp-json/wp/v2/users/$i" GET 200 "$UA"; done
# C  = mixed: login 302 + editor + Log4j probe               -> bans (exploit)
pe 198.51.100.3 "/wp-login.php" POST 302 "$UA"; editor 198.51.100.3
pe 198.51.100.3 "/?x=jndi:ldap://evil/a" GET 200 "$UA"
# D  = double extension in the PATH (threshold 1)           -> bans
pe 198.51.100.4 "/wp-admin/css/x.php.php" GET 200 "$UA"
# E  = login 302 + only a .php inside the query              -> no ban (not a double extension)
pe 198.51.100.5 "/wp-login.php" POST 302 "$UA"; pe 198.51.100.5 "/wp-admin/admin-ajax.php?f=skin.php" GET 200 "$UA"
# H/I = IPv6 parity
editor 2001:db8::1
for i in 1 2 3 4 5; do pe 2001:db8::2 "/?rest_route=/wp/v2/users/$i" GET 200 "$UA"; done
analyze

echo "=== v1.234.0: generic contract, gate retired ==="
banned 198.51.100.1  && bad "A editor (login this cycle) BANNED"            || ok "A editor with a login this cycle NOT banned"
banned 198.51.100.11 && bad "A2 editor with NO login BANNED (auth dependency)" || ok "A2 identical editor traffic with NO login NOT banned (no auth dependency)"
banned 198.51.100.2  && ok "B enumeration of user IDs bans"                 || bad "B enumeration not banned"
banned 198.51.100.12 && ok "B2 enumeration after a login-looking 302 still bans (no inferred trust)" || bad "B2 enumeration after 302 NOT banned (inferred trust survived)"
banned 198.51.100.3  && ok "C mixed exploit (editor + Log4j) bans"          || bad "C mixed exploit not banned"
banned 198.51.100.4  && ok "D double extension in the path bans"           || bad "D path double extension not banned"
banned 198.51.100.5  && bad "E .php inside the query treated as a double extension" || ok "E a .php in the query string is not a double extension"
banned 2001:db8::1   && bad "H IPv6 editor BANNED"                          || ok "H IPv6 editor NOT banned"
banned 2001:db8::2   && ok "I IPv6 rest_route enumeration bans"             || bad "I IPv6 enumeration not banned"

# ---- the retired knob is inert: enabling it changes nothing ----
export BOTSCAN_WPADMIN_CONTEXT_GATE=true BOTSCAN_WPADMIN_CONTEXT_PATTERNS="EXP_WPREST WS_WPADMIN"
nftban_botscan_init_state
pe 198.51.100.12 "/wp-login.php" POST 302 "$UA"
for i in 1 2 3 4 5; do pe 198.51.100.12 "/wp-json/wp/v2/users/$i" GET 200 "$UA"; done
analyze
banned 198.51.100.12 && ok "K BOTSCAN_WPADMIN_CONTEXT_GATE=true is inert (enumeration after login still bans)" || bad "K retired gate knob still suppresses"
unset BOTSCAN_WPADMIN_CONTEXT_GATE BOTSCAN_WPADMIN_CONTEXT_PATTERNS

# ---- negative control: the pre-v1.234 EXP_WPREST record makes the no-login editor ban ----
printf 'EXP_WPREST|/wp-json/wp/v2/users|url-get|5|300|1800|true|pre-v1.234 record (negative control)\n' > "$BOTSCAN_PATTERNS_DIR/zz_negative_control.patterns"
nftban_botscan_load_patterns
nftban_botscan_init_state
editor 198.51.100.11
analyze
banned 198.51.100.11 && ok "NC pre-v1.234 record bans the no-login editor (fixture discriminates)" || bad "NC old record did not ban — the A2 arm has no power"

echo ""
echo "=== botscan wp-admin gate retired / generic contract v1.234.0: PASS=$PASS FAIL=$FAIL ==="
[[ "$PASS" -eq 11 ]] || { echo "INCOMPLETE: $PASS/11 assertions passed or ran" >&2; exit 1; }
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
