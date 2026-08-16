#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.229.3 P0-J — SHELL REBUILD PARTICIPATES IN THE CANONICAL nft LOCK
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="rebuild-nft-lock-participation-v1229-3-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-16"
# meta:description="Proves the shell firewall rebuild acquires the canonical /run/nftban/nft_operations.lock declared by internal/nftlock before mutating the kernel, refuses to mutate when the lock is held by another owner, and releases it on every exit path including failure. Guards the authority-closure gap where Go mutators (reconciliation, OpQueue, botguard) serialized on that lock while the shell rebuild mutated the kernel holding nothing."
# meta:inventory.files="cli/lib/nftban/cli/cmd_firewall.sh,internal/nftlock/lock.go"
# meta:inventory.privileges="none"
# meta:ta.id="rebuild_nft_lock_participation_v1229_3_test"
# meta:ta.owner="firewall"
# meta:ta.module="firewall"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
#
# PROVEN GAP THIS GUARDS (v1.229.2 b62ecf53):
#   internal/nftlock/lock.go:44 declares /run/nftban/nft_operations.lock as the
#   canonical lock for ALL nft operations and states Go and shell share it.
#   Go honoured it: daemon_reconciliation.go + opqueue/queue.go AcquireExclusive,
#   botguard/suspect.go AcquireShared. The shell rebuild did NOT -- it ran
#   `nft delete table` and `nft -f "$load_conf"` holding nothing, so it could
#   interleave with reconciliation and the queue drain.
#
# The wrapper is tested in ISOLATION: the 731-line core is stubbed, so these
# arms bind to the serialization contract and nothing else.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="$SCRIPT_DIR/../cli/cmd_firewall.sh"
FAIL=0
pass(){ echo "  PASS  $1"; }
fail(){ echo "  FAIL  $1"; FAIL=1; }

echo "=== rebuild nft-lock participation (v1.229.3 P0-J) ==="

[[ -f "$SUBJECT" ]] || { echo "  SUBJECT_NOT_FOUND: $SUBJECT"; exit 1; }
command -v flock >/dev/null || { echo "  TEST_INVALID: flock(1) unavailable in the test environment"; exit 1; }

# --- extract ONLY the wrapper, so the arms cannot accidentally bind elsewhere ---
WRAPPER="$(awk '/^_firewall_rebuild_serialized\(\) \{/,/^\}/' "$SUBJECT")"
if [[ -z "$WRAPPER" ]]; then
    echo "  SUBJECT_NOT_FOUND: _firewall_rebuild_serialized wrapper not located"; exit 1
fi
if ! grep -q 'nft_operations.lock' <<<"$WRAPPER"; then
    fail "wrapper does not reference the canonical nft_operations.lock"
else
    pass "wrapper binds to the canonical lock path"
fi
# --- DRIFT GUARD: the shell path MUST equal internal/nftlock's canonical const ---
# Without this, the two authorities could silently diverge into two different locks
# while every other arm in this file still passed.
NFTLOCK_GO="$SCRIPT_DIR/../../../../internal/nftlock/lock.go"
if [[ ! -f "$NFTLOCK_GO" ]]; then
    fail "SUBJECT_NOT_FOUND: internal/nftlock/lock.go — cannot bind shell path to the Go authority"
else
    GO_PATH="$(sed -n 's/^const LockPath = "\(.*\)"$/\1/p' "$NFTLOCK_GO" | head -1)"
    if [[ -z "$GO_PATH" ]]; then
        fail "SUBJECT_NOT_FOUND: LockPath const not parsed from internal/nftlock/lock.go"
    else
        # the shell default must resolve to exactly the Go constant
        SHELL_DEFAULT="$(sed -n 's/.*_nftlock_path="\${NFTBAN_RUN_DIR:-\([^}]*\)}\(.*\)".*/\1\2/p' <<<"$WRAPPER" | head -1)"
        if [[ "$SHELL_DEFAULT" == "$GO_PATH" ]]; then
            pass "shell lock path == internal/nftlock canonical const ($GO_PATH)"
        else
            fail "LOCK PATH DRIFT: shell resolves to '$SHELL_DEFAULT', Go declares '$GO_PATH'"
        fi
    fi
fi

