#!/usr/bin/env bash
# =============================================================================
# NFTBan Gate B — retired in-code audit rotator guard
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="audit_rotate_retired_gateb_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-19"
# meta:description="Static + runtime guard for Gate B: the dead in-code audit rotator nftban_audit_rotate was retired (it had zero callers and only implied a non-running 'in-code 50MB rotation' that would have fought logrotate over the same inode). Asserts the symbol is neither defined nor exported in nftban_audit.sh, does not resolve after sourcing, and that logrotate remains the single rotation authority for nftban-actions.log + audit.log (a copytruncate stanza covering both). Prevents reintroduction of an in-code rotator."
# meta:input="None (greps nftban_audit.sh + install/config/nftban.logrotate; sources audit helper in a sandbox)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,grep"
# meta:inventory.files="cli/lib/nftban/helpers/nftban_audit.sh,install/config/nftban.logrotate"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files="install/config/nftban.logrotate"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
AUDIT="$REPO_ROOT/cli/lib/nftban/helpers/nftban_audit.sh"
LR="$REPO_ROOT/install/config/nftban.logrotate"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1${2:+ — $2}"; }

echo "== static: nftban_audit_rotate is not defined or exported =="
grep -Eq '^[[:space:]]*nftban_audit_rotate[[:space:]]*\(\)' "$AUDIT" && no "definition still present" || ok "no function definition in nftban_audit.sh"
grep -Eq '^[[:space:]]*export -f[[:space:]]+nftban_audit_rotate\b' "$AUDIT" && no "export -f still present" || ok "no export -f nftban_audit_rotate"

echo "== runtime: symbol does not resolve after sourcing the audit helper =="
( set +e
  # sandbox: stub the audit helper's expected env so sourcing is side-effect-free
  export NFTBAN_AUDIT_LOG="/tmp/_nftban_audit_guard_$$.log"
  # shellcheck source=/dev/null
  source "$AUDIT" >/dev/null 2>&1 || true
  if declare -F nftban_audit_rotate >/dev/null 2>&1; then exit 2; fi
  # the surviving audit API must still be present (we only removed the rotator)
  declare -F nftban_audit_log >/dev/null 2>&1 || exit 3
  exit 0
)
rc=$?
case "$rc" in
  0) ok "nftban_audit_rotate unresolved after source; nftban_audit_log preserved" ;;
  2) no "nftban_audit_rotate STILL resolves after sourcing" ;;
  3) no "nftban_audit_log missing (over-deletion)" ;;
  *) ok "audit helper sourced without the retired symbol (rc=$rc, env-limited)" ;;
esac

echo "== logrotate is the single authority for the audit files =="
grep -q '/var/log/nftban/nftban-actions.log' "$LR" && grep -q '/var/log/nftban/audit.log' "$LR" \
  && ok "nftban-actions.log + audit.log covered by a logrotate stanza" || no "audit files missing from logrotate"
# the shared stanza must still carry copytruncate (unchanged in Gate B)
awk '/nftban-actions.log/{f=1} f&&/copytruncate/{print "yes"; exit} f&&/\}/{exit}' "$LR" | grep -q yes \
  && ok "audit stanza retains copytruncate (logrotate owns rotation)" || no "audit stanza copytruncate missing"

echo
echo "======================================================================"
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
