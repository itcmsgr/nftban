#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.135 update-lock cleanup (D-UPDATE-LOCK-LEFT-BEHIND)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cmd_update_lock_cleanup_v135_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-27"
# meta:description="Tests for the v1.135 fix that removes /run/nftban/update.lock on every terminal update path. Pre-v1.135 the flock fd was released on process exit but the empty lock file was left behind (observed as a 2-day stale lock on dns2). Verifies: (a) _release_update_lock removes the lock file AND releases the kernel lock (a fresh flock then succeeds), (b) release is idempotent / safe when the file is already absent, (c) the lock file path honors NFTBAN_RUN_DIR, (d) STATIC guards that _cmd_update_main wraps _cmd_update_main_locked and calls _release_update_lock on every terminal path while NOT removing the file on the lock-contention path. Uses NFTBAN_RUN_DIR sandbox override. No host contact; no root required."
# meta:input="None (self-contained sandbox)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,flock,mktemp"
# meta:inventory.files="cli/lib/nftban/cli/cmd_update.sh"
# meta:inventory.binaries="bash,flock,mktemp"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_RUN_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Defect closed:  D-UPDATE-LOCK-LEFT-BEHIND (v1.135 Phase 2)
# Scope file:     AUDIT_190_LIFECYCLE/V135_INSTALL_UPDATE_LIFECYCLE_SCOPE.md §2
# Fix mechanism:  cmd_update.sh splits _cmd_update_main into a lock WRAPPER
#                 (acquire flock fd9 → run _cmd_update_main_locked → release)
#                 and the locked body. _release_update_lock removes the lock
#                 file (while still holding the flock, so no live updater can
#                 exist) then closes fd 9. The lock-contention path closes the
#                 fd but does NOT remove the file (it belongs to the holder).
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
NFTBAN_LIB_DIR="${REPO_ROOT}/cli/lib/nftban"
export NFTBAN_LIB_DIR

SANDBOX=$(mktemp -d)
export NFTBAN_RUN_DIR="$SANDBOX/run"
mkdir -p "$NFTBAN_RUN_DIR"
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0
FAIL=0
FAILED_TESTS=()

assert_eq() {
    local actual="$1" expected="$2" name="$3"
    if [[ "$actual" == "$expected" ]]; then
        printf "  [PASS] %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  [FAIL] %s (expected '%s', got '%s')\n" "$name" "$expected" "$actual"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    fi
}

CMD_UPDATE="${NFTBAN_LIB_DIR}/cli/cmd_update.sh"

echo "=========================================================="
echo "V135 D-UPDATE-LOCK-LEFT-BEHIND — lock cleanup test"
echo "=========================================================="

# ---------------------------------------------------------------------------
# BEHAVIORAL — source cmd_update.sh (NFTBAN_RUN_DIR points at the sandbox so
# UPDATE_LOCK_FILE resolves under it) and drive the real helpers. We run these
# in a subshell because cmd_update.sh sets `set -Eeuo pipefail` and has a
# one-shot load guard.
# ---------------------------------------------------------------------------

# CASE 1: _release_update_lock removes the lock file.
result=$(
    # shellcheck source=/dev/null
    source "$CMD_UPDATE"
    exec 9>"$UPDATE_LOCK_FILE"
    flock -n 9 || { echo "ACQUIRE_FAILED"; exit 0; }
    [[ -f "$UPDATE_LOCK_FILE" ]] || { echo "NO_FILE_AFTER_ACQUIRE"; exit 0; }
    _release_update_lock
    if [[ -e "$UPDATE_LOCK_FILE" ]]; then echo "STILL_PRESENT"; else echo "REMOVED"; fi
)
assert_eq "$result" "REMOVED" "behav_1_release_removes_lock_file"

# CASE 2: after release the kernel lock is gone — a fresh flock succeeds.
result=$(
    # shellcheck source=/dev/null
    source "$CMD_UPDATE"
    exec 9>"$UPDATE_LOCK_FILE"; flock -n 9 || { echo "ACQUIRE1_FAILED"; exit 0; }
    _release_update_lock
    # Re-acquire from scratch — must succeed (lock truly released).
    exec 8>"$UPDATE_LOCK_FILE"
    if flock -n 8; then echo "REACQUIRED"; else echo "STILL_LOCKED"; fi
    flock -u 8; exec 8>&-
)
assert_eq "$result" "REACQUIRED" "behav_2_release_frees_kernel_lock"

