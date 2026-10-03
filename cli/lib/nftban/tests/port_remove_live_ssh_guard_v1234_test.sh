#!/usr/bin/env bash
# =============================================================================
# NFTBan - `nftban port remove|block` never removes an SSH port (v1.234)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="port_remove_live_ssh_guard_v1234_test"
# meta:type="test"
# meta:version="1.234.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-03"
# meta:description="BUG-PORT-REMOVE-CAN-DELETE-LIVE-SSH-PORT. The guard used only SSH_CLIENT, which sudo drops, so `sudo nftban port remove <ssh-port>` deleted it from config and kernel. Drives the real nftban_cmd_port + _nftban_port_live_ssh_reason (extracted from cmd_port.sh) with stubbed IPC/nft/detector against a sandbox ports.d: SSH ports from SSH_CLIENT, from the sshd listener detector (non-22, second port) and from ports.d/00-ssh.conf are refused with nothing changed; a non-SSH port is still removed (positive control); also under the dispatcher IFS."
# meta:input="cli/lib/nftban/cli/cmd_port.sh"
# meta:output="PASS/FAIL per assertion; exit 1 on any failure"
# meta:depends="bash,awk,sed,grep,mktemp"
# meta:ta.id="port_remove_live_ssh_guard_v1234_test"
# meta:ta.owner="cli"
# meta:ta.module="ports"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:inventory.files=""
# meta:inventory.binaries="bash,awk,sed,grep,mktemp"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_LIB_DIR,SSH_CLIENT"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SUBJECT="$ROOT/cli/lib/nftban/cli/cmd_port.sh"
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

[[ -f "$SUBJECT" ]] || { echo "  SUBJECT_NOT_FOUND: $SUBJECT"; echo "TOTAL: pass=0 fail=1"; exit 1; }
for fn in _nftban_port_live_ssh_reason nftban_cmd_port; do
    grep -q "^${fn}() {" "$SUBJECT" || { echo "  SUBJECT_FUNCTION_NOT_FOUND: $fn"; echo "TOTAL: pass=0 fail=1"; exit 1; }
done

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
LOG="$SB/calls.log"
export NFTBAN_CONFIG_DIR="$SB/conf" NFTBAN_LIB_DIR="$SB/no-lib" LOG
export NFTBAN_TABLE_IPV4="ip nftban" NFTBAN_TABLE_IPV6="ip6 nftban"

# The subject functions, extracted by name. The EUID gate is patched to "privileged"
# (the sandbox runs unprivileged); everything else is the shipped text.
subject_text(){
    awk '/^_nftban_port_live_ssh_reason\(\) \{/{c=1} /^nftban_cmd_port\(\) \{/{c=1} c{print} /^}/{if(c){c=0}}' "$SUBJECT" \
        | sed -E 's@\[\[ \$EUID -ne 0 \]\]@[[ 1 -eq 0 ]]@g'
}

# Leaf stubs: the firewall table exists, the daemon runs, and every kernel mutation is
# recorded instead of performed. DETECTED = what the sshd listener detector reports.
stubs(){
    cat <<'STUBS'
nft(){ echo "nft $*" >> "$LOG"; return 0; }
nft_ipc_is_daemon_running(){ return 0; }
nft_ipc_delete_port(){ echo "IPC_DELETE_PORT $*" >> "$LOG"; return 0; }
nft_ipc_delete_element(){ echo "IPC_DELETE_ELEMENT $*" >> "$LOG"; return 0; }
# One port per line like the real detector, independent of the caller's IFS.
nftban_detect_ssh_ports(){ [[ -n "${DETECTED:-}" ]] || return 1; tr ' ' '\n' <<<"$DETECTED"; }
STUBS
}

reset_conf(){
    rm -rf "$NFTBAN_CONFIG_DIR"; mkdir -p "$NFTBAN_CONFIG_DIR/ports.d"
    printf '22/T/I\n2200/T/I\n' > "$NFTBAN_CONFIG_DIR/ports.d/00-ssh.conf"
    printf '2200/T/I\n2222/T/I\n2022/T/I\n8080/T/I\n' > "$NFTBAN_CONFIG_DIR/ports.d/90-custom.conf"
    : > "$LOG"
}

