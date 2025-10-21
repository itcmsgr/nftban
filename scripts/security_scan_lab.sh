#!/usr/bin/env bash
#
# NFTBan Security Scanner - Lab Environment Only
#
# Purpose: Install and run security scanning tools on lab servers
# WARNING: This script installs packages and runs security scans
#          ONLY run on lab/test servers, NEVER on production
#
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Version: 1.0.0
# Date: 2025-10-21

set -Eeuo pipefail
IFS=$'\n\t'

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Detect OS
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_NAME="$ID"
    OS_VERSION="$VERSION_ID"
else
    echo -e "${RED}ERROR: Cannot detect OS${NC}"
    exit 1
fi

echo "╔═══════════════════════════════════════════════════════╗"
echo "║   NFTBan Security Scanner - Lab Environment          ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""
echo "OS: $OS_NAME $OS_VERSION"
echo "Hostname: $(hostname)"
echo "Date: $(date)"
echo ""

# Confirm this is a lab server
read -p "Are you SURE this is a LAB server (not production)? [yes/NO]: " -r
if [[ ! "$REPLY" =~ ^[Yy][Ee][Ss]$ ]]; then
    echo -e "${RED}Aborted. Only run on lab servers.${NC}"
    exit 1
fi

# Create results directory
RESULTS_DIR="/var/log/nftban/security-scan-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULTS_DIR"

echo -e "${BLUE}Results will be saved to: $RESULTS_DIR${NC}"
echo ""

# ============================================================================
# Tool Installation Functions
# ============================================================================

install_shellcheck() {
    echo -e "${YELLOW}[1/6] Installing ShellCheck...${NC}"

    if command -v shellcheck &>/dev/null; then
        echo -e "${GREEN}✓ ShellCheck already installed$(NC}"
        shellcheck --version | head -2
        return 0
    fi

    case "$OS_NAME" in
        centos|rocky|rhel|fedora)
            dnf install -y ShellCheck
            ;;
        ubuntu|debian)
            apt-get update && apt-get install -y shellcheck
            ;;
        *)
            echo -e "${RED}✗ Unsupported OS for ShellCheck${NC}"
            return 1
            ;;
    esac

    if command -v shellcheck &>/dev/null; then
        echo -e "${GREEN}✓ ShellCheck installed successfully${NC}"
        shellcheck --version | head -2
    else
        echo -e "${RED}✗ ShellCheck installation failed${NC}"
        return 1
    fi
}

install_gitleaks() {
    echo -e "${YELLOW}[2/6] Installing Gitleaks...${NC}"

    if command -v gitleaks &>/dev/null; then
        echo -e "${GREEN}✓ Gitleaks already installed${NC}"
        gitleaks version
        return 0
    fi

    local version="8.18.4"
    local tmpdir
    tmpdir=$(mktemp -d)

    cd "$tmpdir"
    wget -q "https://github.com/gitleaks/gitleaks/releases/download/v${version}/gitleaks_${version}_linux_x64.tar.gz"
    tar -xzf "gitleaks_${version}_linux_x64.tar.gz"
    mv gitleaks /usr/local/bin/
    chmod +x /usr/local/bin/gitleaks
    cd - >/dev/null
    rm -rf "$tmpdir"

    if command -v gitleaks &>/dev/null; then
        echo -e "${GREEN}✓ Gitleaks installed successfully${NC}"
        gitleaks version
    else
        echo -e "${RED}✗ Gitleaks installation failed${NC}"
        return 1
    fi
}

install_trivy() {
    echo -e "${YELLOW}[3/6] Installing Trivy...${NC}"

    if command -v trivy &>/dev/null; then
        echo -e "${GREEN}✓ Trivy already installed${NC}"
        trivy --version
        return 0
    fi

    local tmpfile
    tmpfile=$(mktemp)

    curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \
        -o "$tmpfile"
    sh "$tmpfile" -b /usr/local/bin
    rm -f "$tmpfile"

    if command -v trivy &>/dev/null; then
        echo -e "${GREEN}✓ Trivy installed successfully${NC}"
        trivy --version
    else
        echo -e "${RED}✗ Trivy installation failed${NC}"
        return 1
    fi
}

