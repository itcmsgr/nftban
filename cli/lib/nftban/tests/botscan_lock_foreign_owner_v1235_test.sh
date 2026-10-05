#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.235 - BotScan scan lock survives a lock file the unit user cannot write
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="botscan_lock_foreign_owner_v1235_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-05"
# meta:description="BUG-BOTSCAN-PROCESSOR-LOCK-POISONED-BY-ROOT-INVOCATION. A manual root run of the BotScan processor or collector leaves /run/nftban/botscan-processor.lock root:root 0644; the units run User=nftban, so a write open of the lock failed with EACCES and (processor, errexit) every later cycle aborted before scanning, while the collector silently dropped scanner mutual exclusion. The lock is modelled as a file the running user cannot write (mode 0444). Arms: P1 the processor still runs its scan; P2 a held lock still excludes the processor (the read-only fallback keeps flock semantics); P3 the processor does not unlink the lock file on exit; C1 the collector takes the lock instead of proceeding without it; C2 a held lock still makes the collector skip. P1 and C1 FAIL on 631b649b. Root ignores file permission bits: under root the test re-runs itself as uid 65534 via setpriv, and is NOT_EXECUTED (exit 3) only if that user cannot read the subjects."
# meta:inventory.files="botscan_lock_foreign_owner_v1235_test.sh"
# meta:inventory.binaries="bash,flock,mktemp,chmod,sleep,kill,setpriv"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# meta:ta.id="botscan_lock_foreign_owner_v1235_test"
# meta:ta.owner="botscan"
# meta:ta.module="botscan"
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
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../../../.." && pwd)"
PROCESSOR="$REPO/cli/sbin/nftban-botscan-processor"
COLLECTOR="$REPO/cli/sbin/nftban-botscan-collector"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

echo "=== v1.235 BotScan lock: unwritable (root-left) lock file ==="

for b in flock bash; do
    command -v "$b" >/dev/null 2>&1 || { echo "  NOT_EXECUTED: '$b' not available"; echo "RESULT: NOT_EXECUTED"; exit 3; }
done
[[ -f "$PROCESSOR" && -f "$COLLECTOR" ]] || { echo "  NOT_EXECUTED: subject scripts not found"; echo "RESULT: NOT_EXECUTED"; exit 3; }
if [[ "$(id -u)" -eq 0 ]]; then
    # root ignores file permission bits, so mode 0444 cannot model the unit user's EACCES.
    # Re-run this test as uid/gid 65534 when that user can read the subjects; else NOT_EXECUTED.
    SELF="$TEST_DIR/$(basename -- "${BASH_SOURCE[0]}")"
    if command -v setpriv >/dev/null 2>&1 \
       && setpriv --reuid=65534 --regid=65534 --clear-groups \
            test -r "$SELF" -a -r "$PROCESSOR" -a -r "$COLLECTOR" -a -r "$REPO/cli/lib/nftban/lib/nftban_http_logs.sh" 2>/dev/null; then
        exec setpriv --reuid=65534 --regid=65534 --clear-groups env HOME=/tmp TMPDIR=/tmp bash "$SELF"
    fi
    echo "  NOT_EXECUTED: running as root bypasses DAC and uid 65534 cannot read the subjects"
    echo "RESULT: NOT_EXECUTED"; exit 3
fi

