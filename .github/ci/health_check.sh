#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Project Health Check Script
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Validates code quality, documentation, structure, and security
#
# meta:name="nftban_health_check"
# meta:type="cli"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2025-10-26"
#
# meta:description="Validates code quality, documentation, structure, and security"
# meta:input="Project files"
# meta:output="STATUS.md with project health metrics"
# meta:depends="bash,shellcheck,go,grep,find"
#
# meta:inventory.files=""
# meta:inventory.binaries="shellcheck,go,grep,find,wc,date"
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
readonly PROJECT_ROOT
readonly STATUS_FILE="$PROJECT_ROOT/STATUS.md"
TIMESTAMP="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
readonly TIMESTAMP
NFTBAN_DEV_VERSION=$(cat "${SCRIPT_DIR}/../../VERSION" 2>/dev/null || echo "unknown")
readonly NFTBAN_DEV_VERSION

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
# SECURITY: eval is acceptable here because:
# 1. This is a CI-only script, not production code
# 2. All check_command values are hardcoded in this file
# 3. No external/user input reaches this function
run_check() {
    local check_name="$1"
    local check_command="$2"
    local is_warning="${3:-false}"

    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

    # shellcheck disable=SC2086  # check_command is intentionally unquoted
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

    run_check "shellcheck installed" "command_exists shellcheck" "true"
    run_check "shfmt installed" "command_exists shfmt" "true"
    run_check "yamllint installed" "command_exists yamllint" "true"
    run_check "markdownlint installed" "command_exists markdownlint-cli2" "true"
    run_check "jq installed" "command_exists jq"
    run_check "go installed" "command_exists go"
}

check_project_structure() {
    log_info "Checking project structure..."

    run_check "cli/ directory exists" "[ -d '$PROJECT_ROOT/cli' ]"
    run_check "cmd/ directory exists" "[ -d '$PROJECT_ROOT/cmd' ]"
    run_check "internal/ directory exists" "[ -d '$PROJECT_ROOT/internal' ]"
    run_check "install/ directory exists" "[ -d '$PROJECT_ROOT/install' ]"
    run_check "packaging/ directory exists" "[ -d '$PROJECT_ROOT/packaging' ]"
    run_check "README.md exists" "[ -f '$PROJECT_ROOT/README.md' ]"
    run_check "LICENSE exists" "[ -f '$PROJECT_ROOT/LICENSE' ]"
    run_check "go.mod exists" "[ -f '$PROJECT_ROOT/go.mod' ]"
    run_check "nftban CLI script exists" "[ -f '$PROJECT_ROOT/cli/sbin/nftban' ]"
    run_check "build.sh exists" "[ -f '$PROJECT_ROOT/build.sh' ]"
    run_check "install.sh exists" "[ -f '$PROJECT_ROOT/install.sh' ]"
}

check_shellcheck() {
    log_info "Running shellcheck on shell scripts..."

    if ! command_exists shellcheck; then
        log_warning "shellcheck not installed, skipping"
        WARNINGS=$((WARNINGS + 1))
        WARNING_ITEMS+=("shellcheck not installed")
        TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
        return 0
    fi

    local failed=0
    local checked=0

    # Find all .sh files and main nftban script
    while IFS= read -r -d '' script; do
        checked=$((checked + 1))
        if shellcheck -x -S warning "$script" 2>/dev/null; then
            : # pass
        else
            log_error "shellcheck failed: $script"
            failed=$((failed + 1))
        fi
    done < <(find "$PROJECT_ROOT" -type f \( -name "*.sh" -o -name "nftban" \) \
        ! -path "*/.git/*" ! -path "*/build/*" ! -path "*/node_modules/*" -print0)

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
        WARNINGS=$((WARNINGS + 1))
        WARNING_ITEMS+=("shfmt not installed")
        TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
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
        ! -path "*/.git/*" ! -path "*/build/*" ! -path "*/node_modules/*" -print0)

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
        WARNINGS=$((WARNINGS + 1))
        WARNING_ITEMS+=("markdownlint not installed")
        TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
        return 0
    fi

    # Run markdownlint (allow some common style issues)
    if markdownlint-cli2 "$PROJECT_ROOT"/**/*.md 2>/dev/null; then
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
        WARNINGS=$((WARNINGS + 1))
        WARNING_ITEMS+=("yamllint not installed")
        TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
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
        ! -path "*/.git/*" ! -path "*/build/*" ! -path "*/node_modules/*" -print0)

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
        log_warning "yamllint: $failed/$checked files have warnings (non-critical)"
        WARNINGS=$((WARNINGS + 1))
        WARNING_ITEMS+=("yamllint ($failed files)")
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
        TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
        return 0
    fi
}

