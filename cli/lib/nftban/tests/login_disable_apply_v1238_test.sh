#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.238 `nftban login enable/disable` applies and verifies the daemon state
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="login_disable_apply_v1238_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-23"
# meta:description="v1.238 BUG-LOGIN-DISABLE-REPORTS-SUCCESS-WITHOUT-LOCAL-FILE + BUG-LOGIN-RELOAD-HINT-DOES-NOT-APPLY-MODULE-CHANGES (owner GO 2026-11-23). nftband reads LOGIN_ENABLED only at start and SIGHUP does not reconfigure modules, so enable/disable must write conf.d/login/main.conf.local (creating it 0640), check the value nftband will resolve (main.conf -> main.conf.local -> nftban.conf.local), restart nftband, and report success only when the daemon's modules IPC confirms loginmon enabled/running. Cases: disable without the override file (the reproduced defect) writes it and verifies; enable verifies; a contradicting central nftban.conf.local fails and names it; daemon stopped: disable succeeds (nothing detects), enable fails; a daemon that does not confirm fails; no reload hint remains; login status text and --json report the LoginMon state from the daemon modules answer (active/disabled/unknown/not_running), not from the unit state. Stubs: systemctl (restart derives the fake daemon state from the config files like nftband does), socat (modules IPC); real jq. No firewall change."
# meta:input="None (repo source read-only; temp dirs)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,grep,awk,jq,python3"
# meta:inventory.files="cli/lib/nftban/cli/cmd_login.sh"
# meta:inventory.binaries="bash,grep,awk,jq,python3"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_RUN_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="login_disable_apply_v1238_test"
# meta:ta.owner="core"
# meta:ta.module="login"
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
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
CMD="$REPO_ROOT/cli/lib/nftban/cli/cmd_login.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "SKIP: jq/python3 missing"; exit 0; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/etc/conf.d/login" "$W/run"
# fake systemctl: is-active from $W/active; restart records the call and derives the fake
# daemon's loginmon state from the config files in nftband's order (start-time read).
cat > "$W/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  is-active) [[ "$(cat "$W/active" 2>/dev/null)" == yes ]] ;;
  restart)
    echo restart >> "$W/calls"
    v=""; for f in "$W/etc/conf.d/login/main.conf" "$W/etc/conf.d/login/main.conf.local" "$W/etc/nftban.conf.local"; do
      [[ -f "$f" ]] || continue; l=$(grep -E '^LOGIN_ENABLED=' "$f" | tail -n1 || true); [[ -n "$l" ]] && v="${l#*=}"; done
    v="${v//\"/}"; [[ -f "$W/daemon_lies" ]] && v=true
    echo "$v" > "$W/daemon_state" ;;
  *) exit 0 ;;
esac
EOF
cat > "$W/bin/socat" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
s=$(cat "$W/daemon_state" 2>/dev/null || echo true)
printf '{"success":true,"data":[{"name":"loginmon","enabled":%s,"running":%s},{"name":"ddos","enabled":true,"running":true}]}\n' "$s" "$s"
EOF
chmod 755 "$W/bin/systemctl" "$W/bin/socat"
python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$W/run/nftband.sock"
export W NFTBAN_CONFIG_DIR="$W/etc" NFTBAN_RUN_DIR="$W/run"

fns=$(awk '/^(_nftban_login_set_config|_nftban_login_effective_enabled|_nftban_login_apply_daemon_state|_loginmon_ipc_call)\(\) \{/ {f=1} f {print} f && /^\}/ {f=0}' "$CMD")
run(){ PATH="$W/bin:$PATH" bash -c 'eval "$1"; shift; _nftban_login_apply_daemon_state "$@"' _ "$fns" "$@" 2>&1; }
reset(){ rm -f "$W/etc/conf.d/login/main.conf.local" "$W/etc/nftban.conf.local" "$W/calls" "$W/daemon_lies"
         printf 'LOGIN_ENABLED="true"\n' > "$W/etc/conf.d/login/main.conf"; echo true > "$W/daemon_state"; echo yes > "$W/active"; }

echo "=== disable without main.conf.local (the reproduced defect) ==="
reset; rc=0; out=$(run false) || rc=$?
[[ -f "$W/etc/conf.d/login/main.conf.local" ]] && grep -qx 'LOGIN_ENABLED="false"' "$W/etc/conf.d/login/main.conf.local" \
  && ok "override created and LOGIN_ENABLED=\"false\" written" || no "override not written"
