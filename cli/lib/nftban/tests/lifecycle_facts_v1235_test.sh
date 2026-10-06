#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.235 - status/health show the four lifecycle facts (row 486, D8)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="lifecycle_facts_v1235_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-06"
# meta:description="Row 486 behaviour contract D8 (CLI_AUDIT_V1235/ROW486_BEHAVIOUR_CONTRACT_V1235.md): status and health show STORED choice, APPLIED now, ON REBOOT and RECOVERY as separate facts, plus the per-boot emergency bypass and the disable unit record; a mismatch is a named EXPECTED or DIVERGENCE line; an unread fact is UNKNOWN, never OK/DISABLED/0. Drives the REAL lib/lifecycle_facts.sh with the three authorities it reads (nftban_master_switch_on, nftban_emergency_bypass_active, nftban_boot_projection_state; owned by the 486 lane) STUBBED here, and stub nft/systemctl. Arms: A1 consistent enabled host -> no DIVERGENCE; A2 plain disable (stored off, tables present, projection inert) -> EXPECTED 'removed at next reboot'; A3 stored on + projection inert -> DIVERGENCE; A4 stored off + projection active + tables present -> DIVERGENCE; A5 bypass active -> EXPECTED 'EMERGENCY BYPASS ACTIVE ... stored choice'; A6 authorities not loaded -> stored/projection UNKNOWN, never enabled/active; A7 nft unreadable -> tables UNKNOWN; A8 unit record present (recorded_at) / absent ('prior unit state unknown'); A9 JSON is valid and carries the same facts; A10 recovery never claims a 'window'; B1 bypass unit not enabled -> DIVERGENCE; B2 /run/nftban/boot-bypass.state outcome=backstop-removed -> DIVERGENCE 'rules WERE loaded ... removed (at <UTC>, T+Ns)', never a successful bypass; B4 failed / backstop-failed / backstop-unknown -> DIVERGENCE; B3 outcome primary -> ACTIVE, guarantee met; C1 commit-confirm pending -> apply ID, deadline with remaining seconds, the exact confirm command; C2 rollback-failed -> DIVERGENCE 'host NOT protected by NFTBan'; C3 no record named; C4 rolled-back with conflicts= -> untouched files named; C5 status=abandoned (operator abandoned a failed rollback) -> named last outcome, not UNKNOWN; D1 applied baseline (state/applied/meta at=) shown, absent -> 'rebuild --confirm unavailable'. E1/E2 the REAL dispatcher: status shows the 'Protection lifecycle' block and status --json carries a 'lifecycle' object; E3 through the real dispatcher the stored choice and projection are read from the real lib/service_control.sh and lib/boot_projection.sh (loaded on demand), not UNKNOWN. Set LF_SUBJECT_ROOT to an older tree (e.g. e79a1173): every arm FAILS there (the facts do not exist)."
# meta:inventory.files="lifecycle_facts_v1235_test.sh"
# meta:inventory.binaries="bash,jq,cp,mktemp"
# meta:inventory.env_vars="LF_SUBJECT_ROOT"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# meta:ta.id="lifecycle_facts_v1235_test"
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
ROOT="${LF_SUBJECT_ROOT:-$REPO}"
LIBF="$ROOT/cli/lib/nftban/lib/lifecycle_facts.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

echo "=== v1.235: lifecycle facts in status/health (row 486, D8) ==="
command -v jq >/dev/null || { echo "  NOT_EXECUTED: jq missing"; echo "RESULT: NOT_EXECUTED"; exit 3; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/state" "$W/run"

if [[ ! -r "$LIBF" ]]; then
    no "lib/lifecycle_facts.sh absent in the subject: status/health show none of the four facts"
    echo ""; echo "Results: $PASS passed, $FAIL failed"; echo "RESULT: FAIL"; exit 1
fi

# stub nft / systemctl driven by env (TABLES=both|none|unreadable, DAEMON, NFTSVC)
cat > "$W/bin/nft" <<'S'
#!/bin/sh
case "${TABLES:-both}" in
  both) printf 'table inet filter\ntable ip nftban\ntable ip6 nftban\n' ;;
  none) printf 'table inet filter\n' ;;
  unreadable) exit 1 ;;
