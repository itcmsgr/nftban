#!/usr/bin/env bash
# =============================================================================
# V127 UX-4 Suricata de-surfacing — deterministic test fixtures
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="v127_ux4_suricata_desurfacing_test"
# meta:type="test"
# meta:version="1.127.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-24"
# meta:description="Deterministic shell tests for V127 UX-4 lane (PR-D). Asserts (a) cli/sbin/nftban no-args dashboard render block contains no Suricata row, status probe, or systemctl-suricata background call; (b) cmd_modes.sh default modes overview does not emit Suricata: status line, Suricata-naming reason text, or Suricata-naming help text; (c) nftban_help.sh essential + minimal help blocks no longer list the suricata row and the --all branch filters the suricata line from the generate-help.sh delegation; (d) v1.228.2 retirement invariants: cmd_suricata.sh exposes only status+help with a DORMANT contract and exit 2, cmd_suricata_setup.sh is an inert non-mutating tombstone, and the engine code paths (nftban_login_suricata.sh, nftban_portscan_suricata.sh, nftban_ddos_suricata.sh) remain present; (e) command-routing infrastructure (dispatcher case, completion lists, typo handler) still references suricata so nftban suricata <subcmd> remains reachable."
# meta:input="static source-file inspection via grep code-pattern assertions + functional source-and-call test for cmd_modes.sh display helpers"
# meta:output="exit 0 if all assertions pass; exit 1 with FAILED tests list otherwise"
# meta:depends="bash,grep,awk,sed"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR,NFTBAN_LOG_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="v127_ux4_suricata_desurfacing_test"
# meta:ta.owner="cli"
# meta:ta.module="cli-help-surface"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
#
# Scope: AUDIT_190_LIFECYCLE/V127_FULL_UX_CORRECTION_UMBRELLA_SCOPE.md (UX-4 lane)
# =============================================================================

set -Eeuo pipefail
# Continue past individual assertion failures so the suite reports total counts
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
_sbin_nftban="${_repo_root}/cli/sbin/nftban"
_cmd_modes="${_repo_root}/cli/lib/nftban/cli/cmd_modes.sh"
_nftban_help="${_repo_root}/cli/lib/nftban/nftban_help.sh"
_cmd_suricata="${_repo_root}/cli/lib/nftban/cli/cmd_suricata.sh"
_cmd_suricata_setup="${_repo_root}/cli/lib/nftban/cli/cmd_suricata_setup.sh"
_core_login_suricata="${_repo_root}/cli/lib/nftban/core/nftban_login_suricata.sh"
_core_portscan_suricata="${_repo_root}/cli/lib/nftban/core/nftban_portscan_suricata.sh"
_core_ddos_suricata="${_repo_root}/cli/lib/nftban/core/nftban_ddos_suricata.sh"

echo "==============================================================================="
echo "V127 UX-4 Suricata de-surfacing — deterministic test fixtures"
echo "==============================================================================="

# =============================================================================
# (A) cli/sbin/nftban no-args dashboard de-surface
# =============================================================================

