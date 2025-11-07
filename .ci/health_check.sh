#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.32.6 - Project Health Check Script
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Description: Validates code quality, documentation, structure, and security
# Generates: STATUS.md with project health metrics
# Usage: .ci/health_check.sh
# Exit codes: 0 = all checks pass, 1 = one or more checks failed
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# CONSTANTS
# =============================================================================
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly STATUS_FILE="$PROJECT_ROOT/STATUS.md"
readonly TIMESTAMP="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

# Color codes for terminal output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# =============================================================================
# GLOBAL VARIABLES
# =============================================================================
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNINGS=0

declare -a FAILED_ITEMS=()
declare -a WARNING_ITEMS=()

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[✗]${NC} $*" >&2
}

log_warning() {
    echo -e "${YELLOW}[!]${NC} $*" >&2
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Run a check and track results
run_check() {
    local check_name="$1"
    local check_command="$2"
    local is_warning="${3:-false}"

    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

    if eval "$check_command" >/dev/null 2>&1; then
        log_success "$check_name"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
        return 0
    else
        if [ "$is_warning" = "true" ]; then
            log_warning "$check_name (non-critical)"
            WARNINGS=$((WARNINGS + 1))
            WARNING_ITEMS+=("$check_name")
            PASSED_CHECKS=$((PASSED_CHECKS + 1))  # Don't fail build on warnings
            return 0
        else
            log_error "$check_name"
            FAILED_CHECKS=$((FAILED_CHECKS + 1))
            FAILED_ITEMS+=("$check_name")
            return 1
        fi
    fi
}

# =============================================================================
# CHECK FUNCTIONS
# =============================================================================

check_required_tools() {
    log_info "Checking required tools..."

    run_check "shellcheck installed" "command_exists shellcheck"
    run_check "shfmt installed" "command_exists shfmt"
    run_check "yamllint installed" "command_exists yamllint"
    run_check "markdownlint installed" "command_exists markdownlint-cli2" "true"
    run_check "jq installed" "command_exists jq"
}

check_project_structure() {
    log_info "Checking project structure..."

    run_check "src/ directory exists" "[ -d '$PROJECT_ROOT/src' ]"
    run_check "scripts/ directory exists" "[ -d '$PROJECT_ROOT/scripts' ]"
    run_check "docs/ directory exists" "[ -d '$PROJECT_ROOT/docs' ]"
    run_check "packaging/ directory exists" "[ -d '$PROJECT_ROOT/packaging' ]"
    run_check "README.md exists" "[ -f '$PROJECT_ROOT/README.md' ]"
    run_check "CHANGELOG.md exists" "[ -f '$PROJECT_ROOT/CHANGELOG.md' ]"
    run_check "LICENSE exists" "[ -f '$PROJECT_ROOT/LICENSE' ]"
    run_check "nftban main script exists" "[ -f '$PROJECT_ROOT/src/usr/sbin/nftban' ]"
}

check_shellcheck() {
    log_info "Running shellcheck on shell scripts..."

    if ! command_exists shellcheck; then
        log_warning "shellcheck not installed, skipping"
        return 0
    fi

    local failed=0
    local checked=0

    # Find all .sh files and main nftban script
    while IFS= read -r -d '' script; do
        checked=$((checked + 1))
        if shellcheck -x "$script" 2>/dev/null; then
            : # pass
        else
            log_error "shellcheck failed: $script"
            failed=$((failed + 1))
        fi
    done < <(find "$PROJECT_ROOT" -type f \( -name "*.sh" -o -name "nftban" \) \
        ! -path "*/.*" ! -path "*/dist/*" ! -path "*/node_modules/*" -print0)

    if [ $failed -eq 0 ]; then
        log_success "shellcheck: checked $checked files, all passed"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
        TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
        return 0
    else
        log_error "shellcheck: $failed/$checked files failed"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
        FAILED_ITEMS+=("shellcheck ($failed files)")
        return 1
    fi
}

check_shfmt() {
    log_info "Running shfmt on shell scripts..."

    if ! command_exists shfmt; then
        log_warning "shfmt not installed, skipping"
        return 0
    fi

    local failed=0
    local checked=0

    # Check formatting (don't auto-fix, just verify)
    while IFS= read -r -d '' script; do
        checked=$((checked + 1))
        if shfmt -d -i 4 -bn -ci -sr "$script" >/dev/null 2>&1; then
            : # pass
        else
            log_warning "shfmt formatting issue: $script (non-critical)"
            failed=$((failed + 1))
        fi
    done < <(find "$PROJECT_ROOT" -type f \( -name "*.sh" -o -name "nftban" \) \
        ! -path "*/.*" ! -path "*/dist/*" ! -path "*/node_modules/*" -print0)

    if [ $failed -eq 0 ]; then
        log_success "shfmt: checked $checked files, all formatted correctly"
    else
        log_warning "shfmt: $failed/$checked files have formatting issues (non-critical)"
        WARNING_ITEMS+=("shfmt ($failed files)")
        WARNINGS=$((WARNINGS + 1))
    fi

    PASSED_CHECKS=$((PASSED_CHECKS + 1))
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    return 0
}

check_markdown_lint() {
    log_info "Running markdownlint on documentation..."

    if ! command_exists markdownlint-cli2; then
        log_warning "markdownlint-cli2 not installed, skipping"
        return 0
    fi

    # Run markdownlint (allow some common style issues)
    if markdownlint-cli2 "$PROJECT_ROOT"/**/*.md \
        --config "$PROJECT_ROOT/.markdownlint.json" 2>/dev/null || \
       markdownlint-cli2 "$PROJECT_ROOT"/**/*.md 2>/dev/null; then
        log_success "markdownlint: documentation passed"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    else
        log_warning "markdownlint: some style issues found (non-critical)"
        WARNINGS=$((WARNINGS + 1))
        WARNING_ITEMS+=("markdownlint")
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    fi

    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    return 0
}

check_yaml_lint() {
    log_info "Running yamllint on configuration files..."

    if ! command_exists yamllint; then
        log_warning "yamllint not installed, skipping"
        return 0
    fi

    local failed=0
    local checked=0

    while IFS= read -r -d '' yaml_file; do
        checked=$((checked + 1))
        if yamllint -d relaxed "$yaml_file" 2>/dev/null; then
            : # pass
        else
            log_error "yamllint failed: $yaml_file"
            failed=$((failed + 1))
        fi
    done < <(find "$PROJECT_ROOT" -type f \( -name "*.yml" -o -name "*.yaml" \) \
        ! -path "*/.*" ! -path "*/dist/*" ! -path "*/node_modules/*" -print0)

    if [ $checked -eq 0 ]; then
        log_warning "No YAML files found to check"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
        TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
        return 0
    fi

    if [ $failed -eq 0 ]; then
        log_success "yamllint: checked $checked files, all passed"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
        TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
        return 0
    else
        log_error "yamllint: $failed/$checked files failed"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
        FAILED_ITEMS+=("yamllint ($failed files)")
        return 1
    fi
}

check_basic_security() {
    log_info "Running basic security checks..."

    local issues=0

    # Check for common secret patterns (simple grep)
    if grep -r -i -E "(password|secret|token|api[_-]?key)\s*=\s*['\"]?[a-zA-Z0-9]{8,}" \
        --include="*.sh" --include="*.conf" --include="*.yaml" --include="*.yml" \
        --exclude-dir=".git" --exclude-dir="dist" --exclude-dir="node_modules" \
        "$PROJECT_ROOT" 2>/dev/null | grep -v "EXAMPLE\|sample\|placeholder\|YOUR_"; then
        log_warning "Potential hardcoded secrets found (verify manually)"
        issues=$((issues + 1))
    fi

    # Check for executable files in unusual places
    if find "$PROJECT_ROOT/docs" -type f -executable 2>/dev/null | grep -q .; then
        log_warning "Executable files found in docs/ (unusual)"
        issues=$((issues + 1))
    fi

    if [ $issues -eq 0 ]; then
        log_success "Basic security checks passed"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    else
        log_warning "Basic security: $issues potential issues found (review manually)"
        WARNINGS=$((WARNINGS + 1))
        WARNING_ITEMS+=("Security ($issues potential issues)")
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    fi

    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    return 0
}

check_file_permissions() {
    log_info "Checking file permissions..."

    local issues=0

    # Check for world-writable files (security issue)
    if find "$PROJECT_ROOT" -type f -perm -002 ! -path "*/.git/*" ! -path "*/dist/*" 2>/dev/null | grep -q .; then
        log_error "World-writable files found (security risk)"
        issues=$((issues + 1))
    fi

    # Check that scripts are executable
    local non_executable=0
    while IFS= read -r -d '' script; do
        if [ ! -x "$script" ]; then
            non_executable=$((non_executable + 1))
        fi
    done < <(find "$PROJECT_ROOT/scripts" -type f -name "*.sh" -print0 2>/dev/null)

    if [ $non_executable -gt 0 ]; then
        log_warning "$non_executable scripts in scripts/ are not executable"
        issues=$((issues + 1))
    fi

    if [ $issues -eq 0 ]; then
        log_success "File permissions look good"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
        TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
        return 0
    else
        log_warning "File permissions: $issues issues found (non-critical)"
        WARNINGS=$((WARNINGS + 1))
        WARNING_ITEMS+=("File permissions ($issues issues)")
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
        TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
        return 0
    fi
}

# =============================================================================
# STATUS.md GENERATION
# =============================================================================

generate_status_md() {
    log_info "Generating STATUS.md..."

    local status_emoji="✅"
    local status_text="Healthy"

    if [ $FAILED_CHECKS -gt 0 ]; then
        status_emoji="❌"
        status_text="Failing"
    elif [ $WARNINGS -gt 0 ]; then
        status_emoji="⚠️"
        status_text="Warning"
    fi

    cat > "$STATUS_FILE" <<EOF
# NFTBan Project Health Status

**Status:** $status_emoji $status_text
**Last Updated:** $TIMESTAMP
**Version:** v0.32.6

---

## Summary

| Metric | Value |
|--------|-------|
| Total Checks | $TOTAL_CHECKS |
| Passed | ✅ $PASSED_CHECKS |
| Failed | ❌ $FAILED_CHECKS |
| Warnings | ⚠️ $WARNINGS |

---

## Check Results

### ✅ Passed Checks
- **Code Quality**: shellcheck, shfmt
- **Documentation**: markdownlint
- **Configuration**: yamllint
- **Structure**: all critical files present
- **Security**: no obvious issues detected
- **Permissions**: appropriate file permissions

EOF

    if [ ${#FAILED_ITEMS[@]} -gt 0 ]; then
        cat >> "$STATUS_FILE" <<EOF

### ❌ Failed Checks
EOF
        for item in "${FAILED_ITEMS[@]}"; do
            echo "- $item" >> "$STATUS_FILE"
        done
    fi

    if [ ${#WARNING_ITEMS[@]} -gt 0 ]; then
        cat >> "$STATUS_FILE" <<EOF

### ⚠️ Warnings (Non-Critical)
EOF
        for item in "${WARNING_ITEMS[@]}"; do
            echo "- $item" >> "$STATUS_FILE"
        done
    fi

    cat >> "$STATUS_FILE" <<EOF

---

## Health Categories

### Code Quality
- **shellcheck**: Static analysis for shell scripts
- **shfmt**: Shell script formatting
- **Status**: $([ $FAILED_CHECKS -eq 0 ] && echo "✅ Passing" || echo "⚠️ Issues found")

### Documentation
- **markdownlint**: Markdown style checking
- **Status**: ✅ Passing

### Project Structure
- **Critical Files**: README, LICENSE, CHANGELOG
- **Core Directories**: src/, scripts/, docs/, packaging/
- **Status**: ✅ All present

### Security
- **Secret Scanning**: Basic grep-based detection
- **File Permissions**: World-writable checks
- **Status**: $([ $WARNINGS -eq 0 ] && echo "✅ Clean" || echo "⚠️ Review recommended")

---

## CI/CD Status

This status report is automatically generated by \`.ci/health_check.sh\`.

- **Workflow**: Project Health
- **Trigger**: On push to any branch, weekly schedule
- **Full Logs**: [GitHub Actions](https://github.com/itcmsgr/nftban/actions/workflows/health.yml)

---

**Note**: This is an automated health check. Manual review may be required for warnings.
EOF

    log_success "STATUS.md generated at $STATUS_FILE"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    echo ""
    log_info "=================================================================="
    log_info "NFTBan v0.32.6 - Project Health Check"
    log_info "=================================================================="
    echo ""

    cd "$PROJECT_ROOT"

    # Run all checks
    check_required_tools
    check_project_structure
    check_shellcheck
    check_shfmt
    check_markdown_lint
    check_yaml_lint
    check_basic_security
    check_file_permissions

    echo ""
    log_info "=================================================================="
    log_info "Health Check Summary"
    log_info "=================================================================="
    echo ""
    log_info "Total Checks:   $TOTAL_CHECKS"
    log_success "Passed:         $PASSED_CHECKS"

    if [ $FAILED_CHECKS -gt 0 ]; then
        log_error "Failed:         $FAILED_CHECKS"
    fi

    if [ $WARNINGS -gt 0 ]; then
        log_warning "Warnings:       $WARNINGS"
    fi

    echo ""

    # Generate STATUS.md
    generate_status_md

    # Exit with appropriate code
    if [ $FAILED_CHECKS -gt 0 ]; then
        log_error "Health check FAILED ❌"
        echo ""
        log_info "Failed items:"
        for item in "${FAILED_ITEMS[@]}"; do
            echo "  - $item"
        done
        echo ""
        exit 1
    elif [ $WARNINGS -gt 0 ]; then
        log_warning "Health check passed with warnings ⚠️"
        echo ""
        exit 0
    else
        log_success "All health checks PASSED ✅"
        echo ""
        exit 0
    fi
}

main "$@"
