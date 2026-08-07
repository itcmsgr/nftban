#!/usr/bin/env bash
# =============================================================================
# NFTBan - firewall rebuild evidence authority guard (v1.228.5)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="check-rebuild-evidence-authority"
# meta:type="ci-guard"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-04"
# meta:description="v1.228.5 completion guard. Prevents reintroduction of the defect class where a branch-significant failure is consumed with its evidence discarded. R-1 rejects any EXECUTABLE line that runs 'firewall rebuild' while sending stderr to /dev/null - rebuild's exit-code contract now distinguishes a real runtime failure (including an unprojected durable whitelist) from success, and a caller that branches on rc after discarding stderr tells the operator 'manual intervention required' with no cause. R-2 rejects 'sync --quick ... || true', the exact swallow that let firewall_rebuild report 'all checks passed' while the durable whitelist.d layer - including 00-session.conf, which holds the ACTIVE ADMIN SSH IP - was never projected into the running set (MEASURED: daemon down, rebuild rc=0, admin IP absent from whitelist_ipv4). R-3 asserts the shared reconcile helper still exists and is used by BOTH callers, so one authority cannot silently fork into two. Comments and test files legitimately quote these patterns to document the defect and to assert its absence, so all rules operate on EXECUTABLE lines only and skip tests - a guard that cannot tell a defect from a guard against one produces false positives, which is how the original stale-index failure masked the more important unassigned-test problem. Static analysis only - reads files, invokes nothing, contacts no host."
# meta:input="cli/lib/nftban/**, packaging/**, install/**"
# meta:output="PASS/FAIL per rule; exit 0 on all-pass, 1 on any violation"
# meta:depends="bash,grep,sed"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,sed"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

FAIL=0
pass(){ printf '  [PASS] %s\n' "$1"; }
fail(){ printf '  [FAIL] %s\n' "$1"; FAIL=1; }

# Executable lines only, and never inside tests.
#   - comments legitimately DOCUMENT the removed pattern (the rationale must survive)
#   - test files legitimately ASSERT ITS ABSENCE (a guard against the defect is not the defect)
# Scanning them would produce exactly the false positive that once masked a real finding.
scan_paths() {
    grep -rn --include='*.sh' "$1" cli/ packaging/ install/ scripts/ 2>/dev/null \
      | grep -vE '_test\.sh:' \
      | grep -vF 'scripts/ci/check-rebuild-evidence-authority.sh:' \
      | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#'
}

echo "=== R-1: no 'firewall rebuild' with stderr discarded on an executable line ==="
# Both shapes hide the reason: 2>/dev/null and >/dev/null 2>&1.
r1="$(scan_paths 'firewall rebuild' | grep -E '2>[[:space:]]*/dev/null' || true)"
if [[ -n "$r1" ]]; then
    fail "rebuild callers discarding stderr:"
    printf '%s\n' "$r1" | sed 's/^/        /'
    echo "        -> capture it:  out=\"\$(nftban firewall rebuild --quiet 2>&1)\"; rc=\$?"
    echo "        -> rebuild now returns non-zero with the CAUSE on stderr; discarding it"
    echo "           makes the branch evidence-free and the operator message unactionable."
else
    pass "no rebuild caller discards stderr"
fi

echo "=== R-2: no 'sync --quick' failure swallowed with || true ==="
r2="$(scan_paths 'sync --quick' | grep -E '\|\|[[:space:]]*true' || true)"
if [[ -n "$r2" ]]; then
    fail "sync --quick failures swallowed:"
    printf '%s\n' "$r2" | sed 's/^/        /'
    echo "        -> this is the measured defect: daemon down -> sync rc=1 discarded ->"
    echo "           rebuild reported rc=0 / 'all checks passed' with the durable"
    echo "           whitelist.d layer (incl. the admin session IP) UNPROJECTED."
else
    pass "no sync --quick failure is swallowed"
fi

echo "=== R-3: the shared reconcile helper exists and BOTH callers use it ==="
SRC="cli/lib/nftban/cli/cmd_firewall.sh"
if [[ ! -r "$SRC" ]]; then
    fail "cannot read $SRC"
else
    if grep -qE '^_nftban_whitelist_reconcile_and_verify\(\)' "$SRC"; then
        pass "shared helper _nftban_whitelist_reconcile_and_verify is defined"
    else
        fail "shared helper _nftban_whitelist_reconcile_and_verify is MISSING"
    fi
    # Call sites on executable lines only.
    calls="$(grep -nE '^[^#]*_nftban_whitelist_reconcile_and_verify[[:space:]]+' "$SRC" | wc -l)"
    if [[ "$calls" -ge 2 ]]; then
        pass "both reload and rebuild route through the shared helper ($calls call sites)"
    else
        fail "expected >=2 helper call sites (reload + rebuild), found $calls — one authority must not fork"
    fi
    # Mode must be PASSED, never inferred from systemctl: an operator-stopped daemon and
    # a not-yet-started daemon are indistinguishable to is-active and mean opposite things.
    if grep -qE '^[^#]*_nftban_whitelist_reconcile_and_verify[[:space:]]+(runtime-required|install-deferred|"\$_wl_mode")' "$SRC"; then
        pass "helper is invoked with an explicit mode"
    else
        fail "helper invoked without an explicit execution-context mode"
    fi
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
    echo "=== RESULT: rebuild evidence authority PASS ==="
else
    echo "=== RESULT: rebuild evidence authority FAIL ==="
fi
exit "$FAIL"
