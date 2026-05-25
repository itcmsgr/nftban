#!/usr/bin/env bash
# =============================================================================
# V130 PR-A Option C — polkit-authorized validate service regression test
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="v130_polkit_validate_service_test"
# meta:type="test"
# meta:version="1.130.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-25"
# meta:description="Deterministic shell assertions locking the V130 PR-A Option C closure for D6.A: nftban-firewall-validate.service exists with the expected oneshot+root+CAP_NET_ADMIN shape, is in the 10-nftban-systemd.rules allowedUnits[] polkit whitelist, is picked up by the systemd-install-list generator, the cmd_firewall.sh CLI routes non-root callers through systemctl start --wait, and the v1.129 PR-C D6.B Remediation in validator.go is consistent with the now-real service unit. The intent of this test is to prevent regression: if any of these files drift apart (e.g. someone renames the service file but forgets the polkit whitelist), CI fails."
# meta:input="self-contained; pattern-greps on the source files"
# meta:output="[PASS]/[FAIL] per assertion; exit 1 on first failure; exit 0 if all pass"
# meta:depends="bash,grep"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# Scope: AUDIT_190_LIFECYCLE/V130_D6A_POLKIT_DESIGN_ANALYSIS.md (Option C)
#        + AUDIT_190_LIFECYCLE/V130_D6A_POLKIT_DECISION.md
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
export NFTBAN_LIB_DIR="${_repo_root}/cli/lib/nftban"

_unit_file="${_repo_root}/install/systemd/nftban-firewall-validate.service"
_polkit_file="${_repo_root}/packaging/polkit-1/rules.d/10-nftban-systemd.rules"
_install_list="${_repo_root}/install/packaging/systemd/nftban-systemd-install.list"
_firewall_cli="${NFTBAN_LIB_DIR}/cli/cmd_firewall.sh"
_validator_go="${_repo_root}/internal/validator/validator.go"

echo "==============================================================================="
echo "V130 PR-A Option C — polkit-authorized validate service regression test"
echo "==============================================================================="
echo "  Repo root:    $_repo_root"
echo

# ----------------------------------------------------------------------------
# A: systemd unit file shape
# ----------------------------------------------------------------------------
echo "--- A: nftban-firewall-validate.service unit shape ---"

[[ -f "$_unit_file" ]] && _t_assert "A1: unit file exists at install/systemd/nftban-firewall-validate.service" 0 \
    || _t_assert "A1: unit file exists at install/systemd/nftban-firewall-validate.service" 1 "$_unit_file missing"

