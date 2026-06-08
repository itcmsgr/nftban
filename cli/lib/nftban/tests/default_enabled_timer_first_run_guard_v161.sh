#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.161: default-enabled-timer first-run CI guard
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="default_enabled_timer_first_run_guard_v161"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-08"
# meta:description="Hermetic CI guard for the geoban first-run lesson (v1.156->v1.159, TEST_LESSON_GEOBAN_REFRESH_V159): every timer the installer auto-enables (coreTimers in internal/installer/services/timers.go) must, on a package-default host, EITHER have an ExecStart whose binaries are all shipped/always-present OR carry an ExecCondition that SKIPS (condition-not-met => unit skipped, NOT failed) when an optional/unshipped dependency is absent. A default-enabled timer whose .service hard-fails on first run flips INSTALL_STATE=DEGRADED fleet-wide (the v1.156 nftban-geoban-refresh regression, which needed the unshipped nftban-geoip helper). This guard enumerates the default-enabled timers (grepped read-only from timers.go coreTimers, cross-checked against install/systemd/*.timer), resolves each timer's .service, extracts ExecStart, and FAILS if a default-enabled service could hard-fail with an optional dep absent and has no ExecCondition gate. Repo-static: no systemd, no host, no network, no privileges."
# meta:input="None (reads install/systemd/* and internal/installer/services/timers.go from the repo)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, non-zero on any default-enabled timer that can hard-fail on first run"
# meta:depends="bash,grep,sed,awk"
# meta:inventory.files="internal/installer/services/timers.go,install/systemd/nftban-geoban-refresh.service"
# meta:inventory.binaries="bash,grep,sed,awk"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units="nftban-maintenance.timer,nftban-health.timer,nftban-unified-exporter.timer,nftban-core-geoip.timer,nftban-core-feeds.timer,nftban-watchdog.timer,nftban-queue.timer,nftban-update-check.timer,nftban-geoban-refresh.timer"
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
TIMERS_GO="$REPO_ROOT/internal/installer/services/timers.go"
SYSTEMD_DIR="$REPO_ROOT/install/systemd"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

[[ -f "$TIMERS_GO" ]]   || { echo "timers.go not found: $TIMERS_GO"; exit 1; }
[[ -d "$SYSTEMD_DIR" ]] || { echo "systemd dir not found: $SYSTEMD_DIR"; exit 1; }

# --- 1. Enumerate the default-enabled timers (coreTimers) ---------------------
# Read-only grep of the `coreTimers = []string{ ... }` block in timers.go. We do
# NOT edit Go; we only extract the quoted timer-unit names from that one block.
core_timers="$(awk '
  /^var coreTimers = \[\]string\{/ {grab=1; next}
  grab && /^\}/ {grab=0}
  grab {
    if (match($0, /"([^"]+\.timer)"/)) {
      s=substr($0, RSTART+1, RLENGTH-2); print s
    }
  }
' "$TIMERS_GO")"

[[ -n "$core_timers" ]] || { echo "could not extract coreTimers from $TIMERS_GO"; exit 1; }

echo "=== default-enabled (coreTimers) timers ==="
n_timers=0
while IFS= read -r t; do
  [[ -n "$t" ]] || continue
  n_timers=$((n_timers+1))
  echo "  - $t"
done <<< "$core_timers"
if [[ "$n_timers" -ge 1 ]]; then
  ok "enumerated $n_timers default-enabled timers"
else
  no "no default-enabled timers enumerated"
fi

