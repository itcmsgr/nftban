#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.235 - health renders validator verdicts; status survives damaged state
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="health_status_verdict_truth_v1235_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-06"
# meta:description="BUG-HEALTH-TREATS-VALIDATOR-DEGRADED-VERDICT-AS-TRUTH-FAILED + BUG-STATUS-ABORTS-ON-DAMAGED-BOTSCAN-RUNSTATE (v1.235; both measured by the RC smoke on lab3 v1.234.0). Runs the REAL dispatcher (cli/sbin/nftban) against a sandbox copy of the library whose bin/nftban-validate is a stub emitting a real validator document (captured from a lab host, no addresses) with a chosen status and exit code. Health arms: V1 rc 0 protected -> Overall PROTECTED, rc 0; V2 rc 1 degraded -> Overall DEGRADED with the finding, NOT 'Truth: FAILED', rc 1, --json status degraded and no truth=failed; V3 rc 2 down -> Overall DOWN rendered from the document, rc 2; V4 rc 3 (execution error) -> 'Truth: FAILED', rc 2; V5 rc 1 with invalid JSON -> 'Truth: FAILED'. Status arms: S1 a truncated botscan runstate.json -> no ERR banner, 'run-state UNREADABLE' shown; S2 a truncated firewall_transition_health.json -> 'FW Transition' UNKNOWN, no 'OK', no banner. Every arm asserts no ERR-trap banner. Set VERDICT_SUBJECT_ROOT to an older tree (e.g. e79a1173): V2, V3, S1 and S2 must FAIL there."
# meta:inventory.files="health_status_verdict_truth_v1235_test.sh"
# meta:inventory.binaries="bash,cp,jq,mktemp"
# meta:inventory.env_vars="VERDICT_SUBJECT_ROOT"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# meta:ta.id="health_status_verdict_truth_v1235_test"
# meta:ta.owner="health"
# meta:ta.module="health-truth"
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
IFS=$'\n\t'
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../../../.." && pwd)"
ROOT="${VERDICT_SUBJECT_ROOT:-$REPO}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

