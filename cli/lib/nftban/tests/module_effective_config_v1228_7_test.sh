#!/usr/bin/env bash
# =============================================================================
# NFTBan - effective module-config authority (v1.228.7)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="module_effective_config_v1228_7_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-08"
# meta:description="Pins nftban_module_effective_enabled — the single lifecycle authority for is-module-on. Proves the two cases the old cmd_firewall.sh gates got wrong (main.conf=true with no .local was read as FALSE by the DDoS .local-only gate; main=true + .local=false could not be expressed by the PortScan .local-then-main gate) and that a generated fragment on disk is NEVER treated as authority (the config->runtime drift that ran DDoS on dns1/dns4 for months with effective config false)."
# meta:ta.id="module_effective_config_v1228_7_test"
# meta:ta.owner="firewall"
# meta:ta.module="effective-config-authority"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.blocking="true"
# meta:ta.timeout="60"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
# shellcheck source=/dev/null
export NFTBAN_LIB_DIR="$ROOT/cli/lib/nftban"
# shellcheck source=/dev/null
source "$ROOT/cli/lib/nftban/lib/module_authority.sh" 2>/dev/null || { echo "FAIL: source module_authority.sh"; exit 1; }

PASS=0; FAIL=0
ok(){ echo "  [PASS] $1"; PASS=$((PASS+1)); }
no(){ echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT
export NFTBAN_CONFIG_DIR="$D"; mkdir -p "$D/conf.d/ddos"
setmain(){ printf 'DDOS_ENABLED="%s"\n' "$1" > "$D/conf.d/ddos/main.conf"; }
setlocal(){ if [ "$1" = none ]; then rm -f "$D/conf.d/ddos/main.conf.local"; else printf 'DDOS_ENABLED="%s"\n' "$1" > "$D/conf.d/ddos/main.conf.local"; fi; }
eff(){ nftban_module_effective_enabled ddos DDOS_ENABLED && echo true || echo false; }

setmain true;  setlocal none;  [ "$(eff)" = true  ] && ok "BASE_TRUE_NO_LOCAL (the .local-only DDoS gate bug)" || no "base=true no local"
setmain false; setlocal none;  [ "$(eff)" = false ] && ok "BASE_FALSE_NO_LOCAL" || no "base=false"
setmain false; setlocal true;  [ "$(eff)" = true  ] && ok "LOCAL_OVERRIDE_ENABLE" || no "local enable"
setmain true;  setlocal false; [ "$(eff)" = false ] && ok "LOCAL_OVERRIDE_DISABLE (portscan gate couldn't express)" || no "local disable"
setmain true;  setlocal true;  [ "$(eff)" = true  ] && ok "BOTH_TRUE" || no "both true"
rm -f "$D/conf.d/ddos/main.conf"; setlocal none; [ "$(eff)" = false ] && ok "NO_CONFIG_SAFE_DEFAULT_FALSE" || no "no config"
setmain false; setlocal none; mkdir -p "$D/rules.d"; echo x > "$D/rules.d/20-ddos-classic.nft"
[ "$(eff)" = false ] && ok "FRAGMENT_ON_DISK_IS_NOT_AUTHORITY" || no "fragment authority leak"

echo "=== module_effective_config_v1228_7: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
