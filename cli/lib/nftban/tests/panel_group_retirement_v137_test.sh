#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.137 nftban-panel authorization GROUP retirement
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="panel_group_retirement_v137_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-27"
# meta:description="v1.137 regression. Asserts the nftban-panel authorization tier is fully retired: the FHS spec no longer declares the group; build_nftban.sh no longer groupadds nftban-panel, installs 30-nftban-panel.rules, or ships the nftban-panelctl wrapper; deb/postinst no longer creates the group; payload.go has no nftban-panelctl entry and assertions.go no nftban-panelctl required-file; users/ensure.go no longer ensures the group; the health check no longer WARNs/degrades on a missing panel rule and health-fix no longer recreates it; cmd_polkit.sh dropped the panel group/rule; the 30-nftban-panel.rules polkit file is gone while the 10-/20- rules survive with the auditor read-only denials intact. GREP-GUARD: no live nftban-panel reference remains in cli/ cmd/ internal/ packaging/ install/ .github/ except explanatory retirement comments + the preserved hosting-panel-survival prose in flags.go. PRESERVE-guard: cmd_panel.sh + --panel-auto-takeover/--no-panel (hosting-panel TAKEOVER subsystem) untouched. Static repo greps only; no host contact; no root required."
# meta:input="None (reads repo source files; self-contained)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,grep,sed"
# meta:inventory.files="build/fhs-spec.yaml,packaging/build_nftban.sh,packaging/deb/postinst,internal/installer/payload/payload.go,internal/installer/validate/assertions.go,internal/installer/users/ensure.go,cli/lib/nftban/core/nftban_health_checks_security.sh,cli/lib/nftban/core/nftban_health_fixes.sh,cli/lib/nftban/cli/cmd_polkit.sh,packaging/polkit-1/rules.d/10-nftban-systemd.rules,packaging/polkit-1/rules.d/20-nftban-auditor.rules,install/systemd/sysusers.d/nftban.conf,.github/workflows/ci-runtime-truth.yml,cmd/nftban-installer/flags.go,cli/lib/nftban/cli/cmd_panel.sh"
# meta:inventory.binaries="bash,grep,sed"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="panel_group_retirement_v137_test"
# meta:ta.owner="security"
# meta:ta.module="panel-group-retirement"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
# Lane:    v1.137 PR — nftban-panel authorization GROUP retirement
# Gate:    OPEN_V1_137_BLOCKER_PANEL_GROUP_RETIREMENT
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)

FHS_SPEC="${REPO_ROOT}/build/fhs-spec.yaml"
BUILD="${REPO_ROOT}/packaging/build_nftban.sh"
POSTINST="${REPO_ROOT}/packaging/deb/postinst"
PAYLOAD_GO="${REPO_ROOT}/internal/installer/payload/payload.go"
ASSERT_GO="${REPO_ROOT}/internal/installer/validate/assertions.go"
ENSURE_GO="${REPO_ROOT}/internal/installer/users/ensure.go"
HEALTH_CHECK="${REPO_ROOT}/cli/lib/nftban/core/nftban_health_checks_security.sh"
HEALTH_FIX="${REPO_ROOT}/cli/lib/nftban/core/nftban_health_fixes.sh"
CMD_POLKIT="${REPO_ROOT}/cli/lib/nftban/cli/cmd_polkit.sh"
RULE_10="${REPO_ROOT}/packaging/polkit-1/rules.d/10-nftban-systemd.rules"
RULE_20="${REPO_ROOT}/packaging/polkit-1/rules.d/20-nftban-auditor.rules"
RULE_30="${REPO_ROOT}/packaging/polkit-1/rules.d/30-nftban-panel.rules"
SYSUSERS="${REPO_ROOT}/install/systemd/sysusers.d/nftban.conf"
CI_RUNTIME="${REPO_ROOT}/.github/workflows/ci-runtime-truth.yml"
FLAGS_GO="${REPO_ROOT}/cmd/nftban-installer/flags.go"
CMD_PANEL="${REPO_ROOT}/cli/lib/nftban/cli/cmd_panel.sh"

