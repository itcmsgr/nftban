#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.0.0 - Distro Config Validation Script
# =============================================================================
# meta:name="validate_distro_configs"
# meta:type="test"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Validate distribution configuration files"
# meta:inventory.files=""
# meta:inventory.binaries="bash"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Purpose: Validate distribution configuration files
# Usage: ./validate_distro_configs.sh [config_dir]
#
# Tests:
# - INI syntax validity
# - Required sections present
# - Required fields in each section
# - Value format validation
# =============================================================================

set -Eeuo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
CONFIG_DIR="${1:-./}"
ERRORS=0
WARNINGS=0
PASSED=0

# Required sections
REQUIRED_SECTIONS=("distro" "package_manager" "packages" "services" "paths")

# Required fields per section
declare -A REQUIRED_FIELDS
REQUIRED_FIELDS[distro]="id name version family"
REQUIRED_FIELDS[package_manager]="type install_cmd update_cmd"
# v2.1: fail2ban removed - use native login monitoring
REQUIRED_FIELDS[packages]="nftables curl bash systemd mail golang"
REQUIRED_FIELDS[services]="cron rsyslog nftables sshd"
REQUIRED_FIELDS[paths]="nft systemctl journalctl"

# =============================================================================
# VALIDATION FUNCTIONS
# =============================================================================

print_header() {
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  NFTBan Distribution Config Validator"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
}

print_summary() {
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  Validation Summary"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    echo -e "${GREEN}✓ Passed: ${PASSED}${NC}"
    echo -e "${YELLOW}⚠ Warnings: ${WARNINGS}${NC}"
    echo -e "${RED}✗ Errors: ${ERRORS}${NC}"
    echo ""

    if [[ $ERRORS -eq 0 ]]; then
        echo -e "${GREEN}All validations passed!${NC}"
        return 0
    else
        echo -e "${RED}Validation failed with ${ERRORS} error(s)${NC}"
        return 1
    fi
}

# Check if section exists in config
has_section() {
    local file="$1"
    local section="$2"
    grep -q "^\[$section\]" "$file"
}

# Get value from INI file
get_value() {
    local file="$1"
    local section="$2"
    local key="$3"

    awk -F= -v section="$section" -v key="$key" '
        /^\[.*\]/ { in_section=0 }
        $0 == "["section"]" { in_section=1; next }
        in_section && $1 ~ "^"key"$" {
            gsub(/^[ \t]+|[ \t]+$/, "", $2)
            print $2
            exit
        }
    ' "$file"
}

# Validate INI syntax
validate_syntax() {
    local file="$1"
    local filename
    filename=$(basename "$file")
    local syntax_errors=0

    # Check for basic INI format issues
    while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^# ]] && continue

        # Check for section headers
        if [[ "$line" =~ ^\[ ]]; then
            if [[ ! "$line" =~ ^\[[a-z_]+\]$ ]]; then
                echo -e "${RED}  ✗ Invalid section header: $line${NC}"
                # v1.19.20 FIX
                ((syntax_errors++)) || true
            fi
            continue
        fi

        # Check for key=value pairs
        if [[ ! "$line" =~ ^[a-z_]+=.+ ]]; then
            echo -e "${RED}  ✗ Invalid line format: $line${NC}"
            # v1.19.20 FIX
            ((syntax_errors++)) || true
        fi
    done < "$file"

    if [[ $syntax_errors -eq 0 ]]; then
        echo -e "${GREEN}  ✓ Syntax valid${NC}"
        # v1.19.20 FIX
        ((PASSED++)) || true
        return 0
    else
        echo -e "${RED}  ✗ Syntax errors: $syntax_errors${NC}"
        ((ERRORS+=syntax_errors))
        return 1
    fi
}

# Validate required sections
validate_sections() {
    local file="$1"
    local missing=0

    for section in "${REQUIRED_SECTIONS[@]}"; do
        if has_section "$file" "$section"; then
            echo -e "${GREEN}  ✓ Section [$section] present${NC}"
            # v1.19.20 FIX
            ((PASSED++)) || true
        else
            echo -e "${RED}  ✗ Section [$section] missing${NC}"
            # v1.19.20 FIX
            ((ERRORS++)) || true
            # v1.19.20 FIX
            ((missing++)) || true
        fi
    done

    return $missing
}

# Validate required fields in a section
validate_fields() {
    local file="$1"
    local section="$2"
    local required="${REQUIRED_FIELDS[$section]}"
    local missing=0

    for field in $required; do
        local value
        value=$(get_value "$file" "$section" "$field")
        if [[ -n "$value" ]]; then
            echo -e "${GREEN}    ✓ $field = $value${NC}"
            # v1.19.20 FIX
            ((PASSED++)) || true
        else
            echo -e "${RED}    ✗ $field is missing or empty${NC}"
            # v1.19.20 FIX
            ((ERRORS++)) || true
            # v1.19.20 FIX
            ((missing++)) || true
        fi
    done

    return $missing
}

# Validate distro family
validate_family() {
    local file="$1"
    local family
    family=$(get_value "$file" "distro" "family")

    case "$family" in
        rhel|debian)
            echo -e "${GREEN}    ✓ Valid family: $family${NC}"
            # v1.19.20 FIX
            ((PASSED++)) || true
            return 0
            ;;
        *)
            echo -e "${RED}    ✗ Invalid family: $family (expected: rhel or debian)${NC}"
            # v1.19.20 FIX
            ((ERRORS++)) || true
            return 1
            ;;
    esac
}