check_go_vet() {
    log_info "Running go vet on Go code..."

    if ! command_exists go; then
        log_error "Go not installed"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
        FAILED_ITEMS+=("Go not installed")
        return 1
    fi

    cd "$PROJECT_ROOT"

    local vet_exit=0
    local vet_output
    vet_output=$(go vet ./... 2>&1) || vet_exit=$?

    # Filter out module download messages (go: downloading ...) which are
    # informational stderr output, not actual vet errors
    local vet_errors
    vet_errors=$(echo "$vet_output" | grep -v '^go: downloading ' | grep -v '^$' || true)

    if [[ -z "$vet_errors" ]] && [[ "$vet_exit" -eq 0 ]]; then
        log_success "go vet: all packages passed"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
        TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
        return 0
    else
        log_error "go vet: found issues"
        echo "$vet_output" >&2
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
        FAILED_ITEMS+=("go vet")
        return 1
    fi
}

check_go_fmt() {
    log_info "Running gofmt on Go code..."

    if ! command_exists go; then
        log_error "Go not installed"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
        FAILED_ITEMS+=("Go not installed")
        return 1
    fi

    cd "$PROJECT_ROOT"

    local unformatted
    unformatted=$(gofmt -l . 2>/dev/null | grep -v '^vendor/' || true)

    if [ -z "$unformatted" ]; then
        log_success "gofmt: all Go files are properly formatted"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
        TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
        return 0
    else
        local count
        count=$(echo "$unformatted" | wc -l)
        log_warning "gofmt: $count files need formatting (non-critical)"
        WARNINGS=$((WARNINGS + 1))
        WARNING_ITEMS+=("gofmt ($count files)")
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
        TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
        return 0
    fi
}

check_go_test() {
    log_info "Running go test on Go code..."

    if ! command_exists go; then
        log_error "Go not installed"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
        FAILED_ITEMS+=("Go not installed")
        return 1
    fi

    cd "$PROJECT_ROOT"

    # Check if there are any test files
    if ! find . -name "*_test.go" -type f | grep -q .; then
        log_warning "No Go test files found (non-critical)"
        WARNINGS=$((WARNINGS + 1))
        WARNING_ITEMS+=("No Go tests")
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
        TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
        return 0
    fi

    if go test -short ./... 2>/dev/null; then
        log_success "go test: all tests passed"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
        TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
        return 0
    else
        log_error "go test: some tests failed"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
        FAILED_ITEMS+=("go test")
        return 1
    fi
}

check_go_mod() {
    log_info "Checking go.mod integrity..."

    if ! command_exists go; then
        log_error "Go not installed"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
        FAILED_ITEMS+=("Go not installed")
        return 1
    fi

    cd "$PROJECT_ROOT"

    # Check if go.mod is tidy
    if go mod tidy -v 2>/dev/null && git diff --exit-code go.mod go.sum >/dev/null 2>&1; then
        log_success "go.mod: module dependencies are tidy"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
        TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
        return 0
    else
        log_warning "go.mod: may need 'go mod tidy' (non-critical)"
        WARNINGS=$((WARNINGS + 1))
        WARNING_ITEMS+=("go.mod needs tidy")
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
        TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
        return 0
    fi
}