PASS=0; FAIL=0; SKIP=0; FAILED_TESTS=()
ok(){ printf "  [PASS] %s\n" "$1"; PASS=$((PASS+1)); }
no(){ printf "  [FAIL] %s (%s)\n" "$1" "$2"; FAIL=$((FAIL+1)); FAILED_TESTS+=("$1"); }
sk(){ printf "  [SKIP] %s (%s)\n" "$1" "$2"; SKIP=$((SKIP+1)); }

echo "=========================================================="
echo "V1.137 nftban-panel authorization GROUP retirement test"
echo "=========================================================="

# ---------------------------------------------------------------------------
echo "--- fhs-spec.yaml: no nftban-panel group entry ---"
# ---------------------------------------------------------------------------
if grep -Eq '^[[:space:]]*-?[[:space:]]*name:[[:space:]]*nftban-panel\b' "$FHS_SPEC"; then
    no "fhs_no_panel_group" "fhs-spec.yaml still declares a nftban-panel group entry"
else
    ok "fhs_no_panel_group"
fi
grep -q 'name: nftban' "$FHS_SPEC" && ok "fhs_keeps_nftban_group" || no "fhs_keeps_nftban_group" "nftban group missing from fhs-spec.yaml"
grep -q 'name: nftban-auditor' "$FHS_SPEC" && ok "fhs_keeps_auditor_group" || no "fhs_keeps_auditor_group" "nftban-auditor group missing from fhs-spec.yaml"

# ---------------------------------------------------------------------------
echo "--- build_nftban.sh: no panel groupadd/rule-install/panelctl ---"
# ---------------------------------------------------------------------------
grep -q 'groupadd -r nftban-panel' "$BUILD" && no "build_no_panel_groupadd" "groupadd -r nftban-panel still present" || ok "build_no_panel_groupadd"
grep -q '30-nftban-panel.rules' "$BUILD" && no "build_no_panel_rule_install" "30-nftban-panel.rules still referenced in build" || ok "build_no_panel_rule_install"
grep -q 'nftban-panelctl' "$BUILD" && no "build_no_panelctl" "nftban-panelctl still referenced in build" || ok "build_no_panelctl"
# surviving groups + rules must stay
grep -q 'groupadd -r nftban-auditor' "$BUILD" && ok "build_keeps_auditor_groupadd" || no "build_keeps_auditor_groupadd" "nftban-auditor groupadd removed"
grep -q '10-nftban-systemd.rules' "$BUILD" && ok "build_keeps_10_rule" || no "build_keeps_10_rule" "10-nftban-systemd.rules install removed"
grep -q '20-nftban-auditor.rules' "$BUILD" && ok "build_keeps_20_rule" || no "build_keeps_20_rule" "20-nftban-auditor.rules install removed"

# ---------------------------------------------------------------------------
echo "--- deb/postinst: no nftban-panel group create ---"
# ---------------------------------------------------------------------------
grep -q 'nftban-panel' "$POSTINST" && no "postinst_no_panel_group" "deb/postinst still creates nftban-panel" || ok "postinst_no_panel_group"
grep -q 'addgroup --system nftban-auditor' "$POSTINST" && ok "postinst_keeps_auditor" || no "postinst_keeps_auditor" "nftban-auditor group create removed from postinst"

# ---------------------------------------------------------------------------
echo "--- Go: payload.go + assertions.go + users/ensure.go ---"
# ---------------------------------------------------------------------------
grep -q 'nftban-panelctl' "$PAYLOAD_GO" && no "payload_no_panelctl" "payload.go still ships nftban-panelctl" || ok "payload_no_panelctl"
grep -q 'nftban-panelctl' "$ASSERT_GO" && no "assert_no_panelctl" "assertions.go still requires nftban-panelctl" || ok "assert_no_panelctl"
# ensured-groups list
grep -q '"nftban-panel"' "$ENSURE_GO" && no "ensure_no_panel_group" "users/ensure.go still ensures nftban-panel" || ok "ensure_no_panel_group"
grep -q '"nftban"' "$ENSURE_GO" && ok "ensure_keeps_nftban" || no "ensure_keeps_nftban" "users/ensure.go dropped nftban group"
grep -q '"nftban-auditor"' "$ENSURE_GO" && ok "ensure_keeps_auditor" || no "ensure_keeps_auditor" "users/ensure.go dropped nftban-auditor group"

