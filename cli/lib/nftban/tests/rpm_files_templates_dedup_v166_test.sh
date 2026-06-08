#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.166 PR-C guard: templates RPM %files dedup via FHS-generator fix
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="rpm_files_templates_dedup_v166_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-08"
# meta:description="Hermetic guard for the v1.166 PR-C templates RPM %files dedup. The bare /usr/share/nftban/templates %files line both double-listed the generator %dir-owned dirs AND was the sole owner of the email/ + partials/ staged .html (which had no inc %dir), so it could not simply be dropped. PR-C adds %dir for templates/email + templates/partials to the FHS generator (build/fhs-spec.yaml -> nftban-files.inc), keeps zabbix as an empty %dir, lists the four content subdirs as <dir>/*, and strips dotfiles in %install so the /* glob is complete. This guard asserts: (a) the bare /usr/share/nftban/templates line is gone; (b) mail/reports/email/partials are listed as <dir>/*; (c) the generator inc %dir-owns email + partials (and still mail/reports/zabbix); (d) the templates %install dotfile strip exists; (e) no /usr/share/nftban/templates path is both a bare %files line and an inc %dir entry. Static; no rpmbuild/host."
# meta:inventory.files="packaging/build_nftban.sh,install/packaging/rpm/nftban-files.inc"
# meta:inventory.binaries="bash,grep"
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

echo "rpm-files templates dedup guard (v1.166 PR-C):"

# --- (a) bare /usr/share/nftban/templates %files line is gone -----------------
bare=$(grep -cE '^/usr/share/nftban/templates[[:space:]]*$' "$BS" || true)
[[ "$bare" -eq 0 ]] \
    && ok "no bare /usr/share/nftban/templates %files line" \
    || no "bare /usr/share/nftban/templates line still present ($bare)"

# --- (b) the four content subdirs are <dir>/* ---------------------------------
for d in mail reports email partials; do
    g=$(grep -cE "^/usr/share/nftban/templates/${d}/\*[[:space:]]*\$" "$BS" || true)
    [[ "$g" -ge 1 ]] \
        && ok "templates/${d} listed as /usr/share/nftban/templates/${d}/*" \
        || no "templates/${d} not listed as <dir>/* ($g)"
done

# --- (c) generator inc %dir-owns email + partials (+ mail/reports/zabbix) ------
for d in mail reports email partials zabbix; do
    i=$(grep -cE "^%dir .* /usr/share/nftban/templates/${d}\$" "$INC" || true)
    [[ "$i" -ge 1 ]] \
        && ok "inc %dir owns templates/${d}" \
        || no "inc %dir MISSING for templates/${d} (run build/generate-fhs-outputs.sh)"
done

# --- (d) templates %install dotfile strip present -----------------------------
if grep -qE 'find %\{buildroot\}/usr/share/nftban/templates -name .\.\*. -type f -delete' "$BS"; then
    ok "%install strips dotfiles from the staged templates tree (/* glob safe)"
else
    no "missing templates dotfile strip (find %{buildroot}/usr/share/nftban/templates -name '.*' -type f -delete)"
fi

# --- (e) no templates path is both a bare %files line and an inc %dir ----------
mapfile -t bare_files < <(grep -E '^/usr/share/nftban/templates[A-Za-z0-9_./-]*[[:space:]]*$' "$BS" \
    | grep -vE '/\*[[:space:]]*$' | sed 's/[[:space:]]*$//' | sort -u)
mapfile -t inc_dirs < <(grep -E '^%dir .* /usr/share/nftban/templates' "$INC" \
    | sed -E 's/^.* (\/usr\/share\/nftban\/templates[A-Za-z0-9_./-]*)[[:space:]]*$/\1/' | sort -u)
double=""
for p in "${bare_files[@]:-}"; do
    [[ -z "$p" ]] && continue
    for q in "${inc_dirs[@]:-}"; do [[ "$p" == "$q" ]] && double+="$p"$'\n'; done
done
[[ -z "$double" ]] \
    && ok "no templates path is both a bare %files line and an inc %dir entry" \
    || no "templates double-listed (bare %files AND inc %dir)" "$(printf '%s' "$double" | head -1)"

# --- (f) self-test: detector catches a re-introduced bare templates line ------
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
{ cat "$BS"; echo '/usr/share/nftban/templates'; } > "$tmp"
reintro=$(grep -cE '^/usr/share/nftban/templates[[:space:]]*$' "$tmp" || true)
[[ "$reintro" -ge 1 ]] \
    && ok "self-test: a re-introduced bare templates line is detectable" \
    || no "self-test FAILED: could not detect a re-introduced bare templates line"

echo ""
echo "  PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