install_shfmt() {
    echo -e "${YELLOW}[4/6] Installing shfmt...${NC}"

    if command -v shfmt &>/dev/null; then
        echo -e "${GREEN}✓ shfmt already installed${NC}"
        shfmt --version
        return 0
    fi

    # Check if Go is available
    if ! command -v go &>/dev/null; then
        echo -e "${YELLOW}Go not installed, skipping shfmt${NC}"
        return 1
    fi

    GO111MODULE=on go install mvdan.cc/sh/v3/cmd/shfmt@latest

    # Try to find shfmt in common locations
    local shfmt_paths=(
        "$HOME/go/bin/shfmt"
        "/root/go/bin/shfmt"
        "/usr/local/go/bin/shfmt"
    )

    for path in "${shfmt_paths[@]}"; do
        if [[ -f "$path" ]]; then
            cp "$path" /usr/local/bin/shfmt
            chmod +x /usr/local/bin/shfmt
            break
        fi
    done

    if command -v shfmt &>/dev/null; then
        echo -e "${GREEN}✓ shfmt installed successfully${NC}"
        shfmt --version
    else
        echo -e "${YELLOW}⚠ shfmt installation failed (non-critical)${NC}"
        return 1
    fi
}

install_jq() {
    echo -e "${YELLOW}[5/6] Installing jq...${NC}"

    if command -v jq &>/dev/null; then
        echo -e "${GREEN}✓ jq already installed${NC}"
        jq --version
        return 0
    fi

    case "$OS_NAME" in
        centos|rocky|rhel|fedora)
            dnf install -y jq
            ;;
        ubuntu|debian)
            apt-get update && apt-get install -y jq
            ;;
        *)
            echo -e "${RED}✗ Unsupported OS for jq${NC}"
            return 1
            ;;
    esac

    if command -v jq &>/dev/null; then
        echo -e "${GREEN}✓ jq installed successfully${NC}"
        jq --version
    else
        echo -e "${RED}✗ jq installation failed${NC}"
        return 1
    fi
}

install_git() {
    echo -e "${YELLOW}[6/6] Checking git...${NC}"

    if command -v git &>/dev/null; then
        echo -e "${GREEN}✓ git already installed${NC}"
        git --version
        return 0
    fi

    case "$OS_NAME" in
        centos|rocky|rhel|fedora)
            dnf install -y git
            ;;
        ubuntu|debian)
            apt-get update && apt-get install -y git
            ;;
        *)
            echo -e "${RED}✗ Unsupported OS for git${NC}"
            return 1
            ;;
    esac
}

# ============================================================================
# Security Scan Functions
# ============================================================================

scan_shellcheck() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "SCAN 1: ShellCheck (Bash Static Analysis)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local output="$RESULTS_DIR/shellcheck-results.txt"
    local summary="$RESULTS_DIR/shellcheck-summary.txt"

    {
        echo "ShellCheck Scan Results"
        echo "Date: $(date)"
        echo "═══════════════════════════════════════════════════════"
        echo ""
    } > "$output"

    local total=0
    local errors=0
    local warnings=0
    local notes=0

    echo "Scanning bash scripts in /etc/nftban..."

    while IFS= read -r script; do
        echo "  → $(basename "$script")"
        ((total++))

        {
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "File: $script"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        } >> "$output"

        if shellcheck -x "$script" >> "$output" 2>&1; then
            echo "    ✓ No issues" >> "$output"
        else
            # Count severity levels
            local file_errors
            file_errors=$(grep -c "^SC[0-9]*.*error:" "$output" 2>/dev/null || echo 0)
            local file_warnings
            file_warnings=$(grep -c "^SC[0-9]*.*warning:" "$output" 2>/dev/null || echo 0)
            local file_notes
            file_notes=$(grep -c "^SC[0-9]*.*note:" "$output" 2>/dev/null || echo 0)

            ((errors += file_errors))
            ((warnings += file_warnings))
            ((notes += file_notes))
        fi

        echo "" >> "$output"
    done < <(find /etc/nftban -name "*.sh" -type f)

    {
        echo "═══════════════════════════════════════════════════════"
        echo "SUMMARY"
        echo "═══════════════════════════════════════════════════════"
        echo "Total scripts scanned: $total"
        echo "Errors:   $errors"
        echo "Warnings: $warnings"
        echo "Notes:    $notes"
        echo ""
    } | tee -a "$output" > "$summary"

    echo -e "${GREEN}✓ ShellCheck scan complete${NC}"
    echo "  Results: $output"
    echo "  Summary: $summary"

    cat "$summary"
}