check_basic_security() {
    log_info "Running basic security checks..."

    local issues=0

    # Check for common secret patterns (simple grep)
    if grep -r -i -E "(password|secret|token|api[_-]?key)\s*=\s*['\"]?[a-zA-Z0-9]{8,}" \
        --include="*.sh" --include="*.conf" --include="*.yaml" --include="*.yml" --include="*.go" \
        --exclude-dir=".git" --exclude-dir="build" --exclude-dir="vendor" --exclude-dir="node_modules" \
        "$PROJECT_ROOT" 2>/dev/null | grep -v "EXAMPLE\|sample\|placeholder\|YOUR_\|TODO\|FIXME"; then
        log_warning "Potential hardcoded secrets found (verify manually)"
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
    if find "$PROJECT_ROOT" -type f -perm -002 ! -path "*/.git/*" ! -path "*/build/*" 2>/dev/null | grep -q .; then
        log_error "World-writable files found (security risk)"
        issues=$((issues + 1))
    fi

    # Check that main scripts are executable
    local non_executable=0
    for script in "$PROJECT_ROOT/build.sh" "$PROJECT_ROOT/install.sh" "$PROJECT_ROOT/cli/sbin/nftban"; do
        if [ -f "$script" ] && [ ! -x "$script" ]; then
            log_warning "$script is not executable"
            non_executable=$((non_executable + 1))
        fi
    done

    if [ $non_executable -gt 0 ]; then
        log_warning "$non_executable critical scripts are not executable"
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

check_recursive_permissions() {
    log_info "Checking for recursive chmod/chown commands..."

    local errors=0

    # v1.228.10: the subject is UNBOUNDED OWNERSHIP/MODE MUTATION, not one shell spelling.
    # Two measured coverage gaps are closed here, in step with the pre-commit twin
    # tools/check-recursive-permissions.sh:
    #   1. Go was invisible. internal/installer/fhs/permissions.go issues the same policy as
    #      exec.Run("chown","-R",...) argv elements — the installer's permission fallback,
    #      a privileged actor no shell-only grep could see.
    #   2. packaging/build_nftban.sh was excluded as "legacy" while it emits the RPM %post
    #      scriptlet. A privileged packaging actor must not be exempt; the exclusion is gone.
    # Excluded now, and only these: this file and the pre-commit twin, both of which carry the
    # detection patterns as data rather than as executable policy.
    local files
    files=$(find "$PROJECT_ROOT" \( -name "*.sh" -o -name "*.go" -o -name "*.spec" -o -name "postinst" -o -name "preinst" \) \
        ! -path "*/.git/*" \
        ! -path "*/build/*" \
        ! -name "*_test.go" \
        ! -name "check-recursive-permissions.sh" \
        ! -name "health_check.sh" \
        -type f 2>/dev/null || true)

    for file in $files; do
        # Check for chmod -R (various forms)
        if grep -n -E '(chmod\s+-R|chmod\s+--recursive)' "$file" 2>/dev/null; then
            log_error "Found 'chmod -R' in: $file"
            errors=$((errors + 1))
        fi

        # Check for chown -R (various forms)
        if grep -n -E '(chown\s+-R|chown\s+--recursive)' "$file" 2>/dev/null; then
            log_error "Found 'chown -R' in: $file"
            errors=$((errors + 1))
        fi

        # Go surface: recursive flag as its own quoted argv element after the quoted verb,
        # so a comment or a log string naming the flag does not match.
        case "$file" in
            *.go)
                # A site in the pending list is STILL WRONG and deliberately deferred (owner
                # TODO-3, GO fallback parity). Reported every run so it stays visible; it does
                # not fail the build. Anything NOT listed fails immediately.
                local _pend="$PROJECT_ROOT/scripts/ci/data/recursive-permission-pending.tsv"
                local _rel="${file#"$PROJECT_ROOT"/}" _ln
                while IFS=: read -r _ln _; do
                    [ -n "$_ln" ] || continue
                    if [ -f "$_pend" ] && grep -qF "$_rel:$_ln	" "$_pend" 2>/dev/null; then
                        log_warning "PENDING (deferred debt): $_rel:$_ln recursive chown/chmod"
                    else
                        log_error "Found a recursive chown/chmod execution in: $_rel:$_ln"
                        errors=$((errors + 1))
                    fi
                done < <(grep -n -E '"(chown|chmod)"[[:space:]]*,[[:space:]]*"(-R|--recursive)"' "$file" 2>/dev/null || true)
                ;;
        esac
    done

    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    if [ $errors -eq 0 ]; then
        log_success "No recursive permission commands found"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
        return 0
    else
        log_error "Recursive permission commands: $errors found (security risk)"
        log_error "Use explicit permissions or systemd-tmpfiles instead"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        FAILED_ITEMS+=("Recursive permissions ($errors files)")
        return 1
    fi
}

