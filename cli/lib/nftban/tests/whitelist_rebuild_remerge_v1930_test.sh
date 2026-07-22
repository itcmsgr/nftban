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
fn_body(){ # $1=func name
  awk -v fn="$1" '
    $0 ~ "^"fn"\\(\\)[[:space:]]*\\{?[[:space:]]*$" {inf=1}
    inf {print}
    inf && /^\}/ {exit}
  ' "$FW"
}

REBUILD="$(fn_body _firewall_rebuild_core)"
RELOAD="$(fn_body firewall_reload)"
[[ -n "$REBUILD" ]] || { echo "FAIL: could not extract _firewall_rebuild_core"; exit 1; }
[[ -n "$RELOAD" ]]  || { echo "FAIL: could not extract firewall_reload"; exit 1; }

echo "=== T1: rebuild reconciles manual whitelist.d via core 'sync --quick' ==="
printf '%s\n' "$REBUILD" | grep -qE 'sync --quick' \
  && ok "rebuild invokes core 'sync --quick' (manual whitelist.d/blacklist.d reconcile)" \
  || bad "rebuild MISSING 'sync --quick' reconcile (manual --static whitelist would be dropped on rebuild)"

echo "=== T2: reconcile is AFTER the system 'nftban whitelist sync' (ordering) ==="
ln_wlsync=$(printf '%s\n' "$REBUILD" | grep -nE 'nftban whitelist sync' | head -1 | cut -d: -f1)
ln_recon=$(printf '%s\n' "$REBUILD" | grep -nE 'sync --quick' | head -1 | cut -d: -f1)
if [[ -n "$ln_wlsync" && -n "$ln_recon" && "$ln_recon" -gt "$ln_wlsync" ]]; then
  ok "reconcile (line $ln_recon) follows system whitelist sync (line $ln_wlsync)"
else
  bad "ordering wrong: whitelist sync=$ln_wlsync reconcile=$ln_recon"
fi

echo "=== T3: parity — firewall_reload also reconciles via 'sync --quick' ==="
printf '%s\n' "$RELOAD" | grep -qE 'sync --quick' \
  && ok "reload invokes core 'sync --quick' (parity established)" \
  || bad "reload missing 'sync --quick' (parity broken — investigate)"

echo "=== T4: reconcile is guarded by core-binary existence (no hard failure if absent) ==="
printf '%s\n' "$REBUILD" | grep -qE '\[\[ -x .*nftban-core.* \]\]|if \[\[ -x' \
  && ok "rebuild reconcile guarded by -x core check" \
  || bad "rebuild reconcile not guarded (could hard-fail when core binary absent)"

echo "=== T5: --quick keeps it whitelist/blacklist-only (no feeds/geoban pulled into rebuild reconcile) ==="
# the reconcile call itself must carry --quick (not a bare 'sync' that would do feeds/geoban)
printf '%s\n' "$REBUILD" | grep -E 'nftban-core.*sync|_rb_reconcile.*sync|"\$.*" sync' | grep -qE 'sync --quick' \
  && ok "rebuild reconcile uses --quick (whitelist/blacklist only)" \
  || bad "rebuild reconcile not --quick"

echo ""
echo "=== whitelist rebuild re-merge v1.193.0: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
