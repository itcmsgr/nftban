#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# meta:name="repo-authority-guard"
# meta:type="script"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Developer-side wrapper around scripts/ci/check-repo-authority.sh. Confirms the working clone IS the canonical development authority before branching or releasing, and prints the remediation for each failure. Holds no checks of its own — the CI gate is the single authority."
# meta:inventory.files="scripts/ci/check-repo-authority.sh"
# meta:inventory.binaries="bash, git"
# meta:inventory.env_vars="NFTBAN_AUTHORITY_OFFLINE"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network="delegated to check-repo-authority.sh (tag parity)"
# meta:inventory.privileges="none"
# =============================================================================
#
# Run this BEFORE creating a branch. The retired pre-rewrite tree looked healthy
# by every casual signal — it had a `main`, a clean status and a remote — while
# sitting 7 releases behind on an abandoned history epoch with 12 of 530 tags.
#
# This wrapper deliberately contains NO verification logic. Duplicating the
# checks here would create a second authority that can drift from the CI gate;
# the gate is the single source of truth and this only invokes it.
# =============================================================================
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GATE="$HERE/../scripts/ci/check-repo-authority.sh"

if [[ ! -x "$GATE" && ! -f "$GATE" ]]; then
    echo "ERROR: authority gate not found: $GATE" >&2
    exit 2
fi

args=(--mode local)
[[ -n "${NFTBAN_AUTHORITY_OFFLINE:-}" ]] && args+=(--skip-network)
# Pass through any caller flags (e.g. --skip-network) unchanged.
args+=("$@")

rc=0
bash "$GATE" "${args[@]}" || rc=$?

case "$rc" in
    0)
        echo
        echo "AUTHORITY: OK — safe to branch from this clone."
        ;;
    1)
        cat >&2 <<'REMEDY'

AUTHORITY: VIOLATED — do NOT branch, commit or release from this clone.

Remediation by failure:

  A1 identity mismatch      This directory is not its own repository; git resolved
                            upward to an ancestor. You are probably in a subdirectory,
                            or in a path that only looks like the repository.
  A2 borrowed object store   The clone shares objects with another repository via
                            alternates. Re-clone independently — never with
                            --reference, --shared, --local or copied objects.
  A3 wrong origin            Point origin at the canonical repository, or set
                            NFTBAN_CANONICAL_ORIGIN if you are intentionally on a fork.
  A4 shallow / grafted       Ancestry cannot be evaluated. Re-clone with full history
                            (CI must check out with fetch-depth: 0 and fetch-tags: true).
  A5 wrong history epoch     This object store predates the privacy history rewrite.
                            Branching from it would resurrect scrubbed private data.
                            Re-clone; do not attempt to repair it in place.
  A6 stale local main        Your local main is not origin/main. Fetch and reset your
                            local main to origin/main before branching.
  A7 tag divergence          Local and remote tags differ. Fetch tags; if local-only
                            tags remain, they belong to an abandoned epoch.

REMEDY
        ;;
    2)
        echo >&2
        echo "AUTHORITY: UNDETERMINABLE — refused. This is never a pass." >&2
        echo "  If you are offline, re-run with --skip-network (or NFTBAN_AUTHORITY_OFFLINE=1)" >&2
        echo "  and re-verify with network access before branching or releasing." >&2
        ;;
esac

exit "$rc"