if grep -qE 'nft_lock\.sh' <<<"$WRAPPER"; then
    fail "wrapper references the deleted orphan module lib/nft_lock.sh"
else
    pass "no resurrection of the deleted orphan lock module"
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export NFTBAN_RUN_DIR="$TMP/run"
mkdir -p "$NFTBAN_RUN_DIR"
LOCK="$NFTBAN_RUN_DIR/nft_operations.lock"

# stub inner core: records that it ran, and whether it saw the lock held
CORE_RAN="$TMP/core_ran"
eval "$WRAPPER"
_firewall_rebuild_core() { echo "ran" > "$CORE_RAN"; return "${STUB_RC:-0}"; }

# --- ARM C/A: lock held by another owner -> REFUSE, inner core NEVER runs -------
rm -f "$CORE_RAN"
exec 7>"$LOCK"; flock 7            # simulate the Go holder (reconciliation/OpQueue)
NFTBAN_TIMEOUT_NFT_LOCK=1 _firewall_rebuild_serialized >"$TMP/out" 2>&1
rc=$?
exec 7>&-
if [[ $rc -ne 0 ]]; then pass "held lock -> rebuild returns non-zero (REFUSED)"
else fail "held lock -> rebuild returned 0"; fi
if [[ ! -f "$CORE_RAN" ]]; then pass "held lock -> inner core NEVER ran (zero nft mutation)"
else fail "inner core ran while the lock was held by another owner"; fi
if grep -qi "was NOT modified" "$TMP/out"; then pass "refusal states the firewall was not modified"
else fail "refusal message does not state that nothing was mutated"; fi

# --- ARM E: lock free -> proceeds ---------------------------------------------
rm -f "$CORE_RAN"
STUB_RC=0 _firewall_rebuild_serialized >/dev/null 2>&1
rc=$?
if [[ $rc -eq 0 && -f "$CORE_RAN" ]]; then pass "free lock -> rebuild proceeds and returns inner rc"
else fail "free lock -> rebuild did not proceed (rc=$rc)"; fi

# --- ARM D: failure path still releases the lock -------------------------------
rm -f "$CORE_RAN"
STUB_RC=7 _firewall_rebuild_serialized >/dev/null 2>&1
rc=$?
if [[ $rc -eq 7 ]]; then pass "inner failure rc is propagated unchanged"
else fail "inner rc not propagated (got $rc, want 7)"; fi
# if the lock leaked, this non-blocking acquisition fails
if flock -n "$LOCK" true 2>/dev/null; then pass "lock RELEASED after inner failure path"
else fail "lock LEAKED after a failing rebuild — later operations would deadlock"; fi

# --- ARM B: while the shell holds it, another owner cannot take it -------------
( eval "$WRAPPER"
  _firewall_rebuild_core() { flock -n "$LOCK" true 2>/dev/null && echo "NOT_HELD" > "$TMP/held" || echo "HELD" > "$TMP/held"; return 0; }
  _firewall_rebuild_serialized >/dev/null 2>&1 )
if [[ "$(cat "$TMP/held" 2>/dev/null)" == "HELD" ]]; then
    pass "lock is genuinely HELD for the duration of the inner core"
else
    fail "lock was NOT held while the core ran — serialization is cosmetic"
fi

# --- ARM F (inversion falsifiability): a wrapper without flock must fail ARM C --
cat > "$TMP/bypass.sh" <<'BYP'
_firewall_rebuild_serialized() { _firewall_rebuild_core "$@"; }
BYP
rm -f "$CORE_RAN"
( source "$TMP/bypass.sh"
  _firewall_rebuild_core() { echo ran > "$CORE_RAN"; return 0; }
  exec 7>"$LOCK"; flock 7
  _firewall_rebuild_serialized >/dev/null 2>&1
  exec 7>&- )
if [[ -f "$CORE_RAN" ]]; then
    pass "inversion: a lock-bypassing wrapper DOES mutate under a held lock (arm C is falsifiable)"
else
    fail "inversion did not reproduce the defect — arm C may be vacuous"
fi

echo
if [[ $FAIL -eq 0 ]]; then echo "RESULT: PASS"; exit 0; fi
echo "RESULT: FAIL"; exit 1
