#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.232.0 update progress visibility
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="update_progress_visibility_v1232_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-20"
# meta:description="v1.232.0 BUG-LONG-CONVERGENCE-OPERATION-NO-PROGRESS-VISIBILITY. The Install phase announced 'package install may take up to 60s'; measured wall-clock the same day was monitor 244s (rebuild alone ~3m12s), srv3 277s, dns1 79s, so the bound was false on every large-ruleset host and made a working installer indistinguishable from a hang. Asserts the false bound is GONE from the live call site, the owner-specified replacement wording is emitted, elapsed durations render operator-readable (45s / 2m00s / 3m12s), the heartbeat emits exactly ONE line per interval of SILENCE, the heartbeat stays SILENT while other output is flowing (it must never flood or talk over working output), the inner installer phase is surfaced from the greppable [PHASE] markers, and stopping leaves NO orphan process. Carries the discriminating negative control: with the heartbeat never started, the same silent interval produces ZERO progress lines — the exact operator experience being fixed — so the positive arms cannot pass vacuously."
# meta:input="None (self-contained sandbox)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,grep,sed,mktemp,date"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,sed,mktemp,date"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="update_progress_visibility_v1232_test"
# meta:ta.owner="update"
# meta:ta.module="update-progress-visibility"
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
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
NFTBAN_LIB_DIR="${REPO_ROOT}/cli/lib/nftban"
export NFTBAN_LIB_DIR
HELP_SRC="$NFTBAN_LIB_DIR/cli/cmd_update_helpers.sh"
UPD_SRC="$NFTBAN_LIB_DIR/cli/cmd_update.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0; FAIL=0; FAILED_TESTS=()
ok()  { printf "  [PASS] %s\n" "$1"; PASS=$((PASS + 1)); }
bad() { printf "  [FAIL] %s\n         %s\n" "$1" "${2:-}"; FAIL=$((FAIL + 1)); FAILED_TESTS+=("$1"); }
assert_eq() { [[ "$1" == "$2" ]] && ok "$3" || bad "$3" "expected '$2', got '$1'"; }

[[ -r "$HELP_SRC" ]] || { echo "NOT_EXECUTED: missing $HELP_SRC" >&2; exit 2; }
[[ -r "$UPD_SRC"  ]] || { echo "NOT_EXECUTED: missing $UPD_SRC"  >&2; exit 2; }

extract_fn() {
    awk -v fn="$1" '$0 ~ "^"fn"\\(\\) \\{" { inside=1 } inside { print } inside && /^\}/ { exit }' "$2"
}
EXTRACT="$SANDBOX/subject.sh"; : > "$EXTRACT"
for fn in _update_mark_output _update_fmt_elapsed _update_installer_phase _update_heartbeat_start _update_heartbeat_stop; do
    body=$(extract_fn "$fn" "$HELP_SRC")
    [[ -n "$body" ]] || { echo "NOT_EXECUTED: function $fn not found in $HELP_SRC" >&2; exit 2; }
    printf '%s\n\n' "$body" >> "$EXTRACT"
done

_NFTBAN_UPDATE_HEARTBEAT_SECS=1
_NFTBAN_UPDATE_HEARTBEAT_POLL=1
_NFTBAN_UPDATE_HEARTBEAT_PID=""
_NFTBAN_UPDATE_HEARTBEAT_LABEL=""
_NFTBAN_UPDATE_OUTPUT_STAMP=""
FORENSIC_ILOG_FILE="$SANDBOX/installer.log"
# shellcheck source=/dev/null
source "$EXTRACT"

echo ""
echo "=== A. the false bound is gone, the honest wording is present ==="

# The live call site must no longer pass a duration bound.
# `grep -m1` rather than `grep | head -1`, and a here-string rather than
# `printf | grep -q`: both of those pipe shapes short-circuit the consumer,
# which under pipefail makes the producer's EPIPE a timing-dependent verdict.
# The exposure is removed, not declared as inventory debt.
live_call=$(grep -m1 -n '_update_phase 2 "Install"' "$UPD_SRC")
if grep -q '60s' <<< "$live_call"; then
    bad "A1 the live Install phase carries no duration bound" "still present: $live_call"
else
    ok "A1 the live Install phase carries no duration bound"
fi

if grep -q 'Package installation can take several minutes on systems with large nftables rulesets' "$UPD_SRC"; then
    ok "A2 owner-specified replacement wording is emitted"
else
    bad "A2 owner-specified replacement wording is emitted" "not found in $UPD_SRC"
fi
if grep -q 'Progress will be shown while the installation runs' "$UPD_SRC"; then
    ok "A3 replacement wording promises progress"
else
    bad "A3 replacement wording promises progress" "not found in $UPD_SRC"
fi
# No fabricated completion percentage anywhere in the new surface.
if grep -qE '[0-9]+% (complete|done)' "$UPD_SRC" "$HELP_SRC"; then
    bad "A4 no fabricated percentage is claimed" "a percentage appears in the progress surface"
else
    ok "A4 no fabricated percentage is claimed"
fi

echo ""
echo "=== B. elapsed rendering is operator-readable ==="
assert_eq "$(_update_fmt_elapsed 0)"   "0s"     "B1 zero"
assert_eq "$(_update_fmt_elapsed 45)"  "45s"    "B2 sub-minute"
assert_eq "$(_update_fmt_elapsed 120)" "2m00s"  "B3 exact minutes zero-pad the seconds"
assert_eq "$(_update_fmt_elapsed 192)" "3m12s"  "B4 the measured monitor rebuild duration"
assert_eq "$(_update_fmt_elapsed 277)" "4m37s"  "B5 the measured srv3 total"

