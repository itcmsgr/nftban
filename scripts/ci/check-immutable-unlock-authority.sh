#!/usr/bin/env bash
# =============================================================================
# NFTBan - immutable-flag UNLOCK authority gate (v1.234, PR #1439)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="check-immutable-unlock-authority"
# meta:type="ci-script"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-01"
# meta:description="Owner rule (PR #1439): NFTBan removes an immutable flag ONLY through the shared proven-ownership implementation (cli/lib/nftban/lib/nftban_immutable_owned.sh, its inlined copies, and internal/installer/immutable). This gate fails on any other `chattr -i` / `chattr -R ...` invocation: in the source tree (DEB maintainer scripts outside the generated library region, the RPM spec generator, CLI shell, Go), and - with --package - in the FINAL GENERATED scripts of built .rpm/.deb packages (rpm -qp --scripts; DEB control scripts), where every unlock must lie between the inlined-library begin/end markers. Comment lines are not invocations."
# meta:inventory.files="packaging/deb/*, packaging/build_nftban.sh, cli/**/*.sh, internal/**/*.go, uninstall.sh, install.sh"
# meta:inventory.binaries="bash,awk,grep,find,rpm,ar,tar"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Usage:  check-immutable-unlock-authority.sh                 # source tree
#         check-immutable-unlock-authority.sh --package F...  # built packages
# Exit:   0 PASS · 1 violations · 2 NOT_EXECUTED (tool/input missing)
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
BEGIN_MARK='# Inlined from cli/lib/nftban/lib/nftban_immutable_owned.sh'
END_MARK='# End of inlined nftban_immutable_owned library.'
viol=0

# scan_text LABEL FILE — report unlock invocations outside the inlined library region.
scan_text() {
    local label=$1 file=$2 out
    out=$(awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
        index($0, b) == 1 || index($0, "    " b) { inlib=1 }
        { line=$0; sub(/^[ \t]+/, "", line) }
        inlib == 0 && line !~ /^(#|--|\/\/)/ && line ~ /chattr[ \t]+(-[A-Za-z]*[iR]|-R)/ { printf "%d: %s\n", NR, $0 }
        index($0, e) { inlib=0 }' "$file")
    if [[ -n "$out" ]]; then
        while IFS= read -r l; do echo "FAIL [UNCHECKED_UNLOCK] $label:$l"; done <<< "$out"
        viol=1
    fi
}

if [[ "${1:-}" == "--package" ]]; then
    shift
    (( $# > 0 )) || { echo "NOT_EXECUTED: no package given" >&2; exit 2; }
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    for pkg in "$@"; do
        [[ -f "$pkg" ]] || { echo "NOT_EXECUTED: $pkg not found" >&2; exit 2; }
        case "$pkg" in
            *.rpm)
                command -v rpm >/dev/null || { echo "NOT_EXECUTED: rpm not available for $pkg" >&2; exit 2; }
                rpm -qp --nosignature --scripts "$pkg" > "$tmp/scripts.txt"
                [[ -s "$tmp/scripts.txt" ]] || { echo "NOT_EXECUTED: no scriptlets extracted from $pkg" >&2; exit 2; }
                scan_text "$(basename "$pkg")[scriptlets]" "$tmp/scripts.txt" ;;
            *.deb)
                rm -rf "$tmp/deb"; mkdir -p "$tmp/deb/c"
                ( cd "$tmp/deb" && ar x "$pkg" )
                ctl=$(ls "$tmp/deb"/control.tar.* 2>/dev/null) || { echo "NOT_EXECUTED: no control archive in $pkg" >&2; exit 2; }
                tar -xf "$ctl" -C "$tmp/deb/c"
                n=0
                for s in preinst postinst prerm postrm; do
                    [[ -f "$tmp/deb/c/$s" ]] || continue
                    n=$((n + 1)); scan_text "$(basename "$pkg")[$s]" "$tmp/deb/c/$s"
                done
                (( n > 0 )) || { echo "NOT_EXECUTED: no maintainer scripts in $pkg" >&2; exit 2; } ;;
            *) echo "NOT_EXECUTED: unknown package type $pkg" >&2; exit 2 ;;
        esac
        echo "scanned: $pkg"
    done
else
    for s in preinst postinst prerm postrm; do scan_text "packaging/deb/$s" "$ROOT/packaging/deb/$s"; done
    scan_text "packaging/build_nftban.sh" "$ROOT/packaging/build_nftban.sh"
    while IFS= read -r -d '' f; do
        scan_text "${f#"$ROOT"/}" "$f"
    done < <(find "$ROOT/cli" "$ROOT/install.sh" "$ROOT/uninstall.sh" -type f -name '*.sh' \
                ! -path '*/tests/*' ! -path '*/lib/nftban_immutable_owned.sh' -print0 2>/dev/null)
    go_hits=$(grep -rnE '"chattr"[^)]*"-(R|[A-Za-z]*i)"' --include='*.go' "$ROOT/internal" "$ROOT/cmd" 2>/dev/null \
              | grep -v '_test.go:' | grep -v '/internal/installer/immutable/' || true)
    if [[ -n "$go_hits" ]]; then
        while IFS= read -r l; do echo "FAIL [UNCHECKED_UNLOCK] ${l#"$ROOT"/}"; done <<< "$go_hits"; viol=1
    fi
    echo "scanned: source tree"
fi
if (( viol )); then
    echo "check-immutable-unlock-authority: FAIL — immutable flags may only be removed through the proven-ownership library"
    exit 1
fi
echo "check-immutable-unlock-authority: PASS (no unlock outside the proven-ownership implementation)"
