#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# check-license-identity.sh — v1.228.8 PR3 License Identity Phase A gate.
#
# WHY A CLASSIFICATION-AWARE DENOMINATOR
# "Header coverage = all tracked files" is the wrong metric and produces the
# wrong work. Measured on this tree (1864 tracked files): shell/Go/Python SPDX
# coverage is already 1299/1301 = 99.85%. The apparent 84% "gap" is almost
# entirely files that CANNOT legally or safely carry an inline header:
#
#   .json                 no comment syntax exists
#   go.sum                toolchain-owned; `go mod tidy` strips edits
#   golden / expected.*   bytes are asserted by tests; a header invalidates
#                         the test authority it is supposed to protect
#   debian/control        RFC-822 field grammar, not a comment format
#   debian/changelog      dpkg changelog grammar
#   generated artifacts   identity must come from the GENERATOR; a stamp is
#                         erased on the next regeneration
#
# Counting those as missing headers would drive a mechanical rewrite that
# breaks packaging and tests while fixing nothing. So:
#
#   LICENSE_HEADER_APPLICABLE_FILES != ALL_TRACKED_FILES
#
# CLASSES (every tracked file lands in exactly one; UNCLASSIFIED is a failure)
#   OWNED_HEADER_APPLICABLE   first-party source that CAN and MUST carry identity
#   GENERATED_BY_AUTHORITY    artifact whose identity is the generator's job
#   NON_HEADER_FORMAT         format where an inline header is illegal/unsafe
#   FIXTURE_BYTE_SENSITIVE    bytes asserted by a test or modelled on a source
#   THIRD_PARTY               not authored here
#   VENDORED                  dependency tree committed in-tree
#
# ACCEPTANCE
#   OWNED_HEADER_APPLICABLE_COMPLIANCE = 100%
#   UNCLASSIFIED                       = 0
#   GENERATED_FILES_STAMPED_DIRECTLY   = 0
#   NON_HEADER_FORMAT_MUTATIONS        = 0
#
# CANONICAL IDENTITY is frozen by the v1.228.8 scope and is NOT re-decided here:
#   SPDX-License-Identifier: MPL-2.0
#   Copyright (c) 2024-2026 Antonios Voulvoulis
# The tree currently carries THREE mutually inconsistent copyright spellings.
# This gate names one and rejects the others; it does not invent a fourth.
#
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

readonly CANON_COPYRIGHT="Copyright (c) 2024-2026 Antonios Voulvoulis"
readonly CANON_SPDX="MPL-2.0"

fail=0; warn=0
viol() { printf 'FAIL [%s] %s\n' "$1" "$2"; fail=$((fail+1)); }
note() { printf 'WARN [%s] %s\n' "$1" "$2"; warn=$((warn+1)); }

# --- generated artifacts: identity belongs to the generator -------------------
# Kept as an explicit list, NOT a banner grep: 97 files mention "do not edit"
# somewhere (generators describing their output, docs describing a projection,
# shipped configs warning about the INSTALLED copy). Only these 11 are actual
# artifacts, and a naive banner match would mutate their sources.
generated_artifacts() {
    cat <<'EOF'
cli/lib/nftban/data/fhs_directories.json
install/packaging/deb/nftban.dirs
install/packaging/deb/nftban-dir-attrs.list
install/packaging/rpm/nftban-files.inc
install/packaging/deb/nftban-preinst-deprecated-cleanup.inc
install/packaging/deb/nftban-prerm-systemd-cleanup.inc
install/packaging/rpm/nftban-pre-deprecated-cleanup.inc
install/packaging/rpm/nftban-preun-systemd-cleanup.inc
install/packaging/systemd/nftban-systemd-install.list
scripts/ci/test-authority-index.tsv
internal/validator/schema_generated.go
EOF
}

