#!/usr/bin/env bash
# =============================================================================
# NFTBan - retired-entrypoint reference guard (v1.228.7)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="check-retired-binary-references"
# meta:type="ci-guard"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-08"
# meta:description="BLOCKING guard for INCOMPLETE_SHELL_TO_GO_MIGRATION. Fails if any EXECUTABLE source line references a retired standalone entrypoint listed in scripts/ci/data/retired-entrypoints.tsv. A shell->Go migration is complete only when every consumer is repointed; the geoban case shipped for months with country-blocking dead because nftban_geoban.sh still resolved bin/.real/nftban-geoip-x86_64 after the impl moved into nftban-core geoip. Comment lines and lines carrying a RETIRED-OK: marker are allowlisted (a guard-against-reintroduction may name the path in prose). Static; scans shell/Go/systemd/packaging source; invokes no host."
# meta:input="scripts/ci/data/retired-entrypoints.tsv + source tree"
# meta:output="PASS/FAIL per pattern; exit 1 on any live reference"
# meta:depends="bash,grep,git"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,git"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1
MANIFEST="scripts/ci/data/retired-entrypoints.tsv"

[[ -f "$MANIFEST" ]] || { echo "  [FAIL] manifest missing: $MANIFEST"; exit 1; }

FAILS=0
ok()  { printf '  [PASS] %s\n' "$1"; }
bad() { printf '  [FAIL] %s\n' "$1"; FAILS=$((FAILS+1)); }

echo "=== check-retired-binary-references (v1.228.7) ==="

# Source families a migrated consumer could hide in.
mapfile -t FILES < <(git -C "$ROOT" ls-files \
    'cli/**/*.sh' 'scripts/**/*.sh' 'cmd/**/*.go' 'internal/**/*.go' \
    'install/**/*.service' 'install/**/*.conf' 'packaging/**' 2>/dev/null \
    | grep -vE '(^scripts/ci/data/retired-entrypoints\.tsv$|_test\.(sh|go)$|/tests/)')

# Strip comments and RETIRED-OK lines from a file, emit "path:lineno:code".
noncomment() {
    local f="$1"
    # shell/go/systemd/conf all use '#' or '//' comments; drop both, and drop
    # any line explicitly marked RETIRED-OK.
    grep -nvE '^[[:space:]]*(#|//)' "$f" 2>/dev/null \
        | grep -v 'RETIRED-OK:' \
        | sed "s|^|$f:|"
}

while IFS=$'\t' read -r pattern migrated _note; do
    [[ -z "$pattern" || "$pattern" == \#* ]] && continue
    hits=""
    for f in "${FILES[@]}"; do
        [[ -f "$f" ]] || continue
        h="$(noncomment "$f" | grep -F "$pattern" || true)"
        [[ -n "$h" ]] && hits+="$h"$'\n'
    done
    if [[ -z "${hits//[$'\n']/}" ]]; then
        ok "no live reference to retired '$pattern' (migrated -> $migrated)"
    else
        bad "retired entrypoint '$pattern' still referenced (migrated -> $migrated):"
        printf '%s' "$hits" | grep -v '^$' | head -8 | sed 's/^/         /'
    fi
done < "$MANIFEST"

echo "=== retired-binary-references: FAILS=$FAILS ==="
[[ "$FAILS" -eq 0 ]]
