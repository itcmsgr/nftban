#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.153 PR-F: short-help verb icons + wording-truth (UX-A7)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="help_verb_icons_v153_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-06"
# meta:description="Locks the marker contract of the two help views (v1.153 PR-F UX-A7, rebased v1.238 help truth). v1.238: ONE meaning per marker in both views. The marker of every command in the short 'nftban help' (_nftban_help_essential) must equal the marker 'nftban help --all' derives from commands.registry.yml (risk advanced -> ⚠️, setup -> 🛠️, otherwise mutates true|conditional -> ⚡, otherwise unmarked), read here with awk (no yq); generate-help.sh must implement that same rule; both legends must carry the same four definitions; no undefined marker (🔍) may appear; read-only verbs (status, list, search, version) stay unmarked; the --all global options list only dispatcher-global flags; the quick ban example uses a documentation address. WORDING-TRUTH guard: no unproven 'protected/validated' posture claim. Hermetic: sources nftban_help.sh and reads the registry and generate-help.sh as text; no host/nft/IPC."
# meta:input="cli/lib/nftban/nftban_help.sh"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep,awk"
# meta:inventory.files="cli/lib/nftban/nftban_help.sh,commands.registry.yml,scripts/generate-help.sh"
# meta:inventory.binaries="bash,grep,awk"
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

REG="$REPO/commands.registry.yml"
GEN="$REPO/scripts/generate-help.sh"

# Registry marker for a top-level command (same rule as generate-help.sh _marker_for).
reg_marker() {
    local risk mutates
    risk=$(awk -v c="$1" '$0 ~ "^"c":[[:space:]]*$" {f=1; next} f && /^[^[:space:]#]/ {exit} f && /^  risk:/ {print $2; exit}' "$REG")
    mutates=$(awk -v c="$1" '$0 ~ "^"c":[[:space:]]*$" {f=1; next} f && /^[^[:space:]#]/ {exit} f && /^  mutates:/ {print $2; exit}' "$REG")
    case "$risk" in
        advanced) printf '⚠️' ;;
        setup)    printf '🛠️' ;;
        *) case "$mutates" in true|conditional) printf '⚡' ;; *) printf 'none' ;; esac ;;
    esac
}
# Marker printed in the short list for a command ('none' when unmarked).
short_marker() {
    local l
    l=$(grep -m1 -E "^  (⚡|⚠️|🛠️|🔍| ) ? *$1 " <<< "$OUT" || true)
    case "$l" in
        "  ⚡ $1 "*) printf '⚡' ;;
        "  ⚠️ $1 "*) printf '⚠️' ;;
        "  🛠️ $1 "*) printf '🛠️' ;;
        "     $1 "*) printf 'none' ;;
        *) printf 'MISSING' ;;
    esac
}

echo "=== v1.238: every short-list marker equals the registry-derived --all marker ==="
SHORT_CMDS=$(awk '/^MARKERS/{exit} {print}' <<< "$OUT" | grep -oE '^  (⚡ |⚠️ |🛠️ |🔍 |   )[a-z][a-z-]+ ' | awk '{print $NF}' | sort -u)
n=0
for c in $SHORT_CMDS; do
    n=$((n+1))
    want=$(reg_marker "$c"); got=$(short_marker "$c")
    [[ "$got" == "$want" ]] && ok "'$c' marker $got == registry" || no "'$c' marker differs from 'help --all'" "short=$got registry=$want"
done
(( n >= 15 )) && ok "short list parsed ($n commands)" || no "short list parse" "only $n commands"

echo "=== read-only verbs stay unmarked ==="
for v in status list search version; do
    [[ "$(short_marker "$v")" == none ]] && ok "read-only verb '$v' is unmarked" || no "read-only verb '$v' marked" "$(short_marker "$v")"
done

echo "=== one legend, same four definitions in both views; no undefined marker ==="
for d in '⚡ changes state in some subcommands' '⚠️ advanced: changes state, use with caution' '🛠️ one-time setup' 'unmarked = read-only'; do
    grep -qF -- "$d" <<< "$OUT" && ok "short legend: $d" || no "short legend missing" "$d"
    grep -qF -- "$d" "$GEN" && ok "--all legend: $d" || no "--all legend missing" "$d"
done
grep -q '🔍' <<< "$OUT" && no "short help uses the undefined marker 🔍" || ok "no undefined marker (🔍) in the short help"
grep -q 'Core      - Essential, safe operations' "$GEN" && no "--all still defines ⚡ as 'Core, safe'" || ok "--all no longer defines ⚡ as 'Core, safe'"
grep -qE '^_marker_for\(\)' "$GEN" && grep -qF 'advanced) printf' "$GEN" && grep -qF 'true|conditional) printf' "$GEN" \
    && ok "generate-help.sh derives markers by the same rule (_marker_for)" || no "generate-help.sh marker rule" "_marker_for missing or changed"

echo "=== --all global options are dispatcher-global only; example IP ==="
go=$(awk '/^global_options:/{f=1;next} f&&/^[^[:space:]#]/{exit} f&&/^  --?[a-z-]+:/{sub(":","",$1); print $1}' "$REG" | tr '\n' ' ')
for bad in --force --dry-run --verbose; do
    [[ " $go " == *" $bad "* ]] && no "global_options lists per-command flag $bad" "$go" || ok "global_options does not list $bad"
done
for good in --help --version --json --quiet --no-banner; do
    [[ " $go " == *" $good "* ]] && ok "global_options lists $good" || no "global_options missing $good" "$go"
done
grep -qF 'nftban ban 192.0.2.10' "$GEN" && ! grep -qF 'nftban ban 1.2.3.4' "$GEN" \
    && ok "quick example bans a documentation address (192.0.2.10)" || no "quick ban example IP" "not 192.0.2.10"

echo "=== WORDING-TRUTH: short help makes no unproven posture claim ==="
printf '%s\n' "$OUT" | grep -qiE 'PROTECTED|fully protected|validated' \
    && no "short help leaked an unproven posture/validated claim" \
    || ok "short help carries no unproven posture/validated claim"

echo ""
echo "================================================================"
echo "help_verb_icons_v153: PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[[ $FAIL -eq 0 ]]
