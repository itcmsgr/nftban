#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.235.1 - loading PortScan must not move the install-state dir
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="portscan_trusted_flow_state_dir_authority_v1235_1_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-14"
# meta:description="v1.235.0 upgrade FAILED_REBUILD with PortScan enabled (monitor, reproduced on lab4): the portscan module loader sources nftban_portscan_trusted_flow.sh, which initialized an UNSET NFTBAN_STATE_DIR to the data-dir root (/var/lib/nftban) with a := default. nftban_firewall_authority later reads the same variable as the STATE dir, so every later IPC write in that process was refused 'no-install-state /var/lib/nftban/install_state' and the portscan chains were never created (an initialization-order conflict, not an overwrite). (a) unset -> source trusted-flow -> the REAL decision reads <data>/state/install_state, GRANTED on a COMMITTED host, and nft_ipc_request passes the gate. (b) a pre-set NFTBAN_STATE_DIR is kept and still GRANTED. (c) FAILED_REBUILD and FAILED_AUTHORITY_ABORT hosts are still refused. T4: the trusted-flow state file path is unchanged (default, NFTBAN_STATE_DIR override, NFTBAN_PTF_STATE_FILE override)."
# meta:input="None (self-contained sandbox)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,mktemp,stat"
# meta:inventory.files="cli/lib/nftban/core/nftban_portscan_trusted_flow.sh,cli/lib/nftban/lib/service_control.sh,cli/lib/nftban/lib/nft_ipc.sh"
# meta:inventory.binaries="bash,mktemp,stat"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_DATA_DIR,NFTBAN_STATE_DIR,NFTBAN_PROC_LOCKS,NFTBAN_LIB_DIR,NFTBAN_PTF_STATE_FILE"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="portscan_trusted_flow_state_dir_authority_v1235_1_test"
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
#
#   ⛔ Production runs with NFTBAN_STATE_DIR UNSET (the authority falls back to
#      ${NFTBAN_DATA_DIR}/state). Tests that export NFTBAN_STATE_DIR mask this defect,
#      so every case here leaves it unset unless the case is about the override.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBDIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PTF="$LIBDIR/core/nftban_portscan_trusted_flow.sh"
SVC="$LIBDIR/lib/service_control.sh"
IPC="$LIBDIR/lib/nft_ipc.sh"
FAIL=0
pass(){ echo "  PASS  $1"; }
fail(){ echo "  FAIL  $1"; FAIL=1; }

echo "=== portscan trusted-flow keeps the install-state dir (v1.235.1) ==="
for f in "$PTF" "$SVC" "$IPC"; do
    [[ -f "$f" ]] || { echo "  SUBJECT_NOT_FOUND: $f"; exit 1; }
done

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/bin"
printf '#!/usr/bin/env bash\ncat >/dev/null; echo "{\\"success\\":true}"\n' > "$SB/bin/socat"
chmod +x "$SB/bin/socat"

# host <dir> <INSTALL_STATE> <AUTHORITY>: NFTBan on, no installer lock, state under data/state.
host() {
    local d="$1"
    mkdir -p "$d/etc/conf.d" "$d/data/state"
    echo 'NFTBAN_ENABLED=true' > "$d/etc/conf.d/services.conf"
    printf 'INSTALL_STATE=%s\nAUTHORITY=%s\n' "$2" "$3" > "$d/data/state/install_state"
    echo "1: POSIX  ADVISORY  WRITE 999 fd:00:12 0 EOF" > "$d/locks"
}

# in_host <dir> <script>: a fresh shell shaped like the portscan process (NFTBAN_STATE_DIR
# unset), with the REAL authority + IPC libraries loaded and the boot bypass held off.
in_host() {
    local d="$1"
    env -u NFTBAN_STATE_DIR -u NFTBAN_PTF_STATE_FILE PATH="$SB/bin:$PATH" \
        NFTBAN_CONFIG_DIR="$d/etc" NFTBAN_DATA_DIR="$d/data" NFTBAN_PROC_LOCKS="$d/locks" \
        NFTBAN_LIB_DIR="$LIBDIR" NFTBAN_DAEMON_SOCKET="$d/absent.sock" \
        NFTBAN_PORTSCAN_TRUSTED_FLOWS_FILE="$d/absent.conf" \
        bash -c '
            source "$1" >/dev/null 2>&1 || true
            nftban_emergency_bypass_active() { return 1; }
            source "$2" >/dev/null 2>&1 || true
            set +eu
            eval "$4"' _ "$SVC" "$IPC" "$PTF" "$2" 2>/dev/null
}

# The defect is an INITIALIZATION ORDER, not an overwrite: `: "${NFTBAN_STATE_DIR:=...}"`
# only fills an unset/empty variable. In a process where it is unset (production), loading
# trusted-flow initialized it to the data-dir ROOT, and the authority check later read that
# same variable as the STATE dir. (a) is that order; (b) is the pre-set order; (c) the guard.

# --- (a) unset -> source trusted-flow -> authority reads <data>/state/install_state -----
host "$SB/a" COMMITTED UPDATE
out="$(in_host "$SB/a" 'source "$3" >/dev/null 2>&1; set +eu; echo "${NFTBAN_STATE_DIR-<unset>}"')"
[[ "$out" == "<unset>" ]] && pass "a1 unset NFTBAN_STATE_DIR is not initialized by trusted-flow" \
                          || fail "a1 trusted-flow initialized NFTBAN_STATE_DIR='$out'"
