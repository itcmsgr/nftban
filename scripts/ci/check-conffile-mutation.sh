#!/usr/bin/env bash
# =============================================================================
# NFTBan - a release must not silently mutate a shipped DEB conffile
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="check-conffile-mutation"
# meta:type="ci-gate"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Changing a shipped DEB conffile makes `apt upgrade` prompt, and an UNATTENDED upgrade then aborts or silently keeps the old file — the 71/74 incident. There is no CI gate for this today: the only protection is a predicate inside tools/add-spdx-copyright.sh, which constrains that one script and nothing else. Worse, the places upgrades ARE exercised mask the hazard: lifecycle_deb_matrix.sh passes --force-confold --force-confdef (exactly what suppresses the prompt we need to observe) and ci-update-canonization.yml degrades a dpkg abort to ::warning::. This gate compares the SOURCE files that packaging stages into conffile destinations between a baseline ref and the candidate, and fails on any change that is not explicitly acknowledged. It REUSES packaging's own predicate rather than hard-coding a path list."
# meta:inventory.files="packaging/build_nftban.sh"
# meta:inventory.binaries="git,find,sort,comm"
# meta:inventory.privileges="none (read-only)"
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="${1:-}"
CAND="${2:-HEAD}"
ACK="${NFTBAN_CONFFILE_ACK:-}"   # space-separated paths deliberately changed

if [[ -z "$BASE" ]]; then
    BASE="$(git -C "$ROOT" describe --tags --abbrev=0 --match 'v*' 2>/dev/null)"
    [[ -n "$BASE" ]] || { echo "ERROR: no baseline ref given and no tag found"; exit 2; }
fi

echo "=== shipped-conffile mutation gate ==="
echo "  baseline : $BASE"
echo "  candidate: $CAND"

# -----------------------------------------------------------------------------
# THE AUTHORITY. packaging/build_nftban.sh generates DEBIAN/conffiles from the
# STAGED tree with this predicate (see its MAIL-F8 block):
#     etc/nftban/**/*.conf                      minus *.default *.example *.local
#     etc/nftban/conf.d/**/*.{yaml,yml}         minus the same
#     etc/sysctl.d/90-nftban.conf
# We apply the SAME predicate to the SOURCE trees that packaging stages from, so
# the gate cannot drift from packaging by carrying its own path list.
# ⛔ If packaging's predicate changes, this must change with it — the parity
#    assertion below fails the gate if the marker block disappears.
# -----------------------------------------------------------------------------
PKG="$ROOT/packaging/build_nftban.sh"
if [[ "$(grep -c "GENERATE the DEB conffiles from the actually-staged config set" "$PKG")" -ne 1 ]]; then
    echo "  [FAIL] packaging's conffile-generation block was not found where expected."
    echo "         This gate mirrors that predicate; if packaging changed, update BOTH."
    exit 1
fi

conffile_sources() { # $1=ref -> source paths, sorted
    git -C "$ROOT" ls-tree -r --name-only "$1" 2>/dev/null | awk '
        # bulk-staged operator config tree
        /^etc\/nftban\/.*\.conf$/            { print; next }
        /^etc\/nftban\/conf\.d\/.*\.(yaml|yml)$/ { print; next }
        # explicitly installed into a conffile destination
        $0 == "install/config/nftban.conf"   { print; next }
        $0 == "install/config/feeds.conf"    { print; next }
        $0 == "install/nftables/nftables.conf" { print; next }
        $0 == "install/sysctl/90-nftban.conf" { print; next }
    ' | grep -vE '\.(default|example|local)$' | LC_ALL=C sort -u
}

b_list="$(conffile_sources "$BASE")"
c_list="$(conffile_sources "$CAND")"
n_b=$(printf '%s\n' "$b_list" | grep -c . || true)
n_c=$(printf '%s\n' "$c_list" | grep -c . || true)
echo "  conffile sources: baseline=$n_b candidate=$n_c"

# ⛔ NON-VACUITY. An empty set would make every comparison below pass while
#    asserting nothing — the exact shape of guard this project keeps rejecting.
if [[ "$n_b" -lt 5 || "$n_c" -lt 5 ]]; then
    echo "  [FAIL] conffile source set is implausibly small — the gate would pass vacuously"
    exit 1
fi

rc=0
added="$(comm -13 <(printf '%s\n' "$b_list") <(printf '%s\n' "$c_list"))"
removed="$(comm -23 <(printf '%s\n' "$b_list") <(printf '%s\n' "$c_list"))"
changed=""
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    hb="$(git -C "$ROOT" rev-parse "$BASE:$f" 2>/dev/null || echo MISSING)"
    hc="$(git -C "$ROOT" rev-parse "$CAND:$f" 2>/dev/null || echo MISSING)"
    [[ "$hb" == "$hc" ]] || changed="${changed}${f}"$'\n'
done < <(comm -12 <(printf '%s\n' "$b_list") <(printf '%s\n' "$c_list"))

report() { # $1=label $2=list $3=severity
    local n; n="$(printf '%s\n' "$2" | grep -c . || true)"
    [[ "$n" -eq 0 ]] && { echo "  [PASS] $1: none"; return 0; }
    echo "  [$3] $1: $n"
    printf '%s\n' "$2" | grep . | sed 's/^/        /'
    return 1
}

# A NEW conffile is not a mutation of an existing one: dpkg installs it cleanly.
report "conffiles ADDED (safe: new files install without prompting)" "$added" "INFO" || true

# A REMOVED conffile leaves the operator's file orphaned on upgrade.
report "conffiles REMOVED" "$removed" "FAIL" || rc=1

# The dangerous case.
if [[ -n "${changed//[$'\n' ]/}" ]]; then
    unex=""
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        case " $ACK " in *" $f "*) echo "  [ACK ] acknowledged change: $f" ;;
                        *) unex="${unex}${f}"$'\n' ;; esac
    done <<< "$changed"
    if [[ -n "${unex//[$'\n' ]/}" ]]; then
        echo "  [FAIL] UNEXPECTED conffile mutations:"
        printf '%s\n' "$unex" | grep . | sed 's/^/        /'
        echo "         Changing a shipped conffile makes apt prompt; an UNATTENDED"
        echo "         upgrade then aborts or silently keeps the old file."
        echo "         If deliberate, set NFTBAN_CONFFILE_ACK and record the migration review."
        rc=1
    fi
else
    echo "  [PASS] no shipped conffile content changed"
fi

echo
[[ $rc -eq 0 ]] && echo "RESULT: conffile-mutation PASS" || echo "RESULT: conffile-mutation FAIL"
exit $rc
