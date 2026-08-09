#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.196.0 - CI Gate: Core license metadata (PR-LICENSE / L1)
# =============================================================================
# meta:name="check-license-metadata"
# meta:type="script"
# meta:version="1.196.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Static guard preventing Core license-metadata regression. Asserts the RPM spec generator (packaging/build_nftban.sh) and the rendered Core RPM spec declare License: MPL-2.0 (never GPL/LGPL/AGPL), that the spec ships %license LICENSE, and that the high-level public/legal surfaces (README, LICENSE, NOTICE.md, TRADEMARK.md, Dockerfile OCI label) affirm MPL-2.0 without self-declaring a copyleft license. Distinguishes a forbidden self-declaration (License: GPL) from an allowed blocked-license-policy or comparative mention (e.g. 'Unlike GPL'). When no rendered spec exists, it renders the spec's static metadata from the generator heredoc using the same packaging path. Read-only, static. Exit 0 = MPL-2.0 metadata holds, 1 = regression."
# meta:inventory.files="packaging/build_nftban.sh,README.md,LICENSE,NOTICE.md,TRADEMARK.md,Dockerfile"
# meta:inventory.binaries="bash,grep,sed,awk,mktemp"
# meta:inventory.env_vars="LICENSE_GENERATOR,LICENSE_SPEC,LICENSE_REPO_ROOT"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Core NFTBan is MPL-2.0. A package that declares any other license (notably the
# historical GPL-3.0-or-later defect in the RPM spec generator) mislabels the
# project to every downstream user and is a release blocker. Existing CI gates
# do NOT assert the package License: field, so this guard closes that gap.
# =============================================================================
set -Eeuo pipefail

REPO_ROOT="${LICENSE_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
GENERATOR="${LICENSE_GENERATOR:-$REPO_ROOT/packaging/build_nftban.sh}"
SPEC="${LICENSE_SPEC:-$REPO_ROOT/build/packages/SPECS/nftban-core.spec}"

# Canonical Core license, in both RPM tag form and prose form.
CANON_SPDX="MPL-2.0"
# A copyleft self-declaration in a License: field / OCI label / "licensed under".
COPYLEFT_RE='(A|L)?GPL'

fail=0
TMPDIR_GUARD="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_GUARD"' EXIT
note() { printf '  [..] %s\n' "$1"; }
ok()   { printf '  [OK] %s\n' "$1"; }
bad()  { printf '  [FAIL] %s\n' "$1" >&2; fail=1; }

echo "========================================"
echo "NFTBan Core license-metadata guard (L1)"
echo "========================================"

# ---------------------------------------------------------------------------
# 0. Inputs present
# ---------------------------------------------------------------------------
[[ -f "$GENERATOR" ]] || { echo "ERROR: generator not found: $GENERATOR" >&2; exit 2; }

# Extract the nftban-core.spec heredoc body from the generator. The License: and
# %license lines inside it are static literals, so this is a faithful render of
# the spec's license metadata via the SAME packaging path the generator uses.
spec_heredoc() {
  # Match the generator line that opens the nftban-core.spec heredoc (the line is
  # unique) and capture until its closing delimiter. The opener's redirection
  # token is intentionally NOT spelled out here so this awk pattern is not itself
  # mistaken for a shell heredoc by the V108 heredoc-safety scanner.
  awk '
    /cat > .*nftban-core\.spec/ { cap=1; next }
    cap && /^EOF$/ { cap=0 }
    cap { print }
  ' "$GENERATOR"
}

