#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.164: RPM %files directory double-listing dedup guard
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="rpm_files_no_double_dir_listing_v164"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-08"
# meta:description="Locks the v1.164 fix for BUG-RPM-FILES-LISTED-TWICE. The RPM %files section in packaging/build_nftban.sh both %include's nftban-files.inc (which %dir-owns every package directory) AND used to repeat those same directories as bare payload paths, so strict rpm 4.16/EL9 saw each %dir node twice ('File listed twice'). v1.164 converts the /usr/lib/nftban payload dirs to <dir>/* (contents only, inc keeps sole %dir ownership), drops the now-empty tests/ payload line (its .gitkeep is stripped in %install so /* would error 'contains no files'), and documents the two intentional bare exceptions (templates: un-%dir'd email/+partials/ subdirs the generator does not own yet; selinux: has NO inc %dir so its bare line is sole owner, not a double-listing). This guard asserts NO path is BOTH a bare %files payload line in build_nftban.sh AND a %dir entry in nftban-files.inc, except the documented allowlist. It also asserts the .gitkeep strip is present in %install and that the empty tests/ payload line is gone. Hermetic / repo-static (no rpm, no build, no host)."
# meta:input="None (self-contained; reads packaging/build_nftban.sh + install/packaging/rpm/nftban-files.inc from the repo)"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
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
[[ -f "$INC" ]]  || { echo "inc not found: $INC"; exit 1; }

# Documented intentional bare-directory exceptions (NOT to be flagged):
#   /usr/share/nftban/templates : the inc %dir-owns templates/{,mail,reports,zabbix}
#       but the staged tree also has email/ + partials/ subdirs that the GENERATED
#       inc does NOT %dir (DO NOT EDIT). The bare path recursively owns those
#       un-%dir'd subdirs; converting it would orphan them. Residual "listed twice"
#       on the templates dir itself is benign until the generator emits those %dirs.
#   /usr/share/nftban/selinux : the inc has NO %dir for it, so the bare line is its
#       SOLE owner — not a double-listing at all; it MUST stay to own the dir.
ALLOWLIST=$'/usr/share/nftban/templates\n/usr/share/nftban/selinux'

# -----------------------------------------------------------------------------
# Extract the %files section of build_nftban.sh (from "^%files" to the next
# top-level %section or EOF), then collect BARE directory payload lines: lines
# that are a plain absolute path with NO trailing /* glob, NO file extension
# component after the last /, NO leading %-directive (e.g. %dir/%attr/%config/%doc),
# and NO embedded glob. Those are the candidates that could double-list a %dir.
# -----------------------------------------------------------------------------
# NOTE: the section terminator is a KNOWN RPM-section keyword set — NOT a bare
# "^%word" — because the %files body legitimately contains inline directives
# (%include, %attr, %config, %doc, %dir) that begin with % but do NOT end the
# section. Terminating on those would truncate the body and miss real payload
# lines.
files_section="$(awk '
  /^%files([ \t]|$)/ {inf=1; next}
  inf && /^%(changelog|post|postun|posttrans|pre|preun|pretrans|prep|build|install|clean|description|package|trigger|verifyscript)([a-z]*)?([ \t]|$)/ {inf=0}
  inf {print}
' "$SPEC")"

[[ -n "$files_section" ]] || { echo "could not extract %files section from $SPEC"; exit 1; }

# Bare absolute-dir payload lines = start with "/", no glob char, no directive,
# and the basename has no "." (a dot would imply a file, e.g. VERSION has none but
# *.sh/README.md/structure_default.json do — those are file payloads, not dirs).
# Pipelines are guarded with `|| true` because grep/comm legitimately return rc=1
# on no-match under `set -o pipefail`.
bare_dirs="$( { printf '%s\n' "$files_section" \
  | grep -vE '^[[:space:]]*#' \
  | grep -E '^/' \
  | grep -vE '[*?[]' \
  | awk '{bn=$0; sub(/.*\//,"",bn); if (bn !~ /\./) print $0}' \
  | sort -u; } || true )"

