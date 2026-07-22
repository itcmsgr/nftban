#!/usr/bin/env bash
# =============================================================================
# NFTBan - rollback --help guard test (v1.139.2 hotfix)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="rollback_help_guard_v1_139_2_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-28"
# meta:description="v1.139.2 hotfix test — asserts that `nftban rollback --help`, `nftban rollback -h`, and `nftban rollback help` show help text and DO NOT trigger a real rollback. Prior to v1.139.2, the dispatcher in cmd_update.sh passed args through unparsed and the four call sites of _do_rollback (top-level rollback alias + github/git/local sub-modes) all invoked the rollback worker regardless of --help. A CLI-audit invocation tripped the bug in production and downgraded a host. Defense-in-depth: this test verifies the guard is at the _do_rollback function entry (cmd_update_backup.sh), so any current OR future caller is safe. Hermetic — no host contact."
# meta:input="cli/lib/nftban/cli/cmd_update_backup.sh, cli/lib/nftban/cli/cmd_update.sh"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep,awk"
# meta:inventory.files="cli/lib/nftban/cli/cmd_update_backup.sh,cli/lib/nftban/cli/cmd_update.sh"
# meta:inventory.binaries="bash,grep,awk"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="rollback_help_guard_v1_139_2_test"
# meta:ta.owner="update"
# meta:ta.module="rollback"
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

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../../../.." && pwd)
SRC_BACKUP="$REPO/cli/lib/nftban/cli/cmd_update_backup.sh"
SRC_UPDATE="$REPO/cli/lib/nftban/cli/cmd_update.sh"

[[ -f "$SRC_BACKUP" ]] || { echo "FAIL: cannot find $SRC_BACKUP" >&2; exit 1; }
[[ -f "$SRC_UPDATE" ]] || { echo "FAIL: cannot find $SRC_UPDATE" >&2; exit 1; }

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s (%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

echo "=========================================================="
echo "V1.139.2 hotfix: rollback --help guard test"
echo "=========================================================="

# -----------------------------------------------------------------------------
# Source-code structural asserts.
# -----------------------------------------------------------------------------
echo "--- source-code structural asserts ---"

# T1: _rollback_help() helper exists in cmd_update_backup.sh
grep -qE '^_rollback_help\(\)' "$SRC_BACKUP" \
    && ok "T1 _rollback_help() helper defined in cmd_update_backup.sh" \
    || no "T1 _rollback_help() helper defined in cmd_update_backup.sh" "missing"

# T2: the help-arg loop appears in source AND precedes the rollback worker.
# Authority: the guard MUST execute before "Looking for backups" (the work marker).
LOOP_LINE=$(awk 'index($0, "for arg in \"$@\"") > 0 { print NR; exit }' "$SRC_BACKUP")
WORK_LINE=$(awk 'index($0, "_update_log INFO \"Looking for backups") > 0 { print NR; exit }' "$SRC_BACKUP")
if [[ -n "$LOOP_LINE" && -n "$WORK_LINE" ]] && (( LOOP_LINE < WORK_LINE )); then
    ok "T2 help-guard loop (line $LOOP_LINE) precedes the rollback worker (line $WORK_LINE)"
else
    no "T2 help-guard loop precedes the rollback worker" "loop=${LOOP_LINE:-MISSING} work=${WORK_LINE:-MISSING}"
fi

# T3: every user-dispatcher call to _do_rollback in cmd_update.sh passes "$@".
# We require: for every line that calls `_do_rollback` AS A STATEMENT (not
# inside `declare -f`, not inside a pipeline that reads its stdout for history,
# not the "_do_rollback not available" error message), the call site must
# include `"$@"`. The four known user-facing sites are at lines ~2391/2413/2435/2466.
BAD=$(grep -nE '_do_rollback' "$SRC_UPDATE" \
        | grep -v 'declare -f' \
        | grep -v '_do_rollback not available' \
        | grep -v '_do_rollback 2>&1 | while IFS' \
        | grep -v '_do_rollback comment\|v1\.139\.2:' \
        | grep -vE '_do_rollback "\$@"' \
        | grep -vE ':\s+#' || true)
if [[ -z "$BAD" ]]; then
    ok "T3 every user-dispatcher call to _do_rollback passes \"\$@\""
else
    no "T3 every user-dispatcher call to _do_rollback passes \"\$@\"" "bare calls remain:
$BAD"
fi

# -----------------------------------------------------------------------------
# Runtime simulation.
# -----------------------------------------------------------------------------
echo "--- runtime simulation ---"

# Run the inner test in a subshell. Source path passed via env var so the
# single-quoted heredoc body doesn't get prematurely expanded.
export SRC_BACKUP

INNER_OUT=$(bash <<'BASHTEST' 2>&1
set -euo pipefail
# Stub upstream helpers that _do_rollback uses
_update_log(){ :; }
_fix_broken_dpkg(){ :; }
_remove_immutable_flags(){ :; }
UPDATE_BACKUP_DIR=/nonexistent-test-dir-do-not-create

. "$SRC_BACKUP"

test_one(){
    local label="$1"; shift
    local out rc=0
    out=$(_do_rollback "$@" 2>&1) || rc=$?
    if (( rc == 0 )) \
        && [[ "$out" == *"nftban rollback"* ]] \
        && [[ "$out" != *"Looking for backups"* ]]; then
        printf 'PASS %s\n' "$label"
    else
        printf 'FAIL %s rc=%s\n' "$label" "$rc"
    fi
}

test_one "T4 _do_rollback --help"           --help
test_one "T5 _do_rollback -h"               -h
test_one "T6 _do_rollback help"             help
test_one "T7 _do_rollback rollback --help"  rollback --help
test_one "T8 _do_rollback --foo --help --bar" --foo --help --bar
test_one "T9 _do_rollback rollback -h"      rollback -h

# T10: no-arg path REACHES worker (returns non-zero because UPDATE_BACKUP_DIR
# does not exist) — guard must NOT block the legitimate no-arg invocation.
out=$(_do_rollback 2>&1 || true)
rc=$?
if [[ "$out" != *"nftban rollback —"* ]]; then
    printf 'PASS T10 _do_rollback no-arg reaches worker (does not take help path)\n'
else
    printf 'FAIL T10 _do_rollback no-arg unexpectedly took help path\n'
fi
BASHTEST
)

while IFS= read -r line; do
    case "$line" in
        PASS\ *) ok "${line#PASS }" ;;
        FAIL\ *) no "${line#FAIL }" "runtime" ;;
        *)       [[ -n "$line" ]] && printf '    %s\n' "$line" || true ;;
    esac
done <<<"$INNER_OUT"

echo "=========================================================="
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
if (( FAIL > 0 )); then
    printf 'FAILED: %s\n' "${FAILED[@]}"
    exit 1
fi
echo "ALL PASS"
