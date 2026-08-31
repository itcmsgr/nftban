#!/usr/bin/env bash
# =============================================================================
# NFTBan - the CIDR converter must fail closed, never empty a non-empty list
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="cidr-merge-failclosed-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Regression guard for the GeoBan self-zeroing defect. nftban_cidr_merge invoked netmask as 'netmask -c < file', but netmask(1) parses ARGUMENTS and reads nothing from stdin, so it printed only a usage hint to a discarded stderr; the converter then returned 0 with an EMPTY output file. GeoBan's apply is gated on the resulting count, so nft_ipc_sync_or_apply was never called at all, and the module printed 'GeoBan applied' and 'ACTIVELY BLOCKING' having committed nothing. Measured on lab2 (netmask present): 0 of 524,032 intended addresses in the kernel. lab4 (netmask absent) was correct, so the defect is triggered BY INSTALLING THE RECOMMENDED PACKAGE. Asserts: a merge can never turn a non-empty list into an empty one; a method that does is rejected and the next method is tried; total conversion failure returns non-zero with an empty output rather than a false success; and the bash fallback returns 0 when nothing needed merging."
# meta:ta.id="cidr_merge_failclosed_test"
# meta:ta.owner="geoban"
# meta:ta.module="cidr-conversion-truth"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.blocking="true"
# meta:ta.timeout="60"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:inventory.files="cli/lib/nftban/lib/nftban_dataset_cidr.sh"
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

# shellcheck source=/dev/null
source "${LIB_DIR}/lib/nftban_dataset_cidr.sh"
set +e   # the library imposes `set -Eeuo pipefail` on its caller; observe rc

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cd "$T" || exit 1
mkdir -p bin; export PATH="$T/bin:$PATH"
printf '%s\n' 10.0.0.0/8 10.1.0.0/16 192.168.1.0/24 > in.txt
: > empty.txt
printf '   \n\n  \n' > ws.txt
# `grep -c` prints 0 AND exits 1 on no match, so `|| echo 0` would emit "0\n0".
# Capture stdout first, then substitute only on a genuine failure.
records() { local n; n="$(grep -cE '[^[:space:]]' "$1" 2>/dev/null)" || n="${n:-0}"; printf '%s' "${n:-0}"; }
stub_netmask() { printf '#!/bin/sh\n%s\n' "$1" > bin/netmask; chmod +x bin/netmask; }

echo "=== the converter's core invariant ==="
nftban_cidr_merge empty.txt out.txt 4
[[ $? -eq 0 && "$(records out.txt)" -eq 0 ]] && ok "genuinely empty input -> rc 0, empty output (not a failure)" || bad "empty input mishandled"

nftban_cidr_merge ws.txt out.txt 4
[[ $? -eq 0 && "$(records out.txt)" -eq 0 ]] && ok "whitespace-only input counts as empty, not as records" || bad "whitespace input mishandled"

nftban_cidr_merge /nonexistent/path out.txt 4
[[ $? -ne 0 ]] && ok "missing input file -> non-zero (ENOENT is not 'no ranges')" || bad "missing input returned success"

echo "=== THE MOTIVATING DEFECT: a method that empties a non-empty list ==="
# This is exactly what `netmask -c < file` did on a host where netmask exists.
stub_netmask 'exit 0'
nftban_cidr_merge in.txt out.txt 4; rc=$?
if [[ $rc -eq 0 && "$(records out.txt)" -eq 3 || $rc -eq 0 && "$(records out.txt)" -gt 0 ]]; then
    ok "a method emitting NOTHING is rejected; a later method supplies the list ($(records out.txt) CIDRs)"
else
    bad "empty-from-non-empty accepted: rc=$rc records=$(records out.txt)"
fi
[[ "$(records out.txt)" -gt 0 ]] && ok "coverage survived the failing method (never silently zeroed)" || bad "output was zeroed"

stub_netmask 'echo "not-an-ip"'
nftban_cidr_merge in.txt out.txt 4
[[ $? -eq 0 && "$(records out.txt)" -gt 0 ]] && ok "a method emitting only unparseable output is rejected, not applied" || bad "garbage output accepted"

echo "=== total conversion failure is reported, never disguised as success ==="
stub_netmask 'exit 0'
_real_bash_merge="$(declare -f _nftban_cidr_merge_bash)"
_nftban_cidr_merge_bash() { : > "$2"; return 1; }
nftban_cidr_merge in.txt out.txt 4; rc=$?
[[ $rc -ne 0 ]] && ok "every method failing -> non-zero (caller must not apply)" || bad "total failure returned success"
[[ "$(records out.txt)" -eq 0 ]] && ok "failed conversion leaves an EMPTY output, so a caller that ignores rc applies nothing" || bad "failed conversion left partial output"
eval "$_real_bash_merge"

echo "=== the bash fallback's own exit status ==="
rm -f bin/netmask
# Non-overlapping input: nothing to merge. The function once ended on
# `[[ $merged -gt 0 ]]`, so this NORMAL case returned 1 and aborted the caller
# under the inherited `set -e`.
printf '%s\n' 10.0.0.0/8 192.168.1.0/24 > nomerge.txt
_nftban_cidr_merge_bash nomerge.txt out.txt 4
[[ $? -eq 0 ]] && ok "bash fallback returns 0 when nothing needed merging" || bad "bash fallback returned non-zero on a no-op merge"

echo
echo "=== cidr_merge_failclosed: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