# ---------------------------------------------------------------------------
echo "--- health: no panel-rule WARN/degrade; no self-heal recreation ---"
# ---------------------------------------------------------------------------
# The retired security check must no longer treat a missing panel rule as a
# WARNING/DEGRADED condition. We assert there is no live code path that builds a
# polkit_panel_rules path and emits a WARNING on its absence.
if grep -q 'polkit_panel_rules' "$HEALTH_CHECK"; then
    no "healthcheck_no_panel_warn" "security health check still has a polkit_panel_rules WARN/degrade path"
else
    ok "healthcheck_no_panel_warn"
fi
# auditor presence check must remain
grep -q '20-nftban-auditor.rules' "$HEALTH_CHECK" && ok "healthcheck_keeps_auditor_rule" || no "healthcheck_keeps_auditor_rule" "auditor-rule presence check removed"
# health-fix self-heal rule_files list must not recreate the panel rule. The
# only acceptable mention is the explanatory retirement comment.
if grep '30-nftban-panel.rules' "$HEALTH_FIX" | grep -vqE 'retired|RETIRED|two-tier'; then
    no "healthfix_no_panel_recreate" "health-fix still references 30-nftban-panel.rules in a non-comment context"
else
    ok "healthfix_no_panel_recreate"
fi
# surviving rule recreation must stay
grep -q '10-nftban-systemd.rules' "$HEALTH_FIX" && ok "healthfix_keeps_10" || no "healthfix_keeps_10" "health-fix dropped 10-nftban-systemd.rules"
grep -q '20-nftban-auditor.rules' "$HEALTH_FIX" && ok "healthfix_keeps_20" || no "healthfix_keeps_20" "health-fix dropped 20-nftban-auditor.rules"

# ---------------------------------------------------------------------------
echo "--- cmd_polkit.sh: no panel group; auditor preserved ---"
# ---------------------------------------------------------------------------
grep -q 'nftban-panel' "$CMD_POLKIT" && no "cmd_polkit_no_panel" "cmd_polkit.sh still references nftban-panel" || ok "cmd_polkit_no_panel"
grep -q '30-nftban-panel.rules' "$CMD_POLKIT" && no "cmd_polkit_no_panel_rule" "cmd_polkit.sh still references 30-nftban-panel.rules" || ok "cmd_polkit_no_panel_rule"
grep -q 'nftban-auditor' "$CMD_POLKIT" && ok "cmd_polkit_keeps_auditor" || no "cmd_polkit_keeps_auditor" "cmd_polkit.sh dropped nftban-auditor"

# ---------------------------------------------------------------------------
echo "--- polkit rule files: 30- gone; 10-/20- present + auditor denials ---"
# ---------------------------------------------------------------------------
[[ ! -e "$RULE_30" ]] && ok "rule30_absent" || no "rule30_absent" "30-nftban-panel.rules still exists on disk"
[[ -f "$RULE_10" ]] && ok "rule10_present" || no "rule10_present" "10-nftban-systemd.rules missing"
[[ -f "$RULE_20" ]] && ok "rule20_present" || no "rule20_present" "20-nftban-auditor.rules missing"
# auditor read-only denials (start/stop/restart denied) must still be in 20-rule
if [[ -f "$RULE_20" ]]; then
    if grep -qE '"start"|"stop"|"restart"' "$RULE_20" && grep -q 'Result\.NO' "$RULE_20"; then
        ok "rule20_keeps_readonly_denials"
    else
        no "rule20_keeps_readonly_denials" "20-nftban-auditor.rules lost its start/stop/restart denial(s)"
    fi
else
    no "rule20_keeps_readonly_denials" "20-nftban-auditor.rules missing"
fi

