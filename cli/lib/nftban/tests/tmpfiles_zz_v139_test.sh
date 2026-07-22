#!/usr/bin/env bash
# =============================================================================
# NFTBan - FHS-TMPFILES-ZZ behavior test (v1.139 PR-A)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="tmpfiles_zz_v139_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-28"
# meta:description="v1.139 PR-A FHS-TMPFILES-ZZ behavior contract: asserts the generated install/systemd/tmpfiles.d/nftban.conf carries the HYBRID reconcile policy — every `created_by: tmpfiles` entry in build/fhs-spec.yaml has both a `d` create-if-missing line AND a sibling `z` (non-recursive) reconcile line with matching path/mode/owner/group. Asserts NO `Z` (recursive) directives are present (recursive would clobber file modes inside log dirs). Asserts no z line exists for paths whose spec entry lacks tmpfiles_reconcile (package/feature_enable surfaces stay d-only). Pure static assertion against repo files; no host contact, no Go, no systemd."
# meta:input="build/fhs-spec.yaml, install/systemd/tmpfiles.d/nftban.conf"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep,awk,yq,sort,wc"
# meta:inventory.files="build/fhs-spec.yaml,install/systemd/tmpfiles.d/nftban.conf,build/generate-fhs-outputs.sh"
# meta:inventory.binaries="bash,grep,awk,yq,sort,wc,diff,comm"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="tmpfiles_zz_v139_test"
# meta:ta.owner="packaging"
# meta:ta.module="fhs"
# meta:ta.execution_class="PACKAGE_BUILD"
# meta:ta.gate="package-build"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../../../.." && pwd)
SPEC="$REPO/build/fhs-spec.yaml"
TMPF="$REPO/install/systemd/tmpfiles.d/nftban.conf"