esac
S
cat > "$W/bin/systemctl" <<'S'
#!/bin/sh
case "$1" in
  is-active) echo "${DAEMON:-active}"; [ "${DAEMON:-active}" = active ] ;;
  is-enabled) if [ "$2" = nftban-boot-bypass.service ]; then echo "${BYPASSUNIT:-enabled}"; [ "${BYPASSUNIT:-enabled}" = enabled ]
              else echo "${NFTSVC:-enabled}"; [ "${NFTSVC:-enabled}" = enabled ]; fi ;;
  list-units) printf 'nftban-watchdog.timer loaded active waiting x\nnftban-maintenance.timer loaded active waiting x\n' ;;
  *) exit 0 ;;
esac
S
chmod 0755 "$W/bin/nft" "$W/bin/systemctl"
printf '# distro\ninclude "/etc/nftban/generated/nftban-boot.nft"\n' > "$W/distro.conf"

# run_lf <out> [authorities: yes|no] ; env STORED=0|1 BYPASS=0|1 PROJ=active|inert|missing
run_lf(){
    local o="$1" auth="${2:-yes}"
    # NFTBAN_LIB_DIR -> an empty dir: the on-demand authority load must find nothing,
    # never the libraries installed on the host running the test.
    env PATH="$W/bin:/usr/bin:/bin" NFTBAN_LIB_DIR="$W/nolib" NFTBAN_STATE_DIR="$W/state" NFTBAN_RUN_DIR="$W/run" NFTBAN_LF_DISTRO_CONFS="$W/distro.conf" \
        AUTH="$auth" LIBF="$LIBF" bash -c '
        set -Eeuo pipefail
        if [[ "$AUTH" == yes ]]; then
            nftban_master_switch_on(){ return "${STORED:-0}"; }
            nftban_emergency_bypass_active(){ return "${BYPASS:-1}"; }
            nftban_boot_projection_state(){ printf "%s" "${PROJ:-active}"; }
        fi
        # shellcheck source=/dev/null
        . "$LIBF"
        nftban_lifecycle_collect
        nftban_lifecycle_render
        echo "@@JSON"
        nftban_lifecycle_json
    ' > "$W/$o.out" 2>"$W/$o.err" || true
}
txt(){ sed '/^@@JSON$/,$d' "$W/$1.out"; }
js(){ sed -n '/^@@JSON$/,$p' "$W/$1.out" | tail -n +2; }

STORED=0 PROJ=active run_lf a1
t="$(txt a1)"
if [[ "$t" == *"Stored choice......."*enabled* && "$t" == *"Applied now........."*"tables present"* && "$t" == *"On reboot..........."*"projection active"* && "$t" == *"Recovery............"* && "$t" != *DIVERGENCE* ]]; then
    ok "A1 consistent enabled host: four facts shown, no DIVERGENCE"
else no "A1 consistent host" "$(tr '\n' '|' <<<"$t" | cut -c1-300)"; fi

STORED=1 PROJ=inert run_lf a2
[[ "$(txt a2)" == *"EXPECTED: stored disabled, NFTBan rules still active (expected after plain disable; removed at next reboot)"* ]] \
    && ok "A2 plain disable -> EXPECTED, removed at next reboot" || no "A2 plain disable not named" "$(txt a2 | tail -3 | tr '\n' '|')"

STORED=0 PROJ=inert run_lf a3
[[ "$(txt a3)" == *"DIVERGENCE: stored enabled, projection inert"* ]] && ok "A3 stored on + projection inert -> DIVERGENCE" || no "A3 not flagged"

STORED=1 PROJ=active run_lf a4
[[ "$(txt a4)" == *"DIVERGENCE: stored disabled, NFTBan rules active and projection active"* ]] && ok "A4 stored off + projection active -> DIVERGENCE" || no "A4 not flagged" "$(txt a4 | tail -2 | tr '\n' '|')"

