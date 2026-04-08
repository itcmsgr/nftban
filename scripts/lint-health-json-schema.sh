#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.79 - CI Gate G17: Health JSON Schema Validation
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Validate health JSON output contains required fields and structure
#
# meta:name="lint-health-json-schema"
# meta:type="ci"
# meta:version="1.79.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-04-08"
# meta:inventory.files="scripts/lint-health-json-schema.sh"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail

echo "=== CI Gate G17: Health JSON Schema Validation ==="
echo ""

VIOLATIONS=0

# Find health render code
HEALTH_RENDER="cli/lib/nftban/core/nftban_health_render.sh"

if [[ ! -f "$HEALTH_RENDER" ]]; then
    echo "::error::Health render file not found: $HEALTH_RENDER"
    exit 1
fi

# Required top-level fields in health JSON
# Based on v1.78 health JSON v1.0.0 schema
# Note: Fields are stored for grep matching in echo statements
REQUIRED_FIELDS=(
    'schema_version'
    'timestamp'
    'kernel'
    'services'
)

echo "Checking health JSON render for required fields..."

for field in "${REQUIRED_FIELDS[@]}"; do
    if ! grep -q "$field" "$HEALTH_RENDER"; then
        echo "::error::Missing required field $field in health JSON render"
        VIOLATIONS=$((VIOLATIONS + 1))
    else
        echo "✓ Found field: $field"
    fi
done

echo ""

# Validate schema_version is set to known version
if ! grep -qE 'schema_version.*1\.[0-9]+\.[0-9]+' "$HEALTH_RENDER"; then
    echo "::warning::schema_version may not be set to semver format"
fi

# Validate JSON output uses proper escaping
echo "Checking for proper JSON escaping..."

# Check for raw variable interpolation without proper escaping (common JSON bug)
# Allow: printf '...' "$var" (proper) vs echo "{"key": $var}" (dangerous)
DANGEROUS_PATTERNS=(
    '": \${'           # Unquoted variable in JSON value
    '": \$[A-Za-z]'    # Unquoted variable in JSON value
)

for pattern in "${DANGEROUS_PATTERNS[@]}"; do
    if grep -En "$pattern" "$HEALTH_RENDER" | grep -v '#' | grep -v 'printf' >/dev/null 2>&1; then
        echo "::warning::Potentially unsafe JSON interpolation pattern found"
        grep -n "$pattern" "$HEALTH_RENDER" | grep -v '#' | head -3
    fi
done

# Check for heredoc JSON blocks (should use proper escaping)
echo ""
echo "Checking heredoc JSON blocks..."
HEREDOC_COUNT=$(grep -c 'cat <<' "$HEALTH_RENDER" 2>/dev/null || echo "0")
echo "Found $HEREDOC_COUNT heredoc blocks in health render"

if [[ $VIOLATIONS -gt 0 ]]; then
    echo ""
    echo "::error::G17 FAILED: $VIOLATIONS schema violations found"
    exit 1
fi

echo ""
echo "✓ G17: Health JSON schema validation PASSED"
