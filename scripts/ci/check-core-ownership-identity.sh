#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# check-core-ownership-identity.sh — v1.228.9 PR2 Core ownership identity gate.
#
# WHY
# The repository carried NINE different renderings of Core ownership across its
# legal documents — `©` vs `(c)` vs a bare `Copyright:` field, en-dash vs
# hyphen, `NFTBAN` vs `NFTBan`, some with a trailing period, and one that named
# no project at all. They disagreed with each other and with the frozen source
# canon, so "who owns NFTBan Core" had no single answer a reader could rely on.
#
# ⛔ THIS IS A SEMANTIC GATE, NOT A BYTE-EQUALITY GREP.
# Different surfaces have different grammars and must be allowed to render the
# same ownership differently. DEP-5 legitimately writes
#     Copyright: 2024-2026 Antonios Voulvoulis
# with no `(c)` at all, and that is CORRECT — it is the format's own spelling.
# A repository-wide search for one exact string would reject valid metadata and
# push people toward writing invalid metadata to satisfy a linter.
#
# So each surface is parsed to its SEMANTICS and those are compared:
#     HOLDER  ==  Antonios Voulvoulis
#     YEARS   ==  2024-2026
#     LICENSE ==  MPL-2.0            (where the surface declares one)
#
# This mirrors the licence-identity check in check-license-metadata.sh: an SPDX
# identifier, a DEP-5 field and an OCI label are different strings in different
# grammars that must name the same licence.
#
# FROZEN AUTHORITY (owner 2026-08-09):
#     CORE_COPYRIGHT_HOLDER = Antonios Voulvoulis
#     CORE_COPYRIGHT_YEARS  = 2024-2026
#     PROJECT_NAME_IS_OWNER = NO
# "NFTBan Project / Antonios Voulvoulis" and its variants are RETIRED: the
# project name is not a copyright holder.
#
# SCOPE: Core only. The Pro tree, its absent licence instrument and the archived
# Core serialisations are deliberately untouched — tracked under
# OPEN_PRO_TREE_VERSION_CONTROL_AND_LEGAL_BOUNDARY.
#
set -Eeuo pipefail

REPO_ROOT="${OWNERSHIP_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
REGISTRY="$REPO_ROOT/scripts/ci/data/legal-identity-surfaces.tsv"

readonly CORE_HOLDER="Antonios Voulvoulis"
readonly CORE_YEARS="2024-2026"
readonly CORE_LICENSE="MPL-2.0"
# Renderings that name the project as an owner. Retired: a project name is not
# a legal person and cannot hold copyright.
# Case-insensitive: the tree spells it both NFTBAN and NFTBan, and a
# case-sensitive detector would pass half the retired forms.
readonly RETIRED_HOLDER_RE='[Nn][Ff][Tt][Bb][Aa][Nn]?[[:space:]]*([Pp]roject)?[[:space:]]*/'

fail=0; warn=0
bad()  { printf '  [FAIL] %s\n' "$1"; fail=$((fail + 1)); }
ok()   { printf '  [OK] %s\n' "$1"; }
note() { printf '  [..] %s\n' "$1"; warn=$((warn + 1)); }

[[ -f "$REGISTRY" ]] || { echo "FAIL: surface registry missing: $REGISTRY"; exit 2; }

# Normalise a copyright rendering to its semantics.
#   in : any single copyright line, any grammar
#   out: "HOLDER|YEARS"  (empty field = not extractable)
parse_identity() {
    local line="$1" years holder
    # years: 2024-2026 / 2024–2026 (en-dash) / 2024
    years="$(printf '%s' "$line" | grep -oE '[0-9]{4}[[:space:]]*[-–—][[:space:]]*[0-9]{4}|[0-9]{4}' | head -1)"
    years="${years//[[:space:]]/}"
    years="${years//–/-}"; years="${years//—/-}"   # en/em dash -> hyphen
    # holder: everything after the year run, minus trailing punctuation and
    # trailing prose such as "All rights reserved" or markup
    holder="$(printf '%s' "$line" \
        | sed -E 's/.*[0-9]{4}([[:space:]]*[-–—][[:space:]]*[0-9]{4})?[[:space:]]*//' \
        | sed -E 's/<[^>]*>//g; s/\|.*$//' \
        | sed -E 's/[[:space:]]*All rights reserved.*$//I' \
        | sed -E 's/[.,;]+[[:space:]]*$//' \
        | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    printf '%s|%s' "$holder" "$years"
}

echo "== Core ownership identity (semantic, per-surface grammar) =="
printf '   authority: holder=%s years=%s license=%s\n\n' "$CORE_HOLDER" "$CORE_YEARS" "$CORE_LICENSE"

