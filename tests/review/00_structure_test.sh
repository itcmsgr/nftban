#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Project Structure & Conventions Validator
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Static analysis of project structure, meta tags, and conventions
#
# meta:name="00_structure_test"
# meta:type="test"
# meta:header="Structure Test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Validates project structure invariants and code conventions"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,find"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# meta:created_date="2026-02-27"
# =============================================================================
# Usage: ./tests/review/00_structure_test.sh [--verbose]
#
# Run from repo root:
#   bash tests/review/00_structure_test.sh
#
# Exit codes:
#   0 - All checks passed
#   1 - One or more checks failed
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

VERBOSE=0
if [[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]]; then
    VERBOSE=1
fi

# =============================================================================
# COUNTERS & HELPERS
# =============================================================================

PASS=0
FAIL=0
SKIP=0
TOTAL=0

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Colour

# check <description> <command...>
#   Runs a test case. If the command succeeds (exit 0), the test passes.
#   Otherwise it fails. All output is captured.
check() {
    local desc="$1"
    shift
    TOTAL=$((TOTAL + 1))

    local output
    if output=$("$@" 2>&1); then
        PASS=$((PASS + 1))
        printf "${GREEN}  PASS${NC}  %s\n" "$desc"
        if [[ $VERBOSE -eq 1 && -n "$output" ]]; then
            printf "        %s\n" "$output"
        fi
    else
        FAIL=$((FAIL + 1))
        printf "${RED}  FAIL${NC}  %s\n" "$desc"
        if [[ -n "$output" ]]; then
            # Indent each line of failure output
            while IFS= read -r line; do
                printf "${RED}        %s${NC}\n" "$line"
            done <<< "$output"
        fi
    fi
}

# skip <description> <reason>
#   Marks a test as skipped.
skip() {
    local desc="$1"
    local reason="${2:-}"
    TOTAL=$((TOTAL + 1))
    SKIP=$((SKIP + 1))
    printf "${YELLOW}  SKIP${NC}  %s" "$desc"
    if [[ -n "$reason" ]]; then
        printf " (%s)" "$reason"
    fi
    printf "\n"
}

# banner <section-name>
banner() {
    printf "\n${BOLD}${CYAN}=== %s ===${NC}\n\n" "$1"
}

# =============================================================================
# SECTION 1: Core Files
# =============================================================================

banner "Core Files"

check "VERSION file exists" \
    test -f "$REPO_ROOT/VERSION"

check "VERSION contains valid semver (MAJOR.MINOR.PATCH)" \
    bash -c 'grep -qxE "[0-9]+\.[0-9]+\.[0-9]+" "$1/VERSION"' _ "$REPO_ROOT"

check "LICENSE file exists" \
    test -f "$REPO_ROOT/LICENSE"

check "SECURITY.md exists" \
    test -f "$REPO_ROOT/SECURITY.md"

check "go.mod exists" \
    test -f "$REPO_ROOT/go.mod"

# =============================================================================
# SECTION 2: Required Directories
# =============================================================================

banner "Required Directories"

check "cli/lib/nftban/ directory exists" \
    test -d "$REPO_ROOT/cli/lib/nftban"

check "install/systemd/ directory exists" \
    test -d "$REPO_ROOT/install/systemd"

check "packaging/ directory exists" \
    test -d "$REPO_ROOT/packaging"

# =============================================================================
# SECTION 3: Systemd Units
# =============================================================================

banner "Systemd Units"

check "install/systemd/ contains .service files" \
    bash -c 'ls "$1"/install/systemd/*.service >/dev/null 2>&1' _ "$REPO_ROOT"

check "install/systemd/ contains .timer files" \
    bash -c 'ls "$1"/install/systemd/*.timer >/dev/null 2>&1' _ "$REPO_ROOT"

# =============================================================================
# SECTION 4: set -Eeuo pipefail in all shell scripts
# =============================================================================

banner "Strict Mode (set -Eeuo pipefail)"

