#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Bash Runtime & Config Hygiene Static Analysis Test
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Automated static analysis checks for shell safety, meta tags,
#          config loading order, and module guard patterns across all
#          .sh files under cli/lib/nftban/.
#
# meta:name="03_bash_runtime_test"
# meta:type="test"
# meta:header="Bash Runtime Review Test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
# meta:description="Static analysis test for bash runtime hygiene and config safety"
# meta:input="none"
# meta:output="PASS/FAIL report per check"
# meta:depends="bash,grep,awk"
# meta:created_date="2026-02-27"
# meta:updated_date="2026-02-27"
#
# meta:inventory.files="tests/review/03_bash_runtime_test.sh"
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# CONSTANTS
# =============================================================================

# Resolve repo root (script lives in tests/review/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TARGET_DIR="${REPO_ROOT}/cli/lib/nftban"

# =============================================================================
# COUNTERS & STATE
# =============================================================================

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TOTAL_FILES=0

# Accumulate all failure detail lines for the summary
declare -a FAILURE_DETAILS=()

# =============================================================================
# HELPERS
# =============================================================================

check() {
    # Usage: check "description" pass|fail ["detail message"]
    local description="$1"
    local result="$2"
    local detail="${3:-}"

    if [[ "$result" == "pass" ]]; then
        PASS_COUNT=$(( PASS_COUNT + 1 ))
        printf "  [PASS] %s\n" "$description"
    elif [[ "$result" == "skip" ]]; then
        SKIP_COUNT=$(( SKIP_COUNT + 1 ))
        printf "  [SKIP] %s\n" "$description"
        if [[ -n "$detail" ]]; then
            printf "         %s\n" "$detail"
        fi
    else
        FAIL_COUNT=$(( FAIL_COUNT + 1 ))
        printf "  [FAIL] %s\n" "$description"
        if [[ -n "$detail" ]]; then
            printf "         %s\n" "$detail"
            FAILURE_DETAILS+=("${description}: ${detail}")
        else
            FAILURE_DETAILS+=("${description}")
        fi
    fi
}

separator() {
    printf "\n%s\n" "============================================================================="
    printf "%s\n" "$1"
    printf "%s\n\n" "============================================================================="
}

# =============================================================================
# PRE-FLIGHT VALIDATION
# =============================================================================

if [[ ! -d "$TARGET_DIR" ]]; then
    echo "ERROR: Target directory not found: ${TARGET_DIR}"
    echo "       This script must be run from the nftban repository root."
    exit 2
fi