WORK="$(mktemp -d)"
HOLDER_PID=""
cleanup(){ [[ -n "$HOLDER_PID" ]] && kill "$HOLDER_PID" 2>/dev/null || true; chmod -R u+w "$WORK" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

LOCK="$WORK/botscan-processor.lock"
# Stub library for the processor: only nftban_botscan_check is called after sourcing.
mkdir -p "$WORK/stublib/core"
printf '%s\n' 'nftban_botscan_check(){ echo "STUB_SCAN_RAN"; return 0; }' > "$WORK/stublib/core/nftban_botscan.sh"

# Collector fixtures (same pattern as botscan_spool_oom_v2093_test.sh).
ALLOW="$WORK/logs"; SPOOL="$WORK/spool"; OFF="$WORK/off"; STATUS="$WORK/spool.status"
mkdir -p "$ALLOW"

make_unwritable_lock(){ rm -f "$LOCK"; : > "$LOCK"; chmod 0444 "$LOCK"; }

run_processor(){
    env NFTBAN_LIB_DIR="$WORK/stublib" BOTSCAN_SCAN_LOCK_FILE="$LOCK" \
        BOTSCAN_SCAN_BUDGET_SECS=5 bash "$PROCESSOR" 2>&1
}
run_collector(){
    env NFTBAN_LIB_DIR="$REPO/cli/lib/nftban" \
        BOTSCAN_SPOOL_DIR="$SPOOL" BOTSCAN_SPOOL_STATUS_FILE="$STATUS" \
        BOTSCAN_SCAN_LOCK_FILE="$LOCK" NFTBAN_BOTSCAN_COLLECTOR_OFFSET_DIR="$OFF" \
        NFTBAN_BOTSCAN_COLLECTOR_ALLOW_ROOTS="$ALLOW" BOTSCAN_LOG_PATHS="$ALLOW/*.log" \
        bash "$COLLECTOR" 2>&1
}

# hold_lock: take the lock from a separate process and wait until it is observably held.
hold_lock(){
    # The holder IS the process that owns the descriptor (exec sleep), so killing
    # HOLDER_PID really releases the lock. `flock -c 'sleep …' &` would leave a sleep
    # child holding it after the flock parent is killed.
    ( exec 7<"$LOCK"; flock -x 7; exec sleep 30 ) &
    HOLDER_PID=$!
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        if ! flock -n "$LOCK" -c true 2>/dev/null; then return 0; fi
        sleep 0.1
    done
    return 1
}
release_lock(){ [[ -n "$HOLDER_PID" ]] && kill "$HOLDER_PID" 2>/dev/null || true; wait "$HOLDER_PID" 2>/dev/null || true; HOLDER_PID=""; }

# ---- precondition: the model really is unwritable for this user -------------
make_unwritable_lock
if { exec 8>>"$LOCK"; } 2>/dev/null; then
    exec 8>&-
    echo "  NOT_EXECUTED: a 0444 file is still writable for this user — model invalid"
    echo "RESULT: NOT_EXECUTED"; exit 3
fi
ok "precondition: lock file is not writable by the running user (models root:root 0644 vs User=nftban)"

# ---- P1 · processor runs its scan despite the unwritable lock -----------------
make_unwritable_lock
p1_rc=0; p1_out="$(run_processor)" || p1_rc=$?
if [[ "$p1_rc" -eq 0 && "$p1_out" == *STUB_SCAN_RAN* ]]; then
    ok "P1 processor acquired the lock read-only and ran the scan (rc=0)"
else
    no "P1 processor did not run the scan with an unwritable lock" "rc=$p1_rc out=${p1_out//$'\n'/ | }"
fi

# ---- P3 · processor leaves the lock file in place -----------------------------
if [[ -e "$LOCK" ]]; then
    ok "P3 processor did not unlink the lock file on exit"
else
    no "P3 lock file was removed on exit (unlink race: a second process can lock a fresh file)"
fi

# ---- P2 · a held lock still excludes the processor ----------------------------
make_unwritable_lock
if hold_lock; then
    p2_rc=0; p2_out="$(run_processor)" || p2_rc=$?
    release_lock
    if [[ "$p2_rc" -eq 0 && "$p2_out" == *"Another instance running"* && "$p2_out" != *STUB_SCAN_RAN* ]]; then
        ok "P2 held lock excludes the processor (no scan; clean skip)"
    else
        no "P2 processor ignored a held lock" "rc=$p2_rc out=${p2_out//$'\n'/ | }"
    fi
else
    release_lock
    no "P2 harness could not establish a held lock" "precondition failed"
fi

# ---- C1 · collector takes the lock instead of dropping mutual exclusion ------
make_unwritable_lock
c1_rc=0; c1_out="$(run_collector)" || c1_rc=$?
if [[ "$c1_out" == *"cannot open scan lock"* ]]; then
    no "C1 collector dropped scanner mutual exclusion on an unwritable lock" "out=${c1_out//$'\n'/ | }"
else
    ok "C1 collector opened the unwritable lock (no 'cannot open scan lock'; rc=$c1_rc)"
fi

# ---- C2 · a held lock still makes the collector skip --------------------------
make_unwritable_lock
if hold_lock; then
    c2_rc=0; c2_out="$(run_collector)" || c2_rc=$?
    release_lock
    if [[ "$c2_out" == *"scan in progress (lock held)"* ]]; then
        ok "C2 held lock makes the collector skip the cycle (rc=$c2_rc)"
    else
        no "C2 collector did not honour a held lock" "out=${c2_out//$'\n'/ | }"
    fi
else
    release_lock
    no "C2 harness could not establish a held lock" "precondition failed"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -eq 0 ]]; then echo "RESULT: PASS"; exit 0; fi
echo "RESULT: FAIL"; exit 1
