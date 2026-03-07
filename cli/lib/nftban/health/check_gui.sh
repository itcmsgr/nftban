#!/usr/bin/env bash
# =============================================================================
# NFTBan - GUI Registry Validator
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="check_gui"
# meta:type="script"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-01-15"
# meta:description="Validate GOTH GUI components against ui-registry.json"
# meta:input="None"
# meta:output="Validation results"
# meta:depends="jq"
# meta:inventory.files=""
# meta:inventory.binaries="jq"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NFTBAN_ROOT="${SCRIPT_DIR}/../../../../"
REGISTRY="${NFTBAN_ROOT}/internal/ui/ui-registry.json"
HANDLERS_FILE="${NFTBAN_ROOT}/cmd/nftban-ui/handlers/goth.go"
MAIN_FILE="${NFTBAN_ROOT}/cmd/nftban-ui/main.go"

# Counters
ERRORS=0
WARNINGS=0
PASSED=0

# Output format
JSON_OUTPUT="${1:-}"

# v1.19.20 FIX: Added || true to prevent set -e failures when counters start at 0
log_pass() {
    ((PASSED++)) || true
    if [[ "$JSON_OUTPUT" != "--json" ]]; then
        echo -e "${GREEN}[PASS]${NC} $1"
    fi
}

log_warn() {
    ((WARNINGS++)) || true
    if [[ "$JSON_OUTPUT" != "--json" ]]; then
        echo -e "${YELLOW}[WARN]${NC} $1"
    fi
}

log_fail() {
    ((ERRORS++)) || true
    if [[ "$JSON_OUTPUT" != "--json" ]]; then
        echo -e "${RED}[FAIL]${NC} $1"
    fi
}

log_info() {
    if [[ "$JSON_OUTPUT" != "--json" ]]; then
        echo -e "${BLUE}[INFO]${NC} $1"
    fi
}

# =============================================================================
# CHECK: Registry file exists
# =============================================================================
check_registry() {
    if [[ ! -f "$REGISTRY" ]]; then
        log_fail "GUI-000: Registry file not found: $REGISTRY"
        return 1
    fi

    if ! jq empty "$REGISTRY" 2>/dev/null; then
        log_fail "GUI-000: Registry file is not valid JSON"
        return 1
    fi

    log_pass "GUI-000: Registry file valid"
    return 0
}

# =============================================================================
# CHECK: GUI-001 - Templ files exist
# =============================================================================
check_templ_files() {
    log_info "Checking templ files..."

    local packages
    packages=$(jq -r '.packages | keys[]' "$REGISTRY")

    for pkg in $packages; do
        local pkg_path
        pkg_path=$(jq -r ".packages[\"$pkg\"].path" "$REGISTRY")

        local files
        files=$(jq -r ".packages[\"$pkg\"].files | keys[]" "$REGISTRY" 2>/dev/null || echo "")

        for file in $files; do
            local file_type
            file_type=$(jq -r ".packages[\"$pkg\"].files[\"$file\"].type" "$REGISTRY")

            if [[ "$file_type" == "templ" ]]; then
                local full_path="${NFTBAN_ROOT}/${pkg_path}/${file}"
                if [[ -f "$full_path" ]]; then
                    log_pass "GUI-001: $pkg_path/$file exists"
                else
                    log_fail "GUI-001: Missing templ file: $pkg_path/$file"
                fi
            fi
        done
    done
}

# =============================================================================
# CHECK: GUI-002 - Generated files exist
# =============================================================================
check_generated_files() {
    log_info "Checking generated files..."

    local packages
    packages=$(jq -r '.packages | keys[]' "$REGISTRY")

    for pkg in $packages; do
        local pkg_path
        pkg_path=$(jq -r ".packages[\"$pkg\"].path" "$REGISTRY")

        local files
        files=$(jq -r ".packages[\"$pkg\"].files | keys[]" "$REGISTRY" 2>/dev/null || echo "")

        for file in $files; do
            local generates
            generates=$(jq -r ".packages[\"$pkg\"].files[\"$file\"].generates // empty" "$REGISTRY")

            if [[ -n "$generates" ]]; then
                local full_path="${NFTBAN_ROOT}/${pkg_path}/${generates}"
                if [[ -f "$full_path" ]]; then
                    log_pass "GUI-002: $pkg_path/$generates exists"
                else
                    log_fail "GUI-002: Missing generated file: $pkg_path/$generates (run 'templ generate')"
                fi
            fi
        done
    done
}

