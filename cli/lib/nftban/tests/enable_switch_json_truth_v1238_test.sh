#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.238 botguard status --json and ddos stats --json report the enable decision truthfully
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="enable_switch_json_truth_v1238_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-23"
# meta:description="v1.238 (owner 2026-11-23, D1/D2 lab4 check): `nftban botguard status --json` printed \"enabled\":yes (invalid JSON) when the module .local said yes, and `nftban ddos stats --json` read only the shipped main.conf and said enabled:false while DDoS was enforcing from main.conf.local. Asserts: both botguard JSON producers map the value with the module-gate truth table (true|yes|1|on|enabled -> true, anything else -> false) into a JSON boolean, so every value renders valid JSON; the REAL _nftban_ddos_stats_json, with main.conf false and main.conf.local yes in a sandbox, reports ddos enabled true (the same decision as nftban_module_effective_enabled) and emits valid JSON. Sandbox only."
# meta:input="None (repo source read-only; temp dirs)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,jq,awk,grep"
# meta:inventory.files="cli/lib/nftban/cli/cmd_botguard.sh,cli/lib/nftban/cli/cmd_ddos.sh,cli/lib/nftban/lib/module_authority.sh"
# meta:inventory.binaries="bash,jq,awk,grep"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_LIB_DIR,NFTBAN_LOG_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="enable_switch_json_truth_v1238_test"
# meta:ta.owner="core"
# meta:ta.module="ddos"
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
LIB="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }; no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
command -v jq >/dev/null || { echo "SKIP: jq missing"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

echo "=== botguard: JSON boolean ==="
[[ "$(grep -c 'case "${enabled,,}" in true|yes|1|on|enabled) enabled_json=true ;; \*) enabled_json=false ;; esac' "$LIB/cli/cmd_botguard.sh")" == 2 ]] \
  && ok "both botguard JSON producers map the value with the module-gate truth table" || no "enabled_json mapping"
[[ "$(grep -c '"$enabled_json"' "$LIB/cli/cmd_botguard.sh")" == 2 ]] && ok "both botguard JSON outputs print the boolean (status, config)" || no "printf sites"
for v in true yes YES 1 on enabled false no 0 bogus ""; do
  r=$(bash -c 'enabled="$1"; case "${enabled,,}" in true|yes|1|on|enabled) enabled_json=true ;; *) enabled_json=false ;; esac; printf "{\"enabled\":%s}" "$enabled_json"' _ "$v")
  jq -e . >/dev/null 2>&1 <<<"$r" || no "invalid JSON for '$v'"
done
ok "every value renders valid JSON"

echo "=== ddos stats --json follows the module decision ==="
mkdir -p "$W/etc/conf.d/ddos" "$W/log"
printf 'DDOS_ENABLED="false"\nDDOS_MODE="classic"\n' > "$W/etc/conf.d/ddos/main.conf"
printf 'DDOS_ENABLED="yes"\n' > "$W/etc/conf.d/ddos/main.conf.local"
dfn=$(awk '/^_nftban_ddos_stats_json\(\) \{/ {f=1} f {print} f && /^\}/ {f=0}' "$LIB/cli/cmd_ddos.sh")
out=$(NFTBAN_CONFIG_DIR="$W/etc" NFTBAN_LIB_DIR="$LIB" NFTBAN_LOG_DIR="$W/log" PATH="$W:$PATH" bash -c '
  systemctl(){ return 3; }; nft(){ return 1; }
  json_output(){ printf "%s\n" "$2"; }
  source "$NFTBAN_LIB_DIR/lib/module_authority.sh" >/dev/null 2>&1 || true
  eval "$1"; _nftban_ddos_stats_json true' _ "$dfn" 2>/dev/null)
jq -e . >/dev/null 2>&1 <<<"$out" && ok "valid JSON" || no "invalid JSON" "$out"
[[ "$(jq -r '[.. | objects | select(has("enabled")) | .enabled][0]' <<<"$out" 2>/dev/null)" == true ]] \
  && ok "main.conf false + main.conf.local yes -> enabled true (same as the module gate; was false)" || no "ddos enabled" "$out"

echo ""
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
