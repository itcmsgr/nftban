#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.174 HEALTH-OOM-JOURNALCTL guard (shell side)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="health_journalctl_bounded_v174_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-11"
# meta:description="Locks v1.174 HEALTH-OOM-JOURNALCTL: (A) every actual journalctl INVOCATION in the nftban-health.service health-check path (cmd_health.sh + the core/helper modules it sources for `health check --auto-heal`) is BOUNDED (carries -n/--lines or a small --since); advisory hint strings (\`check: journalctl -u ...\`) and the required-binaries probe list are not invocations and are exempt. The Go validator journalctl read (internal/validator/journal.go) is already bounded (--since -15m -n 200) and out of this shell guard. (B) nftban-health.service declares MemoryMax=256M (raised 128M->256M for the validator + concurrent-children RSS on large journals). Hermetic: static source scan; no journalctl run, no root."
# meta:input="None (reads health-path shell modules + nftban-health.service)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,grep,awk"
# meta:inventory.files="cli/lib/nftban/cli/cmd_health.sh,install/systemd/nftban-health.service"
# meta:inventory.binaries="journalctl"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units="nftban-health.service"
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="health_journalctl_bounded_v174_test"
# meta:ta.owner="health"
# meta:ta.module="health-journalctl-bound"
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
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

# Files on the `nftban health check --auto-heal --cache-status` runtime path:
# the dispatcher + the modules it sources + the auto-heal helper.
HEALTH_PATH_FILES=(
  "cli/lib/nftban/cli/cmd_health.sh"
  "cli/lib/nftban/cli/cmd_health_core.sh"
  "cli/lib/nftban/cli/cmd_health_components.sh"
  "cli/lib/nftban/cli/cmd_health_analysis.sh"
  "cli/lib/nftban/core/nftban_health_checks_core.sh"
  "cli/lib/nftban/core/nftban_health_checks_services.sh"
  "cli/lib/nftban/helpers/autoheal.sh"
)

# is_journalctl_invocation: true when a line actually RUNS journalctl, as
# opposed to (a) mentioning it inside a quoted advisory hint like
# `check: journalctl -u nftband.service`, or (b) listing it as a required
# binary token. We treat a line as an invocation only when `journalctl`
# appears as a command word (start of line / after a pipe, `$(`, `;`, `&&`,
# `||`, or `=` for a capture) and NOT preceded on the line by `check:` /
# `check logs:` / `required_binaries`.
echo "== Part A: no UNBOUNDED journalctl invocation on the health-check path =="
unbounded_hits=0
scanned_invocations=0
for rel in "${HEALTH_PATH_FILES[@]}"; do
  f="$REPO_ROOT/$rel"
  [[ -f "$f" ]] || { no "A:$rel present" "missing"; continue; }
  while IFS= read -r line; do
    # skip comments
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    # skip advisory hint strings and the required-binaries probe list
    [[ "$line" == *"check:"* || "$line" == *"check logs:"* ]] && continue
    [[ "$line" == *"required_binaries"* ]] && continue
    # only consider lines where journalctl is a command word
    if [[ "$line" =~ (^|[\|\;\&\(\=\`[:space:]])journalctl([[:space:]]|$) ]]; then
      scanned_invocations=$((scanned_invocations+1))
      # bounded if it carries a line cap or a bounded --since
      if [[ "$line" == *" -n "* || "$line" == *"--lines"* || "$line" == *"--since"* ]]; then
        ok "A bounded invocation in $rel: ${line//[[:space:]]/ }"
      else
        no "A UNBOUNDED journalctl in $rel" "${line}"
        unbounded_hits=$((unbounded_hits+1))
      fi
    fi
  done < "$f"
done
if [[ $scanned_invocations -eq 0 ]]; then
  ok "A no journalctl invocation on the health-check path (only advisory hints / probe list) — nothing to bound"
fi
[[ $unbounded_hits -eq 0 ]] && ok "A no unbounded journalctl invocation on the health-check path" \
  || no "A unbounded journalctl present" "$unbounded_hits hit(s)"

echo "== Part B: nftban-health.service MemoryMax raised to 256M (v1.174 HEALTH-OOM) =="
UNIT="$REPO_ROOT/install/systemd/nftban-health.service"
[[ -f "$UNIT" ]] || { no "B unit present" "missing"; }
if [[ -f "$UNIT" ]]; then
  grep -qE '^MemoryMax=256M[[:space:]]*$' "$UNIT" \
    && ok "B MemoryMax=256M" || no "B MemoryMax=256M" "not set / not 256M"
  grep -qE '^MemoryMax=128M' "$UNIT" \
    && no "B stale 128M still present" "remove old cap" || ok "B no stale MemoryMax=128M"
fi

echo
echo "Result: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
