#!/usr/bin/env bash
# =============================================================================
# NFTBan - connector no-edit-hint test (v1.144.0 PR-C D-UXV-14)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cli_connector_no_edit_hint_v144_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-01"
# meta:description="v1.144.0 PR-C D-UXV-14 closure — asserts cmd_connector.sh no longer advertises 'nftban connector edit' (which never existed in the dispatch and would hit the 'Unknown command' catch-all rc=1). The existing-connector branch in _cmd_connector_add() must instead print the canonical idempotent recreate pattern: 'nftban connector show NAME' (inspect) and 'nftban connector remove NAME && nftban connector add NAME [...]' (recreate). The dispatch itself remains intact — list/add/remove|delete|rm/enable/disable/test/show/push/help — verified by re-asserting the case-arm pattern. Hermetic — no daemon, no nft, no host contact."
# meta:input="cli/lib/nftban/cli/cmd_connector.sh"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep"
# meta:inventory.files="cli/lib/nftban/cli/cmd_connector.sh"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../../../.." && pwd)
CONN="$REPO/cli/lib/nftban/cli/cmd_connector.sh"

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s (%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

[[ -f "$CONN" ]] || { echo "FAIL: missing $CONN"; exit 1; }

# T1: no echo-printf line emits 'nftban connector edit'. Comment lines
# (PR-C documentation reference at :233) are allowed; only a non-comment
# code line emitting the broken hint is forbidden.
if grep -nE 'echo[[:space:]]+.*"nftban connector edit' "$CONN" >/dev/null 2>&1; then
    no "T1: no echo line emits 'nftban connector edit'" \
       "$(grep -nE 'echo.*"nftban connector edit' "$CONN" | head -1)"
else
    ok "T1: no echo line emits 'nftban connector edit'"
fi

# T2: the replacement 2-line hint pattern is present
if grep -nE 'nftban connector show \$name' "$CONN" >/dev/null 2>&1; then
    ok "T2: 'nftban connector show \$name' present (inspect hint)"
else
    no "T2: 'nftban connector show \$name' present (inspect hint)" "not found"
fi
if grep -nE 'nftban connector remove \$name && nftban connector add \$name' "$CONN" >/dev/null 2>&1; then
    ok "T3: 'nftban connector remove \$name && nftban connector add \$name' present (recreate hint)"
else
    no "T3: 'nftban connector remove \$name && nftban connector add \$name' present (recreate hint)" "not found"
fi

# T4: connector dispatch case-arm is unchanged. Look for the canonical
# arm list: list/add/remove|delete|rm/enable/disable/test/show/push/help.
# Use POSIX-portable [[:space:]] (grep -E doesn't reliably grok \s).
# IMPORTANT: declare arms as an explicit array because the test sets
# IFS=$'\n\t' at the top — `for arm in $expected_string` would NOT
# word-split on spaces under that IFS.
expected_arms=(list add remove delete rm enable disable test show push help)
missing=()
for arm in "${expected_arms[@]}"; do
    if ! grep -nE "^[[:space:]]*${arm}[)|]|\|${arm}[)|]" "$CONN" >/dev/null 2>&1; then
        missing+=("$arm")
    fi
done
if [[ ${#missing[@]} -eq 0 ]]; then
    ok "T4: connector dispatch case-arms all present (no regression)"
else
    no "T4: connector dispatch case-arms all present (no regression)" \
       "missing: ${missing[*]}"
fi

# T5: no NEW 'edit' arm was added (we explicitly did NOT implement edit;
# the recreate pattern is the canonical idempotent path)
if awk '/^nftban_cmd_connector\(\)/,/^}/' "$CONN" | grep -nE '^[[:space:]]*edit[)|]|\|edit[)|]' >/dev/null 2>&1; then
    no "T5: no 'edit' arm in connector dispatch (recreate is the canonical pattern)" \
       "edit arm found"
else
    ok "T5: no 'edit' arm in connector dispatch (recreate is the canonical pattern)"
fi

# T6: the only remaining 'edit' token in this file is the retirement
# comment at the changed site. Strip comment lines and assert.
# Note: the pipeline runs under `set -Eeuo pipefail`, so a successful
# zero-match (inner grep -v returns 1) would otherwise abort. Wrap with
# explicit `|| true` to capture the count safely.
non_comment_edit_count=$( { grep -nE '\bedit\b' "$CONN" || true; } | { grep -vE '^[0-9]+:[[:space:]]*#' || true; } | wc -l)
if [[ "$non_comment_edit_count" -eq 0 ]]; then
    ok "T6: no non-comment 'edit' tokens remain in cmd_connector.sh"
else
    no "T6: no non-comment 'edit' tokens remain in cmd_connector.sh" \
       "$( { grep -nE '\bedit\b' "$CONN" || true; } | { grep -vE '^[0-9]+:[[:space:]]*#' || true; } | head -3)"
fi

echo
echo "═══════════════════════════════════════════════════════════════"
echo "  cli_connector_no_edit_hint_v144_test: ${PASS} PASS / ${FAIL} FAIL"
echo "═══════════════════════════════════════════════════════════════"

if [[ $FAIL -gt 0 ]]; then
    echo "Failed tests:"
    for f in "${FAILED[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
