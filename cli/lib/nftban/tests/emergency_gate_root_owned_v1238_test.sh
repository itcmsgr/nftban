#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.238: the emergency gate lives in the root-only /run/nftban-writers
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="emergency_gate_root_owned_v1238_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-24"
# meta:description="v1.238 (owner 2026-11-24; audit KERNEL_WRITER_AUDIT_d016f838 V3). nftban_ipc_check_or_emergency (cli/lib/nftban/lib/nft_ipc.sh) honours only /run/nftban-writers/.emergency_unlock in a root:root 0700 directory, as a regular root-owned file, decided from one lstat; the old /run/nftban marker is ignored. Runs the REAL function (and the REAL cmd_flush.sh _flush_check_daemon caller) with the two paths redirected into a sandbox and the daemon probe stubbed down. As any user: directory not root:root 0700 -> ignored, legacy marker ignored, absent -> refused. As root with a real nftban account (lab): role split in a root:root 0700 sandbox dir - nftban cannot create, symlink or replace the marker; root creates it (honoured) and removes it (refused again); a root-owned symlink marker and a non-0700 dir are ignored. Sandbox only; no firewall change."
# meta:input="None (repo source read-only; temp dir)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,stat,runuser"
# meta:inventory.files="cli/lib/nftban/lib/nft_ipc.sh,cli/lib/nftban/cli/cmd_flush.sh"
# meta:inventory.binaries="bash,stat,runuser"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="emergency_gate_root_owned_v1238_test"
# meta:ta.owner="core"
# meta:ta.module="ipc"
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
LIBROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$LIBROOT/lib/nft_ipc.sh"; FLUSH="$LIBROOT/cli/cmd_flush.sh"
PASS=0; FAIL=0; SKIP=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }; no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
chmod 0755 "$W"                                  # traversable, so a second account can try

extract(){ awk -v n="$1" '$0 ~ "^"n"\\(\\) *\\{" {c=1} c{print} c&&/^}/{exit}' "$2"; }
fn=$(extract nftban_ipc_check_or_emergency "$LIB")
caller=$(extract _flush_check_daemon "$FLUSH")
[[ "$fn" == *'local gate_dir="/run/nftban-writers"'* && "$fn" == *'local legacy_gate="/run/nftban/.emergency_unlock"'* ]] \
    || { echo "FATAL: gate paths not found in $LIB"; exit 1; }
[[ -n "$caller" ]] || { echo "FATAL: _flush_check_daemon not found in $FLUSH"; exit 1; }
SB_DIR="$W/writers"; SB_LEGACY="$W/legacy/.emergency_unlock"; mkdir -p "$W/legacy"
body="${fn//\/run\/nftban-writers/$SB_DIR}"; body="${body//\/run\/nftban\/.emergency_unlock/$SB_LEGACY}"

gate(){ # -> "rc|NFTBAN_EMERGENCY_MODE|caller_rc|_FLUSH_IPC_MODE"
    bash -c '
        nft_ipc_is_daemon_running() { return 1; }   # daemon stopped: the marker decides
        logger() { :; }
        eval "$1"; eval "$2"
        unset NFTBAN_EMERGENCY_MODE
        rc=0; nftban_ipc_check_or_emergency >/dev/null 2>&1 || rc=$?
        m="${NFTBAN_EMERGENCY_MODE:-}"; unset NFTBAN_EMERGENCY_MODE
        crc=0; _flush_check_daemon >/dev/null 2>&1 || crc=$?
        echo "$rc|$m|$crc|$_FLUSH_IPC_MODE"' _ "$body" "$caller"
}
HONOURED="1|1|0|1"; REFUSED="2||1|2"

