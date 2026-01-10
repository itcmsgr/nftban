#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Service Capabilities Validator
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="validate-service-capabilities"
# meta:type="tools"
# meta:header="Validate systemd service capabilities match contract"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Ensures systemd service capabilities match the contract"
# meta:inventory.files=""
# meta:inventory.binaries="grep,awk"
# meta:inventory.env_vars=""
# meta:inventory.config_files="install/config/service-capabilities.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="user"
#
# meta:created_date="2026-01-10"
# meta:updated_date="2026-01-10"
#
# Usage:
#   ./tools/validate-service-capabilities.sh
#
# Exit codes:
#   0 - All services match their capability contract
#   1 - Mismatch found
# =============================================================================

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACT_FILE="${REPO_ROOT}/install/config/service-capabilities.conf"
SYSTEMD_DIR="${REPO_ROOT}/install/systemd"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

errors=0
checked=0

echo "Validating systemd service capabilities against contract..."
echo ""

# Read contract entries (skip comments and empty lines)
while IFS= read -r line; do
    # Skip comments and empty lines
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

    # Parse service=capabilities
    service="${line%%=*}"
    expected_caps="${line#*=}"

    # Trim whitespace
    service="${service// /}"

    service_file="${SYSTEMD_DIR}/${service}.service"

    if [[ ! -f "$service_file" ]]; then
        echo -e "${YELLOW}[SKIP]${NC} ${service}.service - file not found"
        continue
    fi

    ((checked++)) || true

    # Extract capabilities from service file
    # Look for both CapabilityBoundingSet and AmbientCapabilities
    actual_caps=""

    # Get CapabilityBoundingSet (authoritative)
    cap_bound=$(grep -E '^CapabilityBoundingSet=' "$service_file" 2>/dev/null | head -1 | cut -d'=' -f2 || true)

    # Get AmbientCapabilities
    cap_ambient=$(grep -E '^AmbientCapabilities=' "$service_file" 2>/dev/null | head -1 | cut -d'=' -f2 || true)

    # Use CapabilityBoundingSet as authoritative, fall back to AmbientCapabilities
    if [[ -n "$cap_bound" ]]; then
        actual_caps="$cap_bound"
    elif [[ -n "$cap_ambient" ]]; then
        actual_caps="$cap_ambient"
    fi

    # Normalize: sort capabilities for comparison
    expected_sorted=$(echo "$expected_caps" | tr ' ' '\n' | sort | tr '\n' ' ' | xargs)
    actual_sorted=$(echo "$actual_caps" | tr ' ' '\n' | sort | tr '\n' ' ' | xargs)

    if [[ "$expected_sorted" == "$actual_sorted" ]]; then
        echo -e "${GREEN}[PASS]${NC} ${service}.service - capabilities: ${actual_caps:-none}"
    else
        echo -e "${RED}[FAIL]${NC} ${service}.service"
        echo "       Expected: ${expected_caps}"
        echo "       Actual:   ${actual_caps:-none}"
        ((errors++)) || true
    fi
done < "$CONTRACT_FILE"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ $errors -eq 0 ]]; then
    echo -e "${GREEN}[OK]${NC} All ${checked} service(s) match their capability contract"
    exit 0
else
    echo -e "${RED}[ERROR]${NC} ${errors} service(s) have capability mismatches"
    echo ""
    echo "To fix:"
    echo "  1. Update the service file to match the contract, OR"
    echo "  2. Update install/config/service-capabilities.conf if the change is intentional"
    exit 1
fi