scan_gitleaks() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "SCAN 2: Gitleaks (Secret Detection)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local output="$RESULTS_DIR/gitleaks-results.json"
    local summary="$RESULTS_DIR/gitleaks-summary.txt"

    echo "Scanning /etc/nftban for secrets..."

    if gitleaks detect \
        --source /etc/nftban \
        --no-git \
        --report-format json \
        --report-path "$output" \
        --verbose 2>&1 | tee "$summary"; then
        echo -e "${GREEN}✓ No secrets detected${NC}" | tee -a "$summary"
    else
        echo -e "${RED}⚠ Potential secrets found${NC}" | tee -a "$summary"
    fi

    if [[ -f "$output" && -s "$output" ]]; then
        local count
        count=$(jq '. | length' "$output" 2>/dev/null || echo "0")
        echo "Total findings: $count" | tee -a "$summary"
    fi

    echo -e "${GREEN}✓ Gitleaks scan complete${NC}"
    echo "  Results: $output"
    echo "  Summary: $summary"
}

scan_trivy() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "SCAN 3: Trivy (Secret & Config Scanner)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local output="$RESULTS_DIR/trivy-results.txt"

    echo "Scanning /etc/nftban with Trivy..."

    trivy fs \
        --scanners secret,config \
        --severity HIGH,CRITICAL \
        /etc/nftban \
        | tee "$output"

    echo -e "${GREEN}✓ Trivy scan complete${NC}"
    echo "  Results: $output"
}

scan_permissions() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "SCAN 4: File Permissions Audit"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local output="$RESULTS_DIR/permissions-audit.txt"

    {
        echo "File Permissions Audit"
        echo "Date: $(date)"
        echo "═══════════════════════════════════════════════════════"
        echo ""

        echo "━━━ Files with world-writable permissions ━━━"
        find /etc/nftban -type f -perm -002 -ls 2>/dev/null || echo "None found"

        echo ""
        echo "━━━ Files with SUID/SGID bits ━━━"
        find /etc/nftban -type f \( -perm -4000 -o -perm -2000 \) -ls 2>/dev/null || echo "None found"

        echo ""
        echo "━━━ Files with unusual ownership ━━━"
        find /etc/nftban -type f ! -user root -ls 2>/dev/null || echo "All files owned by root"

        echo ""
        echo "━━━ Executable files ━━━"
        find /etc/nftban -type f -executable -ls 2>/dev/null

        echo ""
        echo "━━━ Configuration files permissions ━━━"
        find /etc/nftban/config -type f -ls 2>/dev/null

    } | tee "$output"

    echo -e "${GREEN}✓ Permissions audit complete${NC}"
    echo "  Results: $output"
}