# Check all .sh files under cli/lib/nftban/ for set -Eeuo pipefail
# Files can set it directly OR source strict.sh which sets it.
# We look for either pattern.
check "All .sh files under cli/lib/nftban/ have strict mode" \
    bash -c '
        repo="$1"
        failures=()
        while IFS= read -r -d "" file; do
            # Check for direct set -Eeuo pipefail OR sourcing strict.sh
            if ! grep -qE "^set -Eeuo pipefail" "$file" && \
               ! grep -q "source.*strict\.sh" "$file" && \
               ! grep -q "\..*strict\.sh" "$file"; then
                failures+=("${file#$repo/}")
            fi
        done < <(find "$repo/cli/lib/nftban" -name "*.sh" -type f -print0)

        if [[ ${#failures[@]} -gt 0 ]]; then
            printf "Missing strict mode in %d file(s):\n" "${#failures[@]}"
            for f in "${failures[@]}"; do
                printf "  - %s\n" "$f"
            done
            exit 1
        fi
        exit 0
    ' _ "$REPO_ROOT"

# =============================================================================
# SECTION 5: Meta Inventory Tags (7 required)
# =============================================================================

banner "Meta Inventory Tags (7 required lines)"

# The 7 required inventory keys:
#   meta:inventory.files
#   meta:inventory.binaries
#   meta:inventory.env_vars
#   meta:inventory.config_files
#   meta:inventory.systemd_units
#   meta:inventory.network
#   meta:inventory.privileges

check "All .sh files under cli/lib/nftban/ have 7 meta:inventory.* lines" \
    bash -c '
        repo="$1"
        required_keys=(
            "meta:inventory.files"
            "meta:inventory.binaries"
            "meta:inventory.env_vars"
            "meta:inventory.config_files"
            "meta:inventory.systemd_units"
            "meta:inventory.network"
            "meta:inventory.privileges"
        )
        failures=()
        while IFS= read -r -d "" file; do
            for key in "${required_keys[@]}"; do
                if ! grep -q "$key" "$file"; then
                    relpath="${file#$repo/}"
                    failures+=("$relpath  missing  $key")
                    break  # report file once
                fi
            done
        done < <(find "$repo/cli/lib/nftban" -name "*.sh" -type f -print0)

        if [[ ${#failures[@]} -gt 0 ]]; then
            printf "Files with missing inventory tags (%d):\n" "${#failures[@]}"
            for f in "${failures[@]}"; do
                printf "  - %s\n" "$f"
            done
            exit 1
        fi
        exit 0
    ' _ "$REPO_ROOT"

# =============================================================================
# SECTION 6: Meta Tag Quoting (meta:key="value")
# =============================================================================

banner "Meta Tag Quoting"

# All meta: tags must be quoted: meta:key="value"
# Violation: meta:key=value (without quotes)
# Acceptable: meta:key="value" or meta:key="" or multi-tag lines
check "All meta: tags in .sh files are properly quoted (meta:key=\"value\")" \
    bash -c '
        repo="$1"
        failures=()
        while IFS= read -r -d "" file; do
            # Find meta: lines that have an = but the value is NOT quoted.
            # Pattern for violation: meta:word=<not-a-double-quote>
            # We look for lines containing meta: with unquoted values.
            # Only check comment lines (starting with optional whitespace + #)
            # to avoid false positives from echo/printf statements
            while IFS= read -r line; do
                # Extract all meta:key=value patterns on the line
                # A violation is meta:key= followed by a non-quote, non-space, non-EOL char
                if echo "$line" | grep -qP "meta:\w+=(?!\"|$)[^\s]"; then
                    relpath="${file#$repo/}"
                    failures+=("$relpath: $line")
                fi
            done < <(grep -n "^[[:space:]]*#.*meta:" "$file" 2>/dev/null || true)
        done < <(find "$repo/cli/lib/nftban" -name "*.sh" -type f -print0)

        if [[ ${#failures[@]} -gt 0 ]]; then
            printf "Unquoted meta tags found (%d):\n" "${#failures[@]}"
            for f in "${failures[@]}"; do
                printf "  - %s\n" "$f"
            done
            exit 1
        fi
        exit 0
    ' _ "$REPO_ROOT"

# =============================================================================
# SECTION 7: No Secrets / Keys Committed
# =============================================================================

banner "Secret / Key Leak Prevention"

check "No .env files committed in repository" \
    bash -c '
        repo="$1"
        found=$(find "$repo" -name ".env" -not -path "*/.git/*" -type f 2>/dev/null)
        if [[ -n "$found" ]]; then
            printf "Committed .env files found:\n%s\n" "$found"
            exit 1
        fi
        exit 0
    ' _ "$REPO_ROOT"

check "No .env.* files committed (e.g., .env.local, .env.production)" \
    bash -c '
        repo="$1"
        found=$(find "$repo" -name ".env.*" -not -path "*/.git/*" -type f 2>/dev/null)
        if [[ -n "$found" ]]; then
            printf "Committed .env.* files found:\n%s\n" "$found"
            exit 1
        fi
        exit 0
    ' _ "$REPO_ROOT"

check "No private key files committed (id_rsa, id_ed25519, *.pem keys)" \
    bash -c '
        repo="$1"
        found=$(find "$repo" -not -path "*/.git/*" -type f \( \
            -name "id_rsa" -o -name "id_ed25519" -o -name "id_ecdsa" -o \
            -name "id_dsa" -o -name "*.key" -o -name "*.key.pem" \
        \) 2>/dev/null)
        if [[ -n "$found" ]]; then
            printf "Private key files found:\n%s\n" "$found"
            exit 1
        fi
        exit 0
    ' _ "$REPO_ROOT"

check "No files contain literal private key headers" \
    bash -c '
        repo="$1"
        self="$2"
        # Search for PEM private key headers in tracked files
        # Exclude this test script itself to avoid self-match
        found=$(grep -rl "BEGIN.*PRIVATE KEY" "$repo" \
            --include="*.sh" --include="*.go" --include="*.conf" \
            --include="*.yml" --include="*.yaml" --include="*.json" \
            --include="*.toml" --include="*.env" --include="*.txt" \
            2>/dev/null | grep -v "/.git/" | grep -v "$self" || true)
        if [[ -n "$found" ]]; then
            printf "Files containing private key material:\n%s\n" "$found"
            exit 1
        fi
        exit 0
    ' _ "$REPO_ROOT" "00_structure_test.sh"

# =============================================================================
# SUMMARY
# =============================================================================

printf "\n${BOLD}${CYAN}==========================================${NC}\n"
printf "${BOLD}  STRUCTURE TEST SUMMARY${NC}\n"
printf "${BOLD}${CYAN}==========================================${NC}\n\n"
printf "  Total : %d\n" "$TOTAL"
printf "  ${GREEN}Pass${NC}  : %d\n" "$PASS"
printf "  ${RED}Fail${NC}  : %d\n" "$FAIL"
if [[ $SKIP -gt 0 ]]; then
    printf "  ${YELLOW}Skip${NC}  : %d\n" "$SKIP"
fi
printf "\n"

if [[ $FAIL -gt 0 ]]; then
    printf "${RED}${BOLD}  RESULT: FAILED${NC} (%d check(s) failed)\n\n" "$FAIL"
    exit 1
else
    printf "${GREEN}${BOLD}  RESULT: PASSED${NC} (all %d checks passed)\n\n" "$PASS"
    exit 0
fi
