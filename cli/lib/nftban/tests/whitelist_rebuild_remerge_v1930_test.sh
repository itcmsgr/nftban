#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.193.0 - rebuild re-merges manual whitelist.d (BUG-REBUILD-DROPS-MANUAL-WHITELIST)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="whitelist_rebuild_remerge_v1930_test"
# meta:type="test"
# meta:version="1.193.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-17"
# meta:description="Static guard: _firewall_rebuild_core must reconcile durable manual whitelist.d/blacklist.d via the core 'sync --quick' path (same as firewall_reload Step 3b), AFTER the system 'nftban whitelist sync', so an explicit 'firewall rebuild' no longer drops manual --static whitelist IPs from the live set. Hermetic — parses cmd_firewall.sh function bodies; no nft/root (real behaviour proven lab-first)."
# meta:inventory.files="whitelist_rebuild_remerge_v1930_test.sh"
# meta:inventory.binaries="bash,awk,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="whitelist_rebuild_remerge_v1930_test"
# meta:ta.owner="firewall"
# meta:ta.module="whitelist-rebuild-remerge"
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FW="$SCRIPT_DIR/../cli/cmd_firewall.sh"
[[ -f "$FW" ]] || { echo "FAIL: cmd_firewall.sh not found at $FW"; exit 1; }
PASS=0; FAIL=0
ok(){ echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad(){ echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

# Extract a top-level function body by name (name() { ... } at column 0).
# CODE LINES ONLY. v1.228.5: the removed defect ('sync --quick ... || true') is now
# DELIBERATELY DOCUMENTED in a comment so the rationale survives. Grepping raw source
# let that comment satisfy T1 below — it reported PASS while the call it claimed to
# verify had moved into the shared helper. A guard that cannot tell a defect from the
# documentation of a defect is not a guard, and a vacuous PASS is worse than a visible
# FAIL because it manufactures confidence. Controls in T7 keep this falsifiable.
fn_body(){ # $1=func name
  awk -v fn="$1" '
    $0 ~ "^"fn"\\(\\)[[:space:]]*\\{?[[:space:]]*$" {inf=1}
    inf {print}
    inf && /^\}/ {exit}
  ' "$FW" | grep -vE '^[[:space:]]*#'
}

REBUILD="$(fn_body _firewall_rebuild_core)"
RELOAD="$(fn_body firewall_reload)"
# v1.228.5: the reconcile call moved OUT of both callers into ONE shared helper so
# reload and rebuild cannot drift apart. The assertions follow the AUTHORITY into the
# helper and separately prove both callers delegate — asserting the literal call text
# at the old call sites would test a structure the code no longer has.
HELPER="$(fn_body _nftban_whitelist_reconcile_and_verify)"
[[ -n "$REBUILD" ]] || { echo "FAIL: could not extract _firewall_rebuild_core"; exit 1; }
[[ -n "$RELOAD" ]]  || { echo "FAIL: could not extract firewall_reload"; exit 1; }
[[ -n "$HELPER" ]]  || { echo "FAIL: could not extract _nftban_whitelist_reconcile_and_verify"; exit 1; }
DELEGATE='_nftban_whitelist_reconcile_and_verify[[:space:]]'

echo "=== T1: rebuild reconciles manual whitelist.d via core 'sync --quick' ==="
# Two-part now: rebuild must DELEGATE, and the delegate must do the reconcile.
if printf '%s\n' "$REBUILD" | grep -qE "$DELEGATE"; then
  printf '%s\n' "$HELPER" | grep -qE 'sync --quick' \
    && ok "rebuild delegates to the reconcile helper, which invokes core 'sync --quick'" \
    || bad "reconcile helper MISSING 'sync --quick' (manual --static whitelist would be dropped)"
else
  bad "rebuild does NOT delegate to _nftban_whitelist_reconcile_and_verify"
fi

echo "=== T2: reconcile is AFTER the system 'nftban whitelist sync' (ordering) ==="
ln_wlsync=$(printf '%s\n' "$REBUILD" | grep -nE 'nftban whitelist sync' | head -1 | cut -d: -f1)
ln_recon=$(printf '%s\n' "$REBUILD" | grep -nE "$DELEGATE" | head -1 | cut -d: -f1)
if [[ -n "$ln_wlsync" && -n "$ln_recon" && "$ln_recon" -gt "$ln_wlsync" ]]; then
  ok "reconcile (line $ln_recon) follows system whitelist sync (line $ln_wlsync)"
else
  bad "ordering wrong: whitelist sync=$ln_wlsync reconcile=$ln_recon"
fi

echo "=== T3: parity — firewall_reload also reconciles via 'sync --quick' ==="
# Parity is now STRUCTURAL: one helper, so the two paths cannot silently diverge.
printf '%s\n' "$RELOAD" | grep -qE "$DELEGATE" \
  && ok "reload delegates to the same reconcile helper (parity is structural)" \
  || bad "reload does NOT delegate to the shared helper (parity broken — investigate)"

echo "=== T4: reconcile is guarded by core-binary existence (no hard failure if absent) ==="
printf '%s\n' "$HELPER" | grep -qE '\[\[ ! -x "\$_core" \]\]|\[\[ -x .*core.* \]\]' \
  && ok "reconcile helper guarded by -x core check" \
  || bad "reconcile not guarded (could hard-fail when core binary absent)"

echo "=== T5: --quick keeps it whitelist/blacklist-only (no feeds/geoban pulled into rebuild reconcile) ==="
printf '%s\n' "$HELPER" | grep -E '"\$_core" sync|nftban-core.*sync' | grep -qE 'sync --quick' \
  && ok "reconcile uses --quick (whitelist/blacklist only)" \
  || bad "reconcile not --quick"

echo "=== T6 (v1.228.5): the reconcile result is no longer discarded ==="
printf '%s\n' "$HELPER" | grep -qE 'sync --quick[^|]*\|\|[[:space:]]*true' \
  && bad "helper still swallows the reconcile failure with '|| true'" \
  || ok "reconcile failure is no longer swallowed"
printf '%s\n' "$REBUILD" | grep -qE "_rebuild_whitelist_converged|if ! ${DELEGATE}" \
  && ok "rebuild BRANCHES on the reconcile outcome" \
  || bad "rebuild ignores the reconcile outcome (it would report success regardless)"

echo "=== T7 (v1.228.5): CONTROLS — T1 must be satisfied by CODE, never by a comment ==="
# T1 previously reported PASS off a comment quoting the very call it existed to
# verify. These controls make it falsifiable in BOTH directions.
code_only(){ grep -vE '^[[:space:]]*#'; }

# CONTROL A: call ABSENT, comment MENTIONS it -> must NOT satisfy.
_synth_a="$(printf '%s\n' 'f() {' '    # historical: "$_core" sync --quick >/dev/null 2>&1 || true' '    echo noop' '}')"
printf '%s\n' "$_synth_a" | code_only | grep -qE 'sync --quick' \
  && bad "T7-A a comment mentioning 'sync --quick' still satisfies the matcher (VACUOUS PASS)" \
  || ok "T7-A comment-only mention correctly does NOT satisfy T1"

# CONTROL B: call PRESENT, no comment -> must satisfy.
_synth_b="$(printf '%s\n' 'f() {' '    "$_core" sync --quick' '}')"
printf '%s\n' "$_synth_b" | code_only | grep -qE 'sync --quick' \
  && ok "T7-B executable 'sync --quick' correctly satisfies T1" \
  || bad "T7-B executable call NOT detected — matcher is broken"

# CONTROL C: extraction must be non-vacuous, else every check passes for free.
[[ -n "$HELPER" && "$(printf '%s\n' "$HELPER" | wc -l)" -gt 5 ]] \
  && ok "T7-C helper extraction non-vacuous ($(printf '%s\n' "$HELPER" | wc -l) code lines)" \
  || bad "T7-C helper extraction empty/degenerate — T1/T4/T5 would be meaningless"

echo ""
echo "=== whitelist rebuild re-merge v1.193.0: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