STORED=1 BYPASS=0 PROJ=inert run_lf a5
[[ "$(txt a5)" == *"EXPECTED: EMERGENCY BYPASS ACTIVE for this boot (kernel nftban=disabled); stored choice: disabled"* && "$(txt a5)" == *"bind-mounted"* ]] \
    && ok "A5 bypass active -> EXPECTED with stored choice and why the projection reads inert" || no "A5 bypass not shown"

run_lf a6 no
t="$(txt a6)"
sline="$(grep -m1 'Stored choice' <<<"$t" || true)"
if [[ "$sline" == *UNKNOWN* && "$sline" != *enabled* && "$t" == *"projection UNKNOWN"* && "$t" == *"UNKNOWN: stored choice not read"* ]]; then
    ok "A6 authorities not loaded -> UNKNOWN (never guessed)"
else no "A6 unread authorities rendered as a value" "$(tr '\n' '|' <<<"$t" | cut -c1-240)"; fi

TABLES=unreadable STORED=0 run_lf a7
[[ "$(txt a7)" == *"tables UNKNOWN"* && "$(txt a7)" == *"UNKNOWN: kernel tables not read"* ]] && ok "A7 nft unreadable -> tables UNKNOWN, named" || no "A7 unreadable kernel rendered as a value"

printf '# recorded_at=2026-10-06T10:00:00Z\nnftables.service\tenabled\n' > "$W/state/disable-units.state"
STORED=1 PROJ=inert run_lf a8a
rm -f "$W/state/disable-units.state"
STORED=1 PROJ=inert run_lf a8b
[[ "$(txt a8a)" == *"unit record present (recorded_at 2026-10-06T10:00:00Z)"* && "$(txt a8b)" == *"no record (prior unit state unknown)"* ]] \
    && ok "A8 disable unit record: present with recorded_at / absent named" || no "A8 unit record"

if js a2 | jq -e '.stored=="disabled" and .applied.tables=="present" and .on_reboot.projection=="inert" and (.notes|length)>=1' >/dev/null 2>&1; then
    ok "A9 JSON valid and carries the same facts"
else _j="$(js a2)"; no "A9 JSON" "${_j:0:200}"; fi

! grep -qiE 'window' <<<"$(txt a1)$(txt a2)$(txt a3)" && ok "A10 recovery never claims a 'window'" || no "A10 a recovery window is claimed"

# ---- B: emergency bypass states (contract §3/§6) ------------------------------------
BYPASSUNIT=disabled STORED=0 PROJ=active run_lf b1
[[ "$(txt b1)" == *"DIVERGENCE: the bypass unit is disabled: the emergency bypass would not act before the first load"* ]] \
    && ok "B1 bypass unit not enabled -> DIVERGENCE" || no "B1 bypass unit state not flagged" "$(grep -m1 'Emergency' <<<"$(txt b1)" || true)"
printf 'outcome=backstop-removed\nat=2026-10-06T11:00:05Z\nmonotonic_us=7400000\n' > "$W/run/boot-bypass.state"
BYPASS=0 STORED=0 PROJ=inert run_lf b2
t="$(txt b2)"
if [[ "$t" == *"DIVERGENCE: emergency bypass DEGRADED: not a successful bypass: NFTBan rules WERE loaded during this bypass boot and removed (at 2026-10-06T11:00:05Z, T+7s)"* && "$t" != *"EXPECTED: EMERGENCY BYPASS ACTIVE"* ]]; then
    ok "B2 backstop-removed -> DIVERGENCE 'rules WERE loaded … removed (at …, T+7s)', never shown as a successful bypass"
else no "B2 backstop outcome misreported" "$(grep -E 'Emergency|bypass' <<<"$t" | tr '\n' '|')"; fi
printf 'outcome=primary\nat=2026-10-06T11:00:00Z\n' > "$W/run/boot-bypass.state"
BYPASS=0 STORED=1 PROJ=inert run_lf b3
rm -f "$W/run/boot-bypass.state"
[[ "$(txt b3)" == *"ACTIVE (guarantee met: outcome=primary at 2026-10-06T11:00:00Z)"* && "$(txt b3)" == *"EXPECTED: EMERGENCY BYPASS ACTIVE"* ]] \
    && ok "B3 outcome primary -> ACTIVE, guarantee met" || no "B3 guarantee-met outcome" "$(grep -m1 Emergency <<<"$(txt b3)" || true)"

