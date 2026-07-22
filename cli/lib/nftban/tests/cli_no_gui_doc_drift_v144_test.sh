#!/usr/bin/env bash
# =============================================================================
# NFTBan - no GUI doc drift test (v1.144.0 PR-A)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cli_no_gui_doc_drift_v144_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-01"
# meta:description="v1.144.0 PR-A — asserts D-NFTBAN-GUI-DOC-DRIFT + FHS-SPEC-GUI-MENTION are closed. (1) commands.registry.yml has no top-level `gui:` entry and no `gui` row in `missing_json:`. (2) build/fhs-spec.yaml has no `gui:` feature block and no 'GUI/API' description. (3) cli/lib/nftban/core/nftban_fhs_spec.sh — regenerated from (2) — contains 'TLS certificates for API' (not 'GUI/API') and no /etc/nftban/gui directory entry. (4) `nftban gui` dispatch through cli/sbin/nftban falls through to the 'Unknown command' catch-all (verified by absence of dispatch case AND absence of alias). Hermetic — no host contact; no daemon, no nft. Closes the operator-visible UX confusion surfaced by the v1.142.0 fleet rollout (V1_142_0_FLEET_ROLLOUT_RECORD.md §3.2)."
# meta:input="commands.registry.yml, build/fhs-spec.yaml, cli/lib/nftban/core/nftban_fhs_spec.sh, cli/sbin/nftban"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep"
# meta:inventory.files="commands.registry.yml,build/fhs-spec.yaml,cli/lib/nftban/core/nftban_fhs_spec.sh,cli/sbin/nftban"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="cli_no_gui_doc_drift_v144_test"
# meta:ta.owner="cli"
# meta:ta.module="command-registry-drift"
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

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../../../.." && pwd)

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s (%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

# ──────────────────────────────────────────────────────────────────────────
# Section 1: commands.registry.yml — help-output source-of-truth
# ──────────────────────────────────────────────────────────────────────────
REG="$REPO/commands.registry.yml"
[[ -f "$REG" ]] || { echo "FAIL: missing $REG"; exit 1; }

# T1-1: no top-level 'gui:' entry in the registry. The registry is YAML and
# the top-level entries are at column 0; comments starting with '#' are
# allowed (and used to record the retirement reason).
if grep -nE '^gui:' "$REG" >/dev/null 2>&1; then
    no "T1-1: commands.registry.yml has no top-level 'gui:' entry" \
       "$(grep -nE '^gui:' "$REG" | head -1)"
else
    ok "T1-1: commands.registry.yml has no top-level 'gui:' entry"
fi

# T1-2: no 'nftban gui ...' invocation examples remain
if grep -nE '"nftban gui ' "$REG" >/dev/null 2>&1; then
    no "T1-2: commands.registry.yml has no 'nftban gui' example strings" \
       "$(grep -nE '"nftban gui ' "$REG" | head -1)"
else
    ok "T1-2: commands.registry.yml has no 'nftban gui' example strings"
fi

# T1-3: 'gui' removed from the metadata 'missing_json:' list. The retirement
# comment is allowed; only a bare list-item line '    - gui' is forbidden.
if grep -nE '^[[:space:]]+- gui$' "$REG" >/dev/null 2>&1; then
    no "T1-3: commands.registry.yml 'missing_json:' has no '- gui' item" \
       "$(grep -nE '^[[:space:]]+- gui$' "$REG" | head -1)"
else
    ok "T1-3: commands.registry.yml 'missing_json:' has no '- gui' item"
fi

# T1-4: total_commands counter is one lower than it was before the retirement
# (66, not 67) — guards against silent re-introduction by a future PR that
# adds 'gui' back without bumping the counter.
if grep -nE '^[[:space:]]+total_commands:[[:space:]]+66\b' "$REG" >/dev/null 2>&1; then
    ok "T1-4: total_commands = 66 (reflects gui retirement)"
else
    no "T1-4: total_commands = 66 (reflects gui retirement)" \
       "$(grep -nE 'total_commands:' "$REG" | head -1 || echo 'absent')"
fi

# ──────────────────────────────────────────────────────────────────────────
# Section 2: build/fhs-spec.yaml — FHS spec source-of-truth
# ──────────────────────────────────────────────────────────────────────────
FHS_SRC="$REPO/build/fhs-spec.yaml"
[[ -f "$FHS_SRC" ]] || { echo "FAIL: missing $FHS_SRC"; exit 1; }

# T2-1: SSL directory description should say "TLS certificates for API"
# (NOT "TLS certificates for GUI/API"). Permits the leading comment block
# at the top of fhs-spec.yaml which has historical text about GUI retirement.
if grep -nE 'description: "TLS certificates for API"' "$FHS_SRC" >/dev/null 2>&1; then
    ok "T2-1: build/fhs-spec.yaml SSL description = 'TLS certificates for API'"
else
    no "T2-1: build/fhs-spec.yaml SSL description = 'TLS certificates for API'" \
       "$(grep -nE 'description.*TLS certificates' "$FHS_SRC" | head -1 || echo 'absent')"
fi

# T2-2: no 'TLS certificates for GUI/API' string remains
if grep -nE 'TLS certificates for GUI/API' "$FHS_SRC" >/dev/null 2>&1; then
    no "T2-2: build/fhs-spec.yaml has no 'TLS certificates for GUI/API'" \
       "$(grep -nE 'TLS certificates for GUI/API' "$FHS_SRC" | head -1)"
else
    ok "T2-2: build/fhs-spec.yaml has no 'TLS certificates for GUI/API'"
fi

# T2-3: no `gui:` feature block (under feature_directories.gui:). The block
# would manifest as a 2-space-indented 'gui:' line followed by an indented
# 'condition: "gui_enabled"' line. Match the conjunction to avoid false
# positives on any unrelated 'gui:' that might exist elsewhere.
if grep -nE '^[[:space:]]{2}gui:' "$FHS_SRC" >/dev/null 2>&1; then
    no "T2-3: build/fhs-spec.yaml has no 'gui:' feature block" \
       "$(grep -nE '^[[:space:]]{2}gui:' "$FHS_SRC" | head -1)"
else
    ok "T2-3: build/fhs-spec.yaml has no 'gui:' feature block"
fi

# T2-4: no 'gui_enabled' condition string
if grep -nE 'gui_enabled' "$FHS_SRC" >/dev/null 2>&1; then
    no "T2-4: build/fhs-spec.yaml has no 'gui_enabled' condition" \
       "$(grep -nE 'gui_enabled' "$FHS_SRC" | head -1)"
else
    ok "T2-4: build/fhs-spec.yaml has no 'gui_enabled' condition"
fi

# T2-5: no '/etc/nftban/gui' YAML path entry. Retirement-rationale COMMENT
# lines (prefixed with `#`) are allowed; only a non-comment yaml line
# containing the path is forbidden. Standard hermetic-test convention
# (matches T3-2 / T3-3 / T2-3 same-file semantics).
if grep -nE '/etc/nftban/gui' "$FHS_SRC" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' >/dev/null 2>&1; then
    no "T2-5: build/fhs-spec.yaml has no '/etc/nftban/gui' path (non-comment)" \
       "$(grep -nE '/etc/nftban/gui' "$FHS_SRC" | grep -vE '^[0-9]+:[[:space:]]*#' | head -1)"
else
    ok "T2-5: build/fhs-spec.yaml has no '/etc/nftban/gui' path (non-comment)"
fi

# ──────────────────────────────────────────────────────────────────────────
# Section 3: cli/lib/nftban/core/nftban_fhs_spec.sh — regenerated output
# ──────────────────────────────────────────────────────────────────────────
FHS_OUT="$REPO/cli/lib/nftban/core/nftban_fhs_spec.sh"
[[ -f "$FHS_OUT" ]] || { echo "FAIL: missing $FHS_OUT"; exit 1; }

# T3-1: regenerated description reflects source edit
if grep -nE 'TLS certificates for API' "$FHS_OUT" >/dev/null 2>&1; then
    ok "T3-1: nftban_fhs_spec.sh contains 'TLS certificates for API'"
else
    no "T3-1: nftban_fhs_spec.sh contains 'TLS certificates for API'" \
       "$(grep -nE 'TLS certificates' "$FHS_OUT" | head -1 || echo 'absent')"
fi

# T3-2: no 'GUI/API' string in the regenerated output (the lines 30-31
# historical comment block uses 'GOTH GUI' / 'GUI is display-only' but never
# the 'GUI/API' compound — those are different strings and harmless context).
if grep -nE 'GUI/API' "$FHS_OUT" >/dev/null 2>&1; then
    no "T3-2: nftban_fhs_spec.sh has no 'GUI/API' compound string" \
       "$(grep -nE 'GUI/API' "$FHS_OUT" | head -1)"
else
    ok "T3-2: nftban_fhs_spec.sh has no 'GUI/API' compound string"
fi

# T3-3: no /etc/nftban/gui directory entry in the generated output
if grep -nE '/etc/nftban/gui' "$FHS_OUT" >/dev/null 2>&1; then
    no "T3-3: nftban_fhs_spec.sh has no /etc/nftban/gui directory entry" \
       "$(grep -nE '/etc/nftban/gui' "$FHS_OUT" | head -1)"
else
    ok "T3-3: nftban_fhs_spec.sh has no /etc/nftban/gui directory entry"
fi

# ──────────────────────────────────────────────────────────────────────────
# Section 4: cli/sbin/nftban — dispatcher reachability for `nftban gui`
# ──────────────────────────────────────────────────────────────────────────
DISP="$REPO/cli/sbin/nftban"
[[ -f "$DISP" ]] || { echo "FAIL: missing $DISP"; exit 1; }

# T4-1: 'gui' not in canonical command list. The function _nftban_canonical_commands
# emits one command per line from a heredoc; ensure no bare 'gui' line appears.
if awk '/^_nftban_canonical_commands\(\)/,/^EOF$/' "$DISP" | grep -E '^gui$' >/dev/null 2>&1; then
    no "T4-1: _nftban_canonical_commands has no bare 'gui' line" \
       "$(awk '/^_nftban_canonical_commands\(\)/,/^EOF$/' "$DISP" | grep -nE '^gui$' | head -1)"
else
    ok "T4-1: _nftban_canonical_commands has no bare 'gui' line"
fi

# T4-2: 'gui' not in the alias-case block (cloudflare/enable|disable|restart/
# verify|explain/service/export/rollback). Pattern: '^[[:space:]]+gui)' or
# '|gui)' inside the alias-case lines after the autoloader fallthrough.
if grep -nE '^[[:space:]]+gui\)|gui\|.+\)|\|gui\)' "$DISP" >/dev/null 2>&1; then
    no "T4-2: dispatcher has no 'gui' case alias" \
       "$(grep -nE '^[[:space:]]+gui\)|gui\|.+\)|\|gui\)' "$DISP" | head -1)"
else
    ok "T4-2: dispatcher has no 'gui' case alias"
fi

# T4-3: no autoloader sourcing of cmd_gui.sh — assert the autoloader walks
# ${NFTBAN_LIB_DIR}/cli/cmd_${cmd}.sh and assert the file doesn't exist on
# disk. (The dispatcher pattern itself doesn't name 'gui'; it builds the
# path dynamically. So we just assert cmd_gui.sh isn't present in the tree.)
if [[ -f "$REPO/cli/lib/nftban/cli/cmd_gui.sh" ]]; then
    no "T4-3: cli/lib/nftban/cli/cmd_gui.sh not present" \
       "found at $REPO/cli/lib/nftban/cli/cmd_gui.sh"
else
    ok "T4-3: cli/lib/nftban/cli/cmd_gui.sh not present"
fi

# ──────────────────────────────────────────────────────────────────────────
# Section 5: cross-tree string drift — only test files and harmless comments
#            may mention 'gui'/'GUI' from this point forward
# ──────────────────────────────────────────────────────────────────────────
# T5-1: no shell .sh source advertises 'nftban gui <subcmd>' (the v133 D-01
# guard already enforces this; this is an explicit v144 regression-lock).
# Scope: cli/ excluding tests and tabular health-render array key.
HITS=$(grep -rnE 'nftban gui ' --include='*.sh' "$REPO/cli/" 2>/dev/null | grep -v '/tests/' || true)
if [[ -n "$HITS" ]]; then
    no "T5-1: no shell source advertises 'nftban gui <subcmd>'" \
       "$(echo "$HITS" | head -1)"
else
    ok "T5-1: no shell source advertises 'nftban gui <subcmd>'"
fi

# ──────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────
echo
echo "═══════════════════════════════════════════════════════════════"
echo "  cli_no_gui_doc_drift_v144_test results: ${PASS} PASS / ${FAIL} FAIL"
echo "═══════════════════════════════════════════════════════════════"

if [[ $FAIL -gt 0 ]]; then
    echo "Failed tests:"
    for f in "${FAILED[@]}"; do
        echo "  - $f"
    done
    exit 1
fi

exit 0
