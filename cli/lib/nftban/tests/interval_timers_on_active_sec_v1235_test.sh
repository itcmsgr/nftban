#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.235 - every interval-only timer carries OnActiveSec
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="interval_timers_on_active_sec_v1235_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-05"
# meta:description="BUG-INTERVAL-TIMERS-UNSCHEDULED-AFTER-FRESH-START-ON-LONG-UPTIME (v1.235 T1). A timer with only OnBootSec + OnUnitActiveSec (+ Persistent=true), started on a long-running host after a remove->install, has nothing to fire on: OnBootSec is past and counted as used (the kept stamp file restores a last trigger), and OnUnitActiveSec has no base (the reinstalled service never ran). systemd shows it active with NextElapseUSecMonotonic=infinity until reboot (measured lab3 systemd 257, lab4 systemd 252; mechanism proven with throwaway units). OnActiveSec= counts from timer activation and gives it a first run. Locks: P1 the population is DERIVED from install/systemd/nftban-*.timer (a recurring OnUnitActiveSec/OnUnitInactiveSec trigger and no OnCalendar) and must contain the five timers measured dead (watchdog, queue, unified-exporter, botscan-collector, botscan); One-shot boot timers (OnBootSec only, e.g. nftban-rebuild-recovery.timer) are outside the population by design. A1 every member carries OnActiveSec; A2 OnActiveSec equals that timer's OnBootSec; S1/S2 self-check: a planted interval timer without OnActiveSec FAILS, a planted calendar timer without it does not. Set T1_SUBJECT_ROOT to an older tree (e.g. e79a1173): A1 must FAIL there."
# meta:inventory.files="interval_timers_on_active_sec_v1235_test.sh"
# meta:inventory.binaries="bash,awk,mktemp"
# meta:inventory.env_vars="T1_SUBJECT_ROOT"
# meta:inventory.config_files=""
# meta:inventory.systemd_units="nftban-*.timer"
# meta:inventory.network=""
# meta:inventory.privileges=""
# meta:ta.id="interval_timers_on_active_sec_v1235_test"
# meta:ta.owner="packaging"
# meta:ta.module="systemd-timers"
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
ROOT="${T1_SUBJECT_ROOT:-$REPO}"
UNITS="$ROOT/install/systemd"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

echo "=== v1.235 T1: interval-only timers carry OnActiveSec ==="
[[ -d "$UNITS" ]] || { echo "  NOT_EXECUTED: $UNITS missing"; echo "RESULT: NOT_EXECUTED"; exit 3; }

# key <unit> <Key> -> the [Timer] value of Key (last wins, like systemd), or "".
key(){ awk -v k="$2" '
    /^\[/ { sec = $0; next }
    sec == "[Timer]" && $0 !~ /^[[:space:]]*[#;]/ {
        line = $0; sub(/^[[:space:]]+/, "", line)
        if (index(line, k "=") == 1) v = substr(line, length(k) + 2)
    }
    END { print v }' "$1"; }

# interval_only <unit>: a RECURRING monotonic trigger (OnUnitActiveSec /
# OnUnitInactiveSec) and no calendar trigger. A one-shot boot timer (OnBootSec
# only, e.g. nftban-rebuild-recovery.timer: deferred retry after boot,
# Persistent=false) is deliberately outside: OnActiveSec would make it fire on
# every timer start, which changes what it is for.
interval_only(){
    local f="$1" m
    [[ -n "$(key "$f" OnCalendar)" ]] && return 1
    for m in OnUnitActiveSec OnUnitInactiveSec; do
        [[ -n "$(key "$f" "$m")" ]] && return 0
    done
    return 1
}

# check_dir <dir> -> prints "<unit> <problem>" for each violation; rc 1 if any.
check_dir(){
    local f n bad=0 act boot
    for f in "$1"/*.timer; do
        [[ -e "$f" ]] || continue
        interval_only "$f" || continue
        n="$(basename "$f")"
        act="$(key "$f" OnActiveSec)"; boot="$(key "$f" OnBootSec)"
        if [[ -z "$act" ]]; then
            printf '%s missing OnActiveSec\n' "$n"; bad=1
        elif [[ -n "$boot" && "$act" != "$boot" ]]; then
            printf '%s OnActiveSec=%s differs from OnBootSec=%s\n' "$n" "$act" "$boot"; bad=1
        fi
    done
    return "$bad"
}

# ---- P1 · population, derived -------------------------------------------------------
pop=()
for f in "$UNITS"/nftban-*.timer; do
    [[ -e "$f" ]] || continue
    interval_only "$f" && pop+=("$(basename "$f")")
done
echo "  population (interval-only nftban timers): ${#pop[@]} — $(printf '%s ' "${pop[@]}")"
missing_known=""
for k in nftban-watchdog.timer nftban-queue.timer nftban-unified-exporter.timer \
         nftban-botscan-collector.timer nftban-botscan.timer; do
    found=0
    for p in "${pop[@]}"; do [[ "$p" == "$k" ]] && found=1; done
    [[ "$found" -eq 1 ]] || missing_known+=" $k"
done
[[ -z "$missing_known" ]] && ok "P1 population contains the five timers measured dead on lab3/lab4" \
                          || no "P1 population lost a measured timer (renamed or now calendar?)" "$missing_known"

# ---- A1/A2 · every member carries OnActiveSec == OnBootSec -----------------------------
viol="$(check_dir "$UNITS" || true)"
if [[ -z "$viol" ]]; then
    ok "A1/A2 every interval-only timer has OnActiveSec equal to its OnBootSec"
else
    while IFS= read -r v; do no "A1/A2 $v"; done <<<"$viol"
fi

# ---- S1/S2 · the checker itself --------------------------------------------------------
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
printf '[Timer]\nOnBootSec=1min\nOnUnitActiveSec=5min\nPersistent=true\n' > "$W/planted-interval.timer"
printf '[Timer]\nOnCalendar=daily\nPersistent=true\n' > "$W/planted-calendar.timer"
sv="$(check_dir "$W" || true)"
[[ "$sv" == *"planted-interval.timer missing OnActiveSec"* ]] && ok "S1 planted interval timer without OnActiveSec is caught" \
                                                            || no "S1 checker missed a planted interval timer" "$sv"
[[ "$sv" != *"planted-calendar.timer"* ]] && ok "S2 calendar timer is outside the population" \
                                          || no "S2 calendar timer was flagged" "$sv"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -eq 0 ]]; then echo "RESULT: PASS"; exit 0; fi
echo "RESULT: FAIL"; exit 1
