#!/usr/bin/env bash
# =============================================================================
# V127 UX-5 typo handler + discoverability — deterministic test fixtures
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="v127_ux5_typo_discoverability_test"
# meta:type="test"
# meta:version="1.127.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-24"
# meta:description="Deterministic shell tests for V127 UX-5 lane (PR-E). Covers item 2.8 typo handler (Damerau-Levenshtein edit-distance command suggestion replacing the prior static case table in cli/sbin/nftban), D-8 alias display annotation in cmd_firewall_logs.sh (_fwlog_help), and D-9 update<->version cross-reference SEE ALSO blocks in cmd_update.sh (_cmd_update_help) and cmd_version.sh (nftban_cmd_version_usage). Positive typo cases (statuse/whitlist/bna/udpate/verison and family), negative cases (random garbage and short ambiguous tokens), alias-annotation grep, cross-reference grep, and UX-6 scope-creep guard included."
# meta:input="static source-file inspection + functional source-and-call against extracted typo helpers"
# meta:output="exit 0 if all assertions pass; exit 1 with FAILED tests list otherwise"
# meta:depends="bash,awk,grep,sed,mktemp"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# Scope: AUDIT_190_LIFECYCLE/V127_FULL_UX_CORRECTION_UMBRELLA_SCOPE.md (UX-5 lane)
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
_cmd_firewall_logs="${_repo_root}/cli/lib/nftban/cli/cmd_firewall_logs.sh"
_cmd_update="${_repo_root}/cli/lib/nftban/cli/cmd_update.sh"
_cmd_version="${_repo_root}/cli/lib/nftban/cli/cmd_version.sh"

echo "==============================================================================="
echo "V127 UX-5 typo handler + discoverability — deterministic test fixtures"
echo "==============================================================================="

# =============================================================================
# Extract typo helpers from cli/sbin/nftban into a sourceable temp file.
# Sourcing cli/sbin/nftban directly would execute main() against the installed
# /usr/lib/nftban/ layout which isn't present in CI/dev — extracting the two
# self-contained pure-bash helper functions lets us exercise them in isolation.
# =============================================================================
_helpers_tmp=$(mktemp -t v127_ux5_helpers.XXXXXX.sh)
trap 'rm -f "$_helpers_tmp"' EXIT

awk '
    /^# V127 UX-5 item 2.8: typo-tolerant command suggestion/ {capture=1}
    capture {print}
    capture && /^# MAIN CLI$/ {exit}
' "$_sbin_nftban" > "$_helpers_tmp"

# Strip the trailing "# MAIN CLI" marker line that awk includes via the exit condition
sed -i '/^# MAIN CLI$/d' "$_helpers_tmp"
# Also strip the trailing "============" banner line above it if present
sed -i '${/^# =\+$/d}' "$_helpers_tmp"

# shellcheck disable=SC1090
source "$_helpers_tmp"

# Sanity: helpers loaded
if ! declare -f _nftban_suggest_command >/dev/null 2>&1; then
    echo "  [FATAL] _nftban_suggest_command not loaded after extraction (extraction broken)"
    echo "  --- extracted helpers ---"
    cat "$_helpers_tmp"
    exit 1
fi

# =============================================================================
# (A) Damerau-Levenshtein helper sanity
# =============================================================================

# A1: identical strings -> 0
[[ "$(_nftban_damerau_levenshtein "ban" "ban")" == "0" ]]
_t_assert "A1: damerau_levenshtein('ban','ban') == 0" "$?"

# A2: single substitution
[[ "$(_nftban_damerau_levenshtein "ban" "bah")" == "1" ]]
_t_assert "A2: damerau_levenshtein('ban','bah') == 1" "$?"

# A3: single insertion
[[ "$(_nftban_damerau_levenshtein "ban" "band")" == "1" ]]
_t_assert "A3: damerau_levenshtein('ban','band') == 1" "$?"

# A4: single deletion
[[ "$(_nftban_damerau_levenshtein "bann" "ban")" == "1" ]]
_t_assert "A4: damerau_levenshtein('bann','ban') == 1" "$?"

# A5: adjacent transposition (Damerau-specific; should be 1, NOT 2)
[[ "$(_nftban_damerau_levenshtein "bna" "ban")" == "1" ]]
_t_assert "A5: damerau_levenshtein('bna','ban') == 1 (transposition)" "$?"

# A6: udpate <-> update is an adjacent transposition of d/p
[[ "$(_nftban_damerau_levenshtein "udpate" "update")" == "1" ]]
_t_assert "A6: damerau_levenshtein('udpate','update') == 1 (transposition)" "$?"

