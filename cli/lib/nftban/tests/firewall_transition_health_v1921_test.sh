#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.192.1 — firewall transition health (PR-B) hermetic test
# =============================================================================
# meta:name="firewall_transition_health_v1921_test"
# meta:type="test"
# meta:version="1.192.1"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Harm-keyed transition health: pure diff/classify, healthy=zero counters, service-port/floor/table breaches, cadence no-alarm, v1.192.0 skeletal regression detected"
# meta:inventory.files=""
# meta:inventory.binaries="bash"
# meta:inventory.env_vars="FTH_STATE_FILE,FTH_SKIP_GATHER"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="firewall_transition_health_v1921_test"
# meta:ta.owner="firewall"
# meta:ta.module="firewall-transition-health"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
# shellcheck disable=SC2034  # FTH_* fixtures (set_healthy etc.) are consumed by
# the sourced helper via direct/indirect (${!var}) expansion — ShellCheck can't
# see that use across the source boundary.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
LIB="$SCRIPT_DIR/../core/nftban_firewall_transition_health.sh"
[[ -f "$LIB" ]] || { echo "FAIL: helper not found at $LIB"; exit 1; }

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
export FTH_STATE_FILE="$SB/fth.json"
export FTH_SKIP_GATHER=1   # use injected FTH_* vars, no nft/core

# shellcheck source=/dev/null
source "$LIB"

