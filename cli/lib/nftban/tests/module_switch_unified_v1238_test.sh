#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.238 D1/D2: one enable-switch rule for DDoS / PortScan / BotGuard
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="module_switch_unified_v1238_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-23"
# meta:description="v1.238 D1/D2 (owner 2026-11-23; lab4: central false + module yes -> kernel chains installed while the daemon and health said off). Asserts the unified rule on the REAL module_authority.sh: module main.conf < main.conf.local < central nftban.conf.local (explicit central wins) for ddos/portscan/botguard only, truth table true|yes|1|on|enabled, invalid values resolve off and are reported invalid with file; the writer targets the central file only when the key is defined there, otherwise the module .local; nftban_module_enable_state reports CONSISTENT / INCONSISTENT / UNKNOWN from stubbed nftband (modules IPC) and nft, and merges .enable_state into a JSON document. Asserts the REAL nftban_module_switch_preflight (shared package library): upgrade from 1.237.0 stops before any change when the new rule changes a module's decision (central false vs module yes; BotGuard 'enabled'; central HTTP_BOT* keys that differ), prints key, files and editor instructions, and proceeds when the files agree, for upgrades from >= 1.238.0 and with no previous version. Static: the rebuild never runs 'botguard enable' and uses the non-writing 'botguard apply'. Sandbox only; no firewall change."
# meta:input="None (repo source read-only; temp dirs)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,sh,jq,grep"
# meta:inventory.files="cli/lib/nftban/lib/module_authority.sh,cli/lib/nftban/lib/nftban_immutable_owned.sh,cli/lib/nftban/cli/cmd_firewall.sh,cli/lib/nftban/cli/cmd_botguard.sh"
# meta:inventory.binaries="bash,sh,jq,grep"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_RUN_DIR,NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="module_switch_unified_v1238_test"
# meta:ta.owner="core"
# meta:ta.module="module-authority"
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
export NFTBAN_CONFIG_DIR="$W/etc" NFTBAN_RUN_DIR="$W/run" NFTBAN_LIB_DIR="$LIB"
C="$W/etc/nftban.conf.local"
reset(){ rm -rf "${W:?}/etc"; mkdir -p "$W/etc/conf.d/ddos" "$W/etc/conf.d/portscan" "$W/etc/conf.d/botguard" "$W/run"
         printf 'DDOS_ENABLED="false"\n' > "$W/etc/conf.d/ddos/main.conf"
         printf 'PORTSCAN_ENABLED="false"\n' > "$W/etc/conf.d/portscan/main.conf"
         printf 'HTTP_BOTGUARD_ENABLED="false"\nHTTP_BOT_SUSPECT_RATE="30/second"\n' > "$W/etc/conf.d/botguard/main.conf"; }
ma(){ bash -c 'source "$NFTBAN_LIB_DIR/lib/module_authority.sh" >/dev/null 2>&1 || true; set +e; "$@"' _ "$@" 2>&1; }
gate(){ ma nftban_module_effective_enabled "$1" >/dev/null && echo on || echo off; }

echo "=== unified rule ==="
reset; printf 'DDOS_ENABLED="yes"\n' > "$W/etc/conf.d/ddos/main.conf.local"
[[ "$(gate ddos)" == on ]] && ok "module .local yes -> on (truth table)" || no "module yes"
printf 'DDOS_ENABLED="false"\n' > "$C"
[[ "$(gate ddos)" == off ]] && ok "explicit central false wins over module yes (lab4 case)" || no "central wins"
printf 'DDOS_ENABLED="true"\n' > "$C"; printf 'DDOS_ENABLED="false"\n' > "$W/etc/conf.d/ddos/main.conf.local"
[[ "$(gate ddos)" == on ]] && ok "explicit central true wins over module false" || no "central true"
reset; printf 'HTTP_BOTGUARD_ENABLED="enabled"\n' > "$W/etc/conf.d/botguard/main.conf.local"
[[ "$(gate botguard)" == on ]] && ok "BotGuard 'enabled' -> on (same table as the shell gate)" || no "botguard enabled"
reset; printf 'PORTSCAN_ENABLED="maybe"\n' > "$W/etc/conf.d/portscan/main.conf.local"
r=$(ma nftban_module_enable_resolve portscan)
[[ "$(gate portscan)" == off && "$r" == $'maybe\t'"$W/etc/conf.d/portscan/main.conf.local"$'\tinvalid' ]] && ok "invalid value -> off and reported invalid with its file" || no "invalid" "$r"
reset; printf 'GEOBAN_ENABLED="true"\n' > "$C"; mkdir -p "$W/etc/conf.d/geoban"; printf 'GEOBAN_ENABLED="false"\n' > "$W/etc/conf.d/geoban/main.conf"
[[ "$(gate geoban)" == off ]] && ok "GeoBan keeps its own rule (central not part of this gate)" || no "geoban unchanged"

echo "=== writer target + read-back ==="
reset; ma nftban_module_set_enabled portscan true >/dev/null
grep -qx 'PORTSCAN_ENABLED="true"' "$W/etc/conf.d/portscan/main.conf.local" && [[ ! -e "$C" ]] && ok "no central key -> module .local written" || no "module target"
printf 'PORTSCAN_ENABLED="false"\nOTHER="x"\n' > "$C"; ma nftban_module_set_enabled portscan true >/dev/null
grep -qx 'PORTSCAN_ENABLED="true"' "$C" && grep -qx 'OTHER="x"' "$C" && [[ "$(gate portscan)" == on ]] && ok "central key defined -> central updated (the file that wins); other lines kept" || no "central target" "$(cat "$C")"

