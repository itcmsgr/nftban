#!/usr/bin/env bash
# =============================================================================
# NFTBan - Snapshot source-time dispatch truth (v1.228.2 PR-D)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="snapshot_source_time_dispatch_v1228_2_test"
# meta:type="test"
# meta:version="1.228.2"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-28"
# meta:description="Proves OPEN_SNAPSHOT_SOURCE_TIME_DOUBLE_DISPATCH is closed. Replicates the router dispatch sequence exactly (cli/sbin/nftban:1128 cmd assignment with NO shift, :1236 source with positionals still set, :1242 declare -f, :1243 shift, :1249 call) against an instrumented copy of cmd_snapshot.sh whose acting leaves are counter stubs. T1 asserts sourcing with positional arguments executes zero snapshot actions. T2-T5 assert create/list/help/unknown call counts. T6 is a repository-wide structural guard asserting NO cmd_*.sh executes its command entrypoint merely because it was sourced with positional arguments - derived by scanning every module, never pinned to cmd_snapshot.sh alone. Creates no real snapshot and touches no host state."
# meta:input="repo cli/lib/nftban/cli/cmd_*.sh; self-contained sandbox under mktemp -d"
# meta:output="[PASS]/[FAIL] per assertion; terminal RESULT: PASS|FAIL; exit 0 all pass, 1 any fail"
# meta:depends="bash,mktemp,grep,awk,sed"
# meta:inventory.files="cli/lib/nftban/cli/cmd_snapshot.sh"
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_SNAPSHOT_TEST_LOG"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="snapshot_source_time_dispatch_v1228_2_test"
# meta:ta.owner="cli"
# meta:ta.module="snapshot"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# =============================================================================

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
CLI_DIR="${REPO_ROOT}/cli/lib/nftban/cli"
MODULE="${CLI_DIR}/cmd_snapshot.sh"

PASS=0
FAIL=0

