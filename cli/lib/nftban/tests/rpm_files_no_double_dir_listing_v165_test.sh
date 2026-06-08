#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.165 PR-B guard: lib-dir RPM %files dedup (no double dir listing)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="rpm_files_no_double_dir_listing_v165_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-08"
# meta:description="Hermetic guard for the v1.165 PR-B lib-dir RPM %files dedup. The %files section in packaging/build_nftban.sh both %include nftban-files.inc (which %dir-owns every /usr/lib/nftban payload dir) AND used to repeat those dirs as bare payload paths, so strict rpm 4.16 (EL9/EL10) warned 'File listed twice'. PR-B converts the 12 lib payload dirs to <dir>/* (the inc keeps sole %dir ownership) and strips dotfiles from the buildroot in %install so the /* glob - which skips dotfiles - does not orphan tests/.gitkeep. This guard asserts: (a) each of the 12 lib dirs is listed as <dir>/* and NOT as a bare dir path; (b) the %install dotfile strip exists; (c) no /usr/lib/nftban path is BOTH a bare %files payload line AND an inc %dir entry. Static; no rpmbuild/host. Templates + non-lib trees are out of PR-B scope (PR-C)."
# meta:inventory.files="packaging/build_nftban.sh,install/packaging/rpm/nftban-files.inc"
# meta:inventory.binaries="bash,awk,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
BS="$REPO_ROOT/packaging/build_nftban.sh"
INC="$REPO_ROOT/install/packaging/rpm/nftban-files.inc"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

[[ -f "$BS"  ]] || { echo "build_nftban.sh not found at $BS"; exit 1; }
[[ -f "$INC" ]] || { echo "nftban-files.inc not found at $INC"; exit 1; }

LIB_DIRS=(bin sbin cli core lib cron helpers setup exporters tests data health)

echo "rpm-files lib-dir dedup guard (v1.165 PR-B):"

# --- (a) each lib dir is <dir>/* and NOT a bare dir line -----------------------
for d in "${LIB_DIRS[@]}"; do
    has_glob=$(grep -cE "^/usr/lib/nftban/${d}/\*[[:space:]]*\$" "$BS" || true)
    has_bare=$(grep -cE "^/usr/lib/nftban/${d}[[:space:]]*\$" "$BS" || true)
    if [[ "$has_glob" -ge 1 && "$has_bare" -eq 0 ]]; then
        ok "lib dir '${d}' is /usr/lib/nftban/${d}/* (no bare dir line)"
    else
        no "lib dir '${d}' dedup wrong (glob=$has_glob bare=$has_bare; want glob>=1 bare=0)"
    fi
done

# --- (b) the %install dotfile strip is present --------------------------------
if grep -qE 'find %\{buildroot\}/usr/lib/nftban -name .\.\*. -type f -delete' "$BS"; then
    ok "%install strips dotfiles from the buildroot lib tree (/* glob safe)"
else
    no "missing %install dotfile strip (find %{buildroot}/usr/lib/nftban -name '.*' -type f -delete)"
fi

# --- (c) no /usr/lib/nftban path is BOTH a bare %files line AND an inc %dir ----
# Bare %files payload lines (no %dir/%attr/%config/%doc/glob), /usr/lib/nftban only.
mapfile -t bare_files < <(grep -E '^/usr/lib/nftban/[A-Za-z0-9_./-]+[[:space:]]*$' "$BS" \
    | grep -vE '/\*[[:space:]]*$' | sed 's/[[:space:]]*$//' | sort -u)
# inc %dir-owned /usr/lib/nftban paths.
mapfile -t inc_dirs < <(grep -E '^%dir .* /usr/lib/nftban/' "$INC" \
    | sed -E 's/^.* (\/usr\/lib\/nftban\/[A-Za-z0-9_./-]+)[[:space:]]*$/\1/' | sort -u)

double=""
for p in "${bare_files[@]:-}"; do
    [[ -z "$p" ]] && continue
    for q in "${inc_dirs[@]:-}"; do
        [[ "$p" == "$q" ]] && double+="$p"$'\n'
    done
done
if [[ -z "$double" ]]; then
    ok "no /usr/lib/nftban path is both a bare %files line and an inc %dir entry"
else
    no "double-listed (bare %files AND inc %dir)" "$(printf '%s' "$double" | head -1)"
    printf '%s' "$double" | sed 's/^/      /'
fi

# --- (d) self-test: detector catches a re-introduced bare dir line ------------
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
{ cat "$BS"; echo '/usr/lib/nftban/core'; } > "$tmp"
reintro_bare=$(grep -cE '^/usr/lib/nftban/core[[:space:]]*$' "$tmp" || true)
[[ "$reintro_bare" -ge 1 ]] \
    && ok "self-test: a re-introduced bare '/usr/lib/nftban/core' line is detectable" \
    || no "self-test FAILED: could not detect a re-introduced bare dir line"

echo ""
echo "  PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
