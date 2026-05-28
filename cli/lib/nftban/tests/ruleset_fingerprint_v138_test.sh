#!/usr/bin/env bash
# =============================================================================
# NFTBan - SEC-RULEFP integration wiring + invariant guard (v1.138 PR-A)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="ruleset_fingerprint_v138_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-27"
# meta:description="v1.138 PR-A SEC-RULEFP integration guard (static, runnable without Go/nft/root). Asserts the rulefp package exists; the daemon capture hook is guarded by !check (no capture on dry-run/failed apply); the verify-rules CLI is wired with MISMATCH=2 / NFT_UNAVAILABLE=3 exit codes; the shell rebuild captures only inside the exit-0 success branch; the health check is defined+registered+exported; reconciliation records a finding; and the no-auto-heal INVARIANT holds — the verify/reconcile paths never call CaptureBaseline/CaptureLive (capture is reachable ONLY behind the apply !check hook, the --capture flag, and the rebuild success branch). The runtime OK/MISMATCH/BASELINE_MISSING/inject-flip behavior is covered by the lab integration verify + internal/rulefp unit tests."
# meta:input="None (reads repo source)"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep"
# meta:inventory.files="internal/rulefp/fingerprint.go,internal/rulefp/baseline.go,cmd/nftban-core/cmd_verify_rules.go,cmd/nftband/daemon_handlers_elements.go,cmd/nftband/daemon_reconciliation.go,cli/lib/nftban/cli/cmd_firewall.sh,cli/lib/nftban/core/nftban_health_checks_security.sh"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../../../.." && pwd)
PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s (%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED+=("$1"); }
has(){ grep -q "$1" "$REPO/$2" 2>/dev/null; }

echo "=========================================================="
echo "V1.138 PR-A SEC-RULEFP integration wiring + invariant guard"
echo "=========================================================="

echo "--- core package ---"
[[ -f "$REPO/internal/rulefp/fingerprint.go" ]] && ok core_fingerprint_present || no core_fingerprint_present "missing"
[[ -f "$REPO/internal/rulefp/baseline.go" ]] && ok core_baseline_present || no core_baseline_present "missing"
has 'func Normalize(' internal/rulefp/fingerprint.go && ok core_normalize || no core_normalize "Normalize missing"
has 'func Verify(' internal/rulefp/baseline.go && ok core_verify || no core_verify "Verify missing"

echo "--- (A) daemon capture hook guarded by !check ---"
F=cmd/nftband/daemon_handlers_elements.go
has 'rulefp.CaptureLive' "$F" && ok daemon_capture_present || no daemon_capture_present "no CaptureLive in apply handler"
# the CaptureLive must sit under an `if !check {` guard (no capture on dry-run / failed apply)
if grep -Pzoq 'if !check \{[^}]*rulefp\.CaptureLive' "$REPO/$F" 2>/dev/null; then ok daemon_capture_guarded_by_notcheck; else
  # fallback (grep -P -z may be unavailable): both tokens present + !check above CaptureLive
  awk '/if !check \{/{g=NR} /rulefp.CaptureLive/{if(g&&NR-g<6){f=1}} END{exit !f}' "$REPO/$F" && ok daemon_capture_guarded_by_notcheck || no daemon_capture_guarded_by_notcheck "CaptureLive not guarded by !check"
fi

echo "--- (B) verify-rules CLI + exit codes ---"
has 'case "verify-rules":' cmd/nftban-core/main.go && ok cli_case_wired || no cli_case_wired "no verify-rules case in main.go"
has 'cmdVerifyRules' cmd/nftban-core/main.go && ok cli_dispatch || no cli_dispatch "cmdVerifyRules not dispatched"
has 'verifyExitMismatch       = 2' cmd/nftban-core/cmd_verify_rules.go && ok cli_exit_mismatch_2 || no cli_exit_mismatch_2 "MISMATCH exit != 2"
has 'verifyExitNFTUnavailable = 3' cmd/nftban-core/cmd_verify_rules.go && ok cli_exit_nftunavail_3 || no cli_exit_nftunavail_3 "NFT_UNAVAILABLE exit != 3"

echo "--- (C) shell rebuild capture inside success branch only ---"
# the --capture call must appear in cmd_firewall.sh; and the rebuild success branch (exit 0) wraps it
has 'verify-rules --capture' cli/lib/nftban/cli/cmd_firewall.sh && ok shell_rebuild_capture || no shell_rebuild_capture "no --capture in rebuild"
awk '/_rebuild_exit -eq 0 \]\]; then/{g=NR} /verify-rules --capture/{if(g&&NR-g<12){f=1}} END{exit !f}' "$REPO/cli/lib/nftban/cli/cmd_firewall.sh" && ok shell_capture_in_success_branch || no shell_capture_in_success_branch "capture not inside exit-0 branch"

echo "--- (D) health check defined + registered + exported ---"
has 'nftban_health_check_ruleset_fingerprint()' cli/lib/nftban/core/nftban_health_checks_security.sh && ok health_fn_defined || no health_fn_defined "health fn missing"
has 'nftban_health_check_ruleset_fingerprint || ' cli/lib/nftban/core/nftban_health.sh && ok health_registered || no health_registered "not registered in nftban_health.sh"
has 'export -f nftban_health_check_ruleset_fingerprint' cli/lib/nftban/core/nftban_health.sh && ok health_exported || no health_exported "not exported"

echo "--- (E) reconciliation records finding (no mutation) ---"
has 'checkRulesetFingerprint' cmd/nftband/daemon_reconciliation.go && ok reconcile_wired || no reconcile_wired "checkRulesetFingerprint missing"

echo "--- INVARIANT: verify/reconcile paths never capture (no auto-heal) ---"
# cmd_verify_rules.go: CaptureLive only reachable under the `if capture` branch.
if awk '/if capture \{/{c=NR} /rulefp.CaptureLive/{if(!c||NR<c){bad=1}} END{exit bad}' "$REPO/cmd/nftban-core/cmd_verify_rules.go"; then ok cli_capture_only_behind_flag; else no cli_capture_only_behind_flag "CaptureLive reachable outside --capture"; fi
# reconcile method must NOT call any Capture (record-only).
if grep -A30 'func (d \*Daemon) checkRulesetFingerprint' "$REPO/cmd/nftband/daemon_reconciliation.go" | grep -qE 'Capture(Live|Baseline)'; then no reconcile_no_capture "reconcile calls Capture (auto-heal!)"; else ok reconcile_no_capture; fi
# rulefp.Verify must not write files (no os.WriteFile/Rename in Verify body).
if awk '/^func Verify\(/{v=1} v&&/os\.(WriteFile|Rename|Create)/{bad=1} v&&/^}/{v=0} END{exit bad}' "$REPO/internal/rulefp/baseline.go"; then ok verify_is_readonly; else no verify_is_readonly "Verify writes to disk"; fi

echo "=========================================================="
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
if (( FAIL > 0 )); then printf 'FAILED: %s\n' "${FAILED[@]}"; exit 1; fi
echo "ALL PASS"
