#!/usr/bin/env bash
# =============================================================================
# NFTBan CI — P7: only the fenced writer may emit an NFTBan system include
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="check-system-include-writer-authority"
# meta:type="ci"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-06"
# meta:description="v1.229.13 Lane 3E rule P7. The distro nftables.conf include is owned by ONE authority: render.IntegrateSystemConf, which writes a FENCED BEGIN/END marker block that the postrm/%postun strip twin can find and remove. A shell helper that emits its own include is a competing mechanism: unfenced (invisible to both the writer and the remover), destructive to operator rules, and — after Lane 3D.4 moved boot authority to the generated projection — able to silently RESURRECT the retired legacy path. This guard fails the build if any shell file emits an NFTBan include line. Comments are stripped first: documenting the retired path is not emitting it."
# meta:inventory.files="cli/lib/nftban/helpers/autoheal.sh,internal/installer/render/sysconf.go"
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
rc=0
ok(){ printf '  PASS  %s\n' "$1"; }
bad(){ rc=1; printf '  FAIL  %s\n' "$1"; }

# Shell files that legitimately MATCH an include (removers, tests) are distinguished from
# files that EMIT one. Emission = the include text appears on a line that writes output:
# a heredoc body, a printf/echo, or a redirection target.
INCLUDE_RE='include[[:space:]]+"/etc/nftban/[^"]*"'

# Strip full-line comments so a documented path is never mistaken for an emission.
strip_sh_comments(){ sed -e 's/^[[:space:]]*#.*$//' "$1"; }

echo "== P7 subject population =="
mapfile -t SHELL_FILES < <(find "$ROOT/cli" "$ROOT/packaging" "$ROOT/install" -name '*.sh' -type f 2>/dev/null | sort)
echo "  shell files scanned: ${#SHELL_FILES[@]}"
if [[ "${#SHELL_FILES[@]}" -eq 0 ]]; then
    bad "SUBJECT POPULATION IS ZERO — a guard over nothing is a false green"
    exit "$rc"
fi
ok "subject population is non-vacuous (${#SHELL_FILES[@]} shell files)"

echo "== P7 emitters =="
HITS=""
for f in "${SHELL_FILES[@]}"; do
    case "$f" in */tests/*) continue;; esac          # tests may assert on the text
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        HITS+="${f#$ROOT/}:${line}"$'\n'
    done < <(strip_sh_comments "$f" | grep -nE "$INCLUDE_RE" | head -5)
done

if [[ -z "$HITS" ]]; then
    ok "no shell file emits an NFTBan system include (P7 ENFORCED)"
else
    bad "shell file(s) emit an NFTBan system include — competing include authority:"
    printf '%s' "$HITS" | sed 's/^/        /'
    printf '        %s\n' \
      "The managed include is owned by render.IntegrateSystemConf (fenced BEGIN/END)." \
      "A shell-emitted include is UNFENCED: invisible to that writer AND to the" \
      "postrm/%postun strip twin, and after Lane 3D.4 it resurrects the RETIRED" \
      "legacy path as boot authority. Detect and report instead; route repair" \
      "through nftban-installer --repair."
fi

# --------------------------------------------------------------- self-test
if [[ "${1:-}" == "--self-test" ]]; then
    echo "== NEGATIVE CONTROL =="
    TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
    mkdir -p "$TMP/cli"
    cat > "$TMP/cli/inject.sh" <<'INJ'
#!/usr/bin/env bash
cat > /etc/nftables.conf << 'EOFX'
include "/etc/nftban/nftables.conf"
EOFX
INJ
    if strip_sh_comments "$TMP/cli/inject.sh" | grep -qE "$INCLUDE_RE"; then
        ok "NEGATIVE CONTROL: an injected shell-emitted include IS detected"
    else
        bad "NEGATIVE CONTROL FAILED — guard blind to the motivating defect"
    fi
    cat > "$TMP/cli/mention.sh" <<'INJ'
#!/usr/bin/env bash
# Historically this wrote include "/etc/nftban/nftables.conf" — it must not any more.
true
INJ
    if strip_sh_comments "$TMP/cli/mention.sh" | grep -qE "$INCLUDE_RE"; then
        bad "NEGATIVE CONTROL FAILED — guard flags a COMMENT, not an emission"
    else
        ok "NEGATIVE CONTROL: a comment-only mention is NOT flagged"
    fi
fi
exit "$rc"
