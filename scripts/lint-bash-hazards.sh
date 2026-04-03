#!/usr/bin/env bash
# =============================================================================
# NFTBan Bash Hazard Lint (H1 + H2)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="lint_bash_hazards"
# meta:type="ci"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-04-03"
# meta:description="CI lint: detect nft handle grep without -a flag and set -e hazard patterns"
# meta:input="None"
# meta:output="PASS/FAIL lint result to stdout"
# meta:depends=""
# meta:inventory.files="scripts/lint-bash-hazards.sh"
# meta:inventory.binaries="grep,awk"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# Gates:
#   H1: Reject `nft list` without `-a` when output is grepped for `# handle`
#   H2: Reject `[[ ... ]] && <action>` as last statement before `}` or `fi`
#       (under set -e, false condition = exit 1 = script abort)
#   H3: Reject subshell `)` followed by `=$?` on next line
#       (under set -e, non-zero subshell exit kills before $? is captured)
#
# Exit codes:
#   0  All checks passed
#   1  One or more violations found
# =============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

failures=0

# Scan scope: all shell scripts in cli/ (runtime code)
CLI_DIR="${REPO_ROOT}/cli/lib/nftban"

# =============================================================================
# H1: nft list without -a flag when grepping for "# handle"
# =============================================================================
# `nft list chain/table ...` does NOT include `# handle N` annotations.
# Only `nft -a list ...` does. If we grep for "# handle" without -a,
# the count is always 0 — a silent detection failure.
# =============================================================================

echo "=== H1: Checking for nft handle grep without -a flag ==="
h1_violations=0