if [[ -f "$_unit_file" ]]; then
    grep -qE '^Type=oneshot' "$_unit_file" \
        && _t_assert "A2: unit is Type=oneshot" 0 \
        || _t_assert "A2: unit is Type=oneshot" 1
    grep -qE '^User=root' "$_unit_file" && grep -qE '^Group=root' "$_unit_file" \
        && _t_assert "A3: unit runs as root:root" 0 \
        || _t_assert "A3: unit runs as root:root" 1
    grep -qE '^AmbientCapabilities=CAP_NET_ADMIN' "$_unit_file" \
        && _t_assert "A4: unit holds CAP_NET_ADMIN ambient capability" 0 \
        || _t_assert "A4: unit holds CAP_NET_ADMIN ambient capability" 1
    grep -qE '^CapabilityBoundingSet=CAP_NET_ADMIN' "$_unit_file" \
        && _t_assert "A5: unit's CapabilityBoundingSet is CAP_NET_ADMIN" 0 \
        || _t_assert "A5: unit's CapabilityBoundingSet is CAP_NET_ADMIN" 1
    grep -qE '^ExecStart=/usr/lib/nftban/bin/nftban-validate --json' "$_unit_file" \
        && _t_assert "A6: ExecStart invokes nftban-validate --json" 0 \
        || _t_assert "A6: ExecStart invokes nftban-validate --json" 1
    grep -qE '^StandardOutput=journal' "$_unit_file" \
        && _t_assert "A7: stdout goes to journal" 0 \
        || _t_assert "A7: stdout goes to journal" 1
    grep -qE '^ProtectSystem=strict' "$_unit_file" \
        && _t_assert "A8: ProtectSystem=strict hardening present" 0 \
        || _t_assert "A8: ProtectSystem=strict hardening present" 1
    grep -qE '^\[Install\]' "$_unit_file" \
        && _t_assert "A9: unit has NO [Install] section (on-demand only)" 1 "unexpected [Install] section" \
        || _t_assert "A9: unit has NO [Install] section (on-demand only)" 0

    # V130 PR-A.1 D11 fix: StartLimitIntervalSec + StartLimitBurst MUST live
    # in the [Unit] section (systemd 240+ ignores them silently in [Service]).
    # The check: in the unit file scanned line-by-line, track which section we
    # are in; record which section StartLimitIntervalSec appears in. Must be
    # "[Unit]". (PR-B D11 evidence on lab2 systemd 255 confirmed "[Service]"
    # placement was silently ignored with "Unknown key name" warning.)
    _sli_section=$(awk '
        /^\[Unit\]/      { sec="Unit"; next }
        /^\[Service\]/   { sec="Service"; next }
        /^\[Install\]/   { sec="Install"; next }
        /^StartLimitIntervalSec=/ { print sec; exit }
    ' "$_unit_file")
    if [[ "$_sli_section" == "Unit" ]]; then
        _t_assert "A10 (D11): StartLimitIntervalSec is in [Unit] section (systemd 240+ requirement)" 0
    else
        _t_assert "A10 (D11): StartLimitIntervalSec is in [Unit] section (systemd 240+ requirement)" 1 \
            "found in section: [${_sli_section:-NONE}] — systemd 240+ will ignore it silently"
    fi
    _slb_section=$(awk '
        /^\[Unit\]/      { sec="Unit"; next }
        /^\[Service\]/   { sec="Service"; next }
        /^\[Install\]/   { sec="Install"; next }
        /^StartLimitBurst=/ { print sec; exit }
    ' "$_unit_file")
    if [[ "$_slb_section" == "Unit" ]]; then
        _t_assert "A11 (D11): StartLimitBurst is in [Unit] section" 0
    else
        _t_assert "A11 (D11): StartLimitBurst is in [Unit] section" 1 \
            "found in section: [${_slb_section:-NONE}]"
    fi
fi

# ----------------------------------------------------------------------------
# B: polkit whitelist
# ----------------------------------------------------------------------------
echo "--- B: 10-nftban-systemd.rules allowedUnits[] whitelist ---"

grep -qE '"nftban-firewall-validate\.service"' "$_polkit_file" \
    && _t_assert "B1: nftban-firewall-validate.service is in allowedUnits[]" 0 \
    || _t_assert "B1: nftban-firewall-validate.service is in allowedUnits[]" 1 \
        "polkit whitelist missing entry — operators will see polkit denial"

# Negative: no new pkexec rule added (the v1.0.19 philosophy must be preserved).
# Strip comment lines (// ... or /* ... */ blocks) before grepping so the
# security philosophy comments in 10-nftban-systemd.rules don't trip the test.
_pkexec_real=$(
  for f in "${_repo_root}/packaging/polkit-1/rules.d/"*.rules; do
    [[ -f "$f" ]] || continue
    # Remove single-line // comments + lines inside /* */ blocks
    sed -e 's,//.*$,,' -e '/\/\*/,/\*\//d' "$f" | grep -E 'pkexec' || true
  done
)
if [[ -z "$_pkexec_real" ]]; then
    _t_assert "B2: no polkit rule grants pkexec privileges (v1.0.19 philosophy)" 0
else
    _t_assert "B2: no polkit rule grants pkexec privileges (v1.0.19 philosophy)" 1 \
        "new pkexec authorization found in non-comment code — violates 'NO pkexec privileges': $_pkexec_real"
fi

# Negative: no new direct nft polkit action authorization
if grep -rE 'action\.id\s*==\s*"[^"]*nft[^"]*"' "${_repo_root}/packaging/polkit-1/rules.d/" 2>/dev/null | grep -v "systemd1\|locale1\|hostname1\|timedate1" >/dev/null 2>&1; then
    _t_assert "B3: no polkit rule authorizes nft action ids directly" 1 \
        "new nft polkit action found — violates 'NO polkit authorization for nft commands'"
else
    _t_assert "B3: no polkit rule authorizes nft action ids directly" 0
fi

# ----------------------------------------------------------------------------
# C: systemd-install-list generator output includes the unit
# ----------------------------------------------------------------------------
echo "--- C: install list generator picks up the unit ---"

if [[ -f "$_install_list" ]]; then
    grep -qE '^nftban-firewall-validate\.service$' "$_install_list" \
        && _t_assert "C1: nftban-firewall-validate.service is in nftban-systemd-install.list" 0 \
        || _t_assert "C1: nftban-firewall-validate.service is in nftban-systemd-install.list" 1 \
            "run 'bash build/generate-systemd-install-list.sh' to regenerate"
else
    _t_assert "C1: install list exists" 1 "$_install_list missing — run generator"
fi

# ----------------------------------------------------------------------------
# D: CLI wrapper routes non-root via systemctl
# ----------------------------------------------------------------------------
echo "--- D: cmd_firewall.sh routing ---"

grep -qE '_route_via_systemd' "$_firewall_cli" \
    && _t_assert "D1: cmd_firewall.sh has _route_via_systemd branch" 0 \
    || _t_assert "D1: cmd_firewall.sh has _route_via_systemd branch" 1

grep -qE 'systemctl start --wait nftban-firewall-validate\.service' "$_firewall_cli" \
    && _t_assert "D2: cmd_firewall.sh calls 'systemctl start --wait nftban-firewall-validate.service'" 0 \
    || _t_assert "D2: cmd_firewall.sh calls 'systemctl start --wait nftban-firewall-validate.service'" 1

grep -qE 'EUID -ne 0' "$_firewall_cli" \
    && _t_assert "D3: cmd_firewall.sh gates the systemd route on \$EUID -ne 0" 0 \
    || _t_assert "D3: cmd_firewall.sh gates the systemd route on \$EUID -ne 0" 1

grep -qE 'journalctl -u nftban-firewall-validate\.service' "$_firewall_cli" \
    && _t_assert "D4: cmd_firewall.sh reads the validator JSON from journalctl" 0 \
    || _t_assert "D4: cmd_firewall.sh reads the validator JSON from journalctl" 1

# Fallback path: if the unit isn't installed (pre-v1.130 host), the CLI still
# falls through to direct invocation (which surfaces the D6.B Remediation).
grep -qE 'systemctl cat nftban-firewall-validate\.service' "$_firewall_cli" \
    && _t_assert "D5: cmd_firewall.sh checks unit existence (systemctl cat) before routing" 0 \
    || _t_assert "D5: cmd_firewall.sh checks unit existence (systemctl cat) before routing" 1

# V130 PR-A.1 D10 fix: journalctl read MUST retry with bounded backoff to
# survive the journald async-write race that PR-B observed on lab2 (operator
# saw rc=0 with empty stdout because the JSON hadn't flushed to journal when
# the first journalctl call ran). The retry loop is the contract: a bare
# single journalctl call would re-introduce the D10 UX bug.
_journalctl_count=$(grep -cE 'journalctl -u nftban-firewall-validate\.service' "$_firewall_cli" || echo 0)
# We expect the journalctl call to appear inside a loop. Two correct patterns:
#   for _try in ...; do journalctl ...; ...; done
#   while ...; do journalctl ...; done
# Negative pattern: a single bare journalctl call with no surrounding loop.
if grep -B2 -A3 'journalctl -u nftban-firewall-validate\.service --since' "$_firewall_cli" | grep -qE '(for[[:space:]]+[_a-zA-Z]+|while)'; then
    _t_assert "D6 (D10 fix): journalctl read is inside a retry loop (survives journald async write)" 0
else
    _t_assert "D6 (D10 fix): journalctl read is inside a retry loop (survives journald async write)" 1 \
        "bare journalctl call without retry loop — D10 UX regression"
fi

# Retry must be bounded (not infinite). Look for a numeric iteration cap.
if grep -qE 'for _try in 1 2 3' "$_firewall_cli"; then
    _t_assert "D7 (D10 fix): retry loop has bounded iterations (no infinite wait)" 0
else
    _t_assert "D7 (D10 fix): retry loop has bounded iterations (no infinite wait)" 1
fi

# Each retry iteration must sleep between attempts (otherwise we burn CPU
# and likely all 8 tries fire within journald's flush window anyway).
if grep -qE 'sleep 0?\.[0-9]' "$_firewall_cli" && \
   awk '/for _try in/,/done/' "$_firewall_cli" | grep -q 'sleep'; then
    _t_assert "D8 (D10 fix): retry loop sleeps between attempts" 0
else
    _t_assert "D8 (D10 fix): retry loop sleeps between attempts" 1
fi

# Loop exits early once output is captured (don't waste 800ms on every call).
if awk '/for _try in/,/done/' "$_firewall_cli" | grep -qE '\[\[ -n "\$?_output"? \]\] && break'; then
    _t_assert "D9 (D10 fix): retry loop short-circuits when output appears" 0
else
    _t_assert "D9 (D10 fix): retry loop short-circuits when output appears" 1
fi

# ----------------------------------------------------------------------------
# E: validator.go D6.B Remediation text is consistent with the now-real unit
# ----------------------------------------------------------------------------
echo "--- E: validator.go D6.B Remediation consistency ---"

grep -qE 'nftban-firewall-validate\.service' "$_validator_go" \
    && _t_assert "E1: validator.go Remediation references nftban-firewall-validate.service" 0 \
    || _t_assert "E1: validator.go Remediation references nftban-firewall-validate.service" 1

grep -qE 'CAP_NET_ADMIN' "$_validator_go" \
    && _t_assert "E2: validator.go Remediation mentions CAP_NET_ADMIN" 0 \
    || _t_assert "E2: validator.go Remediation mentions CAP_NET_ADMIN" 1

grep -qE '\(you must be root\)' "$_validator_go" \
    && _t_assert "E3: validator.go strips upstream '(you must be root)' wording" 0 \
    || _t_assert "E3: validator.go strips upstream '(you must be root)' wording" 1

# Negative wording: validator.go must not regress to root-first instruction.
# The only allowed occurrence of "you must be root" in EXECUTABLE Go is the
# strip call strings.ReplaceAll(errText, "(you must be root)", ""). Any other
# occurrence inside a Remediation/Message string literal would be a regression.
# Strip Go comments before grepping so explanatory comments don't trip the test.
_yumbr_lines=$(sed -e 's,//.*$,,' "$_validator_go" | grep -nE '"\(you must be root\)"' 2>/dev/null | grep -vE 'ReplaceAll' || true)
if [[ -z "$_yumbr_lines" ]]; then
    _t_assert "E4: validator.go's only executable 'you must be root' occurrence is the ReplaceAll strip pattern" 0
else
    _t_assert "E4: validator.go's only executable 'you must be root' occurrence is the ReplaceAll strip pattern" 1 \
        "non-strip occurrence found: $_yumbr_lines"
fi

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
echo
echo "==============================================================================="
echo "V130 PR-A Option C test summary"
echo "==============================================================================="
echo "  Passed:  $TESTS_PASSED"
echo "  Failed:  $TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
    echo "  Failed assertions:"
    for n in "${FAILED_NAMES[@]}"; do
        echo "    - $n"
    done
    exit 1
fi
exit 0