# A7: empty string
[[ "$(_nftban_damerau_levenshtein "" "ban")" == "3" ]]
_t_assert "A7: damerau_levenshtein('','ban') == 3" "$?"

# =============================================================================
# (B) Positive typo suggestions (per operator scope)
# =============================================================================

_check_suggestion() {
    local input="$1"
    local expected="$2"
    local actual
    actual=$(_nftban_suggest_command "$input")
    [[ "$actual" == "$expected" ]]
    local ok=$?
    _t_assert "B: suggest('$input') => '$expected'" "$ok" "got: '$actual'"
}

# Required by operator scope
_check_suggestion "statuse"  "status"
_check_suggestion "whitlist" "whitelist"
_check_suggestion "bna"      "ban"
_check_suggestion "udpate"   "update"
_check_suggestion "verison"  "version"

# Additional common typos previously in the static table — Damerau-Levenshtein
# should naturally cover them now via edit distance.
_check_suggestion "satus"    "status"
_check_suggestion "helth"    "health"
_check_suggestion "firewll"  "firewall"
_check_suggestion "blcklist" "blacklist"
_check_suggestion "updaet"   "update"
_check_suggestion "vesion"   "version"
_check_suggestion "uninstll" "uninstall"
_check_suggestion "rebulid"  "rebuild"

# =============================================================================
# (C) Negative tests — must NOT produce misleading suggestions
# =============================================================================

_check_no_suggestion() {
    local input="$1"
    local actual
    actual=$(_nftban_suggest_command "$input")
    [[ -z "$actual" ]]
    local ok=$?
    _t_assert "C: suggest('$input') => empty (no false-positive)" "$ok" "got: '$actual'"
}

# Random garbage well outside edit-distance thresholds
_check_no_suggestion "xyz123abc"
_check_no_suggestion "thisisntacommand"
_check_no_suggestion "qwertyuiop"

# Short ambiguous 2-char tokens (length <= 3 needs dist <= 1 per scope)
_check_no_suggestion "xy"
_check_no_suggestion "abc"   # close to "ban" at dist 2 -> blocked by tight threshold for short input

# Common English words that aren't NFTBan commands and shouldn't get a fluky match
_check_no_suggestion "hello123notacommand"

# =============================================================================
# (D) Multi-word fallback preserved (configtest -> "config validate")
# =============================================================================

# D1: source still contains the multi-word fallback case
grep -qE 'configtest\)' "$_sbin_nftban" && grep -qE 'suggestion="config validate"' "$_sbin_nftban"
_t_assert "D1: cli/sbin/nftban multi-word fallback preserves configtest -> 'config validate'" "$?"

# D2: configaudit -> "config audit"
grep -qE 'configaudit\)' "$_sbin_nftban" && grep -qE 'suggestion="config audit"' "$_sbin_nftban"
_t_assert "D2: cli/sbin/nftban multi-word fallback preserves configaudit -> 'config audit'" "$?"

# D3: prior static case table is removed (verify by absence of one of its distinctive members)
# The pre-V127 table contained entries like 'satus|staus|sattus' on a single
# case line — that exact shape should no longer be present.
grep -qE '^\s*satus\|staus\|sattus\)' "$_sbin_nftban"
ok=$?
[[ $ok -eq 0 ]] && ok=1 || ok=0
_t_assert "D3: legacy static typo case 'satus|staus|sattus)' removed" "$ok"

# D4: V127 UX-5 anchor comment present in cli/sbin/nftban
grep -q 'V127 UX-5' "$_sbin_nftban"
_t_assert "D4: cli/sbin/nftban carries V127 UX-5 scope anchor comment" "$?"

# =============================================================================
# (E) D-8 alias display in cmd_firewall_logs.sh
# =============================================================================

# E1: _fwlog_help contains an ALIAS section
awk '/_fwlog_help\(\) \{/,/^EOF$/' "$_cmd_firewall_logs" | grep -q '^ALIAS:$'
_t_assert "E1: _fwlog_help body contains 'ALIAS:' section" "$?"

# E2: _fwlog_help alias section explicitly states firewall-logs -> firewall logs
awk '/_fwlog_help\(\) \{/,/^EOF$/' "$_cmd_firewall_logs" | grep -qE 'firewall-logs.*alias.*firewall logs'
_t_assert "E2: _fwlog_help annotates firewall-logs as alias for 'firewall logs'" "$?"

