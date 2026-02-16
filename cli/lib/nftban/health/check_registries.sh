#!/usr/bin/env bash
# =============================================================================
# NFTBan Health Check - Registry Validation
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="check_registries"
# meta:type="health"
# meta:description="Lightweight registry validation for nftban health command"
# meta:inventory.files=""
# meta:inventory.binaries="python3"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# Quick registry checks for production health monitoring.
# For deep analysis, use nftban-validator.
# =============================================================================

set -Eeuo pipefail

# Configuration
NFTBAN_LIB_DIR="${NFTBAN_LIB_DIR:-/usr/lib/nftban}"
NFTBAN_CONFIG_DIR="${NFTBAN_CONFIG_DIR:-/etc/nftban}"

# Registry paths (installed paths)
COMMANDS_REGISTRY="${NFTBAN_CONFIG_DIR}/commands.registry.yml"
CONFIG_REGISTRY="${NFTBAN_LIB_DIR}/data/config-registry.json"
CONFIG_SCHEMA="${NFTBAN_LIB_DIR}/data/config-schema.json"
REPORTS_REGISTRY="${NFTBAN_LIB_DIR}/data/reports-registry.json"

# Output format
FORMAT="${1:-text}"
ERRORS=0
WARNINGS=0

# JSON output helper
declare -a JSON_CHECKS=()

check_json_valid() {
    local file="$1"
    local name="$2"

    if [[ ! -f "$file" ]]; then
        if [[ "$FORMAT" == "json" ]]; then
            JSON_CHECKS+=("{\"name\":\"$name\",\"status\":\"warning\",\"message\":\"File not found\"}")
        else
            echo "  ⚠ $name: Not found"
        fi
        ((WARNINGS++))
        return 1
    fi

    if python3 -m json.tool "$file" >/dev/null 2>&1; then
        if [[ "$FORMAT" == "json" ]]; then
            JSON_CHECKS+=("{\"name\":\"$name\",\"status\":\"ok\",\"message\":\"Valid JSON\"}")
        else
            echo "  ✓ $name: Valid"
        fi
        return 0
    else
        if [[ "$FORMAT" == "json" ]]; then
            JSON_CHECKS+=("{\"name\":\"$name\",\"status\":\"error\",\"message\":\"Invalid JSON syntax\"}")
        else
            echo "  ✗ $name: Invalid JSON"
        fi
        ((ERRORS++))
        return 1
    fi
}

check_yaml_valid() {
    local file="$1"
    local name="$2"

    if [[ ! -f "$file" ]]; then
        if [[ "$FORMAT" == "json" ]]; then
            JSON_CHECKS+=("{\"name\":\"$name\",\"status\":\"warning\",\"message\":\"File not found\"}")
        else
            echo "  ⚠ $name: Not found"
        fi
        ((WARNINGS++))
        return 1
    fi

    if python3 -c "import yaml; yaml.safe_load(open('$file'))" 2>/dev/null; then
        if [[ "$FORMAT" == "json" ]]; then
            JSON_CHECKS+=("{\"name\":\"$name\",\"status\":\"ok\",\"message\":\"Valid YAML\"}")
        else
            echo "  ✓ $name: Valid"
        fi
        return 0
    else
        if [[ "$FORMAT" == "json" ]]; then
            JSON_CHECKS+=("{\"name\":\"$name\",\"status\":\"error\",\"message\":\"Invalid YAML syntax\"}")
        else
            echo "  ✗ $name: Invalid YAML"
        fi
        ((ERRORS++))
        return 1
    fi
}

# Run checks
if [[ "$FORMAT" != "json" ]]; then
    echo "Registry Health Check"
    echo "─────────────────────────────────────────────────────────"
fi

# Check each registry
check_yaml_valid "$COMMANDS_REGISTRY" "commands.registry.yml" || true
check_json_valid "$CONFIG_REGISTRY" "config-registry.json" || true
check_json_valid "$CONFIG_SCHEMA" "config-schema.json" || true
check_json_valid "$REPORTS_REGISTRY" "reports-registry.json" || true

# Output results
if [[ "$FORMAT" == "json" ]]; then
    echo "{"
    echo "  \"check\": \"registries\","
    echo "  \"status\": \"$([[ $ERRORS -eq 0 ]] && echo 'ok' || echo 'error')\","
    echo "  \"errors\": $ERRORS,"
    echo "  \"warnings\": $WARNINGS,"
    echo "  \"registries\": ["
    first=1
    for check in "${JSON_CHECKS[@]}"; do
        [[ $first -eq 0 ]] && echo ","
        echo -n "    $check"
        first=0
    done
    echo ""
    echo "  ]"
    echo "}"
else
    echo "─────────────────────────────────────────────────────────"
    if [[ $ERRORS -gt 0 ]]; then
        echo "Status: FAILED ($ERRORS errors, $WARNINGS warnings)"
    elif [[ $WARNINGS -gt 0 ]]; then
        echo "Status: WARNING ($WARNINGS warnings)"
    else
        echo "Status: OK (all registries valid)"
    fi
fi

# Exit code
[[ $ERRORS -gt 0 ]] && exit 1
exit 0
