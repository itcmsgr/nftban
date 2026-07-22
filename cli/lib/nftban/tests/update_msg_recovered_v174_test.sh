#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.174 update-summary messaging (recovered transparency + DEGRADED text)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="update_msg_recovered_v174_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-12"
# meta:description="Locks the v1.174 user-facing update messaging in cmd_update.sh. (A) the this-run-scoped recovered-unit detection pipeline (tail from the pre-install installer.log line count → grep WARN_PRE_EXISTING_RECOVERED → extract reset-failed unit names) detects a recovery in this run and stays silent for a prior-run-only marker. (B) message contract: the COMMITTED branch surfaces a guarded ℹ️ 'pre-existing failed unit ... cleared automatically. No action is required' note (quiet when none); the DEGRADED branch no longer says 'known transient on the exporter' and instead says it may be a current OR stale pre-existing failure and to run nftban health + --repair. Hermetic: synthetic installer.log + static source assertions; no host."
# meta:input="None (temp installer.log fixture)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,grep,sed,sort,tail"
# meta:inventory.files="cli/lib/nftban/cli/cmd_update.sh"
# meta:inventory.binaries="bash"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="update_msg_recovered_v174_test"
# meta:ta.owner="update"
# meta:ta.module="update"
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
U="$REPO_ROOT/cli/lib/nftban/cli/cmd_update.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
[[ -f "$U" ]] || { echo "cmd_update.sh not found: $U"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# detect() mirrors the exact pipeline in cmd_update.sh's COMMITTED branch; Part B
# statically asserts the source still carries the same pipeline so this can't drift.
detect(){ # <logfile> <before-lines>
  local f="$1" b="$2" u=""
  if [[ -f "$f" ]] && tail -n +$((b + 1)) "$f" 2>/dev/null | grep -q "WARN_PRE_EXISTING_RECOVERED"; then
    u=$(tail -n +$((b + 1)) "$f" 2>/dev/null | sed -n 's/.*reset-failed \([^ ]*\): cleared stale.*/\1/p' | sort -u | tr '\n' ' ')
    u="${u% }"
  fi
  printf '%s' "$u"
}

echo "== Part A: this-run-scoped recovered detection =="
ilog="$WORK/installer.log"
printf 'old line 1\nold line 2\n' > "$ilog"
before=$(wc -l < "$ilog"); before=${before//[^0-9]/}
cat >> "$ilog" <<'EOF'
[NFTBan] ASSERT failed_units_postinstall_ok: PASS — WARN_PRE_EXISTING_RECOVERED (pre-existing failed unit(s), live health clean): nftban-alert@nftband.service.service(exit-code)
[NFTBan] reset-failed nftban-alert@nftband.service.service: cleared stale pre-existing systemd failed-state latch (failure pre-dates the install window; live health clean)
EOF
got=$(detect "$ilog" "$before")
[[ "$got" == "nftban-alert@nftband.service.service" ]] && ok "A1 recovered unit detected this-run" || no "A1 detect" "got '$got'"

# prior-run marker present but BEFORE this run's window → must NOT surface
printf 'WARN_PRE_EXISTING_RECOVERED prior\nreset-failed prior.service: cleared stale x\n' > "$ilog"
before2=$(wc -l < "$ilog"); before2=${before2//[^0-9]/}
printf 'this run: clean, no recovery\n' >> "$ilog"
got2=$(detect "$ilog" "$before2")
[[ -z "$got2" ]] && ok "A2 prior-run marker NOT surfaced (this-run scoped → quiet COMMITTED)" || no "A2 scope" "got '$got2'"

echo "== Part B: cmd_update.sh message contract =="
grep -q '_ilog_before_lines' "$U" && grep -q 'WARN_PRE_EXISTING_RECOVERED' "$U" \
  && ok "B1 this-run recovered detection wired (installer.log line-delta)" || no "B1 detection" "missing"
grep -q 'A pre-existing failed NFTBan unit was found before this upgrade' "$U" \
  && grep -q 'cleared automatically. No action is required' "$U" \
  && ok "B2 recovered transparency message present" || no "B2 recovered msg" "missing"
grep -q 'if \[\[ -n "\$_recovered_units" \]\]; then' "$U" \
  && ok "B3 recovered message GUARDED (quiet when no recovery)" || no "B3 guard" "missing"
if grep -q "known transient on the" "$U"; then no "B4 misleading exporter line" "still present"; else ok "B4 misleading 'known transient on the exporter' removed"; fi
grep -q "may be a CURRENT failure, or a STALE pre-existing" "$U" \
  && ok "B5 DEGRADED reworded (current OR stale pre-existing)" || no "B5 DEGRADED wording" "missing"
grep -q "nftban health" "$U" && ok "B6 DEGRADED suggests nftban health" || no "B6 health hint" "missing"
# v1.222.1 Lane 4: the DEGRADED remediation MUST surface reset-failed, now rendered
# PER STRUCTURED FAILED UNIT from install_state (SERVICES_FAILED), NOT a hardcoded
# nftban-botscan.service (BUG-INSTALLER-FAILED-UNIT-REMEDIATION-HARDCODED-BOTSCAN).
grep -qF 'systemctl reset-failed $_u' "$U" \
  && ok "B7 DEGRADED surfaces structured per-unit reset-failed (v1.222.1)" || no "B7 structured reset-failed" "missing"
grep -qF 'SERVICES_FAILED=' "$U" \
  && ok "B7a DEGRADED reads structured SERVICES_FAILED" || no "B7a SERVICES_FAILED read" "missing"
if grep -q "systemctl reset-failed nftban-botscan.service" "$U"; then
  no "B7b hardcoded botscan remediation removed" "still present"
else
  ok "B7b no hardcoded nftban-botscan.service remediation (v1.222.1 Lane 4)"
fi
grep -q "does NOT clear a stale oneshot failed-state" "$U" \
  && ok "B8 DEGRADED explains --repair alone is insufficient (v1.185.1)" || no "B8 repair-insufficient note" "missing"

echo ""
echo "=== RESULT: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