scan_code_patterns() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "SCAN 5: Dangerous Code Pattern Detection"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local output="$RESULTS_DIR/code-patterns.txt"

    {
        echo "Dangerous Code Pattern Detection"
        echo "Date: $(date)"
        echo "═══════════════════════════════════════════════════════"
        echo ""

        echo "━━━ Use of 'eval' (dangerous) ━━━"
        grep -rn "eval " /etc/nftban --include="*.sh" 2>/dev/null || echo "None found"

        echo ""
        echo "━━━ Use of unquoted variables ━━━"
        echo "(Checking for common patterns...)"
        grep -rn '\$[A-Z_]*[^"]' /etc/nftban --include="*.sh" 2>/dev/null | head -20 || echo "Manual review needed"

        echo ""
        echo "━━━ Temporary files without mktemp ━━━"
        grep -rn '/tmp/[^$]' /etc/nftban --include="*.sh" 2>/dev/null || echo "None found"

        echo ""
        echo "━━━ Missing strict mode (set -euo pipefail) ━━━"
        for script in /etc/nftban/lib/*.sh /etc/nftban/bin/*; do
            [[ -f "$script" ]] || continue
            if ! grep -q "set -.*e" "$script"; then
                echo "  Missing in: $script"
            fi
        done

        echo ""
        echo "━━━ Curl without error handling ━━━"
        grep -rn "curl " /etc/nftban --include="*.sh" 2>/dev/null | grep -v -- "--fail" || echo "All curls use --fail"

        echo ""
        echo "━━━ Potential command injection points ━━━"
        grep -rn 'nft.*\$' /etc/nftban --include="*.sh" 2>/dev/null | head -20

    } | tee "$output"

    echo -e "${GREEN}✓ Code pattern scan complete${NC}"
    echo "  Results: $output"
}

scan_nftables_security() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "SCAN 6: nftables Security Audit"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local output="$RESULTS_DIR/nftables-security.txt"

    {
        echo "nftables Security Audit"
        echo "Date: $(date)"
        echo "═══════════════════════════════════════════════════════"
        echo ""

        echo "━━━ Current ruleset ━━━"
        nft list ruleset

        echo ""
        echo "━━━ Table priorities ━━━"
        nft list tables | while read -r table; do
            echo "Table: $table"
            nft list table "$table" | grep -A2 "type filter"
        done

        echo ""
        echo "━━━ Whitelist sets ━━━"
        nft list set inet nftban_v4 whitelist_v4 2>/dev/null || echo "IPv4 whitelist not found"
        nft list set inet nftban_v6 whitelist_v6 2>/dev/null || echo "IPv6 whitelist not found"

        echo ""
        echo "━━━ Blacklist/Feed sets ━━━"
        nft list set inet nftban_v4 blacklist_v4 2>/dev/null | head -20 || echo "IPv4 blacklist not found"

        echo ""
        echo "━━━ Default policies ━━━"
        nft list ruleset | grep "policy"

    } | tee "$output"

    echo -e "${GREEN}✓ nftables security audit complete${NC}"
    echo "  Results: $output"
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║   Installing Security Tools                          ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo ""

    # Install tools
    install_shellcheck || echo "Warning: ShellCheck installation failed"
    install_gitleaks || echo "Warning: Gitleaks installation failed"
    install_trivy || echo "Warning: Trivy installation failed"
    install_shfmt || echo "Warning: shfmt installation failed"
    install_jq || echo "Warning: jq installation failed"
    install_git || echo "Warning: git installation failed"

    echo ""
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║   Running Security Scans                             ║"
    echo "╚═══════════════════════════════════════════════════════╝"

    # Run scans
    scan_shellcheck
    scan_gitleaks
    scan_trivy
    scan_permissions
    scan_code_patterns
    scan_nftables_security

    echo ""
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║   Security Scan Complete                             ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo ""
    echo "All results saved to: $RESULTS_DIR"
    echo ""
    echo "Quick Summary:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [[ -f "$RESULTS_DIR/shellcheck-summary.txt" ]]; then
        cat "$RESULTS_DIR/shellcheck-summary.txt"
    fi

    echo ""
    echo "Next Steps:"
    echo "1. Review detailed results in: $RESULTS_DIR/"
    echo "2. Address any HIGH/CRITICAL findings"
    echo "3. Run 'nftban verify' to check system health"
    echo "4. Compare results across all lab servers"
    echo ""

    # Create tar archive of results
    local archive="/tmp/security-scan-$(hostname)-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar -czf "$archive" -C "$(dirname "$RESULTS_DIR")" "$(basename "$RESULTS_DIR")"

    echo "Results archived to: $archive"
    echo "You can download this for local analysis."
    echo ""
}

# Run main function
main "$@"
