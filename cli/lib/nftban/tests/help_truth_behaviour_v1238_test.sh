#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.238 help truth: behaviour changes (doctor fix path, health --cache-status)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="help_truth_behaviour_v1238_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-25"
# meta:description="v1.238 (owner GO 2026-11-25, BUG-CLI-HINT-NAMES-NONEXISTENT-NFTBAN-REBUILD): the config doctor auto-fix ran `nftban rebuild`, which is not a CLI command, so it always FAILED and never touched the firewall; it now runs `nftban firewall rebuild`, a BEHAVIOUR change. This test proves the new call is reachable ONLY from the explicit fix path. S1-S4 (static, the REAL nftban_config_doctor.sh): no `nftban rebuild` remains; every `nftban firewall rebuild` invocation and every `sed -i` write sits inside _doctor_auto_fix; _doctor_auto_fix is called once, under `fix_mode -eq 1`; fix_mode=1 is set only by the `--fix)` arm. B1-B6 (behaviour, the REAL nftban_cmd_config_doctor with the analysis phases stubbed to report a kernel/config drift finding and a recording `nftban` stub first on PATH): the plain doctor, --json, --brief, --module, --security and `--fix --help` call nothing; `--fix` as non-root calls nothing; `--fix` as uid 0 (real root or a user namespace) calls exactly `nftban firewall rebuild`. H1-H4 (health, owner decision: the periodic check stays diagnostic): nftban-health.service runs `nftban health check --cache-status` without --auto-heal; through the REAL dispatcher with a stub validator, `health check --auto-heal --cache-status` writes the banner cache from the verdict (rc 0 -> PROTECTED, rc 1 -> WARNING; before v1.238 this path wrote no cache) and calls no repair; without --cache-status no cache is written. Sandbox only: temp dirs, no nft, no firewall change."
# meta:input="None (repo source read-only; temp dir)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,awk,grep,jq,mktemp,unshare"
# meta:inventory.files="cli/lib/nftban/core/nftban_config_doctor.sh,cli/lib/nftban/cli/cmd_health.sh,cli/lib/nftban/cli/cmd_health_core.sh,install/systemd/nftban-health.service,cli/sbin/nftban"
# meta:inventory.binaries="bash,awk,grep,jq,mktemp,unshare"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR,NFTBAN_CACHE_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="help_truth_behaviour_v1238_test"
# meta:ta.owner="cli"
# meta:ta.module="cli-help-truth"
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

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../../../.." && pwd)
LIB="$REPO/cli/lib/nftban"
CD="$LIB/core/nftban_config_doctor.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  [PASS] $1"; }
no() { FAIL=$((FAIL+1)); echo "  [FAIL] $1${2:+ ($2)}"; }