# %dir entries from the generated inc (strip the %dir %attr(...) prefix to the path)
inc_dirs="$( { grep -E '^%dir' "$INC" \
  | sed -E 's/^%dir[[:space:]]+(%attr\([^)]*\)[[:space:]]+)?//' \
  | awk '{print $1}' \
  | sort -u; } || true )"

[[ -n "$inc_dirs" ]] || { echo "no %dir entries parsed from $INC"; exit 1; }

echo "=== (a) no path is BOTH a bare %files payload dir AND an inc %dir entry (minus allowlist) ==="
# Intersection of bare_dirs and inc_dirs = double-listed directories.
double="$(comm -12 <(printf '%s\n' "$bare_dirs" | sed '/^$/d' | sort -u) \
                   <(printf '%s\n' "$inc_dirs"  | sed '/^$/d' | sort -u) || true)"
# Drop the documented allowlist.
offenders="$(comm -23 <(printf '%s\n' "$double"    | sed '/^$/d' | sort -u) \
                      <(printf '%s\n' "$ALLOWLIST" | sed '/^$/d' | sort -u) || true)"
offenders="$(printf '%s\n' "$offenders" | sed '/^$/d')"
if [[ -z "$offenders" ]]; then
  ok "no un-allowlisted double-listed directories"
else
  no "double-listed directory/ies found (bare %files payload + inc %dir)" "$(printf '%s' "$offenders" | tr '\n' ' ')"
fi

echo "=== (b) /usr/lib/nftban payload dirs are listed as <dir>/* (contents), not bare ==="
# These dirs are inc-%dir'd AND non-empty at package time -> must use /* form.
for d in bin sbin cli core lib cron helpers setup exporters data health; do
  if printf '%s\n' "$files_section" | grep -qE "^/usr/lib/nftban/${d}/\*[[:space:]]*$"; then
    ok "/usr/lib/nftban/${d}/* present (contents-only)"
  else
    no "/usr/lib/nftban/${d}/* MISSING — dir may be bare-listed (double-list) or absent"
  fi
  # And the bare form must NOT also appear.
  if printf '%s\n' "$files_section" | grep -qE "^/usr/lib/nftban/${d}[[:space:]]*$"; then
    no "/usr/lib/nftban/${d} STILL bare-listed (would double-list inc %dir)"
  fi
done

echo "=== (c) empty tests/ payload line is DROPPED (no bare line, no /* glob) ==="
if printf '%s\n' "$files_section" | grep -qE '^/usr/lib/nftban/tests([[:space:]]|/\*|$)'; then
  no "/usr/lib/nftban/tests still listed in %files — must be dropped (empty after .gitkeep strip)"
else
  ok "/usr/lib/nftban/tests payload line dropped (inc %dir is sole owner of empty dir)"
fi

echo "=== (d) %install strips .gitkeep (and any dotfile) from the staged buildroot ==="
if grep -qE 'find[[:space:]]+%\{buildroot\}/usr/lib/nftban[[:space:]]+-name[[:space:]].*-type[[:space:]]+f[[:space:]]+-delete' "$SPEC"; then
  ok ".gitkeep/dotfile strip present in %install (prevents 'unpackaged .gitkeep' on /*)"
else
  no ".gitkeep dotfile strip MISSING from %install — /* over tests/ would leave .gitkeep unpackaged"
fi

echo "=== (e) documented bare exceptions are still present (templates + selinux) ==="
for ex in /usr/share/nftban/templates /usr/share/nftban/selinux; do
  if printf '%s\n' "$files_section" | grep -qE "^${ex}[[:space:]]*$"; then
    ok "$ex bare line present (documented exception)"
  else
    no "$ex bare line MISSING — exception removed without generator support"
  fi
done

echo "================================================================"
echo "rpm_files_no_double_dir_listing_v164: PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[[ $FAIL -eq 0 ]]
