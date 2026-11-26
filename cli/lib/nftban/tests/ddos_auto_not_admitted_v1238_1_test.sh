#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.238.1: DDoS auto never selects the non-admitted suricata mode
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="ddos_auto_not_admitted_v1238_1_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-25"
# meta:description="v1.238.1 (owner GO 2026-11-25). DDoS/suricata is BROKEN in docs/MODE_ADMISSION_LEDGER.md (nothing consumes DDoS Suricata alerts). (1) Resolution, real nftban_module_resolve_plan: ddos auto + Suricata available -> classic / auto_suricata_mode_not_admitted; ddos auto + unavailable -> classic / auto_suricata_unavailable; ddos explicit suricata -> suricata / configured_suricata with the admission reason; portscan auto + available -> suricata / auto_suricata_available (unchanged). (2) KEY regression, the TRANSITION: DDoS enabled in auto with classic active, then Suricata becomes available (stubbed predicate), the REAL nftban_ddos_reconcile runs again: the classic projection is NOT torn down (no nftban_ddos_classic_disable, no suricata enable; classic enable runs). (3) status JSON carries the persistent mode_warning for explicit suricata. Non-vacuity: at 0b013b3c (2) tears classic down and (1) resolves suricata. Sandbox only: config, run, writers, log dirs in a temp dir; projection functions are call recorders; no nft, no firewall change."
# meta:input="cli/lib/nftban/lib/module_authority.sh, cli/lib/nftban/core/nftban_ddos.sh (repo, read-only)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure, 2 NOT_EXECUTED (precondition)"
# meta:depends="bash,flock,jq"
# meta:inventory.files="cli/lib/nftban/lib/module_authority.sh,cli/lib/nftban/core/nftban_ddos.sh"
# meta:inventory.binaries="bash,flock,jq"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR,NFTBAN_RUN_DIR,NFTBAN_WRITERS_DIR,NFTBAN_PLAN_RECORD_DIR,NFTBAN_LOG_DIR,NFTBAN_DATA_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="ddos_auto_not_admitted_v1238_1_test"
# meta:ta.owner="cli"
# meta:ta.module="mode-authority"
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
LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for b in flock jq; do command -v "$b" >/dev/null 2>&1 || { echo "NOT_EXECUTED: '$b' missing (precondition)"; exit 2; }; done
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }; no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT

world() { # fresh sandbox: <ddos_mode> <portscan_mode>
    rm -rf "${W:?}/w"; mkdir -p "$W/w/etc/conf.d/ddos" "$W/w/etc/conf.d/portscan" "$W/w/run" "$W/w/log" "$W/w/data"
    chmod 0700 "$W/w/run"
    printf 'DDOS_ENABLED="true"\nDDOS_MODE="%s"\n' "$1" > "$W/w/etc/conf.d/ddos/main.conf"
    printf 'PORTSCAN_ENABLED="true"\nPORTSCAN_MODE="%s"\n' "$2" > "$W/w/etc/conf.d/portscan/main.conf"
    : > "$W/w/calls"
}
ENV=(env -i PATH=/usr/bin:/bin HOME="$W" TMPDIR="$W" NFTBAN_LIB_DIR="$LIBDIR" NFTBAN_DDOS_LIB_DIR="$LIBDIR"
     NFTBAN_CONFIG_DIR="$W/w/etc" NFTBAN_RUN_DIR="$W/w/run" NFTBAN_WRITERS_DIR="$W/w/run"
     NFTBAN_PLAN_RECORD_DIR="$W/w/run" NFTBAN_PLAN_GENERATION_FILE="$W/w/run/convergence-generation"
     NFTBAN_LOG_DIR="$W/w/log" NFTBAN_DATA_DIR="$W/w/data"
     NFTBAN_STATE_DIR="$W/w/data/state" CALLS="$W/w/calls")

resolve() { # <module> <available:0|1> -> "effective basis"
    "${ENV[@]}" AVAIL="$2" bash -c '
        source "$NFTBAN_LIB_DIR/lib/module_authority.sh" >/dev/null 2>&1 || exit 9
        nftban_ddos_suricata_is_available()     { return "$AVAIL"; }
        nftban_portscan_suricata_is_available() { return "$AVAIL"; }
        eval "$(nftban_module_resolve_plan "$1")"
        echo "$NFTBAN_PLAN_EFFECTIVE_MODE $NFTBAN_PLAN_RESOLUTION_BASIS"' _ "$1"
}

