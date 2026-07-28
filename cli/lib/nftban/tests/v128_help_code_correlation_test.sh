#!/usr/bin/env bash
# =============================================================================
# v1.128 PR-B HELP_CODE_CORRELATION_AUDIT — deterministic test fixtures
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="v128_help_code_correlation_test"
# meta:type="test"
# meta:version="1.128.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-24"
# meta:description="Deterministic correlation audit verifying that the canonical NFTBan top-level command list (cli/sbin/nftban::_nftban_canonical_commands), the cmd_<X>.sh file inventory, and the dispatcher's known-nftban-core-command case statement remain mutually consistent. Catches the bug class where a help block invokes a command that no longer exists or a cmd_<X>.sh file is shipped for a command that the dispatcher doesn't route. Subcommand-level doctest validation (verifying every 'nftban X Y' in help text resolves to a parser branch in cmd_X.sh) is INTENTIONALLY deferred to a future deeper-audit lane: subcommand parsing varies hugely across files (helper sub-modules cmd_X_*.sh own dispatch for some commands; wildcard cases swallow others; narrative text 'firewall-logs is an alias for ...' generates false positives). The lighter top-level + dispatcher consistency checks land here as the v1.128 lockable correlation invariant."
# meta:input="static source-file scan of cli/sbin/nftban + cli/lib/nftban/cli/cmd_*.sh"
# meta:output="exit 0 if all correlations resolve; exit 1 with drift report otherwise"
# meta:depends="bash,grep,sed,sort,comm"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="v128_help_code_correlation_test"
# meta:ta.owner="cli"
# meta:ta.module="cli-command-correlation"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
#
# Scope: AUDIT_190_LIFECYCLE/V128_CLI_TEXT_AUTHORITY_ALIGNMENT_SCOPE.md (PR-B lane)
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

echo "==============================================================================="
echo "v1.128 PR-B HELP_CODE_CORRELATION_AUDIT — deterministic test fixtures"
echo "==============================================================================="

# Cleanup temp files on exit
_canonical_tmp=$(mktemp -t v128_pr_b_canonical.XXXXXX)
_cmd_files_tmp=$(mktemp -t v128_pr_b_cmdfiles.XXXXXX)
_dispatched_tmp=$(mktemp -t v128_pr_b_dispatched.XXXXXX)
trap 'rm -f "$_canonical_tmp" "$_cmd_files_tmp" "$_dispatched_tmp"' EXIT

# =============================================================================
# (1) Build canonical top-level command set
# =============================================================================
awk '/^_nftban_canonical_commands\(\) \{$/,/^EOF$/' "$_cli_sbin" \
    | grep -E '^[a-z][a-z0-9_-]*$' \
    | sort -u > "$_canonical_tmp"
canonical_count=$(wc -l < "$_canonical_tmp")
[[ "$canonical_count" -ge 50 && "$canonical_count" -le 100 ]]
_t_assert "C1: canonical command list extracted (got: $canonical_count, expected 50-100)" "$?"

# =============================================================================
# (2) Build cmd_<X>.sh file inventory.
# Excludes helper sub-modules (cmd_X_<verb>.sh):
#   keep:  cmd_ban.sh, cmd_firewall_logs.sh (hyphenated alias)
#   drop:  cmd_update_helpers.sh, cmd_update_methods.sh, cmd_update_backup.sh, etc.
# =============================================================================
for f in "${_cli_lib}/cli/cmd_"*.sh; do
    base=$(basename "$f" .sh)
    cmd="${base#cmd_}"
    # The canonical command list IS the source of truth. Treat cmd_X_Y as
    # a helper sub-module unless the joined form is a real command (e.g.
    # firewall_logs → firewall-logs, whitelist_system → whitelist-system,
    # support_bundle → support-bundle, suricata_setup → suricata setup [sub]).
    case "$cmd" in
        firewall_logs)   echo "firewall-logs" ;;
        whitelist_system) echo "whitelist-system" ;;
        support_bundle)  echo "support-bundle" ;;
        suricata_setup)  ;; # subcommand of suricata, no top-level entry
        *_*) ;; # other helper sub-modules — skip
        *) echo "$cmd" ;;
    esac
done | sort -u > "$_cmd_files_tmp"
cmd_files_count=$(wc -l < "$_cmd_files_tmp")
[[ "$cmd_files_count" -ge 40 ]]
_t_assert "C2: cmd_*.sh file inventory extracted (got: $cmd_files_count, expected >=40)" "$?"

# =============================================================================
# (3) Build dispatcher's known-nftban-core-command list (case at ~line 1342)
# =============================================================================
grep -E '^\s*init\|sync\|' "$_cli_sbin" | head -1 \
    | sed -E 's/^[[:space:]]*//' \
    | sed -E 's/\)[[:space:]]*$//' \
    | tr '|' '\n' \
    | sort -u > "$_dispatched_tmp"
dispatched_count=$(wc -l < "$_dispatched_tmp")
[[ "$dispatched_count" -ge 5 ]]
_t_assert "C3: dispatcher's nftban-core case list extracted (got: $dispatched_count, expected >=5)" "$?"