PASS=0; FAIL=0
ok(){ echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad(){ echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
code_of(){ echo "${1%%|*}"; }
reason_of(){ echo "${1#*|}"; }

# Healthy injected state: live == effective on all 4 sets x both families.
set_healthy() {
    FTH_EFF_TCPIN="22,80,443,993";  FTH_EFF_TCPOUT="25,53,80,443,587"
    FTH_EFF_UDPIN="53";             FTH_EFF_UDPOUT="53,123"
    FTH_LIVE_TCPIN_4="$FTH_EFF_TCPIN"; FTH_LIVE_TCPIN_6="$FTH_EFF_TCPIN"
    FTH_LIVE_TCPOUT_4="$FTH_EFF_TCPOUT"; FTH_LIVE_TCPOUT_6="$FTH_EFF_TCPOUT"
    FTH_LIVE_UDPIN_4="$FTH_EFF_UDPIN"; FTH_LIVE_UDPIN_6="$FTH_EFF_UDPIN"
    FTH_LIVE_UDPOUT_4="$FTH_EFF_UDPOUT"; FTH_LIVE_UDPOUT_6="$FTH_EFF_UDPOUT"
    FTH_FLOOR_4=Y; FTH_FLOOR_6=Y; FTH_TABLE_PRESENT=Y; FTH_COMMITTED=Y; FTH_IN_RECOVERY=N
}

echo "=== T1: _fth_missing (pure) ==="
[[ "$(_fth_missing '22,80,443,993' '80,443,22')" == "993" ]] && ok "missing reports 993" || bad "missing: got '$(_fth_missing '22,80,443,993' '80,443,22')'"
[[ -z "$(_fth_missing '80,443' '443,80,22')" ]] && ok "no missing when superset" || bad "false missing"
[[ "$(_fth_missing '53,123,443' '53')" == "123 443" ]] && ok "missing multiple" || bad "missing multi: '$(_fth_missing '53,123,443' '53')'"

echo "=== T2: _fth_classify (pure semantics) ==="
[[ "$(_fth_classify 0 0 0 0 0)" == "$HEALTH_OK" ]] && ok "all-zero => OK" || bad "all-zero not OK"
[[ "$(_fth_classify 3 0 0 0 0)" == "$HEALTH_ERROR" ]] && ok "svc>0 => ERROR/DEGRADED" || bad "svc not ERROR"
[[ "$(_fth_classify 0 1 0 0 0)" == "$HEALTH_CRITICAL" ]] && ok "floor>0 => CRITICAL" || bad "floor not CRITICAL"
[[ "$(_fth_classify 0 0 1 0 0)" == "$HEALTH_CRITICAL" ]] && ok "table-absent => CRITICAL" || bad "table not CRITICAL"
[[ "$(_fth_classify 0 0 0 1 0)" == "$HEALTH_CRITICAL" ]] && ok "blacklist-empty => CRITICAL" || bad "bl not CRITICAL"
[[ "$(_fth_classify 0 0 0 0 1)" == "$HEALTH_ERROR" ]] && ok "non-atomic => ERROR" || bad "na not ERROR"

echo "=== T3: healthy => zero harm counters + OK ==="
set_healthy
fth_record_transition rebuild 1500
[[ "$(_fth_json_get service_port_breach_count)" == "0" ]] && ok "svc counter 0 on healthy rebuild" || bad "svc counter not 0"
[[ "$(_fth_json_get floor_breach_count)" == "0" ]] && ok "floor counter 0" || bad "floor not 0"
[[ "$(_fth_json_get last_rebuild_atomic)" == "true" ]] && ok "last_rebuild_atomic=true" || bad "atomic flag wrong"
[[ "$(_fth_json_get last_trigger)" == "rebuild" ]] && ok "last_trigger=rebuild" || bad "trigger wrong"
[[ "$(_fth_json_get last_duration_ms)" == "1500" ]] && ok "last_duration_ms=1500" || bad "duration wrong"
[[ -z "$(_fth_json_get last_transition_anomaly_reason '')" ]] && ok "anomaly_reason empty on healthy (not \"0\")" || bad "anomaly_reason not empty: '$(_fth_json_get last_transition_anomaly_reason '')'"
[[ -z "$(_fth_json_get last_transition_anomaly_at '')" ]] && ok "anomaly_at empty on healthy" || bad "anomaly_at not empty"
r=$(fth_eval_health); [[ "$(code_of "$r")" == "$HEALTH_OK" ]] && ok "eval=OK on healthy" || bad "eval not OK: $r"

echo "=== T4: cadence — many healthy rebuilds, still zero counters / no DEGRADED ==="
for _ in $(seq 1 8); do fth_record_transition rebuild 900; done
[[ "$(_fth_json_get service_port_breach_count)" == "0" ]] && ok "8 healthy rebuilds => svc still 0 (no cadence alarm)" || bad "cadence inflated counter"
r=$(fth_eval_health); [[ "$(code_of "$r")" == "$HEALTH_OK" ]] && ok "eval OK after cadence" || bad "cadence caused non-OK: $r"

echo "=== T5: missing configured service port => breach + reason identifies set/family/port ==="
rm -f "$FTH_STATE_FILE"; set_healthy
FTH_LIVE_TCPIN_4="22,80,443"   # 993 missing on ip
FTH_LIVE_TCPIN_6="22,80,443"   # 993 missing on ip6
fth_record_transition rebuild 1200
sv=$(_fth_json_get service_port_breach_count)
[[ "$sv" -ge 1 ]] && ok "service_port_breach_count incremented ($sv)" || bad "svc not incremented"
r=$(fth_eval_health); [[ "$(code_of "$r")" == "$HEALTH_ERROR" ]] && ok "eval=DEGRADED on svc breach" || bad "eval not ERROR: $r"
echo "$(reason_of "$r")" | grep -q 'tcp_ports_in' && echo "$(reason_of "$r")" | grep -q '993' && ok "reason names tcp_ports_in + 993" || bad "reason missing set/port: $(reason_of "$r")"
echo "$(reason_of "$r")" | grep -q 'ip6' && ok "reason names ip6 family" || bad "reason missing family: $(reason_of "$r")"

echo "=== T6: floor missing => CRITICAL ==="
rm -f "$FTH_STATE_FILE"; set_healthy; FTH_FLOOR_4=N
r=$(fth_eval_health); [[ "$(code_of "$r")" == "$HEALTH_CRITICAL" ]] && ok "eval=CRITICAL on floor breach" || bad "floor eval not CRITICAL: $r"
echo "$(reason_of "$r")" | grep -qi 'floor' && ok "reason mentions floor" || bad "no floor reason: $(reason_of "$r")"

echo "=== T7: table absent while COMMITTED => CRITICAL + non_atomic bumped at record ==="
rm -f "$FTH_STATE_FILE"; set_healthy; FTH_TABLE_PRESENT=N; FTH_COMMITTED=Y; FTH_IN_RECOVERY=N
fth_record_transition rebuild 800
[[ "$(_fth_json_get table_absent_while_committed_count)" -ge 1 ]] && ok "table-absent counter incremented" || bad "table counter not incremented"
[[ "$(_fth_json_get non_atomic_rebuild_count)" -ge 1 ]] && ok "non_atomic bumped (harmful non-atomic)" || bad "non_atomic not bumped"
[[ "$(_fth_json_get last_rebuild_atomic)" == "false" ]] && ok "last_rebuild_atomic=false" || bad "atomic flag not false"
r=$(fth_eval_health); [[ "$(code_of "$r")" == "$HEALTH_CRITICAL" ]] && ok "eval=CRITICAL on table-absent" || bad "table eval not CRITICAL: $r"

echo "=== T8: table absent but IN RECOVERY => exempt (no breach) ==="
rm -f "$FTH_STATE_FILE"; set_healthy; FTH_TABLE_PRESENT=N; FTH_COMMITTED=Y; FTH_IN_RECOVERY=Y
_fth_compute_breaches
[[ "$FTH_B_TABLE" == "0" ]] && ok "recovery window exempts table-absent" || bad "recovery not exempt"

echo "=== T9: v1.192.0 skeletal regression detected as service-port breach ==="
rm -f "$FTH_STATE_FILE"; set_healthy
# durable/live skeletal {22,80,443} but effective has full set incl 993/995
FTH_EFF_TCPIN="22,80,443,993,995,8443"
FTH_LIVE_TCPIN_4="22,80,443"; FTH_LIVE_TCPIN_6="22,80,443"
r=$(fth_eval_health)
[[ "$(code_of "$r")" == "$HEALTH_ERROR" ]] && ok "skeletal mismatch => DEGRADED (regression caught)" || bad "skeletal not flagged: $r"
echo "$(reason_of "$r")" | grep -qE '993|995|8443' && ok "reason lists the dropped ports" || bad "reason lacks dropped ports: $(reason_of "$r")"

echo "=== T10: blacklist-empty note => CRITICAL ==="
rm -f "$FTH_STATE_FILE"; set_healthy; fth_record_transition rebuild 700   # seed healthy state
fth_note_blacklist_empty 42
[[ "$(_fth_json_get blacklist_empty_during_refresh_count)" -ge 1 ]] && ok "blacklist-empty counter incremented" || bad "bl counter not incremented"
r=$(fth_eval_health); [[ "$(code_of "$r")" == "$HEALTH_CRITICAL" ]] && ok "eval=CRITICAL on blacklist-empty" || bad "bl eval not CRITICAL: $r"

echo ""
echo "=== firewall_transition_health PR-B: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