# =============================================================================
# CHECK: GUI-003 - Routes registered
# =============================================================================
check_routes_registered() {
    log_info "Checking route registration..."

    if [[ ! -f "$MAIN_FILE" ]]; then
        log_fail "GUI-003: main.go not found"
        return
    fi

    # Check page routes
    local page_routes
    page_routes=$(jq -r '.routes.pages[].path' "$REGISTRY")

    for route in $page_routes; do
        if grep -q "\"$route\"" "$MAIN_FILE"; then
            log_pass "GUI-003: Route $route registered"
        else
            log_fail "GUI-003: Route $route not found in main.go"
        fi
    done

    # Check fragment routes
    local frag_routes
    frag_routes=$(jq -r '.routes.fragments[].path' "$REGISTRY")

    for route in $frag_routes; do
        if grep -q "\"$route\"" "$MAIN_FILE"; then
            log_pass "GUI-003: Route $route registered"
        else
            log_fail "GUI-003: Route $route not found in main.go"
        fi
    done

    # Check action routes
    local action_routes
    action_routes=$(jq -r '.routes.actions[].path' "$REGISTRY")

    for route in $action_routes; do
        if grep -q "\"$route\"" "$MAIN_FILE"; then
            log_pass "GUI-003: Route $route registered"
        else
            log_fail "GUI-003: Route $route not found in main.go"
        fi
    done
}

# =============================================================================
# CHECK: GUI-004 - Handlers implemented
# =============================================================================
check_handlers() {
    log_info "Checking handler implementations..."

    if [[ ! -f "$HANDLERS_FILE" ]]; then
        log_fail "GUI-004: Handlers file not found: $HANDLERS_FILE"
        return
    fi

    local methods
    methods=$(jq -r '.handlers.methods[]' "$REGISTRY")

    for method in $methods; do
        if grep -q "func.*$method" "$HANDLERS_FILE"; then
            log_pass "GUI-004: Handler $method implemented"
        else
            log_fail "GUI-004: Handler $method not found in goth.go"
        fi
    done
}

# =============================================================================
# CHECK: GUI-005 - Build prerequisites
# =============================================================================
check_prerequisites() {
    log_info "Checking build prerequisites..."

    # Check templ
    if command -v templ &>/dev/null; then
        local templ_version
        templ_version=$(templ version 2>/dev/null | grep -oP 'v\K[0-9.]+' || echo "unknown")
        log_pass "GUI-005: templ installed (v$templ_version)"
    else
        log_warn "GUI-005: templ not installed (required for development)"
    fi

    # Check go
    if command -v go &>/dev/null; then
        local go_version
        go_version=$(go version | grep -oP 'go\K[0-9.]+' || echo "unknown")
        log_pass "GUI-005: go installed (v$go_version)"
    else
        log_fail "GUI-005: go not installed"
    fi
}

# =============================================================================
# CHECK: GUI-006 - Version consistency
# =============================================================================
check_version() {
    log_info "Checking version consistency..."

    local registry_version
    registry_version=$(jq -r '.version' "$REGISTRY")

    local version_file="${NFTBAN_ROOT}/VERSION"
    if [[ -f "$version_file" ]]; then
        local file_version
        file_version=$(cat "$version_file" | tr -d '[:space:]')

        if [[ "$registry_version" == "$file_version" ]]; then
            log_pass "GUI-006: Registry version matches VERSION file ($registry_version)"
        else
            log_warn "GUI-006: Version mismatch - registry: $registry_version, VERSION: $file_version"
        fi
    fi
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    if [[ "$JSON_OUTPUT" != "--json" ]]; then
        echo "=========================================="
        echo "NFTBan GUI Registry Validator"
        echo "=========================================="
        echo ""
    fi

    # Run all checks
    check_registry || exit 1
    check_templ_files
    check_generated_files
    check_routes_registered
    check_handlers
    check_prerequisites
    check_version

    # Summary
    if [[ "$JSON_OUTPUT" == "--json" ]]; then
        cat <<EOF
{
  "passed": $PASSED,
  "warnings": $WARNINGS,
  "errors": $ERRORS,
  "status": "$( [[ $ERRORS -eq 0 ]] && echo "ok" || echo "failed" )"
}
EOF
    else
        echo ""
        echo "=========================================="
        echo "Summary"
        echo "=========================================="
        echo -e "${GREEN}Passed:${NC}   $PASSED"
        echo -e "${YELLOW}Warnings:${NC} $WARNINGS"
        echo -e "${RED}Errors:${NC}   $ERRORS"
        echo ""

        if [[ $ERRORS -gt 0 ]]; then
            echo -e "${RED}GUI validation FAILED${NC}"
            exit 1
        else
            echo -e "${GREEN}GUI validation PASSED${NC}"
            exit 0
        fi
    fi
}

main "$@"
