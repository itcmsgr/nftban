#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# =============================================================================
# P12-A02 CONNLIMIT PROJECTION APPLIER / DRIFT CHECK
# =============================================================================
# meta:description="Rewrites every NFTBAN-GENERATED connlimit block in the three
#   emission surfaces from the canonical declaration, or (--check) verifies that
#   what is committed is byte-identical to what the generator produces. This is
#   what makes the declaration AUTHORITATIVE rather than merely documentary: a
#   hand-edited projection, or a declaration change that was never projected,
#   both fail --check. Scalar limits are NOT resolved here; the boot artifact is
#   a pre-rendered snapshot so it carries the shipped defaults, and the template
#   keeps its __CT_LIMIT_*__ placeholders for the runtime substitution layer."
#
# Usage: apply-connlimit-projection.sh [--check]
# Exit:  0 applied / no drift · 1 DRIFT (with --check) · 3 missing input
# =============================================================================
set -Eeuo pipefail

MODE="${1:-apply}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GEN="$ROOT/scripts/ci/gen-connlimit-projection.sh"
[[ -f "$GEN" ]] || { echo "MISSING generator: $GEN" >&2; exit 3; }
SPLICE="$ROOT/scripts/ci/lib/splice-marker-block.py"
[[ -f "$SPLICE" ]] || { echo "MISSING splicer: $SPLICE" >&2; exit 3; }

TPL="$ROOT/install/nftables/nftables.conf.tpl"
CONF="$ROOT/install/nftables/nftables.conf"
FRAG="$ROOT/cli/lib/nftban/lib/nft_fragment.sh"

# The boot artifact is a PRE-RENDERED snapshot: same structure, shipped defaults
# substituted. Keep aligned with cmd_firewall.sh's fallbacks.
declare -A SUB=( [__CT_LIMIT_SSH__]=15 [__CT_LIMIT_HTTP__]=200 [__CT_LIMIT_MAIL__]=30 )

render() {  # render <medium> <family|-> <resolve_scalars:0|1>
    local medium="$1" fam="$2" resolve="$3" out
    if [[ "$fam" == "-" ]]; then out=$(bash "$GEN" "$medium")
    else                          out=$(bash "$GEN" "$medium" "$fam"); fi
    if [[ "$resolve" == 1 ]]; then
        local k
        for k in "${!SUB[@]}"; do out="${out//$k/${SUB[$k]}}"; done
    fi
    printf '%s\n' "$out"
}

rewrite() {  # rewrite <file> <medium> <family|-> <resolve>
    local file="$1" medium="$2" fam="$3" resolve="$4"
    local famlabel="$fam"; [[ "$fam" == "-" ]] && famlabel=""
    local blockfile; blockfile=$(mktemp)
    render "$medium" "$fam" "$resolve" > "$blockfile"
    python3 "$SPLICE" "$file" "$medium" "$famlabel" "$blockfile"
    rm -f "$blockfile"
}

TMPD=$(mktemp -d)
# --check is READ-ONLY and must stay read-only even if it dies mid-run. It works
# by rendering into the real files and diffing, so restoration cannot live at the
# end of the happy path: `diff -u | head` raises SIGPIPE, and under `set -e` with
# pipefail that aborted the script BEFORE the restore, silently leaving the
# generated text in place and discarding the operator's edit. A second run then
# reported NO DRIFT. Restoration therefore belongs in the EXIT trap, which runs on
# error, signal and normal exit alike.
restore_originals() {
    [[ "$MODE" == "--check" ]] || return 0
    local f b
    for f in "$TPL" "$CONF" "$FRAG"; do
        b=$(basename "$f")
        [[ -f "$TMPD/$b.orig" ]] && cp -- "$TMPD/$b.orig" "$f"
    done
}
trap 'restore_originals; rm -rf "$TMPD"' EXIT
if [[ "$MODE" == "--check" ]]; then
    for f in "$TPL" "$CONF" "$FRAG"; do cp "$f" "$TMPD/$(basename "$f").orig"; done
fi

rewrite "$TPL"  base-sets  4 0
rewrite "$TPL"  base-sets  6 0
rewrite "$TPL"  base-rules 4 0
rewrite "$TPL"  base-rules 6 0
rewrite "$CONF" base-sets  4 1
rewrite "$CONF" base-sets  6 1
rewrite "$CONF" base-rules 4 1
rewrite "$CONF" base-rules 6 1
rewrite "$FRAG" fragment   4 0
rewrite "$FRAG" fragment   6 0

if [[ "$MODE" == "--check" ]]; then
    rc=0
    for f in "$TPL" "$CONF" "$FRAG"; do
        b=$(basename "$f")
        if ! diff -q "$TMPD/$b.orig" "$f" >/dev/null; then
            echo "DRIFT: $f differs from the generated projection"
            diff -u "$TMPD/$b.orig" "$f" | head -30 || true
            rc=1
        fi
    done
    [[ $rc -eq 0 ]] && echo "connlimit projection: NO DRIFT (3 surfaces, 9 blocks)"
    exit $rc
fi
echo "connlimit projection applied (3 surfaces, 9 blocks)"