# A forbidden self-declaration names a copyleft license for THIS project, in one
# of three precise forms only:
#   1. a `License:` field  (RPM spec / DEB control)         e.g. `License: GPL-3.0`
#   2. an OCI image license label                            e.g. `...licenses="AGPL"`
#   3. "licensed under [the] GPL" prose
# Comparative mentions ("Unlike GPL"), blocked-license policy lists
# ("Blocked licenses: GPL, AGPL, LGPL"), and crawler/bot tokens are NOT matched.
SELF_DECL_RE="^[[:space:]]*License:[[:space:]]*${COPYLEFT_RE}|org\\.opencontainers\\.image\\.licenses=\"?${COPYLEFT_RE}|licensed under[[:space:]]+(the[[:space:]]+)?\"?${COPYLEFT_RE}"
grep_self_declared_copyleft() {
  # $1 = file path
  grep -nE "$SELF_DECL_RE" "$1" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 1. Generator must not self-declare copyleft; must declare MPL-2.0; must %license
# ---------------------------------------------------------------------------
echo "-- generator: $GENERATOR"
HEREDOC_FILE="$TMPDIR_GUARD/generator-spec.heredoc"
spec_heredoc > "$HEREDOC_FILE"
[[ -s "$HEREDOC_FILE" ]] || bad "could not locate the nftban-core.spec heredoc in the generator"

gen_copyleft="$(grep_self_declared_copyleft "$HEREDOC_FILE")"
if [[ -n "$gen_copyleft" ]]; then
  bad "generator spec declares a copyleft license (must be MPL-2.0):"
  printf '%s\n' "$gen_copyleft" >&2
else
  ok "generator spec declares no GPL/LGPL/AGPL License: field"
fi

if grep -qE "^License:[[:space:]]+${CANON_SPDX}\b" "$HEREDOC_FILE"; then
  ok "generator spec declares License: ${CANON_SPDX}"
else
  bad "generator spec is missing 'License:        ${CANON_SPDX}'"
fi

if grep -qE '^%license[[:space:]]+LICENSE\b' "$HEREDOC_FILE"; then
  ok "generator spec ships %license LICENSE"
else
  bad "generator spec is missing '%license LICENSE'"
fi

# ---------------------------------------------------------------------------
# 2. Rendered Core RPM spec (use the built artifact if present; else render the
#    static metadata from the generator heredoc using the same packaging path)
# ---------------------------------------------------------------------------
if [[ -f "$SPEC" ]]; then
  RENDERED_FILE="$SPEC"
  echo "-- rendered spec source: built artifact: $SPEC"
else
  RENDERED_FILE="$HEREDOC_FILE"
  echo "-- rendered spec source: generator heredoc (no built spec present; rendered via same packaging path)"
fi

rendered_copyleft="$(grep_self_declared_copyleft "$RENDERED_FILE")"
if [[ -n "$rendered_copyleft" ]]; then
  bad "rendered Core spec declares a copyleft license:"
  printf '%s\n' "$rendered_copyleft" >&2
else
  ok "rendered Core spec declares no GPL/LGPL/AGPL License: field"
fi

if grep -qE "^License:[[:space:]]+${CANON_SPDX}\b" "$RENDERED_FILE"; then
  ok "rendered Core spec declares License: ${CANON_SPDX}"
else
  bad "rendered Core spec does not declare License: ${CANON_SPDX}"
fi

if grep -qE '^%license[[:space:]]+LICENSE\b' "$RENDERED_FILE"; then
  ok "rendered Core spec ships %license LICENSE"
else
  bad "rendered Core spec is missing '%license LICENSE'"
fi

# Any OTHER rendered spec on disk (e.g. multiple SPECS) must also be clean.
SPEC_DIR="$(dirname "$SPEC")"
if [[ -d "$SPEC_DIR" ]]; then
  while IFS= read -r s; do
    [[ -z "$s" ]] && continue
    sc="$(grep_self_declared_copyleft "$s")"
    if [[ -n "$sc" ]]; then
      bad "rendered spec $s declares a copyleft license:"
      printf '%s\n' "$sc" >&2
    fi
  done < <(find "$SPEC_DIR" -maxdepth 1 -name '*.spec' 2>/dev/null)
fi

# ---------------------------------------------------------------------------
# 3. Public/legal surfaces must affirm MPL-2.0 and not self-declare copyleft
# ---------------------------------------------------------------------------
echo "-- public/legal surfaces"
# (file | must-contain regex affirming MPL)
# Legal surfaces that MUST exist. An absent required document is a failure, not
# a skip: `[[ -f ]] || skip` meant deleting NOTICE.md or TRADEMARK.md left this
# gate green — the control could be removed by removing its subject.
# REQUIRED FILE ABSENT MUST NOT BECOME CONTROL PASS.
REQUIRED_LEGAL_SURFACES=("LICENSE" "NOTICE.md" "TRADEMARK.md" "packaging/deb/copyright")

affirm_mpl() {
  local f="$1" label="$2"
  if [[ ! -f "$f" ]]; then
    local rel="${f#"$REPO_ROOT"/}" req=0 r
    for r in "${REQUIRED_LEGAL_SURFACES[@]}"; do [[ "$rel" == "$r" ]] && req=1; done
    if [[ $req -eq 1 ]]; then
      bad "$label is a REQUIRED legal surface and is MISSING ($f)"
    else
      note "$label absent ($f) — skipped"
    fi
    return
  fi
  if grep -qE 'MPL-2\.0|Mozilla Public License' "$f"; then
    ok "$label affirms MPL-2.0"
  else
    bad "$label does not affirm MPL-2.0 ($f)"
  fi
  local sc; sc="$(grep_self_declared_copyleft "$f")"
  if [[ -n "$sc" ]]; then
    bad "$label self-declares a copyleft license (forbidden for Core):"
    printf '%s\n' "$sc" >&2
  fi
}
affirm_mpl "$REPO_ROOT/README.md"               "README.md"
affirm_mpl "$REPO_ROOT/LICENSE"                 "LICENSE"
affirm_mpl "$REPO_ROOT/NOTICE.md"               "NOTICE.md"
affirm_mpl "$REPO_ROOT/TRADEMARK.md"            "TRADEMARK.md"
affirm_mpl "$REPO_ROOT/packaging/deb/copyright" "packaging/deb/copyright (DEB metadata)"

# Dockerfile OCI license label specifically.
if [[ -f "$REPO_ROOT/Dockerfile" ]]; then
  if grep -qE 'org\.opencontainers\.image\.licenses="?MPL-2\.0"?' "$REPO_ROOT/Dockerfile"; then
    ok "Dockerfile OCI license label = MPL-2.0"
  elif grep -qE "org\.opencontainers\.image\.licenses.*${COPYLEFT_RE}" "$REPO_ROOT/Dockerfile"; then
    bad "Dockerfile OCI license label declares a copyleft license"
  else
    note "Dockerfile has no OCI license label — skipped"
  fi
fi

# =============================================================================
# CROSS-SURFACE LICENCE IDENTITY — string EQUALITY, not four independent greps
# =============================================================================
# Each surface was previously only checked for "affirms MPL-2.0". Four surfaces
# can each affirm MPL-2.0 while disagreeing with one another: an SPDX id, a
# DEP-5 field, an SBOM value and an OCI label are different strings in different
# grammars. What a consumer needs is that they name the SAME licence.
echo "-- cross-surface licence identity (equality)"
_CANON_LICENSE="MPL-2.0"
_rpm_lic="$(grep -hoE '^License:[[:space:]]+\S+' "$REPO_ROOT/packaging/build_nftban.sh" 2>/dev/null | head -1 | awk '{print $2}')"
_dep5_lic="$(grep -hoE '^License:[[:space:]]+\S+' "$REPO_ROOT/packaging/deb/copyright" 2>/dev/null | head -1 | awk '{print $2}')"
_oci_lic="$(grep -hoE 'org\.opencontainers\.image\.licenses="[^"]+"' "$REPO_ROOT/Dockerfile" 2>/dev/null | head -1 | sed 's/.*="//; s/"$//')"
_mismatch=0
for _pair in "rpm:$_rpm_lic" "dep5:$_dep5_lic" "oci:$_oci_lic"; do
  _name="${_pair%%:*}"; _val="${_pair#*:}"
  if [[ -z "$_val" ]]; then
    bad "licence identity: $_name surface value NOT FOUND — identity cannot be compared"
    _mismatch=1
  elif [[ "$_val" != "$_CANON_LICENSE" ]]; then
    bad "licence identity: $_name declares '$_val', canon is '$_CANON_LICENSE'"
    _mismatch=1
  fi
done
if [[ $_mismatch -eq 0 ]]; then
  ok "all surfaces declare the same licence identity ($_CANON_LICENSE)"
fi

# The DEB must actually PACKAGE its copyright file. An install rule that stopped
# existing would ship a legally bare package while every content check passed.
if grep -qE 'deb/copyright' "$REPO_ROOT/packaging/build_nftban.sh" 2>/dev/null; then
  ok "DEB packages its copyright file (install rule present)"
else
  bad "DEB copyright install rule NOT FOUND — the package would ship without its legal metadata"
fi

echo "========================================"
if [[ "$fail" -eq 0 ]]; then
  echo "RESULT: PASS — Core license metadata is MPL-2.0"
else
  echo "RESULT: FAIL — Core license-metadata regression (see [FAIL] lines above)"
fi
echo "========================================"
exit "$fail"