for oc in "backstop-failed|delete FAILED: NFTBan rules may still be active" "backstop-unknown|the backstop outcome is UNKNOWN" "failed|the primary bypass FAILED: unit timeout"; do
    printf 'outcome=%s\nat=2026-10-06T11:00:05Z\ndetail=unit timeout\n' "${oc%%|*}" > "$W/run/boot-bypass.state"
    BYPASS=0 STORED=0 PROJ=inert run_lf b4
    if [[ "$(txt b4)" == *"DIVERGENCE: emergency bypass DEGRADED"*"${oc#*|}"* && "$(txt b4)" != *"EXPECTED: EMERGENCY BYPASS ACTIVE"* ]]; then
        ok "B4 outcome ${oc%%|*} -> DIVERGENCE, never a successful bypass"
    else no "B4 outcome ${oc%%|*} misreported" "$(grep -m1 Emergency <<<"$(txt b4)" || true)"; fi
done
rm -f "$W/run/boot-bypass.state"

# ---- C: commit-confirm (contract §4/§6) --------------------------------------------
dl=$(( $(date +%s) + 90 ))
printf 'apply_id=a1b2c3\ndeadline_epoch=%s\nstatus=pending\nat=2026-10-06T11:05:00Z\n' "$dl" > "$W/state/commit-confirm.state"
STORED=0 PROJ=active run_lf c1
l="$(grep -m1 'Commit-confirm' <<<"$(txt c1)" || true)"
[[ "$l" == *"PENDING apply a1b2c3"* && "$l" == *"remaining"* && "$l" == *"nftban firewall confirm a1b2c3"* ]] \
    && ok "C1 pending apply: ID, deadline with remaining seconds, exact confirm command" || no "C1 pending apply" "$l"
printf 'apply_id=a1b2c3\ndeadline_epoch=1\nstatus=rollback-failed\nat=2026-10-06T11:07:00Z\n' > "$W/state/commit-confirm.state"
STORED=0 PROJ=active run_lf c2
[[ "$(txt c2)" == *"DIVERGENCE: ROLLBACK FAILED: NFTBan rules removed, host NOT protected by NFTBan"* ]] \
    && ok "C2 rollback-failed -> DIVERGENCE (host NOT protected by NFTBan)" || no "C2 rollback failure not flagged"
printf 'apply_id=a1b2c3\ndeadline_epoch=1\nstatus=rolled-back\nat=2026-10-06T11:07:00Z\nconflicts=/etc/nftban/conf.d/ddos/main.conf.local\n' > "$W/state/commit-confirm.state"
STORED=0 PROJ=active run_lf c4
[[ "$(txt c4)" == *"last outcome: rolled-back at 2026-10-06T11:07:00Z (apply a1b2c3)"* && "$(txt c4)" == *"untouched: /etc/nftban/conf.d/ddos/main.conf.local"* ]] \
    && ok "C4 rolled-back with conflicts -> last outcome + untouched files named" || no "C4 conflicts not shown"
printf 'apply_id=a1b2c3\ndeadline_epoch=1\nstatus=abandoned\nat=2026-10-06T11:09:00Z\n' > "$W/state/commit-confirm.state"
STORED=0 PROJ=active run_lf c5
l="$(grep -m1 'Commit-confirm' <<<"$(txt c5)" || true)"
[[ "$l" == *"last outcome: abandoned (a failed rollback, abandoned by the operator) at 2026-10-06T11:09:00Z (apply a1b2c3)"* && "$l" != *UNKNOWN* ]] \
    && ok "C5 abandoned (commit_confirm.sh writer) -> named last outcome, not UNKNOWN" || no "C5 abandoned not named" "$l"
