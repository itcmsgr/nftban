#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.238.2: an explicit PortScan switch to suricata never leaves no detector
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="portscan_switch_keeps_classic_v1238_2_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-28"
# meta:description="v1.238.2 (owner 2026-11-28, RC row 11; BUG-PORTSCAN-MODE-SWITCH-NO-PLAN-UNTIL-REBUILD). MEASURED on EL9 enforcing: classic->suricata via mode set + restart (both rc 0) removed the classic projection, then enable refused ('Suricata is not available') and neither detector ran for 19+ min. Sources the REAL module_authority.sh and nftban_portscan_suricata.sh in a sandbox. Resolver: configured portscan suricata + nftban_portscan_suricata_ready TRUE -> effective suricata (configured_suricata); FALSE -> effective classic, basis configured_suricata_unavailable_kept_classic + a WARN that the transition is INCOMPLETE; readiness function absent -> classic (configured_suricata_module_not_loaded_kept_classic); DDoS configured suricata is unchanged. Enable: the same readiness (binary + service), not EVE freshness: a ready Suricata with a stale alert file enables; a stopped service refuses. Non-vacuity: the v1.238.1 resolver returns suricata when not ready, and enable refuses on a stale EVE file. Sandbox only; no firewall change."
# meta:input="cli/lib/nftban/lib/module_authority.sh, cli/lib/nftban/core/nftban_portscan_suricata.sh (repo, read-only); temp dirs"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,mktemp,grep,touch"
# meta:inventory.files="cli/lib/nftban/lib/module_authority.sh,cli/lib/nftban/core/nftban_portscan_suricata.sh"
# meta:inventory.binaries="bash,mktemp,grep,touch"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR,NFTBAN_LOG_DIR,PORTSCAN_SURICATA_BINARY,PORTSCAN_SURICATA_EVE_FILE"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="portscan_switch_keeps_classic_v1238_2_test"
# meta:ta.owner="portscan"
# meta:ta.module="portscan"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -uo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }; no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
mkdir -p "$W/etc/conf.d/portscan" "$W/etc/conf.d/ddos" "$W/bin" "$W/log"
printf 'PORTSCAN_ENABLED="true"\nPORTSCAN_MODE="suricata"\n' > "$W/etc/conf.d/portscan/main.conf"
printf 'DDOS_ENABLED="true"\nDDOS_MODE="suricata"\n'        > "$W/etc/conf.d/ddos/main.conf"
# pgrep must never find a real Suricata on the test host
printf '#!/bin/sh\nexit 1\n' > "$W/bin/pgrep"; chmod +x "$W/bin/pgrep"
printf '#!/bin/sh\nexit 0\n' > "$W/bin/suri"; chmod +x "$W/bin/suri"

# resolve <module> <ready: yes|no|absent> -> "EFFECTIVE BASIS WARN?"
resolve() {
    env -i PATH="$W/bin:/usr/bin:/bin" HOME="$W" NFTBAN_LIB_DIR="$LIB" NFTBAN_CONFIG_DIR="$W/etc" R="$2" bash -c '
        source "$1/lib/module_authority.sh" >/dev/null 2>&1 || { echo SOURCE_FAILED; exit 9; }
        case "$R" in
            yes) nftban_portscan_suricata_ready(){ return 0; } ;;
            no)  nftban_portscan_suricata_ready(){ return 1; } ;;
        esac
        out=$(nftban_module_resolve_plan "$2" 2>"$3/err") || { echo "RESOLVE_RC=$?"; exit 0; }
        e=$(grep "^NFTBAN_PLAN_EFFECTIVE_MODE=" <<<"$out" | cut -d= -f2)
        b=$(grep "^NFTBAN_PLAN_RESOLUTION_BASIS=" <<<"$out" | cut -d= -f2)
        w=no; grep -q "transition INCOMPLETE" "$3/err" && w=yes
        echo "$e $b warn=$w"' _ "$LIB" "$1" "$W"
}

echo "=== resolver: explicit portscan suricata ==="
r=$(resolve portscan yes)
[[ "$r" == "suricata configured_suricata warn=no" ]] && ok "ready -> effective suricata, no warning" || no "ready" "$r"
r=$(resolve portscan no)
[[ "$r" == "classic configured_suricata_unavailable_kept_classic warn=yes" ]] && ok "not ready -> classic KEPT, transition reported incomplete" || no "not ready" "$r"
r=$(resolve portscan absent)
[[ "$r" == "classic configured_suricata_module_not_loaded_kept_classic warn=yes" ]] && ok "readiness unknown -> classic KEPT" || no "absent" "$r"
r=$(resolve ddos no)
[[ "$r" == "suricata configured_suricata warn=no" ]] && ok "DDoS explicit suricata is unchanged (owner scope)" || no "ddos" "$r"

# enable <service: up|down> <eve: stale|fresh> -> rc
enable() {
    local eve="$W/eve-alerts.json"; : > "$eve"
    [[ "$2" == stale ]] && touch -d '-2 hours' "$eve"
    env -i PATH="$W/bin:/usr/bin:/bin" HOME="$W" NFTBAN_LIB_DIR="$LIB" NFTBAN_CONFIG_DIR="$W/etc" NFTBAN_LOG_DIR="$W/log" \
        PORTSCAN_SURICATA_BINARY="$W/bin/suri" PORTSCAN_SURICATA_EVE_FILE="$eve" PORTSCAN_SURICATA_STATE_FILE="$W/st.db" S="$1" bash -c '
        source "$1/core/nftban_portscan_suricata.sh" >/dev/null 2>&1 || { echo 9; exit 0; }
        nftban_service_is_active(){ [[ "$S" == up ]]; }
        nftban_portscan_suricata_load_config >/dev/null 2>&1 || true
        set +e   # the sourced file sets -e; a refusal (rc 1) must be reported, not end the shell
        nftban_portscan_suricata_enable >/dev/null 2>&1; echo $?' _ "$LIB"
}

echo "=== enable: the same readiness, not EVE freshness ==="
r=$(enable up stale);  [[ "$r" == 0 ]] && ok "ready Suricata with a stale alert file -> enabled" || no "up+stale" "rc=$r"
r=$(enable up fresh);  [[ "$r" == 0 ]] && ok "ready Suricata, fresh alert file -> enabled" || no "up+fresh" "rc=$r"
r=$(enable down fresh); [[ "$r" == 1 ]] && ok "service stopped -> refused" || no "down" "rc=$r"
grep -q 'Suricata is not ready (binary: .*; service: not running)' "$W/log/portscan-suricata.log" 2>/dev/null \
    && ok "the refusal names binary and service state" || no "refusal log line" "$(tail -2 "$W/log/portscan-suricata.log" 2>/dev/null)"

echo ""
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
