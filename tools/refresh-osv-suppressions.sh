#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="refresh-osv-suppressions"
# meta:type="tool"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Refresh osv-scanner.toml suppress list against OSV API for new stdlib Go CVEs"
# meta:inventory.files="tools/refresh-osv-suppressions.sh"
# meta:inventory.binaries="curl,jq"
# meta:inventory.env_vars="OSV_TARGET_GO_VERSION"
# meta:inventory.config_files="osv-scanner.toml"
# meta:inventory.systemd_units=""
# meta:inventory.network="api.osv.dev"
# meta:inventory.privileges="none"
#
# =============================================================================
# Refresh OSV stdlib suppression list
# =============================================================================
#
# Queries the OSV API for Go stdlib vulnerabilities, finds entries not yet
# present in osv-scanner.toml, and either prints them (default) or appends
# them in place (--apply).
#
# When run with --apply, it ALSO checks the patched version for each new CVE.
# CVEs patched in <= OSV_TARGET_GO_VERSION are appended with the standard
# "patched in Go X.Y.Z+ (our builders run TARGET+)" reason. CVEs patched in
# a newer version than the target are appended with a "toolchain upgrade
# pending" reason.
#
# Usage:
#
#   tools/refresh-osv-suppressions.sh                  # dry run, prints diff
#   tools/refresh-osv-suppressions.sh --apply          # writes to osv-scanner.toml
#   OSV_TARGET_GO_VERSION=1.25.9 tools/refresh-osv-suppressions.sh --apply
#
# Default OSV_TARGET_GO_VERSION = 1.25.8 (current builder version).
#
# Exit codes:
#   0  no changes needed (or --apply succeeded with new entries)
#   1  script error
#   2  --apply succeeded and changes were made (signal to CI to commit)
#
# =============================================================================

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOML="${REPO_ROOT}/osv-scanner.toml"
TARGET_GO="${OSV_TARGET_GO_VERSION:-1.25.8}"
APPLY=0

for arg in "$@"; do
    case "$arg" in
        --apply) APPLY=1 ;;
        --help|-h)
            sed -n '2,/^# ===/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

# Dependency check
for cmd in curl jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: required command not found: $cmd" >&2
        exit 1
    fi
done

if [[ ! -f "$TOML" ]]; then
    echo "ERROR: $TOML not found" >&2
    exit 1
fi

# version_le a b → 0 (true) if a <= b in semver-ish ordering
version_le() {
    local a="$1" b="$2"
    [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -1)" == "$a" ]]
}

# Extract currently-suppressed IDs
existing_ids=$(grep -oE '^id = "GO-[0-9-]+"' "$TOML" | sed 's/id = "//;s/"//')
existing_count=$(echo "$existing_ids" | wc -l)

echo "==> Current suppress list: $existing_count entries (target Go $TARGET_GO)"

# Query OSV API for Go stdlib vulns
echo "==> Querying https://api.osv.dev/v1/query for Go stdlib vulns..."
osv_response=$(curl -fsSL https://api.osv.dev/v1/query \
    -H 'Content-Type: application/json' \
    -d "{\"package\":{\"ecosystem\":\"Go\",\"name\":\"stdlib\"},\"version\":\"${TARGET_GO}\"}")

# Extract all GO-* IDs returned
all_ids=$(echo "$osv_response" | jq -r '.vulns[]?.id // empty' | sort -u)
all_count=$(echo "$all_ids" | grep -c '^GO-' || true)

if [[ "$all_count" -eq 0 ]]; then
    echo "==> OSV returned 0 vulns for Go stdlib at version $TARGET_GO. Nothing to do."
    exit 0
fi

echo "==> OSV returned $all_count stdlib vulns affecting Go $TARGET_GO"

# Find new ones (in OSV, not in toml)
new_ids=$(comm -23 <(echo "$all_ids") <(echo "$existing_ids" | sort -u))
new_count=$(echo "$new_ids" | grep -c '^GO-' || true)

if [[ "$new_count" -eq 0 ]]; then
    echo "==> Suppress list is up to date. Nothing to do."
    exit 0
fi

echo "==> Found $new_count new stdlib CVE(s) not in suppress list:"
echo "$new_ids" | sed 's/^/      /'

# For each new ID, fetch details and build the toml stanza
new_stanzas=""
for id in $new_ids; do
    [[ -z "$id" ]] && continue

    detail=$(curl -fsSL "https://api.osv.dev/v1/vulns/${id}" 2>/dev/null || echo '{}')
    summary=$(echo "$detail" | jq -r '.summary // ""' | head -c 90)
    fixed_version=$(echo "$detail" | jq -r '
        [.affected[]?
            | .ranges[]?
            | .events[]?
            | select(.fixed != null)
            | .fixed
        ]
        | sort_by(split(".") | map(tonumber? // 0))
        | .[0] // ""
    ')

    if [[ -z "$summary" ]]; then summary="(no summary available)"; fi

    if [[ -n "$fixed_version" ]] && version_le "$fixed_version" "$TARGET_GO"; then
        reason="stdlib: ${summary}; patched in Go ${fixed_version}+ (our builders run ${TARGET_GO}+)"
    elif [[ -n "$fixed_version" ]]; then
        reason="stdlib: ${summary}; patched in Go ${fixed_version}+ — toolchain upgrade pending"
    else
        reason="stdlib: ${summary}; fix version unknown — review manually"
    fi

    new_stanzas+=$'\n[[IgnoredVulns]]\n'
    new_stanzas+="id = \"${id}\""$'\n'
    new_stanzas+="reason = \"${reason}\""$'\n'
done

if [[ "$APPLY" -eq 0 ]]; then
    echo
    echo "==> Dry run. To apply, re-run with --apply."
    echo
    echo "Would append:"
    echo "$new_stanzas"
    exit 0
fi

# Apply: append to toml
echo "==> Appending $new_count entries to $TOML"
{
    echo
    echo "# === Auto-added by tools/refresh-osv-suppressions.sh on $(date -u +%Y-%m-%d) ==="
    echo "$new_stanzas"
} >> "$TOML"

echo "==> Done. Review the diff and commit."
exit 2