[[ -f "$CD" ]] || { echo "FAIL: missing $CD" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required (the doctor uses it)" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "=== S: static, the real nftban_config_doctor.sh ==="
src=$(grep -vE '^[[:space:]]*#' "$CD")
if grep -qE 'nftban rebuild\b' <<< "$src"; then
    no "S1 no 'nftban rebuild' (not a CLI command) remains in executable lines"
else
    ok "S1 no 'nftban rebuild' remains in executable lines"
fi
# Line ranges of _doctor_auto_fix.
read -r af_start af_end < <(awk '/^_doctor_auto_fix\(\) \{/{s=NR} s&&!e&&/^}/{e=NR} END{print s+0, e+0}' "$CD")
outside=$(awk -v s="$af_start" -v e="$af_end" '
    /^[[:space:]]*#/ {next}
    (NR<s || NR>e) && (/nftban firewall rebuild/ && !/echo|_doctor_finding|"[^"]*nftban firewall rebuild/) {print NR": "$0}
    (NR<s || NR>e) && /sed -i/ {print NR": "$0}' "$CD")
if (( af_start > 0 && af_end > af_start )) && [[ -z "$outside" ]]; then
    ok "S2 every 'nftban firewall rebuild' invocation and every 'sed -i' write is inside _doctor_auto_fix (lines $af_start-$af_end)"
else
    no "S2 writers confined to _doctor_auto_fix" "range=$af_start-$af_end outside=[$outside]"
fi
calls=$(grep -nE '^[[:space:]]*_doctor_auto_fix[[:space:]]*$' "$CD" || true)
ncalls=$(grep -c . <<< "$calls" || true)
guard_ok=0
if (( ncalls == 1 )); then
    cl=${calls%%:*}
    prev=$(awk -v c="$cl" 'NR==c-1' "$CD")
    grep -qE 'if \[\[ \$fix_mode -eq 1 \]\]; then' <<< "$prev" && guard_ok=1
fi
(( guard_ok )) && ok "S3 _doctor_auto_fix is called once, directly under 'if [[ \$fix_mode -eq 1 ]]'" \
    || no "S3 single guarded call" "calls=[$calls]"
setters=$(grep -nE 'fix_mode=1' "$CD" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
if [[ "$(grep -c . <<< "$setters")" == 1 && "$setters" == *"--fix) fix_mode=1"* ]]; then
    ok "S4 fix_mode=1 is set only by the '--fix)' option arm"
else
    no "S4 fix_mode setter" "[$setters]"
fi

echo "=== B: behaviour, the real nftban_cmd_config_doctor with stubbed analysis ==="
mkdir -p "$TMP/bin" "$TMP/etc"
cat > "$TMP/bin/nftban" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NFTBAN_TEST_CALL_LOG"
exit 0
STUB
chmod +x "$TMP/bin/nftban"

cat > "$TMP/driver.sh" <<'DRIVER'
#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=/dev/null
source "$NFTBAN_TEST_CD"
# Analysis phases stubbed: one kernel/config drift finding, nothing read from the host.
_doctor_gather_data()      { :; }
_doctor_core_integrity()   { :; }
_doctor_override_analysis(){ :; }
_doctor_global_drift()     { _DOCTOR_FINDINGS+=('{"severity":"WARN","type":"drift_module_unapplied","message":"ddos: drift","source":"test"}'); }
_doctor_all_modules()      { :; }
_doctor_security_gaps()    { :; }
_doctor_render_human()     { echo "rendered human"; }
_doctor_render_json()      { echo "{}"; }
_doctor_render_brief()     { echo "brief"; }
nftban_cmd_config_doctor "$@"
DRIVER

# run_case <label> <as_root:0|1|ns> <args...> -> sets CALLS, RC
run_case() {
    local as="$1"; shift
    : > "$TMP/calls.log"
    local -a envs=(env "PATH=$TMP/bin:$PATH" "NFTBAN_LIB_DIR=$LIB" "NFTBAN_CONFIG_DIR=$TMP/etc"
                   "NFTBAN_TEST_CD=$CD" "NFTBAN_TEST_CALL_LOG=$TMP/calls.log")
    RC=0
    case "$as" in
        ns)   unshare --user --map-root-user "${envs[@]}" bash "$TMP/driver.sh" "$@" >/dev/null 2>&1 || RC=$? ;;
        sudo) sudo -n "${envs[@]}" bash "$TMP/driver.sh" "$@" >/dev/null 2>&1 || RC=$? ;;
        *)  "${envs[@]}" bash "$TMP/driver.sh" "$@" >/dev/null 2>&1 || RC=$? ;;
    esac
    CALLS=$(tr '\n' ';' < "$TMP/calls.log")
}

# Plain / read-only modes: never call nftban, as any user (root included when we are root).
for args in "" "--json" "--brief" "--module ddos" "--security" "--fix --help"; do
    # shellcheck disable=SC2086
    run_case user $args
    [[ -z "$CALLS" ]] && ok "B1 'config doctor $args' calls nothing (rc=$RC)" \
        || no "B1 'config doctor $args' must not call nftban" "calls=$CALLS"
done

# Choose a uid-0 runner for the fix path: real root, else a user namespace.
ROOT_MODE=""
if (( EUID == 0 )); then ROOT_MODE=user
elif command -v unshare >/dev/null 2>&1 && unshare --user --map-root-user true >/dev/null 2>&1; then ROOT_MODE=ns
elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then ROOT_MODE=sudo
fi

if (( EUID != 0 )); then
    run_case user --fix
    [[ -z "$CALLS" ]] && ok "B2 'config doctor --fix' as non-root calls nothing (privilege gate)" \
        || no "B2 non-root --fix must not call nftban" "calls=$CALLS"
else
    ok "B2 skipped as a separate case: running as root (B3 covers the fix path)"
fi