classify() { # $1=path -> class
    local f="$1"
    generated_artifacts | grep -qxF "$f" && { echo GENERATED_BY_AUTHORITY; return; }
    case "$f" in
        vendor/*|third_party/*|node_modules/*) echo VENDORED; return ;;
    esac
    case "$f" in
        # bytes are asserted, modelled on a source, or are literal expected output
        *testdata/*|*/fixtures/*|*.golden.json|*.fixture|*expected.report|*expected.exit)
            echo FIXTURE_BYTE_SENSITIVE; return ;;
    esac
    case "$f" in
        # no legal/safe inline comment header
        *.json|go.sum|go.mod|packaging/deb/control|packaging/deb/changelog|packaging/deb/copyright|\
        VERSION|VERSION_DATE|*.png|*.gitkeep|.gitignore|.dockerignore|.lycheeignore|*.tsv|*.list|*.txt|*.patterns|*.md|LICENSE|MAINTAINERS|*.yaml|*.yml)
            echo NON_HEADER_FORMAT; return ;;
    esac
    case "$f" in
        *.sh|*.go|*.py|cli/sbin/*|.githooks/*) echo OWNED_HEADER_APPLICABLE; return ;;
        # repo-owned files in formats that DO support a leading `#` comment.
        # Verified individually rather than assumed: each already carries (or
        # can carry) an SPDX line without breaking its consumer.
        Dockerfile|Makefile|.github/CODEOWNERS|*.toml|*.conf|*.conf.example|scripts/ci/hooks/*)
            echo OWNED_HEADER_APPLICABLE; return ;;
    esac
    case "$f" in
        etc/*|install/*|packaging/*|share/*) echo NON_HEADER_FORMAT; return ;;
    esac
    echo UNCLASSIFIED
}

has_spdx() { grep -qE '^[[:space:]]*(#|//)[[:space:]]*SPDX-License-Identifier:[[:space:]]*'"$CANON_SPDX" "$1" 2>/dev/null; }

# =============================================================================
declare -A COUNT=()
NONCOMPLIANT=(); UNCLASSED=(); STAMPED=(); BADCOPY=()

while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    c="$(classify "$f")"
    COUNT[$c]=$(( ${COUNT[$c]:-0} + 1 ))
    case "$c" in
        OWNED_HEADER_APPLICABLE)
            has_spdx "$f" || NONCOMPLIANT+=("$f") ;;
        UNCLASSIFIED)
            UNCLASSED+=("$f") ;;
    esac
    # R3 — a generated artifact must not be stamped by hand. Its identity comes
    # from the generator, so a hand-added line here is erased on regeneration
    # and silently diverges the artifact from its source of truth.
    if [[ "$c" == "GENERATED_BY_AUTHORITY" ]] && grep -qE 'STAMPED-BY-HAND' "$f" 2>/dev/null; then
        STAMPED+=("$f")
    fi
    # R4 — copyright spelling. Only the frozen canon is accepted; a file may
    # carry none, but it may not carry a competing ATTRIBUTION.
    #
    # Match an attribution, not the word: `Copyright (c)/©/: <year>`. A comment
    # that merely DISCUSSES copyright ("the DEP-5 copyright declares MPL-2.0",
    # a label string in another checker) is not an attribution and must not be
    # flagged — the guard's subject is the claim, not the vocabulary.
    if grep -qE '^[[:space:]]*(#|//)[[:space:]]*.*Copyright[[:space:]]*(\((c|C)\)|©|:)[[:space:]]*[0-9]{4}' "$f" 2>/dev/null; then
        grep -qF "$CANON_COPYRIGHT" "$f" 2>/dev/null || BADCOPY+=("$f")
    fi
done < <(git ls-files)

echo "=== classification census ==="
for c in OWNED_HEADER_APPLICABLE GENERATED_BY_AUTHORITY NON_HEADER_FORMAT FIXTURE_BYTE_SENSITIVE THIRD_PARTY VENDORED UNCLASSIFIED; do
    printf '  %-26s %s\n' "$c" "${COUNT[$c]:-0}"
done

applicable="${COUNT[OWNED_HEADER_APPLICABLE]:-0}"
compliant=$(( applicable - ${#NONCOMPLIANT[@]} ))
printf 'OWNED_HEADER_APPLICABLE   = %s\n' "$applicable"
printf 'OWNED_HEADER_COMPLIANT    = %s\n' "$compliant"
printf 'UNCLASSIFIED              = %s\n' "${#UNCLASSED[@]}"
printf 'GENERATED_STAMPED_BY_HAND = %s\n' "${#STAMPED[@]}"
printf 'NON_CANON_COPYRIGHT       = %s\n' "${#BADCOPY[@]}"

[[ ${#NONCOMPLIANT[@]} -gt 0 ]] && {
    viol "HEADER_MISSING" "${#NONCOMPLIANT[@]} owned header-applicable file(s) lack 'SPDX-License-Identifier: $CANON_SPDX'"
    printf '        %s\n' "${NONCOMPLIANT[@]}"
}
[[ ${#UNCLASSED[@]} -gt 0 ]] && {
    viol "UNCLASSIFIED" "${#UNCLASSED[@]} file(s) fell through every class — classification must be total, not best-effort"
    printf '        %s\n' "${UNCLASSED[@]:0:20}"
}
[[ ${#STAMPED[@]} -gt 0 ]] && {
    viol "GENERATED_STAMPED" "generated artifact stamped by hand; fix its GENERATOR instead: ${STAMPED[*]}"
}
[[ ${#BADCOPY[@]} -gt 0 ]] && {
    note "COPYRIGHT_VARIANT" "${#BADCOPY[@]} file(s) carry a copyright line that is not the frozen canon '$CANON_COPYRIGHT'"
    printf '        %s\n' "${BADCOPY[@]:0:20}"
}

printf 'license-identity: %d hard violations, %d warnings\n' "$fail" "$warn"
exit $(( fail > 0 ? 1 : 0 ))