# The path the REAL decision reads, made visible by a data dir with no install_state.
mkdir -p "$SB/e/etc/conf.d" "$SB/e/data"; echo 'NFTBAN_ENABLED=true' > "$SB/e/etc/conf.d/services.conf"
: > "$SB/e/locks"
out="$(in_host "$SB/e" 'source "$3" >/dev/null 2>&1; set +eu; nftban_firewall_authority')"
[[ "$out" == "DENIED no-install-state $SB/e/data/state/install_state" ]] \
    && pass "a2 after trusted-flow the decision reads <NFTBAN_DATA_DIR>/state/install_state" \
    || fail "a2 after trusted-flow the decision read the wrong file: '$out'"
# Production defaults (no NFTBAN_DATA_DIR either): the expression service_control.sh uses.
out="$(env -u NFTBAN_STATE_DIR -u NFTBAN_DATA_DIR bash -c 'source "$1" >/dev/null 2>&1; set +eu
        echo "${NFTBAN_STATE_DIR:-${NFTBAN_DATA_DIR:-/var/lib/nftban}/state}/install_state"' _ "$PTF" 2>/dev/null)"
[[ "$out" == "/var/lib/nftban/state/install_state" ]] \
    && pass "a3 production defaults: authority path stays /var/lib/nftban/state/install_state" \
    || fail "a3 production defaults: authority path became '$out'"
ctl="$(in_host "$SB/a" 'nftban_firewall_authority')"
out="$(in_host "$SB/a" 'source "$3" >/dev/null 2>&1; set +eu; echo "AUTH=$(nftban_firewall_authority)"; nft_ipc_request ping "{}"')"
if [[ "$ctl" == GRANTED* && "$out" == *"AUTH=GRANTED"* && "$out" != *refused* ]]; then
    pass "a4 COMMITTED/UPDATE host: GRANTED and nft_ipc_request passes the gate after trusted-flow"
else
    fail "a4 control='$ctl' after-trusted-flow='${out//$'\n'/ | }'"
fi

# --- (b) NFTBAN_STATE_DIR pre-set to the state dir -> unchanged and granted ----------
out="$(in_host "$SB/a" 'export NFTBAN_STATE_DIR="$NFTBAN_DATA_DIR/state"; source "$3" >/dev/null 2>&1; set +eu
        echo "SD=$NFTBAN_STATE_DIR"; echo "AUTH=$(nftban_firewall_authority)"')"
if [[ "$out" == *"SD=$SB/a/data/state"$'\n'* && "$out" == *"AUTH=GRANTED"* ]]; then
    pass "b1 pre-set NFTBAN_STATE_DIR kept by trusted-flow and still GRANTED"
else
    fail "b1 pre-set order: '${out//$'\n'/ | }'"
fi

# --- (c) no authority, no writes: the guard still refuses -------------------------
host "$SB/f" FAILED_REBUILD UPDATE
out="$(in_host "$SB/f" 'source "$3" >/dev/null 2>&1; set +eu; nft_ipc_request ping "{}"')"
[[ "$out" == *'"success":false'*"refused"*"needs-repair"* ]] && pass "c1 FAILED_REBUILD host: nft_ipc_request still refused (needs-repair) after trusted-flow" \
                                                            || fail "c1 FAILED_REBUILD host not refused: '$out'"
host "$SB/r" FAILED_AUTHORITY_ABORT ABORT
out="$(in_host "$SB/r" 'source "$3" >/dev/null 2>&1; set +eu; nft_ipc_request ping "{}"')"
[[ "$out" == *'"success":false'*"refused"* ]] && pass "c2 refused install: nft_ipc_request still refuses after trusted-flow" \
                                             || fail "c2 refused install not refused: '$out'"

# --- T4 · the trusted-flow state file path is unchanged --------------------------
p="$(env -u NFTBAN_STATE_DIR -u NFTBAN_PTF_STATE_FILE bash -c 'source "$1" >/dev/null 2>&1; echo "$_PTF_STATE_FILE"' _ "$PTF" 2>/dev/null)"
[[ "$p" == "/var/lib/nftban/portscan-trusted-flow.state" ]] && pass "T4a default state file /var/lib/nftban/portscan-trusted-flow.state" \
                                                          || fail "T4a default state file moved: '$p'"
p="$(env -u NFTBAN_PTF_STATE_FILE NFTBAN_STATE_DIR="$SB/x" bash -c 'source "$1" >/dev/null 2>&1; echo "$_PTF_STATE_FILE"' _ "$PTF" 2>/dev/null)"
[[ "$p" == "$SB/x/portscan-trusted-flow.state" ]] && pass "T4b a caller-set NFTBAN_STATE_DIR is still honoured" \
                                                 || fail "T4b NFTBAN_STATE_DIR override lost: '$p'"
p="$(NFTBAN_PTF_STATE_FILE="$SB/y.state" bash -c 'source "$1" >/dev/null 2>&1; echo "$_PTF_STATE_FILE"' _ "$PTF" 2>/dev/null)"
[[ "$p" == "$SB/y.state" ]] && pass "T4c NFTBAN_PTF_STATE_FILE override is still honoured" \
                            || fail "T4c NFTBAN_PTF_STATE_FILE override lost: '$p'"

echo ""
[[ "$FAIL" -eq 0 ]] && { echo "RESULT: PASS"; exit 0; }
echo "RESULT: FAIL"; exit 1
