#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.238 config validator agrees with the real consumers
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="config_validator_truth_v1238_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-23"
# meta:description="v1.238 (owner GO 2026-11-23, .conf/.local review): `nftban config validate` exited 1 on stock lab2/lab4 because keys NFTBan ships or writes were missing from the schema (FEED_ABUSEIPDB_*, PORTSCAN_CLASSIC_GENERIC_CORROBORATE(_PORTS), SSH_PORT, NFTBAN_LOG_DIR); custom feeds were UNKNOWN like a typo; 13 of 14 deprecated properties read OK; config local list/doctor missed conf.d/<module>/*.conf.local; --quiet was ignored. Drives the REAL nftban_configtest / nftban_cmd_config_test / nftban_cmd_config_local_doctor against a sandbox config with the repo schema. Asserts: stock-like config with those keys validates rc 0; a custom feed (FEED_A5LOCAL_URL/_ENABLED) is accepted and the typo FEED_A5LOCAL_ENABELD is UNKNOWN with the feed-suffix hint; doctor finds a conf.d/<module>/*.conf.local and reports the typo with file:line, never the value; a deprecated property (DDOS_WHITELIST_FILE) is a warning in validate; NFTBAN_FAIL2BAN_ENABLED reports removed/no effect; --quiet prints nothing and keeps the exit code. Sandbox only."
# meta:input="None (repo source read-only; temp dirs)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,jq,grep"
# meta:inventory.files="cli/lib/nftban/core/nftban_config_schema.sh,cli/lib/nftban/core/nftban_config_local.sh,cli/lib/nftban/cli/cmd_config.sh,cli/lib/nftban/data/config-schema.json"
# meta:inventory.binaries="bash,jq,grep"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="config_validator_truth_v1238_test"
# meta:ta.owner="core"
# meta:ta.module="config"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="policy-gates"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
export NFTBAN_LIB_DIR="$REPO_ROOT/cli/lib/nftban"
_tmp="$(mktemp -d)"; export NFTBAN_CONFIG_DIR="$_tmp/etc/nftban"
trap 'rm -rf "$_tmp"' EXIT
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }; no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
command -v jq >/dev/null || { echo "SKIP: jq missing"; exit 0; }
mkdir -p "$NFTBAN_CONFIG_DIR/conf.d/portscan" "$NFTBAN_CONFIG_DIR/conf.d/ddos"

source "$NFTBAN_LIB_DIR/lib/env.sh" 2>/dev/null || true
source "$NFTBAN_LIB_DIR/core/nftban_config_schema.sh"
source "$NFTBAN_LIB_DIR/core/nftban_config_local.sh"
cfn=$(awk '/^nftban_cmd_config_test\(\) \{/ {f=1} f {print} f && /^\}/ {f=0}' "$NFTBAN_LIB_DIR/cli/cmd_config.sh")
eval "$cfn"
set +e

stock(){
  rm -rf "$NFTBAN_CONFIG_DIR"; mkdir -p "$NFTBAN_CONFIG_DIR/conf.d/portscan" "$NFTBAN_CONFIG_DIR/conf.d/ddos"
  cat > "$NFTBAN_CONFIG_DIR/conf.d/feeds.conf" <<'EOF'
FEED_ABUSEIPDB_URL="https://api.abuseipdb.example.invalid/blacklist"
FEED_ABUSEIPDB_FORMAT="abuseipdb"
FEED_ABUSEIPDB_ENABLED="false"
FEED_ABUSEIPDB_CATEGORY="reputation"
FEED_ABUSEIPDB_DESCRIPTION="x"
FEED_ABUSEIPDB_INTERVAL="DAILY"
FEED_ABUSEIPDB_SIZE="x"
FEED_ABUSEIPDB_CONFIDENCE_MINIMUM="100"
FEED_ABUSEIPDB_LIMIT="10000"
FEED_ABUSEIPDB_MAX_AGE="72h"
FEED_ABUSEIPDB_MIN_INTERVAL="6h"
EOF
  printf 'PORTSCAN_CLASSIC_GENERIC_CORROBORATE="true"\nPORTSCAN_CLASSIC_GENERIC_CORROBORATE_PORTS=""\n' > "$NFTBAN_CONFIG_DIR/conf.d/portscan/classic.conf"
  printf 'SSH_PORT="2222"\nNFTBAN_LOG_DIR="/var/log/nftban"\n' > "$NFTBAN_CONFIG_DIR/nftban.conf.local"
}