[[ "$(stat -c %a "$W/etc/conf.d/login/main.conf.local")" == 640 ]] && ok "override created 0640" || no "override mode $(stat -c %a "$W/etc/conf.d/login/main.conf.local")"
[[ $rc -eq 0 && "$(cat "$W/calls" 2>/dev/null)" == restart && "$out" == *"verified: nftband reports loginmon enabled=false running=false"* ]] \
  && ok "nftband restarted and the daemon confirmed loginmon disabled before success" || no "disable not applied/verified" "rc=$rc out=$out"

echo "=== enable ==="
rc=0; out=$(run true) || rc=$?
[[ $rc -eq 0 && "$out" == *"verified: nftband reports loginmon enabled=true running=true"* ]] && ok "enable restored and verified" || no "enable" "rc=$rc out=$out"

echo "=== central override contradicts ==="
reset; printf 'LOGIN_ENABLED="true"\n' > "$W/etc/nftban.conf.local"; rc=0; out=$(run false) || rc=$?
[[ $rc -ne 0 && "$out" == *"nftban.conf.local overrides"* && ! -f "$W/calls" ]] && ok "refused, names nftban.conf.local, no restart" || no "central override" "rc=$rc out=$out"

echo "=== daemon not running ==="
reset; echo no > "$W/active"; rc=0; out=$(run false) || rc=$?
[[ $rc -eq 0 && "$out" == *"nftband is not running, so nothing is detecting"* && ! -f "$W/calls" ]] && ok "disable with nftband stopped: saved, true, no start" || no "disable stopped" "rc=$rc out=$out"
rc=0; out=$(run true) || rc=$?
[[ $rc -ne 0 && "$out" == *"NOT active"* ]] && ok "enable with nftband stopped: fails, not claimed" || no "enable stopped" "rc=$rc out=$out"

echo "=== daemon does not confirm ==="
reset; touch "$W/daemon_lies"; rc=0; out=$( (export PATH="$W/bin:$PATH"; sleep() { :; }; export -f sleep; bash -c 'eval "$1"; shift; sleep(){ :; }; _nftban_login_apply_daemon_state "$@"' _ "$fns" false) 2>&1) || rc=$?
[[ $rc -ne 0 && "$out" == *"did not confirm"* && "$out" != *"✅"* ]] && ok "no confirmation -> failure, no success line" || no "unconfirmed" "rc=$rc out=$out"

echo "=== no reload hint remains ==="
if grep -nE 'systemctl reload nftband' "$CMD" >/dev/null; then no "a 'systemctl reload nftband' hint remains in cmd_login.sh"; else ok "no reload hint (reload does not reconfigure modules)"; fi

echo "=== login status follows nftband's modules answer (batch 1: was the unit state only) ==="
sfn=$(awk '/^(_nftban_loginmon_module_state|_loginmon_ipc_call)\(\) \{/ {f=1} f {print} f && /^\}/ {f=0}' "$CMD")
mstate(){ PATH="$W/bin:$PATH" bash -c 'eval "$1"; _nftban_loginmon_module_state' _ "$sfn" 2>&1; }
reset; echo false > "$W/daemon_state"; [[ "$(mstate)" == disabled ]] && ok "daemon reports loginmon disabled -> 'disabled'" || no "disabled state" "$(mstate)"
echo true > "$W/daemon_state";  [[ "$(mstate)" == active ]] && ok "daemon reports loginmon running -> 'active'" || no "active state" "$(mstate)"
mv "$W/run/nftband.sock" "$W/run/sock.off"; [[ "$(mstate)" == unknown ]] && ok "no modules answer -> 'unknown' (not 'active')" || no "unknown state" "$(mstate)"; mv "$W/run/sock.off" "$W/run/nftband.sock"
echo no > "$W/active"; [[ "$(mstate)" == not_running ]] && ok "nftband stopped -> 'not_running'" || no "not_running state" "$(mstate)"
if grep -q 'case "$(_nftban_loginmon_module_state)" in' "$CMD" && grep -q 'loginmon_module: $loginmon_module' "$CMD"; then
    ok "status text and --json both use the daemon-derived state"; else no "status text/--json not wired to the daemon state"; fi

echo ""
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