echo "=== v1.235: health renders validator verdicts; status survives damaged state ==="
for b in jq cp; do command -v "$b" >/dev/null || { echo "  NOT_EXECUTED: $b missing"; echo "RESULT: NOT_EXECUTED"; exit 3; }; done
[[ -x "$ROOT/cli/sbin/nftban" && -d "$ROOT/cli/lib/nftban" ]] || { echo "  NOT_EXECUTED: subject missing under $ROOT"; echo "RESULT: NOT_EXECUTED"; exit 3; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
cp -r "$ROOT/cli/lib/nftban" "$W/lib"
mkdir -p "$W/lib/bin" "$W/etc/conf.d/botscan" "$W/data/botscan" "$W/data/botguard" "$W/state" "$W/log" "$W/run" "$W/cache" "$W/stub"

# A real validator document (lab host, protected) with status/findings replaced per arm.
cat > "$W/doc.json" <<'DOC'
{"schema_version":"1.84.0","status":"protected","timestamp":"2026-10-06T16:06:48Z",
 "service_state":{"nftband":"RUNNING","nftband_detail":"active","timer_count":11},
 "modules":{"botguard":{"config":"disabled"},"ddos":{"config":"enabled","structural":"present","effective":"enforcing"},
  "portscan":{"config":"disabled"},"loginmon":{"config":"enabled","structural":"present","runtime":"running","effective":"idle"},
  "blacklist":{"manual":{"state":"enforcing","entries":19,"drops":4211},"feeds":{"state":"disabled"},"geoban":{"state":"loaded"}}},
 "consistency":{"kernel_vs_validator":"ok"},"findings":[],
 "chain_counts":{"ipv4_total":7,"ipv4_base":3,"ipv4_helper":0,"ipv6_total":7,"ipv6_base":3,"ipv6_helper":0,"total_chains":14},
 "summary":{"total_findings":0,"critical_findings":0,"error_findings":0,"warn_findings":0,"checked_families":2,"protected_families":2,"degraded_families":0},
 "counters_phase":"contract"}
DOC
jq '.status="degraded" | .findings=[{"id":"VAL-CONS-002","severity":"error","message":"ddos: mode is auto and no authoritative resolved plan was observed"}] | .summary.error_findings=1 | .summary.total_findings=1' "$W/doc.json" > "$W/doc_degraded.json"
jq '.status="down"' "$W/doc.json" > "$W/doc_down.json"
printf '{"status": "deg' > "$W/doc_invalid.json"

# Stub validator: prints $STUB_DOC (if set), writes $STUB_ERR to stderr, exits $STUB_RC.
cat > "$W/lib/bin/nftban-validate" <<'STUB'
#!/bin/sh
[ -n "${STUB_DOC:-}" ] && cat "$STUB_DOC"
[ -n "${STUB_ERR:-}" ] && echo "$STUB_ERR" >&2
exit "${STUB_RC:-0}"
STUB
chmod 0755 "$W/lib/bin/nftban-validate"
# nft that cannot read the kernel: status must still complete.
printf '#!/bin/sh\nexit 1\n' > "$W/stub/nft"; chmod 0755 "$W/stub/nft"

run(){ # <out-prefix> <args...>  (env STUB_* set by caller)
    local o="$1"; shift
    local rc=0
    PATH="$W/stub:$PATH" NFTBAN_LIB_DIR="$W/lib" NFTBAN_CONFIG_DIR="$W/etc" NFTBAN_DATA_DIR="$W/data" \
        NFTBAN_STATE_DIR="$W/state" NFTBAN_LOG_DIR="$W/log" NFTBAN_RUN_DIR="$W/run" NFTBAN_CACHE_DIR="$W/cache" \
        NFTBAN_ENABLE_ERROR_LOGGING=0 timeout 120 "$ROOT/cli/sbin/nftban" "$@" >"$W/$o.out" 2>"$W/$o.err" </dev/null || rc=$?
    echo "$rc" > "$W/$o.rc"
}
banner(){ grep -qsE 'ERROR: Script failed|unbound variable|command not found' "$W/$1.out" "$W/$1.err"; }
has(){ grep -qsF -- "$2" "$W/$1.out"; }

# ---- health arms --------------------------------------------------------------------
STUB_DOC="$W/doc.json" STUB_RC=0 run v1 health
has v1 "PROTECTED" && [[ "$(cat "$W/v1.rc")" == 0 ]] && ! banner v1 && ok "V1 rc 0 protected -> PROTECTED, rc 0" \
    || no "V1 protected verdict" "rc=$(cat "$W/v1.rc") $(grep -m1 Overall "$W/v1.out" || true)"

STUB_DOC="$W/doc_degraded.json" STUB_RC=1 run v2 health
if grep -qsE 'Overall:[[:space:]]+DEGRADED' "$W/v2.out" && ! has v2 "Truth:" && [[ "$(cat "$W/v2.rc")" == 1 ]] && ! banner v2; then
    ok "V2 rc 1 degraded -> Overall DEGRADED rendered from the document, rc 1"
else
    no "V2 degraded verdict misreported" "rc=$(cat "$W/v2.rc") $(grep -hm2 -E 'Overall|Truth' "$W/v2.out" | tr '\n' ' ')"
fi
STUB_DOC="$W/doc_degraded.json" STUB_RC=1 run v2j health --json
if [[ "$(jq -r '.status // empty' "$W/v2j.out" 2>/dev/null)" == degraded && "$(jq -r '.truth // empty' "$W/v2j.out" 2>/dev/null)" != failed && "$(cat "$W/v2j.rc")" == 1 ]]; then
    ok "V2 --json: status degraded, no truth=failed, rc 1"
else
    no "V2 --json degraded misreported" "rc=$(cat "$W/v2j.rc") $(head -c 160 "$W/v2j.out" | tr '\n' ' ')"
fi

STUB_DOC="$W/doc_down.json" STUB_RC=2 run v3 health
if grep -qsE 'Overall:[[:space:]]+DOWN' "$W/v3.out" && ! has v3 "Truth:" && [[ "$(cat "$W/v3.rc")" == 2 ]] && ! banner v3; then
    ok "V3 rc 2 down -> Overall DOWN rendered from the document, rc 2 (SF-1 contract kept)"
else
    no "V3 down verdict misreported" "rc=$(cat "$W/v3.rc") $(grep -hm2 -E 'Overall|Truth' "$W/v3.out" | tr '\n' ' ')"
fi

STUB_DOC="" STUB_ERR="Validation error: nft list ruleset: permission denied" STUB_RC=3 run v4 health
has v4 "Truth:" && has v4 "FAILED" && [[ "$(cat "$W/v4.rc")" == 2 ]] && ! banner v4 \
    && ok "V4 rc 3 execution error -> Truth: FAILED, rc 2" \
    || no "V4 execution error not reported as a failed collection" "rc=$(cat "$W/v4.rc")"

STUB_DOC="$W/doc_invalid.json" STUB_RC=1 run v5 health
has v5 "Truth:" && has v5 "FAILED" && ! banner v5 \
    && ok "V5 rc 1 with invalid JSON -> Truth: FAILED" \
    || no "V5 invalid document rendered as a verdict" "rc=$(cat "$W/v5.rc")"

# ---- status arms ----------------------------------------------------------------------
cp "$ROOT/etc/nftban/conf.d/botscan/main.conf" "$W/etc/conf.d/botscan/main.conf" 2>/dev/null \
    || printf 'BOTSCAN_ENABLED="true"\nBOTSCAN_ACTION_MODE="both"\n' > "$W/etc/conf.d/botscan/main.conf"
printf 'BOTSCAN_ENABLED="true"\n' > "$W/etc/conf.d/botscan/main.conf.local"
printf '{"health_state":"OK_' > "$W/data/botscan/runstate.json"
STUB_DOC="$W/doc.json" STUB_RC=0 run s1 status
if ! banner s1 && has s1 "run-state UNREADABLE"; then
    ok "S1 truncated runstate.json -> status completes, run-state UNREADABLE shown"
else
    no "S1 damaged runstate.json" "rc=$(cat "$W/s1.rc") banner=$(banner s1 && echo yes || echo no) $(grep -hm1 -E 'Command:|Line:' "$W/s1.err" || true)"
fi
rm -f "$W/data/botscan/runstate.json"
printf '{"floor_breach_count": ' > "$W/state/firewall_transition_health.json"
STUB_DOC="$W/doc.json" STUB_RC=0 run s2 status
if ! banner s2 && grep -qsE 'FW Transition.*UNKNOWN' "$W/s2.out" && ! grep -qsE 'FW Transition.*OK' "$W/s2.out"; then
    ok "S2 truncated firewall_transition_health.json -> FW Transition UNKNOWN, not OK"
else
    no "S2 damaged transition state" "rc=$(cat "$W/s2.rc") $(grep -hm1 'FW Transition' "$W/s2.out" || true) $(grep -hm1 -E 'Command:' "$W/s2.err" || true)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -eq 0 ]]; then echo "RESULT: PASS"; exit 0; fi
echo "RESULT: FAIL"; exit 1