echo "=== stock-like config: keys NFTBan ships or writes ==="
stock
out=$(nftban_configtest 0 0 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "validate rc 0 with the shipped/installer-written keys (was rc 1 on stock lab2/lab4)" || no "stock validate rc=$rc" "$(grep -E 'UNKNOWN|DEPRECATED' <<<"$out" | head -5)"

echo "=== custom feed vs typo ==="
printf 'FEED_A5LOCAL_URL="https://feed.example.invalid/list.txt"\nFEED_A5LOCAL_ENABLED="true"\nFEED_A5LOCAL_ENABELD="true"\n' > "$NFTBAN_CONFIG_DIR/conf.d/feeds.conf.local"
out=$(nftban_configtest 0 0 2>&1); rc=$?
# validate prints problems only: a valid custom feed key must not appear as UNKNOWN
! grep -qE 'UNKNOWN: FEED_A5LOCAL_(ENABLED|URL) ' <<<"$out" && ok "valid custom feed keys accepted" || no "custom feed" "$(grep FEED_A5 <<<"$out")"
grep -q 'UNKNOWN: FEED_A5LOCAL_ENABELD (not a feed setting' <<<"$out" && [[ $rc -ne 0 ]] && ok "typo FEED_A5LOCAL_ENABELD flagged with the feed-suffix hint" || no "typo" "$(grep ENABELD <<<"$out")"
dout=$(nftban_cmd_config_local_doctor 2>&1)
grep -qE "UNKNOWN_KEY +FEED_A5LOCAL_ENABELD +\[$NFTBAN_CONFIG_DIR/conf.d/feeds.conf.local:3\]" <<<"$dout" && ok "doctor points to file:line of the typo" || no "doctor file:line" "$(grep ENABELD <<<"$dout")"
grep -qE 'OK +FEED_A5LOCAL_ENABLED' <<<"$dout" && ok "doctor: valid custom feed key OK" || no "doctor custom OK"
grep -q 'feed.example.invalid' <<<"$dout" && no "doctor printed a value" || ok "doctor prints no values"
rm -f "$NFTBAN_CONFIG_DIR/conf.d/feeds.conf.local"

echo "=== module subdirectory .local is inventoried ==="
# validate merges a .local only when its base .conf exists (nftban_config_load_effective), as on a real install
printf 'DDOS_ENABLED="true"\n' > "$NFTBAN_CONFIG_DIR/conf.d/ddos/main.conf"
printf 'DDOS_WHITELIST_FILE="/etc/nftban/x"\n' > "$NFTBAN_CONFIG_DIR/conf.d/ddos/main.conf.local"
_config_local_inventory | grep -q 'conf.d/ddos/main.conf.local' && ok "inventory includes conf.d/<module>/*.conf.local" || no "inventory"
dout=$(nftban_cmd_config_local_doctor 2>&1)
grep -qE 'DEPRECATED_KEY +DDOS_WHITELIST_FILE +\[.*conf.d/ddos/main.conf.local:1\]' <<<"$dout" && ok "doctor: deprecated key in a module .local, with file:line" || no "doctor module local" "$(grep DDOS <<<"$dout")"

echo "=== deprecated property in validate; fail2ban removed ==="
out=$(nftban_configtest 0 0 2>&1); rc=$?
grep -q 'DEPRECATED: DDOS_WHITELIST_FILE' <<<"$out" && [[ $rc -ne 0 ]] && ok "validate reports a deprecated property (was OK)" || no "deprecated property" "$(grep DDOS_WHITELIST <<<"$out")"
rm -f "$NFTBAN_CONFIG_DIR/conf.d/ddos/main.conf.local"
printf 'NFTBAN_FAIL2BAN_ENABLED="true"\n' >> "$NFTBAN_CONFIG_DIR/nftban.conf.local"
out=$(nftban_configtest 0 0 2>&1)
grep -q 'DEPRECATED: NFTBAN_FAIL2BAN_ENABLED - Fail2ban integration was removed in v1.0' <<<"$out" && grep -q 'no effect' <<<"$out" && ok "fail2ban key: removed in v1.0, no effect" || no "fail2ban" "$(grep FAIL2BAN <<<"$out")"

echo "=== --quiet ==="
q=$(nftban_cmd_config_test --quiet 2>&1); qrc=$?
nftban_cmd_config_test >/dev/null 2>&1; nrc=$?
[[ -z "$q" && $qrc -eq $nrc && $qrc -ne 0 ]] && ok "--quiet prints nothing and keeps the exit code ($qrc)" || no "--quiet" "out='${q:0:80}' qrc=$qrc nrc=$nrc"
stock; q=$(nftban_cmd_config_test --quiet 2>&1); qrc=$?
[[ -z "$q" && $qrc -eq 0 ]] && ok "--quiet on a clean config: no output, rc 0" || no "--quiet clean" "rc=$qrc"

echo ""
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
