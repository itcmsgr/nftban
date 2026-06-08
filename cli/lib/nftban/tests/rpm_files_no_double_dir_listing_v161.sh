#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.161: RPM %files no-double-dir-listing guard
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="rpm_files_no_double_dir_listing_v161"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-08"
# meta:description="Best-effort guard for BUG-RPM-FILES-LISTED-TWICE. The RPM %files payload (in packaging/build_nftban.sh, between %files and %changelog) must not list a directory PATH as a bare payload line when that same path already has a %dir entry in the generated install/packaging/rpm/nftban-files.inc — RPM then sees the %dir twice and warns 'File listed twice'. This greps both the inc %dir paths and the %files bare-directory lines and fails on any overlap, except a small documented allowlist of paths intentionally kept bare because the inc lacks %dir entries for their subdirs (e.g. /usr/share/nftban/templates owns un-%dir'd email/ + partials/). Static text check; no rpmbuild, no host."
# meta:input="None (reads packaging/build_nftban.sh + install/packaging/rpm/nftban-files.inc)"
# meta:output="Pass/fail assertions; exit 0 on no unexpected overlap"
# meta:depends="bash,grep,sed,awk,sort,comm"
# meta:inventory.files="packaging/build_nftban.sh,install/packaging/rpm/nftban-files.inc"
# meta:inventory.binaries="bash,grep,sed,awk,sort,comm"
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
SPEC="$REPO_ROOT/packaging/build_nftban.sh"
INC="$REPO_ROOT/install/packaging/rpm/nftban-files.inc"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

[[ -f "$SPEC" ]] || { echo "spec not found: $SPEC"; exit 1; }
[[ -f "$INC"  ]] || { echo "inc not found: $INC"; exit 1; }

# Paths intentionally left as a BARE dir in %files even though the inc carries a
# %dir for them, because the inc has NO %dir entry for their subdirs and the bare
# path is what recursively owns those subdirs. Documented in build_nftban.sh.
allow_bare=(
  "/usr/share/nftban/templates"
)
is_allowed(){
  local p="$1" a
  for a in "${allow_bare[@]}"; do [[ "$p" == "$a" ]] && return 0; done
  return 1
}

# 1. %dir paths declared in the generated inc.
dir_paths="$(grep -E '^%dir ' "$INC" | sed -E 's/.* (\/[^ ]+)$/\1/' | sort -u)"

# 2. Bare directory-style payload lines in the %files section of the spec.
#    A "bare dir line" = a line that is just an absolute path, no %attr/%dir/%doc/
#    %config prefix, no trailing glob (/* or *.ext), i.e. a plain directory path.
files_block="$(awk '/^%files/{f=1} /^%changelog/{f=0} f' "$SPEC")"
bare_dirs="$(printf '%s\n' "$files_block" \
  | grep -E '^/[A-Za-z0-9._/-]+$' \
  | grep -vE '[*]' \
  | sort -u)"

echo "=== overlap between inc %dir entries and bare %files dir lines ==="
overlap="$(comm -12 <(printf '%s\n' "$dir_paths") <(printf '%s\n' "$bare_dirs") || true)"

found_bad=0
if [[ -n "$overlap" ]]; then
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    if is_allowed "$p"; then
      ok "allowed bare overlap: $p (inc lacks %dir for its subdirs — documented)"
    else
      no "double-listed: $p is BOTH a %dir (inc) and a bare %files line" "convert to ${p}/* or drop"
      found_bad=1
    fi
  done <<< "$overlap"
else
  ok "no overlap between inc %dir paths and bare %files dir lines"
fi

[[ "$found_bad" -eq 0 ]] && ok "no unexpected double-listed directories" \
  || true

echo "================================================================"
echo "rpm_files_no_double_dir_listing_v161: PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[[ $FAIL -eq 0 ]]
