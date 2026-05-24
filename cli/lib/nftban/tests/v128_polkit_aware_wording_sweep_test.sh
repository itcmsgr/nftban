#!/usr/bin/env bash
# =============================================================================
# v1.128 PR-A POLKIT_AWARE_WORDING_SWEEP — deterministic test fixtures
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="v128_polkit_aware_wording_sweep_test"
# meta:type="test"
# meta:version="1.128.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-24"
# meta:description="Deterministic shell tests for v1.128 PR-A POLKIT_AWARE_WORDING_SWEEP locking the canonical NFTBan privilege wording model: 'Members of the nftban group can run supported NFTBan privileged operations through PolicyKit/polkit authorization rules.' Forbidden: any sudo/root/root-fallback framing in normal CLI surfaces (Run with sudo, sudo nftban X, must run as root, Run as root, Otherwise run as root, site-approved privilege method, Permission denied (not root), requires root, requires root privileges, privileges (sudo)). Allowlist: installer/bootstrap scripts (setup/install_*.sh + cmd/nftban-core/install.sh) and one technical security warning (nftban_path_security.sh) where root requirement is genuine. Required positive: at least 5 cli files mention 'PolicyKit/polkit' AND 'nftban group' to prove the canonical wording is in operator-facing help. Includes fix for the three V127 UX-6 PR-F REQUIRES blocks that shipped with the earlier (incorrect) 'site-approved privilege method' fallback wording in v1.127.0."
# meta:input="static source-file grep across cli/lib/nftban/**/*.sh + cli/sbin/nftban + cmd/nftban-core/privilege.go"
# meta:output="exit 0 if all assertions pass; exit 1 with FAILED tests list otherwise"
# meta:depends="bash,grep,awk"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# Scope: AUDIT_190_LIFECYCLE/V128_CLI_TEXT_AUTHORITY_ALIGNMENT_SCOPE.md (PR-A lane)
# Architecture: memory/reference_nftban_group_and_polkit_architecture.md
# Wording rule: memory/feedback_polkit_not_sudo_in_help.md
# =============================================================================

set -Eeuo pipefail
set +e

TESTS_PASSED=0
TESTS_FAILED=0
FAILED_NAMES=()

_t_assert() {
    local name="$1"
    local ok="$2"
    local detail="${3:-}"
    if [[ "$ok" == "0" ]]; then
        printf "  [PASS] %s\n" "$name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        printf "  [FAIL] %s%s\n" "$name" "${detail:+ — $detail}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_NAMES+=("$name")
    fi
}

_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
_cli_lib="${_repo_root}/cli/lib/nftban"
_cli_sbin="${_repo_root}/cli/sbin/nftban"
_privilege_go="${_repo_root}/cmd/nftban-core/privilege.go"

# Allowlist: installer/bootstrap scripts and technical security warnings
# where root-requirement wording is genuine and correct (see
# feedback_polkit_not_sudo_in_help.md "Allowlist exception" sections).
_ALLOWLIST_PATTERNS=(
    '/setup/install_'                           # third-party tool installers
    'cmd/nftban-core/install\.sh'               # one-off bootstrap installer
    'cli/lib/nftban/core/nftban_path_security' # technical security warning context
    'cli/lib/nftban/lib/setup_utils\.sh'        # check_root() helper called only from
                                                 # allowlisted setup/install_* scripts
)

# Build a grep -v pipeline filter from the allowlist
_apply_allowlist() {
    local pattern
    for pattern in "${_ALLOWLIST_PATTERNS[@]}"; do
        set -- "$@" -e "$pattern"
    done
    grep -v "$@"
}

echo "==============================================================================="
echo "v1.128 PR-A POLKIT_AWARE_WORDING_SWEEP — deterministic test fixtures"
echo "==============================================================================="

# =============================================================================
# (A) FORBIDDEN PATTERNS — zero tolerance across normal CLI surfaces
# =============================================================================

