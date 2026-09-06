#!/usr/bin/env bash
# =============================================================================
# NFTBan CI — P6: boot-projection publication + label authority
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="check-boot-projection-publication-authority"
# meta:type="ci"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-06"
# meta:description="v1.229.13 Lane 3E rule P6, assurance-only. TWO independent invariants. P6-A PUBLICATION AUTHORITY: the boot projection is rendered and published by the established SHELL authority; Go orchestrates by delegation only and must not write, rename, substitute for, or re-validate the projection itself. P6-B LABEL AUTHORITY: the shipped policy maps the ONE boot-projection file to nftban_nftables_conf_t so the distro nftables.service (iptables_t) can read it, and does NOT broaden that type to the whole generated directory. This guard asserts SOURCE/PACKAGE-POLICY invariants only — runtime SELinux enforcement was proven package-natively in Lane 3D.5 and is NOT claimed here."
# meta:inventory.files="internal/installer/switchop/renderboot.go,cli/lib/nftban/lib/boot_projection.sh,install/selinux/nftban.fc"
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
rc=0
ok(){ printf '  PASS  %s\n' "$1"; }
bad(){ rc=1; printf '  FAIL  %s\n' "$1"; }

RENDERBOOT="$ROOT/internal/installer/switchop/renderboot.go"
BOOTPROJ="$ROOT/cli/lib/nftban/lib/boot_projection.sh"
FC="$ROOT/install/selinux/nftban.fc"
BOOT_ARTIFACT='/etc/nftban/generated/nftban-boot.nft'

strip_go_comments(){ sed -e 's://.*::' "$1" | perl -0pe 's{/\*.*?\*/}{}gs'; }
strip_sh_comments(){ sed -e 's/^[[:space:]]*#.*$//' "$1"; }

echo "== P6 subject population (non-vacuity asserted BEFORE any bad-population check) =="
for f in "$RENDERBOOT" "$BOOTPROJ" "$FC"; do
    [[ -f "$f" ]] || { bad "subject missing: ${f#$ROOT/} — guard would be vacuous"; }
done
[[ "$rc" -eq 0 ]] || exit "$rc"
ok "all three P6 subjects present"

# ---------------------------------------------------------------- P6-A
echo "== P6-A REQUIRED DELEGATION =="
GO_DELEG=$(strip_go_comments "$RENDERBOOT" | grep -cE '"firewall",[[:space:]]*"render-boot"' || true)
if [[ "${GO_DELEG:-0}" -gt 0 ]]; then
    ok "Go delegates publication to the CLI authority (render-boot), $GO_DELEG site(s)"
else
    bad "renderboot.go no longer delegates to \`nftban firewall render-boot\` — Go would be \
publishing the boot projection itself"
fi

for fn in _firewall_substitute_placeholders _firewall_publish_conf; do
    n=$(strip_sh_comments "$BOOTPROJ" | grep -cE "$fn" || true)
    if [[ "${n:-0}" -gt 0 ]]; then
        ok "boot_projection.sh delegates to $fn ($n site(s))"
    else
        bad "boot_projection.sh no longer calls $fn — publication/render semantics would be \
reimplemented instead of delegated"
    fi
done

echo "== P6-A FORBIDDEN DIRECT GO PUBLICATION =="
# Constrained to the FPA boot-projection surface. A generic os.Rename elsewhere in Go is
# NOT a violation — the subject is publication OF THE BOOT PROJECTION.
GO_SURFACE=$(find "$ROOT/internal/installer/switchop" "$ROOT/internal/installer/render" \
             -name '*.go' -not -name '*_test.go' 2>/dev/null | sort)
VIOL=""
for f in $GO_SURFACE; do
    body=$(strip_go_comments "$f")
    # Only lines that BOTH name the boot artifact AND perform a publication operation.
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        VIOL+="${f#$ROOT/}: ${line}"$'\n'
    done < <(printf '%s\n' "$body" | grep -nE "$BOOT_ARTIFACT" \
             | grep -E 'os\.Rename|WriteFile|Create\(|ReplaceAll|nft -c|exec\.Command' || true)
done
if [[ -z "$VIOL" ]]; then
    ok "P6_DIRECT_PUBLICATION_POPULATION=0 (no Go write/rename/substitute/validate of the projection)"
else
    bad "Go implements boot-projection publication directly — competing authority:"
    printf '%s' "$VIOL" | sed 's/^/        /'
fi

# ---------------------------------------------------------------- P6-B
echo "== P6-B SHIPPED LABEL MAPPING =="
fc_rules(){ grep -vE '^[[:space:]]*#' "$FC"; }
EXACT=$(fc_rules | grep -cE '^/etc/nftban/generated/nftban-boot\\\.nft[[:space:]].*nftban_nftables_conf_t' || true)
if [[ "${EXACT:-0}" -eq 1 ]]; then
    ok "P6_FCONTEXT_EXACT: the boot projection maps to nftban_nftables_conf_t (exactly 1 rule)"
else
    bad "P6_FCONTEXT_EXACT: expected exactly ONE exact mapping for the boot projection, found ${EXACT:-0}. \
Without it restorecon resolves to the /etc/nftban catch-all, publication verification fails, \
and the FPA transition is UNREACHABLE on EL."
fi

echo "== P6-B SCOPE NARROWNESS =="
# ⛔ 'the required type appears somewhere in .fc' is too weak. The nftables-readable type
# must NOT be broadened to the generated directory: only the one consumed artifact needs it.
BROAD=$(fc_rules | grep -E '^/etc/nftban/generated\(' | grep -cE 'nftban_nftables_conf_t' || true)
if [[ "${BROAD:-0}" -eq 0 ]]; then
    ok "P6_FCONTEXT_SCOPE_NARROW: generated/ directory is NOT broadly nftables-readable"
else
    bad "P6_FCONTEXT_SCOPE_NARROW: a generated-directory rule grants nftban_nftables_conf_t. \
That makes every future generated artifact readable by nftables.service; only the boot \
projection requires it."
fi

exit "$rc"
