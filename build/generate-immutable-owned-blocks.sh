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
# meta:description="v1.234 (PR #1439): maintainer scripts run before the new package's files exist, so they cannot source cli/lib/nftban/lib/nftban_immutable_owned.sh. This generator copies that single source verbatim (minus its shebang) between '# == BEGIN GENERATED immutable-owned lib ==' and '# == END GENERATED immutable-owned lib ==' in packaging/deb/{preinst,prerm,postinst}. The RPM spec receives the same text at build time (packaging/build_nftban.sh). --check fails on drift."
# meta:inventory.files="cli/lib/nftban/lib/nftban_immutable_owned.sh, packaging/deb/preinst, packaging/deb/prerm, packaging/deb/postinst"
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
body=$(mktemp); trap 'rm -f "$body" "$body".*' EXIT
tail -n +2 "$LIB" > "$body"
rc=0
for s in preinst prerm postinst; do
    f="$ROOT/packaging/deb/$s"
    if ! grep -qxF "$BEGIN" "$f" || ! grep -qxF "$END" "$f"; then
        echo "ERROR: $f lacks the immutable-owned sentinel markers" >&2; rc=1; continue
    fi
    awk -v b="$BEGIN" -v e="$END" -v bodyf="$body" '
        $0 == b { print; while ((getline l < bodyf) > 0) print l; close(bodyf); skip=1; next }
        $0 == e { skip=0 }
        !skip { print }' "$f" > "$body.$s"
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
exit $rc