# run <ssh_client|-> <detected> <ifs:default|dispatcher> <verb> <port>
run(){
    local sc="$1" det="$2" ifsmode="$3"; shift 3
    (
        set +eu
        if [[ "$sc" == "-" ]]; then unset SSH_CLIENT; else export SSH_CLIENT="$sc"; fi
        export DETECTED="$det"
        eval "$(stubs)"
        eval "$(subject_text)"
        [[ "$ifsmode" == "dispatcher" ]] && IFS=$'\n\t'
        nftban_cmd_port "$@"
    ) > "$SB/out" 2>&1
}
in_custom(){ grep -q "^$1/" "$NFTBAN_CONFIG_DIR/ports.d/90-custom.conf"; }
kernel_touched(){ grep -qE "IPC_DELETE_(PORT|ELEMENT).*\b$1\b" "$LOG"; }

# refused <label> <port>: rc != 0, says SSH, config + kernel untouched
refused(){
    local label="$1" port="$2" rc="$3"
    if [[ $rc -ne 0 ]] && grep -q "it is an SSH port" "$SB/out" && in_custom "$port" && ! kernel_touched "$port"; then
        ok "$label"
    else
        no "$label (rc=$rc custom_has_port=$(in_custom "$port" && echo yes || echo no) kernel_touched=$(kernel_touched "$port" && echo yes || echo no))"
        sed 's/^/        /' "$SB/out" | tail -4
    fi
}

echo "== C0  positive control: a non-SSH port is still removed (the guard is not blanket) =="
reset_conf; rc=0; run - "2222" default remove 8080 || rc=$?
if [[ $rc -eq 0 ]] && ! in_custom 8080 && grep -q "IPC_DELETE_PORT 8080" "$LOG"; then
    ok "remove 8080: rc 0, gone from ports.d, deleted via IPC"
else no "remove 8080 did not complete (rc=$rc)"; sed 's/^/        /' "$SB/out" | tail -4; fi

echo "== A1  sudo shape: no SSH_CLIENT, sshd listens on 2222 (non-22) =="
reset_conf; rc=0; run - "2222" default remove 2222 || rc=$?
refused "remove 2222 refused without SSH_CLIENT (detector authority)" 2222 $rc

echo "== A2  second sshd port: session on 22, sshd also listens on 2222 =="
reset_conf; rc=0; run "198.51.100.9 50000 22" "22 2222" default remove 2222 || rc=$?
refused "remove 2222 refused while the session is on 22" 2222 $rc

echo "== A3  configured SSH port (00-ssh.conf) also listed in another file, detector empty =="
reset_conf; rc=0; run - "" default remove 2200 || rc=$?
refused "remove 2200 refused (ports.d/00-ssh.conf authority)" 2200 $rc

echo "== A4  the caller's session port (SSH_CLIENT) is still refused =="
reset_conf; rc=0; run "198.51.100.9 50000 2022" "" default remove 2022 || rc=$?
refused "remove 2022 refused (SSH_CLIENT session port)" 2022 $rc

echo "== A5  block uses the same guard =="
reset_conf; rc=0; run - "2222" default block 2222 || rc=$?
refused "block 2222 refused without SSH_CLIENT" 2222 $rc

echo "== A6  under the dispatcher IFS=\$'\\n\\t' (v1.234 R-11 class) =="
reset_conf; rc=0; run - "22 2222" dispatcher remove 2222 || rc=$?
refused "remove 2222 refused under the dispatcher IFS" 2222 $rc
reset_conf; rc=0; run - "22 2222" dispatcher remove 8080 || rc=$?
if [[ $rc -eq 0 ]] && ! in_custom 8080; then ok "remove 8080 still works under the dispatcher IFS"
else no "remove 8080 under the dispatcher IFS (rc=$rc)"; fi

echo
echo "TOTAL: pass=$pass fail=$fail"
[[ $fail -eq 0 ]] || exit 1