# ---------------------------------------------------------------------------
echo "--- sysusers.d + CI: no panel group create/require ---"
# ---------------------------------------------------------------------------
grep -qE '^g[[:space:]]+nftban-panel\b' "$SYSUSERS" && no "sysusers_no_panel" "sysusers.d still creates g nftban-panel" || ok "sysusers_no_panel"
grep -qE '^g[[:space:]]+nftban\b' "$SYSUSERS" && ok "sysusers_keeps_nftban" || no "sysusers_keeps_nftban" "sysusers.d dropped nftban group"
grep -qE '^g[[:space:]]+nftban-auditor\b' "$SYSUSERS" && ok "sysusers_keeps_auditor" || no "sysusers_keeps_auditor" "sysusers.d dropped nftban-auditor group"
# CI runtime-truth: positive identity asserts present; no panel REQUIRE
grep -q 'getent passwd nftban' "$CI_RUNTIME" && ok "ci_asserts_nftban_user" || no "ci_asserts_nftban_user" "CI lacks nftban user assertion"
grep -q 'getent group nftban-auditor' "$CI_RUNTIME" && ok "ci_asserts_auditor_group" || no "ci_asserts_auditor_group" "CI lacks nftban-auditor group assertion"
# the only acceptable nftban-panel mention in CI is the retirement comment
if grep 'nftban-panel' "$CI_RUNTIME" | grep -vqE 'RETIRED|retired|two-tier'; then
    no "ci_no_panel_require" "CI still has a non-comment nftban-panel reference"
else
    ok "ci_no_panel_require"
fi

# ---------------------------------------------------------------------------
echo "--- GREP-GUARD: no live nftban-panel ref in code/config trees ---"
# ---------------------------------------------------------------------------
# Allowed exceptions:
#   (a) explanatory retirement comments we added (match retired/RETIRED/two-tier)
#   (b) the preserved hosting-panel-SURVIVAL prose in cmd/nftban-installer/flags.go
#       ("nftban-panel integration ... panel managed externally") — a DIFFERENT
#       subsystem (--no-panel / cmd_panel.sh) that must stay 100% untouched.
guard_hits=$(grep -rn 'nftban-panel' \
    "${REPO_ROOT}/cli" "${REPO_ROOT}/cmd" "${REPO_ROOT}/internal" \
    "${REPO_ROOT}/packaging" "${REPO_ROOT}/install" "${REPO_ROOT}/.github" \
    2>/dev/null | grep -v '\.md:' || true)
unexpected=$(printf '%s\n' "$guard_hits" \
    | grep -v '^$' \
    | grep -vF 'panel_group_retirement_v137_test.sh:' \
    | grep -vE 'retired|RETIRED|two-tier' \
    | grep -vE 'flags\.go:[0-9]+:[[:space:]]*//[[:space:]]*nftban-panel integration' \
    || true)
if [[ -z "$unexpected" ]]; then
    ok "grep_guard_no_live_panel_ref"
else
    no "grep_guard_no_live_panel_ref" "unexpected live nftban-panel reference(s) below"
    printf '%s\n' "$unexpected" | sed 's/^/        /'
fi

# ---------------------------------------------------------------------------
echo "--- PRESERVE-guard: hosting-panel TAKEOVER subsystem untouched ---"
# ---------------------------------------------------------------------------
[[ -f "$CMD_PANEL" ]] && ok "preserve_cmd_panel_exists" || no "preserve_cmd_panel_exists" "cmd_panel.sh missing (hosting-panel takeover subsystem)"
grep -q 'panel-auto-takeover' "$FLAGS_GO" && ok "preserve_panel_auto_takeover" || no "preserve_panel_auto_takeover" "--panel-auto-takeover removed from flags.go"
grep -q 'no-panel' "$FLAGS_GO" && ok "preserve_no_panel_flag" || no "preserve_no_panel_flag" "--no-panel removed from flags.go"

# ---------------------------------------------------------------------------
echo "=========================================================="
echo "RESULTS: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
if [[ $FAIL -gt 0 ]]; then
    echo "FAILED:"
    for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
    echo "=========================================================="
    exit 1
fi
echo "=========================================================="
exit 0
