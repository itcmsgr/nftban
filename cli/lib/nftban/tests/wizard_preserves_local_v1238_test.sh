#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.238 nftban wizard / profile keep the operator's other settings
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="wizard_preserves_local_v1238_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-23"
# meta:description="v1.238 D3 (owner GO 2026-11-23): nftban wizard (also launched by nftban profile) replaced /etc/nftban/nftban.conf.local with `cat >`, losing every unrelated setting (installer SSH_PORT / TCP_PORTS_IN, NFTBAN_FEEDS_ENABLED, FEED_*). Drives the REAL _wizard_write_config on a temporary config: unrelated lines and comments are kept byte-for-byte, the wizard's own keys are set exactly once through nftban_config_kv_set, a second run adds no duplicates, and a backup of the previous file is kept. Sandbox only."
# meta:input="None (repo source read-only; temp dirs)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,grep,awk"
# meta:inventory.files="cli/lib/nftban/cli/cmd_wizard.sh,cli/lib/nftban/lib/nftban_config_kv.sh"
# meta:inventory.binaries="bash,grep,awk"
# meta:inventory.env_vars="NFTBAN_CONFIG_LOCAL,NFTBAN_PROFILE_CURRENT,NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="wizard_preserves_local_v1238_test"
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
LIB="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }; no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
export NFTBAN_LIB_DIR="$LIB" NFTBAN_CONFIG_LOCAL="$W/nftban.conf.local" NFTBAN_PROFILE_CURRENT="$W/profile.current"
cat > "$NFTBAN_CONFIG_LOCAL" <<'EOF'
# operator comment kept
SSH_PORT="2222"
TCP_PORTS_IN="2222,443"
NFTBAN_FEEDS_ENABLED="true"
FEED_TOR_EXITS_ENABLED="true"
ENABLE_DDOS=0
EOF
keep=$(grep -vE '^ENABLE_DDOS=' "$NFTBAN_CONFIG_LOCAL")
fn=$(awk '/^_wizard_write_config\(\) \{/ {f=1} f {print} f && /^\}/ {f=0}' "$LIB/cli/cmd_wizard.sh")
run(){ bash -c 'mkdir(){ :; }; chown(){ :; }
  PROFILE_ENV=web PROFILE_SECURITY_LEVEL=high PROFILE_TRAFFIC_LEVEL=low ENABLE_DDOS=1 ENABLE_PORTSCAN=1 ENABLE_LOGIN_MONITOR=1
  ENABLE_FEEDS=0 ENABLE_GEOBAN=0 ENABLE_IDS_INTEGRATION=0 ENABLE_GUI=0 ENABLE_METRICS=0 SSH_PROTECT_LEVEL=2 SSH_PORTS=22
  WEB_TCP_PORTS="80 443" MAIL_TCP_PORTS="" DB_TCP_PORTS="" DDOS_SYNFLOOD_RATE="100/second" DDOS_SYNFLOOD_BURST=200
  DDOS_CONN_LIMIT_PER_IP=50 PORTSCAN_THRESHOLD=20 PORTSCAN_WINDOW_SECONDS=60 PORTSCAN_BAN_DURATION_SECONDS=3600
  LOGIN_MAX_ATTEMPTS=5 LOGIN_BAN_DURATION_SECONDS=3600
  eval "$1"; _wizard_write_config' _ "$fn" 2>&1; }

out=$(run); rc=$?
[[ $rc -eq 0 ]] && ok "wizard write succeeded" || no "wizard rc=$rc" "$out"
while IFS= read -r l; do grep -qxF "$l" "$NFTBAN_CONFIG_LOCAL" || no "unrelated line lost: $l"; done <<<"$keep"
grep -qxF 'SSH_PORT="2222"' "$NFTBAN_CONFIG_LOCAL" && grep -qxF 'FEED_TOR_EXITS_ENABLED="true"' "$NFTBAN_CONFIG_LOCAL" \
  && grep -qxF '# operator comment kept' "$NFTBAN_CONFIG_LOCAL" && ok "unrelated settings and comments kept (SSH_PORT, TCP_PORTS_IN, feeds)" || no "preservation"
[[ "$(grep -c '^ENABLE_DDOS=' "$NFTBAN_CONFIG_LOCAL")" == 1 ]] && grep -qxF 'ENABLE_DDOS="1"' "$NFTBAN_CONFIG_LOCAL" && ok "wizard key updated in place (exactly once)" || no "ENABLE_DDOS" "$(grep ENABLE_DDOS "$NFTBAN_CONFIG_LOCAL")"
grep -qxF 'PROFILE_ENV="web"' "$NFTBAN_CONFIG_LOCAL" && ok "new wizard keys appended" || no "new keys"
ls "$W"/nftban.conf.local.wizard-backup-* >/dev/null 2>&1 && ok "previous file kept as a backup" || no "backup"
before=$(sha256sum "$NFTBAN_CONFIG_LOCAL"); sleep 1; run >/dev/null
[[ "$(sha256sum "$NFTBAN_CONFIG_LOCAL")" == "$before" ]] && ok "second run: same content, no duplicates" || no "second run changed the file" "$(sort "$NFTBAN_CONFIG_LOCAL" | uniq -d)"
grep -q 'cat > "\$NFTBAN_CONFIG_LOCAL"' "$LIB/cli/cmd_wizard.sh" && no "cmd_wizard.sh still truncates the file" || ok "no truncating write left in cmd_wizard.sh"

echo ""
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
