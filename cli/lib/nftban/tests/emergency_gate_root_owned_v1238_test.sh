#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.238: the emergency gate is trusted only as a root-owned regular file
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="emergency_gate_root_owned_v1238_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-24"
# meta:description="v1.238 (owner 2026-11-24; audit KERNEL_WRITER_AUDIT_d016f838 V3). /run/nftban is owned by the nftban service account, so nftban_ipc_check_or_emergency (cli/lib/nftban/lib/nft_ipc.sh) must not trust any .emergency_unlock it finds there. Runs the REAL function with only the gate path redirected into a sandbox and the daemon probe stubbed down: a gate owned by a non-root user is ignored (rc 2), a symlink is ignored even when its target is root-owned (rc 2), a regular root-owned file is honoured (rc 1, NFTBAN_EMERGENCY_MODE=1), no gate gives rc 2. Non-vacuity: the pre-fix test (-f only) would have honoured the non-root gate. Sandbox only; no firewall change."
# meta:input="None (repo source read-only; temp dir)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,sed,stat"
# meta:inventory.files="cli/lib/nftban/lib/nft_ipc.sh"
# meta:inventory.binaries="bash,sed,stat"
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
LIB="$(cd "$SCRIPT_DIR/.." && pwd)/lib/nft_ipc.sh"
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }; no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
ROOT_FILE=""
for f in /etc/os-release /etc/hostname /etc/passwd; do
    [[ -f "$f" && ! -L "$f" && "$(stat -c %u -- "$f")" == 0 ]] && { ROOT_FILE="$f"; break; }
done
[[ -n "$ROOT_FILE" ]] || { echo "SKIP: no root-owned regular file to stand in for an operator-created gate"; exit 0; }
[[ "$(id -u)" != 0 ]] || { echo "SKIP: run as a non-root user (the non-root-owned case needs a non-root creator)"; exit 0; }

# The REAL function, with only its gate path replaced.
fn=$(awk '/^nftban_ipc_check_or_emergency\(\) *\{/{c=1} c{print} c&&/^}/{exit}' "$LIB")
[[ "$fn" == *'local emergency_gate="/run/nftban/.emergency_unlock"'* ]] || { echo "FATAL: gate path not found in $LIB"; exit 1; }
run() { # $1 gate path -> "rc|mode"
    local body="${fn//\/run\/nftban\/.emergency_unlock/$1}"
    bash -c '
        nft_ipc_is_daemon_running() { return 1; }   # daemon down: the gate decides
        logger() { :; }
        eval "$1"
        unset NFTBAN_EMERGENCY_MODE
        rc=0; nftban_ipc_check_or_emergency >/dev/null 2>&1 || rc=$?
        echo "$rc|${NFTBAN_EMERGENCY_MODE:-}"' _ "$body"
}

echo "=== gate ownership and type ==="
touch "$W/gate_mine"
r=$(run "$W/gate_mine"); [[ "$r" == "2|" ]] && ok "gate owned by a non-root user is ignored (rc 2)" || no "non-root gate" "$r"
ln -s "$ROOT_FILE" "$W/gate_link"
r=$(run "$W/gate_link"); [[ "$r" == "2|" ]] && ok "symlink gate is ignored even with a root-owned target (rc 2)" || no "symlink gate" "$r"
r=$(run "$ROOT_FILE"); [[ "$r" == "1|1" ]] && ok "regular root-owned gate is honoured (rc 1, NFTBAN_EMERGENCY_MODE=1)" || no "root gate" "$r"
r=$(run "$W/absent"); [[ "$r" == "2|" ]] && ok "no gate: daemon down is an error (rc 2)" || no "absent gate" "$r"

echo "=== non-vacuity ==="
pre=$(bash -c 'g="$1"; [[ -f "$g" ]] && echo honoured || echo ignored' _ "$W/gate_mine")
[[ "$pre" == honoured ]] && ok "the pre-fix check (-f only) would have honoured the non-root gate" || no "non-vacuity"

echo ""
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
