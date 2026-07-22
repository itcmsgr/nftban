#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.152 BUG-S1a/S1b: status DOWN rc-contract (+ caller safety)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="status_rc_contract_v152_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-06"
# meta:description="Locks BUG-S1a/S1b: the two ERROR-and-DOWN paths in _nftban_protection_state_validator (cmd_status.sh: validator-missing + validator-empty) must return rc>=1 (v1.139.2 rc-contract), not the rc=0 of a bare 'return' after 'echo DOWN'. Because the helper output is captured by plain 'var=\$(...)' under set -e, the fix pairs each 'return 1' with '|| true' guards at the 3 capture sites so the DOWN string is still used and the top-level exit stays mapped from base_state (DOWN -> 2). Asserts the shipped code (return 1 on both paths + guarded captures) and proves the caller-safety pattern (echo DOWN; return 1 | var=\$(f) || true under set -e keeps the string and does not abort). Hermetic: no host/nft/IPC."
# meta:input="None (self-contained)"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep"
# meta:inventory.files="cli/lib/nftban/cli/cmd_status.sh"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="status_rc_contract_v152_test"
# meta:ta.owner="cli"
# meta:ta.module="status"
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
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
S="$REPO_ROOT/cli/lib/nftban/cli/cmd_status.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✓ $1"; }
no() { FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

echo "=== shipped: the validator ERROR+DOWN paths return rc>=1 (no bare 'return') ==="
# a bare 'return' on the line immediately after 'echo "DOWN"' is the rc=0 bug
bare=$(grep -A1 'echo "DOWN"' "$S" | grep -cE '^[[:space:]]*return$' || true)
[[ "${bare:-0}" -eq 0 ]] && ok "no 'echo DOWN' followed by a bare 'return' remains" || no "bare return after DOWN still present" "$bare"
n_s1=$(grep -cE 'return 1.*BUG-S1' "$S" || true)
[[ "${n_s1:-0}" -eq 2 ]] && ok "both validator DOWN paths now 'return 1' (BUG-S1a + BUG-S1b)" || no "expected 2 'return 1' BUG-S1 markers" "$n_s1"

echo "=== shipped: caller-safety guards on the 3 plain captures ==="
[[ "$(grep -cE '_nftban_protection_state\) \|\| true' "$S")" -eq 3 ]] \
    && ok "all 3 'var=\$(_nftban_protection_state)' captures guarded with '|| true'" \
    || no "expected 3 guarded captures" "$(grep -cE '_nftban_protection_state\) \|\| true' "$S")"
# guard: no UNGUARDED plain capture remains
ung=$(grep -nE '=\$\(_nftban_protection_state\)$' "$S" | grep -vE '\|\| true' | grep -cE '.' || true)
[[ "${ung:-0}" -eq 0 ]] && ok "no unguarded plain '=\$(_nftban_protection_state)' capture remains" || no "unguarded capture present" "$ung"

echo "=== caller-safety pattern proven (echo DOWN; return 1 | capture || true under set -e) ==="
# helper mirrors the fixed validator DOWN path
_val() { echo "ERROR: stub" >&2; echo "DOWN"; return 1; }
# the fixed capture pattern: plain assignment + || true under set -e must NOT abort, must keep the string
raw=$(_val 2>/dev/null) || true
[[ "$raw" == "DOWN" ]] && ok "captured 'DOWN' string despite rc=1 (caller not aborted under set -e)" || no "capture" "$raw"
# base_state -> exit mapping (mirror cmd_status.sh :474-481): DOWN -> exit 2
base="${raw%%:*}"
case "$base" in PROTECTED) ec=0 ;; DEGRADED) ec=1 ;; *) ec=2 ;; esac
[[ "$ec" -eq 2 ]] && ok "DOWN base_state maps to top-level exit 2 (contract intact)" || no "exit mapping" "$ec"
# prove the helper itself now honors rc>=1 (guard the call so set -e doesn't abort)
rc=0; _val >/dev/null 2>&1 || rc=$?
[[ "$rc" -ge 1 ]] && ok "helper returns rc>=1 on ERROR+DOWN (was rc=0)" || no "helper rc" "$rc"

echo ""
echo "================================================================"
echo "status_rc_contract_v152: PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[[ $FAIL -eq 0 ]]
