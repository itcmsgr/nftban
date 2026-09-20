#!/usr/bin/env bash
# =============================================================================
# NFTBan CI — build provenance guard (v1.232.0, BLOCKING)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="check-build-provenance-source"
# meta:type="script"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="CI gate (v1.232.0): the artifact must declare WHICH SOURCE it was built from, not only which commit. Enforces both required directions — a build at a release tag must declare that tag, and a build that is NOT at a release tag must never claim tag provenance. Distinct from check-build-provenance.sh, which guards against packaging a stale prebuilt bin/* artifact."
# meta:inventory.files=""
# meta:inventory.binaries="bash, grep, git, sed"
# meta:inventory.env_vars="PROV_SOURCE_COMMIT, PROV_SOURCE_VERSION, PROV_SOURCE_KIND"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# OPEN-BUILD-PROVENANCE-VERSION-STRING-CANNOT-DISTINGUISH-POST-RELEASE-SOURCE.
#
# The published v1.231.0 tag was 805c6bba and origin/main was eb909b4d. VERSION
# read 1.231.0 on BOTH, while the trees differed by five files of which TWO were
# shipped product files. A package built from main declared the same version as
# the published artifact without being it, so the version string alone could not
# answer "WHICH ARTIFACT AM I RUNNING?".
#
#   A VERSION NAMES AN INTENT. IT DOES NOT IDENTIFY AN ARTIFACT.
#
# The mitigation until now was that everyone remembered to say which one they
# meant. The project's own rule rejects exactly that shape:
# HUMAN ATTENTION IS NOT A SECURITY CONTROL.
#
# This guard enforces BOTH required directions:
#
#   D1  a build AT a release tag must declare that tag and that commit;
#   D2  a build that is NOT at a release tag must NOT claim tag provenance.
#
# D2 is the one that matters for the defect: without it a post-release main
# build could still present itself as the release.
#
# It also asserts the INJECTION IS WIRED, so the guard cannot pass vacuously on
# a checkout where nothing has been built.
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/packaging/lib/provenance.sh"

fail=0
note() { printf '  [OK] %s\n' "$1"; }
bad()  { printf 'FAIL [%s] %s\n' "$1" "$2"; fail=$((fail + 1)); }

echo "== build provenance: injection is wired =="

# The guard must not be satisfiable by a tree that never injects the field.
if grep -q 'version\.BuildSource=' "$ROOT/build.sh"; then
    note "build.sh injects pkg/version.BuildSource"
else
    bad BUILD_SOURCE_NOT_INJECTED "build.sh does not inject pkg/version.BuildSource — provenance would be 'unknown' in every artifact"
fi

if grep -q 'prov_resolve_source_kind' "$ROOT/build.sh"; then
    note "build.sh resolves the source kind before injecting it"
else
    bad SOURCE_KIND_NOT_RESOLVED "build.sh does not call prov_resolve_source_kind"
fi

# An uninjected build must read "unknown" — never anything release-looking.
if grep -qE '^var BuildSource = "unknown"' "$ROOT/pkg/version/version.go"; then
    note "uninjected builds default to 'unknown', not to a release-looking value"
else
    bad BUILD_SOURCE_DEFAULT "pkg/version.BuildSource must default to \"unknown\""
fi

echo "== build provenance: this checkout =="

if ! prov_resolve_source_identity "$ROOT"; then
    bad SOURCE_IDENTITY "cannot resolve source identity for $ROOT"
    exit 1
fi
if ! prov_resolve_source_kind "$ROOT"; then
    bad SOURCE_KIND "cannot resolve source kind for $ROOT"
    exit 1
fi
printf 'BUILD_PROVENANCE_VERSION = %s\n' "${PROV_SOURCE_VERSION:-}"
printf 'BUILD_PROVENANCE_COMMIT  = %s\n' "$PROV_SOURCE_COMMIT"
printf 'BUILD_PROVENANCE_SOURCE  = %s\n' "$PROV_SOURCE_KIND"

# Is this checkout AT the release tag for its own VERSION?
at_release_tag=0
if [[ "$PROV_SOURCE_KIND" == "tag:v${PROV_SOURCE_VERSION}" ]]; then
    at_release_tag=1
fi

# D1 — a tag build must name the tag for its own VERSION. prov_resolve_source_kind
# only emits tag:vX when a tag named vX points at THIS commit, so a "tag:" kind
# that does not match VERSION means the two authorities disagree.
case "$PROV_SOURCE_KIND" in
    tag:*)
        if (( at_release_tag )); then
            note "D1 tag build declares tag:v${PROV_SOURCE_VERSION} matching VERSION"
        else
            bad D1_TAG_VERSION_MISMATCH "source kind '$PROV_SOURCE_KIND' does not match VERSION ${PROV_SOURCE_VERSION}"
        fi
        ;;
    *)
        note "D1 not a tag build (source=$PROV_SOURCE_KIND) — release-artifact rule not applicable here"
        ;;
esac

echo "== build provenance: built artifacts (if any) =="

shopt -s nullglob
bins=()
for b in "$ROOT"/bin/nftband "$ROOT"/bin/nftban-core "$ROOT"/bin/nftban-installer "$ROOT"/bin/nftban-validate; do
    [[ -f "$b" && -x "$b" ]] && bins+=("$b")
done
shopt -u nullglob

if (( ${#bins[@]} == 0 )); then
    echo "  (no built binaries present — artifact-level arms not applicable in this job)"
else
    for b in "${bins[@]}"; do
        ec="$(prov_binary_embedded_commit "$b" 2>/dev/null || echo "")"
        es="$(prov_binary_embedded_source "$b" 2>/dev/null || echo "")"
        if [[ -z "$es" ]]; then
            bad ARTIFACT_NO_SOURCE "$(basename "$b"): --version carries no source field"
            continue
        fi
        if [[ -n "$ec" && "$ec" != "$PROV_SOURCE_COMMIT" ]]; then
            bad ARTIFACT_STALE "$(basename "$b"): embedded commit $ec != source $PROV_SOURCE_COMMIT"
        fi
        if (( at_release_tag )); then
            # D1 at artifact level: the release artifact must carry the tag.
            if [[ "$es" == "tag:v${PROV_SOURCE_VERSION}" ]]; then
                note "D1 $(basename "$b") declares tag:v${PROV_SOURCE_VERSION}"
            else
                bad D1_ARTIFACT_NOT_TAG "$(basename "$b"): built at release tag but declares source '$es'"
            fi
        else
            # D2 — THE defect direction. A non-tag build must never present
            # itself as the release.
            case "$es" in
                tag:*)
                    bad D2_FALSE_TAG_PROVENANCE "$(basename "$b"): declares '$es' but this checkout is not at that release tag (source=$PROV_SOURCE_KIND) — a post-release build must not claim release provenance"
                    ;;
                *)
                    note "D2 $(basename "$b") declares non-tag provenance '$es' (correct for this checkout)"
                    ;;
            esac
        fi
    done
fi

printf 'BUILD_PROVENANCE_VIOLATIONS = %d\n' "$fail"
if (( fail > 0 )); then
    exit 1
fi
echo "  [OK] build provenance is self-describing in both directions"
exit 0
