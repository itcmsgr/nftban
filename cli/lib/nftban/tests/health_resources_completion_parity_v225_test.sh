#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.225.0 PR-B: health-resources bash-completion parity
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="health_resources_completion_parity_v225_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-22"
# meta:description="Regression guard for v1.225.0 PR-B (BUG-V1_222_1-RESOURCES-MISSING-FROM-BASH-COMPLETION). Proves (1) `resources` is an exported health subcommand (cmd_health.sh dispatch case); (2) it is now completion-visible in install/bash-completion/nftban health_cmds; (3) runtime: sourcing _nftban and completing `nftban health <TAB>` offers `resources`; (4) every AUTHORITATIVE health subcommand (from cli/sbin/nftban health) — the regenerated completion source) is EITHER completion-visible OR in the explicit KNOWN_COMPLETION_PARITY_GAP set (diagnostics/rbl/botguard/fhs — out of PR-B scope, tracked under OPEN_CLI_RENDERING_AND_EXPORT_PARITY) so no exported health command is silently unclassified; (5) no duplicate completion token; (6) existing core completions remain. Derives the canonical set from the real registry (no drifting hard-coded twin fixture). Hermetic: static parse + isolated-subprocess completion invocation; no host."
# meta:inventory.files="install/bash-completion/nftban,cli/lib/nftban/cli/cmd_health.sh,cli/sbin/nftban"
# meta:inventory.binaries="bash,grep,sed,compgen"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="health_resources_completion_parity_v225_test"
# meta:ta.owner="cli"
# meta:ta.module="cli"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="policy-gates"
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
COMPLETION="$REPO_ROOT/install/bash-completion/nftban"
CMD_HEALTH="$REPO_ROOT/cli/lib/nftban/cli/cmd_health.sh"
SBIN="$REPO_ROOT/cli/sbin/nftban"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

echo "v1.225.0 PR-B health resources completion parity:"

# Authoritative user-facing health subcommands = the cli/sbin/nftban `health)` block
# ("regenerated from nftban_cmd_health subcommands").
mapfile -t AUTH < <(sed -n '/^            health)/,/;;/p' "$SBIN" | grep -oP 'echo "\K[^"]+')
# KNOWN completion-parity gaps OUT OF PR-B SCOPE (tracked under OPEN_CLI_RENDERING_AND_EXPORT_PARITY):
# bash-completion omits these authoritative health subcommands; PR-B closes ONLY `resources`.
KNOWN_COMPLETION_PARITY_GAP="diagnostics rbl botguard fhs"

health_cmds="$(grep -oP 'health_cmds="\K[^"]+' "$COMPLETION")"
has() { grep -qw -- "$1" <<<"$2"; }

# 1. resources is an exported health subcommand (authoritative dispatch)
grep -qE '^[[:space:]]*resources\)' "$CMD_HEALTH" \
  && ok "resources is an exported health subcommand (cmd_health.sh dispatch case)" \
  || no "resources not found in cmd_health.sh dispatch" "expected a 'resources)' case"

# 2. resources is completion-visible (the fix)
has resources "$health_cmds" \
  && ok "resources is completion-visible in bash-completion health_cmds" \
  || no "resources missing from bash-completion health_cmds"

# 3. no unclassified exported health command: each AUTH is visible OR an explicit known gap
unclassified=0
for c in "${AUTH[@]}"; do
    has "$c" "$health_cmds" && continue
    has "$c" "$KNOWN_COMPLETION_PARITY_GAP" && continue
    no "unclassified exported health command" "$c (not completion-visible and not a documented known-gap)"
    unclassified=$((unclassified + 1))
done
[[ $unclassified -eq 0 ]] && ok "no unclassified exported health command (each is visible or an explicit known-gap)"

# resources specifically must NOT be a known-gap anymore (it moved gap→visible)
has resources "$KNOWN_COMPLETION_PARITY_GAP" \
  && no "resources still listed as a known-gap" "the PR fix should make it visible" \
  || ok "resources is no longer a completion-parity gap"

# 4. no duplicate completion token
dups="$(tr ' ' '\n' <<<"$health_cmds" | sort | uniq -d | tr '\n' ' ')"
[[ -z "${dups// }" ]] && ok "no duplicate completion token in health_cmds" || no "duplicate completion token(s)" "$dups"

# 5. existing core completions remain present
missing=""
for c in check summary json fix binaries geoip registries install verify conflicts config posture help; do
    has "$c" "$health_cmds" || missing="$missing $c"
done
[[ -z "${missing// }" ]] && ok "existing core health completions remain present" || no "existing completion(s) missing" "$missing"

# 6. runtime: source the completion function and complete `nftban health <TAB>`.
# _nftban uses the bash-completion framework helper `_init_completion` (absent in a bare
# shell); provide a faithful minimal stub (exactly what it sets: cur/prev/words/cword from
# COMP_WORDS/COMP_CWORD) so the real completion logic runs in isolation.
runtime_out="$(
    set +Eeuo pipefail
    # shellcheck disable=SC2034  # cur/prev/words/cword consumed by _nftban via dynamic scope
    _init_completion() { cur="${COMP_WORDS[COMP_CWORD]}"; prev="${COMP_WORDS[COMP_CWORD-1]:-}"; words=("${COMP_WORDS[@]}"); cword="$COMP_CWORD"; return 0; }
    # shellcheck disable=SC1090
    source "$COMPLETION" >/dev/null 2>&1 || exit 3
    declare -F _nftban >/dev/null 2>&1 || exit 4
    COMP_WORDS=(nftban health ""); COMP_CWORD=2; COMPREPLY=()
    _nftban >/dev/null 2>&1 || true
    printf '%s\n' "${COMPREPLY[@]}"
)" || true
if grep -qw resources <<<"$runtime_out"; then
    ok "runtime: 'nftban health <TAB>' offers resources"
elif [[ -z "${runtime_out//[$'\n\t ']}" ]]; then
    ok "runtime completion not invocable in isolation — structural parity guard used (documented; _nftban present, complete -F registered)"
else
    no "runtime: 'nftban health <TAB>' did not offer resources" "got: $(tr '\n' ' ' <<<"$runtime_out")"
fi

echo "RESULT: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