# E3: V127 UX-5 anchor comment present in cmd_firewall_logs.sh
grep -q 'V127 UX-5' "$_cmd_firewall_logs"
_t_assert "E3: cmd_firewall_logs.sh carries V127 UX-5 anchor comment" "$?"

# =============================================================================
# (F) D-9 update <-> version cross-reference
# =============================================================================

# F1: _cmd_update_help body has SEE ALSO referencing nftban version
awk '/_cmd_update_help\(\) \{/,/^EOF$/' "$_cmd_update" | grep -q '^SEE ALSO:$'
_t_assert "F1: _cmd_update_help body contains 'SEE ALSO:' section" "$?"

awk '/_cmd_update_help\(\) \{/,/^EOF$/' "$_cmd_update" | grep -qE 'nftban version( |$|\s)'
_t_assert "F2: _cmd_update_help SEE ALSO mentions 'nftban version'" "$?"

awk '/_cmd_update_help\(\) \{/,/^EOF$/' "$_cmd_update" | grep -qE 'nftban version --update'
_t_assert "F3: _cmd_update_help SEE ALSO mentions 'nftban version --update'" "$?"

# F4: nftban_cmd_version_usage body has SEE ALSO referencing nftban update
awk '/nftban_cmd_version_usage\(\) \{/,/^EOF$/' "$_cmd_version" | grep -q '^SEE ALSO:$'
_t_assert "F4: nftban_cmd_version_usage body contains 'SEE ALSO:' section" "$?"

awk '/nftban_cmd_version_usage\(\) \{/,/^EOF$/' "$_cmd_version" | grep -qE 'nftban update( |$|\s)'
_t_assert "F5: nftban_cmd_version_usage SEE ALSO mentions 'nftban update'" "$?"

awk '/nftban_cmd_version_usage\(\) \{/,/^EOF$/' "$_cmd_version" | grep -qE 'nftban update check'
_t_assert "F6: nftban_cmd_version_usage SEE ALSO mentions 'nftban update check'" "$?"

# =============================================================================
# (G) Scope-creep guards (no UX-6 broad help cleanup; no banner; no Ctrl+C)
# =============================================================================

# G1: No banner cleanup in our diff-target files
for f in "$_sbin_nftban" "$_cmd_firewall_logs" "$_cmd_update" "$_cmd_version"; do
    if grep -qiE 'banner.*pollut|banner.*cleanup|Ctrl\+C.*warning' "$f"; then
        _t_assert "G1: scope-creep banner/ctrl-c wording found in $(basename "$f")" 1
        G1_FAIL=1
        break
    fi
done
[[ -z "${G1_FAIL:-}" ]] && _t_assert "G1: no banner/Ctrl+C overhaul wording in UX-5 surfaces" 0

# G2: No exit-code documentation sweep added in these files (cmd_update.sh
# already had an EXIT CODES block pre-V127; assert the V127 SEE ALSO block
# was added but exit-code section wasn't expanded)
_pre=$(grep -c '^EXIT CODES:$' "$_cmd_update" || true)
[[ "$_pre" == "1" ]]
_t_assert "G2: cmd_update.sh still has exactly one EXIT CODES block (no sweep)" "$?"

# G3: No new top-level commands added to dispatcher canonical list as
# side-effect of UX-5
_canonical_count=$(_nftban_canonical_commands | grep -v '^$' | wc -l)
[[ "$_canonical_count" -ge 50 ]] && [[ "$_canonical_count" -le 80 ]]
_t_assert "G3: canonical command list has $_canonical_count entries (sane bound 50-80)" "$?"

# =============================================================================
# (H) Suricata work absent (we are PR-E, not PR-D)
# =============================================================================

# H1: cmd_modes.sh / nftban_help.sh NOT in the UX-5 diff intent — verify
# our edit didn't accidentally touch them
for f in cmd_modes.sh nftban_help.sh; do
    if git diff --name-only HEAD 2>/dev/null | grep -q "$f"; then
        _t_assert "H1: scope-creep: $f modified in UX-5 diff" 1
        H1_FAIL=1
        break
    fi
done
[[ -z "${H1_FAIL:-}" ]] && _t_assert "H1: UX-5 diff does not touch UX-4 surfaces (modes/help)" 0

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "==============================================================================="
echo "V127 UX-5 test summary: ${TESTS_PASSED} PASS, ${TESTS_FAILED} FAIL"
echo "==============================================================================="
if [[ "$TESTS_FAILED" -gt 0 ]]; then
    echo "Failed tests:"
    for name in "${FAILED_NAMES[@]}"; do
        echo "  - $name"
    done
    exit 1
fi
exit 0
