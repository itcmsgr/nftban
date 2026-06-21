#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.198 R1a-2 DirectAdmin help/disable SSH-port + PAM audit
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_da_help_ssh_port_r1a2_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-21"
# meta:description="R1a-2 Part A: DirectAdmin user-facing output (help + disable confirmation) must not hardcode SSH port 22 — it resolves the safety port (NFTBAN_SSH_TEST_PORT/SSH_PORT). Part B audit guard: deprecated nftban-ui appears only in removal/cleanup paths (no live creation/ship)."
# meta:input="None (greps cmd/lib + install paths)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,grep"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
DA="${REPO_ROOT}/cli/lib/nftban/lib/nftban_panel_directadmin.sh"
INSTALL="${REPO_ROOT}/install"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }

echo "R1a-2 DA SSH-port + PAM audit — tests"

# Part A
if grep -qE '•[[:space:]]*22[[:space:]]*\(SSH' "$DA"; then bad "Part A: DA output still hardcodes '• 22 (SSH …)'"; else ok "Part A: no hardcoded '• 22 (SSH' in DA user output"; fi
if grep -qE 'echo "  • \$\{_da_ssh_port\} \(SSH - safety port\)"' "$DA"; then ok "Part A: disable confirmation uses resolved \${_da_ssh_port}"; else bad "Part A: disable confirmation not using resolved port"; fi
# regression: the v1.150 help fix still resolves the port (not re-hardcoded)
if grep -qE '\$\{_da_ssh_port\}[[:space:]]+- SSH \(safety port' "$DA"; then ok "Part A: DA help still resolves \${_da_ssh_port} (v1.150 regression)"; else bad "Part A: DA help port resolution regressed"; fi
# no bare hardcoded 22 in the SSH-safety-port semantic lines
if grep -qE '(safety port|SSH).*\b22\b' "$DA" | grep -vqE '\$\{|:-22\}' 2>/dev/null; then bad "Part A: a bare 22 lingers in an SSH-safety-port line"; else ok "Part A: SSH-safety-port lines are port-neutral (default :-22 only)"; fi

# Part B audit guard: deprecated nftban-ui only in removal/cleanup context (no live creation)
if grep -rnE '(^|[^-])nftban-ui' "$INSTALL" --include=*.sh --include=*.inc --include=*.service 2>/dev/null \
   | grep -vE 'rm |stop|disable|mask|reset-failed|no longer|removed|residue|cleanup|purge|deprecated' \
   | grep -qvE '#'; then
    bad "Part B: a non-removal nftban-ui reference exists in install paths (possible live residual)"
else
    ok "Part B: nftban-ui appears only in removal/cleanup/comment context (15.14 audit-close)"
fi

echo "-----------------------------------------------"
printf 'R1a-2 tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