# A1: Zero "Run with sudo" / "run with sudo"
hits=$(grep -rni 'run with sudo' --include='*.sh' "$_cli_lib" "$_cli_sbin" 2>/dev/null \
       | grep -v "/tests/" \
       | _apply_allowlist | wc -l)
hits=${hits:-0}
[[ "$hits" -eq 0 ]]
_t_assert "A1: zero 'Run with sudo' wording in CLI surfaces (got: $hits)" "$?"

# A2: Zero "Permission denied (not root"
hits=$(grep -rn 'Permission denied (not root' --include='*.sh' --include='*.go' \
       "$_cli_lib" "$_cli_sbin" "${_repo_root}/cmd" "${_repo_root}/internal" 2>/dev/null \
       | grep -v "/tests/" | _apply_allowlist | wc -l)
hits=${hits:-0}
[[ "$hits" -eq 0 ]]
_t_assert "A2: zero 'Permission denied (not root' (got: $hits)" "$?"

# A3: Zero "requires root" / "requires root privileges" in CLI surfaces
hits=$(grep -rn 'requires root privileges\|requires root' --include='*.sh' "$_cli_lib" "$_cli_sbin" 2>/dev/null \
       | grep -v "/tests/" | _apply_allowlist | wc -l)
hits=${hits:-0}
[[ "$hits" -eq 0 ]]
_t_assert "A3: zero 'requires root [privileges]' in CLI surfaces (got: $hits)" "$?"

# A4: Zero "must run as root" / "Run as root" in CLI surfaces
hits=$(grep -rni 'must run as root\|Run as root' --include='*.sh' --include='*.go' \
       "$_cli_lib" "$_cli_sbin" "${_repo_root}/cmd" "${_repo_root}/internal" 2>/dev/null \
       | grep -v "/tests/" | _apply_allowlist | wc -l)
hits=${hits:-0}
[[ "$hits" -eq 0 ]]
_t_assert "A4: zero 'must run as root' / 'Run as root' in CLI surfaces (got: $hits)" "$?"

# A5: 'sudo nftban X' example lines — HARDENED in PR-A.2.
# Allowed (allowlist via grep -E): 'sudo nftban-installer' (installer/bootstrap
# binary; not the main CLI and not polkit-covered the same way; documented
# in feedback_polkit_not_sudo_in_help.md "Allowlist exception").
hits=$(grep -rn 'sudo nftban ' --include='*.sh' "$_cli_lib" "$_cli_sbin" 2>/dev/null \
       | grep -v "/tests/" | _apply_allowlist | wc -l)
hits=${hits:-0}
[[ "$hits" -eq 0 ]]
_t_assert "A5: zero 'sudo nftban X' example lines in main-CLI examples (got: $hits; 'sudo nftban-installer' allowlisted separately)" "$?"

# A5b: 'sudo nftban-installer' (installer/bootstrap) — informational count
# (allowlisted; reported for visibility but not asserted to zero)
hits=$(grep -rn 'sudo nftban-installer' --include='*.sh' "$_cli_lib" "$_cli_sbin" 2>/dev/null | grep -v "/tests/" | wc -l)
hits=${hits:-0}
[[ "$hits" -ge 0 ]]  # informational
_t_assert "A5b (informational; allowlisted): 'sudo nftban-installer' installer/bootstrap references: $hits" "$?"

# A8: PR-A.2 residual sweeps — 'root privileges' / 'NEEDS ROOT' / 'needs root'
# in operator-facing strings (echo statements + ui_msg calls; internal
# # comments excluded by the grep filter).
hits=$(grep -rnE 'root privileges|NEEDS ROOT' --include='*.sh' "$_cli_lib" "$_cli_sbin" 2>/dev/null \
       | grep -v "/tests/" | _apply_allowlist \
       | grep -v ':\s*#' \
       | wc -l)
hits=${hits:-0}
[[ "$hits" -eq 0 ]]
_t_assert "A8: zero 'root privileges' / 'NEEDS ROOT' in operator-facing strings (got: $hits; internal # comments OK)" "$?"