if [[ -n "$ROOT_MODE" ]]; then
    run_case "$ROOT_MODE" --fix
    if [[ "$CALLS" == "firewall rebuild;" ]]; then
        ok "B3 'config doctor --fix' as uid 0 calls exactly 'nftban firewall rebuild' (runner: $ROOT_MODE)"
    else
        no "B3 'config doctor --fix' as uid 0 must call 'nftban firewall rebuild' once" "calls=[$CALLS] rc=$RC runner=$ROOT_MODE"
    fi
    run_case "$ROOT_MODE"
    [[ -z "$CALLS" ]] && ok "B4 plain 'config doctor' as uid 0 calls nothing (runner: $ROOT_MODE)" \
        || no "B4 plain doctor as uid 0 must not call nftban" "calls=$CALLS"
else
    no "B3/B4 fix path not exercised" "no uid-0 runner: not root, no 'unshare --user --map-root-user', no 'sudo -n'"
fi

echo "=== H: periodic health check stays diagnostic; --cache-status writes the banner cache ==="
UNIT="$REPO/install/systemd/nftban-health.service"
es=$(grep -E '^ExecStart=' "$UNIT" || true)
if [[ "$es" == *"nftban health check --cache-status"* && "$es" != *"--auto-heal"* ]]; then
    ok "H1 nftban-health.service ExecStart: 'health check --cache-status', no --auto-heal"
else
    no "H1 unit ExecStart" "$es"
fi
# A lib dir that is the real one except bin/: a stub validator with a chosen exit code,
# plus recording stubs for anything a repair would run.
HL="$TMP/hlib"; mkdir -p "$HL/bin" "$TMP/hetc" "$TMP/hcache"
for e in "$LIB"/*; do [[ "$(basename "$e")" == bin ]] || ln -s "$e" "$HL/$(basename "$e")"; done
cat > "$HL/bin/nftban-validate" <<'VAL'
#!/usr/bin/env bash
printf '{"schema_version":"1.84.0","status":"%s","modules":{}}\n' "${NFTBAN_TEST_VSTATUS:-protected}"
exit "${NFTBAN_TEST_VRC:-0}"
VAL
chmod +x "$HL/bin/nftban-validate"
mkdir -p "$TMP/hstub"
for b in systemctl nft chown chmod; do
    printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" "%s" "$*" >> "%s"\nexit 0\n' "$b" "$TMP/hcalls.log" > "$TMP/hstub/$b"
    chmod +x "$TMP/hstub/$b"
done
hrun() {
    local vrc="$1"; shift
    rm -f "$TMP/hcache/health/health_status.cache"; : > "$TMP/hcalls.log"
    HRC=0
    env PATH="$TMP/hstub:$PATH" NFTBAN_LIB_DIR="$HL" NFTBAN_CONFIG_DIR="$TMP/hetc" \
        NFTBAN_CACHE_DIR="$TMP/hcache" NFTBAN_NO_BANNER=1 NFTBAN_TEST_VRC="$vrc" \
        NFTBAN_TEST_VSTATUS="$([[ $vrc == 0 ]] && echo protected || echo degraded)" \
        bash "$REPO/cli/sbin/nftban" health "$@" >/dev/null 2>&1 || HRC=$?
    HCACHE=$(cat "$TMP/hcache/health/health_status.cache" 2>/dev/null || echo ABSENT)
    # The cache write's own chmod of its temp file is the only allowed call.
    HCALLS=$(grep -E '^(systemctl (restart|start|enable)|nft (add|delete|flush|-f)|chown|chmod)' "$TMP/hcalls.log" \
             | grep -vF "$TMP/hcache/health/" | tr '\n' ';' || true)
}
hrun 0 check --auto-heal --cache-status
[[ "$HCACHE" == PROTECTED && $HRC -eq 0 ]] && ok "H2 'health check --auto-heal --cache-status' (validator rc 0): cache=PROTECTED, rc=0" \
    || no "H2 cache from verdict rc 0" "cache=$HCACHE rc=$HRC"
[[ -z "$HCALLS" ]] && ok "H2b ... and no repair call (systemctl restart/start, nft write, chown/chmod)" || no "H2b check must not repair" "$HCALLS"
hrun 1 check --cache-status
[[ "$HCACHE" == WARNING && $HRC -eq 1 ]] && ok "H3 'health check --cache-status' (validator rc 1): cache=WARNING, rc=1" \
    || no "H3 cache from verdict rc 1" "cache=$HCACHE rc=$HRC"
hrun 0 check
[[ "$HCACHE" == ABSENT ]] && ok "H4 'health check' without --cache-status writes no cache" || no "H4 no cache without flag" "cache=$HCACHE"

echo ""
echo "help_truth_behaviour_v1238: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
