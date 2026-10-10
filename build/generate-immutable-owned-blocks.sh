#!/usr/bin/env bash
# =============================================================================
# NFTBan - inline the immutable-ownership library into the DEB maintainer scripts
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="generate-immutable-owned-blocks"
# meta:type="build-script"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-01"
# meta:description="v1.234 (PR #1439): maintainer scripts run before the new package's files exist, so they cannot source cli/lib/nftban/lib/nftban_immutable_owned.sh. This generator copies the library's CODE BODY (never its SPDX/copyright/meta header: maintainer scripts are not legal-identity surfaces) between '# == BEGIN GENERATED immutable-owned lib ==' and '# == END GENERATED immutable-owned lib ==' in packaging/deb/{preinst,prerm,postinst,postrm}. The RPM spec receives the same text at build time via --body (packaging/build_nftban.sh). --check fails on drift or on any legal line inside a generated region. v1.235 K2: the NFTBAN_ENABLED reader block of the library is also the ONE source of the copies in cli/lib/nftban/lib/service_control.sh and install/helpers/nftban-boot-early.sh (written between the reader markers; --check fails on divergence)."
# meta:inventory.files="cli/lib/nftban/lib/nftban_immutable_owned.sh, packaging/deb/preinst, packaging/deb/prerm, packaging/deb/postinst, cli/lib/nftban/lib/service_control.sh, install/helpers/nftban-boot-early.sh"
# meta:inventory.binaries="bash,awk,diff,mktemp"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LIB="$ROOT/cli/lib/nftban/lib/nftban_immutable_owned.sh"
MODE=${1:-write}
BEGIN='# == BEGIN GENERATED immutable-owned lib =='
END='# == END GENERATED immutable-owned lib =='
# Only the CODE BODY is injected: everything after the library's legal/meta header
# (the third '# ====' rule line). The maintainer scripts are not registered
# legal-identity surfaces (scripts/ci/data/legal-identity-surfaces.tsv), so no
# SPDX/copyright/meta line may be copied into them (check-core-ownership-identity.sh).
emit_body() {
    printf '%s\n' "# Inlined from cli/lib/nftban/lib/nftban_immutable_owned.sh by build/generate-immutable-owned-blocks.sh - do not edit here."
    awk '/^# =+$/ {n++; next} n >= 3 {print}' "$LIB"
    printf '%s\n' "# End of inlined nftban_immutable_owned library."
}
LEGAL_RE='SPDX-|Copyright|meta:'
if [[ "$MODE" == "--body" ]]; then emit_body; exit 0; fi
body=$(mktemp); trap 'rm -f "$body" "$body".*' EXIT
emit_body > "$body"
if [[ $(awk '/^# =+$/ {n++} END {print n+0}' "$LIB") -lt 3 ]] || grep -qE "$LEGAL_RE" "$body"; then
    echo "ERROR: could not separate the library code body from its legal header" >&2; exit 1
fi
rc=0
for s in preinst prerm postinst postrm; do
    f="$ROOT/packaging/deb/$s"
    if ! grep -qxF "$BEGIN" "$f" || ! grep -qxF "$END" "$f"; then
        echo "ERROR: $f lacks the immutable-owned sentinel markers" >&2; rc=1; continue
    fi
    awk -v b="$BEGIN" -v e="$END" -v bodyf="$body" '
        $0 == b { print; while ((getline l < bodyf) > 0) print l; close(bodyf); skip=1; next }
        $0 == e { skip=0 }
        !skip { print }' "$f" > "$body.$s"
    if awk -v b="$BEGIN" -v e="$END" '$0==b{p=1;next} $0==e{p=0} p' "$f" | grep -qE "$LEGAL_RE"; then
        echo "LEGAL: packaging/deb/$s carries SPDX/copyright/meta lines inside the generated region" >&2; rc=1
    fi
    if [[ "$MODE" == "--check" ]]; then
        if ! diff -q "$f" "$body.$s" >/dev/null; then
            echo "STALE: packaging/deb/$s (run build/generate-immutable-owned-blocks.sh)" >&2; rc=1
        else
            echo "OK: packaging/deb/$s"
        fi
    else
        cat "$body.$s" > "$f"; echo "updated packaging/deb/$s"
    fi
done
# v1.235 K2 (owner 2026-10-08): the NFTBAN_ENABLED reader has ONE source, the block between the
# reader markers in the library above. It is copied (markers included) into the two bash
# consumers that cannot source the library at their run time; --check fails on any divergence.
SW_BEGIN='# >>> NFTBAN_ENABLED reader (v1.235 K2, owner 2026-10-08) >>>'
# Built from a single '<': a literal triple '<' outside a comment reads as a heredoc opener to
# the V108 heredoc-safety gate (scripts/ci). The value is unchanged.
_lt='<'
SW_END="# ${_lt}${_lt}${_lt} NFTBAN_ENABLED reader ${_lt}${_lt}${_lt}"
awk -v b="$SW_BEGIN" -v e="$SW_END" '$0==b{p=1} p{print} $0==e{exit}' "$LIB" > "$body.sw"
if ! grep -qxF "$SW_BEGIN" "$body.sw" || ! grep -qxF "$SW_END" "$body.sw"; then
    echo "ERROR: $LIB lacks the NFTBAN_ENABLED reader markers" >&2; exit 1
fi
for t in cli/lib/nftban/lib/service_control.sh install/helpers/nftban-boot-early.sh; do
    f="$ROOT/$t"; n="$body.$(basename "$t")"
    if [[ $(grep -cxF "$SW_BEGIN" "$f") -ne 1 || $(grep -cxF "$SW_END" "$f") -ne 1 ]]; then
        echo "ERROR: $t must carry the NFTBAN_ENABLED reader markers exactly once" >&2; rc=1; continue
    fi
    awk -v b="$SW_BEGIN" -v e="$SW_END" -v bodyf="$body.sw" '
        $0 == b { while ((getline l < bodyf) > 0) print l; close(bodyf); skip=1; next }
        $0 == e { skip=0; next }
        !skip { print }' "$f" > "$n"
    if [[ "$MODE" == "--check" ]]; then
        if ! diff -q "$f" "$n" >/dev/null; then
            echo "STALE: $t NFTBAN_ENABLED reader differs from $LIB (run build/generate-immutable-owned-blocks.sh)" >&2; rc=1
        else
            echo "OK: $t (NFTBAN_ENABLED reader)"
        fi
    else
        cat "$n" > "$f"; echo "updated $t (NFTBAN_ENABLED reader)"
    fi
done
exit $rc