# Validate package manager type
validate_pkgmgr() {
    local file="$1"
    local type
    type=$(get_value "$file" "package_manager" "type")

    case "$type" in
        dnf|yum|apt-get)
            echo -e "${GREEN}    ✓ Valid package manager: $type${NC}"
            # v1.19.20 FIX
            ((PASSED++)) || true
            return 0
            ;;
        *)
            echo -e "${YELLOW}    ⚠ Unusual package manager: $type${NC}"
            # v1.19.20 FIX
            ((WARNINGS++)) || true
            return 0
            ;;
    esac
}

# Validate query_cmd matches family
validate_query_cmd() {
    local file="$1"
    local family
    family=$(get_value "$file" "distro" "family")
    local query_cmd
    query_cmd=$(get_value "$file" "package_manager" "query_cmd")

    case "$family" in
        rhel)
            if [[ "$query_cmd" == "rpm -qa" ]]; then
                echo -e "${GREEN}    ✓ Correct query_cmd for RHEL family${NC}"
                # v1.19.20 FIX
                ((PASSED++)) || true
            else
                echo -e "${RED}    ✗ Wrong query_cmd for RHEL: $query_cmd (expected: rpm -qa)${NC}"
                # v1.19.20 FIX
                ((ERRORS++)) || true
            fi
            ;;
        debian)
            if [[ "$query_cmd" == "dpkg -l" ]]; then
                echo -e "${GREEN}    ✓ Correct query_cmd for Debian family${NC}"
                # v1.19.20 FIX
                ((PASSED++)) || true
            else
                echo -e "${RED}    ✗ Wrong query_cmd for Debian: $query_cmd (expected: dpkg -l)${NC}"
                # v1.19.20 FIX
                ((ERRORS++)) || true
            fi
            ;;
    esac
}

# Validate a single config file
validate_config() {
    local file="$1"
    local filename
    filename=$(basename "$file")

    echo ""
    echo -e "${BLUE}Validating: $filename${NC}"
    echo "───────────────────────────────────────────────────────────"

    # 1. Syntax validation
    echo "Checking syntax..."
    validate_syntax "$file"

    # 2. Section validation
    echo ""
    echo "Checking required sections..."
    validate_sections "$file"

    # 3. Field validation per section
    for section in "${REQUIRED_SECTIONS[@]}"; do
        if has_section "$file" "$section"; then
            echo ""
            echo "Checking [$section] fields..."
            validate_fields "$file" "$section"

            # Special validations
            if [[ "$section" == "distro" ]]; then
                validate_family "$file"
            elif [[ "$section" == "package_manager" ]]; then
                validate_pkgmgr "$file"
                validate_query_cmd "$file"
            fi
        fi
    done
}

# =============================================================================
# MAIN
# =============================================================================

print_header

# Find all .conf files
echo "Searching for config files in: $CONFIG_DIR"
echo ""

config_files=()
while IFS= read -r -d '' file; do
    config_files+=("$file")
done < <(find "$CONFIG_DIR" -name "*.conf" -type f -print0 2>/dev/null)

if [[ ${#config_files[@]} -eq 0 ]]; then
    echo -e "${RED}No config files found in $CONFIG_DIR${NC}"
    exit 1
fi

echo "Found ${#config_files[@]} config file(s)"

# Validate each config
for config in "${config_files[@]}"; do
    validate_config "$config"
done

# Print summary
print_summary