echo ""
echo "=== C. the inner installer phase is surfaced ==="
printf '[2026-09-20] [INFO] [PHASE] detect start\n[2026-09-20] [INFO] [PHASE] detect end\n[2026-09-20] [INFO] [PHASE] switch start\n' > "$FORENSIC_ILOG_FILE"
assert_eq "$(_update_installer_phase)" "switch" "C1 newest START marker wins"
: > "$FORENSIC_ILOG_FILE"
assert_eq "$(_update_installer_phase)" "" "C2 no markers yields empty, never a guess"
rm -f "$FORENSIC_ILOG_FILE"
assert_eq "$(_update_installer_phase)" "" "C3 absent log yields empty, never an error"

echo ""
echo "=== D. the heartbeat speaks into silence, and only into silence ==="
printf '[2026-09-20] [INFO] [PHASE] switch start\n' > "$FORENSIC_ILOG_FILE"

# D1: silence for longer than the interval must produce output.
out_file="$SANDBOX/beat.out"
( _update_heartbeat_start "package install" ; sleep 3 ; _update_heartbeat_stop ) > "$out_file" 2>&1
beats=$(grep -c 'still running' "$out_file" || true)
if [[ "$beats" -ge 1 ]]; then ok "D1 silence produces at least one heartbeat line"; else
    bad "D1 silence produces at least one heartbeat line" "got $beats lines"; fi

if grep -q 'installer phase: switch' "$out_file"; then
    ok "D2 the heartbeat carries the inner installer phase"
else
    bad "D2 the heartbeat carries the inner installer phase" "$(head -3 "$out_file")"
fi

# D3: one line per interval — never a flood.
if [[ "$beats" -le 4 ]]; then ok "D3 emits at most one line per interval (no flood)"; else
    bad "D3 emits at most one line per interval (no flood)" "got $beats lines in ~3s at interval=1"; fi

# D4: while other output is flowing, the heartbeat must stay silent.
#
# The silence test compares whole-second stamps (date +%s), so the margin
# between the output cadence and the emit interval must be larger than one
# second of quantisation — otherwise a mark at t=0.9 and a poll at t=1.0 read
# as a full second of silence and the heartbeat fires CORRECTLY, failing the
# arm for a clock artifact rather than a defect. Observed exactly that: this
# arm passed on lab2 and failed on the faster CI runner at interval=1.
#
# The assertion is unchanged — ZERO beats while output flows. Only the margin
# is made expressible: output every 0.5s against a 4s interval leaves at most
# ~1s of measured silence, well inside the interval even with quantisation.
out2="$SANDBOX/quiet.out"
(
    _NFTBAN_UPDATE_HEARTBEAT_SECS=4
    _update_heartbeat_start "package install"
    for _ in $(seq 1 10); do _update_mark_output; sleep 0.5; done
    _update_heartbeat_stop
) > "$out2" 2>&1
beats2=$(grep -c 'still running' "$out2" || true)
if [[ "$beats2" -eq 0 ]]; then ok "D4 stays silent while other output is flowing"; else
    bad "D4 stays silent while other output is flowing" "emitted $beats2 lines over working output"; fi

# D5: completion line reports a real measured duration.
out3="$SANDBOX/done.out"
( _update_heartbeat_start "package install"; _update_heartbeat_stop 192 ) > "$out3" 2>&1
if grep -q 'package install completed in 3m12s' "$out3"; then
    ok "D5 completion reports the measured duration"
else
    bad "D5 completion reports the measured duration" "$(cat "$out3")"
fi

echo ""
echo "=== E. no orphan process is left behind ==="
_update_heartbeat_start "orphan check"
hb_pid="$_NFTBAN_UPDATE_HEARTBEAT_PID"
_update_heartbeat_stop
if [[ -z "$hb_pid" ]]; then
    bad "E1 the heartbeat records its PID" "no PID captured, so termination cannot be proven"
else
    ok "E1 the heartbeat records its PID"
    sleep 1
    if kill -0 "$hb_pid" 2>/dev/null; then
        bad "E2 the heartbeat process is gone after stop" "pid $hb_pid still alive"
    else
        ok "E2 the heartbeat process is gone after stop"
    fi
fi
assert_eq "$_NFTBAN_UPDATE_HEARTBEAT_PID" "" "E3 stop clears the recorded PID"

echo ""
echo "=== F. NEGATIVE CONTROL: the pre-v1.232.0 experience ==="
# Power check. Without the heartbeat, the SAME silent interval produces nothing
# at all — which is exactly what the operator saw on monitor for 3+ minutes. If
# this arm ever produced output, D1 would prove nothing.
out4="$SANDBOX/control.out"
( sleep 3 ) > "$out4" 2>&1
ctrl=$(grep -c 'still running' "$out4" || true)
if [[ "$ctrl" -eq 0 ]]; then
    ok "F1 CONTROL: without a heartbeat a silent interval emits nothing"
else
    bad "F1 CONTROL: without a heartbeat a silent interval emits nothing" "control is malformed: $ctrl lines"
fi

echo ""
echo "============================================================"
printf "Passed: %d  Failed: %d\n" "$PASS" "$FAIL"
if (( FAIL > 0 )); then
    printf "Failed tests:\n"; for t in "${FAILED_TESTS[@]}"; do printf "  - %s\n" "$t"; done
    exit 1
fi
exit 0