echo "=== (1) resolution ==="
world auto auto
r=$(resolve ddos 0);     [[ "$r" == "classic auto_suricata_mode_not_admitted" ]] && ok "ddos auto + Suricata available -> classic / auto_suricata_mode_not_admitted" || no "ddos auto + available" "$r"
r=$(resolve ddos 1);     [[ "$r" == "classic auto_suricata_unavailable" ]] && ok "ddos auto + unavailable -> classic / auto_suricata_unavailable (unchanged)" || no "ddos auto + unavailable" "$r"
r=$(resolve portscan 0); [[ "$r" == "suricata auto_suricata_available" ]] && ok "portscan auto + available -> suricata (unchanged, it has a consumer)" || no "portscan auto + available" "$r"
world suricata auto
r=$(resolve ddos 0);     [[ "$r" == "suricata configured_suricata" ]] && ok "ddos explicit suricata stays honoured" || no "ddos explicit suricata" "$r"
w=$("${ENV[@]}" bash -c 'source "$NFTBAN_LIB_DIR/lib/module_authority.sh" >/dev/null 2>&1; nftban_module_mode_unadmitted ddos suricata' 2>/dev/null)
[[ "$w" == *"does not consume DDoS alerts in suricata mode"* ]] && ok "admission reason for ddos:suricata" || no "admission reason" "$w"
"${ENV[@]}" bash -c 'source "$NFTBAN_LIB_DIR/lib/module_authority.sh" >/dev/null 2>&1; ! nftban_module_mode_unadmitted portscan suricata && ! nftban_module_mode_unadmitted ddos classic' \
    && ok "portscan:suricata and ddos:classic are admitted" || no "admission scope too wide"

echo "=== (2) transition: classic active, Suricata becomes available, reconcile again ==="
world auto auto
reconcile() { # <available:0|1>
    "${ENV[@]}" AVAIL="$1" bash -c '
        source "$NFTBAN_LIB_DIR/core/nftban_ddos.sh" >/dev/null 2>&1 || exit 9
        set +e   # the module enables errexit; the harness must record the rc, not die on it
        rec() { echo "$1" >> "$CALLS"; return 0; }
        nftban_ddos_suricata_is_available() { return "$AVAIL"; }
        nftban_ddos_classic_enable()   { rec classic_enable; }
        nftban_ddos_classic_disable()  { rec classic_disable; }
        nftban_ddos_suricata_enable()  { rec suricata_enable; }
        nftban_ddos_suricata_disable() { rec suricata_disable; }
        nftban_ddos_suricata_get_status() { echo stub; }
        _nftban_ddos_banner() { :; }
        nftban_ddos_reconcile >/dev/null 2>&1; echo "rc=$?" >> "$CALLS"'
}
reconcile 1
grep -qx classic_enable "$W/w/calls" && ok "baseline: classic applied while Suricata is unavailable" \
    || no "baseline did not apply classic (harness)" "$(tr '\n' ' ' < "$W/w/calls")"
: > "$W/w/calls"
reconcile 0
calls=$(tr '\n' ' ' < "$W/w/calls")
grep -qx 'rc=0' "$W/w/calls" && ok "reconcile after Suricata became available: rc 0" || no "reconcile rc" "$calls"
grep -qx classic_disable "$W/w/calls" && no "CLASSIC TORN DOWN after Suricata became available" "$calls" \
    || ok "classic projection NOT torn down (no classic_disable)"
grep -qx suricata_enable "$W/w/calls" && no "suricata mode applied under auto" "$calls" || ok "no suricata enable under auto"
grep -qx classic_enable "$W/w/calls" && ok "classic kept/applied" || no "classic not applied" "$calls"
pf=$(ls "$W/w/run"/module-plan-ddos* 2>/dev/null | tail -1)
grep -q 'auto_suricata_mode_not_admitted' "$pf" 2>/dev/null && ok "plan record basis auto_suricata_mode_not_admitted" \
    || no "plan record basis" "$(grep -h BASIS "$W/w/run"/module-plan-ddos* 2>/dev/null | tr '\n' ' ')"

echo "=== (3) persistent warning for explicit suricata (status JSON) ==="
world suricata auto
j=$("${ENV[@]}" bash -c 'source "$NFTBAN_LIB_DIR/core/nftban_ddos.sh" >/dev/null 2>&1; _nftban_ddos_status_json suricata suricata' 2>/dev/null)
[[ "$(jq -r '.mode_warning // empty' <<<"$j" 2>/dev/null)" == *"does not consume DDoS alerts"* ]] && ok "status JSON mode_warning present for suricata" || no "status JSON warning" "$j"
j=$("${ENV[@]}" bash -c 'source "$NFTBAN_LIB_DIR/core/nftban_ddos.sh" >/dev/null 2>&1; _nftban_ddos_status_json classic auto' 2>/dev/null)
[[ "$(jq -r '.mode_warning' <<<"$j" 2>/dev/null)" == null ]] && ok "no warning for classic" || no "warning on classic" "$j"

echo ""
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