classified=0
# owner_auth/years_auth are read to keep the row shape explicit and to make a
# future per-surface authority override a data change rather than a code change;
# today every classified surface answers to CORE.
# shellcheck disable=SC2034
while IFS=$'\t' read -r path klass required owner_auth years_auth lic_auth; do
    [[ -z "$path" || "${path:0:1}" == "#" ]] && continue
    classified=$((classified + 1))
    f="$REPO_ROOT/$path"

    if [[ ! -f "$f" ]]; then
        if [[ "$required" == "YES" ]]; then
            bad "$path is a REQUIRED legal-identity surface and is MISSING"
        else
            note "$path absent (not required)"
        fi
        continue
    fi

    line="$(grep -hoE 'Copyright[^"<|]{0,80}' "$f" 2>/dev/null | head -1 || true)"
    if [[ -z "$line" ]]; then
        bad "$path ($klass) carries no copyright line"
        continue
    fi

    # A retired holder form is a competing ownership identity, regardless of
    # whether the canonical holder also appears in the same line.
    if [[ "$(printf '%s' "$line" | grep -cE "$RETIRED_HOLDER_RE" || true)" -gt 0 ]]; then
        bad "$path names the PROJECT as an owner (retired form): ${line:0:64}"
        continue
    fi

    ident="$(parse_identity "$line")"
    holder="${ident%%|*}"; years="${ident##*|}"

    if [[ "$holder" != "$CORE_HOLDER" ]]; then
        bad "$path holder is '$holder', authority is '$CORE_HOLDER'"
    elif [[ "$years" != "$CORE_YEARS" ]]; then
        bad "$path years are '$years', authority is '$CORE_YEARS'"
    else
        ok "$path ($klass) resolves to holder=$holder years=$years"
    fi

    if [[ "$lic_auth" == "CORE" ]]; then
        grep -qE 'MPL-2\.0|Mozilla Public License' "$f" \
            && ok "$path declares the Core licence" \
            || bad "$path is a licence-declaring surface but does not name $CORE_LICENSE"
    fi
done < "$REGISTRY"

# Population coverage: a surface removed from the registry must not silently
# stop being checked. Any file carrying a Core-looking copyright attribution
# has to be classified.
echo
echo "== registry coverage =="
unclassified=0
while IFS= read -r f; do
    grep -qxF "$f" <(grep -vE '^[[:space:]]*(#|$)' "$REGISTRY" | cut -f1) && continue
    case "$f" in *test*|*fixtures*) continue ;; esac   # negative-control fixtures
    # source headers are governed by check-license-identity.sh, not this gate
    case "$f" in *.sh|*.go|*.py|cli/sbin/*|*.conf|*.rules) continue ;; esac
    # The gate's own machinery DESCRIBES the canon (the surface registry header,
    # the CI step comment). Documentation of a rule is not a claim of ownership,
    # and matching it here would let this gate fail on its own explanation.
    case "$f" in *.tsv|*.yml|*.yaml) continue ;; esac
    # generated artifacts take their identity from their GENERATOR (v1.228.8
    # PR3) and are asserted by the parser/licence gates; stamping them here
    # would duplicate an authority and invite hand-editing a generated file.
    case "$f" in \
        cli/lib/nftban/data/fhs_directories.json|\
        install/packaging/deb/nftban.dirs|\
        install/packaging/deb/nftban-dir-attrs.list|\
        install/packaging/rpm/nftban-files.inc|\
        install/packaging/systemd/nftban-systemd-install.list|\
        scripts/ci/test-authority-index.tsv|\
        internal/validator/schema_generated.go) continue ;;
    esac
    bad "UNCLASSIFIED legal-identity surface: $f carries a copyright attribution but is not in the registry"
    unclassified=$((unclassified + 1))
done < <(cd "$REPO_ROOT" && git grep -lE 'Copyright[[:space:]]*(\((c|C)\)|©|:)?[[:space:]]*[0-9]{4}' -- . 2>/dev/null || true)
[[ $unclassified -eq 0 ]] && ok "every copyright-bearing non-source file is classified"

echo
printf 'CORE_LEGAL_IDENTITY_SURFACES_CLASSIFIED = %d\n' "$classified"
printf 'OWNER_HOLDER_DIVERGENCE / OWNER_YEAR_DIVERGENCE / COMPETING_CORE_OWNER_IDENTITIES = %d total\n' "$fail"
printf 'core-ownership-identity: %d hard violations, %d notes\n' "$fail" "$warn"
exit $(( fail > 0 ? 1 : 0 ))
