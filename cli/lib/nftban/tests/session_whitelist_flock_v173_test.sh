#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.173 §4.1 session-whitelist flock (shell side)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="session_whitelist_flock_v173_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-11"
# meta:description="Locks the v1.173 §4.1 shell side: the three session-whitelist read-modify-write funcs in cmd_firewall.sh (_whitelist_session_add/remove/cleanup) each serialize their RMW under flock(9) on the shared cross-language lock \$_NFTBAN_SESSION_WL_LOCK (= /run/nftban/session_whitelist.lock, the SAME path the Go installer flock(2)s) so a concurrent Go \`nftban update\` and a CLI write can't lose an update. (1) the lock var + data path are defined and overridable; (2) each func opens fd 9 on the shared lock and runs its mv (atomic rename) while the lock is held; (3) a behavioral flock-mechanism check proves flock(1) actually serializes concurrent appenders (the real funcs gate on root, so the full shell∥Go behavioral race is a lab step). Hermetic: static source assertions + a temp-file flock mechanism check; no root, no /run, no nft."
# meta:input="None (reads cmd_firewall.sh; temp file for the mechanism check)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,awk,grep,flock"
# meta:inventory.files="cli/lib/nftban/cli/cmd_firewall.sh"
# meta:inventory.binaries="flock"
# meta:inventory.env_vars="_NFTBAN_SESSION_WL_LOCK,_NFTBAN_SESSION_WHITELIST_PATH"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
FW="$REPO_ROOT/cli/lib/nftban/cli/cmd_firewall.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

[[ -f "$FW" ]] || { echo "cmd_firewall.sh not found at $FW"; exit 1; }

echo "== Part A: lock + path vars defined and overridable =="
grep -qE '_NFTBAN_SESSION_WL_LOCK="\$\{_NFTBAN_SESSION_WL_LOCK:-/run/nftban/session_whitelist\.lock\}"' "$FW" \
  && ok "A1 shared lock var = /run/nftban/session_whitelist.lock (overridable)" \
  || no "A1 shared lock var" "missing/changed"
grep -qE '_NFTBAN_SESSION_WHITELIST_PATH="\$\{_NFTBAN_SESSION_WHITELIST_PATH:-/etc/nftban/whitelist\.d/00-session\.conf\}"' "$FW" \
  && ok "A2 session path overridable" || no "A2 session path overridable" "missing/changed"

echo "== Part B: each RMW func locks the full read-modify-write =="
# Extract a function body (from `name() {` to the matching closing brace at col 0).
func_body(){ awk -v fn="$1" '
  $0 ~ "^"fn"\\(\\) \\{" {inf=1}
  inf {print}
  inf && /^\}/ {exit}
' "$FW"; }

for fn in _whitelist_session_add _whitelist_session_remove _whitelist_session_cleanup; do
  body="$(func_body "$fn")"
  if [[ -z "$body" ]]; then no "B:$fn body" "not found"; continue; fi
  has_flock=0; has_fd=0; has_mv=0; has_ensure=0
  grep -qE 'flock 9' <<<"$body" && has_flock=1
  grep -qE '9>"\$_NFTBAN_SESSION_WL_LOCK"' <<<"$body" && has_fd=1
  grep -qE 'mv "\$tmp" "\$_NFTBAN_SESSION_WHITELIST_PATH"' <<<"$body" && has_mv=1
  grep -qE '_whitelist_session_ensure_lock' <<<"$body" && has_ensure=1
  if [[ $has_flock -eq 1 && $has_fd -eq 1 && $has_mv -eq 1 && $has_ensure -eq 1 ]]; then
    ok "B $fn: ensures 0600 lock + RMW (mv) under flock 9 on the shared lock"
  else
    no "B $fn: flock-wrapped RMW" "flock=$has_flock fd=$has_fd mv=$has_mv ensure=$has_ensure"
  fi
done

echo "== Part B2: ensure-lock helper forces 0600 (cross-language parity with Go) =="
grep -qE 'chmod 0600 "\$_NFTBAN_SESSION_WL_LOCK"' "$FW" \
  && ok "B2a helper chmod 0600 present" || no "B2a helper chmod 0600" "missing"

echo "== Part C: flock(1) actually serializes concurrent appenders (mechanism) =="
if ! command -v flock >/dev/null 2>&1; then
  echo "  (skip C: flock(1) not available)"
else
  WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
  lock="$WORK/lock"; out="$WORK/out"; : > "$out"
  # 30 concurrent appenders, each does read-count→append under the same flock.
  # Under a correct lock the final line count is exactly 30 (no lost update);
  # without it, racing read-modify-append would drop lines.
  app(){ ( flock 9; n=$(wc -l < "$out"); printf 'line-%s\n' "$((n+1))" >> "$out" ) 9>"$lock"; }
  pids=()
  for _ in $(seq 1 30); do app & pids+=("$!"); done
  for p in "${pids[@]}"; do wait "$p"; done
  got=$(wc -l < "$out"); got=${got//[^0-9]/}
  [[ "$got" == "30" ]] && ok "C flock serialized 30 concurrent RMW appenders (no lost update)" \
    || no "C flock mechanism" "expected 30 lines, got $got"

  echo "== Part D: the REAL ensure-lock helper creates the lock at 0600 =="
  # eval the actual helper definition from cmd_firewall.sh and run it against a
  # temp lock; assert mode 0600 even under a group-readable umask (027 → 0640).
  eval "$(awk '/^_whitelist_session_ensure_lock\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$FW")"
  if declare -f _whitelist_session_ensure_lock >/dev/null 2>&1; then
    ( umask 027
      _NFTBAN_SESSION_WL_LOCK="$WORK/parity.lock" _whitelist_session_ensure_lock )
    mode=$(stat -c '%a' "$WORK/parity.lock" 2>/dev/null)
    [[ "$mode" == "600" ]] && ok "D ensure-lock created the lock at 0600 (parity with Go 0o600)" \
      || no "D lock mode parity" "expected 600, got '$mode'"
  else
    no "D ensure-lock helper" "could not extract/eval helper"
  fi
fi

echo ""
echo "=== RESULT: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