echo "=== any user ==="
r=$(gate); [[ "$r" == "$REFUSED" ]] && ok "daemon stopped + no marker: gate rc 2, flush caller refuses (rc 1)" || no "absent" "$r"
touch "$SB_LEGACY"
r=$(gate); [[ "$r" == "$REFUSED" ]] && ok "the old /run/nftban marker no longer enables the gate" || no "legacy marker" "$r"
rm -f "$SB_LEGACY"
mkdir -m 0700 "$SB_DIR"; touch "$SB_DIR/.emergency_unlock"
if [[ "$(id -u)" != 0 ]]; then
    r=$(gate); [[ "$r" == "$REFUSED" ]] && ok "marker in a directory not owned by root is ignored" || no "non-root dir" "$r"
fi
rm -rf "$SB_DIR"

echo "=== role split (root + real nftban account) ==="
if [[ "$(id -u)" != 0 ]] || ! id nftban >/dev/null 2>&1; then
    echo "  - SKIP: needs root and the nftban account (run on a lab host as root)"; SKIP=1
else
    as_nftban(){ runuser -u nftban -- "$@" 2>/dev/null; }
    mkdir -m 0700 "$SB_DIR"                       # root:root 0700, as tmpfiles creates it
    [[ "$(stat -c '%U:%G:%a' "$SB_DIR")" == "root:root:700" ]] || chown root:root "$SB_DIR"
    # Control: the account really can write where it owns the directory (the old /run/nftban model).
    chown nftban "$W/legacy"
    as_nftban touch "$SB_LEGACY" && ok "control: nftban CAN create the old-path marker (service-owned dir)" || no "control: nftban could not write its own dir"
    r=$(gate); [[ "$r" == "$REFUSED" ]] && ok "that nftban-created old-path marker enables nothing" || no "nftban legacy marker" "$r"
    rm -f "$SB_LEGACY"
    as_nftban touch "$SB_DIR/.emergency_unlock" && no "nftban created the marker" || ok "nftban cannot create the marker (permission denied)"
    as_nftban ln -s /etc/passwd "$SB_DIR/.emergency_unlock" && no "nftban planted a symlink" || ok "nftban cannot plant a symlink marker"
    r=$(gate); [[ "$r" == "$REFUSED" ]] && ok "no marker: refused" || no "no marker" "$r"
    touch "$SB_DIR/.emergency_unlock"
    r=$(gate); [[ "$r" == "$HONOURED" ]] && ok "root creates the marker: honoured (rc 1, NFTBAN_EMERGENCY_MODE=1, flush caller proceeds)" || no "root marker" "$r"
    as_nftban rm -f "$SB_DIR/.emergency_unlock" || true; [[ -f "$SB_DIR/.emergency_unlock" ]] && ok "nftban cannot remove or replace the marker" || no "nftban removed the marker"
    as_nftban mv -f /dev/null "$SB_DIR/.emergency_unlock" || true; [[ -f "$SB_DIR/.emergency_unlock" ]] && ok "nftban cannot rename over the marker" || no "nftban replaced the marker"
    rm -f "$SB_DIR/.emergency_unlock"
    r=$(gate); [[ "$r" == "$REFUSED" ]] && ok "root removes the marker: refused again" || no "after rm" "$r"
    ln -s /etc/passwd "$SB_DIR/.emergency_unlock"
    r=$(gate); [[ "$r" == "$REFUSED" ]] && ok "root-owned symlink marker (root-owned target) is ignored" || no "symlink" "$r"
    rm -f "$SB_DIR/.emergency_unlock"; touch "$SB_DIR/.emergency_unlock"
    chmod 0755 "$SB_DIR"
    r=$(gate); [[ "$r" == "$REFUSED" ]] && ok "directory mode not 0700: ignored" || no "dir mode" "$r"
    chmod 0700 "$SB_DIR"; chown nftban "$SB_DIR"
    r=$(gate); [[ "$r" == "$REFUSED" ]] && ok "directory owned by nftban: ignored (even with a root marker)" || no "dir owner" "$r"
    chown root "$SB_DIR"
    r=$(gate); [[ "$r" == "$HONOURED" ]] && ok "control: restored root:root 0700 + root marker honoured" || no "control" "$r"
fi

echo ""
echo "RESULTS: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[[ $FAIL -eq 0 ]]