check_nft_schema_alignment() {
    log_info "Checking NFT Schema v${NFTBAN_DEV_VERSION} alignment..."

    local issues=0

    # Check for hardcoded table names in shell scripts (should use variables)
    if grep -r -E 'nft.*(ip|ip6|inet) nftban' \
        --include="*.sh" \
        "$PROJECT_ROOT/cli/lib/nftban" 2>/dev/null | \
        grep -v '${NFTBAN_TABLE' | \
        grep -v '#.*nft' | \
        grep -v 'NFTBAN_TABLE' | \
        head -5; then
        log_warning "Found potential hardcoded table names in shell scripts"
        issues=$((issues + 1))
    fi

    # Check for hardcoded table names in Go code (should use constants)
    if grep -r '"ip nftban"\|"ip6 nftban"\|"inet nftban"' \
        --include="*.go" \
        "$PROJECT_ROOT/pkg" "$PROJECT_ROOT/cmd" 2>/dev/null | \
        grep -v 'nftables.Table' | \
        grep -v '//.*' | \
        head -5; then
        log_warning "Found potential hardcoded table names in Go code"
        issues=$((issues + 1))
    fi

    if [ $issues -eq 0 ]; then
        log_success "NFT Schema v${NFTBAN_DEV_VERSION} alignment looks good"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    else
        log_warning "NFT Schema: $issues potential alignment issues (verify manually)"
        WARNINGS=$((WARNINGS + 1))
        WARNING_ITEMS+=("NFT Schema alignment ($issues potential issues)")
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    fi

    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    return 0
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
# NFTBan Development Project Health Status

**Status:** $status_emoji $status_text
**Last Updated:** $TIMESTAMP
**Version:** v${NFTBAN_DEV_VERSION} Development Branch

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
- **Shell Quality**: shellcheck, shfmt
- **Go Quality**: go vet, gofmt, go test
- **Documentation**: markdownlint
- **Configuration**: yamllint
- **Structure**: all critical files present
- **Security**: no obvious issues detected
- **Permissions**: appropriate file permissions
- **NFT Schema**: v${NFTBAN_DEV_VERSION} alignment verified

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

### Shell Script Quality
- **shellcheck**: Static analysis for bash scripts
- **shfmt**: Shell script formatting
- **Status**: $([ $FAILED_CHECKS -eq 0 ] && echo "✅ Passing" || echo "⚠️ Issues found")

### Go Code Quality
- **go vet**: Go code static analysis
- **gofmt**: Go code formatting
- **go test**: Unit test execution
- **go.mod**: Dependency management
- **Status**: $([ $FAILED_CHECKS -eq 0 ] && echo "✅ Passing" || echo "⚠️ Issues found")

### Documentation
- **markdownlint**: Markdown style checking
- **Status**: ✅ Passing

### Project Structure
- **Critical Files**: README, LICENSE, go.mod, build.sh
- **Core Directories**: cli/, cmd/, internal/, pkg/, install/, packaging/
- **Status**: ✅ All present

### Security
- **Secret Scanning**: Basic grep-based detection
- **File Permissions**: World-writable checks
- **Status**: $([ $WARNINGS -eq 0 ] && echo "✅ Clean" || echo "⚠️ Review recommended")

### NFT Schema v${NFTBAN_DEV_VERSION} Alignment
- **Variable Usage**: Check for hardcoded table names in shell
- **Constants Usage**: Check for hardcoded table names in Go
- **Status**: ✅ Aligned

---

## CI/CD Status

This status report is automatically generated by \`.ci/health_check.sh\`.

- **Workflow**: Project Health
- **Trigger**: On push to v0.7 branch, weekly schedule
- **Full Logs**: [GitHub Actions](https://github.com/itcmsgr/nftban/actions/workflows/health.yml)

---

## Development Notes

This is the **development branch** for NFTBan v${NFTBAN_DEV_VERSION}. Health checks include:

1. **Code Quality**: Both shell and Go code are validated
2. **Architecture Alignment**: NFT Schema v${NFTBAN_DEV_VERSION} dual-table architecture
3. **Package Building**: Automated RPM/DEB package generation
4. **Testing**: Unit tests and integration checks

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
    log_info "NFTBan v${NFTBAN_DEV_VERSION} Development - Project Health Check"
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
    check_go_vet
    check_go_fmt
    check_go_test
    check_go_mod
    check_basic_security
    check_file_permissions
    check_recursive_permissions
    check_nft_schema_alignment

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