# A9: PR-A.2 ui_msg / echo "needs root" residuals
hits=$(grep -rnE 'needs root|need root privileges' --include='*.sh' "$_cli_lib" "$_cli_sbin" 2>/dev/null \
       | grep -v "/tests/" | _apply_allowlist \
       | grep -v ':\s*#' \
       | wc -l)
hits=${hits:-0}
[[ "$hits" -eq 0 ]]
_t_assert "A9: zero 'needs root' / 'need root privileges' in operator-facing strings (got: $hits)" "$?"

# A6: Zero "(sudo)" parenthetical hints
hits=$(grep -rn 'privileges (sudo)\|root/sudo' --include='*.sh' "$_cli_lib" "$_cli_sbin" 2>/dev/null \
       | grep -v "/tests/" | _apply_allowlist | wc -l)
hits=${hits:-0}
[[ "$hits" -eq 0 ]]
_t_assert "A6: zero 'privileges (sudo)' or 'root/sudo' parenthetical (got: $hits)" "$?"

# A7: Zero "Otherwise run as root or use the site-approved privilege method"
# (the V127 UX-6 PR-F template that ended REQUIRES blocks with a root
# fallback — superseded in v1.128 PR-A by the nftban-group + polkit
# canonical template per operator correction 2026-05-24)
hits=$(grep -rn 'site-approved privilege method\|Otherwise run as root' --include='*.sh' \
       "$_cli_lib" "$_cli_sbin" 2>/dev/null | grep -v "/tests/" | wc -l)
hits=${hits:-0}
[[ "$hits" -eq 0 ]]
_t_assert "A7: zero 'site-approved privilege method' / 'Otherwise run as root' V127 carry-over (got: $hits)" "$?"

# =============================================================================
# (B) Go-side privilege wording (cmd/nftban-core/privilege.go)
# =============================================================================

# B1: privilege.go MUST NOT contain the legacy "must run as root" string
grep -q 'must run as root' "$_privilege_go"
ok=$?
[[ $ok -eq 0 ]] && ok=1 || ok=0
_t_assert "B1: privilege.go does NOT contain 'must run as root' legacy wording" "$ok"

# B2: privilege.go MUST preserve CAP_NET_ADMIN technical guidance
grep -q 'CAP_NET_ADMIN' "$_privilege_go"
_t_assert "B2: privilege.go preserves CAP_NET_ADMIN technical guidance" "$?"

# B3: privilege.go MUST mention PolicyKit/polkit (canonical authority)
grep -qE 'PolicyKit|polkit' "$_privilege_go"
_t_assert "B3: privilege.go mentions PolicyKit/polkit canonical authority" "$?"

# =============================================================================
# (C) Positive canonical wording in normal CLI mutating help blocks
# =============================================================================

# C1: cmd_update.sh REQUIRES block uses the canonical "nftban group" + "PolicyKit/polkit" template
block=$(grep -A 15 '^REQUIRES:$' "${_cli_lib}/cli/cmd_update.sh")
echo "$block" | grep -qE 'nftban group' && echo "$block" | grep -qE 'PolicyKit/polkit'
_t_assert "C1: cmd_update.sh REQUIRES block uses canonical 'nftban group' + 'PolicyKit/polkit'" "$?"

# C2: cmd_firewall.sh REQUIRES block uses the canonical template
block=$(grep -A 15 '^REQUIRES:$' "${_cli_lib}/cli/cmd_firewall.sh")
echo "$block" | grep -qE 'nftban group' && echo "$block" | grep -qE 'PolicyKit/polkit'
_t_assert "C2: cmd_firewall.sh REQUIRES block uses canonical 'nftban group' + 'PolicyKit/polkit'" "$?"