rm -f "$W/state/commit-confirm.state"
STORED=0 PROJ=active run_lf c3
[[ "$(grep -m1 'Commit-confirm' <<<"$(txt c3)" || true)" == *"no apply awaiting confirmation (no record)"* ]] \
    && ok "C3 no record -> named as such" || no "C3 absent record"

# ---- D1 applied baseline -------------------------------------------------------------
mkdir -p "$W/state/applied"; printf 'at=2026-10-06T10:30:00Z\n' > "$W/state/applied/meta"
STORED=0 PROJ=active run_lf d1a
rm -rf "$W/state/applied"
STORED=0 PROJ=active run_lf d1b
[[ "$(txt d1a)" == *"applied baseline at 2026-10-06T10:30:00Z"* && "$(txt d1b)" == *"no applied baseline (rebuild --confirm unavailable)"* ]] \
    && ok "D1 applied baseline shown / absent named" || no "D1 applied baseline"

# ---- E1/E2 the real dispatcher ------------------------------------------------------
if [[ -x "$ROOT/cli/sbin/nftban" ]]; then
    cp -r "$ROOT/cli/lib/nftban" "$W/lib"; mkdir -p "$W/lib/bin" "$W/etc" "$W/data" "$W/log" "$W/run" "$W/cache"
    printf '#!/bin/sh\necho "{\\"schema_version\\":\\"1.84.0\\",\\"status\\":\\"protected\\",\\"modules\\":{},\\"service_state\\":{},\\"consistency\\":{}}"\n' > "$W/lib/bin/nftban-validate"
    chmod 0755 "$W/lib/bin/nftban-validate"
    for c in status "status --json"; do
        slug="${c// /_}"; slug="${slug//-/}"
        local_args=(); IFS=' ' read -r -a local_args <<<"$c"
        PATH="$W/bin:$PATH" NFTBAN_LIB_DIR="$W/lib" NFTBAN_CONFIG_DIR="$W/etc" NFTBAN_DATA_DIR="$W/data" NFTBAN_STATE_DIR="$W/state" \
            NFTBAN_LOG_DIR="$W/log" NFTBAN_RUN_DIR="$W/run" NFTBAN_CACHE_DIR="$W/cache" NFTBAN_ENABLE_ERROR_LOGGING=0 \
            NFTBAN_LF_DISTRO_CONFS="$W/distro.conf" timeout 120 "$ROOT/cli/sbin/nftban" "${local_args[@]}" > "$W/e_$slug.out" 2>/dev/null </dev/null || true
    done
    grep -q 'Protection lifecycle' "$W/e_status.out" && grep -q 'Stored choice' "$W/e_status.out" \
        && ok "E1 status (real dispatcher) shows the Protection lifecycle block" || no "E1 status shows no lifecycle facts"
    jq -e '.lifecycle | has("stored") and has("on_reboot") and has("recovery")' "$W/e_status_json.out" >/dev/null 2>&1 \
        && ok "E2 status --json carries the lifecycle object" || no "E2 status --json has no lifecycle object"
    # E3: the dispatcher does not load lib/service_control.sh or lib/boot_projection.sh;
    # the facts must load them (lab3 runtime pass: all three read UNKNOWN without it).
    if [[ -f "$W/lib/lib/service_control.sh" && -f "$W/lib/lib/boot_projection.sh" ]]; then
        e3="$(grep -E 'Stored choice|On reboot|UNKNOWN: (stored choice|boot projection state) not read' "$W/e_status.out" || true)"
        if [[ "$e3" == *"Stored choice"* && "$e3" != *"Stored choice....... UNKNOWN"* \
              && "$e3" != *"projection UNKNOWN"* && "$e3" != *"not read"* ]]; then
            ok "E3 real dispatcher: stored choice and projection read from the real authorities (not UNKNOWN)"
        else no "E3 authorities not loaded by the real dispatcher path" "$(tr '\n' '|' <<<"$e3")"; fi
    fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -eq 0 ]]; then echo "RESULT: PASS"; exit 0; fi
echo "RESULT: FAIL"; exit 1