command -v yq >/dev/null 2>&1 || { echo "FAIL: yq not installed" >&2; exit 1; }
[[ -f "$SPEC" ]] || { echo "FAIL: spec missing $SPEC" >&2; exit 1; }
[[ -f "$TMPF" ]] || { echo "FAIL: generated tmpfiles missing $TMPF" >&2; exit 1; }

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s (%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

echo "=========================================================="
echo "V1.139 PR-A FHS-TMPFILES-ZZ behavior test"
echo "=========================================================="

# -----------------------------------------------------------------------------
# T1: every `created_by: tmpfiles` entry has tmpfiles_reconcile set to z or Z.
# (HYBRID schema contract: explicit metadata, no implicit reconcile.)
# -----------------------------------------------------------------------------
TOTAL_TMPFILES=$(yq -r '[.directories.data[], .directories.logs[], .directories.runtime[]] | map(select(.created_by == "tmpfiles")) | length' "$SPEC")
WITH_RECONCILE=$(yq -r '[.directories.data[], .directories.logs[], .directories.runtime[]] | map(select(.created_by == "tmpfiles" and (.tmpfiles_reconcile == "z" or .tmpfiles_reconcile == "Z"))) | length' "$SPEC")
if [[ "$TOTAL_TMPFILES" -gt 0 ]] && [[ "$WITH_RECONCILE" == "$TOTAL_TMPFILES" ]]; then
    ok "T1 every tmpfiles entry has tmpfiles_reconcile annotation ($WITH_RECONCILE/$TOTAL_TMPFILES)"
else
    no "T1 every tmpfiles entry has tmpfiles_reconcile annotation" "annotated=$WITH_RECONCILE total=$TOTAL_TMPFILES"
fi

# -----------------------------------------------------------------------------
# T2: NO `created_by: package` / `feature_enable` entry carries tmpfiles_reconcile.
# (HYBRID safety: only nftban-owned-lifecycle dirs get reconciled.)
# -----------------------------------------------------------------------------
LEAKED=$(yq -r '[.directories.data[], .directories.config[], .directories.system[], .directories.shared[], .directories.logs[]] | map(select(.created_by != "tmpfiles" and (.tmpfiles_reconcile == "z" or .tmpfiles_reconcile == "Z"))) | length' "$SPEC")
if [[ "$LEAKED" == "0" ]]; then
    ok "T2 no package/feature_enable entry carries tmpfiles_reconcile (operator surfaces safe)"
else
    no "T2 no package/feature_enable entry carries tmpfiles_reconcile" "leaked=$LEAKED — operator surfaces would be reconciled by tmpfiles"
fi

# -----------------------------------------------------------------------------
# T3: generated file's `d`/`z` counts match the spec.
# -----------------------------------------------------------------------------
D_COUNT=$(awk '/^d / {n++} END {print n+0}' "$TMPF")
Z_COUNT=$(awk '/^z / {n++} END {print n+0}' "$TMPF")
ZZ_COUNT=$(awk '/^Z / {n++} END {print n+0}' "$TMPF")
SPEC_Z=$(yq -r '[.directories.data[], .directories.logs[], .directories.runtime[]] | map(select(.tmpfiles_reconcile == "z")) | length' "$SPEC")
SPEC_ZZ=$(yq -r '[.directories.data[], .directories.logs[], .directories.runtime[]] | map(select(.tmpfiles_reconcile == "Z")) | length' "$SPEC")

if [[ "$D_COUNT" == "$TOTAL_TMPFILES" ]]; then
    ok "T3 generated d-count matches spec tmpfiles count ($D_COUNT)"
else
    no "T3 generated d-count matches spec tmpfiles count" "generated=$D_COUNT spec=$TOTAL_TMPFILES"
fi
if [[ "$Z_COUNT" == "$SPEC_Z" ]]; then
    ok "T3a generated z-count matches spec z-annotated count ($Z_COUNT)"
else
    no "T3a generated z-count matches spec z-annotated count" "generated=$Z_COUNT spec=$SPEC_Z"
fi
if [[ "$ZZ_COUNT" == "$SPEC_ZZ" ]]; then
    ok "T3b generated Z-count matches spec Z-annotated count ($ZZ_COUNT, currently 0 by HYBRID design)"
else
    no "T3b generated Z-count matches spec Z-annotated count" "generated=$ZZ_COUNT spec=$SPEC_ZZ"
fi

# -----------------------------------------------------------------------------
# T4: every `d` line for a tmpfiles entry has a SIBLING `z` (or `Z`) line for
# the SAME path. (The generator emits paired d+z; missing pair = drift.)
# -----------------------------------------------------------------------------
# Extract spec paths whose tmpfiles_reconcile is set.
RECONCILED_PATHS=$(yq -r '[.directories.data[], .directories.logs[], .directories.runtime[]] | map(select(.tmpfiles_reconcile == "z" or .tmpfiles_reconcile == "Z")) | .[].path' "$SPEC" | sort -u)
MISSING_Z=0
while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    # Use -F fixed-strings with explicit space prefix/suffix; paths contain no regex.
    if ! grep -qF "z $p " "$TMPF" && ! grep -qF "Z $p " "$TMPF"; then
        MISSING_Z=$((MISSING_Z+1))
    fi
done <<< "$RECONCILED_PATHS"
if [[ "$MISSING_Z" == "0" ]]; then
    ok "T4 every reconcile-annotated path has a paired z/Z line in the generated file"
else
    no "T4 every reconcile-annotated path has a paired z/Z line" "$MISSING_Z reconciled spec paths missing their z/Z sibling"
fi

# -----------------------------------------------------------------------------
# T5: z/Z lines' mode/owner/group MATCH the corresponding d line's
# mode/owner/group. (Protects against silent generator drift.)
# -----------------------------------------------------------------------------
MISMATCH=0
while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    d_line=$(grep -F "d $p " "$TMPF" | head -1)
    z_line=$(grep -F "z $p " "$TMPF" | head -1)
    if [[ -z "$d_line" || -z "$z_line" ]]; then continue; fi
    d_tail=$(echo "$d_line" | cut -d' ' -f3-)
    z_tail=$(echo "$z_line" | cut -d' ' -f3-)
    if [[ "$d_tail" != "$z_tail" ]]; then
        MISMATCH=$((MISMATCH+1))
    fi
done <<< "$RECONCILED_PATHS"
if [[ "$MISMATCH" == "0" ]]; then
    ok "T5 d/z line tails (mode owner group -) match for every paired path"
else
    no "T5 d/z line tails match" "$MISMATCH paths have d/z mode-owner-group drift"
fi

# -----------------------------------------------------------------------------
# T6: the auditor authority exception (/var/lib/nftban/reports/auditors) is now
# created_by=package, NOT tmpfiles. v1.175 BUG-TMPFILES: this root-owned child
# (0770 root:nftban-auditor) under the nftban-owned /var/lib/nftban/reports parent
# made systemd-tmpfiles refuse the non-root-parent→root-child transition (exit 73).
# It is created+owned at install (RPM %dir %attr — nftban-auditor resolves via the
# %pre groupadd; DEB nftban.dirs + dir-attrs in postinst), so tmpfiles never
# attempts the unsafe transition. The authority exception (root:nftban-auditor 0770)
# is preserved — only the CREATOR changed (tmpfiles → package).
# -----------------------------------------------------------------------------
AUD_CB=$(yq -r '.directories.data[] | select(.path == "/var/lib/nftban/reports/auditors") | .created_by // "missing"' "$SPEC")
if [[ "$AUD_CB" == "package" ]]; then
    ok "T6 auditor authority exception is created_by=package (v1.175 BUG-TMPFILES; not tmpfiles → no exit-73)"
else
    no "T6 auditor authority exception created_by=package" "got created_by=$AUD_CB"
fi
# T6b: and it is therefore absent from the generated tmpfiles.d.
if grep -qE '/var/lib/nftban/reports/auditors' "$REPO/install/systemd/tmpfiles.d/nftban.conf"; then
    no "T6b auditors absent from tmpfiles.d" "still present — generator emitted a tmpfiles entry"
else
    ok "T6b auditors absent from generated tmpfiles.d (created by package, not tmpfiles)"
fi

# -----------------------------------------------------------------------------
# T7: NO `Z` (recursive) directives in the generated file (HYBRID design
# locks all 47 to non-recursive `z`; later operator decision could opt-in
# specific subtrees, but v1.139 PR-A ships with zero Z).
# -----------------------------------------------------------------------------
if [[ "$ZZ_COUNT" == "0" ]]; then
    ok "T7 no recursive Z directives in v1.139 PR-A (HYBRID locked to z)"
else
    no "T7 no recursive Z directives in v1.139 PR-A" "found $ZZ_COUNT — HYBRID violated"
fi

# -----------------------------------------------------------------------------
# T8: generator --check passes (idempotency: regenerate matches committed).
# -----------------------------------------------------------------------------
if (cd "$REPO" && bash build/generate-fhs-outputs.sh --check >/dev/null 2>&1); then
    ok "T8 build/generate-fhs-outputs.sh --check PASS (deterministic regen matches committed)"
else
    no "T8 generator --check PASS" "regenerate diverges from committed — run generator + commit"
fi

# -----------------------------------------------------------------------------
echo "=========================================================="
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
if (( FAIL > 0 )); then printf 'FAILED: %s\n' "${FAILED[@]}"; exit 1; fi
echo "ALL PASS"