# Collect all .sh files under cli/lib/nftban/
mapfile -t ALL_SH_FILES < <(find "$TARGET_DIR" -name '*.sh' -type f | sort)
TOTAL_FILES=${#ALL_SH_FILES[@]}

if [[ "$TOTAL_FILES" -eq 0 ]]; then
    echo "ERROR: No .sh files found under ${TARGET_DIR}"
    exit 2
fi

echo "NFTBan Bash Runtime & Config Hygiene - Static Analysis"
echo "======================================================="
echo "Target:  ${TARGET_DIR}"
echo "Files:   ${TOTAL_FILES} .sh files"
echo "Date:    $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

# =============================================================================
# CHECK 1: Strict mode (set -Eeuo pipefail)
# =============================================================================

separator "CHECK 1: Strict mode — set -Eeuo pipefail"

STRICT_MISSING=()
for f in "${ALL_SH_FILES[@]}"; do
    # Accept set -Eeuo pipefail with any leading whitespace and any spacing.
    # Also accept if the flags appear in any order as long as E, e, u, o and
    # pipefail are all present. The canonical form is: set -Eeuo pipefail
    if ! grep -qE '^[[:space:]]*set[[:space:]]+-[Eeuo]+[[:space:]]+pipefail' "$f"; then
        rel="${f#"${REPO_ROOT}/"}"
        STRICT_MISSING+=("$rel")
    fi
done

if [[ ${#STRICT_MISSING[@]} -eq 0 ]]; then
    check "All ${TOTAL_FILES} files have strict mode" "pass"
else
    detail="${#STRICT_MISSING[@]} file(s) missing strict mode"
    check "Strict mode present in all files" "fail" "$detail"
    for missing in "${STRICT_MISSING[@]}"; do
        printf "         - %s\n" "$missing"
    done
fi

# =============================================================================
# CHECK 2: No eval in production code
# =============================================================================

separator "CHECK 2: No eval usage in production code"

EVAL_HITS=()
for f in "${ALL_SH_FILES[@]}"; do
    # Skip test files — eval in tests may be acceptable
    if [[ "$f" == *"/tests/"* ]]; then
        continue
    fi
    # Look for eval as a command (not inside comments or strings like "evaluate")
    # Match: eval at word boundary, not preceded by # comment marker.
    # Since grep -n prepends "LINENO:", we filter comments by checking
    # the content after the line number prefix.
    while IFS= read -r match_line; do
        [[ -z "$match_line" ]] && continue
        # Extract content after "LINENO:" prefix
        content="${match_line#*:}"
        # Strip leading whitespace and check if it's a comment
        stripped="${content#"${content%%[![:space:]]*}"}"
        [[ "$stripped" == \#* ]] && continue
        rel="${f#"${REPO_ROOT}/"}"
        EVAL_HITS+=("${rel}:${match_line}")
    done < <(grep -nE '(^|[[:space:];|&])eval[[:space:]]' "$f" || true)
done

if [[ ${#EVAL_HITS[@]} -eq 0 ]]; then
    check "No eval usage in production code" "pass"
else
    detail="${#EVAL_HITS[@]} eval occurrence(s) found"
    check "No eval usage in production code" "fail" "$detail"
    for hit in "${EVAL_HITS[@]}"; do
        printf "         - %s\n" "$hit"
    done
fi

# =============================================================================
# CHECK 3: No unquoted variable expansions in dangerous contexts
# =============================================================================

separator "CHECK 3: No unquoted variables in dangerous contexts"

# We look for common dangerous patterns:
#   - [ $VAR ... ] (test with unquoted var — should be [[ or quoted)
#   - rm $VAR, rm -rf $VAR (unquoted path in rm)
#   - cp/mv with unquoted source/dest
#   - echo $VAR (word-splitting in echo)
# This is a heuristic check — not exhaustive but catches common issues.

UNQUOTED_HITS=()

# Helper: filter grep -n output to exclude comment lines (accounting for
# the "LINENO:" prefix that grep -n adds).
_is_comment_line() {
    local grepline="$1"
    local content="${grepline#*:}"
    local stripped="${content#"${content%%[![:space:]]*}"}"
    [[ "$stripped" == \#* ]]
}

for f in "${ALL_SH_FILES[@]}"; do
    rel="${f#"${REPO_ROOT}/"}"

    # Pattern 1: [ $VAR ] — single-bracket test with unquoted variable
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        _is_comment_line "$line" && continue
        UNQUOTED_HITS+=("${rel}:${line}  (unquoted var in [ ] test)")
    done < <(grep -nE '\[\s+\$[A-Za-z_]+[^"'\''}\]]' "$f" || true)

    # Pattern 2: rm/rm -rf with unquoted variable
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        _is_comment_line "$line" && continue
        UNQUOTED_HITS+=("${rel}:${line}  (unquoted var in rm)")
    done < <(grep -nE '(rm|rm -[rRf]+)\s+\$[A-Za-z_]+[^"'\''{}]' "$f" || true)

    # Pattern 3: cd with unquoted variable (not ${...} or "$...")
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        _is_comment_line "$line" && continue
        UNQUOTED_HITS+=("${rel}:${line}  (unquoted var in cd)")
    done < <(grep -nE 'cd\s+\$[A-Za-z_]+[^"'\''{}]' "$f" || true)
done

if [[ ${#UNQUOTED_HITS[@]} -eq 0 ]]; then
    check "No unquoted variables in dangerous contexts" "pass"
else
    detail="${#UNQUOTED_HITS[@]} unquoted variable(s) in dangerous contexts"
    check "No unquoted variables in dangerous contexts" "fail" "$detail"
    for hit in "${UNQUOTED_HITS[@]}"; do
        printf "         - %s\n" "$hit"
    done
fi

# =============================================================================
# CHECK 4: No bare cd without error handling
# =============================================================================

separator "CHECK 4: No bare cd without error handling"

# A "bare cd" is a cd command that is not followed by || on the same line,
# not inside a subshell $(), and not a pushd/popd. We also exclude comments
# and the common pattern of cd in a conditional (if cd ...; then).

BARE_CD_HITS=()
for f in "${ALL_SH_FILES[@]}"; do
    rel="${f#"${REPO_ROOT}/"}"

    # Find cd commands: lines containing cd followed by a path
    # Exclude: comments, cd with ||, cd inside $(), string literals
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # Extract content after "LINENO:" prefix
        content="${line#*:}"

        # Skip comments (strip leading whitespace first)
        stripped="${content#"${content%%[![:space:]]*}"}"
        [[ "$stripped" == \#* ]] && continue

        # Skip if line contains || (error handling present)
        [[ "$content" == *"||"* ]] && continue

        # Skip if cd is inside a $() subshell (heuristic: has $( before cd)
        if [[ "$content" == *'$('*'cd '* ]]; then
            continue
        fi

        # Skip lines inside string literals (heuristic: cd preceded by quote)
        if [[ "$content" == *'"'*'cd '* ]] || [[ "$content" == *"'"*"cd "* ]]; then
            continue
        fi

        # Skip lines where cd appears in: if cd, && cd (safe chaining)
        if [[ "$content" == *"&& cd"* ]] || [[ "$content" == *"if cd"* ]]; then
            continue
        fi

        # This line has a bare cd without || error handling
        BARE_CD_HITS+=("${rel}:${line}")
    done < <(grep -nE '(^|[[:space:];])cd[[:space:]]+' "$f" || true)
done

if [[ ${#BARE_CD_HITS[@]} -eq 0 ]]; then
    check "No bare cd without error handling" "pass"
else
    detail="${#BARE_CD_HITS[@]} bare cd command(s) without || error handling"
    check "No bare cd without error handling" "fail" "$detail"
    # Show up to 20 to avoid overwhelming output
    shown=0
    for hit in "${BARE_CD_HITS[@]}"; do
        printf "         - %s\n" "$hit"
        shown=$(( shown + 1 ))
        if [[ $shown -ge 20 ]]; then
            remaining=$(( ${#BARE_CD_HITS[@]} - shown ))
            if [[ $remaining -gt 0 ]]; then
                printf "         ... and %d more\n" "$remaining"
            fi
            break
        fi
    done
fi

# =============================================================================
# CHECK 5: Double-load prevention guards (_LOADED pattern)
# =============================================================================

separator "CHECK 5: Double-load prevention guards (_LOADED pattern)"

# Library/core files that are sourced should have a _LOADED guard.
# CLI cmd_*.sh files, test files, setup scripts, cron, and tools
# may not need guards (they are executed, not sourced). We check
# core/, lib/, helpers/, and exporters/ directories.

GUARD_DIRS=("core" "lib" "helpers" "exporters")
GUARD_MISSING=()

for dir in "${GUARD_DIRS[@]}"; do
    dir_path="${TARGET_DIR}/${dir}"
    [[ ! -d "$dir_path" ]] && continue

    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        rel="${f#"${REPO_ROOT}/"}"
        # Look for a _LOADED variable pattern (various naming conventions)
        if ! grep -qE '_LOADED' "$f"; then
            GUARD_MISSING+=("$rel")
        fi
    done < <(find "$dir_path" -name '*.sh' -type f | sort)
done

if [[ ${#GUARD_MISSING[@]} -eq 0 ]]; then
    check "All sourceable libraries have _LOADED guards" "pass"
else
    detail="${#GUARD_MISSING[@]} file(s) missing _LOADED guard"
    check "All sourceable libraries have _LOADED guards" "fail" "$detail"
    for missing in "${GUARD_MISSING[@]}"; do
        printf "         - %s\n" "$missing"
    done
fi

# =============================================================================
# CHECK 6: Config load order (main.conf before main.conf.local)
# =============================================================================

separator "CHECK 6: Config load order — main.conf before main.conf.local"

# In files that source both main.conf and main.conf.local, ensure
# main.conf appears BEFORE main.conf.local (line number comparison).

CONFIG_ORDER_VIOLATIONS=()
for f in "${ALL_SH_FILES[@]}"; do
    rel="${f#"${REPO_ROOT}/"}"

    # Find lines that source main.conf (but NOT main.conf.local)
    main_lines=$(grep -n 'main\.conf' "$f" | grep -v 'main\.conf\.local' | grep -v '^\s*#' || true)
    # Find lines that source main.conf.local
    local_lines=$(grep -n 'main\.conf\.local' "$f" | grep -v '^\s*#' || true)

    # Skip files that don't reference both
    [[ -z "$main_lines" ]] && continue
    [[ -z "$local_lines" ]] && continue

    # For each main.conf.local occurrence, verify a main.conf line appears
    # before it (lower line number). We compare the first main.conf line
    # with the first main.conf.local line.
    first_main_lineno=$(echo "$main_lines" | head -1 | cut -d: -f1)
    first_local_lineno=$(echo "$local_lines" | head -1 | cut -d: -f1)

    if [[ "$first_local_lineno" -lt "$first_main_lineno" ]]; then
        CONFIG_ORDER_VIOLATIONS+=("${rel}: main.conf.local (line ${first_local_lineno}) loaded before main.conf (line ${first_main_lineno})")
    fi
done

if [[ ${#CONFIG_ORDER_VIOLATIONS[@]} -eq 0 ]]; then
    check "Config load order: main.conf before main.conf.local" "pass"
else
    detail="${#CONFIG_ORDER_VIOLATIONS[@]} file(s) with wrong config load order"
    check "Config load order: main.conf before main.conf.local" "fail" "$detail"
    for violation in "${CONFIG_ORDER_VIOLATIONS[@]}"; do
        printf "         - %s\n" "$violation"
    done
fi

# =============================================================================
# CHECK 7: All meta tags properly quoted (meta:key="value")
# =============================================================================

separator "CHECK 7: Meta tags properly quoted — meta:key=\"value\""

# The pre-commit hook requires that meta: lines have the form
# meta:key="value". We check that every meta: tag with an = sign
# has its value wrapped in double quotes.
#
# Valid:   meta:name="foo"  meta:version="1.0.0"
# Invalid: meta:name=foo    meta:version=1.0.0
# Also valid: meta:inventory.files="" (empty value)

META_UNQUOTED=()
for f in "${ALL_SH_FILES[@]}"; do
    rel="${f#"${REPO_ROOT}/"}"

    # Find lines containing meta: tags with assignments (inside comments)
    meta_lines=$(grep -nE '#.*meta:[a-zA-Z_.]+=' "$f" || true)
    [[ -z "$meta_lines" ]] && continue

    while IFS= read -r mline; do
        [[ -z "$mline" ]] && continue
        lineno="${mline%%:*}"
        content="${mline#*:}"

        # Use awk to extract meta:key=value tokens properly, handling
        # multi-word quoted values like meta:owner="Antonios Voulvoulis"
        # Strategy: find each meta:key= and check if the value starts
        # with a double quote and eventually has a closing double quote.
        #
        # We use a regex-based approach: split by 'meta:' to isolate tokens,
        # then check each token that has key=value form.
        remaining="$content"
        while [[ "$remaining" == *"meta:"* ]]; do
            # Skip to the next meta: token
            remaining="${remaining#*meta:}"
            # Extract the key (up to =)
            if [[ "$remaining" != *"="* ]]; then
                break
            fi
            key="${remaining%%=*}"
            # Validate key is alphanumeric/dots/underscores
            if ! [[ "$key" =~ ^[a-zA-Z_.]+$ ]]; then
                continue
            fi
            after_eq="${remaining#*=}"
            # Check if value starts with double quote
            if [[ "$after_eq" == \"* ]]; then
                # Value is quoted — check it eventually closes
                after_open="${after_eq#\"}"
                if [[ "$after_open" == *\"* ]]; then
                    # Properly quoted: meta:key="..."
                    continue
                else
                    # Opening quote without closing quote on this line
                    META_UNQUOTED+=("${rel}:${lineno}: meta:${key}= (unclosed quote)")
                fi
            else
                # Value does NOT start with double quote — unquoted
                # Extract the unquoted value (up to next space or end)
                unquoted_val="${after_eq%% *}"
                META_UNQUOTED+=("${rel}:${lineno}: meta:${key}=${unquoted_val}")
            fi
        done
    done <<< "$meta_lines"
done

if [[ ${#META_UNQUOTED[@]} -eq 0 ]]; then
    check "All meta tags are properly quoted" "pass"
else
    detail="${#META_UNQUOTED[@]} unquoted meta tag(s) found"
    check "All meta tags are properly quoted" "fail" "$detail"
    for hit in "${META_UNQUOTED[@]}"; do
        printf "         - %s\n" "$hit"
    done
fi

# =============================================================================
# CHECK 8: 7 inventory lines per file
# =============================================================================

separator "CHECK 8: 7 inventory meta lines per file"

# Every .sh file must have exactly 7 meta:inventory.* lines:
#   meta:inventory.files
#   meta:inventory.binaries
#   meta:inventory.env_vars
#   meta:inventory.config_files
#   meta:inventory.systemd_units
#   meta:inventory.network
#   meta:inventory.privileges

REQUIRED_INVENTORY=(
    "meta:inventory.files"
    "meta:inventory.binaries"
    "meta:inventory.env_vars"
    "meta:inventory.config_files"
    "meta:inventory.systemd_units"
    "meta:inventory.network"
    "meta:inventory.privileges"
)

INVENTORY_FAILURES=()
for f in "${ALL_SH_FILES[@]}"; do
    rel="${f#"${REPO_ROOT}/"}"
    missing_keys=()

    for key in "${REQUIRED_INVENTORY[@]}"; do
        if ! grep -q "${key}=" "$f"; then
            missing_keys+=("$key")
        fi
    done

    if [[ ${#missing_keys[@]} -gt 0 ]]; then
        # Count how many inventory lines the file actually has
        actual_count=$(grep -c 'meta:inventory\.' "$f" || true)
        INVENTORY_FAILURES+=("${rel}: has ${actual_count}/7 inventory lines, missing: ${missing_keys[*]}")
    fi
done

if [[ ${#INVENTORY_FAILURES[@]} -eq 0 ]]; then
    check "All ${TOTAL_FILES} files have 7 inventory meta lines" "pass"
else
    detail="${#INVENTORY_FAILURES[@]} file(s) missing inventory lines"
    check "All files have 7 inventory meta lines" "fail" "$detail"
    # Show up to 30 to keep output manageable
    shown=0
    for failure in "${INVENTORY_FAILURES[@]}"; do
        printf "         - %s\n" "$failure"
        shown=$(( shown + 1 ))
        if [[ $shown -ge 30 ]]; then
            remaining=$(( ${#INVENTORY_FAILURES[@]} - shown ))
            if [[ $remaining -gt 0 ]]; then
                printf "         ... and %d more\n" "$remaining"
            fi
            break
        fi
    done
fi

# =============================================================================
# SUMMARY
# =============================================================================

separator "SUMMARY"

TOTAL_CHECKS=$(( PASS_COUNT + FAIL_COUNT + SKIP_COUNT ))

printf "Total checks:  %d\n" "$TOTAL_CHECKS"
printf "Passed:        %d\n" "$PASS_COUNT"
printf "Failed:        %d\n" "$FAIL_COUNT"
printf "Skipped:       %d\n" "$SKIP_COUNT"
printf "Files scanned: %d\n" "$TOTAL_FILES"
echo ""

if [[ $FAIL_COUNT -gt 0 ]]; then
    echo "--- FAILURE DETAILS ---"
    for detail in "${FAILURE_DETAILS[@]}"; do
        printf "  * %s\n" "$detail"
    done
    echo ""
    echo "RESULT: FAIL (${FAIL_COUNT} check(s) failed)"
    exit 1
else
    echo "RESULT: PASS (all checks passed)"
    exit 0
fi
