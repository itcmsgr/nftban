#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.153 PR-F: short-help verb icons + wording-truth (UX-A7)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="help_verb_icons_v153_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-06"
# meta:description="Locks v1.153 PR-F UX-A7: the short 'nftban help' (_nftban_help_essential) now carries the same ⚡/⚠️ risk markers as 'help --all' on state-changing verbs. Asserts: state-changing verbs (ban, unban, blacklist, whitelist, feeds, ddos, portscan, login, botguard, geoban, config) are marked ⚡; advanced/caution verbs (firewall, update) are marked ⚠️; read-only verbs (status, health, list, search, version) are NOT marked; a LEGEND explains the markers. WORDING-TRUTH guard: the short help does not introduce an unproven 'protected/validated' posture claim. Hermetic: sources nftban_help.sh and inspects the rendered text; no host/nft/IPC."
# meta:input="cli/lib/nftban/nftban_help.sh"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep"
# meta:inventory.files="cli/lib/nftban/nftban_help.sh"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="help_verb_icons_v153_test"
# meta:ta.owner="cli"
# meta:ta.module="help-render"
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
HELP="$REPO/cli/lib/nftban/nftban_help.sh"
export NFTBAN_LIB_DIR="$REPO/cli/lib/nftban"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✓ $1"; }
no() { FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

# Render the short help text.
OUT="$(
    set +e
    # shellcheck source=/dev/null
    source "$HELP" 2>/dev/null || true
    _nftban_help_essential 2>&1
)" || true

# Helper: assert a verb's line begins (after leading spaces) with a marker.
line_for() { printf '%s\n' "$OUT" | grep -E "[[:space:]]$1([[:space:]]|$)" | head -1; }

echo "=== UX-A7: state-changing verbs carry the ⚡ marker ==="
for v in ban unban blacklist whitelist feeds ddos portscan login botguard geoban config; do
    l="$(line_for "$v")"
    if [[ "$l" == *"⚡ $v"* ]]; then
        ok "⚡ marks state-changing verb '$v'"
    else
        no "verb '$v' not marked ⚡" "$l"
    fi
done

echo "=== UX-A7: advanced/caution verbs carry the ⚠️ marker ==="
for v in firewall update; do
    l="$(line_for "$v")"
    if [[ "$l" == *"⚠️ $v"* ]]; then
        ok "⚠️ marks advanced verb '$v'"
    else
        no "verb '$v' not marked ⚠️" "$l"
    fi
done

echo "=== UX-A7: read-only verbs are NOT marked ==="
for v in status health list search version; do
    l="$(line_for "$v")"
    if [[ "$l" == *"⚡ $v"* || "$l" == *"⚠️ $v"* ]]; then
        no "read-only verb '$v' wrongly marked" "$l"
    else
        ok "read-only verb '$v' is unmarked"
    fi
done

echo "=== UX-A7: a legend explains the markers ==="
printf '%s\n' "$OUT" | grep -qi 'LEGEND' && ok "LEGEND header present" || no "LEGEND missing"
printf '%s\n' "$OUT" | grep -q 'state-changing' && ok "legend defines ⚡ = state-changing" || no "state-changing legend text missing"
printf '%s\n' "$OUT" | grep -qi 'use with caution' && ok "legend defines ⚠️ = advanced/caution" || no "caution legend text missing"

echo "=== WORDING-TRUTH: short help makes no unproven posture claim ==="
printf '%s\n' "$OUT" | grep -qiE 'PROTECTED|fully protected|validated' \
    && no "short help leaked an unproven posture/validated claim" \
    || ok "short help carries no unproven posture/validated claim"

echo ""
echo "================================================================"
echo "help_verb_icons_v153: PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[[ $FAIL -eq 0 ]]