# Single-line: nft list ... | grep ... "# handle" (without -a)
while IFS=: read -r file lineno content; do
    # Skip if it has nft -a
    if echo "$content" | grep -q 'nft -a' 2>/dev/null; then
        continue
    fi
    # Skip comment lines
    stripped=$(echo "$content" | sed 's/^[[:space:]]*//')
    [[ "$stripped" == \#* ]] && continue

    echo "::error file=${file},line=${lineno}::H1 VIOLATION: 'nft list' without '-a' piped to 'grep # handle'"
    echo "  ${lineno}: ${content}"
    h1_violations=$((h1_violations + 1))
done < <(grep -rn 'nft list.*|.*grep.*# handle' "$CLI_DIR" --include="*.sh" 2>/dev/null || true)

# Multi-line: nft list ... \ (continuation) + grep "# handle" on next line
while IFS=: read -r file lineno content; do
    # Skip if it already has -a
    echo "$content" | grep -q 'nft -a' 2>/dev/null && continue
    # Skip comment lines
    stripped=$(echo "$content" | sed 's/^[[:space:]]*//')
    [[ "$stripped" == \#* ]] && continue
    # Check if next line has "# handle"
    next_line=$(sed -n "$((lineno + 1))p" "$file" 2>/dev/null || true)
    if echo "$next_line" | grep -q '# handle' 2>/dev/null; then
        echo "::error file=${file},line=${lineno}::H1 VIOLATION: 'nft list' without '-a' (multi-line pipe to '# handle')"
        echo "  ${lineno}: ${content}"
        h1_violations=$((h1_violations + 1))
    fi
done < <(grep -rn 'nft list.*\\$' "$CLI_DIR" --include="*.sh" 2>/dev/null || true)

if [[ $h1_violations -gt 0 ]]; then
    echo ""
    echo "FAIL: $h1_violations H1 violation(s) — use 'nft -a list' when grepping for '# handle'"
    failures=$((failures + h1_violations))
else
    echo "PASS: No nft handle grep without -a flag"
fi

echo ""

# =============================================================================
# H2: [[ ... ]] && action as last statement (set -e hazard)
# =============================================================================
# Under set -Eeuo pipefail, if `[[ test ]] && action` is the last command
# in a function/block and the test is false, the line returns exit 1.
# The caller sees exit 1 → ERR trap fires → script aborts.
#
# Safe patterns (excluded):
#   [[ test ]] && action || true
#   [[ test ]] && action || :
#   [[ test ]] && action || return
#   [[ test ]] && action || false
#
# Strategy: use grep -n to find candidate lines, then check if the NEXT
# non-blank line is }, fi, or done. Much faster than line-by-line read.
# =============================================================================

echo "=== H2: Checking for set -e hazard patterns ==="
h2_violations=0

# Step 1: Find all [[ ]] && lines that lack || true/:/false/return
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

grep -rn '\[\[.*\]\].*&&' "$CLI_DIR" --include="*.sh" 2>/dev/null \
    | grep -v '\|\|[[:space:]]*\(true\|:\|false\|return\)' \
    | grep -v '^\s*#' \
    | grep -v '^[^:]*:[^:]*:\s*#' \
    > "$TMPFILE" || true

# Step 2: For each candidate, check if the next non-blank line closes a block
while IFS= read -r match; do
    file=$(echo "$match" | cut -d: -f1)
    lineno=$(echo "$match" | cut -d: -f2)
    content=$(echo "$match" | cut -d: -f3-)

    # Skip comment lines (extra safety)
    stripped=$(echo "$content" | sed 's/^[[:space:]]*//')
    [[ "$stripped" == \#* ]] && continue

    # Look at the next non-blank line
    next_lineno=$((lineno + 1))
    next_line=""
    # Read up to 3 lines ahead to skip blanks
    for offset in 1 2 3; do
        candidate=$(sed -n "$((lineno + offset))p" "$file" 2>/dev/null || true)
        candidate_stripped=$(echo "$candidate" | sed 's/^[[:space:]]*//')
        if [[ -n "$candidate_stripped" ]]; then
            next_line="$candidate_stripped"
            next_lineno=$((lineno + offset))
            break
        fi
    done

    # Check if next non-blank line closes a block
    case "$next_line" in
        "}"*|"fi"*|"done"*|"esac"*)
            echo "::error file=${file},line=${lineno}::H2 VIOLATION: '[[ ]] && action' before '${next_line}' — exits 1 under set -e"
            echo "  ${lineno}: ${content}"
            echo "  ${next_lineno}: ${next_line}"
            echo "  Fix: add '|| true' or use 'if [[ ]]; then action; fi'"
            h2_violations=$((h2_violations + 1))
            ;;
    esac
done < "$TMPFILE"

if [[ $h2_violations -gt 0 ]]; then
    echo ""
    echo "FAIL: $h2_violations H2 violation(s) — add '|| true' or use if/then/fi"
    failures=$((failures + h2_violations))
else
    echo "PASS: No set -e hazard patterns found"
fi

echo ""

# =============================================================================
# H3: Subshell/command exit captured via $? on next line (set -e hazard)
# =============================================================================
# Pattern:
#   )           ← subshell closes with non-zero exit
#   var=$?      ← never reached — set -e already killed the script
#
# Safe pattern:
#   ) || _var=$?            ← non-zero captured inline
#   ) || true; _var=$?      ← suppressed, then captured
#   if ( ... ); then        ← conditional context, set -e doesn't fire
#
# Strategy: find lines that are just `)` followed by a line containing `=$?`
# =============================================================================

echo "=== H3: Checking for subshell exit capture via \$? on next line ==="
h3_violations=0

# Find all closing-paren lines `)` and check if next line captures $?
while IFS=: read -r file lineno content; do
    stripped=$(echo "$content" | sed 's/^[[:space:]]*//')
    # Must be a standalone `)` — not part of case pattern or inline
    [[ "$stripped" != ")" ]] && continue

    # Check next line for =$?
    next_line=$(sed -n "$((lineno + 1))p" "$file" 2>/dev/null || true)
    next_stripped=$(echo "$next_line" | sed 's/^[[:space:]]*//')

    if echo "$next_stripped" | grep -qE '=\$\?' 2>/dev/null; then
        # This is the hazard: ) on one line, $? capture on next
        # Check it's not already guarded with || on the ) line itself
        echo "::error file=${file},line=${lineno}::H3 VIOLATION: subshell ')' followed by '\$?' capture — set -e kills before capture"
        echo "  ${lineno}: ${content}"
        echo "  $((lineno + 1)): ${next_line}"
        echo "  Fix: use ') || var=\$?' or ') || true' on the closing paren line"
        h3_violations=$((h3_violations + 1))
    fi
done < <(grep -rn '^\s*)$' "$CLI_DIR" --include="*.sh" 2>/dev/null || true)

if [[ $h3_violations -gt 0 ]]; then
    echo ""
    echo "FAIL: $h3_violations H3 violation(s) — capture exit inline with '|| var=\$?'"
    failures=$((failures + h3_violations))
else
    echo "PASS: No subshell exit capture hazards found"
fi

echo ""

# =============================================================================
# SUMMARY
# =============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ $failures -gt 0 ]]; then
    echo "FAIL: $failures bash hazard violation(s) found"
    exit 1
else
    echo "PASS: All bash hazard checks passed (H1 + H2 + H3)"
    exit 0
fi