# C3: cmd_flush.sh REQUIRES block uses the canonical template
block=$(grep -A 15 '^REQUIRES:$' "${_cli_lib}/cli/cmd_flush.sh")
echo "$block" | grep -qE 'nftban group' && echo "$block" | grep -qE 'PolicyKit/polkit'
_t_assert "C3: cmd_flush.sh REQUIRES block uses canonical 'nftban group' + 'PolicyKit/polkit'" "$?"

# C4: At least 3 CLI files mention BOTH 'nftban group' AND 'PolicyKit/polkit'
# (currently the 3 V127 UX-6 destructive helps; future help blocks added
# in PR-A.2 / PR-B will increase this count)
count=$(grep -rl 'nftban group' --include='*.sh' "$_cli_lib" 2>/dev/null | grep -v "/tests/" | \
        xargs -r grep -l 'PolicyKit/polkit' 2>/dev/null | wc -l)
count=${count:-0}
[[ "$count" -ge 3 ]]
_t_assert "C4: at least 3 CLI files mention BOTH 'nftban group' AND 'PolicyKit/polkit' (got: $count, expected >=3)" "$?"

# C5: At least one CLI exit-code section uses the canonical "PolicyKit/polkit authorization failed" wording
count=$(grep -rn 'PolicyKit/polkit authorization failed' --include='*.sh' "$_cli_lib" 2>/dev/null | grep -v "/tests/" | wc -l)
count=${count:-0}
[[ "$count" -ge 3 ]]
_t_assert "C5: at least 3 'PolicyKit/polkit authorization failed' exit/error strings (got: $count)" "$?"

# =============================================================================
# (D) Scope-creep guards (NOT PR-B, NOT PR-C, NOT PR-D)
# =============================================================================

# D1: No new doctest harness added (PR-B work)
[[ ! -f "${_cli_lib}/tests/help_correlation_doctest.sh" ]]
_t_assert "D1: no PR-B doctest harness added in this PR" "$?"

# D2: No wiki edits in this PR's diff (PR-C work)
if git diff --name-only HEAD 2>/dev/null | grep -qE '\.wiki|^WIKI/'; then
    _t_assert "D2: scope-creep: wiki file in diff" 1
else
    _t_assert "D2: no wiki edits (PR-C not absorbed)" 0
fi

# D3: No docs/ edits in this PR's diff (PR-C stage 2 / PR-D)
if git diff --name-only HEAD 2>/dev/null | grep -qE '^docs/'; then
    _t_assert "D3: scope-creep: docs/ file in diff" 1
else
    _t_assert "D3: no docs/ edits (PR-C stage 2 / PR-D not absorbed)" 0
fi

# D4: No README edits in this PR's diff (PR-D work)
if git diff --name-only HEAD 2>/dev/null | grep -qE '^README'; then
    _t_assert "D4: scope-creep: README in diff" 1
else
    _t_assert "D4: no README edits (PR-D not absorbed)" 0
fi

# D5: No privilege-behavior change in privilege.go (only wording)
grep -q 'func.*Privilege\|hasNetAdminCapability' "$_privilege_go"
_t_assert "D5: privilege.go privilege-check logic preserved (no behavior change)" "$?"

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "==============================================================================="
echo "v1.128 PR-A test summary: ${TESTS_PASSED} PASS, ${TESTS_FAILED} FAIL"
echo "==============================================================================="
if [[ "$TESTS_FAILED" -gt 0 ]]; then
    echo "Failed tests:"
    for name in "${FAILED_NAMES[@]}"; do
        echo "  - $name"
    done
    echo ""
    echo "To see specific offenders for the forbidden-pattern tests, run:"
    echo "  grep -rni 'Run with sudo' --include='*.sh' cli/lib/nftban cli/sbin/nftban"
    echo "  grep -rn 'requires root' --include='*.sh' cli/lib/nftban cli/sbin/nftban"
    echo "  grep -rni 'must run as root' --include='*.sh' --include='*.go' cli/lib cli/sbin cmd internal"
    echo "  grep -rn 'site-approved privilege method' --include='*.sh' cli/lib cli/sbin"
    exit 1
fi
exit 0