# NOTE: assertions must NOT run inside a ( subshell ) — the counters would be
# incremented in a child process and discarded, and a failing case would report
# success. Every helper below runs in the current shell.
ok()  { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '[FAIL] %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/nftban-snapshot-dispatch.XXXXXX")"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

[[ -f "$MODULE" ]] || { echo "FATAL: module not found: $MODULE" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Instrumented fixture
#
# The three acting leaves are replaced with counter stubs injected immediately
# BEFORE the module's trailing guard, so the guard condition and the dispatch
# logic in nftban_cmd_snapshot stay byte-identical to what ships. Nothing real is
# created; the module itself is never modified in the worktree.
# -----------------------------------------------------------------------------
build_fixture() {
    mkdir -p "${SANDBOX}/cli" "${SANDBOX}/lib"

    cat > "${SANDBOX}/lib/cmd_common.sh" <<'STUB'
#!/usr/bin/env bash
cmd_init() { :; }
nftban_print_status() { :; }
STUB

    local guard_line
    guard_line="$(grep -n 'BASH_SOURCE\[0\]' "$MODULE" | tail -1 | cut -d: -f1)"
    [[ -n "$guard_line" ]] || { echo "FATAL: trailing guard not found in $MODULE" >&2; exit 1; }

    awk -v ln="$guard_line" 'NR==ln{
        print "nftban_snapshot_create() { echo \"CREATE\" >> \"$NFTBAN_SNAPSHOT_TEST_LOG\"; return 0; }";
        print "nftban_snapshot_list()   { echo \"LIST\"   >> \"$NFTBAN_SNAPSHOT_TEST_LOG\"; return 0; }";
        print "nftban_snapshot_help()   { echo \"HELP\"   >> \"$NFTBAN_SNAPSHOT_TEST_LOG\"; return 0; }";
    }{print}' "$MODULE" > "${SANDBOX}/cli/cmd_snapshot.sh"
}

# Replicates cli/sbin/nftban main() for the source+entrypoint path, verbatim:
#   :1128  local cmd="${1:-hello}"   (NO shift before the source)
#   :1236  source "$cmd_file"        (positionals still set)
#   :1242  declare -f  :1243 shift  :1249 call
router_replica() {
    local cmd="${1:-hello}"
    cmd="${cmd,,}"
    local cmd_file="${NFTBAN_LIB_DIR}/cli/cmd_${cmd}.sh"
    if [[ -f "$cmd_file" ]]; then
        # shellcheck source=/dev/null
        source "$cmd_file"
        local func_cmd="${cmd//-/_}"
        if declare -f "nftban_cmd_${func_cmd}" >/dev/null 2>&1; then
            shift
            "nftban_cmd_${func_cmd}" "$@" || return $?
            return 0
        fi
        return 0
    fi
    return 1
}

# Runs one invocation in a FRESH shell — the module sets `readonly
# CMD_SNAPSHOT_LOADED=1` and short-circuits on re-source, so cases must not share
# a shell. Prints "rc create list help". The child is a measurement harness, not
# an assertion site: counters live in the log file, never in a subshell variable.
invoke() {
    local log="${SANDBOX}/log.$RANDOM$RANDOM"
    : > "$log"
    local rc=0
    NFTBAN_LIB_DIR="$SANDBOX" NFTBAN_SNAPSHOT_TEST_LOG="$log" \
        bash "${SANDBOX}/runner.sh" "$@" >/dev/null 2>&1 || rc=$?
    printf '%s %s %s %s\n' \
        "$rc" \
        "$(grep -c '^CREATE' "$log" 2>/dev/null || true)" \
        "$(grep -c '^LIST'   "$log" 2>/dev/null || true)" \
        "$(grep -c '^HELP'   "$log" 2>/dev/null || true)"
    rm -f "$log"
}

build_fixture

# Materialise the router replica as a standalone runner for `invoke`.
{
    printf '#!/usr/bin/env bash\n'
    declare -f router_replica
    printf 'router_replica "$@"\n'
} > "${SANDBOX}/runner.sh"

echo "=== snapshot source-time dispatch truth (v1.228.2 PR-D) ==="

# -----------------------------------------------------------------------------
# T1 — sourcing with positional arguments must execute NOTHING
# This is the defect itself: the shipped guard fired on [[ -n "${1:-}" ]].
# -----------------------------------------------------------------------------
T1_LOG="${SANDBOX}/t1.log"; : > "$T1_LOG"
(
    export NFTBAN_LIB_DIR="$SANDBOX" NFTBAN_SNAPSHOT_TEST_LOG="$T1_LOG"
    # shellcheck source=/dev/null
    source "${SANDBOX}/cli/cmd_snapshot.sh" snapshot create >/dev/null 2>&1 || true
) || true
t1_actions="$(grep -c . "$T1_LOG" || true)"
if [[ "$t1_actions" -eq 0 ]]; then
    ok "T1 sourcing cmd_snapshot.sh WITH arguments executes 0 snapshot actions"
else
    bad "T1 sourcing with arguments executed ${t1_actions} snapshot action(s) — source-time dispatch is back"
fi

# -----------------------------------------------------------------------------
# T2-T5 — end-to-end call counts through the exact router sequence
# -----------------------------------------------------------------------------
read -r rc c l h <<<"$(invoke snapshot create)"
if [[ "$c" -eq 1 && "$l" -eq 0 ]]; then
    ok "T2 'snapshot create' -> create exactly once (create=$c list=$l)"
else
    bad "T2 'snapshot create' -> create=$c list=$l (want create=1 list=0)"
fi

read -r rc c l h <<<"$(invoke snapshot list)"
if [[ "$l" -eq 1 && "$c" -eq 0 ]]; then
    ok "T3 'snapshot list' -> list once, create ZERO (create=$c list=$l)"
else
    bad "T3 'snapshot list' -> create=$c list=$l (want create=0 list=1) — a read-only command must not write"
fi

read -r rc c l h <<<"$(invoke snapshot --help)"
if [[ "$h" -ge 1 && "$c" -eq 0 && "$l" -eq 0 ]]; then
    ok "T4 'snapshot --help' -> help only, create ZERO (help=$h create=$c)"
else
    bad "T4 'snapshot --help' -> help=$h create=$c list=$l (want help>=1 create=0 list=0)"
fi

read -r rc c l h <<<"$(invoke snapshot restore)"
if [[ "$c" -eq 0 && "$l" -eq 0 ]]; then
    ok "T5 'snapshot restore' (unsupported) -> create ZERO (create=$c list=$l rc=$rc)"
else
    bad "T5 'snapshot restore' -> create=$c list=$l (want 0/0) — unsupported action must not mutate"
fi

# -----------------------------------------------------------------------------
# T6 — repository-wide structural guard
#
# Derived by scanning EVERY cmd_*.sh, not pinned to cmd_snapshot.sh, so the
# pattern cannot reappear in another module. A trailing execution guard is only
# acceptable when it is conditioned solely on direct execution
# (BASH_SOURCE[0] == $0). Any guard that also fires on positional arguments —
# `-n "${1:-}"`, `$# -gt 0`, `-n "$*"` — executes the entrypoint at SOURCE time,
# because the router sources modules with the caller's positionals still set.
# -----------------------------------------------------------------------------
offenders=""
scanned=0
while IFS= read -r f; do
    scanned=$((scanned + 1))
    hits="$(grep -nE '^[[:space:]]*if[[:space:]]*\[\[.*BASH_SOURCE\[0\]' "$f" 2>/dev/null || true)"
    [[ -z "$hits" ]] && continue
    while IFS= read -r hit; do
        [[ -z "$hit" ]] && continue
        line="${hit#*:}"
        if printf '%s' "$line" | grep -qE '[-]n[[:space:]]*"[$][{]1:[-][}]"|[$]#[[:space:]]*[-]gt[[:space:]]*0|[-]n[[:space:]]*"[$][*]"'; then
            offenders+="  $(basename "$f"):${hit%%:*}  ${line}"$'\n'
        fi
    done <<< "$hits"
done < <(find "$CLI_DIR" -maxdepth 1 -name 'cmd_*.sh' -type f | sort)

if [[ "$scanned" -eq 0 ]]; then
    bad "T6 scanned 0 modules — enumeration failed, guard proves nothing"
elif [[ -z "$offenders" ]]; then
    ok "T6 no cmd_*.sh executes its entrypoint on being sourced with arguments (${scanned} modules scanned)"
else
    bad "T6 source-time execution guard(s) found in ${scanned} scanned modules:"
    printf '%s' "$offenders" >&2
fi

echo
echo "passed=${PASS} failed=${FAIL}"
if [[ "$FAIL" -gt 0 ]]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
exit 0