# CASE 3: release is idempotent / safe when file already absent.
result=$(
    # shellcheck source=/dev/null
    source "$CMD_UPDATE"
    rm -f "$UPDATE_LOCK_FILE"
    _release_update_lock && echo "OK" || echo "ERRORED"
    [[ -e "$UPDATE_LOCK_FILE" ]] && echo "EXISTS" || echo "ABSENT"
)
assert_eq "$result" $'OK\nABSENT' "behav_3_release_idempotent_when_absent"

# CASE 4: UPDATE_LOCK_FILE honors NFTBAN_RUN_DIR.
result=$(
    # shellcheck source=/dev/null
    source "$CMD_UPDATE"
    echo "$UPDATE_LOCK_FILE"
)
assert_eq "$result" "${NFTBAN_RUN_DIR}/update.lock" "behav_4_lock_path_honors_run_dir"

# CASE 5: while the lock is HELD, a second non-blocking flock fails (contention
# is real — proves the wrapper's "another update in progress" branch can trip).
result=$(
    # shellcheck source=/dev/null
    source "$CMD_UPDATE"
    exec 9>"$UPDATE_LOCK_FILE"; flock -n 9 || { echo "ACQUIRE_FAILED"; exit 0; }
    # Second holder in a sub-subshell attempts non-blocking lock on same file.
    if ( exec 7>"$UPDATE_LOCK_FILE"; flock -n 7 ); then
        echo "SECOND_ACQUIRED"   # would be a bug
    else
        echo "SECOND_BLOCKED"    # correct
    fi
    _release_update_lock
)
assert_eq "$result" "SECOND_BLOCKED" "behav_5_held_lock_blocks_second_acquire"

# ---------------------------------------------------------------------------
# STATIC — wiring guards on the production source (cheap, durable regressions).
# ---------------------------------------------------------------------------
echo
echo "--- static wiring guards ---"

# s1: wrapper delegates to the locked inner body.
if grep -q "_cmd_update_main_locked \"\$source\" \"\$arg\"" "$CMD_UPDATE"; then
    assert_eq "wired" "wired" "static_s1_wrapper_calls_locked_body"
else
    assert_eq "missing" "wired" "static_s1_wrapper_calls_locked_body"
fi

# s2: wrapper releases the lock after the body (single canonical release call).
if grep -q "_cmd_update_main_locked \"\$source\" \"\$arg\" || _update_rc=\$?" "$CMD_UPDATE" \
   && grep -qE "^\s*_release_update_lock\s*$" "$CMD_UPDATE"; then
    assert_eq "wired" "wired" "static_s2_wrapper_releases_after_body"
else
    assert_eq "missing" "wired" "static_s2_wrapper_releases_after_body"
fi

# s3: lock-contention path closes fd but does NOT call _release_update_lock
#     (must not remove a live updater's file). Verify the contention branch
#     uses `exec 9>&-` and not `_release_update_lock`.
contention_block=$(awk '/Another update is in progress/{f=1} f{print} /return 1/{if(f){exit}}' "$CMD_UPDATE")
if grep -q "exec 9>&-" <<<"$contention_block" \
   && ! grep -q "_release_update_lock" <<<"$contention_block"; then
    assert_eq "safe" "safe" "static_s3_contention_path_does_not_remove_holders_file"
else
    assert_eq "unsafe" "safe" "static_s3_contention_path_does_not_remove_holders_file"
fi

# s4: _release_update_lock removes the file BEFORE closing fd 9 (hold-then-rm
#     ordering — strongest no-clobber guarantee).
release_fn=$(awk '/^_release_update_lock\(\) \{/{f=1} f{print} /^\}/{if(f){exit}}' "$CMD_UPDATE")
rm_line=$(grep -n "rm -f \"\$UPDATE_LOCK_FILE\"" <<<"$release_fn" | head -1 | cut -d: -f1)
close_line=$(grep -n "exec 9>&-" <<<"$release_fn" | head -1 | cut -d: -f1)
if [[ -n "$rm_line" && -n "$close_line" && "$rm_line" -lt "$close_line" ]]; then
    assert_eq "ordered" "ordered" "static_s4_release_rm_before_close"
else
    assert_eq "unordered" "ordered" "static_s4_release_rm_before_close"
fi

echo
echo "=========================================================="
echo "Results: $PASS passed, $FAIL failed"
echo "=========================================================="
if (( FAIL > 0 )); then
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do
        echo "  - $t"
    done
    exit 1
fi
echo "All v1.135 update-lock cleanup tests passed."
exit 0