# --- 2. Helper: is an ExecStart binary shipped / always-present? --------------
# A binary is "safe" if it is a base-OS binary that systemd-managed hosts always
# have, OR an nftban-shipped path. Anything else is treated as a possibly-absent
# optional dependency and therefore REQUIRES an ExecCondition gate.
#
# Shipped nftban paths (staged by packaging/build_nftban.sh / the Go installer):
#   /usr/sbin/nftban                     (cli/sbin/nftban)
#   /usr/lib/nftban/bin/nftban-core      (built Go binary)
#   /usr/lib/nftban/sbin/*               (cli/sbin helper scripts)
#   /usr/lib/nftban/cron/*, exporters/*  (cp -r of cli/lib/nftban/*)
# Base-OS binaries treated as always-present: flock, sh, bash, env.
is_shipped_bin(){
  local b="$1"
  case "$b" in
    /usr/bin/flock|/bin/sh|/usr/bin/sh|/bin/bash|/usr/bin/bash|/usr/bin/env) return 0 ;;
    /usr/sbin/nftban) return 0 ;;
    /usr/lib/nftban/bin/nftban-core) return 0 ;;
    /usr/lib/nftban/sbin/*) return 0 ;;
    /usr/lib/nftban/cron/*) return 0 ;;
    /usr/lib/nftban/exporters/*) return 0 ;;
    /usr/lib/nftban/helpers/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Subcommands whose RUNTIME work needs an OPTIONAL (not base-package) dependency,
# even though the launching binary itself ships. The geoban lesson: the launcher
# /usr/sbin/nftban ships, but `geoip refresh` needs the unshipped nftban-geoip
# helper, so the service MUST gate it with an ExecCondition. Extend this list if
# a future default-enabled service grows an optional-dep subcommand.
needs_execcondition_subcmd(){
  local execline="$1"
  case "$execline" in
    *"nftban geoip "*) return 0 ;;   # geoip refresh/update path needs the helper
    *) return 1 ;;
  esac
}

# --- 3. Per-timer assessment -------------------------------------------------
echo "=== per-timer first-run safety ==="
while IFS= read -r timer; do
  [[ -n "$timer" ]] || continue
  svc="${timer%.timer}.service"
  svc_path="$SYSTEMD_DIR/$svc"

  if [[ ! -f "$svc_path" ]]; then
    no "$timer -> $svc missing" "default-enabled timer with no shipped .service"
    continue
  fi

  # Collect ExecStart lines (a oneshot may have several) and any ExecCondition.
  mapfile -t exec_starts < <(grep -E '^ExecStart=' "$svc_path" || true)
  has_cond="no"
  grep -qE '^ExecCondition=' "$svc_path" && has_cond="yes"

  if [[ "${#exec_starts[@]}" -eq 0 ]]; then
    no "$svc has no ExecStart" "cannot assess first-run behaviour"
    continue
  fi

  unsafe="no"; reason=""
  for line in "${exec_starts[@]}"; do
    # Strip "ExecStart=" and any leading '-'/'+'/'@'/':' systemd prefixes.
    cmd="${line#ExecStart=}"
    cmd="${cmd#[-+@:!]}"; cmd="${cmd#[-+@:!]}"
    # First token = the binary path actually exec'd.
    bin="${cmd%% *}"

    # Unwrap flock: `/usr/bin/flock -n <lockpath> <realbin> ...` -> realbin.
    if [[ "$bin" == "/usr/bin/flock" ]]; then
      # tokenise; the first token after the lock-path that starts with / is the bin.
      # shellcheck disable=SC2206
      toks=($cmd)
      bin=""
      for ((i=1; i<${#toks[@]}; i++)); do
        case "${toks[$i]}" in
          -*) continue ;;                 # flock options (-n etc.)
          /run/*|/var/*|/tmp/*) continue ;; # the lock file path
          /*) bin="${toks[$i]}"; break ;;
        esac
      done
      [[ -n "$bin" ]] || bin="${cmd%% *}"
    fi

    # Unwrap `sh -c` / `bash -c` wrappers: the launcher ships; the real concern is
    # the optional-dep subcommand, caught by needs_execcondition_subcmd below.
    if ! is_shipped_bin "$bin"; then
      unsafe="yes"; reason="ExecStart binary not shipped/always-present: $bin"
    fi

    # Optional-dependency subcommand requires an ExecCondition gate.
    if needs_execcondition_subcmd "$cmd" && [[ "$has_cond" == "no" ]]; then
      unsafe="yes"
      reason="optional-dep subcommand (\"$cmd\") with NO ExecCondition gate"
    fi
  done

  if [[ "$unsafe" == "yes" ]]; then
    no "$timer -> $svc CAN hard-fail on first run" "$reason"
  else
    if [[ "$has_cond" == "yes" ]]; then
      ok "$timer -> $svc safe (ExecCondition gate present)"
    else
      ok "$timer -> $svc safe (all ExecStart deps shipped/always-present)"
    fi
  fi
done <<< "$core_timers"

# --- 4. Anchor assertion: the geoban regression stays fixed ------------------
# nftban-geoban-refresh is the canonical first-run-DEGRADE case; assert it is in
# the default-enabled set AND carries an ExecCondition (defence against a future
# edit that drops the v1.159 gate while leaving the timer auto-enabled).
geoban_svc="$SYSTEMD_DIR/nftban-geoban-refresh.service"
if grep -q "nftban-geoban-refresh.timer" <<< "$core_timers"; then
  if grep -qE '^ExecCondition=' "$geoban_svc"; then
    ok "anchor: nftban-geoban-refresh auto-enabled AND gated by ExecCondition (v1.159 fix intact)"
  else
    no "anchor: nftban-geoban-refresh auto-enabled but ExecCondition gate MISSING" "v1.159 regression"
  fi
else
  # If it is no longer auto-enabled the regression class is moot for it; just note.
  ok "anchor: nftban-geoban-refresh not in coreTimers (first-run-DEGRADE class N/A for it)"
fi

echo "================================================================"
echo "default_enabled_timer_first_run_guard_v161: PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[[ $FAIL -eq 0 ]]
