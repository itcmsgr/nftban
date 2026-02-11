#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.0.0 - Service Security Validator
# =============================================================================
# meta:name="validate-service-security"
# meta:type="tool"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Ensures systemd service security matches the contract"
# meta:inventory.files=""
# meta:inventory.binaries="grep,awk,sed"
# meta:inventory.env_vars=""
# meta:inventory.config_files="install/config/service-security.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Usage:
#   ./tools/validate-service-security.sh [--strict]
#
# Exit codes:
#   0 - All services match their security contract
#   1 - Mismatch found
# =============================================================================

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACT_FILE="${REPO_ROOT}/install/config/service-security.conf"
SYSTEMD_DIR="${REPO_ROOT}/install/systemd"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

STRICT_MODE=0
[[ "${1:-}" == "--strict" ]] && STRICT_MODE=1

errors=0
warnings=0
checked=0

echo "Validating systemd service security against contract..."
[[ $STRICT_MODE -eq 1 ]] && echo -e "${BLUE}Mode: STRICT (all checks required)${NC}"
echo ""

# Parse INI file and extract section values
get_contract_value() {
    local section="$1"
    local key="$2"
    awk -v section="$section" -v key="$key" '
        /^\[/ { in_section = ($0 == "[" section "]") }
        in_section && $0 ~ "^" key "=" {
            sub(/^[^=]+=/, "");
            print;
            exit
        }
    ' "$CONTRACT_FILE"
}

# Get value from systemd unit file
get_unit_value() {
    local file="$1"
    local key="$2"
    grep -E "^${key}=" "$file" 2>/dev/null | head -1 | cut -d'=' -f2- || true
}

# Normalize for comparison (sort space-separated values, normalize yes/true)
normalize() {
    local val="$1"
    # Normalize boolean values
    val="${val//yes/true}"
    val="${val//no/false}"
    echo "$val" | tr ' ' '\n' | sort -u | tr '\n' ' ' | xargs
}

# Check a single field
# Args: service, field, unit_key (reserved), expected, actual, is_critical
check_field() {
    local _service="$1"      # Reserved for future use
    local field="$2"
    local _unit_key="$3"     # Reserved for future use
    local expected="$4"
    local actual="$5"
    local is_critical="${6:-0}"

    local expected_norm
    local actual_norm
    expected_norm=$(normalize "$expected")
    actual_norm=$(normalize "$actual")

    if [[ "$expected_norm" == "$actual_norm" ]]; then
        echo -e "  ${GREEN}✓${NC} ${field}: ${actual:-<not set>}"
        return 0
    else
        if [[ $is_critical -eq 1 ]]; then
            echo -e "  ${RED}✗${NC} ${field}"
            echo -e "    Expected: ${expected}"
            echo -e "    Actual:   ${actual:-<not set>}"
            ((errors++)) || true
        else
            echo -e "  ${YELLOW}⚠${NC} ${field}"
            echo -e "    Expected: ${expected}"
            echo -e "    Actual:   ${actual:-<not set>}"
            ((warnings++)) || true
        fi
        return 1
    fi
}

# Get all sections from contract
sections=$(grep -E '^\[.*\]$' "$CONTRACT_FILE" | tr -d '[]')

for service in $sections; do
    service_file="${SYSTEMD_DIR}/${service}.service"

    if [[ ! -f "$service_file" ]]; then
        echo -e "${YELLOW}[SKIP]${NC} ${service}.service - file not found"
        continue
    fi

    ((checked++)) || true

    echo -e "${BLUE}[CHECK]${NC} ${service}.service"

    # Get expected values from contract
    exp_user=$(get_contract_value "$service" "user")
    exp_group=$(get_contract_value "$service" "group")
    exp_caps=$(get_contract_value "$service" "caps")
    exp_protect=$(get_contract_value "$service" "protectsystem")
    exp_readwrite=$(get_contract_value "$service" "readwrite")
    exp_nonewprivs=$(get_contract_value "$service" "nonewprivs")
    exp_privatetmp=$(get_contract_value "$service" "privatetmp")

    # Get actual values from unit file
    act_user=$(get_unit_value "$service_file" "User")
    act_group=$(get_unit_value "$service_file" "Group")
    act_caps=$(get_unit_value "$service_file" "CapabilityBoundingSet")
    act_ambient=$(get_unit_value "$service_file" "AmbientCapabilities")
    act_protect=$(get_unit_value "$service_file" "ProtectSystem")
    act_readwrite=$(get_unit_value "$service_file" "ReadWritePaths")
    act_nonewprivs=$(get_unit_value "$service_file" "NoNewPrivileges")
    act_privatetmp=$(get_unit_value "$service_file" "PrivateTmp")
    act_dynamicuser=$(get_unit_value "$service_file" "DynamicUser")

    # Use CapabilityBoundingSet as primary, fall back to AmbientCapabilities
    [[ -z "$act_caps" ]] && act_caps="$act_ambient"

    # Check critical fields (always required)
    check_field "$service" "User" "User" "$exp_user" "$act_user" 1
    check_field "$service" "Group" "Group" "$exp_group" "$act_group" 1
    check_field "$service" "Capabilities" "CapabilityBoundingSet" "$exp_caps" "$act_caps" 1

    # Check sandbox fields (critical in strict mode)
    check_field "$service" "ProtectSystem" "ProtectSystem" "$exp_protect" "$act_protect" $STRICT_MODE
    check_field "$service" "NoNewPrivileges" "NoNewPrivileges" "$exp_nonewprivs" "$act_nonewprivs" $STRICT_MODE
    check_field "$service" "PrivateTmp" "PrivateTmp" "$exp_privatetmp" "$act_privatetmp" $STRICT_MODE

    # Check ReadWritePaths (critical for services with CAP_DAC_OVERRIDE)
    if [[ "$exp_caps" == *"CAP_DAC_OVERRIDE"* ]]; then
        # Services with DAC_OVERRIDE MUST have constrained ReadWritePaths
        if [[ -z "$act_readwrite" ]]; then
            echo -e "  ${RED}✗${NC} ReadWritePaths: MISSING (required when CAP_DAC_OVERRIDE is granted)"
            ((errors++)) || true
        else
            # Verify paths are within allowed set
            allowed_prefixes="/etc/nftban /var/lib/nftban /var/log/nftban /var/cache/nftban /run/nftban"
            bad_paths=""
            for path in $act_readwrite; do
                is_allowed=0
                for prefix in $allowed_prefixes; do
                    [[ "$path" == "$prefix"* ]] && is_allowed=1 && break
                done
                [[ $is_allowed -eq 0 ]] && bad_paths="$bad_paths $path"
            done
            if [[ -n "$bad_paths" ]]; then
                echo -e "  ${RED}✗${NC} ReadWritePaths: contains paths outside allowed set"
                echo -e "    Disallowed:$bad_paths"
                echo -e "    Allowed prefixes: $allowed_prefixes"
                ((errors++)) || true
            else
                echo -e "  ${GREEN}✓${NC} ReadWritePaths: properly constrained"
            fi
        fi
    else
        # Non-DAC_OVERRIDE services - just verify ReadWritePaths matches if specified
        if [[ -n "$exp_readwrite" ]]; then
            check_field "$service" "ReadWritePaths" "ReadWritePaths" "$exp_readwrite" "$act_readwrite" 0
        fi
    fi

    # Check DynamicUser (must be false or not set for our model)
    if [[ -n "$act_dynamicuser" && "$act_dynamicuser" != "false" ]]; then
        echo -e "  ${RED}✗${NC} DynamicUser: must be false (got: $act_dynamicuser)"
        ((errors++)) || true
    else
        echo -e "  ${GREEN}✓${NC} DynamicUser: false/not set (correct)"
    fi

    echo ""
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ $errors -eq 0 && $warnings -eq 0 ]]; then
    echo -e "${GREEN}[OK]${NC} All ${checked} service(s) match their security contract"
    exit 0
elif [[ $errors -eq 0 ]]; then
    echo -e "${YELLOW}[WARN]${NC} ${checked} service(s) checked, ${warnings} warning(s)"
    echo ""
    echo "Warnings are non-blocking but should be reviewed."
    echo "Run with --strict to treat warnings as errors."
    exit 0
else
    echo -e "${RED}[ERROR]${NC} ${errors} error(s), ${warnings} warning(s)"
    echo ""
    echo "To fix:"
    echo "  1. Update the service file to match the contract, OR"
    echo "  2. Update install/config/service-security.conf if the change is intentional"
    exit 1
fi
