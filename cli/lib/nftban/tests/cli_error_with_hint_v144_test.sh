#!/usr/bin/env bash
# =============================================================================
# NFTBan - _v144_error_with_hint UX-C2 migration test (v1.144.0 PR-B)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cli_error_with_hint_v144_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-01"
# meta:description="v1.144.0 PR-B — asserts UX-C2 wall-of-text-on-error-paths closure. (1) The _v144_error_with_hint helper exists in lib/cmd_common.sh, exports cleanly, and emits at most 3 stderr lines (ERROR/Hint/Run). (2) The six top-priority cmd_*.sh files migrated their unknown-subcommand/option catch-all parse-error path to call _v144_error_with_hint instead of show_usage: cmd_config.sh, cmd_status.sh, cmd_test.sh, cmd_whitelist_system.sh, cmd_update.sh, cmd_feeds.sh. (3) show_usage (or equivalent help block) is still printed on explicit --help paths in those files — only the error path migrated. (4) Helper rc-contract: default rc=1; rc override via \$4. (5) Helper honors no-content fields: if \$2 (hint) or \$3 (runhelp) is empty, that line is omitted. Hermetic — sources only cmd_common.sh and runs the helper directly; no daemon, no nft."
# meta:input="cli/lib/nftban/lib/cmd_common.sh, cli/lib/nftban/cli/cmd_config.sh, cli/lib/nftban/cli/cmd_status.sh, cli/lib/nftban/cli/cmd_test.sh, cli/lib/nftban/cli/cmd_whitelist_system.sh, cli/lib/nftban/cli/cmd_update.sh, cli/lib/nftban/cli/cmd_feeds.sh"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep,wc"
# meta:inventory.files="cli/lib/nftban/lib/cmd_common.sh,cli/lib/nftban/cli/cmd_config.sh,cli/lib/nftban/cli/cmd_status.sh,cli/lib/nftban/cli/cmd_test.sh,cli/lib/nftban/cli/cmd_whitelist_system.sh,cli/lib/nftban/cli/cmd_update.sh,cli/lib/nftban/cli/cmd_feeds.sh"
# meta:inventory.binaries="bash,grep,wc"
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
COMMON="$REPO/cli/lib/nftban/lib/cmd_common.sh"

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s (%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

# ──────────────────────────────────────────────────────────────────────────
# Section 1: helper definition + export
# ──────────────────────────────────────────────────────────────────────────
[[ -f "$COMMON" ]] || { echo "FAIL: missing $COMMON"; exit 1; }

# T1-1: function _v144_error_with_hint exists
if grep -nE '^_v144_error_with_hint\(\)' "$COMMON" >/dev/null 2>&1; then
    ok "T1-1: _v144_error_with_hint() function defined in cmd_common.sh"
else
    no "T1-1: _v144_error_with_hint() function defined in cmd_common.sh" \
       "no definition found"
fi

# T1-2: helper is exported
if grep -nE '^export -f _v144_error_with_hint\b' "$COMMON" >/dev/null 2>&1; then
    ok "T1-2: _v144_error_with_hint is exported"
else
    no "T1-2: _v144_error_with_hint is exported" "no export line found"
fi

# ──────────────────────────────────────────────────────────────────────────
# Section 2: helper runtime behavior — source cmd_common.sh and exercise it
# ──────────────────────────────────────────────────────────────────────────
# Set up a minimal env so cmd_common.sh sources cleanly. It does an automatic
# init via cmd_init which may try to set up paths — provide safe defaults.
export NFTBAN_LIB_DIR="$REPO/cli/lib/nftban"
export NFTBAN_NONINTERACTIVE=1
# shellcheck source=/dev/null
source "$COMMON" 2>/dev/null || true

# T2-1: helper is callable in this shell
if declare -f _v144_error_with_hint >/dev/null 2>&1; then
    ok "T2-1: _v144_error_with_hint callable after sourcing cmd_common.sh"
else
    no "T2-1: _v144_error_with_hint callable after sourcing cmd_common.sh" \
       "function not loaded"
fi

# T2-2: default rc = 1
out=""; rc=0
out=$(_v144_error_with_hint "test err" "test hint" "test run" 2>&1) || rc=$?
if [[ "$rc" == "1" ]]; then
    ok "T2-2: default rc=1 on _v144_error_with_hint call"
else
    no "T2-2: default rc=1 on _v144_error_with_hint call" "got rc=$rc"
fi

# T2-3: rc override via \$4
out=""; rc=0
out=$(_v144_error_with_hint "test err" "" "" 2 2>&1) || rc=$?
if [[ "$rc" == "2" ]]; then
    ok "T2-3: rc override via \$4 = 2"
else
    no "T2-3: rc override via \$4 = 2" "got rc=$rc"
fi

# T2-4: ERROR line is the only required output (Hint/Run omitted on empty)
out=""; rc=0
out=$(_v144_error_with_hint "only err" "" "" 2>&1) || rc=$?
line_count=$(printf '%s\n' "$out" | wc -l)
if [[ "$line_count" == "1" ]] && [[ "$out" == "ERROR: only err" ]]; then
    ok "T2-4: ERROR-only mode emits exactly 1 line"
else
    no "T2-4: ERROR-only mode emits exactly 1 line" "got $line_count line(s): '$out'"
fi

# T2-5: with hint only, 2 lines
out=""; rc=0
out=$(_v144_error_with_hint "e1" "h1" "" 2>&1) || rc=$?
line_count=$(printf '%s\n' "$out" | wc -l)
if [[ "$line_count" == "2" ]]; then
    ok "T2-5: with hint only emits exactly 2 lines"
else
    no "T2-5: with hint only emits exactly 2 lines" "got $line_count line(s)"
fi

# T2-6: with runhelp only (skip hint), 2 lines
out=""; rc=0
out=$(_v144_error_with_hint "e1" "" "r1" 2>&1) || rc=$?
line_count=$(printf '%s\n' "$out" | wc -l)
if [[ "$line_count" == "2" ]]; then
    ok "T2-6: with runhelp only (no hint) emits exactly 2 lines"
else
    no "T2-6: with runhelp only (no hint) emits exactly 2 lines" "got $line_count line(s)"
fi

# T2-7: full 3-line emit
out=""; rc=0
out=$(_v144_error_with_hint "e1" "h1" "r1" 2>&1) || rc=$?
line_count=$(printf '%s\n' "$out" | wc -l)
if [[ "$line_count" == "3" ]]; then
    ok "T2-7: full ERROR/Hint/Run emits exactly 3 lines"
else
    no "T2-7: full ERROR/Hint/Run emits exactly 3 lines" "got $line_count line(s)"
fi

# T2-8: emission is to stderr only (stdout is empty on full 3-line call)
stdout=$(_v144_error_with_hint "e1" "h1" "r1" 2>/dev/null) || true
if [[ -z "$stdout" ]]; then
    ok "T2-8: emission is stderr-only (stdout empty)"
else
    no "T2-8: emission is stderr-only (stdout empty)" "got stdout='$stdout'"
fi

# T2-9: at most 3 lines on a 3-arg call (wall-of-text upper-bound contract)
out=$(_v144_error_with_hint "abc" "def" "ghi" 2>&1) || true
line_count=$(printf '%s\n' "$out" | wc -l)
if [[ "$line_count" -le 3 ]]; then
    ok "T2-9: wall-of-text upper bound — ≤3 lines on any 3-arg call"
else
    no "T2-9: wall-of-text upper bound — ≤3 lines on any 3-arg call" "got $line_count lines"
fi

# ──────────────────────────────────────────────────────────────────────────
# Section 3: top-six cmd_*.sh files have migrated their catch-all error path
# ──────────────────────────────────────────────────────────────────────────
for cmd_file in \
    "$REPO/cli/lib/nftban/cli/cmd_config.sh" \
    "$REPO/cli/lib/nftban/cli/cmd_status.sh" \
    "$REPO/cli/lib/nftban/cli/cmd_test.sh" \
    "$REPO/cli/lib/nftban/cli/cmd_whitelist_system.sh" \
    "$REPO/cli/lib/nftban/cli/cmd_update.sh" \
    "$REPO/cli/lib/nftban/cli/cmd_feeds.sh"; do
    name=$(basename "$cmd_file")
    if grep -nE '_v144_error_with_hint' "$cmd_file" >/dev/null 2>&1; then
        ok "T3: $name migrated at least one error path to _v144_error_with_hint"
    else
        no "T3: $name migrated at least one error path to _v144_error_with_hint" \
           "no call site found in $name"
    fi
done

# ──────────────────────────────────────────────────────────────────────────
# Section 4: show_usage is preserved for explicit --help paths
# ──────────────────────────────────────────────────────────────────────────
# cmd_config.sh, cmd_status.sh, cmd_test.sh, cmd_whitelist_system.sh all
# have a `help|-h|--help)` arm that calls show_usage. Assert at least one
# non-comment, non-function-definition `show_usage` invocation remains
# (i.e. only the function definition + a help-arm call), proving the
# migration touched the error arm but left the help arm intact.
for cmd_file in \
    "$REPO/cli/lib/nftban/cli/cmd_config.sh" \
    "$REPO/cli/lib/nftban/cli/cmd_status.sh" \
    "$REPO/cli/lib/nftban/cli/cmd_test.sh" \
    "$REPO/cli/lib/nftban/cli/cmd_whitelist_system.sh"; do
    name=$(basename "$cmd_file")
    # Match `show_usage` invocations only (the bare token followed by EOL,
    # a single space + arg, or a redirection — but NOT preceded by a `#`
    # comment marker and NOT the `show_usage() {` definition line).
    call_count=$(grep -nE '^\s*show_usage\b' "$cmd_file" | grep -vE 'show_usage\(\)' | wc -l)
    if [[ "$call_count" -ge 1 ]]; then
        ok "T4: $name preserves at least one show_usage call (help arm intact)"
    else
        no "T4: $name preserves at least one show_usage call (help arm intact)" \
           "found $call_count non-definition show_usage invocations"
    fi
done

# ──────────────────────────────────────────────────────────────────────────
# Section 5: UX-C5 — cmd_update.sh advertises that --dry-run is not supported
# ──────────────────────────────────────────────────────────────────────────
UPD="$REPO/cli/lib/nftban/cli/cmd_update.sh"

# T5-1: help block mentions --dry-run + the document-the-asymmetry shape
if grep -nE 'dry-run is NOT supported' "$UPD" >/dev/null 2>&1; then
    ok "T5-1: cmd_update.sh help advertises '--dry-run is NOT supported' (UX-C5 documented shape)"
else
    no "T5-1: cmd_update.sh help advertises '--dry-run is NOT supported' (UX-C5 documented shape)" \
       "no --dry-run note found in help block"
fi

# T5-2: help block points to nftban update check / list / status as preview alternatives
if grep -nE 'nftban update check\b' "$UPD" | grep -qE 'is an update available'; then
    ok "T5-2: cmd_update.sh help points to update check/list/status as preview alternatives"
else
    no "T5-2: cmd_update.sh help points to update check/list/status as preview alternatives" \
       "no preview-alternative note found"
fi

# ──────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────
echo
echo "═══════════════════════════════════════════════════════════════"
echo "  cli_error_with_hint_v144_test results: ${PASS} PASS / ${FAIL} FAIL"
echo "═══════════════════════════════════════════════════════════════"

if [[ $FAIL -gt 0 ]]; then
    echo "Failed tests:"
    for f in "${FAILED[@]}"; do
        echo "  - $f"
    done
    exit 1
fi

exit 0