# =============================================================================
# (4) Every cmd_<X>.sh maps to a canonical command (no orphan files)
# =============================================================================
orphan_files=$(comm -23 "$_cmd_files_tmp" "$_canonical_tmp")
orphan_count=$(echo -n "$orphan_files" | grep -c '^' || true)
orphan_count=${orphan_count:-0}
if [[ "$orphan_count" -eq 0 ]]; then
    _t_assert "C4: every cmd_<X>.sh maps to a canonical command (no orphan files)" 0
else
    _t_assert "C4: $orphan_count cmd_<X>.sh files have no canonical-command match" 1
    echo "  === Orphan cmd_*.sh files ==="
    echo "$orphan_files" | sed 's/^/    /'
fi

# =============================================================================
# (5) Every canonical command is reachable: cmd_<X>.sh file exists OR
#     dispatcher routes to nftban-core OR special-case dispatcher branch.
# =============================================================================
# Special-case dispatch (in cli/sbin/nftban around line 898):
#   firewall-logs → cmd_firewall_logs.sh (covered by file inventory)
#   support-bundle → cmd_support.sh (alias)
# Plus a small set that nftban-core handles silently:
#   init, ports (nftban-core only — no cli/lib counterpart)
#
# A canonical command is "unreachable" if it has no cmd_<X>.sh AND is NOT
# in the dispatcher's nftban-core case list AND is NOT in this hard-coded
# alias-only set.
_ALIAS_ONLY_HANDLED=(
    "support-bundle"  # aliased to cmd_support.sh via dispatcher special-case
    "menu"            # ui-only; may route via cmd_menu.sh
    "smoke"           # debug-only
    "test"            # debug-only
    "debug"           # debug-only
    "hello"           # placeholder
    # Inline-dispatched commands in cli/sbin/nftban main():
    # service-control verbs handled inline (no cmd_enable.sh / cmd_disable.sh
    # / cmd_restart.sh — they delegate to systemctl via inline case branches)
    "enable"
    "disable"
    "restart"
    # bootstrap/installer commands handled inline (delegate to nftban-installer
    # or nftban-core; no cmd_install.sh / cmd_uninstall.sh / cmd_rebuild.sh)
    "install"
    "uninstall"
    "rebuild"
    # other inline cases (help dispatcher at line 1320; cloudflare wrapper)
    "help"
    "cloudflare"
    # v1.228.1 PR-1 (R20): inline alias arms in cli/sbin/nftban main() that the
    # Level-0 completion already offered but the canonical list omitted. Adding
    # them to _nftban_canonical_commands() closed that split; they are reachable
    # via the post-autoloader case, not via a cmd_<X>.sh of their own.
    "verify"      # -> nftban_cmd_emulate
    "explain"     # -> nftban_cmd_emulate
    "export"      # -> nftban_cmd_stats export
    "rollback"    # -> nftban_cmd_update rollback
)
unreachable=()
while IFS= read -r cmd; do
    [[ -z "$cmd" ]] && continue
    # cmd_<X>.sh exists?
    if grep -qFx "$cmd" "$_cmd_files_tmp"; then
        continue
    fi
    # In nftban-core dispatch?
    if grep -qFx "$cmd" "$_dispatched_tmp"; then
        continue
    fi
    # Alias-only handled?
    skip=0
    for a in "${_ALIAS_ONLY_HANDLED[@]}"; do
        if [[ "$cmd" == "$a" ]]; then
            skip=1
            break
        fi
    done
    [[ $skip -eq 1 ]] && continue
    unreachable+=("$cmd")
done < "$_canonical_tmp"

if [[ "${#unreachable[@]}" -eq 0 ]]; then
    _t_assert "C5: every canonical command is reachable (no orphan canonical entries)" 0
else
    _t_assert "C5: ${#unreachable[@]} canonical commands have no cmd_*.sh + no dispatcher route + no allowlist" 1
    echo "  === Unreachable canonical commands ==="
    for cmd in "${unreachable[@]}"; do
        echo "    $cmd"
    done
fi

# =============================================================================
# (6) Scope-creep guards (NOT PR-C, NOT PR-D)
# =============================================================================
if git diff --name-only HEAD 2>/dev/null | grep -qE '\.wiki|^WIKI/|^docs/|^README'; then
    _t_assert "D1: scope-creep (wiki/docs/README in diff)" 1
else
    _t_assert "D1: no wiki/docs/README absorbed (PR-C/PR-D not touched)" 0
fi

# Confirm this is repo-only (no test changes outside this file)
non_test_files=$(git diff --name-only HEAD 2>/dev/null | grep -v "v128_help_code_correlation_test\.sh" | wc -l)
[[ "$non_test_files" -le 5 ]]
_t_assert "D2: PR-B diff is small (test + ≤5 fix files; got: $((non_test_files+1)) total)" "$?"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "==============================================================================="
echo "v1.128 PR-B test summary: ${TESTS_PASSED} PASS, ${TESTS_FAILED} FAIL"
echo "==============================================================================="
if [[ "$TESTS_FAILED" -gt 0 ]]; then
    echo "Failed tests:"
    for name in "${FAILED_NAMES[@]}"; do
        echo "  - $name"
    done
    exit 1
fi
exit 0