# The dashboard render block sits inside the `"")` branch of the main case
# statement and runs from the "Module status (2-column ...)" marker through
# the line that prints the "nftban health" hint. Slice that out and assert
# Suricata is absent from it without false positives from other parts of the
# very large dispatcher file (which intentionally still references suricata
# as a valid subcommand for routing, completion, and typo suggestion).
_dashboard_block=$(awk '
    /Module status \(2-column/ {in_block=1}
    in_block {print}
    in_block && /Run diagnostics/ {exit}
' "$_sbin_nftban")

# A1: Dashboard render block does NOT print a "Suricata:" row label
echo "$_dashboard_block" | grep -q '"Suricata:"'
ok=$?
[[ $ok -eq 0 ]] && ok=1 || ok=0
_t_assert "A1: dashboard render block omits 'Suricata:' label" "$ok"

# A2: Dashboard render block does NOT declare a suri_st status variable
echo "$_dashboard_block" | grep -q 'suri_st='
ok=$?
[[ $ok -eq 0 ]] && ok=1 || ok=0
_t_assert "A2: dashboard render block omits 'suri_st' status variable" "$ok"

# A3: Dashboard background-probe loop does NOT call systemctl on suricata
echo "$_dashboard_block" | grep -q 'systemctl is-active.*suricata'
ok=$?
[[ $ok -eq 0 ]] && ok=1 || ok=0
_t_assert "A3: dashboard background probe omits systemctl is-active suricata" "$ok"

# A4: Dashboard render block does NOT contain the suri_nftban/suri_native temp files
echo "$_dashboard_block" | grep -q 'suri_nftban\|suri_native'
ok=$?
[[ $ok -eq 0 ]] && ok=1 || ok=0
_t_assert "A4: dashboard render block omits suri_nftban/suri_native probe files" "$ok"

# A5: V127 UX-4 anchor comment present in dashboard render block (traceability)
echo "$_dashboard_block" | grep -q 'V127 UX-4'
ok=$?
_t_assert "A5: dashboard render block carries V127 UX-4 scope anchor comment" "$ok"

# A6: Dispatcher routing still references suricata as a known nftban-core command
# (this is OUT of scope for de-surfacing and MUST remain so `nftban suricata`
# subcommands continue to route)
grep -qE 'init\|sync\|check\|.*\|suricata\|' "$_sbin_nftban"
ok=$?
_t_assert "A6: dispatcher case still routes 'suricata' to nftban-core (NOT touched)" "$ok"

# A7: Completion / suggestion infrastructure still mentions suricata
# (out of scope for UX-4; must remain)
_total_suricata_refs=$(grep -c -i 'suricata' "$_sbin_nftban" || true)
[[ "$_total_suricata_refs" -ge 4 ]]
ok=$?
_t_assert "A7: cli/sbin/nftban still references suricata $_total_suricata_refs times in command infra (>=4)" "$ok"

# =============================================================================
# (B) cli/lib/nftban/cli/cmd_modes.sh default overview + reason text
# =============================================================================

# B1: Source no longer contains the "Suricata: ${suricata_status_str} | EVE: ..." display line
grep -qE 'echo "Suricata: \$\{suricata_status_str\}' "$_cmd_modes"
ok=$?
[[ $ok -eq 0 ]] && ok=1 || ok=0
_t_assert "B1: cmd_modes.sh source omits 'Suricata: \${suricata_status_str}' display line" "$ok"

# B2: Source no longer declares the suricata_status_str variable (used only by removed line)
grep -q 'local suricata_status_str' "$_cmd_modes"
ok=$?
[[ $ok -eq 0 ]] && ok=1 || ok=0
_t_assert "B2: cmd_modes.sh source omits 'local suricata_status_str' variable" "$ok"

# B3: Source no longer emits the legacy reason "Suricata detected"
grep -qE 'echo "Suricata detected"' "$_cmd_modes"
ok=$?
[[ $ok -eq 0 ]] && ok=1 || ok=0
_t_assert "B3: cmd_modes.sh source omits 'Suricata detected' reason string" "$ok"

# B4: Source no longer emits the legacy reason "No Suricata config"
grep -qE 'echo "No Suricata config"' "$_cmd_modes"
ok=$?
[[ $ok -eq 0 ]] && ok=1 || ok=0
_t_assert "B4: cmd_modes.sh source omits 'No Suricata config' reason string" "$ok"

# B5: Neutral replacement reason strings present (covers _modes_get_reason auto branch)
grep -qE 'echo "Auto-resolved \(advanced\)"' "$_cmd_modes"
ok=$?
_t_assert "B5: cmd_modes.sh emits neutral 'Auto-resolved (advanced)' reason" "$ok"

grep -qE 'echo "Auto-resolved \(classic\)"' "$_cmd_modes"
ok=$?
_t_assert "B5b: cmd_modes.sh emits neutral 'Auto-resolved (classic)' reason" "$ok"

# B6: _modes_help text no longer contains "Suricata IDS"
grep -q 'Suricata IDS' "$_cmd_modes"
ok=$?
[[ $ok -eq 0 ]] && ok=1 || ok=0
_t_assert "B6: cmd_modes.sh _modes_help omits 'Suricata IDS' wording" "$ok"

# B7: _modes_help text no longer says "Use Suricata"
grep -q 'Use Suricata' "$_cmd_modes"
ok=$?
[[ $ok -eq 0 ]] && ok=1 || ok=0
_t_assert "B7: cmd_modes.sh _modes_help omits 'Use Suricata' wording" "$ok"

# B8: _modes_help body no longer references "Suricata availability" in operator-facing text.
# (An internal-source-comment that uses the phrase outside the help-text body is OUT of
# scope per UX-4 "operator-facing" framing; the assertion is narrowed to the _modes_help
# function body only via awk slice.)
awk '/^_modes_help\(\) \{/,/^\}$/' "$_cmd_modes" | grep -q 'Suricata availability'
ok=$?
[[ $ok -eq 0 ]] && ok=1 || ok=0
_t_assert "B8: cmd_modes.sh _modes_help body omits 'Suricata availability' wording" "$ok"

# B9: SEE ALSO no longer lists `nftban suricata status`
grep -qE 'nftban suricata status' "$_cmd_modes"
ok=$?
[[ $ok -eq 0 ]] && ok=1 || ok=0
_t_assert "B9: cmd_modes.sh SEE ALSO omits 'nftban suricata status' line" "$ok"

# B10: V127 UX-4 anchor comment present in cmd_modes.sh (traceability)
grep -q 'V127 UX-4' "$_cmd_modes"
ok=$?
_t_assert "B10: cmd_modes.sh carries V127 UX-4 scope anchor comment" "$ok"

# B11: _modes_suricata_is_running internal detection function STILL present
# (it feeds _modes_resolve_effective and --json output; UX-4 is display-only)
grep -q '_modes_suricata_is_running()' "$_cmd_modes"
ok=$?
_t_assert "B11: cmd_modes.sh internal _modes_suricata_is_running detection preserved" "$ok"

# B12: --json output path still emits suricata.running / eve.* keys
# (machine consumers must see no wire-format regression per V127 UX-4 scope)
grep -q '"suricata":' "$_cmd_modes" && grep -q '"running":' "$_cmd_modes"
ok=$?
_t_assert "B12: cmd_modes.sh --json output still emits suricata.running key" "$ok"

# =============================================================================
# (C) cli/lib/nftban/nftban_help.sh essential + minimal help blocks
# =============================================================================

# C1: _nftban_help_essential heredoc does NOT include the "suricata" row
awk '/_nftban_help_essential\(\)/,/^EOF$/' "$_nftban_help" | grep -q '^  suricata'
ok=$?
[[ $ok -eq 0 ]] && ok=1 || ok=0
_t_assert "C1: _nftban_help_essential omits 'suricata' module row" "$ok"

# C2: _nftban_help_minimal heredoc does NOT include the "suricata" row
awk '/_nftban_help_minimal\(\)/,/^EOF$/' "$_nftban_help" | grep -q '^  suricata'
ok=$?
[[ $ok -eq 0 ]] && ok=1 || ok=0
_t_assert "C2: _nftban_help_minimal omits 'suricata' module row" "$ok"

# C3: --all branch pipes generate-help.sh output through suricata filter
grep -qE "grep -v -E '\^\[\[:space:\]\]\+suricata\[\[:space:\]\]'" "$_nftban_help"
ok=$?
_t_assert "C3: nftban_help.sh --all branch filters suricata from generate-help output" "$ok"

# C4: V127 UX-4 anchor comment present in nftban_help.sh
grep -q 'V127 UX-4' "$_nftban_help"
ok=$?
_t_assert "C4: nftban_help.sh carries V127 UX-4 scope anchor comment" "$ok"

# =============================================================================
# (D) Production Suricata code paths UNTOUCHED (sentinel-grep)
# =============================================================================

# -----------------------------------------------------------------------------
# D1/D2 REWRITTEN v1.228.2 (owner ruling D1-D4) — justification.
#
# The original D1/D2 were SENTINEL-GREP scope guards: UX-4 was a display-only
# de-surfacing lane, so they asserted that the production Suricata code paths
# were "untouched" by that PR. They pinned the pre-v1.228.2 surface as a side
# effect of pinning UX-4's blast radius.
#
# v1.228.2 retires Suricata from the ACTIVE product surface: `nftban suricata`
# is narrowed to `help` + `status`, and install/enable/disable are removed
# because a dormant placeholder must not mutate the host. Asserting the old
# entry points still exist would now assert the exact surface the ruling
# deleted, so the two assertions are re-aimed at what UX-4 actually cares
# about — that `nftban suricata <subcmd>` still ROUTES (A6/A7 above) and that
# the retired module is inert — rather than deleted outright.
#
# D3-D5 below are UNCHANGED: the loginmon/portscan/ddos engine code is not in
# scope for the retirement and must still be present.
# -----------------------------------------------------------------------------

# D1: cmd_suricata.sh present and still defines its top-level command function
[[ -f "$_cmd_suricata" ]] && grep -qE 'cmd_suricata|nftban_cmd_suricata' "$_cmd_suricata"
ok=$?
_t_assert "D1: cmd_suricata.sh present with command entry point" "$ok"

# D1b: the narrowed surface routes ONLY status + help (no install/enable/disable)
awk '/^nftban_cmd_suricata\(\) \{/,/^\}$/' "$_cmd_suricata" \
    | grep -qE '^[[:space:]]+(install|enable|disable|rules|update|sid|category|profile)\)'
ok=$?
[[ $ok -eq 0 ]] && ok=1 || ok=0
_t_assert "D1b: cmd_suricata.sh router has no install/enable/disable/rules/update/sid/category/profile arm" "$ok"

# D1c: status reports the dormant contract and a stable machine token
grep -q 'DORMANT / NOT IMPLEMENTED' "$_cmd_suricata" \
    && grep -q 'NFTBAN_SURICATA_STATE=DORMANT' "$_cmd_suricata" \
    && grep -q 'NFTBAN_SURICATA_DORMANT_EXIT=2' "$_cmd_suricata"
ok=$?
_t_assert "D1c: cmd_suricata.sh status reports DORMANT + stable token + non-zero exit 2" "$ok"

# D2: cmd_suricata_setup.sh is an inert tombstone — present, but defining no
# command function. Deletion is hard-locked by shell-delete-guard CHECK 3
# (NO-DROP-RUNTIME-DIRS-CODE), so the file stays and the behaviour goes.
[[ -f "$_cmd_suricata_setup" ]] && ! grep -qE '^cmd_suricata_[a-z]+\(\)' "$_cmd_suricata_setup"
ok=$?
_t_assert "D2: cmd_suricata_setup.sh is an inert tombstone (defines no cmd_suricata_* function)" "$ok"

# D2b: the tombstone performs no host mutation
grep -qE '^[[:space:]]*(systemctl|usermod|chown|chmod|sed -i|install -D|pip3|dnf|apt-get)[[:space:]]' "$_cmd_suricata_setup"
ok=$?
[[ $ok -eq 0 ]] && ok=1 || ok=0
_t_assert "D2b: cmd_suricata_setup.sh tombstone issues no host-mutating command" "$ok"

# D3: nftban_login_suricata.sh present and non-empty
[[ -f "$_core_login_suricata" ]] && [[ -s "$_core_login_suricata" ]]
ok=$?
_t_assert "D3: nftban_login_suricata.sh present and non-empty (engine code untouched)" "$ok"

# D4: nftban_portscan_suricata.sh present and non-empty
[[ -f "$_core_portscan_suricata" ]] && [[ -s "$_core_portscan_suricata" ]]
ok=$?
_t_assert "D4: nftban_portscan_suricata.sh present and non-empty (engine code untouched)" "$ok"

# D5: nftban_ddos_suricata.sh present and non-empty
[[ -f "$_core_ddos_suricata" ]] && [[ -s "$_core_ddos_suricata" ]]
ok=$?
_t_assert "D5: nftban_ddos_suricata.sh present and non-empty (engine code untouched)" "$ok"

# =============================================================================
# (E) Scope-creep guard — no UX-5 (typo) or UX-6 (broad help) work here
# =============================================================================

# E1 REMOVED (v1.226.0 PR-D): the UX-5 Damerau-Levenshtein typo-suggestion feature
# legitimately shipped to cli/sbin/nftban as its own lane. E1 was only a cross-PR
# scope-guard to keep UX-5 out of the UX-4 PR; both merged to trunk long ago, so the
# guard now fires on intended trunk state. Disposition FALSE_OR_OBSOLETE_TEST. The 29
# substantive suricata-desurfacing assertions (A1-A7, B1-B12, C1-C4, D1-D5, E2) remain.

# E2: No alias-relationship help rewrite (UX-6 territory)
for f in "$_sbin_nftban" "$_cmd_modes" "$_nftban_help"; do
    if grep -qE 'alias for `firewall' "$f"; then
        _t_assert "E2: scope-creep: alias-for help rewrite found in $(basename "$f")" 1
        E2_FAIL=1
        break
    fi
done
[[ -z "${E2_FAIL:-}" ]] && _t_assert "E2: no alias-for help rewrite (UX-6 not touched)" 0

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "==============================================================================="
echo "V127 UX-4 test summary: ${TESTS_PASSED} PASS, ${TESTS_FAILED} FAIL"
echo "==============================================================================="
if [[ "$TESTS_FAILED" -gt 0 ]]; then
    echo "Failed tests:"
    for name in "${FAILED_NAMES[@]}"; do
        echo "  - $name"
    done
    exit 1
fi
exit 0