echo "=== status: configuration / daemon / kernel ==="
mkdir -p "$W/bin"
python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$W/run/nftband.sock"
printf '#!/usr/bin/env bash\ncat >/dev/null; cat "%s/daemon.json"\n' "$W" > "$W/bin/socat"
printf '#!/usr/bin/env bash\n[[ -f "%s/chain_present" ]] && exit 0; echo "Error: No such file or directory" >&2; exit 1\n' "$W" > "$W/bin/nft"
chmod 755 "$W/bin/socat" "$W/bin/nft"
st(){ PATH="$W/bin:$PATH" ma nftban_module_enable_state ddos --json; }
reset; printf 'DDOS_ENABLED="false"\n' > "$C"; printf 'DDOS_ENABLED="yes"\n' > "$W/etc/conf.d/ddos/main.conf.local"
echo '{"data":[{"name":"ddos","enabled":false}]}' > "$W/daemon.json"; touch "$W/chain_present"
j=$(st); [[ "$(jq -r .state <<<"$j")" == INCONSISTENT && "$(jq -r .config.source <<<"$j")" == "$C" ]] && ok "lab4 situation -> INCONSISTENT, config source named" || no "inconsistent" "$j"
rm -f "$W/chain_present"
j=$(st); [[ "$(jq -r .state <<<"$j")" == CONSISTENT ]] && ok "config off, daemon off, chain absent -> CONSISTENT" || no "consistent" "$j"
echo 'not json' > "$W/daemon.json"
j=$(st); [[ "$(jq -r .state <<<"$j")" == UNKNOWN && "$(jq -r .daemon <<<"$j")" == null ]] && ok "daemon answer unreadable -> UNKNOWN (null), not a guess" || no "unknown" "$j"
m=$(PATH="$W/bin:$PATH" ma nftban_module_enable_state_merge ddos '{"success":true,"data":{"enabled":false}}')
jq -e '.data.enable_state.state and .data.enabled == false' >/dev/null <<<"$m" && ok "status JSON keeps its fields and gains .enable_state" || no "merge" "$m"

echo "=== upgrade check (shared package library) ==="
pf(){ sh -c '. "$1"; nftban_module_switch_preflight "$2"' _ "$LIB/lib/nftban_immutable_owned.sh" "$1" 2>&1; }
reset; printf 'DDOS_ENABLED="yes"\n' > "$W/etc/conf.d/ddos/main.conf.local"
rc=0; out=$(pf 1.237.0) || rc=$?; [[ $rc -eq 0 ]] && ok "no central keys -> upgrade proceeds" || no "compatible" "$out"
printf 'DDOS_ENABLED="false"\n' > "$C"
rc=0; out=$(pf 1.237.0) || rc=$?
[[ $rc -ne 0 && "$out" == *"DDoS (DDOS_ENABLED): today ON"*"after the upgrade OFF"* && "$out" == *"delete the DDOS_ENABLED line from $C"* \
   && "$out" == *"set DDOS_ENABLED=\"false\" in $W/etc/conf.d/ddos/main.conf.local"* && "$out" == *"nothing was changed"* ]] \
  && ok "central false vs module yes -> STOP, names key and files, editor instructions" || no "conflict stop" "rc=$rc $out"
rc=0; out=$(pf 1.238.0) || rc=$?; [[ $rc -eq 0 ]] && ok "upgrade from >= 1.238.0 -> not checked" || no "new version" "$out"
rc=0; out=$(pf "") || rc=$?; [[ $rc -eq 0 ]] && ok "no previous version (install) -> not checked" || no "install"
printf 'DDOS_ENABLED="yes"\n' > "$C"; rc=0; out=$(pf 1.237.0) || rc=$?; [[ $rc -eq 0 ]] && ok "files agree after the operator's edit -> proceeds" || no "resolved" "$out"
reset; printf 'HTTP_BOTGUARD_ENABLED="enabled"\n' > "$W/etc/conf.d/botguard/main.conf.local"
rc=0; out=$(pf 1.237.0) || rc=$?; [[ $rc -ne 0 && "$out" == *"BotGuard (HTTP_BOTGUARD_ENABLED): today OFF"* ]] && ok "BotGuard 'enabled' (off for the old daemon) -> STOP" || no "botguard enabled" "$out"
reset; printf 'HTTP_BOT_SUSPECT_RATE="10/second"\nHTTP_BOT_LOOP_SAME="x"\n' > "$C"; printf 'HTTP_BOT_LOOP_SAME="x"\n' > "$W/etc/conf.d/botguard/main.conf.local"
rc=0; out=$(pf 1.237.0) || rc=$?
[[ $rc -ne 0 && "$out" == *"BotGuard HTTP_BOT_SUSPECT_RATE: set in $C (ignored before 1.238)"* && "$out" != *"HTTP_BOT_LOOP_SAME"* && "$out" != *"10/second"* ]] \
  && ok "central HTTP_BOT* key that changes behaviour -> named (no value); identical key -> not listed" || no "http_bot keys" "$out"

echo "=== rebuild applies without writing ==="
grep -qE '^[^#]*nftban botguard enable' "$LIB/cli/cmd_firewall.sh" && no "rebuild still runs 'botguard enable'" || ok "rebuild never runs 'botguard enable'"
[[ "$(grep -c 'nftban botguard apply' "$LIB/cli/cmd_firewall.sh")" -ge 3 ]] && grep -q '^        apply)' "$LIB/cli/cmd_botguard.sh" && ok "rebuild uses the non-writing 'botguard apply'" || no "apply"

echo ""
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
